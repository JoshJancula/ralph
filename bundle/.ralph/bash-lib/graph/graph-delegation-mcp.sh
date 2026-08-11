#!/usr/bin/env bash
# MCP broker tools for delegated children under graph-node agents.
#
# The five delegation tools (ralph_delegate_start, ralph_delegate_status,
# ralph_delegate_wait, ralph_delegate_result, ralph_delegate_cancel) allow a
# graph-node agent to request, monitor, and retrieve the output of a bounded
# child task without exposing arbitrary shell, environment, workspace, plan,
# graph, or artifact paths.
#
# Security model
# -------------
# - Handlers revalidate scope, caller identity, depth, and policy on every call.
# - The MCP tool catalog is filtered by scope as a usability hint only; catalog
#   hiding is not the security boundary.
# - No inputs accept workspace, plan_path, graph_path, artifact_paths, or
#   env_overrides; those are derived from server context (WORKSPACE_ROOT) and
#   frozen policy (RALPH_GRAPH_NODE_POLICY) injected by the scheduler.
# - The delegation_id parameter for status/wait/result/cancel must match the
#   ledger format (delegation-<24 hex chars>) and the call must originate from
#   the node that created it (matched via server context env vars).
#
# Execution scopes
# ----------------
# operator          All tools visible and callable; no context restrictions.
# graph-node        Delegation broker tools available; run_plan,
#                   orchestrator_run, and graph_run are removed from catalog.
#                   Handlers enforce RALPH_GRAPH_{NAMESPACE,RUN_ID,NODE_ID,
#                   ATTEMPT_ID} and policy.
# native-subagent   ralph_delegate_start, ralph_run_plan, ralph_orchestrator_run,
#                   and ralph_graph_run are removed from catalog. Handlers reject
#                   calls that require graph-node context.
# delegated-child   Same restrictions as native-subagent.
#
# Env vars consumed (set by the scheduler before the agent session starts)
# -----------------------------------------------------------------------
# RALPH_MCP_SCOPE             operator|graph-node|native-subagent|delegated-child
# RALPH_GRAPH_NAMESPACE       graph-run namespace
# RALPH_GRAPH_RUN_ID          graph-run id
# RALPH_GRAPH_NODE_ID         this node's id (already set by scheduler)
# RALPH_GRAPH_ATTEMPT_ID      this attempt's id
# RALPH_GRAPH_DELEGATION_DEPTH current delegation depth (0 = top-level node)
# RALPH_GRAPH_NODE_POLICY     frozen policy JSON from graph compile step
#
# Log file: <state-root>/logs/delegation-mcp.log

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

if [[ -n "${GRAPH_DELEGATION_MCP_LOADED:-}" ]]; then return 0; fi
GRAPH_DELEGATION_MCP_LOADED=1

_GRAPH_DELEGATION_MCP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F graph_delegation_ledger_start >/dev/null 2>&1; then
  # shellcheck source=graph-delegation-ledger.sh
  source "$_GRAPH_DELEGATION_MCP_DIR/graph-delegation-ledger.sh"
fi
if ! declare -F graph_delegation_queue_enqueue >/dev/null 2>&1; then
  # shellcheck source=graph-delegation-queue.sh
  source "$_GRAPH_DELEGATION_MCP_DIR/graph-delegation-queue.sh"
fi
if ! declare -F graph_delegation_child_cancel >/dev/null 2>&1; then
  source "$_GRAPH_DELEGATION_MCP_DIR/graph-delegation-runner.sh"
fi
if ! declare -F graph_depth_policy_log_denial >/dev/null 2>&1; then
  # shellcheck source=graph-depth-policy.sh
  source "$_GRAPH_DELEGATION_MCP_DIR/graph-depth-policy.sh"
fi

# Scope name constants
readonly RALPH_MCP_SCOPE_OPERATOR="operator"
readonly RALPH_MCP_SCOPE_GRAPH_NODE="graph-node"
readonly RALPH_MCP_SCOPE_NATIVE_SUBAGENT="native-subagent"
readonly RALPH_MCP_SCOPE_DELEGATED_CHILD="delegated-child"

# Limits
readonly GRAPH_DELEGATION_MCP_MAX_TASK_BYTES=4096
readonly GRAPH_DELEGATION_MCP_WAIT_MAX_SECONDS=30
readonly GRAPH_DELEGATION_MCP_WAIT_POLL_INTERVAL=2

# ---- Logging ---------------------------------------------------------------

_graph_delegation_mcp_log() {
  local workspace="${WORKSPACE_ROOT:-}"
  local state_root path
  if [[ -n "$workspace" ]]; then
    state_root="$(graph_state_state_root "$workspace")" || return 0
    path="$state_root/logs/delegation-mcp.log"
    mkdir -p "$(dirname "$path")" 2>/dev/null || true
    printf '[%s] delegation-mcp: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u)" "$*" >>"$path" 2>/dev/null || true
  fi
}

# ---- Scope helpers ---------------------------------------------------------

