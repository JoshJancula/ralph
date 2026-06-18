#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

RESULT_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-result.sh"

setup() {
  unset RALPH_MCP_PROXY_RESULT_LOADED
  # shellcheck source=/dev/null
  source "$RESULT_LIB"
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
