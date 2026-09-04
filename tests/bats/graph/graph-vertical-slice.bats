#!/usr/bin/env bats
# G20: vertical-slice acceptance harness. A real two-node graph run must
# cross the public graph CLI, the real scheduler, the real orchestrator.sh,
# the real run-plan.sh, and a fake runtime executable -- and the harness's
# own crossing checks must fail when either orchestrator.sh or run-plan.sh
# is bypassed.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/test_helper/graph-vertical-slice.bash"

setup() {
  unset RALPH_PROCESS_RUN_ID RALPH_PROCESS_RUN_DEPTH RALPH_PROCESS_MAX_NESTED_DEPTH
}

teardown() {
  graph_vertical_slice_cleanup
}

@test "graph vertical slice: two-node success crosses scheduler, orchestrator, run-plan, and the fake runtime" {
  graph_vertical_slice_setup success

  graph_vertical_slice_run
  [ "$GVS_STATUS" -eq 0 ] || {
    echo "graph run did not exit 0; output:"
    printf '%s\n' "$GVS_OUTPUT"
    return 1
  }

  run_dir="$(graph_vertical_slice_run_dir)"
  [ -n "$run_dir" ]
  [ -d "$run_dir" ]

  # Runner/agent/usage/outcome/ledger/event paths are exposed and correct.
  for node in first second; do
    ledger="$(graph_vertical_slice_node_ledger "$node")"
    [ -f "$ledger" ]
    [ "$(jq -r '.status' "$ledger")" = "succeeded" ]

    runner_log="$(graph_vertical_slice_runner_log "$node")"
    [ -f "$runner_log" ]
    grep -q "Invoking: .ralph/run-plan.sh" "$runner_log"

    agent_log="$(graph_vertical_slice_agent_log "$node")"
    [ -f "$agent_log" ]

    usage_json="$(graph_vertical_slice_usage_json "$node")"
    [ -f "$usage_json" ]

    outcome_json="$(graph_vertical_slice_outcome_json "$node")"
    [ -f "$outcome_json" ]
    [ "$(jq -r '.outcome' "$outcome_json")" = "success" ]
  done

  events_jsonl="$(graph_vertical_slice_events_jsonl)"
  [ -f "$events_jsonl" ]
  grep -q '"event":"run-started"' "$events_jsonl"

  orchestrator_log="$(graph_vertical_slice_orchestrator_log)"
  [ -f "$orchestrator_log" ]

  # Prove the fake runtime was the only thing standing in for a real model:
  # exactly two real (non --help) invocations, one per node.
  [ -s "$GVS_RECORD" ]
  [ "$(grep -c '^REAL_INVOCATION$' "$GVS_RECORD")" -eq 2 ]

  # The harness's own crossing-check helper agrees.
  graph_vertical_slice_crossed_all_layers
}

@test "graph vertical slice: bypassing orchestrator and run-plan is caught by the crossing checks" {
  graph_vertical_slice_setup bypass

  graph_vertical_slice_run
  # The bypass stub refuses (exit 3); the graph run must not report success.
  [ "$GVS_STATUS" -ne 0 ]

  # Preflight's capability probe may still call the fake CLI with --help,
  # but dispatch never reaches a real (non-probe) invocation: neither node
  # reached the real orchestrator/run-plan/fake-runtime chain.
  if [[ -f "$GVS_RECORD" ]]; then
    [ "$(grep -c '^REAL_INVOCATION$' "$GVS_RECORD")" -eq 0 ]
  fi

  # The harness's own crossing-check helper must fail here -- proving the
  # success test's checks are meaningful, not tautological.
  run graph_vertical_slice_crossed_all_layers
  [ "$status" -ne 0 ]
  [[ "$output" == *"crossing check failed"* ]]
}
