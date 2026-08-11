#!/usr/bin/env bats
# Tests for the pipeline.repairRounds compile-time authoring macro
# (v2-repair-epochs).
#
# Coverage:
#   - Compile: zero rounds emits only the entry integrate/gate/passed-join,
#     no diagnose/lane/reintegrate/regate nodes, no changes-required edge.
#   - Compile: one round emits exactly one diagnose/lane/reintegrate/regate
#     set, and the (only, therefore last) round's regate omits the
#     changes-required edge (fail-closed at exhaustion).
#   - Compile: max rounds (hard ceiling 5) compiles; rounds beyond the ceiling
#     are rejected at compile time.
#   - Compile: multiple rounds converge every regate's passed edge onto one
#     stable join id, and only the final round omits changes-required.
#   - Compile: graph hash / byte-identical output stability across repeated
#     compiles of the same source.
#   - Render: expanded round/lane node ids are visible in mermaid and ascii
#     output.
#   - Scheduler: first-pass success releases the join via the entry gate's
#     passed edge without ever touching round nodes.
#   - Scheduler: one repair round routes changes-required into round 1 and
#     back out through the join without double-releasing it.
#   - Scheduler: multiple repair rounds cascade changes-required from round 1
#     into round 2 and converge on the join once exactly.
#   - Scheduler: exhaustion (every round changes-required) fails closed
#     (rc=2) rather than declaring success.
#   - Resume: reconciling a ledger-succeeded gate with a recorded
#     changes-required outcome mid-round replays the correct branch instead
#     of deadlocking or re-running.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/plan-todo.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-state.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-schedule.sh"
if ! command -v graph_render_stub >/dev/null 2>&1; then
  source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-render.sh"
fi

FIXTURE_DIR="$BATS_TEST_DIRNAME/../../fixtures/graph"
ARTIFACT_LOG="$BATS_TEST_DIRNAME/../../../.ralph-workspace/artifacts/graph-engineering-v2/repair-epochs.log"
mkdir -p "$(dirname "$ARTIFACT_LOG")"

log_result() {
  printf '%s\n' "$1" >>"$ARTIFACT_LOG"
}

compile_fixture_to() {
  local fixture_name="$1" workspace="$2" out_path="$3"
  local plan_file="$workspace/$(basename "$fixture_name")"
  cp "$FIXTURE_DIR/$fixture_name" "$plan_file"
  plan_pipeline_graph_json "$plan_file" >"$out_path"
}

setup() {
  TMPD="$(mktemp -d)"
}

teardown() {
  log_result "$BATS_TEST_NAME: $BATS_TEST_COMPLETED"
  rm -rf "$TMPD"
}

# ---------------------------------------------------------------------------
# Compile
# ---------------------------------------------------------------------------

@test "compile: zero rounds emits only entry integrate/gate/passed-join, no round nodes" {
  command -v jq >/dev/null || skip "jq required"
  local out="$TMPD/out.graph.json"
  run compile_fixture_to "graph-repair-rounds-zero.plan.md" "$TMPD" "$out"
  [ "$status" -eq 0 ]

  local ids
  ids="$(jq -r '.nodes[].id' "$out" | sort | tr '\n' ',')"
  [ "$ids" = "fix-gate,fix-integrate,fix-passed,implement," ]

  # No changes-required edge anywhere: an exhausted (here: never-attempted,
  # zero-round) epoch has nowhere to route repair, and the only conditional
  # edge is the entry gate's passed edge.
  local cond_conditions
  cond_conditions="$(jq -r '[.edges[] | select(.condition != null and .condition != "") | .condition] | sort | unique | join(",")' "$out")"
  [ "$cond_conditions" = "passed" ]
}

