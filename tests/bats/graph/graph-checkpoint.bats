#!/usr/bin/env bats
# Tests for p5-checkpoint-node:
#  - checkpoint node enters awaiting-ack while independent branches complete
#  - run exits with code 3 (awaiting-ack), not hard failure
#  - resume with ack file present completes the subtree
#  - resume without ack file is a clean no-op preserving awaiting-ack state

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/plan-todo.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-state.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-schedule.sh"

RALPH_DIR="$REPO_ROOT/bundle/.ralph"
CHECKPOINT_PLAN="$BATS_TEST_DIRNAME/../../fixtures/graph/graph-checkpoint.plan.md"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

set_checkpoint_state() {
  local ws="$1" ns="$2" run_id="$3" node_id="$4" state="$5"
  local aid="${node_id}__${run_id}__1"
  case "$state" in
    running)
      graph_state_write_node "$ws" "$ns" "$run_id" "$node_id" running "$aid" \
        '{"startedAt":"2026-01-01T00:00:00Z"}' >/dev/null
      ;;
    succeeded|awaiting-ack)
      graph_state_write_node "$ws" "$ns" "$run_id" "$node_id" running "$aid" \
        '{"startedAt":"2026-01-01T00:00:00Z"}' >/dev/null
      graph_state_write_node "$ws" "$ns" "$run_id" "$node_id" "$state" "$aid" \
        "{\"outcome\":\"$state\",\"finishedAt\":\"2026-01-01T00:01:00Z\"}" >/dev/null
      ;;
    blocked)
      graph_state_write_node "$ws" "$ns" "$run_id" "$node_id" blocked >/dev/null
      ;;
    *)
      graph_state_write_node "$ws" "$ns" "$run_id" "$node_id" "$state" >/dev/null
      ;;
  esac
}

# Write a checkpoint graph JSON to out_path.
# Graph structure:
#   gate       - checkpoint node (blocks after-gate)
#   independent - agent node (no dependencies; runs in parallel with gate)
#   after-gate  - agent node (depends on gate)
# Edges: gate -> after-gate
write_checkpoint_graph() {
  local out_path="$1" ns="$2" max_parallel="${3:-2}"
  python3 - "$out_path" "$ns" "$max_parallel" <<'PY'
import json, sys
out_path, ns, max_parallel = sys.argv[1], sys.argv[2], int(sys.argv[3])
doc = {
    "schemaVersion": 2,
    "ralphVersion": "1.0.0",
    "name": ns,
    "namespace": ns,
    "maxParallel": max_parallel,
    "failurePolicy": "drain",
    "nodes": [
        {
            "id": "gate",
            "type": "checkpoint",
            "dependsOn": [],
            "derivedFrom": "declared",
            "stage": {"id": "gate", "type": "checkpoint"},
        },
        {
            "id": "independent",
            "type": "agent",
            "dependsOn": [],
            "derivedFrom": "declared",
            "stage": {
                "id": "independent",
                "runtime": "claude",
                "_inlineTodos": [
                    {"id": "independent-1", "content": "work independent",
                     "verification": "ok", "status": "pending"}
                ],
            },
        },
        {
            "id": "after-gate",
            "type": "agent",
            "dependsOn": ["gate"],
            "derivedFrom": "declared",
            "stage": {
                "id": "after-gate",
                "runtime": "claude",
                "_inlineTodos": [
                    {"id": "after-gate-1", "content": "work after gate",
                     "verification": "ok", "status": "pending"}
                ],
            },
        },
    ],
    "edges": [
        {"from": "gate", "to": "after-gate", "reasons": ["declared"]}
    ],
}
with open(out_path, "w", encoding="utf-8") as fh:
    json.dump(doc, fh)
PY
}

