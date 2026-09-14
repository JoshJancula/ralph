#!/usr/bin/env bats
# Regression coverage for D3 part two: post-tool-mcp-compact.sh must only ever
# rewrite Ralph MCP proxy tools (ralph_proxy_*). Third-party MCP results pass
# through untouched even though hooks.json registers the hook against MCP:*.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

FIXTURE_DIR="$REPO_ROOT/tests/fixtures/native-hook"
HOOK="$REPO_ROOT/bundle/.cursor/hooks/post-tool-mcp-compact.sh"

setup() {
  _tmp="$(mktemp -d)"
  export WORKSPACE="$_tmp"
  export RALPH_PROXY_SHELL_COMPACT=1
  bats_skip_known_ci_flakes
}

teardown() {
  rm -rf "$_tmp"
  unset WORKSPACE RALPH_PROXY_SHELL_COMPACT
}

@test "mcp-compact: third-party tool passes through unchanged" {
  run bash -c "cat '$FIXTURE_DIR/mcp-third-party.json' | bash '$HOOK' 2>'$_tmp/hook.err'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "mcp-compact: ralph_proxy_shell result is compacted" {
  run bash -c "cat '$FIXTURE_DIR/mcp-ralph-proxy.json' | bash '$HOOK' 2>'$_tmp/hook.err'"
  [ "$status" -eq 0 ]
  [ -n "$output" ]

  echo "$output" | jq -e . >/dev/null

  echo "$output" | jq -e '.updated_mcp_tool_output' >/dev/null
  local compact_text
  compact_text="$(echo "$output" | jq -r '.updated_mcp_tool_output.content[0].text')"
  [ -n "$compact_text" ]

  local orig_len
  orig_len="$(jq -r '.tool_output.content[0].text | length' "$FIXTURE_DIR/mcp-ralph-proxy.json")"
  [ "${#compact_text}" -lt "$orig_len" ]
}

@test "mcp-compact: antigravity bundle copy also scopes to ralph_proxy_*" {
  local agy_hook="$REPO_ROOT/bundle/.agents/hooks/post-tool-mcp-compact.sh"
  run bash -c "cat '$FIXTURE_DIR/mcp-third-party.json' | bash '$agy_hook' 2>'$_tmp/hook.err'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run bash -c "cat '$FIXTURE_DIR/mcp-ralph-proxy.json' | bash '$agy_hook' 2>'$_tmp/hook2.err'"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  echo "$output" | jq -e '.updated_mcp_tool_output' >/dev/null
}
