#!/usr/bin/env bats
# Common workflow action request/decision/consumption primitives.
# Sourced function tests only — no CLI, engine, or runtime.
# Contracts: agents/rules/test-design.md, agents/rules/testing-workflow.md,
# and .ralph-workspace/artifacts/ralph-first-class-workflows/contracts.md
# (Common actions: kinds, decisions, records).

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

ACTIONS_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/workflow/workflow-actions.sh"
SCHEMA="$REPO_ROOT/bundle/.ralph/schemas/workflow-action.schema.json"
ARTIFACT_SCHEMA_PY="$REPO_ROOT/bundle/.ralph/python/artifact_json_schema.py"

setup_file() {
  command -v jq >/dev/null || skip "jq required"
  command -v python3 >/dev/null || skip "python3 required"
  [ -f "$ACTIONS_LIB" ]
  [ -f "$SCHEMA" ]
  [ -f "$ARTIFACT_SCHEMA_PY" ]
}

setup() {
  TMPD="$(mktemp -d)"
  RUN_DIR="$TMPD/registry-run"
  mkdir -p "$RUN_DIR"
  export WORKFLOW_ACTION_NOW="2026-08-26T12:00:00Z"
  export GRAPH_OPERATOR_NONCE="aabbccddeeff00112233445566778899"
  unset WORKFLOW_ACTION_TEXT_MAX 2>/dev/null || true
  unset RALPH_SESSION_DIR RALPH_PLAN_WORKSPACE_ROOT RALPH_PROJECT_ROOT \
    RALPH_WORKFLOW_RUN_ID RALPH_WORKFLOW_STAGE_ID RALPH_WORKFLOW_STAGE_ATTEMPT \
    RALPH_CURRENT_TODO_LINE RALPH_CURRENT_TODO_ID RALPH_CURRENT_TODO_HASH \
    RALPH_PLAN_INVOCATION_REASON RALPH_RUN_PLAN_RESUME_SESSION_ID \
    RALPH_WORKFLOW_OPERATOR_INPUT_CONTINUATION 2>/dev/null || true
  # shellcheck source=/dev/null
  source "$ACTIONS_LIB"
}

teardown() {
  rm -rf "$TMPD"
  unset WORKFLOW_ACTION_NOW GRAPH_OPERATOR_NONCE WORKFLOW_ACTION_TEXT_MAX 2>/dev/null || true
  unset RALPH_SESSION_DIR RALPH_PLAN_WORKSPACE_ROOT RALPH_PROJECT_ROOT \
    RALPH_WORKFLOW_RUN_ID RALPH_WORKFLOW_STAGE_ID RALPH_WORKFLOW_STAGE_ATTEMPT \
    RALPH_CURRENT_TODO_LINE RALPH_CURRENT_TODO_ID RALPH_CURRENT_TODO_HASH \
    RALPH_PLAN_INVOCATION_REASON RALPH_RUN_PLAN_RESUME_SESSION_ID \
    RALPH_WORKFLOW_OPERATOR_INPUT_CONTINUATION 2>/dev/null || true
}

wait_for_file() {
  local path="$1"
  local deadline=$(( $(date +%s) + 5 ))
  until [[ -e "$path" ]]; do
    [[ $(date +%s) -lt $deadline ]] || {
      echo "timed out waiting for $path" >&2
      return 1
    }
    sleep 0.05
  done
}

extract_schema() {
  local kind="$1" dest="$2"
  jq --arg k "$kind" '.[$k]' "$SCHEMA" >"$dest"
}

validate_fixture() {
  local kind="$1" fixture="$2"
  local schema_tmp
  schema_tmp="$TMPD/${kind}.schema.json"
  extract_schema "$kind" "$schema_tmp"
  python3 "$ARTIFACT_SCHEMA_PY" validate-final-output \
    --schema "$schema_tmp" \
    --artifact "$fixture"
}

permission_request_json() {
  jq -nc \
    --arg requestId "${1:-perm-001}" \
    '{
      requestId: $requestId,
      kind: "permission",
      runId: "run-001",
      stageId: "impl",
      attemptId: "impl-1",
      choices: ["allow-once","allow-run","allow-always","deny"],
      createdAt: "2026-08-26T12:00:00Z",
      question: "needs write access",
      action: "Bash",
      resource: "src/app.ts",
      effect: "write",
      runtime: "cursor",
      namespace: "ns",
      expiresAt: "2026-08-26T13:00:00Z",
      nonce: "aabbccddeeff00112233445566778899"
    }'
}

approval_request_json() {
  jq -nc \
    --arg requestId "${1:-appr-001}" \
    '{
      requestId: $requestId,
      kind: "approval",
      runId: "run-001",
      stageId: "approve-plan",
      attemptId: "approve-plan-1",
      choices: ["approve","request-changes","cancel"],
      createdAt: "2026-08-26T12:00:00Z",
      question: "Approve the implementation plan?",
      changesTarget: "plan-implementation",
      evidence: [
        {path: "/tmp/project/.ralph-workspace/artifacts/ns/plan.json", sha256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
      ]
    }'
}

input_request_json() {
  jq -nc \
    --arg requestId "${1:-inp-001}" \
    '{
      requestId: $requestId,
      kind: "input",
      runId: "run-001",
      stageId: "implement",
      attemptId: "implement-1",
      choices: ["answer","cancel"],
      createdAt: "2026-08-26T12:00:00Z",
      question: "Which API base URL should the client use?",
      details: "Choose staging or production config name only."
    }'
}

# --- schema ---

@test "schema rejects unknown keys on request decision and consumed fixtures" {
  local f
  f="$TMPD/bad-request.json"
  cat >"$f" <<'EOF'
{
  "schemaVersion": 1,
  "requestId": "perm-001",
  "kind": "permission",
  "runId": "run-001",
  "stageId": "impl",
  "attemptId": "impl-1",
  "choices": ["allow-once","allow-run","allow-always","deny"],
  "createdAt": "2026-08-26T12:00:00Z",
  "extraField": true
}
EOF
  run validate_fixture request "$f"
  [ "$status" -ne 0 ]

  cat >"$f" <<'EOF'
{
  "schemaVersion": 1,
  "requestId": "appr-001",
  "kind": "approval",
  "runId": "run-001",
  "stageId": "approve-plan",
  "attemptId": "approve-plan-1",
  "decision": "approve",
  "actorSource": "human",
  "decidedAt": "2026-08-26T12:00:00Z",
  "message": null,
  "unknownKey": true
}
EOF
  run validate_fixture decision "$f"
  [ "$status" -ne 0 ]

  cat >"$f" <<'EOF'
{
  "schemaVersion": 1,
  "requestId": "inp-001",
  "kind": "input",
  "runId": "run-001",
  "stageId": "implement",
  "attemptId": "implement-1",
  "decision": "answer",
  "consumedAt": "2026-08-26T12:00:00Z",
  "consumer": "resume",
  "extra": "nope"
}
EOF
  run validate_fixture consumed "$f"
  [ "$status" -ne 0 ]
}

