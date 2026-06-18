#!/usr/bin/env bash

if [[ -n "${RALPH_MCP_PROXY_UPSTREAM_LOADED:-}" ]]; then
  return
fi
RALPH_MCP_PROXY_UPSTREAM_LOADED=1

ralph_mcp_proxy_upstream_script_path() {
  local workspace="${1:-}"
  if [[ -n "${RALPH_MCP_PROXY_UPSTREAM_SCRIPT:-}" && -f "${RALPH_MCP_PROXY_UPSTREAM_SCRIPT:-}" ]]; then
    printf '%s\n' "$RALPH_MCP_PROXY_UPSTREAM_SCRIPT"
    return 0
  fi
  if [[ -n "$workspace" && -f "$workspace/.ralph/mcp-server.sh" ]]; then
    printf '%s\n' "$workspace/.ralph/mcp-server.sh"
    return 0
  fi
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."
  if [[ -f "$script_dir/mcp-server.sh" ]]; then
    printf '%s\n' "$script_dir/mcp-server.sh"
    return 0
  fi
  return 1
}

ralph_mcp_proxy_upstream_invoke() {
  local workspace="${1:-}"
  local server_script="${2:-}"
  local method="${3:-}"
  local params_json="${4-}"
  local response_file stderr_file payload exit_code response_line

  if [[ -z "$workspace" || -z "$server_script" || -z "$method" ]]; then
    printf 'Error: workspace, server script, and method are required for upstream invocation.\n' >&2
    return 1
  fi
  if [[ ! -f "$server_script" ]]; then
    printf 'Error: upstream server script not found: %s\n' "$server_script" >&2
    return 1
  fi
  if [[ -z "$params_json" ]]; then
    params_json='{}'
  fi

  local method_json="$method"
  method_json="${method_json//\\/\\\\}"
  method_json="${method_json//\"/\\\"}"
  method_json="\"$method_json\""
  payload="$(printf '{"jsonrpc":"2.0","id":1,"method":%s,"params":%s}' "$method_json" "$params_json")"
  payload+=$'\n'
  payload+='{"jsonrpc":"2.0","id":2,"method":"exit"}'
  payload+=$'\n'

  response_file="$(mktemp)"
  stderr_file="$(mktemp)"
  set +e
  env RALPH_MCP_WORKSPACE="$workspace" bash "$server_script" >"$response_file" 2>"$stderr_file" <<< "$payload"
  exit_code=$?
  set -e

  if [[ "$exit_code" -ne 0 ]]; then
    RALPH_MCP_PROXY_LAST_UPSTREAM_STDERR="$(<"$stderr_file")"
    export RALPH_MCP_PROXY_LAST_UPSTREAM_STDERR
    rm -f "$response_file" "$stderr_file"
    printf 'Error: upstream server exited with code %s.\n' "$exit_code" >&2
    return 1
  fi

  response_line="$(jq -c -s '.[0]' "$response_file" 2>/dev/null || true)"
  rm -f "$response_file" "$stderr_file"
  if [[ -z "$response_line" ]]; then
    printf 'Error: upstream server returned no JSON-RPC response.\n' >&2
    return 1
  fi
  printf '%s\n' "$response_line"
}
