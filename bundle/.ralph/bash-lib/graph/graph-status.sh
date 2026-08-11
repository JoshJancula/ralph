#!/usr/bin/env bash
# Graph status verb: read-only view of a live or completed graph run.
#
# graph_status_cli <--namespace <ns>> <--run <run-id|latest>> [--workspace <dir>]
#   Entry point from graph-run.sh.  Reads only the graph-runs directory so it is
#   safe to call against a live in-progress run.
#
# graph_status_run <workspace> <namespace> <run_id>
#   Core implementation.  Prints:
#     1. A table: node, type, runtime, state, attempt count, duration.
#     2. A mermaid flowchart with a classDef per state and live run-state classes
#        applied per node.  Consensus voter nodes include per-voter provenance and
#        confidence so "which provider dissented" is answerable in one command.
#
# This script never writes to the graph-runs directory.
#
# jq-only for JSON parsing; no python3; bash 3.2 safe; no associative arrays;
# no namerefs.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

GRAPH_STATUS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -F graph_state_runs_root >/dev/null 2>&1; then
  # shellcheck source=./graph-state.sh
  source "$GRAPH_STATUS_SCRIPT_DIR/graph-state.sh"
fi
if ! declare -F graph_delegation_ledger_root >/dev/null 2>&1; then
  # shellcheck source=graph-delegation-ledger.sh
  source "$GRAPH_STATUS_SCRIPT_DIR/graph-delegation-ledger.sh"
fi

# _graph_status_iso_to_epoch <iso_timestamp>
# Convert an ISO-8601 UTC timestamp (YYYY-MM-DDTHH:MM:SSZ) to Unix epoch
# seconds.  Returns 0 on success with the epoch on stdout; returns 1 when
# neither GNU date nor BSD date is available.  Does not require python3.
_graph_status_iso_to_epoch() {
  local ts="$1"
  if [[ -z "$ts" ]]; then
    return 1
  fi
  # GNU date (Linux).
  if date -d "$ts" +%s >/dev/null 2>&1; then
    date -d "$ts" +%s
    return 0
  fi
  # BSD date (macOS).
  if date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s >/dev/null 2>&1; then
    date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s
    return 0
  fi
  return 1
}

