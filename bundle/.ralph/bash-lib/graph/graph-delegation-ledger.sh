#!/usr/bin/env bash
# Durable ledger for Ralph-brokered delegated children.  This is deliberately
# separate from graph-state.sh: a delegated child is supervised work below a
# durable parent node, not a graph node and never changes the frozen graph.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

if [[ -n "${GRAPH_DELEGATION_LEDGER_LOADED:-}" ]]; then return 0; fi
GRAPH_DELEGATION_LEDGER_LOADED=1

_GRAPH_DELEGATION_LEDGER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F ralph_atomic_write_json >/dev/null 2>&1; then
  # shellcheck source=../atomic-json.sh
  source "$_GRAPH_DELEGATION_LEDGER_DIR/../atomic-json.sh"
fi
if ! declare -F graph_state_nodes_dir >/dev/null 2>&1; then
  # shellcheck source=graph-state.sh
  source "$_GRAPH_DELEGATION_LEDGER_DIR/graph-state.sh"
fi
if ! declare -F graph_depth_policy_ledger_guard >/dev/null 2>&1; then
  # shellcheck source=graph-depth-policy.sh
  source "$_GRAPH_DELEGATION_LEDGER_DIR/graph-depth-policy.sh"
fi

GRAPH_DELEGATION_LEDGER_SCHEMA_VERSION=1
GRAPH_DELEGATION_LEDGER_STATES=(queued running succeeded failed cancelled awaiting-ack)

graph_delegation_ledger_log() {
  local workspace="$1"; shift
  local state_root path
  state_root="$(graph_state_state_root "$workspace")" || return 0
  path="$state_root/logs/delegation-ledger.log"
  mkdir -p "$(dirname "$path")" 2>/dev/null || true
  printf '[%s] graph-delegation-ledger: %s\n' "$(graph_state_now_iso)" "$*" >>"$path" 2>/dev/null || true
}

graph_delegation_ledger_safe_component() {
  [[ -n "${1:-}" ]] || return 1
  printf '%s' "$1" | sed 's/[^A-Za-z0-9._-]/_/g'
}

graph_delegation_ledger_root() {
  local workspace="$1" namespace="$2" run_id="$3" node_id="$4" node_dir
  node_dir="$(graph_state_nodes_dir "$workspace" "$namespace" "$run_id")" || return 1
  printf '%s/%s/delegations\n' "$node_dir" "$(graph_delegation_ledger_safe_component "$node_id")"
}

graph_delegation_ledger_dir() {
  local root
  root="$(graph_delegation_ledger_root "$1" "$2" "$3" "$4")" || return 1
  printf '%s/%s\n' "$root" "$(graph_delegation_ledger_safe_component "$5")"
}