@test "schema accepts valid permission approval and input request fixtures" {
  local f
  f="$TMPD/ok.json"
  # Permission after write (includes schemaVersion)
  path="$(workflow_action_request_write "$RUN_DIR" "$(permission_request_json)")"
  cp "$path" "$f"
  run validate_fixture request "$f"
  [ "$status" -eq 0 ]

  path="$(workflow_action_request_write "$RUN_DIR" "$(approval_request_json)")"
  cp "$path" "$f"
  run validate_fixture request "$f"
  [ "$status" -eq 0 ]

  path="$(workflow_action_request_write "$RUN_DIR" "$(input_request_json)")"
  cp "$path" "$f"
  run validate_fixture request "$f"
  [ "$status" -eq 0 ]
}

# --- kind choices / message required ---

@test "permission approval and input kinds enforce exact choices enums" {
  run workflow_action_request_write "$RUN_DIR" "$(permission_request_json | jq -c '.choices = ["allow-once","deny"]')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing required choice"* || "$output" == *"malformed workflow action choice"* ]]

  run workflow_action_request_write "$RUN_DIR" "$(approval_request_json | jq -c '.choices = ["approve","cancel","yolo"]')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"malformed workflow action choice"* ]]

  run workflow_action_request_write "$RUN_DIR" "$(input_request_json | jq -c '.choices = ["answer"]')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing required choice"* ]]
}

@test "approval request-changes and input answer require non-empty message" {
  workflow_action_request_write "$RUN_DIR" "$(approval_request_json)" >/dev/null
  run workflow_action_decision_write "$RUN_DIR" "$(jq -nc '{
    requestId:"appr-001", kind:"approval", runId:"run-001", stageId:"approve-plan",
    attemptId:"approve-plan-1", decision:"request-changes", actorSource:"human",
    decidedAt:"2026-08-26T12:00:00Z", message:null
  }')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"message"* ]]

  workflow_action_request_write "$RUN_DIR" "$(input_request_json)" >/dev/null
  run workflow_action_decision_write "$RUN_DIR" "$(jq -nc '{
    requestId:"inp-001", kind:"input", runId:"run-001", stageId:"implement",
    attemptId:"implement-1", decision:"answer", actorSource:"cli",
    decidedAt:"2026-08-26T12:00:00Z", message:""
  }')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"message"* || "$output" == *"non-empty"* ]]
}

@test "approval approve and input cancel do not require message" {
  local path
  workflow_action_request_write "$RUN_DIR" "$(approval_request_json)" >/dev/null
  path="$(workflow_action_decision_write "$RUN_DIR" "$(jq -nc '{
    requestId:"appr-001", kind:"approval", runId:"run-001", stageId:"approve-plan",
    attemptId:"approve-plan-1", decision:"approve", actorSource:"human",
    decidedAt:"2026-08-26T12:00:00Z"
  }')")"
  [ "$(jq -r '.decision' "$path")" = "approve" ]
  [ "$(jq -r '.message' "$path")" = "null" ]

  workflow_action_request_write "$RUN_DIR" "$(input_request_json)" >/dev/null
  path="$(workflow_action_decision_write "$RUN_DIR" "$(jq -nc '{
    requestId:"inp-001", kind:"input", runId:"run-001", stageId:"implement",
    attemptId:"implement-1", decision:"cancel", actorSource:"human",
    decidedAt:"2026-08-26T12:00:00Z"
  }')")"
  [ "$(jq -r '.decision' "$path")" = "cancel" ]
}

# --- create once / read / list ---

@test "create once request write under actions/requests with identity tuple" {
  local path
  path="$(workflow_action_request_write "$RUN_DIR" "$(input_request_json)")"
  [[ "$path" == */actions/requests/inp-001.json ]]
  [ "$(jq -r '.schemaVersion' "$path")" = "1" ]
  [ "$(jq -r '.kind' "$path")" = "input" ]
  [ "$(jq -r '.runId' "$path")" = "run-001" ]
  [ "$(jq -r '.stageId' "$path")" = "implement" ]
  [ "$(jq -r '.attemptId' "$path")" = "implement-1" ]
  [ "$(jq -c '.choices' "$path")" = '["answer","cancel"]' ]
  # Input must not persist nonce
  [ "$(jq -r 'has("nonce")' "$path")" = "false" ]

  run workflow_action_request_write "$RUN_DIR" "$(input_request_json)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]]

  run workflow_action_request_read "$RUN_DIR" "inp-001"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.question')" = "Which API base URL should the client use?" ]
}

@test "permission request stores nonce and required permission fields" {
  local path
  path="$(workflow_action_request_write "$RUN_DIR" "$(permission_request_json)")"
  [[ "$path" == */actions/requests/perm-001.json ]]
  [ "$(jq -r '.nonce' "$path")" = "aabbccddeeff00112233445566778899" ]
  [ "$(jq -r '.action' "$path")" = "Bash" ]
  [ "$(jq -r '.effect' "$path")" = "write" ]
  [ "$(jq -r '.runtime' "$path")" = "cursor" ]
}

@test "list returns normalized array across permission approval and input kinds" {
  workflow_action_request_write "$RUN_DIR" "$(permission_request_json)" >/dev/null
  workflow_action_request_write "$RUN_DIR" "$(approval_request_json)" >/dev/null
  workflow_action_request_write "$RUN_DIR" "$(input_request_json)" >/dev/null
  run workflow_action_list "$RUN_DIR"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq 'length')" = "3" ]
  [ "$(printf '%s' "$output" | jq -r 'map(.kind) | sort | join(",")')" = "approval,input,permission" ]
}

# --- decisions: replay / conflict / consume once ---

@test "identical decision replay is safe and conflict refusal preserves bytes" {
  local path before after
  workflow_action_request_write "$RUN_DIR" "$(approval_request_json)" >/dev/null
  path="$(workflow_action_decision_write "$RUN_DIR" "$(jq -nc '{
    requestId:"appr-001", kind:"approval", runId:"run-001", stageId:"approve-plan",
    attemptId:"approve-plan-1", decision:"approve", actorSource:"human",
    decidedAt:"2026-08-26T12:00:00Z"
  }')")"
  before="$(shasum "$path" | awk '{print $1}')"

  run workflow_action_decision_write "$RUN_DIR" "$(jq -nc '{
    requestId:"appr-001", kind:"approval", runId:"run-001", stageId:"approve-plan",
    attemptId:"approve-plan-1", decision:"approve", actorSource:"human",
    decidedAt:"2026-08-26T12:00:00Z"
  }')"
  [ "$status" -eq 0 ]
  after="$(shasum "$path" | awk '{print $1}')"
  [ "$before" = "$after" ]

  run workflow_action_decision_write "$RUN_DIR" "$(jq -nc '{
    requestId:"appr-001", kind:"approval", runId:"run-001", stageId:"approve-plan",
    attemptId:"approve-plan-1", decision:"cancel", actorSource:"human",
    decidedAt:"2026-08-26T12:00:00Z"
  }')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"conflicts"* || "$output" == *"already resolved"* ]]
  after="$(shasum "$path" | awk '{print $1}')"
  [ "$before" = "$after" ]
}

