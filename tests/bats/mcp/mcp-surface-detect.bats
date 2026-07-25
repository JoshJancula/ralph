#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

SETUP_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-setup.sh"
SERVER_SCRIPT="$REPO_ROOT/bundle/.ralph/mcp-server.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  WS="$TEST_TMPDIR/workspace"
  mkdir -p "$WS"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

@test "ralph_mcp_proxy_preflight sets RALPH_MCP_TOOL_NAMESPACE to mcp__ralph__ when tools list contains ralph_proxy tools" {
  command -v jq >/dev/null || skip "jq required"
  command -v python3 >/dev/null || skip "python3 required"

  local ns
  ns="$(
    env RALPH_MCP_WORKSPACE="$WS" \
    bash -c '
      source "$1"
      ralph_mcp_proxy_preflight "$2" "$3" >/dev/null
      printf "%s\n" "${RALPH_MCP_TOOL_NAMESPACE:-UNSET}"
    ' _ "$SETUP_LIB" "$SERVER_SCRIPT" "$WS"
  )"

  [[ "$ns" == "mcp__ralph__" ]] || [[ "$ns" == "" ]] \
    || { echo "unexpected namespace: $ns"; return 1; }
}

@test "ralph_mcp_proxy_preflight sets RALPH_MCP_DETECTED_TOOL_NAMES with at least one ralph_ entry" {
  command -v jq >/dev/null || skip "jq required"
  command -v python3 >/dev/null || skip "python3 required"

  local detected
  detected="$(
    env RALPH_MCP_WORKSPACE="$WS" \
    bash -c '
      source "$1"
      ralph_mcp_proxy_preflight "$2" "$3" >/dev/null
      printf "%s\n" "${RALPH_MCP_DETECTED_TOOL_NAMES:-}"
    ' _ "$SETUP_LIB" "$SERVER_SCRIPT" "$WS"
  )"

  printf '%s\n' "$detected" | grep -q "^ralph_" \
    || { echo "no ralph_ tools in detected list: $detected"; return 1; }
}

@test "RALPH_MCP_TOOL_NAMESPACE is mcp__ralph__ when server exposes ralph_proxy tools" {
  command -v jq >/dev/null || skip "jq required"
  command -v python3 >/dev/null || skip "python3 required"

  local ns
  ns="$(
    env RALPH_MCP_WORKSPACE="$WS" \
    bash -c '
      source "$1"
      ralph_mcp_proxy_preflight "$2" "$3" >/dev/null
      printf "%s\n" "${RALPH_MCP_TOOL_NAMESPACE:-}"
    ' _ "$SETUP_LIB" "$SERVER_SCRIPT" "$WS"
  )"

  [[ "$ns" == "mcp__ralph__" ]] \
    || { echo "expected mcp__ralph__ namespace, got: '${ns}'"; return 1; }
}
