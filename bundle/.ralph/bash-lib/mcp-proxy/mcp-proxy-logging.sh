#!/usr/bin/env bash

if [[ -n "${RALPH_MCP_PROXY_LOGGING_LOADED:-}" ]]; then
  return
fi
RALPH_MCP_PROXY_LOGGING_LOADED=1

# Derive the per-plan MCP log file path from RALPH_PLAN_KEY and workspace env
# vars. Returns a non-empty path when both RALPH_PLAN_KEY and a workspace root
# are set; returns nothing when either is absent.
ralph_mcp_proxy_plan_log_path() {
  local plan_key="${RALPH_PLAN_KEY:-}"
  [[ -n "$plan_key" ]] || return 0
  local workspace_root="${RALPH_PLAN_WORKSPACE_ROOT:-${RALPH_MCP_WORKSPACE:-}}"
  [[ -n "$workspace_root" ]] || return 0
  printf '%s/.ralph-workspace/logs/%s/mcp.log\n' "${workspace_root%/}" "$plan_key"
}

ralph_mcp_proxy_log_line() {
  local level="${1:-info}"
  shift || true
  local message="$*"
  local line
  line="$(printf '[%s] [mcp-proxy] %s: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" "$message")"
  printf '%s' "$line" >&2

  # Resolve log file inline to avoid a subshell per call.
  local _log_file="${RALPH_MCP_PROXY_LOG_FILE:-}"
  if [[ -z "$_log_file" && -n "${RALPH_PLAN_KEY:-}" ]]; then
    local _ws_root="${RALPH_PLAN_WORKSPACE_ROOT:-${RALPH_MCP_WORKSPACE:-}}"
    [[ -n "$_ws_root" ]] && _log_file="${_ws_root%/}/.ralph-workspace/logs/${RALPH_PLAN_KEY}/mcp.log"
  fi
  if [[ -n "$_log_file" ]]; then
    mkdir -p "$(dirname "$_log_file")" 2>/dev/null || true
    printf '%s' "$line" >> "$_log_file" 2>/dev/null || true
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

# Append a structured JSONL record for a tool call to the active plan log.
# Fields: timestamp, tool, request_id, runtime, duration_s, exit_status, extra.
# Silently no-ops when no active log file is configured.
ralph_mcp_proxy_log_tool_call_jsonl() {
  local tool="${1:-}"
  local request_id="${2:-null}"
  local duration_s="${3:-0}"
  local exit_status="${4:-ok}"
  local extra="${5:-}"

  local _log_file="${RALPH_MCP_PROXY_LOG_FILE:-}"
  if [[ -z "$_log_file" && -n "${RALPH_PLAN_KEY:-}" ]]; then
    local _ws_root="${RALPH_PLAN_WORKSPACE_ROOT:-${RALPH_MCP_WORKSPACE:-}}"
    [[ -n "$_ws_root" ]] && _log_file="${_ws_root%/}/.ralph-workspace/logs/${RALPH_PLAN_KEY}/mcp.log"
  fi
  [[ -n "$_log_file" ]] || return 0

  local record
  record="$(jq -nc \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg tool "$tool" \
    --arg request_id "$request_id" \
    --arg runtime "${RUNTIME:-}" \
    --argjson duration_s "${duration_s:-0}" \
    --arg exit_status "$exit_status" \
    --arg extra "${extra:-}" \
    '{ts:$ts, tool:$tool, request_id:$request_id, runtime:$runtime, duration_s:$duration_s, exit_status:$exit_status, extra:($extra | if . == "" then null else . end)}' \
    2>/dev/null)" || return 0

  mkdir -p "$(dirname "$_log_file")" 2>/dev/null || true
  printf '%s\n' "$record" >> "$_log_file" 2>/dev/null || true
}
