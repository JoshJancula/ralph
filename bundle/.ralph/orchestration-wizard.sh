#!/usr/bin/env bash
set -euo pipefail

workspace="$(pwd)"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bundle_root="$(cd "$script_dir/.." && pwd)"
plan_template="$script_dir/plan.template"

if [[ ! -f "$plan_template" ]]; then
  echo "plan template not found at $plan_template" >&2
  exit 1
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

default_stages=("research" "architecture" "implementation" "code-review" "qa")

runtime_default() {
  case "$1" in
    research) printf 'cursor' ;;
    architecture) printf 'claude' ;;
    implementation) printf 'cursor' ;;
    code-review) printf 'codex' ;;
    qa) printf 'cursor' ;;
    *)
      printf 'cursor'
      ;;
  esac
}

agent_default() {
  case "$1" in
    research) printf 'research' ;;
    architecture) printf 'architect' ;;
    implementation) printf 'implementation' ;;
    code-review) printf 'code-review' ;;
    qa) printf 'qa' ;;
    *)
      printf '%s' "$1"
      ;;
  esac
}

artifact_file_for_stage() {
  case "$1" in
    research) printf 'research.md' ;;
    architecture) printf 'architecture.md' ;;
    implementation) printf 'implementation-handoff.md' ;;
    code-review) printf 'code-review.md' ;;
    qa) printf 'qa.md' ;;
    *)
      printf '%s.md' "$1"
      ;;
  esac
}

agent_dir_for_runtime() {
  case "$1" in
    cursor) printf '.cursor/agents' ;;
    claude) printf '.claude/agents' ;;
    codex) printf '.codex/agents' ;;
    *)
      printf '.cursor/agents'
      ;;
  esac
}

sanitize() {
  local value="$1"
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
  value="$(printf '%s' "$value" | tr -c 'a-z0-9-' '-')"
  value="$(printf '%s' "$value" | sed 's/-\+/-/g; s/^-//; s/-$//')"
  printf '%s' "$value"
}

