#!/usr/bin/env bash
# Tier-2 runner wait phase: after the yielding invocation exits and its process
# group is torn down, wait for the background job in the runner (never in MCP),
# persist a bounded continuation payload, and hand off to the next invocation.
#
# Reuses stop-continuation-hook wait/finalize/store helpers and bg job state.
# MCP-free; do not source the MCP server here.

if [[ -n "${RALPH_BG_INVOCATION_WAIT_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
RALPH_BG_INVOCATION_WAIT_LOADED=1

_ralph_bg_invocation_wait_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=run-plan-bg-job-state.sh
source "$_ralph_bg_invocation_wait_dir/run-plan-bg-job-state.sh"
# shellcheck source=../native-hook/stop-continuation-hook.sh
source "$_ralph_bg_invocation_wait_dir/../native-hook/stop-continuation-hook.sh"
unset _ralph_bg_invocation_wait_dir

RALPH_BG_INVOCATION_WAIT_RC_NONE=0
RALPH_BG_INVOCATION_WAIT_RC_CONTINUE=10

ralph_bg_invocation_wait_debug() {
  local event="${1:-}" detail="${2:-}"
  [[ -n "${RALPH_CONTINUATION_DEBUG:-}" ]] || return 0
  printf '[ralph-bg-invocation-wait] %s %s\n' "$event" "$detail" >&2
}

ralph_bg_invocation_tier_active() {
  [[ "${RALPH_BG_JOBS:-0}" != "0" ]] || return 1
  [[ "${RALPH_BG_TIER_SELECTED:-}" == "invocation" ]]
}

ralph_bg_continuation_root() {
  ralph_bg_job_require_session_dir || return 1
  printf '%s/continuations\n' "$RALPH_SESSION_DIR"
}

ralph_bg_continuation_record_path() {
  local request_id="${1:-}"
  local root
  [[ -n "$request_id" && "$request_id" != *"/"* && "$request_id" != *".."* ]] || return 1
  root="$(ralph_bg_continuation_root)" || return 1
  printf '%s/%s.json\n' "$root" "$request_id"
}

ralph_bg_continuation_consumed_marker_path() {
  local request_id="${1:-}" record_path
  record_path="$(ralph_bg_continuation_record_path "$request_id")" || return 1
  printf '%s.consumed\n' "$record_path"
}

ralph_bg_invocation_format_prompt_block() {
  local continuation_json="${1:-}"
  local job_id status exit_code preview command_summary result_id result_path elapsed

  [[ -n "$continuation_json" ]] || return 0
  job_id="$(jq -r '.jobId // empty' <<<"$continuation_json")"
  status="$(jq -r '.status // empty' <<<"$continuation_json")"
  exit_code="$(jq -r '.exitCode // empty' <<<"$continuation_json")"
  preview="$(jq -r '.preview // empty' <<<"$continuation_json")"
  command_summary="$(jq -r '.commandSummary // empty' <<<"$continuation_json")"
  result_id="$(jq -r '.resultId // empty' <<<"$continuation_json")"
  result_path="$(jq -r '.resultPath // empty' <<<"$continuation_json")"
  elapsed="$(jq -r '.elapsedSeconds // empty' <<<"$continuation_json")"

  printf '%s\n' "## Background job result (runner-owned, tier 2)"
  printf '%s\n' ""
  printf '%s\n' "Your prior invocation ended while a background job was still running. The runner waited for it outside the model session and consumed the result exactly once."
  printf '%s\n' ""
  printf '%s\n' "- Job id: ${job_id:-unknown}"
  [[ -n "$command_summary" ]] && printf '%s\n' "- Command: ${command_summary}"
  [[ -n "$status" ]] && printf '%s\n' "- Status: ${status}"
  [[ -n "$exit_code" && "$exit_code" != "null" ]] && printf '%s\n' "- Exit code: ${exit_code}"
  [[ -n "$elapsed" && "$elapsed" != "null" ]] && printf '%s\n' "- Elapsed seconds: ${elapsed}"
  if [[ -n "$preview" ]]; then
    printf '%s\n' "- Preview:"
    printf '%s\n' '```'
    printf '%s\n' "$preview"
    printf '%s\n' '```'
  fi
  if [[ -n "$result_id" ]]; then
    if [[ -n "$result_path" ]]; then
      printf '%s\n' "- Full output stored at \`${result_path}\` (result id \`${result_id}\`). Use \`ralph_proxy_result_read\` with offset/limit if you need more than the preview."
    else
      printf '%s\n' "- Full output stored under result id \`${result_id}\`. Use \`ralph_proxy_result_read\` with offset/limit if you need more than the preview."
    fi
  fi
  printf '%s\n' ""
  printf '%s\n' "Continue this TODO from the result above. Do not redo the TODO from scratch. Do not poll the job or re-run the same command unless the TODO explicitly requires it."
}

ralph_bg_invocation_persist_continuation() {
  local job_id="${1:-}" continuation_json="${2:-}" attempt_key="${3:-}"
  local path now_iso record marker

  [[ -n "$job_id" && -n "$continuation_json" ]] || return 1
  path="$(ralph_bg_continuation_record_path "$job_id")" || return 1
  marker="$(ralph_bg_continuation_consumed_marker_path "$job_id")" || return 1
  [[ ! -f "$marker" ]] || return 1

  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u)"
  record="$(jq -nc \
    --argjson schema_version 1 \
    --arg kind "bg-job-continuation" \
    --arg request_id "$job_id" \
    --arg tier "invocation" \
    --arg reason "bg-job-result" \
    --arg attempt_key "$attempt_key" \
    --argjson continuation "$continuation_json" \
    --argjson identity "$(ralph_bg_job_identity_json)" \
    --arg created_at "$now_iso" \
    '{
      schema_version: $schema_version,
      kind: $kind,
      request_id: $request_id,
      tier: $tier,
      reason: $reason,
      attempt_key: $attempt_key,
      continuation: $continuation,
      identity: $identity,
      consumed: false,
      created_at: $created_at,
      consumed_at: null
    }')"

  mkdir -p "$(dirname "$path")"
  umask 077
  printf '%s\n' "$record" >"${path}.tmp" && mv -f "${path}.tmp" "$path"
  chmod 600 "$path" 2>/dev/null || true
  jq -c '.' <<<"$record"
}