@test "consume once refuses a second consumption" {
  local path
  workflow_action_request_write "$RUN_DIR" "$(input_request_json)" >/dev/null
  workflow_action_decision_write "$RUN_DIR" "$(jq -nc '{
    requestId:"inp-001", kind:"input", runId:"run-001", stageId:"implement",
    attemptId:"implement-1", decision:"answer", actorSource:"human",
    decidedAt:"2026-08-26T12:00:00Z", message:"Use the staging config name."
  }')" >/dev/null

  path="$(workflow_action_consume_once "$RUN_DIR" "inp-001" resume)"
  [[ "$path" == */actions/consumed/inp-001.json ]]
  [ "$(jq -r '.consumer' "$path")" = "resume" ]
  [ "$(jq -r '.decision' "$path")" = "answer" ]

  run workflow_action_consume_once "$RUN_DIR" "inp-001" resume
  [ "$status" -ne 0 ]
  [[ "$output" == *"already consumed"* ]]
}

# --- credential rejection / redaction ---

@test "credential rejection refuses secret literals in question details and message" {
  run workflow_action_request_write "$RUN_DIR" "$(input_request_json | jq -c '.question = "password=hunter2"')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"credential-looking"* ]]
  [[ "$output" == *"environment or native secret"* ]]
  [ ! -e "$RUN_DIR/actions/requests/inp-001.json" ]

  run workflow_action_request_write "$RUN_DIR" "$(input_request_json | jq -c '.details = "token=sk-abc123456789"')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"credential-looking"* ]]

  workflow_action_request_write "$RUN_DIR" "$(input_request_json)" >/dev/null
  run workflow_action_decision_write "$RUN_DIR" "$(jq -nc '{
    requestId:"inp-001", kind:"input", runId:"run-001", stageId:"implement",
    attemptId:"implement-1", decision:"answer", actorSource:"human",
    decidedAt:"2026-08-26T12:00:00Z", message:"api_key=abcd1234"
  }')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"credential-looking"* ]]
  [ ! -e "$RUN_DIR/actions/decisions/inp-001.json" ]
}

@test "display redaction is defense in depth and does not authorize storage" {
  local redacted
  redacted="$(workflow_action_redact_for_display 'token=sk-secretvalue123')"
  [ "$redacted" = "[REDACTED]" ]

  # Storage still rejects the same pattern.
  run workflow_action_request_write "$RUN_DIR" "$(approval_request_json | jq -c '.question = "token=sk-secretvalue123"')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"credential-looking"* ]]
}

# --- path traversal / symlink ---

@test "input request id path traversal is refused" {
  run workflow_action_request_write "$RUN_DIR" "$(input_request_json '../escape')"
  [ "$status" -ne 0 ]
  [ ! -e "$TMPD/escape.json" ]
  [ ! -e "$RUN_DIR/actions/requests/../escape.json" ]

  run workflow_action_request_path "$RUN_DIR" '..'
  [ "$status" -ne 0 ]
}

@test "symlink escape from registry run is refused" {
  local outside
  outside="$TMPD/outside"
  mkdir -p "$outside"
  ln -s "$outside" "$RUN_DIR/actions"
  run workflow_action_request_write "$RUN_DIR" "$(input_request_json)"
  [ "$status" -ne 0 ]
  [ ! -e "$outside/requests/inp-001.json" ]
}

@test "leaf symlink at request path is refused" {
  mkdir -p "$RUN_DIR/actions/requests"
  ln -s "$TMPD/stolen.json" "$RUN_DIR/actions/requests/inp-001.json"
  printf 'secret\n' >"$TMPD/stolen.json"
  run workflow_action_request_write "$RUN_DIR" "$(input_request_json)"
  [ "$status" -ne 0 ]
  [ "$(cat "$TMPD/stolen.json")" = "secret" ]
}

# --- concurrent create with barriers ---

@test "concurrent create once request writers yield exactly one record" {
  local barrier go ready1 ready2 out1 out2 rc1 rc2
  barrier="$(mktemp -d "$TMPD/barrier.XXXXXX")"
  go="$barrier/go"
  ready1="$barrier/ready1"
  ready2="$barrier/ready2"
  out1="$barrier/out1"
  out2="$barrier/out2"
  json="$(input_request_json)"

  (
    # shellcheck source=/dev/null
    source "$ACTIONS_LIB"
    touch "$ready1"
    wait_for_file "$go"
    set +e
    workflow_action_request_write "$RUN_DIR" "$json" >"$out1" 2>"$barrier/err1"
    echo $? >"$barrier/rc1"
  ) &
  (
    # shellcheck source=/dev/null
    source "$ACTIONS_LIB"
    touch "$ready2"
    wait_for_file "$go"
    set +e
    workflow_action_request_write "$RUN_DIR" "$json" >"$out2" 2>"$barrier/err2"
    echo $? >"$barrier/rc2"
  ) &

  wait_for_file "$ready1"
  wait_for_file "$ready2"
  touch "$go"
  wait

  rc1="$(cat "$barrier/rc1")"
  rc2="$(cat "$barrier/rc2")"
  if [[ "$rc1" -eq 0 && "$rc2" -ne 0 ]]; then
    [[ "$(cat "$out1")" == */actions/requests/inp-001.json ]]
  elif [[ "$rc2" -eq 0 && "$rc1" -ne 0 ]]; then
    [[ "$(cat "$out2")" == */actions/requests/inp-001.json ]]
  else
    echo "expected one success and one create-once refusal, got rc1=$rc1 rc2=$rc2" >&2
    return 1
  fi
  [ "$(find "$RUN_DIR/actions/requests" -name '*.json' | wc -l | tr -d ' ')" = "1" ]
}

@test "graph operator create-once and nonce helpers remain compatible for permission" {
  # Preserve internal graph permission surface by exercising shared primitives
  # still exported from graph-operator-records via the workflow wrapper load.
  run graph_operator_request_id_valid "req-ok"
  [ "$status" -eq 0 ]
  run graph_operator_nonce_valid "aabbccddeeff00112233445566778899"
  [ "$status" -eq 0 ]
  run graph_operator_text_looks_like_credential "password=secret"
  [ "$status" -eq 0 ]
  run graph_operator_text_looks_like_credential "ordinary question text"
  [ "$status" -ne 0 ]
}

