#!/usr/bin/env bats
# shellcheck shell=bash

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
# shellcheck disable=SC1090
source "$BATS_TEST_DIRNAME/run-plan-invoke-test-helper.bash"

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-cursor.sh"
  run_plan_invoke_test_setup_common
}

teardown() {
  run_plan_invoke_test_teardown_common
}

@test "cursor invoke helper dispatches the stubbed CLI" {
  local record="$TEST_TMPDIR/cursor.args"
  run_plan_invoke_test_write_stub "cursor-agent" "$record"

  export PROMPT="cursor-smoke-prompt"
  export RALPH_MODE=native

  run ralph_run_plan_invoke_cursor
  [ "$status" -eq 0 ]
  [ -s "$record" ]

  local captured
  captured="$(cat "$record")"
  [[ "$captured" == *"-p"* ]]
  [[ "$captured" == *"--force"* ]]
  [[ "$captured" == *"cursor-smoke-prompt"* ]]
}

@test "cursor refuses subagents on before native argv" {
  local record="$TEST_TMPDIR/cursor-subagents.args"
  run_plan_invoke_test_write_stub "cursor-agent" "$record"
  export RALPH_PLAN_SUBAGENTS=on
  run ralph_run_plan_invoke_cursor
  [ "$status" -ne 0 ]
  [[ "$output" == *"nativeSubagents=on was removed"* ]]
  [ ! -e "$record" ]
}

@test "cursor refuses nativeSubagents off before native argv" {
  local record="$TEST_TMPDIR/cursor-subagents-off.args"
  : >"$record"
  run_plan_invoke_test_write_stub "cursor-agent" "$record"
  export RALPH_PLAN_NATIVE_SUBAGENTS=off
  export PROMPT="cursor-subagents-off"
  export RALPH_MODE=native
  run ralph_run_plan_invoke_cursor
  [ "$status" -ne 0 ]
  [[ "$output" == *"nativeSubagents=off"* ]]
  [[ "$output" == *"unsupported for runtime cursor"* ]]
  ! grep -Fxq -- "-p" "$record"
}

@test "cursor invoke ignores portable-profile model context config" {
  local record="$TEST_TMPDIR/cursor-no-profile.args"
  run_plan_invoke_test_write_stub "cursor-agent" "$record"

  # Legacy portable-profile fields must not become Cursor argv/config.
  # Model comes only from SELECTED_MODEL (prior TODOs); unset => native default.
  export PREBUILT_AGENT=implementation
  export PREBUILT_AGENT_CONTEXT=$'## profile context\nmust-not-appear-in-argv'
  export RALPH_AGENT_MAX_BUDGET=7.25
  export RALPH_AGENT_NATIVE_NAME=implementation
  export RALPH_AGENT_NATIVE_PASSTHROUGH=1
  export PROMPT="cursor-primary-default-turn"
  export RALPH_MODE=native

  run ralph_run_plan_invoke_cursor
  [ "$status" -eq 0 ]
  [ -s "$record" ]

  ! grep -Fxq -- "--agent" "$record"
  ! grep -Fxq -- "--model" "$record"
  ! grep -Fxq -- "--max-budget-usd" "$record"
  ! grep -Fxq -- "implementation" "$record"
  ! grep -Fq -- "must-not-appear-in-argv" "$record"
  grep -Fxq -- "-p" "$record"
  grep -Fxq -- "--force" "$record"
  grep -Fxq -- "cursor-primary-default-turn" "$record"
}

@test "cursor invoke honors SELECTED_MODEL without profile reads" {
  local record="$TEST_TMPDIR/cursor-selected-model.args"
  run_plan_invoke_test_write_stub "cursor-agent" "$record"

  export PREBUILT_AGENT=implementation
  export SELECTED_MODEL="cursor-resolved-model"
  export PROMPT="cursor-model-turn"
  export RALPH_MODE=native

  run ralph_run_plan_invoke_cursor
  [ "$status" -eq 0 ]
  grep -Fxq -- "--model" "$record"
  grep -Fxq -- "cursor-resolved-model" "$record"
  ! grep -Fxq -- "--agent" "$record"
  ! grep -Fxq -- "implementation" "$record"
}
