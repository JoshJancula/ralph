#!/usr/bin/env bash
#
# Standalone Jev MCP server (JSON-RPC over stdio).
#
# Decision tools only — deliberately NOT under bash-lib/mcp-proxy/. That tree
# carries proxy policy, owned-tool dispatch, kill-switch, and RALPH_MODE catalog
# gating; a decision surface must not inherit any of those.
#
# stdout is the protocol channel. ALL logging goes to stderr.

set -uo pipefail
# Do not set IFS globally. jev-client / jev-policy use space-splitting reads
# (e.g. breaker "closed 0"). A global IFS=$'\n' makes jev_available always fail.

readonly SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bash-lib/mcp/mcp-protocol.sh
source "$SCRIPT_DIR/bash-lib/mcp/mcp-protocol.sh"
# shellcheck source=bash-lib/jev/jev-key-store.sh
source "$SCRIPT_DIR/bash-lib/jev/jev-key-store.sh"
# shellcheck source=bash-lib/jev/jev-redact.sh
source "$SCRIPT_DIR/bash-lib/jev/jev-redact.sh"
# shellcheck source=bash-lib/jev/jev-client.sh
source "$SCRIPT_DIR/bash-lib/jev/jev-client.sh"
# shellcheck source=bash-lib/jev/jev-policy.sh
source "$SCRIPT_DIR/bash-lib/jev/jev-policy.sh"

# Curated tool catalog (name-sorted at list time, stable). MUST NOT include a
# nextCursor field in the tools/list result — a null nextCursor caused Claude
# to drop the entire catalog in production.
_JEV_TOOL_LIST_JSON=$(
  cat <<'EOF'
{
  "tools": [
    {
      "name": "jev_ask",
      "description": "UNVERSIONED and UNAUDITED raw escape hatch for exploration. Accepts arbitrary state plus a questions object; prefer curated tools (jev_classify_request, jev_classify_failure, jev_rank_relevance) for auditable versioned decisions. Same redaction and request-size policy as curated tools — escapes the registry only, not the data policy.",
      "inputSchema": {
        "type": "object",
        "additionalProperties": false,
        "properties": {
          "state": {
            "type": "string",
            "description": "State text passed through redaction and size estimation before transport."
          },
          "questions": {
            "type": "object",
            "description": "Arbitrary SystemOne questions object (not a registry question-set id)."
          }
        },
        "required": ["state", "questions"]
      }
    },
    {
      "name": "jev_classify_failure",
      "description": "Classify a graph-stage failure via the versioned graph.failure-class question set. Returns the typed answer plus the Ralph policy decision (act/gather/fallback) and thresholds applied.",
      "inputSchema": {
        "type": "object",
        "additionalProperties": false,
        "properties": {
          "state": {
            "type": "string",
            "description": "Failure evidence text for classification (logs, error summaries)."
          }
        },
        "required": ["state"]
      }
    },
    {
      "name": "jev_classify_request",
      "description": "Route a request via the versioned graph.router-confidence question set. Returns the typed answer plus the Ralph policy decision (act/gather/fallback) and thresholds applied.",
      "inputSchema": {
        "type": "object",
        "additionalProperties": false,
        "properties": {
          "state": {
            "type": "string",
            "description": "Request context for routing (task text, allowed targets)."
          },
          "options": {
            "type": "array",
            "items": {"type": "string"},
            "minItems": 1,
            "maxItems": 255,
            "description": "REQUIRED for this tool: the closed set of choices. This question set's choice options are populated at call time (SystemOne rejects a choice with zero options)."
          }
        },
        "required": ["state", "options"]
      }
    },
    {
      "name": "jev_rank_relevance",
      "description": "Rank evidence/context lines via the versioned compaction.line-relevance question set. Returns the typed answer plus the Ralph policy decision (act/gather/fallback) and thresholds applied.",
      "inputSchema": {
        "type": "object",
        "additionalProperties": false,
        "properties": {
          "state": {
            "type": "string",
            "description": "Tagged evidence or compacted output lines to rank for relevance."
          },
          "options": {
            "type": "array",
            "items": {"type": "string"},
            "minItems": 1,
            "maxItems": 255,
            "description": "REQUIRED for this tool: the closed set of choices. This question set's choice options are populated at call time (SystemOne rejects a choice with zero options)."
          }
        },
        "required": ["state", "options"]
      }
    }
  ]
}
EOF
)

