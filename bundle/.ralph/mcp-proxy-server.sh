#!/usr/bin/env bash
# Ralph MCP proxy server MVP.
#
# This server wraps the bundled Ralph MCP server as a wrapped upstream dependency,
# forwards the JSON-RPC methods required by the current phase, and applies
# lightweight policy-based filtering/truncation to tool results.

set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bash-lib/error-handling.sh
source "$SCRIPT_DIR/bash-lib/error-handling.sh"
# shellcheck source=bash-lib/mcp/mcp-protocol.sh
source "$SCRIPT_DIR/bash-lib/mcp/mcp-protocol.sh"
# shellcheck source=bash-lib/mcp-proxy/mcp-proxy-logging.sh
source "$SCRIPT_DIR/bash-lib/mcp-proxy/mcp-proxy-logging.sh"
# shellcheck source=bash-lib/mcp-proxy/mcp-proxy-capability.sh
source "$SCRIPT_DIR/bash-lib/mcp-proxy/mcp-proxy-capability.sh"
# shellcheck source=bash-lib/mcp-proxy/mcp-proxy-tools.sh
source "$SCRIPT_DIR/bash-lib/mcp-proxy/mcp-proxy-tools.sh"
# shellcheck source=bash-lib/mcp-proxy/mcp-proxy-policy.sh
source "$SCRIPT_DIR/bash-lib/mcp-proxy/mcp-proxy-policy.sh"
# shellcheck source=bash-lib/mcp-proxy/mcp-proxy-result.sh
source "$SCRIPT_DIR/bash-lib/mcp-proxy/mcp-proxy-result.sh"
# shellcheck source=bash-lib/mcp-proxy/mcp-proxy-upstream.sh
source "$SCRIPT_DIR/bash-lib/mcp-proxy/mcp-proxy-upstream.sh"
# shellcheck source=bash-lib/mcp-proxy/mcp-proxy-cache.sh
source "$SCRIPT_DIR/bash-lib/mcp-proxy/mcp-proxy-cache.sh"

print_usage() {
  cat <<EOF
Usage: RALPH_MCP_WORKSPACE=<workspace-root> $SCRIPT_NAME

Environment variables:
  RALPH_MCP_WORKSPACE            Required workspace root for the upstream Ralph MCP server.
  RALPH_MCP_PROXY_LOG_FILE       Optional ledger path for proxy-mode events (defaults to .ralph-workspace/logs/<PLAN_KEY>/mcp-proxy.log when set by the runner).
  RALPH_MCP_PROXY_POLICY         Optional named policy to select from the loaded policy JSON.
  RALPH_MCP_PROXY_POLICY_FILE    Optional path to a JSON policy file.
  RALPH_MCP_PROXY_POLICY_INLINE   Optional inline JSON policy document.
  RALPH_MCP_PROXY_UPSTREAM_SCRIPT Override the upstream Ralph MCP server path.
  RALPH_MCP_PROXY_RUNTIME              Active plan runtime (claude, opencode, etc.) for capability gating of ralph_proxy_* tools.
  RALPH_MCP_PROXY_OWNED_TOOLS_FORCE    Test hook: expose ralph_proxy_* tools without a supporting runtime (set to 1).
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  print_usage
  exit 0
fi

ensure_proxy_runtime() {
  local workspace="${1:-}"
  if [[ -z "$workspace" ]]; then
    ralph_error "Error: RALPH_MCP_WORKSPACE must be set before starting the proxy server."
  fi

  if ! workspace="$(cd "$workspace" && pwd)"; then
    ralph_error "Error: failed to resolve RALPH_MCP_WORKSPACE=$workspace"
  fi

  WORKSPACE_ROOT="$workspace"
  export WORKSPACE_ROOT
  local upstream_script
  if ! upstream_script="$(ralph_mcp_proxy_upstream_script_path "$WORKSPACE_ROOT")"; then
    ralph_error "Error: unable to resolve the upstream Ralph MCP server script."
  fi

  if ! ralph_mcp_proxy_load_policy "$WORKSPACE_ROOT" "$upstream_script"; then
    ralph_error "Error: failed to load proxy policy."
  fi

  local upstream_initialize_response
  if ! upstream_initialize_response="$(ralph_mcp_proxy_upstream_invoke "$WORKSPACE_ROOT" "$upstream_script" "initialize" "{}")"; then
    ralph_error "Error: proxy startup failed because the upstream Ralph MCP server could not initialize."
  fi

  if jq -e '.error? != null' >/dev/null 2>&1 <<< "$upstream_initialize_response"; then
    ralph_error "Error: proxy startup failed because the upstream Ralph MCP server returned an initialize error."
  fi

  RALPH_MCP_PROXY_UPSTREAM_INITIALIZE_RESULT="$(jq -c '.result // {}' <<< "$upstream_initialize_response")"
  export RALPH_MCP_PROXY_UPSTREAM_INITIALIZE_RESULT
  ralph_mcp_proxy_log_action "startup" "workspace=$WORKSPACE_ROOT upstream=$(basename "$upstream_script") policy=${RALPH_MCP_PROXY_POLICY_NAME:-default}"
}

proxy_send_json_response() {
  local request_id_present="$1"
  local request_id_raw="$2"
  local upstream_response_json="$3"

  if jq -e '.error? != null' >/dev/null 2>&1 <<< "$upstream_response_json"; then
    local error_code error_message error_data
    error_code="$(jq -r '.error.code' <<< "$upstream_response_json")"
    error_message="$(jq -r '.error.message' <<< "$upstream_response_json")"
    error_data="$(jq -c '.error.data // empty' <<< "$upstream_response_json")"
    if [[ -n "$error_data" ]]; then
      send_error "$request_id_present" "$request_id_raw" "$error_code" "$error_message" "$error_data"
    else
      send_error "$request_id_present" "$request_id_raw" "$error_code" "$error_message"
    fi
    return 0
  fi

  local result_json
  result_json="$(jq -c '.result // {}' <<< "$upstream_response_json")"
  send_result "$request_id_present" "$request_id_raw" "$result_json"
}

handle_initialize() {
  local request_id_present="$1"
  local request_id_raw="$2"
  local result_json
  local result_text="${RALPH_MCP_PROXY_UPSTREAM_INITIALIZE_RESULT:-}"
  if [[ -z "$result_text" ]]; then
    result_text='{}'
  fi
  result_json="$(
    jq -n -c --arg result_text "$result_text" \
      '{capabilities: (($result_text | fromjson).capabilities // {tools:{listChanged:false}, resources:{listChanged:false}, prompts:{listChanged:false}})}'
  )"
  send_result "$request_id_present" "$request_id_raw" "$result_json"
}

