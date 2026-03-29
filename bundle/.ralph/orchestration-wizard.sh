#!/usr/bin/env bash
set -euo pipefail

workspace="$(pwd)"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bundle_root="$(cd "$script_dir/.." && pwd)"
plan_template="$script_dir/plan.template"
# shellcheck source=/Users/joshuajancula/Documents/projects/ralph/bundle/.ralph/bash-lib/error-handling.sh
source "$bundle_root/.ralph/bash-lib/error-handling.sh"

if [[ ! -f "$plan_template" ]]; then
  ralph_die "plan template not found at $plan_template"
fi

if [[ -f "$bundle_root/.cursor/ralph/select-model.sh" ]]; then
  # shellcheck source=/dev/null
  source "$bundle_root/.cursor/ralph/select-model.sh"
fi
if [[ -f "$bundle_root/.claude/ralph/select-model.sh" ]]; then
  # shellcheck source=/dev/null
  source "$bundle_root/.claude/ralph/select-model.sh"
fi
if [[ -f "$bundle_root/.codex/ralph/select-model.sh" ]]; then
  # shellcheck source=/dev/null
  source "$bundle_root/.codex/ralph/select-model.sh"
fi
if [[ -f "$bundle_root/.opencode/ralph/select-model.sh" ]]; then
  # shellcheck source=/dev/null
  source "$bundle_root/.opencode/ralph/select-model.sh"
fi

# shellcheck source=/Users/joshuajancula/Documents/projects/ralph/bundle/.ralph/bash-lib/wizard-prompts.sh
source "$bundle_root/.ralph/bash-lib/wizard-prompts.sh"

# shellcheck source=/Users/joshuajancula/Documents/projects/ralph/bundle/.ralph/bash-lib/wizard-templates.sh
source "$bundle_root/.ralph/bash-lib/wizard-templates.sh"

# shellcheck source=/Users/joshuajancula/Documents/projects/ralph/bundle/.ralph/bash-lib/wizard-validation.sh
source "$bundle_root/.ralph/bash-lib/wizard-validation.sh"

echo "Note: this wizard copies .ralph/plan.template and scaffolds .ralph-workspace/orchestration-plans/<namespace> plus artifacts."

print_step "1/6" "Pipeline metadata"
print_hint "- Pick a short name we can use in file paths."
read_pipeline_info

