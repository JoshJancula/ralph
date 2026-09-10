#!/usr/bin/env bats
# Test suite for setup-runtime.sh CLI argument parsing.
#
# This suite covers:
# - Basic CLI parsing for flags like --runtime, --runtime-dir, --hooks, --mcp, --all, --dry-run, --yes
# - Validation of runtime values
# - Required action validation (--hooks, --mcp, or --all)
# - Runtime-dir basename validation
# - Dry-run behavior (no actual writes)
# - --remove argument combinations, closed stdin, and journal recovery

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
  [[ "$output" == *"--remove"* ]]
  [[ "$output" == *"--dry-run"* ]]
  [[ "$output" == *"--yes"* ]]
  [[ "$output" == *"Does not create or validate Ralph native agent"* ]] || \
    [[ "$output" == *"Native runtime agent directories"* ]]
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

SETUP_JOURNAL_SH="$REPO_ROOT/bundle/.ralph/bash-lib/setup/setup-journal.sh"
SETUP_REMOVE_SH="$REPO_ROOT/bundle/.ralph/bash-lib/setup/setup-remove.sh"

@test "setup-runtime.sh --remove requires exactly one of --hooks, --mcp, or --all" {
  [ -f "$SETUP_RUNTIME_SH" ] || skip "setup-runtime.sh missing"

  local temp_dir marker
  temp_dir="$(mktemp -d)"
  mkdir -p "$temp_dir/.claude"
  marker="$temp_dir/.claude/keep.txt"
  printf 'precious\n' >"$marker"

  run bash "$SETUP_RUNTIME_SH" --runtime claude --runtime-dir "$temp_dir/.claude" --remove --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"exactly one of --hooks, --mcp, or --all"* ]]
  [ "$(cat "$marker")" = "precious" ]
  [ ! -d "$temp_dir/.ralph-workspace/setup-journal" ]
}

@test "setup-runtime.sh --remove rejects --hooks with --mcp before mutation" {
  [ -f "$SETUP_RUNTIME_SH" ] || skip "setup-runtime.sh missing"

  local temp_dir marker
  temp_dir="$(mktemp -d)"
  mkdir -p "$temp_dir/.claude"
  marker="$temp_dir/.claude/keep.txt"
  printf 'precious\n' >"$marker"

  run bash "$SETUP_RUNTIME_SH" --runtime claude --runtime-dir "$temp_dir/.claude" --remove --hooks --mcp --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"exactly one of --hooks, --mcp, or --all"* ]]
  [ "$(cat "$marker")" = "precious" ]
  [ ! -d "$temp_dir/.ralph-workspace/setup-journal" ]
}

@test "setup-runtime.sh --remove rejects --all combined with --hooks before mutation" {
  [ -f "$SETUP_RUNTIME_SH" ] || skip "setup-runtime.sh missing"

  local temp_dir marker
  temp_dir="$(mktemp -d)"
  mkdir -p "$temp_dir/.claude"
  marker="$temp_dir/.claude/keep.txt"
  printf 'precious\n' >"$marker"

  run bash "$SETUP_RUNTIME_SH" --runtime claude --runtime-dir "$temp_dir/.claude" --remove --all --hooks --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"exactly one of --hooks, --mcp, or --all"* ]]
  [ "$(cat "$marker")" = "precious" ]
  [ ! -d "$temp_dir/.ralph-workspace/setup-journal" ]
}

@test "setup-runtime.sh --remove --dry-run prints mutation set and creates no journal" {
  [ -f "$SETUP_RUNTIME_SH" ] || skip "setup-runtime.sh missing"

  local temp_dir
  temp_dir="$(mktemp -d)"
  mkdir -p "$temp_dir/.claude"

  run bash "$SETUP_RUNTIME_SH" --runtime claude --runtime-dir "$temp_dir/.claude" --remove --all --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Removing Ralph setup"* ]]
  [[ "$output" == *"hooks"* ]]
  [[ "$output" == *"mcp"* ]]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"no journal"* ]] || [[ "$output" == *"does not create a setup journal"* ]]
  [ ! -d "$temp_dir/.ralph-workspace/setup-journal" ]
}

@test "setup-runtime.sh --remove without --yes fails on closed stdin before mutation" {
  [ -f "$SETUP_RUNTIME_SH" ] || skip "setup-runtime.sh missing"

  local temp_dir marker
  temp_dir="$(mktemp -d)"
  mkdir -p "$temp_dir/.claude"
  marker="$temp_dir/.claude/keep.txt"
  printf 'precious\n' >"$marker"

  run bash -c 'exec < /dev/null; bash "$@"' _ "$SETUP_RUNTIME_SH" \
    --runtime claude --runtime-dir "$temp_dir/.claude" --remove --hooks
  [ "$status" -ne 0 ]
  [[ "$output" == *"--yes"* ]] || [[ "$output" == *"stdin"* ]] || [[ "$output" == *"terminal"* ]]
  [ "$(cat "$marker")" = "precious" ]
  [ ! -d "$temp_dir/.ralph-workspace/setup-journal" ]
}

@test "setup-runtime.sh --remove --yes succeeds with closed stdin" {
  [ -f "$SETUP_RUNTIME_SH" ] || skip "setup-runtime.sh missing"

  local temp_dir
  temp_dir="$(mktemp -d)"
  mkdir -p "$temp_dir/.claude"

  run bash -c 'exec < /dev/null; bash "$@"' _ "$SETUP_RUNTIME_SH" \
    --runtime claude --runtime-dir "$temp_dir/.claude" --remove --mcp --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"Removing Ralph setup"* ]]
  [[ "$output" == *"mcp"* ]]
}

