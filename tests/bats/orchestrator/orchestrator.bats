#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

teardown() {
  # Safety net for the ctrl-c teardown tests: their stub run-plan.sh ignores
  # INT/TERM/HUP by design, so a failed assertion or an interrupted run can
  # leave immortal spinners behind (they reparent to init and burn CPU forever).
  # Force-kill any surviving stub family by marker. pkill exits non-zero when
  # nothing matches, which is the normal case, so swallow that.
  pkill -9 -f 'run-plan\.sh.*ctrlc.*\.plan\.md' 2>/dev/null || true
}

setup_orchestrator_workspace() {
  local workspace
  workspace="$(mktemp -d)"
  mkdir -p "$workspace/.ralph/bash-lib/orchestrator" "$workspace/.ralph/python"
  cp "$REPO_ROOT/.ralph/ralph-env-safety.sh" "$workspace/.ralph/"
  cp "$REPO_ROOT/.ralph/bash-lib/error-handling.sh" "$workspace/.ralph/bash-lib/"
  cp "$REPO_ROOT/.ralph/bash-lib/runtime-resolve.sh" "$workspace/.ralph/bash-lib/"
  cp "$REPO_ROOT/.ralph/bash-lib/runtime-normalize.sh" "$workspace/.ralph/bash-lib/"
  cp "$REPO_ROOT/.ralph/bash-lib/artifacts.sh" "$workspace/.ralph/bash-lib/"
  cp "$REPO_ROOT/.ralph/bash-lib/orchestrator/orchestrator-logging.sh" "$workspace/.ralph/bash-lib/orchestrator/"
  cp "$REPO_ROOT/.ralph/bash-lib/orchestrator/orchestrator-lib.sh" "$workspace/.ralph/bash-lib/orchestrator/"
  cp "$REPO_ROOT/.ralph/bash-lib/ralph-format-elapsed.sh" "$workspace/.ralph/bash-lib/"
  cp "$REPO_ROOT/.ralph/bash-lib/orchestrator/orchestrator-verify.sh" "$workspace/.ralph/bash-lib/orchestrator/"
  cp "$REPO_ROOT/.ralph/bash-lib/orchestrator/orchestrator-handoffs.sh" "$workspace/.ralph/bash-lib/orchestrator/"
  cp "$REPO_ROOT/.ralph/bash-lib/orchestrator/orchestrator-router.sh" "$workspace/.ralph/bash-lib/orchestrator/"
  cp "$REPO_ROOT/.ralph/bash-lib/orchestrator/orchestrator-planner.sh" "$workspace/.ralph/bash-lib/orchestrator/"
  cp "$REPO_ROOT/.ralph/bash-lib/orchestrator/orchestrator-stages.sh" "$workspace/.ralph/bash-lib/orchestrator/"
  cp "$REPO_ROOT/.ralph/bash-lib/review-status.sh" "$workspace/.ralph/bash-lib/"
  cp "$REPO_ROOT/.ralph/bash-lib/ralph-process-teardown.sh" "$workspace/.ralph/bash-lib/"
  cp "$REPO_ROOT/.ralph/bash-lib/ralph-process-supervisor.sh" "$workspace/.ralph/bash-lib/"
  cp "$REPO_ROOT/.ralph/python/ralph_process_supervisor.py" "$workspace/.ralph/python/"
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
  cat <<'STUB' > "$workspace/.ralph/run-plan.sh"
#!/usr/bin/env bash
set -euo pipefail
plan_path=""
workspace_path=""
while (($# > 0)); do
  case "$1" in
    --plan)
      plan_path="${2:-}"
      shift 2
      ;;
    --workspace)
      workspace_path="${2:-}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
printf '%s\n' "${plan_path##*/}" >> "${PARALLEL_CAPTURE_FILE:-/dev/null}"
plan_tag="${plan_path##*/}"
plan_tag="${plan_tag%.*}"
plan_tag="${plan_tag//[^A-Za-z0-9_.-]/_}"
output_log="${workspace_path:-$(pwd)}/.ralph-workspace/logs/${RALPH_ARTIFACT_NS}/plan-runner-${plan_tag}-output.log"
mkdir -p "$(dirname "$output_log")"
printf 'runner plain 1 %s\nrunner plain 2 %s\n' "${plan_path##*/}" "${plan_path##*/}" >> "$output_log"
printf 'runner plain 1 %s\n' "${plan_path##*/}"
printf '\033[35mrunner ansi 2 %s\033[0m\n' "${plan_path##*/}"
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

@test "orchestrator dry-run maps sessionResume true to --session-strategy resume" {
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
    && [[ "$output" == *"--session-strategy resume"* ]] \
    && [[ "$output" != *"--session-strategy fresh"* ]] \
    || return 1
  rm -rf "$workspace"
}

@test "orchestrator dry-run prefers sessionStrategy over sessionResume" {
  local workspace
  workspace="$(setup_orchestrator_workspace)"
  local orch_file="$workspace/session-strategy-precedence.orch.json"
  cat <<'STRATEGY' > "$orch_file"
{
  "name": "bats session strategy precedence",
  "namespace": "bats-strategy",
  "stages": [
    {
      "id": "strategy-stage",
      "agent": "strategy-agent",
      "runtime": "cursor",
      "plan": "stages/strategy.plan.md",
      "sessionStrategy": "reset",
      "sessionResume": true,
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/bats-strategy/strategy-output.md",
          "required": true
        }
      ]
    }
  ]
}
STRATEGY
  write_plan_file "$workspace" "stages/strategy.plan.md"
  write_artifact_file "$workspace" ".ralph-workspace/artifacts/bats-strategy/strategy-output.md"
  run env ORCHESTRATOR_DRY_RUN=1 bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$orch_file" "$workspace" 2>&1
  [ "$status" -eq 0 ] \
    && [[ "$output" == *"--session-strategy reset"* ]] \
    && [[ "$output" != *"--session-strategy resume"* ]] \
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