# _graph_status_duration_fmt <started_at> <finished_at>
# Return a HH:MM:SS string for the interval, or "-" when timestamps are
# missing or unparseable.
_graph_status_duration_fmt() {
  local started="$1" finished="$2"
  if [[ -z "$started" || -z "$finished" ]]; then
    printf '-'
    return 0
  fi
  local s f diff h m sec
  # The common live-run case stays within one UTC date. Avoid spawning BSD/GNU
  # date repeatedly for every node in a status refresh.
  if [[ "${started:0:10}" == "${finished:0:10}" && "${started:11:8}" =~ ^[0-9:]+$ && "${finished:11:8}" =~ ^[0-9:]+$ ]]; then
    local sh sm ss fh fm fs
    sh="${started:11:2}"; sm="${started:14:2}"; ss="${started:17:2}"
    fh="${finished:11:2}"; fm="${finished:14:2}"; fs="${finished:17:2}"
    diff=$(( (10#$fh * 3600 + 10#$fm * 60 + 10#$fs) - (10#$sh * 3600 + 10#$sm * 60 + 10#$ss) ))
    [[ "$diff" -ge 0 ]] || diff=0
    h=$(( diff / 3600 )); m=$(( (diff % 3600) / 60 )); sec=$(( diff % 60 ))
    printf '%02d:%02d:%02d' "$h" "$m" "$sec"
    return 0
  fi
  s="$(_graph_status_iso_to_epoch "$started")" || { printf '-'; return 0; }
  f="$(_graph_status_iso_to_epoch "$finished")" || { printf '-'; return 0; }
  diff=$(( f - s ))
  if [[ "$diff" -lt 0 ]]; then
    diff=0
  fi
  h=$(( diff / 3600 ))
  m=$(( (diff % 3600) / 60 ))
  sec=$(( diff % 60 ))
  printf '%02d:%02d:%02d' "$h" "$m" "$sec"
}

# _graph_status_table_row <node_id> <type> <runtime> <state> <attempts> <duration> [mode] [base] [scopes]
# Print one fixed-width table row.
_graph_status_table_row() {
  printf '%-32s %-20s %-12s %-14s %-10s %-10s %-10s %-24s %s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "${7:--}" "${8:--}" "${9:-}"
}

# _graph_status_scopes_fmt <scopes_json>
# Return a compact, human-readable summary of write scopes.
_graph_status_scopes_fmt() {
  local scopes_json="$1"
  if [[ -z "$scopes_json" ]]; then
    printf '-'
    return 0
  fi
  local count
  count="$(printf '%s' "$scopes_json" | jq 'length' 2>/dev/null)" || count=0
  if [[ "$count" -eq 0 ]]; then
    printf '-'
    return 0
  fi
  local first
  first="$(printf '%s' "$scopes_json" | jq -r '.[0]' 2>/dev/null)" || first=""
  if [[ "$count" -eq 1 ]]; then
    printf '%s' "$first"
  else
    printf '%s +%d' "$first" "$((count - 1))"
  fi
}

# _graph_status_attempts_extra <node_file>
# Print one indented metadata line per attempt that carries extra observability
# data: workspace mode/path, frozen base, write scopes, changeset hash,
# conflict artifact, integration inputs, gate outcome, repair epoch, subagent
# policy, runtime admission summary, and usage.
_graph_status_attempts_extra() {
  local node_file="$1"
  [[ -f "$node_file" ]] || return 0
  jq -e '[.attempts[]? | select(has("workspaceMode") or has("workspacePath") or has("writeScopes") or has("frozenBase") or has("changesetHash") or has("gateOutcome") or has("usageSnapshot") or has("admissionSummary"))] | length > 0' "$node_file" >/dev/null 2>&1 || return 0
  local attempts_count i
  attempts_count="$(jq '.attempts | length' "$node_file" 2>/dev/null)" || attempts_count=0
  i=0
  while [[ "$i" -lt "$attempts_count" ]]; do
    local mode path scopes base baseline hash conflict outcome subagent_mode cross_mode integration usage reason admission
    mode="$(jq -r --argjson idx "$i" '.attempts[$idx].workspaceMode // empty' "$node_file" 2>/dev/null)"
    path="$(jq -r --argjson idx "$i" '.attempts[$idx].workspacePath // empty' "$node_file" 2>/dev/null)"
    scopes="$(jq -r --argjson idx "$i" '.attempts[$idx].writeScopes // empty' "$node_file" 2>/dev/null)"
    base="$(jq -r --argjson idx "$i" '.attempts[$idx].frozenBase // empty' "$node_file" 2>/dev/null)"
    baseline="$(jq -r --argjson idx "$i" '.attempts[$idx].changesetBaseline // empty' "$node_file" 2>/dev/null)"
    hash="$(jq -r --argjson idx "$i" '.attempts[$idx].changesetHash // empty' "$node_file" 2>/dev/null)"
    conflict="$(jq -r --argjson idx "$i" '.attempts[$idx].conflictArtifact // empty' "$node_file" 2>/dev/null)"
    outcome="$(jq -r --argjson idx "$i" '.attempts[$idx].gateOutcome // empty' "$node_file" 2>/dev/null)"
    subagent_mode="$(jq -r --argjson idx "$i" '.attempts[$idx].nativeSubagentMode // empty' "$node_file" 2>/dev/null)"
    cross_mode="$(jq -r --argjson idx "$i" '.attempts[$idx].crossRuntimeMode // empty' "$node_file" 2>/dev/null)"
    integration="$(jq -r --argjson idx "$i" '.attempts[$idx].integrationInputs // empty' "$node_file" 2>/dev/null)"
    usage="$(jq -r --argjson idx "$i" '.attempts[$idx].usageSnapshot // empty' "$node_file" 2>/dev/null)"
    reason="$(jq -r --argjson idx "$i" '.attempts[$idx].reason // empty' "$node_file" 2>/dev/null)"
    admission="$(jq -r --argjson idx "$i" '.attempts[$idx].admissionSummary // empty' "$node_file" 2>/dev/null)"
    if [[ -n "$mode" || -n "$path" || -n "$scopes" || -n "$base" || -n "$baseline" || -n "$hash" || -n "$conflict" || -n "$outcome" || -n "$subagent_mode" || -n "$cross_mode" || -n "$integration" || -n "$usage" || -n "$reason" || -n "$admission" ]]; then
      printf '    attempt %d:' "$((i + 1))"
      [[ -n "$mode" ]] && printf ' mode=%s' "$mode"
      [[ -n "$path" ]] && printf ' workspace=%s' "$path"
      [[ -n "$scopes" ]] && printf ' scopes=%s' "$scopes"
      [[ -n "$base" ]] && printf ' base=%s' "${base:0:16}"
      [[ -n "$baseline" ]] && printf ' baseline=%s' "$baseline"
      [[ -n "$hash" ]] && printf ' changesetHash=%s' "${hash:0:16}"
      [[ -n "$conflict" ]] && printf ' conflictArtifact=%s' "$conflict"
      [[ -n "$outcome" ]] && printf ' gateOutcome=%s' "$outcome"
      [[ -n "$subagent_mode" ]] && printf ' nativeSubagent=%s' "$subagent_mode"
      [[ -n "$cross_mode" ]] && printf ' crossRuntime=%s' "$cross_mode"
      [[ -n "$integration" ]] && printf ' integration=%s' "$integration"
      [[ -n "$usage" ]] && printf ' usage=%s' "$usage"
      [[ -n "$admission" ]] && printf ' admission=%s' "$admission"
      [[ -n "$reason" ]] && printf ' reason=%s' "$reason"
      printf '\n'
    fi
    i=$((i + 1))
  done
}

# _graph_status_node_extra <node_file>
# Print per-node metadata (aggregated from the latest attempt or the node
# entry itself) when it carries v2 observability fields.
_graph_status_node_extra() {
  local node_file="$1" node_id="$2"
  [[ -f "$node_file" ]] || return 0
  jq -e 'has("workspaceMode") or has("workspacePath") or has("writeScopes") or has("frozenBase") or has("changesetHash") or has("conflictArtifact") or has("gateOutcome") or has("nativeSubagentMode") or has("crossRuntimeMode") or has("integrationInputs") or has("usageSnapshot") or has("publishReadiness") or has("repairEpoch") or has("admissionSummary") or has("verificationResourceClasses")' "$node_file" >/dev/null 2>&1 || return 0
  local mode path scopes base baseline hash conflict outcome subagent_mode cross_mode integration usage publish repair_epoch admission verification_classes
  mode="$(jq -r '.workspaceMode // empty' "$node_file" 2>/dev/null)"
  path="$(jq -r '.workspacePath // empty' "$node_file" 2>/dev/null)"
  scopes="$(jq -r '.writeScopes // empty' "$node_file" 2>/dev/null)"
  base="$(jq -r '.frozenBase // empty' "$node_file" 2>/dev/null)"
  baseline="$(jq -r '.changesetBaseline // empty' "$node_file" 2>/dev/null)"
  hash="$(jq -r '.changesetHash // empty' "$node_file" 2>/dev/null)"
  conflict="$(jq -r '.conflictArtifact // empty' "$node_file" 2>/dev/null)"
  outcome="$(jq -r '.gateOutcome // empty' "$node_file" 2>/dev/null)"
  subagent_mode="$(jq -r '.nativeSubagentMode // empty' "$node_file" 2>/dev/null)"
  cross_mode="$(jq -r '.crossRuntimeMode // empty' "$node_file" 2>/dev/null)"
  integration="$(jq -r '.integrationInputs // empty' "$node_file" 2>/dev/null)"
  usage="$(jq -r '.usageSnapshot // empty' "$node_file" 2>/dev/null)"
  publish="$(jq -r '.publishReadiness // empty' "$node_file" 2>/dev/null)"
  repair_epoch="$(jq -r '.repairEpoch // empty' "$node_file" 2>/dev/null)"
  admission="$(jq -r '.admissionSummary // empty' "$node_file" 2>/dev/null)"
  verification_classes="$(jq -r '.verificationResourceClasses // empty' "$node_file" 2>/dev/null)"
  if [[ -n "$mode" || -n "$path" || -n "$scopes" || -n "$base" || -n "$baseline" || -n "$hash" || -n "$conflict" || -n "$outcome" || -n "$subagent_mode" || -n "$cross_mode" || -n "$integration" || -n "$usage" || -n "$publish" || -n "$repair_epoch" || -n "$admission" || -n "$verification_classes" ]]; then
    printf '  %s metadata:' "$node_id"
    [[ -n "$mode" ]] && printf ' mode=%s' "$mode"
    [[ -n "$path" ]] && printf ' workspace=%s' "$path"
    [[ -n "$scopes" ]] && printf ' scopes=%s' "$scopes"
    [[ -n "$base" ]] && printf ' base=%s' "${base:0:16}"
    [[ -n "$baseline" ]] && printf ' changeset=%s' "$baseline"
    [[ -n "$hash" ]] && printf ' changesetHash=%s' "${hash:0:16}"
    [[ -n "$conflict" ]] && printf ' conflictArtifact=%s' "$conflict"
    [[ -n "$outcome" ]] && printf ' gateOutcome=%s' "$outcome"
    [[ -n "$subagent_mode" ]] && printf ' nativeSubagent=%s' "$subagent_mode"
    [[ -n "$cross_mode" ]] && printf ' crossRuntime=%s' "$cross_mode"
    [[ -n "$integration" ]] && printf ' integrationInputs=%s' "$integration"
    [[ -n "$usage" ]] && printf ' usage=%s' "$usage"
    [[ -n "$admission" ]] && printf ' admission=%s' "$admission"
    [[ -n "$publish" ]] && printf ' publish=%s' "$publish"
    [[ -n "$repair_epoch" ]] && printf ' repairEpoch=%s' "$repair_epoch"
    [[ -n "$verification_classes" ]] && printf ' verificationResources=%s' "$verification_classes"
    printf '\n'
  fi
  _graph_status_attempts_extra "$node_file"
}

# _graph_status_mermaid_classdefs
# Emit the classDef block for every recognized node state.
_graph_status_mermaid_classdefs() {
  printf '  classDef state_pending     fill:#888,color:#fff\n'
  printf '  classDef state_ready       fill:#5599ee,color:#fff\n'
  printf '  classDef state_running     fill:#2255cc,color:#fff\n'
  printf '  classDef state_succeeded   fill:#2a8a2a,color:#fff\n'
  printf '  classDef state_failed      fill:#bb2222,color:#fff\n'
  printf '  classDef state_blocked     fill:#cc7700,color:#fff\n'
  printf '  classDef state_skipped     fill:#aaaaaa,color:#333\n'
  printf '  classDef state_awaiting_ack fill:#ddbb00,color:#333\n'
  printf '  classDef state_cancelled   fill:#555,color:#fff\n'
}

# _graph_status_mermaid_classname <state>
# Map a node state to the matching classDef name.
_graph_status_mermaid_classname() {
  case "$1" in
    pending)      printf 'state_pending' ;;
    ready)        printf 'state_ready' ;;
    running)      printf 'state_running' ;;
    succeeded)    printf 'state_succeeded' ;;
    failed)       printf 'state_failed' ;;
    blocked)      printf 'state_blocked' ;;
    skipped)      printf 'state_skipped' ;;
    awaiting-ack) printf 'state_awaiting_ack' ;;
    cancelled)    printf 'state_cancelled' ;;
    *)            printf 'state_pending' ;;
  esac
}

