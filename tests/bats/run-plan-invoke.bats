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
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan-invoke-opencode.sh"

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
  unset CLAUDE_PLAN_BARE
  unset CLAUDE_PLAN_PERMISSION_MODE
  unset CODEX_CLI
  unset CODEX_PLAN_CLI
  unset CODEX_PLAN_MODEL
  unset OPENCODE_CLI
  unset OPENCODE_PLAN_CLI
  unset OPENCODE_PLAN_MODEL
  unset RALPH_PLAN_ALLOW_UNSAFE_RESUME
  unset RALPH_RUN_PLAN_RESUME_BARE
  unset RALPH_PLAN_CLI_RESUME
  unset RALPH_RUN_PLAN_RESUME_SESSION_ID
  unset RALPH_RUN_PLAN_RESET_COMMAND_USED
  unset PREBUILT_AGENT
  unset CLAUDE_PLAN_MINIMAL_DISABLE_MCP
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

@test "claude minimal mode helper appends auth-safe flags in order" {
  local -a args=()

  run_plan_invoke_claude_apply_minimal_flags args

  [ "${#args[@]}" -eq 8 ]
  [ "${args[0]}" = "--disable-slash-commands" ]
  [ "${args[1]}" = "--strict-mcp-config" ]
  [ "${args[2]}" = "--mcp-config" ]
  [ "${args[3]}" = '{"mcpServers":{}}' ]
  [ "${args[4]}" = "--setting-sources" ]
  [ "${args[5]}" = "project,local" ]
  [ "${args[6]}" = "--tools" ]
  [ "${args[7]}" = "Bash,Read,Edit,Write" ]

  local -a override_args=()
  CLAUDE_PLAN_MINIMAL_TOOLS="Bash,Read"
  run_plan_invoke_claude_apply_minimal_flags override_args

  [ "${#override_args[@]}" -eq 8 ]
  [ "${override_args[0]}" = "--disable-slash-commands" ]
  [ "${override_args[1]}" = "--strict-mcp-config" ]
  [ "${override_args[2]}" = "--mcp-config" ]
  [ "${override_args[3]}" = '{"mcpServers":{}}' ]
  [ "${override_args[4]}" = "--setting-sources" ]
  [ "${override_args[5]}" = "project,local" ]
  [ "${override_args[6]}" = "--tools" ]
  [ "${override_args[7]}" = "Bash,Read" ]

  unset CLAUDE_PLAN_MINIMAL_TOOLS
  local -a reset_args=()
  RALPH_RUN_PLAN_RESET_COMMAND_USED=1
  run_plan_invoke_claude_apply_minimal_flags reset_args
  unset RALPH_RUN_PLAN_RESET_COMMAND_USED

  [ "${#reset_args[@]}" -eq 7 ]
  [ "${reset_args[0]}" = "--strict-mcp-config" ]
  [ "${reset_args[1]}" = "--mcp-config" ]
  [ "${reset_args[2]}" = '{"mcpServers":{}}' ]
  [ "${reset_args[3]}" = "--setting-sources" ]
  [ "${reset_args[4]}" = "project,local" ]
  [ "${reset_args[5]}" = "--tools" ]
  [ "${reset_args[6]}" = "Bash,Read,Edit,Write" ]
}

@test "claude minimal mode validator normalizes accepted values" {
  unset CLAUDE_PLAN_MINIMAL

  run_plan_invoke_claude_minimal_mode_validate
  [ "$?" -eq 0 ]
  [ "$CLAUDE_PLAN_MINIMAL" = "1" ]

  local case_value expected_value
  for case_value in true yes on 0 false no off; do
    case "$case_value" in
      true|yes|on) expected_value=1 ;;
      0|false|no|off) expected_value=0 ;;
    esac
    CLAUDE_PLAN_MINIMAL="$case_value"
    run_plan_invoke_claude_minimal_mode_validate
    [ "$?" -eq 0 ]
    [ "$CLAUDE_PLAN_MINIMAL" = "$expected_value" ]
  done
}

@test "claude minimal mode validator rejects invalid values" {
  CLAUDE_PLAN_MINIMAL="garbage"

  run run_plan_invoke_claude_minimal_mode_validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"Error: CLAUDE_PLAN_MINIMAL must be one of 1, true, yes, on, 0, false, no, or off."* ]]
}

