#!/usr/bin/env bash
# Background job durable state for plan TODO continuations (records only).
#
# Jobs live under $RALPH_SESSION_DIR/bg-jobs/<job-id>/meta.json with stdout and
# stderr reserved for later launch helpers. State machine:
#   requested -> launched -> running -> terminal -> consumed
#
# Terminal status (when state=terminal) is exactly one of:
#   passed | failed | timed_out | cancelled | interrupted | unknown

if [[ -n "${RALPH_BG_JOB_STATE_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
RALPH_BG_JOB_STATE_LOADED=1

RALPH_BG_JOB_SCHEMA_VERSION=1
RALPH_BG_MAX_PER_TODO="${RALPH_BG_MAX_PER_TODO:-8}"

RALPH_BG_JOB_STATE_REQUESTED="requested"
RALPH_BG_JOB_STATE_LAUNCHED="launched"
RALPH_BG_JOB_STATE_RUNNING="running"
RALPH_BG_JOB_STATE_TERMINAL="terminal"
RALPH_BG_JOB_STATE_CONSUMED="consumed"

RALPH_BG_JOB_TERMINAL_PASSED="passed"
RALPH_BG_JOB_TERMINAL_FAILED="failed"
RALPH_BG_JOB_TERMINAL_TIMED_OUT="timed_out"
RALPH_BG_JOB_TERMINAL_CANCELLED="cancelled"
RALPH_BG_JOB_TERMINAL_INTERRUPTED="interrupted"
RALPH_BG_JOB_TERMINAL_UNKNOWN="unknown"

ralph_bg_job_require_session_dir() {
  [[ -n "${RALPH_SESSION_DIR:-}" ]] || {
    printf '%s\n' "Error: RALPH_SESSION_DIR is required for background job state" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || {
    printf '%s\n' "Error: jq is required for background job state" >&2
    return 1
  }
}

ralph_bg_job_root() {
  ralph_bg_job_require_session_dir || return 1
  printf '%s/bg-jobs\n' "$RALPH_SESSION_DIR"
}

ralph_bg_job_dir() {
  local job_id="${1:-}"
  [[ -n "$job_id" ]] || return 1
  [[ "$job_id" != *"/"* && "$job_id" != *".."* ]] || return 1
  printf '%s/%s\n' "$(ralph_bg_job_root)" "$job_id"
}

ralph_bg_job_meta_path() {
  local job_id="${1:-}"
  local dir
  dir="$(ralph_bg_job_dir "$job_id")" || return 1
  printf '%s/meta.json\n' "$dir"
}

ralph_bg_job_command_hash() {
  local command="${1:-}"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$command" <<'PYTHON'
import hashlib
import sys

print(hashlib.sha256(sys.argv[1].encode("utf-8")).hexdigest())
PYTHON
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$command" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$command" | sha256sum | awk '{print $1}'
  else
    printf '%s' "$command"
  fi
}

ralph_bg_job_owner_process_start_id() {
  local pid="${1:-$$}"
  local start=""
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  if [[ -d "/proc/$pid" ]] && command -v stat >/dev/null 2>&1; then
    start="$(stat -c %Z "/proc/$pid" 2>/dev/null || stat -f %B "/proc/$pid" 2>/dev/null || true)"
  fi
  if [[ -z "$start" ]] && command -v ps >/dev/null 2>&1; then
    start="$(ps -o lstart= -p "$pid" 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | head -n1)"
  fi
  [[ -n "$start" ]] || start="unknown"
  printf '%s\n' "$start"
}

ralph_bg_job_run_id() {
  if [[ -n "${RALPH_PROCESS_RUN_ID:-}" ]]; then
    printf '%s\n' "$RALPH_PROCESS_RUN_ID"
  elif [[ -n "${RALPH_GRAPH_RUN_ID:-}" ]]; then
    printf '%s\n' "$RALPH_GRAPH_RUN_ID"
  elif [[ -n "${RALPH_WORKFLOW_RUN_ID:-}" ]]; then
    printf '%s\n' "$RALPH_WORKFLOW_RUN_ID"
  else
    printf '%s\n' ""
  fi
}

ralph_bg_job_identity_json() {
  jq -nc \
    --arg projectRoot "${RALPH_PROJECT_ROOT:-}" \
    --arg stateRoot "${RALPH_PLAN_WORKSPACE_ROOT:-}" \
    --arg agentWorkspace "${RALPH_AGENT_WORKSPACE:-}" \
    --arg planKey "${RALPH_PLAN_KEY:-}" \
    --arg runtime "${RUNTIME:-${RALPH_PLAN_RUNTIME:-}}" \
    --arg runId "$(ralph_bg_job_run_id)" \
    --arg todoLine "${RALPH_CURRENT_TODO_LINE:-}" \
    --arg todoOrdinal "${RALPH_CURRENT_TODO_ORDINAL:-}" \
    --arg todoId "${RALPH_CURRENT_TODO_ID:-}" \
    --arg todoHash "${RALPH_CURRENT_TODO_HASH:-}" \
    --arg workflowRunId "${RALPH_WORKFLOW_RUN_ID:-}" \
    --arg workflowStageId "${RALPH_WORKFLOW_STAGE_ID:-}" \
    --arg workflowStageAttempt "${RALPH_WORKFLOW_STAGE_ATTEMPT:-}" \
    '{
      projectRoot: (if $projectRoot == "" then null else $projectRoot end),
      stateRoot: (if $stateRoot == "" then null else $stateRoot end),
      agentWorkspace: (if $agentWorkspace == "" then null else $agentWorkspace end),
      planKey: (if $planKey == "" then null else $planKey end),
      runtime: (if $runtime == "" then null else $runtime end),
      runId: (if $runId == "" then null else $runId end),
      todoLine: (if $todoLine == "" then null else $todoLine end),
      todoOrdinal: (if $todoOrdinal == "" then null else $todoOrdinal end),
      todoId: (if $todoId == "" then null else $todoId end),
      todoHash: (if $todoHash == "" then null else $todoHash end),
      workflowRunId: (if $workflowRunId == "" then null else $workflowRunId end),
      workflowStageId: (if $workflowStageId == "" then null else $workflowStageId end),
      workflowStageAttempt: (if $workflowStageAttempt == "" then null else $workflowStageAttempt end)
    }'
}

ralph_bg_job_attempt_key() {
  local identity_json="${1:-}"
  jq -c '[
    .planKey // "",
    .todoLine // "",
    .todoOrdinal // "",
    .todoId // "",
    .todoHash // "",
    .workflowRunId // "",
    .workflowStageId // "",
    .workflowStageAttempt // ""
  ] | join("|")' <<<"$identity_json"
}

ralph_bg_job_valid_terminal_status() {
  local status="${1:-}"
  case "$status" in
    "$RALPH_BG_JOB_TERMINAL_PASSED"|"$RALPH_BG_JOB_TERMINAL_FAILED"|"$RALPH_BG_JOB_TERMINAL_TIMED_OUT"|\
"$RALPH_BG_JOB_TERMINAL_CANCELLED"|"$RALPH_BG_JOB_TERMINAL_INTERRUPTED"|"$RALPH_BG_JOB_TERMINAL_UNKNOWN")
      return 0
      ;;
  esac
  return 1
}

