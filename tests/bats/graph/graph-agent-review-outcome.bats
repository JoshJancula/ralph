#!/usr/bin/env bats
# Tests for the agent-node success path resolving a semantic review outcome
# via a stage-declared loopCheck artifact. Roles never supply verdicts,
# loop conditions, or rework evidence.
#
# Coverage:
#   - changes-required verdict releases condition:changes-required successor,
#     skips condition:passed successor (evaluator verdict + rework evidence).
#   - approved verdict releases condition:passed successor, skips
#     condition:changes-required successor.
#   - missing/invalid verdict artifact fails with reason review-verdict-invalid
#     and produces exactly one terminal failed ledger record (never a
#     succeeded-then-failed transition).
#   - a valid changes-required verdict with no matching conditional edge fails
#     with reason review-changes-required-no-edge (fail-closed exhaustion).
#   - role present without stage loopCheck resolves passed (removed fallback).

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/atomic-json.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-failure-classify.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-run-base.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-schedule.sh"

# write_review_graph <out_path> <with_repair_edge:true|false> [with_loop_check:true|false]
# review -[passed]-> publish
# review -[changes-required]-> repair   (only when with_repair_edge=true)
write_review_graph() {
  local out_path="$1" with_repair="${2:-true}" with_loop="${3:-true}"
  local loop_check_json="null"
  if [[ "$with_loop" == "true" ]]; then
    loop_check_json='{"path":".ralph-workspace/artifacts/{{ARTIFACT_NS}}/exchange/{{STAGE_ID}}/verdict.json"}'
  fi
  if [[ "$with_repair" == "true" ]]; then
    jq -n --argjson loopCheck "$loop_check_json" '
      {
        schemaVersion: 1,
        ralphVersion: "test",
        name: "review-outcome",
        namespace: "review-outcome",
        maxParallel: 1,
        failurePolicy: "drain",
        nodes: [
          {
            id: "review", type: "agent", dependsOn: [], derivedFrom: "stage",
            stage: (
              {
                id: "review", runtime: "cursor", role: "code-review",
                _inlineTodos: [{id: "review-1", content: "review it", status: "pending"}]
              } + (if $loopCheck == null then {} else {loopCheck: $loopCheck} end)
            )
          },
          {
            id: "publish", type: "agent", dependsOn: ["review"], derivedFrom: "stage",
            stage: {id: "publish", runtime: "cursor", role: "implementation",
              _inlineTodos: [{id: "publish-1", content: "publish it", status: "pending"}]}
          },
          {
            id: "repair", type: "agent", dependsOn: ["review"], derivedFrom: "stage",
            stage: {id: "repair", runtime: "cursor", role: "implementation",
              _inlineTodos: [{id: "repair-1", content: "repair it", status: "pending"}]}
          }
        ],
        edges: [
          {from: "review", to: "publish", reasons: ["declared"], condition: "passed"},
          {from: "review", to: "repair", reasons: ["declared"], condition: "changes-required"}
        ]
      }
    ' >"$out_path"
  else
    # No conditional(changes-required) edge: only the passed branch exists.
    jq -n --argjson loopCheck "$loop_check_json" '
      {
        schemaVersion: 1,
        ralphVersion: "test",
        name: "review-outcome",
        namespace: "review-outcome",
        maxParallel: 1,
        failurePolicy: "drain",
        nodes: [
          {
            id: "review", type: "agent", dependsOn: [], derivedFrom: "stage",
            stage: (
              {
                id: "review", runtime: "cursor", role: "code-review",
                _inlineTodos: [{id: "review-1", content: "review it", status: "pending"}]
              } + (if $loopCheck == null then {} else {loopCheck: $loopCheck} end)
            )
          },
          {
            id: "publish", type: "agent", dependsOn: ["review"], derivedFrom: "stage",
            stage: {id: "publish", runtime: "cursor", role: "implementation",
              _inlineTodos: [{id: "publish-1", content: "publish it", status: "pending"}]}
          }
        ],
        edges: [
          {from: "review", to: "publish", reasons: ["declared"], condition: "passed"}
        ]
      }
    ' >"$out_path"
  fi
}

# write_review_report <out_path> <run_id> <attempt_id>
write_review_report() {
  local out_path="$1" run_id="$2" attempt_id="$3"
  mkdir -p "$(dirname "$out_path")"
  jq -n --arg run "$run_id" --arg attempt "$attempt_id" '{
    schemaVersion: 2,
    runId: $run,
    stageId: "review",
    attemptId: $attempt,
    outcome: "success",
    exitCode: 0
  }' >"$out_path"
}

