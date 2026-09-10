#!/usr/bin/env bats
# Acceptance-fixture repair test for v2-jury-acceptance-repair
# (GRAPH-ENGINEERING-V2.plan.md). accept-fanout-jury.plan.md previously did
# not match the contract graph_consensus_run_join actually parses: voters had
# no role, models were stale placeholders, and the REVIEW_STATUS block used
# "approved:"/"changes-requested:" keys instead of the "status:"/
# "confidence:" keys ralph_extract_review_status and
# _graph_consensus_read_voter_confidence read. This suite proves the repaired
# fixture compiles, schema-validates, and (with stubbed runtime invocations)
# reaches real aggregation and produces a valid consensus-result.json.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/plan-todo.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-schedule.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-consensus.sh"

RALPH_DIR="$REPO_ROOT/bundle/.ralph"
JURY_PLAN="$REPO_ROOT/.ralph-workspace/plans/accept-fanout-jury.plan.md"

setup_jury_workspace() {
  local tmpd="$1"
  DISPATCH_WORKSPACE="$tmpd/workspace"
  mkdir -p "$DISPATCH_WORKSPACE/.ralph" "$DISPATCH_WORKSPACE/.ralph-workspace"

  cp -R "$RALPH_DIR"/* "$DISPATCH_WORKSPACE/.ralph/"
  chmod +x "$DISPATCH_WORKSPACE/.ralph"/*.sh 2>/dev/null || true
  chmod +x "$DISPATCH_WORKSPACE/.ralph/bash-lib"/*/*.sh 2>/dev/null || true

  cp "$BATS_TEST_DIRNAME/../../fixtures/orchestrator-single-stage/run-plan-stub.sh" \
    "$DISPATCH_WORKSPACE/.ralph/run-plan.sh"
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

# Stub orchestrator: for a consensus-voter stage (review:<id>), writes a real
# REVIEW_STATUS artifact at the stage's own declared outputArtifacts[0].path
# (resolved against the run's namespace) before reporting success, exactly
# like a real runtime invocation would after completing the review-1 todo.
# The verdict per voter id is controlled by a file under $behavior_dir.
install_jury_voter_orchestrator() {
  local workspace="$1" ns="$2" run_id="$3" behavior_dir="$4"
  mkdir -p "$behavior_dir"
  cat >"$workspace/.ralph/orchestrator.sh" <<EORC
#!/usr/bin/env bash
set -euo pipefail
stage=""
attempt=""
prev=""
for arg in "\$@"; do
  if [[ "\$prev" == "--single-stage" ]]; then stage="\$arg"; fi
  if [[ "\$prev" == "--attempt-id" ]];  then attempt="\$arg"; fi
  prev="\$arg"
done

ns="$ns"
run_id="$run_id"
behavior_dir="$behavior_dir"
workspace="\${@: -1}"

case "\$stage" in
  review:*)
    voter_id="\${stage#review:}"
    verdict="approved"
    confidence="0.9"
    if [[ -f "\$behavior_dir/\$voter_id.status" ]]; then
      verdict="\$(cat "\$behavior_dir/\$voter_id.status")"
    fi
    if [[ -f "\$behavior_dir/\$voter_id.confidence" ]]; then
      confidence="\$(cat "\$behavior_dir/\$voter_id.confidence")"
    fi
    artifact_dir="\$workspace/.ralph-workspace/artifacts/\$ns/reviews"
    mkdir -p "\$artifact_dir"
    printf '<!-- REVIEW_STATUS: START -->\nstatus: %s\nconfidence: %s\n<!-- REVIEW_STATUS: END -->\n' \
      "\$verdict" "\$confidence" >"\$artifact_dir/\$voter_id.md"
    ;;
esac

report_dir="\$workspace/.ralph-workspace/artifacts/\$ns/stage-outcomes"
mkdir -p "\$report_dir"
report_path="\$report_dir/\${attempt}.json"
cat >"\$report_path" <<EOF
{
  "schemaVersion": 1,
  "attemptId": "\$attempt",
  "runId": "\$run_id",
  "stageId": "\$stage",
  "namespace": "\$ns",
  "outcome": "success",
  "exitCode": 0,
  "finishedAt": "\$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u)"
}
EOF
exit 0
EORC
  chmod +x "$workspace/.ralph/orchestrator.sh"
}

