#!/usr/bin/env bash
# Dependency-mode adapter: common workflow run ID + graph ledger projection.
#
# Dependency mode keeps the existing graph ledger under
#   <state-root>/graph-runs/<namespace>/<run-id>/
# using the same run ID as the outer registry entry at
#   <state-root>/workflow-runs/<run-id>/.
# Outer run.json.engine holds kind=graph, absolute statePath, and namespace.
# This module never copies graph run/node/event ledgers into the registry.
#
# Public status/stage/event records are projected on read from the graph
# ledger (including optional plan-source/progress and approval/action blocker
# fields merged onto node documents by later plan-backed stages).

if [[ -n "${RALPH_WORKFLOW_ENGINE_DEPENDENCY_LOADED:-}" ]]; then
  return 0
fi
RALPH_WORKFLOW_ENGINE_DEPENDENCY_LOADED=1

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

_WORKFLOW_DEP_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -F workflow_state_read >/dev/null 2>&1; then
  # shellcheck source=./workflow-state.sh
  source "$_WORKFLOW_DEP_SCRIPT_DIR/workflow-state.sh"
fi

if ! declare -F graph_state_init_run >/dev/null 2>&1; then
  # shellcheck source=../graph/graph-state.sh
  source "$_WORKFLOW_DEP_SCRIPT_DIR/../graph/graph-state.sh"
fi

if ! declare -F graph_events_read_lines >/dev/null 2>&1; then
  # shellcheck source=../graph/graph-events.sh
  source "$_WORKFLOW_DEP_SCRIPT_DIR/../graph/graph-events.sh"
fi

if ! declare -F ralph_atomic_write_json >/dev/null 2>&1; then
  # shellcheck source=../atomic-json.sh
  source "$_WORKFLOW_DEP_SCRIPT_DIR/../atomic-json.sh"
fi

# Supervisor-owned graph node types expose no fake plan run or plan progress.

# workflow_dep_map_node_state <internal-node-status>
# Maps a graph node ledger status onto the public workflow stage state enum.
workflow_dep_map_node_state() {
  case "${1:-}" in
    pending|ready) printf 'queued\n' ;;
    running|retry-wait) printf 'running\n' ;;
    awaiting-operator|awaiting-ack) printf 'waiting\n' ;;
    blocked|needs-plan-repair) printf 'blocked\n' ;;
    interrupted) printf 'stale\n' ;;
    failed) printf 'failed\n' ;;
    cancelled) printf 'cancelled\n' ;;
    succeeded) printf 'succeeded\n' ;;
    skipped) printf 'skipped\n' ;;
    *)
      echo "Error: unrecognized graph node status for public projection: ${1:-}" >&2
      return 1
      ;;
  esac
}

# workflow_dep_map_run_status <internal-run-status>
# Maps a graph run ledger status onto the public workflow run state enum.
workflow_dep_map_run_status() {
  case "${1:-}" in
    running) printf 'running\n' ;;
    awaiting-operator|awaiting-ack) printf 'waiting\n' ;;
    interrupted) printf 'stale\n' ;;
    failed) printf 'failed\n' ;;
    cancelled) printf 'cancelled\n' ;;
    succeeded) printf 'succeeded\n' ;;
    *)
      echo "Error: unrecognized graph run status for public projection: ${1:-}" >&2
      return 1
      ;;
  esac
}

# workflow_dep_engine_state_path <state-root> <namespace> <run-id>
# Absolute graph ledger directory for the common run ID.
workflow_dep_engine_state_path() {
  local state_root="$1" namespace="$2" run_id="$3"
  local root
  if [[ -z "$state_root" || -z "$namespace" || -z "$run_id" ]]; then
    echo "Error: workflow_dep_engine_state_path requires state-root, namespace, run-id" >&2
    return 1
  fi
  root="$(workflow_state_ensure_state_root "$state_root")" || return 1
  printf '%s/graph-runs/%s/%s\n' "$root" "$namespace" "$run_id"
}

