#!/usr/bin/env bash
# Parent TODO completion gate for Ralph-brokered delegated children.
# A child belongs to the graph-node attempt that created it.  It is never a
# substitute for the parent TODO's normal completion/verification gates.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then echo "This file is meant to be sourced, not executed." >&2; exit 1; fi
if [[ -n "${GRAPH_DELEGATION_COMPLETION_LOADED:-}" ]]; then return 0; fi
GRAPH_DELEGATION_COMPLETION_LOADED=1
_GRAPH_DELEGATION_COMPLETION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F graph_delegation_ledger_read_status >/dev/null 2>&1; then
  source "$_GRAPH_DELEGATION_COMPLETION_DIR/graph-delegation-ledger.sh"
fi

# Exit statuses: 0 safe, 10 outstanding, 11 acknowledgement/retry required,
# 12 bounded child failure needs a human.  The caller receives compact facts
# only: task text and prompts never enter this evidence.
graph_delegation_completion_gate() {
  local workspace="$1" ns="$2" run_id="$3" parent="$4" attempt="$5" artifact_root="$6"
  local root dir did request status_json state result_path mode reason evidence="" inputs='[]' integrations='[]' blocked=0 retry=0 exhausted=0
  GRAPH_DELEGATION_GATE_EVIDENCE=""; GRAPH_DELEGATION_GATE_INPUT_ARTIFACTS=""; GRAPH_DELEGATION_GATE_INTEGRATION_INPUTS=""
  [[ -n "$ns" && -n "$run_id" && -n "$parent" && -n "$attempt" ]] || return 0
  root="$(graph_delegation_ledger_root "$workspace" "$ns" "$run_id" "$parent")" || return 1
  [[ -d "$root" ]] || return 0
  for dir in "$root"/delegation-*; do
    [[ -d "$dir" && -f "$dir/request.json" ]] || continue
    request="$dir/request.json"
    [[ "$(jq -r '.parentAttemptId // empty' "$request" 2>/dev/null)" == "$attempt" ]] || continue
    did="$(jq -r '.delegationId // empty' "$request" 2>/dev/null)"
    status_json="$(graph_delegation_ledger_read_status "$workspace" "$ns" "$run_id" "$parent" "$did" 2>/dev/null)" || { blocked=1; evidence+="delegation=$did state=missing-ledger\n"; continue; }
    state="$(jq -r '.status // "unknown"' <<<"$status_json")"
    if [[ "$(jq -r '.policyViolation // false' <<<"$status_json")" == "true" ]]; then blocked=1; evidence+="delegation=$did state=policy-violation\n"; continue; fi
    case "$state" in
      queued|running|awaiting-ack|unknown|'') blocked=1; evidence+="delegation=$did state=$state\n" ;;
      succeeded)
        result_path="$(jq -r '.finalResult.resultArtifact // empty' <<<"$status_json")"
        if [[ -z "$result_path" ]]; then blocked=1; evidence+="delegation=$did state=succeeded-missing-result\n"; continue; fi
        if [[ "$result_path" = /* ]]; then [[ -s "$result_path" ]] || { blocked=1; evidence+="delegation=$did state=missing-result\n"; continue; }
        else [[ -s "$workspace/$result_path" ]] || { blocked=1; evidence+="delegation=$did state=missing-result\n"; continue; }; fi
        mode="$(jq -r '.accessMode // empty' "$request" 2>/dev/null)"
        [[ -n "$mode" ]] || mode="$(jq -r '.policy.requestedAccess // .policy.crossRuntime.mode // "read-only"' "$dir/policy.json" 2>/dev/null)"
        if [[ "$mode" == "changeset" ]]; then
          local changeset_path integration_path integrated
          changeset_path="$(jq -r '.finalResult.changesetArtifact // empty' <<<"$status_json")"
          integration_path="$(jq -r '.finalResult.integrationResult // empty' <<<"$status_json")"
          integrated="$(jq -r '.finalResult.integrated // false' <<<"$status_json")"
          if [[ -z "$changeset_path" || -z "$integration_path" || "$integrated" != true \
            || ! -s "$changeset_path" || ! -s "$integration_path" ]]; then
            blocked=1; evidence+="delegation=$did state=missing-integrated-changeset\n"; continue
          fi
          integrations="$(jq -c --arg id "$did" --arg path "$changeset_path" --arg result "$integration_path" '. + [{delegationId:$id,changesetArtifact:$path,integrationResult:$result,apply:"scheduler-integrated"}]' <<<"$integrations")"
        else
          inputs="$(jq -c --arg id "$did" --arg path "$result_path" '. + [{delegationId:$id,resultArtifact:$path}]' <<<"$inputs")"
        fi
        ;;
      failed)
        if [[ "$(jq -r '.acknowledgement.at // empty' <<<"$status_json")" == "" ]]; then
          retry=1; reason="$(jq -r '.attempts[-1].reason // "child failed"' <<<"$status_json" | tr '\n' ' ' | cut -c1-240)"; evidence+="delegation=$did state=failed reason=$reason\n"
        fi
        if jq -e '.attempts[-1].reason | test("exhaust|retry"; "i")' <<<"$status_json" >/dev/null 2>&1; then exhausted=1; fi
        ;;
      cancelled) : ;; # cancellation is explicit parent acknowledgement
      *) blocked=1; evidence+="delegation=$did state=$state\n" ;;
    esac
  done
  if [[ "$inputs" != '[]' || "$integrations" != '[]' ]]; then
    mkdir -p "$artifact_root" || return 1
    ralph_atomic_write_json "$artifact_root/input-artifacts.json" '$v' --argjson v "$inputs" || return 1
    ralph_atomic_write_json "$artifact_root/integration-inputs.json" '$v' --argjson v "$integrations" || return 1
    GRAPH_DELEGATION_GATE_INPUT_ARTIFACTS="$artifact_root/input-artifacts.json"
    GRAPH_DELEGATION_GATE_INTEGRATION_INPUTS="$artifact_root/integration-inputs.json"
  fi
  GRAPH_DELEGATION_GATE_EVIDENCE="$(printf '%b' "$evidence" | sed '/^$/d' | head -20)"
  [[ "$blocked" == 0 ]] || return 10
  [[ "$retry" == 0 ]] || { [[ "$exhausted" == 1 ]] && return 12 || return 11; }
  return 0
}
