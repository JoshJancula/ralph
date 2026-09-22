#!/usr/bin/env bats
# Bundled delivery workflow candidate bindings at compile time.
# Runtime snapshot / publish behavior lives in graph-candidate-binding.bats.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$REPO_ROOT/bundle/.ralph/bash-lib/plan-todo.sh"

DELIVERY_WORKFLOWS=(
  feature-delivery
  bug-fix
  refactor
  plan-delivery
  human-verified-delivery
)

workflow_file() {
  printf '%s/bundle/.ralph/workflows/%s.workflow.md\n' "$REPO_ROOT" "$1"
}

compile_delivery_graph() {
  local name="$1" source_workflow="$2"
  local out="$BATS_TEST_TMPDIR/${name}.plan.md"
  local graph="$BATS_TEST_TMPDIR/${name}.graph.json"
  if grep -q '^planInput:' "$source_workflow"; then
    printf -- '- [ ] supplied\n' >"$BATS_TEST_TMPDIR/${name}.src.plan.md"
    plan_workflow_instantiate_provided "$source_workflow" "task" "$out" \
      "provided_plan_path=$BATS_TEST_TMPDIR/${name}.src.plan.md" \
      fallback_runtime=cursor fallback_model=auto >/dev/null
  else
    plan_workflow_instantiate "$source_workflow" "task" "$out" \
      fallback_runtime=cursor fallback_model=auto >/dev/null
  fi
  plan_pipeline_graph_json "$out" >"$graph"
  printf '%s\n' "$graph"
}

