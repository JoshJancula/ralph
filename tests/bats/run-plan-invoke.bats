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

@test "claude stream-json path writes session_id to SESSION_ID_FILE" {
  cat <<'EOF' >"$BIN_DIR/claude"
#!/usr/bin/env bash
echo '{"session_id":"sid-from-stream","message":{"text":"done"}}'
exit 0
EOF
  chmod +x "$BIN_DIR/claude"

  export SESSION_ID_FILE="$TEST_TMPDIR/session-id.txt"
  export RALPH_PLAN_CLI_RESUME=1
  PROMPT="p"
  export PROMPT

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  [ "$(cat "$SESSION_ID_FILE" | tr -d '\n')" = "sid-from-stream" ]
}

@test "cursor json path writes session_id to SESSION_ID_FILE" {
  cat <<'EOF' >"$BIN_DIR/cursor-agent"
#!/usr/bin/env bash
echo '{"session_id":"cursor-sid-9","content":"ok"}'
exit 0
EOF
  chmod +x "$BIN_DIR/cursor-agent"

  export SESSION_ID_FILE="$TEST_TMPDIR/cursor-sid.txt"
  export RALPH_PLAN_CLI_RESUME=1
  PROMPT="p"
  export PROMPT

  run ralph_run_plan_invoke_cursor
  [ "$status" -eq 0 ]
  [ "$(cat "$SESSION_ID_FILE" | tr -d '\n')" = "cursor-sid-9" ]
}

@test "claude bare resume passes --resume without session id argument when unsafe allowed" {
  local record="$TEST_TMPDIR/claude-bare.args"
  cat <<EOF >"$BIN_DIR/claude"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
exit 0
EOF
  chmod +x "$BIN_DIR/claude"

  export RALPH_RUN_PLAN_RESUME_BARE=1
  export RALPH_PLAN_ALLOW_UNSAFE_RESUME=1
  unset RALPH_RUN_PLAN_RESUME_SESSION_ID
  export RALPH_PLAN_CLI_RESUME=0
  PROMPT="x"
  export PROMPT

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  grep -Fxq -- "--resume" "$record"
  ! grep -Fxq -- "some-uuid" "$record"
}

@test "claude omits bare --resume when unsafe resume is not allowed" {
  local record="$TEST_TMPDIR/claude-no-unsafe.args"
  cat <<EOF >"$BIN_DIR/claude"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
exit 0
EOF
  chmod +x "$BIN_DIR/claude"

  export RALPH_RUN_PLAN_RESUME_BARE=1
  export RALPH_PLAN_ALLOW_UNSAFE_RESUME=0
  unset RALPH_RUN_PLAN_RESUME_SESSION_ID
  export RALPH_PLAN_CLI_RESUME=0
  PROMPT="x"
  export PROMPT

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  ! grep -Fxq -- "--resume" "$record"
}

@test "cursor bare resume passes --resume and --continue when unsafe allowed" {
  local record="$TEST_TMPDIR/cursor-bare.args"
  cat <<EOF >"$BIN_DIR/cursor-agent"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
exit 0
EOF
  chmod +x "$BIN_DIR/cursor-agent"

  export RALPH_RUN_PLAN_RESUME_BARE=1
  export RALPH_PLAN_ALLOW_UNSAFE_RESUME=1
  unset RALPH_RUN_PLAN_RESUME_SESSION_ID
  export RALPH_PLAN_CLI_RESUME=0
  PROMPT="x"
  export PROMPT

  run ralph_run_plan_invoke_cursor
  [ "$status" -eq 0 ]
  grep -Fxq -- "--resume" "$record"
  grep -Fxq -- "--continue" "$record"
}

@test "codex-exec-prompt uses resume --last when bare and unsafe resume allowed" {
  local record="$TEST_TMPDIR/codex.args"
  cat <<EOF >"$BIN_DIR/codex"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
exit 0
EOF
  chmod +x "$BIN_DIR/codex"

  local pf="$TEST_TMPDIR/prompt.txt"
  echo "prompt-body" >"$pf"
  export CODEX_PLAN_CLI=codex
  export CODEX_PLAN_NO_ADD_AGENTS_DIR=1
  export RALPH_RUN_PLAN_RESUME_BARE=1
  export RALPH_PLAN_ALLOW_UNSAFE_RESUME=1
  unset RALPH_RUN_PLAN_RESUME_SESSION_ID
  export RALPH_PLAN_CLI_RESUME=0

  run bash "$REPO_ROOT/bundle/.codex/ralph/codex-exec-prompt.sh" "$pf" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  grep -Fxq -- "resume" "$record"
  grep -Fxq -- "--last" "$record"
}
