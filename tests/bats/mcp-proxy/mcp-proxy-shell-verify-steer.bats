#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

POLICY_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-policy.sh"
RESULT_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-result.sh"
TOOLS_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-tools.sh"
UPSTREAM_SCRIPT="$REPO_ROOT/bundle/.ralph/mcp-server.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  WS="$TEST_TMPDIR/workspace"
  mkdir -p "$WS"
  export RALPH_MCP_WORKSPACE="$WS"
  export RALPH_PLAN_KEY="verify-steer-test"
  POLICY_JSON='{"name":"verify-steer","proxyOwnedTools":{"enabled":true,"allowAllCommands":true,"allowShellOperators":true,"shellTimeoutSeconds":600,"maxShellOutputBytes":65536},"resultByteCap":65536,"toolResultByteCaps":{"ralph_proxy_shell":65536}}'
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

invoke_tool() {
  local tool_name="$1"
  local args_json="$2"
  shift 2
  env \
    RALPH_MCP_WORKSPACE="$WS" \
    RALPH_PLAN_KEY="$RALPH_PLAN_KEY" \
    RALPH_MCP_PROXY_POLICY_INLINE="$POLICY_JSON" \
    "$@" \
    bash -c '
      source "$1"
      source "$2"
      source "$3"
      ralph_mcp_proxy_load_policy "$4" "$5" >/dev/null || exit 1
      ralph_mcp_proxy_call_owned_tool "$6" "$7" "$8"
    ' _ "$POLICY_LIB" "$RESULT_LIB" "$TOOLS_LIB" "$REPO_ROOT" "$UPSTREAM_SCRIPT" "$WS" "$tool_name" "$args_json"
}

extract_json_object() {
  python3 -c '
import sys
text = sys.stdin.read()
start = text.find("{")
if start == -1:
    sys.exit(1)
depth = 0
for idx in range(start, len(text)):
    ch = text[idx]
    if ch == "{":
        depth += 1
    elif ch == "}":
        depth -= 1
        if depth == 0:
            sys.stdout.write(text[start:idx+1])
            sys.exit(0)
sys.exit(1)
' || return 1
}

response_text() {
  printf '%s\n' "$1" | extract_json_object | jq -r '.content[0].text'
}

response_is_error() {
  printf '%s\n' "$1" | extract_json_object | jq -r '.isError'
}

@test "npm test is steered to async shell" {
  command -v jq >/dev/null || skip "jq required"

  local response guidance
  response="$(invoke_tool ralph_proxy_shell "$(jq -nc --arg command 'npm test' '{command:$command}')")"
  [[ "$(response_is_error "$response")" == "false" ]]
  guidance="$(response_text "$response")"
  printf '%s\n' "$guidance" | jq -e '.syncShellVerificationSteered == true'
  printf '%s\n' "$guidance" | jq -e '.nextActions | map(.tool) | index("ralph_proxy_shell_start") != null'
}

@test "npm run lint is steered to async shell" {
  command -v jq >/dev/null || skip "jq required"

  local response guidance
  response="$(invoke_tool ralph_proxy_shell "$(jq -nc --arg command 'npm run lint' '{command:$command}')")"
  [[ "$(response_is_error "$response")" == "false" ]]
  guidance="$(response_text "$response")"
  printf '%s\n' "$guidance" | jq -e '.syncShellVerificationSteered == true'
}

@test "yarn test is steered to async shell" {
  command -v jq >/dev/null || skip "jq required"

  local response guidance
  response="$(invoke_tool ralph_proxy_shell "$(jq -nc --arg command 'yarn test' '{command:$command}')")"
  [[ "$(response_is_error "$response")" == "false" ]]
  guidance="$(response_text "$response")"
  printf '%s\n' "$guidance" | jq -e '.syncShellVerificationSteered == true'
}

@test "short exploratory commands run unchanged and are not steered" {
  command -v jq >/dev/null || skip "jq required"

  local response text
  response="$(invoke_tool ralph_proxy_shell "$(jq -nc --arg command 'echo not-steered' '{command:$command}')")"
  [[ "$(response_is_error "$response")" == "false" ]]
  text="$(response_text "$response")"
  [[ "$text" != *"syncShellVerificationSteered"* ]]
}

@test "echo command is not steered" {
  command -v jq >/dev/null || skip "jq required"

  local response text
  response="$(invoke_tool ralph_proxy_shell "$(jq -nc --arg command 'echo hello-world' '{command:$command}')")"
  [[ "$(response_is_error "$response")" == "false" ]]
  text="$(response_text "$response")"
  [[ "$text" == "hello-world" ]]
}

@test "RALPH_PROXY_SHELL_VERIFY_STEER=0 disables heuristic and allows npm test to run" {
  command -v jq >/dev/null || skip "jq required"

  # With steering disabled, npm test is allowed to attempt to run (it may
  # fail because npm is not in the workspace, but it should NOT return a
  # syncShellVerificationSteered response).
  local response text
  response="$(invoke_tool ralph_proxy_shell "$(jq -nc --arg command 'npm test' '{command:$command}')" RALPH_PROXY_SHELL_VERIFY_STEER=0)"
  text="$(response_text "$response")"
  [[ "$text" != *"syncShellVerificationSteered"* ]]
}

@test "npm test with explicit timeoutSeconds bypasses verify steer" {
  command -v jq >/dev/null || skip "jq required"

  local response text
  response="$(invoke_tool ralph_proxy_shell "$(jq -nc --arg command 'npm test' --argjson timeoutSeconds 10 '{command:$command, timeoutSeconds:$timeoutSeconds}')")"
  text="$(response_text "$response")"
  [[ "$text" != *"syncShellVerificationSteered"* ]]
}
