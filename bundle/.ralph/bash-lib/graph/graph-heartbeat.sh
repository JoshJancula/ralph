#!/usr/bin/env bash
# Read-only heartbeat liveness classifier for graph runs.
#
# Decides whether the owning supervisor of a graph run is still alive based on
# the heartbeat timestamp and process-start identity recorded in run.json.
# The classifier never writes state; it only reads run.json and, when needed,
# inspects the process table.
#
# Output is one word: healthy, stale, or unknown.
#   healthy  - heartbeat is fresh (within TTL).
#   stale    - heartbeat has expired AND we can prove the owning process is
#              dead or its PID has been reused (process-start identity differs).
#   unknown  - heartbeat is missing/unparseable, the required owner metadata is
#              absent, or process inspection is restricted/unavailable.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

GRAPH_HEARTBEAT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -F graph_state_read_run_v2 >/dev/null 2>&1; then
  # shellcheck source=./graph-state.sh
  source "$GRAPH_HEARTBEAT_SCRIPT_DIR/graph-state.sh"
fi

# Default heartbeat TTL in seconds. Tests override via GRAPH_HEARTBEAT_TTL_SECONDS
# or the optional fourth argument to graph_heartbeat_classify_run.
GRAPH_HEARTBEAT_TTL_SECONDS="${GRAPH_HEARTBEAT_TTL_SECONDS:-60}"

# graph_heartbeat_parse_iso_to_epoch <iso>
# Converts an ISO-8601 timestamp (seconds precision, trailing Z) to a Unix
# epoch. Supports GNU date and BSD/macOS date. Returns 1 when unparseable.
graph_heartbeat_parse_iso_to_epoch() {
  local iso="$1" epoch
  [[ -n "$iso" ]] || return 1

  # GNU date
  if epoch="$(date -d "$iso" +%s 2>/dev/null)" && [[ -n "$epoch" ]]; then
    printf '%s\n' "$epoch"
    return 0
  fi

  # BSD / macOS date
  if epoch="$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null)" && [[ -n "$epoch" ]]; then
    printf '%s\n' "$epoch"
    return 0
  fi

  return 1
}

# graph_heartbeat_now_epoch
# Current Unix epoch. Honors GRAPH_HEARTBEAT_NOW_EPOCH for tests.
graph_heartbeat_now_epoch() {
  if [[ -n "${GRAPH_HEARTBEAT_NOW_EPOCH:-}" ]]; then
    printf '%s\n' "$GRAPH_HEARTBEAT_NOW_EPOCH"
    return 0
  fi
  date +%s
}

# graph_heartbeat_process_start_id_of_pid <pid>
# Best-effort process-start identity for <pid>.
#   Exit 0: process exists; start identity printed on stdout.
#   Exit 1: process is dead or pid is invalid.
#   Exit 2: process inspection is unavailable or restricted.
# Honors GRAPH_HEARTBEAT_PROCESS_LOOKUP=off to force the unavailable path.
graph_heartbeat_process_start_id_of_pid() {
  local pid="$1" start=""

  if [[ -z "$pid" || ! "$pid" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  if [[ "${GRAPH_HEARTBEAT_PROCESS_LOOKUP:-}" == "off" ]]; then
    return 2
  fi

  # Linux /proc path: a missing /proc/<pid> directory means the process is dead.
  if [[ -d "/proc" ]]; then
    if [[ -d "/proc/$pid" ]]; then
      if command -v stat >/dev/null 2>&1; then
        start="$(stat -c %Z "/proc/$pid" 2>/dev/null || stat -f %B "/proc/$pid" 2>/dev/null)"
      fi
      if [[ -n "$start" ]]; then
        printf '%s\n' "$start"
        return 0
      fi
      # /proc entry exists but we cannot read it; treat as unavailable.
      return 2
    fi
    return 1
  fi

  # Portable fallback: ps -o lstart. Empty output means the process is dead.
  if command -v ps >/dev/null 2>&1; then
    start="$(ps -o lstart= -p "$pid" 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | head -n1)"
    if [[ -n "$start" ]]; then
      printf '%s\n' "$start"
      return 0
    fi
    return 1
  fi

  return 2
}

# graph_heartbeat_classify_run <workspace> <namespace> <run_id> [ttl_seconds] [now_epoch]
# Pure read-only classifier. Prints exactly one of: healthy, stale, unknown.
graph_heartbeat_classify_run() {
  local workspace="$1" namespace="$2" run_id="$3"
  local ttl_seconds="${4:-${GRAPH_HEARTBEAT_TTL_SECONDS:-60}}"
  local now_epoch="${5:-${GRAPH_HEARTBEAT_NOW_EPOCH:-$(graph_heartbeat_now_epoch)}}"
  local run_file run_json heartbeat_at heartbeat_epoch pid owner_start_id
  local current_start_id pid_rc=0

  if [[ -z "$workspace" || -z "$namespace" || -z "$run_id" ]]; then
    echo "unknown"
    return 0
  fi

  run_file="$(graph_state_run_file "$workspace" "$namespace" "$run_id")" || true
  if [[ -z "$run_file" || ! -f "$run_file" ]]; then
    echo "unknown"
    return 0
  fi

  run_json="$(graph_state_read_run_v2 "$workspace" "$namespace" "$run_id")" || true
  if [[ -z "$run_json" ]]; then
    echo "unknown"
    return 0
  fi

  heartbeat_at="$(jq -r '.heartbeatAt // empty' <<<"$run_json" 2>/dev/null)"
  if [[ -z "$heartbeat_at" ]]; then
    echo "unknown"
    return 0
  fi

  heartbeat_epoch="$(graph_heartbeat_parse_iso_to_epoch "$heartbeat_at")" || true
  if [[ -z "$heartbeat_epoch" || ! "$heartbeat_epoch" =~ ^[0-9]+$ ]]; then
    echo "unknown"
    return 0
  fi

  [[ "$ttl_seconds" =~ ^[0-9]+$ ]] || ttl_seconds=60

  # Fresh heartbeat: owner is considered healthy regardless of process state.
  if [[ "$(( now_epoch - heartbeat_epoch ))" -lt "$ttl_seconds" ]]; then
    echo "healthy"
    return 0
  fi

  # Heartbeat expired. Prove owner mismatch or death before calling stale.
  pid="$(jq -r '.supervisorPid // empty' <<<"$run_json" 2>/dev/null)"
  owner_start_id="$(jq -r '.ownerProcessStartId // empty' <<<"$run_json" 2>/dev/null)"
  if [[ -z "$pid" || -z "$owner_start_id" ]]; then
    echo "unknown"
    return 0
  fi
  [[ "$pid" =~ ^[0-9]+$ ]] || { echo "unknown"; return 0; }

  current_start_id="$(graph_heartbeat_process_start_id_of_pid "$pid")"; pid_rc=$?

  if [[ "$pid_rc" -eq 2 ]]; then
    echo "unknown"
    return 0
  fi

  if [[ "$pid_rc" -eq 1 ]]; then
    echo "stale"
    return 0
  fi

  if [[ "$current_start_id" != "$owner_start_id" ]]; then
    echo "stale"
    return 0
  fi

  # Expired heartbeat, but we cannot prove owner mismatch or death.
  echo "unknown"
  return 0
}
