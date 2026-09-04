#!/usr/bin/env bash
# Durable storage for Ralph delegated runs.
#
# A delegated run is deliberately independent of the graph-node ledger. Its
# identity is the directory name under <state-root>/delegated-runs and every
# JSON record is written through the shared atomic writer.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

if [[ -n "${GRAPH_DELEGATION_LEDGER_LOADED:-}" ]]; then return 0; fi
GRAPH_DELEGATION_LEDGER_LOADED=1

_GRAPH_DELEGATION_LEDGER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F ralph_wait >/dev/null 2>&1; then
  # shellcheck source=../ralph-wait.sh
  source "$_GRAPH_DELEGATION_LEDGER_DIR/../ralph-wait.sh"
fi
if ! declare -F ralph_atomic_write_json >/dev/null 2>&1; then
  # shellcheck source=../atomic-json.sh
  source "$_GRAPH_DELEGATION_LEDGER_DIR/../atomic-json.sh"
fi
if ! declare -F graph_state_state_root >/dev/null 2>&1; then
  # shellcheck source=graph-state.sh
  source "$_GRAPH_DELEGATION_LEDGER_DIR/graph-state.sh"
fi
if ! declare -F graph_state_now_iso >/dev/null 2>&1; then
  graph_state_now_iso() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
fi

# Schema version 1 is the old node-local delegation ledger and is not read.
GRAPH_DELEGATION_LEDGER_SCHEMA_VERSION=2
GRAPH_DELEGATION_LEDGER_STATES=(queued running succeeded failed cancelled)

graph_delegation_ledger_log() {
  local workspace="$1"; shift
  local state_root path
  state_root="$(graph_state_state_root "$workspace")" || return 0
  path="$state_root/logs/delegation-ledger.log"
  mkdir -p "$(dirname "$path")" 2>/dev/null || true
  printf '[%s] graph-delegation-ledger: %s\n' "$(graph_state_now_iso)" "$*" >>"$path" 2>/dev/null || true
}

