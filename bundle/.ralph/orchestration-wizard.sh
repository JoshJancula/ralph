#!/usr/bin/env bash
set -euo pipefail

workspace="$(pwd)"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bundle_root="$(cd "$script_dir/.." && pwd)"
SCRIPT_DIR="$script_dir"
export SCRIPT_DIR

# shellcheck source=bash-lib/error-handling.sh
source "$bundle_root/.ralph/bash-lib/error-handling.sh"

_wizard_bash_lib="$script_dir/bash-lib/select-model"
if [[ -f "$_wizard_bash_lib/select-model-cursor.sh" ]]; then
  # shellcheck source=/dev/null
  source "$_wizard_bash_lib/select-model-cursor.sh"
fi
if [[ -f "$_wizard_bash_lib/select-model-claude.sh" ]]; then
  # shellcheck source=/dev/null
  source "$_wizard_bash_lib/select-model-claude.sh"
fi
if [[ -f "$_wizard_bash_lib/select-model-codex.sh" ]]; then
  # shellcheck source=/dev/null
  source "$_wizard_bash_lib/select-model-codex.sh"
fi
if [[ -f "$_wizard_bash_lib/select-model-opencode.sh" ]]; then
  # shellcheck source=/dev/null
  source "$_wizard_bash_lib/select-model-opencode.sh"
fi
if [[ -f "$_wizard_bash_lib/select-model-antigravity.sh" ]]; then
  # shellcheck source=/dev/null
  source "$_wizard_bash_lib/select-model-antigravity.sh"
fi
unset _wizard_bash_lib

# shellcheck source=bash-lib/ui-prompt.sh
source "$bundle_root/.ralph/bash-lib/ui-prompt.sh"
# shellcheck source=bash-lib/wizard/wizard-prompts.sh
source "$bundle_root/.ralph/bash-lib/wizard/wizard-prompts.sh"
# shellcheck source=bash-lib/wizard/wizard-templates.sh
source "$bundle_root/.ralph/bash-lib/wizard/wizard-templates.sh"
# shellcheck source=bash-lib/wizard/wizard-validation.sh
source "$bundle_root/.ralph/bash-lib/wizard/wizard-validation.sh"
# shellcheck source=bash-lib/wizard/wizard-pipeline-plan.sh
source "$bundle_root/.ralph/bash-lib/wizard/wizard-pipeline-plan.sh"