# True when the current scope allows calling ralph_delegate_start.
_graph_delegation_mcp_scope_allows_start() {
  local scope="${RALPH_MCP_SCOPE:-operator}"
  case "$scope" in
    operator|graph-node) return 0 ;;
    *) return 1 ;;
  esac
}

# True when the current scope allows calling the broker read tools
# (status, wait, result, cancel).
_graph_delegation_mcp_scope_allows_broker() {
  local scope="${RALPH_MCP_SCOPE:-operator}"
  case "$scope" in
    operator|graph-node) return 0 ;;
    *) return 1 ;;
  esac
}

# Emit a JSON array of tool names that should be hidden for the given scope.
# Called by get_tool_list_result() in mcp-server.sh to filter the catalog.
# The catalog filter is a usability hint; handler enforcement is the boundary.
graph_delegation_mcp_catalog_hidden_tools() {
  local scope="${RALPH_MCP_SCOPE:-operator}"
  case "$scope" in
    graph-node)
      # Graph nodes cannot spawn top-level runs; they use delegation tools instead.
      printf '%s\n' \
        ralph_run_plan \
        ralph_orchestrator_run \
        ralph_graph_run
      ;;
    native-subagent|delegated-child)
      # Subagents and delegated children cannot start new work at any level.
      printf '%s\n' \
        ralph_delegate_start \
        ralph_run_plan \
        ralph_orchestrator_run \
        ralph_graph_run
      ;;
    *)
      # operator or unknown: no tools hidden
      ;;
  esac
}

# Return the delegation tool schema JSON array for inclusion in the catalog.
# This is appended in mcp-server.sh get_tool_list_result().
graph_delegation_mcp_tools_json() {
  cat <<'TOOLS_JSON'
[
  {
    "name": "ralph_delegate_start",
    "description": "Start a delegated child task under the current graph node. The task, runtime, and agent must satisfy the frozen delegation policy for this node. Workspace, plan paths, graph paths, artifact paths, and environment overrides are not accepted; they are derived from the server context and policy.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "task": {
          "type": "string",
          "description": "Bounded task description for the child (max 4096 bytes). No shell metacharacters."
        },
        "idempotency_key": {
          "type": "string",
          "description": "Client-supplied idempotency key. Repeating an identical request returns the same delegation id. Reusing the key with different task or policy content is an error."
        },
        "runtime": {
          "type": "string",
          "description": "Requested runtime from the stage delegation allowlist (e.g. claude, codex). Use 'inherit' for native same-runtime delegation."
        },
        "agent": {
          "type": "string",
          "description": "Requested agent from the stage delegation allowlist."
        },
        "mode": {
          "type": "string",
          "enum": ["snapshot", "worktree", "inherit"],
          "description": "Workspace isolation mode for the child (default: inherit)."
        },
        "access": {
          "type": "string",
          "enum": ["read-only", "changeset"],
          "description": "Requested child authority (default: read-only). A changeset request is accepted only when the frozen stage policy allows changesets."
        },
        "verification_profile": {
          "type": "string",
          "description": "Named verification profile for the child (optional)."
        },
        "result_kind": {
          "type": "string",
          "enum": ["text", "json", "artifact"],
          "description": "Declared kind of result the child will produce (default: text)."
        }
      },
      "required": ["task", "idempotency_key", "runtime", "agent"]
    }
  },
  {
    "name": "ralph_delegate_status",
    "description": "Return the current status of a delegated child by delegation id.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "delegation_id": {
          "type": "string",
          "description": "Delegation id returned by ralph_delegate_start."
        }
      },
      "required": ["delegation_id"]
    }
  },
  {
    "name": "ralph_delegate_wait",
    "description": "Block until the delegated child reaches a terminal state or the server-side timeout elapses. The timeout is capped at 30 seconds; call again if the delegation is still running. Never busy-loops.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "delegation_id": {
          "type": "string",
          "description": "Delegation id returned by ralph_delegate_start."
        },
        "timeout_seconds": {
          "type": "integer",
          "description": "Maximum seconds to wait (capped at 30). Defaults to 30.",
          "minimum": 1,
          "maximum": 30
        }
      },
      "required": ["delegation_id"]
    }
  },
  {
    "name": "ralph_delegate_result",
    "description": "Read the final result of a completed delegation. The delegation must be in a terminal state (succeeded, failed, or cancelled).",
    "inputSchema": {
      "type": "object",
      "properties": {
        "delegation_id": {
          "type": "string",
          "description": "Delegation id returned by ralph_delegate_start."
        }
      },
      "required": ["delegation_id"]
    }
  },
  {
    "name": "ralph_delegate_cancel",
    "description": "Cancel a running or queued delegation. The scheduler picks up the cancellation from the ledger. Idempotent: cancelling an already-cancelled delegation succeeds.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "delegation_id": {
          "type": "string",
          "description": "Delegation id returned by ralph_delegate_start."
        }
      },
      "required": ["delegation_id"]
    }
  }
]
TOOLS_JSON
}

# ---- Input validators ------------------------------------------------------

