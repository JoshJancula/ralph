#!/usr/bin/env bash
# Durable, scheduler-owned FIFO for cross-runtime delegated children.  MCP only
# appends requests; it never starts a runtime.  This file deliberately uses
# mkdir locks and indexed jq arrays so it remains usable on macOS Bash 3.2.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then echo "This file is meant to be sourced, not executed." >&2; exit 1; fi
if [[ -n "${GRAPH_DELEGATION_QUEUE_LOADED:-}" ]]; then return 0; fi
GRAPH_DELEGATION_QUEUE_LOADED=1

_GRAPH_DELEGATION_QUEUE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F graph_delegation_ledger_request_file >/dev/null 2>&1; then
  source "$_GRAPH_DELEGATION_QUEUE_DIR/graph-delegation-ledger.sh"
fi

graph_delegation_queue_file() {
  printf '%s/delegation-queue.json\n' "$(graph_state_run_dir "$1" "$2" "$3")"
}
graph_delegation_queue_lock_dir() {
  printf '%s/delegation-queue.lock\n' "$(graph_state_run_dir "$1" "$2" "$3")"
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
    sleep 1
  done
}
_graph_delegation_queue_unlock() { rmdir "$1" 2>/dev/null || true; }

# Atomically append a committed ledger request.  The queue itself is the
# scheduler contract; sorting by request time then opaque id is deterministic
# even when separate MCP processes enqueue during the same clock tick.
graph_delegation_queue_enqueue() {
  local workspace="$1" ns="$2" run_id="$3" node="$4" did="$5" max_children="${6:-0}"
  local request queue lock base entry existing_count
  request="$(graph_delegation_ledger_request_file "$workspace" "$ns" "$run_id" "$node" "$did")"
  [[ -f "$request" ]] || return 1
  queue="$(graph_delegation_queue_file "$workspace" "$ns" "$run_id")" || return 1
  lock="$(graph_delegation_queue_lock_dir "$workspace" "$ns" "$run_id")" || return 1
  _graph_delegation_queue_lock "$lock" || return 1
  base='[]'; [[ -f "$queue" ]] && base="$(jq -c . "$queue" 2>/dev/null)" || true
  # Idempotent MCP retries must not consume another parent child allowance.
  if jq -e --arg p "$node" --arg id "$did" 'any(.[]; .parentNodeId == $p and .delegationId == $id)' <<<"$base" >/dev/null; then
    _graph_delegation_queue_unlock "$lock"
    return 0
  fi
  if [[ "$max_children" =~ ^[0-9]+$ && "$max_children" -gt 0 ]]; then
    existing_count="$(jq --arg p "$node" '[.[] | select(.parentNodeId == $p)] | length' <<<"$base")" || { _graph_delegation_queue_unlock "$lock"; return 1; }
    if [[ "$existing_count" -ge "$max_children" ]]; then
      _graph_delegation_queue_unlock "$lock"
      return 3
    fi
  fi
  entry="$(jq -cn --arg node "$node" --arg id "$did" --slurpfile r "$request" '$r[0] + {parentNodeId:$node,delegationId:$id}')" || { _graph_delegation_queue_unlock "$lock"; return 1; }
  if ! ralph_atomic_write_json "$queue" '($base|fromjson) as $q | ($entry|fromjson) as $e | if any($q[]; .delegationId == $e.delegationId and .parentNodeId == $e.parentNodeId) then $q else $q + [$e] end' --arg base "$base" --arg entry "$entry"; then
    _graph_delegation_queue_unlock "$lock"; return 1
  fi
  _graph_delegation_queue_unlock "$lock"
  graph_delegation_queue_log "$workspace" "enqueue delegation=$did parent=$node"
}

# Prints queued entries in deterministic FIFO order. Cancelled and dispatched
# entries remain in queue.json as an audit trail but are ignored.
graph_delegation_queue_pending() {
  local workspace="$1" ns="$2" run_id="$3" queue
  queue="$(graph_delegation_queue_file "$workspace" "$ns" "$run_id")" || return 1
  [[ -f "$queue" ]] || return 0
  jq -c 'sort_by(.createdAt, .delegationId)[]' "$queue" 2>/dev/null
}

