#!/usr/bin/env bash
set -euo pipefail

workspace="$(pwd)"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plan_template="$script_dir/plan.template"

if [[ ! -f "$plan_template" ]]; then
  echo "plan template not found at $plan_template" >&2
  exit 1
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
  local runtime
  read -rp "Runtime for \"$stage\" [cursor/claude/codex, default $default]: " runtime
  runtime="${runtime:-$default}"
  runtime="$(printf '%s' "$runtime" | tr '[:upper:]' '[:lower:]')"
  case "$runtime" in
    cursor|claude|codex) ;;
    *)
      echo "Invalid runtime; defaulting to $default" >&2
      runtime="$default"
      ;;
  esac
  printf '%s' "$runtime"
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

  if [[ ${#agents[@]} -gt 0 ]]; then
    printf 'Available %s agents:\n' "$runtime"
    local idx=1
    local agent
    for agent in "${agents[@]}"; do
      printf '  %2d) %s\n' "$idx" "$agent"
      idx=$((idx + 1))
    done
  fi

  local prompt="Agent for \"$stage\" [default $default]: "
  local answer
  read -rp "$prompt" answer
  if [[ -z "$answer" ]]; then
    printf '%s' "$default"
    return
  fi
  if [[ "$answer" =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= ${#agents[@]} )); then
    printf '%s' "${agents[$((answer - 1))]}"
  else
    printf '%s' "$answer"
  fi
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

for stage in "${stages[@]}"; do
  stage_id="$(sanitize "$stage")"
  [[ -n "$stage_id" ]] || { echo "Stage \"$stage\" sanitizes to empty; skip" >&2; exit 1; }
  printf '\nConfiguring stage "%s"\n' "$stage_id"
  runtime="$(select_runtime "$stage_id")"
  agent="$(select_agent "$runtime" "$stage_id")"
  stage_runtimes+=("$runtime")
  stage_agents+=("$agent")
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
total_steps=${#stages[@]}

for idx in "${!stages[@]}"; do
  step_number=$(printf "%02d" $((idx + 1)))
  stage_label="$(sanitize "${stages[$idx]}")"
  runtime="${stage_runtimes[$idx]}"
  agent="${stage_agents[$idx]}"

  plan_rel_path=".agents/orchestration-plans/$namespace/${namespace}-${step_number}-${stage_label}.plan.md"
  plan_abs_path="$workspace/$plan_rel_path"
  artifact_base="$(artifact_file_for_stage "$stage_label")"
  artifact_path=".agents/artifacts/$namespace/$artifact_base"

  if [[ ! -f "$plan_abs_path" ]]; then
    plan_title="$(printf '%s %s stage plan for %s' "$namespace" "$stage_label" "$pipeline_name")"
    sed "s/PLAN_TITLE_HERE/$(escape_sed "$plan_title")/" "$plan_template" > "$plan_abs_path"
    echo -e "\n## Stage overview\n- Stage: $stage_label\n- Runtime: $runtime\n- Agent: $agent" >> "$plan_abs_path"
    echo "Created plan $plan_rel_path"
  else
    echo "Plan already exists: $plan_rel_path"
  fi

  entry="    {\n      \"id\": \"$stage_label\",\n      \"runtime\": \"$runtime\",\n      \"agent\": \"$agent\",\n      \"plan\": \"$plan_rel_path\",\n      \"artifacts\": [\n        {\n          \"path\": \"$artifact_path\",\n          \"required\": true\n        }\n      ]"

  if [[ "$stage_label" == "$loop_stage" ]]; then
    entry="$entry,\n      \"loopControl\": {\n        \"loopBackTo\": \"$loop_back\",\n        \"maxIterations\": $loop_iterations\n      }"
  fi

  entry="$entry\n    }"
  stage_entries+=("$entry")
done

printf '{\n  "name": "%s",\n  "namespace": "%s",\n  "description": "%s",\n  "stages": [\n' "$pipeline_name" "$namespace" "$(printf '%s' "$description" | sed 's/"/\\"/g')" > "$orch_file"

for idx in "${!stage_entries[@]}"; do
  printf '%s' "${stage_entries[$idx]}" >> "$orch_file"
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
echo "Use the plan sample prompts in docs/AGENT-WORKFLOW.md to prompt agents for the TODOs."
