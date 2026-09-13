#!/usr/bin/env bash
# Consensus join node aggregation for graph mode.
#
# graph_consensus_result_path <workspace> <namespace> <node_id>
#   Prints the consensus result path for a join node.  Mirrors the stage-outcomes
#   convention in graph-dispatch.sh so callers find results without parsing logs.
#
# graph_consensus_run_join <workspace> <namespace> <run_id> <node_id> <policy> <voters_json>
#   Reads every voter artifact, applies the named policy, atomically writes a
#   consensus result under the artifacts consensus directory keyed by node id,
#   updates the node ledger entry, and returns 0 (approved) or non-zero (blocked).
#
# Supported policies:
#   veto (default) - any single changes-required verdict blocks; all-approved passes.
#   unanimous      - passes only when all voters approve; any dissent yields escalate.
#   adjudicate     - short-circuits on unanimity; on dissent dispatches an adjudicator
#                    agent whose prompt contains the full dissent packet with provenance
#                    (runtime, agent, model) for every voter; adjudicator verdict is final.
#   quorum         - N or more approvals pass; requires minRuntimes distinct providers
#                    (validated at compile time in plan-todo.sh); see code comment below.
#
# voters_json format (JSON array):
#   [{"voterId":"<node_id>:<voter_id>","runtime":"<rt>","artifact":"<abs_path>"
#     [,"agent":"<agent>"][,"model":"<model>"]}]
#
# Confidence ordering, onVoterError handling, and the adjudicate/quorum policies
# are implemented in later TODOs (p4-join-adjudicate-quorum, p4-voter-error-and-confidence).
# Do not add weighting or automated decision logic that uses confidence as a
# multiplier.  Research published in 2026 found correlated errors across providers
# and an agreement-to-correctness Spearman correlation of only 0.20-0.59; a
# confidence-weighted automated decision would be the single worst available choice.
#
# jq-only; no python3; bash 3.2 safe; no associative arrays; no namerefs.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

GRAPH_CONSENSUS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -F ralph_atomic_write_json >/dev/null 2>&1; then
  # shellcheck source=../atomic-json.sh
  source "$GRAPH_CONSENSUS_SCRIPT_DIR/../atomic-json.sh"
fi

if ! declare -F graph_state_write_node >/dev/null 2>&1; then
  # shellcheck source=./graph-state.sh
  source "$GRAPH_CONSENSUS_SCRIPT_DIR/graph-state.sh"
fi

if ! declare -F ralph_extract_review_status >/dev/null 2>&1; then
  # shellcheck source=../review-status.sh
  source "$GRAPH_CONSENSUS_SCRIPT_DIR/../review-status.sh"
fi

if ! declare -F graph_dispatch_run_node >/dev/null 2>&1; then
  # shellcheck source=./graph-dispatch.sh
  source "$GRAPH_CONSENSUS_SCRIPT_DIR/graph-dispatch.sh"
fi

GRAPH_CONSENSUS_SCHEMA_VERSION=1

# graph_consensus_adjudicator_artifact_path <workspace> <namespace> <node_id>
# Returns the deterministic path where the adjudicator will write its verdict.
# Callers and tests use this to pre-create or locate the artifact before or after
# dispatch without re-implementing the naming convention.
graph_consensus_adjudicator_artifact_path() {
  local workspace="$1" namespace="$2" node_id="$3"
  local safe_id state_root
  if [[ -z "$workspace" || -z "$namespace" || -z "$node_id" ]]; then
    echo "Error: graph_consensus_adjudicator_artifact_path requires workspace, namespace, node_id" >&2
    return 1
  fi
  safe_id="$(printf '%s' "$node_id" | sed 's/[^A-Za-z0-9._-]/_/g')"
  state_root="$(graph_state_state_root "$workspace")" || return 1
  printf '%s/artifacts/%s/consensus/%s-adjudicator.md\n' \
    "$state_root" "$namespace" "$safe_id"
}