get_tool_list_result() {
  # Sort by name so catalog order is stable across plan keys / process starts.
  jq -c '.tools |= sort_by(.name)' <<< "$_JEV_TOOL_LIST_JSON"
}

# Soft unavailability: SUCCESS with available:false (never isError). Agents must
# cut over to native behavior, not retry or escalate on missing Jev config.
# Modeled on dashboard_mcp_unavailable in mcp-server.sh.
jev_mcp_unavailable() {
  local id_present="$1"
  local id_raw="$2"
  local reason result_json
  reason="$(jev_unavailable_reason 2>/dev/null || printf 'disabled')"
  result_json="$(
    jq -n --arg reason "$reason" '{
      content:[{type:"text",text:("Jev unavailable: " + $reason)}],
      structuredContent:{available:false,reason:$reason},
      isError:false
    }'
  )" || {
    send_error "$id_present" "$id_raw" "-32000" "failed to build unavailable envelope"
    return
  }
  send_result "$id_present" "$id_raw" "$result_json"
}

# Registry top-level version (string). Fail closed to empty on read errors.
_jev_mcp_registry_version() {
  local registry
  registry="$(_jev_policy_registry_path)"
  if [[ ! -f "$registry" ]]; then
    printf '\n'
    return 1
  fi
  jq -r '.registryVersion // empty' "$registry" 2>/dev/null
}

# Mirror of python jev_client.ask: availability + registry questions + build +
# post. Adds questionSetId so fixture transport resolves by set id.
# Prints response JSON on stdout. Exit: 0 | 1 (unavailable/unknown set) |
# 2 (transport) | 3 (input rejected).
_jev_mcp_ask_registered() {
  local question_set_id="${1:-}"
  local state_text="${2:-}"
  local questions_override="${3:-}"
  local questions request response

  [[ -n "$question_set_id" ]] || return 3

  if ! jev_available; then
    return 1
  fi

  if [[ -n "$questions_override" ]]; then
    questions="$questions_override"
  elif ! questions="$(jev_policy_questions "$question_set_id")"; then
    return 1
  fi

  if ! request="$(jev_build_request "$state_text" "$questions")"; then
    return 3
  fi

  if ! request="$(
    jq -c --arg id "$question_set_id" '. + {questionSetId: $id}' <<<"$request" 2>/dev/null
  )"; then
    return 3
  fi

  if ! response="$(jev_post_systemone "$request")"; then
    return $?
  fi

  printf '%s\n' "$response"
  return 0
}

