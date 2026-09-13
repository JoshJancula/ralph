#!/usr/bin/env bash
set -euo pipefail
# Behavioral fixture for the graph ready-set scheduler
# (bundle/.ralph/bash-lib/graph/graph-schedule.sh).
#
# Verifies that a linear graph produces the same node execution order and exit
# code as orchestrator.sh on the equivalent .orch.json, that the diamond
# fixture runs its two middle nodes concurrently with the join after both,
# and that a missing StageOutcomeReport fails the run. Uses a stubbed
# run-plan.sh; never invokes a real AI CLI.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RALPH_DIR="$ROOT/bundle/.ralph"
FIXTURE_DIR="$ROOT/tests/fixtures/graph"
STUB_RUN_PLAN="$ROOT/tests/fixtures/orchestrator-single-stage/run-plan-stub.sh"
SCHEDULE_LIB="$RALPH_DIR/bash-lib/graph/graph-schedule.sh"

fail() {
  printf 'graph-scheduler: %s\n' "$1" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is required for this test"
command -v python3 >/dev/null 2>&1 || fail "python3 is required for this test"

# Keep the artifact namespace deterministic regardless of the invoking runner.
unset RALPH_ARTIFACT_NS 2>/dev/null || true
unset RALPH_PLAN_KEY 2>/dev/null || true

# shellcheck source=bundle/.ralph/bash-lib/plan-todo.sh
source "$RALPH_DIR/bash-lib/plan-todo.sh"
# shellcheck source=bundle/.ralph/bash-lib/graph/graph-schedule.sh
source "$SCHEDULE_LIB"

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/ralph-graph-sched-XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT

setup_workspace() {
  local workspace="$1"
  mkdir -p "$workspace/.ralph" "$workspace/.ralph-workspace"
  cp -R "$RALPH_DIR"/* "$workspace/.ralph/"
  chmod +x "$workspace/.ralph"/*.sh 2>/dev/null || true
  chmod +x "$workspace/.ralph/bash-lib"/*/*.sh 2>/dev/null || true
  cp "$STUB_RUN_PLAN" "$workspace/.ralph/run-plan.sh"
  chmod +x "$workspace/.ralph/run-plan.sh"
}

install_stage_aware_run_plan() {
  local workspace="$1" order_log="$2" marker_dir="$3"
  local stub_src="$workspace/.ralph/run-plan.sh"
  local stub_real="$workspace/.ralph/run-plan.stub-real.sh"
  mv "$stub_src" "$stub_real"
  cat >"$stub_src" <<EOF
#!/usr/bin/env bash
set -euo pipefail
ORDER_LOG="$order_log"
MARKER_DIR="$marker_dir"
STAGE="\${RALPH_STAGE_ID:-unknown}"
mkdir -p "\$MARKER_DIR" "\$(dirname "\$ORDER_LOG")"
printf '%s\n' "\$STAGE" >>"\$ORDER_LOG"
date +%s >"\$MARKER_DIR/\$STAGE.started_at"
: >"\$MARKER_DIR/\$STAGE.started"
case "\$STAGE" in
  source) export RUN_PLAN_STUB_WRITE_ARTIFACTS="shared/input.md" ;;
  transform) export RUN_PLAN_STUB_WRITE_ARTIFACTS="shared/output.md" ;;
  left) export RUN_PLAN_STUB_WRITE_ARTIFACTS="shared/left.md" ;;
  right) export RUN_PLAN_STUB_WRITE_ARTIFACTS="shared/right.md" ;;
  sink) export RUN_PLAN_STUB_WRITE_ARTIFACTS="" ;;
  *) export RUN_PLAN_STUB_WRITE_ARTIFACTS="\${RUN_PLAN_STUB_WRITE_ARTIFACTS:-}" ;;
esac
if [[ "\$STAGE" == "left" || "\$STAGE" == "right" ]]; then
  # Hold long enough that staggered orch startup still overlaps on distinct runtimes.
  sleep 3
fi
date +%s >"\$MARKER_DIR/\$STAGE.finished_at"
: >"\$MARKER_DIR/\$STAGE.finished"
export RALPH_RUN_PLAN_CAPTURE_FILE="\$MARKER_DIR/capture-\$STAGE.json"
export RUN_PLAN_STUB_EXIT_CODE="\${RUN_PLAN_STUB_EXIT_CODE:-0}"
exec "$stub_real" "\$@"
EOF
  chmod +x "$stub_src"
}

# Build a sequential .orch.json equivalent: materialize (expands inline todos)
# then reorder stages into topological execution order for the orch loop.
build_sequential_orch_from_graph() {
  local graph_json="$1" workspace="$2" out_path="$3"
  local flat_orch
  flat_orch="$(graph_dispatch_materialize_orch "$graph_json" "$workspace")" || return 1
  jq '
    . as $o
    | .stages = [
        ("source"), ("transform"), ("sink")
        | . as $id
        | ($o.stages[] | select(.id == $id))
      ]
  ' "$flat_orch" >"$out_path"
}

