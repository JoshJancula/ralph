#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

LIB="$REPO_ROOT/bundle/.ralph/bash-lib/runtime-config/runtime-config-mcp.sh"
PY="$REPO_ROOT/bundle/.ralph/python/runtime-config-mcp.py"
MCP_SETUP="$REPO_ROOT/bundle/.ralph/bash-lib/mcp/mcp-setup.sh"
MCP_SERVER="$REPO_ROOT/bundle/.ralph/mcp-server.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  WORKSPACE="$TEST_TMPDIR/workspace"
  ISOLATED_HOME="$TEST_TMPDIR/home"
  mkdir -p "$WORKSPACE/.ralph" "$ISOLATED_HOME"
  cp "$MCP_SERVER" "$WORKSPACE/.ralph/mcp-server.sh"
  export WORKSPACE
  export HOME="$ISOLATED_HOME"
  export RALPH_RUNTIME_MCP_HOME="$ISOLATED_HOME"
  export RALPH_PROJECT_ROOT="$WORKSPACE"
  export RALPH_DIR="$REPO_ROOT/bundle/.ralph"
  export SCRIPT_DIR="$RALPH_DIR"
  unset RALPH_AGENT_TOOL_ACCESS
  unset RALPH_RUNTIME_MCP_AGENT_ENTRIES_JSON
  unset RALPH_MODE
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

write_ambient_cursor() {
  mkdir -p "$WORKSPACE/.cursor" "$ISOLATED_HOME/.cursor"
  printf '%s\n' '{"mcpServers":{"ambient":{"command":"keep-cmd"}}}' >"$WORKSPACE/.cursor/mcp.json"
}

write_ambient_claude() {
  mkdir -p "$WORKSPACE/.claude" "$ISOLATED_HOME/.claude"
  printf '%s\n' '{"mcpServers":{"ambient":{"command":"claude-ambient"}}}' >"$WORKSPACE/.mcp.json"
}

write_ambient_codex() {
  mkdir -p "$WORKSPACE/.codex" "$ISOLATED_HOME/.codex"
  cat >"$WORKSPACE/.codex/config.toml" <<'EOF'
[mcp_servers.ambient]
command = "codex-ambient"
EOF
}

write_ambient_opencode() {
  mkdir -p "$WORKSPACE/.opencode" "$ISOLATED_HOME/.config/opencode"
  printf '%s\n' '{"mcp":{"ambient":{"type":"local","command":["opencode-ambient"]}}}' >"$WORKSPACE/opencode.json"
}

write_ambient_antigravity() {
  mkdir -p "$WORKSPACE/.agents" "$ISOLATED_HOME/.agents"
  printf '%s\n' '{"mcpServers":{"ambient":{"command":"agy-ambient"}}}' >"$WORKSPACE/.agents/mcp_config.json"
}

# --- ambient + protected ralph for each runtime ---

@test "runtime-config-mcp ambient + protected ralph for cursor" {
  [ -f "$LIB" ] || skip "runtime-config-mcp.sh missing"
  [ -f "$PY" ] || skip "runtime-config-mcp.py missing"
  write_ambient_cursor

  run bash -c '
    source "$1"
    source "$2"
    export RALPH_MODE=ralph
    export WORKSPACE="$3"
    export RALPH_PROJECT_ROOT="$3"
    ralph_runtime_config_mcp_resolve cursor "$3" "" "$3"
    jq -e ".mcpServers.ralph.command == \"bash\"" "$RALPH_RUNTIME_MCP_RESOLVE_PATH"
    jq -e ".mcpServers.ambient.command == \"keep-cmd\"" "$RALPH_RUNTIME_MCP_RESOLVE_PATH"
    jq -e ".mcpServers | keys | index(\"ralph\") != null" "$RALPH_RUNTIME_MCP_RESOLVE_PATH"
  ' _ "$MCP_SETUP" "$LIB" "$WORKSPACE"
  [ "$status" -eq 0 ]
}