# Shared curated-tool body. question_set_id is fixed per tool; agents cannot
# invent sets — only named, versioned registry entries are callable.
_jev_mcp_handle_curated() {
  local question_set_id="$1"
  local args_json="$2"
  local id_present="$3"
  local id_raw="$4"
  local state_arg response answers decision registry_version result_json
  local questions primary needs_options options_json questions_override=""
  local ask_ec=0

  # Reject unknown keys (additionalProperties false at the schema layer; enforce
  # the same invariant in the handler so bad clients still get -32602).
  if ! echo "$args_json" | jq -e '
    type == "object"
    and ((keys - ["state","options"]) | length == 0)
  ' >/dev/null 2>&1; then
    send_error "$id_present" "$id_raw" "-32602" "invalid params: only state and options are allowed"
    return
  fi

  state_arg="$(echo "$args_json" | jq -r '.state // empty')"
  if [[ -z "$state_arg" ]]; then
    send_error "$id_present" "$id_raw" "-32602" "state is required"
    return
  fi

  # Unavailability is a successful soft result — never isError for missing Jev.
  if ! jev_available; then
    jev_mcp_unavailable "$id_present" "$id_raw"
    return
  fi

  # Some registry sets declare a choice question whose options are populated at
  # call time (router allowedTargets, compaction line ids). SystemOne rejects a
  # choice with zero options, so those sets require an explicit options array.
  if questions="$(jev_policy_questions "$question_set_id" 2>/dev/null)"; then
    primary="$(jev_policy_primary_question "$question_set_id" 2>/dev/null || printf '')"
    if [[ -n "$primary" ]]; then
      needs_options="$(
        jq -r --arg q "$primary" '
          if (.[$q].type == "choice") and (((.[$q].criteria // {}) | length) == 0)
          then "yes" else "no" end
        ' <<<"$questions" 2>/dev/null || printf 'no'
      )"
      if [[ "$needs_options" == "yes" ]]; then
        options_json="$(
          jq -c 'if (.options | type) == "array" then .options else empty end' \
            <<<"$args_json" 2>/dev/null || printf ''
        )"
        if [[ -z "$options_json" ]] || ! jq -e '
          length > 0 and length <= 255 and all(.[]; type == "string" and length > 0)
        ' >/dev/null 2>&1 <<<"$options_json"; then
          send_error "$id_present" "$id_raw" "-32602" \
            "question set $question_set_id needs options: 1-255 non-empty strings"
          return
        fi
        questions_override="$(
          jq -c --arg q "$primary" --argjson opts "$options_json" \
            '.[$q].criteria = ($opts | map({(.): null}) | add)' <<<"$questions" 2>/dev/null
        )" || {
          send_error "$id_present" "$id_raw" "-32000" "failed to apply options to $question_set_id"
          return
        }
      fi
    fi
  fi


  response="$(_jev_mcp_ask_registered "$question_set_id" "$state_arg" "$questions_override")" || ask_ec=$?
  if [[ "$ask_ec" -ne 0 ]]; then
    case "$ask_ec" in
      1)
        # Availability already passed; remaining code-1 path is unknown set.
        send_error "$id_present" "$id_raw" "-32000" "unknown question set: $question_set_id"
        ;;
      3)
        send_error "$id_present" "$id_raw" "-32602" "state rejected before transport (redaction or size)"
        ;;
      *)
        send_error "$id_present" "$id_raw" "-32000" "jev transport or protocol failure for $question_set_id"
        ;;
    esac
    return
  fi

  answers="$(jq -c '.answers // empty' <<<"$response" 2>/dev/null)" || answers=""
  if [[ -z "$answers" || "$answers" == "null" ]]; then
    send_error "$id_present" "$id_raw" "-32000" "jev response missing answers"
    return
  fi

  if ! decision="$(jev_policy_decide "$question_set_id" "$answers")"; then
    send_error "$id_present" "$id_raw" "-32000" "policy decide failed for $question_set_id"
    return
  fi

  if ! registry_version="$(_jev_mcp_registry_version)" || [[ -z "$registry_version" ]]; then
    send_error "$id_present" "$id_raw" "-32000" "registry version unavailable"
    return
  fi

  result_json="$(
    jq -n \
      --argjson answer "$answers" \
      --argjson decision "$decision" \
      --arg questionSetId "$question_set_id" \
      --arg registryVersion "$registry_version" \
      '{
        content:[{
          type:"text",
          text:(
            "questionSetId=" + $questionSetId
            + " decision=" + ($decision.decision // "")
            + " reason=" + ($decision.reason // "")
            + " confidence=" + (($decision.confidence // null) | tostring)
          )
        }],
        structuredContent:{
          answer:$answer,
          decision:$decision,
          questionSetId:$questionSetId,
          registryVersion:$registryVersion
        },
        isError:false
      }'
  )" || {
    send_error "$id_present" "$id_raw" "-32000" "failed to build result envelope"
    return
  }

  send_result "$id_present" "$id_raw" "$result_json"
}

handle_jev_classify_request() {
  _jev_mcp_handle_curated "graph.router-confidence" "$1" "$2" "$3"
}