if [[ -z "${RALPH_SKIP_FZF_HINT:-}" ]] && ! command -v fzf >/dev/null 2>&1; then
  if [[ -t 2 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    echo -e "\033[2mtip: install fzf for arrow-key menus (brew install fzf / apt install fzf). set RALPH_SKIP_FZF_HINT=1 to silence.\033[0m" >&2
  else
    echo "tip: install fzf for arrow-key menus (brew install fzf / apt install fzf). set RALPH_SKIP_FZF_HINT=1 to silence." >&2
  fi
fi

print_step "1/5" "Plan metadata"
print_hint "- Pick a short name for this orchestration plan."
read_pipeline_info

plan_name="${namespace:-orchestration}"
plan_overview="${pipeline_description:-Multi-stage orchestration for $plan_name}"
if [[ -z "$pipeline_name" ]]; then
  pipeline_name="$plan_name"
fi

plans_dir="$workspace/.ralph-workspace/plans"
dest="$plans_dir/${plan_name}.plan.md"
if [[ -e "$dest" ]]; then
  ralph_die "plan already exists: $dest"
fi

instructions_line="instructions: Execute one TODO at a time."
template_path="$script_dir/plan-templates/pipeline-simple.plan.template.md"
if [[ -f "$template_path" ]]; then
  _il="$(awk '/^instructions:/{print; exit}' "$template_path")"
  [[ -n "$_il" ]] && instructions_line="$_il"
fi

print_step "2/5" "Stage list"
print_hint "- Preset names: research, architecture, implementation, code-review, qa, security."
print_hint "- Or custom ids (letters, digits, hyphens). Separate with commas or spaces."
read_stages

selected_stage_ids=()
for _s in "${selected_stages[@]}"; do
  _sid="$(ralph_internal_wizard_sanitize "$_s")"
  [[ -n "$_sid" ]] || ralph_die "Stage \"$_s\" sanitizes to empty"
  selected_stage_ids+=("$_sid")
done

if ((${#selected_stage_ids[@]} == 0)); then
  ralph_die "No stages configured"
fi

cp_stages=()
cp_stage_runtimes=()
cp_stage_agents=()
cp_stage_models=()
cp_stage_session=()
cp_stage_context=()
cp_stage_plan_files=()
cp_stage_inline_content=()
cp_stage_inline_verification=()
cp_artifact_entries=()
cp_parallel_waves=()
cp_loop_sources=()
cp_loop_targets=()
cp_loop_max_iters=()
cp_loop_check_paths=()

print_step "3/5" "Configure each stage"
print_hint "- For each stage: pick runtime, agent/model, then choose inline content or a separate plan file."

for stage_id in "${selected_stage_ids[@]}"; do
  cp_stages+=("$stage_id")
  print_info "Configuring stage \"$stage_id\""

  use_plan_file="$(ralph_menu_select --prompt "Stage \"$stage_id\": inline content or separate plan file?" --default 1 -- "inline" "plan file")"

  if [[ "$use_plan_file" == "plan file" ]]; then
    plan_file_default=".ralph-workspace/plans/${plan_name}-${stage_id}.plan.md"
    plan_file_path="$(ralph_prompt_text "Plan file path for \"$stage_id\"" "$plan_file_default")"
    [[ -n "$plan_file_path" ]] || ralph_die "plan file path required for stage \"$stage_id\""
    cp_stage_plan_files+=("$plan_file_path")
    cp_stage_inline_content+=("")
    cp_stage_inline_verification+=("")
    cp_stage_runtimes+=("")
    cp_stage_agents+=("")
    cp_stage_models+=("")

    create_stub="$(ralph_prompt_yesno "Create a stub plan file at $plan_file_path" "y")"
    if [[ "$create_stub" == "y" ]]; then
      stub_dir="$(dirname "$workspace/$plan_file_path")"
      mkdir -p "$stub_dir"
      stub_dest="$workspace/$plan_file_path"
      if [[ ! -e "$stub_dest" ]]; then
        stage_plan_name="$(basename "$plan_file_path" .plan.md)"
        printf '%s\n' \
          "---" \
          "name: ${stage_plan_name}" \
          "overview: Stage plan for ${stage_id} in ${plan_name}" \
          "execution: standard" \
          "instructions: Execute one TODO at a time." \
          "" \
          "todos:" \
          "  - id: ${stage_id}-task-1" \
          "    content: |" \
          "      Describe the task for this stage here." \
          "    verification: |" \
          "      Confirm the task is complete." \
          "    status: pending" \
          "isProject: false" \
          "---" \
          > "$stub_dest"
        print_info "Created stub plan: $plan_file_path"
      else
        print_info "Plan file already exists, skipping stub creation."
      fi
    fi
  else
    cp_stage_plan_files+=("")
    runtime="$(select_runtime "$stage_id")"
    agent_selection="$(select_agent "$runtime" "$stage_id")"
    IFS=$'\t' read -r agent agent_is_custom custom_model <<< "$agent_selection"
    if [[ "${agent_is_custom:-0}" == "1" ]]; then
      stage_model="$custom_model"
      [[ -n "$stage_model" ]] || ralph_die "Model is required for custom $runtime stage \"$stage_id\"."
      cp_stage_agents+=("")
      cp_stage_models+=("$stage_model")
    else
      model_default="$(agent_model_default "$runtime" "$agent" | tr -d '\n')"
      stage_model="$(select_model_override "$runtime" "$agent" "$model_default")"
      cp_stage_agents+=("$agent")
      cp_stage_models+=("$stage_model")
    fi
    cp_stage_runtimes+=("$runtime")

    inline_content="$(ralph_prompt_text "Content/instructions for \"$stage_id\" todo (optional)" "")"
    inline_verification="$(ralph_prompt_text "Verification steps for \"$stage_id\" todo (optional)" "")"
    cp_stage_inline_content+=("$inline_content")
    cp_stage_inline_verification+=("$inline_verification")
  fi

  if [[ "${pipeline_session_strategy_all_stages:-true}" == "true" ]]; then
    session="${pipeline_session_strategy_default:-fresh}"
  else
    session="$(select_session_strategy "$stage_id" "${pipeline_session_strategy_default:-fresh}")"
  fi
  context="$(select_context_budget "$stage_id")"
  cp_stage_session+=("$session")
  cp_stage_context+=("$context")
done

print_step "4/5" "Artifacts, parallel stages, and loop rules (optional)"

for stage_id in "${cp_stages[@]}"; do
  _plan_file_idx=0
  for _ci in "${!cp_stages[@]}"; do
    [[ "${cp_stages[$_ci]}" == "$stage_id" ]] && { _plan_file_idx=$_ci; break; }
  done
  if [[ -n "${cp_stage_plan_files[$_plan_file_idx]:-}" ]]; then
    continue
  fi
  artifact_default=".ralph-workspace/artifacts/{{ARTIFACT_NS}}/$(artifact_file_for_stage "$stage_id")"
  produces_input="$(ralph_prompt_text "Output artifact path for \"$stage_id\" (optional)" "")"
  if [[ -n "$produces_input" ]]; then
    wizard_create_plan_append_artifact "$stage_id" "$produces_input" "true" "produces"
  fi
  requires_input="$(ralph_prompt_text "Required input artifact for \"$stage_id\" (optional)" "")"
  if [[ -n "$requires_input" ]]; then
    wizard_create_plan_append_artifact "$stage_id" "$requires_input" "true" "requires"
  fi
