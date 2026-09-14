#!/usr/bin/env bash
# MCP surface for the five Ralph delegated-run tools.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi
if [[ -n "${GRAPH_DELEGATED_RUN_MCP_LOADED:-}" ]]; then return 0; fi
GRAPH_DELEGATED_RUN_MCP_LOADED=1

_GRAPH_DELEGATED_RUN_MCP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F graph_delegation_ledger_start >/dev/null 2>&1; then
  source "$_GRAPH_DELEGATED_RUN_MCP_DIR/graph-delegation-ledger.sh"
fi
if ! declare -F graph_delegation_queue_enqueue >/dev/null 2>&1; then
  source "$_GRAPH_DELEGATED_RUN_MCP_DIR/graph-delegation-queue.sh"
fi
if ! declare -F graph_depth_policy_enforce_scope >/dev/null 2>&1; then
  # shellcheck source=graph-depth-policy.sh
  source "$_GRAPH_DELEGATED_RUN_MCP_DIR/graph-depth-policy.sh"
fi

readonly GRAPH_DELEGATED_RUN_MCP_MAX_TASK_BYTES=4096
readonly GRAPH_DELEGATED_RUN_MCP_WAIT_MAX_SECONDS=30
readonly GRAPH_DELEGATED_RUN_MCP_WAIT_POLL_INTERVAL=1

_graph_delegated_run_log() {
  local workspace="${WORKSPACE_ROOT:-}" state_root path
  [[ -n "$workspace" ]] || return 0
  state_root="$(graph_state_state_root "$workspace" 2>/dev/null || true)"
  [[ -n "$state_root" ]] || return 0
  path="$state_root/logs/delegated-run-mcp.log"
  mkdir -p "$(dirname "$path")" 2>/dev/null || true
  printf '[%s] delegated-run-mcp: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$path" 2>/dev/null || true
}

# Scope denial is a no-recursion boundary, so every refusal is recorded as a
# structured denial in no-recursion.log, not only returned to the caller.
_graph_delegated_run_scope_allows() {
  local tool="${1:-ralph_delegated_run_start}"
  case "${RALPH_MCP_SCOPE:-operator}" in
    operator|graph-node) return 0 ;;
    *) graph_depth_policy_enforce_scope "$tool" >/dev/null 2>&1 || true; return 1 ;;
  esac
}

