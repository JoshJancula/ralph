#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

POLICY_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-policy.sh"
RESULT_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-result.sh"
TOOLS_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-tools.sh"
LOGGING_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-logging.sh"
UPSTREAM_SCRIPT="$REPO_ROOT/bundle/.ralph/mcp-server.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  WS="$TEST_TMPDIR/workspace"
  mkdir -p "$WS"
  export RALPH_MCP_WORKSPACE="$WS"
  export RALPH_PLAN_KEY="obs-test"
  export RALPH_PLAN_WORKSPACE_ROOT="$TEST_TMPDIR"
  POLICY_JSON='{"name":"obs-test","proxyOwnedTools":{"enabled":true,"allowAllCommands":true,"allowShellOperators":true,"shellTimeoutSeconds":600,"maxShellOutputBytes":65536},"resultByteCap":65536,"toolResultByteCaps":{"ralph_proxy_shell":65536}}'
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

plan_log_path() {
  printf '%s/.ralph-workspace/logs/%s/mcp.log\n' "$TEST_TMPDIR" "$RALPH_PLAN_KEY"
}

invoke_tool_with_plan_log() {
  local tool_name="$1"
  local args_json="$2"
  shift 2
  env \
    RALPH_MCP_WORKSPACE="$WS" \
    RALPH_PLAN_KEY="$RALPH_PLAN_KEY" \
    RALPH_PLAN_WORKSPACE_ROOT="$TEST_TMPDIR" \
    RALPH_MCP_PROXY_POLICY_INLINE="$POLICY_JSON" \
    "$@" \
    bash -c '
      source "$1"
      source "$2"
      source "$3"
      source "$4"
      ralph_mcp_proxy_load_policy "$5" "$6" >/dev/null || exit 1
      ralph_mcp_proxy_call_owned_tool "$7" "$8" "$9"
    ' _ "$POLICY_LIB" "$RESULT_LIB" "$TOOLS_LIB" "$LOGGING_LIB" \
      "$REPO_ROOT" "$UPSTREAM_SCRIPT" "$WS" "$tool_name" "$args_json"
}

@test "plan-scoped log file is created when RALPH_PLAN_KEY and RALPH_PLAN_WORKSPACE_ROOT are set" {
  command -v jq >/dev/null || skip "jq required"

  invoke_tool_with_plan_log ralph_proxy_shell "$(jq -nc --arg command 'echo hello' '{command:$command}')"

  [[ -f "$(plan_log_path)" ]] || fail "per-plan MCP log not created at $(plan_log_path)"
}

@test "plan log contains at least one log line after a tool call" {
  command -v jq >/dev/null || skip "jq required"

  invoke_tool_with_plan_log ralph_proxy_shell "$(jq -nc --arg command 'echo world' '{command:$command}')"

  local log_path
  log_path="$(plan_log_path)"
  [[ -f "$log_path" ]] || skip "plan log not created"
  [[ -s "$log_path" ]] || fail "plan log is empty after tool call"
}

@test "timeout-handoff is recorded in plan log when sync cap fires" {
  command -v jq >/dev/null || skip "jq required"
  command -v perl >/dev/null || skip "perl required for timeout fallback"

  invoke_tool_with_plan_log ralph_proxy_shell \
    "$(jq -nc --arg command 'sleep 10' '{command:$command}')" \
    RALPH_PROXY_SHELL_SYNC_TIMEOUT_SECONDS=1

  local log_path
  log_path="$(plan_log_path)"
  [[ -f "$log_path" ]] || fail "plan log not created"
  grep -q "timeout-handoff" "$log_path" || fail "timeout-handoff marker not found in plan log"
}

@test "plan log is written to the path derived from RALPH_PLAN_WORKSPACE_ROOT" {
  command -v jq >/dev/null || skip "jq required"

  local expected_log
  expected_log="${TEST_TMPDIR}/.ralph-workspace/logs/${RALPH_PLAN_KEY}/mcp.log"

  invoke_tool_with_plan_log ralph_proxy_shell "$(jq -nc --arg command 'ls' '{command:$command}')"

  [[ -f "$expected_log" ]] || fail "expected log not at $expected_log"
}

@test "ralph_mcp_proxy_plan_log_path returns plan-scoped path from env" {
  command -v jq >/dev/null || skip "jq required"

  local result
  result="$(
    env \
      RALPH_PLAN_KEY="my-plan" \
      RALPH_PLAN_WORKSPACE_ROOT="/tmp/ws" \
    bash -c '
      source "$1"
      ralph_mcp_proxy_plan_log_path
    ' _ "$LOGGING_LIB"
  )"

  [[ "$result" == "/tmp/ws/.ralph-workspace/logs/my-plan/mcp.log" ]] \
    || fail "unexpected plan log path: $result"
}

@test "ralph_mcp_proxy_plan_log_path returns nothing when RALPH_PLAN_KEY is unset" {
  command -v jq >/dev/null || skip "jq required"

  local result
  result="$(
    env -u RALPH_PLAN_KEY \
      RALPH_PLAN_WORKSPACE_ROOT="/tmp/ws" \
    bash -c '
      source "$1"
      ralph_mcp_proxy_plan_log_path
    ' _ "$LOGGING_LIB"
  )"

  [[ -z "$result" ]]
}
