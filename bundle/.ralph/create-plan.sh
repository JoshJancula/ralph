#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bundle_root="$(cd "$script_dir/.." && pwd)"
templates_dir="$script_dir/plan-templates"

# shellcheck source=bash-lib/error-handling.sh
source "$bundle_root/.ralph/bash-lib/error-handling.sh"
# shellcheck source=bash-lib/ui-prompt.sh
source "$bundle_root/.ralph/bash-lib/ui-prompt.sh"
# shellcheck source=bash-lib/wizard/wizard-prompts.sh
source "$bundle_root/.ralph/bash-lib/wizard/wizard-prompts.sh"
# shellcheck source=bash-lib/wizard/wizard-validation.sh
source "$bundle_root/.ralph/bash-lib/wizard/wizard-validation.sh"
# shellcheck source=bash-lib/wizard/wizard-pipeline-plan.sh
source "$bundle_root/.ralph/bash-lib/wizard/wizard-pipeline-plan.sh"

workspace="$(pwd)"
plan_name=""
plan_format="classic"
plan_execution=""
plan_preset=""
interactive="false"
plan_overview=""
parallel_lane_count="2"
parallel_workspace_mode="snapshot"
parallel_shared_risk_ack="false"
parallel_publish_checkpoint="false"
parallel_options_set="false"

declare -a cp_stage_args=()
declare -a cp_stage_runtime_args=()
declare -a cp_stage_agent_args=()
declare -a cp_stage_model_args=()
declare -a cp_stage_session_args=()
declare -a cp_stage_context_args=()
declare -a cp_stage_produces_args=()
declare -a cp_stage_requires_args=()
declare -a cp_stage_produces_optional_args=()
declare -a cp_stage_requires_optional_args=()
declare -a cp_parallel_wave_args=()
declare -a cp_stage_loop_back_args=()
declare -a cp_stage_max_iterations_args=()
declare -a cp_stage_loop_check_args=()

create_plan_normalize_format() {
  case "$1" in
    legacy|classic) printf 'classic' ;;
    yaml|standard|structured|pipeline|orchestration|cursor) printf 'pipeline' ;;
    graph) printf 'graph' ;;
    *) return 1 ;;
  esac
}

create_plan_usage() {
  cat <<'USAGE'
Usage: bash .ralph/create-plan.sh [options]

Options:
  --name <name>            Plan name (default: auto-generated PLAN1, PLAN2, ...).
  --format <classic|yaml|graph>  Plan template format (default: classic).
                                 classic: zero-dependency markdown checklist.
                                 yaml: YAML-frontmatter flat TODO queue.
                                 graph: YAML-frontmatter DAG plan (execution: graph).
  --preset <name>          Graph preset: cross-provider-jury or parallel-implementation.
  --lanes <2|3|4>          Implementation lane count for parallel-implementation (default: 2).
  --workspace-mode <mode>  Lane mode: snapshot (default), worktree, or shared.
  --acknowledge-shared-mutation-risk
                           Required with --workspace-mode shared.
  --publish-checkpoint     Add an optional human checkpoint after review.
  --workspace <path>       Workspace directory (default: current directory).

For a multi-stage orchestration, use: ralph create orc
USAGE
}

create_plan_instructions_line() {
  if [[ -f "$templates_dir/pipeline-simple.plan.template.md" ]]; then
    awk '/^instructions:/{print; exit}' "$templates_dir/pipeline-simple.plan.template.md"
    return 0
  fi
  printf '%s\n' 'instructions: Execute one TODO at a time.'
}

create_plan_reset_orchestration_state() {
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
}

create_plan_stage_set_field() {
  local stage_id="$1"
  local field="$2"
  local value="$3"
  local idx
  idx="$(wizard_create_plan_stage_index "$stage_id")" || ralph_die "unknown stage id: $stage_id"
  case "$field" in
    runtime) cp_stage_runtimes[$idx]="$value" ;;
    agent) cp_stage_agents[$idx]="$value" ;;
    model) cp_stage_models[$idx]="$value" ;;
    session) cp_stage_session[$idx]="$value" ;;
    context) cp_stage_context[$idx]="$value" ;;
  esac
}

