#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

require_bash_four_or_skip() {
  if (( BASH_VERSINFO[0] < 4 )); then
    skip "bash >= 4 is required for orchestrator stage tests"
  fi
}

setup_orchestrator_workspace() {
  local workspace
  workspace="$(mktemp -d)"
  mkdir -p "$workspace/.ralph/bash-lib"
  cp "$REPO_ROOT/.ralph/ralph-env-safety.sh" "$workspace/.ralph/"
  cp "$REPO_ROOT/.ralph/bash-lib/orchestrator-lib.sh" "$workspace/.ralph/bash-lib/"
  cat <<'STUB' > "$workspace/.ralph/run-plan.sh"
#!/usr/bin/env bash
set -euo pipefail
printf 'stub run-plan received %s\n' "${*@Q}"
exit 0
STUB
  chmod +x "$workspace/.ralph/run-plan.sh"
  mkdir -p "$workspace/.agents/logs"
  printf '%s' "$workspace"
}

write_plan_file() {
  local workspace="$1"
  local plan_rel="$2"
  mkdir -p "$workspace/$(dirname "$plan_rel")"
  cat <<'PLAN' > "$workspace/$plan_rel"
# Plan: $(basename "$plan_rel")
- [ ] placeholder TODO
PLAN
}

write_artifact_file() {
  local workspace="$1"
  local artifact_rel="$2"
  mkdir -p "$workspace/$(dirname "$artifact_rel")"
  printf 'artifact placeholder for %s\n' "$(basename "$artifact_rel")" > "$workspace/$artifact_rel"
}

create_dry_run_orchestration() {
  local workspace="$1"
  local orch_path="$workspace/dry-run.orch.json"
  cat <<'DRY_ORCH' > "$orch_path"
{
  "name": "bats dry-run",
  "namespace": "bats-dry",
  "stages": [
    {
      "id": "dry",
      "agent": "dry-runner",
      "runtime": "cursor",
      "plan": "stages/dry-plan.md",
      "artifacts": [
        {
          "path": ".agents/artifacts/bats-dry/dry-output.md",
          "required": true
        }
      ]
    }
  ]
}
DRY_ORCH
  write_plan_file "$workspace" "stages/dry-plan.md"
  write_artifact_file "$workspace" ".agents/artifacts/bats-dry/dry-output.md"
  printf '%s' "$orch_path"
}

create_loop_orchestration() {
  local workspace="$1"
  local orch_path="$workspace/loop.orch.json"
  cat <<'LOOP_ORCH' > "$orch_path"
{
  "name": "bats loop",
  "namespace": "bats-loop",
  "stages": [
    {
      "id": "start",
      "agent": "start-agent",
      "runtime": "cursor",
      "plan": "stages/start.plan.md",
      "artifacts": [
        {
          "path": ".agents/artifacts/bats-loop/start-output.md",
          "required": true
        }
      ]
    },
    {
      "id": "review",
      "agent": "review-agent",
      "runtime": "cursor",
      "plan": "stages/review.plan.md",
      "artifacts": [
        {
          "path": ".agents/artifacts/bats-loop/review-output.md",
          "required": true
        }
      ],
      "loopControl": {
        "loopBackTo": "start",
        "maxIterations": 2
      }
    }
  ]
}
LOOP_ORCH
  write_plan_file "$workspace" "stages/start.plan.md"
  write_plan_file "$workspace" "stages/review.plan.md"
  write_artifact_file "$workspace" ".agents/artifacts/bats-loop/start-output.md"
  write_artifact_file "$workspace" ".agents/artifacts/bats-loop/review-output.md"
  printf '%s' "$orch_path"
}

@test "orchestrator prints usage when asked for help" {
  run bash "$REPO_ROOT/.ralph/orchestrator.sh" -h
  [ "$status" -eq 1 ]
  [[ "$output" == *".ralph/orchestrator.sh --orchestration"* ]]
}

@test "orchestrator reports invalid JSON during validation" {
  local workspace
  workspace="$(setup_orchestrator_workspace)"
  local bad_orch="$workspace/invalid.orch.json"
  cat <<'BAD' > "$bad_orch"
{
BAD
  run bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$bad_orch" "$workspace"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Orchestrator parse error: invalid JSON"* ]]
  rm -rf "$workspace"
}

@test "orchestrator dry-run prints each planned step" {
  require_bash_four_or_skip
  local workspace
  workspace="$(setup_orchestrator_workspace)"
  local orch_file
  orch_file="$(create_dry_run_orchestration "$workspace")"
  run env ORCHESTRATOR_DRY_RUN=1 bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$orch_file" "$workspace"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY RUN step 1: .ralph/run-plan.sh (runtime=cursor)"* ]]
  [[ "$output" == *"--agent dry-runner --plan stages/dry-plan.md"* ]]
  [[ "$output" == *"expected artifacts: .agents/artifacts/bats-dry/dry-output.md"* ]]
  rm -rf "$workspace"
}

@test "orchestrator loops back to an earlier stage when configured" {
  require_bash_four_or_skip
  local workspace
  workspace="$(setup_orchestrator_workspace)"
  local orch_file
  orch_file="$(create_loop_orchestration "$workspace")"
  run bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$orch_file" "$workspace"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Step 2 completed with feedback loop"* ]]
  [[ "$output" == *"Looping back to: start (iteration 2)"* ]]
  rm -rf "$workspace"
}
