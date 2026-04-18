#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

setup_orchestrator_workspace() {
  local workspace
  workspace="$(mktemp -d)"
  mkdir -p "$workspace/.ralph/bash-lib"
  cp "$REPO_ROOT/.ralph/ralph-env-safety.sh" "$workspace/.ralph/"
  cp "$REPO_ROOT/.ralph/bash-lib/error-handling.sh" "$workspace/.ralph/bash-lib/"
  cp "$REPO_ROOT/.ralph/bash-lib/orchestrator-logging.sh" "$workspace/.ralph/bash-lib/"
  cp "$REPO_ROOT/.ralph/bash-lib/orchestrator-lib.sh" "$workspace/.ralph/bash-lib/"
  cp "$REPO_ROOT/.ralph/bash-lib/ralph-format-elapsed.sh" "$workspace/.ralph/bash-lib/"
  cp "$REPO_ROOT/.ralph/bash-lib/orchestrator-verify.sh" "$workspace/.ralph/bash-lib/"
  cp "$REPO_ROOT/.ralph/bash-lib/orchestrator-handoffs.sh" "$workspace/.ralph/bash-lib/"
  cp "$REPO_ROOT/.ralph/bash-lib/orchestrator-stages.sh" "$workspace/.ralph/bash-lib/"
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

setup_handoff_capture_workspace() {
  local workspace
  workspace="$(setup_orchestrator_workspace)"
# Validate the plan exactly as run-plan sees it so the test can prove injection timing.
  cat <<'STUB' > "$workspace/.ralph/run-plan.sh"
#!/usr/bin/env bash
set -euo pipefail
plan_path=""
while (($# > 0)); do
  case "$1" in
    --plan)
      plan_path="${2:-}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [[ -n "$plan_path" && "$(basename "$plan_path")" == "consumer.plan.md" ]]; then
  grep -q "RALPH_HANDOFF: from=producer iter=1" "$plan_path" || {
    echo "expected injected handoff before run-plan invocation" >&2
    exit 42
  }
  grep -q "Injected task from producer stage" "$plan_path" || {
    echo "expected injected tasks before run-plan invocation" >&2
    exit 42
  }
fi

printf 'stub run-plan received %s\n' "$*"
exit 0
STUB
  chmod +x "$workspace/.ralph/run-plan.sh"
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

create_handoff_injection_orchestration() {
  local workspace="$1"
  local orch_path="$workspace/handoff-injection.orch.json"
  cat <<ORCH > "$orch_path"
{
  "name": "bats handoff injection",
  "namespace": "handoff-order",
  "stages": [
    {
      "id": "producer",
      "agent": "producer-agent",
      "runtime": "cursor",
      "plan": "stages/producer.plan.md",
      "outputArtifacts": [
        {
          "path": "$workspace/.ralph-workspace/artifacts/{{ARTIFACT_NS}}/handoff-a-to-b.md",
          "kind": "handoff",
          "to": "consumer"
        }
      ]
    },
    {
      "id": "consumer",
      "agent": "consumer-agent",
      "runtime": "cursor",
      "plan": "stages/consumer.plan.md"
    }
  ]
}
ORCH
  write_plan_file "$workspace" "stages/producer.plan.md"
  write_plan_file "$workspace" "stages/consumer.plan.md"
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

create_parallel_orchestration() {
  local workspace="$1"
  local orch_path="$workspace/parallel.orch.json"
  local runtime="${2:-cursor}"
  local stage_one_id="${3:-alpha-one}"
  local stage_two_id="${4:-beta-two}"
  local stage_one_plan="${5:-stages/parallel-stage-one.plan.md}"
  local stage_two_plan="${6:-stages/parallel-stage-two.plan.md}"
  local stage_one_artifact="${7:-.ralph-workspace/artifacts/bats-parallel/alpha-one.md}"
  local stage_two_artifact="${8:-.ralph-workspace/artifacts/bats-parallel/beta-two.md}"
  local stage_two_agent="${9:-parallel-agent-two}"

  cat <<ORCH > "$orch_path"
{
  "name": "bats parallel",
  "namespace": "bats-parallel",
  "parallelStages": [
    "$stage_one_id,$stage_two_id"
  ],
  "stages": [
    {
      "id": "$stage_one_id",
      "agent": "parallel-agent-one",
      "runtime": "$runtime",
      "plan": "$stage_one_plan",
      "artifacts": [
        {
          "path": "$stage_one_artifact",
          "required": true
        }
      ]
    },
    {
      "id": "$stage_two_id",
      "agent": "$stage_two_agent",
      "runtime": "$runtime",
      "plan": "$stage_two_plan",
      "artifacts": [
        {
          "path": "$stage_two_artifact",
          "required": true
        }
      ]
    }
  ]
}
ORCH
  write_plan_file "$workspace" "$stage_one_plan"
  write_plan_file "$workspace" "$stage_two_plan"
  printf '%s' "$orch_path"
}

setup_parallel_workspace() {
  local workspace
  workspace="$(setup_orchestrator_workspace)"
  mkdir -p "$workspace/.ralph-workspace/logs/PLAN"
  cat <<'STUB' > "$workspace/.ralph/run-plan.sh"
#!/usr/bin/env bash
set -euo pipefail
plan_path=""
while (($# > 0)); do
  if [[ "$1" == --plan ]]; then
    plan_path="${2:-}"
    break
  fi
  shift
done
printf '%s\n' "${plan_path##*/}" >> "${PARALLEL_CAPTURE_FILE:-/dev/null}"
if [[ -n "${PARALLEL_FAIL_PLAN:-}" && "${plan_path##*/}" == "${PARALLEL_FAIL_PLAN}" ]]; then
  exit 7
fi
if [[ -n "${PARALLEL_SKIP_ARTIFACT_PLAN:-}" && "${plan_path##*/}" == "${PARALLEL_SKIP_ARTIFACT_PLAN}" ]]; then
  exit 0
fi
if [[ -n "${PARALLEL_OUTPUT_FILE:-}" ]]; then
  printf 'artifact output for %s\n' "${plan_path##*/}" > "$PARALLEL_OUTPUT_FILE"
fi
exit 0
STUB
  chmod +x "$workspace/.ralph/run-plan.sh"
  printf '%s' "$workspace"
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
  run bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$bad_orch" "$workspace" 2>&1
  [ "$status" -ne 0 ] \
    && [[ "$output" == *"Orchestrator parse error: invalid JSON"* ]] \
    || return 1
  rm -rf "$workspace"
}

@test "orchestrator dry-run prints each planned step" {
  [[ -n "${CI:-}" ]] && skip "Temporarily skipped in CI due shell-specific output variance"
  local workspace
  workspace="$(setup_orchestrator_workspace)"
  local orch_file
  orch_file="$(create_dry_run_orchestration "$workspace")"
  run env ORCHESTRATOR_DRY_RUN=1 bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$orch_file" "$workspace" 2>&1
  [ "$status" -eq 0 ] \
    && [[ "$output" == *"DRY RUN step 1: .ralph/run-plan.sh (runtime=cursor)"* ]] \
    && [[ "$output" == *"--agent dry-runner --plan stages/dry-plan.md"* ]] \
    && [[ "$output" == *"expected artifacts: .ralph-workspace/artifacts/bats-dry/dry-output.md"* ]] \
    || return 1
  rm -rf "$workspace"
}

@test "orchestrator ignores inherited workspace root env override" {
  local workspace
  workspace="$(setup_orchestrator_workspace)"
  local orch_file
  orch_file="$(create_dry_run_orchestration "$workspace")"
  run env ORCHESTRATOR_DRY_RUN=1 RALPH_PLAN_WORKSPACE_ROOT="$workspace/.agents" bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$orch_file" "$workspace" 2>&1
  [ "$status" -eq 0 ] || return 1
  local log_dir="$workspace/.ralph-workspace/logs"
  [ -d "$log_dir" ] || return 1
  [ ! -e "$workspace/.agents/logs/orchestrator-dry-run.orch.log" ] || return 1
  rm -rf "$workspace"
}

@test "orchestrator dry-run prints cli-resume when sessionResume true" {
  [[ -n "${CI:-}" ]] && skip "Temporarily skipped in CI due shell-specific output variance"
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
  run env ORCHESTRATOR_DRY_RUN=1 bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$orch_file" "$workspace" 2>&1
  [ "$status" -eq 0 ] \
    && [[ "$output" == *"--cli-resume"* ]] \
    && [[ "$output" != *"--no-cli-resume"* ]] \
    || return 1
  rm -rf "$workspace"
}

@test "orchestrator dry-run shows parallel wave steps" {
  [[ -n "${CI:-}" ]] && skip "Temporarily skipped in CI due shell-specific output variance"
  local workspace
  workspace="$(setup_parallel_workspace)"
  local orch_file
  orch_file="$(create_parallel_orchestration "$workspace")"
  run env ORCHESTRATOR_DRY_RUN=1 bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$orch_file" "$workspace" 2>&1
  [ "$status" -eq 0 ] \
    && [[ "$output" == *"DRY RUN step 1:"* ]] \
    && [[ "$output" == *"DRY RUN step 2:"* ]] \
    || return 1
  rm -rf "$workspace"
}

@test "orchestrator runs parallel waves successfully" {
  [[ -n "${CI:-}" ]] && skip "Temporarily skipped in CI due shell-specific output variance"
  local workspace capture_file
  workspace="$(setup_parallel_workspace)"
  capture_file="$(mktemp)"
  local orch_file
  orch_file="$(create_parallel_orchestration "$workspace")"
  write_artifact_file "$workspace" ".ralph-workspace/artifacts/bats-parallel/alpha-one.md"
  write_artifact_file "$workspace" ".ralph-workspace/artifacts/bats-parallel/beta-two.md"

  run env PARALLEL_CAPTURE_FILE="$capture_file" bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$orch_file" "$workspace" 2>&1
  [ "$status" -eq 0 ] || { echo "FAIL: $output"; rm -f "$capture_file"; rm -rf "$workspace"; return 1; }
  local captured
  captured="$(cat "$capture_file")"
  [[ "$captured" == *"parallel-stage-one.plan.md"* ]] || { echo "missing stage one capture: $captured"; rm -f "$capture_file"; rm -rf "$workspace"; return 1; }
  [[ "$captured" == *"parallel-stage-two.plan.md"* ]] || { echo "missing stage two capture: $captured"; rm -f "$capture_file"; rm -rf "$workspace"; return 1; }
  rm -f "$capture_file"
  rm -rf "$workspace"
}

@test "orchestrator reports a failing stage in a parallel wave" {
  [[ -n "${CI:-}" ]] && skip "Temporarily skipped in CI due shell-specific output variance"
  local workspace capture_file
  workspace="$(setup_parallel_workspace)"
  capture_file="$(mktemp)"
  local orch_file
  orch_file="$(create_parallel_orchestration "$workspace")"
  write_artifact_file "$workspace" ".ralph-workspace/artifacts/bats-parallel/alpha-one.md"
  write_artifact_file "$workspace" ".ralph-workspace/artifacts/bats-parallel/beta-two.md"
  run env PARALLEL_CAPTURE_FILE="$capture_file" PARALLEL_FAIL_PLAN="parallel-stage-two.plan.md" bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$orch_file" "$workspace" 2>&1
  [ "$status" -ne 0 ] \
    && [[ "$output" == *"Parallel wave 1 failed:"* ]] \
    && [[ "$output" == *"beta-two:1"* ]] \
    || { echo "FAIL: $output"; rm -f "$capture_file"; rm -rf "$workspace"; return 1; }
  rm -f "$capture_file"
  rm -rf "$workspace"
}

@test "orchestrator surfaces artifact verification failures in parallel mode" {
  [[ -n "${CI:-}" ]] && skip "Temporarily skipped in CI due shell-specific output variance"
  local workspace capture_file
  workspace="$(setup_parallel_workspace)"
  capture_file="$(mktemp)"
  local orch_file
  orch_file="$(create_parallel_orchestration "$workspace")"
  write_artifact_file "$workspace" ".ralph-workspace/artifacts/bats-parallel/alpha-one.md"

  run env PARALLEL_CAPTURE_FILE="$capture_file" PARALLEL_SKIP_ARTIFACT_PLAN="parallel-stage-two.plan.md" bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$orch_file" "$workspace" 2>&1
  [ "$status" -ne 0 ] \
    && [[ "$output" == *"Expected file missing:"* ]] \
    && [[ "$output" == *"beta-two.md"* ]] \
    || { echo "FAIL: $output"; rm -f "$capture_file"; rm -rf "$workspace"; return 1; }
  rm -f "$capture_file"
  rm -rf "$workspace"
}

@test "orchestrator rejects parallelStages with loopControl" {
  local workspace
  workspace="$(setup_orchestrator_workspace)"
  local orch_file="$workspace/parallel-loop.orch.json"
  cat <<'ORCH' > "$orch_file"
{
  "name": "bats parallel loop",
  "namespace": "bats-parallel-loop",
  "parallelStages": [
    "stage-one"
  ],
  "stages": [
    {
      "id": "stage-one",
      "agent": "parallel-agent-one",
      "runtime": "cursor",
      "plan": "stages/parallel-loop.plan.md",
      "loopControl": {
        "loopBackTo": "stage-one",
        "maxIterations": 2
      },
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/bats-parallel-loop/stage-one.md",
          "required": true
        }
      ]
    }
  ]
}
ORCH
  write_plan_file "$workspace" "stages/parallel-loop.plan.md"
  run bash "$REPO_ROOT/scripts/validate-orchestration-schema.sh" "$orch_file" 2>&1
  [ "$status" -ne 0 ] \
    && [[ "$output" == *"schema validation failed"* ]] \
    || { echo "FAIL: $output"; rm -rf "$workspace"; return 1; }
  rm -rf "$workspace"
}

@test "orchestrator sanitizes stage id before RALPH_STAGE_ID export" {
  local workspace
  workspace="$(setup_orchestrator_workspace)"
  local orch_file="$workspace/stage-id-sanitization.orch.json"
  cat <<'SANITIZE_ORCH' > "$orch_file"
{
  "name": "bats stage id sanitization",
  "namespace": "bats-sanitization",
  "stages": [
    {
      "id": "My Stage/1",
      "agent": "sanitize-agent",
      "runtime": "cursor",
      "plan": "stages/sanitize.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/{{STAGE_ID}}.md",
          "required": true
        }
      ],
      "humanAck": {
        "path": ".ralph-workspace/human/{{STAGE_ID}}.ack",
        "message": "Confirm sanitized artifact"
      }
    }
  ]
}
SANITIZE_ORCH
  write_plan_file "$workspace" "stages/sanitize.plan.md"
  run env ORCHESTRATOR_DRY_RUN=1 ORCHESTRATOR_HUMAN_ACK=1 bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$orch_file" "$workspace" 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *".ralph-workspace/artifacts/bats-sanitization/my-stage-1.md"* ]]
  [[ "$output" == *"humanAck"* ]]
  [[ "$output" == *"my-stage-1.ack"* ]]
  rm -rf "$workspace"
}

@test "validate-orchestration-schema rejects unsafe stage id" {
  local orch_file
  orch_file="$(mktemp)"
  cat <<'BAD_ORCH' > "$orch_file"
{
  "name": "bats invalid stage id",
  "namespace": "unsafe-stage",
  "stages": [
    {
      "id": "unsafe stage/1",
      "agent": "unsafe-agent",
      "runtime": "cursor",
      "plan": "stages/unsafe.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/unsafe-stage/output.md",
          "required": true
        }
      ]
    }
  ]
}
BAD_ORCH

  run bash "$REPO_ROOT/scripts/validate-orchestration-schema.sh" "$orch_file" 2>&1
  [ "$status" -ne 0 ] \
    && [[ "$output" == *"Orchestration schema validation failed"* ]] \
    || return 1
  rm -f "$orch_file"
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
  run env ORCHESTRATOR_DRY_RUN=1 bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$orch_file" "$workspace" 2>&1
  local output_lc
  output_lc="$(printf '%s' "$output" | tr '[:upper:]' '[:lower:]')"
  [ "$status" -ne 0 ] \
    && [[ "$output_lc" == *"sessionresume"* ]] \
    && [[ "$output_lc" == *"boolean"* ]] \
    || return 1
  rm -rf "$workspace"
}

