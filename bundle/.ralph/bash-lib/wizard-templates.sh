#!/usr/bin/env bash
# Template and artifact generation helpers for the orchestration wizard.
#
# Public interface:
#   wizard_render_plan_template -- materialize a stage plan from the shared template + metadata.
#   wizard_build_stage_entry -- emit one orchestration JSON stage object (shell string).
#   wizard_write_orchestration_file -- write the full .orch.json from pipeline metadata and stages.
#   wizard_render_summary -- print a human-readable summary of the pipeline before writing files.

# Internal: color codes for summary output (initialized on first use)
_wizard_summary_init_colors() {
  _WIZ_C_RST="" _WIZ_C_BOLD="" _WIZ_C_DIM="" _WIZ_C_G="" _WIZ_C_C="" _WIZ_C_Y=""
  if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    _WIZ_C_RST=$'\033[0m'
    _WIZ_C_BOLD=$'\033[1m'
    _WIZ_C_DIM=$'\033[2m'
    _WIZ_C_G=$'\033[32m'
    _WIZ_C_C=$'\033[36m'
    _WIZ_C_Y=$'\033[33m'
  fi
}

# Renders a human-readable summary of the pipeline configuration.
# Args: 1 pipeline_name, 2 namespace, 3 description, 4 session_resume_enabled, 5... stage entries
# Global arrays used: stage_ids, stage_runtimes, stage_agents, stage_models, stage_session_strategy,
#                     stage_context_budgets, stage_input_sources, stage_handoff_targets,
#                     parallel_stage_waves, loop_sources, loop_targets, loop_max_iterations
# Returns: prints summary to stdout.
wizard_render_summary() {
  local pipeline_name="$1"
  local namespace="$2"
  local description="$3"
  local session_resume_enabled="$4"
  shift 4

  _wizard_summary_init_colors

  # Header
  printf '\n%s%sPipeline Summary%s\n' "$_WIZ_C_BOLD" "$_WIZ_C_C" "$_WIZ_C_RST"
  printf '%s\n\n' "${_WIZ_C_DIM}================================${_WIZ_C_RST}"

  # Metadata
  printf '%sName:%s %s\n' "$_WIZ_C_BOLD" "$_WIZ_C_RST" "$pipeline_name"
  printf '%sNamespace:%s %s\n' "$_WIZ_C_BOLD" "$_WIZ_C_RST" "$namespace"
  printf '%sDescription:%s %s\n' "$_WIZ_C_BOLD" "$_WIZ_C_RST" "$description"
  printf '%sAll Resume:%s %s\n' "$_WIZ_C_BOLD" "$_WIZ_C_RST" "$session_resume_enabled"
  printf '\n'

  # Stages table header
  printf '%sStages:%s\n' "$_WIZ_C_BOLD" "$_WIZ_C_RST"
  printf '  %-12s %-10s %-15s %-20s %-10s %-10s\n' "ID" "Runtime" "Agent" "Model" "Session" "Budget"
  printf '  %s\n' "${_WIZ_C_DIM}--------------------------------------------------------------------------------${_WIZ_C_RST}"

  # Stage rows
  local idx=0
  for stage_entry in "$@"; do
    # Extract values from the entry JSON (simplified extraction)
    local stage_id="${stage_ids[$idx]:-}"
    local runtime="${stage_runtimes[$idx]:-}"
    local agent="${stage_agents[$idx]:-}"
    local model="${stage_models[$idx]:-}"
    local session_strategy="${stage_session_strategy[$idx]:-fresh}"
    local budget="${stage_context_budgets[$idx]:-}"

    # Truncate long values
    [[ ${#agent} -gt 15 ]] && agent="${agent:0:12}..."
    [[ ${#model} -gt 20 ]] && model="${model:0:17}..."

    printf '  %-12s %-10s %-15s %-20s %-10s %-10s\n' \
      "$stage_id" "$runtime" "$agent" "${model:-(default)}" "$session_strategy" "${budget:-(none)}"
    ((++idx))
  done
  printf '\n'

  # Parallel waves
  if [[ "${parallel_stages_enabled:-false}" == "true" ]] && (( ${#parallel_stage_waves[@]-0} > 0 )); then
    printf '%sParallel Waves:%s\n' "$_WIZ_C_BOLD" "$_WIZ_C_RST"
    local wave_num=1
    for wave in "${parallel_stage_waves[@]}"; do
      printf '  Wave %d: %s\n' "$wave_num" "$wave"
      ((wave_num++))
    done
    printf '\n'
  fi

  # Input dependencies
  local has_deps=0
  for input_src in "${stage_input_sources[@]-}"; do
    [[ -n "$input_src" ]] && { has_deps=1; break; }
  done
  if (( has_deps == 1 )); then
    printf '%sInput Dependencies:%s\n' "$_WIZ_C_BOLD" "$_WIZ_C_RST"
    for idx in "${!stage_ids[@]-}"; do
      local input_src="${stage_input_sources[$idx]:-}"
      if [[ -n "$input_src" ]]; then
        printf '  %s reads from: %s\n' "${stage_ids[$idx]}" "$input_src"
      fi
    done
    printf '\n'
  fi

  # Loop rules
  if (( ${#loop_sources[@]-0} > 0 )); then
    printf '%sLoop Rules:%s\n' "$_WIZ_C_BOLD" "$_WIZ_C_RST"
    for idx in "${!loop_sources[@]}"; do
      printf '  %s -> %s (max %d iterations)\n' \
        "${loop_sources[$idx]}" "${loop_targets[$idx]}" "${loop_max_iterations[$idx]}"
    done
    printf '\n'
  fi

  # Handoffs
  local has_handoffs=0
  for target in "${stage_handoff_targets[@]-}"; do
    [[ -n "$target" ]] && { has_handoffs=1; break; }
  done
  if (( has_handoffs == 1 )); then
    printf '%sHandoffs:%s\n' "$_WIZ_C_BOLD" "$_WIZ_C_RST"
    for idx in "${!stage_ids[@]-}"; do
      local target="${stage_handoff_targets[$idx]:-}"
      if [[ -n "$target" ]]; then
        printf '  %s -> %s\n' "${stage_ids[$idx]}" "$target"
      fi
    done
    printf '\n'
  fi

  printf '%s\n\n' "${_WIZ_C_DIM}================================${_WIZ_C_RST}"
}

# Ensures a stage plan file exists by rendering the shared plan template and appending metadata.
# Args: 1 plan_template, 2 plan_abs_path, 3 plan_rel_path, 4 namespace, 5 stage_label, 6 pipeline_name,
#       7 runtime, 8 agent, 9 stage_desc, 10 stage_input_list, 11 stage_model
# Returns: 0 on success.
wizard_render_plan_template() {
  local plan_template="$1"
  local plan_abs_path="$2"
  local plan_rel_path="$3"
  local namespace="$4"
  local stage_label="$5"
  local pipeline_name="$6"
  local runtime="$7"
  local agent="$8"
  local stage_desc="$9"
  local stage_input_list="${10:-}"
  local stage_model="${11:-}"

  if [[ -f "$plan_abs_path" ]]; then
    echo "Plan already exists: $plan_rel_path"
    return 0
  fi

  local plan_title
  plan_title="$(printf '%s %s stage plan for %s' "$namespace" "$stage_label" "$pipeline_name")"
  sed "s/PLAN_TITLE_HERE/$(escape_sed "$plan_title")/" "$plan_template" > "$plan_abs_path"
  {
    printf '\n## Stage overview\n- Stage: %s\n- Runtime: %s\n- Agent: %s\n' "$stage_label" "$runtime" "$agent"
    [[ -n "$stage_desc" ]] && printf '%s\n' "- Description: $stage_desc"
    [[ -n "$stage_input_list" ]] && printf '%s\n' "- Input from stages: $stage_input_list"
    [[ -n "$stage_model" ]] && printf '%s\n' "- Model: $stage_model"
  } >> "$plan_abs_path"
  echo "Created plan $plan_rel_path"
}

# Builds the JSON entry for a stage, including optional artifacts and control data.
# Args: 1 namespace, 2 stage_label, 3 runtime, 4 agent, 5 agent_source, 6 plan_rel_path, 7 artifact_path,
#       8 stage_desc, 9 stage_model, 10 session_strategy, 11 stage_input_list, 12 context_budget,
#       13 handoff_target, 14 handoff_kind
# Returns: prints the JSON entry to stdout.
wizard_build_stage_entry() {
  local namespace="$1"
  local stage_label="$2"
  local runtime="$3"
  local agent="$4"
  local agent_source="$5"
  local plan_rel_path="$6"
  local artifact_path="$7"
  local stage_desc="$8"
  local stage_model="$9"
  local session_strategy="${10:-fresh}"
  local stage_input_list="${11:-}"
  local context_budget="${12:-}"
  local handoff_target="${13:-}"
  local handoff_kind="${14:-}"
  local session_resume="false"
  if [[ "$session_strategy" == "resume" ]]; then
    session_resume="true"
  fi

  local entry
  entry="    {\n      \"id\": \"$stage_label\",\n      \"runtime\": \"$runtime\",\n      \"agent\": \"$agent\",\n      \"agentSource\": \"$agent_source\",\n      \"plan\": \"$plan_rel_path\",\n      \"artifacts\": [\n        {\n          \"path\": \"$artifact_path\",\n          \"required\": true\n        }\n      ]"

  if [[ -n "$stage_desc" ]]; then
    local desc_json
    desc_json="$(escape_json "$stage_desc")"
    entry="$entry,\n      \"description\": $desc_json"
  fi

  if [[ -n "$stage_model" ]]; then
    local model_json
    model_json="$(escape_json "$stage_model")"
    entry="$entry,\n      \"model\": $model_json"
  fi

  if [[ -n "$context_budget" ]]; then
    entry="$entry,\n      \"contextBudget\": \"$context_budget\""
  fi

  entry="$entry,\n      \"sessionStrategy\": \"$session_strategy\""
  entry="$entry,\n      \"sessionResume\": $session_resume"

  if [[ -n "$stage_input_list" ]]; then
    local input_artifact_entries=()
    IFS=',' read -r -a input_stage_arr <<< "$stage_input_list"
    for input_stage in "${input_stage_arr[@]}"; do
      input_stage="$(ralph_internal_wizard_sanitize "$input_stage")"
      [[ -z "$input_stage" ]] && continue
      local input_artifact_base
      input_artifact_base="$(artifact_file_for_stage "$input_stage")"
      input_artifact_entries+=("        {\n          \"path\": \".ralph-workspace/artifacts/$namespace/$input_artifact_base\"\n        }")
    done
    if (( ${#input_artifact_entries[@]} > 0 )); then
      entry="$entry,\n      \"inputArtifacts\": [\n"
      for idx in "${!input_artifact_entries[@]}"; do
        entry="$entry${input_artifact_entries[$idx]}"
        if (( idx < ${#input_artifact_entries[@]} - 1 )); then
          entry="$entry,\n"
        else
          entry="$entry\n"
        fi
      done
      entry="$entry      ]"
    fi
  fi

  if (( ${#loop_sources[@]} > 0 )); then
    for loop_idx in "${!loop_sources[@]}"; do
      if [[ "$stage_label" == "${loop_sources[$loop_idx]}" ]]; then
        entry="$entry,\n      \"loopControl\": {\n        \"loopBackTo\": \"${loop_targets[$loop_idx]}\",\n        \"maxIterations\": ${loop_max_iterations[$loop_idx]}\n      }"
        break
      fi
    done
  fi

  # Add outputArtifacts with handoff declaration if configured
  if [[ -n "$handoff_target" && -n "$handoff_kind" ]]; then
    local handoff_artifact_path=".ralph-workspace/handoffs/$namespace/${stage_label}-to-${handoff_target}.md"
    entry="$entry,\n      \"outputArtifacts\": [\n        {\n          \"path\": \"$artifact_path\",\n          \"required\": true\n        },\n        {\n          \"path\": \"$handoff_artifact_path\",\n          \"required\": false,\n          \"kind\": \"$handoff_kind\",\n          \"to\": \"$handoff_target\"\n        }\n      ]"
  fi

  entry="$entry\n    }"
  printf '%s' "$entry"
}

# Writes the orchestration JSON file from the collected stage entries.
# Args: 1 orch_file, 2 pipeline_name, 3 namespace, 4 description, 5 session_resume_enabled, 6... stage entries
# Returns: 0 on success.
wizard_write_orchestration_file() {
  local orch_file="$1"
  local pipeline_name="$2"
  local namespace="$3"
  local description="$4"
  local session_resume_enabled="$5"
  shift 5
  local stage_entries=("$@")
  local name_json
  local namespace_json
  local description_json
  local wave_json

  name_json="$(escape_json "$pipeline_name")"
  namespace_json="$(escape_json "$namespace")"
  description_json="$(escape_json "$description")"
  printf '{\n  "name": %s,\n  "namespace": %s,\n  "description": %s,\n  "sessionResumeEnabled": %s' \
    "$name_json" "$namespace_json" "$description_json" "$session_resume_enabled" > "$orch_file"

  if [[ "${parallel_stages_enabled:-false}" == "true" ]] && (( ${#parallel_stage_waves[@]-0} > 0 )); then
    printf ',\n  "parallelStages": [\n' >>"$orch_file"
    for idx in "${!parallel_stage_waves[@]}"; do
      wave_json="$(escape_json "${parallel_stage_waves[$idx]}")"
      printf '    %s' "$wave_json" >>"$orch_file"
      if (( idx < ${#parallel_stage_waves[@]} - 1 )); then
        printf ',\n' >>"$orch_file"
      else
        printf '\n' >>"$orch_file"
      fi
    done
    printf '  ]' >>"$orch_file"
  fi

  printf ',\n  "stages": [\n' >>"$orch_file"

  for idx in "${!stage_entries[@]}"; do
    printf '%b' "${stage_entries[$idx]}" >> "$orch_file"
    if (( idx < ${#stage_entries[@]} - 1 )); then
      printf ',\n' >> "$orch_file"
    else
      printf '\n' >> "$orch_file"
    fi
  done

  printf '  ]\n}\n' >> "$orch_file"
}
