#!/usr/bin/env bash
# Canonical Ralph orchestrator (repo root: .ralph/orchestrator.sh). Dispatches each JSON
# stage to Cursor, Claude, or Codex run-plan.sh via per-stage "runtime".
# Master orchestrator: read a JSON orchestration plan, run each step in order via Ralph
# (Cursor, Claude, or Codex run-plan.sh with --agent and --plan). Stops on first failure
# and writes actionable logs under .agents/logs/orchestrator-*.log.
#
# Orchestration plan format (JSON file with .orch.json extension):
#   {
#     "name": "pipeline-name",
#     "namespace": "artifact-namespace",
#     "description": "What this pipeline does",
#     "stages": [
#       {
#         "id": "stage-id",
#         "agent": "agent-name",
#         "runtime": "cursor", "claude", or "codex" (optional, default: cursor),
#         "plan": "path/to/stage-plan.md",
#         "planTemplate": "path/to/stage-plan.template.md (optional)",
#         "inputArtifacts": ["path/to/{{ARTIFACT_NS}}/input.md"],
#         "outputArtifacts": [
#           "path/to/{{ARTIFACT_NS}}/output.md"
#         ],
#         "artifacts": [
#           {
#             "path": ".agents/artifacts/{{ARTIFACT_NS}}/output.md",
#             "required": true
#           }
#         ]
#       }
#     ]
#   }
#
# Each stage's plan file lists the TODO(s) that agent should complete.
# After each stage, required artifacts are verified (exist, non-empty).
#
# Usage:
#   .ralph/orchestrator.sh --orchestration PATH [WORKSPACE]
#   .ralph/orchestrator.sh .agents/orchestration-plans/my-feature.orch.json
#
# Env:
#   ORCHESTRATOR_VERBOSE=1           log each step start to stderr as well as log file
#   ORCHESTRATOR_DRY_RUN=1           print steps and exit 0 without running runners
#   ORCHESTRATOR_RUNNER_TO_CONSOLE=0 when set, runner stdout/stderr go only to the orchestrator log (no live console mirror)
#   ORCHESTRATOR_HUMAN_ACK=1         enforce per-stage humanAck gates (default: off; pipeline does not pause)
#   RALPH_ARTIFACT_NS                override artifact namespace (default: from JSON or filename)
#   RALPH_ORCH_FILE                  path to the orchestration plan currently being processed
#
# Exit codes: 0 success, 1 failure, 3 human acknowledgment required (only when ORCHESTRATOR_HUMAN_ACK=1 and ack file missing)
#
# Optional per-stage JSON field humanAck: enforced only when ORCHESTRATOR_HUMAN_ACK=1. See .agents/artifacts/README.md.
#
# When stdout is a TTY and ORCHESTRATOR_RUNNER_TO_CONSOLE is not 0, each step streams the Ralph runner
# (run-plan.sh and Cursor/Claude agent output) to the console as well as appending to the orchestrator log.

set -euo pipefail

WORKSPACE="$(pwd)"
ORCH_FILE=""

usage() {
  echo "Usage: $0 --orchestration <orchestration_plan.orch.json> [workspace_dir]" >&2
  echo "   or: $0 <orchestration_plan.orch.json>   (workspace is current directory)" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --orchestration|-f)
      [[ -n "${2:-}" ]] || usage
      ORCH_FILE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      if [[ -z "$ORCH_FILE" && -f "$1" ]]; then
        ORCH_FILE="$1"
        shift
      elif [[ "$WORKSPACE" == "$(pwd)" && -d "$1" ]]; then
        WORKSPACE="$(cd "$1" && pwd)"
        shift
      else
        usage
      fi
      ;;
  esac
done

if [[ -z "$ORCH_FILE" ]]; then
  usage
fi

