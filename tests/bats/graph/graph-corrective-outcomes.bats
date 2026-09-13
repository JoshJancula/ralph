#!/usr/bin/env bats
# graph-corrective-outcomes: library-level tests. No real dispatch.

source "$BATS_TEST_DIRNAME/test_helper/graph-corrective-outcomes-shared.bash"

@test "corrective record writes compact json for missing artifact" {
  local record
  run graph_schedule_write_correction_record "$RUN_DIR" "impl" "1" \
    '{"kind":"artifact","reason":"required-artifact-missing:exchange/out.md"}'
  [ "$status" -eq 0 ]
  record="$output"
  assert_compact_correction "$record"
  [ "$record" = "$RUN_DIR/corrections/impl.json" ]
  [ "$(jq -r '.failedCompletionComponent' "$record")" = "required-artifact-missing" ]
  [ "$(jq -r '.offendingPaths | join(",")' "$record")" = "exchange/out.md" ]
  [ "$(jq -r '.verificationResultPath' "$record")" = "null" ]
  [ "$(jq -r '.nextAttemptNumber' "$record")" = "2" ]
}

@test "corrective record adapts nested StageOutcomeReport v2 failure evidence" {
  local missing record report
  missing="$TMPD/state/artifacts/corrective-retry/out.md"
  report="$(jq -cn --arg p "$missing" '{
    schemaVersion: 2,
    outcome: "failed",
    exitCode: 1,
    failure: {
      classification: "agent-correctable",
      cause: "required-artifact-missing",
      source: "orchestrator",
      summary: "a required artifact was not produced",
      retryable: true,
      operatorAction: "none",
      missingArtifacts: [$p],
      offendingPaths: [],
      verification: "unknown"
    }
  }')"

  record="$(graph_schedule_write_correction_record "$RUN_DIR" "impl" "1" "$report")"
  assert_compact_correction "$record"
  [ "$(jq -r '.failedCompletionComponent' "$record")" = "required-artifact-missing" ]
  [ "$(jq -r '.offendingPaths[0]' "$record")" = "$missing" ]
  [ "$(jq -r '.nextAttemptNumber' "$record")" = "2" ]
}

@test "corrective record omits prompts and raw output" {
  local record
  record="$(graph_schedule_write_correction_record "$RUN_DIR" "impl" "2" \
    '{"component":"verification","missingArtifacts":["notes.md"],"prompt":"fix the todo","output":"full agent transcript","rawOutput":"BYTES","stdout":"log","stderr":"err","text":"noise"}')"
  assert_compact_correction "$record"
  [ "$(jq -r '.failedCompletionComponent' "$record")" = "verification" ]
  [ "$(jq -r '.offendingPaths[0]' "$record")" = "notes.md" ]
  [ "$(jq -r '.nextAttemptNumber' "$record")" = "3" ]
  ! jq -e '.prompt or .output or .rawOutput or .stdout or .stderr or .text' "$record" >/dev/null
}

@test "corrective record includes verification-result path and next attempt number" {
  local record
  record="$(graph_schedule_write_correction_record "$RUN_DIR" "gate-node" "4" \
    '{"kind":"verification-failed","offendingPaths":["src/a.ts"],"verificationResultPath":"/tmp/verify/gate-result.json"}')"
  assert_compact_correction "$record"
  [ "$(jq -r '.failedCompletionComponent' "$record")" = "verification-failed" ]
  [ "$(jq -r '.offendingPaths | join(",")' "$record")" = "src/a.ts" ]
  [ "$(jq -r '.verificationResultPath' "$record")" = "/tmp/verify/gate-result.json" ]
  [ "$(jq -r '.nextAttemptNumber | type' "$record")" = "number" ]
  [ "$(jq -r '.nextAttemptNumber' "$record")" = "5" ]
}

@test "corrective record merges offending paths and missing artifacts" {
  local record
  record="$(graph_schedule_write_correction_record "$RUN_DIR" "impl" "1" \
    '{"component":"correctable-scope","offendingPaths":["src/leaked.ts"],"missingArtifacts":["exchange/out.md"]}')"
  assert_compact_correction "$record"
  [ "$(jq -r '.offendingPaths | sort | join(",")' "$record")" = "exchange/out.md,src/leaked.ts" ]
}

