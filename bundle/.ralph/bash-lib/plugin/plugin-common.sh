#!/usr/bin/env bash
# Shared helpers for Ralph host-plugin install adapters (Claude/Codex/Cursor/OpenCode/…).
#
# Journals (user scope):   $RALPH_HOME/plugin-installs/<runtime>.json
# Journals (OpenCode):     <state-root>/plugin-installs/opencode.json
# Packaged assets:         $RALPH_HOME/plugins/ralph-orchestrator/<runtime>/
#
# States: absent | current | drifted | unverifiable
set -euo pipefail

if [[ -n "${RALPH_PLUGIN_COMMON_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
RALPH_PLUGIN_COMMON_LOADED=1

PLUGIN_COMMON_MARKETPLACE_NAME="ralph-plugins"
PLUGIN_COMMON_PLUGIN_ID="ralph-orchestrator"
PLUGIN_COMMON_PACKAGE_REF="${PLUGIN_COMMON_PLUGIN_ID}@${PLUGIN_COMMON_MARKETPLACE_NAME}"

plugin_common_ralph_home() {
  printf '%s\n' "${RALPH_HOME:-${HOME}/.ralph}"
}

plugin_common_package_root() {
  local runtime="${1:-}"
  [[ -n "$runtime" ]] || return 1
  printf '%s/plugins/ralph-orchestrator/%s\n' "$(plugin_common_ralph_home)" "$runtime"
}

# Resolve project state-root. Optional project_root; honors RALPH_PLAN_WORKSPACE_ROOT.
plugin_common_state_root() {
  local project_root="${1:-}"
  if [[ -n "${RALPH_PLAN_WORKSPACE_ROOT:-}" ]]; then
    printf '%s\n' "${RALPH_PLAN_WORKSPACE_ROOT%/}"
    return 0
  fi
  if [[ -n "$project_root" ]]; then
    printf '%s/.ralph-workspace\n' "${project_root%/}"
    return 0
  fi
  if [[ -n "${RALPH_PROJECT_ROOT:-}" ]]; then
    printf '%s/.ralph-workspace\n' "${RALPH_PROJECT_ROOT%/}"
    return 0
  fi
  return 1
}

# Journal path. Optional state_root (required for opencode when env unset).
plugin_common_journal_path() {
  local runtime="${1:-}"
  local state_root="${2:-}"
  [[ -n "$runtime" ]] || return 1
  if [[ "$runtime" == "opencode" ]]; then
    if [[ -z "$state_root" ]]; then
      state_root="$(plugin_common_state_root)" || return 1
    fi
    printf '%s/plugin-installs/opencode.json\n' "${state_root%/}"
    return 0
  fi
  printf '%s/plugin-installs/%s.json\n' "$(plugin_common_ralph_home)" "$runtime"
}

plugin_common_default_scope() {
  local runtime="${1:-}"
  case "$runtime" in
    claude | codex | cursor | antigravity) printf 'user\n' ;;
    opencode) printf 'project\n' ;;
    *) return 1 ;;
  esac
}

# Exit 2 when scope is unsupported for the runtime (fixed matrix).
plugin_common_require_scope() {
  local runtime="${1:-}"
  local scope="${2:-}"
  local expected
  expected="$(plugin_common_default_scope "$runtime")" || {
    printf 'plugin: unsupported runtime %s\n' "$runtime" >&2
    return 2
  }
  if [[ -z "$scope" ]]; then
    scope="$expected"
  fi
  if [[ "$scope" != "$expected" ]]; then
    printf 'plugin: scope %s is not supported for %s (only %s)\n' \
      "$scope" "$runtime" "$expected" >&2
    return 2
  fi
  printf '%s\n' "$scope"
}

plugin_common_utc_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ"
}

plugin_common_package_meta() {
  local package_root="${1:-}"
  local meta
  [[ -n "$package_root" && -d "$package_root" ]] || return 1
  meta="$package_root/.ralph-plugin-generated.json"
  [[ -f "$meta" ]] || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -r '[.pluginVersion // "", .sourceDescriptor // ""] | @tsv' "$meta"
    return 0
  fi
  python3 - "$meta" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
print(f"{data.get('pluginVersion', '')}\t{data.get('sourceDescriptor', '')}")
PY
}

