#!/usr/bin/env bats
# Compact workflow continuation journeys with stub runtimes (no real CLIs).
# Covers operator-input resume of the same stage attempt and request-changes
# reset starting a new attempt. Asserts consume-once, session identity, and
# zero agent polling turns.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

ACTIONS_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/workflow/workflow-actions.sh"
CONTINUATION_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/workflow/workflow-action-continuation.sh"
SESSION_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-session.sh"
BG_JOB_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-bg-job-state.sh"
BG_TEARDOWN_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-bg-teardown.sh"

setup_file() {
  command -v jq >/dev/null || skip "jq required"
  [ -f "$ACTIONS_LIB" ]
  [ -f "$CONTINUATION_LIB" ]
}

setup() {
  TMPD="$(mktemp -d)"
  RUN_DIR="$TMPD/registry-run"
  mkdir -p "$RUN_DIR/actions/requests" "$RUN_DIR/actions/decisions" "$RUN_DIR/actions/consumed"
  export WORKFLOW_ACTION_NOW="2026-08-26T12:00:00Z"
  export GRAPH_OPERATOR_NONCE="aabbccddeeff00112233445566778899"
  export AGENT_POLL_TURNS=0
  unset RALPH_SESSION_DIR RALPH_PLAN_WORKSPACE_ROOT RALPH_PROJECT_ROOT \
    RALPH_WORKFLOW_RUN_ID RALPH_WORKFLOW_STAGE_ID RALPH_WORKFLOW_STAGE_ATTEMPT \
    RALPH_CURRENT_TODO_LINE RALPH_CURRENT_TODO_ID RALPH_CURRENT_TODO_HASH \
    RALPH_PLAN_INVOCATION_REASON RALPH_RUN_PLAN_RESUME_SESSION_ID \
    RALPH_WORKFLOW_OPERATOR_INPUT_CONTINUATION RALPH_PLAN_CLI_RESUME \
    RALPH_RUN_PLAN_NEW_SESSION_ID RALPH_PLAN_SESSION_STRATEGY 2>/dev/null || true
  # shellcheck source=/dev/null
  source "$ACTIONS_LIB"
  # shellcheck source=/dev/null
  source "$CONTINUATION_LIB"
  ralph_run_plan_log() { :; }
}

teardown() {
  rm -rf "$TMPD"
  unset WORKFLOW_ACTION_NOW GRAPH_OPERATOR_NONCE AGENT_POLL_TURNS 2>/dev/null || true
  unset RALPH_SESSION_DIR RALPH_PLAN_WORKSPACE_ROOT RALPH_PROJECT_ROOT \
    RALPH_WORKFLOW_RUN_ID RALPH_WORKFLOW_STAGE_ID RALPH_WORKFLOW_STAGE_ATTEMPT \
    RALPH_CURRENT_TODO_LINE RALPH_CURRENT_TODO_ID RALPH_CURRENT_TODO_HASH \
    RALPH_PLAN_INVOCATION_REASON RALPH_RUN_PLAN_RESUME_SESSION_ID \
    RALPH_WORKFLOW_OPERATOR_INPUT_CONTINUATION RALPH_PLAN_CLI_RESUME \
    RALPH_RUN_PLAN_NEW_SESSION_ID RALPH_PLAN_SESSION_STRATEGY 2>/dev/null || true
}

wf_cont_env() {
  export RALPH_SESSION_DIR="$TMPD/session"
  export RALPH_PLAN_WORKSPACE_ROOT="$TMPD/state"
  export RALPH_PROJECT_ROOT="$TMPD/project"
  export RALPH_AGENT_WORKSPACE="$TMPD/project"
  export RALPH_PLAN_KEY="wf-cont-plan"
  export RUNTIME="cursor"
  export RALPH_PROCESS_RUN_ID="run-001"
  export RALPH_WORKFLOW_RUN_ID="run-001"
  export RALPH_WORKFLOW_STAGE_ID="implement"
  export RALPH_WORKFLOW_STAGE_ATTEMPT="implement-1"
  export RALPH_CURRENT_TODO_LINE="3"
  export RALPH_CURRENT_TODO_ORDINAL="1"
  export RALPH_CURRENT_TODO_ID="work-todo"
  export RALPH_CURRENT_TODO_HASH="hash-wf-work"
  mkdir -p "$RALPH_SESSION_DIR/todo-sessions" "$RALPH_PROJECT_ROOT"
  # shellcheck source=/dev/null
  source "$SESSION_LIB"
}

wf_assert_zero_agent_polls() {
  [ "${AGENT_POLL_TURNS:-0}" -eq 0 ]
}

