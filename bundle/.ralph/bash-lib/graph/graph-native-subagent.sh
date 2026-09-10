#!/usr/bin/env bash
# graph-native-subagent.sh - Fail-closed stubs after Ralph-child removal.
#
# Ralph no longer synthesizes native child overlays, portable agent allowlists,
# or prompt contracts. Ambient nativeSubagents: off|inherit is authored on
# agent stages (voters forced off) and enforced by runtime adapters.
#
# Remaining helpers only refuse Ralph-child setup and keep depth-policy
# no-recursion logging when a child scope attempts a native spawn.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

if [[ -n "${GRAPH_NATIVE_SUBAGENT_LOADED:-}" ]]; then
  return 0
fi
GRAPH_NATIVE_SUBAGENT_LOADED=1

_GRAPH_NATIVE_SUBAGENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F graph_depth_policy_log_denial >/dev/null 2>&1; then
  # shellcheck source=graph-depth-policy.sh
  source "$_GRAPH_NATIVE_SUBAGENT_DIR/graph-depth-policy.sh"
fi

_graph_native_subagent_log_file() {
  local workspace="${RALPH_AGENT_WORKSPACE:-${RALPH_PLAN_WORKSPACE_ROOT:-$(pwd)}}"
  local log_dir
  log_dir="${workspace}/.ralph-workspace/logs"
  mkdir -p "$log_dir" 2>/dev/null || true
  printf '%s/native-readonly.log' "$log_dir"
}

graph_native_subagent_log() {
  local msg="[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] graph-native-subagent: $*"
  local log_file
  log_file="$(_graph_native_subagent_log_file)"
  printf '%s\n' "$msg" >> "$log_file" 2>/dev/null || true
}

# Ralph-controlled native children were removed; no runtime is Ralph-child proven.
graph_native_subagent_runtime_supported() {
  local runtime="${1:-}"
  if [[ -z "$runtime" ]]; then
    echo "Error: graph_native_subagent_runtime_supported requires a runtime argument" >&2
    return 1
  fi
  graph_native_subagent_log "runtime_supported: Ralph-child native overlays removed; refusing runtime=$runtime"
  echo "Error: Ralph-controlled native child overlays were removed; use nativeSubagents: off|inherit on agent stages (runtime adapters enforce off)" >&2
  return 1
}

# Portable allowlists were removed with Ralph-child overlays.
graph_native_subagent_is_allowed_role() {
  return 1
}

graph_native_subagent_validate_agents() {
  echo "Error: Ralph-controlled native child agent allowlists were removed; use nativeSubagents: off|inherit on agent stages" >&2
  return 1
}

graph_native_subagent_child_tools() {
  echo "Error: Ralph-controlled native child tool surfaces were removed" >&2
  return 1
}

graph_native_subagent_generate_child_overlay() {
  echo "Error: Ralph-controlled native child overlays were removed; no overlay is written" >&2
  return 1
}

graph_native_subagent_prompt_contract() {
  # No Ralph-child prompt contract. Emit nothing.
  return 0
}

# graph_native_subagent_setup
# Always fails closed. Child scopes still hit depth-policy first so
# no-recursion.log records the denial. Never writes overlay artifacts or ledger.
graph_native_subagent_setup() {
  local delegation_json="${1:-}"
  local runtime="${2:-}"
  local workspace="${3:-}"
  local node_id="${4:-}"
  local out_overlay_dir="${5:-}"

  if [[ -z "$delegation_json" || -z "$runtime" || -z "$workspace" || -z "$node_id" || -z "$out_overlay_dir" ]]; then
    echo "Error: graph_native_subagent_setup requires delegation_json, runtime, workspace, node_id, and out_overlay_dir" >&2
    return 1
  fi

  if ! graph_depth_policy_enforce_native_spawn "$runtime" "native-subagent-spawn" 2>/dev/null; then
    local _scope="${RALPH_MCP_SCOPE:-unknown}"
    echo "Error: native subagent spawn is not permitted from scope '$_scope' (runtime=$runtime)" >&2
    return 1
  fi

  graph_native_subagent_log "setup refused: Ralph-child overlays removed node=$node_id runtime=$runtime"
  echo "Error: Ralph-controlled native child overlays were removed; refusing setup for node '$node_id' (use nativeSubagents: off|inherit on agent stages)" >&2
  return 1
}

graph_native_subagent_collect_failure_evidence() {
  # No Ralph-child artifact/ledger to scan.
  return 1
}

# Legacy delegation.native env injection always resolves to off.
graph_native_subagent_env_from_delegation() {
  RALPH_PLAN_NATIVE_SUBAGENT_MODE="off"
  export RALPH_PLAN_NATIVE_SUBAGENT_MODE
  unset RALPH_PLAN_NATIVE_SUBAGENT_RUNTIME || true
  graph_native_subagent_log "env_from_delegation: Ralph-child removed; mode=off"
  return 0
}
