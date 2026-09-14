#!/usr/bin/env bash
# Graph status verb: read-only view of a live or completed graph run.
#
# graph_status_cli <--namespace <ns>> <--run <run-id|latest>> [--workspace <dir>]
#   [--details] [--mermaid]
#   Entry point from graph-run.sh.  Reads only the graph-runs directory so it is
#   safe to call against a live in-progress run.
#
# graph_status_run <workspace> <namespace> <run_id> [--details] [--mermaid]
#   Core implementation.  By default prints only the run summary (usage,
#   concurrency reductions) plus a table: node, type, runtime, state, unique
#   attempt count, duration. With --details, also prints verbose per-node and
#   per-attempt observability metadata (workspace mode, write scopes, gate
#   outcome, changeset hash, consensus voter provenance and dissent,
#   delegated runs, native subagent events) plus efficiency signals
#   (elapsed active/wait time, reliable usage or n/a, retry classification,
#   repeated-tool-call hints). --json includes the same efficiency fields.
#   With --mermaid, also prints a mermaid flowchart with a classDef per state
#   and live run-state classes applied per node.
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
if ! declare -F graph_events_read_lines >/dev/null 2>&1; then
  # shellcheck source=graph-events.sh
  source "$GRAPH_STATUS_SCRIPT_DIR/graph-events.sh"
fi
if ! declare -F graph_heartbeat_classify_run >/dev/null 2>&1; then
  # shellcheck source=graph-heartbeat.sh
  source "$GRAPH_STATUS_SCRIPT_DIR/graph-heartbeat.sh"
fi
if ! declare -F graph_operator_view_build >/dev/null 2>&1; then
  # shellcheck source=graph-operator-view.sh
  source "$GRAPH_STATUS_SCRIPT_DIR/graph-operator-view.sh"
fi

