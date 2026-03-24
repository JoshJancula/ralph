#!/usr/bin/env bash
# Wizard prompt helpers shared by orchestration-wizard.sh.
#
# Public interface (selection and I/O helpers):
#   runtime_default, agent_default, artifact_file_for_stage, agent_dir_for_runtime -- defaults per stage/runtime.
#   ralph_internal_wizard_sanitize, list_agents, escape_sed, escape_json -- string and agent listing utilities.
#   read_pipeline_info, read_stages, choose_stage_id_from_list -- wizard flow state.
#   select_runtime, pick_model_for_runtime, select_model_override, select_agent, agent_model_default -- picks.
#   print_info, print_hint, print_step, offer_prompt_execution -- TTY messaging and optional run hint.

default_stages=("research" "architecture" "implementation" "code-review" "qa")
pipeline_resume_all_stages="false"

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
  read -rp "Pipeline name (human-friendly): " name
  [[ -n "$name" ]] || ralph_die "Pipeline name is required"
  default_ns="$(ralph_internal_wizard_sanitize "$name")"
  [[ -n "$default_ns" ]] || default_ns="pipeline"
  read -rp "Namespace [default $default_ns]: " ns
  ns="${ns:-$default_ns}"
  ns="$(ralph_internal_wizard_sanitize "$ns")"
  [[ -n "$ns" ]] || ralph_die "Namespace cannot be empty after sanitization"
  pipeline_name="$name"
  namespace="$ns"
  pipeline_description_default="Multi-stage pipeline for $pipeline_name"
  read -rp "Description [default $pipeline_description_default]: " description_input
  pipeline_description="${description_input:-$pipeline_description_default}"
  read -rp "Enable session resume for all stages? (y/N) " session_resume_input
  session_resume_input="${session_resume_input:-N}"
  if [[ "$session_resume_input" =~ ^[Yy] ]]; then
    pipeline_resume_all_stages="true"
  else
    pipeline_resume_all_stages="false"
  fi
  if [[ "$pipeline_resume_all_stages" != "true" ]]; then
    print_hint "You can enable session resume per stage while configuring each stage."
  fi
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
    answer="$(ralph_internal_wizard_sanitize "$answer")"
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

offer_prompt_execution() {
  if [[ ! -t 0 || ! -t 1 ]]; then
    return
  fi
  local answer
  read -rp "Execute the generated prompt now to populate these stage plans? (y/N): " answer
  if [[ ! "$answer" =~ ^[Yy]$ ]]; then
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
