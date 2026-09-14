#!/usr/bin/env bash
# Workflow operator-input continuation identity (tier-2 session resume).
#
# Persists consume-once continuation records under
# $RALPH_SESSION_DIR/continuations/ and embeds continuationIdentity on common
# action request/decision/consumed records for the same stage attempt.

if [[ -n "${RALPH_WORKFLOW_ACTION_CONTINUATION_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
RALPH_WORKFLOW_ACTION_CONTINUATION_LOADED=1

_wfac_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
unset _wfac_dir

workflow_action_continuation_require_session_dir() {
  [[ -n "${RALPH_SESSION_DIR:-}" ]] || {
    printf '%s\n' "Error: RALPH_SESSION_DIR is required for workflow action continuation" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || {
    printf '%s\n' "Error: jq is required for workflow action continuation" >&2
    return 1
  }
}

workflow_action_continuation_root() {
  workflow_action_continuation_require_session_dir || return 1
  printf '%s/continuations\n' "$RALPH_SESSION_DIR"
}

workflow_action_continuation_record_path() {
  local request_id="${1:-}"
  local root
  [[ -n "$request_id" && "$request_id" != *"/"* && "$request_id" != *".."* ]] || return 1
  root="$(workflow_action_continuation_root)" || return 1
  printf '%s/%s.json\n' "$root" "$request_id"
}

workflow_action_continuation_consumed_marker_path() {
  local request_id="${1:-}" record_path
  record_path="$(workflow_action_continuation_record_path "$request_id")" || return 1
  printf '%s.consumed\n' "$record_path"
}

workflow_action_continuation_request_id_for_attempt() {
  local attempt_key="${1:-}"
  local hash=""
  [[ -n "$attempt_key" ]] || return 1
  if command -v shasum >/dev/null 2>&1; then
    hash="$(printf '%s' "$attempt_key" | shasum -a 256 | awk '{print $1}' | head -c 16)"
  elif command -v sha256sum >/dev/null 2>&1; then
    hash="$(printf '%s' "$attempt_key" | sha256sum | awk '{print $1}' | head -c 16)"
  else
    hash="$(printf '%s' "$attempt_key" | tr -c '[:alnum:]' '-' | head -c 16)"
  fi
  printf 'workflow-operator-input-%s\n' "$hash"
}

workflow_action_continuation_capture_session() {
  local manifest_key record session_id capture
  session_id=""
  capture="${RALPH_TODO_SESSION_CAPTURE_DEGRADED:-degraded}"
  if declare -F ralph_session_todo_manifest_key >/dev/null 2>&1 \
    && manifest_key="$(ralph_session_todo_manifest_key 2>/dev/null)"; then
    if record="$(ralph_session_todo_read_raw "$manifest_key" 2>/dev/null)"; then
      session_id="$(jq -r '.session_id // empty' <<<"$record")"
      capture="$(jq -r '.capture // empty' <<<"$record")"
      [[ -n "$capture" ]] || capture="${RALPH_TODO_SESSION_CAPTURE_DEGRADED:-degraded}"
    fi
  fi
  jq -nc \
    --arg session_id "$session_id" \
    --arg capture "$capture" \
    '{
      session_id: (if $session_id == "" then null else $session_id end),
      capture: $capture
    }'
}

# Build continuationIdentity for embedding in action records.
# Optional: --control-plan <path> --todo-id <id> --runtime <name>
workflow_action_continuation_build() {
  local control_plan="" todo_id="" runtime_override=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --control-plan) control_plan="${2:-}"; shift 2 ;;
      --todo-id) todo_id="${2:-}"; shift 2 ;;
      --runtime) runtime_override="${2:-}"; shift 2 ;;
      --) shift; break ;;
      *) shift ;;
    esac
  done

  declare -F ralph_session_todo_identity_json >/dev/null 2>&1 || return 1
  declare -F ralph_session_todo_attempt_key >/dev/null 2>&1 || return 1

  local identity attempt_key session runtime
  identity="$(ralph_session_todo_identity_json)"
  attempt_key="$(ralph_session_todo_attempt_key "$identity")"
  session="$(workflow_action_continuation_capture_session)"
  runtime="$(jq -r '.runtime // empty' <<<"$identity")"
  [[ -n "$runtime_override" ]] && runtime="$runtime_override"
  [[ -n "${RUNTIME:-${RALPH_PLAN_RUNTIME:-}}" && -z "$runtime" ]] && runtime="${RUNTIME:-${RALPH_PLAN_RUNTIME:-}}"
  [[ -n "$todo_id" ]] || todo_id="${RALPH_CURRENT_TODO_ID:-}"
  [[ -n "$control_plan" ]] || control_plan="${RALPH_WORKFLOW_CONTROL_PLAN_PATH:-}"

  jq -nc \
    --argjson identity "$identity" \
    --arg attempt_key "$attempt_key" \
    --arg control_plan "$control_plan" \
    --arg todo_id "$todo_id" \
    --arg runtime "$runtime" \
    --argjson session "$session" \
    '{
      identity: $identity,
      attemptKey: $attempt_key,
      controlPlanPath: (if $control_plan == "" then null else $control_plan end),
      todoId: (if $todo_id == "" then null else $todo_id end),
      runtime: (if $runtime == "" then null else $runtime end),
      session: $session
    }'
}