export ORCHESTRATOR_RUNNER_TO_CONSOLE=0
export RALPH_MODE=no
export RALPH_ARTIFACT_SCHEMA_VALIDATION=0
export RALPH_ARTIFACT_PROVENANCE=0
export RALPH_ALLOW_NESTED_RUNS=1
export RUN_PLAN_STUB_EXIT_CODE=0
unset RUN_PLAN_STUB_SLEEP_SECONDS RUN_PLAN_STUB_READY_FILE 2>/dev/null || true

# ---------------------------------------------------------------------------
# 1. Linear graph: scheduler order + exit match orchestrator.sh on .orch.json
# ---------------------------------------------------------------------------
linear_ws="$tmpdir/linear-ws"
setup_workspace "$linear_ws"
linear_plan="$linear_ws/graph-edges.plan.md"
cp "$FIXTURE_DIR/graph-edges.plan.md" "$linear_plan"
linear_graph="$tmpdir/linear.graph.json"
plan_pipeline_graph_json "$linear_plan" >"$linear_graph"

mkdir -p "$linear_ws/.ralph-workspace/orchestration-plans"
linear_orch="$linear_ws/.ralph-workspace/orchestration-plans/linear-seq.orch.json"
build_sequential_orch_from_graph "$linear_graph" "$linear_ws" "$linear_orch" \
  || fail "failed to build sequential orch"

orch_order_log="$tmpdir/orch-order.log"
orch_markers="$tmpdir/orch-markers"
mkdir -p "$orch_markers"
install_stage_aware_run_plan "$linear_ws" "$orch_order_log" "$orch_markers"

orch_rc=0
unset RALPH_ARTIFACT_NS RALPH_PLAN_KEY 2>/dev/null || true
"$linear_ws/.ralph/orchestrator.sh" \
  --orchestration "$linear_orch" \
  "$linear_ws" \
  >"$tmpdir/orch-linear.out" 2>"$tmpdir/orch-linear.err" || orch_rc=$?

[ "$orch_rc" -eq 0 ] || fail "orchestrator linear run failed rc=$orch_rc err=$(tail -n 40 "$tmpdir/orch-linear.err")"
orch_order="$(tr '\n' ',' <"$orch_order_log")"
[ "$orch_order" = "source,transform,sink," ] || fail "orchestrator order=$orch_order"

# Fresh workspace for the scheduler so artifacts/order do not collide.
sched_ws="$tmpdir/sched-ws"
setup_workspace "$sched_ws"
sched_plan="$sched_ws/graph-edges.plan.md"
cp "$FIXTURE_DIR/graph-edges.plan.md" "$sched_plan"
sched_graph="$tmpdir/sched.graph.json"
plan_pipeline_graph_json "$sched_plan" >"$sched_graph"
sched_order_log="$tmpdir/sched-order.log"
sched_markers="$tmpdir/sched-markers"
mkdir -p "$sched_markers"
install_stage_aware_run_plan "$sched_ws" "$sched_order_log" "$sched_markers"
export GRAPH_DISPATCH_ORCHESTRATOR="$sched_ws/.ralph/orchestrator.sh"

sched_rc=0
unset RALPH_ARTIFACT_NS RALPH_PLAN_KEY 2>/dev/null || true
graph_schedule_run "$sched_graph" "linear-beh" "$sched_ws" || sched_rc=$?
[ "$sched_rc" -eq 0 ] || fail "scheduler linear run failed rc=$sched_rc"
sched_order="$(tr '\n' ',' <"$sched_order_log")"
[ "$sched_order" = "$orch_order" ] || fail "order mismatch orch=$orch_order sched=$sched_order"
[ "$sched_rc" -eq "$orch_rc" ] || fail "exit mismatch orch=$orch_rc sched=$sched_rc"
printf 'linear: order=%s exit=%s (matches orchestrator)\n' "$sched_order" "$sched_rc"

# ---------------------------------------------------------------------------
# 2. Diamond: middle nodes concurrent; sink after both
# ---------------------------------------------------------------------------
diamond_ws="$tmpdir/diamond-ws"
setup_workspace "$diamond_ws"
diamond_plan="$diamond_ws/graph-diamond.plan.md"
cp "$FIXTURE_DIR/graph-diamond.plan.md" "$diamond_plan"
diamond_graph="$tmpdir/diamond.graph.json"
plan_pipeline_graph_json "$diamond_plan" >"$diamond_graph"
[ "$(jq -r '.maxParallel' "$diamond_graph")" = "2" ] || fail "diamond maxParallel expected 2"

