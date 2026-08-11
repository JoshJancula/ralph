#!/usr/bin/env bats
# Characterization tests for graph-mode baseline gaps identified in the
# GRAPH-ENGINEERING-V2 audit (baseline-audit.md).
#
# These tests are intentionally written to EXPOSE the current gaps and must
# initially fail (or, when marked with skip, be unreachable until the named
# prerequisite lands).  They pass only after the corresponding repair TODOs.
#
# Two gap characterizations are required by the baseline TODO:
#
#   Gap 1: graph_consensus_run_join is never reached by a production graph run.
#           REPAIRED by v2-consensus-production-wiring: graph-schedule.sh now
#           dispatches consensus-barrier nodes in-process via
#           graph_consensus_run_join instead of as a plain agent stage. The
#           GAP1 test below asserts this repaired behavior directly.
#
#   Gap 2: subagents=on does not change any actual runtime invocation surface.
#           The field affects only per-runtime concurrency slot reservation in
#           graph-schedule.sh; no run-plan invoke adapter reads or applies it.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/plan-todo.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-schedule.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-consensus.sh"

RALPH_DIR="$REPO_ROOT/bundle/.ralph"
CONSENSUS_JOIN_PLAN="$BATS_TEST_DIRNAME/../../fixtures/graph/graph-consensus-join-subagents-on.plan.md"
STUB_RUN_PLAN="$BATS_TEST_DIRNAME/../../fixtures/orchestrator-single-stage/run-plan-stub.sh"

# ---------------------------------------------------------------------------
# Shared setup helpers (mirrors setup_dispatch_workspace in graph-schedule.bats)
# ---------------------------------------------------------------------------

