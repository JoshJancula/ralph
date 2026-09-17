#!/usr/bin/env bash
# Create a leaf Ralph plan (classic or YAML). Graph/orchestration formats are
# refused with a pointer to `ralph create workflow`.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bundle_root="$(cd "$script_dir/.." && pwd)"
templates_dir="$script_dir/plan-templates"

# shellcheck source=bash-lib/error-handling.sh
source "$bundle_root/.ralph/bash-lib/error-handling.sh"
# shellcheck source=bash-lib/help-render.sh
source "$bundle_root/.ralph/bash-lib/help-render.sh"

workspace="$(pwd)"
plan_name=""
plan_format="classic"
plan_execution=""
plan_preset=""
interactive="false"
manual="false"
plan_runtime=""
plan_model=""
plan_session_strategy=""
plan_overview=""
parallel_options_set="false"
stage_flags_set="false"

create_plan_removed_format_die() {
  local fmt="$1"
  ralph_die "Error: 'ralph create plan --format ${fmt}' was removed. Use: ralph create workflow" 2
}

create_plan_normalize_format() {
  case "$1" in
    legacy|classic) printf 'classic' ;;
    yaml|standard|structured|pipeline|cursor) printf 'pipeline' ;;
    *) return 1 ;;
  esac
}

create_plan_usage() {
  cat <<'USAGE' | ralph_help_render
Usage: bash .ralph/create-plan.sh [options]

Options:
  --name <name>            Plan name (default: auto-generated PLAN1, PLAN2, ...).
  --format <classic|yaml>  Plan template format (default: classic).
                           classic: zero-dependency markdown checklist.
                           yaml: YAML-frontmatter flat TODO queue.
                           (standard, structured, pipeline, and cursor are
                            accepted as silent aliases for yaml.)
  --workspace <path>       Workspace directory (default: current directory).
  --runtime <runtime>      YAML plan default runtime (cursor|claude|codex|opencode|antigravity).
  --model <model>          YAML plan default model (requires --runtime).
  --session-strategy <s>   YAML plan default session strategy
                           (fresh|resume|reset|compact).
  --guided, --interactive  Prompt for YAML plan runtime, model, and session strategy.
  --manual                 Create the editable YAML template without prompts (default).

For multi-stage Sequential or Dependency workflows, use: ralph create workflow
USAGE
}

create_plan_validate_runtime() {
  case "$1" in
    cursor|claude|codex|opencode|antigravity) ;;
    *) ralph_die "invalid --runtime: $1 (must be cursor, claude, codex, opencode, or antigravity)" ;;
  esac
}

create_plan_validate_session_strategy() {
  case "$1" in
    fresh|resume|reset|compact) ;;
    *) ralph_die "invalid --session-strategy: $1 (must be fresh, resume, reset, or compact)" ;;
  esac
}

create_plan_prompt_routing() {
  local value
  printf '%s' 'Default runtime (blank = choose when running): ' >&2
  IFS= read -r value || true
  plan_runtime="$value"
  if [[ -n "$plan_runtime" ]]; then
    create_plan_validate_runtime "$plan_runtime"
    printf '%s' 'Default model (blank = runtime default): ' >&2
    IFS= read -r value || true
    plan_model="$value"
  fi
  printf '%s' 'Session strategy [fresh|resume|reset|compact] (default fresh): ' >&2
  IFS= read -r value || true
  plan_session_strategy="${value:-fresh}"
  create_plan_validate_session_strategy "$plan_session_strategy"
}