handle_jev_classify_failure() {
  _jev_mcp_handle_curated "graph.failure-class" "$1" "$2" "$3"
}

handle_jev_rank_relevance() {
  _jev_mcp_handle_curated "compaction.line-relevance" "$1" "$2" "$3"
}

# Raw escape hatch: arbitrary state + questions. Same redact/size path as curated
# tools (jev_build_request); no registry lookup and no policy decide.
handle_jev_ask() {
  local args_json="$1"
  local id_present="$2"
  local id_raw="$3"
  local state_arg questions_json request response answers result_json
  local build_ec=0
  local post_ec=0

  if ! echo "$args_json" | jq -e '
    type == "object"
    and ((keys - ["state", "questions"]) | length == 0)
  ' >/dev/null 2>&1; then
    send_error "$id_present" "$id_raw" "-32602" "invalid params: only state and questions are allowed"
    return
  fi

  state_arg="$(echo "$args_json" | jq -r '.state // empty')"
  if [[ -z "$state_arg" ]]; then
    send_error "$id_present" "$id_raw" "-32602" "state is required"
    return
  fi

  if ! echo "$args_json" | jq -e '.questions | type == "object"' >/dev/null 2>&1; then
    send_error "$id_present" "$id_raw" "-32602" "questions must be an object"
    return
  fi
  questions_json="$(echo "$args_json" | jq -c '.questions')"

  if ! jev_available; then
    jev_mcp_unavailable "$id_present" "$id_raw"
    return
  fi

  # Identical redaction + size estimation as curated tools / jev_build_request.
  request="$(jev_build_request "$state_arg" "$questions_json")" || build_ec=$?
  if [[ "$build_ec" -ne 0 ]]; then
    send_error "$id_present" "$id_raw" "-32602" "state rejected before transport (redaction or size)"
    return
  fi

  response="$(jev_post_systemone "$request")" || post_ec=$?
  if [[ "$post_ec" -ne 0 ]]; then
    send_error "$id_present" "$id_raw" "-32000" "jev transport or protocol failure"
    return
  fi

  answers="$(jq -c '.answers // empty' <<<"$response" 2>/dev/null)" || answers=""
  if [[ -z "$answers" || "$answers" == "null" ]]; then
    send_error "$id_present" "$id_raw" "-32000" "jev response missing answers"
    return
  fi

  result_json="$(
    jq -n \
      --argjson answer "$answers" \
      '{
        content:[{
          type:"text",
          text:"jev_ask UNVERSIONED/UNAUDITED answer returned (prefer curated tools for auditable decisions)"
        }],
        structuredContent:{
          answer:$answer,
          unversioned:true,
          unaudited:true
        },
        isError:false
      }'
  )" || {
    send_error "$id_present" "$id_raw" "-32000" "failed to build result envelope"
    return
  }

  send_result "$id_present" "$id_raw" "$result_json"
}

handle_initialize() {
  local id_present="$1"
  local id_raw="$2"
  ralph_mcp_log "handling initialize"
  # Same protocol version string as bundle/.ralph/mcp-server.sh.
  local result='{"protocolVersion":"2025-11-25","serverInfo":{"name":"ralph-jev","version":"1.0.0"},"capabilities":{"tools":{"listChanged":false}}}'
  send_result "$id_present" "$id_raw" "$result"
}

handle_initialized() {
  ralph_mcp_log "received initialized notification"
}

handle_shutdown() {
  local id_present="$1"
  local id_raw="$2"
  ralph_mcp_log "shutdown requested"
  send_result "$id_present" "$id_raw" '{"status":"shutting_down"}'
}

handle_exit() {
  local id_present="$1"
  local id_raw="$2"
  ralph_mcp_log "exit requested; terminating jev MCP server"
  send_result "$id_present" "$id_raw" '{"status":"exiting"}'
  exit 0
}

handle_list_tools() {
  local id_present="$1"
  local id_raw="$2"
  # Result is exactly {tools:[...]} — no nextCursor key, ever.
  send_result "$id_present" "$id_raw" "$(get_tool_list_result)"
}

