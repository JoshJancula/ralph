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

@test "claude subagents contract preserves inherit and controls Agent argv" {
  local inherit_record on_record off_record
  inherit_record="$TEST_TMPDIR/inherit.args"
  on_record="$TEST_TMPDIR/on.args"
  off_record="$TEST_TMPDIR/off.args"
  export PROMPT="subagents-contract"
  export RALPH_MODE=native

  run_plan_invoke_test_write_claude_stub "$inherit_record"
  export RALPH_PLAN_SUBAGENTS=inherit
  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  ! grep -Fxq -- "--disallowedTools" "$inherit_record"
  ! grep -Fxq -- "Agent" "$inherit_record"

  # nativeSubagents=on was removed; the contract is inherit|off and `on` must
  # be refused rather than silently widening the allowed-tools list.
  run_plan_invoke_test_write_claude_stub "$on_record"
  export RALPH_PLAN_SUBAGENTS=on
  run ralph_run_plan_invoke_claude
  [ "$status" -ne 0 ]
  [[ "$output" == *"nativeSubagents=on was removed"* ]]

  run_plan_invoke_test_write_claude_stub "$off_record"
  export CLAUDE_PLAN_ALLOWED_TOOLS="Bash,Read,Agent"
  export RALPH_PLAN_SUBAGENTS=off
  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  grep -Fxq -- "--disallowedTools" "$off_record"
  grep -Fxq -- "Agent" "$off_record"
}

@test "claude invoke helper does not impose a default budget cap" {
  local record="$TEST_TMPDIR/claude-no-budget.args"
  run_plan_invoke_test_write_stub "claude" "$record"

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

@test "claude invoke ignores profile-derived budget and native --agent passthrough" {
  local record="$TEST_TMPDIR/claude-no-profile-agent.args"
  run_plan_invoke_test_write_stub "claude" "$record"

  export RALPH_AGENT_MAX_BUDGET=7.25
  export CLAUDE_TOOLS_FROM_AGENT="Bash,Read,Agent"
  export RALPH_AGENT_NATIVE_NAME="test-agent"
  export RALPH_AGENT_NATIVE_PASSTHROUGH=1
  export PROMPT_STATIC="stable-preamble"
  export PROMPT="primary-default-turn"
  export RALPH_MODE=native

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  ! grep -Fxq -- "--max-budget-usd" "$record"
  ! grep -Fxq -- "7.25" "$record"
  ! grep -Fxq -- "--agent" "$record"
  ! grep -Fxq -- "test-agent" "$record"
  grep -Fxq -- "--system-prompt" "$record"
  grep -Fxq -- "stable-preamble" "$record"
  grep -Fxq -- "Bash,Read,Edit,Write" "$record"
}
