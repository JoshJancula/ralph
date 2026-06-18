#!/usr/bin/env bats
# Test suite for setup-runtime.sh CLI argument parsing.
#
# This suite covers:
# - Basic CLI parsing for flags like --runtime, --runtime-dir, --hooks, --mcp, --all, --dry-run, --yes
# - Validation of runtime values
# - Required action validation (--hooks, --mcp, or --all)
# - Runtime-dir basename validation
# - Dry-run behavior (no actual writes)

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

SETUP_RUNTIME_SH="$REPO_ROOT/bundle/.ralph/setup-runtime.sh"

@test "setup-runtime.sh --help shows usage" {
  [ -f "$SETUP_RUNTIME_SH" ] || skip "setup-runtime.sh missing"

  run bash "$SETUP_RUNTIME_SH" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]] || [[ "$output" == *"--runtime"* ]]
  [[ "$output" == *"--hooks"* ]]
  [[ "$output" == *"--mcp"* ]]
  [[ "$output" == *"--all"* ]]
  [[ "$output" == *"--dry-run"* ]]
  [[ "$output" == *"--yes"* ]]
}

@test "setup-runtime.sh with no args shows error" {
  [ -f "$SETUP_RUNTIME_SH" ] || skip "setup-runtime.sh missing"

  run bash "$SETUP_RUNTIME_SH" 2>&1
  [ "$status" -ne 0 ]
}

@test "setup-runtime.sh --runtime requires an argument" {
  [ -f "$SETUP_RUNTIME_SH" ] || skip "setup-runtime.sh missing"

  run bash "$SETUP_RUNTIME_SH" --runtime 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"--runtime requires an argument"* ]] || [[ "$output" == *"--runtime"* ]]
}

@test "setup-runtime.sh rejects invalid runtime" {
  [ -f "$SETUP_RUNTIME_SH" ] || skip "setup-runtime.sh missing"

  run bash "$SETUP_RUNTIME_SH" --runtime invalid-runtime --hooks 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid runtime"* ]]
  [[ "$output" == *"invalid-runtime"* ]]
}

@test "setup-runtime.sh rejects missing action (no --hooks, --mcp, or --all)" {
  [ -f "$SETUP_RUNTIME_SH" ] || skip "setup-runtime.sh missing"

  run bash "$SETUP_RUNTIME_SH" --runtime claude 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"at least one of --hooks, --mcp, or --all"* ]] || [[ "$output" == *"At least one"* ]]
}

@test "setup-runtime.sh accepts valid runtime with --hooks" {
  [ -f "$SETUP_RUNTIME_SH" ] || skip "setup-runtime.sh missing"

  for runtime in claude cursor codex opencode agy; do
    run bash "$SETUP_RUNTIME_SH" --runtime "$runtime" --hooks --dry-run
    [ "$status" -eq 0 ]
    if [[ "$runtime" == "agy" ]]; then
      [[ "$output" == *"Setting up antigravity runtime"* ]]
    else
      [[ "$output" == *"Setting up $runtime runtime"* ]]
    fi
    [[ "$output" == *"hooks"* ]]
    [[ "$output" == *"DRY-RUN"* ]]
  done
}

@test "setup-runtime.sh accepts valid runtime with --mcp" {
  [ -f "$SETUP_RUNTIME_SH" ] || skip "setup-runtime.sh missing"

  for runtime in claude cursor codex opencode agy; do
    run bash "$SETUP_RUNTIME_SH" --runtime "$runtime" --mcp --dry-run
    [ "$status" -eq 0 ]
    if [[ "$runtime" == "agy" ]]; then
      [[ "$output" == *"Setting up antigravity runtime"* ]]
    else
      [[ "$output" == *"Setting up $runtime runtime"* ]]
    fi
    [[ "$output" == *"mcp"* ]]
    [[ "$output" == *"DRY-RUN"* ]]
  done
}

@test "setup-runtime.sh accepts valid runtime with --all" {
  [ -f "$SETUP_RUNTIME_SH" ] || skip "setup-runtime.sh missing"

  for runtime in claude cursor codex opencode agy; do
    run bash "$SETUP_RUNTIME_SH" --runtime "$runtime" --all --dry-run
    [ "$status" -eq 0 ]
    if [[ "$runtime" == "agy" ]]; then
      [[ "$output" == *"Setting up antigravity runtime"* ]]
    else
      [[ "$output" == *"Setting up $runtime runtime"* ]]
    fi
    [[ "$output" == *"hooks"* ]]
    [[ "$output" == *"mcp"* ]]
    [[ "$output" == *"DRY-RUN"* ]]
  done
}

@test "setup-runtime.sh --all is equivalent to --hooks --mcp" {
  [ -f "$SETUP_RUNTIME_SH" ] || skip "setup-runtime.sh missing"

  # Test with --all
  run bash "$SETUP_RUNTIME_SH" --runtime claude --all --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"hooks"* ]]
  [[ "$output" == *"mcp"* ]]

  # Test with --hooks --mcp
  run bash "$SETUP_RUNTIME_SH" --runtime claude --hooks --mcp --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"hooks"* ]]
  [[ "$output" == *"mcp"* ]]
}

@test "setup-runtime.sh uses default runtime-dir" {
  [ -f "$SETUP_RUNTIME_SH" ] || skip "setup-runtime.sh missing"

  cd "$(mktemp -d)"
  run bash "$SETUP_RUNTIME_SH" --runtime claude --hooks --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Runtime directory:"*".claude"* ]]
}

