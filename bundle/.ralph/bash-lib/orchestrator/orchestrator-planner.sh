#!/usr/bin/env bash
# Planner stage helpers for the orchestrator.
#
# Two branches:
#   1. Workflow-run plan-file (ungated): append a fixed prompt contract, then
#      after ordinary artifact verification call
#      workflow_state_materialize_generated_plan under the common registry run.
#      Never writes orchestration-plans/<key>/generated and never enqueues
#      dynamic stages. Ignores RALPH_DYNAMIC_PLANNER, RALPH_MODE, MCP/tooling.
#   2. Internal legacy-orchestration (gated): retain classic
#      orchestration-plans/<key>/generated writer + stages enqueue for classic
#      dynamic-planner tests. Labelled LEGACY below; never used for project /
#      global / bundled workflow runs.

if [[ -n "${RALPH_ORCHESTRATOR_PLANNER_LOADED:-}" ]]; then
  return
fi
RALPH_ORCHESTRATOR_PLANNER_LOADED=1

if ! declare -F ralph_warn >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/error-handling.sh"
fi

ORCH_PLANNER_QUEUE=()
ORCH_PLANNER_QUEUE_INDEX=0
# Set to invalid-artifact when workflow plan-file materialization fails.
ORCH_PLANNER_FAIL_REASON=""
# Human-readable detail for the most recent planner failure. Surfaced in the
# StageOutcomeReport so operators are not left with a bare "stage execution
# failed" while the real reason sits only in runner.log.
ORCH_PLANNER_FAIL_DETAIL=""

# ---------------------------------------------------------------------------
# Workflow-run detection / gates
# ---------------------------------------------------------------------------

# True when the orchestrator is executing inside a common workflow registry run.
# Engines export RALPH_WORKFLOW_REGISTRY_RUN to the absolute registry-run dir.
orch_planner_is_workflow_run() {
  [[ -n "${RALPH_WORKFLOW_REGISTRY_RUN:-}" ]]
}

# LEGACY gate only. Workflow plan-file publication ignores this entirely.
ralph_planner_stage_enabled() {
  local gate="${RALPH_DYNAMIC_PLANNER:-}"
  if [[ -n "$gate" ]]; then
    case "$gate" in
      0) return 1 ;;
      1) return 0 ;;
      *)
        ralph_warn "RALPH_DYNAMIC_PLANNER: invalid value '$gate' (use 0 or 1)"
        return 2
        ;;
    esac
  fi
  case "${RALPH_MODE:-no}" in
    ralph|hybrid) return 0 ;;
    *) return 1 ;;
  esac
}

ralph_planner_resolve_py() {
  local candidate="" dir
  for dir in "${RALPH_ACTIVE_DIR:-}" "${RALPH_DIR:-}"; do
    [[ -n "$dir" && -f "$dir/python/planner_contract.py" ]] || continue
    candidate="$dir/python/planner_contract.py"
    break
  done
  if [[ -z "$candidate" ]]; then
    ralph_warn "planner contract helper not found under Ralph python helpers"
    return 1
  fi
  printf '%s\n' "$candidate"
}

