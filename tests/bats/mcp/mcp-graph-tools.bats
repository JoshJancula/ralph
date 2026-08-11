#!/usr/bin/env bats
# Tests for ralph_graph_run and ralph_graph_status MCP tools.
#
# Verifies:
#   - Both tools appear in the tools/list catalog with valid schemas.
#   - The tools/list response is well-formed and contains no nextCursor key
#     (a null nextCursor causes Claude to drop the entire tool catalog).

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

SERVER_SCRIPT="$REPO_ROOT/bundle/.ralph/mcp-server.sh"

# Send a single JSON-RPC request to the server and capture the response.
_mcp_request() {
  local payload="$1"
  local response
  response="$(
    printf '%s\n' "$payload" \
      | bash "$SERVER_SCRIPT" 2>/dev/null \
      | head -n 1
  )"
  printf '%s' "$response"
}

_tools_list_response() {
  local init_payload='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"test","version":"1.0"}}}'
  local list_payload='{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
  printf '%s\n%s\n' "$init_payload" "$list_payload" \
    | bash "$SERVER_SCRIPT" 2>/dev/null \
    | grep '"id":2'
}

setup() {
  command -v jq >/dev/null || skip "jq required"
  [ -f "$SERVER_SCRIPT" ] || skip "mcp-server.sh missing"
  TEST_TMPDIR="$(mktemp -d)"
  WS="$TEST_TMPDIR/workspace"
  mkdir -p "$WS"
  export RALPH_MCP_WORKSPACE="$WS"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

@test "ralph_graph_run appears in tools/list catalog" {
  local response
  response="$(_tools_list_response)"
  [ -n "$response" ] || { echo "empty tools/list response"; return 1; }

  local found
  found="$(printf '%s' "$response" | jq -r '.result.tools[] | select(.name == "ralph_graph_run") | .name' 2>/dev/null)"
  [ "$found" = "ralph_graph_run" ] \
    || { echo "ralph_graph_run not found in catalog; response: $response"; return 1; }
}

@test "ralph_graph_status appears in tools/list catalog" {
  local response
  response="$(_tools_list_response)"
  [ -n "$response" ] || { echo "empty tools/list response"; return 1; }

  local found
  found="$(printf '%s' "$response" | jq -r '.result.tools[] | select(.name == "ralph_graph_status") | .name' 2>/dev/null)"
  [ "$found" = "ralph_graph_status" ] \
    || { echo "ralph_graph_status not found in catalog; response: $response"; return 1; }
}

@test "ralph_graph_run has valid inputSchema with required workspace and plan_path" {
  local response
  response="$(_tools_list_response)"
  [ -n "$response" ] || { echo "empty tools/list response"; return 1; }

  local schema
  schema="$(printf '%s' "$response" | jq -c '.result.tools[] | select(.name == "ralph_graph_run") | .inputSchema' 2>/dev/null)"
  [ -n "$schema" ] || { echo "no inputSchema for ralph_graph_run"; return 1; }

  local schema_type
  schema_type="$(printf '%s' "$schema" | jq -r '.type')"
  [ "$schema_type" = "object" ] \
    || { echo "inputSchema type is $schema_type, expected object"; return 1; }

  local required_workspace required_plan
  required_workspace="$(printf '%s' "$schema" | jq -r '.required[] | select(. == "workspace")')"
  required_plan="$(printf '%s' "$schema" | jq -r '.required[] | select(. == "plan_path")')"
  [ "$required_workspace" = "workspace" ] \
    || { echo "workspace not in required array"; return 1; }
  [ "$required_plan" = "plan_path" ] \
    || { echo "plan_path not in required array"; return 1; }
}

@test "ralph_graph_status has valid inputSchema with required workspace and plan_path" {
  local response
  response="$(_tools_list_response)"
  [ -n "$response" ] || { echo "empty tools/list response"; return 1; }

  local schema
  schema="$(printf '%s' "$response" | jq -c '.result.tools[] | select(.name == "ralph_graph_status") | .inputSchema' 2>/dev/null)"
  [ -n "$schema" ] || { echo "no inputSchema for ralph_graph_status"; return 1; }

  local schema_type
  schema_type="$(printf '%s' "$schema" | jq -r '.type')"
  [ "$schema_type" = "object" ] \
    || { echo "inputSchema type is $schema_type, expected object"; return 1; }

  local required_workspace required_plan
  required_workspace="$(printf '%s' "$schema" | jq -r '.required[] | select(. == "workspace")')"
  required_plan="$(printf '%s' "$schema" | jq -r '.required[] | select(. == "plan_path")')"
  [ "$required_workspace" = "workspace" ] \
    || { echo "workspace not in required array"; return 1; }
  [ "$required_plan" = "plan_path" ] \
    || { echo "plan_path not in required array"; return 1; }
}

@test "tools/list response has no nextCursor key" {
  # A null nextCursor causes Claude to drop the entire tool catalog.
  local response
  response="$(_tools_list_response)"
  [ -n "$response" ] || { echo "empty tools/list response"; return 1; }

  local has_next_cursor
  has_next_cursor="$(printf '%s' "$response" | jq 'has("nextCursor") or (.result | has("nextCursor"))' 2>/dev/null)"
  [ "$has_next_cursor" = "false" ] \
    || { echo "tools/list response contains nextCursor key; response: $response"; return 1; }
}

@test "tools/list response is valid JSON with a tools array" {
  local response
  response="$(_tools_list_response)"
  [ -n "$response" ] || { echo "empty tools/list response"; return 1; }

  local tools_len
  tools_len="$(printf '%s' "$response" | jq '.result.tools | length' 2>/dev/null)"
  [[ "$tools_len" =~ ^[0-9]+$ ]] \
    || { echo "tools array length is not a number: $tools_len; response: $response"; return 1; }
  [ "$tools_len" -gt 0 ] \
    || { echo "tools array is empty; response: $response"; return 1; }
}
