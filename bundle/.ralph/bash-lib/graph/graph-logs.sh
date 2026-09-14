#!/usr/bin/env bash
# Contained graph-owned log paths under <run-dir>/logs/.
#
# Canonical layout (paths stored relative to run-dir in the ledger):
#   logs/supervisor.log
#   logs/admission.jsonl
#   logs/nodes/<safe-node-id>/<attempt-id>/{runner.log,agent.log,usage.json}
#
# All writes go through graph_logs_resolve. Absolute paths, `..`, symlink
# escapes, and identifiers that sanitize to a collision are rejected.
# Graph logs are owned by their run directory.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

GRAPH_LOGS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -F ralph_atomic_write_json >/dev/null 2>&1; then
  # shellcheck source=../atomic-json.sh
  source "$GRAPH_LOGS_SCRIPT_DIR/../atomic-json.sh"
fi

# graph_logs_sanitize_id <identifier>
# Prints a filesystem-safe token. Rejects empty values, control characters,
# path separators, `.`, `..`, and a sanitize result that is empty/`.`/`..`.
graph_logs_sanitize_id() {
  local raw="$1" safe
  if [[ -z "$raw" || "$raw" == *$'\n'* || "$raw" == *$'\r'* ]]; then
    echo "Error: graph log identifier must be a non-empty single line" >&2
    return 1
  fi
  case "$raw" in
    /*|*\\*|*/*|*".."*)
      echo "Error: graph log identifier contains a path component: $raw" >&2
      return 1
      ;;
    .|..)
      echo "Error: graph log identifier is not usable as a path component: $raw" >&2
      return 1
      ;;
  esac
  safe="$(printf '%s' "$raw" | sed 's/[^A-Za-z0-9._-]/_/g')"
  if [[ -z "$safe" || "$safe" == "." || "$safe" == ".." ]]; then
    echo "Error: graph log identifier sanitizes to an unusable path component: $raw" >&2
    return 1
  fi
  printf '%s\n' "$safe"
}

graph_logs_id_map_rel() {
  printf 'logs/id-map.json\n'
}

# graph_logs_claim_id <run-dir> <kind> <identifier>
# kind is "node" or "attempt". Records original->safe mapping under the run
# and rejects a second original that sanitizes to an already-claimed token.
graph_logs_claim_id() {
  local run_dir="$1" kind="$2" original="$3"
  local safe map_rel map_abs map_json="" existing=""
  safe="$(graph_logs_sanitize_id "$original")" || return 1
  case "$kind" in
    node|attempt) ;;
    *)
      echo "Error: graph log id kind must be node or attempt" >&2
      return 1
      ;;
  esac
  map_rel="$(graph_logs_id_map_rel)"
  if ! graph_logs_prepare_parent "$run_dir" "$map_rel"; then
    return 1
  fi
  map_abs="$(graph_logs_resolve "$run_dir" "$map_rel")" || return 1
  if [[ -f "$map_abs" ]]; then
    map_json="$(cat "$map_abs" 2>/dev/null || true)"
  fi
  [[ -n "$map_json" ]] || map_json='{"nodes":{},"attempts":{}}'
  existing="$(printf '%s' "$map_json" | jq -r --arg kind "$kind" --arg safe "$safe" '
    (if $kind == "node" then .nodes else .attempts end)[$safe] // empty
  ' 2>/dev/null)" || existing=""
  if [[ -n "$existing" && "$existing" != "$original" ]]; then
    echo "Error: graph log identifiers '$existing' and '$original' sanitize to the same token '$safe'" >&2
    return 1
  fi
  if [[ "$existing" == "$original" ]]; then
    printf '%s\n' "$safe"
    return 0
  fi
  if ! ralph_atomic_write_json "$map_abs" \
    '($base | fromjson)
     | if $kind == "node" then .nodes[$safe] = $orig else .attempts[$safe] = $orig end' \
    --arg base "$map_json" --arg kind "$kind" --arg safe "$safe" --arg orig "$original"; then
    echo "Error: failed to record graph log identifier mapping" >&2
    return 1
  fi
  printf '%s\n' "$safe"
}

# graph_logs_supervisor_rel
graph_logs_supervisor_rel() {
  printf 'logs/supervisor.log\n'
}

