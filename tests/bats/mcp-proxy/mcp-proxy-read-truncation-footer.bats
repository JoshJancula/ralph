#!/usr/bin/env bats
# Honest truncation footer for ralph_proxy_read on the
# RALPH_MCP_EXPLORATION_RESULT_COMPACT=0 fast path (COMPACTION-CACHE-AUDIT a1).

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

POLICY_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-policy.sh"
RESULT_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-result.sh"
TOOLS_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-tools.sh"
UPSTREAM_SCRIPT="$REPO_ROOT/bundle/.ralph/mcp-server.sh"

setup() {
  WS="$(mktemp -d)"
  export RALPH_MCP_WORKSPACE="$WS"
  export RALPH_PLAN_KEY="plan-read-truncation-footer"
  # Default exploration path: return the gathered window inline (no envelope).
  unset RALPH_MCP_EXPLORATION_RESULT_COMPACT
  export RALPH_MCP_EXPLORATION_RESULT_COMPACT=0
  unset RALPH_MCP_PROXY_POLICY_INLINE
  unset RALPH_MCP_PROXY_POLICY_FILE
  unset RALPH_MCP_PROXY_POLICY
}

teardown() {
  rm -rf "$WS"
}

invoke_read() {
  local args_json="$1"
  env \
    RALPH_MCP_WORKSPACE="$WS" \
    RALPH_PLAN_KEY="$RALPH_PLAN_KEY" \
    RALPH_MCP_EXPLORATION_RESULT_COMPACT=0 \
    RALPH_MCP_PROXY_OWNED_TOOLS_FORCE=1 \
    bash -c '
      source "$1"
      source "$2"
      source "$3"
      ralph_mcp_proxy_load_policy "$4" "$5" || exit 1
      ralph_mcp_proxy_call_owned_tool "$4" "ralph_proxy_read" "$6"
    ' _ "$POLICY_LIB" "$RESULT_LIB" "$TOOLS_LIB" "$WS" "$UPSTREAM_SCRIPT" "$args_json"
}

seed_file() {
  awk 'BEGIN { for (i = 1; i <= 400; i++) printf "line-%d\n", i }' >"$WS/four-hundred.txt"
}

response_text() {
  jq -r '.content[0].text // empty'
}

@test "read-truncation-footer: default policy caps at 250 of 400 with continue offset" {
  seed_file
  local response text footer
  response="$(invoke_read "$(jq -nc '{path:"four-hundred.txt"}')")"
  printf '%s\n' "$response" | jq -e '.isError != true'
  text="$(printf '%s\n' "$response" | response_text)"
  footer='[ralph_proxy_read: lines 1-250 of 400 shown (policy cap 250); continue with offset=251]'
  [[ "$text" == *"$footer" ]]
  [[ "$(printf '%s\n' "$text" | tail -n1)" == "$footer" ]]
  # Delivered window is the first 250 lines, then the footer.
  [[ "$(printf '%s\n' "$text" | grep -c '^line-')" -eq 250 ]]
  [[ "$(printf '%s\n' "$text" | sed -n '1p')" == "line-1" ]]
  [[ "$(printf '%s\n' "$text" | sed -n '250p')" == "line-250" ]]
}

@test "read-truncation-footer: caller limit=20 delivers the requested window with no footer" {
  seed_file
  local response text
  response="$(invoke_read "$(jq -nc '{path:"four-hundred.txt", limit:20}')")"
  printf '%s\n' "$response" | jq -e '.isError != true'
  text="$(printf '%s\n' "$response" | response_text)"
  [[ "$text" != *"[ralph_proxy_read:"* ]]
  [[ "$(printf '%s\n' "$text" | grep -c '^line-')" -eq 20 ]]
  [[ "$(printf '%s\n' "$text" | tail -n1)" == "line-20" ]]
}