@test "setup journal recovers journaled writes on failure" {
  [ -f "$SETUP_JOURNAL_SH" ] || skip "setup-journal.sh missing"

  local temp_dir state target
  temp_dir="$(mktemp -d)"
  state="$temp_dir/.ralph-workspace"
  target="$temp_dir/owned.txt"
  printf 'original\n' >"$target"

  run bash -c '
    set -euo pipefail
    source "$1"
    SETUP_DRY_RUN=""
    setup_journal_begin "$2" "fail-op"
    setup_journal_record "$3"
    printf "mutated\n" >"$3"
    exit 2
  ' _ "$SETUP_JOURNAL_SH" "$state" "$target"
  [ "$status" -ne 0 ]
  [ "$(cat "$target")" = "original" ]
}

@test "setup journal recovers journaled writes on interrupt signal" {
  [ -f "$SETUP_JOURNAL_SH" ] || skip "setup-journal.sh missing"

  local temp_dir state target
  temp_dir="$(mktemp -d)"
  state="$temp_dir/.ralph-workspace"
  target="$temp_dir/owned.txt"
  printf 'original\n' >"$target"

  run bash -c '
    set -euo pipefail
    source "$1"
    SETUP_DRY_RUN=""
    setup_journal_begin "$2" "int-op"
    setup_journal_record "$3"
    printf "mutated\n" >"$3"
    kill -TERM "$$"
    exit 99
  ' _ "$SETUP_JOURNAL_SH" "$state" "$target"
  [ "$status" -ne 0 ]
  [ "$status" -ne 99 ]
  [ "$(cat "$target")" = "original" ]
}

@test "owned-file removal refuses mutation when journal backup fails" {
  [ -f "$SETUP_JOURNAL_SH" ] || skip "setup-journal.sh missing"
  [ -f "$SETUP_REMOVE_SH" ] || skip "setup-remove.sh missing"

  local temp_dir source target
  temp_dir="$(mktemp -d)"
  source="$temp_dir/source.txt"
  target="$temp_dir/target.txt"
  printf 'owned\n' >"$source"
  cp "$source" "$target"

  run bash -c '
    set -euo pipefail
    source "$1"
    source "$2"
    setup_merge_status() { :; }
    SETUP_DRY_RUN=""
    SETUP_JOURNAL_DIR=""
    SETUP_JOURNAL_FILE=""
    if setup_remove_owned_file "$3" "$4"; then
      exit 0
    else
      rc=$?
      exit "$rc"
    fi
  ' _ "$SETUP_JOURNAL_SH" "$SETUP_REMOVE_SH" "$source" "$target"
  [ "$status" -ne 0 ]
  [[ "$output" == *"setup journal is not active"* ]]
  [ -f "$target" ]
  cmp -s "$source" "$target"
}

# Clean end-to-end fixture: project with MCP server + unrelated native agent.
_fixture_setup_runtime_clean_with_native_agent() {
  local project_dir="$1"
  local runtime_dir="$2"
  local marker="${3:-native-agent-marker-do-not-touch}"
  mkdir -p "$project_dir/.ralph" "$runtime_dir/agents/my-native-agent" "$runtime_dir/agents/research"
  cp "$REPO_ROOT/bundle/.ralph/mcp-server.sh" "$project_dir/.ralph/mcp-server.sh"
  chmod +x "$project_dir/.ralph/mcp-server.sh"
  printf '%s\n' "$marker" >"$runtime_dir/agents/my-native-agent/my-native-agent.md"
  printf 'stale-six\n' >"$runtime_dir/agents/research/research.md"
}

@test "clean setup --all continues hooks/mcp and preserve unrelated native agent" {
  command -v jq >/dev/null || skip "jq required"
  command -v python3 >/dev/null || skip "python3 required"
  [ -f "$SETUP_RUNTIME_SH" ] || skip "setup-runtime.sh missing"

  local project_dir runtime_dir marker
  project_dir="$(mktemp -d)"
  runtime_dir="$project_dir/.cursor"
  marker="native-agent-marker-do-not-touch"
  _fixture_setup_runtime_clean_with_native_agent "$project_dir" "$runtime_dir" "$marker"

  run bash "$SETUP_RUNTIME_SH" \
    --runtime cursor \
    --runtime-dir "$runtime_dir" \
    --all \
    --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"hooks"* ]]
  [[ "$output" == *"mcp"* ]]
  [ -f "$runtime_dir/mcp.json" ]
  jq -e '.mcpServers.ralph' "$runtime_dir/mcp.json" >/dev/null
  [ -d "$runtime_dir/hooks" ] || [ -f "$runtime_dir/hooks.json" ]
  [ -f "$runtime_dir/agents/my-native-agent/my-native-agent.md" ]
  [[ "$(cat "$runtime_dir/agents/my-native-agent/my-native-agent.md")" == "$marker" ]]
  [ -f "$runtime_dir/agents/research/research.md" ]
  [[ "$(cat "$runtime_dir/agents/research/research.md")" == "stale-six" ]]
  [ ! -d "$runtime_dir/agents/architect" ]
  [ ! -d "$runtime_dir/agents/code-review" ]
  [ ! -d "$runtime_dir/agents/implementation" ]
  [ ! -d "$runtime_dir/agents/qa" ]
  [ ! -d "$runtime_dir/agents/security" ]
  [ ! -e "$project_dir/.agents/agents.md" ]
  rm -rf "$project_dir"
}

@test "help documents that setup does not create Ralph native agent definitions" {
  [ -f "$SETUP_RUNTIME_SH" ] || skip "setup-runtime.sh missing"

  run bash "$SETUP_RUNTIME_SH" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Does not create or validate Ralph native agent"* ]]
  [[ "$output" == *"Native runtime agent directories"* ]]
}
