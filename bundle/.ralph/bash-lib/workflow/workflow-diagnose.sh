#!/usr/bin/env bash
# Normalized diagnosis of why a workflow run is not progressing.
#
# Both engines stall for the same operator-visible reasons, so both map onto one
# diagnosis object:
#
#   {state, reasonCode, summary, stageId, requestKind, requestId,
#    evidence, retryable, nextAction}
#
# evidence is an array of paths or messages. nextAction is null or
# {label, argv} with argv as an array, so a caller can print or execute the one
# action that actually unblocks the run.
#
# These functions are pure: they read action records and the observation they are
# handed, and never write state, start a process, or poll.

if [[ -n "${RALPH_WORKFLOW_DIAGNOSE_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
RALPH_WORKFLOW_DIAGNOSE_LOADED=1

# Public run states and reason codes, kept in one place so both engines agree.
WORKFLOW_DIAGNOSE_STATES=(queued running waiting blocked stale failed cancelled succeeded)
WORKFLOW_DIAGNOSE_REASON_CODES=(
  operator-request operator-input human-approval human-changes-requested
  unmet-dependency failed-prerequisite missing-artifact invalid-artifact
  loop-exhausted cycle live-owner stale-owner stage-failed cancelled none
)

# workflow_diagnose_emit <state> <reasonCode> <summary> <stageId> <retryable>
#   <evidence-json-array> <nextAction-json> [requestKind] [requestId]
workflow_diagnose_emit() {
  local state="$1" reason="$2" summary="$3" stage_id="$4" retryable="$5"
  local evidence="${6:-[]}" next_action="${7:-null}"
  local request_kind="${8:-}" request_id="${9:-}"

  jq -cn \
    --arg state "$state" \
    --arg reasonCode "$reason" \
    --arg summary "$summary" \
    --arg stageId "$stage_id" \
    --arg requestKind "$request_kind" \
    --arg requestId "$request_id" \
    --argjson retryable "$retryable" \
    --argjson evidence "$evidence" \
    --argjson nextAction "$next_action" \
    '{
      state: $state,
      reasonCode: $reasonCode,
      summary: $summary,
      stageId: (if $stageId == "" then null else $stageId end),
      requestKind: (if $requestKind == "" then null else $requestKind end),
      requestId: (if $requestId == "" then null else $requestId end),
      evidence: $evidence,
      retryable: $retryable,
      nextAction: $nextAction
    }'
}

workflow_diagnose_action() {
  local label="$1"
  shift
  # Build the argv array by hand: jq --args still parses a positional that looks
  # like an option (for example --stage), which would corrupt a reset action.
  local argv_json
  argv_json="$(printf '%s\n' "$@" | jq -Rc . | jq -sc .)"
  jq -cn --arg label "$label" --argjson argv "$argv_json" \
    '{label: $label, argv: $argv}'
}

workflow_diagnose_resume_action() {
  workflow_diagnose_action "resume the run" ralph workflow resume "$1"
}

workflow_diagnose_actions_action() {
  workflow_diagnose_action "answer the outstanding request" \
    ralph workflow actions list "$1"
}

workflow_diagnose_reset_action() {
  workflow_diagnose_action "reset to the approval changes target" \
    ralph workflow reset "$1" --stage "$2"
}

workflow_diagnose_rework_reset_action() {
  workflow_diagnose_action "retry the final repair with the latest review feedback" \
    ralph workflow reset "$1" --stage "$2"
}

_workflow_diagnose_emit_exhausted_review() {
  local node="$1" run_id="$2" node_id repair_target verdict_path evidence
  node_id="$(printf '%s' "$node" | jq -r '.id // ""')"
  repair_target="$(printf '%s' "$node" | jq -r \
    '(.dependencies // []) | map(if type == "object" then (.stageId // "") else . end) | map(select(. != "")) | first // ""')"
  verdict_path="$(printf '%s' "$node" | jq -r \
    '(.artifacts // []) | map(select(type == "string" and length > 0)) | first // ""')"
  evidence="$(_workflow_diagnose_node_evidence "$node" \
    "$(jq -cn --arg verdict "$verdict_path" --arg target "$repair_target" '
      ([if $verdict != "" then "final review verdict " + $verdict else empty end]
       + [if $target != "" then "repair target " + $target else empty end])')")"
  if [[ -n "$repair_target" ]]; then
    workflow_diagnose_emit blocked loop-exhausted \
      "final review $node_id still requested changes after every automatic repair round; integration and verification did not run" \
      "$node_id" false "$evidence" \
      "$(workflow_diagnose_rework_reset_action "$run_id" "$repair_target")"
  else
    workflow_diagnose_emit blocked loop-exhausted \
      "final review $node_id still requested changes after every automatic repair round, but no safe repair target was recorded" \
      "$node_id" false "$evidence" null
  fi
}

workflow_diagnose_recover_action() {
  workflow_diagnose_action "recover the abandoned run" ralph workflow recover "$1"
}

# Reason code for an outstanding request of the given kind.
workflow_diagnose_request_reason() {
  case "${1:-}" in
    input) printf 'operator-input' ;;
    approval) printf 'human-approval' ;;
    permission) printf 'operator-request' ;;
    *) printf 'operator-request' ;;
  esac
}