@test "orchestrator loops back to an earlier stage when configured" {
  [[ -n "${CI:-}" ]] && skip "Temporarily skipped in CI due shell-specific output variance"
  local workspace
  workspace="$(setup_orchestrator_workspace)"
  local orch_file
  orch_file="$(create_loop_orchestration "$workspace")"
  run bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$orch_file" "$workspace" 2>&1
  [ "$status" -eq 0 ] \
    && [[ "$output" == *"Step 2 completed with feedback loop"* ]] \
    && [[ "$output" == *"Looping back to: start (iteration 2)"* ]] \
    || return 1
  rm -rf "$workspace"
}

@test "orchestrator injects handoffs before run-plan invocation" {
  local workspace artifact_ns handoff_file orch_file consumer_plan captured
  workspace="$(setup_handoff_capture_workspace)"
  artifact_ns="handoff-order"
  handoff_file="$workspace/.ralph-workspace/artifacts/$artifact_ns/handoff-a-to-b.md"
  orch_file="$(create_handoff_injection_orchestration "$workspace")"

  mkdir -p "$(dirname "$handoff_file")"
  cat > "$handoff_file" <<'HANDOFF'
# Handoff: Producer to Consumer

<!-- HANDOFF_META: START -->
from: producer
to: stage-b
iteration: 1
<!-- HANDOFF_META: END -->

## Tasks

- [ ] Injected task from producer stage
- [ ] Confirm plan mutation before runner invocation

## Context

Generated by the plan-execution test.
HANDOFF

  run bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$orch_file" "$workspace" 2>&1
  [ "$status" -eq 0 ] || { echo "FAIL: $output"; rm -rf "$workspace"; return 1; }

  consumer_plan="$workspace/stages/consumer.plan.md"
  captured="$(cat "$consumer_plan")"
  [[ "$captured" == *"RALPH_HANDOFF: from=producer iter=1"* ]] \
    || { echo "FAIL: consumer plan missing injected handoff: $captured"; rm -rf "$workspace"; return 1; }
  [[ "$captured" == *"Injected task from producer stage"* ]] \
    || { echo "FAIL: consumer plan missing injected task: $captured"; rm -rf "$workspace"; return 1; }

  rm -rf "$workspace"
}

