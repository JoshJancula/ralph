#!/usr/bin/env bash
# Recovery helpers for graph-mode runs.
#
# Repairs ledger state after supervisor failure or explicit operator recovery.
# All mutations use the existing atomic ledger writers and the event journal.
# Recovery never invokes model runtimes directly.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

GRAPH_RECOVERY_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -F graph_state_read_node_v2 >/dev/null 2>&1; then
  # shellcheck source=./graph-state.sh
  source "$GRAPH_RECOVERY_SCRIPT_DIR/graph-state.sh"
fi

if ! declare -F graph_events_append >/dev/null 2>&1; then
  # shellcheck source=./graph-events.sh
  source "$GRAPH_RECOVERY_SCRIPT_DIR/graph-events.sh"
fi

if ! declare -F graph_heartbeat_classify_run >/dev/null 2>&1; then
  # shellcheck source=./graph-heartbeat.sh
  source "$GRAPH_RECOVERY_SCRIPT_DIR/graph-heartbeat.sh"
fi

# graph_recovery_now_iso
# Current UTC timestamp in ISO-8601 seconds form. Honors GRAPH_RECOVERY_INTERRUPT_AT
# for tests that need a deterministic timestamp.
graph_recovery_now_iso() {
  if [[ -n "${GRAPH_RECOVERY_INTERRUPT_AT:-}" ]]; then
    printf '%s\n' "$GRAPH_RECOVERY_INTERRUPT_AT"
    return 0
  fi
  date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ
}

# graph_recovery_interrupt_attempt <workspace> <namespace> <run_id> <node_id> <attempt_id> [reason]
#
# Terminalizes an orphaned running attempt as interrupted, sets its node to
# interrupted, and appends a node-interrupted event. Existing attempt fields
# (logPaths, usageSnapshot, usageReliable, runtime, startedAt, etc.) are
# preserved because the ledger writer merges rather than replaces.
#
# The operation is atomic and idempotent: repeating the call on an attempt that
# is already interrupted with outcome interrupted is a no-op.
graph_recovery_interrupt_attempt() {
  local workspace="$1" namespace="$2" run_id="$3" node_id="$4" attempt_id="$5"
  local reason="${6:-}"
  local node_file run_dir node_json prev_status prev_outcome timestamp
  local attempt_fields_json details_json

  if [[ -z "$workspace" || -z "$namespace" || -z "$run_id" || -z "$node_id" || -z "$attempt_id" ]]; then
    echo "Error: graph_recovery_interrupt_attempt requires workspace, namespace, run_id, node_id, and attempt_id" >&2
    return 1
  fi

  node_file="$(graph_state_node_file "$workspace" "$namespace" "$run_id" "$node_id")" || return 1
  if [[ ! -f "$node_file" ]]; then
    echo "Error: node ledger not found: $node_file" >&2
    return 1
  fi

  run_dir="$(graph_state_run_dir "$workspace" "$namespace" "$run_id")" || return 1
  if [[ ! -d "$run_dir" ]]; then
    echo "Error: run directory not found: $run_dir" >&2
    return 1
  fi

  node_json="$(graph_state_read_node_v2 "$workspace" "$namespace" "$run_id" "$node_id")" || return 1
  prev_status="$(jq -r '.status // empty' <<<"$node_json" 2>/dev/null)"
  prev_outcome="$(jq -r --arg aid "$attempt_id" '(.attempts // [])[]? | select(.attemptId == $aid) | .outcome // empty' <<<"$node_json" 2>/dev/null)"

  # Idempotent no-op: already interrupted with the same outcome.
  if [[ "$prev_status" == "interrupted" && "$prev_outcome" == "interrupted" ]]; then
    return 0
  fi

  if [[ "$prev_status" != "running" ]]; then
    echo "Error: cannot interrupt node $node_id because it is not running (status: ${prev_status:-<none>})" >&2
    return 1
  fi

  # Verify the attempt exists on the running node before mutating.
  local attempt_idx
  attempt_idx="$(jq -r --arg aid "$attempt_id" '(.attempts // []) | map(.attemptId) | index($aid)' <<<"$node_json" 2>/dev/null)"
  if [[ -z "$attempt_idx" || "$attempt_idx" == "null" ]]; then
    echo "Error: attempt $attempt_id not found for node $node_id" >&2
    return 1
  fi

  timestamp="$(graph_recovery_now_iso)"

  attempt_fields_json="$(jq -cn --arg ts "$timestamp" --arg reason "$reason" \
    '{outcome:"interrupted",finishedAt:$ts} + if $reason == "" then {} else {reason:$reason} end')"

  if ! graph_state_write_node_v2 "$workspace" "$namespace" "$run_id" "$node_id" "interrupted" \
    "$attempt_id" "$attempt_fields_json"; then
    echo "Error: failed to interrupt attempt $attempt_id for node $node_id" >&2
    return 1
  fi

  details_json="$(jq -cn --arg attemptId "$attempt_id" --arg finishedAt "$timestamp" --arg reason "$reason" \
    '{attemptId:$attemptId,finishedAt:$finishedAt} + if $reason == "" then {} else {reason:$reason} end')"

  if ! graph_events_append "$run_dir" "$run_id" "node-interrupted" "$node_id" "$attempt_id" "$details_json"; then
    echo "Error: failed to append node-interrupted event for $node_id/$attempt_id" >&2
    return 1
  fi

  return 0
}

