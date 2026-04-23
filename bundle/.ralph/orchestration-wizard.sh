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

# shellcheck source=/Users/joshuajancula/Documents/projects/ralph/bundle/.ralph/bash-lib/ui-prompt.sh
source "$bundle_root/.ralph/bash-lib/ui-prompt.sh"

# shellcheck source=/Users/joshuajancula/Documents/projects/ralph/bundle/.ralph/bash-lib/wizard-prompts.sh
source "$bundle_root/.ralph/bash-lib/wizard-prompts.sh"

# shellcheck source=/Users/joshuajancula/Documents/projects/ralph/bundle/.ralph/bash-lib/wizard-templates.sh
source "$bundle_root/.ralph/bash-lib/wizard-templates.sh"

# shellcheck source=/Users/joshuajancula/Documents/projects/ralph/bundle/.ralph/bash-lib/wizard-validation.sh
source "$bundle_root/.ralph/bash-lib/wizard-validation.sh"

# Print fzf hint at startup if fzf is not installed
if [[ -z "${RALPH_SKIP_FZF_HINT:-}" ]] && ! command -v fzf >/dev/null 2>&1; then
  if [[ -t 2 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    echo -e "\033[2mtip: install fzf for arrow-key menus (brew install fzf / apt install fzf). set RALPH_SKIP_FZF_HINT=1 to silence.\033[0m" >&2
  else
    echo "tip: install fzf for arrow-key menus (brew install fzf / apt install fzf). set RALPH_SKIP_FZF_HINT=1 to silence." >&2
  fi
fi

echo "Note: this wizard copies .ralph/plan.template and scaffolds .ralph-workspace/orchestration-plans/<namespace> plus artifacts."

print_step "1/7" "Pipeline metadata"
print_hint "- Pick a short name we can use in file paths."
read_pipeline_info

print_step "2/7" "Stage list"
print_hint "- List stages with commas or spaces: preset names (research, architecture, ...), 1-based indexes (1,2,3), or custom ids (letters, digits, hyphens; example: r1,plan-a)."
print_hint "- Press Enter for the default stage list."
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
stage_session_strategy=()
stage_context_budgets=()
stage_input_sources=()
stage_handoff_targets=()
stage_handoff_kinds=()

print_step "3/7" "Configure each stage"
print_hint "- For each stage, pick where it runs and which helper agent to use."
print_hint "- Pick 'custom' if you want to choose a model yourself."
for stage in "${stages[@]}"; do
  stage_id="$(ralph_internal_wizard_sanitize "$stage")"
  [[ -n "$stage_id" ]] || ralph_die "Stage \"$stage\" sanitizes to empty; skip"
  print_info "Configuring stage \"$stage_id\""
  runtime="$(select_runtime "$stage_id")"
  agent_selection="$(select_agent "$runtime" "$stage_id")"
  IFS=$'\t' read -r agent agent_is_custom custom_model_from_picker <<< "$agent_selection"
  stage_desc="$(ralph_prompt_text "Describe \"$stage_id\" stage (optional)" "")"
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
  if [[ "$pipeline_session_strategy_all_stages" == "true" ]]; then
    stage_session_strategy+=("$pipeline_session_strategy_default")
  else
    _stage_strategy_default_index=1
    case "${pipeline_session_strategy_default:-fresh}" in
      resume) _stage_strategy_default_index=2 ;;
      reset) _stage_strategy_default_index=3 ;;
    esac
    if [[ "$runtime" == "claude" ]]; then
      print_hint "Claude often benefits from resume/reset because prompt-cache reuse is stronger."
    fi
    _stage_strategy="$(ralph_menu_select --prompt "Session strategy for \"$stage_id\"" --default "$_stage_strategy_default_index" -- "fresh" "resume" "reset")"
    stage_session_strategy+=("${_stage_strategy:-fresh}")
  fi
  cb_input="$(ralph_menu_select --prompt "Context budget for \"$stage_id\"" --default 2 -- "full" "standard" "lean")"
  stage_context_budgets+=("$cb_input")
done

orch_session_resume_enabled="true"
for ss in "${stage_session_strategy[@]}"; do
  [[ "$ss" == "resume" ]] || orch_session_resume_enabled="false"
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

configure_parallel_stages

configure_stage_input_dependencies

configure_loop_rules

configure_handoff_declarations

print_step "7/7" "Generate orchestration files"
plan_dir="$workspace/.ralph-workspace/orchestration-plans/$namespace"
artifact_dir="$workspace/.ralph-workspace/artifacts/$namespace"
orch_file="$plan_dir/$namespace.orch.json"

# Build stage entries (without creating files yet)
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
  stage_session_strategy_value="${stage_session_strategy[$idx]}"
  stage_input_list="${stage_input_sources[$idx]}"

  # Only build the entry, don't write files yet
  stage_entries+=("$(
    wizard_build_stage_entry \
      "$namespace" "$stage_label" "$runtime" "$agent" "$agent_source" "$plan_rel_path" "$artifact_path" \
      "$stage_desc" "$stage_model" "$stage_session_strategy_value" "$stage_input_list" \
      "${stage_context_budgets[$idx]:-}"
  )")
done

# Render summary for user confirmation
wizard_render_summary \
  "$pipeline_name" "$namespace" "$description" "$orch_session_resume_enabled" \
  "${stage_entries[@]}"

# Ask for confirmation
confirm_write="$(ralph_prompt_yesno "Write these files" "y")"
if [[ "$confirm_write" == "n" ]]; then
  echo "aborted; no files created"
  exit 0
fi

# Create directories and write files after confirmation
mkdir -p "$plan_dir" "$artifact_dir"

# Write stage plan files
for idx in "${!stages[@]}"; do
  step_number=$(printf "%02d" $((idx + 1)))
  stage_label="$(ralph_internal_wizard_sanitize "${stages[$idx]}")"
  runtime="${stage_runtimes[$idx]}"
  agent="${stage_agents[$idx]}"

  plan_rel_path="${generated_plan_paths[$idx]}"
  plan_abs_path="$workspace/$plan_rel_path"
  stage_desc="${stage_descriptions[$idx]}"
  stage_model="${stage_models[$idx]}"
  stage_input_list="${stage_input_sources[$idx]}"

  wizard_render_plan_template \
    "$plan_template" "$plan_abs_path" "$plan_rel_path" "$namespace" "$stage_label" "$pipeline_name" "$runtime" "$agent" \
    "$stage_desc" "$stage_input_list" "$stage_model"
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