@test "runtime-config-mcp ambient + protected ralph for claude" {
  [ -f "$LIB" ] || skip "runtime-config-mcp.sh missing"
  write_ambient_claude

  run bash -c '
    source "$1"
    source "$2"
    export RALPH_MODE=ralph
    export WORKSPACE="$3"
    export RALPH_PROJECT_ROOT="$3"
    ralph_runtime_config_mcp_resolve claude "$3" "" "$3"
    jq -e ".mcpServers.ralph.command == \"bash\"" "$RALPH_RUNTIME_MCP_RESOLVE_PATH"
    jq -e ".mcpServers.ambient.command == \"claude-ambient\"" "$RALPH_RUNTIME_MCP_RESOLVE_PATH"
  ' _ "$MCP_SETUP" "$LIB" "$WORKSPACE"
  [ "$status" -eq 0 ]
}

@test "runtime-config-mcp ambient + protected ralph for codex" {
  [ -f "$LIB" ] || skip "runtime-config-mcp.sh missing"
  write_ambient_codex

  run bash -c '
    source "$1"
    source "$2"
    export RALPH_MODE=ralph
    export WORKSPACE="$3"
    export RALPH_PROJECT_ROOT="$3"
    ralph_runtime_config_mcp_resolve codex "$3" "" "$3"
    jq -e ".mcp_servers.ralph.command == \"bash\"" "$RALPH_RUNTIME_MCP_RESOLVE_PATH"
    jq -e ".mcp_servers.ambient.command == \"codex-ambient\"" "$RALPH_RUNTIME_MCP_RESOLVE_PATH"
  ' _ "$MCP_SETUP" "$LIB" "$WORKSPACE"
  [ "$status" -eq 0 ]
}

@test "runtime-config-mcp ambient + protected ralph for opencode" {
  [ -f "$LIB" ] || skip "runtime-config-mcp.sh missing"
  write_ambient_opencode

  run bash -c '
    source "$1"
    source "$2"
    export RALPH_MODE=hybrid
    export WORKSPACE="$3"
    export RALPH_PROJECT_ROOT="$3"
    ralph_runtime_config_mcp_resolve opencode "$3" "" "$3"
    jq -e ".mcp.ralph.command[0] == \"bash\"" "$RALPH_RUNTIME_MCP_RESOLVE_PATH"
    jq -e ".mcp.ambient.command[0] == \"opencode-ambient\"" "$RALPH_RUNTIME_MCP_RESOLVE_PATH"
  ' _ "$MCP_SETUP" "$LIB" "$WORKSPACE"
  [ "$status" -eq 0 ]
}

@test "runtime-config-mcp ambient + protected ralph for antigravity" {
  [ -f "$LIB" ] || skip "runtime-config-mcp.sh missing"
  write_ambient_antigravity

  run bash -c '
    source "$1"
    source "$2"
    export RALPH_MODE=ralph
    export WORKSPACE="$3"
    export RALPH_PROJECT_ROOT="$3"
    ralph_runtime_config_mcp_resolve antigravity "$3" "" "$3"
    jq -e ".mcpServers.ralph.command == \"bash\"" "$RALPH_RUNTIME_MCP_RESOLVE_PATH"
    jq -e ".mcpServers.ambient.command == \"agy-ambient\"" "$RALPH_RUNTIME_MCP_RESOLVE_PATH"
  ' _ "$MCP_SETUP" "$LIB" "$WORKSPACE"
  [ "$status" -eq 0 ]
}

# --- protected ralph name cannot be shadowed by ambient ---

@test "runtime-config-mcp protected ralph ignores ambient server named ralph" {
  [ -f "$LIB" ] || skip "runtime-config-mcp.sh missing"
  mkdir -p "$WORKSPACE/.cursor"
  printf '%s\n' \
    '{"mcpServers":{"ralph":{"command":"malicious"},"ambient":{"command":"keep-cmd"}}}' \
    >"$WORKSPACE/.cursor/mcp.json"

  run bash -c '
    source "$1"
    source "$2"
    export RALPH_MODE=ralph
    export WORKSPACE="$3"
    export RALPH_PROJECT_ROOT="$3"
    ralph_runtime_config_mcp_resolve cursor "$3" "" "$3"
    jq -e ".mcpServers.ralph.command == \"bash\"" "$RALPH_RUNTIME_MCP_RESOLVE_PATH"
    jq -e ".mcpServers.ralph.command != \"malicious\"" "$RALPH_RUNTIME_MCP_RESOLVE_PATH"
    jq -e ".mcpServers.ambient.command == \"keep-cmd\"" "$RALPH_RUNTIME_MCP_RESOLVE_PATH"
  ' _ "$MCP_SETUP" "$LIB" "$WORKSPACE"
  [ "$status" -eq 0 ]
}

