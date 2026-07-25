#!/usr/bin/env bats
# Antigravity MCP config generation and runtime validation.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

SETUP_FILE="$REPO_ROOT/bundle/.ralph/bash-lib/mcp/mcp-setup.sh"
SETUP_MCP_SH="$REPO_ROOT/bundle/.ralph/bash-lib/setup/setup-mcp.sh"
SETUP_HELPERS_SH="$REPO_ROOT/bundle/.ralph/bash-lib/setup/setup-helpers.sh"
MCP_SERVER="$REPO_ROOT/bundle/.ralph/mcp-server.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
}

teardown() {
  if [[ -e "$TEST_TMPDIR" ]]; then
    rm -rf "$TEST_TMPDIR"
  fi
}

@test "ralph_mcp_proxy_generate_config succeeds for antigravity runtime" {
  [ -f "$SETUP_FILE" ] || skip "mcp-setup.sh missing"
  command -v jq >/dev/null || skip "jq required"

  local ws out
  ws="$TEST_TMPDIR/ws_antigravity"
  mkdir -p "$ws/.ralph"
  cp "$MCP_SERVER" "$ws/.ralph/mcp-server.sh"
  out="$ws/ephemeral.json"

  run bash -c 'source "$1" && RALPH_DIR="$3/.ralph" && ralph_mcp_proxy_generate_config antigravity "$2" "$3"' _ "$SETUP_FILE" "$out" "$ws"
  [ "$status" -eq 0 ]
  [ -f "$out" ]
  grep -q '"ralph"' "$out"
  grep -q '"type": "stdio"' "$out"
  grep -q "$ws/.ralph/mcp-server.sh" "$out"
}

@test "ralph_mcp_generate_config alias works for antigravity runtime" {
  [ -f "$SETUP_FILE" ] || skip "mcp-setup.sh missing"
  command -v jq >/dev/null || skip "jq required"

  local ws out
  ws="$TEST_TMPDIR/ws_antigravity_alias"
  mkdir -p "$ws/.ralph"
  cp "$MCP_SERVER" "$ws/.ralph/mcp-server.sh"
  out="$ws/ephemeral.json"

  run bash -c 'source "$1" && RALPH_DIR="$3/.ralph" && ralph_mcp_generate_config antigravity "$2" "$3"' _ "$SETUP_FILE" "$out" "$ws"
  [ "$status" -eq 0 ]
  [ -f "$out" ]
  grep -q '"ralph"' "$out"
}

@test "setup_mcp_antigravity writes .agents/mcp_config.json with Ralph server" {
  [ -f "$SETUP_MCP_SH" ] || skip "setup-mcp.sh missing"
  command -v jq >/dev/null || skip "jq required"

  local project_dir runtime_dir
  project_dir="$TEST_TMPDIR/project"
  runtime_dir="$project_dir/.agents"
  mkdir -p "$project_dir/.ralph" "$runtime_dir"
  cp "$MCP_SERVER" "$project_dir/.ralph/mcp-server.sh"
  chmod +x "$project_dir/.ralph/mcp-server.sh"

  run bash -c "
    set -euo pipefail
    source \"$SETUP_HELPERS_SH\"
    source \"$SETUP_MCP_SH\"
    export BUNDLE_ROOT=\"$REPO_ROOT/bundle\"
    setup_mcp_antigravity \"$runtime_dir\" \"$project_dir\"
  "
  [ "$status" -eq 0 ]
  [ -f "$runtime_dir/mcp_config.json" ]
  grep -q '"ralph"' "$runtime_dir/mcp_config.json"
  grep -q "$project_dir/.ralph/mcp-server.sh" "$runtime_dir/mcp_config.json"
}

@test "setup_mcp_for_runtime rejects unsupported runtime" {
  [ -f "$SETUP_MCP_SH" ] || skip "setup-mcp.sh missing"

  local project_dir runtime_dir
  project_dir="$TEST_TMPDIR/bad_project"
  runtime_dir="$project_dir/.bogus"
  mkdir -p "$runtime_dir"

  run bash -c "
    set -euo pipefail
    source \"$SETUP_HELPERS_SH\"
    source \"$SETUP_MCP_SH\"
    setup_mcp_for_runtime bogus \"$runtime_dir\" \"$project_dir\"
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"not implemented for runtime bogus"* ]]
}