create_agent_config_workspace() {
  local workspace="$1"
  local agent_id="$2"
  local artifact_path="$3"
  local runtime="${4:-cursor}"
  local agents_dir
  if [[ "$runtime" == "cursor" ]]; then
    agents_dir="$workspace/.cursor/agents"
  elif [[ "$runtime" == "codex" ]]; then
    agents_dir="$workspace/.codex/agents"
  else
    agents_dir="$workspace/.claude/agents"
  fi
  mkdir -p "$agents_dir/$agent_id"
  cat > "$agents_dir/$agent_id/config.json" <<CFG
{
  "name": "$agent_id",
  "model": "test-model",
  "description": "test agent for bats",
  "rules": [],
  "skills": [],
  "output_artifacts": [
    {
      "path": "$artifact_path",
      "required": true
    }
  ]
}
CFG
  cp "$REPO_ROOT/.ralph/agent-config-tool.sh" "$workspace/.ralph/"
}

setup_model_capture_workspace() {
  local workspace
  workspace="$(setup_orchestrator_workspace)"
  # Override stub to capture env vars set by orchestrator for each stage invocation
  cat <<'STUB' > "$workspace/.ralph/run-plan.sh"
#!/usr/bin/env bash
set -euo pipefail
{
  printf 'RUNTIME=%s\n' "${1:-}"
  printf 'CURSOR_PLAN_MODEL=%s\n' "${CURSOR_PLAN_MODEL:-}"
  printf 'CLAUDE_PLAN_MODEL=%s\n' "${CLAUDE_PLAN_MODEL:-}"
  printf 'CLAUDE_PLAN_BARE=%s\n' "${CLAUDE_PLAN_BARE:-}"
  printf 'CLAUDE_PLAN_PERMISSION_MODE=%s\n' "${CLAUDE_PLAN_PERMISSION_MODE:-}"
  printf 'CODEX_PLAN_MODEL=%s\n' "${CODEX_PLAN_MODEL:-}"
  printf 'CODEX_PLAN_SANDBOX=%s\n' "${CODEX_PLAN_SANDBOX:-}"
} >> "${MODEL_CAPTURE_FILE:-/dev/null}"
exit 0
STUB
  chmod +x "$workspace/.ralph/run-plan.sh"
  printf '%s' "$workspace"
}