# _graph_consensus_read_voter_confidence <artifact_path>
# Reads the optional confidence field from a voter artifact's REVIEW_STATUS block.
# Prints the numeric value when present; prints nothing when absent.
# Always returns 0 -- confidence is optional, its absence is not an error.
#
# Confidence is used ONLY for ordering the dissent packet so the lowest-confidence
# dissent appears first, enabling reviewers to focus on the most uncertain voices.
# It is NEVER used as a weight in the automated policy decision.  See the header
# comment and the note in graph_consensus_run_join for the full rationale.
_graph_consensus_read_voter_confidence() {
  local artifact="$1"
  if [[ ! -f "$artifact" ]]; then
    return 0
  fi
  local conf_line
  conf_line="$(sed -n '/<!-- REVIEW_STATUS: START -->/,/<!-- REVIEW_STATUS: END -->/p' "$artifact" \
    | grep "^confidence:" || true)"
  if [[ -z "$conf_line" ]]; then
    return 0
  fi
  local conf_val
  conf_val="$(printf '%s' "$conf_line" | sed 's/^confidence:[[:space:]]*//' | tr -d ' ')"
  # Validate: must be a number in [0,1].
  if printf '%s' "$conf_val" | grep -qE '^(0(\.[0-9]+)?|1(\.0*)?)$'; then
    printf '%s\n' "$conf_val"
  fi
  return 0
}

