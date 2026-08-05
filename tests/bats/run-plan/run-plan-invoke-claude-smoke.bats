#!/usr/bin/env bats
# shellcheck shell=bash

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
# shellcheck disable=SC1090
source "$BATS_TEST_DIRNAME/run-plan-invoke-test-helper.bash"

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-claude.sh"
  run_plan_invoke_test_setup_common
}

teardown() {
  run_plan_invoke_test_teardown_common
}

@test "claude invoke helper dispatches the stubbed CLI" {
  local record="$TEST_TMPDIR/claude.args"
  local stdin_capture="$TEST_TMPDIR/claude.stdin"
  run_plan_invoke_test_write_stub "claude" "$record" "$stdin_capture"

  export PROMPT="claude-smoke-prompt"
  export RALPH_MODE=native

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  [ -s "$record" ]
  [ "$(cat "$stdin_capture")" = "claude-smoke-prompt" ]
}

@test "claude invoke helper does not impose a default budget cap" {
  local record="$TEST_TMPDIR/claude-no-budget.args"
  run_plan_invoke_test_write_stub "claude" "$record"

  export PREBUILT_AGENT=implementation
  export PROMPT="large implementation"
  export RALPH_MODE=native

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  ! grep -Fxq -- "--max-budget-usd" "$record"
}

@test "claude invoke helper honors an explicit global budget cap" {
  local record="$TEST_TMPDIR/claude-global-budget.args"
  run_plan_invoke_test_write_stub "claude" "$record"

  export RALPH_CLAUDE_MAX_BUDGET_USD=12.50
  export PROMPT="budgeted implementation"
  export RALPH_MODE=native

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  grep -Fxq -- "--max-budget-usd" "$record"
  grep -Fxq -- "12.50" "$record"
}

@test "claude invoke helper honors an explicit agent budget cap" {
  local record="$TEST_TMPDIR/claude-agent-budget.args"
  run_plan_invoke_test_write_stub "claude" "$record"

  export RALPH_AGENT_MAX_BUDGET=7.25
  export PROMPT="agent-budgeted implementation"
  export RALPH_MODE=native

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  grep -Fxq -- "--max-budget-usd" "$record"
  grep -Fxq -- "7.25" "$record"
}