list_agents() {
  local runtime="$1"
  local dir
  dir="$(agent_dir_for_runtime "$runtime")"
  local abs_dir="$workspace/$dir"
  local agent
  local entries=()

  if [[ ! -d "$abs_dir" ]]; then
    return
  fi

  for agent in "$abs_dir"/*; do
    [[ -d "$agent" && -f "$agent/config.json" ]] || continue
    entries+=("$(basename "$agent")")
  done

  if [[ ${#entries[@]} -gt 0 ]]; then
    printf '%s\n' "${entries[@]}" | sort
  fi
}

escape_sed() {
  local value="$1"
  printf '%s' "$value" | sed 's/[\/&]/\\&/g'
}

read_pipeline_info() {
  local name default_ns ns
  read -rp "Pipeline name (human-friendly): " name
  [[ -n "$name" ]] || { echo "Pipeline name is required" >&2; exit 1; }
  default_ns="$(sanitize "$name")"
  [[ -n "$default_ns" ]] || default_ns="pipeline"
  read -rp "Namespace [default $default_ns]: " ns
  ns="${ns:-$default_ns}"
  ns="$(sanitize "$ns")"
  [[ -n "$ns" ]] || { echo "Namespace cannot be empty after sanitization" >&2; exit 1; }
  pipeline_name="$name"
  namespace="$ns"
}

read_stages() {
  local input default_list raw
  default_list="${default_stages[*]}"
  read -rp "Stages (comma-separated, default $default_list): " input
  selected_stages=()
  if [[ -z "$input" ]]; then
    selected_stages=("${default_stages[@]}")
    return
  fi
  local IFS=,
  for raw in $input; do
    raw="$(echo "$raw" | tr -d '[:space:]')"
    [[ -n "$raw" ]] || continue
    selected_stages+=("$raw")
  done
}

select_runtime() {
  local stage="$1"
  local default
  default="$(runtime_default "$stage")"
  local runtime options idx=1 default_index=1 choice
  options=("cursor" "claude" "codex")
  printf 'Available runtimes:\n' >&2
  for opt in "${options[@]}"; do
    if [[ "$opt" == "$default" ]]; then
      default_index="$idx"
    fi
    printf '  %d) %s\n' "$idx" "$opt" >&2
    idx=$((idx + 1))
  done
  while true; do
    read -rp "Runtime for \"$stage\" [default $default_index, input number selection]: " choice
    choice="${choice:-$default_index}"
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
      runtime="${options[$((choice - 1))]}"
      break
    fi
    echo "Invalid selection. Enter a number from 1 to ${#options[@]}." >&2
  done
  printf '%s' "$runtime"
}

pick_model_for_runtime() {
  local runtime="$1"
  case "$runtime" in
    cursor)
      if declare -F select_model_cursor >/dev/null 2>&1; then
        select_model_cursor --interactive
      fi
      ;;
    claude)
      if declare -F select_model_claude >/dev/null 2>&1; then
        select_model_claude --interactive
      fi
      ;;
    codex)
      if declare -F select_model_codex >/dev/null 2>&1; then
        select_model_codex --interactive
      fi
      ;;
  esac
}

select_model_override() {
  local runtime="$1"
  local agent="$2"
  local model_default="${3:-}"
  local choice picked_model

  echo "Model override for \"$agent\":" >&2
  if [[ -n "$model_default" ]]; then
    echo "  1) No override (use agent default: $model_default)" >&2
  else
    echo "  1) No override (use agent default)" >&2
  fi
  echo "  2) Pick model from list" >&2

  while true; do
    read -rp "Select option [1]: " choice
    choice="${choice:-1}"
    case "$choice" in
      1)
        printf ''
        return
        ;;
      2)
        picked_model="$(pick_model_for_runtime "$runtime" | tr -d '\n')"
        printf '%s' "$picked_model"
        return
        ;;
      *)
        echo "Invalid selection. Enter 1 or 2." >&2
        ;;
    esac
  done
}

select_agent() {
  local runtime="$1"
  local stage="$2"
  local default
  default="$(agent_default "$stage")"
  local agents=()
  local line

  while IFS= read -r line; do
    agents+=("$line")
  done < <(list_agents "$runtime")

  if [[ ${#agents[@]} -eq 0 ]]; then
    local custom_model
    echo "No existing $runtime agents found. Using implicit custom agent id: custom." >&2
    echo "Custom agent will use default $runtime runner skills and rules." >&2
    custom_model="$(pick_model_for_runtime "$runtime" | tr -d '\n')"
    printf '%s\t1\t%s' "custom" "$custom_model"
    return
  fi

  printf 'Available %s agents:\n' "$runtime" >&2
  local idx=1
  local default_index=1
  local agent
  for agent in "${agents[@]}"; do
    [[ "$agent" == "$default" ]] && default_index="$idx"
    printf '  %2d) %s\n' "$idx" "$agent" >&2
    idx=$((idx + 1))
  done

  local answer
  while true; do
    read -rp "Select existing agent number [default $default_index]: " answer
    answer="${answer:-$default_index}"
    if [[ "$answer" =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= ${#agents[@]} )); then
      printf '%s\t0\t' "${agents[$((answer - 1))]}"
      return
    fi
    echo "Invalid selection. Enter a number from 1 to ${#agents[@]}." >&2
  done
}

agent_model_default() {
  local runtime="$1"
  local agent="$2"
  local dir
  dir="$(agent_dir_for_runtime "$runtime")"
  local cfg="$workspace/$dir/$agent/config.json"
  if [[ ! -f "$cfg" ]]; then
    return
  fi
  python3 - <<'PY' "$cfg"
import json,sys
with open(sys.argv[1]) as f:
    c=json.load(f)
print(c.get("model",""))
PY
}

escape_json() {
  python3 - <<'PY'
import json,sys
print(json.dumps(sys.stdin.read()))
PY
}

echo "Note: this wizard copies .ralph/plan.template and scaffolds .agents/orchestration-plans/<namespace> plus artifacts."

read_pipeline_info
read_stages
stages=()
if [[ ${#selected_stages[@]} -gt 0 ]]; then
  stages=("${selected_stages[@]}")
fi

if [[ ${#stages[@]} -eq 0 ]]; then
  echo "No stages configured" >&2
  exit 1
fi

stage_runtimes=()
stage_agents=()
stage_agent_sources=()
stage_descriptions=()
stage_models=()

for stage in "${stages[@]}"; do
  stage_id="$(sanitize "$stage")"
  [[ -n "$stage_id" ]] || { echo "Stage \"$stage\" sanitizes to empty; skip" >&2; exit 1; }
  printf '\nConfiguring stage "%s"\n' "$stage_id"
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
done

pipeline_description_default="Multi-stage pipeline for $pipeline_name"
read -rp "Description (press enter to use default): " description
description="${description:-$pipeline_description_default}"

loop_stage=""
loop_back=""
loop_iterations=2
read -rp "Add loop control for a stage? [y/N]: " loop_choice
if [[ "$loop_choice" =~ ^[Yy] ]]; then
  echo "Available stages: ${stages[*]}"
  read -rp "Stage that should loop (id): " loop_stage_input
  loop_stage="$(sanitize "$loop_stage_input")"
  if [[ -z "$loop_stage" ]]; then
    loop_stage=""
  else
    read -rp "Loop back to which stage (id): " loop_back_input
    loop_back="$(sanitize "$loop_back_input")"
    if [[ -z "$loop_back" ]]; then
      loop_stage=""
    else
      read -rp "Max iterations [default 2]: " loop_iterations_input
      loop_iterations="${loop_iterations_input:-2}"
      if ! [[ "$loop_iterations" =~ ^[0-9]+$ ]]; then
        loop_iterations=2
      fi
    fi
  fi
fi

if [[ -n "$loop_stage" ]]; then
  loop_stage_found=0
  loop_back_found=0
  for stage in "${stages[@]}"; do
    sanitized_stage="$(sanitize "$stage")"
    [[ "$loop_stage" == "$sanitized_stage" ]] && loop_stage_found=1
    [[ "$loop_back" == "$sanitized_stage" ]] && loop_back_found=1
  done
  if (( loop_stage_found == 0 || loop_back_found == 0 )); then
    echo "Loop control targets not found in configured stages; ignoring loop control."
    loop_stage=""
    loop_back=""
  fi
fi

plan_dir="$workspace/.agents/orchestration-plans/$namespace"
artifact_dir="$workspace/.agents/artifacts/$namespace"
orch_file="$plan_dir/$namespace.orch.json"

mkdir -p "$plan_dir" "$artifact_dir"

stage_entries=()
generated_plan_paths=()
total_steps=${#stages[@]}

for idx in "${!stages[@]}"; do
  step_number=$(printf "%02d" $((idx + 1)))
  stage_label="$(sanitize "${stages[$idx]}")"
  runtime="${stage_runtimes[$idx]}"
  agent="${stage_agents[$idx]}"
  agent_source="${stage_agent_sources[$idx]}"

  plan_rel_path=".agents/orchestration-plans/$namespace/${namespace}-${step_number}-${stage_label}.plan.md"
  plan_abs_path="$workspace/$plan_rel_path"
  generated_plan_paths+=("$plan_rel_path")
  artifact_base="$(artifact_file_for_stage "$stage_label")"
  artifact_path=".agents/artifacts/$namespace/$artifact_base"

  stage_desc="${stage_descriptions[$idx]}"
  stage_model="${stage_models[$idx]}"
  if [[ ! -f "$plan_abs_path" ]]; then
    plan_title="$(printf '%s %s stage plan for %s' "$namespace" "$stage_label" "$pipeline_name")"
    sed "s/PLAN_TITLE_HERE/$(escape_sed "$plan_title")/" "$plan_template" > "$plan_abs_path"
    {
      printf '\n## Stage overview\n- Stage: %s\n- Runtime: %s\n- Agent: %s\n' "$stage_label" "$runtime" "$agent"
      [[ -n "$stage_desc" ]] && printf '%s\n' "- Description: $stage_desc"
      [[ -n "$stage_model" ]] && printf '%s\n' "- Model: $stage_model"
    } >> "$plan_abs_path"
    echo "Created plan $plan_rel_path"
  else
    echo "Plan already exists: $plan_rel_path"
  fi

  entry="    {\n      \"id\": \"$stage_label\",\n      \"runtime\": \"$runtime\",\n      \"agent\": \"$agent\",\n      \"agentSource\": \"$agent_source\",\n      \"plan\": \"$plan_rel_path\",\n      \"artifacts\": [\n        {\n          \"path\": \"$artifact_path\",\n          \"required\": true\n        }\n      ]"
  if [[ -n "$stage_desc" ]]; then
    desc_json="$(printf '%s' "$stage_desc" | escape_json)"
    entry="$entry,\n      \"description\": $desc_json"
  fi
  if [[ -n "$stage_model" ]]; then
    model_json="$(printf '%s' "$stage_model" | escape_json)"
    entry="$entry,\n      \"model\": $model_json"
  fi

  if [[ "$stage_label" == "$loop_stage" ]]; then
    entry="$entry,\n      \"loopControl\": {\n        \"loopBackTo\": \"$loop_back\",\n        \"maxIterations\": $loop_iterations\n      }"
  fi

  entry="$entry\n    }"
  stage_entries+=("$entry")
done

name_json="$(printf '%s' "$pipeline_name" | escape_json)"
namespace_json="$(printf '%s' "$namespace" | escape_json)"
description_json="$(printf '%s' "$description" | escape_json)"

printf '{\n  "name": %s,\n  "namespace": %s,\n  "description": %s,\n  "stages": [\n' "$name_json" "$namespace_json" "$description_json" > "$orch_file"

for idx in "${!stage_entries[@]}"; do
  printf '%b' "${stage_entries[$idx]}" >> "$orch_file"
  if (( idx < total_steps - 1 )); then
    printf ',\n' >> "$orch_file"
  else
    printf '\n' >> "$orch_file"
  fi
done

printf '  ]\n}\n' >> "$orch_file"

echo -e "\nCreated orchestration $orch_file with ${total_steps} stage(s)."
echo "Edit the plans under $plan_dir, add TODOs, and run:"
echo ".ralph/orchestrator.sh --orchestration $orch_file"
echo ""
echo "Generated prompt for creating TODOs in stage plans:"
echo "-----"
echo "Create actionable TODO checklists for this orchestration pipeline using .ralph/plan.template as the checklist style reference."
echo ""
echo "Namespace: $namespace"
echo "Orchestration JSON: $orch_file"
echo "Artifact directory: .agents/artifacts/$namespace/"
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
echo "- Artifact expectations under .agents/artifacts/$namespace/"
echo "-----"
