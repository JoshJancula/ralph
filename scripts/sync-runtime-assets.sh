#!/usr/bin/env bash
# Sync canonical rules, skills, and agent bodies into per-runtime directories.
#
# Canonical sources:
#   root layer   - agents/rules/*.md, agents/skills/<id>/SKILL.md
#                  agents/agents/<id>.md
#   bundle layer - bundle/.ralph/rules/*.md, bundle/.ralph/skills/<id>/SKILL.md
#                  bundle/.ralph/agents/<id>.md
#
# Generated targets (root layer at repo root; bundle layer under bundle/):
#   .<runtime>/rules/<name>.md (.mdc for cursor)
#   .<runtime>/skills/<id>/SKILL.md
#   .<runtime>/agents/<id>/<id>.md  (.toml for codex)
#
# Usage:
#   bash scripts/sync-runtime-assets.sh [--check] [--layer root|bundle]
#
# Default writes both layers. --check compares without writing and exits nonzero
# when any generated file is missing, differs, or is stale.
set -euo pipefail

SCRIPT_DIR="${SCRIPT_DIR:-}"
if [[ -z "$SCRIPT_DIR" ]]; then
  _sync_script_ref="${BASH_SOURCE[0]}"
  if [[ -L "$_sync_script_ref" ]]; then
    _sync_script_dir="$(cd "$(dirname "$_sync_script_ref")" && pwd)"
    _sync_script_ref="$(cd "$_sync_script_dir" && cd "$(dirname "$(readlink "$_sync_script_ref")")" && pwd)/$(basename "$(readlink "${BASH_SOURCE[0]}")")"
  fi
  SCRIPT_DIR="$(cd "$(dirname "$_sync_script_ref")" && pwd)"
fi
if [[ -z "${REPO_ROOT:-}" ]]; then
  REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

if ! declare -F ralph_runtime_config_dirname >/dev/null 2>&1; then
  for runtime_normalize_path in \
    "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-normalize.sh" \
    "$REPO_ROOT/.ralph/bash-lib/runtime-normalize.sh"; do
    if [[ -r "$runtime_normalize_path" ]]; then
      # shellcheck source=/dev/null
      source "$runtime_normalize_path"
      break
    fi
  done
fi

if ! declare -F agent_source_fm_scalar >/dev/null 2>&1; then
  for frontmatter_path in \
    "$REPO_ROOT/bundle/.ralph/bash-lib/agent-source/frontmatter.sh" \
    "$REPO_ROOT/.ralph/bash-lib/agent-source/frontmatter.sh"; do
    if [[ -r "$frontmatter_path" ]]; then
      # shellcheck source=/dev/null
      source "$frontmatter_path"
      break
    fi
  done
fi

if ! declare -F ralph_validate_skill_package >/dev/null 2>&1; then
  for skill_package_path in \
    "$REPO_ROOT/bundle/.ralph/bash-lib/agent-config/skill-package.sh" \
    "$REPO_ROOT/.ralph/bash-lib/agent-config/skill-package.sh" \
    "$SCRIPT_DIR/../bundle/.ralph/bash-lib/agent-config/skill-package.sh"; do
    if [[ -r "$skill_package_path" ]]; then
      # shellcheck source=/dev/null
      source "$skill_package_path"
      break
    fi
  done
fi

RUNTIMES=(claude codex opencode cursor antigravity)
AGENT_IDS=(architect code-review implementation qa research security)
MARKER_PREFIX='<!-- GENERATED from '
MARKER_SUFFIX=' by scripts/sync-runtime-assets.sh - edit the canonical file -->'

CHECK_MODE=0
LAYER_SCOPE="both"
ISSUES=0

sync_assets_usage() {
  cat <<'EOF' >&2
Usage: sync-runtime-assets.sh [--check] [--layer root|bundle]

Regenerate per-runtime rules and skills from canonical sources.

Options:
  --check           Compare generated files without writing; exit nonzero on drift.
  --layer LAYER     Restrict to root or bundle layer (default: both).
  -h, --help        Show this help.
EOF
  exit 1
}

sync_assets_parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --check)
        CHECK_MODE=1
        ;;
      --layer)
        [[ $# -ge 2 ]] || sync_assets_usage
        case "$2" in
          root | bundle) LAYER_SCOPE="$2" ;;
          *) sync_assets_usage ;;
        esac
        shift
        ;;
      -h | --help)
        sync_assets_usage
        ;;
      *)
        sync_assets_usage
        ;;
    esac
    shift
  done
}

sync_assets_report_issue() {
  if [[ "$CHECK_MODE" -eq 1 ]]; then
    printf '%s\n' "$1"
    ISSUES=1
  fi
}

sync_assets_layer_rules_canonical() {
  local layer="$1"
  if [[ "$layer" == "root" ]]; then
    printf '%s\n' "agents/rules"
  else
    printf '%s\n' "bundle/.ralph/rules"
  fi
}

sync_assets_layer_skills_canonical() {
  local layer="$1"
  if [[ "$layer" == "root" ]]; then
    printf '%s\n' "agents/skills"
  else
    printf '%s\n' "bundle/.ralph/skills"
  fi
}

sync_assets_layer_agents_canonical() {
  local layer="$1"
  if [[ "$layer" == "root" ]]; then
    printf '%s\n' "agents/agents"
  else
    printf '%s\n' "bundle/.ralph/agents"
  fi
}

sync_assets_layer_dest_prefix() {
  local layer="$1"
  if [[ "$layer" == "root" ]]; then
    printf '%s' ""
  else
    printf '%s' "bundle/"
  fi
}

sync_assets_runtime_config_dirname() {
  ralph_runtime_config_dirname "$1"
}

sync_assets_json_string() {
  agent_source_json_string "$@"
}

sync_assets_frontmatter_scalar() {
  agent_source_fm_scalar "$@"
}

sync_assets_frontmatter_model() {
  agent_source_fm_model "$@"
}

sync_assets_frontmatter_list() {
  agent_source_fm_list "$@"
}

sync_assets_frontmatter_body() {
  agent_source_fm_body "$@"
}

sync_assets_frontmatter_artifact_json() {
  agent_source_fm_artifact "$@"
}