print_step "2/6" "Stage list"
print_hint "- Type stage names with commas, like: plan,test,qa"
print_hint "- Press Enter if you want the default stage list."
read_stages
stages=()
if [[ ${#selected_stages[@]} -gt 0 ]]; then
  stages=("${selected_stages[@]}")
fi

if [[ ${#stages[@]} -eq 0 ]]; then
  ralph_die "No stages configured"
fi

stage_runtimes=()
stage_agents=()
stage_agent_sources=()
stage_descriptions=()
stage_models=()
stage_session_resume=()
stage_input_sources=()

print_step "3/6" "Configure each stage"
print_hint "- For each stage, pick where it runs and which helper agent to use."
print_hint "- Pick 'custom' if you want to choose a model yourself."
for stage in "${stages[@]}"; do
  stage_id="$(ralph_internal_wizard_sanitize "$stage")"
  [[ -n "$stage_id" ]] || ralph_die "Stage \"$stage\" sanitizes to empty; skip"
  print_info "Configuring stage \"$stage_id\""
  runtime="$(select_runtime "$stage_id")"
  agent_selection="$(select_agent "$runtime" "$stage_id")"
  IFS=$'\t' read -r agent agent_is_custom custom_model_from_picker <<< "$agent_selection"
  read -rp "Describe \"$stage_id\" stage (optional): " stage_desc
  if [[ "${agent_is_custom:-0}" == "1" ]]; then
    stage_agent_source="custom"
    stage_model="$custom_model_from_picker"
  else
    stage_agent_source="prebuilt"
    model_default="$(agent_model_default "$runtime" "$agent" | tr -d '\n')"
    stage_model="$(select_model_override "$runtime" "$agent" "$model_default")"
  fi
  stage_runtimes+=("$runtime")
  stage_agents+=("$agent")
  stage_agent_sources+=("$stage_agent_source")
  stage_descriptions+=("$stage_desc")
  stage_models+=("$stage_model")
  if [[ "$pipeline_resume_all_stages" == "true" ]]; then
    stage_session_resume+=("true")
  else
    read -rp "Enable session resume for \"$stage_id\"? (y/N) " sr_one_stage
    sr_one_stage="${sr_one_stage:-N}"
    if [[ "$sr_one_stage" =~ ^[Yy] ]]; then
      stage_session_resume+=("true")
    else
      stage_session_resume+=("false")
    fi
  fi
done

orch_session_resume_enabled="true"
for sr in "${stage_session_resume[@]}"; do
  [[ "$sr" == "true" ]] || orch_session_resume_enabled="false"
done

description="${pipeline_description:-Multi-stage pipeline for $pipeline_name}"
if [[ -z "$pipeline_name" ]]; then
  pipeline_name="$namespace"
fi
if [[ -z "$namespace" ]]; then
  namespace="$(ralph_internal_wizard_sanitize "$pipeline_name")"
fi

stage_ids=()
for stage in "${stages[@]}"; do
  stage_ids+=("$(ralph_internal_wizard_sanitize "$stage")")
done

configure_stage_input_dependencies

configure_loop_rules

print_step "6/6" "Generate orchestration files"
plan_dir="$workspace/.ralph-workspace/orchestration-plans/$namespace"
artifact_dir="$workspace/.ralph-workspace/artifacts/$namespace"
orch_file="$plan_dir/$namespace.orch.json"

mkdir -p "$plan_dir" "$artifact_dir"

  stage_entries=()
  generated_plan_paths=()
  total_steps=${#stages[@]}

  for idx in "${!stages[@]}"; do
    step_number=$(printf "%02d" $((idx + 1)))
    stage_label="$(ralph_internal_wizard_sanitize "${stages[$idx]}")"
    runtime="${stage_runtimes[$idx]}"
    agent="${stage_agents[$idx]}"
    agent_source="${stage_agent_sources[$idx]}"

    plan_rel_path=".ralph-workspace/orchestration-plans/$namespace/${namespace}-${step_number}-${stage_label}.plan.md"
    plan_abs_path="$workspace/$plan_rel_path"
    generated_plan_paths+=("$plan_rel_path")
    artifact_base="$(artifact_file_for_stage "$stage_label")"
    artifact_path=".ralph-workspace/artifacts/$namespace/$artifact_base"

    stage_desc="${stage_descriptions[$idx]}"
    stage_model="${stage_models[$idx]}"
    stage_resume_json="${stage_session_resume[$idx]}"
    stage_input_list="${stage_input_sources[$idx]}"

    wizard_render_plan_template \
      "$plan_template" "$plan_abs_path" "$plan_rel_path" "$namespace" "$stage_label" "$pipeline_name" "$runtime" "$agent" \
      "$stage_desc" "$stage_input_list" "$stage_model"

    stage_entries+=("$(
      wizard_build_stage_entry \
        "$namespace" "$stage_label" "$runtime" "$agent" "$agent_source" "$plan_rel_path" "$artifact_path" \
        "$stage_desc" "$stage_model" "$stage_resume_json" "$stage_input_list"
    )")
  done

wizard_write_orchestration_file \
  "$orch_file" "$pipeline_name" "$namespace" "$description" "$orch_session_resume_enabled" \
  "${stage_entries[@]}"

print_info "Created orchestration $orch_file with ${total_steps} stage(s)."
echo "Edit the plans under $plan_dir, add TODOs, and run:"
echo ".ralph/orchestrator.sh --orchestration $orch_file"
echo ""
print_hint "Generated prompt for creating TODOs in stage plans:"
echo "-----"
echo "Create actionable TODO checklists for this orchestration pipeline using .ralph/plan.template as the checklist style reference."
echo ""
echo "Namespace: $namespace"
echo "Orchestration JSON: $orch_file"
echo "Artifact directory: .ralph-workspace/artifacts/$namespace/"
echo ""
echo "Fill these stage plan files with concrete TODOs (- [ ] / - [x]), files to edit, validation commands, and expected artifacts:"
for p in "${generated_plan_paths[@]}"; do
  echo "- $p"
done
echo ""
echo "Each stage plan should include:"
echo "- Implementation steps tied to real files or modules"
echo "- Verification commands (lint/tests/build as applicable)"
echo "- Clear handoff expectations for the next stage"
echo "- Artifact expectations under .ralph-workspace/artifacts/$namespace/"
echo "-----"
offer_prompt_execution