@test "compile: one round emits exactly one diagnose/lane/reintegrate/regate set with fail-closed regate" {
  command -v jq >/dev/null || skip "jq required"
  local plan_file="$TMPD/one-round.plan.md"
  sed 's/rounds: 2/rounds: 1/' "$FIXTURE_DIR/graph-repair-rounds.plan.md" >"$plan_file"
  local out="$TMPD/out.graph.json"
  run plan_pipeline_graph_json "$plan_file"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" >"$out"

  local round1_nodes
  round1_nodes="$(jq -r '[.nodes[].id | select(startswith("fix-r1-"))] | sort | join(",")' "$out")"
  [ "$round1_nodes" = "fix-r1-diagnose,fix-r1-regate,fix-r1-reintegrate,fix-r1-repair-lane-a,fix-r1-repair-lane-b" ]

  # No round 2 exists.
  local round2_count
  round2_count="$(jq '[.nodes[].id | select(startswith("fix-r2-"))] | length' "$out")"
  [ "$round2_count" -eq 0 ]

  # The single round's regate has a passed edge to the join but no
  # changes-required edge: it is the last round, so exhaustion fails closed.
  local regate_conditions
  regate_conditions="$(jq -r '[.edges[] | select(.from == "fix-r1-regate") | .condition] | sort | join(",")' "$out")"
  [ "$regate_conditions" = "passed" ]
}

@test "compile: max rounds (hard ceiling) compiles; exceeding the ceiling is rejected" {
  command -v jq >/dev/null || skip "jq required"
  local out="$TMPD/out.graph.json"
  run compile_fixture_to "graph-repair-rounds-max.plan.md" "$TMPD" "$out"
  [ "$status" -eq 0 ]
  local round5_count
  round5_count="$(jq '[.nodes[].id | select(startswith("fix-r5-"))] | length' "$out")"
  [ "$round5_count" -gt 0 ]
  local round6_count
  round6_count="$(jq '[.nodes[].id | select(startswith("fix-r6-"))] | length' "$out")"
  [ "$round6_count" -eq 0 ]

  local over_plan="$TMPD/over.plan.md"
  sed 's/rounds: 5/rounds: 6/' "$FIXTURE_DIR/graph-repair-rounds-max.plan.md" >"$over_plan"
  run plan_pipeline_graph_json "$over_plan"
  [ "$status" -ne 0 ]
  [[ "$output" == *"repairRounds.rounds"* ]]
}

@test "compile: multiple rounds converge every regate passed edge on one join id; only final round omits changes-required" {
  command -v jq >/dev/null || skip "jq required"
  local out="$TMPD/out.graph.json"
  run compile_fixture_to "graph-repair-rounds.plan.md" "$TMPD" "$out"
  [ "$status" -eq 0 ]

  local join_predecessors
  join_predecessors="$(jq -r '[.edges[] | select(.to == "fix-passed") | .from] | sort | join(",")' "$out")"
  [ "$join_predecessors" = "fix-gate,fix-r1-regate,fix-r2-regate" ]

  # Round 1 regate routes changes-required onward to round 2's diagnose.
  local r1_changes_required_target
  r1_changes_required_target="$(jq -r '[.edges[] | select(.from == "fix-r1-regate" and .condition == "changes-required")] | .[0].to' "$out")"
  [ "$r1_changes_required_target" = "fix-r2-diagnose" ]

  # Round 2 (final) regate has no changes-required edge at all.
  local r2_changes_required_count
  r2_changes_required_count="$(jq '[.edges[] | select(.from == "fix-r2-regate" and .condition == "changes-required")] | length' "$out")"
  [ "$r2_changes_required_count" -eq 0 ]
}

@test "compile: repeated compiles of the same source are byte-identical (graph hash stability)" {
  command -v jq >/dev/null || skip "jq required"
  local plan_file="$TMPD/plan.md"
  cp "$FIXTURE_DIR/graph-repair-rounds.plan.md" "$plan_file"

  local out1="$TMPD/out1.json" out2="$TMPD/out2.json"
  plan_pipeline_graph_json "$plan_file" >"$out1"
  plan_pipeline_graph_json "$plan_file" >"$out2"
  cmp "$out1" "$out2"

  local sha1 sha2
  sha1="$(shasum -a 256 "$out1" | awk '{print $1}')"
  sha2="$(shasum -a 256 "$out2" | awk '{print $1}')"
  [ "$sha1" = "$sha2" ]
}

