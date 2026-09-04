#!/usr/bin/env bash
# Canonical Ralph orchestrator (repo root: .ralph/orchestrator.sh). Dispatches each JSON
# stage to `.ralph/run-plan.sh` with per-stage `--runtime`, `--plan` (from the stage), and
# optional `--role`.
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
#         "role": "research",
#         "runtime": "cursor", "claude", "codex", "opencode", or "antigravity" (optional, default: cursor),
#         "plan": "path/to/stage-plan.md",
#         "mcpProxyPolicy": "readonly" (optional; forwarded to RALPH_MCP_PROXY_POLICY for that stage),
#         "sessionStrategy": "fresh" | "resume" | "reset" (optional; preferred),
#         "sessionResume": true or false (optional shorthand mapped to session strategy resume/fresh),
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
# Each stage's plan file lists the TODO(s) that stage should complete.
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
# shellcheck source=bash-lib/help-render.sh
source "$RALPH_DIR/bash-lib/help-render.sh"

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
  ralph_help_title "Usage: orchestrator.sh --orchestration <plan> [options]" >&2
  ralph_help_section 'Options' >&2
  ralph_help_command '--workspace-root <path>' 'Set a custom .ralph-workspace location.' >&2
  ralph_help_command '--single-stage <stage> --run-id <id> --attempt-id <id>' 'Execute exactly one stage and write its StageOutcomeReport.' >&2
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
  --model|--model=*)
    echo "Error: orchestration does not accept --model; configure models per stage or voter." >&2
    exit 1
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
if [[ -n "${RALPH_GRAPH_TOOLING_ROOT:-}" ]]; then
  RALPH_ACTIVE_DIR="$(cd "$RALPH_GRAPH_TOOLING_ROOT" 2>/dev/null && pwd -P)" || {
    echo "Orchestrator error: invalid frozen graph tooling root." >&2
    exit 1
  }
elif [[ -f "$WORKSPACE/.ralph/run-plan.sh" && -f "$WORKSPACE/.ralph/ralph-env-safety.sh" ]]; then
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
# Directory run-plan.sh actually writes its per-plan logs into. Mirrors the
# RALPH_LOG_DIR selection in run-plan-core.sh: the graph scheduler sets
# RALPH_GRAPH_NODE_ID so concurrent nodes keep a shared RALPH_ARTIFACT_NS while
# logging under a per-node subdirectory. Every operator-facing log hint must go
# through this, or graph-mode failures point at paths that do not exist.
orch_plan_log_dir() {
  if [[ -n "${RALPH_GRAPH_NODE_LOG_DIR:-}" ]]; then
    printf '%s\n' "$RALPH_GRAPH_NODE_LOG_DIR"
  elif [[ -n "${RALPH_GRAPH_NODE_ID:-}" ]]; then
    printf '%s\n' "$RALPH_LOG_DIR/$RALPH_ARTIFACT_NS"
  else
    printf '%s\n' "$RALPH_LOG_DIR/$RALPH_ARTIFACT_NS"
  fi
}

ORCH_BASENAME="$(basename "$ORCH_FILE" | sed 's/\.[^.]*$//')"
ORCH_BASENAME="${ORCH_BASENAME//[^A-Za-z0-9_.-]/_}"
LOG_FILE="$RALPH_LOG_DIR/orchestrator-${ORCH_BASENAME}.log"
# Ensure the log path exists before the first append (some environments rely on the file for smoke checks).
touch "$LOG_FILE"
RALPH_RUN_PLAN="$RALPH_ACTIVE_DIR/run-plan.sh"
# Populated per stage from stage JSON only (artifacts / outputArtifacts); cleared each iteration.
EXPECTED_ARTIFACT_PATHS=()

ralph_orchestrator_timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

# expand_artifact_tokens, orchestrator_validate_runtime, orch_stage_collect_expected_artifacts, etc.
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
# shellcheck source=bash-lib/orchestrator/orchestrator-verify.sh
source "$RALPH_ACTIVE_DIR/bash-lib/orchestrator/orchestrator-verify.sh"
# shellcheck source=/dev/null
source "$RALPH_ACTIVE_DIR/bash-lib/ralph-format-elapsed.sh"
# shellcheck source=bash-lib/orchestrator/orchestrator-handoffs.sh
source "$RALPH_ACTIVE_DIR/bash-lib/orchestrator/orchestrator-handoffs.sh"
# shellcheck source=/dev/null
source "$RALPH_ACTIVE_DIR/bash-lib/review-status.sh"
# shellcheck source=bash-lib/atomic-json.sh
source "$RALPH_ACTIVE_DIR/bash-lib/atomic-json.sh"
# G10/G11: pure failure-envelope normalizer for the single-stage
# StageOutcomeReport writer below.
if [[ -f "$RALPH_ACTIVE_DIR/bash-lib/graph/graph-failure-classify.sh" ]]; then
  # shellcheck source=bash-lib/graph/graph-failure-classify.sh
  source "$RALPH_ACTIVE_DIR/bash-lib/graph/graph-failure-classify.sh"
fi
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
# shellcheck source=/dev/null
source "$RALPH_ACTIVE_DIR/bash-lib/ralph-process-supervisor.sh"

# The orchestration guardian owns every sequential and parallel stage. Stage
# run-plan processes attach structurally to this registry, so runtime sessions
# remain visible even though output pipelines create additional process groups.
ralph_process_run_init "$RALPH_PLAN_WORKSPACE_ROOT" "$WORKSPACE" "$ORCH_FILE" orchestrator || exit $?

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

  # Persist cancellation intent before TERM reaches owned children. SIGINT is
  # checkpointed only after teardown so the last run-plan atomic plan update
  # has settled.
  if [[ -n "${RALPH_WORKFLOW_REGISTRY_RUN:-}" ]]; then
    orch_workflow_seq_ensure_lib || true
    if declare -F workflow_seq_engine_active >/dev/null 2>&1 &&
      workflow_seq_engine_active "$RALPH_WORKFLOW_REGISTRY_RUN" 2>/dev/null; then
      if [[ "$signal" == "TERM" || "$signal" == "HUP" ]]; then
        workflow_seq_operator_cancel "$RALPH_WORKFLOW_REGISTRY_RUN" || true
      fi
    fi
  fi

  # Registry-backed sessions are authoritative. This includes runtime CLIs
  # that called setsid beneath a stage and therefore escaped its pipeline PGID.
  ralph_process_stop_active "orchestrator-signal-${signal}" || true

  # Stop the active sequential runner and reap it.
  if [[ "$ORCH_RUNNER_PID" =~ ^[0-9]+$ ]] && kill -0 "$ORCH_RUNNER_PID" 2>/dev/null; then
    ralph_kill_tree_and_reap "$ORCH_RUNNER_PID" 2>/dev/null || true
  fi
  orch_clear_runner_pid

  # Stop every active parallel-wave stage wrapper and reap it.
  orch_reap_parallel_pids

  if [[ "$signal" == "INT" && -n "${RALPH_WORKFLOW_REGISTRY_RUN:-}" ]]; then
    if declare -F workflow_seq_engine_active >/dev/null 2>&1 &&
      workflow_seq_engine_active "$RALPH_WORKFLOW_REGISTRY_RUN" 2>/dev/null; then
      workflow_seq_operator_interrupt_checkpoint "$RALPH_WORKFLOW_REGISTRY_RUN" || true
    fi
  fi

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
  # Repeated signals stay ignored until registry teardown finishes. Restoring
  # defaults here could kill the orchestrator between TERM and KILL passes.
  trap '' INT TERM HUP
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
# Thin wrapper around the shared ralph_fsync_path from atomic-json.sh; kept
# for any in-tree callers that still reference the orch_ name.
orch_fsync_path() {
  ralph_fsync_path "$1"
}

