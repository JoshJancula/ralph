#!/usr/bin/env bats
# Small-feature delivery is intentionally shallower than feature-delivery while
# retaining candidate-bound evaluation, bounded repair, and model-free gating.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$RALPH_LIB_ROOT/plan-todo.sh"

small_feature_workflow() {
  printf '%s\n' "$REPO_ROOT/bundle/.ralph/workflows/small-feature-delivery.workflow.md"
}

compile_small_feature() {
  local out="$BATS_TEST_TMPDIR/small-feature.plan.md"
  local graph="$BATS_TEST_TMPDIR/small-feature.graph.json"
  plan_workflow_instantiate "$(small_feature_workflow)" "Add a scoped control" "$out" \
    fallback_runtime=cursor fallback_model=auto >/dev/null
  plan_pipeline_graph_json "$out" >"$graph"
  printf '%s\n' "$graph"
}

@test "small-feature-delivery compiles with the five authored stages and fields" {
  command -v jq >/dev/null || skip "jq required"
  local graph
  graph="$(compile_small_feature)"

  jq -e '
    .publishMode == "on-verified"
    and (
      [.nodes[] | select(.derivedFrom == "stage") | .id]
      | sort
      | . == ["evaluate", "implement", "integrate", "scope-and-plan", "verdict-gate"]
    )
    and (.nodes[] | select(.id == "scope-and-plan") | .stage.sessionStrategy == "resume")
    and (
      .nodes[]
      | select(.id == "implement")
      | .stage.planFrom == "scope-and-plan"
        and .stage.workspaceMode == "snapshot"
        and .stage.writeScopes == ["**"]
        and .stage.agentGitAccess == "off"
        and .stage.sessionStrategy == "compact"
    )
    and (
      .nodes[]
      | select(.id == "evaluate")
      | .stage.candidateFrom == "implement"
        and .stage.workspaceMode == "snapshot"
        and .stage.sessionStrategy == "fresh"
    )
    and (
      .nodes[]
      | select(.id == "integrate")
      | .type == "integrate"
        and .stage.workspaceMode == "snapshot"
        and (.dependsOn | index("evaluate-approved") != null)
    )
    and (
      .nodes[]
      | select(.id == "verdict-gate")
      | .type == "gate"
        and .stage.profile == "evaluate-verdict"
        and (.dependsOn | index("integrate") != null)
    )
  ' "$graph" >/dev/null
}

@test "evaluate binds implement with a bounded rework loop that ends without changes-required" {
  command -v jq >/dev/null || skip "jq required"
  local graph
  graph="$(compile_small_feature)"

  jq -e '
    ([.nodes[] | select(.id == "evaluate") | .stage.candidateFrom] | .[0] == "implement")
    and ([.nodes[] | select(.id == "evaluate-r1") | .stage.candidateFrom] | .[0] == "implement-r1")
    and ([.nodes[] | select(.id == "evaluate-r2") | .stage.candidateFrom] | .[0] == "implement-r2")
    and ([.nodes[] | select(.id == "evaluate-approved" and .type == "join")] | length == 1)
    and ([.edges[] | select(.from == "evaluate" and .to == "implement-r1" and .condition == "changes-required")] | length == 1)
    and ([.edges[] | select(.from == "evaluate-r1" and .to == "implement-r2" and .condition == "changes-required")] | length == 1)
    and ([.edges[] | select(.from == "evaluate-r2" and .condition == "changes-required")] | length == 0)
    and ([.edges[] | select(.from == "evaluate-r2" and .to == "evaluate-approved" and .condition == "passed")] | length == 1)
  ' "$graph" >/dev/null
}

@test "verdict-gate profile runs evaluator_contract require-approved" {
  command -v jq >/dev/null || skip "jq required"
  local graph
  graph="$(compile_small_feature)"

  jq -e '
    ([.nodes[] | select(.id == "verdict-gate" and .type == "gate" and .stage.profile == "evaluate-verdict")] | length == 1)
    and (
      .verificationProfiles[]
      | select(.name == "evaluate-verdict")
      | .steps[0].command
      | contains("evaluator_contract.py require-approved")
    )
  ' "$graph" >/dev/null
}

@test "scope-and-plan instructions raise a kind input action for unresolved decisions" {
  command -v jq >/dev/null || skip "jq required"
  local graph
  graph="$(compile_small_feature)"
  # The instruction must survive compilation into the stage the agent runs.
  jq -e '
    [.nodes[] | select(.id == "scope-and-plan") | (.stage.instructions // .stage.prompt // "")][0]
    | contains("ralph workflow actions request --question")
      and contains("rather than inventing the choice")
  ' "$graph" >/dev/null
}

@test "the compiled graph has fewer coordination stages than feature-delivery" {
  command -v jq >/dev/null || skip "jq required"
  local small_out feature_out small_graph feature_graph
  small_out="$BATS_TEST_TMPDIR/small-feature.plan.md"
  feature_out="$BATS_TEST_TMPDIR/feature-delivery.plan.md"
  plan_workflow_instantiate "$(small_feature_workflow)" "Add a scoped control" "$small_out" \
    fallback_runtime=cursor fallback_model=auto >/dev/null
  plan_workflow_instantiate "$REPO_ROOT/bundle/.ralph/workflows/feature-delivery.workflow.md" "Add a scoped control" "$feature_out" \
    fallback_runtime=cursor fallback_model=auto >/dev/null
  small_graph="$(plan_pipeline_graph_json "$small_out")"
  feature_graph="$(plan_pipeline_graph_json "$feature_out")"
  [ "$(printf '%s' "$small_graph" | jq '.nodes | length')" -lt "$(printf '%s' "$feature_graph" | jq '.nodes | length')" ]
}
