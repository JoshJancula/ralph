#!/usr/bin/env bash
# Out-of-process graph scheduler shell.
#
# Sources graph-dispatch.sh and maintains a bash 3.2-safe in-memory index of
# .graph.json (parallel indexed arrays + id->index map). Every node still runs
# as a fresh orchestrator.sh --single-stage process. The child reaper and the
# Kahn ready-set scheduling loop live in this file as centralized helpers.
# Global and per-runtime concurrency caps (plus subagents=on reservation) and
# failurePolicy drain/cancel semantics live here.
# Do not route work through the in-process orch loop.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

GRAPH_SCHEDULE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -F graph_dispatch_run_node >/dev/null 2>&1; then
  # shellcheck source=graph-dispatch.sh
  source "$GRAPH_SCHEDULE_SCRIPT_DIR/graph-dispatch.sh"
fi

# Process-group / tree teardown used by failurePolicy=cancel. Child orchestrators
# convert SIGTERM into StageOutcomeReport outcome=cancelled via their EXIT trap,
# which also calls ralph_process_run_close.
if ! declare -F ralph_kill_process_group >/dev/null 2>&1; then
  # shellcheck source=../ralph-process-teardown.sh
  source "$GRAPH_SCHEDULE_SCRIPT_DIR/../ralph-process-teardown.sh"
fi
if ! declare -F ralph_process_run_close >/dev/null 2>&1; then
  # shellcheck source=../ralph-process-supervisor.sh
  source "$GRAPH_SCHEDULE_SCRIPT_DIR/../ralph-process-supervisor.sh"
fi
if ! declare -F graph_state_write_node >/dev/null 2>&1; then
  # shellcheck source=graph-state.sh
  source "$GRAPH_SCHEDULE_SCRIPT_DIR/graph-state.sh"
fi
if ! declare -F graph_workspace_prepare_node >/dev/null 2>&1; then
  # shellcheck source=graph-workspace-manager.sh
  source "$GRAPH_SCHEDULE_SCRIPT_DIR/graph-workspace-manager.sh"
fi
if ! declare -F graph_changeset_capture_node >/dev/null 2>&1; then
  # shellcheck source=graph-changeset.sh
  source "$GRAPH_SCHEDULE_SCRIPT_DIR/graph-changeset.sh"
fi
if ! declare -F graph_integration_run >/dev/null 2>&1; then
  # shellcheck source=graph-integration.sh
  source "$GRAPH_SCHEDULE_SCRIPT_DIR/graph-integration.sh"
fi
if ! declare -F graph_gate_run >/dev/null 2>&1; then
  # shellcheck source=graph-gate.sh
  source "$GRAPH_SCHEDULE_SCRIPT_DIR/graph-gate.sh"
fi
if ! declare -F graph_composite_success_validate >/dev/null 2>&1; then
  # shellcheck source=graph-composite-success.sh
  source "$GRAPH_SCHEDULE_SCRIPT_DIR/graph-composite-success.sh"
fi
if ! declare -F graph_delegation_queue_admit_one >/dev/null 2>&1; then
  # shellcheck source=graph-delegation-queue.sh
  source "$GRAPH_SCHEDULE_SCRIPT_DIR/graph-delegation-queue.sh"
fi
if ! declare -F graph_delegation_child_run >/dev/null 2>&1; then
  # shellcheck source=graph-delegation-runner.sh
  source "$GRAPH_SCHEDULE_SCRIPT_DIR/graph-delegation-runner.sh"
fi
if ! declare -F graph_runtime_same_runtime_parallel_safe >/dev/null 2>&1; then
  # shellcheck source=graph-runtime-capabilities.sh
  source "$GRAPH_SCHEDULE_SCRIPT_DIR/graph-runtime-capabilities.sh"
fi
if ! declare -F plan_pipeline_graph_json >/dev/null 2>&1; then
  # shellcheck source=../plan-todo.sh
  source "$GRAPH_SCHEDULE_SCRIPT_DIR/../plan-todo.sh"
fi
# consensus-barrier nodes are dispatched synchronously in-process (see
# _graph_schedule_handle_consensus_barrier_node) rather than as an
# orchestrator subprocess; graph_consensus_run_join lives here.
if ! declare -F graph_consensus_run_join >/dev/null 2>&1; then
  # shellcheck source=graph-consensus.sh
  source "$GRAPH_SCHEDULE_SCRIPT_DIR/graph-consensus.sh"
fi

# Successor lists are stored as a single delimited string per node (bash 3.2
# has no array-of-arrays). Node ids that contain this delimiter are rejected
# at load so splitting remains unambiguous.
GRAPH_SUCCESSOR_DELIM='|'

# Parallel indexed arrays (index N describes one node). Populated by
# graph_schedule_load_index. No associative arrays / namerefs.
GRAPH_NODE_IDS=()
GRAPH_NODE_TYPES=()
GRAPH_NODE_RUNTIMES=()
GRAPH_NODE_SUBAGENTS=()
GRAPH_NODE_NATIVE_PARALLEL=()
GRAPH_NODE_INDEGREES=()
GRAPH_NODE_SUCCESSORS=()
# Conditional successors: pipe-delimited "condition:node_id" pairs.
# Each entry encodes the semantic condition (passed, changes-required, error)
# under which the edge fires. Populated alongside GRAPH_NODE_SUCCESSORS by
# graph_schedule_load_index for edges that carry a "condition" field.
GRAPH_NODE_COND_SUCCESSORS=()
# Scheduler-owned working state (reset by graph_schedule_run).
GRAPH_NODE_STATES=()
GRAPH_NODE_REMAINING_INDEGREE=()
GRAPH_NODE_ATTEMPT_NUMBERS=()
# Slots held against the per-runtime cap while the node is running (0 when idle).
GRAPH_NODE_HELD_SLOTS=()
GRAPH_NODE_HELD_TOKEN_SLOTS=()
# Count of predecessors that have been SKIPPED (not succeeded, failed, or
# blocked). Used by the router skip cascade: a pending descendant with
# skip_predecessor_count == total_indegree has ALL predecessors skipped and
# no live inbound path, so it should also be skipped. Zero at init; reset
# by graph_schedule_run.
GRAPH_NODE_SKIP_PREDECESSOR_COUNT=()

# Id -> index map, same idiom as orch_stage_index_map_set/get.
GRAPH_NODE_INDEX_KEYS=()
GRAPH_NODE_INDEX_VALS=()

# Per-runtime occupancy (bash 3.2 parallel arrays; no associative arrays).
GRAPH_RUNTIME_KEYS=()
GRAPH_RUNTIME_USED_SLOTS=()
GRAPH_RUNTIME_EXCLUSIVE_NODE=()
# Set by _graph_schedule_runtime_map_index / _graph_schedule_runtime_ensure.
GRAPH_RUNTIME_LOOKUP_IDX=""

# Populated for the active graph_schedule_run.
GRAPH_SCHEDULE_MAX_PARALLEL=2
GRAPH_SCHEDULE_MAX_PARALLEL_PER_RUNTIME=1
GRAPH_SCHEDULE_TOKEN_CAP=2
GRAPH_SCHEDULE_USED_TOKEN_SLOTS=0
GRAPH_SCHEDULE_ORCH_PATH=""
GRAPH_SCHEDULE_NAMESPACE=""
GRAPH_SCHEDULE_PLAN_KEY=""
GRAPH_SCHEDULE_GRAPH_JSON=""
GRAPH_SCHEDULE_RUN_ID=""
GRAPH_SCHEDULE_WORKSPACE=""
GRAPH_SCHEDULE_EXIT_CODE=0
GRAPH_SCHEDULE_FAILED_NODE=""
GRAPH_SCHEDULE_STOP_DISPATCH=0
# failurePolicy from .graph.json: drain (default) or cancel.
GRAPH_SCHEDULE_FAILURE_POLICY="drain"
# Set when cancel has signalled in-flight children (idempotent).
GRAPH_SCHEDULE_CANCEL_REQUESTED=0
# Set when any node finished with exit code 3 (human ack pending).
GRAPH_SCHEDULE_AWAITING_ACK=0
# Ledger integration (p3-resume). When non-empty, the scheduler records node
# state transitions and attempt outcomes into the durable run-state ledger at
# GRAPH_SCHEDULE_LEDGER_RUN_DIR. Set by graph_schedule_run when the ledger is
# initialized. Empty for ledger-less test invocations (keeps existing tests
# behaviorally unchanged).
GRAPH_SCHEDULE_LEDGER_RUN_DIR=""
GRAPH_SCHEDULE_LEDGER_NAMESPACE=""
# Path to the structured transition log for this run.  Set by graph_schedule_run
# once GRAPH_SCHEDULE_WORKSPACE and GRAPH_SCHEDULE_NAMESPACE are known.  Uses
# the same format as the orchestrator log ([YYYY-MM-DD HH:MM:SS] message) so
# the logs directory stays greppable.  Empty keeps the pre-ledger tests intact.
GRAPH_SCHEDULE_LOG_FILE=""
GRAPH_SCHEDULE_ADMISSION_LOG_FILE=""
GRAPH_SCHEDULE_DELEGATION_ACTIVE=0
GRAPH_DELEGATION_CHILD_PIDS=()
GRAPH_DELEGATION_CHILD_PARENTS=()
GRAPH_DELEGATION_CHILD_IDS=()
GRAPH_DELEGATION_CHILD_RUNTIMES=()
GRAPH_DELEGATION_CHILD_HELD_SLOTS=()
GRAPH_DELEGATION_CHILD_TOKEN_SLOTS=()
GRAPH_DELEGATION_ADMITTED_ENTRY=""

