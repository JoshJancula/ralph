#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

LIB="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-session.sh"
HUMAN_CONTINUATION_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-human-continuation.sh"
POST_VERIFY_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-post-verify.sh"
INVOCATION_WAIT_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-bg-invocation-wait.sh"
BG_STATE_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-bg-job-state.sh"
HOOK_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/native-hook/stop-continuation-hook.sh"

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  TEST_TMPDIR="$(mktemp -d)"
  export RALPH_SESSION_DIR="$TEST_TMPDIR/session"
  export RALPH_PROJECT_ROOT="$TEST_TMPDIR/project"
  export RALPH_PLAN_WORKSPACE_ROOT="$TEST_TMPDIR/state"
  export RALPH_AGENT_WORKSPACE="$TEST_TMPDIR/project"
  export RALPH_PLAN_KEY="todo-session-test"
  export RUNTIME="cursor"
  export RALPH_PROCESS_RUN_ID="run-abc"
  export RALPH_CURRENT_TODO_LINE="10"
  export RALPH_CURRENT_TODO_ORDINAL="1"
  export RALPH_CURRENT_TODO_ID="add-tier2-todo-session-manifest"
  export RALPH_CURRENT_TODO_HASH="hash-abc123"
  mkdir -p "$RALPH_SESSION_DIR"
  # shellcheck disable=SC1090
  source "$LIB"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

todo_session_seed_identity() {
  export RALPH_PROCESS_RUN_ID="${1:-run-abc}"
  export RALPH_CURRENT_TODO_HASH="${2:-hash-abc123}"
  export RALPH_CURRENT_TODO_ID="${3:-add-tier2-todo-session-manifest}"
  export RALPH_WORKFLOW_STAGE_ATTEMPT="${4:-}"
  export RUNTIME="${5:-cursor}"
}

@test "todo session manifest create writes schema_version 1 with identity fields" {
  todo_session_seed_identity
  local record
  record="$(ralph_session_todo_create "sess-111" "exact")"
  [ "$?" -eq 0 ]
  run jq -r '.schema_version,.state,.runtime,.session_id,.identity.runId,.identity.todoHash' <<<"$record"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "1" ]
  [ "${lines[1]}" = "active" ]
  [ "${lines[2]}" = "cursor" ]
  [ "${lines[3]}" = "sess-111" ]
  [ "${lines[4]}" = "run-abc" ]
  [ "${lines[5]}" = "hash-abc123" ]
}

@test "todo session manifest is written mode 0600 via atomic temp then mv" {
  todo_session_seed_identity
  ralph_session_todo_create "sess-mode" "" >/dev/null
  local manifest_path mode
  manifest_path="$(ralph_session_todo_manifest_path "add-tier2-todo-session-manifest")"
  [ -f "$manifest_path" ]
  mode="$(stat -f '%OLp' "$manifest_path" 2>/dev/null || stat -c '%a' "$manifest_path")"
  [ "$mode" = "600" ]
}

@test "todo session manifest read returns validated record for current identity" {
  todo_session_seed_identity
  ralph_session_todo_create "sess-read" "" >/dev/null
  run ralph_session_todo_select_manifest
  [ "$status" -eq 0 ]
  run jq -r '.manifest_key,.session_id' <<<"$output"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "add-tier2-todo-session-manifest" ]
  [ "${lines[1]}" = "sess-read" ]
}

@test "todo session sanitize_key rejects slashes and path traversal" {
  run ralph_session_todo_sanitize_key "../../etc/passwd"
  [ "$status" -ne 0 ]
  run ralph_session_todo_sanitize_key "foo/bar"
  [ "$status" -ne 0 ]
  run ralph_session_todo_sanitize_key "/absolute/path"
  [ "$status" -ne 0 ]
}

@test "todo session sanitize_key strips control characters from todo id" {
  local sanitized
  sanitized="$(ralph_session_todo_sanitize_key $'evil\x01id.with\x7Fdots')"
  [ "$?" -eq 0 ]
  [[ "$sanitized" != *$'\x01'* ]]
  [ "$sanitized" = "evilid.withdots" ]
}

