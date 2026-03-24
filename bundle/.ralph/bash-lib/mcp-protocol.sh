# Minimal JSON-RPC protocol helpers for the MCP server.

ralph_mcp_log() {
  printf '[%s] %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SCRIPT_NAME" "$*" >&2
}

fail() {
  ralph_mcp_log "$*"
  exit 1
}

ensure_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    fail "jq is required to parse MCP JSON-RPC messages; please install it before running the server."
  fi
}

send_result() {
  local id_present="$1"
  local id_raw="$2"
  local result_json="$3"

  if [[ "$id_present" != "true" ]]; then
    ralph_mcp_log "notification received; skipping response"
    return
  fi

  local response
  response="$(
    jq -n \
      --argjson id "$id_raw" \
      --argjson result "$result_json" \
      '{"jsonrpc":"2.0","id":$id,"result":$result}'
  )"

  printf '%s\n' "$response"
}

send_error() {
  local id_present="$1"
  local id_raw="$2"
  local code="$3"
  local message="$4"
  local data_json="${5:-}"

  if [[ "$id_present" != "true" ]]; then
    ralph_mcp_log "cannot send error (missing id): $message"
    return
  fi

  local error_payload
  if [[ -n "$data_json" ]]; then
    error_payload="$(
      jq -n \
        --argjson data "$data_json" \
        --arg code "$code" \
        --arg message "$message" \
        '{code: ($code | tonumber), message: $message, data: $data}'
    )"
  else
    error_payload="$(
      jq -n \
        --arg code "$code" \
        --arg message "$message" \
        '{code: ($code | tonumber), message: $message}'
    )"
  fi

  local response
  response="$(
    jq -n \
      --argjson id "$id_raw" \
      --argjson error "$error_payload" \
      '{"jsonrpc":"2.0","id":$id,"error":$error}'
  )"

  printf '%s\n' "$response"
}

auth_token_guard_enabled() {
  [[ -n "${MCP_AUTH_TOKEN:-}" ]]
}

enforce_auth_token() {
  local raw="$1"
  local id_present="$2"
  local id_raw="$3"
  if ! auth_token_guard_enabled; then
    return 0
  fi
  local provided
  provided="$(echo "$raw" | jq -r '.authToken // empty')"
  if [[ "$provided" != "$MCP_AUTH_TOKEN" ]]; then
    ralph_mcp_log "unauthorized request received (missing or mismatched authToken)"
    if [[ "$id_present" == "true" ]]; then
      send_error "$id_present" "$id_raw" "-32001" "unauthorized"
    else
      ralph_mcp_log "cannot send unauthorized response (notifications lack id)"
    fi
    return 1
  fi
  return 0
}

# JSON-RPC send helpers and auth only. Method dispatch and MCP handlers live in
# mcp-server.sh (single source of truth for the advertised surface).
