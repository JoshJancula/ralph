#!/usr/bin/env bats
# Tests for the "ralph jev mcp" subcommands in bundle/.ralph/jev.sh.
#
# Isolation: RALPH_CONFIG_HOME and HOME point at a per-test mktemp dir, and
# RALPH_JEV_ENV_FILE=0 keeps the developer's real .env out of every assertion.
# No test makes a live API call: only status/config are exercised, plus a single
# initialize handshake against the stdio server.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

JEV_CLI="$REPO_ROOT/bundle/.ralph/jev.sh"

setup() {
  JEVCLI_TMP="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/ralph-jev-cli.XXXXXX")"
  export HOME="$JEVCLI_TMP/home"
  export RALPH_CONFIG_HOME="$JEVCLI_TMP/config"
  export RALPH_JEV_STATE_DIR="$JEVCLI_TMP/state"
  export RALPH_JEV_ENV_FILE=0
  mkdir -p "$HOME" "$RALPH_CONFIG_HOME" "$RALPH_JEV_STATE_DIR"
  unset RALPH_JEV RALPH_JEV_MCP TYPESAFE_API_KEY RALPH_JEV_MCP_SERVER_SCRIPT
}

teardown() {
  rm -rf "$JEVCLI_TMP"
}

@test "ralph jev mcp config emits a registrable ralph-jev entry without the key" {
  export TYPESAFE_API_KEY="typesafe-cli-config-test-key"
  run bash "$JEV_CLI" mcp config
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '
    .mcpServers["ralph-jev"].command == "bash"
    and (.mcpServers["ralph-jev"].args[0] | endswith("jev-mcp-server.sh"))
    and .mcpServers["ralph-jev"].env.RALPH_JEV == "1"
    and .mcpServers["ralph-jev"].env.RALPH_JEV_MCP == "1"
  '
  # The key is resolved by the server itself and must never reach a config file.
  ! printf '%s\n' "$output" | grep -qi 'TYPESAFE_API_KEY'
  ! printf '%s\n' "$output" | grep -qF 'typesafe-cli-config-test-key'
}

@test "ralph jev mcp config --merge adds ralph-jev and keeps existing servers" {
  local cfg="$JEVCLI_TMP/.mcp.json"
  printf '%s\n' '{"mcpServers":{"ralph":{"command":"bash","args":["/x/mcp-server.sh"]}}}' >"$cfg"
  run bash "$JEV_CLI" mcp config --merge "$cfg"
  [ "$status" -eq 0 ]
  jq -e '
    (.mcpServers | keys | sort) == ["ralph","ralph-jev"]
    and .mcpServers.ralph.args[0] == "/x/mcp-server.sh"
  ' "$cfg"
}

@test "ralph jev mcp config --merge rejects a missing file" {
  run bash "$JEV_CLI" mcp config --merge "$JEVCLI_TMP/does-not-exist.json"
  [ "$status" -eq 2 ]
}

@test "ralph jev mcp status reports the curated tool names and question sets" {
  run bash "$JEV_CLI" mcp status
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'jev_classify_failure'
  printf '%s\n' "$output" | grep -q 'jev_classify_request'
  printf '%s\n' "$output" | grep -q 'jev_rank_relevance'
  printf '%s\n' "$output" | grep -q 'jev_ask'
  printf '%s\n' "$output" | grep -q 'graph.failure-class'
}

@test "ralph jev mcp status reports no resolvable key when none is configured" {
  run bash "$JEV_CLI" mcp status
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '^key-resolvable: no$'
}

@test "ralph jev mcp start serves stdio and identifies as ralph-jev" {
  run bash -c 'printf "%s\n" "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}" | bash "$1" mcp start 2>/dev/null' _ "$JEV_CLI"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -s -e '.[0].result.serverInfo.name == "ralph-jev"'
}

@test "ralph jev mcp rejects an unknown subcommand" {
  run bash "$JEV_CLI" mcp bogus
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -q 'unknown ralph jev mcp subcommand'
}