@test "corrective record reads a result file and ignores extra fields" {
  local src record
  src="$TMPD/result.json"
  printf '%s\n' '{"kind":"changeset-verification-failed","offendingPaths":["src/bad.ts"],"verificationResult":"'"$TMPD"'/verify.json","prompt":"do not persist","output":"raw"}' >"$src"
  record="$(graph_schedule_write_correction_record "$RUN_DIR" "build" "1" "$src")"
  assert_compact_correction "$record"
  [ "$(jq -r '.failedCompletionComponent' "$record")" = "changeset-verification-failed" ]
  [ "$(jq -r '.offendingPaths[0]' "$record")" = "src/bad.ts" ]
  [ "$(jq -r '.verificationResultPath' "$record")" = "$TMPD/verify.json" ]
}

@test "corrective record is not written for plan-contract results" {
  run graph_schedule_write_correction_record "$RUN_DIR" "impl" "1" \
    '{"kind":"undeclared-path","outOfScope":["docs/secret.md"]}'
  [ "$status" -ne 0 ]
  [ ! -e "$RUN_DIR/corrections/impl.json" ]
}

@test "corrective record is not written for operator-permission results" {
  run graph_schedule_write_correction_record "$RUN_DIR" "impl" "1" \
    '{"outcome":"failed","exitCode":4,"prompt":"allow bash?"}'
  [ "$status" -ne 0 ]
  [ ! -e "$RUN_DIR/corrections/impl.json" ]
}

@test "corrective record is written by the scheduler helper for agent-correctable reap results" {
  local record
  GRAPH_SCHEDULE_LEDGER_RUN_DIR="$RUN_DIR"
  GRAPH_NODE_IDS=()
  GRAPH_NODE_ATTEMPT_NUMBERS=()
  GRAPH_NODE_INDEX_KEYS=()
  GRAPH_NODE_INDEX_VALS=()
  _graph_schedule_try_write_correction_record "impl" "impl__run-1__1" \
    '{"kind":"artifact-publish-failed","missingArtifacts":["stub-output.md"],"verificationResultPath":"'"$TMPD"'/verify.json","output":"do-not-store"}'
  record="$RUN_DIR/corrections/impl.json"
  assert_compact_correction "$record"
  [ "$(jq -r '.failedCompletionComponent' "$record")" = "artifact-publish-failed" ]
  [ "$(jq -r '.offendingPaths[0]' "$record")" = "stub-output.md" ]
  [ "$(jq -r '.verificationResultPath' "$record")" = "$TMPD/verify.json" ]
  [ "$(jq -r '.nextAttemptNumber' "$record")" = "2" ]
}

@test "corrective retry requeues without deleting the isolated workspace" {
  local graph_file record node_key workspace_path idx
  graph_file="$TMPD/corrective.graph.json"
  write_corrective_graph "$graph_file" true
  graph_schedule_load_index "$graph_file"
  GRAPH_SCHEDULE_GRAPH_JSON="$graph_file"
  GRAPH_SCHEDULE_LEDGER_RUN_DIR=""
  GRAPH_SCHEDULE_LEDGER_NAMESPACE=""
  GRAPH_SCHEDULE_WORKSPACE=""
  GRAPH_SCHEDULE_RUN_ID=""

  node_key="$(graph_workspace_node_key impl)"
  workspace_path="$RUN_DIR/workspaces/nodes/$node_key"
  mkdir -p "$workspace_path/src"
  printf 'keep-isolated-work\n' >"$workspace_path/src/partial.ts"

  record="$(graph_schedule_write_correction_record "$RUN_DIR" "impl" "1" \
    '{"kind":"artifact-publish-failed","missingArtifacts":["stub-output.md"]}')"
  assert_compact_correction "$record"

  graph_schedule_requeue_corrective_node "$RUN_DIR" "impl" "impl__run-1__1" >"$TMPD/requeued.path"
  [ "$(cat "$TMPD/requeued.path")" = "$record" ]
  [ "$(graph_schedule_node_state_by_id impl)" = "pending" ]
  idx="$(graph_schedule_index_map_get impl)"
  [ "${GRAPH_NODE_CORRECTIVE_RETRIES_USED[$idx]}" = "1" ]
  [ -d "$workspace_path" ]
  [ -f "$workspace_path/src/partial.ts" ]
  [ "$(cat "$workspace_path/src/partial.ts")" = "keep-isolated-work" ]
}