# workflow_diagnose_owner_class <observation-json>
#
# Liveness predicate. The default reads the class the observation already
# carries, which is what a caller computes from graph_heartbeat_classify_run (or
# the Sequential owner classifier). Tests set it in the fixture; callers that
# want live probing can override this function.
workflow_diagnose_owner_class() {
  local observation="$1"
  printf '%s' "$(printf '%s' "$observation" | jq -r '.ownerClass // "none"')"
}

# _workflow_diagnose_first_node <observation> <jq-filter>
# First node matching the filter, or empty.
_workflow_diagnose_first_node() {
  printf '%s' "$1" | jq -c "[.nodes[]? | select($2)] | first // empty"
}

_workflow_diagnose_node_evidence() {
  local node="$1" extra="${2:-[]}"
  printf '%s' "$node" | jq -c --argjson extra "$extra" '
    [
      ("stage " + (.id // "?") + " is " + (.state // "?")),
      (.attemptId // empty | "attempt " + .)
    ] + (.evidence // []) + $extra
  '
}

# workflow_diagnose_core <registry-run> <observation-json> <engine>
#
# Shared normalization for both engines. `engine` is dependency or sequential;
# native permission requests are only reachable on dependency.
workflow_diagnose_core() {
  local run_dir="${1:-}" observation="${2:-}" engine="${3:-dependency}"
  local run_id run_status owner_class cycle node node_id blocker
  local kind request_id class reason summary evidence changes_target
  local loop_json iterations max_iterations

  command -v jq >/dev/null 2>&1 || {
    echo "Error: jq is required for workflow diagnosis" >&2
    return 1
  }
  if [[ -z "$observation" ]] || ! printf '%s' "$observation" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "Error: workflow_diagnose requires an observation object" >&2
    return 1
  fi

  run_id="$(printf '%s' "$observation" | jq -r '.runId // ""')"
  run_status="$(printf '%s' "$observation" | jq -r '.runStatus // "running"')"
  owner_class="$(workflow_diagnose_owner_class "$observation")"

  # 1. A cycle is a structural deadlock: no action unblocks it.
  cycle="$(printf '%s' "$observation" | jq -c '.cycle // []')"
  if [[ "$(printf '%s' "$cycle" | jq -r 'length')" -gt 0 ]]; then
    workflow_diagnose_emit blocked cycle \
      "the graph contains a dependency cycle and can never progress" \
      "" false \
      "$(printf '%s' "$cycle" | jq -c 'map("cycle member " + .)')" null
    return 0
  fi

  # 2. Cancellation is terminal.
  if [[ "$run_status" == "cancelled" ]]; then
    workflow_diagnose_emit cancelled cancelled \
      "the run was cancelled by the operator" "" false '[]' null
    return 0
  fi

  # 3. Human-requested changes outrank everything else that is merely waiting:
  #    the run is blocked until the operator resets the exact changes target.
  node="$(_workflow_diagnose_first_node "$observation" \
    '(.reasonCode // "") == "human-changes-requested" or ((.blocker.reasonCode // "") == "human-changes-requested")')"
  if [[ -n "$node" ]]; then
    node_id="$(printf '%s' "$node" | jq -r '.id // ""')"
    changes_target="$(printf '%s' "$node" | jq -r '.changesTarget // .blocker.changesTarget // ""')"
    request_id="$(printf '%s' "$node" | jq -r '.blocker.requestId // ""')"
    if [[ -z "$changes_target" ]]; then
      workflow_diagnose_emit blocked human-changes-requested \
        "the operator requested changes but the gate declares no changesTarget" \
        "$node_id" false "$(_workflow_diagnose_node_evidence "$node")" null \
        approval "$request_id"
      return 0
    fi
    workflow_diagnose_emit blocked human-changes-requested \
      "the operator requested changes at $node_id; reset $changes_target and resume" \
      "$node_id" false "$(_workflow_diagnose_node_evidence "$node")" \
      "$(workflow_diagnose_reset_action "$run_id" "$changes_target")" \
      approval "$request_id"
    return 0
  fi

  # 4. Owner liveness. A stale owner is recoverable; a live one means the run is
  #    simply owned elsewhere and nothing is wrong.
  if [[ "$owner_class" == "stale" ]]; then
    workflow_diagnose_emit stale stale-owner \
      "the owning supervisor is gone and the run can be recovered" \
      "" true \
      "$(printf '%s' "$observation" | jq -c '[("last heartbeat " + (.heartbeatAt // "unknown"))]')" \
      "$(workflow_diagnose_recover_action "$run_id")"
    return 0
  fi
  if [[ "$owner_class" == "healthy" && "$run_status" == "running" ]]; then
    workflow_diagnose_emit running live-owner \
      "another supervisor owns this run and is still making progress" \
      "" true \
      "$(printf '%s' "$observation" | jq -c '[("owner pid " + ((.ownerPid // "unknown") | tostring))]')" \
      null
    return 0
  fi

  # 5. An outstanding or answered action request on some stage.
  node="$(_workflow_diagnose_first_node "$observation" '(.blocker | type) == "object"')"
  if [[ -n "$node" ]]; then
    node_id="$(printf '%s' "$node" | jq -r '.id // ""')"
    blocker="$(printf '%s' "$node" | jq -c '.blocker')"
    kind="$(printf '%s' "$blocker" | jq -r '.kind // ""')"
    request_id="$(printf '%s' "$blocker" | jq -r '.requestId // ""')"

    if [[ "$engine" == "sequential" && "$kind" == "permission" ]]; then
      workflow_diagnose_emit blocked stage-failed \
        "a native permission request cannot occur on the sequential engine" \
        "$node_id" false "$(_workflow_diagnose_node_evidence "$node")" null \
        "$kind" "$request_id"
      return 0
    fi

    class="$(workflow_action_waiting_resume_class "$run_dir" "$blocker" 2>/dev/null || printf 'refuse')"
    evidence="$(_workflow_diagnose_node_evidence "$node")"
    case "$class" in
      clean-interruption)
        workflow_diagnose_emit waiting operator-request \
          "the run was interrupted cleanly and can be resumed as is" \
          "$node_id" true "$evidence" \
          "$(workflow_diagnose_resume_action "$run_id")" "$kind" "$request_id"
        return 0
        ;;
      answered-input)
        workflow_diagnose_emit waiting operator-input \
          "the operator answered the input request; resume consumes it once" \
          "$node_id" true "$evidence" \
          "$(workflow_diagnose_resume_action "$run_id")" "$kind" "$request_id"
        return 0
        ;;
      approved-gate)
        workflow_diagnose_emit waiting human-approval \
          "the approval gate was approved; resume continues past it" \
          "$node_id" true "$evidence" \
          "$(workflow_diagnose_resume_action "$run_id")" "$kind" "$request_id"
        return 0
        ;;
      unresolved-action)
        reason="$(workflow_diagnose_request_reason "$kind")"
        case "$kind" in
          input) summary="the run is waiting for the operator to answer an input request" ;;
          approval) summary="the run is waiting for the operator to decide an approval gate" ;;
          permission) summary="the run is waiting for the operator to decide a permission request" ;;
          *) summary="the run is waiting for an outstanding operator request" ;;
        esac
        workflow_diagnose_emit waiting "$reason" "$summary" \
          "$node_id" false "$evidence" \
          "$(workflow_diagnose_actions_action "$run_id")" "$kind" "$request_id"
        return 0
        ;;
      changes-requested)
        changes_target="$(printf '%s' "$node" | jq -r '.changesTarget // .blocker.changesTarget // ""')"
        if [[ -n "$changes_target" ]]; then
          workflow_diagnose_emit blocked human-changes-requested \
            "the operator requested changes at $node_id; reset $changes_target and resume" \
            "$node_id" false "$evidence" \
            "$(workflow_diagnose_reset_action "$run_id" "$changes_target")" \
            "$kind" "$request_id"
        else
          workflow_diagnose_emit blocked human-changes-requested \
            "the operator requested changes but the gate declares no changesTarget" \
            "$node_id" false "$evidence" null "$kind" "$request_id"
        fi
        return 0
        ;;
      refuse)
        workflow_diagnose_emit blocked stage-failed \
          "the recorded action state is inconsistent and resume would be unsafe" \
          "$node_id" false "$evidence" null "$kind" "$request_id"
        return 0
        ;;
    esac
  fi

  # 5b. Parallel-wave failure. Sequential runs waves of stages together, so a
  #     stage that cannot start because a sibling in its own wave failed is a
  #     distinct operator story from an ordinary upstream prerequisite failure.
  node="$(_workflow_diagnose_first_node "$observation" '((.waveFailures // []) | length) > 0')"
  if [[ -n "$node" ]]; then
    node_id="$(printf '%s' "$node" | jq -r '.id // ""')"
    local wave_id
    wave_id="$(printf '%s' "$node" | jq -r '.wave // "?" | tostring')"
    workflow_diagnose_emit blocked stage-failed \
      "wave $wave_id cannot complete because a stage in the same wave failed" \
      "$node_id" false \
      "$(_workflow_diagnose_node_evidence "$node" \
        "$(printf '%s' "$node" | jq -c --arg w "$wave_id" \
          '[.waveFailures[] | "failed in wave " + $w + ": " + .]')")" \
      null
    return 0
  fi

  # 6. Exhausted rework or repair loop.
  node="$(_workflow_diagnose_first_node "$observation" \
    '((.loop.iterations // 0) >= (.loop.max // 0)) and ((.loop.max // 0) > 0) and ((.state // "") != "succeeded")')"
  if [[ -n "$node" ]]; then
    node_id="$(printf '%s' "$node" | jq -r '.id // ""')"
    loop_json="$(printf '%s' "$node" | jq -c '.loop')"
    iterations="$(printf '%s' "$loop_json" | jq -r '.iterations')"
    max_iterations="$(printf '%s' "$loop_json" | jq -r '.max')"
    workflow_diagnose_emit blocked loop-exhausted \
      "$node_id exhausted its $max_iterations rework iterations without approval" \
      "$node_id" false \
      "$(_workflow_diagnose_node_evidence "$node" \
        "$(jq -cn --arg i "$iterations" --arg m "$max_iterations" '["iteration " + $i + " of " + $m]')")" \
      null
    return 0
  fi

  # The Dependency scheduler represents final compile-time rework exhaustion
  # as a failed review with no remaining changes-required edge. Classify this
  # before downstream prerequisite fallout so the root cause wins.
  node="$(_workflow_diagnose_first_node "$observation" \
    '(.state // "") == "failed" and (.reasonCode // "") == "review-changes-required-no-edge"')"
  if [[ -n "$node" ]]; then
    _workflow_diagnose_emit_exhausted_review "$node" "$run_id"
    return 0
  fi

  # 7. Prerequisite and artifact problems, most specific first.
  node="$(_workflow_diagnose_first_node "$observation" '((.failedPrerequisites // []) | length) > 0')"
  if [[ -n "$node" ]]; then
    node_id="$(printf '%s' "$node" | jq -r '.id // ""')"
    workflow_diagnose_emit blocked failed-prerequisite \
      "$node_id cannot run because a prerequisite stage failed" \
      "$node_id" false \
      "$(_workflow_diagnose_node_evidence "$node" \
        "$(printf '%s' "$node" | jq -c '[.failedPrerequisites[] | "failed prerequisite " + .]')")" \
      null
    return 0
  fi

  node="$(_workflow_diagnose_first_node "$observation" '((.invalidArtifacts // []) | length) > 0')"
  if [[ -n "$node" ]]; then
    node_id="$(printf '%s' "$node" | jq -r '.id // ""')"
    workflow_diagnose_emit blocked invalid-artifact \
      "$node_id produced an artifact that does not match its declared schema" \
      "$node_id" false \
      "$(_workflow_diagnose_node_evidence "$node" \
        "$(printf '%s' "$node" | jq -c '[.invalidArtifacts[] | "invalid artifact " + .]')")" \
      null
    return 0
  fi

  node="$(_workflow_diagnose_first_node "$observation" '((.missingArtifacts // []) | length) > 0')"
  if [[ -n "$node" ]]; then
    node_id="$(printf '%s' "$node" | jq -r '.id // ""')"
    workflow_diagnose_emit blocked missing-artifact \
      "$node_id is missing a required artifact declared by its dependencies" \
      "$node_id" false \
      "$(_workflow_diagnose_node_evidence "$node" \
        "$(printf '%s' "$node" | jq -c '[.missingArtifacts[] | "missing artifact " + .]')")" \
      null
    return 0
  fi

  node="$(_workflow_diagnose_first_node "$observation" '((.unmetDependencies // []) | length) > 0')"
  if [[ -n "$node" ]]; then
    node_id="$(printf '%s' "$node" | jq -r '.id // ""')"
    workflow_diagnose_emit blocked unmet-dependency \
      "$node_id is waiting on a dependency that has not completed" \
      "$node_id" false \
      "$(_workflow_diagnose_node_evidence "$node" \
        "$(printf '%s' "$node" | jq -c '[.unmetDependencies[] | "unmet dependency " + .]')")" \
      null
    return 0
  fi

  # 8. A plain stage failure with nothing more specific recorded.
  node="$(_workflow_diagnose_first_node "$observation" '(.state // "") == "failed"')"
  if [[ -n "$node" ]]; then
    local failure_reason=""
    node_id="$(printf '%s' "$node" | jq -r '.id // ""')"
    failure_reason="$(printf '%s' "$node" | jq -r '.reasonCode // ""')"
    workflow_diagnose_emit blocked stage-failed \
      "$(if [[ -n "$failure_reason" ]]; then
          printf '%s failed: %s' "$node_id" "$failure_reason"
        else
          printf '%s failed and no more specific cause was recorded' "$node_id"
        fi)" \
      "$node_id" false \
      "$(_workflow_diagnose_node_evidence "$node" \
        "$(if [[ -n "$failure_reason" ]]; then jq -cn --arg reason "$failure_reason" '["failure reason " + $reason]'; else printf '[]'; fi)")" \
      null
    return 0
  fi

  # 9. Nothing outstanding: a clean operator interruption that resume clears.
  if [[ "$run_status" == "waiting" || "$run_status" == "running" ]]; then
    workflow_diagnose_emit waiting operator-request \
      "the run was interrupted cleanly and can be resumed as is" \
      "" true '[]' "$(workflow_diagnose_resume_action "$run_id")"
    return 0
  fi

  workflow_diagnose_emit "$run_status" none \
    "no blocking condition was found" "" true '[]' null
}