ralph_bg_job_valid_state() {
  local state="${1:-}"
  case "$state" in
    "$RALPH_BG_JOB_STATE_REQUESTED"|"$RALPH_BG_JOB_STATE_LAUNCHED"|"$RALPH_BG_JOB_STATE_RUNNING"|\
"$RALPH_BG_JOB_STATE_TERMINAL"|"$RALPH_BG_JOB_STATE_CONSUMED")
      return 0
      ;;
  esac
  return 1
}

ralph_bg_job_state_allows_transition() {
  local from="${1:-}" to="${2:-}"
  case "$from" in
    "$RALPH_BG_JOB_STATE_REQUESTED")
      [[ "$to" == "$RALPH_BG_JOB_STATE_LAUNCHED" ]]
      ;;
    "$RALPH_BG_JOB_STATE_LAUNCHED")
      [[ "$to" == "$RALPH_BG_JOB_STATE_RUNNING" ]]
      ;;
    "$RALPH_BG_JOB_STATE_RUNNING")
      [[ "$to" == "$RALPH_BG_JOB_STATE_TERMINAL" ]]
      ;;
    "$RALPH_BG_JOB_STATE_TERMINAL")
      [[ "$to" == "$RALPH_BG_JOB_STATE_CONSUMED" ]]
      ;;
    *)
      return 1
      ;;
  esac
}