workflow_action_continuation_from_record() {
  local record="${1:-}"
  [[ -n "$record" ]] || record='{}'
  jq -c 'if (.continuationIdentity | type) == "object" then .continuationIdentity else empty end' <<<"$record"
}

workflow_action_continuation_matches_current() {
  local continuation_json="${1:-}"
  local current_key record_key
  [[ -n "$continuation_json" && "$continuation_json" != "null" ]] || return 1
  declare -F ralph_session_todo_attempt_key >/dev/null 2>&1 || return 1
  current_key="$(ralph_session_todo_attempt_key "$(ralph_session_todo_identity_json)")"
  record_key="$(jq -r '.attemptKey // empty' <<<"$continuation_json")"
  [[ -n "$record_key" && "$record_key" == "$current_key" ]]
}

workflow_action_continuation_embed_in_json() {
  local record_json="${1:-}" continuation_json="${2:-}"
  [[ -n "$record_json" ]] || return 1
  [[ -n "$continuation_json" && "$continuation_json" != "null" ]] || {
    jq -c '.' <<<"$record_json"
    return 0
  }
  jq -c --argjson continuationIdentity "$continuation_json" \
    '. + {continuationIdentity: $continuationIdentity}' <<<"$record_json"
}

workflow_action_continuation_persist() {
  local continuation_json="${1:-}" reason="${2:-operator-input-wait}"
  local attempt_key request_id path marker now_iso record

  workflow_action_continuation_require_session_dir || return 1
  [[ -n "$continuation_json" && "$continuation_json" != "null" ]] || return 1
  attempt_key="$(jq -r '.attemptKey // empty' <<<"$continuation_json")"
  [[ -n "$attempt_key" ]] || return 1
  request_id="$(workflow_action_continuation_request_id_for_attempt "$attempt_key")" || return 1
  path="$(workflow_action_continuation_record_path "$request_id")" || return 1
  marker="$(workflow_action_continuation_consumed_marker_path "$request_id")" || return 1
  [[ ! -f "$path" ]] || {
    jq -c '.' "$path"
    return 0
  }
  [[ ! -f "$marker" ]] || return 1

  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u)"
  record="$(jq -nc \
    --argjson schema_version 1 \
    --arg kind "workflow-operator-input" \
    --arg request_id "$request_id" \
    --arg tier "invocation" \
    --arg reason "$reason" \
    --arg attempt_key "$attempt_key" \
    --argjson continuationIdentity "$continuation_json" \
    --arg created_at "$now_iso" \
    '{
      schema_version: $schema_version,
      kind: $kind,
      request_id: $request_id,
      tier: $tier,
      reason: $reason,
      attempt_key: $attempt_key,
      continuationIdentity: $continuationIdentity,
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

workflow_action_continuation_find_pending() {
  local root attempt_key current_key record_path record marker
  workflow_action_continuation_require_session_dir || return 1
  declare -F ralph_session_todo_attempt_key >/dev/null 2>&1 || return 1
  root="$(workflow_action_continuation_root)" || return 1
  [[ -d "$root" ]] || return 1
  current_key="$(ralph_session_todo_attempt_key "$(ralph_session_todo_identity_json)")"
  for record_path in "$root"/workflow-operator-input-*.json; do
    [[ -f "$record_path" ]] || continue
    record="$(jq -c '.' "$record_path" 2>/dev/null)" || continue
    [[ "$(jq -r '.kind // empty' <<<"$record")" == "workflow-operator-input" ]] || continue
    [[ "$(jq -r '.consumed // false' <<<"$record")" == "false" ]] || continue
    attempt_key="$(jq -r '.attempt_key // empty' <<<"$record")"
    [[ -n "$attempt_key" && "$attempt_key" == "$current_key" ]] || continue
    marker="$(workflow_action_continuation_consumed_marker_path "$(jq -r '.request_id // empty' <<<"$record")")"
    [[ ! -f "$marker" ]] || continue
    jq -c '.' <<<"$record"
    return 0
  done
  return 1
}

