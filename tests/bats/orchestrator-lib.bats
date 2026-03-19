#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"
source "$RALPH_LIB_ROOT/orchestrator-lib.sh"

setup() {
  WORKSPACE="/tmp/ralph-ws"
  export ORCH_BASENAME="orch-base"
  export RALPH_ARTIFACT_NS=""
  EXPECTED_ARTIFACT_PATHS=()
}

@test "normalize_runtime lowercases and defaults" {
  run orchestrator_normalize_runtime "CLAUDE"
  [ "$status" -eq 0 ]
  [ "$output" = "claude" ]

  run orchestrator_normalize_runtime ""
  [ "$status" -eq 0 ]
  [ "$output" = "cursor" ]
}

@test "validate_runtime accepts known runtimes" {
  run orchestrator_validate_runtime "CODEX"
  [ "$status" -eq 0 ]
  [ "$output" = "codex" ]
}

@test "validate_runtime rejects unsupported runtimes" {
  run orchestrator_validate_runtime "alien"
  [ "$status" -ne 0 ]
}

@test "validate_stage_agent_plan enforces agent and plan" {
  run orchestrator_validate_stage_agent_plan "agent" ""
  [ "$status" -ne 0 ]

  run orchestrator_validate_stage_agent_plan "agent" "plan.md"
  [ "$status" -eq 0 ]
}

@test "stage_plan_abs resolves paths" {
  result="$(orchestrator_stage_plan_abs "docs/next.md" "$WORKSPACE")"
  [ "$result" = "$WORKSPACE/docs/next.md" ]

  result="$(orchestrator_stage_plan_abs "/abs/plan.md" "$WORKSPACE")"
  [ "$result" = "/abs/plan.md" ]
}

@test "expand_artifact_tokens honors namespace" {
  export RALPH_ARTIFACT_NS="custom-ns"
  result="$(expand_artifact_tokens ".agents/{{ARTIFACT_NS}}/out.md")"
  [ "$result" = ".agents/custom-ns/out.md" ]
}

@test "artifact_paths_append_unique deduplicates expanded paths" {
  EXPECTED_ARTIFACT_PATHS=()
  export RALPH_ARTIFACT_NS="report-ns"

  artifact_paths_append_unique ".agents/{{ARTIFACT_NS}}/output.md"
  [ "${EXPECTED_ARTIFACT_PATHS[0]}" = ".agents/report-ns/output.md" ]

  artifact_paths_append_unique ".agents/{{ARTIFACT_NS}}/output.md"
  [ "${#EXPECTED_ARTIFACT_PATHS[@]}" -eq 1 ]
}