ralph_bg_job_is_outstanding_state() {
  local state="${1:-}"
  case "$state" in
    "$RALPH_BG_JOB_STATE_REQUESTED"|"$RALPH_BG_JOB_STATE_LAUNCHED"|"$RALPH_BG_JOB_STATE_RUNNING")
      return 0
      ;;
  esac
  return 1
}

ralph_bg_job_atomic_write_meta() {
  local target_path="${1:-}"
  local json_payload="${2:-}"
  local target_dir tmp_file
  [[ -n "$target_path" && -n "$json_payload" ]] || return 1
  target_dir="$(dirname "$target_path")"
  mkdir -p "$target_dir" || return 1
  chmod 700 "$target_dir" 2>/dev/null || true
  tmp_file="$(mktemp "$target_dir/.meta-XXXXXX" 2>/dev/null)" || return 1
  printf '%s\n' "$json_payload" >"$tmp_file" || {
    rm -f "$tmp_file"
    return 1
  }
  chmod 0600 "$tmp_file" 2>/dev/null || true
  if ! mv -f "$tmp_file" "$target_path" 2>/dev/null; then
    rm -f "$tmp_file"
    return 1
  fi
  chmod 0600 "$target_path" 2>/dev/null || true
  return 0
}

ralph_bg_job_record_malformed_reason() {
  local record="${1:-}"
  jq -e '
    type == "object"
    and (.schema_version | type) == "number"
    and (.schema_version == '"$RALPH_BG_JOB_SCHEMA_VERSION"')
    and (.job_id | type) == "string" and (.job_id | length) > 0
    and (.state | type) == "string"
    and (.command | type) == "string"
    and (.command_hash | type) == "string" and (.command_hash | length) > 0
    and (.source_surface | type) == "string"
    and (.timeout_seconds | type) == "number"
    and (.owner_pid | type) == "number"
    and (.owner_process_start_id | type) == "string"
    and (.tier | type) == "number"
    and (.identity | type) == "object"
  ' <<<"$record" >/dev/null 2>&1 || {
    printf '%s\n' "malformed-record"
    return 0
  }
  if ! ralph_bg_job_valid_state "$(jq -r '.state' <<<"$record")"; then
    printf '%s\n' "malformed-state"
    return 0
  fi
  local terminal_state terminal_status
  terminal_state="$(jq -r '.state' <<<"$record")"
  terminal_status="$(jq -r '.terminal_status // empty' <<<"$record")"
  if [[ "$terminal_state" == "$RALPH_BG_JOB_STATE_TERMINAL" ]]; then
    ralph_bg_job_valid_terminal_status "$terminal_status" || {
      printf '%s\n' "invalid-terminal-status"
      return 0
    }
  elif [[ "$terminal_state" == "$RALPH_BG_JOB_STATE_CONSUMED" ]]; then
    :
  elif [[ -n "$terminal_status" && "$terminal_status" != "null" ]]; then
    printf '%s\n' "terminal-status-outside-terminal-state"
    return 0
  fi
  if jq -e '.isolated == false' <<<"$record" >/dev/null 2>&1; then
    printf '%s\n' "non-isolated"
    return 0
  fi
  printf '%s\n' ""
}

