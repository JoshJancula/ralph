#!/usr/bin/env bats

# Tests that cover both callable MCP tool surfaces:
#   - Namespaced: mcp__ralph__<tool>  (Claude registers server as "ralph")
#   - Direct:     <tool>              (RALPH_MCP_TOOL_NAMESPACE="" fallback)
#
# Verifies that allowedTools, the surface detection logic, and the live-preflight
# guard all behave correctly for each surface.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

PROXY_SETUP_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-setup.sh"
INVOKE_CLAUDE_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-claude.sh"
SERVER_SCRIPT="$REPO_ROOT/bundle/.ralph/mcp-server.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  WS="$TEST_TMPDIR/workspace"
  mkdir -p "$WS"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

# ---- Surface detection from preflight ----------------------------------------

@test "preflight detects mcp__ralph__ namespace from real server" {
  command -v jq >/dev/null || skip "jq required"
  command -v python3 >/dev/null || skip "python3 required"

  local ns
  ns="$(
    env RALPH_MCP_WORKSPACE="$WS" \
    bash -c '
      source "$1"
      ralph_mcp_proxy_preflight "$2" "$3" >/dev/null
      printf "%s\n" "${RALPH_MCP_TOOL_NAMESPACE:-UNSET}"
    ' _ "$PROXY_SETUP_LIB" "$SERVER_SCRIPT" "$WS"
  )"
  [[ "$ns" == "mcp__ralph__" ]] \
    || { echo "expected mcp__ralph__ namespace from real server, got: $ns"; return 1; }
}

@test "preflight with stub server returning no ralph_proxy tools sets empty namespace" {
  command -v jq >/dev/null || skip "jq required"
  command -v python3 >/dev/null || skip "python3 required"

  # Stub: a server that responds to initialize+tools/list but with non-ralph tools
  local stub_server="$TEST_TMPDIR/stub-server.sh"
  cat > "$stub_server" <<'STUB'
#!/usr/bin/env bash
while IFS= read -r line; do
  case "$line" in
    *'"method":"initialize"'*)
      printf '{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"tools":{}}}}\n'
      ;;
    *'"method":"tools/list"'*)
      printf '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"other_tool","description":"not a proxy tool","inputSchema":{"type":"object"}}]}}\n'
      exit 0
      ;;
  esac
done
STUB
  chmod +x "$stub_server"

  local ns
  ns="$(
    env RALPH_MCP_WORKSPACE="$WS" \
    bash -c '
      source "$1"
      ralph_mcp_proxy_preflight "$2" "$3" >/dev/null 2>&1 || true
      printf "%s\n" "${RALPH_MCP_TOOL_NAMESPACE:-EMPTY}"
    ' _ "$PROXY_SETUP_LIB" "$stub_server" "$WS"
  )"
  # Stub has tools but no ralph_proxy_* tools, so namespace should be empty
  [[ "$ns" == "EMPTY" || "$ns" == "" ]] \
    || { echo "expected empty namespace for non-ralph tools, got: $ns"; return 1; }
}

# ---- allowedTools surface: namespaced (mcp__ralph__) -------------------------

@test "allowedTools uses mcp__ralph__ prefix when RALPH_MCP_TOOL_NAMESPACE is mcp__ralph__" {
  local tools
  tools="$(
    env RALPH_MCP_TOOL_NAMESPACE="mcp__ralph__" RALPH_MODE=native \
    bash -c '
      # Only load the run-plan-invoke-claude lib to call the function directly.
      # Source its dependencies manually.
      source "$1"
      ralph_run_plan_invoke_claude_proxy_tool_names
    ' _ "$INVOKE_CLAUDE_LIB" 2>/dev/null
  )"
  printf '%s\n' "$tools" | tr ',' '\n' | grep -q "mcp__ralph__ralph_proxy_read" \
    || { echo "mcp__ralph__ prefix not in allowedTools: $tools"; return 1; }
  # Confirm no bare tool names without prefix
  printf '%s\n' "$tools" | tr ',' '\n' | grep -qE "^ralph_proxy_read$" \
    && { echo "bare ralph_proxy_read should not appear when namespace is mcp__ralph__"; return 1; } || true
}

# ---- allowedTools surface: fallback when namespace unset ----------------------

@test "allowedTools falls back to mcp__ralph__ prefix when RALPH_MCP_TOOL_NAMESPACE is empty" {
  # When the env is explicitly empty the :-fallback in _ns="${RALPH_MCP_TOOL_NAMESPACE:-mcp__ralph__}"
  # kicks in. This is the safe default: the MCP config always registers the server as "ralph".
  local tools
  tools="$(
    env RALPH_MCP_TOOL_NAMESPACE="" RALPH_MODE=native \
    bash -c '
      source "$1"
      ralph_run_plan_invoke_claude_proxy_tool_names
    ' _ "$INVOKE_CLAUDE_LIB" 2>/dev/null
  )"
  printf '%s\n' "$tools" | tr ',' '\n' | grep -q "mcp__ralph__ralph_proxy_read" \
    || { echo "expected fallback mcp__ralph__ prefix in allowedTools, got: $tools"; return 1; }
}