create_plan_apply_yaml_routing() {
  local source="$1"
  awk -v runtime="$plan_runtime" -v model="$plan_model" -v strategy="$plan_session_strategy" '
    function yaml_quote(value) {
      gsub(/\\/, "\\\\", value)
      gsub(/"/, "\\\"", value)
      return "\"" value "\""
    }
    {
      print
      if ($0 ~ /^mode:/) {
        if (runtime != "") print "runtime: " runtime
        if (model != "") print "model: " yaml_quote(model)
        if (strategy != "") print "sessionStrategy: " strategy
      }
    }
  ' "$source"
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
      case "$2" in
        graph|orchestration)
          create_plan_removed_format_die "$2"
          ;;
      esac
      if ! plan_format="$(create_plan_normalize_format "$2")"; then
        ralph_die "invalid --format: $2 (must be 'classic' or 'yaml')"
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
    --lanes|--lane-count|--workspace-mode)
      [[ $# -ge 2 ]] || ralph_die "missing value for $1"
      parallel_options_set="true"
      shift 2
      ;;
    --acknowledge-shared-mutation-risk|--publish-checkpoint|--human-publish-checkpoint)
      parallel_options_set="true"
      shift
      ;;
    --interactive)
      interactive="true"
      shift
      ;;
    --guided)
      interactive="true"
      shift
      ;;
    --manual)
      manual="true"
      shift
      ;;
    --runtime)
      [[ $# -ge 2 ]] || ralph_die "missing value for --runtime"
      plan_runtime="$2"
      shift 2
      ;;
    --model)
      [[ $# -ge 2 ]] || ralph_die "missing value for --model"
      plan_model="$2"
      shift 2
      ;;
    --session-strategy)
      [[ $# -ge 2 ]] || ralph_die "missing value for --session-strategy"
      plan_session_strategy="$2"
      shift 2
      ;;
    --workspace)
      [[ $# -ge 2 ]] || ralph_die "missing value for --workspace"
      workspace="$2"
      shift 2
      ;;
    --kind)
      ralph_die "unsupported flag: --kind (use --format classic|yaml)"
      ;;
    --stage|--stage-runtime|--stage-model|--stage-session-strategy|--stage-context-budget|\
    --stage-produces|--stage-requires|--stage-produces-optional|--stage-requires-optional|\
    --parallel-wave|--stage-loop-back|--stage-max-iterations|--stage-loop-check)
      [[ $# -ge 2 ]] || ralph_die "missing value for $1"
      stage_flags_set="true"
      shift 2
      ;;
    --stage-agent)
      ralph_die "unsupported flag: --stage-agent (roles are selected separately by the interactive wizard)"
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

if [[ -n "$plan_preset" || "$parallel_options_set" == "true" ]]; then
  ralph_die "Error: graph plan options were removed from 'ralph create plan'. Use: ralph create workflow" 2
fi

if [[ "$stage_flags_set" == "true" ]]; then
  ralph_die "Error: orchestration stage flags require 'ralph create workflow', not 'ralph create plan'" 2
fi

if [[ -n "$plan_execution" ]]; then
  case "$plan_execution" in
    standard|simple) plan_execution="standard" ;;
    orchestration)
      ralph_die "Error: orchestration plans are created with 'ralph create workflow', not 'ralph create plan'" 2
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
  if [[ -n "$plan_runtime$plan_model$plan_session_strategy" ]]; then
    ralph_die "--runtime, --model, and --session-strategy are only valid with --format yaml"
  fi
fi

if [[ "$interactive" == "true" && "$manual" == "true" ]]; then
  ralph_die "--guided/--interactive and --manual cannot be used together"
fi

if [[ "$interactive" == "true" && -n "$plan_runtime$plan_model$plan_session_strategy" ]]; then
  ralph_die "--guided/--interactive cannot be combined with --runtime, --model, or --session-strategy"
fi

if [[ "$interactive" == "true" ]]; then
  create_plan_prompt_routing
fi

if [[ -n "$plan_runtime" ]]; then
  create_plan_validate_runtime "$plan_runtime"
fi
if [[ -n "$plan_model" && -z "$plan_runtime" ]]; then
  ralph_die "--model requires --runtime"
fi
if [[ -n "$plan_session_strategy" ]]; then
  create_plan_validate_session_strategy "$plan_session_strategy"
fi

if [[ "$plan_format" == "pipeline" && -z "$plan_execution" ]]; then
  plan_execution="standard"
fi

workspace="$(cd "$workspace" && pwd)"

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

tmp_dest="$(mktemp "${TMPDIR:-/tmp}/ralph-create-plan.XXXXXX")"
trap 'rm -f "$tmp_dest"' EXIT

case "$plan_format" in
  classic)
    plan_template="$templates_dir/classic.plan.template.md"
    [[ -f "$plan_template" ]] || ralph_die "plan template not found at $plan_template"
    create_plan_render_simple_template "$plan_template" "$plan_name" "$plan_overview" > "$tmp_dest"
    ;;
  pipeline)
    plan_template="$templates_dir/pipeline-simple.plan.template.md"
    [[ -f "$plan_template" ]] || ralph_die "plan template not found at $plan_template"
    create_plan_render_simple_template "$plan_template" "$plan_name" "$plan_overview" \
      | create_plan_apply_yaml_routing /dev/stdin > "$tmp_dest"
    ;;
  *)
    ralph_die "unsupported plan format: $plan_format"
    ;;
esac

mv "$tmp_dest" "$dest"
trap - EXIT

if [[ "$workspace" == "$(pwd)" ]]; then
  display_dest="./.ralph-workspace/plans/${plan_name}.plan.md"
else
  display_dest="$dest"
fi

printf 'Created plan: %s\n' "$display_dest"
if [[ "$plan_format" == "pipeline" ]]; then
  printf 'Tip: YAML plans support plan defaults for runtime, model, and sessionStrategy. Every TODO can override runtime, model, sessionStrategy, or contextBudget; runtime switches require fresh sessions.\n'
  if [[ "$interactive" == "true" ]]; then
    printf 'Guided defaults were added. Edit the generated YAML to configure individual TODO overrides.\n'
  else
    printf 'Use --guided to configure defaults now, or edit the generated YAML manually.\n'
  fi
fi