ralph_bg_job_identity_mismatch_reason() {
  local record="${1:-}"
  local current_identity current_run record_run
  local current_hash record_hash
  local current_attempt record_attempt

  current_identity="$(ralph_bg_job_identity_json)"
  current_run="$(jq -r '.runId // empty' <<<"$current_identity")"
  record_run="$(jq -r '.identity.runId // empty' <<<"$record")"
  if [[ -n "$current_run" && -n "$record_run" && "$current_run" != "$record_run" ]]; then
    printf '%s\n' "foreign-run-id"
    return 0
  fi

  current_hash="$(jq -r '.todoHash // empty' <<<"$current_identity")"
  record_hash="$(jq -r '.identity.todoHash // empty' <<<"$record")"
  if [[ -n "$current_hash" && -n "$record_hash" && "$current_hash" != "$record_hash" ]]; then
    printf '%s\n' "mismatched-todo-hash"
    return 0
  fi

  current_attempt="$(jq -r '.workflowStageAttempt // empty' <<<"$current_identity")"
  record_attempt="$(jq -r '.identity.workflowStageAttempt // empty' <<<"$record")"
  if [[ -n "$current_attempt" && -n "$record_attempt" && "$current_attempt" != "$record_attempt" ]]; then
    printf '%s\n' "mismatched-workflow-attempt"
    return 0
  fi

  printf '%s\n' ""
}

ralph_bg_job_validate_record() {
  local record="${1:-}"
  local allow_consumed="${2:-0}"
  local reason state

  reason="$(ralph_bg_job_record_malformed_reason "$record")"
  if [[ -n "$reason" ]]; then
    printf '%s\n' "Error: background job record rejected ($reason)" >&2
    return 1
  fi

  state="$(jq -r '.state' <<<"$record")"
  if [[ "$state" == "$RALPH_BG_JOB_STATE_CONSUMED" && "$allow_consumed" != "1" ]]; then
    printf '%s\n' "Error: background job record already consumed" >&2
    return 1
  fi

  reason="$(ralph_bg_job_identity_mismatch_reason "$record")"
  if [[ -n "$reason" ]]; then
    printf '%s\n' "Error: background job record rejected ($reason)" >&2
    return 1
  fi

  jq -c '.' <<<"$record"
}

ralph_bg_job_read_raw() {
  local job_id="${1:-}" meta_path
  meta_path="$(ralph_bg_job_meta_path "$job_id")" || return 1
  [[ -f "$meta_path" ]] || {
    printf '%s\n' "Error: background job record not found: $job_id" >&2
    return 1
  }
  jq -c '.' "$meta_path"
}

ralph_bg_job_read() {
  local job_id="${1:-}" allow_consumed="${2:-0}" record
  record="$(ralph_bg_job_read_raw "$job_id")" || return 1
  ralph_bg_job_validate_record "$record" "$allow_consumed"
}

ralph_bg_job_list_records() {
  local root job_dir meta
  root="$(ralph_bg_job_root)" || return 1
  [[ -d "$root" ]] || return 0
  while IFS= read -r -d '' job_dir; do
    meta="$job_dir/meta.json"
    [[ -f "$meta" ]] || continue
    jq -c '.' "$meta" 2>/dev/null || true
  done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
}

ralph_bg_job_count_outstanding() {
  local attempt_key="${1:-$(ralph_bg_job_attempt_key "$(ralph_bg_job_identity_json)")}"
  local count=0 record state identity_key
  while IFS= read -r record; do
    [[ -n "$record" ]] || continue
    state="$(jq -r '.state // empty' <<<"$record")"
    ralph_bg_job_is_outstanding_state "$state" || continue
    identity_key="$(ralph_bg_job_attempt_key "$(jq -c '.identity' <<<"$record")")"
    [[ "$identity_key" == "$attempt_key" ]] || continue
    count=$((count + 1))
  done < <(ralph_bg_job_list_records)
  printf '%s\n' "$count"
}

