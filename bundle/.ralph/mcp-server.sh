#!/usr/bin/env bash
#
# Minimal MCP server loop implemented entirely with Bash and jq so that
# the Cursor/Claude/Codex orchestrator can connect over stdio without
# requiring Python or Node.
#
# One canonical MCP server implementation for all runtimes. Keep policy and
# workspace initialization lazy, but source the protocol/tool/resource helpers
# before any top-level catalog construction so startup stays correct.

set -uo pipefail
IFS=$'\n'

readonly SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Server helpers loaded before any top-level tool/resource catalog assembly.
RALPH_MCP_LIBS_LOADED=0

load_server_libs() {
  if [[ "$RALPH_MCP_LIBS_LOADED" == "1" ]]; then
    return 0
  fi
  RALPH_MCP_LIBS_LOADED=1

  # shellcheck source=bash-lib/error-handling.sh
  source "$SCRIPT_DIR/bash-lib/error-handling.sh"
  # shellcheck source=bash-lib/mcp/mcp-protocol.sh
  source "$SCRIPT_DIR/bash-lib/mcp/mcp-protocol.sh"
  # shellcheck source=bash-lib/mcp/mcp-resources.sh
  source "$SCRIPT_DIR/bash-lib/mcp/mcp-resources.sh"
  # shellcheck source=bash-lib/plan-todo.sh
  source "$SCRIPT_DIR/bash-lib/plan-todo.sh"
  # shellcheck source=bash-lib/mcp/mcp-tools.sh
  source "$SCRIPT_DIR/bash-lib/mcp/mcp-tools.sh"
  # shellcheck source=bash-lib/mcp/mcp-prompts.sh
  source "$SCRIPT_DIR/bash-lib/mcp/mcp-prompts.sh"

  if [[ -z "${RALPH_MCP_PROXY_LOGGING_LOADED:-}" ]]; then
    # shellcheck source=bash-lib/mcp-proxy/mcp-proxy-logging.sh
    source "$SCRIPT_DIR/bash-lib/mcp-proxy/mcp-proxy-logging.sh"
  fi

  # shellcheck source=bash-lib/mcp-proxy/mcp-proxy-policy.sh
  source "$SCRIPT_DIR/bash-lib/mcp-proxy/mcp-proxy-policy.sh"
  # shellcheck source=bash-lib/mcp-proxy/mcp-proxy-result.sh
  source "$SCRIPT_DIR/bash-lib/mcp-proxy/mcp-proxy-result.sh"
  # shellcheck source=bash-lib/mcp-proxy/mcp-proxy-tools.sh
  source "$SCRIPT_DIR/bash-lib/mcp-proxy/mcp-proxy-tools.sh"
  # shellcheck source=bash-lib/mcp-proxy/mcp-proxy-approvals.sh
  source "$SCRIPT_DIR/bash-lib/mcp-proxy/mcp-proxy-approvals.sh"
}

load_server_libs

if [[ -n "${RALPH_MODE-}" ]]; then
  mode="$(tr '[:upper:]' '[:lower:]' <<<"${RALPH_MODE:-no}" | tr -d '\r\n')"
  if [[ "$mode" == "no" ]]; then
    echo "Error: Ralph MCP preflight cannot run with RALPH_MODE=no. Use native, ralph, or hybrid when starting the MCP server." >&2
    exit 1
  fi
fi

RALPH_MCP_TOOL_CALL_PROGRESS_TOKEN=""

ralph_mcp_approvals_on_progress() {
  local request_id="${1:-}"
  local elapsed="${2:-0}"
  local timeout="${3:-0}"
  if [[ -z "${RALPH_MCP_TOOL_CALL_PROGRESS_TOKEN:-}" ]]; then
    return 0
  fi
  send_notification "notifications/progress" "$(
    jq -n -c \
      --arg token "$RALPH_MCP_TOOL_CALL_PROGRESS_TOKEN" \
      --argjson progress "$elapsed" \
      --argjson total "$timeout" \
      --arg message "waiting for operator approval (${request_id})" \
      '{progressToken: $token, progress: $progress, total: $total, message: $message}'
  )"
}

send_proxy_owned_tool_result() {
  local tool_name="$1"
  local args_json="$2"
  local id_present="$3"
  local id_raw="$4"
  local result_json="$5"
  local params_json upstream_response_json shaped_response_json

  params_json="$(
    jq -n -c --arg name "$tool_name" --argjson arguments "$args_json" \
      '{name: $name, arguments: $arguments}'
  )"
  upstream_response_json="$(jq -n -c --argjson result "$result_json" '{result: $result}')"
  shaped_response_json="$(ralph_mcp_proxy_shape_response "tools/call" "$params_json" "$upstream_response_json")"
  result_json="$(jq -c '.result // {}' <<< "$shaped_response_json")"
  send_result "$id_present" "$id_raw" "$result_json"
}

invoke_proxy_owned_tool_once() {
  local tool_name="$1"
  local args_json="$2"
  local result_var="${3:-}"
  local temp_result_file tool_result_json

  temp_result_file="$(mktemp)"
  ralph_mcp_proxy_call_owned_tool "$WORKSPACE_ROOT" "$tool_name" "$args_json" >"$temp_result_file"
  tool_result_json="$(<"$temp_result_file")"
  rm -f "$temp_result_file"
  if [[ -n "$result_var" ]]; then
    printf -v "$result_var" '%s' "$tool_result_json"
  else
    printf '%s' "$tool_result_json"
  fi
}

handle_proxy_tool_violation_approve() {
  local id_present="$1"
  local id_raw="$2"
  local tool_name="$3"
  local message="$4"
  local reason="$5"
  local category="$6"
  local args_json="$7"
  local request_id deny_reason retry_json

  request_id="$(ralph_mcp_approvals_write_request "$tool_name" "$category" "$reason" "$args_json")" || {
    send_error "$id_present" "$id_raw" "-32603" "failed to create approval request"
    return
  }

  # Approve-mode boundary violations are escalated and denied immediately.
  # We still write the request JSON + audit log entry, but we do not wait
  # for operator decision.
  deny_reason='approval escalated'
  ralph_mcp_approvals_finalize "$request_id" "escalated" "$deny_reason" "server"
  send_proxy_owned_tool_result "$tool_name" "$args_json" "$id_present" "$id_raw" \
    "$(ralph_mcp_proxy_tool_error_json "operator approval escalated: $deny_reason")"
}