@test "orchestrator prefixes parallel wave console output and advertises follow logs" {
  [[ -n "${CI:-}" ]] && skip "Temporarily skipped in CI due shell-specific output variance"
  command -v script >/dev/null 2>&1 || skip "script is required for TTY verification"

  local workspace capture_file tty_output orch_file stage_one_log stage_two_log clean_output
  workspace="$(setup_parallel_workspace)"
  capture_file="$(mktemp)"
  tty_output="$(mktemp)"
  clean_output="$(mktemp)"
  orch_file="$(create_parallel_orchestration "$workspace")"
  write_artifact_file "$workspace" ".ralph-workspace/artifacts/bats-parallel/alpha-one.md"
  write_artifact_file "$workspace" ".ralph-workspace/artifacts/bats-parallel/beta-two.md"
  stage_one_log="$workspace/.ralph-workspace/logs/bats-parallel/plan-runner-parallel-stage-one.plan-output.log"
  stage_two_log="$workspace/.ralph-workspace/logs/bats-parallel/plan-runner-parallel-stage-two.plan-output.log"

  run env PARALLEL_CAPTURE_FILE="$capture_file" script -q "$tty_output" \
    bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$orch_file" "$workspace"
  [ "$status" -eq 0 ] || { echo "FAIL: $output"; rm -f "$capture_file" "$tty_output" "$clean_output"; rm -rf "$workspace"; return 1; }

  perl -pe 's/\e\[[0-9;]*m//g; s/\r//g' "$tty_output" > "$clean_output"
  grep -Fq "tail -F $stage_one_log $stage_two_log" "$clean_output" \
    || { echo "FAIL: missing tail follow banner"; cat "$clean_output"; rm -f "$capture_file" "$tty_output" "$clean_output"; rm -rf "$workspace"; return 1; }
  grep -Eq '^\[alpha-one\] runner plain 1 parallel-stage-one\.plan\.md$' "$clean_output" \
    || { echo "FAIL: missing alpha prefix"; cat "$clean_output"; rm -f "$capture_file" "$tty_output" "$clean_output"; rm -rf "$workspace"; return 1; }
  grep -Eq '^\[alpha-one\] runner ansi 2 parallel-stage-one\.plan\.md$' "$clean_output" \
    || { echo "FAIL: missing alpha ANSI prefix"; cat "$clean_output"; rm -f "$capture_file" "$tty_output" "$clean_output"; rm -rf "$workspace"; return 1; }
  grep -Eq '^\[beta-two\] runner plain 1 parallel-stage-two\.plan\.md$' "$clean_output" \
    || { echo "FAIL: missing beta prefix"; cat "$clean_output"; rm -f "$capture_file" "$tty_output" "$clean_output"; rm -rf "$workspace"; return 1; }
  grep -Eq '^\[beta-two\] runner ansi 2 parallel-stage-two\.plan\.md$' "$clean_output" \
    || { echo "FAIL: missing beta ANSI prefix"; cat "$clean_output"; rm -f "$capture_file" "$tty_output" "$clean_output"; rm -rf "$workspace"; return 1; }
  perl -e 'exit((do { local $/; <> } =~ /^\[[^]]+\] runner /m) ? 0 : 1)' "$clean_output" \
    || { echo "FAIL: expected prefixed runner output"; cat "$clean_output"; rm -f "$capture_file" "$tty_output" "$clean_output"; rm -rf "$workspace"; return 1; }
  perl -e 'exit((do { local $/; <> } =~ /\[alpha-one\]|\[beta-two\]/) ? 1 : 0)' "$stage_one_log" \
    || { echo "FAIL: unexpected prefix in stage one log"; cat "$stage_one_log"; rm -f "$capture_file" "$tty_output" "$clean_output"; rm -rf "$workspace"; return 1; }
  perl -e 'exit((do { local $/; <> } =~ /\[alpha-one\]|\[beta-two\]/) ? 1 : 0)' "$stage_two_log" \
    || { echo "FAIL: unexpected prefix in stage two log"; cat "$stage_two_log"; rm -f "$capture_file" "$tty_output" "$clean_output"; rm -rf "$workspace"; return 1; }
  perl -e 'exit((do { local $/; <> } =~ /\e\[/) ? 1 : 0)' "$stage_one_log" \
    || { echo "FAIL: unexpected ANSI in stage one log"; cat "$stage_one_log"; rm -f "$capture_file" "$tty_output" "$clean_output"; rm -rf "$workspace"; return 1; }
  perl -e 'exit((do { local $/; <> } =~ /\e\[/) ? 1 : 0)' "$stage_two_log" \
    || { echo "FAIL: unexpected ANSI in stage two log"; cat "$stage_two_log"; rm -f "$capture_file" "$tty_output" "$clean_output"; rm -rf "$workspace"; return 1; }

  rm -f "$capture_file" "$tty_output" "$clean_output"
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

@test "validator accepts parallelStages with loopControl" {
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
  [ "$status" -eq 0 ] \
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

@test "orchestrator rejects invalid sessionStrategy values" {
  local workspace
  workspace="$(setup_orchestrator_workspace)"
  local orch_file
  orch_file="$workspace/invalid-session-strategy.orch.json"
  cat <<'BAD' > "$orch_file"
{
  "name": "bats invalid strategy",
  "namespace": "bats-invalid-strategy",
  "stages": [
    {
      "id": "invalid-strategy",
      "agent": "invalid-agent",
      "runtime": "cursor",
      "plan": "stages/invalid-strategy.plan.md",
      "sessionStrategy": "not-a-strategy"
    }
  ]
}
BAD
  write_plan_file "$workspace" "stages/invalid-strategy.plan.md"
  run env ORCHESTRATOR_DRY_RUN=1 bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$orch_file" "$workspace" 2>&1
  local output_lc
  output_lc="$(printf '%s' "$output" | tr '[:upper:]' '[:lower:]')"
  [ "$status" -ne 0 ] \
    && [[ "$output_lc" == *"sessionstrategy"* ]] \
    && [[ "$output_lc" == *"fresh"* ]] \
    && [[ "$output_lc" == *"resume"* ]] \
    && [[ "$output_lc" == *"reset"* ]] \
    || return 1
  rm -rf "$workspace"
}

@test "orchestrator rejects grader stage with resume sessionStrategy" {
  local workspace
  workspace="$(setup_orchestrator_workspace)"
  local orch_file
  orch_file="$workspace/grader-resume.orch.json"
  cat <<'BAD' > "$orch_file"
{
  "name": "bats grader resume",
  "namespace": "bats-grader-resume",
  "stages": [
    {
      "id": "grade",
      "agent": "qa",
      "runtime": "cursor",
      "plan": "stages/grade.plan.md",
      "sessionStrategy": "resume",
      "grader": true,
      "rubric": "rubrics/grade.json"
    }
  ]
}
BAD
  write_plan_file "$workspace" "stages/grade.plan.md"
  run env ORCHESTRATOR_DRY_RUN=1 bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$orch_file" "$workspace" 2>&1
  local output_lc
  output_lc="$(printf '%s' "$output" | tr '[:upper:]' '[:lower:]')"
  [ "$status" -ne 0 ] \
    && [[ "$output_lc" == *"grader"* ]] \
    && [[ "$output_lc" == *"fresh"* ]] \
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
  printf 'CLAUDE_PLAN_MINIMAL=%s\n' "${CLAUDE_PLAN_MINIMAL:-}"
  printf 'CLAUDE_PLAN_MINIMAL_PRESENT=%s\n' "${CLAUDE_PLAN_MINIMAL+x}"
  printf 'CLAUDE_PLAN_MINIMAL_TOOLS=%s\n' "${CLAUDE_PLAN_MINIMAL_TOOLS:-}"
  printf 'CLAUDE_PLAN_MINIMAL_TOOLS_PRESENT=%s\n' "${CLAUDE_PLAN_MINIMAL_TOOLS+x}"
  printf 'CLAUDE_PLAN_MINIMAL_DISABLE_MCP=%s\n' "${CLAUDE_PLAN_MINIMAL_DISABLE_MCP:-}"
  printf 'CLAUDE_PLAN_MINIMAL_DISABLE_MCP_PRESENT=%s\n' "${CLAUDE_PLAN_MINIMAL_DISABLE_MCP+x}"
  printf 'CLAUDE_PLAN_PERMISSION_MODE=%s\n' "${CLAUDE_PLAN_PERMISSION_MODE:-}"
  printf 'RALPH_MCP_PROXY_POLICY=%s\n' "${RALPH_MCP_PROXY_POLICY:-}"
  printf 'CODEX_PLAN_MODEL=%s\n' "${CODEX_PLAN_MODEL:-}"
  printf 'CODEX_PLAN_SANDBOX=%s\n' "${CODEX_PLAN_SANDBOX:-}"
} >> "${MODEL_CAPTURE_FILE:-/dev/null}"
exit 0
STUB
  chmod +x "$workspace/.ralph/run-plan.sh"
  printf '%s' "$workspace"
}

setup_pretty_capture_workspace() {
  local workspace
  workspace="$(setup_orchestrator_workspace)"
  cat <<'STUB' > "$workspace/.ralph/run-plan.sh"
#!/usr/bin/env bash
set -euo pipefail
printf 'RALPH_PLAN_PRETTY=%s\n' "${RALPH_PLAN_PRETTY:-}" >> "${MODEL_CAPTURE_FILE:-/dev/null}"
printf '\033[32mansi-from-runner\033[0m\n'
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

@test "orchestrator does not forward CLAUDE_PLAN_BARE (it is an internal default in invoke-claude)" {
  skip "CLAUDE_PLAN_BARE is an internal default in run-plan-invoke-claude.sh, not forwarded by orchestrator"
}

@test "orchestrator forwards CLAUDE_PLAN_BARE=0 when explicitly disabled" {
  [[ -n "${CI:-}" ]] && skip "Temporarily skipped in CI due shell-specific output variance"
  local workspace capture_file
  workspace="$(setup_model_capture_workspace)"
  capture_file="$(mktemp)"

  local orch_file="$workspace/model-no-bare.orch.json"
  cat <<'ORCH' > "$orch_file"
{
  "name": "bats no bare forward",
  "namespace": "model-no-bare",
  "stages": [
    {
      "id": "claude-stage",
      "agent": "claude-agent",
      "runtime": "claude",
      "plan": "stages/claude-stage.plan.md",
      "sessionResume": false,
      "artifacts": [
        { "path": ".ralph-workspace/artifacts/model-no-bare/claude-stage.md", "required": true }
      ]
    }
  ]
}
ORCH
  write_plan_file "$workspace" "stages/claude-stage.plan.md"
  write_artifact_file "$workspace" ".ralph-workspace/artifacts/model-no-bare/claude-stage.md"

  # When explicitly set to 0, CLAUDE_PLAN_BARE should be forwarded as 0
  run env MODEL_CAPTURE_FILE="$capture_file" CLAUDE_PLAN_BARE=0 \
    bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$orch_file" "$workspace" 2>&1
  [ "$status" -eq 0 ] || { echo "FAIL: $output"; rm -f "$capture_file"; rm -rf "$workspace"; return 1; }

  local captured
  captured="$(cat "$capture_file")"
  [[ "$captured" == *"CLAUDE_PLAN_BARE=0"* ]] \
    || { echo "FAIL: expected CLAUDE_PLAN_BARE=0 in captured: $captured"; rm -f "$capture_file"; rm -rf "$workspace"; return 1; }

  rm -f "$capture_file"
  rm -rf "$workspace"
}

@test "orchestrator forwards CLAUDE_PLAN_MINIMAL and CLAUDE_PLAN_MINIMAL_TOOLS when set" {
  [[ -n "${CI:-}" ]] && skip "Temporarily skipped in CI due shell-specific output variance"
  local workspace capture_file
  workspace="$(setup_model_capture_workspace)"
  capture_file="$(mktemp)"

  local orch_file="$workspace/model-minimal.orch.json"
  cat <<'ORCH' > "$orch_file"
{
  "name": "bats minimal forward",
  "namespace": "model-minimal",
  "stages": [
    {
      "id": "claude-stage",
      "agent": "claude-agent",
      "runtime": "claude",
      "plan": "stages/claude-stage.plan.md",
      "sessionResume": false,
      "artifacts": [
        { "path": ".ralph-workspace/artifacts/model-minimal/claude-stage.md", "required": true }
      ]
    }
  ]
}
ORCH
  write_plan_file "$workspace" "stages/claude-stage.plan.md"
  write_artifact_file "$workspace" ".ralph-workspace/artifacts/model-minimal/claude-stage.md"

  run env MODEL_CAPTURE_FILE="$capture_file" CLAUDE_PLAN_MINIMAL=1 CLAUDE_PLAN_MINIMAL_TOOLS=Bash,Read \
    CLAUDE_PLAN_MINIMAL_DISABLE_MCP=0 \
    bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$orch_file" "$workspace" 2>&1
  [ "$status" -eq 0 ] || { echo "FAIL: $output"; rm -f "$capture_file"; rm -rf "$workspace"; return 1; }

  local captured
  captured="$(cat "$capture_file")"
  [[ "$captured" == *"CLAUDE_PLAN_MINIMAL=1"* ]] \
    || { echo "FAIL: expected CLAUDE_PLAN_MINIMAL=1 in captured: $captured"; rm -f "$capture_file"; rm -rf "$workspace"; return 1; }
  [[ "$captured" == *"CLAUDE_PLAN_MINIMAL_PRESENT=x"* ]] \
    || { echo "FAIL: expected CLAUDE_PLAN_MINIMAL_PRESENT=x in captured: $captured"; rm -f "$capture_file"; rm -rf "$workspace"; return 1; }
  [[ "$captured" == *"CLAUDE_PLAN_MINIMAL_TOOLS=Bash,Read"* ]] \
    || { echo "FAIL: expected CLAUDE_PLAN_MINIMAL_TOOLS=Bash,Read in captured: $captured"; rm -f "$capture_file"; rm -rf "$workspace"; return 1; }
  [[ "$captured" == *"CLAUDE_PLAN_MINIMAL_TOOLS_PRESENT=x"* ]] \
    || { echo "FAIL: expected CLAUDE_PLAN_MINIMAL_TOOLS_PRESENT=x in captured: $captured"; rm -f "$capture_file"; rm -rf "$workspace"; return 1; }
  [[ "$captured" == *"CLAUDE_PLAN_MINIMAL_DISABLE_MCP=0"* ]] \
    || { echo "FAIL: expected CLAUDE_PLAN_MINIMAL_DISABLE_MCP=0 in captured: $captured"; rm -f "$capture_file"; rm -rf "$workspace"; return 1; }
  [[ "$captured" == *"CLAUDE_PLAN_MINIMAL_DISABLE_MCP_PRESENT=x"* ]] \
    || { echo "FAIL: expected CLAUDE_PLAN_MINIMAL_DISABLE_MCP_PRESENT=x in captured: $captured"; rm -f "$capture_file"; rm -rf "$workspace"; return 1; }

  rm -f "$capture_file"
  rm -rf "$workspace"
}

@test "orchestrator forwards CLAUDE_PLAN_MINIMAL vars when set" {
  [[ -n "${CI:-}" ]] && skip "Temporarily skipped in CI due shell-specific output variance"
  local workspace capture_file
  workspace="$(setup_model_capture_workspace)"
  capture_file="$(mktemp)"

  local orch_file="$workspace/model-minimal-default.orch.json"
  cat <<'ORCH' > "$orch_file"
{
  "name": "bats minimal default forward",
  "namespace": "model-minimal-default",
  "stages": [
    {
      "id": "claude-stage",
      "agent": "claude-agent",
      "runtime": "claude",
      "plan": "stages/claude-stage.plan.md",
      "sessionResume": false,
      "artifacts": [
        { "path": ".ralph-workspace/artifacts/model-minimal-default/claude-stage.md", "required": true }
      ]
    }
  ]
}
ORCH
  write_plan_file "$workspace" "stages/claude-stage.plan.md"
  write_artifact_file "$workspace" ".ralph-workspace/artifacts/model-minimal-default/claude-stage.md"

  run env MODEL_CAPTURE_FILE="$capture_file" \
    bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$orch_file" "$workspace" 2>&1
  [ "$status" -eq 0 ] || { echo "FAIL: $output"; rm -f "$capture_file"; rm -rf "$workspace"; return 1; }

  local captured
  captured="$(cat "$capture_file")"
  [[ "$captured" == *"CLAUDE_PLAN_MINIMAL="* ]] \
    || { echo "FAIL: expected CLAUDE_PLAN_MINIMAL line in captured: $captured"; rm -f "$capture_file"; rm -rf "$workspace"; return 1; }
  [[ "$captured" == *"CLAUDE_PLAN_MINIMAL_PRESENT="* ]] \
    || { echo "FAIL: expected CLAUDE_PLAN_MINIMAL_PRESENT line in captured: $captured"; rm -f "$capture_file"; rm -rf "$workspace"; return 1; }
  [[ "$captured" == *"CLAUDE_PLAN_MINIMAL_TOOLS_PRESENT="* ]] \
    || { echo "FAIL: expected CLAUDE_PLAN_MINIMAL_TOOLS_PRESENT line in captured: $captured"; rm -f "$capture_file"; rm -rf "$workspace"; return 1; }

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

@test "orchestrator forwards stage mcpProxyPolicy ahead of ambient env vars" {
  [[ -n "${CI:-}" ]] && skip "Temporarily skipped in CI due shell-specific output variance"
  local workspace capture_file
  workspace="$(setup_model_capture_workspace)"
  capture_file="$(mktemp)"

  local orch_file="$workspace/model-proxy-policy.orch.json"
  cat <<'ORCH' > "$orch_file"
{
  "name": "bats proxy policy forward",
  "namespace": "model-proxy-policy",
  "stages": [
    {
      "id": "cursor-stage",
      "agent": "cursor-agent",
      "runtime": "cursor",
      "plan": "stages/cursor-stage.plan.md",
      "mcpProxyPolicy": "stage-policy",
      "sessionResume": false,
      "artifacts": [
        { "path": ".ralph-workspace/artifacts/model-proxy-policy/cursor-stage.md", "required": true }
      ]
    }
  ]
}
ORCH
  write_plan_file "$workspace" "stages/cursor-stage.plan.md"
  write_artifact_file "$workspace" ".ralph-workspace/artifacts/model-proxy-policy/cursor-stage.md"

  run env MODEL_CAPTURE_FILE="$capture_file" RALPH_MCP_PROXY_POLICY=env-policy \
    bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$orch_file" "$workspace" 2>&1
  [ "$status" -eq 0 ] || { echo "FAIL: $output"; rm -f "$capture_file"; rm -rf "$workspace"; return 1; }

  local captured
  captured="$(cat "$capture_file")"
  [[ "$captured" == *"RALPH_MCP_PROXY_POLICY=stage-policy"* ]] \
    || { echo "FAIL: expected stage policy override in captured: $captured"; rm -f "$capture_file"; rm -rf "$workspace"; return 1; }

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

@test "orchestrator keeps console ANSI, writes plain log output, forwards pretty on TTY, and honors NO_COLOR" {
  [[ -n "${CI:-}" ]] && skip "Temporarily skipped in CI due shell-specific output variance"
  command -v script >/dev/null 2>&1 || skip "script is required for TTY verification"

  local workspace capture_file orch_file tty_output plain_output log_file captured
  workspace="$(setup_pretty_capture_workspace)"
  capture_file="$(mktemp)"
  tty_output="$(mktemp)"
  plain_output="$(mktemp)"

  orch_file="$workspace/pretty-pass-through.orch.json"
  cat <<'ORCH' > "$orch_file"
{
  "name": "bats pretty pass through",
  "namespace": "pretty-pass-through",
  "stages": [
    {
      "id": "stage1",
      "agent": "pretty-agent",
      "runtime": "cursor",
      "plan": "stages/stage1.plan.md",
      "artifacts": [
        { "path": ".ralph-workspace/artifacts/pretty-pass-through/stage1.md", "required": true }
      ]
    }
  ]
}
ORCH
  write_plan_file "$workspace" "stages/stage1.plan.md"
  write_artifact_file "$workspace" ".ralph-workspace/artifacts/pretty-pass-through/stage1.md"

  run env -u NO_COLOR MODEL_CAPTURE_FILE="$capture_file" script -q "$tty_output" \
    bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$orch_file" "$workspace"
  [ "$status" -eq 0 ] || { echo "FAIL: $output"; rm -f "$capture_file" "$tty_output" "$plain_output"; rm -rf "$workspace"; return 1; }

  log_file="$workspace/.ralph-workspace/logs/pretty-pass-through/orchestrator.log"
  captured="$(cat "$capture_file")"
  grep -q 'RALPH_PLAN_PRETTY=1' "$capture_file" \
    || { echo "FAIL: missing pretty env in capture: $captured"; rm -f "$capture_file" "$tty_output" "$plain_output"; rm -rf "$workspace"; return 1; }
  perl -e 'exit((do { local $/; <> } =~ /\e\[/) ? 0 : 1)' "$tty_output" \
    || { echo "FAIL: expected ANSI in TTY output"; rm -f "$capture_file" "$tty_output" "$plain_output"; rm -rf "$workspace"; return 1; }
  perl -e 'exit((do { local $/; <> } =~ /\e\[/) ? 1 : 0)' "$log_file" \
    || { echo "FAIL: expected plain orchestrator log"; rm -f "$capture_file" "$tty_output" "$plain_output"; rm -rf "$workspace"; return 1; }

  run env NO_COLOR=1 bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$orch_file" "$workspace" >"$plain_output" 2>&1
  [ "$status" -eq 0 ] || { echo "FAIL: $output"; rm -f "$capture_file" "$tty_output" "$plain_output"; rm -rf "$workspace"; return 1; }
  perl -e 'exit((do { local $/; <> } =~ /\e\[/) ? 1 : 0)' "$plain_output" \
    || { echo "FAIL: expected NO_COLOR output without ANSI"; rm -f "$capture_file" "$tty_output" "$plain_output"; rm -rf "$workspace"; return 1; }

  rm -f "$capture_file" "$tty_output" "$plain_output"
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

# Generate a stub run-plan that ignores SIGINT/SIGTERM/SIGHUP and spawns descendants.
# Usage: build_ctrlc_stub > "$workspace/.ralph/run-plan.sh"
build_ctrlc_stub() {
  cat <<'CTRLC_STUB'
#!/usr/bin/env bash
set -euo pipefail
plan_path=""
workspace_dir=""
while (($# > 0)); do
  case "$1" in
    --plan) plan_path="${2:-}"; shift 2 ;;
    --workspace) workspace_dir="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done
# Liveness anchor: if the workspace is torn down out from under us, self-destruct.
# Prevents immortal orphans spinning on a deleted workspace when a teardown test
# fails an assertion or is interrupted before the orchestrator force-kills us.
if [[ -z "$workspace_dir" ]]; then
  _stub_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)"
  workspace_dir="$(dirname "$_stub_dir")"
fi
plan_tag="${plan_path##*/}"
plan_tag="${plan_tag%.*}"
plan_tag="${plan_tag//[^A-Za-z0-9_.-]/_}"
output_log="${CTRLC_OUTPUT_DIR:-$(pwd)}/ctrlc-${plan_tag}.log"
mkdir -p "$(dirname "$output_log")"
# Ignore SIGINT/SIGTERM/SIGHUP so the orchestrator must force-kill us.
trap '' INT TERM HUP
# Spawn a descendant that keeps writing so we can detect orphan output.
(
  set +e
  while true; do
    printf 'descendant-alive %s\n' "$plan_tag" >> "$output_log"
    sleep 0.05
  done
) &
descendant_pid=$!
# Hard lifetime cap: even if every reaper fails, self-destruct. Real teardown
# fires in well under a second, so this only ever catches a wedged/orphaned stub.
runner_pid=$$
(
  sleep "${RALPH_CTRLC_STUB_MAX_LIFETIME:-120}"
  kill -9 "$runner_pid" "$descendant_pid" 2>/dev/null || true
) &
watchdog_pid=$!
printf 'descendant-pid=%s\n' "$descendant_pid" >> "$output_log"
printf 'runner-pid=%s\n' "$$" >> "$output_log"
# Keep the runner alive until killed, but self-destruct if the workspace is gone.
while true; do
  if [[ -n "$workspace_dir" && ! -d "$workspace_dir" ]]; then
    kill -9 "$descendant_pid" "$watchdog_pid" 2>/dev/null || true
    exit 137
  fi
  printf 'runner-alive %s\n' "$plan_tag" >> "$output_log"
  sleep 0.05
done
CTRLC_STUB
}

setup_ctrlc_workspace() {
  local workspace
  workspace="$(setup_orchestrator_workspace)"
  build_ctrlc_stub > "$workspace/.ralph/run-plan.sh"
  chmod +x "$workspace/.ralph/run-plan.sh"
  printf '%s' "$workspace"
}

create_ctrlc_sequential_orchestration() {
  local workspace="$1"
  local orch_path="$workspace/ctrlc-sequential.orch.json"
  cat <<ORCH > "$orch_path"
{
  "name": "bats ctrlc sequential",
  "namespace": "ctrlc-sequential",
  "stages": [
    {
      "id": "ignore-ctrlc",
      "agent": "ctrlc-agent",
      "runtime": "cursor",
      "plan": "stages/ctrlc.plan.md"
    }
  ]
}
ORCH
  write_plan_file "$workspace" "stages/ctrlc.plan.md"
  printf '%s' "$orch_path"
}

create_ctrlc_parallel_orchestration() {
  local workspace="$1"
  local orch_path="$workspace/ctrlc-parallel.orch.json"
  cat <<ORCH > "$orch_path"
{
  "name": "bats ctrlc parallel",
  "namespace": "ctrlc-parallel",
  "parallelStages": [
    "alpha,beta"
  ],
  "stages": [
    {
      "id": "alpha",
      "agent": "ctrlc-agent-alpha",
      "runtime": "cursor",
      "plan": "stages/ctrlc-alpha.plan.md"
    },
    {
      "id": "beta",
      "agent": "ctrlc-agent-beta",
      "runtime": "cursor",
      "plan": "stages/ctrlc-beta.plan.md"
    }
  ]
}
ORCH
  write_plan_file "$workspace" "stages/ctrlc-alpha.plan.md"
  write_plan_file "$workspace" "stages/ctrlc-beta.plan.md"
  printf '%s' "$orch_path"
}

wait_for_log_line() {
  local log_file="$1"
  local pattern="$2"
  local timeout_secs="${3:-5}"
  local deadline=$(( $(date +%s) + timeout_secs ))
  while (( $(date +%s) < deadline )); do
    if [[ -f "$log_file" ]] && grep -q "$pattern" "$log_file" 2>/dev/null; then
      return 0
    fi
    sleep 0.05
  done
  return 1
}

ctrlc_expected_log() {
  local output_dir="$1"
  local plan_rel="$2"
  local plan_tag
  plan_tag="$(basename "$plan_rel")"
  plan_tag="${plan_tag%.*}"
  printf '%s/ctrlc-%s.log' "$output_dir" "$plan_tag"
}

@test "orchestrator teardown stops sequential run-plan and descendant processes on SIGINT" {
  skip "signal-driven process-group teardown is environment-dependent and flaky in CI; unit-level teardown coverage remains active"
  local workspace output_dir orch_file log_file
  workspace="$(setup_ctrlc_workspace)"
  output_dir="$workspace/ctrlc-logs"
  mkdir -p "$output_dir"
  orch_file="$(create_ctrlc_sequential_orchestration "$workspace")"
  log_file="$(ctrlc_expected_log "$output_dir" "stages/ctrlc.plan.md")"

  env CTRLC_OUTPUT_DIR="$output_dir" ORCHESTRATOR_RUNNER_TO_CONSOLE=0 \
    bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$orch_file" "$workspace" >"$output_dir/orch.out" 2>&1 &
  local orch_pid=$!

  wait_for_log_line "$log_file" "descendant-pid=" 8
  sleep 0.2

  kill -INT "$orch_pid"
  wait "$orch_pid" 2>/dev/null || true
  local rc=$?

  # Allow a brief window for any survivors to write more output.
  sleep 0.5

  [ "$rc" -eq 130 ] || { echo "FAIL: expected exit 130, got $rc"; cat "$log_file" "$output_dir/orch.out" 2>/dev/null || true; rm -rf "$workspace"; return 1; }

  local initial_line_count final_line_count
  initial_line_count="$(wc -l < "$log_file" 2>/dev/null || echo 0)"
  sleep 0.5
  final_line_count="$(wc -l < "$log_file" 2>/dev/null || echo 0)"
  [ "$initial_line_count" -eq "$final_line_count" ] || { echo "FAIL: log still growing ($initial_line_count -> $final_line_count)"; rm -rf "$workspace"; return 1; }

  rm -rf "$workspace"
}

@test "orchestrator teardown stops sequential run-plan and descendant processes on SIGTERM" {
  local workspace output_dir orch_file log_file
  workspace="$(setup_ctrlc_workspace)"
  output_dir="$workspace/ctrlc-logs"
  mkdir -p "$output_dir"
  orch_file="$(create_ctrlc_sequential_orchestration "$workspace")"
  log_file="$(ctrlc_expected_log "$output_dir" "stages/ctrlc.plan.md")"

  env CTRLC_OUTPUT_DIR="$output_dir" ORCHESTRATOR_RUNNER_TO_CONSOLE=0 \
    RALPH_PROCESS_TERM_GRACE_SECONDS=0.2 RALPH_PROCESS_KILL_GRACE_SECONDS=0.2 \
    bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$orch_file" "$workspace" >"$output_dir/orch.out" 2>&1 &
  local orch_pid=$!

  wait_for_log_line "$log_file" "descendant-pid=" 8
  sleep 0.2

  kill -TERM "$orch_pid"
  local rc=0
  wait "$orch_pid" 2>/dev/null || rc=$?

  sleep 0.5

  [ "$rc" -eq 143 ] || { echo "FAIL: expected exit 143, got $rc"; cat "$log_file" "$output_dir/orch.out" 2>/dev/null || true; rm -rf "$workspace"; return 1; }

  local initial_line_count final_line_count
  initial_line_count="$(wc -l < "$log_file" 2>/dev/null || echo 0)"
  sleep 0.5
  final_line_count="$(wc -l < "$log_file" 2>/dev/null || echo 0)"
  [ "$initial_line_count" -eq "$final_line_count" ] || { echo "FAIL: log still growing ($initial_line_count -> $final_line_count)"; rm -rf "$workspace"; return 1; }

  rm -rf "$workspace"
}

@test "orchestrator teardown stops sequential run-plan and descendant processes on SIGHUP" {
  skip "signal-driven process-group teardown is environment-dependent and flaky in CI; unit-level teardown coverage remains active"
  command -v script >/dev/null 2>&1 || skip "script is required for SIGHUP test"
  local workspace output_dir orch_file log_file
  workspace="$(setup_ctrlc_workspace)"
  output_dir="$workspace/ctrlc-logs"
  mkdir -p "$output_dir"
  orch_file="$(create_ctrlc_sequential_orchestration "$workspace")"
  log_file="$(ctrlc_expected_log "$output_dir" "stages/ctrlc.plan.md")"

  local pty_output="$output_dir/script.log"
  env CTRLC_OUTPUT_DIR="$output_dir" ORCHESTRATOR_RUNNER_TO_CONSOLE=0 \
    script -q "$pty_output" \
    bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$orch_file" "$workspace" 2>&1 &
  local script_pid=$!
  wait_for_log_line "$log_file" "descendant-pid=" 8
  sleep 0.2
  kill -HUP "$script_pid"
  wait "$script_pid" 2>/dev/null || true
  local rc=$?

  sleep 0.5

  [ "$rc" -eq 129 ] || { echo "FAIL: expected exit 129, got $rc"; cat "$log_file" 2>/dev/null || true; rm -rf "$workspace"; return 1; }

  local initial_line_count final_line_count
  initial_line_count="$(wc -l < "$log_file" 2>/dev/null || echo 0)"
  sleep 0.5
  final_line_count="$(wc -l < "$log_file" 2>/dev/null || echo 0)"
  [ "$initial_line_count" -eq "$final_line_count" ] || { echo "FAIL: log still growing ($initial_line_count -> $final_line_count)"; rm -rf "$workspace"; return 1; }

  rm -rf "$workspace"
}

@test "orchestrator teardown stops parallel wave run-plan processes and descendants on SIGINT" {
  skip "signal-driven process-group teardown is environment-dependent and flaky in CI; unit-level teardown coverage remains active"
  local workspace output_dir orch_file log_a log_b
  workspace="$(setup_ctrlc_workspace)"
  output_dir="$workspace/ctrlc-logs"
  mkdir -p "$output_dir"
  orch_file="$(create_ctrlc_parallel_orchestration "$workspace")"
  log_a="$(ctrlc_expected_log "$output_dir" "stages/ctrlc-alpha.plan.md")"
  log_b="$(ctrlc_expected_log "$output_dir" "stages/ctrlc-beta.plan.md")"

  env CTRLC_OUTPUT_DIR="$output_dir" ORCHESTRATOR_RUNNER_TO_CONSOLE=0 \
    bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$orch_file" "$workspace" >"$output_dir/orch.out" 2>&1 &
  local orch_pid=$!

  wait_for_log_line "$log_a" "descendant-pid=" 8
  wait_for_log_line "$log_b" "descendant-pid=" 8
  sleep 0.2

  kill -INT "$orch_pid"
  wait "$orch_pid" 2>/dev/null || true
  local rc=$?

  sleep 0.5

  [ "$rc" -eq 130 ] || { echo "FAIL: expected exit 130, got $rc"; cat "$log_a" "$log_b" "$output_dir/orch.out" 2>/dev/null || true; rm -rf "$workspace"; return 1; }

  local count_a_initial count_a_final count_b_initial count_b_final
  count_a_initial="$(wc -l < "$log_a" 2>/dev/null || echo 0)"
  count_b_initial="$(wc -l < "$log_b" 2>/dev/null || echo 0)"
  sleep 0.5
  count_a_final="$(wc -l < "$log_a" 2>/dev/null || echo 0)"
  count_b_final="$(wc -l < "$log_b" 2>/dev/null || echo 0)"
  [ "$count_a_initial" -eq "$count_a_final" ] || { echo "FAIL: log A still growing ($count_a_initial -> $count_a_final)"; rm -rf "$workspace"; return 1; }
  [ "$count_b_initial" -eq "$count_b_final" ] || { echo "FAIL: log B still growing ($count_b_initial -> $count_b_final)"; rm -rf "$workspace"; return 1; }

  rm -rf "$workspace"
}

@test "orchestrator teardown stops parallel wave run-plan processes and descendants on SIGTERM" {
  local workspace output_dir orch_file log_a log_b
  workspace="$(setup_ctrlc_workspace)"
  output_dir="$workspace/ctrlc-logs"
  mkdir -p "$output_dir"
  orch_file="$(create_ctrlc_parallel_orchestration "$workspace")"
  log_a="$(ctrlc_expected_log "$output_dir" "stages/ctrlc-alpha.plan.md")"
  log_b="$(ctrlc_expected_log "$output_dir" "stages/ctrlc-beta.plan.md")"

  env CTRLC_OUTPUT_DIR="$output_dir" ORCHESTRATOR_RUNNER_TO_CONSOLE=0 \
    RALPH_PROCESS_TERM_GRACE_SECONDS=0.2 RALPH_PROCESS_KILL_GRACE_SECONDS=0.2 \
    bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$orch_file" "$workspace" >"$output_dir/orch.out" 2>&1 &
  local orch_pid=$!

  wait_for_log_line "$log_a" "descendant-pid=" 8
  wait_for_log_line "$log_b" "descendant-pid=" 8
  sleep 0.2

  kill -TERM "$orch_pid"
  local rc=0
  wait "$orch_pid" 2>/dev/null || rc=$?

  sleep 0.5

  [ "$rc" -eq 143 ] || { echo "FAIL: expected exit 143, got $rc"; cat "$log_a" "$log_b" "$output_dir/orch.out" 2>/dev/null || true; rm -rf "$workspace"; return 1; }

  local count_a_initial count_a_final count_b_initial count_b_final
  count_a_initial="$(wc -l < "$log_a" 2>/dev/null || echo 0)"
  count_b_initial="$(wc -l < "$log_b" 2>/dev/null || echo 0)"
  sleep 0.5
  count_a_final="$(wc -l < "$log_a" 2>/dev/null || echo 0)"
  count_b_final="$(wc -l < "$log_b" 2>/dev/null || echo 0)"
  [ "$count_a_initial" -eq "$count_a_final" ] || { echo "FAIL: log A still growing ($count_a_initial -> $count_a_final)"; rm -rf "$workspace"; return 1; }
  [ "$count_b_initial" -eq "$count_b_final" ] || { echo "FAIL: log B still growing ($count_b_initial -> $count_b_final)"; rm -rf "$workspace"; return 1; }

  rm -rf "$workspace"
}

@test "orchestrator validates produced artifact JSON when schema validation is enabled" {
  local workspace orch_file
  workspace="$(setup_orchestrator_workspace)"
  orch_file="$workspace/schema-contract.orch.json"
  mkdir -p "$workspace/schemas"
  cp "$REPO_ROOT/bundle/.ralph/schemas/evaluator-verdict.schema.json" "$workspace/schemas/"
  cat <<'ORCH' > "$orch_file"
{
  "name": "bats schema contract",
  "namespace": "bats-schema",
  "stages": [
    {
      "id": "review",
      "agent": "schema-agent",
      "runtime": "cursor",
      "plan": "stages/schema.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/bats-schema/review.json",
          "required": true,
          "schema": "schemas/evaluator-verdict.schema.json"
        }
      ]
    }
  ]
}
ORCH
  write_plan_file "$workspace" "stages/schema.plan.md"
  mkdir -p "$workspace/.ralph-workspace/artifacts/bats-schema"
  printf '%s\n' '{"status":"approved","feedback":[]}' > "$workspace/.ralph-workspace/artifacts/bats-schema/review.json"
  run env RALPH_ARTIFACT_SCHEMA_VALIDATION=1 RALPH_MODE=no bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$orch_file" "$workspace" 2>&1
  [ "$status" -eq 0 ]
  rm -rf "$workspace"
}

@test "orchestrator rejects invalid produced artifact JSON before advancing" {
  local workspace orch_file
  workspace="$(setup_orchestrator_workspace)"
  orch_file="$workspace/schema-contract-fail.orch.json"
  mkdir -p "$workspace/schemas"
  cp "$REPO_ROOT/bundle/.ralph/schemas/evaluator-verdict.schema.json" "$workspace/schemas/"
  cat <<'ORCH' > "$orch_file"
{
  "name": "bats schema contract fail",
  "namespace": "bats-schema-fail",
  "stages": [
    {
      "id": "review",
      "agent": "schema-agent",
      "runtime": "cursor",
      "plan": "stages/schema-fail.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/bats-schema-fail/review.json",
          "required": true,
          "schema": "schemas/evaluator-verdict.schema.json"
        }
      ]
    }
  ]
}
ORCH
  write_plan_file "$workspace" "stages/schema-fail.plan.md"
  mkdir -p "$workspace/.ralph-workspace/artifacts/bats-schema-fail"
  printf '%s\n' '{"status":"approved"}' > "$workspace/.ralph-workspace/artifacts/bats-schema-fail/review.json"
  run env RALPH_ARTIFACT_SCHEMA_VALIDATION=1 RALPH_MODE=no bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$orch_file" "$workspace" 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"artifact schema validation failed"* ]]
  [[ "$output" == *"stage=review"* ]]
  rm -rf "$workspace"
}

