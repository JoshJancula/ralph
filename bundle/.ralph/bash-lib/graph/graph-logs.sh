#!/usr/bin/env bash
# Contained graph-owned log paths under <run-dir>/logs/.
#
# Canonical v2 layout (paths stored relative to run-dir in the ledger):
#   logs/supervisor.log
#   logs/admission.jsonl
#   logs/nodes/<safe-node-id>/<attempt-id>/{runner.log,agent.log,usage.json}
#
# All writes go through graph_logs_resolve. Absolute paths, `..`, symlink
# escapes, and identifiers that sanitize to a collision are rejected.
# Namespace-only v1 paths under <state-root>/logs/<namespace>/ remain
# readable for historical runs and are never opened for append.

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

# graph_logs_v1_namespace_dir <state-root> <namespace>
# Historical namespace-only log root. Read-only.
graph_logs_v1_namespace_dir() {
  local state_root="$1" namespace="$2"
  if [[ -z "$state_root" || -z "$namespace" ]]; then
    echo "Error: graph_logs_v1_namespace_dir requires state-root and namespace" >&2
    return 1
  fi
  printf '%s/logs/%s\n' "${state_root%/}" "$namespace"
}

# graph_logs_v1_supervisor <state-root> <namespace> <run-id>
graph_logs_v1_supervisor() {
  local state_root="$1" namespace="$2" run_id="$3"
  printf '%s/graph-schedule-%s.log\n' \
    "$(graph_logs_v1_namespace_dir "$state_root" "$namespace")" "$run_id"
}

# graph_logs_v1_admission <state-root> <namespace> <run-id>
graph_logs_v1_admission() {
  local state_root="$1" namespace="$2" run_id="$3"
  printf '%s/graph-admission-%s.jsonl\n' \
    "$(graph_logs_v1_namespace_dir "$state_root" "$namespace")" "$run_id"
}

# graph_logs_v1_node_dir <state-root> <namespace> <node-id>
# Prefers the sanitized workspace key directory, then the raw node-id directory.
graph_logs_v1_node_dir() {
  local state_root="$1" namespace="$2" node_id="$3"
  local root key_dir raw_dir
  root="$(graph_logs_v1_namespace_dir "$state_root" "$namespace")/nodes"
  if declare -F graph_workspace_node_key >/dev/null 2>&1; then
    key_dir="$root/$(graph_workspace_node_key "$node_id" 2>/dev/null || true)"
    if [[ -n "$key_dir" && -d "$key_dir" ]]; then
      printf '%s\n' "$key_dir"
      return 0
    fi
  fi
  raw_dir="$root/$node_id"
  if [[ -d "$raw_dir" ]]; then
    printf '%s\n' "$raw_dir"
    return 0
  fi
  printf '%s\n' "${key_dir:-$raw_dir}"
}

# graph_logs_read <run-dir> <relative-path> [v1-fallback-abs]
# Prints the first existing readable file. Never creates or appends.
graph_logs_read() {
  local run_dir="$1" rel="$2" v1_fallback="${3:-}"
  local abs
  if [[ -n "$run_dir" && -n "$rel" ]]; then
    if abs="$(graph_logs_resolve "$run_dir" "$rel" 2>/dev/null)" && [[ -f "$abs" && ! -L "$abs" ]]; then
      printf '%s\n' "$abs"
      return 0
    fi
  fi
  if [[ -n "$v1_fallback" && -f "$v1_fallback" ]]; then
    printf '%s\n' "$v1_fallback"
    return 0
  fi
  return 1
}

# graph_logs_owned_paths <run-dir>
# Prints absolute paths owned by this run: the contained logs/ tree plus any
# relative logPaths recorded in v2 node ledgers. Never emits namespace-only
# v1 node directories.
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

