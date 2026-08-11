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

@test "codex refuses subagents on before native argv" {
  local record="$TEST_TMPDIR/codex-subagents.args"
  run_plan_invoke_test_write_codex_stub "$record"
  export RALPH_PLAN_SUBAGENTS=on
  run ralph_run_plan_invoke_codex
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported for runtime codex"* ]]
  [ ! -e "$record" ]
}

@test "codex accepts the portable off contract" {
  local record="$TEST_TMPDIR/codex-delegated-child.args"
  run_plan_invoke_test_write_codex_stub "$record"
  export PROMPT="codex-delegated-child-prompt"
  export RALPH_MODE=native
  export RALPH_PLAN_SUBAGENTS=off
  export CODEX_PLAN_NO_ADD_AGENTS_DIR=1

  run ralph_run_plan_invoke_codex
  [ "$status" -eq 0 ]
  [ -s "$record" ]
}

@test "codex grants an external state root without creating a shadow workspace root" {
  local record="$TEST_TMPDIR/codex-external-state.args"
  local state_root="$TEST_TMPDIR/external-state"
  run_plan_invoke_test_write_codex_stub "$record"
  mkdir -p "$state_root"
  export PROMPT="codex-external-state"
  export RALPH_MODE=native
  export RALPH_PLAN_WORKSPACE_ROOT="$state_root"

  run ralph_run_plan_invoke_codex
  [ "$status" -eq 0 ]
  [[ "$(cat "$record")" == *"--add-dir"*"$state_root"* ]]
  [ ! -d "$WORKSPACE/.ralph-workspace" ]
}


# Regression: Codex refuses to start outside a git repo unless
# --skip-git-repo-check is passed. Ralph workspaces are often a parent dir
# holding several sibling repos (a lib, an API, client apps), which is not a
# repo itself. The runner must auto-add the flag so runs are not blocked with
# "Not inside a trusted directory and --skip-git-repo-check was not specified."
@test "codex auto-adds --skip-git-repo-check when workspace is not a git repo" {
  local record="$TEST_TMPDIR/codex.args"
  run_plan_invoke_test_write_codex_stub "$record"

  # WORKSPACE (from the shared setup) is a plain dir, not a git work tree.
  export PROMPT="codex-nogit-prompt"
  export RALPH_MODE=native
  export CODEX_PLAN_NO_ADD_AGENTS_DIR=1

  run ralph_run_plan_invoke_codex
  [ "$status" -eq 0 ]
  [[ "$(cat "$record")" == *"--skip-git-repo-check"* ]]
}

@test "codex omits --skip-git-repo-check when workspace is a git repo" {
  local record="$TEST_TMPDIR/codex.args"
  run_plan_invoke_test_write_codex_stub "$record"

  git -C "$WORKSPACE" init -q

  export PROMPT="codex-git-prompt"
  export RALPH_MODE=native
  export CODEX_PLAN_NO_ADD_AGENTS_DIR=1

  run ralph_run_plan_invoke_codex
  [ "$status" -eq 0 ]
  [[ "$(cat "$record")" != *"--skip-git-repo-check"* ]]
}

@test "CODEX_PLAN_SKIP_GIT_REPO_CHECK=1 forces the flag inside a git repo" {
  local record="$TEST_TMPDIR/codex.args"
  run_plan_invoke_test_write_codex_stub "$record"

  git -C "$WORKSPACE" init -q

  export PROMPT="codex-force-prompt"
  export RALPH_MODE=native
  export CODEX_PLAN_NO_ADD_AGENTS_DIR=1
  export CODEX_PLAN_SKIP_GIT_REPO_CHECK=1

  run ralph_run_plan_invoke_codex
  [ "$status" -eq 0 ]
  [[ "$(cat "$record")" == *"--skip-git-repo-check"* ]]
}

@test "CODEX_PLAN_SKIP_GIT_REPO_CHECK=0 forces the flag off outside a git repo" {
  local record="$TEST_TMPDIR/codex.args"
  run_plan_invoke_test_write_codex_stub "$record"

  export PROMPT="codex-forceoff-prompt"
  export RALPH_MODE=native
  export CODEX_PLAN_NO_ADD_AGENTS_DIR=1
  export CODEX_PLAN_SKIP_GIT_REPO_CHECK=0

  run ralph_run_plan_invoke_codex
  [ "$status" -eq 0 ]
  [[ "$(cat "$record")" != *"--skip-git-repo-check"* ]]
}

@test "CODEX_PLAN_EXTRA_ADD_DIRS grants extra repos via --add-dir" {
  local record="$TEST_TMPDIR/codex.args"
  run_plan_invoke_test_write_codex_stub "$record"

  mkdir -p "$TEST_TMPDIR/repo-lib" "$TEST_TMPDIR/repo-api"

  export PROMPT="codex-adddirs-prompt"
  export RALPH_MODE=native
  export CODEX_PLAN_NO_ADD_AGENTS_DIR=1
  export CODEX_PLAN_EXTRA_ADD_DIRS="$TEST_TMPDIR/repo-lib,$TEST_TMPDIR/repo-api"

  run ralph_run_plan_invoke_codex
  [ "$status" -eq 0 ]
  local captured
  captured="$(cat "$record")"
  [[ "$captured" == *"$TEST_TMPDIR/repo-lib"* ]]
  [[ "$captured" == *"$TEST_TMPDIR/repo-api"* ]]
}
