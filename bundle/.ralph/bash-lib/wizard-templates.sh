#!/usr/bin/env bash
# Template and artifact generation helpers for the orchestration wizard.

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
#       8 stage_desc, 9 stage_model, 10 session_resume, 11 stage_input_list
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
  local session_resume="${10:-false}"
  local stage_input_list="${11:-}"

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

  name_json="$(escape_json "$pipeline_name")"
  namespace_json="$(escape_json "$namespace")"
  description_json="$(escape_json "$description")"
  printf '{\n  "name": %s,\n  "namespace": %s,\n  "description": %s,\n  "sessionResumeEnabled": %s,\n  "stages": [\n' \
    "$name_json" "$namespace_json" "$description_json" "$session_resume_enabled" > "$orch_file"

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