_graph_delegated_run_assert_context() {
  local missing=()
  [[ -n "${RALPH_GRAPH_NAMESPACE:-}" ]] || missing+=(RALPH_GRAPH_NAMESPACE)
  [[ -n "${RALPH_GRAPH_RUN_ID:-}" ]] || missing+=(RALPH_GRAPH_RUN_ID)
  [[ -n "${RALPH_GRAPH_NODE_ID:-}" ]] || missing+=(RALPH_GRAPH_NODE_ID)
  [[ -n "${RALPH_GRAPH_ATTEMPT_ID:-}" ]] || missing+=(RALPH_GRAPH_ATTEMPT_ID)
  (( ${#missing[@]} == 0 )) || { printf '%s\n' "missing graph context env vars: ${missing[*]}" >&2; return 1; }
}

_graph_delegated_run_validate_id() { graph_delegation_ledger_valid_id "${1:-}"; }

_graph_delegated_run_policy() {
  local policy="${RALPH_GRAPH_NODE_POLICY:-}"
  [[ -n "$policy" ]] || return 1
  jq -e . >/dev/null 2>&1 <<<"$policy" || return 1
  jq -c '.delegatedRuns // empty' <<<"$policy" 2>/dev/null
}

_graph_delegated_run_validate_policy() {
  local policy="$1" mode max_runs max_parallel
  jq -e 'type == "object" and ((keys - ["mode","runtimes","roles","maxRuns","maxParallel"]) | length == 0)' <<<"$policy" >/dev/null 2>&1 || return 1
  mode="$(jq -r '.mode // empty' <<<"$policy")"
  [[ "$mode" == read-only || "$mode" == changeset ]] || return 1
  jq -e '(.runtimes | type == "array" and length > 0 and length == (unique | length) and all(.[]; . as $r | type == "string" and (["cursor","claude","codex","opencode","antigravity"] | index($r)) != null))' <<<"$policy" >/dev/null 2>&1 || return 1
  jq -e '(.roles // [] | type == "array" and length == (unique | length) and all(.[]; type == "string" and test("^[a-z0-9]+(-[a-z0-9]+)*$")))' <<<"$policy" >/dev/null 2>&1 || return 1
  max_runs="$(jq -r '.maxRuns // empty' <<<"$policy")"
  max_parallel="$(jq -r '.maxParallel // empty' <<<"$policy")"
  [[ "$max_runs" =~ ^[1-9][0-9]*$ && "$max_parallel" =~ ^[1-9][0-9]*$ ]] || return 1
  (( max_parallel <= max_runs ))
}

_graph_delegated_run_validate_paths() {
  local project="$1" paths="$2" path base current part resolved
  jq -e 'type == "array" and all(.[]; type == "string" and length > 0)' <<<"$paths" >/dev/null 2>&1 || return 1
  base="$(cd "$project" 2>/dev/null && pwd -P)" || return 1
  while IFS= read -r path; do
    [[ "$path" != /* && "$path" != *'\'* && "$path" != */ && "$path" != *//* && "$path" != *"/../"* && "$path" != ../* && "$path" != */.. && "$path" != .. ]] || return 1
    current="$base"
    while IFS= read -r -d '/' part; do
      [[ -n "$part" ]] || return 1
      current="$current/$part"
      if [[ -L "$current" ]]; then
        resolved="$(realpath "$current" 2>/dev/null || true)"
        [[ -n "$resolved" && ( "$resolved" == "$base" || "$resolved" == "$base/"* ) ]] || return 1
      fi
    done < <(printf '%s/' "$path")
  done < <(jq -r '.[]' <<<"$paths")
}

_graph_delegated_run_error() { send_error "$1" "$2" "-32602" "$3"; }
_graph_delegated_run_ok_result() {
  jq -cn --arg text "$1" --argjson structured "$2" \
    '{content:[{type:"text",text:$text}],structuredContent:$structured,isError:false}'
}
_graph_delegated_run_status_json() {
  jq -cn --arg id "$1" --argjson status "$2" --argjson timedOut "${3:-false}" \
    '$status + {delegatedRunId:$id,timedOut:$timedOut}'
}

graph_delegated_run_mcp_tools_json() {
  cat <<'TOOLS_JSON'
[
  {"name":"ralph_delegated_run_start","description":"Create a queued delegated run after validating the delegatedRuns policy.","inputSchema":{"type":"object","additionalProperties":false,"properties":{"task":{"type":"string"},"idempotencyKey":{"type":"string"},"runtime":{"type":"string","enum":["cursor","claude","codex","opencode","antigravity"]},"role":{"type":"string"},"artifactPaths":{"type":"array","items":{"type":"string"}}},"required":["task","idempotencyKey","runtime"]}},
  {"name":"ralph_delegated_run_status","description":"Read delegated run status.","inputSchema":{"type":"object","additionalProperties":false,"properties":{"delegatedRunId":{"type":"string"}},"required":["delegatedRunId"]}},
  {"name":"ralph_delegated_run_wait","description":"Wait for a delegated run to reach a terminal state.","inputSchema":{"type":"object","additionalProperties":false,"properties":{"delegatedRunId":{"type":"string"},"timeoutSeconds":{"type":"integer","minimum":1,"maximum":30}},"required":["delegatedRunId"]}},
  {"name":"ralph_delegated_run_result","description":"Read a terminal delegated run result.","inputSchema":{"type":"object","additionalProperties":false,"properties":{"delegatedRunId":{"type":"string"}},"required":["delegatedRunId"]}},
  {"name":"ralph_delegated_run_cancel","description":"Cancel a queued or running delegated run.","inputSchema":{"type":"object","additionalProperties":false,"properties":{"delegatedRunId":{"type":"string"}},"required":["delegatedRunId"]}}
]
TOOLS_JSON
}

graph_delegated_run_mcp_catalog_hidden_tools() {
  case "${RALPH_MCP_SCOPE:-operator}" in
    graph-node) printf '%s\n' ralph_run_plan ralph_orchestrator_run ralph_graph_run ;;
    native-subagent|delegated-child)
      printf '%s\n' ralph_delegated_run_start ralph_delegated_run_status ralph_delegated_run_wait ralph_delegated_run_result ralph_delegated_run_cancel ralph_run_plan ralph_orchestrator_run ralph_graph_run ;;
  esac
}

_graph_delegated_run_read_allowed() {
  local tool="${1:-ralph_delegated_run_status}"
  case "${RALPH_MCP_SCOPE:-operator}" in
    operator|graph-node) return 0 ;;
    *) graph_depth_policy_enforce_scope "$tool" >/dev/null 2>&1 || true; return 1 ;;
  esac
}
_graph_delegated_run_read_context() {
  [[ "${RALPH_MCP_SCOPE:-operator}" != graph-node ]] || _graph_delegated_run_assert_context
}

_graph_delegated_run_validate_request() {
  local args="$1" policy project paths task key runtime role
  jq -e 'type == "object" and ((keys - ["task","idempotencyKey","runtime","role","artifactPaths"]) | length == 0)' <<<"$args" >/dev/null 2>&1 || return 1
  task="$(jq -r '.task // empty' <<<"$args")"; key="$(jq -r '.idempotencyKey // empty' <<<"$args")"; runtime="$(jq -r '.runtime // empty' <<<"$args")"; role="$(jq -r '.role // empty' <<<"$args")"; paths="$(jq -c '.artifactPaths // []' <<<"$args")"
  [[ -n "$task" ]] || return 2
  local bytes="$(LC_ALL=C printf '%s' "$task" | wc -c | tr -d ' ')"
  [[ "$bytes" =~ ^[0-9]+$ && "$bytes" -le "$GRAPH_DELEGATED_RUN_MCP_MAX_TASK_BYTES" ]] || return 2
  graph_delegation_ledger_safe_component "$key" >/dev/null 2>&1 || return 3
  [[ "$runtime" == cursor || "$runtime" == claude || "$runtime" == codex || "$runtime" == opencode || "$runtime" == antigravity ]] || return 4
  [[ -z "$role" || "$role" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || return 5
  policy="$(_graph_delegated_run_policy)" || return 6
  _graph_delegated_run_validate_policy "$policy" || return 6
  jq -e --arg runtime "$runtime" '.runtimes | index($runtime) != null' <<<"$policy" >/dev/null 2>&1 || return 7
  if [[ "$(jq '.roles | length' <<<"$policy")" -gt 0 ]]; then
    [[ -n "$role" ]] || return 8
    jq -e --arg role "$role" '.roles | index($role) != null' <<<"$policy" >/dev/null 2>&1 || return 8
  else
    [[ -z "$role" ]] || return 8
  fi
  project="${RALPH_PROJECT_ROOT:-${WORKSPACE_ROOT:-}}"
  [[ -d "$project" ]] || return 9
  _graph_delegated_run_validate_paths "$project" "$paths" || return 10
  printf '%s\n' "$policy"
}

# ---- ralph_delegated_run_start --------------------------------------------
handle_delegated_run_start() {
  local args="$1" id_present="$2" id_raw="$3" policy rc
  _graph_delegated_run_scope_allows ralph_delegated_run_start || { _graph_delegated_run_error "$id_present" "$id_raw" "ralph_delegated_run_start is not available in scope: ${RALPH_MCP_SCOPE:-operator}"; return; }
  _graph_delegated_run_assert_context || { _graph_delegated_run_error "$id_present" "$id_raw" "graph node context is required"; return; }
  # Maximum delegated-run depth is one. The runner re-checks it and the ledger
  # guards the write path; this is the boundary check at the MCP edge, so a
  # forged depth is refused before any ledger record exists.
  graph_depth_policy_enforce_depth ralph_delegated_run_start 1 >/dev/null 2>&1 \
    || { _graph_delegated_run_error "$id_present" "$id_raw" "delegated run depth limit reached: maximum depth is 1"; return; }
  if policy="$(_graph_delegated_run_validate_request "$args")"; then rc=0; else rc=$?; fi
  case "$rc" in
    0) ;;
    2) _graph_delegated_run_error "$id_present" "$id_raw" "task is required and must be at most 4096 bytes"; return ;;
    3) _graph_delegated_run_error "$id_present" "$id_raw" "idempotencyKey is invalid"; return ;;
    4) _graph_delegated_run_error "$id_present" "$id_raw" "runtime is unsupported"; return ;;
    5) _graph_delegated_run_error "$id_present" "$id_raw" "role is invalid"; return ;;
    6|7|8) _graph_delegated_run_error "$id_present" "$id_raw" "request is not allowed by the delegatedRuns policy"; return ;;
    9|10) _graph_delegated_run_error "$id_present" "$id_raw" "artifactPaths must be safe project-relative paths"; return ;;
    *) _graph_delegated_run_error "$id_present" "$id_raw" "invalid delegated run request"; return ;;
  esac
  local task key runtime role paths id request_json max_runs max_parallel request_file
  task="$(jq -r '.task' <<<"$args")"; key="$(jq -r '.idempotencyKey' <<<"$args")"; runtime="$(jq -r '.runtime' <<<"$args")"; role="$(jq -r '.role // empty' <<<"$args")"; paths="$(jq -c '.artifactPaths // []' <<<"$args")"
  id="$(graph_delegation_ledger_id "$RALPH_GRAPH_RUN_ID" "$RALPH_GRAPH_NODE_ID" "$RALPH_GRAPH_ATTEMPT_ID" "$key")" || { _graph_delegated_run_error "$id_present" "$id_raw" "failed to derive delegatedRunId"; return; }
  request_json="$(jq -cn --arg id "$id" --arg task "$task" --arg key "$key" --arg runtime "$runtime" --arg role "$role" --argjson paths "$paths" '{delegatedRunId:$id,task:$task,idempotencyKey:$key,runtime:$runtime} + (if $role == "" then {} else {role:$role} end) + (if ($paths|length) == 0 then {} else {artifactPaths:$paths} end)')" || { _graph_delegated_run_error "$id_present" "$id_raw" "failed to build delegated run request"; return; }
  request_file="$(graph_delegation_ledger_request_file "$WORKSPACE_ROOT" "$id")"
  if ! graph_delegation_ledger_start "$WORKSPACE_ROOT" "$id" "$request_json" >/dev/null 2>/dev/null; then
    if [[ ! -f "$request_file" ]] || ! jq -e --argjson request "$request_json" 'del(.schemaVersion,.createdAt) == $request' "$request_file" >/dev/null 2>&1; then
      _graph_delegated_run_error "$id_present" "$id_raw" "idempotencyKey conflicts with an existing delegated run"; return
    fi
  fi
  max_runs="$(jq -r '.maxRuns' <<<"$policy")"; max_parallel="$(jq -r '.maxParallel' <<<"$policy")"
  graph_delegation_queue_enqueue "$WORKSPACE_ROOT" "$RALPH_GRAPH_NAMESPACE" "$RALPH_GRAPH_RUN_ID" "$RALPH_GRAPH_NODE_ID" "$id" "$max_runs" "$max_parallel" >/dev/null 2>/dev/null || { _graph_delegated_run_error "$id_present" "$id_raw" "failed to enqueue delegated run"; return; }
  _graph_delegated_run_log "start delegatedRunId=$id runtime=$runtime role=${role:-none}"
  local status_json now structured
  status_json="$(graph_delegation_ledger_read_status "$WORKSPACE_ROOT" "$id")" || { send_error "$id_present" "$id_raw" "-32000" "failed to read delegated run status"; return; }
  now="$(jq -r '.createdAt // .updatedAt // empty' <<<"$status_json")"
  structured="$(jq -cn --arg id "$id" --arg runtime "$runtime" --arg role "$role" --arg now "$now" --argjson paths "$paths" '{delegatedRunId:$id,status:"queued",runtime:$runtime} + (if $role == "" then {} else {role:$role} end) + {artifactPaths:$paths,createdAt:$now}')"
  send_result "$id_present" "$id_raw" "$(_graph_delegated_run_ok_result "delegated run queued: $id" "$structured")"
}

