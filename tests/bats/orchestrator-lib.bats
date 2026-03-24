#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"
source "$RALPH_LIB_ROOT/orchestrator-lib.sh"

setup() {
  WORKSPACE="/tmp/ralph-ws"
  export ORCH_BASENAME="orch-base"
  export RALPH_ARTIFACT_NS=""
  unset RALPH_PLAN_KEY
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
  result="$(expand_artifact_tokens ".ralph-workspace/{{ARTIFACT_NS}}/out.md")"
  [ "$result" = ".ralph-workspace/custom-ns/out.md" ]
}

@test "expand_artifact_tokens resolves STAGE_ID token" {
  export RALPH_ARTIFACT_NS="my-ns"
  export RALPH_STAGE_ID="cr1"
  result="$(expand_artifact_tokens ".ralph-workspace/{{ARTIFACT_NS}}/{{STAGE_ID}}.md")"
  [ "$result" = ".ralph-workspace/my-ns/cr1.md" ]
  unset RALPH_STAGE_ID
}

@test "expand_artifact_tokens leaves STAGE_ID empty when env var unset" {
  export RALPH_ARTIFACT_NS="my-ns"
  unset RALPH_STAGE_ID
  result="$(expand_artifact_tokens ".ralph-workspace/{{ARTIFACT_NS}}/{{STAGE_ID}}.md")"
  [ "$result" = ".ralph-workspace/my-ns/.md" ]
}

@test "expand_artifact_tokens resolves all three tokens together" {
  export RALPH_ARTIFACT_NS="pipeline"
  export RALPH_STAGE_ID="sr2"
  ORCH_BASENAME="pipeline"
  result="$(expand_artifact_tokens "{{ARTIFACT_NS}}/{{PLAN_KEY}}/{{STAGE_ID}}.md")"
  [ "$result" = "pipeline/pipeline/sr2.md" ]
  unset RALPH_STAGE_ID
}

@test "expand_artifact_tokens prefers PLAN_KEY over ARTIFACT_NS" {
  export RALPH_ARTIFACT_NS="my-ns"
  export RALPH_PLAN_KEY="my-plan-key"
  result="$(expand_artifact_tokens ".ralph-workspace/{{PLAN_KEY}}/artifact.md")"
  [ "$result" = ".ralph-workspace/my-plan-key/artifact.md" ]
  unset RALPH_PLAN_KEY
}

@test "expand_artifact_tokens falls back to ARTIFACT_NS when PLAN_KEY empty" {
  export RALPH_ARTIFACT_NS="fallback-ns"
  export RALPH_PLAN_KEY=""
  result="$(expand_artifact_tokens ".ralph-workspace/{{PLAN_KEY}}/artifact.md")"
  [ "$result" = ".ralph-workspace/fallback-ns/artifact.md" ]
  unset RALPH_PLAN_KEY
}

@test "artifact_paths_append_unique deduplicates after token expansion" {
  export RALPH_ARTIFACT_NS="dedup-ns"
  export RALPH_STAGE_ID="step1"
  EXPECTED_ARTIFACT_PATHS=()
  artifact_paths_append_unique ".ralph-workspace/{{ARTIFACT_NS}}/{{STAGE_ID}}.md"
  artifact_paths_append_unique ".ralph-workspace/dedup-ns/step1.md"
  [ "${#EXPECTED_ARTIFACT_PATHS[@]}" -eq 1 ]
  [ "${EXPECTED_ARTIFACT_PATHS[0]}" = ".ralph-workspace/dedup-ns/step1.md" ]
  unset RALPH_STAGE_ID
}

@test "parse_artifact_csv trims entries and resets state" {
  EXPECTED_ARTIFACT_PATHS=("preexisting")
  parse_artifact_csv " first ,second, ,  third  "
  [ "${#EXPECTED_ARTIFACT_PATHS[@]}" -eq 3 ]
  [ "${EXPECTED_ARTIFACT_PATHS[0]}" = "first" ]
  [ "${EXPECTED_ARTIFACT_PATHS[1]}" = "second" ]
  [ "${EXPECTED_ARTIFACT_PATHS[2]}" = "third" ]

  parse_artifact_csv ""
  [ "${#EXPECTED_ARTIFACT_PATHS[@]}" -eq 0 ]
}
