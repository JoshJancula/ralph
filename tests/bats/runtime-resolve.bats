#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"
source "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-resolve.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  WORKSPACE_DIR="$TEST_TMPDIR/workspace"
  HOME_DIR="$TEST_TMPDIR/home"
  RALPH_HOME_DIR="$TEST_TMPDIR/ralph-home"
  mkdir -p "$WORKSPACE_DIR" "$HOME_DIR" "$RALPH_HOME_DIR/bundle"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

@test "runtime resolver prefers project runtime root" {
  mkdir -p "$WORKSPACE_DIR/.claude" "$HOME_DIR/.claude" "$RALPH_HOME_DIR/bundle/.claude"

  run env HOME="$HOME_DIR" RALPH_HOME="$RALPH_HOME_DIR" bash -c '
    source "$1"
    ralph_resolve_runtime_root claude "$2"
  ' _ "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-resolve.sh" "$WORKSPACE_DIR"

  [ "$status" -eq 0 ]
  [ "$output" = "$WORKSPACE_DIR/.claude" ]
}

@test "runtime resolver falls back to user runtime root" {
  mkdir -p "$HOME_DIR/.codex" "$RALPH_HOME_DIR/bundle/.codex"

  run env HOME="$HOME_DIR" RALPH_HOME="$RALPH_HOME_DIR" bash -c '
    source "$1"
    ralph_resolve_runtime_root codex "$2"
  ' _ "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-resolve.sh" "$WORKSPACE_DIR"

  [ "$status" -eq 0 ]
  [ "$output" = "$HOME_DIR/.codex" ]
}

@test "runtime resolver falls back to bundled runtime root" {
  mkdir -p "$RALPH_HOME_DIR/bundle/.opencode"

  run env HOME="$HOME_DIR" RALPH_HOME="$RALPH_HOME_DIR" bash -c '
    source "$1"
    ralph_resolve_runtime_root opencode "$2"
  ' _ "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-resolve.sh" "$WORKSPACE_DIR"

  [ "$status" -eq 0 ]
  [ "$output" = "$RALPH_HOME_DIR/bundle/.opencode" ]
}

@test "runtime resolver honors RALPH_GLOBAL_RUNTIME_HOME" {
  global_runtime_home="$TEST_TMPDIR/global-runtime-home"
  mkdir -p "$global_runtime_home/.cursor"

  run env HOME="$HOME_DIR" RALPH_GLOBAL_RUNTIME_HOME="$global_runtime_home" bash -c '
    source "$1"
    ralph_resolve_runtime_root cursor "$2"
  ' _ "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-resolve.sh" "$WORKSPACE_DIR"

  [ "$status" -eq 0 ]
  [ "$output" = "$global_runtime_home/.cursor" ]
}

@test "runtime resolver disables global fallback when requested" {
  mkdir -p "$HOME_DIR/.claude" "$RALPH_HOME_DIR/bundle/.claude"

  run env HOME="$HOME_DIR" RALPH_HOME="$RALPH_HOME_DIR" RALPH_DISABLE_GLOBAL_FALLBACK=1 bash -c '
    source "$1"
    ralph_resolve_runtime_root claude "$2"
  ' _ "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-resolve.sh" "$WORKSPACE_DIR"

  [ "$status" -ne 0 ]
  [ "$output" = "" ]
}

@test "runtime resolver returns error when no runtime root present" {
  run env HOME="$HOME_DIR" RALPH_HOME="$RALPH_HOME_DIR" bash -c '
    source "$1"
    ralph_resolve_runtime_root cursor "$2"
  ' _ "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-resolve.sh" "$WORKSPACE_DIR"

  [ "$status" -ne 0 ]
  [ "$output" = "" ]
}
