#!/usr/bin/env bash

if [[ -n "${RALPH_MCP_PROXY_LOGGING_LOADED:-}" ]]; then
  return
fi
RALPH_MCP_PROXY_LOGGING_LOADED=1

ralph_mcp_proxy_log_line() {
  local level="${1:-info}"
  shift || true
  local message="$*"
  local line
  line="$(printf '[%s] [mcp-proxy] %s: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" "$message")"
  printf '%s' "$line" >&2
  if [[ -n "${RALPH_MCP_PROXY_LOG_FILE:-}" ]]; then
    mkdir -p "$(dirname "$RALPH_MCP_PROXY_LOG_FILE")" 2>/dev/null || true
    printf '%s' "$line" >> "$RALPH_MCP_PROXY_LOG_FILE" 2>/dev/null || true
  fi
}

ralph_mcp_proxy_log_request() {
  local method="${1:-}"
  local request_id="${2:-}"
  local policy_name="${3:-}"
  ralph_mcp_proxy_log_line info "request method=$method id=${request_id:-null} policy=${policy_name:-default}"
}

ralph_mcp_proxy_log_action() {
  local action="${1:-}"
  shift || true
  ralph_mcp_proxy_log_line info "$action${*:+: $*}"
}