@test "corrective retry consumes one retry attempt and preserves the prior attempt" {
  local graph_file workspace ns run_id node_file aid record idx
  graph_file="$TMPD/corrective.graph.json"
  write_corrective_graph "$graph_file" true
  workspace="$TMPD/ws"
  mkdir -p "$workspace"
  ns="corrective-retry"
  run_id="run-corrective-1"
  printf 'plan\n' >"$workspace/plan.md"
  graph_state_init_run "$workspace" "$ns" "$run_id" "$workspace/plan.md" "$graph_file" 1

  graph_schedule_load_index "$graph_file"
  GRAPH_SCHEDULE_GRAPH_JSON="$graph_file"
  GRAPH_SCHEDULE_WORKSPACE="$workspace"
  GRAPH_SCHEDULE_LEDGER_NAMESPACE="$ns"
  GRAPH_SCHEDULE_RUN_ID="$run_id"
  GRAPH_SCHEDULE_LEDGER_RUN_DIR="$(graph_state_run_dir "$workspace" "$ns" "$run_id")"
  RUN_DIR="$GRAPH_SCHEDULE_LEDGER_RUN_DIR"

  aid="impl__${run_id}__1"
  _graph_schedule_ledger_record "impl" "running" "$aid" "" "" "2026-01-01T00:00:00Z" "" "cursor" "off" ""
  _graph_schedule_ledger_record "impl" "failed" "$aid" "failed" "1" "" "2026-01-01T00:00:01Z" \
    "cursor" "off" "artifact-publish-failed"
  GRAPH_NODE_ATTEMPT_NUMBERS[$(graph_schedule_index_map_get impl)]="1"

  record="$(graph_schedule_write_correction_record "$RUN_DIR" "impl" "1" \
    '{"kind":"artifact-publish-failed","missingArtifacts":["stub-output.md"]}')"
  assert_compact_correction "$record"
  [ "$(jq -r '.nextAttemptNumber' "$record")" = "2" ]

  graph_schedule_requeue_corrective_node "$RUN_DIR" "impl" "$aid" >"$TMPD/requeued.path"
  [ "$(cat "$TMPD/requeued.path")" = "$record" ]

  node_file="$(graph_state_node_file "$workspace" "$ns" "$run_id" "impl")"
  [ "$(jq -r '.status' "$node_file")" = "pending" ]
  [ "$(jq '.attempts | length' "$node_file")" -eq 1 ]
  [ "$(jq -r '.attempts[0].attemptId' "$node_file")" = "$aid" ]
  [ "$(jq -r '.attempts[0].outcome' "$node_file")" = "failed" ]
  [ "$(jq -r '.attempts[0].exitCode' "$node_file")" = "1" ]
  [ "$(graph_state_max_attempt_number "$node_file")" -eq 1 ]
  idx="$(graph_schedule_index_map_get impl)"
  [ "${GRAPH_NODE_CORRECTIVE_RETRIES_USED[$idx]}" = "1" ]
  [ "${GRAPH_NODE_ATTEMPT_NUMBERS[$idx]}" = "1" ]

  run graph_schedule_requeue_corrective_node "$RUN_DIR" "impl" "$aid"
  [ "$status" -ne 0 ]
  [ "$(jq '.attempts | length' "$node_file")" -eq 1 ]
  [ "$(jq -r '.attempts[0].attemptId' "$node_file")" = "$aid" ]
  [ "$(jq -r '.status' "$node_file")" = "pending" ]
}

@test "corrective retry passes only the compact correction record on a supported session turn" {
  local graph_file record turn
  graph_file="$TMPD/corrective.graph.json"
  write_corrective_graph "$graph_file" true
  record="$(graph_schedule_write_correction_record "$RUN_DIR" "impl" "1" \
    '{"kind":"required-artifact-missing","missingArtifacts":["stub-output.md"],"prompt":"full prior prompt","output":"raw transcript"}')"
  assert_compact_correction "$record"

  run graph_schedule_node_session_resume_supported "$graph_file" "impl"
  [ "$status" -eq 0 ]

  turn="$(graph_schedule_corrective_retry_turn "$RUN_DIR" "impl" "$graph_file")"
  [ "$turn" = "$record" ]
  assert_compact_correction "$turn"
  [ "$(jq -r 'keys | sort | join(",")' "$turn")" = \
    "failedCompletionComponent,nextAttemptNumber,offendingPaths,verificationResultPath" ]
  ! jq -e '.prompt or .output or .rawOutput or .stdout or .stderr or .text' "$turn" >/dev/null

  GRAPH_SCHEDULE_GRAPH_JSON="$graph_file"
  GRAPH_SCHEDULE_LEDGER_RUN_DIR="$RUN_DIR"
  GRAPH_SCHEDULE_SPAWN_CORRECTION_RECORD=""
  _graph_schedule_prepare_corrective_retry_spawn "impl" "2" ""
  [ "$GRAPH_SCHEDULE_SPAWN_CORRECTION_RECORD" = "$record" ]

  _graph_schedule_prepare_corrective_retry_spawn "impl" "1" ""
  [ -z "$GRAPH_SCHEDULE_SPAWN_CORRECTION_RECORD" ]
}