# Assert the required graph-node context env vars are present.
_graph_delegation_mcp_assert_graph_context() {
  local missing=()
  [[ -n "${RALPH_GRAPH_NAMESPACE:-}" ]] || missing+=(RALPH_GRAPH_NAMESPACE)
  [[ -n "${RALPH_GRAPH_RUN_ID:-}" ]]    || missing+=(RALPH_GRAPH_RUN_ID)
  [[ -n "${RALPH_GRAPH_NODE_ID:-}" ]]   || missing+=(RALPH_GRAPH_NODE_ID)
  [[ -n "${RALPH_GRAPH_ATTEMPT_ID:-}" ]]|| missing+=(RALPH_GRAPH_ATTEMPT_ID)
  if [[ "${#missing[@]}" -gt 0 ]]; then
    printf 'missing graph context env vars: %s\n' "${missing[*]}" >&2
    return 1
  fi
  return 0
}

# Assert delegation_id matches the expected format (delegation-<24 hex chars>)
# and contains no path traversal characters.
_graph_delegation_mcp_validate_delegation_id() {
  local did="$1"
  [[ -n "$did" ]] || return 1
  [[ "$did" =~ ^delegation-[0-9a-f]{24}$ ]] || return 1
  [[ "$did" != *"/"* && "$did" != *"\\"* && "$did" != *".."* ]] || return 1
  return 0
}

# Check whether runtime is allowed by the frozen policy.
# native delegation: runtime == "inherit" -> check policy.native.mode != "off"
# cross-runtime: runtime in policy.crossRuntime.allowedRuntimes
_graph_delegation_mcp_runtime_allowed() {
  local runtime="$1" policy="$2"
  if [[ "$runtime" == "inherit" ]]; then
    local mode
    mode="$(jq -r '.native.mode // "off"' <<<"$policy" 2>/dev/null)"
    [[ "$mode" != "off" ]] && return 0
    return 1
  fi
  # Cross-runtime
  local cr_mode
  cr_mode="$(jq -r '.crossRuntime.mode // "off"' <<<"$policy" 2>/dev/null)"
  [[ "$cr_mode" == "off" ]] && return 1
  jq -e --arg r "$runtime" '(.crossRuntime.allowedRuntimes // []) | index($r) != null' \
    <<<"$policy" >/dev/null 2>&1
}

# Check whether agent is allowed by the frozen policy for the given runtime.
_graph_delegation_mcp_agent_allowed() {
  local agent="$1" runtime="$2" policy="$3"
  if [[ "$runtime" == "inherit" ]]; then
    jq -e --arg a "$agent" \
      '(.native.allowedAgents // []) | (map(select(. == "*" or . == $a)) | length) > 0' \
      <<<"$policy" >/dev/null 2>&1
  else
    jq -e --arg a "$agent" \
      '(.crossRuntime.allowedAgents // []) | (map(select(. == "*" or . == $a)) | length) > 0' \
      <<<"$policy" >/dev/null 2>&1
  fi
}

# ---- Tool result builder ---------------------------------------------------

_graph_delegation_mcp_ok_result() {
  local text="$1" structured="$2"
  jq -cn --arg t "$text" --argjson s "$structured" \
    '{content:[{type:"text",text:$t}],structuredContent:$s,isError:false}'
}

_graph_delegation_mcp_error_text_result() {
  local text="$1"
  jq -cn --arg t "$text" \
    '{content:[{type:"text",text:$t}],isError:true}'
}

# ---- Handler: ralph_delegate_start -----------------------------------------