plugin_common_journal_read() {
  local runtime="${1:-}"
  local state_root="${2:-}"
  local path
  path="$(plugin_common_journal_path "$runtime" "$state_root")" || return 1
  if [[ ! -f "$path" ]]; then
    return 1
  fi
  cat "$path"
}

plugin_common_journal_write() {
  local runtime="${1:-}"
  local json_file="${2:-}"
  local state_root="${3:-}"
  local path dir tmp
  path="$(plugin_common_journal_path "$runtime" "$state_root")" || return 1
  [[ -n "$json_file" && -f "$json_file" ]] || return 1
  dir="$(dirname "$path")"
  mkdir -p "$dir"
  tmp="$(mktemp "$dir/.plugin-journal.XXXXXX")" || return 1
  if command -v jq >/dev/null 2>&1; then
    if ! jq -e . "$json_file" >"$tmp" 2>/dev/null; then
      rm -f "$tmp"
      return 1
    fi
  else
    cp "$json_file" "$tmp" || {
      rm -f "$tmp"
      return 1
    }
  fi
  mv -f "$tmp" "$path"
}

plugin_common_journal_clear() {
  local runtime="${1:-}"
  local state_root="${2:-}"
  local path
  path="$(plugin_common_journal_path "$runtime" "$state_root")" || return 1
  rm -f "$path"
}

# SHA-256 of a file (hex). Requires shasum, sha256sum, or python3.
plugin_common_file_sha256() {
  local path="${1:-}"
  [[ -n "$path" && -f "$path" ]] || return 1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -- "$path" 2>/dev/null | awk '{print $1}'
    return 0
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$path" 2>/dev/null | awk '{print $1}'
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$path"
    return 0
  fi
  printf 'plugin: no sha256 tool available (shasum/sha256sum/python3)\n' >&2
  return 1
}

# Emit path<TAB>sha256 lines for every regular file under root (sorted).
# Paths are relative to root without a leading ./ .
plugin_common_collect_digests_tsv() {
  local root="${1:-}"
  local rel path digest
  [[ -n "$root" && -d "$root" ]] || return 1
  while IFS= read -r -d '' path; do
    rel="${path#"${root%/}"/}"
    digest="$(plugin_common_file_sha256 "$path")" || return 1
    printf '%s\t%s\n' "$rel" "$digest"
  done < <(find "${root%/}" -type f -print0 | sort -z)
}

# Convert digests TSV (path\thash) on stdin to a JSON object on stdout.
plugin_common_digests_tsv_to_json() {
  if command -v jq >/dev/null 2>&1; then
    jq -Rn '
      reduce (inputs | select(length > 0) | split("\t")) as $row ({};
        if ($row | length) >= 2 then .[$row[0]] = $row[1] else . end
      )
    '
    return $?
  fi
  python3 - <<'PY'
import json, sys
out = {}
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line or "\t" not in line:
        continue
    path, digest = line.split("\t", 1)
    out[path] = digest
print(json.dumps(out, sort_keys=True))
PY
}

# Collect digests for root into a JSON object file.
plugin_common_write_digests_json() {
  local root="${1:-}"
  local out_file="${2:-}"
  [[ -n "$root" && -n "$out_file" ]] || return 1
  plugin_common_collect_digests_tsv "$root" | plugin_common_digests_tsv_to_json >"$out_file"
}

# Verify every journal digests entry matches files under root.
# Returns 0 when all present and matching; 1 when any missing/modified.
plugin_common_digests_verify() {
  local digests_json="${1:-}"
  local root="${2:-}"
  local tmp rel expected actual
  [[ -n "$digests_json" && -n "$root" && -d "$root" ]] || return 1
  if [[ "$digests_json" == "{}" ]]; then
    return 1
  fi
  tmp="$(mktemp)"
  printf '%s' "$digests_json" >"$tmp"
  if command -v jq >/dev/null 2>&1; then
    while IFS=$'\t' read -r rel expected; do
      [[ -n "$rel" ]] || continue
      if [[ ! -f "${root%/}/$rel" ]]; then
        rm -f "$tmp"
        return 1
      fi
      actual="$(plugin_common_file_sha256 "${root%/}/$rel")" || {
        rm -f "$tmp"
        return 1
      }
      if [[ "$actual" != "$expected" ]]; then
        rm -f "$tmp"
        return 1
      fi
    done < <(jq -r 'to_entries[] | "\(.key)\t\(.value)"' "$tmp")
    rm -f "$tmp"
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$tmp" "$root" <<'PY'
import hashlib, json, sys
digests_path, root = sys.argv[1], sys.argv[2]
with open(digests_path, encoding="utf-8") as fh:
    digests = json.load(fh)
for rel, expected in digests.items():
    path = f"{root.rstrip('/')}/{rel}"
    try:
        with open(path, "rb") as fh:
            actual = hashlib.sha256(fh.read()).hexdigest()
    except OSError:
        sys.exit(1)
    if actual != expected:
        sys.exit(1)
sys.exit(0)
PY
    local ec=$?
    rm -f "$tmp"
    return "$ec"
  fi
  rm -f "$tmp"
  return 1
}