diamond_order="$tmpdir/diamond-order.log"
diamond_markers="$tmpdir/diamond-markers"
mkdir -p "$diamond_markers"
install_stage_aware_run_plan "$diamond_ws" "$diamond_order" "$diamond_markers"
export GRAPH_DISPATCH_ORCHESTRATOR="$diamond_ws/.ralph/orchestrator.sh"

diamond_rc=0
unset RALPH_ARTIFACT_NS RALPH_PLAN_KEY 2>/dev/null || true
graph_schedule_run "$diamond_graph" "diamond-beh" "$diamond_ws" || diamond_rc=$?
[ "$diamond_rc" -eq 0 ] || fail "diamond scheduler failed rc=$diamond_rc"

left_start="$(cat "$diamond_markers/left.started_at")"
left_end="$(cat "$diamond_markers/left.finished_at")"
right_start="$(cat "$diamond_markers/right.started_at")"
right_end="$(cat "$diamond_markers/right.finished_at")"
sink_start="$(cat "$diamond_markers/sink.started_at")"
if ! { [ "$left_start" -lt "$right_end" ] && [ "$right_start" -lt "$left_end" ]; }; then
  fail "diamond middle nodes did not overlap left=[$left_start,$left_end] right=[$right_start,$right_end]"
fi
[ "$sink_start" -ge "$left_end" ] || fail "sink started before left finished"
[ "$sink_start" -ge "$right_end" ] || fail "sink started before right finished"

source_line="$(grep -n '^source$' "$diamond_order" | head -n1 | cut -d: -f1)"
left_line="$(grep -n '^left$' "$diamond_order" | head -n1 | cut -d: -f1)"
right_line="$(grep -n '^right$' "$diamond_order" | head -n1 | cut -d: -f1)"
sink_line="$(grep -n '^sink$' "$diamond_order" | head -n1 | cut -d: -f1)"
[ "$source_line" -lt "$left_line" ] || fail "source must precede left"
[ "$source_line" -lt "$right_line" ] || fail "source must precede right"
[ "$left_line" -lt "$sink_line" ] || fail "left must precede sink"
[ "$right_line" -lt "$sink_line" ] || fail "right must precede sink"
printf 'diamond: concurrent middle nodes confirmed; sink after join\n'

# ---------------------------------------------------------------------------
# 3. Missing StageOutcomeReport is treated as failure
# ---------------------------------------------------------------------------
miss_ws="$tmpdir/miss-ws"
setup_workspace "$miss_ws"
miss_plan="$miss_ws/graph-edges.plan.md"
cp "$FIXTURE_DIR/graph-edges.plan.md" "$miss_plan"
miss_graph="$tmpdir/miss.graph.json"
plan_pipeline_graph_json "$miss_plan" >"$miss_graph"

miss_ns="$(jq -r '.namespace' "$miss_graph")"
cat >"$miss_ws/.ralph/orchestrator.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
attempt=""
prev=""
for arg in "\$@"; do
  if [[ "\$prev" == "--attempt-id" ]]; then
    attempt="\$arg"
  fi
  prev="\$arg"
done
workspace="\${@: -1}"
report="\$workspace/.ralph-workspace/artifacts/$miss_ns/stage-outcomes/\${attempt}.json"
mkdir -p "\$(dirname "\$report")"
printf '%s\n' '{"schemaVersion":1,"runId":"miss-beh","stageId":"source","attemptId":"'"\$attempt"'","outcome":"success","exitCode":0,"startedAt":"2026-01-01T00:00:00Z","finishedAt":"2026-01-01T00:00:01Z"}' >"\$report"
rm -f "\$report"
exit 0
EOF
chmod +x "$miss_ws/.ralph/orchestrator.sh"
export GRAPH_DISPATCH_ORCHESTRATOR="$miss_ws/.ralph/orchestrator.sh"

miss_rc=0
unset RALPH_ARTIFACT_NS RALPH_PLAN_KEY 2>/dev/null || true
graph_schedule_run "$miss_graph" "miss-beh" "$miss_ws" || miss_rc=$?
[ "$miss_rc" -ne 0 ] || fail "missing-report run should fail"
[ "$(graph_schedule_node_state_by_id source)" = "failed" ] || fail "source should be failed"
[ "$(graph_schedule_node_state_by_id transform)" = "blocked" ] || fail "transform should be blocked"
[ "$(graph_schedule_node_state_by_id sink)" = "blocked" ] || fail "sink should be blocked"
printf 'missing-report: failed as expected rc=%s node=%s\n' "$miss_rc" "$GRAPH_SCHEDULE_FAILED_NODE"

printf 'graph-scheduler: all behavioral checks passed\n'
exit 0