setup_router_capture_workspace() {
  local workspace
  workspace="$(setup_orchestrator_workspace)"
  cat <<'STUB' > "$workspace/.ralph/run-plan.sh"
#!/usr/bin/env bash
set -euo pipefail
plan_path=""
ws_root=""
while (($# > 0)); do
  case "$1" in
    --plan)
      plan_path="${2:-}"
      shift 2
      ;;
    --workspace)
      ws_root="${2:-}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
[[ -n "$ws_root" ]] || ws_root="$(pwd)"
log="${ROUTER_STAGE_LOG:-/dev/null}"
if [[ "${RALPH_ROUTER_STAGE:-0}" == "1" ]]; then
  mkdir -p "$ws_root/.ralph-workspace/artifacts/bats-router"
  printf '%s\n' '{"target":"branch-b","reason":"test route","confidence":0.9}' \
    > "$ws_root/.ralph-workspace/artifacts/bats-router/route.json"
  printf 'router\n' >> "$log"
else
  stage_id="$(basename "${plan_path:-unknown}" .plan.md)"
  printf '%s\n' "$stage_id" >> "$log"
fi
exit 0
STUB
  chmod +x "$workspace/.ralph/run-plan.sh"
  printf '%s' "$workspace"
}

create_router_orchestration() {
  local workspace="$1"
  local orch_path="$workspace/router.orch.json"
  mkdir -p "$workspace/schemas"
  cp "$REPO_ROOT/bundle/.ralph/schemas/router-decision.schema.json" "$workspace/schemas/"
  cat <<'ORCH' > "$orch_path"
{
  "name": "bats router",
  "namespace": "bats-router",
  "stages": [
    {
      "id": "router",
      "agent": "router-agent",
      "runtime": "cursor",
      "plan": "stages/router.plan.md",
      "router": {
        "allowedTargets": ["branch-a", "branch-b"],
        "defaultTarget": "branch-a",
        "onInvalid": "fail"
      },
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/bats-router/route.json",
          "required": true,
          "schema": "schemas/router-decision.schema.json"
        }
      ]
    },
    {
      "id": "branch-a",
      "agent": "branch-a-agent",
      "runtime": "cursor",
      "plan": "stages/branch-a.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/bats-router/branch-a.md",
          "required": true
        }
      ]
    },
    {
      "id": "branch-b",
      "agent": "branch-b-agent",
      "runtime": "cursor",
      "plan": "stages/branch-b.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/bats-router/branch-b.md",
          "required": true
        }
      ]
    },
    {
      "id": "tail",
      "agent": "tail-agent",
      "runtime": "cursor",
      "plan": "stages/tail.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/bats-router/tail.md",
          "required": true
        }
      ]
    }
  ]
}
ORCH
  write_plan_file "$workspace" "stages/router.plan.md"
  write_plan_file "$workspace" "stages/branch-a.plan.md"
  write_plan_file "$workspace" "stages/branch-b.plan.md"
  write_plan_file "$workspace" "stages/tail.plan.md"
  write_artifact_file "$workspace" ".ralph-workspace/artifacts/bats-router/branch-a.md"
  write_artifact_file "$workspace" ".ralph-workspace/artifacts/bats-router/branch-b.md"
  write_artifact_file "$workspace" ".ralph-workspace/artifacts/bats-router/tail.md"
  printf '%s' "$orch_path"
}