# --- no profile layer ---

@test "runtime-config-mcp no profile layer: agent entries env is rejected" {
  [ -f "$LIB" ] || skip "runtime-config-mcp.sh missing"
  write_ambient_cursor

  run bash -c '
    source "$1"
    source "$2"
    export RALPH_MODE=ralph
    export WORKSPACE="$3"
    export RALPH_PROJECT_ROOT="$3"
    export RALPH_RUNTIME_MCP_AGENT_ENTRIES_JSON='"'"'[{"name":"extra","transport":"stdio","command":"agent-cmd"}]'"'"'
    ralph_runtime_config_mcp_resolve cursor "$3" "" "$3"
  ' _ "$MCP_SETUP" "$LIB" "$WORKSPACE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"profile MCP layer is removed"* ]]
  [[ "$output" == *"ralph migrate"* ]]
}

@test "runtime-config-mcp no profile layer: ambient secrets still resolve without leaking summary" {
  [ -f "$LIB" ] || skip "runtime-config-mcp.sh missing"

  mkdir -p "$WORKSPACE/.cursor"
  printf '%s\n' \
    '{"mcpServers":{"tokenized":{"command":"cmd","env":{"TOKEN":"${MCP_TEST_TOKEN}"}}}}' \
    >"$WORKSPACE/.cursor/mcp.json"

  run env MCP_TEST_TOKEN=super-secret-value bash -c '
    set -euo pipefail
    source "$1"
    source "$2"
    export RALPH_MODE=no
    export WORKSPACE="$3"
    export RALPH_PROJECT_ROOT="$3"
    ralph_runtime_config_mcp_resolve cursor "$3" "" "$3"
    test -f "$RALPH_RUNTIME_MCP_RESOLVE_PATH"
    grep -q "super-secret-value" "$RALPH_RUNTIME_MCP_RESOLVE_PATH"
    ! grep -q "super-secret-value" <<<"$RALPH_RUNTIME_MCP_SUMMARY_JSON"
  ' _ "$MCP_SETUP" "$LIB" "$WORKSPACE"
  [ "$status" -eq 0 ]
}

@test "runtime-config-mcp ambient apply_summary exposes sanitized overlay fields" {
  [ -f "$LIB" ] || skip "runtime-config-mcp.sh missing"
  write_ambient_cursor

  run bash -c '
    source "$1"
    source "$2"
    source "$3"
    export RALPH_PLAN_KEY=plan-key
    export RALPH_PLAN_WORKSPACE_ROOT="$4/.ralph-workspace"
    export RALPH_MODE=ralph
    export WORKSPACE="$4"
    export RALPH_PROJECT_ROOT="$4"
    runtime_overlay_init_state cursor plan-key
    ralph_runtime_config_mcp_resolve cursor "$4" "" "$4"
    runtime_overlay_write_summary
    jq -e ".mcp_config_sources | length > 0" "$(runtime_overlay_summary_path)"
    jq -e ".mcp_effective_names | index(\"ralph\") != null" "$(runtime_overlay_summary_path)"
    jq -e ".mcp_override_decisions | length > 0" "$(runtime_overlay_summary_path)"
  ' _ "$MCP_SETUP" "$LIB" "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-overlay/runtime-overlay.sh" "$WORKSPACE"
  [ "$status" -eq 0 ]
}

@test "runtime-config-mcp resolves RALPH_RESULT_WINDOWING_LOG into protected ralph env" {
  [ -f "$LIB" ] || skip "runtime-config-mcp.sh missing"
  write_ambient_cursor
  LOG_PATH="$TEST_TMPDIR/windowing.jsonl"

  run env RALPH_MODE=hybrid RALPH_RESULT_WINDOWING_LOG="$LOG_PATH" bash -c '
    source "$1"
    source "$2"
    export WORKSPACE="$3"
    export RALPH_PROJECT_ROOT="$3"
    ralph_runtime_config_mcp_resolve cursor "$3" "" "$3"
    jq -e --arg expected "$RALPH_RESULT_WINDOWING_LOG" \
      ".mcpServers.ralph.env.RALPH_RESULT_WINDOWING_LOG == \$expected" \
      "$RALPH_RUNTIME_MCP_RESOLVE_PATH"
  ' _ "$MCP_SETUP" "$LIB" "$WORKSPACE"

  [ "$status" -eq 0 ]
}
