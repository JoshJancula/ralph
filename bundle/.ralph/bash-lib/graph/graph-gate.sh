#!/usr/bin/env bash
# Scheduler-owned, model-free gate node for operator-authored verification profiles.
#
# A gate node runs an ordered list of named, allowlisted shell commands drawn
# from a verificationProfile declared in the graph JSON. It writes a
# schema-validated gate-result.json with outcome passed, changes-required, or
# error, then returns:
#   0  passed  - every required check succeeded
#   2  changes-required - commands ran correctly but found a code/test failure
#   1  error   - gate infrastructure, policy, timeout, or result-writing failure
#
# No model is ever invoked. All command output is redirected to compact artifact
# files under state_root/artifacts/namespace/gate/<node-id>/. Only bounded
# summaries appear in gate-result.json.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

GRAPH_GATE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F ralph_wait >/dev/null 2>&1; then
  # shellcheck source=../ralph-wait.sh
  source "$GRAPH_GATE_SCRIPT_DIR/../ralph-wait.sh"
fi

if ! declare -F graph_ui_node >/dev/null 2>&1; then
  # shellcheck source=graph-ui.sh
  source "$GRAPH_GATE_SCRIPT_DIR/graph-ui.sh"
fi
if ! declare -F graph_state_now_iso >/dev/null 2>&1; then
  # shellcheck source=graph-state.sh
  source "$GRAPH_GATE_SCRIPT_DIR/graph-state.sh"
fi

# ---------------------------------------------------------------------------
# Allowlisted executables. Add entries to RALPH_GATE_EXTRA_ALLOWED (colon-
# separated) at runtime to extend for project-specific tooling without
# modifying this file.  The base list covers common CI verification tools.
# ---------------------------------------------------------------------------

GRAPH_GATE_BASE_ALLOWED=(
  bash sh env
  python3 python
  node npm yarn npx
  go cargo make
  pytest
  eslint pylint flake8 ruff shellcheck
  jq cat grep find diff wc sort head tail ls
  echo printf true false
  git
)

# graph_gate_is_allowed_executable <exe>
# Returns 0 when exe is in the base allowlist or in RALPH_GATE_EXTRA_ALLOWED.
graph_gate_is_allowed_executable() {
  local exe="$1" e
  # Strip leading path components; only the basename is allowlisted.
  exe="$(basename "$exe")"
  for e in "${GRAPH_GATE_BASE_ALLOWED[@]}"; do
    [[ "$e" == "$exe" ]] && return 0
  done
  if [[ -n "${RALPH_GATE_EXTRA_ALLOWED:-}" ]]; then
    local IFS=':'
    for e in $RALPH_GATE_EXTRA_ALLOWED; do
      [[ "$(basename "$e")" == "$exe" ]] && return 0
    done
  fi
  return 1
}

# graph_gate_extract_executable <command_string>
# Extracts the first word of a command string as the executable name.
# Handles leading whitespace. Prints the extracted name on stdout.
graph_gate_extract_executable() {
  local cmd="$1"
  # Trim leading whitespace, then take the first token.
  printf '%s' "$cmd" | awk '{print $1}'
}

# _graph_gate_timeout_cmd
# Prints the name of the timeout binary available on this system, or empty
# if neither timeout nor gtimeout is present.
_graph_gate_timeout_cmd() {
  if command -v timeout >/dev/null 2>&1; then
    printf 'timeout'
  elif command -v gtimeout >/dev/null 2>&1; then
    printf 'gtimeout'
  fi
}

# _graph_gate_watchdog <secs> <output_file> [<command_words...>]
# Runs the command, redirecting stdout+stderr to output_file, with a bash-
# level watchdog that kills the process if it exceeds <secs> seconds.
# Sets GRAPH_GATE_STEP_TIMED_OUT=1 when the watchdog fires.
# Returns the process exit code (124 on timeout).
GRAPH_GATE_STEP_TIMED_OUT=0
_graph_gate_watchdog() {
  local secs="$1" output_file="$2"; shift 2
  GRAPH_GATE_STEP_TIMED_OUT=0
  local cmd_pid ec=0 waited=0

  ( "$@" ) >>"$output_file" 2>&1 &
  cmd_pid=$!

  while kill -0 "$cmd_pid" 2>/dev/null; do
    if [[ "$waited" -ge "$secs" ]]; then
      GRAPH_GATE_STEP_TIMED_OUT=1
      kill -TERM "$cmd_pid" 2>/dev/null || true
      ralph_wait 1
      kill -KILL "$cmd_pid" 2>/dev/null || true
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done

  if [[ "$GRAPH_GATE_STEP_TIMED_OUT" -eq 1 ]]; then
    wait "$cmd_pid" 2>/dev/null || true
    return 124
  fi
  wait "$cmd_pid" 2>/dev/null || ec=$?
  return "$ec"
}