# _graph_consensus_build_dissent_packet <voters_result_json>
# Builds and prints a JSON object with the full dissent packet for the
# adjudicator prompt: all voters listed, with dissenting voters separated.
# Dissenting voters are sorted by ascending confidence so the lowest-confidence
# dissent appears first (null confidence is treated as 1.0 and goes last).
# Confidence is used here only for ordering, never as a decision weight; see
# the note in graph_consensus_run_join for the rationale.
_graph_consensus_build_dissent_packet() {
  local voters_result_json="$1"
  printf '%s' "$voters_result_json" | jq '{
    voters: .,
    dissentingVoters: ([.[] | select(.status == "changes-required")] | sort_by(.confidence // 1.0)),
    approvedVoters: [.[] | select(.status == "approved")]
  }'
}

# _graph_consensus_dispatch_adjudicator <workspace> <namespace> <run_id> <node_id>
#                                        <voters_result_json> <policy_cfg_json>
#
# Builds a synthetic single-node graph for the adjudicator, dispatches it via
# graph-dispatch.sh, reads the adjudicator's verdict from the deterministic
# artifact path, and prints the verdict (approved|changes-required).
#
# policy_cfg_json is a JSON object optionally carrying runtime, agent, model
# for the adjudicator stage.  Defaults to claude/code-review when absent.
_graph_consensus_dispatch_adjudicator() {
  local workspace="$1" namespace="$2" run_id="$3" node_id="$4"
  local voters_result_json="$5" policy_cfg_json="${6:-}"
  # Not "${6:-{}}": bash closes that expansion one brace early, so a provided
  # value arrives with a stray trailing "}". Same defect this file documents at
  # graph_consensus_run_join.
  [[ -n "$policy_cfg_json" ]] || policy_cfg_json='{}'

  local adj_id="${node_id}-adjudicator"
  local adj_artifact
  adj_artifact="$(graph_consensus_adjudicator_artifact_path "$workspace" "$namespace" "$node_id")" || return 1

  local result_dir
  result_dir="$(dirname "$adj_artifact")"
  mkdir -p "$result_dir" || return 1

  local safe_id
  safe_id="$(printf '%s' "$node_id" | sed 's/[^A-Za-z0-9._-]/_/g')"

  # Write the dissent packet to disk for audit and prompt inclusion.
  local packet_path="${result_dir}/${safe_id}-adjudicator-packet.json"
  local dissent_packet
  dissent_packet="$(_graph_consensus_build_dissent_packet "$voters_result_json")" || return 1
  printf '%s\n' "$dissent_packet" > "$packet_path"

  # Extract adjudicator configuration from policy_cfg_json.
  local adj_runtime adj_role adj_model
  adj_runtime="$(printf '%s' "$policy_cfg_json" | jq -r '.runtime // "claude"')"
  adj_role="$(printf '%s' "$policy_cfg_json" | jq -r '.role // "code-review"')"
  adj_model="$(printf '%s' "$policy_cfg_json" | jq -r '.model // ""')"

  # Build the adjudicator todo content containing the full dissent packet.
  # The adjudicator reads this prompt and writes a REVIEW_STATUS verdict to
  # the artifact at adj_artifact.  All voter provenance (runtime, agent,
  # model, status) is included so the adjudicator can weigh the evidence.
  local todo_content
  todo_content="You are the adjudicator for a consensus review node.

The following voters have reviewed the work and their verdicts are below.
Your task is to independently evaluate the evidence and produce your own verdict.

Dissent packet (all voters with provenance):
$(printf '%s\n' "$dissent_packet")

Review the work independently. Write your verdict as a REVIEW_STATUS block:
<!-- REVIEW_STATUS: START -->
status: approved
<!-- REVIEW_STATUS: END -->
or
<!-- REVIEW_STATUS: START -->
status: changes-required
<!-- REVIEW_STATUS: END -->

Your verdict determines the final decision."

  # Build a synthetic graph JSON with a single adjudicator node.
  # The adjudicator stage uses _inlineTodos so graph_dispatch_materialize_orch
  # writes the plan file and the orchestrator picks it up without changes.
  local adj_graph_json
  adj_graph_json="$(jq -n \
    --arg name    "${namespace}-adjudicator" \
    --arg ns      "$namespace" \
    --arg adj_id  "$adj_id" \
    --arg rt      "$adj_runtime" \
    --arg role    "$adj_role" \
    --arg mo      "$adj_model" \
    --arg content "$todo_content" \
    --arg art     "$adj_artifact" \
    '{
      schemaVersion: 1,
      name: $name,
      namespace: $ns,
      nodes: [{
        id: $adj_id,
        type: "agent",
        dependsOn: [],
        derivedFrom: "adjudicate",
        stage: (
          {id: $adj_id, runtime: $rt, sessionStrategy: "fresh", nativeSubagents: "off"}
          + (if $role != "" then {role: $role} else {} end)
          + (if $mo != "" then {model: $mo} else {} end)
          + {
            _inlineTodos: [{
              id: ($adj_id + "-task"),
              content: $content,
              verification: "Confirm your verdict is written as a REVIEW_STATUS block.",
              status: "pending"
            }],
            outputArtifacts: [{path: $art, required: false}]
          }
        )
      }],
      edges: []
    }')"

  # Write the synthetic graph JSON to the consensus directory.
  local adj_graph_path="${result_dir}/${safe_id}-adjudicator.graph.json"
  printf '%s\n' "$adj_graph_json" > "$adj_graph_path"

  # Dispatch the adjudicator via graph-dispatch machinery.  Attempt number 1
  # since adjudicators are not retried at this layer.
  graph_dispatch_run_node \
    "$adj_graph_path" "$adj_id" "$run_id" "1" "$workspace" >/dev/null 2>&1 || {
    echo "Error: adjudicator dispatch failed for node $node_id" >&2
    return 1
  }

  # Read the adjudicator's verdict from the deterministic artifact path.
  if [[ ! -f "$adj_artifact" ]]; then
    echo "Error: adjudicator did not produce a verdict artifact at $adj_artifact" >&2
    return 1
  fi

  local verdict
  verdict="$(_graph_consensus_read_voter_status "$adj_artifact")" || {
    echo "Error: could not parse adjudicator verdict from $adj_artifact" >&2
    return 1
  }
  printf '%s\n' "$verdict"
}