@test "orchestrator sets CURSOR_PLAN_MODEL env var for cursor stage with model field" {
  [[ -n "${CI:-}" ]] && skip "Temporarily skipped in CI due shell-specific output variance"
  local workspace capture_file
  workspace="$(setup_model_capture_workspace)"
  capture_file="$(mktemp)"

  local orch_file="$workspace/model-cursor.orch.json"
  cat <<'ORCH' > "$orch_file"
{
  "name": "bats model cursor",
  "namespace": "model-cursor",
  "stages": [
    {
      "id": "stage1",
      "agent": "test-agent",
      "runtime": "cursor",
      "plan": "stages/stage1.plan.md",
      "model": "gpt-5.4-mini-medium",
      "sessionResume": false,
      "artifacts": [
        { "path": ".ralph-workspace/artifacts/model-cursor/stage1.md", "required": true }
      ]
    }
  ]
}
ORCH
  write_plan_file "$workspace" "stages/stage1.plan.md"
  write_artifact_file "$workspace" ".ralph-workspace/artifacts/model-cursor/stage1.md"

  run env MODEL_CAPTURE_FILE="$capture_file" \
    bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$orch_file" "$workspace" 2>&1
  [ "$status" -eq 0 ] || { echo "FAIL: $output"; rm -f "$capture_file"; rm -rf "$workspace"; return 1; }

  local captured
  captured="$(cat "$capture_file")"
  [[ "$captured" == *"CURSOR_PLAN_MODEL=gpt-5.4-mini-medium"* ]] \
    || { echo "FAIL: expected CURSOR_PLAN_MODEL=gpt-5.4-mini-medium in captured: $captured"; rm -f "$capture_file"; rm -rf "$workspace"; return 1; }

  rm -f "$capture_file"
  rm -rf "$workspace"
}

