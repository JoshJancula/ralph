#!/usr/bin/env bash
# graph-native-subagent.sh - Ralph-controlled native read-only subagent support.
#
# This library implements the native read-only subagent feature for graph nodes
# whose delegation policy sets native.mode = read-only. It is fail-closed: only
# runtimes with passing capability probes are supported, and only bounded
# read-only roles are permitted as child agents.
#
# Supported runtimes: claude (PROVEN for enable/disable; enforcement is prompt-
# and overlay-based since per-child tool restriction is not proven at the API level)
#
# Allowed child roles: research, code-review, log-analysis, explorer
#
# These roles are bounded and do not have recursive delegation. Child overlays
# are written to the workspace scratch directory; the parent's system prompt
# receives the prompt contract. Children cannot:
#   - Mark Ralph TODOs complete
#   - Edit plan files
#   - Emit authoritative verification
#   - Satisfy required artifacts directly
#   - Spawn their own native children
#   - Invoke cross-runtime delegation
#
# Log file: .ralph-workspace/logs/native-readonly.log

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

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Runtimes with passing capability probes. Updated when a new runtime passes
# all four probes (enable, disable, read-only, no-recursion). See DELEGATION.md.
readonly GRAPH_NATIVE_SUBAGENT_SUPPORTED_RUNTIMES="claude"

# Allowed child agent roles for native read-only mode.
# These roles are bounded: no edits, no writes, no subagent spawning.
# Expanding this list requires a capability proof for the new role.
readonly GRAPH_NATIVE_SUBAGENT_ALLOWED_ROLES="research code-review log-analysis explorer"

# Child tool surface for each supported runtime (read-only; no Agent).
# The overlay generator uses these when writing child agent definitions.
readonly GRAPH_NATIVE_SUBAGENT_CHILD_TOOLS_CLAUDE="Read,Grep,Glob"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Runtime capability check
# ---------------------------------------------------------------------------

# graph_native_subagent_runtime_supported <runtime>
# Returns 0 only when the runtime is in the PROVEN set. Fail-closed: unknown
# runtimes always fail. This check must run before model invocation.
graph_native_subagent_runtime_supported() {
  local runtime="${1:-}"
  if [[ -z "$runtime" ]]; then
    graph_native_subagent_log "ERROR: runtime_supported called with empty runtime"
    echo "Error: graph_native_subagent_runtime_supported requires a runtime argument" >&2
    return 1
  fi
  local r
  for r in $GRAPH_NATIVE_SUBAGENT_SUPPORTED_RUNTIMES; do
    if [[ "$r" == "$runtime" ]]; then
      graph_native_subagent_log "runtime_supported: $runtime is PROVEN"
      return 0
    fi
  done
  graph_native_subagent_log "ERROR: runtime_supported: $runtime is not in the PROVEN set; refusing"
  echo "Error: native read-only subagent mode is not supported for runtime '$runtime'; only ${GRAPH_NATIVE_SUBAGENT_SUPPORTED_RUNTIMES} is proven" >&2
  return 1
}

# ---------------------------------------------------------------------------
# Role validation
# ---------------------------------------------------------------------------

# graph_native_subagent_is_allowed_role <agent_name>
# Returns 0 when the agent is in the allowed read-only role set.
graph_native_subagent_is_allowed_role() {
  local agent="${1:-}"
  local r
  for r in $GRAPH_NATIVE_SUBAGENT_ALLOWED_ROLES; do
    [[ "$r" == "$agent" ]] && return 0
  done
  return 1
}

# graph_native_subagent_validate_agents <agent> [<agent> ...]
# Rejects any agent not in the allowed read-only role set.
graph_native_subagent_validate_agents() {
  if [[ $# -eq 0 ]]; then
    graph_native_subagent_log "ERROR: validate_agents called with no agents"
    echo "Error: graph_native_subagent_validate_agents requires at least one agent name" >&2
    return 1
  fi
  local agent
  for agent in "$@"; do
    if ! graph_native_subagent_is_allowed_role "$agent"; then
      graph_native_subagent_log "ERROR: validate_agents: '$agent' is not an allowed read-only role (allowed: ${GRAPH_NATIVE_SUBAGENT_ALLOWED_ROLES})"
      echo "Error: agent '$agent' is not an allowed read-only role for native subagents; allowed roles: ${GRAPH_NATIVE_SUBAGENT_ALLOWED_ROLES}" >&2
      return 1
    fi
    graph_native_subagent_log "validate_agents: '$agent' accepted"
  done
  return 0
}

# ---------------------------------------------------------------------------
# Child agent overlay generation
# ---------------------------------------------------------------------------

# graph_native_subagent_child_tools <runtime>
# Returns the CSV tool list for child agents of the given runtime.
graph_native_subagent_child_tools() {
  local runtime="${1:-}"
  case "$runtime" in
    claude) printf '%s' "$GRAPH_NATIVE_SUBAGENT_CHILD_TOOLS_CLAUDE" ;;
    *)
      echo "Error: no child tool surface defined for runtime '$runtime'" >&2
      return 1
      ;;
  esac
}