ralph_bg_job_create_record_json() {
  local job_id="${1:-}"
  local command="${2:-}"
  local source_surface="${3:-}"
  local timeout_sec="${4:-}"
  local tier="${5:-}"
  local owner_pid="${6:-$$}"
  local command_hash identity owner_start now_iso

  [[ -n "$job_id" && -n "$command" && -n "$source_surface" ]] || return 1
  [[ "$timeout_sec" =~ ^[0-9]+$ ]] || return 1
  [[ "$tier" =~ ^[12]$ ]] || return 1
  [[ "$owner_pid" =~ ^[0-9]+$ ]] || return 1

  command_hash="$(ralph_bg_job_command_hash "$command")"
  identity="$(ralph_bg_job_identity_json)"
  owner_start="$(ralph_bg_job_owner_process_start_id "$owner_pid")"
  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u)"

  jq -nc \
    --argjson schema_version "$RALPH_BG_JOB_SCHEMA_VERSION" \
    --arg job_id "$job_id" \
    --arg state "$RALPH_BG_JOB_STATE_REQUESTED" \
    --arg command "$command" \
    --arg command_hash "$command_hash" \
    --arg source_surface "$source_surface" \
    --argjson timeout_seconds "$timeout_sec" \
    --argjson owner_pid "$owner_pid" \
    --arg owner_process_start_id "$owner_start" \
    --argjson tier "$tier" \
    --arg created_at "$now_iso" \
    --arg updated_at "$now_iso" \
    --argjson identity "$identity" \
    '{
      schema_version: $schema_version,
      job_id: $job_id,
      state: $state,
      terminal_status: null,
      command: $command,
      command_hash: $command_hash,
      source_surface: $source_surface,
      timeout_seconds: $timeout_seconds,
      owner_pid: $owner_pid,
      owner_process_start_id: $owner_process_start_id,
      launch_mode: null,
      isolated: null,
      job_pid: null,
      tier: $tier,
      identity: $identity,
      created_at: $created_at,
      updated_at: $updated_at,
      consumed_at: null
    }'
}

ralph_bg_job_create() {
  local job_id="${1:-}"
  local command="${2:-}"
  local source_surface="${3:-}"
  local timeout_sec="${4:-3600}"
  local tier="${5:-1}"
  local owner_pid="${6:-$$}"
  local meta_path record outstanding max_per_todo

  ralph_bg_job_require_session_dir || return 1
  meta_path="$(ralph_bg_job_meta_path "$job_id")" || return 1
  [[ ! -e "$meta_path" ]] || {
    printf '%s\n' "Error: background job record already exists: $job_id" >&2
    return 1
  }

  max_per_todo="$RALPH_BG_MAX_PER_TODO"
  [[ "$max_per_todo" =~ ^[0-9]+$ ]] || max_per_todo=8
  outstanding="$(ralph_bg_job_count_outstanding)"
  if (( outstanding >= max_per_todo )); then
    printf '%s\n' "Error: background job cap exceeded (${outstanding}/${max_per_todo})" >&2
    return 1
  fi

  record="$(ralph_bg_job_create_record_json "$job_id" "$command" "$source_surface" "$timeout_sec" "$tier" "$owner_pid")" || return 1
  ralph_bg_job_atomic_write_meta "$meta_path" "$record" || return 1
  jq -c '.' <<<"$record"
}

ralph_bg_job_write_record() {
  local job_id="${1:-}"
  local record="${2:-}"
  local meta_path

  ralph_bg_job_require_session_dir || return 1
  meta_path="$(ralph_bg_job_meta_path "$job_id")" || return 1
  [[ -f "$meta_path" ]] || {
    printf '%s\n' "Error: background job record not found: $job_id" >&2
    return 1
  }

  record="$(ralph_bg_job_validate_record "$record" 1)" || return 1
  ralph_bg_job_atomic_write_meta "$meta_path" "$record"
}

ralph_bg_job_transition() {
  local job_id="${1:-}"
  local new_state="${2:-}"
  local record job_id_in state now_iso updated

  record="$(ralph_bg_job_read "$job_id")" || return 1
  job_id_in="$(jq -r '.job_id' <<<"$record")"
  state="$(jq -r '.state' <<<"$record")"
  [[ "$job_id_in" == "$job_id" ]] || return 1
  ralph_bg_job_valid_state "$new_state" || return 1
  ralph_bg_job_state_allows_transition "$state" "$new_state" || {
    printf '%s\n' "Error: invalid background job state transition ($state -> $new_state)" >&2
    return 1
  }

  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u)"
  updated="$(jq -c \
    --arg state "$new_state" \
    --arg updated_at "$now_iso" \
    '.state = $state | .updated_at = $updated_at' <<<"$record")"
  ralph_bg_job_write_record "$job_id" "$updated" || return 1
  ralph_bg_job_read "$job_id"
}