@test "compile: no duplicate node ids across entry and every round/lane" {
  command -v jq >/dev/null || skip "jq required"
  local out="$TMPD/out.graph.json"
  run compile_fixture_to "graph-repair-rounds-max.plan.md" "$TMPD" "$out"
  [ "$status" -eq 0 ]
  local total unique
  total="$(jq '.nodes | length' "$out")"
  unique="$(jq '[.nodes[].id] | unique | length' "$out")"
  [ "$total" = "$unique" ]
}

# ---------------------------------------------------------------------------
# Render
# ---------------------------------------------------------------------------

@test "render: expanded round/lane node ids appear in mermaid output" {
  command -v jq >/dev/null || skip "jq required"
  local out="$TMPD/out.graph.json"
  compile_fixture_to "graph-repair-rounds.plan.md" "$TMPD" "$out"

  run graph_render_mermaid "$out"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fix-r1-diagnose"* ]]
  [[ "$output" == *"fix-r1-repair-lane-a"* ]]
  [[ "$output" == *"fix-r2-regate"* ]]
  [[ "$output" == *"fix-passed"* ]]
}

@test "render: expanded round/lane node ids appear in ascii output" {
  command -v jq >/dev/null || skip "jq required"
  local out="$TMPD/out.graph.json"
  compile_fixture_to "graph-repair-rounds.plan.md" "$TMPD" "$out"

  run graph_render_ascii "$out"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fix-r1-diagnose"* ]]
  [[ "$output" == *"fix-r2-repair-lane-b"* ]]
}

# ---------------------------------------------------------------------------
# Scheduler outcome routing (direct GRAPH_NODE_* index manipulation, the same
# unit-level pattern graph-conditional-edges.bats uses for gate outcomes).
# ---------------------------------------------------------------------------

@test "scheduler: first-pass success releases the join via the entry gate without touching round nodes" {
  command -v jq >/dev/null || skip "jq required"
  local out="$TMPD/out.graph.json"
  compile_fixture_to "graph-repair-rounds.plan.md" "$TMPD" "$out"
  graph_schedule_load_index "$out"

  local cond_rc=0
  _graph_schedule_apply_conditional_outcome "fix-gate" "passed" || cond_rc=$?
  [ "$cond_rc" -eq 0 ]

  local join_idx r1_diag_idx
  join_idx="$(graph_schedule_index_map_get fix-passed)"
  r1_diag_idx="$(graph_schedule_index_map_get fix-r1-diagnose)"
  [ "${GRAPH_NODE_REMAINING_INDEGREE[$join_idx]}" -eq 0 ]
  [ "${GRAPH_NODE_STATES[$r1_diag_idx]}" = "skipped" ]
}

@test "scheduler: one repair round routes changes-required into round 1 and back to the join exactly once" {
  command -v jq >/dev/null || skip "jq required"
  local out="$TMPD/out.graph.json"
  compile_fixture_to "graph-repair-rounds.plan.md" "$TMPD" "$out"
  graph_schedule_load_index "$out"

  # Entry gate finds a repair problem: route into round 1.
  local cond_rc=0
  _graph_schedule_apply_conditional_outcome "fix-gate" "changes-required" || cond_rc=$?
  [ "$cond_rc" -eq 0 ]

  local join_idx r1_diag_idx
  join_idx="$(graph_schedule_index_map_get fix-passed)"
  r1_diag_idx="$(graph_schedule_index_map_get fix-r1-diagnose)"
  # Join not yet reachable: only one of its three predecessors accounted for.
  [ "${GRAPH_NODE_REMAINING_INDEGREE[$join_idx]}" -eq 2 ]
  [ "${GRAPH_NODE_REMAINING_INDEGREE[$r1_diag_idx]}" -eq 0 ]

  # Round 1's regate passes: releases the join's second predecessor and
  # skips round 2 entirely (round 1 fixed the problem).
  cond_rc=0
  _graph_schedule_apply_conditional_outcome "fix-r1-regate" "passed" || cond_rc=$?
  [ "$cond_rc" -eq 0 ]
  [ "${GRAPH_NODE_REMAINING_INDEGREE[$join_idx]}" -eq 0 ]

  local r2_diag_idx
  r2_diag_idx="$(graph_schedule_index_map_get fix-r2-diagnose)"
  [ "${GRAPH_NODE_STATES[$r2_diag_idx]}" = "skipped" ]
}