# _graph_status_consensus_voters <workspace> <namespace> <node_id>
# Print per-voter provenance lines for a consensus join node.  Reads from the
# consensus-result.json written by graph-consensus.sh; returns nothing when the
# file is absent (run still in progress or join not yet reached).
_graph_status_consensus_voters() {
  local workspace="$1" namespace="$2" node_id="$3"
  local safe_id result_path
  safe_id="$(printf '%s' "$node_id" | sed 's/[^A-Za-z0-9._-]/_/g')"
  result_path="${workspace}/.ralph-workspace/artifacts/${namespace}/consensus/${safe_id}.json"
  if [[ ! -f "$result_path" ]]; then
    return 0
  fi
  local voter_count i voter_id runtime status agent model confidence
  voter_count="$(jq '.voters | length' "$result_path" 2>/dev/null)" || return 0
  i=0
  while [[ "$i" -lt "$voter_count" ]]; do
    voter_id="$(jq -r ".voters[$i].voterId // empty" "$result_path")"
    runtime="$(jq -r ".voters[$i].runtime // empty" "$result_path")"
    status="$(jq -r ".voters[$i].status // empty" "$result_path")"
    agent="$(jq -r ".voters[$i].agent // empty" "$result_path")"
    model="$(jq -r ".voters[$i].model // empty" "$result_path")"
    confidence="$(jq -r ".voters[$i].confidence // empty" "$result_path")"
    printf '    voter=%-24s runtime=%-10s status=%-18s' \
      "${voter_id:-?}" "${runtime:-?}" "${status:-?}"
    if [[ -n "$agent" ]]; then
      printf ' agent=%s' "$agent"
    fi
    if [[ -n "$model" ]]; then
      printf ' model=%s' "$model"
    fi
    if [[ -n "$confidence" ]]; then
      printf ' confidence=%s' "$confidence"
    fi
    printf '\n'
    i=$(( i + 1 ))
  done
  # Report dissenters explicitly so "which provider dissented" is grep-able.
  local dissent
  dissent="$(jq -r '.dissent[]? // empty' "$result_path" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
  if [[ -n "$dissent" ]]; then
    printf '    dissenting-voters: %s\n' "$dissent"
  fi
}