# Resolve file-copy adapter state from target presence + digests + journal meta.
# Prints one of: absent|current|drifted|unverifiable
# host_present=1 when the install target / owned files exist on disk.
plugin_common_resolve_file_state() {
  local host_present="${1:-0}"
  local digests_ok="${2:-0}"
  local journal_json="${3:-}"
  local package_version="${4:-}"
  local package_source="${5:-}"
  local verify_ok="${6:-1}"  # 0 when hash tooling / IO failed

  if [[ "$verify_ok" != "1" ]]; then
    printf 'unverifiable\n'
    return 0
  fi
  if [[ "$host_present" != "1" ]]; then
    printf 'absent\n'
    return 0
  fi
  if [[ -z "$journal_json" ]]; then
    printf 'drifted\n'
    return 0
  fi
  if [[ "$digests_ok" != "1" ]]; then
    printf 'drifted\n'
    return 0
  fi
  if command -v jq >/dev/null 2>&1; then
    if printf '%s' "$journal_json" | jq -e \
      --arg v "$package_version" \
      --arg s "$package_source" '
        (.packageVersion // .package.version // "") == $v
        and (.packageSource // .package.source // "") == $s
      ' >/dev/null 2>&1; then
      printf 'current\n'
      return 0
    fi
    printf 'drifted\n'
    return 0
  fi
  printf 'drifted\n'
}

# Atomically replace dest directory with a full copy of src (complete package).
# Stages beside dest, swaps via rename, removes the previous tree only after success.
plugin_common_atomic_copy_tree() {
  local src="${1:-}"
  local dest="${2:-}"
  local parent stage backup
  [[ -n "$src" && -d "$src" && -n "$dest" ]] || return 1
  parent="$(dirname -- "$dest")"
  mkdir -p "$parent" || return 1
  stage="$(mktemp -d "${parent}/.ralph-plugin-stage.XXXXXX")" || return 1
  if ! cp -R "${src%/}/." "$stage/"; then
    rm -rf "$stage"
    return 1
  fi
  backup=""
  if [[ -e "$dest" ]]; then
    backup="$(mktemp -d "${parent}/.ralph-plugin-bak.XXXXXX")" || {
      rm -rf "$stage"
      return 1
    }
    # Move existing tree aside (contents into backup dir's parent slot).
    rm -rf "$backup"
    if ! mv "$dest" "$backup"; then
      rm -rf "$stage"
      return 1
    fi
  fi
  if ! mv "$stage" "$dest"; then
    if [[ -n "$backup" && -e "$backup" ]]; then
      mv "$backup" "$dest" || true
    fi
    rm -rf "$stage"
    return 1
  fi
  if [[ -n "$backup" ]]; then
    rm -rf "$backup"
  fi
  return 0
}

# Atomically write one file: create parents, stage beside dest, rename into place.
plugin_common_atomic_write_file() {
  local src="${1:-}"
  local dest="${2:-}"
  local parent tmp
  [[ -n "$src" && -f "$src" && -n "$dest" ]] || return 1
  parent="$(dirname -- "$dest")"
  mkdir -p "$parent" || return 1
  tmp="$(mktemp "${parent}/.ralph-plugin-file.XXXXXX")" || return 1
  if ! cp "$src" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! mv -f "$tmp" "$dest"; then
    rm -f "$tmp"
    return 1
  fi
  return 0
}

# Delete files listed in digests JSON under root only when digests still match.
# Refuses (return 1) if any listed file exists with a different digest.
# After deletes, prunes empty directories under root (including root if empty).
plugin_common_remove_owned_files() {
  local root="${1:-}"
  local digests_json="${2:-}"
  local tmp rel expected actual
  [[ -n "$root" && -n "$digests_json" ]] || return 1
  tmp="$(mktemp)"
  printf '%s' "$digests_json" >"$tmp"
  if ! command -v jq >/dev/null 2>&1; then
    rm -f "$tmp"
    printf 'plugin: jq required to remove owned files\n' >&2
    return 1
  fi
  # First pass: refuse modified targets.
  while IFS=$'\t' read -r rel expected; do
    [[ -n "$rel" ]] || continue
    if [[ ! -e "${root%/}/$rel" ]]; then
      continue
    fi
    if [[ ! -f "${root%/}/$rel" ]]; then
      rm -f "$tmp"
      printf 'plugin: refuse remove (non-file at owned path %s)\n' "$rel" >&2
      return 1
    fi
    actual="$(plugin_common_file_sha256 "${root%/}/$rel")" || {
      rm -f "$tmp"
      return 1
    }
    if [[ "$actual" != "$expected" ]]; then
      rm -f "$tmp"
      printf 'plugin: refuse remove (modified target %s)\n' "$rel" >&2
      return 1
    fi
  done < <(jq -r 'to_entries[] | "\(.key)\t\(.value)"' "$tmp")

  # Second pass: delete matching owned files only.
  while IFS=$'\t' read -r rel expected; do
    [[ -n "$rel" ]] || continue
    if [[ -f "${root%/}/$rel" ]]; then
      rm -f "${root%/}/$rel"
    fi
  done < <(jq -r 'to_entries[] | "\(.key)\t\(.value)"' "$tmp")
  rm -f "$tmp"

  plugin_common_prune_empty_dirs "$root"
}

# Remove empty directories under root (depth-first). Removes root when empty.
# Never deletes non-empty directories or files.
plugin_common_prune_empty_dirs() {
  local root="${1:-}"
  [[ -n "$root" && -d "$root" ]] || return 0
  find "${root%/}" -depth -type d -empty -delete 2>/dev/null || {
    # Portable fallback without -empty/-delete.
    local dir
    while IFS= read -r -d '' dir; do
      rmdir "$dir" 2>/dev/null || true
    done < <(find "${root%/}" -depth -type d -print0)
  }
  return 0
}

# Append one captured host command record to a JSON array file (creates if missing).
# Usage: plugin_common_command_capture <array-file> <exit-code> -- <argv...>
plugin_common_command_capture() {
  local array_file="${1:-}"
  local exit_code="${2:-}"
  shift 2 || return 1
  [[ "${1:-}" == "--" ]] && shift
  local at argv_json tmp
  [[ -n "$array_file" ]] || return 1
  at="$(plugin_common_utc_now)"
  if command -v jq >/dev/null 2>&1; then
    argv_json="$(jq -nc --args '$ARGS.positional' -- "$@")"
    if [[ ! -f "$array_file" ]]; then
      printf '[]\n' >"$array_file"
    fi
    tmp="$(mktemp "${array_file}.XXXXXX")"
    jq -c \
      --argjson argv "$argv_json" \
      --argjson exitCode "$exit_code" \
      --arg at "$at" \
      '. + [{argv:$argv, exitCode:$exitCode, at:$at}]' \
      "$array_file" >"$tmp"
    mv -f "$tmp" "$array_file"
    return 0
  fi
  python3 - "$array_file" "$exit_code" "$at" "$@" <<'PY'
import json, sys
path, exit_code, at = sys.argv[1], int(sys.argv[2]), sys.argv[3]
argv = sys.argv[4:]
try:
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
except (OSError, json.JSONDecodeError):
    data = []
if not isinstance(data, list):
    data = []
data.append({"argv": argv, "exitCode": exit_code, "at": at})
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh)
    fh.write("\n")
PY
}

# Run a host CLI, capture argv/exit into commands file, print stdout.
# Usage: plugin_common_host_run <commands-file> -- <argv...>
# Returns the host exit code.
plugin_common_host_run() {
  local commands_file="${1:-}"
  shift || return 1
  [[ "${1:-}" == "--" ]] && shift
  local out ec
  out="$(mktemp)"
  set +e
  "$@" >"$out" 2>"${out}.err"
  ec=$?
  set -e
  plugin_common_command_capture "$commands_file" "$ec" -- "$@" || true
  cat "$out"
  if [[ -s "${out}.err" ]]; then
    cat "${out}.err" >&2
  fi
  rm -f "$out" "${out}.err"
  return "$ec"
}

plugin_common_cli_missing() {
  local cli="${1:-}"
  [[ -n "$cli" ]] || return 0
  if command -v "$cli" >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

# True when list output mentions the Ralph package (name or @ralph-plugins ref).
# Accepts JSON lists (Claude/Codex) and plain-text host lists (Antigravity).
plugin_common_list_contains_ralph() {
  local list_json="${1:-}"
  local trimmed
  [[ -n "$list_json" ]] || return 1
  if command -v jq >/dev/null 2>&1; then
    if printf '%s' "$list_json" | jq -e '
      def hit:
        tostring
        | test("ralph-orchestrator(@ralph-plugins)?");
      (type == "array" and any(.[]; hit))
      or (type == "object" and (
            ((.installed // .plugins // .entries // []) | type == "array"
              and any(.[]?; hit))
            or hit
          ))
      or (type == "string" and hit)
    ' >/dev/null 2>&1; then
      return 0
    fi
    # Valid JSON that simply lacks Ralph must not fall through to grep
    # (avoids false positives on unrelated JSON text). Plain-text lists
    # from hosts such as `agy plugin list` are matched below.
    trimmed="$(printf '%s' "$list_json" | sed -e 's/^[[:space:]]*//')"
    case "$trimmed" in
      \{* | \[*) return 1 ;;
    esac
  fi
  printf '%s' "$list_json" | grep -Eq 'ralph-orchestrator(@ralph-plugins)?'
}

# Resolve adapter status from host presence + journal vs packaged meta.
# Prints one of: absent|current|drifted|unverifiable
plugin_common_resolve_state() {
  local host_ok="${1:-0}"          # 1 if list command succeeded
  local host_has_ralph="${2:-0}"   # 1 if list contains Ralph
  local journal_json="${3:-}"
  local package_version="${4:-}"
  local package_source="${5:-}"

  if [[ "$host_ok" != "1" ]]; then
    printf 'unverifiable\n'
    return 0
  fi
  if [[ "$host_has_ralph" != "1" ]]; then
    printf 'absent\n'
    return 0
  fi
  if [[ -z "$journal_json" ]]; then
    printf 'drifted\n'
    return 0
  fi
  if command -v jq >/dev/null 2>&1; then
    if printf '%s' "$journal_json" | jq -e \
      --arg v "$package_version" \
      --arg s "$package_source" '
        (.packageVersion // .package.version // "") == $v
        and (.packageSource // .package.source // "") == $s
      ' >/dev/null 2>&1; then
      printf 'current\n'
      return 0
    fi
    printf 'drifted\n'
    return 0
  fi
  printf 'drifted\n'
}

# Validate marketplace JSON resolves exactly ralph-orchestrator@ralph-plugins.
# Args: <marketplace-json-path>
plugin_common_marketplace_resolves_package_ref() {
  local market_path="${1:-}"
  [[ -f "$market_path" ]] || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -e --arg mid "$PLUGIN_COMMON_MARKETPLACE_NAME" --arg pid "$PLUGIN_COMMON_PLUGIN_ID" '
      .name == $mid
      and (.plugins | type == "array")
      and any(.plugins[]; .name == $pid)
    ' "$market_path" >/dev/null
    return $?
  fi
  python3 - "$market_path" "$PLUGIN_COMMON_MARKETPLACE_NAME" "$PLUGIN_COMMON_PLUGIN_ID" <<'PY'
import json, sys
path, mid, pid = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)
plugins = data.get("plugins")
ok = (
    data.get("name") == mid
    and isinstance(plugins, list)
    and any(isinstance(p, dict) and p.get("name") == pid for p in plugins)
)
sys.exit(0 if ok else 1)
PY
}

plugin_common_preview_line() {
  # Print a preview argv as a single shell-quoted line.
  local out="" arg
  for arg in "$@"; do
    printf -v out '%s%s%q' "$out" "${out:+ }" "$arg"
  done
  printf '%s\n' "$out"
}