@test "claude minimal MCP lockdown validator rejects invalid values" {
  CLAUDE_PLAN_MINIMAL_DISABLE_MCP="garbage"

  run run_plan_invoke_claude_minimal_mcp_lockdown_validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"Error: CLAUDE_PLAN_MINIMAL_DISABLE_MCP must be one of 1, true, yes, on, 0, false, no, or off."* ]]
}

@test "claude invoke helper appends minimal flags by default" {
  local record="$TEST_TMPDIR/claude-minimal-default.args"
  local stdin_cap="$TEST_TMPDIR/claude-minimal-default.stdin"
  cat <<EOF >"$BIN_DIR/claude"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
cat >"$stdin_cap"
EOF
  chmod +x "$BIN_DIR/claude"

  PROMPT="claude-minimal-prompt"
  export PROMPT

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  [ -s "$record" ]

  local captured
  captured="$(cat "$record")"
  [[ "$captured" == *"--disable-slash-commands"* ]]
  [[ "$captured" == *"--strict-mcp-config"* ]]
  [[ "$captured" == *"--mcp-config"* ]]
  [[ "$captured" == *'{"mcpServers":{}}'* ]]
  [[ "$captured" == *"--setting-sources"* ]]
  [[ "$captured" == *"project,local"* ]]
  [[ "$captured" == *"--tools"* ]]
  [[ "$captured" == *"Bash,Read,Edit,Write"* ]]
  [[ "$captured" != *"--bare"* ]]
  [ "$(cat "$stdin_cap")" = "claude-minimal-prompt" ]
}

@test "claude invoke helper omits MCP lockdown in minimal mode when CLAUDE_PLAN_MINIMAL_DISABLE_MCP=0" {
  local record="$TEST_TMPDIR/claude-minimal-allow-mcp.args"
  local stdin_cap="$TEST_TMPDIR/claude-minimal-allow-mcp.stdin"
  cat <<EOF >"$BIN_DIR/claude"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
cat >"$stdin_cap"
EOF
  chmod +x "$BIN_DIR/claude"

  PROMPT="claude-minimal-allow-mcp-prompt"
  export PROMPT
  CLAUDE_PLAN_MINIMAL_DISABLE_MCP=0
  export CLAUDE_PLAN_MINIMAL_DISABLE_MCP

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  [ -s "$record" ]

  local captured
  captured="$(cat "$record")"
  [[ "$captured" == *"--disable-slash-commands"* ]]
  [[ "$captured" != *"--strict-mcp-config"* ]]
  [[ "$captured" != *"--mcp-config"* ]]
  [[ "$captured" == *"--setting-sources"* ]]
  [[ "$captured" == *"project,local"* ]]
  [[ "$captured" == *"--tools"* ]]
  [[ "$captured" == *"Bash,Read,Edit,Write"* ]]
  [ "$(cat "$stdin_cap")" = "claude-minimal-allow-mcp-prompt" ]
}

@test "claude invoke helper leaves slash commands enabled when reset command is used" {
  local record="$TEST_TMPDIR/claude-minimal-reset.args"
  local stdin_cap="$TEST_TMPDIR/claude-minimal-reset.stdin"
  cat <<EOF >"$BIN_DIR/claude"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
cat >"$stdin_cap"
EOF
  chmod +x "$BIN_DIR/claude"

  PROMPT="/clear

claude-minimal-reset-prompt"
  export PROMPT
  RALPH_RUN_PLAN_RESET_COMMAND_USED=1
  export RALPH_RUN_PLAN_RESET_COMMAND_USED

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  [ -s "$record" ]

  local captured
  captured="$(cat "$record")"
  [[ "$captured" != *"--disable-slash-commands"* ]]
  [[ "$captured" == *"--strict-mcp-config"* ]]
  [[ "$captured" == *"--mcp-config"* ]]
  [[ "$captured" == *'{"mcpServers":{}}'* ]]
  [[ "$captured" == *"--setting-sources"* ]]
  [[ "$captured" == *"project,local"* ]]
  [[ "$captured" == *"--tools"* ]]
  [[ "$captured" == *"Bash,Read,Edit,Write"* ]]
  [ "$(cat "$stdin_cap")" = "$PROMPT" ]
}

