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

killswitch_plan_key_safe() {
  local plan_key="${1:-}"
  local sanitized
  sanitized="${plan_key//[^a-zA-Z0-9._-]/_}"
  sanitized="${sanitized//../_}"
  if [[ -z "$sanitized" ]]; then
    sanitized="unknown"
  fi
  printf '%s\n' "$sanitized"
}

killswitch_sentinel_path() {
  local plan_key="${1:-${RALPH_PLAN_KEY:-}}"
  plan_key="${plan_key:-unknown}"
  local sanitized
  sanitized="$(killswitch_plan_key_safe "$plan_key")" || return 1
  local workspace_root="${RALPH_PLAN_WORKSPACE_ROOT:-}"
  if [[ -z "$workspace_root" ]]; then
    local base_workspace="${WORKSPACE:-$(pwd)}"
    workspace_root="$base_workspace/.ralph-workspace"
  fi
  workspace_root="${workspace_root%/}"
  local sentinel_file="$workspace_root/security/kill-switch.$sanitized.json"
  printf '%s\n' "$sentinel_file"
}

killswitch_file_mtime_epoch() {
  local path="${1:-}"
  [[ -n "$path" && -f "$path" ]] || return 1
  if stat -f '%m' "$path" 2>/dev/null; then
    return 0
  fi
  stat -c '%Y' "$path" 2>/dev/null
}

killswitch_run_start_ts() {
  printf '%s' "${KILLSWITCH_RUN_START_TS:-${_plan_start_ts:-}}"
}

# Returns 0 when the sentinel file exists and predates the current run start.
killswitch_sentinel_is_stale() {
  local path="${1:-}"
  local start_ts="${2:-$(killswitch_run_start_ts)}"
  [[ -n "$path" && -f "$path" ]] || return 1
  [[ "$start_ts" =~ ^[0-9]+$ ]] || return 1
  local mtime
  mtime="$(killswitch_file_mtime_epoch "$path")" || return 1
  [[ "$mtime" =~ ^[0-9]+$ ]] || return 1
  (( mtime < start_ts ))
}

# Returns 0 when a present sentinel should abort the current run.
killswitch_sentinel_should_abort() {
  local path="${1:-}"
  if [[ -z "$path" ]]; then
    path="$(killswitch_sentinel_path 2>/dev/null || true)"
  fi
  [[ -n "$path" && -f "$path" ]] || return 1
  if killswitch_sentinel_is_stale "$path"; then
    return 1
  fi
  return 0
}

killswitch_write_sentinel_from_json() {
  local sentinel_json="${1:-}"
  local plan_key="${RALPH_PLAN_KEY:-}"

  if [[ -z "$sentinel_json" ]]; then
    return 1
  fi

  local sentinel_path
  sentinel_path="$(killswitch_sentinel_path "$plan_key")" || return 1

  local sentinel_dir
  sentinel_dir="$(dirname "$sentinel_path")"
  mkdir -p "$sentinel_dir" 2>/dev/null || return 1

  if command -v jq &>/dev/null; then
    if ! jq -e . >/dev/null 2>&1 <<< "$sentinel_json"; then
      return 1
    fi
  fi

  printf '%s\n' "$sentinel_json" > "$sentinel_path" || return 1
  return 0
}

# Main killswitch trigger: log violation, write sentinel, optionally kill the runner process tree, exit 77.
# Args: tool_name category reason [arguments...]
# This is the unified entry point for all killswitch violations (MCP and native paths).
killswitch_trigger() {
  local tool="${1:-unknown}"
  local category="${2:-policy}"
  local reason="${3:-violation}"
  local arguments="${4:-}"

  killswitch_log_violation "$category" "$tool" "$arguments"

  local dry_run="${RALPH_KILLSWITCH_DRY_RUN:-0}"
  [[ "${_KILLSWITCH_DRY_RUN:-false}" == "true" ]] && dry_run="1"

  local dry_run_mode=""
  if [[ "$dry_run" == "1" ]]; then
    dry_run_mode="DRY_RUN: "
  fi

  if ! killswitch_write_sentinel "$tool" "$category" "$reason" "$arguments"; then
    printf 'Warning: failed to write killswitch sentinel for %s\n' "$tool" >&2
  fi

  if [[ "$dry_run" != "1" ]]; then
    local runner_pid="${KILLSWITCH_RUNNER_PID:-}"
    if [[ -n "$runner_pid" ]]; then
      printf '%sKillswitch activated: killing process tree rooted at %s\n' "$dry_run_mode" "$runner_pid" >&2
      killswitch_kill_process_tree "$runner_pid"
    fi
  else
    printf '%sKillswitch would activate for: %s\n' "$dry_run_mode" "$tool" >&2
  fi

  exit 77
}