handle_tools_call() {
  local params_json="$1"
  local request_id_present="$2"
  local request_id_raw="$3"
  local tool_name args_json result_json upstream_script upstream_response_json shaped_response_json

  tool_name="$(jq -r '.name // empty' <<< "$params_json" 2>/dev/null || true)"
  args_json="$(jq -c '.arguments // {}' <<< "$params_json" 2>/dev/null || printf '{}')"

  ralph_mcp_proxy_log_request "tools/call" "$request_id_raw" "${RALPH_MCP_PROXY_POLICY_NAME:-default}"

  if ralph_mcp_proxy_is_owned_tool "$tool_name" && ralph_mcp_proxy_owned_tools_active; then
    local cached_owned_result
    if cached_owned_result="$(ralph_mcp_proxy_cache_try_get "tools/call" "$tool_name" "$args_json" "$WORKSPACE_ROOT")"; then
      result_json="$cached_owned_result"
    else
      result_json="$(ralph_mcp_proxy_call_owned_tool "$WORKSPACE_ROOT" "$tool_name" "$args_json")"
      ralph_mcp_proxy_cache_maybe_store "tools/call" "$tool_name" "$args_json" "$WORKSPACE_ROOT" "$result_json"
    fi
    upstream_response_json="$(jq -n -c --argjson result "$result_json" '{result: $result}')"
    shaped_response_json="$(ralph_mcp_proxy_shape_response "tools/call" "$params_json" "$upstream_response_json")"
    proxy_send_json_response "$request_id_present" "$request_id_raw" "$shaped_response_json"
    return 0
  fi

  if ralph_mcp_proxy_call_arguments_denied "$tool_name" "$args_json"; then
    ralph_mcp_proxy_log_action "denied" "tools/call argument blocked for $tool_name: ${RALPH_MCP_PROXY_LAST_DENY_REASON:-policy}"
    send_error "$request_id_present" "$request_id_raw" "-32602" "tool arguments denied by proxy policy: ${RALPH_MCP_PROXY_LAST_DENY_REASON:-denied}"
    return 0
  fi

  if ! ralph_mcp_proxy_tool_allowed "$tool_name"; then
    ralph_mcp_proxy_log_action "denied" "tools/call blocked for $tool_name by policy=${RALPH_MCP_PROXY_POLICY_NAME:-default}"
    send_error "$request_id_present" "$request_id_raw" "-32602" "tool denied by proxy policy: $tool_name"
    return 0
  fi

  upstream_script="$(ralph_mcp_proxy_upstream_script_path "$WORKSPACE_ROOT")"
  local cached_upstream_response
  if cached_upstream_response="$(ralph_mcp_proxy_cache_try_get "tools/call" "$tool_name" "$args_json" "$WORKSPACE_ROOT")"; then
    upstream_response_json="$(jq -n -c --argjson result "$cached_upstream_response" '{result: $result}')"
  else
    if ! upstream_response_json="$(ralph_mcp_proxy_upstream_invoke "$WORKSPACE_ROOT" "$upstream_script" "tools/call" "$params_json")"; then
      send_error "$request_id_present" "$request_id_raw" "-32000" "upstream request failed for tools/call"
      return 0
    fi
    if jq -e '.result? != null' >/dev/null 2>&1 <<< "$upstream_response_json"; then
      ralph_mcp_proxy_cache_maybe_store "tools/call" "$tool_name" "$args_json" "$WORKSPACE_ROOT" "$(jq -c '.result' <<< "$upstream_response_json")"
    fi
    shaped_response_json="$(ralph_mcp_proxy_shape_response "tools/call" "$params_json" "$upstream_response_json")"
    proxy_send_json_response "$request_id_present" "$request_id_raw" "$shaped_response_json"
    return 0
  fi
  shaped_response_json="$(ralph_mcp_proxy_shape_response "tools/call" "$params_json" "$upstream_response_json")"
  proxy_send_json_response "$request_id_present" "$request_id_raw" "$shaped_response_json"
}