# graph_recovery_lock_path <run_dir>
# Prints the absolute path to the run-local recovery lock file. The lock is
# stored inside the run directory so it is scoped to exactly one run and
# cleaned up with the run.
graph_recovery_lock_path() {
  local run_dir="$1"
  if [[ -z "$run_dir" ]]; then
    echo "Error: graph_recovery_lock_path requires a run_dir" >&2
    return 1
  fi
  printf '%s/recovery.lock\n' "$run_dir"
}

# graph_recovery_node_is_reset_eligible <status>
# Returns 0 when a node in <status> may be reset to pending during recovery.
# Only interrupted nodes are scheduler-eligible. Succeeded, skipped,
# awaiting-operator, and needs-plan-repair are preserved, as are every other
# non-interrupted status.
graph_recovery_node_is_reset_eligible() {
  case "${1:-}" in
    interrupted) return 0 ;;
    *) return 1 ;;
  esac
}

# graph_recovery_reset_eligible_nodes <workspace> <namespace> <run_id> <run_dir>
#
# Resets scheduler-eligible interrupted nodes to pending and appends one
# node-recovered event per reset. Preserves succeeded, skipped,
# awaiting-operator, and needs-plan-repair (and any other non-interrupted
# status). Prints the number of nodes reset. Attempts stay on the ledger.
graph_recovery_reset_eligible_nodes() {
  local workspace="$1" namespace="$2" run_id="$3" run_dir="$4"
  local node_file node_json node_id node_status attempt_id details_json
  local reset_count=0

  if [[ -z "$workspace" || -z "$namespace" || -z "$run_id" || -z "$run_dir" ]]; then
    echo "Error: graph_recovery_reset_eligible_nodes requires workspace, namespace, run_id, and run_dir" >&2
    return 1
  fi

  for node_file in "$run_dir"/nodes/*.json; do
    [[ -f "$node_file" ]] || continue
    node_json="$(jq -c . "$node_file" 2>/dev/null)" || continue
    node_id="$(jq -r '.nodeId // empty' <<<"$node_json" 2>/dev/null)" || continue
    node_status="$(jq -r '.status // empty' <<<"$node_json" 2>/dev/null)" || continue
    [[ -n "$node_id" ]] || continue
    graph_recovery_node_is_reset_eligible "$node_status" || continue

    attempt_id="$(jq -r '.lastAttemptId // empty' <<<"$node_json" 2>/dev/null)"
    if ! graph_state_reset_node_to_pending "$workspace" "$namespace" "$run_id" "$node_id"; then
      echo "Error: failed to reset interrupted node $node_id to pending" >&2
      return 1
    fi

    details_json="$(jq -cn --arg from "$node_status" '{from:$from,to:"pending"}')"
    if ! graph_events_append "$run_dir" "$run_id" "node-recovered" "$node_id" "${attempt_id:-}" "$details_json"; then
      echo "Error: failed to append node-recovered event for $node_id" >&2
      return 1
    fi
    reset_count=$((reset_count + 1))
  done

  printf '%s\n' "$reset_count"
  return 0
}

# _graph_recovery_attempt_run_locked <workspace> <namespace> <run_id> <run_dir>
#
# Internal helper that runs after the run-local recovery lock has been
# acquired. Re-runs the liveness classifier, refuses healthy/unknown/terminal
# runs, interrupts every running attempt, then resets only scheduler-eligible
# interrupted nodes to pending and marks the run interrupted (resumable).
# Must be called while the caller holds the recovery lock.
_graph_recovery_attempt_run_locked() {
  local workspace="$1" namespace="$2" run_id="$3" run_dir="$4"
  local health run_status node_file node_json node_id node_status
  local attempt_id outcome interrupted_count=0 reset_count=0
  local start_details finish_details

  # Re-run the liveness classifier after acquiring the lock.
  health="$(graph_heartbeat_classify_run "$workspace" "$namespace" "$run_id" 2>/dev/null)" || health="unknown"

  case "$health" in
    healthy)
      echo "refused: run is healthy"
      return 1
      ;;
    unknown)
      echo "refused: run liveness is unknown"
      return 1
      ;;
  esac

  # Refuse published or any terminal run status.
  run_status="$(jq -r '.status // empty' "$run_dir/run.json" 2>/dev/null)"
  if [[ "$run_status" == "published" ]] || graph_state_run_status_is_terminal "$run_status"; then
    echo "refused: run is terminal ($run_status)"
    return 1
  fi

  if [[ "$run_status" != "running" ]]; then
    echo "refused: run is not running ($run_status)"
    return 1
  fi

  start_details="$(jq -cn --arg health "$health" '{health:$health}')"
  if ! graph_events_append "$run_dir" "$run_id" "recovery-start" "" "" "$start_details"; then
    echo "Error: failed to append recovery-start event" >&2
    return 1
  fi

  # Interrupt every running attempt.
  for node_file in "$run_dir"/nodes/*.json; do
    [[ -f "$node_file" ]] || continue
    node_json="$(jq -c . "$node_file" 2>/dev/null)" || continue
    node_id="$(jq -r '.nodeId // empty' <<<"$node_json" 2>/dev/null)" || continue
    node_status="$(jq -r '.status // empty' <<<"$node_json" 2>/dev/null)" || continue
    [[ "$node_status" == "running" ]] || continue
    attempt_id="$(jq -r '.lastAttemptId // empty' <<<"$node_json" 2>/dev/null)" || continue
    [[ -n "$attempt_id" ]] || continue
    outcome="$(jq -r --arg aid "$attempt_id" '(.attempts // [])[]? | select(.attemptId == $aid) | .outcome // empty' <<<"$node_json" 2>/dev/null)" || continue
    [[ -z "$outcome" ]] || continue
    if graph_recovery_interrupt_attempt "$workspace" "$namespace" "$run_id" "$node_id" "$attempt_id" "stale supervisor detected by recovery"; then
      interrupted_count=$((interrupted_count + 1))
    fi
  done

  reset_count="$(graph_recovery_reset_eligible_nodes "$workspace" "$namespace" "$run_id" "$run_dir")" || return 1
  [[ "$reset_count" =~ ^[0-9]+$ ]] || reset_count=0

  finish_details="$(jq -cn --argjson interrupted "$interrupted_count" --argjson reset "$reset_count" \
    '{interruptedAttempts:$interrupted,nodesReset:$reset}')"
  if ! graph_events_append "$run_dir" "$run_id" "recovery-finish" "" "" "$finish_details"; then
    echo "Error: failed to append recovery-finish event" >&2
    return 1
  fi

  if [[ "$interrupted_count" -eq 0 && "$reset_count" -eq 0 ]]; then
    echo "no running attempts to recover"
  fi

  # Leave the run resumable but not live. Resume accepts interrupted; status
  # and attach must not treat a recovered run as still owned by a supervisor.
  if ! graph_state_set_run_status "$workspace" "$namespace" "$run_id" "interrupted"; then
    echo "Error: failed to mark recovered run as interrupted" >&2
    return 1
  fi

  return 0
}

# graph_recovery_attempt_run <workspace> <namespace> <run_id>
#
# Acquires the run-local recovery lock, re-runs the liveness classifier, and
# interrupts orphaned running attempts only when the run is provably stale.
# After interrupt, resets only scheduler-eligible interrupted nodes to pending
# and emits recovery-start, per-node, and recovery-finish events. On success
# the run status is set to interrupted so resume can continue without the
# run still looking live. Refuses healthy, unknown, published, or otherwise
# terminal runs. The lock is non-blocking so two concurrent recoverers
# serialize: the first one mutates, the second finds nothing running and
# exits without additional node changes.
graph_recovery_attempt_run() {
  local workspace="$1" namespace="$2" run_id="$3"
  local run_dir lock_path

  if [[ -z "$workspace" || -z "$namespace" || -z "$run_id" ]]; then
    echo "Error: graph_recovery_attempt_run requires workspace, namespace, and run_id" >&2
    return 1
  fi

  run_dir="$(graph_state_run_dir "$workspace" "$namespace" "$run_id")" || return 1
  if [[ ! -d "$run_dir" ]]; then
    echo "Error: run directory not found: $run_dir" >&2
    return 1
  fi

  lock_path="$(graph_recovery_lock_path "$run_dir")" || return 1

  if command -v flock >/dev/null 2>&1; then
    (
      flock -n -x 200 || { echo "refused: recovery lock already held"; exit 1; }
      _graph_recovery_attempt_run_locked "$workspace" "$namespace" "$run_id" "$run_dir"
    ) 200>"$lock_path"
    return $?
  fi

  # Fallback: atomic mkdir-based lock for systems without flock.
  local mkdir_lock="$lock_path.mkdir"
  if ! mkdir "$mkdir_lock" 2>/dev/null; then
    echo "refused: recovery lock already held"
    return 1
  fi
  local rc=0
  _graph_recovery_attempt_run_locked "$workspace" "$namespace" "$run_id" "$run_dir" || rc=$?
  rmdir "$mkdir_lock" 2>/dev/null || true
  return $rc
}