_graph_delegated_run_load_status() {
  _graph_delegated_run_validate_id "$1" || return 2
  graph_delegation_ledger_read_status "$WORKSPACE_ROOT" "$1" 2>/dev/null
}

# ---- ralph_delegated_run_status -------------------------------------------
handle_delegated_run_status() {
  local args="$1" id_present="$2" id_raw="$3" id status rc
  _graph_delegated_run_read_allowed ralph_delegated_run_status || { _graph_delegated_run_error "$id_present" "$id_raw" "ralph_delegated_run_status is not available in scope"; return; }
  _graph_delegated_run_read_context || { _graph_delegated_run_error "$id_present" "$id_raw" "graph node context is required"; return; }
  jq -e 'type == "object" and ((keys - ["delegatedRunId"]) | length == 0) and (.delegatedRunId | type == "string")' <<<"$args" >/dev/null 2>&1 || { _graph_delegated_run_error "$id_present" "$id_raw" "delegatedRunId is required"; return; }
  id="$(jq -r '.delegatedRunId' <<<"$args")"; status="$(_graph_delegated_run_load_status "$id")"; rc=$?
  (( rc == 0 )) || { (( rc == 2 )) && _graph_delegated_run_error "$id_present" "$id_raw" "delegatedRunId is invalid" || send_error "$id_present" "$id_raw" "-32000" "delegated run not found: $id"; return; }
  send_result "$id_present" "$id_raw" "$(_graph_delegated_run_ok_result "delegated run status: $id" "$(_graph_delegated_run_status_json "$id" "$status")")"
}