dispatch_proxy_tool_violation() {
  local id_present="$1"
  local id_raw="$2"
  local tool_name="$3"
  local message="$4"
  local reason="${5:-$message}"
  local arguments="${6:-}"
  local category="${7:-boundary}"
  local args_json="${8-}"
  if [[ -z "$args_json" ]]; then
    args_json='{}'
  fi

  local mode
  mode="$(ralph_mcp_policy_violation_mode_effective)"

  # Thread runner interactivity into MCP denial wording.
  # This only affects the operator-facing message prefix; classification/extraction
  # still relies on the remainder of "$message".
  local interactivity_prefix=""
  case "${RALPH_MCP_PROXY_INTERACTIVITY:-interactive}" in
    non-interactive)
      interactivity_prefix="permission denied; find a workaround within the workspace and continue"
      ;;
    interactive|*)
      interactivity_prefix="permission denied; stop and let the operator decide"
      ;;
  esac

  if [[ "${RALPH_MCP_PROXY_APPROVAL_RETRY:-0}" == "1" ]]; then
    send_proxy_owned_tool_result "$tool_name" "$args_json" "$id_present" "$id_raw" \
      "$(ralph_mcp_proxy_tool_error_json "policy blocked after operator approval: $reason")"
    return 0
  fi

  case "$mode" in
    error)
      send_error "$id_present" "$id_raw" "-32001" "$message"
      ralph_mcp_proxy_log_action "policy violation" "tool=$tool_name reason=$reason mode=error"
      return 0
      ;;
    approve)
      handle_proxy_tool_violation_approve \
        "$id_present" "$id_raw" "$tool_name" "$message" "$reason" "$category" "$args_json"
      return 0
      ;;
    fatal|*)
      # For boundary violations, attach an operator-action hint that differs
      # between interactive and non-interactive runs.
      if [[ "$category" == "boundary" ]]; then
        message="$interactivity_prefix; $message"
      fi
      send_error "$id_present" "$id_raw" "-32001" "$message"
      ralph_mcp_proxy_log_action "fatal violation" "tool=$tool_name reason=$reason"
      ralph_mcp_policy_violation_fatal "$tool_name" "proxy" "$reason" "$arguments"
      exit "$RALPH_MCP_POLICY_VIOLATION_EXIT_CODE"
      ;;
  esac
}

normalize_tool_access() {
  local value="$1"
  value="$(tr '[:upper:]' '[:lower:]' <<<"$value" | tr -d '\r\n')"
  case "$value" in
    native|ralph)
      printf '%s' "$value"
      ;;
    *)
      return 1
      ;;
  esac
}

contains_control_bytes() {
  local candidate="$1"
  if [[ -z "$candidate" ]]; then
    return 1
  fi
  LC_ALL=C printf '%s' "$candidate" | grep -q '[[:cntrl:]]'
}

env_override_allowed_name() {
  local name="$1"
  case "$name" in
    RALPH_AGENT_TOOL_ACCESS|RALPH_MCP_PROXY_POLICY*|RALPH_PLAN_*|CURSOR_PLAN_MODEL|CLAUDE_PLAN_MODEL|CODEX_PLAN_MODEL|OPENCODE_PLAN_MODEL)
      return 0
      ;;
  esac
  return 1
}

setup_colors() {
  if [[ -t 1 ]]; then
    C_G=$'\033[32m'
    C_B=$'\033[34m'
    C_Y=$'\033[33m'
    C_BOLD=$'\033[1m'
    C_RST=$'\033[0m'
  else
    C_G="" C_B="" C_Y="" C_BOLD="" C_RST=""
  fi
}

setup_colors

print_usage() {
  cat <<EOF
${C_BOLD}${C_G}Usage:${C_RST} RALPH_MCP_WORKSPACE=<workspace-root> $SCRIPT_NAME

${C_BOLD}Environment variables:${C_RST}
  ${C_G}RALPH_MCP_WORKSPACE${C_RST}        Required path to the repo workspace the MCP server exposes.
                                   Legacy: treated as project root when RALPH_PROJECT_ROOT is absent.
  ${C_G}RALPH_PROJECT_ROOT${C_RST}         Ralph project root (where .ralph/ lives). Falls back to RALPH_MCP_WORKSPACE.
  ${C_G}RALPH_AGENT_WORKSPACE${C_RST}      Agent sandbox workspace (where the assistant operates). Falls back to RALPH_MCP_WORKSPACE.
  ${C_G}RALPH_PLAN_WORKSPACE_ROOT${C_RST}  Plan state root (where .ralph-workspace/ lives). Falls back to RALPH_MCP_WORKSPACE.
  ${C_G}RALPH_MCP_ALLOWLIST${C_RST}      Optional colon/comma/semicolon-separated dirs (relative to workspace) to allow in requests.

${C_BOLD}Options:${C_RST}
  ${C_G}--help${C_RST}                   Show this help message and exit.

${C_BOLD}Dependencies:${C_RST}
  ${C_Y}jq${C_RST}                        Required for parsing MCP JSON-RPC payloads.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  print_usage
  exit 0
fi

readonly ORCHESTRATOR_SCRIPT=".ralph/orchestrator.sh"
MCP_AUTH_TOKEN="${RALPH_MCP_AUTH_TOKEN:-}"

WORKSPACE_ROOT=""
WORKSPACE_ROOT_PREFIX=""
ALLOWLIST_ROOTS=()

_BASE_TOOL_LIST_JSON=$(
  cat <<'EOF'
{
  "tools": [
    {
      "name": "ralph_run_plan",
      "description": "Execute a plan.",
      "inputSchema": {
        "type": "object",
        "properties": {
          "workspace": { "type": "string", "description": "Workspace root path." },
          "plan_path": { "type": "string", "description": "Plan file path." },
          "runtime": { "type": "string", "description": "Runtime: cursor, claude, codex, opencode, antigravity." },
          "agent": { "type": "string", "description": "Agent name." },
          "tool_access": {
            "type": "string",
            "enum": ["native", "ralph"],
            "description": "Tool access mode."
          },
          "non_interactive": { "type": "boolean", "description": "Skip TTY prompts." },
          "env_overrides": {
            "type": "object",
            "additionalProperties": { "type": "string" },
            "description": "Environment variable overrides."
          }
        },
        "required": ["workspace", "plan_path", "runtime", "agent"]
      }
    },
    {
      "name": "ralph_plan_status",
      "description": "Count TODOs and report plan metadata.",
      "inputSchema": {
        "type": "object",
        "properties": {
          "workspace": { "type": "string", "description": "Workspace root path." },
          "plan_path": { "type": "string", "description": "Plan file path." }
        },
        "required": ["workspace", "plan_path"]
      }
    },
    {
      "name": "ralph_orchestrator_run",
      "description": "Execute an orchestration pipeline.",
      "inputSchema": {
        "type": "object",
        "properties": {
          "workspace": { "type": "string", "description": "Workspace root path." },
          "orchestration_path": { "type": "string", "description": "Orchestration JSON file path." },
          "dry_run": { "type": "boolean", "description": "Print steps without running." },
          "env_overrides": {
            "type": "object",
            "additionalProperties": { "type": "string" },
            "description": "Environment variable overrides."
          }
        },
        "required": ["workspace", "orchestration_path"]
      }
    },
    {
      "name": "ralph_complete_todo",
      "description": "Report completion or retry for the current active TODO using the runner-provided identity.",
      "inputSchema": {
        "type": "object",
        "properties": {
          "workspace": { "type": "string", "description": "Workspace root path." },
          "plan_path": { "type": "string", "description": "Plan file path." },
          "todo_ref": {
            "type": "object",
            "properties": {
              "line": { "type": "string", "description": "Current runner todo line or ordinal token." },
              "ordinal": { "type": "string", "description": "1-based todo ordinal." },
              "id": { "type": "string", "description": "TODO id when present." },
              "hash": { "type": "string", "description": "Stable todo hash." }
            },
            "required": ["line", "ordinal", "hash"]
          },
          "outcome": {
            "type": "string",
            "enum": ["complete", "needs_retry"],
            "description": "Whether the active TODO is done or should be retried."
          },
          "verification_status": {
            "type": "string",
            "enum": ["pass", "fail", "not_run"],
            "description": "Verification verdict to emit."
          },
          "summary": { "type": "string", "description": "Short completion or retry summary." },
          "verification_note": { "type": "string", "description": "Optional verification detail." },
          "tool_result_ids": {
            "type": "array",
            "items": { "type": "string" },
            "description": "Optional Ralph tool-result ids used for verification."
          }
        },
        "required": ["workspace", "plan_path", "todo_ref", "outcome", "verification_status", "summary"]
      }
    }
  ]
}
EOF
)

TOOL_LIST_RESULT=""

get_tool_list_result() {
  if [[ -z "$TOOL_LIST_RESULT" ]]; then
    local mode proxy_json result_tools_json tools_array
    mode="$(tr '[:upper:]' '[:lower:]' <<<"${RALPH_MODE:-no}" | tr -d '\r\n')"
    case "$mode" in
      ralph|hybrid)
        proxy_json="$(ralph_mcp_proxy_owned_tools_json)"
        ;;
      native)
        if ralph_mcp_proxy_compact_tool_catalog_active; then
          proxy_json="$(ralph_mcp_proxy_compact_meta_tools_json)"
        else
          proxy_json='[]'
        fi
        ;;
      *)
        proxy_json='[]'
        ;;
    esac
    result_tools_json="$(ralph_mcp_proxy_result_tools_json)"
    TOOL_LIST_RESULT=$(
      jq -c \
        --argjson proxy "$proxy_json" \
        --argjson result "$result_tools_json" \
        '.tools += $proxy | .tools += $result | .tools |= sort_by(.name)' \
        <<< "$_BASE_TOOL_LIST_JSON"
    )
    if ralph_mcp_proxy_compact_tool_catalog_active; then
      local core_names
      core_names="$(ralph_mcp_proxy_core_tool_names_json)"
      TOOL_LIST_RESULT=$(
        jq -c --argjson core "$core_names" '
          .tools |= map(
            . as $tool
            | ($tool.name // "") as $n
            | if ($n == "ralph_run_plan" or $n == "ralph_plan_status" or $n == "ralph_orchestrator_run") then .
              elif ($core | index($n)) != null then .
              else empty
              end
          )
          | .tools |= sort_by(.name)
        ' <<< "$TOOL_LIST_RESULT"
      )
    fi
    tools_array="$(jq -c '.tools' <<<"$TOOL_LIST_RESULT")"
    ralph_mcp_proxy_record_tools_list_telemetry "$tools_array"
  fi
  printf '%s' "$TOOL_LIST_RESULT"
}

