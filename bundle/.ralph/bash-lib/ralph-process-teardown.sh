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

# Return 0 when the process group has live members other than the given pid.
# Args: $1 = process-group id, $2 = pid to exclude (the caller)
ralph_process_group_has_other_members() {
  local pgid="${1:-}"
  local self_pid="${2:-}"
  local member
  [[ "$pgid" =~ ^[0-9]+$ ]] || return 1
  while IFS= read -r member; do
    [[ "$member" =~ ^[0-9]+$ ]] || continue
    [[ "$member" == "$self_pid" ]] && continue
    return 0
  done < <(pgrep -g "$pgid" 2>/dev/null || true)
  return 1
}

# Env-gated debug trace for the agent group guard. Always returns 0 so it is
# safe under errexit.
ralph_teardown_guard_debug() {
  [[ -n "${RALPH_TEARDOWN_DEBUG_LOG:-}" ]] || return 0
  printf '%s\n' "$*" >>"$RALPH_TEARDOWN_DEBUG_LOG" 2>/dev/null || true
}

# Guard the agent invocation process group against runner death. Must be
# started from inside the backgrounded invocation subshell so it lives in the
# agent's process group. Watches the runner pid and reaps the invocation's own
# process group when the runner disappears (killed mid-teardown, SIGKILL,
# crash) so runtime CLIs and their MCP children are never orphaned. Exits
# quietly once the group has no other members. Ignores INT/TERM/HUP so the
# group-wide SIGTERM sent by normal teardown cannot stop it before it can
# escalate; runner-side teardown reaps it directly via its pid sidecar
# (RALPH_PLAN_INVOCATION_GUARD_PID_FILE).
# Args: $1 = runner pid, $2 = agent process-group id
ralph_run_plan_agent_group_guard() {
  local runner_pid="${1:-}"
  local pgid="${2:-}"
  [[ "$runner_pid" =~ ^[0-9]+$ ]] || return 0
  [[ "$pgid" =~ ^[0-9]+$ ]] || return 0
  (
    trap '' INT TERM HUP
    # The guard must never die from inherited shell strictness: a single
    # failing compound under errexit would silently remove the orphan
    # protection for the whole invocation.
    set +e +u
    set +o pipefail 2>/dev/null
    if [[ -n "${RALPH_PLAN_INVOCATION_GUARD_PID_FILE:-}" ]]; then
      printf '%s\n' "$BASHPID" >"$RALPH_PLAN_INVOCATION_GUARD_PID_FILE" 2>/dev/null
    fi
    ralph_teardown_guard_debug "guard start pid=$BASHPID runner=$runner_pid pgid=$pgid"
    # pgrep's process snapshot can be transiently incomplete during the fork
    # churn of invocation startup (observed on macOS), so a single empty
    # membership result must not end the guard. Require several consecutive
    # empty observations before concluding the group is really gone.
    local empty_checks=0
    while kill -0 "$runner_pid" 2>/dev/null; do
      if ralph_process_group_has_other_members "$pgid" "$BASHPID"; then
        empty_checks=0
      else
        empty_checks=$((empty_checks + 1))
        if (( empty_checks >= 3 )); then
          ralph_teardown_guard_debug "guard exit-empty pid=$BASHPID"
          exit 0
        fi
      fi
      sleep 1
    done
    ralph_teardown_guard_debug "guard runner-dead pid=$BASHPID"
    if ralph_process_group_has_other_members "$pgid" "$BASHPID"; then
      printf '%s\n' "ralph-process-teardown: plan runner $runner_pid exited; reaping agent process group $pgid" >&2
      kill -TERM -"$pgid" 2>/dev/null
      ralph_teardown_guard_debug "guard sent TERM to -$pgid"
      sleep 2
      kill -KILL -"$pgid" 2>/dev/null
    fi
    exit 0
  ) &
}

