#!/usr/bin/env bats
# Per-stage toolingProfile env overlay in ordinary orchestration: orch_stage_execute
# must append ralph_tooling_profile_env lines to the child env prefix without
# exporting into the orchestrator process or reusing one stage's overlay for another.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$REPO_ROOT/bundle/.ralph/bash-lib/tooling-profile.sh"

ORCHESTRATOR_SH="$REPO_ROOT/bundle/.ralph/orchestrator.sh"
VALIDATOR="$REPO_ROOT/scripts/validate-orchestration-schema.sh"

PROFILE_ENV_KEYS='RALPH_MODE
RALPH_PROXY_SHELL_COMPACT
RALPH_COMPACT_GENERIC_FALLBACK
RALPH_COMPACT_GENERIC_THRESHOLD_BYTES
RALPH_NATIVE_RESULT_COMPACT
RALPH_TOOLING_PROFILE
RALPH_TOOLING_PROFILE_DEGRADED'

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq required"
  [ -f "$ORCHESTRATOR_SH" ] || skip "orchestrator missing"
  unset RALPH_PROCESS_RUN_DIR RALPH_PROCESS_RUN_ID RALPH_PROCESS_RUN_DEPTH \
    RALPH_PROCESS_ATTACHED_PLAN RALPH_PROCESS_SCOPE_TOKEN \
    RALPH_PROCESS_RUN_TOKEN RALPH_PROCESS_GUARDIAN_PID RALPH_PROCESS_RUN_OWNED \
    2>/dev/null || true
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
  cp "$REPO_ROOT/.ralph/bash-lib/atomic-json.sh" "$workspace/.ralph/bash-lib/"
  cp "$REPO_ROOT/.ralph/bash-lib/ralph-process-teardown.sh" "$workspace/.ralph/bash-lib/"
  cp "$REPO_ROOT/.ralph/bash-lib/ralph-process-supervisor.sh" "$workspace/.ralph/bash-lib/"
  cp "$REPO_ROOT/.ralph/python/ralph_process_supervisor.py" "$workspace/.ralph/python/"
  mkdir -p "$workspace/.ralph-workspace/logs"
  printf '%s' "$workspace"
}

setup_tooling_capture_workspace() {
  local workspace
  workspace="$(setup_orchestrator_workspace)"
  cat <<'STUB' >"$workspace/.ralph/run-plan.sh"
#!/usr/bin/env bash
set -euo pipefail
capture="${TOOLING_CAPTURE_FILE:-/dev/null}"
{
  printf 'STAGE=%s\n' "${RALPH_STAGE_ID:-unknown}"
  var=""
  for var in \
    RALPH_MODE \
    RALPH_PROXY_SHELL_COMPACT \
    RALPH_COMPACT_GENERIC_FALLBACK \
    RALPH_COMPACT_GENERIC_THRESHOLD_BYTES \
    RALPH_NATIVE_RESULT_COMPACT \
    RALPH_TOOLING_PROFILE \
    RALPH_TOOLING_PROFILE_DEGRADED
  do
    if [[ -n "${!var+x}" ]]; then
      printf '%s=%s\n' "$var" "${!var}"
    fi
  done
  printf 'END_BLOCK\n'
} >>"$capture"
exit 0
STUB
  chmod +x "$workspace/.ralph/run-plan.sh"
  printf '%s' "$workspace"
}

write_plan_file() {
  local workspace="$1"
  local plan_rel="$2"
  mkdir -p "$workspace/$(dirname "$plan_rel")"
  cat <<'PLAN' >"$workspace/$plan_rel"
# Plan
- [x] done
PLAN
}

write_artifact_file() {
  local workspace="$1"
  local artifact_rel="$2"
  mkdir -p "$workspace/$(dirname "$artifact_rel")"
  printf 'artifact\n' >"$workspace/$artifact_rel"
}

_capture_orchestrator_tooling_env() {
  { env | grep -E '^(RALPH_MODE|RALPH_PROXY_SHELL_COMPACT|RALPH_COMPACT_GENERIC_FALLBACK|RALPH_COMPACT_GENERIC_THRESHOLD_BYTES|RALPH_NATIVE_RESULT_COMPACT|RALPH_TOOLING_PROFILE|RALPH_TOOLING_PROFILE_DEGRADED)=' || true; } | sort
}