setup_char_workspace() {
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

# Install an orchestrator that records which nodes were dispatched and passes
# for every node (writes a success StageOutcomeReport).  The caller can then
# check whether graph_consensus_run_join was actually triggered separately.
install_recording_orchestrator() {
  local workspace="$1"
  local ns="$2"
  local run_id="$3"
  local record_dir="$4"

  mkdir -p "$record_dir"

  cat >"$workspace/.ralph/orchestrator.sh" <<EORC
#!/usr/bin/env bash
set -euo pipefail
stage=""
attempt=""
run_id_arg=""
prev=""
for arg in "\$@"; do
  if [[ "\$prev" == "--single-stage" ]]; then stage="\$arg"; fi
  if [[ "\$prev" == "--attempt-id" ]];  then attempt="\$arg"; fi
  if [[ "\$prev" == "--run-id" ]];      then run_id_arg="\$arg"; fi
  prev="\$arg"
done

# Record every dispatched node name so tests can inspect what was called.
printf '%s\n' "\$stage" >> "${record_dir}/dispatched-nodes.txt"

# Write a success StageOutcomeReport at the expected path.
report_dir="${workspace}/.ralph-workspace/artifacts/${ns}/stage-outcomes"
mkdir -p "\$report_dir"
report_path="\$report_dir/\${attempt}.json"
cat >"\$report_path" <<EOF
{
  "schemaVersion": 1,
  "attemptId": "\$attempt",
  "runId": "\$run_id_arg",
  "stageId": "\$stage",
  "namespace": "${ns}",
  "outcome": "success",
  "exitCode": 0,
  "finishedAt": "\$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u)"
}
EOF
exit 0
EORC
  chmod +x "$workspace/.ralph/orchestrator.sh"
}

compile_plan_graph_to() {
  local plan_path="$1"
  local workspace="$2"
  local out_path="$3"
  local plan_copy
  plan_copy="$workspace/$(basename "$plan_path")"
  cp "$plan_path" "$plan_copy"
  plan_pipeline_graph_json "$plan_copy" > "$out_path"
}

# ---------------------------------------------------------------------------
# Gap 1: graph_consensus_run_join is not reached by a production graph run.
#
# Prerequisite: a scheduler repair TODO that detects consensus-barrier nodes
# and calls graph_consensus_run_join instead of dispatching them as plain
# agent invocations.
# ---------------------------------------------------------------------------

@test "GAP1 [repaired by v2-consensus-production-wiring] consensus-barrier node reached by graph_consensus_run_join in a real graph run" {
  # Was a skip-guarded characterization test; v2-consensus-production-wiring
  # landed (graph-schedule.sh now dispatches consensus-barrier nodes
  # in-process via graph_consensus_run_join instead of as a plain agent
  # stage), so this now runs for real and asserts the repaired behavior.
  tmpd="$(mktemp -d)"
  setup_char_workspace "$tmpd"
  command -v python3 >/dev/null || { rm -rf "$tmpd"; skip "python3 required for graph compile"; }

  graph_file="$tmpd/consensus-join.graph.json"
  compile_plan_graph_to "$CONSENSUS_JOIN_PLAN" "$DISPATCH_WORKSPACE" "$graph_file"

  ns="$(jq -r '.namespace' "$graph_file")"
  run_id="char-consensus-run-join-test"
  record_dir="$tmpd/recorded"

  install_recording_orchestrator "$DISPATCH_WORKSPACE" "$ns" "$run_id" "$record_dir"

  # review:barrier reads each voter's declared outputArtifacts[0] itself; the
  # recording orchestrator only writes StageOutcomeReports, so pre-seed the
  # voter verdict artifacts as approved.
  mkdir -p "$DISPATCH_WORKSPACE/.ralph-workspace/artifacts/${ns}/review"
  printf '<!-- REVIEW_STATUS: START -->\nstatus: approved\n<!-- REVIEW_STATUS: END -->\n' \
    >"$DISPATCH_WORKSPACE/.ralph-workspace/artifacts/${ns}/review/alpha.md"
  printf '<!-- REVIEW_STATUS: START -->\nstatus: approved\n<!-- REVIEW_STATUS: END -->\n' \
    >"$DISPATCH_WORKSPACE/.ralph-workspace/artifacts/${ns}/review/beta.md"

  export RALPH_GRAPH_MAX_PARALLEL=4
  export RALPH_GRAPH_MAX_PARALLEL_PER_RUNTIME=2

  graph_schedule_run "$graph_file" "$run_id" "$DISPATCH_WORKSPACE"
  [ "$GRAPH_SCHEDULE_EXIT_CODE" -eq 0 ]

  # The barrier must never appear in the recording orchestrator's dispatched
  # nodes -- it is handled in-process, not as an orchestrator subprocess.
  if [ -f "$record_dir/dispatched-nodes.txt" ]; then
    grep -q "review:barrier" "$record_dir/dispatched-nodes.txt" && {
      echo "FAIL: review:barrier was dispatched as a plain agent node" >&2
      cat "$record_dir/dispatched-nodes.txt" >&2
      false
    }
  fi

  # A consensus result JSON must exist for the barrier node.
  barrier_result="$DISPATCH_WORKSPACE/.ralph-workspace/artifacts/${ns}/consensus/review_barrier.json"
  [ -f "$barrier_result" ] || {
    echo "FAIL: no consensus result written; graph_consensus_run_join was not called" >&2
    false
  }

  # The result must have decision=approved (both voters approved).
  decision="$(jq -r '.decision' "$barrier_result")"
  [ "$decision" = "approved" ] || {
    echo "FAIL: expected decision=approved, got $decision" >&2
    false
  }

  rm -rf "$tmpd"
}

# ---------------------------------------------------------------------------
# Gap 2: subagents=on does not change any actual runtime invocation surface.
#
# Prerequisite: a repair TODO that reads the effective subagents field in
# run-plan-routing.sh or a runtime invocation adapter and modifies the CLI
# invocation accordingly (e.g., adds a Task/dispatch tool flag or similar).
# ---------------------------------------------------------------------------

@test "GAP2 [prereq: subagents-on-changes-invocation] subagents=on modifies the actual runtime invocation surface" {
  # BASELINE CHARACTERIZATION: this test documents the current gap.
  # It skips until the prerequisite repair TODO lands.
  #
  # After repair, a node with subagents=on must produce an invocation that
  # differs from a node with subagents=inherit (e.g., a Task tool flag, a
  # different allowed-tools list, or an env var the invocation adapter sets).
  # Until then, the subagents field only affects concurrency slot reservation
  # in graph-schedule.sh and has no effect on what the runtime CLI receives.
  skip "prereq: subagents-on-changes-invocation -- subagents=on is read only by the concurrency reservation code in graph-schedule.sh; run-plan-routing.sh and all invoke adapters ignore the field entirely"

  # After repair: inject a node with subagents=on and verify the invocation
  # differs from a plain node in a measurable way (runtime adapter flag, env
  # var, allowed-tools argument, etc.).  The specific mechanism is left to
  # the repair TODO author to define; this skip ensures we land here.
  false
}

@test "GAP2 characterization: subagents field is included in run-plan-routing effective metadata fields" {
  # The routing metadata carries subagents so the selected runtime invocation
  # can enforce the native-subagent policy rather than merely reserving a
  # scheduler slot.
  # run-plan-routing.sh's ralph_run_plan_routing_effective_metadata_fields
  # extracts: stage, runtime, agent, model, sessionStrategy, contextBudget,
  # planFile -- and does NOT extract subagents.  Confirm by inspecting the
  # function source.
  command -v python3 >/dev/null || skip "python3 required"

  routing_src="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-routing.sh"
  [ -f "$routing_src" ]

  # The routing function must exist.
  grep -q "ralph_run_plan_routing_effective_metadata_fields" "$routing_src"

  # The function body must include subagents in the fields list.
  fn_body="$(awk '/ralph_run_plan_routing_effective_metadata_fields\(\)/{found=1} found{print} found && /^}$/{exit}' "$routing_src")"

  if ! echo "$fn_body" | grep -q '"subagents"'; then
    echo "subagents is missing from ralph_run_plan_routing_effective_metadata_fields" >&2
    false
  fi
}