done

stage_ids=("${cp_stages[@]}")
configure_parallel_stages
cp_parallel_waves=("${parallel_stage_waves[@]}")

configure_loop_rules
for loop_idx in "${!loop_sources[@]}"; do
  loop_source="${loop_sources[$loop_idx]}"
  loop_target="${loop_targets[$loop_idx]}"
  loop_max="${loop_max_iterations[$loop_idx]}"
  artifact_default=".ralph-workspace/artifacts/{{ARTIFACT_NS}}/${loop_source}-loop-check.md"
  wizard_create_plan_set_loop "$loop_source" "$loop_target" "$loop_max" \
    "$(ralph_prompt_text "Loop check artifact path for \"$loop_source\"" "$artifact_default")"
  wizard_create_plan_append_artifact "$loop_source" "$(wizard_create_plan_loop_check "$loop_source")" "true" "produces"
done

print_step "5/5" "Generate plan"
echo ""
echo "Plan: $dest"
echo "Stages: ${cp_stages[*]}"
echo ""

confirm_write="$(ralph_prompt_yesno "Write this plan" "y")"
if [[ "$confirm_write" == "n" ]]; then
  echo "aborted; no files created"
  exit 0
fi

mkdir -p "$plans_dir"

tmp_dest="$(mktemp "${TMPDIR:-/tmp}/ralph-orc-wizard.XXXXXX")"
trap 'rm -f "$tmp_dest"' EXIT

wizard_render_pipeline_orchestration_plan "$plan_name" "$plan_overview" "$instructions_line" > "$tmp_dest"

mv "$tmp_dest" "$dest"
trap - EXIT

echo "Created orchestration plan: .ralph-workspace/plans/${plan_name}.plan.md"
echo ""
echo "Run with:"
echo "  ralph run --plan $dest"