# Wrapper for backgrounded agent invocations: start the runner-death guard
# inside the invocation's own process group, then run the invoke function.
# $$ still expands to the runner pid inside the backgrounded subshell, while
# BASHPID is the subshell (process-group leader) pid.
# Args: $1 = invoke function name
ralph_run_plan_invoke_with_group_guard() {
  local invoke_fn="$1"
  # Managed runs use the detached session guardian, which sees sibling process
  # groups and escaped sessions. Keep the PGID guard only for direct legacy
  # callers that source an invoker without initializing a process run.
  if [[ -z "${RALPH_PROCESS_RUN_DIR:-}" ]]; then
    ralph_run_plan_agent_group_guard "$$" "$BASHPID"
  fi
  local invoke_rc=0
  if "$invoke_fn"; then
    invoke_rc=0
  else
    invoke_rc=$?
  fi
  # The normal demux path writes this sidecar itself. Pre-invocation failures
  # (capability/config checks) never reach that path, so preserve their real
  # status instead of reporting the runner's synthetic 125 sentinel.
  if [[ -n "${EXIT_CODE_FILE:-}" && ! -f "$EXIT_CODE_FILE" ]]; then
    printf '%s\n' "$invoke_rc" >"$EXIT_CODE_FILE" 2>/dev/null || true
  fi
  return "$invoke_rc"
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
  rm -f "${RALPH_PLAN_INVOCATION_GUARD_PID_FILE:-}" 2>/dev/null || true
}

# Reap the invocation's group guard via its pid sidecar. The guard ignores
# TERM (it must survive group-wide SIGTERM to escalate), so runner-side
# teardown kills it directly with KILL before signalling the group; otherwise
# every teardown would wait out the full grace period and escalate to a
# group SIGKILL just to clear the guard.
ralph_run_plan_reap_agent_group_guard() {
  local sidecar="${RALPH_PLAN_INVOCATION_GUARD_PID_FILE:-}"
  local guard_pid=""
  [[ -n "$sidecar" && -f "$sidecar" ]] || return 0
  guard_pid="$(tr -d '[:space:]' <"$sidecar" 2>/dev/null || true)"
  rm -f "$sidecar" 2>/dev/null || true
  [[ "$guard_pid" =~ ^[0-9]+$ ]] || return 0
  kill -KILL "$guard_pid" 2>/dev/null || true
}

# Cancel runner-owned async shell jobs recorded under the plan tool-results tree.
ralph_run_plan_async_shell_jobs_teardown() {
  local plan_key="${RALPH_PLAN_KEY:-${RALPH_ARTIFACT_NS:-}}"
  local root state_file pid pgid isolated status
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
    pgid="$(jq -r '.pgid // empty' "$state_file" 2>/dev/null || true)"
    isolated="$(jq -r '.isolatedProcessGroup // false' "$state_file" 2>/dev/null || true)"
    if [[ "$isolated" == "true" && "$pgid" =~ ^[0-9]+$ ]]; then
      ralph_kill_process_group "$pgid" 1
    elif [[ "$pid" =~ ^[0-9]+$ ]]; then
      ralph_kill_tree_and_reap "$pid"
    else
      continue
    fi
    jq -c --arg endedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.status = "cancelled" | .endedAt = $endedAt | .terminationReason = "cancelled"' "$state_file" >"${state_file}.tmp" 2>/dev/null && mv "${state_file}.tmp" "$state_file"
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

  # The durable registry owns runtime processes. Stop its verified sessions
  # before touching the legacy shell wrapper group so a live runtime cannot
  # replace children while teardown walks a stale snapshot.
  if declare -F ralph_process_stop_active >/dev/null 2>&1; then
    ralph_process_stop_active "agent-teardown" || true
  fi

  if [[ "$watchdog_pid" =~ ^[0-9]+$ ]]; then
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    unset RALPH_LAUNCHER_WATCHDOG_PID
  fi

  ralph_run_plan_reap_agent_group_guard

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
