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
  pipeline_description_default="Multi-stage pipeline for $pipeline_name"
  read -rp "Description [default $pipeline_description_default]: " description_input
  pipeline_description="${description_input:-$pipeline_description_default}"
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

choose_stage_id_from_list() {
  local prompt="$1"
  local allow_empty="${2:-0}"
  local stage_opts=("$@")
  stage_opts=("${stage_opts[@]:2}")
  local answer picked
  local idx=1
  local stage
  echo "Available stages: ${stage_opts[*]}" >&2
  if [[ "$allow_empty" == "1" ]]; then
    printf '   0) none\n' >&2
  fi
  for stage in "${stage_opts[@]}"; do
    printf '  %2d) %s\n' "$idx" "$stage" >&2
    idx=$((idx + 1))
  done
  while true; do
    read -rp "$prompt" answer
    if [[ -z "$answer" ]]; then
      if [[ "$allow_empty" == "1" ]]; then
        printf ''
        return
      fi
      echo "Selection is required." >&2
      continue
    fi
    if [[ "$allow_empty" == "1" && "$answer" =~ ^[Nn][Oo][Nn][Ee]$ ]]; then
      printf ''
      return
    fi
    if [[ "$allow_empty" == "1" && "$answer" == "0" ]]; then
      printf ''
      return
    fi
    if [[ "$answer" =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= ${#stage_opts[@]} )); then
      picked="${stage_opts[$((answer - 1))]}"
      printf '%s' "$picked"
      return
    fi
    answer="$(sanitize "$answer")"
    for stage in "${stage_opts[@]}"; do
      if [[ "$answer" == "$stage" ]]; then
        printf '%s' "$stage"
        return
      fi
    done
    echo "Invalid stage selection. Choose a listed number or stage id." >&2
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

  printf 'Available %s agents:\n' "$runtime" >&2
  local idx=1
  local default_index=1
  local agent
  if [[ ${#agents[@]} -gt 0 ]]; then
    for agent in "${agents[@]}"; do
      [[ "$agent" == "$default" ]] && default_index="$idx"
      printf '  %2d) %s\n' "$idx" "$agent" >&2
      idx=$((idx + 1))
    done
  else
    echo "  (no prebuilt agents found)" >&2
  fi
  local custom_index="$idx"
  printf '  %2d) custom\n' "$custom_index" >&2
  echo "Pick custom to use runtime defaults and choose a model." >&2

  local answer
  while true; do
    read -rp "Select existing agent number [default $default_index]: " answer
    answer="${answer:-$default_index}"
    if [[ "$answer" =~ ^[0-9]+$ ]] && (( answer == custom_index )); then
      local custom_model
      custom_model="$(pick_model_for_runtime "$runtime" | tr -d '\n')"
      printf '%s\t1\t%s' "custom" "$custom_model"
      return
    fi
    if [[ "$answer" =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= ${#agents[@]} )); then
      printf '%s\t0\t' "${agents[$((answer - 1))]}"
      return
    fi
    answer="$(sanitize "$answer")"
    if [[ "$answer" == "custom" ]]; then
      local custom_model
      custom_model="$(pick_model_for_runtime "$runtime" | tr -d '\n')"
      printf '%s\t1\t%s' "custom" "$custom_model"
      return
    fi
    echo "Invalid selection. Enter a listed number or 'custom'." >&2
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
  python3 - <<'PY' "${1-}"
import json,sys
print(json.dumps(sys.argv[1]))
PY
}

supports_color=0
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
  colors="$(tput colors 2>/dev/null || printf '0')"
  if [[ "${colors:-0}" -ge 8 ]]; then
    supports_color=1
  fi
fi
if (( supports_color == 1 )); then
  c_reset="$(tput sgr0)"
  c_bold="$(tput bold)"
  c_blue="$(tput setaf 4)"
  c_yellow="$(tput setaf 3)"
else
  c_reset=""
  c_bold=""
  c_blue=""
  c_yellow=""
fi

print_info() {
  printf '%s%s%s%s\n' "$c_blue" "$c_bold" "$1" "$c_reset"
}

print_hint() {
  printf '%s%s%s\n' "$c_yellow" "$1" "$c_reset"
}

print_step() {
  printf '\n%s%s[%s]%s %s\n' "$c_blue" "$c_bold" "$1" "$c_reset" "$2"
}

echo "Note: this wizard copies .ralph/plan.template and scaffolds .agents/orchestration-plans/<namespace> plus artifacts."

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
  echo "No stages configured" >&2
  exit 1
fi

stage_runtimes=()
stage_agents=()
stage_agent_sources=()
stage_descriptions=()
stage_models=()
stage_input_sources=()

print_step "3/6" "Configure each stage"
print_hint "- For each stage, pick where it runs and which helper agent to use."
print_hint "- Pick 'custom' if you want to choose a model yourself."
for stage in "${stages[@]}"; do
  stage_id="$(sanitize "$stage")"
  [[ -n "$stage_id" ]] || { echo "Stage \"$stage\" sanitizes to empty; skip" >&2; exit 1; }
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
done

description="${pipeline_description:-Multi-stage pipeline for $pipeline_name}"
if [[ -z "$pipeline_name" ]]; then
  pipeline_name="$namespace"
fi
if [[ -z "$namespace" ]]; then
  namespace="$(sanitize "$pipeline_name")"
fi

stage_ids=()
for stage in "${stages[@]}"; do
  stage_ids+=("$(sanitize "$stage")")
done

print_step "4/6" "Stage input dependencies"
print_info "Choose stage inputs (writes to: inputFromStages)"
print_hint "- Use this so a stage knows which earlier artifacts to read."
print_hint "- This is how one agent uses output from a previous agent."
print_hint "- Example: plan stage artifacts -> implementation stage."
print_hint "- Example: implementation artifacts -> qa or code-review stage."
print_hint "- Type numbers or stage names, with commas or spaces."
print_hint "- Type 'none' for no handoff, or Enter for the default."
read -rp "Set custom stage inputs? (inputFromStages) [y/N]: " handoff_choice
if [[ "$handoff_choice" =~ ^[Yy] ]]; then
  print_info "Available stages for stage inputs (inputFromStages)"
  for idx in "${!stage_ids[@]}"; do
    printf '  %2d) %s\n' "$((idx + 1))" "${stage_ids[$idx]}"
  done
  print_hint "Type numbers or stage names. Commas and spaces both work."
  for idx in "${!stage_ids[@]}"; do
    current_stage="${stage_ids[$idx]}"
    default_input=""
    if (( idx > 0 )); then
      default_input="${stage_ids[$((idx - 1))]}"
    fi
    read -rp "Which earlier stages should \"$current_stage\" read from? (inputFromStages${default_input:+, default $default_input}; use 'none' for no input): " input_line
    if [[ -z "$input_line" ]]; then
      input_line="$default_input"
    fi
    parsed_inputs=()
    normalized_input="$(printf '%s' "$input_line" | tr ',' ' ')"
    if [[ -n "$normalized_input" ]]; then
      IFS=' ' read -r -a raw_inputs <<< "$normalized_input"
      for raw_input in "${raw_inputs[@]-}"; do
        raw_input="$(printf '%s' "$raw_input" | tr -d '[:space:]')"
        if [[ "$raw_input" =~ ^[0-9]+$ ]] && (( raw_input >= 1 && raw_input <= ${#stage_ids[@]} )); then
          candidate="${stage_ids[$((raw_input - 1))]}"
        else
          candidate="$(sanitize "$raw_input")"
        fi
        [[ -n "$candidate" ]] || continue
        if [[ "$candidate" == "none" || "$candidate" == "no-input" || "$candidate" == "no-inputs" ]]; then
          parsed_inputs=()
          break
        fi
        if [[ "$candidate" == "$current_stage" ]]; then
          echo "Ignoring self-reference for $current_stage in inputFromStages." >&2
          continue
        fi
        is_valid=0
        for stage_opt in "${stage_ids[@]}"; do
          if [[ "$candidate" == "$stage_opt" ]]; then
            is_valid=1
            break
          fi
        done
        if (( is_valid == 1 )); then
          already_added=0
          for existing in "${parsed_inputs[@]-}"; do
            if [[ "$existing" == "$candidate" ]]; then
              already_added=1
              break
            fi
          done
          (( already_added == 0 )) && parsed_inputs+=("$candidate")
        else
          echo "Ignoring unknown stage id \"$candidate\" for $current_stage input mapping." >&2
        fi
      done
    fi
    if [[ ${#parsed_inputs[@]} -gt 0 ]]; then
      stage_input_sources+=("$(IFS=,; printf '%s' "${parsed_inputs[*]}")")
    else
      stage_input_sources+=("")
    fi
  done
else
  for idx in "${!stage_ids[@]}"; do
    if (( idx == 0 )); then
      stage_input_sources+=("")
    else
      stage_input_sources+=("${stage_ids[$((idx - 1))]}")
    fi
  done
fi

loop_sources=()
loop_targets=()
loop_max_iterations=()
print_step "5/6" "Optional loop rules"
print_hint "- Use loop rules for review/testing stages that may find issues."
print_hint "- If a review/test stage finds a problem, it can send work back."
print_hint "- If review/test says everything is good, pipeline moves forward."
print_hint "- This writes to loopControl (loopBackTo + maxIterations) in JSON."
print_hint "- You can set loops quickly with a list, or go stage-by-stage."
print_hint "- Quick list examples: 2,4 or review,qa (choose loop source stages)."
print_hint "- Then pick where each source stage should send work back."
print_hint "- In loop prompts, Enter (or 0/none) means no loop."
read -rp "Add loop rules? (loopControl) [y/N]: " loop_choice
if [[ "$loop_choice" =~ ^[Yy] ]]; then
  print_info "Loop setup mode (loopControl)"
  print_hint "1) Pick source stages in one line, then configure each picked stage."
  print_hint "2) Walk every stage one-by-one and choose loop targets."
  read -rp "Choose mode [2]: " loop_mode
  loop_mode="${loop_mode:-2}"
  if [[ "$loop_mode" == "1" ]]; then
    echo "Available stages for loop sources:" >&2
    for idx in "${!stage_ids[@]}"; do
      printf '  %2d) %s\n' "$((idx + 1))" "${stage_ids[$idx]}" >&2
    done
    read -rp "Stages that should loop (numbers/names, comma or space; Enter/none for no loops): " loop_sources_line
    loop_sources_line="${loop_sources_line:-none}"
    normalized_sources="$(printf '%s' "$loop_sources_line" | tr ',' ' ')"
    selected_loop_sources=()
    IFS=' ' read -r -a source_tokens <<< "$normalized_sources"
    for source_token in "${source_tokens[@]-}"; do
      source_token="$(printf '%s' "$source_token" | tr -d '[:space:]')"
      [[ -n "$source_token" ]] || continue
      if [[ "$source_token" =~ ^[Nn][Oo][Nn][Ee]$ ]]; then
        selected_loop_sources=()
        break
      fi
      if [[ "$source_token" =~ ^[0-9]+$ ]] && (( source_token >= 1 && source_token <= ${#stage_ids[@]} )); then
        source_stage="${stage_ids[$((source_token - 1))]}"
      else
        source_stage="$(sanitize "$source_token")"
      fi
      is_valid=0
      for stage_opt in "${stage_ids[@]}"; do
        if [[ "$source_stage" == "$stage_opt" ]]; then
          is_valid=1
          break
        fi
      done
      if (( is_valid == 0 )); then
        echo "Ignoring unknown loop source \"$source_token\"." >&2
        continue
      fi
      already_added=0
      for existing_source in "${selected_loop_sources[@]-}"; do
        if [[ "$existing_source" == "$source_stage" ]]; then
          already_added=1
          break
        fi
      done
      (( already_added == 0 )) && selected_loop_sources+=("$source_stage")
    done

    for loop_stage in "${selected_loop_sources[@]-}"; do
      echo "" >&2
      loop_back="$(choose_stage_id_from_list "Send \"$loop_stage\" back to which stage? (loopBackTo, number/id, Enter for none): " 1 "${stage_ids[@]}")"
      if [[ -z "$loop_back" ]]; then
        echo "No loop target set for $loop_stage. Skipping this loop rule." >&2
        continue
      fi
      read -rp "Max iterations for \"$loop_stage\" [default 2]: " loop_iterations_input
      loop_iterations="${loop_iterations_input:-2}"
      if ! [[ "$loop_iterations" =~ ^[0-9]+$ ]]; then
        echo "Invalid number. Using 2." >&2
        loop_iterations=2
      fi
      loop_sources+=("$loop_stage")
      loop_targets+=("$loop_back")
      loop_max_iterations+=("$loop_iterations")
    done
  else
    for loop_stage in "${stage_ids[@]}"; do
      echo "" >&2
      loop_back="$(choose_stage_id_from_list "Send \"$loop_stage\" back to which stage? (loopBackTo, number/id, Enter for none): " 1 "${stage_ids[@]}")"
      if [[ -z "$loop_back" ]]; then
        continue
      fi
      read -rp "Max iterations for \"$loop_stage\" [default 2]: " loop_iterations_input
      loop_iterations="${loop_iterations_input:-2}"
      if ! [[ "$loop_iterations" =~ ^[0-9]+$ ]]; then
        echo "Invalid number. Using 2." >&2
        loop_iterations=2
      fi
      loop_sources+=("$loop_stage")
      loop_targets+=("$loop_back")
      loop_max_iterations+=("$loop_iterations")
    done
  fi
fi

print_step "6/6" "Generate orchestration files"
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
  stage_input_list="${stage_input_sources[$idx]}"
  if [[ ! -f "$plan_abs_path" ]]; then
    plan_title="$(printf '%s %s stage plan for %s' "$namespace" "$stage_label" "$pipeline_name")"
    sed "s/PLAN_TITLE_HERE/$(escape_sed "$plan_title")/" "$plan_template" > "$plan_abs_path"
    {
      printf '\n## Stage overview\n- Stage: %s\n- Runtime: %s\n- Agent: %s\n' "$stage_label" "$runtime" "$agent"
      [[ -n "$stage_desc" ]] && printf '%s\n' "- Description: $stage_desc"
      [[ -n "$stage_input_list" ]] && printf '%s\n' "- Input from stages: $stage_input_list"
      [[ -n "$stage_model" ]] && printf '%s\n' "- Model: $stage_model"
    } >> "$plan_abs_path"
    echo "Created plan $plan_rel_path"
  else
    echo "Plan already exists: $plan_rel_path"
  fi

  entry="    {\n      \"id\": \"$stage_label\",\n      \"runtime\": \"$runtime\",\n      \"agent\": \"$agent\",\n      \"agentSource\": \"$agent_source\",\n      \"plan\": \"$plan_rel_path\",\n      \"artifacts\": [\n        {\n          \"path\": \"$artifact_path\",\n          \"required\": true\n        }\n      ]"
  if [[ -n "$stage_desc" ]]; then
    desc_json="$(escape_json "$stage_desc")"
    entry="$entry,\n      \"description\": $desc_json"
  fi
  if [[ -n "$stage_model" ]]; then
    model_json="$(escape_json "$stage_model")"
    entry="$entry,\n      \"model\": $model_json"
  fi

  if [[ -n "$stage_input_list" ]]; then
    input_artifact_entries=()
    IFS=',' read -r -a input_stage_arr <<< "$stage_input_list"
    for input_stage in "${input_stage_arr[@]}"; do
      input_stage="$(sanitize "$input_stage")"
      [[ -z "$input_stage" ]] && continue
      input_artifact_base="$(artifact_file_for_stage "$input_stage")"
      input_artifact_entries+=("        {\n          \"path\": \".agents/artifacts/$namespace/$input_artifact_base\"\n        }")
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

  for loop_idx in "${!loop_sources[@]}"; do
    if [[ "$stage_label" == "${loop_sources[$loop_idx]}" ]]; then
      entry="$entry,\n      \"loopControl\": {\n        \"loopBackTo\": \"${loop_targets[$loop_idx]}\",\n        \"maxIterations\": ${loop_max_iterations[$loop_idx]}\n      }"
      break
    fi
  done

  entry="$entry\n    }"
  stage_entries+=("$entry")
done

name_json="$(escape_json "$pipeline_name")"
namespace_json="$(escape_json "$namespace")"
description_json="$(escape_json "$description")"

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

print_info "Created orchestration $orch_file with ${total_steps} stage(s)."
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