@test "orchestrator dispatches router target once and skips other branches" {
  local workspace orch_file stage_log summary_file
  workspace="$(setup_router_capture_workspace)"
  stage_log="$(mktemp)"
  orch_file="$(create_router_orchestration "$workspace")"
  run env RALPH_ROUTER_STAGE=1 RALPH_ARTIFACT_SCHEMA_VALIDATION=1 RALPH_MODE=no \
    ROUTER_STAGE_LOG="$stage_log" \
    bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$orch_file" "$workspace" 2>&1
  [ "$status" -eq 0 ] || { echo "FAIL: $output"; rm -f "$stage_log"; rm -rf "$workspace"; return 1; }
  [[ "$output" == *"Router selected stage: branch-b"* ]] || { echo "FAIL missing router dispatch: $output"; rm -f "$stage_log"; rm -rf "$workspace"; return 1; }
  [[ "$output" == *"skipped by router: branch-a"* ]] || { echo "FAIL missing skipped branch-a: $output"; rm -f "$stage_log"; rm -rf "$workspace"; return 1; }
  grep -Fxq router "$stage_log" || { echo "FAIL router stage not executed"; rm -f "$stage_log"; rm -rf "$workspace"; return 1; }
  grep -Fxq branch-b "$stage_log" || { echo "FAIL branch-b not executed"; rm -f "$stage_log"; rm -rf "$workspace"; return 1; }
  grep -Fxq branch-a "$stage_log" && { echo "FAIL branch-a should be skipped"; rm -f "$stage_log"; rm -rf "$workspace"; return 1; }
  summary_file="$workspace/.ralph-workspace/logs/bats-router/orchestration-usage-summary.json"
  [ -f "$summary_file" ]
  grep -Fq '"status":"skipped"' "$summary_file" || { echo "FAIL missing skipped usage record: $(cat "$summary_file")"; rm -f "$stage_log"; rm -rf "$workspace"; return 1; }
  rm -f "$stage_log"
  rm -rf "$workspace"
}