@test "orchestrator sets CLAUDE_PLAN_MODEL for claude stage and CODEX_PLAN_MODEL for codex stage" {
  [[ -n "${CI:-}" ]] && skip "Temporarily skipped in CI due shell-specific output variance"
  local workspace capture_file
  workspace="$(setup_model_capture_workspace)"
  capture_file="$(mktemp)"

  local orch_file="$workspace/model-multi.orch.json"
  cat <<'ORCH' > "$orch_file"
{
  "name": "bats model multi",
  "namespace": "model-multi",
  "stages": [
    {
      "id": "claude-stage",
      "agent": "claude-agent",
      "runtime": "claude",
      "plan": "stages/claude-stage.plan.md",
      "model": "claude-sonnet-4-6",
      "sessionResume": false,
      "artifacts": [
        { "path": ".ralph-workspace/artifacts/model-multi/claude-stage.md", "required": true }
      ]
    },
    {
      "id": "codex-stage",
      "agent": "codex-agent",
      "runtime": "codex",
      "plan": "stages/codex-stage.plan.md",
      "model": "gpt-5.1-codex-mini",
      "sessionResume": false,
      "artifacts": [
        { "path": ".ralph-workspace/artifacts/model-multi/codex-stage.md", "required": true }
      ]
    }
  ]
}
ORCH
  write_plan_file "$workspace" "stages/claude-stage.plan.md"
  write_artifact_file "$workspace" ".ralph-workspace/artifacts/model-multi/claude-stage.md"
  write_plan_file "$workspace" "stages/codex-stage.plan.md"
  write_artifact_file "$workspace" ".ralph-workspace/artifacts/model-multi/codex-stage.md"

  run env MODEL_CAPTURE_FILE="$capture_file" \
    bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$orch_file" "$workspace" 2>&1
  [ "$status" -eq 0 ] || { echo "FAIL: $output"; rm -f "$capture_file"; rm -rf "$workspace"; return 1; }

  local captured
  captured="$(cat "$capture_file")"
  [[ "$captured" == *"CLAUDE_PLAN_MODEL=claude-sonnet-4-6"* ]] \
    || { echo "FAIL: missing CLAUDE_PLAN_MODEL; captured: $captured"; rm -f "$capture_file"; rm -rf "$workspace"; return 1; }
  [[ "$captured" == *"CODEX_PLAN_MODEL=gpt-5.1-codex-mini"* ]] \
    || { echo "FAIL: missing CODEX_PLAN_MODEL; captured: $captured"; rm -f "$capture_file"; rm -rf "$workspace"; return 1; }

  rm -f "$capture_file"
  rm -rf "$workspace"
}