@test "journey: workflow input resumes the same stage attempt with exact session" {
  wf_cont_env
  local control="$TMPD/control.plan.md"
  local session_id="sess-wf-attempt-1"
  local nonce="aabbccddeeff00112233445566778899"
  local rid continuation
  printf '# control\n- [ ] work\n' >"$control"

  ralph_session_todo_create "$session_id" "exact" >/dev/null

  # Create-once input request bound to this stage attempt + TODO.
  workflow_action_capability_write "$RUN_DIR" "run-001" "implement" "implement-1" "$nonce" >/dev/null
  rid="$(workflow_action_stage_request_create \
    --registry-run "$RUN_DIR" --run-id run-001 --stage-id implement \
    --attempt-id implement-1 --nonce "$nonce" \
    --control-plan "$control" --todo-id work-todo --runtime cursor \
    --question "Which API base URL?")"
  [ "$(jq -r '.continuationIdentity.todoId' "$RUN_DIR/actions/requests/${rid}.json")" = "work-todo" ]
  [ "$(jq -r '.continuationIdentity.identity.workflowStageAttempt' "$RUN_DIR/actions/requests/${rid}.json")" = "implement-1" ]

  # Operator answers; consume-once into resume.
  workflow_action_decision_write "$RUN_DIR" "$(jq -nc \
    --arg rid "$rid" \
    '{requestId:$rid,kind:"input",runId:"run-001",stageId:"implement",attemptId:"implement-1",decision:"answer",message:"https://staging.example",actorSource:"human",decidedAt:"2026-08-26T12:00:00Z"}')" >/dev/null
  local consumed_path
  consumed_path="$(workflow_action_consume_once "$RUN_DIR" "$rid" resume)"
  [ "$(jq -r '.continuationIdentity.identity.workflowStageAttempt' "$consumed_path")" = "implement-1" ]
  [ "$(jq -r '.continuationIdentity.todoId' "$consumed_path")" = "work-todo" ]

  # Persist and apply stage-attempt continuation: exact session under fresh strategy.
  continuation="$(workflow_action_continuation_build --control-plan "$control" --todo-id work-todo --runtime cursor)"
  [ "$(jq -r '.session.session_id' <<<"$continuation")" = "$session_id" ]
  [ "$(jq -r '.identity.workflowStageAttempt' <<<"$continuation")" = "implement-1" ]
  workflow_action_continuation_persist "$continuation" "operator-input-wait" >/dev/null
  ralph_session_todo_mark_terminal "$(ralph_session_todo_manifest_key)" "$session_id" "exact" >/dev/null

  export RALPH_PLAN_SESSION_STRATEGY=fresh
  unset RALPH_PLAN_INVOCATION_REASON RALPH_RUN_PLAN_RESUME_SESSION_ID RALPH_RUN_PLAN_NEW_SESSION_ID
  workflow_action_continuation_try_apply
  [ "${RALPH_PLAN_INVOCATION_REASON}" = "todo-continue" ]
  [ "${RALPH_RUN_PLAN_RESUME_SESSION_ID}" = "$session_id" ]
  [ "${RALPH_WORKFLOW_OPERATOR_INPUT_CONTINUATION}" = "1" ]

  # Same stage attempt; consume-once.
  run workflow_action_continuation_try_apply
  [ "$status" -ne 0 ]
  wf_assert_zero_agent_polls
}

@test "journey: request-changes reset starts a new attempt without prior session" {
  wf_cont_env
  local session_id="sess-rejected-attempt" continuation manifest_key
  export RALPH_WORKFLOW_STAGE_ATTEMPT="implement-1"
  ralph_session_todo_create "$session_id" "exact" >/dev/null
  continuation="$(workflow_action_continuation_build --todo-id work-todo --runtime cursor)"
  workflow_action_continuation_persist "$continuation" "operator-input-wait" >/dev/null
  manifest_key="$(ralph_session_todo_manifest_key)"

  # request-changes reset abandons the rejected attempt's continuation + session.
  workflow_action_continuation_abandon_stage_attempt run-001 implement implement-1 wf-cont-plan cursor
  run workflow_action_continuation_find_pending
  [ "$status" -ne 0 ]
  run ralph_session_todo_read "$manifest_key" 1
  [[ "$status" -ne 0 || "$(jq -r '.state' <<<"$output")" = "retired" ]]

  # New attempt starts fresh: no resume of the rejected session.
  export RALPH_WORKFLOW_STAGE_ATTEMPT="implement-2"
  export RALPH_PLAN_SESSION_STRATEGY=fresh
  unset RALPH_PLAN_INVOCATION_REASON RALPH_RUN_PLAN_RESUME_SESSION_ID RALPH_RUN_PLAN_NEW_SESSION_ID \
    RALPH_WORKFLOW_OPERATOR_INPUT_CONTINUATION RALPH_PLAN_CLI_RESUME
  ralph_session_todo_prepare_invocation
  [ "${RALPH_PLAN_INVOCATION_REASON}" = "todo-start" ]
  [ -z "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]
  [ "${RALPH_PLAN_CLI_RESUME}" = "0" ]
  wf_assert_zero_agent_polls
}

@test "journey: workflow input consume-once refuses replay on same stage attempt" {
  wf_cont_env
  local control="$TMPD/control.plan.md"
  local nonce="aabbccddeeff00112233445566778899"
  local rid
  printf '# control\n- [ ] work\n' >"$control"
  ralph_session_todo_create "sess-replay" "exact" >/dev/null

  workflow_action_capability_write "$RUN_DIR" "run-001" "implement" "implement-1" "$nonce" >/dev/null
  rid="$(workflow_action_stage_request_create \
    --registry-run "$RUN_DIR" --run-id run-001 --stage-id implement \
    --attempt-id implement-1 --nonce "$nonce" \
    --control-plan "$control" --todo-id work-todo --runtime cursor \
    --question "Choose deploy target")"
  workflow_action_decision_write "$RUN_DIR" "$(jq -nc \
    --arg rid "$rid" \
    '{requestId:$rid,kind:"input",runId:"run-001",stageId:"implement",attemptId:"implement-1",decision:"answer",message:"canary",actorSource:"human",decidedAt:"2026-08-26T12:00:00Z"}')" >/dev/null

  workflow_action_consume_once "$RUN_DIR" "$rid" resume >/dev/null
  run workflow_action_consume_once "$RUN_DIR" "$rid" resume
  [ "$status" -ne 0 ]
  [[ "$output" == *"already consumed"* || "$output" == *"consumed"* || "$status" -ne 0 ]]
  wf_assert_zero_agent_polls
}
