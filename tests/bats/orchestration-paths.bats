#!/usr/bin/env bats

# Test orchestration plan path resolution with subdirectories
# Verifies that .agents/orchestration-plans/<namespace>/<files> structure is correctly parsed

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"
source "$RALPH_LIB_ROOT/orchestrator-lib.sh"

setup() {
  export WORKSPACE="$(pwd)"
  export ORCH_BASENAME="test-orch"
  export RALPH_ARTIFACT_NS="test-namespace"
  EXPECTED_ARTIFACT_PATHS=()
}

@test "orchestration JSON with subdirectory plan paths can be parsed" {
  local orch_json=".agents/orchestration-plans/test-namespace/test.orch.json"
  
  # Verify the file exists (it's the dashboard one)
  if [[ -f ".agents/orchestration-plans/dashboard/dashboard.orch.json" ]]; then
    run jq empty ".agents/orchestration-plans/dashboard/dashboard.orch.json"
    [ "$status" -eq 0 ]
  fi
}

@test "orchestration plan stage paths resolve correctly with subdirectories" {
  # Test relative paths in subdirectories
  result="$(orchestrator_stage_plan_abs ".agents/orchestration-plans/dashboard/dashboard-01-requirements.plan.md" "$WORKSPACE")"
  [[ "$result" == "$WORKSPACE/.agents/orchestration-plans/dashboard/dashboard-01-requirements.plan.md" ]]
  
  # Test absolute paths work too
  result="$(orchestrator_stage_plan_abs "/tmp/plans/feature/stage.md" "$WORKSPACE")"
  [ "$result" = "/tmp/plans/feature/stage.md" ]
}

@test "dashboard orchestration JSON has correct plan paths in subdirectory" {
  if [[ -f ".agents/orchestration-plans/dashboard/dashboard.orch.json" ]]; then
    # Check that plan paths reference the subdirectory
    local plan1=$(jq -r '.stages[0].plan' ".agents/orchestration-plans/dashboard/dashboard.orch.json")
    [[ "$plan1" == ".agents/orchestration-plans/dashboard/dashboard-01-requirements.plan.md" ]]
    
    local plan2=$(jq -r '.stages[1].plan' ".agents/orchestration-plans/dashboard/dashboard.orch.json")
    [[ "$plan2" == ".agents/orchestration-plans/dashboard/dashboard-02-implementation.plan.md" ]]
    
    local plan3=$(jq -r '.stages[2].plan' ".agents/orchestration-plans/dashboard/dashboard.orch.json")
    [[ "$plan3" == ".agents/orchestration-plans/dashboard/dashboard-03-review.plan.md" ]]
  fi
}

@test "dashboard orchestration files exist in subdirectory" {
  # Verify all files moved to the subdirectory
  [[ -f ".agents/orchestration-plans/dashboard/dashboard.orch.json" ]]
  [[ -f ".agents/orchestration-plans/dashboard/dashboard-01-requirements.plan.md" ]]
  [[ -f ".agents/orchestration-plans/dashboard/dashboard-02-implementation.plan.md" ]]
  [[ -f ".agents/orchestration-plans/dashboard/dashboard-03-review.plan.md" ]]
}

@test "no orphaned orchestration files at root level" {
  # Verify old files were removed
  [[ ! -f ".agents/orchestration-plans/dashboard.orch.json" ]]
  [[ ! -f ".agents/orchestration-plans/dashboard-01-requirements.plan.md" ]]
  [[ ! -f ".agents/orchestration-plans/dashboard-02-implementation.plan.md" ]]
  [[ ! -f ".agents/orchestration-plans/dashboard-03-review.plan.md" ]]
}

@test "orchestration template uses namespace placeholders for subdirectories" {
  if [[ -f ".ralph/orchestration.template.json" ]]; then
    local plan_path=$(jq -r '.stages[0].plan' ".ralph/orchestration.template.json")
    # Should contain {{ARTIFACT_NS}} placeholder for subdirectory structure
    [[ "$plan_path" == *"orchestration-plans/{{ARTIFACT_NS}}"* ]]
  fi
}

@test "dashboard namespace matches subdirectory name" {
  if [[ -f ".agents/orchestration-plans/dashboard/dashboard.orch.json" ]]; then
    local namespace=$(jq -r '.namespace' ".agents/orchestration-plans/dashboard/dashboard.orch.json")
    [ "$namespace" = "dashboard" ]
  fi
}

@test "directory structure is consistent across .agents subdirs" {
  # Verify the pattern: .agents/<type>/<namespace>/
  # .agents/artifacts/dashboard/ exists
  [[ -d ".agents/artifacts/dashboard" ]]
  
  # .agents/logs/dashboard/ exists
  [[ -d ".agents/logs/dashboard" ]]
  
  # .agents/orchestration-plans/dashboard/ exists
  [[ -d ".agents/orchestration-plans/dashboard" ]]
}

@test "orchestration plan file is readable as markdown" {
  if [[ -f ".agents/orchestration-plans/dashboard/dashboard-01-requirements.plan.md" ]]; then
    run head -1 ".agents/orchestration-plans/dashboard/dashboard-01-requirements.plan.md"
    [ "$status" -eq 0 ]
    [[ "$output" == "#"* ]]
  fi
}

@test "expand_artifact_tokens works with namespace subdirectory paths" {
  export RALPH_ARTIFACT_NS="my-feature"
  
  result="$(expand_artifact_tokens ".agents/orchestration-plans/{{ARTIFACT_NS}}/stage-01.plan.md")"
  [ "$result" = ".agents/orchestration-plans/my-feature/stage-01.plan.md" ]
}
