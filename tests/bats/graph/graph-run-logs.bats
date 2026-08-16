#!/usr/bin/env bats
# Run-owned graph log containment: v2 paths live under <run-dir>/logs/,
# two runs with the same node/attempt numbers never share files, v1
# namespace paths stay readable, and traversal/symlink inputs fail.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/atomic-json.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-state.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-logs.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-dispatch.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-run-base.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-schedule.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/cleanup-plan.sh"

FIXTURE_COLLISION="$BATS_TEST_DIRNAME/../../fixtures/graph-production-failure/duplicate-run-node-attempt-collision.json"
STUB_RUN_PLAN="$BATS_TEST_DIRNAME/../../fixtures/orchestrator-single-stage/run-plan-stub.sh"
RALPH_DIR="$REPO_ROOT/bundle/.ralph"

setup() {
  TMPD="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMPD"
}

setup_dispatch_workspace() {
  local tmpd="$1"
  DISPATCH_WORKSPACE="$tmpd/workspace"
  mkdir -p "$DISPATCH_WORKSPACE/.ralph" "$DISPATCH_WORKSPACE/.ralph-workspace"
  cp -R "$RALPH_DIR"/* "$DISPATCH_WORKSPACE/.ralph/"
  chmod +x "$DISPATCH_WORKSPACE/.ralph"/*.sh 2>/dev/null || true
  cp "$STUB_RUN_PLAN" "$DISPATCH_WORKSPACE/.ralph/run-plan.sh"
  chmod +x "$DISPATCH_WORKSPACE/.ralph/run-plan.sh"
  export GRAPH_DISPATCH_ORCHESTRATOR="$DISPATCH_WORKSPACE/.ralph/orchestrator.sh"
  export RALPH_ALLOW_NESTED_RUNS=1
  export ORCHESTRATOR_RUNNER_TO_CONSOLE=0
  export RALPH_MODE=no
  export RALPH_ARTIFACT_SCHEMA_VALIDATION=0
  export RALPH_ARTIFACT_PROVENANCE=0
}

write_one_node_graph() {
  local path="$1" namespace="$2" node_id="$3"
  cat >"$path" <<EOF
{"schemaVersion":1,"ralphVersion":"test","name":"$namespace","namespace":"$namespace","maxParallel":1,"failurePolicy":"drain","nodes":[{"id":"$node_id","type":"agent","dependsOn":[],"derivedFrom":"stage","stage":{"id":"$node_id","runtime":"cursor","agent":"implementation","_inlineTodos":[{"id":"t","content":"Do it","status":"pending"}]}}],"edges":[]}
EOF
}

init_run_dir() {
  local run_dir="$1"
  mkdir -p "$run_dir"
}

@test "two runs with identical node and attempt numbers never share log files" {
  local fixture ns node_id run_a run_b attempt_a attempt_b dir_a dir_b rel_a rel_b abs_a abs_b
  fixture="$(jq -c '.fixture' "$FIXTURE_COLLISION")"
  ns="$(printf '%s' "$fixture" | jq -r '.namespace')"
  node_id="$(printf '%s' "$fixture" | jq -r '.nodeId')"
  run_a="$(printf '%s' "$fixture" | jq -r '.runs[0].runId')"
  run_b="$(printf '%s' "$fixture" | jq -r '.runs[1].runId')"
  attempt_a="$(printf '%s' "$fixture" | jq -r '.runs[0].attemptId')"
  attempt_b="$(printf '%s' "$fixture" | jq -r '.runs[1].attemptId')"
  dir_a="$TMPD/graph-runs/$ns/$run_a"
  dir_b="$TMPD/graph-runs/$ns/$run_b"
  init_run_dir "$dir_a"
  init_run_dir "$dir_b"

  rel_a="$(graph_logs_attempt_rel "$dir_a" "$node_id" "$attempt_a" runner.log)"
  rel_b="$(graph_logs_attempt_rel "$dir_b" "$node_id" "$attempt_b" runner.log)"
  abs_a="$(graph_logs_prepare_write "$dir_a" "$rel_a")"
  abs_b="$(graph_logs_prepare_write "$dir_b" "$rel_b")"
  printf 'run-a\n' >"$abs_a"
  printf 'run-b\n' >"$abs_b"

  [ "$abs_a" != "$abs_b" ]
  [ -f "$abs_a" ]
  [ -f "$abs_b" ]
  [ "$(cat "$abs_a")" = "run-a" ]
  [ "$(cat "$abs_b")" = "run-b" ]
  [[ "$rel_a" == logs/nodes/*/*/* ]]
  [[ "$rel_b" == logs/nodes/*/*/* ]]
}

@test "follow-up writes re-resolve and stay contained in the run-dir" {
  local run_dir rel abs
  run_dir="$TMPD/run-follow"
  init_run_dir "$run_dir"
  rel="$(graph_logs_supervisor_rel)"
  graph_logs_append "$run_dir" "$rel" "first"
  abs="$(graph_logs_resolve "$run_dir" "$rel")"
  [ "$(cat "$abs")" = "first" ]
  graph_logs_append "$run_dir" "$rel" "second"
  abs="$(graph_logs_resolve "$run_dir" "$rel")"
  grep -qx 'first' "$abs"
  grep -qx 'second' "$abs"
  run_real="$(graph_logs_real_dir "$run_dir")"
  [[ "$abs" == "$run_real/logs/supervisor.log" ]]
}

@test "v1 namespace paths remain readable and are never appended" {
  local run_dir state_root ns run_id v1_file v2_file
  state_root="$TMPD/state"
  ns="hist-ns"
  run_id="run-hist-1"
  run_dir="$state_root/graph-runs/$ns/$run_id"
  init_run_dir "$run_dir"
  v1_file="$(graph_logs_v1_supervisor "$state_root" "$ns" "$run_id")"
  mkdir -p "$(dirname "$v1_file")"
  printf 'historical supervisor\n' >"$v1_file"

  [ "$(graph_logs_read "$run_dir" "$(graph_logs_supervisor_rel)" "$v1_file")" = "$v1_file" ]

  graph_logs_append "$run_dir" "$(graph_logs_supervisor_rel)" "new-run-line"
  v2_file="$(graph_logs_resolve "$run_dir" "$(graph_logs_supervisor_rel)")"
  [ "$(cat "$v1_file")" = "historical supervisor" ]
  grep -qx 'new-run-line' "$v2_file"
  [ "$(graph_logs_read "$run_dir" "$(graph_logs_supervisor_rel)" "$v1_file")" = "$v2_file" ]
}

@test "absolute paths, dot-dot, and empty components are rejected" {
  local run_dir
  run_dir="$TMPD/run-reject"
  init_run_dir "$run_dir"

  run graph_logs_resolve "$run_dir" "/tmp/evil.log"
  [ "$status" -ne 0 ]
  run graph_logs_resolve "$run_dir" "logs/../evil.log"
  [ "$status" -ne 0 ]
  run graph_logs_resolve "$run_dir" "logs/nodes/../supervisor.log"
  [ "$status" -ne 0 ]
  run graph_logs_resolve "$run_dir" "logs//runner.log"
  [ "$status" -ne 0 ]
  run graph_logs_resolve "$run_dir" "logs/./runner.log"
  [ "$status" -ne 0 ]
  run graph_logs_sanitize_id "../etc"
  [ "$status" -ne 0 ]
  run graph_logs_sanitize_id "foo/bar"
  [ "$status" -ne 0 ]
}

@test "symlink escapes are rejected for resolve and follow-up writes" {
  local run_dir outside rel
  run_dir="$TMPD/run-link"
  outside="$TMPD/outside"
  init_run_dir "$run_dir"
  mkdir -p "$outside" "$run_dir/logs"
  printf 'secret\n' >"$outside/stolen.log"
  ln -s "$outside" "$run_dir/logs/nodes"

  run graph_logs_resolve "$run_dir" "logs/nodes/stolen.log"
  [ "$status" -ne 0 ]

  rel="$(graph_logs_supervisor_rel)"
  graph_logs_append "$run_dir" "$rel" "ok"
  rm -f "$run_dir/logs/supervisor.log"
  ln -s "$outside/stolen.log" "$run_dir/logs/supervisor.log"
  run graph_logs_append "$run_dir" "$rel" "pwn"
  [ "$status" -ne 0 ]
  [ "$(cat "$outside/stolen.log")" = "secret" ]
}

@test "identifiers that sanitize to the same token are rejected" {
  local run_dir
  run_dir="$TMPD/run-collide"
  init_run_dir "$run_dir"
  run graph_logs_claim_id "$run_dir" node "foo:bar"
  [ "$status" -eq 0 ]
  [ "$output" = "foo_bar" ]
  run graph_logs_claim_id "$run_dir" node "foo_bar"
  [ "$status" -ne 0 ]
}

@test "scheduled runs with the same node and attempt number write distinct contained files" {
  local tmpd graph_file marker_dir order_log ns node_id run_a run_b dir_a dir_b rel_a rel_b abs_a abs_b attempt
  tmpd="$(mktemp -d)"
  setup_dispatch_workspace "$tmpd"
  ns="sample-graph"
  node_id="node-fixture-shared"
  run_a="run-fixture-aaaa0001"
  run_b="run-fixture-bbbb0002"
  graph_file="$tmpd/shared.graph.json"
  write_one_node_graph "$graph_file" "$ns" "$node_id"
  marker_dir="$tmpd/markers"
  order_log="$tmpd/order.log"
  mkdir -p "$marker_dir"
  cp "$STUB_RUN_PLAN" "$DISPATCH_WORKSPACE/.ralph/run-plan.sh"
  chmod +x "$DISPATCH_WORKSPACE/.ralph/run-plan.sh"

  # Recreate the timed stub files the schedule tests use by writing a tiny runner.
  cat >"$DISPATCH_WORKSPACE/.ralph/run-plan.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
node="${RALPH_GRAPH_NODE_ID:-node}"
mkdir -p "${RALPH_GRAPH_NODE_LOG_DIR:-/tmp}"
if [[ -n "${RALPH_GRAPH_NODE_LOG_DIR:-}" ]]; then
  printf 'agent\n' >>"${RALPH_GRAPH_NODE_LOG_DIR}/agent.log"
  printf '{"invocations":1}\n' >"${RALPH_GRAPH_NODE_LOG_DIR}/usage.json"
fi
ns="${RALPH_ARTIFACT_NS:-graph}"
report_dir="${RALPH_PLAN_WORKSPACE_ROOT:-$PWD/.ralph-workspace}/artifacts/${ns}/stage-outcomes"
mkdir -p "$report_dir"
printf '{"attemptId":"%s","outcome":"succeeded","exitCode":0}\n' "${RALPH_GRAPH_ATTEMPT_ID:-x}" \
  >"$report_dir/${RALPH_GRAPH_ATTEMPT_ID:-x}.json"
exit 0
STUB
  chmod +x "$DISPATCH_WORKSPACE/.ralph/run-plan.sh"

  graph_schedule_run "$graph_file" "$run_a" "$DISPATCH_WORKSPACE"
  [ "$GRAPH_SCHEDULE_EXIT_CODE" -eq 0 ]
  graph_schedule_run "$graph_file" "$run_b" "$DISPATCH_WORKSPACE"
  [ "$GRAPH_SCHEDULE_EXIT_CODE" -eq 0 ]

  dir_a="$(graph_state_run_dir "$DISPATCH_WORKSPACE" "$ns" "$run_a")"
  dir_b="$(graph_state_run_dir "$DISPATCH_WORKSPACE" "$ns" "$run_b")"
  attempt="$(graph_dispatch_mint_attempt_id "$node_id" "$run_a" 1)"
  rel_a="$(graph_logs_attempt_rel "$dir_a" "$node_id" "$attempt" runner.log)"
  attempt="$(graph_dispatch_mint_attempt_id "$node_id" "$run_b" 1)"
  rel_b="$(graph_logs_attempt_rel "$dir_b" "$node_id" "$attempt" runner.log)"
  abs_a="$(graph_logs_resolve "$dir_a" "$rel_a")"
  abs_b="$(graph_logs_resolve "$dir_b" "$rel_b")"
  [ -f "$abs_a" ]
  [ -f "$abs_b" ]
  [ "$abs_a" != "$abs_b" ]
  [ -f "$dir_a/logs/supervisor.log" ]
  [ -f "$dir_b/logs/admission.jsonl" ]
  [ ! -e "$DISPATCH_WORKSPACE/.ralph-workspace/logs/$ns/nodes" ]
  rm -rf "$tmpd"
}

@test "retention removes only files owned by the pruned run ledger" {
  local workspace ns_dir stage_dir state_root decoy v1_pruned v1_kept
  workspace="$TMPD/ws"
  ns_dir="$workspace/.ralph-workspace/graph-runs/myns"
  stage_dir="$workspace/.ralph-workspace/artifacts/myns/stage-outcomes"
  state_root="$workspace/.ralph-workspace"
  mkdir -p "$ns_dir/run-pruned/logs/nodes/shared/shared__run-pruned__1" \
    "$ns_dir/run-kept/logs/nodes/shared/shared__run-kept__1" \
    "$ns_dir/run-pruned/nodes" "$ns_dir/run-kept/nodes" \
    "$state_root/logs/myns/nodes/shared" \
    "$stage_dir"
  printf '{"schemaVersion":2,"runId":"run-pruned","status":"succeeded"}\n' >"$ns_dir/run-pruned/run.json"
  printf '{"schemaVersion":2,"runId":"run-kept","status":"succeeded"}\n' >"$ns_dir/run-kept/run.json"
  printf 'pruned-runner\n' >"$ns_dir/run-pruned/logs/nodes/shared/shared__run-pruned__1/runner.log"
  printf 'kept-runner\n' >"$ns_dir/run-kept/logs/nodes/shared/shared__run-kept__1/runner.log"
  printf '{"schemaVersion":2,"nodeId":"shared","status":"succeeded","attempts":[{"attemptId":"shared__run-pruned__1","logPaths":{"runner":"logs/nodes/shared/shared__run-pruned__1/runner.log"}}]}\n' \
    >"$ns_dir/run-pruned/nodes/shared.json"
  printf '{"schemaVersion":2,"nodeId":"shared","status":"succeeded","attempts":[{"attemptId":"shared__run-kept__1","logPaths":{"runner":"logs/nodes/shared/shared__run-kept__1/runner.log"}}]}\n' \
    >"$ns_dir/run-kept/nodes/shared.json"

  decoy="$state_root/logs/myns/nodes/shared/attempt-1.log"
  printf 'shared-v1-decoy\n' >"$decoy"
  v1_pruned="$state_root/logs/myns/graph-schedule-run-pruned.log"
  v1_kept="$state_root/logs/myns/graph-schedule-run-kept.log"
  printf 'v1-pruned\n' >"$v1_pruned"
  printf 'v1-kept\n' >"$v1_kept"
  ln -sfn "run-kept" "$ns_dir/latest"

  RALPH_GRAPH_RUN_MAX_AGE_DAYS=9999 RALPH_GRAPH_RUN_MAX_COUNT=0 \
    cleanup_plan_prune_graph_runs "$workspace" "myns"

  [ ! -d "$ns_dir/run-pruned" ]
  [ -d "$ns_dir/run-kept" ]
  [ -f "$ns_dir/run-kept/logs/nodes/shared/shared__run-kept__1/runner.log" ]
  [ -f "$decoy" ]
  [ "$(cat "$decoy")" = "shared-v1-decoy" ]
  [ ! -f "$v1_pruned" ]
  [ -f "$v1_kept" ]
}
