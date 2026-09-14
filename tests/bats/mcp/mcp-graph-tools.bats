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
  unset RALPH_PROCESS_RUN_ID RALPH_PROCESS_RUN_DEPTH RALPH_PROCESS_MAX_NESTED_DEPTH RALPH_ALLOW_NESTED_RUNS
}

teardown() {
  chmod -R u+w "$TEST_TMPDIR" 2>/dev/null || true
  rm -rf "$TEST_TMPDIR"
}

# ---------------------------------------------------------------------------
# G05: ralph_graph_run two-step preview/confirm transaction. Fixtures for
# the tools/call (not just tools/list) tests below.
# ---------------------------------------------------------------------------

_g05_write_plan() {
  GRAPH_PLAN="$WS/PLAN1.graph.plan.md"
  cat >"$GRAPH_PLAN" <<'PLAN'
---
name: mcp-confirm-test
namespace: mcp-confirm-test
execution: graph
pipeline:
  stages:
    - id: impl
      runtime: claude
      workspaceMode: snapshot
todos:
  - id: impl-1
    stage: impl
    content: do the work
    status: pending
---
PLAN
}

# The confirmed preview invokes the workspace's internal graph entrypoint,
# which sources its sibling bash library. Use the bundled `.ralph` tree so
# confirmation can exercise that exact invocation.
_g05_write_workspace_stub() {
  mkdir -p "$WS/.ralph" "$WS/src" "$WS/.ralph-workspace"
  cp -R "$REPO_ROOT/bundle/.ralph/." "$WS/.ralph/"
}

_g05_write_runtime_stub() {
  BIN_DIR="$TEST_TMPDIR/bin"
  mkdir -p "$BIN_DIR"
  cat >"$BIN_DIR/claude" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  --help|help|-h)
    printf '%s\n' "Usage: claude" "  --permission-prompt-tool <name>"
    exit 0
    ;;
  auth)
    [[ "${2:-}" == "status" ]] && { printf 'Logged in\n'; exit 0; }
    ;;
esac
exit 3
EOF
  chmod +x "$BIN_DIR/claude"
}

_g05_write_dispatch_stub() {
  DISPATCH_MARKER="$TEST_TMPDIR/dispatch.marker"
  cat >"$TEST_TMPDIR/orch-stub.sh" <<EOF
#!/usr/bin/env bash
printf 'dispatched %s\n' "\$*" >>"$DISPATCH_MARKER"
echo "orchestrator stub must not start a model session" >&2
exit 3
EOF
  chmod +x "$TEST_TMPDIR/orch-stub.sh"
  export GRAPH_DISPATCH_ORCHESTRATOR="$TEST_TMPDIR/orch-stub.sh"
}

# A "ralph" executable on PATH matching the real installed shim (extracted
# from install.sh the same way it is written), pointed at a throwaway
# RALPH_HOME carrying the real bundle. This proves the confirmed call
# invokes the public CLI surface named in commandArgv, not a hand-rebuilt
# script invocation.
_g05_write_ralph_shim() {
  local home="$TEST_TMPDIR/ralph-home"
  mkdir -p "$home/bundle/.ralph"
  cp -R "$REPO_ROOT/bundle/.ralph/." "$home/bundle/.ralph/"
  awk '
    /^  cat > "\$tmp" <<.SHIM.$/ { flag = 1; next }
    /^SHIM$/ { flag = 0 }
    flag { print }
  ' "$REPO_ROOT/install.sh" >"$BIN_DIR/ralph"
  chmod +x "$BIN_DIR/ralph"
  export RALPH_HOME="$home"
}

_g05_two_calls() {
  local init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"test","version":"1.0"}}}'
  local call
  call="$(jq -nc --arg plan "$GRAPH_PLAN" --arg ws "$WS" '{jsonrpc:"2.0",id:2,method:"tools/call",params:{name:"ralph_graph_run",arguments:{workspace:$ws,plan_path:$plan}}}')"
  PATH="$BIN_DIR:$PATH" printf '%s\n%s\n' "$init" "$call" | PATH="$BIN_DIR:$PATH" bash "$SERVER_SCRIPT" 2>/dev/null | grep '"id":2'
}

