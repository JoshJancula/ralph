#!/usr/bin/env bats
# shellcheck shell=bash

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan-invoke-cursor.sh"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan-invoke-claude.sh"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan-invoke-codex.sh"

  TEST_TMPDIR="$(mktemp -d)"
  BIN_DIR="$TEST_TMPDIR/bin"
  mkdir -p "$BIN_DIR"
  export WORKSPACE="$TEST_TMPDIR/workspace"
  mkdir -p "$WORKSPACE/.codex/ralph"

  ORIGINAL_PATH="$PATH"
  PATH="$BIN_DIR:$PATH"

  export OUTPUT_LOG="$TEST_TMPDIR/output.log"
  export EXIT_CODE_FILE="$TEST_TMPDIR/exit-code"
  export PROMPT=""

  unset SELECTED_MODEL
  unset CLAUDE_PLAN_ALLOWED_TOOLS
  unset CLAUDE_PLAN_NO_ALLOWED_TOOLS
  unset CLAUDE_TOOLS_FROM_AGENT
  unset CODEX_CLI
  unset CODEX_PLAN_CLI
  unset CODEX_PLAN_MODEL
  unset RALPH_PLAN_ALLOW_UNSAFE_RESUME
  unset RALPH_RUN_PLAN_RESUME_BARE
  unset RALPH_PLAN_CLI_RESUME
  unset RALPH_RUN_PLAN_RESUME_SESSION_ID
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

write_codex_exec_stub() {
  local record="$1"

  mkdir -p "$WORKSPACE/.codex/ralph"
  cat <<EOF >"$WORKSPACE/.codex/ralph/codex-exec-prompt.sh"
#!/usr/bin/env bash
printf 'MODEL:%s\n' "\${CODEX_PLAN_MODEL:-}" >>"$record"
printf 'CLI:%s\n' "\${CODEX_PLAN_CLI:-}" >>"$record"
printf 'RESUME_BARE:%s\n' "\${RALPH_RUN_PLAN_RESUME_BARE:-}" >>"$record"
printf 'ARGS:%s\n' "\$@" >>"$record"
EOF
  chmod +x "$WORKSPACE/.codex/ralph/codex-exec-prompt.sh"
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

@test "cursor invoke helper honors SELECTED_MODEL" {
  local record="$TEST_TMPDIR/cursor.model.args"
  write_stub_script "cursor-agent" "$record"

  SELECTED_MODEL="gpt-4"
  export SELECTED_MODEL
  PROMPT="model prompt"
  export PROMPT

  run ralph_run_plan_invoke_cursor
  [ "$status" -eq 0 ]
  [ -s "$record" ]

  grep -Fxq -- "--model" "$record"
  grep -Fxq -- "gpt-4" "$record"
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

@test "claude invoke helper errors when CLI missing" {
  export CLAUDE_PLAN_CLI="claude-does-not-exist"

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"Error: Claude CLI not found"* ]]
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
  [ -x "$(command -v python3)" ] || skip "python3 required for JSON demux"
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

@test "codex-exec-prompt adds sandbox args and honors extras" {
  cat <<'EOF' >"$BIN_DIR/codex"
#!/usr/bin/env bash
printf '%s\n' "$@"
EOF
  chmod +x "$BIN_DIR/codex"

  local prompt_file="$TEST_TMPDIR/codex-prompt.txt"
  echo "prompt-body" >"$prompt_file"

  export CODEX_PLAN_CLI=codex
  export CODEX_PLAN_MODEL="codex-model"
  export CODEX_PLAN_EXEC_EXTRA="--timeout 123 --voice"
  export RALPH_PLAN_CLI_RESUME=0

  run bash "$REPO_ROOT/bundle/.codex/ralph/codex-exec-prompt.sh" "$prompt_file" "$WORKSPACE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--sandbox"* ]]
  [[ "$output" == *"workspace-write"* ]]
  [[ "$output" == *"--add-dir"* ]]
  [[ "$output" == *"$WORKSPACE/.ralph-workspace"* ]]
  [[ "$output" == *"--model"* ]]
  [[ "$output" == *"codex-model"* ]]
  [[ "$output" == *"--timeout"* ]]
  [[ "$output" == *"--voice"* ]]
  [[ "$output" == *"prompt-body"* ]]
}

@test "codex invoke helper warns when unsafe bare resume is blocked" {
  local record="$TEST_TMPDIR/codex-bare.warn"
  write_codex_exec_stub "$record"

  export PROMPT="bare warn"
  export RALPH_RUN_PLAN_RESUME_BARE=1
  export RALPH_PLAN_ALLOW_UNSAFE_RESUME=0
  export RALPH_PLAN_CLI_RESUME=0

  run ralph_run_plan_invoke_codex
  [ "$status" -eq 0 ]
  [[ "$output" == *"Warning: resume without a session id requires"* ]]
  [ -s "$record" ]
}

@test "codex invoke helper honors CODEX_CLI overrides" {
  local record="$TEST_TMPDIR/codex-cli.args"
  write_codex_exec_stub "$record"

  export CODEX_CLI="custom-codex"
  export PROMPT="cli override"

  run ralph_run_plan_invoke_codex
  [ "$status" -eq 0 ]
  grep -Fxq -- "CLI:custom-codex" "$record"
}

@test "codex invoke helper respects SELECTED_MODEL" {
  local record="$TEST_TMPDIR/codex-model.args"
  write_codex_exec_stub "$record"

  SELECTED_MODEL="gpt-5"
  export SELECTED_MODEL
  export PROMPT="model test"

  run ralph_run_plan_invoke_codex
  [ "$status" -eq 0 ]
  grep -Fxq -- "MODEL:gpt-5" "$record"
}