# graph_consensus_result_path <workspace> <namespace> <node_id>
# Prints the path where the consensus aggregation result JSON will be written.
# The caller is responsible for mkdir -p of the directory before calling
# the atomic writer, but graph_consensus_run_join does that internally.
graph_consensus_result_path() {
  local workspace="$1" namespace="$2" node_id="$3"
  local safe_id state_root
  if [[ -z "$workspace" || -z "$namespace" || -z "$node_id" ]]; then
    echo "Error: graph_consensus_result_path requires workspace, namespace, node_id" >&2
    return 1
  fi
  safe_id="$(printf '%s' "$node_id" | sed 's/[^A-Za-z0-9._-]/_/g')"
  state_root="$(graph_state_state_root "$workspace")" || return 1
  printf '%s/artifacts/%s/consensus/%s.json\n' \
    "$state_root" "$namespace" "$safe_id"
}

# _graph_consensus_read_voter_status <artifact_path> [schema_path]
# Prints the voter's verdict status (approved|changes-required) from a voter
# artifact file.  Delegates to ralph_extract_review_status_with_schema when
# available (rollout-gated), otherwise falls through to ralph_extract_review_status
# (the markdown REVIEW_STATUS block parser).  Returns non-zero on failure.
_graph_consensus_read_voter_status() {
  local artifact="$1" schema="${2:-}"
  if [[ ! -f "$artifact" ]]; then
    echo "Error: voter artifact not found: $artifact" >&2
    return 1
  fi
  local status
  if declare -F ralph_extract_review_status_with_schema >/dev/null 2>&1; then
    status="$(ralph_extract_review_status_with_schema "$artifact" "$schema")" || return 1
  else
    status="$(ralph_extract_review_status "$artifact")" || return 1
  fi
  case "$status" in
    approved|changes-required)
      printf '%s\n' "$status"
      return 0
      ;;
    *)
      echo "Error: voter artifact $artifact returned unrecognized status: $status" >&2
      return 1
      ;;
  esac
}