# Prepare a scratch workspace with a behavior orchestrator.
# behavior_dir files: success | fail:<ec>
setup_checkpoint_workspace() {
  local tmpd="$1" ns="$2" run_id="$3"
  DISPATCH_WORKSPACE="$tmpd/workspace"
  mkdir -p "$DISPATCH_WORKSPACE/.ralph" "$DISPATCH_WORKSPACE/.ralph-workspace"

  cp -R "$RALPH_DIR"/* "$DISPATCH_WORKSPACE/.ralph/"
  chmod +x "$DISPATCH_WORKSPACE/.ralph"/*.sh 2>/dev/null || true
  chmod +x "$DISPATCH_WORKSPACE/.ralph/bash-lib"/*/*.sh 2>/dev/null || true

  local behavior_dir="$tmpd/behavior"
  local marker_dir="$tmpd/markers"
  mkdir -p "$behavior_dir" "$marker_dir"

  # Install a lightweight orchestrator so agent nodes (independent, after-gate)
  # complete successfully. Checkpoint nodes are never dispatched to this
  # orchestrator; they are handled directly by the scheduler.
  cat >"$DISPATCH_WORKSPACE/.ralph/orchestrator.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
attempt=""
stage=""
prev=""
for arg in "\$@"; do
  if [[ "\$prev" == "--attempt-id" ]]; then
    attempt="\$arg"
  elif [[ "\$prev" == "--single-stage" ]]; then
    stage="\$arg"
  fi
  prev="\$arg"
done
workspace="\${@: -1}"
ns="$ns"
run_id="$run_id"
behavior_dir="$behavior_dir"
marker_dir="$marker_dir"
report="\$workspace/.ralph-workspace/artifacts/\$ns/stage-outcomes/\${attempt}.json"
mkdir -p "\$(dirname "\$report")" "\$marker_dir"
printf '%s\n' "\$\$" >"\$marker_dir/\$stage.pid"
: >"\$marker_dir/\$stage.started"

write_report() {
  local outcome="\$1" exit_code="\$2"
  printf '%s\n' "{\"schemaVersion\":1,\"runId\":\"\$run_id\",\"stageId\":\"\$stage\",\"attemptId\":\"\$attempt\",\"outcome\":\"\$outcome\",\"exitCode\":\$exit_code,\"startedAt\":\"2026-01-01T00:00:00Z\",\"finishedAt\":\"2026-01-01T00:00:01Z\"}" >"\$report"
}

behavior="success"
if [[ -f "\$behavior_dir/\$stage" ]]; then
  behavior="\$(cat "\$behavior_dir/\$stage")"
fi

case "\$behavior" in
  fail:*)
    ec="\${behavior#fail:}"
    [[ "\$ec" =~ ^[0-9]+$ ]] || ec=1
    write_report failed "\$ec"
    : >"\$marker_dir/\$stage.finished"
    exit "\$ec"
    ;;
  *)
    write_report success 0
    : >"\$marker_dir/\$stage.finished"
    exit 0
    ;;
esac
EOF
  chmod +x "$DISPATCH_WORKSPACE/.ralph/orchestrator.sh"

  export GRAPH_DISPATCH_ORCHESTRATOR="$DISPATCH_WORKSPACE/.ralph/orchestrator.sh"
  export RALPH_ALLOW_NESTED_RUNS=1
  export ORCHESTRATOR_RUNNER_TO_CONSOLE=0
  export RALPH_MODE=no
  export RALPH_ARTIFACT_SCHEMA_VALIDATION=0
  export RALPH_ARTIFACT_PROVENANCE=0
  unset RALPH_ARTIFACT_NS 2>/dev/null || true
  unset RALPH_PLAN_KEY 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Test: checkpoint + independent branch; no ack file
# ---------------------------------------------------------------------------