# workflow_diagnose_dependency <registry-run> <observation-json>
workflow_diagnose_dependency() {
  workflow_diagnose_core "${1:-}" "${2:-}" dependency
}

# workflow_diagnose_sequential <registry-run> <observation-json>
#
# Sequential runs cannot raise a native permission request, so that kind is
# reported as an inconsistency rather than an answerable action.
workflow_diagnose_sequential() {
  workflow_diagnose_core "${1:-}" "${2:-}" sequential
}

# workflow_diagnose_outer_state <diagnosis-json>
# The registry state a diagnosis normalizes to. run.json has no reason field, so
# only the state is persisted; the reason travels in the diagnosis record.
workflow_diagnose_outer_state() {
  printf '%s' "${1:-}" | jq -r '.state // "running"'
}

# workflow_diagnose_persist_outer_state <state-root> <run-id> <diagnosis-json>
#
# Sequential must not leave a run reading `running` once nothing can progress.
# This is the one deliberately non-pure entry point in this file: the diagnosis
# functions above never write, and this records the state they computed.
# Returns 0 when the run already carried the normalized state.
workflow_diagnose_persist_outer_state() {
  local state_root="${1:-}" run_id="${2:-}" diagnosis="${3:-}"
  local target current

  if [[ -z "$state_root" || -z "$run_id" || -z "$diagnosis" ]]; then
    echo "Error: workflow_diagnose_persist_outer_state requires state-root, run-id, and diagnosis" >&2
    return 1
  fi
  target="$(workflow_diagnose_outer_state "$diagnosis")"
  case "$target" in
    running|queued)
      # Still progressing: nothing to normalize.
      return 0
      ;;
  esac

  current="$(workflow_state_read "$state_root" "$run_id" 2>/dev/null | jq -r '.state // ""')" || current=""
  if [[ "$current" == "$target" ]]; then
    return 0
  fi
  # workflow_state_update takes the jq filter as its third positional argument,
  # followed by any jq arguments.
  workflow_state_update "$state_root" "$run_id" '.state = $target' \
    --arg target "$target" >/dev/null || return 1
  return 0
}