ralph_bg_job_mark_launched() {
  local job_id="${1:-}"
  local job_pid="${2:-}"
  local launch_mode="${3:-plain}"
  local isolated="${4:-true}"
  local record state now_iso updated isolated_json

  [[ "$job_pid" =~ ^[0-9]+$ ]] || return 1
  if [[ "$isolated" == "false" || "$isolated" == "0" ]]; then
    printf '%s\n' "Error: background job launch rejected (non-isolated)" >&2
    return 1
  fi
  [[ "$isolated" == "true" || "$isolated" == "1" ]] && isolated_json=true || isolated_json=false

  record="$(ralph_bg_job_read "$job_id")" || return 1
  state="$(jq -r '.state' <<<"$record")"
  [[ "$state" == "$RALPH_BG_JOB_STATE_REQUESTED" ]] || {
    printf '%s\n' "Error: background job launch requires requested state" >&2
    return 1
  }

  local job_process_start_id
  job_process_start_id="$(ralph_bg_job_owner_process_start_id "$job_pid")"

  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u)"
  updated="$(jq -c \
    --arg state "$RALPH_BG_JOB_STATE_LAUNCHED" \
    --arg launch_mode "$launch_mode" \
    --argjson isolated "$isolated_json" \
    --argjson job_pid "$job_pid" \
    --arg job_process_start_id "$job_process_start_id" \
    --arg updated_at "$now_iso" \
    '.state = $state
     | .launch_mode = $launch_mode
     | .isolated = $isolated
     | .job_pid = $job_pid
     | .job_process_start_id = $job_process_start_id
     | .updated_at = $updated_at' <<<"$record")"

  reason="$(ralph_bg_job_record_malformed_reason "$updated")"
  if [[ -n "$reason" ]]; then
    printf '%s\n' "Error: background job launch rejected ($reason)" >&2
    return 1
  fi

  ralph_bg_job_write_record "$job_id" "$updated" || return 1
  ralph_bg_job_read "$job_id"
}

ralph_bg_job_mark_running() {
  ralph_bg_job_transition "$1" "$RALPH_BG_JOB_STATE_RUNNING"
}

ralph_bg_job_mark_terminal() {
  local job_id="${1:-}"
  local terminal_status="${2:-}"
  local record state now_iso updated

  ralph_bg_job_valid_terminal_status "$terminal_status" || {
    printf '%s\n' "Error: invalid background job terminal status: $terminal_status" >&2
    return 1
  }

  record="$(ralph_bg_job_read "$job_id")" || return 1
  state="$(jq -r '.state' <<<"$record")"
  [[ "$state" == "$RALPH_BG_JOB_STATE_RUNNING" ]] || {
    printf '%s\n' "Error: background job terminal requires running state" >&2
    return 1
  }

  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u)"
  updated="$(jq -c \
    --arg state "$RALPH_BG_JOB_STATE_TERMINAL" \
    --arg terminal_status "$terminal_status" \
    --arg updated_at "$now_iso" \
    '.state = $state
     | .terminal_status = $terminal_status
     | .updated_at = $updated_at' <<<"$record")"
  ralph_bg_job_write_record "$job_id" "$updated" || return 1
  ralph_bg_job_read "$job_id"
}

