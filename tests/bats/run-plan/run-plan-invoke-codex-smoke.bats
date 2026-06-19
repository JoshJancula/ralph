#!/usr/bin/env bats
# shellcheck shell=bash

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
# shellcheck disable=SC1090
source "$BATS_TEST_DIRNAME/run-plan-invoke-test-helper.bash"

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-codex.sh"
  run_plan_invoke_test_setup_common
}

teardown() {
  run_plan_invoke_test_teardown_common
}

@test "codex invoke helper dispatches the stubbed CLI" {
  local record="$TEST_TMPDIR/codex.args"
  run_plan_invoke_test_write_codex_stub "$record"

  export PROMPT="codex-smoke-prompt"
  export RALPH_MODE=native
  export CODEX_PLAN_NO_ADD_AGENTS_DIR=1

  run ralph_run_plan_invoke_codex
  [ "$status" -eq 0 ]
  [ -s "$record" ]

  local captured
  captured="$(cat "$record")"
  [[ "$captured" == *"exec"* ]]
  [[ "$captured" == *"codex-smoke-prompt"* ]]
}