handle_delegate_start() {
  local args_json="$1"
  local id_present="$2"
  local id_raw="$3"

  local scope="${RALPH_MCP_SCOPE:-operator}"

  # Scope enforcement (layer 3+4: catalog scope + server-side caller validation)
  if ! _graph_delegation_mcp_scope_allows_start; then
    _graph_delegation_mcp_log "start denied: scope=$scope"
    graph_depth_policy_log_denial "scope" "ralph_delegate_start" \
      "scope '$scope' may not invoke ralph_delegate_start"
    send_error "$id_present" "$id_raw" "-32602" \
      "ralph_delegate_start is not available in scope: $scope"
    return
  fi

  # Graph context enforcement
  if ! _graph_delegation_mcp_assert_graph_context 2>/dev/null; then
    _graph_delegation_mcp_log "start denied: graph context not set"
    send_error "$id_present" "$id_raw" "-32602" \
      "graph node context unavailable; scheduler must export RALPH_GRAPH_NAMESPACE, RALPH_GRAPH_RUN_ID, RALPH_GRAPH_NODE_ID, and RALPH_GRAPH_ATTEMPT_ID"
    return
  fi

  # Reject disallowed input keys (injection prevention)
  local injected
  injected="$(jq -r '[
    if has("workspace") then "workspace" else empty end,
    if has("plan_path") then "plan_path" else empty end,
    if has("graph_path") then "graph_path" else empty end,
    if has("artifact_paths") then "artifact_paths" else empty end,
    if has("env_overrides") then "env_overrides" else empty end
  ] | join(",")' <<<"$args_json" 2>/dev/null)"
  if [[ -n "$injected" ]]; then
    _graph_delegation_mcp_log "start denied: disallowed keys=$injected"
    send_error "$id_present" "$id_raw" "-32602" \
      "ralph_delegate_start does not accept: $injected"
    return
  fi

  # Extract and validate required inputs
  local task idempotency_key runtime agent
  local mode access verification_profile result_kind
  task="$(jq -r '.task // empty' <<<"$args_json" 2>/dev/null)"
  idempotency_key="$(jq -r '.idempotency_key // empty' <<<"$args_json" 2>/dev/null)"
  runtime="$(jq -r '.runtime // empty' <<<"$args_json" 2>/dev/null)"
  agent="$(jq -r '.agent // empty' <<<"$args_json" 2>/dev/null)"
  mode="$(jq -r '.mode // "inherit"' <<<"$args_json" 2>/dev/null)"
  access="$(jq -r '.access // "read-only"' <<<"$args_json" 2>/dev/null)"
  verification_profile="$(jq -r '.verification_profile // ""' <<<"$args_json" 2>/dev/null)"
  result_kind="$(jq -r '.result_kind // "text"' <<<"$args_json" 2>/dev/null)"

  if [[ -z "$task" || -z "$idempotency_key" || -z "$runtime" || -z "$agent" ]]; then
    send_error "$id_present" "$id_raw" "-32602" \
      "task, idempotency_key, runtime, and agent are required"
    return
  fi

  # Task length bound
  local task_len="${#task}"
  if [[ "$task_len" -gt "$GRAPH_DELEGATION_MCP_MAX_TASK_BYTES" ]]; then
    send_error "$id_present" "$id_raw" "-32602" \
      "task exceeds maximum length of $GRAPH_DELEGATION_MCP_MAX_TASK_BYTES bytes (got $task_len)"
    return
  fi

  # Idempotency key: safe component only (no path chars, no shell metacharacters)
  local safe_key
  safe_key="$(graph_delegation_ledger_safe_component "$idempotency_key" 2>/dev/null || true)"
  if [[ -z "$safe_key" || "$idempotency_key" =~ [/\\] || "$idempotency_key" =~ \.\. ]]; then
    send_error "$id_present" "$id_raw" "-32602" \
      "idempotency_key contains invalid characters (no path separators or traversal)"
    return
  fi

  # Mode validation
  case "$mode" in
    snapshot|worktree|inherit) ;;
    *)
      send_error "$id_present" "$id_raw" "-32602" \
        "mode must be one of: snapshot, worktree, inherit"
      return
      ;;
  esac

  case "$access" in
    read-only|changeset) ;;
    *)
      send_error "$id_present" "$id_raw" "-32602" \
        "access must be one of: read-only, changeset"
      return
      ;;
  esac

  # Result kind validation
  case "$result_kind" in
    text|json|artifact) ;;
    *)
      send_error "$id_present" "$id_raw" "-32602" \
        "result_kind must be one of: text, json, artifact"
      return
      ;;
  esac

  # Policy validation — do not use ${VAR:-{}} because the `}` in `{}`
  # closes the bash parameter expansion early, appending a stray `}` to the value.
  local policy="${RALPH_GRAPH_NODE_POLICY:-}"
  [[ -n "$policy" ]] || policy='{}'
  if [[ "$mode" == "inherit" ]]; then
    mode="$(jq -r '.parentWorkspaceMode // "snapshot"' <<<"$policy" 2>/dev/null || echo snapshot)"
    # Brokered work always gets an isolated child workspace. A shared parent
    # therefore resolves to the safe snapshot default rather than inheriting
    # concurrent mutation risk.
    [[ "$mode" == snapshot || "$mode" == worktree ]] || mode=snapshot
  fi
  local max_depth current_depth
  max_depth="$(jq -r '.maxDepth // 1' <<<"$policy" 2>/dev/null || echo 1)"
  current_depth="${RALPH_GRAPH_DELEGATION_DEPTH:-0}"
  if [[ ! "$max_depth" =~ ^[0-9]+$ ]]; then max_depth=1; fi
  # Layer 1: frozen policy — hard cap at GRAPH_DEPTH_MAX regardless of policy value.
  if [[ "$max_depth" -gt "$GRAPH_DEPTH_MAX" ]]; then
    graph_depth_policy_log_denial "policy-cap" "ralph_delegate_start" \
      "policy maxDepth=$max_depth exceeds frozen cap=$GRAPH_DEPTH_MAX; capping"
    max_depth="$GRAPH_DEPTH_MAX"
  fi
  if [[ "$current_depth" -ge "$max_depth" ]]; then
    _graph_delegation_mcp_log "start denied: depth=$current_depth maxDepth=$max_depth"
    graph_depth_policy_log_denial "depth" "ralph_delegate_start" \
      "delegation depth limit: current=$current_depth max=$max_depth (cap=$GRAPH_DEPTH_MAX)"
    send_error "$id_present" "$id_raw" "-32602" \
      "delegation depth limit reached: current=$current_depth max=$max_depth"
    return
  fi

  if ! _graph_delegation_mcp_runtime_allowed "$runtime" "$policy"; then
    _graph_delegation_mcp_log "start denied: runtime=$runtime not in policy allowlist"
    send_error "$id_present" "$id_raw" "-32602" \
      "runtime not in stage delegation allowlist: $runtime"
    return
  fi
  if [[ "$access" == changeset && "$(jq -r '.crossRuntime.mode // "off"' <<<"$policy")" != changeset ]]; then
    _graph_delegation_mcp_log "start denied: changeset access exceeds frozen policy"
    send_error "$id_present" "$id_raw" "-32602" \
      "changeset access is not allowed by the frozen stage delegation policy"
    return
  fi

  # A brokered child is always cross-runtime in graph v1.  `inherit` remains
  # accepted only when an older caller did not receive parent-runtime context;
  # graph scheduler invocations always set it and are therefore fail-closed.
  local parent_runtime="${RALPH_GRAPH_NODE_RUNTIME:-}"
  if [[ -n "$parent_runtime" && ( "$runtime" == "inherit" || "$runtime" == "$parent_runtime" ) ]]; then
    _graph_delegation_mcp_log "start denied: same runtime parent=$parent_runtime requested=$runtime"
    send_error "$id_present" "$id_raw" "-32602" \
      "same-runtime helper work must use a native subagent or sibling graph node"
    return
  fi

  if ! _graph_delegation_mcp_agent_allowed "$agent" "$runtime" "$policy"; then
    _graph_delegation_mcp_log "start denied: agent=$agent not in policy allowlist for runtime=$runtime"
    send_error "$id_present" "$id_raw" "-32602" \
      "agent not in stage delegation allowlist for runtime $runtime: $agent"
    return
  fi

  # Create ledger entry
  local ns="$RALPH_GRAPH_NAMESPACE"
  local run_id="$RALPH_GRAPH_RUN_ID"
  local node_id="$RALPH_GRAPH_NODE_ID"
  local attempt_id="$RALPH_GRAPH_ATTEMPT_ID"
  local child_depth=$(( current_depth + 1 ))
  local delegation_id
  local ledger_stderr
  ledger_stderr="$(mktemp)"
  set +e
  local request_policy
  request_policy="$(jq -c --arg access "$access" '. + {requestedAccess:$access}' <<<"$policy")" || {
    send_error "$id_present" "$id_raw" "-32000" "failed to freeze requested delegation access"; return
  }
  delegation_id="$(graph_delegation_ledger_start \
    "$WORKSPACE_ROOT" "$ns" "$run_id" "$node_id" "$attempt_id" \
    "$idempotency_key" "$task" "$request_policy" \
    "$runtime" "$agent" "" "$child_depth" "$mode" '[]' "" \
    2>"$ledger_stderr")"
  local rc=$?
  set -e
  local ledger_err
  ledger_err="$(cat "$ledger_stderr" 2>/dev/null || true)"
  rm -f "$ledger_stderr"

  if [[ $rc -ne 0 ]]; then
    if [[ "$ledger_err" == *"idempotency"* ]]; then
      _graph_delegation_mcp_log "start denied: idempotency conflict key=$idempotency_key"
      send_error "$id_present" "$id_raw" "-32602" \
        "idempotency key reused with different task or policy content"
    else
      _graph_delegation_mcp_log "start failed: ledger write error: $ledger_err"
      send_error "$id_present" "$id_raw" "-32000" \
        "failed to create delegation ledger entry"
    fi
    return
  fi

  # These are broker metadata, not caller-controlled shell input.  Persist
  # them before queue publication so the scheduler can compile the selected
  # frozen verification profile and result contract into its child plan.
  local request_file request_json
  request_file="$(graph_delegation_ledger_request_file "$WORKSPACE_ROOT" "$ns" "$run_id" "$node_id" "$delegation_id")"
  request_json="$(jq -c . "$request_file" 2>/dev/null)" || {
    send_error "$id_present" "$id_raw" "-32000" "failed to finalize delegation request"; return
  }
  ralph_atomic_write_json "$request_file" '($base | fromjson) + {verificationProfile:$profile,resultKind:$kind,accessMode:$access}' \
    --arg base "$request_json" --arg profile "$verification_profile" --arg kind "$result_kind" --arg access "$access" || {
    send_error "$id_present" "$id_raw" "-32000" "failed to finalize delegation request"; return
  }

  # Publish the request to the scheduler-owned durable queue only after the
  # request ledger is committed.  No runtime is invoked in this MCP process.
  local max_children queue_rc
  max_children="$(jq -r '.maxChildren // 0' <<<"$policy" 2>/dev/null || echo 0)"
  set +e
  graph_delegation_queue_enqueue "$WORKSPACE_ROOT" "$ns" "$run_id" "$node_id" "$delegation_id" "$max_children"
  queue_rc=$?
  set -e
  if [[ "$queue_rc" -ne 0 ]]; then
    graph_delegation_ledger_transition "$WORKSPACE_ROOT" "$ns" "$run_id" "$node_id" "$delegation_id" cancelled "" "" '{}' 'null' "queue admission rejected" 2>/dev/null || true
    if [[ "$queue_rc" -eq 3 ]]; then
      send_error "$id_present" "$id_raw" "-32602" "parent delegation maxChildren limit reached: $max_children"
    else
      send_error "$id_present" "$id_raw" "-32000" "failed to enqueue delegation request"
    fi
    return
  fi

  _graph_delegation_mcp_log "start ok: delegation=$delegation_id node=$node_id attempt=$attempt_id depth=$child_depth"

  local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u)"
  local structured
  structured="$(jq -cn \
    --arg did "$delegation_id" \
    --arg status "queued" \
    --arg now "$now" \
    --arg result_kind "$result_kind" \
    --arg access "$access" \
    '{delegation_id:$did,status:$status,queued_at:$now,result_kind:$result_kind,access:$access}')"
  send_result "$id_present" "$id_raw" \
    "$(_graph_delegation_mcp_ok_result "delegation queued: $delegation_id" "$structured")"
}