@test "checkpoint awaiting-ack while independent branch runs to completion" {
  command -v python3 >/dev/null || skip "python3 required"
  tmpd="$(mktemp -d)"
  ns="ckpt-basic"
  run_id="ckpt-basic-run-1"
  setup_checkpoint_workspace "$tmpd" "$ns" "$run_id"
  graph_file="$tmpd/ckpt-basic.graph.json"
  write_checkpoint_graph "$graph_file" "$ns" 3

  export RALPH_GRAPH_MAX_PARALLEL=3
  export RALPH_GRAPH_MAX_PARALLEL_PER_RUNTIME=2

  rc=0
  graph_schedule_run "$graph_file" "$run_id" "$DISPATCH_WORKSPACE" || rc=$?

  # Run exits with code 3 (awaiting-ack), not hard failure.
  [ "$rc" -eq 3 ]

  # checkpoint node: awaiting-ack.
  [ "$(graph_schedule_node_state_by_id gate)" = "awaiting-ack" ]

  # independent branch ran to completion.
  [ "$(graph_schedule_node_state_by_id independent)" = "succeeded" ]
  [ -f "$tmpd/markers/independent.finished" ]

  # after-gate is blocked (subtree of the checkpoint).
  [ "$(graph_schedule_node_state_by_id after-gate)" = "blocked" ]
  [ ! -f "$tmpd/markers/after-gate.started" ]

  rm -rf "$tmpd"
}

# ---------------------------------------------------------------------------
# Test: run exits with awaiting-ack code 3, not a hard failure code
# ---------------------------------------------------------------------------

@test "checkpoint run exits with code 3 distinct from hard failure" {
  command -v python3 >/dev/null || skip "python3 required"
  tmpd="$(mktemp -d)"
  ns="ckpt-ec"
  run_id="ckpt-ec-run-1"
  setup_checkpoint_workspace "$tmpd" "$ns" "$run_id"
  graph_file="$tmpd/ckpt-ec.graph.json"
  write_checkpoint_graph "$graph_file" "$ns" 2

  export RALPH_GRAPH_MAX_PARALLEL=2
  export RALPH_GRAPH_MAX_PARALLEL_PER_RUNTIME=2

  rc=0
  graph_schedule_run "$graph_file" "$run_id" "$DISPATCH_WORKSPACE" || rc=$?

  # Specifically exit 3 (awaiting-ack sentinel), not 1 (generic failure).
  [ "$rc" -eq 3 ]
  # No failure was recorded -- no GRAPH_SCHEDULE_FAILED_NODE set.
  [ -z "$GRAPH_SCHEDULE_FAILED_NODE" ]

  rm -rf "$tmpd"
}

# ---------------------------------------------------------------------------
# Test: ack path derivation
# ---------------------------------------------------------------------------

@test "_graph_schedule_checkpoint_ack_path returns derived path under workspace" {
  command -v python3 >/dev/null || skip "python3 required"
  tmpd="$(mktemp -d)"
  ns="ckpt-path"
  run_id="ckpt-path-run"
  setup_checkpoint_workspace "$tmpd" "$ns" "$run_id"
  graph_file="$tmpd/ckpt-path.graph.json"
  write_checkpoint_graph "$graph_file" "$ns" 2

  # Load the index so node context is available.
  graph_schedule_load_index "$graph_file"
  GRAPH_SCHEDULE_WORKSPACE="$DISPATCH_WORKSPACE"
  GRAPH_SCHEDULE_NAMESPACE="$ns"

  ack_path="$(_graph_schedule_checkpoint_ack_path "gate")"
  expected="$DISPATCH_WORKSPACE/.ralph-workspace/artifacts/$ns/checkpoints/gate.ack"
  [ "$ack_path" = "$expected" ]

  rm -rf "$tmpd"
}

# ---------------------------------------------------------------------------
# Test: resume before ack file -- clean no-op preserving awaiting-ack
# ---------------------------------------------------------------------------

