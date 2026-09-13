#!/usr/bin/env bats
# Stage-only orchestration artifacts: required inputs/outputs and contracts come
# exclusively from the stage. Profile output_artifacts are never merged.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$RALPH_LIB_ROOT/artifacts.sh"
source "$RALPH_LIB_ROOT/orchestrator/orchestrator-lib.sh"
source "$RALPH_LIB_ROOT/orchestrator/orchestrator-verify.sh"

ORCHESTRATOR_SH="$REPO_ROOT/bundle/.ralph/orchestrator.sh"

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq required"
  [ -f "$ORCHESTRATOR_SH" ] || skip "orchestrator missing"
  EXPECTED_ARTIFACT_PATHS=()
  unset RALPH_ARTIFACT_NS RALPH_PLAN_KEY RALPH_STAGE_ID ORCH_BASENAME
  unset RALPH_PROCESS_RUN_DIR RALPH_PROCESS_RUN_ID RALPH_PROCESS_RUN_DEPTH \
    RALPH_PROCESS_ATTACHED_PLAN RALPH_PROCESS_SCOPE_TOKEN \
    RALPH_PROCESS_RUN_TOKEN RALPH_PROCESS_GUARDIAN_PID RALPH_PROCESS_RUN_OWNED \
    2>/dev/null || true
}

teardown() {
  if [[ -n "${WORKSPACE:-}" && -d "${WORKSPACE:-}" ]]; then
    ralph_test_rm_workspace "$WORKSPACE"
  fi
}

setup_role_artifacts_workspace() {
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
  cat <<'STUB' >"$workspace/.ralph/run-plan.sh"
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
  cat <<'PLAN' >"$workspace/$plan_rel"
# Plan
- [ ] placeholder TODO
PLAN
}

write_artifact_file() {
  local workspace="$1"
  local artifact_rel="$2"
  mkdir -p "$workspace/$(dirname "$artifact_rel")"
  printf 'artifact placeholder for %s\n' "$(basename "$artifact_rel")" >"$workspace/$artifact_rel"
}

create_profile_with_output_artifacts() {
  local workspace="$1"
  local role_id="$2"
  local artifact_path="$3"
  mkdir -p "$workspace/.cursor/agents/$role_id"
  cat >"$workspace/.cursor/agents/$role_id/config.json" <<CFG
{
  "name": "$role_id",
  "model": "test-model",
  "description": "legacy profile for fallback rejection",
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
  if [[ -f "$REPO_ROOT/.ralph/agent-config-tool.sh" ]]; then
    cp "$REPO_ROOT/.ralph/agent-config-tool.sh" "$workspace/.ralph/"
  fi
}

@test "collect: roleless stage with no artifacts expects none" {
  local stage
  stage='{"id":"s1","runtime":"cursor","plan":"p.md"}'
  orch_stage_collect_expected_artifacts "$stage"
  [ "${#EXPECTED_ARTIFACT_PATHS[@]}" -eq 0 ]
}

@test "collect: role-with-none ignores absent stage outputs" {
  local stage
  stage='{"id":"s1","runtime":"cursor","role":"research","plan":"p.md"}'
  orch_stage_collect_expected_artifacts "$stage"
  [ "${#EXPECTED_ARTIFACT_PATHS[@]}" -eq 0 ]
}

@test "collect: explicit required outputArtifacts expand tokens" {
  export RALPH_ARTIFACT_NS="role-arts"
  export RALPH_STAGE_ID="impl"
  local stage
  stage='{"id":"impl","runtime":"cursor","role":"implementation","plan":"p.md","outputArtifacts":[{"path":".ralph-workspace/artifacts/{{ARTIFACT_NS}}/{{STAGE_ID}}.md","required":true}]}'
  orch_stage_collect_expected_artifacts "$stage"
  [ "${#EXPECTED_ARTIFACT_PATHS[@]}" -eq 1 ]
  [ "${EXPECTED_ARTIFACT_PATHS[0]}" = ".ralph-workspace/artifacts/role-arts/impl.md" ]
}

@test "collect: optional outputArtifacts are not required" {
  export RALPH_ARTIFACT_NS="role-arts"
  local stage
  stage='{"id":"s1","runtime":"cursor","plan":"p.md","outputArtifacts":[{"path":".ralph-workspace/artifacts/{{ARTIFACT_NS}}/optional.md","required":false}]}'
  orch_stage_collect_expected_artifacts "$stage"
  [ "${#EXPECTED_ARTIFACT_PATHS[@]}" -eq 0 ]
}

@test "orchestrator: roleless stage with no artifacts succeeds without profile merge" {
  WORKSPACE="$(setup_role_artifacts_workspace)"
  local orch_file="$WORKSPACE/roleless.orch.json"
  cat <<'ORCH' >"$orch_file"
{
  "name": "roleless arts",
  "namespace": "roleless-arts",
  "stages": [
    {
      "id": "solo",
      "runtime": "cursor",
      "plan": "stages/solo.plan.md"
    }
  ]
}
ORCH
  write_plan_file "$WORKSPACE" "stages/solo.plan.md"
  run bash "$ORCHESTRATOR_SH" --orchestration "$orch_file" "$WORKSPACE" 2>&1
  [ "$status" -eq 0 ] || { echo "FAIL: $output"; return 1; }
}

@test "orchestrator: role-with-none does not require profile output_artifacts" {
  WORKSPACE="$(setup_role_artifacts_workspace)"
  create_profile_with_output_artifacts "$WORKSPACE" "research" \
    ".ralph-workspace/artifacts/role-none/from-profile.md"
  local orch_file="$WORKSPACE/role-none.orch.json"
  cat <<'ORCH' >"$orch_file"
{
  "name": "role none arts",
  "namespace": "role-none",
  "stages": [
    {
      "id": "research-step",
      "runtime": "cursor",
      "plan": "stages/research.plan.md"
    }
  ]
}
ORCH
  write_plan_file "$WORKSPACE" "stages/research.plan.md"
  # Deliberately omit from-profile.md -- fallback would fail the run if still active.
  run bash "$ORCHESTRATOR_SH" --orchestration "$orch_file" "$WORKSPACE" 2>&1
  [ "$status" -eq 0 ] || { echo "FAIL: $output"; return 1; }
}

@test "orchestrator: explicit required outputArtifacts are checked non-empty" {
  WORKSPACE="$(setup_role_artifacts_workspace)"
  local orch_file="$WORKSPACE/explicit.orch.json"
  cat <<'ORCH' >"$orch_file"
{
  "name": "explicit arts",
  "namespace": "explicit-arts",
  "stages": [
    {
      "id": "writer",
      "runtime": "cursor",
      "plan": "stages/writer.plan.md",
      "outputArtifacts": [
        {
          "path": ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/{{STAGE_ID}}.md",
          "required": true
        }
      ]
    }
  ]
}
ORCH
  write_plan_file "$WORKSPACE" "stages/writer.plan.md"
  write_artifact_file "$WORKSPACE" ".ralph-workspace/artifacts/explicit-arts/writer.md"
  run bash "$ORCHESTRATOR_SH" --orchestration "$orch_file" "$WORKSPACE" 2>&1
  [ "$status" -eq 0 ] || { echo "FAIL: $output"; return 1; }

  # Empty required file must fail the required/non-empty check.
  : >"$WORKSPACE/.ralph-workspace/artifacts/explicit-arts/writer.md"
  run bash "$ORCHESTRATOR_SH" --orchestration "$orch_file" "$WORKSPACE" 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"empty"* || "$output" == *"artifact check"* ]]
}

