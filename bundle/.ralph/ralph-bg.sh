#!/usr/bin/env bash
# Launch a durable background job for the active plan TODO (tier 1/2 launch surface).
#
# Usage:
#   .ralph/ralph-bg.sh '<shell command>'
#
# The command must be passed as exactly one quoted argument. Requires an active
# run-plan invocation with exported TODO identity and RALPH_BG_JOBS != 0.

set -euo pipefail

RALPH_BG_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bash-lib/run-plan/run-plan-bg-job-state.sh
source "$RALPH_BG_SCRIPT_DIR/bash-lib/run-plan/run-plan-bg-job-state.sh"
if ! declare -F ralph_native_shell_terminate_spawned_job >/dev/null 2>&1; then
  # shellcheck source=bash-lib/native-hook/native-shell-wrapper.sh
  source "$RALPH_BG_SCRIPT_DIR/bash-lib/native-hook/native-shell-wrapper.sh"
fi
if ! declare -F ralph_process_scope_exec >/dev/null 2>&1; then
  # shellcheck source=bash-lib/ralph-process-supervisor.sh
  source "$RALPH_BG_SCRIPT_DIR/bash-lib/ralph-process-supervisor.sh"
fi

RALPH_BG_JOBS="${RALPH_BG_JOBS:-0}"
RALPH_BG_JOB_TIMEOUT="${RALPH_BG_JOB_TIMEOUT:-3600}"

ralph_bg_usage() {
  cat <<'EOF' >&2
Usage: ralph-bg.sh '<shell command>'

Launch one background job for the active plan TODO. The command must be passed
as a single quoted argument.
EOF
}

ralph_bg_emit_json() {
  jq -c '.'
}

ralph_bg_require_plan_context() {
  if [[ -z "${RALPH_PROCESS_RUN_DIR:-}" ]]; then
    printf '%s\n' "Error: ralph-bg.sh requires an active run-plan process run (RALPH_PROCESS_RUN_DIR)" >&2
    return 1
  fi
  if [[ "${RALPH_RUN_PLAN_ACTIVE:-0}" != "1" ]]; then
    printf '%s\n' "Error: ralph-bg.sh requires an active run-plan invocation (RALPH_RUN_PLAN_ACTIVE)" >&2
    return 1
  fi
  if [[ -z "${RALPH_CURRENT_PLAN_PATH:-}" || -z "${RALPH_CURRENT_TODO_LINE:-}" || -z "${RALPH_CURRENT_TODO_ORDINAL:-}" || -z "${RALPH_CURRENT_TODO_HASH:-}" ]]; then
    printf '%s\n' "Error: ralph-bg.sh requires current plan and TODO identity exports" >&2
    return 1
  fi
  if [[ -z "${RALPH_SESSION_DIR:-}" || -z "${RALPH_PLAN_KEY:-}" ]]; then
    printf '%s\n' "Error: ralph-bg.sh requires RALPH_SESSION_DIR and RALPH_PLAN_KEY" >&2
    return 1
  fi
  if [[ -z "${RALPH_AGENT_WORKSPACE:-}" ]]; then
    printf '%s\n' "Error: ralph-bg.sh requires RALPH_AGENT_WORKSPACE" >&2
    return 1
  fi
  return 0
}

ralph_bg_validate_command_args() {
  local argc="${1:-0}"
  shift || true
  local command="${1:-}"

  if [[ ! "$argc" =~ ^[0-9]+$ || "$argc" -eq 0 ]]; then
    printf '%s\n' "Error: ralph-bg.sh requires exactly one quoted shell command argument" >&2
    ralph_bg_usage
    return 1
  fi
  if (( argc > 1 )); then
    printf '%s\n' "Error: ralph-bg.sh received an unquoted or malformed command (expected one argument, got $argc)" >&2
    return 1
  fi
  if [[ -z "$command" ]]; then
    printf '%s\n' "Error: ralph-bg.sh command must not be empty" >&2
    return 1
  fi
  if [[ "$command" == *$'\n'* || "$command" == *$'\r'* ]]; then
    printf '%s\n' "Error: ralph-bg.sh command must be a single-line shell command" >&2
    return 1
  fi
  return 0
}

