#!/usr/bin/env bash

if [[ -n "${RALPH_MCP_PROXY_RESULT_STORE_LOADED:-}" ]]; then
  return
fi
RALPH_MCP_PROXY_RESULT_STORE_LOADED=1

# Public interface:
#   ralph_mcp_proxy_result_store_root -- resolve .ralph-workspace/tool-results path.
#   ralph_mcp_proxy_result_store_plan_dir -- path for one plan key under tool-results.
#   ralph_mcp_proxy_result_store_init -- create plan-key storage directory layout.
#   ralph_mcp_proxy_result_store_generate_id -- deterministic 16-char hex id from content.
#   ralph_mcp_proxy_result_store_write -- persist full result text; prints result id on stdout.
#   ralph_mcp_proxy_result_store_read_bytes -- read a byte range from a stored result.
#   ralph_mcp_proxy_result_store_read_lines -- read a line range from a stored result.
#   ralph_mcp_proxy_result_store_search -- regex search within one result or all plan results.
#   ralph_mcp_proxy_result_store_match_metadata_from_grep_output -- grep/rg lines to match metadata JSON.
#   ralph_mcp_proxy_result_store_match_clusters_from_metadata -- merge nearby match lines into clusters JSON.
#   ralph_mcp_proxy_result_store_generate_breakpoints_json -- deterministic paging breakpoints JSON.
#   ralph_mcp_proxy_result_store_apply_retention -- delete oldest results beyond retention limits.
#   ralph_mcp_proxy_result_store_retention_max_entries -- max stored results per plan key (default 100).
#   ralph_mcp_proxy_result_store_retention_max_bytes -- max stored bytes per plan key (default 52428800).
#   ralph_mcp_proxy_result_store_retention_max_age_days -- max result age in days (default 7; 0 disables age pruning).
#
# Retention env overrides (non-negative integers; invalid values fall back to defaults):
#   RALPH_MCP_PROXY_RESULT_STORE_MAX_ENTRIES
#   RALPH_MCP_PROXY_RESULT_STORE_MAX_BYTES
#   RALPH_MCP_PROXY_RESULT_STORE_MAX_AGE_DAYS
#   ralph_mcp_proxy_result_store_validate_plan_key -- reject plan keys that escape storage.
#   ralph_mcp_proxy_result_store_validate_result_id -- reject result ids that escape storage.

ralph_mcp_proxy_result_store_workspace_realpath() {
  local workspace="${1:-}"
  [[ -n "$workspace" ]] || return 1
  (cd "$workspace" 2>/dev/null && pwd -P)
}

