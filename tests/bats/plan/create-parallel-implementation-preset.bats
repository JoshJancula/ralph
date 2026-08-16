#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$REPO_ROOT/bundle/.ralph/bash-lib/plan-todo.sh"
source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-compile.sh"
source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-render.sh"
source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-state.sh"
source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-run-base.sh"

CREATE_PLAN="$REPO_ROOT/.ralph/create-plan.sh"
VALIDATE_GRAPH="$REPO_ROOT/bundle/.ralph/bash-lib/graph/validate-graph-schema.sh"
ARTIFACT_LOG="$REPO_ROOT/.ralph-workspace/artifacts/GRAPH-ENGINEERING-V2.plan/parallel-preset.log"

setup() {
  TEST_WORKSPACE="$(mktemp -d)"
  export RALPH_VERSION="test"
  mkdir -p "$(dirname "$ARTIFACT_LOG")"
}

teardown() {
  printf '%s: %s\n' "$BATS_TEST_NAME" "$BATS_TEST_COMPLETED" >>"$ARTIFACT_LOG"
  chmod -R u+w "$TEST_WORKSPACE" 2>/dev/null || true
  rm -rf "$TEST_WORKSPACE"
}

generate_compile_validate_render() {
  local name="$1" lanes="$2" mode="$3"
  shift 3
  local plan="$TEST_WORKSPACE/.ralph-workspace/plans/$name.plan.md"
  local graph="$TEST_WORKSPACE/$name.graph.json"
  local render="$TEST_WORKSPACE/$name.ascii"

  bash "$CREATE_PLAN" --workspace "$TEST_WORKSPACE" --format graph \
    --preset parallel-implementation --name "$name" --lanes "$lanes" \
    --workspace-mode "$mode" "$@" >/dev/null
  RALPH_GRAPH_GIT_SANDBOX_PROVEN=1 graph_compile_plan "$plan" "$graph" 1 >/dev/null
  bash "$VALIDATE_GRAPH" "$graph"
  graph_render_ascii "$graph" >"$render"
  [ -s "$render" ]

  [ "$(jq '[.nodes[] | select(.id | test("^lane-[1-4]$"))] | length' "$graph")" -eq "$lanes" ]
  [ "$(jq '[.nodes[] | select(.id | test("^lane-[1-4]$")) | .stage.plan] | unique | length' "$graph")" -eq "$lanes" ]
  [ "$(jq --arg mode "$mode" '[.nodes[] | select(.id | test("^lane-[1-4]$")) | select(.stage.workspaceMode == $mode)] | length' "$graph")" -eq "$lanes" ]
  [ "$(jq '[.nodes[] | select(.id | test("^lane-[1-4]$")) | select(.stage.agentGitAccess == "off")] | length' "$graph")" -eq "$lanes" ]
  [ "$(jq '[.nodes[] | select(.id | test("^lane-[1-4]$")) | .stage.writeScopes[]] | unique | length' "$graph")" -eq "$lanes" ]
  [ "$(jq '[.nodes[] | select(.id | test("^lane-[1-4]$")) | .stage.plan] | length' "$graph")" -eq "$lanes" ]
  [ "$(jq '[.nodes[] | select(.id | test("^lane-[1-4]$")) | select(any(.stage.inputArtifacts[]?; .path | endswith("ownership-map.json")))] | length' "$graph")" -eq "$lanes" ]
  [ "$(jq '[.nodes[] | select(.id | test("^lane-[1-4]$")) | select(any(.stage.outputArtifacts[]?; .path | test("lane-[1-4]-verification.md$")))] | length' "$graph")" -eq "$lanes" ]
  while IFS= read -r plan_file; do
    [ -f "$TEST_WORKSPACE/$plan_file" ]
  done < <(jq -r '.nodes[] | select(.id | test("^lane-[1-4]$")) | .stage.plan' "$graph")

  [ "$(jq '[.nodes[] | select(.type == "integrate" and .stage.workspaceMode == "snapshot")] | length' "$graph")" -eq 3 ]
  [ "$(jq '[.edges[] | select(.condition == "changes-required")] | length' "$graph")" -eq 2 ]
  [ "$(jq '[.nodes[] | select((.id == "implementation-gate" or (.id | test("implementation-r[1-2]-regate"))) and .stage.profile == "fast")] | length' "$graph")" -eq 3 ]
  [ "$(jq '[.nodes[] | select(.id == "full-gate" and .stage.profile == "full")] | length' "$graph")" -eq 1 ]
  [ "$(jq '[.nodes[] | select(.type == "consensus-voter") | select(.stage.subagents == "off" and .stage.delegation.maxChildren == 0)] | length' "$graph")" -eq 3 ]
  [ "$(jq '[.edges[].reasons[] | select(startswith("artifact:"))] | length' "$graph")" -eq 0 ]
  [ "$(jq '[.edges[].reasons[] | select(. != "declared" and . != "repair-epoch" and . != "consensus-barrier")] | length' "$graph")" -eq 0 ]
  [ "$(jq '[.verificationProfiles[].name] | sort | join(",")' -r "$graph")" = "fast,full" ]

  printf 'variant=%s lanes=%s mode=%s nodes=%s edges=%s\n' \
    "$name" "$lanes" "$mode" "$(jq '.nodes | length' "$graph")" \
    "$(jq '.edges | length' "$graph")" >>"$ARTIFACT_LOG"
}

