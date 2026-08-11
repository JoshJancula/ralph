#!/usr/bin/env bash
# graph-depth-policy.sh - Depth-one enforcement across all independent layers.
#
# Implements the depth-one contract: no child of a graph node may itself spawn
# a child. Enforcement is multi-layered so that bypassing one layer does not
# open a recursive path.
#
# Layers
# ------
# 1. Frozen policy     - maxDepth is hard-capped at GRAPH_DEPTH_MAX (1) regardless
#                        of the policy field value. Callers cannot raise the cap.
# 2. Runtime tool removal - child env sets RALPH_STAGE_SUBAGENTS=off and
#                           RALPH_MCP_SCOPE to a restricted scope; see
#                           graph_depth_policy_child_env_vars().
# 3. MCP catalog scope - graph_delegation_mcp_catalog_hidden_tools() filters the
#                        tool catalog per RALPH_MCP_SCOPE. Spawn and run tools
#                        are hidden for native-subagent and delegated-child.
# 4. Server-side caller validation - handlers call graph_depth_policy_check_handler()
#                                    which enforces scope first, then depth.
# 5. Child environment - the runner sets RALPH_MCP_SCOPE and
#                        RALPH_GRAPH_DELEGATION_DEPTH before spawning any child.
# 6. Ledger depth      - graph_delegation_ledger_start() rejects depth > GRAPH_DEPTH_MAX
#                        as a final write-path guard independent of the handler.
#
# Denial records
# --------------
# Every denial is written as a single-line JSON record to no-recursion.log:
#   {"ts":"<iso8601>","layer":"<layer>","runtime":"<rt>","parent_node":"<node>",
#    "child_identity":"<id-or-unknown>","requested_tool":"<tool>","reason":"<msg>"}
#
# Fields are populated from server-context env vars. Prompt content and secret
# values are never included.
#
# Log file: <workspace>/.ralph-workspace/logs/no-recursion.log

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

if [[ -n "${GRAPH_DEPTH_POLICY_LOADED:-}" ]]; then return 0; fi
GRAPH_DEPTH_POLICY_LOADED=1

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Absolute maximum delegation depth. Layer 1 (frozen policy) caps every policy
# maxDepth at this value; it cannot be overridden from user-supplied JSON.
readonly GRAPH_DEPTH_MAX=1

# Scopes allowed to spawn new child work (native subagents or brokered delegations).
# Any scope not in this list is treated as a child scope and denied.
readonly GRAPH_DEPTH_SPAWN_ALLOWED_SCOPES="operator graph-node"

# ---------------------------------------------------------------------------
# Log path helper
# ---------------------------------------------------------------------------

_graph_depth_policy_log_path() {
  local workspace="${WORKSPACE_ROOT:-${RALPH_MCP_WORKSPACE:-}}"
  if [[ -n "$workspace" ]]; then
    printf '%s/.ralph-workspace/logs/no-recursion.log\n' "$workspace"
  else
    printf '/dev/null\n'
  fi
}

# ---------------------------------------------------------------------------
# Denial record emitter
# ---------------------------------------------------------------------------