compile_jury_graph_to() {
  local plan_path="$1"
  local workspace="$2"
  local out_path="$3"
  local plan_copy
  plan_copy="$workspace/$(basename "$plan_path")"
  cp "$plan_path" "$plan_copy"
  plan_pipeline_graph_json "$plan_copy" > "$out_path"
}

@test "accept-fanout-jury: compiles and schema-validates against graph.schema.json" {
  command -v python3 >/dev/null || skip "python3 required"
  tmpd="$(mktemp -d)"
  graph_file="$tmpd/accept-fanout-jury.graph.json"
  plan_pipeline_graph_json "$JURY_PLAN" > "$graph_file"

  run bash "$REPO_ROOT/bundle/.ralph/bash-lib/graph/validate-graph-schema.sh" "$graph_file"
  [ "$status" -eq 0 ]

  rm -rf "$tmpd"
}

# Removed: "no voter has a null/missing role" asserted that every compiled voter
# carried a non-null .stage.role. `role` was removed as an authored field and is
# now refused by validation, so that test asserted a removed feature still works.
# Per the repair rules it is deleted rather than re-pointed. Voter identity is
# still covered by the distinct-runtime/model test below.

@test "accept-fanout-jury: every voter declares a distinct runtime and a non-placeholder model" {
  tmpd="$(mktemp -d)"
  graph_file="$tmpd/accept-fanout-jury.graph.json"
  plan_pipeline_graph_json "$JURY_PLAN" > "$graph_file"

  runtimes="$(jq -r '[.nodes[] | select(.type == "consensus-voter") | .stage.runtime] | unique | length' "$graph_file")"
  [ "$runtimes" = "3" ]

  # Reject empty/null models and the specific stale placeholder this fixture
  # used to hard-code ("sonnet" with no version, "auto", "gpt-5.6-luna" --
  # none of which match any model string used elsewhere in this repo's own
  # plans).
  bad_models="$(jq '[.nodes[] | select(.type == "consensus-voter") | .stage.model]
    | map(select(. == null or . == "" or . == "sonnet" or . == "auto" or . == "gpt-5.6-luna"))
    | length' "$graph_file")"
  [ "$bad_models" = "0" ]

  rm -rf "$tmpd"
}

@test "accept-fanout-jury: review-1 todo prompt requests exactly the REVIEW_STATUS keys the aggregation path parses" {
  # ralph_extract_review_status looks for a "status:" line and
  # _graph_consensus_read_voter_confidence looks for a "confidence:" line
  # inside the REVIEW_STATUS block (bundle/.ralph/bash-lib/review-status.sh,
  # bundle/.ralph/bash-lib/graph/graph-consensus.sh). The old fixture's
  # prompt asked voters to fill in "approved:"/"changes-requested:" keys,
  # which neither parser reads -- a Markdown/JSON mismatch. Assert the
  # prompt now names the keys that are actually parsed, and does not still
  # reference the old dead keys.
  tmpd="$(mktemp -d)"
  graph_file="$tmpd/accept-fanout-jury.graph.json"
  plan_pipeline_graph_json "$JURY_PLAN" > "$graph_file"

  content="$(jq -r '.nodes[] | select(.id == "review:alpha") | .stage._inlineTodos[0].content' "$graph_file")"
  case "$content" in
    *"status: approved"*) : ;;
    *) echo "FAIL: prompt does not show the real 'status:' key" >&2; false ;;
  esac
  case "$content" in
    *"confidence: 0.9"*) : ;;
    *) echo "FAIL: prompt does not show the real 'confidence:' key" >&2; false ;;
  esac
  case "$content" in
    *"changes-requested:"*)
      echo "FAIL: prompt still references the old unparsed 'changes-requested:' key" >&2
      false
      ;;
    *) : ;;
  esac

  rm -rf "$tmpd"
}

@test "accept-fanout-jury: policy lives on the consensus stage the barrier actually reads, not only the downstream join" {
  # graph_schedule.sh's consensus-barrier handler reads .stage.policy from the
  # barrier node, which is spread from the "review" (type: consensus) stage
  # at compile time (plan-todo.sh). A "policy:" declared only on the
  # downstream "decide" (type: join, no runtime) stage has no effect, since
  # that node is a pass-through and never calls graph_consensus_run_join.
  tmpd="$(mktemp -d)"
  graph_file="$tmpd/accept-fanout-jury.graph.json"
  plan_pipeline_graph_json "$JURY_PLAN" > "$graph_file"

  barrier_policy="$(jq -r '.nodes[] | select(.id == "review:barrier") | .stage.policy' "$graph_file")"
  [ "$barrier_policy" = "veto" ]

  rm -rf "$tmpd"
}