# ---- Handler: ralph_delegate_status ----------------------------------------

handle_delegate_status() {
  local args_json="$1"
  local id_present="$2"
  local id_raw="$3"

  local scope="${RALPH_MCP_SCOPE:-operator}"

  if ! _graph_delegation_mcp_scope_allows_broker; then
    _graph_delegation_mcp_log "status denied: scope=$scope"
    graph_depth_policy_log_denial "scope" "ralph_delegate_status" \
      "scope '$scope' may not invoke ralph_delegate_status"
    send_error "$id_present" "$id_raw" "-32602" \
      "ralph_delegate_status is not available in scope: $scope"
    return
  fi

  if ! _graph_delegation_mcp_assert_graph_context 2>/dev/null; then
    send_error "$id_present" "$id_raw" "-32602" \
      "graph node context unavailable"
    return
  fi

  local delegation_id
  delegation_id="$(jq -r '.delegation_id // empty' <<<"$args_json" 2>/dev/null)"
  if [[ -z "$delegation_id" ]]; then
    send_error "$id_present" "$id_raw" "-32602" "delegation_id is required"
    return
  fi
  if ! _graph_delegation_mcp_validate_delegation_id "$delegation_id"; then
    _graph_delegation_mcp_log "status denied: invalid delegation_id=$delegation_id"
    send_error "$id_present" "$id_raw" "-32602" \
      "delegation_id is invalid or contains path traversal characters"
    return
  fi

  local status_json
  set +e
  status_json="$(graph_delegation_ledger_read_status \
    "$WORKSPACE_ROOT" "$RALPH_GRAPH_NAMESPACE" "$RALPH_GRAPH_RUN_ID" \
    "$RALPH_GRAPH_NODE_ID" "$delegation_id" 2>/dev/null)"
  local rc=$?
  set -e

  if [[ $rc -ne 0 || -z "$status_json" ]]; then
    _graph_delegation_mcp_log "status: delegation not found: $delegation_id"
    send_error "$id_present" "$id_raw" "-32602" \
      "delegation not found: $delegation_id"
    return
  fi

  local cur_status
  cur_status="$(jq -r '.status // "unknown"' <<<"$status_json" 2>/dev/null)"
  _graph_delegation_mcp_log "status: delegation=$delegation_id status=$cur_status"

  send_result "$id_present" "$id_raw" \
    "$(_graph_delegation_mcp_ok_result \
      "delegation $delegation_id: $cur_status" \
      "$status_json")"
}

