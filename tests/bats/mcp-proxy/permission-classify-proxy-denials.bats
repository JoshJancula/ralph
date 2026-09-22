#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

setup() {
  # permission-classify is a bash lib that exposes classification helpers.
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/permission-classify.sh"
}

@test "external_directory denial is classified with extracted path" {
  local text expected_path tag extracted
  expected_path="/abs/outside"
  text="Plan plans/foo.plan.md Todo line 12; Permission requested: external_directory (${expected_path})"

  tag="$(ralph_permission_block_type "$text" 1 "cursor")"
  [ "$tag" = "external_directory" ]

  extracted="$(ralph_permission_blocked_path "$text")"
  [ "$extracted" = "$expected_path" ]
}

@test "restricted_tool denial is classified with extracted tool" {
  local text tool tag extracted
  tool="ralph_proxy_shell"
  text="Plan plans/foo.plan.md Todo line 12; Permission requested: tool ${tool} is not allowed"

  tag="$(ralph_permission_block_type "$text" 1 "claude")"
  [ "$tag" = "restricted_tool" ]

  extracted="$(ralph_permission_blocked_tool "$text")"
  [ "$extracted" = "$tool" ]
}

@test "MCP server env JSON includes interactivity flag" {
  local workspace_json
  workspace_json="/tmp/ralph-mcp-env-json-$$"
  mkdir -p "$workspace_json"

  export NON_INTERACTIVE_FLAG=0
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/mcp/mcp-setup.sh"
  json="$(ralph_mcp_proxy_build_server_env_json "$workspace_json")"
  val="$(jq -r '.RALPH_MCP_PROXY_INTERACTIVITY // empty' <<<"$json")"
  [ "$val" = "interactive" ]

  export NON_INTERACTIVE_FLAG=1
  json="$(ralph_mcp_proxy_build_server_env_json "$workspace_json")"
  val="$(jq -r '.RALPH_MCP_PROXY_INTERACTIVITY // empty' <<<"$json")"
  [ "$val" = "non-interactive" ]
}