@test "parallel implementation preset generates compiles validates and renders snapshot lanes two through four" {
  generate_compile_validate_render snapshot-two 2 snapshot
  generate_compile_validate_render snapshot-three 3 snapshot
  generate_compile_validate_render snapshot-four 4 snapshot

  local run_dir="$TEST_WORKSPACE/.ralph-workspace/graph-runs/preset/base-check"
  mkdir -p "$run_dir"
  printf '%s\n' '{"schemaVersion":1,"ralphVersion":"test","runId":"base-check","status":"running"}' >"$run_dir/run.json"
  graph_run_base_prepare "$run_dir" \
    "$(jq -cn --arg root "$TEST_WORKSPACE" --arg state "$TEST_WORKSPACE/.ralph-workspace" \
      '{projectRoot:$root,stateRoot:$state,agentWorkspace:$root}')" '["snapshot"]'
  [ "$(jq -r '.sourceBase.immutable' "$run_dir/run.json")" = "true" ]
  [ "$(find "$run_dir" -maxdepth 1 -type d -name base | wc -l | tr -d ' ')" -eq 1 ]
}

@test "parallel implementation preset supports explicit worktree and acknowledged shared variants" {
  generate_compile_validate_render worktree-three 3 worktree
  generate_compile_validate_render shared-three 3 shared \
    --acknowledge-shared-mutation-risk --publish-checkpoint

  local shared_graph="$TEST_WORKSPACE/shared-three.graph.json"
  [ "$(jq '[.nodes[] | select(.id | test("^lane-[1-4]$")) | select(.stage.parallelMutation == "allow" and .stage.acknowledgeSharedMutationRisk == true)] | length' "$shared_graph")" -eq 3 ]
  [ "$(jq '[.nodes[] | select(.id == "publish-checkpoint" and .type == "checkpoint")] | length' "$shared_graph")" -eq 1 ]
}

@test "parallel implementation preset refuses unacknowledged shared mutation" {
  run bash "$CREATE_PLAN" --workspace "$TEST_WORKSPACE" --format graph \
    --preset parallel-implementation --name unsafe --lanes 2 --workspace-mode shared
  [ "$status" -ne 0 ]
  [[ "$output" == *"--acknowledge-shared-mutation-risk"* ]]
}

@test "compiler rejects overlapping lane scopes unless one downstream owner is explicit" {
  local plan="$TEST_WORKSPACE/overlap.plan.md"
  local accepted="$TEST_WORKSPACE/accepted.plan.md"
  cat >"$plan" <<'EOF'
---
execution: graph
pipeline:
  stages:
    - id: left
      runtime: cursor
      agent: implementation
      workspaceMode: snapshot
      writeScopes: [src/shared/**]
    - id: right
      runtime: codex
      agent: implementation
      workspaceMode: snapshot
      writeScopes: [src/shared/api/**]
    - id: integration-owner
      type: integrate
      ownershipRole: integration
      workspaceMode: snapshot
      dependsOn: [left, right]
todos: []
---
EOF
  run plan_pipeline_graph_json "$plan"
  [ "$status" -ne 0 ]
  [[ "$output" == *"overlapOwner"* ]]

  awk '/writeScopes:/{print "      overlapOwner: integration-owner"} {print}' "$plan" >"$accepted"
  run plan_pipeline_graph_json "$accepted"
  [ "$status" -eq 0 ]
}
