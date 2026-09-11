#!/usr/bin/env bats
# Prove D2 source-output commands reach the model unchanged through the Claude
# PostToolUse:Bash compact hook (compact-bash-output.sh -> ralph_compact_shell_output
# -> shell-output-compact.py). With RALPH_COMPACT_GENERIC_FALLBACK=1, git diff /
# grep / cat / find must emit no updatedToolOutput; npm install still compacts.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

FIXTURE_DIR="$REPO_ROOT/tests/fixtures/native-hook"
HOOK="$REPO_ROOT/bundle/.claude/hooks/compact-bash-output.sh"

setup() {
  _tmp="$(mktemp -d)"
  export WORKSPACE="$_tmp/workspace"
  mkdir -p "$WORKSPACE"
  export CLAUDE_PROJECT_DIR="$REPO_ROOT"
  export RALPH_BASH_COMPACT=1
  export RALPH_COMPACT_GENERIC_FALLBACK=1
  export RALPH_PLAN_KEY="bash-compact-source-passthrough-bats"
  export RALPH_BASH_COMPACT_LOG="$_tmp/compact.jsonl"
  bats_skip_known_ci_flakes
}

teardown() {
  rm -rf "$_tmp"
  unset WORKSPACE CLAUDE_PROJECT_DIR RALPH_BASH_COMPACT RALPH_COMPACT_GENERIC_FALLBACK
  unset RALPH_PLAN_KEY RALPH_BASH_COMPACT_LOG
}

# Build a PostToolUse:Bash payload from the live-capture bash.json fixture shape,
# injecting command + a large stdout body (20 KiB class).
_bash_payload_from_fixture() {
  local command="$1" stdout="$2" out="$3"
  local stdout_file="$_tmp/hook-stdout"
  printf '%s' "$stdout" >"$stdout_file"
  jq --arg cmd "$command" --rawfile stdout "$stdout_file" \
    '.tool_input.command = $cmd
     | .tool_response.stdout = $stdout
     | .tool_response.stderr = ""
     | .tool_response.interrupted = false
     | .tool_response.isImage = false' \
    "$FIXTURE_DIR/bash.json" >"$out"
}

_twenty_kb_lines() {
  local prefix="$1"
  python3 -c "
prefix = '''$prefix'''
line = prefix + ('x' * 64)
# Guarantee >= 20 KiB: total = n*len(line) + (n-1) newlines.
target = 20 * 1024
n = max(1, (target + len(line) + 1) // (len(line) + 1))
text = '\\n'.join(line for _ in range(n))
while len(text.encode('utf-8')) < target:
    n += 1
    text = '\\n'.join(line for _ in range(n))
print(text)
"
}

_assert_no_replacement() {
  local hook_out="$1"
  [ -z "$hook_out" ]
  ! grep -q 'updatedToolOutput' <<<"$hook_out"
  ! grep -q 'hookSpecificOutput' <<<"$hook_out"
}

@test "source-passthrough: git diff 20KB emits no updatedToolOutput" {
  local big input
  big="$(_twenty_kb_lines 'diff --git a/f b/f +')"
  [ "$(printf '%s' "$big" | wc -c | tr -d ' ')" -ge 20480 ]
  input="$_tmp/git-diff.json"
  _bash_payload_from_fixture "git diff" "$big" "$input"

  run bash -c "bash '$HOOK' < '$input'"
  [ "$status" -eq 0 ]
  _assert_no_replacement "$output"
}

@test "source-passthrough: grep -rn 20KB emits no updatedToolOutput" {
  local big input
  big="$(_twenty_kb_lines 'src/file.c:12:')"
  [ "$(printf '%s' "$big" | wc -c | tr -d ' ')" -ge 20480 ]
  input="$_tmp/grep.json"
  _bash_payload_from_fixture "grep -rn proxy bundle/.ralph" "$big" "$input"

  run bash -c "bash '$HOOK' < '$input'"
  [ "$status" -eq 0 ]
  _assert_no_replacement "$output"
}

@test "source-passthrough: cat 20KB emits no updatedToolOutput" {
  local big input
  big="$(_twenty_kb_lines 'file-body-line:')"
  [ "$(printf '%s' "$big" | wc -c | tr -d ' ')" -ge 20480 ]
  input="$_tmp/cat.json"
  _bash_payload_from_fixture "cat large-file.txt" "$big" "$input"

  run bash -c "bash '$HOOK' < '$input'"
  [ "$status" -eq 0 ]
  _assert_no_replacement "$output"
}

@test "source-passthrough: find 20KB emits no updatedToolOutput" {
  local big input
  big="$(_twenty_kb_lines './path/to/file-')"
  [ "$(printf '%s' "$big" | wc -c | tr -d ' ')" -ge 20480 ]
  input="$_tmp/find.json"
  _bash_payload_from_fixture "find . -type f" "$big" "$input"

  run bash -c "bash '$HOOK' < '$input'"
  [ "$status" -eq 0 ]
  _assert_no_replacement "$output"
}

@test "source-passthrough: npm install 20KB is still compacted" {
  local big input compact_stdout orig_len new_len
  # Family npm_install needs a recognizable summary line to rewrite successfully.
  big="$(python3 -c "
lines = ['npm notice fetching ' + ('pkg-' + str(i)).ljust(80, 'x') for i in range(300)]
lines.append('added 42 packages in 3s')
print('\\n'.join(lines))
")"
  [ "$(printf '%s' "$big" | wc -c | tr -d ' ')" -ge 20480 ]
  input="$_tmp/npm-install.json"
  _bash_payload_from_fixture "npm install" "$big" "$input"

  run bash -c "bash '$HOOK' < '$input'"
  [ "$status" -eq 0 ]
  [ -n "$output" ]

  echo "$output" | jq -e '.hookSpecificOutput.updatedToolOutput' >/dev/null
  compact_stdout="$(echo "$output" | jq -r '.hookSpecificOutput.updatedToolOutput.stdout')"
  [ -n "$compact_stdout" ]
  orig_len="$(printf '%s' "$big" | wc -c | tr -d ' ')"
  new_len="$(printf '%s' "$compact_stdout" | wc -c | tr -d ' ')"
  [ "$new_len" -lt "$orig_len" ]
  [[ "$compact_stdout" == *"npm install complete"* ]] || [[ "$compact_stdout" == *"added 42 packages"* ]]
}
