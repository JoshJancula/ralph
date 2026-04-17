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
#         "runtime": "cursor", "claude", or "codex" (optional, default: cursor),
#         "plan": "path/to/stage-plan.md",
#         "planTemplate": "path/to/stage-plan.template.md (optional)",
#         "sessionResume": true or false (optional JSON boolean; forwards --cli-resume / --no-cli-resume to run-plan),
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

# ---------------------------------------------------------------------------
# High-level flow: parse CLI -> load JSON -> for each stage: resolve artifacts,
# ensure plan file (template copy if missing), run .ralph/run-plan.sh non-interactively,
# verify required output files, optional humanAck gate, optional loop back to an earlier stage.
# ---------------------------------------------------------------------------

WORKSPACE="$(pwd)"
WORKSPACE_ROOT_OVERRIDE=""
ORCH_FILE=""

usage() {
  echo "Usage: $0 --orchestration <orchestration_plan.orch.json> [workspace_dir]" >&2
  echo "   or: $0 <orchestration_plan.orch.json> [workspace_dir]" >&2
  echo "Optional: append --workspace-root <path> to set a custom .ralph-workspace location" >&2
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
if [[ ! -f "$WORKSPACE/.ralph/ralph-env-safety.sh" ]]; then
  echo "Orchestrator error: expected $WORKSPACE/.ralph/ralph-env-safety.sh (repo Ralph tooling)." >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$WORKSPACE/.ralph/ralph-env-safety.sh"
ralph_assert_path_not_env_secret "Orchestration file" "$ORCH_FILE"
# Logs and per-plan artifacts live here; same root run-plan uses when invoked from orchestrator.
DEFAULT_ORCH_WORKSPACE_ROOT="$WORKSPACE/.ralph-workspace"
if [[ -n "${WORKSPACE_ROOT_OVERRIDE:-}" ]]; then
  DEFAULT_ORCH_WORKSPACE_ROOT="$WORKSPACE_ROOT_OVERRIDE"
fi
export RALPH_PLAN_WORKSPACE_ROOT="${RALPH_PLAN_WORKSPACE_ROOT:-$DEFAULT_ORCH_WORKSPACE_ROOT}"
export RALPH_PROJECT_ROOT="$WORKSPACE"
RALPH_LOG_DIR="$RALPH_PLAN_WORKSPACE_ROOT/logs"
mkdir -p "$RALPH_LOG_DIR"
ORCH_BASENAME="$(basename "$ORCH_FILE" | sed 's/\.[^.]*$//')"
ORCH_BASENAME="${ORCH_BASENAME//[^A-Za-z0-9_.-]/_}"
LOG_FILE="$RALPH_LOG_DIR/orchestrator-${ORCH_BASENAME}.log"
RALPH_RUN_PLAN="$WORKSPACE/.ralph/run-plan.sh"
# Populated per stage from JSON (and sometimes merged from agent config); cleared each iteration.
EXPECTED_ARTIFACT_PATHS=()

ralph_orchestrator_timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

# Used by merge_required_artifacts_from_agent when a stage omits explicit artifacts.
if [[ -f "$WORKSPACE/.ralph/agent-config-tool.sh" ]]; then
  AGENT_CONFIG_TOOL_SH="$WORKSPACE/.ralph/agent-config-tool.sh"
else
  AGENT_CONFIG_TOOL_SH=""
fi

# expand_artifact_tokens, merge_required_artifacts_from_agent, orchestrator_validate_runtime, etc.
# shellcheck source=/dev/null
source "$WORKSPACE/.ralph/bash-lib/orchestrator-lib.sh"
# shellcheck source=/dev/null
source "$WORKSPACE/.ralph/bash-lib/ralph-format-elapsed.sh"
# shellcheck source=/dev/null
source "$WORKSPACE/.ralph/bash-lib/orchestrator-handoffs.sh"

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
  local stage_context_budget=""
  stage_context_budget="$(echo "$stage" | jq -r '.contextBudget // ""' 2>/dev/null)" || stage_context_budget=""
  local plan_abs_file="$plan_abs"
  local step_status=0
  local runner="$RALPH_RUN_PLAN"
  local runner_label=".ralph/run-plan.sh (runtime=$runtime)"
  local human_ack_rel human_ack_abs human_ack_msg
  local _dry_sr _dry_model_label _step_model_label _plan_tag_stream _runner_stream_log _runner_env _runner_args _art_check
  local _session_resume_cli=()
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
      if [[ "$runtime" == "cursor" ]]; then
        agent_template_dir="$WORKSPACE/.cursor/ralph/templates"
      elif [[ "$runtime" == "codex" ]]; then
        agent_template_dir="$WORKSPACE/.codex/ralph/templates"
      elif [[ "$runtime" == "opencode" ]]; then
        agent_template_dir="$WORKSPACE/.opencode/ralph/templates"
      else
        agent_template_dir="$WORKSPACE/.claude/ralph/templates"
      fi
      if [[ -f "$agent_template_dir/$agent.plan.template.md" ]]; then
        template_to_use="$agent_template_dir/$agent.plan.template.md"
      elif [[ -f "$WORKSPACE/.ralph/plan.template" ]]; then
        template_to_use="$WORKSPACE/.ralph/plan.template"
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

  _session_resume_type="$(echo "$stage" | jq -r 'if has("sessionResume") then (.sessionResume|type) else "absent" end' 2>/dev/null || echo "error")"
  if [[ "$_session_resume_type" == "boolean" ]]; then
    _session_resume_value="$(echo "$stage" | jq -r '.sessionResume' 2>/dev/null || echo "false")"
    if [[ "$_session_resume_value" == "true" ]]; then
      _session_resume_cli+=(--cli-resume)
    else
      _session_resume_cli+=(--no-cli-resume)
    fi
  elif [[ "$_session_resume_type" != "absent" ]]; then
    ralph_orchestrator_log "FAIL step $step_n: sessionResume must be a boolean (got $_session_resume_type)"
    echo -e "${C_R}${C_BOLD}Step $step_n failed (invalid sessionResume)${C_RST}" >&2
    echo "  sessionResume must be a boolean true/false in $ORCH_FILE." >&2
    echo "  Log: $LOG_FILE" >&2
    printf -v "$step_status_var" '%s' 1
    return 1
  fi

  if [[ "${ORCHESTRATOR_DRY_RUN:-0}" == "1" ]]; then
    _dry_sr=""
    if ((${#_session_resume_cli[@]} > 0)); then
      _dry_sr=" ${_session_resume_cli[*]}"
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
    printf -v "$step_status_var" '%s' 0
    return 0
  fi

  _step_model_label="${stage_model:-agent-config default}"
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
  echo -e "${C_DIM}--- runner / agent output follows ---${C_RST}" >&2

  if [[ "${RALPH_HANDOFFS_ENABLED:-1}" == "1" ]]; then
    export ORCH_FILE="$RALPH_ORCH_FILE"
    inject_handoffs_into_plan "$plan_abs_file" "$stage_id" "$stage_iter" || {
      ralph_orchestrator_log "WARNING step $step_n: failed to inject handoffs into plan (continuing anyway)"
    }
  fi

  set +e
  _runner_env=(
    RALPH_ARTIFACT_NS="$RALPH_ARTIFACT_NS"
    RALPH_PLAN_KEY="$(basename "$plan_abs_file" | sed 's/\.[^.]*$//;s/[^A-Za-z0-9_.-]/_/g')"
    RALPH_ORCH_FILE="$RALPH_ORCH_FILE"
  )
  if [[ -n "$stage_model" ]]; then
    if [[ "$runtime" == "cursor" ]]; then
      _runner_env+=(CURSOR_PLAN_MODEL="$stage_model")
    elif [[ "$runtime" == "codex" ]]; then
      _runner_env+=(CODEX_PLAN_MODEL="$stage_model")
    elif [[ "$runtime" == "opencode" ]]; then
      _runner_env+=(OPENCODE_PLAN_MODEL="$stage_model")
    else
      _runner_env+=(CLAUDE_PLAN_MODEL="$stage_model")
    fi
  fi
  if [[ -n "$stage_context_budget" ]]; then
    _runner_env+=(RALPH_PLAN_CONTEXT_BUDGET="$stage_context_budget")
  fi
  _runner_args=(--non-interactive --runtime "$runtime" --workspace "$WORKSPACE" --plan "$plan_abs_file")
  if [[ -n "${WORKSPACE_ROOT_OVERRIDE:-}" ]]; then
    _runner_args+=(--workspace-root "$WORKSPACE_ROOT_OVERRIDE")
  fi
  if ((${#_session_resume_cli[@]} > 0)); then
    _runner_args+=("${_session_resume_cli[@]}")
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
    fi
  fi

  # run-plan writes plan-usage-summary.json under logs/<RALPH_ARTIFACT_NS>/ (see run-plan-core.sh).
  _stage_usage_file="$RALPH_LOG_DIR/$RALPH_ARTIFACT_NS/plan-usage-summary.json"
  orch_stage_capture_usage "$step_n" "$agent" "$runtime" "$_stage_usage_file" "${14:-}"
  ralph_orchestrator_log "step $step_n OK"
  echo -e "${C_G}Step $step_n completed.${C_RST}"
  printf -v "$step_status_var" '%s' 0
  return 0
}

orch_stage_run_runner() {
  local runner="$1"
  shift
  if [[ "${ORCHESTRATOR_RUNNER_TO_CONSOLE:-1}" != "0" ]] && [[ -t 1 ]] && command -v tee >/dev/null 2>&1; then
    env "$@" bash "$runner" "${_runner_args[@]}" 2>&1 | tee -a "$LOG_FILE"
    return ${PIPESTATUS[0]}
  fi
  env "$@" bash "$runner" "${_runner_args[@]}" >>"$LOG_FILE" 2>&1
}

ralph_orchestrator_log() {
  echo "[$(ralph_orchestrator_timestamp)] $*" >> "$LOG_FILE"
  if [[ "${ORCHESTRATOR_VERBOSE:-0}" == "1" ]]; then
    echo "[$(ralph_orchestrator_timestamp)] $*" >&2
  fi
}

ralph_orchestrator_log "orchestrator started workspace=$WORKSPACE orchestration=$ORCH_FILE"

if [[ -t 1 && "${ORCHESTRATOR_NO_COLOR:-0}" != "1" ]]; then
  C_R=$'\033[31m'
  C_G=$'\033[32m'
  C_Y=$'\033[33m'
  C_B=$'\033[34m'
  C_DIM=$'\033[2m'
  C_BOLD=$'\033[1m'
  C_RST=$'\033[0m'
else
  C_R="" C_G="" C_Y="" C_B="" C_DIM="" C_BOLD="" C_RST=""
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

# Non-JSON orchestrations are rejected; all pipelines use .orch.json today.
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

  # Drives {{ARTIFACT_NS}} in paths and per-plan log dirs unless overridden in the environment.
  json_ns="$(jq -r '.namespace // empty' "$ORCH_FILE" 2>/dev/null || echo "")"
  export RALPH_ARTIFACT_NS="${RALPH_ARTIFACT_NS:-${json_ns:-$ORCH_BASENAME}}"

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

  parallel_waves_raw="$(jq -c '.parallelStages // empty' "$ORCH_FILE" 2>/dev/null || echo "")"
  if [[ -n "$parallel_waves_raw" ]]; then
    parallel_waves_count="$(echo "$parallel_waves_raw" | jq 'length' 2>/dev/null || echo 0)"
    for ((wave_idx = 0; wave_idx < parallel_waves_count; wave_idx++)); do
      wave_stage_ids="$(echo "$parallel_waves_raw" | jq -r ".[$wave_idx]" 2>/dev/null || true)"
      wave_pids=()
      wave_stage_refs=()
      wave_status=0
      wave_failures=()
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
          ralph_orchestrator_log "FAIL parse: invalid RUNTIME '$runtime_raw' (use cursor, claude, codex, or opencode)"
          echo -e "${C_R}Invalid RUNTIME '${runtime_raw}'. Use cursor, claude, codex, or opencode.${C_RST}" >&2
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
        stage_usage_file="$RALPH_LOG_DIR/$RALPH_ARTIFACT_NS/parallel-wave-${wave_idx}-stage-${stage_id}.usage.json"
        mkdir -p "$(dirname "$stage_usage_file")"
        if [[ "${ORCHESTRATOR_DRY_RUN:-0}" == "1" ]]; then
          stage_file="$RALPH_LOG_DIR/$RALPH_ARTIFACT_NS/parallel-wave-${wave_idx}-stage-${stage_id}.status"
          mkdir -p "$(dirname "$stage_file")"
          ( orch_stage_execute "$step_index" "$stage" "$plan_abs" "$plan_rel" "$runtime" "$agent" "$agent_source" "$stage_model" "$agent_source_raw" "$planTemplate" "$stage_id" "$stage_iter" status_tmp "$stage_usage_file" ) &
          wave_pids+=("$!")
          wave_stage_refs+=("$stage_id:$stage_file")
        else
          stage_file="$RALPH_LOG_DIR/$RALPH_ARTIFACT_NS/parallel-wave-${wave_idx}-stage-${stage_id}.status"
          mkdir -p "$(dirname "$stage_file")"
          (
            orch_stage_execute "$step_index" "$stage" "$plan_abs" "$plan_rel" "$runtime" "$agent" "$agent_source" "$stage_model" "$agent_source_raw" "$planTemplate" "$stage_id" "$stage_iter" status_tmp "$stage_usage_file"
            echo "$?" > "$stage_file"
          ) &
          wave_pids+=("$!")
          wave_stage_refs+=("$stage_id:$stage_file")
        fi
      done
      for pid in "${wave_pids[@]}"; do
        wait "$pid" || wave_status=1
      done
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
    idx=0
    while (( idx < num_stages )); do
      stage="$(jq ".stages[$idx]" "$ORCH_FILE" 2>/dev/null)" || continue
      stage_id="$(echo "$stage" | jq -r '.id // empty' 2>/dev/null || echo "")"
      stage_id="$(orch_stage_normalize_id "$stage_id")"
      if [[ -n "$stage_id" ]]; then
        stage_iter="$(orch_stage_iteration_map_get "$stage_id")"
      else
        stage_iter=1
      fi
      runtime_raw="$(echo "$stage" | jq -r '.runtime // "cursor"' 2>/dev/null || echo "cursor")"
      if ! runtime="$(orchestrator_validate_runtime "$runtime_raw")"; then
        ralph_orchestrator_log "FAIL parse: invalid RUNTIME '$runtime_raw' (use cursor, claude, codex, or opencode)"
        echo -e "${C_R}Invalid RUNTIME '${runtime_raw}'. Use cursor, claude, codex, or opencode.${C_RST}" >&2
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
      if ! orch_stage_execute "$step_index" "$stage" "$plan_abs" "$plan_rel" "$runtime" "$agent" "$agent_source" "$stage_model" "$agent_source_raw" "$planTemplate" "$stage_id" "$stage_iter" step_rc; then
        exit 1
      fi
      if [[ "${step_rc:-0}" -gt 0 ]]; then
        if [[ "$step_rc" -eq 3 ]]; then
          exit 3
        fi
        exit "$step_rc"
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
_orch_summary_file="$RALPH_LOG_DIR/$RALPH_ARTIFACT_NS/orchestration-usage-summary.json"
mkdir -p "$(dirname "$_orch_summary_file")"
cat > "$_orch_summary_file" << _ORCH_SUMMARY_EOF
{"schema_version":1,"kind":"orchestration_usage_summary","orchestration":"$(basename "$ORCH_FILE")","plan_key":"${RALPH_PLAN_KEY:-${RALPH_ARTIFACT_NS:-}}","artifact_ns":"${RALPH_ARTIFACT_NS:-${RALPH_PLAN_KEY:-}}","started_at":"${_orch_started_at}","ended_at":"${_orch_ended_at}","steps":${step_index},"elapsed_seconds":${_orch_elapsed},"input_tokens":${_orch_input_tokens},"output_tokens":${_orch_output_tokens},"cache_creation_input_tokens":${_orch_cache_creation_tokens},"cache_read_input_tokens":${_orch_cache_read_tokens},"stages":[${_orch_stage_usages}]}
_ORCH_SUMMARY_EOF
_orch_elapsed_fmt="$(ralph_format_elapsed_secs "$_orch_elapsed")"
ralph_orchestrator_log "orchestration usage: steps=${step_index} input=${_orch_input_tokens} output=${_orch_output_tokens} cache_create=${_orch_cache_creation_tokens} cache_read=${_orch_cache_read_tokens} elapsed=${_orch_elapsed_fmt}"
echo -e "${C_DIM}Token usage: input=${_orch_input_tokens} output=${_orch_output_tokens} cache_read=${_orch_cache_read_tokens} elapsed=${_orch_elapsed_fmt}${C_RST}"
echo -e "${C_DIM}Total elapsed time: ${_orch_elapsed_fmt}${C_RST}"

echo -e "${C_G}${C_BOLD}Orchestration complete${C_RST} ($step_index steps). Log: $LOG_FILE"
exit 0