graph_delegation_queue_count_parent() {
  local workspace="$1" ns="$2" run_id="$3" parent="$4" queue
  queue="$(graph_delegation_queue_file "$workspace" "$ns" "$run_id")" || return 1
  [[ -f "$queue" ]] || { printf '0\n'; return 0; }
  jq --arg p "$parent" '[.[] | select(.parentNodeId == $p)] | length' "$queue"
}

# Scheduler admission.  It claims an eligible child by changing its ledger
# state to running under the queue lock and prints the entry.  The caller owns
# actual runtime execution and later terminal transition.  Capacity is based
# on active running children, while queued work is strict FIFO (a blocked head
# cannot be bypassed by a later request).
graph_delegation_queue_admit_one() {
  local workspace="$1" ns="$2" run_id="$3" child_cap="$4" runtime_cap="$5"
  local queue lock entry did node runtime status active active_rt
  [[ "$child_cap" =~ ^[0-9]+$ && "$runtime_cap" =~ ^[1-9][0-9]*$ ]] || return 1
  queue="$(graph_delegation_queue_file "$workspace" "$ns" "$run_id")" || return 1
  [[ -f "$queue" ]] || return 2
  lock="$(graph_delegation_queue_lock_dir "$workspace" "$ns" "$run_id")" || return 1
  _graph_delegation_queue_lock "$lock" || return 1
  active=0
  while IFS= read -r entry; do
    node="$(jq -r '.parentNodeId' <<<"$entry")"; did="$(jq -r '.delegationId' <<<"$entry")"
    status="$(graph_delegation_ledger_read_status "$workspace" "$ns" "$run_id" "$node" "$did" 2>/dev/null | jq -r '.status // empty')"
    [[ "$status" == running ]] && active=$((active + 1))
  done < <(graph_delegation_queue_pending "$workspace" "$ns" "$run_id")
  [[ "$active" -lt "$child_cap" ]] || { _graph_delegation_queue_unlock "$lock"; return 2; }
  while IFS= read -r entry; do
    node="$(jq -r '.parentNodeId' <<<"$entry")"; did="$(jq -r '.delegationId' <<<"$entry")"; runtime="$(jq -r '.runtime' <<<"$entry")"
    status="$(graph_delegation_ledger_read_status "$workspace" "$ns" "$run_id" "$node" "$did" 2>/dev/null | jq -r '.status // empty')"
    [[ "$status" == queued ]] || continue
    active_rt=0
    local candidate other_node other_did other_runtime other_status
    while IFS= read -r candidate; do
      other_node="$(jq -r '.parentNodeId' <<<"$candidate")"; other_did="$(jq -r '.delegationId' <<<"$candidate")"; other_runtime="$(jq -r '.runtime' <<<"$candidate")"
      [[ "$other_runtime" == "$runtime" ]] || continue
      other_status="$(graph_delegation_ledger_read_status "$workspace" "$ns" "$run_id" "$other_node" "$other_did" 2>/dev/null | jq -r '.status // empty')"
      [[ "$other_status" == running ]] && active_rt=$((active_rt + 1))
    done < <(graph_delegation_queue_pending "$workspace" "$ns" "$run_id")
    [[ "$active_rt" -lt "$runtime_cap" ]] || { _graph_delegation_queue_unlock "$lock"; return 2; }
    graph_delegation_ledger_transition "$workspace" "$ns" "$run_id" "$node" "$did" running "scheduler-${run_id}" || { _graph_delegation_queue_unlock "$lock"; return 1; }
    _graph_delegation_queue_unlock "$lock"
    graph_delegation_queue_log "$workspace" "admit delegation=$did runtime=$runtime"
    printf '%s\n' "$entry"
    return 0
  done < <(graph_delegation_queue_pending "$workspace" "$ns" "$run_id")
  _graph_delegation_queue_unlock "$lock"; return 2
}
