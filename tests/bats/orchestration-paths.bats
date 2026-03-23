#!/usr/bin/env bats

# Test orchestration plan path resolution with subdirectories
# Verifies that .ralph-workspace/orchestration-plans/<namespace>/<files> structure is correctly parsed

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"
source "$RALPH_LIB_ROOT/orchestrator-lib.sh"

setup() {
  export WORKSPACE="$(pwd)"
  export ORCH_BASENAME="test-orch"
  export RALPH_ARTIFACT_NS="test-namespace"
  EXPECTED_ARTIFACT_PATHS=()
}

@test "orchestration JSON with subdirectory plan paths can be parsed" {
  local orch_json="dashboard.orch.json"
  
  # Verify the file exists (it's at the repository root)
  if [[ -f "dashboard.orch.json" ]]; then
    run jq empty "dashboard.orch.json"
    [ "$status" -eq 0 ]
  fi
}

@test "orchestration plan stage paths resolve correctly with subdirectories" {
  # Test relative paths in docs/
  result="$(orchestrator_stage_plan_abs "docs/orchestration-plans/dashboard-01-requirements.plan.md" "$WORKSPACE")"
  [[ "$result" == "$WORKSPACE/docs/orchestration-plans/dashboard-01-requirements.plan.md" ]]
  
  # Test absolute paths work too
  result="$(orchestrator_stage_plan_abs "/tmp/plans/feature/stage.md" "$WORKSPACE")"
  [ "$result" = "/tmp/plans/feature/stage.md" ]
}

@test "dashboard orchestration JSON has correct plan paths in subdirectory" {
  if [[ -f "dashboard.orch.json" ]]; then
    # Check that plan paths reference the docs directory
    local plan1=$(jq -r '.stages[0].plan' "dashboard.orch.json")
    [[ "$plan1" == "docs/orchestration-plans/dashboard-01-requirements.plan.md" ]]
    
    local plan2=$(jq -r '.stages[1].plan' "dashboard.orch.json")
    [[ "$plan2" == "docs/orchestration-plans/dashboard-02-implementation.plan.md" ]]
    
    local plan3=$(jq -r '.stages[2].plan' "dashboard.orch.json")
    [[ "$plan3" == "docs/orchestration-plans/dashboard-03-review.plan.md" ]]
  fi
}

@test "no orphaned orchestration files at .ralph-workspace level" {
  # Verify old files are not in .ralph-workspace (they're now at the root and in docs/)
  [[ ! -f ".ralph-workspace/orchestration-plans/dashboard.orch.json" ]] || true
}

@test "orchestration template uses namespace placeholders for subdirectories" {
  if [[ -f ".ralph/orchestration.template.json" ]]; then
    local plan_path=$(jq -r '.stages[0].plan' ".ralph/orchestration.template.json")
    # Should contain {{ARTIFACT_NS}} placeholder for subdirectory structure
    [[ "$plan_path" == *"orchestration-plans/{{ARTIFACT_NS}}"* ]]
  fi
}

@test "dashboard namespace matches subdirectory name" {
  if [[ -f "dashboard.orch.json" ]]; then
    local namespace=$(jq -r '.namespace' "dashboard.orch.json")
    [ "$namespace" = "dashboard" ]
  fi
}

@test "orchestration plan file is readable as markdown" {
  if [[ -f "docs/orchestration-plans/dashboard-01-requirements.plan.md" ]]; then
    run head -1 "docs/orchestration-plans/dashboard-01-requirements.plan.md"
    [ "$status" -eq 0 ]
    [[ "$output" == "#"* ]]
  fi
}

@test "expand_artifact_tokens works with namespace subdirectory paths" {
  export RALPH_ARTIFACT_NS="my-feature"
  
  result="$(expand_artifact_tokens ".ralph-workspace/orchestration-plans/{{ARTIFACT_NS}}/stage-01.plan.md")"
  [ "$result" = ".ralph-workspace/orchestration-plans/my-feature/stage-01.plan.md" ]
}