ralph_bg_invocation_mark_continuation_consumed() {
  local continuation_json="${1:-}" job_id path marker now_iso
  job_id="$(jq -r '.jobId // empty' <<<"$continuation_json")"
  [[ -n "$job_id" ]] || return 1
  path="$(ralph_bg_continuation_record_path "$job_id")" || return 1
  marker="$(ralph_bg_continuation_consumed_marker_path "$job_id")" || return 1
  [[ -f "$path" ]] || return 1
  [[ ! -f "$marker" ]] || return 1
  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u)"
  jq -c --arg consumed_at "$now_iso" '.consumed = true | .consumed_at = $consumed_at' "$path" >"${path}.tmp" \
    && mv -f "${path}.tmp" "$path"
  printf '%s\n' "$now_iso" >"${marker}.tmp" && mv -f "${marker}.tmp" "$marker"
}

ralph_bg_invocation_apply_degraded_continuity() {
  local capture="" record=""

  declare -F ralph_session_todo_select_manifest >/dev/null 2>&1 || return 0
  record="$(ralph_session_todo_select_manifest 2>/dev/null || true)"
  [[ -n "$record" ]] || return 0
  capture="$(jq -r '.capture // empty' <<<"$record")"
  [[ "$capture" == "${RALPH_TODO_SESSION_CAPTURE_DEGRADED:-degraded}" ]] || return 0

  unset RALPH_RUN_PLAN_RESUME_SESSION_ID RALPH_RUN_PLAN_NEW_SESSION_ID RALPH_RUN_PLAN_RESUME_BARE
  export RALPH_USAGE_DEGRADED_FALLBACK="session-capture-degraded"
  if declare -F ralph_run_plan_log >/dev/null 2>&1; then
    ralph_run_plan_log "tier2 degraded continuity: starting fresh invocation with bounded job result (no session attach)"
  fi
  ralph_bg_invocation_wait_debug "degraded-continuity" "capture=${capture}"
}

