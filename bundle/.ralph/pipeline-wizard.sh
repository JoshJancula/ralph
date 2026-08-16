#!/usr/bin/env bash
# Shared interactive wizard engine for orchestration and graph plans.
# `ralph create orc` / `ralph create graph` exec into this with --mode
# pre-set; `ralph create wizard` omits --mode and asks first. The two modes
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
      [[ -n "${2:-}" ]] || ralph_die "--mode requires a value (orchestration or graph)"
      mode="$2"
      shift 2
      ;;
    --mode=*)
      mode="${1#--mode=}"
      shift
      ;;
    -h|--help)
      cat <<'EOF'
Usage: pipeline-wizard.sh [--mode orchestration|graph]

Interactive wizard shared by `ralph create orc` (--mode orchestration),
`ralph create graph` (--mode graph), and `ralph create wizard` (no --mode --
asks which one you want first).
EOF
      exit 0
      ;;
    *)
      ralph_die "unknown option: $1"
      ;;
  esac
done

if [[ -n "$mode" && "$mode" != "orchestration" && "$mode" != "graph" ]]; then
  ralph_die "--mode must be orchestration or graph, got: $mode"
fi

if [[ -z "$mode" ]]; then
  print_step "-" "Which kind of plan?"
  cat >&2 <<'EOF'
Orchestration: stages run in order (or parallel waves you declare). Best
default -- pick this unless you specifically need one of the graph
capabilities below.

Graph: stages form a dependency graph (dependsOn) instead of a fixed order,
and adds:
  - cross-provider consensus (multiple runtimes vote on one result)
  - checkpoint nodes (pause for human ack without blocking unrelated branches)
  - isolated workspace mutation (snapshot/worktree) for safer parallel writes

EOF
  mode="$(ralph_menu_select --prompt "Which do you want to build?" --default 1 -- "orchestration" "graph")"
fi

if [[ "$mode" == "graph" ]]; then
  total_steps=4
  noun="node"
else
  total_steps=5
  noun="stage"
fi

print_step "1/$total_steps" "Plan metadata"
print_hint "- Pick a short name for this ${mode} plan."
read_pipeline_info

plan_name="${namespace:-$mode}"
plan_overview="${pipeline_description:-Multi-stage ${mode} plan for $plan_name}"
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

max_parallel=""
edge_derivation=""
failure_policy=""
if [[ "$mode" == "graph" ]]; then
  max_parallel="$(ralph_prompt_text "Max parallel nodes" "3")"
  edge_derivation="$(ralph_menu_select --prompt "Edge derivation" --default 3 -- "declared" "artifacts" "both")"
  failure_policy="$(ralph_menu_select --prompt "Failure policy" --default 1 -- "drain" "cancel")"
fi

print_step "2/$total_steps" "${noun^} list"
if [[ "$mode" == "graph" ]]; then
  print_hint "- Node ids: letters, digits, hyphens. Separate with commas or spaces."
  read_graph_nodes
else
  print_hint "- Preset names: research, architecture, implementation, code-review, qa, security."
  print_hint "- Or custom ids (letters, digits, hyphens). Separate with commas or spaces."
  read_stages
fi

selected_stage_ids=()
for _s in "${selected_stages[@]}"; do
  _sid="$(ralph_internal_wizard_sanitize "$_s")"
  [[ -n "$_sid" ]] || ralph_die "${noun^} \"$_s\" sanitizes to empty"
  selected_stage_ids+=("$_sid")
done

