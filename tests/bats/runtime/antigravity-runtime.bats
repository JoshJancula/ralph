#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-resolve.sh"

SETUP_RUNTIME_SH="$REPO_ROOT/bundle/.ralph/setup-runtime.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  WORKSPACE_DIR="$TEST_TMPDIR/workspace"
  HOME_DIR="$TEST_TMPDIR/home"
  RALPH_HOME_DIR="$TEST_TMPDIR/ralph-home"
  unset RALPH_HOME RALPH_GLOBAL_RUNTIME_HOME RALPH_DISABLE_GLOBAL_FALLBACK
  mkdir -p "$WORKSPACE_DIR" "$HOME_DIR" "$RALPH_HOME_DIR/bundle"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

@test "runtime resolver prefers project antigravity root" {
  mkdir -p "$WORKSPACE_DIR/.agents" "$HOME_DIR/.agents" "$RALPH_HOME_DIR/bundle/.agents"

  run env HOME="$HOME_DIR" RALPH_HOME="$RALPH_HOME_DIR" bash -c '
    source "$1"
    ralph_resolve_runtime_root antigravity "$2"
  ' _ "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-resolve.sh" "$WORKSPACE_DIR"

  [ "$status" -eq 0 ]
  [ "$output" = "$WORKSPACE_DIR/.agents" ]
}

@test "runtime resolver accepts agy alias for antigravity root" {
  mkdir -p "$WORKSPACE_DIR/.agents"

  run env HOME="$HOME_DIR" RALPH_HOME="$RALPH_HOME_DIR" bash -c '
    source "$1"
    ralph_resolve_runtime_root agy "$2"
  ' _ "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-resolve.sh" "$WORKSPACE_DIR"

  [ "$status" -eq 0 ]
  [ "$output" = "$WORKSPACE_DIR/.agents" ]
}

@test "runtime resolver falls back to bundled antigravity root" {
  mkdir -p "$RALPH_HOME_DIR/bundle/.agents"

  run env HOME="$HOME_DIR" RALPH_HOME="$RALPH_HOME_DIR" bash -c '
    source "$1"
    ralph_resolve_runtime_root antigravity "$2"
  ' _ "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-resolve.sh" "$WORKSPACE_DIR"

  [ "$status" -eq 0 ]
  [ "$output" = "$RALPH_HOME_DIR/bundle/.agents" ]
}

@test "select-model resolver falls back to bundle antigravity helper" {
  run env -i PATH="$PATH" HOME="$HOME_DIR" RALPH_HOME="$RALPH_HOME_DIR" bash --noprofile --norc -c '
    source "$1"
    ralph_select_model_script antigravity "$2" "$3"
  ' _ "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-resolve.sh" "$WORKSPACE_DIR" "$REPO_ROOT/bundle/.ralph"

  [ "$status" -eq 0 ]
  [ "$output" = "$REPO_ROOT/bundle/.ralph/bash-lib/select-model/select-model-antigravity.sh" ]
}

@test "setup-runtime.sh accepts antigravity with --hooks dry-run" {
  [ -f "$SETUP_RUNTIME_SH" ] || skip "setup-runtime.sh missing"

  local temp_dir
  temp_dir="$(mktemp -d)"
  mkdir -p "$temp_dir/.agents"

  run bash "$SETUP_RUNTIME_SH" --runtime antigravity --runtime-dir "$temp_dir/.agents" --hooks --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Setting up antigravity runtime"* ]]
  [[ "$output" == *"hooks"* ]]
  [[ "$output" == *"DRY-RUN"* ]]

  rm -rf "$temp_dir"
}

@test "setup-runtime.sh accepts agy shorthand with --hooks dry-run" {
  [ -f "$SETUP_RUNTIME_SH" ] || skip "setup-runtime.sh missing"

  local temp_dir
  temp_dir="$(mktemp -d)"
  mkdir -p "$temp_dir/.agents"

  run bash "$SETUP_RUNTIME_SH" --runtime agy --runtime-dir "$temp_dir/.agents" --hooks --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Setting up antigravity runtime"* ]]
  [[ "$output" == *"hooks"* ]]
  [[ "$output" == *"DRY-RUN"* ]]

  rm -rf "$temp_dir"
}

@test "setup-runtime.sh accepts antigravity with --mcp dry-run" {
  [ -f "$SETUP_RUNTIME_SH" ] || skip "setup-runtime.sh missing"

  local temp_dir
  temp_dir="$(mktemp -d)"
  mkdir -p "$temp_dir/.agents"

  run bash "$SETUP_RUNTIME_SH" --runtime antigravity --runtime-dir "$temp_dir/.agents" --mcp --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Setting up antigravity runtime"* ]]
  [[ "$output" == *"mcp"* ]]
  [[ "$output" == *"DRY-RUN"* ]]

  rm -rf "$temp_dir"
}