# ralph_bg_invocation_wait_after_turn
# Returns RALPH_BG_INVOCATION_WAIT_RC_CONTINUE when a continuation invocation
# should start for the same TODO without consuming the gutter retry budget.
ralph_bg_invocation_wait_after_turn() {
  local attempt_key job_id record state wait_outcome continuation_json
  local guard_count max_per_todo consumed_state

  ralph_bg_invocation_tier_active || return "$RALPH_BG_INVOCATION_WAIT_RC_NONE"
  ralph_bg_stop_hook_require_context || return "$RALPH_BG_INVOCATION_WAIT_RC_NONE"

  attempt_key="$(ralph_bg_job_attempt_key "$(ralph_bg_job_identity_json)")"
  max_per_todo="${RALPH_BG_MAX_PER_TODO:-8}"
  [[ "$max_per_todo" =~ ^[0-9]+$ ]] || max_per_todo=8
  guard_count="$(ralph_bg_stop_hook_guard_read "$attempt_key")"
  [[ "$guard_count" =~ ^[0-9]+$ ]] || guard_count=0
  if (( guard_count >= max_per_todo )); then
    ralph_bg_invocation_wait_debug "cap" "count=${guard_count} max=${max_per_todo}"
    return "$RALPH_BG_INVOCATION_WAIT_RC_NONE"
  fi

  if ! job_id="$(ralph_bg_stop_hook_find_job_for_attempt "$attempt_key")"; then
    return "$RALPH_BG_INVOCATION_WAIT_RC_NONE"
  fi

  record="$(ralph_bg_job_read "$job_id" 1 2>/dev/null || ralph_bg_job_read "$job_id" 2>/dev/null || true)"
  [[ -n "$record" ]] || return "$RALPH_BG_INVOCATION_WAIT_RC_NONE"
  state="$(jq -r '.state // empty' <<<"$record")"
  if [[ "$state" == "$RALPH_BG_JOB_STATE_CONSUMED" ]]; then
    return "$RALPH_BG_INVOCATION_WAIT_RC_NONE"
  fi

  wait_outcome="ready"
  case "$state" in
    "$RALPH_BG_JOB_STATE_REQUESTED" | "$RALPH_BG_JOB_STATE_LAUNCHED" | "$RALPH_BG_JOB_STATE_RUNNING")
      ralph_bg_invocation_wait_debug "wait" "job_id=${job_id}"
      wait_outcome="$(ralph_bg_stop_hook_wait_for_process "$job_id" "$record")"
      record="$(ralph_bg_job_read "$job_id" 1 2>/dev/null || ralph_bg_job_read "$job_id" 2>/dev/null || true)"
      state="$(jq -r '.state // empty' <<<"$record")"
      if [[ "$state" == "$RALPH_BG_JOB_STATE_CONSUMED" ]]; then
        return "$RALPH_BG_INVOCATION_WAIT_RC_NONE"
      fi
      ;;
    "$RALPH_BG_JOB_STATE_TERMINAL")
      wait_outcome="ready"
      ;;
    *)
      return "$RALPH_BG_INVOCATION_WAIT_RC_NONE"
      ;;
  esac

  continuation_json="$(ralph_bg_stop_hook_finalize_job "$job_id" "$wait_outcome")" || return "$RALPH_BG_INVOCATION_WAIT_RC_NONE"

  consumed_state="$(jq -r '.state // empty' <<<"$(ralph_bg_job_read "$job_id" 1 2>/dev/null || true)")"
  if [[ "$consumed_state" == "$RALPH_BG_JOB_STATE_TERMINAL" ]]; then
    ralph_bg_job_consume "$job_id" >/dev/null || return "$RALPH_BG_INVOCATION_WAIT_RC_NONE"
  elif [[ "$consumed_state" != "$RALPH_BG_JOB_STATE_CONSUMED" ]]; then
    return "$RALPH_BG_INVOCATION_WAIT_RC_NONE"
  fi

  ralph_bg_invocation_persist_continuation "$job_id" "$continuation_json" "$attempt_key" >/dev/null \
    || return "$RALPH_BG_INVOCATION_WAIT_RC_NONE"

  ralph_bg_stop_hook_guard_increment "$attempt_key" >/dev/null

  export RALPH_RUN_PLAN_BG_JOB_CONTINUATION="$continuation_json"
  export RALPH_PLAN_INVOCATION_REASON="${RALPH_TODO_INVOCATION_REASON_CONTINUE:-todo-continue}"
  export RALPH_USAGE_CONTINUATION_REASON="bg-job"
  if declare -F ralph_run_plan_capture_bg_continuation_usage_telemetry >/dev/null 2>&1; then
    ralph_run_plan_capture_bg_continuation_usage_telemetry "$continuation_json"
  fi
  ralph_bg_invocation_apply_degraded_continuity

  if declare -F ralph_run_plan_log >/dev/null 2>&1; then
    ralph_run_plan_log "tier2 invocation-boundary: job ${job_id} waited and consumed; scheduling continuation invocation"
  fi
  ralph_bg_invocation_wait_debug "continue" "job_id=${job_id}"
  return "$RALPH_BG_INVOCATION_WAIT_RC_CONTINUE"
}

ralph_bg_invocation_try_schedule_continuation() {
  local rc=0
  ralph_bg_invocation_wait_after_turn || rc=$?
  [[ "$rc" == "$RALPH_BG_INVOCATION_WAIT_RC_CONTINUE" ]]
}