handle_complete_todo() {
  local args_json="$1"
  local id_present="$2"
  local id_raw="$3"
  local workspace_arg plan_arg outcome_arg verification_status_arg summary_arg verification_note_arg
  local todo_line_arg todo_ordinal_arg todo_id_arg todo_hash_arg

  workspace_arg="$(echo "$args_json" | jq -r '.workspace // empty')"
  plan_arg="$(echo "$args_json" | jq -r '.plan_path // empty')"
  outcome_arg="$(echo "$args_json" | jq -r '.outcome // empty')"
  verification_status_arg="$(echo "$args_json" | jq -r '.verification_status // empty')"
  summary_arg="$(echo "$args_json" | jq -r '.summary // empty')"
  verification_note_arg="$(echo "$args_json" | jq -r '.verification_note // empty')"
  todo_line_arg="$(echo "$args_json" | jq -r '.todo_ref.line // empty')"
  todo_ordinal_arg="$(echo "$args_json" | jq -r '.todo_ref.ordinal // empty')"
  todo_id_arg="$(echo "$args_json" | jq -r '.todo_ref.id // empty')"
  todo_hash_arg="$(echo "$args_json" | jq -r '.todo_ref.hash // empty')"

  if [[ -z "$workspace_arg" || -z "$plan_arg" || -z "$outcome_arg" || -z "$verification_status_arg" || -z "$summary_arg" ]]; then
    send_error "$id_present" "$id_raw" "-32602" "workspace, plan_path, outcome, verification_status, and summary are required"
    return
  fi

  local workspace_path plan_path
  if ! workspace_path="$(resolve_workspace "$workspace_arg")"; then
    send_error "$id_present" "$id_raw" "-32602" "workspace not allowed: $workspace_arg"
    return
  fi
  if ! plan_path="$(resolve_plan_path "$workspace_path" "$plan_arg")"; then
    send_error "$id_present" "$id_raw" "-32602" "plan path invalid, outside workspace, or not allowlisted: $plan_arg"
    return
  fi
  if [[ "$workspace_path" != "$WORKSPACE_ROOT" ]]; then
    send_error "$id_present" "$id_raw" "-32602" "workspace does not match current MCP workspace: $workspace_arg"
    return
  fi
  if [[ -z "${RALPH_CURRENT_PLAN_PATH:-}" || -z "${RALPH_CURRENT_TODO_LINE:-}" || -z "${RALPH_CURRENT_TODO_ORDINAL:-}" || -z "${RALPH_CURRENT_TODO_HASH:-}" ]]; then
    send_error "$id_present" "$id_raw" "-32602" "active TODO context is unavailable; the runner must export current todo identity before calling ralph_complete_todo"
    return
  fi
  if [[ "$plan_path" != "$RALPH_CURRENT_PLAN_PATH" ]]; then
    send_error "$id_present" "$id_raw" "-32602" "plan path does not match current TODO context: $plan_arg"
    return
  fi
  if [[ "$todo_line_arg" != "${RALPH_CURRENT_TODO_LINE:-}" || "$todo_ordinal_arg" != "${RALPH_CURRENT_TODO_ORDINAL:-}" || "$todo_id_arg" != "${RALPH_CURRENT_TODO_ID:-}" || "$todo_hash_arg" != "${RALPH_CURRENT_TODO_HASH:-}" ]]; then
    send_error "$id_present" "$id_raw" "-32602" "todo_ref does not match the current TODO context"
    return
  fi

  local plan_format
  if ! plan_format="$(plan_detect_format "$plan_path")"; then
    send_error "$id_present" "$id_raw" "-32000" "unable to detect plan format: $plan_path"
    return
  fi
  local todo_target=""
  if plan_format_is_yaml "$plan_format"; then
    todo_target="${RALPH_CURRENT_TODO_ID:-}"
    if [[ -z "$todo_target" || "$todo_target" == "null" ]]; then
      todo_target="${RALPH_CURRENT_TODO_ORDINAL:-}"
    fi
    if [[ -z "$todo_target" || "$todo_target" == "null" ]]; then
      todo_target="$todo_ordinal_arg"
    fi
  else
    todo_target="${RALPH_CURRENT_TODO_LINE:-}"
    if [[ -z "$todo_target" || "$todo_target" == "null" ]]; then
      todo_target="$todo_line_arg"
    fi
  fi

  local complete_text verification_text verification_verdict verification_reason
  case "$verification_status_arg" in
    pass)
      verification_verdict="PASS"
      verification_reason=""
      ;;
    fail)
      verification_verdict="FAIL"
      verification_reason="${verification_note_arg:-$summary_arg}"
      ;;
    not_run)
      verification_verdict="FAIL"
      verification_reason="${verification_note_arg:-verification not run}"
      ;;
    *)
      send_error "$id_present" "$id_raw" "-32602" "unsupported verification_status: $verification_status_arg"
      return
      ;;
  esac

  case "$outcome_arg" in
    complete)
      if [[ "$verification_status_arg" != "pass" ]]; then
        send_error "$id_present" "$id_raw" "-32602" "completion requires verification_status=pass"
        return
      fi
      if [[ "$verification_verdict" != "PASS" ]]; then
        send_error "$id_present" "$id_raw" "-32602" "completion requires verification_status=pass"
        return
      fi
      if ! plan_mark_todo_done_by_format "$plan_path" "$plan_format" "$todo_target"; then
        send_error "$id_present" "$id_raw" "-32000" "failed to mark active TODO complete"
        return
      fi
      complete_text="$(printf '%s\nVERIFICATION_RESULT: PASS\nAGENT_INVOCATION_COMPLETE\n' "$summary_arg")"
      ;;
    needs_retry)
      if [[ "$verification_status_arg" == "pass" ]]; then
        send_error "$id_present" "$id_raw" "-32602" "needs_retry cannot be paired with verification_status=pass"
        return
      fi
      if ! plan_reopen_todo_by_format "$plan_path" "$plan_format" "$todo_target"; then
        send_error "$id_present" "$id_raw" "-32000" "failed to reopen active TODO"
        return
      fi
      complete_text="$(printf '%s\nVERIFICATION_RESULT: FAIL: %s\n' "$summary_arg" "$verification_reason")"
      ;;
    *)
      send_error "$id_present" "$id_raw" "-32602" "unsupported outcome: $outcome_arg"
      return
      ;;
  esac

  local tool_result_ids_json
  tool_result_ids_json="$(echo "$args_json" | jq -c '.tool_result_ids // []')"
  local result_json
  result_json="$(
    jq -n \
      --arg text "$complete_text" \
      --arg workspace "$workspace_path" \
      --arg plan_path "$plan_path" \
      --arg outcome "$outcome_arg" \
      --arg verification_status "$verification_status_arg" \
      --arg summary "$summary_arg" \
      --arg verification_note "$verification_note_arg" \
      --arg todo_line "${RALPH_CURRENT_TODO_LINE:-}" \
      --arg todo_ordinal "${RALPH_CURRENT_TODO_ORDINAL:-}" \
      --arg todo_id "${RALPH_CURRENT_TODO_ID:-}" \
      --arg todo_hash "${RALPH_CURRENT_TODO_HASH:-}" \
      --argjson tool_result_ids "$tool_result_ids_json" \
      '{
        content:[{type:"text",text:$text}],
        structuredContent:{
          workspace:$workspace,
          plan_path:$plan_path,
          outcome:$outcome,
          verification_status:$verification_status,
          summary:$summary,
          verification_note:$verification_note,
          tool_result_ids:$tool_result_ids,
          matched:true,
          current_todo:{
            line:$todo_line,
            ordinal:$todo_ordinal,
            id:$todo_id,
            hash:$todo_hash
          },
          completion_marker_emitted: ($outcome == "complete"),
          verification_verdict: (if $outcome == "complete" then "PASS" else "FAIL" end)
        },
        isError:false
      }'
  )"
  send_result "$id_present" "$id_raw" "$result_json"
}