workflow_action_continuation_mark_consumed() {
  local request_id="${1:-}" path marker now_iso
  [[ -n "$request_id" ]] || return 1
  path="$(workflow_action_continuation_record_path "$request_id")" || return 1
  marker="$(workflow_action_continuation_consumed_marker_path "$request_id")" || return 1
  [[ -f "$path" ]] || return 1
  [[ ! -f "$marker" ]] || return 1
  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u)"
  jq -c --arg consumed_at "$now_iso" '.consumed = true | .consumed_at = $consumed_at' "$path" >"${path}.tmp" \
    && mv -f "${path}.tmp" "$path"
  printf '%s\n' "$now_iso" >"${marker}.tmp" && mv -f "${marker}.tmp" "$marker"
}

# Persist continuation at operator-input wait boundary (exit 3).
workflow_action_continuation_persist_on_wait() {
  local control_plan="${1:-}" todo_id="${2:-}"
  local continuation
  continuation="$(workflow_action_continuation_build \
    --control-plan "$control_plan" --todo-id "$todo_id")" || return 1
  workflow_action_continuation_persist "$continuation" "operator-input-wait"
}

# Returns 0 when a pending workflow operator-input continuation was consumed.
workflow_action_continuation_try_apply() {
  local record request_id continuation session_id
  record="$(workflow_action_continuation_find_pending 2>/dev/null || true)"
  [[ -n "$record" ]] || return 1
  request_id="$(jq -r '.request_id // empty' <<<"$record")"
  [[ -n "$request_id" ]] || return 1
  continuation="$(jq -c '.continuationIdentity // empty' <<<"$record")"
  [[ -n "$continuation" && "$continuation" != "null" ]] || return 1
  workflow_action_continuation_mark_consumed "$request_id" || return 1

  if declare -F ralph_session_todo_reactivate_for_repair >/dev/null 2>&1; then
    local repair_record
    repair_record="$(jq -nc --argjson session "$(jq -c '.session // {}' <<<"$continuation")" '{session: $session}')"
    ralph_session_todo_reactivate_for_repair "$repair_record" >/dev/null 2>&1 || true
  fi

  session_id="$(jq -r '.session.session_id // empty' <<<"$continuation")"
  if [[ -n "$session_id" ]]; then
    export RALPH_RUN_PLAN_RESUME_SESSION_ID="$session_id"
    unset RALPH_RUN_PLAN_NEW_SESSION_ID 2>/dev/null || true
  fi

  RALPH_PLAN_INVOCATION_REASON="${RALPH_TODO_INVOCATION_REASON_CONTINUE:-todo-continue}"
  export RALPH_PLAN_INVOCATION_REASON
  RALPH_WORKFLOW_OPERATOR_INPUT_CONTINUATION=1
  export RALPH_WORKFLOW_OPERATOR_INPUT_CONTINUATION
  if declare -F ralph_run_plan_log >/dev/null 2>&1; then
    ralph_run_plan_log "tier2 workflow operator-input continuation: consumed record ${request_id}; scheduling todo-continue invocation"
  fi
  return 0
}

workflow_action_continuation_discard_for_attempt_key() {
  local attempt_key="${1:-}" root record_path record rid marker
  [[ -n "$attempt_key" ]] || return 0
  workflow_action_continuation_require_session_dir 2>/dev/null || return 0
  root="$(workflow_action_continuation_root 2>/dev/null)" || return 0
  [[ -d "$root" ]] || return 0
  for record_path in "$root"/workflow-operator-input-*.json; do
    [[ -f "$record_path" ]] || continue
    record="$(jq -c '.' "$record_path" 2>/dev/null)" || continue
    [[ "$(jq -r '.attempt_key // empty' <<<"$record")" == "$attempt_key" ]] || continue
    rid="$(jq -r '.request_id // empty' <<<"$record")"
    rm -f "$record_path" 2>/dev/null || true
    marker="$(workflow_action_continuation_consumed_marker_path "$rid" 2>/dev/null || true)"
    [[ -n "$marker" ]] && rm -f "$marker" 2>/dev/null || true
  done
}

