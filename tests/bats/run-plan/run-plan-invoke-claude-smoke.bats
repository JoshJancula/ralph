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
  grep -Fxq -- "--append-system-prompt" "$record"
  ! grep -Fxq -- "--system-prompt" "$record"
  grep -Fxq -- "stable-preamble" "$record"
  grep -Fxq -- "Bash,Read,Edit,Write" "$record"
}

@test "claude preserves skills and native context across every tooling mode and continuation" {
  local mode turn record
  for mode in no native ralph hybrid; do
    for turn in fresh resume reset; do
      record="$TEST_TMPDIR/$mode-$turn.args"
      run_plan_invoke_test_write_claude_stub "$record"
      export RALPH_MODE="$mode" PROMPT="use the operator skill" PROMPT_STATIC="Ralph instructions"
      unset RALPH_RUN_PLAN_RESUME_SESSION_ID RALPH_RUN_PLAN_RESET_COMMAND_USED
      case "$turn" in
        resume) export RALPH_RUN_PLAN_RESUME_SESSION_ID=operator-session ;;
        reset) export RALPH_RUN_PLAN_RESET_COMMAND_USED=1 ;;
      esac

      run ralph_run_plan_invoke_claude
      [ "$status" -eq 0 ]
      ! grep -Fxq -- "--bare" "$record"
      ! grep -Fxq -- "--disable-slash-commands" "$record"
      ! grep -Fxq -- "--tools" "$record"
      ! grep -Fxq -- "--strict-mcp-config" "$record"
      ! grep -Fxq -- "--system-prompt" "$record"
      grep -Fxq -- "--append-system-prompt" "$record"
      grep -Fxq -- "user,project,local" "$record"
    done
  done
}

@test "claude keeps permission allowlists separate from explicit tool restrictions" {
  local record="$TEST_TMPDIR/explicit-tools.args"
  run_plan_invoke_test_write_claude_stub "$record"
  export RALPH_MODE=native CLAUDE_PLAN_ALLOWED_TOOLS="Read"
  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  ! grep -Fxq -- "--tools" "$record"

  export CLAUDE_PLAN_MINIMAL_TOOLS="Read,Skill"
  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  grep -Fxq -- "--tools" "$record"
  grep -Fxq -- "Read,Skill" "$record"

  # An explicitly empty catalog is also an operator choice.
  local -a args=()
  export CLAUDE_PLAN_MINIMAL_TOOLS=""
  run_plan_invoke_claude_apply_minimal_flags args
  [ "${args[2]}" = "--tools" ]
  [ "${args[3]}" = "" ]
}

@test "claude strict proxy and subagent policies deny only the selected tools" {
  local record="$TEST_TMPDIR/strict-proxy.args"
  run_plan_invoke_test_write_claude_stub "$record"
  export RALPH_MODE=ralph RALPH_MCP_PREFLIGHT_PASSED=1 RALPH_PLAN_SUBAGENTS=off
  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  grep -Fxq -- "--disallowedTools" "$record"
  grep -Fxq -- "Bash" "$record"
  grep -Fxq -- "Agent" "$record"
  ! grep -Fxq -- "Skill" "$record"
  ! grep -Fxq -- "--tools" "$record"
}

@test "claude exposes project rules and skills while retaining the separate agent cwd" {
  export RALPH_AGENT_WORKSPACE="$TEST_TMPDIR/agent checkout"
  export RALPH_PROJECT_ROOT="$WORKSPACE"
  export RALPH_PLAN_WORKSPACE_ROOT="$TEST_TMPDIR/state"
  export RALPH_MODE=native
  mkdir -p "$RALPH_AGENT_WORKSPACE" "$RALPH_PLAN_WORKSPACE_ROOT"
  mkdir -p "$WORKSPACE/.claude"
  printf '%s\n' '{"env":{"OPERATOR_CONTEXT":"present"}}' >"$WORKSPACE/.claude/settings.json"
  local record="$TEST_TMPDIR/roots.args" cwd_record="$TEST_TMPDIR/cwd"
  run_plan_invoke_test_write_live_pid_stub claude "$record" "$TEST_TMPDIR/pid" 0 "" \
    'printf "%s\n" "$PWD" "$CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD" >"'"$cwd_record"'"'
  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"does not load settings or MCP configuration"* ]]
  grep -Fxq -- "--add-dir" "$record"
  grep -Fxq -- "$(cd "$WORKSPACE" && pwd -P)" "$record"
  ! grep -Fxq -- "$RALPH_PLAN_WORKSPACE_ROOT" "$record"
  [ "$(head -1 "$cwd_record")" = "$RALPH_AGENT_WORKSPACE" ]
  [ "$(tail -1 "$cwd_record")" = "1" ]

  export CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=0
  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  [ "$(tail -1 "$cwd_record")" = "0" ]
}