# --- Dependency approval evidence / blocker / waiting helpers ---

@test "Dependency approval evidence freeze and verify fail closed on missing or mutated evidence" {
  local ev_path abs evidence
  mkdir -p "$TMPD/ws/.ralph-workspace/artifacts/ns"
  ev_path="$TMPD/ws/.ralph-workspace/artifacts/ns/plan.json"
  printf 'plan-body\n' >"$ev_path"

  evidence="$(workflow_action_freeze_evidence "$TMPD/ws" "ns" \
    '[{"path":".ralph-workspace/artifacts/{{ARTIFACT_NS}}/plan.json","required":true}]')"
  [ "$(printf '%s' "$evidence" | jq 'length')" = "1" ]
  abs="$(printf '%s' "$evidence" | jq -r '.[0].path')"
  [[ "$abs" == "$ev_path" || "$abs" == "$(cd "$TMPD/ws" && pwd)/.ralph-workspace/artifacts/ns/plan.json" ]]
  workflow_action_verify_evidence "$evidence"

  printf 'mutated\n' >"$ev_path"
  run workflow_action_verify_evidence "$evidence"
  [ "$status" -ne 0 ]
  [[ "$output" == *"mutated"* || "$output" == *"mismatched"* ]]

  run workflow_action_freeze_evidence "$TMPD/ws" "ns" \
    '[{"path":".ralph-workspace/artifacts/{{ARTIFACT_NS}}/missing.json","required":true}]'
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing"* ]]
}

@test "Dependency approval blocker carries waiting list argv and changesTarget reset argv" {
  local blocker
  blocker="$(workflow_action_approval_blocker_json \
    --request-id appr-001 --run-id run-001 --reason-code human-approval \
    --retryable false --changes-target plan-implementation --mode list)"
  [ "$(printf '%s' "$blocker" | jq -r '.kind')" = "approval" ]
  [ "$(printf '%s' "$blocker" | jq -r '.reasonCode')" = "human-approval" ]
  [ "$(printf '%s' "$blocker" | jq -c '.action.argv')" = '["ralph","workflow","actions","list","run-001"]' ]

  blocker="$(workflow_action_approval_blocker_json \
    --request-id appr-001 --run-id run-001 --reason-code human-changes-requested \
    --retryable false --changes-target plan-implementation --mode reset)"
  [ "$(printf '%s' "$blocker" | jq -r '.reasonCode')" = "human-changes-requested" ]
  [ "$(printf '%s' "$blocker" | jq -c '.action.argv')" = '["ralph","workflow","reset","run-001","--stage","plan-implementation"]' ]
  [ "$(printf '%s' "$blocker" | jq -r '.changesTarget')" = "plan-implementation" ]
}

@test "Dependency approval request-changes cancel and approve classify for resume" {
  local path evidence
  mkdir -p "$TMPD/ws/.ralph-workspace/artifacts/ns"
  printf 'body\n' >"$TMPD/ws/.ralph-workspace/artifacts/ns/plan.json"
  evidence="$(workflow_action_freeze_evidence "$TMPD/ws" "ns" \
    '[".ralph-workspace/artifacts/{{ARTIFACT_NS}}/plan.json"]')"

  path="$(workflow_action_request_write "$RUN_DIR" "$(jq -nc \
    --argjson evidence "$evidence" \
    '{
      requestId:"appr-dep-001", kind:"approval", runId:"run-001",
      stageId:"approve-plan", attemptId:"approve-plan-1",
      choices:["approve","request-changes","cancel"],
      createdAt:"2026-08-26T12:00:00Z",
      question:"Approve the plan?",
      changesTarget:"plan-implementation",
      evidence:$evidence
    }')")"
  [[ "$path" == */actions/requests/appr-dep-001.json ]]

  [ "$(workflow_action_classify_for_resume "$RUN_DIR" "appr-dep-001")" = "unresolved" ]

  workflow_action_decision_write "$RUN_DIR" "$(jq -nc '{
    requestId:"appr-dep-001", kind:"approval", runId:"run-001", stageId:"approve-plan",
    attemptId:"approve-plan-1", decision:"approve", actorSource:"human",
    decidedAt:"2026-08-26T12:00:00Z"
  }')" >/dev/null
  [ "$(workflow_action_classify_for_resume "$RUN_DIR" "appr-dep-001")" = "ready-approval" ]

  # Consume once, then refuse a second consume.
  workflow_action_consume_once "$RUN_DIR" "appr-dep-001" resume >/dev/null
  [ "$(workflow_action_classify_for_resume "$RUN_DIR" "appr-dep-001")" = "already-consumed" ]
  run workflow_action_consume_once "$RUN_DIR" "appr-dep-001" resume
  [ "$status" -ne 0 ]
}

# --- Sequential approval shares common action evidence / blocker semantics ---

@test "Sequential approval evidence freeze and waiting list argv match Dependency" {
  local ev_path evidence blocker
  mkdir -p "$TMPD/ws/.ralph-workspace/artifacts/ns"
  ev_path="$TMPD/ws/.ralph-workspace/artifacts/ns/plan.json"
  printf 'plan-body\n' >"$ev_path"

  evidence="$(workflow_action_freeze_evidence "$TMPD/ws" "ns" \
    '[{"path":".ralph-workspace/artifacts/{{ARTIFACT_NS}}/plan.json","required":true}]')"
  [ "$(printf '%s' "$evidence" | jq 'length')" = "1" ]
  workflow_action_verify_evidence "$evidence"

  blocker="$(workflow_action_approval_blocker_json \
    --request-id appr-seq-001 --run-id run-seq-001 --reason-code human-approval \
    --retryable false --changes-target investigate --mode list)"
  [ "$(printf '%s' "$blocker" | jq -r '.kind')" = "approval" ]
  [ "$(printf '%s' "$blocker" | jq -c '.action.argv')" = '["ralph","workflow","actions","list","run-seq-001"]' ]

  blocker="$(workflow_action_approval_blocker_json \
    --request-id appr-seq-001 --run-id run-seq-001 --reason-code human-changes-requested \
    --retryable false --changes-target investigate --mode reset)"
  [ "$(printf '%s' "$blocker" | jq -c '.action.argv')" = '["ralph","workflow","reset","run-seq-001","--stage","investigate"]' ]
  [ "$(printf '%s' "$blocker" | jq -r '.changesTarget')" = "investigate" ]
}

