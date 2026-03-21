#!/usr/bin/env bash
#
# Minimal MCP server loop implemented entirely with Bash and jq so that
# the Cursor/Claude/Codex orchestrator can connect over stdio without
# requiring Python or Node.

set -uo pipefail
IFS=$'\n'

readonly SCRIPT_NAME="$(basename "$0")"

log() {
  printf '[%s] %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SCRIPT_NAME" "$*" >&2
}

fail() {
  log "$*"
  exit 1
}

ensure_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    fail "jq is required to parse MCP JSON-RPC messages; please install it before running the server."
  fi
}

readonly MAX_TOOL_TAIL_BYTES=32768
readonly ORCHESTRATOR_SCRIPT=".ralph/orchestrator.sh"

WORKSPACE_ROOT=""
WORKSPACE_ROOT_PREFIX=""
ALLOWLIST_ROOTS=()

send_result() {
  local id_present="$1"
  local id_raw="$2"
  local result_json="$3"

  if [[ "$id_present" != "true" ]]; then
    log "notification received; skipping response"
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
    log "cannot send error (missing id): $message"
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

tail_text() {
  local file="$1"
  local limit="$2"
  local out_var="$3"
  local truncated_var="$4"
  local size
  size="$(wc -c < "$file" 2>/dev/null || echo 0)"
  local truncated="false"
  if [[ "$size" -gt "$limit" ]]; then
    truncated="true"
  fi
  local content=""
  if [[ "$size" -gt 0 ]]; then
    content="$(tail -c "$limit" "$file" 2>/dev/null || cat "$file")"
  fi
  printf -v "$out_var" "%s" "$content"
  printf -v "$truncated_var" "%s" "$truncated"
}

execute_tool_command() {
  local -n exit_ref="$1"
  local -n duration_ref="$2"
  local -n stdout_ref="$3"
  local -n stderr_ref="$4"
  local -n stdout_trunc_ref="$5"
  local -n stderr_trunc_ref="$6"
  shift 6
  local command=("$@")
  local stdout_file stderr_file
  stdout_file="$(mktemp)"
  stderr_file="$(mktemp)"
  local start_time end_time
  start_time="$(date +%s.%N)"
  set +e
  "${command[@]}" >"$stdout_file" 2>"$stderr_file"
  local exit_code=$?
  set -e
  end_time="$(date +%s.%N)"
  duration_ref="$(awk "BEGIN {printf \"%.3f\", $end_time - $start_time}")"
  tail_text "$stdout_file" "$MAX_TOOL_TAIL_BYTES" stdout_ref stdout_trunc_ref
  tail_text "$stderr_file" "$MAX_TOOL_TAIL_BYTES" stderr_ref stderr_trunc_ref
  rm -f "$stdout_file" "$stderr_file"
  exit_ref="$exit_code"
}

canonicalize_path() {
  local raw="$1"
  local expanded="$raw"
  if [[ "$expanded" == "~" ]]; then
    expanded="$HOME"
  elif [[ "$expanded" == ~/* ]]; then
    expanded="$HOME/${expanded#~/}"
  fi
  local dir
  dir="$(cd "$(dirname "$expanded")" 2>/dev/null && pwd)" || return 1
  printf '%s/%s\n' "$dir" "$(basename "$expanded")"
}

add_allowlist_root() {
  local root="$1"
  for existing in "${ALLOWLIST_ROOTS[@]-}"; do
    [[ "$existing" == "$root" ]] && return
  done
  ALLOWLIST_ROOTS+=("$root")
}

build_allowlist() {
  local raw="${RALPH_MCP_ALLOWLIST:-}"
  if [[ -n "$raw" ]]; then
    local normalized
    normalized="$(printf '%s\n' "$raw" | tr ',;:' '\n')"
    local entry
    while IFS= read -r entry; do
      entry="${entry#"${entry%%[![:space:]]*}"}"
      entry="${entry%"${entry##*[![:space:]]}"}"
      if [[ -z "${entry//[[:space:]]/}" ]]; then
        continue
      fi
      local candidate="$entry"
      if [[ "$candidate" == ~* ]]; then
        :
      elif [[ "$candidate" != /* ]]; then
        candidate="$WORKSPACE_ROOT/$candidate"
      fi
      candidate="$(canonicalize_path "$candidate")" || fail "allowlist entry invalid: $entry"
      if [[ ! -d "$candidate" ]]; then
        fail "allowlist entry is not a directory: $candidate"
      fi
      add_allowlist_root "$candidate"
    done <<< "$normalized"
  fi
  add_allowlist_root "$WORKSPACE_ROOT"
}

workspace_allowed() {
  local candidate="$1"
  for root in "${ALLOWLIST_ROOTS[@]-}"; do
    if [[ "$root" == "/" ]]; then
      [[ "$candidate" == /* ]] && return 0
      continue
    fi
    if [[ "$candidate" == "$root" || "$candidate" == "$root/"* ]]; then
      return 0
    fi
  done
  return 1
}

is_subpath() {
  local candidate="$1"
  if [[ -z "$WORKSPACE_ROOT" ]]; then
    return 1
  fi
  if [[ "$WORKSPACE_ROOT" == "/" ]]; then
    [[ "$candidate" == /* ]]
    return
  fi
  [[ "$candidate" == "$WORKSPACE_ROOT" || "$candidate" == "$WORKSPACE_ROOT_PREFIX"* ]]
}

resolve_workspace() {
  local value="$1"
  if [[ -z "$value" ]]; then
    return 1
  fi
  local candidate
  if [[ "$value" == /* ]]; then
    candidate="$value"
  else
    candidate="$WORKSPACE_ROOT/$value"
  fi
  local canonical
  canonical="$(canonicalize_path "$candidate")" || return 2
  if [[ ! -d "$canonical" ]]; then
    return 3
  fi
  if ! workspace_allowed "$canonical"; then
    return 4
  fi
  printf '%s\n' "$canonical"
}

resolve_plan_path() {
  local workspace="$1"
  local plan_value="$2"
  local candidate
  if [[ "$plan_value" == /* ]]; then
    candidate="$plan_value"
  else
    candidate="$workspace/$plan_value"
  fi
  local canonical
  canonical="$(canonicalize_path "$candidate")" || return 1
  if ! is_subpath "$canonical"; then
    return 2
  fi
  printf '%s\n' "$canonical"
}

resolve_orchestration_path() {
  local workspace="$1"
  local path_value="$2"
  local candidate
  if [[ "$path_value" == /* ]]; then
    candidate="$path_value"
  else
    candidate="$workspace/$path_value"
  fi
  local canonical
  canonical="$(canonicalize_path "$candidate")" || return 1
  if ! is_subpath "$canonical"; then
    return 2
  fi
  if [[ ! -f "$canonical" ]]; then
    return 3
  fi
  printf '%s\n' "$canonical"
}

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
    send_error "$id_present" "$id_raw" "-32602" "plan path invalid or outside workspace: $plan_arg"
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
  local workspace_path
  if ! workspace_path="$(resolve_workspace "$workspace_arg")"; then
    send_error "$id_present" "$id_raw" "-32602" "workspace not allowed: $workspace_arg"
    return
  fi
  local plan_path
  if ! plan_path="$(resolve_plan_path "$workspace_path" "$plan_arg")"; then
    send_error "$id_present" "$id_raw" "-32602" "plan path invalid or outside workspace: $plan_arg"
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
  local exit_code duration stdout_tail stderr_tail stdout_trunc stderr_trunc
  execute_tool_command exit_code duration stdout_tail stderr_tail stdout_trunc stderr_trunc "${command[@]}"
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
  local workspace_path
  if ! workspace_path="$(resolve_workspace "$workspace_arg")"; then
    send_error "$id_present" "$id_raw" "-32602" "workspace not allowed: $workspace_arg"
    return
  fi
  local orchestration_path
  if ! orchestration_path="$(resolve_orchestration_path "$workspace_path" "$orchestration_arg")"; then
    send_error "$id_present" "$id_raw" "-32602" "orchestration path invalid or outside workspace: $orchestration_arg"
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
  local exit_code duration stdout_tail stderr_tail stdout_trunc stderr_trunc
  execute_tool_command exit_code duration stdout_tail stderr_tail stdout_trunc stderr_trunc "${command[@]}"
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
  log "handling initialize request from orchestrator"
  local capabilities
  capabilities="$(
    jq -n '{tools: {listChanged: false}, resources: null, prompts: null}'
  )"
  local result
  result="$(
    jq -n --argjson capabilities "$capabilities" '{capabilities: $capabilities}'
  )"
  send_result "$id_present" "$id_raw" "$result"
}

handle_initialized() {
  log "received initialized notification"
}

handle_shutdown() {
  local id_present="$1"
  local id_raw="$2"
  log "shutdown requested"
  local result
  result="$(jq -n '{status: "shutting_down"}')"
  send_result "$id_present" "$id_raw" "$result"
}

handle_exit() {
  local id_present="$1"
  local id_raw="$2"
  log "exit requested; terminating MCP server"
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
      log "$message"
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
  log "configured workspace allowlist: ${ALLOWLIST_ROOTS[*]-}"

  log "starting MCP server for workspace $workspace"
  log "waiting for JSON-RPC requests on stdin"

  while true; do
    local raw
    if ! IFS= read -r raw; then
      log "stdin closed; exiting"
      break
    fi

    if [[ -z "${raw//[[:space:]]/}" ]]; then
      continue
    fi

    if ! echo "$raw" | jq -e . >/dev/null 2>&1; then
      log "invalid JSON received; ignoring line"
      continue
    fi

    local jsonrpc
    jsonrpc="$(echo "$raw" | jq -r '.jsonrpc // empty')"
    if [[ -z "$jsonrpc" || "$jsonrpc" != "2.0" ]]; then
      log "invalid or missing jsonrpc version; rejecting request"
      local id_present
      id_present="$(echo "$raw" | jq -r 'has("id")')"
      local id_raw
      id_raw="$(echo "$raw" | jq -c '.id // null')"
      send_error "$id_present" "$id_raw" "-32600" "jsonrpc=2.0 is required"
      continue
    fi

    local method
    method="$(echo "$raw" | jq -r '.method // empty')"
    if [[ -z "$method" ]]; then
      log "missing method in request; ignoring"
      continue
    fi

    local id_present
    id_present="$(echo "$raw" | jq -r 'has("id")')"
    local id_raw
    id_raw="$(echo "$raw" | jq -c '.id // null')"

    dispatch_request "$method" "$id_present" "$id_raw" "$raw"
  done
}

main "$@"
