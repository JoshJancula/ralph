#!/usr/bin/env bats
# Smoke coverage for durable MCP setup across runtimes.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

SETUP_HELPERS_SH="$REPO_ROOT/bundle/.ralph/bash-lib/setup/setup-helpers.sh"
SETUP_MCP_SH="$REPO_ROOT/bundle/.ralph/bash-lib/setup/setup-mcp.sh"

setup() {
  TEST_TEMP_DIR="$(mktemp -d)"
  export TEST_TEMP_DIR
  export BUNDLE_ROOT="$REPO_ROOT/bundle"
}

teardown() {
  if [[ -d "${TEST_TEMP_DIR:-}" ]]; then
    rm -rf "$TEST_TEMP_DIR"
  fi
}

prepare_project_with_mcp_server() {
  local project_dir="$1"
  mkdir -p "$project_dir/.ralph"
  cp "$REPO_ROOT/bundle/.ralph/mcp-server.sh" "$project_dir/.ralph/mcp-server.sh"
  chmod +x "$project_dir/.ralph/mcp-server.sh"
}

@test "setup_mcp_cursor writes .cursor/mcp.json with hybrid env" {
  command -v jq >/dev/null || skip "jq required"
  [ -f "$SETUP_MCP_SH" ] || skip "setup-mcp.sh missing"

  local project_dir="$TEST_TEMP_DIR/project"
  local runtime_dir="$project_dir/.cursor"
  prepare_project_with_mcp_server "$project_dir"
  mkdir -p "$runtime_dir"

  run bash -c "
    set -euo pipefail
    source \"$SETUP_HELPERS_SH\"
    source \"$SETUP_MCP_SH\"
    export BUNDLE_ROOT=\"$BUNDLE_ROOT\"
    setup_mcp_cursor \"$runtime_dir\" \"$project_dir\"
  "
  [ "$status" -eq 0 ]
  jq -e '.mcpServers.ralph.env.RALPH_MODE == "hybrid"' "$runtime_dir/mcp.json"
}

@test "setup_mcp_claude writes project-root .mcp.json with hybrid env" {
  command -v jq >/dev/null || skip "jq required"
  [ -f "$SETUP_MCP_SH" ] || skip "setup-mcp.sh missing"

  local project_dir="$TEST_TEMP_DIR/project"
  local runtime_dir="$project_dir/.claude"
  prepare_project_with_mcp_server "$project_dir"
  mkdir -p "$runtime_dir"

  run bash -c "
    set -euo pipefail
    source \"$SETUP_HELPERS_SH\"
    source \"$SETUP_MCP_SH\"
    export BUNDLE_ROOT=\"$BUNDLE_ROOT\"
    setup_mcp_claude \"$runtime_dir\" \"$project_dir\"
  "
  [ "$status" -eq 0 ]
  jq -e '.mcpServers.ralph.env.RALPH_MODE == "hybrid"' "$project_dir/.mcp.json"
}

@test "setup_mcp_codex writes .codex/config.toml with hybrid env" {
  command -v python3 >/dev/null || skip "python3 required"
  python3 -c 'import tomllib' 2>/dev/null || skip "Python 3.11+ required"
  [ -f "$SETUP_MCP_SH" ] || skip "setup-mcp.sh missing"

  local project_dir="$TEST_TEMP_DIR/project"
  local runtime_dir="$project_dir/.codex"
  prepare_project_with_mcp_server "$project_dir"
  mkdir -p "$runtime_dir"

  run bash -c "
    set -euo pipefail
    source \"$SETUP_HELPERS_SH\"
    source \"$SETUP_MCP_SH\"
    export BUNDLE_ROOT=\"$BUNDLE_ROOT\"
    setup_mcp_codex \"$runtime_dir\" \"$project_dir\"
  "
  [ "$status" -eq 0 ]
  [ -f "$runtime_dir/config.toml" ]
}

@test "setup_mcp_opencode writes project-root opencode.json with hybrid env" {
  command -v jq >/dev/null || skip "jq required"
  [ -f "$SETUP_MCP_SH" ] || skip "setup-mcp.sh missing"

  local project_dir="$TEST_TEMP_DIR/project"
  local runtime_dir="$project_dir/.opencode"
  prepare_project_with_mcp_server "$project_dir"
  mkdir -p "$runtime_dir"

  run bash -c "
    set -euo pipefail
    source \"$SETUP_HELPERS_SH\"
    source \"$SETUP_MCP_SH\"
    export BUNDLE_ROOT=\"$BUNDLE_ROOT\"
    setup_mcp_opencode \"$runtime_dir\" \"$project_dir\"
  "
  [ "$status" -eq 0 ]
  jq -e '.mcp.ralph.environment.RALPH_MODE == "hybrid"' "$project_dir/opencode.json"
}

