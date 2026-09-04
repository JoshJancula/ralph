#!/usr/bin/env bash
# Parent completion gate for scheduler-owned delegated runs.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then echo "This file is meant to be sourced, not executed." >&2; exit 1; fi
if [[ -n "${GRAPH_DELEGATION_COMPLETION_LOADED:-}" ]]; then return 0; fi
GRAPH_DELEGATION_COMPLETION_LOADED=1
_GRAPH_DELEGATION_COMPLETION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F graph_delegation_ledger_read_status >/dev/null 2>&1; then source "$_GRAPH_DELEGATION_COMPLETION_DIR/graph-delegation-ledger.sh"; fi
if ! declare -F graph_delegation_queue_file >/dev/null 2>&1; then source "$_GRAPH_DELEGATION_COMPLETION_DIR/graph-delegation-queue.sh"; fi

_graph_delegation_completion_path() {
  local state_root="$1" id="$2" path="$3" candidate real_root real_path
  [[ -n "$path" && "$path" != *$'\n'* ]] || return 1
  real_root="$(cd "$state_root" 2>/dev/null && pwd -P)" || return 1
  if [[ "$path" = /* ]]; then candidate="$path"; else
    candidate="$state_root/delegated-runs/$id/$path"
    [[ -e "$candidate" ]] || candidate="$state_root/$path"
  fi
  [[ -f "$candidate" && -s "$candidate" && ! -L "$candidate" ]] || return 1
  real_path="$(cd "$(dirname "$candidate")" 2>/dev/null && pwd -P)/$(basename "$candidate")" || return 1
  [[ "$real_path" == "$real_root/"* ]] || return 1
  printf '%s\n' "$candidate"
}

# Verify immutable supervisor handoff evidence. A bare terminal model claim is
# deliberately insufficient; every declared artifact must have a durable copy.
graph_delegation_completion_verify_success() {
  local workspace="$1" id="$2" status_json="$3" request result mode declared item declared_path artifact_path resolved state_root
  state_root="$(graph_state_state_root "$workspace")" || return 1
  request="$(graph_delegation_ledger_request_file "$workspace" "$id")" || return 1
  [[ -f "$request" ]] || return 1
  result="$(jq -c '.finalResult // empty' <<<"$status_json" 2>/dev/null)" || return 1
  [[ -n "$result" && "$result" != null ]] || return 1
  declared="$(jq -c '.artifactPaths // []' "$request" 2>/dev/null)" || return 1
  jq -e 'type == "array"' <<<"$declared" >/dev/null 2>&1 || return 1
  while IFS= read -r item; do
    declared_path="$(jq -r '.declaredPath // empty' <<<"$item" 2>/dev/null)"
    artifact_path="$(jq -r '.artifactPath // empty' <<<"$item" 2>/dev/null)"
    [[ -n "$declared_path" && -n "$artifact_path" ]] || return 1
    resolved="$(_graph_delegation_completion_path "$state_root" "$id" "$artifact_path")" || return 1
  done < <(jq -c '.finalResult.declaredArtifacts // [] | .[]' <<<"$status_json")
  if [[ "$(jq 'length' <<<"$declared")" -gt 0 ]]; then
    [[ "$(jq '.finalResult.declaredArtifacts // [] | length' <<<"$status_json")" -eq "$(jq 'length' <<<"$declared")" ]] || return 1
  else
    resolved="$(_graph_delegation_completion_path "$state_root" "$id" "$(jq -r '.resultArtifact // empty' <<<"$result")")" || return 1
  fi
  mode="$(jq -r '.accessMode // (if .mode == "changeset" then "changeset" else "read-only" end)' "$request" 2>/dev/null)"
  if [[ "$mode" == changeset ]]; then
    local changeset integration
    changeset="$(_graph_delegation_completion_path "$state_root" "$id" "$(jq -r '.changesetArtifact // empty' <<<"$result")")" || return 1
    integration="$(_graph_delegation_completion_path "$state_root" "$id" "$(jq -r '.integrationResult // empty' <<<"$result")")" || return 1
    [[ "$(jq -r '.integrated // false' <<<"$result")" == true ]] || return 1
    jq -e '.schemaVersion == 1 and .kind == "graph-changeset" and (.writeScopes | type == "array" and length > 0) and (.laneVerification.status == "passed")' "$changeset" >/dev/null 2>&1 || return 1
    jq -e '.schemaVersion == 1 and .kind == "graph-integration" and (.changeCount | type == "number")' "$integration" >/dev/null 2>&1 || return 1
  fi
}

# 0 accepted; 10 nonterminal/unverified; 11 failed; 12 cancelled.
graph_delegation_completion_gate() {
  local workspace="$1" ns="$2" run_id="$3" parent="$4" attempt="$5" artifact_root="$6"
  local queue entry did request parent_attempt status_json state evidence="" blocked=0 failed=0 cancelled=0
  local inputs='[]' integrations='[]' result_path changeset_path integration_path mode
  GRAPH_DELEGATION_GATE_EVIDENCE=""; GRAPH_DELEGATION_GATE_INPUT_ARTIFACTS=""; GRAPH_DELEGATION_GATE_INTEGRATION_INPUTS=""
  [[ -n "$workspace" && -n "$ns" && -n "$run_id" && -n "$parent" ]] || return 0
  queue="$(graph_delegation_queue_file "$workspace" "$ns" "$run_id" 2>/dev/null)" || return 1
  [[ -f "$queue" ]] || return 0
  while IFS= read -r entry; do
    [[ "$(jq -r '.parentNodeId // empty' <<<"$entry")" == "$parent" ]] || continue
    did="$(jq -r '.delegatedRunId // empty' <<<"$entry")"
    request="$(graph_delegation_ledger_request_file "$workspace" "$did" 2>/dev/null)" || { blocked=1; evidence+="delegation=$did state=missing-ledger\n"; continue; }
    parent_attempt="$(jq -r '.parentAttemptId // empty' "$request" 2>/dev/null)"
    [[ -z "$parent_attempt" || -z "$attempt" || "$parent_attempt" == "$attempt" ]] || continue
    status_json="$(graph_delegation_ledger_read_status "$workspace" "$did" 2>/dev/null)" || { blocked=1; evidence+="delegation=$did state=missing-ledger\n"; continue; }
    if [[ "$(jq -r 'if has("finalResult") then "yes" else "no" end' <<<"$status_json")" == no ]]; then
      local terminal_result_file terminal_result
      terminal_result_file="$(graph_delegation_ledger_result_file "$workspace" "$did" 2>/dev/null)"
      terminal_result="$(jq -c '.result // empty' "$terminal_result_file" 2>/dev/null)"
      [[ -n "$terminal_result" ]] && status_json="$(jq -c --argjson result "$terminal_result" '. + {finalResult:$result}' <<<"$status_json")"
    fi
    state="$(jq -r '.status // "unknown"' <<<"$status_json")"
    case "$state" in
      succeeded)
        if ! graph_delegation_completion_verify_success "$workspace" "$did" "$status_json"; then blocked=1; evidence+="delegation=$did state=unverified-succeeded\n"; continue; fi
        result_path="$(jq -r '.finalResult.resultArtifact // empty' <<<"$status_json")"
        mode="$(jq -r '.accessMode // (if .mode == "changeset" then "changeset" else "read-only" end)' "$request" 2>/dev/null)"
        if [[ "$mode" == changeset ]]; then
          changeset_path="$(jq -r '.finalResult.changesetArtifact // empty' <<<"$status_json")"
          integration_path="$(jq -r '.finalResult.integrationResult // empty' <<<"$status_json")"
          integrations="$(jq -c --arg id "$did" --arg path "$changeset_path" --arg result "$integration_path" '. + [{delegatedRunId:$id,changesetArtifact:$path,integrationResult:$result,apply:"scheduler-integrated"}]' <<<"$integrations")"
        else
          inputs="$(jq -c --arg id "$did" --arg path "$result_path" '. + [{delegatedRunId:$id,resultArtifact:$path}]' <<<"$inputs")"
        fi
        ;;
      queued|running|unknown|'') blocked=1; evidence+="delegation=$did state=$state\n" ;;
      failed) blocked=1; failed=1; evidence+="delegation=$did state=failed\n" ;;
      cancelled) blocked=1; cancelled=1; evidence+="delegation=$did state=cancelled\n" ;;
      *) blocked=1; evidence+="delegation=$did state=$state\n" ;;
    esac
  done < <(jq -c '.[]' "$queue" 2>/dev/null)
  if [[ "$inputs" != '[]' || "$integrations" != '[]' ]]; then
    mkdir -p "$artifact_root" || return 1
    ralph_atomic_write_json "$artifact_root/input-artifacts.json" '$v' --argjson v "$inputs" || return 1
    ralph_atomic_write_json "$artifact_root/integration-inputs.json" '$v' --argjson v "$integrations" || return 1
    GRAPH_DELEGATION_GATE_INPUT_ARTIFACTS="$artifact_root/input-artifacts.json"; GRAPH_DELEGATION_GATE_INTEGRATION_INPUTS="$artifact_root/integration-inputs.json"
  fi
  GRAPH_DELEGATION_GATE_EVIDENCE="$(printf '%b' "$evidence" | sed '/^$/d' | head -20)"
  [[ "$blocked" == 0 ]] || { [[ "$cancelled" == 1 ]] && return 12; [[ "$failed" == 1 ]] && return 11; return 10; }
  return 0
}