@test "scheduler: multiple repair rounds cascade changes-required and converge on the join exactly once" {
  command -v jq >/dev/null || skip "jq required"
  local out="$TMPD/out.graph.json"
  compile_fixture_to "graph-repair-rounds.plan.md" "$TMPD" "$out"
  graph_schedule_load_index "$out"

  _graph_schedule_apply_conditional_outcome "fix-gate" "changes-required"
  _graph_schedule_apply_conditional_outcome "fix-r1-regate" "changes-required"

  local join_idx r2_diag_idx
  join_idx="$(graph_schedule_index_map_get fix-passed)"
  r2_diag_idx="$(graph_schedule_index_map_get fix-r2-diagnose)"
  # Two of three join predecessors accounted for (entry gate, round 1 regate);
  # round 2's regate has not resolved yet.
  [ "${GRAPH_NODE_REMAINING_INDEGREE[$join_idx]}" -eq 1 ]
  [ "${GRAPH_NODE_REMAINING_INDEGREE[$r2_diag_idx]}" -eq 0 ]

  local cond_rc=0
  _graph_schedule_apply_conditional_outcome "fix-r2-regate" "passed" || cond_rc=$?
  [ "$cond_rc" -eq 0 ]
  [ "${GRAPH_NODE_REMAINING_INDEGREE[$join_idx]}" -eq 0 ]
}

@test "scheduler: exhaustion (every round changes-required) fails closed instead of succeeding" {
  command -v jq >/dev/null || skip "jq required"
  local out="$TMPD/out.graph.json"
  compile_fixture_to "graph-repair-rounds.plan.md" "$TMPD" "$out"
  graph_schedule_load_index "$out"

  _graph_schedule_apply_conditional_outcome "fix-gate" "changes-required"
  _graph_schedule_apply_conditional_outcome "fix-r1-regate" "changes-required"

  # Round 2 is the final round: its regate has no changes-required edge, so
  # the epoch fails closed (rc=2, the same sentinel a bare gate with no
  # repair edge returns) rather than being silently treated as success.
  run _graph_schedule_apply_conditional_outcome "fix-r2-regate" "changes-required"
  [ "$status" -eq 2 ]

  local join_idx
  join_idx="$(graph_schedule_index_map_get fix-passed)"
  [ "${GRAPH_NODE_REMAINING_INDEGREE[$join_idx]}" -gt 0 ]
}

# ---------------------------------------------------------------------------
# Resume mid-round
# ---------------------------------------------------------------------------

