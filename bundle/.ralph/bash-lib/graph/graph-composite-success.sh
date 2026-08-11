#!/usr/bin/env bash
# Composite success contract for durable graph nodes.
#
# A StageOutcomeReport is necessary but deliberately insufficient evidence for
# a graph node success.  This library records the complete scheduler-owned
# acceptance decision and revalidates its input fingerprint during resume.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then echo "This file is meant to be sourced, not executed." >&2; exit 1; fi
if [[ -n "${GRAPH_COMPOSITE_SUCCESS_LOADED:-}" ]]; then return 0; fi
GRAPH_COMPOSITE_SUCCESS_LOADED=1
_GRAPH_COMPOSITE_SUCCESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F graph_delegation_completion_gate >/dev/null 2>&1; then
  source "$_GRAPH_COMPOSITE_SUCCESS_DIR/graph-delegation-completion.sh"
fi
if ! declare -F get_next_todo >/dev/null 2>&1; then
  source "$_GRAPH_COMPOSITE_SUCCESS_DIR/../plan-todo.sh"
fi

graph_composite_success_sha256_file() {
  local path="$1"
  [[ -f "$path" ]] || return 1
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$path" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$path" | awk '{print $1}'
  else openssl dgst -sha256 "$path" | awk '{print $NF}'; fi
}

graph_composite_success_path() {
  local state_root="$1" namespace="$2" node_id="$3" attempt_id="$4" safe
  safe="$(printf '%s' "$node_id" | sed 's/[^A-Za-z0-9._-]/_/g')"
  printf '%s/artifacts/%s/composite-success/%s/%s.json\n' "$state_root" "$namespace" "$safe" "$attempt_id"
}

_graph_composite_success_stage() {
  jq -c --arg id "$2" '.nodes[] | select(.id == $id) | .stage' "$1" 2>/dev/null
}

# Stable fingerprint for exactly the inputs that can make a retained success
# unsafe.  Output and changeset hashes are included so a removed or replaced
# handoff cannot be silently adopted on resume.
graph_composite_success_fingerprint() {
  local graph="$1" run_file="$2" node_id="$3" state_root="$4" namespace="$5" changeset="$6"
  local stage inputs profile policy workspace base records='[]' declared path required resolved digest
  stage="$(_graph_composite_success_stage "$graph" "$node_id")" || return 1
  [[ -n "$stage" ]] || return 1
  inputs="$(printf '%s' "$stage" | jq -c '.inputArtifacts // []')" || return 1
  while IFS=$'\t' read -r declared required || [[ -n "$declared" ]]; do
    [[ -n "$declared" ]] || continue
    # Graph exchange paths are the canonical handoff location.  A missing
    # optional artifact remains part of the fingerprint as a deliberate null.
    resolved="$state_root/artifacts/$namespace/exchange/$declared"
    digest="missing"
    [[ -f "$resolved" ]] && digest="$(graph_composite_success_sha256_file "$resolved" 2>/dev/null || echo unreadable)"
    records="$(jq -c --arg p "$declared" --arg h "$digest" '. + [{path:$p,sha256:$h}]' <<<"$records")" || return 1
  done < <(printf '%s' "$inputs" | jq -r '.[]? | if type == "string" then [., true] else [.path, (.required // true)] end | @tsv')
  profile="$(printf '%s' "$stage" | jq -r '.verificationProfile // empty')"
  policy="$(printf '%s' "$stage" | jq -c '.delegation // {}')"
  workspace="$(printf '%s' "$stage" | jq -c '{workspaceMode:(.workspaceMode // "shared"),setupProfile:(.setupProfile // "")}')"
  base="$(jq -c '{sourceBase:(.sourceBase // {}),workspaceConfigSha:(.workspaceManager.configSha // "")}' "$run_file" 2>/dev/null)" || return 1
  jq -cn --argjson inputs "$records" --arg profile "$profile" --argjson profiles "$(jq -c '.verificationProfiles // []' "$graph")" \
    --argjson policy "$policy" --argjson workspace "$workspace" --argjson base "$base" \
    --arg changeset "${changeset:-}" \
    '{inputs:$inputs, verificationProfile:$profile,
      verificationProfiles:$profiles, delegationPolicy:$policy, workspacePolicy:$workspace,
      runBase:$base, changesetPath:$changeset}'
}