handle_forwarded_method() {
  local method="$1"
  local params_json="$2"
  local request_id_present="$3"
  local request_id_raw="$4"
  local upstream_script
  upstream_script="$(ralph_mcp_proxy_upstream_script_path "$WORKSPACE_ROOT")"
  local upstream_response_json shaped_response_json

  ralph_mcp_proxy_log_request "$method" "$request_id_raw" "${RALPH_MCP_PROXY_POLICY_NAME:-default}"

  if [[ "$method" == "tools/call" ]]; then
    handle_tools_call "$params_json" "$request_id_present" "$request_id_raw"
    return 0
  fi

  local cached_method_result args_for_cache
  args_for_cache="$(jq -c '. // {}' <<< "$params_json" 2>/dev/null || printf '{}')"
  if cached_method_result="$(ralph_mcp_proxy_cache_try_get "$method" "" "$args_for_cache" "$WORKSPACE_ROOT")"; then
    upstream_response_json="$(jq -n -c --argjson result "$cached_method_result" '{result: $result}')"
  elif ! upstream_response_json="$(ralph_mcp_proxy_upstream_invoke "$WORKSPACE_ROOT" "$upstream_script" "$method" "$params_json")"; then
    send_error "$request_id_present" "$request_id_raw" "-32000" "upstream request failed for $method"
    return 0
  else
    if jq -e '.result? != null' >/dev/null 2>&1 <<< "$upstream_response_json"; then
      ralph_mcp_proxy_cache_maybe_store "$method" "" "$args_for_cache" "$WORKSPACE_ROOT" "$(jq -c '.result' <<< "$upstream_response_json")"
    fi
  fi

  if [[ "$method" == "tools/list" ]]; then
    shaped_response_json="$(ralph_mcp_proxy_shape_response "$method" "$params_json" "$upstream_response_json")"
    shaped_response_json="$(ralph_mcp_proxy_merge_owned_tools_into_list "$shaped_response_json")"
    proxy_send_json_response "$request_id_present" "$request_id_raw" "$shaped_response_json"
    return 0
  fi

  shaped_response_json="$(ralph_mcp_proxy_shape_response "$method" "$params_json" "$upstream_response_json")"
  proxy_send_json_response "$request_id_present" "$request_id_raw" "$shaped_response_json"
}

dispatch_request() {
  local raw_json="$1"
  local request_id_present request_id_raw method params_json

  request_id_present="$(jq -r 'has("id")' <<< "$raw_json")"
  request_id_raw="$(jq -c '.id // null' <<< "$raw_json")"
  method="$(jq -r '.method // empty' <<< "$raw_json")"
  params_json="$(jq -c '.params // {}' <<< "$raw_json")"

  if [[ -z "$method" ]]; then
    ralph_mcp_proxy_log_action "ignored" "missing method in JSON-RPC request"
    return 0
  fi

  case "$method" in
    initialize)
      handle_initialize "$request_id_present" "$request_id_raw"
      ;;
    initialized)
      ralph_mcp_proxy_log_action "notification" "received initialized"
      ;;
    exit)
      ralph_mcp_proxy_log_action "shutdown" "received exit request"
      if [[ "$request_id_present" == "true" ]]; then
        send_result "$request_id_present" "$request_id_raw" "$(jq -n '{status:"exiting"}')"
      fi
      exit 0
      ;;
    shutdown)
      if [[ "$request_id_present" == "true" ]]; then
        send_result "$request_id_present" "$request_id_raw" "$(jq -n '{status:"shutting_down"}')"
      fi
      ;;
    tools/list|tools/call|resources/list|resources/read)
      handle_forwarded_method "$method" "$params_json" "$request_id_present" "$request_id_raw"
      ;;
    *)
      if [[ "$request_id_present" == "true" ]]; then
        send_error "$request_id_present" "$request_id_raw" "-32601" "method not found: $method"
      fi
      ;;
  esac
}

main() {
  if ! command -v jq >/dev/null 2>&1; then
    ralph_error "Error: jq is required to run the proxy server."
  fi

  ensure_proxy_runtime "${RALPH_MCP_WORKSPACE:-}"
  ralph_mcp_proxy_log_action "ready" "waiting for JSON-RPC requests on stdin"

  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    if [[ -z "${raw_line//[[:space:]]/}" ]]; then
      continue
    fi
    if ! jq -e . >/dev/null 2>&1 <<< "$raw_line"; then
      ralph_mcp_proxy_log_action "ignore" "invalid JSON received"
      continue
    fi
    dispatch_request "$raw_line"
  done
}

main "$@"