@test "claude invoke helper reset mode omits MCP lockdown when CLAUDE_PLAN_MINIMAL_DISABLE_MCP=0" {
  local record="$TEST_TMPDIR/claude-minimal-reset-allow-mcp.args"
  local stdin_cap="$TEST_TMPDIR/claude-minimal-reset-allow-mcp.stdin"
  cat <<EOF >"$BIN_DIR/claude"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
cat >"$stdin_cap"
EOF
  chmod +x "$BIN_DIR/claude"

  PROMPT="/clear

claude-minimal-reset-allow-mcp-prompt"
  export PROMPT
  RALPH_RUN_PLAN_RESET_COMMAND_USED=1
  export RALPH_RUN_PLAN_RESET_COMMAND_USED
  CLAUDE_PLAN_MINIMAL_DISABLE_MCP=0
  export CLAUDE_PLAN_MINIMAL_DISABLE_MCP

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  [ -s "$record" ]

  local captured
  captured="$(cat "$record")"
  [[ "$captured" != *"--disable-slash-commands"* ]]
  [[ "$captured" != *"--strict-mcp-config"* ]]
  [[ "$captured" != *"--mcp-config"* ]]
  [[ "$captured" == *"--setting-sources"* ]]
  [[ "$captured" == *"--tools"* ]]
  [ "$(cat "$stdin_cap")" = "$PROMPT" ]
}

@test "claude invoke helper omits --bare when CLAUDE_PLAN_BARE=0" {
  local record="$TEST_TMPDIR/claude-no-bare.args"
  local stdin_cap="$TEST_TMPDIR/claude-no-bare.stdin"
  cat <<EOF >"$BIN_DIR/claude"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
cat >"$stdin_cap"
EOF
  chmod +x "$BIN_DIR/claude"

  PROMPT="claude-no-bare-prompt"
  export PROMPT
  CLAUDE_PLAN_BARE=0
  CLAUDE_PLAN_MINIMAL=0
  export CLAUDE_PLAN_BARE
  export CLAUDE_PLAN_MINIMAL

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  [ -s "$record" ]

  local captured
  captured="$(cat "$record")"
  [[ "$captured" != *"--bare"* ]]
  [[ "$captured" != *"--disable-slash-commands"* ]]
  [[ "$captured" != *"--strict-mcp-config"* ]]
  [[ "$captured" != *"--mcp-config"* ]]
  [[ "$captured" != *"--setting-sources"* ]]
  [[ "$captured" != *"--tools"* ]]
  [ "$(cat "$stdin_cap")" = "claude-no-bare-prompt" ]
}

@test "claude invoke helper appends --bare when CLAUDE_PLAN_BARE=1" {
  local record="$TEST_TMPDIR/claude-bare.args"
  local stdin_cap="$TEST_TMPDIR/claude-bare.stdin"
  cat <<EOF >"$BIN_DIR/claude"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
cat >"$stdin_cap"
EOF
  chmod +x "$BIN_DIR/claude"

  PROMPT="claude-bare-prompt"
  export PROMPT
  CLAUDE_PLAN_BARE=1
  export CLAUDE_PLAN_BARE

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  [ -s "$record" ]

  local captured
  captured="$(cat "$record")"
  [[ "$captured" == *"--bare"* ]]
  [[ "$captured" != *"--disable-slash-commands"* ]]
  [[ "$captured" != *"--strict-mcp-config"* ]]
  [[ "$captured" != *"--mcp-config"* ]]
  [[ "$captured" != *"--setting-sources"* ]]
  [[ "$captured" != *"--tools"* ]]
  [ "$(cat "$stdin_cap")" = "claude-bare-prompt" ]
}

