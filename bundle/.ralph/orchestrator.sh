#!/usr/bin/env bash
# Canonical Ralph orchestrator (repo root: .ralph/orchestrator.sh). Dispatches each JSON
# stage to `.ralph/run-plan.sh` with per-stage `--runtime`, `--plan` (from the stage), and `--agent`.
# Master orchestrator: read a JSON orchestration plan, run each step in order via Ralph
# (unified run-plan; `--plan` is always passed). Stops on first failure
# and writes actionable logs under .ralph-workspace/logs/orchestrator-*.log.
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
#         "runtime": "cursor", "claude", "codex", "opencode", or "antigravity" (optional, default: cursor),
#         "plan": "path/to/stage-plan.md",
#         "mcpProxyPolicy": "readonly" (optional; forwarded to RALPH_MCP_PROXY_POLICY for that stage),
#         "planTemplate": "path/to/stage-plan.template.md (optional)",
#         "sessionStrategy": "fresh" | "resume" | "reset" (optional; preferred),
#         "sessionResume": true or false (optional legacy fallback; mapped to session strategy resume/fresh),
#         "inputArtifacts": ["path/to/{{ARTIFACT_NS}}/input.md"],
#         "outputArtifacts": [
#           "path/to/{{ARTIFACT_NS}}/output.md"
#         ],
#         "artifacts": [
#           {
#             "path": ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/output.md",
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
#   .ralph/orchestrator.sh docs/orchestration-plans/my-feature/my-feature.orch.json
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
# Optional per-stage JSON field humanAck: enforced only when ORCHESTRATOR_HUMAN_ACK=1. Artifacts live under .ralph-workspace/artifacts/.
#
# When stdout is a TTY and ORCHESTRATOR_RUNNER_TO_CONSOLE is not 0, each step streams the Ralph runner
# (.ralph/run-plan.sh and agent CLI output) to the console as well as appending to the orchestrator log.

set -euo pipefail

RALPH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# High-level flow: parse CLI -> load JSON -> for each stage: resolve artifacts,
# ensure plan file (template copy if missing), run .ralph/run-plan.sh non-interactively,
# verify required output files, optional humanAck gate, optional loop back to an earlier stage.
# ---------------------------------------------------------------------------

WORKSPACE="$(pwd)"
WORKSPACE_ROOT_OVERRIDE=""
ORCH_FILE=""

# Single-stage mode: execute exactly one stage and emit a StageOutcomeReport.
# When SINGLE_STAGE_MODE=1 the orchestrator routes into the per-stage function,
# skips stage-index advancement, router/planner application, loopControl,
# parallel wave scheduling, and humanAck waiting. Ordinary mode leaves these
# variables at their defaults and follows the same code path as before.
SINGLE_STAGE_MODE=0
SINGLE_STAGE_ID=""
SINGLE_STAGE_RUN_ID=""
SINGLE_STAGE_ATTEMPT_ID=""
SINGLE_STAGE_STARTED_AT=""
SINGLE_STAGE_REPORT_WRITTEN=0

usage() {
  echo "Usage: $0 --orchestration <orchestration_plan.orch.json> [workspace_dir]" >&2
  echo "   or: $0 <orchestration_plan.orch.json> [workspace_dir]" >&2
  echo "Optional: append --workspace-root <path> to set a custom .ralph-workspace location" >&2
  echo "Single stage: --single-stage <stageId> --run-id <runId> --attempt-id <attemptId>" >&2
  echo "              executes exactly one stage and writes a StageOutcomeReport." >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  --workspace-root)
    [[ -n "${2:-}" ]] || usage
    WORKSPACE_ROOT_OVERRIDE="$2"
    shift 2
    ;;
  --orchestration|-f)
      [[ -n "${2:-}" ]] || usage
      ORCH_FILE="$2"
      shift 2
      ;;
  --single-stage)
      [[ -n "${2:-}" ]] || usage
      SINGLE_STAGE_ID="$2"
      SINGLE_STAGE_MODE=1
      shift 2
      ;;
  --run-id)
      [[ -n "${2:-}" ]] || usage
      SINGLE_STAGE_RUN_ID="$2"
      shift 2
      ;;
  --attempt-id)
      [[ -n "${2:-}" ]] || usage
      SINGLE_STAGE_ATTEMPT_ID="$2"
      shift 2
      ;;
    -h|--help)
    echo "Usage: $0 --orchestration <orchestration_plan.orch.json> [workspace_dir]"
    echo "   or: $0 <orchestration_plan.orch.json> [workspace_dir]"
    echo "Optional: --workspace-root <path> overrides .ralph-workspace location"
      exit 0
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

# Positional args: first existing file becomes ORCH_FILE; optional directory becomes WORKSPACE.
if [[ -z "$ORCH_FILE" ]]; then
  usage
fi

if [[ "$SINGLE_STAGE_MODE" == "1" ]]; then
  if [[ -z "$SINGLE_STAGE_RUN_ID" || -z "$SINGLE_STAGE_ATTEMPT_ID" ]]; then
    echo "Orchestrator error: --single-stage requires --run-id and --attempt-id" >&2
    usage
  fi
  SINGLE_STAGE_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fi