@test "accept-fanout-jury: with stubbed runtimes, the real fixture reaches aggregation and writes a valid consensus-result.json (all approve)" {
  command -v python3 >/dev/null || skip "python3 required for graph compile"
  tmpd="$(mktemp -d)"
  setup_jury_workspace "$tmpd"

  graph_file="$tmpd/accept-fanout-jury.graph.json"
  compile_jury_graph_to "$JURY_PLAN" "$DISPATCH_WORKSPACE" "$graph_file"

  ns="$(jq -r '.namespace' "$graph_file")"
  run_id="accept-fanout-jury-approve"
  behavior_dir="$tmpd/behavior"
  mkdir -p "$behavior_dir"
  install_jury_voter_orchestrator "$DISPATCH_WORKSPACE" "$ns" "$run_id" "$behavior_dir"

  export RALPH_GRAPH_MAX_PARALLEL=4
  export RALPH_GRAPH_MAX_PARALLEL_PER_RUNTIME=3
  unset RALPH_ARTIFACT_NS RALPH_PLAN_KEY 2>/dev/null || true

  graph_schedule_run "$graph_file" "$run_id" "$DISPATCH_WORKSPACE"
  [ "$GRAPH_SCHEDULE_EXIT_CODE" -eq 0 ]
  [ "$(graph_schedule_node_state_by_id "review:alpha")"   = "succeeded" ]
  [ "$(graph_schedule_node_state_by_id "review:beta")"    = "succeeded" ]
  [ "$(graph_schedule_node_state_by_id "review:gamma")"   = "succeeded" ]
  [ "$(graph_schedule_node_state_by_id "review:barrier")" = "succeeded" ]
  [ "$(graph_schedule_node_state_by_id "decide")"         = "succeeded" ]

  result="$DISPATCH_WORKSPACE/.ralph-workspace/artifacts/$ns/consensus/review_barrier.json"
  [ -f "$result" ]

  run bash "$REPO_ROOT/scripts/validate-consensus-result.sh" "$result"
  [ "$status" -eq 0 ]

  decision="$(jq -r '.decision' "$result")"
  [ "$decision" = "approved" ]

  voter_count="$(jq '.voters | length' "$result")"
  [ "$voter_count" = "3" ]

  rm -rf "$tmpd"
}

@test "accept-fanout-jury: a single changes-required vote blocks under the veto policy" {
  command -v python3 >/dev/null || skip "python3 required for graph compile"
  tmpd="$(mktemp -d)"
  setup_jury_workspace "$tmpd"

  graph_file="$tmpd/accept-fanout-jury.graph.json"
  compile_jury_graph_to "$JURY_PLAN" "$DISPATCH_WORKSPACE" "$graph_file"

  ns="$(jq -r '.namespace' "$graph_file")"
  run_id="accept-fanout-jury-veto"
  behavior_dir="$tmpd/behavior"
  mkdir -p "$behavior_dir"
  printf 'changes-required\n' >"$behavior_dir/beta.status"
  install_jury_voter_orchestrator "$DISPATCH_WORKSPACE" "$ns" "$run_id" "$behavior_dir"

  export RALPH_GRAPH_MAX_PARALLEL=4
  export RALPH_GRAPH_MAX_PARALLEL_PER_RUNTIME=3
  unset RALPH_ARTIFACT_NS RALPH_PLAN_KEY 2>/dev/null || true

  graph_schedule_run "$graph_file" "$run_id" "$DISPATCH_WORKSPACE" || true
  [ "$(graph_schedule_node_state_by_id "review:barrier")" = "failed" ]

  result="$DISPATCH_WORKSPACE/.ralph-workspace/artifacts/$ns/consensus/review_barrier.json"
  [ -f "$result" ]
  decision="$(jq -r '.decision' "$result")"
  [ "$decision" = "changes-required" ]

  # decide (downstream pass-through) must never have run: its dependency
  # (review:barrier) failed, so it stays blocked, never pending-ready.
  [ "$(graph_schedule_node_state_by_id "decide")" != "succeeded" ]

  rm -rf "$tmpd"
}