@test "claude invoke helper retries with minimal flags on Not logged in" {
  local first_record="$TEST_TMPDIR/claude-retry-first.args"
  local second_record="$TEST_TMPDIR/claude-retry-second.args"
  local call_count="$TEST_TMPDIR/claude-retry-count"
  export CLAUDE_RETRY_FIRST="$first_record"
  export CLAUDE_RETRY_SECOND="$second_record"
  export CLAUDE_RETRY_COUNT="$call_count"
  cat <<'EOF' >"$BIN_DIR/claude"
#!/usr/bin/env bash
count=0
if [[ -f "$CLAUDE_RETRY_COUNT" ]]; then
  count="$(cat "$CLAUDE_RETRY_COUNT")"
fi
count=$((count + 1))
printf '%s\n' "$count" >"$CLAUDE_RETRY_COUNT"

if [[ "$count" -eq 1 ]]; then
  printf '%s\n' "$@" >>"$CLAUDE_RETRY_FIRST"
  echo "Not logged in - Please run /login"
  exit 1
fi

printf '%s\n' "$@" >>"$CLAUDE_RETRY_SECOND"
exit 0
EOF
  chmod +x "$BIN_DIR/claude"

  PROMPT="claude-retry-prompt"
  export PROMPT
  CLAUDE_PLAN_BARE=1
  export CLAUDE_PLAN_BARE

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  [ -s "$first_record" ]
  [ -s "$second_record" ]
  [ "$(cat "$call_count")" = "2" ]

  local first_captured second_captured
  first_captured="$(cat "$first_record")"
  second_captured="$(cat "$second_record")"
  [[ "$first_captured" == *"--bare"* ]]
  [[ "$first_captured" != *"--disable-slash-commands"* ]]
  [[ "$first_captured" != *"--strict-mcp-config"* ]]
  [[ "$first_captured" != *"--mcp-config"* ]]
  [[ "$first_captured" != *"--setting-sources"* ]]
  [[ "$first_captured" != *"--tools"* ]]
  [[ "$second_captured" != *"--bare"* ]]
  [[ "$second_captured" == *"--disable-slash-commands"* ]]
  [[ "$second_captured" == *"--strict-mcp-config"* ]]
  [[ "$second_captured" == *"--mcp-config"* ]]
  [[ "$second_captured" == *'{"mcpServers":{}}'* ]]
  [[ "$second_captured" == *"--setting-sources"* ]]
  [[ "$second_captured" == *"project,local"* ]]
  [[ "$second_captured" == *"--tools"* ]]
  [[ "$second_captured" == *"Bash,Read,Edit,Write"* ]]
  [[ "$output" == *"Retrying once with CLAUDE_PLAN_MINIMAL=1"* ]]
}

@test "claude invoke helper does not retry when bare is already off" {
  local record="$TEST_TMPDIR/claude-no-retry.args"
  local call_count="$TEST_TMPDIR/claude-no-retry-count"
  export CLAUDE_NO_RETRY_RECORD="$record"
  export CLAUDE_NO_RETRY_COUNT="$call_count"
  cat <<'EOF' >"$BIN_DIR/claude"
#!/usr/bin/env bash
count=0
if [[ -f "$CLAUDE_NO_RETRY_COUNT" ]]; then
  count="$(cat "$CLAUDE_NO_RETRY_COUNT")"
fi
count=$((count + 1))
printf '%s\n' "$count" >"$CLAUDE_NO_RETRY_COUNT"
printf '%s\n' "$@" >>"$CLAUDE_NO_RETRY_RECORD"
exit 0
EOF
  chmod +x "$BIN_DIR/claude"

  PROMPT="claude-no-retry-prompt"
  export PROMPT
  CLAUDE_PLAN_BARE=0
  export CLAUDE_PLAN_BARE

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  [ "$(cat "$call_count")" = "1" ]
  [ -s "$record" ]

  local captured
  captured="$(cat "$record")"
  [[ "$captured" != *"--bare"* ]]
  [[ "$captured" == *"--disable-slash-commands"* ]]
  [[ "$captured" == *"--strict-mcp-config"* ]]
  [[ "$captured" == *"--mcp-config"* ]]
  [[ "$captured" == *"--setting-sources"* ]]
  [[ "$captured" == *"--tools"* ]]
  [[ "$output" != *"Retrying once with CLAUDE_PLAN_MINIMAL=1"* ]]
}

@test "claude invoke helper appends --permission-mode when CLAUDE_PLAN_PERMISSION_MODE is set" {
  local record="$TEST_TMPDIR/claude-permission.args"
  local stdin_cap="$TEST_TMPDIR/claude-permission.stdin"
  cat <<EOF >"$BIN_DIR/claude"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
cat >"$stdin_cap"
EOF
  chmod +x "$BIN_DIR/claude"

  PROMPT="claude-permission-prompt"
  export PROMPT
  CLAUDE_PLAN_PERMISSION_MODE="acceptEdits"
  export CLAUDE_PLAN_PERMISSION_MODE

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  [ -s "$record" ]

  local captured
  captured="$(cat "$record")"
  [[ "$captured" == *"--permission-mode"* ]]
  [[ "$captured" == *"acceptEdits"* ]]
  [ "$(cat "$stdin_cap")" = "claude-permission-prompt" ]
}