# ---- Handler: ralph_delegate_wait ------------------------------------------

handle_delegate_wait() {
  local args_json="$1"
  local id_present="$2"
  local id_raw="$3"

  local scope="${RALPH_MCP_SCOPE:-operator}"

  if ! _graph_delegation_mcp_scope_allows_broker; then
    _graph_delegation_mcp_log "wait denied: scope=$scope"
    graph_depth_policy_log_denial "scope" "ralph_delegate_wait" \
      "scope '$scope' may not invoke ralph_delegate_wait"
    send_error "$id_present" "$id_raw" "-32602" \
      "ralph_delegate_wait is not available in scope: $scope"
    return
  fi

  if ! _graph_delegation_mcp_assert_graph_context 2>/dev/null; then
    send_error "$id_present" "$id_raw" "-32602" \
      "graph node context unavailable"
    return
  fi

  local delegation_id timeout_seconds
  delegation_id="$(jq -r '.delegation_id // empty' <<<"$args_json" 2>/dev/null)"
  timeout_seconds="$(jq -r '.timeout_seconds // 30' <<<"$args_json" 2>/dev/null)"

  if [[ -z "$delegation_id" ]]; then
    send_error "$id_present" "$id_raw" "-32602" "delegation_id is required"
    return
  fi
  if ! _graph_delegation_mcp_validate_delegation_id "$delegation_id"; then
    _graph_delegation_mcp_log "wait denied: invalid delegation_id=$delegation_id"
    send_error "$id_present" "$id_raw" "-32602" \
      "delegation_id is invalid or contains path traversal characters"
    return
  fi

  # Cap timeout at server maximum
  if [[ ! "$timeout_seconds" =~ ^[0-9]+$ ]]; then
    timeout_seconds="$GRAPH_DELEGATION_MCP_WAIT_MAX_SECONDS"
  fi
  if [[ "$timeout_seconds" -gt "$GRAPH_DELEGATION_MCP_WAIT_MAX_SECONDS" ]]; then
    timeout_seconds="$GRAPH_DELEGATION_MCP_WAIT_MAX_SECONDS"
  fi

  local deadline=$(( $(date +%s) + timeout_seconds ))
  local status_json cur_status

  while true; do
    set +e
    status_json="$(graph_delegation_ledger_read_status \
      "$WORKSPACE_ROOT" "$RALPH_GRAPH_NAMESPACE" "$RALPH_GRAPH_RUN_ID" \
      "$RALPH_GRAPH_NODE_ID" "$delegation_id" 2>/dev/null)"
    local rc=$?
    set -e

    if [[ $rc -ne 0 || -z "$status_json" ]]; then
      send_error "$id_present" "$id_raw" "-32602" \
        "delegation not found: $delegation_id"
      return
    fi

    cur_status="$(jq -r '.status // "unknown"' <<<"$status_json" 2>/dev/null)"

    case "$cur_status" in
      succeeded|failed|cancelled|awaiting-ack)
        _graph_delegation_mcp_log "wait: delegation=$delegation_id terminal status=$cur_status"
        send_result "$id_present" "$id_raw" \
          "$(_graph_delegation_mcp_ok_result \
            "delegation $delegation_id: $cur_status" \
            "$status_json")"
        return
        ;;
    esac

    local now; now="$(date +%s)"
    if [[ "$now" -ge "$deadline" ]]; then
      _graph_delegation_mcp_log "wait: delegation=$delegation_id timed out status=$cur_status"
      local structured
      structured="$(jq -c '. + {timedOut:true}' <<<"$status_json" 2>/dev/null || echo '{}')"
      send_result "$id_present" "$id_raw" \
        "$(_graph_delegation_mcp_ok_result \
          "delegation $delegation_id: still running (timeout after ${timeout_seconds}s)" \
          "$structured")"
      return
    fi

    sleep "$GRAPH_DELEGATION_MCP_WAIT_POLL_INTERVAL"
  done
}

