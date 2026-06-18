#!/usr/bin/env bats
# shellcheck shell=bash

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-env.sh"
}

teardown() {
  unset ANTIGRAVITY_PLAN_VERBOSE ANTIGRAVITY_PLAN_NO_COLOR ANTIGRAVITY_PLAN_MAX_ITER
  unset ANTIGRAVITY_PLAN_GUTTER_ITER ANTIGRAVITY_PLAN_PROGRESS_INTERVAL
  unset ANTIGRAVITY_PLAN_DISABLE_HUMAN_PROMPT ANTIGRAVITY_PLAN_NO_OPEN
  unset OPENCODE_PLAN_DISABLE_HUMAN_PROMPT OPENCODE_PLAN_NO_OPEN
  unset CURSOR_PLAN_DISABLE_HUMAN_PROMPT CURSOR_PLAN_NO_OPEN
  unset RALPH_PLAN_VERBOSE RALPH_PLAN_NO_COLOR RALPH_PLAN_MAX_ITERATIONS
  unset RALPH_PLAN_GUTTER_ITERATIONS RALPH_PLAN_PROGRESS_INTERVAL
  unset RALPH_PLAN_DISABLE_HUMAN_PROMPT RALPH_PLAN_NO_OPEN
}

@test "antigravity env populates shared RALPH knobs from ANTIGRAVITY_PLAN_*" {
  export ANTIGRAVITY_PLAN_VERBOSE=1
  export ANTIGRAVITY_PLAN_NO_COLOR=1
  export ANTIGRAVITY_PLAN_MAX_ITER=42
  export ANTIGRAVITY_PLAN_GUTTER_ITER=7
  export ANTIGRAVITY_PLAN_PROGRESS_INTERVAL=15
  export ANTIGRAVITY_PLAN_DISABLE_HUMAN_PROMPT=1
  export ANTIGRAVITY_PLAN_NO_OPEN=1

  ralph_run_plan_load_env_for_runtime antigravity

  [ "$RALPH_PLAN_VERBOSE" = "1" ]
  [ "$RALPH_PLAN_NO_COLOR" = "1" ]
  [ "$RALPH_PLAN_MAX_ITERATIONS" = "42" ]
  [ "$RALPH_PLAN_GUTTER_ITERATIONS" = "7" ]
  [ "$RALPH_PLAN_PROGRESS_INTERVAL" = "15" ]
  [ "$RALPH_PLAN_DISABLE_HUMAN_PROMPT" = "1" ]
  [ "$RALPH_PLAN_NO_OPEN" = "1" ]
}

@test "antigravity precedence prefers ANTIGRAVITY human flags over OPENCODE" {
  export ANTIGRAVITY_PLAN_DISABLE_HUMAN_PROMPT=1
  export ANTIGRAVITY_PLAN_NO_OPEN=1
  export OPENCODE_PLAN_DISABLE_HUMAN_PROMPT=0
  export OPENCODE_PLAN_NO_OPEN=0
  export CURSOR_PLAN_DISABLE_HUMAN_PROMPT=0
  export CURSOR_PLAN_NO_OPEN=0

  ralph_run_plan_load_env_for_runtime antigravity

  [ "$RALPH_PLAN_DISABLE_HUMAN_PROMPT" = "1" ]
  [ "$RALPH_PLAN_NO_OPEN" = "1" ]
}

@test "antigravity env falls back through opencode chain when ANTIGRAVITY unset" {
  export OPENCODE_PLAN_VERBOSE=1
  export OPENCODE_PLAN_MAX_ITER=88
  unset ANTIGRAVITY_PLAN_VERBOSE ANTIGRAVITY_PLAN_MAX_ITER

  ralph_run_plan_load_env_for_runtime antigravity

  [ "$RALPH_PLAN_VERBOSE" = "1" ]
  [ "$RALPH_PLAN_MAX_ITERATIONS" = "88" ]
}

@test "unsupported runtime fails env validation" {
  run ralph_run_plan_load_env_for_runtime bogus-runtime
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unsupported runtime: bogus-runtime"* ]]
}
