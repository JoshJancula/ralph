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
