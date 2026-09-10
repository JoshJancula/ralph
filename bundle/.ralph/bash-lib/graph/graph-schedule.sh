#!/usr/bin/env bash
# Out-of-process graph scheduler shell.
#
# Sources graph-dispatch.sh and maintains a bash 3.2-safe in-memory index of
# .graph.json (parallel indexed arrays + id->index map). Every node still runs
# as a fresh orchestrator.sh --single-stage process. The child reaper and the
# Kahn ready-set scheduling loop live in this file as centralized helpers.
# Global and per-runtime concurrency caps (parent-process admission only) and
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
if ! declare -F graph_ui_node >/dev/null 2>&1; then
  # shellcheck source=graph-ui.sh
  source "$GRAPH_SCHEDULE_SCRIPT_DIR/graph-ui.sh"
fi
if ! declare -F ralph_model_store_default >/dev/null 2>&1; then
  # shellcheck source=../select-model/model-store.sh
  source "$GRAPH_SCHEDULE_SCRIPT_DIR/../select-model/model-store.sh"
fi
if ! declare -F ralph_resolve_staged_plan_model >/dev/null 2>&1; then
  # shellcheck source=../select-model/select-model-common.sh
  source "$GRAPH_SCHEDULE_SCRIPT_DIR/../select-model/select-model-common.sh"
fi
if ! declare -F graph_state_write_node >/dev/null 2>&1; then
  # shellcheck source=graph-state.sh
  source "$GRAPH_SCHEDULE_SCRIPT_DIR/graph-state.sh"
fi
if ! declare -F graph_logs_resolve >/dev/null 2>&1; then
  # shellcheck source=graph-logs.sh
  source "$GRAPH_SCHEDULE_SCRIPT_DIR/graph-logs.sh"
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
if ! declare -F ralph_evaluator_parse_status >/dev/null 2>&1; then
  # shellcheck source=../review-status.sh
  source "$GRAPH_SCHEDULE_SCRIPT_DIR/../review-status.sh"
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
if ! declare -F graph_delegation_completion_verify_success >/dev/null 2>&1; then
  # shellcheck source=graph-delegation-completion.sh
  source "$GRAPH_SCHEDULE_SCRIPT_DIR/graph-delegation-completion.sh"
fi
if ! declare -F graph_runtime_same_runtime_parallel_safe >/dev/null 2>&1; then
  # shellcheck source=graph-runtime-capabilities.sh
  source "$GRAPH_SCHEDULE_SCRIPT_DIR/graph-runtime-capabilities.sh"
fi
if ! declare -F plan_pipeline_graph_json >/dev/null 2>&1; then
  # shellcheck source=../plan-todo.sh
  source "$GRAPH_SCHEDULE_SCRIPT_DIR/../plan-todo.sh"
fi
if ! declare -F graph_compile_plan >/dev/null 2>&1; then
  # shellcheck source=graph-compile.sh
  source "$GRAPH_SCHEDULE_SCRIPT_DIR/graph-compile.sh"
fi
# consensus-barrier nodes are dispatched synchronously in-process (see
# _graph_schedule_handle_consensus_barrier_node) rather than as an
# orchestrator subprocess; graph_consensus_run_join lives here.
if ! declare -F graph_consensus_run_join >/dev/null 2>&1; then
  # shellcheck source=graph-consensus.sh
  source "$GRAPH_SCHEDULE_SCRIPT_DIR/graph-consensus.sh"
fi
if ! declare -F graph_events_append >/dev/null 2>&1; then
  # shellcheck source=graph-events.sh
  source "$GRAPH_SCHEDULE_SCRIPT_DIR/graph-events.sh"
fi
if ! declare -F graph_failure_classify >/dev/null 2>&1; then
  # shellcheck source=graph-failure-classify.sh
  source "$GRAPH_SCHEDULE_SCRIPT_DIR/graph-failure-classify.sh"
fi
if ! declare -F graph_schema_parse_resilience >/dev/null 2>&1; then
  # shellcheck source=validate-graph-schema.sh
  source "$GRAPH_SCHEDULE_SCRIPT_DIR/validate-graph-schema.sh"
fi
if ! declare -F graph_operator_request_write >/dev/null 2>&1; then
  # shellcheck source=graph-operator-records.sh
  source "$GRAPH_SCHEDULE_SCRIPT_DIR/graph-operator-records.sh"
fi
if ! declare -F ralph_atomic_write_json >/dev/null 2>&1; then
  # shellcheck source=../atomic-json.sh
  source "$GRAPH_SCHEDULE_SCRIPT_DIR/../atomic-json.sh"
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
GRAPH_NODE_NATIVE_SUBAGENTS=()
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
# One in-memory retry grant per node for agent-correctable in-place requeue.
# Durable refusal also uses the ledger's failed-attempt count so resume cannot
# grant a second ordinary retry after the first has been consumed.
GRAPH_NODE_CORRECTIVE_RETRIES_USED=()
# Ordinary retry counters for configured transient-runtime retries. Corrective
# ordinary retries share GRAPH_NODE_CORRECTIVE_RETRIES_USED when resilience
# limits are in force.
GRAPH_NODE_TRANSIENT_RETRIES_USED=()
# Committed active execution seconds per node (excludes operator/checkpoint
# waits and retry backoff). GRAPH_NODE_ACTIVE_STARTED_AT is the open clock
# ISO stamp while the node is running; empty when the clock is paused.
GRAPH_NODE_ACTIVE_SECONDS=()
GRAPH_NODE_ACTIVE_STARTED_AT=()
# Per-node usage aggregate JSON (reliable totals, reliability, counted
# attempt ids). Empty means unavailable, not zero.
GRAPH_NODE_USAGE_JSON=()
# One compact alternative turn after an operator deny. Durable refusal also
# uses the alternative record so resume cannot grant a second deny turn.
GRAPH_NODE_OPERATOR_DENY_TURNS_USED=()
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
# Set when a child exits from an interrupt signal before it can persist its
# StageOutcomeReport. The run remains resumable; this must not be collapsed
# into the permanent missing-report failure path.
GRAPH_SCHEDULE_INTERRUPTED=0
# failurePolicy from .graph.json: drain (default) or cancel.
GRAPH_SCHEDULE_FAILURE_POLICY="drain"
# Set when cancel has signalled in-flight children (idempotent).
GRAPH_SCHEDULE_CANCEL_REQUESTED=0
# Set when any node finished with exit code 3 (human ack pending).
GRAPH_SCHEDULE_AWAITING_ACK=0
# Set when any node is paused for an operator-permission request.
GRAPH_SCHEDULE_AWAITING_OPERATOR=0
# Path of the most recently persisted operator request for this process.
GRAPH_SCHEDULE_OPERATOR_REQUEST_PATH=""
# Path of the most recently consumed operator decision for this process.
GRAPH_SCHEDULE_OPERATOR_DECISION_PATH=""
# Compact adapter-continuation or deny-alternative record for the next spawn.
GRAPH_SCHEDULE_SPAWN_OPERATOR_RECORD=""
GRAPH_SCHEDULE_SPAWN_OPERATOR_PATH_KIND=""
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
# Run directory that owns logs/supervisor.log, logs/admission.jsonl, and
# logs/nodes/<safe-node-id>/<attempt-id>/. Set for every schedule run, even
# ledger-less tests, so two runs never share namespace-only log files.
GRAPH_SCHEDULE_LOG_RUN_DIR=""
# Set for one spawn when the next supported session turn should receive only
# the compact correction record. Empty for ordinary first attempts.
GRAPH_SCHEDULE_SPAWN_CORRECTION_RECORD=""
# Contained retry-context path for a retry spawn. Empty for first attempts.
GRAPH_SCHEDULE_SPAWN_RETRY_CONTEXT=""
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

# Verification profiles are a frozen part of the compiled graph, but this was
# re-read with a fresh jq fork on every scheduler drain tick -- 26 identical
# reads in a five-node test, most of them on ticks that admitted no child at
# all. Memoize per graph path (keyed by path so a process that schedules more
# than one graph stays correct).
_graph_schedule_verification_profiles() {
  local graph_json="${GRAPH_SCHEDULE_GRAPH_JSON:-}"
  local cache_name
  [[ -n "$graph_json" ]] || { printf '%s\n' '[]'; return 0; }
  cache_name="_GRAPH_SCHEDULE_VPROFILES_${graph_json}"
  cache_name="${cache_name//[^A-Za-z0-9_]/_}"
  if [[ -z "${!cache_name+set}" ]]; then
    printf -v "$cache_name" '%s' \
      "$(jq -c '.verificationProfiles // []' "$graph_json" 2>/dev/null || echo '[]')"
  fi
  printf '%s\n' "${!cache_name}"
}

# Start queued broker work in its own session while a parent graph node remains
# live.  The status ledger, not this shell PID, is the source of truth.
graph_schedule_drain_delegated_children() {
  local workspace="$GRAPH_SCHEDULE_WORKSPACE" ns="$GRAPH_SCHEDULE_NAMESPACE" run_id="$GRAPH_SCHEDULE_RUN_ID" entry parent did pid cap profiles runtime slots token_slots
  local project_root state_root parent_workspace run_file node_file delegation_runner parent_runtime runtime_active
  [[ -n "$workspace" && -n "$ns" && -n "$run_id" ]] || return 0
  _graph_schedule_reap_delegated_children
  cap=$(( GRAPH_SCHEDULE_MAX_PARALLEL - $(_graph_schedule_count_active_invocations) )); [[ "$cap" -gt 0 ]] || return 0
  profiles="$(_graph_schedule_verification_profiles)"
  while [[ "$cap" -gt 0 ]]; do
    GRAPH_DELEGATION_ADMITTED_ENTRY=""
    graph_schedule_admit_delegated_child "$workspace" "$ns" "$run_id" "$cap" "$GRAPH_SCHEDULE_MAX_PARALLEL_PER_RUNTIME" || break
    entry="$GRAPH_DELEGATION_ADMITTED_ENTRY"
    parent="$(jq -r .parentNodeId <<<"$entry")"; did="$(jq -r '.delegatedRunId // .delegationId // empty' <<<"$entry")"
    runtime="$(jq -r .runtime <<<"$entry")"
    parent_runtime="$(graph_schedule_node_runtime_by_id "$parent" 2>/dev/null || true)"
    slots="${GRAPH_DELEGATION_ADMITTED_RUNTIME_SLOTS:-1}"
    token_slots="${GRAPH_DELEGATION_ADMITTED_TOKEN_SLOTS:-1}"
    runtime_active=""
    if _graph_schedule_runtime_map_index "$runtime"; then
      runtime_active="${GRAPH_RUNTIME_USED_SLOTS[$GRAPH_RUNTIME_LOOKUP_IDX]:-1}"
      runtime_active=$((runtime_active - slots))
      [[ "$runtime_active" -ge 0 ]] || runtime_active=0
    fi
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
      export RALPH_GRAPH_DELEGATION_PARENT_RUNTIME="$parent_runtime"
      export RALPH_GRAPH_MAX_PARALLEL_PER_RUNTIME="$GRAPH_SCHEDULE_MAX_PARALLEL_PER_RUNTIME"
      [[ -z "$runtime_active" ]] || export RALPH_GRAPH_RUNTIME_ACTIVE_SLOTS="$runtime_active"
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
  local entry parent did status runtime pid status_json
  while IFS= read -r entry; do
    parent="$(jq -r .parentNodeId <<<"$entry")"; did="$(jq -r '.delegatedRunId // .delegationId // empty' <<<"$entry")"
    status_json="$(graph_delegation_ledger_read_status "$GRAPH_SCHEDULE_WORKSPACE" "$did" 2>/dev/null)" || { graph_delegation_runner_log "$GRAPH_SCHEDULE_WORKSPACE" "ignore delegation=$did unreadable-ledger"; continue; }
    status="$(jq -r '.status // empty' <<<"$status_json")"
    case "$status" in
      succeeded)
        if graph_delegation_completion_verify_success "$GRAPH_SCHEDULE_WORKSPACE" "$did" "$status_json"; then
          graph_delegation_runner_log "$GRAPH_SCHEDULE_WORKSPACE" "adopt delegation=$did status=succeeded verified=true"
        else
          graph_delegation_runner_log "$GRAPH_SCHEDULE_WORKSPACE" "reject adoption delegation=$did status=succeeded verified=false"
        fi
        ;;
      failed|cancelled) graph_delegation_runner_log "$GRAPH_SCHEDULE_WORKSPACE" "retain delegation=$did status=$status";;
      running)
        if graph_delegation_child_process_alive "$GRAPH_SCHEDULE_WORKSPACE" "${GRAPH_SCHEDULE_LEDGER_NAMESPACE:-$GRAPH_SCHEDULE_NAMESPACE}" "$GRAPH_SCHEDULE_RUN_ID" "$parent" "$did"; then
          runtime="$(jq -r '.runtime' <<<"$entry")"
          pid="$(jq -r '.runner.pid // empty' <<<"$status_json")"
          if [[ "$pid" =~ ^[0-9]+$ ]] && _graph_schedule_runtime_can_admit "$runtime" off 1; then
            _graph_schedule_runtime_reserve_slots "$runtime" 1 1
            GRAPH_DELEGATION_CHILD_PIDS+=("$pid"); GRAPH_DELEGATION_CHILD_PARENTS+=("$parent"); GRAPH_DELEGATION_CHILD_IDS+=("$did")
            GRAPH_DELEGATION_CHILD_RUNTIMES+=("$runtime"); GRAPH_DELEGATION_CHILD_HELD_SLOTS+=("1"); GRAPH_DELEGATION_CHILD_TOKEN_SLOTS+=("1")
            _graph_schedule_log_admission "admitted" "broker-child" "$did" "$runtime" "off" "1" "1" "recovered-live-child"
          else
            graph_delegation_runner_log "$GRAPH_SCHEDULE_WORKSPACE" "defer adoption delegation=$did runtime=$runtime capacity unavailable"
          fi
        else
          graph_delegation_queue_requeue_crashed "$GRAPH_SCHEDULE_WORKSPACE" "$did" 'scheduler recovery: dead child without outcome' || true
          graph_delegation_runner_log "$GRAPH_SCHEDULE_WORKSPACE" "reset delegation=$did dead-process"
        fi
        ;;
    esac
  done < <(graph_delegation_queue_entries "$GRAPH_SCHEDULE_WORKSPACE" "${GRAPH_SCHEDULE_LEDGER_NAMESPACE:-$GRAPH_SCHEDULE_NAMESPACE}" "$GRAPH_SCHEDULE_RUN_ID")
}

# _graph_schedule_log_transition <message>
# Append one structured log line to the run-owned supervisor log using the
# same format as ralph_orchestrator_log. Re-resolves the path on every write
# so a swapped symlink cannot redirect a follow-up append. Falls back to
# GRAPH_SCHEDULE_LOG_FILE when a test injects a path without a run-dir.
_graph_schedule_log_transition() {
  local ts line
  ts="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)"
  line="$(printf '[%s] %s' "$ts" "$*")"
  if [[ -n "${GRAPH_SCHEDULE_LOG_RUN_DIR:-}" ]]; then
    graph_logs_append "$GRAPH_SCHEDULE_LOG_RUN_DIR" "$(graph_logs_supervisor_rel)" "$line" 2>/dev/null || true
    return 0
  fi
  if [[ -z "${GRAPH_SCHEDULE_LOG_FILE:-}" ]]; then
    return 0
  fi
  printf '%s\n' "$line" >> "$GRAPH_SCHEDULE_LOG_FILE" 2>/dev/null || true
}

# _graph_schedule_bind_run_logs <run-id> [mode]
# mode is "create" (truncate admission) or "resume" (append). Resolves
# supervisor.log and admission.jsonl under the run-dir. When no ledger
# run-dir is set, still owns logs at graph_state_run_dir so two runs
# never share namespace-only files.
_graph_schedule_bind_run_logs() {
  local run_id="$1" mode="${2:-create}"
  local run_dir rel
  GRAPH_SCHEDULE_LOG_FILE=""
  GRAPH_SCHEDULE_ADMISSION_LOG_FILE=""
  if [[ -n "${GRAPH_SCHEDULE_LEDGER_RUN_DIR:-}" ]]; then
    run_dir="$GRAPH_SCHEDULE_LEDGER_RUN_DIR"
  else
    run_dir="$(graph_state_run_dir "$GRAPH_SCHEDULE_WORKSPACE" "${GRAPH_SCHEDULE_LEDGER_NAMESPACE:-$GRAPH_SCHEDULE_NAMESPACE}" "$run_id")" || return 1
  fi
  mkdir -p "$run_dir" || return 1
  GRAPH_SCHEDULE_LOG_RUN_DIR="$run_dir"
  rel="$(graph_logs_supervisor_rel)"
  GRAPH_SCHEDULE_LOG_FILE="$(graph_logs_prepare_write "$run_dir" "$rel")" || GRAPH_SCHEDULE_LOG_FILE=""
  if [[ -n "$GRAPH_SCHEDULE_LOG_FILE" ]]; then
    if [[ "$mode" == "create" && ! -s "$GRAPH_SCHEDULE_LOG_FILE" ]]; then
      : >"$GRAPH_SCHEDULE_LOG_FILE" 2>/dev/null || true
    else
      touch "$GRAPH_SCHEDULE_LOG_FILE" 2>/dev/null || GRAPH_SCHEDULE_LOG_FILE=""
    fi
  fi
  rel="$(graph_logs_admission_rel)"
  GRAPH_SCHEDULE_ADMISSION_LOG_FILE="$(graph_logs_prepare_write "$run_dir" "$rel")" || GRAPH_SCHEDULE_ADMISSION_LOG_FILE=""
  if [[ -n "$GRAPH_SCHEDULE_ADMISSION_LOG_FILE" ]]; then
    if [[ "$mode" == "create" ]]; then
      : >"$GRAPH_SCHEDULE_ADMISSION_LOG_FILE" 2>/dev/null || GRAPH_SCHEDULE_ADMISSION_LOG_FILE=""
    else
      touch "$GRAPH_SCHEDULE_ADMISSION_LOG_FILE" 2>/dev/null || GRAPH_SCHEDULE_ADMISSION_LOG_FILE=""
    fi
  fi
}

# _graph_schedule_events_log_file
# Returns the per-run ordered, append-only event journal path, or empty when no
# ledger run is active. The journal lives at <run-dir>/events.jsonl and is the
# single source of truth for graph observability events.
_graph_schedule_events_log_file() {
  if [[ -z "${GRAPH_SCHEDULE_LEDGER_RUN_DIR:-}" ]]; then
    return 0
  fi
  printf '%s/events.jsonl\n' "$GRAPH_SCHEDULE_LEDGER_RUN_DIR"
}

# _graph_schedule_log_observability <event> <node-id> <attempt-id> <runtime>
#   <nativeSubagents> <details-json>
# Append a schemaVersion 1 event to the run event journal.  No-op when there is
# no ledger run.  All writes go through graph_events_append so concurrent node
# children are serialized and sequence numbers stay monotonic.  Full prompts and
# full tool output are forbidden in details; callers must reference ledger-
# relative log/artifact paths instead.
_graph_schedule_log_observability() {
  local event="$1" node_id="$2" attempt_id="$3" runtime="$4" native_subagents="$5" details_json="${6:-}"
  if [[ -z "${GRAPH_SCHEDULE_LEDGER_RUN_DIR:-}" || -z "${GRAPH_SCHEDULE_RUN_ID:-}" ]]; then
    return 0
  fi
  if [[ -z "$details_json" ]]; then
    details_json='{}'
  fi
  # Normalize scheduler event names for the event journal.
  local mapped="$event"
  case "$event" in
    node-spawn) mapped="node-spawn" ;;
    node-succeeded) mapped="node-terminal" ;;
    integration-start|integration-complete|integration-failed) ;;
    gate-passed|gate-changes-required|gate-error) ;;
    *)
      # Unknown names pass through the schema validator unchanged.
      ;;
  esac
  graph_events_append "$GRAPH_SCHEDULE_LEDGER_RUN_DIR" "$GRAPH_SCHEDULE_RUN_ID" "$mapped" "$node_id" "$attempt_id" "$details_json" >/dev/null 2>&1 || true
}

# A parent that waits for a brokered child occupies one graph slot. It
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

# Native subagents are opaque and parent-owned; Ralph no longer reserves
# child-count slots. Kept as a no-op so call sites stay stable.
graph_schedule_native_budget_preflight() {
  local graph="$1"
  [[ -n "$graph" ]] || return 0
  return 0
}

# Emit one FS-separated row per node: id, runtime, agent, stage model override.
# Same field-separator convention as graph_schedule_native_budget_preflight.
_graph_schedule_preflight_rows() {
  jq -jr '.nodes[] | ([.id, (.stage.runtime // ""), (.stage.agent // ""), (.stage.model // "")] | map(tostring) | join("")) + "\n"' "$1"
}

# graph_schedule_agent_model_preflight <graph-json> <workspace>
#
# Resolve every node's runtime/agent/model before the first spawn and print the
# resolution as a table. A graph fans out to several runtimes at once, so without
# this the operator cannot see which model a node will use until after it has
# already failed - and a stale model id fails every node that shares it.
#
# Precedence matches staged run-plan resolution: stage/voter model: > saved
# (claude/codex) > runtime-native default. Profile/agent-config models are not
# consulted. This is reporting, not validation, and never fails the run.

graph_schedule_agent_model_preflight() {
  local graph="$1" workspace="$2"
  local node runtime agent stage_model model problems=0
  local rows_tmp width=4
  local prev_ni="${NON_INTERACTIVE_FLAG:-}"

  graph_ui_init
  rows_tmp="$(mktemp "${TMPDIR:-/tmp}/ralph-graph-preflight.XXXXXX")" || return 1
  _graph_schedule_preflight_rows "$graph" >"$rows_tmp" || { rm -f "$rows_tmp"; return 1; }

  # Size the node column to the widest id so the table stays readable; graph
  # node ids are descriptive and routinely exceed any fixed guess.
  while IFS=$'\034' read -r node runtime agent stage_model || [[ -n "$node" ]]; do
    [[ -n "$node" ]] || continue
    [[ "${#node}" -gt "$width" ]] && width="${#node}"
  done <"$rows_tmp"

  graph_ui_section "Node agents"
  printf '  %b%-*s %-9s %-14s %s%b\n' "$GRAPH_UI_DIM" "$width" "NODE" "RUNTIME" "AGENT" "MODEL" "$GRAPH_UI_RST" >&2

  # Non-interactive so preflight never opens a model picker.
  export NON_INTERACTIVE_FLAG=1
  while IFS=$'\034' read -r node runtime agent stage_model || [[ -n "$node" ]]; do
    [[ -n "$node" ]] || continue
    if [[ -z "$runtime" ]]; then
      # Gate, integration, and checkpoint nodes are executed by the scheduler
      # itself. Naming that is clearer than leaving the columns blank.
      printf '  %-*s %b%-9s%b %-14s %s\n' "$width" "$node" "$GRAPH_UI_DIM" "scheduler" "$GRAPH_UI_RST" "-" "no model invoked" >&2
      continue
    fi
    model="$(ralph_resolve_staged_plan_model "$runtime" "$stage_model" 2>/dev/null)" || model=""
    # An empty model means "let the runtime CLI pick its default" -- but only
    # where the runtime actually has one it can use unattended. Graph nodes
    # always run run-plan.sh --non-interactive, and that path refuses to start
    # when it cannot resolve a model, so for those runtimes an empty model is
    # not a default: it is a node that is going to fail after dispatch. Say so
    # here, where the operator is still looking, instead of letting them wait
    # for the stage to die. Mirrors run-plan-agent.sh's
    # ralph_run_plan_non_interactive_model_preflight_ok, reusing the same
    # resolvers from select-model-common.sh rather than restating its rules.
    [[ -n "$model" ]] || model="(runtime default)"
    printf '  %-*s %b%-9s%b %-14s %s\n' "$width" "$node" "$GRAPH_UI_C" "$runtime" "$GRAPH_UI_RST" "${agent:-(none)}" "$model" >&2
  done <"$rows_tmp"
  rm -f "$rows_tmp"
  if [[ -n "$prev_ni" ]]; then
    export NON_INTERACTIVE_FLAG="$prev_ni"
  else
    unset NON_INTERACTIVE_FLAG
  fi

  return 0
}

# Public scheduler admission seam. It is intentionally separate from runtime
# execution so the MCP server cannot accidentally become an executor.
graph_schedule_admit_delegated_child() {
  local workspace="$1" ns="$2" run_id="$3" child_cap="$4" runtime_cap="$5"
  local entry parent did runtime slots token_slots
  entry="$(graph_delegation_queue_admit_one "$workspace" "$ns" "$run_id" "$child_cap" "$runtime_cap")" || return $?
  parent="$(jq -r .parentNodeId <<<"$entry")"
  did="$(jq -r '.delegatedRunId // .delegationId // empty' <<<"$entry")"
  runtime="$(jq -r .runtime <<<"$entry")"
  slots=1
  token_slots=1
  if ! _graph_schedule_runtime_can_admit "$runtime" "off" "$token_slots"; then
    graph_delegation_queue_requeue_crashed "$workspace" "$did" 'runtime/token admission deferred' || true
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
  local entry parent did parent_runtime
  entry="$(graph_delegation_queue_admit_one "$workspace" "$ns" "$run_id" "$child_cap" "$runtime_cap")" || return $?
  parent="$(jq -r '.parentNodeId' <<<"$entry")"; did="$(jq -r '.delegatedRunId // .delegationId // empty' <<<"$entry")"
  parent_runtime="$(graph_schedule_node_runtime_by_id "$parent" 2>/dev/null || true)"
  RALPH_GRAPH_DELEGATION_PARENT_RUNTIME="$parent_runtime" \
    RALPH_GRAPH_MAX_PARALLEL="$child_cap" RALPH_GRAPH_MAX_PARALLEL_PER_RUNTIME="$runtime_cap" \
    RALPH_GRAPH_ACTIVE_SLOTS=1 RALPH_GRAPH_RUNTIME_ACTIVE_SLOTS=1 \
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

graph_schedule_node_native_subagents_at() {
  local idx="$1"
  if [[ -z "$idx" || "$idx" -lt 0 || "$idx" -ge ${#GRAPH_NODE_NATIVE_SUBAGENTS[@]} ]]; then
    echo "Error: graph node index out of range: ${idx:-}" >&2
    return 1
  fi
  printf '%s\n' "${GRAPH_NODE_NATIVE_SUBAGENTS[$idx]}"
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

graph_schedule_node_native_subagents_by_id() {
  local node_id="$1" idx
  if ! idx="$(graph_schedule_index_map_get "$node_id")"; then
    echo "Error: unknown graph node id: $node_id" >&2
    return 1
  fi
  graph_schedule_node_native_subagents_at "$idx"
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

# _graph_schedule_agent_conditional_outcome <node_id> <graph_json> <state_root> <namespace>
# Resolves an agent node's review verdict via its stage-declared loop-check
# artifact and prints one of: passed | changes-required | error.
#
# - No .stage.loopCheck.path on the node -> "passed" (preserves default behavior
#   for nodes that do not declare a loop check). Roles never invent loopCheck,
#   evaluator verdicts, or rework evidence paths.
# - loopCheck.path present -> expand {{ARTIFACT_NS}}/{{STAGE_ID}} the same way
#   _graph_dispatch_render_inline_stage_plan does, resolve against state_root,
#   then validate the artifact via ralph_evaluator_parse_status against the
#   evaluator verdict schema. approved -> passed, changes-required -> changes-required.
# - Missing/unreadable/empty/invalid artifact -> "error" (never falls back to passed).
_graph_schedule_agent_conditional_outcome() {
  local node_id="$1" graph_json="$2" state_root="$3" namespace="$4"
  local loop_check_path
  loop_check_path="$(printf '%s' "$graph_json" | jq -r --arg id "$node_id" \
    '.nodes[] | select(.id == $id) | .stage.loopCheck.path // empty' 2>/dev/null)" || loop_check_path=""

  if [[ -z "$loop_check_path" ]]; then
    echo "passed"
    return 0
  fi

  local stage_id_sub="${node_id//:/_}"
  local resolved_path="$loop_check_path"
  resolved_path="${resolved_path//\{\{ARTIFACT_NS\}\}/$namespace}"
  resolved_path="${resolved_path//\{\{STAGE_ID\}\}/$stage_id_sub}"
  if [[ "$resolved_path" == .ralph-workspace/* && -n "$state_root" ]]; then
    resolved_path="$state_root/${resolved_path#.ralph-workspace/}"
  fi

  if ! declare -F ralph_evaluator_parse_status >/dev/null 2>&1; then
    # shellcheck source=../review-status.sh
    source "$GRAPH_SCHEDULE_SCRIPT_DIR/../review-status.sh"
  fi

  local schema_path="$GRAPH_SCHEDULE_SCRIPT_DIR/../../schemas/evaluator-verdict.schema.json"
  local parsed_status
  if ! parsed_status="$(ralph_evaluator_parse_status "$resolved_path" "$schema_path" 2>/dev/null)"; then
    echo "error"
    return 1
  fi

  case "$parsed_status" in
    approved)
      echo "passed"
      return 0
      ;;
    changes-required)
      # Stall detection: a blocking finding that has survived repeated rework
      # rounds will not be fixed by spending the remaining iterations on the
      # same loop. Stop with a precise reason instead of exhausting silently.
      local stalled=""
      if declare -F ralph_evaluator_stalled_findings >/dev/null 2>&1; then
        stalled="$(ralph_evaluator_stalled_findings "$resolved_path" 2>/dev/null)" || stalled=""
      fi
      if [[ -n "$stalled" ]]; then
        echo "graph-schedule: node=$node_id rework stalled; blocking findings unresolved across rounds:" >&2
        printf '%s\n' "$stalled" | while IFS=$'\t' read -r fid rounds; do
          [[ -n "$fid" ]] && echo "graph-schedule:   finding=$fid roundsOpen=$rounds" >&2
        done
        echo "changes-required"
        return 3
      fi
      echo "changes-required"
      return 0
      ;;
    *)
      echo "error"
      return 1
      ;;
  esac
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
  GRAPH_RUNTIME_LOOKUP_IDX=""
  GRAPH_SCHEDULE_USED_TOKEN_SLOTS=0
}

_graph_schedule_reset_index() {
  GRAPH_NODE_IDS=()
  GRAPH_NODE_TYPES=()
  GRAPH_NODE_RUNTIMES=()
  GRAPH_NODE_NATIVE_SUBAGENTS=()
  GRAPH_NODE_INDEGREES=()
  GRAPH_NODE_SUCCESSORS=()
  GRAPH_NODE_COND_SUCCESSORS=()
  GRAPH_NODE_STATES=()
  GRAPH_NODE_REMAINING_INDEGREE=()
  GRAPH_NODE_ATTEMPT_NUMBERS=()
  GRAPH_NODE_CORRECTIVE_RETRIES_USED=()
  GRAPH_NODE_TRANSIENT_RETRIES_USED=()
  GRAPH_NODE_ACTIVE_SECONDS=()
  GRAPH_NODE_ACTIVE_STARTED_AT=()
  GRAPH_NODE_USAGE_JSON=()
  GRAPH_NODE_OPERATOR_DENY_TURNS_USED=()
  GRAPH_NODE_HELD_SLOTS=()
  GRAPH_NODE_HELD_TOKEN_SLOTS=()
  GRAPH_NODE_SKIP_PREDECESSOR_COUNT=()
  GRAPH_NODE_INDEX_KEYS=()
  GRAPH_NODE_INDEX_VALS=()
  GRAPH_SCHEDULE_SPAWN_CORRECTION_RECORD=""
  GRAPH_SCHEDULE_SPAWN_RETRY_CONTEXT=""
  GRAPH_SCHEDULE_SPAWN_OPERATOR_RECORD=""
  GRAPH_SCHEDULE_SPAWN_OPERATOR_PATH_KIND=""
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
  GRAPH_SCHEDULE_INTERRUPTED=0
  GRAPH_SCHEDULE_FAILURE_POLICY="drain"
  GRAPH_SCHEDULE_CANCEL_REQUESTED=0
  GRAPH_SCHEDULE_AWAITING_ACK=0
  GRAPH_SCHEDULE_AWAITING_OPERATOR=0
  GRAPH_SCHEDULE_OPERATOR_REQUEST_PATH=""
  GRAPH_SCHEDULE_OPERATOR_DECISION_PATH=""
  GRAPH_SCHEDULE_LEDGER_RUN_DIR=""
  GRAPH_SCHEDULE_LEDGER_NAMESPACE=""
  GRAPH_SCHEDULE_LOG_FILE=""
  GRAPH_SCHEDULE_ADMISSION_LOG_FILE=""
  GRAPH_SCHEDULE_LOG_RUN_DIR=""
  _graph_schedule_live_progress_reset
}

# graph_schedule_load_index <graph_json_path>
#
# jq-only loader (no python3). Builds parallel indexed arrays for node id,
# type, runtime, indegree, and delimited successor lists, plus an id->index
# map. Fails loudly when a node id contains GRAPH_SUCCESSOR_DELIM or when any
# edge references an unknown node (offending edge named in the error).
graph_schedule_load_index() {
  local graph_json_path="$1"
  local node_line edge_line node_id node_type node_runtime node_native_subagents
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
  if ! jq -jr '.nodes[] | ([.id, .type, (.stage.runtime // ""), (.stage.nativeSubagents // "off")] | map(tostring) | join("\u001c")) + "\n"' \
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
  while IFS=$'\034' read -r node_id node_type node_runtime node_native_subagents || [[ -n "$node_id" ]]; do
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
    case "$node_native_subagents" in
      inherit|off) ;;
      "") node_native_subagents="off" ;;
      *)
        echo "Error: invalid nativeSubagents value for node $node_id: $node_native_subagents" >&2
        rm -f "$nodes_tmp" "$edges_tmp" "$edges_cond_tmp"
        _graph_schedule_reset_index
        return 1
        ;;
    esac
    GRAPH_NODE_IDS+=("$node_id")
    GRAPH_NODE_TYPES+=("$node_type")
    GRAPH_NODE_RUNTIMES+=("$node_runtime")
    GRAPH_NODE_NATIVE_SUBAGENTS+=("$node_native_subagents")
    GRAPH_NODE_INDEGREES+=("0")
    GRAPH_NODE_SUCCESSORS+=("")
    GRAPH_NODE_COND_SUCCESSORS+=("")
    GRAPH_NODE_STATES+=("pending")
    GRAPH_NODE_REMAINING_INDEGREE+=("0")
    GRAPH_NODE_ATTEMPT_NUMBERS+=("0")
    GRAPH_NODE_CORRECTIVE_RETRIES_USED+=("0")
    GRAPH_NODE_TRANSIENT_RETRIES_USED+=("0")
    GRAPH_NODE_ACTIVE_SECONDS+=("0")
    GRAPH_NODE_ACTIVE_STARTED_AT+=("")
    GRAPH_NODE_USAGE_JSON+=("")
    GRAPH_NODE_OPERATOR_DENY_TURNS_USED+=("0")
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
  local poll_interval rc use_wait_n=0

  if [[ ${#GRAPH_CHILD_PIDS[@]} -eq 0 ]]; then
    echo "Error: graph_schedule_reap_one called with no tracked children" >&2
    return 1
  fi

  poll_interval="${GRAPH_REAP_POLL_INTERVAL:-0.25}"

  # wait -n blocks until a child exits, so live progress / run heartbeats cannot
  # emit during a slow agent. Prefer the portable poll path whenever live
  # progress is enabled (default), when delegation is active, or when forced.
  if _graph_schedule_reap_supports_wait_n \
    && [[ "${GRAPH_SCHEDULE_DELEGATION_ACTIVE:-0}" -eq 0 ]] \
    && [[ "${GRAPH_LIVE_PROGRESS:-1}" == "0" ]]; then
    use_wait_n=1
  fi

  if [[ "$use_wait_n" -eq 1 ]]; then
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

  # Portable bash 3.2 path, GRAPH_REAP_FORCE_POLL=1, and default live-progress
  # mode. Tick heartbeat + operator progress between polls so a slow fake/agent
  # still surfaces within the 15-second G09 bucket.
  while [[ ${#GRAPH_CHILD_PIDS[@]} -gt 0 ]]; do
    graph_schedule_tick_heartbeat
    graph_schedule_tick_live_progress
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
# cap (default 1, overridable via RALPH_GRAPH_MAX_PARALLEL_PER_RUNTIME). Each
# graph node consumes one parent-process runtime/token slot for its duration;
# resolved nativeSubagents (off|inherit) is opaque and does not reserve child
# slots. Reap
# with graph_schedule_reap_one, and on StageOutcomeReport success decrement each
# successor's remaining indegree. Exit 0 only when every node reached a
# successful terminal state (succeeded or scheduler-owned conditional skip).
# On ordinary failure: stop dispatch, apply failurePolicy (drain
# waits for in-flight; cancel SIGTERMs child process groups), mark transitive
# descendants blocked (unless reachable by another path that avoids the failed
# node), and exit with the failed node's exit code. Exit code 3 (human ack) is
# non-blocking: mark awaiting-ack only on that node and keep scheduling siblings.
# Plan-contract failures are not ordinary: the node becomes needs-plan-repair,
# only exclusive descendants are blocked, and independent branches keep
# dispatching. Operator-permission is also not ordinary: persist a request,
# pause the node/attempt as awaiting-operator, release concurrency/runtime
# slots, and keep dispatching independent branches without consuming retry
# or active-time budget. A valid decision is consumed once: allow uses the
# adapter continuation path, deny permits at most one compact alternative
# turn. Exit 3 only when no runnable/running work remains and a wait is
# unresolved. The frozen graph.json and writeScopes are never mutated.
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

# _graph_schedule_print_summary <run-status>
#
# Closing block for a run. A graph can end with nodes in several states at once
# (one failure plus a set of blocked descendants under drain), so the tally is
# printed alongside the headline rather than a single "failed" line, and every
# non-succeeded node is named. Without this the operator has to reconstruct what
# actually ran from the interleaved lifecycle lines.
_graph_schedule_print_summary() {
  local run_status="$1"
  local i state node
  local n_ok=0 n_failed=0 n_blocked=0 n_cancelled=0 n_other=0
  local trouble=""

  for ((i = 0; i < ${#GRAPH_NODE_STATES[@]}; i++)); do
    state="${GRAPH_NODE_STATES[$i]}"
    node="${GRAPH_NODE_IDS[$i]:-?}"
    case "$state" in
      succeeded|skipped) n_ok=$((n_ok + 1)) ;;
      failed) n_failed=$((n_failed + 1)); trouble+="    failed     $node"$'\n' ;;
      blocked) n_blocked=$((n_blocked + 1)); trouble+="    blocked    $node"$'\n' ;;
      cancelled) n_cancelled=$((n_cancelled + 1)); trouble+="    cancelled  $node"$'\n' ;;
      *) n_other=$((n_other + 1)); trouble+="    $state $node"$'\n' ;;
    esac
  done

  case "$run_status" in
    succeeded) graph_ui_banner "Graph run succeeded" "$GRAPH_SCHEDULE_NAMESPACE" ;;
    awaiting-ack) graph_ui_banner "Graph run awaiting acknowledgement" "$GRAPH_SCHEDULE_NAMESPACE" ;;
    awaiting-operator) graph_ui_banner "Graph run awaiting operator" "$GRAPH_SCHEDULE_NAMESPACE" ;;
    *) graph_ui_banner "Graph run $run_status" "$GRAPH_SCHEDULE_NAMESPACE" ;;
  esac

  graph_ui_kv "nodes" "$n_ok succeeded, $n_failed failed, $n_blocked blocked, $n_cancelled cancelled, $n_other other"
  graph_ui_kv "exit" "$GRAPH_SCHEDULE_EXIT_CODE"
  [[ -n "$GRAPH_SCHEDULE_FAILED_NODE" ]] && graph_ui_kv "first failure" "$GRAPH_SCHEDULE_FAILED_NODE"
  if [[ -n "$trouble" ]]; then
    printf '%b%s%b\n' "$GRAPH_UI_DIM" "  not succeeded:" "$GRAPH_UI_RST" >&2
    printf '%s' "$trouble" >&2
  fi
  [[ -n "$GRAPH_SCHEDULE_LOG_FILE" ]] && graph_ui_kv "log" "$GRAPH_SCHEDULE_LOG_FILE"
  printf '\n' >&2
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

# Default scheduler heartbeat tick interval in seconds. Tests override via
# GRAPH_HEARTBEAT_INTERVAL_SECONDS; the tick function also honors
# GRAPH_HEARTBEAT_NOW_EPOCH for deterministic time control.
GRAPH_HEARTBEAT_INTERVAL_SECONDS="${GRAPH_HEARTBEAT_INTERVAL_SECONDS:-30}"

# graph_schedule_tick_heartbeat
# One bounded scheduler-loop tick that refreshes the run heartbeat and the
# heartbeats of currently running attempts. Writes only when the configured
# interval has elapsed since the last tick; rapid loop iterations therefore
# do not cause repeated disk writes. No polling process is spawned.
graph_schedule_tick_heartbeat() {
  local workspace="${GRAPH_SCHEDULE_WORKSPACE:-}"
  local namespace="${GRAPH_SCHEDULE_LEDGER_NAMESPACE:-${GRAPH_SCHEDULE_NAMESPACE:-}}"
  local run_id="${GRAPH_SCHEDULE_RUN_ID:-}"
  local interval now_epoch last_tick i node_id attempt_id

  if [[ -z "$workspace" || -z "$namespace" || -z "$run_id" ]]; then
    return 0
  fi

  interval="$(_graph_schedule_positive_int_or_default "${GRAPH_HEARTBEAT_INTERVAL_SECONDS:-}" 30)"
  now_epoch="${GRAPH_HEARTBEAT_NOW_EPOCH:-$(date +%s)}"
  [[ "$now_epoch" =~ ^[0-9]+$ ]] || now_epoch="$(date +%s)"
  last_tick="${GRAPH_HEARTBEAT_LAST_TICK_EPOCH:-0}"
  [[ "$last_tick" =~ ^[0-9]+$ ]] || last_tick=0

  if [[ "$(( now_epoch - last_tick ))" -lt "$interval" ]]; then
    return 0
  fi

  graph_state_update_run_heartbeat "$workspace" "$namespace" "$run_id" >/dev/null 2>&1 || true

  for ((i = 0; i < ${#GRAPH_NODE_IDS[@]}; i++)); do
    if [[ "${GRAPH_NODE_STATES[$i]:-}" != "running" ]]; then
      continue
    fi
    node_id="${GRAPH_NODE_IDS[$i]}"
    attempt_id="$(graph_state_node_last_attempt_id "$workspace" "$namespace" "$run_id" "$node_id" 2>/dev/null || true)"
    if [[ -z "$attempt_id" ]]; then
      continue
    fi
    graph_state_update_attempt_heartbeat "$workspace" "$namespace" "$run_id" "$node_id" "$attempt_id" >/dev/null 2>&1 || true
  done

  GRAPH_HEARTBEAT_LAST_TICK_EPOCH="$now_epoch"
  return 0
}

# ---------------------------------------------------------------------------
# G09 bounded live progress
#
# Operator heartbeat for running nodes only. Emits at most once per 15-second
# bucket, and immediately when node/runtime/model/TODO/log-line identity
# changes. Never lists unchanged pending nodes. Lines are redacted with the
# same credential rules as failure summaries and never carry chain-of-thought,
# hidden prompts, or raw tool arguments. Repeated identical progress is
# suppressed. GRAPH_LIVE_PROGRESS=0 disables emission.
# ---------------------------------------------------------------------------

GRAPH_LIVE_PROGRESS_INTERVAL_SECONDS="${GRAPH_LIVE_PROGRESS_INTERVAL_SECONDS:-15}"
GRAPH_LIVE_PROGRESS_LINE_MAX="${GRAPH_LIVE_PROGRESS_LINE_MAX:-200}"
# Per-node last emitted change key and full progress signature (parallel arrays).
GRAPH_LIVE_PROGRESS_NODE_IDS=()
GRAPH_LIVE_PROGRESS_CHANGE_KEYS=()
GRAPH_LIVE_PROGRESS_SIGNATURES=()
GRAPH_LIVE_PROGRESS_LAST_EMIT_EPOCH=()
# Per-node last-checked epoch: gates how often the expensive detection path
# (jq/tail/sed subprocesses) runs at all, independent of whether it emits.
# Without this, a computation that itself takes longer than the interval
# (e.g. under process-spawn-heavy conditions) re-triggers on the very next
# poll, defeating the interval bound.
GRAPH_LIVE_PROGRESS_LAST_CHECK_EPOCH=()
# Per-node log-path cache, keyed by the attempt id they were resolved for.
# graph_logs_attempt_rel claims/persists an id mapping (jq read + write), so
# resolving it fresh on every ~0.2s poll tick is expensive enough to starve
# the reaper of a slow node. Resolve once per attempt and reuse until the
# node's attempt id changes.
GRAPH_LIVE_PROGRESS_CACHE_ATTEMPT_IDS=()
GRAPH_LIVE_PROGRESS_CACHE_AGENT_PATHS=()
GRAPH_LIVE_PROGRESS_CACHE_RUNNER_PATHS=()

_graph_schedule_live_progress_reset() {
  GRAPH_LIVE_PROGRESS_NODE_IDS=()
  GRAPH_LIVE_PROGRESS_CHANGE_KEYS=()
  GRAPH_LIVE_PROGRESS_SIGNATURES=()
  GRAPH_LIVE_PROGRESS_LAST_EMIT_EPOCH=()
  GRAPH_LIVE_PROGRESS_LAST_CHECK_EPOCH=()
  GRAPH_LIVE_PROGRESS_CACHE_ATTEMPT_IDS=()
  GRAPH_LIVE_PROGRESS_CACHE_AGENT_PATHS=()
  GRAPH_LIVE_PROGRESS_CACHE_RUNNER_PATHS=()
}

_graph_schedule_live_progress_slot() {
  local node_id="$1" i
  for ((i = 0; i < ${#GRAPH_LIVE_PROGRESS_NODE_IDS[@]}; i++)); do
    if [[ "${GRAPH_LIVE_PROGRESS_NODE_IDS[$i]}" == "$node_id" ]]; then
      printf '%s\n' "$i"
      return 0
    fi
  done
  GRAPH_LIVE_PROGRESS_NODE_IDS+=("$node_id")
  GRAPH_LIVE_PROGRESS_CHANGE_KEYS+=("")
  GRAPH_LIVE_PROGRESS_SIGNATURES+=("")
  GRAPH_LIVE_PROGRESS_LAST_EMIT_EPOCH+=("0")
  GRAPH_LIVE_PROGRESS_LAST_CHECK_EPOCH+=("0")
  GRAPH_LIVE_PROGRESS_CACHE_ATTEMPT_IDS+=("")
  GRAPH_LIVE_PROGRESS_CACHE_AGENT_PATHS+=("")
  GRAPH_LIVE_PROGRESS_CACHE_RUNNER_PATHS+=("")
  printf '%s\n' "$((${#GRAPH_LIVE_PROGRESS_NODE_IDS[@]} - 1))"
}

# _graph_schedule_live_progress_redact <text>
# Credential redaction + length cap + reject CoT / prompt / tool-arg shapes.
_graph_schedule_live_progress_redact() {
  local text="${1:-}" lower
  text="$(printf '%s' "$text" | tr '\n\r\t' ' ' | tr -s ' ')"
  text="${text# }"
  text="${text% }"
  [[ -n "$text" ]] || return 0
  lower="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    *'<thinking>'*|*'</thinking>'*|*chain-of-thought*|*chain\ of\ thought*)
      return 0
      ;;
    *hidden\ prompt*|*system\ prompt*|*tool_use*|*tool\ call\ args*|*\"arguments\"*|*raw\ tool*)
      return 0
      ;;
    thinking:*|reasoning:*|scratchpad:*|internal\ monologue:*)
      return 0
      ;;
  esac
  if declare -F graph_failure_redact_text >/dev/null 2>&1; then
    text="$(graph_failure_redact_text "$text")"
    text="${text%$'\n'}"
  fi
  if declare -F graph_failure_bound_summary >/dev/null 2>&1; then
    text="$(GRAPH_FAILURE_SUMMARY_MAX="${GRAPH_LIVE_PROGRESS_LINE_MAX:-200}" graph_failure_bound_summary "$text")"
    text="${text%$'\n'}"
  fi
  printf '%s\n' "$text"
}

# _graph_schedule_live_progress_follow_command <node_id> [attempt_id]
# Exact operator follow-log command (G08 running action).
_graph_schedule_live_progress_follow_command() {
  local node_id="$1" attempt_id="${2:-}"
  local ns="${GRAPH_SCHEDULE_NAMESPACE:-}" run_id="${GRAPH_SCHEDULE_RUN_ID:-}"
  local -a argv=(ralph workflow logs "$run_id" --stage "$node_id")
  local attempt_number=""
  if [[ "$attempt_id" =~ __([0-9]+)$ ]]; then
    attempt_number="${BASH_REMATCH[1]}"
  elif [[ "$attempt_id" =~ ^[0-9]+$ ]]; then
    attempt_number="$attempt_id"
  fi
  if [[ -n "$attempt_number" ]]; then
    argv+=(--attempt "$attempt_number")
  fi
  local text="" part
  for part in "${argv[@]}"; do
    [[ -n "$text" ]] && text+=" "
    text+="$(printf '%q' "$part")"
  done
  printf '%s\n' "$text"
}

# _graph_schedule_live_progress_model <node_id>
# Stage model override from the frozen graph when present.
_graph_schedule_live_progress_model() {
  local node_id="$1" model=""
  [[ -n "${GRAPH_SCHEDULE_GRAPH_JSON:-}" && -f "${GRAPH_SCHEDULE_GRAPH_JSON:-}" ]] || return 0
  model="$(jq -r --arg id "$node_id" '
    (.nodes // []) | map(select(.id == $id)) | first | .stage.model // empty
  ' "$GRAPH_SCHEDULE_GRAPH_JSON" 2>/dev/null)" || model=""
  printf '%s\n' "$model"
}

# _graph_schedule_live_progress_extract_todo <line>
# Prints a TODO id when the line carries a structured marker.
_graph_schedule_live_progress_extract_todo() {
  local line="$1" todo=""
  todo="$(printf '%s' "$line" | sed -nE 's/.*"currentTodoId"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p')"
  if [[ -z "$todo" ]]; then
    todo="$(printf '%s' "$line" | sed -nE 's/.*currentTodoId=([A-Za-z0-9._-]+).*/\1/p')"
  fi
  if [[ -z "$todo" ]]; then
    todo="$(printf '%s' "$line" | sed -nE 's/.*RALPH_CURRENT_TODO_ID=([A-Za-z0-9._-]+).*/\1/p')"
  fi
  if [[ -z "$todo" ]]; then
    todo="$(printf '%s' "$line" | sed -nE 's/.*TODO id=([A-Za-z0-9._-]+).*/\1/p')"
  fi
  if [[ -z "$todo" ]]; then
    todo="$(printf '%s' "$line" | sed -nE 's/.*\bid=([A-Za-z0-9._-]+).*TODO \(line.*/\1/p')"
  fi
  printf '%s\n' "$todo"
}

# _graph_schedule_live_progress_current_todo <log-path...>
# Prefer structured runner markers when present.
_graph_schedule_live_progress_current_todo() {
  local path line todo="" found=""
  for path in "$@"; do
    [[ -n "$path" && -f "$path" && ! -L "$path" ]] || continue
    found=""
    while IFS= read -r line || [[ -n "$line" ]]; do
      todo="$(_graph_schedule_live_progress_extract_todo "$line")"
      [[ -n "$todo" ]] && found="$todo"
    done < <(tail -n 80 "$path" 2>/dev/null || true)
    if [[ -n "$found" ]]; then
      printf '%s\n' "$found"
      return 0
    fi
  done
  return 0
}

# _graph_schedule_live_progress_last_safe_line <agent-log-path>
# Last nonempty operator-safe agent-log line (no CoT / credentials).
_graph_schedule_live_progress_last_safe_line() {
  local log_path="$1" raw candidate="" safe=""
  [[ -n "$log_path" && -f "$log_path" && ! -L "$log_path" ]] || return 0
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    [[ -n "${raw//[[:space:]]/}" ]] || continue
    case "$raw" in
      [+#|=]*) continue ;;
      ---*) continue ;;
    esac
    [[ "$raw" =~ ^[[:space:]]*\[[0-9]{4}- ]] && continue
    candidate="$(_graph_schedule_live_progress_redact "$raw")" || candidate=""
    [[ -n "$candidate" ]] || continue
    safe="$candidate"
  done < <(tail -n 80 "$log_path" 2>/dev/null || true)
  printf '%s\n' "$safe"
}

# _graph_schedule_live_progress_fmt_elapsed <seconds>
_graph_schedule_live_progress_fmt_elapsed() {
  local seconds="${1:-0}" minutes hours
  [[ "$seconds" =~ ^[0-9]+$ ]] || seconds=0
  if [[ "$seconds" -lt 60 ]]; then
    printf '%ss\n' "$seconds"
    return 0
  fi
  minutes=$((seconds / 60))
  if [[ "$minutes" -lt 60 ]]; then
    printf '%sm%02ds\n' "$minutes" "$((seconds % 60))"
    return 0
  fi
  hours=$((minutes / 60))
  printf '%sh%02dm\n' "$hours" "$((minutes % 60))"
}

# _graph_schedule_live_progress_emit_node <node_id>
# Build and maybe print one progress block for a running node.
_graph_schedule_live_progress_emit_node() {
  local node_id="$1"
  local idx slot runtime model attempt_id elapsed todo last_line follow_cmd
  local run_dir agent_rel runner_rel agent_path runner_path
  local change_key signature now_epoch last_emit last_check interval force=0
  local last_change last_sig heartbeat_interval attempt_number elapsed_text

  if ! idx="$(graph_schedule_index_map_get "$node_id" 2>/dev/null)"; then
    return 0
  fi
  if [[ "${GRAPH_NODE_STATES[$idx]:-}" != "running" ]]; then
    return 0
  fi

  slot="$(_graph_schedule_live_progress_slot "$node_id")"
  interval="$(_graph_schedule_positive_int_or_default "${GRAPH_LIVE_PROGRESS_INTERVAL_SECONDS:-}" 15)"
  now_epoch="${GRAPH_LIVE_PROGRESS_NOW_EPOCH:-${GRAPH_HEARTBEAT_NOW_EPOCH:-$(date +%s)}}"
  [[ "$now_epoch" =~ ^[0-9]+$ ]] || now_epoch="$(date +%s)"
  last_check="${GRAPH_LIVE_PROGRESS_LAST_CHECK_EPOCH[$slot]:-0}"
  [[ "$last_check" =~ ^[0-9]+$ ]] || last_check=0
  # The full detection path below spawns several jq/tail/sed subprocesses per
  # node; running it on every ~0.2s reap poll (rather than once per bucket)
  # is expensive enough to starve the reaper and blow the G09 15-second
  # bound. Sample it at most once per interval, gated on when it was last
  # attempted (not last emitted) so a computation that itself runs long does
  # not immediately retrigger on the next poll. A node is still checked
  # immediately the first time it is seen running (last_check=0).
  if [[ "$last_check" -ne 0 && "$((now_epoch - last_check))" -lt "$interval" ]]; then
    return 0
  fi
  GRAPH_LIVE_PROGRESS_LAST_CHECK_EPOCH[$slot]="$now_epoch"

  runtime="${GRAPH_NODE_RUNTIMES[$idx]:-}"
  model="$(_graph_schedule_live_progress_model "$node_id")"
  attempt_id="$(graph_state_node_last_attempt_id \
    "${GRAPH_SCHEDULE_WORKSPACE:-}" "${GRAPH_SCHEDULE_LEDGER_NAMESPACE:-${GRAPH_SCHEDULE_NAMESPACE:-}}" \
    "${GRAPH_SCHEDULE_RUN_ID:-}" "$node_id" 2>/dev/null || true)"
  if [[ -z "$attempt_id" ]]; then
    local attempt_number="${GRAPH_NODE_ATTEMPT_NUMBERS[$idx]:-}"
    if [[ -n "$attempt_number" && "$attempt_number" != "0" ]]; then
      attempt_id="$(graph_dispatch_mint_attempt_id "$node_id" "$GRAPH_SCHEDULE_RUN_ID" "$attempt_number" 2>/dev/null || true)"
    fi
  fi
  elapsed="$(graph_schedule_node_active_seconds "$node_id" 2>/dev/null || printf '0\n')"
  [[ "$elapsed" =~ ^[0-9]+$ ]] || elapsed=0

  # graph_logs_attempt_rel claims/persists an id mapping (jq read + write on
  # every call), so it is too expensive to re-resolve on every ~0.2s poll
  # tick. Resolve the log paths once per attempt id and cache them; a slow
  # node's heartbeat then costs one cheap file read per tick instead of four
  # claim round-trips.
  run_dir="${GRAPH_SCHEDULE_LOG_RUN_DIR:-${GRAPH_SCHEDULE_LEDGER_RUN_DIR:-}}"
  if [[ -n "$attempt_id" && "$attempt_id" == "${GRAPH_LIVE_PROGRESS_CACHE_ATTEMPT_IDS[$slot]:-}" ]]; then
    agent_path="${GRAPH_LIVE_PROGRESS_CACHE_AGENT_PATHS[$slot]:-}"
    runner_path="${GRAPH_LIVE_PROGRESS_CACHE_RUNNER_PATHS[$slot]:-}"
  else
    agent_path=""
    runner_path=""
    if [[ -n "$run_dir" && -n "$attempt_id" ]]; then
      agent_rel="$(graph_logs_attempt_rel "$run_dir" "$node_id" "$attempt_id" "agent.log" 2>/dev/null || true)"
      runner_rel="$(graph_logs_attempt_rel "$run_dir" "$node_id" "$attempt_id" "runner.log" 2>/dev/null || true)"
      [[ -n "$agent_rel" ]] && agent_path="$(graph_logs_read "$run_dir" "$agent_rel" 2>/dev/null || true)"
      [[ -n "$runner_rel" ]] && runner_path="$(graph_logs_read "$run_dir" "$runner_rel" 2>/dev/null || true)"
    fi
    GRAPH_LIVE_PROGRESS_CACHE_ATTEMPT_IDS[$slot]="$attempt_id"
    GRAPH_LIVE_PROGRESS_CACHE_AGENT_PATHS[$slot]="$agent_path"
    GRAPH_LIVE_PROGRESS_CACHE_RUNNER_PATHS[$slot]="$runner_path"
  fi

  todo="$(_graph_schedule_live_progress_current_todo "$runner_path" "$agent_path")"
  last_line="$(_graph_schedule_live_progress_last_safe_line "$agent_path")"
  follow_cmd="$(_graph_schedule_live_progress_follow_command "$node_id" "$attempt_id")"

  change_key="${node_id}|${runtime}|${model}|${attempt_id}|${todo}|${last_line}"
  signature="${change_key}|${elapsed}|${follow_cmd}"

  last_change="${GRAPH_LIVE_PROGRESS_CHANGE_KEYS[$slot]:-}"
  last_sig="${GRAPH_LIVE_PROGRESS_SIGNATURES[$slot]:-}"
  last_emit="${GRAPH_LIVE_PROGRESS_LAST_EMIT_EPOCH[$slot]:-0}"
  [[ "$last_emit" =~ ^[0-9]+$ ]] || last_emit=0

  heartbeat_interval="$(_graph_schedule_positive_int_or_default "${GRAPH_LIVE_PROGRESS_HEARTBEAT_SECONDS:-}" 60)"
  if [[ "$change_key" != "$last_change" ]]; then
    force=1
  elif [[ "$((now_epoch - last_emit))" -ge "$heartbeat_interval" ]]; then
    force=1
  fi
  [[ "$force" -eq 1 ]] || return 0
  # Identical full line (including elapsed) is suppressed even when the bucket
  # elapsed, so a quiet agent does not flood unchanged heartbeats.
  if [[ "$signature" == "$last_sig" ]]; then
    return 0
  fi

  graph_ui_init
  attempt_number="${GRAPH_NODE_ATTEMPT_NUMBERS[$idx]:-1}"
  elapsed_text="$(_graph_schedule_live_progress_fmt_elapsed "$elapsed")"
  printf '%b%s%b %b%s%b' \
    "$GRAPH_UI_C" "~~" "$GRAPH_UI_RST" \
    "$GRAPH_UI_BOLD" "$node_id" "$GRAPH_UI_RST" >&2
  printf ' runtime=%s' "$runtime" >&2
  [[ -n "$model" ]] && printf ' model=%s' "$model" >&2
  printf ' attempt=%s' "$attempt_number" >&2
  printf ' elapsed=%s' "$elapsed_text" >&2
  [[ -n "$todo" ]] && printf ' todo=%s' "$todo" >&2
  printf '\n' >&2
  if [[ "$change_key" != "$last_change" ]]; then
    [[ -n "$last_line" ]] && graph_ui_detail "last: $last_line"
    graph_ui_detail "logs: $follow_cmd"
  fi

  GRAPH_LIVE_PROGRESS_CHANGE_KEYS[$slot]="$change_key"
  GRAPH_LIVE_PROGRESS_SIGNATURES[$slot]="$signature"
  GRAPH_LIVE_PROGRESS_LAST_EMIT_EPOCH[$slot]="$now_epoch"
  return 0
}

# graph_schedule_tick_live_progress
# Emit bounded operator progress for currently running nodes only.
graph_schedule_tick_live_progress() {
  local i node_id
  if [[ "${GRAPH_LIVE_PROGRESS:-1}" == "0" ]]; then
    return 0
  fi
  if [[ -z "${GRAPH_SCHEDULE_NAMESPACE:-}" || -z "${GRAPH_SCHEDULE_RUN_ID:-}" ]]; then
    return 0
  fi
  for ((i = 0; i < ${#GRAPH_NODE_IDS[@]}; i++)); do
    if [[ "${GRAPH_NODE_STATES[$i]:-}" != "running" ]]; then
      continue
    fi
    node_id="${GRAPH_NODE_IDS[$i]}"
    _graph_schedule_live_progress_emit_node "$node_id" || true
  done
  return 0
}

# graph_schedule_correction_record_path <run_dir> <node_id>
# Contained path for the latest compact correction record of a node.
graph_schedule_correction_record_path() {
  local run_dir="$1" node_id="$2" safe
  if [[ -z "$run_dir" || -z "$node_id" ]]; then
    echo "Error: graph_schedule_correction_record_path requires run_dir and node_id" >&2
    return 1
  fi
  safe="$(printf '%s' "$node_id" | sed 's/[^A-Za-z0-9._-]/_/g')"
  printf '%s/corrections/%s.json\n' "$run_dir" "$safe"
}

# _graph_schedule_attempt_number_from_id <attempt_id>
# Numeric suffix of node__run__N. Prints 0 when absent.
_graph_schedule_attempt_number_from_id() {
  local attempt_id="$1" n
  n="${attempt_id##*__}"
  if [[ "$n" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$n"
    return 0
  fi
  printf '0\n'
}

# _graph_schedule_correction_paths_from_reason <reason>
# After the last classifying token, the remainder is treated as a path.
_graph_schedule_correction_paths_from_reason() {
  local reason="${1:-}" rest prefix
  [[ -n "$reason" ]] || { printf '[]\n'; return 0; }
  rest="$reason"
  while [[ "$rest" == *:* ]]; do
    prefix="${rest%%:*}"
    if graph_failure_map_kind "$prefix" >/dev/null 2>&1; then
      rest="${rest#*:}"
    else
      break
    fi
  done
  if [[ -z "$rest" ]] || graph_failure_map_kind "$rest" >/dev/null 2>&1; then
    printf '[]\n'
    return 0
  fi
  jq -cn --arg p "$rest" '[$p]'
}

# _graph_schedule_correction_component_from_reason <reason>
# Most specific classifying token in a colon-delimited reason.
_graph_schedule_correction_component_from_reason() {
  local reason="${1:-}" token rest mapped="" candidate
  [[ -n "$reason" ]] || return 1
  rest="$reason"
  while [[ -n "$rest" ]]; do
    if [[ "$rest" == *:* ]]; then
      token="${rest%%:*}"
      rest="${rest#*:}"
    else
      token="$rest"
      rest=""
    fi
    [[ -n "$token" ]] || continue
    if candidate="$(graph_failure_map_kind "$token" 2>/dev/null)" && [[ "$candidate" == "agent-correctable" ]]; then
      mapped="$token"
    fi
  done
  [[ -n "$mapped" ]] || return 1
  printf '%s\n' "$mapped"
}

# graph_schedule_write_correction_record <run_dir> <node_id> <current_attempt_number> <result_json_or_path>
#
# For agent-correctable results only, write one compact correction JSON
# containing failedCompletionComponent, offendingPaths (offending paths or
# missing artifacts), verificationResultPath, and nextAttemptNumber.
# Prompts and raw output from the source result are discarded.
# Prints the record path on success. Returns 1 when the result is not
# agent-correctable or arguments are invalid.
graph_schedule_write_correction_record() {
  local run_dir="$1" node_id="$2" current_attempt="$3" result_in="${4:-}"
  local report class extracted component paths_json verify next_n dest reason_paths
  local reason_component

  if [[ -z "$run_dir" || -z "$node_id" ]]; then
    echo "Error: graph_schedule_write_correction_record requires run_dir and node_id" >&2
    return 1
  fi
  if [[ ! "$current_attempt" =~ ^[0-9]+$ ]]; then
    echo "Error: graph_schedule_write_correction_record current attempt must be a number" >&2
    return 1
  fi

  if [[ "$result_in" == \{* || "$result_in" == \[* ]]; then
    report="$result_in"
  elif [[ -n "$result_in" && -f "$result_in" ]]; then
    report="$(cat -- "$result_in" 2>/dev/null || true)"
  else
    report="$result_in"
  fi

  class="$(graph_failure_classify "$report" 2>/dev/null | jq -r '.classification // empty')"
  if [[ "$class" != "agent-correctable" ]]; then
    return 1
  fi

  extracted="$(printf '%s' "$report" | jq -c '
    def as_paths:
      if . == null then []
      elif type == "array" then
        [.[] | if type == "string" then .
               elif type == "object" then (.path // .artifact // empty)
               else empty end]
      elif type == "string" and . != "" then [.]
      else [] end;
    {
      component: ((.failedCompletionComponent // .completionComponent // .component // .failure.cause // "") | tostring),
      kind: ((.kind // .category // .failureKind // .failure.cause // "") | tostring),
      reason: ((.reason // .failure.cause // "") | tostring),
      verificationResultPath: ((.verificationResultPath // .verificationResult // .verificationResultFile // .failure.verificationResultPath // "") | tostring),
      offendingPaths: (
        ((.offendingPaths | as_paths)
         + (.missingArtifacts | as_paths)
         + (.failure.offendingPaths | as_paths)
         + (.failure.missingArtifacts | as_paths)
         + (.undeclaredPaths | as_paths)
         + (.outOfScope | as_paths)
         + (.paths | as_paths)
         + ((.missingArtifact // .artifact // "") | as_paths))
        | unique
        | map(select(. != "" and . != "null"))
      )
    }
  ' 2>/dev/null)" || extracted=""

  if [[ -z "$extracted" ]]; then
    return 1
  fi

  component="$(printf '%s' "$extracted" | jq -r '.component')"
  paths_json="$(printf '%s' "$extracted" | jq -c '.offendingPaths')"
  verify="$(printf '%s' "$extracted" | jq -r '.verificationResultPath')"
  if [[ "$verify" == "null" ]]; then
    verify=""
  fi

  if [[ -z "$component" ]]; then
    component="$(printf '%s' "$extracted" | jq -r '.kind')"
  fi
  if reason_component="$(_graph_schedule_correction_component_from_reason "$(printf '%s' "$extracted" | jq -r '.reason')")"; then
    if [[ -z "$component" ]] || ! graph_failure_map_kind "$component" >/dev/null 2>&1; then
      component="$reason_component"
    elif [[ "$(graph_failure_map_kind "$reason_component" 2>/dev/null || true)" == "agent-correctable" ]]; then
      component="$reason_component"
    fi
  fi
  if [[ -z "$component" ]]; then
    component="verification"
  fi

  reason_paths="$(_graph_schedule_correction_paths_from_reason "$(printf '%s' "$extracted" | jq -r '.reason')")"
  paths_json="$(jq -cn --argjson a "$paths_json" --argjson b "${reason_paths:-[]}" '($a + $b) | unique')"

  next_n=$((current_attempt + 1))
  dest="$(graph_schedule_correction_record_path "$run_dir" "$node_id")" || return 1
  mkdir -p "$(dirname "$dest")" || return 1
  ralph_atomic_write_json "$dest" \
    '{failedCompletionComponent:$c,offendingPaths:$p,verificationResultPath:(if $v == "" then null else $v end),nextAttemptNumber:($n|tonumber)}' \
    --arg c "$component" --argjson p "$paths_json" --arg v "$verify" --arg n "$next_n" || return 1
  printf '%s\n' "$dest"
}

# _graph_schedule_try_write_correction_record <node_id> <attempt_id> <result_json_or_path>
# Best-effort write during reap. No-ops without a run directory or when the
# result is not agent-correctable. Does not change failure handling.
_graph_schedule_try_write_correction_record() {
  local node_id="$1" attempt_id="$2" result="${3:-}"
  local run_dir current idx
  run_dir="${GRAPH_SCHEDULE_LEDGER_RUN_DIR:-${GRAPH_SCHEDULE_LOG_RUN_DIR:-}}"
  [[ -n "$run_dir" && -d "$run_dir" ]] || return 0
  current=""
  if idx="$(graph_schedule_index_map_get "$node_id" 2>/dev/null)"; then
    current="${GRAPH_NODE_ATTEMPT_NUMBERS[$idx]:-}"
  fi
  if [[ ! "$current" =~ ^[1-9][0-9]*$ ]]; then
    current="$(_graph_schedule_attempt_number_from_id "$attempt_id")"
  fi
  [[ "$current" =~ ^[0-9]+$ ]] || current=0
  graph_schedule_write_correction_record "$run_dir" "$node_id" "$current" "$result" >/dev/null 2>&1 || true
}

# _graph_schedule_correction_result_for_reason <reason> [paths_json] [verification_result_path]
# Build a structured result for a supervisor-owned failure. When a reap report
# exists, merge kind/component/paths onto it so classification still sees the
# supervisor failure rather than the earlier success outcome.
_graph_schedule_correction_result_for_reason() {
  local reason="$1" paths_json="${2:-[]}" verify="${3:-}"
  local report_path="${GRAPH_REAP_REPORT_PATH:-}" component
  [[ "$paths_json" == \[* ]] || paths_json='[]'
  component="$(_graph_schedule_correction_component_from_reason "$reason" 2>/dev/null || true)"
  [[ -n "$component" ]] || component="$reason"
  if [[ -n "$report_path" && -f "$report_path" ]]; then
    jq -c --arg kind "$reason" --arg component "$component" --argjson paths "$paths_json" --arg verify "$verify" '
      . + {
        kind: $kind,
        component: $component,
        reason: $kind,
        offendingPaths: (((.offendingPaths // []) + (.missingArtifacts // []) + $paths) | unique),
        verificationResultPath: (if $verify != "" then $verify
                                 else (.verificationResultPath // .verificationResult // "") end)
      }
    ' "$report_path" 2>/dev/null && return 0
  fi
  jq -cn --arg kind "$reason" --arg component "$component" --argjson paths "$paths_json" --arg verify "$verify" \
    '{kind:$kind,component:$component,reason:$kind,offendingPaths:$paths,verificationResultPath:$verify}'
}

# graph_schedule_node_session_resume_supported <graph_json> <node_id>
# Returns 0 when the frozen stage can take a resumed session turn
# (sessionStrategy resume|reset|compact, or sessionResume true).
graph_schedule_node_session_resume_supported() {
  local graph_json="$1" node_id="$2" strategy resume
  if [[ -z "$graph_json" || ! -f "$graph_json" || -z "$node_id" ]]; then
    return 1
  fi
  strategy="$(jq -r --arg id "$node_id" \
    '.nodes[] | select(.id == $id) | .stage.sessionStrategy // empty' \
    "$graph_json" 2>/dev/null)" || strategy=""
  resume="$(jq -r --arg id "$node_id" \
    '.nodes[] | select(.id == $id) | .stage.sessionResume // false' \
    "$graph_json" 2>/dev/null)" || resume="false"
  case "$strategy" in
    resume|reset|compact) return 0 ;;
  esac
  [[ "$resume" == "true" ]]
}

# graph_schedule_corrective_retry_turn <run_dir> <node_id> [graph_json]
# Prints the compact correction record path for the next supported session
# turn. The turn payload is that record only -- no prompt or raw output.
# Returns 1 when session resume is unsupported or the record is missing.
graph_schedule_corrective_retry_turn() {
  local run_dir="$1" node_id="$2" graph_json="${3:-${GRAPH_SCHEDULE_GRAPH_JSON:-}}"
  local record
  graph_schedule_node_session_resume_supported "$graph_json" "$node_id" || return 1
  record="$(graph_schedule_correction_record_path "$run_dir" "$node_id")" || return 1
  [[ -f "$record" ]] || return 1
  printf '%s\n' "$record"
}

# graph_schedule_retry_context_path <run_dir> <node_id>
# Contained path for the latest compact retry-context record of a node.
graph_schedule_retry_context_path() {
  local run_dir="$1" node_id="$2" safe
  if [[ -z "$run_dir" || -z "$node_id" ]]; then
    echo "Error: graph_schedule_retry_context_path requires run_dir and node_id" >&2
    return 1
  fi
  safe="$(printf '%s' "$node_id" | sed 's/[^A-Za-z0-9._-]/_/g')"
  printf '%s/retry-context/%s.json\n' "$run_dir" "$safe"
}

# _graph_schedule_retry_context_max_bytes
# Call-time cap so tests can override GRAPH_SCHEDULE_RETRY_CONTEXT_MAX_BYTES.
_graph_schedule_retry_context_max_bytes() {
  local max="${GRAPH_SCHEDULE_RETRY_CONTEXT_MAX_BYTES:-4096}"
  if [[ ! "$max" =~ ^[1-9][0-9]*$ ]]; then
    max=4096
  fi
  printf '%s\n' "$max"
}

# _graph_schedule_retry_context_load_json <json_or_path>
# Prints a compact JSON object, or empty when the input is missing/invalid.
_graph_schedule_retry_context_load_json() {
  local input="${1:-}" raw=""
  if [[ -z "$input" ]]; then
    return 0
  fi
  if [[ "$input" == \{* || "$input" == \[* ]]; then
    raw="$input"
  elif [[ -f "$input" ]]; then
    raw="$(cat -- "$input" 2>/dev/null || true)"
  else
    raw="$input"
  fi
  [[ -n "$raw" ]] || return 0
  printf '%s' "$raw" | jq -c 'if type == "object" or type == "array" then . else empty end' 2>/dev/null || true
}

# _graph_schedule_retry_context_drop_forbidden <json>
# Strip prior prompts, transcripts, and raw output from any object depth.
_graph_schedule_retry_context_drop_forbidden() {
  local json="${1:-}" out
  [[ -n "$json" ]] || { printf '{}\n'; return 0; }
  out="$(printf '%s' "$json" | jq -c '
    def drop:
      if type == "object" then
        del(.prompt, .output, .rawOutput, .stdout, .stderr, .text, .transcript,
            .messages, .priorPrompt, .fullLog, .raw, .body)
        | with_entries(.value |= drop)
      elif type == "array" then map(drop)
      else . end;
    drop
  ' 2>/dev/null | jq -n 'input' -c 2>/dev/null)" || out=""
  if [[ -z "$out" ]]; then
    printf '{}\n'
    return 0
  fi
  printf '%s\n' "$out"
}

# _graph_schedule_retry_context_required_artifacts <graph_json> <node_id>
# Required output/artifact paths from the frozen node contract. Paths only.
_graph_schedule_retry_context_required_artifacts() {
  local graph_json="$1" node_id="$2"
  if [[ -z "$graph_json" || ! -f "$graph_json" || -z "$node_id" ]]; then
    printf '[]\n'
    return 0
  fi
  jq -c --arg id "$node_id" '
    [.nodes[]? | select(.id == $id) | .stage |
      [(.outputArtifacts // [])[], (.artifacts // [])[]] |
      map(if type == "string" then {path:., required:true} else . end)[]? |
      select(.required != false) |
      (.path // empty) |
      select(. != "" and . != "null")
    ] | unique
  ' "$graph_json" 2>/dev/null || printf '[]\n'
}

# _graph_schedule_retry_context_node_identity <graph_json> <node_id>
# Compact identity: nodeId plus runtime/role when present. No todos or prompts.
_graph_schedule_retry_context_node_identity() {
  local graph_json="$1" node_id="$2"
  if [[ -z "$graph_json" || ! -f "$graph_json" || -z "$node_id" ]]; then
    jq -cn --arg id "$node_id" '{nodeId:$id,runtime:"",role:""}'
    return 0
  fi
  jq -c --arg id "$node_id" '
    (.nodes[]? | select(.id == $id) | .stage // {}) as $stage |
    {
      nodeId: $id,
      runtime: (($stage.runtime // "") | tostring),
      role: (($stage.role // "") | tostring)
    }
  ' "$graph_json" 2>/dev/null || jq -cn --arg id "$node_id" '{nodeId:$id,runtime:"",role:""}'
}

# _graph_schedule_retry_context_previous_logs <run_dir> <node_id> <previous_attempt_id>
# Run-dir-relative log path references only. Never reads log bodies.
_graph_schedule_retry_context_previous_logs() {
  local run_dir="$1" node_id="$2" attempt_id="$3" paths
  if [[ -z "$run_dir" || -z "$node_id" || -z "$attempt_id" ]]; then
    printf '{}\n'
    return 0
  fi
  paths="$(graph_logs_attempt_paths_json "$run_dir" "$node_id" "$attempt_id" 2>/dev/null || true)"
  if [[ -z "$paths" ]]; then
    printf '{}\n'
    return 0
  fi
  printf '%s\n' "$paths"
}

# _graph_schedule_retry_context_compact_correction <json_or_path>
# The four compact correction fields only. Prompts and raw output are dropped.
_graph_schedule_retry_context_compact_correction() {
  local loaded component paths_json verify next_n
  loaded="$(_graph_schedule_retry_context_load_json "${1:-}")"
  [[ -n "$loaded" ]] || { printf 'null\n'; return 0; }
  loaded="$(_graph_schedule_retry_context_drop_forbidden "$loaded")"
  component="$(printf '%s' "$loaded" | jq -r '
    (.failedCompletionComponent // .component // .kind // "") | tostring
  ' 2>/dev/null)" || component=""
  if [[ "$component" == "null" ]]; then
    component=""
  fi
  paths_json="$(printf '%s' "$loaded" | jq -c '
    def as_paths:
      if . == null then []
      elif type == "array" then
        [.[] | if type == "string" then .
               elif type == "object" then (.path // .artifact // empty)
               else empty end]
      elif type == "string" and . != "" then [.]
      else [] end;
    ((.offendingPaths | as_paths)
     + (.missingArtifacts | as_paths)
     + (.undeclaredPaths | as_paths)
     + (.outOfScope | as_paths)
     + (.paths | as_paths)
     + ((.missingArtifact // .artifact // "") | as_paths))
    | unique
    | map(select(. != "" and . != "null"))
  ' 2>/dev/null)" || paths_json='[]'
  verify="$(printf '%s' "$loaded" | jq -r '
    (.verificationResultPath // .verificationResult // .verificationResultFile // "") | tostring
  ' 2>/dev/null)" || verify=""
  if [[ "$verify" == "null" ]]; then
    verify=""
  fi
  next_n="$(printf '%s' "$loaded" | jq -r '.nextAttemptNumber // empty' 2>/dev/null)" || next_n=""
  if [[ -z "$component" && "$paths_json" == "[]" && -z "$verify" && -z "$next_n" ]]; then
    printf 'null\n'
    return 0
  fi
  jq -cn --arg c "$component" --argjson p "${paths_json:-[]}" --arg v "$verify" --arg n "$next_n" '
    {
      failedCompletionComponent: $c,
      offendingPaths: $p,
      verificationResultPath: (if $v == "" then null else $v end),
      nextAttemptNumber: (if ($n | test("^[0-9]+$")) then ($n | tonumber) else null end)
    }
  '
}

# _graph_schedule_retry_context_apply_cap <json>
# Enforce GRAPH_SCHEDULE_RETRY_CONTEXT_MAX_BYTES. Shrinks optional arrays/paths
# first; always returns valid JSON and never reintroduces forbidden fields.
_graph_schedule_retry_context_apply_cap() {
  local json="{}" max serialized shrunk
  if [[ -n "${1:-}" ]]; then
    json="$1"
  fi
  max="$(_graph_schedule_retry_context_max_bytes)"
  json="$(_graph_schedule_retry_context_drop_forbidden "$json")"
  serialized="$(printf '%s' "$json" | jq -n 'input' -c 2>/dev/null)" || serialized='{}'
  [[ -n "$serialized" ]] || serialized='{}'
  if [[ "${#serialized}" -le "$max" ]]; then
    printf '%s\n' "$serialized"
    return 0
  fi
  shrunk="$(printf '%s' "$serialized" | jq -c '
    .truncated = true
    | .correction = (if (.correction | type) == "object" then
        {failedCompletionComponent:(.correction.failedCompletionComponent // ""),
         offendingPaths:[],
         verificationResultPath:null,
         nextAttemptNumber:(.correction.nextAttemptNumber // null)}
      else .correction end)
    | .requiredArtifactPaths = ((.requiredArtifactPaths // [])[:2])
  ' 2>/dev/null)" || shrunk="$serialized"
  [[ -n "$shrunk" ]] || shrunk="$serialized"
  if [[ "${#shrunk}" -le "$max" ]]; then
    printf '%s\n' "$shrunk"
    return 0
  fi
  shrunk="$(printf '%s' "$shrunk" | jq -c '
    .previousLogs = {}
    | .requiredArtifactPaths = []
    | .correction = (if (.correction | type) == "object" then
        {failedCompletionComponent:(.correction.failedCompletionComponent // "")}
      else null end)
  ' 2>/dev/null)" || shrunk="$shrunk"
  [[ -n "$shrunk" ]] || shrunk='{"truncated":true}'
  if [[ "${#shrunk}" -le "$max" ]]; then
    printf '%s\n' "$shrunk"
    return 0
  fi
  shrunk="$(printf '%s' "$serialized" | jq -c '
    {nodeId:(.nodeId // ""),attemptNumber:(.attemptNumber // null),
     classification:(.classification // ""),truncated:true}
  ' 2>/dev/null)" || shrunk='{"truncated":true}'
  [[ -n "$shrunk" ]] || shrunk='{"truncated":true}'
  if [[ "${#shrunk}" -le "$max" ]]; then
    printf '%s\n' "$shrunk"
    return 0
  fi
  printf '%s\n' '{"truncated":true}'
}

# graph_schedule_build_retry_context <run_dir> <node_id> [graph_json]
#   [previous_attempt_id] [classification] [correction_json_or_path]
#
# Compact retry prompt/context. Includes node identity, attempt/classification,
# the compact correction record, required artifact paths, and previous log
# path references only. Full prior prompts, transcripts, and log bodies are
# excluded. Output is byte-capped.
graph_schedule_build_retry_context() {
  local run_dir="$1" node_id="$2"
  local graph_json="${3:-${GRAPH_SCHEDULE_GRAPH_JSON:-}}"
  local previous_attempt_id="${4:-}"
  local classification="${5:-}"
  local correction_in="${6:-}"
  local identity artifacts logs correction attempt_n built record

  if [[ -z "$run_dir" || -z "$node_id" ]]; then
    echo "Error: graph_schedule_build_retry_context requires run_dir and node_id" >&2
    return 1
  fi

  if [[ -z "$correction_in" ]]; then
    record="$(graph_schedule_correction_record_path "$run_dir" "$node_id" 2>/dev/null || true)"
    if [[ -n "$record" && -f "$record" ]]; then
      correction_in="$record"
    fi
  fi

  identity="$(_graph_schedule_retry_context_node_identity "$graph_json" "$node_id")"
  artifacts="$(_graph_schedule_retry_context_required_artifacts "$graph_json" "$node_id")"
  logs="$(_graph_schedule_retry_context_previous_logs "$run_dir" "$node_id" "$previous_attempt_id")"
  correction="$(_graph_schedule_retry_context_compact_correction "$correction_in")"
  [[ -n "$artifacts" ]] || artifacts='[]'
  [[ -n "$logs" ]] || logs='{}'
  [[ -n "$correction" ]] || correction='null'
  [[ -n "$identity" ]] || identity="$(jq -cn --arg id "$node_id" '{nodeId:$id,runtime:"",role:""}')"

  attempt_n=""
  if [[ "$correction" != "null" ]]; then
    attempt_n="$(printf '%s' "$correction" | jq -r '.nextAttemptNumber // empty' 2>/dev/null || true)"
  fi
  if [[ ! "$attempt_n" =~ ^[0-9]+$ ]]; then
    attempt_n="$(_graph_schedule_attempt_number_from_id "$previous_attempt_id")"
    if [[ "$attempt_n" =~ ^[0-9]+$ && "$attempt_n" -gt 0 ]]; then
      attempt_n=$((attempt_n + 1))
    fi
  fi
  if [[ ! "$attempt_n" =~ ^[0-9]+$ ]]; then
    attempt_n=0
  fi

  if [[ -z "$classification" && "$correction" != "null" ]]; then
    classification="$(_graph_schedule_correction_component_from_reason \
      "$(printf '%s' "$correction" | jq -r '.failedCompletionComponent // empty')" 2>/dev/null || true)"
    if [[ -z "$classification" ]]; then
      classification="$(graph_failure_map_kind \
        "$(printf '%s' "$correction" | jq -r '.failedCompletionComponent // empty')" 2>/dev/null || true)"
    fi
  fi

  built="$(jq -cn \
    --argjson identity "$identity" \
    --argjson artifacts "$artifacts" \
    --argjson logs "$logs" \
    --argjson correction "$correction" \
    --arg class "$classification" \
    --arg prev "$previous_attempt_id" \
    --arg n "$attempt_n" \
    '
    $identity + {
      attemptNumber: ($n | tonumber),
      previousAttemptId: (if $prev == "" then null else $prev end),
      classification: $class,
      correction: $correction,
      requiredArtifactPaths: $artifacts,
      previousLogs: $logs
    }
    ')" || return 1
  _graph_schedule_retry_context_apply_cap "$built"
}

# graph_schedule_write_retry_context <run_dir> <node_id> [graph_json]
#   [previous_attempt_id] [classification] [correction_json_or_path]
# Writes the compact retry context and prints the contained path.
graph_schedule_write_retry_context() {
  local run_dir="$1" node_id="$2"
  local dest json
  dest="$(graph_schedule_retry_context_path "$run_dir" "$node_id")" || return 1
  json="$(graph_schedule_build_retry_context "$@")" || return 1
  mkdir -p "$(dirname "$dest")" || return 1
  ralph_atomic_write_json "$dest" '$ctx' --argjson ctx "$json" || return 1
  printf '%s\n' "$dest"
}

# _graph_schedule_prepare_retry_context_spawn <node_id> <attempt_number>
# For retry spawns (attempt > 1), write one compact retry-context record and
# remember its path. First attempts leave GRAPH_SCHEDULE_SPAWN_RETRY_CONTEXT
# empty. Does not attach prior prompts or transcripts.
_graph_schedule_prepare_retry_context_spawn() {
  local node_id="$1" attempt_number="$2"
  local run_dir prev_n prev_id class node_file record dest
  GRAPH_SCHEDULE_SPAWN_RETRY_CONTEXT=""
  run_dir="${GRAPH_SCHEDULE_LEDGER_RUN_DIR:-${GRAPH_SCHEDULE_LOG_RUN_DIR:-}}"
  [[ -n "$run_dir" && -n "$node_id" ]] || return 0
  [[ "$attempt_number" =~ ^[1-9][0-9]*$ ]] || return 0
  if [[ "$attempt_number" -lt 2 ]]; then
    return 0
  fi
  prev_n=$((attempt_number - 1))
  prev_id=""
  if [[ -n "${GRAPH_SCHEDULE_RUN_ID:-}" ]] && declare -F graph_dispatch_mint_attempt_id >/dev/null 2>&1; then
    prev_id="$(graph_dispatch_mint_attempt_id "$node_id" "$GRAPH_SCHEDULE_RUN_ID" "$prev_n" 2>/dev/null || true)"
  fi
  class=""
  if [[ -n "${GRAPH_SCHEDULE_WORKSPACE:-}" && -n "${GRAPH_SCHEDULE_LEDGER_NAMESPACE:-}" \
    && -n "${GRAPH_SCHEDULE_RUN_ID:-}" ]]; then
    node_file="$(graph_state_node_file "$GRAPH_SCHEDULE_WORKSPACE" \
      "$GRAPH_SCHEDULE_LEDGER_NAMESPACE" "$GRAPH_SCHEDULE_RUN_ID" "$node_id" 2>/dev/null || true)"
    if [[ -n "$node_file" && -f "$node_file" ]]; then
      class="$(jq -r '.retry.classification // empty' "$node_file" 2>/dev/null || true)"
      if [[ -z "$class" ]]; then
        class="$(jq -r --arg aid "$prev_id" '
          (.attempts // [])
          | (map(select(.attemptId == $aid)) | last // last // {})
          | (.retryClassification // .reason // empty)
        ' "$node_file" 2>/dev/null || true)"
      fi
      if [[ -z "$prev_id" ]]; then
        prev_id="$(jq -r '.lastAttemptId // empty' "$node_file" 2>/dev/null || true)"
      fi
    fi
  fi
  if [[ -n "$class" ]] && ! graph_failure_is_known_class "$class" 2>/dev/null; then
    class="$(graph_failure_map_kind "$class" 2>/dev/null || true)"
  fi
  record=""
  dest="$(graph_schedule_write_retry_context "$run_dir" "$node_id" \
    "${GRAPH_SCHEDULE_GRAPH_JSON:-}" "$prev_id" "$class" "$record" 2>/dev/null || true)"
  [[ -n "$dest" && -f "$dest" ]] || return 0
  GRAPH_SCHEDULE_SPAWN_RETRY_CONTEXT="$dest"
  return 0
}

# _graph_schedule_corrective_failed_attempt_count <node_id>
# Count ledger attempts with outcome=failed. Prints 0 without a node file.
_graph_schedule_corrective_failed_attempt_count() {
  local node_id="$1" node_file count
  count=0
  if [[ -n "${GRAPH_SCHEDULE_WORKSPACE:-}" && -n "${GRAPH_SCHEDULE_LEDGER_NAMESPACE:-}" \
    && -n "${GRAPH_SCHEDULE_RUN_ID:-}" ]]; then
    node_file="$(graph_state_node_file "$GRAPH_SCHEDULE_WORKSPACE" \
      "$GRAPH_SCHEDULE_LEDGER_NAMESPACE" "$GRAPH_SCHEDULE_RUN_ID" "$node_id" 2>/dev/null || true)"
    if [[ -n "$node_file" && -f "$node_file" ]]; then
      count="$(jq '[.attempts[]? | select(.outcome == "failed")] | length' \
        "$node_file" 2>/dev/null)" || count=0
    fi
  fi
  [[ "$count" =~ ^[0-9]+$ ]] || count=0
  printf '%s\n' "$count"
}

# graph_schedule_requeue_corrective_node <run_dir> <node_id> [attempt_id]
# Requeue an agent-correctable node after its failed attempt without deleting
# the isolated workspace. Consumes one retry grant and leaves the prior
# attempt in the ledger. Requires a compact correction record. Prints the
# record path on success.
graph_schedule_requeue_corrective_node() {
  local run_dir="$1" node_id="$2" attempt_id="${3:-}"
  local record idx used failed_n status node_file

  if [[ -z "$run_dir" || -z "$node_id" ]]; then
    echo "Error: graph_schedule_requeue_corrective_node requires run_dir and node_id" >&2
    return 1
  fi
  record="$(graph_schedule_correction_record_path "$run_dir" "$node_id")" || return 1
  if [[ ! -f "$record" ]]; then
    echo "Error: graph_schedule_requeue_corrective_node requires a compact correction record" >&2
    return 1
  fi

  idx=""
  used=0
  if idx="$(graph_schedule_index_map_get "$node_id" 2>/dev/null)"; then
    used="${GRAPH_NODE_CORRECTIVE_RETRIES_USED[$idx]:-0}"
  else
    idx=""
  fi
  [[ "$used" =~ ^[0-9]+$ ]] || used=0
  if [[ "$used" -ge 1 ]]; then
    return 1
  fi

  failed_n="$(_graph_schedule_corrective_failed_attempt_count "$node_id")"
  if [[ "$failed_n" -ge 2 ]]; then
    return 1
  fi
  if [[ -n "${GRAPH_SCHEDULE_WORKSPACE:-}" && -n "${GRAPH_SCHEDULE_LEDGER_NAMESPACE:-}" \
    && -n "${GRAPH_SCHEDULE_RUN_ID:-}" ]]; then
    node_file="$(graph_state_node_file "$GRAPH_SCHEDULE_WORKSPACE" \
      "$GRAPH_SCHEDULE_LEDGER_NAMESPACE" "$GRAPH_SCHEDULE_RUN_ID" "$node_id" 2>/dev/null || true)"
    if [[ -n "$node_file" && -f "$node_file" ]]; then
      status="$(jq -r '.status // empty' "$node_file")"
      if [[ "$status" == "pending" && "$failed_n" -ge 1 ]]; then
        return 1
      fi
    fi
  fi

  # Isolated snapshot/worktree paths stay on disk. graph_workspace_prepare_node
  # reuses a ready workspace; this helper must not archive or rm it.
  if [[ -n "$idx" ]]; then
    GRAPH_NODE_STATES[$idx]="pending"
    GRAPH_NODE_CORRECTIVE_RETRIES_USED[$idx]="1"
  fi

  if [[ -n "${GRAPH_SCHEDULE_LEDGER_RUN_DIR:-}" ]]; then
    _graph_schedule_ledger_record "$node_id" "pending" \
      "" "" "" "" "" "" "" "corrective-retry"
  fi
  echo "graph-schedule: node=$node_id requeued for corrective retry attempt=${attempt_id:-}" >&2
  printf '%s\n' "$record"
}

# _graph_schedule_try_requeue_corrective_node <node_id> <attempt_id>
# After a failed attempt whose correction record was written, requeue in place.
# Returns 0 when requeued so the caller must not apply ordinary failure.
_graph_schedule_try_requeue_corrective_node() {
  local node_id="$1" attempt_id="$2"
  local run_dir
  run_dir="${GRAPH_SCHEDULE_LEDGER_RUN_DIR:-${GRAPH_SCHEDULE_LOG_RUN_DIR:-}}"
  [[ -n "$run_dir" && -d "$run_dir" ]] || return 1
  graph_schedule_requeue_corrective_node "$run_dir" "$node_id" "$attempt_id" >/dev/null 2>&1
}

# _graph_schedule_result_classification [result_json_or_path] [reason]
# Classify a reap report or supervisor reason. Structured report fields win.
# Prints a known classification or empty.
_graph_schedule_result_classification() {
  local result="${1:-}" reason="${2:-}"
  local report="" class=""
  if [[ -n "$result" ]]; then
    if [[ "$result" == \{* || "$result" == \[* ]]; then
      report="$result"
    elif [[ -f "$result" ]]; then
      report="$(cat -- "$result" 2>/dev/null || true)"
    fi
  fi
  if [[ -n "$report" ]]; then
    class="$(graph_failure_classify "$report" 2>/dev/null | jq -r '.classification // empty')"
    if [[ -n "$class" && "$class" != "unknown" ]]; then
      printf '%s\n' "$class"
      return 0
    fi
  fi
  if [[ -n "$reason" ]]; then
    report="$(jq -cn --arg kind "$reason" --arg reason "$reason" \
      '{kind:$kind,reason:$reason,outcome:"failed"}' 2>/dev/null)" || report=""
    if [[ -n "$report" ]]; then
      class="$(graph_failure_classify "$report" 2>/dev/null | jq -r '.classification // empty')"
    fi
  fi
  printf '%s\n' "$class"
}

# _graph_schedule_result_is_plan_contract [result_json_or_path] [reason]
_graph_schedule_result_is_plan_contract() {
  local class
  class="$(_graph_schedule_result_classification "${1:-}" "${2:-}")" || return 1
  [[ "$class" == "plan-contract" ]]
}

# _graph_schedule_result_is_operator_permission [result_json_or_path] [reason]
_graph_schedule_result_is_operator_permission() {
  local class
  class="$(_graph_schedule_result_classification "${1:-}" "${2:-}")" || return 1
  [[ "$class" == "operator-permission" ]]
}

# graph_schedule_ordinary_retry_eligible <class>
# Ordinary retry is only for transient-runtime and agent-correctable.
graph_schedule_ordinary_retry_eligible() {
  case "${1:-}" in
    transient-runtime|agent-correctable) return 0 ;;
    *) return 1 ;;
  esac
}

# graph_schedule_retry_now_epoch
# Honors GRAPH_SCHEDULE_RETRY_NOW_ISO first, then GRAPH_SCHEDULE_RETRY_NOW_EPOCH.
graph_schedule_retry_now_epoch() {
  local from_iso
  if [[ -n "${GRAPH_SCHEDULE_RETRY_NOW_ISO:-}" ]]; then
    from_iso="$(graph_schedule_retry_epoch_from_iso "$GRAPH_SCHEDULE_RETRY_NOW_ISO" 2>/dev/null || true)"
    if [[ "$from_iso" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$from_iso"
      return 0
    fi
  fi
  if [[ -n "${GRAPH_SCHEDULE_RETRY_NOW_EPOCH:-}" && "${GRAPH_SCHEDULE_RETRY_NOW_EPOCH}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$GRAPH_SCHEDULE_RETRY_NOW_EPOCH"
    return 0
  fi
  date +%s
}

# graph_schedule_retry_now_iso
graph_schedule_retry_now_iso() {
  if [[ -n "${GRAPH_SCHEDULE_RETRY_NOW_ISO:-}" ]]; then
    printf '%s\n' "$GRAPH_SCHEDULE_RETRY_NOW_ISO"
    return 0
  fi
  if [[ -n "${GRAPH_SCHEDULE_RETRY_NOW_EPOCH:-}" && "${GRAPH_SCHEDULE_RETRY_NOW_EPOCH}" =~ ^[0-9]+$ ]]; then
    graph_schedule_retry_iso_from_epoch "$GRAPH_SCHEDULE_RETRY_NOW_EPOCH"
    return 0
  fi
  graph_state_now_iso
}

# graph_schedule_retry_iso_from_epoch <epoch>
graph_schedule_retry_iso_from_epoch() {
  local epoch="$1"
  [[ "$epoch" =~ ^[0-9]+$ ]] || return 1
  date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

# graph_schedule_retry_epoch_from_iso <iso>
graph_schedule_retry_epoch_from_iso() {
  local iso="$1"
  [[ -n "$iso" ]] || return 1
  date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null \
    || date -u -d "$iso" +%s 2>/dev/null
}

# graph_schedule_retry_backoff_seconds <retry_ordinal> [backoff_json]
# Deterministic capped exponential backoff. retry_ordinal is 1-based.
# backoff_json is [base] or [base, cap]; the wait never exceeds cap.
graph_schedule_retry_backoff_seconds() {
  local ordinal="${1:-1}" backoff_json="${2:-[2,10]}"
  [[ "$ordinal" =~ ^[1-9][0-9]*$ ]] || ordinal=1
  if ! printf '%s' "$backoff_json" | jq -e 'type == "array" and length >= 1' >/dev/null 2>&1; then
    backoff_json='[2,10]'
  fi
  jq -nr --argjson b "$backoff_json" --argjson n "$ordinal" '
    def to_int: if type == "number" then floor elif type == "string" and test("^[0-9]+$") then tonumber else 0 end;
    ($b[0] // 2 | to_int) as $base
    | ($b[1] // $base | to_int) as $cap
    | (if $n <= 1 then $base
       else reduce range(1; $n) as $_ ($base; . * 2)
       end) as $raw
    | (if $raw < 0 then 0 elif $raw > $cap then $cap else $raw end)
  '
}

# _graph_schedule_node_resilience [node_id]
# Prints the resolved resilience object. Missing graph -> fail-fast zeros.
_graph_schedule_node_resilience() {
  local node_id="${1:-}" graph="${GRAPH_SCHEDULE_GRAPH_JSON:-}" parsed
  if [[ -z "$graph" || ! -f "$graph" ]]; then
    graph_schema_parse_resilience_object "null"
    return 0
  fi
  parsed="$(graph_schema_parse_resilience "$graph" "$node_id" 2>/dev/null)" || parsed=""
  if [[ -z "$parsed" ]]; then
    graph_schema_parse_resilience_object "null"
    return 0
  fi
  printf '%s\n' "$parsed"
}

# _graph_schedule_ordinary_retry_limit <class> [resilience_json]
_graph_schedule_ordinary_retry_limit() {
  local class="$1" resilience="${2:-}"
  [[ -n "$resilience" ]] || resilience="$(_graph_schedule_node_resilience)"
  case "$class" in
    transient-runtime) printf '%s' "$resilience" | jq -r '.transientRetries // 0' ;;
    agent-correctable) printf '%s' "$resilience" | jq -r '.correctiveRetries // 0' ;;
    *) printf '0\n' ;;
  esac
}

# _graph_schedule_retry_used_from_ledger <node_id> <field>
_graph_schedule_retry_used_from_ledger() {
  local node_id="$1" field="$2" node_file count=0
  if [[ -n "${GRAPH_SCHEDULE_WORKSPACE:-}" && -n "${GRAPH_SCHEDULE_LEDGER_NAMESPACE:-}" \
    && -n "${GRAPH_SCHEDULE_RUN_ID:-}" ]]; then
    node_file="$(graph_state_node_file "$GRAPH_SCHEDULE_WORKSPACE" \
      "$GRAPH_SCHEDULE_LEDGER_NAMESPACE" "$GRAPH_SCHEDULE_RUN_ID" "$node_id" 2>/dev/null || true)"
    if [[ -n "$node_file" && -f "$node_file" ]]; then
      count="$(jq -r --arg f "$field" '(.retry[$f] // 0) | tostring' "$node_file" 2>/dev/null)" || count=0
    fi
  fi
  [[ "$count" =~ ^[0-9]+$ ]] || count=0
  printf '%s\n' "$count"
}

# _graph_schedule_ordinary_retry_used <node_id> <class>
_graph_schedule_ordinary_retry_used() {
  local node_id="$1" class="$2" idx used=0 field
  if idx="$(graph_schedule_index_map_get "$node_id" 2>/dev/null)"; then
    case "$class" in
      transient-runtime) used="${GRAPH_NODE_TRANSIENT_RETRIES_USED[$idx]:-0}" ;;
      agent-correctable) used="${GRAPH_NODE_CORRECTIVE_RETRIES_USED[$idx]:-0}" ;;
    esac
  fi
  [[ "$used" =~ ^[0-9]+$ ]] || used=0
  case "$class" in
    transient-runtime) field="transientUsed" ;;
    agent-correctable) field="correctiveUsed" ;;
    *) printf '%s\n' "$used"; return 0 ;;
  esac
  local durable
  durable="$(_graph_schedule_retry_used_from_ledger "$node_id" "$field")"
  if [[ "$durable" =~ ^[0-9]+$ && "$durable" -gt "$used" ]]; then
    used="$durable"
  fi
  printf '%s\n' "$used"
}

# _graph_schedule_set_ordinary_retry_used <node_id> <class> <used>
_graph_schedule_set_ordinary_retry_used() {
  local node_id="$1" class="$2" used="$3" idx
  [[ "$used" =~ ^[0-9]+$ ]] || return 1
  if ! idx="$(graph_schedule_index_map_get "$node_id" 2>/dev/null)"; then
    return 1
  fi
  case "$class" in
    transient-runtime) GRAPH_NODE_TRANSIENT_RETRIES_USED[$idx]="$used" ;;
    agent-correctable) GRAPH_NODE_CORRECTIVE_RETRIES_USED[$idx]="$used" ;;
    *) return 1 ;;
  esac
  return 0
}

# _graph_schedule_retry_extra_json <class> <ordinal> <used_transient> <used_corrective> <backoff> <scheduled_at> <retry_at>
_graph_schedule_retry_extra_json() {
  local class="$1" ordinal="$2" used_t="$3" used_c="$4" backoff="$5"
  local scheduled_at="$6" retry_at="$7"
  jq -nc \
    --arg classification "$class" \
    --arg ordinal "$ordinal" \
    --arg usedT "$used_t" \
    --arg usedC "$used_c" \
    --arg backoff "$backoff" \
    --arg scheduledAt "$scheduled_at" \
    --arg retryAt "$retry_at" \
    '{
      retry: {
        classification: $classification,
        retryOrdinal: ($ordinal | tonumber),
        scheduledAt: $scheduledAt,
        retryAt: $retryAt,
        backoffSeconds: ($backoff | tonumber),
        transientUsed: ($usedT | tonumber),
        correctiveUsed: ($usedC | tonumber)
      }
    }'
}

# graph_schedule_release_due_retry_waits
# Move retry-wait nodes whose retryAt has elapsed to pending. Does not spawn.
graph_schedule_release_due_retry_waits() {
  local i node_id node_file retry_at retry_epoch now extra used_t used_c
  now="$(graph_schedule_retry_now_epoch)"
  for ((i = 0; i < ${#GRAPH_NODE_IDS[@]}; i++)); do
    [[ "${GRAPH_NODE_STATES[$i]:-}" == "retry-wait" ]] || continue
    node_id="${GRAPH_NODE_IDS[$i]}"
    retry_at=""
    if [[ -n "${GRAPH_SCHEDULE_WORKSPACE:-}" && -n "${GRAPH_SCHEDULE_LEDGER_NAMESPACE:-}" \
      && -n "${GRAPH_SCHEDULE_RUN_ID:-}" ]]; then
      node_file="$(graph_state_node_file "$GRAPH_SCHEDULE_WORKSPACE" \
        "$GRAPH_SCHEDULE_LEDGER_NAMESPACE" "$GRAPH_SCHEDULE_RUN_ID" "$node_id" 2>/dev/null || true)"
      if [[ -n "$node_file" && -f "$node_file" ]]; then
        retry_at="$(jq -r '.retry.retryAt // empty' "$node_file" 2>/dev/null)" || retry_at=""
      fi
    fi
    if [[ -n "$retry_at" ]]; then
      retry_epoch="$(graph_schedule_retry_epoch_from_iso "$retry_at" 2>/dev/null || true)"
      if [[ "$retry_epoch" =~ ^[0-9]+$ && "$retry_epoch" -gt "$now" ]]; then
        continue
      fi
    fi
    GRAPH_NODE_STATES[$i]="pending"
    used_t="${GRAPH_NODE_TRANSIENT_RETRIES_USED[$i]:-0}"
    used_c="${GRAPH_NODE_CORRECTIVE_RETRIES_USED[$i]:-0}"
    extra=""
    if [[ -n "${node_file:-}" && -f "${node_file:-}" ]]; then
      extra="$(jq -c --arg t "$used_t" --arg c "$used_c" \
        '{retry: ((.retry // {}) + {transientUsed:($t|tonumber),correctiveUsed:($c|tonumber)})}' \
        "$node_file" 2>/dev/null)" || extra=""
    fi
    if [[ -z "$extra" ]]; then
      extra="$(jq -nc --arg t "$used_t" --arg c "$used_c" \
        '{retry:{transientUsed:($t|tonumber),correctiveUsed:($c|tonumber)}}')"
    fi
    if [[ -n "${GRAPH_SCHEDULE_LEDGER_RUN_DIR:-}" ]]; then
      _graph_schedule_ledger_record "$node_id" "pending" \
        "" "" "" "" "" "" "" "retry-wait-elapsed" "$extra"
    fi
    echo "graph-schedule: node=$node_id retry-wait elapsed; requeued" >&2
  done
  return 0
}

# graph_schedule_earliest_retry_wait_epoch
# Prints the earliest future-or-due retryAt epoch, or returns 1 when none.
graph_schedule_earliest_retry_wait_epoch() {
  local i node_id node_file retry_at retry_epoch earliest=""
  for ((i = 0; i < ${#GRAPH_NODE_IDS[@]}; i++)); do
    [[ "${GRAPH_NODE_STATES[$i]:-}" == "retry-wait" ]] || continue
    node_id="${GRAPH_NODE_IDS[$i]}"
    retry_at=""
    if [[ -n "${GRAPH_SCHEDULE_WORKSPACE:-}" && -n "${GRAPH_SCHEDULE_LEDGER_NAMESPACE:-}" \
      && -n "${GRAPH_SCHEDULE_RUN_ID:-}" ]]; then
      node_file="$(graph_state_node_file "$GRAPH_SCHEDULE_WORKSPACE" \
        "$GRAPH_SCHEDULE_LEDGER_NAMESPACE" "$GRAPH_SCHEDULE_RUN_ID" "$node_id" 2>/dev/null || true)"
      if [[ -n "$node_file" && -f "$node_file" ]]; then
        retry_at="$(jq -r '.retry.retryAt // empty' "$node_file" 2>/dev/null)" || retry_at=""
      fi
    fi
    retry_epoch=""
    if [[ -n "$retry_at" ]]; then
      retry_epoch="$(graph_schedule_retry_epoch_from_iso "$retry_at" 2>/dev/null || true)"
    fi
    [[ "$retry_epoch" =~ ^[0-9]+$ ]] || retry_epoch="$(graph_schedule_retry_now_epoch)"
    if [[ -z "$earliest" || "$retry_epoch" -lt "$earliest" ]]; then
      earliest="$retry_epoch"
    fi
  done
  [[ -n "$earliest" ]] || return 1
  printf '%s\n' "$earliest"
}

# _graph_schedule_sleep_for_retry_wait
# Returns 0 when the caller should continue the loop.
_graph_schedule_sleep_for_retry_wait() {
  local earliest now delay
  graph_schedule_release_due_retry_waits
  earliest="$(graph_schedule_earliest_retry_wait_epoch 2>/dev/null || true)"
  [[ "$earliest" =~ ^[0-9]+$ ]] || return 1
  now="$(graph_schedule_retry_now_epoch)"
  if [[ "$earliest" -le "$now" ]]; then
    graph_schedule_release_due_retry_waits
    return 0
  fi
  if [[ -n "${GRAPH_SCHEDULE_RETRY_NOW_EPOCH:-}" || "${GRAPH_SCHEDULE_RETRY_SKIP_SLEEP:-0}" == "1" ]]; then
    return 1
  fi
  delay=$((earliest - now))
  [[ "$delay" -lt 1 ]] && delay=1
  if [[ "${GRAPH_SCHEDULE_RETRY_SLEEP_CAP:-}" =~ ^[1-9][0-9]*$ ]] && [[ "$delay" -gt "$GRAPH_SCHEDULE_RETRY_SLEEP_CAP" ]]; then
    delay="$GRAPH_SCHEDULE_RETRY_SLEEP_CAP"
  fi
  sleep "$delay"
  return 0
}

# _graph_schedule_restore_retry_counters
# Reload durable ordinary-retry counters after resume reconcile.
_graph_schedule_restore_retry_counters() {
  local i node_id used_t used_c
  for ((i = 0; i < ${#GRAPH_NODE_IDS[@]}; i++)); do
    node_id="${GRAPH_NODE_IDS[$i]}"
    used_t="$(_graph_schedule_retry_used_from_ledger "$node_id" "transientUsed")"
    used_c="$(_graph_schedule_retry_used_from_ledger "$node_id" "correctiveUsed")"
    GRAPH_NODE_TRANSIENT_RETRIES_USED[$i]="$used_t"
    if [[ "$used_c" =~ ^[1-9][0-9]*$ ]]; then
      GRAPH_NODE_CORRECTIVE_RETRIES_USED[$i]="$used_c"
    fi
  done
}

# graph_schedule_try_ordinary_retry <node_id> <exit_code> [reason] [attempt_id] [result]
# Persist retry-wait with deterministic capped backoff when the classified
# result is transient-runtime or agent-correctable and a configured retry
# remains. Returns 0 when a retry was granted. Operator, plan-contract,
# configuration, integrity, cancelled, and unknown never enter this path.
graph_schedule_try_ordinary_retry() {
  local node_id="$1" exit_code="$2" reason="${3:-}" attempt_id="${4:-}" result="${5:-}"
  local class resilience limit used next_used backoff now_epoch retry_at scheduled_at
  local extra idx used_t used_c ordinal

  [[ -n "$node_id" ]] || return 1
  class="$(_graph_schedule_result_classification "$result" "$reason")"
  graph_schedule_ordinary_retry_eligible "$class" || return 1

  resilience="$(_graph_schedule_node_resilience "$node_id")"
  limit="$(_graph_schedule_ordinary_retry_limit "$class" "$resilience")"
  [[ "$limit" =~ ^[0-9]+$ ]] || limit=0
  [[ "$limit" -gt 0 ]] || return 1

  used="$(_graph_schedule_ordinary_retry_used "$node_id" "$class")"
  [[ "$used" =~ ^[0-9]+$ ]] || used=0
  if [[ "$used" -ge "$limit" ]]; then
    return 1
  fi
  graph_schedule_commit_active_time "$node_id" || true
  if graph_schedule_active_time_exhausted "$node_id"; then
    graph_schedule_apply_active_time_exhaustion "$node_id" "$attempt_id" || true
    return 1
  fi
  if [[ -n "$attempt_id" ]]; then
    graph_schedule_record_attempt_usage "$node_id" "$attempt_id" || true
  fi
  if graph_schedule_usage_should_stop "$node_id"; then
    graph_schedule_apply_usage_exhaustion "$node_id" "$attempt_id" || true
    return 1
  fi

  next_used=$((used + 1))
  ordinal="$next_used"
  backoff="$(graph_schedule_retry_backoff_seconds "$ordinal" \
    "$(printf '%s' "$resilience" | jq -c '.backoffSeconds // [2,10]')")"
  [[ "$backoff" =~ ^[0-9]+$ ]] || backoff=0

  _graph_schedule_set_ordinary_retry_used "$node_id" "$class" "$next_used" || return 1
  if ! idx="$(graph_schedule_index_map_get "$node_id" 2>/dev/null)"; then
    return 1
  fi

  used_t="${GRAPH_NODE_TRANSIENT_RETRIES_USED[$idx]:-0}"
  used_c="${GRAPH_NODE_CORRECTIVE_RETRIES_USED[$idx]:-0}"
  now_epoch="$(graph_schedule_retry_now_epoch)"
  scheduled_at="$(graph_schedule_retry_now_iso)"
  retry_at="$(graph_schedule_retry_iso_from_epoch "$((now_epoch + backoff))")"
  [[ -n "$retry_at" ]] || retry_at="$scheduled_at"
  extra="$(_graph_schedule_retry_extra_json "$class" "$ordinal" "$used_t" "$used_c" \
    "$backoff" "$scheduled_at" "$retry_at")"

  GRAPH_NODE_STATES[$idx]="retry-wait"
  if [[ -n "${GRAPH_SCHEDULE_LEDGER_RUN_DIR:-}" ]]; then
    _graph_schedule_ledger_record "$node_id" "retry-wait" \
      "$attempt_id" "" "" "" "" "" "" "retry-wait:$class" "$extra"
  fi
  graph_ui_node "retry-wait" "$node_id" "class=$class ordinal=$ordinal backoff=${backoff}s"
  echo "graph-schedule: node=$node_id retry-wait class=$class ordinal=$ordinal backoff=${backoff}s retryAt=$retry_at" >&2

  if [[ "$backoff" -eq 0 ]]; then
    graph_schedule_release_due_retry_waits
  fi
  return 0
}

# graph_schedule_active_now_epoch
# Frozen-time helper shared with retry tests: GRAPH_SCHEDULE_RETRY_NOW_ISO,
# then GRAPH_SCHEDULE_RETRY_NOW_EPOCH, then GRAPH_HEARTBEAT_NOW_EPOCH.
graph_schedule_active_now_epoch() {
  local from_iso
  if [[ -n "${GRAPH_SCHEDULE_RETRY_NOW_ISO:-}" ]]; then
    from_iso="$(graph_schedule_retry_epoch_from_iso "$GRAPH_SCHEDULE_RETRY_NOW_ISO" 2>/dev/null || true)"
    if [[ "$from_iso" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$from_iso"
      return 0
    fi
  fi
  if [[ -n "${GRAPH_SCHEDULE_RETRY_NOW_EPOCH:-}" && "${GRAPH_SCHEDULE_RETRY_NOW_EPOCH}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$GRAPH_SCHEDULE_RETRY_NOW_EPOCH"
    return 0
  fi
  if [[ -n "${GRAPH_HEARTBEAT_NOW_EPOCH:-}" && "${GRAPH_HEARTBEAT_NOW_EPOCH}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$GRAPH_HEARTBEAT_NOW_EPOCH"
    return 0
  fi
  date +%s
}

# graph_schedule_active_now_iso
graph_schedule_active_now_iso() {
  if [[ -n "${GRAPH_SCHEDULE_RETRY_NOW_ISO:-}" ]]; then
    printf '%s\n' "$GRAPH_SCHEDULE_RETRY_NOW_ISO"
    return 0
  fi
  graph_schedule_retry_iso_from_epoch "$(graph_schedule_active_now_epoch)"
}

# _graph_schedule_node_budgets [node_id]
# Prints the resolved budgets object. Missing graph -> all-null ceilings.
_graph_schedule_node_budgets() {
  local node_id="${1:-}" graph="${GRAPH_SCHEDULE_GRAPH_JSON:-}" parsed
  if [[ -z "$graph" || ! -f "$graph" ]]; then
    graph_schema_parse_budgets_object "null"
    return 0
  fi
  parsed="$(graph_schema_parse_budgets "$graph" "$node_id" 2>/dev/null)" || parsed=""
  if [[ -z "$parsed" ]]; then
    graph_schema_parse_budgets_object "null"
    return 0
  fi
  printf '%s\n' "$parsed"
}

# _graph_schedule_budget_nonneg_limit <budgets_json> <field>
# Prints the integer limit or empty when the field is null/absent.
_graph_schedule_budget_nonneg_limit() {
  local json="$1" field="$2" val
  val="$(printf '%s' "$json" | jq -r --arg f "$field" '.[$f] // empty' 2>/dev/null)" || val=""
  if [[ "$val" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$val"
    return 0
  fi
  printf '\n'
}

# _graph_schedule_empty_usage_json
# Unavailable aggregate. Missing usage is not represented as zero.
_graph_schedule_empty_usage_json() {
  # Compile-time constant: emit directly instead of forking jq to render a
  # fixed literal (26 of 683 jq forks in a five-node scheduler test).
  printf '%s\n' '{"inputTokens":null,"outputTokens":null,"cacheReadTokens":null,"cacheWriteTokens":null,"estimatedCostUsd":null,"reliability":"unavailable","missingAttempts":0,"countedAttemptIds":[],"warned":false}'
}

# _graph_schedule_node_usage_stored <node_id>
# Prints the in-memory usage aggregate, or the empty unavailable object.
_graph_schedule_node_usage_stored() {
  local node_id="$1" idx usage=""
  if idx="$(graph_schedule_index_map_get "$node_id" 2>/dev/null)"; then
    usage="${GRAPH_NODE_USAGE_JSON[$idx]:-}"
  fi
  if [[ -n "$usage" ]] && printf '%s' "$usage" | jq -e . >/dev/null 2>&1; then
    printf '%s\n' "$usage"
    return 0
  fi
  _graph_schedule_empty_usage_json
}

# _graph_schedule_budget_extra_json <node_id>
# Compact persistable clock: committed seconds plus optional open start.
# Also carries the usage aggregate so resume cannot double-count attempts.
_graph_schedule_budget_extra_json() {
  local node_id="$1" idx committed=0 started="" usage=""
  if idx="$(graph_schedule_index_map_get "$node_id" 2>/dev/null)"; then
    committed="${GRAPH_NODE_ACTIVE_SECONDS[$idx]:-0}"
    started="${GRAPH_NODE_ACTIVE_STARTED_AT[$idx]:-}"
    usage="${GRAPH_NODE_USAGE_JSON[$idx]:-}"
  fi
  [[ "$committed" =~ ^[0-9]+$ ]] || committed=0
  if [[ -z "$usage" ]] || ! printf '%s' "$usage" | jq -e . >/dev/null 2>&1; then
    usage="$(_graph_schedule_empty_usage_json)"
  fi
  jq -nc --arg sec "$committed" --arg started "$started" --argjson usage "$usage" '{
    budget: {
      activeSeconds: ($sec | tonumber),
      activeStartedAt: (if $started == "" then null else $started end),
      usage: $usage
    }
  }'
}

# _graph_schedule_persist_budget_fields <node_id> [extra_json]
# Merge budget into the node ledger without a state transition so resume can
# reload committed seconds after failed/awaiting/retry-wait writes.
_graph_schedule_persist_budget_fields() {
  local node_id="$1" extra="${2:-}" node_file base
  [[ -n "$node_id" ]] || return 1
  [[ -n "${GRAPH_SCHEDULE_WORKSPACE:-}" && -n "${GRAPH_SCHEDULE_LEDGER_NAMESPACE:-}" \
    && -n "${GRAPH_SCHEDULE_RUN_ID:-}" ]] || return 0
  if [[ -z "$extra" ]]; then
    extra="$(_graph_schedule_budget_extra_json "$node_id")"
  fi
  if ! printf '%s' "$extra" | jq -e . >/dev/null 2>&1; then
    return 1
  fi
  node_file="$(graph_state_node_file "$GRAPH_SCHEDULE_WORKSPACE" \
    "$GRAPH_SCHEDULE_LEDGER_NAMESPACE" "$GRAPH_SCHEDULE_RUN_ID" "$node_id" 2>/dev/null || true)"
  [[ -n "$node_file" && -f "$node_file" ]] || return 0
  base="$(jq -c . "$node_file" 2>/dev/null)" || return 0
  ralph_atomic_write_json "$node_file" \
    '($base | fromjson) as $doc
     | $doc + {budget: (($doc.budget // {}) + ($extra.budget // {}))}' \
    --arg base "$base" \
    --argjson extra "$extra" >/dev/null 2>&1 || return 1
  return 0
}

# _graph_schedule_merge_ledger_extra <extra_json> <budget_json>
# Deep-merges budget so caller fields (exhausted, classification) win.
_graph_schedule_merge_ledger_extra() {
  # Not "${1:-{}}" / "${2:-{}}" -- bash's brace-depth scan for that default
  # closes the parameter expansion one brace early, so whenever $1 or $2 is
  # actually provided its value comes through with a stray extra "}"
  # appended (verified: a provided '{"operatorRequestId":"x"}' becomes
  # '{"operatorRequestId":"x"}}'). jq then fails to parse it, silently
  # falling back to "{}" and dropping the caller's fields. See
  # graph-consensus.sh graph_consensus_run_join for the same pitfall.
  local extra="${1:-}" budget="${2:-}"
  [[ -n "$extra" ]] || extra='{}'
  [[ -n "$budget" ]] || budget='{}'
  [[ -n "$extra" && "$extra" != "null" ]] || extra='{}'
  [[ -n "$budget" && "$budget" != "null" ]] || budget='{}'
  if ! printf '%s' "$extra" | jq -e . >/dev/null 2>&1; then
    extra='{}'
  fi
  if ! printf '%s' "$budget" | jq -e . >/dev/null 2>&1; then
    printf '%s\n' "$extra"
    return 0
  fi
  jq -nc --argjson extra "$extra" --argjson budget "$budget" '
    ($budget + $extra)
    | .budget = (($budget.budget // {}) + ($extra.budget // {}))
  '
}

# graph_schedule_node_active_seconds <node_id>
# Committed seconds plus the open running clock. Waits are not on the clock.
graph_schedule_node_active_seconds() {
  local node_id="$1" idx committed=0 started="" now start_epoch elapsed=0
  if idx="$(graph_schedule_index_map_get "$node_id" 2>/dev/null)"; then
    committed="${GRAPH_NODE_ACTIVE_SECONDS[$idx]:-0}"
    started="${GRAPH_NODE_ACTIVE_STARTED_AT[$idx]:-}"
  fi
  [[ "$committed" =~ ^[0-9]+$ ]] || committed=0
  if [[ -n "$started" ]]; then
    start_epoch="$(graph_schedule_retry_epoch_from_iso "$started" 2>/dev/null || true)"
    now="$(graph_schedule_active_now_epoch)"
    if [[ "$start_epoch" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ && "$now" -ge "$start_epoch" ]]; then
      elapsed=$((now - start_epoch))
    fi
  fi
  printf '%s\n' "$((committed + elapsed))"
}

# graph_schedule_run_active_seconds
graph_schedule_run_active_seconds() {
  local i total=0 n
  for ((i = 0; i < ${#GRAPH_NODE_IDS[@]}; i++)); do
    n="$(graph_schedule_node_active_seconds "${GRAPH_NODE_IDS[$i]}")"
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    total=$((total + n))
  done
  printf '%s\n' "$total"
}

# graph_schedule_start_active_clock <node_id> [started_iso]
# Idempotent: an already-open clock is left alone so resume cannot double-count.
graph_schedule_start_active_clock() {
  local node_id="$1" started_at="${2:-}" idx
  [[ -n "$node_id" ]] || return 1
  if ! idx="$(graph_schedule_index_map_get "$node_id" 2>/dev/null)"; then
    return 1
  fi
  if [[ -n "${GRAPH_NODE_ACTIVE_STARTED_AT[$idx]:-}" ]]; then
    return 0
  fi
  [[ -n "$started_at" ]] || started_at="$(graph_schedule_active_now_iso)"
  GRAPH_NODE_ACTIVE_STARTED_AT[$idx]="$started_at"
  _graph_schedule_persist_budget_fields "$node_id" || true
  return 0
}

# graph_schedule_commit_active_time <node_id>
# Fold the open clock into committed seconds and pause. No-op without a clock,
# so operator/checkpoint/retry-wait periods are not charged.
graph_schedule_commit_active_time() {
  local node_id="$1" idx started="" start_epoch now elapsed=0 committed=0
  [[ -n "$node_id" ]] || return 1
  if ! idx="$(graph_schedule_index_map_get "$node_id" 2>/dev/null)"; then
    return 1
  fi
  started="${GRAPH_NODE_ACTIVE_STARTED_AT[$idx]:-}"
  [[ -n "$started" ]] || return 0
  start_epoch="$(graph_schedule_retry_epoch_from_iso "$started" 2>/dev/null || true)"
  now="$(graph_schedule_active_now_epoch)"
  if [[ "$start_epoch" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ && "$now" -ge "$start_epoch" ]]; then
    elapsed=$((now - start_epoch))
  fi
  committed="${GRAPH_NODE_ACTIVE_SECONDS[$idx]:-0}"
  [[ "$committed" =~ ^[0-9]+$ ]] || committed=0
  GRAPH_NODE_ACTIVE_SECONDS[$idx]="$((committed + elapsed))"
  GRAPH_NODE_ACTIVE_STARTED_AT[$idx]=""
  _graph_schedule_persist_budget_fields "$node_id" || true
  return 0
}

# graph_schedule_pause_active_clock <node_id>
# Alias for commit: stop charging across operator/checkpoint/backoff waits.
graph_schedule_pause_active_clock() {
  graph_schedule_commit_active_time "$@"
}

# graph_schedule_active_time_exhausted [node_id]
# True when the node or run committed+open active time meets a configured limit.
# Null ceilings never exhaust.
graph_schedule_active_time_exhausted() {
  local node_id="${1:-}" budgets limit used run_limit run_used
  if [[ -n "$node_id" ]]; then
    budgets="$(_graph_schedule_node_budgets "$node_id")"
    limit="$(_graph_schedule_budget_nonneg_limit "$budgets" "maxActiveSeconds")"
    if [[ "$limit" =~ ^[0-9]+$ ]]; then
      used="$(graph_schedule_node_active_seconds "$node_id")"
      if [[ "$used" =~ ^[0-9]+$ && "$used" -ge "$limit" ]]; then
        return 0
      fi
    fi
  fi
  run_limit="$(_graph_schedule_budget_nonneg_limit "$(_graph_schedule_node_budgets)" "maxRunActiveSeconds")"
  if [[ "$run_limit" =~ ^[0-9]+$ ]]; then
    run_used="$(graph_schedule_run_active_seconds)"
    if [[ "$run_used" =~ ^[0-9]+$ && "$run_used" -ge "$run_limit" ]]; then
      return 0
    fi
  fi
  return 1
}

# _graph_schedule_restore_active_time
# Reload committed seconds and any open clock after resume reconcile.
_graph_schedule_restore_active_time() {
  local i node_id node_file sec started
  for ((i = 0; i < ${#GRAPH_NODE_IDS[@]}; i++)); do
    node_id="${GRAPH_NODE_IDS[$i]}"
    sec=0
    started=""
    if [[ -n "${GRAPH_SCHEDULE_WORKSPACE:-}" && -n "${GRAPH_SCHEDULE_LEDGER_NAMESPACE:-}" \
      && -n "${GRAPH_SCHEDULE_RUN_ID:-}" ]]; then
      node_file="$(graph_state_node_file "$GRAPH_SCHEDULE_WORKSPACE" \
        "$GRAPH_SCHEDULE_LEDGER_NAMESPACE" "$GRAPH_SCHEDULE_RUN_ID" "$node_id" 2>/dev/null || true)"
      if [[ -n "$node_file" && -f "$node_file" ]]; then
        sec="$(jq -r '.budget.activeSeconds // 0' "$node_file" 2>/dev/null)" || sec=0
        started="$(jq -r '.budget.activeStartedAt // empty' "$node_file" 2>/dev/null)" || started=""
      fi
    fi
    [[ "$sec" =~ ^[0-9]+$ ]] || sec=0
    [[ "$started" == "null" ]] && started=""
    GRAPH_NODE_ACTIVE_SECONDS[$i]="$sec"
    GRAPH_NODE_ACTIVE_STARTED_AT[$i]="$started"
  done
  _graph_schedule_restore_usage
}

# _graph_schedule_restore_usage
# Reload persisted usage aggregates so resume cannot double-count attempts.
_graph_schedule_restore_usage() {
  local i node_id node_file usage=""
  for ((i = 0; i < ${#GRAPH_NODE_IDS[@]}; i++)); do
    usage=""
    node_id="${GRAPH_NODE_IDS[$i]}"
    if [[ -n "${GRAPH_SCHEDULE_WORKSPACE:-}" && -n "${GRAPH_SCHEDULE_LEDGER_NAMESPACE:-}" \
      && -n "${GRAPH_SCHEDULE_RUN_ID:-}" ]]; then
      node_file="$(graph_state_node_file "$GRAPH_SCHEDULE_WORKSPACE" \
        "$GRAPH_SCHEDULE_LEDGER_NAMESPACE" "$GRAPH_SCHEDULE_RUN_ID" "$node_id" 2>/dev/null || true)"
      if [[ -n "$node_file" && -f "$node_file" ]]; then
        usage="$(jq -c '.budget.usage // empty' "$node_file" 2>/dev/null)" || usage=""
      fi
    fi
    [[ "$usage" == "null" ]] && usage=""
    if [[ -n "$usage" ]] && printf '%s' "$usage" | jq -e . >/dev/null 2>&1; then
      GRAPH_NODE_USAGE_JSON[$i]="$usage"
    else
      GRAPH_NODE_USAGE_JSON[$i]=""
    fi
  done
}

# graph_schedule_apply_active_time_exhaustion <node_id> [attempt_id]
# Classify a budget-exhausted report, persist the clock, emit budget-exhausted,
# and terminalize. Does not enter ordinary retry.
graph_schedule_apply_active_time_exhaustion() {
  local node_id="$1" attempt_id="${2:-}" idx report classified class summary extra
  local used limit budgets scope="maxActiveSeconds" runtime="" node_file already=""
  local node_limit run_limit
  [[ -n "$node_id" ]] || return 1
  if ! idx="$(graph_schedule_index_map_get "$node_id" 2>/dev/null)"; then
    return 1
  fi
  graph_schedule_commit_active_time "$node_id" || true
  if [[ -n "${GRAPH_SCHEDULE_WORKSPACE:-}" && -n "${GRAPH_SCHEDULE_LEDGER_NAMESPACE:-}" \
    && -n "${GRAPH_SCHEDULE_RUN_ID:-}" ]]; then
    node_file="$(graph_state_node_file "$GRAPH_SCHEDULE_WORKSPACE" \
      "$GRAPH_SCHEDULE_LEDGER_NAMESPACE" "$GRAPH_SCHEDULE_RUN_ID" "$node_id" 2>/dev/null || true)"
    if [[ -n "$node_file" && -f "$node_file" ]]; then
      already="$(jq -r '.budget.exhausted // false' "$node_file" 2>/dev/null)" || already=""
    fi
  fi
  used="$(graph_schedule_node_active_seconds "$node_id")"
  [[ "$used" =~ ^[0-9]+$ ]] || used=0
  budgets="$(_graph_schedule_node_budgets "$node_id")"
  node_limit="$(_graph_schedule_budget_nonneg_limit "$budgets" "maxActiveSeconds")"
  run_limit="$(_graph_schedule_budget_nonneg_limit "$(_graph_schedule_node_budgets)" "maxRunActiveSeconds")"
  if [[ "$node_limit" =~ ^[0-9]+$ && "$used" -ge "$node_limit" ]]; then
    scope="maxActiveSeconds"
    limit="$node_limit"
  elif [[ "$run_limit" =~ ^[0-9]+$ ]]; then
    scope="maxRunActiveSeconds"
    limit="$run_limit"
    used="$(graph_schedule_run_active_seconds)"
    [[ "$used" =~ ^[0-9]+$ ]] || used=0
  else
    limit="${node_limit:-0}"
  fi
  [[ "$limit" =~ ^[0-9]+$ ]] || limit=0
  report="$(jq -nc --arg used "$used" --arg limit "$limit" --arg scope "$scope" '{
    class: "terminal-configuration",
    kind: "configuration",
    reason: "budget-exhausted",
    outcome: "failed",
    summary: ("active-time budget exhausted (" + $scope + " " + $used + "/" + $limit + ")"),
    budget: $scope,
    activeSeconds: ($used | tonumber),
    limit: ($limit | tonumber)
  }')"
  classified="$(graph_failure_classify "$report" 2>/dev/null)" || classified=""
  class="$(printf '%s' "$classified" | jq -r '.classification // "terminal-configuration"' 2>/dev/null)" || class="terminal-configuration"
  summary="$(printf '%s' "$classified" | jq -r '.summary // empty' 2>/dev/null)" || summary=""
  [[ -n "$class" && "$class" != "null" ]] || class="terminal-configuration"
  extra="$(jq -nc --argjson budget "$(_graph_schedule_budget_extra_json "$node_id")" \
    --arg class "$class" --arg scope "$scope" --arg used "$used" --arg limit "$limit" \
    '$budget + {budget: ($budget.budget + {
      exhausted: true,
      scope: $scope,
      limit: ($limit | tonumber),
      classification: $class,
      activeSeconds: ($used | tonumber)
    })}')"
  _graph_schedule_persist_budget_fields "$node_id" "$extra" || true
  runtime="${GRAPH_NODE_RUNTIMES[$idx]:-}"
  if [[ "$already" != "true" ]]; then
    case "${GRAPH_NODE_STATES[$idx]:-}" in
      failed)
        ;;
      running)
        GRAPH_NODE_STATES[$idx]="failed"
        if [[ -n "${GRAPH_SCHEDULE_LEDGER_RUN_DIR:-}" ]]; then
          _graph_schedule_ledger_record "$node_id" "failed" \
            "$attempt_id" "failed" "1" "" "$(graph_schedule_active_now_iso)" \
            "$runtime" "" "budget-exhausted" "$extra"
        fi
        _graph_schedule_runtime_release "$node_id" || true
        ;;
      *)
        if [[ "${GRAPH_NODE_STATES[$idx]:-}" != "running" ]]; then
          GRAPH_NODE_STATES[$idx]="running"
          if [[ -n "${GRAPH_SCHEDULE_LEDGER_RUN_DIR:-}" ]]; then
            _graph_schedule_ledger_record "$node_id" "running" \
              "$attempt_id" "" "" "$(graph_schedule_active_now_iso)" "" \
              "$runtime" "" "budget-exhausted" "$extra" 2>/dev/null || true
          fi
        fi
        GRAPH_NODE_STATES[$idx]="failed"
        if [[ -n "${GRAPH_SCHEDULE_LEDGER_RUN_DIR:-}" ]]; then
          _graph_schedule_ledger_record "$node_id" "failed" \
            "$attempt_id" "failed" "1" "" "$(graph_schedule_active_now_iso)" \
            "$runtime" "" "budget-exhausted" "$extra"
        fi
        ;;
    esac
    _graph_schedule_log_observability "budget-exhausted" "$node_id" "$attempt_id" \
      "$runtime" "" "$(jq -nc --arg class "$class" --arg scope "$scope" \
        --arg used "$used" --arg limit "$limit" --arg summary "$summary" '{
          budget: $scope,
          activeSeconds: ($used | tonumber),
          limit: ($limit | tonumber),
          classification: $class,
          retryable: false,
          summary: $summary
        }')"
  fi
  _graph_schedule_apply_node_failure "$node_id" 1 "budget-exhausted"
  echo "graph-schedule: node=$node_id budget-exhausted scope=$scope used=$used limit=$limit class=$class" >&2
  return 0
}

# graph_schedule_enforce_active_time_budgets
# Check running nodes (and pending dispatch via callers). Terminalizes through
# the classifier when a configured active-time ceiling is reached.
graph_schedule_enforce_active_time_budgets() {
  local i node_id attempt_id
  for ((i = 0; i < ${#GRAPH_NODE_IDS[@]}; i++)); do
    [[ "${GRAPH_NODE_STATES[$i]:-}" == "running" ]] || continue
    node_id="${GRAPH_NODE_IDS[$i]}"
    graph_schedule_active_time_exhausted "$node_id" || continue
    attempt_id=""
    if [[ -n "${GRAPH_SCHEDULE_WORKSPACE:-}" && -n "${GRAPH_SCHEDULE_LEDGER_NAMESPACE:-}" \
      && -n "${GRAPH_SCHEDULE_RUN_ID:-}" ]]; then
      attempt_id="$(graph_state_node_last_attempt_id "$GRAPH_SCHEDULE_WORKSPACE" \
        "$GRAPH_SCHEDULE_LEDGER_NAMESPACE" "$GRAPH_SCHEDULE_RUN_ID" "$node_id" 2>/dev/null || true)"
    fi
    graph_schedule_apply_active_time_exhaustion "$node_id" "$attempt_id"
  done
  return 0
}

# _graph_schedule_budget_nonneg_number <budgets_json> <field>
# Prints a nonnegative number (int or decimal) or empty when null/absent.
_graph_schedule_budget_nonneg_number() {
  local json="$1" field="$2" val
  val="$(printf '%s' "$json" | jq -r --arg f "$field" '
    .[$f] // empty
    | if . == null or . == "" then empty
      elif type == "number" and . >= 0 then tostring
      elif type == "string" and test("^[0-9]+([.][0-9]+)?$") then .
      else empty end
  ' 2>/dev/null)" || val=""
  printf '%s\n' "$val"
}

# _graph_schedule_number_ge <used> <limit>
# True when both values are nonnegative numbers and used >= limit.
_graph_schedule_number_ge() {
  local used="$1" limit="$2"
  [[ -n "$used" && -n "$limit" ]] || return 1
  jq -ne --arg used "$used" --arg limit "$limit" '
    ($used | tonumber) >= ($limit | tonumber)
  ' >/dev/null 2>&1
}

# _graph_schedule_missing_usage_policy [node_id]
# Prints warn, fail, or zero from the resolved budgets object.
_graph_schedule_missing_usage_policy() {
  local node_id="${1:-}" budgets policy
  budgets="$(_graph_schedule_node_budgets "$node_id")"
  policy="$(printf '%s' "$budgets" | jq -r '.missingUsage // "warn"' 2>/dev/null)" || policy="warn"
  case "$policy" in
    warn|fail|zero) printf '%s\n' "$policy" ;;
    *) printf 'warn\n' ;;
  esac
}

# graph_schedule_normalize_usage [snapshot-json-or-path] [usageReliable]
# Normalize a usage snapshot into inputTokens/outputTokens/cache* /
# estimatedCostUsd and reliability (authoritative|estimated|unavailable).
graph_schedule_normalize_usage() {
  local raw="${1:-}" reliable="${2:-}"
  if [[ -n "$raw" && -f "$raw" ]]; then
    raw="$(jq -c . "$raw" 2>/dev/null || true)"
  fi
  if [[ -z "$raw" || "$raw" == "null" ]] || ! printf '%s' "$raw" | jq -e . >/dev/null 2>&1; then
    raw='{}'
  fi
  jq -nc --argjson raw "$raw" --arg reliable "$reliable" '
    def pick_num(obj; keys):
      first(
        keys[] as $k
        | obj[$k]
        | select(. != null)
        | if type == "number" then .
          elif type == "string" and test("^-?[0-9]+([.][0-9]+)?$") then tonumber
          else empty end
      ) // null;
    (if ($raw | type) == "object" and ($raw.usage | type) == "object" then $raw.usage
     else $raw end) as $src
    | (pick_num($src; ["inputTokens","input_tokens","promptTokens","prompt_tokens"])) as $input_direct
    | (pick_num($src; ["totalTokens","total_tokens"])) as $total
    | (if $input_direct != null then $input_direct else $total end) as $input
    | (pick_num($src; ["outputTokens","output_tokens","completionTokens","completion_tokens"])) as $output
    | (pick_num($src; ["cacheReadTokens","cache_read_tokens","cache_read_input_tokens"])) as $cache_read
    | (pick_num($src; ["cacheWriteTokens","cache_write_tokens","cache_creation_input_tokens","cacheCreationTokens"])) as $cache_write
    | (pick_num($src; ["estimatedCostUsd","estimated_cost_usd","costUsd","cost_usd","cost"])) as $cost
    | (pick_num($src; ["cache_read_input_tokens_estimated"])) as $cache_est
    | (($src.reliability // $src.measurement // $raw.reliability // $raw.usageReliable // "") | tostring) as $explicit
    | (if ($src.measurement_source | type) == "object" then
         [ $src.measurement_source[]? | tostring | ascii_downcase ]
       elif ($src.measurement_source | type) == "string" then
         [ $src.measurement_source | ascii_downcase ]
       else [] end) as $sources
    | ($input == null and $output == null and $cache_read == null
       and $cache_write == null and $cost == null and ($cache_est == null or $cache_est == 0)) as $empty
    | (if ($explicit | ascii_downcase) == "authoritative" or ($explicit | ascii_downcase) == "measured"
         or $explicit == "true" or $explicit == "1" then "authoritative"
       elif ($explicit | ascii_downcase) == "estimated" then "estimated"
       elif ($explicit | ascii_downcase) == "unavailable" then "unavailable"
       elif (($sources | index("estimated")) != null)
         or ($cache_est != null and $cache_est > 0 and ($cache_read == null or $cache_read == 0)) then "estimated"
       elif $reliable == "true" or $reliable == "1" or $reliable == "authoritative" then "authoritative"
       elif $reliable == "false" or $reliable == "0" or $reliable == "unavailable" then
         (if $empty then "unavailable" else "estimated" end)
       elif $empty then "unavailable"
       else "authoritative" end) as $rel
    | {
        inputTokens: $input,
        outputTokens: $output,
        cacheReadTokens: $cache_read,
        cacheWriteTokens: $cache_write,
        estimatedCostUsd: $cost,
        reliability: $rel
      }
  '
}

# graph_schedule_node_usage <node_id>
# Prints the persisted/in-memory usage aggregate for a node.
graph_schedule_node_usage() {
  _graph_schedule_node_usage_stored "$1"
}

# graph_schedule_usage_should_stop [node_id]
# True when reliable usage meets a configured token/cost ceiling, or when
# missingUsage=fail and at least one attempt has unavailable usage.
graph_schedule_usage_should_stop() {
  local node_id="${1:-}" usage budgets policy rel missing
  local in_lim out_lim cost_lim in_used out_used cost_used
  [[ -n "$node_id" ]] || return 1
  usage="$(_graph_schedule_node_usage_stored "$node_id")"
  budgets="$(_graph_schedule_node_budgets "$node_id")"
  policy="$(_graph_schedule_missing_usage_policy "$node_id")"
  rel="$(printf '%s' "$usage" | jq -r '.reliability // "unavailable"' 2>/dev/null)" || rel="unavailable"
  missing="$(printf '%s' "$usage" | jq -r '.missingAttempts // 0' 2>/dev/null)" || missing=0
  [[ "$missing" =~ ^[0-9]+$ ]] || missing=0
  if [[ "$policy" == "fail" && "$missing" -gt 0 ]]; then
    return 0
  fi
  case "$rel" in
    authoritative|mixed) ;;
    *) return 1 ;;
  esac
  in_lim="$(_graph_schedule_budget_nonneg_limit "$budgets" "maxInputTokens")"
  out_lim="$(_graph_schedule_budget_nonneg_limit "$budgets" "maxOutputTokens")"
  cost_lim="$(_graph_schedule_budget_nonneg_number "$budgets" "maxEstimatedCostUsd")"
  in_used="$(printf '%s' "$usage" | jq -r '.inputTokens // empty' 2>/dev/null)" || in_used=""
  out_used="$(printf '%s' "$usage" | jq -r '.outputTokens // empty' 2>/dev/null)" || out_used=""
  cost_used="$(printf '%s' "$usage" | jq -r '.estimatedCostUsd // empty' 2>/dev/null)" || cost_used=""
  if [[ -n "$in_lim" ]] && _graph_schedule_number_ge "$in_used" "$in_lim"; then
    return 0
  fi
  if [[ -n "$out_lim" ]] && _graph_schedule_number_ge "$out_used" "$out_lim"; then
    return 0
  fi
  if [[ -n "$cost_lim" ]] && _graph_schedule_number_ge "$cost_used" "$cost_lim"; then
    return 0
  fi
  return 1
}

# graph_schedule_usage_exhausted [node_id]
# Alias of graph_schedule_usage_should_stop for the token/cost/missing fail gate.
graph_schedule_usage_exhausted() {
  graph_schedule_usage_should_stop "$@"
}

# _graph_schedule_usage_emit_warning <node_id> <attempt_id> <kind> <reliability> <policy>
_graph_schedule_usage_emit_warning() {
  local node_id="$1" attempt_id="$2" kind="$3" reliability="$4" policy="$5" idx runtime=""
  if idx="$(graph_schedule_index_map_get "$node_id" 2>/dev/null)"; then
    runtime="${GRAPH_NODE_RUNTIMES[$idx]:-}"
  fi
  _graph_schedule_log_observability "budget-warning" "$node_id" "$attempt_id" \
    "$runtime" "" "$(jq -nc --arg kind "$kind" --arg reliability "$reliability" \
      --arg policy "$policy" '{
        budget: $kind,
        reliability: $reliability,
        policy: $policy,
        retryable: false
      }')"
}

# graph_schedule_record_attempt_usage <node_id> <attempt_id> [snapshot] [usageReliable]
# Add one attempt's usage to the node aggregate. The same attemptId is counted
# once. Missing snapshots follow missingUsage (warn/fail/zero) instead of
# becoming zero. Estimated usage warns and is not treated as reliable.
graph_schedule_record_attempt_usage() {
  local node_id="$1" attempt_id="$2" snapshot="${3:-}" reliable="${4:-}"
  local idx usage normalized rel policy next warn_kind="" apply_zero=0
  [[ -n "$node_id" && -n "$attempt_id" ]] || return 1
  if ! idx="$(graph_schedule_index_map_get "$node_id" 2>/dev/null)"; then
    return 1
  fi
  usage="$(_graph_schedule_node_usage_stored "$node_id")"
  if printf '%s' "$usage" | jq -e --arg id "$attempt_id" \
    '.countedAttemptIds | index($id) != null' >/dev/null 2>&1; then
    printf '%s\n' "$usage"
    return 0
  fi
  if [[ -z "$snapshot" || "$snapshot" == "null" ]]; then
    snapshot="$(_graph_schedule_usage_snapshot_from_report "$attempt_id" "$node_id" 2>/dev/null || true)"
  fi
  normalized="$(graph_schedule_normalize_usage "$snapshot" "$reliable")" || normalized=""
  if [[ -z "$normalized" ]]; then
    normalized="$(jq -nc '{inputTokens:null,outputTokens:null,cacheReadTokens:null,cacheWriteTokens:null,estimatedCostUsd:null,reliability:"unavailable"}')"
  fi
  rel="$(printf '%s' "$normalized" | jq -r '.reliability // "unavailable"' 2>/dev/null)" || rel="unavailable"
  policy="$(_graph_schedule_missing_usage_policy "$node_id")"
  if [[ "$rel" == "unavailable" ]]; then
    case "$policy" in
      zero) apply_zero=1 ;;
      warn|fail) warn_kind="missingUsage" ;;
    esac
  elif [[ "$rel" == "estimated" ]]; then
    warn_kind="estimated"
  fi
  next="$(jq -nc --argjson acc "$usage" --argjson snap "$normalized" --arg id "$attempt_id" \
    --arg rel "$rel" --argjson zero "$apply_zero" '
    def add_num(a; b):
      if a == null then b elif b == null then a else a + b end;
    def add_cost(a; b):
      add_num(a; b) as $sum
      | if $sum == null then null else (($sum * 1000000 | round) / 1000000) end;
    def combine(cur; nxt):
      if cur == "unavailable" then nxt
      elif nxt == "unavailable" then
        (if cur == "authoritative" or cur == "estimated" then "mixed" else cur end)
      elif cur == nxt then cur
      else "mixed" end;
    ($acc + {
      countedAttemptIds: (($acc.countedAttemptIds // []) + [$id]),
      missingAttempts: (($acc.missingAttempts // 0) + (if $rel == "unavailable" then 1 else 0 end)),
      warned: (($acc.warned // false) or ($rel == "unavailable" and $zero == 0) or $rel == "estimated")
    }) as $base
    | if $rel == "authoritative" then
        $base + {
          inputTokens: add_num($acc.inputTokens; $snap.inputTokens),
          outputTokens: add_num($acc.outputTokens; $snap.outputTokens),
          cacheReadTokens: add_num($acc.cacheReadTokens; $snap.cacheReadTokens),
          cacheWriteTokens: add_num($acc.cacheWriteTokens; $snap.cacheWriteTokens),
          estimatedCostUsd: add_cost($acc.estimatedCostUsd; $snap.estimatedCostUsd),
          reliability: combine($acc.reliability; "authoritative")
        }
      elif $rel == "estimated" then
        $base + {
          reliability: combine($acc.reliability; "estimated")
        }
      elif $zero == 1 then
        $base + {
          inputTokens: add_num($acc.inputTokens; 0),
          outputTokens: add_num($acc.outputTokens; 0),
          cacheReadTokens: add_num($acc.cacheReadTokens; 0),
          cacheWriteTokens: add_num($acc.cacheWriteTokens; 0),
          estimatedCostUsd: add_cost($acc.estimatedCostUsd; 0),
          reliability: combine($acc.reliability; "unavailable")
        }
      else
        $base + {reliability: combine($acc.reliability; "unavailable")}
      end
  ')" || next="$usage"
  GRAPH_NODE_USAGE_JSON[$idx]="$next"
  _graph_schedule_persist_budget_fields "$node_id" || true
  if [[ -n "$warn_kind" ]]; then
    _graph_schedule_usage_emit_warning "$node_id" "$attempt_id" "$warn_kind" "$rel" "$policy"
  fi
  case "${GRAPH_NODE_STATES[$idx]:-}" in
    failed|pending|retry-wait)
      if graph_schedule_usage_should_stop "$node_id"; then
        graph_schedule_apply_usage_exhaustion "$node_id" "$attempt_id" || true
      fi
      ;;
  esac
  printf '%s\n' "$next"
  return 0
}

# graph_schedule_apply_usage_exhaustion <node_id> [attempt_id]
# Classify a usage-budget stop, persist reliability, emit budget-exhausted,
# and terminalize. Does not enter ordinary retry.
graph_schedule_apply_usage_exhaustion() {
  local node_id="$1" attempt_id="${2:-}" idx report classified class summary extra
  local usage budgets scope="maxInputTokens" used="" limit="" runtime="" node_file already=""
  local policy rel missing in_lim out_lim cost_lim in_used out_used cost_used
  [[ -n "$node_id" ]] || return 1
  if ! idx="$(graph_schedule_index_map_get "$node_id" 2>/dev/null)"; then
    return 1
  fi
  if [[ -n "${GRAPH_SCHEDULE_WORKSPACE:-}" && -n "${GRAPH_SCHEDULE_LEDGER_NAMESPACE:-}" \
    && -n "${GRAPH_SCHEDULE_RUN_ID:-}" ]]; then
    node_file="$(graph_state_node_file "$GRAPH_SCHEDULE_WORKSPACE" \
      "$GRAPH_SCHEDULE_LEDGER_NAMESPACE" "$GRAPH_SCHEDULE_RUN_ID" "$node_id" 2>/dev/null || true)"
    if [[ -n "$node_file" && -f "$node_file" ]]; then
      already="$(jq -r '.budget.exhausted // false' "$node_file" 2>/dev/null)" || already=""
    fi
  fi
  usage="$(_graph_schedule_node_usage_stored "$node_id")"
  budgets="$(_graph_schedule_node_budgets "$node_id")"
  policy="$(_graph_schedule_missing_usage_policy "$node_id")"
  rel="$(printf '%s' "$usage" | jq -r '.reliability // "unavailable"' 2>/dev/null)" || rel="unavailable"
  missing="$(printf '%s' "$usage" | jq -r '.missingAttempts // 0' 2>/dev/null)" || missing=0
  [[ "$missing" =~ ^[0-9]+$ ]] || missing=0
  in_lim="$(_graph_schedule_budget_nonneg_limit "$budgets" "maxInputTokens")"
  out_lim="$(_graph_schedule_budget_nonneg_limit "$budgets" "maxOutputTokens")"
  cost_lim="$(_graph_schedule_budget_nonneg_number "$budgets" "maxEstimatedCostUsd")"
  in_used="$(printf '%s' "$usage" | jq -r '.inputTokens // empty' 2>/dev/null)" || in_used=""
  out_used="$(printf '%s' "$usage" | jq -r '.outputTokens // empty' 2>/dev/null)" || out_used=""
  cost_used="$(printf '%s' "$usage" | jq -r '.estimatedCostUsd // empty' 2>/dev/null)" || cost_used=""
  if [[ "$policy" == "fail" && "$missing" -gt 0 ]]; then
    scope="missingUsage"
    used="$missing"
    limit=""
  elif [[ -n "$in_lim" ]] && _graph_schedule_number_ge "$in_used" "$in_lim"; then
    scope="maxInputTokens"
    used="$in_used"
    limit="$in_lim"
  elif [[ -n "$out_lim" ]] && _graph_schedule_number_ge "$out_used" "$out_lim"; then
    scope="maxOutputTokens"
    used="$out_used"
    limit="$out_lim"
  elif [[ -n "$cost_lim" ]] && _graph_schedule_number_ge "$cost_used" "$cost_lim"; then
    scope="maxEstimatedCostUsd"
    used="$cost_used"
    limit="$cost_lim"
  else
    scope="missingUsage"
    used="$missing"
    limit=""
  fi
  report="$(jq -nc --arg used "$used" --arg limit "$limit" --arg scope "$scope" \
    --arg rel "$rel" '{
    class: "terminal-configuration",
    kind: "configuration",
    reason: "budget-exhausted",
    outcome: "failed",
    summary: (if $scope == "missingUsage" then
      "usage budget exhausted (missingUsage fail; reliability " + $rel + ")"
    else
      "usage budget exhausted (" + $scope + " " + $used + "/" + $limit + ")"
    end),
    budget: $scope,
    reliability: $rel,
    used: (if $used == "" then null elif ($used | test("^-?[0-9]+([.][0-9]+)?$")) then ($used | tonumber) else $used end),
    limit: (if $limit == "" then null elif ($limit | test("^-?[0-9]+([.][0-9]+)?$")) then ($limit | tonumber) else $limit end)
  }')"
  classified="$(graph_failure_classify "$report" 2>/dev/null)" || classified=""
  class="$(printf '%s' "$classified" | jq -r '.classification // "terminal-configuration"' 2>/dev/null)" || class="terminal-configuration"
  summary="$(printf '%s' "$classified" | jq -r '.summary // empty' 2>/dev/null)" || summary=""
  [[ -n "$class" && "$class" != "null" ]] || class="terminal-configuration"
  extra="$(jq -nc --argjson budget "$(_graph_schedule_budget_extra_json "$node_id")" \
    --arg class "$class" --arg scope "$scope" --arg used "$used" --arg limit "$limit" \
    --arg rel "$rel" '
    $budget + {budget: ($budget.budget + {
      exhausted: true,
      scope: $scope,
      limit: (if $limit == "" then null elif ($limit | test("^-?[0-9]+([.][0-9]+)?$")) then ($limit | tonumber) else $limit end),
      classification: $class,
      usageReliability: $rel
    })}')"
  _graph_schedule_persist_budget_fields "$node_id" "$extra" || true
  runtime="${GRAPH_NODE_RUNTIMES[$idx]:-}"
  if [[ "$already" != "true" ]]; then
    case "${GRAPH_NODE_STATES[$idx]:-}" in
      failed)
        ;;
      running)
        GRAPH_NODE_STATES[$idx]="failed"
        if [[ -n "${GRAPH_SCHEDULE_LEDGER_RUN_DIR:-}" ]]; then
          _graph_schedule_ledger_record "$node_id" "failed" \
            "$attempt_id" "failed" "1" "" "$(graph_schedule_active_now_iso)" \
            "$runtime" "" "budget-exhausted" "$extra"
        fi
        _graph_schedule_runtime_release "$node_id" || true
        ;;
      *)
        if [[ "${GRAPH_NODE_STATES[$idx]:-}" != "running" ]]; then
          GRAPH_NODE_STATES[$idx]="running"
          if [[ -n "${GRAPH_SCHEDULE_LEDGER_RUN_DIR:-}" ]]; then
            _graph_schedule_ledger_record "$node_id" "running" \
              "$attempt_id" "" "" "$(graph_schedule_active_now_iso)" "" \
              "$runtime" "" "budget-exhausted" "$extra" 2>/dev/null || true
          fi
        fi
        GRAPH_NODE_STATES[$idx]="failed"
        if [[ -n "${GRAPH_SCHEDULE_LEDGER_RUN_DIR:-}" ]]; then
          _graph_schedule_ledger_record "$node_id" "failed" \
            "$attempt_id" "failed" "1" "" "$(graph_schedule_active_now_iso)" \
            "$runtime" "" "budget-exhausted" "$extra"
        fi
        ;;
    esac
    _graph_schedule_log_observability "budget-exhausted" "$node_id" "$attempt_id" \
      "$runtime" "" "$(jq -nc --arg class "$class" --arg scope "$scope" \
        --arg used "$used" --arg limit "$limit" --arg summary "$summary" \
        --arg rel "$rel" '{
          budget: $scope,
          used: (if $used == "" then null elif ($used | test("^-?[0-9]+([.][0-9]+)?$")) then ($used | tonumber) else $used end),
          limit: (if $limit == "" then null elif ($limit | test("^-?[0-9]+([.][0-9]+)?$")) then ($limit | tonumber) else $limit end),
          classification: $class,
          reliability: $rel,
          retryable: false,
          summary: $summary
        }')"
  fi
  _graph_schedule_apply_node_failure "$node_id" 1 "budget-exhausted"
  echo "graph-schedule: node=$node_id budget-exhausted scope=$scope used=${used:-n/a} limit=${limit:-n/a} reliability=$rel class=$class" >&2
  return 0
}

# graph_schedule_enforce_usage_budgets
# Terminalize pending/failed/retry-wait/running nodes that have crossed a
# reliable usage ceiling or a fail missing-usage policy.
graph_schedule_enforce_usage_budgets() {
  local i node_id attempt_id
  for ((i = 0; i < ${#GRAPH_NODE_IDS[@]}; i++)); do
    case "${GRAPH_NODE_STATES[$i]:-}" in
      pending|failed|retry-wait|running) ;;
      *) continue ;;
    esac
    node_id="${GRAPH_NODE_IDS[$i]}"
    graph_schedule_usage_should_stop "$node_id" || continue
    attempt_id=""
    if [[ -n "${GRAPH_SCHEDULE_WORKSPACE:-}" && -n "${GRAPH_SCHEDULE_LEDGER_NAMESPACE:-}" \
      && -n "${GRAPH_SCHEDULE_RUN_ID:-}" ]]; then
      attempt_id="$(graph_state_node_last_attempt_id "$GRAPH_SCHEDULE_WORKSPACE" \
        "$GRAPH_SCHEDULE_LEDGER_NAMESPACE" "$GRAPH_SCHEDULE_RUN_ID" "$node_id" 2>/dev/null || true)"
    fi
    graph_schedule_apply_usage_exhaustion "$node_id" "$attempt_id"
  done
  return 0
}

# graph_schedule_operator_request_id <node_id> [attempt_id]
# Deterministic create-once id for a permission pause. Honors
# GRAPH_OPERATOR_REQUEST_ID for tests.
graph_schedule_operator_request_id() {
  local node_id="$1" attempt_id="${2:-}" n safe
  if [[ -n "${GRAPH_OPERATOR_REQUEST_ID:-}" ]]; then
    printf '%s\n' "$GRAPH_OPERATOR_REQUEST_ID"
    return 0
  fi
  safe="$(printf '%s' "$node_id" | sed 's/[^A-Za-z0-9._-]/_/g')"
  [[ -n "$safe" ]] || safe="node"
  n="$(_graph_schedule_attempt_number_from_id "$attempt_id")"
  if [[ "$n" =~ ^[1-9][0-9]*$ ]]; then
    printf 'op-%s-%s\n' "$safe" "$n"
    return 0
  fi
  if [[ -n "$attempt_id" ]]; then
    safe="$(printf 'op-%s-%s' "$safe" "$attempt_id" | sed 's/[^A-Za-z0-9._-]/_/g')"
    printf '%s\n' "$safe"
    return 0
  fi
  printf 'op-%s-1\n' "$safe"
}

# graph_schedule_operator_expires_at [created_at]
# Default request lifetime is one hour after createdAt. Honors
# GRAPH_OPERATOR_EXPIRES_AT for tests.
graph_schedule_operator_expires_at() {
  local created="${1:-}"
  if [[ -n "${GRAPH_OPERATOR_EXPIRES_AT:-}" ]]; then
    printf '%s\n' "$GRAPH_OPERATOR_EXPIRES_AT"
    return 0
  fi
  if [[ -z "$created" ]]; then
    created="$(graph_operator_now_iso)"
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import sys
from datetime import datetime, timedelta, timezone
raw = sys.argv[1]
try:
    dt = datetime.strptime(raw, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
except ValueError:
    sys.exit(1)
print((dt + timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ"))
' "$created" && return 0
  fi
  if date -u -d "${created} +1 hour" +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
    date -u -d "${created} +1 hour" +%Y-%m-%dT%H:%M:%SZ
    return 0
  fi
  if date -u -v+1H +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
    date -u -v+1H +%Y-%m-%dT%H:%M:%SZ
    return 0
  fi
  printf '%s\n' "$created"
}

# graph_schedule_build_operator_request <node_id> <attempt_id> [result]
# Compact request JSON from a classified permission report plus run identity.
# Prompts and raw output are discarded.
graph_schedule_build_operator_request() {
  local node_id="$1" attempt_id="$2" result="${3:-}"
  local report="" extracted action resource effect reason session_id
  local choices_json request_id created expires runtime namespace run_id
  local summary=""

  if [[ -z "$node_id" ]]; then
    echo "Error: graph_schedule_build_operator_request requires node_id" >&2
    return 1
  fi
  if [[ -n "$result" ]]; then
    if [[ "$result" == \{* || "$result" == \[* ]]; then
      report="$result"
    elif [[ -f "$result" ]]; then
      report="$(cat -- "$result" 2>/dev/null || true)"
    fi
  fi
  [[ -n "$report" ]] || report='{}'
  if ! printf '%s' "$report" | jq -e 'type == "object"' >/dev/null 2>&1; then
    report='{}'
  fi

  extracted="$(printf '%s' "$report" | jq -c '
    def first_nonempty:
      map(select(. != null and . != "" and . != "null")) | .[0] // "";
    {
      action: ([
        .permissionRequest.tool,
        .permissionRequest.action,
        .action,
        .tool
      ] | first_nonempty),
      resource: ([
        .permissionRequest.resource,
        .permissionRequest.rule,
        .permissionRequest.pattern,
        .resource
      ] | first_nonempty),
      effect: ((.permissionRequest.effect // .effect // "write") | tostring),
      reason: ([
        .permissionRequest.reason,
        .reason,
        .summary,
        .message
      ] | first_nonempty),
      sessionId: ([
        .sessionId,
        .session.id,
        .sessionIdentity
      ] | first_nonempty),
      choices: (
        if (.permissionRequest.choices | type) == "array" then .permissionRequest.choices
        elif (.choices | type) == "array" then .choices
        else ["allow-once","allow-run","allow-always","deny"] end
      )
    }
  ' 2>/dev/null)" || extracted=""
  [[ -n "$extracted" ]] || extracted='{"action":"","resource":"","effect":"write","reason":"","sessionId":"","choices":["allow-once","allow-run","allow-always","deny"]}'

  action="$(printf '%s' "$extracted" | jq -r '.action')"
  resource="$(printf '%s' "$extracted" | jq -r '.resource')"
  effect="$(printf '%s' "$extracted" | jq -r '.effect')"
  reason="$(printf '%s' "$extracted" | jq -r '.reason')"
  session_id="$(printf '%s' "$extracted" | jq -r '.sessionId')"
  choices_json="$(printf '%s' "$extracted" | jq -c '.choices')"
  [[ -n "$action" ]] || action="permission"
  [[ -n "$resource" ]] || resource="$action"
  case "$effect" in
    read|write|network) ;;
    *) effect="write" ;;
  esac
  if graph_logs_has_dotdot "$resource" 2>/dev/null || [[ "$resource" == *$'\n'* ]]; then
    resource="$action"
  fi
  if [[ -z "$reason" ]]; then
    summary="$(graph_failure_classify "$report" 2>/dev/null | jq -r '.summary // empty')" || summary=""
    reason="${summary:-operator permission required}"
  fi

  request_id="$(graph_schedule_operator_request_id "$node_id" "$attempt_id")" || return 1
  created="$(graph_operator_now_iso)"
  expires="$(graph_schedule_operator_expires_at "$created")" || return 1
  runtime="$(graph_schedule_node_runtime_by_id "$node_id" 2>/dev/null || true)"
  [[ -n "$runtime" ]] || runtime="cursor"
  namespace="${GRAPH_SCHEDULE_LEDGER_NAMESPACE:-${GRAPH_SCHEDULE_NAMESPACE:-graph}}"
  run_id="${GRAPH_SCHEDULE_RUN_ID:-run}"
  [[ -n "$attempt_id" ]] || attempt_id="${node_id}-1"

  jq -nc \
    --arg requestId "$request_id" \
    --arg namespace "$namespace" \
    --arg runId "$run_id" \
    --arg nodeId "$node_id" \
    --arg attemptId "$attempt_id" \
    --arg runtime "$runtime" \
    --arg sessionId "$session_id" \
    --arg action "$action" \
    --arg resource "$resource" \
    --arg effect "$effect" \
    --arg reason "$reason" \
    --argjson choices "$choices_json" \
    --arg createdAt "$created" \
    --arg expiresAt "$expires" \
    '{
      requestId:$requestId,
      namespace:$namespace,
      runId:$runId,
      nodeId:$nodeId,
      attemptId:$attemptId,
      runtime:$runtime,
      sessionId:$sessionId,
      classification:"operator-permission",
      action:$action,
      resource:$resource,
      effect:$effect,
      reason:$reason,
      choices:$choices,
      createdAt:$createdAt,
      expiresAt:$expiresAt
    }'
}

# graph_schedule_persist_operator_request <node_id> <attempt_id> [result]
# Create-once persist under <run-dir>/operator/requests/. Prints the path.
# Returns 1 when there is no run directory or the write is rejected.
graph_schedule_persist_operator_request() {
  local node_id="$1" attempt_id="$2" result="${3:-}"
  local run_dir request_json path
  run_dir="${GRAPH_SCHEDULE_LEDGER_RUN_DIR:-${GRAPH_SCHEDULE_LOG_RUN_DIR:-}}"
  GRAPH_SCHEDULE_OPERATOR_REQUEST_PATH=""
  if [[ -z "$run_dir" || ! -d "$run_dir" ]]; then
    return 1
  fi
  request_json="$(graph_schedule_build_operator_request "$node_id" "$attempt_id" "$result")" || return 1
  path="$(graph_operator_request_write "$run_dir" "$request_json")" || return 1
  GRAPH_SCHEDULE_OPERATOR_REQUEST_PATH="$path"
  printf '%s\n' "$path"
}

# graph_schedule_apply_operator_permission <node_id> <exit_code> [reason] [attempt_id] [result]
# Persist a permission request, pause the node/attempt as awaiting-operator,
# release concurrency/runtime slots, and keep independent branches runnable.
# Does not consume a retry grant or active-time budget and does not apply
# drain/cancel failure policy.
graph_schedule_apply_operator_permission() {
  local node_id="$1" exit_code="$2" reason="${3:-operator-permission}" attempt_id="${4:-}" result="${5:-}"
  local idx request_id extra_json request_path="" runtime="" native_subagents=""
  if [[ -z "$node_id" ]]; then
    echo "Error: graph_schedule_apply_operator_permission requires node_id" >&2
    return 1
  fi
  if ! idx="$(graph_schedule_index_map_get "$node_id")"; then
    echo "Error: graph_schedule_apply_operator_permission unknown node: $node_id" >&2
    return 1
  fi

  request_path=""
  if graph_schedule_persist_operator_request "$node_id" "$attempt_id" "$result" >/dev/null 2>&1; then
    request_path="${GRAPH_SCHEDULE_OPERATOR_REQUEST_PATH:-}"
  fi
  request_id=""
  if [[ -n "$request_path" && -f "$request_path" ]]; then
    request_id="$(jq -r '.requestId // empty' "$request_path" 2>/dev/null || true)"
  fi
  if [[ -z "$request_id" ]]; then
    request_id="$(graph_schedule_operator_request_id "$node_id" "$attempt_id")"
  fi

  GRAPH_NODE_STATES[$idx]="awaiting-operator"
  GRAPH_SCHEDULE_AWAITING_OPERATOR=1
  # A permission wait is not an ordinary failure: keep dispatching siblings
  # and do not spend the in-memory retry grant, stop the ready set, or charge
  # active-time while the operator request is unresolved.
  graph_schedule_pause_active_clock "$node_id" || true
  GRAPH_SCHEDULE_STOP_DISPATCH=0
  runtime="${GRAPH_NODE_RUNTIMES[$idx]:-}"
  native_subagents="${GRAPH_NODE_NATIVE_SUBAGENTS[$idx]:-}"
  extra_json="{}"
  if [[ -n "$request_id" ]]; then
    extra_json="$(jq -cn --arg rid "$request_id" '{operatorRequestId:$rid}')" || extra_json="{}"
  fi
  _graph_schedule_runtime_release "$node_id"
  if [[ -n "${GRAPH_SCHEDULE_LEDGER_RUN_DIR:-}" ]]; then
    _graph_schedule_ledger_record "$node_id" "awaiting-operator" \
      "$attempt_id" "awaiting-operator" "$exit_code" "" "$(graph_state_now_iso)" \
      "$runtime" "$native_subagents" "$reason" "$extra_json"
  fi
  if [[ -n "$request_id" && -n "${GRAPH_SCHEDULE_LEDGER_RUN_DIR:-}" ]]; then
    _graph_schedule_log_observability "operator-request" "$node_id" "$attempt_id" \
      "$runtime" "$native_subagents" "$(jq -cn --arg rid "$request_id" '{requestId:$rid}')"
  fi
  graph_ui_node "awaiting-operator" "$node_id" "reason=$reason request=${request_id:-}"
  _graph_schedule_mark_blocked_descendants "$node_id"
  echo "graph-schedule: node=$node_id awaiting-operator reason=$reason request=${request_id:-}" >&2
  _graph_schedule_print_operator_request_notice "$node_id" "$request_id" "$reason" "$runtime"
  return 0
}

# Print the copy-paste command that answers a parked node.
#
# The scheduler polls for operator decisions on every loop iteration, so a
# decision recorded from another terminal requeues the node inside the live
# run -- no restart needed. That only helps if the operator can see what to
# type, so print it next to the pause rather than leaving the request id to be
# reconstructed from the ledger.
_graph_schedule_print_operator_request_notice() {
  local node_id="$1" request_id="$2" reason="$3" runtime="${4:-}"
  [[ -n "$request_id" ]] || return 0

  local ns="${GRAPH_SCHEDULE_NAMESPACE:-}"
  local run_id="${GRAPH_SCHEDULE_RUN_ID:-}"
  local scope=""
  [[ -n "$ns" ]] && scope+=" --namespace $ns"
  [[ -n "$run_id" ]] && scope+=" --run $run_id"

  {
    printf '\n  Node %s needs an operator decision%s.\n' \
      "$node_id" "$([[ -n "$runtime" ]] && printf ' (runtime %s)' "$runtime")"
    printf '  Reason: %s\n\n' "${reason:-permission}"
    printf '  Answer from another terminal; this run picks it up and continues:\n'
    printf '    ralph workflow actions respond %s %s --decision allow-once\n' "$run_id" "$request_id"
    printf '    ralph workflow actions respond %s %s --decision deny\n\n' "$run_id" "$request_id"
    printf '  Other decisions: allow-run (rest of this run), allow-always (persist a rule).\n'
    printf '  See every open request:  ralph workflow actions list %s\n\n' "$run_id"
  } >&2
}

# graph_schedule_operator_consumed_rel <request-id>
graph_schedule_operator_consumed_rel() {
  local request_id="$1"
  graph_operator_request_id_valid "$request_id" || return 1
  printf 'operator/consumed/%s.json\n' "$request_id"
}

# graph_schedule_operator_consumed_path <run-dir> <request-id>
graph_schedule_operator_consumed_path() {
  local run_dir="$1" request_id="$2" rel
  if [[ -z "$run_dir" || -z "$request_id" ]]; then
    echo "Error: graph_schedule_operator_consumed_path requires run-dir and request-id" >&2
    return 1
  fi
  rel="$(graph_schedule_operator_consumed_rel "$request_id")" || return 1
  graph_logs_resolve "$run_dir" "$rel"
}

# graph_schedule_operator_decision_is_consumed <run-dir> <request-id>
# Returns 0 when the create-once consume record exists.
graph_schedule_operator_decision_is_consumed() {
  local run_dir="$1" request_id="$2" abs
  abs="$(graph_schedule_operator_consumed_path "$run_dir" "$request_id" 2>/dev/null)" || return 1
  [[ -f "$abs" && ! -L "$abs" ]]
}

# graph_schedule_operator_continuation_rel <request-id>
graph_schedule_operator_continuation_rel() {
  local request_id="$1"
  graph_operator_request_id_valid "$request_id" || return 1
  printf 'operator/continuations/%s.json\n' "$request_id"
}

# graph_schedule_operator_alternative_rel <node-id>
graph_schedule_operator_alternative_rel() {
  local node_id="$1" safe
  if [[ -z "$node_id" ]]; then
    echo "Error: graph_schedule_operator_alternative_rel requires node-id" >&2
    return 1
  fi
  safe="$(printf '%s' "$node_id" | sed 's/[^A-Za-z0-9._-]/_/g')"
  [[ -n "$safe" ]] || safe="node"
  graph_operator_request_id_valid "$safe" || return 1
  printf 'operator/alternatives/%s.json\n' "$safe"
}

# graph_schedule_operator_request_id_for_node <node-id>
# Resolve the paused request id from the ledger, then the request directory.
graph_schedule_operator_request_id_for_node() {
  local node_id="$1"
  local run_dir node_file rid="" candidate req_dir f
  [[ -n "$node_id" ]] || return 1
  run_dir="${GRAPH_SCHEDULE_LEDGER_RUN_DIR:-${GRAPH_SCHEDULE_LOG_RUN_DIR:-}}"
  if [[ -n "${GRAPH_SCHEDULE_WORKSPACE:-}" && -n "${GRAPH_SCHEDULE_LEDGER_NAMESPACE:-}" \
    && -n "${GRAPH_SCHEDULE_RUN_ID:-}" ]]; then
    node_file="$(graph_state_node_file "$GRAPH_SCHEDULE_WORKSPACE" \
      "$GRAPH_SCHEDULE_LEDGER_NAMESPACE" "$GRAPH_SCHEDULE_RUN_ID" "$node_id" 2>/dev/null || true)"
    if [[ -n "$node_file" && -f "$node_file" ]]; then
      rid="$(jq -r '.attempts[-1].operatorRequestId // .operatorRequestId // empty' \
        "$node_file" 2>/dev/null || true)"
    fi
  fi
  if [[ -z "$rid" && -n "$run_dir" ]]; then
    req_dir="$(graph_logs_resolve "$run_dir" "operator/requests" 2>/dev/null || true)"
    if [[ -n "$req_dir" && -d "$req_dir" ]]; then
      for f in "$req_dir"/*.json; do
        [[ -f "$f" && ! -L "$f" ]] || continue
        candidate="$(jq -r --arg id "$node_id" \
          'select(.nodeId == $id) | .requestId // empty' "$f" 2>/dev/null || true)"
        [[ -n "$candidate" ]] || continue
        if [[ -z "$rid" ]] || ! graph_schedule_operator_decision_is_consumed "$run_dir" "$candidate"; then
          rid="$candidate"
        fi
        if [[ -n "$rid" ]] && ! graph_schedule_operator_decision_is_consumed "$run_dir" "$rid"; then
          break
        fi
      done
    fi
  fi
  if [[ -z "$rid" ]]; then
    rid="$(graph_schedule_operator_request_id "$node_id")" || return 1
  fi
  printf '%s\n' "$rid"
}

# graph_schedule_consume_operator_decision <run-dir> <request-id>
# Consume a valid stored decision exactly once. Prints the consume-record path.
# A second consume of the same request fails and leaves the first record.
graph_schedule_consume_operator_decision() {
  local run_dir="$1" request_id="$2"
  local decision_json decision rel abs record write_ec path_kind granted

  if [[ -z "$run_dir" || -z "$request_id" ]]; then
    echo "Error: graph_schedule_consume_operator_decision requires run-dir and request-id" >&2
    return 1
  fi
  GRAPH_SCHEDULE_OPERATOR_DECISION_PATH=""
  decision_json="$(graph_operator_decision_read "$run_dir" "$request_id")" || return 1
  decision="$(printf '%s' "$decision_json" | jq -r '.decision // empty')"
  if ! graph_operator_token_in_list "$decision" "$GRAPH_OPERATOR_CHOICES"; then
    echo "Error: operator decision is not a valid choice: ${decision:-<empty>}" >&2
    return 1
  fi
  if graph_schedule_operator_decision_is_consumed "$run_dir" "$request_id"; then
    echo "Error: operator decision already consumed: $request_id" >&2
    return 1
  fi

  case "$decision" in
    deny) path_kind="compact-alternative" ;;
    *) path_kind="adapter-continuation" ;;
  esac
  granted="$(printf '%s' "$decision_json" | jq -c '.granted // null')"
  record="$(jq -nc \
    --arg requestId "$request_id" \
    --arg decision "$decision" \
    --arg consumedAt "$(graph_operator_now_iso)" \
    --arg path "$path_kind" \
    --argjson granted "$granted" \
    '{
      requestId:$requestId,
      decision:$decision,
      consumedAt:$consumedAt,
      path:$path,
      granted:(if $granted == null then null else $granted end)
    }')" || {
    echo "Error: failed to encode operator consume record" >&2
    return 1
  }

  rel="$(graph_schedule_operator_consumed_rel "$request_id")" || return 1
  if ! graph_logs_prepare_parent "$run_dir" "$rel"; then
    echo "Error: operator consume path is not contained in the run-dir" >&2
    return 1
  fi
  abs="$(graph_logs_resolve "$run_dir" "$rel")" || return 1
  if [[ -L "$abs" ]]; then
    echo "Error: refusing to write through an operator consume symlink: $rel" >&2
    return 1
  fi
  write_ec=0
  graph_operator_create_once_write "$abs" "$record" || write_ec=$?
  if [[ "$write_ec" -eq 0 ]]; then
    GRAPH_SCHEDULE_OPERATOR_DECISION_PATH="$abs"
    printf '%s\n' "$abs"
    return 0
  fi
  echo "Error: operator decision already consumed: $request_id" >&2
  return 1
}

# graph_schedule_write_operator_adapter_continuation <run-dir> <request-id> <next-attempt>
# Compact allow-path record for the adapter continuation. No prompts or output.
graph_schedule_write_operator_adapter_continuation() {
  local run_dir="$1" request_id="$2" next_attempt="${3:-}"
  local decision_json decision granted rel abs record
  if [[ -z "$run_dir" || -z "$request_id" ]]; then
    echo "Error: graph_schedule_write_operator_adapter_continuation requires run-dir and request-id" >&2
    return 1
  fi
  [[ "$next_attempt" =~ ^[1-9][0-9]*$ ]] || next_attempt=2
  decision_json="$(graph_operator_decision_read "$run_dir" "$request_id")" || return 1
  decision="$(printf '%s' "$decision_json" | jq -r '.decision // empty')"
  granted="$(printf '%s' "$decision_json" | jq -c '.granted // null')"
  record="$(jq -nc \
    --arg requestId "$request_id" \
    --arg decision "$decision" \
    --argjson granted "$granted" \
    --argjson nextAttemptNumber "$next_attempt" \
    '{
      path:"adapter-continuation",
      requestId:$requestId,
      decision:$decision,
      granted:(if $granted == null then null else $granted end),
      nextAttemptNumber:$nextAttemptNumber
    }')" || return 1
  rel="$(graph_schedule_operator_continuation_rel "$request_id")" || return 1
  graph_logs_prepare_parent "$run_dir" "$rel" || return 1
  abs="$(graph_logs_resolve "$run_dir" "$rel")" || return 1
  if [[ -e "$abs" || -L "$abs" ]]; then
    printf '%s\n' "$abs"
    return 0
  fi
  graph_operator_create_once_write "$abs" "$record" || return 1
  printf '%s\n' "$abs"
}

# graph_schedule_write_operator_alternative_turn <run-dir> <node-id> <request-id> <next-attempt>
# Compact deny-path record for at most one alternative turn. No prompts or output.
graph_schedule_write_operator_alternative_turn() {
  local run_dir="$1" node_id="$2" request_id="$3" next_attempt="${4:-}"
  local rel abs record
  if [[ -z "$run_dir" || -z "$node_id" || -z "$request_id" ]]; then
    echo "Error: graph_schedule_write_operator_alternative_turn requires run-dir, node-id, and request-id" >&2
    return 1
  fi
  [[ "$next_attempt" =~ ^[1-9][0-9]*$ ]] || next_attempt=2
  rel="$(graph_schedule_operator_alternative_rel "$node_id")" || return 1
  graph_logs_prepare_parent "$run_dir" "$rel" || return 1
  abs="$(graph_logs_resolve "$run_dir" "$rel")" || return 1
  if [[ -e "$abs" || -L "$abs" ]]; then
    echo "Error: operator deny alternative turn already used for node=$node_id" >&2
    return 1
  fi
  record="$(jq -nc \
    --arg requestId "$request_id" \
    --argjson nextAttemptNumber "$next_attempt" \
    '{
      path:"compact-alternative",
      requestId:$requestId,
      decision:"deny",
      nextAttemptNumber:$nextAttemptNumber
    }')" || return 1
  graph_operator_create_once_write "$abs" "$record" || return 1
  printf '%s\n' "$abs"
}

# _graph_schedule_restore_blocked_descendants <node-id>
# Return exclusive descendants marked blocked by a permission wait to pending
# so a later success can release them. Remaining indegree is unchanged.
_graph_schedule_restore_blocked_descendants() {
  local node_id="$1"
  local queue=() q_i=0
  local cur succ_str succ idx state
  local seen_keys=() s_i seen
  local old_ifs="$IFS"

  succ_str="$(graph_schedule_node_successors_by_id "$node_id" 2>/dev/null)" || return 0
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
    if ! idx="$(graph_schedule_index_map_get "$cur" 2>/dev/null)"; then
      continue
    fi
    state="${GRAPH_NODE_STATES[$idx]}"
    if [[ "$state" == "blocked" ]]; then
      GRAPH_NODE_STATES[$idx]="pending"
      if [[ -n "${GRAPH_SCHEDULE_LEDGER_RUN_DIR:-}" ]]; then
        _graph_schedule_ledger_record "$cur" "pending" \
          "" "" "" "" "" "" "" "operator-decision-resume"
      fi
    fi
    succ_str="$(graph_schedule_node_successors_by_id "$cur" 2>/dev/null)" || succ_str=""
    if [[ -n "$succ_str" ]]; then
      IFS="$GRAPH_SUCCESSOR_DELIM"
      # shellcheck disable=SC2086
      for succ in $succ_str; do
        [[ -z "$succ" ]] && continue
        queue+=("$succ")
      done
      IFS="$old_ifs"
    fi
  done
  return 0
}

# _graph_schedule_refresh_awaiting_operator
# Recompute GRAPH_SCHEDULE_AWAITING_OPERATOR from in-memory node states.
_graph_schedule_refresh_awaiting_operator() {
  local i
  GRAPH_SCHEDULE_AWAITING_OPERATOR=0
  for ((i = 0; i < ${#GRAPH_NODE_STATES[@]}; i++)); do
    if [[ "${GRAPH_NODE_STATES[$i]}" == "awaiting-operator" ]]; then
      GRAPH_SCHEDULE_AWAITING_OPERATOR=1
      return 0
    fi
  done
  return 0
}

# _graph_schedule_has_unresolved_wait
# Returns 0 when a checkpoint, operator, or retry-wait is still unresolved.
_graph_schedule_has_unresolved_wait() {
  local i
  for ((i = 0; i < ${#GRAPH_NODE_STATES[@]}; i++)); do
    case "${GRAPH_NODE_STATES[$i]}" in
      awaiting-ack|awaiting-operator|retry-wait) return 0 ;;
    esac
  done
  [[ "${GRAPH_SCHEDULE_AWAITING_ACK:-0}" -eq 1 || "${GRAPH_SCHEDULE_AWAITING_OPERATOR:-0}" -eq 1 ]]
}

# _graph_schedule_has_runnable_or_running
# Returns 0 when a node is running or the ready set is non-empty.
_graph_schedule_has_runnable_or_running() {
  local ready
  if [[ "$(_graph_schedule_count_running)" -gt 0 ]]; then
    return 0
  fi
  ready="$(graph_schedule_ready_ids 2>/dev/null || true)"
  [[ -n "$ready" ]]
}

# graph_schedule_apply_operator_decision <node-id> [request-id]
# Consume a valid decision once and either start the adapter continuation
# path (allow-*) or grant at most one compact alternative turn (deny).
graph_schedule_apply_operator_decision() {
  local node_id="$1" request_id="${2:-}"
  local idx run_dir decision_json decision consumed_path record_path
  local attempt_id next_n used extra_json runtime

  if [[ -z "$node_id" ]]; then
    echo "Error: graph_schedule_apply_operator_decision requires node_id" >&2
    return 1
  fi
  if ! idx="$(graph_schedule_index_map_get "$node_id")"; then
    echo "Error: graph_schedule_apply_operator_decision unknown node: $node_id" >&2
    return 1
  fi
  if [[ "${GRAPH_NODE_STATES[$idx]}" != "awaiting-operator" ]]; then
    echo "Error: graph_schedule_apply_operator_decision node $node_id is not awaiting-operator" >&2
    return 1
  fi
  run_dir="${GRAPH_SCHEDULE_LEDGER_RUN_DIR:-${GRAPH_SCHEDULE_LOG_RUN_DIR:-}}"
  if [[ -z "$run_dir" || ! -d "$run_dir" ]]; then
    echo "Error: graph_schedule_apply_operator_decision requires a run directory" >&2
    return 1
  fi
  if [[ -z "$request_id" ]]; then
    request_id="$(graph_schedule_operator_request_id_for_node "$node_id")" || return 1
  fi

  consumed_path="$(graph_schedule_consume_operator_decision "$run_dir" "$request_id")" || return 1
  decision_json="$(graph_operator_decision_read "$run_dir" "$request_id")" || return 1
  decision="$(printf '%s' "$decision_json" | jq -r '.decision // empty')"
  attempt_id="$(printf '%s' "$decision_json" | jq -r '.attemptId // empty')"
  next_n=$(( ${GRAPH_NODE_ATTEMPT_NUMBERS[$idx]:-0} + 1 ))
  [[ "$next_n" -ge 1 ]] || next_n=1
  runtime="${GRAPH_NODE_RUNTIMES[$idx]:-}"
  _graph_schedule_restore_blocked_descendants "$node_id"

  extra_json="$(jq -cn --arg rid "$request_id" --arg decision "$decision" \
    '{operatorRequestId:$rid,operatorDecision:$decision}')" || extra_json="{}"

  case "$decision" in
    deny)
      used="${GRAPH_NODE_OPERATOR_DENY_TURNS_USED[$idx]:-0}"
      [[ "$used" =~ ^[0-9]+$ ]] || used=0
      if [[ "$used" -ge 1 ]]; then
        GRAPH_NODE_STATES[$idx]="failed"
        if [[ -z "$GRAPH_SCHEDULE_FAILED_NODE" ]]; then
          GRAPH_SCHEDULE_FAILED_NODE="$node_id"
        fi
        if [[ "$GRAPH_SCHEDULE_EXIT_CODE" -eq 0 || "$GRAPH_SCHEDULE_EXIT_CODE" -eq 3 ]]; then
          GRAPH_SCHEDULE_EXIT_CODE=1
        fi
        if [[ -n "${GRAPH_SCHEDULE_LEDGER_RUN_DIR:-}" ]]; then
          _graph_schedule_ledger_record "$node_id" "failed" \
            "$attempt_id" "failed" "1" "" "$(graph_state_now_iso)" \
            "$runtime" "" "operator-denied" "$extra_json"
        fi
        _graph_schedule_log_observability "operator-decision" "$node_id" "$attempt_id" \
          "$runtime" "" "$(jq -cn --arg rid "$request_id" --arg path "$consumed_path" \
            '{requestId:$rid,decision:"deny",path:"exhausted"}')"
        _graph_schedule_mark_blocked_descendants "$node_id"
        _graph_schedule_refresh_awaiting_operator
        echo "graph-schedule: node=$node_id operator deny exhausted compact alternative turn" >&2
        return 1
      fi
      record_path="$(graph_schedule_write_operator_alternative_turn \
        "$run_dir" "$node_id" "$request_id" "$next_n")" || return 1
      GRAPH_NODE_OPERATOR_DENY_TURNS_USED[$idx]="1"
      GRAPH_NODE_STATES[$idx]="pending"
      if [[ -n "${GRAPH_SCHEDULE_LEDGER_RUN_DIR:-}" ]]; then
        _graph_schedule_ledger_record "$node_id" "pending" \
          "" "" "" "" "" "" "" "operator-deny-alternative" "$extra_json"
      fi
      _graph_schedule_log_observability "operator-decision" "$node_id" "$attempt_id" \
        "$runtime" "" "$(jq -cn --arg rid "$request_id" --arg path "$record_path" \
          '{requestId:$rid,decision:"deny",path:"compact-alternative"}')"
      graph_ui_node "pending" "$node_id" "operator-deny-alternative request=$request_id"
      echo "graph-schedule: node=$node_id operator deny compact alternative turn request=$request_id" >&2
      ;;
    allow-once|allow-run|allow-always)
      record_path="$(graph_schedule_write_operator_adapter_continuation \
        "$run_dir" "$request_id" "$next_n")" || return 1
      GRAPH_NODE_STATES[$idx]="pending"
      if [[ -n "${GRAPH_SCHEDULE_LEDGER_RUN_DIR:-}" ]]; then
        _graph_schedule_ledger_record "$node_id" "pending" \
          "" "" "" "" "" "" "" "operator-allow-continuation" "$extra_json"
      fi
      _graph_schedule_log_observability "operator-decision" "$node_id" "$attempt_id" \
        "$runtime" "" "$(jq -cn --arg rid "$request_id" --arg path "$record_path" \
          --arg decision "$decision" \
          '{requestId:$rid,decision:$decision,path:"adapter-continuation"}')"
      graph_ui_node "pending" "$node_id" "adapter-continuation request=$request_id"
      echo "graph-schedule: node=$node_id adapter continuation path request=$request_id decision=$decision" >&2
      ;;
    *)
      echo "Error: unsupported operator decision: ${decision:-<empty>}" >&2
      return 1
      ;;
  esac
  _graph_schedule_refresh_awaiting_operator
  printf '%s\n' "$record_path"
  return 0
}

# graph_schedule_poll_operator_decisions
# Consume at most one valid decision per awaiting-operator node. Returns 0
# when at least one node was requeued or terminalized.
graph_schedule_poll_operator_decisions() {
  local i node_id request_id run_dir applied=0
  run_dir="${GRAPH_SCHEDULE_LEDGER_RUN_DIR:-${GRAPH_SCHEDULE_LOG_RUN_DIR:-}}"
  [[ -n "$run_dir" && -d "$run_dir" ]] || return 1
  for ((i = 0; i < ${#GRAPH_NODE_STATES[@]}; i++)); do
    [[ "${GRAPH_NODE_STATES[$i]}" == "awaiting-operator" ]] || continue
    node_id="${GRAPH_NODE_IDS[$i]}"
    request_id="$(graph_schedule_operator_request_id_for_node "$node_id" 2>/dev/null)" || continue
    graph_operator_decision_read "$run_dir" "$request_id" >/dev/null 2>&1 || continue
    graph_schedule_operator_decision_is_consumed "$run_dir" "$request_id" && continue
    if graph_schedule_apply_operator_decision "$node_id" "$request_id" >/dev/null 2>&1; then
      applied=1
    elif [[ "${GRAPH_NODE_STATES[$i]}" != "awaiting-operator" ]]; then
      applied=1
    fi
  done
  _graph_schedule_refresh_awaiting_operator
  [[ "$applied" -eq 1 ]]
}

# _graph_schedule_prepare_operator_decision_spawn <node_id> <attempt_number> <node_orch_path>
# Attach the compact adapter-continuation or deny-alternative record for this
# attempt. Does not attach prompts or raw output.
_graph_schedule_prepare_operator_decision_spawn() {
  local node_id="$1" attempt_number="$2" node_orch_path="$3"
  local run_dir request_id record next_n tmp
  GRAPH_SCHEDULE_SPAWN_OPERATOR_RECORD=""
  GRAPH_SCHEDULE_SPAWN_OPERATOR_PATH_KIND=""
  run_dir="${GRAPH_SCHEDULE_LEDGER_RUN_DIR:-${GRAPH_SCHEDULE_LOG_RUN_DIR:-}}"
  [[ -n "$run_dir" && -n "$node_id" ]] || return 0
  request_id="$(graph_schedule_operator_request_id_for_node "$node_id" 2>/dev/null)" || request_id=""
  if [[ -n "$request_id" ]]; then
    record="$(graph_logs_resolve "$run_dir" "$(graph_schedule_operator_continuation_rel "$request_id")" 2>/dev/null || true)"
    if [[ -n "$record" && -f "$record" ]]; then
      next_n="$(jq -r '.nextAttemptNumber // empty' "$record" 2>/dev/null)" || next_n=""
      if [[ "$next_n" == "$attempt_number" ]]; then
        GRAPH_SCHEDULE_SPAWN_OPERATOR_RECORD="$record"
        GRAPH_SCHEDULE_SPAWN_OPERATOR_PATH_KIND="adapter-continuation"
      fi
    fi
  fi
  if [[ -z "$GRAPH_SCHEDULE_SPAWN_OPERATOR_RECORD" ]]; then
    record="$(graph_logs_resolve "$run_dir" "$(graph_schedule_operator_alternative_rel "$node_id")" 2>/dev/null || true)"
    if [[ -n "$record" && -f "$record" ]]; then
      next_n="$(jq -r '.nextAttemptNumber // empty' "$record" 2>/dev/null)" || next_n=""
      if [[ "$next_n" == "$attempt_number" ]]; then
        GRAPH_SCHEDULE_SPAWN_OPERATOR_RECORD="$record"
        GRAPH_SCHEDULE_SPAWN_OPERATOR_PATH_KIND="compact-alternative"
      fi
    fi
  fi
  [[ -n "$GRAPH_SCHEDULE_SPAWN_OPERATOR_RECORD" ]] || return 0
  if [[ "$GRAPH_SCHEDULE_SPAWN_OPERATOR_PATH_KIND" == "adapter-continuation" \
    && -n "$node_orch_path" && -f "$node_orch_path" ]]; then
    tmp="$(mktemp "${node_orch_path}.op.XXXXXX")" || return 0
    if jq --arg id "$node_id" \
      '(.stages[] | select(.id == $id) | .sessionStrategy) = "resume"
       | (.stages[] | select(.id == $id) | .sessionResume) = true' \
      "$node_orch_path" >"$tmp"; then
      mv -f "$tmp" "$node_orch_path" || rm -f "$tmp"
    else
      rm -f "$tmp"
    fi
  fi
  return 0
}

# graph_schedule_apply_plan_contract <node_id> <exit_code> [reason] [attempt_id]
# Map a plan-contract failure to needs-plan-repair. Blocks only exclusive
# descendants. Independent branches keep dispatching (STOP_DISPATCH stays 0).
# Never mutates graph.json or widens writeScopes.
graph_schedule_apply_plan_contract() {
  local node_id="$1" exit_code="$2" reason="${3:-plan-contract}" attempt_id="${4:-}"
  local idx
  if [[ -z "$node_id" ]]; then
    echo "Error: graph_schedule_apply_plan_contract requires node_id" >&2
    return 1
  fi
  if ! idx="$(graph_schedule_index_map_get "$node_id")"; then
    echo "Error: graph_schedule_apply_plan_contract unknown node: $node_id" >&2
    return 1
  fi
  GRAPH_NODE_STATES[$idx]="needs-plan-repair"
  GRAPH_SCHEDULE_FAILED_NODE="$node_id"
  # Independent branches must keep draining. Do not stop dispatch and do not
  # cancel in-flight siblings, even when failurePolicy=cancel.
  if [[ "$exit_code" =~ ^[0-9]+$ && "$exit_code" -ne 0 ]]; then
    GRAPH_SCHEDULE_EXIT_CODE="$exit_code"
  elif [[ "$GRAPH_SCHEDULE_EXIT_CODE" -eq 0 ]]; then
    GRAPH_SCHEDULE_EXIT_CODE=1
  fi
  if [[ -n "${GRAPH_SCHEDULE_LEDGER_RUN_DIR:-}" ]]; then
    _graph_schedule_ledger_record "$node_id" "needs-plan-repair" \
      "$attempt_id" "failed" "$GRAPH_SCHEDULE_EXIT_CODE" "" "$(graph_state_now_iso)" \
      "" "" "$reason"
  fi
  graph_ui_node "needs-plan-repair" "$node_id" "exit=$GRAPH_SCHEDULE_EXIT_CODE reason=$reason"
  _graph_schedule_mark_blocked_descendants "$node_id"
  echo "graph-schedule: node=$node_id needs-plan-repair reason=$reason" >&2
  return 0
}

# _graph_schedule_finish_failed_or_requeue <exit_code> <reason> [attempt_id] [result]
# After the failed attempt is already in the ledger and a correction record
# has been attempted: pause operator-permission, map plan-contract to
# needs-plan-repair, grant ordinary retry (retry-wait + backoff) for
# transient-runtime and agent-correctable within configured limits, or apply
# ordinary failure. Corrective retries are governed only by the
# frozen resilience.correctiveRetries budget; an omitted or zero budget is
# deliberately fail-fast.
# Configuration, integrity, and cancelled never enter ordinary retry.
_graph_schedule_finish_failed_or_requeue() {
  local exit_code="$1" reason="$2" reap_attempt="${3:-}" result="${4:-}"
  if [[ -z "$result" ]]; then
    result="${GRAPH_REAP_REPORT_PATH:-}"
  fi
  graph_schedule_commit_active_time "$GRAPH_REAP_NODE" || true
  if graph_schedule_active_time_exhausted "$GRAPH_REAP_NODE"; then
    graph_schedule_apply_active_time_exhaustion "$GRAPH_REAP_NODE" "$reap_attempt"
    return 1
  fi
  if [[ -n "$reap_attempt" ]]; then
    graph_schedule_record_attempt_usage "$GRAPH_REAP_NODE" "$reap_attempt" || true
  fi
  if graph_schedule_usage_should_stop "$GRAPH_REAP_NODE"; then
    graph_schedule_apply_usage_exhaustion "$GRAPH_REAP_NODE" "$reap_attempt"
    return 1
  fi
  if _graph_schedule_result_is_operator_permission "$result" "$reason"; then
    graph_schedule_apply_operator_permission "$GRAPH_REAP_NODE" "$exit_code" \
      "$reason" "$reap_attempt" "$result"
    return 0
  fi
  if _graph_schedule_result_is_plan_contract "$result" "$reason"; then
    graph_schedule_apply_plan_contract "$GRAPH_REAP_NODE" "$exit_code" "$reason" "$reap_attempt"
    return 1
  fi
  if graph_schedule_try_ordinary_retry "$GRAPH_REAP_NODE" "$exit_code" \
    "$reason" "$reap_attempt" "$result"; then
    return 0
  fi
  _graph_schedule_apply_node_failure "$GRAPH_REAP_NODE" "$exit_code" "$reason"
  return 1
}

# _graph_schedule_prepare_corrective_retry_spawn <node_id> <attempt_number> <node_orch_path>
# When this spawn is the next supported session turn, remember the compact
# correction record and request session resume. Does not attach prompts.
_graph_schedule_prepare_corrective_retry_spawn() {
  local node_id="$1" attempt_number="$2" node_orch_path="$3"
  local run_dir record next_n tmp
  GRAPH_SCHEDULE_SPAWN_CORRECTION_RECORD=""
  run_dir="${GRAPH_SCHEDULE_LEDGER_RUN_DIR:-${GRAPH_SCHEDULE_LOG_RUN_DIR:-}}"
  [[ -n "$run_dir" && -n "$node_id" ]] || return 0
  record="$(graph_schedule_corrective_retry_turn "$run_dir" "$node_id" \
    "${GRAPH_SCHEDULE_GRAPH_JSON:-}")" || return 0
  next_n="$(jq -r '.nextAttemptNumber // empty' "$record" 2>/dev/null)" || next_n=""
  if [[ ! "$next_n" =~ ^[0-9]+$ || "$attempt_number" != "$next_n" ]]; then
    return 0
  fi
  GRAPH_SCHEDULE_SPAWN_CORRECTION_RECORD="$record"
  if [[ -n "$node_orch_path" && -f "$node_orch_path" ]]; then
    tmp="$(mktemp "${node_orch_path}.corr.XXXXXX")" || return 0
    if jq --arg id "$node_id" \
      '(.stages[] | select(.id == $id) | .sessionStrategy) = "resume"
       | (.stages[] | select(.id == $id) | .sessionResume) = true' \
      "$node_orch_path" >"$tmp"; then
      mv -f "$tmp" "$node_orch_path" || rm -f "$tmp"
    else
      rm -f "$tmp"
    fi
  fi
  return 0
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

# Each graph node admits as one parent-process slot. Resolved nativeSubagents
# is opaque and does not change slot count.
_graph_schedule_slots_for_node() {
  printf '1\n'
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
  local decision="$1" kind="$2" owner="$3" runtime="$4" native_subagents="$5" slots="$6" token_slots="$7" reason="$8"
  local safe=false effective isolation used=0 line
  if [[ -z "${GRAPH_SCHEDULE_LOG_RUN_DIR:-}" && -z "${GRAPH_SCHEDULE_ADMISSION_LOG_FILE:-}" ]]; then
    return 0
  fi
  graph_runtime_same_runtime_parallel_safe "$runtime" && safe=true
  effective="$(_graph_schedule_runtime_cap "$runtime")"
  isolation="$(graph_runtime_overlay_isolation "$runtime")"
  if _graph_schedule_runtime_map_index "$runtime"; then used="${GRAPH_RUNTIME_USED_SLOTS[$GRAPH_RUNTIME_LOOKUP_IDX]:-0}"; fi
  line="$(jq -cn --arg ts "$(graph_state_now_iso)" --arg event admission --arg decision "$decision" \
    --arg workKind "$kind" --arg ownerId "$owner" --arg runtime "$runtime" --arg nativeSubagents "$native_subagents" \
    --arg isolation "$isolation" --arg reason "$reason" --argjson sameRuntimeParallelSafe "$safe" \
    --argjson requestedRuntimeCap "$GRAPH_SCHEDULE_MAX_PARALLEL_PER_RUNTIME" --argjson effectiveRuntimeCap "$effective" \
    --argjson runtimeUsed "$used" --argjson runtimeSlots "$slots" --argjson tokenUsed "$GRAPH_SCHEDULE_USED_TOKEN_SLOTS" \
    --argjson tokenSlots "$token_slots" --argjson tokenCap "$GRAPH_SCHEDULE_TOKEN_CAP" \
    '{timestamp:$ts,event:$event,decision:$decision,workKind:$workKind,ownerId:$ownerId,runtime:$runtime,nativeSubagents:$nativeSubagents,sameRuntimeParallelSafe:$sameRuntimeParallelSafe,overlayIsolation:$isolation,requestedRuntimeCap:$requestedRuntimeCap,effectiveRuntimeCap:$effectiveRuntimeCap,runtimeUsed:$runtimeUsed,runtimeSlots:$runtimeSlots,tokenUsed:$tokenUsed,tokenSlots:$tokenSlots,tokenCap:$tokenCap,reason:$reason}')" || return 0
  if [[ -n "${GRAPH_SCHEDULE_LOG_RUN_DIR:-}" ]]; then
    graph_logs_append "$GRAPH_SCHEDULE_LOG_RUN_DIR" "$(graph_logs_admission_rel)" "$line" 2>/dev/null || true
    return 0
  fi
  printf '%s\n' "$line" >>"$GRAPH_SCHEDULE_ADMISSION_LOG_FILE" 2>/dev/null || true
}

# Returns 0 when the node can be admitted under runtime and token-stream caps.
_graph_schedule_runtime_can_admit() {
  local runtime="$1" native_subagents="$2" token_slots="${3:-}"
  local used slots_needed effective_cap

  _graph_schedule_runtime_ensure "$runtime" || return 1
  used="${GRAPH_RUNTIME_USED_SLOTS[$GRAPH_RUNTIME_LOOKUP_IDX]:-0}"
  slots_needed="$(_graph_schedule_slots_for_node)"
  [[ "$token_slots" =~ ^[1-9][0-9]*$ ]] || token_slots="$slots_needed"
  effective_cap="$(_graph_schedule_runtime_cap "$runtime")"
  [[ $(( used + slots_needed )) -le "$effective_cap" ]] || return 1
  [[ $(( GRAPH_SCHEDULE_USED_TOKEN_SLOTS + token_slots )) -le "$GRAPH_SCHEDULE_TOKEN_CAP" ]] || return 1
  return 0
}

_graph_schedule_runtime_reserve() {
  local node_id="$1"
  local runtime="$2"
  local native_subagents="$3"
  local slots_needed idx

  if ! _graph_schedule_runtime_can_admit "$runtime" "$native_subagents" ""; then
    echo "Error: runtime $runtime cannot admit node $node_id (nativeSubagents=$native_subagents)" >&2
    return 1
  fi
  _graph_schedule_runtime_ensure "$runtime" || return 1
  slots_needed="$(_graph_schedule_slots_for_node)"
  _graph_schedule_runtime_reserve_slots "$runtime" "$slots_needed" "$slots_needed" || return 1
  if ! idx="$(graph_schedule_index_map_get "$node_id")"; then
    echo "Error: unknown graph node id: $node_id" >&2
    return 1
  fi
  GRAPH_NODE_HELD_SLOTS[$idx]="$slots_needed"
  GRAPH_NODE_HELD_TOKEN_SLOTS[$idx]="$slots_needed"
  _graph_schedule_log_admission "admitted" "graph-node" "$node_id" "$runtime" "$native_subagents" "$slots_needed" "$slots_needed" "runtime-and-token-cap"
  return 0
}

# Release per-runtime slots for a node that reached any terminal state
# (success, failure, cancellation, missing report). Safe to call when the node
# held zero slots.
_graph_schedule_runtime_release() {
  local node_id="$1"
  local idx runtime held held_tokens

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
  GRAPH_NODE_HELD_SLOTS[$idx]="0"
  GRAPH_NODE_HELD_TOKEN_SLOTS[$idx]="0"
  _graph_schedule_log_admission "released" "graph-node" "$node_id" "$runtime" "${GRAPH_NODE_NATIVE_SUBAGENTS[$idx]}" "$held" "$held_tokens" "terminal-state"
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
    child_parent="$(jq -r .parentNodeId <<<"$child_entry")"; child_did="$(jq -r '.delegatedRunId // .delegationId // empty' <<<"$child_entry")"
    child_status="$(graph_delegation_ledger_read_status "$GRAPH_SCHEDULE_WORKSPACE" "$child_did" 2>/dev/null | jq -r '.status // empty')"
    [[ "$child_status" == queued || "$child_status" == running ]] && graph_delegation_child_cancel "$GRAPH_SCHEDULE_WORKSPACE" "${GRAPH_SCHEDULE_LEDGER_NAMESPACE:-$GRAPH_SCHEDULE_NAMESPACE}" "$GRAPH_SCHEDULE_RUN_ID" "$child_parent" "$child_did" || true
  done < <(graph_delegation_queue_pending "$GRAPH_SCHEDULE_WORKSPACE" "${GRAPH_SCHEDULE_LEDGER_NAMESPACE:-$GRAPH_SCHEDULE_NAMESPACE}" "$GRAPH_SCHEDULE_RUN_ID")
  # If this shell owns a process-run registry, stop active scopes too. Child
  # orchestrators that own their own runs still close via their EXIT traps.
  if [[ -n "${RALPH_PROCESS_RUN_DIR:-}" ]]; then
    ralph_process_stop_active "graph-schedule-cancel" || true
  fi
  return 0
}

# Newest regular file matching a glob, or empty. Avoids `ls -t` parsing and
# stays bash 3.2 safe (no readarray).
_graph_schedule_newest_file() {
  local newest="" f
  for f in "$@"; do
    [[ -f "$f" ]] || continue
    if [[ -z "$newest" || "$f" -nt "$newest" ]]; then
      newest="$f"
    fi
  done
  printf '%s\n' "$newest"
}

# _graph_schedule_node_failure_log <node_id>
#
# Resolve the operator-facing log for a failed node. Prefers run-plan's per-plan
# output log (keyed by RALPH_GRAPH_NODE_ID, where the agent CLI's own stderr
# lands) and falls back to the scheduler's attempt log (keyed by the workspace
# node key). Prints nothing when neither exists.
_graph_schedule_node_failure_log() {
  local node_id="$1"
  local run_dir attempt_id="" rel candidate=""

  run_dir="${GRAPH_SCHEDULE_LOG_RUN_DIR:-${GRAPH_SCHEDULE_LEDGER_RUN_DIR:-}}"
  if [[ -n "$run_dir" ]]; then
    local idx attempt_number node_file
    idx="$(graph_schedule_index_map_get "$node_id" 2>/dev/null || true)"
    attempt_number="${GRAPH_NODE_ATTEMPT_NUMBERS[$idx]:-}"
    if [[ -n "$attempt_number" && "$attempt_number" != "0" ]]; then
      attempt_id="$(graph_dispatch_mint_attempt_id "$node_id" "$GRAPH_SCHEDULE_RUN_ID" "$attempt_number" 2>/dev/null || true)"
    fi
    if [[ -z "$attempt_id" ]]; then
      node_file="$(graph_state_node_file "$GRAPH_SCHEDULE_WORKSPACE" "${GRAPH_SCHEDULE_LEDGER_NAMESPACE:-$GRAPH_SCHEDULE_NAMESPACE}" "$GRAPH_SCHEDULE_RUN_ID" "$node_id" 2>/dev/null || true)"
      if [[ -n "$node_file" && -f "$node_file" ]]; then
        attempt_id="$(jq -r '.lastAttemptId // empty' "$node_file" 2>/dev/null || true)"
      fi
    fi
    if [[ -n "$attempt_id" ]]; then
      rel="$(graph_logs_attempt_rel "$run_dir" "$node_id" "$attempt_id" "agent.log" 2>/dev/null || true)"
      [[ -n "$rel" ]] && candidate="$(graph_logs_read "$run_dir" "$rel" 2>/dev/null || true)"
      if [[ -z "$candidate" ]]; then
        rel="$(graph_logs_attempt_rel "$run_dir" "$node_id" "$attempt_id" "runner.log" 2>/dev/null || true)"
        [[ -n "$rel" ]] && candidate="$(graph_logs_read "$run_dir" "$rel" 2>/dev/null || true)"
      fi
    fi
  fi
  printf '%s\n' "$candidate"
}

# _graph_schedule_node_failure_cause <log_path>
#
# Best-effort one-line cause from a node log. Agent CLIs print their fatal error
# as plain text amid Ralph's banners and summary tables, so skip decoration
# (table borders, rules, timestamped runner lines) and take the last real line.
# Truncated hard: provider errors like "Cannot use this model" append the entire
# _graph_schedule_node_failure_recorded_cause
# Cause the stage recorded for itself, from the just-reaped attempt's outcome
# report. Prints nothing when there is no report or no recorded reason, which
# leaves the caller on its log-scraping fallback.
_graph_schedule_node_failure_recorded_cause() {
  local report="${GRAPH_REAP_REPORT_PATH:-}"
  [[ -n "$report" && -f "$report" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r '(.failure.summary // "") as $s
    | (.reason // "") as $r
    | if $s != "" then $s elif $r != "" then $r else "" end' \
    "$report" 2>/dev/null | head -n 1
}

# model catalog, which must never reach the scheduler's stderr.
_graph_schedule_node_failure_cause() {
  local log_path="$1"
  [[ -n "$log_path" && -f "$log_path" ]] || return 0
  tail -n 400 "$log_path" 2>/dev/null | awk '
    /^[[:space:]]*$/ { next }
    /^[+|#=]/ { next }
    /^-{3,}/ { next }
    /^[[:space:]]*\[[0-9][0-9][0-9][0-9]-/ { next }
    { last = $0 }
    END {
      if (last == "") { exit }
      if (length(last) > 200) { last = substr(last, 1, 197) "..." }
      print last
    }'
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
  graph_ui_node "failed" "$node_id" "exit=$GRAPH_SCHEDULE_EXIT_CODE reason=$reason policy=$GRAPH_SCHEDULE_FAILURE_POLICY"
  # Surface the underlying cause. Without this the operator sees only exit=1 and
  # has to hunt for the node log to learn that (for example) the configured
  # model no longer exists.
  local _fail_log _fail_cause
  # Prefer what the stage recorded about itself. The log fallback below is a
  # heuristic -- it prints the last non-boilerplate line -- so when a stage ends
  # without a tidy final error it can surface an unrelated fragment (an echoed
  # TODO line, say) as the cause. The stage outcome carries the reason the
  # runner actually decided on, so use it whenever one exists.
  _fail_cause="$(_graph_schedule_node_failure_recorded_cause)"
  _fail_log="$(_graph_schedule_node_failure_log "$node_id")"
  if [[ -z "$_fail_cause" && -n "$_fail_log" ]]; then
    _fail_cause="$(_graph_schedule_node_failure_cause "$_fail_log")"
  fi
  [[ -n "$_fail_cause" ]] && graph_ui_cause "$_fail_cause"
  [[ -n "$_fail_log" ]] && graph_ui_detail "log: $_fail_log"
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

  # graph_state_validate_node_transition has no direct pending->succeeded or
  # pending->awaiting-ack edge (every other node type passes through
  # running/ready first); record that intermediate "running" transition here
  # so the terminal writes below are legal and actually persist, instead of
  # being silently rejected and leaving the node stuck at "pending" on disk
  # forever (which then blocks manual publish even after this checkpoint
  # truly succeeded).
  _graph_schedule_ledger_record "$node_id" "running" \
    "" "" "" "$(graph_state_now_iso)" "" "" "" "checkpoint-dispatch"

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
  # Checkpoint waits are not active execution and must not charge the clock.
  graph_schedule_pause_active_clock "$node_id" || true
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
# Public Dependency approval node (type: approval)
#
# Distinct from legacy checkpoint/file acknowledgement: creates one common
# workflow action request (kind=approval), freezes evidence hashes, parks the
# node/run as awaiting-operator / waiting, releases scheduler ownership, and
# returns through the schedule loop with exit 3. Never spawns an agent and
# never consumes runtime/concurrency budget. Resume consumes approve exactly
# once; request-changes blocks with exact changesTarget reset argv; cancel
# records durable cancel intent.
# ---------------------------------------------------------------------------

# _graph_schedule_handle_approval_node <node_id>
# Synchronous supervisor gate. No subprocess, no runtime admission.
_graph_schedule_handle_approval_node() {
  local node_id="$1" idx started attempt_id attempt_number activation extra_json
  local registry_run state_root request_id blocker

  if ! idx="$(graph_schedule_index_map_get "$node_id")"; then
    echo "Error: _graph_schedule_handle_approval_node: unknown node id: $node_id" >&2
    return 1
  fi
  if [[ "${GRAPH_NODE_TYPES[$idx]:-}" != "approval" ]]; then
    echo "Error: node $node_id is not type approval" >&2
    return 1
  fi
  if [[ "${GRAPH_NODE_STATES[$idx]}" != "pending" ]]; then
    echo "Error: approval node $node_id not in pending state: ${GRAPH_NODE_STATES[$idx]}" >&2
    return 1
  fi
  [[ -n "$GRAPH_SCHEDULE_LEDGER_RUN_DIR" ]] || {
    _graph_schedule_apply_node_failure "$node_id" 1 "approval-requires-ledger"
    return 1
  }
  [[ -n "${GRAPH_SCHEDULE_GRAPH_JSON:-}" && -f "$GRAPH_SCHEDULE_GRAPH_JSON" ]] || {
    _graph_schedule_apply_node_failure "$node_id" 1 "approval-requires-graph"
    return 1
  }

  if ! declare -F workflow_dep_approval_activate >/dev/null 2>&1; then
    # shellcheck source=../workflow/workflow-engine-dependency.sh
    source "$GRAPH_SCHEDULE_SCRIPT_DIR/../workflow/workflow-engine-dependency.sh"
  fi

  started="$(graph_state_now_iso)"
  attempt_number=$(( ${GRAPH_NODE_ATTEMPT_NUMBERS[$idx]:-0} + 1 ))
  GRAPH_NODE_ATTEMPT_NUMBERS[$idx]="$attempt_number"
  attempt_id="$(graph_dispatch_mint_attempt_id "$node_id" "$GRAPH_SCHEDULE_RUN_ID" "$attempt_number")" || {
    _graph_schedule_apply_node_failure "$node_id" 1 "approval-attempt-id"
    return 1
  }

  # Legal hop pending -> running before awaiting-operator (no agent spawn).
  GRAPH_NODE_STATES[$idx]="running"
  _graph_schedule_ledger_record "$node_id" "running" "$attempt_id" "" "" \
    "$started" "" "" "" "approval-dispatch"

  # Approval time must not charge runtime/concurrency/active-time budgets.
  graph_schedule_pause_active_clock "$node_id" || true
  GRAPH_SCHEDULE_STOP_DISPATCH=0

  # Workflow-backed graph ledgers carry registryRunPath rather than .roots, so
  # derive the workflow state root (<state-root>/workflow-runs/<run-id>) before
  # falling back to the plain-graph roots or the raw workspace.
  state_root="$(jq -r '.roots.stateRoot // empty' "$GRAPH_SCHEDULE_LEDGER_RUN_DIR/run.json" 2>/dev/null || true)"
  if [[ -z "$state_root" ]]; then
    local _sched_registry_run
    _sched_registry_run="$(jq -r '.registryRunPath // empty' "$GRAPH_SCHEDULE_LEDGER_RUN_DIR/run.json" 2>/dev/null || true)"
    if [[ -n "$_sched_registry_run" ]]; then
      state_root="$(dirname -- "$(dirname -- "$_sched_registry_run")")"
    fi
  fi
  [[ -n "$state_root" ]] || state_root="${RALPH_GRAPH_STATE_ROOT:-${RALPH_PLAN_WORKSPACE_ROOT:-}}"
  [[ -n "$state_root" ]] || state_root="${GRAPH_SCHEDULE_WORKSPACE}"

  if ! activation="$(workflow_dep_approval_activate \
      --workspace "$GRAPH_SCHEDULE_WORKSPACE" \
      --namespace "$GRAPH_SCHEDULE_NAMESPACE" \
      --run-id "$GRAPH_SCHEDULE_RUN_ID" \
      --graph-json "$GRAPH_SCHEDULE_GRAPH_JSON" \
      --node-id "$node_id" \
      --attempt-id "$attempt_id" \
      --graph-run-dir "$GRAPH_SCHEDULE_LEDGER_RUN_DIR" \
      --state-root "$state_root")"; then
    echo "Error: approval activation failed for $node_id (missing/mutated evidence or duplicate request)" >&2
    _graph_schedule_apply_node_failure "$node_id" 1 "approval-activate-failed"
    return 1
  fi

  request_id="$(printf '%s' "$activation" | jq -r '.requestId // empty')"
  blocker="$(printf '%s' "$activation" | jq -c '.blocker // null')"
  registry_run="$(printf '%s' "$activation" | jq -r '.registryRun // empty')"
  extra_json="$(jq -cn \
    --arg rid "$request_id" \
    --argjson blocker "$blocker" \
    --arg registryRun "$registry_run" \
    --argjson evidence "$(printf '%s' "$activation" | jq -c '.evidence // []')" \
    '{
      operatorRequestId: $rid,
      workflowActionKind: "approval",
      blocker: $blocker,
      registryRunPath: $registryRun,
      approvalEvidence: $evidence
    }')" || extra_json="{}"

  GRAPH_NODE_STATES[$idx]="awaiting-operator"
  GRAPH_SCHEDULE_AWAITING_OPERATOR=1
  if [[ "$GRAPH_SCHEDULE_EXIT_CODE" -eq 0 ]]; then
    GRAPH_SCHEDULE_EXIT_CODE=3
  fi
  _graph_schedule_ledger_record "$node_id" "awaiting-operator" \
    "$attempt_id" "awaiting-operator" "3" "$started" "$(graph_state_now_iso)" \
    "" "" "human-approval" "$extra_json"
  _graph_schedule_log_observability "operator-request" "$node_id" "$attempt_id" "" "" \
    "$(jq -cn --arg rid "$request_id" --arg kind approval '{requestId:$rid,kind:$kind}')"
  _graph_schedule_mark_blocked_descendants "$node_id"
  echo "graph-schedule: node=$node_id awaiting-operator (Dependency approval; exit 3; no runtime) request=$request_id" >&2
  return 0
}

# _graph_schedule_resume_approval_node <node_id>
# Consume a common approval decision once while parked awaiting-operator.
# Returns 0 when still waiting / terminalized; 1 when the node should continue
# scheduling (should not happen for approval — approve succeeds the gate).
_graph_schedule_resume_approval_node() {
  local node_id="$1" idx run_dir registry_run request_id result outcome
  local started finished extra_json state_root

  if ! idx="$(graph_schedule_index_map_get "$node_id")"; then
    return 1
  fi
  [[ "${GRAPH_NODE_TYPES[$idx]:-}" == "approval" ]] || return 1
  [[ "${GRAPH_NODE_STATES[$idx]}" == "awaiting-operator" ]] || return 1
  run_dir="${GRAPH_SCHEDULE_LEDGER_RUN_DIR:-}"
  [[ -n "$run_dir" && -d "$run_dir" ]] || return 1

  if ! declare -F workflow_dep_approval_apply_decision >/dev/null 2>&1; then
    # shellcheck source=../workflow/workflow-engine-dependency.sh
    source "$GRAPH_SCHEDULE_SCRIPT_DIR/../workflow/workflow-engine-dependency.sh"
  fi
  if ! declare -F workflow_dep_registry_run_from_graph >/dev/null 2>&1; then
    source "$GRAPH_SCHEDULE_SCRIPT_DIR/../workflow/workflow-engine-dependency.sh"
  fi

  registry_run="$(workflow_dep_registry_run_from_graph "$run_dir")" || return 1
  request_id="$(jq -r --arg id "$node_id" '
      .blocker.requestId // .operatorRequestId // empty
    ' "$(graph_state_node_file "$GRAPH_SCHEDULE_WORKSPACE" "$GRAPH_SCHEDULE_LEDGER_NAMESPACE" "$GRAPH_SCHEDULE_RUN_ID" "$node_id")" 2>/dev/null || true)"
  if [[ -z "$request_id" ]]; then
    # Fall back to listing common approval requests for this stage.
    request_id="$(workflow_action_list "$registry_run" 2>/dev/null \
      | jq -r --arg sid "$node_id" \
        '[.[] | select(.kind=="approval" and .stageId==$sid and .consumed==null)][0].requestId // empty')"
  fi
  if [[ -z "$request_id" ]]; then
    echo "graph-resume: node=$node_id Dependency approval still waiting (no decision)" >&2
    GRAPH_SCHEDULE_AWAITING_OPERATOR=1
    return 0
  fi

  state_root="$(jq -r '.roots.stateRoot // empty' "$run_dir/run.json" 2>/dev/null || true)"
  [[ -n "$state_root" ]] || state_root="${GRAPH_SCHEDULE_WORKSPACE}"

  result="$(workflow_dep_approval_apply_decision \
    --registry-run "$registry_run" \
    --request-id "$request_id" \
    --run-id "$GRAPH_SCHEDULE_RUN_ID" \
    --state-root "$state_root")" || {
    local rc=$?
    if [[ "$rc" -eq 2 ]]; then
      echo "graph-resume: node=$node_id Dependency approval unresolved; staying awaiting-operator" >&2
      GRAPH_SCHEDULE_AWAITING_OPERATOR=1
      return 0
    fi
    echo "Error: Dependency approval decision refused for $node_id ($request_id)" >&2
    _graph_schedule_apply_node_failure "$node_id" 1 "approval-decision-refused"
    return 1
  }

  outcome="$(printf '%s' "$result" | jq -r '.outcome // empty')"
  started="$(graph_state_now_iso)"
  finished="$started"
  extra_json="$(jq -cn --argjson r "$result" --arg rid "$request_id" \
    '$r + {operatorRequestId:$rid,workflowActionKind:"approval"}')"

  case "$outcome" in
    approved)
      # awaiting-operator -> running -> succeeded (legal hop).
      _graph_schedule_ledger_record "$node_id" "running" \
        "" "" "" "$started" "" "" "" "approval-resume"
      GRAPH_NODE_STATES[$idx]="succeeded"
      _graph_schedule_ledger_record "$node_id" "succeeded" \
        "" "success" "0" "$started" "$finished" "" "" "approval-approved" "$extra_json"
      _graph_schedule_log_observability "operator-decision" "$node_id" "" "" "" \
        "$(jq -cn --arg rid "$request_id" '{requestId:$rid,decision:"approve"}')"
      _graph_schedule_restore_blocked_descendants "$node_id" || true
      _graph_schedule_release_successors "$node_id" || true
      echo "graph-resume: node=$node_id Dependency approval approved; gate succeeded (consumed once)" >&2
      return 0
      ;;
    changes-requested)
      _graph_schedule_ledger_record "$node_id" "running" \
        "" "" "" "$started" "" "" "" "approval-resume"
      GRAPH_NODE_STATES[$idx]="blocked"
      _graph_schedule_ledger_record "$node_id" "blocked" \
        "" "blocked" "1" "$started" "$finished" "" "" "human-changes-requested" "$extra_json"
      _graph_schedule_log_observability "operator-decision" "$node_id" "" "" "" \
        "$(jq -cn --arg rid "$request_id" '{requestId:$rid,decision:"request-changes"}')"
      _graph_schedule_mark_blocked_descendants "$node_id"
      if [[ -z "$GRAPH_SCHEDULE_FAILED_NODE" ]]; then
        GRAPH_SCHEDULE_FAILED_NODE="$node_id"
      fi
      GRAPH_SCHEDULE_EXIT_CODE=1
      echo "graph-resume: node=$node_id Dependency approval request-changes; blocked with changesTarget reset argv" >&2
      return 0
      ;;
    cancelled)
      GRAPH_NODE_STATES[$idx]="cancelled"
      _graph_schedule_ledger_record "$node_id" "cancelled" \
        "" "cancelled" "1" "$started" "$finished" "" "" "approval-cancelled" "$extra_json"
      _graph_schedule_log_observability "operator-decision" "$node_id" "" "" "" \
        "$(jq -cn --arg rid "$request_id" '{requestId:$rid,decision:"cancel"}')"
      _graph_schedule_mark_blocked_descendants "$node_id"
      GRAPH_SCHEDULE_EXIT_CODE=1
      echo "graph-resume: node=$node_id Dependency approval cancelled; durable cancel intent recorded" >&2
      return 0
      ;;
    *)
      echo "Error: unknown approval resume outcome: $outcome" >&2
      return 1
      ;;
  esac
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
  # conditional-outcomes) it propagates through failurePolicy like any
  # other node failure.
  _graph_schedule_apply_node_failure "$node_id" "$join_rc" "consensus-decision-not-approved"
  return 1
}

# _graph_schedule_handle_join_node <node_id>
# Only called for join-typed nodes with no declared runtime (see the dispatch
# loop); nodes with a runtime fall through to ordinary agent dispatch.
_graph_schedule_handle_join_node() {
  local node_id="$1"
  local idx now

  if ! idx="$(graph_schedule_index_map_get "$node_id")"; then
    echo "Error: _graph_schedule_handle_join_node: unknown node id: $node_id" >&2
    return 1
  fi
  if [[ "${GRAPH_NODE_STATES[$idx]}" != "pending" ]]; then
    echo "Error: join node $node_id not in pending state: ${GRAPH_NODE_STATES[$idx]}" >&2
    return 1
  fi

  now="$(graph_state_now_iso)"
  # graph_state_validate_node_transition rejects pending->succeeded (same trap
  # as checkpoint). Record the intermediate running write so the terminal
  # succeeded status actually persists; otherwise the in-memory join looks
  # done while the on-disk ledger stays pending and publish refuses the run.
  _graph_schedule_ledger_record "$node_id" "running" \
    "" "" "" "$now" "" "" "" "join-passthrough"
  GRAPH_NODE_STATES[$idx]="succeeded"
  _graph_schedule_ledger_record "$node_id" "succeeded" \
    "" "success" "0" "$now" "$now" "" "" "join-passthrough"
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
#   [exit_code] [started_at] [finished_at] [runtime] [nativeSubagents] [reason]
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
# into the attempt when one is supplied). It records observability
# metadata produced during admission, workspace setup, gate execution,
# integration, delegation, repair, and publish.
_graph_schedule_ledger_record() {
  [[ -z "$GRAPH_SCHEDULE_LEDGER_RUN_DIR" ]] && return 0
  local node_id="$1" state="$2" attempt_id="${3:-}" outcome="${4:-}"
  local exit_code="${5:-}" started_at="${6:-}" finished_at="${7:-}"
  local runtime="${8:-}" native_subagents="${9:-}" reason="${10:-}"
  local extra_json="${11:-}"
  local budget_extra merged_extra
  budget_extra="$(_graph_schedule_budget_extra_json "$node_id" 2>/dev/null || true)"
  if [[ -n "$budget_extra" ]]; then
    merged_extra="$(_graph_schedule_merge_ledger_extra "$extra_json" "$budget_extra" 2>/dev/null || true)"
    if [[ -n "$merged_extra" ]]; then
      extra_json="$merged_extra"
    fi
  fi

  # Graph runs have one canonical ledger shape. Never branch on an old
  # schema or emit a second attempt representation.
  local attempt_fields_json='{}' log_paths_json=""
  if [[ -n "$attempt_id" ]]; then
    if [[ -n "${GRAPH_SCHEDULE_LOG_RUN_DIR:-}" ]]; then
      log_paths_json="$(graph_logs_attempt_paths_json "$GRAPH_SCHEDULE_LOG_RUN_DIR" "$node_id" "$attempt_id" 2>/dev/null || true)"
    fi
    [[ -n "$log_paths_json" ]] || log_paths_json="null"
    attempt_fields_json="$(jq -cn \
        --arg outcome "$outcome" --arg startedAt "$started_at" --arg finishedAt "$finished_at" \
        --arg runtime "$runtime" --arg nativeSubagents "$native_subagents" --arg reason "$reason" \
        --arg exitCode "$exit_code" \
        --argjson logPaths "$log_paths_json" \
        '{}
         + (if $outcome == "" then {} else {outcome: $outcome} end)
         + (if $startedAt == "" then {} else {startedAt: $startedAt} end)
         + (if $finishedAt == "" then {} else {finishedAt: $finishedAt} end)
         + (if $runtime == "" then {} else {runtime: $runtime} end)
         + (if $nativeSubagents == "" then {} else {nativeSubagents: $nativeSubagents} end)
         + (if $reason == "" then {} else {reason: $reason} end)
         + (if ($exitCode | test("^-?[0-9]+$")) then {exitCode: ($exitCode | tonumber)} else {} end)
         + (if $logPaths == null then {} else {logPaths: $logPaths} end)' \
      2>/dev/null)" || attempt_fields_json='{}'
  fi
  graph_state_write_node \
    "$GRAPH_SCHEDULE_WORKSPACE" "$GRAPH_SCHEDULE_LEDGER_NAMESPACE" \
    "$GRAPH_SCHEDULE_RUN_ID" "$node_id" "$state" \
    "$attempt_id" "$attempt_fields_json" "$extra_json" 2>/dev/null || true
  # Emit a corresponding event to the run journal. The event type
  # is derived from the node state; terminal states carry outcome/exitCode in
  # details so status/render/TUI can build a timeline without parsing text logs.
  local event_type="" event_details='{}'
  case "$state" in
    ready) event_type="node-ready" ;;
    running)
      if [[ -n "$attempt_id" ]]; then
        event_type="node-spawn"
      else
        event_type="node-running-update"
      fi
      ;;
    succeeded|failed|cancelled)
      event_type="node-terminal"
      event_details="$(jq -cn --arg outcome "$outcome" --arg exitCode "$exit_code" \
        '{outcome:(if $outcome == "" then null else $outcome end),exitCode:(if ($exitCode | test("^-?[0-9]+$")) then ($exitCode | tonumber) else null end)}' 2>/dev/null)" || event_details='{}'
      ;;
    retry-wait) event_type="node-retry-wait" ;;
    awaiting-operator) event_type="node-awaiting-operator" ;;
    needs-plan-repair) event_type="node-needs-plan-repair" ;;
    interrupted) event_type="node-interrupted" ;;
    blocked) event_type="node-ready" ;;
    skipped) event_type="node-skipped" ;;
  esac
  if [[ -n "$event_type" ]]; then
    if [[ -n "$extra_json" ]] && printf '%s' "$extra_json" | jq -e . >/dev/null 2>&1; then
      event_details="$(printf '%s\n%s\n' "$event_details" "$extra_json" | jq -cs 'reduce .[] as $o ({}; . + $o)' 2>/dev/null)" || event_details='{}'
    fi
    _graph_schedule_log_observability "$event_type" "$node_id" "$attempt_id" "$runtime" "$native_subagents" "$event_details"
  fi

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
  elif [[ "$declared" == .ralph-workspace/* ]]; then
    # .ralph-workspace is a control root and is never part of an isolated
    # node's snapshot; agents always write these paths straight into the
    # shared state root (matching _graph_schedule_artifact_exchange_path),
    # so there is no separate node-local copy to stage or look for.
    printf '%s/%s\n' "$state_root" "${declared#.ralph-workspace/}"
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
    declared="${declared//\{\{ARTIFACT_NS\}\}/$GRAPH_SCHEDULE_NAMESPACE}"
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
  GRAPH_SCHEDULE_LAST_MISSING_ARTIFACT=""
  [[ "$node_workspace" != "$GRAPH_SCHEDULE_WORKSPACE" ]] || return 0
  while IFS=$'\t' read -r declared required || [[ -n "$declared" ]]; do
    [[ -n "$declared" ]] || continue
    declared="${declared//\{\{ARTIFACT_NS\}\}/$GRAPH_SCHEDULE_NAMESPACE}"
    canonical="$(_graph_schedule_artifact_exchange_path "$declared" "$state_root" "$GRAPH_SCHEDULE_NAMESPACE")" || return 1
    local_path="$(_graph_schedule_artifact_local_path "$declared" "$node_workspace" "$state_root")" || return 1
    if [[ "$local_path" == "$canonical" ]]; then
      if [[ "$required" == "true" && ( ! -f "$canonical" || ! -s "$canonical" ) ]]; then
        GRAPH_SCHEDULE_LAST_MISSING_ARTIFACT="$declared"
        return 1
      fi
      continue
    fi
    if [[ ! -f "$local_path" || ! -s "$local_path" ]]; then
      [[ "$required" != "true" ]] && continue
      GRAPH_SCHEDULE_LAST_MISSING_ARTIFACT="$declared"
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
  local node_orch_dir node_orch_path session_key runtime native_subagents node_policy
  local node_workspace state_root node_plan_rel node_plan_source node_plan_target node_path_key tooling_root
  local changeset_baseline="" changeset_scopes="" changeset_mode="" changeset_base_identity=""
  local planfrom_planner="" planfrom_binding="" registry_run_path="" planfrom_force_fresh=0
  local provided_kind="" provided_binding="" provided_force_fresh=0

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
  native_subagents="${GRAPH_NODE_NATIVE_SUBAGENTS[$idx]}"
  node_path_key="$(graph_workspace_node_key "$node_id")" || return 1
  node_policy="$(jq -c --arg id "$node_id" '
    .nodes[] | select(.id == $id) | .stage as $stage |
    (($stage.delegation // {}) + {
      parentWorkspaceMode: ($stage.workspaceMode // "shared"),
      parentWriteScopes: ($stage.writeScopes // [])
    })
  ' "$GRAPH_SCHEDULE_GRAPH_JSON" 2>/dev/null)" || node_policy='{}'

  # Ordinary planFrom consumers: validate immutable source + create/reuse the
  # control copy before runtime or workspace admission. Missing/stale evidence
  # must fail closed here. Generated-plan rework clones always get a fresh
  # control from the same frozen planner source (review edge is feedback only).
  planfrom_planner="$(graph_dispatch_node_planfrom_id "$GRAPH_SCHEDULE_GRAPH_JSON" "$node_id")"
  provided_kind="$(graph_dispatch_node_provided_plan_kind "$GRAPH_SCHEDULE_GRAPH_JSON" "$node_id")"
  attempt_number=$(( ${GRAPH_NODE_ATTEMPT_NUMBERS[$idx]} + 1 ))
  if [[ -n "$planfrom_planner" ]]; then
    if [[ -n "$GRAPH_SCHEDULE_LEDGER_RUN_DIR" && -f "$GRAPH_SCHEDULE_LEDGER_RUN_DIR/run.json" ]]; then
      registry_run_path="$(jq -r '.registryRunPath // empty' "$GRAPH_SCHEDULE_LEDGER_RUN_DIR/run.json")"
    fi
    if [[ -z "$registry_run_path" ]]; then
      registry_run_path="${RALPH_WORKFLOW_REGISTRY_RUN:-}"
    fi
    if [[ -z "$registry_run_path" || ! -d "$registry_run_path" ]]; then
      echo "Error: planFrom node $node_id requires a workflow registry run before admission" >&2
      return 1
    fi
    if ! declare -F workflow_state_bind_generated_plan_control >/dev/null 2>&1; then
      # shellcheck source=../workflow/workflow-state.sh
      source "$GRAPH_SCHEDULE_SCRIPT_DIR/../workflow/workflow-state.sh"
    fi
    planfrom_force_fresh=0
    if [[ "$(jq -r --arg id "$node_id" '
        .nodes[] | select(.id == $id) | .derivedFrom // empty
      ' "$GRAPH_SCHEDULE_GRAPH_JSON" 2>/dev/null)" == "rework" ]]; then
      planfrom_force_fresh=1
    fi
    planfrom_binding="$(
      if [[ "$planfrom_force_fresh" -eq 1 ]]; then
        workflow_state_bind_generated_plan_control \
          --registry-run "$registry_run_path" \
          --consumer-stage-id "$node_id" \
          --consumer-attempt "$attempt_number" \
          --planner-stage-id "$planfrom_planner" \
          --graph-workspace "$GRAPH_SCHEDULE_WORKSPACE" \
          --namespace "${GRAPH_SCHEDULE_LEDGER_NAMESPACE:-$GRAPH_SCHEDULE_NAMESPACE}" \
          --run-id "$GRAPH_SCHEDULE_RUN_ID" \
          --plan-run-id "${node_id}__${GRAPH_SCHEDULE_RUN_ID}__${attempt_number}" \
          --force-fresh
      else
        workflow_state_bind_generated_plan_control \
          --registry-run "$registry_run_path" \
          --consumer-stage-id "$node_id" \
          --consumer-attempt "$attempt_number" \
          --planner-stage-id "$planfrom_planner" \
          --graph-workspace "$GRAPH_SCHEDULE_WORKSPACE" \
          --namespace "${GRAPH_SCHEDULE_LEDGER_NAMESPACE:-$GRAPH_SCHEDULE_NAMESPACE}" \
          --run-id "$GRAPH_SCHEDULE_RUN_ID" \
          --plan-run-id "${node_id}__${GRAPH_SCHEDULE_RUN_ID}__${attempt_number}"
      fi
    )" || {
      echo "Error: planFrom evidence missing/invalid/stale for $node_id (blocked before workspace/runtime admission)" >&2
      return 1
    }
  elif [[ "$provided_kind" == "provided" ]]; then
    if [[ -n "$GRAPH_SCHEDULE_LEDGER_RUN_DIR" && -f "$GRAPH_SCHEDULE_LEDGER_RUN_DIR/run.json" ]]; then
      registry_run_path="$(jq -r '.registryRunPath // empty' "$GRAPH_SCHEDULE_LEDGER_RUN_DIR/run.json")"
    fi
    if [[ -z "$registry_run_path" ]]; then
      registry_run_path="${RALPH_WORKFLOW_REGISTRY_RUN:-}"
    fi
    if [[ -z "$registry_run_path" || ! -d "$registry_run_path" ]]; then
      echo "Error: provided-plan node $node_id requires a workflow registry run before admission" >&2
      return 1
    fi
    if ! declare -F workflow_state_bind_provided_plan_control >/dev/null 2>&1; then
      # shellcheck source=../workflow/workflow-state.sh
      source "$GRAPH_SCHEDULE_SCRIPT_DIR/../workflow/workflow-state.sh"
    fi
    # Rework clones always receive a fresh control from the frozen source.
    if [[ "$(jq -r --arg id "$node_id" '
        .nodes[] | select(.id == $id) | .derivedFrom // empty
      ' "$GRAPH_SCHEDULE_GRAPH_JSON" 2>/dev/null)" == "rework" ]]; then
      provided_force_fresh=1
    fi
    provided_binding="$(
      if [[ "$provided_force_fresh" -eq 1 ]]; then
        workflow_state_bind_provided_plan_control \
          --registry-run "$registry_run_path" \
          --consumer-stage-id "$node_id" \
          --consumer-attempt "$attempt_number" \
          --plan-run-id "${node_id}__${GRAPH_SCHEDULE_RUN_ID}__${attempt_number}" \
          --force-fresh
      else
        workflow_state_bind_provided_plan_control \
          --registry-run "$registry_run_path" \
          --consumer-stage-id "$node_id" \
          --consumer-attempt "$attempt_number" \
          --plan-run-id "${node_id}__${GRAPH_SCHEDULE_RUN_ID}__${attempt_number}"
      fi
    )" || {
      echo "Error: provided-plan input missing/invalid/corrupt for $node_id (blocked before workspace/runtime admission)" >&2
      return 1
    }
  fi

  _graph_schedule_runtime_reserve "$node_id" "$runtime" "$native_subagents" || return 1
  _graph_schedule_log_transition "graph-schedule: node=$node_id phase=admitted"
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
  _graph_schedule_log_transition "graph-schedule: node=$node_id phase=workspace-ready"
  _graph_schedule_stage_inputs "$node_id" "$node_workspace" "$state_root" || {
    _graph_schedule_runtime_release "$node_id"
    return 1
  }

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
  if [[ -n "$planfrom_binding" ]]; then
    if ! graph_dispatch_apply_planfrom_to_orch "$node_orch_path" "$node_id" \
      "$(printf '%s' "$planfrom_binding" | jq -r '.controlPlanPath')"; then
      _graph_schedule_runtime_release "$node_id"
      return 1
    fi
    if [[ -n "$GRAPH_SCHEDULE_LEDGER_RUN_DIR" ]]; then
      graph_state_persist_plan_progress \
        "$GRAPH_SCHEDULE_WORKSPACE" "${GRAPH_SCHEDULE_LEDGER_NAMESPACE:-$GRAPH_SCHEDULE_NAMESPACE}" \
        "$GRAPH_SCHEDULE_RUN_ID" "$node_id" "$planfrom_binding" || {
          _graph_schedule_runtime_release "$node_id"
          return 1
        }
    fi
  elif [[ -n "$provided_binding" ]]; then
    if ! graph_dispatch_apply_provided_to_orch "$node_orch_path" "$node_id" \
      "$(printf '%s' "$provided_binding" | jq -r '.controlPlanPath')"; then
      _graph_schedule_runtime_release "$node_id"
      return 1
    fi
    if ! graph_dispatch_apply_provided_routing_order "$node_orch_path" "$node_id" \
      "$(printf '%s' "$provided_binding" | jq -r '.sourcePlanPath')"; then
      _graph_schedule_runtime_release "$node_id"
      return 1
    fi
    if [[ -n "$GRAPH_SCHEDULE_LEDGER_RUN_DIR" ]]; then
      graph_state_persist_plan_progress \
        "$GRAPH_SCHEDULE_WORKSPACE" "${GRAPH_SCHEDULE_LEDGER_NAMESPACE:-$GRAPH_SCHEDULE_NAMESPACE}" \
        "$GRAPH_SCHEDULE_RUN_ID" "$node_id" "$provided_binding" || {
          _graph_schedule_runtime_release "$node_id"
          return 1
        }
    fi
  fi
  # Ledger-backed graph runs materialize inline plans under the durable run
  # directory and pass an absolute read path. Never copy those scheduler-owned
  # plans into a model-writable isolated workspace.
  node_plan_rel="$(jq -r --arg id "$node_id" '.stages[] | select(.id == $id) | .plan // empty' "$node_orch_path")"
  # A planFrom / provided control copy is already durable, per-attempt, and
  # outside the node workspace, and it lives under the workflow registry run
  # dir rather than the graph ledger run dir.  The ledger reads TODO progress
  # back from that exact path, so copying it again under
  # orchestration-plans/nodes/ would strand every runner-owned status
  # transition in the copy and leave `ralph workflow status` and resume
  # reading a pristine 0/N control plan for a stage that actually finished.
  local node_plan_is_control=0 _node_plan_binding _node_plan_control
  for _node_plan_binding in "${planfrom_binding:-}" "${provided_binding:-}"; do
    [[ -n "$_node_plan_binding" ]] || continue
    _node_plan_control="$(printf '%s' "$_node_plan_binding" | jq -r '.controlPlanPath // empty')"
    if [[ -n "$_node_plan_control" && "$_node_plan_control" == "$node_plan_rel" ]]; then
      node_plan_is_control=1
      break
    fi
  done
  # Explicit planFile stages are loop state, not project output.  Run them from
  # a durable per-node control copy so runner-owned checkbox transitions never
  # enter the node workspace or its changeset.  Preserve an existing copy on
  # resume: completed TODOs are the idempotency checkpoint inside the node.
  if [[ -n "$node_plan_rel" && "$node_plan_is_control" -eq 0 \
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
  _graph_schedule_prepare_corrective_retry_spawn "$node_id" "$attempt_number" "$node_orch_path"
  _graph_schedule_prepare_operator_decision_spawn "$node_id" "$attempt_number" "$node_orch_path"
  _graph_schedule_prepare_retry_context_spawn "$node_id" "$attempt_number"
  local inject_plan_root="$GRAPH_SCHEDULE_WORKSPACE"
  if [[ -n "$GRAPH_SCHEDULE_LEDGER_RUN_DIR" ]]; then
    inject_plan_root="$GRAPH_SCHEDULE_LEDGER_RUN_DIR"
  fi
  _graph_dispatch_inject_rework_feedback \
    "$GRAPH_SCHEDULE_GRAPH_JSON" \
    "$node_id" \
    "$GRAPH_SCHEDULE_WORKSPACE" \
    "$GRAPH_SCHEDULE_NAMESPACE" \
    "$state_root" \
    "$inject_plan_root" \
    "$node_orch_path" \
    "$GRAPH_SCHEDULE_RUN_ID" || {
    _graph_schedule_runtime_release "$node_id"
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
  _graph_schedule_log_transition "graph-schedule: node=$node_id phase=command-ready"

  # Per-attempt log root under the run directory.
  local log_rel log_paths_json agent_rel usage_rel
  if [[ -z "${GRAPH_SCHEDULE_LOG_RUN_DIR:-}" ]]; then
    GRAPH_SCHEDULE_LOG_RUN_DIR="$(graph_state_run_dir "$GRAPH_SCHEDULE_WORKSPACE" "${GRAPH_SCHEDULE_LEDGER_NAMESPACE:-$GRAPH_SCHEDULE_NAMESPACE}" "$GRAPH_SCHEDULE_RUN_ID")" || return 1
    mkdir -p "$GRAPH_SCHEDULE_LOG_RUN_DIR" || return 1
  fi
  log_paths_json="$(graph_logs_attempt_paths_json "$GRAPH_SCHEDULE_LOG_RUN_DIR" "$node_id" "$attempt_id")" || {
    _graph_schedule_runtime_release "$node_id"
    return 1
  }
  log_rel="$(printf '%s' "$log_paths_json" | jq -r '.runner')"
  agent_rel="$(printf '%s' "$log_paths_json" | jq -r '.agent')"
  usage_rel="$(printf '%s' "$log_paths_json" | jq -r '.usage')"
  log_path="$(graph_logs_prepare_write "$GRAPH_SCHEDULE_LOG_RUN_DIR" "$log_rel")" || {
    _graph_schedule_runtime_release "$node_id"
    return 1
  }
  log_dir="$(dirname "$log_path")"
  graph_logs_prepare_write "$GRAPH_SCHEDULE_LOG_RUN_DIR" "$agent_rel" >/dev/null || true
  graph_logs_prepare_write "$GRAPH_SCHEDULE_LOG_RUN_DIR" "$usage_rel" >/dev/null || true
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
    # Ledger-backed runs key node state by the ledger namespace ("workflow"),
    # which is not the artifact/orchestration namespace above.  Children that
    # write node state back (plan-progress refresh) must address the ledger,
    # not the artifact NS, or the write lands on a node file nobody reads.
    export RALPH_GRAPH_LEDGER_NAMESPACE="${GRAPH_SCHEDULE_LEDGER_NAMESPACE:-$GRAPH_SCHEDULE_NAMESPACE}"
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
    export RALPH_GRAPH_NODE_LOG_DIR="$log_dir"
    export RALPH_GRAPH_RUN_DIR="$GRAPH_SCHEDULE_LOG_RUN_DIR"
    export RALPH_GRAPH_ARTIFACT_EXCHANGE_ROOT="$state_root/artifacts/$GRAPH_SCHEDULE_NAMESPACE/exchange"
    unset RALPH_GRAPH_PROMPT RALPH_PLAN_PROMPT RALPH_GRAPH_RAW_OUTPUT 2>/dev/null || true
    unset RALPH_GRAPH_OPERATOR_DECISION RALPH_GRAPH_APPROVAL_PATH 2>/dev/null || true
    if [[ -n "${GRAPH_SCHEDULE_SPAWN_OPERATOR_RECORD:-}" ]]; then
      # Compact decision record only: adapter continuation or one deny turn.
      export RALPH_GRAPH_OPERATOR_DECISION="$GRAPH_SCHEDULE_SPAWN_OPERATOR_RECORD"
      export RALPH_GRAPH_APPROVAL_PATH="${GRAPH_SCHEDULE_SPAWN_OPERATOR_PATH_KIND:-}"
      if [[ "${GRAPH_SCHEDULE_SPAWN_OPERATOR_PATH_KIND:-}" == "adapter-continuation" ]]; then
        export RALPH_PLAN_CLI_RESUME=1
        export RALPH_PLAN_SESSION_STRATEGY=resume
      fi
    fi
    if [[ -n "${GRAPH_SCHEDULE_SPAWN_CORRECTION_RECORD:-}" ]]; then
      # Next supported session turn: compact correction record only.
      export RALPH_GRAPH_CORRECTION_RECORD="$GRAPH_SCHEDULE_SPAWN_CORRECTION_RECORD"
      export RALPH_PLAN_CLI_RESUME=1
      export RALPH_PLAN_SESSION_STRATEGY=resume
    else
      unset RALPH_GRAPH_CORRECTION_RECORD 2>/dev/null || true
    fi
    if [[ -n "${GRAPH_SCHEDULE_SPAWN_RETRY_CONTEXT:-}" ]]; then
      # Compact retry prompt: identity, classification, correction, artifacts, log refs.
      export RALPH_GRAPH_RETRY_CONTEXT="$GRAPH_SCHEDULE_SPAWN_RETRY_CONTEXT"
    else
      unset RALPH_GRAPH_RETRY_CONTEXT 2>/dev/null || true
    fi
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
  _graph_schedule_log_transition "graph-schedule: node=$node_id phase=child-launched pid=$pid"
  printf 'graph-schedule: node=%s state=starting-runtime pid=%s\n' "$node_id" "$pid" >&2
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
  # Active-time clock starts here and pauses on reap/operator/checkpoint/backoff.
  local spawn_started
  spawn_started="$(graph_schedule_active_now_iso)"
  graph_schedule_start_active_clock "$node_id" "$spawn_started"
  _graph_schedule_ledger_record "$node_id" "running" \
    "$attempt_id" "" "" "$spawn_started" "" "$runtime" "$native_subagents" "" "$spawn_context_json"
  _graph_schedule_log_observability "node-spawn" "$node_id" "$attempt_id" "$runtime" "$native_subagents" "$spawn_context_json"
  # Runtime only, from the in-memory index. The spawn path must stay free of
  # subprocesses: an extra jq here delays the next spawn and measurably narrows
  # the window in which sibling nodes actually overlap. The node's agent and
  # model are already listed in the preflight table.
  graph_ui_node "start" "$node_id" "$runtime"
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
  local policy_json native_mode cross_mode idx
  policy_json="$(jq -c --arg id "$node_id" '.nodes[] | select(.id == $id) | (.stage.delegation // {})' "${GRAPH_SCHEDULE_GRAPH_JSON:-}" 2>/dev/null)" || policy_json='{}'
  native_mode="off"
  if idx="$(graph_schedule_index_map_get "$node_id" 2>/dev/null)"; then
    native_mode="${GRAPH_NODE_NATIVE_SUBAGENTS[$idx]:-off}"
  else
    native_mode="$(jq -r --arg id "$node_id" '.nodes[] | select(.id == $id) | .stage.nativeSubagents // "off"' "${GRAPH_SCHEDULE_GRAPH_JSON:-}" 2>/dev/null)" || native_mode="off"
  fi
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

# _graph_schedule_admission_summary_json <node-id> <runtime> <nativeSubagents> [reason]
# Build a compact admission summary object from the scheduler's current
# capacity counters.  The reason defaults to the last recorded decision reason.
_graph_schedule_admission_summary_json() {
  local node_id="$1" runtime="$2" native_subagents="$3" reason="${4:-}"
  local requested effective used slots token_used token_cap
  requested="$(_graph_schedule_slots_for_node)"
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

# _graph_schedule_usage_snapshot_from_report <attempt-id> [node-id]
# Return the attempt usage.json from the run-owned ledger path. Brokered child
# usage lives in their own ledgers and must not be merged here.
_graph_schedule_usage_snapshot_from_report() {
  local attempt_id="$1" node_id="${2:-}"
  local run_dir rel candidate report_path node_log_dir
  run_dir="${GRAPH_SCHEDULE_LOG_RUN_DIR:-${GRAPH_SCHEDULE_LEDGER_RUN_DIR:-}}"
  if [[ -n "$run_dir" && -n "$node_id" ]]; then
    rel="$(graph_logs_attempt_rel "$run_dir" "$node_id" "$attempt_id" "usage.json" 2>/dev/null || true)"
    if [[ -n "$rel" ]]; then
      candidate="$(graph_logs_read "$run_dir" "$rel" 2>/dev/null || true)"
      if [[ -n "$candidate" && -f "$candidate" ]]; then
        jq -c . "$candidate" 2>/dev/null || true
        return 0
      fi
    fi
  fi
  report_path="$(graph_dispatch_report_path "$GRAPH_SCHEDULE_WORKSPACE" "$GRAPH_SCHEDULE_NAMESPACE" "$attempt_id" 2>/dev/null || true)"
  [[ -n "$report_path" ]] || return 0
  node_log_dir="$(dirname "$report_path")"
  node_log_dir="${node_log_dir//stage-outcomes\//\/nodes\/}"
  candidate="$node_log_dir/plan-usage-summary.json"
  if [[ -f "$candidate" ]]; then
    jq -c . "$candidate" 2>/dev/null || true
    return 0
  fi
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
  local extra_json changeset_manifest changeset_hash publish_readiness usage_json idx node_runtime node_native_subagents admission_summary
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
  usage_json="$(_graph_schedule_usage_snapshot_from_report "$attempt_id" "$node_id")"
  idx="$(graph_schedule_index_map_get "$node_id" 2>/dev/null)" || idx=""
  node_runtime="${GRAPH_NODE_RUNTIMES[$idx]:-}"
  node_native_subagents="${GRAPH_NODE_NATIVE_SUBAGENTS[$idx]:-}"
  admission_summary="$(_graph_schedule_admission_summary_json "$node_id" "$node_runtime" "$node_native_subagents" "admitted")"
  local usage_reliable="false" usage_norm=""
  usage_norm="$(graph_schedule_normalize_usage "${usage_json:-}" "")"
  if [[ "$(printf '%s' "$usage_norm" | jq -r '.reliability // empty' 2>/dev/null)" == "authoritative" ]]; then
    usage_reliable="true"
  fi
  extra_json="$(printf '%s' "$extra_json" | jq -c \
    --arg changeset "${changeset_manifest:-}" \
    --arg changesetHash "${changeset_hash:-}" \
    --arg publish "${publish_readiness:-}" \
    --argjson usage "${usage_json:-null}" \
    --argjson admission "${admission_summary:-null}" \
    --argjson usageReliable "$usage_reliable" \
    '. + {
       changesetManifest: (if $changeset == "" then null else $changeset end),
       changesetHash: (if $changesetHash == "" then null else $changesetHash end),
       publishReadiness: (if $publish == "" then null else ($publish | fromjson) end),
       usageSnapshot: (if $usage == null then null else $usage end),
       usageReliable: $usageReliable,
       admissionSummary: (if $admission == null then null else $admission end)
     }')"
  printf '%s\n' "$extra_json"
}

# graph_schedule_report_is_denied_nonessential_diagnostic <report-json-or-path>
# True only for an explicit diagnostic denial with essential=false. Ordinary
# permission requests and essential diagnostics fail closed.
graph_schedule_report_is_denied_nonessential_diagnostic() {
  local input="${1:-}" report=""
  if [[ "$input" == \{* || "$input" == \[* ]]; then
    report="$input"
  elif [[ -n "$input" && -f "$input" ]]; then
    report="$(cat -- "$input" 2>/dev/null || true)"
  else
    return 1
  fi
  [[ -n "$report" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  printf '%s' "$report" | jq -e '
    def lower:
      if . == null then "" else (tostring | ascii_downcase) end;
    def decision_of:
      (.diagnostic.decision // .permissionRequest.decision // .decision // "") | lower;
    def essential_of:
      if (.diagnostic | type) == "object" and (.diagnostic | has("essential")) then
        .diagnostic.essential
      elif (.permissionRequest | type) == "object" and (.permissionRequest | has("essential")) then
        .permissionRequest.essential
      elif has("essential") then .essential
      else null end;
    def diagnostic_marker:
      ((.diagnostic | type) == "object")
      or ((.permissionRequest.kind // .kind // .event // .type // "") | lower | test("diagnostic"));
    (decision_of == "deny" or decision_of == "denied")
    and (essential_of == false)
    and diagnostic_marker
  ' >/dev/null 2>&1
}

# graph_schedule_diagnostic_denial_evidence <report-json-or-path>
# Compact diagnosticEvidence object. No prompts or raw output.
graph_schedule_diagnostic_denial_evidence() {
  local input="${1:-}" report=""
  if [[ "$input" == \{* || "$input" == \[* ]]; then
    report="$input"
  elif [[ -n "$input" && -f "$input" ]]; then
    report="$(cat -- "$input" 2>/dev/null || true)"
  else
    return 1
  fi
  [[ -n "$report" ]] || return 1
  printf '%s' "$report" | jq -c '
    def lower:
      if . == null then "" else (tostring | ascii_downcase) end;
    def decision_of:
      ((.diagnostic.decision // .permissionRequest.decision // .decision // "deny") | lower);
    {
      denied: true,
      essential: false,
      decision: (if decision_of == "denied" or decision_of == "deny" then "deny" else decision_of end),
      kind: "diagnostic"
    }
  ' 2>/dev/null
}

# graph_schedule_record_diagnostic_denial <composite-record-path> <report-json-or-path> [original-report-path]
# Attach diagnosticEvidence to an existing composite success record. Leaves
# components and success status unchanged.
graph_schedule_record_diagnostic_denial() {
  local record_path="$1" report_in="${2:-}" original_report_path="${3:-}"
  local current evidence
  [[ -s "$record_path" ]] || return 1
  evidence="$(graph_schedule_diagnostic_denial_evidence "$report_in")" || return 1
  [[ -n "$evidence" ]] || return 1
  current="$(cat -- "$record_path" 2>/dev/null || true)"
  [[ -n "$current" ]] || return 1
  if [[ -z "$original_report_path" && -n "$report_in" && -f "$report_in" ]]; then
    original_report_path="$report_in"
  fi
  ralph_atomic_write_json "$record_path" \
    '$cur + {diagnosticEvidence:$ev} + (if $rp == "" then {} else {reportPath:$rp} end)' \
    --argjson cur "$current" --argjson ev "$evidence" --arg rp "${original_report_path:-}"
}

# graph_schedule_try_accept_denied_nonessential_diagnostic <report> <graph>
#   <run-file> <node> <run> <attempt> <node-workspace> <state-root>
#   <namespace> <plan> [changeset]
# Accept a denied nonessential diagnostic only when supervisor completion
# evidence is already satisfied. Returns 1 before completion.
graph_schedule_try_accept_denied_nonessential_diagnostic() {
  local report="$1" graph="$2" run_file="$3" node_id="$4" run_id="$5" attempt_id="$6"
  local node_workspace="$7" state_root="$8" namespace="$9" plan_path="${10}" changeset="${11:-}"
  local report_json tmp_report record original_path=""
  GRAPH_SCHEDULE_DIAGNOSTIC_DENIAL_RECORD=""
  if ! graph_schedule_report_is_denied_nonessential_diagnostic "$report"; then
    return 1
  fi
  if [[ "$report" == \{* || "$report" == \[* ]]; then
    report_json="$report"
  elif [[ -n "$report" && -f "$report" ]]; then
    original_path="$report"
    report_json="$(cat -- "$report" 2>/dev/null || true)"
  else
    return 1
  fi
  [[ -n "$report_json" ]] || return 1
  tmp_report="$(mktemp "${TMPDIR:-/tmp}/ralph-diag-success.XXXXXX")" || return 1
  if ! printf '%s' "$report_json" | jq '.outcome = "success" | .exitCode = 0' >"$tmp_report" 2>/dev/null; then
    rm -f "$tmp_report"
    return 1
  fi
  if ! graph_composite_success_validate "$tmp_report" "$graph" "$run_file" "$node_id" \
    "$run_id" "$attempt_id" "$node_workspace" "$state_root" "$namespace" \
    "$plan_path" "$changeset"; then
    rm -f "$tmp_report"
    return 1
  fi
  rm -f "$tmp_report"
  record="${GRAPH_COMPOSITE_SUCCESS_RECORD:-}"
  if [[ -z "$record" || ! -s "$record" ]]; then
    record="$(graph_composite_success_path "$state_root" "$namespace" "$node_id" "$attempt_id")"
  fi
  if ! graph_schedule_record_diagnostic_denial "$record" "$report_json" "$original_path"; then
    return 1
  fi
  GRAPH_SCHEDULE_DIAGNOSTIC_DENIAL_RECORD="$record"
  GRAPH_COMPOSITE_SUCCESS_RECORD="$record"
  return 0
}

_graph_schedule_handle_reaped_node() {
  # Uses GRAPH_REAP_* globals from graph_schedule_reap_one. Returns 0 when the
  # node succeeded or was a non-blocking awaiting-ack / expected cancel / clean
  # interruption, 1 when it was an ordinary failure (also sets
  # GRAPH_SCHEDULE_STOP_DISPATCH).
  # Always releases per-runtime slots so failure/cancellation cannot leak a
  # parent-process runtime admission.
  local idx reap_rc="$1"
  local outcome_ok=0 effective_ec outcome
  # Attempt id is the report filename stem; used to append the attempt to the
  # ledger entry so p3-resume can correlate a running node with its report.
  local attempt_id=""
  if [[ -n "$GRAPH_REAP_REPORT_PATH" ]]; then
    attempt_id="$(basename "$GRAPH_REAP_REPORT_PATH")"
    attempt_id="${attempt_id%.json}"
  fi
  local node_runtime="" node_native_subagents=""
  if idx="$(graph_schedule_index_map_get "$GRAPH_REAP_NODE" 2>/dev/null)"; then
    node_runtime="${GRAPH_NODE_RUNTIMES[$idx]:-}"
    node_native_subagents="${GRAPH_NODE_NATIVE_SUBAGENTS[$idx]:-}"
  fi
  local finished_at
  finished_at="$(graph_schedule_active_now_iso)"
  graph_schedule_commit_active_time "$GRAPH_REAP_NODE" || true
  if [[ -n "$attempt_id" ]]; then
    graph_schedule_record_attempt_usage "$GRAPH_REAP_NODE" "$attempt_id" || true
  fi

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
        "$node_runtime" "$node_native_subagents" "missing-report-after-cancel"
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
        "$node_runtime" "$node_native_subagents" "cancel-outcome=$outcome"
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
        "$node_runtime" "$node_native_subagents" "missing-report"
      echo "graph-schedule: node=$GRAPH_REAP_NODE awaiting-ack exit=3 (missing report)" >&2
      return 0
    fi
    # SIGINT/SIGTERM can stop the stage wrapper before its EXIT trap writes a
    # StageOutcomeReport. That is a resumable interruption, not evidence that
    # the stage itself failed or omitted its report. Keep descendants pending
    # and stop new dispatch so resume can retry this same node cleanly.
    if [[ "$effective_ec" -eq 130 || "$effective_ec" -eq 143 ]]; then
      GRAPH_NODE_STATES[$idx]="interrupted"
      _graph_schedule_runtime_release "$GRAPH_REAP_NODE"
      GRAPH_SCHEDULE_INTERRUPTED=1
      GRAPH_SCHEDULE_STOP_DISPATCH=1
      if [[ "$GRAPH_SCHEDULE_EXIT_CODE" -eq 0 ]]; then
        GRAPH_SCHEDULE_EXIT_CODE="$effective_ec"
      fi
      _graph_schedule_ledger_record "$GRAPH_REAP_NODE" "interrupted" \
        "$attempt_id" "interrupted" "$effective_ec" "" "$finished_at" \
        "$node_runtime" "$node_native_subagents" "signal-exit-without-report"
      echo "graph-schedule: node=$GRAPH_REAP_NODE interrupted exit=$effective_ec (report not persisted; run is resumable)" >&2
      return 0
    fi
    GRAPH_NODE_STATES[$idx]="failed"
    _graph_schedule_runtime_release "$GRAPH_REAP_NODE"
    _graph_schedule_ledger_record "$GRAPH_REAP_NODE" "failed" \
      "$attempt_id" "failed" "$effective_ec" "" "$finished_at" \
      "$node_runtime" "$node_native_subagents" "missing-report"
    _graph_schedule_apply_node_failure "$GRAPH_REAP_NODE" "$effective_ec" "missing-report"
    return 1
  fi

  local diagnostic_candidate=0
  if _graph_schedule_report_is_success "$GRAPH_REAP_REPORT_PATH"; then
    outcome_ok=1
  elif graph_schedule_report_is_denied_nonessential_diagnostic "$GRAPH_REAP_REPORT_PATH"; then
    # Candidate only. The exception applies after supervisor completion
    # evidence is proved below; a failed check falls through as failure.
    diagnostic_candidate=1
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
        "$node_runtime" "$node_native_subagents" "changeset-verification-failed"
      _graph_schedule_try_write_correction_record "$GRAPH_REAP_NODE" "$attempt_id" \
        "$(_graph_schedule_correction_result_for_reason "changeset-verification-failed")"
      _graph_schedule_finish_failed_or_requeue 1 "changeset-verification-failed" "$attempt_id"
      return $?
    fi
    if ! _graph_schedule_publish_stage_artifacts \
      "$GRAPH_REAP_NODE" "$succeeded_workspace" "$succeeded_state_root"; then
      local publish_paths='[]'
      if [[ -n "${GRAPH_SCHEDULE_LAST_MISSING_ARTIFACT:-}" ]]; then
        publish_paths="$(jq -cn --arg p "$GRAPH_SCHEDULE_LAST_MISSING_ARTIFACT" '[$p]')"
      fi
      GRAPH_NODE_STATES[$idx]="failed"
      _graph_schedule_runtime_release "$GRAPH_REAP_NODE"
      _graph_schedule_ledger_record "$GRAPH_REAP_NODE" "failed" \
        "$attempt_id" "failed" "1" "" "$finished_at" \
        "$node_runtime" "$node_native_subagents" "artifact-publish-failed"
      _graph_schedule_try_write_correction_record "$GRAPH_REAP_NODE" "$attempt_id" \
        "$(_graph_schedule_correction_result_for_reason "artifact-publish-failed:${GRAPH_SCHEDULE_LAST_MISSING_ARTIFACT:-}" "$publish_paths")"
      _graph_schedule_finish_failed_or_requeue 1 "artifact-publish-failed" "$attempt_id"
      return $?
    fi
    # A successful subprocess report is only one part of graph-node success.
    # Validate all durable scheduler-owned evidence before publishing the
    # ledger transition that makes descendants runnable.
    # RALPH_GRAPH_COMPOSITE_SUCCESS=1 enables the stronger completion-evidence
    # invariant for this run.
    # A denied nonessential diagnostic is accepted only after that same
    # evidence is already satisfied; the exception does not apply before
    # completion.
    if [[ -n "$GRAPH_SCHEDULE_LEDGER_RUN_DIR" && ( "${RALPH_GRAPH_COMPOSITE_SUCCESS:-0}" == "1" || "$diagnostic_candidate" -eq 1 ) ]]; then
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
      if [[ "$diagnostic_candidate" -eq 1 ]]; then
        if ! graph_schedule_try_accept_denied_nonessential_diagnostic \
          "$GRAPH_REAP_REPORT_PATH" "$GRAPH_SCHEDULE_GRAPH_JSON" "$composite_run_file" \
          "$GRAPH_REAP_NODE" "$GRAPH_SCHEDULE_RUN_ID" "$attempt_id" \
          "$succeeded_workspace" "$succeeded_state_root" "$GRAPH_SCHEDULE_NAMESPACE" \
          "$composite_plan" "$composite_changeset"; then
          local composite_reason="${GRAPH_COMPOSITE_SUCCESS_REASON:-composite-success-failed}"
          local composite_paths
          composite_paths="$(_graph_schedule_correction_paths_from_reason "$composite_reason")"
          GRAPH_NODE_STATES[$idx]="failed"
          _graph_schedule_runtime_release "$GRAPH_REAP_NODE"
          _graph_schedule_ledger_record "$GRAPH_REAP_NODE" "failed" \
            "$attempt_id" "failed" "1" "" "$finished_at" \
            "$node_runtime" "$node_native_subagents" "composite-success-failed:${composite_reason}"
          _graph_schedule_try_write_correction_record "$GRAPH_REAP_NODE" "$attempt_id" \
            "$(_graph_schedule_correction_result_for_reason "$composite_reason" "$composite_paths")"
          _graph_schedule_finish_failed_or_requeue 1 "composite-success-failed" "$attempt_id"
          return $?
        fi
      elif ! graph_composite_success_validate "$GRAPH_REAP_REPORT_PATH" \
        "$GRAPH_SCHEDULE_GRAPH_JSON" "$composite_run_file" "$GRAPH_REAP_NODE" \
        "$GRAPH_SCHEDULE_RUN_ID" "$attempt_id" "$succeeded_workspace" \
        "$succeeded_state_root" "$GRAPH_SCHEDULE_NAMESPACE" "$composite_plan" \
        "$composite_changeset"; then
        local composite_reason="${GRAPH_COMPOSITE_SUCCESS_REASON:-composite-success-failed}"
        local composite_paths
        composite_paths="$(_graph_schedule_correction_paths_from_reason "$composite_reason")"
        GRAPH_NODE_STATES[$idx]="failed"
        _graph_schedule_runtime_release "$GRAPH_REAP_NODE"
        _graph_schedule_ledger_record "$GRAPH_REAP_NODE" "failed" \
          "$attempt_id" "failed" "1" "" "$finished_at" \
          "$node_runtime" "$node_native_subagents" "composite-success-failed:${composite_reason}"
        _graph_schedule_try_write_correction_record "$GRAPH_REAP_NODE" "$attempt_id" \
          "$(_graph_schedule_correction_result_for_reason "$composite_reason" "$composite_paths")"
        _graph_schedule_finish_failed_or_requeue 1 "composite-success-failed" "$attempt_id"
        return $?
      elif graph_schedule_report_is_denied_nonessential_diagnostic "$GRAPH_REAP_REPORT_PATH"; then
        graph_schedule_record_diagnostic_denial \
          "${GRAPH_COMPOSITE_SUCCESS_RECORD:-}" "$GRAPH_REAP_REPORT_PATH" \
          "$GRAPH_REAP_REPORT_PATH" || true
      fi
    elif [[ "$diagnostic_candidate" -eq 1 ]]; then
      GRAPH_NODE_STATES[$idx]="failed"
      _graph_schedule_runtime_release "$GRAPH_REAP_NODE"
      _graph_schedule_ledger_record "$GRAPH_REAP_NODE" "failed" \
        "$attempt_id" "failed" "1" "" "$finished_at" \
        "$node_runtime" "$node_native_subagents" "composite-success-failed:missing-required-evidence"
      _graph_schedule_finish_failed_or_requeue 1 "composite-success-failed" "$attempt_id"
      return $?
    fi
    # Resolve the node's semantic review outcome before touching any
    # succeeded state. A regular agent node with no declared loopCheck
    # resolves "passed" unconditionally; a review node's outcome comes from
    # validating its stage-declared loopCheck artifact (never a role
    # profile). An invalid/missing verdict is a terminal failure of this
    # node and must never pass through "succeeded".
    local agent_review_outcome agent_review_rc=0 agent_review_graph_content=""
    if [[ -n "$GRAPH_SCHEDULE_GRAPH_JSON" && -f "$GRAPH_SCHEDULE_GRAPH_JSON" ]]; then
      agent_review_graph_content="$(cat "$GRAPH_SCHEDULE_GRAPH_JSON")"
    fi
    agent_review_outcome="$(_graph_schedule_agent_conditional_outcome \
      "$GRAPH_REAP_NODE" "$agent_review_graph_content" "$succeeded_state_root" "$GRAPH_SCHEDULE_NAMESPACE")" || agent_review_rc=$?
    if [[ "$agent_review_rc" -eq 1 ]]; then
      _graph_schedule_runtime_release "$GRAPH_REAP_NODE"
      GRAPH_NODE_STATES[$idx]="failed"
      _graph_schedule_ledger_record "$GRAPH_REAP_NODE" "failed" \
        "$attempt_id" "failed" "1" "" "$finished_at" \
        "$node_runtime" "$node_native_subagents" "review-verdict-invalid"
      _graph_schedule_apply_node_failure "$GRAPH_REAP_NODE" 1 "review-verdict-invalid"
      return 1
    fi
    if [[ "$agent_review_rc" -eq 3 ]]; then
      # A valid verdict, but the same blocking finding has outlived the rework
      # budget's usefulness. Fail with a distinct reason so the operator sees
      # "this loop is not converging" rather than a generic exhaustion.
      _graph_schedule_runtime_release "$GRAPH_REAP_NODE"
      GRAPH_NODE_STATES[$idx]="failed"
      _graph_schedule_ledger_record "$GRAPH_REAP_NODE" "failed" \
        "$attempt_id" "failed" "2" "" "$finished_at" \
        "$node_runtime" "$node_native_subagents" "rework-stalled"
      _graph_schedule_apply_node_failure "$GRAPH_REAP_NODE" 2 "rework-stalled"
      return 1
    fi

    # Release unconditional + conditional(<outcome>) successors and skip
    # non-matching conditional branches before this node is allowed to
    # transition to "succeeded". Every failure below must transition this
    # node from "running", never from "succeeded".
    local cond_outcome_rc=0
    _graph_schedule_apply_conditional_outcome "$GRAPH_REAP_NODE" "$agent_review_outcome" || cond_outcome_rc=$?
    if [[ "$cond_outcome_rc" -ne 0 ]]; then
      local cond_fail_reason="successor-release" cond_fail_exit=1
      if [[ "$cond_outcome_rc" -eq 2 && "$agent_review_outcome" == "changes-required" ]]; then
        # Fail-closed exhaustion path: a valid changes-required verdict with
        # no matching conditional(changes-required) edge cannot proceed.
        cond_fail_reason="review-changes-required-no-edge"
        cond_fail_exit=2
      fi
      _graph_schedule_runtime_release "$GRAPH_REAP_NODE"
      GRAPH_NODE_STATES[$idx]="failed"
      _graph_schedule_ledger_record "$GRAPH_REAP_NODE" "failed" \
        "$attempt_id" "failed" "$cond_fail_exit" "" "$finished_at" \
        "$node_runtime" "$node_native_subagents" "$cond_fail_reason"
      _graph_schedule_apply_node_failure "$GRAPH_REAP_NODE" "$cond_fail_exit" "$cond_fail_reason"
      return 1
    fi

    # Executor success and semantic review outcome are distinct: a valid
    # "changes-required" verdict is still a succeeded executor attempt, but
    # observability records the semantic outcome rather than calling it
    # "passed".
    GRAPH_NODE_STATES[$idx]="succeeded"
    _graph_schedule_runtime_release "$GRAPH_REAP_NODE"
    local success_extra_json diag_ev
    success_extra_json="$(_graph_schedule_node_success_observability_json "$GRAPH_REAP_NODE" "$attempt_id" "$succeeded_workspace" "$succeeded_state_root")"
    success_extra_json="$(printf '%s' "$success_extra_json" | jq -c --arg outcome "$agent_review_outcome" '. + {semanticOutcome: $outcome}')"
    if [[ -n "${GRAPH_COMPOSITE_SUCCESS_RECORD:-}" && -s "$GRAPH_COMPOSITE_SUCCESS_RECORD" ]]; then
      diag_ev="$(jq -c '.diagnosticEvidence // empty' "$GRAPH_COMPOSITE_SUCCESS_RECORD" 2>/dev/null || true)"
      if [[ -n "$diag_ev" && "$diag_ev" != "null" ]]; then
        success_extra_json="$(printf '%s' "$success_extra_json" | jq -c --argjson d "$diag_ev" '. + {diagnosticEvidence:$d}')"
      fi
    fi
    _graph_schedule_ledger_record "$GRAPH_REAP_NODE" "succeeded" \
      "$attempt_id" "success" "0" "" "$finished_at" \
      "$node_runtime" "$node_native_subagents" "" "$success_extra_json"
    _graph_schedule_log_observability "node-succeeded" "$GRAPH_REAP_NODE" "$attempt_id" "$node_runtime" "$node_native_subagents" "$success_extra_json"
    graph_ui_node "$agent_review_outcome" "$GRAPH_REAP_NODE" "$node_runtime"
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
      "$node_runtime" "$node_native_subagents" "exit-3"
    echo "graph-schedule: node=$GRAPH_REAP_NODE awaiting-ack exit=3" >&2
    return 0
  fi

  # Exit code 4 (permission request) and every other non-success: classify
  # first. Operator-permission persists a request and pauses as
  # awaiting-operator without consuming a slot, retry, or active-time budget.
  # Plan-contract waits as needs-plan-repair without stopping independent
  # dispatch. outcome=cancelled without an active cancel request is ordinary
  # failure for stop-dispatch purposes (e.g. child self-cancelled).
  if [[ "$outcome" == "cancelled" ]]; then
    GRAPH_NODE_STATES[$idx]="cancelled"
    _graph_schedule_ledger_record "$GRAPH_REAP_NODE" "cancelled" \
      "$attempt_id" "cancelled" "$effective_ec" "" "$finished_at" \
      "$node_runtime" "$node_native_subagents" "outcome=cancelled"
  elif _graph_schedule_result_is_operator_permission "$GRAPH_REAP_REPORT_PATH" "outcome=$outcome"; then
    graph_schedule_apply_operator_permission "$GRAPH_REAP_NODE" "$effective_ec" \
      "operator-permission" "$attempt_id" "$GRAPH_REAP_REPORT_PATH"
    return 0
  elif _graph_schedule_result_is_plan_contract "$GRAPH_REAP_REPORT_PATH" "outcome=$outcome"; then
    GRAPH_NODE_STATES[$idx]="needs-plan-repair"
    _graph_schedule_ledger_record "$GRAPH_REAP_NODE" "needs-plan-repair" \
      "$attempt_id" "$outcome" "$effective_ec" "" "$finished_at" \
      "$node_runtime" "$node_native_subagents" "plan-contract"
    _graph_schedule_runtime_release "$GRAPH_REAP_NODE"
    graph_schedule_apply_plan_contract "$GRAPH_REAP_NODE" "$effective_ec" \
      "plan-contract" "$attempt_id"
    return 1
  else
    GRAPH_NODE_STATES[$idx]="failed"
    _graph_schedule_ledger_record "$GRAPH_REAP_NODE" "failed" \
      "$attempt_id" "$outcome" "$effective_ec" "" "$finished_at" \
      "$node_runtime" "$node_native_subagents" "outcome=$outcome"
    _graph_schedule_try_write_correction_record "$GRAPH_REAP_NODE" "$attempt_id" \
      "$GRAPH_REAP_REPORT_PATH"
  fi
  _graph_schedule_runtime_release "$GRAPH_REAP_NODE"
  if [[ "$outcome" != "cancelled" ]]; then
    _graph_schedule_finish_failed_or_requeue "$effective_ec" "outcome=$outcome" "$attempt_id"
    return $?
  fi
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
  local ready_tmp ready_idx ready_runtime ready_native_subagents

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
    GRAPH_NODE_CORRECTIVE_RETRIES_USED[$i]="0"
    GRAPH_NODE_TRANSIENT_RETRIES_USED[$i]="0"
    GRAPH_NODE_ACTIVE_SECONDS[$i]="0"
    GRAPH_NODE_ACTIVE_STARTED_AT[$i]=""
    GRAPH_NODE_USAGE_JSON[$i]=""
    GRAPH_NODE_OPERATOR_DENY_TURNS_USED[$i]="0"
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
  GRAPH_SCHEDULE_INTERRUPTED=0
  GRAPH_SCHEDULE_CANCEL_REQUESTED=0
  GRAPH_SCHEDULE_AWAITING_ACK=0
  GRAPH_SCHEDULE_AWAITING_OPERATOR=0
  GRAPH_SCHEDULE_OPERATOR_REQUEST_PATH=""
  GRAPH_SCHEDULE_OPERATOR_DECISION_PATH=""
  GRAPH_SCHEDULE_SPAWN_OPERATOR_RECORD=""
  GRAPH_SCHEDULE_SPAWN_OPERATOR_PATH_KIND=""
  GRAPH_HEARTBEAT_LAST_TICK_EPOCH=0
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
  # GRAPH_SCHEDULE_NAMESPACE is the plan/artifact namespace: it is what
  # {{ARTIFACT_NS}} expands to and what spawn_node exports as RALPH_ARTIFACT_NS.
  # It must keep tracking the orchestration plan ("input" for a workflow run).
  GRAPH_SCHEDULE_PLAN_KEY="$GRAPH_SCHEDULE_NAMESPACE"

  # The LEDGER namespace is a different thing: it addresses the durable run
  # state under graph-runs/<ns>/<run-id>. For a plain graph run the two agree.
  # For a workflow run they do not -- the ledger is graph-runs/workflow/<id>
  # while the plan namespace stays "input" -- and defaulting the ledger to the
  # plan namespace aimed every graph_state_* write at graph-runs/input/<id>, a
  # shadow directory holding nothing but nodes/. The real ledger's run.json then
  # kept saying "running" with every node "pending" no matter what happened,
  # because graph_state_set_run_status failed its [[ -f "$run_file" ]] guard
  # silently under `2>/dev/null || true`. Derive it from the ledger dir, which
  # logs, events, and orchestration plans already treat as authoritative.
  GRAPH_SCHEDULE_LEDGER_NAMESPACE="$GRAPH_SCHEDULE_NAMESPACE"
  if [[ -n "$ledger_run_dir" ]]; then
    local _ledger_ns _ledger_ns_dir
    _ledger_ns="$(basename -- "$(dirname -- "$ledger_run_dir")")"
    _ledger_ns_dir="$(graph_state_run_dir "$workspace" "$_ledger_ns" "$run_id" 2>/dev/null || true)"
    if [[ -n "$_ledger_ns" && "$_ledger_ns_dir" == "$ledger_run_dir" ]]; then
      GRAPH_SCHEDULE_LEDGER_NAMESPACE="$_ledger_ns"
    else
      # Not addressable as graph-runs/<ns>/<run-id> under this workspace. Keep
      # the plan namespace rather than aiming state writes somewhere new, and
      # say so instead of failing silently.
      echo "graph-schedule: warning: ledger dir $ledger_run_dir is not addressable as <namespace>/${run_id}; run state may not be durable" >&2
    fi
  fi

  # Public viewer-attached starts create the ledger before they launch this
  # isolated supervisor. Bind durable ownership to this scheduler process,
  # replacing the short-lived startup CLI identity written during init.
  if [[ -n "$ledger_run_dir" ]]; then
    local _scheduler_pid="${GRAPH_STATE_SUPERVISOR_PID:-${BASHPID:-$$}}"
    graph_state_rebind_run_owner \
      "$workspace" "$GRAPH_SCHEDULE_LEDGER_NAMESPACE" "$run_id" "$_scheduler_pid" || return 1
  fi

  # Structured transition log in the same format as the orchestrator log so the
  # logs directory stays greppable. One line per state transition.
  _graph_schedule_bind_run_logs "$run_id" create

  # Seed the run event journal with a run-started record so sequence numbers
  # begin at 1 and readers can always locate the run id and frozen graph.
  if [[ -n "$ledger_run_dir" ]]; then
    graph_events_append "$ledger_run_dir" "$run_id" "run-started" "" "" "{\"graphSha\":\"$(jq -r '.graphSha // empty' "$ledger_run_dir/run.json" 2>/dev/null)\",\"maxParallel\":$GRAPH_SCHEDULE_MAX_PARALLEL}" 2>/dev/null || true
  fi

  # Run header. Everything the operator needs to interpret the lines that follow
  # (and to find the run again later) is stated once, here.
  graph_ui_banner "Ralph graph run" "$GRAPH_SCHEDULE_NAMESPACE"
  graph_ui_kv "run id" "$run_id"
  graph_ui_kv "nodes" "$(jq '.nodes | length' "$graph_json_path" 2>/dev/null || echo '?')"
  graph_ui_kv "max parallel" "$GRAPH_SCHEDULE_MAX_PARALLEL (per runtime: $GRAPH_SCHEDULE_MAX_PARALLEL_PER_RUNTIME)"
  graph_ui_kv "on failure" "$GRAPH_SCHEDULE_FAILURE_POLICY"
  [[ -n "$GRAPH_SCHEDULE_LOG_FILE" ]] && graph_ui_kv "log" "$GRAPH_SCHEDULE_LOG_FILE"
  graph_schedule_agent_model_preflight "$graph_json_path" "$workspace" || return 1
  graph_ui_section "Execution"

  graph_schedule_recover_delegated_children

  ready_tmp="$(mktemp "${TMPDIR:-/tmp}/ralph-graph-ready.XXXXXX")" || return 1

  while true; do
    graph_schedule_tick_heartbeat
    graph_schedule_tick_live_progress
    graph_schedule_enforce_active_time_budgets
    graph_schedule_enforce_usage_budgets
    graph_schedule_release_due_retry_waits
    graph_schedule_drain_delegated_children
    graph_schedule_poll_operator_decisions || true
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
        ready_native_subagents="${GRAPH_NODE_NATIVE_SUBAGENTS[$ready_idx]}"
        # Checkpoint nodes are handled synchronously without spawning a process.
        # They do not consume the spawn budget or go through runtime admission.
        if [[ "${GRAPH_NODE_TYPES[$ready_idx]:-}" == "checkpoint" ]]; then
          _graph_schedule_handle_checkpoint_node "$ready_id" || true
          continue
        fi
        # Public Dependency approval: common action request, exit 3, no agent,
        # no runtime/concurrency budget.
        if [[ "${GRAPH_NODE_TYPES[$ready_idx]:-}" == "approval" ]]; then
          _graph_schedule_handle_approval_node "$ready_id" || true
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
        # Per-runtime capacity may block this node while another
        # ready node on a different runtime remains eligible -- continue, do not break.
        if ! _graph_schedule_runtime_can_admit "$ready_runtime" "$ready_native_subagents" ""; then
          _graph_schedule_log_admission "denied" "graph-node" "$ready_id" "$ready_runtime" "$ready_native_subagents" \
            "$(_graph_schedule_slots_for_node)" "$(_graph_schedule_slots_for_node)" "runtime-or-token-cap"
          local denied_summary
          denied_summary="$(_graph_schedule_admission_summary_json "$ready_id" "$ready_runtime" "$ready_native_subagents" "runtime-or-token-cap")"
          _graph_schedule_ledger_record "$ready_id" "ready" "" "" "" "" "" "" "$ready_runtime" "$ready_native_subagents" "admission-denied" "$denied_summary"
          continue
        fi
        if graph_schedule_active_time_exhausted "$ready_id"; then
          graph_schedule_apply_active_time_exhaustion "$ready_id"
          continue
        fi
        if graph_schedule_usage_should_stop "$ready_id"; then
          graph_schedule_apply_usage_exhaustion "$ready_id"
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
      # ready set before concluding no more progress is possible. A just-
      # consumed operator decision can also requeue a node without a child.
      if graph_schedule_poll_operator_decisions; then
        continue
      fi
      if [[ "$GRAPH_SCHEDULE_STOP_DISPATCH" -eq 0 ]]; then
        graph_schedule_ready_ids >"$ready_tmp"
        if [[ -s "$ready_tmp" ]]; then
          continue
        fi
        if _graph_schedule_sleep_for_retry_wait; then
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

  local final_status="failed"
  _graph_schedule_refresh_awaiting_operator
  if _graph_schedule_all_succeeded; then
    GRAPH_SCHEDULE_EXIT_CODE=0
    final_status="succeeded"
  elif [[ "$GRAPH_SCHEDULE_INTERRUPTED" -eq 1 && -z "$GRAPH_SCHEDULE_FAILED_NODE" ]]; then
    final_status="interrupted"
  elif [[ -z "$GRAPH_SCHEDULE_FAILED_NODE" ]] \
    && ! _graph_schedule_has_runnable_or_running \
    && _graph_schedule_has_unresolved_wait; then
    GRAPH_SCHEDULE_EXIT_CODE=3
    if [[ "$GRAPH_SCHEDULE_AWAITING_OPERATOR" -eq 1 ]]; then
      final_status="awaiting-operator"
    else
      final_status="awaiting-ack"
    fi
  elif [[ "$GRAPH_SCHEDULE_AWAITING_ACK" -eq 1 ]]; then
    if [[ "$GRAPH_SCHEDULE_EXIT_CODE" -eq 0 ]]; then
      GRAPH_SCHEDULE_EXIT_CODE=3
    fi
    final_status="awaiting-ack"
  elif [[ "$GRAPH_SCHEDULE_EXIT_CODE" -eq 0 ]]; then
    GRAPH_SCHEDULE_EXIT_CODE=1
  fi
  if [[ -n "$GRAPH_SCHEDULE_LEDGER_RUN_DIR" ]]; then
    graph_state_set_run_status "$GRAPH_SCHEDULE_WORKSPACE" \
      "$GRAPH_SCHEDULE_LEDGER_NAMESPACE" "$GRAPH_SCHEDULE_RUN_ID" "$final_status" 2>/dev/null || true
    graph_events_append "$GRAPH_SCHEDULE_LEDGER_RUN_DIR" "$GRAPH_SCHEDULE_RUN_ID" "run-status-changed" "" "" "{\"status\":\"$final_status\",\"exitCode\":$GRAPH_SCHEDULE_EXIT_CODE}" 2>/dev/null || true
  fi
  # final_status is only ever succeeded, failed, interrupted, awaiting-ack, or
  # awaiting-operator.
  if [[ "$final_status" == "failed" ]]; then
    _graph_schedule_print_summary "failed"
  elif [[ "$final_status" == "awaiting-operator" ]]; then
    _graph_schedule_print_summary "awaiting-operator"
  elif [[ "$final_status" == "awaiting-ack" ]]; then
    _graph_schedule_print_summary "awaiting-ack"
  else
    _graph_schedule_print_summary "$final_status"
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
# Run-level admission: resume accepts running, interrupted (the status the
# explicit recovery helper writes), awaiting-ack, awaiting-operator,
# succeeded (clean no-op), failed, and cancelled. published and unknown
# statuses are refused. Resume never invokes recovery; status never does
# either. A recovered run must be resumed explicitly after recover.
#
# Node reconciliation:
#   succeeded        -> stays succeeded; skipped with a log line
#   running          -> look for a StageOutcomeReport matching lastAttemptId;
#                       adopt it (mark succeeded/failed per the report) if
#                       present, otherwise reset to pending (the previous
#                       scheduler died mid-flight with no recoverable outcome)
#   interrupted      -> reset to pending (explicit recovery already
#                       terminalized the orphaned attempt)
#   failed/cancelled/blocked -> reset to pending
#   awaiting-ack     -> stays awaiting-ack (human ack is still pending)
#   awaiting-operator -> consume a valid decision once and continue, or stay
#                       awaiting-operator when no decision is present
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
  local node_runtime node_native_subagents finished_at node_file durable_attempt_number

  if ! idx="$(graph_schedule_index_map_get "$node_id")"; then
    echo "Error: reconcile: unknown node id: $node_id" >&2
    return 1
  fi

  status="$(graph_state_node_status "$GRAPH_SCHEDULE_WORKSPACE" \
    "$GRAPH_SCHEDULE_LEDGER_NAMESPACE" "$GRAPH_SCHEDULE_RUN_ID" "$node_id" 2>/dev/null)" || status="pending"
  [[ -z "$status" ]] && status="pending"

  node_runtime="${GRAPH_NODE_RUNTIMES[$idx]}"
  node_native_subagents="${GRAPH_NODE_NATIVE_SUBAGENTS[$idx]}"
  node_file="$(graph_state_node_file "$GRAPH_SCHEDULE_WORKSPACE" \
    "$GRAPH_SCHEDULE_LEDGER_NAMESPACE" "$GRAPH_SCHEDULE_RUN_ID" "$node_id" 2>/dev/null || true)"
  durable_attempt_number=0
  if [[ -n "$node_file" && -f "$node_file" ]]; then
    durable_attempt_number="$(graph_state_max_attempt_number "$node_file")"
    [[ "$durable_attempt_number" =~ ^[0-9]+$ ]] || durable_attempt_number=0
  fi
  GRAPH_NODE_ATTEMPT_NUMBERS[$idx]="$durable_attempt_number"

  case "$status" in
    succeeded)
      # Composite records are written only by newer ledger-backed runs.  Their
      # absence is accepted; when present, a hash
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
      # e.g. inside a repair-epochs round) must replay its recorded
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
          # graph_state_validate_node_transition has no direct
          # awaiting-ack->succeeded edge; record the legal awaiting-ack->
          # running->succeeded hop so this write actually persists instead
          # of being silently rejected and leaving the node stuck at
          # "awaiting-ack" on disk forever (blocking manual publish even
          # though the run itself reports succeeded).
          _graph_schedule_ledger_record "$node_id" "running" \
            "" "" "" "$(graph_state_now_iso)" "" "" "" "checkpoint-resume"
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
    awaiting-operator)
      GRAPH_NODE_STATES[$idx]="awaiting-operator"
      GRAPH_SCHEDULE_AWAITING_OPERATOR=1
      # Public Dependency approval uses common workflow actions, not graph
      # operator/ permission records.
      if [[ "${GRAPH_NODE_TYPES[$idx]:-}" == "approval" ]]; then
        _graph_schedule_resume_approval_node "$node_id" || true
        if [[ "${GRAPH_NODE_STATES[$idx]}" == "succeeded" ]]; then
          return 0
        fi
        if [[ "${GRAPH_NODE_STATES[$idx]}" == "blocked" || "${GRAPH_NODE_STATES[$idx]}" == "cancelled" || "${GRAPH_NODE_STATES[$idx]}" == "failed" ]]; then
          return 1
        fi
        echo "graph-resume: node=$node_id Dependency approval awaiting-operator; skipping" >&2
        return 0
      fi
      if [[ -n "${GRAPH_SCHEDULE_LEDGER_RUN_DIR:-}" ]]; then
        local alt_rel alt_abs op_request_id
        alt_rel="$(graph_schedule_operator_alternative_rel "$node_id" 2>/dev/null || true)"
        if [[ -n "$alt_rel" ]]; then
          alt_abs="$(graph_logs_resolve "$GRAPH_SCHEDULE_LEDGER_RUN_DIR" "$alt_rel" 2>/dev/null || true)"
          if [[ -n "$alt_abs" && -f "$alt_abs" ]]; then
            GRAPH_NODE_OPERATOR_DENY_TURNS_USED[$idx]="1"
          fi
        fi
        op_request_id="$(graph_schedule_operator_request_id_for_node "$node_id" 2>/dev/null || true)"
        if [[ -n "$op_request_id" ]] \
          && graph_operator_decision_read "$GRAPH_SCHEDULE_LEDGER_RUN_DIR" "$op_request_id" >/dev/null 2>&1 \
          && ! graph_schedule_operator_decision_is_consumed "$GRAPH_SCHEDULE_LEDGER_RUN_DIR" "$op_request_id"; then
          graph_schedule_apply_operator_decision "$node_id" "$op_request_id" >/dev/null 2>&1 || true
          if [[ "${GRAPH_NODE_STATES[$idx]}" == "pending" ]]; then
            echo "graph-resume: node=$node_id operator decision consumed; continuing" >&2
            return 1
          fi
          if [[ "${GRAPH_NODE_STATES[$idx]}" == "failed" ]]; then
            echo "graph-resume: node=$node_id operator deny exhausted; failed" >&2
            return 1
          fi
        fi
      fi
      echo "graph-resume: node=$node_id awaiting-operator; skipping" >&2
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
      # Commit any open active-time clock so orphaned execution is kept.
      graph_schedule_commit_active_time "$node_id" || true
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
                    "$node_runtime" "$node_native_subagents" "orphan-workspace-reopen-failed"
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
                "$node_runtime" "$node_native_subagents" "orphan-changeset-verification-failed"
              echo "graph-resume: node=$node_id orphan changeset finalization failed; resetting to pending" >&2
              return 1
            fi
            if ! _graph_schedule_publish_stage_artifacts \
              "$node_id" "$adopted_workspace" "$adopted_state_root"; then
              GRAPH_NODE_STATES[$idx]="pending"
              _graph_schedule_ledger_record "$node_id" "failed" \
                "$last_attempt_id" "failed" "1" "" "$finished_at" \
                "$node_runtime" "$node_native_subagents" "orphan-artifact-publish-failed"
              echo "graph-resume: node=$node_id orphan artifact finalization failed; resetting to pending" >&2
              return 1
            fi
            GRAPH_NODE_STATES[$idx]="succeeded"
            adopted_extra_json="$(_graph_schedule_node_success_observability_json \
              "$node_id" "$last_attempt_id" "$adopted_workspace" "$adopted_state_root")"
            _graph_schedule_ledger_record "$node_id" "succeeded" \
              "$last_attempt_id" "success" "0" "" "$finished_at" \
              "$node_runtime" "$node_native_subagents" "adopted-orphan-report" "$adopted_extra_json"
            _graph_schedule_apply_conditional_outcome "$node_id" "passed" || true
            echo "graph-resume: node=$node_id running -> adopted orphaned report (success); skipping" >&2
            return 0
          fi
          # Non-success report: treat as failed and let the loop retry or block.
          GRAPH_NODE_STATES[$idx]="failed"
          _graph_schedule_ledger_record "$node_id" "failed" \
            "$last_attempt_id" "$outcome" "$exit_code" "" "$finished_at" \
            "$node_runtime" "$node_native_subagents" "adopted-orphan-report"
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
    retry-wait)
      GRAPH_NODE_STATES[$idx]="retry-wait"
      GRAPH_NODE_TRANSIENT_RETRIES_USED[$idx]="$(_graph_schedule_retry_used_from_ledger "$node_id" "transientUsed")"
      local resume_used_c
      resume_used_c="$(_graph_schedule_retry_used_from_ledger "$node_id" "correctiveUsed")"
      if [[ "$resume_used_c" =~ ^[1-9][0-9]*$ ]]; then
        GRAPH_NODE_CORRECTIVE_RETRIES_USED[$idx]="$resume_used_c"
      fi
      graph_schedule_release_due_retry_waits
      if [[ "${GRAPH_NODE_STATES[$idx]}" == "pending" ]]; then
        echo "graph-resume: node=$node_id retry-wait elapsed; continuing" >&2
        return 1
      fi
      echo "graph-resume: node=$node_id retry-wait; skipping until retryAt" >&2
      return 0
      ;;
    failed|cancelled|blocked|pending|ready|interrupted)
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

# graph_schedule_run_status_is_resumable <status>
# Returns 0 when resume may continue a run in <status>. interrupted is the
# status the explicit recovery helper writes; a recovered run is therefore
# resumable without still looking live. published and unknown statuses are
# not resumable. This helper is admission only: it never mutates state and
# never invokes recovery.
graph_schedule_run_status_is_resumable() {
  case "${1:-}" in
    running|interrupted|awaiting-ack|awaiting-operator|succeeded|failed|cancelled) return 0 ;;
    *) return 1 ;;
  esac
}

# graph_schedule_resume <workspace> <namespace> <run_id_or_latest> <plan_path>
#   [--accept-graph-change] [--frozen-graph <path>]
#
# Resumes a graph run. Resolves the run id, recompiles the plan, compares
# graphSha, reconciles node states from the ledger, and continues the
# ready-set loop. Returns the scheduler exit code. Never invokes recovery.
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
  # Fail closed on a stale run or node ledger rather than misreading it.
  if ! graph_state_require_run_schema "$workspace" "$namespace" "$run_id"; then
    return 1
  fi
  local current_status
  current_status="$(jq -r '.status // empty' "$run_file" 2>/dev/null)"
  if ! graph_schedule_run_status_is_resumable "$current_status"; then
    echo "Error: graph_schedule_resume cannot resume run $run_id (status: ${current_status:-<none>})" >&2
    return 1
  fi
  GRAPH_SCHEDULE_LEDGER_RUN_DIR="$(graph_state_run_dir "$workspace" "$namespace" "$run_id")"
  frozen_graph="$(graph_state_graph_file "$workspace" "$namespace" "$run_id")"
  if [[ -n "$frozen_graph_override" ]]; then
    frozen_graph="$frozen_graph_override"
  fi
  if [[ ! -f "$frozen_graph" ]]; then
    echo "Error: graph_schedule_resume frozen graph not found: $frozen_graph" >&2
    return 1
  fi

  local resume_node_id
  while IFS= read -r resume_node_id || [[ -n "$resume_node_id" ]]; do
    [[ -z "$resume_node_id" ]] && continue
    if [[ -f "$(graph_state_node_file "$workspace" "$namespace" "$run_id" "$resume_node_id")" ]]; then
      if ! graph_state_require_node_schema "$workspace" "$namespace" "$run_id" "$resume_node_id"; then
        return 1
      fi
    fi
  done < <(jq -r '.nodes[]?.id // empty' "$frozen_graph" 2>/dev/null)

  old_sha="$(graph_state_field "$run_file" "graphSha")" || old_sha=""

  # Recompile the plan and compare graphSha. Use a temp file so the cached
  # graph beside the plan is not disturbed.
  #
  # The recompile has to reproduce what was frozen, not re-derive it from
  # scratch. A workflow run's artifact namespace is minted once at start and
  # baked into the frozen graph; recompiling without it yields the plan-basename
  # default, a different namespace, and therefore a different graphSha -- so
  # resume would refuse a run whose plan never changed. Replay the frozen
  # namespace over the recompile. Runs whose namespace already matches the
  # default are unaffected, since the override reproduces the same value.
  local _frozen_ns _prev_ns_override _had_ns_override=0
  _frozen_ns="$(jq -r '.namespace // empty' "$frozen_graph" 2>/dev/null || true)"
  if [[ -n "${RALPH_ARTIFACT_NS_OVERRIDE+x}" ]]; then
    _had_ns_override=1
    _prev_ns_override="$RALPH_ARTIFACT_NS_OVERRIDE"
  fi
  if [[ -n "$_frozen_ns" ]]; then
    export RALPH_ARTIFACT_NS_OVERRIDE="$_frozen_ns"
  fi
  new_graph="$(mktemp "${TMPDIR:-/tmp}/ralph-graph-resume.XXXXXX")" || return 1
  if ! graph_compile_plan "$plan_path" "$new_graph" 1 >/dev/null; then
    rm -f "$new_graph"
    if [[ "$_had_ns_override" == "1" ]]; then
      export RALPH_ARTIFACT_NS_OVERRIDE="$_prev_ns_override"
    else
      unset RALPH_ARTIFACT_NS_OVERRIDE
    fi
    echo "Error: graph_schedule_resume failed to recompile plan: $plan_path" >&2
    return 1
  fi
  if [[ "$_had_ns_override" == "1" ]]; then
    export RALPH_ARTIFACT_NS_OVERRIDE="$_prev_ns_override"
  else
    unset RALPH_ARTIFACT_NS_OVERRIDE
  fi
  new_sha="$(graph_state_compute_graph_sha "$new_graph")" || {
    rm -f "$new_graph"
    return 1
  }
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

  # Mark the run as running again and record the resumed state in the event journal.
  graph_state_set_run_status "$workspace" "$namespace" "$run_id" "running" 2>/dev/null || true
  graph_events_append "$GRAPH_SCHEDULE_LEDGER_RUN_DIR" "$run_id" "run-status-changed" "" "" '{"status":"running","reason":"resume"}' 2>/dev/null || true

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
    GRAPH_NODE_CORRECTIVE_RETRIES_USED[$i]="0"
    GRAPH_NODE_TRANSIENT_RETRIES_USED[$i]="0"
    GRAPH_NODE_ACTIVE_SECONDS[$i]="0"
    GRAPH_NODE_ACTIVE_STARTED_AT[$i]=""
    GRAPH_NODE_USAGE_JSON[$i]=""
    GRAPH_NODE_OPERATOR_DENY_TURNS_USED[$i]="0"
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
  GRAPH_SCHEDULE_INTERRUPTED=0
  GRAPH_SCHEDULE_CANCEL_REQUESTED=0
  GRAPH_SCHEDULE_AWAITING_ACK=0
  GRAPH_SCHEDULE_AWAITING_OPERATOR=0
  GRAPH_SCHEDULE_OPERATOR_REQUEST_PATH=""
  GRAPH_SCHEDULE_OPERATOR_DECISION_PATH=""
  GRAPH_SCHEDULE_SPAWN_OPERATOR_RECORD=""
  GRAPH_SCHEDULE_SPAWN_OPERATOR_PATH_KIND=""
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

  # Structured transition log (append to the run-owned supervisor log).
  _graph_schedule_bind_run_logs "$run_id" resume
  graph_schedule_recover_delegated_children

  # Reconcile each node. Succeeded/awaiting-ack/skipped stay; others reset.
  local node_id reapable_ready=0
  _graph_schedule_restore_active_time
  for ((i = 0; i < ${#GRAPH_NODE_IDS[@]}; i++)); do
    node_id="${GRAPH_NODE_IDS[$i]}"
    _graph_schedule_reconcile_node "$node_id" "$frozen_graph" || true
  done
  _graph_schedule_restore_retry_counters

  # Detect a fully completed run: every node is terminal-successful or
  # awaiting-ack/skipped, and none is pending. This is a clean no-op resume.
  local pending_count=0
  for ((i = 0; i < ${#GRAPH_NODE_STATES[@]}; i++)); do
    if [[ "${GRAPH_NODE_STATES[$i]}" == "pending" ]]; then
      pending_count=$((pending_count + 1))
    fi
  done
  if [[ "$pending_count" -eq 0 ]]; then
    local final_status="succeeded"
    _graph_schedule_refresh_awaiting_operator
    if _graph_schedule_all_succeeded; then
      GRAPH_SCHEDULE_EXIT_CODE=0
    elif [[ -z "$GRAPH_SCHEDULE_FAILED_NODE" ]] && _graph_schedule_has_unresolved_wait; then
      GRAPH_SCHEDULE_EXIT_CODE=3
      if [[ "$GRAPH_SCHEDULE_AWAITING_OPERATOR" -eq 1 ]]; then
        final_status="awaiting-operator"
      else
        final_status="awaiting-ack"
      fi
    elif [[ "$GRAPH_SCHEDULE_AWAITING_ACK" -eq 1 ]]; then
      GRAPH_SCHEDULE_EXIT_CODE=3
      final_status="awaiting-ack"
    else
      GRAPH_SCHEDULE_EXIT_CODE=1
      final_status="failed"
    fi
    graph_state_set_run_status "$workspace" "$namespace" "$run_id" "$final_status" 2>/dev/null || true
    graph_events_append "$GRAPH_SCHEDULE_LEDGER_RUN_DIR" "$run_id" "run-status-changed" "" "" "{\"status\":\"$final_status\",\"reason\":\"resume-no-pending\"}" 2>/dev/null || true
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
  local ready_runtime ready_native_subagents ready_tmp

  ready_tmp="$(mktemp "${TMPDIR:-/tmp}/ralph-graph-resume-ready.XXXXXX")" || return 1

  while true; do
    graph_schedule_tick_heartbeat
    graph_schedule_tick_live_progress
    graph_schedule_enforce_active_time_budgets
    graph_schedule_enforce_usage_budgets
    graph_schedule_release_due_retry_waits
    graph_schedule_drain_delegated_children
    graph_schedule_poll_operator_decisions || true
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
        ready_native_subagents="${GRAPH_NODE_NATIVE_SUBAGENTS[$ready_idx]}"
        # Checkpoint nodes are handled synchronously without spawning a process.
        if [[ "${GRAPH_NODE_TYPES[$ready_idx]:-}" == "checkpoint" ]]; then
          _graph_schedule_handle_checkpoint_node "$ready_id" || true
          continue
        fi
        # Public Dependency approval: common action request, exit 3, no agent,
        # no runtime/concurrency budget (mirrors main schedule loop).
        if [[ "${GRAPH_NODE_TYPES[$ready_idx]:-}" == "approval" ]]; then
          _graph_schedule_handle_approval_node "$ready_id" || true
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
        if ! _graph_schedule_runtime_can_admit "$ready_runtime" "$ready_native_subagents" ""; then
          _graph_schedule_log_admission "denied" "graph-node" "$ready_id" "$ready_runtime" "$ready_native_subagents" \
            "$(_graph_schedule_slots_for_node)" "$(_graph_schedule_slots_for_node)" "runtime-or-token-cap"
          local denied_summary
          denied_summary="$(_graph_schedule_admission_summary_json "$ready_id" "$ready_runtime" "$ready_native_subagents" "runtime-or-token-cap")"
          _graph_schedule_ledger_record "$ready_id" "ready" "" "" "" "" "" "" "$ready_runtime" "$ready_native_subagents" "admission-denied" "$denied_summary"
          continue
        fi
        if graph_schedule_active_time_exhausted "$ready_id"; then
          graph_schedule_apply_active_time_exhaustion "$ready_id"
          continue
        fi
        if graph_schedule_usage_should_stop "$ready_id"; then
          graph_schedule_apply_usage_exhaustion "$ready_id"
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
      if graph_schedule_poll_operator_decisions; then
        continue
      fi
      if [[ "$GRAPH_SCHEDULE_STOP_DISPATCH" -eq 0 ]]; then
        graph_schedule_ready_ids >"$ready_tmp"
        if [[ -s "$ready_tmp" ]]; then
          continue
        fi
        if _graph_schedule_sleep_for_retry_wait; then
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

  local final_status="failed"
  _graph_schedule_refresh_awaiting_operator
  if _graph_schedule_all_succeeded; then
    GRAPH_SCHEDULE_EXIT_CODE=0
    final_status="succeeded"
  elif [[ "$GRAPH_SCHEDULE_INTERRUPTED" -eq 1 && -z "$GRAPH_SCHEDULE_FAILED_NODE" ]]; then
    final_status="interrupted"
  elif [[ -z "$GRAPH_SCHEDULE_FAILED_NODE" ]] \
    && ! _graph_schedule_has_runnable_or_running \
    && _graph_schedule_has_unresolved_wait; then
    GRAPH_SCHEDULE_EXIT_CODE=3
    if [[ "$GRAPH_SCHEDULE_AWAITING_OPERATOR" -eq 1 ]]; then
      final_status="awaiting-operator"
    else
      final_status="awaiting-ack"
    fi
  elif [[ "$GRAPH_SCHEDULE_AWAITING_ACK" -eq 1 ]]; then
    if [[ "$GRAPH_SCHEDULE_EXIT_CODE" -eq 0 ]]; then
      GRAPH_SCHEDULE_EXIT_CODE=3
    fi
    final_status="awaiting-ack"
  elif [[ "$GRAPH_SCHEDULE_EXIT_CODE" -eq 0 ]]; then
    GRAPH_SCHEDULE_EXIT_CODE=1
  fi
  graph_state_set_run_status "$workspace" "$GRAPH_SCHEDULE_LEDGER_NAMESPACE" "$run_id" "$final_status" 2>/dev/null || true
  graph_events_append "$GRAPH_SCHEDULE_LEDGER_RUN_DIR" "$run_id" "run-status-changed" "" "" "{\"status\":\"$final_status\",\"exitCode\":$GRAPH_SCHEDULE_EXIT_CODE}" 2>/dev/null || true
  # final_status is only ever succeeded, failed, interrupted, awaiting-ack, or
  # awaiting-operator.
  if [[ "$final_status" == "failed" ]]; then
    _graph_schedule_print_summary "failed"
  elif [[ "$final_status" == "awaiting-operator" ]]; then
    _graph_schedule_print_summary "awaiting-operator"
  elif [[ "$final_status" == "awaiting-ack" ]]; then
    _graph_schedule_print_summary "awaiting-ack"
  else
    _graph_schedule_print_summary "$final_status"
  fi
  return "$GRAPH_SCHEDULE_EXIT_CODE"
}