orch_planner_ensure_workflow_state() {
  if declare -F workflow_state_materialize_generated_plan >/dev/null 2>&1; then
    return 0
  fi
  local lib=""
  for lib in \
    "${RALPH_ACTIVE_DIR:-}/bash-lib/workflow/workflow-state.sh" \
    "${RALPH_DIR:-}/bash-lib/workflow/workflow-state.sh"; do
    if [[ -f "$lib" ]]; then
      # shellcheck source=/dev/null
      source "$lib"
      break
    fi
  done
  declare -F workflow_state_materialize_generated_plan >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Queue helpers (LEGACY stages enqueue only)
# ---------------------------------------------------------------------------

orch_planner_queue_clear() {
  ORCH_PLANNER_QUEUE=()
  ORCH_PLANNER_QUEUE_INDEX=0
}

orch_planner_queue_length() {
  printf '%s' "${#ORCH_PLANNER_QUEUE[@]}"
}

orch_planner_queue_push_json() {
  local stage_json="$1"
  ORCH_PLANNER_QUEUE+=("$stage_json")
}

orch_planner_queue_next_json() {
  local _out_var="${1:-ORCH_PLANNER_QUEUE_CURRENT}"
  local index="${ORCH_PLANNER_QUEUE_INDEX:-0}"
  if (( index >= ${#ORCH_PLANNER_QUEUE[@]} )); then
    return 1
  fi
  printf -v "$_out_var" '%s' "${ORCH_PLANNER_QUEUE[$index]}"
  ORCH_PLANNER_QUEUE_INDEX=$((index + 1))
  return 0
}

orch_planner_queue_has_pending() {
  local index="${ORCH_PLANNER_QUEUE_INDEX:-0}"
  (( index < ${#ORCH_PLANNER_QUEUE[@]} ))
}

# ---------------------------------------------------------------------------
# Stage / artifact helpers
# ---------------------------------------------------------------------------

orch_planner_stage_has_planner() {
  local stage_json="$1"
  echo "$stage_json" | jq -e '.planner | type == "object"' >/dev/null 2>&1
}

orch_planner_output_mode() {
  local stage_json="$1"
  echo "$stage_json" | jq -r '.planner.outputMode // empty' 2>/dev/null || echo ""
}

orch_planner_max_todos() {
  local stage_json="$1"
  local max_todos=""
  max_todos="$(echo "$stage_json" | jq -r '.planner.maxTodos // empty' 2>/dev/null || echo "")"
  if [[ -z "$max_todos" ]]; then
    max_todos=100
  fi
  printf '%s' "$max_todos"
}

orch_planner_find_artifact_path() {
  local stage_json="$1"
  local path=""
  # Planner contracts come only from stage artifacts / outputArtifacts (never role profiles).
  path="$(echo "$stage_json" | jq -r '
    [(.artifacts // []), (.outputArtifacts // [])] | add
    | map(select((.schema // "") | test("planner-output\\.schema\\.json$")))
    | .[0].path // empty
  ' 2>/dev/null || echo "")"
  if [[ -n "$path" ]]; then
    printf '%s' "$path"
    return 0
  fi
  path="$(echo "$stage_json" | jq -r '
    [(.artifacts // []), (.outputArtifacts // [])] | add
    | map(select((.path // "") | test("\\.json$")))
    | .[0].path // empty
  ' 2>/dev/null || echo "")"
  if [[ -n "$path" ]]; then
    printf '%s' "$path"
    return 0
  fi
  echo "$stage_json" | jq -r '(.artifacts[0].path // .outputArtifacts[0].path // empty)' 2>/dev/null
}

orch_planner_plan_key() {
  local orch_file="$1"
  local plan_key=""
  plan_key="$(jq -r '.namespace // .name // empty' "$orch_file" 2>/dev/null || echo "")"
  if [[ -z "$plan_key" ]]; then
    plan_key="$(basename "$orch_file" .orch.json)"
  fi
  printf '%s' "$plan_key"
}

# Resolve absolute artifact path under WORKSPACE (or absolute as-is).
orch_planner_artifact_abs() {
  local stage_json="$1"
  local artifact_rel artifact_abs
  artifact_rel="$(orch_planner_find_artifact_path "$stage_json")"
  [[ -n "$artifact_rel" ]] || return 1
  if declare -F expand_artifact_tokens >/dev/null 2>&1; then
    artifact_rel="$(expand_artifact_tokens "$artifact_rel")"
  fi
  if [[ "$artifact_rel" == /* ]]; then
    artifact_abs="$artifact_rel"
  else
    artifact_abs="${WORKSPACE:-.}/$artifact_rel"
  fi
  printf '%s' "$artifact_abs"
}

# Find the planFrom consumer of planner_stage_id in ORCH_FILE / orch_file whose
# routing should freeze the generated plan.
#
# Multiple consumers are normal and expected: rework derivation clones the
# consumer stage once per rework round (implement -> implement-r1 -> implement-r2),
# and every clone inherits planFrom from the stage it was cloned from. Those
# clones are the compiler's own output, not an authoring mistake, so rejecting
# them outright made every rework-bearing workflow (including the bundled
# bug-fix workflow) fail the moment its planner stage finished.
#
# The consumer is only read for its runtime/model, so what actually matters is
# whether the consumers AGREE on routing. They agree -> freeze on that routing.
# They genuinely diverge -> the choice is ambiguous and the caller must fail.
#
# Prints consumer stage JSON on stdout, or empty when zero consumers.
# Returns 2 only when consumers disagree on runtime/model. Callers that want to
# name the colliding stages use orch_planner_consumer_conflict_detail; this
# function runs inside a command substitution, so it cannot export state.
orch_planner_find_consumer_json() {
  local orch_file="${1:-${ORCH_FILE:-}}"
  local planner_stage_id="$2"
  local count distinct consumer_json=""
  [[ -n "$orch_file" && -f "$orch_file" && -n "$planner_stage_id" ]] || {
    printf '%s' ""
    return 0
  }
  count="$(jq -r --arg id "$planner_stage_id" \
    '[.stages[]? | select((.planFrom // "") == $id)] | length' \
    "$orch_file" 2>/dev/null || echo 0)"
  if [[ "$count" -eq 0 ]]; then
    printf '%s' ""
    return 0
  fi
  if [[ "$count" -gt 1 ]]; then
    distinct="$(jq -r --arg id "$planner_stage_id" \
      '[.stages[]? | select((.planFrom // "") == $id)
        | ((.runtime // "") + "/" + (.model // ""))] | unique | length' \
      "$orch_file" 2>/dev/null || echo 0)"
    if [[ "$distinct" != "1" ]]; then
      return 2
    fi
  fi
  # One consumer, or several that agree: the first carries the shared routing.
  consumer_json="$(jq -c --arg id "$planner_stage_id" \
    '[.stages[]? | select((.planFrom // "") == $id)] | .[0]' \
    "$orch_file" 2>/dev/null || echo "")"
  printf '%s' "$consumer_json"
  return 0
}

# Human-readable "id=runtime/model" list of a planner stage's planFrom consumers,
# used to name the stages that collided when routing genuinely diverges.
orch_planner_consumer_conflict_detail() {
  local orch_file="${1:-${ORCH_FILE:-}}"
  local planner_stage_id="$2"
  [[ -n "$orch_file" && -f "$orch_file" && -n "$planner_stage_id" ]] || return 0
  jq -r --arg id "$planner_stage_id" \
    '[.stages[]? | select((.planFrom // "") == $id)
      | "\(.id)=\(.runtime // "-")/\(.model // "-")"] | join(", ")' \
    "$orch_file" 2>/dev/null || true
}

# Resolve frozen default runtime/model for materialization.
# One consumer: consumer stage runtime/model (with planner/env fallbacks).
# Zero consumers: planner stage / RALPH_WORKFLOW_FALLBACK_* / RALPH_PLAN_RUNTIME.
# Prints: <runtime>\t<model>
orch_planner_resolve_default_routing() {
  local planner_stage_json="$1"
  local consumer_json="${2:-}"
  local runtime="" model="" provenance=""

  if [[ -n "$consumer_json" ]]; then
    runtime="$(echo "$consumer_json" | jq -r '.runtime // empty' 2>/dev/null || echo "")"
    model="$(echo "$consumer_json" | jq -r '.model // empty' 2>/dev/null || echo "")"
    provenance="consumer"
  fi
  if [[ -z "$runtime" ]]; then
    runtime="$(echo "$planner_stage_json" | jq -r '.runtime // empty' 2>/dev/null || echo "")"
    [[ -n "$provenance" ]] || provenance="planner-stage"
  fi
  if [[ -z "$runtime" ]]; then
    runtime="${RALPH_WORKFLOW_FALLBACK_RUNTIME:-${RALPH_PLAN_RUNTIME:-}}"
    provenance="fallback"
  fi
  if [[ -z "$model" ]]; then
    if [[ -n "$consumer_json" ]]; then
      :
    else
      model="$(echo "$planner_stage_json" | jq -r '.model // empty' 2>/dev/null || echo "")"
    fi
  fi
  if [[ -z "$model" ]]; then
    model="${RALPH_WORKFLOW_FALLBACK_MODEL:-}"
  fi
  printf '%s\t%s\t%s' "$runtime" "$model" "$provenance"
}

# Collect resolved upstream required-artifact paths for the prompt.
orch_planner_upstream_artifacts_text() {
  local stage_json="$1"
  local lines="" path
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    if declare -F expand_artifact_tokens >/dev/null 2>&1; then
      path="$(expand_artifact_tokens "$path")"
    fi
    lines+="- ${path}"$'\n'
  done < <(echo "$stage_json" | jq -r '
    [(.inputArtifacts // []), (.requires // [])] | add
    | map(.path // empty) | map(select(length > 0)) | .[]
  ' 2>/dev/null || true)
  printf '%s' "$lines"
}

orch_planner_artifact_list_text() {
  local stage_json="$1"
  local field="$2"
  local lines="" path
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    if declare -F expand_artifact_tokens >/dev/null 2>&1; then
      path="$(expand_artifact_tokens "$path")"
    fi
    lines+="- ${path}"$'\n'
  done < <(echo "$stage_json" | jq -r --arg f "$field" '
    (.[$f] // []) | map(.path // empty) | map(select(length > 0)) | .[]
  ' 2>/dev/null || true)
  printf '%s' "$lines"
}

# Build the fixed plan-file prompt contract (workflow + sourced helper tests).
# Args: planner_stage_json, task_text, artifact_rel, max_todos, consumer_json
orch_planner_build_plan_file_prompt() {
  local planner_stage_json="$1"
  local task_text="$2"
  local artifact_rel="$3"
  local max_todos="$4"
  local consumer_json="${5:-}"
  local planner_id upstream requires produces
  local workspace_mode write_scopes git_access instructions
  local runtime model provenance routing_line consumer_id
  local review_rework block=""

  planner_id="$(echo "$planner_stage_json" | jq -r '.id // empty' 2>/dev/null || echo "")"
  upstream="$(orch_planner_upstream_artifacts_text "$planner_stage_json")"
  IFS=$'\t' read -r runtime model provenance <<<"$(orch_planner_resolve_default_routing "$planner_stage_json" "$consumer_json")"
  routing_line="effective default runtime=${runtime:-<unset>} model=${model:-<runtime-default>} provenance=${provenance}"

  block+="## Ralph plan-file planner contract"$'\n\n'
  block+="Emit exactly one planner-output-v2 JSON object to the declared artifact path."$'\n'
  block+="Do not wrap the JSON in markdown fences."$'\n'
  block+="Do not emit an alternate checklist, markdown plan, pipeline, workflow, or topology."$'\n\n'
  block+="Concrete task:"$'\n'
  block+="${task_text:-<task not provided>}"$'\n\n'
  block+="Repository instructions: reread AGENTS.md / project instruction files and named upstream artifacts before decomposing."$'\n\n'
  block+="Resolved upstream artifacts:"$'\n'
  if [[ -n "$upstream" ]]; then
    block+="$upstream"
  else
    block+="(none declared)"$'\n'
  fi
  block+=$'\n'
  block+="Exact declared planner JSON output path: ${artifact_rel}"$'\n'
  block+="maxTodos ceiling (safety limit, not a target): ${max_todos}"$'\n\n'
  block+="planner-output-v2 shape (closed object):"$'\n'
  block+='{"schemaVersion":2,"name":"...","overview":"...","rationale":"...","todos":[{"id":"kebab-id","content":"...","verification":"...","status":"pending","runtime":"<optional>","model":"<optional>"}]}'$'\n\n'
  block+="Evidence-first decomposition rules:"$'\n'
  block+="- Read the task, repository instructions, investigation/design artifacts, affected code/tests, and existing behavior before writing TODOs."$'\n'
  block+="- Use the fewest independently verifiable TODOs that fully cover the task; do not pad, arbitrarily split, or collapse unrelated changes."$'\n'
  block+="- Each TODO names intended behavior, concrete scope/files when knowable, rejection/error cases, cheapest appropriate tests, and executable verification."$'\n'
  block+="- Unknown product decisions become explicit blockers/assumptions in rationale; do not silently decide them."$'\n'
  block+="- Optional runtime/model on a TODO is an intentional override; otherwise routing stays neutral for supervisor freeze."$'\n'
  block+="- sessionStrategy is forbidden in planner JSON; the rendered plan always uses fresh sessions."$'\n\n'

  if [[ -n "$consumer_json" ]]; then
    consumer_id="$(echo "$consumer_json" | jq -r '.id // empty')"
    instructions="$(echo "$consumer_json" | jq -r '.instructions // empty')"
    requires="$(orch_planner_artifact_list_text "$consumer_json" "inputArtifacts")"
    if [[ -z "$requires" ]]; then
      requires="$(orch_planner_artifact_list_text "$consumer_json" "requires")"
    fi
    produces="$(orch_planner_artifact_list_text "$consumer_json" "outputArtifacts")"
    if [[ -z "$produces" ]]; then
      produces="$(orch_planner_artifact_list_text "$consumer_json" "artifacts")"
    fi
    if [[ -z "$produces" ]]; then
      produces="$(orch_planner_artifact_list_text "$consumer_json" "produces")"
    fi
    workspace_mode="$(echo "$consumer_json" | jq -r '.workspaceMode // "shared"')"
    write_scopes="$(echo "$consumer_json" | jq -c '.writeScopes // []' 2>/dev/null || echo '[]')"
    git_access="$(echo "$consumer_json" | jq -r '.agentGitAccess // "inherit"')"
    review_rework="$(echo "$consumer_json" | jq -r '
      if .loopControl then
        "loopBackTo=\(.loopControl.loopBackTo // "") maxIterations=\(.loopControl.maxIterations // "") onExhausted=\(.loopControl.onExhausted // "")"
      elif .loopBackTo then
        "loopBackTo=\(.loopBackTo) maxIterations=\(.maxIterations // "") onExhausted=\(.onExhausted // "")"
      else
        "none declared"
      end
    ' 2>/dev/null || echo "none declared")"

    block+="Sole consumer contract:"$'\n'
    block+="- consumer stage ID: ${consumer_id}"$'\n'
    block+="- consumer instructions: ${instructions:-<none>}"$'\n'
    block+="- requires:"$'\n'
    if [[ -n "$requires" ]]; then
      block+="$requires"
    else
      block+="  (none)"$'\n'
    fi
    block+="- produces:"$'\n'
    if [[ -n "$produces" ]]; then
      block+="$produces"
    else
      block+="  (none; do not invent a synthetic handoff)"$'\n'
    fi
    block+="- workspaceMode: ${workspace_mode}"$'\n'
    block+="- writeScopes: ${write_scopes}"$'\n'
    block+="- agentGitAccess: ${git_access}"$'\n'
    block+="- ${routing_line}"$'\n'
    block+="- review/rework contract: ${review_rework}"$'\n'
    block+="Plan TODOs must cover the requested work and end by producing and verifying every mandatory consumer handoff/output artifact listed above."$'\n'
  else
    block+="Recommended next-step plan (zero planFrom consumers):"$'\n'
    block+="- Label this output a generally runnable recommended next-step Ralph plan; no consumer will execute it in this workflow run."$'\n'
    block+="- Freeze routing from the planner run selected fallback: ${routing_line}"$'\n'
    block+="- Do not invent a synthetic consumer handoff."$'\n'
  fi
  if [[ -n "$planner_id" ]]; then
    block+=$'\n'"Planner stage ID: ${planner_id}"$'\n'
  fi
  printf '%s' "$block"
}

# Append plan-file prompt contract to stage instructions when applicable.
# Prints the combined instructions string on stdout.
orch_planner_stage_instructions_with_prompt() {
  local stage_json="$1"
  local orch_file="${2:-${ORCH_FILE:-}}"
  local base="" task_text="" artifact_rel="" max_todos="" consumer_json=""
  local output_mode="" prompt=""

  base="$(echo "$stage_json" | jq -r '.instructions // empty' 2>/dev/null || echo "")"
  if ! orch_planner_stage_has_planner "$stage_json"; then
    printf '%s' "$base"
    return 0
  fi
  output_mode="$(orch_planner_output_mode "$stage_json")"
  # Workflow plan-file prompt is unconditional. Legacy non-plan-file stages keep
  # author instructions only (classic prompt-block path removed with stages mode).
  if [[ "$output_mode" != "plan-file" ]]; then
    printf '%s' "$base"
    return 0
  fi

  artifact_rel="$(orch_planner_find_artifact_path "$stage_json")"
  if declare -F expand_artifact_tokens >/dev/null 2>&1 && [[ -n "$artifact_rel" ]]; then
    artifact_rel="$(expand_artifact_tokens "$artifact_rel")"
  fi
  max_todos="$(orch_planner_max_todos "$stage_json")"
  task_text="${RALPH_WORKFLOW_TASK:-${RALPH_TASK:-}}"
  if [[ -z "$task_text" && -n "$orch_file" && -f "$orch_file" ]]; then
    task_text="$(jq -r '.task // .overview // .name // empty' "$orch_file" 2>/dev/null || echo "")"
  fi
  consumer_json="$(orch_planner_find_consumer_json "$orch_file" "$(echo "$stage_json" | jq -r '.id // empty')")" || consumer_json=""
  prompt="$(orch_planner_build_plan_file_prompt "$stage_json" "$task_text" "$artifact_rel" "$max_todos" "$consumer_json")"
  if [[ -n "$base" ]]; then
    printf '%s\n\n%s' "$base" "$prompt"
  else
    printf '%s' "$prompt"
  fi
}

# Compatibility wrapper used by older call sites / tests.
ralph_planner_prepare_prompt() {
  local planner_json="$1"
  local plan_key="${2:-}"
  local stage_json
  # Build a minimal stage envelope so the plan-file prompt helper can run.
  stage_json="$(jq -nc --argjson planner "$planner_json" \
    --arg id "planner" \
    '{id:$id, planner:$planner, artifacts:[{path:".ralph-workspace/artifacts/{{ARTIFACT_NS}}/planner-output.json", required:true, schema:"bundle/.ralph/schemas/planner-output.schema.json"}]}' \
    2>/dev/null || echo "{\"id\":\"planner\",\"planner\":${planner_json}}")"
  _="$plan_key"
  orch_planner_build_plan_file_prompt "$stage_json" "${RALPH_WORKFLOW_TASK:-}" \
    ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/planner-output.json" \
    "$(echo "$planner_json" | jq -r '.maxTodos // 100')" \
    ""
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

orch_planner_validate_orchestration() {
  local orch_file="$1"
  local has_plan_file=0
  if jq -e '.stages[]? | select((.planner.outputMode // "") == "plan-file")' "$orch_file" >/dev/null 2>&1; then
    has_plan_file=1
  fi

  # Plan-file planner configs always validate (workflow semantics; ungated).
  if [[ "$has_plan_file" -eq 1 ]]; then
    local py
    py="$(ralph_planner_resolve_py)" || return 1
    if ! command -v python3 >/dev/null 2>&1; then
      ralph_warn "orch_planner_validate_orchestration: python3 is required when plan-file planner stages are declared"
      return 1
    fi
    python3 "$py" validate-orchestration --orchestration "$orch_file"
    return $?
  fi

  # LEGACY: stages / removed role keys are not validated by the v2 contract.
  # Gate only controls whether classic dynamic planner apply runs later.
  return 0
}

# ---------------------------------------------------------------------------
# Workflow plan-file publication (ungated)
# ---------------------------------------------------------------------------

orch_planner_fail_invalid_artifact() {
  local step_n="$1"
  local step_status_var="$2"
  local detail="${3:-}"
  ORCH_PLANNER_FAIL_REASON="invalid-artifact"
  ORCH_PLANNER_FAIL_DETAIL="$detail"
  ralph_orchestrator_log "FAIL step $step_n: invalid-artifact${detail:+: $detail}"
  echo -e "${C_R}${C_BOLD}Step $step_n failed (invalid-artifact)${C_RST}" >&2
  if [[ -n "$detail" ]]; then
    echo "  $detail" >&2
  fi
  printf -v "$step_status_var" '%s' 1
  return 1
}

# After ordinary stage artifact verification: materialize under the registry run.
# Never publishes a manifest on failure (materializer rolls back).
orch_planner_apply_workflow_plan_file() {
  local stage_json="$1"
  local stage_id="$2"
  local step_n="$3"
  local step_status_var="$4"

  ORCH_PLANNER_FAIL_REASON=""
  ORCH_PLANNER_FAIL_DETAIL=""

  local artifact_abs max_todos attempt registry_run
  local consumer_json runtime model provenance plan_path detail conflict
  local materialize_args=()

  if ! orch_planner_ensure_workflow_state; then
    orch_planner_fail_invalid_artifact "$step_n" "$step_status_var" "workflow-state materializer unavailable"
    return 1
  fi

  registry_run="${RALPH_WORKFLOW_REGISTRY_RUN:-}"
  if [[ -z "$registry_run" || ! -d "$registry_run" ]]; then
    orch_planner_fail_invalid_artifact "$step_n" "$step_status_var" "RALPH_WORKFLOW_REGISTRY_RUN is missing or not a directory"
    return 1
  fi

  artifact_abs="$(orch_planner_artifact_abs "$stage_json")" || {
    orch_planner_fail_invalid_artifact "$step_n" "$step_status_var" "planner stage missing artifact path"
    return 1
  }
  if [[ ! -f "$artifact_abs" ]]; then
    orch_planner_fail_invalid_artifact "$step_n" "$step_status_var" "planner artifact not found: $artifact_abs"
    return 1
  fi

  max_todos="$(orch_planner_max_todos "$stage_json")"
  attempt="${RALPH_WORKFLOW_STAGE_ATTEMPT:-1}"
  if ! [[ "$attempt" =~ ^[1-9][0-9]*$ ]]; then
    attempt=1
  fi

  consumer_json="$(orch_planner_find_consumer_json "${ORCH_FILE:-}" "$stage_id")" || {
    detail="planner stage has planFrom consumers with conflicting runtime/model"
    conflict="$(orch_planner_consumer_conflict_detail "${ORCH_FILE:-}" "$stage_id")"
    if [[ -n "$conflict" ]]; then
      detail="$detail: $conflict"
    fi
    orch_planner_fail_invalid_artifact "$step_n" "$step_status_var" "$detail"
    return 1
  }
  IFS=$'\t' read -r runtime model provenance <<<"$(orch_planner_resolve_default_routing "$stage_json" "$consumer_json")"
  if [[ -z "$runtime" ]]; then
    orch_planner_fail_invalid_artifact "$step_n" "$step_status_var" "missing effective default runtime for generated plan freeze"
    return 1
  fi

  materialize_args=(
    --registry-run "$registry_run"
    --planner-stage-id "$stage_id"
    --attempt "$attempt"
    --artifact "$artifact_abs"
    --max-todos "$max_todos"
    --default-runtime "$runtime"
  )
  if [[ -n "$model" ]]; then
    materialize_args+=(--default-model "$model")
  fi

  if [[ "${ORCHESTRATOR_DRY_RUN:-0}" == "1" ]]; then
    echo -e "${C_Y}Planner plan-file (dry-run): would materialize under $registry_run/plans/$stage_id/attempt-${attempt}.{plan.md,manifest.json}${C_RST}"
    echo -e "${C_Y}  freeze runtime=$runtime model=${model:-<none>} provenance=$provenance${C_RST}"
    return 0
  fi

  if ! plan_path="$(workflow_state_materialize_generated_plan "${materialize_args[@]}" 2>&1)"; then
    detail="$plan_path"
    # Never leave a published manifest for a failed stage; materializer rolls back.
    orch_planner_fail_invalid_artifact "$step_n" "$step_status_var" "$detail"
    return 1
  fi

  ralph_orchestrator_log "planner step $step_n published run-scoped plan: $plan_path (runtime=$runtime provenance=$provenance)"
  echo -e "${C_Y}Planner plan-file published:${C_RST}"
  echo -e "${C_Y}  plan: $plan_path${C_RST}"
  echo -e "${C_Y}  freeze runtime=$runtime model=${model:-<none>} provenance=$provenance${C_RST}"
  return 0
}

# ---------------------------------------------------------------------------
# LEGACY classic dynamic-planner apply (gated; orchestration-plans/generated)
# ---------------------------------------------------------------------------

orch_planner_legacy_show_summary() {
  local output_mode="$1"
  local item_count="$2"
  local generated_dir="$3"
  echo "Planner decomposition (legacy-orchestration):"
  echo "  outputMode: $output_mode"
  echo "  items: $item_count"
  echo "  generatedDir: $generated_dir"
}

# LEGACY: write classic items under orchestration-plans/<key>/generated and
# optionally enqueue stages. Uses parse-legacy-output when available; falls
# back to jq. Never used for workflow-run plan-file publication.
orch_planner_apply_legacy() {
  local stage_json="$1"
  local stage_id="$2"
  local step_n="$3"
  local step_status_var="$4"

  if ! ralph_planner_stage_enabled; then
    return 0
  fi

  local artifact_abs planner_json plan_key output_mode generated_dir
  local workspace_abs item_count=0 py parsed=""
  local dry="${ORCHESTRATOR_DRY_RUN:-0}"

  artifact_abs="$(orch_planner_artifact_abs "$stage_json")" || {
    ralph_orchestrator_log "FAIL step $step_n: legacy planner missing artifact path"
    echo -e "${C_R}${C_BOLD}Step $step_n failed (planner missing artifact)${C_RST}" >&2
    printf -v "$step_status_var" '%s' 1
    return 1
  }
  if [[ ! -f "$artifact_abs" ]]; then
    ralph_orchestrator_log "FAIL step $step_n: legacy planner artifact not found: $artifact_abs"
    echo -e "${C_R}${C_BOLD}Step $step_n failed (planner artifact missing)${C_RST}" >&2
    printf -v "$step_status_var" '%s' 1
    return 1
  fi

  planner_json="$(echo "$stage_json" | jq -c '.planner' 2>/dev/null || echo "{}")"
  output_mode="$(echo "$planner_json" | jq -r '.outputMode // "stages"' 2>/dev/null || echo "stages")"
  plan_key="$(orch_planner_plan_key "$ORCH_FILE")"
  workspace_abs="${WORKSPACE:-.}"
  generated_dir="$RALPH_PLAN_WORKSPACE_ROOT/orchestration-plans/${plan_key}/generated"

  py="$(ralph_planner_resolve_py 2>/dev/null || true)"
  if [[ -n "$py" ]] && command -v python3 >/dev/null 2>&1; then
    parsed="$(python3 "$py" parse-legacy-output --artifact "$artifact_abs" 2>/dev/null || true)"
  fi
  if [[ -z "$parsed" ]]; then
    # Accept classic shape without the Python helper.
    if ! jq -e '.items | type == "array" and length > 0' "$artifact_abs" >/dev/null 2>&1; then
      ralph_orchestrator_log "FAIL step $step_n: legacy planner artifact invalid"
      echo -e "${C_R}${C_BOLD}Step $step_n planner apply failed${C_RST}" >&2
      printf -v "$step_status_var" '%s' 1
      return 1
    fi
    parsed="$(jq -c '{rationale:(.rationale//""),items,verification:(.verification//"")}' "$artifact_abs")"
  fi

  item_count="$(printf '%s' "$parsed" | jq '.items | length')"
  echo -e "${C_Y}$(orch_planner_legacy_show_summary "$output_mode" "$item_count" "orchestration-plans/${plan_key}/generated")${C_RST}"
  while IFS= read -r _legacy_item_id; do
    [[ -n "$_legacy_item_id" ]] || continue
    echo -e "${C_Y}  - ${_legacy_item_id}${C_RST}"
  done < <(printf '%s' "$parsed" | jq -r '.items[]?.id // empty')

  if [[ "$dry" == "1" ]]; then
    return 0
  fi

  mkdir -p "$generated_dir"

  if [[ "$output_mode" == "plan-file" ]]; then
    local plan_name plan_abs rationale verification line
    plan_name="${stage_id}-decomposition.plan.md"
    plan_abs="$generated_dir/$plan_name"
    if [[ -e "$plan_abs" ]]; then
      ralph_orchestrator_log "FAIL step $step_n: refusing to overwrite $plan_abs"
      printf -v "$step_status_var" '%s' 1
      return 1
    fi
    {
      echo "---"
      echo "name: ${stage_id} decomposition"
      echo "overview: Generated by Ralph legacy planner stage"
      echo "---"
      echo ""
      echo "# ${stage_id} decomposition"
      echo ""
      printf '%s' "$parsed" | jq -r '.rationale // empty'
      echo ""
      while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        echo "- [ ] $line"
      done < <(printf '%s' "$parsed" | jq -r '.items[]?.content // empty')
      verification="$(printf '%s' "$parsed" | jq -r '.verification // empty')"
      if [[ -n "$verification" ]]; then
        echo ""
        echo "verification: |"
        echo "  $verification"
      fi
    } >"$plan_abs"
    return 0
  fi

  # stages mode: one plan + queued stage per item
  local item_id content runtime role model plan_rel plan_abs stage_line
  while IFS= read -r item_id; do
    [[ -n "$item_id" ]] || continue
    content="$(printf '%s' "$parsed" | jq -r --arg id "$item_id" '.items[] | select(.id==$id) | .content' )"
    runtime="$(printf '%s' "$parsed" | jq -r --arg id "$item_id" '.items[] | select(.id==$id) | .runtime // empty' 2>/dev/null || echo "")"
    # Prefer role; map legacy agent field when present in raw artifact.
    role="$(jq -r --arg id "$item_id" '.items[]? | select(.id==$id) | (.role // .agent // empty)' "$artifact_abs" 2>/dev/null || echo "")"
    model="$(jq -r --arg id "$item_id" '.items[]? | select(.id==$id) | (.model // empty)' "$artifact_abs" 2>/dev/null || echo "")"
    [[ -n "$runtime" ]] || runtime="$(echo "$planner_json" | jq -r '.defaultRuntime // "cursor"')"
    [[ -n "$role" ]] || role="$(echo "$planner_json" | jq -r '.defaultRole // .defaultAgent // "implementation"')"
    plan_rel=".ralph-workspace/orchestration-plans/${plan_key}/generated/${item_id}.plan.md"
    # Write under state root generated dir (absolute).
    plan_abs="$generated_dir/${item_id}.plan.md"
    if [[ -e "$plan_abs" ]]; then
      ralph_orchestrator_log "FAIL step $step_n: refusing to overwrite $plan_abs"
      printf -v "$step_status_var" '%s' 1
      return 1
    fi
    {
      echo "---"
      echo "name: ${item_id}"
      echo "overview: Generated by Ralph legacy planner stage"
      echo "---"
      echo ""
      echo "# ${item_id}"
      echo ""
      printf '%s' "$parsed" | jq -r '.rationale // empty'
      echo ""
      echo "- [ ] $content"
      verification="$(printf '%s' "$parsed" | jq -r '.verification // empty')"
      if [[ -n "$verification" ]]; then
        echo ""
        echo "verification: |"
        echo "  $verification"
      fi
    } >"$plan_abs"

    # Relative plan path from project workspace for the queued stage.
    plan_rel="${plan_abs#"$workspace_abs"/}"
    if [[ "$plan_rel" == "$plan_abs" ]]; then
      # State root may sit under workspace as .ralph-workspace/...
      plan_rel=".ralph-workspace/orchestration-plans/${plan_key}/generated/${item_id}.plan.md"
      mkdir -p "$workspace_abs/.ralph-workspace/orchestration-plans/${plan_key}/generated"
      # Mirror into workspace-relative path when state root differs.
      if [[ "$plan_abs" != "$workspace_abs/.ralph-workspace/orchestration-plans/${plan_key}/generated/${item_id}.plan.md" ]]; then
        cp "$plan_abs" "$workspace_abs/.ralph-workspace/orchestration-plans/${plan_key}/generated/${item_id}.plan.md" 2>/dev/null || true
      fi
    fi

    stage_line="$(jq -nc \
      --arg id "$item_id" \
      --arg runtime "$runtime" \
      --arg role "$role" \
      --arg plan "$plan_rel" \
      --arg model "$model" \
      --arg ns_art ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/${item_id}.md" \
      '
      {
        id: $id,
        runtime: $runtime,
        role: $role,
        plan: $plan,
        sessionStrategy: "fresh",
        sessionResume: false,
        artifacts: [{path: $ns_art, required: true}]
      }
      + (if $model != "" then {model: $model} else {} end)
      ')"
    orch_planner_queue_push_json "$stage_line"
  done < <(printf '%s' "$parsed" | jq -r '.items[]?.id // empty')

  ralph_orchestrator_log "legacy planner step $step_n queued ${#ORCH_PLANNER_QUEUE[@]} generated stage(s)"
  return 0
}

# ---------------------------------------------------------------------------
# Public apply entry: branch workflow vs LEGACY
# ---------------------------------------------------------------------------

orch_planner_apply_output() {
  local stage_json="$1"
  local stage_id="$2"
  local step_n="$3"
  local step_status_var="$4"
  local output_mode=""

  ORCH_PLANNER_FAIL_REASON=""
  ORCH_PLANNER_FAIL_DETAIL=""

  if ! orch_planner_stage_has_planner "$stage_json"; then
    return 0
  fi

  output_mode="$(orch_planner_output_mode "$stage_json")"

  # Workflow-run + plan-file: ungated. Ignores RALPH_DYNAMIC_PLANNER / RALPH_MODE.
  if orch_planner_is_workflow_run && [[ "$output_mode" == "plan-file" ]]; then
    orch_planner_apply_workflow_plan_file "$stage_json" "$stage_id" "$step_n" "$step_status_var"
    return $?
  fi

  # Also treat plan-file without registry as invalid when workflow env claims a run id only.
  if [[ "$output_mode" == "plan-file" && -n "${RALPH_WORKFLOW_RUN_ID:-}" && -z "${RALPH_WORKFLOW_REGISTRY_RUN:-}" ]]; then
    orch_planner_fail_invalid_artifact "$step_n" "$step_status_var" "RALPH_WORKFLOW_RUN_ID set without RALPH_WORKFLOW_REGISTRY_RUN"
    return 1
  fi

  # LEGACY-orchestration branch (gated). Skip in single-stage bridge mode so
  # graph/dependency dispatch does not enqueue classic dynamic stages.
  if [[ "${SINGLE_STAGE_MODE:-0}" == "1" ]]; then
    return 0
  fi
  orch_planner_apply_legacy "$stage_json" "$stage_id" "$step_n" "$step_status_var"
}