workflow_action_continuation_discard_for_stage_attempt() {
  local run_id="${1:-}" stage_id="${2:-}" attempt_id="${3:-}" root record_path record rid marker
  [[ -n "$run_id" && -n "$stage_id" && -n "$attempt_id" ]] || return 0
  workflow_action_continuation_require_session_dir 2>/dev/null || return 0
  root="$(workflow_action_continuation_root 2>/dev/null)" || return 0
  [[ -d "$root" ]] || return 0
  for record_path in "$root"/workflow-operator-input-*.json; do
    [[ -f "$record_path" ]] || continue
    record="$(jq -c '.' "$record_path" 2>/dev/null)" || continue
    [[ "$(jq -r '.continuationIdentity.identity.workflowRunId // empty' <<<"$record")" == "$run_id" ]] || continue
    [[ "$(jq -r '.continuationIdentity.identity.workflowStageId // empty' <<<"$record")" == "$stage_id" ]] || continue
    [[ "$(jq -r '.continuationIdentity.identity.workflowStageAttempt // empty' <<<"$record")" == "$attempt_id" ]] || continue
    rid="$(jq -r '.request_id // empty' <<<"$record")"
    rm -f "$record_path" 2>/dev/null || true
    marker="$(workflow_action_continuation_consumed_marker_path "$rid" 2>/dev/null || true)"
    [[ -n "$marker" ]] && rm -f "$marker" 2>/dev/null || true
  done
}

workflow_action_continuation_teardown_bg_jobs_for_attempt_key() {
  local attempt_key="${1:-}" record state
  [[ -n "$attempt_key" ]] || return 0
  declare -F ralph_bg_job_list_records >/dev/null 2>&1 || return 0
  declare -F ralph_bg_job_attempt_key >/dev/null 2>&1 || return 0
  declare -F ralph_bg_job_is_outstanding_state >/dev/null 2>&1 || return 0
  declare -F ralph_bg_job_teardown_one_record >/dev/null 2>&1 || return 0
  while IFS= read -r record; do
    [[ -n "$record" ]] || continue
    [[ "$(ralph_bg_job_attempt_key "$(jq -c '.identity' <<<"$record")")" == "$attempt_key" ]] || continue
    state="$(jq -r '.state // empty' <<<"$record")"
    ralph_bg_job_is_outstanding_state "$state" || continue
    ralph_bg_job_teardown_one_record "$record" "stage-boundary" || true
  done < <(ralph_bg_job_list_records 2>/dev/null || true)
}

workflow_action_continuation_teardown_bg_jobs_for_stage_attempt() {
  local run_id="${1:-}" stage_id="${2:-}" attempt_id="${3:-}" record state
  [[ -n "$run_id" && -n "$stage_id" && -n "$attempt_id" ]] || return 0
  declare -F ralph_bg_job_list_records >/dev/null 2>&1 || return 0
  declare -F ralph_bg_job_is_outstanding_state >/dev/null 2>&1 || return 0
  declare -F ralph_bg_job_teardown_one_record >/dev/null 2>&1 || return 0
  while IFS= read -r record; do
    [[ -n "$record" ]] || continue
    [[ "$(jq -r '.identity.workflowRunId // empty' <<<"$record")" == "$run_id" ]] || continue
    [[ "$(jq -r '.identity.workflowStageId // empty' <<<"$record")" == "$stage_id" ]] || continue
    [[ "$(jq -r '.identity.workflowStageAttempt // empty' <<<"$record")" == "$attempt_id" ]] || continue
    state="$(jq -r '.state // empty' <<<"$record")"
    ralph_bg_job_is_outstanding_state "$state" || continue
    ralph_bg_job_teardown_one_record "$record" "stage-boundary" || true
  done < <(ralph_bg_job_list_records 2>/dev/null || true)
}