handle_call_tool() {
  local tool_name="$1"
  local args_json="$2"
  local id_present="$3"
  local id_raw="$4"

  case "$tool_name" in
    jev_ask)
      handle_jev_ask "$args_json" "$id_present" "$id_raw"
      ;;
    jev_classify_request)
      handle_jev_classify_request "$args_json" "$id_present" "$id_raw"
      ;;
    jev_classify_failure)
      handle_jev_classify_failure "$args_json" "$id_present" "$id_raw"
      ;;
    jev_rank_relevance)
      handle_jev_rank_relevance "$args_json" "$id_present" "$id_raw"
      ;;
    *)
      send_error "$id_present" "$id_raw" "-32601" "tool not found: ${tool_name:-}"
      ;;
  esac
}

dispatch_request() {
  local method="$1"
  local id_present="$2"
  local id_raw="$3"
  local payload="$4"

  case "$method" in
    initialize)
      handle_initialize "$id_present" "$id_raw"
      ;;
    initialized|notifications/initialized)
      handle_initialized
      ;;
    shutdown)
      handle_shutdown "$id_present" "$id_raw"
      ;;
    exit)
      handle_exit "$id_present" "$id_raw"
      ;;
    tools/list)
      handle_list_tools "$id_present" "$id_raw"
      ;;
    tools/call)
      local tool_name
      local args_json
      tool_name="$(echo "$payload" | jq -r '.params.name // empty')"
      args_json="$(echo "$payload" | jq -c '.params.arguments // {}')"
      handle_call_tool "$tool_name" "$args_json" "$id_present" "$id_raw"
      ;;
    *)
      local message="method not found: $method"
      ralph_mcp_log "$message"
      send_error "$id_present" "$id_raw" "-32601" "$message"
      ;;
  esac
}

main() {
  ensure_jq

  # Workspace is optional for decision tools; registration always sets it.
  if [[ -n "${RALPH_MCP_WORKSPACE:-}" ]]; then
    local workspace
    if workspace="$(cd "$RALPH_MCP_WORKSPACE" && pwd 2>/dev/null)"; then
      export RALPH_MCP_WORKSPACE="$workspace"
      ralph_mcp_log "starting jev MCP server for workspace $workspace"
    else
      ralph_mcp_log "RALPH_MCP_WORKSPACE=$RALPH_MCP_WORKSPACE could not be resolved; continuing"
    fi
  else
    ralph_mcp_log "starting jev MCP server (no RALPH_MCP_WORKSPACE)"
  fi

  ralph_mcp_log "waiting for JSON-RPC requests on stdin"

  while true; do
    local raw
    # Empty IFS: read one full line without trimming; do not touch global IFS.
    if ! IFS= read -r raw; then
      ralph_mcp_log "stdin closed; exiting"
      break
    fi

    if [[ -z "${raw//[[:space:]]/}" ]]; then
      continue
    fi

    local parsed
    if ! parsed="$(echo "$raw" | jq -r '"\(.jsonrpc // "")\t\(has("id"))\t\(.id // null | tojson)\t\(.method // "")"' 2>/dev/null)"; then
      ralph_mcp_log "invalid JSON received; ignoring line"
      continue
    fi

    local jsonrpc id_present id_raw method
    # Tab-split the jq tuple only; restore default IFS for jev library calls.
    IFS=$'\t' read -r jsonrpc id_present id_raw method <<< "$parsed" || true
    IFS=$' \t\n'

    if [[ -z "$jsonrpc" || "$jsonrpc" != "2.0" ]]; then
      ralph_mcp_log "invalid or missing jsonrpc version; rejecting request"
      send_error "$id_present" "$id_raw" "-32600" "jsonrpc=2.0 is required"
      continue
    fi

    if [[ -z "$method" ]]; then
      ralph_mcp_log "missing method in request; ignoring"
      continue
    fi

    dispatch_request "$method" "$id_present" "$id_raw" "$raw"
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