sync_assets_rule_dest_basename() {
  local runtime="$1"
  local rule_name="$2"
  local base="${rule_name%.md}"
  if [[ "$runtime" == "cursor" ]]; then
    printf '%s.mdc\n' "$base"
  else
    printf '%s.md\n' "$base"
  fi
}

sync_assets_render_with_marker() {
  local canonical_rel="$1"
  local marker="${MARKER_PREFIX}${canonical_rel}${MARKER_SUFFIX}"
  awk -v marker="$marker" '
    BEGIN { in_frontmatter = 0; inserted = 0 }
    /^---$/ {
      if (in_frontmatter == 0) {
        in_frontmatter = 1
        print
        next
      }
      if (in_frontmatter == 1 && inserted == 0) {
        print
        print marker
        inserted = 1
        next
      }
    }
    { print }
  ' "$REPO_ROOT/$canonical_rel"
}

sync_assets_parse_inline_array() {
  # Convert an inline YAML array literal like ["a", "b"] into one item per line
  # (unquoted). Canonical rule globs never contain commas inside quotes, so a
  # simple comma split is sufficient.
  local raw="$1"
  printf '%s' "$raw" | sed -E 's/^[[:space:]]*\[//; s/\][[:space:]]*$//' | awk -F',' '{
    for (i = 1; i <= NF; i++) {
      v = $i
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      gsub(/^"|"$/, "", v)
      gsub(/^\x27|\x27$/, "", v)
      if (v != "") print v
    }
  }'
}

# Render a rule file for a specific runtime, transforming the canonical
# Cursor-style frontmatter (globs + alwaysApply) into each runtime's native
# schema. cursor/codex/opencode keep the verbatim canonical frontmatter (cursor
# is native; codex/opencode consume the file through Ralph's own injection only).
sync_assets_render_rule_for_runtime() {
  local runtime="$1"
  local canonical_rel="$2"
  local canonical_abs="$REPO_ROOT/$canonical_rel"
  local marker="${MARKER_PREFIX}${canonical_rel}${MARKER_SUFFIX}"

  case "$runtime" in
    cursor | codex | opencode)
      sync_assets_render_with_marker "$canonical_rel"
      return 0
      ;;
  esac

  local name description always_apply globs_raw
  name="$(agent_source_fm_scalar "$canonical_abs" "name")"
  description="$(agent_source_fm_scalar "$canonical_abs" "description")"
  always_apply="$(agent_source_fm_scalar "$canonical_abs" "alwaysApply")"
  globs_raw="$(agent_source_fm_scalar "$canonical_abs" "globs")"

  local -a globs=()
  local glob
  while IFS= read -r glob; do
    [[ -n "$glob" ]] || continue
    globs+=("$glob")
  done < <(sync_assets_parse_inline_array "$globs_raw")

  local is_always=0
  [[ "$always_apply" == "true" ]] && is_always=1

  printf -- '---\n'
  [[ -n "$name" ]] && printf 'name: %s\n' "$name"
  [[ -n "$description" ]] && printf 'description: %s\n' "$description"

  case "$runtime" in
    claude)
      # Native Claude rules use `paths`; a rule with no `paths` loads always.
      if [[ "$is_always" -eq 0 && "${#globs[@]}" -gt 0 ]]; then
        printf 'paths:\n'
        for glob in "${globs[@]}"; do
          printf '  - "%s"\n' "$glob"
        done
      fi
      ;;
    antigravity)
      # Native Antigravity rules use `trigger` for activation.
      if [[ "$is_always" -eq 1 || "${#globs[@]}" -eq 0 ]]; then
        printf 'trigger: always_on\n'
      else
        printf 'trigger: glob\n'
        printf 'globs:\n'
        for glob in "${globs[@]}"; do
          printf '  - "%s"\n' "$glob"
        done
      fi
      ;;
  esac

  printf -- '---\n'
  printf '%s\n' "$marker"
  agent_source_fm_body "$canonical_abs"
}

sync_assets_has_marker() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  grep -q 'GENERATED from .* by scripts/sync-runtime-assets.sh' "$file"
}

sync_assets_extract_canonical_rel() {
  local file="$1"
  local rel=""
  rel="$(sed -n 's/.*GENERATED from \([^ ]*\) by scripts\/sync-runtime-assets\.sh.*/\1/p' "$file" | head -1)"
  [[ -n "$rel" ]] || return 1
  printf '%s' "$rel"
}

sync_assets_expected_rule_dest() {
  local layer="$1"
  local runtime="$2"
  local rule_name="$3"
  local prefix dest_base runtime_dir
  prefix="$(sync_assets_layer_dest_prefix "$layer")"
  dest_base="$(sync_assets_rule_dest_basename "$runtime" "$rule_name")"
  runtime_dir="$(sync_assets_runtime_config_dirname "$runtime")"
  printf '%s%s/rules/%s\n' "$prefix" "$runtime_dir" "$dest_base"
}

sync_assets_expected_skill_dest() {
  local layer="$1"
  local runtime="$2"
  local skill_id="$3"
  local prefix runtime_dir
  prefix="$(sync_assets_layer_dest_prefix "$layer")"
  runtime_dir="$(sync_assets_runtime_config_dirname "$runtime")"
  printf '%s%s/skills/%s/SKILL.md\n' "$prefix" "$runtime_dir" "$skill_id"
}

sync_assets_expected_agent_dest() {
  local layer="$1"
  local runtime="$2"
  local agent_id="$3"
  local prefix runtime_dir ext
  prefix="$(sync_assets_layer_dest_prefix "$layer")"
  runtime_dir="$(sync_assets_runtime_config_dirname "$runtime")"
  if [[ "$runtime" == "codex" ]]; then
    ext="toml"
  else
    ext="md"
  fi
  printf '%s%s/agents/%s/%s.%s\n' "$prefix" "$runtime_dir" "$agent_id" "$agent_id" "$ext"
}

