#!/usr/bin/env bats
# Regression coverage for native-hook Read/Grep/Glob/Bash shape-preserving
# compaction (PLAN15). Expands the small committed live fixtures at runtime
# instead of committing oversized payloads.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

FIXTURE_DIR="$REPO_ROOT/tests/fixtures/native-hook"
HOOK="$REPO_ROOT/bundle/.claude/hooks/native-result-compact.sh"

setup() {
  _tmp="$(mktemp -d)"
  export WORKSPACE="$_tmp/workspace"
  mkdir -p "$WORKSPACE"
  export CLAUDE_PROJECT_DIR="$REPO_ROOT"
  export RALPH_NATIVE_RESULT_COMPACT=1
  export RALPH_PLAN_KEY="native-result-shapes-bats"
  export RALPH_RESULT_WINDOWING_LOG="$_tmp/windowing.jsonl"
}

teardown() {
  rm -rf "$_tmp"
  unset WORKSPACE CLAUDE_PROJECT_DIR RALPH_NATIVE_RESULT_COMPACT RALPH_PLAN_KEY RALPH_RESULT_WINDOWING_LOG
}

# Expands a fixture's tool_response.<field path> by repeating its current
# string value $1 times, writes the result to $_tmp/<name>, and prints the
# path. field_path is dot-separated (e.g. "file.content" or "stdout").
_expand_fixture() {
  local fixture="$1" field_path="$2" repeat="$3" out_name="$4"
  local out="$_tmp/$out_name"
  RALPH_TEST_REPEAT="$repeat" RALPH_TEST_FIELD="$field_path" \
    jq --argjson repeat "$repeat" '
      def setpath_repeat(path):
        getpath(["tool_response"] + path) as $v
        | setpath(["tool_response"] + path; ($v * $repeat));
      setpath_repeat('"$(printf '%s' "$field_path" | awk -F. '{out="["; for(i=1;i<=NF;i++){ if(i>1) out=out","; out=out"\"" $i "\""}; print out"]"}')"')
    ' "$fixture" > "$out"
  printf '%s\n' "$out"
}

@test "Read: oversized content is compacted, shape-preserved, telemetry recorded" {
  local f
  f="$(_expand_fixture "$FIXTURE_DIR/read.json" "file.content" 1500 "read_big.json")"
  run bash -c "cat '$f' | bash '$HOOK'"
  [ "$status" -eq 0 ]
  [ -n "$output" ]

  echo "$output" | jq -e . >/dev/null

  local keys
  keys="$(echo "$output" | jq -c '.hookSpecificOutput.updatedToolOutput | keys | sort')"
  [ "$keys" = '["file","type"]' ]

  local orig_len new_len
  orig_len="$(jq '.tool_response.file.content | length' "$f")"
  new_len="$(echo "$output" | jq '.hookSpecificOutput.updatedToolOutput.file.content | length')"
  [ "$new_len" -lt "$orig_len" ]

  local file_path
  file_path="$(echo "$output" | jq -r '.hookSpecificOutput.updatedToolOutput.file.filePath')"
  [ "$file_path" = "/redacted/project/sample.txt" ]

  [ -f "$RALPH_RESULT_WINDOWING_LOG" ]
  run wc -l < "$RALPH_RESULT_WINDOWING_LOG"
  [ "$(echo "$output" | tr -d ' ')" != "" ]
  run jq -r '.toolName' "$RALPH_RESULT_WINDOWING_LOG"
  [ "$output" = "Read" ]
}

@test "Grep content mode: oversized match text is compacted and shape-preserved" {
  local f
  f="$(_expand_fixture "$FIXTURE_DIR/grep-content.json" "content" 2000 "grep_big.json")"
  run bash -c "cat '$f' | bash '$HOOK'"
  [ "$status" -eq 0 ]
  [ -n "$output" ]

  echo "$output" | jq -e . >/dev/null
  local keys
  keys="$(echo "$output" | jq -c '.hookSpecificOutput.updatedToolOutput | keys | sort')"
  [ "$keys" = '["content","filenames","mode","numFiles","numLines"]' ]

  local mode
  mode="$(echo "$output" | jq -r '.hookSpecificOutput.updatedToolOutput.mode')"
  [ "$mode" = "content" ]

  run jq -r '.toolName' "$RALPH_RESULT_WINDOWING_LOG"
  [ "$output" = "Grep" ]
}

@test "Bash: oversized stdout is compacted, stderr sibling untouched" {
  local f
  f="$(_expand_fixture "$FIXTURE_DIR/bash.json" "stdout" 3000 "bash_big.json")"
  run bash -c "cat '$f' | bash '$HOOK'"
  [ "$status" -eq 0 ]
  [ -n "$output" ]

  echo "$output" | jq -e . >/dev/null
  local keys
  keys="$(echo "$output" | jq -c '.hookSpecificOutput.updatedToolOutput | keys | sort')"
  [ "$keys" = '["interrupted","isImage","noOutputExpected","stderr","stdout"]' ]

  local stderr_val
  stderr_val="$(echo "$output" | jq -r '.hookSpecificOutput.updatedToolOutput.stderr')"
  [ "$stderr_val" = "" ]

  run jq -r '.toolName' "$RALPH_RESULT_WINDOWING_LOG"
  [ "$output" = "Bash" ]
}

@test "Grep files_with_matches (no text field) fails open with no hook output" {
  run bash -c "cat '$FIXTURE_DIR/grep-files-with-matches.json' | bash '$HOOK'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "Glob (no text field) fails open with no hook output" {
  run bash -c "cat '$FIXTURE_DIR/glob.json' | bash '$HOOK'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "unknown tool name fails open with no hook output" {
  local f="$_tmp/unknown_tool.json"
  jq '.tool_name = "SomeUnknownTool"' "$FIXTURE_DIR/read.json" > "$f"
  run bash -c "cat '$f' | bash '$HOOK'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "unrecognized response shape fails open with no hook output" {
  local f="$_tmp/unrecognized.json"
  jq '.tool_response = {"nonsenseField": "no text here"}' "$FIXTURE_DIR/read.json" > "$f"
  run bash -c "cat '$f' | bash '$HOOK'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "already-compact envelope content is not re-compacted" {
  local f
  f="$(_expand_fixture "$FIXTURE_DIR/read.json" "file.content" 1500 "read_precompact.json")"
  run bash -c "cat '$f' | bash '$HOOK'"
  [ "$status" -eq 0 ]
  local envelope_text
  envelope_text="$(echo "$output" | jq -c '.hookSpecificOutput.updatedToolOutput.content[0].text // .hookSpecificOutput.updatedToolOutput.file.content')"

  local f2="$_tmp/read_already_compact.json"
  jq --argjson t "$envelope_text" '.tool_response.file.content = ($t | fromjson? // $t)' "$f" \
    | jq --arg raw "$envelope_text" '.tool_response.file.content = ($raw | fromjson)' > "$f2"

  run bash -c "cat '$f2' | bash '$HOOK'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "explicit gate-off (RALPH_NATIVE_RESULT_COMPACT=0) fails open with no hook output" {
  export RALPH_NATIVE_RESULT_COMPACT=0
  local f
  f="$(_expand_fixture "$FIXTURE_DIR/read.json" "file.content" 1500 "read_gate_off.json")"
  run bash -c "cat '$f' | bash '$HOOK'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