handle_plan_status() {
  local args_json="$1"
  local id_present="$2"
  local id_raw="$3"
  local workspace_arg plan_arg
  workspace_arg="$(echo "$args_json" | jq -r '.workspace // empty')"
  plan_arg="$(echo "$args_json" | jq -r '.plan_path // empty')"
  if [[ -z "$workspace_arg" || -z "$plan_arg" ]]; then
    send_error "$id_present" "$id_raw" "-32602" "workspace and plan_path are required"
    return
  fi
  local workspace_path
  if ! workspace_path="$(resolve_workspace "$workspace_arg")"; then
    send_error "$id_present" "$id_raw" "-32602" "workspace not allowed: $workspace_arg"
    return
  fi
  local plan_path
  if ! plan_path="$(resolve_plan_path "$workspace_path" "$plan_arg")"; then
    send_error "$id_present" "$id_raw" "-32602" "plan path invalid, outside workspace, or not allowlisted: $plan_arg"
    return
  fi
  if [[ ! -f "$plan_path" ]]; then
    send_error "$id_present" "$id_raw" "-32000" "Plan file not found: $plan_path"
    return
  fi
  local total=0
  local completed=0
  local remaining=0
  local unknown=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+\[([ xX?])\] ]]; then
      local token="${BASH_REMATCH[1]}"
      case "$token" in
        x|X)
          completed=$((completed + 1))
          ;;
        '?')
          unknown=$((unknown + 1))
          ;;
        *)
          remaining=$((remaining + 1))
          ;;
      esac
      total=$((total + 1))
    fi
  done < "$plan_path"
  local last_modified
  last_modified="$(date -u -r "$plan_path" +%Y-%m-%dT%H:%M:%SZ)"
  local summary="Plan status: ${completed}/${total} complete, ${remaining} remaining, ${unknown} unknown."
  local result_json
  result_json="$(
    jq -n \
      --arg text "$summary" \
      --arg workspace "$workspace_path" \
      --arg plan_path "$plan_path" \
      --arg last_modified "$last_modified" \
      --argjson total "$total" \
      --argjson completed "$completed" \
      --argjson remaining "$remaining" \
      --argjson unknown "$unknown" \
      '{
        content:[{type:"text",text:$text}],
        structuredContent:{
          workspace:$workspace,
          plan_path:$plan_path,
          total:$total,
          completed:$completed,
          remaining:$remaining,
          unknown:$unknown,
          last_modified:$last_modified
        },
        isError:false
      }'
  )"
  send_result "$id_present" "$id_raw" "$result_json"
}