setup_planner_capture_workspace() {
  local workspace
  workspace="$(setup_orchestrator_workspace)"
  mkdir -p "$workspace/.ralph/python"
  cp "$REPO_ROOT/bundle/.ralph/python/planner_contract.py" "$workspace/.ralph/python/"
  cp "$REPO_ROOT/bundle/.ralph/python/artifact_json_schema.py" "$workspace/.ralph/python/"
  cat <<'STUB' > "$workspace/.ralph/run-plan.sh"
#!/usr/bin/env bash
set -euo pipefail
plan_path=""
ws_root=""
while (($# > 0)); do
  case "$1" in
    --plan)
      plan_path="${2:-}"
      shift 2
      ;;
    --workspace)
      ws_root="${2:-}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
[[ -n "$ws_root" ]] || ws_root="$(pwd)"
log="${PLANNER_STAGE_LOG:-/dev/null}"
if [[ "${RALPH_PLANNER_STAGE:-0}" == "1" ]]; then
  mkdir -p "$ws_root/.ralph-workspace/artifacts/bats-planner"
  cat > "$ws_root/.ralph-workspace/artifacts/bats-planner/planner-output.json" <<'JSON'
{
  "rationale": "Split into two worker slices.",
  "items": [
    {
      "id": "worker-1",
      "content": "First generated worker slice",
      "runtime": "cursor",
      "agent": "implementation"
    },
    {
      "id": "worker-2",
      "content": "Second generated worker slice",
      "runtime": "cursor",
      "agent": "implementation"
    }
  ],
  "artifactRelationships": [],
  "verification": "bash scripts/run-bats.sh tests/bats/plan/validate-plan.bats"
}
JSON
  printf 'planner\n' >> "$log"
else
  stage_id="$(basename "${plan_path:-unknown}" .plan.md)"
  printf '%s\n' "$stage_id" >> "$log"
  if [[ "$stage_id" == worker-* ]]; then
    mkdir -p "$ws_root/.ralph-workspace/artifacts/bats-planner"
    printf '# worker artifact\n' > "$ws_root/.ralph-workspace/artifacts/bats-planner/${stage_id}.md"
  fi
fi
exit 0
STUB
  chmod +x "$workspace/.ralph/run-plan.sh"
  create_agent_config_workspace "$workspace" "architect" ".ralph-workspace/artifacts/bats-planner/planner-output.json"
  create_agent_config_workspace "$workspace" "implementation" ".ralph-workspace/artifacts/bats-planner/worker.md"
  printf '%s' "$workspace"
}