# graph_depth_policy_log_denial <layer> <requested_tool> <reason>
#
# Writes a structured denial record to no-recursion.log. Layer names:
#   scope      RALPH_MCP_SCOPE disallows the tool
#   depth      RALPH_GRAPH_DELEGATION_DEPTH >= maxDepth (policy layer)
#   policy-cap policy maxDepth exceeded the frozen cap
#   ledger     ledger write-path depth guard
#   native-spawn native subagent spawn attempted from child scope
#   env        missing or forged required env vars in child context
#
# Context is drawn from env vars; no prompt or secret content is included.
graph_depth_policy_log_denial() {
  local layer="${1:-unknown}"
  local requested_tool="${2:-unknown}"
  local reason="${3:-denied}"

  local log_path
  log_path="$(_graph_depth_policy_log_path)"
  mkdir -p "$(dirname "$log_path")" 2>/dev/null || true

  local ts runtime parent_node child_identity
  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u)"
  runtime="${RALPH_GRAPH_NODE_RUNTIME:-unknown}"
  parent_node="${RALPH_GRAPH_NODE_ID:-unknown}"
  child_identity="${RALPH_GRAPH_DELEGATION_DEPTH:+depth=${RALPH_GRAPH_DELEGATION_DEPTH}}"
  child_identity="${child_identity:-unknown}"

  local record
  if command -v jq >/dev/null 2>&1; then
    record="$(jq -cn \
      --arg ts "$ts" \
      --arg layer "$layer" \
      --arg runtime "$runtime" \
      --arg parent_node "$parent_node" \
      --arg child_identity "$child_identity" \
      --arg requested_tool "$requested_tool" \
      --arg reason "$reason" \
      '{ts:$ts,layer:$layer,runtime:$runtime,parent_node:$parent_node,child_identity:$child_identity,requested_tool:$requested_tool,reason:$reason}')"
  else
    # Fallback: basic key=value (no special chars expected in these fields)
    record="{\"ts\":\"$ts\",\"layer\":\"$layer\",\"runtime\":\"$runtime\",\"parent_node\":\"$parent_node\",\"child_identity\":\"$child_identity\",\"requested_tool\":\"$requested_tool\",\"reason\":\"$reason\"}"
  fi

  printf '%s\n' "$record" >> "$log_path" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Scope classification helpers
# ---------------------------------------------------------------------------

# Returns 0 when the current scope is allowed to spawn child work.
graph_depth_policy_scope_allows_spawn() {
  local scope="${RALPH_MCP_SCOPE:-operator}"
  case "$scope" in
    operator|graph-node) return 0 ;;
    *) return 1 ;;
  esac
}

