#!/usr/bin/env bash
# Wizard prompt helpers shared by orchestration-wizard.sh.
#
# Public interface (selection and I/O helpers):
#   ralph_menu_select -- menu selection helper from menu-select.sh.
#   runtime_default, agent_default, artifact_file_for_stage, agent_dir_for_runtime -- defaults per stage/runtime.
#   ralph_internal_wizard_sanitize, list_agents, escape_sed, escape_json -- string and agent listing utilities.
#   read_pipeline_info, read_stages, choose_stage_id_from_list -- wizard flow state.
#   select_runtime, pick_model_for_runtime, select_model_override, select_agent, agent_model_default -- picks.
#   print_info, print_hint, print_step, offer_prompt_execution -- TTY messaging and optional run hint.

# shellcheck source=/Users/joshuajancula/Documents/projects/ralph/bundle/.ralph/bash-lib/menu-select.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/menu-select.sh"

default_stages=("research" "architecture" "implementation" "code-review" "qa")
pipeline_session_strategy_default="fresh"
pipeline_session_strategy_all_stages="true"

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
    opencode) printf '.opencode/agents' ;;
    *)
      printf '.cursor/agents'
      ;;
  esac
}

ralph_internal_wizard_sanitize() {
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
  name="$(ralph_prompt_text "Pipeline name (human-friendly)")"
  [[ -n "$name" ]] || ralph_die "Pipeline name is required"
  default_ns="$(ralph_internal_wizard_sanitize "$name")"
  [[ -n "$default_ns" ]] || default_ns="pipeline"
  ns="$(ralph_prompt_text "Namespace" "$default_ns")"
  ns="$(ralph_internal_wizard_sanitize "$ns")"
  [[ -n "$ns" ]] || ralph_die "Namespace cannot be empty after sanitization"
  pipeline_name="$name"
  namespace="$ns"
  pipeline_description_default="Multi-stage pipeline for $pipeline_name"
  description_input="$(ralph_prompt_text "Description" "$pipeline_description_default")"
  pipeline_description="$description_input"
  print_hint "Session strategy controls per-stage CLI session behavior."
  print_hint "fresh (default) = strict isolation, resume = continue context, reset = reuse session id with reset-oriented prompts."
  print_hint "resume/reset rely on Python 3 for robust session-id capture."
  pipeline_session_strategy_default="$(ralph_menu_select --prompt "Default session strategy" --default 1 -- "fresh" "resume" "reset")"
  if [[ "$pipeline_session_strategy_default" != "fresh" ]]; then
    print_hint "resume/reset can lower token cost on short iterative stage plans."
  fi
  session_strategy_scope_input="$(ralph_prompt_yesno "Use this session strategy for all stages" "y")"
  if [[ "$session_strategy_scope_input" == "y" ]]; then
    pipeline_session_strategy_all_stages="true"
  else
    pipeline_session_strategy_all_stages="false"
    print_hint "You can override session strategy per stage during stage configuration."
  fi
}

read_stages() {
  local default_csv known_csv
  # Build comma-separated default and known lists
  default_csv=""
  known_csv=""
  local IFS=','
  default_csv="${default_stages[*]}"
  known_csv="${default_stages[*]}"
  unset IFS
  
  local result
  result="$(ralph_prompt_list "Stages" "$default_csv" "$known_csv" "1")"
  
  selected_stages=()
  if [[ -z "$result" ]]; then
    return
  fi
  
  local IFS=','
  for raw in $result; do
    [[ -n "$raw" ]] || continue
    selected_stages+=("$raw")
  done
  unset IFS
}