if [[ "$ORCH_FILE" != /* ]]; then
  ORCH_FILE="$(cd "$(dirname "$ORCH_FILE")" && pwd)/$(basename "$ORCH_FILE")"
fi

# Lets run-plan and human-interaction helpers know which orchestration is active.
export RALPH_ORCH_FILE="$ORCH_FILE"

if [[ ! -f "$ORCH_FILE" ]]; then
  echo "Orchestrator error: orchestration file not found: $ORCH_FILE" >&2
  exit 1
fi

if [[ -n "${WORKSPACE_ROOT_OVERRIDE:-}" ]]; then
  WORKSPACE_ROOT_OVERRIDE="$(cd "$WORKSPACE_ROOT_OVERRIDE" && pwd)"
fi
WORKSPACE="$(cd "$WORKSPACE" && pwd)"
RALPH_ACTIVE_DIR="$RALPH_DIR"
if [[ -f "$WORKSPACE/.ralph/run-plan.sh" && -f "$WORKSPACE/.ralph/ralph-env-safety.sh" ]]; then
  RALPH_ACTIVE_DIR="$WORKSPACE/.ralph"
fi
if [[ ! -f "$RALPH_ACTIVE_DIR/ralph-env-safety.sh" ]]; then
  echo "Orchestrator error: expected $RALPH_ACTIVE_DIR/ralph-env-safety.sh (Ralph tooling)." >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$RALPH_ACTIVE_DIR/ralph-env-safety.sh"
ralph_assert_path_not_env_secret "Orchestration file" "$ORCH_FILE"
# Logs and per-plan artifacts live here; same root run-plan uses when invoked from orchestrator.
DEFAULT_ORCH_WORKSPACE_ROOT="$WORKSPACE/.ralph-workspace"
if [[ -n "${WORKSPACE_ROOT_OVERRIDE:-}" ]]; then
  DEFAULT_ORCH_WORKSPACE_ROOT="$WORKSPACE_ROOT_OVERRIDE"
fi
export RALPH_PLAN_WORKSPACE_ROOT="$DEFAULT_ORCH_WORKSPACE_ROOT"
export RALPH_PROJECT_ROOT="$WORKSPACE"
RALPH_LOG_DIR="$RALPH_PLAN_WORKSPACE_ROOT/logs"
mkdir -p "$RALPH_LOG_DIR"
ORCH_BASENAME="$(basename "$ORCH_FILE" | sed 's/\.[^.]*$//')"
ORCH_BASENAME="${ORCH_BASENAME//[^A-Za-z0-9_.-]/_}"
LOG_FILE="$RALPH_LOG_DIR/orchestrator-${ORCH_BASENAME}.log"
# Ensure the log path exists before the first append (some environments rely on the file for smoke checks).
touch "$LOG_FILE"
RALPH_RUN_PLAN="$RALPH_ACTIVE_DIR/run-plan.sh"
# Populated per stage from JSON (and sometimes merged from agent config); cleared each iteration.
EXPECTED_ARTIFACT_PATHS=()

ralph_orchestrator_timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

# Used by merge_required_artifacts_from_agent when a stage omits explicit artifacts.
if [[ -f "$RALPH_ACTIVE_DIR/agent-config-tool.sh" ]]; then
  AGENT_CONFIG_TOOL_SH="$RALPH_ACTIVE_DIR/agent-config-tool.sh"
else
  AGENT_CONFIG_TOOL_SH=""
fi

# expand_artifact_tokens, merge_required_artifacts_from_agent, orchestrator_validate_runtime, etc.
# shellcheck source=/dev/null
source "$RALPH_ACTIVE_DIR/bash-lib/runtime-resolve.sh"
# shellcheck source=/dev/null
if ! declare -F expand_artifact_tokens >/dev/null 2>&1; then
  _artifacts_source="$RALPH_ACTIVE_DIR/bash-lib/artifacts.sh"
  if [[ ! -f "$_artifacts_source" && -f "$RALPH_DIR/bash-lib/artifacts.sh" ]]; then
    _artifacts_source="$RALPH_DIR/bash-lib/artifacts.sh"
  fi
  source "$_artifacts_source"
  unset _artifacts_source
fi
# shellcheck source=bash-lib/orchestrator/orchestrator-lib.sh
source "$RALPH_ACTIVE_DIR/bash-lib/orchestrator/orchestrator-lib.sh"
# shellcheck source=/dev/null
source "$RALPH_ACTIVE_DIR/bash-lib/ralph-format-elapsed.sh"
# shellcheck source=bash-lib/orchestrator/orchestrator-handoffs.sh
source "$RALPH_ACTIVE_DIR/bash-lib/orchestrator/orchestrator-handoffs.sh"
# shellcheck source=/dev/null
source "$RALPH_ACTIVE_DIR/bash-lib/review-status.sh"
if [[ -f "$RALPH_ACTIVE_DIR/bash-lib/rubric-grader.sh" ]]; then
  # shellcheck source=/dev/null
  source "$RALPH_ACTIVE_DIR/bash-lib/rubric-grader.sh"
fi
if [[ -f "$RALPH_ACTIVE_DIR/bash-lib/orchestrator/orchestrator-router.sh" ]]; then
  # shellcheck source=/dev/null
  source "$RALPH_ACTIVE_DIR/bash-lib/orchestrator/orchestrator-router.sh"
fi
if [[ -f "$RALPH_ACTIVE_DIR/bash-lib/orchestrator/orchestrator-planner.sh" ]]; then
  # shellcheck source=/dev/null
  source "$RALPH_ACTIVE_DIR/bash-lib/orchestrator/orchestrator-planner.sh"
fi
if [[ -f "$RALPH_ACTIVE_DIR/bash-lib/run-plan/run-plan-structured-output.sh" ]]; then
  # shellcheck source=/dev/null
  source "$RALPH_ACTIVE_DIR/bash-lib/run-plan/run-plan-structured-output.sh"
fi

# Shared process teardown helpers: kill process trees, process groups, and reap.
# shellcheck source=/dev/null
source "$RALPH_ACTIVE_DIR/bash-lib/ralph-process-teardown.sh"

# ---------------------------------------------------------------------------
# Process tracking and signal handling for sequential + parallel stages.
# ---------------------------------------------------------------------------
ORCH_RUNNER_PID=""           # PID of the active sequential run-plan child
ORCH_PARALLEL_PIDS=()        # PIDs of background parallel-wave stage wrappers
ORCH_INTERRUPT_SIGNAL=""     # INT / TERM / HUP received
ORCH_TEARDOWN_DONE=0

orch_record_runner_pid() {
  local pid="$1"
  ORCH_RUNNER_PID="$pid"
}

orch_clear_runner_pid() {
  ORCH_RUNNER_PID=""
}

orch_register_parallel_pid() {
  local pid="$1"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  ORCH_PARALLEL_PIDS+=("$pid")
}

orch_clear_parallel_pids() {
  ORCH_PARALLEL_PIDS=()
}

orch_reap_parallel_pids() {
  local pid
  for pid in "${ORCH_PARALLEL_PIDS[@]}"; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    ralph_kill_tree_and_reap "$pid" 2>/dev/null || true
  done
  orch_clear_parallel_pids
}

# Teardown all tracked processes on INT/TERM/HUP. Idempotent and safe to call
# from traps or normal cleanup.
orch_interrupt_teardown() {
  local signal="${1:-INT}"
  if [[ "$ORCH_TEARDOWN_DONE" -eq 1 ]]; then
    return 0
  fi
  ORCH_TEARDOWN_DONE=1
  ORCH_INTERRUPT_SIGNAL="$signal"

  ralph_orchestrator_log "orchestrator received signal ${signal}; tearing down tracked processes"

  # Stop the active sequential runner and reap it.
  if [[ "$ORCH_RUNNER_PID" =~ ^[0-9]+$ ]] && kill -0 "$ORCH_RUNNER_PID" 2>/dev/null; then
    ralph_kill_tree_and_reap "$ORCH_RUNNER_PID" 2>/dev/null || true
  fi
  orch_clear_runner_pid

  # Stop every active parallel-wave stage wrapper and reap it.
  orch_reap_parallel_pids

  # Signal-appropriate exit code: INT=130, TERM=143, HUP=129.
  local exit_code
  case "$signal" in
    INT)  exit_code=130 ;;
    TERM) exit_code=143 ;;
    HUP)  exit_code=129 ;;
    *)    exit_code=$(( 128 + $(kill -l "$signal" 2>/dev/null || echo 1) )) ;;
  esac
  exit "$exit_code"
}

orch_signal_handler() {
  local signal="$1"
  # Reset trap to default so a second signal kills us immediately.
  case "$signal" in
    INT)  trap - INT ;;
    TERM) trap - TERM ;;
    HUP)  trap - HUP ;;
  esac
  orch_interrupt_teardown "$signal"
}

trap 'orch_signal_handler INT' INT
trap 'orch_signal_handler TERM' TERM
trap 'orch_signal_handler HUP' HUP

# ---------------------------------------------------------------------------
# Single-stage StageOutcomeReport emission.
#
# The report matches shared/src/models/orchestration.model.ts::StageOutcomeReport
# and is persisted at
#   <workspaceRoot>/artifacts/<artifactNs>/stage-outcomes/<attemptId>.json
# so loop/retry attempts never overwrite each other. JSON is built with jq
# (never echo interpolation), written to a temp file, fsync'd when a platform
# utility supports it, then atomically renamed into place.
# ---------------------------------------------------------------------------
orch_single_stage_report_path() {
  [[ -n "${RALPH_PLAN_WORKSPACE_ROOT:-}" && -n "${RALPH_ARTIFACT_NS:-}" && -n "$SINGLE_STAGE_ATTEMPT_ID" ]] || return 1
  printf '%s/artifacts/%s/stage-outcomes/%s.json' \
    "$RALPH_PLAN_WORKSPACE_ROOT" "$RALPH_ARTIFACT_NS" "$SINGLE_STAGE_ATTEMPT_ID"
}

# Best-effort durable flush of a single file. Prefers a real per-file fsync via
# python3; falls back to sync(1) when present. Never fails the caller.
orch_fsync_path() {
  local target="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$target" <<'PY' 2>/dev/null || true
import os, sys
p = sys.argv[1]
try:
    fd = os.open(p, os.O_RDONLY)
except OSError:
    sys.exit(0)
try:
    os.fsync(fd)
finally:
    os.close(fd)
PY
  elif command -v sync >/dev/null 2>&1; then
    sync 2>/dev/null || true
  fi
}

orch_single_stage_write_report() {
  local outcome="$1" exit_code="$2" reason="${3:-}"
  [[ "${SINGLE_STAGE_MODE:-0}" == "1" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 1
  [[ "$exit_code" =~ ^-?[0-9]+$ ]] || exit_code=1
  local report_path report_dir tmp_file finished_at
  report_path="$(orch_single_stage_report_path)" || return 1
  report_dir="$(dirname "$report_path")"
  mkdir -p "$report_dir" 2>/dev/null || return 1
  finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  tmp_file="$(mktemp "$report_dir/.stage-outcome-XXXXXX" 2>/dev/null)" || return 1
  if ! jq -n \
    --argjson schemaVersion 1 \
    --arg runId "$SINGLE_STAGE_RUN_ID" \
    --arg stageId "$SINGLE_STAGE_ID" \
    --arg attemptId "$SINGLE_STAGE_ATTEMPT_ID" \
    --arg outcome "$outcome" \
    --argjson exitCode "$exit_code" \
    --arg startedAt "${SINGLE_STAGE_STARTED_AT:-$finished_at}" \
    --arg finishedAt "$finished_at" \
    --arg reason "$reason" \
    '{schemaVersion: $schemaVersion, runId: $runId, stageId: $stageId, attemptId: $attemptId, outcome: $outcome, exitCode: $exitCode, startedAt: $startedAt, finishedAt: $finishedAt}
       + (if $reason == "" then {} else {reason: $reason} end)' \
    > "$tmp_file" 2>/dev/null; then
    rm -f "$tmp_file" 2>/dev/null || true
    return 1
  fi
  orch_fsync_path "$tmp_file"
  if ! mv -f "$tmp_file" "$report_path" 2>/dev/null; then
    rm -f "$tmp_file" 2>/dev/null || true
    return 1
  fi
  orch_fsync_path "$report_dir"
  SINGLE_STAGE_REPORT_WRITTEN=1
  return 0
}

# EXIT trap for single-stage mode: if the stage terminated before a report was
# written (runner failure, artifact failure, or a signal), emit a failed or
# cancelled report using the process exit code, without masking it.
orch_single_stage_exit_trap() {
  local ec=$?
  if [[ "${SINGLE_STAGE_MODE:-0}" == "1" && "${SINGLE_STAGE_REPORT_WRITTEN:-0}" != "1" ]]; then
    local outcome="failed" reason="stage terminated before completion"
    if [[ -n "${ORCH_INTERRUPT_SIGNAL:-}" ]]; then
      outcome="cancelled"
      reason="received signal ${ORCH_INTERRUPT_SIGNAL}"
    fi
    orch_single_stage_write_report "$outcome" "$ec" "$reason" || true
  fi
  return "$ec"
}

if [[ "${SINGLE_STAGE_MODE:-0}" == "1" ]]; then
  trap 'orch_single_stage_exit_trap' EXIT
fi

# Inlined here (not only bash-lib/orchestrator-verify.sh) so this script stays self-contained for operators.
artifact_remediation_text() {
  echo "  Remediation:"
  echo "    1. Open the step plan and ensure the agent finished every TODO (agent should write declared outputs)."
  echo "    2. Create or fill the missing path under the repo root (see .ralph-workspace/artifacts/ for handoff files)."
  echo "    3. To require different files for this step, edit artifacts or outputArtifacts in the JSON stage"
  echo "       or adjust output_artifacts in the agent config."
  echo "    4. Re-run from repo root: $0 --orchestration \"$ORCH_FILE\" \"$WORKSPACE\""
}

# After each successful delegated run: each expected artifact must exist and be non-empty.
verify_step_artifacts() {
  local step_n="$1"
  local ap abs
  if ((${#EXPECTED_ARTIFACT_PATHS[@]} > 0)); then
    for ap in "${EXPECTED_ARTIFACT_PATHS[@]}"; do
    if [[ "$ap" == /* ]]; then
      abs="$ap"
    else
      abs="$WORKSPACE/$ap"
    fi
    if [[ ! -f "$abs" ]]; then
      ralph_orchestrator_log "FAIL step $step_n artifact check: missing file: $ap (resolved: $abs)"
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
      ralph_orchestrator_log "FAIL step $step_n artifact check: empty file: $ap (resolved: $abs)"
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
# Uses the shared helper from review-status.sh
extract_review_status() {
  local review_file="$1"
  ralph_extract_review_status "$review_file"
}

# Check if stage should loop back to a previous stage.
# Emits one of: "proceed", "loop:<stage>:<iter>", or "exhausted:<onExhausted>".
check_loop_condition() {
  local stage_json="$1"
  local review_file="$2"

  # If no loopControl defined, proceed forward
  local loop_back="$(echo "$stage_json" | jq -r '.loopControl.loopBackTo // empty' 2>/dev/null)" || loop_back=""
  [[ -z "$loop_back" ]] && echo "proceed" && return 0

  # Resolve an evaluator schema (project-root-relative) when declared. When present
  # and the JSON-contract gate is enabled, parse only the validated JSON contract.
  local evaluator_schema evaluator_schema_abs=""
  evaluator_schema="$(echo "$stage_json" | jq -r '.loopControl.evaluatorSchema // empty' 2>/dev/null)" || evaluator_schema=""
  if [[ -n "$evaluator_schema" ]]; then
    if [[ "$evaluator_schema" == /* ]]; then
      evaluator_schema_abs="$evaluator_schema"
    else
      evaluator_schema_abs="$WORKSPACE/$evaluator_schema"
    fi
  fi

  # Check review status (schema-aware; falls back to legacy markdown when no schema).
  local status="$(ralph_extract_review_status_with_schema "$review_file" "$evaluator_schema_abs" 2>/dev/null)" || status="unknown"
  local max_iter="$(echo "$stage_json" | jq -r '.loopControl.maxIterations // 3' 2>/dev/null)" || max_iter=3
  local on_exhausted="$(echo "$stage_json" | jq -r '.loopControl.onExhausted // empty' 2>/dev/null)" || on_exhausted=""
  local current_iter="${STAGE_ITERATION:-1}"

  if [[ "$status" == "approved" ]]; then
    echo "proceed"
  elif (( current_iter < max_iter )); then
    echo "loop:$loop_back:$((current_iter + 1))"
  else
    # Max iterations reached while still requiring changes.
    if [[ "$on_exhausted" == "proceed" ]]; then
      echo "proceed"
    else
      echo "exhausted:${on_exhausted:-fail}"
    fi
  fi
}

# Bash 3.2 (macOS /bin/bash): no associative arrays. Parallel-array maps for stage id lookups.
ORCH_STAGE_INDEX_KEYS=()
ORCH_STAGE_INDEX_VALS=()
ORCH_STAGE_ITER_KEYS=()
ORCH_STAGE_ITER_VALS=()

orch_stage_index_map_set() {
  local key="$1" val="$2" i
  for ((i = 0; i < ${#ORCH_STAGE_INDEX_KEYS[@]}; i++)); do
    if [[ "${ORCH_STAGE_INDEX_KEYS[$i]}" == "$key" ]]; then
      ORCH_STAGE_INDEX_VALS[$i]="$val"
      return 0
    fi
  done
  ORCH_STAGE_INDEX_KEYS+=("$key")
  ORCH_STAGE_INDEX_VALS+=("$val")
}

orch_stage_index_map_get() {
  local key="$1" i
  for ((i = 0; i < ${#ORCH_STAGE_INDEX_KEYS[@]}; i++)); do
    if [[ "${ORCH_STAGE_INDEX_KEYS[$i]}" == "$key" ]]; then
      printf '%s\n' "${ORCH_STAGE_INDEX_VALS[$i]}"
      return 0
    fi
  done
  return 1
}

orch_stage_iteration_map_set() {
  local key="$1" val="$2" i
  for ((i = 0; i < ${#ORCH_STAGE_ITER_KEYS[@]}; i++)); do
    if [[ "${ORCH_STAGE_ITER_KEYS[$i]}" == "$key" ]]; then
      ORCH_STAGE_ITER_VALS[$i]="$val"
      return 0
    fi
  done
  ORCH_STAGE_ITER_KEYS+=("$key")
  ORCH_STAGE_ITER_VALS+=("$val")
}

orch_stage_iteration_map_get() {
  local key="$1" i
  for ((i = 0; i < ${#ORCH_STAGE_ITER_KEYS[@]}; i++)); do
    if [[ "${ORCH_STAGE_ITER_KEYS[$i]}" == "$key" ]]; then
      printf '%s\n' "${ORCH_STAGE_ITER_VALS[$i]}"
      return 0
    fi
  done
  printf '%s\n' "1"
}

orch_stage_normalize_id() {
  local stage_id="$1"
  stage_id="$(printf '%s' "$stage_id" | tr '[:upper:]' '[:lower:]')"
  stage_id="$(printf '%s' "$stage_id" | tr -c 'a-z0-9-' '-')"
  stage_id="$(printf '%s' "$stage_id" | sed 's/-\+/-/g; s/^-//; s/-$//')"
  printf '%s\n' "$stage_id"
}

orch_stage_collect_expected_artifacts() {
  local stage_json="$1"
  local agent="$2"
  local runtime="$3"
  local stage_has_artifacts=0
  local artifacts_array artifact_path

  EXPECTED_ARTIFACT_PATHS=()
  artifacts_array="$(echo "$stage_json" | jq '.artifacts // []' 2>/dev/null)" || artifacts_array="[]"
  while IFS= read -r artifact_path; do
    [[ -z "$artifact_path" ]] && continue
    artifact_paths_append_unique "$artifact_path"
    stage_has_artifacts=1
  done < <(echo "$artifacts_array" | jq -r '.[] | select(.required == true) | .path' 2>/dev/null)
  while IFS= read -r artifact_path; do
    [[ -z "$artifact_path" ]] && continue
    artifact_paths_append_unique "$artifact_path"
    stage_has_artifacts=1
  done < <(echo "$stage_json" | jq -r '.outputArtifacts[]? | select(.required == true) | .path' 2>/dev/null)

  if [[ "$agent_source" == "prebuilt" && "$stage_has_artifacts" -eq 0 ]]; then
    merge_required_artifacts_from_agent "$agent" "$runtime"
  fi
}

orch_stage_capture_usage() {
  local step_n="$1"
  local agent="$2"
  local runtime="$3"
  local usage_file="$4"
  local stage_usage_file="${5:-}"
  local s_in s_out s_cc s_cr

  if [[ -f "$usage_file" ]] && command -v python3 >/dev/null 2>&1; then
    s_in="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('input_tokens',0))" "$usage_file" 2>/dev/null || echo 0)"
    s_out="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('output_tokens',0))" "$usage_file" 2>/dev/null || echo 0)"
    s_cc="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('cache_creation_input_tokens',0))" "$usage_file" 2>/dev/null || echo 0)"
    s_cr="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('cache_read_input_tokens',0))" "$usage_file" 2>/dev/null || echo 0)"
    if [[ -n "$stage_usage_file" ]]; then
      mkdir -p "$(dirname "$stage_usage_file")"
      cat > "$stage_usage_file" << _STAGE_USAGE_EOF
{"step":${step_n},"agent":"${agent}","runtime":"${runtime}","input_tokens":${s_in},"output_tokens":${s_out},"cache_creation_input_tokens":${s_cc},"cache_read_input_tokens":${s_cr}}
_STAGE_USAGE_EOF
    else
      _orch_input_tokens=$(( _orch_input_tokens + s_in ))
      _orch_output_tokens=$(( _orch_output_tokens + s_out ))
      _orch_cache_creation_tokens=$(( _orch_cache_creation_tokens + s_cc ))
      _orch_cache_read_tokens=$(( _orch_cache_read_tokens + s_cr ))
      _orch_stage_usages+="${_orch_stage_usages:+,}{\"step\":${step_n},\"agent\":\"${agent}\",\"runtime\":\"${runtime}\",\"input_tokens\":${s_in},\"output_tokens\":${s_out},\"cache_creation_input_tokens\":${s_cc},\"cache_read_input_tokens\":${s_cr}}"
      ralph_orchestrator_log "step $step_n usage: input=${s_in} output=${s_out} cache_create=${s_cc} cache_read=${s_cr}"
    fi
  fi
}

orch_stage_execute() {
  local step_n="$1"
  local stage="$2"
  local plan_abs="$3"
  local plan_rel="$4"
  local runtime="$5"
  local agent="$6"
  local agent_source="$7"
  local stage_model="$8"
  local agent_source_raw="$9"
  local planTemplate="${10}"
  local stage_id="${11}"
  local stage_iter="${12}"
  local step_status_var="${13}"
  local stage_usage_file="${14:-}"
  local stage_index="${15:-0}"
  local stage_context_budget=""
  local stage_mcp_proxy_policy=""
  local stage_mcp_proxy_policy_type=""
  stage_context_budget="$(echo "$stage" | jq -r '.contextBudget // ""' 2>/dev/null)" || stage_context_budget=""
  local plan_abs_file="$plan_abs"
  local step_status=0
  local runner="$RALPH_RUN_PLAN"
  local runner_label=".ralph/run-plan.sh (runtime=$runtime)"
  local human_ack_rel human_ack_abs human_ack_msg runtime_root agent_template_dir
  local _dry_sr _dry_model_label _step_model_label _plan_tag_stream _runner_stream_log _runner_env _runner_args _art_check
  local _session_strategy_cli=()
  local _session_strategy_type _session_strategy_value
  local _session_resume_type _session_resume_value
  local _stage_usage_file=""

  export STAGE_ITERATION="$stage_iter"
  export RALPH_STAGE_ID="$stage_id"
  orch_stage_collect_expected_artifacts "$stage" "$agent" "$runtime"

  if ! orchestrator_validate_stage_agent_plan "$agent" "$plan_rel"; then
    ralph_orchestrator_log "FAIL parse: empty agent or plan for stage JSON: $stage"
    echo -e "${C_R}Empty agent or plan path.${C_RST} Log: $LOG_FILE" >&2
    printf -v "$step_status_var" '%s' 1
    return 1
  fi

  if [[ ! -f "$runner" ]]; then
    ralph_orchestrator_log "FAIL step $step_n: runner missing: $runner"
    echo -e "${C_R}${C_BOLD}Orchestrator aborted before step $step_n${C_RST}" >&2
    echo "  Runner not found: $runner" >&2
    echo "  Install Ralph shared bundle (.ralph/) so run-plan.sh exists, then retry." >&2
    echo "  Log: $LOG_FILE" >&2
    printf -v "$step_status_var" '%s' 1
    return 1
  fi

  ralph_assert_path_not_env_secret "Step plan" "$plan_abs_file"
  if ((${#EXPECTED_ARTIFACT_PATHS[@]} > 0)); then
    for _art_check in "${EXPECTED_ARTIFACT_PATHS[@]}"; do
      ralph_assert_path_not_env_secret "Expected artifact" "$_art_check"
    done
  fi

  if [[ ! -f "$plan_abs_file" ]]; then
    plan_dir="$(dirname "$plan_abs_file")"
    mkdir -p "$plan_dir"
    template_to_use=""
    if [[ -n "$planTemplate" ]]; then
      if [[ "$planTemplate" != /* ]]; then
        template_to_use="$WORKSPACE/$planTemplate"
      else
        template_to_use="$planTemplate"
      fi
    fi
    if [[ -z "$template_to_use" ]] || [[ ! -f "$template_to_use" ]]; then
      agent_template_dir="${ralph_plan_templates_dir:-$RALPH_ACTIVE_DIR/plan-templates}"
      if [[ -n "$agent_template_dir" && -f "$agent_template_dir/$agent.plan.template.md" ]]; then
        template_to_use="$agent_template_dir/$agent.plan.template.md"
      elif [[ -f "$RALPH_ACTIVE_DIR/plan-templates/classic.plan.template.md" ]]; then
        template_to_use="$RALPH_ACTIVE_DIR/plan-templates/classic.plan.template.md"
      fi
    fi
    if [[ -f "$template_to_use" ]]; then
      cp "$template_to_use" "$plan_abs_file"
      ralph_orchestrator_log "auto-created plan file from template: $plan_abs_file"
      echo -e "${C_Y}Step $step_n: auto-created plan file${C_RST}" >&2
      echo "  Source template: $(basename "$template_to_use")" >&2
      echo "  Created: $plan_abs_file" >&2
      echo "  Review and edit the plan, then re-run the orchestrator." >&2
      echo "  Log: $LOG_FILE" >&2
      printf -v "$step_status_var" '%s' 0
      return 0
    fi
    ralph_orchestrator_log "FAIL step $step_n: plan file not found and no template available: $plan_abs_file"
    echo -e "${C_R}${C_BOLD}Step $step_n failed (plan missing)${C_RST}" >&2
    echo "  Agent: $agent  Runtime: $runtime" >&2
    echo "  Plan path: $plan_abs_file" >&2
    echo "  Log: $LOG_FILE" >&2
    printf -v "$step_status_var" '%s' 1
    return 1
  fi

  art_log="(none)"
  if ((${#EXPECTED_ARTIFACT_PATHS[@]} > 0)); then
    art_log="${EXPECTED_ARTIFACT_PATHS[*]}"
  fi
  ralph_orchestrator_log "step $step_n: runtime=$runtime agent=$agent agent_source=$agent_source plan=$plan_abs_file expected_artifacts=$art_log"

  _session_strategy_type="$(echo "$stage" | jq -r 'if has("sessionStrategy") then (.sessionStrategy|type) else "absent" end' 2>/dev/null || echo "error")"
  if [[ "$_session_strategy_type" == "string" ]]; then
    _session_strategy_value="$(echo "$stage" | jq -r '.sessionStrategy' 2>/dev/null || echo "")"
    case "$_session_strategy_value" in
      fresh|resume|reset|compact)
        _session_strategy_cli+=(--session-strategy "$_session_strategy_value")
        ;;
      *)
        ralph_orchestrator_log "FAIL step $step_n: sessionStrategy must be one of fresh|resume|reset|compact (got $_session_strategy_value)"
        echo -e "${C_R}${C_BOLD}Step $step_n failed (invalid sessionStrategy)${C_RST}" >&2
        echo "  sessionStrategy must be one of fresh, resume, reset, or compact in $ORCH_FILE." >&2
        echo "  Log: $LOG_FILE" >&2
        printf -v "$step_status_var" '%s' 1
        return 1
        ;;
    esac
  elif [[ "$_session_strategy_type" == "absent" ]]; then
    _session_resume_type="$(echo "$stage" | jq -r 'if has("sessionResume") then (.sessionResume|type) else "absent" end' 2>/dev/null || echo "error")"
    if [[ "$_session_resume_type" == "boolean" ]]; then
      _session_resume_value="$(echo "$stage" | jq -r '.sessionResume' 2>/dev/null || echo "false")"
      if [[ "$_session_resume_value" == "true" ]]; then
        _session_strategy_cli+=(--session-strategy resume)
      else
        _session_strategy_cli+=(--session-strategy fresh)
      fi
    elif [[ "$_session_resume_type" != "absent" ]]; then
      ralph_orchestrator_log "FAIL step $step_n: sessionResume must be a boolean (got $_session_resume_type)"
      echo -e "${C_R}${C_BOLD}Step $step_n failed (invalid sessionResume)${C_RST}" >&2
      echo "  sessionResume must be a boolean true/false in $ORCH_FILE." >&2
      echo "  Log: $LOG_FILE" >&2
      printf -v "$step_status_var" '%s' 1
      return 1
    fi
  else
    ralph_orchestrator_log "FAIL step $step_n: sessionStrategy must be a string (got $_session_strategy_type)"
    echo -e "${C_R}${C_BOLD}Step $step_n failed (invalid sessionStrategy)${C_RST}" >&2
    echo "  sessionStrategy must be a string in $ORCH_FILE." >&2
    echo "  Log: $LOG_FILE" >&2
    printf -v "$step_status_var" '%s' 1
    return 1
  fi

  local _stage_grader _stage_rubric _effective_session_strategy
  _stage_grader="$(echo "$stage" | jq -r '.grader // false' 2>/dev/null || echo "false")"
  _stage_rubric="$(echo "$stage" | jq -r '.rubric // empty' 2>/dev/null || echo "")"
  _effective_session_strategy="$(echo "$stage" | jq -r '.sessionStrategy // empty' 2>/dev/null || echo "")"
  if [[ "$_stage_grader" == "true" ]]; then
    if [[ -z "$_stage_rubric" ]]; then
      ralph_orchestrator_log "FAIL step $step_n: grader stage requires rubric path"
      echo -e "${C_R}${C_BOLD}Step $step_n failed (grader missing rubric)${C_RST}" >&2
      echo "  grader: true requires rubric: <project-relative path> in $ORCH_FILE." >&2
      echo "  Log: $LOG_FILE" >&2
      printf -v "$step_status_var" '%s' 1
      return 1
    fi
    if [[ "$_effective_session_strategy" != "fresh" && "$_effective_session_strategy" != "" ]]; then
      ralph_orchestrator_log "FAIL step $step_n: grader stage requires sessionStrategy fresh (got $_effective_session_strategy)"
      echo -e "${C_R}${C_BOLD}Step $step_n failed (grader sessionStrategy)${C_RST}" >&2
      echo "  grader stages must use sessionStrategy: fresh (not resume, reset, or compact)." >&2
      echo "  Log: $LOG_FILE" >&2
      printf -v "$step_status_var" '%s' 1
      return 1
    fi
    _session_resume_value="$(echo "$stage" | jq -r '.sessionResume // false' 2>/dev/null || echo "false")"
    if [[ "$_session_resume_value" == "true" ]]; then
      ralph_orchestrator_log "FAIL step $step_n: grader stage rejects sessionResume true"
      echo -e "${C_R}${C_BOLD}Step $step_n failed (grader sessionResume)${C_RST}" >&2
      echo "  grader stages cannot use sessionResume: true; use sessionStrategy: fresh." >&2
      echo "  Log: $LOG_FILE" >&2
      printf -v "$step_status_var" '%s' 1
      return 1
    fi
    if [[ "$_effective_session_strategy" == "" ]]; then
      _session_strategy_cli=(--session-strategy fresh)
    fi
  fi

  if [[ "${ORCHESTRATOR_DRY_RUN:-0}" == "1" ]]; then
    _dry_sr=""
    if ((${#_session_strategy_cli[@]} > 0)); then
      _dry_sr=" ${_session_strategy_cli[*]}"
    fi
    _dry_model_label="${stage_model:-agent-config default}"
    if [[ "$agent_source" == "prebuilt" ]]; then
      echo "DRY RUN step $step_n: $runner_label --workspace <path> --agent $agent --plan $plan_rel${_dry_sr}"
    else
      echo "DRY RUN step $step_n: $runner_label --workspace <path> --plan $plan_rel${_dry_sr} (custom agent: $agent)"
    fi
    echo "  model: ${_dry_model_label}"
    if ((${#EXPECTED_ARTIFACT_PATHS[@]} > 0)); then
      echo "  expected artifacts: ${EXPECTED_ARTIFACT_PATHS[*]}"
    fi
    if [[ "${ORCHESTRATOR_HUMAN_ACK:-0}" == "1" ]]; then
      local _dry_human_ack_rel
      _dry_human_ack_rel="$(echo "$stage" | jq -r '.humanAck.path // empty' 2>/dev/null)" || _dry_human_ack_rel=""
      if [[ -n "$_dry_human_ack_rel" ]]; then
        _dry_human_ack_rel="$(expand_artifact_tokens "$_dry_human_ack_rel")"
        echo "  humanAck (only if ORCHESTRATOR_HUMAN_ACK=1): $_dry_human_ack_rel"
      fi
    fi
    if orch_planner_stage_has_planner "$stage"; then
      local _dry_planner_artifact_rel _dry_planner_artifact_abs _dry_planner_status=0
      _dry_planner_artifact_rel="$(orch_planner_find_artifact_path "$stage")"
      if [[ -n "$_dry_planner_artifact_rel" ]]; then
        _dry_planner_artifact_rel="$(expand_artifact_tokens "$_dry_planner_artifact_rel")"
        if [[ "$_dry_planner_artifact_rel" == /* ]]; then
          _dry_planner_artifact_abs="$_dry_planner_artifact_rel"
        else
          _dry_planner_artifact_abs="$WORKSPACE/$_dry_planner_artifact_rel"
        fi
        if [[ -f "$_dry_planner_artifact_abs" ]]; then
          orch_planner_apply_output "$stage" "$stage_id" "$step_n" _dry_planner_status || true
        else
          echo "  planner decomposition: artifact not present yet ($_dry_planner_artifact_rel)"
        fi
      fi
    fi
    printf -v "$step_status_var" '%s' 0
    return 0
  fi

  _step_model_label="${stage_model:-agent-config default}"
  echo -e "${C_DIM}────────────────────────────────────────────────────────────${C_RST}"
  echo -e "${C_B}Step ${step_n}${C_RST} ${C_G}$runtime${C_RST} agent=${C_BOLD}$agent${C_RST} source=${C_BOLD}$agent_source${C_RST} model=${C_DIM}${_step_model_label}${C_RST} plan=$plan_rel"
  _plan_tag_stream="$(basename "$plan_abs_file" | sed 's/\.[^.]*$//')"
  _plan_tag_stream="${_plan_tag_stream//[^A-Za-z0-9_.-]/_}"
  _runner_stream_log="$RALPH_LOG_DIR/$RALPH_ARTIFACT_NS/plan-runner-${_plan_tag_stream}-output.log"
  echo "" >&2
  echo -e "${C_DIM}Invoking:${C_RST} $runner_label" >&2
  if [[ "$agent_source" == "prebuilt" ]]; then
    echo -e "${C_DIM}  command:${C_RST} bash $runner --non-interactive --runtime $runtime --workspace <path> --plan <plan> --agent $agent" >&2
  else
    echo -e "${C_DIM}  command:${C_RST} bash $runner --non-interactive --runtime $runtime --workspace <path> --plan <plan>" >&2
  fi
  echo -e "${C_DIM}  orchestrator log (append):${C_RST} $LOG_FILE" >&2
  echo -e "${C_DIM}  per-plan agent output log:${C_RST} $_runner_stream_log" >&2
  echo -e "${C_DIM}──────────────── runner / agent output follows ────────────────${C_RST}" >&2

  if [[ "${RALPH_HANDOFFS_ENABLED:-1}" == "1" ]]; then
    export ORCH_FILE="$RALPH_ORCH_FILE"
    RALPH_ARTIFACT_NS="$ORCH_ARTIFACT_NS" inject_handoffs_into_plan "$plan_abs_file" "$stage_id" "$stage_iter" || {
      ralph_orchestrator_log "WARNING step $step_n: failed to inject handoffs into plan (continuing anyway)"
    }
  fi

  set +e
  _runner_env=(
    RALPH_ARTIFACT_NS="$RALPH_ARTIFACT_NS"
    RALPH_PLAN_KEY="$(basename "$plan_abs_file" | sed 's/\.[^.]*$//;s/[^A-Za-z0-9_.-]/_/g')"
    RALPH_ORCH_FILE="$RALPH_ORCH_FILE"
  )
  if [[ -n "${CODEX_PLAN_SANDBOX:-}" ]]; then
    _runner_env+=(CODEX_PLAN_SANDBOX="$CODEX_PLAN_SANDBOX")
  fi
  if [[ -n "${CODEX_PLAN_DANGEROUSLY_BYPASS_APPROVALS_AND_SANDBOX:-}" ]]; then
    _runner_env+=(CODEX_PLAN_DANGEROUSLY_BYPASS_APPROVALS_AND_SANDBOX="$CODEX_PLAN_DANGEROUSLY_BYPASS_APPROVALS_AND_SANDBOX")
  fi
  if [[ -n "${CLAUDE_PLAN_BARE:-}" ]]; then
    _runner_env+=(CLAUDE_PLAN_BARE="$CLAUDE_PLAN_BARE")
  fi
  if [[ -n "${CLAUDE_PLAN_MINIMAL:-}" ]]; then
    _runner_env+=(CLAUDE_PLAN_MINIMAL="$CLAUDE_PLAN_MINIMAL")
  fi
  if [[ -n "${CLAUDE_PLAN_MINIMAL_TOOLS:-}" ]]; then
    _runner_env+=(CLAUDE_PLAN_MINIMAL_TOOLS="$CLAUDE_PLAN_MINIMAL_TOOLS")
  fi
  if [[ -n "${CLAUDE_PLAN_MINIMAL_DISABLE_MCP:-}" ]]; then
    _runner_env+=(CLAUDE_PLAN_MINIMAL_DISABLE_MCP="$CLAUDE_PLAN_MINIMAL_DISABLE_MCP")
  fi
  if [[ -n "${CLAUDE_PLAN_PERMISSION_MODE:-}" ]]; then
    _runner_env+=(CLAUDE_PLAN_PERMISSION_MODE="$CLAUDE_PLAN_PERMISSION_MODE")
  fi
  stage_mcp_proxy_policy_type="$(echo "$stage" | jq -r 'if has("mcpProxyPolicy") then (.mcpProxyPolicy|type) else "absent" end' 2>/dev/null || echo "error")"
  if [[ "$stage_mcp_proxy_policy_type" == "string" ]]; then
    stage_mcp_proxy_policy="$(echo "$stage" | jq -r '.mcpProxyPolicy' 2>/dev/null || echo "")"
    if [[ -z "$stage_mcp_proxy_policy" ]]; then
      ralph_orchestrator_log "FAIL step $step_n: mcpProxyPolicy must be a non-empty string"
      echo -e "${C_R}${C_BOLD}Step $step_n failed (invalid mcpProxyPolicy)${C_RST}" >&2
      echo "  mcpProxyPolicy must be a non-empty string in $ORCH_FILE." >&2
      echo "  Log: $LOG_FILE" >&2
      printf -v "$step_status_var" '%s' 1
      return 1
    fi
    _runner_env+=(RALPH_MCP_PROXY_POLICY="$stage_mcp_proxy_policy")
  elif [[ "$stage_mcp_proxy_policy_type" != "absent" ]]; then
    ralph_orchestrator_log "FAIL step $step_n: mcpProxyPolicy must be a string (got $stage_mcp_proxy_policy_type)"
    echo -e "${C_R}${C_BOLD}Step $step_n failed (invalid mcpProxyPolicy)${C_RST}" >&2
    echo "  mcpProxyPolicy must be a string in $ORCH_FILE." >&2
    echo "  Log: $LOG_FILE" >&2
    printf -v "$step_status_var" '%s' 1
    return 1
  fi
  if [[ -n "$stage_model" ]]; then
    if [[ "$runtime" == "cursor" ]]; then
      _runner_env+=(CURSOR_PLAN_MODEL="$stage_model")
    elif [[ "$runtime" == "codex" ]]; then
      _runner_env+=(CODEX_PLAN_MODEL="$stage_model")
    elif [[ "$runtime" == "opencode" ]]; then
      _runner_env+=(OPENCODE_PLAN_MODEL="$stage_model")
    elif [[ "$runtime" == "antigravity" ]]; then
      _runner_env+=(ANTIGRAVITY_PLAN_MODEL="$stage_model")
    else
      _runner_env+=(CLAUDE_PLAN_MODEL="$stage_model")
    fi
  fi
  local stage_reasoning_effort=""
  stage_reasoning_effort="$(echo "$stage" | jq -r '.reasoning_effort // ""' 2>/dev/null)" || stage_reasoning_effort=""
  if [[ -n "$stage_reasoning_effort" ]]; then
    case "$stage_reasoning_effort" in
      low|medium|high|xhigh|max|inherit)
        case "$runtime" in
          cursor) _runner_env+=(CURSOR_PLAN_REASONING_EFFORT="$stage_reasoning_effort") ;;
          codex) _runner_env+=(CODEX_PLAN_REASONING_EFFORT="$stage_reasoning_effort") ;;
          opencode) _runner_env+=(OPENCODE_PLAN_REASONING_EFFORT="$stage_reasoning_effort") ;;
          antigravity) _runner_env+=(ANTIGRAVITY_PLAN_REASONING_EFFORT="$stage_reasoning_effort") ;;
          *) _runner_env+=(CLAUDE_PLAN_REASONING_EFFORT="$stage_reasoning_effort") ;;
        esac
        ;;
      *)
        ralph_orchestrator_log "FAIL step $step_n: invalid reasoning_effort '$stage_reasoning_effort' (use low, medium, high, xhigh, max, or inherit)"
        echo -e "${C_R}${C_BOLD}Step $step_n failed (invalid reasoning_effort)${C_RST}" >&2
        echo "  reasoning_effort must be one of: low, medium, high, xhigh, max, inherit in $ORCH_FILE." >&2
        echo "  Log: $LOG_FILE" >&2
        printf -v "$step_status_var" '%s' 1
        return 1
        ;;
    esac
  fi
  if [[ -n "$stage_context_budget" ]]; then
    _runner_env+=(RALPH_PLAN_CONTEXT_BUDGET="$stage_context_budget")
  fi
  if [[ "$_stage_grader" == "true" ]]; then
    _runner_env+=(RALPH_GRADER_STAGE=1 RALPH_RUBRIC_PATH="$_stage_rubric")
  else
    _runner_env+=(RALPH_GRADER_STAGE=0)
  fi
  local _stage_router_json=""
  local _stage_planner_json=""
  local _final_output_schema=""
  if echo "$stage" | jq -e '.router | type == "object"' >/dev/null 2>&1; then
    _stage_router_json="$(echo "$stage" | jq -c '.router' 2>/dev/null || echo "")"
    _runner_env+=(RALPH_ROUTER_STAGE=1 RALPH_ROUTER_CONFIG_JSON="$_stage_router_json")
  else
    _runner_env+=(RALPH_ROUTER_STAGE=0)
  fi
  if echo "$stage" | jq -e '.planner | type == "object"' >/dev/null 2>&1; then
    _stage_planner_json="$(echo "$stage" | jq -c '.planner' 2>/dev/null || echo "")"
    _runner_env+=(RALPH_PLANNER_STAGE=1 RALPH_PLANNER_CONFIG_JSON="$_stage_planner_json")
  else
    _runner_env+=(RALPH_PLANNER_STAGE=0)
  fi
  if declare -F orch_resolve_final_output_schema >/dev/null 2>&1; then
    _final_output_schema="$(orch_resolve_final_output_schema "$stage")"
    if [[ -n "$_final_output_schema" ]]; then
      _runner_env+=(RALPH_STRUCTURED_OUTPUT_SCHEMA="$_final_output_schema")
    fi
  fi
  _runner_args=(--non-interactive --runtime "$runtime" --workspace "$WORKSPACE" --plan "$plan_abs_file")
  if [[ -n "${WORKSPACE_ROOT_OVERRIDE:-}" ]]; then
    _runner_args+=(--workspace-root "$WORKSPACE_ROOT_OVERRIDE")
  fi
  if ((${#_session_strategy_cli[@]} > 0)); then
    _runner_args+=("${_session_strategy_cli[@]}")
  fi
  if [[ "$agent_source" == "prebuilt" ]]; then
    _runner_args+=(--agent "$agent")
  elif [[ -z "$stage_model" ]]; then
    ralph_orchestrator_log "FAIL step $step_n: custom agent '$agent' requires stage model"
    echo -e "${C_R}${C_BOLD}Step $step_n failed (missing model for custom agent)${C_RST}" >&2
    echo "  Add \"model\" to this stage in $ORCH_FILE or choose a prebuilt agent." >&2
    echo "  Log: $LOG_FILE" >&2
    printf -v "$step_status_var" '%s' 1
    set -e
    return 1
  fi
  orch_stage_run_runner "$runner" "${_runner_env[@]}"
  rc=$?
  set -e
  echo -e "${C_DIM}--- end step $step_n runner output (exit $rc) ---${C_RST}" >&2
  echo "" >&2
  if [[ $rc -ne 0 ]]; then
    plan_tag="$(basename "$plan_abs_file" | sed 's/\.[^.]*$//')"
    plan_tag="${plan_tag//[^A-Za-z0-9_.-]/_}"
    hint_log="$RALPH_LOG_DIR/$RALPH_ARTIFACT_NS/plan-runner-${plan_tag}.log"
    hint_out="$RALPH_LOG_DIR/$RALPH_ARTIFACT_NS/plan-runner-${plan_tag}-output.log"
    ralph_orchestrator_log "FAIL step $step_n exit=$rc agent=$agent plan=$plan_abs_file"
    {
      echo ""
      echo "======== orchestrator failure ========"
      echo "Step:        $step_n"
      echo "Runtime:     $runtime"
      echo "Agent:       $agent"
      echo "Plan file:   $plan_abs_file"
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
    echo -e "${C_R}${C_BOLD}Orchestrator stopped: step $step_n failed (exit $rc)${C_RST}" >&2
    echo "  Runtime: $runtime  Agent: $agent" >&2
    echo "  Plan: $plan_abs_file" >&2
    echo "  See: $LOG_FILE" >&2
    echo "  Ralph logs: $hint_log / $hint_out" >&2
    printf -v "$step_status_var" '%s' "$rc"
    exit "$rc"
  fi

  if ((${#EXPECTED_ARTIFACT_PATHS[@]} > 0)); then
    if ! verify_step_artifacts "$step_n"; then
      ralph_orchestrator_log "FAIL step $step_n: artifact verification failed (see log for remediation)"
      printf -v "$step_status_var" '%s' 1
      exit 1
    fi
    ralph_orchestrator_log "step $step_n artifact verification OK (${#EXPECTED_ARTIFACT_PATHS[@]} file(s))"
    if ! verify_stage_artifact_schemas "$WORKSPACE" "$stage" "$stage_id" "$step_n"; then
      {
        echo ""
        echo "======== artifact schema validation failure ========"
        echo "Step: $step_n"
        echo "Stage: $stage_id"
        echo "Reason: produced artifact failed JSON schema validation (see stderr above)"
        artifact_remediation_text
        echo "===================================================="
      } >>"$LOG_FILE"
      echo -e "${C_R}${C_BOLD}Step $step_n artifact schema validation failed${C_RST}" >&2
      echo "  Stage: $stage_id" >&2
      echo "  See stderr for stage id, artifact path, schema path, and JSON location." >&2
      artifact_remediation_text >&2
      echo "  Log: $LOG_FILE" >&2
      ralph_orchestrator_log "FAIL step $step_n: artifact schema validation failed"
      printf -v "$step_status_var" '%s' 1
      exit 1
    fi
  elif ralph_artifact_schema_validation_enabled; then
    if ! verify_stage_artifact_schemas "$WORKSPACE" "$stage" "$stage_id" "$step_n"; then
      {
        echo ""
        echo "======== artifact schema validation failure ========"
        echo "Step: $step_n"
        echo "Stage: $stage_id"
        echo "Reason: produced artifact failed JSON schema validation (see stderr above)"
        artifact_remediation_text
        echo "===================================================="
      } >>"$LOG_FILE"
      echo -e "${C_R}${C_BOLD}Step $step_n artifact schema validation failed${C_RST}" >&2
      echo "  Stage: $stage_id" >&2
      echo "  See stderr for stage id, artifact path, schema path, and JSON location." >&2
      artifact_remediation_text >&2
      echo "  Log: $LOG_FILE" >&2
      ralph_orchestrator_log "FAIL step $step_n: artifact schema validation failed"
      printf -v "$step_status_var" '%s' 1
      exit 1
    fi
  fi
  if ralph_artifact_provenance_enabled; then
    if ! verify_stage_artifact_provenance "$WORKSPACE" "$stage" "$stage_id" "$step_n"; then
      {
        echo ""
        echo "======== artifact provenance validation failure ========"
        echo "Step: $step_n"
        echo "Stage: $stage_id"
        echo "Reason: produced artifact failed provenance validation (see stderr above)"
        artifact_remediation_text
        echo "======================================================"
      } >>"$LOG_FILE"
      echo -e "${C_R}${C_BOLD}Step $step_n artifact provenance validation failed${C_RST}" >&2
      echo "  Stage: $stage_id" >&2
      echo "  See stderr for stage id, artifact path, and citation location." >&2
      artifact_remediation_text >&2
      echo "  Log: $LOG_FILE" >&2
      ralph_orchestrator_log "FAIL step $step_n: artifact provenance validation failed"
      printf -v "$step_status_var" '%s' 1
      exit 1
    fi
  fi

  # Single-stage mode executes exactly one stage: no humanAck waiting, router
  # target application, planner advancement, or loopControl. The orchestration
  # transition/retry decision is made downstream from the StageOutcomeReport.
  if [[ "${SINGLE_STAGE_MODE:-0}" != "1" ]]; then
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
      ralph_orchestrator_log "HUMAN_ACK step $step_n: paused until ack file exists: $human_ack_abs"
      echo "" >&2
      echo -e "${C_Y}${C_BOLD}Human acknowledgment required before the next stage${C_RST}" >&2
      echo "  Stage: $step_n ($agent)" >&2
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
    ralph_orchestrator_log "humanAck OK: $human_ack_abs"
  fi

  if ! orch_router_apply_decision "$stage" "$stage_id" "$stage_index" "$step_n" "$step_status_var"; then
    return 1
  fi
  if [[ "${ORCH_ROUTER_TERMINAL_ACTIVE:-0}" == "1" ]]; then
    ralph_orchestrator_log "router terminal outcome selected; skipping remaining stages"
    printf -v "$step_status_var" '%s' 0
    return 0
  fi

  if ! orch_planner_apply_output "$stage" "$stage_id" "$step_n" "$step_status_var"; then
    return 1
  fi

  loop_decision="proceed"
  if [[ "$agent" == "code-review" ]] || echo "$stage" | jq -e '.loopControl' >/dev/null 2>&1; then
    loop_artifact="${EXPECTED_ARTIFACT_PATHS[0]-}"
    loop_result="$(check_loop_condition "$stage" "$loop_artifact" 2>/dev/null)" || loop_result="proceed"
    if [[ "$loop_result" == loop:* ]]; then
      loop_decision="$loop_result"
      IFS=: read -r _ loop_back_stage loop_iter <<< "$loop_result"
      loop_back_stage="$(printf '%s' "$loop_back_stage" | tr '[:upper:]' '[:lower:]')"
      loop_back_stage="$(printf '%s' "$loop_back_stage" | tr -c 'a-z0-9-' '-')"
      loop_back_stage="$(printf '%s' "$loop_back_stage" | sed 's/-\+/-/g; s/^-//; s/-$//')"
      if [[ -n "$stage_id" ]]; then
        orch_stage_iteration_map_set "$stage_id" "$loop_iter"
      fi
      ralph_orchestrator_log "step $step_n triggers loop back to $loop_back_stage (iteration $loop_iter)"
      echo -e "${C_Y}Step $step_n completed with feedback loop.${C_RST}"
      echo -e "${C_Y}Looping back to: $loop_back_stage (iteration $loop_iter)${C_RST}"
      if back_idx="$(orch_stage_index_map_get "$loop_back_stage")"; then
        printf -v "$step_status_var" '%s' 0
        echo "$back_idx"
        return 0
      fi
      ralph_orchestrator_log "loop target '$loop_back_stage' not found in stages; continuing forward"
      echo -e "${C_Y}Loop target '$loop_back_stage' not found; continuing forward.${C_RST}"
    elif [[ "$loop_result" == exhausted:* ]]; then
      # Max iterations reached while review still requires changes and
      # onExhausted is not 'proceed': stop the orchestration with a non-zero exit.
      ralph_orchestrator_log "step $step_n loop exhausted (maxIterations reached, changes still required)"
      echo -e "${C_R}${C_BOLD}Step $step_n loop exhausted: review still requires changes after maximum iterations.${C_RST}" >&2
      echo "  Set loopControl.onExhausted: proceed to continue past an exhausted loop." >&2
      echo "  Log: $LOG_FILE" >&2
      printf -v "$step_status_var" '%s' 1
      return 1
    fi
  fi
  fi

  # run-plan writes plan-usage-summary.json under logs/<RALPH_ARTIFACT_NS>/ (see run-plan-core.sh).
  _stage_usage_file="$RALPH_LOG_DIR/$RALPH_ARTIFACT_NS/plan-usage-summary.json"
  orch_stage_capture_usage "$step_n" "$agent" "$runtime" "$_stage_usage_file" "$stage_usage_file"
  ralph_orchestrator_log "step $step_n OK"
  echo -e "${C_G}Step $step_n completed.${C_RST}"
  printf -v "$step_status_var" '%s' 0
  return 0
}

orch_stage_run_runner() {
  local runner="$1"
  shift
  local _use_tee=0
  local _child_pid=""
  local _exit_status=0
  if [[ "${ORCHESTRATOR_RUNNER_TO_CONSOLE:-1}" != "0" ]] \
    && ([[ -t 1 ]] || [[ "${ORCHESTRATOR_PARALLEL_PREFIX_STREAM:-0}" == "1" ]]) \
    && command -v tee >/dev/null 2>&1; then
    _use_tee=1
    if [[ ("${ORCHESTRATOR_NO_COLOR:-0}" != "1" && -z "${NO_COLOR:-}") && (-t 1 || "${ORCHESTRATOR_PARALLEL_PREFIX_STREAM:-0}" == "1") ]]; then
      set -- "$@" RALPH_PLAN_PRETTY=1
    fi
    # Run the actual runner with output piped through tee for console and log.
    # We launch the runner in a subshell, capture its PID and exit status, then
    # pipe the output through tee. This preserves both the runner's PID (for signal
    # handling) and its exit status.
    local _runner_pidfile _runner_exitfile
    _runner_pidfile="$(mktemp)" || _runner_pidfile="/dev/null"
    _runner_exitfile="$(mktemp)" || _runner_exitfile="/dev/null"
    {
      env "$@" bash "$runner" "${_runner_args[@]}" 2>&1
      printf '%s' "$?" > "$_runner_exitfile" 2>/dev/null || true
    } | tee >(LC_ALL=C sed -E $'s/\x1b\\[[0-9;]*m//g' >> "$LOG_FILE") &
    _child_pid=$!
    # The runner PID is written by the first command in the pipeline (the subshell),
    # but we need to write it from within the subshell. Since we don't have direct
    # access to write from within the pipeline, we use a different approach:
    # we track the wrapper PID (the backgrounded pipeline) and rely on the signal
    # handler to kill it, which will kill all descendants including the actual runner.
    orch_record_runner_pid "$_child_pid"
    wait "$_child_pid"
    _exit_status=$?
    # Read the actual runner exit status if available.
    if [[ -f "$_runner_exitfile" ]]; then
      _exit_status="$(cat "$_runner_exitfile" 2>/dev/null || echo "$?")"
    fi
    rm -f "$_runner_pidfile" "$_runner_exitfile" 2>/dev/null || true
    orch_clear_runner_pid
    return "$_exit_status"
  fi
  env "$@" bash "$runner" "${_runner_args[@]}" >>"$LOG_FILE" 2>&1 &
  _child_pid=$!
  orch_record_runner_pid "$_child_pid"
  wait "$_child_pid"
  _exit_status=$?
  orch_clear_runner_pid
  return "$_exit_status"
}

orch_parallel_stage_tag_color() {
  local color_idx="${1:-0}"
  case $((color_idx % 4)) in
    0) printf '%s' "$C_B" ;;
    1) printf '%s' "$C_G" ;;
    2) printf '%s' "$C_Y" ;;
    *) printf '%s' "$C_C" ;;
  esac
}

orch_parallel_stage_prefix_stream() {
  local stage_id="$1"
  local stage_color="${2:-}"
  local stage_tag
  if [[ -n "$stage_color" ]]; then
    stage_tag="${stage_color}[${stage_id}]${C_RST}"
  else
    stage_tag="[${stage_id}]"
  fi
  while IFS= read -r stage_line || [[ -n "$stage_line" ]]; do
    printf '%s %s\n' "$stage_tag" "$stage_line"
  done
}

ralph_orchestrator_log() {
  echo "[$(ralph_orchestrator_timestamp)] $*" >> "$LOG_FILE"
  if [[ "${ORCHESTRATOR_VERBOSE:-0}" == "1" ]]; then
    echo "[$(ralph_orchestrator_timestamp)] $*" >&2
  fi
}

ralph_orchestrator_log "orchestrator started workspace=$WORKSPACE orchestration=$ORCH_FILE"

if [[ -t 1 && "${ORCHESTRATOR_NO_COLOR:-0}" != "1" && -z "${NO_COLOR:-}" ]]; then
  C_R=$'\033[31m'
  C_G=$'\033[32m'
  C_Y=$'\033[33m'
  C_B=$'\033[34m'
  C_C=$'\033[36m'
  C_DIM=$'\033[2m'
  C_BOLD=$'\033[1m'
  C_RST=$'\033[0m'
else
  C_R="" C_G="" C_Y="" C_B="" C_C="" C_DIM="" C_BOLD="" C_RST=""
fi

# Human-facing step counter (1-based); can exceed idx when looping back.
step_index=0
# Running orchestration-level token usage totals (read from per-stage plan-usage-summary.json).
_orch_input_tokens=0
_orch_output_tokens=0
_orch_cache_creation_tokens=0
_orch_cache_read_tokens=0
_orch_start_ts="$(date +%s)"
_orch_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
_orch_stage_usages=""

# Render an inline orchestration stage (its todos carried in the root plan) into a
# standalone standard plan file that run-plan.sh can execute, mirroring planFile stages.
orch_render_inline_stage_plan() {
  local stage_id="$1" ns="$2" todos_json="$3"
  python3 - "$stage_id" "$ns" "$todos_json" <<'PYRENDER'
import json
import sys

stage_id, ns, todos_json = sys.argv[1], sys.argv[2], sys.argv[3]
todos = json.loads(todos_json) if todos_json else []
if not todos:
    todos = [{"id": f"{stage_id}-task-1", "content": "Complete this stage.",
              "verification": "Confirm the stage is complete.", "status": "pending"}]


def block(text: str) -> str:
    lines = (text or "").splitlines() or [""]
    return "\n".join("      " + ln for ln in lines)


out = ["---", f"name: {ns}-{stage_id}", f"overview: Inline stage {stage_id}",
       "execution: standard", "instructions: Execute one TODO at a time.", "", "todos:"]
for todo in todos:
    out.append(f"  - id: {todo.get('id') or stage_id + '-task'}")
    out.append("    content: |")
    out.append(block(todo.get("content", "")))
    out.append("    verification: |")
    out.append(block(todo.get("verification", "")))
    out.append(f"    status: {todo.get('status') or 'pending'}")
out += ["isProject: false", "---"]
print("\n".join(out))
PYRENDER
}

# A structured orchestration plan (.plan.md with a pipeline block) is normalized into the
# .orch.json shape this orchestrator already runs: inline stages become standalone stage
# plan files, planFile stages are used as-is. Legacy .orch.json inputs skip this entirely.
if [[ "$ORCH_FILE" != *.json ]]; then
  if ! command -v python3 >/dev/null 2>&1; then
    ralph_orchestrator_log "FAIL: python3 required for structured orchestration plan $ORCH_FILE"
    echo -e "${C_R}${C_BOLD}Orchestrator aborted: python3 is required for a structured orchestration plan${C_RST}" >&2
    echo "  Use a classic markdown plan with 'ralph run --plan', or install python3." >&2
    echo "  Log: $LOG_FILE" >&2
    exit 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    ralph_orchestrator_log "FAIL: jq required to normalize structured orchestration plan $ORCH_FILE"
    echo -e "${C_R}${C_BOLD}Orchestrator aborted: jq is required for orchestration${C_RST}" >&2
    echo "  Install: brew install jq (macOS) or apt install jq (Linux)" >&2
    exit 1
  fi
  if ! declare -F plan_pipeline_orch_json >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "$RALPH_ACTIVE_DIR/bash-lib/plan-todo.sh"
  fi
  if ! _orch_norm_json="$(plan_pipeline_orch_json "$ORCH_FILE" 2>&1)"; then
    ralph_orchestrator_log "FAIL parse: $ORCH_FILE"
    echo -e "${C_R}${C_BOLD}Orchestrator parse error: invalid orchestration plan${C_RST}" >&2
    printf '%s\n' "$_orch_norm_json" | sed 's/^/  /' >&2
    echo "  Log: $LOG_FILE" >&2
    exit 1
  fi
  _orch_norm_ns="$(printf '%s' "$_orch_norm_json" | jq -r '.namespace // empty' 2>/dev/null || echo "")"
  [[ -n "$_orch_norm_ns" ]] || _orch_norm_ns="$ORCH_BASENAME"
  _orch_gen_dir="$RALPH_PLAN_WORKSPACE_ROOT/orchestration-plans/$_orch_norm_ns"
  mkdir -p "$_orch_gen_dir"
  _orch_stage_count="$(printf '%s' "$_orch_norm_json" | jq '.stages | length' 2>/dev/null || echo 0)"
  for ((_orch_si = 0; _orch_si < _orch_stage_count; _orch_si++)); do
    if [[ "$(printf '%s' "$_orch_norm_json" | jq -r ".stages[$_orch_si] | has(\"_inlineTodos\")" 2>/dev/null)" != "true" ]]; then
      continue
    fi
    _orch_sid="$(printf '%s' "$_orch_norm_json" | jq -r ".stages[$_orch_si].id // \"stage\"" 2>/dev/null)"
    _orch_todos="$(printf '%s' "$_orch_norm_json" | jq -c ".stages[$_orch_si]._inlineTodos" 2>/dev/null)"
    _orch_stage_file="$_orch_gen_dir/$(printf '%s-%02d-%s.plan.md' "$_orch_norm_ns" "$((_orch_si + 1))" "$_orch_sid")"
    orch_render_inline_stage_plan "$_orch_sid" "$_orch_norm_ns" "$_orch_todos" > "$_orch_stage_file"
    _orch_norm_json="$(printf '%s' "$_orch_norm_json" | jq --arg p "$_orch_stage_file" "(.stages[$_orch_si].plan) = \$p | del(.stages[$_orch_si]._inlineTodos)" 2>/dev/null)"
  done
  _orch_gen_file="$_orch_gen_dir/${_orch_norm_ns}.orch.json"
  printf '%s\n' "$_orch_norm_json" > "$_orch_gen_file"
  ORCH_FILE="$_orch_gen_file"
  export RALPH_ORCH_FILE="$ORCH_FILE"
  ralph_orchestrator_log "normalized structured plan -> $_orch_gen_file (ns=$_orch_norm_ns)"
  if [[ "${ORCH_NORMALIZE_ONLY:-0}" == "1" ]]; then
    printf '%s\n' "$_orch_gen_file"
    exit 0
  fi
fi

# Legacy .orch.json is parsed directly; structured plans were normalized to one above.
if [[ "$ORCH_FILE" == *.json ]]; then
  # Parse JSON orchestration file with jq
  if ! command -v jq >/dev/null 2>&1; then
    ralph_orchestrator_log "FAIL: jq not found. Install jq to parse JSON orchestration files."
    echo -e "${C_R}${C_BOLD}Orchestrator aborted: jq is required for JSON orchestration${C_RST}" >&2
    echo "  Install: brew install jq (macOS) or apt install jq (Linux)" >&2
    echo "  Log: $LOG_FILE" >&2
    exit 1
  fi

  # Validate JSON
  if ! jq empty "$ORCH_FILE" 2>/dev/null; then
    ralph_orchestrator_log "FAIL parse: invalid JSON in $ORCH_FILE"
    echo -e "${C_R}${C_BOLD}Orchestrator parse error: invalid JSON${C_RST}" >&2
    jq empty "$ORCH_FILE" 2>&1 | sed 's/^/  /' >&2
    echo "  Log: $LOG_FILE" >&2
    exit 1
  fi

  if ! orch_router_validate_orchestration "$ORCH_FILE"; then
    ralph_orchestrator_log "FAIL parse: router validation failed for $ORCH_FILE"
    echo -e "${C_R}${C_BOLD}Orchestrator parse error: router validation failed${C_RST}" >&2
    echo "  Log: $LOG_FILE" >&2
    exit 1
  fi

  if ! orch_planner_validate_orchestration "$ORCH_FILE"; then
    ralph_orchestrator_log "FAIL parse: planner validation failed for $ORCH_FILE"
    echo -e "${C_R}${C_BOLD}Orchestrator parse error: planner validation failed${C_RST}" >&2
    echo "  Log: $LOG_FILE" >&2
    exit 1
  fi

  # Drives {{ARTIFACT_NS}} in paths and per-plan log dirs unless overridden in the environment.
  json_ns="$(jq -r '.namespace // empty' "$ORCH_FILE" 2>/dev/null || echo "")"
  export RALPH_ARTIFACT_NS="${RALPH_ARTIFACT_NS:-${json_ns:-$ORCH_BASENAME}}"
  ORCH_ARTIFACT_NS="${json_ns:-$ORCH_BASENAME}"

  # Build stage_id -> array index so loop-back can set idx to an earlier stage.
  num_stages="$(jq '.stages | length' "$ORCH_FILE" 2>/dev/null || echo 0)"
  ORCH_STAGE_INDEX_KEYS=()
  ORCH_STAGE_INDEX_VALS=()
  ORCH_STAGE_ITER_KEYS=()
  ORCH_STAGE_ITER_VALS=()
  for ((map_idx = 0; map_idx < num_stages; map_idx++)); do
    map_stage_id="$(jq -r ".stages[$map_idx].id // empty" "$ORCH_FILE" 2>/dev/null || echo "")"
    map_stage_id="$(orch_stage_normalize_id "$map_stage_id")"
    [[ -n "$map_stage_id" ]] && orch_stage_index_map_set "$map_stage_id" "$map_idx"
  done

  # Single-stage mode: resolve exactly one stage by id, run it through the
  # per-stage function, emit a StageOutcomeReport, and exit. Router target
  # application, planner advancement, loopControl, humanAck waiting (skipped
  # inside orch_stage_execute), parallel wave scheduling, and stage-index
  # advancement are all bypassed because this branch never enters the loops.
  if [[ "${SINGLE_STAGE_MODE:-0}" == "1" ]]; then
    ss_norm_id="$(orch_stage_normalize_id "$SINGLE_STAGE_ID")"
    if [[ -z "$ss_norm_id" ]] || ! ss_idx="$(orch_stage_index_map_get "$ss_norm_id")"; then
      ralph_orchestrator_log "FAIL single-stage: unknown stage id '$SINGLE_STAGE_ID'"
      echo -e "${C_R}${C_BOLD}Single-stage: unknown stage id '${SINGLE_STAGE_ID}'${C_RST}" >&2
      echo "  No stage with that id exists in $ORCH_FILE." >&2
      echo "  Log: $LOG_FILE" >&2
      orch_single_stage_write_report "failed" 1 "unknown stage id: $SINGLE_STAGE_ID" || true
      exit 1
    fi
    stage="$(jq ".stages[$ss_idx]" "$ORCH_FILE" 2>/dev/null)" || {
      ralph_orchestrator_log "FAIL single-stage: unable to read stage $ss_norm_id"
      orch_single_stage_write_report "failed" 1 "unable to read stage $ss_norm_id" || true
      exit 1
    }
    stage_id="$ss_norm_id"
    stage_iter="$(orch_stage_iteration_map_get "$stage_id")"
    runtime_raw="$(echo "$stage" | jq -r '.runtime // "cursor"' 2>/dev/null || echo "cursor")"
    if ! runtime="$(orchestrator_validate_runtime "$runtime_raw")"; then
      ralph_orchestrator_log "FAIL single-stage: invalid RUNTIME '$runtime_raw'"
      echo -e "${C_R}Invalid RUNTIME '${runtime_raw}'. Use cursor, claude, codex, opencode, or antigravity.${C_RST}" >&2
      echo "  Log: $LOG_FILE" >&2
      orch_single_stage_write_report "failed" 1 "invalid runtime: $runtime_raw" || true
      exit 1
    fi
    agent="$(echo "$stage" | jq -r '.agent // ""' 2>/dev/null)" || agent=""
    agent_source_raw="$(echo "$stage" | jq -r '.agentSource // ""' 2>/dev/null)" || agent_source_raw=""
    stage_model="$(echo "$stage" | jq -r '.model // ""' 2>/dev/null)" || stage_model=""
    agent_source="$(printf '%s' "${agent_source_raw:-prebuilt}" | tr '[:upper:]' '[:lower:]')"
    [[ -z "$agent_source" ]] && agent_source="prebuilt"
    plan_rel="$(echo "$stage" | jq -r '.plan // ""' 2>/dev/null)" || plan_rel=""
    planTemplate="$(echo "$stage" | jq -r '.planTemplate // ""' 2>/dev/null)" || planTemplate=""
    step_index=$((step_index + 1))
    plan_abs="$(orchestrator_stage_plan_abs "$plan_rel" "$WORKSPACE")"
    step_rc=0
    # orch_stage_execute exits directly on runner/artifact failure; the EXIT trap
    # then records the failed/cancelled report with the real exit code. Non-zero
    # returns (validation without exit) are handled explicitly here.
    if ! orch_stage_execute "$step_index" "$stage" "$plan_abs" "$plan_rel" "$runtime" "$agent" "$agent_source" "$stage_model" "$agent_source_raw" "$planTemplate" "$stage_id" "$stage_iter" step_rc "$ss_idx"; then
      orch_single_stage_write_report "failed" "${step_rc:-1}" "stage execution failed" || true
      exit "${step_rc:-1}"
    fi
    if [[ "${step_rc:-0}" -gt 0 ]]; then
      orch_single_stage_write_report "failed" "$step_rc" "stage execution returned $step_rc" || true
      exit "$step_rc"
    fi
    if ! orch_single_stage_write_report "success" 0 ""; then
      ralph_orchestrator_log "FAIL single-stage: unable to write StageOutcomeReport"
      echo -e "${C_R}${C_BOLD}Single-stage: failed to write StageOutcomeReport${C_RST}" >&2
      echo "  Log: $LOG_FILE" >&2
      exit 1
    fi
    ss_report_path="$(orch_single_stage_report_path 2>/dev/null || echo "")"
    ralph_orchestrator_log "single-stage complete: stage=$stage_id outcome=success report=$ss_report_path"
    echo -e "${C_G}${C_BOLD}Single-stage complete${C_RST} (stage=$stage_id). Report: $ss_report_path"
    exit 0
  fi

  parallel_waves_raw="$(jq -c '.parallelStages // empty' "$ORCH_FILE" 2>/dev/null || echo "")"
  if [[ -n "$parallel_waves_raw" ]]; then
    parallel_waves_count="$(echo "$parallel_waves_raw" | jq 'length' 2>/dev/null || echo 0)"
    for ((wave_idx = 0; wave_idx < parallel_waves_count; wave_idx++)); do
      wave_stage_ids="$(echo "$parallel_waves_raw" | jq -r ".[$wave_idx]" 2>/dev/null || true)"
      wave_pids=()
      wave_stage_refs=()
      wave_output_logs=()
      wave_status=0
      wave_failures=()
      wave_stage_position=0
      IFS=',' read -r -a wave_stage_id_parts <<< "$wave_stage_ids"
      for wave_stage_id in "${wave_stage_id_parts[@]}"; do
        wave_stage_id="$(printf '%s' "$wave_stage_id" | sed 's/^\s*//; s/\s*$//')"
        [[ -z "$wave_stage_id" ]] && continue
        normalized_stage_id="$(orch_stage_normalize_id "$wave_stage_id")"
        if [[ -z "$normalized_stage_id" ]]; then
          ralph_orchestrator_log "FAIL parallel wave $((wave_idx + 1)): empty stage id entry"
          echo "Parallel wave $((wave_idx + 1)) contains an empty stage id." >&2
          exit 1
        fi
        if ! back_idx="$(orch_stage_index_map_get "$normalized_stage_id")"; then
          ralph_orchestrator_log "FAIL parallel wave $((wave_idx + 1)): unknown stage id '$normalized_stage_id'"
          echo "Parallel wave $((wave_idx + 1)) references unknown stage id: $normalized_stage_id" >&2
          exit 1
        fi
        stage="$(jq ".stages[$back_idx]" "$ORCH_FILE" 2>/dev/null)" || exit 1
        stage_id="$normalized_stage_id"
        stage_iter="$(orch_stage_iteration_map_get "$stage_id")"
        runtime_raw="$(echo "$stage" | jq -r '.runtime // "cursor"' 2>/dev/null || echo "cursor")"
        if ! runtime="$(orchestrator_validate_runtime "$runtime_raw")"; then
          ralph_orchestrator_log "FAIL parse: invalid RUNTIME '$runtime_raw' (use cursor, claude, codex, opencode, or antigravity)"
          echo -e "${C_R}Invalid RUNTIME '${runtime_raw}'. Use cursor, claude, codex, opencode, or antigravity.${C_RST}" >&2
          exit 1
        fi
        agent="$(echo "$stage" | jq -r '.agent // ""' 2>/dev/null)" || agent=""
        agent_source_raw="$(echo "$stage" | jq -r '.agentSource // ""' 2>/dev/null)" || agent_source_raw=""
        stage_model="$(echo "$stage" | jq -r '.model // ""' 2>/dev/null)" || stage_model=""
        agent_source="$(printf '%s' "${agent_source_raw:-prebuilt}" | tr '[:upper:]' '[:lower:]')"
        [[ -z "$agent_source" ]] && agent_source="prebuilt"
        plan_rel="$(echo "$stage" | jq -r '.plan // ""' 2>/dev/null)" || plan_rel=""
        planTemplate="$(echo "$stage" | jq -r '.planTemplate // ""' 2>/dev/null)" || planTemplate=""
        step_index=$((step_index + 1))
        plan_abs="$(orchestrator_stage_plan_abs "$plan_rel" "$WORKSPACE")"
        plan_tag="$(basename "$plan_abs" | sed 's/\.[^.]*$//')"
        plan_tag="${plan_tag//[^A-Za-z0-9_.-]/_}"
        wave_output_logs+=("$RALPH_LOG_DIR/$RALPH_ARTIFACT_NS/plan-runner-${plan_tag}-output.log")
        stage_usage_file="$RALPH_LOG_DIR/$RALPH_ARTIFACT_NS/parallel-wave-${wave_idx}-stage-${stage_id}.usage.json"
        mkdir -p "$(dirname "$stage_usage_file")"
        if [[ "${ORCHESTRATOR_DRY_RUN:-0}" == "1" ]]; then
          stage_file="$RALPH_LOG_DIR/$RALPH_ARTIFACT_NS/parallel-wave-${wave_idx}-stage-${stage_id}.status"
          mkdir -p "$(dirname "$stage_file")"
          if [[ "${ORCHESTRATOR_RUNNER_TO_CONSOLE:-1}" != "0" ]]; then
            (
              ORCHESTRATOR_PARALLEL_PREFIX_STREAM=1 orch_stage_execute "$step_index" "$stage" "$plan_abs" "$plan_rel" "$runtime" "$agent" "$agent_source" "$stage_model" "$agent_source_raw" "$planTemplate" "$stage_id" "$stage_iter" status_tmp "$stage_usage_file" "$back_idx"
            ) 2>&1 | orch_parallel_stage_prefix_stream "$stage_id" "$(orch_parallel_stage_tag_color "$wave_stage_position")" &
          else
            ( orch_stage_execute "$step_index" "$stage" "$plan_abs" "$plan_rel" "$runtime" "$agent" "$agent_source" "$stage_model" "$agent_source_raw" "$planTemplate" "$stage_id" "$stage_iter" status_tmp "$stage_usage_file" "$back_idx" ) &
          fi
          wave_pid=$!
          orch_register_parallel_pid "$wave_pid"
          wave_pids+=("$wave_pid")
          wave_stage_refs+=("$stage_id:$stage_file")
        else
          stage_file="$RALPH_LOG_DIR/$RALPH_ARTIFACT_NS/parallel-wave-${wave_idx}-stage-${stage_id}.status"
          mkdir -p "$(dirname "$stage_file")"
          if [[ "${ORCHESTRATOR_RUNNER_TO_CONSOLE:-1}" != "0" ]]; then
            (
              ORCHESTRATOR_PARALLEL_PREFIX_STREAM=1 orch_stage_execute "$step_index" "$stage" "$plan_abs" "$plan_rel" "$runtime" "$agent" "$agent_source" "$stage_model" "$agent_source_raw" "$planTemplate" "$stage_id" "$stage_iter" status_tmp "$stage_usage_file" "$back_idx"
              echo "$?" > "$stage_file"
            ) 2>&1 | orch_parallel_stage_prefix_stream "$stage_id" "$(orch_parallel_stage_tag_color "$wave_stage_position")" &
          else
            (
              orch_stage_execute "$step_index" "$stage" "$plan_abs" "$plan_rel" "$runtime" "$agent" "$agent_source" "$stage_model" "$agent_source_raw" "$planTemplate" "$stage_id" "$stage_iter" status_tmp "$stage_usage_file" "$back_idx"
              echo "$?" > "$stage_file"
            ) &
          fi
          wave_pid=$!
          orch_register_parallel_pid "$wave_pid"
          wave_pids+=("$wave_pid")
          wave_stage_refs+=("$stage_id:$stage_file")
        fi
        wave_stage_position=$((wave_stage_position + 1))
      done
      if [[ "${ORCHESTRATOR_RUNNER_TO_CONSOLE:-1}" != "0" ]] && ((${#wave_output_logs[@]} > 0)); then
        wave_follow_cmd="tail -F"
        for wave_output_log in "${wave_output_logs[@]}"; do
          printf -v wave_follow_cmd '%s %q' "$wave_follow_cmd" "$wave_output_log"
        done
        echo -e "${C_DIM}Parallel wave $((wave_idx + 1)) follow:${C_RST} $wave_follow_cmd" >&2
      fi
      for pid in "${wave_pids[@]}"; do
        wait "$pid" || wave_status=1
      done
      orch_clear_parallel_pids
      for stage_ref in "${wave_stage_refs[@]}"; do
        wave_stage_id="${stage_ref%%:*}"
        stage_usage_file="$RALPH_LOG_DIR/$RALPH_ARTIFACT_NS/parallel-wave-${wave_idx}-stage-${wave_stage_id}.usage.json"
        if [[ -f "$stage_usage_file" ]]; then
          if command -v python3 >/dev/null 2>&1; then
            stage_input="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('input_tokens',0))" "$stage_usage_file" 2>/dev/null || echo 0)"
            stage_output="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('output_tokens',0))" "$stage_usage_file" 2>/dev/null || echo 0)"
            stage_cc="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('cache_creation_input_tokens',0))" "$stage_usage_file" 2>/dev/null || echo 0)"
            stage_cr="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('cache_read_input_tokens',0))" "$stage_usage_file" 2>/dev/null || echo 0)"
            _orch_input_tokens=$(( _orch_input_tokens + stage_input ))
            _orch_output_tokens=$(( _orch_output_tokens + stage_output ))
            _orch_cache_creation_tokens=$(( _orch_cache_creation_tokens + stage_cc ))
            _orch_cache_read_tokens=$(( _orch_cache_read_tokens + stage_cr ))
            _orch_stage_usages+="${_orch_stage_usages:+,}$(<"$stage_usage_file")"
            ralph_orchestrator_log "parallel wave $((wave_idx + 1)) stage $wave_stage_id usage: input=${stage_input} output=${stage_output} cache_create=${stage_cc} cache_read=${stage_cr}"
          fi
          rm -f "$stage_usage_file"
        fi
      done
      for stage_ref in "${wave_stage_refs[@]}"; do
        wave_stage_id="${stage_ref%%:*}"
        stage_file="${stage_ref#*:}"
        if [[ -f "$stage_file" ]]; then
          stage_rc="$(cat "$stage_file" 2>/dev/null || echo 1)"
          rm -f "$stage_file"
          if [[ "$stage_rc" -ne 0 ]]; then
            wave_failures+=("$wave_stage_id:$stage_rc")
          fi
        elif [[ $wave_status -ne 0 ]]; then
          wave_failures+=("$wave_stage_id:1")
        fi
      done
      if ((${#wave_failures[@]} > 0)); then
        ralph_orchestrator_log "FAIL parallel wave $((wave_idx + 1)): ${wave_failures[*]}"
        echo "Parallel wave $((wave_idx + 1)) failed: ${wave_failures[*]}" >&2
        exit 1
      fi
    done
  else
    orch_planner_queue_clear
    idx=0
    while (( idx < num_stages )); do
      if [[ "${ORCH_ROUTER_TERMINAL_ACTIVE:-0}" == "1" ]]; then
        ralph_orchestrator_log "router terminal outcome active; stopping sequential execution"
        break
      fi
      stage="$(jq ".stages[$idx]" "$ORCH_FILE" 2>/dev/null)" || continue
      stage_id="$(echo "$stage" | jq -r '.id // empty' 2>/dev/null || echo "")"
      stage_id="$(orch_stage_normalize_id "$stage_id")"
      if [[ -n "$stage_id" ]] && orch_router_skip_map_has "$stage_id" >/dev/null 2>&1; then
        step_index=$((step_index + 1))
        agent="$(echo "$stage" | jq -r '.agent // ""' 2>/dev/null || echo "")"
        runtime="$(echo "$stage" | jq -r '.runtime // "cursor"' 2>/dev/null || echo "cursor")"
        orch_router_record_skipped_stage "$step_index" "$stage_id" "$agent" "$runtime"
        echo -e "${C_DIM}Step ${step_index} skipped by router: ${stage_id}${C_RST}"
        idx=$((idx + 1))
        continue
      fi
      if [[ -n "$stage_id" ]]; then
        stage_iter="$(orch_stage_iteration_map_get "$stage_id")"
      else
        stage_iter=1
      fi
      runtime_raw="$(echo "$stage" | jq -r '.runtime // "cursor"' 2>/dev/null || echo "cursor")"
      if ! runtime="$(orchestrator_validate_runtime "$runtime_raw")"; then
        ralph_orchestrator_log "FAIL parse: invalid RUNTIME '$runtime_raw' (use cursor, claude, codex, opencode, or antigravity)"
        echo -e "${C_R}Invalid RUNTIME '${runtime_raw}'. Use cursor, claude, codex, opencode, or antigravity.${C_RST}" >&2
        echo "  Log: $LOG_FILE" >&2
        exit 1
      fi
      agent="$(echo "$stage" | jq -r '.agent // ""' 2>/dev/null)" || agent=""
      agent_source_raw="$(echo "$stage" | jq -r '.agentSource // ""' 2>/dev/null)" || agent_source_raw=""
      stage_model="$(echo "$stage" | jq -r '.model // ""' 2>/dev/null)" || stage_model=""
      agent_source="$(printf '%s' "${agent_source_raw:-prebuilt}" | tr '[:upper:]' '[:lower:]')"
      [[ -z "$agent_source" ]] && agent_source="prebuilt"
      plan_rel="$(echo "$stage" | jq -r '.plan // ""' 2>/dev/null)" || plan_rel=""
      planTemplate="$(echo "$stage" | jq -r '.planTemplate // ""' 2>/dev/null)" || planTemplate=""
      step_index=$((step_index + 1))
      plan_abs="$(orchestrator_stage_plan_abs "$plan_rel" "$WORKSPACE")"
      if ! orch_stage_execute "$step_index" "$stage" "$plan_abs" "$plan_rel" "$runtime" "$agent" "$agent_source" "$stage_model" "$agent_source_raw" "$planTemplate" "$stage_id" "$stage_iter" step_rc "$idx"; then
        exit 1
      fi
      if [[ "${step_rc:-0}" -gt 0 ]]; then
        if [[ "$step_rc" -eq 3 ]]; then
          exit 3
        fi
        exit "$step_rc"
      fi
      if [[ "${ORCH_ROUTER_TERMINAL_ACTIVE:-0}" == "1" ]]; then
        break
      fi
      if orch_planner_stage_has_planner "$stage"; then
        while orch_planner_queue_has_pending; do
          if ! orch_planner_queue_next_json stage; then
            break
          fi
          stage_id="$(echo "$stage" | jq -r '.id // empty' 2>/dev/null || echo "")"
          stage_id="$(orch_stage_normalize_id "$stage_id")"
          stage_iter=1
          runtime_raw="$(echo "$stage" | jq -r '.runtime // "cursor"' 2>/dev/null || echo "cursor")"
          if ! runtime="$(orchestrator_validate_runtime "$runtime_raw")"; then
            ralph_orchestrator_log "FAIL parse: invalid RUNTIME '$runtime_raw' in generated planner stage"
            exit 1
          fi
          agent="$(echo "$stage" | jq -r '.agent // ""' 2>/dev/null)" || agent=""
          agent_source_raw="$(echo "$stage" | jq -r '.agentSource // ""' 2>/dev/null)" || agent_source_raw=""
          stage_model="$(echo "$stage" | jq -r '.model // ""' 2>/dev/null)" || stage_model=""
          agent_source="$(printf '%s' "${agent_source_raw:-prebuilt}" | tr '[:upper:]' '[:lower:]')"
          [[ -z "$agent_source" ]] && agent_source="prebuilt"
          plan_rel="$(echo "$stage" | jq -r '.plan // ""' 2>/dev/null)" || plan_rel=""
          planTemplate="$(echo "$stage" | jq -r '.planTemplate // ""' 2>/dev/null)" || planTemplate=""
          step_index=$((step_index + 1))
          plan_abs="$(orchestrator_stage_plan_abs "$plan_rel" "$WORKSPACE")"
          if ! orch_stage_execute "$step_index" "$stage" "$plan_abs" "$plan_rel" "$runtime" "$agent" "$agent_source" "$stage_model" "$agent_source_raw" "$planTemplate" "$stage_id" "$stage_iter" step_rc "$idx"; then
            exit 1
          fi
          if [[ "${step_rc:-0}" -gt 0 ]]; then
            if [[ "$step_rc" -eq 3 ]]; then
              exit 3
            fi
            exit "$step_rc"
          fi
          if [[ "${ORCH_ROUTER_TERMINAL_ACTIVE:-0}" == "1" ]]; then
            break 2
          fi
        done
      fi
      idx=$((idx + 1))
    done
  fi
else
  ralph_orchestrator_log "FAIL: orchestration file must be JSON (.orch.json)"
  echo -e "${C_R}${C_BOLD}Error: orchestration file must be JSON${C_RST}" >&2
  echo "  Expected: .orch.json (JSON format)" >&2
  echo "  Got: $(basename "$ORCH_FILE")" >&2
  echo "  See .ralph/orchestration.template.json" >&2
  echo "  Log: $LOG_FILE" >&2
  exit 1
fi

if [[ $step_index -eq 0 ]]; then
  ralph_orchestrator_log "FAIL: no stages found in $ORCH_FILE"
  echo -e "${C_R}No valid stages in orchestration file.${C_RST}" >&2
  echo "  Check the 'stages' array in your JSON file." >&2
  echo "  Template: .ralph/orchestration.template.json" >&2
  echo "  Log: $LOG_FILE" >&2
  exit 1
fi

if [[ "${ORCHESTRATOR_DRY_RUN:-0}" == "1" ]]; then
  ralph_orchestrator_log "dry-run complete ($step_index steps)"
  exit 0
fi

ralph_orchestrator_log "orchestrator complete ($step_index steps)"

# Write orchestration-level usage summary.
_orch_elapsed=$(( $(date +%s) - _orch_start_ts ))
_orch_ended_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
_orch_summary_dir="$RALPH_LOG_DIR/$RALPH_ARTIFACT_NS"
_orch_summary_file="$_orch_summary_dir/orchestration-usage-summary.json"
mkdir -p "$_orch_summary_dir"
cat > "$_orch_summary_file" << _ORCH_SUMMARY_EOF
{"schema_version":1,"kind":"orchestration_usage_summary","orchestration":"$(basename "$ORCH_FILE")","plan_key":"${RALPH_PLAN_KEY:-${RALPH_ARTIFACT_NS:-}}","artifact_ns":"${RALPH_ARTIFACT_NS:-${RALPH_PLAN_KEY:-}}","started_at":"${_orch_started_at}","ended_at":"${_orch_ended_at}","steps":${step_index},"elapsed_seconds":${_orch_elapsed},"input_tokens":${_orch_input_tokens},"output_tokens":${_orch_output_tokens},"cache_creation_input_tokens":${_orch_cache_creation_tokens},"cache_read_input_tokens":${_orch_cache_read_tokens},"stages":[${_orch_stage_usages}]}
_ORCH_SUMMARY_EOF
_orch_elapsed_fmt="$(ralph_format_elapsed_secs "$_orch_elapsed")"
ralph_orchestrator_log "orchestration usage: steps=${step_index} input=${_orch_input_tokens} output=${_orch_output_tokens} cache_create=${_orch_cache_creation_tokens} cache_read=${_orch_cache_read_tokens} elapsed=${_orch_elapsed_fmt}"
_orch_summary_text=""
if command -v python3 &>/dev/null && [[ -f "$RALPH_LOG_DIR/invocation-usage.json" ]]; then
  _orch_summary_text="$(
    python3 "$WORKSPACE/.ralph/python/ralph-usage-summary-text.py" orch \
      --summary "$_orch_summary_file" \
      --invocations "$RALPH_LOG_DIR/invocation-usage.json" 2>/dev/null || true
  )"
fi
echo -e "${C_DIM}Token usage: input=${_orch_input_tokens} output=${_orch_output_tokens} cache_create=${_orch_cache_creation_tokens} cache_read=${_orch_cache_read_tokens} elapsed=${_orch_elapsed_fmt}${C_RST}"
if [[ -n "$_orch_summary_text" ]]; then
  printf '%s\n' "${C_DIM}${_orch_summary_text}${C_RST}"
else
  echo -e "${C_DIM}Total elapsed time: ${_orch_elapsed_fmt}${C_RST}"
fi

echo -e "${C_G}${C_BOLD}Orchestration complete${C_RST} ($step_index steps). Log: $LOG_FILE"
exit 0