# orch_single_stage_write_report <outcome> <exit_code> <reason> [evidence-json]
#
# G10: writes the current schema. Identity and timing fields remain stable;
# a non-success outcome additionally gets
# an optional `failure` object built by the pure G10/G11 normalizer in
# graph-failure-classify.sh (graph_failure_classify_v2). [evidence-json] is
# an optional compact JSON object a caller may supply with richer G11
# evidence (timeoutMarker, cancelMarker, nativePermission, offendingPaths,
# missingArtifacts, ...); it is merged over the exitCode/reason this
# function always has, so a caller with no extra evidence still gets a
# best-effort classification instead of an invented one. A success outcome
# never gets a `failure` object.
orch_single_stage_write_report() {
  local outcome="$1" exit_code="$2" reason="${3:-}" evidence_extra="${4:-}"
  [[ "${SINGLE_STAGE_MODE:-0}" == "1" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 1
  [[ "$exit_code" =~ ^-?[0-9]+$ ]] || exit_code=1
  local report_path report_dir finished_at
  report_path="$(orch_single_stage_report_path)" || return 1
  report_dir="$(dirname "$report_path")"
  mkdir -p "$report_dir" 2>/dev/null || return 1
  finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local failure_json="null"
  if [[ "$outcome" != "success" ]] && declare -F graph_failure_classify_v2 >/dev/null 2>&1; then
    local base_evidence merged_evidence
    base_evidence="$(jq -nc --argjson exitCode "$exit_code" --arg reason "$reason" \
      '{exitCode: $exitCode} + (if $reason == "" then {} else {reason: $reason, summary: $reason} end)' 2>/dev/null)"
    if [[ -n "$base_evidence" ]]; then
      if [[ -n "$evidence_extra" ]] && printf '%s' "$evidence_extra" | jq -e 'type == "object"' >/dev/null 2>&1; then
        merged_evidence="$(jq -nc --argjson base "$base_evidence" --argjson extra "$evidence_extra" '$base * $extra' 2>/dev/null)"
      else
        merged_evidence="$base_evidence"
      fi
      if [[ -n "$merged_evidence" ]]; then
        failure_json="$(graph_failure_classify_v2 "$merged_evidence" 2>/dev/null)" || failure_json=""
        [[ -n "$failure_json" ]] || failure_json="null"
      fi
    fi
  fi

  if ! ralph_atomic_write_json "$report_path" \
    '{schemaVersion: $schemaVersion, runId: $runId, stageId: $stageId, attemptId: $attemptId, outcome: $outcome, exitCode: $exitCode, startedAt: $startedAt, finishedAt: $finishedAt}
       + (if $reason == "" then {} else {reason: $reason} end)
       + (if $failure == null then {} else {failure: $failure} end)' \
    --argjson schemaVersion 2 \
    --arg runId "$SINGLE_STAGE_RUN_ID" \
    --arg stageId "$SINGLE_STAGE_ID" \
    --arg attemptId "$SINGLE_STAGE_ATTEMPT_ID" \
    --arg outcome "$outcome" \
    --argjson exitCode "$exit_code" \
    --arg startedAt "${SINGLE_STAGE_STARTED_AT:-$finished_at}" \
    --arg finishedAt "$finished_at" \
    --arg reason "$reason" \
    --argjson failure "$failure_json"; then
    return 1
  fi
  SINGLE_STAGE_REPORT_WRITTEN=1
  return 0
}

# EXIT trap for single-stage mode: if the stage terminated before a report was
# written (runner failure, artifact failure, or a signal), emit a failed or
# cancelled report using the process exit code, without masking it. A
# received signal is passed through as a G11 tier-1 cancellation marker so
# the failure envelope carries that evidence instead of only generic text.
orch_exit_trap() {
  local ec=$?
  if [[ "${SINGLE_STAGE_MODE:-0}" == "1" && "${SINGLE_STAGE_REPORT_WRITTEN:-0}" != "1" ]]; then
    local outcome="failed" reason="stage terminated before completion" evidence=""
    if [[ -n "${ORCH_INTERRUPT_SIGNAL:-}" ]]; then
      outcome="cancelled"
      reason="received signal ${ORCH_INTERRUPT_SIGNAL}"
      evidence="$(jq -nc --arg owner "orchestrator" --arg signal "$ORCH_INTERRUPT_SIGNAL" \
        '{cancelMarker: {owner: $owner, signal: $signal}}' 2>/dev/null)"
    fi
    orch_single_stage_write_report "$outcome" "$ec" "$reason" "$evidence" || true
  fi
  ralph_process_run_close "orchestrator-exit" || true
  return "$ec"
}

trap 'orch_exit_trap' EXIT

# Override the bash-lib remediation copy so operators see the live CLI path.
artifact_remediation_text() {
  echo "  Remediation:"
  echo "    1. Open the step plan and ensure the agent finished every TODO (agent should write declared outputs)."
  echo "    2. Create or fill the missing path under the repo root (see .ralph-workspace/artifacts/ for handoff files)."
  echo "    3. To require different files for this step, edit artifacts or outputArtifacts in the JSON stage."
  echo "    4. Re-run from repo root: $0 --orchestration \"$ORCH_FILE\" \"$WORKSPACE\""
}

# G12: the one resolved-path function. A required-artifact path declared on
# a stage always resolves the same way for every consumer -- artifact
# verification (verify_step_artifacts below), the StageOutcomeReport
# missingArtifacts evidence, and the agent-facing prompt block
# (ralph_artifact_namespace_prompt_block in run-plan-artifacts.sh, fed via
# RALPH_REQUIRED_ARTIFACT_PATHS_JSON) all call this instead of re-deriving
# the answer independently:
#   - an already-absolute path passes through unchanged;
#   - a `.ralph-workspace/artifacts/...` path resolves under
#     RALPH_ARTIFACT_ROOT (<state-root>/artifacts/<namespace>) when that is
#     set -- the supervisor's own artifact directory, never the isolated
#     agent workspace's own throwaway `.ralph-workspace`;
#   - any other `.ralph-workspace/...` path resolves under
#     RALPH_PLAN_WORKSPACE_ROOT (the state root);
#   - anything else resolves relative to $WORKSPACE (the agent workspace),
#     matching source-edit paths declared without the artifacts prefix.
orch_resolve_artifact_path() {
  local raw="${1:-}"
  if [[ "$raw" == /* ]]; then
    printf '%s\n' "$raw"
    return 0
  fi
  if [[ "$raw" == .ralph-workspace/artifacts/* && -n "${RALPH_ARTIFACT_ROOT:-}" ]]; then
    local ns_prefix=".ralph-workspace/artifacts/${RALPH_ARTIFACT_NS:-}/"
    if [[ -n "${RALPH_ARTIFACT_NS:-}" && "$raw" == "$ns_prefix"* ]]; then
      printf '%s/%s\n' "${RALPH_ARTIFACT_ROOT%/}" "${raw#"$ns_prefix"}"
    else
      printf '%s/%s\n' "${RALPH_ARTIFACT_ROOT%/}" "${raw#.ralph-workspace/artifacts/}"
    fi
    return 0
  fi
  if [[ "$raw" == .ralph-workspace/* && -n "${RALPH_PLAN_WORKSPACE_ROOT:-}" ]]; then
    printf '%s/%s\n' "${RALPH_PLAN_WORKSPACE_ROOT%/}" "${raw#.ralph-workspace/}"
    return 0
  fi
  printf '%s/%s\n' "$WORKSPACE" "$raw"
}

# G12: absolute, resolved required-artifact paths for the current stage, as
# a compact JSON array. Empty when there are no expected artifacts. Used to
# populate RALPH_REQUIRED_ARTIFACT_PATHS_JSON so the agent prompt names the
# exact supervisor-owned destinations instead of leaving the agent to guess
# a path relative to its own isolated workspace.
orch_required_artifact_paths_json() {
  local ap abs
  local -a resolved=()
  for ap in "${EXPECTED_ARTIFACT_PATHS[@]}"; do
    abs="$(orch_resolve_artifact_path "$ap")"
    resolved+=("$abs")
  done
  if ((${#resolved[@]} == 0)); then
    printf '[]\n'
    return 0
  fi
  printf '%s\n' "${resolved[@]}" | jq -R . | jq -sc .
}

# Populated by verify_step_artifacts on failure: the resolved absolute
# paths of every missing or empty required artifact, so the caller can pass
# them as G11 tier-4 evidence to orch_single_stage_write_report instead of
# falling through to a generic exit-trap classification.
ORCH_MISSING_ARTIFACT_PATHS=()

# After each successful delegated run: each expected artifact must exist and be non-empty.
verify_step_artifacts() {
  local step_n="$1"
  local ap abs
  ORCH_MISSING_ARTIFACT_PATHS=()
  if ((${#EXPECTED_ARTIFACT_PATHS[@]} > 0)); then
    for ap in "${EXPECTED_ARTIFACT_PATHS[@]}"; do
    abs="$(orch_resolve_artifact_path "$ap")"
    if [[ ! -f "$abs" ]]; then
      ORCH_MISSING_ARTIFACT_PATHS+=("$abs")
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
      continue
    fi
    if [[ ! -s "$abs" ]]; then
      ORCH_MISSING_ARTIFACT_PATHS+=("$abs")
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
      continue
    fi
    done
  fi
  ((${#ORCH_MISSING_ARTIFACT_PATHS[@]} == 0))
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

  # Check review status (schema-aware; falls back to markdown when no schema is declared).
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

# Extract optional stage instructions for the run-plan prompt bridge. Returns
# empty when absent. Always safe to assign into RALPH_WORKFLOW_STAGE_INSTRUCTIONS
# (empty clears ambient leakage for stages without instructions).
orch_stage_instructions_from_json() {
  local stage_json="$1"
  local instructions=""
  instructions="$(echo "$stage_json" | jq -r '.instructions // empty' 2>/dev/null)" || instructions=""
  printf '%s' "$instructions"
}

# Reject removed agent / agentSource keys. Role ids are obsolete; callers may
# still receive an empty role string when absent. Prints the role id (may be
# empty) on success; exits 1 with replacement guidance on removed syntax.
orch_stage_role_from_json() {
  local stage_json="$1"
  if echo "$stage_json" | jq -e 'has("agent")' >/dev/null 2>&1; then
    echo "Error: stage agent was removed. Use inline workflow instructions (instructions: text)." >&2
    return 1
  fi
  if echo "$stage_json" | jq -e 'has("agentSource")' >/dev/null 2>&1; then
    echo "Error: stage agentSource was removed. Use inline workflow instructions (instructions: text)." >&2
    return 1
  fi
  local role=""
  role="$(echo "$stage_json" | jq -r '.role // ""' 2>/dev/null)" || role=""
  if [[ -n "$role" && ! "$role" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
    echo "Error: stage role must be a non-empty id matching ^[a-z0-9]+(-[a-z0-9]+)*$ (got '$role')" >&2
    return 1
  fi
  printf '%s\n' "$role"
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

# Soft-load Sequential engine journal helpers (RALPH_ACTIVE_DIR, then RALPH_DIR).
orch_workflow_seq_ensure_lib() {
  local lib=""
  if declare -F workflow_seq_orch_journal_before >/dev/null 2>&1; then
    return 0
  fi
  if [[ -f "${RALPH_ACTIVE_DIR:-}/bash-lib/workflow/workflow-engine-sequential.sh" ]]; then
    lib="${RALPH_ACTIVE_DIR}/bash-lib/workflow/workflow-engine-sequential.sh"
  elif [[ -f "${RALPH_DIR:-}/bash-lib/workflow/workflow-engine-sequential.sh" ]]; then
    lib="${RALPH_DIR}/bash-lib/workflow/workflow-engine-sequential.sh"
  else
    return 1
  fi
  # shellcheck source=bash-lib/workflow/workflow-engine-sequential.sh
  source "$lib"
}

# Journal stage start when Sequential engine/run.json is active. Never fails the stage.
orch_workflow_seq_journal_before() {
  local stage_id="${1:-}" stage_index="${2:-0}" stage_json="${3:-}" stage_iter="${4:-0}"
  local wave=""
  [[ -n "${RALPH_WORKFLOW_REGISTRY_RUN:-}" ]] || return 0
  orch_workflow_seq_ensure_lib || return 0
  if ! declare -F workflow_seq_engine_active >/dev/null 2>&1; then
    return 0
  fi
  workflow_seq_engine_active "$RALPH_WORKFLOW_REGISTRY_RUN" || return 0
  if [[ -n "${ORCH_FILE:-}" && -f "${ORCH_FILE:-}" ]]; then
    wave="$(jq -r --arg id "$stage_id" '
      (.parallelStages // []) as $waves
      | if ($waves | length) == 0 then ""
        else
          (reduce range(0; $waves | length) as $i
            ({found:""};
              if .found != "" then .
              else
                (($waves[$i] | if type == "string" then split(",") else . end)
                  | map(gsub("^\\s+|\\s+$";""))
                  | index($id)) as $pos
                | if $pos != null then .found = ($i | tostring) else . end
              end)
            | .found)
        end
    ' "$ORCH_FILE" 2>/dev/null)" || wave=""
  fi
  workflow_seq_orch_journal_before \
    "$RALPH_WORKFLOW_REGISTRY_RUN" \
    "$stage_id" \
    "$stage_index" \
    "$stage_json" \
    "$stage_iter" \
    "$wave" || true
}

# Journal stage finish. Preserves caller exit semantics (soft journal failure).
orch_workflow_seq_journal_after() {
  local stage_id="${1:-}" exit_code="${2:-1}" stage_json="${3:-}"
  local artifacts_json="[]"
  [[ -n "${RALPH_WORKFLOW_REGISTRY_RUN:-}" ]] || return 0
  orch_workflow_seq_ensure_lib || return 0
  if ! declare -F workflow_seq_engine_active >/dev/null 2>&1; then
    return 0
  fi
  workflow_seq_engine_active "$RALPH_WORKFLOW_REGISTRY_RUN" || return 0
  if ((${#EXPECTED_ARTIFACT_PATHS[@]} > 0)); then
    artifacts_json="$(printf '%s\n' "${EXPECTED_ARTIFACT_PATHS[@]}" | jq -R . | jq -cs .)"
  fi
  workflow_seq_orch_journal_after \
    "$RALPH_WORKFLOW_REGISTRY_RUN" \
    "$stage_id" \
    "$exit_code" \
    "$stage_json" \
    "$artifacts_json" || true
}

# True when Sequential engine says this stage already succeeded (resume skip).
orch_workflow_seq_should_skip_succeeded() {
  local stage_id="${1:-}"
  [[ -n "${RALPH_WORKFLOW_REGISTRY_RUN:-}" && -n "$stage_id" ]] || return 1
  orch_workflow_seq_ensure_lib || return 1
  declare -F workflow_seq_stage_should_skip >/dev/null 2>&1 || return 1
  workflow_seq_engine_active "$RALPH_WORKFLOW_REGISTRY_RUN" || return 1
  workflow_seq_stage_should_skip "$RALPH_WORKFLOW_REGISTRY_RUN" "$stage_id"
}

# Prefer durable control plan path from the Sequential engine ledger when set.
orch_workflow_seq_resolve_plan_override() {
  local stage_id="${1:-}" control=""
  [[ -n "${RALPH_WORKFLOW_REGISTRY_RUN:-}" && -n "$stage_id" ]] || return 0
  orch_workflow_seq_ensure_lib || return 0
  declare -F workflow_seq_resolve_control_plan >/dev/null 2>&1 || return 0
  workflow_seq_engine_active "$RALPH_WORKFLOW_REGISTRY_RUN" || return 0
  control="$(workflow_seq_resolve_control_plan "$RALPH_WORKFLOW_REGISTRY_RUN" "$stage_id" 2>/dev/null)" || control=""
  if [[ -n "$control" && -f "$control" ]]; then
    printf '%s\n' "$control"
  fi
  return 0
}

# Before a Sequential planFrom stage runs: resolve planner evidence, create or
# reuse the control copy, project orch plan + fresh sessionStrategy, and
# persist progress fields. Prints the control plan path on stdout. Fails closed
# (non-zero) when evidence is missing/invalid so the stage never reaches a
# runtime. No-op (empty stdout, exit 0) when the stage is not planFrom or the
# Sequential engine is inactive.
orch_workflow_seq_prepare_planfrom() {
  local stage_id="${1:-}" stage_json="${2:-}"
  local plan_from="" binding control force_args=()

  [[ -n "${RALPH_WORKFLOW_REGISTRY_RUN:-}" && -n "$stage_id" ]] || return 0
  plan_from="$(printf '%s' "$stage_json" | jq -r '.planFrom // empty' 2>/dev/null)" || plan_from=""
  [[ -n "$plan_from" ]] || return 0

  orch_workflow_seq_ensure_lib || {
    echo "Error: Sequential planFrom requires workflow-engine-sequential.sh" >&2
    return 1
  }
  declare -F workflow_seq_bind_planfrom_control >/dev/null 2>&1 || {
    echo "Error: workflow_seq_bind_planfrom_control unavailable" >&2
    return 1
  }
  workflow_seq_engine_active "$RALPH_WORKFLOW_REGISTRY_RUN" || {
    echo "Error: Sequential planFrom requires an active sequential engine ledger" >&2
    return 1
  }
  [[ -n "${ORCH_FILE:-}" && -f "${ORCH_FILE:-}" ]] || {
    echo "Error: Sequential planFrom requires ORCH_FILE for control projection" >&2
    return 1
  }

  # Consumer-only reset: RALPH_WORKFLOW_SEQ_PLANFROM_FORCE_FRESH=1 creates a
  # fresh control copy from the same verified planner source.
  if [[ "${RALPH_WORKFLOW_SEQ_PLANFROM_FORCE_FRESH:-0}" == "1" ]]; then
    force_args=(--force-fresh)
  fi

  binding="$(
    workflow_seq_bind_planfrom_control \
      --registry-run "$RALPH_WORKFLOW_REGISTRY_RUN" \
      --orch-path "$ORCH_FILE" \
      --stage-id "$stage_id" \
      "${force_args[@]}"
  )" || {
    ralph_orchestrator_log "FAIL planFrom bind: missing/invalid generated plan for $stage_id (planner=$plan_from)"
    echo -e "${C_R}${C_BOLD}planFrom blocked before runtime: invalid or missing planner plan for '${stage_id}'${C_RST}" >&2
    return 1
  }
  control="$(printf '%s' "$binding" | jq -r '.controlPlanPath // empty')"
  [[ -n "$control" && -f "$control" ]] || {
    echo "Error: planFrom bind did not produce a control plan for $stage_id" >&2
    return 1
  }
  printf '%s\n' "$control"
  return 0
}

# Sequential provided plan (planInput): bind/validate common input + control
# copy for the designated stage only, before any runtime invocation.
# No-op when the stage is not the planInput consumer. Missing/corrupt input
# fails closed. Consumer-only reset: RALPH_WORKFLOW_SEQ_PROVIDED_FORCE_FRESH=1.
orch_workflow_seq_prepare_provided() {
  local stage_id="${1:-}" stage_json="${2:-}"
  local binding control force_args=()

  [[ -n "${RALPH_WORKFLOW_REGISTRY_RUN:-}" && -n "$stage_id" ]] || return 0

  orch_workflow_seq_ensure_lib || {
    # Soft-load failure: only hard-fail when this stage is clearly the consumer.
    if [[ -n "${RALPH_WORKFLOW_PLAN_INPUT_STAGE:-}" && \
          "${RALPH_WORKFLOW_PLAN_INPUT_STAGE}" == "$stage_id" ]]; then
      echo "Error: Sequential provided plan requires workflow-engine-sequential.sh" >&2
      return 1
    fi
    return 0
  }
  declare -F workflow_seq_stage_is_provided_consumer >/dev/null 2>&1 || return 0
  declare -F workflow_seq_bind_provided_plan_control >/dev/null 2>&1 || {
    if workflow_seq_stage_is_provided_consumer "$RALPH_WORKFLOW_REGISTRY_RUN" "$stage_id"; then
      echo "Error: workflow_seq_bind_provided_plan_control unavailable" >&2
      return 1
    fi
    return 0
  }
  workflow_seq_engine_active "$RALPH_WORKFLOW_REGISTRY_RUN" || return 0
  workflow_seq_stage_is_provided_consumer "$RALPH_WORKFLOW_REGISTRY_RUN" "$stage_id" || return 0

  # planFrom takes precedence (task-entry generated path); provided bind is
  # only for the designated planInput consumer without planFrom.
  if printf '%s' "$stage_json" | jq -e '(.planFrom // "") != ""' >/dev/null 2>&1; then
    return 0
  fi

  [[ -n "${ORCH_FILE:-}" && -f "${ORCH_FILE:-}" ]] || {
    echo "Error: Sequential provided plan requires ORCH_FILE for control projection" >&2
    return 1
  }

  if [[ "${RALPH_WORKFLOW_SEQ_PROVIDED_FORCE_FRESH:-0}" == "1" ]]; then
    force_args=(--force-fresh)
  fi

  binding="$(
    workflow_seq_bind_provided_plan_control \
      --registry-run "$RALPH_WORKFLOW_REGISTRY_RUN" \
      --orch-path "$ORCH_FILE" \
      --stage-id "$stage_id" \
      "${force_args[@]}"
  )" || {
    ralph_orchestrator_log "FAIL provided-plan bind: missing/invalid input for $stage_id"
    echo -e "${C_R}${C_BOLD}provided plan blocked before runtime: missing or invalid input for '${stage_id}'${C_RST}" >&2
    return 1
  }
  control="$(printf '%s' "$binding" | jq -r '.controlPlanPath // empty')"
  [[ -n "$control" && -f "$control" ]] || {
    echo "Error: provided-plan bind did not produce a control plan for $stage_id" >&2
    return 1
  }
  printf '%s\n' "$control"
  return 0
}

# Before dispatching a stage, recheck required artifacts of every succeeded
# lower-index prerequisite recorded in the Sequential engine ledger.
orch_workflow_seq_recheck_prereq_artifacts() {
  local stage_id="${1:-}" id
  [[ -n "${RALPH_WORKFLOW_REGISTRY_RUN:-}" && -n "$stage_id" ]] || return 0
  orch_workflow_seq_ensure_lib || return 0
  declare -F workflow_seq_list_stage_ids >/dev/null 2>&1 || return 0
  workflow_seq_engine_active "$RALPH_WORKFLOW_REGISTRY_RUN" || return 0
  while IFS= read -r id || [[ -n "$id" ]]; do
    [[ -z "$id" || "$id" == "$stage_id" ]] && continue
    if workflow_seq_stage_should_skip "$RALPH_WORKFLOW_REGISTRY_RUN" "$id" 2>/dev/null; then
      if ! workflow_seq_recheck_stage_artifacts \
          --registry-run "$RALPH_WORKFLOW_REGISTRY_RUN" \
          --stage-id "$id" \
          --workspace "${WORKSPACE:-$PWD}"; then
        ralph_orchestrator_log "FAIL artifact recheck: prerequisite stage $id failed for $stage_id"
        echo -e "${C_R}${C_BOLD}Artifact recheck failed for succeeded prerequisite '${id}'${C_RST}" >&2
        return 1
      fi
    fi
  done < <(workflow_seq_list_stage_ids "$RALPH_WORKFLOW_REGISTRY_RUN")
  return 0
}

# True when Sequential workflow engine owns this run and sourceKind is not the
# explicitly internal classic-orchestration path (legacy humanAck retained there).
orch_workflow_seq_uses_common_actions() {
  local kind=""
  [[ -n "${RALPH_WORKFLOW_REGISTRY_RUN:-}" ]] || return 1
  orch_workflow_seq_ensure_lib || return 1
  declare -F workflow_seq_engine_active >/dev/null 2>&1 || return 1
  workflow_seq_engine_active "$RALPH_WORKFLOW_REGISTRY_RUN" || return 1
  if declare -F workflow_seq_is_legacy_orchestration_input >/dev/null 2>&1; then
    workflow_seq_is_legacy_orchestration_input "$RALPH_WORKFLOW_REGISTRY_RUN" && return 1
  else
    kind="$(jq -r '.sourceKind // empty' "$RALPH_WORKFLOW_REGISTRY_RUN/run.json" 2>/dev/null)" || kind=""
    [[ "$kind" == "legacy-orchestration" ]] && return 1
  fi
  return 0
}

# Public Sequential approval: durable common action request, exit 3, no agent.
# Returns 0 after parking (caller must exit 3). Returns 1 on activation failure.
orch_workflow_seq_handle_approval_stage() {
  local stage_id="${1:-}" stage_json="${2:-}" stage_index="${3:-0}" stage_iter="${4:-0}"
  local step_n="${5:-0}"
  local run_id attempt_id namespace activation wave orch_json=""
  local workspace="${WORKSPACE:-$PWD}"

  [[ -n "$stage_id" && -n "$stage_json" ]] || return 1
  orch_workflow_seq_ensure_lib || {
    echo "Error: Sequential approval requires workflow-engine-sequential.sh" >&2
    return 1
  }
  declare -F workflow_seq_approval_activate >/dev/null 2>&1 || {
    echo "Error: workflow_seq_approval_activate unavailable" >&2
    return 1
  }
  orch_workflow_seq_uses_common_actions || {
    echo "Error: type:approval requires an active Sequential workflow run (not legacy-orchestration)" >&2
    return 1
  }

  run_id="${RALPH_WORKFLOW_RUN_ID:-$(jq -r '.runId // empty' "$RALPH_WORKFLOW_REGISTRY_RUN/run.json" 2>/dev/null)}"
  [[ -n "$run_id" ]] || {
    echo "Error: Sequential approval missing run id" >&2
    return 1
  }
  namespace="$(jq -r '.namespace // .name // "workflow"' "${ORCH_FILE:-/dev/null}" 2>/dev/null)" || namespace="workflow"
  [[ -n "$namespace" && "$namespace" != "null" ]] || namespace="workflow"
  attempt_id="${RALPH_WORKFLOW_STAGE_ATTEMPT:-${stage_id}-${stage_iter:-1}}"
  if [[ -n "${ORCH_FILE:-}" && -f "${ORCH_FILE:-}" ]]; then
    orch_json="$ORCH_FILE"
  fi
  wave=""
  if [[ -n "$orch_json" ]]; then
    wave="$(jq -r --arg id "$stage_id" '
      (.parallelStages // []) as $waves
      | if ($waves | length) == 0 then ""
        else
          (reduce range(0; $waves | length) as $i
            ({found:""};
              if .found != "" then .
              else
                (($waves[$i] | if type == "string" then split(",") else . end)
                  | map(gsub("^\\s+|\\s+$";""))
                  | index($id)) as $pos
                | if $pos != null then .found = ($i | tostring) else . end
              end)
            | .found)
        end
    ' "$orch_json" 2>/dev/null)" || wave=""
  fi

  orch_workflow_seq_journal_before "$stage_id" "$stage_index" "$stage_json" "$stage_iter"

  local activate_args=(
    --workspace "$workspace"
    --namespace "$namespace"
    --run-id "$run_id"
    --registry-run "$RALPH_WORKFLOW_REGISTRY_RUN"
    --stage-id "$stage_id"
    --attempt-id "$attempt_id"
  )
  if [[ -n "$orch_json" ]]; then
    activate_args+=(--orch-json "$orch_json")
  else
    activate_args+=(--stage-json "$stage_json")
  fi
  if [[ -n "$wave" && "$wave" != "null" ]]; then
    activate_args+=(--wave "$wave")
  fi

  if ! activation="$(workflow_seq_approval_activate "${activate_args[@]}")"; then
    ralph_orchestrator_log "FAIL step $step_n: Sequential approval activate failed for $stage_id"
    orch_workflow_seq_journal_after "$stage_id" 1 "$stage_json"
    return 1
  fi

  ralph_orchestrator_log "step $step_n: Sequential approval waiting (exit 3; no runtime) request=$(printf '%s' "$activation" | jq -r '.requestId')"
  echo "" >&2
  local opview_lib="" approval_q approval_ct request_id status_json wf_id task_text entry_kind task_prov
  request_id="$(printf '%s' "$activation" | jq -r '.requestId // empty')"
  approval_q="$(echo "$stage_json" | jq -r '.question // empty' 2>/dev/null)"
  approval_ct="$(echo "$stage_json" | jq -r '.changesTarget // empty' 2>/dev/null)"
  if [[ -f "${RALPH_ACTIVE_DIR:-}/bash-lib/workflow/workflow-operator-view.sh" ]]; then
    opview_lib="${RALPH_ACTIVE_DIR}/bash-lib/workflow/workflow-operator-view.sh"
  elif [[ -f "${RALPH_DIR:-}/bash-lib/workflow/workflow-operator-view.sh" ]]; then
    opview_lib="${RALPH_DIR}/bash-lib/workflow/workflow-operator-view.sh"
  fi
  if [[ -n "$opview_lib" ]]; then
    # shellcheck source=bash-lib/workflow/workflow-operator-view.sh
    source "$opview_lib"
    wf_id="$(jq -r '.workflowId // "-"' "$RALPH_WORKFLOW_REGISTRY_RUN/run.json" 2>/dev/null)"
    task_text="$(jq -r '.task // ""' "$RALPH_WORKFLOW_REGISTRY_RUN/run.json" 2>/dev/null)"
    entry_kind="$(jq -r '.entryKind // "task"' "$RALPH_WORKFLOW_REGISTRY_RUN/run.json" 2>/dev/null)"
    task_prov="$(jq -r '.taskProvenance // "explicit"' "$RALPH_WORKFLOW_REGISTRY_RUN/run.json" 2>/dev/null)"
    status_json="$(jq -cn \
      --arg runId "$run_id" \
      --arg wf "$wf_id" \
      --arg task "$task_text" \
      --arg entry "$entry_kind" \
      --arg prov "$task_prov" \
      --arg stageId "$stage_id" \
      --arg requestId "$request_id" \
      --arg question "$approval_q" \
      --arg changesTarget "$approval_ct" \
      '{
        schemaVersion: 1,
        run: {runId:$runId, workflowId:$wf, mode:"sequential", entryKind:$entry, task:$task, taskProvenance:$prov},
        stages: [{
          id: $stageId, state: "waiting", stageKind: "approval",
          approval: {question: $question, changesTarget: $changesTarget},
          requestId: $requestId, requestState: "outstanding", evidence: []
        }],
        diagnosis: {
          state: "waiting", reasonCode: "human-approval",
          summary: "the run is waiting for the operator to decide an approval gate",
          stageId: $stageId, requestKind: "approval", requestId: $requestId,
          retryable: false, evidence: []
        },
        nextAction: {label: "answer the outstanding request", argv: ["ralph","workflow","actions","list",$runId]}
      }')"
    workflow_operator_render_status "$status_json" stderr
  else
    echo -e "${C_Y}${C_BOLD}Human approval required (Sequential workflow)${C_RST}" >&2
    echo "  Stage: $stage_id" >&2
    echo "  Request: $request_id" >&2
    echo "  Decide with: ralph workflow actions list $run_id" >&2
    echo "  Then: ralph workflow resume $run_id" >&2
  fi
  echo "  Log: $LOG_FILE" >&2
  # Activate already parked waiting+blocker; journal_after exit 3 keeps blocker.
  orch_workflow_seq_journal_after "$stage_id" 3 "$stage_json"
  return 0
}

orch_stage_execute() {
  local step_n="$1"
  local stage="$2"
  local plan_abs="$3"
  local plan_rel="$4"
  local runtime="$5"
  local role="$6"
  local agent_source="$7"
  local stage_model="$8"
  local agent_source_raw="$9"
  local stage_id="${10}"
  local stage_iter="${11}"
  local step_status_var="${12}"
  local stage_usage_file="${13:-}"
  local stage_index="${14:-0}"
  local stage_context_budget=""
  local stage_native_subagents=""
  local stage_mcp_proxy_policy=""
  local stage_mcp_proxy_policy_type=""
  local _seq_plan_override=""
  # Role is instruction-only; required outputs come exclusively from the stage.
  local agent="$role"

  # Sequential resume: never rerun a stage the engine already marked succeeded.
  if [[ -n "$stage_id" ]] && orch_workflow_seq_should_skip_succeeded "$stage_id"; then
    ralph_orchestrator_log "step $step_n skipped: sequential engine stage already succeeded ($stage_id)"
    echo -e "${C_DIM}Step ${step_n} skipped (already succeeded): ${stage_id}${C_RST}" >&2
    printf -v "$step_status_var" '%s' 0
    return 0
  fi

  # Public Sequential approval: common actions, exit 3, never invoke an agent.
  local _seq_stage_type=""
  _seq_stage_type="$(echo "$stage" | jq -r '.type // empty' 2>/dev/null)" || _seq_stage_type=""
  if [[ "$_seq_stage_type" == "approval" ]]; then
    if orch_workflow_seq_handle_approval_stage "$stage_id" "$stage" "$stage_index" "$stage_iter" "$step_n"; then
      printf -v "$step_status_var" '%s' 3
      exit 3
    fi
    printf -v "$step_status_var" '%s' 1
    return 1
  fi

  # Before downstream dispatch, recheck required artifacts of succeeded prerequisites.
  if [[ -n "$stage_id" ]] && ! orch_workflow_seq_recheck_prereq_artifacts "$stage_id"; then
    printf -v "$step_status_var" '%s' 1
    return 1
  fi

  # Sequential planFrom: bind/verify control copy before any runtime invocation.
  # Missing/invalid planner evidence fails closed here.
  local _seq_planfrom_control=""
  if [[ -n "$stage_id" ]]; then
    if ! _seq_planfrom_control="$(orch_workflow_seq_prepare_planfrom "$stage_id" "$stage")"; then
      printf -v "$step_status_var" '%s' 1
      return 1
    fi
    if [[ -n "$_seq_planfrom_control" ]]; then
      plan_abs="$_seq_planfrom_control"
      plan_rel="$_seq_planfrom_control"
      # Re-read projected stage (plan + sessionStrategy fresh) after orch mutation.
      if [[ -n "${ORCH_FILE:-}" && -f "${ORCH_FILE:-}" ]]; then
        stage="$(jq -c --arg id "$stage_id" '.stages[] | select(.id == $id)' "$ORCH_FILE" 2>/dev/null)" || true
      fi
      ralph_orchestrator_log "step $step_n sequential planFrom control: $plan_abs"
    fi
  fi

  # Sequential provided plan (planInput): bind only the designated stage to the
  # common input manifest. Missing/corrupt input fails before runtime.
  local _seq_provided_control=""
  if [[ -n "$stage_id" && -z "${_seq_planfrom_control:-}" ]]; then
    if ! _seq_provided_control="$(orch_workflow_seq_prepare_provided "$stage_id" "$stage")"; then
      printf -v "$step_status_var" '%s' 1
      return 1
    fi
    if [[ -n "$_seq_provided_control" ]]; then
      plan_abs="$_seq_provided_control"
      plan_rel="$_seq_provided_control"
      if [[ -n "${ORCH_FILE:-}" && -f "${ORCH_FILE:-}" ]]; then
        stage="$(jq -c --arg id "$stage_id" '.stages[] | select(.id == $id)' "$ORCH_FILE" 2>/dev/null)" || true
      fi
      ralph_orchestrator_log "step $step_n sequential provided-plan control: $plan_abs"
    fi
  fi

  # Resume continues the same mutable control plan when the engine recorded one.
  _seq_plan_override="$(orch_workflow_seq_resolve_plan_override "$stage_id" 2>/dev/null || true)"
  if [[ -n "$_seq_plan_override" ]]; then
    plan_abs="$_seq_plan_override"
    plan_rel="$_seq_plan_override"
    ralph_orchestrator_log "step $step_n using sequential control plan: $plan_abs"
  fi

  stage_context_budget="$(echo "$stage" | jq -r '.contextBudget // ""' 2>/dev/null)" || stage_context_budget=""
  # Graph/orchestration agent stages default to off, but only on a runtime with
  # a proven deny boundary. Choosing off for a runtime that cannot enforce it
  # would refuse to invoke a stage whose author never asked for off; an
  # explicitly authored off on such a runtime still fails at preflight.
  local _ns_default="off"
  if declare -F graph_runtime_native_subagents_off_supported >/dev/null 2>&1; then
    graph_runtime_native_subagents_off_supported "$runtime" || _ns_default="inherit"
  else
    case "$runtime" in claude|codex) _ns_default="off" ;; *) _ns_default="inherit" ;; esac
  fi
  stage_native_subagents="$(echo "$stage" | jq -r --arg d "$_ns_default" '.nativeSubagents // $d' 2>/dev/null)" || stage_native_subagents="$_ns_default"
  case "$stage_native_subagents" in
    inherit|off) ;;
    *)
      ralph_orchestrator_log "FAIL step $step_n: nativeSubagents must be inherit or off (got $stage_native_subagents)"
      printf -v "$step_status_var" '%s' 1
      return 1
      ;;
  esac
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
  # Workflow-owned ordinary stages also publish common stage identity for
  # attempt-bound OPERATOR_INPUT capability / request acceptance.
  if [[ -n "${RALPH_WORKFLOW_REGISTRY_RUN:-}" ]]; then
    export RALPH_WORKFLOW_STAGE_ID="$stage_id"
    if [[ -z "${RALPH_WORKFLOW_STAGE_ATTEMPT:-}" ]]; then
      export RALPH_WORKFLOW_STAGE_ATTEMPT="${stage_id}-${stage_iter:-1}"
    fi
  fi
  orch_stage_collect_expected_artifacts "$stage"

  if ! orchestrator_validate_stage_agent_plan "$agent" "$plan_rel"; then
    ralph_orchestrator_log "FAIL parse: empty plan for stage JSON: $stage"
    echo -e "${C_R}Empty plan path.${C_RST} Log: $LOG_FILE" >&2
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
    agent_template_dir="${ralph_plan_templates_dir:-$RALPH_ACTIVE_DIR/plan-templates}"
    if [[ -n "$agent_template_dir" && -f "$agent_template_dir/$agent.plan.template.md" ]]; then
      template_to_use="$agent_template_dir/$agent.plan.template.md"
    elif [[ -f "$RALPH_ACTIVE_DIR/plan-templates/classic.plan.template.md" ]]; then
      template_to_use="$RALPH_ACTIVE_DIR/plan-templates/classic.plan.template.md"
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
    _dry_model_label="${stage_model:-saved or runtime-native default}"
    if [[ -n "$role" ]]; then
      echo "DRY RUN step $step_n: $runner_label --workspace <path> --role $role --plan $plan_rel${_dry_sr}"
    else
      echo "DRY RUN step $step_n: $runner_label --workspace <path> --plan $plan_rel${_dry_sr}"
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

  _step_model_label="${stage_model:-saved or runtime-native default}"
  echo -e "${C_DIM}────────────────────────────────────────────────────────────${C_RST}"
  echo -e "${C_B}Step ${step_n}${C_RST} ${C_G}$runtime${C_RST} role=${C_BOLD}${role:-none}${C_RST} model=${C_DIM}${_step_model_label}${C_RST} plan=$plan_rel"
  _plan_tag_stream="$(basename "$plan_abs_file" | sed 's/\.[^.]*$//')"
  _plan_tag_stream="${_plan_tag_stream//[^A-Za-z0-9_.-]/_}"
  _runner_stream_log="$(orch_plan_log_dir)/plan-runner-${_plan_tag_stream}-output.log"
  echo "" >&2
  echo -e "${C_DIM}Invoking:${C_RST} $runner_label" >&2
  if [[ -n "$role" ]]; then
    echo -e "${C_DIM}  command:${C_RST} bash $runner --non-interactive --runtime $runtime --workspace <path> --plan <plan> --role $role" >&2
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
  # Graph scheduler injects RALPH_PLAN_KEY=<planKey>-<nodeId> plus
  # RALPH_GRAPH_NODE_ID for session/log isolation while keeping a shared
  # RALPH_ARTIFACT_NS. Preserve those when present; otherwise derive the plan
  # key from the stage plan basename as before.
  _runner_plan_key="$(basename "$plan_abs_file" | sed 's/\.[^.]*$//;s/[^A-Za-z0-9_.-]/_/g')"
  if [[ -n "${RALPH_GRAPH_NODE_ID:-}" && -n "${RALPH_PLAN_KEY:-}" ]]; then
    _runner_plan_key="$RALPH_PLAN_KEY"
  fi
  _runner_env=(
    RALPH_ARTIFACT_NS="$RALPH_ARTIFACT_NS"
    RALPH_PLAN_KEY="$_runner_plan_key"
    RALPH_ORCH_FILE="$RALPH_ORCH_FILE"
  )
  if [[ -n "${RALPH_GRAPH_NODE_ID:-}" ]]; then
    _runner_env+=(RALPH_GRAPH_NODE_ID="$RALPH_GRAPH_NODE_ID")
  fi
  # G12: declared artifact tokens expand before the prompt is built. When
  # this stage declares required outputs, tell the agent the exact, already
  # -resolved absolute destinations (via the shared orch_resolve_artifact_path)
  # so it never guesses a path relative to its own isolated workspace.
  # ralph_artifact_namespace_prompt_block (run-plan-artifacts.sh) renders
  # this list and names them supervisor outputs, not source edits.
  if ((${#EXPECTED_ARTIFACT_PATHS[@]} > 0)); then
    _runner_env+=(RALPH_REQUIRED_ARTIFACT_PATHS_JSON="$(orch_required_artifact_paths_json)")
  fi
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
  # Staged model precedence: stage/voter model: > saved > native. Never pass
  # profile models or global *_PLAN_MODEL env as a resolution rung.
  _runner_env+=(RALPH_MODEL_SCOPE=staged PLAN_STAGE_MODEL="$stage_model")
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
  _runner_env+=(RALPH_PLAN_NATIVE_SUBAGENTS="$stage_native_subagents")
  # Always set (possibly empty) so ambient RALPH_WORKFLOW_STAGE_INSTRUCTIONS
  # from a prior stage cannot leak into a stage without instructions.
  # Plan-file planner stages append the fixed prompt contract (ungated for
  # workflow semantics; helper also covers sourced tests without a registry run).
  local stage_instructions=""
  if declare -F orch_planner_stage_instructions_with_prompt >/dev/null 2>&1 \
    && echo "$stage" | jq -e '(.planner.outputMode // "") == "plan-file"' >/dev/null 2>&1; then
    stage_instructions="$(orch_planner_stage_instructions_with_prompt "$stage" "${ORCH_FILE:-}")"
  else
    stage_instructions="$(orch_stage_instructions_from_json "$stage")"
  fi
  _runner_env+=(RALPH_WORKFLOW_STAGE_INSTRUCTIONS="$stage_instructions")
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
  # Workflow registry identity for ungated plan-file publication (engines set these).
  if [[ -n "${RALPH_WORKFLOW_REGISTRY_RUN:-}" ]]; then
    _runner_env+=(RALPH_WORKFLOW_REGISTRY_RUN="$RALPH_WORKFLOW_REGISTRY_RUN")
  fi
  if [[ -n "${RALPH_WORKFLOW_RUN_ID:-}" ]]; then
    _runner_env+=(RALPH_WORKFLOW_RUN_ID="$RALPH_WORKFLOW_RUN_ID")
  fi
  if [[ -n "${RALPH_WORKFLOW_STAGE_ID:-}" ]]; then
    _runner_env+=(RALPH_WORKFLOW_STAGE_ID="$RALPH_WORKFLOW_STAGE_ID")
  elif [[ -n "${RALPH_WORKFLOW_REGISTRY_RUN:-}" && -n "${stage_id:-}" ]]; then
    _runner_env+=(RALPH_WORKFLOW_STAGE_ID="$stage_id")
  fi
  if [[ -n "${RALPH_WORKFLOW_STAGE_ATTEMPT:-}" ]]; then
    _runner_env+=(RALPH_WORKFLOW_STAGE_ATTEMPT="$RALPH_WORKFLOW_STAGE_ATTEMPT")
  fi
  if [[ -n "${RALPH_WORKFLOW_ACTION_CAPABILITY:-}" ]]; then
    _runner_env+=(RALPH_WORKFLOW_ACTION_CAPABILITY="$RALPH_WORKFLOW_ACTION_CAPABILITY")
  fi
  # Nonce stays in env for request CLI only; never log it from orchestrator.
  if [[ -n "${RALPH_WORKFLOW_ACTION_NONCE:-}" ]]; then
    _runner_env+=(RALPH_WORKFLOW_ACTION_NONCE="$RALPH_WORKFLOW_ACTION_NONCE")
  fi
  if [[ -n "${RALPH_WORKFLOW_TASK:-}" ]]; then
    _runner_env+=(RALPH_WORKFLOW_TASK="$RALPH_WORKFLOW_TASK")
  fi
  if [[ -n "${RALPH_WORKFLOW_FALLBACK_RUNTIME:-}" ]]; then
    _runner_env+=(RALPH_WORKFLOW_FALLBACK_RUNTIME="$RALPH_WORKFLOW_FALLBACK_RUNTIME")
  fi
  if [[ -n "${RALPH_WORKFLOW_FALLBACK_MODEL:-}" ]]; then
    _runner_env+=(RALPH_WORKFLOW_FALLBACK_MODEL="$RALPH_WORKFLOW_FALLBACK_MODEL")
  fi
  if declare -F orch_resolve_final_output_schema >/dev/null 2>&1; then
    _final_output_schema="$(orch_resolve_final_output_schema "$stage")"
    if [[ -n "$_final_output_schema" ]]; then
      _runner_env+=(RALPH_STRUCTURED_OUTPUT_SCHEMA="$_final_output_schema")
    fi
  fi
  if [[ -n "${ORCH_RALPH_MODE:-}" ]]; then
    _runner_env+=(RALPH_MODE="$ORCH_RALPH_MODE")
  fi
  local _stage_tooling_profile=""
  _stage_tooling_profile="$(echo "$stage" | jq -r '.toolingProfile // empty' 2>/dev/null)" || _stage_tooling_profile=""
  if [[ -n "$_stage_tooling_profile" ]]; then
    if ! declare -F ralph_tooling_profile_env >/dev/null 2>&1; then
      local _tooling_profile_lib=""
      _tooling_profile_lib="$RALPH_DIR/bash-lib/tooling-profile.sh"
      if [[ ! -f "$_tooling_profile_lib" && -f "$RALPH_ACTIVE_DIR/bash-lib/tooling-profile.sh" ]]; then
        _tooling_profile_lib="$RALPH_ACTIVE_DIR/bash-lib/tooling-profile.sh"
      fi
      if [[ ! -f "$_tooling_profile_lib" ]]; then
        ralph_orchestrator_log "FAIL step $step_n: tooling profile helper missing"
        echo -e "${C_R}${C_BOLD}Step $step_n failed (tooling profile helper missing)${C_RST}" >&2
        echo "  Expected tooling-profile.sh under Ralph bash-lib." >&2
        echo "  Log: $LOG_FILE" >&2
        printf -v "$step_status_var" '%s' 1
        set -e
        return 1
      fi
      # shellcheck source=bash-lib/tooling-profile.sh
      source "$_tooling_profile_lib"
    fi
    local _profile_line _profile_lines=""
    if ! _profile_lines="$(ralph_tooling_profile_env "$_stage_tooling_profile" "$runtime")"; then
      ralph_orchestrator_log "FAIL step $step_n: invalid toolingProfile '$_stage_tooling_profile'"
      echo -e "${C_R}${C_BOLD}Step $step_n failed (invalid toolingProfile)${C_RST}" >&2
      echo "  toolingProfile '$_stage_tooling_profile' is not a declared profile name." >&2
      echo "  Log: $LOG_FILE" >&2
      printf -v "$step_status_var" '%s' 1
      set -e
      return 1
    fi
    while IFS= read -r _profile_line || [[ -n "$_profile_line" ]]; do
      [[ -n "$_profile_line" ]] || continue
      _runner_env+=("$_profile_line")
    done <<< "$_profile_lines"
  fi
  _runner_args=(--non-interactive --runtime "$runtime" --workspace "$WORKSPACE" --plan "$plan_abs_file")
  if [[ -n "${WORKSPACE_ROOT_OVERRIDE:-}" ]]; then
    _runner_args+=(--workspace-root "$WORKSPACE_ROOT_OVERRIDE")
  fi
  # Graph nodes have an explicit, isolated agent workspace.  run-plan's
  # ordinary default is its process cwd, which is the scheduler's workspace
  # here, so pass the root explicitly rather than losing the node boundary.
  # Keep non-graph orchestration byte-compatible.
  if [[ -n "${RALPH_GRAPH_NODE_ID:-}" && -n "${RALPH_AGENT_WORKSPACE:-}" ]]; then
    _runner_args+=(--agent-workspace "$RALPH_AGENT_WORKSPACE")
  fi
  if ((${#_session_strategy_cli[@]} > 0)); then
    _runner_args+=("${_session_strategy_cli[@]}")
  fi
  if [[ -n "$role" ]]; then
    _runner_args+=(--role "$role")
  fi
  # Sequential workflow engine: journal immediately before the existing runner
  # invocation so dry-run / early validation paths are unchanged.
  orch_workflow_seq_journal_before "$stage_id" "$stage_index" "$stage" "$stage_iter"
  orch_stage_run_runner "$runner" "${_runner_env[@]}"
  rc=$?
  set -e
  # Persist planFrom / provided-plan control-copy progress after every runner
  # transition without mutating the immutable source plan/manifest.
  orch_workflow_seq_ensure_lib || true
  if declare -F workflow_seq_refresh_plan_progress_after_runner >/dev/null 2>&1; then
    workflow_seq_refresh_plan_progress_after_runner "${plan_abs_file:-}" || true
  fi
  if declare -F workflow_dep_refresh_plan_progress_after_runner >/dev/null 2>&1; then
    workflow_dep_refresh_plan_progress_after_runner "${plan_abs_file:-}" || true
  elif [[ -f "${RALPH_ACTIVE_DIR:-}/bash-lib/workflow/workflow-engine-dependency.sh" ]]; then
    # shellcheck source=bash-lib/workflow/workflow-engine-dependency.sh
    source "${RALPH_ACTIVE_DIR}/bash-lib/workflow/workflow-engine-dependency.sh"
    if declare -F workflow_dep_refresh_plan_progress_after_runner >/dev/null 2>&1; then
      workflow_dep_refresh_plan_progress_after_runner "${plan_abs_file:-}" || true
    fi
  fi
  echo -e "${C_DIM}--- end step $step_n runner output (exit $rc) ---${C_RST}" >&2
  echo "" >&2
  if [[ $rc -ne 0 ]]; then
    orch_workflow_seq_journal_after "$stage_id" "$rc" "$stage"
    plan_tag="$(basename "$plan_abs_file" | sed 's/\.[^.]*$//')"
    plan_tag="${plan_tag//[^A-Za-z0-9_.-]/_}"
    hint_log="$(orch_plan_log_dir)/plan-runner-${plan_tag}.log"
    hint_out="$(orch_plan_log_dir)/plan-runner-${plan_tag}-output.log"
    ralph_orchestrator_log "FAIL step $step_n exit=$rc role=${role:-none} plan=$plan_abs_file"
    {
      echo ""
      echo "======== orchestrator failure ========"
      echo "Step:        $step_n"
      echo "Runtime:     $runtime"
      echo "Role:        ${role:-none}"
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
    # In graph mode the run-plan log is the authoritative agent stream. If a
    # supervisor-owned postcondition rejected an otherwise clean model exit,
    # carry that precise error into the StageOutcomeReport instead of letting
    # the EXIT trap flatten it to "stage terminated before completion".
    if [[ "${SINGLE_STAGE_MODE:-0}" == "1" && "${SINGLE_STAGE_REPORT_WRITTEN:-0}" != "1" \
      && -n "${RALPH_GRAPH_NODE_LOG_DIR:-}" && -f "$RALPH_GRAPH_NODE_LOG_DIR/agent.log" ]]; then
      _orch_failure_reason="$(sed -n '/ERROR:/p' "$RALPH_GRAPH_NODE_LOG_DIR/agent.log" 2>/dev/null | tail -n 1)"
      _orch_failure_reason="$(printf '%s' "$_orch_failure_reason" | sed -E 's/^\[[^]]+\][[:space:]]*//')"
      if [[ -n "$_orch_failure_reason" ]]; then
        orch_single_stage_write_report "failed" "$rc" "$_orch_failure_reason" || true
      fi
    fi
    printf -v "$step_status_var" '%s' "$rc"
    exit "$rc"
  fi

  if ((${#EXPECTED_ARTIFACT_PATHS[@]} > 0)); then
    if ! verify_step_artifacts "$step_n"; then
      ralph_orchestrator_log "FAIL step $step_n: artifact verification failed (see log for remediation)"
      printf -v "$step_status_var" '%s' 1
      # G10/G11 tier 4: write the report with the resolved missing-artifact
      # evidence directly, rather than letting the EXIT trap fall back to a
      # generic "stage terminated before completion" reason with no
      # missingArtifacts. Marks SINGLE_STAGE_REPORT_WRITTEN so the trap
      # never overwrites this evidence-carrying report.
      if [[ "${SINGLE_STAGE_MODE:-0}" == "1" && ${#ORCH_MISSING_ARTIFACT_PATHS[@]} -gt 0 ]]; then
        local _missing_evidence
        _missing_evidence="$(printf '%s\n' "${ORCH_MISSING_ARTIFACT_PATHS[@]}" | jq -R . | jq -sc '{missingArtifacts: .}' 2>/dev/null)"
        orch_single_stage_write_report "failed" 1 "required artifact missing or empty" "${_missing_evidence:-}" || true
      fi
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

  # Workflow plan-file publication runs even in single-stage mode: the stage
  # must not be marked succeeded until the run-scoped plan+manifest exist.
  # Legacy dynamic-stage enqueue / generated writer remain multi-stage only
  # (orch_planner_apply_output no-ops legacy when SINGLE_STAGE_MODE=1).
  if ! orch_planner_apply_output "$stage" "$stage_id" "$step_n" "$step_status_var"; then
    if [[ "${ORCH_PLANNER_FAIL_REASON:-}" == "invalid-artifact" ]]; then
      ralph_orchestrator_log "step $step_n planner reasonCode=invalid-artifact"
    fi
    return 1
  fi

  # Single-stage mode executes exactly one stage: no humanAck waiting, router
  # target application, or loopControl. The orchestration transition/retry
  # decision is made downstream from the StageOutcomeReport.
  if [[ "${SINGLE_STAGE_MODE:-0}" != "1" ]]; then
  # Workflow Sequential runs use durable common approval/input actions. Retain
  # env-gated humanAck/touch-file only for classic/legacy-orchestration inputs.
  human_ack_rel=""
  if ! orch_workflow_seq_uses_common_actions; then
    human_ack_rel="$(echo "$stage" | jq -r '.humanAck.path // empty' 2>/dev/null)" || human_ack_rel=""
  fi
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

  # run-plan writes plan-usage-summary.json under logs/<RALPH_ARTIFACT_NS>/ (see
  # run-plan-core.sh), or logs/<RALPH_ARTIFACT_NS>/nodes/<nodeId>/ when the graph
  # scheduler set RALPH_GRAPH_NODE_ID for per-node log isolation.
  _stage_usage_file="$(orch_plan_log_dir)/plan-usage-summary.json"
  orch_stage_capture_usage "$step_n" "$agent" "$runtime" "$_stage_usage_file" "$stage_usage_file"
  ralph_orchestrator_log "step $step_n OK"
  echo -e "${C_G}Step $step_n completed.${C_RST}"
  printf -v "$step_status_var" '%s' 0
  # Sequential engine after-journal: preserve exit 0; soft-fails never reopen the stage.
  orch_workflow_seq_journal_after "$stage_id" 0 "$stage"
  return 0
}

# Resolve the run-wide Ralph tooling mode from the orchestration file.
#
# Tool exposure is a property of the whole run: every stage of one run brokers
# tools the same way. It is declared once, either as ralphMode in the
# orchestration file (which a graph plan's pipeline.ralphMode is projected
# into) or as RALPH_MODE in the environment.
#
# Declaring both is a conflict rather than a precedence puzzle. Silently
# letting one win means the mode that actually took effect can only be
# discovered by reading a log, so disagreeing values are refused outright.
# Identical values are fine -- that is not a conflict, just a redundant
# statement of the same intent.
#
# Absent both, nothing is exported and the inherited environment stands, so
# Ralph mode stays opt-in exactly as before.
orch_resolve_ralph_mode() {
  ORCH_RALPH_MODE=""
  local declared="" env_mode="${RALPH_MODE:-}"

  if [[ -n "${ORCH_FILE:-}" && -f "${ORCH_FILE:-}" ]]; then
    declared="$(jq -r '.ralphMode // empty' "$ORCH_FILE" 2>/dev/null || echo "")"
  fi

  if [[ -n "$declared" ]]; then
    case "$declared" in
      no | native | ralph | hybrid) ;;
      *)
        echo -e "${C_R}${C_BOLD}Orchestrator config error: invalid ralphMode${C_RST}" >&2
        echo "  ralphMode is \"$declared\" in $ORCH_FILE" >&2
        echo "  Expected one of: no, native, ralph, hybrid" >&2
        exit 1
        ;;
    esac
  fi

  if [[ -n "$declared" && -n "$env_mode" && "$declared" != "$env_mode" ]]; then
    echo -e "${C_R}${C_BOLD}Orchestrator config error: conflicting Ralph mode${C_RST}" >&2
    echo "  ralphMode is \"$declared\" in $ORCH_FILE" >&2
    echo "  RALPH_MODE is \"$env_mode\" in the environment" >&2
    echo "  These apply to the same run and must agree. Remove one, or set them to the same value." >&2
    exit 1
  fi

  if [[ -n "$declared" ]]; then
    ORCH_RALPH_MODE="$declared"
    export RALPH_MODE="$declared"
    ralph_orchestrator_log "ralph mode: $declared (declared in $ORCH_FILE)"
  elif [[ -n "$env_mode" ]]; then
    ORCH_RALPH_MODE="$env_mode"
    ralph_orchestrator_log "ralph mode: $env_mode (from environment)"
  fi
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
      ralph_process_scope_exec stage orchestrator \
        env -u RALPH_AGENT_TOOL_ACCESS -u RALPH_NATIVE_HOOKS \
        "$@" RALPH_PROCESS_ALLOW_CHILD=1 bash "$runner" "${_runner_args[@]}" 2>&1
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
  ralph_process_scope_exec stage orchestrator \
    env -u RALPH_AGENT_TOOL_ACCESS -u RALPH_NATIVE_HOOKS \
    "$@" RALPH_PROCESS_ALLOW_CHILD=1 bash "$runner" "${_runner_args[@]}" >>"$LOG_FILE" 2>&1 &
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
# plan files, planFile stages are used as-is. Direct .orch.json inputs skip this entirely.
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

# Direct .orch.json input is parsed as supplied; structured plans were normalized above.
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

  if jq -e 'has("ralphMode") and ([.stages[]? | select(has("toolingProfile"))] | length > 0)' "$ORCH_FILE" >/dev/null 2>&1; then
    ralph_orchestrator_log "FAIL parse: ralphMode and stage toolingProfile cannot coexist in $ORCH_FILE"
    echo -e "${C_R}${C_BOLD}Orchestrator config error: conflicting tooling declarations${C_RST}" >&2
    echo "  ralphMode and stage toolingProfile apply to the same run and cannot coexist." >&2
    echo "  Remove ralphMode or declare tooling via stage toolingProfile, not both." >&2
    echo "  Log: $LOG_FILE" >&2
    exit 1
  fi

  orch_resolve_ralph_mode

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
    if ! role="$(orch_stage_role_from_json "$stage")"; then
      ralph_orchestrator_log "FAIL single-stage: invalid stage role/agent fields"
      orch_single_stage_write_report "failed" 1 "invalid stage role/agent fields" || true
      exit 1
    fi
    stage_model="$(echo "$stage" | jq -r '.model // ""' 2>/dev/null)" || stage_model=""
    agent_source=""
    agent_source_raw=""
    if [[ -n "$role" ]]; then
      agent_source="prebuilt"
    fi
    plan_rel="$(echo "$stage" | jq -r '.plan // ""' 2>/dev/null)" || plan_rel=""
    step_index=$((step_index + 1))
    plan_abs="$(orchestrator_stage_plan_abs "$plan_rel" "$WORKSPACE")"
    step_rc=0
    # orch_stage_execute exits directly on runner/artifact failure; the EXIT trap
    # then records the failed/cancelled report with the real exit code. Non-zero
    # returns (validation without exit) are handled explicitly here.
    if ! orch_stage_execute "$step_index" "$stage" "$plan_abs" "$plan_rel" "$runtime" "$role" "$agent_source" "$stage_model" "$agent_source_raw" "$stage_id" "$stage_iter" step_rc "" "$ss_idx"; then
      ss_fail_detail="stage execution failed"
      if [[ -n "${ORCH_PLANNER_FAIL_DETAIL:-}" ]]; then
        ss_fail_detail="${ORCH_PLANNER_FAIL_REASON:-stage execution failed}: ${ORCH_PLANNER_FAIL_DETAIL}"
      fi
      orch_single_stage_write_report "failed" "${step_rc:-1}" "$ss_fail_detail" || true
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
        if ! role="$(orch_stage_role_from_json "$stage")"; then
          ralph_orchestrator_log "FAIL parallel wave $((wave_idx + 1)): invalid stage role/agent fields"
          exit 1
        fi
        stage_model="$(echo "$stage" | jq -r '.model // ""' 2>/dev/null)" || stage_model=""
        agent_source=""
        agent_source_raw=""
        if [[ -n "$role" ]]; then
          agent_source="prebuilt"
        fi
        plan_rel="$(echo "$stage" | jq -r '.plan // ""' 2>/dev/null)" || plan_rel=""
        step_index=$((step_index + 1))
        plan_abs="$(orchestrator_stage_plan_abs "$plan_rel" "$WORKSPACE")"
        plan_tag="$(basename "$plan_abs" | sed 's/\.[^.]*$//')"
        plan_tag="${plan_tag//[^A-Za-z0-9_.-]/_}"
        wave_output_logs+=("$(orch_plan_log_dir)/plan-runner-${plan_tag}-output.log")
        stage_usage_file="$RALPH_LOG_DIR/$RALPH_ARTIFACT_NS/parallel-wave-${wave_idx}-stage-${stage_id}.usage.json"
        mkdir -p "$(dirname "$stage_usage_file")"
        if [[ "${ORCHESTRATOR_DRY_RUN:-0}" == "1" ]]; then
          stage_file="$RALPH_LOG_DIR/$RALPH_ARTIFACT_NS/parallel-wave-${wave_idx}-stage-${stage_id}.status"
          mkdir -p "$(dirname "$stage_file")"
          if [[ "${ORCHESTRATOR_RUNNER_TO_CONSOLE:-1}" != "0" ]]; then
            (
              ORCHESTRATOR_PARALLEL_PREFIX_STREAM=1 orch_stage_execute "$step_index" "$stage" "$plan_abs" "$plan_rel" "$runtime" "$role" "$agent_source" "$stage_model" "$agent_source_raw" "$stage_id" "$stage_iter" status_tmp "$stage_usage_file" "$back_idx"
            ) 2>&1 | orch_parallel_stage_prefix_stream "$stage_id" "$(orch_parallel_stage_tag_color "$wave_stage_position")" &
          else
            ( orch_stage_execute "$step_index" "$stage" "$plan_abs" "$plan_rel" "$runtime" "$role" "$agent_source" "$stage_model" "$agent_source_raw" "$stage_id" "$stage_iter" status_tmp "$stage_usage_file" "$back_idx" ) &
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
              ORCHESTRATOR_PARALLEL_PREFIX_STREAM=1 orch_stage_execute "$step_index" "$stage" "$plan_abs" "$plan_rel" "$runtime" "$role" "$agent_source" "$stage_model" "$agent_source_raw" "$stage_id" "$stage_iter" status_tmp "$stage_usage_file" "$back_idx"
              echo "$?" > "$stage_file"
            ) 2>&1 | orch_parallel_stage_prefix_stream "$stage_id" "$(orch_parallel_stage_tag_color "$wave_stage_position")" &
          else
            (
              orch_stage_execute "$step_index" "$stage" "$plan_abs" "$plan_rel" "$runtime" "$role" "$agent_source" "$stage_model" "$agent_source_raw" "$stage_id" "$stage_iter" status_tmp "$stage_usage_file" "$back_idx"
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
        role="$(echo "$stage" | jq -r '.role // ""' 2>/dev/null || echo "")"
        runtime="$(echo "$stage" | jq -r '.runtime // "cursor"' 2>/dev/null || echo "cursor")"
        orch_router_record_skipped_stage "$step_index" "$stage_id" "$role" "$runtime"
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
      if ! role="$(orch_stage_role_from_json "$stage")"; then
        ralph_orchestrator_log "FAIL parse: invalid stage role/agent fields"
        exit 1
      fi
      stage_model="$(echo "$stage" | jq -r '.model // ""' 2>/dev/null)" || stage_model=""
      agent_source=""
      agent_source_raw=""
      if [[ -n "$role" ]]; then
        agent_source="prebuilt"
      fi
      plan_rel="$(echo "$stage" | jq -r '.plan // ""' 2>/dev/null)" || plan_rel=""
      step_index=$((step_index + 1))
      plan_abs="$(orchestrator_stage_plan_abs "$plan_rel" "$WORKSPACE")"
      if ! orch_stage_execute "$step_index" "$stage" "$plan_abs" "$plan_rel" "$runtime" "$role" "$agent_source" "$stage_model" "$agent_source_raw" "$stage_id" "$stage_iter" step_rc "$idx"; then
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
          if ! role="$(orch_stage_role_from_json "$stage")"; then
            ralph_orchestrator_log "FAIL parse: invalid stage role/agent fields in generated planner stage"
            exit 1
          fi
          stage_model="$(echo "$stage" | jq -r '.model // ""' 2>/dev/null)" || stage_model=""
          agent_source=""
          agent_source_raw=""
          if [[ -n "$role" ]]; then
            agent_source="prebuilt"
          fi
          plan_rel="$(echo "$stage" | jq -r '.plan // ""' 2>/dev/null)" || plan_rel=""
          step_index=$((step_index + 1))
          plan_abs="$(orchestrator_stage_plan_abs "$plan_rel" "$WORKSPACE")"
          if ! orch_stage_execute "$step_index" "$stage" "$plan_abs" "$plan_rel" "$runtime" "$role" "$agent_source" "$stage_model" "$agent_source_raw" "$stage_id" "$stage_iter" step_rc "$idx"; then
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