# graph_composite_success_validate <report> <graph> <run-file> <node> <run>
#   <attempt> <node-workspace> <state-root> <namespace> <plan> <changeset>
# On success writes an atomically durable evidence record.  The caller owns
# state transition; a failed component never becomes ledger success.
graph_composite_success_validate() {
  local report="$1" graph="$2" run_file="$3" node_id="$4" run_id="$5" attempt_id="$6"
  local node_workspace="$7" state_root="$8" namespace="$9" plan_path="${10}" changeset="${11:-}"
  local record_path fingerprint gate_dir session_key stage mode required_changeset
  GRAPH_COMPOSITE_SUCCESS_REASON=""
  [[ -s "$report" && -s "$graph" && -s "$run_file" && -d "$node_workspace" && -f "$plan_path" ]] || {
    GRAPH_COMPOSITE_SUCCESS_REASON="missing-required-evidence"; return 1; }
  jq -e --arg node "$node_id" --arg run "$run_id" --arg attempt "$attempt_id" '
    .schemaVersion == 1 and .outcome == "success" and .exitCode == 0 and
    .stageId == $node and .runId == $run and .attemptId == $attempt and
    (.startedAt | type == "string") and (.finishedAt | type == "string")' "$report" >/dev/null 2>&1 || {
    GRAPH_COMPOSITE_SUCCESS_REASON="invalid-stage-outcome-report"; return 1; }
  # The plan is the durable loop state.  Any open checkbox means a success
  # report cannot be adopted, including after an interruption between TODOs.
  if get_next_todo "$plan_path" >/dev/null 2>&1; then
    GRAPH_COMPOSITE_SUCCESS_REASON="internal-plan-incomplete"; return 1
  fi
  session_key="${namespace}-${node_id}"; session_key="$(printf '%s' "$session_key" | sed 's/[^A-Za-z0-9_.-]/_/g')"
  if [[ -e "$state_root/sessions/$session_key/pending-human.txt" ]]; then
    GRAPH_COMPOSITE_SUCCESS_REASON="pending-human-request"; return 1
  fi
  stage="$(_graph_composite_success_stage "$graph" "$node_id")" || { GRAPH_COMPOSITE_SUCCESS_REASON="unknown-node"; return 1; }
  while IFS=$'\t' read -r declared required || [[ -n "$declared" ]]; do
    [[ -n "$declared" ]] || continue
    if [[ "$required" == "true" && ! -s "$state_root/artifacts/$namespace/exchange/$declared" ]]; then
      GRAPH_COMPOSITE_SUCCESS_REASON="required-artifact-missing:$declared"; return 1
    fi
  done < <(printf '%s' "$stage" | jq -r '
    [(.outputArtifacts // [])[], (.artifacts // [])[]]
    | unique_by(if type == "string" then . else .path end)[]?
    | if type == "string" then [., true] else [.path, (.required // true)] end | @tsv')
  mode="$(printf '%s' "$stage" | jq -r '.workspaceMode // "shared"')"
  if [[ "$mode" != "shared" ]]; then
    jq -e --arg node "$node_id" '.workspaceManager.schemaVersion == 1 and .workspaceManager.configSha != null' "$run_file" >/dev/null 2>&1 || {
      GRAPH_COMPOSITE_SUCCESS_REASON="workspace-policy-not-frozen"; return 1; }
  fi
  required_changeset="$(printf '%s' "$stage" | jq '[.writeScopes // [] | .[]] | length > 0')"
  if [[ "$required_changeset" == "true" ]]; then
    if [[ ! -s "$changeset" ]] || ! jq -e '.kind == "graph-changeset" and .schemaVersion == 1' "$changeset" >/dev/null 2>&1; then
      GRAPH_COMPOSITE_SUCCESS_REASON="missing-or-invalid-changeset"; return 1
    fi
  fi
  # Recheck brokered children at the node boundary, rather than trusting only
  # the TODO-time check.  This catches a report written before a child became
  # terminal and persists its accepted handoff inputs for the parent.
  gate_dir="$state_root/artifacts/$namespace/delegations/$node_id/$attempt_id"
  if ! graph_delegation_completion_gate "$node_workspace" "$namespace" "$run_id" "$node_id" "$attempt_id" "$gate_dir"; then
    GRAPH_COMPOSITE_SUCCESS_REASON="brokered-children-not-terminal:${GRAPH_DELEGATION_GATE_EVIDENCE:-unknown}"
    return 1
  fi
  fingerprint="$(graph_composite_success_fingerprint "$graph" "$run_file" "$node_id" "$state_root" "$namespace" "$changeset")" || {
    GRAPH_COMPOSITE_SUCCESS_REASON="fingerprint-failed"; return 1; }
  record_path="$(graph_composite_success_path "$state_root" "$namespace" "$node_id" "$attempt_id")"
  mkdir -p "$(dirname "$record_path")" || return 1
  ralph_atomic_write_json "$record_path" \
    '{schemaVersion:1,nodeId:$node,runId:$run,attemptId:$attempt,reportPath:$report,
      planPath:$plan,changesetPath:(if $changeset == "" then null else $changeset end),
      fingerprint:$fingerprint,components:{internalPlan:true,pendingHuman:false,
      completionFooter:true,requiredArtifacts:true,structuredOutput:true,
      runnerVerification:true,nativeSubagentsReconciled:true,brokeredChildren:true,
      workspacePolicy:true,changesetOrGate:true,stageOutcomeDurable:true}}' \
    --arg node "$node_id" --arg run "$run_id" --arg attempt "$attempt_id" --arg report "$report" \
    --arg plan "$plan_path" --arg changeset "${changeset:-}" --argjson fingerprint "$fingerprint" || return 1
  GRAPH_COMPOSITE_SUCCESS_RECORD="$record_path"
  return 0
}

# Reuse is safe only when the exact acceptance record and all fingerprinted
# inputs still match.  Missing evidence fails closed and lets the scheduler
# rerun only this node plus its descendants.
graph_composite_success_reusable() {
  local graph="$1" run_file="$2" node_id="$3" run_id="$4" attempt_id="$5" state_root="$6" namespace="$7"
  local record changeset now then
  record="$(graph_composite_success_path "$state_root" "$namespace" "$node_id" "$attempt_id")"
  [[ -s "$record" ]] || return 1
  jq -e --arg node "$node_id" --arg run "$run_id" --arg attempt "$attempt_id" \
    '.schemaVersion == 1 and .nodeId == $node and .runId == $run and .attemptId == $attempt and (.components | all(.[]; . == true or . == false))' "$record" >/dev/null 2>&1 || return 1
  changeset="$(jq -r '.changesetPath // empty' "$record")"
  [[ -z "$changeset" || -s "$changeset" ]] || return 1
  now="$(graph_composite_success_fingerprint "$graph" "$run_file" "$node_id" "$state_root" "$namespace" "$changeset")" || return 1
  then="$(jq -c '.fingerprint' "$record")" || return 1
  [[ "$now" == "$then" ]]
}