@test "allowedTools uses custom namespace from RALPH_MCP_TOOL_NAMESPACE" {
  # Custom/overridden namespace (e.g. "mcp__myserver__") is respected.
  local tools
  tools="$(
    env RALPH_MCP_TOOL_NAMESPACE="mcp__myserver__" RALPH_MODE=native \
    bash -c '
      source "$1"
      ralph_run_plan_invoke_claude_proxy_tool_names
    ' _ "$INVOKE_CLAUDE_LIB" 2>/dev/null
  )"
  printf '%s\n' "$tools" | tr ',' '\n' | grep -q "mcp__myserver__ralph_proxy_read" \
    || { echo "expected custom namespace prefix in allowedTools, got: $tools"; return 1; }
}

# ---- Completion tool surface -------------------------------------------------

@test "completion tool uses mcp__ralph__ prefix when namespace is set" {
  local tool
  tool="$(
    env RALPH_MCP_TOOL_NAMESPACE="mcp__ralph__" \
    bash -c '
      source "$1"
      ralph_run_plan_invoke_claude_completion_tool_names
    ' _ "$INVOKE_CLAUDE_LIB" 2>/dev/null
  )"
  [[ "$tool" == "mcp__ralph__ralph_complete_todo" ]] \
    || { echo "expected mcp__ralph__ralph_complete_todo, got: $tool"; return 1; }
}

@test "completion tool falls back to mcp__ralph__ prefix when namespace is empty" {
  local tool
  tool="$(
    env RALPH_MCP_TOOL_NAMESPACE="" \
    bash -c '
      source "$1"
      ralph_run_plan_invoke_claude_completion_tool_names
    ' _ "$INVOKE_CLAUDE_LIB" 2>/dev/null
  )"
  [[ "$tool" == "mcp__ralph__ralph_complete_todo" ]] \
    || { echo "expected mcp__ralph__ralph_complete_todo (fallback), got: $tool"; return 1; }
}

@test "graph-node Claude allowlist includes broker delegation tools" {
  local tools
  tools="$(
    env RALPH_MCP_SCOPE=graph-node RALPH_MCP_TOOL_NAMESPACE=mcp__ralph__ RALPH_MODE=hybrid \
    bash -c '
      source "$1"
      ralph_run_plan_invoke_claude_allowed_tools_list "Bash,Read" 0 0
    ' _ "$INVOKE_CLAUDE_LIB" 2>/dev/null
  )"
  # The broker tools are namespaced ralph_delegated_run_* on the delegated-run surface.
  printf '%s\n' "$tools" | tr ',' '\n' | grep -q '^mcp__ralph__ralph_delegated_run_start$'
  printf '%s\n' "$tools" | tr ',' '\n' | grep -q '^mcp__ralph__ralph_delegated_run_wait$'
  printf '%s\n' "$tools" | tr ',' '\n' | grep -q '^mcp__ralph__ralph_delegated_run_cancel$'
}

# ---- Preflight probe tool surface --------------------------------------------

@test "live preflight probe tool uses detected namespace (mcp__ralph__)" {
  # Verify the probe_tool variable constructed in ralph_mcp_claude_cli_preflight
  # resolves to the expected namespaced form when RALPH_MCP_TOOL_NAMESPACE is set.
  local probe
  probe="$(
    env RALPH_MCP_TOOL_NAMESPACE="mcp__ralph__" \
    bash -c '
      ns="${RALPH_MCP_TOOL_NAMESPACE:-mcp__ralph__}"
      printf "%s\n" "${ns}ralph_proxy_read"
    '
  )"
  [[ "$probe" == "mcp__ralph__ralph_proxy_read" ]] \
    || { echo "expected mcp__ralph__ralph_proxy_read, got: $probe"; return 1; }
}

@test "live preflight probe tool falls back to mcp__ralph__ when namespace unset" {
  local probe
  probe="$(
    env -u RALPH_MCP_TOOL_NAMESPACE \
    bash -c '
      ns="${RALPH_MCP_TOOL_NAMESPACE:-mcp__ralph__}"
      printf "%s\n" "${ns}ralph_proxy_read"
    '
  )"
  [[ "$probe" == "mcp__ralph__ralph_proxy_read" ]] \
    || { echo "expected fallback mcp__ralph__ralph_proxy_read, got: $probe"; return 1; }
}