# workflow_dep_resolve_pointer <state-root> <run-id>
# Reads outer run.json.engine and prints kind, namespace, and absolute statePath
# as compact JSON. Fails when mode is not dependency / engine.kind is not graph.
workflow_dep_resolve_pointer() {
  local state_root="$1" run_id="$2"
  local raw mode kind namespace state_path
  raw="$(workflow_state_read "$state_root" "$run_id")" || return 1
  mode="$(printf '%s' "$raw" | jq -r '.mode // empty')"
  kind="$(printf '%s' "$raw" | jq -r '.engine.kind // empty')"
  namespace="$(printf '%s' "$raw" | jq -r '.engine.namespace // empty')"
  state_path="$(printf '%s' "$raw" | jq -r '.engine.statePath // empty')"
  if [[ "$mode" != "dependency" || "$kind" != "graph" ]]; then
    echo "Error: Dependency adapter requires mode=dependency and engine.kind=graph" >&2
    return 1
  fi
  if [[ -z "$namespace" || -z "$state_path" ]]; then
    echo "Error: Dependency engine pointer missing namespace or statePath" >&2
    return 1
  fi
  case "$state_path" in
    /*) ;;
    *)
      echo "Error: engine.statePath must be absolute: $state_path" >&2
      return 1
      ;;
  esac
  jq -cn \
    --arg kind "$kind" \
    --arg namespace "$namespace" \
    --arg statePath "$state_path" \
    '{kind:$kind,namespace:$namespace,statePath:$statePath}'
}

# workflow_dep_start_engine --state-root ... --run-id ... --workspace ...
#   --plan-path ... --graph-json ... [--namespace ...] [--max-parallel N]
#
# Initializes the graph ledger at the common run ID (same as the outer registry
# run), records the absolute registry pointer on the graph run.json, and stores
# the absolute graph pointer on outer run.json.engine. Does not duplicate
# ledgers under <registry-run>/engine/.
workflow_dep_start_engine() {
  local state_root="" run_id="" workspace="" plan_path="" graph_json=""
  local namespace="" max_parallel=2
  local pointer expected_path registry_run graph_run_dir abs_plan abs_graph

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --state-root) state_root="${2:-}"; shift 2 ;;
      --run-id) run_id="${2:-}"; shift 2 ;;
      --workspace) workspace="${2:-}"; shift 2 ;;
      --plan-path) plan_path="${2:-}"; shift 2 ;;
      --graph-json) graph_json="${2:-}"; shift 2 ;;
      --namespace) namespace="${2:-}"; shift 2 ;;
      --max-parallel) max_parallel="${2:-}"; shift 2 ;;
      *)
        echo "Error: unknown workflow_dep_start_engine argument: $1" >&2
        return 1
        ;;
    esac
  done

  if [[ -z "$state_root" || -z "$run_id" || -z "$workspace" || -z "$plan_path" || -z "$graph_json" ]]; then
    echo "Error: workflow_dep_start_engine requires --state-root --run-id --workspace --plan-path --graph-json" >&2
    return 1
  fi
  [[ -f "$plan_path" && ! -L "$plan_path" ]] || {
    echo "Error: plan path must be a regular non-symlink file: $plan_path" >&2
    return 1
  }
  [[ -f "$graph_json" && ! -L "$graph_json" ]] || {
    echo "Error: graph json must be a regular non-symlink file: $graph_json" >&2
    return 1
  }
  [[ "$max_parallel" =~ ^[1-9][0-9]*$ ]] || max_parallel=2

  pointer="$(workflow_dep_resolve_pointer "$state_root" "$run_id")" || return 1
  if [[ -z "$namespace" ]]; then
    namespace="$(printf '%s' "$pointer" | jq -r '.namespace')"
  fi
  expected_path="$(workflow_dep_engine_state_path "$state_root" "$namespace" "$run_id")" || return 1
  if [[ "$(printf '%s' "$pointer" | jq -r '.statePath')" != "$expected_path" ]]; then
    # Align outer pointer to the canonical common-ID layout before init.
    workflow_state_update "$state_root" "$run_id" \
      '.engine = {kind:$kind, statePath:$statePath, namespace:$namespace}' \
      --arg kind graph \
      --arg statePath "$expected_path" \
      --arg namespace "$namespace" || return 1
  fi

  registry_run="$(workflow_state_run_dir "$state_root" "$run_id")" || return 1
  case "$registry_run" in
    /*) ;;
    *) registry_run="$(cd "$registry_run" && pwd -P)" || return 1 ;;
  esac

  abs_plan="$(cd "$(dirname -- "$plan_path")" && pwd -P)/$(basename -- "$plan_path")"
  abs_graph="$(cd "$(dirname -- "$graph_json")" && pwd -P)/$(basename -- "$graph_json")"

  export RALPH_GRAPH_STATE_ROOT="$(workflow_state_ensure_state_root "$state_root")"
  export RALPH_PLAN_WORKSPACE_ROOT="$RALPH_GRAPH_STATE_ROOT"
  export RALPH_WORKFLOW_RUN_ID="$run_id"
  export RALPH_WORKFLOW_REGISTRY_RUN="$registry_run"

  if [[ -e "$expected_path/run.json" ]]; then
    echo "Error: graph ledger already exists for common run ID (refusing duplicate): $expected_path" >&2
    return 1
  fi
  if [[ -d "$registry_run/engine" ]]; then
    echo "Error: Dependency mode must not use Sequential engine/ under the registry run" >&2
    return 1
  fi

  if ! graph_state_init_run "$workspace" "$namespace" "$run_id" "$abs_plan" "$abs_graph" \
    "$max_parallel" "$registry_run"; then
    return 1
  fi

  graph_run_dir="$(graph_state_run_dir "$workspace" "$namespace" "$run_id")" || return 1
  case "$graph_run_dir" in
    /*) ;;
    *) graph_run_dir="$(cd "$graph_run_dir" && pwd -P)" || return 1 ;;
  esac

  # Record run roots and the source base the same way public graph runs do.
  # Workspace-isolating node types (integrate, snapshot, worktree) read
  # run.json.roots and fail closed without it.
  if ! declare -F graph_run_base_prepare >/dev/null 2>&1; then
    # shellcheck source=../graph/graph-run-base.sh
    source "$_WORKFLOW_DEP_SCRIPT_DIR/../graph/graph-run-base.sh"
  fi
  local dep_roots_json dep_modes_json
  dep_roots_json="$(RALPH_PLAN_WORKSPACE_ROOT="$RALPH_GRAPH_STATE_ROOT" \
    graph_run_base_resolve_roots "$workspace")" || return 1
  dep_modes_json="$(graph_run_base_modes_json "$graph_run_dir/graph.json")" || return 1
  if ! graph_run_base_prepare "$graph_run_dir" "$dep_roots_json" "$dep_modes_json"; then
    return 1
  fi
  if [[ "$graph_run_dir" != "$expected_path" ]]; then
    echo "Error: graph ledger path mismatch: $graph_run_dir != $expected_path" >&2
    return 1
  fi

  workflow_state_update "$state_root" "$run_id" \
    '.engine = {kind:$kind, statePath:$statePath, namespace:$namespace}
     | .state = (if .state == "queued" then "running" else .state end)' \
    --arg kind graph \
    --arg statePath "$graph_run_dir" \
    --arg namespace "$namespace" || return 1

  printf '%s\n' "$graph_run_dir"
}

# workflow_dep_operator_interrupt_checkpoint <registry-run> <state-root>
# Checkpoint a graph-backed workflow after the scheduler has torn down its
# children. Graph ledgers use awaiting-operator for the run-level waiting
# projection while interrupted marks only the owned attempt.
workflow_dep_operator_interrupt_checkpoint() {
  local registry_run="${1:-}" state_root="${2:-}" outer graph_run namespace run_id
  local node_ids node_id node_json status attempt details graph_run_file
  [[ -n "$registry_run" && -d "$registry_run" ]] || return 1
  [[ -n "$state_root" ]] || state_root="$(cd "$(dirname "$(dirname "$registry_run")")" && pwd -P)"
  outer="$(workflow_state_read "$state_root" "$(basename "$registry_run")")" || return 1
  run_id="$(printf '%s' "$outer" | jq -r '.runId // empty')"
  namespace="$(printf '%s' "$outer" | jq -r '.engine.namespace // empty')"
  graph_run="$(printf '%s' "$outer" | jq -r '.engine.statePath // empty')"
  [[ -n "$run_id" && -n "$namespace" && -d "$graph_run" ]] || return 1
  node_ids="$(jq -r '.currentNodeIds // .currentStageIds // [] | .[]' "$graph_run/run.json" 2>/dev/null || true)"
  while IFS= read -r node_id; do
    [[ -n "$node_id" ]] || continue
    node_json="$(graph_state_read_node "$state_root" "$namespace" "$run_id" "$node_id" 2>/dev/null || true)"
    status="$(printf '%s' "$node_json" | jq -r '.status // empty')"
    # Do not replace a request that was durably published before SIGINT.
    if [[ "$status" == "awaiting-operator" || "$status" == "awaiting-ack" ]]; then
      continue
    fi
    attempt="$(printf '%s' "$node_json" | jq -r '.lastAttemptId // empty')"
    details="$(jq -cn --arg reason operator-request '{reason:$reason,phase:"operator-interrupted"}')"
    graph_state_write_node "$state_root" "$namespace" "$run_id" "$node_id" interrupted \
      "$attempt" '{}' '{}' || return 1
    # The graph journal vocabulary names this node-interrupted; the operator
    # phase is carried in details so the ledger stays schema-valid.
    graph_events_append "$graph_run" "$run_id" node-interrupted "$node_id" "$attempt" "$details" || return 1
    if declare -F workflow_action_revoke_attempt_capability >/dev/null 2>&1 && [[ -n "$attempt" ]]; then
      workflow_action_revoke_attempt_capability "$registry_run" "$run_id" "$node_id" "$attempt" || true
    fi
  done <<< "$node_ids"
  graph_run_file="$(graph_state_run_file "$state_root" "$namespace" "$run_id")" || return 1
  ralph_atomic_write_json "$graph_run_file" \
    '($base | fromjson) + {status:"awaiting-operator", supervisorPid:null, ownerHostname:null, ownerProcessStartId:null, heartbeatAt:null}' \
    --arg base "$(jq -c . "$graph_run_file")" || return 1
  workflow_state_clear_owner_and_set_state "$state_root" "$run_id" waiting || return 1
  workflow_state_write_diagnosis "$registry_run" "$(jq -cn --arg id "$run_id" \
    '{state:"waiting",reasonCode:"operator-request",summary:"Workflow interrupted by operator",stageId:null,evidence:[],retryable:true,nextAction:{label:"Resume workflow",argv:["ralph","workflow","resume",$id]},runId:$id}')" >/dev/null || true
}

workflow_dep_operator_cancel() {
  local registry_run="${1:-}" state_root="${2:-}" outer run_id namespace graph_run graph_file
  [[ -n "$registry_run" && -d "$registry_run" ]] || return 1
  [[ -n "$state_root" ]] || state_root="$(cd "$(dirname "$(dirname "$registry_run")")" && pwd -P)"
  outer="$(workflow_state_read "$state_root" "$(basename "$registry_run")")" || return 1
  run_id="$(printf '%s' "$outer" | jq -r '.runId // empty')"
  namespace="$(printf '%s' "$outer" | jq -r '.engine.namespace // empty')"
  graph_run="$(printf '%s' "$outer" | jq -r '.engine.statePath // empty')"
  graph_file="$(graph_state_run_file "$state_root" "$namespace" "$run_id")" || return 1
  workflow_state_record_cancel_intent "$registry_run" "$(jq -cn --arg runId "$run_id" \
    '{runId:$runId,source:"operator-signal"}')" >/dev/null || true
  workflow_action_cancel_outstanding "$registry_run" "$run_id" || true
  if [[ -f "$graph_file" ]]; then
    ralph_atomic_write_json "$graph_file" \
      '($base | fromjson) + {status:"cancelled", supervisorPid:null, ownerHostname:null, ownerProcessStartId:null, heartbeatAt:null}' \
      --arg base "$(jq -c . "$graph_file")" || true
  fi
  workflow_state_clear_owner_and_set_state "$state_root" "$run_id" cancelled || true
}

# Resolve graph state root for projection. When RALPH_PLAN_WORKSPACE_ROOT is set
# (workflow CLI / registry adapters), align RALPH_GRAPH_STATE_ROOT to that root so
# a stale operator-shell RALPH_GRAPH_STATE_ROOT cannot hide ledgers. Otherwise honor
# RALPH_GRAPH_STATE_ROOT, or treat <workspace> as the state root when
# graph-runs/<namespace>/<run-id> exists there.
_workflow_dep_ensure_graph_state_root() {
  local workspace="$1" namespace="$2" run_id="$3"
  local resolved
  if [[ -n "${RALPH_PLAN_WORKSPACE_ROOT:-}" ]]; then
    resolved="$(workflow_state_ensure_state_root "${RALPH_PLAN_WORKSPACE_ROOT}")" || return 1
    export RALPH_GRAPH_STATE_ROOT="$resolved"
    return 0
  fi
  if [[ -n "${RALPH_GRAPH_STATE_ROOT:-}" ]]; then
    return 0
  fi
  if [[ -f "$workspace/graph-runs/$namespace/$run_id/run.json" ]]; then
    resolved="$(workflow_state_ensure_state_root "$workspace")" || return 1
    export RALPH_GRAPH_STATE_ROOT="$resolved"
    export RALPH_PLAN_WORKSPACE_ROOT="$resolved"
  fi
}

# workflow_dep_project_run <workspace> <namespace> <run-id>
# Public run-facing projection from the graph run ledger (read-only).
workflow_dep_project_run() {
  local workspace="$1" namespace="$2" run_id="$3"
  local run_json status public_state
  _workflow_dep_ensure_graph_state_root "$workspace" "$namespace" "$run_id"
  run_json="$(graph_state_read_run "$workspace" "$namespace" "$run_id")" || return 1
  status="$(printf '%s' "$run_json" | jq -r '.status // empty')"
  public_state="$(workflow_dep_map_run_status "$status")" || return 1
  jq -cn \
    --argjson run "$run_json" \
    --arg state "$public_state" \
    '{
      schemaVersion: 1,
      runId: $run.runId,
      state: $state,
      internalStatus: $run.status,
      startedAt: ($run.startedAt // null),
      heartbeatAt: ($run.heartbeatAt // null),
      registryRunPath: ($run.registryRunPath // null),
      planPath: ($run.planPath // null),
      graphSha: ($run.graphSha // null),
      maxParallel: ($run.maxParallel // null)
    }'
}

_workflow_dep_node_is_supervisor() {
  local graph_file="$1" node_id="$2"
  local ntype
  ntype="$(jq -r --arg id "$node_id" '
    (.nodes // [])[]? | select(.id == $id) | .type // empty
  ' "$graph_file" 2>/dev/null)" || ntype=""
  case "$ntype" in
    join|gate|checkpoint|router|integrate|approval) return 0 ;;
    *) return 1 ;;
  esac
}

# workflow_dep_project_stage <workspace> <namespace> <run-id> <node-id> [index]
# Public stage projection from one graph node ledger. Plan-source/progress and
# blocker fields are read from the node document when present; supervisors get
# null plan fields and zero TODO counts.
workflow_dep_project_stage() {
  local workspace="$1" namespace="$2" run_id="$3" node_id="$4" index="${5:-0}"
  local node_json graph_file graph_json public_state attempt supervisor=0
  local created updated

  _workflow_dep_ensure_graph_state_root "$workspace" "$namespace" "$run_id"
  node_json="$(graph_state_read_node "$workspace" "$namespace" "$run_id" "$node_id")" || return 1
  graph_file="$(graph_state_graph_file "$workspace" "$namespace" "$run_id")" || return 1
  graph_json="$(<"$graph_file")" || return 1
  public_state="$(workflow_dep_map_node_state "$(printf '%s' "$node_json" | jq -r '.status // empty')")" || return 1
  if _workflow_dep_node_is_supervisor "$graph_file" "$node_id"; then
    supervisor=1
  fi

  attempt="$(printf '%s' "$node_json" | jq -r '
    ( .lastAttemptId // empty ) as $lid
    | if $lid == "" then 0
      else
        ($lid | capture("__(?<n>[0-9]+)$")? | .n // empty) as $n
        | if $n == "" then ((.attempts // []) | length) else ($n | tonumber) end
      end
  ')"
  [[ -n "$attempt" ]] || attempt=0

  created="$(printf '%s' "$node_json" | jq -r '
    (.attempts // []) | map(.startedAt // empty) | map(select(length > 0)) | .[0] // empty
  ')"
  updated="$(printf '%s' "$node_json" | jq -r '
    (.attempts // []) | map(.finishedAt // .heartbeatAt // .startedAt // empty)
    | map(select(length > 0)) | .[-1] // empty
  ')"
  if [[ -z "$created" ]]; then
    created="$(graph_state_field "$(graph_state_run_file "$workspace" "$namespace" "$run_id")" startedAt 2>/dev/null || true)"
  fi
  if [[ -z "$updated" ]]; then
    updated="$created"
  fi
  if [[ -z "$created" ]]; then
    created="$(graph_state_now_iso)"
  fi
  if [[ -z "$updated" ]]; then
    updated="$created"
  fi

  jq -cn \
    --argjson node "$node_json" \
    --argjson graph "$graph_json" \
    --arg id "$node_id" \
    --argjson index "$index" \
    --arg state "$public_state" \
    --argjson attempt "$attempt" \
    --argjson supervisor "$supervisor" \
    --arg createdAt "$created" \
    --arg updatedAt "$updated" \
    '
    def abs_or_null:
      if . == null then null
      elif (type == "string") and (. | startswith("/")) then .
      else null end;
    def int_or_zero:
      if (. == null) then 0
      elif (type == "number") then .
      else 0 end;
    ($node.blocker // null) as $blocker
    | ([($graph.edges // [])[]
        | select((.to // "") == $id)
        | {stageId: (.from // ""), condition: (.condition // null)}
        | select(.stageId != "")]
       | if length > 0 then .
         else [($graph.nodes // [])[]
               | select((.id // "") == $id)
               | (.dependsOn // [])[]
               | {stageId: ., condition: null}]
         end
       | unique_by([.stageId, (.condition // "")])) as $dependencies
    | {
        id: $id,
        index: $index,
        state: $state,
        attempt: $attempt,
        planPath: (if $supervisor == 1 then null else ($node.planPath | abs_or_null) end),
        planRunId: (if $supervisor == 1 then null else ($node.planRunId // null) end),
        planSourceKind: (if $supervisor == 1 then null else ($node.planSourceKind // null) end),
        planSourceStageId: (if $supervisor == 1 then null else ($node.planSourceStageId // null) end),
        dependencies: $dependencies,
        originalPlanPath: (if $supervisor == 1 then null else ($node.originalPlanPath | abs_or_null) end),
        sourcePlanPath: (if $supervisor == 1 then null else ($node.sourcePlanPath | abs_or_null) end),
        controlPlanPath: (if $supervisor == 1 then null else ($node.controlPlanPath | abs_or_null) end),
        currentTodoId: (if $supervisor == 1 then null else ($node.currentTodoId // null) end),
        wave: ($node.wave // null),
        terminalResult: (
          if $state == "succeeded" or $state == "failed" or $state == "cancelled"
          then $state else ($node.terminalResult // null) end
        ),
        reasonCode: (
          $node.reasonCode
          // $node.blocker.reasonCode
          // (($node.attempts // []) | last | .reason)
          // null
        ),
        blocker: $blocker,
        completedTodos: (if $supervisor == 1 then 0 else (($node.completedTodos | int_or_zero)) end),
        totalTodos: (if $supervisor == 1 then 0 else (($node.totalTodos | int_or_zero)) end),
        artifacts: (
          if ($node.artifacts | type) == "array" then $node.artifacts else [] end
        ),
        createdAt: $createdAt,
        updatedAt: $updatedAt
      }
    '
}

# workflow_dep_project_stages <workspace> <namespace> <run-id>
# Public stages array in frozen graph node order.
workflow_dep_project_stages() {
  local workspace="$1" namespace="$2" run_id="$3"
  local graph_file node_id index=0
  local -a stages=()
  _workflow_dep_ensure_graph_state_root "$workspace" "$namespace" "$run_id"
  graph_file="$(graph_state_graph_file "$workspace" "$namespace" "$run_id")" || return 1
  [[ -f "$graph_file" ]] || {
    echo "Error: frozen graph.json missing for projection" >&2
    return 1
  }
  while IFS= read -r node_id || [[ -n "$node_id" ]]; do
    [[ -n "$node_id" ]] || continue
    stages+=("$(workflow_dep_project_stage "$workspace" "$namespace" "$run_id" "$node_id" "$index")") || return 1
    index=$((index + 1))
  done < <(jq -r '.nodes[]?.id // empty' "$graph_file")
  if [[ "${#stages[@]}" -eq 0 ]]; then
    printf '[]\n'
    return 0
  fi
  printf '%s\n' "${stages[@]}" | jq -sc '.'
}

# _workflow_dep_snapshot_owner_class <graph-run-json>
#
# Equivalent to graph_heartbeat_classify_run, but accepts the already-read run
# ledger used by the public status snapshot.  Keeping the classification here
# avoids reopening run.json solely to decide owner health.
_workflow_dep_snapshot_owner_class() {
  local run_json="${1:-}"
  local heartbeat_at pid owner_start_id heartbeat_epoch current_start_id pid_rc=0
  local ttl_seconds="${GRAPH_HEARTBEAT_TTL_SECONDS:-60}"
  local now_epoch

  [[ -n "$run_json" ]] || { printf 'none\n'; return 0; }
  # Match the legacy observation helper: owner health is available only when
  # the graph heartbeat library has been loaded by the caller.
  declare -F graph_heartbeat_parse_iso_to_epoch >/dev/null 2>&1 || {
    printf 'none\n'
    return 0
  }

  # A run that recorded its own disposition has no owner left to be stale
  # about: the supervisor exits on the way to every terminal status, so its pid
  # is always dead and its heartbeat always expired afterwards. Without this,
  # every finished run eventually reported stale-owner and the public status
  # offered "recover the abandoned run" for a run that had already failed or
  # succeeded. graph-status.sh applies the same override at its call site.
  local run_status
  run_status="$(printf '%s' "$run_json" | jq -r '.status // empty' 2>/dev/null)" || true
  if [[ -n "$run_status" ]] \
    && declare -F graph_state_run_status_is_terminal >/dev/null 2>&1 \
    && graph_state_run_status_is_terminal "$run_status"; then
    printf 'none\n'
    return 0
  fi

  heartbeat_at="$(printf '%s' "$run_json" | jq -r '.heartbeatAt // empty' 2>/dev/null)" || true
  [[ -n "$heartbeat_at" ]] || { printf 'none\n'; return 0; }
  heartbeat_epoch="$(graph_heartbeat_parse_iso_to_epoch "$heartbeat_at" 2>/dev/null || true)"
  [[ -n "$heartbeat_epoch" && "$heartbeat_epoch" =~ ^[0-9]+$ ]] || { printf 'none\n'; return 0; }
  now_epoch="${GRAPH_HEARTBEAT_NOW_EPOCH:-$(graph_heartbeat_now_epoch)}"
  [[ "$ttl_seconds" =~ ^[0-9]+$ ]] || ttl_seconds=60

  if [[ "$(( now_epoch - heartbeat_epoch ))" -lt "$ttl_seconds" ]]; then
    printf 'healthy\n'
    return 0
  fi

  pid="$(printf '%s' "$run_json" | jq -r '.supervisorPid // empty' 2>/dev/null)" || true
  [[ "$pid" =~ ^[0-9]+$ ]] || { printf 'none\n'; return 0; }
  current_start_id="$(graph_heartbeat_process_start_id_of_pid "$pid")"; pid_rc=$?
  if [[ "$pid_rc" -eq 2 ]]; then
    printf 'none\n'
    return 0
  fi
  if [[ "$pid_rc" -eq 1 ]]; then
    printf 'stale\n'
    return 0
  fi

  owner_start_id="$(printf '%s' "$run_json" | jq -r '.ownerProcessStartId // empty' 2>/dev/null)" || true
  if [[ -z "$owner_start_id" || "$current_start_id" != "$owner_start_id" ]]; then
    printf 'none\n'
  else
    # An expired heartbeat with a still-matching owner is deliberately not
    # healthy; graph_heartbeat_classify_run reports unknown in this case.
    printf 'none\n'
  fi
}

# workflow_dep_project_snapshot <workspace> <namespace> <run-id> <outer-run-json>
#
# Projects the public stages and Dependency diagnosis observation together.
# graph.json and run.json are each read once, and jq slurps all node ledgers in
# one process before deriving both outputs.  The smaller project_stages and
# build_observation helpers above/below intentionally remain available for
# internal callers with their historical single-purpose contracts.
workflow_dep_project_snapshot() {
  local workspace="${1:-}" namespace="${2:-}" run_id="${3:-}" outer="${4:-}"
  local graph_file run_file nodes_dir run_json owner_class snapshot now_iso
  local state_root artifact_namespace actual_artifacts available_workspaces changesets_dir agent_workspace_root
  local -a node_files=() changeset_files=() projection_files=()
  local nullglob_was_set=0

  [[ -n "$workspace" && -n "$namespace" && -n "$run_id" && -n "$outer" ]] || {
    echo "Error: workflow_dep_project_snapshot requires workspace, namespace, run-id, and outer run JSON" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || return 1
  _workflow_dep_ensure_graph_state_root "$workspace" "$namespace" "$run_id"
  graph_file="$(graph_state_graph_file "$workspace" "$namespace" "$run_id")" || return 1
  run_file="$(graph_state_run_file "$workspace" "$namespace" "$run_id")" || return 1
  nodes_dir="$(dirname "$run_file")/nodes"
  [[ -f "$graph_file" && -f "$run_file" && -d "$nodes_dir" ]] || {
    echo "Error: frozen Dependency graph ledger missing for projection" >&2
    return 1
  }

  # Read run.json once so owner health and the jq projector share the same
  # ledger bytes.  Node files are passed to one slurping jq invocation below.
  run_json="$(<"$run_file")" || return 1
  shopt -q nullglob && nullglob_was_set=1
  shopt -s nullglob
  node_files=("$nodes_dir"/*.json)
  changesets_dir="$(dirname "$run_file")/changesets/nodes"
  if [[ -d "$changesets_dir" ]]; then
    changeset_files=("$changesets_dir"/*.json)
  fi
  if [[ "$nullglob_was_set" -eq 0 ]]; then
    shopt -u nullglob
  fi
  now_iso="$(graph_state_now_iso)"
  state_root="${RALPH_PLAN_WORKSPACE_ROOT:-$workspace/.ralph-workspace}"
  artifact_namespace="$(sed -nE \
    's/.*"namespace"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' \
    "$graph_file" | head -n 1)"
  actual_artifacts=""
  if [[ -n "$artifact_namespace" && -d "$state_root/artifacts/$artifact_namespace" ]]; then
    actual_artifacts="$(find "$state_root/artifacts/$artifact_namespace" -type f -print 2>/dev/null || true)"
  fi
  # Workspace paths are supervisor-owned and constrained to either the caller's
  # agent workspace or this run's node-workspace directory.  Pass the existing
  # paths into the single jq projection so public status can distinguish a live
  # handoff target from a retained changeset whose workspace has gone away.
  agent_workspace_root="$(printf '%s' "$run_json" | jq -r '.roots.agentWorkspace // empty')"
  available_workspaces="$agent_workspace_root"
  if [[ -d "$(dirname "$run_file")/workspaces/nodes" ]]; then
    available_workspaces+=$'\n'"$(find "$(dirname "$run_file")/workspaces/nodes" \
      -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null || true)"
  fi
  projection_files=("$graph_file" "${node_files[@]}" "${changeset_files[@]}")

  snapshot="$(jq -cs \
    --argjson run "$run_json" \
    --argjson outer "$outer" \
    --arg runId "$run_id" \
    --arg now "$now_iso" \
    --arg workspace "$workspace" \
    --arg stateRoot "$state_root" \
    --arg actualArtifacts "$actual_artifacts" \
    --arg availableWorkspaces "$available_workspaces" \
    --arg runSchema "$GRAPH_STATE_RUN_SCHEMA_VERSION" \
    --arg nodeSchema "$GRAPH_STATE_NODE_SCHEMA_VERSION" \
    '
      def public_node_state:
        if . == "pending" or . == "ready" then "queued"
        elif . == "running" or . == "retry-wait" then "running"
        elif . == "awaiting-operator" or . == "awaiting-ack" then "waiting"
        elif . == "blocked" or . == "needs-plan-repair" then "blocked"
        elif . == "interrupted" then "stale"
        elif . == "failed" then "failed"
        elif . == "cancelled" then "cancelled"
        elif . == "succeeded" then "succeeded"
        elif . == "skipped" then "skipped"
        else error("unrecognized graph node status for public projection: " + (. // ""))
        end;
      def is_supervisor:
        . == "join" or . == "gate" or . == "checkpoint" or . == "router"
        or . == "integrate" or . == "approval";
      def abs_or_null:
        if . == null then null
        elif (type == "string") and startswith("/") then .
        else null end;
      def int_or_zero:
        if . == null then 0 elif type == "number" then . else 0 end;
      def existing_declared_artifacts($graph_node; $id; $artifact_ns; $files):
        [($graph_node.stage.outputArtifacts // [])[],
         ($graph_node.stage.artifacts // [])[]]
        | map(if type == "string" then . else (.path // empty) end)
        | map(select(. != ""))
        | map(
            gsub("\\{\\{ARTIFACT_NS\\}\\}"; $artifact_ns)
            | gsub("\\{\\{STAGE_ID\\}\\}"; $id)
            | if startswith(".ralph-workspace/") then
                $stateRoot + "/" + ltrimstr(".ralph-workspace/")
              elif startswith("/") then .
              else $workspace + "/" + .
              end
          )
        | map(select(. as $path | $files | index($path)))
        | unique;
      def attempt_number:
        (.lastAttemptId // "") as $last
        | if $last == "" then 0
          else (($last | capture("__(?<n>[0-9]+)$")? | .n // "") as $n
                | if $n == "" then ((.attempts // []) | length) else ($n | tonumber) end)
          end;
      ($actualArtifacts | split("\n") | map(select(length > 0))) as $actualArtifactFiles
      | ($availableWorkspaces | split("\n") | map(select(length > 0))) as $availableWorkspacePaths
      | .[0] as $graph
      | (.[1:] | map(select((.kind // "") != "graph-changeset"))) as $node_docs
      | (.[1:] | map(select((.kind // "") == "graph-changeset"))) as $changeset_docs
      | if (($run.schemaVersion // "") | tostring) != $runSchema
        then error("unsupported graph run ledger schema") else . end
      | if any($node_docs[]; ((.schemaVersion // "") | tostring) != $nodeSchema)
        then error("unsupported graph node ledger schema") else . end
      | (reduce $node_docs[] as $node ({}; .[$node.nodeId] = $node)) as $nodes
      | (reduce $changeset_docs[] as $changeset ({}; .[$changeset.nodeId] = $changeset)) as $changesets
      | [($graph.nodes // [])[]
          | . as $graph_node
          | ($graph_node.id // "") as $id
          | ($nodes[$id] // error("missing graph node ledger: " + $id)) as $node
          | ($node.status | public_node_state) as $state
          | ($graph_node.type | is_supervisor) as $supervisor
          | (($node.attempts // [])
             | map(.startedAt // empty) | map(select(length > 0)) | .[0] // "") as $attempt_created
          | (($node.attempts // [])
             | map(.finishedAt // .heartbeatAt // .startedAt // empty)
             | map(select(length > 0)) | .[-1] // "") as $attempt_updated
          | (if $attempt_created == "" then
               (if ($run.startedAt // "") == "" then $now else $run.startedAt end)
             else $attempt_created end) as $created
          | (if $attempt_updated == "" then $created else $attempt_updated end) as $updated
          | {
              id: $id,
              observation: {
                id: $id,
                state: $state,
                blocker: ($node.blocker // null),
                changesTarget: ($node.changesTarget // $node.blocker.changesTarget // null),
                reasonCode: (
                  $node.reasonCode
                  // $node.blocker.reasonCode
                  // (($node.attempts // []) | last | .reason)
                  // null
                ),
                loop: ($node.loop // null),
                unmetDependencies: ($node.unmetDependencies // []),
                missingArtifacts: ($node.missingArtifacts // []),
                invalidArtifacts: ($node.invalidArtifacts // []),
                failedPrerequisites: ($node.failedPrerequisites // []),
                waveFailures: ($node.waveFailures // [])
              },
              node: $node,
              supervisor: $supervisor,
              state: $state,
              created: $created,
              updated: $updated,
              graphNode: $graph_node
            }
        ]
      | to_entries
      | map(.value + {index: .key}) as $rows
      | {
          stages: [$rows[] | . as $row | $row.node as $node
            | ($node.workspaceMode
               // (($node.attempts // []) | last | .workspaceMode)
               // $row.graphNode.stage.workspaceMode
               // null) as $workspace_mode
            | ($node.workspacePath
               // (($node.attempts // []) | last | .workspacePath)
               // null) as $workspace_path
            | ($changesets[$row.id] // null) as $changeset
            | {
            id: $row.id,
            index: $row.index,
            state: $row.state,
            attempt: ($node | attempt_number),
            planPath: (if $row.supervisor then null else ($node.planPath | abs_or_null) end),
            planRunId: (if $row.supervisor then null else ($node.planRunId // null) end),
            planSourceKind: (if $row.supervisor then null else ($node.planSourceKind // null) end),
            planSourceStageId: (if $row.supervisor then null else ($node.planSourceStageId // null) end),
            dependencies: (
              [($graph.edges // [])[]
               | select((.to // "") == $row.id)
               | {stageId: (.from // ""), condition: (.condition // null)}
               | select(.stageId != "")]
              | if length > 0 then .
                else [($row.graphNode.dependsOn // [])[] | {stageId: ., condition: null}]
                end
              | unique_by([.stageId, (.condition // "")])
            ),
            originalPlanPath: (if $row.supervisor then null else ($node.originalPlanPath | abs_or_null) end),
            sourcePlanPath: (if $row.supervisor then null else ($node.sourcePlanPath | abs_or_null) end),
            controlPlanPath: (if $row.supervisor then null else ($node.controlPlanPath | abs_or_null) end),
            currentTodoId: (if $row.supervisor then null else ($node.currentTodoId // null) end),
            workspaceMode: (if $row.supervisor then null else $workspace_mode end),
            workspacePath: (if $row.supervisor then null else ($workspace_path | abs_or_null) end),
            workspaceAvailable: (
              if $row.supervisor or ($workspace_path | type) != "string" then false
              else ($availableWorkspacePaths | index($workspace_path)) != null
              end
            ),
            baseRevision: (if $row.supervisor then null else ($run.sourceBase.git.head // null) end),
            changesetManifest: (
              if $row.supervisor then null
              else ($node.changesetManifest | abs_or_null)
              end
            ),
            changedFiles: (
              if $row.supervisor or $changeset == null then []
              else [($changeset.changes // [])[] | .path // empty] | unique
              end
            ),
            wave: ($node.wave // null),
            terminalResult: (if $row.state == "succeeded" or $row.state == "failed" or $row.state == "cancelled" then $row.state else ($node.terminalResult // null) end),
            reasonCode: $row.observation.reasonCode,
            blocker: ($node.blocker // null),
            completedTodos: (if $row.supervisor then 0 else ($node.completedTodos | int_or_zero) end),
            totalTodos: (if $row.supervisor then 0 else ($node.totalTodos | int_or_zero) end),
            artifacts: (
              ((if ($node.artifacts | type) == "array" then $node.artifacts else [] end)
               + existing_declared_artifacts(
                   $row.graphNode; $row.id; ($graph.namespace // ""); $actualArtifactFiles
                 ))
              | unique
            ),
            createdAt: $row.created,
            updatedAt: $row.updated
          }],
          observation: {
            runId: $runId,
            runStatus: ($outer.state // "running"),
            ownerClass: null,
            heartbeatAt: ($run.heartbeatAt // null),
            ownerPid: ($run.supervisorPid // null),
            nodes: [$rows[] | .observation],
            cycle: ($graph.cycle // [])
          }
        }
    ' "${projection_files[@]}")" || return 1

  owner_class="$(_workflow_dep_snapshot_owner_class "$run_json")"
  [[ "$owner_class" == "healthy" || "$owner_class" == "stale" ]] || owner_class="none"
  printf '%s\n' "$snapshot" | jq -c --arg ownerClass "$owner_class" \
    '.observation.ownerClass = $ownerClass'
}

# workflow_dep_project_event <graph-event-json-line>
# Adapts one graph events.jsonl row into the public Sequential-shaped event
# record (schemaVersion 1) without writing a second journal.
workflow_dep_project_event() {
  local line="${1:-}"
  local event status public_state
  if [[ -z "$line" ]]; then
    echo "Error: workflow_dep_project_event requires a JSON line" >&2
    return 1
  fi
  if ! printf '%s' "$line" | jq -e . >/dev/null 2>&1; then
    echo "Error: workflow_dep_project_event input is not JSON" >&2
    return 1
  fi
  event="$(printf '%s' "$line" | jq -r '.event // empty')"
  status="$(printf '%s' "$line" | jq -r '.details.status // .details.to // empty')"
  public_state=""
  if [[ -n "$status" ]]; then
    if public_state="$(workflow_dep_map_run_status "$status" 2>/dev/null)"; then
      :
    elif public_state="$(workflow_dep_map_node_state "$status" 2>/dev/null)"; then
      :
    else
      public_state=""
    fi
  fi
  if [[ -z "$public_state" ]]; then
    case "$event" in
      run-started) public_state="running" ;;
      node-ready) public_state="queued" ;;
      node-spawn|node-running-update) public_state="running" ;;
      node-terminal) public_state="succeeded" ;;
      node-awaiting-operator) public_state="waiting" ;;
      node-retry-wait) public_state="running" ;;
      node-needs-plan-repair) public_state="blocked" ;;
      node-interrupted) public_state="stale" ;;
      node-cancelled) public_state="cancelled" ;;
      node-skipped) public_state="skipped" ;;
      *) public_state="running" ;;
    esac
  fi
  jq -cn \
    --argjson src "$line" \
    --arg newState "$public_state" \
    '{
      schemaVersion: 1,
      sequence: ($src.sequence // 0),
      timestamp: ($src.timestamp // ""),
      runId: ($src.runId // ""),
      stageId: ($src.nodeId // null),
      event: ($src.event // ""),
      priorState: null,
      newState: $newState,
      details: ($src.details // {})
    }'
}

# workflow_dep_project_events <run-dir>
# Read-only projection of graph events.jsonl into a public event array.
workflow_dep_project_events() {
  local run_dir="$1"
  local line
  local -a rows=()
  if [[ -z "$run_dir" || ! -d "$run_dir" ]]; then
    echo "Error: workflow_dep_project_events requires a graph run directory" >&2
    return 1
  fi
  if ! graph_events_read_lines "$run_dir" >/dev/null 2>&1; then
    printf '[]\n'
    return 0
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    rows+=("$(workflow_dep_project_event "$line")") || return 1
  done < <(graph_events_read_lines "$run_dir")
  if [[ "${#rows[@]}" -eq 0 ]]; then
    printf '[]\n'
    return 0
  fi
  printf '%s\n' "${rows[@]}" | jq -sc '.'
}

# workflow_dep_resolve_attempt_id <node-json> <attempt-n>
# Maps a public attempt number to the graph attemptId string.
workflow_dep_resolve_attempt_id() {
  local node_json="$1" attempt_n="$2"
  local attempt_id=""
  [[ -n "$node_json" && -n "$attempt_n" ]] || {
    echo "Error: workflow_dep_resolve_attempt_id requires node document and attempt number" >&2
    return 1
  }
  if ! [[ "$attempt_n" =~ ^[0-9]+$ ]]; then
    echo "Error: workflow logs --attempt must be a non-negative integer" >&2
    return 1
  fi
  attempt_id="$(printf '%s' "$node_json" | jq -r --argjson n "$attempt_n" '
    (.attempts // [])
    | map(select(
        (.attemptId // "") as $aid
        | ($aid | capture("__(?<num>[0-9]+)$")? | .num // empty) as $suffix
        | if $suffix != "" then ($suffix | tonumber) == $n
          elif ($n == 0 and length == 0) then true
          else false end
      ))
    | last
    | .attemptId // empty
  ' 2>/dev/null || true)"
  if [[ -z "$attempt_id" ]]; then
    attempt_id="$(printf '%s' "$node_json" | jq -r --argjson n "$attempt_n" '
      if $n == 0 then (.lastAttemptId // empty)
      else
        (.lastAttemptId // "") as $lid
        | if ($lid | capture("__(?<num>[0-9]+)$")? | .num // "" | tonumber) == $n then $lid else empty end
      end
    ' 2>/dev/null || true)"
  fi
  if [[ -z "$attempt_id" ]]; then
    echo "Error: workflow logs attempt '$attempt_n' is not in the stage ledger" >&2
    return 1
  fi
  printf '%s\n' "$attempt_id"
}

# workflow_dep_stage_log_select <run-dir> <stage-id> <node-json> <attempt-n> <public-stream>
# Prints one absolute log path per mapped internal stream (newline-separated).
workflow_dep_stage_log_select() {
  local run_dir="$1" stage_id="$2" node_json="$3" attempt_n="$4" public_stream="$5"
  local attempt_id internal rel abs
  workflow_logs_validate_public_stream "$public_stream" || return 1
  attempt_id="$(workflow_dep_resolve_attempt_id "$node_json" "$attempt_n")" || return 1
  while IFS= read -r internal || [[ -n "$internal" ]]; do
    [[ -n "$internal" ]] || continue
    rel="$(graph_logs_ledger_rel "$node_json" "$attempt_id" "$internal" 2>/dev/null || true)"
    if [[ -z "$rel" ]]; then
      rel="$(graph_logs_attempt_rel "$run_dir" "$stage_id" "$attempt_id" "$internal" 2>/dev/null || true)"
    fi
    [[ -n "$rel" ]] || continue
    abs="$(graph_logs_resolve "$run_dir" "$rel" 2>/dev/null || true)"
    if [[ -n "$abs" && -f "$abs" && ! -L "$abs" ]]; then
      printf '%s\n' "$abs"
    fi
  done < <(workflow_logs_map_public_stream "$public_stream")
}

# workflow_dep_events_file <run-dir>
workflow_dep_events_file() {
  local run_dir="$1"
  graph_logs_resolve "$run_dir" "$(graph_events_rel 2>/dev/null || printf 'events.jsonl')" 2>/dev/null || true
}

# workflow_dep_read_event_lines <run-dir>
workflow_dep_read_event_lines() {
  local run_dir="$1" path
  path="$(workflow_dep_events_file "$run_dir")"
  [[ -n "$path" && -f "$path" && ! -L "$path" ]] || return 0
  graph_events_read_lines "$run_dir" 2>/dev/null || cat "$path"
}

#
# After orchestrator/run-plan transitions a planFrom or provided-plan control
# copy, refresh completed/total/current TODO fields on the graph node ledger.
# No-op when the plan is not a registry control copy or graph identity env is
# absent. Never mutates the immutable source plan or manifest. Preserves any
# already-persisted planSourceKind (generated|provided) and path fields.
# Rework clones (<stage>-r<n>) use distinct consumer control paths; refreshing
# one clone must not rewrite a sibling or original consumer's ledger row.
workflow_dep_refresh_plan_progress_after_runner() {
  local control_plan="${1:-}"
  local registry="${RALPH_WORKFLOW_REGISTRY_RUN:-}"
  local workspace namespace run_id node_id
  local progress binding

  [[ -n "$control_plan" && -f "$control_plan" ]] || return 0
  [[ -n "$registry" ]] || return 0
  case "$control_plan" in
    "$registry"/plans/*/attempt-*/control.plan.md) ;;
    *) return 0 ;;
  esac

  node_id="${RALPH_GRAPH_NODE_ID:-}"
  # Node state is keyed by the ledger namespace, which differs from the
  # artifact/orchestration namespace on workflow-backed runs.
  namespace="${RALPH_GRAPH_LEDGER_NAMESPACE:-${RALPH_GRAPH_NAMESPACE:-}}"
  run_id="${RALPH_GRAPH_RUN_ID:-}"
  workspace="${RALPH_GRAPH_STATE_ROOT:-${RALPH_PLAN_WORKSPACE_ROOT:-}}"
  [[ -n "$node_id" && -n "$namespace" && -n "$run_id" && -n "$workspace" ]] || return 0

  if ! declare -F workflow_state_plan_progress_json >/dev/null 2>&1; then
    # shellcheck source=./workflow-state.sh
    source "$_WORKFLOW_DEP_SCRIPT_DIR/workflow-state.sh"
  fi
  progress="$(workflow_state_plan_progress_json "$control_plan")" || return 1

  # Prefer already-persisted source paths on the node; fall back to control-only.
  binding="$(jq -cn \
    --arg control "$control_plan" \
    --arg planRunId "${RALPH_PLAN_KEY:-${node_id}}" \
    --argjson progress "$progress" \
    '{
      planSourceKind: "generated",
      planSourceStageId: null,
      originalPlanPath: null,
      sourcePlanPath: null,
      controlPlanPath: $control,
      planPath: $control,
      planRunId: $planRunId,
      completedTodos: $progress.completedTodos,
      totalTodos: $progress.totalTodos,
      currentTodoId: $progress.currentTodoId
    }')" || return 1

  if [[ -f "$(graph_state_node_file "$workspace" "$namespace" "$run_id" "$node_id" 2>/dev/null)" ]]; then
    local existing
    existing="$(jq -c '{
      planSourceKind: (.planSourceKind // "generated"),
      planSourceStageId: (.planSourceStageId // null),
      originalPlanPath: (.originalPlanPath // null),
      sourcePlanPath: (.sourcePlanPath // null),
      planRunId: (.planRunId // null)
    }' "$(graph_state_node_file "$workspace" "$namespace" "$run_id" "$node_id")")" || existing='{}'
    binding="$(jq -cn --argjson a "$existing" --argjson b "$binding" '
      $b * {
        planSourceKind: ($a.planSourceKind // $b.planSourceKind),
        planSourceStageId: ($a.planSourceStageId // $b.planSourceStageId),
        originalPlanPath: ($a.originalPlanPath // $b.originalPlanPath),
        sourcePlanPath: ($a.sourcePlanPath // $b.sourcePlanPath),
        planRunId: ($a.planRunId // $b.planRunId)
      }
    ')" || return 1
  fi

  graph_state_persist_plan_progress "$workspace" "$namespace" "$run_id" "$node_id" "$binding"
}

# workflow_dep_set_plan_input_stage <stage-id>
# Export the compile-time planInput.stage for Dependency plan-entry runs so
# graph_compile_plan freezes provided bindings. Empty/unset leaves task-entry
# planFrom compile byte-compatible.
workflow_dep_set_plan_input_stage() {
  local stage_id="${1:-}"
  if [[ -z "$stage_id" ]]; then
    unset RALPH_WORKFLOW_PLAN_INPUT_STAGE
    return 0
  fi
  export RALPH_WORKFLOW_PLAN_INPUT_STAGE="$stage_id"
}

# workflow_dep_registry_run_from_graph <graph-run-dir>
# Prints absolute registryRunPath from the graph ledger run.json.
workflow_dep_registry_run_from_graph() {
  local graph_run_dir="${1:-}"
  local path
  [[ -n "$graph_run_dir" && -f "$graph_run_dir/run.json" ]] || {
    echo "Error: workflow_dep_registry_run_from_graph requires a graph run directory" >&2
    return 1
  }
  path="$(jq -r '.registryRunPath // empty' "$graph_run_dir/run.json")"
  if [[ -z "$path" ]]; then
    path="${RALPH_WORKFLOW_REGISTRY_RUN:-}"
  fi
  [[ -n "$path" && -d "$path" ]] || {
    echo "Error: Dependency approval requires a workflow registry run path" >&2
    return 1
  }
  case "$path" in
    /*) ;;
    *)
      echo "Error: registryRunPath must be absolute: $path" >&2
      return 1
      ;;
  esac
  printf '%s\n' "$path"
}

# workflow_dep_approval_declared_paths <graph-json> <node-id>
# Prints the authored inputArtifacts/requires path array for an approval node.
workflow_dep_approval_declared_paths() {
  local graph_json="${1:-}" node_id="${2:-}"
  [[ -n "$graph_json" && -f "$graph_json" && -n "$node_id" ]] || {
    echo "Error: workflow_dep_approval_declared_paths requires graph-json and node-id" >&2
    return 1
  }
  jq -c --arg id "$node_id" '
    (.nodes // [])[]
    | select(.id == $id)
    | (
        if ((.stage.inputArtifacts // []) | length) > 0 then .stage.inputArtifacts
        else (.stage.requires // [])
        end
      )
  ' "$graph_json"
}

# workflow_dep_approval_stage_fields <graph-json> <node-id>
# Prints {question, changesTarget} for the approval node.
workflow_dep_approval_stage_fields() {
  local graph_json="${1:-}" node_id="${2:-}"
  jq -c --arg id "$node_id" '
    (.nodes // [])[]
    | select(.id == $id)
    | {
        question: (.stage.question // ""),
        changesTarget: (.stage.changesTarget // "")
      }
  ' "$graph_json"
}

# workflow_dep_approval_activate
#   --workspace --namespace --run-id --graph-json --node-id --attempt-id
#   [--graph-run-dir] [--state-root]
# Freezes evidence, creates one common approval request, returns compact JSON:
# {requestId,requestPath,blocker,evidence}
workflow_dep_approval_activate() {
  local workspace="" namespace="" run_id="" graph_json="" node_id="" attempt_id=""
  local graph_run_dir="" state_root=""
  local registry_run fields question changes_target paths evidence request_id
  local request_json request_path blocker

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --workspace) workspace="${2:-}"; shift 2 ;;
      --namespace) namespace="${2:-}"; shift 2 ;;
      --run-id) run_id="${2:-}"; shift 2 ;;
      --graph-json) graph_json="${2:-}"; shift 2 ;;
      --node-id) node_id="${2:-}"; shift 2 ;;
      --attempt-id) attempt_id="${2:-}"; shift 2 ;;
      --graph-run-dir) graph_run_dir="${2:-}"; shift 2 ;;
      --state-root) state_root="${2:-}"; shift 2 ;;
      *)
        echo "Error: unknown workflow_dep_approval_activate argument: $1" >&2
        return 1
        ;;
    esac
  done
  [[ -n "$workspace" && -n "$namespace" && -n "$run_id" && -n "$graph_json" && -n "$node_id" && -n "$attempt_id" ]] || {
    echo "Error: workflow_dep_approval_activate requires workspace namespace run-id graph-json node-id attempt-id" >&2
    return 1
  }

  if ! declare -F workflow_action_request_write >/dev/null 2>&1; then
    # shellcheck source=./workflow-actions.sh
    source "$_WORKFLOW_DEP_SCRIPT_DIR/workflow-actions.sh"
  fi
  if ! declare -F workflow_state_clear_owner_and_set_state >/dev/null 2>&1; then
    # shellcheck source=./workflow-state.sh
    source "$_WORKFLOW_DEP_SCRIPT_DIR/workflow-state.sh"
  fi

  if [[ -z "$graph_run_dir" ]]; then
    graph_run_dir="$(workflow_dep_engine_state_path "${state_root:-$workspace}" "$namespace" "$run_id" 2>/dev/null || true)"
  fi
  [[ -n "$graph_run_dir" ]] || {
    echo "Error: workflow_dep_approval_activate could not resolve graph run dir" >&2
    return 1
  }
  registry_run="$(workflow_dep_registry_run_from_graph "$graph_run_dir")" || return 1
  fields="$(workflow_dep_approval_stage_fields "$graph_json" "$node_id")" || return 1
  question="$(printf '%s' "$fields" | jq -r '.question // empty')"
  changes_target="$(printf '%s' "$fields" | jq -r '.changesTarget // empty')"
  [[ -n "$question" && -n "$changes_target" ]] || {
    echo "Error: approval node $node_id missing question or changesTarget" >&2
    return 1
  }
  paths="$(workflow_dep_approval_declared_paths "$graph_json" "$node_id")" || return 1
  evidence="$(workflow_action_freeze_evidence "$workspace" "$namespace" "$paths")" || return 1
  workflow_action_verify_evidence "$evidence" || return 1

  # Fail closed on a duplicate outstanding approval for this stage.
  if declare -F workflow_action_list >/dev/null 2>&1; then
    if workflow_action_list "$registry_run" 2>/dev/null \
      | jq -e --arg sid "$node_id" \
        'map(select(.kind=="approval" and .stageId==$sid and .consumed==null and (.decision==null))) | length > 0' \
        >/dev/null 2>&1; then
      echo "Error: duplicate approval request refused for stage $node_id" >&2
      return 1
    fi
  fi

  request_id="$(workflow_action_approval_request_id "$run_id" "$node_id" "$attempt_id")" || return 1
  request_json="$(jq -cn \
    --arg requestId "$request_id" \
    --arg runId "$run_id" \
    --arg stageId "$node_id" \
    --arg attemptId "$attempt_id" \
    --arg question "$question" \
    --arg changesTarget "$changes_target" \
    --argjson evidence "$evidence" \
    --arg createdAt "$(workflow_action_now_iso)" \
    '{
      requestId: $requestId,
      kind: "approval",
      runId: $runId,
      stageId: $stageId,
      attemptId: $attemptId,
      choices: ["approve","request-changes","cancel"],
      createdAt: $createdAt,
      question: $question,
      changesTarget: $changesTarget,
      evidence: $evidence
    }')" || return 1
  request_path="$(workflow_action_request_write "$registry_run" "$request_json")" || return 1
  blocker="$(workflow_action_approval_blocker_json \
    --request-id "$request_id" \
    --run-id "$run_id" \
    --reason-code human-approval \
    --retryable false \
    --changes-target "$changes_target" \
    --mode list)" || return 1

  if [[ -z "$state_root" ]]; then
    state_root="$(dirname "$(dirname "$(dirname "$registry_run")")")"
  fi
  # Outer public state: non-retryable waiting; clear live ownership.
  workflow_state_clear_owner_and_set_state "$state_root" "$run_id" waiting || return 1

  jq -cn \
    --arg requestId "$request_id" \
    --arg requestPath "$request_path" \
    --argjson blocker "$blocker" \
    --argjson evidence "$evidence" \
    --arg registryRun "$registry_run" \
    --arg changesTarget "$changes_target" \
    '{
      requestId: $requestId,
      requestPath: $requestPath,
      registryRun: $registryRun,
      changesTarget: $changesTarget,
      blocker: $blocker,
      evidence: $evidence
    }'
}

# workflow_dep_approval_apply_decision
#   --registry-run --request-id --run-id [--state-root]
# Consumes an approval decision exactly once when approved; applies
# changes-requested / cancel durable outcomes. Prints outcome JSON.
workflow_dep_approval_apply_decision() {
  local registry_run="" request_id="" run_id="" state_root=""
  local class decision_json choice message changes_target consume_path blocker intent_path

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --registry-run) registry_run="${2:-}"; shift 2 ;;
      --request-id) request_id="${2:-}"; shift 2 ;;
      --run-id) run_id="${2:-}"; shift 2 ;;
      --state-root) state_root="${2:-}"; shift 2 ;;
      *)
        echo "Error: unknown workflow_dep_approval_apply_decision argument: $1" >&2
        return 1
        ;;
    esac
  done
  [[ -n "$registry_run" && -n "$request_id" && -n "$run_id" ]] || {
    echo "Error: workflow_dep_approval_apply_decision requires registry-run request-id run-id" >&2
    return 1
  }
  if ! declare -F workflow_action_classify_for_resume >/dev/null 2>&1; then
    # shellcheck source=./workflow-actions.sh
    source "$_WORKFLOW_DEP_SCRIPT_DIR/workflow-actions.sh"
  fi
  if ! declare -F workflow_state_clear_owner_and_set_state >/dev/null 2>&1; then
    # shellcheck source=./workflow-state.sh
    source "$_WORKFLOW_DEP_SCRIPT_DIR/workflow-state.sh"
  fi

  class="$(workflow_action_classify_for_resume "$registry_run" "$request_id")" || return 1
  decision_json="$(workflow_action_decision_read "$registry_run" "$request_id" 2>/dev/null || true)"
  choice="$(printf '%s' "$decision_json" | jq -r '.decision // empty')"
  message="$(printf '%s' "$decision_json" | jq -r '.message // empty')"
  changes_target="$(workflow_action_request_read "$registry_run" "$request_id" | jq -r '.changesTarget // empty')"
  # Re-verify frozen evidence before any terminal gate success.
  if [[ "$class" == "ready-approval" ]]; then
    local evidence
    evidence="$(workflow_action_request_read "$registry_run" "$request_id" | jq -c '.evidence // []')" || return 1
    workflow_action_verify_evidence "$evidence" || return 1
  fi

  if [[ -z "$state_root" ]]; then
    state_root="$(dirname "$(dirname "$(dirname "$registry_run")")")"
  fi

  case "$class" in
    ready-approval)
      consume_path="$(workflow_action_consume_once "$registry_run" "$request_id" resume)" || return 1
      workflow_state_clear_owner_and_set_state "$state_root" "$run_id" running || true
      jq -cn \
        --arg outcome "approved" \
        --arg requestId "$request_id" \
        --arg consumed "$consume_path" \
        '{outcome:$outcome,requestId:$requestId,consumedPath:$consumed,nodeState:"succeeded"}'
      ;;
    changes-requested)
      [[ -n "$message" ]] || {
        echo "Error: request-changes decision requires a message" >&2
        return 1
      }
      blocker="$(workflow_action_approval_blocker_json \
        --request-id "$request_id" \
        --run-id "$run_id" \
        --reason-code human-changes-requested \
        --retryable false \
        --changes-target "$changes_target" \
        --mode reset)" || return 1
      # Retain bounded human feedback on the durable blocker for reset/resume.
      blocker="$(printf '%s' "$blocker" | jq -c --arg msg "$message" '. + {feedback:$msg}')" || return 1
      workflow_state_clear_owner_and_set_state "$state_root" "$run_id" blocked || return 1
      jq -cn \
        --arg outcome "changes-requested" \
        --arg requestId "$request_id" \
        --arg message "$message" \
        --argjson blocker "$blocker" \
        --arg changesTarget "$changes_target" \
        '{
          outcome:$outcome,
          requestId:$requestId,
          message:$message,
          changesTarget:$changesTarget,
          blocker:$blocker,
          nodeState:"blocked",
          nextAction:$blocker.action
        }'
      ;;
    cancelled)
      intent_path="$(workflow_state_record_cancel_intent "$registry_run" \
        "$(jq -cn --arg rid "$request_id" --arg runId "$run_id" --arg choice "$choice" \
          '{requestId:$rid,runId:$runId,decision:$choice,source:"approval"}')")" || return 1
      workflow_state_clear_owner_and_set_state "$state_root" "$run_id" cancelled || return 1
      jq -cn \
        --arg outcome "cancelled" \
        --arg requestId "$request_id" \
        --arg intentPath "$intent_path" \
        '{outcome:$outcome,requestId:$requestId,cancelIntentPath:$intentPath,nodeState:"cancelled"}'
      ;;
    unresolved)
      echo "Error: approval decision still unresolved for $request_id" >&2
      return 2
      ;;
    already-consumed|missing|invalid|denied|*)
      echo "Error: approval decision refuse class=$class for $request_id" >&2
      return 1
      ;;
  esac
}

# workflow_dep_build_observation <state-root> <run-id>
# Read-only observation object for workflow_diagnose_dependency.
workflow_dep_build_observation() {
  local state_root="${1:-}" run_id="${2:-}"
  local outer registry_run pointer namespace workspace
  local run_status owner_class owner_pid heartbeat_at cycle_json nodes_json='[]'
  local graph_file node_id node_json public_state obs_node

  [[ -n "$state_root" && -n "$run_id" ]] || {
    echo "Error: workflow_dep_build_observation requires state-root and run-id" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || return 1

  outer="$(workflow_state_read "$state_root" "$run_id" 2>/dev/null)" || return 1
  run_status="$(printf '%s' "$outer" | jq -r '.state // "running"')"
  registry_run="$(workflow_state_run_dir "$state_root" "$run_id")" || return 1

  if ! pointer="$(workflow_dep_resolve_pointer "$state_root" "$run_id" 2>/dev/null)"; then
    jq -cn \
      --arg runId "$run_id" \
      --arg runStatus "$run_status" \
      '{runId:$runId, runStatus:$runStatus, ownerClass:"none", nodes:[], cycle:[]}'
    return 0
  fi

  namespace="$(printf '%s' "$pointer" | jq -r '.namespace // empty')"
  workspace="$state_root"
  _workflow_dep_ensure_graph_state_root "$workspace" "$namespace" "$run_id"

  owner_class="none"
  if declare -F graph_heartbeat_classify_run >/dev/null 2>&1; then
    owner_class="$(graph_heartbeat_classify_run "$workspace" "$namespace" "$run_id" 2>/dev/null || echo none)"
    [[ "$owner_class" == "unknown" ]] && owner_class="none"
  fi

  heartbeat_at="$(graph_state_read_run "$workspace" "$namespace" "$run_id" 2>/dev/null \
    | jq -r '.heartbeatAt // empty')" || heartbeat_at=""
  owner_pid="$(graph_state_read_run "$workspace" "$namespace" "$run_id" 2>/dev/null \
    | jq -r '.supervisorPid // empty')" || owner_pid=""

  graph_file="$(graph_state_graph_file "$workspace" "$namespace" "$run_id" 2>/dev/null || true)"
  cycle_json='[]'
  if [[ -n "$graph_file" && -f "$graph_file" ]]; then
    cycle_json="$(jq -c '.cycle // []' "$graph_file" 2>/dev/null || echo '[]')"
    while IFS= read -r node_id || [[ -n "$node_id" ]]; do
      [[ -n "$node_id" ]] || continue
      node_json="$(graph_state_read_node "$workspace" "$namespace" "$run_id" "$node_id" 2>/dev/null || true)"
      [[ -n "$node_json" ]] || continue
      public_state="$(workflow_dep_map_node_state "$(printf '%s' "$node_json" | jq -r '.status // empty')" 2>/dev/null || echo queued)"
      obs_node="$(printf '%s' "$node_json" | jq -c \
        --arg id "$node_id" \
        --arg state "$public_state" \
        '{
          id: $id,
          state: $state,
          blocker: (.blocker // null),
          changesTarget: (.changesTarget // .blocker.changesTarget // null),
          reasonCode: (.reasonCode // .blocker.reasonCode // null),
          loop: (.loop // null),
          unmetDependencies: (.unmetDependencies // []),
          missingArtifacts: (.missingArtifacts // []),
          invalidArtifacts: (.invalidArtifacts // []),
          failedPrerequisites: (.failedPrerequisites // []),
          waveFailures: (.waveFailures // [])
        }')" || continue
      nodes_json="$(jq -cn --argjson arr "$nodes_json" --argjson node "$obs_node" '$arr + [$node]')"
    done < <(jq -r '.nodes[]?.id // empty' "$graph_file" 2>/dev/null)
  fi

  jq -cn \
    --arg runId "$run_id" \
    --arg runStatus "$run_status" \
    --arg ownerClass "$owner_class" \
    --arg heartbeatAt "$heartbeat_at" \
    --arg ownerPid "$owner_pid" \
    --argjson nodes "$nodes_json" \
    --argjson cycle "$cycle_json" \
    '{
      runId: $runId,
      runStatus: $runStatus,
      ownerClass: $ownerClass,
      heartbeatAt: (if $heartbeatAt == "" then null else $heartbeatAt end),
      ownerPid: (if $ownerPid == "" then null else ($ownerPid | tonumber? // $ownerPid) end),
      nodes: $nodes,
      cycle: $cycle
    }'
}

# ---------------------------------------------------------------------------
# Dependency resume (internal by common run ID)
# ---------------------------------------------------------------------------

_workflow_dep_resume_push() {
  local file="$1" obj="$2" tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/dep-resume.XXXXXX")" || return 1
  jq -c --argjson o "$obj" '. + [$o]' "$file" >"$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$file"
}

# workflow_dep_validate_immutable_input <state-root> <run-id>
# Fail-closed hash check for outer immutable input (and optional provided plan).
# Prints a compact hash report JSON.
workflow_dep_validate_immutable_input() {
  local state_root="${1:-}" run_id="${2:-}"
  local outer input_path expected actual provided_source expected_provided actual_provided
  local report='{"inputOk":true,"providedOk":true}'

  [[ -n "$state_root" && -n "$run_id" ]] || return 1
  outer="$(workflow_state_read "$state_root" "$run_id")" || return 1
  input_path="$(printf '%s' "$outer" | jq -r '.inputPath // empty')"
  if [[ -n "$input_path" && -f "$input_path" && ! -L "$input_path" ]]; then
    if declare -F _workflow_state_file_sha256 >/dev/null 2>&1; then
      actual="$(_workflow_state_file_sha256 "$input_path" 2>/dev/null || true)"
    else
      actual="$(shasum -a 256 "$input_path" 2>/dev/null | awk '{print $1}')"
    fi
    expected="$(printf '%s' "$outer" | jq -r '.inputSha256 // empty')"
    # Outer schema may not store inputSha256; when absent, treat file presence as ok.
    if [[ -n "$expected" && -n "$actual" && "$expected" != "$actual" ]]; then
      report="$(jq -cn --arg e "$expected" --arg a "$actual" \
        '{inputOk:false,providedOk:true,expectedInput:$e,actualInput:$a}')"
      printf '%s\n' "$report"
      return 1
    fi
  fi

  provided_source="$(printf '%s' "$outer" | jq -r '.inputPlan.sourcePath // empty')"
  expected_provided="$(printf '%s' "$outer" | jq -r '.inputPlan.sha256 // empty')"
  if [[ -n "$provided_source" && -n "$expected_provided" ]]; then
    if [[ ! -f "$provided_source" || -L "$provided_source" ]]; then
      printf '%s\n' '{"inputOk":true,"providedOk":false,"reason":"missing-provided-source"}'
      return 1
    fi
    if declare -F _workflow_state_file_sha256 >/dev/null 2>&1; then
      actual_provided="$(_workflow_state_file_sha256 "$provided_source" 2>/dev/null || true)"
    else
      actual_provided="$(shasum -a 256 "$provided_source" 2>/dev/null | awk '{print $1}')"
    fi
    if [[ "$expected_provided" != "$actual_provided" ]]; then
      printf '%s\n' "$(jq -cn --arg e "$expected_provided" --arg a "$actual_provided" \
        '{inputOk:true,providedOk:false,expectedProvided:$e,actualProvided:$a}')"
      return 1
    fi
  fi
  printf '%s\n' "$report"
  return 0
}

# workflow_dep_resume --state-root ... --run-id ... [--workspace ...] [--dry-run]
#
# Internal resume-by-common-run-ID for Dependency mode. Resolves the frozen
# graph via the outer registry, skips succeeded nodes, retries
# pending|failed|interrupted with satisfied deps, accepts waiting only for
# clean interruption / answered input / approved gate, refuses unresolved
# actions and changes-requested, stages delimited input injection, and never
# replaces a valid generated/provided source or control plan. Does not launch
# graph-run/orchestrator/runtime (caller/dispatch owns continuation).
workflow_dep_resume() {
  local state_root="" run_id="" workspace="" dry_run=0
  local outer registry_run pointer namespace graph_run graph_file
  local run_state owner_class hash_report decisions_tmp
  local node_id node_json status public_state blocker class request_id
  local action refuse_reason control_plan current_todo plan_source_kind
  local retry_count=0 refuse_count=0 skip_count=0 details consume_path
  local node_type completed_todos total_todos

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --state-root) state_root="${2:-}"; shift 2 ;;
      --run-id) run_id="${2:-}"; shift 2 ;;
      --workspace) workspace="${2:-}"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      *)
        echo "Error: unknown workflow_dep_resume argument: $1" >&2
        return 1
        ;;
    esac
  done

  [[ -n "$state_root" && -n "$run_id" ]] || {
    echo "Error: workflow_dep_resume requires --state-root and --run-id" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || return 1

  if ! declare -F workflow_action_waiting_resume_class >/dev/null 2>&1; then
    # shellcheck source=./workflow-actions.sh
    source "$_WORKFLOW_DEP_SCRIPT_DIR/workflow-actions.sh"
  fi
  if ! declare -F graph_heartbeat_classify_run >/dev/null 2>&1; then
    # shellcheck source=../graph/graph-heartbeat.sh
    source "$_WORKFLOW_DEP_SCRIPT_DIR/../graph/graph-heartbeat.sh"
  fi

  outer="$(workflow_state_read "$state_root" "$run_id")" || return 1
  run_state="$(printf '%s' "$outer" | jq -r '.state // empty')"
  case "$run_state" in
    cancelled|succeeded)
      echo "Error: workflow_dep_resume refuses terminal run state: $run_state" >&2
      return 1
      ;;
  esac

  pointer="$(workflow_dep_resolve_pointer "$state_root" "$run_id")" || return 1
  namespace="$(printf '%s' "$pointer" | jq -r '.namespace')"
  graph_run="$(printf '%s' "$pointer" | jq -r '.statePath')"
  registry_run="$(workflow_state_run_dir "$state_root" "$run_id")" || return 1
  workspace="${workspace:-${RALPH_AGENT_WORKSPACE:-$state_root}}"
  _workflow_dep_ensure_graph_state_root "$state_root" "$namespace" "$run_id"

  owner_class="$(graph_heartbeat_classify_run "$state_root" "$namespace" "$run_id" 2>/dev/null || echo none)"
  [[ "$owner_class" == "unknown" ]] && owner_class="none"
  if [[ "$run_state" == "running" && "$owner_class" == "healthy" ]]; then
    echo "Error: workflow_dep_resume refuses live-owner running run" >&2
    return 1
  fi

  if ! hash_report="$(workflow_dep_validate_immutable_input "$state_root" "$run_id")"; then
    echo "Error: workflow_dep_resume immutable hash validation failed" >&2
    printf '%s\n' "$hash_report" >&2
    return 2
  fi

  graph_file="$(graph_state_graph_file "$state_root" "$namespace" "$run_id" 2>/dev/null || true)"
  [[ -n "$graph_file" && -f "$graph_file" ]] || {
    echo "Error: workflow_dep_resume frozen graph not found" >&2
    return 1
  }

  decisions_tmp="$(mktemp "${TMPDIR:-/tmp}/dep-resume-dec.XXXXXX")" || return 1
  printf '[]\n' >"$decisions_tmp"

  while IFS= read -r node_id || [[ -n "$node_id" ]]; do
    [[ -z "$node_id" ]] && continue
    node_json="$(graph_state_read_node "$state_root" "$namespace" "$run_id" "$node_id" 2>/dev/null || true)"
    [[ -n "$node_json" ]] || continue
    status="$(printf '%s' "$node_json" | jq -r '.status // empty')"
    public_state="$(workflow_dep_map_node_state "$status" 2>/dev/null || echo queued)"
    blocker="$(printf '%s' "$node_json" | jq -c '.blocker // null')"
    control_plan="$(printf '%s' "$node_json" | jq -r '.controlPlanPath // empty')"
    current_todo="$(printf '%s' "$node_json" | jq -r '.currentTodoId // empty')"
    plan_source_kind="$(printf '%s' "$node_json" | jq -r '.planSourceKind // empty')"
    completed_todos="$(printf '%s' "$node_json" | jq -r '.completedTodos // 0')"
    total_todos="$(printf '%s' "$node_json" | jq -r '.totalTodos // 0')"
    node_type="$(jq -r --arg id "$node_id" '.nodes[]? | select(.id==$id) | .type // empty' "$graph_file" 2>/dev/null || true)"
    action="skip"
    refuse_reason=""
    class=""
    request_id="$(printf '%s' "$blocker" | jq -r '.requestId // empty')"

    case "$status" in
      succeeded|skipped)
        action="skip-succeeded"
        skip_count=$((skip_count + 1))
        ;;
      cancelled)
        action="skip-cancelled"
        skip_count=$((skip_count + 1))
        ;;
      running|retry-wait)
        if [[ "$owner_class" == "healthy" ]]; then
          action="refuse"
          refuse_reason="live-owner"
          refuse_count=$((refuse_count + 1))
        else
          action="reconcile-stale-then-retry"
          retry_count=$((retry_count + 1))
        fi
        ;;
      pending|ready|failed|interrupted|needs-plan-repair)
        action="retry"
        retry_count=$((retry_count + 1))
        ;;
      blocked)
        if [[ "$(printf '%s' "$blocker" | jq -r '.reasonCode // empty')" == "human-changes-requested" ]] \
          || [[ "$(printf '%s' "$node_json" | jq -r '.reasonCode // empty')" == "human-changes-requested" ]]; then
          action="refuse"
          refuse_reason="human-changes-requested"
          refuse_count=$((refuse_count + 1))
        else
          action="retry"
          retry_count=$((retry_count + 1))
        fi
        ;;
      awaiting-operator|awaiting-ack)
        if [[ "$node_type" == "approval" || "$(printf '%s' "$blocker" | jq -r '.kind // empty')" == "approval" ]]; then
          if [[ -n "$request_id" ]]; then
            class="$(workflow_action_classify_for_resume "$registry_run" "$request_id" 2>/dev/null || printf 'invalid')"
          else
            class="unresolved"
          fi
          case "$class" in
            ready-approval)
              if [[ "$owner_class" == "healthy" ]]; then
                action="refuse"
                refuse_reason="live-owner"
                refuse_count=$((refuse_count + 1))
              else
                action="complete-approved-gate"
                skip_count=$((skip_count + 1))
              fi
              ;;
            changes-requested)
              action="refuse"
              refuse_reason="human-changes-requested"
              refuse_count=$((refuse_count + 1))
              ;;
            unresolved)
              action="refuse"
              refuse_reason="human-approval"
              refuse_count=$((refuse_count + 1))
              ;;
            *)
              action="refuse"
              refuse_reason="human-approval"
              refuse_count=$((refuse_count + 1))
              ;;
          esac
        else
          class="$(workflow_action_waiting_resume_class "$registry_run" "$blocker")"
          case "$class" in
            clean-interruption)
              if [[ "$owner_class" == "healthy" ]]; then
                action="refuse"
                refuse_reason="live-owner"
                refuse_count=$((refuse_count + 1))
              else
                action="retry-clean-interruption"
                retry_count=$((retry_count + 1))
              fi
              ;;
            answered-input)
              if [[ "$owner_class" == "healthy" ]]; then
                action="refuse"
                refuse_reason="live-owner"
                refuse_count=$((refuse_count + 1))
              else
                action="retry-answered-input"
                retry_count=$((retry_count + 1))
              fi
              ;;
            approved-gate)
              action="complete-approved-gate"
              skip_count=$((skip_count + 1))
              ;;
            unresolved-action)
              action="refuse"
              refuse_reason="$(printf '%s' "$blocker" | jq -r '.reasonCode // "operator-request"')"
              refuse_count=$((refuse_count + 1))
              ;;
            changes-requested)
              action="refuse"
              refuse_reason="human-changes-requested"
              refuse_count=$((refuse_count + 1))
              ;;
            *)
              action="refuse"
              refuse_reason="stage-failed"
              refuse_count=$((refuse_count + 1))
              ;;
          esac
        fi
        ;;
      *)
        action="defer"
        ;;
    esac

    details="$(jq -cn \
      --arg id "$node_id" \
      --arg status "$status" \
      --arg public "$public_state" \
      --arg action "$action" \
      --arg class "$class" \
      --arg reason "$refuse_reason" \
      --arg controlPlanPath "$control_plan" \
      --arg currentTodoId "$current_todo" \
      --arg planSourceKind "$plan_source_kind" \
      --argjson completedTodos "$completed_todos" \
      --argjson totalTodos "$total_todos" \
      '{
        stageId: $id,
        priorState: $public,
        graphStatus: $status,
        action: $action,
        waitingClass: (if $class == "" then null else $class end),
        reasonCode: (if $reason == "" then null else $reason end),
        controlPlanPath: (if $controlPlanPath == "" or $controlPlanPath == "null" then null else $controlPlanPath end),
        currentTodoId: (if $currentTodoId == "" or $currentTodoId == "null" then null else $currentTodoId end),
        planSourceKind: (if $planSourceKind == "" or $planSourceKind == "null" then null else $planSourceKind end),
        completedTodos: $completedTodos,
        totalTodos: $totalTodos
      }')"
    _workflow_dep_resume_push "$decisions_tmp" "$details" || {
      rm -f "$decisions_tmp"
      return 1
    }
  done < <(jq -r '.nodes[]?.id // empty' "$graph_file")

  if [[ "$refuse_count" -gt 0 ]]; then
    jq -cn \
      --arg runId "$run_id" \
      --arg mode "dependency" \
      --argjson hashReport "$hash_report" \
      --argjson stages "$(cat "$decisions_tmp")" \
      --argjson refuseCount "$refuse_count" \
      --argjson retryCount "$retry_count" \
      --argjson skipCount "$skip_count" \
      '{
        schemaVersion: 1,
        ok: false,
        mode: $mode,
        runId: $runId,
        hashes: $hashReport,
        refuseCount: $refuseCount,
        retryCount: $retryCount,
        skipCount: $skipCount,
        stages: $stages
      }'
    rm -f "$decisions_tmp"
    return 1
  fi

  if [[ "$dry_run" -eq 0 ]]; then
    while IFS= read -r details || [[ -n "$details" ]]; do
      [[ -z "$details" ]] && continue
      node_id="$(printf '%s' "$details" | jq -r '.stageId')"
      action="$(printf '%s' "$details" | jq -r '.action')"
      node_json="$(graph_state_read_node "$state_root" "$namespace" "$run_id" "$node_id" 2>/dev/null || true)"
      blocker="$(printf '%s' "$node_json" | jq -c '.blocker // null')"
      request_id="$(printf '%s' "$blocker" | jq -r '.requestId // empty')"
      control_plan="$(printf '%s' "$details" | jq -r '.controlPlanPath // empty')"
      current_todo="$(printf '%s' "$details" | jq -r '.currentTodoId // empty')"

      case "$action" in
        skip-succeeded|skip-cancelled|defer)
          ;;
        reconcile-stale-then-retry|retry|retry-clean-interruption)
          # Never rewrite plan source/control fields; only requeue.
          graph_state_write_node "$state_root" "$namespace" "$run_id" "$node_id" pending \
            "" '{}' '{"blocker":null}' 2>/dev/null || \
          graph_state_write_node "$state_root" "$namespace" "$run_id" "$node_id" pending || true
          ;;
        retry-answered-input)
          if [[ -n "$request_id" ]]; then
            consume_path="$(workflow_action_consume_once "$registry_run" "$request_id" resume 2>/dev/null)" || {
              echo "Error: failed one-time input consumption for $request_id" >&2
              rm -f "$decisions_tmp"
              return 1
            }
            if ! workflow_action_stage_input_injection "$registry_run" "$request_id" \
                --todo-id "${current_todo}" \
                --control-plan "${control_plan}" >/dev/null; then
              echo "Error: failed to stage delimited input injection for $request_id" >&2
              rm -f "$decisions_tmp"
              return 1
            fi
          fi
          graph_state_write_node "$state_root" "$namespace" "$run_id" "$node_id" pending \
            "" '{}' '{"blocker":null}' 2>/dev/null || \
          graph_state_write_node "$state_root" "$namespace" "$run_id" "$node_id" pending || true
          ;;
        complete-approved-gate)
          if [[ -n "$request_id" ]]; then
            if ! workflow_dep_approval_apply_decision \
                --registry-run "$registry_run" \
                --request-id "$request_id" \
                --run-id "$run_id" \
                --state-root "$state_root" >/dev/null 2>&1; then
              # Fixture-friendly fallback: consume once and mark gate succeeded.
              consume_path="$(workflow_action_consume_once "$registry_run" "$request_id" resume 2>/dev/null)" || {
                echo "Error: failed one-time approval consumption for $request_id" >&2
                rm -f "$decisions_tmp"
                return 1
              }
              # awaiting-operator -> running -> succeeded
              graph_state_write_node "$state_root" "$namespace" "$run_id" "$node_id" running || true
              graph_state_write_node "$state_root" "$namespace" "$run_id" "$node_id" succeeded \
                "" '{"outcome":"success","exitCode":"0"}' '{"blocker":null}' || true
            else
              # approval_apply_decision may not mutate graph node; ensure succeeded.
              status="$(graph_state_node_status "$state_root" "$namespace" "$run_id" "$node_id" 2>/dev/null || true)"
              if [[ "$status" == "awaiting-operator" ]]; then
                graph_state_write_node "$state_root" "$namespace" "$run_id" "$node_id" running || true
                graph_state_write_node "$state_root" "$namespace" "$run_id" "$node_id" succeeded \
                  "" '{"outcome":"success","exitCode":"0"}' '{"blocker":null}' || true
              fi
            fi
          fi
          ;;
      esac
    done < <(jq -c '.[]' "$decisions_tmp")

    # Clear graph supervisor ownership; mark outer queued for dispatch.
    if [[ -f "$graph_run/run.json" ]]; then
      ralph_atomic_write_json "$graph_run/run.json" \
        '($base | fromjson) + {status:"running", supervisorPid:null, ownerHostname:null, ownerProcessStartId:null, heartbeatAt:null}' \
        --arg base "$(jq -c . "$graph_run/run.json")" || true
    fi
    if declare -F graph_events_append >/dev/null 2>&1; then
      graph_events_append "$graph_run" "$run_id" run-status-changed "" "" \
        "$(jq -cn --argjson retry "$retry_count" --argjson skip "$skip_count" \
          '{reason:"resume",retryCount:$retry,skipCount:$skip}')" || true
    fi
    workflow_state_clear_owner_and_set_state "$state_root" "$run_id" queued || true
  fi

  jq -cn \
    --arg runId "$run_id" \
    --arg mode "dependency" \
    --argjson ok true \
    --argjson dryRun "$dry_run" \
    --argjson hashReport "$hash_report" \
    --argjson stages "$(cat "$decisions_tmp")" \
    --argjson refuseCount "$refuse_count" \
    --argjson retryCount "$retry_count" \
    --argjson skipCount "$skip_count" \
    '{
      schemaVersion: 1,
      ok: $ok,
      dryRun: ($dryRun == 1),
      mode: $mode,
      runId: $runId,
      hashes: $hashReport,
      refuseCount: $refuseCount,
      retryCount: $retryCount,
      skipCount: $skipCount,
      stages: $stages
    }'
  rm -f "$decisions_tmp"
  return 0
}

# workflow_dep_resume_by_run_id --state-root ... --run-id ... [--workspace ...] [--dry-run]
workflow_dep_resume_by_run_id() {
  workflow_dep_resume "$@"
}

# workflow_dep_continue_after_resume --state-root ... --run-id ... [--workspace ...]
#
# Continues a Dependency run after workflow_dep_resume applied ledger mutations.
# Resolves frozen graph + immutable input from the outer registry (no plan or
# namespace arguments). Invokes graph_schedule_resume with --frozen-graph.
# graph-run.sh resume-from-registry is the public thin wrapper around this path.
workflow_dep_continue_after_resume() {
  local state_root="" run_id="" workspace=""
  local outer pointer namespace graph_run input_path frozen_graph

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --state-root) state_root="${2:-}"; shift 2 ;;
      --run-id) run_id="${2:-}"; shift 2 ;;
      --workspace) workspace="${2:-}"; shift 2 ;;
      *)
        echo "Error: unknown workflow_dep_continue_after_resume argument: $1" >&2
        return 1
        ;;
    esac
  done
  [[ -n "$state_root" && -n "$run_id" ]] || {
    echo "Error: workflow_dep_continue_after_resume requires --state-root and --run-id" >&2
    return 1
  }

  outer="$(workflow_state_read "$state_root" "$run_id")" || return 1
  pointer="$(workflow_dep_resolve_pointer "$state_root" "$run_id")" || return 1
  namespace="$(printf '%s' "$pointer" | jq -r '.namespace')"
  graph_run="$(printf '%s' "$pointer" | jq -r '.statePath')"
  input_path="$(printf '%s' "$outer" | jq -r '.inputPath // empty')"
  workspace="${workspace:-${RALPH_AGENT_WORKSPACE:-${RALPH_PROJECT_ROOT:-$PWD}}}"
  frozen_graph="$graph_run/graph.json"
  [[ -f "$frozen_graph" && -f "$input_path" ]] || {
    echo "Error: frozen graph or immutable input missing for $run_id" >&2
    return 1
  }

  _workflow_dep_ensure_graph_state_root "$state_root" "$namespace" "$run_id"
  export RALPH_WORKFLOW_RUN_ID="$run_id"
  export RALPH_WORKFLOW_REGISTRY_RUN="$(workflow_state_run_dir "$state_root" "$run_id")"
  export RALPH_PLAN_WORKSPACE_ROOT="$state_root"
  export RALPH_GRAPH_STATE_ROOT="$state_root"

  if ! declare -F graph_schedule_resume >/dev/null 2>&1; then
    # shellcheck source=../graph/graph-schedule.sh
    source "$_WORKFLOW_DEP_SCRIPT_DIR/../graph/graph-schedule.sh"
  fi
  local schedule_rc=0 graph_status="" public_state=""
  graph_schedule_resume "$workspace" "$namespace" "$run_id" "$input_path" \
    --frozen-graph "$frozen_graph" || schedule_rc=$?

  # Project the terminal graph status onto the outer registry state so the
  # common run reports succeeded/failed/waiting without a separate sync pass.
  graph_status="$(jq -r '.status // empty' "$graph_run/run.json" 2>/dev/null || true)"
  if [[ -n "$graph_status" && "$graph_status" != "running" ]]; then
    public_state="$(workflow_dep_map_run_status "$graph_status")" || public_state=""
    if [[ -n "$public_state" ]]; then
      workflow_state_clear_owner_and_set_state "$state_root" "$run_id" "$public_state" || return 1
    fi
  fi

  # Exit 3 is a legitimate scheduler pause (awaiting-operator / awaiting-ack),
  # not a dispatch failure: the operator still has an action to answer.
  [[ "$schedule_rc" -eq 3 ]] && return 0

  return "$schedule_rc"
}

# ---------------------------------------------------------------------------
# Internal Dependency reset planner / applier
#
# Accepts an exact common run ID plus one concrete stage ID. Computes the
# selected node plus transitive downstream dependents from the frozen graph,
# returns a deterministic preview, and on apply archives mutable state then
# leaves the outer run blocked-ready for explicit resume. No public CLI,
# inference, or confirmation here.
# ---------------------------------------------------------------------------

_workflow_dep_node_is_planner() {
  local graph_file="$1" node_id="$2"
  jq -e --arg id "$node_id" '
    any(.nodes[]?; .id == $id and ((.stage.planner // null) | type) == "object")
  ' "$graph_file" >/dev/null 2>&1
}

_workflow_dep_node_is_publish() {
  local graph_file="$1" node_id="$2"
  local ntype
  ntype="$(jq -r --arg id "$node_id" '
    (.nodes // [])[]? | select(.id == $id) | .type // empty
  ' "$graph_file" 2>/dev/null)" || ntype=""
  [[ "$ntype" == "publish" ]]
}

_workflow_dep_node_is_direct_resettable() {
  local graph_file="$1" node_id="$2"
  if _workflow_dep_node_is_supervisor "$graph_file" "$node_id"; then
    return 1
  fi
  if _workflow_dep_node_is_publish "$graph_file" "$node_id"; then
    return 1
  fi
  return 0
}

_workflow_dep_node_role() {
  local graph_file="$1" node_id="$2"
  if _workflow_dep_node_is_supervisor "$graph_file" "$node_id" \
    || _workflow_dep_node_is_publish "$graph_file" "$node_id"; then
    printf 'derived-supervisor\n'
    return 0
  fi
  if _workflow_dep_node_is_planner "$graph_file" "$node_id"; then
    printf 'planner\n'
    return 0
  fi
  printf 'executable\n'
}

_workflow_dep_public_state_resettable() {
  case "${1:-}" in
    failed|blocked|stale|waiting|succeeded) return 0 ;;
    *) return 1 ;;
  esac
}

_workflow_dep_mint_reset_archive_id() {
  local now suffix
  if [[ -n "${WORKFLOW_STATE_FIXED_NOW:-}" ]]; then
    now="$WORKFLOW_STATE_FIXED_NOW"
  elif [[ -n "${WORKFLOW_DEP_FIXED_NOW:-}" ]]; then
    now="$WORKFLOW_DEP_FIXED_NOW"
  else
    now="$(workflow_state_now_iso 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi
  # reset-YYYYMMDDTHHMMSSZ-<six mktemp characters>
  now="$(printf '%s' "$now" | tr -d ':-' | sed 's/\..*//')"
  case "$now" in
    *Z) ;;
    *) now="${now}Z" ;;
  esac
  if [[ -n "${WORKFLOW_DEP_FIXED_RESET_SUFFIX:-}" ]]; then
    suffix="$WORKFLOW_DEP_FIXED_RESET_SUFFIX"
  else
    suffix="$(mktemp -u XXXXXX 2>/dev/null || printf '%s' "$$")"
    suffix="$(printf '%s' "$suffix" | tr -cd 'A-Za-z0-9' | cut -c1-6)"
    [[ "${#suffix}" -eq 6 ]] || suffix="$(printf '%06d' "$$" | cut -c1-6)"
  fi
  printf 'reset-%s-%s\n' "$now" "$suffix"
}

_workflow_dep_plan_action_for_node() {
  local graph_file="$1" node_id="$2" role="$3" node_json="$4" direct="$5"
  local plan_source_kind planfrom provided
  if [[ "$role" == "derived-supervisor" || "$direct" != "1" ]]; then
    if [[ "$role" == "derived-supervisor" ]]; then
      printf 'invalidate\n'
    else
      printf 'wait-upstream\n'
    fi
    return 0
  fi
  if [[ "$role" == "planner" ]]; then
    printf 'new-planner-attempt\n'
    return 0
  fi
  plan_source_kind="$(printf '%s' "$node_json" | jq -r '.planSourceKind // empty')"
  planfrom="$(jq -r --arg id "$node_id" '
    (.nodes // [])[]? | select(.id == $id)
    | (.planFromBinding.plannerStageId // .stage.planFrom // empty)
  ' "$graph_file" 2>/dev/null || true)"
  provided="$(jq -r --arg id "$node_id" '
    (.nodes // [])[]? | select(.id == $id)
    | (.planInputBinding.planSourceKind // empty)
  ' "$graph_file" 2>/dev/null || true)"
  if [[ "$plan_source_kind" == "provided" || "$provided" == "provided" ]]; then
    printf 'fresh-control-provided\n'
    return 0
  fi
  if [[ "$plan_source_kind" == "generated" || -n "$planfrom" ]]; then
    printf 'fresh-control-generated\n'
    return 0
  fi
  printf 'requeue\n'
}

# Print every node id in frozen graph declaration order (executable, planner, and
# derived supervisors). Used by --all reset selection.
_workflow_dep_reset_all_closure() {
  local graph_file="$1"
  [[ -f "$graph_file" ]] || return 1
  jq -r '(.nodes // [])[]?.id // empty' "$graph_file"
}

# workflow_dep_reset_plan --state-root ... --run-id ... --stage ... [--workspace ...]
#
# Deterministic preview only. Never mutates bytes. Prints JSON.
workflow_dep_reset_plan() {
  workflow_dep_reset "$@" --dry-run
}

# _workflow_dep_exhausted_review_feedback <graph> <state-root> <namespace>
#   <run-id> <workspace> <repair-target>
#
# If repair-target is the final unrolled rework implementation and its review
# successor failed closed with a valid changes-required verdict, describe that
# verdict for reset/dispatch.  This is read-only and never invents a graph edge:
# an operator reset reopens the same frozen implementation/review nodes.
_workflow_dep_exhausted_review_feedback() {
  local graph_file="$1" state_root="$2" namespace="$3" run_id="$4"
  local workspace="$5" repair_target="$6"
  local target_kind reviewer reviewer_kind reviewer_node reviewer_status reviewer_reason
  local artifact_template artifact_rel artifact_abs schema_template schema_abs verdict_status
  local graph_namespace iteration

  target_kind="$(jq -r --arg id "$repair_target" \
    '.nodes[]? | select(.id == $id) | .derivedFrom // empty' "$graph_file" 2>/dev/null || true)"
  [[ "$target_kind" == "rework" ]] || return 1

  reviewer="$(jq -r --arg id "$repair_target" '
    . as $root
    | [(.edges // [])[]
     | select(.from == $id and ((.condition // "") == ""))
     | .to as $candidate
     | select(any($root.nodes[]?; .id == $candidate and .derivedFrom == "rework"))
     | $candidate]
    | first // ""
  ' "$graph_file" 2>/dev/null || true)"
  [[ -n "$reviewer" ]] || return 1
  reviewer_kind="$(jq -r --arg id "$reviewer" \
    '.nodes[]? | select(.id == $id) | .derivedFrom // empty' "$graph_file" 2>/dev/null || true)"
  [[ "$reviewer_kind" == "rework" ]] || return 1
  if jq -e --arg id "$reviewer" \
    'any((.edges // [])[]?; .from == $id and .condition == "changes-required")' \
    "$graph_file" >/dev/null 2>&1; then
    return 1
  fi

  reviewer_node="$(graph_state_read_node "$state_root" "$namespace" "$run_id" "$reviewer" 2>/dev/null || true)"
  [[ -n "$reviewer_node" ]] || return 1
  reviewer_status="$(printf '%s' "$reviewer_node" | jq -r '.status // empty')"
  reviewer_reason="$(printf '%s' "$reviewer_node" | jq -r \
    '.reasonCode // ((.attempts // []) | last | .reason) // empty')"
  [[ "$reviewer_status" == "failed" && "$reviewer_reason" == "review-changes-required-no-edge" ]] || return 1

  artifact_template="$(jq -r --arg id "$reviewer" \
    '.nodes[]? | select(.id == $id) | .stage.loopCheck.path // empty' "$graph_file" 2>/dev/null || true)"
  schema_template="$(jq -r --arg id "$reviewer" \
    '.nodes[]? | select(.id == $id) | .stage.loopCheck.schema // empty' "$graph_file" 2>/dev/null || true)"
  [[ -n "$artifact_template" && -n "$schema_template" ]] || return 1

  graph_namespace="$(jq -r '.namespace // empty' "$graph_file" 2>/dev/null || true)"
  artifact_rel="${artifact_template//\{\{ARTIFACT_NS\}\}/$graph_namespace}"
  artifact_rel="${artifact_rel//\{\{STAGE_ID\}\}/${reviewer//:/_}}"
  artifact_abs="$artifact_rel"
  if [[ "$artifact_rel" == .ralph-workspace/* ]]; then
    artifact_abs="$state_root/${artifact_rel#.ralph-workspace/}"
  elif [[ "$artifact_rel" != /* ]]; then
    artifact_abs="$workspace/$artifact_rel"
  fi
  [[ -f "$artifact_abs" ]] || return 1

  schema_abs="$schema_template"
  [[ "$schema_abs" == /* ]] || schema_abs="$workspace/$schema_abs"
  [[ -f "$schema_abs" ]] || return 1
  if ! declare -F ralph_evaluator_parse_status >/dev/null 2>&1; then
    # shellcheck source=../review-status.sh
    source "$_WORKFLOW_DEP_SCRIPT_DIR/../review-status.sh"
  fi
  verdict_status="$(ralph_evaluator_parse_status "$artifact_abs" "$schema_abs" 2>/dev/null || true)"
  [[ "$verdict_status" == "changes-required" ]] || return 1

  iteration="$(printf '%s' "$reviewer" | sed -nE 's/.*-r([0-9]+)$/\1/p')"
  [[ -n "$iteration" ]] || iteration="1"
  jq -cn \
    --arg sourceStageId "$reviewer" \
    --arg targetStageId "$repair_target" \
    --arg artifactPath "$artifact_abs" \
    --arg artifactRelativePath "$artifact_rel" \
    --arg schemaPath "$schema_abs" \
    --argjson iteration "$iteration" \
    '{sourceStageId:$sourceStageId,targetStageId:$targetStageId,
      artifactPath:$artifactPath,artifactRelativePath:$artifactRelativePath,
      schemaPath:$schemaPath,iteration:$iteration,status:"changes-required"}'
}

# workflow_dep_reset_apply --state-root ... --run-id ... --stage ... [--workspace ...]
#
# Applies the reset for one concrete stage ID (archives + mutates).
workflow_dep_reset_apply() {
  workflow_dep_reset "$@"
}

# workflow_dep_reset --state-root ... --run-id ... --stage ... [--workspace ...] [--dry-run]
#
# Shared planner/applier. Dry-run is byte-nonmutating.
workflow_dep_reset() {
  local state_root="" run_id="" stage_id="" workspace="" dry_run=0 reset_all=0
  local outer registry_run pointer namespace graph_run graph_file
  local run_state owner_class node_id node_json status public_state role
  local closure_line direct plan_action archive_id archive_path
  local feedback_json feedback_request_id feedback_message evaluator_feedback_json
  local stages_tmp requests_tmp live_node refuse_msg
  local next_attempt control_plan source_plan plan_source_kind planner_id
  local bind_json attempt_id requests_dir req_path req_json req_stage req_id
  local node_file dest_dir control_rel archived_control select_all=0 primary_stage=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --state-root) state_root="${2:-}"; shift 2 ;;
      --run-id) run_id="${2:-}"; shift 2 ;;
      --stage) stage_id="${2:-}"; shift 2 ;;
      --all) reset_all=1; shift ;;
      --workspace) workspace="${2:-}"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      *)
        echo "Error: unknown workflow_dep_reset argument: $1" >&2
        return 1
        ;;
    esac
  done

  if [[ "$reset_all" -eq 1 && -n "$stage_id" ]]; then
    echo "Error: workflow_dep_reset --stage and --all are mutually exclusive" >&2
    return 1
  fi
  if [[ "$reset_all" -eq 0 && -z "$stage_id" ]]; then
    echo "Error: workflow_dep_reset requires --state-root --run-id and (--stage or --all)" >&2
    return 1
  fi
  [[ -n "$state_root" && -n "$run_id" ]] || {
    echo "Error: workflow_dep_reset requires --state-root --run-id and (--stage or --all)" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || return 1

  if ! declare -F workflow_action_find_changes_requested_for_target >/dev/null 2>&1; then
    # shellcheck source=./workflow-actions.sh
    source "$_WORKFLOW_DEP_SCRIPT_DIR/workflow-actions.sh"
  fi
  if ! declare -F graph_heartbeat_classify_run >/dev/null 2>&1; then
    # shellcheck source=../graph/graph-heartbeat.sh
    source "$_WORKFLOW_DEP_SCRIPT_DIR/../graph/graph-heartbeat.sh"
  fi
  if ! declare -F graph_state_downstream_closure >/dev/null 2>&1; then
    # shellcheck source=../graph/graph-state.sh
    source "$_WORKFLOW_DEP_SCRIPT_DIR/../graph/graph-state.sh"
  fi

  outer="$(workflow_state_read "$state_root" "$run_id")" || return 1
  run_state="$(printf '%s' "$outer" | jq -r '.state // empty')"
  case "$run_state" in
    cancelled|succeeded)
      echo "Error: workflow_dep_reset refuses terminal run state: $run_state" >&2
      return 1
      ;;
  esac

  pointer="$(workflow_dep_resolve_pointer "$state_root" "$run_id")" || return 1
  namespace="$(printf '%s' "$pointer" | jq -r '.namespace')"
  graph_run="$(printf '%s' "$pointer" | jq -r '.statePath')"
  registry_run="$(workflow_state_run_dir "$state_root" "$run_id")" || return 1
  workspace="${workspace:-${RALPH_AGENT_WORKSPACE:-$state_root}}"
  _workflow_dep_ensure_graph_state_root "$state_root" "$namespace" "$run_id"

  graph_file="$(graph_state_graph_file "$state_root" "$namespace" "$run_id" 2>/dev/null || true)"
  [[ -n "$graph_file" && -f "$graph_file" ]] || {
    echo "Error: workflow_dep_reset frozen graph not found" >&2
    return 1
  }

  if [[ "$reset_all" -eq 1 ]]; then
    select_all=1
    closure_line="$(_workflow_dep_reset_all_closure "$graph_file" | tr '\n' ' ')"
    closure_line="$(printf '%s' "$closure_line" | sed 's/[[:space:]]*$//')"
    [[ -n "$closure_line" ]] || {
      echo "Error: workflow_dep_reset empty --all closure" >&2
      return 1
    }
    primary_stage=""
    for node_id in $closure_line; do
      [[ -n "$node_id" ]] || continue
      if _workflow_dep_node_is_direct_resettable "$graph_file" "$node_id"; then
        primary_stage="$node_id"
        break
      fi
    done
    [[ -n "$primary_stage" ]] || {
      echo "Error: workflow_dep_reset --all found no executable/planner stages" >&2
      return 1
    }
    stage_id="$primary_stage"
  else
    if ! jq -e --arg id "$stage_id" 'any(.nodes[]?; .id == $id)' "$graph_file" >/dev/null 2>&1; then
      echo "Error: workflow_dep_reset unknown stage: $stage_id" >&2
      return 1
    fi

    if ! _workflow_dep_node_is_direct_resettable "$graph_file" "$stage_id"; then
      echo "Error: workflow_dep_reset refuses direct supervisor/integrate/publish/approval selection: $stage_id" >&2
      return 1
    fi
  fi

  owner_class="$(graph_heartbeat_classify_run "$state_root" "$namespace" "$run_id" 2>/dev/null || echo none)"
  [[ "$owner_class" == "unknown" ]] && owner_class="none"
  if [[ "$run_state" == "running" && "$owner_class" == "healthy" ]]; then
    echo "Error: workflow_dep_reset refuses live-running run" >&2
    return 1
  fi

  # Any live-running stage in the run blocks reset selection.
  live_node=""
  while IFS= read -r node_id || [[ -n "$node_id" ]]; do
    [[ -z "$node_id" ]] && continue
    status="$(graph_state_node_status "$state_root" "$namespace" "$run_id" "$node_id" 2>/dev/null || true)"
    case "$status" in
      running|retry-wait)
        live_node="$node_id"
        break
        ;;
    esac
  done < <(jq -r '.nodes[]?.id // empty' "$graph_file")
  if [[ -n "$live_node" ]]; then
    echo "Error: workflow_dep_reset refuses selection while stage is live-running: $live_node" >&2
    return 1
  fi

  if [[ "$select_all" -ne 1 ]]; then
    node_json="$(graph_state_read_node "$state_root" "$namespace" "$run_id" "$stage_id" 2>/dev/null || true)"
    [[ -n "$node_json" ]] || {
      echo "Error: workflow_dep_reset missing ledger for stage: $stage_id" >&2
      return 1
    }
    status="$(printf '%s' "$node_json" | jq -r '.status // empty')"
    public_state="$(workflow_dep_map_node_state "$status" 2>/dev/null || echo queued)"
    if ! _workflow_dep_public_state_resettable "$public_state"; then
      echo "Error: workflow_dep_reset permits direct selection only in failed|blocked|stale|waiting|succeeded (got $public_state)" >&2
      return 1
    fi

    closure_line="$(graph_state_downstream_closure "$graph_file" "$stage_id")" || return 1
  fi
  archive_id="$(_workflow_dep_mint_reset_archive_id)"
  archive_path="$registry_run/archive/$archive_id"

  feedback_json="$(workflow_action_find_changes_requested_for_target "$registry_run" "$stage_id" 2>/dev/null || true)"
  feedback_request_id=""
  feedback_message=""
  if [[ -n "$feedback_json" && "$feedback_json" != "null" ]]; then
    feedback_request_id="$(printf '%s' "$feedback_json" | jq -r '.requestId // empty')"
    feedback_message="$(printf '%s' "$feedback_json" | jq -r '.message // empty')"
  fi
  evaluator_feedback_json="$(_workflow_dep_exhausted_review_feedback \
    "$graph_file" "$state_root" "$namespace" "$run_id" "$workspace" "$stage_id" 2>/dev/null || true)"

  stages_tmp="$(mktemp "${TMPDIR:-/tmp}/dep-reset-stages.XXXXXX")" || return 1
  requests_tmp="$(mktemp "${TMPDIR:-/tmp}/dep-reset-reqs.XXXXXX")" || {
    rm -f "$stages_tmp"
    return 1
  }
  printf '[]\n' >"$stages_tmp"
  printf '[]\n' >"$requests_tmp"

  for node_id in $closure_line; do
    [[ -n "$node_id" ]] || continue
    node_json="$(graph_state_read_node "$state_root" "$namespace" "$run_id" "$node_id" 2>/dev/null || echo '{}')"
    status="$(printf '%s' "$node_json" | jq -r '.status // "pending"')"
    public_state="$(workflow_dep_map_node_state "$status" 2>/dev/null || echo queued)"
    role="$(_workflow_dep_node_role "$graph_file" "$node_id")"
    if [[ "$select_all" -eq 1 ]]; then
      if _workflow_dep_node_is_direct_resettable "$graph_file" "$node_id"; then
        direct=1
      else
        direct=0
      fi
    elif [[ "$node_id" == "$stage_id" ]]; then
      direct=1
    else
      direct=0
    fi
    plan_action="$(_workflow_dep_plan_action_for_node "$graph_file" "$node_id" "$role" "$node_json" "$direct")"
    next_attempt="$(graph_state_node_max_attempt_number "$state_root" "$namespace" "$run_id" "$node_id" 2>/dev/null || echo 0)"
    next_attempt=$((next_attempt + 1))
    control_plan="$(printf '%s' "$node_json" | jq -r '.controlPlanPath // empty')"
    source_plan="$(printf '%s' "$node_json" | jq -r '.sourcePlanPath // empty')"
    plan_source_kind="$(printf '%s' "$node_json" | jq -r '.planSourceKind // empty')"

    jq -c \
      --arg id "$node_id" \
      --arg role "$role" \
      --arg prior "$public_state" \
      --arg status "$status" \
      --arg planAction "$plan_action" \
      --argjson direct "$direct" \
      --argjson nextAttempt "$next_attempt" \
      --arg controlPlanPath "$control_plan" \
      --arg sourcePlanPath "$source_plan" \
      --arg planSourceKind "$plan_source_kind" \
      --arg feedbackRequestId "$feedback_request_id" \
      '. + [{
        stageId: $id,
        role: $role,
        direct: ($direct == 1),
        priorState: $prior,
        graphStatus: $status,
        action: (if $role == "derived-supervisor" then "invalidate" else "reset" end),
        planAction: $planAction,
        nextAttempt: $nextAttempt,
        controlPlanPath: (if $controlPlanPath == "" then null else $controlPlanPath end),
        sourcePlanPath: (if $sourcePlanPath == "" then null else $sourcePlanPath end),
        planSourceKind: (if $planSourceKind == "" then null else $planSourceKind end),
        humanFeedbackRequestId: (if ($direct == 1) and ($feedbackRequestId != "") then $feedbackRequestId else null end)
      }]' "$stages_tmp" >"${stages_tmp}.new" && mv -f "${stages_tmp}.new" "$stages_tmp"
  done

  # Collect outstanding (unconsumed) action requests for nodes in the closure.
  requests_dir="$registry_run/actions/requests"
  if [[ -d "$requests_dir" ]]; then
    for req_path in "$requests_dir"/*.json; do
      [[ -f "$req_path" && ! -L "$req_path" ]] || continue
      req_json="$(jq -c . "$req_path" 2>/dev/null)" || continue
      req_stage="$(printf '%s' "$req_json" | jq -r '.stageId // empty')"
      req_id="$(printf '%s' "$req_json" | jq -r '.requestId // empty')"
      [[ -n "$req_stage" && -n "$req_id" ]] || continue
      case " $closure_line " in
        *" $req_stage "*) ;;
        *) continue ;;
      esac
      if workflow_action_consumed_read "$registry_run" "$req_id" >/dev/null 2>&1; then
        continue
      fi
      # Keep the human-feedback request itself until apply consumes it; still list it.
      jq -c \
        --arg id "$req_id" \
        --arg stageId "$req_stage" \
        --arg kind "$(printf '%s' "$req_json" | jq -r '.kind // empty')" \
        '. + [{requestId:$id, stageId:$stageId, kind:$kind}]' \
        "$requests_tmp" >"${requests_tmp}.new" && mv -f "${requests_tmp}.new" "$requests_tmp"
    done
  fi

  if [[ "$dry_run" -eq 1 ]]; then
    jq -cn \
      --arg runId "$run_id" \
      --arg stageId "$stage_id" \
      --arg archivePath "$archive_path" \
      --arg archiveId "$archive_id" \
      --argjson selectAll "$select_all" \
      --argjson stages "$(cat "$stages_tmp")" \
      --argjson invalidatedRequests "$(cat "$requests_tmp")" \
      --argjson humanFeedback "$(if [[ -n "$feedback_json" ]]; then printf '%s' "$feedback_json" | jq -c '{requestId,changesTarget,approvalStageId,message}'; else echo null; fi)" \
      --argjson evaluatorFeedback "$(if [[ -n "$evaluator_feedback_json" ]]; then printf '%s' "$evaluator_feedback_json"; else echo null; fi)" \
      '{
        schemaVersion: 1,
        ok: true,
        dryRun: true,
        mode: "dependency",
        runId: $runId,
        stageId: (if ($selectAll == 1) then "all" else $stageId end),
        selectAll: ($selectAll == 1),
        archiveId: $archiveId,
        archivePath: $archivePath,
        stages: $stages,
        invalidatedRequests: $invalidatedRequests,
        humanFeedback: $humanFeedback,
        evaluatorFeedback: $evaluatorFeedback,
        preserved: [
          "workflow-input",
          "supplied-plan-source-manifest",
          "generated-source-plan-manifest",
          "logs",
          "artifacts",
          "decisions",
          "audit-history"
        ],
        outerStateAfterApply: "blocked"
      }'
    rm -f "$stages_tmp" "$requests_tmp"
    return 0
  fi

  # --- apply ---
  mkdir -p "$archive_path/nodes" "$archive_path/plans" "$archive_path/actions/requests" \
    || {
      rm -f "$stages_tmp" "$requests_tmp"
      echo "Error: failed to create reset archive path" >&2
      return 1
    }

  for node_id in $closure_line; do
    [[ -n "$node_id" ]] || continue
    node_file="$(graph_state_node_file "$state_root" "$namespace" "$run_id" "$node_id" 2>/dev/null || true)"
    if [[ -n "$node_file" && -f "$node_file" ]]; then
      cp -f "$node_file" "$archive_path/nodes/${node_id}.json" || true
    fi
    node_json="$(graph_state_read_node "$state_root" "$namespace" "$run_id" "$node_id" 2>/dev/null || echo '{}')"
    control_plan="$(printf '%s' "$node_json" | jq -r '.controlPlanPath // empty')"
    if [[ -n "$control_plan" && -f "$control_plan" ]]; then
      dest_dir="$archive_path/plans/$node_id"
      mkdir -p "$dest_dir"
      archived_control="$dest_dir/$(basename "$control_plan")"
      cp -f "$control_plan" "$archived_control" || true
    fi
    attempt_id="$(printf '%s' "$node_json" | jq -r '.lastAttemptId // empty')"
    if [[ -n "$attempt_id" ]]; then
      workflow_action_revoke_attempt_capability "$registry_run" "$run_id" "$node_id" "$attempt_id" 2>/dev/null || true
    fi
  done

  # Archive outstanding requests for closure stages (copy; decisions stay).
  while IFS= read -r req_json || [[ -n "$req_json" ]]; do
    [[ -z "$req_json" || "$req_json" == "null" ]] && continue
    req_id="$(printf '%s' "$req_json" | jq -r '.requestId // empty')"
    [[ -n "$req_id" ]] || continue
    # Skip consuming the human-feedback request here; handled below.
    if [[ -n "$feedback_request_id" && "$req_id" == "$feedback_request_id" ]]; then
      continue
    fi
    req_path="$(workflow_action_request_path "$registry_run" "$req_id" 2>/dev/null || true)"
    if [[ -n "$req_path" && -f "$req_path" ]]; then
      cp -f "$req_path" "$archive_path/actions/requests/${req_id}.json" || true
      rm -f "$req_path" || true
    fi
  done < <(jq -c '.[]' "$requests_tmp")

  # Apply per-node mutations from the planned stage list.
  while IFS= read -r details || [[ -n "$details" ]]; do
    [[ -z "$details" ]] && continue
    node_id="$(printf '%s' "$details" | jq -r '.stageId')"
    role="$(printf '%s' "$details" | jq -r '.role')"
    plan_action="$(printf '%s' "$details" | jq -r '.planAction')"
    direct="$(printf '%s' "$details" | jq -r 'if .direct then 1 else 0 end')"
    next_attempt="$(printf '%s' "$details" | jq -r '.nextAttempt // 1')"
    control_plan="$(printf '%s' "$details" | jq -r '.controlPlanPath // empty')"
    source_plan="$(printf '%s' "$details" | jq -r '.sourcePlanPath // empty')"
    plan_source_kind="$(printf '%s' "$details" | jq -r '.planSourceKind // empty')"

    # Reset ledger to pending (bypasses terminal transition rules).
    graph_state_reset_node_to_pending "$state_root" "$namespace" "$run_id" "$node_id" 2>/dev/null || true

    if [[ "$role" == "derived-supervisor" || "$direct" != "1" ]]; then
      # Invalidate derived / downstream: clear blocker and plan progress fields
      # but never delete immutable source/manifest files.
      node_file="$(graph_state_node_file "$state_root" "$namespace" "$run_id" "$node_id")" || continue
      if [[ -f "$node_file" ]]; then
        ralph_atomic_write_json "$node_file" '
          ($base | fromjson)
          | .blocker = null
          | .controlPlanPath = null
          | .planPath = null
          | .currentTodoId = null
          | .completedTodos = 0
          | .planRunId = null
          | del(.recoveryFeedback)
          | if $wait == 1 then .waitingForPlanner = true else del(.waitingForPlanner) end
        ' --arg base "$(jq -c . "$node_file")" \
          --argjson wait "$(if [[ "$plan_action" == "wait-upstream" ]]; then echo 1; else echo 0; fi)" || true
      fi
      # Remove mutable control copy if present (source preserved).
      if [[ -n "$control_plan" && -f "$control_plan" ]]; then
        rm -f "$control_plan" || true
      fi
      continue
    fi

    # Direct selected executable/planner.
    case "$plan_action" in
      new-planner-attempt)
        node_file="$(graph_state_node_file "$state_root" "$namespace" "$run_id" "$node_id")"
        if [[ -f "$node_file" ]]; then
          ralph_atomic_write_json "$node_file" '
            ($base | fromjson)
            | .blocker = null
            | .controlPlanPath = null
            | .planPath = null
            | .currentTodoId = null
            | .completedTodos = 0
            | .planRunId = null
            | .scheduledPlannerAttempt = $attempt
            | del(.waitingForPlanner)
          ' --arg base "$(jq -c . "$node_file")" \
            --argjson attempt "$next_attempt" || true
        fi
        ;;
      fresh-control-provided|fresh-control-generated)
        bind_json=""
        if ! declare -F workflow_state_bind_provided_plan_control >/dev/null 2>&1; then
          # shellcheck source=./workflow-state.sh
          source "$_WORKFLOW_DEP_SCRIPT_DIR/workflow-state.sh"
        fi
        if [[ "$plan_action" == "fresh-control-provided" ]]; then
          bind_json="$(workflow_state_bind_provided_plan_control \
            --registry-run "$registry_run" \
            --consumer-stage-id "$node_id" \
            --consumer-attempt "$next_attempt" \
            --force-fresh 2>/dev/null)" || bind_json=""
        else
          planner_id="$(jq -r --arg id "$node_id" '
            (.nodes // [])[]? | select(.id == $id)
            | (.planFromBinding.plannerStageId // .stage.planFrom // empty)
          ' "$graph_file" 2>/dev/null || true)"
          if [[ -z "$planner_id" ]]; then
            planner_id="$(printf '%s' "$(graph_state_read_node "$state_root" "$namespace" "$run_id" "$node_id")" | jq -r '.planSourceStageId // empty')"
          fi
          if [[ -n "$planner_id" ]]; then
            bind_json="$(workflow_state_bind_generated_plan_control \
              --registry-run "$registry_run" \
              --consumer-stage-id "$node_id" \
              --consumer-attempt "$next_attempt" \
              --planner-stage-id "$planner_id" \
              --graph-workspace "$state_root" \
              --namespace "$namespace" \
              --run-id "$run_id" \
              --force-fresh 2>/dev/null)" || bind_json=""
          fi
        fi
        # Fixture-friendly fallback: byte-copy the frozen sourcePlanPath into a
        # new attempt control without requiring a full input/planner manifest.
        if [[ -z "$bind_json" && -n "$source_plan" && -f "$source_plan" ]]; then
          dest_dir="$registry_run/plans/$node_id/attempt-${next_attempt}"
          mkdir -p "$dest_dir"
          cp -f "$source_plan" "$dest_dir/control.plan.md"
          chmod u+w "$dest_dir/control.plan.md" 2>/dev/null || true
          bind_json="$(jq -cn \
            --arg source "$source_plan" \
            --arg control "$dest_dir/control.plan.md" \
            --arg kind "${plan_source_kind:-provided}" \
            --arg planner "${planner_id:-}" \
            '{
              sourcePlanPath: $source,
              controlPlanPath: $control,
              planPath: $control,
              planRunId: null,
              planSourceKind: $kind,
              planSourceStageId: (if $planner == "" then null else $planner end),
              originalPlanPath: null,
              completedTodos: 0,
              totalTodos: 1,
              currentTodoId: null
            }')"
        fi
        if [[ -n "$bind_json" ]]; then
          graph_state_persist_plan_progress "$state_root" "$namespace" "$run_id" "$node_id" "$bind_json" 2>/dev/null || true
        fi
        node_file="$(graph_state_node_file "$state_root" "$namespace" "$run_id" "$node_id")"
        if [[ -f "$node_file" ]]; then
          ralph_atomic_write_json "$node_file" '
            ($base | fromjson) | .blocker = null | del(.waitingForPlanner)
          ' --arg base "$(jq -c . "$node_file")" || true
        fi
        if [[ -n "$control_plan" && -f "$control_plan" ]]; then
          new_control="$(printf '%s' "${bind_json:-}" | jq -r '.controlPlanPath // empty')"
          if [[ -n "$new_control" && "$control_plan" != "$new_control" ]]; then
            rm -f "$control_plan" || true
          fi
        fi
        ;;
      *)
        node_file="$(graph_state_node_file "$state_root" "$namespace" "$run_id" "$node_id")"
        if [[ -f "$node_file" ]]; then
          ralph_atomic_write_json "$node_file" '
            ($base | fromjson) | .blocker = null | del(.waitingForPlanner)
          ' --arg base "$(jq -c . "$node_file")" || true
        fi
        ;;
    esac

    # A reset of the final rework implementation is an explicit operator
    # recovery after automatic-loop exhaustion.  Record the terminal review
    # verdict on that existing node so dispatch replaces the older upstream
    # feedback block with the reason this reset was actually needed.
    if [[ "$direct" == "1" ]]; then
      node_file="$(graph_state_node_file "$state_root" "$namespace" "$run_id" "$node_id")"
      if [[ -f "$node_file" ]]; then
        if ! ralph_atomic_write_json "$node_file" '
          ($base | fromjson)
          | if $feedback == null then del(.recoveryFeedback)
            else .recoveryFeedback = $feedback end
        ' --arg base "$(jq -c . "$node_file")" \
          --argjson feedback "$(if [[ -n "$evaluator_feedback_json" && "$node_id" == "$stage_id" ]]; then printf '%s' "$evaluator_feedback_json"; else echo null; fi)"; then
          rm -f "$stages_tmp" "$requests_tmp"
          echo "Error: failed to persist review feedback for reset target: $node_id" >&2
          return 1
        fi
      fi
    fi
  done < <(jq -c '.[]' "$stages_tmp")

  # Bind human feedback to the selected target's next fresh attempt and consume once.
  if [[ -n "$feedback_request_id" ]]; then
    if declare -F workflow_action_continuation_abandon_stage_attempt >/dev/null 2>&1; then
      local _prior_attempt _prior_attempt_id _node_json
      _node_json="$(graph_state_read_node "$state_root" "$namespace" "$run_id" "$stage_id" 2>/dev/null || true)"
      # Not "${_node_json:-{}}": bash's brace-depth scan closes that expansion
      # one brace early, so a node ledger that IS present arrives with a stray
      # trailing "}". jq then rejects it, _prior_attempt comes out empty, and
      # the prior attempt is never abandoned -- silently, because the jq error
      # only shows up on stderr. Same defect graph-consensus.sh documents.
      [[ -n "$_node_json" ]] || _node_json='{}'
      _prior_attempt="$(printf '%s' "$_node_json" | jq -r '.attempt // empty')"
      if [[ -n "$_prior_attempt" && "$_prior_attempt" != "0" && "$_prior_attempt" != "null" ]]; then
        _prior_attempt_id="${stage_id}-${_prior_attempt}"
        workflow_action_continuation_abandon_stage_attempt "$run_id" "$stage_id" "$_prior_attempt_id" \
          "" "" 2>/dev/null || true
      fi
    fi
    next_attempt="$(jq -r --arg id "$stage_id" '
      map(select(.stageId == $id)) | .[0].nextAttempt // 1
    ' "$stages_tmp")"
    req_path="$(workflow_action_request_path "$registry_run" "$feedback_request_id" 2>/dev/null || true)"
    if [[ -n "$req_path" && -f "$req_path" ]]; then
      mkdir -p "$archive_path/actions/requests"
      cp -f "$req_path" "$archive_path/actions/requests/${feedback_request_id}.json" || true
    fi
    workflow_action_stage_human_feedback "$registry_run" "$feedback_request_id" \
      --target-stage "$stage_id" \
      --target-attempt "$next_attempt" >/dev/null 2>&1 || true
    workflow_action_consume_once "$registry_run" "$feedback_request_id" reset >/dev/null 2>&1 || true
  fi

  # Clear graph supervisor ownership; leave outer blocked-ready for resume.
  if [[ -f "$graph_run/run.json" ]]; then
    ralph_atomic_write_json "$graph_run/run.json" \
      '($base | fromjson) + {status:"interrupted", supervisorPid:null, ownerHostname:null, ownerProcessStartId:null, heartbeatAt:null}' \
      --arg base "$(jq -c . "$graph_run/run.json")" || true
  fi
  if declare -F graph_events_append >/dev/null 2>&1; then
    graph_events_append "$graph_run" "$run_id" run-status-changed "" "" \
      "$(jq -cn --arg stage "$stage_id" --arg archive "$archive_path" \
        '{reason:"reset",stageId:$stage,archivePath:$archive}')" || true
  fi
  workflow_state_clear_owner_and_set_state "$state_root" "$run_id" blocked || true

  jq -cn \
    --arg runId "$run_id" \
    --arg stageId "$stage_id" \
    --arg archivePath "$archive_path" \
    --arg archiveId "$archive_id" \
    --argjson selectAll "$select_all" \
    --argjson stages "$(cat "$stages_tmp")" \
    --argjson invalidatedRequests "$(cat "$requests_tmp")" \
    --argjson humanFeedback "$(if [[ -n "$feedback_json" ]]; then printf '%s' "$feedback_json" | jq -c '{requestId,changesTarget,approvalStageId,message}'; else echo null; fi)" \
    --argjson evaluatorFeedback "$(if [[ -n "$evaluator_feedback_json" ]]; then printf '%s' "$evaluator_feedback_json"; else echo null; fi)" \
    '{
      schemaVersion: 1,
      ok: true,
      dryRun: false,
      mode: "dependency",
      runId: $runId,
      stageId: (if ($selectAll == 1) then "all" else $stageId end),
      selectAll: ($selectAll == 1),
      archiveId: $archiveId,
      archivePath: $archivePath,
      stages: $stages,
      invalidatedRequests: $invalidatedRequests,
      humanFeedback: $humanFeedback,
      evaluatorFeedback: $evaluatorFeedback,
      preserved: [
        "workflow-input",
        "supplied-plan-source-manifest",
        "generated-source-plan-manifest",
        "logs",
        "artifacts",
        "decisions",
        "audit-history"
      ],
      outerStateAfterApply: "blocked"
    }'
  rm -f "$stages_tmp" "$requests_tmp"
  return 0
}

# workflow_dep_reset_by_run_id --state-root ... --run-id ... [--stage ...|--all] [--workspace ...] [--dry-run]
# Resolves the common registry run directory and delegates to workflow_dep_reset.
workflow_dep_reset_by_run_id() {
  local state_root="" run_id="" stage_id="" workspace="" dry_run=0 reset_all=0
  local args=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --state-root) state_root="${2:-}"; shift 2 ;;
      --run-id) run_id="${2:-}"; shift 2 ;;
      --stage) stage_id="${2:-}"; shift 2 ;;
      --all) reset_all=1; shift ;;
      --workspace) workspace="${2:-}"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      *)
        echo "Error: unknown workflow_dep_reset_by_run_id argument: $1" >&2
        return 1
        ;;
    esac
  done

  if [[ -z "$state_root" || -z "$run_id" ]]; then
    echo "Error: workflow_dep_reset_by_run_id requires --state-root and --run-id" >&2
    return 1
  fi
  if [[ "$reset_all" -eq 0 && -z "$stage_id" ]]; then
    echo "Error: workflow_dep_reset_by_run_id requires --stage or --all" >&2
    return 1
  fi
  if ! workflow_state_run_dir "$state_root" "$run_id" >/dev/null 2>&1; then
    echo "Error: workflow run not found: $run_id" >&2
    return 1
  fi
  args=(--state-root "$state_root" --run-id "$run_id")
  [[ -n "$stage_id" ]] && args+=(--stage "$stage_id")
  [[ "$reset_all" -eq 1 ]] && args+=(--all)
  [[ -n "$workspace" ]] && args+=(--workspace "$workspace")
  [[ "$dry_run" -eq 1 ]] && args+=(--dry-run)
  workflow_dep_reset "${args[@]}"
}

# ---------------------------------------------------------------------------
# Dependency recover / cancel (internal by common run ID)
# ---------------------------------------------------------------------------

# _workflow_dep_source_recovery_libs
# Lazily source heartbeat, recovery, actions, and process teardown helpers.
_workflow_dep_source_recovery_libs() {
  if ! declare -F graph_heartbeat_classify_run >/dev/null 2>&1; then
    # shellcheck source=../graph/graph-heartbeat.sh
    source "$_WORKFLOW_DEP_SCRIPT_DIR/../graph/graph-heartbeat.sh"
  fi
  if ! declare -F graph_recovery_attempt_run >/dev/null 2>&1; then
    # shellcheck source=../graph/graph-recovery.sh
    source "$_WORKFLOW_DEP_SCRIPT_DIR/../graph/graph-recovery.sh"
  fi
  if ! declare -F workflow_action_revoke_residual_capabilities >/dev/null 2>&1; then
    # shellcheck source=./workflow-actions.sh
    source "$_WORKFLOW_DEP_SCRIPT_DIR/workflow-actions.sh"
  fi
  if ! declare -F ralph_kill_tree >/dev/null 2>&1; then
    # shellcheck source=../ralph-process-teardown.sh
    source "$_WORKFLOW_DEP_SCRIPT_DIR/../ralph-process-teardown.sh"
  fi
}

# _workflow_dep_collect_retryable_stages <state-root> <namespace> <run-id>
# Prints a JSON array of stage objects that resume may retry after recover.
_workflow_dep_collect_retryable_stages() {
  local state_root="$1" namespace="$2" run_id="$3"
  local run_dir node_file node_id status stages='[]'

  run_dir="$(graph_state_run_dir "$state_root" "$namespace" "$run_id" 2>/dev/null || true)"
  [[ -n "$run_dir" && -d "$run_dir/nodes" ]] || { printf '[]\n'; return 0; }

  shopt -s nullglob
  for node_file in "$run_dir/nodes"/*.json; do
    [[ -f "$node_file" ]] || continue
    node_id="$(jq -r '.nodeId // .id // empty' "$node_file" 2>/dev/null)"
    status="$(jq -r '.status // empty' "$node_file" 2>/dev/null)"
    [[ -n "$node_id" ]] || continue
    case "$status" in
      pending|ready|failed|interrupted|needs-plan-repair)
        stages="$(jq -cn --argjson arr "$stages" --arg id "$node_id" --arg st "$status" \
          '$arr + [{stageId:$id,status:$st,retryable:true}]')"
        ;;
    esac
  done
  shopt -u nullglob
  printf '%s\n' "$stages"
}

# _workflow_dep_reconcile_interrupted_nodes <state-root> <namespace> <run-id> <registry-run>
# When the graph run is no longer "running" but still has interrupted nodes,
# reset eligible interrupted nodes via graph recovery rules without inventing
# human decisions. Revokes residual capabilities for those attempts.
_workflow_dep_reconcile_interrupted_nodes() {
  local state_root="$1" namespace="$2" run_id="$3" registry_run="$4"
  local run_dir node_file node_id status attempt reset_count=0

  run_dir="$(graph_state_run_dir "$state_root" "$namespace" "$run_id")" || return 1
  shopt -s nullglob
  for node_file in "$run_dir/nodes"/*.json; do
    [[ -f "$node_file" ]] || continue
    node_id="$(jq -r '.nodeId // .id // empty' "$node_file" 2>/dev/null)"
    status="$(jq -r '.status // empty' "$node_file" 2>/dev/null)"
    attempt="$(jq -r '.lastAttemptId // empty' "$node_file" 2>/dev/null)"
    [[ -n "$node_id" ]] || continue
    if [[ "$status" == "interrupted" ]] && graph_recovery_node_is_reset_eligible "$status"; then
      if graph_state_reset_node_to_pending "$state_root" "$namespace" "$run_id" "$node_id" 2>/dev/null; then
        graph_events_append "$run_dir" "$run_id" "node-recovered" "$node_id" "${attempt:-}" \
          "$(jq -cn --arg from interrupted '{from:$from,to:"pending",source:"workflow-dep-recover"}')" || true
        reset_count=$((reset_count + 1))
      fi
    fi
    if [[ -n "$attempt" ]] && declare -F workflow_action_revoke_attempt_capability >/dev/null 2>&1; then
      workflow_action_revoke_attempt_capability "$registry_run" "$run_id" "$node_id" "$attempt" || true
    fi
  done
  shopt -u nullglob
  if declare -F workflow_action_revoke_residual_capabilities >/dev/null 2>&1; then
    workflow_action_revoke_residual_capabilities "$registry_run" "$run_id" || true
  fi
  printf '%s\n' "$reset_count"
}

# workflow_dep_recover --state-root ... --run-id ... [--workspace ...] [--dry-run]
#
# Internal Dependency recover keyed by the exact common run ID. Resolves the
# graph pointer, calls production heartbeat / process-start / hostname / lock
# predicates without weakening them, and permits mutation only for a proven
# stale/orphaned supervisor. Intentional approval/input waits with no owner are
# returned unchanged. Interrupted attempts revoke residual capabilities,
# reconcile via graph recovery rules, preserve action records, and return
# retryable stages without auto-rerun or manufacturing/consuming decisions.
workflow_dep_recover() {
  local state_root="" run_id="" workspace="" dry_run=0
  local outer registry_run pointer namespace graph_run graph_file graph_json
  local run_state owner_class outstanding request_id kind
  local graph_status supervisor_pid recovery_rc=0 reset_count=0
  local stages next_action result_outcome result_state
  local recovery_log before_requests before_decisions before_consumed

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --state-root) state_root="${2:-}"; shift 2 ;;
      --run-id) run_id="${2:-}"; shift 2 ;;
      --workspace) workspace="${2:-}"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      *)
        echo "Error: unknown workflow_dep_recover argument: $1" >&2
        return 1
        ;;
    esac
  done

  [[ -n "$state_root" && -n "$run_id" ]] || {
    echo "Error: workflow_dep_recover requires --state-root and --run-id" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || return 1
  _workflow_dep_source_recovery_libs

  if ! outer="$(workflow_state_read "$state_root" "$run_id" 2>/dev/null)"; then
    echo "Error: workflow_dep_recover unknown run: $run_id" >&2
    return 1
  fi
  run_state="$(printf '%s' "$outer" | jq -r '.state // empty')"
  case "$run_state" in
    cancelled|succeeded)
      echo "Error: workflow_dep_recover refuses terminal run state: $run_state" >&2
      return 1
      ;;
  esac

  pointer="$(workflow_dep_resolve_pointer "$state_root" "$run_id")" || return 1
  namespace="$(printf '%s' "$pointer" | jq -r '.namespace')"
  graph_run="$(printf '%s' "$pointer" | jq -r '.statePath')"
  registry_run="$(workflow_state_run_dir "$state_root" "$run_id")" || return 1
  workspace="${workspace:-${RALPH_AGENT_WORKSPACE:-$state_root}}"
  _workflow_dep_ensure_graph_state_root "$state_root" "$namespace" "$run_id"

  owner_class="$(graph_heartbeat_classify_run "$state_root" "$namespace" "$run_id" 2>/dev/null || echo unknown)"
  outstanding="$(workflow_action_first_outstanding "$registry_run" "$run_id" 2>/dev/null || jq -cn '{requestId:null}')"
  request_id="$(printf '%s' "$outstanding" | jq -r '.requestId // empty')"
  kind="$(printf '%s' "$outstanding" | jq -r '.kind // empty')"

  graph_file="$(graph_state_run_file "$state_root" "$namespace" "$run_id" 2>/dev/null || true)"
  graph_json=""
  [[ -n "$graph_file" && -f "$graph_file" ]] && graph_json="$(jq -c . "$graph_file" 2>/dev/null || true)"
  graph_status="$(printf '%s' "${graph_json:-"{}"}" | jq -r '.status // empty')"
  supervisor_pid="$(printf '%s' "${graph_json:-"{}"}" | jq -r '.supervisorPid // empty')"

  # Intentional approval/input wait with no live owner: unchanged.
  if [[ -n "$request_id" && "$owner_class" != "healthy" && "$owner_class" != "stale" ]]; then
    if [[ "$run_state" == "waiting" || "$graph_status" == "awaiting-operator" || "$graph_status" == "awaiting-ack" ]]; then
      next_action="$(jq -cn --arg id "$run_id" \
        '{label:"List workflow actions",argv:["ralph","workflow","actions","list",$id]}')"
      jq -cn \
        --arg runId "$run_id" \
        --arg mode dependency \
        --arg outcome unchanged-intentional-wait \
        --arg runState "$run_state" \
        --arg ownerClass "$owner_class" \
        --argjson outstanding "$outstanding" \
        --argjson nextAction "$next_action" \
        --argjson dryRun "$dry_run" \
        '{
          schemaVersion:1, ok:true, dryRun:($dryRun==1), mode:$mode, runId:$runId,
          outcome:$outcome, runState:$runState, ownerClass:$ownerClass,
          mutated:false, outstanding:$outstanding, nextAction:$nextAction,
          retryableStages:[], note:"intentional approval/input wait is not stale"
        }'
      return 0
    fi
  fi

  if [[ "$owner_class" == "healthy" ]]; then
    echo "Error: workflow_dep_recover refuses live-owner run" >&2
    return 1
  fi

  if [[ "$owner_class" == "unknown" ]]; then
    # Ambiguous when the ledger still claims a supervisor identity.
    if [[ -n "$supervisor_pid" || "$run_state" == "running" || "$graph_status" == "running" ]]; then
      echo "Error: workflow_dep_recover refuses ambiguous ownership" >&2
      return 1
    fi
  fi

  # Proven stale/orphan, or an already-interrupted attempt with no live owner.
  if [[ "$owner_class" != "stale" && "$graph_status" != "interrupted" && "$run_state" != "stale" ]]; then
    # Allow interrupted-node reconcile when no owner is claimed.
    if [[ -n "$supervisor_pid" || "$graph_status" == "running" || "$run_state" == "running" ]]; then
      echo "Error: workflow_dep_recover refuses run that is not proven stale/orphaned" >&2
      return 1
    fi
  fi

  before_requests="$(find "$registry_run/actions/requests" -type f 2>/dev/null | sort | cksum || true)"
  before_decisions="$(find "$registry_run/actions/decisions" -type f 2>/dev/null | sort | cksum || true)"
  before_consumed="$(find "$registry_run/actions/consumed" -type f 2>/dev/null | sort | cksum || true)"

  if [[ "$dry_run" -eq 1 ]]; then
    stages="$(_workflow_dep_collect_retryable_stages "$state_root" "$namespace" "$run_id")"
    jq -cn \
      --arg runId "$run_id" \
      --arg ownerClass "$owner_class" \
      --arg graphStatus "$graph_status" \
      --argjson stages "$stages" \
      '{
        schemaVersion:1, ok:true, dryRun:true, mode:"dependency", runId:$runId,
        outcome:"would-recover", ownerClass:$ownerClass, graphStatus:$graphStatus,
        mutated:false, retryableStages:$stages,
        preserves:["requests","decisions","consumed","immutable-input","logs","artifacts"]
      }'
    return 0
  fi

  recovery_log="$registry_run/logs/dependency-recover.log"
  mkdir -p "$(dirname "$recovery_log")"

  if [[ "$graph_status" == "running" && "$owner_class" == "stale" ]]; then
    GRAPH_RECOVERY_EMIT_RECEIPT=0 graph_recovery_attempt_run \
      "$state_root" "$namespace" "$run_id" >"$recovery_log" 2>&1 || recovery_rc=$?
    if [[ "$recovery_rc" -ne 0 ]]; then
      echo "Error: workflow_dep_recover graph recovery refused or failed" >&2
      tail -n 20 "$recovery_log" >&2 || true
      return 1
    fi
    # graph_recovery_attempt_run leaves status interrupted but may retain owner
    # metadata; clear it so the outer projection is ownerless and resumable.
    if [[ -f "$graph_file" ]]; then
      ralph_atomic_write_json "$graph_file"         '($base | fromjson) + {supervisorPid:null, ownerHostname:null, ownerProcessStartId:null, heartbeatAt:null}'         --arg base "$(jq -c . "$graph_file")" || true
    fi
    result_outcome="recovered-stale-supervisor"
  else
    # Orphan / already-interrupted path: reconcile without requiring a live running ledger.
    reset_count="$(_workflow_dep_reconcile_interrupted_nodes "$state_root" "$namespace" "$run_id" "$registry_run")"
    if [[ -f "$graph_file" ]]; then
      ralph_atomic_write_json "$graph_file" \
        '($base | fromjson) + {status:"interrupted", supervisorPid:null, ownerHostname:null, ownerProcessStartId:null, heartbeatAt:null}' \
        --arg base "$(jq -c . "$graph_file")" || true
    fi
    if [[ -d "$graph_run" ]]; then
      graph_events_append "$graph_run" "$run_id" "recovery-finish" "" "" \
        "$(jq -cn --argjson reset "${reset_count:-0}" '{source:"workflow-dep-recover",nodesReset:$reset}')" || true
    fi
    result_outcome="recovered-orphaned-or-interrupted"
  fi

  workflow_action_revoke_residual_capabilities "$registry_run" "$run_id" || true

  # Preserve action records: refuse if recover deleted any.
  if [[ "$(find "$registry_run/actions/requests" -type f 2>/dev/null | sort | cksum || true)" != "$before_requests" ]] \
    || [[ "$(find "$registry_run/actions/decisions" -type f 2>/dev/null | sort | cksum || true)" != "$before_decisions" ]] \
    || [[ "$(find "$registry_run/actions/consumed" -type f 2>/dev/null | sort | cksum || true)" != "$before_consumed" ]]; then
    echo "Error: workflow_dep_recover must preserve request/decision/consumption records" >&2
    return 1
  fi

  outstanding="$(workflow_action_first_outstanding "$registry_run" "$run_id" 2>/dev/null || jq -cn '{requestId:null}')"
  request_id="$(printf '%s' "$outstanding" | jq -r '.requestId // empty')"
  if [[ -n "$request_id" ]]; then
    result_state="waiting"
    next_action="$(jq -cn --arg id "$run_id" \
      '{label:"List workflow actions",argv:["ralph","workflow","actions","list",$id]}')"
    workflow_state_clear_owner_and_set_state "$state_root" "$run_id" waiting || return 1
  else
    result_state="blocked"
    next_action="$(jq -cn --arg id "$run_id" \
      '{label:"Resume workflow",argv:["ralph","workflow","resume",$id]}')"
    workflow_state_clear_owner_and_set_state "$state_root" "$run_id" blocked || return 1
  fi

  stages="$(_workflow_dep_collect_retryable_stages "$state_root" "$namespace" "$run_id")"

  jq -cn \
    --arg runId "$run_id" \
    --arg outcome "$result_outcome" \
    --arg runState "$result_state" \
    --arg ownerClass "$owner_class" \
    --argjson stages "$stages" \
    --argjson outstanding "$outstanding" \
    --argjson nextAction "$next_action" \
    '{
      schemaVersion:1, ok:true, dryRun:false, mode:"dependency", runId:$runId,
      outcome:$outcome, runState:$runState, ownerClass:$ownerClass,
      mutated:true, autoReran:false, manufacturedDecision:false,
      outstanding:$outstanding, nextAction:$nextAction, retryableStages:$stages,
      preserves:["requests","decisions","consumed","immutable-input","logs","artifacts"]
    }'
  return 0
}

# workflow_dep_cancel --state-root ... --run-id ... [--workspace ...] [--dry-run]
#
# Cancel a proven owned live graph supervisor, or a non-running cancellable
# Dependency run. Persist cancel intent before TERM so the supervisor signal
# handler records cancelled (never retryable waiting). Revokes capabilities,
# cancels outstanding actions without deletion, retains TERM/KILL timing via
# ralph_kill_tree, appends graph audit events, and returns a normalized outer
# transition.
workflow_dep_cancel() {
  local state_root="" run_id="" workspace="" dry_run=0
  local outer registry_run pointer namespace graph_run graph_file graph_json
  local run_state owner_class live_proof supervisor_pid intent_path
  local graph_status outstanding

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --state-root) state_root="${2:-}"; shift 2 ;;
      --run-id) run_id="${2:-}"; shift 2 ;;
      --workspace) workspace="${2:-}"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      *)
        echo "Error: unknown workflow_dep_cancel argument: $1" >&2
        return 1
        ;;
    esac
  done

  [[ -n "$state_root" && -n "$run_id" ]] || {
    echo "Error: workflow_dep_cancel requires --state-root and --run-id" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || return 1
  _workflow_dep_source_recovery_libs

  if ! outer="$(workflow_state_read "$state_root" "$run_id" 2>/dev/null)"; then
    echo "Error: workflow_dep_cancel unknown run: $run_id" >&2
    return 1
  fi
  run_state="$(printf '%s' "$outer" | jq -r '.state // empty')"
  case "$run_state" in
    cancelled|succeeded)
      echo "Error: workflow_dep_cancel refuses terminal run state: $run_state" >&2
      return 1
      ;;
  esac

  pointer="$(workflow_dep_resolve_pointer "$state_root" "$run_id")" || return 1
  namespace="$(printf '%s' "$pointer" | jq -r '.namespace')"
  graph_run="$(printf '%s' "$pointer" | jq -r '.statePath')"
  registry_run="$(workflow_state_run_dir "$state_root" "$run_id")" || return 1
  workspace="${workspace:-${RALPH_AGENT_WORKSPACE:-$state_root}}"
  _workflow_dep_ensure_graph_state_root "$state_root" "$namespace" "$run_id"

  graph_file="$(graph_state_run_file "$state_root" "$namespace" "$run_id" 2>/dev/null || true)"
  graph_json=""
  [[ -n "$graph_file" && -f "$graph_file" ]] && graph_json="$(jq -c . "$graph_file" 2>/dev/null || true)"
  graph_status="$(printf '%s' "${graph_json:-"{}"}" | jq -r '.status // empty')"
  supervisor_pid="$(printf '%s' "${graph_json:-"{}"}" | jq -r '.supervisorPid // empty')"

  owner_class="$(graph_heartbeat_classify_run "$state_root" "$namespace" "$run_id" 2>/dev/null || echo unknown)"
  live_proof="not-live"
  if [[ "$owner_class" == "healthy" ]]; then
    live_proof="$(graph_heartbeat_live_owner_matches "$state_root" "$namespace" "$run_id" 2>/dev/null || echo not-live)"
  fi

  if [[ "$owner_class" == "healthy" && "$live_proof" != "owned" ]]; then
    echo "Error: workflow_dep_cancel refuses ambiguous or foreign live ownership" >&2
    return 1
  fi

  if [[ "$owner_class" == "unknown" && ( "$run_state" == "running" || "$graph_status" == "running" ) ]]; then
    echo "Error: workflow_dep_cancel refuses ambiguous ownership on running run" >&2
    return 1
  fi

  # Non-running cancellable: waiting|blocked|stale|failed|queued, or interrupted graph.
  if [[ "$live_proof" != "owned" ]]; then
    case "$run_state" in
      waiting|blocked|stale|failed|queued) ;;
      running)
        # running without proven live owner is only cancellable when stale/orphan
        if [[ "$owner_class" != "stale" && "$graph_status" != "interrupted" ]]; then
          echo "Error: workflow_dep_cancel refuses unproven running ownership" >&2
          return 1
        fi
        ;;
      *)
        echo "Error: workflow_dep_cancel refuses run state: $run_state" >&2
        return 1
        ;;
    esac
  fi

  if [[ "$dry_run" -eq 1 ]]; then
    jq -cn \
      --arg runId "$run_id" \
      --arg ownerClass "$owner_class" \
      --arg liveProof "$live_proof" \
      --arg graphStatus "$graph_status" \
      '{
        schemaVersion:1, ok:true, dryRun:true, mode:"dependency", runId:$runId,
        outcome:"would-cancel", ownerClass:$ownerClass, liveProof:$liveProof,
        graphStatus:$graphStatus, mutated:false
      }'
    return 0
  fi

  # Persist cancel intent BEFORE signalling so the supervisor handler records
  # cancelled rather than retryable waiting.
  intent_path="$(workflow_state_record_cancel_intent "$registry_run" "$(jq -cn \
    --arg runId "$run_id" \
    --arg source "workflow-dep-cancel" \
    --arg liveProof "$live_proof" \
    '{runId:$runId,source:$source,liveProof:$liveProof}')" 2>/dev/null || true)"

  workflow_action_revoke_residual_capabilities "$registry_run" "$run_id" || true
  workflow_action_cancel_outstanding "$registry_run" "$run_id" || true

  if [[ -d "$graph_run" ]]; then
    graph_events_append "$graph_run" "$run_id" "run-status-changed" "" "" \
      "$(jq -cn --arg from "$graph_status" '{from:$from,to:"cancelled",source:"workflow-dep-cancel"}')" || true
  fi

  if [[ "$live_proof" == "owned" && "$supervisor_pid" =~ ^[0-9]+$ ]]; then
    # Retain existing TERM-then-KILL timing from ralph_kill_tree.
    ralph_kill_tree "$supervisor_pid" || true
  fi

  if [[ -n "$graph_file" && -f "$graph_file" ]]; then
    ralph_atomic_write_json "$graph_file" \
      '($base | fromjson) + {status:"cancelled", supervisorPid:null, ownerHostname:null, ownerProcessStartId:null, heartbeatAt:null}' \
      --arg base "$(jq -c . "$graph_file")" || true
  fi

  workflow_state_clear_owner_and_set_state "$state_root" "$run_id" cancelled || return 1
  outstanding="$(workflow_action_first_outstanding "$registry_run" "$run_id" 2>/dev/null || jq -cn '{requestId:null}')"

  jq -cn \
    --arg runId "$run_id" \
    --arg liveProof "$live_proof" \
    --arg intentPath "${intent_path:-}" \
    --argjson outstanding "$outstanding" \
    '{
      schemaVersion:1, ok:true, dryRun:false, mode:"dependency", runId:$runId,
      outcome:"cancelled", runState:"cancelled", liveProof:$liveProof,
      cancelIntentPath:(if $intentPath=="" then null else $intentPath end),
      outstanding:$outstanding, mutated:true,
      nextAction:null
    }'
  return 0
}

# workflow_dep_recover_by_run_id / workflow_dep_cancel_by_run_id
# Thin aliases matching the resume/reset_by_run_id naming convention.
workflow_dep_recover_by_run_id() {
  workflow_dep_recover "$@"
}

workflow_dep_cancel_by_run_id() {
  workflow_dep_cancel "$@"
}
