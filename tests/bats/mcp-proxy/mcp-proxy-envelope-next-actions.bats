#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

RESULT_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-result.sh"
RESULT_REDUCE_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-result-reduce.sh"

setup() {
  unset RALPH_MCP_PROXY_RESULT_LOADED RALPH_MCP_PROXY_RESULT_REDUCE_LOADED
  # shellcheck source=/dev/null
  source "$RESULT_LIB"
  # shellcheck source=/dev/null
  source "$RESULT_REDUCE_LIB"
}

@test "default envelope nextActions omit raw escalation" {
  local actions
  actions="$(ralph_mcp_proxy_result_envelope_default_next_actions_json "abc123456789abcd" 4096)"
  printf '%s\n' "$actions" | jq -e '
    map(.arguments.view // empty) | index("raw") == null
  '
}

@test "default envelope nextActions include compacted read and summary" {
  local actions
  actions="$(ralph_mcp_proxy_result_envelope_default_next_actions_json "abc123456789abcd" 4096)"
  printf '%s\n' "$actions" | jq -e '
    (map(.tool) | index("ralph_proxy_result_read")) != null
    and (map(.tool) | index("ralph_proxy_result_summary")) != null
    and any(.[]; .tool == "ralph_proxy_result_read" and .arguments.view == "compacted")
  '
}

@test "raw nextActions only when recommendedReadView is raw" {
  local actions
  actions="$(ralph_mcp_proxy_result_envelope_default_next_actions_json "abc123456789abcd" 4096 raw)"
  printf '%s\n' "$actions" | jq -e '
    (map(.arguments.view // empty) | index("raw")) != null
  '
}

@test "reduce envelope nextActions include reduce read search and summary" {
  command -v jq >/dev/null || skip "jq required"
  local actions
  actions="$(ralph_mcp_proxy_result_envelope_reduce_next_actions_json "abc123456789abcd" "def456789abcde01" 4096 jq ".items")"
  printf '%s\n' "$actions" | jq -e '
    (map(.tool) | index("ralph_proxy_result_reduce")) != null
    and (map(.tool) | index("ralph_proxy_result_read")) != null
    and (map(.tool) | index("ralph_proxy_result_search")) != null
    and (map(.tool) | index("ralph_proxy_result_summary")) != null
    and any(.[]; .tool == "ralph_proxy_result_reduce" and .arguments.resultId == "abc123456789abcd")
    and any(.[]; .tool == "ralph_proxy_result_read" and .arguments.resultId == "def456789abcde01")
  '
}