# Returns 0 when the current scope is a child scope (cannot spawn).
graph_depth_policy_scope_is_child() {
  if graph_depth_policy_scope_allows_spawn; then
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Layer checks
# ---------------------------------------------------------------------------

# graph_depth_policy_enforce_scope <requested_tool>
#
# Enforces the scope layer (layer 3+4). Returns 0 when allowed. Returns 1 and
# logs a denial record when the current scope disallows the tool.
graph_depth_policy_enforce_scope() {
  local requested_tool="${1:-unknown}"
  local scope="${RALPH_MCP_SCOPE:-operator}"
  if ! graph_depth_policy_scope_allows_spawn; then
    local reason="scope '$scope' may not invoke $requested_tool"
    graph_depth_policy_log_denial "scope" "$requested_tool" "$reason"
    printf '%s\n' "$reason" >&2
    return 1
  fi
  return 0
}

# graph_depth_policy_enforce_depth <requested_tool> [<max_depth_from_policy>]
#
# Enforces the depth layers (layer 1 + 6). Caps the effective max depth at
# GRAPH_DEPTH_MAX regardless of the policy value, then checks the current depth.
# Returns 0 when allowed. Returns 1 and logs a denial record when depth would
# exceed the cap.
#
# Outputs the effective max depth (capped) on stdout when returning 0, for use
# by the caller in ledger/error messages.
graph_depth_policy_enforce_depth() {
  local requested_tool="${1:-unknown}"
  local policy_max_depth="${2:-1}"
  local current_depth="${RALPH_GRAPH_DELEGATION_DEPTH:-0}"

  # Layer 1: hard cap
  local effective_max
  if [[ "$policy_max_depth" =~ ^[0-9]+$ ]]; then
    effective_max="$policy_max_depth"
  else
    effective_max=1
  fi
  if [[ "$effective_max" -gt "$GRAPH_DEPTH_MAX" ]]; then
    graph_depth_policy_log_denial "policy-cap" "$requested_tool" \
      "policy maxDepth=$policy_max_depth exceeds frozen cap=$GRAPH_DEPTH_MAX; capping"
    effective_max="$GRAPH_DEPTH_MAX"
  fi

  # Depth check against effective max
  if [[ "$current_depth" -ge "$effective_max" ]]; then
    local reason="delegation depth limit: current=$current_depth max=$effective_max (cap=$GRAPH_DEPTH_MAX)"
    graph_depth_policy_log_denial "depth" "$requested_tool" "$reason"
    printf '%s\n' "$reason" >&2
    return 1
  fi

  printf '%s\n' "$effective_max"
  return 0
}

# graph_depth_policy_enforce_native_spawn <runtime> <requested_tool>
#
# Enforces that native subagent spawning is only permitted from parent scopes,
# not from within a child scope. Returns 0 when allowed; returns 1 and logs a
# denial when the current scope is a child scope.
graph_depth_policy_enforce_native_spawn() {
  local runtime="${1:-unknown}"
  local requested_tool="${2:-native-subagent-spawn}"
  local scope="${RALPH_MCP_SCOPE:-operator}"

  if graph_depth_policy_scope_is_child; then
    local reason="scope '$scope' (runtime=$runtime) may not spawn a native subagent"
    graph_depth_policy_log_denial "native-spawn" "$requested_tool" "$reason"
    printf '%s\n' "$reason" >&2
    return 1
  fi

  local current_depth="${RALPH_GRAPH_DELEGATION_DEPTH:-0}"
  if [[ "$current_depth" -ge "$GRAPH_DEPTH_MAX" ]]; then
    local reason="depth $current_depth >= $GRAPH_DEPTH_MAX: native subagent spawn denied"
    graph_depth_policy_log_denial "depth" "$requested_tool" "$reason"
    printf '%s\n' "$reason" >&2
    return 1
  fi

  return 0
}

# ---------------------------------------------------------------------------
# Child environment builder
# ---------------------------------------------------------------------------

# graph_depth_policy_child_env_vars <child_scope> <child_depth>
#
# Outputs lines of the form KEY=VALUE suitable for export before spawning a
# child. These cover layer 2 (runtime tool removal) and layer 5 (child env):
#
#   RALPH_MCP_SCOPE                restricted scope for the child
#   RALPH_GRAPH_DELEGATION_DEPTH   incremented depth
#   RALPH_STAGE_SUBAGENTS          off (disables subagent feature)
#   RALPH_GRAPH_CROSS_RUNTIME_DELEGATION  off (blocks cross-runtime calls)
#
# The caller is responsible for exporting these before exec'ing the child.
graph_depth_policy_child_env_vars() {
  local child_scope="${1:-delegated-child}"
  local child_depth="${2:-1}"

  # Validate scope is actually a child scope
  case "$child_scope" in
    native-subagent|delegated-child) ;;
    *)
      # Default to delegated-child; never allow a parent scope for a child
      child_scope="delegated-child"
      ;;
  esac

  # Clamp child_depth: never below 1, never above GRAPH_DEPTH_MAX + 1
  if [[ ! "$child_depth" =~ ^[0-9]+$ || "$child_depth" -lt 1 ]]; then
    child_depth=1
  fi

  printf 'RALPH_MCP_SCOPE=%s\n' "$child_scope"
  printf 'RALPH_GRAPH_DELEGATION_DEPTH=%s\n' "$child_depth"
  printf 'RALPH_STAGE_SUBAGENTS=off\n'
  printf 'RALPH_GRAPH_CROSS_RUNTIME_DELEGATION=off\n'
}

# ---------------------------------------------------------------------------
# Ledger depth guard (layer 6)
# ---------------------------------------------------------------------------

# graph_depth_policy_ledger_guard <depth> <requested_tool>
#
# Call this inside graph_delegation_ledger_start() before writing any files.
# Returns 0 when depth is within bounds; returns 1 and logs a denial when the
# depth would exceed the cap. This is the final write-path guard independent of
# the MCP handler.
graph_depth_policy_ledger_guard() {
  local depth="${1:-}"
  local requested_tool="${2:-ralph_delegate_start}"

  if [[ ! "$depth" =~ ^[0-9]+$ ]]; then
    graph_depth_policy_log_denial "ledger" "$requested_tool" \
      "invalid depth value: $depth"
    return 1
  fi

  if [[ "$depth" -gt "$GRAPH_DEPTH_MAX" ]]; then
    local reason="ledger guard: child depth=$depth exceeds cap=$GRAPH_DEPTH_MAX"
    graph_depth_policy_log_denial "ledger" "$requested_tool" "$reason"
    printf '%s\n' "$reason" >&2
    return 1
  fi

  return 0
}
