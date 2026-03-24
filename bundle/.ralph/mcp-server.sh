#!/usr/bin/env bash
#
# Minimal MCP server loop implemented entirely with Bash and jq so that
# the Cursor/Claude/Codex orchestrator can connect over stdio without
# requiring Python or Node.

set -uo pipefail
IFS=$'\n'

readonly SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/Users/joshuajancula/Documents/projects/ralph/bundle/.ralph/bash-lib/error-handling.sh
source "$SCRIPT_DIR/bash-lib/error-handling.sh"
# shellcheck source=/Users/joshuajancula/Documents/projects/ralph/bundle/.ralph/bash-lib/mcp-protocol.sh
source "$SCRIPT_DIR/bash-lib/mcp-protocol.sh"
# shellcheck source=/Users/joshuajancula/Documents/projects/ralph/bundle/.ralph/bash-lib/mcp-resources.sh
source "$SCRIPT_DIR/bash-lib/mcp-resources.sh"
# shellcheck source=/Users/joshuajancula/Documents/projects/ralph/bundle/.ralph/bash-lib/mcp-tools.sh
source "$SCRIPT_DIR/bash-lib/mcp-tools.sh"
# shellcheck source=/Users/joshuajancula/Documents/projects/ralph/bundle/.ralph/bash-lib/mcp-prompts.sh
source "$SCRIPT_DIR/bash-lib/mcp-prompts.sh"

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
  ${C_G}RALPH_MCP_WORKSPACE${C_RST}   Required path to the repo workspace the MCP server exposes.
  ${C_G}RALPH_MCP_ALLOWLIST${C_RST}   Optional colon/comma/semicolon-separated dirs (relative to workspace) to allow in requests.

${C_BOLD}Options:${C_RST}
  ${C_G}--help${C_RST}                Show this help message and exit.

${C_BOLD}Dependencies:${C_RST}
  ${C_Y}jq${C_RST}                     Required for parsing MCP JSON-RPC payloads.
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

TOOL_LIST_RESULT=$(
  cat <<'EOF'
{
  "tools": [
    {
      "name": "ralph_run_plan",
      "description": "Run an existing Ralph plan with the chosen agent/runtime.",
      "inputSchema": {
        "type": "object",
        "properties": {
          "workspace": { "type": "string" },
          "plan_path": { "type": "string" },
          "runtime": { "type": "string" },
          "agent": { "type": "string" },
          "non_interactive": { "type": "boolean" },
          "env_overrides": {
            "type": "object",
            "additionalProperties": { "type": "string" }
          }
        },
        "required": ["workspace", "plan_path", "runtime", "agent"]
      },
      "outputSchema": {
        "type": "object",
        "properties": {
          "workspace": { "type": "string" },
          "plan_path": { "type": "string" },
          "runtime": { "type": "string" },
          "agent": { "type": "string" },
          "exit_code": { "type": ["integer", "null"] },
          "timeout": { "type": "boolean" },
          "duration_seconds": { "type": "number" },
          "stdout_tail": { "type": "string" },
          "stderr_tail": { "type": "string" },
          "stdout_truncated": { "type": "boolean" },
          "stderr_truncated": { "type": "boolean" },
          "command": { "type": "string" },
          "timestamp": { "type": "string", "format": "date-time" }
        },
        "required": [
          "workspace",
          "plan_path",
          "runtime",
          "agent",
          "exit_code",
          "timeout",
          "duration_seconds",
          "stdout_tail",
          "stderr_tail",
          "stdout_truncated",
          "stderr_truncated",
          "command",
          "timestamp"
        ]
      }
    },
    {
      "name": "ralph_plan_status",
      "description": "Count TODO checkboxes and report modification metadata for a plan.",
      "inputSchema": {
        "type": "object",
        "properties": {
          "workspace": { "type": "string" },
          "plan_path": { "type": "string" }
        },
        "required": ["workspace", "plan_path"]
      },
      "outputSchema": {
        "type": "object",
        "properties": {
          "workspace": { "type": "string" },
          "plan_path": { "type": "string" },
          "total": { "type": "integer" },
          "completed": { "type": "integer" },
          "remaining": { "type": "integer" },
          "unknown": { "type": "integer" },
          "last_modified": { "type": "string", "format": "date-time" }
        },
        "required": [
          "workspace",
          "plan_path",
          "total",
          "completed",
          "remaining",
          "unknown",
          "last_modified"
        ]
      }
    },
    {
      "name": "ralph_orchestrator_run",
      "description": "Run a Ralph orchestration spec through the canonical orchestrator.",
      "inputSchema": {
        "type": "object",
        "properties": {
          "workspace": { "type": "string" },
          "orchestration_path": { "type": "string" },
          "dry_run": { "type": "boolean" },
          "env_overrides": {
            "type": "object",
            "additionalProperties": { "type": "string" }
          }
        },
        "required": ["workspace", "orchestration_path"]
      },
      "outputSchema": {
        "type": "object",
        "properties": {
          "workspace": { "type": "string" },
          "orchestration_path": { "type": "string" },
          "stage_count": { "type": "integer" },
          "exit_code": { "type": ["integer", "null"] },
          "timeout": { "type": "boolean" },
          "duration_seconds": { "type": "number" },
          "stdout_tail": { "type": "string" },
          "stderr_tail": { "type": "string" },
          "stdout_truncated": { "type": "boolean" },
          "stderr_truncated": { "type": "boolean" },
          "command": { "type": "string" },
          "timestamp": { "type": "string", "format": "date-time" },
          "dry_run": { "type": "boolean" }
        },
        "required": [
          "workspace",
          "orchestration_path",
          "stage_count",
          "exit_code",
          "timeout",
          "duration_seconds",
          "stdout_tail",
          "stderr_tail",
          "stdout_truncated",
          "stderr_truncated",
          "command",
          "timestamp",
          "dry_run"
        ]
      }
    }
  ],
  "nextCursor": null
}
EOF
)

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
  local workspace_arg plan_arg runtime_arg agent_arg non_interactive_arg
  workspace_arg="$(echo "$args_json" | jq -r '.workspace // empty')"
  plan_arg="$(echo "$args_json" | jq -r '.plan_path // empty')"
  runtime_arg="$(echo "$args_json" | jq -r '.runtime // empty')"
  agent_arg="$(echo "$args_json" | jq -r '.agent // empty')"
  non_interactive_arg="$(echo "$args_json" | jq -r '.non_interactive // "true"')"
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
    cursor|claude|codex) ;;
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
  local command=("bash" "$runner_path")
  if [[ "$non_interactive_arg" != "false" && "$non_interactive_arg" != "0" ]]; then
    command+=("--non-interactive")
  fi
  command+=("--runtime" "$runtime_lower" "--plan" "$plan_path" "--agent" "$agent_arg" "$workspace_path")
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
  send_result "$id_present" "$id_raw" "$TOOL_LIST_RESULT"
}

