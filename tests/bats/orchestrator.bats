#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

setup_orchestrator_workspace() {
  local workspace
  workspace="$(mktemp -d)"
  mkdir -p "$workspace/.ralph/bash-lib"
  cp "$REPO_ROOT/.ralph/ralph-env-safety.sh" "$workspace/.ralph/"
  cp "$REPO_ROOT/.ralph/bash-lib/orchestrator-lib.sh" "$workspace/.ralph/bash-lib/"
  cat <<'STUB' > "$workspace/.ralph/run-plan.sh"
#!/usr/bin/env bash
set -euo pipefail
printf 'stub run-plan received %s\n' "$*"
exit 0
STUB
  chmod +x "$workspace/.ralph/run-plan.sh"
  mkdir -p "$workspace/.ralph-workspace/logs"
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
          "path": ".ralph-workspace/artifacts/bats-dry/dry-output.md",
          "required": true
        }
      ]
    }
  ]
}
DRY_ORCH
  write_plan_file "$workspace" "stages/dry-plan.md"
  write_artifact_file "$workspace" ".ralph-workspace/artifacts/bats-dry/dry-output.md"
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
          "path": ".ralph-workspace/artifacts/bats-loop/start-output.md",
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
          "path": ".ralph-workspace/artifacts/bats-loop/review-output.md",
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
  write_artifact_file "$workspace" ".ralph-workspace/artifacts/bats-loop/start-output.md"
  write_artifact_file "$workspace" ".ralph-workspace/artifacts/bats-loop/review-output.md"
  printf '%s' "$orch_path"
}

create_human_ack_orchestration() {
  local workspace="$1"
  local orch_path="$workspace/human-ack.orch.json"
  cat <<'HUM_ORCH' > "$orch_path"
{
  "name": "bats human ack",
  "namespace": "bats-human-ack",
  "stages": [
    {
      "id": "human-ack-stage",
      "agent": "human-ack-agent",
      "runtime": "cursor",
      "plan": "stages/human-ack.plan.md",
      "humanAck": {
        "path": ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/human-ack.txt",
        "message": "Confirm you reviewed the stage artifacts."
      }
    }
  ]
}
HUM_ORCH
  write_plan_file "$workspace" "stages/human-ack.plan.md"
  printf '%s' "$orch_path"
}

@test "orchestrator prints usage when asked for help" {
  run bash "$REPO_ROOT/.ralph/orchestrator.sh" -h
  [ "$status" -eq 0 ]
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
  [ "$status" -ne 0 ] \
    && [[ "$output" == *"Orchestrator parse error: invalid JSON"* ]] \
    || return 1
  rm -rf "$workspace"
}

@test "orchestrator dry-run prints each planned step" {
  local workspace
  workspace="$(setup_orchestrator_workspace)"
  local orch_file
  orch_file="$(create_dry_run_orchestration "$workspace")"
  run env ORCHESTRATOR_DRY_RUN=1 bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$orch_file" "$workspace"
  [ "$status" -eq 0 ] \
    && [[ "$output" == *"DRY RUN step 1: .ralph/run-plan.sh (runtime=cursor)"* ]] \
    && [[ "$output" == *"--agent dry-runner --plan stages/dry-plan.md"* ]] \
    && [[ "$output" == *"expected artifacts: .ralph-workspace/artifacts/bats-dry/dry-output.md"* ]] \
    || return 1
  rm -rf "$workspace"
}

@test "orchestrator dry-run prints cli-resume when sessionResume true" {
  local workspace
  workspace="$(setup_orchestrator_workspace)"
  local orch_file="$workspace/session-resume.orch.json"
  cat <<'RESUME' > "$orch_file"
{
  "name": "bats session resume",
  "namespace": "bats-resume",
  "stages": [
    {
      "id": "resume-stage",
      "agent": "resume-agent",
      "runtime": "cursor",
      "plan": "stages/resume.plan.md",
      "sessionResume": true,
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/bats-resume/resume-output.md",
          "required": true
        }
      ]
    }
  ]
}
RESUME
  write_plan_file "$workspace" "stages/resume.plan.md"
  write_artifact_file "$workspace" ".ralph-workspace/artifacts/bats-resume/resume-output.md"
  run env ORCHESTRATOR_DRY_RUN=1 bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$orch_file" "$workspace"
  [ "$status" -eq 0 ] \
    && [[ "$output" == *"--cli-resume"* ]] \
    && [[ "$output" != *"--no-cli-resume"* ]] \
    || return 1
  rm -rf "$workspace"
}

@test "orchestrator rejects invalid sessionResume values" {
  local workspace
  workspace="$(setup_orchestrator_workspace)"
  local orch_file
  orch_file="$workspace/invalid-session-resume.orch.json"
  cat <<'BAD' > "$orch_file"
{
  "name": "bats invalid resume",
  "namespace": "bats-invalid-resume",
  "stages": [
    {
      "id": "invalid-session",
      "agent": "invalid-agent",
      "runtime": "cursor",
      "plan": "stages/invalid-session.plan.md",
      "sessionResume": "not-a-boolean"
    }
  ]
}
BAD
  write_plan_file "$workspace" "stages/invalid-session.plan.md"
  run env ORCHESTRATOR_DRY_RUN=1 bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$orch_file" "$workspace"
  local output_lc
  output_lc="$(printf '%s' "$output" | tr '[:upper:]' '[:lower:]')"
  [ "$status" -ne 0 ] \
    && [[ "$output_lc" == *"sessionresume"* ]] \
    && [[ "$output_lc" == *"boolean"* ]] \
    || return 1
  rm -rf "$workspace"
}

@test "orchestrator loops back to an earlier stage when configured" {
  local workspace
  workspace="$(setup_orchestrator_workspace)"
  local orch_file
  orch_file="$(create_loop_orchestration "$workspace")"
  run bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$orch_file" "$workspace"
  [ "$status" -eq 0 ] \
    && [[ "$output" == *"Step 2 completed with feedback loop"* ]] \
    && [[ "$output" == *"Looping back to: start (iteration 2)"* ]] \
    || return 1
  rm -rf "$workspace"
}

@test "orchestrator honors humanAck gates when enabled" {
  local workspace
  workspace="$(setup_orchestrator_workspace)"
  local orch_file
  orch_file="$(create_human_ack_orchestration "$workspace")"
  run env ORCHESTRATOR_HUMAN_ACK=1 bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$orch_file" "$workspace"
  [ "$status" -eq 3 ] \
    && [[ "$output" == *"Human acknowledgment required"* ]] \
    || return 1
  local ack_file="$workspace/.ralph-workspace/artifacts/bats-human-ack/human-ack.txt"
  mkdir -p "$(dirname "$ack_file")"
  : >"$ack_file"
  run env ORCHESTRATOR_HUMAN_ACK=1 bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$orch_file" "$workspace"
  [ "$status" -eq 0 ] || return 1
  rm -rf "$workspace"
}