# ---- ralph_delegated_run_wait ---------------------------------------------
handle_delegated_run_wait() {
  local args="$1" id_present="$2" id_raw="$3" id timeout started now status
  _graph_delegated_run_read_allowed ralph_delegated_run_wait || { _graph_delegated_run_error "$id_present" "$id_raw" "ralph_delegated_run_wait is not available in scope"; return; }
  _graph_delegated_run_read_context || { _graph_delegated_run_error "$id_present" "$id_raw" "graph node context is required"; return; }
  jq -e 'type == "object" and ((keys - ["delegatedRunId","timeoutSeconds"]) | length == 0) and (.delegatedRunId | type == "string") and ((.timeoutSeconds? == null) or (.timeoutSeconds | type == "number" and floor == . and . >= 1))' <<<"$args" >/dev/null 2>&1 || { _graph_delegated_run_error "$id_present" "$id_raw" "delegatedRunId and a valid timeoutSeconds are required"; return; }
  id="$(jq -r '.delegatedRunId' <<<"$args")"; timeout="$(jq -r '.timeoutSeconds // 30' <<<"$args")"; (( timeout > GRAPH_DELEGATED_RUN_MCP_WAIT_MAX_SECONDS )) && timeout=$GRAPH_DELEGATED_RUN_MCP_WAIT_MAX_SECONDS
  _graph_delegated_run_validate_id "$id" || { _graph_delegated_run_error "$id_present" "$id_raw" "delegatedRunId is invalid"; return; }
  started="$(date +%s)"
  while :; do
    status="$(graph_delegation_ledger_read_status "$WORKSPACE_ROOT" "$id" 2>/dev/null)" || { send_error "$id_present" "$id_raw" "-32000" "delegated run not found: $id"; return; }
    case "$(jq -r '.status' <<<"$status")" in
      succeeded|failed|cancelled) send_result "$id_present" "$id_raw" "$(_graph_delegated_run_ok_result "delegated run reached terminal state: $id" "$(_graph_delegated_run_status_json "$id" "$status" false)")"; return ;;
    esac
    now="$(date +%s)"
    if (( now - started >= timeout )); then
      send_result "$id_present" "$id_raw" "$(_graph_delegated_run_ok_result "delegated run wait timed out: $id" "$(_graph_delegated_run_status_json "$id" "$status" true)")"; return
    fi
    sleep "$GRAPH_DELEGATED_RUN_MCP_WAIT_POLL_INTERVAL"
  done
}