setup() {
  TMPD="$(mktemp -d)"
  WORKSPACE="$TMPD/workspace"
  STATE_ROOT="$TMPD/state"
  RUN_DIR="$TMPD/run"
  mkdir -p "$WORKSPACE" "$STATE_ROOT" "$RUN_DIR"
  export RALPH_DIR="$REPO_ROOT/.ralph"
  export RALPH_PLAN_WORKSPACE_ROOT="$STATE_ROOT"
  export RALPH_GRAPH_STATE_ROOT="$STATE_ROOT"
  unset RALPH_GRAPH_COMPOSITE_SUCCESS 2>/dev/null || true

  GRAPH_JSON="$TMPD/g.graph.json"
  LEDGER="$TMPD/ledger.tsv"
  : >"$LEDGER"

  # Capture ledger transitions compactly instead of requiring a full run.json
  # / workspace-manager setup: node, state, attemptId, outcome, reason.
  _graph_schedule_ledger_record() {
    printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "${3:-}" "${4:-}" "${10:-}" >>"$LEDGER"
  }
}

teardown() {
  chmod -R u+w "$TMPD" 2>/dev/null || true
  rm -rf "$TMPD" 2>/dev/null || true
  unset RALPH_GRAPH_STATE_ROOT RALPH_PLAN_WORKSPACE_ROOT RALPH_GRAPH_COMPOSITE_SUCCESS RALPH_DIR 2>/dev/null || true
}

# Common scheduler-context setup shared by all reap tests below. Mints a
# fresh running "review" node whose report path is pre-populated with an
# outcome=success StageOutcomeReport.
prime_review_reap() {
  local run_id="run1" attempt_id
  attempt_id="review__${run_id}__1"

  graph_schedule_load_index "$GRAPH_JSON"
  GRAPH_SCHEDULE_GRAPH_JSON="$GRAPH_JSON"
  GRAPH_SCHEDULE_WORKSPACE="$WORKSPACE"
  GRAPH_SCHEDULE_NAMESPACE="review-outcome"
  GRAPH_SCHEDULE_RUN_ID="$run_id"
  GRAPH_SCHEDULE_LEDGER_RUN_DIR=""
  GRAPH_SCHEDULE_LOG_RUN_DIR="$RUN_DIR"
  GRAPH_SCHEDULE_FAILURE_POLICY="drain"
  GRAPH_SCHEDULE_EXIT_CODE=0
  GRAPH_SCHEDULE_FAILED_NODE=""
  GRAPH_SCHEDULE_STOP_DISPATCH=0
  GRAPH_SCHEDULE_CANCEL_REQUESTED=0

  local idx
  idx="$(graph_schedule_index_map_get review)"
  GRAPH_NODE_STATES[$idx]="running"
  GRAPH_NODE_ATTEMPT_NUMBERS[$idx]="1"

  REVIEW_REPORT="$STATE_ROOT/artifacts/review-outcome/stage-outcomes/${attempt_id}.json"
  write_review_report "$REVIEW_REPORT" "$run_id" "$attempt_id"

  GRAPH_REAP_NODE=review
  GRAPH_REAP_REPORT_PATH="$REVIEW_REPORT"
  GRAPH_REAP_EXIT_CODE=0
  GRAPH_REAP_MISSING_REPORT=0

  VERDICT_PATH="$STATE_ROOT/artifacts/review-outcome/exchange/review/verdict.json"
  mkdir -p "$(dirname "$VERDICT_PATH")"
}

@test "agent review outcome: changes-required verdict releases repair edge, skips passed edge" {
  command -v jq >/dev/null || skip "jq required"
  command -v python3 >/dev/null || skip "python3 required"
  write_review_graph "$GRAPH_JSON" true
  prime_review_reap

  # Rework evidence is the stage-declared evaluator verdict feedback list.
  printf '{"status":"changes-required","feedback":["needs work on the parser"]}' >"$VERDICT_PATH"

  local rc=0
  _graph_schedule_handle_reaped_node 0 || rc=$?
  [ "$rc" -eq 0 ]
  [ "$(graph_schedule_node_state_by_id review)" = "succeeded" ]

  local repair_idx publish_idx
  repair_idx="$(graph_schedule_index_map_get repair)"
  publish_idx="$(graph_schedule_index_map_get publish)"
  [ "${GRAPH_NODE_REMAINING_INDEGREE[$repair_idx]}" -eq 0 ]
  [ "${GRAPH_NODE_STATES[$publish_idx]}" = "skipped" ]

  grep -q $'review\tsucceeded\t' "$LEDGER"
  ! grep -q $'review\tfailed\t' "$LEDGER"

  # Evaluator helper reads the same stage-declared verdict as rework evidence.
  if ! declare -F ralph_evaluator_parse_status >/dev/null 2>&1; then
    source "$REPO_ROOT/bundle/.ralph/bash-lib/review-status.sh"
  fi
  local schema_path="$REPO_ROOT/bundle/.ralph/schemas/evaluator-verdict.schema.json"
  [ "$(ralph_evaluator_parse_status "$VERDICT_PATH" "$schema_path")" = "changes-required" ]
  jq -e '.feedback == ["needs work on the parser"]' "$VERDICT_PATH" >/dev/null
}

