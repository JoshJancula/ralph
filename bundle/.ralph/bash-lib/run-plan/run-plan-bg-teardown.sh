#!/usr/bin/env bash
# Background job teardown and restart recovery for plan runs.
# Integrates with ralph-process-teardown.sh and run-plan startup.

if [[ -n "${RALPH_BG_TEARDOWN_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
RALPH_BG_TEARDOWN_LOADED=1

_RALPH_BG_TEARDOWN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=run-plan-bg-job-state.sh
source "$_RALPH_BG_TEARDOWN_DIR/run-plan-bg-job-state.sh"

ralph_bg_teardown_source_native_shell() {
  if declare -F ralph_native_shell_pid_running >/dev/null 2>&1; then
    return 0
  fi
  # shellcheck source=../native-hook/native-shell-wrapper.sh
  source "$_RALPH_BG_TEARDOWN_DIR/../native-hook/native-shell-wrapper.sh"
}

ralph_bg_job_owner_process_alive() {
  local record="${1:-}"
  local owner_pid owner_start
  owner_pid="$(jq -r '.owner_pid // 0' <<<"$record")"
  owner_start="$(jq -r '.owner_process_start_id // empty' <<<"$record")"
  [[ "$owner_pid" =~ ^[0-9]+$ && "$owner_pid" -gt 0 ]] || return 1
  ralph_bg_teardown_source_native_shell
  ralph_native_shell_pid_running "$owner_pid" "$owner_start"
}

ralph_bg_job_process_alive() {
  local record="${1:-}"
  local job_pid job_start
  job_pid="$(jq -r '.job_pid // 0' <<<"$record")"
  job_start="$(jq -r '.job_process_start_id // empty' <<<"$record")"
  [[ "$job_pid" =~ ^[0-9]+$ && "$job_pid" -gt 0 ]] || return 1
  ralph_bg_teardown_source_native_shell
  ralph_native_shell_pid_running "$job_pid" "$job_start"
}

ralph_bg_job_safe_terminate() {
  local record="${1:-}"
  local job_pid pgid isolated job_start
  job_pid="$(jq -r '.job_pid // 0' <<<"$record")"
  pgid="$(jq -r '.job_pid // 0' <<<"$record")"
  isolated="$(jq -r '.isolated // false' <<<"$record")"
  job_start="$(jq -r '.job_process_start_id // empty' <<<"$record")"
  [[ "$job_pid" =~ ^[0-9]+$ && "$job_pid" -gt 0 ]] || return 1
  ralph_bg_teardown_source_native_shell
  ralph_native_shell_pid_running "$job_pid" "$job_start" || return 1
  ralph_native_shell_terminate_spawned_job "$job_pid" "$pgid" "$isolated" 1 >/dev/null || true
  return 0
}

ralph_bg_job_teardown_terminal_status() {
  local reason="${1:-cancelled}"
  case "$reason" in
    interrupted|signal|killswitch|owner-dead)
      printf '%s\n' "$RALPH_BG_JOB_TERMINAL_INTERRUPTED"
      ;;
    timed_out|timeout)
      printf '%s\n' "$RALPH_BG_JOB_TERMINAL_TIMED_OUT"
      ;;
    unknown)
      printf '%s\n' "$RALPH_BG_JOB_TERMINAL_UNKNOWN"
      ;;
    *)
      printf '%s\n' "$RALPH_BG_JOB_TERMINAL_CANCELLED"
      ;;
  esac
}

ralph_bg_job_teardown_one_record() {
  local record="${1:-}" reason="${2:-cancelled}"
  local job_id state terminal_status
  job_id="$(jq -r '.job_id // empty' <<<"$record")"
  state="$(jq -r '.state // empty' <<<"$record")"
  [[ -n "$job_id" ]] || return 0
  ralph_bg_job_is_outstanding_state "$state" || return 0

  if [[ "$state" == "$RALPH_BG_JOB_STATE_LAUNCHED" || "$state" == "$RALPH_BG_JOB_STATE_RUNNING" ]]; then
    ralph_bg_job_safe_terminate "$record" || true
  fi

  terminal_status="$(ralph_bg_job_teardown_terminal_status "$reason")"
  if ! ralph_bg_job_process_alive "$record" 2>/dev/null; then
    :
  elif [[ "$terminal_status" != "$RALPH_BG_JOB_TERMINAL_UNKNOWN" ]]; then
    terminal_status="$RALPH_BG_JOB_TERMINAL_UNKNOWN"
  fi

  ralph_bg_job_mark_terminal_from_outstanding "$job_id" "$terminal_status" "$reason" >/dev/null 2>&1 || true
}