# Stable opaque id: changing any parent identity or supplied idempotency key
# produces a different child. The content fingerprint below detects key reuse
# with a different request instead of silently accepting it.
graph_delegation_ledger_id() {
  local run_id="$1" node_id="$2" parent_attempt="$3" key="$4" digest
  [[ -n "$run_id" && -n "$node_id" && -n "$parent_attempt" && -n "$key" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  if command -v shasum >/dev/null 2>&1; then
    digest="$(jq -cn --arg r "$run_id" --arg n "$node_id" --arg a "$parent_attempt" --arg k "$key" '{runId:$r,parentNodeId:$n,parentAttemptId:$a,idempotencyKey:$k}' | shasum -a 256 | awk '{print $1}')"
  else
    digest="$(jq -cn --arg r "$run_id" --arg n "$node_id" --arg a "$parent_attempt" --arg k "$key" '{runId:$r,parentNodeId:$n,parentAttemptId:$a,idempotencyKey:$k}' | sha256sum | awk '{print $1}')"
  fi
  printf 'delegation-%s\n' "${digest:0:24}"
}

graph_delegation_ledger_valid_state() {
  local wanted="$1" state
  for state in "${GRAPH_DELEGATION_LEDGER_STATES[@]}"; do [[ "$state" == "$wanted" ]] && return 0; done
  return 1
}

graph_delegation_ledger_request_file() { printf '%s/request.json\n' "$(graph_delegation_ledger_dir "$@")"; }
graph_delegation_ledger_status_file() { printf '%s/status.json\n' "$(graph_delegation_ledger_dir "$@")"; }
graph_delegation_ledger_policy_file() { printf '%s/policy.json\n' "$(graph_delegation_ledger_dir "$@")"; }
graph_delegation_ledger_plan_file() { printf '%s/child.plan.md\n' "$(graph_delegation_ledger_dir "$@")"; }
# This record is deliberately separate from status.json.  status is the
# durable result contract; process.json is only a recoverable supervision hint
# and may be stale after SIGKILL or a scheduler restart.
graph_delegation_ledger_process_file() { printf '%s/child-process.json\n' "$(graph_delegation_ledger_dir "$@")"; }

# The generated plan is not JSON, but needs the same publish guarantee as the
# JSON records: never expose a truncated plan after a parent/scheduler death.
_graph_delegation_ledger_write_plan() {
  local target="$1" content="$2" tmp
  tmp="$(mktemp "$(dirname "$target")/.child-plan-XXXXXX" 2>/dev/null)" || return 1
  if ! printf '%s\n' "$content" >"$tmp"; then rm -f "$tmp"; return 1; fi
  ralph_fsync_path "$tmp"
  if ! mv -f "$tmp" "$target"; then rm -f "$tmp"; return 1; fi
  ralph_fsync_path "$(dirname "$target")"
}

_graph_delegation_ledger_fingerprint() {
  local task="$1" policy="$2" runtime="$3" agent="$4" model="$5" depth="$6" workspace_mode="$7" paths="$8" child_plan="$9"
  jq -cn --arg task "$task" --argjson policy "$policy" --arg runtime "$runtime" --arg agent "$agent" --arg model "$model" --argjson depth "$depth" --arg workspaceMode "$workspace_mode" --argjson artifactPaths "$paths" --arg childPlan "$child_plan" \
    '{task:$task,policy:$policy,runtime:$runtime,agent:$agent,model:$model,depth:$depth,workspaceMode:$workspaceMode,artifactPaths:$artifactPaths,childPlan:$childPlan}' | jq -cS .
}

# graph_delegation_ledger_start <workspace> <namespace> <run-id> <parent-node>
#   <parent-attempt> <idempotency-key> <task> <policy-json> <runtime> <agent>
#   <model> <depth> <workspace-mode> <artifact-paths-json> <child-plan-content>
# Prints the delegation id. Repeating an identical request returns the same id;
# reuse with a different content fingerprint fails closed.
graph_delegation_ledger_start() {
  local workspace="$1" namespace="$2" run_id="$3" node_id="$4" parent_attempt="$5" key="$6" task="$7" policy="$8" runtime="$9" agent="${10}" model="${11}" depth="${12}" workspace_mode="${13}" paths="${14}" child_plan="${15}"
  local did dir request status policy_file plan_file fingerprint now existing deadline
  [[ -n "$workspace" && -n "$namespace" && -n "$run_id" && -n "$node_id" && -n "$parent_attempt" && -n "$key" && -n "$task" && -n "$runtime" && -n "$agent" && -n "$depth" && -n "$workspace_mode" ]] || return 1
  [[ "$depth" =~ ^[0-9]+$ ]] || return 1
  # Layer 6: ledger depth guard — final write-path check independent of the MCP handler.
  if ! graph_depth_policy_ledger_guard "$depth" "ralph_delegate_start" 2>/dev/null; then
    graph_delegation_ledger_log "$workspace" "ERROR start denied: ledger depth guard depth=$depth"
    return 1
  fi
  jq -e . >/dev/null 2>&1 <<<"$policy" && jq -e . >/dev/null 2>&1 <<<"$paths" || return 1
  did="$(graph_delegation_ledger_id "$run_id" "$node_id" "$parent_attempt" "$key")" || return 1
  dir="$(graph_delegation_ledger_dir "$workspace" "$namespace" "$run_id" "$node_id" "$did")" || return 1
  fingerprint="$(_graph_delegation_ledger_fingerprint "$task" "$policy" "$runtime" "$agent" "$model" "$depth" "$workspace_mode" "$paths" "$child_plan")" || return 1
  mkdir -p "$(dirname "$dir")" || return 1

  # mkdir is the portable Bash-3.2 mutual exclusion primitive. The creator
  # publishes request.json last; concurrent callers wait for that commit point.
  if mkdir "$dir" 2>/dev/null; then
    now="$(graph_state_now_iso)"
    policy_file="$dir/policy.json"; plan_file="$dir/child.plan.md"; request="$dir/request.json"; status="$dir/status.json"
    if ! ralph_atomic_write_json "$policy_file" '{schemaVersion:$sv, policy:$p}' --argjson sv "$GRAPH_DELEGATION_LEDGER_SCHEMA_VERSION" --argjson p "$policy" \
      || ! _graph_delegation_ledger_write_plan "$plan_file" "$child_plan" \
      || ! ralph_atomic_write_json "$status" '{schemaVersion:$sv, delegationId:$id, status:"queued", createdAt:$now, updatedAt:$now, attempts:[], usage:{}, verificationOutcome:null, finalResult:null}' --argjson sv "$GRAPH_DELEGATION_LEDGER_SCHEMA_VERSION" --arg id "$did" --arg now "$now" \
      || ! ralph_atomic_write_json "$request" '{schemaVersion:$sv, delegationId:$id, requestFingerprint:$fp, runId:$run, parentNodeId:$node, parentAttemptId:$attempt, idempotencyKey:$key, task:$task, runtime:$runtime, agent:$agent, model:$model, depth:$depth, workspaceMode:$mode, artifactPaths:$paths, createdAt:$now}' --argjson sv "$GRAPH_DELEGATION_LEDGER_SCHEMA_VERSION" --arg id "$did" --arg fp "$fingerprint" --arg run "$run_id" --arg node "$node_id" --arg attempt "$parent_attempt" --arg key "$key" --arg task "$task" --arg runtime "$runtime" --arg agent "$agent" --arg model "$model" --argjson depth "$depth" --arg mode "$workspace_mode" --argjson paths "$paths" --arg now "$now"; then
      graph_delegation_ledger_log "$workspace" "ERROR start failed delegation=$did"
      return 1
    fi
    ralph_fsync_path "$plan_file"
    graph_delegation_ledger_log "$workspace" "start delegation=$did parent=$node_id/$parent_attempt created"
    printf '%s\n' "$did"
    return 0
  fi

  request="$dir/request.json"; deadline=$(( $(date +%s) + 5 ))
  while [[ ! -f "$request" && $(date +%s) -lt $deadline ]]; do sleep 1; done
  [[ -f "$request" ]] || { graph_delegation_ledger_log "$workspace" "ERROR start incomplete delegation=$did"; return 1; }
  existing="$(jq -r '.requestFingerprint // empty' "$request" 2>/dev/null)" || return 1
  if [[ "$existing" != "$fingerprint" ]]; then
    graph_delegation_ledger_log "$workspace" "ERROR idempotency-conflict delegation=$did parent=$node_id/$parent_attempt"
    echo "Error: idempotency key was reused with different task or policy content" >&2
    return 1
  fi
  graph_delegation_ledger_log "$workspace" "start delegation=$did parent=$node_id/$parent_attempt idempotent"
  printf '%s\n' "$did"
}

# graph_delegation_ledger_transition <workspace> <namespace> <run-id> <node-id>
#   <delegation-id> <state> [attempt-id] [verification-outcome] [usage-json]
#   [final-result-json] [reason]
graph_delegation_ledger_transition() {
  local workspace="$1" namespace="$2" run_id="$3" node_id="$4" did="$5" state="$6" attempt_id="${7:-}" verification="${8:-}" usage="${9:-}" result="${10:-}" reason="${11:-}"
  local status base now
  [[ -n "$usage" ]] || usage='{}'
  [[ -n "$result" ]] || result='null'
  graph_delegation_ledger_valid_state "$state" || return 1
  status="$(graph_delegation_ledger_status_file "$workspace" "$namespace" "$run_id" "$node_id" "$did")" || return 1
  [[ -f "$status" ]] || return 1
  base="$(jq -c . "$status" 2>/dev/null)" || return 1
  jq -e . >/dev/null 2>&1 <<<"$usage" && jq . >/dev/null 2>&1 <<<"$result" || return 1
  now="$(graph_state_now_iso)"
  if ! ralph_atomic_write_json "$status" '
    ($base | fromjson) as $old |
    ($usage | fromjson) as $u |
    ($result | fromjson) as $res |
    ($old.usage // {}) as $oldUsage |
    $old + {schemaVersion:$sv,status:$state,updatedAt:$now}
    | .attempts = (($old.attempts // []) + (if $attempt == "" then [] else [{attemptId:$attempt,state:$state,at:$now} + (if $verification == "" then {} else {verificationOutcome:$verification} end) + (if ($u | length) == 0 then {} else {usage:$u} end) + (if $reason == "" then {} else {reason:$reason} end)] end))
    | .usage = ($oldUsage + (reduce ($u | to_entries[]) as $e ($oldUsage; .[$e.key] = ((.[$e.key] // 0) + $e.value))))
    | (if $verification == "" then . else .verificationOutcome = $verification end)
    | (if $res == null then . else .finalResult = $res end)
    | (if ($state == "succeeded" or $state == "failed" or $state == "cancelled") then .finishedAt = $now else . end)' \
    --arg base "$base" --argjson sv "$GRAPH_DELEGATION_LEDGER_SCHEMA_VERSION" --arg state "$state" --arg now "$now" --arg attempt "$attempt_id" --arg verification "$verification" --arg usage "$usage" --arg result "$result" --arg reason "$reason"; then return 1; fi
  graph_delegation_ledger_log "$workspace" "transition delegation=$did state=$state attempt=${attempt_id:-none}"
}

graph_delegation_ledger_read_status() {
  local status
  status="$(graph_delegation_ledger_status_file "$@")" || return 1
  [[ -f "$status" ]] || return 1
  jq -e . "$status" 2>/dev/null
}

# Retrieving a terminal result is an explicit parent acknowledgement.  Keep it
# on the status record so the completion gate survives runner restarts.
graph_delegation_ledger_acknowledge() {
  local workspace="$1" namespace="$2" run_id="$3" node_id="$4" did="$5" acknowledgement="${6:-result-read}"
  local status base now
  status="$(graph_delegation_ledger_status_file "$workspace" "$namespace" "$run_id" "$node_id" "$did")" || return 1
  [[ -f "$status" ]] || return 1
  base="$(jq -c . "$status" 2>/dev/null)" || return 1
  now="$(graph_state_now_iso)"
  ralph_atomic_write_json "$status" '($base | fromjson) + {acknowledgement:{at:$now,kind:$kind}}' \
    --arg base "$base" --arg now "$now" --arg kind "$acknowledgement" || return 1
  graph_delegation_ledger_log "$workspace" "acknowledged delegation=$did kind=$acknowledgement"
}