@test "agent review outcome: approved verdict releases passed edge, skips repair edge" {
  command -v jq >/dev/null || skip "jq required"
  command -v python3 >/dev/null || skip "python3 required"
  write_review_graph "$GRAPH_JSON" true
  prime_review_reap

  printf '{"status":"approved","feedback":[]}' >"$VERDICT_PATH"

  local rc=0
  _graph_schedule_handle_reaped_node 0 || rc=$?
  [ "$rc" -eq 0 ]
  [ "$(graph_schedule_node_state_by_id review)" = "succeeded" ]

  local repair_idx publish_idx
  repair_idx="$(graph_schedule_index_map_get repair)"
  publish_idx="$(graph_schedule_index_map_get publish)"
  [ "${GRAPH_NODE_REMAINING_INDEGREE[$publish_idx]}" -eq 0 ]
  [ "${GRAPH_NODE_STATES[$repair_idx]}" = "skipped" ]

  grep -q $'review\tsucceeded\t' "$LEDGER"
  ! grep -q $'review\tfailed\t' "$LEDGER"
}

@test "evaluator helper resolves from its own library path on the public workflow source path" {
  command -v python3 >/dev/null || skip "python3 required"
  local verdict_path="$TMPD/public-workflow-verdict.json"
  printf '{"status":"approved","feedback":[]}' >"$verdict_path"

  unset RALPH_ACTIVE_DIR RALPH_DIR SCRIPT_DIR
  [ "$(ralph_evaluator_parse_status "$verdict_path")" = "approved" ]
}

@test "agent review outcome: missing verdict artifact fails with review-verdict-invalid" {
  command -v jq >/dev/null || skip "jq required"
  command -v python3 >/dev/null || skip "python3 required"
  write_review_graph "$GRAPH_JSON" true
  prime_review_reap

  # Deliberately do not write $VERDICT_PATH.

  local rc=0
  _graph_schedule_handle_reaped_node 0 || rc=$?
  [ "$rc" -ne 0 ]
  [ "$(graph_schedule_node_state_by_id review)" = "failed" ]

  # Exactly one terminal ledger transition for this node, and it is "failed"
  # -- never a succeeded-then-failed sequence.
  [ "$(awk -F '\t' '$1=="review"{print}' "$LEDGER" | wc -l | tr -d ' ')" -eq 1 ]
  grep -q $'review\tfailed\t[^\t]*\tfailed\treview-verdict-invalid' "$LEDGER"
  ! grep -q $'review\tsucceeded\t' "$LEDGER"
}

@test "agent review outcome: invalid verdict schema fails with review-verdict-invalid" {
  command -v jq >/dev/null || skip "jq required"
  command -v python3 >/dev/null || skip "python3 required"
  write_review_graph "$GRAPH_JSON" true
  prime_review_reap

  # Invalid "status" enum per evaluator-verdict.schema.json. ("feedback" is an
  # optional key since findings[] was introduced, so omitting it is valid.)
  printf '{"status":"maybe"}' >"$VERDICT_PATH"

  local rc=0
  _graph_schedule_handle_reaped_node 0 || rc=$?
  [ "$rc" -ne 0 ]
  [ "$(graph_schedule_node_state_by_id review)" = "failed" ]
  [ "$(awk -F '\t' '$1=="review"{print}' "$LEDGER" | wc -l | tr -d ' ')" -eq 1 ]
  grep -q $'review\tfailed\t[^\t]*\tfailed\treview-verdict-invalid' "$LEDGER"
}

@test "agent review outcome: changes-required verdict with no matching edge fails closed" {
  command -v jq >/dev/null || skip "jq required"
  command -v python3 >/dev/null || skip "python3 required"
  write_review_graph "$GRAPH_JSON" false
  prime_review_reap

  printf '{"status":"changes-required","feedback":["needs work"]}' >"$VERDICT_PATH"

  local rc=0
  _graph_schedule_handle_reaped_node 0 || rc=$?
  [ "$rc" -ne 0 ]
  [ "$(graph_schedule_node_state_by_id review)" = "failed" ]

  [ "$(awk -F '\t' '$1=="review"{print}' "$LEDGER" | wc -l | tr -d ' ')" -eq 1 ]
  grep -q $'review\tfailed\t[^\t]*\tfailed\treview-changes-required-no-edge' "$LEDGER"
  ! grep -q $'review\tsucceeded\t' "$LEDGER"
}