# Reject unsafe components instead of sanitizing them into another record.
graph_delegation_ledger_safe_component() {
  local component="${1:-}"
  [[ "$component" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
  [[ "$component" != "." && "$component" != ".." && "$component" != *..* ]] || return 1
  printf '%s' "$component"
}

graph_delegation_ledger_valid_id() {
  [[ "${1:-}" =~ ^delegated-run-[0-9a-f]{24}$ ]]
}

graph_delegation_ledger_root() {
  local workspace="$1" state_root
  [[ -n "$workspace" ]] || return 1
  state_root="$(graph_state_state_root "$workspace")" || return 1
  printf '%s/delegated-runs\n' "$state_root"
}

graph_delegation_ledger_dir() {
  local root id
  root="$(graph_delegation_ledger_root "$1")" || return 1
  id="$(graph_delegation_ledger_safe_component "${2:-}")" || return 1
  graph_delegation_ledger_valid_id "$id" || return 1
  printf '%s/%s\n' "$root" "$id"
}

graph_delegation_ledger_id() {
  local run_id="$1" node_id="$2" parent_attempt="$3" key="$4" digest
  [[ -n "$run_id" && -n "$node_id" && -n "$parent_attempt" && -n "$key" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  if command -v shasum >/dev/null 2>&1; then
    digest="$(jq -cn --arg r "$run_id" --arg n "$node_id" --arg a "$parent_attempt" --arg k "$key" '{runId:$r,parentNodeId:$n,parentAttemptId:$a,idempotencyKey:$k}' | shasum -a 256 | awk '{print $1}')"
  else
    digest="$(jq -cn --arg r "$run_id" --arg n "$node_id" --arg a "$parent_attempt" --arg k "$key" '{runId:$r,parentNodeId:$n,parentAttemptId:$a,idempotencyKey:$k}' | sha256sum | awk '{print $1}')"
  fi
  printf 'delegated-run-%s\n' "${digest:0:24}"
}

graph_delegation_ledger_valid_state() {
  local wanted="$1" state
  for state in "${GRAPH_DELEGATION_LEDGER_STATES[@]}"; do
    [[ "$state" == "$wanted" ]] && return 0
  done
  return 1
}

graph_delegation_ledger_request_file() { printf '%s/request.json\n' "$(graph_delegation_ledger_dir "$@")"; }
graph_delegation_ledger_status_file() { printf '%s/status.json\n' "$(graph_delegation_ledger_dir "$@")"; }
graph_delegation_ledger_events_file() { printf '%s/events.jsonl\n' "$(graph_delegation_ledger_dir "$@")"; }
graph_delegation_ledger_result_file() { printf '%s/result.json\n' "$(graph_delegation_ledger_dir "$@")"; }
graph_delegation_ledger_artifacts_dir() { printf '%s/artifacts\n' "$(graph_delegation_ledger_dir "$@")"; }
graph_delegation_ledger_changeset_file() { printf '%s/changeset.json\n' "$(graph_delegation_ledger_dir "$@")"; }

# policy.json, child.plan.md, and child-process.json are old sidecars. They
# intentionally have no accessors in the new storage contract.
_graph_delegation_ledger_schema_check() {
  local path="$1" expected_id="${2:-}" version actual_id
  [[ -f "$path" ]] || return 1
  version="$(jq -r '.schemaVersion // empty' "$path" 2>/dev/null)" || return 1
  if [[ "$version" != "$GRAPH_DELEGATION_LEDGER_SCHEMA_VERSION" ]]; then
    echo "Error: unsupported delegated-run ledger at $path: detected schemaVersion ${version:-missing}, requires schemaVersion $GRAPH_DELEGATION_LEDGER_SCHEMA_VERSION" >&2
    return 1
  fi
  if [[ -n "$expected_id" ]]; then
    actual_id="$(jq -r '.delegatedRunId // empty' "$path" 2>/dev/null)" || return 1
    [[ "$actual_id" == "$expected_id" ]] || return 1
  fi
  jq -e . "$path" >/dev/null 2>&1
}

_graph_delegation_ledger_request_fingerprint() { jq -cS . <<<"$1"; }

_graph_delegation_ledger_transition_allowed() {
  local from="$1" to="$2"
  [[ "$from" == "$to" ]] && return 0
  case "$from:$to" in
    queued:running|queued:cancelled|running:succeeded|running:failed|running:cancelled) return 0 ;;
  esac
  return 1
}

_graph_delegation_ledger_lock_events() {
  local dir="$1" lock="$dir/.events.lock" deadline
  deadline=$(( $(date +%s) + 5 ))
  while ! mkdir "$lock" 2>/dev/null; do
    [[ $(date +%s) -lt $deadline ]] || return 1
    ralph_wait 1
  done
  printf '%s\n' "$lock"
}

_graph_delegation_ledger_unlock_events() { rmdir "$1" 2>/dev/null || true; }

# graph_delegation_ledger_append_event <workspace> <delegated-run-id>
#   <event-name> [details-json]
graph_delegation_ledger_append_event() {
  local workspace="$1" id="$2" event="$3" details="${4:-}" dir events lock now
  [[ -n "$details" ]] || details='{}'
  graph_delegation_ledger_valid_id "$id" || return 1
  [[ "$event" == delegated-run-* ]] || return 1
  jq -e . >/dev/null 2>&1 <<<"$details" || return 1
  dir="$(graph_delegation_ledger_dir "$workspace" "$id")" || return 1
  _graph_delegation_ledger_schema_check "$dir/request.json" "$id" || return 1
  _graph_delegation_ledger_schema_check "$dir/status.json" "$id" || return 1
  events="$dir/events.jsonl"
  lock="$(_graph_delegation_ledger_lock_events "$dir")" || return 1
  now="$(graph_state_now_iso)"
  if ! jq -cn --argjson sv "$GRAPH_DELEGATION_LEDGER_SCHEMA_VERSION" --arg id "$id" --arg event "$event" --arg now "$now" --arg details "$details" \
    '{schemaVersion:$sv,delegatedRunId:$id,event:$event,timestamp:$now,details:($details|fromjson)}' >>"$events"; then
    _graph_delegation_ledger_unlock_events "$lock"
    return 1
  fi
  ralph_fsync_path "$events"
  _graph_delegation_ledger_unlock_events "$lock"
}

# graph_delegation_ledger_start <workspace> <delegated-run-id> <request-json>
# Creates storage only; it never queues or invokes a child.
graph_delegation_ledger_start() {
  local workspace="$1" id="$2" request_json="$3" dir request status events artifacts now existing
  [[ $# -eq 3 ]] || return 1
  graph_delegation_ledger_valid_id "$id" || return 1
  jq -e 'type == "object" and (has("delegationId") | not) and (.delegatedRunId == $id)' --arg id "$id" <<<"$request_json" >/dev/null 2>&1 || return 1
  dir="$(graph_delegation_ledger_dir "$workspace" "$id")" || return 1
  request="$dir/request.json"; status="$dir/status.json"; events="$dir/events.jsonl"; artifacts="$dir/artifacts"
  mkdir -p "$(dirname "$dir")" || return 1
  if ! mkdir "$dir" 2>/dev/null; then
    _graph_delegation_ledger_schema_check "$request" "$id" || return 1
    existing="$(_graph_delegation_ledger_request_fingerprint "$(cat "$request")")" || return 1
    [[ "$existing" == "$(_graph_delegation_ledger_request_fingerprint "$request_json")" ]] || return 1
    printf '%s\n' "$id"
    return 0
  fi
  now="$(graph_state_now_iso)"
  if ! ralph_atomic_write_json "$request" '($request|fromjson) + {schemaVersion:$sv,createdAt:$now}' \
      --arg request "$request_json" --argjson sv "$GRAPH_DELEGATION_LEDGER_SCHEMA_VERSION" --arg now "$now" \
    || ! ralph_atomic_write_json "$status" '{schemaVersion:$sv,delegatedRunId:$id,status:"queued",createdAt:$now,updatedAt:$now,usage:{}}' \
      --argjson sv "$GRAPH_DELEGATION_LEDGER_SCHEMA_VERSION" --arg id "$id" --arg now "$now" \
    || ! mkdir "$artifacts" \
    || ! : >"$events"; then
    graph_delegation_ledger_log "$workspace" "ERROR start failed delegatedRunId=$id"
    return 1
  fi
  ralph_fsync_path "$events"
  graph_delegation_ledger_append_event "$workspace" "$id" delegated-run-created '{}' || return 1
  graph_delegation_ledger_log "$workspace" "start delegatedRunId=$id created"
  printf '%s\n' "$id"
}

# graph_delegation_ledger_transition <workspace> <delegated-run-id> <state>
#   [attempt-id] [verification-outcome] [usage-json] [result-json] [reason]
graph_delegation_ledger_transition() {
  local workspace="$1" id="$2" state="$3" attempt_id="${4:-}" verification="${5:-}" usage="${6:-}" result="${7:-}" reason="${8:-}"
  local dir status base old_state now result_file
  [[ $# -ge 3 && $# -le 8 ]] || return 1
  [[ -n "$usage" ]] || usage='{}'
  [[ -n "$result" ]] || result='null'
  graph_delegation_ledger_valid_id "$id" || return 1
  graph_delegation_ledger_valid_state "$state" || return 1
  jq -e type >/dev/null 2>&1 <<<"$usage" && jq -e type >/dev/null 2>&1 <<<"$result" || return 1
  if [[ "$state" != succeeded && "$state" != failed && "$state" != cancelled ]]; then
    [[ "$(jq -c . <<<"$result")" == "null" ]] || return 1
  fi
  dir="$(graph_delegation_ledger_dir "$workspace" "$id")" || return 1
  status="$dir/status.json"
  _graph_delegation_ledger_schema_check "$dir/request.json" "$id" || return 1
  _graph_delegation_ledger_schema_check "$status" "$id" || return 1
  base="$(jq -c . "$status")" || return 1
  old_state="$(jq -r '.status' <<<"$base")" || return 1
  _graph_delegation_ledger_transition_allowed "$old_state" "$state" || return 1
  if [[ "$state" != "$old_state" ]]; then
    now="$(graph_state_now_iso)"
    if ! ralph_atomic_write_json "$status" '
      ($base|fromjson) as $old | ($usage|fromjson) as $u |
      $old + {schemaVersion:$sv,status:$state,updatedAt:$now} |
      .usage = (($old.usage // {}) + (reduce ($u|to_entries[]) as $e ($old.usage // {}; .[$e.key] = ((.[$e.key] // 0) + $e.value)))) |
      (if $verification == "" then . else .verificationOutcome = $verification end) |
      (if $attempt == "" then . else .lastAttemptId = $attempt end) |
      (if $reason == "" then . else .reason = $reason end) |
      (if ($state == "succeeded" or $state == "failed" or $state == "cancelled") then .finishedAt = $now else . end)' \
      --arg base "$base" --argjson sv "$GRAPH_DELEGATION_LEDGER_SCHEMA_VERSION" --arg state "$state" --arg now "$now" \
      --arg usage "$usage" --arg verification "$verification" --arg attempt "$attempt_id" --arg reason "$reason"; then
      return 1
    fi
    if [[ "$state" == succeeded || "$state" == failed || "$state" == cancelled ]]; then
      result_file="$dir/result.json"
      ralph_atomic_write_json "$result_file" '{schemaVersion:$sv,delegatedRunId:$id,status:$state,result:($result|fromjson)}' \
        --argjson sv "$GRAPH_DELEGATION_LEDGER_SCHEMA_VERSION" --arg id "$id" --arg state "$state" --arg result "$result" || return 1
    fi
    graph_delegation_ledger_append_event "$workspace" "$id" delegated-run-state-changed \
      "$(jq -cn --arg from "$old_state" --arg to "$state" --arg reason "$reason" '{from:$from,to:$to} + (if $reason == "" then {} else {reason:$reason} end)')" || return 1
  fi
  graph_delegation_ledger_log "$workspace" "transition delegatedRunId=$id state=$state attempt=${attempt_id:-none}"
}

graph_delegation_ledger_read_status() {
  local workspace="$1" id="$2" status
  status="$(graph_delegation_ledger_status_file "$workspace" "$id")" || return 1
  _graph_delegation_ledger_schema_check "$status" "$id" || return 1
  jq -e . "$status"
}

graph_delegation_ledger_read_events() {
  local workspace="$1" id="$2" events line event_id version
  events="$(graph_delegation_ledger_events_file "$workspace" "$id")" || return 1
  [[ -f "$events" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    jq -e . >/dev/null 2>&1 <<<"$line" || return 1
    version="$(jq -r '.schemaVersion // empty' <<<"$line")"
    event_id="$(jq -r '.delegatedRunId // empty' <<<"$line")"
    [[ "$version" == "$GRAPH_DELEGATION_LEDGER_SCHEMA_VERSION" && "$event_id" == "$id" ]] || return 1
  done <"$events"
  cat "$events"
}

graph_delegation_ledger_write_changeset() {
  local workspace="$1" id="$2" changeset="$3" dir request mode path
  [[ $# -eq 3 ]] || return 1
  jq -e . >/dev/null 2>&1 <<<"$changeset" || return 1
  dir="$(graph_delegation_ledger_dir "$workspace" "$id")" || return 1
  request="$dir/request.json"
  _graph_delegation_ledger_schema_check "$request" "$id" || return 1
  mode="$(jq -r '.mode // .access // .accessMode // .delegationMode // empty' "$request")"
  [[ "$mode" == "changeset" ]] || return 1
  path="$dir/changeset.json"
  ralph_atomic_write_json "$path" '{schemaVersion:$sv,delegatedRunId:$id,changeset:($changeset|fromjson)}' \
    --argjson sv "$GRAPH_DELEGATION_LEDGER_SCHEMA_VERSION" --arg id "$id" --arg changeset "$changeset"
}
