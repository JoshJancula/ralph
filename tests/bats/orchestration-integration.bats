#!/usr/bin/env bats

# Integration tests for orchestration with subdirectory structure
# Tests that .ralph/orchestrator.sh can parse and execute with new paths

setup() {
  export WORKSPACE="$(pwd)"
}

teardown() {
  # Clean up test logs
  rm -f "$WORKSPACE/.agents/logs/orchestrator-test-*.log" 2>/dev/null || true
}

@test "orchestrator dry-run parses dashboard orchestration with subdirectory paths" {
  run bash -c "cd '$WORKSPACE' && ORCHESTRATOR_DRY_RUN=1 .ralph/orchestrator.sh .agents/orchestration-plans/dashboard/dashboard.orch.json 2>&1"
  [ "$status" -eq 0 ]
  
  # Verify it processed all 3 stages
  [[ "$output" =~ "DRY RUN step 1:" ]]
  [[ "$output" =~ "DRY RUN step 2:" ]]
  [[ "$output" =~ "DRY RUN step 3:" ]]
  
  # Verify paths show the subdirectory structure
  [[ "$output" =~ ".agents/orchestration-plans/dashboard/dashboard-01-requirements.plan.md" ]]
  [[ "$output" =~ ".agents/orchestration-plans/dashboard/dashboard-02-implementation.plan.md" ]]
  [[ "$output" =~ ".agents/orchestration-plans/dashboard/dashboard-03-review.plan.md" ]]
}

@test "orchestrator logs plan paths with subdirectory structure" {
  cd "$WORKSPACE"
  ORCHESTRATOR_DRY_RUN=1 ORCHESTRATOR_VERBOSE=1 .ralph/orchestrator.sh .agents/orchestration-plans/dashboard/dashboard.orch.json >/dev/null 2>&1
  
  local log_file="$WORKSPACE/.agents/logs/orchestrator-dashboard.orch.log"
  [[ -f "$log_file" ]]
  
  # Check that log contains the correct paths
  grep -q "orchestration-plans/dashboard/dashboard-01-requirements.plan.md" "$log_file"
  grep -q "orchestration-plans/dashboard/dashboard-02-implementation.plan.md" "$log_file"
  grep -q "orchestration-plans/dashboard/dashboard-03-review.plan.md" "$log_file"
}

@test "orchestrator finds all dashboard plan files in subdirectory" {
  cd "$WORKSPACE"
  
  # Run with verbose to ensure no "file not found" errors
  run bash -c "ORCHESTRATOR_DRY_RUN=1 .ralph/orchestrator.sh .agents/orchestration-plans/dashboard/dashboard.orch.json 2>&1"
  [ "$status" -eq 0 ]
  
  # Should NOT see "plan file not found"
  [[ ! "$output" =~ "plan file not found" ]]
}

@test "orchestrator validates artifact paths for dashboard namespace" {
  cd "$WORKSPACE"
  
  run bash -c "ORCHESTRATOR_DRY_RUN=1 .ralph/orchestrator.sh .agents/orchestration-plans/dashboard/dashboard.orch.json 2>&1"
  [ "$status" -eq 0 ]
  
  # Verify artifact expectations
  [[ "$output" =~ ".agents/artifacts/dashboard/research.md" ]]
  [[ "$output" =~ ".agents/artifacts/dashboard/implementation-handoff.md" ]]
  [[ "$output" =~ ".agents/artifacts/dashboard/code-review.md" ]]
}

@test "orchestrator respects namespace from JSON with subdirectory structure" {
  cd "$WORKSPACE"
  
  local namespace=$(jq -r '.namespace' ".agents/orchestration-plans/dashboard/dashboard.orch.json")
  [ "$namespace" = "dashboard" ]
  
  # Run and verify namespace appears in artifact paths
  run bash -c "ORCHESTRATOR_DRY_RUN=1 .ralph/orchestrator.sh .agents/orchestration-plans/dashboard/dashboard.orch.json 2>&1"
  [[ "$output" =~ "artifacts/dashboard/" ]]
}