@test "Sequential approval request-changes cancel and approve classify for resume consume once" {
  local path evidence
  mkdir -p "$TMPD/ws/.ralph-workspace/artifacts/ns"
  printf 'body\n' >"$TMPD/ws/.ralph-workspace/artifacts/ns/plan.json"
  evidence="$(workflow_action_freeze_evidence "$TMPD/ws" "ns" \
    '[".ralph-workspace/artifacts/{{ARTIFACT_NS}}/plan.json"]')"

  path="$(workflow_action_request_write "$RUN_DIR" "$(jq -nc \
    --argjson evidence "$evidence" \
    '{
      requestId:"appr-seq-001", kind:"approval", runId:"run-001",
      stageId:"approve-plan", attemptId:"approve-plan-1",
      choices:["approve","request-changes","cancel"],
      createdAt:"2026-08-26T12:00:00Z",
      question:"Approve the plan?",
      changesTarget:"investigate",
      evidence:$evidence
    }')")"
  [[ "$path" == */actions/requests/appr-seq-001.json ]]
  [ "$(workflow_action_classify_for_resume "$RUN_DIR" "appr-seq-001")" = "unresolved" ]

  workflow_action_decision_write "$RUN_DIR" "$(jq -nc '{
    requestId:"appr-seq-001", kind:"approval", runId:"run-001", stageId:"approve-plan",
    attemptId:"approve-plan-1", decision:"approve", actorSource:"human",
    decidedAt:"2026-08-26T12:00:00Z"
  }')" >/dev/null
  [ "$(workflow_action_classify_for_resume "$RUN_DIR" "appr-seq-001")" = "ready-approval" ]

  workflow_action_consume_once "$RUN_DIR" "appr-seq-001" resume >/dev/null
  [ "$(workflow_action_classify_for_resume "$RUN_DIR" "appr-seq-001")" = "already-consumed" ]
  run workflow_action_consume_once "$RUN_DIR" "appr-seq-001" resume
  [ "$status" -ne 0 ]
}


# --- Public action shapes: list / respond / stage request / capability ---

@test "actions list merges common records without namespace field" {
  workflow_action_request_write "$RUN_DIR" "$(approval_request_json)" >/dev/null
  workflow_action_request_write "$RUN_DIR" "$(input_request_json)" >/dev/null
  run workflow_action_list_public "$RUN_DIR" "run-001" "sequential" ""
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq 'length')" = "2" ]
  [ "$(printf '%s' "$output" | jq 'map(has("namespace")) | any')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r 'map(.kind) | sort | join(",")')" = "approval,input" ]
}

@test "merged permission rows adapt Dependency graph operator requests without namespace" {
  local graph_dir="$TMPD/graph-run"
  mkdir -p "$graph_dir"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-operator-records.sh"
  export GRAPH_OPERATOR_NOW="2026-08-26T12:00:00Z"
  graph_operator_request_write "$graph_dir" "$(jq -nc '{
    requestId:"perm-graph-001",
    nonce:"aabbccddeeff00112233445566778899",
    namespace:"hidden-ns",
    runId:"run-001",
    nodeId:"impl",
    attemptId:"impl-1",
    runtime:"cursor",
    sessionId:"sess-1",
    classification:"operator-permission",
    action:"Bash",
    resource:"src/app.ts",
    effect:"write",
    reason:"needs write",
    choices:["allow-once","allow-run","allow-always","deny"],
    createdAt:"2026-08-26T12:00:00Z",
    expiresAt:"2026-08-26T13:00:00Z"
  }')" >/dev/null

  workflow_action_request_write "$RUN_DIR" "$(approval_request_json)" >/dev/null
  run workflow_action_list_public "$RUN_DIR" "run-001" "dependency" "$graph_dir"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq 'length')" = "2" ]
  [ "$(printf '%s' "$output" | jq 'map(has("namespace")) | any')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '[.[] | select(.kind=="permission")][0].requestId')" = "perm-graph-001" ]
  [ "$(printf '%s' "$output" | jq -r '[.[] | select(.kind=="permission")][0].source')" = "graph-permission" ]
}

@test "Sequential list ignores graph permission adaptation" {
  local graph_dir="$TMPD/graph-run-seq"
  mkdir -p "$graph_dir"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-operator-records.sh"
  export GRAPH_OPERATOR_NOW="2026-08-26T12:00:00Z"
  graph_operator_request_write "$graph_dir" "$(jq -nc '{
    requestId:"perm-ignored",
    nonce:"aabbccddeeff00112233445566778899",
    namespace:"hidden-ns",
    runId:"run-001",
    nodeId:"impl",
    attemptId:"impl-1",
    runtime:"cursor",
    sessionId:"sess-1",
    classification:"operator-permission",
    action:"Bash",
    resource:"src/app.ts",
    effect:"write",
    reason:"needs write",
    choices:["allow-once","allow-run","allow-always","deny"],
    createdAt:"2026-08-26T12:00:00Z",
    expiresAt:"2026-08-26T13:00:00Z"
  }')" >/dev/null
  workflow_action_request_write "$RUN_DIR" "$(input_request_json)" >/dev/null
  run workflow_action_list_public "$RUN_DIR" "run-001" "sequential" "$graph_dir"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq 'length')" = "1" ]
  [ "$(printf '%s' "$output" | jq -r '.[0].kind')" = "input" ]
}

@test "actions respond persists decision and prints resume next action for approve" {
  workflow_action_request_write "$RUN_DIR" "$(approval_request_json)" >/dev/null
  run workflow_action_respond_persist \
    --registry-run "$RUN_DIR" --run-id run-001 --request-id appr-001 \
    --decision approve --mode sequential
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.decision')" = "approve" ]
  [ "$(printf '%s' "$output" | jq -r '.nextAction.argv | join(" ")')" = "ralph workflow resume run-001" ]
  [ -f "$RUN_DIR/actions/decisions/appr-001.json" ]
}

@test "actions respond request-changes requires message and reset changesTarget next action" {
  workflow_action_request_write "$RUN_DIR" "$(approval_request_json)" >/dev/null
  run workflow_action_respond_persist \
    --registry-run "$RUN_DIR" --run-id run-001 --request-id appr-001 \
    --decision request-changes --mode sequential
  [ "$status" -ne 0 ]

  run workflow_action_respond_persist \
    --registry-run "$RUN_DIR" --run-id run-001 --request-id appr-001 \
    --decision request-changes --message "tighten acceptance" --mode sequential
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.changesTarget')" = "plan-implementation" ]
  [ "$(printf '%s' "$output" | jq -r '.nextAction.argv | join(" ")')" = "ralph workflow reset run-001 --stage plan-implementation" ]
}

@test "request kind decision enum rejects wrong choice for approval" {
  workflow_action_request_write "$RUN_DIR" "$(approval_request_json)" >/dev/null
  run workflow_action_respond_persist \
    --registry-run "$RUN_DIR" --run-id run-001 --request-id appr-001 \
    --decision allow-once --mode sequential
  [ "$status" -ne 0 ]
  [[ "$output" == *"malformed"* || "$output" == *"choice"* || "$output" == *"decision"* ]]
}

