#!/usr/bin/env bats
# Coverage for routing actionable native-hook fail-open paths through the
# shared debug writer (PLAN15), and for NOT logging normal no-op paths.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

FIXTURE_DIR="$REPO_ROOT/tests/fixtures/native-hook"
RESULT_HOOK="$REPO_ROOT/bundle/.claude/hooks/native-result-compact.sh"
BASH_HOOK="$REPO_ROOT/bundle/.claude/hooks/compact-bash-output.sh"

setup() {
  _tmp="$(mktemp -d)"
  export WORKSPACE="$_tmp/workspace"
  mkdir -p "$WORKSPACE"
  export CLAUDE_PROJECT_DIR="$REPO_ROOT"
  export RALPH_NATIVE_RESULT_COMPACT=1
  export RALPH_BASH_COMPACT=1
  export RALPH_PLAN_KEY="fail-open-instrumentation-bats"
  export RALPH_RESULT_WINDOWING_LOG="$_tmp/windowing.jsonl"
  export RALPH_NATIVE_HOOK_DEBUG_LOG="$_tmp/debug.jsonl"
}

teardown() {
  rm -rf "$_tmp"
  unset WORKSPACE CLAUDE_PROJECT_DIR RALPH_NATIVE_RESULT_COMPACT RALPH_BASH_COMPACT
  unset RALPH_PLAN_KEY RALPH_RESULT_WINDOWING_LOG RALPH_NATIVE_HOOK_DEBUG_LOG
}

_debug_lines() {
  [[ -f "$RALPH_NATIVE_HOOK_DEBUG_LOG" ]] || { echo 0; return; }
  wc -l < "$RALPH_NATIVE_HOOK_DEBUG_LOG" | tr -d ' '
}

@test "missing jq: one missing_jq line, empty hook stdout/stderr" {
  local stub_bin="$_tmp/stubbed-path"
  mkdir -p "$stub_bin"
  for tool in bash cat mkdir rm ls date dirname mktemp printf sh tr; do
    local real
    real="$(type -P "$tool" 2>/dev/null)" || continue
    ln -sf "$real" "$stub_bin/$tool"
  done

  run bash -c "PATH='$stub_bin' bash '$RESULT_HOOK' < '$FIXTURE_DIR/read.json'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  [ "$(_debug_lines)" = "1" ]
  run jq -r '.reasonCode' "$RALPH_NATIVE_HOOK_DEBUG_LOG"
  [ "$output" = "missing_jq" ]
}

@test "malformed input (empty stdin): one malformed_input line" {
  run bash -c "printf '' | bash '$RESULT_HOOK'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(_debug_lines)" = "1" ]
  run jq -r '.reasonCode' "$RALPH_NATIVE_HOOK_DEBUG_LOG"
  [ "$output" = "malformed_input" ]
}

@test "malformed input (no tool_output/tool_response): one malformed_input line" {
  local f="$_tmp/no_response.json"
  jq 'del(.tool_response)' "$FIXTURE_DIR/read.json" > "$f"
  run bash -c "cat '$f' | bash '$RESULT_HOOK'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(_debug_lines)" = "1" ]
  run jq -r '.reasonCode' "$RALPH_NATIVE_HOOK_DEBUG_LOG"
  [ "$output" = "malformed_input" ]
}

@test "unrecognized response shape on Read: one unrecognized_shape line" {
  local f="$_tmp/unrecognized.json"
  jq '.tool_response = {"nonsenseField": "no text here"}' "$FIXTURE_DIR/read.json" > "$f"
  run bash -c "cat '$f' | bash '$RESULT_HOOK'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(_debug_lines)" = "1" ]
  run jq -r '.reasonCode' "$RALPH_NATIVE_HOOK_DEBUG_LOG"
  [ "$output" = "unrecognized_shape" ]
}

@test "Grep files_with_matches (expected no-text shape): no debug line" {
  run bash -c "cat '$FIXTURE_DIR/grep-files-with-matches.json' | bash '$RESULT_HOOK'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(_debug_lines)" = "0" ]
}

