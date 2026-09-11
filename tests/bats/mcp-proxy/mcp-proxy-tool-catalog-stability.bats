#!/usr/bin/env bats
# tools/list catalog must stay byte-identical across server starts and
# different RALPH_PLAN_KEY values; five exploration tools advertise a "cap"
# (COMPACTION-CACHE-AUDIT a4).

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

SERVER_SCRIPT="$REPO_ROOT/bundle/.ralph/mcp-server.sh"

setup() {
  command -v jq >/dev/null || skip "jq required"
  [ -f "$SERVER_SCRIPT" ] || skip "mcp-server.sh missing"
  WS="$(mktemp -d)"
  export RALPH_MCP_WORKSPACE="$WS"
  # Full owned catalog so glob/search are present (compact catalog hides them).
  export RALPH_MCP_COMPACT_TOOL_CATALOG=0
  export RALPH_MCP_PROXY_OWNED_TOOLS_FORCE=1
  export RALPH_MODE=ralph
  # tools/list does not call ensure_lazy_init, so export owned-tool policy
  # flags directly; otherwise ralph_proxy_search is omitted from the catalog.
  export RALPH_MCP_PROXY_POLICY_OWNED_TOOLS_ENABLED=1
  export RALPH_MCP_PROXY_POLICY_OWNED_SEARCH_ENABLED=1
}

teardown() {
  rm -rf "$WS"
}

tools_list_payload() {
  printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize"}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
    '{"jsonrpc":"2.0","id":3,"method":"exit"}'
}

# Run one MCP server process and print the compact tools/list result JSON.
invoke_tools_list() {
  local plan_key="$1"
  local output
  output="$(
    env \
      RALPH_MODE=ralph \
      RALPH_MCP_WORKSPACE="$WS" \
      RALPH_PLAN_KEY="$plan_key" \
      RALPH_MCP_COMPACT_TOOL_CATALOG=0 \
      RALPH_MCP_PROXY_OWNED_TOOLS_FORCE=1 \
      RALPH_MCP_PROXY_POLICY_OWNED_TOOLS_ENABLED=1 \
      RALPH_MCP_PROXY_POLICY_OWNED_SEARCH_ENABLED=1 \
      bash "$SERVER_SCRIPT" 2>/dev/null <<< "$(tools_list_payload)"
  )" || return 1
  printf '%s\n' "$output" | jq -cs '
    map(select(.id == 2)) | .[0].result // empty
  '
}

@test "tool-catalog-stability: tools/list identical across plan keys; five tools mention cap" {
  local list_a list_b
  list_a="$(invoke_tools_list "plan-catalog-a")"
  list_b="$(invoke_tools_list "plan-catalog-b")"
  [[ -n "$list_a" && -n "$list_b" ]]
  [[ "$list_a" == "$list_b" ]]

  printf '%s\n' "$list_a" | jq -e '
    (.tools // []) as $tools
    | ["ralph_proxy_read","ralph_proxy_grep","ralph_proxy_glob","ralph_proxy_search","ralph_proxy_shell"] as $names
    | ($names | all(. as $n | ($tools | map(select(.name == $n)) | length == 1)))
    and ($names | all(. as $n |
      ($tools | map(select(.name == $n))[0].description | test("cap"))
    ))
  '
}
