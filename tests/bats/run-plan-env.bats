# shellcheck shell=bash
#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan-env.sh"
}

teardown() {
  unset CURSOR_PLAN_DISABLE_HUMAN_PROMPT
  unset CURSOR_PLAN_NO_OPEN
  unset CLAUDE_PLAN_DISABLE_HUMAN_PROMPT
  unset CLAUDE_PLAN_NO_OPEN
  unset RALPH_PLAN_DISABLE_HUMAN_PROMPT
  unset RALPH_PLAN_NO_OPEN
}

@test "cursor fallback populates RALPH human flags from CURSOR env" {
  export CURSOR_PLAN_DISABLE_HUMAN_PROMPT=1
  export CURSOR_PLAN_NO_OPEN=1

  ralph_run_plan_load_env_for_runtime cursor

  [ "$RALPH_PLAN_DISABLE_HUMAN_PROMPT" = "1" ]
  [ "$RALPH_PLAN_NO_OPEN" = "1" ]
}

@test "claude precedence respects CLAUDE human flags over CURSOR" {
  export CLAUDE_PLAN_DISABLE_HUMAN_PROMPT=1
  export CLAUDE_PLAN_NO_OPEN=1
  export CURSOR_PLAN_DISABLE_HUMAN_PROMPT=0
  export CURSOR_PLAN_NO_OPEN=0

  ralph_run_plan_load_env_for_runtime claude

  [ "$RALPH_PLAN_DISABLE_HUMAN_PROMPT" = "1" ]
  [ "$RALPH_PLAN_NO_OPEN" = "1" ]
}