@test "claude invoke helper rejects invalid CLAUDE_PLAN_PERMISSION_MODE" {
  local record="$TEST_TMPDIR/claude-permission-invalid.args"
  cat <<EOF >"$BIN_DIR/claude"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
exit 0
EOF
  chmod +x "$BIN_DIR/claude"

  PROMPT="claude-permission-invalid"
  export PROMPT
  CLAUDE_PLAN_PERMISSION_MODE="not-a-mode"
  export CLAUDE_PLAN_PERMISSION_MODE

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"Error: CLAUDE_PLAN_PERMISSION_MODE must be one of default, acceptEdits, auto, bypassPermissions, dontAsk, or plan."* ]]
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

@test "cursor usage capture writes USAGE_FILE even without CLI resume" {
  [ -x "$(command -v python3)" ] || skip "python3 required for JSON demux"
  cat <<'EOF' >"$BIN_DIR/cursor-agent"
#!/usr/bin/env bash
echo '{"session_id":"cursor-sid-usage","content":"ok","usage":{"promptTokens":5,"completionTokens":7,"cacheReadInputTokens":2}}'
exit 0
EOF
  chmod +x "$BIN_DIR/cursor-agent"

  export SESSION_ID_FILE="$TEST_TMPDIR/cursor-sid-usage.txt"
  export RALPH_PLAN_CLI_RESUME=0
  export RALPH_PLAN_CAPTURE_USAGE=1
  export USAGE_FILE="$TEST_TMPDIR/cursor.usage.json"
  PROMPT="p"
  export PROMPT

  run ralph_run_plan_invoke_cursor
  [ "$status" -eq 0 ]
  [ -s "$USAGE_FILE" ]
  python3 - <<'PY' "$USAGE_FILE"
import json,sys
with open(sys.argv[1]) as f:
  d=json.load(f)
assert d.get("input_tokens") == 5
assert d.get("output_tokens") == 7
assert d.get("cache_read_input_tokens") == 2
PY
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

@test "opencode invoke helper pins build agent by default" {
  local record="$TEST_TMPDIR/opencode.args"
  write_stub_script "opencode" "$record"

  PROMPT="opencode-prompt"
  export PROMPT
  SELECTED_MODEL="anthropic/claude-sonnet-4-6"
  export SELECTED_MODEL

  run ralph_run_plan_invoke_opencode
  [ "$status" -eq 0 ]
  [ -s "$record" ]

  grep -Fxq -- "run" "$record"
  grep -Fxq -- "--agent" "$record"
  grep -Fxq -- "build" "$record"
  grep -Fxq -- "--model" "$record"
  grep -Fxq -- "anthropic/claude-sonnet-4-6" "$record"
  grep -Fxq -- "opencode-prompt" "$record"
}

@test "opencode invoke helper adds --continue for bare resume when unsafe allowed" {
  local record="$TEST_TMPDIR/opencode-bare.args"
  write_stub_script "opencode" "$record"

  PROMPT="opencode-bare-prompt"
  export PROMPT
  export RALPH_RUN_PLAN_RESUME_BARE=1
  export RALPH_PLAN_ALLOW_UNSAFE_RESUME=1
  unset RALPH_RUN_PLAN_RESUME_SESSION_ID

  run ralph_run_plan_invoke_opencode
  [ "$status" -eq 0 ]
  [ -s "$record" ]

  grep -Fxq -- "run" "$record"
  grep -Fxq -- "--continue" "$record"
  grep -Fxq -- "opencode-bare-prompt" "$record"
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

@test "codex-exec-prompt honors CODEX_PLAN_SANDBOX overrides" {
  cat <<'EOF' >"$BIN_DIR/codex"
#!/usr/bin/env bash
printf '%s\n' "$@"
EOF
  chmod +x "$BIN_DIR/codex"

  local prompt_file="$TEST_TMPDIR/codex-sandbox-prompt.txt"
  echo "sandbox-prompt" >"$prompt_file"

  export CODEX_PLAN_CLI=codex
  export CODEX_PLAN_SANDBOX="danger-full-access"
  export RALPH_PLAN_CLI_RESUME=0

  run bash "$REPO_ROOT/bundle/.codex/ralph/codex-exec-prompt.sh" "$prompt_file" "$WORKSPACE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--sandbox"* ]]
  [[ "$output" == *"danger-full-access"* ]]
  [[ "$output" == *"sandbox-prompt"* ]]
}