ralph_bg_job_recovery_report_path() {
  ralph_bg_job_require_session_dir || return 1
  printf '%s/bg-jobs/recovery-report.json\n' "$RALPH_SESSION_DIR"
}

ralph_bg_job_recovery_append_report() {
  local entry_json="${1:-}"
  local report_path existing
  [[ -n "$entry_json" ]] || return 0
  report_path="$(ralph_bg_job_recovery_report_path)" || return 0
  if [[ -f "$report_path" ]]; then
    existing="$(jq -c '.' "$report_path" 2>/dev/null || printf '[]')"
  else
    existing='[]'
  fi
  jq -c --argjson entry "$entry_json" '. + [$entry]' <<<"$existing" >"${report_path}.tmp" 2>/dev/null \
    && mv "${report_path}.tmp" "$report_path" 2>/dev/null || true
  chmod 0600 "$report_path" 2>/dev/null || true
}

# Terminate verified descendants and persist terminal state for outstanding jobs.
# Args: $1 = termination reason (cancelled|interrupted|timed_out|unknown)
ralph_run_plan_background_jobs_teardown() {
  local reason="${1:-cancelled}" mismatch foreign_reason record state

  ralph_bg_job_require_session_dir 2>/dev/null || return 0
  command -v jq >/dev/null 2>&1 || return 0

  case "${EXIT_STATUS:-}" in
    interrupted)
      reason="interrupted"
      ;;
  esac
  case "${RALPH_BG_JOB_TEARDOWN_REASON:-}" in
    cancelled|interrupted|timed_out|unknown|timeout|killswitch|signal|owner-dead)
      reason="${RALPH_BG_JOB_TEARDOWN_REASON}"
      ;;
  esac

  while IFS= read -r record; do
    [[ -n "$record" ]] || continue
    state="$(jq -r '.state // empty' <<<"$record")"
    ralph_bg_job_is_outstanding_state "$state" || continue
    foreign_reason="$(ralph_bg_job_identity_mismatch_reason "$record")"
    if [[ -n "$foreign_reason" ]]; then
      continue
    fi
    ralph_bg_job_teardown_one_record "$record" "$reason"
  done < <(ralph_bg_job_list_records 2>/dev/null || true)
}

# On runner restart, adopt requested jobs and finalize running jobs whose owner died.
ralph_bg_job_recover_on_restart() {
  local record state job_id owner_alive job_alive terminal_status report_entry now_iso

  [[ "${RALPH_BG_JOBS:-0}" == "1" ]] || return 0
  ralph_bg_job_require_session_dir 2>/dev/null || return 0
  command -v jq >/dev/null 2>&1 || return 0
  ralph_bg_teardown_source_native_shell

  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u)"

  while IFS= read -r record; do
    [[ -n "$record" ]] || continue
    if [[ -n "$(ralph_bg_job_identity_mismatch_reason "$record")" ]]; then
      continue
    fi
    state="$(jq -r '.state // empty' <<<"$record")"
    job_id="$(jq -r '.job_id // empty' <<<"$record")"
    [[ -n "$job_id" ]] || continue

    case "$state" in
      "$RALPH_BG_JOB_STATE_REQUESTED")
        report_entry="$(jq -nc \
          --arg jobId "$job_id" \
          --arg action "adopt-requested" \
          --arg at "$now_iso" \
          '{jobId:$jobId,action:$action,at:$at}')"
        ralph_bg_job_recovery_append_report "$report_entry"
        ;;
      "$RALPH_BG_JOB_STATE_LAUNCHED" | "$RALPH_BG_JOB_STATE_RUNNING")
        if ralph_bg_job_owner_process_alive "$record"; then
          continue
        fi
        if ralph_bg_job_process_alive "$record"; then
          ralph_bg_job_safe_terminate "$record" || true
          terminal_status="$RALPH_BG_JOB_TERMINAL_INTERRUPTED"
        else
          terminal_status="$RALPH_BG_JOB_TERMINAL_UNKNOWN"
        fi
        ralph_bg_job_mark_terminal_from_outstanding "$job_id" "$terminal_status" "restart-owner-dead" >/dev/null 2>&1 || true
        report_entry="$(jq -nc \
          --arg jobId "$job_id" \
          --arg action "finalize-dead-owner" \
          --arg terminalStatus "$terminal_status" \
          --arg at "$now_iso" \
          '{jobId:$jobId,action:$action,terminalStatus:$terminalStatus,at:$at,replay:false}')"
        ralph_bg_job_recovery_append_report "$report_entry"
        ;;
    esac
  done < <(ralph_bg_job_list_records 2>/dev/null || true)
}