@test "Glob (expected no-text shape): no debug line" {
  run bash -c "cat '$FIXTURE_DIR/glob.json' | bash '$RESULT_HOOK'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(_debug_lines)" = "0" ]
}

@test "gate-off is not logged as an error" {
  export RALPH_NATIVE_RESULT_COMPACT=0
  run bash -c "cat '$FIXTURE_DIR/read.json' | bash '$RESULT_HOOK'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(_debug_lines)" = "0" ]
}

@test "below-threshold (small content, not expanded) is not logged as an error" {
  run bash -c "cat '$FIXTURE_DIR/read.json' | bash '$RESULT_HOOK'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(_debug_lines)" = "0" ]
}

@test "already-compacted envelope content is not logged as an error" {
  local big="$_tmp/read_big.json"
  jq '.tool_response.file.content = (.tool_response.file.content * 1500)' "$FIXTURE_DIR/read.json" > "$big"
  run bash -c "cat '$big' | bash '$RESULT_HOOK'"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  local envelope_text
  envelope_text="$(echo "$output" | jq -c '.hookSpecificOutput.updatedToolOutput.file.content')"

  # Reset debug log between the compacting run and the already-compact run.
  rm -f "$RALPH_NATIVE_HOOK_DEBUG_LOG"
  local already="$_tmp/read_already.json"
  jq --argjson t "$envelope_text" '.tool_response.file.content = ($t | fromjson)' "$big" > "$already"

  run bash -c "cat '$already' | bash '$RESULT_HOOK'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(_debug_lines)" = "0" ]
}

@test "no log file is created when RALPH_NATIVE_HOOK_DEBUG_LOG is unset" {
  unset RALPH_NATIVE_HOOK_DEBUG_LOG
  local f="$_tmp/no_response2.json"
  jq 'del(.tool_response)' "$FIXTURE_DIR/read.json" > "$f"
  run bash -c "cat '$f' | bash '$RESULT_HOOK'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$_tmp/debug.jsonl" ]
}

@test "bash hook: missing jq produces one missing_jq line" {
  local stub_bin="$_tmp/stubbed-bash-path"
  mkdir -p "$stub_bin"
  for tool in bash cat mkdir rm ls date dirname mktemp printf sh tr; do
    local real
    real="$(type -P "$tool" 2>/dev/null)" || continue
    ln -sf "$real" "$stub_bin/$tool"
  done
  local bash_input
  bash_input="$(jq -n '{hook_event_name:"PostToolUse", tool_name:"Bash", tool_input:{command:"echo hi"}, tool_response:{stdout:"hi\n", stderr:"", interrupted:false, isImage:false}}')"

  run bash -c "PATH='$stub_bin' bash '$BASH_HOOK' <<<'$bash_input'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(_debug_lines)" = "1" ]
  run jq -r '.reasonCode' "$RALPH_NATIVE_HOOK_DEBUG_LOG"
  [ "$output" = "missing_jq" ]
}

@test "bash hook: malformed tool_response produces one malformed_input line" {
  local bash_input
  bash_input="$(jq -n '{hook_event_name:"PostToolUse", tool_name:"Bash", tool_input:{command:"echo hi"}}')"

  run bash -c "bash '$BASH_HOOK' <<<'$bash_input'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(_debug_lines)" = "1" ]
  run jq -r '.reasonCode' "$RALPH_NATIVE_HOOK_DEBUG_LOG"
  [ "$output" = "malformed_input" ]
}

@test "bash hook: compaction-not-beneficial output is not logged as an error" {
  local bash_input
  bash_input="$(jq -n '{hook_event_name:"PostToolUse", tool_name:"Bash", tool_input:{command:"echo hi"}, tool_response:{stdout:"hi\n", stderr:"", interrupted:false, isImage:false}}')"

  run bash -c "bash '$BASH_HOOK' <<<'$bash_input'"
  [ "$status" -eq 0 ]
  [ "$(_debug_lines)" = "0" ]
}