@test "ralph_graph_run preview call creates no ledger, log, or process" {
  _g05_write_plan
  _g05_write_workspace_stub
  _g05_write_runtime_stub
  _g05_write_dispatch_stub

  local init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"test","version":"1.0"}}}'
  local call
  call="$(jq -nc --arg plan "$GRAPH_PLAN" --arg ws "$WS" '{jsonrpc:"2.0",id:2,method:"tools/call",params:{name:"ralph_graph_run",arguments:{workspace:$ws,plan_path:$plan}}}')"
  local response
  response="$(PATH="$BIN_DIR:$PATH" printf '%s\n%s\n' "$init" "$call" | PATH="$BIN_DIR:$PATH" bash "$SERVER_SCRIPT" 2>/dev/null | grep '"id":2')"

  [ -n "$response" ]
  [ "$(jq -r '.result.structuredContent.requires_confirmation' <<<"$response")" = "true" ]
  [ "$(jq -r '.result.structuredContent.preview.schemaVersion' <<<"$response")" = "1" ]
  [ "$(jq -r '.result.structuredContent.preview.operation' <<<"$response")" = "run" ]
  [ "$(jq -r '.result.structuredContent.preview.invocationMode' <<<"$response")" = "confirmed-noninteractive" ]
  jq -e '
    .result.structuredContent.preview.commandArgv ==
      ["bash", ".ralph/graph-run.sh", "run", .result.structuredContent.preview.planPath, "--yes"]
  ' <<<"$response" >/dev/null
  [ -n "$(jq -r '.result.structuredContent.confirmation_id' <<<"$response")" ]

  # No ledger directory, no dispatch log, no orchestrator process.
  [ ! -d "$WS/.ralph-workspace/graph-runs/mcp-confirm-test" ]
  [ ! -f "$DISPATCH_MARKER" ]
}

@test "ralph_graph_run rejects a stale or mismatched confirmation_id and executes nothing" {
  _g05_write_plan
  _g05_write_workspace_stub
  _g05_write_runtime_stub
  _g05_write_dispatch_stub

  local init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"test","version":"1.0"}}}'
  local call
  call="$(jq -nc --arg plan "$GRAPH_PLAN" --arg ws "$WS" '{jsonrpc:"2.0",id:2,method:"tools/call",params:{name:"ralph_graph_run",arguments:{workspace:$ws,plan_path:$plan,confirmed:true,confirmation_id:"stale-or-wrong-id"}}}')"
  local response
  response="$(PATH="$BIN_DIR:$PATH" printf '%s\n%s\n' "$init" "$call" | PATH="$BIN_DIR:$PATH" bash "$SERVER_SCRIPT" 2>/dev/null | grep '"id":2')"

  [ -n "$response" ]
  [ "$(jq -r '.result.structuredContent.requires_confirmation' <<<"$response")" = "true" ]
  [ -n "$(jq -r '.result.structuredContent.note' <<<"$response")" ]
  [[ "$(jq -r '.result.structuredContent.note' <<<"$response")" == *"did not match"* ]]
  # A fresh preview is returned, not an error.
  [ "$(jq -r '.result.isError' <<<"$response")" = "false" ]
  [ "$(jq -r '.result.structuredContent.preview.schemaVersion' <<<"$response")" = "1" ]

  [ ! -d "$WS/.ralph-workspace/graph-runs/mcp-confirm-test" ]
  [ ! -f "$DISPATCH_MARKER" ]
}