_graph_schedule_delegation_untrack_at() {
  local wanted="$1" i pids=() parents=() ids=() runtimes=() held=() tokens=()
  local runtime="${GRAPH_DELEGATION_CHILD_RUNTIMES[$wanted]:-}" slots="${GRAPH_DELEGATION_CHILD_HELD_SLOTS[$wanted]:-0}" token_slots="${GRAPH_DELEGATION_CHILD_TOKEN_SLOTS[$wanted]:-0}"
  _graph_schedule_runtime_release_slots "$runtime" "$slots" "$token_slots" || true
  for ((i=0; i<${#GRAPH_DELEGATION_CHILD_PIDS[@]}; i++)); do
    if [[ "$i" -ne "$wanted" ]]; then
      pids+=("${GRAPH_DELEGATION_CHILD_PIDS[$i]}")
      parents+=("${GRAPH_DELEGATION_CHILD_PARENTS[$i]}")
      ids+=("${GRAPH_DELEGATION_CHILD_IDS[$i]}")
      runtimes+=("${GRAPH_DELEGATION_CHILD_RUNTIMES[$i]}")
      held+=("${GRAPH_DELEGATION_CHILD_HELD_SLOTS[$i]}")
      tokens+=("${GRAPH_DELEGATION_CHILD_TOKEN_SLOTS[$i]}")
    fi
  done
  GRAPH_DELEGATION_CHILD_PIDS=("${pids[@]}"); GRAPH_DELEGATION_CHILD_PARENTS=("${parents[@]}"); GRAPH_DELEGATION_CHILD_IDS=("${ids[@]}")
  GRAPH_DELEGATION_CHILD_RUNTIMES=("${runtimes[@]}"); GRAPH_DELEGATION_CHILD_HELD_SLOTS=("${held[@]}"); GRAPH_DELEGATION_CHILD_TOKEN_SLOTS=("${tokens[@]}")
}

_graph_schedule_reap_delegated_children() {
  local i pid rc
  for ((i=${#GRAPH_DELEGATION_CHILD_PIDS[@]}-1; i>=0; i--)); do
    pid="${GRAPH_DELEGATION_CHILD_PIDS[$i]}"
    if ! kill -0 "$pid" 2>/dev/null; then
      rc=0
      wait "$pid" 2>/dev/null || rc=$?
      _graph_schedule_log_admission "released" "broker-child" "${GRAPH_DELEGATION_CHILD_IDS[$i]}" \
        "${GRAPH_DELEGATION_CHILD_RUNTIMES[$i]}" "off" "${GRAPH_DELEGATION_CHILD_HELD_SLOTS[$i]}" \
        "${GRAPH_DELEGATION_CHILD_TOKEN_SLOTS[$i]}" "child-exit=$rc"
      _graph_schedule_delegation_untrack_at "$i"
    fi
  done
}

# Start queued broker work in its own session while a parent graph node remains
# live.  The status ledger, not this shell PID, is the source of truth.
graph_schedule_drain_delegated_children() {
  local workspace="$GRAPH_SCHEDULE_WORKSPACE" ns="$GRAPH_SCHEDULE_NAMESPACE" run_id="$GRAPH_SCHEDULE_RUN_ID" entry parent did pid cap profiles runtime slots token_slots
  local project_root state_root parent_workspace run_file node_file delegation_runner
  [[ -n "$workspace" && -n "$ns" && -n "$run_id" ]] || return 0
  _graph_schedule_reap_delegated_children
  cap=$(( GRAPH_SCHEDULE_MAX_PARALLEL - $(_graph_schedule_count_active_invocations) )); [[ "$cap" -gt 0 ]] || return 0
  profiles="$(jq -c '.verificationProfiles // []' "$GRAPH_SCHEDULE_GRAPH_JSON" 2>/dev/null || echo '[]')"
  while [[ "$cap" -gt 0 ]]; do
    GRAPH_DELEGATION_ADMITTED_ENTRY=""
    graph_schedule_admit_delegated_child "$workspace" "$ns" "$run_id" "$cap" "$GRAPH_SCHEDULE_MAX_PARALLEL_PER_RUNTIME" || break
    entry="$GRAPH_DELEGATION_ADMITTED_ENTRY"
    parent="$(jq -r .parentNodeId <<<"$entry")"; did="$(jq -r .delegationId <<<"$entry")"
    runtime="$(jq -r .runtime <<<"$entry")"
    slots="${GRAPH_DELEGATION_ADMITTED_RUNTIME_SLOTS:-1}"
    token_slots="${GRAPH_DELEGATION_ADMITTED_TOKEN_SLOTS:-1}"
    project_root="$workspace"
    state_root="${RALPH_PLAN_WORKSPACE_ROOT:-$workspace/.ralph-workspace}"
    parent_workspace="$workspace"
    run_file="${GRAPH_SCHEDULE_LEDGER_RUN_DIR:+$GRAPH_SCHEDULE_LEDGER_RUN_DIR/run.json}"
    node_file=""
    if [[ -n "$GRAPH_SCHEDULE_LEDGER_RUN_DIR" ]]; then
      node_file="$(graph_state_node_file "$workspace" "$ns" "$run_id" "$parent" 2>/dev/null || true)"
    fi
    if [[ -n "$run_file" && -f "$run_file" ]]; then
      project_root="$(jq -r '.roots.projectRoot // empty' "$run_file")"
      state_root="$(jq -r '.roots.stateRoot // empty' "$run_file")"
      [[ -n "$project_root" && "$project_root" != null ]] || project_root="$workspace"
      [[ -n "$state_root" && "$state_root" != null ]] || state_root="${RALPH_PLAN_WORKSPACE_ROOT:-$workspace/.ralph-workspace}"
    fi
    if [[ -n "$node_file" && -f "$node_file" ]]; then
      parent_workspace="$(jq -r '.workspacePath // .attempts[-1].workspacePath // empty' "$node_file")"
      [[ -n "$parent_workspace" && "$parent_workspace" != null ]] || parent_workspace="$workspace"
    fi
    delegation_runner="${RALPH_DELEGATION_RUN_PLAN:-$GRAPH_SCHEDULE_SCRIPT_DIR/../../run-plan.sh}"
    (
      if command -v python3 >/dev/null 2>&1; then
        RALPH_DELEGATION_RUN_PLAN="$delegation_runner" exec python3 -c 'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' \
          bash -c 'source "$1"; graph_delegation_child_run "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}"' \
          delegated-child "$GRAPH_SCHEDULE_SCRIPT_DIR/graph-delegation-runner.sh" "$workspace" "$ns" "$run_id" "$parent" "$did" "$project_root" "$state_root" "$parent_workspace" "$profiles"
      else
        RALPH_DELEGATION_RUN_PLAN="$delegation_runner" graph_delegation_child_run "$workspace" "$ns" "$run_id" "$parent" "$did" "$project_root" "$state_root" "$parent_workspace" "$profiles"
      fi
    ) >/dev/null 2>&1 &
    pid=$!; graph_delegation_child_record_process "$workspace" "$ns" "$run_id" "$parent" "$did" "$pid" "$pid" || true
    GRAPH_DELEGATION_CHILD_PIDS+=("$pid"); GRAPH_DELEGATION_CHILD_PARENTS+=("$parent"); GRAPH_DELEGATION_CHILD_IDS+=("$did")
    GRAPH_DELEGATION_CHILD_RUNTIMES+=("$runtime"); GRAPH_DELEGATION_CHILD_HELD_SLOTS+=("$slots"); GRAPH_DELEGATION_CHILD_TOKEN_SLOTS+=("$token_slots")
    graph_delegation_runner_log "$workspace" "spawn delegation=$did pid=$pid parent=$parent"
    cap=$((cap-1))
  done
}

# Restart reconciliation adopts terminal ledger outcomes, retains live child
# sessions, and only requeues a dead process with no terminal outcome.
graph_schedule_recover_delegated_children() {
  local entry parent did status runtime process_file pid
  while IFS= read -r entry; do
    parent="$(jq -r .parentNodeId <<<"$entry")"; did="$(jq -r .delegationId <<<"$entry")"
    status="$(graph_delegation_ledger_read_status "$GRAPH_SCHEDULE_WORKSPACE" "$GRAPH_SCHEDULE_NAMESPACE" "$GRAPH_SCHEDULE_RUN_ID" "$parent" "$did" 2>/dev/null | jq -r '.status // empty')"
    case "$status" in succeeded|failed|cancelled|awaiting-ack) graph_delegation_runner_log "$GRAPH_SCHEDULE_WORKSPACE" "adopt delegation=$did status=$status";;
      running)
        if graph_delegation_child_process_alive "$GRAPH_SCHEDULE_WORKSPACE" "$GRAPH_SCHEDULE_NAMESPACE" "$GRAPH_SCHEDULE_RUN_ID" "$parent" "$did"; then
          runtime="$(jq -r '.runtime' <<<"$entry")"
          process_file="$(graph_delegation_ledger_process_file "$GRAPH_SCHEDULE_WORKSPACE" "$GRAPH_SCHEDULE_NAMESPACE" "$GRAPH_SCHEDULE_RUN_ID" "$parent" "$did")"
          pid="$(jq -r '.pid // empty' "$process_file" 2>/dev/null)"
          if [[ "$pid" =~ ^[0-9]+$ ]] && _graph_schedule_runtime_can_admit "$runtime" off 1; then
            _graph_schedule_runtime_reserve_slots "$runtime" 1 1
            GRAPH_DELEGATION_CHILD_PIDS+=("$pid"); GRAPH_DELEGATION_CHILD_PARENTS+=("$parent"); GRAPH_DELEGATION_CHILD_IDS+=("$did")
            GRAPH_DELEGATION_CHILD_RUNTIMES+=("$runtime"); GRAPH_DELEGATION_CHILD_HELD_SLOTS+=("1"); GRAPH_DELEGATION_CHILD_TOKEN_SLOTS+=("1")
            _graph_schedule_log_admission "admitted" "broker-child" "$did" "$runtime" "off" "1" "1" "recovered-live-child"
          else
            graph_delegation_runner_log "$GRAPH_SCHEDULE_WORKSPACE" "defer adoption delegation=$did runtime=$runtime capacity unavailable"
          fi
        else
          graph_delegation_ledger_transition "$GRAPH_SCHEDULE_WORKSPACE" "$GRAPH_SCHEDULE_NAMESPACE" "$GRAPH_SCHEDULE_RUN_ID" "$parent" "$did" queued recovery '' '{}' null 'scheduler recovery: dead child without outcome' || true
          graph_delegation_runner_log "$GRAPH_SCHEDULE_WORKSPACE" "reset delegation=$did dead-process"
        fi
        ;;
    esac
  done < <(graph_delegation_queue_pending "$GRAPH_SCHEDULE_WORKSPACE" "$GRAPH_SCHEDULE_NAMESPACE" "$GRAPH_SCHEDULE_RUN_ID")
}

# _graph_schedule_log_transition <message>
# Append one structured log line to GRAPH_SCHEDULE_LOG_FILE using the same
# format as ralph_orchestrator_log.  No-op when GRAPH_SCHEDULE_LOG_FILE is
# empty, which keeps ledger-less test invocations unchanged.
_graph_schedule_log_transition() {
  if [[ -z "${GRAPH_SCHEDULE_LOG_FILE:-}" ]]; then
    return 0
  fi
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)"
  printf '[%s] %s\n' "$ts" "$*" >> "$GRAPH_SCHEDULE_LOG_FILE" 2>/dev/null || true
}

# _graph_schedule_observability_log_file
# Returns the per-run structured observability log path, or empty when no
# ledger run is active.  Separate from the transition log so status/render
# can append JSONL event records without interfering with greppable text lines.
_graph_schedule_observability_log_file() {
  if [[ -z "${GRAPH_SCHEDULE_LEDGER_RUN_DIR:-}" ]]; then
    return 0
  fi
  printf '%s/observability.jsonl\n' "$GRAPH_SCHEDULE_LEDGER_RUN_DIR"
}

# _graph_schedule_log_observability <event> <node-id> <attempt-id> <runtime>
#   <subagents> <details-json>
# Append a structured JSONL event to the observability log.  No-op when there
# is no ledger run.  The event shape is intentionally compact and additive.
_graph_schedule_log_observability() {
  local event="$1" node_id="$2" attempt_id="$3" runtime="$4" subagents="$5" details_json="${6:-}"
  local log_file
  log_file="$(_graph_schedule_observability_log_file)" || return 0
  [[ -n "$log_file" ]] || return 0
  if [[ -z "$details_json" ]]; then
    details_json='{}'
  fi
  jq -e . >/dev/null 2>&1 <<<"$details_json" || details_json='{}'
  jq -cn \
    --arg ts "$(graph_state_now_iso)" \
    --arg event "$event" \
    --arg nodeId "$node_id" \
    --arg attemptId "$attempt_id" \
    --arg runtime "$runtime" \
    --arg subagents "$subagents" \
    --argjson details "$details_json" \
    '{timestamp:$ts,event:$event,nodeId:$nodeId,attemptId:$attemptId,runtime:$runtime,subagents:$subagents,details:$details}' \
    >>"$log_file" 2>/dev/null || true
}

# A parent that waits for a brokered child occupies one graph slot.  Graph v1
# therefore needs a second, cross-runtime slot before accepting such a policy;
# otherwise the first waiting parent can permanently starve its only child.
graph_schedule_delegation_preflight() {
  local graph="$1" max_parallel="$2" has_cross
  has_cross="$(jq '[.nodes[] | .stage.delegation? | select((.maxChildren // 0) > 0 and (.crossRuntime.mode // "off") != "off" and ((.crossRuntime.allowedRuntimes // []) | length > 0))] | length' "$graph" 2>/dev/null)" || return 1
  if [[ "$has_cross" -gt 0 && "$max_parallel" -lt 2 ]]; then
    echo "Error: delegation policy has no possible child slot: maxParallel must be at least 2 for cross-runtime children" >&2
    return 1
  fi
  return 0
}

graph_schedule_native_budget_preflight() {
  local graph="$1" node runtime subagents native_parallel required cap
  while IFS=$'\034' read -r node runtime subagents native_parallel || [[ -n "$node" ]]; do
    [[ "$subagents" == "on" && "$native_parallel" =~ ^[1-9][0-9]*$ ]] || continue
    required=$(( native_parallel + 1 ))
    cap="$(_graph_schedule_runtime_cap "$runtime")"
    if [[ "$required" -gt "$cap" || "$required" -gt "$GRAPH_SCHEDULE_TOKEN_CAP" ]]; then
      echo "Error: native subagent allowance cannot be admitted for node $node: parent+native.maxParallel requires $required runtime/token slots, effective runtime cap is $cap and token cap is $GRAPH_SCHEDULE_TOKEN_CAP" >&2
      return 1
    fi
  done < <(jq -jr '.nodes[] | ([.id, (.stage.runtime // ""), (.stage.subagents // "inherit"), (.stage.delegation.native.maxParallel // 0)] | map(tostring) | join("\u001c")) + "\n"' "$graph")
}

# Public scheduler admission seam. It is intentionally separate from runtime
# execution so the MCP server cannot accidentally become an executor.
graph_schedule_admit_delegated_child() {
  local workspace="$1" ns="$2" run_id="$3" child_cap="$4" runtime_cap="$5"
  local entry parent did runtime slots token_slots
  entry="$(graph_delegation_queue_admit_one "$workspace" "$ns" "$run_id" "$child_cap" "$runtime_cap")" || return $?
  parent="$(jq -r .parentNodeId <<<"$entry")"
  did="$(jq -r .delegationId <<<"$entry")"
  runtime="$(jq -r .runtime <<<"$entry")"
  slots=1
  token_slots=1
  if ! _graph_schedule_runtime_can_admit "$runtime" "off" "$token_slots"; then
    graph_delegation_ledger_transition "$workspace" "$ns" "$run_id" "$parent" "$did" queued "scheduler-${run_id}" "" '{}' null 'runtime/token admission deferred' || true
    _graph_schedule_log_admission "denied" "broker-child" "$did" "$runtime" "off" "$slots" "$token_slots" "runtime-or-token-cap"
    return 2
  fi
  _graph_schedule_runtime_reserve_slots "$runtime" "$slots" "$token_slots" || return 1
  GRAPH_DELEGATION_ADMITTED_ENTRY="$entry"
  GRAPH_DELEGATION_ADMITTED_RUNTIME_SLOTS="$slots"
  GRAPH_DELEGATION_ADMITTED_TOKEN_SLOTS="$token_slots"
  _graph_schedule_log_admission "admitted" "broker-child" "$did" "$runtime" "off" "$slots" "$token_slots" "scheduler-owned-child"
  return 0
}

# Scheduler-owned child execution seam.  The queue atomically changes the
# ledger to running before this function starts run-plan.sh; no MCP process
# can reach this call.
graph_schedule_run_delegated_child() {
  local workspace="$1" ns="$2" run_id="$3" child_cap="$4" runtime_cap="$5" project_root="$6" state_root="$7" agent_workspace="$8" profiles="${9:-[]}"
  local entry parent did
  entry="$(graph_delegation_queue_admit_one "$workspace" "$ns" "$run_id" "$child_cap" "$runtime_cap")" || return $?
  parent="$(jq -r '.parentNodeId' <<<"$entry")"; did="$(jq -r '.delegationId' <<<"$entry")"
  graph_delegation_child_run "$workspace" "$ns" "$run_id" "$parent" "$did" "$project_root" "$state_root" "$agent_workspace" "$profiles"
}

graph_schedule_index_map_set() {
  local key="$1" val="$2" i
  for ((i = 0; i < ${#GRAPH_NODE_INDEX_KEYS[@]}; i++)); do
    if [[ "${GRAPH_NODE_INDEX_KEYS[$i]}" == "$key" ]]; then
      GRAPH_NODE_INDEX_VALS[$i]="$val"
      return 0
    fi
  done
  GRAPH_NODE_INDEX_KEYS+=("$key")
  GRAPH_NODE_INDEX_VALS+=("$val")
}

graph_schedule_index_map_get() {
  local key="$1" i
  for ((i = 0; i < ${#GRAPH_NODE_INDEX_KEYS[@]}; i++)); do
    if [[ "${GRAPH_NODE_INDEX_KEYS[$i]}" == "$key" ]]; then
      printf '%s\n' "${GRAPH_NODE_INDEX_VALS[$i]}"
      return 0
    fi
  done
  return 1
}

graph_schedule_node_count() {
  printf '%s\n' "${#GRAPH_NODE_IDS[@]}"
}

# Lookup helpers by index.
graph_schedule_node_id_at() {
  local idx="$1"
  if [[ -z "$idx" || "$idx" -lt 0 || "$idx" -ge ${#GRAPH_NODE_IDS[@]} ]]; then
    echo "Error: graph node index out of range: ${idx:-}" >&2
    return 1
  fi
  printf '%s\n' "${GRAPH_NODE_IDS[$idx]}"
}

graph_schedule_node_type_at() {
  local idx="$1"
  if [[ -z "$idx" || "$idx" -lt 0 || "$idx" -ge ${#GRAPH_NODE_TYPES[@]} ]]; then
    echo "Error: graph node index out of range: ${idx:-}" >&2
    return 1
  fi
  printf '%s\n' "${GRAPH_NODE_TYPES[$idx]}"
}

graph_schedule_node_runtime_at() {
  local idx="$1"
  if [[ -z "$idx" || "$idx" -lt 0 || "$idx" -ge ${#GRAPH_NODE_RUNTIMES[@]} ]]; then
    echo "Error: graph node index out of range: ${idx:-}" >&2
    return 1
  fi
  printf '%s\n' "${GRAPH_NODE_RUNTIMES[$idx]}"
}

graph_schedule_node_subagents_at() {
  local idx="$1"
  if [[ -z "$idx" || "$idx" -lt 0 || "$idx" -ge ${#GRAPH_NODE_SUBAGENTS[@]} ]]; then
    echo "Error: graph node index out of range: ${idx:-}" >&2
    return 1
  fi
  printf '%s\n' "${GRAPH_NODE_SUBAGENTS[$idx]}"
}

graph_schedule_node_indegree_at() {
  local idx="$1"
  if [[ -z "$idx" || "$idx" -lt 0 || "$idx" -ge ${#GRAPH_NODE_INDEGREES[@]} ]]; then
    echo "Error: graph node index out of range: ${idx:-}" >&2
    return 1
  fi
  printf '%s\n' "${GRAPH_NODE_INDEGREES[$idx]}"
}

graph_schedule_node_successors_at() {
  local idx="$1"
  if [[ -z "$idx" || "$idx" -lt 0 || "$idx" -ge ${#GRAPH_NODE_SUCCESSORS[@]} ]]; then
    echo "Error: graph node index out of range: ${idx:-}" >&2
    return 1
  fi
  printf '%s\n' "${GRAPH_NODE_SUCCESSORS[$idx]}"
}

# Lookup helpers by node id (resolve through the index map).
graph_schedule_node_type_by_id() {
  local node_id="$1" idx
  if ! idx="$(graph_schedule_index_map_get "$node_id")"; then
    echo "Error: unknown graph node id: $node_id" >&2
    return 1
  fi
  graph_schedule_node_type_at "$idx"
}

graph_schedule_node_runtime_by_id() {
  local node_id="$1" idx
  if ! idx="$(graph_schedule_index_map_get "$node_id")"; then
    echo "Error: unknown graph node id: $node_id" >&2
    return 1
  fi
  graph_schedule_node_runtime_at "$idx"
}

graph_schedule_node_subagents_by_id() {
  local node_id="$1" idx
  if ! idx="$(graph_schedule_index_map_get "$node_id")"; then
    echo "Error: unknown graph node id: $node_id" >&2
    return 1
  fi
  graph_schedule_node_subagents_at "$idx"
}

graph_schedule_node_indegree_by_id() {
  local node_id="$1" idx
  if ! idx="$(graph_schedule_index_map_get "$node_id")"; then
    echo "Error: unknown graph node id: $node_id" >&2
    return 1
  fi
  graph_schedule_node_indegree_at "$idx"
}

graph_schedule_node_successors_by_id() {
  local node_id="$1" idx
  if ! idx="$(graph_schedule_index_map_get "$node_id")"; then
    echo "Error: unknown graph node id: $node_id" >&2
    return 1
  fi
  graph_schedule_node_successors_at "$idx"
}

# Returns the raw "condition:node_id" delimited string for conditional successors.
graph_schedule_node_cond_successors_at() {
  local idx="$1"
  if [[ -z "$idx" || "$idx" -lt 0 || "$idx" -ge ${#GRAPH_NODE_COND_SUCCESSORS[@]} ]]; then
    echo "Error: graph node index out of range: ${idx:-}" >&2
    return 1
  fi
  printf '%s\n' "${GRAPH_NODE_COND_SUCCESSORS[$idx]}"
}

graph_schedule_node_cond_successors_by_id() {
  local node_id="$1" idx
  if ! idx="$(graph_schedule_index_map_get "$node_id")"; then
    echo "Error: unknown graph node id: $node_id" >&2
    return 1
  fi
  graph_schedule_node_cond_successors_at "$idx"
}

_graph_schedule_append_successor() {
  local from_idx="$1"
  local to_id="$2"
  local existing="${GRAPH_NODE_SUCCESSORS[$from_idx]}"
  if [[ -z "$existing" ]]; then
    GRAPH_NODE_SUCCESSORS[$from_idx]="$to_id"
  else
    GRAPH_NODE_SUCCESSORS[$from_idx]="${existing}${GRAPH_SUCCESSOR_DELIM}${to_id}"
  fi
}

# _graph_schedule_append_cond_successor <from_idx> <condition:to_id>
# Appends a "condition:node_id" entry to GRAPH_NODE_COND_SUCCESSORS[from_idx].
_graph_schedule_append_cond_successor() {
  local from_idx="$1"
  local cond_entry="$2"
  local existing="${GRAPH_NODE_COND_SUCCESSORS[$from_idx]:-}"
  if [[ -z "$existing" ]]; then
    GRAPH_NODE_COND_SUCCESSORS[$from_idx]="$cond_entry"
  else
    GRAPH_NODE_COND_SUCCESSORS[$from_idx]="${existing}${GRAPH_SUCCESSOR_DELIM}${cond_entry}"
  fi
}

_graph_schedule_reset_runtime_occupancy() {
  GRAPH_RUNTIME_KEYS=()
  GRAPH_RUNTIME_USED_SLOTS=()
  GRAPH_RUNTIME_EXCLUSIVE_NODE=()
  GRAPH_RUNTIME_LOOKUP_IDX=""
  GRAPH_SCHEDULE_USED_TOKEN_SLOTS=0
}

_graph_schedule_reset_index() {
  GRAPH_NODE_IDS=()
  GRAPH_NODE_TYPES=()
  GRAPH_NODE_RUNTIMES=()
  GRAPH_NODE_SUBAGENTS=()
  GRAPH_NODE_NATIVE_PARALLEL=()
  GRAPH_NODE_INDEGREES=()
  GRAPH_NODE_SUCCESSORS=()
  GRAPH_NODE_COND_SUCCESSORS=()
  GRAPH_NODE_STATES=()
  GRAPH_NODE_REMAINING_INDEGREE=()
  GRAPH_NODE_ATTEMPT_NUMBERS=()
  GRAPH_NODE_HELD_SLOTS=()
  GRAPH_NODE_HELD_TOKEN_SLOTS=()
  GRAPH_NODE_SKIP_PREDECESSOR_COUNT=()
  GRAPH_NODE_INDEX_KEYS=()
  GRAPH_NODE_INDEX_VALS=()
  _graph_schedule_reset_runtime_occupancy
  GRAPH_SCHEDULE_MAX_PARALLEL=2
  GRAPH_SCHEDULE_MAX_PARALLEL_PER_RUNTIME=1
  GRAPH_SCHEDULE_TOKEN_CAP=2
  GRAPH_SCHEDULE_USED_TOKEN_SLOTS=0
  GRAPH_SCHEDULE_ORCH_PATH=""
  GRAPH_SCHEDULE_NAMESPACE=""
  GRAPH_SCHEDULE_PLAN_KEY=""
  GRAPH_SCHEDULE_GRAPH_JSON=""
  GRAPH_SCHEDULE_RUN_ID=""
  GRAPH_SCHEDULE_WORKSPACE=""
  GRAPH_SCHEDULE_EXIT_CODE=0
  GRAPH_SCHEDULE_FAILED_NODE=""
  GRAPH_SCHEDULE_STOP_DISPATCH=0
  GRAPH_SCHEDULE_FAILURE_POLICY="drain"
  GRAPH_SCHEDULE_CANCEL_REQUESTED=0
  GRAPH_SCHEDULE_AWAITING_ACK=0
  GRAPH_SCHEDULE_LEDGER_RUN_DIR=""
  GRAPH_SCHEDULE_LEDGER_NAMESPACE=""
  GRAPH_SCHEDULE_LOG_FILE=""
  GRAPH_SCHEDULE_ADMISSION_LOG_FILE=""
}

# graph_schedule_load_index <graph_json_path>
#
# jq-only loader (no python3). Builds parallel indexed arrays for node id,
# type, runtime, indegree, and delimited successor lists, plus an id->index
# map. Fails loudly when a node id contains GRAPH_SUCCESSOR_DELIM or when any
# edge references an unknown node (offending edge named in the error).
graph_schedule_load_index() {
  local graph_json_path="$1"
  local node_line edge_line node_id node_type node_runtime node_subagents node_native_parallel
  local from_id to_id from_idx to_idx idx
  local nodes_tmp edges_tmp edges_cond_tmp

  if [[ -z "$graph_json_path" || ! -f "$graph_json_path" ]]; then
    echo "Error: graph json not found: ${graph_json_path:-}" >&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required to load .graph.json" >&2
    return 1
  fi

  _graph_schedule_reset_index

  # Temp files avoid process-substitution + pipe-subshell issues under set -e
  # while staying bash 3.2 safe (no mapfile/readarray).
  nodes_tmp="$(mktemp "${TMPDIR:-/tmp}/ralph-graph-nodes.XXXXXX")" || return 1
  edges_tmp="$(mktemp "${TMPDIR:-/tmp}/ralph-graph-edges.XXXXXX")" || {
    rm -f "$nodes_tmp"
    return 1
  }
  edges_cond_tmp="$(mktemp "${TMPDIR:-/tmp}/ralph-graph-edges-cond.XXXXXX")" || {
    rm -f "$nodes_tmp" "$edges_tmp"
    return 1
  }

  # Use a non-whitespace separator so Bash read preserves an empty runtime on
  # scheduler-owned nodes (integrate/checkpoint/barrier).
  if ! jq -jr '.nodes[] | ([.id, .type, (.stage.runtime // ""), (.stage.subagents // "inherit"), (.stage.delegation.native.maxParallel // 0)] | map(tostring) | join("\u001c")) + "\n"' \
      "$graph_json_path" >"$nodes_tmp"; then
    echo "Error: failed to parse nodes from $graph_json_path" >&2
    rm -f "$nodes_tmp" "$edges_tmp"
    return 1
  fi
  # Unconditional edges: no condition field or empty condition.
  if ! jq -r '.edges[] | select((.condition // "") == "") | [.from, .to] | @tsv' \
      "$graph_json_path" >"$edges_tmp"; then
    echo "Error: failed to parse edges from $graph_json_path" >&2
    rm -f "$nodes_tmp" "$edges_tmp" "$edges_cond_tmp"
    return 1
  fi
  # Conditional edges: non-empty condition field; emit from, to, condition.
  if ! jq -r '.edges[] | select((.condition // "") != "") | [.from, .to, .condition] | @tsv' \
      "$graph_json_path" >"$edges_cond_tmp"; then
    echo "Error: failed to parse conditional edges from $graph_json_path" >&2
    rm -f "$nodes_tmp" "$edges_tmp" "$edges_cond_tmp"
    return 1
  fi

  idx=0
  while IFS=$'\034' read -r node_id node_type node_runtime node_subagents node_native_parallel || [[ -n "$node_id" ]]; do
    [[ -z "$node_id" ]] && continue
    if [[ "$node_id" == *"${GRAPH_SUCCESSOR_DELIM}"* ]]; then
      echo "Error: node id contains successor delimiter '${GRAPH_SUCCESSOR_DELIM}': $node_id" >&2
      rm -f "$nodes_tmp" "$edges_tmp" "$edges_cond_tmp"
      _graph_schedule_reset_index
      return 1
    fi
    if graph_schedule_index_map_get "$node_id" >/dev/null 2>&1; then
      echo "Error: duplicate graph node id: $node_id" >&2
      rm -f "$nodes_tmp" "$edges_tmp" "$edges_cond_tmp"
      _graph_schedule_reset_index
      return 1
    fi
    case "$node_subagents" in
      inherit|on|off) ;;
      "") node_subagents="inherit" ;;
      *)
        echo "Error: invalid subagents value for node $node_id: $node_subagents" >&2
        rm -f "$nodes_tmp" "$edges_tmp" "$edges_cond_tmp"
        _graph_schedule_reset_index
        return 1
        ;;
    esac
    GRAPH_NODE_IDS+=("$node_id")
    GRAPH_NODE_TYPES+=("$node_type")
    GRAPH_NODE_RUNTIMES+=("$node_runtime")
    GRAPH_NODE_SUBAGENTS+=("$node_subagents")
    [[ "$node_native_parallel" =~ ^[0-9]+$ ]] || node_native_parallel=0
    GRAPH_NODE_NATIVE_PARALLEL+=("$node_native_parallel")
    GRAPH_NODE_INDEGREES+=("0")
    GRAPH_NODE_SUCCESSORS+=("")
    GRAPH_NODE_COND_SUCCESSORS+=("")
    GRAPH_NODE_STATES+=("pending")
    GRAPH_NODE_REMAINING_INDEGREE+=("0")
    GRAPH_NODE_ATTEMPT_NUMBERS+=("0")
    GRAPH_NODE_HELD_SLOTS+=("0")
    GRAPH_NODE_HELD_TOKEN_SLOTS+=("0")
    GRAPH_NODE_SKIP_PREDECESSOR_COUNT+=("0")
    graph_schedule_index_map_set "$node_id" "$idx"
    idx=$((idx + 1))
  done <"$nodes_tmp"

  if [[ ${#GRAPH_NODE_IDS[@]} -eq 0 ]]; then
    echo "Error: graph has no nodes: $graph_json_path" >&2
    rm -f "$nodes_tmp" "$edges_tmp" "$edges_cond_tmp"
    return 1
  fi

  # Load unconditional edges.
  while IFS=$'\t' read -r from_id to_id || [[ -n "$from_id" ]]; do
    [[ -z "$from_id" && -z "$to_id" ]] && continue
    if ! from_idx="$(graph_schedule_index_map_get "$from_id")"; then
      echo "Error: graph edge references unknown node: ${from_id} -> ${to_id} (unknown: ${from_id})" >&2
      rm -f "$nodes_tmp" "$edges_tmp" "$edges_cond_tmp"
      _graph_schedule_reset_index
      return 1
    fi
    if ! to_idx="$(graph_schedule_index_map_get "$to_id")"; then
      echo "Error: graph edge references unknown node: ${from_id} -> ${to_id} (unknown: ${to_id})" >&2
      rm -f "$nodes_tmp" "$edges_tmp" "$edges_cond_tmp"
      _graph_schedule_reset_index
      return 1
    fi
    GRAPH_NODE_INDEGREES[$to_idx]=$(( ${GRAPH_NODE_INDEGREES[$to_idx]} + 1 ))
    GRAPH_NODE_REMAINING_INDEGREE[$to_idx]="${GRAPH_NODE_INDEGREES[$to_idx]}"
    _graph_schedule_append_successor "$from_idx" "$to_id"
  done <"$edges_tmp"

  # Load conditional edges. Each line: from_id TAB to_id TAB condition.
  # Conditional edges contribute to indegree (for cycle detection and readiness)
  # but are stored in GRAPH_NODE_COND_SUCCESSORS so the scheduler can resolve
  # them at runtime against the producing node's semantic outcome.
  local edge_condition
  while IFS=$'\t' read -r from_id to_id edge_condition || [[ -n "$from_id" ]]; do
    [[ -z "$from_id" && -z "$to_id" ]] && continue
    [[ -z "$edge_condition" ]] && continue
    if ! from_idx="$(graph_schedule_index_map_get "$from_id")"; then
      echo "Error: conditional edge references unknown node: ${from_id} -> ${to_id} (unknown: ${from_id})" >&2
      rm -f "$nodes_tmp" "$edges_tmp" "$edges_cond_tmp"
      _graph_schedule_reset_index
      return 1
    fi
    if ! to_idx="$(graph_schedule_index_map_get "$to_id")"; then
      echo "Error: conditional edge references unknown node: ${from_id} -> ${to_id} (unknown: ${to_id})" >&2
      rm -f "$nodes_tmp" "$edges_tmp" "$edges_cond_tmp"
      _graph_schedule_reset_index
      return 1
    fi
    case "$edge_condition" in
      passed|changes-required|error) ;;
      *)
        echo "Error: conditional edge has invalid condition '${edge_condition}': ${from_id} -> ${to_id}" >&2
        rm -f "$nodes_tmp" "$edges_tmp" "$edges_cond_tmp"
        _graph_schedule_reset_index
        return 1
        ;;
    esac
    GRAPH_NODE_INDEGREES[$to_idx]=$(( ${GRAPH_NODE_INDEGREES[$to_idx]} + 1 ))
    GRAPH_NODE_REMAINING_INDEGREE[$to_idx]="${GRAPH_NODE_INDEGREES[$to_idx]}"
    _graph_schedule_append_cond_successor "$from_idx" "${edge_condition}:${to_id}"
  done <"$edges_cond_tmp"

  rm -f "$nodes_tmp" "$edges_tmp" "$edges_cond_tmp"
  return 0
}

graph_schedule_node_state_at() {
  local idx="$1"
  if [[ -z "$idx" || "$idx" -lt 0 || "$idx" -ge ${#GRAPH_NODE_STATES[@]} ]]; then
    echo "Error: graph node index out of range: ${idx:-}" >&2
    return 1
  fi
  printf '%s\n' "${GRAPH_NODE_STATES[$idx]}"
}

graph_schedule_node_state_by_id() {
  local node_id="$1" idx
  if ! idx="$(graph_schedule_index_map_get "$node_id")"; then
    echo "Error: unknown graph node id: $node_id" >&2
    return 1
  fi
  graph_schedule_node_state_at "$idx"
}

# ---------------------------------------------------------------------------
# Child reaper (single centralized helper; never duplicate this logic).
#
# Tracks background node PIDs with parallel arrays (bash 3.2 safe: no
# associative arrays, no namerefs). Portable path polls kill -0 every 250ms
# and requires consecutive negative observations before wait(1), matching the
# macOS process-table churn hazard also seen with pgrep. bash 4.3+ may use
# wait -n then scan tracked pids (no wait -n -p; job-control SIGKILL
# notifications leave -p unset under set -u). Set GRAPH_REAP_FORCE_POLL=1 to
# force the portable path under newer bash.
#
# Outcome of record is the StageOutcomeReport at the tracked report path, not
# the process exit code. graph_schedule_reap_one returns the node, harvested
# exit code, and report path via globals (+ one stdout line); missing report
# is a failure (EXIT trap guarantees a report for any termination short of
# SIGKILL).
# ---------------------------------------------------------------------------

GRAPH_CHILD_PIDS=()
GRAPH_CHILD_PGIDS=()
GRAPH_CHILD_NODES=()
GRAPH_CHILD_REPORTS=()
GRAPH_CHILD_GONE_STREAKS=()

GRAPH_REAP_NODE=""
GRAPH_REAP_EXIT_CODE=""
GRAPH_REAP_REPORT_PATH=""
GRAPH_REAP_REASON=""
GRAPH_REAP_MISSING_REPORT=0

# Consecutive negative kill -0 observations required before harvest (poll path).
GRAPH_REAP_GONE_STREAK_REQUIRED="${GRAPH_REAP_GONE_STREAK_REQUIRED:-3}"
# Poll interval seconds (250ms). macOS /bin/sleep accepts fractions.
GRAPH_REAP_POLL_INTERVAL="${GRAPH_REAP_POLL_INTERVAL:-0.25}"

graph_schedule_clear_children() {
  GRAPH_CHILD_PIDS=()
  GRAPH_CHILD_PGIDS=()
  GRAPH_CHILD_NODES=()
  GRAPH_CHILD_REPORTS=()
  GRAPH_CHILD_GONE_STREAKS=()
  GRAPH_REAP_NODE=""
  GRAPH_REAP_EXIT_CODE=""
  GRAPH_REAP_REPORT_PATH=""
  GRAPH_REAP_REASON=""
  GRAPH_REAP_MISSING_REPORT=0
}

graph_schedule_child_count() {
  printf '%s\n' "${#GRAPH_CHILD_PIDS[@]}"
}

# graph_schedule_track_child <pid> <node_id> <report_path> [pgid]
# pgid defaults to pid (session-leader children from setsid/python os.setsid).
graph_schedule_track_child() {
  local pid="$1" node_id="$2" report_path="$3" pgid="${4:-$1}"
  if [[ -z "$pid" || ! "$pid" =~ ^[0-9]+$ ]]; then
    echo "Error: graph_schedule_track_child requires a numeric pid" >&2
    return 1
  fi
  if [[ -z "$node_id" || -z "$report_path" ]]; then
    echo "Error: graph_schedule_track_child requires node_id and report_path" >&2
    return 1
  fi
  if [[ -z "$pgid" || ! "$pgid" =~ ^[0-9]+$ ]]; then
    pgid="$pid"
  fi
  GRAPH_CHILD_PIDS+=("$pid")
  GRAPH_CHILD_PGIDS+=("$pgid")
  GRAPH_CHILD_NODES+=("$node_id")
  GRAPH_CHILD_REPORTS+=("$report_path")
  GRAPH_CHILD_GONE_STREAKS+=("0")
  return 0
}

_graph_schedule_reap_supports_wait_n() {
  if [[ "${GRAPH_REAP_FORCE_POLL:-0}" == "1" ]]; then
    return 1
  fi
  if [[ "${BASH_VERSINFO[0]}" -gt 4 ]]; then
    return 0
  fi
  if [[ "${BASH_VERSINFO[0]}" -eq 4 && "${BASH_VERSINFO[1]}" -ge 3 ]]; then
    return 0
  fi
  return 1
}

# Remove tracked child at index by rebuilding parallel arrays (no namerefs).
_graph_schedule_untrack_at() {
  local idx="$1"
  local new_pids=() new_pgids=() new_nodes=() new_reports=() new_streaks=()
  local i
  for ((i = 0; i < ${#GRAPH_CHILD_PIDS[@]}; i++)); do
    if [[ "$i" -eq "$idx" ]]; then
      continue
    fi
    new_pids+=("${GRAPH_CHILD_PIDS[$i]}")
    new_pgids+=("${GRAPH_CHILD_PGIDS[$i]}")
    new_nodes+=("${GRAPH_CHILD_NODES[$i]}")
    new_reports+=("${GRAPH_CHILD_REPORTS[$i]}")
    new_streaks+=("${GRAPH_CHILD_GONE_STREAKS[$i]}")
  done
  # bash 3.2 + set -u treats "${empty[@]}' as unbound; assign () explicitly.
  if [[ ${#new_pids[@]} -eq 0 ]]; then
    GRAPH_CHILD_PIDS=()
    GRAPH_CHILD_PGIDS=()
    GRAPH_CHILD_NODES=()
    GRAPH_CHILD_REPORTS=()
    GRAPH_CHILD_GONE_STREAKS=()
  else
    GRAPH_CHILD_PIDS=("${new_pids[@]}")
    GRAPH_CHILD_PGIDS=("${new_pgids[@]}")
    GRAPH_CHILD_NODES=("${new_nodes[@]}")
    GRAPH_CHILD_REPORTS=("${new_reports[@]}")
    GRAPH_CHILD_GONE_STREAKS=("${new_streaks[@]}")
  fi
}

# Finalize a harvested child at index with a known exit code. Prints one
# machine-readable line and sets GRAPH_REAP_* globals. Returns 0 when the
# StageOutcomeReport exists, 2 when missing (failure), 1 on bad index.
_graph_schedule_finish_reap_at() {
  local idx="$1"
  local exit_code="$2"
  local node_id report_path

  if [[ -z "$idx" || "$idx" -lt 0 || "$idx" -ge ${#GRAPH_CHILD_PIDS[@]} ]]; then
    echo "Error: reap index out of range: ${idx:-}" >&2
    return 1
  fi

  node_id="${GRAPH_CHILD_NODES[$idx]}"
  report_path="${GRAPH_CHILD_REPORTS[$idx]}"
  _graph_schedule_untrack_at "$idx"

  GRAPH_REAP_NODE="$node_id"
  GRAPH_REAP_EXIT_CODE="$exit_code"
  GRAPH_REAP_REPORT_PATH="$report_path"

  if [[ -f "$report_path" ]]; then
    GRAPH_REAP_REASON=""
    GRAPH_REAP_MISSING_REPORT=0
    printf 'node=%s exit=%s report=%s reason=\n' \
      "$GRAPH_REAP_NODE" "$GRAPH_REAP_EXIT_CODE" "$GRAPH_REAP_REPORT_PATH"
    return 0
  fi

  GRAPH_REAP_REASON="missing-report"
  GRAPH_REAP_MISSING_REPORT=1
  printf 'node=%s exit=%s report=%s reason=missing-report\n' \
    "$GRAPH_REAP_NODE" "$GRAPH_REAP_EXIT_CODE" "$GRAPH_REAP_REPORT_PATH"
  return 2
}

# Wait on a tracked pid at index and finish the reap. Used by the poll path
# and by wait -n fallback when the pid is still a waitable child.
_graph_schedule_wait_and_finish_at() {
  local idx="$1"
  local pid="${GRAPH_CHILD_PIDS[$idx]}"
  local ec=0
  wait "$pid" || ec=$?
  _graph_schedule_finish_reap_at "$idx" "$ec"
}

# After wait -n: locate a gone child, harvest it. wn_ec is the exit status
# returned by wait -n (belongs to exactly one already-reaped pid when wait -n
# succeeded). When job control already notified the child, wait -n may return
# 127 while wait "$pid" still yields the real status.
_graph_schedule_reap_after_wait_n() {
  local wn_ec="$1"
  local i pid w_ec
  local wn_consumed=0

  for ((i = 0; i < ${#GRAPH_CHILD_PIDS[@]}; i++)); do
    pid="${GRAPH_CHILD_PIDS[$i]}"
    if kill -0 "$pid" 2>/dev/null; then
      continue
    fi
    # Process table says gone. Prefer wait to harvest; if wait -n already
    # reaped this pid, wait returns 127 and we consume wn_ec once.
    w_ec=0
    if wait "$pid" 2>/dev/null; then
      w_ec=0
    else
      w_ec=$?
    fi
    if [[ "$w_ec" -eq 127 ]]; then
      if [[ "$wn_consumed" -eq 0 ]]; then
        w_ec="$wn_ec"
        wn_consumed=1
      else
        # Already-reaped pid with no remaining wait -n status: treat as failure.
        w_ec=1
      fi
    fi
    _graph_schedule_finish_reap_at "$i" "$w_ec"
    return $?
  done

  # wait -n returned but no tracked pid looks gone yet (transient). Fall back
  # to one poll-path observation cycle rather than hanging on a lost status.
  return 1
}

_graph_schedule_reap_wait_n_fast() {
  # Prefer wait -n (bash 4.3+) then identify the finished child by scanning
  # tracked pids. Avoid wait -n -p: under job-control shells (bats, set -m)
  # a SIGKILL'd child can be notified before wait -n runs, leaving -p's
  # varname unset and tripping set -u.
  local wn_ec=0 rc
  wait -n || wn_ec=$?
  rc=0
  _graph_schedule_reap_after_wait_n "$wn_ec" || rc=$?
  if [[ "$rc" -eq 0 || "$rc" -eq 2 ]]; then
    return "$rc"
  fi
  return 1
}

_graph_schedule_reap_poll_once() {
  local i pid streak required
  required="${GRAPH_REAP_GONE_STREAK_REQUIRED:-3}"
  [[ "$required" =~ ^[0-9]+$ ]] || required=3
  if [[ "$required" -lt 1 ]]; then
    required=1
  fi

  for ((i = 0; i < ${#GRAPH_CHILD_PIDS[@]}; i++)); do
    pid="${GRAPH_CHILD_PIDS[$i]}"
    if kill -0 "$pid" 2>/dev/null; then
      GRAPH_CHILD_GONE_STREAKS[$i]=0
      continue
    fi
    streak=$(( ${GRAPH_CHILD_GONE_STREAKS[$i]} + 1 ))
    GRAPH_CHILD_GONE_STREAKS[$i]="$streak"
    if [[ "$streak" -ge "$required" ]]; then
      _graph_schedule_wait_and_finish_at "$i"
      return $?
    fi
  done
  return 1
}

# graph_schedule_reap_one
#
# Block until one tracked child can be harvested. Sets GRAPH_REAP_NODE,
# GRAPH_REAP_EXIT_CODE, GRAPH_REAP_REPORT_PATH, GRAPH_REAP_REASON,
# GRAPH_REAP_MISSING_REPORT and prints one node=... line on stdout.
#
# Returns:
#   0  harvested; StageOutcomeReport present
#   2  harvested; report missing (failure — SIGKILL or writer bug)
#   1  no tracked children / internal error
graph_schedule_reap_one() {
  local poll_interval rc

  if [[ ${#GRAPH_CHILD_PIDS[@]} -eq 0 ]]; then
    echo "Error: graph_schedule_reap_one called with no tracked children" >&2
    return 1
  fi

  poll_interval="${GRAPH_REAP_POLL_INTERVAL:-0.25}"

  # wait -n cannot be interrupted to admit broker work. When delegation is
  # enabled use the portable poll path so a live parent can wait while its
  # child is admitted and reaped by the same scheduler.
  if _graph_schedule_reap_supports_wait_n && [[ "${GRAPH_SCHEDULE_DELEGATION_ACTIVE:-0}" -eq 0 ]]; then
    while [[ ${#GRAPH_CHILD_PIDS[@]} -gt 0 ]]; do
      rc=0
      _graph_schedule_reap_wait_n_fast || rc=$?
      # finish_reap returns 0 or 2; those are terminal for this call.
      if [[ "$rc" -eq 0 || "$rc" -eq 2 ]]; then
        return "$rc"
      fi
      # Transient miss after wait -n: brief poll before waiting again.
      rc=0
      _graph_schedule_reap_poll_once || rc=$?
      if [[ "$rc" -eq 0 || "$rc" -eq 2 ]]; then
        return "$rc"
      fi
      sleep "$poll_interval"
    done
    return 1
  fi

  # Portable bash 3.2 path (and GRAPH_REAP_FORCE_POLL=1).
  while [[ ${#GRAPH_CHILD_PIDS[@]} -gt 0 ]]; do
    graph_schedule_drain_delegated_children
    rc=0
    _graph_schedule_reap_poll_once || rc=$?
    if [[ "$rc" -eq 0 || "$rc" -eq 2 ]]; then
      return "$rc"
    fi
    sleep "$poll_interval"
  done
  return 1
}

# graph_schedule_run_node <graph_json_path> <node_id> <run_id> <attempt_number> <workspace>
#
# Dispatch a single node out-of-process (synchronous). The ready-set loop uses
# _graph_schedule_spawn_node for background execution instead.
# Prints the minted attempt id on stdout (via graph_dispatch_run_node).
graph_schedule_run_node() {
  graph_dispatch_run_node "$@"
}

# ---------------------------------------------------------------------------
# Kahn ready-set scheduling loop
#
# Ready set = remaining indegree 0 and state pending. Spawn ready nodes in the
# background up to the global cap (GRAPH_SCHEDULE_MAX_PARALLEL from .graph.json
# maxParallel, overridable via RALPH_GRAPH_MAX_PARALLEL) and the per-runtime
# cap (default 1, overridable via RALPH_GRAPH_MAX_PARALLEL_PER_RUNTIME). A node
# with resolved subagents=on consumes its runtime's entire per-runtime
# allowance for the duration of the node so sibling same-runtime nodes cannot
# interleave overlay install/restore with uncounted subagent processes. Reap
# with graph_schedule_reap_one, and on StageOutcomeReport success decrement each
# successor's remaining indegree. Exit 0 only when every node reached a
# successful terminal state (succeeded or scheduler-owned conditional skip).
# On ordinary failure: stop dispatch, apply failurePolicy (drain
# waits for in-flight; cancel SIGTERMs child process groups), mark transitive
# descendants blocked (unless reachable by another path that avoids the failed
# node), and exit with the failed node's exit code. Exit code 3 (human ack) is
# non-blocking: mark awaiting-ack only on that node and keep scheduling siblings.
# ---------------------------------------------------------------------------

# Print ready node ids (one per line) in stable index order.
graph_schedule_ready_ids() {
  local i
  for ((i = 0; i < ${#GRAPH_NODE_IDS[@]}; i++)); do
    if [[ "${GRAPH_NODE_STATES[$i]}" == "pending" && "${GRAPH_NODE_REMAINING_INDEGREE[$i]}" -eq 0 ]]; then
      printf '%s\n' "${GRAPH_NODE_IDS[$i]}"
    fi
  done
}

_graph_schedule_all_succeeded() {
  local i
  for ((i = 0; i < ${#GRAPH_NODE_STATES[@]}; i++)); do
    if [[ "${GRAPH_NODE_STATES[$i]}" != "succeeded" && "${GRAPH_NODE_STATES[$i]}" != "skipped" ]]; then
      return 1
    fi
  done
  return 0
}

_graph_schedule_count_running() {
  local i count=0
  for ((i = 0; i < ${#GRAPH_NODE_STATES[@]}; i++)); do
    if [[ "${GRAPH_NODE_STATES[$i]}" == "running" ]]; then
      count=$((count + 1))
    fi
  done
  printf '%s\n' "$count"
}

_graph_schedule_count_active_invocations() {
  printf '%s\n' $(( $(_graph_schedule_count_running) + ${#GRAPH_DELEGATION_CHILD_PIDS[@]} ))
}

# Resolve a positive integer env override; prints default when unset/invalid.
_graph_schedule_positive_int_or_default() {
  local raw="$1"
  local default="$2"
  if [[ "$raw" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s\n' "$raw"
  else
    printf '%s\n' "$default"
  fi
}

# Set GRAPH_RUNTIME_LOOKUP_IDX when runtime is present; return 1 when missing.
# Must not run in a command-substitution subshell (mutators share this map).
_graph_schedule_runtime_map_index() {
  local runtime="$1" i
  GRAPH_RUNTIME_LOOKUP_IDX=""
  for ((i = 0; i < ${#GRAPH_RUNTIME_KEYS[@]}; i++)); do
    if [[ "${GRAPH_RUNTIME_KEYS[$i]}" == "$runtime" ]]; then
      GRAPH_RUNTIME_LOOKUP_IDX="$i"
      return 0
    fi
  done
  return 1
}

# Ensure a runtime occupancy row exists. Sets GRAPH_RUNTIME_LOOKUP_IDX.
# Never call via $() — array appends must mutate the scheduler shell.
_graph_schedule_runtime_ensure() {
  local runtime="$1"
  if _graph_schedule_runtime_map_index "$runtime"; then
    return 0
  fi
  GRAPH_RUNTIME_KEYS+=("$runtime")
  GRAPH_RUNTIME_USED_SLOTS+=("0")
  GRAPH_RUNTIME_EXCLUSIVE_NODE+=("")
  GRAPH_RUNTIME_LOOKUP_IDX=$(( ${#GRAPH_RUNTIME_KEYS[@]} - 1 ))
  return 0
}

# Unsafe and unknown adapters remain serialized even when a larger cap is
# requested. Snapshot/worktree agent workspaces never change this decision.
_graph_schedule_runtime_cap() {
  local runtime="$1" cap="$GRAPH_SCHEDULE_MAX_PARALLEL_PER_RUNTIME"
  if graph_runtime_same_runtime_parallel_safe "$runtime"; then
    [[ "$cap" -le "$GRAPH_SCHEDULE_MAX_PARALLEL" ]] || cap="$GRAPH_SCHEDULE_MAX_PARALLEL"
    [[ "$cap" -le "$GRAPH_SCHEDULE_TOKEN_CAP" ]] || cap="$GRAPH_SCHEDULE_TOKEN_CAP"
    printf '%s\n' "$cap"
  else
    printf '1\n'
  fi
}

# Native-subagent parents reserve the runtime's entire effective allowance.
# Other nodes and broker children consume one slot.
_graph_schedule_slots_for_node() {
  local runtime="$1" subagents="$2" native_parallel="${3:-0}"
  if [[ "$subagents" == "on" ]]; then
    if [[ "$native_parallel" =~ ^[1-9][0-9]*$ ]]; then
      # The parent is one model invocation in addition to its declared child
      # concurrency. Admission preflight rejects an allowance that cannot fit.
      printf '%s\n' $(( native_parallel + 1 ))
    else
      _graph_schedule_runtime_cap "$runtime"
    fi
  else
    printf '1\n'
  fi
}

_graph_schedule_runtime_reserve_slots() {
  local runtime="$1" slots="$2" token_slots="${3:-$2}"
  _graph_schedule_runtime_ensure "$runtime" || return 1
  GRAPH_RUNTIME_USED_SLOTS[$GRAPH_RUNTIME_LOOKUP_IDX]=$(( ${GRAPH_RUNTIME_USED_SLOTS[$GRAPH_RUNTIME_LOOKUP_IDX]:-0} + slots ))
  GRAPH_SCHEDULE_USED_TOKEN_SLOTS=$(( GRAPH_SCHEDULE_USED_TOKEN_SLOTS + token_slots ))
}

_graph_schedule_runtime_release_slots() {
  local runtime="$1" slots="${2:-0}" token_slots="${3:-0}"
  [[ -n "$runtime" ]] || return 0
  if _graph_schedule_runtime_map_index "$runtime"; then
    GRAPH_RUNTIME_USED_SLOTS[$GRAPH_RUNTIME_LOOKUP_IDX]=$(( ${GRAPH_RUNTIME_USED_SLOTS[$GRAPH_RUNTIME_LOOKUP_IDX]:-0} - slots ))
    [[ "${GRAPH_RUNTIME_USED_SLOTS[$GRAPH_RUNTIME_LOOKUP_IDX]}" -ge 0 ]] || GRAPH_RUNTIME_USED_SLOTS[$GRAPH_RUNTIME_LOOKUP_IDX]=0
  fi
  GRAPH_SCHEDULE_USED_TOKEN_SLOTS=$(( GRAPH_SCHEDULE_USED_TOKEN_SLOTS - token_slots ))
  [[ "$GRAPH_SCHEDULE_USED_TOKEN_SLOTS" -ge 0 ]] || GRAPH_SCHEDULE_USED_TOKEN_SLOTS=0
}

# JSONL audit for every admitted, denied, and released model invocation.
# tokenSlots represent concurrent token streams, not predicted final usage.
_graph_schedule_log_admission() {
  local decision="$1" kind="$2" owner="$3" runtime="$4" subagents="$5" slots="$6" token_slots="$7" reason="$8"
  [[ -n "${GRAPH_SCHEDULE_ADMISSION_LOG_FILE:-}" ]] || return 0
  local safe=false effective isolation used=0
  graph_runtime_same_runtime_parallel_safe "$runtime" && safe=true
  effective="$(_graph_schedule_runtime_cap "$runtime")"
  isolation="$(graph_runtime_overlay_isolation "$runtime")"
  if _graph_schedule_runtime_map_index "$runtime"; then used="${GRAPH_RUNTIME_USED_SLOTS[$GRAPH_RUNTIME_LOOKUP_IDX]:-0}"; fi
  jq -cn --arg ts "$(graph_state_now_iso)" --arg event admission --arg decision "$decision" \
    --arg workKind "$kind" --arg ownerId "$owner" --arg runtime "$runtime" --arg subagents "$subagents" \
    --arg isolation "$isolation" --arg reason "$reason" --argjson sameRuntimeParallelSafe "$safe" \
    --argjson requestedRuntimeCap "$GRAPH_SCHEDULE_MAX_PARALLEL_PER_RUNTIME" --argjson effectiveRuntimeCap "$effective" \
    --argjson runtimeUsed "$used" --argjson runtimeSlots "$slots" --argjson tokenUsed "$GRAPH_SCHEDULE_USED_TOKEN_SLOTS" \
    --argjson tokenSlots "$token_slots" --argjson tokenCap "$GRAPH_SCHEDULE_TOKEN_CAP" \
    '{timestamp:$ts,event:$event,decision:$decision,workKind:$workKind,ownerId:$ownerId,runtime:$runtime,subagents:$subagents,sameRuntimeParallelSafe:$sameRuntimeParallelSafe,overlayIsolation:$isolation,requestedRuntimeCap:$requestedRuntimeCap,effectiveRuntimeCap:$effectiveRuntimeCap,runtimeUsed:$runtimeUsed,runtimeSlots:$runtimeSlots,tokenUsed:$tokenUsed,tokenSlots:$tokenSlots,tokenCap:$tokenCap,reason:$reason}' \
    >>"$GRAPH_SCHEDULE_ADMISSION_LOG_FILE" 2>/dev/null || true
}

# Returns 0 when the node can be admitted under runtime and token-stream caps.
_graph_schedule_runtime_can_admit() {
  local runtime="$1" subagents="$2" token_slots="${3:-}" native_parallel="${4:-0}"
  local used exclusive slots_needed effective_cap

  _graph_schedule_runtime_ensure "$runtime" || return 1
  used="${GRAPH_RUNTIME_USED_SLOTS[$GRAPH_RUNTIME_LOOKUP_IDX]:-0}"
  exclusive="${GRAPH_RUNTIME_EXCLUSIVE_NODE[$GRAPH_RUNTIME_LOOKUP_IDX]:-}"
  [[ -z "$exclusive" ]] || return 1
  slots_needed="$(_graph_schedule_slots_for_node "$runtime" "$subagents" "$native_parallel")"
  [[ "$token_slots" =~ ^[1-9][0-9]*$ ]] || token_slots="$slots_needed"
  effective_cap="$(_graph_schedule_runtime_cap "$runtime")"
  [[ $(( used + slots_needed )) -le "$effective_cap" ]] || return 1
  [[ $(( GRAPH_SCHEDULE_USED_TOKEN_SLOTS + token_slots )) -le "$GRAPH_SCHEDULE_TOKEN_CAP" ]] || return 1
  return 0
}

_graph_schedule_runtime_reserve() {
  local node_id="$1"
  local runtime="$2"
  local subagents="$3"
  local slots_needed idx native_parallel=0

  if idx="$(graph_schedule_index_map_get "$node_id")"; then
    native_parallel="${GRAPH_NODE_NATIVE_PARALLEL[$idx]:-0}"
  fi
  if ! _graph_schedule_runtime_can_admit "$runtime" "$subagents" "" "$native_parallel"; then
    echo "Error: runtime $runtime cannot admit node $node_id (subagents=$subagents)" >&2
    return 1
  fi
  _graph_schedule_runtime_ensure "$runtime" || return 1
  slots_needed="$(_graph_schedule_slots_for_node "$runtime" "$subagents" "$native_parallel")"
  _graph_schedule_runtime_reserve_slots "$runtime" "$slots_needed" "$slots_needed" || return 1
  if [[ "$subagents" == "on" ]]; then
    GRAPH_RUNTIME_EXCLUSIVE_NODE[$GRAPH_RUNTIME_LOOKUP_IDX]="$node_id"
    echo "graph-schedule: node=$node_id subagents=on reserves runtime=$runtime allowance=$slots_needed" >&2
  fi
  if [[ -z "$idx" ]]; then
    echo "Error: unknown graph node id: $node_id" >&2
    return 1
  fi
  GRAPH_NODE_HELD_SLOTS[$idx]="$slots_needed"
  GRAPH_NODE_HELD_TOKEN_SLOTS[$idx]="$slots_needed"
  _graph_schedule_log_admission "admitted" "graph-node" "$node_id" "$runtime" "$subagents" "$slots_needed" "$slots_needed" "runtime-and-token-cap"
  return 0
}

# Release per-runtime slots for a node that reached any terminal state
# (success, failure, cancellation, missing report). Safe to call when the node
# held zero slots.
_graph_schedule_runtime_release() {
  local node_id="$1"
  local idx runtime held held_tokens exclusive

  if ! idx="$(graph_schedule_index_map_get "$node_id")"; then
    return 0
  fi
  held="${GRAPH_NODE_HELD_SLOTS[$idx]:-0}"
  held_tokens="${GRAPH_NODE_HELD_TOKEN_SLOTS[$idx]:-0}"
  [[ "$held" =~ ^[0-9]+$ ]] || held=0
  if [[ "$held" -eq 0 ]]; then
    return 0
  fi
  runtime="${GRAPH_NODE_RUNTIMES[$idx]}"
  if ! _graph_schedule_runtime_map_index "$runtime"; then
    GRAPH_NODE_HELD_SLOTS[$idx]="0"
    return 0
  fi
  _graph_schedule_runtime_release_slots "$runtime" "$held" "$held_tokens"
  exclusive="${GRAPH_RUNTIME_EXCLUSIVE_NODE[$GRAPH_RUNTIME_LOOKUP_IDX]:-}"
  if [[ "$exclusive" == "$node_id" ]]; then
    GRAPH_RUNTIME_EXCLUSIVE_NODE[$GRAPH_RUNTIME_LOOKUP_IDX]=""
  fi
  GRAPH_NODE_HELD_SLOTS[$idx]="0"
  GRAPH_NODE_HELD_TOKEN_SLOTS[$idx]="0"
  _graph_schedule_log_admission "released" "graph-node" "$node_id" "$runtime" "${GRAPH_NODE_SUBAGENTS[$idx]}" "$held" "$held_tokens" "terminal-state"
  return 0
}

_graph_schedule_session_key_for_node() {
  local node_id="$1"
  local base="${GRAPH_SCHEDULE_PLAN_KEY:-$GRAPH_SCHEDULE_NAMESPACE}"
  local key="${base}-${node_id}"
  key="$(printf '%s' "$key" | sed 's/[^A-Za-z0-9_.-]/_/g')"
  printf '%s\n' "$key"
}

# Returns 0 when the StageOutcomeReport at path records outcome=success.
_graph_schedule_report_is_success() {
  local report_path="$1"
  local outcome
  if [[ -z "$report_path" || ! -f "$report_path" ]]; then
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required to read StageOutcomeReport" >&2
    return 1
  fi
  outcome="$(jq -r '.outcome // empty' "$report_path" 2>/dev/null)" || return 1
  [[ "$outcome" == "success" ]]
}

_graph_schedule_report_exit_code() {
  local report_path="$1"
  local ec
  ec="$(jq -r '.exitCode // empty' "$report_path" 2>/dev/null)" || true
  if [[ "$ec" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$ec"
  else
    printf '%s\n' "1"
  fi
}

# Decrement remaining indegree for each successor of node_id.
_graph_schedule_release_successors() {
  local node_id="$1"
  local succ_str succ to_idx
  succ_str="$(graph_schedule_node_successors_by_id "$node_id")" || return 1
  [[ -z "$succ_str" ]] && return 0
  local IFS="$GRAPH_SUCCESSOR_DELIM"
  # shellcheck disable=SC2086
  for succ in $succ_str; do
    [[ -z "$succ" ]] && continue
    if ! to_idx="$(graph_schedule_index_map_get "$succ")"; then
      echo "Error: successor references unknown node: $succ (from $node_id)" >&2
      return 1
    fi
    if [[ "${GRAPH_NODE_REMAINING_INDEGREE[$to_idx]}" -gt 0 ]]; then
      GRAPH_NODE_REMAINING_INDEGREE[$to_idx]=$(( ${GRAPH_NODE_REMAINING_INDEGREE[$to_idx]} - 1 ))
    fi
  done
  return 0
}

# Mark non-selected router branches as skipped and cascade the skip to
# descendants that have no other satisfied (succeeded) inbound path.
#
# Args:
#   router_node_id   - the router node that just succeeded
#   selected_target  - the allowedTarget chosen by the router decision
#   allowed_targets  - space-separated list of all allowedTargets
#
# The router's _graph_schedule_release_successors has already been called
# (decrementing remaining indegrees of the router's direct successors).
# For each skipped node we also release its own successors so the cascade
# can propagate without leaving pending nodes stuck at indegree > 0.
_graph_schedule_mark_router_skipped() {
  local router_node_id="$1"
  local selected_target="$2"
  local allowed_targets="$3"

  local worklist=() wi=0
  local target idx state succ_str succ to_idx

  # Seed the worklist with the non-selected allowedTargets.
  local t
  for t in $allowed_targets; do
    [[ -z "$t" || "$t" == "$selected_target" ]] && continue
    if ! idx="$(graph_schedule_index_map_get "$t" 2>/dev/null)"; then
      echo "graph-schedule: router skip: unknown allowedTarget $t (ignored)" >&2
      continue
    fi
    state="${GRAPH_NODE_STATES[$idx]}"
    if [[ "$state" != "pending" ]]; then
      echo "graph-schedule: router skip: branch $t already in state $state; not skipping" >&2
      continue
    fi
    worklist+=("$t")
  done

  while [[ "$wi" -lt "${#worklist[@]}" ]]; do
    local cur="${worklist[$wi]}"
    wi=$(( wi + 1 ))

    if ! idx="$(graph_schedule_index_map_get "$cur" 2>/dev/null)"; then
      continue
    fi
    state="${GRAPH_NODE_STATES[$idx]}"
    if [[ "$state" != "pending" ]]; then
      continue
    fi

    GRAPH_NODE_STATES[$idx]="skipped"
    _graph_schedule_ledger_record "$cur" "skipped" \
      "" "" "" "" "" "" "" "router-skip:$router_node_id"
    echo "graph-schedule: node=$cur skipped by router $router_node_id (selected=$selected_target)" >&2

    # Release the skipped node's successors so they can become ready if
    # they have other live predecessors. Track how many of each successor's
    # predecessors have been skipped (skip_predecessor_count). A successor
    # with skip_predecessor_count == total_indegree has exclusively-skipped
    # predecessors and should be cascade-skipped too.
    #
    # Traverse both unconditional (GRAPH_NODE_SUCCESSORS) and conditional
    # (GRAPH_NODE_COND_SUCCESSORS) successors of the skipped node so the
    # cascade propagates through conditional branches as well.
    local old_ifs="$IFS"
    local succ_lists=("${GRAPH_NODE_SUCCESSORS[$idx]:-}" "${GRAPH_NODE_COND_SUCCESSORS[$idx]:-}")
    local sl cond_succ cond_node
    for sl in "${succ_lists[@]}"; do
      [[ -z "$sl" ]] && continue
      IFS="$GRAPH_SUCCESSOR_DELIM"
      # shellcheck disable=SC2086
      for succ in $sl; do
        IFS="$old_ifs"
        [[ -z "$succ" ]] && continue
        # Conditional entries are "condition:node_id"; extract node_id.
        case "$succ" in
          passed:*|changes-required:*|error:*) cond_node="${succ#*:}" ;;
          *) cond_node="$succ" ;;
        esac
        if ! to_idx="$(graph_schedule_index_map_get "$cond_node" 2>/dev/null)"; then
          IFS="$GRAPH_SUCCESSOR_DELIM"
          continue
        fi
        # Increment the skip-predecessor count for this successor.
        GRAPH_NODE_SKIP_PREDECESSOR_COUNT[$to_idx]=$(( ${GRAPH_NODE_SKIP_PREDECESSOR_COUNT[$to_idx]:-0} + 1 ))
        if [[ "${GRAPH_NODE_REMAINING_INDEGREE[$to_idx]}" -gt 0 ]]; then
          GRAPH_NODE_REMAINING_INDEGREE[$to_idx]=$(( ${GRAPH_NODE_REMAINING_INDEGREE[$to_idx]} - 1 ))
        fi
        # Cascade: a pending successor with remaining_indegree=0 AND all its
        # predecessors skipped (skip_count == total_indegree) is exclusively
        # reachable through skipped nodes -> also skip it.
        if [[ "${GRAPH_NODE_STATES[$to_idx]}" == "pending" && \
              "${GRAPH_NODE_REMAINING_INDEGREE[$to_idx]}" -eq 0 && \
              "${GRAPH_NODE_SKIP_PREDECESSOR_COUNT[$to_idx]:-0}" -eq "${GRAPH_NODE_INDEGREES[$to_idx]}" ]]; then
          worklist+=("$cond_node")
        fi
        IFS="$GRAPH_SUCCESSOR_DELIM"
      done
      IFS="$old_ifs"
    done
  done
  return 0
}

# _graph_schedule_skip_cond_branches <origin_node_id> <outcome> <node_to_skip...>
#
# Mark a list of conditional branch nodes as skipped (with cascade) when their
# condition did not match the producing node's semantic outcome. This reuses
# the same skip-predecessor-count cascade as _graph_schedule_mark_router_skipped
# so unselected conditional branches propagate the skip through their own
# descendants (both unconditional and conditional).
_graph_schedule_skip_cond_branches() {
  local origin_id="$1" outcome="$2"
  shift 2
  local targets_to_skip=("$@")
  local worklist=() wi=0
  local t idx state succ sl cond_node to_idx old_ifs

  for t in "${targets_to_skip[@]}"; do
    [[ -z "$t" ]] && continue
    if ! idx="$(graph_schedule_index_map_get "$t" 2>/dev/null)"; then
      echo "graph-schedule: conditional skip: unknown target $t (ignored)" >&2
      continue
    fi
    state="${GRAPH_NODE_STATES[$idx]}"
    if [[ "$state" != "pending" ]]; then
      echo "graph-schedule: conditional skip: $t already in state $state; not skipping" >&2
      continue
    fi
    # This is one skipped predecessor edge into $t, not a verdict on $t
    # itself: $t may have other live predecessors, e.g. a repair-epoch join
    # fed by several mutually-exclusive gate/regate "passed" edges (only one
    # round's gate ever actually fires "passed"). Account for this edge the
    # same way the cascade below accounts for its own descendants, and only
    # transition $t to skipped -- and cascade further -- once every one of
    # its predecessors has been accounted for as skipped. A predecessor that
    # later releases $t via a matching outcome decrements remaining indegree
    # through the ordinary release path and is unaffected by this accounting.
    GRAPH_NODE_SKIP_PREDECESSOR_COUNT[$idx]=$(( ${GRAPH_NODE_SKIP_PREDECESSOR_COUNT[$idx]:-0} + 1 ))
    if [[ "${GRAPH_NODE_REMAINING_INDEGREE[$idx]}" -gt 0 ]]; then
      GRAPH_NODE_REMAINING_INDEGREE[$idx]=$(( ${GRAPH_NODE_REMAINING_INDEGREE[$idx]} - 1 ))
    fi
    if [[ "${GRAPH_NODE_REMAINING_INDEGREE[$idx]}" -eq 0 && \
          "${GRAPH_NODE_SKIP_PREDECESSOR_COUNT[$idx]:-0}" -eq "${GRAPH_NODE_INDEGREES[$idx]}" ]]; then
      worklist+=("$t")
    fi
  done

  while [[ "$wi" -lt "${#worklist[@]}" ]]; do
    local cur="${worklist[$wi]}"
    wi=$(( wi + 1 ))

    if ! idx="$(graph_schedule_index_map_get "$cur" 2>/dev/null)"; then continue; fi
    state="${GRAPH_NODE_STATES[$idx]}"
    if [[ "$state" != "pending" ]]; then continue; fi

    GRAPH_NODE_STATES[$idx]="skipped"
    _graph_schedule_ledger_record "$cur" "skipped" \
      "" "" "" "" "" "" "" "conditional-skip:$origin_id:outcome=$outcome"
    echo "graph-schedule: node=$cur skipped (conditional-skip from $origin_id outcome=$outcome)" >&2

    old_ifs="$IFS"
    local succ_lists=("${GRAPH_NODE_SUCCESSORS[$idx]:-}" "${GRAPH_NODE_COND_SUCCESSORS[$idx]:-}")
    for sl in "${succ_lists[@]}"; do
      [[ -z "$sl" ]] && continue
      IFS="$GRAPH_SUCCESSOR_DELIM"
      # shellcheck disable=SC2086
      for succ in $sl; do
        IFS="$old_ifs"
        [[ -z "$succ" ]] && continue
        case "$succ" in
          passed:*|changes-required:*|error:*) cond_node="${succ#*:}" ;;
          *) cond_node="$succ" ;;
        esac
        if ! to_idx="$(graph_schedule_index_map_get "$cond_node" 2>/dev/null)"; then
          IFS="$GRAPH_SUCCESSOR_DELIM"
          continue
        fi
        GRAPH_NODE_SKIP_PREDECESSOR_COUNT[$to_idx]=$(( ${GRAPH_NODE_SKIP_PREDECESSOR_COUNT[$to_idx]:-0} + 1 ))
        if [[ "${GRAPH_NODE_REMAINING_INDEGREE[$to_idx]}" -gt 0 ]]; then
          GRAPH_NODE_REMAINING_INDEGREE[$to_idx]=$(( ${GRAPH_NODE_REMAINING_INDEGREE[$to_idx]} - 1 ))
        fi
        if [[ "${GRAPH_NODE_STATES[$to_idx]}" == "pending" && \
              "${GRAPH_NODE_REMAINING_INDEGREE[$to_idx]}" -eq 0 && \
              "${GRAPH_NODE_SKIP_PREDECESSOR_COUNT[$to_idx]:-0}" -eq "${GRAPH_NODE_INDEGREES[$to_idx]}" ]]; then
          worklist+=("$cond_node")
        fi
        IFS="$GRAPH_SUCCESSOR_DELIM"
      done
      IFS="$old_ifs"
    done
  done
  return 0
}

# _graph_schedule_apply_conditional_outcome <node_id> <outcome>
#
# Apply a node's semantic outcome to its successors. Unconditional successors
# are always released. Conditional successors with a matching condition are
# released; non-matching conditional successors are marked skipped (cascade).
#
# Returns 0 on success. Returns 1 if an error prevents releasing a required
# matching conditional successor (caller must then apply failurePolicy).
# Returns 2 if the outcome is "changes-required" and no conditional(changes-
# required) successor exists; caller must fail closed.
_graph_schedule_apply_conditional_outcome() {
  local node_id="$1" outcome="$2"
  local idx cond_succ_str succ cond node_to to_idx old_ifs
  local matching_cond_count=0
  local skip_targets=()

  # Release unconditional successors (existing behavior, unchanged).
  if ! _graph_schedule_release_successors "$node_id"; then
    return 1
  fi

  if ! idx="$(graph_schedule_index_map_get "$node_id")"; then
    return 1
  fi

  cond_succ_str="${GRAPH_NODE_COND_SUCCESSORS[$idx]:-}"
  if [[ -z "$cond_succ_str" ]]; then
    [[ "$outcome" == "changes-required" ]] && return 2
    return 0
  fi

  old_ifs="$IFS"
  IFS="$GRAPH_SUCCESSOR_DELIM"
  # shellcheck disable=SC2086
  for succ in $cond_succ_str; do
    IFS="$old_ifs"
    [[ -z "$succ" ]] && continue
    cond="${succ%%:*}"
    node_to="${succ#*:}"
    if [[ "$cond" == "$outcome" ]]; then
      # Matching condition: release this successor's remaining indegree slot.
      if to_idx="$(graph_schedule_index_map_get "$node_to" 2>/dev/null)"; then
        if [[ "${GRAPH_NODE_REMAINING_INDEGREE[$to_idx]}" -gt 0 ]]; then
          GRAPH_NODE_REMAINING_INDEGREE[$to_idx]=$(( ${GRAPH_NODE_REMAINING_INDEGREE[$to_idx]} - 1 ))
        fi
        matching_cond_count=$(( matching_cond_count + 1 ))
        echo "graph-schedule: node=$node_to released by conditional outcome=$outcome from $node_id" >&2
      fi
    else
      # Non-matching condition: queue this branch for skipping.
      skip_targets+=("$node_to")
    fi
    IFS="$GRAPH_SUCCESSOR_DELIM"
  done
  IFS="$old_ifs"

  # Skip all non-matching conditional branches.
  if [[ "${#skip_targets[@]}" -gt 0 ]]; then
    _graph_schedule_skip_cond_branches "$node_id" "$outcome" "${skip_targets[@]}"
  fi

  # For changes-required specifically: if no conditional(changes-required)
  # edge exists, the caller should fail closed. Signal this with return 2.
  if [[ "$outcome" == "changes-required" && "$matching_cond_count" -eq 0 ]]; then
    return 2
  fi

  return 0
}

# Resolve and apply a router node's decision in graph mode.
# Reads the router config and decision artifact from the graph JSON, resolves
# the selected target, and marks unselected branches (and their exclusive
# descendants) as skipped. Calls _graph_schedule_mark_router_skipped.
#
# Args:
#   node_id    - the router node id
#   graph_json - path to the graph JSON (usually GRAPH_SCHEDULE_GRAPH_JSON)
#   workspace  - run workspace (for artifact path resolution)
_graph_schedule_apply_router_decision() {
  local node_id="$1"
  local graph_json="$2"
  local workspace="$3"

  local py router_json artifact_rel artifact_abs resolved_json
  local selected_target selected_kind allowed_targets_json allowed_targets

  if ! command -v python3 >/dev/null 2>&1; then
    echo "graph-schedule: router decision: python3 required for router dispatch" >&2
    return 1
  fi

  py=""
  local dir
  for dir in "${RALPH_ACTIVE_DIR:-}" "${RALPH_DIR:-}"; do
    [[ -n "$dir" && -f "$dir/python/router_contract.py" ]] || continue
    py="$dir/python/router_contract.py"
    break
  done
  if [[ -z "$py" ]]; then
    echo "graph-schedule: router decision: router_contract.py not found" >&2
    return 1
  fi

  # Read router config from the graph JSON node's stage.
  router_json="$(jq -c --arg id "$node_id" \
    '.nodes[] | select(.id == $id) | .stage.router' \
    "$graph_json" 2>/dev/null || echo "")"
  if [[ -z "$router_json" || "$router_json" == "null" ]]; then
    echo "graph-schedule: router decision: no router config found for node $node_id" >&2
    return 1
  fi

  allowed_targets_json="$(printf '%s' "$router_json" | \
    jq -r '.allowedTargets[]?' 2>/dev/null || echo "")"
  if [[ -z "$allowed_targets_json" ]]; then
    echo "graph-schedule: router decision: no allowedTargets in router config for $node_id" >&2
    return 1
  fi
  # Convert newline-separated ids to a space-separated string for the worklist.
  allowed_targets="$(printf '%s' "$allowed_targets_json" | tr '\n' ' ')"

  # Find the decision artifact path.
  artifact_rel="$(jq -r --arg id "$node_id" '
    .nodes[] | select(.id == $id) | .stage |
    [(.artifacts // []), (.outputArtifacts // [])] | add |
    map(select((.schema // "") | test("router-decision\\.schema\\.json$"))) |
    first // null |
    if . == null then
      [(.artifacts // []), (.outputArtifacts // [])] | add |
      map(select((.path // "") | test("\\.json$"))) |
      first // null |
      if . == null then empty else .path end
    else .path end
  ' "$graph_json" 2>/dev/null || echo "")"

  if [[ -z "$artifact_rel" || "$artifact_rel" == "null" ]]; then
    echo "graph-schedule: router decision: no artifact path found for router node $node_id" >&2
    return 1
  fi

  if [[ "$artifact_rel" == /* ]]; then
    artifact_abs="$artifact_rel"
  else
    artifact_abs="$workspace/$artifact_rel"
  fi

  if [[ ! -f "$artifact_abs" ]]; then
    echo "graph-schedule: router decision: artifact not found: $artifact_abs" >&2
    return 1
  fi

  # Resolve the target in graph mode (no backward/wave restrictions).
  if ! resolved_json="$(python3 "$py" resolve-target \
    --artifact "$artifact_abs" \
    --router-json "$router_json" \
    --stage-index 0 \
    --stage-ids-json "[]" \
    --mode graph 2>&1)"; then
    echo "graph-schedule: router decision: resolve-target failed: $resolved_json" >&2
    return 1
  fi

  selected_target="$(printf '%s' "$resolved_json" | \
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("target",""))' 2>/dev/null || echo "")"
  selected_kind="$(printf '%s' "$resolved_json" | \
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("kind",""))' 2>/dev/null || echo "")"

  if [[ -z "$selected_target" ]]; then
    echo "graph-schedule: router decision: empty target from resolve-target" >&2
    return 1
  fi

  echo "graph-schedule: router $node_id selected target=$selected_target kind=$selected_kind" >&2

  case "$selected_kind" in
    terminal|default-terminal)
      # Terminal outcome: mark all allowedTargets as skipped.
      _graph_schedule_mark_router_skipped "$node_id" "" "$allowed_targets"
      ;;
    stage|default-stage)
      _graph_schedule_mark_router_skipped "$node_id" "$selected_target" "$allowed_targets"
      ;;
    *)
      echo "graph-schedule: router decision: unknown resolution kind: $selected_kind" >&2
      return 1
      ;;
  esac
  return 0
}

# PGID of the scheduler shell. Used to refuse group-kills that would hit us.
_graph_schedule_scheduler_pgid() {
  local pgid
  pgid="$(ps -o pgid= -p "$$" 2>/dev/null | tr -d '[:space:]')" || true
  if [[ "$pgid" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$pgid"
  else
    printf '%s\n' "$$"
  fi
}

# Resolve effective exit code from report then process exit.
_graph_schedule_effective_exit_code() {
  local report_path="$1"
  local process_ec="$2"
  local report_ec=""
  if [[ -n "$report_path" && -f "$report_path" ]]; then
    report_ec="$(_graph_schedule_report_exit_code "$report_path")"
  fi
  if [[ "$report_ec" =~ ^[0-9]+$ && "$report_ec" -ne 0 ]]; then
    printf '%s\n' "$report_ec"
  elif [[ "$process_ec" =~ ^[0-9]+$ && "$process_ec" -ne 0 ]]; then
    printf '%s\n' "$process_ec"
  else
    printf '%s\n' "1"
  fi
}

# Mark GRAPH_NODE_REACHABLE[i]=1 for every node reachable from a root without
# traversing avoid_id. Parallel array sized to GRAPH_NODE_IDS.
_graph_schedule_compute_reachable_avoiding() {
  local avoid_id="$1"
  local i idx succ_str succ to_idx
  local queue=() q_i=0
  GRAPH_NODE_REACHABLE=()
  for ((i = 0; i < ${#GRAPH_NODE_IDS[@]}; i++)); do
    GRAPH_NODE_REACHABLE[$i]=0
  done
  for ((i = 0; i < ${#GRAPH_NODE_IDS[@]}; i++)); do
    if [[ "${GRAPH_NODE_IDS[$i]}" == "$avoid_id" ]]; then
      continue
    fi
    if [[ "${GRAPH_NODE_INDEGREES[$i]}" -eq 0 ]]; then
      GRAPH_NODE_REACHABLE[$i]=1
      queue+=("$i")
    fi
  done
  while [[ "$q_i" -lt "${#queue[@]}" ]]; do
    idx="${queue[$q_i]}"
    q_i=$((q_i + 1))
    local r_sl r_cond_node
    local r_succ_lists=("${GRAPH_NODE_SUCCESSORS[$idx]:-}" "${GRAPH_NODE_COND_SUCCESSORS[$idx]:-}")
    for r_sl in "${r_succ_lists[@]}"; do
      [[ -z "$r_sl" ]] && continue
      local r_old_ifs="$IFS"
      IFS="$GRAPH_SUCCESSOR_DELIM"
      # shellcheck disable=SC2086
      for succ in $r_sl; do
        IFS="$r_old_ifs"
        [[ -z "$succ" ]] && continue
        case "$succ" in
          passed:*|changes-required:*|error:*) r_cond_node="${succ#*:}" ;;
          *) r_cond_node="$succ" ;;
        esac
        [[ "$r_cond_node" == "$avoid_id" ]] && continue
        if ! to_idx="$(graph_schedule_index_map_get "$r_cond_node")"; then
          IFS="$GRAPH_SUCCESSOR_DELIM"
          continue
        fi
        if [[ "${GRAPH_NODE_REACHABLE[$to_idx]}" -eq 1 ]]; then
          IFS="$GRAPH_SUCCESSOR_DELIM"
          continue
        fi
        GRAPH_NODE_REACHABLE[$to_idx]=1
        queue+=("$to_idx")
        IFS="$GRAPH_SUCCESSOR_DELIM"
      done
      IFS="$r_old_ifs"
    done
  done
}

# Mark pending transitive descendants of failed_id as blocked, except those
# still reachable by a path that avoids failed_id (alternate satisfied path).
_graph_schedule_mark_blocked_descendants() {
  local failed_id="$1"
  local queue=() q_i=0
  local cur succ_str succ idx state
  local seen_keys=() seen_vals=()
  local s_i seen
  local old_ifs="$IFS"

  _graph_schedule_compute_reachable_avoiding "$failed_id"

  succ_str="$(graph_schedule_node_successors_by_id "$failed_id")" || return 0
  [[ -z "$succ_str" ]] && return 0
  IFS="$GRAPH_SUCCESSOR_DELIM"
  # shellcheck disable=SC2086
  for succ in $succ_str; do
    [[ -z "$succ" ]] && continue
    queue+=("$succ")
  done
  IFS="$old_ifs"

  while [[ "$q_i" -lt "${#queue[@]}" ]]; do
    cur="${queue[$q_i]}"
    q_i=$((q_i + 1))
    seen=0
    for ((s_i = 0; s_i < ${#seen_keys[@]}; s_i++)); do
      if [[ "${seen_keys[$s_i]}" == "$cur" ]]; then
        seen=1
        break
      fi
    done
    [[ "$seen" -eq 1 ]] && continue
    seen_keys+=("$cur")
    seen_vals+=("1")

    if ! idx="$(graph_schedule_index_map_get "$cur")"; then
      continue
    fi
    state="${GRAPH_NODE_STATES[$idx]}"
    if [[ "$state" == "pending" ]]; then
      if [[ "${GRAPH_NODE_REACHABLE[$idx]:-0}" -eq 0 ]]; then
        GRAPH_NODE_STATES[$idx]="blocked"
        _graph_schedule_ledger_record "$cur" "blocked" \
          "" "" "" "" "" "" "" "ancestor-failed:$failed_id"
        echo "graph-schedule: node=$cur blocked because of failed node=$failed_id" >&2
      fi
    fi
    # Traverse both unconditional and conditional successors during descent.
    local sl cond_node
    local succ_lists=("${GRAPH_NODE_SUCCESSORS[$idx]:-}" "${GRAPH_NODE_COND_SUCCESSORS[$idx]:-}")
    for sl in "${succ_lists[@]}"; do
      [[ -z "$sl" ]] && continue
      IFS="$GRAPH_SUCCESSOR_DELIM"
      # shellcheck disable=SC2086
      for succ in $sl; do
        [[ -z "$succ" ]] && continue
        case "$succ" in
          passed:*|changes-required:*|error:*) cond_node="${succ#*:}" ;;
          *) cond_node="$succ" ;;
        esac
        queue+=("$cond_node")
      done
      IFS="$old_ifs"
    done
  done
  return 0
}

# SIGTERM in-flight child process groups without touching the scheduler PGID.
# Relies on orchestrator EXIT trap → cancelled StageOutcomeReport +
# ralph_process_run_close. Idempotent via GRAPH_SCHEDULE_CANCEL_REQUESTED.
_graph_schedule_cancel_inflight_children() {
  local i pid pgid scheduler_pgid
  if [[ "${GRAPH_SCHEDULE_CANCEL_REQUESTED:-0}" -eq 1 ]]; then
    return 0
  fi
  GRAPH_SCHEDULE_CANCEL_REQUESTED=1
  scheduler_pgid="$(_graph_schedule_scheduler_pgid)"
  echo "graph-schedule: failurePolicy=cancel signalling in-flight children scheduler_pgid=$scheduler_pgid" >&2
  for ((i = 0; i < ${#GRAPH_CHILD_PIDS[@]}; i++)); do
    pid="${GRAPH_CHILD_PIDS[$i]}"
    pgid="${GRAPH_CHILD_PGIDS[$i]:-$pid}"
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    if [[ "$pgid" =~ ^[0-9]+$ && "$pgid" != "$scheduler_pgid" && "$pgid" -gt 1 ]]; then
      echo "graph-schedule: cancel node=${GRAPH_CHILD_NODES[$i]} pgid=$pgid (process group)" >&2
      ralph_kill_process_group "$pgid" "${RALPH_PROCESS_TERM_GRACE_SECONDS:-5}" || true
    else
      # Same PGID as the scheduler (or unknown): never group-kill; tree-kill only.
      echo "graph-schedule: cancel node=${GRAPH_CHILD_NODES[$i]} pid=$pid (tree; refusing scheduler pgid kill)" >&2
      ralph_kill_tree "$pid" || true
    fi
  done
  # A failed/cancelled parent owns all of its brokered children. Individual
  # child cancellation is narrower and never reaches this parent PGID.
  local child_entry child_parent child_did child_status
  while IFS= read -r child_entry; do
    child_parent="$(jq -r .parentNodeId <<<"$child_entry")"; child_did="$(jq -r .delegationId <<<"$child_entry")"
    child_status="$(graph_delegation_ledger_read_status "$GRAPH_SCHEDULE_WORKSPACE" "$GRAPH_SCHEDULE_NAMESPACE" "$GRAPH_SCHEDULE_RUN_ID" "$child_parent" "$child_did" 2>/dev/null | jq -r '.status // empty')"
    [[ "$child_status" == queued || "$child_status" == running ]] && graph_delegation_child_cancel "$GRAPH_SCHEDULE_WORKSPACE" "$GRAPH_SCHEDULE_NAMESPACE" "$GRAPH_SCHEDULE_RUN_ID" "$child_parent" "$child_did" || true
  done < <(graph_delegation_queue_pending "$GRAPH_SCHEDULE_WORKSPACE" "$GRAPH_SCHEDULE_NAMESPACE" "$GRAPH_SCHEDULE_RUN_ID")
  # If this shell owns a process-run registry, stop active scopes too. Child
  # orchestrators that own their own runs still close via their EXIT traps.
  if [[ -n "${RALPH_PROCESS_RUN_DIR:-}" ]]; then
    ralph_process_stop_active "graph-schedule-cancel" || true
  fi
  return 0
}

# Apply ordinary failure (not exit-3 awaiting-ack): stop dispatch, record exit,
# mark blocked descendants, and under cancel signal in-flight children.
_graph_schedule_apply_node_failure() {
  local node_id="$1"
  local exit_code="$2"
  local reason="${3:-failure}"

  GRAPH_SCHEDULE_STOP_DISPATCH=1
  GRAPH_SCHEDULE_FAILED_NODE="$node_id"
  if [[ "$exit_code" =~ ^[0-9]+$ && "$exit_code" -ne 0 ]]; then
    GRAPH_SCHEDULE_EXIT_CODE="$exit_code"
  else
    GRAPH_SCHEDULE_EXIT_CODE=1
  fi
  echo "graph-schedule: node=$node_id failed reason=$reason exit=$GRAPH_SCHEDULE_EXIT_CODE policy=$GRAPH_SCHEDULE_FAILURE_POLICY" >&2
  _graph_schedule_mark_blocked_descendants "$node_id"
  if [[ "$GRAPH_SCHEDULE_FAILURE_POLICY" == "cancel" ]]; then
    _graph_schedule_cancel_inflight_children
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Checkpoint node handling
#
# A checkpoint node is a pure gate: the scheduler checks whether a human
# acknowledgement file exists at a well-known derived path. If the file exists,
# the checkpoint succeeds immediately and its subtree proceeds. If the file does
# not exist, the checkpoint enters awaiting-ack, its direct descendants are
# marked blocked, and every other branch of the graph continues to completion
# unaffected. No orchestrator subprocess is spawned.
#
# The ack path is derived from the run context so operators can predict it
# without reading the graph JSON:
#   <workspace>/.ralph-workspace/artifacts/<namespace>/checkpoints/<node_id>.ack
#
# This reuses the human-acknowledgement convention from orchestrator.sh
# (file-existence as the gate mechanism) without requiring a humanAck.path
# field in the plan YAML or the stage JSON. The derived path is intentional:
# it is predictable, auditable, and does not require extending the plan parser.
#
# Deliberate deferral: the dynamic planner in
# bundle/.ralph/bash-lib/orchestrator/orchestrator-planner.sh drains onto a
# FIFO queue, and mid-run graph mutation would invalidate the frozen graph.json
# resume contract -- the highest-payoff correctness guarantee in this design.
# The dynamic planner therefore stays out of graph version 1. If it lands
# later, it should take the form of a replan node emitting a sub-graph at a
# declared extension point, with the parent graph remaining immutable so that
# resume semantics are preserved.
# ---------------------------------------------------------------------------

# _graph_schedule_checkpoint_ack_path <node_id>
#
# Prints the absolute path of the acknowledgement file for a checkpoint node.
# Requires GRAPH_SCHEDULE_WORKSPACE and GRAPH_SCHEDULE_NAMESPACE to be set.
_graph_schedule_checkpoint_ack_path() {
  local node_id="$1"
  local safe_id
  if [[ -z "$node_id" || -z "$GRAPH_SCHEDULE_WORKSPACE" || -z "$GRAPH_SCHEDULE_NAMESPACE" ]]; then
    echo "Error: _graph_schedule_checkpoint_ack_path requires node_id and active run context" >&2
    return 1
  fi
  # Sanitize node id for filesystem safety (same rule as graph_state_node_file).
  safe_id="$(printf '%s' "$node_id" | sed 's/[^A-Za-z0-9._-]/_/g')"
  printf '%s/.ralph-workspace/artifacts/%s/checkpoints/%s.ack\n' \
    "$GRAPH_SCHEDULE_WORKSPACE" "$GRAPH_SCHEDULE_NAMESPACE" "$safe_id"
}

# _graph_schedule_handle_checkpoint_node <node_id>
#
# Handles a checkpoint node synchronously. No subprocess is spawned.
# If the ack file exists: mark succeeded, release successors.
# If absent: mark awaiting-ack, block descendants, set GRAPH_SCHEDULE_AWAITING_ACK.
# Other branches are not affected -- only the checkpoint's own subtree is gated.
_graph_schedule_handle_checkpoint_node() {
  local node_id="$1"
  local idx ack_path

  if ! idx="$(graph_schedule_index_map_get "$node_id")"; then
    echo "Error: _graph_schedule_handle_checkpoint_node: unknown node id: $node_id" >&2
    return 1
  fi
  if [[ "${GRAPH_NODE_STATES[$idx]}" != "pending" ]]; then
    echo "Error: checkpoint node $node_id not in pending state: ${GRAPH_NODE_STATES[$idx]}" >&2
    return 1
  fi

  if ! ack_path="$(_graph_schedule_checkpoint_ack_path "$node_id")"; then
    echo "Error: could not derive ack path for checkpoint node $node_id" >&2
    _graph_schedule_apply_node_failure "$node_id" 1 "checkpoint-ack-path-error"
    return 1
  fi

  echo "graph-schedule: checkpoint node=$node_id ack_path=$ack_path" >&2

  if [[ -f "$ack_path" ]]; then
    # Human acknowledged: checkpoint succeeds immediately.
    GRAPH_NODE_STATES[$idx]="succeeded"
    _graph_schedule_ledger_record "$node_id" "succeeded" \
      "" "success" "0" "$(graph_state_now_iso)" "$(graph_state_now_iso)" "" "" "checkpoint-ack-present"
    echo "graph-schedule: node=$node_id checkpoint succeeded (ack file present)" >&2
    _graph_schedule_release_successors "$node_id" || {
      _graph_schedule_apply_node_failure "$node_id" 1 "successor-release"
      return 1
    }
    return 0
  fi

  # Ack absent: enter awaiting-ack and block this node's own subtree only.
  # Every other branch of the graph continues scheduling unaffected.
  GRAPH_NODE_STATES[$idx]="awaiting-ack"
  GRAPH_SCHEDULE_AWAITING_ACK=1
  if [[ "$GRAPH_SCHEDULE_EXIT_CODE" -eq 0 ]]; then
    GRAPH_SCHEDULE_EXIT_CODE=3
  fi
  _graph_schedule_ledger_record "$node_id" "awaiting-ack" \
    "" "awaiting" "3" "$(graph_state_now_iso)" "$(graph_state_now_iso)" "" "" "checkpoint-ack-absent"
  echo "graph-schedule: node=$node_id awaiting-ack (checkpoint; create $ack_path to proceed)" >&2
  _graph_schedule_mark_blocked_descendants "$node_id"
  return 0
}

# ---------------------------------------------------------------------------
# Consensus-barrier and join node handling
#
# A consensus-barrier node (auto-generated by plan-todo.sh consensus
# expansion) has no agent or runtime of its own: it aggregates the verdicts
# of its synthetic consensus-voter predecessors via graph_consensus_run_join
# and is handled synchronously in-process, exactly like a checkpoint node.
# It is never dispatched as an orchestrator subprocess.
#
# A join node with no declared runtime is a policy pass-through: by the time
# it is ready, every dependency (typically a consensus-barrier) has already
# succeeded, so its own "decision" is already made. It is marked succeeded
# without invoking a model rather than re-asking a runtime to restate a
# verdict as a prose TODO. A join node that DOES declare a runtime (e.g. a
# manually authored adjudicator) is left to ordinary agent dispatch --
# existing behavior is preserved for that case.
# ---------------------------------------------------------------------------

# _graph_schedule_consensus_node_json <node_id>
# Prints the compiled graph node object (including .stage) for node_id, or
# nothing when the node or graph JSON is unavailable.
_graph_schedule_consensus_node_json() {
  local node_id="$1"
  [[ -n "${GRAPH_SCHEDULE_GRAPH_JSON:-}" && -f "$GRAPH_SCHEDULE_GRAPH_JSON" ]] || return 1
  jq -c --arg id "$node_id" '.nodes[] | select(.id == $id)' "$GRAPH_SCHEDULE_GRAPH_JSON" 2>/dev/null
}

# _graph_schedule_consensus_voter_artifact_abs <stage_json>
# Resolves a voter/predecessor node's outputArtifacts[0].path (the compiled
# .orch.json stage shape build_orch_stage produces from the plan's "produces"
# key) to an absolute path. Paths below .ralph-workspace are state-root paths,
# while other relative paths remain project-root paths. {{ARTIFACT_NS}} is
# substituted with GRAPH_SCHEDULE_NAMESPACE (the value
# graph_schedule_spawn_node exports as RALPH_ARTIFACT_NS for every node in
# this run); {{VOTER_ID}} is already resolved at compile time by
# plan-todo.sh's substitute_voter_id_in_artifacts and never appears here.
_graph_schedule_consensus_voter_artifact_abs() {
  local stage_json="$1"
  local rel state_root
  rel="$(printf '%s' "$stage_json" | jq -r '(.outputArtifacts // [])[0].path // empty')"
  [[ -n "$rel" ]] || return 1
  rel="${rel//\{\{ARTIFACT_NS\}\}/$GRAPH_SCHEDULE_NAMESPACE}"
  case "$rel" in
    /*) printf '%s\n' "$rel" ;;
    .ralph-workspace)
      graph_state_state_root "$GRAPH_SCHEDULE_WORKSPACE"
      ;;
    .ralph-workspace/*)
      state_root="$(graph_state_state_root "$GRAPH_SCHEDULE_WORKSPACE")" || return 1
      printf '%s/%s\n' "$state_root" "${rel#.ralph-workspace/}"
      ;;
    *) printf '%s/%s\n' "$GRAPH_SCHEDULE_WORKSPACE" "$rel" ;;
  esac
}

# _graph_schedule_handle_consensus_barrier_node <node_id>
_graph_schedule_handle_consensus_barrier_node() {
  local node_id="$1"
  local idx

  if ! idx="$(graph_schedule_index_map_get "$node_id")"; then
    echo "Error: _graph_schedule_handle_consensus_barrier_node: unknown node id: $node_id" >&2
    return 1
  fi
  if [[ "${GRAPH_NODE_STATES[$idx]}" != "pending" ]]; then
    echo "Error: consensus-barrier node $node_id not in pending state: ${GRAPH_NODE_STATES[$idx]}" >&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required for consensus-barrier dispatch" >&2
    _graph_schedule_apply_node_failure "$node_id" 1 "consensus-jq-missing"
    return 1
  fi

  local node_json stage_json policy policy_cfg_json
  if ! node_json="$(_graph_schedule_consensus_node_json "$node_id")" || [[ -z "$node_json" ]]; then
    echo "Error: consensus-barrier node $node_id not found in graph JSON" >&2
    _graph_schedule_apply_node_failure "$node_id" 1 "consensus-node-missing"
    return 1
  fi
  stage_json="$(printf '%s' "$node_json" | jq -c '.stage // {}')"
  policy="$(printf '%s' "$stage_json" | jq -r '.policy // "veto"')"
  policy_cfg_json="$(printf '%s' "$stage_json" | jq -c '
    {onVoterError: (.onVoterError // "fail")}
    + (if .quorum then {threshold: .quorum} else {} end)
    + (if .runtime and .runtime != "" then {runtime: .runtime} else {} end)
    + (if .agent and .agent != "" then {agent: .agent} else {} end)
    + (if .model and .model != "" then {model: .model} else {} end)
  ')"

  # Build voters_json from the barrier's own dependsOn predecessors (the
  # synthetic consensus-voter nodes), not from the plan's declared "voters"
  # list, so the barrier only ever aggregates nodes the scheduler actually
  # dispatched and tracked.
  local dep_ids voters_json="[]" dep_id dep_json dep_stage dep_runtime dep_agent dep_model dep_artifact voter_entry
  dep_ids="$(printf '%s' "$node_json" | jq -r '(.dependsOn // [])[]' 2>/dev/null)"
  if [[ -z "$dep_ids" ]]; then
    echo "Error: consensus-barrier node $node_id has no dependsOn voters" >&2
    _graph_schedule_apply_node_failure "$node_id" 1 "consensus-no-voters"
    return 1
  fi
  while IFS= read -r dep_id || [[ -n "$dep_id" ]]; do
    [[ -z "$dep_id" ]] && continue
    if ! dep_json="$(_graph_schedule_consensus_node_json "$dep_id")" || [[ -z "$dep_json" ]]; then
      echo "Error: consensus-barrier node $node_id: voter node $dep_id not found in graph JSON" >&2
      _graph_schedule_apply_node_failure "$node_id" 1 "consensus-voter-missing"
      return 1
    fi
    dep_stage="$(printf '%s' "$dep_json" | jq -c '.stage // {}')"
    dep_runtime="$(printf '%s' "$dep_stage" | jq -r '.runtime // empty')"
    dep_agent="$(printf '%s' "$dep_stage" | jq -r '.agent // empty')"
    dep_model="$(printf '%s' "$dep_stage" | jq -r '.model // empty')"
    if ! dep_artifact="$(_graph_schedule_consensus_voter_artifact_abs "$dep_stage")"; then
      echo "Error: consensus-barrier node $node_id: voter node $dep_id declares no produces artifact" >&2
      _graph_schedule_apply_node_failure "$node_id" 1 "consensus-voter-artifact-missing"
      return 1
    fi
    voter_entry="$(jq -nc \
      --arg voterId "$dep_id" --arg runtime "$dep_runtime" --arg artifact "$dep_artifact" \
      --arg agent "$dep_agent" --arg model "$dep_model" \
      '{voterId: $voterId, runtime: $runtime, artifact: $artifact}
       + (if $agent != "" then {agent: $agent} else {} end)
       + (if $model != "" then {model: $model} else {} end)')"
    voters_json="$(jq -c --argjson entry "$voter_entry" '. + [$entry]' <<<"$voters_json")"
  done <<<"$dep_ids"

  local join_rc=0
  graph_consensus_run_join \
    "$GRAPH_SCHEDULE_WORKSPACE" "$GRAPH_SCHEDULE_NAMESPACE" "$GRAPH_SCHEDULE_RUN_ID" \
    "$node_id" "$policy" "$voters_json" "$policy_cfg_json" || join_rc=$?

  if [[ "$join_rc" -eq 0 ]]; then
    GRAPH_NODE_STATES[$idx]="succeeded"
    echo "graph-schedule: node=$node_id consensus-barrier succeeded policy=$policy" >&2
    _graph_schedule_release_successors "$node_id" || {
      _graph_schedule_apply_node_failure "$node_id" 1 "successor-release"
      return 1
    }
    return 0
  fi

  GRAPH_NODE_STATES[$idx]="failed"
  # graph_consensus_run_join already recorded the ledger outcome and consensus
  # result artifact; this is a semantic decision (blocked/escalated), not an
  # infrastructure error, but until conditional repair edges exist (see
  # v2-conditional-outcomes) it propagates through failurePolicy like any
  # other node failure.
  _graph_schedule_apply_node_failure "$node_id" "$join_rc" "consensus-decision-not-approved"
  return 1
}

# _graph_schedule_handle_join_node <node_id>
# Only called for join-typed nodes with no declared runtime (see the dispatch
# loop); nodes with a runtime fall through to ordinary agent dispatch.
_graph_schedule_handle_join_node() {
  local node_id="$1"
  local idx

  if ! idx="$(graph_schedule_index_map_get "$node_id")"; then
    echo "Error: _graph_schedule_handle_join_node: unknown node id: $node_id" >&2
    return 1
  fi
  if [[ "${GRAPH_NODE_STATES[$idx]}" != "pending" ]]; then
    echo "Error: join node $node_id not in pending state: ${GRAPH_NODE_STATES[$idx]}" >&2
    return 1
  fi

  GRAPH_NODE_STATES[$idx]="succeeded"
  _graph_schedule_ledger_record "$node_id" "succeeded" \
    "" "success" "0" "$(graph_state_now_iso)" "$(graph_state_now_iso)" "" "" "join-passthrough"
  echo "graph-schedule: node=$node_id join passthrough succeeded (no declared runtime; reflects upstream aggregation)" >&2
  _graph_schedule_release_successors "$node_id" || {
    _graph_schedule_apply_node_failure "$node_id" 1 "successor-release"
    return 1
  }
  return 0
}

# _graph_schedule_handle_integration_node <node_id>
# Scheduler-owned deterministic integration. It invokes no model/runtime and
# can be safely retried because graph_integrate.py applies each operation
# idempotently and writes the success manifest only after the complete apply.
_graph_schedule_handle_integration_node() {
  local node_id="$1" idx started finished attempt_id attempt_number workspace state_root
  if ! idx="$(graph_schedule_index_map_get "$node_id")"; then
    echo "Error: integration node not found: $node_id" >&2
    return 1
  fi
  [[ "${GRAPH_NODE_STATES[$idx]}" == "pending" ]] || return 1
  [[ -n "$GRAPH_SCHEDULE_LEDGER_RUN_DIR" ]] || {
    _graph_schedule_apply_node_failure "$node_id" 1 "integration-requires-ledger"
    return 1
  }
  started="$(graph_state_now_iso)"
  attempt_number=$(( ${GRAPH_NODE_ATTEMPT_NUMBERS[$idx]:-0} + 1 ))
  GRAPH_NODE_ATTEMPT_NUMBERS[$idx]="$attempt_number"
  attempt_id="$(graph_dispatch_mint_attempt_id "$node_id" "$GRAPH_SCHEDULE_RUN_ID" "$attempt_number")" || return 1
  GRAPH_NODE_STATES[$idx]="running"
  workspace="$(graph_workspace_prepare_node \
    "$GRAPH_SCHEDULE_LEDGER_RUN_DIR" "$GRAPH_SCHEDULE_GRAPH_JSON" "$node_id")" || workspace=""
  state_root="$(jq -r '.roots.stateRoot' "$GRAPH_SCHEDULE_LEDGER_RUN_DIR/run.json")"
  local integration_context_json
  integration_context_json="$(_graph_schedule_node_observability_json "$node_id" "$workspace" "")"
  local input_manifests_json
  input_manifests_json="$(graph_integration_input_manifests_json \
    "$GRAPH_SCHEDULE_LEDGER_RUN_DIR" "$GRAPH_SCHEDULE_GRAPH_JSON" "$node_id")"
  integration_context_json="$(printf '%s' "$integration_context_json" | jq -c \
    --argjson inputs "$input_manifests_json" \
    '. + {integrationInputs: (if $inputs | length == 0 then null else $inputs end)}')"
  local integration_admission
  integration_admission="$(_graph_schedule_admission_summary_json "$node_id" "" "" "synchronous-integration")"
  integration_context_json="$(printf '%s' "$integration_context_json" | jq -c \
    --argjson admission "$integration_admission" \
    '. + {admissionSummary: $admission}')"
  _graph_schedule_ledger_record "$node_id" "running" "$attempt_id" "" "" "$started" "" "" "" "integration" "$integration_context_json"
  if [[ -n "$workspace" ]] && graph_integration_run \
    "$GRAPH_SCHEDULE_LEDGER_RUN_DIR" "$GRAPH_SCHEDULE_GRAPH_JSON" "$node_id" \
    "$workspace" "$state_root" "$GRAPH_SCHEDULE_NAMESPACE"; then
    finished="$(graph_state_now_iso)"
    GRAPH_NODE_STATES[$idx]="succeeded"
    local result_identity
    result_identity="$(jq -r '.resultIdentity // empty' "$state_root/artifacts/$GRAPH_SCHEDULE_NAMESPACE/integration/$(graph_workspace_node_key "$node_id").json" 2>/dev/null)"
    local success_json
    success_json="$(printf '%s' "$integration_context_json" | jq -c \
      --arg resultIdentity "${result_identity:-}" \
      '. + {integrationResultIdentity: (if $resultIdentity == "" then null else $resultIdentity end)}')"
    _graph_schedule_ledger_record "$node_id" "succeeded" "$attempt_id" "success" "0" \
      "$started" "$finished" "" "" "integration-complete" "$success_json"
    _graph_schedule_log_observability "integration-complete" "$node_id" "$attempt_id" "" "" "$success_json"
    _graph_schedule_release_successors "$node_id" || {
      _graph_schedule_apply_node_failure "$node_id" 1 "successor-release"
      return 1
    }
    return 0
  fi
  finished="$(graph_state_now_iso)"
  GRAPH_NODE_STATES[$idx]="failed"
  local failed_json
  failed_json="$(printf '%s' "$integration_context_json" | jq -c \
    --arg conflict "$(ls "$state_root/artifacts/$GRAPH_SCHEDULE_NAMESPACE/integration/$(graph_workspace_node_key "$node_id").conflict.json" 2>/dev/null)" \
    '. + {conflictArtifact: (if $conflict == "" then null else $conflict end)}')"
  _graph_schedule_ledger_record "$node_id" "failed" "$attempt_id" "failed" "1" \
    "$started" "$finished" "" "" "integration-failed" "$failed_json"
  _graph_schedule_log_observability "integration-failed" "$node_id" "$attempt_id" "" "" "$failed_json"
  _graph_schedule_apply_node_failure "$node_id" 1 "integration-failed"
  return 1
}

# _graph_schedule_handle_gate_node <node_id>
# Scheduler-owned, model-free verification gate. Runs an operator-authored
# verificationProfile (ordered allowlisted commands) in-process without
# spawning an orchestrator subprocess. Writes gate-result.json with outcome
# passed, changes-required, or error.
#
# With conditional edges, outcome routing works as follows:
#   passed          -> release unconditional + conditional(passed) successors;
#                      skip conditional(changes-required/error) successors.
#   changes-required -> if a conditional(changes-required) edge exists, the
#                       gate is treated as a semantic success: release that
#                       edge, skip conditional(passed/error); fail closed when
#                       no conditional(changes-required) edge exists.
#   error           -> infrastructure failure; skip all conditional successors;
#                      follow failurePolicy.
_graph_schedule_handle_gate_node() {
  local node_id="$1" idx started finished attempt_id attempt_number state_root
  if ! idx="$(graph_schedule_index_map_get "$node_id")"; then
    echo "Error: gate node not found: $node_id" >&2
    return 1
  fi
  [[ "${GRAPH_NODE_STATES[$idx]}" == "pending" ]] || return 1
  [[ -n "$GRAPH_SCHEDULE_LEDGER_RUN_DIR" ]] || {
    _graph_schedule_apply_node_failure "$node_id" 1 "gate-requires-ledger"
    return 1
  }
  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: graph-gate: jq is required for gate dispatch" >&2
    _graph_schedule_apply_node_failure "$node_id" 1 "gate-jq-missing"
    return 1
  fi
  started="$(graph_state_now_iso)"
  attempt_number=$(( ${GRAPH_NODE_ATTEMPT_NUMBERS[$idx]:-0} + 1 ))
  GRAPH_NODE_ATTEMPT_NUMBERS[$idx]="$attempt_number"
  attempt_id="$(graph_dispatch_mint_attempt_id "$node_id" "$GRAPH_SCHEDULE_RUN_ID" "$attempt_number")" || return 1
  GRAPH_NODE_STATES[$idx]="running"
  state_root="$(jq -r '.roots.stateRoot' "$GRAPH_SCHEDULE_LEDGER_RUN_DIR/run.json")"
  local gate_context_json gate_admission
  gate_context_json="$(_graph_schedule_node_observability_json "$node_id" "$GRAPH_SCHEDULE_WORKSPACE" "")"
  gate_admission="$(_graph_schedule_admission_summary_json "$node_id" "" "" "synchronous-gate")"
  gate_context_json="$(printf '%s' "$gate_context_json" | jq -c \
    --argjson admission "$gate_admission" \
    '. + {admissionSummary: $admission}')"
  _graph_schedule_ledger_record "$node_id" "running" "$attempt_id" "" "" "$started" "" "" "" "gate" "$gate_context_json"
  local gate_rc=0
  graph_gate_run \
    "$node_id" "$GRAPH_SCHEDULE_GRAPH_JSON" \
    "$GRAPH_SCHEDULE_WORKSPACE" "$state_root" "$GRAPH_SCHEDULE_NAMESPACE" || gate_rc=$?
  finished="$(graph_state_now_iso)"
  local gate_outcome="" gate_result_path=""
  if [[ "$gate_rc" -eq 0 ]]; then
    gate_outcome="passed"
  elif [[ "$gate_rc" -eq 2 ]]; then
    gate_outcome="changes-required"
  else
    gate_outcome="error"
  fi
  gate_result_path="$state_root/artifacts/$GRAPH_SCHEDULE_NAMESPACE/gate/$(printf '%s' "$node_id" | sed 's|[^A-Za-z0-9_.-]|_|g')/gate-result.json"
  local gate_extra_json verification_classes
  verification_classes="$(jq -c '[.steps[]?.resourceClass // empty] | unique' "$gate_result_path" 2>/dev/null || printf '[]')"
  gate_extra_json="$(printf '%s' "$gate_context_json" | jq -c \
    --arg outcome "$gate_outcome" \
    --arg resultPath "${gate_result_path:-}" \
    --argjson verificationClasses "$verification_classes" \
    '. + {gateOutcome: $outcome, gateResultPath: (if $resultPath == "" then null else $resultPath end), verificationResourceClasses: (if ($verificationClasses | length) == 0 then null else $verificationClasses end)}')"

  if [[ "$gate_rc" -eq 0 ]]; then
    # passed: release unconditional + conditional(passed), skip others.
    GRAPH_NODE_STATES[$idx]="succeeded"
    _graph_schedule_ledger_record "$node_id" "succeeded" "$attempt_id" "success" "0" \
      "$started" "$finished" "" "" "gate-passed" "$gate_extra_json"
    _graph_schedule_log_observability "gate-passed" "$node_id" "$attempt_id" "" "" "$gate_extra_json"
    local outcome_rc=0
    _graph_schedule_apply_conditional_outcome "$node_id" "passed" || outcome_rc=$?
    if [[ "$outcome_rc" -ne 0 ]]; then
      _graph_schedule_apply_node_failure "$node_id" 1 "successor-release"
      return 1
    fi
    return 0
  fi

  if [[ "$gate_rc" -eq 2 ]]; then
    # changes-required: follow explicit repair edge if declared; fail closed otherwise.
    local cond_rc=0
    _graph_schedule_apply_conditional_outcome "$node_id" "changes-required" || cond_rc=$?
    if [[ "$cond_rc" -eq 2 ]]; then
      # No conditional(changes-required) edge: fail closed.
      GRAPH_NODE_STATES[$idx]="failed"
      _graph_schedule_ledger_record "$node_id" "failed" "$attempt_id" "failed" "2" \
        "$started" "$finished" "" "" "gate-changes-required-no-edge" "$gate_extra_json"
      _graph_schedule_apply_node_failure "$node_id" 2 "gate-changes-required-no-edge"
      return 1
    fi
    if [[ "$cond_rc" -ne 0 ]]; then
      GRAPH_NODE_STATES[$idx]="failed"
      _graph_schedule_ledger_record "$node_id" "failed" "$attempt_id" "failed" "2" \
        "$started" "$finished" "" "" "gate-changes-required-successor-error" "$gate_extra_json"
      _graph_schedule_apply_node_failure "$node_id" 2 "gate-changes-required-successor-error"
      return 1
    fi
    # Repair edge found: gate is treated as a semantic success.
    GRAPH_NODE_STATES[$idx]="succeeded"
    _graph_schedule_ledger_record "$node_id" "succeeded" "$attempt_id" "success" "2" \
      "$started" "$finished" "" "" "gate-changes-required-repair-edge" "$gate_extra_json"
    _graph_schedule_log_observability "gate-changes-required" "$node_id" "$attempt_id" "" "" "$gate_extra_json"
    echo "graph-schedule: node=$node_id gate changes-required routed to repair edge" >&2
    return 0
  fi

  # error (gate_rc=1 or any other): infrastructure failure; follow failurePolicy.
  GRAPH_NODE_STATES[$idx]="failed"
  _graph_schedule_ledger_record "$node_id" "failed" "$attempt_id" "failed" "$gate_rc" \
    "$started" "$finished" "" "" "gate-error" "$gate_extra_json"
  _graph_schedule_log_observability "gate-error" "$node_id" "$attempt_id" "" "" "$gate_extra_json"
  # Skip all conditional branches before applying failure so they are not left pending.
  _graph_schedule_skip_cond_branches "$node_id" "error" \
    $(_graph_schedule_cond_successor_nodes_for "$node_id") || true
  _graph_schedule_apply_node_failure "$node_id" "$gate_rc" "gate-error"
  return 1
}

# _graph_schedule_cond_successor_nodes_for <node_id>
# Prints a space-separated list of all conditional successor node ids for node_id.
# Used to skip all conditional branches when a gate errors out.
_graph_schedule_cond_successor_nodes_for() {
  local node_id="$1" idx cond_succ_str succ cond_node old_ifs
  if ! idx="$(graph_schedule_index_map_get "$node_id" 2>/dev/null)"; then return 0; fi
  cond_succ_str="${GRAPH_NODE_COND_SUCCESSORS[$idx]:-}"
  [[ -z "$cond_succ_str" ]] && return 0
  old_ifs="$IFS"
  IFS="$GRAPH_SUCCESSOR_DELIM"
  # shellcheck disable=SC2086
  for succ in $cond_succ_str; do
    IFS="$old_ifs"
    [[ -z "$succ" ]] && continue
    cond_node="${succ#*:}"
    printf '%s ' "$cond_node"
    IFS="$GRAPH_SUCCESSOR_DELIM"
  done
  IFS="$old_ifs"
}

# _graph_schedule_ledger_record <node_id> <state> [attempt_id] [outcome]
#   [exit_code] [started_at] [finished_at] [runtime] [subagents] [reason]
#   [extra_json]
#
# Records a node state transition (and optionally an attempt) into the durable
# run-state ledger. No-op when GRAPH_SCHEDULE_LEDGER_RUN_DIR is empty, which
# keeps ledger-less test invocations behaviorally unchanged. The ledger is
# the graph state; the plan file is the loop state. Never encode graph progress
# into plan checkboxes -- the two states are deliberately separate so a run
# can be inspected and resumed even when the plan source has moved or changed,
# and so loop idempotency inside a node (completed todos already marked done)
# composes cleanly with graph resume (succeeded nodes stay succeeded). This
# separation is the load-bearing reason the loop and graph hybrid works.
#
# extra_json is a JSON object string merged into the node ledger entry (and
# into the attempt when one is supplied). It is used to record v2 observability
# metadata produced during admission, workspace setup, gate execution,
# integration, delegation, repair, and publish.
_graph_schedule_ledger_record() {
  [[ -z "$GRAPH_SCHEDULE_LEDGER_RUN_DIR" ]] && return 0
  local node_id="$1" state="$2" attempt_id="${3:-}" outcome="${4:-}"
  local exit_code="${5:-}" started_at="${6:-}" finished_at="${7:-}"
  local runtime="${8:-}" subagents="${9:-}" reason="${10:-}"
  local extra_json="${11:-}"
  graph_state_write_node \
    "$GRAPH_SCHEDULE_WORKSPACE" "$GRAPH_SCHEDULE_LEDGER_NAMESPACE" \
    "$GRAPH_SCHEDULE_RUN_ID" "$node_id" "$state" \
    "$attempt_id" "$outcome" "$exit_code" "$started_at" "$finished_at" \
    "$runtime" "$subagents" "$reason" "$extra_json" 2>/dev/null || true
  # Emit one structured log line per state transition in the orchestrator log
  # format so the logs directory stays greppable.  One line per transition keeps
  # the format predictable; the attempt id is included when present so a resume
  # can correlate an orphaned in-flight node with its report.
  local log_msg
  log_msg="graph-schedule: node=$node_id state=$state"
  if [[ -n "$attempt_id" ]]; then
    log_msg="$log_msg attempt=$attempt_id"
  fi
  if [[ -n "$outcome" ]]; then
    log_msg="$log_msg outcome=$outcome"
  fi
  if [[ -n "$runtime" ]]; then
    log_msg="$log_msg runtime=$runtime"
  fi
  if [[ -n "$reason" ]]; then
    log_msg="$log_msg reason=$reason"
  fi
  _graph_schedule_log_transition "$log_msg"
}

# Resolve a graph-declared artifact into the supervisor-owned exchange area.
# Isolated agents only see a workspace-local copy of relative declarations;
# the scheduler ferries those copies through shared state after a successful
# node and before a dependent node starts.  This keeps plans and ledger files
# outside the model's writable tree without sacrificing artifact handoffs.
_graph_schedule_artifact_exchange_path() {
  local declared="$1" state_root="$2" namespace="$3"
  [[ -n "$declared" && "$declared" != *$'\n'* && "$declared" != *$'\r'* ]] || return 1
  case "/$declared/" in
    */../*|*/./*)
      echo "Error: unsafe graph artifact path: $declared" >&2
      return 1
      ;;
  esac
  if [[ "$declared" == /* ]]; then
    case "$declared" in
      "$state_root"/*) printf '%s\n' "$declared" ;;
      *)
        echo "Error: isolated graph artifact must be relative or under the shared state root: $declared" >&2
        return 1
        ;;
    esac
  elif [[ "$declared" == .ralph-workspace/* ]]; then
    printf '%s/%s\n' "$state_root" "${declared#.ralph-workspace/}"
  else
    printf '%s/artifacts/%s/exchange/%s\n' "$state_root" "$namespace" "$declared"
  fi
}

_graph_schedule_artifact_local_path() {
  local declared="$1" node_workspace="$2" state_root="$3"
  if [[ "$declared" == /* ]]; then
    # Absolute graph artifacts are accepted only inside state_root by the
    # exchange resolver and are supervisor-visible, not staged for the model.
    printf '%s\n' "$declared"
  else
    printf '%s/%s\n' "$node_workspace" "$declared"
  fi
}

# Reject symlink traversal on either side of a supervisor copy.  The final
# component may not be a symlink either.  Existing ordinary directories are
# allowed; missing components are created only after their ancestors pass.
_graph_schedule_artifact_path_has_symlink() {
  local root="$1" path="$2" rel component cursor
  [[ "$path" == "$root"/* ]] || return 0
  rel="${path#$root/}"
  cursor="$root"
  local old_ifs="$IFS"
  IFS='/'
  for component in $rel; do
    IFS="$old_ifs"
    cursor="$cursor/$component"
    [[ -L "$cursor" ]] && return 0
    IFS='/'
  done
  IFS="$old_ifs"
  return 1
}

_graph_schedule_copy_artifact_file() {
  local source="$1" destination="$2" source_root="$3" destination_root="$4"
  local destination_dir temporary
  [[ -f "$source" && ! -L "$source" ]] || return 1
  if _graph_schedule_artifact_path_has_symlink "$source_root" "$source"; then
    echo "Error: graph artifact source traverses a symlink: $source" >&2
    return 1
  fi
  if [[ -e "$destination" && ( ! -f "$destination" || -L "$destination" ) ]]; then
    echo "Error: graph artifact destination is not a regular file: $destination" >&2
    return 1
  fi
  destination_dir="$(dirname "$destination")"
  if _graph_schedule_artifact_path_has_symlink "$destination_root" "$destination_dir"; then
    echo "Error: graph artifact destination traverses a symlink: $destination" >&2
    return 1
  fi
  mkdir -p "$destination_dir" || return 1
  if _graph_schedule_artifact_path_has_symlink "$destination_root" "$destination_dir"; then
    echo "Error: graph artifact destination became unsafe: $destination" >&2
    return 1
  fi
  temporary="$(mktemp "$destination_dir/.graph-artifact-XXXXXX")" || return 1
  if ! cp "$source" "$temporary" || ! mv -f "$temporary" "$destination"; then
    rm -f "$temporary" 2>/dev/null || true
    return 1
  fi
}

_graph_schedule_stage_inputs() {
  local node_id="$1" node_workspace="$2" state_root="$3"
  local declared required canonical local_path
  [[ "$node_workspace" != "$GRAPH_SCHEDULE_WORKSPACE" ]] || return 0
  while IFS=$'\t' read -r declared required || [[ -n "$declared" ]]; do
    [[ -n "$declared" ]] || continue
    canonical="$(_graph_schedule_artifact_exchange_path "$declared" "$state_root" "$GRAPH_SCHEDULE_NAMESPACE")" || return 1
    local_path="$(_graph_schedule_artifact_local_path "$declared" "$node_workspace" "$state_root")" || return 1
    if [[ "$local_path" == "$canonical" ]]; then
      [[ "$required" != "true" || ( -f "$canonical" && -s "$canonical" ) ]] || {
        echo "Error: required graph input artifact is missing: $declared" >&2
        return 1
      }
      continue
    fi
    if [[ ! -f "$canonical" || ! -s "$canonical" ]]; then
      if [[ "$required" == "true" ]]; then
        echo "Error: required graph input artifact is missing from shared state: $declared" >&2
        return 1
      fi
      continue
    fi
    _graph_schedule_copy_artifact_file "$canonical" "$local_path" "$state_root" "$node_workspace" || return 1
  done < <(jq -r --arg id "$node_id" '
    .nodes[] | select(.id == $id) | (.stage.inputArtifacts // [])[]? |
    if type == "string" then [., true] else [.path, (.required // true)] end | @tsv
  ' "$GRAPH_SCHEDULE_GRAPH_JSON")
}

_graph_schedule_publish_stage_artifacts() {
  local node_id="$1" node_workspace="$2" state_root="$3"
  local declared required canonical local_path
  [[ "$node_workspace" != "$GRAPH_SCHEDULE_WORKSPACE" ]] || return 0
  while IFS=$'\t' read -r declared required || [[ -n "$declared" ]]; do
    [[ -n "$declared" ]] || continue
    canonical="$(_graph_schedule_artifact_exchange_path "$declared" "$state_root" "$GRAPH_SCHEDULE_NAMESPACE")" || return 1
    local_path="$(_graph_schedule_artifact_local_path "$declared" "$node_workspace" "$state_root")" || return 1
    if [[ "$local_path" == "$canonical" ]]; then
      [[ "$required" != "true" || ( -f "$canonical" && -s "$canonical" ) ]] || return 1
      continue
    fi
    if [[ ! -f "$local_path" || ! -s "$local_path" ]]; then
      [[ "$required" != "true" ]] && continue
      echo "Error: required graph output artifact is missing from node workspace: $declared" >&2
      return 1
    fi
    _graph_schedule_copy_artifact_file "$local_path" "$canonical" "$node_workspace" "$state_root" || return 1
  done < <(jq -r --arg id "$node_id" '
    .nodes[] | select(.id == $id) | .stage |
    [(.outputArtifacts // [])[], (.artifacts // [])[]] |
    map(if type == "string" then {path:., required:true} else . end) |
    unique_by(.path)[]? | [.path, (.required // true)] | @tsv
  ' "$GRAPH_SCHEDULE_GRAPH_JSON")
}

# graph_schedule_spawn_node <node_id>
#
# Mint an attempt, reserve runtime slots, background the single-stage
# orchestrator, and track the child for the centralized reaper. Requires
# GRAPH_SCHEDULE_* run context. Each child gets a node-namespaced log directory
# and a distinct RALPH_PLAN_KEY (session key); RALPH_ARTIFACT_NS stays shared so
# edge handoffs resolve under one artifact namespace.
_graph_schedule_spawn_node() {
  local node_id="$1"
  local idx attempt_number attempt_id report_path log_dir log_path pid
  local node_orch_dir node_orch_path session_key runtime subagents node_policy
  local node_workspace state_root node_plan_rel node_plan_source node_plan_target node_path_key tooling_root
  local changeset_baseline="" changeset_scopes="" changeset_mode="" changeset_base_identity=""

  if [[ -z "$node_id" ]]; then
    echo "Error: graph_schedule_spawn_node requires node_id" >&2
    return 1
  fi
  if ! idx="$(graph_schedule_index_map_get "$node_id")"; then
    echo "Error: unknown graph node id: $node_id" >&2
    return 1
  fi
  if [[ "${GRAPH_NODE_STATES[$idx]}" != "pending" ]]; then
    echo "Error: cannot spawn node $node_id in state ${GRAPH_NODE_STATES[$idx]}" >&2
    return 1
  fi
  if [[ -z "$GRAPH_SCHEDULE_ORCH_PATH" || -z "$GRAPH_SCHEDULE_RUN_ID" || -z "$GRAPH_SCHEDULE_WORKSPACE" ]]; then
    echo "Error: graph_schedule_spawn_node requires an active graph_schedule_run context" >&2
    return 1
  fi
  if [[ -z "$GRAPH_SCHEDULE_NAMESPACE" ]]; then
    echo "Error: graph_schedule_spawn_node requires GRAPH_SCHEDULE_NAMESPACE" >&2
    return 1
  fi

  runtime="${GRAPH_NODE_RUNTIMES[$idx]}"
  subagents="${GRAPH_NODE_SUBAGENTS[$idx]}"
  node_path_key="$(graph_workspace_node_key "$node_id")" || return 1
  node_policy="$(jq -c --arg id "$node_id" '
    .nodes[] | select(.id == $id) | .stage as $stage |
    (($stage.delegation // {}) + {
      parentWorkspaceMode: ($stage.workspaceMode // "shared"),
      parentWriteScopes: ($stage.writeScopes // [])
    })
  ' "$GRAPH_SCHEDULE_GRAPH_JSON" 2>/dev/null)" || node_policy='{}'
  _graph_schedule_runtime_reserve "$node_id" "$runtime" "$subagents" || return 1
  node_workspace="$GRAPH_SCHEDULE_WORKSPACE"
  state_root="${RALPH_PLAN_WORKSPACE_ROOT:-$GRAPH_SCHEDULE_WORKSPACE/.ralph-workspace}"
  if [[ -n "$GRAPH_SCHEDULE_LEDGER_RUN_DIR" \
    && -f "$GRAPH_SCHEDULE_LEDGER_RUN_DIR/run.json" \
    && "$(jq -r '.workspaceManager.schemaVersion // 0' "$GRAPH_SCHEDULE_LEDGER_RUN_DIR/run.json")" == "1" ]]; then
    node_workspace="$(graph_workspace_prepare_node \
      "$GRAPH_SCHEDULE_LEDGER_RUN_DIR" "$GRAPH_SCHEDULE_GRAPH_JSON" "$node_id")" || {
        _graph_schedule_runtime_release "$node_id"
        return 1
      }
    state_root="$(jq -r '.roots.stateRoot' "$GRAPH_SCHEDULE_LEDGER_RUN_DIR/run.json")"
  fi
  _graph_schedule_stage_inputs "$node_id" "$node_workspace" "$state_root" || {
    _graph_schedule_runtime_release "$node_id"
    return 1
  }

  attempt_number=$(( ${GRAPH_NODE_ATTEMPT_NUMBERS[$idx]} + 1 ))
  GRAPH_NODE_ATTEMPT_NUMBERS[$idx]="$attempt_number"
  attempt_id="$(graph_dispatch_mint_attempt_id "$node_id" "$GRAPH_SCHEDULE_RUN_ID" "$attempt_number")" || {
    _graph_schedule_runtime_release "$node_id"
    return 1
  }
  if [[ -n "$GRAPH_SCHEDULE_LEDGER_RUN_DIR" ]]; then
    graph_changeset_capture_baseline \
      "$GRAPH_SCHEDULE_LEDGER_RUN_DIR" "$GRAPH_SCHEDULE_GRAPH_JSON" \
      "$node_id" "$attempt_id" "$node_workspace" || {
        _graph_schedule_runtime_release "$node_id"
        return 1
      }
    if graph_changeset_is_mutating "$GRAPH_SCHEDULE_GRAPH_JSON" "$node_id"; then
      changeset_baseline="$(graph_changeset_baseline_path \
        "$GRAPH_SCHEDULE_LEDGER_RUN_DIR" "$node_id" "$attempt_id")" || return 1
      changeset_scopes="$(jq -c --arg id "$node_id" \
        '.nodes[] | select(.id == $id) | .stage.writeScopes' "$GRAPH_SCHEDULE_GRAPH_JSON")"
      changeset_mode="$(jq -r --arg id "$node_id" \
        '.nodes[] | select(.id == $id) | .stage.workspaceMode // "shared"' "$GRAPH_SCHEDULE_GRAPH_JSON")"
      changeset_base_identity="$(jq -r \
        '.sourceBase.filesystemIdentity // .sourceBase.git.treeHash // "shared-optimistic"' \
        "$GRAPH_SCHEDULE_LEDGER_RUN_DIR/run.json")"
    fi
  fi
  report_path="$(graph_dispatch_report_path "$GRAPH_SCHEDULE_WORKSPACE" "$GRAPH_SCHEDULE_NAMESPACE" "$attempt_id")"

  # Per-node orch copy so concurrent single-stage children do not contend on the
  # process-supervisor plan lease (keyed by realpath of --orchestration).
  # Namespace inside the JSON stays shared so StageOutcomeReports and handoff
  # artifacts land under one artifact NS.
  if [[ -n "$GRAPH_SCHEDULE_LEDGER_RUN_DIR" ]]; then
    node_orch_dir="$GRAPH_SCHEDULE_LEDGER_RUN_DIR/orchestration-plans/nodes/$node_path_key"
  else
    node_orch_dir="$state_root/orchestration-plans/$GRAPH_SCHEDULE_NAMESPACE/nodes/$node_path_key"
  fi
  mkdir -p "$node_orch_dir"
  node_orch_path="$node_orch_dir/${GRAPH_SCHEDULE_NAMESPACE}.orch.json"
  cp "$GRAPH_SCHEDULE_ORCH_PATH" "$node_orch_path" || {
    _graph_schedule_runtime_release "$node_id"
    return 1
  }
  # Ledger-backed graph runs materialize inline plans under the durable run
  # directory and pass an absolute read path. Never copy those scheduler-owned
  # plans into a model-writable isolated workspace.
  node_plan_rel="$(jq -r --arg id "$node_id" '.stages[] | select(.id == $id) | .plan // empty' "$node_orch_path")"
  # Explicit planFile stages are loop state, not project output.  Run them from
  # a durable per-node control copy so runner-owned checkbox transitions never
  # enter the node workspace or its changeset.  Preserve an existing copy on
  # resume: completed TODOs are the idempotency checkpoint inside the node.
  if [[ -n "$node_plan_rel" \
    && ( -z "$GRAPH_SCHEDULE_LEDGER_RUN_DIR" || "$node_plan_rel" != "$GRAPH_SCHEDULE_LEDGER_RUN_DIR/"* ) ]]; then
    if [[ "$node_plan_rel" == /* ]]; then
      node_plan_source="$node_plan_rel"
    else
      node_plan_source="$node_workspace/$node_plan_rel"
      if [[ ! -f "$node_plan_source" ]]; then
        node_plan_source="$GRAPH_SCHEDULE_WORKSPACE/$node_plan_rel"
      fi
    fi
    if [[ -f "$node_plan_source" ]]; then
      node_plan_target="$node_orch_dir/plans/${node_path_key}.plan.md"
      if [[ ! -f "$node_plan_target" ]]; then
        mkdir -p "$(dirname "$node_plan_target")" || {
          _graph_schedule_runtime_release "$node_id"
          return 1
        }
        cp "$node_plan_source" "$node_plan_target" || {
          _graph_schedule_runtime_release "$node_id"
          return 1
        }
      fi
      local node_orch_tmp
      node_orch_tmp="$(mktemp "$node_orch_dir/.node-orch-XXXXXX")" || {
        _graph_schedule_runtime_release "$node_id"
        return 1
      }
      if ! jq --arg id "$node_id" --arg plan "$node_plan_target" \
        '(.stages[] | select(.id == $id) | .plan) = $plan' \
        "$node_orch_path" >"$node_orch_tmp"; then
        rm -f "$node_orch_tmp"
        _graph_schedule_runtime_release "$node_id"
        return 1
      fi
      mv -f "$node_orch_tmp" "$node_orch_path" || {
        rm -f "$node_orch_tmp"
        _graph_schedule_runtime_release "$node_id"
        return 1
      }
      node_plan_rel="$node_plan_target"
    fi
  fi
  if [[ -z "$GRAPH_SCHEDULE_LEDGER_RUN_DIR" && "$node_workspace" != "$GRAPH_SCHEDULE_WORKSPACE" \
    && "$node_plan_rel" == ".ralph-workspace/orchestration-plans/"* ]]; then
    node_plan_source="$GRAPH_SCHEDULE_WORKSPACE/$node_plan_rel"
    node_plan_target="$node_workspace/$node_plan_rel"
    if [[ -f "$node_plan_source" && ! -e "$node_plan_target" ]]; then
      mkdir -p "$(dirname "$node_plan_target")" || {
        _graph_schedule_runtime_release "$node_id"
        return 1
      }
      cp "$node_plan_source" "$node_plan_target" || {
        _graph_schedule_runtime_release "$node_id"
        return 1
      }
    fi
  fi

  tooling_root="$(cd "$(dirname "$(graph_dispatch_resolve_orchestrator "$node_workspace")")" 2>/dev/null && pwd -P)" || {
    _graph_schedule_runtime_release "$node_id"
    echo "Error: unable to resolve frozen graph tooling root" >&2
    return 1
  }
  # Pin the child to this already-loaded Ralph tree.  The isolated workspace
  # remains the project/config and agent root, but its .ralph directory is
  # model-writable and cannot supply supervisor scripts.
  RALPH_GRAPH_TOOLING_ROOT="$tooling_root" graph_dispatch_build_argv \
    "$node_orch_path" \
    "$node_id" \
    "$GRAPH_SCHEDULE_RUN_ID" \
    "$attempt_id" \
    "$node_workspace" \
    "$state_root" || {
    _graph_schedule_runtime_release "$node_id"
    return 1
  }

  # Per-node log root: run-plan writes plan-usage-summary.json here when
  # RALPH_GRAPH_NODE_ID is set, so concurrent nodes do not race (same hazard
  # the parallel-wave branch of orchestrator.sh works around).
  log_dir="$state_root/logs/$GRAPH_SCHEDULE_NAMESPACE/nodes/$node_path_key"
  mkdir -p "$log_dir"
  log_path="$log_dir/attempt-${attempt_number}.log"
  session_key="$(_graph_schedule_session_key_for_node "$node_id")"

  # Capture the spawn-time observable context that the scheduler controls
  # before forking, so it can be attached to the running ledger entry and to
  # the structured observability log without reading back from the child.
  local spawn_context_json
  spawn_context_json="$(_graph_schedule_node_spawn_context_json "$node_id" "$node_workspace" "$changeset_mode" "$changeset_scopes" "$changeset_base_identity" "$changeset_baseline")"

  # Background the fresh single-stage process in its own session/process group
  # so failurePolicy=cancel can SIGTERM the child PGID without reaching the
  # scheduler's process group. Prefer setsid; fall back to python3 os.setsid
  # (macOS has no setsid(1)); last resort shares the scheduler PGID and cancel
  # will tree-kill only.
  # Keep RALPH_ARTIFACT_NS shared across nodes (edge handoffs). Give each child a
  # distinct RALPH_PLAN_KEY and RALPH_GRAPH_NODE_ID for session/log isolation.
  # Clear inherited process-run attachment so each node owns its own guardian/
  # lease instead of attaching to the scheduler parent's run (which would still
  # serialize on any shared lease key).
  local pgid=""
  (
    unset RALPH_PROCESS_RUN_DIR RALPH_PROCESS_RUN_ID RALPH_PROCESS_RUN_TOKEN \
      RALPH_PROCESS_GUARDIAN_PID RALPH_PROCESS_RUN_OWNED RALPH_PROCESS_RUN_DEPTH \
      RALPH_PROCESS_ATTACHED_PLAN RALPH_PROCESS_ALLOW_CHILD 2>/dev/null || true
    export RALPH_ALLOW_NESTED_RUNS=1
    export RALPH_ARTIFACT_NS="$GRAPH_SCHEDULE_NAMESPACE"
    export RALPH_PLAN_KEY="$session_key"
    export RALPH_GRAPH_NODE_ID="$node_id"
    export RALPH_GRAPH_NAMESPACE="$GRAPH_SCHEDULE_NAMESPACE"
    export RALPH_GRAPH_RUN_ID="$GRAPH_SCHEDULE_RUN_ID"
    export RALPH_GRAPH_ATTEMPT_ID="$attempt_id"
    export RALPH_GRAPH_NODE_RUNTIME="$runtime"
    export RALPH_GRAPH_DELEGATION_DEPTH=0
    export RALPH_GRAPH_NODE_POLICY="$node_policy"
    export RALPH_GRAPH_TOOLING_ROOT="$tooling_root"
    export RALPH_MCP_SCOPE=graph-node
    export RALPH_PROJECT_ROOT="$node_workspace"
    export RALPH_CONFIG_DISCOVERY_ROOT="$node_workspace"
    export RALPH_AGENT_WORKSPACE="$node_workspace"
    export RALPH_PLAN_WORKSPACE_ROOT="$state_root"
    export RALPH_GRAPH_STATE_ROOT="$state_root"
    export RALPH_GRAPH_NODE_LOG_PATH="$log_path"
    export RALPH_GRAPH_ARTIFACT_EXCHANGE_ROOT="$state_root/artifacts/$GRAPH_SCHEDULE_NAMESPACE/exchange"
    if [[ -n "$changeset_baseline" ]]; then
      export RALPH_GRAPH_CHANGESET_BASELINE="$changeset_baseline"
      export RALPH_GRAPH_CHANGESET_HELPER="$GRAPH_CHANGESET_HELPER"
      export RALPH_GRAPH_WRITE_SCOPES_JSON="$changeset_scopes"
      export RALPH_GRAPH_WORKSPACE_MODE="$changeset_mode"
      export RALPH_GRAPH_BASE_IDENTITY="$changeset_base_identity"
    fi
    # Prefer in-process os.setsid (no fork) so the tracked pid remains the
    # session leader. setsid(1) may fork+exit the parent, which would make the
    # scheduler track a zombie while the real child escapes under another pid.
    if command -v python3 >/dev/null 2>&1; then
      exec python3 -c 'import os, sys
os.setsid()
os.execvp(sys.argv[1], sys.argv[1:])' "${GRAPH_DISPATCH_ARGV[@]}"
    elif command -v setsid >/dev/null 2>&1; then
      exec setsid -w "${GRAPH_DISPATCH_ARGV[@]}" 2>/dev/null || exec setsid "${GRAPH_DISPATCH_ARGV[@]}"
    else
      exec "${GRAPH_DISPATCH_ARGV[@]}"
    fi
  ) >"$log_path" 2>&1 &
  pid=$!
  # With exec setsid / exec python3+setsid the tracked pid is the session leader.
  pgid="$pid"
  if ! graph_schedule_track_child "$pid" "$node_id" "$report_path" "$pgid"; then
    _graph_schedule_runtime_release "$node_id"
    return 1
  fi
  GRAPH_NODE_STATES[$idx]="running"
  # Record the attempt start in the ledger. outcome/exit/finished are left
  # empty until the reaper harvests; the running state plus attempt id is what
  # p3-resume uses to detect an orphaned in-flight node and adopt its report.
  _graph_schedule_ledger_record "$node_id" "running" \
    "$attempt_id" "" "" "$(graph_state_now_iso)" "" "$runtime" "$subagents" "" "$spawn_context_json"
  _graph_schedule_log_observability "node-spawn" "$node_id" "$attempt_id" "$runtime" "$subagents" "$spawn_context_json"
  return 0
}

# _graph_schedule_node_observability_json <node-id> <workspace> [changeset-mode]
#   [write-scopes-json] [base-identity] [changeset-baseline-path]
#
# Build an extra_json object for the durable node ledger.  This is the stable
# source of truth for status, render, dashboard, and the observability log.
# It records scheduler-owned facts: workspace mode and path, frozen base
# identity, declared write scopes, native subagent/delegation policy, and
# the changeset baseline path.  It intentionally does NOT include child
# states or gate outcomes; those are attached later when known.
_graph_schedule_node_observability_json() {
  local node_id="$1" workspace="$2" mode="${3:-}" scopes_json="${4:-}" base_identity="${5:-}" baseline="${6:-}"
  local policy_json native_mode cross_mode
  policy_json="$(jq -c --arg id "$node_id" '.nodes[] | select(.id == $id) | (.stage.delegation // {})' "${GRAPH_SCHEDULE_GRAPH_JSON:-}" 2>/dev/null)" || policy_json='{}'
  native_mode="$(printf '%s' "$policy_json" | jq -r '.native.mode // "off"')"
  cross_mode="$(printf '%s' "$policy_json" | jq -r '.crossRuntime.mode // "off"')"
  if [[ -z "$mode" ]]; then
    mode="$(jq -r --arg id "$node_id" '.nodes[] | select(.id == $id) | .stage.workspaceMode // "shared"' "${GRAPH_SCHEDULE_GRAPH_JSON:-}" 2>/dev/null)" || mode="shared"
  fi
  if [[ -z "$scopes_json" ]]; then
    scopes_json="$(jq -c --arg id "$node_id" '.nodes[] | select(.id == $id) | (.stage.writeScopes // [])' "${GRAPH_SCHEDULE_GRAPH_JSON:-}" 2>/dev/null)" || scopes_json='[]'
  fi
  jq -cn \
    --arg nodeId "$node_id" \
    --arg workspace "$workspace" \
    --arg mode "$mode" \
    --argjson scopes "$scopes_json" \
    --arg baseIdentity "${base_identity:-}" \
    --arg baseline "${baseline:-}" \
    --arg nativeMode "$native_mode" \
    --arg crossMode "$cross_mode" \
    '{
       workspaceMode: (if $mode == "" then null else $mode end),
       workspacePath: (if $workspace == "" then null else $workspace end),
       writeScopes: (if ($scopes | length) == 0 then null else $scopes end),
       frozenBase: (if $baseIdentity == "" then null else $baseIdentity end),
       changesetBaseline: (if $baseline == "" then null else $baseline end),
       nativeSubagentMode: $nativeMode,
       crossRuntimeMode: $crossMode
     }'
}

_graph_schedule_node_spawn_context_json() {
  _graph_schedule_node_observability_json "$@"
}

# _graph_schedule_admission_summary_json <node-id> <runtime> <subagents> [reason]
# Build a compact admission summary object from the scheduler's current
# capacity counters.  The reason defaults to the last recorded decision reason.
_graph_schedule_admission_summary_json() {
  local node_id="$1" runtime="$2" subagents="$3" reason="${4:-}"
  local requested effective used slots token_used token_cap
  requested="$(_graph_schedule_slots_for_node "$runtime" "$subagents" 0)"
  effective="$(_graph_schedule_runtime_cap "$runtime")"
  if _graph_schedule_runtime_map_index "$runtime" 2>/dev/null; then
    used="${GRAPH_RUNTIME_USED_SLOTS[$GRAPH_RUNTIME_LOOKUP_IDX]:-0}"
  else
    used=0
  fi
  slots="${GRAPH_SCHEDULE_MAX_PARALLEL:-2}"
  token_used="${GRAPH_SCHEDULE_USED_TOKEN_SLOTS:-0}"
  token_cap="${GRAPH_SCHEDULE_TOKEN_CAP:-2}"
  jq -cn \
    --arg nodeId "$node_id" \
    --arg runtime "$runtime" \
    --arg requested "$requested" \
    --arg effective "$effective" \
    --arg used "$used" \
    --arg slots "$slots" \
    --arg tokenUsed "$token_used" \
    --arg tokenCap "$token_cap" \
    --arg reason "${reason:-}" \
    '{
       runtime: $runtime,
       requestedSlots: ($requested | tonumber),
       effectiveRuntimeCap: ($effective | tonumber),
       runtimeUsed: ($used | tonumber),
       globalSlots: ($slots | tonumber),
       tokenUsed: ($tokenUsed | tonumber),
       tokenCap: ($tokenCap | tonumber),
       reason: (if $reason == "" then null else $reason end)
     }'
}

# _graph_schedule_usage_snapshot_from_report <attempt-id>
# Return the latest plan-usage-summary.json from the node's log directory,
# or an empty string when none exists.  This is the node attempt's own usage;
# brokered child usage lives in their own ledgers and must not be merged here.
_graph_schedule_usage_snapshot_from_report() {
  local attempt_id="$1"
  local report_path
  report_path="$(graph_dispatch_report_path "$GRAPH_SCHEDULE_WORKSPACE" "$GRAPH_SCHEDULE_NAMESPACE" "$attempt_id" 2>/dev/null || true)"
  [[ -n "$report_path" ]] || return 0
  local node_log_dir
  node_log_dir="$(dirname "$report_path")"
  node_log_dir="${node_log_dir//stage-outcomes\//\/nodes\/}"
  local candidate="$node_log_dir/plan-usage-summary.json"
  if [[ -f "$candidate" ]]; then
    jq -c . "$candidate" 2>/dev/null || true
    return 0
  fi
  # Fallback: the old layout placed summary beside the report.
  candidate="$(dirname "$report_path")/plan-usage-summary.json"
  [[ -f "$candidate" ]] || return 0
  jq -c . "$candidate" 2>/dev/null || true
}

# _graph_schedule_node_success_observability_json <node-id> <attempt-id> <workspace> <state-root>
# Build the extra_json object attached to a successful agent node's ledger
# entry.  Includes the changeset manifest hash (when mutating), integration
# inputs consumed by a downstream integrate node, the publish readiness
# snapshot, and the admission summary.  Brokered child usage is intentionally
# omitted; child provenance is surfaced by graph-status.sh reading the
# delegation ledger under the parent node.
_graph_schedule_node_success_observability_json() {
  local node_id="$1" attempt_id="$2" workspace="$3" state_root="$4"
  local extra_json changeset_manifest changeset_hash publish_readiness usage_json idx node_runtime node_subagents admission_summary
  extra_json="$(_graph_schedule_node_observability_json "$node_id" "$workspace" "")"
  changeset_manifest=""
  changeset_hash=""
  if graph_changeset_is_mutating "$GRAPH_SCHEDULE_GRAPH_JSON" "$node_id"; then
    changeset_manifest="$(graph_changeset_manifest_path "$GRAPH_SCHEDULE_LEDGER_RUN_DIR" "$node_id" 2>/dev/null || true)"
    if [[ -f "$changeset_manifest" ]]; then
      changeset_hash="$(jq -r '.manifestHash // .baseIdentity // empty' "$changeset_manifest" 2>/dev/null || true)"
    fi
  fi
  publish_readiness="$(jq -r '.publishReadiness // empty' "$GRAPH_SCHEDULE_LEDGER_RUN_DIR/run.json" 2>/dev/null || true)"
  usage_json="$(_graph_schedule_usage_snapshot_from_report "$attempt_id")"
  idx="$(graph_schedule_index_map_get "$node_id" 2>/dev/null)" || idx=""
  node_runtime="${GRAPH_NODE_RUNTIMES[$idx]:-}"
  node_subagents="${GRAPH_NODE_SUBAGENTS[$idx]:-}"
  admission_summary="$(_graph_schedule_admission_summary_json "$node_id" "$node_runtime" "$node_subagents" "admitted")"
  extra_json="$(printf '%s' "$extra_json" | jq -c \
    --arg changeset "${changeset_manifest:-}" \
    --arg changesetHash "${changeset_hash:-}" \
    --arg publish "${publish_readiness:-}" \
    --argjson usage "${usage_json:-null}" \
    --argjson admission "${admission_summary:-null}" \
    '. + {
       changesetManifest: (if $changeset == "" then null else $changeset end),
       changesetHash: (if $changesetHash == "" then null else $changesetHash end),
       publishReadiness: (if $publish == "" then null else ($publish | fromjson) end),
       usageSnapshot: (if $usage == null then null else $usage end),
       admissionSummary: (if $admission == null then null else $admission end)
     }')"
  printf '%s\n' "$extra_json"
}

_graph_schedule_handle_reaped_node() {
  # Uses GRAPH_REAP_* globals from graph_schedule_reap_one. Returns 0 when the
  # node succeeded or was a non-blocking awaiting-ack / expected cancel, 1 when
  # it was an ordinary failure (also sets GRAPH_SCHEDULE_STOP_DISPATCH).
  # Always releases per-runtime slots so failure/cancellation cannot leak a
  # subagents reservation.
  local idx reap_rc="$1"
  local outcome_ok=0 effective_ec outcome
  # Attempt id is the report filename stem; used to append the attempt to the
  # ledger entry so p3-resume can correlate a running node with its report.
  local attempt_id=""
  if [[ -n "$GRAPH_REAP_REPORT_PATH" ]]; then
    attempt_id="$(basename "$GRAPH_REAP_REPORT_PATH")"
    attempt_id="${attempt_id%.json}"
  fi
  local node_runtime="" node_subagents=""
  if idx="$(graph_schedule_index_map_get "$GRAPH_REAP_NODE" 2>/dev/null)"; then
    node_runtime="${GRAPH_NODE_RUNTIMES[$idx]:-}"
    node_subagents="${GRAPH_NODE_SUBAGENTS[$idx]:-}"
  fi
  local finished_at
  finished_at="$(graph_state_now_iso)"

  if ! idx="$(graph_schedule_index_map_get "$GRAPH_REAP_NODE")"; then
    echo "Error: reaped unknown node: $GRAPH_REAP_NODE" >&2
    _graph_schedule_runtime_release "$GRAPH_REAP_NODE"
    _graph_schedule_apply_node_failure "${GRAPH_REAP_NODE}" 1 "unknown-node"
    return 1
  fi

  # Expected cancellation of an in-flight sibling under failurePolicy=cancel.
  if [[ "${GRAPH_SCHEDULE_CANCEL_REQUESTED:-0}" -eq 1 ]]; then
    if [[ "$reap_rc" -eq 2 || "$GRAPH_REAP_MISSING_REPORT" -eq 1 ]]; then
      GRAPH_NODE_STATES[$idx]="cancelled"
      _graph_schedule_runtime_release "$GRAPH_REAP_NODE"
      _graph_schedule_mark_blocked_descendants "$GRAPH_REAP_NODE"
      _graph_schedule_ledger_record "$GRAPH_REAP_NODE" "cancelled" \
        "$attempt_id" "cancelled" "$GRAPH_REAP_EXIT_CODE" "" "$finished_at" \
        "$node_runtime" "$node_subagents" "missing-report-after-cancel"
      echo "graph-schedule: node=$GRAPH_REAP_NODE cancelled (missing report after cancel signal)" >&2
      return 0
    fi
    outcome="$(jq -r '.outcome // "unknown"' "$GRAPH_REAP_REPORT_PATH" 2>/dev/null || echo unknown)"
    if [[ "$outcome" == "cancelled" || "$outcome" != "success" ]]; then
      GRAPH_NODE_STATES[$idx]="cancelled"
      _graph_schedule_runtime_release "$GRAPH_REAP_NODE"
      _graph_schedule_mark_blocked_descendants "$GRAPH_REAP_NODE"
      _graph_schedule_ledger_record "$GRAPH_REAP_NODE" "cancelled" \
        "$attempt_id" "$outcome" "$GRAPH_REAP_EXIT_CODE" "" "$finished_at" \
        "$node_runtime" "$node_subagents" "cancel-outcome=$outcome"
      echo "graph-schedule: node=$GRAPH_REAP_NODE cancelled outcome=$outcome" >&2
      return 0
    fi
    # Unexpected success after cancel signal: still accept and release successors.
  fi

  if [[ "$reap_rc" -eq 2 || "$GRAPH_REAP_MISSING_REPORT" -eq 1 ]]; then
    effective_ec="$(_graph_schedule_effective_exit_code "" "$GRAPH_REAP_EXIT_CODE")"
    # Exit 3 with no report: still non-blocking awaiting-ack.
    if [[ "$effective_ec" -eq 3 ]]; then
      GRAPH_NODE_STATES[$idx]="awaiting-ack"
      _graph_schedule_runtime_release "$GRAPH_REAP_NODE"
      GRAPH_SCHEDULE_AWAITING_ACK=1
      if [[ "$GRAPH_SCHEDULE_EXIT_CODE" -eq 0 ]]; then
        GRAPH_SCHEDULE_EXIT_CODE=3
      fi
      _graph_schedule_ledger_record "$GRAPH_REAP_NODE" "awaiting-ack" \
        "$attempt_id" "awaiting" "$effective_ec" "" "$finished_at" \
        "$node_runtime" "$node_subagents" "missing-report"
      echo "graph-schedule: node=$GRAPH_REAP_NODE awaiting-ack exit=3 (missing report)" >&2
      return 0
    fi
    GRAPH_NODE_STATES[$idx]="failed"
    _graph_schedule_runtime_release "$GRAPH_REAP_NODE"
    _graph_schedule_ledger_record "$GRAPH_REAP_NODE" "failed" \
      "$attempt_id" "failed" "$effective_ec" "" "$finished_at" \
      "$node_runtime" "$node_subagents" "missing-report"
    _graph_schedule_apply_node_failure "$GRAPH_REAP_NODE" "$effective_ec" "missing-report"
    return 1
  fi

  if _graph_schedule_report_is_success "$GRAPH_REAP_REPORT_PATH"; then
    outcome_ok=1
  fi

  if [[ "$outcome_ok" -eq 1 ]]; then
    local succeeded_workspace="$GRAPH_SCHEDULE_WORKSPACE" succeeded_state_root
    succeeded_state_root="${RALPH_PLAN_WORKSPACE_ROOT:-$GRAPH_SCHEDULE_WORKSPACE/.ralph-workspace}"
    if [[ -n "$GRAPH_SCHEDULE_LEDGER_RUN_DIR" && -f "$GRAPH_SCHEDULE_LEDGER_RUN_DIR/run.json" \
      && "$(jq -r '.workspaceManager.schemaVersion // 0' "$GRAPH_SCHEDULE_LEDGER_RUN_DIR/run.json")" == "1" ]]; then
      succeeded_state_root="$(jq -r '.roots.stateRoot' "$GRAPH_SCHEDULE_LEDGER_RUN_DIR/run.json")"
      succeeded_workspace="$(graph_workspace_prepare_node \
        "$GRAPH_SCHEDULE_LEDGER_RUN_DIR" "$GRAPH_SCHEDULE_GRAPH_JSON" "$GRAPH_REAP_NODE")" || {
          _graph_schedule_runtime_release "$GRAPH_REAP_NODE"
          _graph_schedule_apply_node_failure "$GRAPH_REAP_NODE" 1 "workspace-reopen-failed"
          return 1
        }
    fi
    if [[ -n "$GRAPH_SCHEDULE_LEDGER_RUN_DIR" ]] && ! graph_changeset_capture_node \
      "$GRAPH_SCHEDULE_LEDGER_RUN_DIR" "$GRAPH_SCHEDULE_GRAPH_JSON" \
      "$GRAPH_REAP_NODE" "$attempt_id" "$succeeded_workspace" "$succeeded_state_root"; then
      GRAPH_NODE_STATES[$idx]="failed"
      _graph_schedule_runtime_release "$GRAPH_REAP_NODE"
      _graph_schedule_ledger_record "$GRAPH_REAP_NODE" "failed" \
        "$attempt_id" "failed" "1" "" "$finished_at" \
        "$node_runtime" "$node_subagents" "changeset-verification-failed"
      _graph_schedule_apply_node_failure "$GRAPH_REAP_NODE" 1 "changeset-verification-failed"
      return 1
    fi
    if ! _graph_schedule_publish_stage_artifacts \
      "$GRAPH_REAP_NODE" "$succeeded_workspace" "$succeeded_state_root"; then
      GRAPH_NODE_STATES[$idx]="failed"
      _graph_schedule_runtime_release "$GRAPH_REAP_NODE"
      _graph_schedule_ledger_record "$GRAPH_REAP_NODE" "failed" \
        "$attempt_id" "failed" "1" "" "$finished_at" \
        "$node_runtime" "$node_subagents" "artifact-publish-failed"
      _graph_schedule_apply_node_failure "$GRAPH_REAP_NODE" 1 "artifact-publish-failed"
      return 1
    fi
    # A successful subprocess report is only one part of graph-node success.
    # Validate all durable scheduler-owned evidence before publishing the
    # ledger transition that makes descendants runnable.
    # Opt-in keeps existing graph plans byte-compatible; graph v2 callers set
    # RALPH_GRAPH_COMPOSITE_SUCCESS=1 to make the stronger invariant active.
    if [[ -n "$GRAPH_SCHEDULE_LEDGER_RUN_DIR" && "${RALPH_GRAPH_COMPOSITE_SUCCESS:-0}" == "1" ]]; then
      local composite_plan composite_changeset composite_run_file
      composite_plan="$(jq -r --arg id "$GRAPH_REAP_NODE" '.stages[] | select(.id == $id) | .plan // empty' "$GRAPH_SCHEDULE_ORCH_PATH" 2>/dev/null)"
      if [[ -n "$composite_plan" && "$composite_plan" != /* ]]; then
        composite_plan="$succeeded_workspace/$composite_plan"
      fi
      composite_changeset=""
      if graph_changeset_is_mutating "$GRAPH_SCHEDULE_GRAPH_JSON" "$GRAPH_REAP_NODE"; then
        composite_changeset="$(graph_changeset_manifest_path "$GRAPH_SCHEDULE_LEDGER_RUN_DIR" "$GRAPH_REAP_NODE" 2>/dev/null || true)"
      fi
      composite_run_file="$GRAPH_SCHEDULE_LEDGER_RUN_DIR/run.json"
      if ! graph_composite_success_validate "$GRAPH_REAP_REPORT_PATH" \
        "$GRAPH_SCHEDULE_GRAPH_JSON" "$composite_run_file" "$GRAPH_REAP_NODE" \
        "$GRAPH_SCHEDULE_RUN_ID" "$attempt_id" "$succeeded_workspace" \
        "$succeeded_state_root" "$GRAPH_SCHEDULE_NAMESPACE" "$composite_plan" \
        "$composite_changeset"; then
        GRAPH_NODE_STATES[$idx]="failed"
        _graph_schedule_runtime_release "$GRAPH_REAP_NODE"
        _graph_schedule_ledger_record "$GRAPH_REAP_NODE" "failed" \
          "$attempt_id" "failed" "1" "" "$finished_at" \
          "$node_runtime" "$node_subagents" "composite-success-failed:${GRAPH_COMPOSITE_SUCCESS_REASON:-unknown}"
        _graph_schedule_apply_node_failure "$GRAPH_REAP_NODE" 1 "composite-success-failed"
        return 1
      fi
    fi
    GRAPH_NODE_STATES[$idx]="succeeded"
    _graph_schedule_runtime_release "$GRAPH_REAP_NODE"
    local success_extra_json
    success_extra_json="$(_graph_schedule_node_success_observability_json "$GRAPH_REAP_NODE" "$attempt_id" "$succeeded_workspace" "$succeeded_state_root")"
    _graph_schedule_ledger_record "$GRAPH_REAP_NODE" "succeeded" \
      "$attempt_id" "success" "0" "" "$finished_at" \
      "$node_runtime" "$node_subagents" "" "$success_extra_json"
    _graph_schedule_log_observability "node-succeeded" "$GRAPH_REAP_NODE" "$attempt_id" "$node_runtime" "$node_subagents" "$success_extra_json"
    # Release unconditional + conditional(passed) successors; skip conditional
    # (changes-required/error) branches. Regular agent nodes always produce
    # "passed" on success.
    local cond_outcome_rc=0
    _graph_schedule_apply_conditional_outcome "$GRAPH_REAP_NODE" "passed" || cond_outcome_rc=$?
    if [[ "$cond_outcome_rc" -ne 0 && "$cond_outcome_rc" -ne 2 ]]; then
      _graph_schedule_apply_node_failure "$GRAPH_REAP_NODE" 1 "successor-release"
      return 1
    fi
    # Router nodes: resolve decision artifact and skip unselected branches.
    if [[ "${GRAPH_NODE_TYPES[$idx]:-}" == "router" && -n "${GRAPH_SCHEDULE_GRAPH_JSON:-}" ]]; then
      _graph_schedule_apply_router_decision \
        "$GRAPH_REAP_NODE" \
        "$GRAPH_SCHEDULE_GRAPH_JSON" \
        "$GRAPH_SCHEDULE_WORKSPACE" || {
        echo "graph-schedule: router decision failed for node=$GRAPH_REAP_NODE; treating as failure" >&2
        _graph_schedule_apply_node_failure "$GRAPH_REAP_NODE" 1 "router-decision-failed"
        return 1
      }
    fi
    return 0
  fi

  outcome="$(jq -r '.outcome // "unknown"' "$GRAPH_REAP_REPORT_PATH" 2>/dev/null || echo unknown)"
  effective_ec="$(_graph_schedule_effective_exit_code "$GRAPH_REAP_REPORT_PATH" "$GRAPH_REAP_EXIT_CODE")"

  # Exit code 3: human acknowledgement pending. Non-blocking: mark only this
  # node awaiting-ack; do not stop sibling dispatch or block other branches.
  if [[ "$effective_ec" -eq 3 ]]; then
    GRAPH_NODE_STATES[$idx]="awaiting-ack"
    _graph_schedule_runtime_release "$GRAPH_REAP_NODE"
    GRAPH_SCHEDULE_AWAITING_ACK=1
    if [[ "$GRAPH_SCHEDULE_EXIT_CODE" -eq 0 ]]; then
      GRAPH_SCHEDULE_EXIT_CODE=3
    fi
    _graph_schedule_ledger_record "$GRAPH_REAP_NODE" "awaiting-ack" \
      "$attempt_id" "$outcome" "$effective_ec" "" "$finished_at" \
      "$node_runtime" "$node_subagents" "exit-3"
    echo "graph-schedule: node=$GRAPH_REAP_NODE awaiting-ack exit=3" >&2
    return 0
  fi

  # Exit code 4 (stuck/timeout) and every other non-success: ordinary failure.
  # outcome=cancelled without an active cancel request is also ordinary failure
  # for stop-dispatch purposes (e.g. child self-cancelled).
  if [[ "$outcome" == "cancelled" ]]; then
    GRAPH_NODE_STATES[$idx]="cancelled"
    _graph_schedule_ledger_record "$GRAPH_REAP_NODE" "cancelled" \
      "$attempt_id" "cancelled" "$effective_ec" "" "$finished_at" \
      "$node_runtime" "$node_subagents" "outcome=cancelled"
  else
    GRAPH_NODE_STATES[$idx]="failed"
    _graph_schedule_ledger_record "$GRAPH_REAP_NODE" "failed" \
      "$attempt_id" "$outcome" "$effective_ec" "" "$finished_at" \
      "$node_runtime" "$node_subagents" "outcome=$outcome"
  fi
  _graph_schedule_runtime_release "$GRAPH_REAP_NODE"
  _graph_schedule_apply_node_failure "$GRAPH_REAP_NODE" "$effective_ec" "outcome=$outcome"
  return 1
}

# graph_schedule_run <graph_json_path> <run_id> <workspace> [ledger_run_dir]
#
# Load the graph index (or reuse if already loaded for this path), materialize
# the flat orch, and run the ready-set loop to completion. When ledger_run_dir
# is supplied (non-empty), node state transitions and attempt outcomes are
# recorded into the durable run-state ledger at that directory; when empty,
# the run is ledger-less and behavior is unchanged from the pre-ledger path.
graph_schedule_run() {
  local graph_json_path="$1"
  local run_id="$2"
  local workspace="$3"
  local ledger_run_dir="${4:-}"
  local i max_parallel per_runtime ready_id running_count reap_rc spawn_budget
  local ready_tmp ready_idx ready_runtime ready_subagents ready_native_parallel

  if [[ -z "$graph_json_path" || -z "$run_id" || -z "$workspace" ]]; then
    echo "Error: graph_schedule_run requires graph_json_path, run_id, and workspace" >&2
    return 1
  fi
  if [[ ! -f "$graph_json_path" ]]; then
    echo "Error: graph json not found: $graph_json_path" >&2
    return 1
  fi
  if [[ ! -d "$workspace" ]]; then
    echo "Error: workspace directory required: $workspace" >&2
    return 1
  fi
  if [[ -n "$ledger_run_dir" ]]; then
    # Keep supervisor-owned paths in the same physical-root form recorded in
    # run.json. On macOS, mktemp commonly returns /var/folders while pwd -P
    # and the run-base root contract resolve that alias to /private/var/folders.
    # Mixing the two makes RALPH_ORCH_FILE appear to escape the state root even
    # though both names address the same directory.
    ledger_run_dir="$(cd "$ledger_run_dir" 2>/dev/null && pwd -P)" || {
      echo "Error: graph ledger run directory not found: ${4:-}" >&2
      return 1
    }
  fi

  graph_schedule_load_index "$graph_json_path" || return 1
  graph_schedule_clear_children
  GRAPH_DELEGATION_CHILD_PIDS=(); GRAPH_DELEGATION_CHILD_PARENTS=(); GRAPH_DELEGATION_CHILD_IDS=()
  GRAPH_DELEGATION_CHILD_RUNTIMES=(); GRAPH_DELEGATION_CHILD_HELD_SLOTS=(); GRAPH_DELEGATION_CHILD_TOKEN_SLOTS=()
  _graph_schedule_reset_runtime_occupancy

  for ((i = 0; i < ${#GRAPH_NODE_IDS[@]}; i++)); do
    GRAPH_NODE_STATES[$i]="pending"
    GRAPH_NODE_REMAINING_INDEGREE[$i]="${GRAPH_NODE_INDEGREES[$i]}"
    GRAPH_NODE_ATTEMPT_NUMBERS[$i]="0"
    GRAPH_NODE_HELD_SLOTS[$i]="0"
    GRAPH_NODE_HELD_TOKEN_SLOTS[$i]="0"
    GRAPH_NODE_SKIP_PREDECESSOR_COUNT[$i]="0"
  done

  # Global cap: .graph.json maxParallel (default 2), then RALPH_GRAPH_MAX_PARALLEL.
  max_parallel="$(jq -r '.maxParallel // 2' "$graph_json_path")"
  max_parallel="$(_graph_schedule_positive_int_or_default "$max_parallel" 2)"
  if [[ -n "${RALPH_GRAPH_MAX_PARALLEL:-}" ]]; then
    max_parallel="$(_graph_schedule_positive_int_or_default "$RALPH_GRAPH_MAX_PARALLEL" "$max_parallel")"
  fi
  GRAPH_SCHEDULE_MAX_PARALLEL="$max_parallel"
  GRAPH_SCHEDULE_TOKEN_CAP="$max_parallel"
  if [[ -n "${RALPH_GRAPH_MAX_PARALLEL_TOKEN_STREAMS:-}" ]]; then
    GRAPH_SCHEDULE_TOKEN_CAP="$(_graph_schedule_positive_int_or_default "$RALPH_GRAPH_MAX_PARALLEL_TOKEN_STREAMS" "$max_parallel")"
  fi
  GRAPH_SCHEDULE_USED_TOKEN_SLOTS=0
  GRAPH_SCHEDULE_DELEGATION_ACTIVE="$(jq '[.nodes[] | .stage.delegation? | select((.maxChildren // 0) > 0)] | length' "$graph_json_path" 2>/dev/null || echo 0)"

  graph_schedule_delegation_preflight "$graph_json_path" "$max_parallel" || return 1

  # Per-runtime cap: default 1 (overlay journal safety). Required, not optional.
  per_runtime=1
  if [[ -n "${RALPH_GRAPH_MAX_PARALLEL_PER_RUNTIME:-}" ]]; then
    per_runtime="$(_graph_schedule_positive_int_or_default "$RALPH_GRAPH_MAX_PARALLEL_PER_RUNTIME" 1)"
  fi
  GRAPH_SCHEDULE_MAX_PARALLEL_PER_RUNTIME="$per_runtime"
  graph_schedule_native_budget_preflight "$graph_json_path" || return 1

  GRAPH_SCHEDULE_GRAPH_JSON="$graph_json_path"
  GRAPH_SCHEDULE_RUN_ID="$run_id"
  GRAPH_SCHEDULE_WORKSPACE="$workspace"
  GRAPH_SCHEDULE_EXIT_CODE=0
  GRAPH_SCHEDULE_FAILED_NODE=""
  GRAPH_SCHEDULE_STOP_DISPATCH=0
  GRAPH_SCHEDULE_CANCEL_REQUESTED=0
  GRAPH_SCHEDULE_AWAITING_ACK=0
  GRAPH_SCHEDULE_LEDGER_RUN_DIR="$ledger_run_dir"
  GRAPH_SCHEDULE_LEDGER_NAMESPACE=""

  # failurePolicy: drain (default) or cancel. Invalid values fall back to drain.
  GRAPH_SCHEDULE_FAILURE_POLICY="$(jq -r '.failurePolicy // "drain"' "$graph_json_path" 2>/dev/null || echo drain)"
  if [[ "$GRAPH_SCHEDULE_FAILURE_POLICY" != "drain" && "$GRAPH_SCHEDULE_FAILURE_POLICY" != "cancel" ]]; then
    echo "graph-schedule: unknown failurePolicy=$GRAPH_SCHEDULE_FAILURE_POLICY; using drain" >&2
    GRAPH_SCHEDULE_FAILURE_POLICY="drain"
  fi

  if [[ -n "$ledger_run_dir" ]]; then
    GRAPH_SCHEDULE_ORCH_PATH="$(graph_dispatch_materialize_orch "$graph_json_path" "$workspace" \
      "$ledger_run_dir/orchestration-plans/$(jq -r '.namespace // "graph"' "$graph_json_path").orch.json" \
      "$ledger_run_dir")" || return 1
  else
    GRAPH_SCHEDULE_ORCH_PATH="$(graph_dispatch_materialize_orch "$graph_json_path" "$workspace")" || return 1
  fi
  GRAPH_SCHEDULE_NAMESPACE="$(jq -r '.namespace // empty' "$GRAPH_SCHEDULE_ORCH_PATH")"
  if [[ -z "$GRAPH_SCHEDULE_NAMESPACE" ]]; then
    GRAPH_SCHEDULE_NAMESPACE="$(basename "$GRAPH_SCHEDULE_ORCH_PATH" .orch.json)"
  fi
  GRAPH_SCHEDULE_PLAN_KEY="$GRAPH_SCHEDULE_NAMESPACE"
  GRAPH_SCHEDULE_LEDGER_NAMESPACE="$GRAPH_SCHEDULE_NAMESPACE"

  # Structured transition log in the same format as the orchestrator log so the
  # logs directory stays greppable.  One line per state transition.
  GRAPH_SCHEDULE_LOG_FILE=""
  GRAPH_SCHEDULE_ADMISSION_LOG_FILE=""
  if [[ -n "$ledger_run_dir" ]]; then
    local _sched_log_dir _sched_state_root
    _sched_state_root="${RALPH_PLAN_WORKSPACE_ROOT:-$workspace/.ralph-workspace}"
    if [[ -f "$ledger_run_dir/run.json" ]]; then
      _sched_state_root="$(jq -r '.roots.stateRoot // empty' "$ledger_run_dir/run.json" 2>/dev/null || true)"
      [[ -n "$_sched_state_root" && "$_sched_state_root" != "null" ]] || \
        _sched_state_root="${RALPH_PLAN_WORKSPACE_ROOT:-$workspace/.ralph-workspace}"
    fi
    _sched_log_dir="$_sched_state_root/logs/$GRAPH_SCHEDULE_NAMESPACE"
    mkdir -p "$_sched_log_dir" 2>/dev/null || true
    GRAPH_SCHEDULE_LOG_FILE="$_sched_log_dir/graph-schedule-${run_id}.log"
    touch "$GRAPH_SCHEDULE_LOG_FILE" 2>/dev/null || GRAPH_SCHEDULE_LOG_FILE=""
  fi
  local _admission_log_dir
  if [[ -n "$GRAPH_SCHEDULE_LOG_FILE" ]]; then
    _admission_log_dir="$(dirname "$GRAPH_SCHEDULE_LOG_FILE")"
  else
    _admission_log_dir="${RALPH_PLAN_WORKSPACE_ROOT:-$workspace/.ralph-workspace}/logs/$GRAPH_SCHEDULE_NAMESPACE"
  fi
  mkdir -p "$_admission_log_dir" 2>/dev/null || true
  GRAPH_SCHEDULE_ADMISSION_LOG_FILE="$_admission_log_dir/graph-admission-${run_id}.jsonl"
  : >"$GRAPH_SCHEDULE_ADMISSION_LOG_FILE" 2>/dev/null || GRAPH_SCHEDULE_ADMISSION_LOG_FILE=""
  graph_schedule_recover_delegated_children

  ready_tmp="$(mktemp "${TMPDIR:-/tmp}/ralph-graph-ready.XXXXXX")" || return 1

  while true; do
    graph_schedule_drain_delegated_children
    running_count="$(_graph_schedule_count_running)"

    if [[ "$GRAPH_SCHEDULE_STOP_DISPATCH" -eq 0 ]]; then
      graph_schedule_ready_ids >"$ready_tmp"
      spawn_budget=$(( GRAPH_SCHEDULE_MAX_PARALLEL - $(_graph_schedule_count_active_invocations) ))
      if [[ "$spawn_budget" -lt 0 ]]; then
        spawn_budget=0
      fi
      while IFS= read -r ready_id || [[ -n "$ready_id" ]]; do
        [[ -z "$ready_id" ]] && continue
        [[ "$spawn_budget" -le 0 ]] && break
        # Skip if already spawned this wave (state no longer pending).
        if [[ "$(graph_schedule_node_state_by_id "$ready_id")" != "pending" ]]; then
          continue
        fi
        if ! ready_idx="$(graph_schedule_index_map_get "$ready_id")"; then
          continue
        fi
        ready_runtime="${GRAPH_NODE_RUNTIMES[$ready_idx]}"
        ready_subagents="${GRAPH_NODE_SUBAGENTS[$ready_idx]}"
        ready_native_parallel="${GRAPH_NODE_NATIVE_PARALLEL[$ready_idx]:-0}"
        # Checkpoint nodes are handled synchronously without spawning a process.
        # They do not consume the spawn budget or go through runtime admission.
        if [[ "${GRAPH_NODE_TYPES[$ready_idx]:-}" == "checkpoint" ]]; then
          _graph_schedule_handle_checkpoint_node "$ready_id" || true
          continue
        fi
        # consensus-barrier nodes never have a runtime/agent; they always
        # dispatch synchronously in-process.
        if [[ "${GRAPH_NODE_TYPES[$ready_idx]:-}" == "consensus-barrier" ]]; then
          _graph_schedule_handle_consensus_barrier_node "$ready_id" || true
          continue
        fi
        if [[ "${GRAPH_NODE_TYPES[$ready_idx]:-}" == "integrate" ]]; then
          _graph_schedule_handle_integration_node "$ready_id" || true
          continue
        fi
        # Gate nodes are model-free verification gates handled synchronously
        # in-process. They run allowlisted commands from a verificationProfile
        # and write gate-result.json; they never invoke an orchestrator or model.
        if [[ "${GRAPH_NODE_TYPES[$ready_idx]:-}" == "gate" ]]; then
          _graph_schedule_handle_gate_node "$ready_id" || true
          continue
        fi
        # A join node with no declared runtime is a policy pass-through
        # (see _graph_schedule_handle_join_node); a join node that declares
        # a runtime (a manually authored adjudicator) falls through to
        # ordinary agent dispatch below, preserving existing behavior.
        if [[ "${GRAPH_NODE_TYPES[$ready_idx]:-}" == "join" && -z "$ready_runtime" ]]; then
          _graph_schedule_handle_join_node "$ready_id" || true
          continue
        fi
        # Per-runtime / subagents reservation may block this node while another
        # ready node on a different runtime remains eligible -- continue, do not break.
        if ! _graph_schedule_runtime_can_admit "$ready_runtime" "$ready_subagents" "" "$ready_native_parallel"; then
          _graph_schedule_log_admission "denied" "graph-node" "$ready_id" "$ready_runtime" "$ready_subagents" \
            "$(_graph_schedule_slots_for_node "$ready_runtime" "$ready_subagents" "$ready_native_parallel")" "$(_graph_schedule_slots_for_node "$ready_runtime" "$ready_subagents" "$ready_native_parallel")" "runtime-or-token-cap"
          local denied_summary
          denied_summary="$(_graph_schedule_admission_summary_json "$ready_id" "$ready_runtime" "$ready_subagents" "runtime-or-token-cap")"
          _graph_schedule_ledger_record "$ready_id" "ready" "" "" "" "" "" "" "$ready_runtime" "$ready_subagents" "admission-denied" "$denied_summary"
          continue
        fi
        _graph_schedule_spawn_node "$ready_id" || {
          rm -f "$ready_tmp"
          GRAPH_SCHEDULE_EXIT_CODE=1
          return 1
        }
        spawn_budget=$((spawn_budget - 1))
        running_count=$((running_count + 1))
      done <"$ready_tmp"
    fi

    running_count="$(_graph_schedule_count_running)"
    if [[ "$running_count" -eq 0 ]]; then
      # Synchronous handlers (checkpoint/consensus-barrier/join/gate) can
      # release new successors without ever spawning a tracked subprocess, so
      # running_count alone cannot decide the run is done -- re-check the
      # ready set before concluding no more progress is possible.
      if [[ "$GRAPH_SCHEDULE_STOP_DISPATCH" -eq 0 ]]; then
        graph_schedule_ready_ids >"$ready_tmp"
        if [[ -s "$ready_tmp" ]]; then
          continue
        fi
      fi
      break
    fi

    reap_rc=0
    # Discard the machine-readable reap line; callers use GRAPH_REAP_* globals.
    graph_schedule_reap_one >/dev/null || reap_rc=$?
    if [[ "$reap_rc" -eq 1 ]]; then
      echo "Error: graph_schedule_reap_one failed while children were tracked" >&2
      rm -f "$ready_tmp"
      GRAPH_SCHEDULE_EXIT_CODE=1
      return 1
    fi
    _graph_schedule_handle_reaped_node "$reap_rc" || true
  done

  rm -f "$ready_tmp"

  # No tracked children should remain after the loop.
  if [[ "$(graph_schedule_child_count)" -ne 0 ]]; then
    echo "Error: graph-schedule: orphan tracked children remain: $(graph_schedule_child_count)" >&2
    GRAPH_SCHEDULE_EXIT_CODE=1
    return 1
  fi

  if _graph_schedule_all_succeeded; then
    GRAPH_SCHEDULE_EXIT_CODE=0
    if [[ -n "$GRAPH_SCHEDULE_LEDGER_RUN_DIR" ]]; then
      graph_state_set_run_status "$GRAPH_SCHEDULE_WORKSPACE" \
        "$GRAPH_SCHEDULE_LEDGER_NAMESPACE" "$GRAPH_SCHEDULE_RUN_ID" "succeeded" 2>/dev/null || true
    fi
    return 0
  fi

  if [[ "$GRAPH_SCHEDULE_EXIT_CODE" -eq 0 ]]; then
    if [[ "$GRAPH_SCHEDULE_AWAITING_ACK" -eq 1 ]]; then
      GRAPH_SCHEDULE_EXIT_CODE=3
    else
      GRAPH_SCHEDULE_EXIT_CODE=1
    fi
  fi
  if [[ -n "$GRAPH_SCHEDULE_LEDGER_RUN_DIR" ]]; then
    local run_status="failed"
    if [[ "$GRAPH_SCHEDULE_AWAITING_ACK" -eq 1 ]]; then
      run_status="awaiting-ack"
    fi
    graph_state_set_run_status "$GRAPH_SCHEDULE_WORKSPACE" \
      "$GRAPH_SCHEDULE_LEDGER_NAMESPACE" "$GRAPH_SCHEDULE_RUN_ID" "$run_status" 2>/dev/null || true
  fi
  if [[ -n "$GRAPH_SCHEDULE_FAILED_NODE" ]]; then
    echo "graph-schedule: run failed node=$GRAPH_SCHEDULE_FAILED_NODE exit=$GRAPH_SCHEDULE_EXIT_CODE policy=$GRAPH_SCHEDULE_FAILURE_POLICY" >&2
  elif [[ "$GRAPH_SCHEDULE_AWAITING_ACK" -eq 1 ]]; then
    echo "graph-schedule: run awaiting-ack exit=$GRAPH_SCHEDULE_EXIT_CODE" >&2
  else
    echo "graph-schedule: run incomplete; not all nodes succeeded exit=$GRAPH_SCHEDULE_EXIT_CODE" >&2
  fi
  return "$GRAPH_SCHEDULE_EXIT_CODE"
}

# ---------------------------------------------------------------------------
# Resume (p3-resume)
#
# Resume accepts either an explicit run id or the literal token `latest`. On
# resume the plan is recompiled and the new graphSha is compared to the one
# recorded in run.json. If they differ, resume refuses unless
# --accept-graph-change is supplied; when it is, every node whose own stage
# JSON or ancestor set changed is invalidated (reset to pending), so a stale
# success is never silently carried forward. Silently resuming onto a mutated
# graph is how these systems corrupt state, so the refusal is deliberate.
#
# Node reconciliation:
#   succeeded        -> stays succeeded; skipped with a log line
#   running          -> look for a StageOutcomeReport matching lastAttemptId;
#                       adopt it (mark succeeded/failed per the report) if
#                       present, otherwise reset to pending (the previous
#                       scheduler died mid-flight with no recoverable outcome)
#   failed/cancelled/blocked -> reset to pending
#   awaiting-ack     -> stays awaiting-ack (human ack is still pending)
#   skipped          -> stays skipped
#
# Idempotency inside a node comes for free: the node body is an ordinary Ralph
# plan whose completed todos are already marked done, and run-plan.sh skips
# completed todos. This is the load-bearing reason the loop and graph hybrid
# works: a resumed node does not redo its finished todos, only the remaining
# ones. This must not be weakened by encoding graph progress into plan
# checkboxes — the ledger is the graph state and the plan is the loop state.
# ---------------------------------------------------------------------------

# _graph_schedule_reconcile_node <node_id> <frozen_graph_path>
#
# Reconciles one node's in-memory state against its ledger entry. Sets
# GRAPH_NODE_STATES, GRAPH_NODE_REMAINING_INDEGREE, and GRAPH_NODE_ATTEMPT_NUMBERS
# for the node. Returns 0 when the node is skippable (succeeded/awaiting-ack/
# skipped), 1 when it needs to run (pending/running-reset). On a running node
# with an adoptable StageOutcomeReport, marks the node succeeded or failed per
# the report and records the adopted attempt to the ledger.
_graph_schedule_reconcile_node() {
  local node_id="$1" frozen_graph="$2"
  local idx status last_attempt_id report_path outcome exit_code
  local node_runtime node_subagents finished_at node_file durable_attempt_number

  if ! idx="$(graph_schedule_index_map_get "$node_id")"; then
    echo "Error: reconcile: unknown node id: $node_id" >&2
    return 1
  fi

  status="$(graph_state_node_status "$GRAPH_SCHEDULE_WORKSPACE" \
    "$GRAPH_SCHEDULE_LEDGER_NAMESPACE" "$GRAPH_SCHEDULE_RUN_ID" "$node_id" 2>/dev/null)" || status="pending"
  [[ -z "$status" ]] && status="pending"

  node_runtime="${GRAPH_NODE_RUNTIMES[$idx]}"
  node_subagents="${GRAPH_NODE_SUBAGENTS[$idx]}"
  node_file="$(graph_state_node_file "$GRAPH_SCHEDULE_WORKSPACE" \
    "$GRAPH_SCHEDULE_LEDGER_NAMESPACE" "$GRAPH_SCHEDULE_RUN_ID" "$node_id" 2>/dev/null || true)"
  durable_attempt_number=0
  if [[ -n "$node_file" && -f "$node_file" ]]; then
    durable_attempt_number="$(jq '[.attempts[]?.attemptId? // empty | try (capture("__(?<number>[0-9]+)$").number | tonumber) catch empty] | max // 0' "$node_file" 2>/dev/null || echo 0)"
    [[ "$durable_attempt_number" =~ ^[0-9]+$ ]] || durable_attempt_number=0
  fi
  GRAPH_NODE_ATTEMPT_NUMBERS[$idx]="$durable_attempt_number"

  case "$status" in
    succeeded)
      # Composite records are written only by newer ledger-backed runs.  Their
      # absence is a backward-compatible legacy success; when present, a hash
      # mismatch invalidates this node and descendants, not unrelated lanes.
      last_attempt_id="$(graph_state_node_last_attempt_id "$GRAPH_SCHEDULE_WORKSPACE" \
        "$GRAPH_SCHEDULE_LEDGER_NAMESPACE" "$GRAPH_SCHEDULE_RUN_ID" "$node_id" 2>/dev/null)" || last_attempt_id=""
      # Runs created by an older scheduler may already contain an adopted
      # success without the supervisor-owned changeset capture that normally
      # follows a successful report.  Heal that narrow crash window before
      # treating the node as reusable.
      if [[ -n "$GRAPH_SCHEDULE_LEDGER_RUN_DIR" && -n "$last_attempt_id" ]] \
        && graph_changeset_is_mutating "$frozen_graph" "$node_id"; then
        local reconcile_manifest reconcile_workspace reconcile_state_root
        reconcile_manifest="$(graph_changeset_manifest_path \
          "$GRAPH_SCHEDULE_LEDGER_RUN_DIR" "$node_id" 2>/dev/null || true)"
        if [[ -z "$reconcile_manifest" || ! -f "$reconcile_manifest" ]]; then
          reconcile_workspace="$GRAPH_SCHEDULE_WORKSPACE"
          reconcile_state_root="${RALPH_PLAN_WORKSPACE_ROOT:-$GRAPH_SCHEDULE_WORKSPACE/.ralph-workspace}"
          if [[ -f "$GRAPH_SCHEDULE_LEDGER_RUN_DIR/run.json" \
            && "$(jq -r '.workspaceManager.schemaVersion // 0' "$GRAPH_SCHEDULE_LEDGER_RUN_DIR/run.json")" == "1" ]]; then
            reconcile_state_root="$(jq -r '.roots.stateRoot' "$GRAPH_SCHEDULE_LEDGER_RUN_DIR/run.json")"
            reconcile_workspace="$(graph_workspace_prepare_node \
              "$GRAPH_SCHEDULE_LEDGER_RUN_DIR" "$frozen_graph" "$node_id")" || reconcile_workspace=""
          fi
          if [[ -z "$reconcile_workspace" ]] || ! graph_changeset_capture_node \
            "$GRAPH_SCHEDULE_LEDGER_RUN_DIR" "$frozen_graph" "$node_id" \
            "$last_attempt_id" "$reconcile_workspace" "$reconcile_state_root" \
            || ! _graph_schedule_publish_stage_artifacts \
              "$node_id" "$reconcile_workspace" "$reconcile_state_root"; then
            _graph_schedule_invalidate_node_descendants "$node_id" "$frozen_graph"
            GRAPH_NODE_STATES[$idx]="pending"
            echo "graph-resume: node=$node_id missing durable success evidence; invalidating node and descendants" >&2
            return 1
          fi
          echo "graph-resume: node=$node_id repaired missing adopted-success changeset" >&2
        fi
      fi
      if [[ "${RALPH_GRAPH_COMPOSITE_SUCCESS:-0}" == "1" && -n "$last_attempt_id" ]]; then
        local composite_state_root composite_record
        composite_state_root="$(jq -r '.roots.stateRoot // empty' "$GRAPH_SCHEDULE_LEDGER_RUN_DIR/run.json" 2>/dev/null)"
        composite_record="$(graph_composite_success_path "$composite_state_root" "$GRAPH_SCHEDULE_NAMESPACE" "$node_id" "$last_attempt_id" 2>/dev/null || true)"
        if [[ -n "$composite_record" && -e "$composite_record" ]] && ! graph_composite_success_reusable \
          "$frozen_graph" "$GRAPH_SCHEDULE_LEDGER_RUN_DIR/run.json" "$node_id" \
          "$GRAPH_SCHEDULE_RUN_ID" "$last_attempt_id" "$composite_state_root" "$GRAPH_SCHEDULE_NAMESPACE"; then
          _graph_schedule_invalidate_node_descendants "$node_id" "$frozen_graph"
          GRAPH_NODE_STATES[$idx]="pending"
          echo "graph-resume: node=$node_id composite inputs changed; invalidating node and descendants" >&2
          return 1
        fi
      fi
      GRAPH_NODE_STATES[$idx]="succeeded"
      # Decrement successors so descendants become ready as if the node ran.
      # A node with conditional successors (gate/regate nodes in particular,
      # e.g. inside a v2-repair-epochs round) must replay its recorded
      # semantic outcome through apply_conditional_outcome rather than just
      # releasing unconditional successors, or the correct branch (and the
      # skip-cascade of the branches not taken) never happens on resume and
      # the run deadlocks mid-round. Regular agent/integrate nodes only ever
      # produce "passed" on success; only gate-typed nodes can have recorded
      # a changes-required outcome (routed through a repair edge) while still
      # ending in ledger status "succeeded".
      if [[ -n "${GRAPH_NODE_COND_SUCCESSORS[$idx]:-}" ]]; then
        local reconcile_outcome="passed"
        if [[ "${GRAPH_NODE_TYPES[$idx]:-}" == "gate" ]]; then
          local reconcile_reason
          reconcile_reason="$(graph_state_node_last_attempt_reason \
            "$GRAPH_SCHEDULE_WORKSPACE" "$GRAPH_SCHEDULE_LEDGER_NAMESPACE" \
            "$GRAPH_SCHEDULE_RUN_ID" "$node_id" 2>/dev/null)" || reconcile_reason=""
          case "$reconcile_reason" in
            *changes-required*) reconcile_outcome="changes-required" ;;
          esac
        fi
        _graph_schedule_apply_conditional_outcome "$node_id" "$reconcile_outcome" || true
      else
        _graph_schedule_release_successors "$node_id" || true
      fi
      echo "graph-resume: node=$node_id succeeded; skipping" >&2
      return 0
      ;;
    awaiting-ack)
      # For checkpoint nodes, check if the ack file now exists. If the human
      # acknowledged since the last run, the checkpoint transitions to succeeded
      # and its subtree unblocks. Blocked descendants are reset to pending by
      # the failed/cancelled/blocked handler in this same reconcile loop, and
      # their remaining indegree is decremented here so they become ready.
      # If the ack file is still absent, the node stays awaiting-ack and its
      # pending descendants keep remaining_indegree > 0 (not released), so they
      # remain non-ready and the resume is a clean no-op.
      if [[ "${GRAPH_NODE_TYPES[$idx]:-}" == "checkpoint" ]]; then
        local ck_ack_path=""
        ck_ack_path="$(_graph_schedule_checkpoint_ack_path "$node_id")" || true
        if [[ -n "$ck_ack_path" && -f "$ck_ack_path" ]]; then
          GRAPH_NODE_STATES[$idx]="succeeded"
          _graph_schedule_release_successors "$node_id" || true
          _graph_schedule_ledger_record "$node_id" "succeeded" \
            "" "success" "0" "" "$(graph_state_now_iso)" "" "" "checkpoint-ack-received"
          echo "graph-resume: node=$node_id checkpoint ack received; transitioning to succeeded" >&2
          return 0
        fi
      fi
      GRAPH_NODE_STATES[$idx]="awaiting-ack"
      GRAPH_SCHEDULE_AWAITING_ACK=1
      # awaiting-ack keeps successors unreleased by design (exit-3 semantics).
      echo "graph-resume: node=$node_id awaiting-ack; skipping" >&2
      return 0
      ;;
    skipped)
      GRAPH_NODE_STATES[$idx]="skipped"
      _graph_schedule_release_successors "$node_id" || true
      echo "graph-resume: node=$node_id skipped; skipping" >&2
      return 0
      ;;
    running)
      # Previous scheduler died mid-flight. Look for a StageOutcomeReport
      # matching lastAttemptId and adopt it if present; otherwise reset.
      last_attempt_id="$(graph_state_node_last_attempt_id "$GRAPH_SCHEDULE_WORKSPACE" \
        "$GRAPH_SCHEDULE_LEDGER_NAMESPACE" "$GRAPH_SCHEDULE_RUN_ID" "$node_id" 2>/dev/null)" || last_attempt_id=""
      if [[ -n "$last_attempt_id" ]]; then
        report_path="$(graph_dispatch_report_path "$GRAPH_SCHEDULE_WORKSPACE" \
          "$GRAPH_SCHEDULE_LEDGER_NAMESPACE" "$last_attempt_id")"
        if [[ -f "$report_path" ]]; then
          outcome="$(jq -r '.outcome // empty' "$report_path" 2>/dev/null)" || outcome=""
          exit_code="$(jq -r '.exitCode // empty' "$report_path" 2>/dev/null)" || exit_code=""
          finished_at="$(graph_state_now_iso)"
          if [[ "$outcome" == "success" ]]; then
            # A StageOutcomeReport is written by the node subprocess before
            # the scheduler performs its supervisor-owned success work.  If
            # the scheduler dies in that window, adopting the report alone is
            # insufficient: mutating nodes still need a scoped changeset and
            # declared artifacts still need publishing before descendants may
            # run.  Replay those idempotent finalization steps during resume.
            local adopted_workspace="$GRAPH_SCHEDULE_WORKSPACE" adopted_state_root adopted_extra_json
            adopted_state_root="${RALPH_PLAN_WORKSPACE_ROOT:-$GRAPH_SCHEDULE_WORKSPACE/.ralph-workspace}"
            if [[ -n "$GRAPH_SCHEDULE_LEDGER_RUN_DIR" && -f "$GRAPH_SCHEDULE_LEDGER_RUN_DIR/run.json" \
              && "$(jq -r '.workspaceManager.schemaVersion // 0' "$GRAPH_SCHEDULE_LEDGER_RUN_DIR/run.json")" == "1" ]]; then
              adopted_state_root="$(jq -r '.roots.stateRoot' "$GRAPH_SCHEDULE_LEDGER_RUN_DIR/run.json")"
              adopted_workspace="$(graph_workspace_prepare_node \
                "$GRAPH_SCHEDULE_LEDGER_RUN_DIR" "$frozen_graph" "$node_id")" || {
                  GRAPH_NODE_STATES[$idx]="pending"
                  _graph_schedule_ledger_record "$node_id" "failed" \
                    "$last_attempt_id" "failed" "1" "" "$finished_at" \
                    "$node_runtime" "$node_subagents" "orphan-workspace-reopen-failed"
                  echo "graph-resume: node=$node_id orphan finalization failed reopening workspace; resetting to pending" >&2
                  return 1
                }
            fi
            if [[ -n "$GRAPH_SCHEDULE_LEDGER_RUN_DIR" ]] && ! graph_changeset_capture_node \
              "$GRAPH_SCHEDULE_LEDGER_RUN_DIR" "$frozen_graph" "$node_id" \
              "$last_attempt_id" "$adopted_workspace" "$adopted_state_root"; then
              GRAPH_NODE_STATES[$idx]="pending"
              _graph_schedule_ledger_record "$node_id" "failed" \
                "$last_attempt_id" "failed" "1" "" "$finished_at" \
                "$node_runtime" "$node_subagents" "orphan-changeset-verification-failed"
              echo "graph-resume: node=$node_id orphan changeset finalization failed; resetting to pending" >&2
              return 1
            fi
            if ! _graph_schedule_publish_stage_artifacts \
              "$node_id" "$adopted_workspace" "$adopted_state_root"; then
              GRAPH_NODE_STATES[$idx]="pending"
              _graph_schedule_ledger_record "$node_id" "failed" \
                "$last_attempt_id" "failed" "1" "" "$finished_at" \
                "$node_runtime" "$node_subagents" "orphan-artifact-publish-failed"
              echo "graph-resume: node=$node_id orphan artifact finalization failed; resetting to pending" >&2
              return 1
            fi
            GRAPH_NODE_STATES[$idx]="succeeded"
            adopted_extra_json="$(_graph_schedule_node_success_observability_json \
              "$node_id" "$last_attempt_id" "$adopted_workspace" "$adopted_state_root")"
            _graph_schedule_ledger_record "$node_id" "succeeded" \
              "$last_attempt_id" "success" "0" "" "$finished_at" \
              "$node_runtime" "$node_subagents" "adopted-orphan-report" "$adopted_extra_json"
            _graph_schedule_apply_conditional_outcome "$node_id" "passed" || true
            echo "graph-resume: node=$node_id running -> adopted orphaned report (success); skipping" >&2
            return 0
          fi
          # Non-success report: treat as failed and let the loop retry or block.
          GRAPH_NODE_STATES[$idx]="failed"
          _graph_schedule_ledger_record "$node_id" "failed" \
            "$last_attempt_id" "$outcome" "$exit_code" "" "$finished_at" \
            "$node_runtime" "$node_subagents" "adopted-orphan-report"
          echo "graph-resume: node=$node_id running -> adopted orphaned report (outcome=$outcome); resetting to pending" >&2
          # Fall through to reset path below by treating as a non-terminal state.
          GRAPH_NODE_STATES[$idx]="pending"
          return 1
        fi
      fi
      # No adoptable report: reset to pending so the loop re-runs the node.
      GRAPH_NODE_STATES[$idx]="pending"
      graph_state_reset_node_to_pending "$GRAPH_SCHEDULE_WORKSPACE" \
        "$GRAPH_SCHEDULE_LEDGER_NAMESPACE" "$GRAPH_SCHEDULE_RUN_ID" "$node_id" 2>/dev/null || true
      echo "graph-resume: node=$node_id running -> no report; resetting to pending" >&2
      return 1
      ;;
    failed|cancelled|blocked|pending|ready)
      GRAPH_NODE_STATES[$idx]="pending"
      graph_state_reset_node_to_pending "$GRAPH_SCHEDULE_WORKSPACE" \
        "$GRAPH_SCHEDULE_LEDGER_NAMESPACE" "$GRAPH_SCHEDULE_RUN_ID" "$node_id" 2>/dev/null || true
      echo "graph-resume: node=$node_id $status -> resetting to pending" >&2
      return 1
      ;;
    *)
      GRAPH_NODE_STATES[$idx]="pending"
      graph_state_reset_node_to_pending "$GRAPH_SCHEDULE_WORKSPACE" \
        "$GRAPH_SCHEDULE_LEDGER_NAMESPACE" "$GRAPH_SCHEDULE_RUN_ID" "$node_id" 2>/dev/null || true
      echo "graph-resume: node=$node_id unknown status=$status -> resetting to pending" >&2
      return 1
      ;;
  esac
}

# Reset exactly one stale node and its transitive descendants.  The frozen DAG
# is authoritative, so sibling lanes that do not consume the changed result
# remain succeeded and retain their workspaces, changesets, and gates.
_graph_schedule_invalidate_node_descendants() {
  local root="$1" graph="$2" ancestors_file node_id ancestors
  ancestors_file="$(mktemp "${TMPDIR:-/tmp}/ralph-composite-ancestors.XXXXXX")" || return 1
  graph_state_ancestor_sets "$graph" >"$ancestors_file" 2>/dev/null || { rm -f "$ancestors_file"; return 1; }
  while IFS=$'\t' read -r node_id ancestors || [[ -n "$node_id" ]]; do
    [[ "$node_id" == "$root" || " $ancestors " == *" $root "* ]] || continue
    graph_state_reset_node_to_pending "$GRAPH_SCHEDULE_WORKSPACE" \
      "$GRAPH_SCHEDULE_LEDGER_NAMESPACE" "$GRAPH_SCHEDULE_RUN_ID" "$node_id" 2>/dev/null || true
  done <"$ancestors_file"
  rm -f "$ancestors_file"
}

# graph_schedule_resume <workspace> <namespace> <run_id_or_latest> <plan_path>
#   [--accept-graph-change] [--frozen-graph <path>]
#
# Resumes a graph run. Resolves the run id, recompiles the plan, compares
# graphSha, reconciles node states from the ledger, and continues the
# ready-set loop. Returns the scheduler exit code.
graph_schedule_resume() {
  local workspace="$1" namespace="$2" run_token="$3" plan_path="$4"
  shift 4
  local accept_change=0 frozen_graph_override=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --accept-graph-change) accept_change=1; shift ;;
      --frozen-graph) frozen_graph_override="$2"; shift 2 ;;
      --frozen-graph=*) frozen_graph_override="${1#--frozen-graph=}"; shift ;;
      *) shift ;;
    esac
  done

  if [[ -z "$workspace" || -z "$namespace" || -z "$run_token" || -z "$plan_path" ]]; then
    echo "Error: graph_schedule_resume requires workspace, namespace, run_token, plan_path" >&2
    return 1
  fi
  command -v jq >/dev/null 2>&1 || return 1

  local run_id run_file frozen_graph old_sha new_graph new_sha
  run_id="$(graph_state_resolve_run_id "$workspace" "$namespace" "$run_token")" || {
    echo "Error: graph_schedule_resume could not resolve run id from token '$run_token'" >&2
    return 1
  }
  run_file="$(graph_state_run_file "$workspace" "$namespace" "$run_id")"
  if [[ ! -f "$run_file" ]]; then
    echo "Error: graph_schedule_resume run not found: $run_id" >&2
    return 1
  fi
  frozen_graph="$(graph_state_graph_file "$workspace" "$namespace" "$run_id")"
  if [[ -n "$frozen_graph_override" ]]; then
    frozen_graph="$frozen_graph_override"
  fi
  if [[ ! -f "$frozen_graph" ]]; then
    echo "Error: graph_schedule_resume frozen graph not found: $frozen_graph" >&2
    return 1
  fi

  old_sha="$(graph_state_field "$run_file" "graphSha")" || old_sha=""

  # Recompile the plan and compare graphSha. Use a temp file so the cached
  # graph beside the plan is not disturbed.
  new_graph="$(mktemp "${TMPDIR:-/tmp}/ralph-graph-resume.XXXXXX")" || return 1
  if ! plan_pipeline_graph_json "$plan_path" >"$new_graph" 2>/dev/null; then
    rm -f "$new_graph"
    echo "Error: graph_schedule_resume failed to recompile plan: $plan_path" >&2
    return 1
  fi
  if [[ "$(jq -r '.namespace // empty' "$new_graph")" != "$namespace" ]]; then
    local namespaced_graph
    namespaced_graph="$(mktemp "${TMPDIR:-/tmp}/ralph-graph-resume-namespace.XXXXXX")" || {
      rm -f "$new_graph"
      return 1
    }
    jq --arg namespace "$namespace" '.namespace = $namespace' "$new_graph" >"$namespaced_graph" || {
      rm -f "$new_graph" "$namespaced_graph"
      return 1
    }
    mv -f "$namespaced_graph" "$new_graph"
  fi
  new_sha="$(graph_state_compute_graph_sha "$new_graph")" || {
    rm -f "$new_graph"
    return 1
  }

  if [[ "$old_sha" != "$new_sha" ]]; then
    if [[ "$accept_change" -ne 1 ]]; then
      echo "Error: graph changed since run $run_id was started" >&2
      echo "Error: old graphSha=$old_sha" >&2
      echo "Error: new graphSha=$new_sha" >&2
      echo "Error: pass --accept-graph-change to invalidate affected nodes and proceed" >&2
      rm -f "$new_graph"
      return 1
    fi
    # Invalidate every node whose own stage JSON or ancestor set changed.
    # Use the frozen graph for old digests/ancestors and the new graph for
    # the comparison; nodes that match on both axes stay succeeded, others
    # reset to pending.
    echo "graph-resume: graph changed; invalidating affected nodes" >&2
    _graph_schedule_invalidate_changed_nodes "$workspace" "$namespace" "$run_id" \
      "$frozen_graph" "$new_graph"
  fi
  rm -f "$new_graph"

  # Mark the run as running again.
  graph_state_set_run_status "$workspace" "$namespace" "$run_id" "running" 2>/dev/null || true

  # Load the (possibly updated) frozen graph into the in-memory index. When
  # the graph changed and --accept-graph-change was supplied, the frozen
  # graph.json in the run directory is replaced with the recompiled one so
  # the scheduler operates on the new contract.
  graph_schedule_load_index "$frozen_graph" || return 1
  graph_schedule_clear_children
  GRAPH_DELEGATION_CHILD_PIDS=(); GRAPH_DELEGATION_CHILD_PARENTS=(); GRAPH_DELEGATION_CHILD_IDS=()
  GRAPH_DELEGATION_CHILD_RUNTIMES=(); GRAPH_DELEGATION_CHILD_HELD_SLOTS=(); GRAPH_DELEGATION_CHILD_TOKEN_SLOTS=()
  _graph_schedule_reset_runtime_occupancy

  # Reconcile each node from the ledger and recompute remaining indegrees.
  local i
  for ((i = 0; i < ${#GRAPH_NODE_IDS[@]}; i++)); do
    GRAPH_NODE_STATES[$i]="pending"
    GRAPH_NODE_REMAINING_INDEGREE[$i]="${GRAPH_NODE_INDEGREES[$i]}"
    GRAPH_NODE_ATTEMPT_NUMBERS[$i]="0"
    GRAPH_NODE_HELD_SLOTS[$i]="0"
    GRAPH_NODE_HELD_TOKEN_SLOTS[$i]="0"
    GRAPH_NODE_SKIP_PREDECESSOR_COUNT[$i]="0"
  done

  GRAPH_SCHEDULE_GRAPH_JSON="$frozen_graph"
  GRAPH_SCHEDULE_RUN_ID="$run_id"
  GRAPH_SCHEDULE_WORKSPACE="$workspace"
  GRAPH_SCHEDULE_EXIT_CODE=0
  GRAPH_SCHEDULE_FAILED_NODE=""
  GRAPH_SCHEDULE_STOP_DISPATCH=0
  GRAPH_SCHEDULE_CANCEL_REQUESTED=0
  GRAPH_SCHEDULE_AWAITING_ACK=0
  GRAPH_SCHEDULE_LEDGER_RUN_DIR="$(graph_state_run_dir "$workspace" "$namespace" "$run_id")"
  GRAPH_SCHEDULE_LEDGER_NAMESPACE="$namespace"

  local max_parallel per_runtime
  max_parallel="$(jq -r '.maxParallel // 2' "$frozen_graph")"
  max_parallel="$(_graph_schedule_positive_int_or_default "$max_parallel" 2)"
  if [[ -n "${RALPH_GRAPH_MAX_PARALLEL:-}" ]]; then
    max_parallel="$(_graph_schedule_positive_int_or_default "$RALPH_GRAPH_MAX_PARALLEL" "$max_parallel")"
  fi
  GRAPH_SCHEDULE_MAX_PARALLEL="$max_parallel"
  GRAPH_SCHEDULE_TOKEN_CAP="$max_parallel"
  if [[ -n "${RALPH_GRAPH_MAX_PARALLEL_TOKEN_STREAMS:-}" ]]; then
    GRAPH_SCHEDULE_TOKEN_CAP="$(_graph_schedule_positive_int_or_default "$RALPH_GRAPH_MAX_PARALLEL_TOKEN_STREAMS" "$max_parallel")"
  fi
  GRAPH_SCHEDULE_USED_TOKEN_SLOTS=0
  GRAPH_SCHEDULE_DELEGATION_ACTIVE="$(jq '[.nodes[] | .stage.delegation? | select((.maxChildren // 0) > 0)] | length' "$frozen_graph" 2>/dev/null || echo 0)"
  per_runtime=1
  if [[ -n "${RALPH_GRAPH_MAX_PARALLEL_PER_RUNTIME:-}" ]]; then
    per_runtime="$(_graph_schedule_positive_int_or_default "$RALPH_GRAPH_MAX_PARALLEL_PER_RUNTIME" 1)"
  fi
  GRAPH_SCHEDULE_MAX_PARALLEL_PER_RUNTIME="$per_runtime"
  graph_schedule_delegation_preflight "$frozen_graph" "$max_parallel" || return 1
  graph_schedule_native_budget_preflight "$frozen_graph" || return 1

  GRAPH_SCHEDULE_FAILURE_POLICY="$(jq -r '.failurePolicy // "drain"' "$frozen_graph" 2>/dev/null || echo drain)"
  if [[ "$GRAPH_SCHEDULE_FAILURE_POLICY" != "drain" && "$GRAPH_SCHEDULE_FAILURE_POLICY" != "cancel" ]]; then
    GRAPH_SCHEDULE_FAILURE_POLICY="drain"
  fi
  GRAPH_SCHEDULE_ORCH_PATH="$(graph_dispatch_materialize_orch "$frozen_graph" "$workspace" \
    "$GRAPH_SCHEDULE_LEDGER_RUN_DIR/orchestration-plans/$(jq -r '.namespace // "graph"' "$frozen_graph").orch.json" \
    "$GRAPH_SCHEDULE_LEDGER_RUN_DIR")" || return 1
  GRAPH_SCHEDULE_NAMESPACE="$(jq -r '.namespace // empty' "$GRAPH_SCHEDULE_ORCH_PATH")"
  if [[ -z "$GRAPH_SCHEDULE_NAMESPACE" ]]; then
    GRAPH_SCHEDULE_NAMESPACE="$(basename "$GRAPH_SCHEDULE_ORCH_PATH" .orch.json)"
  fi
  GRAPH_SCHEDULE_PLAN_KEY="$GRAPH_SCHEDULE_NAMESPACE"
  GRAPH_SCHEDULE_LEDGER_NAMESPACE="$namespace"

  # Structured transition log (append to existing log for this run).
  GRAPH_SCHEDULE_LOG_FILE=""
  local _resume_log_dir _resume_state_root
  _resume_state_root="$(jq -r '.roots.stateRoot // empty' "$GRAPH_SCHEDULE_LEDGER_RUN_DIR/run.json" 2>/dev/null || true)"
  [[ -n "$_resume_state_root" && "$_resume_state_root" != "null" ]] || \
    _resume_state_root="${RALPH_PLAN_WORKSPACE_ROOT:-$workspace/.ralph-workspace}"
  _resume_log_dir="$_resume_state_root/logs/$namespace"
  mkdir -p "$_resume_log_dir" 2>/dev/null || true
  GRAPH_SCHEDULE_LOG_FILE="$_resume_log_dir/graph-schedule-${run_id}.log"
  touch "$GRAPH_SCHEDULE_LOG_FILE" 2>/dev/null || GRAPH_SCHEDULE_LOG_FILE=""
  GRAPH_SCHEDULE_ADMISSION_LOG_FILE="$_resume_log_dir/graph-admission-${run_id}.jsonl"
  touch "$GRAPH_SCHEDULE_ADMISSION_LOG_FILE" 2>/dev/null || GRAPH_SCHEDULE_ADMISSION_LOG_FILE=""
  graph_schedule_recover_delegated_children

  # Reconcile each node. Succeeded/awaiting-ack/skipped stay; others reset.
  local node_id reapable_ready=0
  for ((i = 0; i < ${#GRAPH_NODE_IDS[@]}; i++)); do
    node_id="${GRAPH_NODE_IDS[$i]}"
    _graph_schedule_reconcile_node "$node_id" "$frozen_graph" || true
  done

  # Detect a fully completed run: every node is terminal-successful or
  # awaiting-ack/skipped, and none is pending. This is a clean no-op resume.
  local pending_count=0
  for ((i = 0; i < ${#GRAPH_NODE_STATES[@]}; i++)); do
    if [[ "${GRAPH_NODE_STATES[$i]}" == "pending" ]]; then
      pending_count=$((pending_count + 1))
    fi
  done
  if [[ "$pending_count" -eq 0 ]]; then
    if _graph_schedule_all_succeeded; then
      GRAPH_SCHEDULE_EXIT_CODE=0
      graph_state_set_run_status "$workspace" "$namespace" "$run_id" "succeeded" 2>/dev/null || true
      echo "graph-resume: run $run_id already complete; no-op" >&2
      return 0
    fi
    # awaiting-ack or skipped-only: preserve the prior exit code.
    if [[ "$GRAPH_SCHEDULE_AWAITING_ACK" -eq 1 ]]; then
      GRAPH_SCHEDULE_EXIT_CODE=3
      graph_state_set_run_status "$workspace" "$namespace" "$run_id" "awaiting-ack" 2>/dev/null || true
    else
      GRAPH_SCHEDULE_EXIT_CODE=0
      graph_state_set_run_status "$workspace" "$namespace" "$run_id" "succeeded" 2>/dev/null || true
    fi
    echo "graph-resume: run $run_id has no pending nodes; no-op" >&2
    return "$GRAPH_SCHEDULE_EXIT_CODE"
  fi

  # Continue the ready-set loop. Reuse the same loop body as graph_schedule_run
  # by falling through into the shared scheduling loop below.
  _graph_schedule_resume_loop "$frozen_graph" "$run_id" "$workspace"
}

# _graph_schedule_invalidate_changed_nodes <workspace> <namespace> <run_id>
#   <old_graph> <new_graph>
#
# Compares per-node stage JSON digests and ancestor sets between old and new
# graphs. For every node whose own stage JSON or ancestor set changed, resets
# the ledger entry to pending. Also replaces the frozen graph.json in the run
# directory with the new graph so the scheduler operates on the new contract.
# Prints the changed node ids on stderr (one per line) so the refusal path can
# name them.
_graph_schedule_invalidate_changed_nodes() {
  local workspace="$1" namespace="$2" run_id="$3"
  local old_graph="$4" new_graph="$5"
  local node_id old_digest new_digest old_anc new_anc changed
  local node_ids_old node_ids_new node_id_file
  command -v jq >/dev/null 2>&1 || return 1

  # Build id->ancestor-set maps from both graphs.
  local old_anc_file new_anc_file
  old_anc_file="$(mktemp "${TMPDIR:-/tmp}/ralph-resume-old.XXXXXX")" || return 1
  new_anc_file="$(mktemp "${TMPDIR:-/tmp}/ralph-resume-new.XXXXXX")" || {
    rm -f "$old_anc_file"
    return 1
  }
  graph_state_ancestor_sets "$old_graph" >"$old_anc_file" 2>/dev/null || true
  graph_state_ancestor_sets "$new_graph" >"$new_anc_file" 2>/dev/null || true

  # Iterate over the union of node ids. A node present in only one graph is
  # always invalidated.
  local all_ids_file
  all_ids_file="$(mktemp "${TMPDIR:-/tmp}/ralph-resume-ids.XXXXXX")" || {
    rm -f "$old_anc_file" "$new_anc_file"
    return 1
  }
  {
    graph_state_node_ids_from_graph "$old_graph"
    graph_state_node_ids_from_graph "$new_graph"
  } 2>/dev/null | sort -u >"$all_ids_file"

  while IFS= read -r node_id || [[ -n "$node_id" ]]; do
    [[ -z "$node_id" ]] && continue
    changed=0
    old_digest="$(graph_state_node_digest "$old_graph" "$node_id" 2>/dev/null)" || old_digest=""
    new_digest="$(graph_state_node_digest "$new_graph" "$node_id" 2>/dev/null)" || new_digest=""
    if [[ "$old_digest" != "$new_digest" ]]; then
      changed=1
      echo "graph-resume: node=$node_id own stage changed" >&2
    fi
    old_anc="$(grep -F "$(printf '%s\t' "$node_id")" "$old_anc_file" 2>/dev/null | cut -f2- || true)"
    new_anc="$(grep -F "$(printf '%s\t' "$node_id")" "$new_anc_file" 2>/dev/null | cut -f2- || true)"
    if [[ "$old_anc" != "$new_anc" ]]; then
      changed=1
      echo "graph-resume: node=$node_id ancestor set changed" >&2
    fi
    if [[ "$changed" -eq 1 ]]; then
      echo "graph-resume: invalidating node=$node_id" >&2
      graph_state_reset_node_to_pending "$workspace" "$namespace" "$run_id" "$node_id" 2>/dev/null || true
    fi
  done <"$all_ids_file"

  rm -f "$old_anc_file" "$new_anc_file" "$all_ids_file"

  # Replace the frozen graph.json with the new graph so the scheduler runs
  # against the new contract. Atomic via temp+rename in the run directory.
  local run_dir frozen_path tmp_graph
  run_dir="$(graph_state_run_dir "$workspace" "$namespace" "$run_id")"
  frozen_path="$run_dir/graph.json"
  tmp_graph="$(mktemp "$run_dir/.graph-XXXXXX")" || return 1
  if cp "$new_graph" "$tmp_graph" && mv -f "$tmp_graph" "$frozen_path"; then
    # Update graphSha in run.json to the new digest so a subsequent resume
    # compares against the new baseline.
    local new_sha
    new_sha="$(graph_state_compute_graph_sha "$frozen_path")" || true
    if [[ -n "$new_sha" ]]; then
      local base_json
      base_json="$(jq -c . "$run_dir/run.json" 2>/dev/null)" || base_json="null"
      ralph_atomic_write_json "$run_dir/run.json" \
        '(($base | fromjson) // {}) + {graphSha: $gs}' \
        --arg base "$base_json" --arg gs "$new_sha" 2>/dev/null || true
    fi
    return 0
  fi
  rm -f "$tmp_graph" 2>/dev/null || true
  return 0
}

# _graph_schedule_resume_loop <graph_json_path> <run_id> <workspace>
#
# The ready-set loop body for a resumed run. Identical to the loop in
# graph_schedule_run but assumes the ledger context and node states are
# already reconciled. On completion updates run.json status.
_graph_schedule_resume_loop() {
  local graph_json_path="$1" run_id="$2" workspace="$3"
  local running_count reap_rc spawn_budget ready_id ready_idx
  local ready_runtime ready_subagents ready_native_parallel ready_tmp

  ready_tmp="$(mktemp "${TMPDIR:-/tmp}/ralph-graph-resume-ready.XXXXXX")" || return 1

  while true; do
    graph_schedule_drain_delegated_children
    running_count="$(_graph_schedule_count_running)"

    if [[ "$GRAPH_SCHEDULE_STOP_DISPATCH" -eq 0 ]]; then
      graph_schedule_ready_ids >"$ready_tmp"
      spawn_budget=$(( GRAPH_SCHEDULE_MAX_PARALLEL - $(_graph_schedule_count_active_invocations) ))
      if [[ "$spawn_budget" -lt 0 ]]; then
        spawn_budget=0
      fi
      while IFS= read -r ready_id || [[ -n "$ready_id" ]]; do
        [[ -z "$ready_id" ]] && continue
        [[ "$spawn_budget" -le 0 ]] && break
        if [[ "$(graph_schedule_node_state_by_id "$ready_id")" != "pending" ]]; then
          continue
        fi
        if ! ready_idx="$(graph_schedule_index_map_get "$ready_id")"; then
          continue
        fi
        ready_runtime="${GRAPH_NODE_RUNTIMES[$ready_idx]}"
        ready_subagents="${GRAPH_NODE_SUBAGENTS[$ready_idx]}"
        ready_native_parallel="${GRAPH_NODE_NATIVE_PARALLEL[$ready_idx]:-0}"
        # Checkpoint nodes are handled synchronously without spawning a process.
        if [[ "${GRAPH_NODE_TYPES[$ready_idx]:-}" == "checkpoint" ]]; then
          _graph_schedule_handle_checkpoint_node "$ready_id" || true
          continue
        fi
        # consensus-barrier nodes never have a runtime/agent; they always
        # dispatch synchronously in-process. See graph_schedule_run's inline
        # loop for the full rationale (this loop mirrors it for resume).
        if [[ "${GRAPH_NODE_TYPES[$ready_idx]:-}" == "consensus-barrier" ]]; then
          _graph_schedule_handle_consensus_barrier_node "$ready_id" || true
          continue
        fi
        if [[ "${GRAPH_NODE_TYPES[$ready_idx]:-}" == "integrate" ]]; then
          _graph_schedule_handle_integration_node "$ready_id" || true
          continue
        fi
        # Gate nodes are model-free verification gates; see the main loop's
        # inline comment for the full rationale (this loop mirrors it for resume).
        if [[ "${GRAPH_NODE_TYPES[$ready_idx]:-}" == "gate" ]]; then
          _graph_schedule_handle_gate_node "$ready_id" || true
          continue
        fi
        # A join node with no declared runtime is a policy pass-through; one
        # that declares a runtime falls through to ordinary agent dispatch.
        if [[ "${GRAPH_NODE_TYPES[$ready_idx]:-}" == "join" && -z "$ready_runtime" ]]; then
          _graph_schedule_handle_join_node "$ready_id" || true
          continue
        fi
        if ! _graph_schedule_runtime_can_admit "$ready_runtime" "$ready_subagents" "" "$ready_native_parallel"; then
          _graph_schedule_log_admission "denied" "graph-node" "$ready_id" "$ready_runtime" "$ready_subagents" \
            "$(_graph_schedule_slots_for_node "$ready_runtime" "$ready_subagents" "$ready_native_parallel")" "$(_graph_schedule_slots_for_node "$ready_runtime" "$ready_subagents" "$ready_native_parallel")" "runtime-or-token-cap"
          local denied_summary
          denied_summary="$(_graph_schedule_admission_summary_json "$ready_id" "$ready_runtime" "$ready_subagents" "runtime-or-token-cap")"
          _graph_schedule_ledger_record "$ready_id" "ready" "" "" "" "" "" "" "$ready_runtime" "$ready_subagents" "admission-denied" "$denied_summary"
          continue
        fi
        _graph_schedule_spawn_node "$ready_id" || {
          rm -f "$ready_tmp"
          GRAPH_SCHEDULE_EXIT_CODE=1
          return 1
        }
        spawn_budget=$((spawn_budget - 1))
        running_count=$((running_count + 1))
      done <"$ready_tmp"
    fi

    running_count="$(_graph_schedule_count_running)"
    if [[ "$running_count" -eq 0 ]]; then
      # Synchronous handlers (checkpoint/consensus-barrier/join/gate) can
      # release new successors without ever spawning a tracked subprocess, so
      # running_count alone cannot decide the run is done -- re-check the
      # ready set before concluding no more progress is possible.
      if [[ "$GRAPH_SCHEDULE_STOP_DISPATCH" -eq 0 ]]; then
        graph_schedule_ready_ids >"$ready_tmp"
        if [[ -s "$ready_tmp" ]]; then
          continue
        fi
      fi
      break
    fi

    reap_rc=0
    graph_schedule_reap_one >/dev/null || reap_rc=$?
    if [[ "$reap_rc" -eq 1 ]]; then
      echo "Error: graph_schedule_reap_one failed while children were tracked" >&2
      rm -f "$ready_tmp"
      GRAPH_SCHEDULE_EXIT_CODE=1
      return 1
    fi
    _graph_schedule_handle_reaped_node "$reap_rc" || true
  done

  rm -f "$ready_tmp"

  if [[ "$(graph_schedule_child_count)" -ne 0 ]]; then
    echo "Error: graph-schedule: orphan tracked children remain: $(graph_schedule_child_count)" >&2
    GRAPH_SCHEDULE_EXIT_CODE=1
    return 1
  fi

  if _graph_schedule_all_succeeded; then
    GRAPH_SCHEDULE_EXIT_CODE=0
    graph_state_set_run_status "$workspace" "$GRAPH_SCHEDULE_LEDGER_NAMESPACE" "$run_id" "succeeded" 2>/dev/null || true
    return 0
  fi

  if [[ "$GRAPH_SCHEDULE_EXIT_CODE" -eq 0 ]]; then
    if [[ "$GRAPH_SCHEDULE_AWAITING_ACK" -eq 1 ]]; then
      GRAPH_SCHEDULE_EXIT_CODE=3
    else
      GRAPH_SCHEDULE_EXIT_CODE=1
    fi
  fi
  local run_status="failed"
  if [[ "$GRAPH_SCHEDULE_AWAITING_ACK" -eq 1 ]]; then
    run_status="awaiting-ack"
  fi
  graph_state_set_run_status "$workspace" "$GRAPH_SCHEDULE_LEDGER_NAMESPACE" "$run_id" "$run_status" 2>/dev/null || true
  if [[ -n "$GRAPH_SCHEDULE_FAILED_NODE" ]]; then
    echo "graph-schedule: run failed node=$GRAPH_SCHEDULE_FAILED_NODE exit=$GRAPH_SCHEDULE_EXIT_CODE policy=$GRAPH_SCHEDULE_FAILURE_POLICY" >&2
  elif [[ "$GRAPH_SCHEDULE_AWAITING_ACK" -eq 1 ]]; then
    echo "graph-schedule: run awaiting-ack exit=$GRAPH_SCHEDULE_EXIT_CODE" >&2
  else
    echo "graph-schedule: run incomplete; not all nodes succeeded exit=$GRAPH_SCHEDULE_EXIT_CODE" >&2
  fi
  return "$GRAPH_SCHEDULE_EXIT_CODE"
}