@test "setup_mcp_claude merges a mota MCP server fragment alongside ralph" {
  command -v jq >/dev/null || skip "jq required"
  [ -f "$SETUP_MCP_SH" ] || skip "setup-mcp.sh missing"

  local project_dir="$TEST_TEMP_DIR/project"
  local runtime_dir="$project_dir/.claude"
  local bin_dir="$TEST_TEMP_DIR/bin"
  prepare_project_with_mcp_server "$project_dir"
  mkdir -p "$runtime_dir" "$bin_dir"

  cat >"$bin_dir/mota" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$bin_dir/mota"

  run bash -c "
    set -euo pipefail
    source \"$SETUP_HELPERS_SH\"
    source \"$SETUP_MCP_SH\"
    export BUNDLE_ROOT=\"$BUNDLE_ROOT\"
    export PATH=\"$bin_dir:\$PATH\"
    export MOTA_API_URL=\"http://localhost:3000/api\"
    setup_mcp_claude \"$runtime_dir\" \"$project_dir\"
  "
  [ "$status" -eq 0 ]

  local config_path="$project_dir/.mcp.json"
  [ -f "$config_path" ]
  jq -e '.mcpServers | has("ralph") and has("mota")' "$config_path"
  jq -e '.mcpServers.mota.command == "mota"' "$config_path"
  jq -e '.mcpServers.mota.args == ["mcp", "serve"]' "$config_path"
  jq -e '.mcpServers.mota.env.MOTA_API_URL == "http://localhost:3000/api"' "$config_path"
  jq -e '.mcpServers.mota.env | has("MOTA_BOT_TOKEN") | not' "$config_path"
  jq -e '.mcpServers.mota.env | has("MOTA_ORG_MCP_KEY") | not' "$config_path"
}

# Clean MCP fixture: project + runtime with an unrelated native agent present.
_fixture_mcp_with_native_agent() {
  local project_dir="$1"
  local runtime_dir="$2"
  local marker="${3:-native-agent-marker-do-not-touch}"
  prepare_project_with_mcp_server "$project_dir"
  mkdir -p "$runtime_dir/agents/my-native-agent"
  printf '%s\n' "$marker" >"$runtime_dir/agents/my-native-agent/my-native-agent.md"
  mkdir -p "$runtime_dir/agents/research"
  printf 'stale-six\n' >"$runtime_dir/agents/research/research.md"
}

@test "clean setup mcp continues and preserve unrelated native agent" {
  command -v jq >/dev/null || skip "jq required"
  [ -f "$SETUP_MCP_SH" ] || skip "setup-mcp.sh missing"

  local project_dir="$TEST_TEMP_DIR/project"
  local runtime_dir="$project_dir/.cursor"
  local marker="native-agent-marker-do-not-touch"
  _fixture_mcp_with_native_agent "$project_dir" "$runtime_dir" "$marker"

  run bash -c "
    set -euo pipefail
    source \"$SETUP_HELPERS_SH\"
    source \"$SETUP_MCP_SH\"
    export BUNDLE_ROOT=\"$BUNDLE_ROOT\"
    setup_mcp_cursor \"$runtime_dir\" \"$project_dir\"
  "
  [ "$status" -eq 0 ]
  jq -e '.mcpServers.ralph.env.RALPH_MODE == "hybrid"' "$runtime_dir/mcp.json"
  [ -f "$runtime_dir/agents/my-native-agent/my-native-agent.md" ]
  [[ "$(cat "$runtime_dir/agents/my-native-agent/my-native-agent.md")" == "$marker" ]]
  [ -f "$runtime_dir/agents/research/research.md" ]
  [[ "$(cat "$runtime_dir/agents/research/research.md")" == "stale-six" ]]
  [ ! -d "$runtime_dir/agents/architect" ]
  [ ! -d "$runtime_dir/agents/qa" ]
  [ ! -d "$runtime_dir/agents/security" ]
}

@test "clean setup mcp leaves native agent dirs untouched for claude" {
  command -v jq >/dev/null || skip "jq required"
  [ -f "$SETUP_MCP_SH" ] || skip "setup-mcp.sh missing"

  local project_dir="$TEST_TEMP_DIR/project-claude"
  local runtime_dir="$project_dir/.claude"
  local marker="claude-mcp-native-agent-keep"
  _fixture_mcp_with_native_agent "$project_dir" "$runtime_dir" "$marker"

  run bash -c "
    set -euo pipefail
    source \"$SETUP_HELPERS_SH\"
    source \"$SETUP_MCP_SH\"
    export BUNDLE_ROOT=\"$BUNDLE_ROOT\"
    setup_mcp_claude \"$runtime_dir\" \"$project_dir\"
  "
  [ "$status" -eq 0 ]
  jq -e '.mcpServers.ralph.env.RALPH_MODE == "hybrid"' "$project_dir/.mcp.json"
  [ -f "$runtime_dir/agents/my-native-agent/my-native-agent.md" ]
  [[ "$(cat "$runtime_dir/agents/my-native-agent/my-native-agent.md")" == "$marker" ]]
  [ ! -e "$runtime_dir/agents.md" ]
  [ ! -d "$runtime_dir/agents/architect" ]
}