handle_run_plan() {
  local args_json="$1"
  local id_present="$2"
  local id_raw="$3"
  local workspace_arg plan_arg runtime_arg agent_arg non_interactive_arg tool_access_arg
  workspace_arg="$(echo "$args_json" | jq -r '.workspace // empty')"
  plan_arg="$(echo "$args_json" | jq -r '.plan_path // empty')"
  runtime_arg="$(echo "$args_json" | jq -r '.runtime // empty')"
  agent_arg="$(echo "$args_json" | jq -r '.agent // empty')"
  non_interactive_arg="$(echo "$args_json" | jq -r '.non_interactive // "true"')"
  tool_access_arg="$(echo "$args_json" | jq -r '.tool_access // empty')"
  if [[ -z "$workspace_arg" || -z "$plan_arg" || -z "$runtime_arg" || -z "$agent_arg" ]]; then
    send_error "$id_present" "$id_raw" "-32602" "workspace, plan_path, runtime, and agent are required"
    return
  fi
  if ! ensure_safe_argument "$workspace_arg" "workspace" "$id_present" "$id_raw"; then
    return
  fi
  if ! ensure_safe_argument "$plan_arg" "plan_path" "$id_present" "$id_raw"; then
    return
  fi
  if ! ensure_safe_argument "$runtime_arg" "runtime" "$id_present" "$id_raw"; then
    return
  fi
  if ! ensure_safe_argument "$agent_arg" "agent" "$id_present" "$id_raw"; then
    return
  fi
  if ! ensure_safe_argument "$non_interactive_arg" "non_interactive" "$id_present" "$id_raw"; then
    return
  fi
  if [[ -n "$tool_access_arg" ]]; then
    if ! ensure_safe_argument "$tool_access_arg" "tool_access" "$id_present" "$id_raw"; then
      return
    fi
  fi
  local env_override_assignments=()
  local env_override_entry env_override_key env_override_value
  local env_override_tool_access_value=""
  local env_override_tool_access_seen=false
  while IFS= read -r env_override_entry; do
    env_override_key="$(jq -r '.key' <<< "$env_override_entry")"
    env_override_value="$(jq -r '.value' <<< "$env_override_entry")"
    if ! env_override_allowed_name "$env_override_key"; then
      send_error "$id_present" "$id_raw" "-32602" "env_overrides.$env_override_key is not allowed"
      return
    fi
    if ! ensure_safe_argument "$env_override_value" "env_overrides.$env_override_key" "$id_present" "$id_raw"; then
      return
    fi
    if contains_control_bytes "$env_override_value"; then
      send_error "$id_present" "$id_raw" "-32602" "env_overrides.$env_override_key contains unsafe bytes"
      return
    fi
    env_override_assignments+=("$env_override_key=$env_override_value")
    if [[ "$env_override_key" == "RALPH_AGENT_TOOL_ACCESS" ]]; then
      env_override_tool_access_value="$env_override_value"
      env_override_tool_access_seen=true
    fi
  done < <(echo "$args_json" | jq -c '.env_overrides // {} | to_entries[]')
  local workspace_path
  if ! workspace_path="$(resolve_workspace "$workspace_arg")"; then
    send_error "$id_present" "$id_raw" "-32602" "workspace not allowed: $workspace_arg"
    return
  fi
  local plan_path
  if ! plan_path="$(resolve_plan_path "$workspace_path" "$plan_arg")"; then
    send_error "$id_present" "$id_raw" "-32602" "plan path invalid, outside workspace, or not allowlisted: $plan_arg"
    return
  fi
  if [[ ! -f "$plan_path" ]]; then
    send_error "$id_present" "$id_raw" "-32000" "Plan file not found: $plan_path"
    return
  fi
  local runtime_lower
  runtime_lower="$(tr '[:upper:]' '[:lower:]' <<<"$runtime_arg" | tr -d '\r\n')"
  case "$runtime_lower" in
    cursor|claude|codex|opencode|antigravity) ;;
    *)
      send_error "$id_present" "$id_raw" "-32602" "unsupported runtime: $runtime_arg"
      return
      ;;
  esac
  local runner_rel=".ralph/run-plan.sh"
  local runner_path
  runner_path="$(canonicalize_path "$workspace_path/$runner_rel")" || {
    send_error "$id_present" "$id_raw" "-32602" "runner script not found for runtime: $runtime_lower"
    return
  }
  if [[ ! -f "$runner_path" ]]; then
    send_error "$id_present" "$id_raw" "-32602" "runner script missing: $runner_path"
    return
  fi
  local tool_access_mode=""
  if [[ -n "$tool_access_arg" ]]; then
    if ! tool_access_mode="$(normalize_tool_access "$tool_access_arg")"; then
      send_error "$id_present" "$id_raw" "-32602" "unsupported tool_access: $tool_access_arg"
      return
    fi
  elif [[ -n "$env_override_tool_access_value" ]]; then
    if ! tool_access_mode="$(normalize_tool_access "$env_override_tool_access_value")"; then
      send_error "$id_present" "$id_raw" "-32602" "unsupported env_overrides.RALPH_AGENT_TOOL_ACCESS: $env_override_tool_access_value"
      return
    fi
  fi
  local runtime_command=("bash" "$runner_path")
  if [[ "$non_interactive_arg" != "false" && "$non_interactive_arg" != "0" ]]; then
    runtime_command+=("--non-interactive")
  fi
  runtime_command+=("--runtime" "$runtime_lower" "--plan" "$plan_path" "--agent" "$agent_arg")
  if [[ "$tool_access_mode" == "ralph" ]]; then
    runtime_command+=("--tool-access" "ralph")
  fi
  runtime_command+=("--workspace" "$workspace_path")
  if [[ -n "$tool_access_mode" && "$env_override_tool_access_seen" != "true" ]]; then
    env_override_assignments+=("RALPH_AGENT_TOOL_ACCESS=$tool_access_mode")
  fi
  local full_command=("env")
  if (( ${#env_override_assignments[@]} )); then
    full_command+=("${env_override_assignments[@]}")
  fi
  full_command+=("${runtime_command[@]}")
  execute_tool_command "${full_command[@]}"
  local exit_code="$EXECUTE_TOOL_COMMAND_EXIT_CODE"
  local duration="$EXECUTE_TOOL_COMMAND_DURATION_SECONDS"
  local stdout_tail="$EXECUTE_TOOL_COMMAND_STDOUT_TAIL"
  local stderr_tail="$EXECUTE_TOOL_COMMAND_STDERR_TAIL"
  local stdout_trunc="$EXECUTE_TOOL_COMMAND_STDOUT_TRUNCATED"
  local stderr_trunc="$EXECUTE_TOOL_COMMAND_STDERR_TRUNCATED"
  local command_text
  command_text="$(printf '%s ' "${full_command[@]}")"
  command_text="${command_text%" "}"
  local timestamp
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local summary="Plan run exit code $exit_code (runtime=$runtime_lower agent=$agent_arg)."
  local result_json
  result_json="$(
    jq -n \
      --arg text "$summary" \
      --arg workspace "$workspace_path" \
      --arg plan_path "$plan_path" \
      --arg runtime "$runtime_lower" \
      --arg agent "$agent_arg" \
      --arg command "$command_text" \
      --arg timestamp "$timestamp" \
      --arg stdout_tail "$stdout_tail" \
      --arg stderr_tail "$stderr_tail" \
      --argjson exit_code "$exit_code" \
      --argjson duration "$duration" \
      --argjson stdout_truncated "$stdout_trunc" \
      --argjson stderr_truncated "$stderr_trunc" \
      --argjson timeout false \
      '{
        content:[{type:"text",text:$text}],
        structuredContent:{
          workspace:$workspace,
          plan_path:$plan_path,
          runtime:$runtime,
          agent:$agent,
          exit_code:$exit_code,
          timeout:$timeout,
          duration_seconds:$duration,
          stdout_tail:$stdout_tail,
          stderr_tail:$stderr_tail,
          stdout_truncated:$stdout_truncated,
          stderr_truncated:$stderr_truncated,
          command:$command,
          timestamp:$timestamp
        },
        isError:false
      }'
  )"
  send_result "$id_present" "$id_raw" "$result_json"
}

