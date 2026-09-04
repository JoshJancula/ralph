#!/usr/bin/env bash
# Durable, scheduler-owned FIFO for delegated runs. Queue entries contain
# scheduler metadata in addition to the immutable ledger request. This module
# never starts a runtime.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi
if [[ -n "${GRAPH_DELEGATION_QUEUE_LOADED:-}" ]]; then return 0; fi
GRAPH_DELEGATION_QUEUE_LOADED=1

_GRAPH_DELEGATION_QUEUE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F ralph_wait >/dev/null 2>&1; then
  # shellcheck source=../ralph-wait.sh
  source "$_GRAPH_DELEGATION_QUEUE_DIR/../ralph-wait.sh"
fi
if ! declare -F graph_delegation_ledger_request_file >/dev/null 2>&1; then
  source "$_GRAPH_DELEGATION_QUEUE_DIR/graph-delegation-ledger.sh"
fi

graph_delegation_queue_file() {
  local workspace="$1" namespace="${2:-}" run_id="${3:-}" state_root
  state_root="$(graph_state_state_root "$workspace")" || return 1
  if [[ -n "$namespace" && -n "$run_id" ]]; then
    printf '%s/delegation-queue.json\n' "$(graph_state_run_dir "$workspace" "$namespace" "$run_id")"
  else
    printf '%s/delegation-queue.json\n' "$state_root"
  fi
}

graph_delegation_queue_lock_dir() {
  local queue
  queue="$(graph_delegation_queue_file "$@")" || return 1
  printf '%s.lock\n' "$queue"
}

graph_delegation_queue_log() {
  local workspace="$1"; shift
  local state_root path
  state_root="$(graph_state_state_root "$workspace")" || return 0
  path="$state_root/logs/delegation-queue.log"
  mkdir -p "$(dirname "$path")" 2>/dev/null || true
  printf '[%s] delegation-queue: %s\n' "$(graph_state_now_iso)" "$*" >>"$path" 2>/dev/null || true
}

_graph_delegation_queue_lock() {
  local lock="$1" deadline
  mkdir -p "$(dirname "$lock")" || return 1
  deadline=$(( $(date +%s) + 10 ))
  while ! mkdir "$lock" 2>/dev/null; do
    [[ $(date +%s) -lt $deadline ]] || return 1
    ralph_wait 1
  done
}
_graph_delegation_queue_unlock() { rmdir "$1" 2>/dev/null || true; }