# ---- ralph_delegated_run_result -------------------------------------------
handle_delegated_run_result() {
  local args="$1" id_present="$2" id_raw="$3" id status result_file result
  _graph_delegated_run_read_allowed ralph_delegated_run_result || { _graph_delegated_run_error "$id_present" "$id_raw" "ralph_delegated_run_result is not available in scope"; return; }
  _graph_delegated_run_read_context || { _graph_delegated_run_error "$id_present" "$id_raw" "graph node context is required"; return; }
  jq -e 'type == "object" and ((keys - ["delegatedRunId"]) | length == 0) and (.delegatedRunId | type == "string")' <<<"$args" >/dev/null 2>&1 || { _graph_delegated_run_error "$id_present" "$id_raw" "delegatedRunId is required"; return; }
  id="$(jq -r '.delegatedRunId' <<<"$args")"; _graph_delegated_run_validate_id "$id" || { _graph_delegated_run_error "$id_present" "$id_raw" "delegatedRunId is invalid"; return; }
  status="$(graph_delegation_ledger_read_status "$WORKSPACE_ROOT" "$id" 2>/dev/null)" || { send_error "$id_present" "$id_raw" "-32000" "delegated run not found: $id"; return; }
  [[ "$(jq -r '.status' <<<"$status")" == succeeded || "$(jq -r '.status' <<<"$status")" == failed || "$(jq -r '.status' <<<"$status")" == cancelled ]] || { send_error "$id_present" "$id_raw" "-32602" "delegated run is not terminal: $id"; return; }
  result_file="$(graph_delegation_ledger_result_file "$WORKSPACE_ROOT" "$id")"; [[ -f "$result_file" ]] || { send_error "$id_present" "$id_raw" "-32000" "delegated run result is unavailable: $id"; return; }
  result="$(jq -c '.result' "$result_file" 2>/dev/null)" || { send_error "$id_present" "$id_raw" "-32000" "delegated run result is invalid: $id"; return; }
  send_result "$id_present" "$id_raw" "$(_graph_delegated_run_ok_result "delegated run result: $id" "$(jq -cn --arg id "$id" --arg status "$(jq -r '.status' <<<"$status")" --argjson result "$result" '{delegatedRunId:$id,status:$status,result:$result}')")"
}