# graph_native_subagent_generate_child_overlay <agent_name> <runtime> <out_path>
# Writes a restricted child agent definition to <out_path>.
# The definition includes only read-only tools and no Agent tool, so a child
# spawned with this definition cannot write, edit, or spawn grandchildren.
# The prompt contract is embedded in the definition body.
graph_native_subagent_generate_child_overlay() {
  local agent_name="${1:-}"
  local runtime="${2:-}"
  local out_path="${3:-}"

  if [[ -z "$agent_name" || -z "$runtime" || -z "$out_path" ]]; then
    echo "Error: graph_native_subagent_generate_child_overlay requires agent_name, runtime, and out_path" >&2
    return 1
  fi

  local tools
  if ! tools="$(graph_native_subagent_child_tools "$runtime")"; then
    return 1
  fi

  local out_dir
  out_dir="$(dirname "$out_path")"
  if ! mkdir -p "$out_dir"; then
    echo "Error: failed to create overlay directory: $out_dir" >&2
    return 1
  fi

  # Build YAML tools list from CSV
  local tools_yaml=""
  local IFS_SAVE="$IFS"
  IFS=','
  local t
  for t in $tools; do
    tools_yaml+="  - ${t}"$'\n'
  done
  IFS="$IFS_SAVE"

  # Write the overlay definition
  cat > "$out_path" <<OVERLAY
---
name: ${agent_name}
description: >-
  Ralph-controlled read-only child overlay for native subagent delegation.
  This overlay restricts the agent to read-only tools only.
tools:
${tools_yaml}---

## Ralph Native Subagent Read-Only Contract

This agent definition is a Ralph-controlled overlay. The following restrictions apply and cannot be overridden:

- Use only ${tools} tools. Do not attempt Edit, Write, Bash, or any mutating operation.
- Do not spawn sub-agents (no Agent tool, no Task tool, no delegation).
- Do not mark Ralph TODOs complete (do not emit TODO_COMPLETION or AGENT_INVOCATION_COMPLETE).
- Do not edit, create, or remove plan files (.plan.md, .orch.json, .graph.json).
- Do not emit authoritative verification results. Only the parent can verify.
- Do not write to required output artifacts directly. Return findings to the parent.
- If a task requires writing, editing, or running commands, return the information you found and let the parent perform the action.

## Role: ${agent_name}

Explore and analyze read-only. Return structured findings to the calling parent node.
Report failures with evidence so the parent can handle them; do not silently succeed.

## On Failure

If you cannot complete the assigned task, return:
- What you attempted
- What failed and why (error messages, missing files, access denied)
- What partial results are available

Do not terminate as success if the task is incomplete.
OVERLAY

  graph_native_subagent_log "generate_child_overlay: wrote $runtime overlay for '$agent_name' to $out_path (tools: $tools)"
  return 0
}

# ---------------------------------------------------------------------------
# Prompt contract
# ---------------------------------------------------------------------------

# graph_native_subagent_prompt_contract <node_id> <allowed_agents_csv>
# Outputs the stable prompt contract to inject into the parent's system prompt.
# The contract tells the parent what children can and cannot do.
graph_native_subagent_prompt_contract() {
  local node_id="${1:-}"
  local allowed_agents_csv="${2:-}"

  cat <<CONTRACT

## Native Subagent Contract (node: ${node_id})

This node is configured for native read-only subagent delegation. When invoking
child agents, the following contract is in effect and cannot be overridden.

### Allowed child roles
${allowed_agents_csv:-research, code-review, log-analysis, explorer}

### Child capabilities (read-only only)
Children may: Read, Grep, Glob files and return findings.
Children must NOT:
- Edit, write, or delete any file
- Run shell commands that mutate state
- Mark Ralph TODOs complete (no TODO_COMPLETION, no AGENT_INVOCATION_COMPLETE)
- Edit, create, or remove plan files (.plan.md, .orch.json, .graph.json)
- Emit authoritative verification (only this parent node may verify)
- Satisfy required output artifacts directly
- Spawn their own sub-agents (no Agent tool, no Task tool, no delegation)
- Invoke cross-runtime delegation

### Parent responsibilities
1. Dispatch children for read-only research and analysis only.
2. Wait for child results before proceeding.
3. Synthesize child findings yourself; do not delegate synthesis.
4. Perform all writes, edits, and mutations yourself.
5. Run verification yourself; children cannot satisfy verification requirements.
6. If a child fails, collect its evidence and handle the failure; do not mark the
   node complete based on a failed or partial child result.

### Child failure handling
When a child agent returns an error or incomplete result, treat it as evidence
to incorporate, not as a terminal failure of this node. Log the evidence and
continue with what you have, or return a partial result with the failure noted.
CONTRACT
}