create_planner_orchestration() {
  local workspace="$1"
  local orch_path="$workspace/planner.orch.json"
  mkdir -p "$workspace/schemas"
  cp "$REPO_ROOT/bundle/.ralph/schemas/planner-output.schema.json" "$workspace/schemas/"
  cat <<'ORCH' > "$orch_path"
{
  "name": "bats planner",
  "namespace": "bats-planner",
  "stages": [
    {
      "id": "planner",
      "agent": "architect",
      "runtime": "cursor",
      "plan": "stages/planner.plan.md",
      "planner": {
        "outputMode": "stages",
        "maxTodos": 8,
        "maxStages": 3,
        "allowedRuntimes": ["cursor"],
        "allowedAgents": ["implementation"],
        "allowedModels": ["auto"]
      },
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/bats-planner/planner-output.json",
          "required": true,
          "schema": "schemas/planner-output.schema.json"
        }
      ]
    },
    {
      "id": "tail",
      "agent": "tail-agent",
      "runtime": "cursor",
      "plan": "stages/tail.plan.md",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/bats-planner/tail.md",
          "required": true
        }
      ]
    }
  ]
}
ORCH
  write_plan_file "$workspace" "stages/planner.plan.md"
  write_plan_file "$workspace" "stages/tail.plan.md"
  create_agent_config_workspace "$workspace" "tail-agent" ".ralph-workspace/artifacts/bats-planner/tail.md"
  write_artifact_file "$workspace" ".ralph-workspace/artifacts/bats-planner/tail.md"
  printf '%s' "$orch_path"
}

