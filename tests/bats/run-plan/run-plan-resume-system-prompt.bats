#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/run-plan-invoke-test-helper.bash"

setup() {
  export RALPH_RUN_PLAN_LIBRARY_ONLY=1
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-core.sh"
  unset RALPH_RUN_PLAN_LIBRARY_ONLY
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-claude.sh"
  run_plan_invoke_test_setup_common
}

teardown() {
  run_plan_invoke_test_teardown_common
}

@test "resume system-prompt is stable across two TODO invocations" {
  local record="$TEST_TMPDIR/claude.args"
  run_plan_invoke_test_write_claude_stub "$record"

  export RUNTIME=claude
  export SELECTED_MODEL=test-model
  export RALPH_MODE=hybrid
  export RALPH_PLAN_SESSION_STRATEGY=resume
  export RALPH_ARTIFACT_NS=resume-prompt-test
  export RALPH_PLAN_KEY=resume-prompt-test
  export RALPH_RUN_PLAN_NEW_SESSION_ID=first-session
  unset RALPH_RUN_PLAN_RESUME_SESSION_ID
  export PROMPT="first TODO"
  export PROMPT_STATIC="$(ralph_run_plan_rebuild_prompt_static)"
  local first_prompt="$PROMPT_STATIC"
  local first_fingerprint
  first_fingerprint="$(ralph_run_plan_stable_prefix_fingerprint "$PROMPT_STATIC")"
  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]

  export RALPH_RUN_PLAN_RESUME_SESSION_ID=first-session
  unset RALPH_RUN_PLAN_NEW_SESSION_ID
  export PROMPT="second TODO"
  export PROMPT_STATIC="$(ralph_run_plan_rebuild_prompt_static)"
  local second_fingerprint
  second_fingerprint="$(ralph_run_plan_stable_prefix_fingerprint "$PROMPT_STATIC")"
  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]

  [ "$(grep -Fxc -- '--append-system-prompt' "$record")" -eq 2 ]
  ! grep -Fxq -- "--system-prompt" "$record"
  ! grep -Fxq -- "--exclude-dynamic-system-prompt-sections" "$record"
  [ "$PROMPT_STATIC" = "$first_prompt" ]
  [ "$second_fingerprint" = "$first_fingerprint" ]
}