killswitch_argument_summary() {
  local args="${1:-}"
  local summary
  summary="$(printf '%s' "$args" | tr '\n' ' ' | tr -s ' ' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | cut -c1-160)"
  if [[ -z "$summary" ]]; then
    summary="(redacted)"
  fi
  printf '%s\n' "$summary"
}

killswitch_argument_hash() {
  local args="${1:-}"
  if [[ -z "$args" ]]; then
    printf ''
    return 0
  fi
  if command -v python3 &>/dev/null; then
    python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())' "$args"
    return 0
  fi
  if command -v sha256sum &>/dev/null; then
    printf '%s' "$args" | sha256sum | awk '{print $1}'
    return 0
  fi
  if command -v shasum &>/dev/null; then
    printf '%s' "$args" | shasum -a 256 | awk '{print $1}'
    return 0
  fi
  if command -v openssl &>/dev/null; then
    printf '%s' "$args" | openssl dgst -sha256 | awk '{print $NF}'
    return 0
  fi
  printf ''
}

killswitch_write_sentinel() {
  local tool="${1:-unknown}"
  local category="${2:-policy}"
  local reason="${3:-violation}"
  local arguments="${4:-}"
  local plan_key="${RALPH_PLAN_KEY:-unknown}"
  local timestamp
  timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  local project_root="${RALPH_PROJECT_ROOT:-${WORKSPACE:-}}"
  local agent_workspace="${RALPH_AGENT_WORKSPACE:-${project_root}}"
  local plan_workspace_root="${RALPH_PLAN_WORKSPACE_ROOT:-${project_root}/.ralph-workspace}"
  local summary
  local hash
  summary="$(killswitch_argument_summary "$arguments")"
  hash="$(killswitch_argument_hash "$arguments")"

  local sentinel_json=""
  if command -v jq &>/dev/null; then
    sentinel_json="$(jq -n \
      --arg timestamp "$timestamp" \
      --arg project_root "$project_root" \
      --arg agent_workspace "$agent_workspace" \
      --arg plan_workspace_root "$plan_workspace_root" \
      --arg plan_key "$plan_key" \
      --arg tool "$tool" \
      --arg category "$category" \
      --arg reason "$reason" \
      --arg summary "$summary" \
      --arg hash "$hash" \
      '{
        timestamp: $timestamp,
        project_root: $project_root,
        agent_workspace: $agent_workspace,
        plan_workspace_root: $plan_workspace_root,
        workspace: $project_root,
        plan_key: $plan_key,
        tool: $tool,
        category: $category,
        reason: $reason,
        arguments: {
          summary: $summary,
          hash: $hash
        }
      }')" || sentinel_json=""
  fi

  if [[ -z "$sentinel_json" ]] && command -v python3 &>/dev/null; then
    sentinel_json="$(python3 - "$timestamp" "$project_root" "$agent_workspace" "$plan_workspace_root" \
      "$plan_key" "$tool" "$category" "$reason" "$summary" "$hash" <<'PY'
import json, sys
timestamp, project_root, agent_workspace, plan_workspace_root, plan_key, tool, category, reason, summary, digest = sys.argv[1:11]
print(json.dumps({
    "timestamp": timestamp,
    "project_root": project_root,
    "agent_workspace": agent_workspace,
    "plan_workspace_root": plan_workspace_root,
    "workspace": project_root,
    "plan_key": plan_key,
    "tool": tool,
    "category": category,
    "reason": reason,
    "arguments": {"summary": summary, "hash": digest},
}))
PY
    )" || sentinel_json=""
  fi

  [[ -n "$sentinel_json" ]] || return 1
  killswitch_write_sentinel_from_json "$sentinel_json" || return 1
  return 0
}