# graph_logs_v1_run_owned_files <state-root> <namespace> <run-id>
# Uniquely named v1 supervisor/admission files for one run. Node attempt
# files under logs/<namespace>/nodes/ are not uniquely owned and are omitted.
graph_logs_v1_run_owned_files() {
  local state_root="$1" namespace="$2" run_id="$3"
  local supervisor admission
  supervisor="$(graph_logs_v1_supervisor "$state_root" "$namespace" "$run_id")" || return 0
  admission="$(graph_logs_v1_admission "$state_root" "$namespace" "$run_id")" || return 0
  [[ -f "$supervisor" ]] && printf '%s\n' "$supervisor"
  [[ -f "$admission" ]] && printf '%s\n' "$admission"
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

# graph_logs_v1_first_regular <dir> <glob-pattern> [attempt-id]
# Prints one non-symlink regular file matching glob-pattern. Prefers a
# basename that contains attempt-id. Otherwise requires exactly one match.
graph_logs_v1_first_regular() {
  local dir="$1" pattern="$2" attempt_id="${3:-}"
  local f base named="" only="" count=0 named_count=0
  local old_nullglob=""
  [[ -n "$dir" && -d "$dir" && -n "$pattern" ]] || return 1
  old_nullglob="$(shopt -p nullglob 2>/dev/null || true)"
  shopt -s nullglob
  for f in "$dir"/$pattern; do
    [[ -f "$f" && ! -L "$f" ]] || continue
    base="${f##*/}"
    count=$((count + 1))
    only="$f"
    if [[ -n "$attempt_id" && "$base" == *"$attempt_id"* ]]; then
      named_count=$((named_count + 1))
      named="$f"
    fi
  done
  if [[ -n "$old_nullglob" ]]; then
    eval "$old_nullglob"
  else
    shopt -u nullglob
  fi
  if [[ "$named_count" -eq 1 ]]; then
    printf '%s\n' "$named"
    return 0
  fi
  if [[ "$count" -eq 1 ]]; then
    printf '%s\n' "$only"
    return 0
  fi
  return 1
}

# graph_logs_v1_stream_file <state-root> <namespace> <node-id> <attempt-id> <stream>
# Historical namespace-only node files. Read-only; never creates or follows
# symlinks. Identifiers with path components are rejected before join.
graph_logs_v1_stream_file() {
  local state_root="$1" namespace="$2" node_id="$3" attempt_id="$4" stream="$5"
  local v1_dir=""
  graph_logs_validate_stream "$stream" || return 1
  if [[ -z "$state_root" || -z "$namespace" || -z "$node_id" ]]; then
    return 1
  fi
  graph_logs_sanitize_id "$node_id" >/dev/null || return 1
  if [[ -n "$attempt_id" ]]; then
    graph_logs_sanitize_id "$attempt_id" >/dev/null || return 1
  fi
  v1_dir="$(graph_logs_v1_node_dir "$state_root" "$namespace" "$node_id")" || return 1
  [[ -d "$v1_dir" ]] || return 1
  case "$stream" in
    runner)
      if [[ -n "$attempt_id" ]]; then
        graph_logs_regular_file "$v1_dir/${attempt_id}.log" && return 0
        graph_logs_regular_file "$v1_dir/attempt-${attempt_id}.log" && return 0
      fi
      graph_logs_regular_file "$v1_dir/runner.log" && return 0
      graph_logs_v1_first_regular "$v1_dir" "attempt-*.log" "$attempt_id" && return 0
      ;;
    agent)
      graph_logs_regular_file "$v1_dir/agent.log" && return 0
      if [[ -n "$attempt_id" ]]; then
        graph_logs_regular_file "$v1_dir/${attempt_id}-output.log" && return 0
      fi
      graph_logs_v1_first_regular "$v1_dir" "plan-runner-*-output.log" "$attempt_id" && return 0
      ;;
    usage)
      graph_logs_regular_file "$v1_dir/usage.json" && return 0
      graph_logs_regular_file "$v1_dir/plan-usage-summary.json" && return 0
      ;;
  esac
  return 1
}

# graph_logs_select <run-dir> <node_json> <attempt_id> <stream>
#   [state-root] [namespace] [node-id]
# Resolves one readable log file. Ledger-owned relative paths are resolved
# only through graph_logs_resolve. A missing contained file may fall back
# to a v1 namespace path. A present but uncontained ledger path is fatal.
graph_logs_select() {
  local run_dir="$1" node_json="$2" attempt_id="$3" stream="$4"
  local state_root="${5:-}" namespace="${6:-}" node_id="${7:-}"
  local resolved_attempt="" rel="" abs="" v1="" rc=0

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

  if [[ -n "$state_root" && -n "$namespace" && -n "$node_id" ]]; then
    v1="$(graph_logs_v1_stream_file "$state_root" "$namespace" "$node_id" "$resolved_attempt" "$stream" 2>/dev/null || true)"
    if [[ -n "$v1" ]]; then
      printf '%s\n' "$v1"
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
