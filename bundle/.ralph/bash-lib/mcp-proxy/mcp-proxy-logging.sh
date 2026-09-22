#!/usr/bin/env bash

if [[ -n "${RALPH_MCP_PROXY_LOGGING_LOADED:-}" ]]; then
  return
fi
RALPH_MCP_PROXY_LOGGING_LOADED=1

# Resolve the plan state root. RALPH_PLAN_WORKSPACE_ROOT is already the state
# root; the legacy RALPH_MCP_WORKSPACE is a project root.
ralph_mcp_proxy_state_root() {
  if [[ -n "${RALPH_PLAN_WORKSPACE_ROOT:-}" ]]; then
    printf '%s\n' "${RALPH_PLAN_WORKSPACE_ROOT%/}"
  elif [[ -n "${RALPH_MCP_WORKSPACE:-}" ]]; then
    printf '%s/.ralph-workspace\n' "${RALPH_MCP_WORKSPACE%/}"
  else
    return 1
  fi
}

ralph_mcp_proxy_ensure_state_paths() {
  if declare -F ralph_state_path_resolve >/dev/null 2>&1; then
    return 0
  fi
  local _dir
  _dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || return 1
  # shellcheck source=../state-paths.sh
  source "$_dir/state-paths.sh"
}

# Derive the per-plan MCP log file path from RALPH_PLAN_KEY and workspace env
# vars. Returns nothing when RALPH_PLAN_KEY or a state root is absent.
ralph_mcp_proxy_plan_log_path() {
  local plan_key="${RALPH_PLAN_KEY:-}"
  [[ -n "$plan_key" ]] || return 0
  local state_root
  state_root="$(ralph_mcp_proxy_state_root)" || return 0
  ralph_mcp_proxy_ensure_state_paths || return 0
  # Plan-scoped MCP log sits beside the plan run tree under logs/<key>/.
  ralph_state_path_resolve "$state_root" "logs/$plan_key/mcp.log"
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
    _log_file="$(ralph_mcp_proxy_plan_log_path)" || true
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
    _log_file="$(ralph_mcp_proxy_plan_log_path)" || true
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