# graph_logs_admission_rel
graph_logs_admission_rel() {
  printf 'logs/admission.jsonl\n'
}

# graph_logs_attempt_rel <run-dir> <node-id> <attempt-id> <filename>
# Claims node and attempt identifiers, then prints the relative attempt file.
graph_logs_attempt_rel() {
  local run_dir="$1" node_id="$2" attempt_id="$3" filename="$4"
  local safe_node safe_attempt
  case "$filename" in
    runner.log|agent.log|usage.json) ;;
    *)
      echo "Error: unsupported graph attempt log name: ${filename:-}" >&2
      return 1
      ;;
  esac
  safe_node="$(graph_logs_claim_id "$run_dir" node "$node_id")" || return 1
  safe_attempt="$(graph_logs_claim_id "$run_dir" attempt "$attempt_id")" || return 1
  printf 'logs/nodes/%s/%s/%s\n' "$safe_node" "$safe_attempt" "$filename"
}

# graph_logs_attempt_paths_json <run-dir> <node-id> <attempt-id>
# Prints a logPaths object with run-dir-relative runner/agent/usage paths.
graph_logs_attempt_paths_json() {
  local run_dir="$1" node_id="$2" attempt_id="$3"
  local runner agent usage
  runner="$(graph_logs_attempt_rel "$run_dir" "$node_id" "$attempt_id" runner.log)" || return 1
  agent="$(graph_logs_attempt_rel "$run_dir" "$node_id" "$attempt_id" agent.log)" || return 1
  usage="$(graph_logs_attempt_rel "$run_dir" "$node_id" "$attempt_id" usage.json)" || return 1
  jq -cn --arg runner "$runner" --arg agent "$agent" --arg usage "$usage" \
    '{runner:$runner,agent:$agent,usage:$usage}'
}

