#!/usr/bin/env bats
# Graph compiler: overlapping lane writeScopes must be refused unless one
# downstream node explicitly owns the overlap.
#
# History: this test lived in create-parallel-implementation-preset.bats
# alongside four tests for the `ralph create plan --format graph --preset
# parallel-implementation` route. That route was removed and the preset was
# never rewired to a public command, so those four tests asserted a feature no
# user could reach and were deleted with the preset renderers. This assertion is
# about the compiler, not the preset, so it is kept -- and it is cheap, so it
# belongs in the default tier rather than acceptance.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$REPO_ROOT/bundle/.ralph/bash-lib/plan-todo.sh"

setup() {
  TEST_WORKSPACE="$(mktemp -d)"
  export RALPH_VERSION="test"
}

teardown() {
  chmod -R u+w "$TEST_WORKSPACE" 2>/dev/null || true
  rm -rf "$TEST_WORKSPACE"
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
      workspaceMode: snapshot
      writeScopes: [src/shared/**]
    - id: right
      runtime: codex
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