@test "stage request capability nonce validates and never persists nonce" {
  local nonce="aabbccddeeff00112233445566778899" path
  path="$(workflow_action_capability_write "$RUN_DIR" "run-001" "implement" "implement-1" "$nonce")"
  [[ "$path" == */actions/capabilities/* ]]
  # Capability file has nonce; request must not.
  [ "$(jq -r '.nonce' "$path")" = "$nonce" ]

  run workflow_action_stage_request_create \
    --registry-run "$RUN_DIR" --run-id run-001 --stage-id implement \
    --attempt-id implement-1 --nonce "$nonce" \
    --question "Which staging config name should we use?"
  [ "$status" -eq 0 ]
  local rid="$output"
  [ -f "$RUN_DIR/actions/requests/${rid}.json" ]
  [ "$(jq -r 'has("nonce")' "$RUN_DIR/actions/requests/${rid}.json")" = "false" ]
  [ "$(jq -r '.kind' "$RUN_DIR/actions/requests/${rid}.json")" = "input" ]
}

@test "stage request refuses credential-bearing question" {
  local nonce="aabbccddeeff00112233445566778899"
  workflow_action_capability_write "$RUN_DIR" "run-001" "implement" "implement-1" "$nonce" >/dev/null
  run workflow_action_stage_request_create \
    --registry-run "$RUN_DIR" --run-id run-001 --stage-id implement \
    --attempt-id implement-1 --nonce "$nonce" \
    --question "password=hunter2"
  [ "$status" -ne 0 ]
  [[ "$output" == *"credential-looking"* ]]
}

@test "stale attempt capability nonce is refused" {
  local nonce="aabbccddeeff00112233445566778899"
  workflow_action_capability_write "$RUN_DIR" "run-001" "implement" "implement-1" "$nonce" >/dev/null
  run workflow_action_stage_request_create \
    --registry-run "$RUN_DIR" --run-id run-001 --stage-id implement \
    --attempt-id implement-2 --nonce "$nonce" \
    --question "Which API base URL?"
  [ "$status" -ne 0 ]
  [[ "$output" == *"stale"* || "$output" == *"missing"* || "$output" == *"does not match"* ]]
}

@test "spoof refusal rejects mismatched capability identity" {
  local nonce="aabbccddeeff00112233445566778899"
  workflow_action_capability_write "$RUN_DIR" "run-001" "implement" "implement-1" "$nonce" >/dev/null
  run workflow_action_stage_request_create \
    --registry-run "$RUN_DIR" --run-id run-OTHER --stage-id implement \
    --attempt-id implement-1 --nonce "$nonce" \
    --question "Which API base URL?"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not match"* || "$output" == *"spoof"* || "$output" == *"identity"* ]]
}

@test "stage request allows only one outstanding input per attempt" {
  local nonce="aabbccddeeff00112233445566778899"
  workflow_action_capability_write "$RUN_DIR" "run-001" "implement" "implement-1" "$nonce" >/dev/null
  workflow_action_stage_request_create \
    --registry-run "$RUN_DIR" --run-id run-001 --stage-id implement \
    --attempt-id implement-1 --nonce "$nonce" \
    --question "First question?" >/dev/null
  run workflow_action_stage_request_create \
    --registry-run "$RUN_DIR" --run-id run-001 --stage-id implement \
    --attempt-id implement-1 --nonce "$nonce" \
    --question "Second question?"
  [ "$status" -ne 0 ]
  [[ "$output" == *"at most one outstanding"* ]]
}

@test "common run ID mismatch refuses respond across runs" {
  workflow_action_request_write "$RUN_DIR" "$(input_request_json)" >/dev/null
  run workflow_action_respond_persist \
    --registry-run "$RUN_DIR" --run-id run-OTHER --request-id inp-001 \
    --decision answer --message "use staging" --mode sequential
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not belong"* || "$output" == *"not found"* ]]
}

# --- OPERATOR_INPUT protocol / request pauses / exit 3 / answer injection ---

@test "OPERATOR_INPUT protocol block never includes nonce content" {
  block="$(workflow_action_operator_input_protocol_block)"
  [[ "$block" == *"<!-- OPERATOR_INPUT: START -->"* ]]
  [[ "$block" == *"<!-- OPERATOR_INPUT: END -->"* ]]
  [[ "$block" == *"ralph workflow actions request --question"* ]]
  ! printf '%s' "$block" | grep -qiE '\bnonce\b'
}

@test "prepare attempt capability exports identity and path without printing nonce" {
  # Call in-shell without command substitution so exports persist.
  local path_file="$TMPD/cap-path.txt" path
  workflow_action_prepare_attempt_capability_env \
    --registry-run "$RUN_DIR" --run-id run-001 --stage-id implement --attempt-id implement-1 >"$path_file"
  path="$(cat "$path_file")"
  [[ "$path" == */actions/capabilities/* ]]
  [ "$RALPH_WORKFLOW_RUN_ID" = "run-001" ]
  [ "$RALPH_WORKFLOW_STAGE_ID" = "implement" ]
  [ "$RALPH_WORKFLOW_STAGE_ATTEMPT" = "implement-1" ]
  [ -f "$RALPH_WORKFLOW_ACTION_CAPABILITY" ]
  [ -n "$RALPH_WORKFLOW_ACTION_NONCE" ]
  ! printf '%s' "$path" | grep -Fq "$RALPH_WORKFLOW_ACTION_NONCE"
}

@test "request pauses stage: outstanding input blocks success and cleanup revokes capability" {
  local nonce="aabbccddeeff00112233445566778899" path rid
  path="$(workflow_action_capability_write "$RUN_DIR" "run-001" "implement" "implement-1" "$nonce")"
  rid="$(workflow_action_stage_request_create \
    --registry-run "$RUN_DIR" --run-id run-001 --stage-id implement \
    --attempt-id implement-1 --nonce "$nonce" \
    --question "Which staging config name?")"
  [ -n "$rid" ]
  workflow_action_attempt_blocks_success "$RUN_DIR" run-001 implement implement-1
  [ "$(workflow_action_count_outstanding_input "$RUN_DIR" run-001 implement implement-1)" = "1" ]
  workflow_action_revoke_attempt_capability "$RUN_DIR" run-001 implement implement-1
  [ ! -f "$path" ]
}

@test "completion refused while answered-unconsumed input remains" {
  local nonce="aabbccddeeff00112233445566778899" rid
  workflow_action_capability_write "$RUN_DIR" "run-001" "implement" "implement-1" "$nonce" >/dev/null
  rid="$(workflow_action_stage_request_create \
    --registry-run "$RUN_DIR" --run-id run-001 --stage-id implement \
    --attempt-id implement-1 --nonce "$nonce" \
    --question "Pick a base URL")"
  workflow_action_decision_write "$RUN_DIR" "$(jq -nc \
    --arg rid "$rid" \
    '{requestId:$rid,kind:"input",runId:"run-001",stageId:"implement",attemptId:"implement-1",decision:"answer",message:"https://api.example",actorSource:"human",decidedAt:"2026-08-26T12:00:00Z"}')" >/dev/null
  workflow_action_attempt_blocks_success "$RUN_DIR" run-001 implement implement-1
  [ "$(workflow_action_count_answered_unconsumed_input "$RUN_DIR" run-001 implement implement-1)" = "1" ]
}

@test "answer injection OPERATOR_INPUT_RESPONSE includes request ID question and answer" {
  local nonce="aabbccddeeff00112233445566778899" rid inj
  workflow_action_capability_write "$RUN_DIR" "run-001" "implement" "implement-1" "$nonce" >/dev/null
  rid="$(workflow_action_stage_request_create \
    --registry-run "$RUN_DIR" --run-id run-001 --stage-id implement \
    --attempt-id implement-1 --nonce "$nonce" \
    --question "Which API base URL?")"
  workflow_action_decision_write "$RUN_DIR" "$(jq -nc \
    --arg rid "$rid" \
    '{requestId:$rid,kind:"input",runId:"run-001",stageId:"implement",attemptId:"implement-1",decision:"answer",message:"https://staging.example",actorSource:"human",decidedAt:"2026-08-26T12:00:00Z"}')" >/dev/null
  inj="$(workflow_action_stage_input_injection "$RUN_DIR" "$rid" --todo-id work-todo)"
  [[ "$inj" == */actions/injections/* ]]
  grep -q 'OPERATOR_INPUT_RESPONSE: START' "$inj"
  grep -q "requestId: ${rid}" "$inj"
  grep -q 'question: Which API base URL?' "$inj"
  grep -q 'https://staging.example' "$inj"
  ! grep -qiE '\bnonce\b' "$inj"
}

@test "consume once after answer injection clears success block for fresh invocation" {
  local nonce="aabbccddeeff00112233445566778899" rid
  workflow_action_capability_write "$RUN_DIR" "run-001" "implement" "implement-1" "$nonce" >/dev/null
  rid="$(workflow_action_stage_request_create \
    --registry-run "$RUN_DIR" --run-id run-001 --stage-id implement \
    --attempt-id implement-1 --nonce "$nonce" \
    --question "Choose deploy target")"
  workflow_action_decision_write "$RUN_DIR" "$(jq -nc \
    --arg rid "$rid" \
    '{requestId:$rid,kind:"input",runId:"run-001",stageId:"implement",attemptId:"implement-1",decision:"answer",message:"canary",actorSource:"human",decidedAt:"2026-08-26T12:00:00Z"}')" >/dev/null
  workflow_action_stage_input_injection "$RUN_DIR" "$rid" --todo-id work >/dev/null
  workflow_action_attempt_blocks_success "$RUN_DIR" run-001 implement implement-1
  workflow_action_consume_once "$RUN_DIR" "$rid" resume >/dev/null
  ! workflow_action_attempt_blocks_success "$RUN_DIR" run-001 implement implement-1
}

@test "fresh invocation gets new capability after consume once" {
  local nonce="aabbccddeeff00112233445566778899" rid path2
  workflow_action_capability_write "$RUN_DIR" "run-001" "implement" "implement-1" "$nonce" >/dev/null
  rid="$(workflow_action_stage_request_create \
    --registry-run "$RUN_DIR" --run-id run-001 --stage-id implement \
    --attempt-id implement-1 --nonce "$nonce" \
    --question "Choose deploy target")"
  workflow_action_decision_write "$RUN_DIR" "$(jq -nc \
    --arg rid "$rid" \
    '{requestId:$rid,kind:"input",runId:"run-001",stageId:"implement",attemptId:"implement-1",decision:"answer",message:"canary",actorSource:"human",decidedAt:"2026-08-26T12:00:00Z"}')" >/dev/null
  workflow_action_consume_once "$RUN_DIR" "$rid" resume >/dev/null
  workflow_action_revoke_attempt_capability "$RUN_DIR" run-001 implement implement-1
  # Call without command substitution so exports apply to this shell.
  path2="$(workflow_action_capability_write "$RUN_DIR" "run-001" "implement" "implement-2")"
  [[ "$path2" == */actions/capabilities/* ]]
  [ -f "$path2" ]
  [ "$(jq -r '.attemptId' "$path2")" = "implement-2" ]
  [ "$(jq -r '.stageId' "$path2")" = "implement" ]
  # Fresh capability file must not reuse the revoked attempt-1 identity.
  [ ! -f "$(workflow_action_capability_path "$RUN_DIR" implement implement-1)" ]
}

@test "standalone unchanged: incomplete identity cannot create workflow requests" {
  run workflow_action_stage_request_create \
    --registry-run "$RUN_DIR" --run-id "" --stage-id implement \
    --attempt-id implement-1 --nonce aabbccddeeff00112233445566778899 \
    --question "Should not work"
  [ "$status" -ne 0 ]
  [[ "$output" == *"standalone"* || "$output" == *"incomplete"* || "$output" == *"requires"* ]]
}

@test "request pauses exit 3 gate helper returns waiting blocker JSON" {
  local blocker
  blocker="$(workflow_action_input_blocker_json --request-id inp-001 --run-id run-001 --retryable false)"
  [ "$(printf '%s' "$blocker" | jq -r '.kind')" = "input" ]
  [ "$(printf '%s' "$blocker" | jq -r '.reasonCode')" = "operator-input" ]
  [ "$(printf '%s' "$blocker" | jq -r '.retryable')" = "false" ]
  [ "$(printf '%s' "$blocker" | jq -r '.action.argv | join(" ")')" = "ralph workflow actions list run-001" ]
}

@test "cleanup clears capability env without leaking nonce" {
  local nonce="aabbccddeeff00112233445566778899"
  workflow_action_prepare_attempt_capability_env \
    --registry-run "$RUN_DIR" --run-id run-001 --stage-id implement --attempt-id implement-1 >/dev/null
  [ -n "${RALPH_WORKFLOW_ACTION_NONCE:-}" ]
  workflow_action_clear_attempt_capability_env
  [ -z "${RALPH_WORKFLOW_ACTION_NONCE:-}" ]
  [ -z "${RALPH_WORKFLOW_ACTION_CAPABILITY:-}" ]
}

# --- continuation identity through request/decision/consumption ---

SESSION_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-session.sh"
BG_JOB_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-bg-job-state.sh"
BG_TEARDOWN_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-bg-teardown.sh"

workflow_continuation_test_env() {
  export RALPH_SESSION_DIR="$TMPD/session"
  export RALPH_PLAN_WORKSPACE_ROOT="$TMPD/state"
  export RALPH_PROJECT_ROOT="$TMPD/project"
  export RALPH_PLAN_KEY="wf-plan"
  export RUNTIME="cursor"
  export RALPH_WORKFLOW_RUN_ID="run-001"
  export RALPH_WORKFLOW_STAGE_ID="implement"
  export RALPH_WORKFLOW_STAGE_ATTEMPT="implement-1"
  export RALPH_CURRENT_TODO_LINE="3"
  export RALPH_CURRENT_TODO_ID="work-todo"
  export RALPH_CURRENT_TODO_HASH="abc123"
  mkdir -p "$RALPH_SESSION_DIR/todo-sessions"
  # shellcheck source=/dev/null
  source "$SESSION_LIB"
}

@test "input request decision and consumed carry continuationIdentity" {
  workflow_continuation_test_env
  local nonce="aabbccddeeff00112233445566778899" rid path
  local control="$TMPD/control.plan.md"
  printf '# plan\n- [ ] work\n' >"$control"
  workflow_action_capability_write "$RUN_DIR" "run-001" "implement" "implement-1" "$nonce" >/dev/null
  rid="$(workflow_action_stage_request_create \
    --registry-run "$RUN_DIR" --run-id run-001 --stage-id implement \
    --attempt-id implement-1 --nonce "$nonce" \
    --control-plan "$control" --todo-id work-todo --runtime cursor \
    --question "Which API base URL?")"
  [ "$(jq -r '.continuationIdentity.controlPlanPath' "$RUN_DIR/actions/requests/${rid}.json")" = "$control" ]
  [ "$(jq -r '.continuationIdentity.todoId' "$RUN_DIR/actions/requests/${rid}.json")" = "work-todo" ]
  [ "$(jq -r '.continuationIdentity.runtime' "$RUN_DIR/actions/requests/${rid}.json")" = "cursor" ]
  workflow_action_decision_write "$RUN_DIR" "$(jq -nc \
    --arg rid "$rid" \
    '{requestId:$rid,kind:"input",runId:"run-001",stageId:"implement",attemptId:"implement-1",decision:"answer",message:"https://staging.example",actorSource:"human",decidedAt:"2026-08-26T12:00:00Z"}')" >/dev/null
  [ "$(jq -r '.continuationIdentity.todoId' "$RUN_DIR/actions/decisions/${rid}.json")" = "work-todo" ]
  path="$(workflow_action_consume_once "$RUN_DIR" "$rid" resume)"
  [ "$(jq -r '.continuationIdentity.runtime' "$path")" = "cursor" ]
  validate_fixture request "$RUN_DIR/actions/requests/${rid}.json"
  validate_fixture decision "$RUN_DIR/actions/decisions/${rid}.json"
  validate_fixture consumed "$path"
}

@test "answered input resume continuation applies exact session under fresh strategy" {
  workflow_continuation_test_env
  export RALPH_PLAN_SESSION_STRATEGY="fresh"
  local manifest_key session_id="sess-wf-attempt-1" continuation
  manifest_key="$(ralph_session_todo_manifest_key)"
  ralph_session_todo_create "$session_id" "exact" >/dev/null
  continuation="$(workflow_action_continuation_build --control-plan "$TMPD/c.plan.md" --todo-id work-todo --runtime cursor)"
  [ "$(jq -r '.session.session_id' <<<"$continuation")" = "$session_id" ]
  workflow_action_continuation_persist "$continuation" "operator-input-wait" >/dev/null
  ralph_session_todo_mark_terminal "$manifest_key" "$session_id" "exact" >/dev/null
  workflow_action_continuation_try_apply
  [ "${RALPH_PLAN_INVOCATION_REASON:-}" = "todo-continue" ]
  [ "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" = "$session_id" ]
}

@test "request-changes reset abandons prior attempt continuation and session" {
  workflow_continuation_test_env
  local continuation manifest_key
  export RALPH_WORKFLOW_STAGE_ATTEMPT="implement-1"
  continuation="$(workflow_action_continuation_build --todo-id work-todo --runtime cursor)"
  workflow_action_continuation_persist "$continuation" "operator-input-wait" >/dev/null
  manifest_key="$(ralph_session_todo_manifest_key)"
  ralph_session_todo_create "sess-old" "exact" >/dev/null
  workflow_action_continuation_abandon_stage_attempt run-001 implement implement-1 wf-plan cursor
  run workflow_action_continuation_find_pending
  [ "$status" -ne 0 ]
  run ralph_session_todo_read "$manifest_key" 1
  [[ "$status" -ne 0 || "$(jq -r '.state' <<<"$output")" = "retired" ]]
}

@test "answer injection rejects continuationIdentity from foreign attempt" {
  workflow_continuation_test_env
  local nonce="aabbccddeeff00112233445566778899" rid
  export RALPH_WORKFLOW_STAGE_ATTEMPT="implement-1"
  workflow_action_capability_write "$RUN_DIR" "run-001" "implement" "implement-1" "$nonce" >/dev/null
  rid="$(workflow_action_stage_request_create \
    --registry-run "$RUN_DIR" --run-id run-001 --stage-id implement \
    --attempt-id implement-1 --nonce "$nonce" \
    --question "Pick env")"
  workflow_action_decision_write "$RUN_DIR" "$(jq -nc \
    --arg rid "$rid" \
    '{requestId:$rid,kind:"input",runId:"run-001",stageId:"implement",attemptId:"implement-1",decision:"answer",message:"staging",actorSource:"human",decidedAt:"2026-08-26T12:00:00Z"}')" >/dev/null
  export RALPH_WORKFLOW_STAGE_ATTEMPT="implement-2"
  run workflow_action_stage_input_injection "$RUN_DIR" "$rid" --todo-id work-todo
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not match"* ]]
}

@test "background job does not leak across workflow stage attempt boundary" {
  workflow_continuation_test_env
  # shellcheck source=/dev/null
  source "$BG_JOB_LIB"
  # shellcheck source=/dev/null
  source "$BG_TEARDOWN_LIB"
  local old_key
  export RALPH_WORKFLOW_STAGE_ATTEMPT="implement-1"
  old_key="$(ralph_bg_job_attempt_key "$(ralph_bg_job_identity_json)")"
  ralph_bg_job_create "job-old-001" "sleep 9" "test" 60 1 99999 >/dev/null
  ralph_bg_job_mark_launched "job-old-001" 99998 99998 "setsid" 1 >/dev/null || true
  export RALPH_WORKFLOW_STAGE_ATTEMPT="implement-2"
  workflow_action_continuation_teardown_bg_jobs_for_stage_attempt run-001 implement implement-1
  record="$(ralph_bg_job_read_raw job-old-001)"
  [ "$(jq -r '.state' <<<"$record")" != "running" ]
  [ "$(jq -r '.state' <<<"$record")" != "launched" ]
}