_assert_capture_block_matches_profile() {
  local block="$1" profile="$2" runtime="$3"
  local expected_lines=() line key value captured_key captured_value found

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    expected_lines+=("$line")
  done < <(ralph_tooling_profile_env "$profile" "$runtime")

  for line in "${expected_lines[@]}"; do
    key="${line%%=*}"
    value="${line#*=}"
    captured_value=""
    captured_key="$(printf '%s\n' "$block" | sed -n "s/^${key}=//p" | head -n1)"
    captured_value="$captured_key"
    [[ -n "$captured_value" ]] \
      || { echo "missing profile env '$key' in child capture for $profile/$runtime"; return 1; }
    [[ "$captured_value" == "$value" ]] \
      || { echo "unexpected value for $key: expected '$value' got '$captured_value' (profile=$profile runtime=$runtime)"; return 1; }
  done

  while IFS= read -r line; do
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    printf '%s\n' "$PROFILE_ENV_KEYS" | grep -qxF "$key" || continue
    found=0
    for expected in "${expected_lines[@]}"; do
      if [[ "$line" == "$expected" ]]; then
        found=1
        break
      fi
    done
    [ "$found" -eq 1 ] || { echo "unexpected profile env entry '$line' in child capture for $profile/$runtime"; return 1; }
  done <<< "$block"
}

_extract_capture_block() {
  local file="$1" stage_id="$2"
  awk -v stage="$stage_id" '
    $0 == "STAGE=" stage { capture=1; print; next }
    capture && $0 == "END_BLOCK" { print; capture=0; next }
    capture { print }
  ' "$file"
}

@test "orchestrator applies per-stage toolingProfile env without mutating parent env" {
  local workspace capture_file orch_file before after block_a block_b
  workspace="$(setup_tooling_capture_workspace)"
  capture_file="$(mktemp)"
  orch_file="$workspace/two-profile.orch.json"

  jq -n '{
    name: "tooling-orch",
    namespace: "tooling-orch",
    stages: [
      {
        id: "stage-a",
        runtime: "cursor",
        role: "alpha",
        toolingProfile: "ralph-read-heavy",
        plan: "stages/stage-a.plan.md",
        sessionResume: false,
        artifacts: [{path: ".ralph-workspace/artifacts/tooling-orch/stage-a.md", required: true}]
      },
      {
        id: "stage-b",
        runtime: "cursor",
        role: "alpha",
        toolingProfile: "ralph-aggressive",
        plan: "stages/stage-b.plan.md",
        sessionResume: false,
        artifacts: [{path: ".ralph-workspace/artifacts/tooling-orch/stage-b.md", required: true}]
      }
    ]
  }' >"$orch_file"

  write_plan_file "$workspace" "stages/stage-a.plan.md"
  write_plan_file "$workspace" "stages/stage-b.plan.md"
  write_artifact_file "$workspace" ".ralph-workspace/artifacts/tooling-orch/stage-a.md"
  write_artifact_file "$workspace" ".ralph-workspace/artifacts/tooling-orch/stage-b.md"

  export RALPH_MODE=no
  export RALPH_NATIVE_RESULT_COMPACT=0
  before="$(_capture_orchestrator_tooling_env)"

  run env RALPH_ALLOW_NESTED_RUNS=1 TOOLING_CAPTURE_FILE="$capture_file" ORCHESTRATOR_RUNNER_TO_CONSOLE=0 \
    bash "$ORCHESTRATOR_SH" --orchestration "$orch_file" "$workspace" 2>&1
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }

  block_a="$(_extract_capture_block "$capture_file" stage-a)"
  block_b="$(_extract_capture_block "$capture_file" stage-b)"
  [ -n "$block_a" ] || { echo "missing capture block for stage-a"; return 1; }
  [ -n "$block_b" ] || { echo "missing capture block for stage-b"; return 1; }

  _assert_capture_block_matches_profile "$block_a" ralph-read-heavy cursor
  _assert_capture_block_matches_profile "$block_b" ralph-aggressive cursor
  printf '%s\n' "$block_a" | grep -qxF "RALPH_MODE=ralph"
  printf '%s\n' "$block_a" | grep -qxF "RALPH_NATIVE_RESULT_COMPACT=0"
  printf '%s\n' "$block_b" | grep -qxF "RALPH_MODE=ralph"
  printf '%s\n' "$block_b" | grep -qxF "RALPH_NATIVE_RESULT_COMPACT=1"

  after="$(_capture_orchestrator_tooling_env)"
  [ "$before" = "$after" ]
  [ "$RALPH_MODE" = "no" ]
  [ "$RALPH_NATIVE_RESULT_COMPACT" = "0" ]

  rm -f "$capture_file"
  ralph_test_rm_workspace "$workspace"
}

