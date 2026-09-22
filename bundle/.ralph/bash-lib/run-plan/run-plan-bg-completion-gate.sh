#!/usr/bin/env bash
# Runner-side completion gate for durable background jobs (MCP-free).
#
# Refuses plan or stage success while a matching background job is outstanding
# or terminal-but-unconsumed for the current logical attempt. Foreign-identity
# records are ignored (not blockers).

if [[ -n "${RALPH_BG_COMPLETION_GATE_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
RALPH_BG_COMPLETION_GATE_LOADED=1

_ralph_bg_completion_gate_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=run-plan-bg-job-state.sh
source "$_ralph_bg_completion_gate_dir/run-plan-bg-job-state.sh"
unset _ralph_bg_completion_gate_dir

ralph_bg_job_command_summary() {
  local command="${1:-}"
  local max_len="${2:-120}"
  [[ "$max_len" =~ ^[0-9]+$ ]] || max_len=120
  command="${command//$'\n'/; }"
  command="${command//  / }"
  if ((${#command} > max_len)); then
    command="${command:0:max_len}..."
  fi
  printf '%s' "$command"
}

# Prints the first blocking job record (JSON) for the current attempt, or returns 1.
# Outstanding jobs take precedence over terminal-but-unconsumed jobs.
ralph_bg_job_find_completion_blocker() {
  local attempt_key record state reason identity_key
  local outstanding_record="" terminal_record=""

  ralph_bg_job_require_session_dir || return 1
  attempt_key="$(ralph_bg_job_attempt_key "$(ralph_bg_job_identity_json)")"

  while IFS= read -r record; do
    [[ -n "$record" ]] || continue

    identity_key="$(ralph_bg_job_attempt_key "$(jq -c '.identity' <<<"$record")")"
    [[ "$identity_key" == "$attempt_key" ]] || continue

    reason="$(ralph_bg_job_record_malformed_reason "$record")"
    [[ -z "$reason" ]] || continue

    reason="$(ralph_bg_job_identity_mismatch_reason "$record")"
    [[ -z "$reason" ]] || continue

    state="$(jq -r '.state // empty' <<<"$record")"
    case "$state" in
      "$RALPH_BG_JOB_STATE_REQUESTED" | "$RALPH_BG_JOB_STATE_LAUNCHED" | "$RALPH_BG_JOB_STATE_RUNNING")
        outstanding_record="$record"
        break
        ;;
      "$RALPH_BG_JOB_STATE_TERMINAL")
        [[ -z "$terminal_record" ]] && terminal_record="$record"
        ;;
    esac
  done < <(ralph_bg_job_list_records 2>/dev/null || true)

  if [[ -n "$outstanding_record" ]]; then
    jq -c '.' <<<"$outstanding_record"
    return 0
  fi
  if [[ -n "$terminal_record" ]]; then
    jq -c '.' <<<"$terminal_record"
    return 0
  fi
  return 1
}

# ralph_run_plan_gate_bg_job_before_completion <plan-path> <plan-format> <todo-target> <line-num> [todo-ordinal] [todo-id] [todo-hash]
# Returns 0 when completion may proceed; 1 when a matching background job blocks it.
ralph_run_plan_gate_bg_job_before_completion() {
  local plan_path="${1:-}" plan_format="${2:-}" todo_target="${3:-}" line_num="${4:-}"
  local todo_ordinal="${5:-}" todo_id="${6:-}" todo_hash="${7:-}"
  local blocker job_id command state summary conflict

  [[ "${RALPH_BG_JOBS:-0}" != "0" ]] || return 0
  [[ -n "${RALPH_SESSION_DIR:-}" ]] || return 0
  declare -F ralph_bg_job_find_completion_blocker >/dev/null 2>&1 || return 0

  if [[ -n "$line_num" ]]; then
    export RALPH_CURRENT_TODO_LINE="$line_num"
  fi
  if [[ -n "$todo_ordinal" ]]; then
    export RALPH_CURRENT_TODO_ORDINAL="$todo_ordinal"
  fi
  if [[ -n "$todo_id" ]]; then
    export RALPH_CURRENT_TODO_ID="$todo_id"
  elif [[ -n "$line_num" && -z "${RALPH_CURRENT_TODO_ID:-}" ]]; then
    export RALPH_CURRENT_TODO_ID=""
  fi
  if [[ -n "$todo_hash" ]]; then
    export RALPH_CURRENT_TODO_HASH="$todo_hash"
  fi

  blocker="$(ralph_bg_job_find_completion_blocker 2>/dev/null || true)"
  [[ -n "$blocker" ]] || return 0

  job_id="$(jq -r '.job_id // empty' <<<"$blocker")"
  command="$(jq -r '.command // empty' <<<"$blocker")"
  state="$(jq -r '.state // empty' <<<"$blocker")"
  summary="$(ralph_bg_job_command_summary "$command")"
  conflict="background job blocks completion: job_id=${job_id} state=${state} command=${summary}"

  if [[ -n "$plan_path" && -n "$todo_target" ]] && declare -F plan_reopen_todo_by_format >/dev/null 2>&1; then
    plan_reopen_todo_by_format "$plan_path" "$plan_format" "$todo_target" 2>/dev/null || true
  fi

  export RALPH_BG_JOB_COMPLETION_CONFLICT="$conflict"
  ralph_run_plan_log "${conflict} (line=${line_num:-unknown})"
  return 1
}
