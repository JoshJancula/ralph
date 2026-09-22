#!/usr/bin/env bash
# Shared fixtures and helpers for the graph-resume suites.
#
# graph-resume.bats keeps the library-level tests. graph-resume-e2e.bats keeps the
# tests that drive a real dispatch: each boots the orchestrator and
# run-plan once per node, so they run in the acceptance tier rather than
# on the pull-request path.
#
# This is the non-@test body of the original graph-resume.bats in its original
# order. Several helpers are emitted inside heredocs and depend on that
# ordering, so do not reorder.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/plan-todo.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-state.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-schedule.sh"

DIAMOND_PLAN="$BATS_TEST_DIRNAME/../../fixtures/graph/graph-diamond.plan.md"
EDGES_PLAN="$BATS_TEST_DIRNAME/../../fixtures/graph/graph-edges.plan.md"
STUB_RUN_PLAN="$BATS_TEST_DIRNAME/../../fixtures/orchestrator-single-stage/run-plan-stub.sh"
RALPH_DIR="$REPO_ROOT/bundle/.ralph"
SCHEDULE_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-schedule.sh"

json_payload() {
  printf '%s\n' "$1" | awk 'END{print}'
}

# Compile a plan fixture into a fresh workspace and print the graph path.
compile_graph() {
  local src_plan="$1"
  local workspace="$2"
  local out_path="$3"
  local plan_file="$workspace/$(basename "$src_plan")"
  cp "$src_plan" "$plan_file"
  plan_pipeline_graph_json "$plan_file" > "$out_path"
}








# --- p3-resume: graph_schedule_resume ----------------------------------------

# Prepare a scratch workspace with a stubbed run-plan. Mirrors the setup in
# graph-schedule.bats so the scheduler can dispatch real single-stage children.
setup_dispatch_workspace() {
  local tmpd="$1"
  DISPATCH_WORKSPACE="$tmpd/workspace"
  mkdir -p "$DISPATCH_WORKSPACE/.ralph" "$DISPATCH_WORKSPACE/.ralph-workspace"

  cp -R "$RALPH_DIR"/* "$DISPATCH_WORKSPACE/.ralph/"
  chmod +x "$DISPATCH_WORKSPACE/.ralph"/*.sh 2>/dev/null || true
  chmod +x "$DISPATCH_WORKSPACE/.ralph/bash-lib"/*/*.sh 2>/dev/null || true

  cp "$STUB_RUN_PLAN" "$DISPATCH_WORKSPACE/.ralph/run-plan.sh"
  chmod +x "$DISPATCH_WORKSPACE/.ralph/run-plan.sh"

  export GRAPH_DISPATCH_ORCHESTRATOR="$DISPATCH_WORKSPACE/.ralph/orchestrator.sh"
  export RALPH_ALLOW_NESTED_RUNS=1
  export ORCHESTRATOR_RUNNER_TO_CONSOLE=0
  export RALPH_MODE=no
  export RALPH_ARTIFACT_SCHEMA_VALIDATION=0
  export RALPH_ARTIFACT_PROVENANCE=0
  unset RALPH_ARTIFACT_NS 2>/dev/null || true
  unset RALPH_PLAN_KEY 2>/dev/null || true
}

compile_plan_graph_to() {
  local src_plan="$1" workspace="$2" out_path="$3"
  local plan_file="$workspace/$(basename "$src_plan")"
  cp "$src_plan" "$plan_file"
  plan_pipeline_graph_json "$plan_file" > "$out_path"
}

# Install a lightweight single-stage orchestrator driven by per-stage behavior
# files under behavior_dir: success | fail:<ec> | sleep:<sec>
install_behavior_orchestrator() {
  local workspace="$1" ns="$2" run_id="$3" behavior_dir="$4" marker_dir="$5"
  mkdir -p "$behavior_dir" "$marker_dir"
  cat >"$workspace/.ralph/orchestrator.sh" <<EOF
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
  sleep:*)
    sec="\${behavior#sleep:}"
    [[ "\$sec" =~ ^[0-9]+([.][0-9]+)?$ ]] || sec=2
    sleep "\$sec"
    write_report success 0
    : >"\$marker_dir/\$stage.finished"
    exit 0
    ;;
  *)
    write_report success 0
    : >"\$marker_dir/\$stage.finished"
    exit 0
    ;;
esac
EOF
  chmod +x "$workspace/.ralph/orchestrator.sh"
  export GRAPH_DISPATCH_ORCHESTRATOR="$workspace/.ralph/orchestrator.sh"
}

# Start a graph run with the ledger, optionally killing the scheduler parent
# mid-run to simulate a crashed scheduler. Leaves the ledger on disk.
start_ledgered_run() {
  # $1=graph_file $2=workspace $3=run_id $4=kill_after_marker (optional)
  local graph_file="$1" workspace="$2" run_id="$3" kill_marker="${4:-}"
  local run_dir
  run_dir="$(graph_state_run_dir "$workspace" "$(jq -r '.namespace' "$graph_file")" "$run_id")"
  graph_state_init_run "$workspace" "$(jq -r '.namespace' "$graph_file")" \
    "$run_id" "$workspace/$(basename "$graph_file" .graph.json).plan.md" "$graph_file" 2
  graph_schedule_run "$graph_file" "$run_id" "$workspace" "$run_dir" &
  local sched_pid=$!
  if [[ -n "$kill_marker" ]]; then
    local waited=0
    while [[ ! -f "$kill_marker" && "$waited" -lt 60 ]]; do
      sleep 0.25
      waited=$((waited + 1))
    done
    kill -KILL "$sched_pid" 2>/dev/null || true
    wait "$sched_pid" 2>/dev/null || true
  else
    wait "$sched_pid" 2>/dev/null || true
  fi
}