@test "orchestrator forwards CODEX_PLAN_SANDBOX to run-plan" {
  [[ -n "${CI:-}" ]] && skip "Temporarily skipped in CI due shell-specific output variance"
  local workspace capture_file
  workspace="$(setup_model_capture_workspace)"
  capture_file="$(mktemp)"

  local orch_file="$workspace/model-sandbox.orch.json"
  cat <<'ORCH' > "$orch_file"
{
  "name": "bats sandbox forward",
  "namespace": "model-sandbox",
  "stages": [
    {
      "id": "codex-stage",
      "agent": "codex-agent",
      "runtime": "codex",
      "plan": "stages/codex-stage.plan.md",
      "model": "gpt-5.1-codex-mini",
      "sessionResume": false,
      "artifacts": [
        { "path": ".ralph-workspace/artifacts/model-sandbox/codex-stage.md", "required": true }
      ]
    }
  ]
}
ORCH
  write_plan_file "$workspace" "stages/codex-stage.plan.md"
  write_artifact_file "$workspace" ".ralph-workspace/artifacts/model-sandbox/codex-stage.md"

  run env MODEL_CAPTURE_FILE="$capture_file" CODEX_PLAN_SANDBOX=read-only \
    bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$orch_file" "$workspace" 2>&1
  [ "$status" -eq 0 ] || { echo "FAIL: $output"; rm -f "$capture_file"; rm -rf "$workspace"; return 1; }

  local captured
  captured="$(cat "$capture_file")"
  [[ "$captured" == *"CODEX_PLAN_SANDBOX=read-only"* ]] \
    || { echo "FAIL: expected CODEX_PLAN_SANDBOX=read-only in captured: $captured"; rm -f "$capture_file"; rm -rf "$workspace"; return 1; }

  rm -f "$capture_file"
  rm -rf "$workspace"
}

@test "orchestrator forwards CLAUDE_PLAN_BARE to run-plan" {
  [[ -n "${CI:-}" ]] && skip "Temporarily skipped in CI due shell-specific output variance"
  local workspace capture_file
  workspace="$(setup_model_capture_workspace)"
  capture_file="$(mktemp)"

  local orch_file="$workspace/model-bare.orch.json"
  cat <<'ORCH' > "$orch_file"
{
  "name": "bats bare forward",
  "namespace": "model-bare",
  "stages": [
    {
      "id": "claude-stage",
      "agent": "claude-agent",
      "runtime": "claude",
      "plan": "stages/claude-stage.plan.md",
      "sessionResume": false,
      "artifacts": [
        { "path": ".ralph-workspace/artifacts/model-bare/claude-stage.md", "required": true }
      ]
    }
  ]
}
ORCH
  write_plan_file "$workspace" "stages/claude-stage.plan.md"
  write_artifact_file "$workspace" ".ralph-workspace/artifacts/model-bare/claude-stage.md"

  run env MODEL_CAPTURE_FILE="$capture_file" CLAUDE_PLAN_BARE=1 \
    bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$orch_file" "$workspace" 2>&1
  [ "$status" -eq 0 ] || { echo "FAIL: $output"; rm -f "$capture_file"; rm -rf "$workspace"; return 1; }

  local captured
  captured="$(cat "$capture_file")"
  [[ "$captured" == *"CLAUDE_PLAN_BARE=1"* ]] \
    || { echo "FAIL: expected CLAUDE_PLAN_BARE=1 in captured: $captured"; rm -f "$capture_file"; rm -rf "$workspace"; return 1; }

  rm -f "$capture_file"
  rm -rf "$workspace"
}