# choose_stage_id_from_list -- specialized stage picker for loop targets.
# This stays bespoke (not using ralph_menu_select) because it supports:
#   - Empty/none selection via allow_empty parameter
#   - Both numeric indices and stage name matching
#   - Custom display with stage listing
#   - Zero/none as valid selection options for loop back-to targets
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
    answer="$(ralph_internal_wizard_sanitize "$answer")"
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
  local runtime options idx=1 default_index=1
  options=("cursor" "claude" "codex" "opencode")
  for opt in "${options[@]}"; do
    if [[ "$opt" == "$default" ]]; then
      default_index="$idx"
    fi
    idx=$((idx + 1))
  done
  runtime="$(ralph_menu_select --prompt "runtime for \"$stage\"" --default "$default_index" -- "${options[@]}")"
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
    opencode)
      if declare -F select_model_opencode >/dev/null 2>&1; then
        select_model_opencode --interactive
      fi
      ;;
  esac
}

select_model_override() {
  local runtime="$1"
  local agent="$2"
  local model_default="${3:-}"
  local choice picked_model

  local option1="use agent default"
  if [[ -n "$model_default" ]]; then
    option1="use agent default ($model_default)"
  fi

  choice="$(ralph_menu_select --prompt "model for \"$agent\"" --default 1 -- "$option1" "pick from list")"

  if [[ "$choice" == "pick from list" ]]; then
    picked_model="$(pick_model_for_runtime "$runtime" | tr -d '\n')"
    printf '%s' "$picked_model"
  else
    printf '%s' "$model_default"
  fi
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

  local options=()
  local default_index=1
  local agent
  if [[ ${#agents[@]} -gt 0 ]]; then
    for agent in "${agents[@]}"; do
      [[ "$agent" == "$default" ]] && default_index="$((${#options[@]} + 1))"
      options+=("$agent")
    done
  fi
  options+=("custom")

  local selected
  selected="$(ralph_menu_select --prompt "agent for \"$stage\"" --default "$default_index" -- "${options[@]}")"

  if [[ "$selected" == "custom" ]]; then
    local custom_model
    custom_model="$(pick_model_for_runtime "$runtime" | tr -d '\n')"
    printf '%s\t1\t%s' "custom" "$custom_model"
    return
  fi

  printf '%s\t0\t' "$selected"
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

offer_prompt_execution() {
  if [[ ! -t 0 || ! -t 1 ]]; then
    return
  fi
  local answer
  answer="$(ralph_prompt_yesno "Execute the generated prompt now to populate these stage plans" "n")"
  if [[ "$answer" == "n" ]]; then
    return
  fi

  local prompt_plan_abs="$plan_dir/${namespace}-todo-prompt.plan.md"
  local prompt_plan_rel
  if [[ "$prompt_plan_abs" == "$workspace/"* ]]; then
    prompt_plan_rel="${prompt_plan_abs#$workspace/}"
  else
    prompt_plan_rel="$prompt_plan_abs"
  fi

  {
    cat <<EOF
# Generate TODO checklists for $pipeline_name
Create actionable TODO checklists for this orchestration pipeline using .ralph/plan.template as the checklist style reference.
Fill these stage plan files with concrete TODOs (- [ ] / - [x]), files to edit, validation commands, and expected artifacts:
EOF
    for plan_path in "${generated_plan_paths[@]}"; do
      printf '%s\n' "- $plan_path"
    done
    cat <<EOF

Namespace: $namespace
Orchestration JSON: $orch_file
Artifact directory: .ralph-workspace/artifacts/$namespace/

Each stage plan should include:
- Implementation steps tied to real files or modules
- Verification commands (lint/tests/build as applicable)
- Clear handoff expectations for the next stage
- Artifact expectations under .ralph-workspace/artifacts/$namespace/

## Stage context
EOF
    for idx in "${!generated_plan_paths[@]}"; do
      local stage_label stage_loc stage_runtime stage_agent stage_model stage_desc stage_input artifact_path
      stage_label="${stage_ids[$idx]}"
      stage_loc="${generated_plan_paths[$idx]}"
      stage_runtime="${stage_runtimes[$idx]}"
      stage_agent="${stage_agents[$idx]}"
      stage_model="${stage_models[$idx]}"
      stage_desc="${stage_descriptions[$idx]}"
      stage_input="${stage_input_sources[$idx]}"
      artifact_path=".ralph-workspace/artifacts/$namespace/$(artifact_file_for_stage "$stage_label")"
      printf -- '- `%s`: stage %s (runtime %s, agent %s' "$stage_loc" "$stage_label" "$stage_runtime" "$stage_agent"
      if [[ -n "$stage_model" ]]; then
        printf ', model %s' "$stage_model"
      fi
      printf ')\n'
      if [[ -n "$stage_desc" ]]; then
        printf '  Description: %s\n' "$stage_desc"
      fi
      if [[ -n "$stage_input" ]]; then
        printf '  Input from stages: %s\n' "$stage_input"
      fi
      printf '  Artifact: %s\n' "$artifact_path"
    done
    printf '\n## TODOs\n'
    for idx in "${!generated_plan_paths[@]}"; do
      local stage_label stage_loc artifact_path stage_input
      stage_label="${stage_ids[$idx]}"
      stage_loc="${generated_plan_paths[$idx]}"
      artifact_path=".ralph-workspace/artifacts/$namespace/$(artifact_file_for_stage "$stage_label")"
      stage_input="${stage_input_sources[$idx]}"
      printf -- '- [ ] Update `%s` with actionable TODOs for stage %s: mention the files or modules that will be touched, list validation commands, and describe the artifact at %s. Input stage(s): %s. Follow .ralph/plan.template formatting so the orchestrator can verify outputs.\n' "$stage_loc" "$stage_label" "$artifact_path" "${stage_input:-none}"
    done
  } > "$prompt_plan_abs"

  print_info "Starting run-plan for the TODO prompt plan (same runner, agent, and model prompts as a normal plan)."
  print_hint "You will choose Cursor vs Claude vs Codex, then prebuilt agent vs direct model, then model if needed."
  if [[ ! -f "$script_dir/run-plan.sh" ]]; then
    echo "run-plan.sh not found at $script_dir/run-plan.sh" >&2
    return 1
  fi
  (
    cd "$workspace" || exit 1
    bash "$script_dir/run-plan.sh" --plan "$prompt_plan_rel"
  )

  if [[ -n "${orch_file:-}" ]]; then
    echo ""
    echo "Next step: run the orchestration pipeline:"
    echo ".ralph/orchestrator.sh --orchestration $orch_file"
  fi
}

# Prompts the user to configure handoff declarations between stages.
# Populates: stage_handoff_targets, stage_handoff_kinds
configure_handoff_declarations() {
  local stage_count=${#stages[@]}
  
  handoff_prompt_response="$(ralph_prompt_yesno "Configure handoffs between stages" "n")"
  
  if [[ ! "$handoff_prompt_response" =~ ^[Yy] ]]; then
    print_info "Skipping handoff configuration."
    return 0
  fi
  
  print_info "Configuring handoffs..."
  
  for idx in "${!stages[@]}"; do
    local current_stage="${stages[$idx]}"
    local current_stage_id="$(ralph_internal_wizard_sanitize "$current_stage")"
    
    # Show available target stages (stages after current)
    local target_options=()
    for (( target_idx = idx + 1; target_idx < stage_count; target_idx++ )); do
      target_options+=("$(ralph_internal_wizard_sanitize "${stages[$target_idx]}")")
    done
    
    if (( ${#target_options[@]} == 0 )); then
      print_info "  $current_stage_id: no downstream stages for handoff"
      stage_handoff_targets+=("")
      stage_handoff_kinds+=("")
      continue
    fi
    
    enable_handoff="$(ralph_prompt_yesno "Enable handoff from \"$current_stage_id\"" "n")"
    
    if [[ "$enable_handoff" == "y" ]]; then
      local target_stage
      if (( ${#target_options[@]} == 1 )); then
        target_stage="${target_options[0]}"
        print_info "    Using default target: $target_stage"
      else
        target_stage="$(ralph_menu_select --prompt "target for \"$current_stage_id\"" --default 1 -- "${target_options[@]}")"
      fi
      
      stage_handoff_targets+=("$target_stage")
      stage_handoff_kinds+=("handoff")
    else
      stage_handoff_targets+=("")
      stage_handoff_kinds+=("")
    fi
  done
}