@test "orchestrator: legacy profile output_artifacts fallback is rejected" {
  WORKSPACE="$(setup_role_artifacts_workspace)"
  create_profile_with_output_artifacts "$WORKSPACE" "architect" \
    ".ralph-workspace/artifacts/legacy-fb/from-profile.md"
  write_artifact_file "$WORKSPACE" ".ralph-workspace/artifacts/legacy-fb/from-profile.md"
  local orch_file="$WORKSPACE/legacy-fb.orch.json"
  cat <<'ORCH' >"$orch_file"
{
  "name": "legacy fallback",
  "namespace": "legacy-fb",
  "stages": [
    {
      "id": "arch",
      "runtime": "cursor",
      "plan": "stages/arch.plan.md"
    }
  ]
}
ORCH
  write_plan_file "$WORKSPACE" "stages/arch.plan.md"
  # Stage declares no artifacts. Profile still lists a required output.
  # Collect must stay empty (no merge); run succeeds without treating profile path as required.
  local stage_json
  stage_json="$(jq -c '.stages[0]' "$orch_file")"
  export RALPH_ARTIFACT_NS="legacy-fb"
  export WORKSPACE
  orch_stage_collect_expected_artifacts "$stage_json"
  [ "${#EXPECTED_ARTIFACT_PATHS[@]}" -eq 0 ]

  run bash "$ORCHESTRATOR_SH" --orchestration "$orch_file" "$WORKSPACE" 2>&1
  [ "$status" -eq 0 ] || { echo "FAIL: $output"; return 1; }

  # Removed agentSource syntax still fails with migrate hint (not silent fallback).
  cat <<'ORCH' >"$orch_file"
{
  "name": "legacy agentSource",
  "namespace": "legacy-fb",
  "stages": [
    {
      "id": "arch",
      "runtime": "cursor",
      "agentSource": "prebuilt",
      "plan": "stages/arch.plan.md"
    }
  ]
}
ORCH
  run bash "$ORCHESTRATOR_SH" --orchestration "$orch_file" "$WORKSPACE" 2>&1
  [ "$status" -ne 0 ]
  # `ralph migrate` was removed; the guidance now names inline instructions.
  [[ "$output" == *"agent"* ]]
  [[ "$output" != *"ralph migrate"* ]]
}