@test "codex-exec-prompt passes --json when RALPH_PLAN_CAPTURE_USAGE=1" {
  cat <<'EOF' >"$BIN_DIR/codex"
#!/usr/bin/env bash
printf '%s\n' "$@"
EOF
  chmod +x "$BIN_DIR/codex"

  local prompt_file="$TEST_TMPDIR/codex-capture-prompt.txt"
  echo "capture-prompt" >"$prompt_file"

  export CODEX_PLAN_CLI=codex
  export RALPH_PLAN_CLI_RESUME=0
  export RALPH_PLAN_CAPTURE_USAGE=1

  run bash "$REPO_ROOT/bundle/.codex/ralph/codex-exec-prompt.sh" "$prompt_file" "$WORKSPACE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--json"* ]]
}

@test "codex-exec-prompt omits --json when both CAPTURE_USAGE and CLI_RESUME are off" {
  cat <<'EOF' >"$BIN_DIR/codex"
#!/usr/bin/env bash
printf '%s\n' "$@"
EOF
  chmod +x "$BIN_DIR/codex"

  local prompt_file="$TEST_TMPDIR/codex-no-json-prompt.txt"
  echo "no-json-prompt" >"$prompt_file"

  export CODEX_PLAN_CLI=codex
  export RALPH_PLAN_CLI_RESUME=0
  export RALPH_PLAN_CAPTURE_USAGE=0

  run bash "$REPO_ROOT/bundle/.codex/ralph/codex-exec-prompt.sh" "$prompt_file" "$WORKSPACE"
  [ "$status" -eq 0 ]
  [[ "$output" != *"--json"* ]]
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

@test "codex-exec-prompt includes bypass flag when CODEX_PLAN_DANGEROUSLY_BYPASS_APPROVALS_AND_SANDBOX=1" {
  cat <<'EOF' >"$BIN_DIR/codex"
#!/usr/bin/env bash
printf '%s\n' "$@"
EOF
  chmod +x "$BIN_DIR/codex"

  local prompt_file="$TEST_TMPDIR/codex-bypass-prompt.txt"
  echo "bypass-prompt" >"$prompt_file"

  export CODEX_PLAN_CLI=codex
  export CODEX_PLAN_DANGEROUSLY_BYPASS_APPROVALS_AND_SANDBOX=1
  export RALPH_PLAN_CLI_RESUME=0
  export RALPH_PLAN_CAPTURE_USAGE=0

  run bash "$REPO_ROOT/bundle/.codex/ralph/codex-exec-prompt.sh" "$prompt_file" "$WORKSPACE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--dangerously-bypass-approvals-and-sandbox"* ]]
  [[ "$output" == *"--sandbox"* ]]
  [[ "$output" == *"bypass-prompt"* ]]
}

@test "codex-exec-prompt omits bypass flag by default" {
  cat <<'EOF' >"$BIN_DIR/codex"
#!/usr/bin/env bash
printf '%s\n' "$@"
EOF
  chmod +x "$BIN_DIR/codex"

  local prompt_file="$TEST_TMPDIR/codex-no-bypass-prompt.txt"
  echo "no-bypass-prompt" >"$prompt_file"

  export CODEX_PLAN_CLI=codex
  export RALPH_PLAN_CLI_RESUME=0
  export RALPH_PLAN_CAPTURE_USAGE=0

  run bash "$REPO_ROOT/bundle/.codex/ralph/codex-exec-prompt.sh" "$prompt_file" "$WORKSPACE"
  [ "$status" -eq 0 ]
  [[ "$output" != *"--dangerously-bypass-approvals-and-sandbox"* ]]
  [[ "$output" == *"--sandbox"* ]]
  [[ "$output" == *"no-bypass-prompt"* ]]
}

@test "codex-exec-prompt bypass flag with resume --last" {
  cat <<'EOF' >"$BIN_DIR/codex"
#!/usr/bin/env bash
printf '%s\n' "$@"
EOF
  chmod +x "$BIN_DIR/codex"

  local prompt_file="$TEST_TMPDIR/codex-bypass-resume-prompt.txt"
  echo "bypass-resume-prompt" >"$prompt_file"

  export CODEX_PLAN_CLI=codex
  export CODEX_PLAN_NO_ADD_AGENTS_DIR=1
  export CODEX_PLAN_DANGEROUSLY_BYPASS_APPROVALS_AND_SANDBOX=1
  export RALPH_RUN_PLAN_RESUME_BARE=1
  export RALPH_PLAN_ALLOW_UNSAFE_RESUME=1
  unset RALPH_RUN_PLAN_RESUME_SESSION_ID
  export RALPH_PLAN_CLI_RESUME=0

  run bash "$REPO_ROOT/bundle/.codex/ralph/codex-exec-prompt.sh" "$prompt_file" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--dangerously-bypass-approvals-and-sandbox"* ]]
  [[ "$output" == *"resume"* ]]
  [[ "$output" == *"--last"* ]]
}

