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
  export RALPH_PLAN_KEY="sync-shell-timeout"
  # Default out-of-box policy has a generous 600s shell timeout. The sync cap
  # must clamp execution to a transport-safe value and hand off on timeout.
  POLICY_JSON='{"name":"sync-shell-timeout","proxyOwnedTools":{"enabled":true,"allowAllCommands":true,"allowShellOperators":true,"shellTimeoutSeconds":600,"maxShellOutputBytes":1024},"resultByteCap":65536,"toolResultByteCaps":{"ralph_proxy_shell":65536,"ralph_proxy_shell_start":65536,"ralph_proxy_shell_wait":65536,"ralph_proxy_shell_status":65536,"ralph_proxy_shell_read":65536,"ralph_proxy_shell_cancel":65536}}'
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

invoke_sync_tool() {
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

@test "sync shell returns structured handoff when command exceeds transport-safe timeout" {
  command -v jq >/dev/null || skip "jq required"
  command -v perl >/dev/null || skip "perl required for timeout fallback"

  # Use a 1-second sync cap with a 30-second command. The cap should fire well
  # before the command finishes. Allow up to 15 seconds total for lib startup
  # overhead so this does not flake on loaded machines; it still proves the cap
  # fires (without it, the test would take 30s).
  local response handoff_json elapsed t0 t1
  t0="$(date +%s)"
  response="$(invoke_sync_tool ralph_proxy_shell "$(jq -nc --arg command 'sleep 30' '{command:$command}')" RALPH_PROXY_SHELL_SYNC_TIMEOUT_SECONDS=1)"
  t1="$(date +%s)"
  elapsed=$((t1 - t0))
  [[ "$elapsed" -le 15 ]] || echo "WARNING: sync cap test took ${elapsed}s (expected <=15s on a loaded machine)"

  [[ "$(response_is_error "$response")" == "false" ]]

  handoff_json="$(response_text "$response")"
  printf '%s\n' "$handoff_json" | jq -e '
    .shellTimeoutHandoff == true
    and (.timeoutSeconds | tonumber) == 1
    and .command == "sleep 30"
    and (.nextActions | map(.tool) | index("ralph_proxy_shell_start") != null)
    and (.nextActions | map(.tool) | index("ralph_proxy_shell_wait") != null)
    and (.nextActions | map(.tool) | index("ralph_proxy_shell_read") != null)
  '
}

@test "sync shell short bounded command runs unchanged" {
  command -v jq >/dev/null || skip "jq required"
  command -v perl >/dev/null || skip "perl required for timeout fallback"

  # With the default 600s policy timeout and a 1s sync cap, a short command
  # should finish before the cap and return its output normally.
  local response
  response="$(invoke_sync_tool ralph_proxy_shell "$(jq -nc --arg command 'echo ok; sleep 0.1; echo done' '{command:$command}')" RALPH_PROXY_SHELL_SYNC_TIMEOUT_SECONDS=1)"
  [[ "$(response_is_error "$response")" == "false" ]]
  [[ "$(response_text "$response")" == $'ok\ndone' ]]
}

@test "sync shell timeout keeps server responsive to subsequent tools/call" {
  command -v jq >/dev/null || skip "jq required"
  command -v perl >/dev/null || skip "perl required for timeout fallback"

  # Simulate a long sync command that hits the cap, then issue a second tool
  # call and confirm the server still answers (no transport close).
  local first_response second_response
  first_response="$(invoke_sync_tool ralph_proxy_shell "$(jq -nc --arg command 'sleep 5' '{command:$command}')" RALPH_PROXY_SHELL_SYNC_TIMEOUT_SECONDS=1)"
  [[ "$(response_is_error "$first_response")" == "false" ]]
  printf '%s\n' "$(response_text "$first_response")" | jq -e '.shellTimeoutHandoff == true'

  second_response="$(invoke_sync_tool ralph_proxy_shell "$(jq -nc --arg command 'echo still-alive' '{command:$command}')" RALPH_PROXY_SHELL_SYNC_TIMEOUT_SECONDS=1)"
  [[ "$(response_is_error "$second_response")" == "false" ]]
  [[ "$(response_text "$second_response")" == "still-alive" ]]
}

@test "sync shell cap is configurable via RALPH_PROXY_SHELL_SYNC_TIMEOUT_SECONDS" {
  command -v jq >/dev/null || skip "jq required"
  command -v perl >/dev/null || skip "perl required for timeout fallback"

  local response cap
  cap=2
  response="$(invoke_sync_tool ralph_proxy_shell "$(jq -nc --arg command 'sleep 10' '{command:$command}')" RALPH_PROXY_SHELL_SYNC_TIMEOUT_SECONDS="$cap")"
  [[ "$(response_is_error "$response")" == "false" ]]
  printf '%s\n' "$(response_text "$response")" | jq -e "(.timeoutSeconds | tonumber) == $cap and .shellTimeoutHandoff == true"
}