@test "resume: reconciling a succeeded gate with a recorded changes-required outcome replays into round 1" {
  command -v jq >/dev/null || skip "jq required"
  local workspace="$TMPD/ws"
  mkdir -p "$workspace"
  local out="$workspace/out.graph.json"
  compile_fixture_to "graph-repair-rounds.plan.md" "$workspace" "$out"

  local ns="fix-resume-ns" run_id="resume-run-1"
  graph_state_init_run "$workspace" "$ns" "$run_id" "$workspace/graph-repair-rounds.plan.md" "$out" 2

  graph_schedule_load_index "$out"
  GRAPH_SCHEDULE_WORKSPACE="$workspace"
  GRAPH_SCHEDULE_RUN_ID="$run_id"
  GRAPH_SCHEDULE_NAMESPACE="$ns"
  GRAPH_SCHEDULE_LEDGER_NAMESPACE="$ns"
  GRAPH_SCHEDULE_LEDGER_RUN_DIR="$(graph_state_run_dir "$workspace" "$ns" "$run_id")"

  # Simulate a scheduler that dispatched the entry gate, recorded it as
  # succeeded via the changes-required/repair-edge path, then died before
  # applying the conditional outcome in-memory (the crash this test targets:
  # ledger says done, but the round-1 branch was never actually released).
  _graph_schedule_ledger_record "fix-gate" "succeeded" "att-1" "success" "2" \
    "2026-01-01T00:00:00Z" "2026-01-01T00:00:01Z" "" "" "gate-changes-required-repair-edge"

  # Call directly (not via `run`) so GRAPH_NODE_* array mutations propagate
  # into the current shell instead of a `run` subshell.
  local reconcile_rc=0
  _graph_schedule_reconcile_node "fix-gate" "$out" || reconcile_rc=$?
  [ "$reconcile_rc" -eq 0 ]

  local gate_idx r1_diag_idx join_idx
  gate_idx="$(graph_schedule_index_map_get fix-gate)"
  r1_diag_idx="$(graph_schedule_index_map_get fix-r1-diagnose)"
  join_idx="$(graph_schedule_index_map_get fix-passed)"

  [ "${GRAPH_NODE_STATES[$gate_idx]}" = "succeeded" ]
  # Round 1 is released, not stuck pending on a phantom edge.
  [ "${GRAPH_NODE_REMAINING_INDEGREE[$r1_diag_idx]}" -eq 0 ]
  # The join is not falsely released by a gate that actually took the repair
  # branch (it must wait for round 1's own regate).
  [ "${GRAPH_NODE_REMAINING_INDEGREE[$join_idx]}" -eq 2 ]
}

@test "resume: reconciling a succeeded gate with a recorded passed outcome does not touch round nodes" {
  command -v jq >/dev/null || skip "jq required"
  local workspace="$TMPD/ws"
  mkdir -p "$workspace"
  local out="$workspace/out.graph.json"
  compile_fixture_to "graph-repair-rounds.plan.md" "$workspace" "$out"

  local ns="fix-resume-ns2" run_id="resume-run-2"
  graph_state_init_run "$workspace" "$ns" "$run_id" "$workspace/graph-repair-rounds.plan.md" "$out" 2

  graph_schedule_load_index "$out"
  GRAPH_SCHEDULE_WORKSPACE="$workspace"
  GRAPH_SCHEDULE_RUN_ID="$run_id"
  GRAPH_SCHEDULE_NAMESPACE="$ns"
  GRAPH_SCHEDULE_LEDGER_NAMESPACE="$ns"
  GRAPH_SCHEDULE_LEDGER_RUN_DIR="$(graph_state_run_dir "$workspace" "$ns" "$run_id")"

  _graph_schedule_ledger_record "fix-gate" "succeeded" "att-1" "success" "0" \
    "2026-01-01T00:00:00Z" "2026-01-01T00:00:01Z" "" "" "gate-passed"

  local reconcile_rc=0
  _graph_schedule_reconcile_node "fix-gate" "$out" || reconcile_rc=$?
  [ "$reconcile_rc" -eq 0 ]

  local join_idx r1_diag_idx
  join_idx="$(graph_schedule_index_map_get fix-passed)"
  r1_diag_idx="$(graph_schedule_index_map_get fix-r1-diagnose)"
  [ "${GRAPH_NODE_REMAINING_INDEGREE[$join_idx]}" -eq 0 ]
  [ "${GRAPH_NODE_STATES[$r1_diag_idx]}" = "skipped" ]
}