@test "orchestrator adds no tooling overlay when stage omits toolingProfile" {
  local workspace capture_file orch_file block key
  workspace="$(setup_tooling_capture_workspace)"
  capture_file="$(mktemp)"
  orch_file="$workspace/no-profile.orch.json"

  jq -n '{
    name: "no-tooling",
    namespace: "no-tooling",
    stages: [{
      id: "plain",
      runtime: "cursor",
      role: "alpha",
      plan: "stages/plain.plan.md",
      sessionResume: false,
      artifacts: [{path: ".ralph-workspace/artifacts/no-tooling/plain.md", required: true}]
    }]
  }' >"$orch_file"

  write_plan_file "$workspace" "stages/plain.plan.md"
  write_artifact_file "$workspace" ".ralph-workspace/artifacts/no-tooling/plain.md"

  run env RALPH_ALLOW_NESTED_RUNS=1 TOOLING_CAPTURE_FILE="$capture_file" ORCHESTRATOR_RUNNER_TO_CONSOLE=0 \
    bash "$ORCHESTRATOR_SH" --orchestration "$orch_file" "$workspace" 2>&1
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }

  block="$(_extract_capture_block "$capture_file" plain)"
  [ -n "$block" ] || { echo "missing capture block for plain stage"; return 1; }

  while IFS= read -r line; do
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    printf '%s\n' "$PROFILE_ENV_KEYS" | grep -qxF "$key" \
      && { echo "unexpected profile env key '$key' when toolingProfile is absent"; return 1; }
  done <<< "$block"

  rm -f "$capture_file"
  ralph_test_rm_workspace "$workspace"
}

@test "validate-orchestration-schema rejects ralphMode with stage toolingProfile" {
  local orch
  orch="$(mktemp)"
  cat <<'EOF' >"$orch"
{
  "name": "schema-test",
  "namespace": "schema-test",
  "ralphMode": "ralph",
  "stages": [
    {
      "id": "stage-one",
      "runtime": "cursor",
      "plan": "stages/stage-one.plan.md",
      "toolingProfile": "ralph-compact",
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/schema-test/stage-one.md"
        }
      ]
    }
  ]
}
EOF
  run "$VALIDATOR" "$orch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ralphMode"* ]]
  [[ "$output" == *"toolingProfile"* ]]
  rm -f "$orch"
}

@test "orchestrator rejects ralphMode with stage toolingProfile before invoking run-plan" {
  local workspace capture_file orch_file
  workspace="$(setup_tooling_capture_workspace)"
  capture_file="$(mktemp)"
  orch_file="$workspace/conflict.orch.json"

  jq -n '{
    name: "conflict",
    namespace: "conflict",
    ralphMode: "ralph",
    stages: [{
      id: "stage-one",
      runtime: "cursor",
      role: "alpha",
      toolingProfile: "ralph-compact",
      plan: "stages/stage-one.plan.md",
      sessionResume: false,
      artifacts: [{path: ".ralph-workspace/artifacts/conflict/stage-one.md", required: true}]
    }]
  }' >"$orch_file"

  write_plan_file "$workspace" "stages/stage-one.plan.md"
  write_artifact_file "$workspace" ".ralph-workspace/artifacts/conflict/stage-one.md"

  run env RALPH_ALLOW_NESTED_RUNS=1 TOOLING_CAPTURE_FILE="$capture_file" ORCHESTRATOR_RUNNER_TO_CONSOLE=0 \
    bash "$ORCHESTRATOR_SH" --orchestration "$orch_file" "$workspace" 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"ralphMode"* ]]
  [[ "$output" == *"toolingProfile"* ]]
  [ ! -s "$capture_file" ]

  rm -f "$capture_file"
  ralph_test_rm_workspace "$workspace"
}