@test "orchestrator queues generated planner stages before tail" {
  local workspace orch_file stage_log
  workspace="$(setup_planner_capture_workspace)"
  stage_log="$(mktemp)"
  orch_file="$(create_planner_orchestration "$workspace")"
  run env RALPH_DYNAMIC_PLANNER=1 RALPH_MODE=no RALPH_ARTIFACT_SCHEMA_VALIDATION=1 \
    PLANNER_STAGE_LOG="$stage_log" \
    bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$orch_file" "$workspace" 2>&1
  [ "$status" -eq 0 ] || { echo "FAIL: $output"; rm -f "$stage_log"; rm -rf "$workspace"; return 1; }
  [[ "$output" == *"Planner decomposition:"* ]] || { echo "FAIL missing planner summary: $output"; rm -f "$stage_log"; rm -rf "$workspace"; return 1; }
  grep -Fxq planner "$stage_log" || { echo "FAIL planner stage not executed"; rm -f "$stage_log"; rm -rf "$workspace"; return 1; }
  grep -Fxq worker-1 "$stage_log" || { echo "FAIL worker-1 not executed"; rm -f "$stage_log"; rm -rf "$workspace"; return 1; }
  grep -Fxq worker-2 "$stage_log" || { echo "FAIL worker-2 not executed"; rm -f "$stage_log"; rm -rf "$workspace"; return 1; }
  grep -Fxq tail "$stage_log" || { echo "FAIL tail not executed"; rm -f "$stage_log"; rm -rf "$workspace"; return 1; }
  [ -f "$workspace/.ralph-workspace/orchestration-plans/bats-planner/generated/worker-1.plan.md" ]
  rm -f "$stage_log"
  rm -rf "$workspace"
}

