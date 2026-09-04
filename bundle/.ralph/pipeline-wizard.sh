#!/usr/bin/env bash
# Shared interactive wizard engine for workflow authoring (sequential and
# dependency modes). `ralph create workflow` execs into this; workflow-wizard.sh
# forwards to it. Without --mode the shared mode prompt asks first.
# share the bulk of this flow (plan metadata, node/stage configuration,
# artifacts) because a graph node is a pipeline stage plus a small number of
# extra fields (type, dependsOn, voters, workspaceMode) -- see
# docs/GRAPH.md#graph-vs-orchestration.
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
# shellcheck source=bash-lib/wizard/wizard-workflow-template.sh
source "$bundle_root/.ralph/bash-lib/wizard/wizard-workflow-template.sh"
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

mode=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      [[ -n "${2:-}" ]] || ralph_die "--mode requires a value (orchestration, graph, workflow, sequential, or dependency)"
      mode="$2"
      shift 2
      ;;
    --mode=*)
      mode="${1#--mode=}"
      shift
      ;;
    -h|--help)
      cat <<'EOF'
Usage: pipeline-wizard.sh [--mode orchestration|graph|workflow|sequential|dependency]

Interactive wizard shared by legacy orchestration/graph shims and
`ralph create workflow` (public modes sequential|dependency; default Sequential).
EOF
      exit 0
      ;;
    *)
      ralph_die "unknown option: $1"
      ;;
  esac
done

if [[ -n "$mode" && "$mode" != "orchestration" && "$mode" != "graph" && "$mode" != "workflow" \
  && "$mode" != "sequential" && "$mode" != "dependency" ]]; then
  ralph_die "--mode must be orchestration, graph, workflow, sequential, or dependency, got: $mode"
fi

wizard_output_format="plan"
wizard_workflow_engine=""
workflow_name=""
wizard_workflow_metadata_done=""
wizard_public_mode=""

# Public workflow authoring: Sequential (default) or Dependency.
# `ralph create workflow` exports RALPH_CREATE_WORKFLOW_MODE and execs with
# --mode workflow; --mode sequential|dependency are also accepted directly.
if [[ "$mode" == "workflow" || "$mode" == "sequential" || "$mode" == "dependency" ]]; then
  if [[ "$mode" == "sequential" || "$mode" == "dependency" ]]; then
    wizard_public_mode="$mode"
  else
    wizard_public_mode="$(wizard_sequential_resolve_public_mode "${RALPH_CREATE_WORKFLOW_MODE:-}")" \
      || ralph_die "invalid RALPH_CREATE_WORKFLOW_MODE: ${RALPH_CREATE_WORKFLOW_MODE}"
  fi

  if [[ "$wizard_public_mode" == "sequential" ]]; then
    wizard_output_format="workflow"
    wizard_sequential_run_interactive
    exit $?
  fi

  if [[ "$wizard_public_mode" == "dependency" ]]; then
    wizard_output_format="workflow"
    wizard_dependency_run_interactive
    exit $?
  fi

  ralph_die "unsupported public workflow mode: ${wizard_public_mode}"
fi

if [[ -z "$mode" ]]; then
  print_step "-" "Which kind of plan?"
  cat >&2 <<'EOF'
Both run several agents over one piece of work. The difference is how the
run order is decided.

Orchestration -- you write the order.
  Stages run one after another, in the order you list them, with optional
  parallel waves you declare by hand. Easy to follow. Pick this unless you
  need something below.

Graph -- the order is derived from dependencies.
  Each node declares what it depends on, and Ralph starts a node the moment
  its dependencies are done. Choose graph when you want:
    - branching: run one path or another based on a decision (router)
    - voting: several models judge the same result (consensus)
    - human sign-off mid-run that only pauses one branch (checkpoint)
    - real command checks with no model involved (gate)
    - parallel edits kept in isolated workspaces, then merged (integrate)

Still unsure? Start with orchestration. Converting to a graph later is
mostly a matter of adding dependsOn to the stages you already wrote.

EOF
  mode="$(ralph_menu_select --prompt "Which do you want to build?" --default 1 \
    --desc "Stages in the order you list them. Simpler; the right default." \
    --desc "Dependency-driven DAG. Adds branching, voting, gates, isolation." \
    -- "orchestration" "graph")"
fi

# Graph authoring lives in wizard_graph_run_interactive, which drives every
# prompt from schemas/graph-authoring-contract.json. It supports all seven node
# types (this file's own loop below only ever handled four) and carries the
# operator help text, so graph mode delegates wholesale rather than keeping a
# second, weaker copy of the flow.
if [[ "$mode" == "graph" ]]; then
  wizard_graph_run_interactive
  exit 0
fi

total_steps=6

print_step "1/$total_steps" "Plan metadata"
print_hint "- Pick a short name for this ${mode} plan."
if [[ "${wizard_workflow_metadata_done:-}" == "1" ]]; then
  plan_name="$workflow_name"
  plan_overview="${pipeline_description:-Reusable ${mode} workflow for $plan_name}"
  if [[ -z "$pipeline_name" ]]; then
    pipeline_name="$plan_name"
  fi
  namespace="$workflow_name"