create_plan_apply_stage_mappings() {
  local raw flag_name stage_id value
  local sanitized seen_stage

  create_plan_reset_orchestration_state

  for raw in "${cp_stage_args[@]}"; do
    sanitized="$(ralph_internal_wizard_sanitize "$raw")"
    [[ -n "$sanitized" ]] || ralph_die "invalid --stage value: $raw"
    for seen_stage in "${cp_stages[@]}"; do
      [[ "$seen_stage" == "$sanitized" ]] && ralph_die "duplicate --stage value: $sanitized"
    done
    cp_stages+=("$sanitized")
    cp_stage_runtimes+=("")
    cp_stage_agents+=("")
    cp_stage_models+=("")
    cp_stage_session+=("")
    cp_stage_context+=("")
  done

  for raw in "${cp_stage_runtime_args[@]}"; do
    IFS=$'\t' read -r stage_id value <<< "$(wizard_parse_stage_mapping "$raw" "--stage-runtime")"
    wizard_create_plan_require_known_stage "$stage_id" "--stage-runtime"
    wizard_create_plan_validate_runtime "$value" "--stage-runtime"
    create_plan_stage_set_field "$stage_id" runtime "$value"
  done

  for raw in "${cp_stage_agent_args[@]}"; do
    IFS=$'\t' read -r stage_id value <<< "$(wizard_parse_stage_mapping "$raw" "--stage-agent")"
    wizard_create_plan_require_known_stage "$stage_id" "--stage-agent"
    create_plan_stage_set_field "$stage_id" agent "$value"
  done

  for raw in "${cp_stage_model_args[@]}"; do
    IFS=$'\t' read -r stage_id value <<< "$(wizard_parse_stage_mapping "$raw" "--stage-model")"
    wizard_create_plan_require_known_stage "$stage_id" "--stage-model"
    create_plan_stage_set_field "$stage_id" model "$value"
  done

  for raw in "${cp_stage_session_args[@]}"; do
    IFS=$'\t' read -r stage_id value <<< "$(wizard_parse_stage_mapping "$raw" "--stage-session-strategy")"
    wizard_create_plan_require_known_stage "$stage_id" "--stage-session-strategy"
    wizard_create_plan_validate_session_strategy "$value" "--stage-session-strategy"
    create_plan_stage_set_field "$stage_id" session "$value"
  done

  for raw in "${cp_stage_context_args[@]}"; do
    IFS=$'\t' read -r stage_id value <<< "$(wizard_parse_stage_mapping "$raw" "--stage-context-budget")"
    wizard_create_plan_require_known_stage "$stage_id" "--stage-context-budget"
    wizard_create_plan_validate_context_budget "$value" "--stage-context-budget"
    create_plan_stage_set_field "$stage_id" context "$value"
  done

  for raw in "${cp_stage_produces_args[@]}"; do
    IFS=$'\t' read -r stage_id value <<< "$(wizard_parse_stage_mapping "$raw" "--stage-produces")"
    wizard_create_plan_require_known_stage "$stage_id" "--stage-produces"
    wizard_create_plan_append_artifact "$stage_id" "$value" "true" "produces"
  done

  for raw in "${cp_stage_requires_args[@]}"; do
    IFS=$'\t' read -r stage_id value <<< "$(wizard_parse_stage_mapping "$raw" "--stage-requires")"
    wizard_create_plan_require_known_stage "$stage_id" "--stage-requires"
    wizard_create_plan_append_artifact "$stage_id" "$value" "true" "requires"
  done

  for raw in "${cp_stage_produces_optional_args[@]}"; do
    IFS=$'\t' read -r stage_id value <<< "$(wizard_parse_stage_mapping "$raw" "--stage-produces-optional")"
    wizard_create_plan_require_known_stage "$stage_id" "--stage-produces-optional"
    wizard_create_plan_append_artifact "$stage_id" "$value" "false" "produces"
  done

  for raw in "${cp_stage_requires_optional_args[@]}"; do
    IFS=$'\t' read -r stage_id value <<< "$(wizard_parse_stage_mapping "$raw" "--stage-requires-optional")"
    wizard_create_plan_require_known_stage "$stage_id" "--stage-requires-optional"
    wizard_create_plan_append_artifact "$stage_id" "$value" "false" "requires"
  done

  cp_parallel_waves=("${cp_parallel_wave_args[@]}")

  for raw in "${cp_stage_loop_back_args[@]}"; do
    IFS=$'\t' read -r stage_id value <<< "$(wizard_parse_stage_mapping "$raw" "--stage-loop-back")"
    wizard_create_plan_require_known_stage "$stage_id" "--stage-loop-back"
    wizard_create_plan_set_loop "$stage_id" "$value" "" ""
  done

  for raw in "${cp_stage_max_iterations_args[@]}"; do
    IFS=$'\t' read -r stage_id value <<< "$(wizard_parse_stage_mapping "$raw" "--stage-max-iterations")"
    wizard_create_plan_require_known_stage "$stage_id" "--stage-max-iterations"
    wizard_create_plan_set_loop "$stage_id" "$(wizard_create_plan_loop_target "$stage_id")" "$value" "$(wizard_create_plan_loop_check "$stage_id")"
  done

  for raw in "${cp_stage_loop_check_args[@]}"; do
    IFS=$'\t' read -r stage_id value <<< "$(wizard_parse_stage_mapping "$raw" "--stage-loop-check")"
    wizard_create_plan_require_known_stage "$stage_id" "--stage-loop-check"
    wizard_create_plan_set_loop "$stage_id" "$(wizard_create_plan_loop_target "$stage_id")" "$(wizard_create_plan_loop_max "$stage_id")" "$value"
  done
}