# ---- Handler: ralph_delegate_result ----------------------------------------

handle_delegate_result() {
  local args_json="$1"
  local id_present="$2"
  local id_raw="$3"

  local scope="${RALPH_MCP_SCOPE:-operator}"

  if ! _graph_delegation_mcp_scope_allows_broker; then
    _graph_delegation_mcp_log "result denied: scope=$scope"
    graph_depth_policy_log_denial "scope" "ralph_delegate_result" \
      "scope '$scope' may not invoke ralph_delegate_result"
    send_error "$id_present" "$id_raw" "-32602" \
      "ralph_delegate_result is not available in scope: $scope"
    return
  fi

  if ! _graph_delegation_mcp_assert_graph_context 2>/dev/null; then
    send_error "$id_present" "$id_raw" "-32602" \
      "graph node context unavailable"
    return
  fi

  local delegation_id
  delegation_id="$(jq -r '.delegation_id // empty' <<<"$args_json" 2>/dev/null)"
  if [[ -z "$delegation_id" ]]; then
    send_error "$id_present" "$id_raw" "-32602" "delegation_id is required"
    return
  fi
  if ! _graph_delegation_mcp_validate_delegation_id "$delegation_id"; then
    _graph_delegation_mcp_log "result denied: invalid delegation_id=$delegation_id"
    send_error "$id_present" "$id_raw" "-32602" \
      "delegation_id is invalid or contains path traversal characters"
    return
  fi

  local status_json
  set +e
  status_json="$(graph_delegation_ledger_read_status \
    "$WORKSPACE_ROOT" "$RALPH_GRAPH_NAMESPACE" "$RALPH_GRAPH_RUN_ID" \
    "$RALPH_GRAPH_NODE_ID" "$delegation_id" 2>/dev/null)"
  local rc=$?
  set -e

  if [[ $rc -ne 0 || -z "$status_json" ]]; then
    send_error "$id_present" "$id_raw" "-32602" \
      "delegation not found: $delegation_id"
    return
  fi

  local cur_status
  cur_status="$(jq -r '.status // "unknown"' <<<"$status_json" 2>/dev/null)"

  case "$cur_status" in
    succeeded|failed|cancelled|awaiting-ack) ;;
    *)
      send_error "$id_present" "$id_raw" "-32602" \
        "delegation is not in a terminal state: $cur_status (use ralph_delegate_wait first)"
      return
      ;;
  esac

  # A result read is the durable acknowledgement required before a failed
  # child can stop blocking its parent's TODO completion.
  graph_delegation_ledger_acknowledge "$WORKSPACE_ROOT" "$RALPH_GRAPH_NAMESPACE" \
    "$RALPH_GRAPH_RUN_ID" "$RALPH_GRAPH_NODE_ID" "$delegation_id" "result-read" 2>/dev/null || {
      send_error "$id_present" "$id_raw" "-32000" "failed to record delegation acknowledgement"
      return
    }
  status_json="$(graph_delegation_ledger_read_status "$WORKSPACE_ROOT" "$RALPH_GRAPH_NAMESPACE" "$RALPH_GRAPH_RUN_ID" "$RALPH_GRAPH_NODE_ID" "$delegation_id" 2>/dev/null || printf '%s' "$status_json")"

  _graph_delegation_mcp_log "result: delegation=$delegation_id status=$cur_status"
  send_result "$id_present" "$id_raw" \
    "$(_graph_delegation_mcp_ok_result \
      "delegation $delegation_id result (status=$cur_status)" \
      "$status_json")"
}