handle_resources_list() {
  local id_present="$1"
  local id_raw="$2"
  local description="Aggregates every configured Cursor, Claude, and Codex agent into a shared catalog."
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
        }],
        nextCursor:null
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
      '{prompts: [$prompt], nextCursor: null}'
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

handle_call_tool() {
  local tool_name="$1"
  local args_json="$2"
  local id_present="$3"
  local id_raw="$4"
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
    *)
      send_error "$id_present" "$id_raw" "-32601" "tool not found: $tool_name"
      ;;
  esac
}

handle_initialize() {
  local id_present="$1"
  local id_raw="$2"
  ralph_mcp_log "handling initialize request from orchestrator"
  local capabilities
  capabilities="$(
    jq -n '{tools: {listChanged: false}, resources: {listChanged: false}, prompts: {listChanged: false}}'
  )"
  local result
  result="$(
    jq -n --argjson capabilities "$capabilities" '{capabilities: $capabilities}'
  )"
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
    initialized)
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

  if [[ -z "${RALPH_MCP_WORKSPACE:-}" ]]; then
    fail "RALPH_MCP_WORKSPACE must be set to your workspace root before starting the MCP server."
  fi

  if ! workspace="$(cd "$RALPH_MCP_WORKSPACE" && pwd)"; then
    fail "failed to resolve RALPH_MCP_WORKSPACE=$RALPH_MCP_WORKSPACE"
  fi

  WORKSPACE_ROOT="${workspace%/}"
  [[ -z "$WORKSPACE_ROOT" ]] && WORKSPACE_ROOT="/"
  if [[ "$WORKSPACE_ROOT" == "/" ]]; then
    WORKSPACE_ROOT_PREFIX="/"
  else
    WORKSPACE_ROOT_PREFIX="$WORKSPACE_ROOT/"
  fi
  build_allowlist
  ralph_mcp_log "configured workspace allowlist: ${ALLOWLIST_ROOTS[*]-}"

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

    if ! echo "$raw" | jq -e . >/dev/null 2>&1; then
      ralph_mcp_log "invalid JSON received; ignoring line"
      continue
    fi

    local jsonrpc
    jsonrpc="$(echo "$raw" | jq -r '.jsonrpc // empty')"
    if [[ -z "$jsonrpc" || "$jsonrpc" != "2.0" ]]; then
      ralph_mcp_log "invalid or missing jsonrpc version; rejecting request"
      local id_present
      id_present="$(echo "$raw" | jq -r 'has("id")')"
      local id_raw
      id_raw="$(echo "$raw" | jq -c '.id // null')"
      send_error "$id_present" "$id_raw" "-32600" "jsonrpc=2.0 is required"
      continue
    fi

    local id_present
    id_present="$(echo "$raw" | jq -r 'has("id")')"
    local id_raw
    id_raw="$(echo "$raw" | jq -c '.id // null')"
    if ! enforce_auth_token "$raw" "$id_present" "$id_raw"; then
      continue
    fi

    local method
    method="$(echo "$raw" | jq -r '.method // empty')"
    if [[ -z "$method" ]]; then
      ralph_mcp_log "missing method in request; ignoring"
      continue
    fi

    dispatch_request "$method" "$id_present" "$id_raw" "$raw"
  done
}

main "$@"