handle_orchestrator_run() {
  local args_json="$1"
  local id_present="$2"
  local id_raw="$3"
  local workspace_arg orchestration_arg dry_run_arg
  workspace_arg="$(echo "$args_json" | jq -r '.workspace // empty')"
  orchestration_arg="$(echo "$args_json" | jq -r '.orchestration_path // empty')"
  dry_run_arg="$(echo "$args_json" | jq -r '.dry_run // false')"
  if [[ -z "$workspace_arg" || -z "$orchestration_arg" ]]; then
    send_error "$id_present" "$id_raw" "-32602" "workspace and orchestration_path are required"
    return
  fi
  if ! ensure_safe_argument "$workspace_arg" "workspace" "$id_present" "$id_raw"; then
    return
  fi
  if ! ensure_safe_argument "$orchestration_arg" "orchestration_path" "$id_present" "$id_raw"; then
    return
  fi
  if ! ensure_safe_argument "$dry_run_arg" "dry_run" "$id_present" "$id_raw"; then
    return
  fi
  local workspace_path
  if ! workspace_path="$(resolve_workspace "$workspace_arg")"; then
    send_error "$id_present" "$id_raw" "-32602" "workspace not allowed: $workspace_arg"
    return
  fi
  local orchestration_path
  if ! orchestration_path="$(resolve_orchestration_path "$workspace_path" "$orchestration_arg")"; then
    send_error "$id_present" "$id_raw" "-32602" "orchestration path invalid, outside workspace, or not allowlisted: $orchestration_arg"
    return
  fi
  if [[ ! -f "$orchestration_path" ]]; then
    send_error "$id_present" "$id_raw" "-32000" "Orchestration file not found: $orchestration_path"
    return
  fi
  local stage_count
  stage_count="$(jq -r '.stages | length // 0' "$orchestration_path" 2>/dev/null || echo 0)"
  local orchestrator_script="$workspace_path/$ORCHESTRATOR_SCRIPT"
  if [[ ! -f "$orchestrator_script" ]]; then
    send_error "$id_present" "$id_raw" "-32602" "orchestrator script missing: $orchestrator_script"
    return
  fi
  local command=("bash" "$orchestrator_script" "--orchestration" "$orchestration_path")
  if [[ "$dry_run_arg" == "true" ]]; then
    command=("env" "ORCHESTRATOR_DRY_RUN=1" "${command[@]}")
  fi
  execute_tool_command "${command[@]}"
  local exit_code="$EXECUTE_TOOL_COMMAND_EXIT_CODE"
  local duration="$EXECUTE_TOOL_COMMAND_DURATION_SECONDS"
  local stdout_tail="$EXECUTE_TOOL_COMMAND_STDOUT_TAIL"
  local stderr_tail="$EXECUTE_TOOL_COMMAND_STDERR_TAIL"
  local stdout_trunc="$EXECUTE_TOOL_COMMAND_STDOUT_TRUNCATED"
  local stderr_trunc="$EXECUTE_TOOL_COMMAND_STDERR_TRUNCATED"
  local command_text
  command_text="$(printf '%s ' "${command[@]}")"
  command_text="${command_text%" "}"
  local timestamp
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local summary="Orchestrator run exit code $exit_code (dry_run=$dry_run_arg, steps=$stage_count)."
  local result_json
  result_json="$(
    jq -n \
      --arg text "$summary" \
      --arg workspace "$workspace_path" \
      --arg orchestration_path "$orchestration_path" \
      --arg command "$command_text" \
      --arg timestamp "$timestamp" \
      --arg stdout_tail "$stdout_tail" \
      --arg stderr_tail "$stderr_tail" \
      --argjson exit_code "$exit_code" \
      --argjson duration "$duration" \
      --argjson stdout_truncated "$stdout_trunc" \
      --argjson stderr_truncated "$stderr_trunc" \
      --argjson timeout false \
      --argjson stage_count "$stage_count" \
      --argjson dry_run "$([ "$dry_run_arg" == "true" ] && echo true || echo false)" \
      '{
        content:[{type:"text",text:$text}],
        structuredContent:{
          workspace:$workspace,
          orchestration_path:$orchestration_path,
          stage_count:$stage_count,
          exit_code:$exit_code,
          timeout:$timeout,
          duration_seconds:$duration,
          stdout_tail:$stdout_tail,
          stderr_tail:$stderr_tail,
          stdout_truncated:$stdout_truncated,
          stderr_truncated:$stderr_truncated,
          command:$command,
          timestamp:$timestamp,
          dry_run:$dry_run
        },
        isError:false
      }'
  )"
  send_result "$id_present" "$id_raw" "$result_json"
}

handle_list_tools() {
  local id_present="$1"
  local id_raw="$2"
  send_result "$id_present" "$id_raw" "$(get_tool_list_result)"
}

handle_resources_list() {
  local id_present="$1"
  local id_raw="$2"
  local description="Aggregates every configured Cursor, Claude, Codex, OpenCode, and Antigravity agent into a shared catalog."
  local result
  result="$(
    jq -n \
      --arg uri "$RALPH_MCP_AGENT_CATALOG_RESOURCE_URI" \
      --arg desc "$description" \
      '{
        resources:[{
          uri:$uri,
          name:"ralph/agents",
          title:"Ralph agent catalog",
          description:$desc,
          mimeType:"text/markdown"
        }]
      }'
  )"
  send_result "$id_present" "$id_raw" "$result"
}

handle_resources_read() {
  local params_json="$1"
  local id_present="$2"
  local id_raw="$3"
  local uri
  uri="$(echo "$params_json" | jq -r '.uri // empty')"
  if [[ -z "$uri" ]]; then
    send_error "$id_present" "$id_raw" "-32602" "uri is required"
    return
  fi
  if [[ "$uri" != "$RALPH_MCP_AGENT_CATALOG_RESOURCE_URI" ]]; then
    send_error "$id_present" "$id_raw" "-32002" "resource not found: $uri" "{\"uri\": \"$uri\"}"
    return
  fi
  local catalog
  catalog="$(generate_agent_catalog_markdown)"
  local result
  result="$(
    jq -n \
      --arg uri "$uri" \
      --arg text "$catalog" \
      '{
        contents:[{
          uri:$uri,
          mimeType:"text/markdown",
          text:$text
        }]
      }'
  )"
  send_result "$id_present" "$id_raw" "$result"
}

handle_prompts_list() {
  local id_present="$1"
  local id_raw="$2"
  local prompt_def
  prompt_def="$(generate_next_todo_prompt_definition)"
  local result
  result="$(
    jq -n \
      --argjson prompt "$prompt_def" \
      '{prompts: [$prompt]}'
  )"
  send_result "$id_present" "$id_raw" "$result"
}