@test "corrective retry does not pass a session turn when resume is unsupported" {
  local graph_file record
  graph_file="$TMPD/corrective.graph.json"
  write_corrective_graph "$graph_file" false
  record="$(graph_schedule_write_correction_record "$RUN_DIR" "impl" "1" \
    '{"kind":"artifact-publish-failed","missingArtifacts":["stub-output.md"]}')"
  assert_compact_correction "$record"

  run graph_schedule_node_session_resume_supported "$graph_file" "impl"
  [ "$status" -ne 0 ]
  run graph_schedule_corrective_retry_turn "$RUN_DIR" "impl" "$graph_file"
  [ "$status" -ne 0 ]
  [ -z "$output" ]

  GRAPH_SCHEDULE_GRAPH_JSON="$graph_file"
  GRAPH_SCHEDULE_LEDGER_RUN_DIR="$RUN_DIR"
  _graph_schedule_prepare_corrective_retry_spawn "impl" "2" ""
  [ -z "$GRAPH_SCHEDULE_SPAWN_CORRECTION_RECORD" ]

  graph_schedule_load_index "$graph_file"
  graph_schedule_requeue_corrective_node "$RUN_DIR" "impl" "impl__run-1__1" >"$TMPD/requeued.path"
  [ "$(cat "$TMPD/requeued.path")" = "$record" ]
}

@test "required artifact v2 failure retries once with exact compact context and retained workspace" {
  local record attempt_two
  prepare_required_artifact_retry_harness 1

  _graph_schedule_handle_reaped_node 0
  # A zero-second backoff releases retry-wait immediately.
  [ "$(graph_schedule_node_state_by_id impl)" = "pending" ]
  [ -f "$RETRY_WORKSPACE/keep-me.txt" ]

  record="$RETRY_RUN_DIR/corrections/impl.json"
  assert_compact_correction "$record"
  [ "$(jq -r '.failedCompletionComponent' "$record")" = "required-artifact-missing" ]
  [ "$(jq -r '.offendingPaths[0]' "$record")" = "$RETRY_MISSING" ]
  [ "$(jq -r '.nextAttemptNumber' "$record")" = "2" ]

  GRAPH_NODE_STATES[$(graph_schedule_index_map_get impl)]="pending"
  GRAPH_SCHEDULE_SPAWN_CORRECTION_RECORD=""
  _graph_schedule_prepare_corrective_retry_spawn impl 2 ""
  [ "$GRAPH_SCHEDULE_SPAWN_CORRECTION_RECORD" = "$record" ]
  assert_compact_correction "$GRAPH_SCHEDULE_SPAWN_CORRECTION_RECORD"

  attempt_two="impl__${RETRY_RUN_ID}__2"
  printf 'required artifact\n' >"$RETRY_MISSING"
  [ -s "$RETRY_MISSING" ]
  _graph_schedule_ledger_record impl running "$attempt_two" "" "" \
    "2026-01-01T00:00:02Z" "" cursor off ""
  _graph_schedule_ledger_record impl succeeded "$attempt_two" success 0 "" \
    "2026-01-01T00:00:03Z" cursor off ""
  GRAPH_NODE_STATES[$(graph_schedule_index_map_get impl)]="succeeded"

  [ "$(awk -F '\t' '$3 != "" {print $3}' "$RETRY_LEDGER" | sort -u | wc -l | tr -d ' ')" -eq 2 ]
  grep -q $'impl\tfailed\t'"$RETRY_ATTEMPT_ONE"$'\tfailed' "$RETRY_LEDGER"
  grep -q $'impl\tsucceeded\t'"$attempt_two"$'\tsuccess' "$RETRY_LEDGER"
  [ "$(graph_schedule_node_state_by_id impl)" = "succeeded" ]
}