# Set the long-form graph-run context or the short ledger-focused context.
_graph_delegation_queue_args() {
  if [[ "$#" -ge 6 && "$5" =~ ^delegated-run-[0-9a-f]{24}$ ]]; then
    GRAPH_DELEGATION_QUEUE_WORKSPACE="$1"
    GRAPH_DELEGATION_QUEUE_NAMESPACE="$2"
    GRAPH_DELEGATION_QUEUE_RUN_ID="$3"
    GRAPH_DELEGATION_QUEUE_PARENT="$4"
    GRAPH_DELEGATION_QUEUE_ID="$5"
    if [[ "$6" == \{* ]]; then
      GRAPH_DELEGATION_QUEUE_MAX_RUNS="$(jq -r '.maxRuns // empty' <<<"$6" 2>/dev/null)"
      GRAPH_DELEGATION_QUEUE_MAX_PARALLEL="$(jq -r '.maxParallel // 0' <<<"$6" 2>/dev/null)"
    else
      GRAPH_DELEGATION_QUEUE_MAX_RUNS="$6"
      GRAPH_DELEGATION_QUEUE_MAX_PARALLEL="${7:-0}"
    fi
  elif [[ "$#" -ge 5 ]]; then
    GRAPH_DELEGATION_QUEUE_WORKSPACE="$1"
    GRAPH_DELEGATION_QUEUE_NAMESPACE=''
    GRAPH_DELEGATION_QUEUE_RUN_ID=''
    GRAPH_DELEGATION_QUEUE_PARENT="$3"
    GRAPH_DELEGATION_QUEUE_ID="$2"
    if [[ "$4" == \{* ]]; then
      GRAPH_DELEGATION_QUEUE_MAX_RUNS="$(jq -r '.maxRuns // empty' <<<"$4" 2>/dev/null)"
      GRAPH_DELEGATION_QUEUE_MAX_PARALLEL="$(jq -r '.maxParallel // 0' <<<"$4" 2>/dev/null)"
    else
      GRAPH_DELEGATION_QUEUE_MAX_RUNS="$4"
      GRAPH_DELEGATION_QUEUE_MAX_PARALLEL="${5:-0}"
    fi
  elif [[ "$#" -eq 4 && "$2" =~ ^delegated-run-[0-9a-f]{24}$ ]]; then
    GRAPH_DELEGATION_QUEUE_WORKSPACE="$1"
    GRAPH_DELEGATION_QUEUE_NAMESPACE=''
    GRAPH_DELEGATION_QUEUE_RUN_ID=''
    GRAPH_DELEGATION_QUEUE_PARENT="$3"
    GRAPH_DELEGATION_QUEUE_ID="$2"
    GRAPH_DELEGATION_QUEUE_MAX_RUNS="$(jq -r '.maxRuns // empty' <<<"$4" 2>/dev/null)"
    GRAPH_DELEGATION_QUEUE_MAX_PARALLEL="$(jq -r '.maxParallel // 0' <<<"$4" 2>/dev/null)"
  else
    return 1
  fi
  [[ "$GRAPH_DELEGATION_QUEUE_MAX_RUNS" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ "$GRAPH_DELEGATION_QUEUE_MAX_PARALLEL" =~ ^[0-9]+$ ]] || return 1
  if [[ "$GRAPH_DELEGATION_QUEUE_MAX_PARALLEL" -gt 0 && "$GRAPH_DELEGATION_QUEUE_MAX_PARALLEL" -gt "$GRAPH_DELEGATION_QUEUE_MAX_RUNS" ]]; then
    return 1
  fi
}

_graph_delegation_queue_status() {
  graph_delegation_ledger_read_status "$1" "$2" 2>/dev/null
}
_graph_delegation_queue_status_name() {
  _graph_delegation_queue_status "$1" "$2" | jq -r '.status // empty' 2>/dev/null
}
_graph_delegation_queue_entry_id() { jq -r '.delegatedRunId // empty' <<<"$1"; }

_graph_delegation_queue_parent_cancelled() {
  local workspace="$1" namespace="$2" run_id="$3" parent="$4" node_file run_file status
  [[ -n "$namespace" && -n "$run_id" && -n "$parent" ]] || return 1
  node_file="$(graph_state_node_file "$workspace" "$namespace" "$run_id" "$parent" 2>/dev/null || true)"
  if [[ -f "$node_file" ]]; then
    status="$(jq -r '.status // empty' "$node_file" 2>/dev/null || true)"
    [[ "$status" == cancelled ]] && return 0
  fi
  run_file="$(graph_state_run_file "$workspace" "$namespace" "$run_id" 2>/dev/null || true)"
  if [[ -f "$run_file" ]]; then
    status="$(jq -r '.status // empty' "$run_file" 2>/dev/null || true)"
    [[ "$status" == cancelled ]] && return 0
  fi
  return 1
}

_graph_delegation_queue_active_for_parent() {
  local workspace="$1" queue="$2" parent="$3" entry id status count=0
  [[ -f "$queue" ]] || { printf '0\n'; return 0; }
  while IFS= read -r entry; do
    [[ "$(jq -r '.parentNodeId // empty' <<<"$entry")" == "$parent" ]] || continue
    id="$(_graph_delegation_queue_entry_id "$entry")"
    status="$(_graph_delegation_queue_status_name "$workspace" "$id")"
    [[ "$status" == queued || "$status" == running ]] && count=$((count + 1))
  done < <(jq -c '.[]' "$queue" 2>/dev/null)
  printf '%s\n' "$count"
}

_graph_delegation_queue_running_for_parent() {
  local workspace="$1" queue="$2" parent="$3" entry id status count=0
  [[ -f "$queue" ]] || { printf '0\n'; return 0; }
  while IFS= read -r entry; do
    [[ "$(jq -r '.parentNodeId // empty' <<<"$entry")" == "$parent" ]] || continue
    id="$(_graph_delegation_queue_entry_id "$entry")"
    status="$(_graph_delegation_queue_status_name "$workspace" "$id")"
    [[ "$status" == running ]] && count=$((count + 1))
  done < <(jq -c '.[]' "$queue" 2>/dev/null)
  printf '%s\n' "$count"
}

# Find the durable run already published for a parent's idempotency key.
graph_delegation_queue_find_idempotency() {
  local workspace="$1" namespace run_id parent key queue entry
  if [[ "$#" -ge 5 ]]; then
    namespace="$2"; run_id="$3"; parent="$4"; key="$5"
  else
    namespace=''; run_id=''; parent="$3"; key="$4"
  fi
  queue="$(graph_delegation_queue_file "$workspace" "$namespace" "$run_id")" || return 1
  [[ -f "$queue" ]] || return 1
  while IFS= read -r entry; do
    [[ "$(jq -r '.parentNodeId // empty' <<<"$entry")" == "$parent" ]] || continue
    [[ "$(jq -r '.idempotencyKey // empty' <<<"$entry")" == "$key" ]] || continue
    _graph_delegation_queue_entry_id "$entry"
    return 0
  done < <(jq -c '.[]' "$queue" 2>/dev/null)
  return 1
}

# Enqueue an already-created ledger record.
# Long form: workspace namespace run parent delegatedRunId maxRuns maxParallel
# Short form: workspace delegatedRunId parent maxRuns maxParallel
graph_delegation_queue_enqueue() {
  local workspace namespace run_id parent did max_runs max_parallel
  local request queue lock base entry existing_count existing_id key sequence
  _graph_delegation_queue_args "$@" || return 1
  workspace="$GRAPH_DELEGATION_QUEUE_WORKSPACE"
  namespace="$GRAPH_DELEGATION_QUEUE_NAMESPACE"
  run_id="$GRAPH_DELEGATION_QUEUE_RUN_ID"
  parent="$GRAPH_DELEGATION_QUEUE_PARENT"
  did="$GRAPH_DELEGATION_QUEUE_ID"
  max_runs="$GRAPH_DELEGATION_QUEUE_MAX_RUNS"
  max_parallel="$GRAPH_DELEGATION_QUEUE_MAX_PARALLEL"
  request="$(graph_delegation_ledger_request_file "$workspace" "$did")" || return 1
  [[ -f "$request" ]] || return 1
  _graph_delegation_queue_status "$workspace" "$did" >/dev/null || return 1
  queue="$(graph_delegation_queue_file "$workspace" "$namespace" "$run_id")" || return 1
  lock="$(graph_delegation_queue_lock_dir "$workspace" "$namespace" "$run_id")" || return 1
  _graph_delegation_queue_lock "$lock" || return 1
  base='[]'
  [[ -f "$queue" ]] && base="$(jq -c . "$queue" 2>/dev/null)" || true
  [[ -n "$base" ]] || base='[]'
  key="$(jq -r '.idempotencyKey // empty' "$request" 2>/dev/null)"
  existing_id="$(jq -r --arg p "$parent" --arg k "$key" '[.[] | select(.parentNodeId == $p and .idempotencyKey == $k)] | .[0].delegatedRunId // empty' <<<"$base" 2>/dev/null || true)"
  if [[ -n "$existing_id" ]]; then
    if [[ "$existing_id" == "$did" ]]; then
      _graph_delegation_queue_unlock "$lock"
      printf '%s\n' "$existing_id"
      return 0
    fi
    _graph_delegation_queue_unlock "$lock"
    echo "Error: idempotency key already belongs to delegatedRunId $existing_id" >&2
    return 4
  fi
  existing_count="$(_graph_delegation_queue_active_for_parent "$workspace" "$queue" "$parent")" || { _graph_delegation_queue_unlock "$lock"; return 1; }
  if [[ "$existing_count" -ge "$max_runs" ]]; then
    _graph_delegation_queue_unlock "$lock"
    return 3
  fi
  sequence="$(jq 'map(.queueSequence // 0) | max // 0' <<<"$base" 2>/dev/null)"
  sequence=$((sequence + 1))
  entry="$(jq -cn --arg p "$parent" --argjson maxRuns "$max_runs" --argjson maxParallel "$max_parallel" --argjson sequence "$sequence" --slurpfile request "$request" '$request[0] + {parentNodeId:$p,maxRuns:$maxRuns,maxParallel:$maxParallel,queueSequence:$sequence}')" || { _graph_delegation_queue_unlock "$lock"; return 1; }
  if ! ralph_atomic_write_json "$queue" '($base|fromjson) + [($entry|fromjson)]' --arg base "$base" --arg entry "$entry"; then
    _graph_delegation_queue_unlock "$lock"
    return 1
  fi
  if _graph_delegation_queue_parent_cancelled "$workspace" "$namespace" "$run_id" "$parent"; then
    graph_delegation_ledger_transition "$workspace" "$did" cancelled "queue-${run_id:-state}" '' '{}' null 'parent cancelled before dispatch' >/dev/null 2>&1 || true
  fi
  _graph_delegation_queue_unlock "$lock"
  graph_delegation_queue_log "$workspace" "enqueue delegatedRunId=$did parent=$parent maxRuns=$max_runs maxParallel=$max_parallel"
  printf '%s\n' "$did"
}

# Prints nonterminal entries in queueSequence order. Terminal records remain as
# an audit trail and are not capacity reservations.
graph_delegation_queue_pending() {
  local workspace="$1" namespace="${2:-}" run_id="${3:-}" queue
  queue="$(graph_delegation_queue_file "$workspace" "$namespace" "$run_id")" || return 1
  [[ -f "$queue" ]] || return 0
  jq -c 'sort_by(.queueSequence // 0, .createdAt, .delegatedRunId)[]' "$queue" 2>/dev/null | while IFS= read -r entry; do
    local id status
    id="$(_graph_delegation_queue_entry_id "$entry")"
    status="$(_graph_delegation_queue_status_name "$workspace" "$id")"
    [[ "$status" == queued || "$status" == running ]] && printf '%s\n' "$entry"
  done
}

# All queue records, including terminal records retained for restart adoption.
graph_delegation_queue_entries() {
  local workspace="$1" namespace="${2:-}" run_id="${3:-}" queue
  queue="$(graph_delegation_queue_file "$workspace" "$namespace" "$run_id")" || return 1
  [[ -f "$queue" ]] || return 0
  jq -c 'sort_by(.queueSequence // 0, .createdAt, .delegatedRunId)[]' "$queue" 2>/dev/null
}

graph_delegation_queue_count_parent() {
  local workspace="$1" namespace="${2:-}" run_id="${3:-}" parent="$4" queue
  queue="$(graph_delegation_queue_file "$workspace" "$namespace" "$run_id")" || return 1
  _graph_delegation_queue_active_for_parent "$workspace" "$queue" "$parent"
}

_graph_delegation_queue_cancel_entry() {
  local workspace="$1" entry="$2" reason="$3" id status
  id="$(_graph_delegation_queue_entry_id "$entry")"
  status="$(_graph_delegation_queue_status_name "$workspace" "$id")"
  [[ "$status" == queued || "$status" == running ]] || return 0
  if ! declare -F graph_delegation_child_cancel >/dev/null 2>&1; then
    source "$_GRAPH_DELEGATION_QUEUE_DIR/graph-delegation-runner.sh"
  fi
  graph_delegation_child_cancel "$workspace" "$id" "$reason"
}

# Signal cancellation to all queued/running children owned by a parent. The
# runner remains responsible for process cleanup of a running child.
graph_delegation_queue_cancel_parent() {
  local workspace="$1" namespace="$2" run_id="$3" parent="$4" reason="${5:-parent cancelled}" queue lock entry rc=0
  queue="$(graph_delegation_queue_file "$workspace" "$namespace" "$run_id")" || return 1
  [[ -f "$queue" ]] || return 0
  lock="$(graph_delegation_queue_lock_dir "$workspace" "$namespace" "$run_id")" || return 1
  _graph_delegation_queue_lock "$lock" || return 1
  while IFS= read -r entry; do
    [[ "$(jq -r '.parentNodeId // empty' <<<"$entry")" == "$parent" ]] || continue
    _graph_delegation_queue_cancel_entry "$workspace" "$entry" "$reason" || rc=1
  done < <(jq -c '.[]' "$queue" 2>/dev/null)
  _graph_delegation_queue_unlock "$lock"
  graph_delegation_queue_log "$workspace" "cancel parent=$parent reason=$reason"
  return "$rc"
}

# Requeue a running record after a scheduler crash. The queue entry is kept,
# so recovery never loses work or mints a second delegatedRunId.
graph_delegation_queue_requeue_crashed() {
  local workspace did status_file base now reason
  if [[ "$#" -ge 5 ]]; then
    workspace="$1"; did="$5"; reason="${6:-scheduler recovery: child process unavailable}"
  else
    workspace="$1"; did="$2"; reason="${3:-scheduler recovery: child process unavailable}"
  fi
  status_file="$(graph_delegation_ledger_status_file "$workspace" "$did")" || return 1
  base="$(_graph_delegation_queue_status "$workspace" "$did")" || return 1
  [[ "$(jq -r '.status // empty' <<<"$base")" == running ]] || return 2
  now="$(graph_state_now_iso)"
  ralph_atomic_write_json "$status_file" '($base|fromjson) + {schemaVersion:$sv,status:"queued",updatedAt:$now,reason:$reason,runner:null}' --arg base "$base" --argjson sv "$GRAPH_DELEGATION_LEDGER_SCHEMA_VERSION" --arg now "$now" --arg reason "$reason" || return 1
  graph_delegation_ledger_append_event "$workspace" "$did" delegated-run-state-changed "$(jq -cn --arg reason "$reason" '{from:"running",to:"queued",reason:$reason}')" || return 1
  graph_delegation_queue_log "$workspace" "requeue delegatedRunId=$did reason=$reason"
}
graph_delegation_queue_requeue_running() { graph_delegation_queue_requeue_crashed "$@"; }

# Scheduler admission. child_cap/runtime_cap are global running capacities;
# each entry also carries the parent's maxParallel cap.
graph_delegation_queue_admit_one() {
  local workspace="$1" namespace="${2:-}" run_id="${3:-}" child_cap="${4:-}" runtime_cap="${5:-}"
  local queue lock entry candidate id parent runtime status active active_rt parent_active parent_cap id2
  if [[ "$#" -eq 3 ]]; then
    workspace="$1"; namespace=''; run_id=''; child_cap="$2"; runtime_cap="$3"
  fi
  [[ "$child_cap" =~ ^[0-9]+$ && "$runtime_cap" =~ ^[1-9][0-9]*$ ]] || return 1
  queue="$(graph_delegation_queue_file "$workspace" "$namespace" "$run_id")" || return 1
  [[ -f "$queue" ]] || return 2
  lock="$(graph_delegation_queue_lock_dir "$workspace" "$namespace" "$run_id")" || return 1
  _graph_delegation_queue_lock "$lock" || return 1
  active=0
  while IFS= read -r candidate; do
    id="$(_graph_delegation_queue_entry_id "$candidate")"
    status="$(_graph_delegation_queue_status_name "$workspace" "$id")"
    [[ "$status" == running ]] && active=$((active + 1))
  done < <(jq -c '.[]' "$queue" 2>/dev/null)
  [[ "$active" -lt "$child_cap" ]] || { _graph_delegation_queue_unlock "$lock"; return 2; }
  while IFS= read -r entry; do
    id="$(_graph_delegation_queue_entry_id "$entry")"
    parent="$(jq -r '.parentNodeId // empty' <<<"$entry")"
    status="$(_graph_delegation_queue_status_name "$workspace" "$id")"
    [[ "$status" == queued ]] || continue
    if _graph_delegation_queue_parent_cancelled "$workspace" "$namespace" "$run_id" "$parent"; then
      _graph_delegation_queue_cancel_entry "$workspace" "$entry" 'parent cancelled before dispatch' || true
      continue
    fi
    parent_cap="$(jq -r '.maxParallel // 0' <<<"$entry")"
    parent_active="$(_graph_delegation_queue_running_for_parent "$workspace" "$queue" "$parent")"
    [[ "$parent_cap" =~ ^[0-9]+$ ]] || parent_cap=0
    [[ "$parent_cap" -eq 0 || "$parent_active" -lt "$parent_cap" ]] || continue
    runtime="$(jq -r '.runtime // empty' <<<"$entry")"
    active_rt=0
    while IFS= read -r candidate; do
      [[ "$(jq -r '.runtime // empty' <<<"$candidate")" == "$runtime" ]] || continue
      id2="$(_graph_delegation_queue_entry_id "$candidate")"
      [[ "$(_graph_delegation_queue_status_name "$workspace" "$id2")" == running ]] && active_rt=$((active_rt + 1))
    done < <(jq -c '.[]' "$queue" 2>/dev/null)
    [[ "$active_rt" -lt "$runtime_cap" ]] || continue
    graph_delegation_ledger_transition "$workspace" "$id" running "scheduler-${run_id:-queue}" '' '{}' null '' || continue
    _graph_delegation_queue_unlock "$lock"
    graph_delegation_queue_log "$workspace" "admit delegatedRunId=$id runtime=$runtime"
    printf '%s\n' "$entry"
    return 0
  done < <(jq -c 'sort_by(.queueSequence // 0, .createdAt, .delegatedRunId)[]' "$queue" 2>/dev/null)
  _graph_delegation_queue_unlock "$lock"
  return 2
}