if ((${#selected_stage_ids[@]} == 0)); then
  ralph_die "No ${noun}s configured"
fi

cp_stages=()
cp_stage_types=()
cp_stage_runtimes=()
cp_stage_agents=()
cp_stage_models=()
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
cp_voter_agent=()
cp_voter_model=()

for stage_id in "${selected_stage_ids[@]}"; do
  cp_stages+=("$stage_id")
  if [[ "$mode" == "graph" ]]; then
    node_type="$(ralph_menu_select --prompt "Node type for \"$stage_id\"" --default 1 -- "agent" "consensus" "checkpoint" "join")"
    cp_stage_types+=("$node_type")
  else
    cp_stage_types+=("agent")
  fi
done

print_step "3/$total_steps" "Configure each ${noun}"
print_hint "- For each ${noun}: pick runtime, agent/model, then choose inline content or a separate plan file."
if [[ "$mode" == "graph" ]]; then
  print_hint "- Not yet wizard-authorable: router, gate, integrate node types -- hand-edit the generated plan for those."
fi

for idx in "${!cp_stages[@]}"; do
  stage_id="${cp_stages[$idx]}"
  stage_type="${cp_stage_types[$idx]}"
  if [[ "$mode" == "graph" ]]; then
    print_info "Configuring node \"$stage_id\" (type: $stage_type)"
  else
    print_info "Configuring stage \"$stage_id\""
  fi

  runtime=""
  agent=""
  model=""
  plan_file=""
  inline_content=""
  inline_verification=""
  depends_on=""
  policy=""
  quorum=""
  workspace_mode=""

  if [[ "$mode" == "graph" ]]; then
    known_csv=""
    if ((idx > 0)); then
      earlier_ids=("${cp_stages[@]:0:$idx}")
      known_csv="$(IFS=','; printf '%s' "${earlier_ids[*]}")"
    fi
    depends_on="$(select_depends_on "$stage_id" "$known_csv")"
  fi

  if [[ "$stage_type" == "consensus" ]]; then
    policy="$(ralph_menu_select --prompt "Consensus policy for \"$stage_id\"" --default 1 -- "veto" "unanimous" "quorum" "adjudicate")"
    if [[ "$policy" == "quorum" ]]; then
      quorum="$(ralph_prompt_text "Quorum count for \"$stage_id\"" "2")"
    fi
    configure_voters "$stage_id"
  elif [[ "$stage_type" == "join" ]]; then
    policy="$(ralph_menu_select --prompt "Join policy for \"$stage_id\"" --default 1 -- "veto" "unanimous" "quorum" "adjudicate")"
  elif [[ "$stage_type" == "checkpoint" ]]; then
    :
  else
    use_plan_file="$(ralph_menu_select --prompt "${noun^} \"$stage_id\": inline content or separate plan file?" --default 1 -- "inline" "plan file")"

    if [[ "$use_plan_file" == "plan file" ]]; then
      plan_file_default=".ralph-workspace/plans/${plan_name}-${stage_id}.plan.md"
      plan_file="$(ralph_prompt_text "Plan file path for \"$stage_id\"" "$plan_file_default")"
      [[ -n "$plan_file" ]] || ralph_die "plan file path required for ${noun} \"$stage_id\""

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
            "overview: ${noun^} plan for ${stage_id} in ${plan_name}" \
            "execution: standard" \
            "instructions: Execute one TODO at a time." \
            "" \
            "todos:" \
            "  - id: ${stage_id}-task-1" \
            "    content: |" \
            "      Describe the task for this ${noun} here." \
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
      agent_selection="$(select_agent "$runtime" "$stage_id")"
      IFS=$'\t' read -r agent agent_is_custom custom_model <<< "$agent_selection"
      if [[ "${agent_is_custom:-0}" == "1" ]]; then
        model="$custom_model"
        [[ -n "$model" ]] || ralph_die "Model is required for custom $runtime ${noun} \"$stage_id\"."
        agent=""
      else
        model_default="$(agent_model_default "$runtime" "$agent" | tr -d '\n')"
        model="$(select_model_override "$runtime" "$agent" "$model_default")"
      fi

      inline_content="$(ralph_prompt_text "Content/instructions for \"$stage_id\" todo (optional)" "")"
      inline_verification="$(ralph_prompt_text "Verification steps for \"$stage_id\" todo (optional)" "")"
    fi

    if [[ "$mode" == "graph" ]]; then
      workspace_mode="$(select_workspace_mode "$stage_id")"
    fi
  fi

  if [[ "$stage_type" == "agent" ]]; then
    if [[ "${pipeline_session_strategy_all_stages:-true}" == "true" ]]; then
      session="${pipeline_session_strategy_default:-fresh}"
    else
      session="$(select_session_strategy "$stage_id" "${pipeline_session_strategy_default:-fresh}")"
    fi
    context="$(select_context_budget "$stage_id")"
  else
    session=""
    context=""
  fi

  cp_stage_runtimes+=("$runtime")
  cp_stage_agents+=("$agent")
  cp_stage_models+=("$model")
  cp_stage_session+=("$session")
  cp_stage_context+=("$context")
  cp_stage_plan_files+=("$plan_file")
  cp_stage_inline_content+=("$inline_content")
  cp_stage_inline_verification+=("$inline_verification")
  cp_stage_depends_on+=("$depends_on")
  cp_stage_policy+=("$policy")
  cp_stage_quorum+=("$quorum")
  cp_stage_workspace_mode+=("$workspace_mode")

  if [[ "$stage_type" == "agent" && -z "$plan_file" ]]; then
    artifact_default=".ralph-workspace/artifacts/{{ARTIFACT_NS}}/$(artifact_file_for_stage "$stage_id")"
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

if [[ "$mode" == "orchestration" ]]; then
  print_step "4/$total_steps" "Parallel stages and loop rules (optional)"
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
fi

print_step "$total_steps/$total_steps" "Generate plan"
echo ""
echo "Plan: $dest"
if [[ "$mode" == "graph" ]]; then
  for idx in "${!cp_stages[@]}"; do
    printf '  %s  [%s]  dependsOn: %s\n' "${cp_stages[$idx]}" "${cp_stage_types[$idx]}" "${cp_stage_depends_on[$idx]:-(none)}"
  done
else
  echo "Stages: ${cp_stages[*]}"
fi
echo ""

confirm_write="$(ralph_prompt_yesno "Write this plan" "y")"
if [[ "$confirm_write" == "n" ]]; then
  echo "aborted; no files created"
  exit 0
fi

mkdir -p "$plans_dir"

tmp_dest="$(mktemp "${TMPDIR:-/tmp}/ralph-pipeline-wizard.XXXXXX")"
trap 'rm -f "$tmp_dest"' EXIT

wizard_render_pipeline_plan "$mode" "$plan_name" "$plan_overview" "$instructions_line" \
  "$max_parallel" "$edge_derivation" "$failure_policy" > "$tmp_dest"

mv "$tmp_dest" "$dest"
trap - EXIT

echo "Created ${mode} plan: .ralph-workspace/plans/${plan_name}.plan.md"
echo ""
echo "Run with:"
echo "  ralph run --plan $dest"
if [[ "$mode" == "graph" ]]; then
  echo "Compile and lint with:"
  echo "  ralph graph compile $dest"
fi