# Teardown/recovery path: mark terminal from any outstanding state.
ralph_bg_job_mark_terminal_from_outstanding() {
  local job_id="${1:-}"
  local terminal_status="${2:-}"
  local termination_reason="${3:-}"
  local record state now_iso updated

  ralph_bg_job_valid_terminal_status "$terminal_status" || return 1
  record="$(ralph_bg_job_read_raw "$job_id")" || return 1
  state="$(jq -r '.state' <<<"$record")"
  ralph_bg_job_is_outstanding_state "$state" || return 1

  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u)"
  updated="$(jq -c \
    --arg state "$RALPH_BG_JOB_STATE_TERMINAL" \
    --arg terminal_status "$terminal_status" \
    --arg termination_reason "$termination_reason" \
    --arg updated_at "$now_iso" \
    '.state = $state
     | .terminal_status = $terminal_status
     | .termination_reason = (if $termination_reason == "" then .termination_reason else $termination_reason end)
     | .updated_at = $updated_at' <<<"$record")"
  ralph_bg_job_write_record "$job_id" "$updated" || return 1
  ralph_bg_job_read "$job_id" 1
}

ralph_bg_job_consume() {
  local job_id="${1:-}"
  local record state now_iso updated

  record="$(ralph_bg_job_read "$job_id")" || return 1
  state="$(jq -r '.state' <<<"$record")"
  [[ "$state" == "$RALPH_BG_JOB_STATE_TERMINAL" ]] || {
    printf '%s\n' "Error: background job consume requires terminal state" >&2
    return 1
  }

  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u)"
  updated="$(jq -c \
    --arg state "$RALPH_BG_JOB_STATE_CONSUMED" \
    --arg consumed_at "$now_iso" \
    --arg updated_at "$now_iso" \
    '.state = $state
     | .consumed_at = $consumed_at
     | .updated_at = $updated_at' <<<"$record")"
  ralph_bg_job_write_record "$job_id" "$updated" || return 1
  ralph_bg_job_read "$job_id" 1
}

ralph_bg_job_id_new() {
  if command -v openssl >/dev/null 2>&1; then
    printf 'bg-%s\n' "$(openssl rand -hex 8 2>/dev/null)"
    return 0
  fi
  printf 'bg-%s\n' "$(printf '%s-%s-%s' "$$" "$(date +%s)" "$RANDOM" | shasum 2>/dev/null | awk '{print substr($1,1,16)}')"
}

ralph_bg_job_find_outstanding_by_command_hash() {
  local command_hash="${1:-}"
  local record state record_hash job_id
  [[ -n "$command_hash" ]] || return 1
  while IFS= read -r record; do
    [[ -n "$record" ]] || continue
    state="$(jq -r '.state // empty' <<<"$record")"
    ralph_bg_job_is_outstanding_state "$state" || continue
    record_hash="$(jq -r '.command_hash // empty' <<<"$record")"
    [[ "$record_hash" == "$command_hash" ]] || continue
    identity_key="$(ralph_bg_job_attempt_key "$(jq -c '.identity' <<<"$record")")"
    [[ "$identity_key" == "$(ralph_bg_job_attempt_key "$(ralph_bg_job_identity_json)")" ]] || continue
    job_id="$(jq -r '.job_id // empty' <<<"$record")"
    [[ -n "$job_id" ]] || continue
    printf '%s\n' "$job_id"
    return 0
  done < <(ralph_bg_job_list_records)
  return 1
}

ralph_bg_job_mark_requested_reason() {
  local job_id="${1:-}"
  local reason="${2:-}"
  local launch_mode="${3:-plain}"
  local record state now_iso updated

  [[ -n "$reason" ]] || return 1
  record="$(ralph_bg_job_read "$job_id")" || return 1
  state="$(jq -r '.state' <<<"$record")"
  [[ "$state" == "$RALPH_BG_JOB_STATE_REQUESTED" ]] || {
    printf '%s\n' "Error: background job requested reason requires requested state" >&2
    return 1
  }

  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u)"
  updated="$(jq -c \
    --arg state "$RALPH_BG_JOB_STATE_REQUESTED" \
    --arg requested_reason "$reason" \
    --arg launch_mode "$launch_mode" \
    --arg updated_at "$now_iso" \
    '.state = $state
     | .requested_reason = $requested_reason
     | .launch_mode = $launch_mode
     | .job_pid = null
     | .isolated = null
     | .updated_at = $updated_at' <<<"$record")"
  ralph_bg_job_write_record "$job_id" "$updated" || return 1
  ralph_bg_job_read "$job_id"
}