else
  read_pipeline_info

  plan_name="${namespace:-$mode}"
  plan_overview="${pipeline_description:-Multi-stage ${mode} plan for $plan_name}"
  if [[ -z "$pipeline_name" ]]; then
    pipeline_name="$plan_name"
  fi
fi

if [[ "${wizard_output_format:-plan}" == "workflow" ]]; then
  plans_dir="$workspace/.ralph-workspace/workflows"
  dest="$plans_dir/${plan_name}.workflow.md"
else
  plans_dir="$workspace/.ralph-workspace/plans"
  dest="$plans_dir/${plan_name}.plan.md"
fi
if [[ -e "$dest" ]]; then
  if [[ "${wizard_output_format:-plan}" == "workflow" ]]; then
    ralph_die "workflow already exists: $dest"
  else
    ralph_die "plan already exists: $dest"
  fi
fi

instructions_line="instructions: Execute one TODO at a time."
template_path="$script_dir/plan-templates/pipeline-simple.plan.template.md"
if [[ -f "$template_path" ]]; then
  _il="$(awk '/^instructions:/{print; exit}' "$template_path")"
  [[ -n "$_il" ]] && instructions_line="$_il"
fi

# Graph-only pipeline fields; orchestration renders without them.
max_parallel=""
edge_derivation=""
failure_policy=""

print_step "2/$total_steps" "Stage list"
print_hint "- Preset names: research, architecture, implementation, code-review, qa, security."
print_hint "- Or custom ids (letters, digits, hyphens). Separate with commas or spaces."
read_stages

selected_stage_ids=()
for _s in ${selected_stages[@]+"${selected_stages[@]}"}; do
  _sid="$(ralph_internal_wizard_sanitize "$_s")"
  [[ -n "$_sid" ]] || ralph_die "Stage \"$_s\" sanitizes to empty"
  selected_stage_ids+=("$_sid")
done