sync_assets_expected_agent_config_dest() {
  local layer="$1"
  local runtime="$2"
  local agent_id="$3"
  local prefix runtime_dir
  prefix="$(sync_assets_layer_dest_prefix "$layer")"
  runtime_dir="$(sync_assets_runtime_config_dirname "$runtime")"
  printf '%s%s/agents/%s/config.json\n' "$prefix" "$runtime_dir" "$agent_id"
}

sync_assets_check_or_write_file() {
  local dest_rel="$1"
  local canonical_rel="$2"
  local runtime="$3"
  local dest_abs="$REPO_ROOT/$dest_rel"
  local expected_file
  expected_file="$(mktemp)"
  sync_assets_render_rule_for_runtime "$runtime" "$canonical_rel" >"$expected_file"

  if [[ ! -f "$dest_abs" ]]; then
    sync_assets_report_issue "missing: $dest_rel"
    if [[ "$CHECK_MODE" -eq 0 ]]; then
      mkdir -p "$(dirname "$dest_abs")"
      cp "$expected_file" "$dest_abs"
    fi
    rm -f "$expected_file"
    return 0
  fi

  if ! sync_assets_has_marker "$dest_abs"; then
    rm -f "$expected_file"
    return 0
  fi

  if ! cmp -s "$expected_file" "$dest_abs"; then
    sync_assets_report_issue "differs: $dest_rel"
    if [[ "$CHECK_MODE" -eq 0 ]]; then
      cp "$expected_file" "$dest_abs"
    fi
  fi

  rm -f "$expected_file"
}

sync_assets_sync_rules_for_layer() {
  local layer="$1"
  local rules_canonical runtime rule_path rule_name dest_rel
  rules_canonical="$(sync_assets_layer_rules_canonical "$layer")"
  local rules_dir="$REPO_ROOT/$rules_canonical"

  [[ -d "$rules_dir" ]] || return 0

  while IFS= read -r rule_path; do
    [[ -n "$rule_path" ]] || continue
    rule_name="$(basename "$rule_path")"
    for runtime in "${RUNTIMES[@]}"; do
      dest_rel="$(sync_assets_expected_rule_dest "$layer" "$runtime" "$rule_name")"
      sync_assets_check_or_write_file "$dest_rel" "$rules_canonical/$rule_name" "$runtime"
    done
  done < <(find "$rules_dir" -maxdepth 1 -type f -name '*.md' | LC_ALL=C sort)
}