@test "codex-exec-prompt default includes --full-auto on exec" {
  cat <<'EOF' >"$BIN_DIR/codex"
#!/usr/bin/env bash
printf '%s\n' "$@"
EOF
  chmod +x "$BIN_DIR/codex"

  local prompt_file="$TEST_TMPDIR/codex-fullauto-default.txt"
  echo "fullauto-default-prompt" >"$prompt_file"

  export CODEX_PLAN_CLI=codex
  export RALPH_PLAN_CLI_RESUME=0
  export RALPH_PLAN_CAPTURE_USAGE=0

  run bash "$REPO_ROOT/bundle/.codex/ralph/codex-exec-prompt.sh" "$prompt_file" "$WORKSPACE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--full-auto"* ]]
  [[ "$output" == *"exec"* ]]
  [[ "$output" == *"fullauto-default-prompt"* ]]
}

@test "codex-exec-prompt CODEX_PLAN_FULL_AUTO=0 omits --full-auto on exec" {
  cat <<'EOF' >"$BIN_DIR/codex"
#!/usr/bin/env bash
printf '%s\n' "$@"
EOF
  chmod +x "$BIN_DIR/codex"

  local prompt_file="$TEST_TMPDIR/codex-fullauto-off.txt"
  echo "fullauto-off-prompt" >"$prompt_file"

  export CODEX_PLAN_CLI=codex
  export CODEX_PLAN_FULL_AUTO=0
  export RALPH_PLAN_CLI_RESUME=0
  export RALPH_PLAN_CAPTURE_USAGE=0

  run bash "$REPO_ROOT/bundle/.codex/ralph/codex-exec-prompt.sh" "$prompt_file" "$WORKSPACE"
  [ "$status" -eq 0 ]
  [[ "$output" != *"--full-auto"* ]]
  [[ "$output" == *"--sandbox"* ]]
  [[ "$output" == *"fullauto-off-prompt"* ]]
}

@test "codex-exec-prompt CODEX_PLAN_FULL_AUTO=0 omits --full-auto on resume with session id" {
  cat <<'EOF' >"$BIN_DIR/codex"
#!/usr/bin/env bash
printf '%s\n' "$@"
EOF
  chmod +x "$BIN_DIR/codex"

  local prompt_file="$TEST_TMPDIR/codex-fullauto-off-session.txt"
  echo "fullauto-off-session-prompt" >"$prompt_file"

  export CODEX_PLAN_CLI=codex
  export CODEX_PLAN_NO_ADD_AGENTS_DIR=1
  export CODEX_PLAN_FULL_AUTO=0
  export RALPH_RUN_PLAN_RESUME_SESSION_ID="test-session-123"
  export RALPH_PLAN_CLI_RESUME=0
  export RALPH_PLAN_CAPTURE_USAGE=0

  run bash "$REPO_ROOT/bundle/.codex/ralph/codex-exec-prompt.sh" "$prompt_file" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"--full-auto"* ]]
  [[ "$output" == *"resume"* ]]
  [[ "$output" == *"test-session-123"* ]]
  [[ "$output" == *"fullauto-off-session-prompt"* ]]
}