authored_topology() {
  jq -c '
    {
      publishMode: .publishMode,
      stages: [
        .nodes[]
        | select(.derivedFrom == "stage")
        | {id, dependsOn: (.stage.dependsOn // [])}
      ] | sort_by(.id)
    }
  ' "$1"
}

assert_review_and_qa_candidates() {
  local graph="$1"
  jq -e '
    ([.nodes[] | select(.id == "review") | .stage.candidateFrom] | .[0] == "implement")
    and (
      [.nodes[] | select(.id | test("^review-r[0-9]+$"))]
      | length > 0
      and all(.[]; .stage.candidateFrom == ("implement-r" + (.id | sub("^review-r"; ""))))
    )
    and ([.nodes[] | select(.id == "qa") | .stage.candidateFrom] | .[0] == "integrate")
  ' "$graph" >/dev/null
}

@test "delivery workflows keep pre-plan topology and bind review QA candidates" {
  command -v jq >/dev/null || skip "jq required"
  local name cur_graph cur_topo head_topo
  for name in "${DELIVERY_WORKFLOWS[@]}"; do
    cur_graph="$(compile_delivery_graph "${name}.cur" "$(workflow_file "$name")")"
    assert_review_and_qa_candidates "$cur_graph" \
      || { echo "candidateFrom mismatch for $name"; jq -r '
          .nodes[]
          | select(.id == "review" or (.id | test("^review-r[0-9]+$")) or .id == "qa")
          | "\(.id) candidateFrom=\(.stage.candidateFrom // "-")"
        ' "$cur_graph"; false; }

    # Expected stage order, dependsOn, and publishMode from before candidate
    # binding, checked in so the test does not depend on git history.
    cur_topo="$(authored_topology "$cur_graph")"
    head_topo="$(jq -c . "$BATS_TEST_DIRNAME/fixtures/delivery-topology/${name}.json")"
    [ "$cur_topo" = "$head_topo" ] \
      || { echo "topology drift for $name"; echo "cur=$cur_topo"; echo "head=$head_topo"; false; }
  done
}

# QA repair contract (feature-delivery: R=2, Q=1 adds 10 nodes).
# Node count added = Q * (1 implement + 1 review + 2R rework + 1 review join
# + 1 integrate + 1 qa) + 1 QA join.

@test "feature-delivery QA repair expands to the contract node count and bindings" {
  command -v jq >/dev/null || skip "jq required"
  local graph zero_wf zero_graph node_count zero_count added r q expected
  graph="$(compile_delivery_graph "fd.qa" "$(workflow_file feature-delivery)")"
  node_count="$(jq '.nodes | length' "$graph")"

  # feature-delivery authors maxReworkIterations: 2 and maxQaRepairRounds: 1.
  r=2
  q=1
  expected=$((q * (1 + 1 + 2 * r + 1 + 1 + 1) + 1))
  [ "$expected" -eq 10 ]

  zero_wf="$BATS_TEST_TMPDIR/feature-delivery.qa0.workflow.md"
  sed 's/maxQaRepairRounds: 1/maxQaRepairRounds: 0/' \
    "$(workflow_file feature-delivery)" >"$zero_wf"
  zero_graph="$(compile_delivery_graph "fd.qa0" "$zero_wf")"
  zero_count="$(jq '.nodes | length' "$zero_graph")"
  added=$((node_count - zero_count))
  [ "$added" -eq "$expected" ] \
    || { echo "QA repair added $added nodes, expected $expected (Q=$q R=$r total=$node_count zero=$zero_count)"; false; }

  jq -e '
    ([.nodes[] | select(.id == "qa-q1") | .stage.candidateFrom] | .[0] == "integrate-q1")
    # integrate-q1 builds from the run base like integrate; it is not bound.
    and ([.nodes[] | select(.id == "integrate-q1") | .stage.candidateFrom] | .[0] == null)
    and ([.nodes[] | select(.id == "integrate-q1") | .qaRound] | .[0] == 1)
    # The repair round starts from what QA evaluated (the integrated
    # candidate), never from the first-pass implementation.
    and ([.nodes[] | select(.id == "implement-q1") | .stage.seedFrom] | .[0] == "integrate")
    and ([.nodes[] | select(.id == "implement-q1") | .stage.candidateFrom] | .[0] == null)
    and ([.nodes[] | select(.id == "implement-q1-r1") | .stage.seedFrom] | .[0] == "implement-q1")
    and ([.nodes[] | select(.id == "implement-r2") | .stage.seedFrom] | .[0] == "implement-r1")
  ' "$graph" >/dev/null

  # Final QA round has a passed edge to the join and no changes-required edge.
  jq -e '
    ([.edges[] | select(.from == "qa-q1" and .condition == "passed" and .to == "qa-approved")] | length == 1)
    and ([.edges[] | select(.from == "qa-q1" and .condition == "changes-required")] | length == 0)
  ' "$graph" >/dev/null

  jq -e '
    ([.nodes[] | select(.id == "qa-gate") | .dependsOn] | .[0] | index("qa-approved") != null)
  ' "$graph" >/dev/null
}

@test "human-verified-delivery approve-result depends on qa-approved" {
  command -v jq >/dev/null || skip "jq required"
  local graph
  graph="$(compile_delivery_graph "hv.qa" "$(workflow_file human-verified-delivery)")"
  jq -e '
    ([.nodes[] | select(.id == "qa-gate") | .dependsOn] | .[0] | index("qa-approved") != null)
    and ([.nodes[] | select(.id == "approve-result") | .dependsOn] | .[0] | index("qa-approved") != null)
  ' "$graph" >/dev/null
}

@test "maxQaRepairRounds 0 compiles to the pre-plan graph" {
  command -v jq >/dev/null || skip "jq required"
  local zero_wf zero_graph
  zero_wf="$BATS_TEST_TMPDIR/feature-delivery.qa0-pre.workflow.md"
  sed 's/maxQaRepairRounds: 1/maxQaRepairRounds: 0/' \
    "$(workflow_file feature-delivery)" >"$zero_wf"
  zero_graph="$(compile_delivery_graph "fd.qa0-pre" "$zero_wf")"

  jq -e '
    ([.nodes[] | select(.derivedFrom == "qa-repair")] | length == 0)
    and ([.nodes[] | select(.id == "qa-gate") | .dependsOn] | .[0] == ["qa"])
    and ([.nodes[].id | select(test("^implement-q[0-9]+$|^qa-q[0-9]+$|^qa-approved$"))] | length == 0)
  ' "$zero_graph" >/dev/null
}