create_plan_render_simple_template() {
  local template="$1"
  local dest_name="$2"
  local overview="$3"
  sed \
    -e "s/PLAN_TITLE_HERE/${dest_name}/g" \
    -e "s/PLAN_OVERVIEW_HERE/${overview}/g" \
    "$template"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      [[ $# -ge 2 ]] || ralph_die "missing value for --name"
      plan_name="$2"
      shift 2
      ;;
    --format)
      [[ $# -ge 2 ]] || ralph_die "missing value for --format"
      if ! plan_format="$(create_plan_normalize_format "$2")"; then
        ralph_die "invalid --format: $2 (must be 'classic', 'yaml', or 'graph')"
      fi
      shift 2
      ;;
    --execution)
      [[ $# -ge 2 ]] || ralph_die "missing value for --execution"
      plan_execution="$2"
      shift 2
      ;;
    --preset)
      [[ $# -ge 2 ]] || ralph_die "missing value for --preset"
      plan_preset="$2"
      shift 2
      ;;
    --lanes|--lane-count)
      [[ $# -ge 2 ]] || ralph_die "missing value for $1"
      parallel_lane_count="$2"
      parallel_options_set="true"
      shift 2
      ;;
    --workspace-mode)
      [[ $# -ge 2 ]] || ralph_die "missing value for --workspace-mode"
      parallel_workspace_mode="$2"
      parallel_options_set="true"
      shift 2
      ;;
    --acknowledge-shared-mutation-risk)
      parallel_shared_risk_ack="true"
      parallel_options_set="true"
      shift
      ;;
    --publish-checkpoint|--human-publish-checkpoint)
      parallel_publish_checkpoint="true"
      parallel_options_set="true"
      shift
      ;;
    --interactive)
      interactive="true"
      shift
      ;;
    --workspace)
      [[ $# -ge 2 ]] || ralph_die "missing value for --workspace"
      workspace="$2"
      shift 2
      ;;
    --kind)
      ralph_die "unsupported flag: --kind (use --format classic|yaml)"
      ;;
    --stage)
      [[ $# -ge 2 ]] || ralph_die "missing value for --stage"
      cp_stage_args+=("$2")
      shift 2
      ;;
    --stage-runtime)
      [[ $# -ge 2 ]] || ralph_die "missing value for --stage-runtime"
      cp_stage_runtime_args+=("$2")
      shift 2
      ;;
    --stage-agent)
      [[ $# -ge 2 ]] || ralph_die "missing value for --stage-agent"
      cp_stage_agent_args+=("$2")
      shift 2
      ;;
    --stage-model)
      [[ $# -ge 2 ]] || ralph_die "missing value for --stage-model"
      cp_stage_model_args+=("$2")
      shift 2
      ;;
    --stage-session-strategy)
      [[ $# -ge 2 ]] || ralph_die "missing value for --stage-session-strategy"
      cp_stage_session_args+=("$2")
      shift 2
      ;;
    --stage-context-budget)
      [[ $# -ge 2 ]] || ralph_die "missing value for --stage-context-budget"
      cp_stage_context_args+=("$2")
      shift 2
      ;;
    --stage-produces)
      [[ $# -ge 2 ]] || ralph_die "missing value for --stage-produces"
      cp_stage_produces_args+=("$2")
      shift 2
      ;;
    --stage-requires)
      [[ $# -ge 2 ]] || ralph_die "missing value for --stage-requires"
      cp_stage_requires_args+=("$2")
      shift 2
      ;;
    --stage-produces-optional)
      [[ $# -ge 2 ]] || ralph_die "missing value for --stage-produces-optional"
      cp_stage_produces_optional_args+=("$2")
      shift 2
      ;;
    --stage-requires-optional)
      [[ $# -ge 2 ]] || ralph_die "missing value for --stage-requires-optional"
      cp_stage_requires_optional_args+=("$2")
      shift 2
      ;;
    --parallel-wave)
      [[ $# -ge 2 ]] || ralph_die "missing value for --parallel-wave"
      cp_parallel_wave_args+=("$2")
      shift 2
      ;;
    --stage-loop-back)
      [[ $# -ge 2 ]] || ralph_die "missing value for --stage-loop-back"
      cp_stage_loop_back_args+=("$2")
      shift 2
      ;;
    --stage-max-iterations)
      [[ $# -ge 2 ]] || ralph_die "missing value for --stage-max-iterations"
      cp_stage_max_iterations_args+=("$2")
      shift 2
      ;;
    --stage-loop-check)
      [[ $# -ge 2 ]] || ralph_die "missing value for --stage-loop-check"
      cp_stage_loop_check_args+=("$2")
      shift 2
      ;;
    -h|--help)
      create_plan_usage
      exit 0
      ;;
    *)
      ralph_die "unknown flag: $1"
      ;;
  esac
done

if [[ ! -d "$workspace" ]]; then
  ralph_die "workspace does not exist: $workspace"
fi

if [[ "$plan_preset" == "parallel-implementation" ]]; then
  [[ "$plan_format" == "graph" ]] || ralph_die "--preset parallel-implementation requires --format graph"
  [[ "$parallel_lane_count" =~ ^[234]$ ]] || ralph_die "--lanes must be 2, 3, or 4"
  case "$parallel_workspace_mode" in
    snapshot|worktree) ;;
    shared)
      [[ "$parallel_shared_risk_ack" == "true" ]] || ralph_die \
        "shared parallel mutation is unsafe: repeat with --acknowledge-shared-mutation-risk"
      printf '%s\n' \
        "WARNING: shared parallel mutation can race and corrupt the caller workspace; risk explicitly acknowledged." >&2
      ;;
    *) ralph_die "--workspace-mode must be snapshot, worktree, or shared" ;;
  esac
elif [[ "$parallel_options_set" == "true" ]]; then
  ralph_die "parallel lane options require --preset parallel-implementation"
fi

if [[ -n "$plan_execution" ]]; then
  case "$plan_execution" in
    standard|simple) plan_execution="standard" ;;
    orchestration)
      if [[ "${RALPH_CREATE_ALLOW_ORCHESTRATION:-0}" != "1" ]]; then
        ralph_die "multi-stage orchestrations are created with 'ralph create orc', not 'ralph create plan'"
      fi
      ;;
    *) ralph_die "invalid --execution: $plan_execution (must be 'standard')" ;;
  esac
fi

if [[ "$plan_format" == "classic" ]]; then
  if [[ -n "$plan_execution" ]]; then
    ralph_die "--execution is only valid with --format yaml"
  fi
  if [[ "$interactive" == "true" ]]; then
    ralph_die "--interactive is only valid with --format yaml"
  fi
  if ((${#cp_stage_args[@]} > 0 || ${#cp_stage_runtime_args[@]} > 0)); then
    ralph_die "orchestration stage flags require --format orchestration --execution orchestration"
  fi
fi

if [[ "$plan_format" == "pipeline" && -z "$plan_execution" ]]; then
  if [[ "$interactive" == "true" && "${RALPH_CREATE_ALLOW_ORCHESTRATION:-0}" == "1" ]]; then
    plan_execution="$(wizard_create_plan_interactive_execution_mode)"
  else
    plan_execution="standard"
  fi
fi

workspace="$(cd "$workspace" && pwd)"
SCRIPT_DIR="$script_dir"
export SCRIPT_DIR

if [[ -z "$plan_name" ]]; then
  local_n=1
  while [[ -f "$workspace/.ralph-workspace/plans/PLAN${local_n}.plan.md" ]]; do
    local_n=$((local_n + 1))
  done
  plan_name="PLAN${local_n}"
fi

if [[ -z "$plan_overview" ]]; then
  plan_overview="Plan for ${plan_name}"
fi

plans_dir="$workspace/.ralph-workspace/plans"
mkdir -p "$plans_dir"
dest="$plans_dir/${plan_name}.plan.md"

if [[ -e "$dest" ]]; then
  ralph_die "plan already exists: $dest"
fi

if [[ "$plan_format" == "graph" && "$plan_preset" == "parallel-implementation" ]]; then
  parallel_plan_key="$(ralph_internal_wizard_sanitize "$plan_name")"
  parallel_plans_dir="$plans_dir/${parallel_plan_key}-parallel"
  if [[ -d "$parallel_plans_dir" ]] && find "$parallel_plans_dir" -mindepth 1 -print -quit | grep -q .; then
    ralph_die "parallel implementation plan directory already exists and is not empty: $parallel_plans_dir"
  fi
fi

tmp_dest="$(mktemp "${TMPDIR:-/tmp}/ralph-create-plan.XXXXXX")"
trap 'rm -f "$tmp_dest"' EXIT

case "$plan_format" in
  classic)
    plan_template="$templates_dir/classic.plan.template.md"
    [[ -f "$plan_template" ]] || ralph_die "plan template not found at $plan_template"
    create_plan_render_simple_template "$plan_template" "$plan_name" "$plan_overview" > "$tmp_dest"
    ;;
  pipeline)
    case "$plan_execution" in
      standard)
        plan_template="$templates_dir/pipeline-simple.plan.template.md"
        [[ -f "$plan_template" ]] || ralph_die "plan template not found at $plan_template"
        create_plan_render_simple_template "$plan_template" "$plan_name" "$plan_overview" > "$tmp_dest"
        ;;
      orchestration)
        instructions_line="$(create_plan_instructions_line)"
        if [[ "$interactive" == "true" ]]; then
          wizard_create_plan_interactive_orchestration "$plan_name" "$plan_overview" "$instructions_line" > "$tmp_dest"
        else
          create_plan_apply_stage_mappings
          wizard_create_plan_validate_orchestration
          wizard_render_pipeline_orchestration_plan "$plan_name" "$plan_overview" "$instructions_line" > "$tmp_dest"
        fi
        ;;
    esac
    ;;
  graph)
    case "$plan_preset" in
      cross-provider-jury)
        wizard_render_graph_jury_preset "$plan_name" "$plan_overview" > "$tmp_dest"
        ;;
      parallel-implementation)
        wizard_render_graph_parallel_implementation_preset \
          "$plan_name" "$plan_overview" "$parallel_lane_count" \
          "$parallel_workspace_mode" "$parallel_shared_risk_ack" \
          "$parallel_publish_checkpoint" > "$tmp_dest"
        ;;
      "")
        plan_template="$templates_dir/graph-consensus.plan.template.md"
        [[ -f "$plan_template" ]] || ralph_die "graph template not found at $plan_template"
        sed \
          -e "s/GRAPH_PLAN_NAME_HERE/${plan_name}/g" \
          -e "s/GRAPH_PLAN_NAMESPACE_HERE/${plan_name}/g" \
          "$plan_template" > "$tmp_dest"
        ;;
      *)
        ralph_die "unknown --preset for graph format: $plan_preset (supported: cross-provider-jury, parallel-implementation)"
        ;;
    esac
    ;;
esac

mv "$tmp_dest" "$dest"
trap - EXIT

if [[ "$plan_format" == "graph" && "$plan_preset" == "parallel-implementation" ]]; then
  wizard_write_graph_parallel_plan_files "$workspace" "$plan_name" "$parallel_lane_count"
fi

if [[ "$workspace" == "$(pwd)" ]]; then
  display_dest="./.ralph-workspace/plans/${plan_name}.plan.md"
else
  display_dest="$dest"
fi

printf 'Created plan: %s\n' "$display_dest"
if [[ "$plan_format" == "pipeline" && "$plan_execution" == "standard" ]]; then
  printf 'Tip: add per-todo runtime:/model: overrides to any TODO; per-todo routing applies under fresh session management.\n'
fi
if [[ "$plan_format" == "graph" ]]; then
  printf 'Tip: compile and lint with: ralph graph compile %s\n' "$display_dest"
fi
