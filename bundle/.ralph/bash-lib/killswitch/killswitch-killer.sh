#!/usr/bin/env bash

if [[ -n "${RALPH_KILLSWITCH_KILLER_LOADED:-}" ]]; then
  return
fi
RALPH_KILLSWITCH_KILLER_LOADED=1

# Recursively collect all descendant PIDs of a given PID via pgrep -P.
_killswitch_get_descendants() {
  local pid="$1"
  local children
  children="$(pgrep -P "$pid" 2>/dev/null || true)"
  local child
  for child in $children; do
    printf '%s\n' "$child"
    _killswitch_get_descendants "$child"
  done
}

# Send SIGTERM to the given PID and all its descendants, wait 2 seconds grace,
# then send SIGKILL to any processes that are still alive.
killswitch_kill_process_tree() {
  local root_pid="$1"

  if declare -F ralph_process_stop_active >/dev/null 2>&1 && [[ -n "${RALPH_PROCESS_RUN_DIR:-}" ]]; then
    ralph_process_stop_active "killswitch" || true
    return 0
  fi
  local -a all_pids=()
  local desc

  while IFS= read -r desc; do
    [[ -n "$desc" ]] && all_pids+=("$desc")
  done < <(_killswitch_get_descendants "$root_pid")
  all_pids+=("$root_pid")

  local pid
  # Stop the root first so it cannot replace descendants after this snapshot.
  kill -TERM "$root_pid" 2>/dev/null || true
  for pid in "${all_pids[@]}"; do
    [[ "$pid" == "$root_pid" ]] && continue
    kill -TERM "$pid" 2>/dev/null || true
  done

  sleep 2

  for pid in "${all_pids[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done
}

# Append a JSON line to the killswitch violations log.
# Args: violation_type tool_name tool_args
killswitch_log_violation() {
  local violation_type="$1"
  local tool_name="$2"
  local tool_args="${3:-}"

  local ks_root="${RALPH_PLAN_WORKSPACE_ROOT:-${WORKSPACE:-.}/.ralph-workspace}"
  mkdir -p "$ks_root" 2>/dev/null || true

  python3 - "$violation_type" "$tool_name" "$tool_args" \
      "${RALPH_PLAN_KEY:-}" "${RUNTIME:-}" "$ks_root" 2>/dev/null <<'PY' || true
import json, os, sys, time

violation_type, tool_name, tool_args, plan_key, runtime, ks_root = sys.argv[1:7]
timestamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

entry = {
    "timestamp": timestamp,
    "violation_type": violation_type,
    "tool_name": tool_name,
    "tool_args": tool_args,
    "plan_key": plan_key,
    "runtime": runtime,
}

log_path = os.path.join(ks_root, "killswitch-violations.log")
with open(log_path, "a") as fh:
    fh.write(json.dumps(entry) + "\n")
PY
}

# Write (overwrite) the killswitch triggered status JSON file.
# Args: violation_type tool_name tool_args killed(true|false)
killswitch_write_triggered_json() {
  local violation_type="$1"
  local tool_name="$2"
  local tool_args="${3:-}"
  local killed="${4:-false}"

  local ks_root="${RALPH_PLAN_WORKSPACE_ROOT:-${WORKSPACE:-.}/.ralph-workspace}"
  mkdir -p "$ks_root" 2>/dev/null || true

  python3 - "$violation_type" "$tool_name" "$tool_args" \
      "${RALPH_PLAN_KEY:-}" "${RUNTIME:-}" "$ks_root" "$killed" 2>/dev/null <<'PY' || true
import json, os, sys, time

violation_type, tool_name, tool_args, plan_key, runtime, ks_root, killed_str = sys.argv[1:8]
timestamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

entry = {
    "timestamp": timestamp,
    "violation_type": violation_type,
    "tool_name": tool_name,
    "tool_args": tool_args,
    "plan_key": plan_key,
    "runtime": runtime,
    "killed": killed_str == "true",
}

triggered_path = os.path.join(ks_root, "killswitch-triggered.json")
with open(triggered_path, "w") as fh:
    fh.write(json.dumps(entry) + "\n")
PY
}

# Main killswitch trigger: log violation, optionally kill the runner process tree, exit 77.
# Args: violation_type tool_name [args...]
killswitch_trigger() {
  local violation_type="$1"
  local tool_name="$2"
  local tool_args="${*:3}"

  killswitch_log_violation "$violation_type" "$tool_name" "$tool_args"

  local killed="false"
  local dry_run="${RALPH_KILLSWITCH_DRY_RUN:-0}"
  [[ "${_KILLSWITCH_DRY_RUN:-false}" == "true" ]] && dry_run="1"

  if [[ "$dry_run" != "1" ]]; then
    local runner_pid="${KILLSWITCH_RUNNER_PID:-}"
    if [[ -n "$runner_pid" ]]; then
      killswitch_kill_process_tree "$runner_pid"
      killed="true"
    fi
  fi

  killswitch_write_triggered_json "$violation_type" "$tool_name" "$tool_args" "$killed"

  exit 77
}