@test "todo session manifest rejects foreign run id on read" {
  todo_session_seed_identity "run-original"
  ralph_session_todo_create "sess-run" "" >/dev/null
  export RALPH_PROCESS_RUN_ID="run-foreign"
  run ralph_session_todo_select_manifest
  [ "$status" -ne 0 ]
  [[ "$output" == *"foreign-run-id"* ]]
}

@test "todo session manifest rejects mismatched TODO hash on read" {
  todo_session_seed_identity "run-abc" "hash-original"
  ralph_session_todo_create "sess-hash" "" >/dev/null
  export RALPH_CURRENT_TODO_HASH="hash-different"
  run ralph_session_todo_select_manifest
  [ "$status" -ne 0 ]
  [[ "$output" == *"mismatched-todo-hash"* ]]
}

@test "todo session manifest rejects mismatched runtime on read" {
  todo_session_seed_identity "run-abc" "hash-abc123" "add-tier2-todo-session-manifest" "" "cursor"
  ralph_session_todo_create "sess-runtime" "" >/dev/null
  export RUNTIME="claude"
  run ralph_session_todo_select_manifest
  [ "$status" -ne 0 ]
  [[ "$output" == *"mismatched-runtime"* ]]
}

@test "todo session manifest rejects mismatched workflow attempt on read" {
  todo_session_seed_identity "run-abc" "hash-abc123" "add-tier2-todo-session-manifest" "attempt-1"
  export RALPH_WORKFLOW_RUN_ID="wf-run"
  export RALPH_WORKFLOW_STAGE_ID="stage-a"
  ralph_session_todo_create "sess-wf" "" >/dev/null
  export RALPH_WORKFLOW_STAGE_ATTEMPT="attempt-2"
  run ralph_session_todo_select_manifest
  [ "$status" -ne 0 ]
  [[ "$output" == *"mismatched-workflow-attempt"* ]]
}

@test "todo session manifest select never picks another TODO manifest" {
  todo_session_seed_identity "run-abc" "hash-abc123" "todo-a"
  ralph_session_todo_create "sess-a" "" >/dev/null
  export RALPH_CURRENT_TODO_ID="todo-b"
  export RALPH_CURRENT_TODO_HASH="hash-bbbbb"
  run ralph_session_todo_select_manifest
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

@test "todo session manifest marks terminal and retired states" {
  todo_session_seed_identity
  local record key
  record="$(ralph_session_todo_create "sess-state" "")"
  key="$(jq -r '.manifest_key' <<<"$record")"
  record="$(ralph_session_todo_mark_terminal "$key" "sess-final" "exact")"
  run jq -r '.state,.session_id,.capture' <<<"$record"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "terminal" ]
  [ "${lines[1]}" = "sess-final" ]
  [ "${lines[2]}" = "exact" ]
  record="$(ralph_session_todo_mark_retired "$key")"
  run jq -r '.state,.retired_at' <<<"$record"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "retired" ]
  [[ -n "${lines[1]}" ]]
  run ralph_session_todo_select_manifest
  [ "$status" -ne 0 ]
  [[ "$output" == *"retired"* ]]
}

@test "todo session manifest rejects retired record unless explicitly allowed" {
  todo_session_seed_identity
  local key
  ralph_session_todo_create "sess-retired" "" >/dev/null
  key="$(ralph_session_todo_manifest_key)"
  ralph_session_todo_mark_terminal "$key" "sess-x" "" >/dev/null
  ralph_session_todo_mark_retired "$key" >/dev/null
  run ralph_session_todo_read "$key"
  [ "$status" -ne 0 ]
  [[ "$output" == *"retired"* ]]
  run ralph_session_todo_read "$key" 1
  [ "$status" -eq 0 ]
}

@test "plan-level SESSION_ID_FILE remains independent from todo session manifest" {
  todo_session_seed_identity
  export SESSION_ID_FILE="$RALPH_SESSION_DIR/session-id.cursor.txt"
  printf '%s\n' "plan-level-session" >"$SESSION_ID_FILE"
  chmod 600 "$SESSION_ID_FILE"
  ralph_session_todo_create "todo-bound-session" "" >/dev/null
  run cat "$SESSION_ID_FILE"
  [ "$status" -eq 0 ]
  [ "$output" = "plan-level-session" ]
  run ralph_session_todo_select_manifest
  [ "$status" -eq 0 ]
  run jq -r '.session_id' <<<"$output"
  [ "$output" = "todo-bound-session" ]
}