# ---- ralph_delegated_run_cancel -------------------------------------------
handle_delegated_run_cancel() {
  local args="$1" id_present="$2" id_raw="$3" id status current
  _graph_delegated_run_read_allowed ralph_delegated_run_cancel || { _graph_delegated_run_error "$id_present" "$id_raw" "ralph_delegated_run_cancel is not available in scope"; return; }
  _graph_delegated_run_read_context || { _graph_delegated_run_error "$id_present" "$id_raw" "graph node context is required"; return; }
  jq -e 'type == "object" and ((keys - ["delegatedRunId"]) | length == 0) and (.delegatedRunId | type == "string")' <<<"$args" >/dev/null 2>&1 || { _graph_delegated_run_error "$id_present" "$id_raw" "delegatedRunId is required"; return; }
  id="$(jq -r '.delegatedRunId' <<<"$args")"; _graph_delegated_run_validate_id "$id" || { _graph_delegated_run_error "$id_present" "$id_raw" "delegatedRunId is invalid"; return; }
  status="$(graph_delegation_ledger_read_status "$WORKSPACE_ROOT" "$id" 2>/dev/null)" || { send_error "$id_present" "$id_raw" "-32000" "delegated run not found: $id"; return; }
  current="$(jq -r '.status' <<<"$status")"
  case "$current" in
    cancelled) ;;
    queued|running)
      if ! declare -F graph_delegation_child_cancel >/dev/null 2>&1; then
        source "$_GRAPH_DELEGATED_RUN_MCP_DIR/graph-delegation-runner.sh"
      fi
      graph_delegation_child_cancel "$WORKSPACE_ROOT" "$id" "cancelled by MCP" >/dev/null 2>&1 || { send_error "$id_present" "$id_raw" "-32000" "failed to cancel delegated run: $id"; return; } ;;
    *) send_error "$id_present" "$id_raw" "-32602" "delegated run is already terminal: $id"; return ;;
  esac
  status="$(graph_delegation_ledger_read_status "$WORKSPACE_ROOT" "$id")" || { send_error "$id_present" "$id_raw" "-32000" "failed to read cancelled delegated run"; return; }
  send_result "$id_present" "$id_raw" "$(_graph_delegated_run_ok_result "delegated run cancelled: $id" "$(_graph_delegated_run_status_json "$id" "$status")")"
}
