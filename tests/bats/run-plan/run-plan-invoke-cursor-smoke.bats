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