@test "codex-exec-prompt CODEX_PLAN_FULL_AUTO=0 omits --full-auto on resume --last" {
  cat <<'EOF' >"$BIN_DIR/codex"
#!/usr/bin/env bash
printf '%s\n' "$@"
EOF
  chmod +x "$BIN_DIR/codex"

  local prompt_file="$TEST_TMPDIR/codex-fullauto-off-last.txt"
  echo "fullauto-off-last-prompt" >"$prompt_file"

  export CODEX_PLAN_CLI=codex
  export CODEX_PLAN_NO_ADD_AGENTS_DIR=1
  export CODEX_PLAN_FULL_AUTO=0
  export RALPH_RUN_PLAN_RESUME_BARE=1
  export RALPH_PLAN_ALLOW_UNSAFE_RESUME=1
  unset RALPH_RUN_PLAN_RESUME_SESSION_ID
  export RALPH_PLAN_CLI_RESUME=0
  export RALPH_PLAN_CAPTURE_USAGE=0

  run bash "$REPO_ROOT/bundle/.codex/ralph/codex-exec-prompt.sh" "$prompt_file" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"--full-auto"* ]]
  [[ "$output" == *"resume"* ]]
  [[ "$output" == *"--last"* ]]
  [[ "$output" == *"fullauto-off-last-prompt"* ]]
}

@test "codex-exec-prompt default includes --full-auto on resume with session id" {
  cat <<'EOF' >"$BIN_DIR/codex"
#!/usr/bin/env bash
printf '%s\n' "$@"
EOF
  chmod +x "$BIN_DIR/codex"

  local prompt_file="$TEST_TMPDIR/codex-fullauto-on-session.txt"
  echo "fullauto-on-session-prompt" >"$prompt_file"

  export CODEX_PLAN_CLI=codex
  export CODEX_PLAN_NO_ADD_AGENTS_DIR=1
  export RALPH_RUN_PLAN_RESUME_SESSION_ID="test-session-456"
  export RALPH_PLAN_CLI_RESUME=0
  export RALPH_PLAN_CAPTURE_USAGE=0

  run bash "$REPO_ROOT/bundle/.codex/ralph/codex-exec-prompt.sh" "$prompt_file" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--full-auto"* ]]
  [[ "$output" == *"resume"* ]]
  [[ "$output" == *"test-session-456"* ]]
  [[ "$output" == *"fullauto-on-session-prompt"* ]]
}

@test "codex-exec-prompt default includes --full-auto on resume --last" {
  cat <<'EOF' >"$BIN_DIR/codex"
#!/usr/bin/env bash
printf '%s\n' "$@"
EOF
  chmod +x "$BIN_DIR/codex"

  local prompt_file="$TEST_TMPDIR/codex-fullauto-on-last.txt"
  echo "fullauto-on-last-prompt" >"$prompt_file"

  export CODEX_PLAN_CLI=codex
  export CODEX_PLAN_NO_ADD_AGENTS_DIR=1
  export RALPH_RUN_PLAN_RESUME_BARE=1
  export RALPH_PLAN_ALLOW_UNSAFE_RESUME=1
  unset RALPH_RUN_PLAN_RESUME_SESSION_ID
  export RALPH_PLAN_CLI_RESUME=0
  export RALPH_PLAN_CAPTURE_USAGE=0

  run bash "$REPO_ROOT/bundle/.codex/ralph/codex-exec-prompt.sh" "$prompt_file" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--full-auto"* ]]
  [[ "$output" == *"resume"* ]]
  [[ "$output" == *"--last"* ]]
  [[ "$output" == *"fullauto-on-last-prompt"* ]]
}

@test "codex-exec-prompt records argv for assertion" {
  local record="$TEST_TMPDIR/codex-argv-record.txt"
  cat <<EOF >"$BIN_DIR/codex"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
EOF
  chmod +x "$BIN_DIR/codex"

  local prompt_file="$TEST_TMPDIR/codex-argv-prompt.txt"
  echo "argv-prompt" >"$prompt_file"

  export CODEX_PLAN_CLI=codex
  export CODEX_PLAN_MODEL="test-model"
  export CODEX_PLAN_EXEC_EXTRA="--timeout 30"
  export RALPH_PLAN_CLI_RESUME=0
  export RALPH_PLAN_CAPTURE_USAGE=0

  run bash "$REPO_ROOT/bundle/.codex/ralph/codex-exec-prompt.sh" "$prompt_file" "$WORKSPACE"
  [ "$status" -eq 0 ]
  [ -s "$record" ]

  local captured
  captured="$(cat "$record")"
  [[ "$captured" == *"--full-auto"* ]]
  [[ "$captured" == *"--sandbox"* ]]
  [[ "$captured" == *"workspace-write"* ]]
  [[ "$captured" == *"--model"* ]]
  [[ "$captured" == *"test-model"* ]]
  [[ "$captured" == *"--timeout"* ]]
  [[ "$captured" == *"30"* ]]
  [[ "$captured" == *"argv-prompt"* ]]
}