if ((${#selected_stage_ids[@]} == 0)); then
  ralph_die "No stages configured"
fi

cp_stages=()
cp_stage_types=()
cp_stage_runtimes=()
cp_stage_roles=()
cp_stage_models=()
cp_stage_native_subagents=()
cp_stage_session=()
cp_stage_context=()
cp_stage_plan_files=()
cp_stage_inline_content=()
cp_stage_inline_verification=()
cp_stage_depends_on=()
cp_stage_policy=()
cp_stage_quorum=()
cp_stage_workspace_mode=()
cp_artifact_entries=()
cp_parallel_waves=()
cp_loop_sources=()
cp_loop_targets=()
cp_loop_max_iters=()
cp_loop_check_paths=()
cp_voter_node=()
cp_voter_id=()
cp_voter_runtime=()
cp_voter_model=()

for stage_id in "${selected_stage_ids[@]}"; do
  cp_stages+=("$stage_id")
  cp_stage_types+=("agent")
done

print_step "3/$total_steps" "Tooling profiles"
print_hint "- Controls how tool output is exposed to each stage's agent."
cp_tooling_default_profile=""
cp_tooling_overrides=()
wizard_prompt_tooling_policy "${selected_stage_ids[@]}"
cp_tooling_default_profile="${wizard_tooling_default_profile:-}"
cp_tooling_overrides=(${wizard_tooling_overrides[@]+"${wizard_tooling_overrides[@]}"})

if [[ -n "${wizard_workflow_template_source:-}" ]]; then
  print_step "4/$total_steps" "Dependencies"
  print_hint "- Accept the template defaults or edit the dependency list per stage."
  wizard_workflow_template_configure_dependencies
else
print_step "4/$total_steps" "Configure each stage"
if [[ "${wizard_output_format:-plan}" == "workflow" ]]; then
  print_hint "- For each stage: choose the runtime, optional SDLC role, and native subagent policy separately."
else
  print_hint "- For each stage: choose runtime, optional SDLC role, and native subagent policy separately."
fi

for idx in "${!cp_stages[@]}"; do
  stage_id="${cp_stages[$idx]}"
  stage_type="${cp_stage_types[$idx]}"
  print_info "Configuring stage \"$stage_id\""

  runtime=""
  agent=""
  role=""
  model=""
  native_subagents=""
  plan_file=""
  inline_content=""
  inline_verification=""
  depends_on=""
  policy=""
  quorum=""
  workspace_mode=""

  # Orchestration stages are always agent stages; the non-agent node types are
  # graph-only and handled by wizard_graph_authoring_configure_nodes.
  {
    use_plan_file="$(ralph_menu_select --prompt "Stage \"$stage_id\": inline content or separate plan file?" --default 1 -- "inline" "plan file")"

    if [[ "$use_plan_file" == "plan file" ]]; then
      plan_file_default=".ralph-workspace/plans/${plan_name}-${stage_id}.plan.md"
      plan_file="$(ralph_prompt_text "Plan file path for \"$stage_id\"" "$plan_file_default")"
      [[ -n "$plan_file" ]] || ralph_die "plan file path required for stage \"$stage_id\""

      create_stub="$(ralph_prompt_yesno "Create a stub plan file at $plan_file" "y")"
      if [[ "$create_stub" == "y" ]]; then
        stub_dir="$(dirname "$workspace/$plan_file")"
        mkdir -p "$stub_dir"
        stub_dest="$workspace/$plan_file"
        if [[ ! -e "$stub_dest" ]]; then
          stage_plan_name="$(basename "$plan_file" .plan.md)"
          printf '%s\n' \
            "---" \
            "name: ${stage_plan_name}" \
            "overview: Stage plan for ${stage_id} in ${plan_name}" \
            "mode: standard" \
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
          print_info "Created stub plan: $plan_file"
        else
          print_info "Plan file already exists, skipping stub creation."
        fi
      fi
    else
      runtime="$(select_runtime "$stage_id")"
      if [[ "${wizard_output_format:-plan}" == "workflow" ]]; then
        role="$(select_role "$stage_id")"
        native_subagents="$(select_native_subagents "$stage_id")"
        print_hint "Stage $stage_id runtime: $runtime"
        print_hint "Stage $stage_id role: ${role:-none}"
        print_hint "Stage $stage_id model source: runtime saved/default"
        print_hint "Stage $stage_id native subagents: $native_subagents"
      else
        role="$(select_role "$stage_id")"
        native_subagents="$(select_native_subagents "$stage_id")"
        wizard_print_runtime_role_model_subagents "Stage $stage_id" "$runtime" "$role" "$native_subagents"
      fi

      inline_content="$(ralph_prompt_text "Content/instructions for \"$stage_id\" todo (optional)" "")"
      inline_verification="$(ralph_prompt_text "Verification steps for \"$stage_id\" todo (optional)" "")"
    fi
  }

  if [[ "${pipeline_session_strategy_all_stages:-true}" == "true" ]]; then
    session="${pipeline_session_strategy_default:-fresh}"
  else
    session="$(select_session_strategy "$stage_id" "${pipeline_session_strategy_default:-fresh}")"
  fi
  context="$(select_context_budget "$stage_id")"

  cp_stage_runtimes+=("$runtime")
  cp_stage_roles+=("$role")
  cp_stage_models+=("$model")
  cp_stage_native_subagents+=("$native_subagents")
  cp_stage_session+=("$session")
  cp_stage_context+=("$context")
  cp_stage_plan_files+=("$plan_file")
  cp_stage_inline_content+=("$inline_content")
  cp_stage_inline_verification+=("$inline_verification")
  cp_stage_depends_on+=("$depends_on")
  cp_stage_policy+=("$policy")
  cp_stage_quorum+=("$quorum")
  cp_stage_workspace_mode+=("$workspace_mode")

  if [[ -z "$plan_file" ]]; then
    produces_input="$(ralph_prompt_text "Output artifact path for \"$stage_id\" (optional)" "")"
    if [[ -n "$produces_input" ]]; then
      wizard_create_plan_append_artifact "$stage_id" "$produces_input" "true" "produces"
    fi
    requires_input="$(ralph_prompt_text "Required input artifact for \"$stage_id\" (optional)" "")"
    if [[ -n "$requires_input" ]]; then
      wizard_create_plan_append_artifact "$stage_id" "$requires_input" "true" "requires"
    fi
  fi
done
fi

if [[ -z "${wizard_workflow_template_source:-}" ]]; then
print_step "5/$total_steps" "Parallel stages and loop rules (optional)"
stage_ids=("${cp_stages[@]}")
configure_parallel_stages
cp_parallel_waves=(${parallel_stage_waves[@]+"${parallel_stage_waves[@]}"})

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
fi

print_step "$total_steps/$total_steps" "Generate plan"
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

tmp_dest="$(mktemp "${TMPDIR:-/tmp}/ralph-pipeline-wizard.XXXXXX")"
trap 'rm -f "$tmp_dest"' EXIT

if [[ -n "${wizard_workflow_template_source:-}" && "${wizard_output_format:-plan}" == "workflow" ]]; then
  wizard_workflow_template_write_dest "$tmp_dest" "$plan_name" "$plan_overview"
else
  wizard_render_pipeline_plan "$mode" "$plan_name" "$plan_overview" "$instructions_line" \
    "$max_parallel" "$edge_derivation" "$failure_policy" > "$tmp_dest"
fi

mv "$tmp_dest" "$dest"
trap - EXIT

if [[ "${wizard_output_format:-plan}" == "workflow" ]]; then
  # shellcheck source=bash-lib/plan-todo.sh
  source "$script_dir/bash-lib/plan-todo.sh"
  plan_workflow_validate "$dest" || ralph_die "workflow validation failed: $dest"
  echo "Created workflow: .ralph-workspace/workflows/${plan_name}.workflow.md"
  echo ""
  echo "Start with:"
  echo "  ralph workflow start ${plan_name} --task \"<work request>\""
else
  echo "Created ${mode} plan: .ralph-workspace/plans/${plan_name}.plan.md"
  echo ""
  echo "Run with:"
  echo "  ralph run --plan $dest"
fi