handle_prompts_get() {
  local params_json="$1"
  local id_present="$2"
  local id_raw="$3"
  local name
  name="$(echo "$params_json" | jq -r '.name // empty')"
  if [[ "$name" != "ralph_run_next_todo_prompt" ]]; then
    send_error "$id_present" "$id_raw" "-32602" "unknown prompt: $name"
    return
  fi
  local args_json
  args_json="$(echo "$params_json" | jq -c '.arguments // {}')"
  local workspace_arg plan_arg
  workspace_arg="$(echo "$args_json" | jq -r '.workspace // empty')"
  plan_arg="$(echo "$args_json" | jq -r '.plan_path // empty')"
  if [[ -z "$plan_arg" ]]; then
    send_error "$id_present" "$id_raw" "-32602" "plan_path is required"
    return
  fi
  local workspace_path
  if [[ -z "$workspace_arg" ]]; then
    workspace_path="$WORKSPACE_ROOT"
  else
    if ! workspace_path="$(resolve_workspace "$workspace_arg")"; then
      send_error "$id_present" "$id_raw" "-32602" "workspace not allowed: $workspace_arg"
      return
    fi
  fi
  local prompt_plan_path
  if ! prompt_plan_path="$(resolve_plan_path "$workspace_path" "$plan_arg")"; then
    send_error "$id_present" "$id_raw" "-32602" "plan path invalid, outside workspace, or not allowlisted: $plan_arg"
    return
  fi
  local prompt_text
  prompt_text="$(ralph_mcp_build_next_todo_prompt_message "$workspace_path" "$prompt_plan_path")"
  local result
  result="$(
    jq -n \
      --arg description "Guidance for scheduling the next unchecked TODO" \
      --arg text "$prompt_text" \
      '{
        description: $description,
        messages: [
          {
            role: "user",
            content: {
              type: "text",
              text: $text
            }
          }
        ]
      }'
  )"
  send_result "$id_present" "$id_raw" "$result"
}

fatal_proxy_tool_violation() {
  dispatch_proxy_tool_violation "$@"
}

handle_proxy_owned_tool() {
  local tool_name="$1"
  local args_json="$2"
  local id_present="$3"
  local id_raw="$4"
  local result_json=""
  local _call_start
  _call_start="$(date +%s)"

  if ralph_mcp_proxy_call_arguments_denied "$tool_name" "$args_json"; then
    ralph_mcp_proxy_log_tool_call_jsonl "$tool_name" "$id_raw" "0" "denied" "${RALPH_MCP_PROXY_LAST_DENY_REASON:-denied}" 2>/dev/null || true
    dispatch_proxy_tool_violation \
      "$id_present" \
      "$id_raw" \
      "$tool_name" \
      "tool arguments denied by proxy policy: ${RALPH_MCP_PROXY_LAST_DENY_REASON:-denied}" \
      "${RALPH_MCP_PROXY_LAST_DENY_REASON:-denied}" \
      "tool=$tool_name" \
      "denied-arguments" \
      "$args_json"
    return
  fi

  invoke_proxy_owned_tool_once "$tool_name" "$args_json" result_json

  local _call_end _duration_s _exit_status
  _call_end="$(date +%s)"
  _duration_s=$(( _call_end - _call_start ))

  if [[ "${RALPH_MCP_PROXY_FATAL_VIOLATION:-0}" == "1" ]]; then
    ralph_mcp_proxy_log_tool_call_jsonl "$tool_name" "$id_raw" "$_duration_s" "fatal-violation" "${RALPH_MCP_PROXY_FATAL_REASON:-fatal proxy violation}" 2>/dev/null || true
    dispatch_proxy_tool_violation \
      "$id_present" \
      "$id_raw" \
      "${RALPH_MCP_PROXY_FATAL_TOOL:-$tool_name}" \
      "${RALPH_MCP_PROXY_FATAL_REASON:-fatal proxy violation}" \
      "${RALPH_MCP_PROXY_FATAL_REASON:-fatal proxy violation}" \
      "${RALPH_MCP_PROXY_FATAL_ARGUMENTS:-}" \
      "${RALPH_MCP_PROXY_FATAL_CATEGORY:-boundary}" \
      "$args_json"
    return
  fi

  _exit_status="ok"
  if [[ "$(jq -r '.isError // false' <<<"$result_json" 2>/dev/null)" == "true" ]]; then
    _exit_status="error"
  fi
  if printf '%s' "$result_json" | jq -e '.content[0].text | fromjson? | .shellTimeoutHandoff == true' >/dev/null 2>&1; then
    _exit_status="timeout-handoff"
  fi
  ralph_mcp_proxy_log_tool_call_jsonl "$tool_name" "$id_raw" "$_duration_s" "$_exit_status" "" 2>/dev/null || true

  send_proxy_owned_tool_result "$tool_name" "$args_json" "$id_present" "$id_raw" "$result_json"
}

handle_call_tool() {
  local tool_name="$1"
  local args_json="$2"
  local id_present="$3"
  local id_raw="$4"

  # Lazy init policy on first tool call
  if ! ensure_lazy_init; then
    send_error "$id_present" "$id_raw" "-32603" "server initialization failed"
    return
  fi

  case "$tool_name" in
    ralph_plan_status)
      handle_plan_status "$args_json" "$id_present" "$id_raw"
      ;;
    ralph_run_plan)
      handle_run_plan "$args_json" "$id_present" "$id_raw"
      ;;
    ralph_orchestrator_run)
      handle_orchestrator_run "$args_json" "$id_present" "$id_raw"
      ;;
    ralph_complete_todo)
      handle_complete_todo "$args_json" "$id_present" "$id_raw"
      ;;
    ralph_proxy_read|ralph_proxy_grep|ralph_proxy_glob|ralph_proxy_shell|ralph_proxy_shell_start|ralph_proxy_shell_status|ralph_proxy_shell_wait|ralph_proxy_shell_read|ralph_proxy_shell_cancel|ralph_proxy_search|ralph_proxy_repomap|ralph_proxy_result_read|ralph_proxy_result_search|ralph_proxy_result_summary|ralph_proxy_result_reduce|ralph_proxy_batch|ralph_proxy_tool_search)
      handle_proxy_owned_tool "$tool_name" "$args_json" "$id_present" "$id_raw"
      ;;
    *)
      send_error "$id_present" "$id_raw" "-32601" "tool not found: $tool_name"
      ;;
  esac
}

handle_initialize() {
  local id_present="$1"
  local id_raw="$2"
  ralph_mcp_log "handling initialize request from orchestrator"
  # Pre-computed static response for maximum speed
  local result='{"protocolVersion":"2025-11-25","serverInfo":{"name":"ralph","version":"1.0.0"},"capabilities":{"tools":{"listChanged":false},"resources":{"listChanged":false},"prompts":{"listChanged":false}}}'
  send_result "$id_present" "$id_raw" "$result"
}

handle_initialized() {
  ralph_mcp_log "received initialized notification"
}

handle_shutdown() {
  local id_present="$1"
  local id_raw="$2"
  ralph_mcp_log "shutdown requested"
  local result
  result="$(jq -n '{status: "shutting_down"}')"
  send_result "$id_present" "$id_raw" "$result"
}