# graph_gate_run_step <step_name> <command> <timeout_secs> <output_file>
#   [<workspace>]
# Runs a single gate step command with the given timeout, writing all output
# to output_file. Returns 0 on success, 124 on timeout, non-zero on failure.
# Sets GRAPH_GATE_STEP_TIMED_OUT (1 when timed out, 0 otherwise).
graph_gate_run_step() {
  local step_name="$1" cmd="$2" timeout_secs="$3" output_file="$4"
  local workspace="${5:-}"
  GRAPH_GATE_STEP_TIMED_OUT=0
  local ec=0

  local timeout_bin
  timeout_bin="$(_graph_gate_timeout_cmd)"

  mkdir -p "$(dirname "$output_file")" || return 1

  if [[ -n "$timeout_bin" ]]; then
    # Use the system timeout binary; it exits 124 when the process times out.
    # Append (>>) so the step header written before this call is preserved.
    if [[ -n "$workspace" ]]; then
      ( cd "$workspace" && exec "$timeout_bin" "$timeout_secs" bash -c "$cmd" ) \
        >>"$output_file" 2>&1 || ec=$?
    else
      "$timeout_bin" "$timeout_secs" bash -c "$cmd" >>"$output_file" 2>&1 || ec=$?
    fi
  else
    # Fallback: watchdog loop (1-second granularity). Append to preserve header.
    local watchdog_cmd=( bash -c "$cmd" )
    if [[ -n "$workspace" ]]; then
      watchdog_cmd=( bash -c "cd \"\$1\" && $cmd" _ "$workspace" )
    fi
    ec=0
    _graph_gate_watchdog "$timeout_secs" "$output_file" "${watchdog_cmd[@]}" || ec=$?
  fi

  if [[ "$ec" -eq 124 ]]; then
    GRAPH_GATE_STEP_TIMED_OUT=1
    printf 'gate-step: step=%s timed-out after %ss\n' "$step_name" "$timeout_secs" >>"$output_file" 2>/dev/null || true
  fi
  return "$ec"
}

# _graph_gate_write_result <result_path> <node_id> <profile_name> <outcome>
#   <error_reason> <started_at> <finished_at> <steps_json>
# Writes a schema-validated gate-result.json atomically via mktemp + rename.
# Returns 0 on success, 1 on failure.
_graph_gate_write_result() {
  local result_path="$1" node_id="$2" profile_name="$3" outcome="$4"
  local error_reason="$5" started_at="$6" finished_at="$7" steps_json="$8"

  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: graph-gate: jq required to write gate-result.json" >&2
    return 1
  fi

  local tmp
  tmp="$(mktemp "$(dirname "$result_path")/.gate-result-XXXXXX")" || return 1

  local json
  json="$(jq -cn \
    --argjson schemaVersion 1 \
    --arg nodeId "$node_id" \
    --arg profileName "$profile_name" \
    --arg outcome "$outcome" \
    --arg errorReason "$error_reason" \
    --arg startedAt "$started_at" \
    --arg finishedAt "$finished_at" \
    --argjson steps "$steps_json" \
    '{
      schemaVersion: $schemaVersion,
      nodeId: $nodeId,
      profileName: $profileName,
      outcome: $outcome,
      startedAt: $startedAt,
      finishedAt: $finishedAt,
      steps: $steps
    }
    + (if $errorReason != "" then {errorReason: $errorReason} else {} end)')" || {
    rm -f "$tmp"
    return 1
  }

  # Validate the schema version and outcome field before committing.
  local written_outcome
  written_outcome="$(printf '%s' "$json" | jq -r '.outcome // empty' 2>/dev/null)" || {
    rm -f "$tmp"
    return 1
  }
  case "$written_outcome" in
    passed|changes-required|error) ;;
    *)
      echo "Error: graph-gate: invalid outcome in gate-result: $written_outcome" >&2
      rm -f "$tmp"
      return 1
      ;;
  esac

  printf '%s\n' "$json" >"$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$result_path" || { rm -f "$tmp"; return 1; }
  return 0
}

