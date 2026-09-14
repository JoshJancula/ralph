#!/usr/bin/env bash
# shellcheck shell=bash
## Durable run and scope lifecycle helpers for Ralph.

if [[ -n "${RALPH_PROCESS_SUPERVISOR_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
RALPH_PROCESS_SUPERVISOR_LOADED=1

RALPH_PROCESS_MAX_SCOPE_LIVE="${RALPH_PROCESS_MAX_SCOPE_LIVE:-128}"
RALPH_PROCESS_MAX_RUN_LIVE="${RALPH_PROCESS_MAX_RUN_LIVE:-256}"
RALPH_PROCESS_TERM_GRACE_SECONDS="${RALPH_PROCESS_TERM_GRACE_SECONDS:-5}"
RALPH_PROCESS_KILL_GRACE_SECONDS="${RALPH_PROCESS_KILL_GRACE_SECONDS:-2}"
RALPH_PROCESS_SCAN_INTERVAL_SECONDS="${RALPH_PROCESS_SCAN_INTERVAL_SECONDS:-10}"
RALPH_ALLOW_NESTED_RUNS="${RALPH_ALLOW_NESTED_RUNS:-0}"
RALPH_PROCESS_MAX_NESTED_DEPTH="${RALPH_PROCESS_MAX_NESTED_DEPTH:-1}"
export RALPH_PROCESS_MAX_SCOPE_LIVE RALPH_PROCESS_MAX_RUN_LIVE
export RALPH_PROCESS_TERM_GRACE_SECONDS RALPH_PROCESS_KILL_GRACE_SECONDS
export RALPH_PROCESS_SCAN_INTERVAL_SECONDS
export RALPH_ALLOW_NESTED_RUNS RALPH_PROCESS_MAX_NESTED_DEPTH

ralph_process_python() {
  local lib_dir script_dir
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  script_dir="$(cd "$lib_dir/../python" && pwd)"
  printf '%s' "$script_dir/ralph_process_supervisor.py"
}

ralph_process_require_python() {
  if ! command -v python3 >/dev/null 2>&1; then
    printf '%s\n' "Error: Ralph process supervision requires Python 3." >&2
    return 2
  fi
  local script
  script="$(ralph_process_python)"
  if [[ ! -f "$script" ]]; then
    printf '%s\n' "Error: Ralph process supervisor is missing: $script" >&2
    return 2
  fi
}

# Initialize a durable process run or attach a permitted structural/nested run.
# Args: state root, project root, canonical plan path, kind (plan|orchestrator)
ralph_process_run_init() {
  local state_root="$1"
  local project_root="$2"
  local plan_path="$3"
  local kind="$4"
  local script exports depth
  ralph_process_require_python || return $?
  script="$(ralph_process_python)"
  depth="${RALPH_PROCESS_RUN_DEPTH:-0}"
  [[ "$depth" =~ ^[0-9]+$ ]] || depth=0

  if [[ -n "${RALPH_PROCESS_RUN_DIR:-}" ]]; then
    if [[ "${RALPH_PROCESS_ALLOW_CHILD:-0}" != "1" ]]; then
      if [[ "$RALPH_ALLOW_NESTED_RUNS" != "1" ]]; then
        printf '%s\n' "Error: nested Ralph runs are disabled while a managed runtime is active." >&2
        printf '%s\n' "Set RALPH_ALLOW_NESTED_RUNS=1 to allow an intentional nested run." >&2
        return 2
      fi
      depth=$((depth + 1))
      if (( depth > RALPH_PROCESS_MAX_NESTED_DEPTH )); then
        printf '%s\n' "Error: nested Ralph depth $depth exceeds RALPH_PROCESS_MAX_NESTED_DEPTH=$RALPH_PROCESS_MAX_NESTED_DEPTH." >&2
        return 2
      fi
    fi
    exports="$(python3 "$script" attach --run-dir "$RALPH_PROCESS_RUN_DIR" --plan "$plan_path" --lease-owner-pid "$$")" || return $?
    eval "$exports"
    RALPH_PROCESS_RUN_DEPTH="$depth"
    RALPH_PROCESS_ATTACHED_PLAN="$plan_path"
    export RALPH_PROCESS_RUN_DEPTH
    export RALPH_PROCESS_ATTACHED_PLAN
    unset RALPH_PROCESS_ALLOW_CHILD
    return 0
  fi

  local owner_start=""
  owner_start="$(
    PYTHONPATH="$(dirname "$script")" python3 -c \
      "from ralph_process_supervisor import pid_identity; print(pid_identity($$))" \
      2>/dev/null || true
  )"
  exports="$(python3 "$script" init \
    --state-root "$state_root" \
    --project-root "$project_root" \
    --plan "$plan_path" \
    --kind "$kind" \
    --owner-pid "$$" \
    --owner-start "${owner_start}" \
    --max-live "$RALPH_PROCESS_MAX_RUN_LIVE")" || return $?
  eval "$exports"
  RALPH_PROCESS_RUN_DEPTH=0
  export RALPH_PROCESS_RUN_DEPTH
}

# Execute one managed scope in a new session. All arguments after runtime are
# passed directly to exec without shell interpolation.
# Args: kind, runtime, command...
ralph_process_scope_exec() {
  local kind="$1"
  local runtime="$2"
  shift 2
  local script scope_id
  ralph_process_require_python || return $?
  if [[ -z "${RALPH_PROCESS_RUN_DIR:-}" ]]; then
    printf '%s\n' "Error: Ralph process scope requested before run initialization." >&2
    return 2
  fi
  script="$(ralph_process_python)"
  scope_id="${kind}-${runtime:-generic}-$(date +%s)"
  python3 "$script" run-scope \
    --run-dir "$RALPH_PROCESS_RUN_DIR" \
    --scope-id "$scope_id" \
    --kind "$kind" \
    --runtime "$runtime" \
    --max-live "$RALPH_PROCESS_MAX_SCOPE_LIVE" \
    --pid-file "${RALPH_PLAN_INVOCATION_CLI_PID_FILE:-}" \
    --scope-owner-pid "$$" \
    -- "$@"
}

# Stop all currently active scopes but keep the guardian for later TODOs.
ralph_process_stop_active() {
  local reason="${1:-runner-teardown}"
  [[ -n "${RALPH_PROCESS_RUN_DIR:-}" ]] || return 0
  if [[ "${RALPH_PROCESS_RUN_OWNED:-0}" == "1" ]]; then
    python3 "$(ralph_process_python)" stop-active \
      --run-dir "$RALPH_PROCESS_RUN_DIR" --reason "$reason" >/dev/null 2>&1 || return $?
  else
    python3 "$(ralph_process_python)" stop-active \
      --run-dir "$RALPH_PROCESS_RUN_DIR" --reason "$reason" \
      --owner-pid "$$" >/dev/null 2>&1 || return $?
  fi
}

ralph_process_check_abort() {
  local abort_file="${RALPH_PROCESS_RUN_DIR:-}/abort.json"
  [[ -n "${RALPH_PROCESS_RUN_DIR:-}" && -f "$abort_file" ]] || return 0
  printf '%s\n' "Error: Ralph process safety limit was exceeded; managed processes were terminated." >&2
  return 78
}

# Prefer ralph_kill_tree (TERM then KILL) for proven-owned supervisor cancel.
# Timing stays in ralph-process-teardown.sh; cancel callers must persist cancel
# intent before invoking this so signal handlers record cancelled.
ralph_process_term_kill_tree() {
  local root_pid="${1:-}"
  if ! declare -F ralph_kill_tree >/dev/null 2>&1; then
    # shellcheck source=./ralph-process-teardown.sh
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ralph-process-teardown.sh"
  fi
  ralph_kill_tree "$root_pid"
}

# Close a run owned by this shell. Attached stage/nested shells leave the
# parent guardian running; their scopes are still stopped before returning.
ralph_process_run_close() {
  local reason="${1:-runner-exit}"
  [[ -n "${RALPH_PROCESS_RUN_DIR:-}" ]] || return 0
  if [[ "${RALPH_PROCESS_RUN_OWNED:-0}" == "1" ]]; then
    python3 "$(ralph_process_python)" close \
      --run-dir "$RALPH_PROCESS_RUN_DIR" --reason "$reason" >/dev/null 2>&1 || return $?
  else
    ralph_process_stop_active "$reason" || return $?
    if [[ -n "${RALPH_PROCESS_ATTACHED_PLAN:-}" ]]; then
      python3 "$(ralph_process_python)" release-lease \
        --run-dir "$RALPH_PROCESS_RUN_DIR" \
        --plan "$RALPH_PROCESS_ATTACHED_PLAN" \
        --lease-owner-pid "$$" >/dev/null 2>&1 || true
    fi
  fi
}