# Retire session manifest and discard continuation/bg state for a prior attempt.
workflow_action_continuation_abandon_attempt() {
  local identity_json="${1:-}" attempt_key manifest_key dir record_path record
  local wf_run wf_stage wf_attempt
  [[ -n "$identity_json" ]] || return 0
  declare -F ralph_session_todo_attempt_key >/dev/null 2>&1 || return 0
  attempt_key="$(ralph_session_todo_attempt_key "$identity_json")"
  wf_run="$(jq -r '.workflowRunId // empty' <<<"$identity_json")"
  wf_stage="$(jq -r '.workflowStageId // empty' <<<"$identity_json")"
  wf_attempt="$(jq -r '.workflowStageAttempt // empty' <<<"$identity_json")"
  workflow_action_continuation_discard_for_attempt_key "$attempt_key"
  if [[ -n "$wf_run" && -n "$wf_stage" && -n "$wf_attempt" ]]; then
    workflow_action_continuation_discard_for_stage_attempt "$wf_run" "$wf_stage" "$wf_attempt"
  fi
  workflow_action_continuation_teardown_bg_jobs_for_stage_attempt "$wf_run" "$wf_stage" "$wf_attempt"
  if [[ -z "$wf_run" || -z "$wf_stage" || -z "$wf_attempt" ]]; then
    workflow_action_continuation_teardown_bg_jobs_for_attempt_key "$attempt_key"
  fi
  if declare -F ralph_session_todo_manifest_key >/dev/null 2>&1 \
    && declare -F ralph_session_todo_mark_retired >/dev/null 2>&1; then
    manifest_key="$(ralph_session_todo_manifest_key "$identity_json" 2>/dev/null)" || manifest_key=""
    if [[ -n "$manifest_key" ]] && ralph_session_todo_read_raw "$manifest_key" >/dev/null 2>&1; then
      ralph_session_todo_mark_retired "$manifest_key" >/dev/null 2>&1 || true
    elif declare -F ralph_session_todo_manifest_dir >/dev/null 2>&1; then
      local wf_run wf_stage wf_attempt
      wf_run="$(jq -r '.workflowRunId // empty' <<<"$identity_json")"
      wf_stage="$(jq -r '.workflowStageId // empty' <<<"$identity_json")"
      wf_attempt="$(jq -r '.workflowStageAttempt // empty' <<<"$identity_json")"
      dir="$(ralph_session_todo_manifest_dir 2>/dev/null)" || dir=""
      if [[ -n "$dir" && -d "$dir" && -n "$wf_run" && -n "$wf_stage" && -n "$wf_attempt" ]]; then
        for record_path in "$dir"/*.json; do
          [[ -f "$record_path" ]] || continue
          record="$(jq -c '.' "$record_path" 2>/dev/null)" || continue
          [[ "$(jq -r '.identity.workflowRunId // empty' <<<"$record")" == "$wf_run" ]] || continue
          [[ "$(jq -r '.identity.workflowStageId // empty' <<<"$record")" == "$wf_stage" ]] || continue
          [[ "$(jq -r '.identity.workflowStageAttempt // empty' <<<"$record")" == "$wf_attempt" ]] || continue
          manifest_key="$(jq -r '.manifest_key // empty' <<<"$record")"
          [[ -n "$manifest_key" ]] || continue
          ralph_session_todo_mark_retired "$manifest_key" >/dev/null 2>&1 || true
        done
      fi
    fi
  fi
}

workflow_action_continuation_identity_for_stage_attempt() {
  local run_id="${1:-}" stage_id="${2:-}" attempt_id="${3:-}" plan_key="${4:-}" runtime="${5:-}"
  [[ -n "$run_id" && -n "$stage_id" && -n "$attempt_id" ]] || return 1
  jq -nc \
    --arg runId "$run_id" \
    --arg planKey "$plan_key" \
    --arg runtime "$runtime" \
    --arg workflowRunId "$run_id" \
    --arg workflowStageId "$stage_id" \
    --arg workflowStageAttempt "$attempt_id" \
    '{
      runId: $runId,
      planKey: (if $planKey == "" then null else $planKey end),
      runtime: (if $runtime == "" then null else $runtime end),
      workflowRunId: $workflowRunId,
      workflowStageId: $workflowStageId,
      workflowStageAttempt: $workflowStageAttempt
    }'
}

workflow_action_continuation_abandon_stage_attempt() {
  local run_id="${1:-}" stage_id="${2:-}" attempt_id="${3:-}" plan_key="${4:-}" runtime="${5:-}"
  local identity
  identity="$(workflow_action_continuation_identity_for_stage_attempt \
    "$run_id" "$stage_id" "$attempt_id" "$plan_key" "$runtime")" || return 1
  workflow_action_continuation_abandon_attempt "$identity"
}

# Copy continuationIdentity from request onto decision/consumed when present.
workflow_action_continuation_copy_from_request() {
  local run_dir="${1:-}" request_id="${2:-}" target_json="${3:-}"
  local req continuation
  [[ -n "$run_dir" && -n "$request_id" && -n "$target_json" ]] || {
    [[ -n "$target_json" ]] || target_json='{}'
    jq -c '.' <<<"$target_json"
    return 0
  }
  req="$(workflow_action_request_read "$run_dir" "$request_id" 2>/dev/null || true)"
  continuation="$(workflow_action_continuation_from_record "$req")"
  workflow_action_continuation_embed_in_json "$target_json" "$continuation"
}
