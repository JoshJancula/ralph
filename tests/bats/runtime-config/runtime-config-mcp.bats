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
  mkdir -p "$WORKSPACE/.ralph" "$WORKSPACE/.cursor" "$ISOLATED_HOME"
  cp "$MCP_SERVER" "$WORKSPACE/.ralph/mcp-server.sh"
  printf '%s\n' '{"mcpServers":{"ambient":{"command":"keep-cmd"}}}' >"$WORKSPACE/.cursor/mcp.json"
  export WORKSPACE
  export HOME="$ISOLATED_HOME"
  export RALPH_RUNTIME_MCP_HOME="$ISOLATED_HOME"
  export RALPH_PROJECT_ROOT="$WORKSPACE"
  export RALPH_DIR="$REPO_ROOT/bundle/.ralph"
  export SCRIPT_DIR="$RALPH_DIR"
  unset RALPH_AGENT_TOOL_ACCESS
  unset RALPH_RUNTIME_MCP_AGENT_ENTRIES_JSON
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

@test "runtime-config-mcp resolve merges ambient and ralph for cursor ralph mode" {
  [ -f "$LIB" ] || skip "runtime-config-mcp.sh missing"
  [ -f "$PY" ] || skip "runtime-config-mcp.py missing"

  run bash -c '
    source "$1"
    source "$2"
    export RALPH_MODE=ralph
    export WORKSPACE="$3"
    export RALPH_PROJECT_ROOT="$3"
    ralph_runtime_config_mcp_resolve cursor "$3" "" "$3"
    jq -e ".mcpServers.ralph.command == \"bash\"" "$RALPH_RUNTIME_MCP_RESOLVE_PATH"
    jq -e ".mcpServers.ambient.command == \"keep-cmd\"" "$RALPH_RUNTIME_MCP_RESOLVE_PATH"
  ' _ "$MCP_SETUP" "$LIB" "$WORKSPACE"
  [ "$status" -eq 0 ]
}

@test "runtime-config-mcp resolves RALPH_RESULT_WINDOWING_LOG into ralph server env in cursor hybrid mode" {
  [ -f "$LIB" ] || skip "runtime-config-mcp.sh missing"
  [ -f "$PY" ] || skip "runtime-config-mcp.py missing"

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

@test "runtime-config-mcp fails before CLI for missing agent reference" {
  [ -f "$LIB" ] || skip "runtime-config-mcp.sh missing"

  run bash -c '
    source "$1"
    source "$2"
    export RALPH_MODE=no
    export WORKSPACE="$3"
    export RALPH_PROJECT_ROOT="$3"
    export RALPH_RUNTIME_MCP_AGENT_ENTRIES_JSON='"'"'["missing-ref"]'"'"'
    ralph_runtime_config_mcp_resolve cursor "$3" "test-agent" "$3"
  ' _ "$MCP_SETUP" "$LIB" "$WORKSPACE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing ambient MCP server"* ]]
  [[ "$output" == *"missing-ref"* ]]
  [[ "$output" == *"Searched MCP config sources"* ]]
}

@test "runtime-config-mcp resolves env refs without leaking secrets in summary" {
  [ -f "$LIB" ] || skip "runtime-config-mcp.sh missing"

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

@test "runtime-config-mcp apply_summary exposes sanitized overlay fields" {
  [ -f "$LIB" ] || skip "runtime-config-mcp.sh missing"

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