if [[ "$ORCH_FILE" != /* ]]; then
  ORCH_FILE="$(cd "$(dirname "$ORCH_FILE")" && pwd)/$(basename "$ORCH_FILE")"
fi

export RALPH_ORCH_FILE="$ORCH_FILE"

if [[ ! -f "$ORCH_FILE" ]]; then
  echo "Orchestrator error: orchestration file not found: $ORCH_FILE" >&2
  exit 1
fi

WORKSPACE="$(cd "$WORKSPACE" && pwd)"
if [[ ! -f "$WORKSPACE/.ralph/ralph-env-safety.sh" ]]; then
  echo "Orchestrator error: expected $WORKSPACE/.ralph/ralph-env-safety.sh (repo Ralph tooling)." >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$WORKSPACE/.ralph/ralph-env-safety.sh"
ralph_assert_path_not_env_secret "Orchestration file" "$ORCH_FILE"
AGENTS_SHARED_DIR="$WORKSPACE/.agents"
RALPH_LOG_DIR="$AGENTS_SHARED_DIR/logs"
mkdir -p "$RALPH_LOG_DIR"
ORCH_BASENAME="$(basename "$ORCH_FILE" | sed 's/\.[^.]*$//')"
ORCH_BASENAME="${ORCH_BASENAME//[^A-Za-z0-9_.-]/_}"
LOG_FILE="$RALPH_LOG_DIR/orchestrator-${ORCH_BASENAME}.log"
CURSOR_RUNNER="$WORKSPACE/.cursor/ralph/run-plan.sh"
CLAUDE_RUNNER="$WORKSPACE/.claude/ralph/run-plan.sh"
CODEX_RUNNER="$WORKSPACE/.codex/ralph/run-plan.sh"
EXPECTED_ARTIFACT_PATHS=()

ts() { date '+%Y-%m-%d %H:%M:%S'; }

# Agent config tool (shared under .ralph).
if [[ -f "$WORKSPACE/.ralph/agent-config-tool.sh" ]]; then
  AGENT_CONFIG_TOOL_SH="$WORKSPACE/.ralph/agent-config-tool.sh"
else
  AGENT_CONFIG_TOOL_SH=""
fi

# shellcheck source=/dev/null
source "$WORKSPACE/.ralph/bash-lib/orchestrator-lib.sh"

artifact_remediation_text() {
  echo "  Remediation:"
  echo "    1. Open the step plan and ensure the agent finished every TODO (agent should write declared outputs)."
  echo "    2. Create or fill the missing path under the repo root (see .agents/artifacts/README.md for handoff names)."
  echo "    3. To require different files for this step, edit artifacts or outputArtifacts in the JSON stage"
  echo "       or adjust output_artifacts in the agent config."
  echo "    4. Re-run from repo root: $0 --orchestration \"$ORCH_FILE\" \"$WORKSPACE\""
}

# After each successful delegated run: each expected artifact must exist and be non-empty.
verify_step_artifacts() {
  local step_n="$1"
  local ap abs
  if ((${#EXPECTED_ARTIFACT_PATHS[@]:-0} > 0)); then
    for ap in "${EXPECTED_ARTIFACT_PATHS[@]}"; do
    if [[ "$ap" == /* ]]; then
      abs="$ap"
    else
      abs="$WORKSPACE/$ap"
    fi
    if [[ ! -f "$abs" ]]; then
      log "FAIL step $step_n artifact check: missing file: $ap (resolved: $abs)"
      {
        echo ""
        echo "======== artifact verification failure ========"
        echo "Step: $step_n"
        echo "Reason: expected file missing"
        echo "Path (repo-relative or as given): $ap"
        echo "Resolved: $abs"
        artifact_remediation_text
        echo "=============================================="
      } >>"$LOG_FILE"
      echo -e "${C_R}${C_BOLD}Step $step_n artifact check failed (file missing)${C_RST}" >&2
      echo "  Expected file missing: $ap" >&2
      echo "  Resolved path: $abs" >&2
      artifact_remediation_text >&2
      echo "  Log: $LOG_FILE" >&2
      return 1
    fi
    if [[ ! -s "$abs" ]]; then
      log "FAIL step $step_n artifact check: empty file: $ap (resolved: $abs)"
      {
        echo ""
        echo "======== artifact verification failure ========"
        echo "Step: $step_n"
        echo "Reason: file exists but is empty (size 0)"
        echo "Path (repo-relative or as given): $ap"
        echo "Resolved: $abs"
        artifact_remediation_text
        echo "=============================================="
      } >>"$LOG_FILE"
      echo -e "${C_R}${C_BOLD}Step $step_n artifact check failed (empty file)${C_RST}" >&2
      echo "  Expected non-empty file: $ap" >&2
      echo "  Resolved path: $abs" >&2
      artifact_remediation_text >&2
      echo "  Log: $LOG_FILE" >&2
      return 1
    fi
    done
  fi
  return 0
}

# Extract status from code-review artifact (for loop control)
extract_review_status() {
  local review_file="$1"
  [[ ! -f "$review_file" ]] && return 1

  # Extract status field between markers
  local status=""
  if grep -q "<!-- REVIEW_STATUS: START -->" "$review_file" 2>/dev/null; then
    status="$(sed -n '/<!-- REVIEW_STATUS: START -->/,/<!-- REVIEW_STATUS: END -->/p' "$review_file" | grep '^status:' | head -1 | cut -d: -f2 | tr -d ' ')" || true
  fi

  [[ -n "$status" ]] && echo "$status" && return 0
  return 1
}

# Check if stage should loop back to a previous stage
check_loop_condition() {
  local stage_json="$1"
  local review_file="$2"

  # If no loopControl defined, proceed forward
  local loop_back="$(echo "$stage_json" | jq -r '.loopControl.loopBackTo // empty' 2>/dev/null)" || loop_back=""
  [[ -z "$loop_back" ]] && echo "proceed" && return 0

  # Check review status
  local status="$(extract_review_status "$review_file")" || status="unknown"
  local max_iter="$(echo "$stage_json" | jq -r '.loopControl.maxIterations // 3' 2>/dev/null)" || max_iter=3
  local current_iter="${STAGE_ITERATION:-1}"

  if [[ "$status" == "approved" ]]; then
    echo "proceed"
  elif (( current_iter < max_iter )); then
    echo "loop:$loop_back:$((current_iter + 1))"
  else
    echo "proceed"  # Max iterations reached
  fi
}

log() {
  echo "[$(ts)] $*" >> "$LOG_FILE"
  if [[ "${ORCHESTRATOR_VERBOSE:-0}" == "1" ]]; then
    echo "[$(ts)] $*" >&2
  fi
}

log "orchestrator started workspace=$WORKSPACE orchestration=$ORCH_FILE"

if [[ -t 1 && "${ORCHESTRATOR_NO_COLOR:-0}" != "1" ]]; then
  C_R="\033[31m"
  C_G="\033[32m"
  C_Y="\033[33m"
  C_B="\033[34m"
  C_DIM="\033[2m"
  C_BOLD="\033[1m"
  C_RST="\033[0m"
else
  C_R="" C_G="" C_Y="" C_B="" C_DIM="" C_BOLD="" C_RST=""
fi

step_index=0

# Check if orchestration file is JSON
if [[ "$ORCH_FILE" == *.json ]]; then
  # Parse JSON orchestration file with jq
  if ! command -v jq >/dev/null 2>&1; then
    log "FAIL: jq not found. Install jq to parse JSON orchestration files."
    echo -e "${C_R}${C_BOLD}Orchestrator aborted: jq is required for JSON orchestration${C_RST}" >&2
    echo "  Install: brew install jq (macOS) or apt install jq (Linux)" >&2
    echo "  Log: $LOG_FILE" >&2
    exit 1
  fi

  # Validate JSON
  if ! jq empty "$ORCH_FILE" 2>/dev/null; then
    log "FAIL parse: invalid JSON in $ORCH_FILE"
    echo -e "${C_R}${C_BOLD}Orchestrator parse error: invalid JSON${C_RST}" >&2
    jq empty "$ORCH_FILE" 2>&1 | sed 's/^/  /' >&2
    echo "  Log: $LOG_FILE" >&2
    exit 1
  fi

  # Artifact namespace: env wins, else JSON namespace, else orchestration basename
  json_ns="$(jq -r '.namespace // empty' "$ORCH_FILE" 2>/dev/null || echo "")"
  export RALPH_ARTIFACT_NS="${RALPH_ARTIFACT_NS:-${json_ns:-$ORCH_BASENAME}}"

  # Parse each stage from JSON array
  num_stages="$(jq '.stages | length' "$ORCH_FILE" 2>/dev/null || echo 0)"
  for ((idx = 0; idx < num_stages; idx++)); do
    stage="$(jq ".stages[$idx]" "$ORCH_FILE" 2>/dev/null)" || continue

    runtime_raw="$(echo "$stage" | jq -r '.runtime // "cursor"' 2>/dev/null || echo "cursor")"
    if ! runtime="$(orchestrator_validate_runtime "$runtime_raw")"; then
      log "FAIL parse: invalid RUNTIME '$runtime_raw' (use cursor, claude, or codex)"
      echo -e "${C_R}Invalid RUNTIME '${runtime_raw}'. Use cursor, claude, or codex.${C_RST}" >&2
      echo "  Log: $LOG_FILE" >&2
      exit 1
    fi
    agent="$(echo "$stage" | jq -r '.agent // ""' 2>/dev/null)" || agent=""
    plan_rel="$(echo "$stage" | jq -r '.plan // ""' 2>/dev/null)" || plan_rel=""

    # Parse artifacts from JSON array
    EXPECTED_ARTIFACT_PATHS=()
    artifacts_array="$(echo "$stage" | jq '.artifacts // []' 2>/dev/null)" || artifacts_array="[]"
    while IFS= read -r artifact_path; do
      [[ -z "$artifact_path" ]] && continue
      artifact_paths_append_unique "$artifact_path"
    done < <(echo "$artifacts_array" | jq -r '.[] | select(.required == true) | .path' 2>/dev/null)
    while IFS= read -r artifact_path; do
      [[ -z "$artifact_path" ]] && continue
      artifact_paths_append_unique "$artifact_path"
    done < <(echo "$stage" | jq -r '.outputArtifacts[]? | select(.required == true) | .path' 2>/dev/null)

    merge_required_artifacts_from_agent "$agent" "$runtime"

    if ! orchestrator_validate_stage_agent_plan "$agent" "$plan_rel"; then
      log "FAIL parse: empty agent or plan for stage JSON: $stage"
      echo -e "${C_R}Empty agent or plan path.${C_RST} Log: $LOG_FILE" >&2
      exit 1
    fi

    step_index=$((step_index + 1))
    plan_abs="$(orchestrator_stage_plan_abs "$plan_rel" "$WORKSPACE")"

  if [[ "$runtime" == "cursor" ]]; then
    runner="$CURSOR_RUNNER"
    runner_label="Cursor (.cursor/ralph/run-plan.sh)"
  elif [[ "$runtime" == "codex" ]]; then
    runner="$CODEX_RUNNER"
    runner_label="Codex (.codex/ralph/run-plan.sh)"
  else
    runner="$CLAUDE_RUNNER"
    runner_label="Claude (.claude/ralph/run-plan.sh)"
  fi

  if [[ ! -f "$runner" ]]; then
    log "FAIL step $step_index: runner missing: $runner"
    echo -e "${C_R}${C_BOLD}Orchestrator aborted before step $step_index${C_RST}" >&2
    echo "  Runner not found: $runner" >&2
    echo "  Install or add the Ralph runner for $runtime, then retry." >&2
    echo "  Log: $LOG_FILE" >&2
    exit 1
  fi

  ralph_assert_path_not_env_secret "Step plan" "$plan_abs"

  if ((${#EXPECTED_ARTIFACT_PATHS[@]:-0} > 0)); then
    for _art_check in "${EXPECTED_ARTIFACT_PATHS[@]}"; do
      ralph_assert_path_not_env_secret "Expected artifact" "$_art_check"
    done
  fi

  if [[ ! -f "$plan_abs" ]]; then
    log "FAIL step $step_index: plan file not found: $plan_abs"
    echo -e "${C_R}${C_BOLD}Step $step_index failed (plan missing)${C_RST}" >&2
    echo "  Agent: $agent  Runtime: $runtime" >&2
    echo "  Plan path: $plan_abs" >&2
    if ((step_index > 1)); then
      echo "  This plan should have been generated by the previous stage." >&2
      echo "  Check that the previous agent completed its Stage Plan Generation responsibility." >&2
    else
      echo "  Create this plan file or fix the path in $ORCH_FILE" >&2
    fi
    echo "  Log: $LOG_FILE" >&2
    exit 1
  fi

  art_log="(none)"
  if ((${#EXPECTED_ARTIFACT_PATHS[@]:-0} > 0)); then
    art_log="${EXPECTED_ARTIFACT_PATHS[*]}"
  fi
  log "step $step_index: runtime=$runtime agent=$agent plan=$plan_abs expected_artifacts=$art_log"

  if [[ "${ORCHESTRATOR_DRY_RUN:-0}" == "1" ]]; then
    echo "DRY RUN step $step_index: $runner_label  --agent $agent --plan $plan_rel"
    if ((${#EXPECTED_ARTIFACT_PATHS[@]:-0} > 0)); then
      echo "  expected artifacts: ${EXPECTED_ARTIFACT_PATHS[*]}"
    fi
    _dry_ack="$(echo "$stage" | jq -r '.humanAck.path // empty' 2>/dev/null)" || _dry_ack=""
    if [[ -n "$_dry_ack" ]]; then
      echo "  humanAck (only if ORCHESTRATOR_HUMAN_ACK=1): $(expand_artifact_tokens "$_dry_ack")"
    fi
    continue
  fi

  echo -e "${C_B}Step ${step_index}${C_RST} ${C_G}$runtime${C_RST} agent=${C_BOLD}$agent${C_RST} plan=$plan_rel"

  _plan_tag_stream="$(basename "$plan_abs" | sed 's/\.[^.]*$//')"
  _plan_tag_stream="${_plan_tag_stream//[^A-Za-z0-9_.-]/_}"
  if [[ "$runtime" == "cursor" ]]; then
    _runner_stream_log="$RALPH_LOG_DIR/cursor/plan-runner-${_plan_tag_stream}-output.log"
  elif [[ "$runtime" == "codex" ]]; then
    _runner_stream_log="$RALPH_LOG_DIR/codex/plan-runner-${_plan_tag_stream}-output.log"
  else
    _runner_stream_log="$RALPH_LOG_DIR/claude/plan-runner-${_plan_tag_stream}-output.log"
  fi

  echo "" >&2
  echo -e "${C_DIM}Invoking:${C_RST} $runner_label" >&2
  echo -e "${C_DIM}  command:${C_RST} bash $runner --non-interactive --plan <plan> --agent $agent <workspace>" >&2
  echo -e "${C_DIM}  orchestrator log (append):${C_RST} $LOG_FILE" >&2
  echo -e "${C_DIM}  per-plan agent output log:${C_RST} $_runner_stream_log" >&2
  echo -e "${C_DIM}--- runner / agent output follows ---${C_RST}" >&2

  set +e
  _runner_env=(
    RALPH_ARTIFACT_NS="$RALPH_ARTIFACT_NS"
    RALPH_PLAN_KEY="$(basename "$plan_abs" | sed 's/\.[^.]*$//;s/[^A-Za-z0-9_.-]/_/g')"
    RALPH_ORCH_FILE="$RALPH_ORCH_FILE"
  )
  if [[ "${ORCHESTRATOR_RUNNER_TO_CONSOLE:-1}" != "0" ]] && [[ -t 1 ]] && command -v tee >/dev/null 2>&1; then
    env "${_runner_env[@]}" bash "$runner" --non-interactive --plan "$plan_abs" --agent "$agent" "$WORKSPACE" 2>&1 | tee -a "$LOG_FILE"
    rc=${PIPESTATUS[0]}
  else
    env "${_runner_env[@]}" bash "$runner" --non-interactive --plan "$plan_abs" --agent "$agent" "$WORKSPACE" >>"$LOG_FILE" 2>&1
    rc=$?
  fi
  set -e

  echo -e "${C_DIM}--- end step $step_index runner output (exit $rc) ---${C_RST}" >&2
  echo "" >&2

  if [[ $rc -ne 0 ]]; then
    plan_tag="$(basename "$plan_abs" | sed 's/\.[^.]*$//')"
    plan_tag="${plan_tag//[^A-Za-z0-9_.-]/_}"
    if [[ "$runtime" == "cursor" ]]; then
      hint_log="$RALPH_LOG_DIR/cursor/plan-runner-${plan_tag}.log"
      hint_out="$RALPH_LOG_DIR/cursor/plan-runner-${plan_tag}-output.log"
    elif [[ "$runtime" == "codex" ]]; then
      hint_log="$RALPH_LOG_DIR/codex/plan-runner-${plan_tag}.log"
      hint_out="$RALPH_LOG_DIR/codex/plan-runner-${plan_tag}-output.log"
    else
      hint_log="$RALPH_LOG_DIR/claude/plan-runner-${plan_tag}.log"
      hint_out="$RALPH_LOG_DIR/claude/plan-runner-${plan_tag}-output.log"
    fi

    log "FAIL step $step_index exit=$rc agent=$agent plan=$plan_abs"
    {
      echo ""
      echo "======== orchestrator failure ========"
      echo "Step:        $step_index"
      echo "Runtime:     $runtime"
      echo "Agent:       $agent"
      echo "Plan file:   $plan_abs"
      echo "Exit code:   $rc"
      echo "Runner:      $runner"
      echo "Orchestrator log: $LOG_FILE"
      echo "Ralph runner log (if present):  $hint_log"
      echo "Ralph agent output log:          $hint_out"
      echo ""
      echo "Remediation:"
      echo "  1. Open the plan file and fix the TODO or environment (CLI login, model, etc.)."
      echo "  2. Read tail of output log: tail -80 \"$hint_out\""
      echo "  3. Re-run from repo root: $0 --orchestration \"$ORCH_FILE\" \"$WORKSPACE\""
      echo "======================================"
    } >> "$LOG_FILE"

    echo "" >&2
    echo -e "${C_R}${C_BOLD}Orchestrator stopped: step $step_index failed (exit $rc)${C_RST}" >&2
    echo "  Runtime: $runtime  Agent: $agent" >&2
    echo "  Plan: $plan_abs" >&2
    echo "  See: $LOG_FILE" >&2
    echo "  Ralph logs: $hint_log / $hint_out" >&2
    exit "$rc"
  fi

  if ((${#EXPECTED_ARTIFACT_PATHS[@]:-0} > 0)); then
    if ! verify_step_artifacts "$step_index"; then
      log "FAIL step $step_index: artifact verification failed (see log for remediation)"
      exit 1
    fi
    log "step $step_index artifact verification OK (${#EXPECTED_ARTIFACT_PATHS[@]:-0} file(s))"
  fi

  human_ack_rel="$(echo "$stage" | jq -r '.humanAck.path // empty' 2>/dev/null)" || human_ack_rel=""
  if [[ -n "$human_ack_rel" && "${ORCHESTRATOR_HUMAN_ACK:-0}" == "1" ]]; then
    human_ack_rel="$(expand_artifact_tokens "$human_ack_rel")"
    if [[ "$human_ack_rel" == /* ]]; then
      human_ack_abs="$human_ack_rel"
    else
      human_ack_abs="$WORKSPACE/$human_ack_rel"
    fi
    ralph_assert_path_not_env_secret "Human ack file" "$human_ack_abs"
    if [[ ! -f "$human_ack_abs" ]]; then
      human_ack_msg="$(echo "$stage" | jq -r '.humanAck.message // empty' 2>/dev/null)" || human_ack_msg=""
      log "HUMAN_ACK step $step_index: paused until ack file exists: $human_ack_abs"
      echo "" >&2
      echo -e "${C_Y}${C_BOLD}Human acknowledgment required before the next stage${C_RST}" >&2
      echo "  Stage: $step_index ($agent)" >&2
      echo "  Review the stage outputs (e.g. open questions in research.md)." >&2
      echo "  When you have answered, edited the artifact, or explicitly accepted remaining items," >&2
      echo "  create the ack file (empty file is enough):" >&2
      echo "" >&2
      echo -e "    ${C_B}mkdir -p \"$(dirname "$human_ack_abs")\" && touch \"$human_ack_abs\"${C_RST}" >&2
      echo "" >&2
      if [[ -n "$human_ack_msg" ]]; then
        echo "$human_ack_msg" >&2
        echo "" >&2
      fi
      echo "  Then re-run the orchestrator with ORCHESTRATOR_HUMAN_ACK=1 from the repo root." >&2
      echo "  To run without gates, omit ORCHESTRATOR_HUMAN_ACK (default)." >&2
      echo "  Log: $LOG_FILE" >&2
      exit 3
    fi
    log "humanAck OK: $human_ack_abs"
  fi

  # Check for loop control (feedback loops for code review, etc.)
  # (Must not use "local" here: this block is in a top-level for-loop, not a function.)
  loop_decision="proceed"
  if [[ "$agent" == "code-review" ]] || echo "$stage" | jq -e '.loopControl' >/dev/null 2>&1; then
    loop_artifact="${EXPECTED_ARTIFACT_PATHS[0]-}"
    loop_result="$(check_loop_condition "$stage" "$loop_artifact" 2>/dev/null)" || loop_result="proceed"

    if [[ "$loop_result" == loop:* ]]; then
      loop_decision="$loop_result"
      IFS=: read -r _ loop_back_agent loop_iter <<< "$loop_result"
      log "step $step_index triggers loop back to $loop_back_agent (iteration $loop_iter)"
      echo -e "${C_Y}Step $step_index completed with feedback loop.${C_RST}"
      echo -e "${C_Y}Looping back to: $loop_back_agent (iteration $loop_iter)${C_RST}"

      # Mark this for resuming at the loop-back stage on next run
      # (In practice, user would re-run orchestrator; the JSON would stay the same)
      continue  # Skip to next stage in array (will be processed in order)
    fi
  fi

  log "step $step_index OK"
  echo -e "${C_G}Step $step_index completed.${C_RST}"
  done
else
  log "FAIL: orchestration file must be JSON (.orch.json)"
  echo -e "${C_R}${C_BOLD}Error: orchestration file must be JSON${C_RST}" >&2
  echo "  Expected: .orch.json (JSON format)" >&2
  echo "  Got: $(basename "$ORCH_FILE")" >&2
  echo "  See .ralph/orchestration.template.json" >&2
  echo "  Log: $LOG_FILE" >&2
  exit 1
fi

if [[ $step_index -eq 0 ]]; then
  log "FAIL: no stages found in $ORCH_FILE"
  echo -e "${C_R}No valid stages in orchestration file.${C_RST}" >&2
  echo "  Check the 'stages' array in your JSON file." >&2
  echo "  Template: .ralph/orchestration.template.json" >&2
  echo "  Log: $LOG_FILE" >&2
  exit 1
fi

if [[ "${ORCHESTRATOR_DRY_RUN:-0}" == "1" ]]; then
  log "dry-run complete ($step_index steps)"
  exit 0
fi

log "orchestrator complete ($step_index steps)"
echo -e "${C_G}${C_BOLD}Orchestration complete${C_RST} ($step_index steps). Log: $LOG_FILE"
exit 0
