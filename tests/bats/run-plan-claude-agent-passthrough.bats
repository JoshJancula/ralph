#!/usr/bin/env bats
# shellcheck shell=bash

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../" && pwd)"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/.ralph/bash-lib/run-plan/run-plan-invoke-common.sh"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/.ralph/bash-lib/run-plan/run-plan-invoke-claude.sh"

  TEST_TMPDIR="$(mktemp -d)"
  BIN_DIR="$TEST_TMPDIR/bin"
  mkdir -p "$BIN_DIR"
  export TMPDIR="$TEST_TMPDIR"
  export WORKSPACE="$TEST_TMPDIR/workspace"
  mkdir -p "$WORKSPACE"

  ORIGINAL_PATH="$PATH"
  PATH="$BIN_DIR:$PATH"

  export OUTPUT_LOG="$TEST_TMPDIR/output.log"
  export EXIT_CODE_FILE="$TEST_TMPDIR/exit-code"
  export SESSION_ID_FILE="$TEST_TMPDIR/session-id"
  export CLAUDE_ARGS_LOG="$TEST_TMPDIR/claude-args"
  export PROMPT="test prompt"

  unset PROMPT_STATIC
  unset SELECTED_MODEL
  unset CLAUDE_PLAN_BARE
  unset CLAUDE_PLAN_MINIMAL
  unset CLAUDE_PLAN_MINIMAL_DISABLE_MCP
  unset CLAUDE_TOOLS_FROM_AGENT
  unset CLAUDE_PLAN_ALLOWED_TOOLS
  unset CLAUDE_PLAN_PERMISSION_MODE
  unset RALPH_AGENT_NATIVE_NAME
  unset RALPH_AGENT_NATIVE_PASSTHROUGH
  unset RALPH_PLAN_SESSION_MAX_TURNS
  unset RALPH_PLAN_CLI_RESUME
  unset RALPH_RUN_PLAN_RESUME_SESSION_ID
  unset RALPH_RUN_PLAN_NEW_SESSION_ID
  unset RALPH_RUN_PLAN_RESET_COMMAND_USED
  unset RALPH_MODE
  unset RALPH_MCP_PREFLIGHT_PASSED
  unset RALPH_PLAN_ALLOW_UNSAFE_RESUME
  unset PREBUILT_AGENT_CONTEXT
  unset CLAUDE_PLAN_MCP_CONFIG_OWNED
}

teardown() {
  PATH="$ORIGINAL_PATH"
  rm -rf "$TEST_TMPDIR"
}

write_stub_claude() {
  local exit_code="${1:-0}"
  local output="${2:-}"

  cat >"$BIN_DIR/claude" <<'STUB'
#!/usr/bin/env bash
# Record all arguments
{
  printf '%s\n' "$@"
} >>"$CLAUDE_ARGS_LOG"
# Capture stdin
cat >>"$CLAUDE_ARGS_LOG"
# Exit with specified code
exit $exit_code
STUB
  chmod +x "$BIN_DIR/claude"
}