# graph_gate_run <node_id> <graph_json> <workspace> <state_root> <namespace>
#
# Main gate entry point. Reads the gate node's profile name from stage.profile
# in the graph JSON, finds the matching verificationProfile, runs all steps,
# and writes gate-result.json. Returns:
#   0  outcome=passed
#   2  outcome=changes-required
#   1  outcome=error
graph_gate_run() {
  local node_id="$1" graph_json="$2" workspace="$3" state_root="$4" namespace="$5"
  local started_at profile_name profile_json steps_count
  local result_dir result_path steps_json outcome error_reason

  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: graph-gate: jq is required" >&2
    return 1
  fi

  if [[ -z "$node_id" || -z "$graph_json" || -z "$state_root" || -z "$namespace" ]]; then
    echo "Error: graph-gate: missing required arguments" >&2
    return 1
  fi
  if [[ ! -f "$graph_json" ]]; then
    echo "Error: graph-gate: graph json not found: $graph_json" >&2
    return 1
  fi

  started_at="$(graph_state_now_iso)"

  # Read profile name from stage.profile in the graph JSON node.
  profile_name="$(jq -r --arg id "$node_id" \
    '.nodes[] | select(.id == $id) | .stage.profile // empty' \
    "$graph_json" 2>/dev/null)"
  if [[ -z "$profile_name" ]]; then
    echo "Error: graph-gate: node $node_id missing stage.profile" >&2
    return 1
  fi

  # Find the named profile in verificationProfiles.
  profile_json="$(jq -c --arg name "$profile_name" \
    '.verificationProfiles[]? | select(.name == $name)' \
    "$graph_json" 2>/dev/null)"
  if [[ -z "$profile_json" ]]; then
    echo "Error: graph-gate: verificationProfile '$profile_name' not found in graph JSON" >&2
    return 1
  fi

  steps_count="$(printf '%s' "$profile_json" | jq '.steps | length' 2>/dev/null)"
  if [[ -z "$steps_count" || "$steps_count" -eq 0 ]]; then
    echo "Error: graph-gate: profile '$profile_name' has no steps" >&2
    return 1
  fi

  result_dir="$state_root/artifacts/$namespace/gate/$(printf '%s' "$node_id" | sed 's|[^A-Za-z0-9_.-]|_|g')"
  mkdir -p "$result_dir" || {
    echo "Error: graph-gate: cannot create result dir: $result_dir" >&2
    return 1
  }
  result_path="$result_dir/gate-result.json"

  # Read optional flaky rerun policy.
  local flaky_max_reruns flaky_match_exit
  flaky_max_reruns="$(printf '%s' "$profile_json" | jq -r '.flakyRerunPolicy.maxReruns // 0')"
  [[ "$flaky_max_reruns" =~ ^[0-9]+$ ]] || flaky_max_reruns=0
  flaky_match_exit="$(printf '%s' "$profile_json" | jq -c '.flakyRerunPolicy.matchExit // []')"

  steps_json='[]'
  outcome="passed"
  error_reason=""

  local i step_name step_cmd step_timeout step_resource step_continue step_required_json
  local step_required_count step_artifact exe step_ec step_outcome step_reruns
  local step_timed_out artifact_path artifact_rel step_entry
  local gate_stage_id_sub="${node_id//:/_}"

  for ((i = 0; i < steps_count; i++)); do
    step_name="$(printf '%s' "$profile_json" | jq -r ".steps[$i].name // \"step-$i\"")"
    step_cmd="$(printf '%s' "$profile_json" | jq -r ".steps[$i].command // empty")"
    # Gate steps that assert on a run artifact need the run's namespace. These
    # are the same tokens used everywhere else a path is authored, resolved here
    # so a profile can name .ralph-workspace/artifacts/{{ARTIFACT_NS}}/... .
    step_cmd="${step_cmd//\{\{ARTIFACT_NS\}\}/$namespace}"
    step_cmd="${step_cmd//\{\{STAGE_ID\}\}/$gate_stage_id_sub}"
    step_timeout="$(printf '%s' "$profile_json" | jq -r ".steps[$i].timeout // 300")"
    step_resource="$(printf '%s' "$profile_json" | jq -r ".steps[$i].resourceClass // \"default\"")"
    step_continue="$(printf '%s' "$profile_json" | jq -r ".steps[$i].continueOnFailure // false")"
    step_required_json="$(printf '%s' "$profile_json" | jq -c ".steps[$i].requiredArtifacts // []")"
    step_required_count="$(printf '%s' "$step_required_json" | jq 'length')"

    [[ "$step_timeout" =~ ^[0-9]+$ ]] || step_timeout=300
    [[ "$step_timeout" -gt 0 ]] || step_timeout=300

    if [[ -z "$step_cmd" ]]; then
      echo "Error: graph-gate: step '$step_name' has no command" >&2
      error_reason="step-missing-command:$step_name"
      outcome="error"
      step_entry="$(jq -cn \
        --arg name "$step_name" --arg command "" \
        --arg resourceClass "$step_resource" \
        --argjson exitCode 1 --argjson timedOut false \
        --arg stepOutcome error \
        --arg artifactPath "" --argjson reruns 0 \
        '{name:$name,command:$command,resourceClass:$resourceClass,exitCode:$exitCode,timedOut:$timedOut,outcome:$stepOutcome,artifactPath:$artifactPath,reruns:$reruns}')"
      steps_json="$(jq -c --argjson e "$step_entry" '. + [$e]' <<<"$steps_json")"
      break
    fi

    # Validate the executable against the allowlist.
    exe="$(graph_gate_extract_executable "$step_cmd")"
    if ! graph_gate_is_allowed_executable "$exe"; then
      echo "Error: graph-gate: step '$step_name' command '$exe' is not in the allowlist" >&2
      error_reason="non-allowlisted-command:$exe"
      outcome="error"
      step_entry="$(jq -cn \
        --arg name "$step_name" --arg command "$step_cmd" \
        --arg resourceClass "$step_resource" \
        --argjson exitCode 1 --argjson timedOut false \
        --arg stepOutcome error \
        --arg artifactPath "" --argjson reruns 0 \
        '{name:$name,command:$command,resourceClass:$resourceClass,exitCode:$exitCode,timedOut:$timedOut,outcome:$stepOutcome,artifactPath:$artifactPath,reruns:$reruns}')"
      steps_json="$(jq -c --argjson e "$step_entry" '. + [$e]' <<<"$steps_json")"
      break
    fi

    # Check required artifacts before running.
    if [[ "$step_required_count" -gt 0 ]]; then
      local ri missing_artifact=""
      for ((ri = 0; ri < step_required_count; ri++)); do
        step_artifact="$(printf '%s' "$step_required_json" | jq -r ".[$ri]")"
        if [[ -z "$step_artifact" ]]; then
          continue
        fi
        case "$step_artifact" in
          /*) ;;
          *) step_artifact="$state_root/$step_artifact" ;;
        esac
        if [[ ! -e "$step_artifact" ]]; then
          missing_artifact="$step_artifact"
          break
        fi
      done
      if [[ -n "$missing_artifact" ]]; then
        echo "Error: graph-gate: step '$step_name' required artifact missing: $missing_artifact" >&2
        error_reason="missing-artifact:$step_name"
        outcome="error"
        step_entry="$(jq -cn \
          --arg name "$step_name" --arg command "$step_cmd" \
          --arg resourceClass "$step_resource" \
          --argjson exitCode 1 --argjson timedOut false \
          --arg stepOutcome error \
          --arg artifactPath "" --argjson reruns 0 \
          '{name:$name,command:$command,resourceClass:$resourceClass,exitCode:$exitCode,timedOut:$timedOut,outcome:$stepOutcome,artifactPath:$artifactPath,reruns:$reruns}')"
        steps_json="$(jq -c --argjson e "$step_entry" '. + [$e]' <<<"$steps_json")"
        break
      fi
    fi

    # Artifact log path for this step's output.
    artifact_rel="artifacts/$namespace/gate/$(printf '%s' "$node_id" | sed 's|[^A-Za-z0-9_.-]|_|g')/step-${i}-$(printf '%s' "$step_name" | sed 's|[^A-Za-z0-9_.-]|_|g').log"
    artifact_path="$state_root/$artifact_rel"

    # Run the step with optional flaky rerun.
    step_reruns=0
    step_ec=0
    step_timed_out=0

    {
      printf 'gate-step: node=%s step=%s command=%s timeout=%ss resource=%s\n' \
        "$node_id" "$step_name" "$step_cmd" "$step_timeout" "$step_resource"
    } >"$artifact_path" 2>/dev/null || true

    graph_gate_run_step \
      "$step_name" "$step_cmd" "$step_timeout" "$artifact_path" "$workspace" || step_ec=$?
    [[ "$GRAPH_GATE_STEP_TIMED_OUT" -eq 1 ]] && step_timed_out=1

    # Flaky rerun: retry when the exit code matches flakyRerunPolicy.matchExit
    # and we have reruns remaining, but only when the step was not timed out.
    if [[ "$step_ec" -ne 0 && "$step_timed_out" -eq 0 && "$flaky_max_reruns" -gt 0 ]]; then
      local match_count
      match_count="$(printf '%s' "$flaky_match_exit" | jq --argjson ec "$step_ec" '[.[] | select(. == $ec)] | length')"
      if [[ "$match_count" -gt 0 ]]; then
        while [[ "$step_reruns" -lt "$flaky_max_reruns" ]]; do
          step_reruns=$((step_reruns + 1))
          echo "gate-step: node=$node_id step=$step_name rerun=$step_reruns" >>"$artifact_path" 2>/dev/null || true
          step_ec=0
          graph_gate_run_step \
            "$step_name" "$step_cmd" "$step_timeout" "$artifact_path" "$workspace" || step_ec=$?
          [[ "$GRAPH_GATE_STEP_TIMED_OUT" -eq 1 ]] && step_timed_out=1
          [[ "$step_ec" -eq 0 ]] && break
        done
      fi
    fi

    # Determine per-step outcome.
    if [[ "$step_timed_out" -eq 1 ]]; then
      step_outcome="error"
      if [[ "$outcome" != "error" ]]; then
        outcome="error"
        error_reason="timeout:$step_name"
      fi
    elif [[ "$step_ec" -eq 0 ]]; then
      step_outcome="passed"
    else
      step_outcome="failed"
      if [[ "$outcome" == "passed" ]]; then
        outcome="changes-required"
      fi
    fi

    step_entry="$(jq -cn \
      --arg name "$step_name" \
      --arg command "$step_cmd" \
      --arg resourceClass "$step_resource" \
      --argjson exitCode "$step_ec" \
      --argjson timedOut "$([ "$step_timed_out" -eq 1 ] && echo true || echo false)" \
      --arg stepOutcome "$step_outcome" \
      --arg artifactPath "$artifact_rel" \
      --argjson reruns "$step_reruns" \
      '{name:$name,command:$command,resourceClass:$resourceClass,exitCode:$exitCode,timedOut:$timedOut,outcome:$stepOutcome,artifactPath:$artifactPath,reruns:$reruns}')"
    steps_json="$(jq -c --argjson e "$step_entry" '. + [$e]' <<<"$steps_json")"

    graph_ui_detail "gate step $step_name: $step_outcome (exit=$step_ec reruns=$step_reruns resource=$step_resource)"

    # Stop after first failure unless continueOnFailure is true.
    if [[ "$step_outcome" != "passed" && "$step_continue" != "true" ]]; then
      # Mark remaining steps as skipped.
      local j
      for ((j = i + 1; j < steps_count; j++)); do
        local skip_name
        skip_name="$(printf '%s' "$profile_json" | jq -r ".steps[$j].name // \"step-$j\"")"
        step_entry="$(jq -cn \
          --arg name "$skip_name" --arg command "" \
          --arg resourceClass "default" \
          --argjson exitCode 0 --argjson timedOut false \
          --arg stepOutcome skipped \
          --arg artifactPath "" --argjson reruns 0 \
          '{name:$name,command:$command,resourceClass:$resourceClass,exitCode:$exitCode,timedOut:$timedOut,outcome:$stepOutcome,artifactPath:$artifactPath,reruns:$reruns}')"
        steps_json="$(jq -c --argjson e "$step_entry" '. + [$e]' <<<"$steps_json")"
      done
      break
    fi
  done

  local finished_at
  finished_at="$(graph_state_now_iso)"

  if ! _graph_gate_write_result \
      "$result_path" "$node_id" "$profile_name" \
      "$outcome" "$error_reason" \
      "$started_at" "$finished_at" "$steps_json"; then
    echo "Error: graph-gate: failed to write gate-result.json: $result_path" >&2
    return 1
  fi

  graph_ui_node "$outcome" "$node_id" "gate profile=$profile_name"
  graph_ui_detail "result: $result_path"

  case "$outcome" in
    passed) return 0 ;;
    changes-required) return 2 ;;
    error) return 1 ;;
    *) return 1 ;;
  esac
}