@test "todo session exact capture persists session id to manifest" {
  todo_session_seed_identity
  export SESSION_ID_FILE="$RALPH_SESSION_DIR/session-id.cursor.txt"
  printf '%s\n' "captured-exact-id" >"$SESSION_ID_FILE"
  chmod 600 "$SESSION_ID_FILE"
  ralph_session_todo_capture_after_invocation
  run ralph_session_todo_select_manifest
  [ "$status" -eq 0 ]
  run jq -r '.session_id,.capture' <<<"$output"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "captured-exact-id" ]
  [ "${lines[1]}" = "exact" ]
}

@test "todo session degraded capture records degraded without guessing session id" {
  todo_session_seed_identity
  export SESSION_ID_FILE="$RALPH_SESSION_DIR/session-id.cursor.txt"
  rm -f "$SESSION_ID_FILE"
  ralph_session_todo_capture_after_invocation
  run ralph_session_todo_select_manifest
  [ "$status" -eq 0 ]
  run jq -r '.session_id,.capture' <<<"$output"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "null" ]
  [ "${lines[1]}" = "degraded" ]
}

@test "todo session fresh todo-start omits resume under fresh strategy" {
  todo_session_seed_identity
  export SESSION_ID_FILE="$RALPH_SESSION_DIR/session-id.cursor.txt"
  export RALPH_PLAN_SESSION_STRATEGY=fresh
  unset RALPH_PLAN_INVOCATION_REASON RALPH_RUN_PLAN_RESUME_SESSION_ID RALPH_RUN_PLAN_NEW_SESSION_ID RALPH_RUN_PLAN_RESUME_BARE
  ralph_run_plan_log() { :; }
  ralph_session_todo_prepare_invocation
  [ "${RALPH_PLAN_INVOCATION_REASON:-}" = "todo-start" ]
  [ "${RALPH_PLAN_CLI_RESUME:-1}" = "0" ]
  [ -z "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]
}

@test "todo session todo-continue uses exact manifest id under fresh strategy" {
  todo_session_seed_identity
  export SESSION_ID_FILE="$RALPH_SESSION_DIR/session-id.cursor.txt"
  ralph_session_todo_create "manifest-bound-id" "exact" >/dev/null
  export RALPH_PLAN_SESSION_STRATEGY=fresh
  unset RALPH_PLAN_INVOCATION_REASON RALPH_RUN_PLAN_RESUME_SESSION_ID RALPH_RUN_PLAN_NEW_SESSION_ID RALPH_RUN_PLAN_RESUME_BARE
  ralph_run_plan_log() { :; }
  ralph_session_todo_prepare_invocation
  [ "${RALPH_PLAN_INVOCATION_REASON:-}" = "todo-continue" ]
  [ "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" = "manifest-bound-id" ]
}

@test "todo session cli_resume derived for todo-continue reason" {
  todo_session_seed_identity
  ralph_session_todo_create "sess-cli-resume" "exact" >/dev/null
  export RALPH_PLAN_SESSION_STRATEGY=fresh
  ralph_run_plan_log() { :; }
  ralph_session_todo_prepare_invocation
  [ "${RALPH_PLAN_CLI_RESUME:-0}" = "1" ]
}

@test "todo session cli_resume derived for fresh todo-start boundary" {
  todo_session_seed_identity
  export RALPH_PLAN_SESSION_STRATEGY=fresh
  export RALPH_PLAN_INVOCATION_REASON=todo-start
  ralph_session_derive_cli_resume
  [ "${RALPH_PLAN_CLI_RESUME:-1}" = "0" ]
  export RALPH_PLAN_SESSION_STRATEGY=resume
  ralph_session_derive_cli_resume
  [ "${RALPH_PLAN_CLI_RESUME:-0}" = "1" ]
}

@test "todo session boundary retires manifest after completion" {
  todo_session_seed_identity
  ralph_session_todo_create "sess-boundary" "exact" >/dev/null
  export SESSION_ID_FILE="$RALPH_SESSION_DIR/session-id.cursor.txt"
  printf '%s\n' "sess-boundary" >"$SESSION_ID_FILE"
  ralph_session_todo_retire_at_boundary
  run ralph_session_todo_select_manifest
  [ "$status" -ne 0 ]
  [[ "$output" == *"retired"* ]]
}

@test "todo session rotation deferred at persisted wait boundary" {
  todo_session_seed_identity
  export SESSION_ID_FILE="$RALPH_SESSION_DIR/session-id.cursor.txt"
  export PENDING_HUMAN="$RALPH_SESSION_DIR/pending-human.txt"
  export PENDING_ABS="$PENDING_HUMAN"
  printf '%s\n' "old-session" >"$SESSION_ID_FILE"
  printf '%s\n' "waiting" >"$PENDING_HUMAN"
  printf '%s\n' "1" >"$RALPH_SESSION_DIR/session-turn-count.txt"
  ralph_run_plan_log() { :; }
  ralph_session_maybe_rotate 1
  [ -f "$SESSION_ID_FILE" ]
  run cat "$SESSION_ID_FILE"
  [ "$output" = "old-session" ]
}

@test "todo session prepare exports manifest path for capture wiring" {
  todo_session_seed_identity
  ralph_run_plan_log() { :; }
  ralph_session_todo_prepare_invocation
  [ -n "${RALPH_TODO_SESSION_MANIFEST_KEY:-}" ]
  [ -n "${RALPH_TODO_SESSION_MANIFEST_PATH:-}" ]
  [ -n "${RALPH_TODO_SESSION_MANIFEST_DIR:-}" ]
  [[ "${RALPH_TODO_SESSION_MANIFEST_PATH:-}" == *"/todo-sessions/add-tier2-todo-session-manifest.json" ]]
}

@test "todo session capture after invocation updates active manifest exact" {
  todo_session_seed_identity
  ralph_session_todo_create "initial-id" "degraded" >/dev/null
  export SESSION_ID_FILE="$RALPH_SESSION_DIR/session-id.cursor.txt"
  printf '%s\n' "updated-exact-id" >"$SESSION_ID_FILE"
  ralph_session_todo_capture_after_invocation
  run ralph_session_todo_select_manifest
  run jq -r '.session_id,.capture' <<<"$output"
  [ "${lines[0]}" = "updated-exact-id" ]
  [ "${lines[1]}" = "exact" ]
}

@test "todo session grader fresh isolation preserved before prepare" {
  todo_session_seed_identity
  export RALPH_GRADER_STAGE=1
  export RALPH_MODE=ralph
  export RALPH_PLAN_SESSION_STRATEGY=resume
  export RALPH_PLAN_CLI_RESUME=1
  export RALPH_RUN_PLAN_RESUME_SESSION_ID=grader-session
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/rubric-grader.sh"
  ralph_rubric_grader_apply_session_isolation
  ralph_run_plan_log() { :; }
  ralph_session_todo_prepare_invocation
  [ "${RALPH_PLAN_SESSION_STRATEGY:-}" = "fresh" ]
  [ "${RALPH_PLAN_CLI_RESUME:-1}" = "0" ]
  [ -z "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]
}

@test "todo session stale manifest retired at new logical attempt boundary" {
  todo_session_seed_identity "run-abc" "hash-original"
  ralph_session_todo_create "sess-stale" "exact" >/dev/null
  export RALPH_CURRENT_TODO_HASH="hash-new-attempt"
  ralph_session_todo_reconcile_stale_manifest
  run ralph_session_todo_read "$(ralph_session_todo_manifest_key)" 1
  [ "$status" -eq 0 ]
  [ "$(jq -r '.state' <<<"$output")" = "retired" ]
  ralph_session_todo_create "sess-new" "exact" >/dev/null
  run jq -r '.session_id' <<<"$(ralph_session_todo_select_manifest)"
  [ "$output" = "sess-new" ]
}

@test "tier2 degraded continuity clears resume after invocation wait" {
  # shellcheck disable=SC1090
  source "$BG_STATE_LIB"
  # shellcheck disable=SC1090
  source "$HOOK_LIB"
  # shellcheck disable=SC1090
  source "$INVOCATION_WAIT_LIB"
  export RALPH_BG_JOBS=1
  export RALPH_BG_TIER_SELECTED=invocation
  export RALPH_CURRENT_TODO_LINE="12"
  export RALPH_CURRENT_TODO_ORDINAL="1"
  export RALPH_CURRENT_TODO_HASH="hash-tier2-degraded"
  export RALPH_PROCESS_RUN_ID="run-tier2-degraded"
  ralph_run_plan_log() { :; }
  ralph_session_todo_create "" "degraded" >/dev/null
  ralph_bg_job_create "tier2-degraded-job" "echo degraded" "test" 120 1 "$$" >/dev/null
  ralph_bg_job_mark_launched "tier2-degraded-job" 4242 "setsid" "true" >/dev/null
  ralph_bg_job_mark_running "tier2-degraded-job" >/dev/null
  ralph_bg_job_mark_terminal "tier2-degraded-job" "passed" >/dev/null
  printf '%s\n' "degraded-output" >"$(ralph_bg_job_dir tier2-degraded-job)/stdout"
  printf '0\n' >"$(ralph_bg_job_dir tier2-degraded-job)/exit_code"
  export RALPH_RUN_PLAN_RESUME_SESSION_ID=must-not-resume
  set +e
  ralph_bg_invocation_wait_after_turn
  status=$?
  set -e
  [ "$status" -eq 10 ]
  [ -z "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]
  export RALPH_PLAN_SESSION_STRATEGY=fresh
  unset RALPH_PLAN_INVOCATION_REASON RALPH_RUN_PLAN_NEW_SESSION_ID RALPH_RUN_PLAN_RESUME_BARE
  ralph_session_todo_prepare_invocation
  [ "${RALPH_PLAN_INVOCATION_REASON:-}" = "todo-start" ]
  [ -z "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]
}

@test "tier2 invocation-boundary resume uses exact manifest id under fresh strategy" {
  # shellcheck disable=SC1090
  source "$BG_STATE_LIB"
  # shellcheck disable=SC1090
  source "$HOOK_LIB"
  # shellcheck disable=SC1090
  source "$INVOCATION_WAIT_LIB"
  export RALPH_BG_JOBS=1
  export RALPH_BG_TIER_SELECTED=invocation
  export RALPH_CURRENT_TODO_LINE="12"
  export RALPH_CURRENT_TODO_ORDINAL="1"
  export RALPH_CURRENT_TODO_HASH="hash-tier2-resume"
  export RALPH_PROCESS_RUN_ID="run-tier2-resume"
  ralph_run_plan_log() { :; }
  ralph_session_todo_create "manifest-tier2-resume" "exact" >/dev/null
  ralph_bg_job_create "tier2-resume-job" "echo resume" "test" 120 1 "$$" >/dev/null
  ralph_bg_job_mark_launched "tier2-resume-job" 4242 "setsid" "true" >/dev/null
  ralph_bg_job_mark_running "tier2-resume-job" >/dev/null
  ralph_bg_job_mark_terminal "tier2-resume-job" "passed" >/dev/null
  printf '%s\n' "resume-output" >"$(ralph_bg_job_dir tier2-resume-job)/stdout"
  printf '0\n' >"$(ralph_bg_job_dir tier2-resume-job)/exit_code"
  set +e
  ralph_bg_invocation_wait_after_turn
  status=$?
  set -e
  [ "$status" -eq 10 ]
  export RALPH_PLAN_SESSION_STRATEGY=fresh
  unset RALPH_PLAN_INVOCATION_REASON RALPH_RUN_PLAN_NEW_SESSION_ID RALPH_RUN_PLAN_RESUME_BARE
  ralph_session_todo_prepare_invocation
  [ "${RALPH_PLAN_INVOCATION_REASON:-}" = "todo-continue" ]
  [ "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" = "manifest-tier2-resume" ]
  [ "${RALPH_PLAN_CLI_RESUME:-0}" = "1" ]
}

@test "human-answer guidance continuation persists consume-once record" {
  # shellcheck disable=SC1090
  source "$HUMAN_CONTINUATION_LIB"
  todo_session_seed_identity "run-human-guidance" "hash-human-guidance" "human-guidance-todo"
  ralph_session_todo_create "sess-human-guidance" "exact" >/dev/null
  local record request_id path
  record="$(ralph_human_continuation_persist "guidance" "")"
  [ "$?" -eq 0 ]
  run jq -r '.kind,.route,.consumed' <<<"$record"
  [ "${lines[0]}" = "human-answer" ]
  [ "${lines[1]}" = "guidance" ]
  [ "${lines[2]}" = "false" ]
  request_id="$(jq -r '.request_id' <<<"$record")"
  path="$(ralph_human_continuation_record_path "$request_id")"
  [ -f "$path" ]
  run ralph_human_continuation_persist "guidance" ""
  [ "$status" -ne 0 ]
}

@test "human-answer permission allow continuation records route and decision" {
  # shellcheck disable=SC1090
  source "$HUMAN_CONTINUATION_LIB"
  todo_session_seed_identity "run-human-permission" "hash-human-permission" "human-permission-todo"
  ralph_session_todo_create "sess-human-permission" "exact" >/dev/null
  local record
  record="$(ralph_human_continuation_persist "permission" "allow")"
  run jq -r '.route,.permission_decision' <<<"$record"
  [ "${lines[0]}" = "permission" ]
  [ "${lines[1]}" = "allow" ]
}

@test "human-answer generic continuation resolves identity from active manifest" {
  # shellcheck disable=SC1090
  source "$HUMAN_CONTINUATION_LIB"
  todo_session_seed_identity "run-human-generic" "hash-human-generic" "human-generic-todo"
  ralph_session_todo_create "sess-human-generic" "exact" >/dev/null
  unset RALPH_CURRENT_TODO_LINE RALPH_CURRENT_TODO_ORDINAL RALPH_CURRENT_TODO_ID RALPH_CURRENT_TODO_HASH
  local record
  record="$(ralph_human_continuation_persist "generic" "")"
  run jq -r '.identity.todoId' <<<"$record"
  [ "$output" = "human-generic-todo" ]
}

@test "human-answer deny does not create continuation record" {
  # shellcheck disable=SC1090
  source "$HUMAN_CONTINUATION_LIB"
  todo_session_seed_identity "run-human-deny" "hash-human-deny" "human-deny-todo"
  ralph_session_todo_create "sess-human-deny" "exact" >/dev/null
  local root count
  root="$(ralph_human_continuation_root)"
  mkdir -p "$root"
  count=0
  for _f in "$root"/human-answer-*.json; do
    [[ -f "$_f" ]] && count=$((count + 1))
  done
  [ "$count" -eq 0 ]
}

@test "human-answer continuation apply forces todo-continue under fresh strategy" {
  # shellcheck disable=SC1090
  source "$HUMAN_CONTINUATION_LIB"
  todo_session_seed_identity "run-human-apply" "hash-human-apply" "human-apply-todo"
  ralph_session_todo_create "sess-human-apply" "exact" >/dev/null
  ralph_human_continuation_persist "guidance" "" >/dev/null
  export RALPH_PLAN_SESSION_STRATEGY=fresh
  unset RALPH_PLAN_INVOCATION_REASON RALPH_RUN_PLAN_RESUME_SESSION_ID RALPH_RUN_PLAN_NEW_SESSION_ID RALPH_RUN_PLAN_RESUME_BARE
  ralph_run_plan_log() { :; }
  ralph_session_todo_prepare_invocation
  [ "${RALPH_PLAN_INVOCATION_REASON:-}" = "todo-continue" ]
  [ "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" = "sess-human-apply" ]
  [ "${RALPH_PLAN_CLI_RESUME:-0}" = "1" ]
  run ralph_human_continuation_try_apply
  [ "$status" -ne 0 ]
}

@test "human-answer offline operator-response path uses tier2 continuation not session strategy" {
  [ -f "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-core.sh" ] || skip "run-plan-core missing"
  local tmp_dir pending human_context operator_response human_request log_file run_plan_core_lib helper
  tmp_dir="$(mktemp -d)"
  run_plan_core_lib="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-core.sh"
  mkdir -p "$RALPH_SESSION_DIR/continuations"
  pending="$tmp_dir/pending-human.txt"
  printf 'offline question\n' >"$pending"
  human_request="$RALPH_SESSION_DIR/human-request.json"
  cat <<'EOF' >"$human_request"
{
  "placeholder": false,
  "kind": "guidance",
  "decision": "answer",
  "runtime": "cursor",
  "classification": "",
  "blocked_command_or_tool": "",
  "blocked_path": "",
  "blocked_tool": "",
  "reason": "",
  "question": "offline question",
  "todo_line": 10
}
EOF
  human_context="$tmp_dir/HUMAN-CONTEXT.md"
  printf '### history\n' >"$human_context"
  operator_response="$tmp_dir/operator-response.txt"
  cat <<'EOF' >"$operator_response"
{
  "placeholder": false,
  "kind": "guidance",
  "decision": "answer",
  "runtime": "cursor",
  "classification": "",
  "blocked_command_or_tool": "",
  "blocked_path": "",
  "blocked_tool": "",
  "reason": "",
  "answer": "offline answer"
}
EOF
  log_file="$tmp_dir/log.txt"
  todo_session_seed_identity "run-human-offline" "hash-human-offline" "human-offline-todo"
  export RALPH_CURRENT_TODO_LINE="10"
  ralph_session_todo_create "sess-human-offline" "exact" >/dev/null
  helper="$(mktemp)"
  sed -n '/^ralph_json_field()/,/^}/p' "$run_plan_core_lib" >"$helper"
  sed -n '/^ralph_operator_has_real_answer()/,/^}/p' "$run_plan_core_lib" >>"$helper"
  sed -n '/^ralph_operator_response_file_owned_by_current_user()/,/^}/p' "$run_plan_core_lib" >>"$helper"
  sed -n '/^ralph_try_consume_human_response()/,/^}/p' "$run_plan_core_lib" >>"$helper"
  printf 'source %q\n' "$REPO_ROOT/bundle/.ralph/bash-lib/permission-classify.sh" >>"$helper"
  printf 'source %q\n' "$LIB" >>"$helper"
  run bash -c '
    set -euo pipefail
    source "$1"
    HUMAN_CONTEXT="$2"
    PENDING_HUMAN="$3"
    HUMAN_REQUEST_FILE="$4"
    OPERATOR_RESPONSE_FILE="$5"
    LOG_FILE="$6"
    C_R="" C_G="" C_Y="" C_B="" C_C="" C_BOLD="" C_DIM="" C_RST=""
    log(){ printf "%s\n" "$*" >>"$LOG_FILE"; }
    ralph_run_plan_log(){ log "$@"; }
    ralph_try_consume_human_response
    printf "STRATEGY=%s\n" "${RALPH_PLAN_SESSION_STRATEGY:-unset}"
    printf "CONT=%s\n" "$(ls -1 "$RALPH_SESSION_DIR/continuations"/human-answer-*.json 2>/dev/null | wc -l | tr -d " ")"
  ' _ "$helper" "$human_context" "$pending" "$human_request" "$operator_response" "$log_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CONT=1"* ]]
  [[ "$output" != *"STRATEGY=resume"* ]]
  [ ! -f "$pending" ]
  rm -f "$helper"
  rm -rf "$tmp_dir"
}

@test "post-verification repair continuation persists consume-once record" {
  # shellcheck disable=SC1090
  source "$POST_VERIFY_LIB"
  todo_session_seed_identity "run-post-verify" "hash-post-verify" "post-verify-todo"
  ralph_session_todo_create "sess-post-verify" "exact" >/dev/null
  local record request_id path
  record="$(ralph_post_verify_repair_persist "strict_verify_command_failed" "  exit=1" ".ralph-workspace/artifacts/x.txt" "false" "10")"
  [ "$?" -eq 0 ]
  run jq -r '.kind,.reason,.consumed' <<<"$record"
  [ "${lines[0]}" = "post-verification-repair" ]
  [ "${lines[1]}" = "post-verification-repair" ]
  [ "${lines[2]}" = "false" ]
  request_id="$(jq -r '.request_id' <<<"$record")"
  path="$(ralph_post_verify_repair_record_path "$request_id")"
  [ -f "$path" ]
  run ralph_post_verify_repair_persist "strict_verify_command_failed" "dup" "" "" "10"
  [ "$status" -ne 0 ]
}

@test "post-verification repair records failure summary artifact and command" {
  # shellcheck disable=SC1090
  source "$POST_VERIFY_LIB"
  todo_session_seed_identity "run-post-verify-meta" "hash-post-verify-meta" "post-verify-meta-todo"
  ralph_session_todo_create "sess-post-verify-meta" "exact" >/dev/null
  local record
  record="$(ralph_post_verify_repair_persist "strict_verify_command_failed" "  test failed" ".ralph-workspace/artifacts/y.txt" "bin/bats --filter x" "12")"
  run jq -r '.failure_summary,.failure_artifact,.failure_command,.todo_line' <<<"$record"
  [ "${lines[0]}" = "  test failed" ]
  [ "${lines[1]}" = ".ralph-workspace/artifacts/y.txt" ]
  [ "${lines[2]}" = "bin/bats --filter x" ]
  [ "${lines[3]}" = "12" ]
}

@test "post-verification repair apply forces todo-continue under fresh strategy" {
  # shellcheck disable=SC1090
  source "$POST_VERIFY_LIB"
  todo_session_seed_identity "run-post-verify-apply" "hash-post-verify-apply" "post-verify-apply-todo"
  local manifest_key
  ralph_session_todo_create "sess-post-verify-apply" "exact" >/dev/null
  manifest_key="$(ralph_session_todo_manifest_key)"
  ralph_session_todo_mark_terminal "$manifest_key" "sess-post-verify-apply" "exact" >/dev/null
  ralph_session_todo_mark_retired "$manifest_key" >/dev/null
  ralph_post_verify_repair_persist "strict_verify_command_failed" "  failed" "" "false" "10" >/dev/null
  export RALPH_PLAN_SESSION_STRATEGY=fresh
  unset RALPH_PLAN_INVOCATION_REASON RALPH_RUN_PLAN_RESUME_SESSION_ID RALPH_RUN_PLAN_NEW_SESSION_ID RALPH_RUN_PLAN_RESUME_BARE
  ralph_run_plan_log() { :; }
  ralph_session_todo_prepare_invocation
  [ "${RALPH_PLAN_INVOCATION_REASON:-}" = "todo-continue" ]
  [ "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" = "sess-post-verify-apply" ]
  [ "${RALPH_PLAN_CLI_RESUME:-0}" = "1" ]
  [ "${POST_VERIFICATION_FAILURE_REASON:-}" = "strict_verify_command_failed" ]
  [ "${POST_VERIFICATION_FAILURE_SUMMARY:-}" = "  failed" ]
  run ralph_post_verify_repair_try_apply
  [ "$status" -ne 0 ]
}

@test "post-verification repair reactivates retired manifest for exact session resume" {
  # shellcheck disable=SC1090
  source "$POST_VERIFY_LIB"
  todo_session_seed_identity "run-post-verify-reactivate" "hash-post-verify-reactivate" "post-verify-reactivate-todo"
  local manifest_key record
  ralph_session_todo_create "sess-reactivate" "exact" >/dev/null
  manifest_key="$(ralph_session_todo_manifest_key)"
  ralph_session_todo_mark_terminal "$manifest_key" "sess-reactivate" "exact" >/dev/null
  ralph_session_todo_mark_retired "$manifest_key" >/dev/null
  run ralph_session_todo_select_manifest
  [ "$status" -ne 0 ]
  record="$(ralph_post_verify_repair_persist "strict_verify_command_failed" "  oops" "" "" "10")"
  ralph_run_plan_log() { :; }
  ralph_post_verify_repair_try_apply
  run jq -r '.state,.session_id' <<<"$(ralph_session_todo_select_manifest)"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "active" ]
  [ "${lines[1]}" = "sess-reactivate" ]
}