@test "orchestrator forwards CLAUDE_PLAN_PERMISSION_MODE to run-plan" {
  [[ -n "${CI:-}" ]] && skip "Temporarily skipped in CI due shell-specific output variance"
  local workspace capture_file
  workspace="$(setup_model_capture_workspace)"
  capture_file="$(mktemp)"

  local orch_file="$workspace/model-permission.orch.json"
  cat <<'ORCH' > "$orch_file"
{
  "name": "bats permission forward",
  "namespace": "model-permission",
  "stages": [
    {
      "id": "claude-stage",
      "agent": "claude-agent",
      "runtime": "claude",
      "plan": "stages/claude-stage.plan.md",
      "sessionResume": false,
      "artifacts": [
        { "path": ".ralph-workspace/artifacts/model-permission/claude-stage.md", "required": true }
      ]
    }
  ]
}
ORCH
  write_plan_file "$workspace" "stages/claude-stage.plan.md"
  write_artifact_file "$workspace" ".ralph-workspace/artifacts/model-permission/claude-stage.md"

  run env MODEL_CAPTURE_FILE="$capture_file" CLAUDE_PLAN_PERMISSION_MODE=auto \
    bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$orch_file" "$workspace" 2>&1
  [ "$status" -eq 0 ] || { echo "FAIL: $output"; rm -f "$capture_file"; rm -rf "$workspace"; return 1; }

  local captured
  captured="$(cat "$capture_file")"
  [[ "$captured" == *"CLAUDE_PLAN_PERMISSION_MODE=auto"* ]] \
    || { echo "FAIL: expected CLAUDE_PLAN_PERMISSION_MODE=auto in captured: $captured"; rm -f "$capture_file"; rm -rf "$workspace"; return 1; }

  rm -f "$capture_file"
  rm -rf "$workspace"
}

@test "orchestrator does not set model env var when stage omits model field" {
  [[ -n "${CI:-}" ]] && skip "Temporarily skipped in CI due shell-specific output variance"
  local workspace capture_file
  workspace="$(setup_model_capture_workspace)"
  capture_file="$(mktemp)"

  local orch_file="$workspace/no-model.orch.json"
  cat <<'ORCH' > "$orch_file"
{
  "name": "bats no model",
  "namespace": "no-model",
  "stages": [
    {
      "id": "no-model-stage",
      "agent": "no-model-agent",
      "runtime": "cursor",
      "plan": "stages/no-model.plan.md",
      "sessionResume": false,
      "artifacts": [
        { "path": ".ralph-workspace/artifacts/no-model/out.md", "required": true }
      ]
    }
  ]
}
ORCH
  write_plan_file "$workspace" "stages/no-model.plan.md"
  write_artifact_file "$workspace" ".ralph-workspace/artifacts/no-model/out.md"

  run env MODEL_CAPTURE_FILE="$capture_file" \
    bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$orch_file" "$workspace" 2>&1
  [ "$status" -eq 0 ] || { echo "FAIL: $output"; rm -f "$capture_file"; rm -rf "$workspace"; return 1; }

  local captured
  captured="$(cat "$capture_file")"
  # CURSOR_PLAN_MODEL should be empty (no override) when stage has no model field
  [[ "$captured" == *"CURSOR_PLAN_MODEL="$'\n'* ]] || [[ "$captured" == *"CURSOR_PLAN_MODEL="$'\r'* ]] \
    || [[ "$captured" =~ CURSOR_PLAN_MODEL=$'\n' ]] || [[ "$captured" == *"CURSOR_PLAN_MODEL="* && "$captured" != *"CURSOR_PLAN_MODEL=g"* ]] \
    || { echo "unexpected CURSOR_PLAN_MODEL set: $captured"; rm -f "$capture_file"; rm -rf "$workspace"; return 1; }

  rm -f "$capture_file"
  rm -rf "$workspace"
}

@test "orchestrator uses stage artifacts and skips agent config merge when stage defines artifacts" {
  [[ -n "${CI:-}" ]] && skip "Temporarily skipped in CI due shell-specific output variance"
  local workspace
  workspace="$(setup_orchestrator_workspace)"

  # Agent config declares a different artifact than the stage
  create_agent_config_workspace "$workspace" "test-agent" \
    ".ralph-workspace/artifacts/skip-merge/agent-default.md" "cursor"

  local orch_file="$workspace/skip-merge.orch.json"
  cat <<'ORCH' > "$orch_file"
{
  "name": "bats skip merge",
  "namespace": "skip-merge",
  "stages": [
    {
      "id": "step1",
      "agent": "test-agent",
      "agentSource": "prebuilt",
      "runtime": "cursor",
      "plan": "stages/step1.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/skip-merge/stage-defined.md",
          "required": true
        }
      ]
    }
  ]
}
ORCH
  write_plan_file "$workspace" "stages/step1.plan.md"
  write_artifact_file "$workspace" ".ralph-workspace/artifacts/skip-merge/stage-defined.md"
  # Do NOT create agent-default.md — if it is added as required, the run will fail

  run bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$orch_file" "$workspace" 2>&1
  [ "$status" -eq 0 ] || { echo "FAIL output: $output"; return 1; }
  rm -rf "$workspace"
}