@test "required artifact v2 failure with zero corrective retries fails after one attempt" {
  local record rc=0
  prepare_required_artifact_retry_harness 0

  _graph_schedule_handle_reaped_node 0 || rc=$?
  [ "$rc" -ne 0 ]
  [ "$(graph_schedule_node_state_by_id impl)" = "failed" ]

  record="$RETRY_RUN_DIR/corrections/impl.json"
  assert_compact_correction "$record"
  [ "$(jq -r '.offendingPaths[0]' "$record")" = "$RETRY_MISSING" ]
  [ -f "$RETRY_WORKSPACE/keep-me.txt" ]

  [ "$(awk -F '\t' '$3 != "" {print $3}' "$RETRY_LEDGER" | sort -u | wc -l | tr -d ' ')" -eq 1 ]
  grep -q $'impl\tfailed\t'"$RETRY_ATTEMPT_ONE"$'\tfailed' "$RETRY_LEDGER"
}

@test "corrective plan contract maps undeclared path to needs-plan-repair" {
  local graph_file class
  graph_file="$TMPD/plan-contract.graph.json"
  write_plan_contract_graph "$graph_file"
  graph_schedule_load_index "$graph_file"
  GRAPH_SCHEDULE_GRAPH_JSON="$graph_file"
  GRAPH_SCHEDULE_STOP_DISPATCH=0
  GRAPH_SCHEDULE_EXIT_CODE=0
  GRAPH_SCHEDULE_FAILED_NODE=""
  GRAPH_SCHEDULE_LEDGER_RUN_DIR=""

  class="$(_graph_schedule_result_classification \
    '{"kind":"undeclared-path","outOfScope":["docs/secret.md"]}')"
  [ "$class" = "plan-contract" ]

  graph_schedule_apply_plan_contract "contract" 1 "undeclared-path"
  [ "$(graph_schedule_node_state_by_id contract)" = "needs-plan-repair" ]
  [ "$GRAPH_SCHEDULE_STOP_DISPATCH" -eq 0 ]
  [ "$GRAPH_SCHEDULE_FAILED_NODE" = "contract" ]
  [ "$GRAPH_SCHEDULE_EXIT_CODE" -eq 1 ]
}

@test "corrective plan contract maps write-scope mismatch without widening scopes" {
  local graph_file before after
  graph_file="$TMPD/plan-contract.graph.json"
  write_plan_contract_graph "$graph_file"
  before="$(jq -c --arg id contract '.nodes[] | select(.id == $id) | .stage.writeScopes' "$graph_file")"
  [ "$before" = '["src/allowed/**"]' ]
  cp "$graph_file" "$TMPD/graph.before.json"

  graph_schedule_load_index "$graph_file"
  GRAPH_SCHEDULE_GRAPH_JSON="$graph_file"
  GRAPH_SCHEDULE_STOP_DISPATCH=0
  GRAPH_SCHEDULE_LEDGER_RUN_DIR=""

  graph_schedule_apply_plan_contract "contract" 1 "write-scope-mismatch"
  [ "$(graph_schedule_node_state_by_id contract)" = "needs-plan-repair" ]
  [ "$(graph_schedule_node_state_by_id child)" = "blocked" ]
  [ "$(graph_schedule_node_state_by_id independent)" = "pending" ]

  after="$(jq -c --arg id contract '.nodes[] | select(.id == $id) | .stage.writeScopes' "$graph_file")"
  [ "$after" = "$before" ]
  cmp -s "$graph_file" "$TMPD/graph.before.json"
}

@test "corrective plan contract blocks only descendants" {
  local graph_file
  graph_file="$TMPD/plan-contract.graph.json"
  write_plan_contract_graph "$graph_file"
  graph_schedule_load_index "$graph_file"
  GRAPH_SCHEDULE_GRAPH_JSON="$graph_file"
  GRAPH_SCHEDULE_STOP_DISPATCH=0
  GRAPH_SCHEDULE_LEDGER_RUN_DIR=""

  graph_schedule_apply_plan_contract "contract" 1 "undeclared-changed-leaf"
  [ "$(graph_schedule_node_state_by_id contract)" = "needs-plan-repair" ]
  [ "$(graph_schedule_node_state_by_id child)" = "blocked" ]
  [ "$(graph_schedule_node_state_by_id independent)" = "pending" ]
  [ "$GRAPH_SCHEDULE_STOP_DISPATCH" -eq 0 ]
}