ralph_bg_normalize_path_for_compare() {
  local path="${1:-}"
  [[ -n "$path" ]] || return 1
  if [[ "$path" != /* ]]; then
    local root="${RALPH_PROJECT_ROOT:-${RALPH_AGENT_WORKSPACE:-}}"
    [[ -n "$root" ]] || return 1
    path="$root/$path"
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$path" 2>/dev/null && return 0
  fi
  local dir base
  dir="$(cd "$(dirname "$path")" 2>/dev/null && pwd)" || return 1
  base="$(basename "$path")"
  printf '%s/%s\n' "$dir" "$base"
}

ralph_bg_command_selects_foreign_target() {
  local command="${1:-}"
  local token current expected ref
  local current_plan="${RALPH_CURRENT_PLAN_PATH:-}"
  local current_hash="${RALPH_CURRENT_TODO_HASH:-}"
  local current_plan_key="${RALPH_PLAN_KEY:-}"
  local current_line="${RALPH_CURRENT_TODO_LINE:-}"
  local current_ordinal="${RALPH_CURRENT_TODO_ORDINAL:-}"
  local current_id="${RALPH_CURRENT_TODO_ID:-}"

  while [[ "$command" =~ (--plan|--file)[[:space:]]+([^[:space:]]+) ]]; do
    ref="${BASH_REMATCH[2]}"
    command="${command#*"${BASH_REMATCH[0]}"}"
    expected="$(ralph_bg_normalize_path_for_compare "$current_plan" 2>/dev/null || printf '%s' "$current_plan")"
    token="$(ralph_bg_normalize_path_for_compare "$ref" 2>/dev/null || printf '%s' "$ref")"
    if [[ -n "$expected" && -n "$token" && "$token" != "$expected" ]]; then
      printf '%s\n' "foreign-plan"
      return 0
    fi
  done

  if [[ "$command" =~ RALPH_PLAN_KEY=([^[:space:]]+) ]]; then
    if [[ "${BASH_REMATCH[1]}" != "$current_plan_key" ]]; then
      printf '%s\n' "foreign-plan-key"
      return 0
    fi
  fi
  if [[ "$command" =~ RALPH_CURRENT_PLAN_PATH=([^[:space:]]+) ]]; then
    expected="$(ralph_bg_normalize_path_for_compare "$current_plan" 2>/dev/null || printf '%s' "$current_plan")"
    token="$(ralph_bg_normalize_path_for_compare "${BASH_REMATCH[1]}" 2>/dev/null || printf '%s' "${BASH_REMATCH[1]}")"
    if [[ -n "$expected" && -n "$token" && "$token" != "$expected" ]]; then
      printf '%s\n' "foreign-plan-path"
      return 0
    fi
  fi
  if [[ "$command" =~ RALPH_CURRENT_TODO_HASH=([^[:space:]]+) ]]; then
    if [[ "${BASH_REMATCH[1]}" != "$current_hash" ]]; then
      printf '%s\n' "foreign-todo-hash"
      return 0
    fi
  fi
  if [[ "$command" =~ RALPH_CURRENT_TODO_LINE=([^[:space:]]+) ]]; then
    if [[ "${BASH_REMATCH[1]}" != "$current_line" ]]; then
      printf '%s\n' "foreign-todo-line"
      return 0
    fi
  fi
  if [[ "$command" =~ RALPH_CURRENT_TODO_ORDINAL=([^[:space:]]+) ]]; then
    if [[ "${BASH_REMATCH[1]}" != "$current_ordinal" ]]; then
      printf '%s\n' "foreign-todo-ordinal"
      return 0
    fi
  fi
  if [[ -n "$current_id" && "$command" =~ RALPH_CURRENT_TODO_ID=([^[:space:]]+) ]]; then
    if [[ "${BASH_REMATCH[1]}" != "$current_id" ]]; then
      printf '%s\n' "foreign-todo-id"
      return 0
    fi
  fi

  printf '%s\n' ""
  return 1
}

# Resolve a durable owner PID for background job records and process scopes.
# ralph-bg.sh itself exits immediately after launch, so $$ must not be the owner
# or stop-hook / recovery logic treats every job as owner-dead.
ralph_bg_resolve_owner_pid() {
  if [[ "${RALPH_LAUNCHER_PID:-}" =~ ^[0-9]+$ ]] && kill -0 "$RALPH_LAUNCHER_PID" 2>/dev/null; then
    printf '%s\n' "$RALPH_LAUNCHER_PID"
    return 0
  fi
  if [[ "${PPID:-}" =~ ^[0-9]+$ && "$PPID" -gt 1 ]] && kill -0 "$PPID" 2>/dev/null; then
    printf '%s\n' "$PPID"
    return 0
  fi
  printf '%s\n' "$$"
}

ralph_bg_register_process_scope() {
  local job_id="${1:-}" job_pid="${2:-}" job_sid="${3:-}"
  local run_dir supervisor_py scope_owner_pid

  [[ -n "${RALPH_PROCESS_RUN_DIR:-}" && -n "$job_id" && "$job_pid" =~ ^[0-9]+$ && "$job_sid" =~ ^[0-9]+$ ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  supervisor_py="$RALPH_BG_SCRIPT_DIR/python/ralph_process_supervisor.py"
  [[ -f "$supervisor_py" ]] || return 0
  run_dir="$RALPH_PROCESS_RUN_DIR"
  scope_owner_pid="$(ralph_bg_resolve_owner_pid)"

  PYTHONPATH="$(dirname "$supervisor_py")" python3 - "$run_dir" "$job_id" "$job_pid" "$job_sid" "$scope_owner_pid" <<'PYTHON'
import os
import secrets
import sys
from pathlib import Path

from ralph_process_supervisor import append_event, atomic_json, pid_identity, utc_now

run_dir = Path(sys.argv[1])
job_id = sys.argv[2]
job_pid = int(sys.argv[3])
job_sid = int(sys.argv[4])
scope_owner_pid = int(sys.argv[5])
max_live = int(os.environ.get("RALPH_PROCESS_MAX_SCOPE_LIVE", "128"))
scope_id = f"bg-job-{job_id}"
scope_path = run_dir / "scopes" / f"{scope_id}.json"
scope = {
    "version": 1,
    "scope_id": scope_id,
    "kind": "bg-job",
    "runtime": os.environ.get("RUNTIME") or os.environ.get("RALPH_PLAN_RUNTIME") or "shell",
    "root_pid": job_pid,
    "root_identity": pid_identity(job_pid),
    "session_id": job_sid,
    "wrapper_pid": scope_owner_pid,
    "scope_owner_pid": scope_owner_pid,
    "token": secrets.token_hex(24),
    "status": "running",
    "started_at": utc_now(),
    "max_live": max_live,
    "bg_job_id": job_id,
}
atomic_json(scope_path, scope)
append_event(run_dir, "scope-register", scope_id=scope_id, kind="bg-job", root_pid=job_pid, bg_job_id=job_id)
PYTHON
}

ralph_bg_launch() {
  local command="${1:-}"
  local job_id command_hash duplicate_id foreign_reason
  local workspace timeout_sec tier job_dir stdout_path stderr_path
  local pid pgid sid isolated launch_mode record

  ralph_bg_require_plan_context || return 1
  ralph_bg_validate_command_args 1 "$command" || return 1

  if [[ "$RALPH_BG_JOBS" == "0" ]]; then
    jq -nc \
      --arg status "disabled" \
      --arg message "Background jobs are disabled (RALPH_BG_JOBS=0)." \
      '{status:$status,message:$message,tier1Available:false}'
    return 0
  fi

  foreign_reason="$(ralph_bg_command_selects_foreign_target "$command" || true)"
  if [[ -n "$foreign_reason" ]]; then
    printf '%s\n' "Error: ralph-bg.sh rejected command ($foreign_reason)" >&2
    return 1
  fi

  command_hash="$(ralph_bg_job_command_hash "$command")"
  if duplicate_id="$(ralph_bg_job_find_outstanding_by_command_hash "$command_hash" 2>/dev/null)"; then
    printf '%s\n' "Error: duplicate outstanding background job for this command: $duplicate_id" >&2
    return 1
  fi

  workspace="${RALPH_AGENT_WORKSPACE}"
  timeout_sec="$RALPH_BG_JOB_TIMEOUT"
  [[ "$timeout_sec" =~ ^[0-9]+$ ]] || timeout_sec=3600
  tier=1
  job_id="$(ralph_bg_job_id_new)"
  job_dir="$(ralph_bg_job_dir "$job_id")" || return 1
  stdout_path="$job_dir/stdout"
  stderr_path="$job_dir/stderr"
  mkdir -p "$job_dir"
  chmod 700 "$job_dir" 2>/dev/null || true

  ralph_bg_job_create "$job_id" "$command" "ralph-bg.sh" "$timeout_sec" "$tier" "$(ralph_bg_resolve_owner_pid)" >/dev/null

  ralph_native_shell_launch_process_group "$workspace" "$command" "bash" "$stdout_path" "$stderr_path"
  pid="${RALPH_NATIVE_SHELL_LAUNCH_PID:-0}"
  pgid="${RALPH_NATIVE_SHELL_LAUNCH_PGID:-0}"
  sid="${RALPH_NATIVE_SHELL_LAUNCH_SID:-0}"
  isolated="${RALPH_NATIVE_SHELL_LAUNCH_ISOLATED:-false}"
  launch_mode="${RALPH_NATIVE_SHELL_LAUNCH_MODE:-plain}"

  if [[ "$isolated" != "true" && "$isolated" != "1" ]]; then
    if [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 0 ]]; then
      ralph_native_shell_terminate_spawned_job "$pid" "$pgid" "$isolated" 1 >/dev/null || true
    fi
    ralph_bg_job_mark_requested_reason "$job_id" "tier-1-unavailable: non-isolated launch" "$launch_mode" >/dev/null
    jq -nc \
      --arg jobId "$job_id" \
      --arg reason "tier-1-unavailable: non-isolated launch" \
      --arg launchMode "$launch_mode" \
      --arg message "Tier 1 is unavailable on this host; fall back to tier 2. End this turn without a completion marker." \
      '{
        status: "tier1-unavailable",
        jobId: $jobId,
        tier1Available: false,
        reason: $reason,
        launchMode: $launchMode,
        message: $message
      }'
    return 2
  fi

  ralph_bg_job_mark_launched "$job_id" "$pid" "$launch_mode" "true" >/dev/null
  ralph_bg_job_mark_running "$job_id" >/dev/null
  ralph_bg_register_process_scope "$job_id" "$pid" "$sid" || true

  record="$(ralph_bg_job_read "$job_id")"
  jq -nc \
    --argjson record "$record" \
    --arg message "Background job launched. End this turn without a completion marker (do not emit TODO_COMPLETION)." \
    '{
      status: "launched",
      jobId: $record.job_id,
      state: $record.state,
      tier: $record.tier,
      launchMode: $record.launch_mode,
      isolated: $record.isolated,
      tier1Available: true,
      stdoutPath: ($record.job_id | "bg-jobs/" + . + "/stdout"),
      stderrPath: ($record.job_id | "bg-jobs/" + . + "/stderr"),
      message: $message
    }'
}

ralph_bg_main() {
  case "${1:-}" in
    -h|--help)
      ralph_bg_usage
      return 0
      ;;
  esac
  if [[ $# -ne 1 ]]; then
    ralph_bg_validate_command_args "$#" "${1:-}" || return 1
    return 1
  fi
  ralph_bg_launch "$1"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  ralph_bg_main "$@"
fi