# ---------------------------------------------------------------------------
# Setup (top-level orchestration)
# ---------------------------------------------------------------------------

# graph_native_subagent_setup <delegation_json> <runtime> <workspace> <node_id> <out_overlay_dir>
#
# Validates that native read-only subagents are permissible, generates child
# overlays for each declared agent, and outputs the prompt contract on stdout.
#
# Callers should capture stdout as the contract text and append it to PROMPT_STATIC.
# The <out_overlay_dir> receives one overlay file per declared agent.
#
# Returns 1 and emits an error to stderr when:
#   - the runtime is not supported
#   - any declared agent is not an allowed read-only role
#   - overlay generation fails
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

  # Layer 3+4: native-spawn depth enforcement — fail before model invocation when
  # the calling scope is a child scope. A native subagent cannot itself spawn a
  # native subagent or invoke the delegation broker.
  if ! graph_depth_policy_enforce_native_spawn "$runtime" "native-subagent-spawn" 2>/dev/null; then
    local _scope="${RALPH_MCP_SCOPE:-unknown}"
    echo "Error: native subagent spawn is not permitted from scope '$_scope' (runtime=$runtime)" >&2
    return 1
  fi

  # Fail before model invocation when runtime is not supported
  if ! graph_native_subagent_runtime_supported "$runtime"; then
    return 1
  fi

  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required for graph_native_subagent_setup" >&2
    return 1
  fi

  # Extract allowedAgents from the delegation JSON
  local allowed_agents_raw
  allowed_agents_raw="$(printf '%s' "$delegation_json" | jq -r '(.native.allowedAgents // []) | .[]' 2>/dev/null)" || {
    echo "Error: failed to parse delegation JSON" >&2
    return 1
  }

  # Validate and generate overlays
  local -a agent_list=()
  local agent
  while IFS= read -r agent; do
    [[ -z "$agent" ]] && continue
    agent_list+=("$agent")
  done <<< "$allowed_agents_raw"

  if [[ ${#agent_list[@]} -eq 0 ]]; then
    graph_native_subagent_log "setup: node=$node_id no allowedAgents declared; no overlays generated"
  else
    if ! graph_native_subagent_validate_agents "${agent_list[@]}"; then
      return 1
    fi

    mkdir -p "$out_overlay_dir" || {
      echo "Error: failed to create overlay output directory: $out_overlay_dir" >&2
      return 1
    }

    for agent in "${agent_list[@]}"; do
      local overlay_path="${out_overlay_dir}/${agent}.md"
      if ! graph_native_subagent_generate_child_overlay "$agent" "$runtime" "$overlay_path"; then
        return 1
      fi
    done
  fi

  # Build allowed agents CSV for the contract
  local agents_csv
  agents_csv="$(printf '%s' "$allowed_agents_raw" | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')"

  # Output the prompt contract (callers append this to PROMPT_STATIC)
  graph_native_subagent_prompt_contract "$node_id" "$agents_csv"

  graph_native_subagent_log "setup: node=$node_id runtime=$runtime overlays=${#agent_list[@]} agents=${agents_csv:-none}"
  return 0
}

# ---------------------------------------------------------------------------
# Failure evidence collection
# ---------------------------------------------------------------------------

# graph_native_subagent_collect_failure_evidence <attempt_id> <workspace> [<log_path>]
#
# Scans the workspace for child output files and failure indicators from the
# given attempt. Writes a structured evidence summary to <log_path> (defaults to
# native-readonly.log). Returns 0 when evidence was found, 1 when nothing was
# located.
#
# This is called by the parent dispatcher when a child node exits non-zero so
# the failure is treated as evidence rather than a terminal node failure.
graph_native_subagent_collect_failure_evidence() {
  local attempt_id="${1:-}"
  local workspace="${2:-}"
  local log_path="${3:-}"

  if [[ -z "$attempt_id" || -z "$workspace" ]]; then
    echo "Error: graph_native_subagent_collect_failure_evidence requires attempt_id and workspace" >&2
    return 1
  fi

  if [[ -z "$log_path" ]]; then
    log_path="$(_graph_native_subagent_log_file)"
  fi

  local evidence_found=0
  local evidence_dir="${workspace}/.ralph-workspace/artifacts"
  local timestamp
  timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  {
    printf '[%s] CHILD FAILURE EVIDENCE: attempt_id=%s\n' "$timestamp" "$attempt_id"

    # Look for a StageOutcomeReport for this attempt
    local report_file
    if report_file="$(find "$evidence_dir" -name "${attempt_id}.json" 2>/dev/null | head -1)" && [[ -n "$report_file" ]]; then
      printf '  report_file: %s\n' "$report_file"
      if command -v jq >/dev/null 2>&1; then
        local outcome exit_code
        outcome="$(jq -r '.outcome // "unknown"' "$report_file" 2>/dev/null)"
        exit_code="$(jq -r '.exitCode // "unknown"' "$report_file" 2>/dev/null)"
        printf '  outcome: %s  exit_code: %s\n' "$outcome" "$exit_code"
      fi
      evidence_found=1
    fi

    # Look for output logs containing failure indicators
    local log_file
    for log_file in \
      "${workspace}/.ralph-workspace/logs/output-${attempt_id}.log" \
      "${workspace}/.ralph-workspace/logs/output.log"; do
      if [[ -f "$log_file" ]]; then
        printf '  output_log: %s\n' "$log_file"
        # Emit the last 20 lines as evidence
        if [[ -s "$log_file" ]]; then
          printf '  --- last 20 lines ---\n'
          tail -n 20 "$log_file" | while IFS= read -r line; do
            printf '  | %s\n' "$line"
          done
          printf '  --- end evidence ---\n'
        fi
        evidence_found=1
        break
      fi
    done

    if [[ "$evidence_found" -eq 0 ]]; then
      printf '  no evidence files found for attempt_id=%s\n' "$attempt_id"
    fi
  } >> "$log_path" 2>/dev/null

  return $((1 - evidence_found))
}

# ---------------------------------------------------------------------------
# Env variable injection (for invoke path integration)
# ---------------------------------------------------------------------------

# graph_native_subagent_env_from_delegation <delegation_json> <runtime>
#
# Sets and exports RALPH_PLAN_NATIVE_SUBAGENT_MODE and
# RALPH_PLAN_NATIVE_SUBAGENT_RUNTIME from a resolved delegation JSON object.
# Callers (e.g. graph_dispatch_run_node wrappers) call this before the child
# orchestrator.sh invocation so the invoke helper can inject the contract.
#
# Emits "off" when the native mode is off or the runtime is unsupported.
graph_native_subagent_env_from_delegation() {
  local delegation_json="${1:-}"
  local runtime="${2:-}"

  if [[ -z "$delegation_json" ]]; then
    RALPH_PLAN_NATIVE_SUBAGENT_MODE="off"
    export RALPH_PLAN_NATIVE_SUBAGENT_MODE
    return 0
  fi

  local native_mode="off"
  if command -v jq >/dev/null 2>&1; then
    native_mode="$(printf '%s' "$delegation_json" | jq -r '.native.mode // "off"' 2>/dev/null)" || native_mode="off"
  fi

  if [[ "$native_mode" == "read-only" ]] && graph_native_subagent_runtime_supported "$runtime" 2>/dev/null; then
    RALPH_PLAN_NATIVE_SUBAGENT_MODE="read-only"
    RALPH_PLAN_NATIVE_SUBAGENT_RUNTIME="$runtime"
    export RALPH_PLAN_NATIVE_SUBAGENT_MODE RALPH_PLAN_NATIVE_SUBAGENT_RUNTIME
    graph_native_subagent_log "env_from_delegation: native_mode=read-only runtime=$runtime"
  else
    RALPH_PLAN_NATIVE_SUBAGENT_MODE="off"
    export RALPH_PLAN_NATIVE_SUBAGENT_MODE
    graph_native_subagent_log "env_from_delegation: native_mode=$native_mode runtime=$runtime -> off"
  fi
  return 0
}