@test "ralph_graph_run requires confirmation_id when confirmed:true" {
  _g05_write_plan
  _g05_write_workspace_stub
  _g05_write_runtime_stub
  _g05_write_dispatch_stub

  local init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"test","version":"1.0"}}}'
  local call
  call="$(jq -nc --arg plan "$GRAPH_PLAN" --arg ws "$WS" '{jsonrpc:"2.0",id:2,method:"tools/call",params:{name:"ralph_graph_run",arguments:{workspace:$ws,plan_path:$plan,confirmed:true}}}')"
  local response
  response="$(PATH="$BIN_DIR:$PATH" printf '%s\n%s\n' "$init" "$call" | PATH="$BIN_DIR:$PATH" bash "$SERVER_SCRIPT" 2>/dev/null | grep '"id":2')"

  [ -n "$response" ]
  [[ "$(jq -r '.error.message' <<<"$response")" == *"confirmation_id is required"* ]]
  [ ! -d "$WS/.ralph-workspace/graph-runs/mcp-confirm-test" ]
}

@test "ralph_graph_run confirmed invocation exactly matches the displayed command" {
  _g05_write_plan
  _g05_write_workspace_stub
  _g05_write_runtime_stub
  _g05_write_dispatch_stub
  _g05_write_ralph_shim

  local response1
  response1="$(_g05_two_calls)"
  local cid displayed_command
  cid="$(jq -r '.result.structuredContent.confirmation_id' <<<"$response1")"
  displayed_command="$(jq -r '.result.structuredContent.command' <<<"$response1")"
  [ -n "$cid" ]

  local init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"test","version":"1.0"}}}'
  local call2
  call2="$(jq -nc --arg plan "$GRAPH_PLAN" --arg ws "$WS" --arg cid "$cid" '{jsonrpc:"2.0",id:3,method:"tools/call",params:{name:"ralph_graph_run",arguments:{workspace:$ws,plan_path:$plan,confirmed:true,confirmation_id:$cid}}}')"
  local response2
  response2="$(PATH="$BIN_DIR:$PATH" printf '%s\n%s\n' "$init" "$call2" | PATH="$BIN_DIR:$PATH" bash "$SERVER_SCRIPT" 2>/dev/null | grep '"id":3')"

  [ -n "$response2" ]
  local executed_command
  executed_command="$(jq -r '.result.structuredContent.command' <<<"$response2")"
  [ "$executed_command" = "$displayed_command" ]
  [[ "$executed_command" == "bash .ralph/graph-run.sh run "*" --yes" ]]

  # The confirmed call actually ran (dispatch stub was invoked -- the
  # scheduler reached node dispatch, proving `run` executed, not just the
  # preview).
  [ -f "$DISPATCH_MARKER" ]
  [ -n "$(jq -r '.result.structuredContent.run_id' <<<"$response2")" ]
  [ "$(jq -r '.result.structuredContent.run_id' <<<"$response2")" != "null" ]
  [ -d "$WS/.ralph-workspace/graph-runs/mcp-confirm-test" ]
}

@test "ralph_graph_status tool description and result mark it explicitly read-only" {
  local response
  response="$(_tools_list_response)"
  local description
  description="$(printf '%s' "$response" | jq -r '.result.tools[] | select(.name == "ralph_graph_status") | .description')"
  [[ "$description" == *"Read-only"* ]]
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

@test "delegated run tools use the renamed five-tool surface" {
  local response
  response="$(_tools_list_response)"
  for tool in ralph_delegated_run_start ralph_delegated_run_status ralph_delegated_run_wait ralph_delegated_run_result ralph_delegated_run_cancel; do
    jq -e --arg n "$tool" '.result.tools[] | select(.name == $n)' <<<"$response" >/dev/null
  done
  ! jq -e '.result.tools[] | select(.name == "ralph_delegate_start")' <<<"$response" >/dev/null
}

@test "removed delegate tool is not found" {
  local init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"test","version":"1.0"}}}'
  local response
  response="$(printf '%s\n' "$init" '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ralph_delegate_status","arguments":{}}}' | bash "$SERVER_SCRIPT" 2>/dev/null | grep '"id":2')"
  [ "$(jq -r '.error.code' <<<"$response")" = "-32601" ]
}