sync_assets_skill_package_py() {
  local candidate=""
  for candidate in \
    "$REPO_ROOT/bundle/.ralph/python/skill_package.py" \
    "$REPO_ROOT/.ralph/python/skill_package.py" \
    "$SCRIPT_DIR/../bundle/.ralph/python/skill_package.py"; do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

sync_assets_skill_manifest_rel() {
  local layer="$1"
  local runtime="$2"
  local skill_id="$3"
  local dest_dir
  dest_dir="$(dirname "$(sync_assets_expected_skill_dest "$layer" "$runtime" "$skill_id")")"
  printf '%s/.ralph-sync-manifest.json\n' "$dest_dir"
}

sync_assets_list_skill_resources() {
  local package_dir="$1"
  local py_script
  py_script="$(sync_assets_skill_package_py)" || return 0
  python3 "$py_script" list-resources --package-dir "$package_dir" 2>/dev/null || true
}

sync_assets_render_skill_native() {
  local canonical_abs="$1"
  cat "$canonical_abs"
}

sync_assets_render_skill_marked() {
  local canonical_rel="$1"
  sync_assets_render_with_marker "$canonical_rel"
}

sync_assets_write_skill_manifest() {
  local manifest_abs="$1"
  local canonical_rel="$2"
  shift 2
  local resources=("$@")
  local py_script
  py_script="$(sync_assets_skill_package_py)" || return 0
  python3 -c "
import json, sys
canonical = sys.argv[1]
resources = [item for item in sys.argv[2:] if item]
payload = {
    '_generated': 'GENERATED by scripts/sync-runtime-assets.sh - do not edit',
    'canonical': canonical,
    'resources': resources,
}
print(json.dumps(payload, indent=2, sort_keys=True))
print()
" "$canonical_rel" "${resources[@]}" >"$manifest_abs"
}

sync_assets_check_or_write_bytes() {
  local dest_rel="$1"
  local expected_file="$2"
  local dest_abs="$REPO_ROOT/$dest_rel"

  if [[ ! -f "$dest_abs" ]]; then
    sync_assets_report_issue "missing: $dest_rel"
    if [[ "$CHECK_MODE" -eq 0 ]]; then
      mkdir -p "$(dirname "$dest_abs")"
      cp "$expected_file" "$dest_abs"
    fi
    return 0
  fi

  if ! cmp -s "$expected_file" "$dest_abs"; then
    sync_assets_report_issue "differs: $dest_rel"
    if [[ "$CHECK_MODE" -eq 0 ]]; then
      cp "$expected_file" "$dest_abs"
    fi
  fi
}

sync_assets_check_or_write_skill() {
  local layer="$1"
  local runtime="$2"
  local skill_id="$3"
  local canonical_rel="$4"
  local native_layout="$5"
  local dest_rel expected_file
  dest_rel="$(sync_assets_expected_skill_dest "$layer" "$runtime" "$skill_id")"
  expected_file="$(mktemp)"
  if [[ "$native_layout" -eq 1 ]]; then
    sync_assets_render_skill_native "$REPO_ROOT/$canonical_rel" >"$expected_file"
    sync_assets_check_or_write_bytes "$dest_rel" "$expected_file"
    rm -f "$expected_file"
    return 0
  fi
  sync_assets_render_skill_marked "$canonical_rel" >"$expected_file"
  local dest_abs="$REPO_ROOT/$dest_rel"
  if [[ ! -f "$dest_abs" ]]; then
    sync_assets_report_issue "missing: $dest_rel"
    if [[ "$CHECK_MODE" -eq 0 ]]; then
      mkdir -p "$(dirname "$dest_abs")"
      cp "$expected_file" "$dest_abs"
    fi
    rm -f "$expected_file"
    return 0
  fi
  if ! sync_assets_has_marker "$dest_abs"; then
    rm -f "$expected_file"
    return 0
  fi
  if ! cmp -s "$expected_file" "$dest_abs"; then
    sync_assets_report_issue "differs: $dest_rel"
    if [[ "$CHECK_MODE" -eq 0 ]]; then
      cp "$expected_file" "$dest_abs"
    fi
  fi
  rm -f "$expected_file"
}

sync_assets_check_or_write_skill_resources() {
  local layer="$1"
  local runtime="$2"
  local skill_id="$3"
  local package_dir="$4"
  local canonical_rel="$5"
  local dest_skill_dir manifest_rel manifest_abs resource rel expected_file dest_rel
  dest_skill_dir="$REPO_ROOT/$(dirname "$(sync_assets_expected_skill_dest "$layer" "$runtime" "$skill_id")")"
  manifest_rel="$(sync_assets_skill_manifest_rel "$layer" "$runtime" "$skill_id")"
  manifest_abs="$REPO_ROOT/$manifest_rel"

  local -a resources=()
  while IFS= read -r resource; do
    [[ -n "$resource" ]] || continue
    resources+=("$resource")
  done < <(sync_assets_list_skill_resources "$package_dir")

  local -a stale_resources=()
  if [[ -f "$manifest_abs" ]] && command -v python3 >/dev/null 2>&1; then
    while IFS= read -r stale_rel; do
      [[ -n "$stale_rel" ]] || continue
      stale_resources+=("$stale_rel")
    done < <(python3 -c "
import json, sys
manifest_path, canonical, current = sys.argv[1], sys.argv[2], sys.argv[3:]
try:
    with open(manifest_path, encoding='utf-8') as handle:
        data = json.load(handle)
except Exception:
    sys.exit(0)
if data.get('canonical') != canonical:
    sys.exit(0)
previous = data.get('resources') or []
for rel in previous:
    if rel not in current:
        print(rel)
" "$manifest_abs" "$canonical_rel" "${resources[@]}")
  fi

  expected_file="$(mktemp)"
  sync_assets_write_skill_manifest "$expected_file" "$canonical_rel" "${resources[@]}"
  sync_assets_check_or_write_bytes "$manifest_rel" "$expected_file"
  rm -f "$expected_file"

  for resource in "${resources[@]}"; do
    expected_file="$(mktemp)"
    cp "$package_dir/$resource" "$expected_file"
    dest_rel="$(dirname "$(sync_assets_expected_skill_dest "$layer" "$runtime" "$skill_id")")/$resource"
    sync_assets_check_or_write_bytes "$dest_rel" "$expected_file"
    rm -f "$expected_file"
  done

  for resource in "${stale_resources[@]}"; do
    local stale_abs="$dest_skill_dir/$resource"
    [[ -f "$stale_abs" ]] || continue
    sync_assets_report_issue "stale: ${stale_abs#"$REPO_ROOT"/}"
    if [[ "$CHECK_MODE" -eq 0 ]]; then
      rm -f "$stale_abs"
    fi
  done
}

sync_assets_sync_skills_for_layer() {
  local layer="$1"
  local skills_canonical runtime skill_path skill_id dest_rel package_dir canonical_rel native_layout
  skills_canonical="$(sync_assets_layer_skills_canonical "$layer")"
  local skills_dir="$REPO_ROOT/$skills_canonical"

  [[ -d "$skills_dir" ]] || return 0

  while IFS= read -r skill_path; do
    [[ -n "$skill_path" ]] || continue
    skill_id="$(basename "$(dirname "$skill_path")")"
    package_dir="$(dirname "$skill_path")"
    canonical_rel="${skills_canonical}/${skill_id}/SKILL.md"
    if ! ralph_validate_skill_package "$package_dir" "$skill_id"; then
      echo "skill package validation failed: $canonical_rel" >&2
      ISSUES=1
      continue
    fi
    for runtime in "${RUNTIMES[@]}"; do
      native_layout=0
      if [[ "$runtime" == "claude" ]] && ralph_claude_native_skill_layout "$layer"; then
        native_layout=1
      fi
      sync_assets_check_or_write_skill "$layer" "$runtime" "$skill_id" "$canonical_rel" "$native_layout"
      if ralph_runtime_supports_skill_resources "$runtime"; then
        sync_assets_check_or_write_skill_resources "$layer" "$runtime" "$skill_id" "$package_dir" "$canonical_rel"
      fi
    done
  done < <(find "$skills_dir" -mindepth 2 -maxdepth 2 -type f -name 'SKILL.md' | LC_ALL=C sort)
}

sync_assets_rule_glob_for_runtime() {
  local runtime="$1"
  if [[ "$runtime" == "cursor" ]]; then
    printf '%s\n' '*.mdc'
  else
    printf '%s\n' '*.md'
  fi
}

sync_assets_handle_stale_in_dir() {
  local dir_abs="$1"
  local glob_pattern="$2"
  local file canonical_rel

  [[ -d "$dir_abs" ]] || return 0

  shopt -s nullglob
  local files=("$dir_abs"/$glob_pattern)
  shopt -u nullglob

  for file in "${files[@]}"; do
    [[ -f "$file" ]] || continue
    sync_assets_has_marker "$file" || continue
    canonical_rel="$(sync_assets_extract_canonical_rel "$file")" || {
      sync_assets_report_issue "stale: ${file#"$REPO_ROOT"/}"
      if [[ "$CHECK_MODE" -eq 0 ]]; then
        rm -f "$file"
      fi
      continue
    }
    if [[ ! -f "$REPO_ROOT/$canonical_rel" ]]; then
      sync_assets_report_issue "stale: ${file#"$REPO_ROOT"/}"
      if [[ "$CHECK_MODE" -eq 0 ]]; then
        rm -f "$file"
      fi
    fi
  done
}

sync_assets_handle_stale_skills_in_dir() {
  local dir_abs="$1"
  local skill_dir skill_file canonical_rel manifest_file

  [[ -d "$dir_abs" ]] || return 0

  shopt -s nullglob
  local skill_dirs=("$dir_abs"/*/)
  shopt -u nullglob

  for skill_dir in "${skill_dirs[@]}"; do
    [[ -d "$skill_dir" ]] || continue
    skill_file="$skill_dir/SKILL.md"
    manifest_file="$skill_dir/.ralph-sync-manifest.json"
    if [[ -f "$manifest_file" ]]; then
      canonical_rel="$(python3 -c "
import json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as handle:
        data = json.load(handle)
except Exception:
    sys.exit(0)
print(data.get('canonical', ''))
" "$manifest_file" 2>/dev/null || true)"
      if [[ -n "$canonical_rel" && ! -f "$REPO_ROOT/$canonical_rel" ]]; then
        sync_assets_report_issue "stale: ${skill_dir#"$REPO_ROOT"/}"
        if [[ "$CHECK_MODE" -eq 0 ]]; then
          rm -rf "$skill_dir"
        fi
        continue
      fi
    fi
    [[ -f "$skill_file" ]] || continue
    sync_assets_has_marker "$skill_file" || continue
    canonical_rel="$(sync_assets_extract_canonical_rel "$skill_file")" || {
      sync_assets_report_issue "stale: ${skill_file#"$REPO_ROOT"/}"
      if [[ "$CHECK_MODE" -eq 0 ]]; then
        rm -rf "$skill_dir"
      fi
      continue
    }
    if [[ ! -f "$REPO_ROOT/$canonical_rel" ]]; then
      sync_assets_report_issue "stale: ${skill_file#"$REPO_ROOT"/}"
      if [[ "$CHECK_MODE" -eq 0 ]]; then
        rm -rf "$skill_dir"
      fi
    fi
  done
}

sync_assets_prune_stale_for_layer() {
  local layer="$1"
  local prefix runtime rules_dir skills_dir agents_dir rule_glob ext registry_dir registry_rel registry_abs canonical_rel
  prefix="$(sync_assets_layer_dest_prefix "$layer")"

  for runtime in "${RUNTIMES[@]}"; do
    rules_dir="$REPO_ROOT/${prefix}$(sync_assets_runtime_config_dirname "$runtime")/rules"
    skills_dir="$REPO_ROOT/${prefix}$(sync_assets_runtime_config_dirname "$runtime")/skills"
    rule_glob="$(sync_assets_rule_glob_for_runtime "$runtime")"
    sync_assets_handle_stale_in_dir "$rules_dir" "$rule_glob"
    sync_assets_handle_stale_skills_in_dir "$skills_dir"
    ext="md"
    [[ "$runtime" == "codex" ]] && ext="toml"
    agents_dir="$REPO_ROOT/${prefix}$(sync_assets_runtime_config_dirname "$runtime")/agents"
    sync_assets_handle_stale_agents_in_dir "$agents_dir" "$ext"
  done

  registry_rel="$(sync_assets_expected_antigravity_registry_dest "$layer")"
  registry_abs="$REPO_ROOT/$registry_rel"
  if [[ -f "$registry_abs" ]] && sync_assets_has_marker "$registry_abs"; then
    canonical_rel="$(sync_assets_extract_canonical_rel "$registry_abs")" || canonical_rel=""
    if [[ -z "$canonical_rel" || ! -e "$REPO_ROOT/$canonical_rel" ]]; then
      sync_assets_report_issue "stale: $registry_rel"
      if [[ "$CHECK_MODE" -eq 0 ]]; then
        rm -f "$registry_abs"
      fi
    fi
  fi
}

sync_assets_agent_canonical_rel() {
  local layer="$1"
  local agent_id="$2"
  local agents_canonical
  agents_canonical="$(sync_assets_layer_agents_canonical "$layer")"
  printf '%s/%s.md\n' "$agents_canonical" "$agent_id"
}

sync_assets_agent_canonical_abs() {
  local layer="$1"
  local agent_id="$2"
  printf '%s/%s' "$REPO_ROOT" "$(sync_assets_agent_canonical_rel "$layer" "$agent_id")"
}

sync_assets_agent_description() {
  local canonical_abs="$1"
  sync_assets_frontmatter_scalar "$canonical_abs" "description"
}

sync_assets_agent_model() {
  local canonical_abs="$1"
  local runtime="$2"
  sync_assets_frontmatter_model "$canonical_abs" "$runtime"
}

sync_assets_agent_allowed_tools() {
  local canonical_abs="$1"
  sync_assets_frontmatter_list "$canonical_abs" "allowed_tools"
}

sync_assets_agent_rules_list() {
  local canonical_abs="$1"
  local runtime="$2"
  local list_key="rules"
  if [[ "$runtime" == "antigravity" ]]; then
    if [[ -n "$(sync_assets_frontmatter_list "$canonical_abs" "rules_antigravity" | head -1)" ]]; then
      list_key="rules_antigravity"
    fi
  fi
  sync_assets_frontmatter_list "$canonical_abs" "$list_key"
}

sync_assets_agent_skills_list() {
  local canonical_abs="$1"
  sync_assets_frontmatter_list "$canonical_abs" "skills"
}

sync_assets_agent_output_artifacts_list() {
  local canonical_abs="$1"
  sync_assets_frontmatter_list "$canonical_abs" "output_artifacts"
}

sync_assets_agent_mcp_servers_list() {
  local canonical_abs="$1"
  local mcp_script
  mcp_script="$REPO_ROOT/bundle/.ralph/python/agent-config-mcp.py"
  if [[ ! -f "$mcp_script" ]] || ! command -v python3 >/dev/null 2>&1; then
    return 0
  fi
  python3 "$mcp_script" --frontmatter "$canonical_abs" 2>/dev/null || true
}

sync_assets_agent_max_budget() {
  local canonical_abs="$1"
  sync_assets_frontmatter_scalar "$canonical_abs" "max_budget_usd"
}

sync_assets_agent_reasoning_effort() {
  local canonical_abs="$1"
  sync_assets_frontmatter_scalar "$canonical_abs" "reasoning_effort"
}

sync_assets_agent_version() {
  local canonical_abs="$1"
  sync_assets_frontmatter_scalar "$canonical_abs" "version"
}

sync_assets_agent_rule_path() {
  local layer="$1"
  local runtime="$2"
  local rule_name="$3"
  local prefix runtime_dir
  prefix="$(sync_assets_layer_dest_prefix "$layer")"
  runtime_dir="$(sync_assets_runtime_config_dirname "$runtime")"
  printf '%s%s/rules/%s\n' "$prefix" "$runtime_dir" "$(sync_assets_rule_dest_basename "$runtime" "$rule_name")"
}

sync_assets_agent_skill_path() {
  local layer="$1"
  local runtime="$2"
  local skill_id="$3"
  local prefix runtime_dir
  prefix="$(sync_assets_layer_dest_prefix "$layer")"
  runtime_dir="$(sync_assets_runtime_config_dirname "$runtime")"
  printf '%s%s/skills/%s/SKILL.md\n' "$prefix" "$runtime_dir" "$skill_id"
}

sync_assets_agent_config_path() {
  local layer="$1"
  local runtime="$2"
  local agent_id="$3"
  local prefix runtime_dir
  prefix="$(sync_assets_layer_dest_prefix "$layer")"
  runtime_dir="$(sync_assets_runtime_config_dirname "$runtime")"
  printf '%s%s/agents/%s/config.json\n' "$prefix" "$runtime_dir" "$agent_id"
}

sync_assets_render_agent_config_json() {
  local layer="$1"
  local runtime="$2"
  local agent_id="$3"
  local canonical_abs="$4"
  local canonical_rel="$5"
  local description model max_budget reasoning_effort version rules skills artifacts allowed_tools

  description="$(sync_assets_agent_description "$canonical_abs")"
  model="$(sync_assets_agent_model "$canonical_abs" "$runtime")"
  max_budget="$(sync_assets_agent_max_budget "$canonical_abs")"
  reasoning_effort="$(sync_assets_agent_reasoning_effort "$canonical_abs")"
  version="$(sync_assets_agent_version "$canonical_abs")"
  rules="$(sync_assets_agent_rules_list "$canonical_abs" "$runtime")"
  skills="$(sync_assets_agent_skills_list "$canonical_abs")"
  artifacts="$(sync_assets_agent_output_artifacts_list "$canonical_abs")"
  allowed_tools="$(sync_assets_agent_allowed_tools "$canonical_abs")"
  mcp_servers="$(sync_assets_agent_mcp_servers_list "$canonical_abs")"

  printf '{\n'
  printf '  "name": %s,\n' "$(sync_assets_json_string "$agent_id")"
  printf '  "_generated": %s,\n' "$(sync_assets_json_string "GENERATED from ${canonical_rel} by scripts/sync-runtime-assets.sh - edit the canonical file")"
  printf '  "model": %s,\n' "$(sync_assets_json_string "$model")"
  if [[ -n "$max_budget" ]]; then
    printf '  "max_budget_usd": %s,\n' "$(sync_assets_json_string "$max_budget")"
  fi
  if [[ -n "$reasoning_effort" ]]; then
    printf '  "reasoning_effort": %s,\n' "$(sync_assets_json_string "$reasoning_effort")"
  fi
  if [[ -n "$version" ]]; then
    printf '  "version": %s,\n' "$(sync_assets_json_string "$version")"
  fi
  printf '  "description": %s,\n' "$(sync_assets_json_string "$description")"
  printf '  "rules": [\n'
  local first=1 rule
  while IFS= read -r rule; do
    [[ -n "$rule" ]] || continue
    if [[ "$first" -eq 0 ]]; then
      printf ',\n'
    fi
    printf '    %s' "$(sync_assets_json_string "$(sync_assets_agent_rule_path "$layer" "$runtime" "$rule")")"
    first=0
  done <<< "$rules"
  if [[ "$first" -eq 1 ]]; then
    :
  fi
  printf '\n  ],\n'
  printf '  "skills": [\n'
  first=1
  local skill
  while IFS= read -r skill; do
    [[ -n "$skill" ]] || continue
    if [[ "$first" -eq 0 ]]; then
      printf ',\n'
    fi
    printf '    %s' "$(sync_assets_json_string "$(sync_assets_agent_skill_path "$layer" "$runtime" "$skill")")"
    first=0
  done <<< "$skills"
  printf '\n  ]'
  if [[ -n "$allowed_tools" ]]; then
    printf ',\n  "allowed_tools": [\n'
    first=1
    local tool
    while IFS= read -r tool; do
      [[ -n "$tool" ]] || continue
      if [[ "$first" -eq 0 ]]; then
        printf ',\n'
      fi
      printf '    %s' "$(sync_assets_json_string "$tool")"
      first=0
    done <<< "$allowed_tools"
    printf '\n  ]'
  fi
  if [[ -n "$artifacts" ]]; then
    printf ',\n  "output_artifacts": [\n'
    first=1
    local artifact
    while IFS= read -r artifact; do
      [[ -n "$artifact" ]] || continue
      if [[ "$first" -eq 0 ]]; then
        printf ',\n'
      fi
      printf '    %s' "$(sync_assets_frontmatter_artifact_json "$artifact")"
      first=0
    done <<< "$artifacts"
    printf '\n  ]'
  fi
  if [[ -n "$mcp_servers" ]]; then
    printf ',\n  "mcp_servers": [\n'
    first=1
    local entry
    while IFS= read -r entry; do
      [[ -n "$entry" ]] || continue
      if [[ "$first" -eq 0 ]]; then
        printf ',\n'
      fi
      printf '    %s' "$entry"
      first=0
    done <<< "$mcp_servers"
    printf '\n  ]'
  fi
  printf '\n}\n'
}

sync_assets_check_or_write_agent_config() {
  local dest_rel="$1"
  local layer="$2"
  local runtime="$3"
  local agent_id="$4"
  local canonical_abs="$5"
  local canonical_rel="$6"
  local dest_abs="$REPO_ROOT/$dest_rel"
  local expected_file
  expected_file="$(mktemp)"

  sync_assets_render_agent_config_json "$layer" "$runtime" "$agent_id" "$canonical_abs" "$canonical_rel" >"$expected_file"

  if [[ ! -f "$dest_abs" ]]; then
    sync_assets_report_issue "missing: $dest_rel"
    if [[ "$CHECK_MODE" -eq 0 ]]; then
      mkdir -p "$(dirname "$dest_abs")"
      cp "$expected_file" "$dest_abs"
    fi
    rm -f "$expected_file"
    return 0
  fi

  if ! cmp -s "$expected_file" "$dest_abs"; then
    sync_assets_report_issue "differs: $dest_rel"
    if [[ "$CHECK_MODE" -eq 0 ]]; then
      cp "$expected_file" "$dest_abs"
    fi
  fi

  rm -f "$expected_file"
}

sync_assets_render_agent_markdown() {
  local layer="$1"
  local runtime="$2"
  local agent_id="$3"
  local canonical_abs="$4"
  local canonical_rel="$5"
  local desc body marker model
  desc="$(sync_assets_agent_description "$canonical_abs")"
  body="$(sync_assets_frontmatter_body "$canonical_abs")"
  marker="${MARKER_PREFIX}${canonical_rel}${MARKER_SUFFIX}"
  model="$(sync_assets_agent_model "$canonical_abs" "$runtime")"

  case "$runtime" in
    claude)
      printf '%s\n' "---"
      printf '%s\n' "name: ${agent_id}"
      printf '%s\n' "description: >-"
      printf '%s\n' "  ${desc}"
      printf '%s\n' "model: ${model}"
      if [[ "$agent_id" == "research" ]]; then
        printf '%s\n' "tools:" "  - Read" "  - Grep" "  - Glob" "  - Bash" "  - Write"
      else
        printf '%s\n' "tools:" "  - Read" "  - Edit" "  - Write" "  - Grep" "  - Glob" "  - Bash"
      fi
      printf '%s\n' "skills:" "  - .claude/skills/repo-context/SKILL.md"
      printf '%s\n' "---"
      printf '%s\n' "${marker}"
      printf '\n'
      printf '%s\n' "$body"
      ;;
    cursor)
      printf '%s\n' "---"
      printf '%s\n' "name: ${agent_id}"
      printf '%s\n' "description: >-"
      printf '%s\n' "  ${desc}"
      printf '%s\n' "model: inherit"
      printf '%s\n' "readonly: false"
      printf '%s\n' "---"
      printf '%s\n' "${marker}"
      printf '\n'
      printf '%s\n' "$body"
      ;;
    opencode)
      printf '%s\n' "---"
      printf '%s\n' "name: ${agent_id}"
      printf '%s\n' "description: >-"
      printf '%s\n' "  ${desc}"
      printf '%s\n' "model: ${model}"
      if [[ "$agent_id" == "research" ]]; then
        printf '%s\n' "tools:" "  read: true" "  grep: true" "  glob: true" "  bash: true" "  write: true"
      else
        printf '%s\n' "tools:" "  read: true" "  edit: true" "  write: true" "  grep: true" "  glob: true" "  bash: true"
      fi
      printf '%s\n' "skills:" "  - .opencode/skills/repo-context/SKILL.md"
      printf '%s\n' "---"
      printf '%s\n' "${marker}"
      printf '\n'
      printf '%s\n' "$body"
      ;;
    antigravity)
      printf '%s\n' "---"
      printf '%s\n' "name: ${agent_id}"
      printf '%s\n' "description: ${desc}"
      printf '%s\n' "model: inherit"
      printf '%s\n' "---"
      printf '%s\n' "${marker}"
      printf '\n'
      printf '%s\n' "$body"
      ;;
    codex)
      printf '%s\n' "# GENERATED from ${canonical_rel} by scripts/sync-runtime-assets.sh - edit the canonical file"
      printf '%s\n' "# Codex custom agent: official subagent format (developers.openai.com/codex/subagents)"
      printf '\n'
      printf '%s\n' "name = \"${agent_id}\""
      printf '%s\n' "description = \"${desc}\""
      printf '\n'
      printf '%s\n' 'developer_instructions = """'
      printf '%s\n' "$body"
      printf '\n%s\n' '"""'
      ;;
  esac
}

sync_assets_check_or_write_agent() {
  local dest_rel="$1"
  local layer="$2"
  local runtime="$3"
  local agent_id="$4"
  local canonical_abs="$5"
  local canonical_rel="$6"
  local dest_abs="$REPO_ROOT/$dest_rel"
  local expected_file
  expected_file="$(mktemp)"

  sync_assets_render_agent_markdown "$layer" "$runtime" "$agent_id" "$canonical_abs" "$canonical_rel" >"$expected_file"

  if [[ ! -f "$dest_abs" ]]; then
    sync_assets_report_issue "missing: $dest_rel"
    if [[ "$CHECK_MODE" -eq 0 ]]; then
      mkdir -p "$(dirname "$dest_abs")"
      cp "$expected_file" "$dest_abs"
    fi
    rm -f "$expected_file"
    return 0
  fi

  if ! cmp -s "$expected_file" "$dest_abs"; then
    sync_assets_report_issue "differs: $dest_rel"
    if [[ "$CHECK_MODE" -eq 0 ]]; then
      cp "$expected_file" "$dest_abs"
    fi
  fi

  rm -f "$expected_file"
}

sync_assets_generate_antigravity_registry() {
  local layer="$1"
  local agents_canonical
  agents_canonical="$(sync_assets_layer_agents_canonical "$layer")"

  printf '%s\n' "# Ralph Antigravity Agent Registry"
  printf '%s\n' "${MARKER_PREFIX}${agents_canonical}${MARKER_SUFFIX}"
  printf '%s\n' ""
  printf '%s\n' "This file is the Antigravity-native team registry. Ralph also keeps machine-readable metadata under \`$agents_canonical/<agent-id>/config.json\` for \`run-plan.sh --agent\`, orchestration, MCP catalogs, output artifact validation, and model resolution."

  local agent_path agent_id canonical_abs desc
  while IFS= read -r agent_path; do
    [[ -f "$agent_path" ]] || continue
    agent_id="$(basename "$agent_path" .md)"
    canonical_abs="$agent_path"
    desc="$(sync_assets_agent_description "$canonical_abs")"
    printf '\n## @%s\n' "$agent_id"
    printf '%s\n' "$desc"
    printf '%s\n' ""
    printf '%s\n' "- Follow the corresponding Ralph metadata in \`$agents_canonical/$agent_id/config.json\` when this profile is used through \`run-plan.sh --agent $agent_id\`."
    printf '%s\n' "- Use \`$(sync_assets_layer_dest_prefix "$layer").agents/rules/\` and \`$(sync_assets_layer_dest_prefix "$layer").agents/skills/\` for Antigravity-native project guidance."
    printf '%s\n' "- Plain ASCII only; no emoji."
  done < <(find "$REPO_ROOT/$agents_canonical" -maxdepth 1 -type f -name '*.md' | LC_ALL=C sort)
}

sync_assets_expected_antigravity_registry_dest() {
  local layer="$1"
  local prefix
  prefix="$(sync_assets_layer_dest_prefix "$layer")"
  printf '%s.agents/agents.md\n' "$prefix"
}

sync_assets_check_or_write_registry() {
  local dest_rel="$1"
  local layer="$2"
  local dest_abs="$REPO_ROOT/$dest_rel"
  local expected_file
  expected_file="$(mktemp)"

  sync_assets_generate_antigravity_registry "$layer" >"$expected_file"

  if [[ ! -f "$dest_abs" ]]; then
    sync_assets_report_issue "missing: $dest_rel"
    if [[ "$CHECK_MODE" -eq 0 ]]; then
      mkdir -p "$(dirname "$dest_abs")"
      cp "$expected_file" "$dest_abs"
    fi
    rm -f "$expected_file"
    return 0
  fi

  if ! cmp -s "$expected_file" "$dest_abs"; then
    sync_assets_report_issue "differs: $dest_rel"
    if [[ "$CHECK_MODE" -eq 0 ]]; then
      cp "$expected_file" "$dest_abs"
    fi
  fi

  rm -f "$expected_file"
}

sync_assets_sync_agents_for_layer() {
  local layer="$1"
  local agents_canonical agents_dir agent_path canonical_rel canonical_abs agent_id runtime dest_rel cfg_rel
  agents_canonical="$(sync_assets_layer_agents_canonical "$layer")"
  agents_dir="$REPO_ROOT/$agents_canonical"
  [[ -d "$agents_dir" ]] || return 0

  while IFS= read -r agent_path; do
    [[ -f "$agent_path" ]] || continue
    agent_id="$(basename "$agent_path" .md)"
    canonical_abs="$agent_path"
    canonical_rel="${canonical_abs#"$REPO_ROOT"/}"
    if ! ralph_validate_agent_version "$canonical_abs" "$agent_id"; then
      echo "agent version validation failed: $canonical_rel" >&2
      ISSUES=1
      continue
    fi
    for runtime in "${RUNTIMES[@]}"; do
      dest_rel="$(sync_assets_expected_agent_dest "$layer" "$runtime" "$agent_id")"
      sync_assets_check_or_write_agent "$dest_rel" "$layer" "$runtime" "$agent_id" "$canonical_abs" "$canonical_rel"
      cfg_rel="$(sync_assets_expected_agent_config_dest "$layer" "$runtime" "$agent_id")"
      sync_assets_check_or_write_agent_config "$cfg_rel" "$layer" "$runtime" "$agent_id" "$canonical_abs" "$canonical_rel"
    done
  done < <(find "$agents_dir" -maxdepth 1 -type f -name '*.md' | LC_ALL=C sort)

  if [[ -n "$(find "$agents_dir" -maxdepth 1 -type f -name '*.md' | head -1)" ]]; then
    local registry_rel
    registry_rel="$(sync_assets_expected_antigravity_registry_dest "$layer")"
    sync_assets_check_or_write_registry "$registry_rel" "$layer"
  fi
}

sync_assets_handle_stale_agents_in_dir() {
  local runtime_agents_dir="$1"
  local ext="$2"

  [[ -d "$runtime_agents_dir" ]] || return 0

  shopt -s nullglob
  local agent_dirs=("$runtime_agents_dir"/*/)
  shopt -u nullglob

  local agent_dir agent_id file canonical_rel
  for agent_dir in "${agent_dirs[@]}"; do
    [[ -d "$agent_dir" ]] || continue
    agent_id="$(basename "$agent_dir")"
    local agent_file config_file stale_rel
    agent_file="${agent_dir}${agent_id}.${ext}"
    config_file="$agent_dir/config.json"
    stale_rel=""

    if [[ -f "$agent_file" ]] && sync_assets_has_marker "$agent_file"; then
      canonical_rel="$(sync_assets_extract_canonical_rel "$agent_file")" || canonical_rel=""
      if [[ -z "$canonical_rel" || ! -f "$REPO_ROOT/$canonical_rel" ]]; then
        stale_rel="${agent_file#"$REPO_ROOT"/}"
      fi
    fi

    if [[ -z "$stale_rel" && -f "$config_file" ]] && sync_assets_has_marker "$config_file"; then
      canonical_rel="$(sync_assets_extract_canonical_rel "$config_file")" || canonical_rel=""
      if [[ -z "$canonical_rel" || ! -f "$REPO_ROOT/$canonical_rel" ]]; then
        stale_rel="${config_file#"$REPO_ROOT"/}"
      fi
    fi

    if [[ -n "$stale_rel" ]]; then
      sync_assets_report_issue "stale: $stale_rel"
      if [[ "$CHECK_MODE" -eq 0 ]]; then
        rm -f "$agent_file" "$config_file"
      fi
    fi
  done
}

sync_assets_process_layer() {
  local layer="$1"
  sync_assets_sync_rules_for_layer "$layer"
  sync_assets_sync_skills_for_layer "$layer"
  sync_assets_sync_agents_for_layer "$layer"
  sync_assets_prune_stale_for_layer "$layer"
}

sync_assets_main() {
  sync_assets_parse_args "$@"

  local layer
  case "$LAYER_SCOPE" in
    both)
      sync_assets_process_layer root
      sync_assets_process_layer bundle
      ;;
    root | bundle)
      sync_assets_process_layer "$LAYER_SCOPE"
      ;;
    *)
      sync_assets_usage
      ;;
  esac

  if [[ "$ISSUES" -ne 0 ]]; then
    exit 1
  fi
}

sync_assets_main "$@"