# _graph_status_now_epoch
# Current Unix epoch for live wait/active math. Honors GRAPH_STATUS_NOW_EPOCH,
# then GRAPH_HEARTBEAT_NOW_EPOCH, so tests can freeze time.
_graph_status_now_epoch() {
  if [[ -n "${GRAPH_STATUS_NOW_EPOCH:-}" && "${GRAPH_STATUS_NOW_EPOCH}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$GRAPH_STATUS_NOW_EPOCH"
    return 0
  fi
  if [[ -n "${GRAPH_HEARTBEAT_NOW_EPOCH:-}" && "${GRAPH_HEARTBEAT_NOW_EPOCH}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$GRAPH_HEARTBEAT_NOW_EPOCH"
    return 0
  fi
  date +%s
}

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

# _graph_status_interval_seconds <started_at> <finished_at>
# Print nonnegative elapsed seconds, or return 1 when timestamps are missing
# or unparseable.
_graph_status_interval_seconds() {
  local started="$1" finished="$2"
  if [[ -z "$started" || -z "$finished" ]]; then
    return 1
  fi
  local diff
  if [[ "${started:0:10}" == "${finished:0:10}" && "${started:11:8}" =~ ^[0-9:]+$ && "${finished:11:8}" =~ ^[0-9:]+$ ]]; then
    local sh sm ss fh fm fs
    sh="${started:11:2}"; sm="${started:14:2}"; ss="${started:17:2}"
    fh="${finished:11:2}"; fm="${finished:14:2}"; fs="${finished:17:2}"
    diff=$(( (10#$fh * 3600 + 10#$fm * 60 + 10#$fs) - (10#$sh * 3600 + 10#$sm * 60 + 10#$ss) ))
    [[ "$diff" -ge 0 ]] || diff=0
    printf '%s\n' "$diff"
    return 0
  fi
  local s f
  s="$(_graph_status_iso_to_epoch "$started")" || return 1
  f="$(_graph_status_iso_to_epoch "$finished")" || return 1
  diff=$(( f - s ))
  [[ "$diff" -ge 0 ]] || diff=0
  printf '%s\n' "$diff"
}

# _graph_status_seconds_fmt <seconds>
# Format a nonnegative integer as HH:MM:SS, or "-" when empty/unparseable.
_graph_status_seconds_fmt() {
  local sec="${1:-}"
  if [[ ! "$sec" =~ ^[0-9]+$ ]]; then
    printf '-'
    return 0
  fi
  local h m s
  h=$(( sec / 3600 ))
  m=$(( (sec % 3600) / 60 ))
  s=$(( sec % 60 ))
  printf '%02d:%02d:%02d' "$h" "$m" "$s"
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
    subagent_mode="$(jq -r --argjson idx "$i" '.attempts[$idx].nativeSubagents // .attempts[$idx].nativeSubagentMode // empty' "$node_file" 2>/dev/null)"
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
      [[ -n "$subagent_mode" ]] && printf ' nativeSubagents=%s' "$subagent_mode"
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
# entry itself) when it carries extended observability fields.
_graph_status_node_extra() {
  local node_file="$1" node_id="$2"
  [[ -f "$node_file" ]] || return 0
  jq -e 'has("workspaceMode") or has("workspacePath") or has("writeScopes") or has("frozenBase") or has("changesetHash") or has("conflictArtifact") or has("gateOutcome") or has("nativeSubagents") or has("nativeSubagentMode") or has("crossRuntimeMode") or has("integrationInputs") or has("usageSnapshot") or has("publishReadiness") or has("repairEpoch") or has("admissionSummary") or has("verificationResourceClasses")' "$node_file" >/dev/null 2>&1 || return 0
  local mode path scopes base baseline hash conflict outcome subagent_mode cross_mode integration usage publish repair_epoch admission verification_classes
  mode="$(jq -r '.workspaceMode // empty' "$node_file" 2>/dev/null)"
  path="$(jq -r '.workspacePath // empty' "$node_file" 2>/dev/null)"
  scopes="$(jq -r '.writeScopes // empty' "$node_file" 2>/dev/null)"
  base="$(jq -r '.frozenBase // empty' "$node_file" 2>/dev/null)"
  baseline="$(jq -r '.changesetBaseline // empty' "$node_file" 2>/dev/null)"
  hash="$(jq -r '.changesetHash // empty' "$node_file" 2>/dev/null)"
  conflict="$(jq -r '.conflictArtifact // empty' "$node_file" 2>/dev/null)"
  outcome="$(jq -r '.gateOutcome // empty' "$node_file" 2>/dev/null)"
  subagent_mode="$(jq -r '.nativeSubagents // .nativeSubagentMode // empty' "$node_file" 2>/dev/null)"
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
    [[ -n "$subagent_mode" ]] && printf ' nativeSubagents=%s' "$subagent_mode"
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

# _graph_status_delegated_runs <workspace> <namespace> <run_id> <node_id>
# Print durable delegated-run provenance as nested rows. Delegated runs are
# ledger children of the parent node, not peer nodes in the frozen DAG.
_graph_status_delegated_runs() {
  local workspace="$1" namespace="$2" run_id="$3" node_id="$4"
  local root dir
  root="$(graph_delegation_ledger_root "$workspace" 2>/dev/null)" || return 0
  [[ -d "$root" ]] || return 0
  for dir in "$root"/delegated-run-*; do
    [[ -d "$dir" && -f "$dir/request.json" && -f "$dir/status.json" ]] || continue
    local did runtime role state
    did="$(jq -r '.delegatedRunId // empty' "$dir/request.json" 2>/dev/null)"
    runtime="$(jq -r '.runtime // empty' "$dir/request.json" 2>/dev/null)"
    role="$(jq -r '.role // empty' "$dir/request.json" 2>/dev/null)"
    state="$(jq -r '.status // unknown' "$dir/status.json" 2>/dev/null)"
    printf '    delegated run=%-30s runtime=%-10s role=%-14s state=%s\n' \
      "${did:-?}" "${runtime:-?}" "${role:-none}" "${state:-?}"
  done
}

# _graph_status_read_events_safe <run-dir>
# Status reads <run-dir>/events.jsonl only through graph_events_read_lines or
# graph_events_read_json. A missing journal or a single crash-truncated tail
# is nonfatal; a malformed interior line produces a concise warning and returns
# an empty result so callers continue without mutating the journal or ledger.
_graph_status_read_events_safe() {
  local run_dir="$1" events=""
  if [[ -z "$run_dir" ]]; then
    return 0
  fi
  if events="$(graph_events_read_lines "$run_dir" 2>/dev/null)"; then
    if [[ -n "$events" ]]; then
      printf '%s\n' "$events"
    fi
    return 0
  fi
  echo "Warning: event journal has a malformed interior line; event-derived status details omitted" >&2
  return 0
}

# _graph_status_subagent_events <workspace> <namespace> <run_id> <node_id> [events]
# Print best-effort native subagent events recorded in the run event journal.
# An optional fifth argument supplies pre-read event lines so the journal is
# read only once per status invocation.
_graph_status_subagent_events() {
  local workspace="$1" namespace="$2" run_id="$3" node_id="$4" events="${5:-}"
  local run_dir
  run_dir="$(graph_state_run_dir "$workspace" "$namespace" "$run_id" 2>/dev/null)" || return 0
  if [[ -z "$events" ]]; then
    events="$(_graph_status_read_events_safe "$run_dir")"
  fi
  [[ -n "$events" ]] || return 0
  local filtered
  filtered="$(printf '%s\n' "$events" | jq -r --arg node "$node_id" 'select(.nodeId == $node and (.event | startswith("native-subagent"))) | "    native-subagent event=\(.event) \(.details // {})"')"
  [[ -n "$filtered" ]] || return 0
  printf '%s\n' "$filtered"
}

# _graph_status_usage_aggregate <nodes-dir> [workspace]
# Parent summaries are cumulative snapshots, so retain only the latest
# snapshot per durable node. Delegated runs are separate durable attempts: sum
# their status usage once per ledger record, never through the parent.
_graph_status_usage_aggregate() {
  local nodes_dir="$1" workspace="${2:-}" child_files=()
  [[ -d "$nodes_dir" ]] || return 0
  local node_usage child_usage
  node_usage="$(jq -cs '
    def add_numbers: reduce .[] as $o ({}; reduce ($o | to_entries[]? | select(.value | type == "number")) as $e (. ; .[$e.key] = ((.[$e.key] // 0) + $e.value)));
    def reliable:
      (.usageReliable == true) or (.usageReliable == "true")
      or ((.usageSnapshot.reliability // .usage.reliability // "") == "authoritative");
    [ .[]
      | (.attempts[-1] // .) as $a
      | select($a | reliable)
      | ($a.usageSnapshot // $a.usage)
      | select(type == "object")
    ] | add_numbers
  ' "$nodes_dir"/*.json 2>/dev/null)" || node_usage='{}'
  # Delegated-run usage lives in the flat state-root ledger, not under the node.
  local _delegated_root
  _delegated_root="$(graph_delegation_ledger_root "$workspace" 2>/dev/null || true)"
  if [[ -n "$_delegated_root" ]]; then
    for child in "$_delegated_root"/delegated-run-*/status.json; do
      [[ -f "$child" ]] && child_files+=("$child")
    done
  fi
  if [[ "${#child_files[@]}" -gt 0 ]]; then
    child_usage="$(jq -cs '
      def add_numbers: reduce .[] as $o ({}; reduce ($o | to_entries[]? | select(.value | type == "number")) as $e (. ; .[$e.key] = ((.[$e.key] // 0) + $e.value)));
      [ .[] | .usage? | select(type == "object") ] | add_numbers
    ' "${child_files[@]}" 2>/dev/null)" || child_usage='{}'
  else
    child_usage='{}'
  fi
  # An empty aggregate means usage was never recorded, not that zero tokens
  # were spent; show that distinction explicitly instead of an empty object.
  [[ "$node_usage" == "{}" ]] && node_usage="n/a"
  [[ "$child_usage" == "{}" ]] && child_usage="n/a"
  printf '  usage parent=%s delegated-runs=%s\n' "$node_usage" "$child_usage"
  return 0
}

# _graph_status_concurrency_reductions <run-dir> [events]
# Explain actual admission reductions using the append-only event journal.
# An optional second argument supplies pre-read event lines so the journal is
# read only once per status invocation.
_graph_status_concurrency_reductions() {
  local run_dir="$1" events="${2:-}"
  [[ -d "$run_dir" ]] || return 0
  if [[ -z "$events" ]]; then
    events="$(_graph_status_read_events_safe "$run_dir")"
  fi
  [[ -n "$events" ]] || return 0
  local reductions
  reductions="$(printf '%s\n' "$events" | jq -r '
    select(.event == "admission") |
    if .details.workKind == "broker-child" and .details.decision == "denied" then "broker-capacity"
    elif .details.sameRuntimeParallelSafe == false then "runtime-overlay"
    elif ((.details.reason // "") | test("verification|resource"; "i")) then "verification-resource-class"
    else empty end
  ' | sort -u | tr "\n" "," | sed 's/,$//')"
  if [[ -n "$reductions" ]]; then
    printf '  concurrency reduced-by=%s\n' "$reductions"
  fi
  # No reductions to report is not a failure: an empty journal, or one with no
  # reduction-worthy events, must never abort the caller under errexit.
  return 0
}

# _graph_status_concurrency_reductions_json <events>
# Return a JSON array of reduction reasons from pre-read event lines.
_graph_status_concurrency_reductions_json() {
  local events="${1:-}"
  if [[ -z "$events" ]]; then
    printf '[]\n'
    return 0
  fi
  printf '%s\n' "$events" | jq -r '
    select(.event == "admission") |
    if .details.workKind == "broker-child" and .details.decision == "denied" then "broker-capacity"
    elif .details.sameRuntimeParallelSafe == false then "runtime-overlay"
    elif ((.details.reason // "") | test("verification|resource"; "i")) then "verification-resource-class"
    else empty end
  ' | sort -u | jq -R . | jq -s . || printf '[]\n'
}

# _graph_status_usage_reliable <attempt-or-node-json>
# True when the record carries authoritative usage. Missing or estimated
# snapshots are not treated as reliable.
_graph_status_usage_reliable() {
  local rec="${1:-}"
  [[ -n "$rec" ]] || return 1
  printf '%s' "$rec" | jq -e '
    (.usageReliable == true) or (.usageReliable == "true")
    or ((.usageSnapshot.reliability // .usage.reliability // "") == "authoritative")
  ' >/dev/null 2>&1
}

# _graph_status_tool_hints_from_usage <usage-json>
# Build a JSON array of repeated-tool-call hint strings from a usage snapshot.
# jq-only; does not invoke python3.
_graph_status_tool_hints_from_usage() {
  local usage="${1:-}"
  if [[ -z "$usage" ]] || ! printf '%s' "$usage" | jq -e 'type == "object"' >/dev/null 2>&1; then
    printf '[]\n'
    return 0
  fi
  printf '%s' "$usage" | jq -c '
    def as_int(v):
      if (v | type) == "number" then v
      elif (v | type) == "string" and (v | test("^[0-9]+$")) then (v | tonumber)
      else 0 end;
    def hint_line:
      (.optimizationHintLine // .optimization_hint_line // .efficiencyHint // .efficiency_hint // "")
      | tostring
      | sub("^HINT:[[:space:]]*"; "")
      | select(. != "");
    . as $u
    | ($u.usage // $u) as $src
    | [
        (as_int($src.adjacent_duplicate_tool_calls) as $n
          | if $n > 0 then "\($n) adjacent duplicate tool call(s)" else empty end),
        (as_int($src.repeated_read_extra_calls) as $n
          | if $n > 0 then "\($n) repeated read(s)" else empty end),
        (as_int($src.repeated_read_targets) as $n
          | if $n > 0 and as_int($src.repeated_read_extra_calls) == 0 then
              "\($n) repeated read target(s)"
            else empty end),
        (as_int($src.repeated_native_read_like) as $n
          | if $n > 0 then "\($n) consecutive native read/search pair(s)" else empty end),
        (hint_line)
      ]
  ' 2>/dev/null || printf '[]\n'
}

# _graph_status_efficiency_json <node_file> [run_dir]
# Read-only efficiency object for --details/--json: unique attempts, elapsed
# active/wait seconds, reliable usage or "n/a", latest retry classification,
# and repeated-tool-call hints. Missing or estimated usage is "n/a".
_graph_status_efficiency_json() {
  local node_file="$1" run_dir="${2:-}"
  local empty
  empty='{"attempts":0,"activeSeconds":0,"waitSeconds":0,"usage":"n/a","retryClassification":null,"repeatedToolCallHints":[]}'
  if [[ ! -f "$node_file" ]]; then
    printf '%s\n' "$empty"
    return 0
  fi

  local meta now_epoch
  now_epoch="$(_graph_status_now_epoch)"
  meta="$(jq -c '
    def unique_attempts:
      reduce (.attempts // [])[] as $a ({};
        (($a.attemptId // "") | if . == "" then "_" else . end) as $id
        | .[$id] = ((.[$id] // {}) + $a)
      ) | [.[]]
      | sort_by(.startedAt // "");
    . as $n
    | unique_attempts as $atts
    | {
        attempts: ($atts | length),
        status: ($n.status // "pending"),
        firstStartedAt: ([$atts[].startedAt // empty] | map(select(. != "")) | sort | .[0] // ""),
        lastFinishedAt: ([$atts[].finishedAt // empty] | map(select(. != "")) | sort | .[-1] // ""),
        lastStartedAt: ([$atts[].startedAt // empty] | map(select(. != "")) | sort | .[-1] // ""),
        budgetActiveSeconds: ($n.budget.activeSeconds // null),
        budgetActiveStartedAt: ($n.budget.activeStartedAt // ""),
        retryClassification: (
          ($atts[-1].retryClassification // $n.retryClassification // "")
          | if . == "" then
              (($atts[-1].reason // $n.reason // "") | capture("retry-wait:(?<c>[^[:space:]]+)")? | .c // "")
            else . end
        ),
        intervals: [ $atts[] | {
          startedAt: (.startedAt // ""),
          finishedAt: (.finishedAt // ""),
          usageReliable: (.usageReliable // false),
          usage: (.usageSnapshot // .usage // null),
          usagePath: (.logPaths.usage // "")
        } ]
      }
  ' "$node_file" 2>/dev/null)" || meta=""
  if [[ -z "$meta" ]] || ! printf '%s' "$meta" | jq -e . >/dev/null 2>&1; then
    printf '%s\n' "$empty"
    return 0
  fi

  local attempts_count status first_started last_finished last_started
  local budget_sec budget_started retry_class
  attempts_count="$(printf '%s' "$meta" | jq -r '.attempts // 0')"
  status="$(printf '%s' "$meta" | jq -r '.status // "pending"')"
  first_started="$(printf '%s' "$meta" | jq -r '.firstStartedAt // empty')"
  last_finished="$(printf '%s' "$meta" | jq -r '.lastFinishedAt // empty')"
  last_started="$(printf '%s' "$meta" | jq -r '.lastStartedAt // empty')"
  budget_sec="$(printf '%s' "$meta" | jq -r '.budgetActiveSeconds // empty')"
  budget_started="$(printf '%s' "$meta" | jq -r '.budgetActiveStartedAt // empty')"
  retry_class="$(printf '%s' "$meta" | jq -r '.retryClassification // empty')"
  [[ "$attempts_count" =~ ^[0-9]+$ ]] || attempts_count=0

  local active=0 wait=0
  if [[ "$budget_sec" =~ ^[0-9]+$ ]]; then
    active="$budget_sec"
    if [[ -n "$budget_started" ]]; then
      local open_elapsed
      open_elapsed="$(_graph_status_interval_seconds "$budget_started" "$(_graph_status_epoch_to_iso "$now_epoch")")" \
        || open_elapsed=""
      if [[ "$open_elapsed" =~ ^[0-9]+$ ]]; then
        active=$((active + open_elapsed))
      fi
    fi
  else
    local i count started finished elapsed
    count="$(printf '%s' "$meta" | jq '.intervals | length')"
    i=0
    while [[ "$i" -lt "$count" ]]; do
      started="$(printf '%s' "$meta" | jq -r --argjson idx "$i" '.intervals[$idx].startedAt // empty')"
      finished="$(printf '%s' "$meta" | jq -r --argjson idx "$i" '.intervals[$idx].finishedAt // empty')"
      if [[ -z "$finished" ]]; then
        finished="$(_graph_status_epoch_to_iso "$now_epoch")"
      fi
      elapsed="$(_graph_status_interval_seconds "$started" "$finished")" || elapsed=0
      [[ "$elapsed" =~ ^[0-9]+$ ]] || elapsed=0
      active=$((active + elapsed))
      i=$((i + 1))
    done
  fi

  local wall_end="$last_finished" wall=0
  case "$status" in
    running|retry-wait|awaiting-operator|awaiting-ack|ready)
      wall_end="$(_graph_status_epoch_to_iso "$now_epoch")"
      ;;
  esac
  if [[ -z "$wall_end" && -n "$last_started" ]]; then
    wall_end="$(_graph_status_epoch_to_iso "$now_epoch")"
  fi
  wall="$(_graph_status_interval_seconds "$first_started" "$wall_end")" || wall=0
  [[ "$wall" =~ ^[0-9]+$ ]] || wall=0
  wait=$((wall - active))
  [[ "$wait" -ge 0 ]] || wait=0

  local usage_json="n/a" hints='[]' i count rec usage_blob path_usage
  count="$(printf '%s' "$meta" | jq '.intervals | length')"
  i=0
  while [[ "$i" -lt "$count" ]]; do
    rec="$(printf '%s' "$meta" | jq -c --argjson idx "$i" '.intervals[$idx]')"
    usage_blob="$(printf '%s' "$rec" | jq -c '.usage // empty')"
    if [[ "$usage_blob" == "null" || -z "$usage_blob" ]]; then
      usage_blob=""
    fi
    if [[ -n "$run_dir" ]]; then
      local usage_path
      usage_path="$(printf '%s' "$rec" | jq -r '.usagePath // empty')"
      if [[ -n "$usage_path" && -f "$run_dir/$usage_path" ]]; then
        path_usage="$(jq -c . "$run_dir/$usage_path" 2>/dev/null || true)"
        if [[ -n "$path_usage" ]]; then
          if [[ -n "$usage_blob" ]]; then
            usage_blob="$(jq -cn --argjson a "$usage_blob" --argjson b "$path_usage" '$a + $b')"
          else
            usage_blob="$path_usage"
          fi
        fi
      fi
    fi
    if [[ -n "$usage_blob" ]]; then
      local more
      more="$(_graph_status_tool_hints_from_usage "$usage_blob")"
      hints="$(jq -cn --argjson a "$hints" --argjson b "$more" '$a + $b | unique')"
    fi
    if _graph_status_usage_reliable "$rec" && [[ -n "$usage_blob" ]]; then
      local piece
      piece="$(printf '%s' "$usage_blob" | jq -c '
        def pick_num(obj; keys):
          first(
            keys[] as $k
            | obj[$k]
            | select(. != null)
            | if type == "number" then .
              elif type == "string" and test("^-?[0-9]+([.][0-9]+)?$") then tonumber
              else empty end
          ) // null;
        (if type == "object" and (.usage | type) == "object" then .usage else . end) as $src
        | {
            inputTokens: pick_num($src; ["inputTokens","input_tokens","promptTokens","prompt_tokens"]),
            outputTokens: pick_num($src; ["outputTokens","output_tokens","completionTokens","completion_tokens"]),
            cacheReadTokens: pick_num($src; ["cacheReadTokens","cache_read_tokens","cache_read_input_tokens"]),
            cacheWriteTokens: pick_num($src; ["cacheWriteTokens","cache_write_tokens","cache_creation_input_tokens"]),
            reliability: "authoritative"
          }
        | with_entries(select(.value != null))
      ' 2>/dev/null || true)"
      if [[ -n "$piece" ]] && printf '%s' "$piece" | jq -e 'type == "object"' >/dev/null 2>&1; then
        if [[ "$usage_json" == "n/a" ]]; then
          usage_json="$piece"
        else
          usage_json="$(jq -cn --argjson a "$usage_json" --argjson b "$piece" '
            def add_num(x; y):
              if (x | type) == "number" and (y | type) == "number" then x + y
              elif (x | type) == "number" then x
              elif (y | type) == "number" then y
              else null end;
            {
              inputTokens: add_num($a.inputTokens; $b.inputTokens),
              outputTokens: add_num($a.outputTokens; $b.outputTokens),
              cacheReadTokens: add_num($a.cacheReadTokens; $b.cacheReadTokens),
              cacheWriteTokens: add_num($a.cacheWriteTokens; $b.cacheWriteTokens),
              reliability: "authoritative"
            } | with_entries(select(.value != null))
          ')"
        fi
      fi
    fi
    i=$((i + 1))
  done

  if [[ -z "$retry_class" ]]; then
    retry_class="null"
  else
    retry_class="$(jq -cn --arg c "$retry_class" '$c')"
  fi
  if [[ "$usage_json" == "n/a" ]]; then
    usage_json='"n/a"'
  fi
  [[ -n "$hints" ]] || hints='[]'

  jq -nc \
    --argjson attempts "$attempts_count" \
    --argjson active "$active" \
    --argjson wait "$wait" \
    --argjson usage "$usage_json" \
    --argjson retry "$retry_class" \
    --argjson hints "$hints" \
    '{
       attempts: $attempts,
       activeSeconds: $active,
       waitSeconds: $wait,
       usage: $usage,
       retryClassification: $retry,
       repeatedToolCallHints: $hints
     }'
}

# _graph_status_epoch_to_iso <epoch>
# Best-effort UTC ISO-8601 for live-end math. Returns empty on failure.
_graph_status_epoch_to_iso() {
  local epoch="$1"
  [[ "$epoch" =~ ^[0-9]+$ ]] || return 1
  if date -u -d "@$epoch" +"%Y-%m-%dT%H:%M:%SZ" >/dev/null 2>&1; then
    date -u -d "@$epoch" +"%Y-%m-%dT%H:%M:%SZ"
    return 0
  fi
  if date -u -r "$epoch" +"%Y-%m-%dT%H:%M:%SZ" >/dev/null 2>&1; then
    date -u -r "$epoch" +"%Y-%m-%dT%H:%M:%SZ"
    return 0
  fi
  return 1
}

# _graph_status_print_efficiency <node_id> <efficiency_json>
# Details-only efficiency line. Default status must not call this.
_graph_status_print_efficiency() {
  local node_id="$1" eff="${2:-}"
  [[ -n "$eff" ]] || return 0
  printf '%s' "$eff" | jq -e . >/dev/null 2>&1 || return 0
  local attempts active wait usage retry hints
  attempts="$(printf '%s' "$eff" | jq -r '.attempts // 0')"
  active="$(_graph_status_seconds_fmt "$(printf '%s' "$eff" | jq -r '.activeSeconds // 0')")"
  wait="$(_graph_status_seconds_fmt "$(printf '%s' "$eff" | jq -r '.waitSeconds // 0')")"
  usage="$(printf '%s' "$eff" | jq -c '.usage')"
  retry="$(printf '%s' "$eff" | jq -r '.retryClassification // "n/a"')"
  [[ -n "$retry" && "$retry" != "null" ]] || retry="n/a"
  hints="$(printf '%s' "$eff" | jq -r '.repeatedToolCallHints | join("; ")')"
  [[ -n "$hints" ]] || hints="n/a"
  printf '  %s efficiency: attempts=%s active=%s wait=%s usage=%s retry=%s\n' \
    "$node_id" "$attempts" "$active" "$wait" "$usage" "$retry"
  printf '    repeated-tool-calls: %s\n' "$hints"
}

# _graph_status_json_node <id> <type> <runtime> <state> <attempts> <duration> <mode> <base> <scopes> [efficiency_json]
# Format one node table row as a JSON object. Optional efficiency fields are
# merged for --json without changing the default text table.
_graph_status_json_node() {
  local eff="${10:-}"
  if [[ -z "$eff" ]] || ! printf '%s' "$eff" | jq -e . >/dev/null 2>&1; then
    eff='{}'
  fi
  jq -n \
    --arg id "$1" --arg type "$2" --arg runtime "${3:--}" --arg state "$4" \
    --argjson attempts "${5:-0}" --arg duration "${6:--}" --arg mode "${7:--}" \
    --arg base "${8:--}" --arg scopes "${9:--}" \
    --argjson eff "$eff" \
    '{id: $id, type: $type, runtime: $runtime, state: $state, attempts: $attempts, duration: $duration, mode: $mode, base: $base, scopes: $scopes} + $eff'
}

# graph_status_run <workspace> <namespace> <run_id> [--details] [--mermaid] [--json]
#
# Core read-only status display.  Never writes to the graph-runs directory.
#
# By default, output is the run summary plus the node table only. Verbose
# per-node/per-attempt metadata (workspace mode, write scopes, gate outcome,
# changeset hash, consensus voter provenance, delegated runs, native
# subagent events, efficiency signals, and similar observability detail) is
# printed only with --details. The mermaid flowchart is printed only with
# --mermaid. --json emits a structured JSON object including owner-health,
# run metadata, the node table, and efficiency fields; it is mutually
# exclusive with text formatting flags.
graph_status_run() {
  local workspace="$1" namespace="$2" run_id="$3"
  if [[ $# -ge 3 ]]; then
    shift 3
  else
    shift $#
  fi

  local show_details=0 show_mermaid=0 show_json=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --details) show_details=1; shift ;;
      --mermaid) show_mermaid=1; shift ;;
      --json) show_json=1; shift ;;
      *) shift ;;
    esac
  done

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

  local run_status started_at plan_path owner_health
  run_status="$(jq -r '.status // "unknown"' "$run_file")"
  started_at="$(jq -r '.startedAt // ""' "$run_file")"
  plan_path="$(jq -r '.planPath // ""' "$run_file")"
  owner_health="$(graph_heartbeat_classify_run "$workspace" "$namespace" "$run_id")" || owner_health="unknown"
  case "$run_status" in
    succeeded|failed|cancelled) owner_health="terminal" ;;
  esac

  local operator_view_json="" operator_default=0
  operator_view_json="$(graph_operator_view_build "$workspace" "$namespace" "$run_id" 2>/dev/null)" || operator_view_json=""

  if [[ "$show_json" -eq 0 && "$show_details" -eq 0 && -n "$operator_view_json" ]]; then
    graph_operator_view_format_text "$operator_view_json"
    operator_default=1
    if [[ "$show_mermaid" -eq 0 ]]; then
      return 0
    fi
    printf '\n'
  fi

  if [[ "$show_json" -eq 0 && "$operator_default" -eq 0 ]]; then
    printf '# graph status  run=%s  namespace=%s  status=%s  owner-health=%s\n' \
      "$run_id" "$namespace" "$run_status" "$owner_health"
    if [[ -n "$plan_path" ]]; then
      printf '# plan: %s\n' "$plan_path"
    fi
    if [[ -n "$started_at" ]]; then
      printf '# started: %s\n' "$started_at"
    fi
    printf '\n'
  fi

  local run_dir events_jsonl
  run_dir="$(dirname "$run_file")"
  events_jsonl="$(_graph_status_read_events_safe "$run_dir")"

  if [[ "$show_json" -eq 0 ]]; then
    _graph_status_usage_aggregate "$nodes_dir" "$workspace"
    _graph_status_concurrency_reductions "$run_dir" "$events_jsonl"
    printf '\n'

    # Table header.
    _graph_status_table_row "NODE" "TYPE" "RUNTIME" "STATE" "ATTEMPTS" "DURATION" "MODE" "BASE" "SCOPES"
    printf '%s\n' \
      "------------------------------------------------------------------------------------------------------------------------------------------------"
  fi

  # Read node ids from the frozen graph in graph order.
  local node_ids
  node_ids="$(jq -r '.nodes[].id // empty' "$graph_file" 2>/dev/null)"

  # Build mermaid node-state lines as we iterate to avoid a second pass.
  local mermaid_nodes="" mermaid_definitions=""
  # Build JSON node rows for --json output.
  local nodes_jsonl=""

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
      # Attempt count is the number of unique attemptId values, not the raw
      # attempts[] record count: the append-only ledger records one entry per
      # transition (running, then terminal), so a single attempt can occupy
      # two records that must collapse to one for display.
      node_fields="$(jq -r '
        (.writeScopes // .attempts[-1].writeScopes // []) as $scopes |
        [(.status // "pending"), ((.attempts // []) | map(.attemptId) | unique | length), (.attempts[-1].startedAt // ""), (.attempts[-1].finishedAt // ""), (.workspaceMode // .attempts[-1].workspaceMode // "-"), (.frozenBase // .attempts[-1].frozenBase // "-"), (if ($scopes | length) == 0 then "-" elif ($scopes | length) == 1 then $scopes[0] else ($scopes[0] + " +" + (($scopes | length) - 1 | tostring)) end), (if (has("workspaceMode") or has("workspacePath") or has("writeScopes") or has("frozenBase") or has("changesetHash") or has("conflictArtifact") or has("gateOutcome") or has("nativeSubagents") or has("nativeSubagentMode") or has("crossRuntimeMode") or has("integrationInputs") or has("usageSnapshot") or has("publishReadiness") or has("repairEpoch") or has("admissionSummary") or has("verificationResourceClasses")) then "yes" else "no" end)] | @tsv
      ' "$node_file" 2>/dev/null)"
      local last_started last_finished
      local has_observability="no"
      IFS=$'\t' read -r node_state attempts_count last_started last_finished mode base scopes has_observability <<< "$node_fields"
      duration="$(_graph_status_duration_fmt "$last_started" "$last_finished")"
      base="${base:0:16}"
    fi

    local eff_json
    eff_json="$(_graph_status_efficiency_json "$node_file" "$run_dir")"

    if [[ "$show_json" -eq 0 && "$operator_default" -eq 0 ]]; then
      _graph_status_table_row "$nid" "$ntype" "${runtime:--}" "$node_state" \
        "$attempts_count" "$duration" "$mode" "$base" "$scopes"

      if [[ "$show_details" -eq 1 ]]; then
        # Print per-node metadata (workspace, scopes, gate outcome, etc.).
        if [[ "${has_observability:-no}" == "yes" ]]; then
          _graph_status_node_extra "$node_file" "$nid"
        fi

        # For consensus-barrier (join) nodes, show per-voter provenance.
        if [[ "$ntype" == "consensus-barrier" ]]; then
          _graph_status_consensus_voters "$workspace" "$namespace" "$nid"
        fi

        # Brokered children are durable ledger children, not DAG peer nodes.
        if [[ "$ntype" == "agent" || "$ntype" == "stage" ]]; then
          _graph_status_delegated_runs "$workspace" "$namespace" "$run_id" "$nid"
        fi

        # Best-effort native subagent events (logged when the runtime supports them).
        _graph_status_subagent_events "$workspace" "$namespace" "$run_id" "$nid" "$events_jsonl"

        # Efficiency signals stay out of the default table.
        _graph_status_print_efficiency "$nid" "$eff_json"
      fi
    fi

    # Accumulate JSON node rows regardless of output mode.
    if [[ -z "$nodes_jsonl" ]]; then
      nodes_jsonl="$(_graph_status_json_node "$nid" "$ntype" "${runtime:--}" "$node_state" "$attempts_count" "$duration" "$mode" "$base" "$scopes" "$eff_json")"
    else
      nodes_jsonl="${nodes_jsonl}"$'\n'"$(_graph_status_json_node "$nid" "$ntype" "${runtime:--}" "$node_state" "$attempts_count" "$duration" "$mode" "$base" "$scopes" "$eff_json")"
    fi

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

  if [[ "$show_json" -eq 1 ]]; then
    local reductions_json nodes_array_json
    reductions_json="$(_graph_status_concurrency_reductions_json "$events_jsonl")"
    if [[ -n "$nodes_jsonl" ]]; then
      nodes_array_json="$(printf '%s\n' "$nodes_jsonl" | jq -s .)"
    else
      nodes_array_json='[]'
    fi
    printf '%s\n' "$nodes_array_json" | jq \
      --arg runId "$run_id" --arg namespace "$namespace" --arg status "$run_status" \
      --arg ownerHealth "$owner_health" --arg startedAt "$started_at" --arg planPath "$plan_path" \
      --argjson reductions "$reductions_json" \
      --argjson operatorView "${operator_view_json:-null}" \
      '
        def add_num(x; y):
          if (x | type) == "number" and (y | type) == "number" then x + y
          elif (x | type) == "number" then x
          elif (y | type) == "number" then y
          else null end;
        def usage_sum:
          reduce (.[] | .usage | select(type == "object")) as $u
            ({};
              {
                inputTokens: add_num(.inputTokens; $u.inputTokens),
                outputTokens: add_num(.outputTokens; $u.outputTokens),
                cacheReadTokens: add_num(.cacheReadTokens; $u.cacheReadTokens),
                cacheWriteTokens: add_num(.cacheWriteTokens; $u.cacheWriteTokens),
                reliability: "authoritative"
              }
            )
          | with_entries(select(.value != null))
          | if . == {} or . == {"reliability":"authoritative"} then "n/a" else . end;
        . as $nodes
        | {
            schema: (if $operatorView == null then null else $operatorView.schema end),
            schemaVersion: (if $operatorView == null then null else $operatorView.schemaVersion end),
            runId: $runId,
            namespace: $namespace,
            status: $status,
            ownerHealth: $ownerHealth,
            startedAt: $startedAt,
            planPath: $planPath,
            run: (if $operatorView == null then null else $operatorView.run end),
            attention: (if $operatorView == null then [] else $operatorView.attention end),
            active: (if $operatorView == null then [] else $operatorView.active end),
            completed: (if $operatorView == null then null else $operatorView.completed end),
            pending: (if $operatorView == null then null else $operatorView.pending end),
            nextActions: (if $operatorView == null then [] else $operatorView.nextActions end),
            concurrencyReductions: $reductions,
            efficiency: {
              attempts: ([ $nodes[].attempts // 0 ] | add // 0),
              activeSeconds: ([ $nodes[].activeSeconds // 0 ] | add // 0),
              waitSeconds: ([ $nodes[].waitSeconds // 0 ] | add // 0),
              usage: ($nodes | usage_sum),
              retryClassifications: ([ $nodes[].retryClassification | select(. != null and . != "") ] | unique),
              repeatedToolCallHints: ([ $nodes[].repeatedToolCallHints[]? ] | unique)
            },
            nodes: $nodes
          }
      '
    return 0
  fi

  if [[ "$show_mermaid" -ne 1 ]]; then
    return 0
  fi

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
  # responsive while a run is executing. Keep the alternate construction below
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
#   [--workspace <dir>] [--details] [--mermaid] [--json]
#
# Entry point called by graph-run.sh.  Resolves the run selector and delegates
# to graph_status_run.  Reads only the graph-runs directory.  By default,
# prints only the run summary and node table; --details adds verbose
# per-node/per-attempt observability metadata, --mermaid adds the
# flowchart view, and --json emits a structured JSON object.
graph_status_cli() {
  local namespace="" run_token="" workspace="" details=0 mermaid=0 json=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --namespace) namespace="$2"; shift 2 ;;
      --namespace=*) namespace="${1#--namespace=}"; shift ;;
      --run) run_token="$2"; shift 2 ;;
      --run=*) run_token="${1#--run=}"; shift ;;
      --workspace) workspace="$2"; shift 2 ;;
      --workspace=*) workspace="${1#--workspace=}"; shift ;;
      --details) details=1; shift ;;
      --mermaid) mermaid=1; shift ;;
      --json) json=1; shift ;;
      -h|--help)
        cat <<'EOF' >&2
Usage: graph-run.sh status --namespace <ns> --run <run-id|latest> [--workspace <dir>] [--details] [--mermaid] [--json]
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

  # Build the optional flag list without relying on possibly-empty array
  # expansion under nounset (kept bash 3.2 safe, matching the rest of this
  # file).
  local extra_args=()
  if [[ "$details" -eq 1 ]]; then
    extra_args[${#extra_args[@]}]="--details"
  fi
  if [[ "$mermaid" -eq 1 ]]; then
    extra_args[${#extra_args[@]}]="--mermaid"
  fi
  if [[ "$json" -eq 1 ]]; then
    extra_args[${#extra_args[@]}]="--json"
  fi

  graph_status_run "$workspace" "$namespace" "$run_id" ${extra_args[@]+"${extra_args[@]}"}
}