ralph_mcp_proxy_result_store_workspace_root() {
  local workspace="${1:-}"
  [[ -n "$workspace" ]] || return 1
  local workspace_real
  workspace_real="$(ralph_mcp_proxy_result_store_workspace_realpath "$workspace")" || return 1
  local candidate="${RALPH_PLAN_WORKSPACE_ROOT:-}"
  if [[ -z "$candidate" ]]; then
    candidate="$workspace_real/.ralph-workspace"
  elif [[ "$candidate" != /* ]]; then
    candidate="$workspace_real/$candidate"
  fi
  local canonical_root
  canonical_root="$(ralph_mcp_proxy_result_store_canonicalize_path "$candidate")" || return 1
  canonical_root="${canonical_root%/}"
  if [[ "$canonical_root" != "$workspace_real" && "$canonical_root" != "$workspace_real/"* ]]; then
    return 1
  fi
  printf '%s\n' "$canonical_root"
}

ralph_mcp_proxy_result_store_root() {
  local workspace="${1:-}"
  local workspace_root
  workspace_root="$(ralph_mcp_proxy_result_store_workspace_root "$workspace")" || return 1
  printf '%s/tool-results\n' "$workspace_root"
}

ralph_mcp_proxy_result_store_canonicalize_path() {
  local raw="${1:-}"
  local expanded="$raw"
  if [[ "$expanded" == "~" ]]; then
    expanded="$HOME"
  elif [[ "$expanded" == ~/* ]]; then
    expanded="$HOME/${expanded#~/}"
  fi
  local dir base
  dir="$(dirname "$expanded")"
  base="$(basename "$expanded")"
  local dir_real
  dir_real="$(cd "$dir" 2>/dev/null && pwd -P)" || return 1
  printf '%s/%s\n' "$dir_real" "$base"
}

ralph_mcp_proxy_result_store_path_under_dir() {
  local root_dir="${1:-}"
  local candidate="${2:-}"
  [[ -n "$root_dir" && -n "$candidate" ]] || return 1
  local root_real candidate_real
  root_real="$(cd "$root_dir" 2>/dev/null && pwd -P)" || return 1
  if [[ -e "$candidate" ]]; then
    candidate_real="$(ralph_mcp_proxy_result_store_canonicalize_path "$candidate")" || return 1
  else
    local parent base
    parent="$(dirname "$candidate")"
    base="$(basename "$candidate")"
    local parent_real
    parent_real="$(cd "$parent" 2>/dev/null && pwd -P)" || return 1
    candidate_real="$parent_real/$base"
  fi
  if [[ "$candidate_real" == "$root_real" || "$candidate_real" == "$root_real/"* ]]; then
    printf '%s\n' "$candidate_real"
    return 0
  fi
  return 1
}

ralph_mcp_proxy_result_store_validate_plan_key() {
  local plan_key="${1:-}"
  if [[ -z "$plan_key" ]]; then
    return 1
  fi
  if [[ "$plan_key" == *"/"* || "$plan_key" == *".."* ]]; then
    return 1
  fi
  [[ "$plan_key" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

ralph_mcp_proxy_result_store_validate_result_id() {
  local result_id="${1:-}"
  if [[ -z "$result_id" ]]; then
    return 1
  fi
  if [[ "$result_id" == *"/"* || "$result_id" == *".."* ]]; then
    return 1
  fi
  [[ "$result_id" =~ ^[a-f0-9]{16}$ ]]
}

ralph_mcp_proxy_result_store_plan_dir() {
  local workspace="${1:-}"
  local plan_key="${2:-}"
  ralph_mcp_proxy_result_store_validate_plan_key "$plan_key" || return 1
  local store_root
  store_root="$(ralph_mcp_proxy_result_store_root "$workspace")" || return 1
  mkdir -p "$store_root" || return 1
  printf '%s/%s\n' "${store_root%/}" "$plan_key"
}

ralph_mcp_proxy_result_store_results_dir() {
  local workspace="${1:-}"
  local plan_key="${2:-}"
  local plan_dir
  plan_dir="$(ralph_mcp_proxy_result_store_plan_dir "$workspace" "$plan_key")" || return 1
  printf '%s/results\n' "${plan_dir%/}"
}

ralph_mcp_proxy_result_store_index_path() {
  local workspace="${1:-}"
  local plan_key="${2:-}"
  local plan_dir
  plan_dir="$(ralph_mcp_proxy_result_store_plan_dir "$workspace" "$plan_key")" || return 1
  printf '%s/index.jsonl\n' "${plan_dir%/}"
}

ralph_mcp_proxy_result_store_resolve_result_path() {
  local workspace="${1:-}"
  local plan_key="${2:-}"
  local result_id="${3:-}"
  local view="${4:-raw}"
  ralph_mcp_proxy_result_store_validate_result_id "$result_id" || return 1
  local results_dir store_root candidate suffix=".txt"
  case "$view" in
    compacted) suffix=".compact.txt" ;;
    raw|*) suffix=".txt" ;;
  esac
  results_dir="$(ralph_mcp_proxy_result_store_results_dir "$workspace" "$plan_key")" || return 1
  candidate="${results_dir%/}/${result_id}${suffix}"
  store_root="$(ralph_mcp_proxy_result_store_root "$workspace")" || return 1
  if [[ -d "$store_root" ]]; then
    ralph_mcp_proxy_result_store_path_under_dir "$store_root" "$candidate" || return 1
    return 0
  fi
  printf '%s\n' "$candidate"
}

ralph_mcp_proxy_result_store_metadata_dir() {
  local workspace="${1:-}"
  local plan_key="${2:-}"
  local plan_dir
  plan_dir="$(ralph_mcp_proxy_result_store_plan_dir "$workspace" "$plan_key")" || return 1
  printf '%s/metadata\n' "${plan_dir%/}"
}

ralph_mcp_proxy_result_store_metadata_path() {
  local workspace="${1:-}"
  local plan_key="${2:-}"
  local result_id="${3:-}"
  local metadata_dir
  metadata_dir="$(ralph_mcp_proxy_result_store_metadata_dir "$workspace" "$plan_key")" || return 1
  printf '%s/%s.json\n' "${metadata_dir%/}" "$result_id"
}

ralph_mcp_proxy_result_store_write_metadata() {
  local workspace="${1:-}"
  local plan_key="${2:-}"
  local result_id="${3:-}"
  local metadata_json="${4:-}"
  if [[ -z "$metadata_json" ]]; then
    return 0
  fi
  local metadata_dir metadata_path
  metadata_dir="$(ralph_mcp_proxy_result_store_metadata_dir "$workspace" "$plan_key")" || return 1
  mkdir -p "$metadata_dir" || return 1
  metadata_path="$(ralph_mcp_proxy_result_store_metadata_path "$workspace" "$plan_key" "$result_id")" || return 1
  printf '%s' "$metadata_json" >"$metadata_path" || return 1
}

ralph_mcp_proxy_result_store_read_metadata() {
  local workspace="${1:-}"
  local plan_key="${2:-}"
  local result_id="${3:-}"
  local metadata_path
  metadata_path="$(ralph_mcp_proxy_result_store_metadata_path "$workspace" "$plan_key" "$result_id")" || return 0
  if [[ ! -f "$metadata_path" ]]; then
    return 0
  fi
  cat "$metadata_path"
}

ralph_mcp_proxy_result_store_init() {
  local workspace="${1:-}"
  local plan_key="${2:-}"
  local plan_dir results_dir index_path
  plan_dir="$(ralph_mcp_proxy_result_store_plan_dir "$workspace" "$plan_key")" || return 1
  results_dir="$(ralph_mcp_proxy_result_store_results_dir "$workspace" "$plan_key")" || return 1
  mkdir -p "$results_dir" || return 1
  index_path="$(ralph_mcp_proxy_result_store_index_path "$workspace" "$plan_key")" || return 1
  if [[ ! -f "$index_path" ]]; then
    : >"$index_path" || return 1
  fi
  printf '%s\n' "$plan_dir"
}

ralph_mcp_proxy_result_store_hash_content() {
  local content="$1"
  local hash=""

  if command -v sha256sum >/dev/null 2>&1; then
    hash="$(printf '%s' "$content" | sha256sum | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    hash="$(printf '%s' "$content" | shasum -a 256 | awk '{print $1}')"
  elif command -v python3 >/dev/null 2>&1; then
    hash="$(printf '%s' "$content" | python3 -c \
      'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')"
  elif command -v openssl >/dev/null 2>&1; then
    hash="$(printf '%s' "$content" | openssl dgst -sha256 | awk '{print $NF}')"
  else
    return 1
  fi

  printf '%s' "${hash:0:16}"
}

ralph_mcp_proxy_result_store_generate_id() {
  local content="${1:-}"
  [[ -n "$content" ]] || return 1
  ralph_mcp_proxy_result_store_hash_content "$content"
}

ralph_mcp_proxy_result_store_timestamp() {
  if date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null; then
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'from datetime import datetime, timezone; print(datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))'
    return 0
  fi
  return 1
}

ralph_mcp_proxy_result_store_retention_parse_nonneg_int() {
  local raw="${1:-}"
  local fallback="${2:-0}"
  if [[ -z "$raw" || ! "$raw" =~ ^[0-9]+$ ]]; then
    printf '%s' "$fallback"
    return 0
  fi
  printf '%s' "$raw"
}

ralph_mcp_proxy_result_store_retention_max_entries() {
  ralph_mcp_proxy_result_store_retention_parse_nonneg_int \
    "${RALPH_MCP_PROXY_RESULT_STORE_MAX_ENTRIES:-}" \
    "100"
}

ralph_mcp_proxy_result_store_retention_max_bytes() {
  ralph_mcp_proxy_result_store_retention_parse_nonneg_int \
    "${RALPH_MCP_PROXY_RESULT_STORE_MAX_BYTES:-}" \
    "52428800"
}

ralph_mcp_proxy_result_store_retention_max_age_days() {
  ralph_mcp_proxy_result_store_retention_parse_nonneg_int \
    "${RALPH_MCP_PROXY_RESULT_STORE_MAX_AGE_DAYS:-}" \
    "7"
}

ralph_mcp_proxy_result_store_locked_run() {
  local lock_file="$1"
  shift
  [[ -n "$lock_file" ]] || return 1

  if command -v flock >/dev/null 2>&1; then
    (
      flock -x 200 || exit 1
      "$@"
    ) 200>"$lock_file"
    return $?
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$lock_file" "$@" <<'PYTHON'
import fcntl
import os
import subprocess
import sys

lock_file = sys.argv[1]
cmd = sys.argv[2:]
lock_dir = os.path.dirname(lock_file)
if lock_dir:
    os.makedirs(lock_dir, exist_ok=True)
with open(lock_file, "a+", encoding="utf-8") as lock_fh:
    fcntl.flock(lock_fh.fileno(), fcntl.LOCK_EX)
    try:
        completed = subprocess.run(cmd, check=False)
        raise SystemExit(completed.returncode)
    finally:
        fcntl.flock(lock_fh.fileno(), fcntl.LOCK_UN)
PYTHON
    return $?
  fi

  "$@"
}

ralph_mcp_proxy_result_store_write() {
  local workspace="${1:-}"
  local plan_key="${2:-}"
  local content="${3:-}"
  local tool_name="${4:-}"
  local metadata_json="${5:-}"
  local compact_content="${6:-}"
  [[ -n "$workspace" && -n "$plan_key" && -n "$content" ]] || return 1
  if [[ -n "$tool_name" ]] \
    && declare -F ralph_mcp_proxy_result_store_tool_name_allowed >/dev/null 2>&1 \
    && ! ralph_mcp_proxy_result_store_tool_name_allowed "$tool_name"; then
    return 1
  fi
  command -v jq >/dev/null 2>&1 || return 1

  local plan_dir result_id result_path index_path lock_file stored_at bytes entry_json
  plan_dir="$(ralph_mcp_proxy_result_store_init "$workspace" "$plan_key")" || return 1
  result_id="$(ralph_mcp_proxy_result_store_generate_id "$content")" || return 1
  result_path="$(ralph_mcp_proxy_result_store_resolve_result_path "$workspace" "$plan_key" "$result_id")" || return 1
  index_path="$(ralph_mcp_proxy_result_store_index_path "$workspace" "$plan_key")" || return 1
  lock_file="${plan_dir%/}/.store.lock"
  stored_at="$(ralph_mcp_proxy_result_store_timestamp)" || stored_at=""
  bytes="$(printf '%s' "$content" | wc -c | tr -d ' ')"
  entry_json="$(jq -nc \
    --arg id "$result_id" \
    --arg storedAt "$stored_at" \
    --argjson bytes "$bytes" \
    --arg tool "$tool_name" \
    --arg path "$result_path" \
    --arg metadata "$metadata_json" \
    '{id:$id,storedAt:$storedAt,bytes:$bytes,tool:(if $tool == "" then null else $tool end),path:$path}
      | if ($metadata == "" or $metadata == "null") then . else .metadata = ($metadata | fromjson) end
    ')" || return 1
  local content_file="${plan_dir%/}/.write-content.$$"
  local entry_file="${plan_dir%/}/.write-entry.$$"
  printf '%s' "$content" >"$content_file" || return 1
  printf '%s' "$entry_json" >"$entry_file" || return 1

  ralph_mcp_proxy_result_store_locked_run "$lock_file" bash -c '
    set -euo pipefail
    cat "$1" >"$2"
    entry="$(cat "$6")"
    if [[ -f "$3" ]] && [[ -s "$3" ]]; then
      jq -c -n --arg id "$4" --argjson entry "$entry" '"'"'[inputs | select(.id != $id)] + [$entry] | .[]'"'"' "$3" >"${3}.tmp.$$"
    else
      printf "%s\n" "$entry" >"${3}.tmp.$$"
    fi
    mv "${3}.tmp.$$" "$3"
  ' _ "$content_file" "$result_path" "$index_path" "$result_id" "" "$entry_file" || {
    rm -f "$content_file" "$entry_file"
    return 1
  }
  rm -f "$content_file" "$entry_file"

  if [[ -n "$compact_content" ]]; then
    local compact_path results_dir
    results_dir="$(ralph_mcp_proxy_result_store_results_dir "$workspace" "$plan_key")" || return 1
    compact_path="${results_dir%/}/${result_id}.compact.txt"
    if ralph_mcp_proxy_result_store_path_under_dir "$(ralph_mcp_proxy_result_store_root "$workspace")" "$compact_path" >/dev/null 2>&1; then
      printf '%s' "$compact_content" >"$compact_path" 2>/dev/null || true
    fi
  fi

  ralph_mcp_proxy_result_store_apply_retention "$workspace" "$plan_key" >/dev/null || true
  if [[ -n "$metadata_json" ]]; then
    ralph_mcp_proxy_result_store_write_metadata "$workspace" "$plan_key" "$result_id" "$metadata_json" >/dev/null 2>&1 || true
  fi
  printf '%s\n' "$result_id"
}

ralph_mcp_proxy_result_store_read_bytes() {
  local workspace="${1:-}"
  local plan_key="${2:-}"
  local result_id="${3:-}"
  local byte_offset="${4:-0}"
  local byte_limit="${5:-0}"
  local view="${6:-raw}"
  local result_path
  result_path="$(ralph_mcp_proxy_result_store_resolve_result_path "$workspace" "$plan_key" "$result_id" "$view")" || return 1
  if [[ ! -f "$result_path" && "$view" == "compacted" ]]; then
    result_path="$(ralph_mcp_proxy_result_store_resolve_result_path "$workspace" "$plan_key" "$result_id" "raw")" || return 1
  fi
  [[ -f "$result_path" ]] || return 1
  if [[ ! "$byte_offset" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  if [[ ! "$byte_limit" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$result_path" "$byte_offset" "$byte_limit" <<'PYTHON'
import sys

path, offset_s, limit_s = sys.argv[1:4]
offset = int(offset_s)
limit = int(limit_s)
with open(path, "rb") as fh:
    fh.seek(offset)
    data = fh.read(limit if limit > 0 else None)
sys.stdout.buffer.write(data)
PYTHON
    return $?
  fi

  if [[ "$byte_limit" -eq 0 ]]; then
    tail -c +"$((byte_offset + 1))" "$result_path"
  else
    tail -c +"$((byte_offset + 1))" "$result_path" | head -c "$byte_limit"
  fi
}

ralph_mcp_proxy_result_store_read_lines() {
  local workspace="${1:-}"
  local plan_key="${2:-}"
  local result_id="${3:-}"
  local line_offset="${4:-1}"
  local line_limit="${5:-0}"
  local view="${6:-raw}"
  local result_path
  result_path="$(ralph_mcp_proxy_result_store_resolve_result_path "$workspace" "$plan_key" "$result_id" "$view")" || return 1
  if [[ ! -f "$result_path" && "$view" == "compacted" ]]; then
    result_path="$(ralph_mcp_proxy_result_store_resolve_result_path "$workspace" "$plan_key" "$result_id" "raw")" || return 1
  fi
  [[ -f "$result_path" ]] || return 1
  if [[ ! "$line_offset" =~ ^[0-9]+$ ]] || [[ "$line_offset" -lt 1 ]]; then
    return 1
  fi
  if [[ ! "$line_limit" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  if [[ "$line_limit" -eq 0 ]]; then
    tail -n +"$line_offset" "$result_path"
  else
    tail -n +"$line_offset" "$result_path" | head -n "$line_limit"
  fi
}

ralph_mcp_proxy_result_store_search() {
  local workspace="${1:-}"
  local plan_key="${2:-}"
  local pattern="${3:-}"
  local result_id="${4:-}"
  [[ -n "$pattern" ]] || return 1

  local -a search_paths=()
  if [[ -n "$result_id" ]]; then
    local result_path
    result_path="$(ralph_mcp_proxy_result_store_resolve_result_path "$workspace" "$plan_key" "$result_id")" || return 1
    [[ -f "$result_path" ]] || return 1
    search_paths+=("$result_path")
  else
    local results_dir
    results_dir="$(ralph_mcp_proxy_result_store_results_dir "$workspace" "$plan_key")" || return 1
    [[ -d "$results_dir" ]] || return 0
    local entry
    shopt -s nullglob
    for entry in "$results_dir"/*.txt; do
      [[ "$entry" == *.compact.txt ]] && continue
      search_paths+=("$entry")
    done
    shopt -u nullglob
  fi

  local path
  for path in "${search_paths[@]}"; do
    if command -v rg >/dev/null 2>&1; then
      rg --no-heading --line-number -- "$pattern" "$path" 2>/dev/null || true
    else
      grep -En -- "$pattern" "$path" 2>/dev/null || true
    fi
  done
}

ralph_mcp_proxy_result_store_match_metadata_from_grep_output() {
  local grep_output="${1:-}"
  command -v jq >/dev/null 2>&1 || return 1

  if [[ -z "$grep_output" ]]; then
    jq -nc '[]'
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$grep_output" | python3 -c '
import json
import re
import sys

lines = []
seen = set()
for raw_line in sys.stdin.read().splitlines():
    match = re.match(r"^(?:[^:]+:)?(\d+):", raw_line)
    if not match:
        continue
    line_no = int(match.group(1))
    if line_no in seen:
        continue
    seen.add(line_no)
    lines.append({"line": line_no})

lines.sort(key=lambda item: item["line"])
print(json.dumps(lines, separators=(",", ":")))
'
    return $?
  fi

  local -a metadata_lines=()
  local raw_line line_no
  while IFS= read -r raw_line; do
    [[ -n "$raw_line" ]] || continue
    if [[ "$raw_line" =~ ^([^:]*:)?([0-9]+): ]]; then
      line_no="${BASH_REMATCH[2]}"
      metadata_lines+=("{\"line\":$line_no}")
    fi
  done <<< "$grep_output"

  if [[ ${#metadata_lines[@]} -eq 0 ]]; then
    jq -nc '[]'
    return 0
  fi

  local joined=""
  local entry
  for entry in "${metadata_lines[@]}"; do
    if [[ -n "$joined" ]]; then
      joined+=","
    fi
    joined+="$entry"
  done
  jq -c "[${joined}] | unique_by(.line) | sort_by(.line)"
}

ralph_mcp_proxy_result_store_match_clusters_from_metadata() {
  local match_metadata_json="${1:-[]}"
  local cluster_gap="${2:-2}"
  command -v jq >/dev/null 2>&1 || return 1
  if [[ ! "$cluster_gap" =~ ^[0-9]+$ ]]; then
    cluster_gap=2
  fi
  printf '%s' "$match_metadata_json" | jq -e 'type == "array"' >/dev/null 2>&1 || return 1
  jq -nc \
    --argjson metadata "$match_metadata_json" \
    --argjson gap "$cluster_gap" \
    '
      def line_no($entry):
        if ($entry | type) == "object" then
          ($entry.line // empty)
        elif ($entry | type) == "number" then
          $entry
        else
          empty
        end;
      [ $metadata[] | line_no(.) | select(. != null) ]
      | unique
      | sort
      | reduce .[] as $line (
          [];
          if length == 0 then
            [{lineStart: $line, lineEnd: $line}]
          elif $line <= (.[-1].lineEnd + $gap) then
            .[-1].lineEnd = $line | .
          else
            . + [{lineStart: $line, lineEnd: $line}]
          end
        )
    '
}

ralph_mcp_proxy_result_store_generate_breakpoints_json() {
  local workspace="${1:-}"
  local plan_key="${2:-}"
  local result_id="${3:-}"
  local original_bytes="${4:-0}"
  local returned_bytes="${5:-0}"
  local envelope_byte_cap="${6:-0}"
  local match_metadata_json="${7:-[]}"
  command -v jq >/dev/null 2>&1 || return 1

  if [[ ! "$original_bytes" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  if [[ ! "$returned_bytes" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  if [[ ! "$envelope_byte_cap" =~ ^[0-9]+$ ]]; then
    envelope_byte_cap=0
  fi
  if [[ -z "$match_metadata_json" ]]; then
    match_metadata_json='[]'
  fi
  printf '%s' "$match_metadata_json" | jq -e 'type == "array"' >/dev/null 2>&1 || return 1

  local result_path=""
  if [[ -n "$workspace" && -n "$plan_key" && -n "$result_id" ]]; then
    result_path="$(ralph_mcp_proxy_result_store_resolve_result_path "$workspace" "$plan_key" "$result_id" 2>/dev/null || true)"
    if [[ -n "$result_path" && ! -f "$result_path" ]]; then
      result_path=""
    fi
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$result_path" "$original_bytes" "$returned_bytes" "$envelope_byte_cap" "$match_metadata_json" <<'PYTHON'
import json
import sys

result_path, original_s, returned_s, cap_s, match_json = sys.argv[1:6]
original_bytes = int(original_s)
returned_bytes = int(returned_s)
envelope_byte_cap = int(cap_s)
match_metadata = json.loads(match_json)

window = returned_bytes if returned_bytes > 0 else (original_bytes if original_bytes > 0 else 1)
orig = max(0, original_bytes)
context_lines = 1

breakpoints = [
    {"kind": "start", "byteStart": 0, "byteEnd": min(window, orig if orig > 0 else window)},
    {
        "kind": "end",
        "byteStart": max(0, orig - window) if orig > window else 0,
        "byteEnd": orig,
    },
]

line_starts = [0]
data = b""
if result_path:
    with open(result_path, "rb") as fh:
        data = fh.read()
    for index, byte in enumerate(data):
        if byte == ord("\n"):
            line_starts.append(index + 1)
total_lines = max(1, len(line_starts))

def normalize_match(entry):
    if isinstance(entry, dict):
        line_start = entry.get("lineStart")
        line_end = entry.get("lineEnd")
        if line_start is not None and line_end is not None:
            try:
                ls = int(line_start)
                le = int(line_end)
            except (TypeError, ValueError):
                return None
            if ls < 1 or le < ls:
                return None
            return ("cluster", ls, le)
        line = entry.get("line")
    else:
        line = entry
    try:
        line_no = int(line)
    except (TypeError, ValueError):
        return None
    if line_no < 1:
        return None
    return ("line", line_no)

match_entries = []
seen = set()
for entry in match_metadata:
    norm = normalize_match(entry)
    if norm is None:
        continue
    if norm[0] == "cluster":
        key = ("cluster", norm[1], norm[2])
    else:
        key = ("line", norm[1])
    if key in seen:
        continue
    seen.add(key)
    match_entries.append(norm)

match_entries.sort(key=lambda item: item[1])

for norm in match_entries:
    if norm[0] == "cluster":
        line_start = max(1, norm[1] - context_lines)
        line_end = min(total_lines, norm[2] + context_lines)
        entry = {
            "kind": "matchCluster",
            "lineStart": line_start,
            "lineEnd": line_end,
        }
    else:
        line_no = norm[1]
        line_start = max(1, line_no - context_lines)
        line_end = min(total_lines, line_no + context_lines)
        entry = {
            "kind": "match",
            "lineStart": line_start,
            "lineEnd": line_end,
        }
    if data:
        byte_start = line_starts[line_start - 1]
        if line_end >= total_lines:
            byte_end = len(data)
        else:
            byte_end = line_starts[line_end]
        entry["byteStart"] = byte_start
        entry["byteEnd"] = byte_end
    breakpoints.append(entry)

def compact_size(items):
    return len(json.dumps(items, separators=(",", ":")).encode("utf-8"))

if envelope_byte_cap > 0:
    preview_bytes = min(returned_bytes if returned_bytes > 0 else window, orig if orig > 0 else window)
    fixed_overhead = 220
    budget = max(64, envelope_byte_cap - preview_bytes - fixed_overhead)
    while compact_size(breakpoints) > budget and len(breakpoints) > 2:
        breakpoints.pop()

print(json.dumps(breakpoints, separators=(",", ":")))
PYTHON
    return $?
  fi

  jq -nc \
    --argjson originalBytes "$original_bytes" \
    --argjson returnedBytes "$returned_bytes" \
    --argjson envelopeByteCap "$envelope_byte_cap" \
    --argjson matchMetadata "$match_metadata_json" \
    '
      ($originalBytes | if . < 0 then 0 else . end) as $orig
      | ($returnedBytes | if . < 0 then 0 else . end) as $ret
      | ($ret | if $ret > 0 then $ret else ($orig | if . > 0 then . else 1 end) end) as $window
      | ($envelopeByteCap | if . < 0 then 0 else . end) as $cap
      | [
          {kind: "start", byteStart: 0, byteEnd: ($window | if $orig > 0 and $orig < . then $orig else . end)},
          {
            kind: "end",
            byteStart: (if $orig > $window then ($orig - $window) else 0 end),
            byteEnd: $orig
          }
        ]
      | . + (
          ($matchMetadata
            | map(
                if (type == "object") and (.lineStart? != null) and (.lineEnd? != null) then
                  {
                    kind: "matchCluster",
                    lineStart: (if (.lineStart | tonumber) <= 1 then 1 else ((.lineStart | tonumber) - 1) end),
                    lineEnd: ((.lineEnd | tonumber) + 1)
                  }
                elif (type == "object") and (.line? != null) then
                  {
                    kind: "match",
                    lineStart: (if (.line | tonumber) <= 1 then 1 else ((.line | tonumber) - 1) end),
                    lineEnd: ((.line | tonumber) + 1)
                  }
                elif (type == "number") then
                  {
                    kind: "match",
                    lineStart: (if . <= 1 then 1 else (. - 1) end),
                    lineEnd: (. + 1)
                  }
                else
                  empty
                end
              )
          )
        )
      | if $cap > 0 then
          . as $all
          | ($ret | if . > 0 then . else ($orig | if . > 0 then . else 1 end) end) as $preview
          | ($cap - $preview - 220) as $budget
          | if $budget < 64 then $all[:2] else $all end
        else
          .
        end
    '
}

ralph_mcp_proxy_result_store_apply_retention() {
  local workspace="${1:-}"
  local plan_key="${2:-}"
  local index_path store_root
  index_path="$(ralph_mcp_proxy_result_store_index_path "$workspace" "$plan_key")" || return 1
  store_root="$(ralph_mcp_proxy_result_store_root "$workspace")" || return 1
  [[ -s "$index_path" ]] || {
    jq -n '{removed:0,remaining:0}'
    return 0
  }
  command -v jq >/dev/null 2>&1 || return 1

  local max_entries max_bytes max_age_days
  max_entries="$(ralph_mcp_proxy_result_store_retention_max_entries)"
  max_bytes="$(ralph_mcp_proxy_result_store_retention_max_bytes)"
  max_age_days="$(ralph_mcp_proxy_result_store_retention_max_age_days)"

  local retention_json drop_json keep_json
  retention_json="$(
    jq -c -n \
      --argjson max_entries "$max_entries" \
      --argjson max_bytes "$max_bytes" \
      --argjson max_age_days "$max_age_days" \
      '
        def age_active_entries:
          if $max_age_days <= 0 then
            .
          else
            (now - ($max_age_days * 86400)) as $cutoff
            | map(
                if (.storedAt // "" | length) == 0 then
                  .
                elif try ((.storedAt | fromdateiso8601) >= $cutoff) catch true then
                  .
                else
                  empty
                end
              )
          end;
        def retention_keep:
          sort_by(.storedAt // "")
          | reverse as $newest
          | reduce $newest[] as $entry (
              {keep: [], bytes: 0};
              if (.keep | length) == 0 then
                .keep += [$entry]
                | .bytes += ($entry.bytes // 0)
              elif (.keep | length) >= $max_entries
                 or (.bytes + ($entry.bytes // 0)) > $max_bytes then
                .
              else
                .keep += [$entry]
                | .bytes += ($entry.bytes // 0)
              end
            )
          | .keep;
        [inputs] as $all
        | ($all | age_active_entries) as $active
        | ($active | retention_keep) as $keep
        | {
            keep: $keep,
            drop: (($all - $active) + ($active - $keep))
          }
      ' "$index_path" 2>/dev/null || printf '{"keep":[],"drop":[]}'
  )"
  drop_json="$(printf '%s' "$retention_json" | jq -c '.drop // []')"
  keep_json="$(printf '%s' "$retention_json" | jq -c '.keep // []')"

  local drop_count=0
  local drop_id drop_path
  while IFS= read -r drop_id; do
    [[ -n "$drop_id" ]] || continue
    drop_path="$(ralph_mcp_proxy_result_store_resolve_result_path "$workspace" "$plan_key" "$drop_id")" || continue
    if ! ralph_mcp_proxy_result_store_path_under_dir "$store_root" "$drop_path" >/dev/null; then
      continue
    fi
    rm -f "$drop_path" 2>/dev/null || true
    local drop_compact_path
    drop_compact_path="$(ralph_mcp_proxy_result_store_resolve_result_path "$workspace" "$plan_key" "$drop_id" "compacted" 2>/dev/null || true)"
    if [[ -n "$drop_compact_path" ]] \
      && ralph_mcp_proxy_result_store_path_under_dir "$store_root" "$drop_compact_path" >/dev/null 2>&1; then
      rm -f "$drop_compact_path" 2>/dev/null || true
    fi
    drop_count=$((drop_count + 1))
  done < <(printf '%s\n' "$drop_json" | jq -r '.[].id // empty')

  local tmp_index="${index_path}.retention.$$"
  if [[ "$keep_json" == "[]" ]]; then
    : >"$tmp_index"
  else
    jq -c '.[]' <<< "$keep_json" >"$tmp_index"
  fi
  mv "$tmp_index" "$index_path"

  local remaining
  remaining="$(jq 'length' <<< "$keep_json")"
  jq -n --argjson removed "$drop_count" --argjson remaining "$remaining" '{removed:$removed,remaining:$remaining}'
}