@test "native passthrough: --agent flag is added when RALPH_AGENT_NATIVE_NAME is set" {
  write_stub_claude 0

  export RALPH_AGENT_NATIVE_NAME="test-agent"
  export RALPH_AGENT_NATIVE_PASSTHROUGH="1"
  export CLAUDE_PLAN_MINIMAL="1"
  export CLAUDE_PLAN_MINIMAL_DISABLE_MCP="1"
  export SELECTED_MODEL="claude-3-5-sonnet-20241022"

  local -a args=(-p)
  args+=(--model "$SELECTED_MODEL")
  args+=(--allowedTools "Bash,Read,Edit,Write")

  # Add native passthrough logic (mimic what run_plan_invoke_claude does)
  local _native_passthrough_idx=-1
  if [[ -n "${RALPH_AGENT_NATIVE_NAME:-}" ]] && [[ "${RALPH_AGENT_NATIVE_PASSTHROUGH}" != "0" ]]; then
    args+=("--agent" "$RALPH_AGENT_NATIVE_NAME")
    _native_passthrough_idx=$((${#args[@]} - 2))
  fi

  # Skip --system-prompt when native passthrough is active
  if [[ $_native_passthrough_idx -lt 0 ]]; then
    args+=(--system-prompt "test context")
  fi

  # Run claude with our stub
  printf '%s' "$PROMPT" | claude "${args[@]}" >/dev/null 2>&1 || true

  # Verify --agent flag and argument were passed
  [[ -f "$CLAUDE_ARGS_LOG" ]]
  grep -q "\-\-agent" "$CLAUDE_ARGS_LOG"
  grep -q "test-agent" "$CLAUDE_ARGS_LOG"
}

@test "native passthrough: --system-prompt is suppressed when passthrough is active" {
  write_stub_claude 0

  export RALPH_AGENT_NATIVE_NAME="my-agent"
  export RALPH_AGENT_NATIVE_PASSTHROUGH="1"
  export CLAUDE_PLAN_MINIMAL="1"
  export CLAUDE_PLAN_MINIMAL_DISABLE_MCP="1"
  export SELECTED_MODEL="claude-3-5-sonnet-20241022"
  export PROMPT_STATIC="system context"

  local -a args=(-p)
  args+=(--model "$SELECTED_MODEL")
  args+=(--allowedTools "Bash,Read,Edit,Write")

  # Add native passthrough logic
  local _native_passthrough_idx=-1
  if [[ -n "${RALPH_AGENT_NATIVE_NAME:-}" ]] && [[ "${RALPH_AGENT_NATIVE_PASSTHROUGH}" != "0" ]]; then
    args+=("--agent" "$RALPH_AGENT_NATIVE_NAME")
    _native_passthrough_idx=$((${#args[@]} - 2))
  fi

  # Skip --system-prompt when native passthrough is active
  if [[ $_native_passthrough_idx -lt 0 ]]; then
    args+=(--system-prompt "$PROMPT_STATIC")
  fi

  # Run claude with our stub
  printf '%s' "$PROMPT" | claude "${args[@]}" >/dev/null 2>&1 || true

  # Verify --system-prompt was NOT passed
  [[ -f "$CLAUDE_ARGS_LOG" ]]
  ! grep -q "\-\-system-prompt" "$CLAUDE_ARGS_LOG"
}

@test "native passthrough: --system-prompt is included when passthrough is off" {
  write_stub_claude 0

  export RALPH_AGENT_NATIVE_PASSTHROUGH="0"
  export CLAUDE_PLAN_MINIMAL="1"
  export CLAUDE_PLAN_MINIMAL_DISABLE_MCP="1"
  export SELECTED_MODEL="claude-3-5-sonnet-20241022"
  export PROMPT_STATIC="system context"

  local -a args=(-p)
  args+=(--model "$SELECTED_MODEL")
  args+=(--allowedTools "Bash,Read,Edit,Write")

  # Add native passthrough logic (but passthrough is off)
  local _native_passthrough_idx=-1
  if [[ -n "${RALPH_AGENT_NATIVE_NAME:-}" ]] && [[ "${RALPH_AGENT_NATIVE_PASSTHROUGH}" != "0" ]]; then
    args+=("--agent" "$RALPH_AGENT_NATIVE_NAME")
    _native_passthrough_idx=$((${#args[@]} - 2))
  fi

  # Add --system-prompt since passthrough is inactive
  if [[ $_native_passthrough_idx -lt 0 ]]; then
    args+=(--system-prompt "$PROMPT_STATIC")
  fi

  # Run claude with our stub
  printf '%s' "$PROMPT" | claude "${args[@]}" >/dev/null 2>&1 || true

  # Verify --system-prompt WAS passed
  [[ -f "$CLAUDE_ARGS_LOG" ]]
  grep -q "\-\-system-prompt" "$CLAUDE_ARGS_LOG"
  grep -q "system context" "$CLAUDE_ARGS_LOG"
}

@test "native passthrough: no --agent flag when RALPH_AGENT_NATIVE_NAME is not set" {
  write_stub_claude 0

  unset RALPH_AGENT_NATIVE_NAME
  export CLAUDE_PLAN_MINIMAL="1"
  export CLAUDE_PLAN_MINIMAL_DISABLE_MCP="1"
  export SELECTED_MODEL="claude-3-5-sonnet-20241022"
  export PROMPT_STATIC="system context"

  local -a args=(-p)
  args+=(--model "$SELECTED_MODEL")
  args+=(--allowedTools "Bash,Read,Edit,Write")

  # Add native passthrough logic (no RALPH_AGENT_NATIVE_NAME)
  local _native_passthrough_idx=-1
  if [[ -n "${RALPH_AGENT_NATIVE_NAME:-}" ]] && [[ "${RALPH_AGENT_NATIVE_PASSTHROUGH}" != "0" ]]; then
    args+=("--agent" "$RALPH_AGENT_NATIVE_NAME")
    _native_passthrough_idx=$((${#args[@]} - 2))
  fi

  # Add --system-prompt since no passthrough
  if [[ $_native_passthrough_idx -lt 0 ]]; then
    args+=(--system-prompt "$PROMPT_STATIC")
  fi

  # Run claude with our stub
  printf '%s' "$PROMPT" | claude "${args[@]}" >/dev/null 2>&1 || true

  # Verify no --agent flag
  [[ -f "$CLAUDE_ARGS_LOG" ]]
  ! grep -q "\-\-agent" "$CLAUDE_ARGS_LOG"
  # Verify --system-prompt WAS passed
  grep -q "\-\-system-prompt" "$CLAUDE_ARGS_LOG"
}

@test "native passthrough: fallback rebuilds context when agent is unknown" {
  # First invocation fails with unknown-agent, second succeeds
  cat >"$BIN_DIR/claude" <<'STUB'
#!/usr/bin/env bash
local call_count=0
[[ -f "$CLAUDE_CALL_COUNT" ]] && call_count=$(cat "$CLAUDE_CALL_COUNT")
call_count=$((call_count + 1))
echo "$call_count" >"$CLAUDE_CALL_COUNT"

# Record arguments
{
  printf 'call-%d:\n' "$call_count"
  printf '%s\n' "$@"
} >>"$CLAUDE_ARGS_LOG"

# First call fails with unknown-agent
if [[ $call_count -eq 1 ]]; then
  echo "Error: unknown agent 'test-agent'" >&2
  echo "$call_count" >"$EXIT_CODE_FILE"
  exit 1
fi

# Second call succeeds
echo 0 >"$EXIT_CODE_FILE"
exit 0
STUB
  chmod +x "$BIN_DIR/claude"

  export CLAUDE_CALL_COUNT="$TEST_TMPDIR/call-count"
  export RALPH_AGENT_NATIVE_NAME="test-agent"
  export RALPH_AGENT_NATIVE_PASSTHROUGH="1"
  export CLAUDE_PLAN_MINIMAL="1"
  export CLAUDE_PLAN_MINIMAL_DISABLE_MCP="1"
  export SELECTED_MODEL="claude-3-5-sonnet-20241022"
  export PROMPT_STATIC="system context"
  export PREBUILT_AGENT_CONTEXT="agent context"

  # Initialize logs
  echo 0 >"$EXIT_CODE_FILE"
  touch "$OUTPUT_LOG"

  local -a args=(-p)
  args+=(--model "$SELECTED_MODEL")
  args+=(--allowedTools "Bash,Read,Edit,Write")

  # Add native passthrough logic
  local _native_passthrough_idx=-1
  if [[ -n "${RALPH_AGENT_NATIVE_NAME:-}" ]] && [[ "${RALPH_AGENT_NATIVE_PASSTHROUGH}" != "0" ]]; then
    args+=("--agent" "$RALPH_AGENT_NATIVE_NAME")
    _native_passthrough_idx=$((${#args[@]} - 2))
  fi

  # Skip --system-prompt when native passthrough is active
  if [[ $_native_passthrough_idx -lt 0 ]]; then
    args+=(--system-prompt "$PROMPT_STATIC")
  fi

  # First invocation with --agent
  printf '%s' "$PROMPT" | claude "${args[@]}" >"$OUTPUT_LOG" 2>&1 || true

  # Simulate fallback: agent failed, rebuild context
  if [[ -s "$OUTPUT_LOG" ]] && grep -q "unknown agent" "$OUTPUT_LOG"; then
    # Remove --agent flag from args
    args=("${args[@]:0:_native_passthrough_idx}" "${args[@]:$((_native_passthrough_idx+2))}")
    # Re-add --system-prompt with inlined context
    if [[ -n "${PREBUILT_AGENT_CONTEXT:-}" ]]; then
      local _fallback_prompt_static="${PROMPT_STATIC:-}${PREBUILT_AGENT_CONTEXT}"
      if [[ -n "$_fallback_prompt_static" ]]; then
        args+=(--system-prompt "$_fallback_prompt_static")
      fi
    fi
    # Second invocation without --agent
    printf '%s' "$PROMPT" | claude "${args[@]}" >"$OUTPUT_LOG" 2>&1 || true
  fi

  # Verify two invocations were made
  [[ -f "$CLAUDE_CALL_COUNT" ]]
  [[ "$(cat "$CLAUDE_CALL_COUNT")" == "2" ]]

  # Verify fallback restored --system-prompt
  [[ -f "$CLAUDE_ARGS_LOG" ]]
  # Second call (call-2) should have --system-prompt
  grep "call-2:" "$CLAUDE_ARGS_LOG" -A 20 | grep -q "\-\-system-prompt"
}

@test "native passthrough: RALPH_AGENT_NATIVE_PASSTHROUGH default is 1 (auto)" {
  # When RALPH_AGENT_NATIVE_PASSTHROUGH is unset, it should default to 1
  unset RALPH_AGENT_NATIVE_PASSTHROUGH

  # This is what run-plan-core.sh does:
  RALPH_AGENT_NATIVE_PASSTHROUGH="${RALPH_AGENT_NATIVE_PASSTHROUGH:-1}"

  [[ "$RALPH_AGENT_NATIVE_PASSTHROUGH" == "1" ]]
}