# graph_logs_has_dotdot <path>
# Returns 0 when any slash-separated component is `..`.
graph_logs_has_dotdot() {
  local path="$1" rest component
  rest="$path"
  while [[ -n "$rest" ]]; do
    component="${rest%%/*}"
    if [[ "$component" == ".." ]]; then
      return 0
    fi
    if [[ "$rest" == */* ]]; then
      rest="${rest#*/}"
    else
      rest=""
    fi
  done
  return 1
}

# graph_logs_real_dir <path>
# Prints the physical directory path. Fails if path is missing or not a dir.
graph_logs_real_dir() {
  local path="$1"
  [[ -n "$path" && -d "$path" ]] || return 1
  (cd "$path" 2>/dev/null && pwd -P)
}

# graph_logs_is_within <parent-real> <child-real>
# Returns 0 when child-real is parent-real or a descendant.
graph_logs_is_within() {
  local parent="$1" child="$2"
  [[ -n "$parent" && -n "$child" ]] || return 1
  [[ "$child" == "$parent" || "$child" == "$parent"/* ]]
}

# graph_logs_resolve <run-dir> <relative-path>
# The single containment helper. Rejects absolute paths, `..`, empty/`.`
# components, and any symlink that leaves the run-dir. Prints the absolute
# contained path. The final leaf may not exist yet.
graph_logs_resolve() {
  local run_dir="$1" rel="$2"
  local run_real current rest component next resolved_dir target

  if [[ -z "$run_dir" || -z "$rel" ]]; then
    echo "Error: graph_logs_resolve requires run-dir and a relative path" >&2
    return 1
  fi
  if [[ "$rel" == /* ]]; then
    echo "Error: graph log path must be relative to the run-dir: $rel" >&2
    return 1
  fi
  if graph_logs_has_dotdot "$rel"; then
    echo "Error: graph log path may not contain '..': $rel" >&2
    return 1
  fi

  run_real="$(graph_logs_real_dir "$run_dir")" || {
    echo "Error: graph log run-dir is not a directory: $run_dir" >&2
    return 1
  }

  current="$run_real"
  rest="$rel"
  while [[ -n "$rest" ]]; do
    component="${rest%%/*}"
    if [[ "$rest" == */* ]]; then
      rest="${rest#*/}"
    else
      rest=""
    fi
    if [[ -z "$component" || "$component" == "." || "$component" == ".." ]]; then
      echo "Error: graph log path has an illegal component: $rel" >&2
      return 1
    fi
    next="$current/$component"
    if [[ -L "$next" ]]; then
      if [[ -d "$next" ]]; then
        resolved_dir="$(graph_logs_real_dir "$next")" || {
          echo "Error: graph log path symlink is not a usable directory: $rel" >&2
          return 1
        }
        if ! graph_logs_is_within "$run_real" "$resolved_dir"; then
          echo "Error: graph log path escapes the run-dir via symlink: $rel" >&2
          return 1
        fi
        current="$resolved_dir"
      else
        target="$(readlink "$next" 2>/dev/null || true)"
        if [[ -z "$target" ]]; then
          echo "Error: graph log path symlink could not be read: $rel" >&2
          return 1
        fi
        if [[ "$target" == /* ]] || graph_logs_has_dotdot "$target"; then
          echo "Error: graph log path escapes the run-dir via symlink: $rel" >&2
          return 1
        fi
        resolved_dir="$(graph_logs_real_dir "$(dirname "$next")")" || return 1
        if ! graph_logs_is_within "$run_real" "$resolved_dir"; then
          echo "Error: graph log path escapes the run-dir via symlink: $rel" >&2
          return 1
        fi
        current="$next"
      fi
    elif [[ -d "$next" ]]; then
      resolved_dir="$(graph_logs_real_dir "$next")" || return 1
      if ! graph_logs_is_within "$run_real" "$resolved_dir"; then
        echo "Error: graph log path escapes the run-dir via symlink: $rel" >&2
        return 1
      fi
      current="$resolved_dir"
    else
      current="$next"
    fi
  done

  if [[ "$current" != "$run_real" && "$current" != "$run_real"/* ]]; then
    echo "Error: graph log path is not contained in the run-dir: $rel" >&2
    return 1
  fi
  printf '%s\n' "$current"
}

# graph_logs_prepare_parent <run-dir> <relative-path>
# Creates the parent directory of a contained relative path.
graph_logs_prepare_parent() {
  local run_dir="$1" rel="$2"
  local abs parent parent_rel
  [[ "$rel" == */* ]] || return 0
  parent_rel="${rel%/*}"
  abs="$(graph_logs_resolve "$run_dir" "$parent_rel")" || return 1
  mkdir -p "$abs" || {
    echo "Error: failed to create graph log directory: $parent_rel" >&2
    return 1
  }
  parent="$(graph_logs_resolve "$run_dir" "$parent_rel")" || return 1
  if [[ -L "$parent" ]]; then
    echo "Error: graph log parent is a symlink: $parent_rel" >&2
    return 1
  fi
  return 0
}

# graph_logs_prepare_write <run-dir> <relative-path>
# Ensures the parent exists and prints the contained absolute path for append.
graph_logs_prepare_write() {
  local run_dir="$1" rel="$2"
  local abs
  graph_logs_prepare_parent "$run_dir" "$rel" || return 1
  abs="$(graph_logs_resolve "$run_dir" "$rel")" || return 1
  if [[ -L "$abs" ]]; then
    echo "Error: refusing to write through a graph log symlink: $rel" >&2
    return 1
  fi
  printf '%s\n' "$abs"
}

# graph_logs_append <run-dir> <relative-path> <text>
# Appends one line after re-resolving the path so a swapped symlink cannot
# redirect a follow-up write.
graph_logs_append() {
  local run_dir="$1" rel="$2" text="$3"
  local abs
  abs="$(graph_logs_prepare_write "$run_dir" "$rel")" || return 1
  printf '%s\n' "$text" >>"$abs" || return 1
}

# graph_logs_read <run-dir> <relative-path>
# Prints a readable, contained run-owned file. Never creates or appends.
graph_logs_read() {
  local run_dir="$1" rel="$2"
  local abs
  if [[ -n "$run_dir" && -n "$rel" ]]; then
    if abs="$(graph_logs_resolve "$run_dir" "$rel" 2>/dev/null)" && [[ -f "$abs" && ! -L "$abs" ]]; then
      printf '%s\n' "$abs"
      return 0
    fi
  fi
  return 1
}

# graph_logs_owned_paths <run-dir>
# Prints absolute paths owned by this run: the contained logs/ tree plus any
# relative logPaths recorded in canonical node ledgers.
graph_logs_owned_paths() {
  local run_dir="$1"
  local run_real logs_dir node_file rel abs
  [[ -n "$run_dir" && -d "$run_dir" ]] || return 0
  run_real="$(graph_logs_real_dir "$run_dir")" || return 0
  logs_dir="$run_real/logs"
  if [[ -d "$logs_dir" ]]; then
    printf '%s\n' "$logs_dir"
  fi
  if [[ -d "$run_real/nodes" ]]; then
    for node_file in "$run_real/nodes"/*.json; do
      [[ -f "$node_file" ]] || continue
      while IFS= read -r rel; do
        [[ -n "$rel" && "$rel" != "null" ]] || continue
        abs="$(graph_logs_resolve "$run_dir" "$rel" 2>/dev/null)" || continue
        if [[ -e "$abs" ]]; then
          printf '%s\n' "$abs"
        fi
      done < <(jq -r '.attempts[]? | .logPaths // {} | .[]? // empty' "$node_file" 2>/dev/null)
    done
  fi
}

# graph_logs_validate_stream <stream>
# Accepts runner, agent, or usage.
graph_logs_validate_stream() {
  case "${1:-}" in
    runner|agent|usage) return 0 ;;
    *)
      echo "Error: graph logs --stream must be runner, agent, or usage" >&2
      return 1
      ;;
  esac
}

# workflow_logs_validate_public_stream <stream>
# Public workflow logs streams (stage-scoped; no internal node/namespace args).
workflow_logs_validate_public_stream() {
  case "${1:-}" in
    agent|supervisor|combined) return 0 ;;
    *)
      echo "Error: workflow logs --stream must be agent, supervisor, or combined" >&2
      return 1
      ;;
  esac
}

# workflow_logs_map_public_stream <public-stream>
# Prints internal graph stream name(s), one per line: agent, runner.
workflow_logs_map_public_stream() {
  local stream="${1:-}"
  workflow_logs_validate_public_stream "$stream" || return 1
  case "$stream" in
    agent) printf 'agent\n' ;;
    supervisor) printf 'runner\n' ;;
    combined)
      printf 'runner\n'
      printf 'agent\n'
      ;;
  esac
}

# graph_logs_regular_file <path>
# Prints path when it is a non-symlink regular file.
graph_logs_regular_file() {
  local path="$1"
  [[ -n "$path" && -f "$path" && ! -L "$path" ]] || return 1
  printf '%s\n' "$path"
}

# graph_logs_ledger_attempt_id <node_json> [attempt_id]
# Prints the attempt id to select. An empty attempt_id uses lastAttemptId.
# Fails when the attempt is absent from the ledger.
graph_logs_ledger_attempt_id() {
  local node_json="$1" attempt_id="${2:-}" found=""
  if [[ -z "$node_json" ]]; then
    echo "Error: graph logs requires a node ledger document" >&2
    return 1
  fi
  if [[ -z "$attempt_id" ]]; then
    attempt_id="$(printf '%s' "$node_json" | jq -r '.lastAttemptId // empty' 2>/dev/null || true)"
  fi
  if [[ -z "$attempt_id" ]]; then
    echo "Error: graph logs requires --attempt when the node has no lastAttemptId" >&2
    return 1
  fi
  found="$(printf '%s' "$node_json" | jq -r --arg aid "$attempt_id" \
    '(.attempts // []) | map(select(.attemptId == $aid)) | length' 2>/dev/null || true)"
  if [[ -z "$found" || "$found" == "0" ]]; then
    echo "Error: graph logs attempt '$attempt_id' is not in the node ledger" >&2
    return 1
  fi
  printf '%s\n' "$attempt_id"
}

# graph_logs_ledger_rel <node_json> <attempt_id> <stream>
# Prints the ledger-owned relative logPaths entry. Returns 2 when the
# attempt exists but that stream has no relative path. Rejects absolute
# paths and `..` so callers never resolve an unowned location.
graph_logs_ledger_rel() {
  local node_json="$1" attempt_id="$2" stream="$3" rel=""
  graph_logs_validate_stream "$stream" || return 1
  if [[ -z "$node_json" || -z "$attempt_id" ]]; then
    echo "Error: graph logs ledger path requires a node document and attempt id" >&2
    return 1
  fi
  rel="$(printf '%s' "$node_json" | jq -r --arg aid "$attempt_id" --arg stream "$stream" '
    (.attempts // [])
    | map(select(.attemptId == $aid))
    | last
    | .logPaths[$stream] // empty
  ' 2>/dev/null || true)"
  if [[ -z "$rel" || "$rel" == "null" ]]; then
    return 2
  fi
  if [[ "$rel" == /* ]] || graph_logs_has_dotdot "$rel"; then
    echo "Error: graph log path is not a ledger-owned contained relative path: $rel" >&2
    return 1
  fi
  printf '%s\n' "$rel"
}

# graph_logs_select <run-dir> <node_json> <attempt_id> <stream>
# Resolves one readable log file. Ledger-owned relative paths are resolved
# only through graph_logs_resolve. A present but uncontained ledger path is
# fatal; a missing ledger-owned file is a real error.
graph_logs_select() {
  local run_dir="$1" node_json="$2" attempt_id="$3" stream="$4"
  local resolved_attempt="" rel="" abs="" rc=0

  graph_logs_validate_stream "$stream" || return 1
  resolved_attempt="$(graph_logs_ledger_attempt_id "$node_json" "$attempt_id")" || return 1

  rel=""
  rc=0
  rel="$(graph_logs_ledger_rel "$node_json" "$resolved_attempt" "$stream")" || rc=$?
  if [[ "$rc" -eq 1 ]]; then
    return 1
  fi

  if [[ "$rc" -eq 0 && -n "$rel" ]]; then
    if ! abs="$(graph_logs_resolve "$run_dir" "$rel" 2>/dev/null)"; then
      echo "Error: graph log path is not contained in the run-dir: $rel" >&2
      return 1
    fi
    if [[ -L "$abs" ]]; then
      echo "Error: refusing to read a graph log symlink: $rel" >&2
      return 1
    fi
    if [[ -f "$abs" ]]; then
      printf '%s\n' "$abs"
      return 0
    fi
  fi

  echo "Error: graph log not found for stream '$stream'" >&2
  return 1
}

# graph_logs_print_file <abs-path> [tail_n]
# Prints the file. tail_n, when set, must be a positive integer.
graph_logs_print_file() {
  local abs="$1" tail_n="${2:-}"
  if [[ -z "$abs" || ! -f "$abs" || -L "$abs" ]]; then
    echo "Error: graph log file is missing or not a regular file" >&2
    return 1
  fi
  if [[ -n "$tail_n" ]]; then
    if [[ ! "$tail_n" =~ ^[1-9][0-9]*$ ]]; then
      echo "Error: graph logs --tail requires a positive integer" >&2
      return 1
    fi
    tail -n "$tail_n" "$abs"
    return $?
  fi
  cat "$abs"
}

# _graph_logs_operator_view_ready
# Lazy-load the operator read model without a circular import at file load.
_graph_logs_operator_view_ready() {
  if declare -F graph_operator_view_build >/dev/null 2>&1; then
    return 0
  fi
  # shellcheck source=./graph-operator-view.sh
  source "$GRAPH_LOGS_SCRIPT_DIR/graph-operator-view.sh"
}

# graph_logs_operator_context_print <workspace> <namespace> <run_id> <node_id> [stream]
# Read-only. Prints the shared operator context header on stdout. Log bytes
# follow on stdout after the separator when callers tee stderr/stdout apart.
graph_logs_operator_context_print() {
  local workspace="$1" namespace="$2" run_id="$3" node_id="$4" stream="${5:-agent}"
  local view_json=""
  _graph_logs_operator_view_ready || return 0
  view_json="$(graph_operator_view_build "$workspace" "$namespace" "$run_id" 2>/dev/null)" || return 0
  graph_operator_view_format_logs_context "$view_json" "$node_id" "$stream"
}

# graph_attach_operator_context_print <workspace> <namespace> <run_id>
# Read-only attach/status snapshot from the same operator projection.
graph_attach_operator_context_print() {
  local workspace="$1" namespace="$2" run_id="$3"
  local view_json=""
  _graph_logs_operator_view_ready || return 1
  view_json="$(graph_operator_view_build "$workspace" "$namespace" "$run_id" 2>/dev/null)" || return 1
  graph_operator_view_format_attach_snapshot "$view_json"
}
