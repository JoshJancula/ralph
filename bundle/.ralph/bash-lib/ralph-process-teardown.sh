#!/usr/bin/env bash
# shellcheck shell=bash
## Process teardown helpers for run-plan.
## Safe to source repeatedly; functions no-op when launcher tracking is unavailable.

if [[ -n "${RALPH_PROCESS_TEARDOWN_LOADED:-}" ]]; then
  # shellcheck disable=SC2317
  return 0 2>/dev/null || exit 0
fi
RALPH_PROCESS_TEARDOWN_LOADED=1

# Recursively terminate a process tree, walking descendants breadth-first and
# sending TERM to leaves before the root. Any survivors receive KILL after a
# brief grace period.
# Args: $1 = root pid
ralph_kill_tree() {
  local root_pid="${1:-}"
  local -a queue descendants
  local queue_index=0 current_pid child_pid
  local descendant_index

  [[ "$root_pid" =~ ^[0-9]+$ ]] || return 0

  queue=("$root_pid")
  while (( queue_index < ${#queue[@]} )); do
    current_pid="${queue[$queue_index]}"
    ((queue_index++)) || true
    descendants+=("$current_pid")

    while IFS= read -r child_pid; do
      [[ -n "$child_pid" ]] || continue
      queue+=("$child_pid")
    done < <(pgrep -P "$current_pid" 2>/dev/null || true)
  done

  for ((descendant_index=${#descendants[@]} - 1; descendant_index >= 0; descendant_index--)); do
    kill -TERM "${descendants[$descendant_index]}" 2>/dev/null || true
  done

  sleep 0.2

  for current_pid in "${descendants[@]}"; do
    kill -0 "$current_pid" 2>/dev/null || continue
    kill -KILL "$current_pid" 2>/dev/null || true
  done
}

# Kill a process tree and reap the root process.
# Prefer this over ralph_kill_tree when the caller holds AGENT_PID, so the
# backgrounded subshell is waited on and does not become a zombie.
# Args: $1 = root pid
ralph_kill_tree_and_reap() {
  local root_pid="${1:-}"
  [[ "$root_pid" =~ ^[0-9]+$ ]] || return 0
  ralph_kill_tree "$root_pid"
  wait "$root_pid" 2>/dev/null || true
}

# Send signals to the entire process group whose leader is $1. First TERM,
# then KILL after a grace period. Returns 0 whether or not the group still
# existed; any live members after KILL are left to the caller to handle.
# Args: $1 = process-group leader pid
# Optional: $2 = max wait seconds before KILL (default: 2)
ralph_kill_process_group() {
  local pgid="${1:-}"
  local max_wait="${2:-2}"
  [[ "$pgid" =~ ^[0-9]+$ ]] || return 0
  [[ "$max_wait" =~ ^[0-9]+$ ]] || max_wait=2
  kill -TERM -"$pgid" 2>/dev/null || true
  local waited=0
  while (( waited < max_wait * 10 )) && kill -0 -"$pgid" 2>/dev/null; do
    sleep 0.1
    ((waited++)) || true
  done
  if kill -0 -"$pgid" 2>/dev/null; then
    kill -KILL -"$pgid" 2>/dev/null || true
  fi
}

# Watch the launcher process and tear down the current shell if it disappears.
# Intended to run in the background.
ralph_launcher_death_watchdog() {
  local launcher_pid="${RALPH_LAUNCHER_PID:-}"
  local our_ppid="$PPID"

  [[ "$launcher_pid" =~ ^[0-9]+$ ]] || return 0

  # If the stored launcher is our own parent shell, fall back to monitoring PPID
  # so the watchdog stays useful even when RALPH_LAUNCHER_PID was inherited
  # from an exec'd ancestor.
  if [[ "$launcher_pid" == "$$" ]]; then
    launcher_pid="$our_ppid"
  fi

  [[ "$launcher_pid" =~ ^[0-9]+$ ]] || return 0

  while kill -0 "$launcher_pid" 2>/dev/null; do
    sleep 1
  done

  printf '%s\n' "ralph-process-teardown: launcher $launcher_pid exited; reaping $$" >&2
  ralph_kill_tree "$$"
  kill -KILL "$$"
}

# Read a numeric runtime CLI PID from the per-invocation sidecar when present.
# Args: none (uses RALPH_PLAN_INVOCATION_CLI_PID_FILE)
# Prints the PID on success; returns non-zero when missing or malformed.
ralph_run_plan_read_cli_pid_from_sidecar() {
  local sidecar="${RALPH_PLAN_INVOCATION_CLI_PID_FILE:-}"
  local cli_pid=""
  [[ -n "$sidecar" && -f "$sidecar" ]] || return 1
  cli_pid="$(tr -d '[:space:]' <"$sidecar" 2>/dev/null || true)"
  [[ "$cli_pid" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$cli_pid"
}

# Remove per-invocation CLI tracking sidecars for the current runner process.
ralph_run_plan_remove_invocation_sidecars() {
  rm -f "${RALPH_PLAN_INVOCATION_CLI_PID_FILE:-}" 2>/dev/null || true
  rm -f "${RALPH_PLAN_INVOCATION_CLI_START_FILE:-}" 2>/dev/null || true
}

# Cancel runner-owned async shell jobs recorded under the plan tool-results tree.
ralph_run_plan_async_shell_jobs_teardown() {
  local plan_key="${RALPH_PLAN_KEY:-${RALPH_ARTIFACT_NS:-}}"
  local root state_file pid status
  [[ -n "$plan_key" && -n "${WORKSPACE:-}" ]] || return 0
  [[ "$plan_key" =~ ^[A-Za-z0-9._-]+$ ]] || return 0
  root="$WORKSPACE/.ralph-workspace/tool-results/$plan_key/shell-jobs"
  [[ -d "$root" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  while IFS= read -r state_file; do
    [[ -f "$state_file" ]] || continue
    status="$(jq -r '.status // empty' "$state_file" 2>/dev/null || true)"
    [[ "$status" == "running" ]] || continue
    pid="$(jq -r '.pid // empty' "$state_file" 2>/dev/null || true)"
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    ralph_kill_tree_and_reap "$pid"
    jq -c --arg endedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.status = "cancelled" | .endedAt = $endedAt' "$state_file" >"${state_file}.tmp" 2>/dev/null && mv "${state_file}.tmp" "$state_file"
  done < <(find "$root" -mindepth 2 -maxdepth 2 -name state.json -type f 2>/dev/null)
}

# Idempotent run-plan agent teardown: process group, escaped CLI, watchdog, async jobs.
# Args: none
# Returns: 0
ralph_run_plan_agent_teardown() {
  local agent_pid="${AGENT_PID:-}"
  local cli_pid=""
  local watchdog_pid="${RALPH_LAUNCHER_WATCHDOG_PID:-}"

  if [[ "${RALPH_RUN_PLAN_AGENT_TEARDOWN_DONE:-}" == "1" ]]; then
    return 0
  fi
  RALPH_RUN_PLAN_AGENT_TEARDOWN_DONE=1

  if [[ "$watchdog_pid" =~ ^[0-9]+$ ]]; then
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    unset RALPH_LAUNCHER_WATCHDOG_PID
  fi

  if [[ "$agent_pid" =~ ^[0-9]+$ ]]; then
    ralph_kill_process_group "$agent_pid" 2
    ralph_kill_tree_and_reap "$agent_pid"
    kill -0 -"$agent_pid" 2>/dev/null && kill -KILL -"$agent_pid" 2>/dev/null || true
  fi

  if cli_pid="$(ralph_run_plan_read_cli_pid_from_sidecar 2>/dev/null)"; then
    ralph_kill_tree_and_reap "$cli_pid"
  fi

  ralph_run_plan_async_shell_jobs_teardown
  if declare -F ralph_claude_speculative_cache_warm_teardown >/dev/null 2>&1; then
    ralph_claude_speculative_cache_warm_teardown
  fi
  ralph_run_plan_remove_invocation_sidecars
}

# Public alias used by run-plan exit and interrupt handlers.
ralph_run_plan_process_teardown_on_exit() {
  ralph_run_plan_agent_teardown
}
