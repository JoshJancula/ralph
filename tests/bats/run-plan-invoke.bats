#!/usr/bin/env bats
# shellcheck shell=bash

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan-invoke-cursor.sh"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan-invoke-claude.sh"

  TEST_TMPDIR="$(mktemp -d)"
  BIN_DIR="$TEST_TMPDIR/bin"
  mkdir -p "$BIN_DIR"

  ORIGINAL_PATH="$PATH"
  PATH="$BIN_DIR:$PATH"

  export OUTPUT_LOG="$TEST_TMPDIR/output.log"
  export EXIT_CODE_FILE="$TEST_TMPDIR/exit-code"
  export PROMPT=""

  unset SELECTED_MODEL
  unset CLAUDE_PLAN_ALLOWED_TOOLS
  unset CLAUDE_PLAN_NO_ALLOWED_TOOLS
  unset CLAUDE_TOOLS_FROM_AGENT
}

teardown() {
  PATH="$ORIGINAL_PATH"
  rm -rf "$TEST_TMPDIR"
}

write_stub_script() {
  local name="$1"
  local record="$2"

  cat <<EOF >"$BIN_DIR/$name"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
EOF
  chmod +x "$BIN_DIR/$name"
}

@test "cursor invoke helper adds -p --force and passes prompt" {
  local record="$TEST_TMPDIR/cursor.args"
  write_stub_script "cursor-agent" "$record"

  PROMPT="cursor-prompt"
  export PROMPT

  run ralph_run_plan_invoke_cursor
  [ "$status" -eq 0 ]
  [ -s "$record" ]

  local captured
  captured="$(cat "$record")"
  [[ "$captured" == *"-p"* ]]
  [[ "$captured" == *"--force"* ]]
  [[ "$captured" == *"cursor-prompt"* ]]
}

@test "claude invoke helper namespaces allowed tools and passes prompt on stdin" {
  local record="$TEST_TMPDIR/claude.args"
  local stdin_cap="$TEST_TMPDIR/claude.stdin"
  cat <<EOF >"$BIN_DIR/claude"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
cat >"$stdin_cap"
EOF
  chmod +x "$BIN_DIR/claude"

  PROMPT="claude-prompt"
  export PROMPT
  CLAUDE_PLAN_ALLOWED_TOOLS="Bash,Read,Edit"
  export CLAUDE_PLAN_ALLOWED_TOOLS

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  [ -s "$record" ]

  local captured
  captured="$(cat "$record")"
  [[ "$captured" == *"-p"* ]]
  [[ "$captured" == *"--allowedTools"* ]]
  [[ "$captured" == *"Bash,Read,Edit"* ]]
  [ "$(cat "$stdin_cap")" = "claude-prompt" ]
}