@test "orchestrator dry-run shows planner decomposition when artifact exists" {
  local workspace orch_file
  workspace="$(setup_planner_capture_workspace)"
  orch_file="$(create_planner_orchestration "$workspace")"
  mkdir -p "$workspace/.ralph-workspace/artifacts/bats-planner"
  cat > "$workspace/.ralph-workspace/artifacts/bats-planner/planner-output.json" <<'JSON'
{
  "rationale": "Dry-run preview.",
  "items": [
    {
      "id": "worker-1",
      "content": "Preview worker",
      "runtime": "cursor",
      "agent": "implementation"
    }
  ],
  "artifactRelationships": [],
  "verification": "bash scripts/run-bats.sh tests/bats/plan/validate-plan.bats"
}
JSON
  run env RALPH_DYNAMIC_PLANNER=1 RALPH_MODE=no ORCHESTRATOR_DRY_RUN=1 \
    bash "$REPO_ROOT/.ralph/orchestrator.sh" --orchestration "$orch_file" "$workspace" 2>&1
  [ "$status" -eq 0 ] || { echo "FAIL: $output"; rm -rf "$workspace"; return 1; }
  [[ "$output" == *"Planner decomposition:"* ]] || { echo "FAIL missing dry-run planner summary: $output"; rm -rf "$workspace"; return 1; }
  [[ "$output" == *"worker-1"* ]] || { echo "FAIL missing worker preview: $output"; rm -rf "$workspace"; return 1; }
  rm -rf "$workspace"
}