@test "setup-runtime.sh accepts explicit runtime-dir" {
  [ -f "$SETUP_RUNTIME_SH" ] || skip "setup-runtime.sh missing"

  local temp_dir
  temp_dir="$(mktemp -d)"
  mkdir -p "$temp_dir/.claude"

  run bash "$SETUP_RUNTIME_SH" --runtime claude --runtime-dir "$temp_dir/.claude" --hooks --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Runtime directory: $temp_dir/.claude"* ]]
}

@test "setup-runtime.sh rejects runtime-dir with mismatched basename" {
  [ -f "$SETUP_RUNTIME_SH" ] || skip "setup-runtime.sh missing"

  local temp_dir
  temp_dir="$(mktemp -d)"
  mkdir -p "$temp_dir/.cursor"

  # Try to use .cursor dir for claude runtime (should fail without --yes)
  run bash "$SETUP_RUNTIME_SH" --runtime claude --runtime-dir "$temp_dir/.cursor" --hooks 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not match runtime"* ]] || [[ "$output" == *".cursor"* ]]
}

@test "setup-runtime.sh accepts mismatched runtime-dir with --yes" {
  [ -f "$SETUP_RUNTIME_SH" ] || skip "setup-runtime.sh missing"

  local temp_dir
  temp_dir="$(mktemp -d)"
  mkdir -p "$temp_dir/.cursor"

  # With --yes flag, it should accept the mismatched dir
  run bash "$SETUP_RUNTIME_SH" --runtime claude --runtime-dir "$temp_dir/.cursor" --hooks --yes --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Runtime directory: $temp_dir/.cursor"* ]]
}

@test "setup-runtime.sh --dry-run makes no actual changes" {
  [ -f "$SETUP_RUNTIME_SH" ] || skip "setup-runtime.sh missing"

  local temp_dir
  temp_dir="$(mktemp -d)"
  mkdir -p "$temp_dir/.claude"

  # Capture initial state
  local initial_ls
  initial_ls="$(ls -la "$temp_dir/.claude" 2>/dev/null || echo "empty")"

  run bash "$SETUP_RUNTIME_SH" --runtime claude --runtime-dir "$temp_dir/.claude" --all --dry-run
  [ "$status" -eq 0 ]

  # Verify directory is still empty (no files were created)
  local final_ls
  final_ls="$(ls -la "$temp_dir/.claude" 2>/dev/null || echo "empty")"
  [ "$initial_ls" = "$final_ls" ]
}

@test "setup-runtime.sh --runtime-dir requires an argument" {
  [ -f "$SETUP_RUNTIME_SH" ] || skip "setup-runtime.sh missing"

  run bash "$SETUP_RUNTIME_SH" --runtime claude --runtime-dir --hooks 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"--runtime-dir requires an argument"* ]] || [[ "$output" == *"--runtime-dir"* ]]
}

@test "setup-runtime.sh rejects unknown arguments" {
  [ -f "$SETUP_RUNTIME_SH" ] || skip "setup-runtime.sh missing"

  run bash "$SETUP_RUNTIME_SH" --runtime claude --hooks --unknown-flag 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown argument"* ]]
}

@test "setup-runtime.sh resolves relative runtime-dir to absolute path" {
  [ -f "$SETUP_RUNTIME_SH" ] || skip "setup-runtime.sh missing"

  local temp_dir
  temp_dir="$(mktemp -d)"
  mkdir -p "$temp_dir/subdir/.claude"

  cd "$temp_dir"
  run bash "$SETUP_RUNTIME_SH" --runtime claude --runtime-dir "subdir/.claude" --hooks --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Runtime directory:"*"$temp_dir/subdir/.claude"* ]]
}

@test "setup-runtime.sh infers project root from runtime-dir" {
  [ -f "$SETUP_RUNTIME_SH" ] || skip "setup-runtime.sh missing"

  local temp_dir
  temp_dir="$(mktemp -d)"
  mkdir -p "$temp_dir/.claude"

  run bash "$SETUP_RUNTIME_SH" --runtime claude --runtime-dir "$temp_dir/.claude" --hooks --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Project root: $temp_dir"* ]]
}

@test "setup-runtime.sh all valid runtimes accepted" {
  [ -f "$SETUP_RUNTIME_SH" ] || skip "setup-runtime.sh missing"

  local temp_dir
  temp_dir="$(mktemp -d)"

  for runtime in claude cursor codex opencode antigravity agy; do
    local runtime_dir="$temp_dir/.$runtime"
    local cli_runtime="$runtime"
    if [[ "$runtime" == "agy" || "$runtime" == "antigravity" ]]; then
      runtime_dir="$temp_dir/.agents"
      cli_runtime="$runtime"
    fi
    mkdir -p "$runtime_dir"
    run bash "$SETUP_RUNTIME_SH" --runtime "$cli_runtime" --runtime-dir "$runtime_dir" --all --dry-run
    [ "$status" -eq 0 ]
    if [[ "$runtime" == "agy" || "$runtime" == "antigravity" ]]; then
      [[ "$output" == *"Setting up antigravity runtime"* ]]
      rm -rf "$temp_dir/.agents"
    else
      [[ "$output" == *"Setting up $runtime runtime"* ]]
      rm -rf "$runtime_dir"
    fi
  done
}