handle_exit() {
  local id_present="$1"
  local id_raw="$2"
  ralph_mcp_log "exit requested; terminating MCP server"
  local result
  result="$(jq -n '{status: "exiting"}')"
  send_result "$id_present" "$id_raw" "$result"
  exit 0
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
      handle_initialized "$id_present" "$id_raw"
      ;;
    shutdown)
      handle_shutdown "$id_present" "$id_raw"
      ;;
    exit)
      handle_exit "$id_present" "$id_raw"
      ;;
    resources/list)
      handle_resources_list "$id_present" "$id_raw"
      ;;
    resources/read)
      local params_json
      params_json="$(echo "$payload" | jq -c '.params // {}')"
      handle_resources_read "$params_json" "$id_present" "$id_raw"
      ;;
    prompts/list)
      handle_prompts_list "$id_present" "$id_raw"
      ;;
    prompts/get)
      local params_json
      params_json="$(echo "$payload" | jq -c '.params // {}')"
      handle_prompts_get "$params_json" "$id_present" "$id_raw"
      ;;
    tools/list)
      handle_list_tools "$id_present" "$id_raw"
      ;;
    tools/call)
      local tool_name
      local args_json
      tool_name="$(echo "$payload" | jq -r '.params.name // empty')"
      args_json="$(echo "$payload" | jq -c '.params.arguments // {}')"
      RALPH_MCP_TOOL_CALL_PROGRESS_TOKEN="$(echo "$payload" | jq -r '.params._meta.progressToken // empty')"
      handle_call_tool "$tool_name" "$args_json" "$id_present" "$id_raw"
      RALPH_MCP_TOOL_CALL_PROGRESS_TOKEN=""
      ;;
    *)
      local message="method not found: $method"
      ralph_mcp_log "$message"
      send_error "$id_present" "$id_raw" "-32601" "$message"
      ;;
  esac
}

RALPH_MCP_LAZY_INIT_DONE=0

ensure_lazy_init() {
  if [[ "$RALPH_MCP_LAZY_INIT_DONE" == "1" ]]; then
    return 0
  fi
  RALPH_MCP_LAZY_INIT_DONE=1

  # Unified server always executes ralph_proxy_* handlers; policy env vars still apply.
  export RALPH_MCP_PROXY_OWNED_TOOLS_FORCE=1
  if ! ralph_mcp_proxy_load_policy "$WORKSPACE_ROOT" "$SCRIPT_DIR/mcp-server.sh"; then
    ralph_mcp_log "failed to load MCP proxy policy for ralph_proxy_* tools"
    return 1
  fi

  build_allowlist
  ralph_mcp_log "configured workspace allowlist: ${ALLOWLIST_ROOTS[*]-}"
  return 0
}

main() {
  ensure_jq

  if [[ -z "${RALPH_MCP_WORKSPACE:-}" ]]; then
    fail "RALPH_MCP_WORKSPACE must be set to your workspace root before starting the MCP server."
  fi

  if ! workspace="$(cd "$RALPH_MCP_WORKSPACE" && pwd)"; then
    fail "failed to resolve RALPH_MCP_WORKSPACE=$RALPH_MCP_WORKSPACE"
  fi

  # Three-root workspace boundary model with backward compatibility:
  # - RALPH_MCP_WORKSPACE (legacy): treated as the workspace root
  # - RALPH_PROJECT_ROOT: where .ralph/ lives (falls back to RALPH_MCP_WORKSPACE)
  # - RALPH_AGENT_WORKSPACE: agent sandbox (falls back to RALPH_MCP_WORKSPACE)
  # - RALPH_PLAN_WORKSPACE_ROOT: plan state root (falls back to RALPH_MCP_WORKSPACE)
  local project_root agent_workspace plan_workspace_root
  project_root="${RALPH_PROJECT_ROOT:-$workspace}"
  agent_workspace="${RALPH_AGENT_WORKSPACE:-$workspace}"
  plan_workspace_root="${RALPH_PLAN_WORKSPACE_ROOT:-$workspace}"

  # Export the three roots for use by policy/tools
  export RALPH_MCP_WORKSPACE="$workspace"
  export RALPH_PROJECT_ROOT="$project_root"
  export RALPH_AGENT_WORKSPACE="$agent_workspace"
  export RALPH_PLAN_WORKSPACE_ROOT="$plan_workspace_root"

  # Auto-initialize the per-plan MCP log file when RALPH_PLAN_KEY is set and
  # RALPH_MCP_PROXY_LOG_FILE is not already configured. This enables plan-scoped
  # observability without requiring the caller to set the path explicitly.
  if [[ -n "${RALPH_PLAN_KEY:-}" && -z "${RALPH_MCP_PROXY_LOG_FILE:-}" ]]; then
    local auto_log_dir
    auto_log_dir="${plan_workspace_root}/.ralph-workspace/logs/${RALPH_PLAN_KEY}"
    mkdir -p "$auto_log_dir" 2>/dev/null || true
    export RALPH_MCP_PROXY_LOG_FILE="${auto_log_dir}/mcp.log"
  fi

  WORKSPACE_ROOT="${workspace%/}"
  [[ -z "$WORKSPACE_ROOT" ]] && WORKSPACE_ROOT="/"
  if [[ "$WORKSPACE_ROOT" == "/" ]]; then
    WORKSPACE_ROOT_PREFIX="/"
  else
    WORKSPACE_ROOT_PREFIX="$WORKSPACE_ROOT/"
  fi

  ralph_mcp_log "starting MCP server for workspace $workspace"
  ralph_mcp_log "waiting for JSON-RPC requests on stdin"
  if auth_token_guard_enabled; then
    ralph_mcp_log "RALPH_MCP_AUTH_TOKEN set; enforcing bearer-token guard."
  else
    ralph_mcp_log "RALPH_MCP_AUTH_TOKEN not set; MCP server accepting requests without auth tokens."
  fi

  while true; do
    local raw
    if ! IFS= read -r raw; then
      ralph_mcp_log "stdin closed; exiting"
      break
    fi

    if [[ -z "${raw//[[:space:]]/}" ]]; then
      continue
    fi

    # Parse all needed fields in a single jq call for performance
    local parsed
    if ! parsed="$(echo "$raw" | jq -r '"\(.jsonrpc // "")\t\(has("id"))\t\(.id // null | tojson)\t\(.method // "")"' 2>/dev/null)"; then
      ralph_mcp_log "invalid JSON received; ignoring line"
      continue
    fi

    local jsonrpc id_present id_raw method
    IFS=$'\t' read -r jsonrpc id_present id_raw method <<< "$parsed"

    if [[ -z "$jsonrpc" || "$jsonrpc" != "2.0" ]]; then
      ralph_mcp_log "invalid or missing jsonrpc version; rejecting request"
      send_error "$id_present" "$id_raw" "-32600" "jsonrpc=2.0 is required"
      continue
    fi

    if ! enforce_auth_token "$raw" "$id_present" "$id_raw"; then
      continue
    fi

    if [[ -z "$method" ]]; then
      ralph_mcp_log "missing method in request; ignoring"
      continue
    fi

    dispatch_request "$method" "$id_present" "$id_raw" "$raw"
  done
}

main "$@"