# graph_consensus_run_join <workspace> <namespace> <run_id> <node_id> <policy>
#                          <voters_json> [policy_cfg_json]
#
# Aggregates voter verdicts and records a consensus result.  Returns 0 when the
# join passes (decision=approved), non-zero when it blocks or escalates.
#
# policy_cfg_json (optional): policy-specific JSON configuration.
#   For adjudicate: {"runtime":"<rt>","agent":"<ag>","model":"<mo>"}
#   For quorum:     {"threshold":<N>}
#
# On success: ledger state is set to succeeded.
# On failure: ledger state is set to failed.
graph_consensus_run_join() {
  local workspace="$1" namespace="$2" run_id="$3" node_id="$4"
  local policy="${5:-veto}" voters_json="${6:-}"
  # Not "${7:-{}}" -- bash's brace-depth scan for that default closes the
  # parameter expansion one brace early, so whenever $7 is actually provided
  # its value comes through with a stray extra "}" appended (verified: a
  # provided '{"onVoterError":"fail"}' becomes '{"onVoterError":"fail"}}').
  # jq then silently reads only the first (valid) JSON document and reports
  # the trailing brace as a separate parse error, which happened to stay
  # invisible in prior callers but is a real corruption bug.
  local policy_cfg_json="${7:-}"
  [[ -z "$policy_cfg_json" ]] && policy_cfg_json='{}'

  if [[ -z "$workspace" || -z "$namespace" || -z "$run_id" || -z "$node_id" ]]; then
    echo "Error: graph_consensus_run_join requires workspace, namespace, run_id, node_id" >&2
    return 1
  fi

  command -v jq >/dev/null 2>&1 || { echo "Error: jq is required for consensus aggregation" >&2; return 1; }

  case "$policy" in
    veto|unanimous|adjudicate|quorum)
      ;;
    *)
      echo "Error: graph_consensus_run_join: unknown policy '$policy'" >&2
      return 1
      ;;
  esac

  if [[ -z "$voters_json" ]]; then
    echo "Error: graph_consensus_run_join: voters_json is required" >&2
    return 1
  fi

  # Extract onVoterError from policy_cfg_json.  Default is fail (fail closed).
  # A jury that lost a juror is not a jury: a voter whose runtime was unavailable
  # or whose stage exited non-zero is recorded with status=error.
  #   fail    -- default; any voter error blocks the join regardless of other verdicts.
  #   exclude -- drop the errored voter and proceed with the remaining voters.
  #   retry   -- re-dispatch the errored voter exactly once (attempt 2); if it still
  #              errors, fall back to fail behavior.
  local on_voter_error
  on_voter_error="$(printf '%s' "$policy_cfg_json" | jq -r '.onVoterError // "fail"')"
  case "$on_voter_error" in
    fail|exclude|retry) ;;
    *)
      echo "Error: graph_consensus_run_join: unknown onVoterError value '$on_voter_error' (must be fail, exclude, or retry)" >&2
      return 1
      ;;
  esac

  local voter_count
  voter_count="$(printf '%s' "$voters_json" | jq 'length' 2>/dev/null)" || {
    echo "Error: graph_consensus_run_join: voters_json is not valid JSON" >&2
    return 1
  }

  if [[ "$voter_count" -lt 1 ]]; then
    echo "Error: graph_consensus_run_join: voters_json must contain at least one voter" >&2
    return 1
  fi

  # Iterate over voters, read each artifact, and accumulate results.
  # Confidence is recorded per voter for display and dissent-packet ordering;
  # it is NEVER used as a weight in any automated policy decision -- see the header
  # comment for the full rationale (correlated errors, Spearman 0.20-0.59).
  local approved_count=0 changes_required_count=0 error_count=0
  local voters_result_json="[]"
  local i=0
  while [[ "$i" -lt "$voter_count" ]]; do
    local voter_entry voter_id runtime artifact agent model schema
    voter_entry="$(printf '%s' "$voters_json" | jq -c ".[$i]")"
    voter_id="$(printf '%s' "$voter_entry" | jq -r '.voterId // empty')"
    runtime="$(printf '%s' "$voter_entry" | jq -r '.runtime // empty')"
    artifact="$(printf '%s' "$voter_entry" | jq -r '.artifact // empty')"
    agent="$(printf '%s' "$voter_entry" | jq -r '.agent // empty')"
    model="$(printf '%s' "$voter_entry" | jq -r '.model // empty')"
    schema="$(printf '%s' "$voter_entry" | jq -r '.schema // empty')"

    if [[ -z "$voter_id" ]]; then
      echo "Error: voter at index $i is missing required field voterId" >&2
      return 1
    fi
    if [[ -z "$runtime" ]]; then
      echo "Error: voter $voter_id is missing required field runtime" >&2
      return 1
    fi

    local status="" voter_has_error=0

    if ! status="$(_graph_consensus_read_voter_status "$artifact" "$schema")"; then
      voter_has_error=1
    fi

    # Handle retry: re-dispatch the errored voter exactly once (attempt 2).
    # If the retry still fails, voter_has_error remains 1 and the behavior
    # falls back to fail (same as onVoterError=fail).
    if [[ "$voter_has_error" -eq 1 && "$on_voter_error" = "retry" ]]; then
      local graph_json_path
      graph_json_path="$(printf '%s' "$voter_entry" | jq -r '.graphJsonPath // empty')"
      if [[ -n "$graph_json_path" ]]; then
        echo "onVoterError=retry: retrying voter $voter_id (attempt 2)" >&2
        # Dispatch and ignore exit code; what matters is whether the artifact appears.
        graph_dispatch_run_node "$graph_json_path" "$voter_id" "$run_id" "2" "$workspace" >/dev/null 2>&1 || true
        # Re-read the artifact after the retry dispatch.
        if status="$(_graph_consensus_read_voter_status "$artifact" "$schema")"; then
          voter_has_error=0
        fi
        # If still errored, voter_has_error stays 1 -> falls back to fail below.
      else
        echo "onVoterError=retry: voter $voter_id has no graphJsonPath, cannot dispatch retry" >&2
      fi
    fi

    local confidence voter_obj
    if [[ "$voter_has_error" -eq 1 ]]; then
      echo "Voter $voter_id errored: could not read verdict from artifact '$artifact'" >&2
      error_count=$((error_count + 1))
      # Build error voter object.  Omit optional fields when empty.
      voter_obj="$(jq -n \
        --arg vid "$voter_id" \
        --arg rt "$runtime" \
        --arg ag "$agent" \
        --arg mo "$model" \
        '{voterId: $vid, runtime: $rt, status: "error"}
         + (if $ag != "" then {agent: $ag} else {} end)
         + (if $mo != "" then {model: $mo} else {} end)')"
    else
      # Successfully read voter status; also capture optional confidence.
      # Confidence is used only for dissent-packet ordering (ascending), never
      # as an automated decision weight -- see header comment.
      confidence="$(_graph_consensus_read_voter_confidence "$artifact")"
      case "$status" in
        approved)
          approved_count=$((approved_count + 1))
          ;;
        changes-required)
          changes_required_count=$((changes_required_count + 1))
          ;;
      esac
      # Build the voter result object; omit optional fields when empty so the
      # on-disk JSON stays clean and does not fail strict schema validators.
      voter_obj="$(jq -n \
        --arg vid "$voter_id" \
        --arg rt "$runtime" \
        --arg st "$status" \
        --arg ag "$agent" \
        --arg mo "$model" \
        --arg conf "$confidence" \
        '{voterId: $vid, runtime: $rt, status: $st}
         + (if $ag != "" then {agent: $ag} else {} end)
         + (if $mo != "" then {model: $mo} else {} end)
         + (if $conf != "" then {confidence: ($conf | tonumber)} else {} end)')"
    fi

    voters_result_json="$(printf '%s' "$voters_result_json" \
      | jq --argjson entry "$voter_obj" '. + [$entry]')"

    i=$((i + 1))
  done

  # Apply onVoterError policy after accumulating all voter results.
  # For fail and retry (retry falls back to fail after exhausting one retry):
  #   any errored voter forces the join to fail closed, regardless of policy.
  # For exclude: drop errored voters from the effective count; if all voters
  #   errored, fail closed since there is no jury left to apply the policy.
  local force_fail_from_voter_error=0
  local effective_voter_count="$voter_count"
  if [[ "$error_count" -gt 0 ]]; then
    case "$on_voter_error" in
      fail|retry)
        force_fail_from_voter_error=1
        ;;
      exclude)
        effective_voter_count=$((voter_count - error_count))
        if [[ "$effective_voter_count" -lt 1 ]]; then
          echo "Error: all voters errored; join has no effective voters to apply policy" >&2
          force_fail_from_voter_error=1
        fi
        ;;
    esac
  fi

  # Apply policy: decide the outcome.
  #
  # NOTE: naive majority vote and confidence-weighted averaging are intentionally
  # NEVER the default for any policy.  Research published in 2026 found highly
  # correlated errors across AI providers and an agreement-to-correctness
  # Spearman correlation of only 0.20-0.59.  Weighting by self-reported
  # confidence would be the single worst available choice.  quorum requires
  # compile-time minRuntimes enforcement to provide any independent signal.
  local decision join_exit_code
  if [[ "$force_fail_from_voter_error" -eq 1 ]]; then
    # Voter error forces the join closed regardless of policy.
    # decision is changes-required to signal a blocking failure.
    decision="changes-required"
    join_exit_code=1
  else
    case "$policy" in
      veto)
        if [[ "$changes_required_count" -gt 0 ]]; then
          decision="changes-required"
          join_exit_code=1
        else
          decision="approved"
          join_exit_code=0
        fi
        ;;
      unanimous)
        if [[ "$changes_required_count" -gt 0 ]]; then
          decision="escalate"
          join_exit_code=1
        else
          decision="approved"
          join_exit_code=0
        fi
        ;;
      adjudicate)
        if [[ "$changes_required_count" -eq 0 ]]; then
          # Unanimity: short-circuit, no adjudicator dispatch needed.
          decision="approved"
          join_exit_code=0
        else
          # Dissent: dispatch adjudicator with the full dissent packet.
          local adj_verdict
          adj_verdict="$(_graph_consensus_dispatch_adjudicator \
            "$workspace" "$namespace" "$run_id" "$node_id" \
            "$voters_result_json" "$policy_cfg_json")" || {
            echo "Error: adjudicator dispatch failed for consensus node $node_id" >&2
            return 1
          }
          decision="$adj_verdict"
          if [[ "$adj_verdict" == "approved" ]]; then
            join_exit_code=0
          else
            join_exit_code=1
          fi
        fi
        ;;
      quorum)
        # quorum policy: at least threshold approvals required.
        # Compile-time enforcement (plan-todo.sh) guarantees minRuntimes distinct
        # providers are present.  Runtime enforcement applies the threshold.
        # Do not add confidence weighting here -- see note above.
        local quorum_threshold
        quorum_threshold="$(printf '%s' "$policy_cfg_json" | jq -r '.threshold // empty')"
        if [[ -z "$quorum_threshold" || ! "$quorum_threshold" =~ ^[0-9]+$ ]]; then
          # Default threshold: simple majority (ceil(n/2)) when not configured.
          quorum_threshold=$(( (effective_voter_count + 1) / 2 ))
        fi
        if [[ "$approved_count" -ge "$quorum_threshold" ]]; then
          decision="approved"
          join_exit_code=0
        else
          decision="changes-required"
          join_exit_code=1
        fi
        ;;
    esac
  fi

  # Compute agreement ratio (approved voters / effective voters) via jq to stay
  # arithmetic-free in bash and produce a valid JSON float.
  # effective_voter_count excludes errored voters when onVoterError=exclude.
  local agreement_val
  if [[ "$effective_voter_count" -gt 0 ]]; then
    agreement_val="$(jq -n --argjson ap "$approved_count" --argjson tot "$effective_voter_count" '$ap / $tot')"
  else
    agreement_val="0"
  fi

  # Build dissent array (voter ids that returned changes-required).
  local dissent_json
  dissent_json="$(printf '%s' "$voters_result_json" \
    | jq '[.[] | select(.status == "changes-required") | .voterId]')"

  # Write the consensus result atomically.
  local result_path result_dir
  result_path="$(graph_consensus_result_path "$workspace" "$namespace" "$node_id")" || return 1
  result_dir="$(dirname "$result_path")"
  if ! mkdir -p "$result_dir"; then
    echo "Error: failed to create consensus result directory: $result_dir" >&2
    return 1
  fi

  if ! ralph_atomic_write_json "$result_path" \
    '{schemaVersion: $sv, nodeId: $nid, policy: $pol, decision: $dec,
      voters: ($vj | fromjson), agreement: $ag}
     + (if ($diss | fromjson | length) > 0 then {dissent: ($diss | fromjson)} else {} end)' \
    --argjson sv  "$GRAPH_CONSENSUS_SCHEMA_VERSION" \
    --arg     nid "$node_id" \
    --arg     pol "$policy" \
    --arg     dec "$decision" \
    --arg     vj  "$voters_result_json" \
    --argjson ag  "$agreement_val" \
    --arg     diss "$dissent_json"; then
    echo "Error: failed to write consensus result for node $node_id" >&2
    return 1
  fi

  # Record the join outcome in the ledger.  The join node itself is not a voter
  # stage so it does not carry an attempt; we update its state only.
  local ledger_state
  if [[ "$join_exit_code" -eq 0 ]]; then
    ledger_state="succeeded"
  else
    ledger_state="failed"
  fi

  if ! graph_state_write_node "$workspace" "$namespace" "$run_id" "$node_id" \
      "$ledger_state"; then
    echo "Error: failed to update ledger for consensus join node $node_id" >&2
    return 1
  fi

  return "$join_exit_code"
}