@test "resuming without ack file is a clean no-op preserving awaiting-ack" {
  command -v python3 >/dev/null || skip "python3 required"
  tmpd="$(mktemp -d)"
  # The fixture plan has namespace: checkpoint-test (explicit, from the name: field).
  ns="checkpoint-test"
  run_id="ckpt-noop-run-1"
  setup_checkpoint_workspace "$tmpd" "$ns" "$run_id"
  ws="$DISPATCH_WORKSPACE"

  # Compile the plan fixture to a graph file for this run.
  plan_file="$ws/graph-checkpoint.plan.md"
  cp "$CHECKPOINT_PLAN" "$plan_file"
  graph_file="$tmpd/ckpt-noop.graph.json"
  plan_pipeline_graph_json "$plan_file" >"$graph_file" 2>/dev/null

  export RALPH_GRAPH_MAX_PARALLEL=3
  export RALPH_GRAPH_MAX_PARALLEL_PER_RUNTIME=2

  # Initialize the ledger with checkpoint awaiting-ack state (simulating a
  # prior run that stopped at the checkpoint).
  graph_state_init_run "$ws" "$ns" "$run_id" "$plan_file" "$graph_file" 3 2>/dev/null || true
  set_checkpoint_state "$ws" "$ns" "$run_id" gate awaiting-ack
  set_checkpoint_state "$ws" "$ns" "$run_id" independent succeeded
  set_checkpoint_state "$ws" "$ns" "$run_id" after-gate blocked

  # Resume without creating the ack file: should be a clean no-op.
  rc2=0
  graph_schedule_resume "$ws" "$ns" "$run_id" "$plan_file" \
    --frozen-graph "$graph_file" || rc2=$?

  # Still awaiting-ack (code 3), not a hard failure.
  [ "$rc2" -eq 3 ]

  # gate must still be awaiting-ack after resume.
  [ "$(graph_schedule_node_state_by_id gate)" = "awaiting-ack" ]
  # after-gate must not have been dispatched.
  [ ! -f "$tmpd/markers/after-gate.started" ]

  rm -rf "$tmpd"
}

# ---------------------------------------------------------------------------
# Test: resume after ack file appears -- subtree completes
# ---------------------------------------------------------------------------

@test "resuming after ack file appears completes the checkpoint subtree" {
  command -v python3 >/dev/null || skip "python3 required"
  tmpd="$(mktemp -d)"
  # The fixture plan has namespace: checkpoint-test (explicit, from the name: field).
  ns="checkpoint-test"
  run_id="ckpt-ack-run-1"
  setup_checkpoint_workspace "$tmpd" "$ns" "$run_id"
  ws="$DISPATCH_WORKSPACE"

  # Compile the plan fixture to a graph file for this run.
  plan_file="$ws/graph-checkpoint.plan.md"
  cp "$CHECKPOINT_PLAN" "$plan_file"
  graph_file="$tmpd/ckpt-ack.graph.json"
  plan_pipeline_graph_json "$plan_file" >"$graph_file" 2>/dev/null

  export RALPH_GRAPH_MAX_PARALLEL=3
  export RALPH_GRAPH_MAX_PARALLEL_PER_RUNTIME=2

  # Initialize ledger with the prior awaiting-ack state.
  graph_state_init_run "$ws" "$ns" "$run_id" "$plan_file" "$graph_file" 3 2>/dev/null || true
  set_checkpoint_state "$ws" "$ns" "$run_id" gate awaiting-ack
  set_checkpoint_state "$ws" "$ns" "$run_id" independent succeeded
  set_checkpoint_state "$ws" "$ns" "$run_id" after-gate blocked

  # Create the ack file to simulate human acknowledgement.
  # The ack path is derived from the namespace used by the scheduler.
  ack_dir="$ws/.ralph-workspace/artifacts/$ns/checkpoints"
  mkdir -p "$ack_dir"
  touch "$ack_dir/gate.ack"

  # Resume: checkpoint transitions to succeeded, after-gate unblocks and runs.
  rc=0
  graph_schedule_resume "$ws" "$ns" "$run_id" "$plan_file" \
    --frozen-graph "$graph_file" || rc=$?

  # Run completes successfully.
  [ "$rc" -eq 0 ]

  # gate transitioned to succeeded.
  [ "$(graph_schedule_node_state_by_id gate)" = "succeeded" ]
  # after-gate ran and succeeded (no longer blocked).
  [ "$(graph_schedule_node_state_by_id after-gate)" = "succeeded" ]
  [ -f "$tmpd/markers/after-gate.finished" ]

  rm -rf "$tmpd"
}