# _graph_status_brokered_children <workspace> <namespace> <run_id> <node_id>
# Print durable brokered child provenance as nested rows. Brokered children are
# ledger children of the parent node, not peer nodes in the frozen DAG.
_graph_status_brokered_children() {
  local workspace="$1" namespace="$2" run_id="$3" node_id="$4"
  local root dir
  root="$(graph_delegation_ledger_root "$workspace" "$namespace" "$run_id" "$node_id" 2>/dev/null)" || return 0
  [[ -d "$root" ]] || return 0
  for dir in "$root"/delegation-*; do
    [[ -d "$dir" && -f "$dir/request.json" && -f "$dir/status.json" ]] || continue
    local did runtime state result
    did="$(jq -r '.delegationId // empty' "$dir/request.json" 2>/dev/null)"
    runtime="$(jq -r '.runtime // empty' "$dir/request.json" 2>/dev/null)"
    state="$(jq -r '.status // unknown' "$dir/status.json" 2>/dev/null)"
    printf '    brokered child=%-22s runtime=%-10s state=%s\n' \
      "${did:-?}" "${runtime:-?}" "${state:-?}"
  done
}

# _graph_status_subagent_events <workspace> <namespace> <run_id> <node_id>
# Print best-effort native subagent events recorded in the observability log.
_graph_status_subagent_events() {
  local workspace="$1" namespace="$2" run_id="$3" node_id="$4"
  local log_file
  log_file="${workspace}/.ralph-workspace/graph-runs/${namespace}/${run_id}/observability.jsonl"
  [[ -f "$log_file" ]] || {
    log_file="${workspace}/.ralph-workspace/logs/native-readonly.log"
    [[ -f "$log_file" ]] || return 0
  }
  local events
  events="$(jq -r --arg node "$node_id" 'select(.nodeId == $node and (.event | startswith("native-subagent"))) | "    native-subagent event=\(.event) \(.details // {})"' "$log_file" 2>/dev/null)"
  [[ -n "$events" ]] || return 0
  printf '%s\n' "$events"
}

# _graph_status_usage_aggregate <nodes-dir>
# Parent summaries are cumulative snapshots, so retain only the latest
# snapshot per durable node. Brokered children are separate durable attempts:
# sum their status usage once per child ledger, never through the parent.
_graph_status_usage_aggregate() {
  local nodes_dir="$1" child_files=()
  [[ -d "$nodes_dir" ]] || return 0
  local node_usage child_usage
  node_usage="$(jq -cs '
    def add_numbers: reduce .[] as $o ({}; reduce ($o | to_entries[]? | select(.value | type == "number")) as $e (. ; .[$e.key] = ((.[$e.key] // 0) + $e.value)));
    [ .[] | .attempts[-1].usageSnapshot? | select(type == "object") ] | add_numbers
  ' "$nodes_dir"/*.json 2>/dev/null)" || node_usage='{}'
  for child in "$nodes_dir"/*/delegations/delegation-*/status.json; do
    [[ -f "$child" ]] && child_files+=("$child")
  done
  if [[ "${#child_files[@]}" -gt 0 ]]; then
    child_usage="$(jq -cs '
      def add_numbers: reduce .[] as $o ({}; reduce ($o | to_entries[]? | select(.value | type == "number")) as $e (. ; .[$e.key] = ((.[$e.key] // 0) + $e.value)));
      [ .[] | .usage? | select(type == "object") ] | add_numbers
    ' "${child_files[@]}" 2>/dev/null)" || child_usage='{}'
  else
    child_usage='{}'
  fi
  printf '  usage parent=%s brokered-children=%s\n' "$node_usage" "$child_usage"
}

# _graph_status_concurrency_reductions <run-dir>
# Explain actual admission reductions using the append-only scheduler log.
_graph_status_concurrency_reductions() {
  local run_dir="$1" log_file
  log_file="$run_dir/observability.jsonl"
  [[ -f "$log_file" ]] || return 0
  local reductions
  reductions="$(jq -r '
    select(.event == "admission") |
    if .workKind == "broker-child" and .decision == "denied" then "broker-capacity"
    elif .subagents == "on" then "native-subagent-reservation"
    elif .sameRuntimeParallelSafe == false then "runtime-overlay"
    elif ((.reason // "") | test("verification|resource"; "i")) then "verification-resource-class"
    else empty end
  ' "$log_file" 2>/dev/null | sort -u | tr "\n" "," | sed 's/,$//')"
  [[ -n "$reductions" ]] && printf '  concurrency reduced-by=%s\n' "$reductions"
}

# graph_status_run <workspace> <namespace> <run_id>
#
# Core read-only status display.  Never writes to the graph-runs directory.
graph_status_run() {
  local workspace="$1" namespace="$2" run_id="$3"

  if [[ -z "$workspace" || -z "$namespace" || -z "$run_id" ]]; then
    echo "Error: graph_status_run requires workspace, namespace, run_id" >&2
    return 1
  fi

  command -v jq >/dev/null 2>&1 || {
    echo "Error: jq is required for graph status" >&2
    return 1
  }

  local run_file graph_file nodes_dir
  run_file="$(graph_state_run_file "$workspace" "$namespace" "$run_id")" || return 1
  graph_file="$(graph_state_graph_file "$workspace" "$namespace" "$run_id")" || return 1
  nodes_dir="$(graph_state_nodes_dir "$workspace" "$namespace" "$run_id")" || return 1

  if [[ ! -f "$run_file" ]]; then
    echo "Error: run not found: $run_file" >&2
    return 1
  fi
  if [[ ! -f "$graph_file" ]]; then
    echo "Error: frozen graph not found: $graph_file" >&2
    return 1
  fi

  local run_status started_at plan_path
  run_status="$(jq -r '.status // "unknown"' "$run_file")"
  started_at="$(jq -r '.startedAt // ""' "$run_file")"
  plan_path="$(jq -r '.planPath // ""' "$run_file")"

  printf '# graph status  run=%s  namespace=%s  status=%s\n' \
    "$run_id" "$namespace" "$run_status"
  if [[ -n "$plan_path" ]]; then
    printf '# plan: %s\n' "$plan_path"
  fi
  if [[ -n "$started_at" ]]; then
    printf '# started: %s\n' "$started_at"
  fi
  printf '\n'

  _graph_status_usage_aggregate "$nodes_dir"
  _graph_status_concurrency_reductions "$(dirname "$run_file")"
  printf '\n'

  # Table header.
  _graph_status_table_row "NODE" "TYPE" "RUNTIME" "STATE" "ATTEMPTS" "DURATION" "MODE" "BASE" "SCOPES"
  printf '%s\n' \
    "------------------------------------------------------------------------------------------------------------------------------------------------"

  # Read node ids from the frozen graph in graph order.
  local node_ids
  node_ids="$(jq -r '.nodes[].id // empty' "$graph_file" 2>/dev/null)"

  # Build mermaid node-state lines as we iterate to avoid a second pass.
  local mermaid_nodes="" mermaid_definitions=""

  while IFS= read -r nid || [[ -n "$nid" ]]; do
    [[ -z "$nid" ]] && continue

    local ntype runtime node_file node_state attempts_count duration graph_fields node_fields
    graph_fields="$(jq -r --arg id "$nid" '.nodes[] | select(.id == $id) | [(.type // "stage"), (.stage.runtime // "")] | @tsv' "$graph_file")"
    IFS=$'\t' read -r ntype runtime <<< "$graph_fields"

    node_file="$(graph_state_node_file "$workspace" "$namespace" "$run_id" "$nid")"
    node_state="pending"
    attempts_count=0
    duration="-"
    local mode="-" base="-" scopes="-" scopes_json=""

    if [[ -f "$node_file" ]]; then
      node_fields="$(jq -r '
        (.writeScopes // .attempts[-1].writeScopes // []) as $scopes |
        [(.status // "pending"), ((.attempts // []) | length), (.attempts[-1].startedAt // ""), (.attempts[-1].finishedAt // ""), (.workspaceMode // .attempts[-1].workspaceMode // "-"), (.frozenBase // .attempts[-1].frozenBase // "-"), (if ($scopes | length) == 0 then "-" elif ($scopes | length) == 1 then $scopes[0] else ($scopes[0] + " +" + (($scopes | length) - 1 | tostring)) end), (if (has("workspaceMode") or has("workspacePath") or has("writeScopes") or has("frozenBase") or has("changesetHash") or has("conflictArtifact") or has("gateOutcome") or has("nativeSubagentMode") or has("crossRuntimeMode") or has("integrationInputs") or has("usageSnapshot") or has("publishReadiness") or has("repairEpoch") or has("admissionSummary") or has("verificationResourceClasses")) then "yes" else "no" end)] | @tsv
      ' "$node_file" 2>/dev/null)"
      local last_started last_finished
      local has_observability="no"
      IFS=$'\t' read -r node_state attempts_count last_started last_finished mode base scopes has_observability <<< "$node_fields"
      duration="$(_graph_status_duration_fmt "$last_started" "$last_finished")"
      base="${base:0:16}"
    fi

    _graph_status_table_row "$nid" "$ntype" "${runtime:--}" "$node_state" \
      "$attempts_count" "$duration" "$mode" "$base" "$scopes"

    # Print v2 per-node metadata (workspace, scopes, gate outcome, etc.).
    if [[ "${has_observability:-no}" == "yes" ]]; then
      _graph_status_node_extra "$node_file" "$nid"
    fi

    # For consensus-barrier (join) nodes, show per-voter provenance.
    if [[ "$ntype" == "consensus-barrier" ]]; then
      _graph_status_consensus_voters "$workspace" "$namespace" "$nid"
    fi

    # Brokered children are durable ledger children, not DAG peer nodes.
    if [[ "$ntype" == "agent" || "$ntype" == "stage" ]]; then
      _graph_status_brokered_children "$workspace" "$namespace" "$run_id" "$nid"
    fi

    # Best-effort native subagent events (logged when the runtime supports them).
    _graph_status_subagent_events "$workspace" "$namespace" "$run_id" "$nid"

    # Accumulate mermaid node assignments (class per state).
    local safe_nid
    safe_nid="$(printf '%s' "$nid" | tr -c 'a-zA-Z0-9_-' '_')"
    local class_name
    class_name="$(_graph_status_mermaid_classname "$node_state")"
    mermaid_nodes="${mermaid_nodes}
  ${safe_nid}:::${class_name}"
    local escaped_label extra_label=""
    escaped_label="$(printf '%s' "$nid" | sed "s/\"/'/g")"
    [[ "$mode" != "-" ]] && extra_label="${extra_label}mode=${mode}\\n"
    [[ "$base" != "-" ]] && extra_label="${extra_label}base=${base}\\n"
    [[ "$scopes" != "-" ]] && extra_label="${extra_label}scopes=${scopes}"
    if [[ -n "$extra_label" ]]; then
      mermaid_definitions="${mermaid_definitions}
  ${safe_nid}[\"${escaped_label}\\n${runtime:-}\\n${extra_label}\"]:::${class_name}"
    else
      mermaid_definitions="${mermaid_definitions}
  ${safe_nid}[\"${escaped_label}\\n${runtime:-}\"]:::${class_name}"
    fi
  done <<< "$node_ids"

  # Mermaid section.
  printf '\n'
  printf '## mermaid (live state)\n'
  printf '\n'
  printf '```mermaid\n'
  printf 'flowchart TD\n'
  _graph_status_mermaid_classdefs

  # Node definitions with state class.
  printf '%s\n' "$mermaid_definitions"
  # Definitions were captured with the table data above so live status remains
  # responsive while a run is executing. Keep the legacy construction below
  # as reference for output compatibility without re-reading every ledger file.
  if false; then
  local safe_nid_def escaped_label ntype_def runtime_def
  while IFS= read -r nid || [[ -n "$nid" ]]; do
    [[ -z "$nid" ]] && continue
    safe_nid_def="$(printf '%s' "$nid" | tr -c 'a-zA-Z0-9_-' '_')"
    escaped_label="$(printf '%s' "$nid" | sed "s/\"/'/g")"
    ntype_def="$(jq -r --arg id "$nid" '.nodes[] | select(.id == $id) | .type // "stage"' "$graph_file")"
    runtime_def="$(jq -r --arg id "$nid" '.nodes[] | select(.id == $id) | .stage.runtime // ""' "$graph_file")"

    local node_state_def
    node_state_def="pending"
    local node_file_def
    node_file_def="$(graph_state_node_file "$workspace" "$namespace" "$run_id" "$nid")"
    local mode_def="" base_def="" scopes_def=""
    if [[ -f "$node_file_def" ]]; then
      node_state_def="$(jq -r '.status // "pending"' "$node_file_def" 2>/dev/null)"
      mode_def="$(jq -r '.workspaceMode // .attempts[-1].workspaceMode // ""' "$node_file_def" 2>/dev/null)"
      base_def="$(jq -r '.frozenBase // .attempts[-1].frozenBase // ""' "$node_file_def" 2>/dev/null)"
      base_def="${base_def:0:16}"
      scopes_def="$(_graph_status_scopes_fmt "$(jq -r '.writeScopes // .attempts[-1].writeScopes // empty' "$node_file_def" 2>/dev/null)")"
    fi

    local extra_label=""
    [[ -n "$mode_def" ]] && extra_label="${extra_label}mode=${mode_def}\n"
    [[ -n "$base_def" && "$base_def" != "-" ]] && extra_label="${extra_label}base=${base_def}\n"
    [[ -n "$scopes_def" && "$scopes_def" != "-" ]] && extra_label="${extra_label}scopes=${scopes_def}"

    local class_def
    class_def="$(_graph_status_mermaid_classname "$node_state_def")"
    if [[ -n "$extra_label" ]]; then
      printf '  %s["%s\n%s\n%s"]:::%s\n' \
        "$safe_nid_def" "$escaped_label" "${runtime_def:-}" "$extra_label" "$class_def"
    else
      printf '  %s["%s\n%s"]:::%s\n' \
        "$safe_nid_def" "$escaped_label" "${runtime_def:-}" "$class_def"
    fi
  done <<< "$node_ids"
  fi

  # Edges from the frozen graph.
  local edges_tsv
  edges_tsv="$(jq -r '
    [.edges[] | {from: .from, to: .to}] |
    sort_by(.from + .to) | .[] |
    "\(.from)\t\(.to)"
  ' "$graph_file" 2>/dev/null)"

  local real_node_ids_list
  real_node_ids_list="$(jq -r '[.nodes[].id] | join("\n")' "$graph_file" 2>/dev/null)"

  while IFS=$'\t' read -r from to || [[ -n "$from" ]]; do
    [[ -z "$from" ]] && continue
    local safe_from safe_to
    safe_from="$(printf '%s' "$from" | tr -c 'a-zA-Z0-9_-' '_')"
    if printf '%s\n' "$real_node_ids_list" | grep -qx "$to"; then
      safe_to="$(printf '%s' "$to" | tr -c 'a-zA-Z0-9_-' '_')"
      printf '  %s --> %s\n' "$safe_from" "$safe_to"
    else
      # Virtual consensus group id: fan out to voter nodes that depend on it.
      local voter_deps
      voter_deps="$(jq -r --arg vid "$to" '
        [.nodes[] |
          select(.type == "consensus-voter") |
          select(.dependsOn | map(. == $vid) | any) |
          .id
        ] | sort[]
      ' "$graph_file" 2>/dev/null)"
      while IFS= read -r vid || [[ -n "$vid" ]]; do
        [[ -z "$vid" ]] && continue
        safe_to="$(printf '%s' "$vid" | tr -c 'a-zA-Z0-9_-' '_')"
        printf '  %s --> %s\n' "$safe_from" "$safe_to"
      done <<< "$voter_deps"
    fi
  done <<< "$edges_tsv"

  printf '```\n'
}

# graph_status_cli [--namespace <ns>] [--run <run-id|latest>]
#   [--workspace <dir>]
#
# Entry point called by graph-run.sh.  Resolves the run selector and delegates
# to graph_status_run.  Reads only the graph-runs directory.
graph_status_cli() {
  local namespace="" run_token="" workspace=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --namespace) namespace="$2"; shift 2 ;;
      --namespace=*) namespace="${1#--namespace=}"; shift ;;
      --run) run_token="$2"; shift 2 ;;
      --run=*) run_token="${1#--run=}"; shift ;;
      --workspace) workspace="$2"; shift 2 ;;
      --workspace=*) workspace="${1#--workspace=}"; shift ;;
      -h|--help)
        cat <<'EOF' >&2
Usage: graph-run.sh status --namespace <ns> --run <run-id|latest> [--workspace <dir>]
EOF
        return 0
        ;;
      --) shift; break ;;
      -*) echo "Error: unknown option '$1'" >&2; return 1 ;;
      *)
        echo "Error: unexpected argument '$1'" >&2
        return 1
        ;;
    esac
  done

  if [[ -z "$workspace" ]]; then
    workspace="$(pwd)"
  fi

  if [[ -z "$namespace" ]]; then
    echo "Error: graph status requires --namespace <ns>" >&2
    return 1
  fi
  if [[ -z "$run_token" ]]; then
    echo "Error: graph status requires --run <run-id|latest>" >&2
    return 1
  fi

  local run_id
  if ! run_id="$(graph_state_resolve_run_id "$workspace" "$namespace" "$run_token")"; then
    echo "Error: could not resolve run selector '$run_token' for namespace '$namespace'" >&2
    return 1
  fi

  graph_status_run "$workspace" "$namespace" "$run_id"
}