@test "agent review outcome: role without stage loopCheck resolves passed (removed fallback)" {
  command -v jq >/dev/null || skip "jq required"
  command -v python3 >/dev/null || skip "python3 required"
  # Role present, but no stage loopCheck -- roles must not invent verdict paths.
  write_review_graph "$GRAPH_JSON" true false
  prime_review_reap

  # Seed a profile-shaped verdict that must be ignored without stage loopCheck.
  printf '{"status":"changes-required","feedback":["from-role-profile"]}' >"$VERDICT_PATH"

  local outcome rc=0
  outcome="$(_graph_schedule_agent_conditional_outcome \
    review "$(cat "$GRAPH_JSON")" "$STATE_ROOT" review-outcome)" || rc=$?
  [ "$rc" -eq 0 ]
  [ "$outcome" = "passed" ]

  rc=0
  _graph_schedule_handle_reaped_node 0 || rc=$?
  [ "$rc" -eq 0 ]
  [ "$(graph_schedule_node_state_by_id review)" = "succeeded" ]

  local repair_idx publish_idx
  repair_idx="$(graph_schedule_index_map_get repair)"
  publish_idx="$(graph_schedule_index_map_get publish)"
  # passed branch only -- changes-required profile verdict was not consulted.
  [ "${GRAPH_NODE_REMAINING_INDEGREE[$publish_idx]}" -eq 0 ]
  [ "${GRAPH_NODE_STATES[$repair_idx]}" = "skipped" ]
}

@test "agent review outcome: a blocking finding open past the stall threshold fails with rework-stalled" {
  command -v jq >/dev/null || skip "jq required"
  command -v python3 >/dev/null || skip "python3 required"
  write_review_graph "$GRAPH_JSON" true
  prime_review_reap

  printf '%s' '{"status":"changes-required","findings":[{"id":"F1","severity":"blocking","summary":"same defect","requiredFix":"split the change"}]}' >"$VERDICT_PATH"

  # Age F1 past the threshold by folding the same verdict into three rounds.
  local ledger="$(dirname "$VERDICT_PATH")/defect-ledger.json"
  local py="$REPO_ROOT/bundle/.ralph/python/evaluator_contract.py"
  python3 "$py" ledger-merge --ledger "$ledger" --artifact "$VERDICT_PATH" --iteration 1 --source-stage review >/dev/null
  python3 "$py" ledger-merge --ledger "$ledger" --artifact "$VERDICT_PATH" --iteration 2 --source-stage review-r1 >/dev/null
  python3 "$py" ledger-merge --ledger "$ledger" --artifact "$VERDICT_PATH" --iteration 3 --source-stage review-r2 >/dev/null
  [ "$(jq -r '.findings[0].roundsOpen' "$ledger")" -eq 3 ]

  local rc=0
  _graph_schedule_handle_reaped_node 0 || rc=$?
  [ "$rc" -ne 0 ]
  [ "$(graph_schedule_node_state_by_id review)" = "failed" ]
  [ "$(awk -F '\t' '$1=="review"{print}' "$LEDGER" | wc -l | tr -d ' ')" -eq 1 ]
  grep -q $'review\tfailed\t[^\t]*\tfailed\trework-stalled' "$LEDGER"
}

@test "agent review outcome: stall detection can be disabled" {
  command -v jq >/dev/null || skip "jq required"
  command -v python3 >/dev/null || skip "python3 required"
  write_review_graph "$GRAPH_JSON" true
  prime_review_reap

  printf '%s' '{"status":"changes-required","findings":[{"id":"F1","severity":"blocking","summary":"same defect","requiredFix":"split the change"}]}' >"$VERDICT_PATH"
  local ledger="$(dirname "$VERDICT_PATH")/defect-ledger.json"
  local py="$REPO_ROOT/bundle/.ralph/python/evaluator_contract.py"
  python3 "$py" ledger-merge --ledger "$ledger" --artifact "$VERDICT_PATH" --iteration 1 --source-stage review >/dev/null
  python3 "$py" ledger-merge --ledger "$ledger" --artifact "$VERDICT_PATH" --iteration 2 --source-stage review-r1 >/dev/null
  python3 "$py" ledger-merge --ledger "$ledger" --artifact "$VERDICT_PATH" --iteration 3 --source-stage review-r2 >/dev/null

  RALPH_REWORK_STALL_ROUNDS=0 _graph_schedule_handle_reaped_node 0
  [ "$(graph_schedule_node_state_by_id review)" = "succeeded" ]
  ! grep -q 'rework-stalled' "$LEDGER"
}
