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
  tool="ralph_proxy_read"
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

@test "MCP boundary denial wording changes by interactivity" {
  # Run the real mcp-server for a denied proxy call and verify the error
  # text prefix differs for interactive vs non-interactive.
  local server="$REPO_ROOT/bundle/.ralph/mcp-server.sh"
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/workspace"

  run bash -c '
    set -euo pipefail
    ws="$1"
    server="$2"
    mode="$3"

    # shellcheck source=/dev/null
    source "$REPO_ROOT/bundle/.ralph/bash-lib/mcp/mcp-setup.sh"

    export NON_INTERACTIVE_FLAG="$mode"
    export RALPH_MCP_POLICY_VIOLATION_MODE="fatal"
    export RALPH_MCP_WORKSPACE="$ws"
    # Simulate ralph_mcp_proxy_build_server_env_json export into server.
    interactivity="$(jq -r '.RALPH_MCP_PROXY_INTERACTIVITY' <<<"$(ralph_mcp_proxy_build_server_env_json "$ws")")"
    export RALPH_MCP_PROXY_INTERACTIVITY="$interactivity"

    payload="$(
      cat <<EOF
{"jsonrpc":"2.0","id":1,"method":"initialize"}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ralph_proxy_read","arguments":{"path":"/etc/passwd"}}}
{"jsonrpc":"2.0","id":3,"method":"exit"}
EOF
    )"

    if [[ "$mode" == "1" ]]; then
      out="$(printf "%s" "$payload" | "$server" 2>/dev/null || true)"
      grep -q "permission denied; find a workaround within the workspace and continue" <<<"$out"
    else
      out="$(printf "%s" "$payload" | "$server" 2>/dev/null || true)"
      grep -q "permission denied; stop and let the operator decide" <<<"$out"
    fi
  ' _ "$tmp/workspace" "$server" 0

  [ "$status" -eq 0 ]

  run bash -c '
    set -euo pipefail
    ws="$1"
    server="$2"
    mode="$3"

    # shellcheck source=/dev/null
    source "$REPO_ROOT/bundle/.ralph/bash-lib/mcp/mcp-setup.sh"

    export NON_INTERACTIVE_FLAG="$mode"
    export RALPH_MCP_POLICY_VIOLATION_MODE="fatal"
    export RALPH_MCP_WORKSPACE="$ws"
    interactivity="$(jq -r '.RALPH_MCP_PROXY_INTERACTIVITY' <<<"$(ralph_mcp_proxy_build_server_env_json "$ws")")"
    export RALPH_MCP_PROXY_INTERACTIVITY="$interactivity"

    payload="$(
      cat <<EOF
{"jsonrpc":"2.0","id":1,"method":"initialize"}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ralph_proxy_read","arguments":{"path":"/etc/passwd"}}}
{"jsonrpc":"2.0","id":3,"method":"exit"}
EOF
    )"

    if [[ "$mode" == "1" ]]; then
      out="$(printf "%s" "$payload" | "$server" 2>/dev/null || true)"
      grep -q "permission denied; find a workaround within the workspace and continue" <<<"$out"
    else
      out="$(printf "%s" "$payload" | "$server" 2>/dev/null || true)"
      grep -q "permission denied; stop and let the operator decide" <<<"$out"
    fi
  ' _ "$tmp/workspace" "$server" 1

  [ "$status" -eq 0 ]

  rm -rf "$tmp"
}