# ---- Handler: ralph_delegate_cancel ----------------------------------------

handle_delegate_cancel() {
  local args_json="$1"
  local id_present="$2"
  local id_raw="$3"

  local scope="${RALPH_MCP_SCOPE:-operator}"

  if ! _graph_delegation_mcp_scope_allows_broker; then
    _graph_delegation_mcp_log "cancel denied: scope=$scope"
    graph_depth_policy_log_denial "scope" "ralph_delegate_cancel" \
      "scope '$scope' may not invoke ralph_delegate_cancel"
    send_error "$id_present" "$id_raw" "-32602" \
      "ralph_delegate_cancel is not available in scope: $scope"
    return
  fi

  if ! _graph_delegation_mcp_assert_graph_context 2>/dev/null; then
    send_error "$id_present" "$id_raw" "-32602" \
      "graph node context unavailable"
    return
  fi

  local delegation_id
  delegation_id="$(jq -r '.delegation_id // empty' <<<"$args_json" 2>/dev/null)"
  if [[ -z "$delegation_id" ]]; then
    send_error "$id_present" "$id_raw" "-32602" "delegation_id is required"
    return
  fi
  if ! _graph_delegation_mcp_validate_delegation_id "$delegation_id"; then
    _graph_delegation_mcp_log "cancel denied: invalid delegation_id=$delegation_id"
    send_error "$id_present" "$id_raw" "-32602" \
      "delegation_id is invalid or contains path traversal characters"
    return
  fi

  local status_json cur_status
  set +e
  status_json="$(graph_delegation_ledger_read_status \
    "$WORKSPACE_ROOT" "$RALPH_GRAPH_NAMESPACE" "$RALPH_GRAPH_RUN_ID" \
    "$RALPH_GRAPH_NODE_ID" "$delegation_id" 2>/dev/null)"
  local rc=$?
  set -e

  if [[ $rc -ne 0 || -z "$status_json" ]]; then
    send_error "$id_present" "$id_raw" "-32602" \
      "delegation not found: $delegation_id"
    return
  fi

  cur_status="$(jq -r '.status // "unknown"' <<<"$status_json" 2>/dev/null)"

  # Idempotent: already cancelled is success
  if [[ "$cur_status" == "cancelled" ]]; then
    _graph_delegation_mcp_log "cancel: delegation=$delegation_id already cancelled"
    send_result "$id_present" "$id_raw" \
      "$(_graph_delegation_mcp_ok_result \
        "delegation $delegation_id: already cancelled" \
        "$status_json")"
    return
  fi

  # Cannot cancel a terminal delegation (except cancelled which is handled above)
  case "$cur_status" in
    succeeded|failed|awaiting-ack)
      send_error "$id_present" "$id_raw" "-32602" \
        "delegation is already in terminal state: $cur_status"
      return
      ;;
  esac

  set +e
  graph_delegation_child_cancel \
    "$WORKSPACE_ROOT" "$RALPH_GRAPH_NAMESPACE" "$RALPH_GRAPH_RUN_ID" \
    "$RALPH_GRAPH_NODE_ID" "$delegation_id" \
    2>/dev/null
  rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    send_error "$id_present" "$id_raw" "-32000" \
      "failed to cancel delegation: $delegation_id"
    return
  fi

  _graph_delegation_mcp_log "cancel: delegation=$delegation_id ok"

  local updated_json
  set +e
  updated_json="$(graph_delegation_ledger_read_status \
    "$WORKSPACE_ROOT" "$RALPH_GRAPH_NAMESPACE" "$RALPH_GRAPH_RUN_ID" \
    "$RALPH_GRAPH_NODE_ID" "$delegation_id" 2>/dev/null)"
  set -e
  [[ -n "$updated_json" ]] || updated_json="{\"status\":\"cancelled\"}"

  send_result "$id_present" "$id_raw" \
    "$(_graph_delegation_mcp_ok_result \
      "delegation $delegation_id: cancelled" \
      "$updated_json")"
}
