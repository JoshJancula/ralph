#!/usr/bin/env bats

# Compiler provenance is a frozen-graph contract. Keep this focused test
# independent of a runtime invocation so it also covers a freshly compiled run.
source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$REPO_ROOT/bundle/.ralph/bash-lib/plan-todo.sh"
source "$REPO_ROOT/bundle/.ralph/bash-lib/workflow/workflow-operator-view.sh"

setup() {
  TMPD="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMPD"
}

@test "compiled rework nodes retain logical stage and attempt provenance" {
  local plan="$TMPD/rework.plan.md"
  cat >"$plan" <<'EOF'
---
execution: graph
pipeline:
  maxParallel: 1
  maxReworkIterations: 2
  stages:
    - id: implement
      runtime: cursor
      instructions: implement
    - id: review
      runtime: cursor
      dependsOn:
        - implement
      loopBackTo: implement
      loopCheck:
        path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/{{STAGE_ID}}.json
        schema: bundle/.ralph/schemas/evaluator-verdict.schema.json
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/{{STAGE_ID}}.json
          schema: bundle/.ralph/schemas/evaluator-verdict.schema.json
      instructions: review
---
EOF
  run plan_pipeline_graph_json "$plan"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    (.nodes[] | select(.id == "implement") | .logicalStage == "implement" and .attempt == 0)
    and (.nodes[] | select(.id == "implement-r1") | .logicalStage == "implement" and .attempt == 1)
    and (.nodes[] | select(.id == "review-r2") | .logicalStage == "review" and .attempt == 2)
    and (.nodes[] | select(.id == "review-approved") | .logicalStage == "review" and .attempt == 0)
  ' >/dev/null
}

@test "rework clones project as attempts of one logical stage" {
  local graph ledger projected
  graph="$(jq -n '{
    nodes: [
      {id:"implement", type:"agent", logicalStage:"implement", attempt:0, derivedFrom:"stage"},
      {id:"implement-r1", type:"agent", logicalStage:"implement", attempt:1, derivedFrom:"rework"},
      {id:"review", type:"agent", logicalStage:"review", attempt:0, derivedFrom:"stage"},
      {id:"review-approved", type:"join", logicalStage:"review", attempt:0, derivedFrom:"rework"}
    ],
    edges: [
      {from:"implement", to:"review"},
      {from:"review", to:"implement-r1", condition:"changes-required"},
      {from:"implement-r1", to:"review-approved", condition:"passed"},
      {from:"review", to:"review-approved", condition:"passed"}
    ]
  }')"
  ledger="$(jq -n '{
    implement: {nodeId:"implement", status:"succeeded"},
    "implement-r1": {nodeId:"implement-r1", status:"succeeded"},
    review: {nodeId:"review", status:"succeeded"},
    "review-approved": {nodeId:"review-approved", status:"succeeded"}
  }')"
  projected="$(workflow_operator_project_logical_stages "$graph" "$ledger")"
  printf '%s' "$projected" | jq -e '
    .mode == "logical"
    and (.note == null)
    and ([.stages[].id] | sort) == ["implement","review"]
    and (.stages[] | select(.id == "implement") | (.attempts | length) == 2)
    and (.stages[] | select(.id == "implement")
         | [.attempts[].attempt] == [0,1]
         and [.attempts[].nodeId] == ["implement","implement-r1"])
  ' >/dev/null
}

@test "unreached rework clones are excluded from completion percentage" {
  local graph ledger projected
  graph="$(jq -n '{
    nodes: [
      {id:"implement", type:"agent", logicalStage:"implement", attempt:0, derivedFrom:"stage"},
      {id:"implement-r1", type:"agent", logicalStage:"implement", attempt:1, derivedFrom:"rework"},
      {id:"review", type:"agent", logicalStage:"review", attempt:0, derivedFrom:"stage"},
      {id:"review-r1", type:"agent", logicalStage:"review", attempt:1, derivedFrom:"rework"},
      {id:"review-approved", type:"join", logicalStage:"review", attempt:0, derivedFrom:"rework"}
    ],
    edges: [
      {from:"review", to:"implement-r1", condition:"changes-required"},
      {from:"implement-r1", to:"review-r1"},
      {from:"review", to:"review-approved", condition:"passed"},
      {from:"review-r1", to:"review-approved", condition:"passed"}
    ]
  }')"
  ledger="$(jq -n '{
    implement: {nodeId:"implement", status:"succeeded"},
    review: {nodeId:"review", status:"succeeded"},
    "implement-r1": {nodeId:"implement-r1", status:"queued"},
    "review-r1": {nodeId:"review-r1", status:"queued"},
    "review-approved": {nodeId:"review-approved", status:"succeeded"}
  }')"
  projected="$(workflow_operator_project_logical_stages "$graph" "$ledger")"
  printf '%s' "$projected" | jq -e '
    .mode == "logical"
    and (.stages[] | select(.id == "implement") | (.attempts | length) == 1)
    and (.stages[] | select(.id == "implement") | .attempts[0].nodeId == "implement")
    and .completion.completed == 2
    and .completion.total == 2
    and .completion.percent == 100
  ' >/dev/null
}

@test "unselected conditional branch is shown as not selected" {
  local graph ledger projected
  graph="$(jq -n '{
    nodes: [
      {id:"router", type:"router", logicalStage:"router", attempt:0, derivedFrom:"stage"},
      {id:"branch-a", type:"agent", logicalStage:"branch-a", attempt:0, derivedFrom:"stage"},
      {id:"branch-b", type:"agent", logicalStage:"branch-b", attempt:0, derivedFrom:"stage"}
    ],
    edges: [
      {from:"router", to:"branch-a", condition:"route-a"},
      {from:"router", to:"branch-b", condition:"route-b"}
    ]
  }')"
  ledger="$(jq -n '{
    router: {nodeId:"router", status:"succeeded"},
    "branch-a": {nodeId:"branch-a", status:"succeeded"},
    "branch-b": {nodeId:"branch-b", status:"skipped"}
  }')"
  projected="$(workflow_operator_project_logical_stages "$graph" "$ledger")"
  printf '%s' "$projected" | jq -e '
    .mode == "logical"
    and (.stages[] | select(.id == "branch-b") | .state == "not selected")
    and (.stages[] | select(.id == "branch-a") | .state == "succeeded")
    and .completion.total == 2
    and .completion.completed == 2
    and .completion.percent == 100
  ' >/dev/null
}

@test "graph without provenance renders expanded with compiled-before note" {
  local graph ledger projected attached
  graph="$(jq -n '{
    nodes: [
      {id:"implement", type:"agent"},
      {id:"implement-r1", type:"agent"},
      {id:"review", type:"agent"}
    ],
    edges: []
  }')"
  ledger="$(jq -n '{
    implement: {nodeId:"implement", status:"succeeded"},
    "implement-r1": {nodeId:"implement-r1", status:"queued"},
    review: {nodeId:"review", status:"succeeded"}
  }')"
  projected="$(workflow_operator_project_logical_stages "$graph" "$ledger")"
  printf '%s' "$projected" | jq -e '
    .mode == "expanded"
    and .note == "compiled before logical stage provenance"
    and ([.stages[].id] | sort) == ["implement","implement-r1","review"]
  ' >/dev/null

  attached="$(workflow_operator_attach_compiled_graph '{"schemaVersion":1}' "$graph")"
  printf '%s' "$attached" | jq -e '
    .compiledGraph != null
    and .compiledGraphNote == "compiled before logical stage provenance"
  ' >/dev/null
}