@test "orchestrator falls back to agent config artifacts when stage defines none" {
  [[ -n "${CI:-}" ]] && skip "Temporarily skipped in CI due shell-specific output variance"
  local workspace
  workspace="$(setup_orchestrator_workspace)"

  create_agent_config_workspace "$workspace" "fallback-agent" \
    ".ralph-workspace/artifacts/fallback-ns/fallback.md" "cursor"

  local orch_file="$workspace/fallback.orch.json"
  cat <<'ORCH' > "$orch_file"
{
  "name": "bats fallback",
  "namespace": "fallback-ns",
  "stages": [
    {
      "id": "fallback-stage",
      "agent": "fallback-agent",
      "agentSource": "prebuilt",
      "runtime": "cursor",
      "plan": "stages/fallback.plan.md"
    }
  ]
}
ORCH
  write_plan_file "$workspace" "stages/fallback.plan.md"
  write_artifact_file "$workspace" ".ralph-workspace/artifacts/fallback-ns/fallback.md"

  run bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$orch_file" "$workspace" 2>&1
  [ "$status" -eq 0 ] || { echo "FAIL output: $output"; return 1; }
  rm -rf "$workspace"
}

@test "orchestrator expands STAGE_ID token in stage artifacts" {
  [[ -n "${CI:-}" ]] && skip "Temporarily skipped in CI due shell-specific output variance"
  local workspace
  workspace="$(setup_orchestrator_workspace)"

  local orch_file="$workspace/stage-id-token.orch.json"
  cat <<'ORCH' > "$orch_file"
{
  "name": "bats stage id",
  "namespace": "stage-id-ns",
  "stages": [
    {
      "id": "my-step",
      "agent": "id-agent",
      "runtime": "cursor",
      "plan": "stages/my-step.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/stage-id-ns/{{STAGE_ID}}.md",
          "required": true
        }
      ]
    }
  ]
}
ORCH
  write_plan_file "$workspace" "stages/my-step.plan.md"
  # Artifact path should expand to my-step.md
  write_artifact_file "$workspace" ".ralph-workspace/artifacts/stage-id-ns/my-step.md"

  run bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$orch_file" "$workspace" 2>&1
  [ "$status" -eq 0 ] || { echo "FAIL output: $output"; return 1; }
  rm -rf "$workspace"
}

@test "orchestrator dry-run shows STAGE_ID-expanded artifact paths" {
  [[ -n "${CI:-}" ]] && skip "Temporarily skipped in CI due shell-specific output variance"
  local workspace
  workspace="$(setup_orchestrator_workspace)"

  local orch_file="$workspace/stage-id-dry.orch.json"
  cat <<'ORCH' > "$orch_file"
{
  "name": "bats stage id dry",
  "namespace": "sid-dry",
  "stages": [
    {
      "id": "cr1",
      "agent": "dry-agent",
      "runtime": "cursor",
      "plan": "stages/cr1.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/sid-dry/{{STAGE_ID}}.md",
          "required": true
        }
      ]
    }
  ]
}
ORCH
  write_plan_file "$workspace" "stages/cr1.plan.md"

  run env ORCHESTRATOR_DRY_RUN=1 bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$orch_file" "$workspace" 2>&1
  [ "$status" -eq 0 ] \
    && [[ "$output" == *"expected artifacts:"*"cr1.md"* ]] \
    || { echo "FAIL output: $output"; return 1; }
  rm -rf "$workspace"
}

@test "orchestrator honors humanAck gates when enabled" {
  [[ -n "${CI:-}" ]] && skip "Temporarily skipped in CI due shell-specific output variance"
  local workspace
  workspace="$(setup_orchestrator_workspace)"
  local orch_file
  orch_file="$(create_human_ack_orchestration "$workspace")"
  run env ORCHESTRATOR_HUMAN_ACK=1 bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$orch_file" "$workspace" 2>&1
  [ "$status" -eq 3 ] \
    && [[ "$output" == *"Human acknowledgment required"* ]] \
    || return 1
  local artifact_ns="${RALPH_ARTIFACT_NS:-bats-human-ack}"
  local ack_file="$workspace/.ralph-workspace/artifacts/$artifact_ns/human-ack.txt"
  mkdir -p "$(dirname "$ack_file")"
  : >"$ack_file"
  run env ORCHESTRATOR_HUMAN_ACK=1 bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$orch_file" "$workspace" 2>&1
  [ "$status" -eq 0 ] || return 1
  rm -rf "$workspace"
}
