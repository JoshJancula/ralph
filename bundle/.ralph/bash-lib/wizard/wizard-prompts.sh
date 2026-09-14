#!/usr/bin/env bash
# Wizard prompt helpers shared by pipeline-wizard.sh.
#
# Public interface (selection and I/O helpers):
#   ralph_menu_select -- menu selection helper from menu-select.sh.
#   runtime_default, artifact_file_for_stage -- defaults per stage/runtime.
#   ralph_internal_wizard_sanitize, escape_sed, escape_json -- string utilities.
#   read_pipeline_info, read_workflow_info, read_stages, choose_stage_id_from_list -- wizard flow state.
#   select_runtime, select_role, select_native_subagents -- execution-dimension picks.
#   print_info, print_hint, print_step, offer_prompt_execution -- TTY messaging and optional run hint.
#   wizard_prompt_tooling_policy -- shared tooling-profile prompt for both wizard modes.

if [[ -z "${SCRIPT_DIR:-}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

# shellcheck source=bash-lib/menu-select.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../menu-select.sh"
# shellcheck source=bash-lib/tooling-profile.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../tooling-profile.sh"
# Roles were removed; keep select_role as a soft stub when role-source is absent.
_wizard_role_source="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../role/role-source.sh"
if [[ -f "$_wizard_role_source" ]]; then
  # shellcheck source=bash-lib/role/role-source.sh
  source "$_wizard_role_source"
fi
unset _wizard_role_source

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

ralph_internal_wizard_sanitize() {
  local value="$1"
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
  value="$(printf '%s' "$value" | tr -c 'a-z0-9-' '-')"
  value="$(printf '%s' "$value" | sed 's/-\+/-/g; s/^-//; s/-$//')"
  printf '%s' "$value"
}

# wizard_workflow_name_valid <name>
# Strict workflow file basename validation. Never sanitize an invalid name into
# a different valid one.
wizard_workflow_name_valid() {
  [[ -n "${1:-}" && "$1" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]
}

read_workflow_info() {
  local name desc
  name="$(ralph_prompt_text "Workflow name (lowercase letters, digits, hyphens)")"
  [[ -n "$name" ]] || ralph_die "Workflow name is required"
  if [[ "$name" == /* || "$name" == *"/"* || "$name" == *".."* || "$name" == *" "* || "$name" == *$'\t'* || "$name" == *"_"* ]]; then
    ralph_die "invalid workflow name: $name (use lowercase letters, digits, and hyphens only)"
  fi
  if ! wizard_workflow_name_valid "$name"; then
    ralph_die "invalid workflow name: $name (use lowercase letters, digits, and hyphens only)"
  fi
  workflow_name="$name"
  pipeline_name="$name"
  namespace="$name"
  pipeline_description_default="Reusable workflow for $pipeline_name"
  description_input="$(ralph_prompt_text "Description" "$pipeline_description_default")"
  pipeline_description="$description_input"
  print_hint "Session strategy controls per-stage CLI session behavior."
  print_hint "fresh (default) = strict isolation, resume = continue context, reset = reuse session id with reset-oriented prompts, compact = reuse session id with compact command prefix."
  print_hint "resume/reset/compact rely on Python 3 for robust session-id capture."
  pipeline_session_strategy_default="$(ralph_menu_select --prompt "Default session strategy" --default 1 -- "fresh" "resume" "reset" "compact")"
  if [[ "$pipeline_session_strategy_default" != "fresh" ]]; then
    print_hint "resume/reset/compact can lower token cost on short iterative stage plans."
  fi
  session_strategy_scope_input="$(ralph_prompt_yesno "Use this session strategy for all stages" "y")"
  if [[ "$session_strategy_scope_input" == "y" ]]; then
    pipeline_session_strategy_all_stages="true"
  else
    pipeline_session_strategy_all_stages="false"
    print_hint "You can override session strategy per stage during stage configuration."
  fi
}

# wizard_role_catalog -- print the resolved role catalog for the current
# project. A role is guidance selected
# by the plan, while the runtime supplies its actual agent.
wizard_role_catalog() {
  if ! declare -F ralph_role_list_resolved >/dev/null 2>&1; then
    return 0
  fi
  local project_root="${workspace:-$(pwd)}"
  local bundle_root
  bundle_root="$(cd "${SCRIPT_DIR:?SCRIPT_DIR must be set}/.." && pwd)"
  ralph_role_list_resolved "$project_root" "$bundle_root"
}

# select_role <stage> -- select optional instruction-only SDLC guidance.
# The catalog is resolved at prompt time so project roles shadow bundled roles
# and newly-created project roles appear without a hardcoded menu.
# When the role library is absent, returns empty (no role).
select_role() {
  local stage="$1"
  if ! declare -F ralph_role_list_resolved >/dev/null 2>&1; then
    return 0
  fi
  local role_catalog line role kind description
  local -a options=(none) menu_args=(--desc "No optional SDLC role instructions.")

  role_catalog="$(wizard_role_catalog)" || ralph_die "unable to resolve SDLC roles"
  while IFS=$'\t' read -r role kind description; do
    [[ -n "$role" ]] || continue
    options+=("$role")
    menu_args+=(--desc "${kind} role: ${description}")
  done <<< "$role_catalog"

  local selected
  selected="$(ralph_menu_select --prompt "Optional SDLC role for \"$stage\"" \
    --default 1 "${menu_args[@]}" -- "${options[@]}")"
  [[ "$selected" == "none" ]] && return 0
  printf '%s' "$selected"
}

# select_native_subagents <stage> -- graph/orchestration native runtime
# subagent policy. The default is off; unlike a role,
# this is an execution policy and is rendered as its own field.
select_native_subagents() {
  local stage="$1"
  wizard_annotated_menu nativeSubagents \
    "Native runtime subagents for \"$stage\"" 1 "off" "inherit"
}

# Keep the routing dimensions visible as separate lines. Roles are instruction
# guidance; model selection remains owned by the selected runtime unless an
# explicit stage override is authored.
wizard_print_runtime_role_model_subagents() {
  local label="$1" runtime="$2" role="$3" native_subagents="$4"
  print_hint "$label runtime: ${runtime:-runtime default}"
  print_hint "$label role: ${role:-none}"
  print_hint "$label model source: runtime saved/default"
  print_hint "$label native subagents: ${native_subagents:-off}"
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
  print_hint "fresh (default) = strict isolation, resume = continue context, reset = reuse session id with reset-oriented prompts, compact = reuse session id with compact command prefix."
  print_hint "resume/reset/compact rely on Python 3 for robust session-id capture."
  pipeline_session_strategy_default="$(ralph_menu_select --prompt "Default session strategy" --default 1 -- "fresh" "resume" "reset" "compact")"
  if [[ "$pipeline_session_strategy_default" != "fresh" ]]; then
    print_hint "resume/reset/compact can lower token cost on short iterative stage plans."
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
  local default_csv known_csv template_default
  # Build comma-separated default and known lists
  default_csv=""
  known_csv=""
  template_default="$(wizard_workflow_template_stage_default_csv 2>/dev/null || true)"
  if [[ -n "$template_default" ]]; then
    default_csv="$template_default"
    known_csv="$template_default"
  else
    local IFS=','
    default_csv="${default_stages[*]}"
    known_csv="${default_stages[*]}"
    unset IFS
  fi
  
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

# read_graph_nodes -- prompts for graph node ids (mirrors read_stages).
# Populates: selected_stages.
read_graph_nodes() {
  local default_csv template_default
  default_csv="research,implement,review"
  template_default="$(wizard_workflow_template_stage_default_csv 2>/dev/null || true)"
  if [[ -n "$template_default" ]]; then
    default_csv="$template_default"
  fi

  local result
  result="$(ralph_prompt_list "Nodes" "$default_csv" "$default_csv" "1")"

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

# select_depends_on <node_id> <known_csv>
# Multi-select dependsOn restricted to already-defined node ids; no custom entries,
# empty answer means no dependencies (valid for source nodes).
select_depends_on() {
  local node_id="$1"
  local known_csv="${2:-}"
  local default_csv=""
  if [[ -z "$known_csv" ]]; then
    printf ''
    return 0
  fi
  default_csv="$(wizard_workflow_template_depends_default_csv "$node_id" 2>/dev/null || true)"
  ralph_prompt_list "Depends on (for \"$node_id\")" "$default_csv" "$known_csv" "0"
}

# wizard_annotated_menu <choiceHelp-group> <prompt> <default-index> <option>...
# Uses the contract-annotated menu when the graph authoring contract is loadable,
# otherwise falls back to a plain numbered menu. This lets shared pickers such as
# workspace mode and session strategy explain themselves in graph mode without
# making the orchestration-only paths depend on the contract or on jq.
wizard_annotated_menu() {
  if declare -F wizard_graph_menu >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 \
    && [[ -f "$(wizard_graph_authoring_contract_path 2>/dev/null)" ]]; then
    wizard_graph_menu "$@"
    return
  fi
  local prompt="$2" default_idx="$3"
  shift 3
  ralph_menu_select --prompt "$prompt" --default "$default_idx" -- "$@"
}

# select_workspace_mode <node_id>
# Prompts snapshot|worktree|shared for a graph agent node. shared requires an
# interactive risk acknowledgement, mirroring create-plan.sh's
# --acknowledge-shared-mutation-risk flag gate; declining dies rather than
# silently downgrading the mode.
select_workspace_mode() {
  local node_id="$1"
  local mode ack
  mode="$(wizard_annotated_menu workspaceMode "Where should \"$node_id\" write files" 1 "snapshot" "worktree" "shared")"
  if [[ "$mode" == "shared" ]]; then
    print_hint "shared mode uses the caller's live workspace directly; concurrent writers can race."
    ack="$(ralph_prompt_yesno "Acknowledge shared-mutation risk for \"$node_id\"" "n")"
    [[ "$ack" == "y" ]] || ralph_die "shared workspaceMode requires acknowledging the risk for \"$node_id\""
  fi
  printf '%s' "$mode"
}

# configure_voters <node_id>
# Interactively collects voters for a consensus node. Appends rows to the
# caller's cp_voter_node/cp_voter_id/cp_voter_runtime arrays.
# Native subagents are always forced off for voters at compile time, not
# prompted here.
configure_voters() {
  local node_id="$1"
  local add voter_id voter_runtime voter_count=0

  while true; do
    if (( voter_count >= 2 )); then
      add="$(ralph_prompt_yesno "Add another voter for \"$node_id\" ($voter_count so far)" "n")"
    else
      add="y"
      [[ "$voter_count" -eq 0 ]] && print_info "Configuring voters for consensus node \"$node_id\" (at least 2 recommended, each on a distinct runtime)"
    fi
    [[ "$add" == "y" ]] || break

    voter_id="$(ralph_prompt_text "Voter id" "voter-$((voter_count + 1))")"
    voter_runtime="$(select_runtime "$node_id-$voter_id")"
    wizard_print_runtime_role_model_subagents "Voter $voter_id" "$voter_runtime" "" "off"

    cp_voter_node+=("$node_id")
    cp_voter_id+=("$voter_id")
    cp_voter_runtime+=("$voter_runtime")
    cp_voter_model+=("")
    voter_count=$((voter_count + 1))
  done

  if (( voter_count == 0 )); then
    ralph_die "consensus node \"$node_id\" requires at least one voter"
  fi
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
    printf '%s' "$prompt" >&2
    ralph_ui_read_line answer
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
  options=("cursor" "claude" "codex" "opencode" "antigravity")
  for opt in "${options[@]}"; do
    if [[ "$opt" == "$default" ]]; then
      default_index="$idx"
    fi
    idx=$((idx + 1))
  done
  runtime="$(ralph_menu_select --prompt "runtime for \"$stage\"" --default "$default_index" -- "${options[@]}")"
  printf '%s' "$runtime"
}

select_session_strategy() {
  local stage="$1"
  local default="${2:-fresh}"
  local default_index=1
  case "$default" in
    resume) default_index=2 ;;
    reset) default_index=3 ;;
    compact) default_index=4 ;;
  esac
  wizard_annotated_menu sessionStrategy "Session strategy for \"$stage\"" "$default_index" "fresh" "resume" "reset" "compact"
}

select_context_budget() {
  local stage="$1"
  wizard_annotated_menu contextBudget "How much context should \"$stage\" get" 2 "full" "standard" "lean"
}

escape_json() {
  python3 "${SCRIPT_DIR}/python/wizard-prompts-escape-json.py" "${1-}"
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
  c_dim="$(tput dim 2>/dev/null || printf '')"
else
  c_reset=""
  c_bold=""
  c_blue=""
  c_yellow=""
  c_dim=""
fi

# ralph_menu_select renders with C_* (uppercase) but no wizard entry point
# defined them, so every wizard menu printed colorless and option descriptions
# had no dim treatment to separate them from the labels.
: "${C_G:=$c_blue}"
: "${C_Y:=$c_yellow}"
: "${C_BOLD:=$c_bold}"
: "${C_DIM:=$c_dim}"
: "${C_RST:=$c_reset}"

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
Create actionable TODO checklists for this orchestration pipeline using .ralph/plan-templates/classic.plan.template.md as the checklist style reference.
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
      printf -- '- [ ] Update `%s` with actionable TODOs for stage %s: mention the files or modules that will be touched, list validation commands, and describe the artifact at %s. Input stage(s): %s. Follow .ralph/plan-templates/classic.plan.template.md formatting so the orchestrator can verify outputs.\n' "$stage_loc" "$stage_label" "$artifact_path" "${stage_input:-none}"
    done
  } > "$prompt_plan_abs"

  print_info "Starting run-plan for the TODO prompt plan (same runner, agent, and model prompts as a normal plan)."
  print_hint "You will choose the runtime, optional SDLC role, and native model source."
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

# wizard_prompt_tooling_policy [stage-id...]
# Shared tooling-profile prompt used by both wizard modes (graph and
# orchestration). Profile names and descriptions come from
# tooling-profiles.json so the wizard never hardcodes the list.
#
# Flow:
#   1. "Configure tooling profiles?" (default yes). Declining leaves both
#      outputs empty so the caller omits `tooling` entirely.
#   2. Pick the default profile (ralph-compact preselected).
#   3. "Apply this profile to every stage?" (default yes). Declining walks the
#      already-collected stage ids and asks per stage, defaulting to the
#      selected default profile.
#
# Populates (caller-consumed):
#   wizard_tooling_default_profile -- selected default profile name, or empty.
#   wizard_tooling_overrides       -- array of "stage=profile" entries for the
#                                     stages that differ from the default.
#
# Stage ids come from the arguments; with no arguments the caller's `stages`
# array is used (sanitized), matching the inline orchestration flow.
wizard_prompt_tooling_policy() {
  wizard_tooling_default_profile=""
  wizard_tooling_overrides=()

  local -a stage_ids=("$@")
  if [[ ${#stage_ids[@]} -eq 0 ]] && declare -p stages >/dev/null 2>&1; then
    local stage
    for stage in "${stages[@]}"; do
      stage_ids+=("$(ralph_internal_wizard_sanitize "$stage")")
    done
  fi

  local configure
  configure="$(ralph_prompt_yesno "Configure tooling profiles" "y")"
  if [[ "$configure" != "y" ]]; then
    return 0
  fi

  local -a profile_names=()
  local -a menu_args=()
  local name desc
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    profile_names+=("$name")
  done < <(ralph_tooling_profile_names 2>/dev/null || true)

  if [[ ${#profile_names[@]} -eq 0 ]]; then
    print_hint "No tooling profiles available; skipping tooling configuration."
    return 0
  fi

  local default_index=1 idx=1 template_default template_has_overrides=0
  template_default=""
  if [[ -n "${wizard_workflow_template_seed_json:-}" && -f "$wizard_workflow_template_seed_json" ]]; then
    template_default="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("tooling", {}).get("defaultProfile", ""))' \
      "$wizard_workflow_template_seed_json" 2>/dev/null || true)"
    template_has_overrides="$(python3 -c 'import json,sys; print(1 if json.load(open(sys.argv[1])).get("tooling", {}).get("overrides") else 0)' \
      "$wizard_workflow_template_seed_json" 2>/dev/null || printf '0')"
  fi
  for name in "${profile_names[@]}"; do
    desc="$(_wizard_tooling_profile_description "$name")"
    menu_args+=(--desc "$desc")
    if [[ -n "$template_default" && "$name" == "$template_default" ]]; then
      default_index="$idx"
    elif [[ -z "$template_default" && "$name" == "ralph-compact" ]]; then
      default_index="$idx"
    fi
    idx=$((idx + 1))
  done

  local selected
  selected="$(ralph_menu_select --prompt "Default tooling profile" "${menu_args[@]}" \
    --default "$default_index" -- "${profile_names[@]}")" || selected=""
  if [[ -z "$selected" ]]; then
    print_hint "No tooling profile selected; skipping tooling configuration."
    return 0
  fi
  wizard_tooling_default_profile="$selected"

  local apply_all apply_all_default="y"
  if [[ "$template_has_overrides" == "1" ]]; then
    apply_all_default="n"
  fi
  apply_all="$(ralph_prompt_yesno "Apply this profile to every stage" "$apply_all_default")"
  if [[ "$apply_all" == "y" ]]; then
    return 0
  fi

  local stage_default_index=1 template_override=""
  idx=1
  for name in "${profile_names[@]}"; do
    [[ "$name" == "$wizard_tooling_default_profile" ]] && stage_default_index="$idx"
    idx=$((idx + 1))
  done

  local stage_id stage_profile stage_default_index_override=0
  for stage_id in "${stage_ids[@]}"; do
    [[ -n "$stage_id" ]] || continue
    stage_default_index_override="$stage_default_index"
    if [[ -n "${wizard_workflow_template_seed_json:-}" && -f "$wizard_workflow_template_seed_json" ]]; then
      template_override="$(python3 - "$wizard_workflow_template_seed_json" "$stage_id" <<'PY'
import json, sys
overrides = json.load(open(sys.argv[1], encoding="utf-8")).get("tooling", {}).get("overrides", {})
print(overrides.get(sys.argv[2], ""))
PY
)"
      if [[ -n "$template_override" ]]; then
        idx=1
        for name in "${profile_names[@]}"; do
          [[ "$name" == "$template_override" ]] && stage_default_index_override="$idx"
          idx=$((idx + 1))
        done
      fi
    fi
    stage_profile="$(ralph_menu_select --prompt "tooling profile for \"$stage_id\"" "${menu_args[@]}" \
      --default "$stage_default_index_override" -- "${profile_names[@]}")" || stage_profile=""
    stage_profile="${stage_profile:-$wizard_tooling_default_profile}"
    if [[ "$stage_profile" != "$wizard_tooling_default_profile" ]]; then
      wizard_tooling_overrides+=("$stage_id=$stage_profile")
    fi
  done
}

# _wizard_tooling_profile_description <name>
# One-line menu annotation taken from the profile's description in
# tooling-profiles.json, trimmed to the first sentence and capped for menu
# width. Prints nothing when jq or the description is unavailable.
_wizard_tooling_profile_description() {
  local name="$1" text=""
  if command -v jq >/dev/null 2>&1 && [[ -f "$RALPH_TOOLING_PROFILE_JSON_PATH" ]]; then
    text="$(jq -r --arg n "$name" '.profiles[$n].description // ""' "$RALPH_TOOLING_PROFILE_JSON_PATH" 2>/dev/null || printf '')"
  fi
  [[ -n "$text" ]] || return 0
  text="${text%%. *}"
  if [[ ${#text} -gt 72 ]]; then
    text="${text:0:69}..."
  fi
  printf '%s' "$text"
}

# --- Sequential workflow authoring prompts ---------------------------------

# wizard_sequential_resolve_public_mode [raw]
# Map an optional mode token (or RALPH_CREATE_WORKFLOW_MODE) to the public
# workflow mode. Empty / unanswered / accepted default is Sequential.
wizard_sequential_resolve_public_mode() {
  local raw="${1-}"
  if [[ -z "$raw" ]]; then
    raw="${RALPH_CREATE_WORKFLOW_MODE:-}"
  fi
  case "$raw" in
    ""|sequential|Sequential)
      printf 'sequential'
      ;;
    dependency|Dependency)
      printf 'dependency'
      ;;
    *)
      return 1
      ;;
  esac
}

# wizard_sequential_select_public_mode
# Interactive Sequential/Dependency picker. Default 1 = Sequential when the
# operator presses Enter / accepts the default.
wizard_sequential_select_public_mode() {
  local chosen
  chosen="$(ralph_menu_select --prompt "Select a workflow mode:" --default 1 \
    --desc "Ordered stages; optional declared parallel waves." \
    --desc "Dependency-driven DAG with branching and supervisors." \
    -- "sequential" "dependency")" || chosen="sequential"
  wizard_sequential_resolve_public_mode "$chosen"
}

# Exact work-source labels offered for ordinary Sequential agent stages.
wizard_sequential_work_source_inline="bounded inline action"
wizard_sequential_work_source_static="existing static plan file"
wizard_sequential_work_source_generated="generated Ralph plan"

# wizard_sequential_select_work_source <stage_id>
# Prompt for exactly one work source for an ordinary agent stage.
wizard_sequential_select_work_source() {
  local stage_id="$1"
  ralph_menu_select --prompt "Work source for \"$stage_id\"" --default 1 \
    --desc "One bounded investigation/review/handoff action with inline instructions and {{TASK}}." \
    --desc "An existing static Ralph plan file this stage executes." \
    --desc "A Ralph plan from a previously declared planner stage; this stage runs it TODO-by-TODO." \
    -- "$wizard_sequential_work_source_inline" \
       "$wizard_sequential_work_source_static" \
       "$wizard_sequential_work_source_generated"
}

# wizard_sequential_select_stage_kind <stage_id>
# Ordinary agent stage vs public approval supervisor.
wizard_sequential_select_stage_kind() {
  local stage_id="$1"
  ralph_menu_select --prompt "Stage kind for \"$stage_id\"" --default 1 \
    --desc "Ordinary agent stage with one work source." \
    --desc "Public approval gate (approve | request-changes | cancel)." \
    -- "ordinary agent" "approval"
}

# wizard_sequential_print_approval_decisions
# Display the three authored approval decisions (exact public vocabulary).
wizard_sequential_print_approval_decisions() {
  print_hint "- Approval decisions: approve | request-changes | cancel"
  print_hint "- approve: gate succeeds on explicit resume"
  print_hint "- request-changes: requires a message; reset the changesTarget stage, then resume"
  print_hint "- cancel: cancel the workflow run"
}

# wizard_sequential_explain_generated_plan
# Explain planner/planFrom schema and TODO-by-TODO consumer execution.
wizard_sequential_explain_generated_plan() {
  print_hint "- Producer emits planner: {outputMode: plan-file, maxTodos: <n>} plus one required planner JSON artifact."
  print_hint "- This stage declares planFrom: <producer> (mutually exclusive with planFile)."
  print_hint "- The later stage runs the generated Ralph plan TODO-by-TODO through the plan loop."
}

# wizard_sequential_prompt_max_todos [default]
# Max TODO ceiling for planner config (1..200, default 100).
wizard_sequential_prompt_max_todos() {
  local default_max="${1:-100}"
  local answer
  answer="$(ralph_prompt_text "Max TODO ceiling for the generated Ralph plan (1-200)" "$default_max")"
  if ! [[ "$answer" =~ ^[0-9]+$ ]] || (( answer < 1 || answer > 200 )); then
    print_hint "Invalid maxTodos; using ${default_max}."
    answer="$default_max"
  fi
  printf '%s' "$answer"
}

# wizard_sequential_select_producer_stage <consumer_id> <known_csv>
# Pick a previously declared direct planner dependency (earlier stage id).
wizard_sequential_select_producer_stage() {
  local consumer_id="$1"
  local known_csv="${2:-}"
  local -a opts=()
  local raw IFS=','
  [[ -n "$known_csv" ]] || ralph_die "generated Ralph plan for \"$consumer_id\" requires a previously declared planner stage"
  for raw in $known_csv; do
    raw="$(printf '%s' "$raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -n "$raw" ]] || continue
    opts+=("$raw")
  done
  unset IFS
  ((${#opts[@]} > 0)) || ralph_die "generated Ralph plan for \"$consumer_id\" requires a previously declared planner stage"
  ralph_menu_select --prompt "Producer planner stage for \"$consumer_id\"" --default 1 -- "${opts[@]}"
}

# wizard_sequential_select_changes_target <approval_id> <known_csv>
# Upstream resettable changesTarget for an approval stage.
wizard_sequential_select_changes_target() {
  local approval_id="$1"
  local known_csv="${2:-}"
  local -a opts=()
  local raw IFS=','
  [[ -n "$known_csv" ]] || ralph_die "approval \"$approval_id\" requires an upstream changesTarget"
  for raw in $known_csv; do
    raw="$(printf '%s' "$raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -n "$raw" ]] || continue
    opts+=("$raw")
  done
  unset IFS
  ((${#opts[@]} > 0)) || ralph_die "approval \"$approval_id\" requires an upstream changesTarget"
  ralph_menu_select --prompt "changesTarget for \"$approval_id\" (upstream resettable stage)" --default 1 -- "${opts[@]}"
}

# wizard_sequential_optional_runtime_model <stage_id>
# Optional stage runtime/model overrides. Prints "runtime<TAB>model" (either may be empty).
wizard_sequential_optional_runtime_model() {
  local stage_id="$1"
  local want runtime="" model=""
  want="$(ralph_prompt_yesno "Set runtime/model stage overrides for \"$stage_id\"" "n")"
  if [[ "$want" == "y" ]]; then
    runtime="$(select_runtime "$stage_id")"
    model="$(ralph_prompt_text "Model override for \"$stage_id\" (empty = runtime default)" "")"
  fi
  printf '%s\t%s' "$runtime" "$model"
}

# --- Shared create-workflow finish helpers (project/global, defaults, planInput) ---

# wizard_workflow_require_interactive_stdin
# Closed / non-TTY non-pipe stdin cannot complete interactive authoring. Exit 1.
# Piped answers and a real TTY are allowed; --mode only preselects scheduling.
wizard_workflow_require_interactive_stdin() {
  if [[ -t 0 ]] || [[ -p /dev/stdin ]]; then
    return 0
  fi
  ralph_die "ralph create workflow requires an interactive terminal (or piped authoring answers). Closed stdin cannot complete remaining interactive authoring. Pass --mode only to preselect sequential|dependency; all other authoring stays interactive." 1
}

# wizard_workflow_prompt_defaults
# Optional workflow-level defaults: only runtime and model (model requires runtime).
# Sets cp_defaults_runtime / cp_defaults_model (empty when skipped).
wizard_workflow_prompt_defaults() {
  local want runtime="" model=""
  cp_defaults_runtime=""
  cp_defaults_model=""
  print_info "Workflow defaults (optional)"
  print_hint "- defaults: permits only runtime and model; a model requires its paired runtime."
  print_hint "- Stage overrides still win over these defaults at run time."
  want="$(ralph_prompt_yesno "Set workflow defaults.runtime / defaults.model" "n")"
  if [[ "$want" != "y" ]]; then
    return 0
  fi
  runtime="$(select_runtime "workflow defaults")"
  [[ -n "$runtime" ]] || ralph_die "defaults.runtime is required when setting workflow defaults"
  model="$(ralph_prompt_text "defaults.model (empty = runtime default; requires defaults.runtime)" "")"
  cp_defaults_runtime="$runtime"
  cp_defaults_model="$model"
}

# wizard_workflow_plan_input_eligible_csv <required_flag>
# Print comma-separated eligible ordinary stage ids for planInput.
# required=1: ordinary agent, not planner, not planFile, not approval/supervisor.
# required=0: same plus must already have authored planFrom.
wizard_workflow_plan_input_eligible_csv() {
  local required_flag="${1:-0}"
  local idx stage_id stage_type work_source csv=""
  for idx in "${!cp_stages[@]}"; do
    stage_id="${cp_stages[$idx]}"
    stage_type="${cp_stage_types[$idx]:-agent}"
    work_source="${cp_stage_work_source[$idx]:-}"
    case "$stage_type" in
      approval|gate|checkpoint|consensus|integrate|router|join) continue ;;
    esac
    [[ "$work_source" == "approval" ]] && continue
    [[ -n "${cp_stage_planner_max[$idx]:-}" ]] && continue
    [[ -n "${cp_stage_plan_files[$idx]:-}" ]] && continue
    if [[ "$required_flag" != "1" ]]; then
      [[ -n "${cp_stage_plan_from[$idx]:-}" ]] || continue
    fi
    if [[ -n "$csv" ]]; then
      csv+=",${stage_id}"
    else
      csv="$stage_id"
    fi
  done
  printf '%s' "$csv"
}

# wizard_workflow_explain_plan_command <workflow_id> <required_flag>
# Explain the resulting ralph workflow start --plan invocation.
wizard_workflow_explain_plan_command() {
  local workflow_id="$1"
  local required_flag="${2:-0}"
  echo ""
  print_info "Supplied-plan entry (--plan)"
  if [[ "$required_flag" == "1" ]]; then
    print_hint "- required planInput rejects task-only start; supply a leaf Ralph plan:"
    echo "  ralph workflow start ${workflow_id} --plan <leaf-plan-path> [--task <text>]"
  else
    print_hint "- optional planInput: omit --plan to use the authored planFrom path; or supply a plan:"
    echo "  ralph workflow start ${workflow_id} --task \"<work request>\""
    echo "  ralph workflow start ${workflow_id} --plan <leaf-plan-path> [--task <text>]"
  fi
  print_hint "- --plan selects a leaf Ralph plan, never the workflow definition."
  print_hint "- Other stages are never inferred or skipped when --plan is used."
}

# wizard_workflow_prompt_plan_input <workflow_id>
# After stages exist: optionally designate exactly one eligible planInput stage.
# Sets cp_plan_input_stage / cp_plan_input_required (empty when skipped).
wizard_workflow_prompt_plan_input() {
  local workflow_id="$1"
  local want required_choice required_flag="0" eligible_csv stage_id
  local -a opts=()
  local raw IFS=','

  cp_plan_input_stage=""
  cp_plan_input_required=""

  print_info "Existing-plan entry (planInput, optional)"
  print_hint "- Exactly one ordinary plan-backed consumer may accept an operator-supplied --plan."
  print_hint "- Optional planInput keeps authored planFrom for task-mode starts."
  print_hint "- Required planInput rejects task-only start; the stage may omit planFrom."
  print_hint "- Never infers or skips other stages."

  want="$(ralph_prompt_yesno "Designate one eligible stage as planInput" "n")"
  if [[ "$want" != "y" ]]; then
    return 0
  fi

  required_choice="$(ralph_menu_select --prompt "planInput required?" --default 1 \
    --desc "Optional: --plan optional; authored planFrom required for task-mode starts." \
    --desc "Required: rejects task-only start; stage may omit planFrom." \
    -- "optional" "required")" || required_choice="optional"
  if [[ "$required_choice" == "required" ]]; then
    required_flag="1"
  fi

  eligible_csv="$(wizard_workflow_plan_input_eligible_csv "$required_flag")"
  if [[ -z "$eligible_csv" ]]; then
    print_hint "No eligible stages for planInput (need an ordinary non-planner stage without planFile; optional also needs planFrom). Skipping."
    return 0
  fi

  for raw in $eligible_csv; do
    raw="$(printf '%s' "$raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -n "$raw" ]] || continue
    opts+=("$raw")
  done
  unset IFS
  ((${#opts[@]} > 0)) || return 0

  stage_id="$(ralph_menu_select --prompt "planInput stage (exactly one)" --default 1 -- "${opts[@]}")"
  [[ -n "$stage_id" ]] || return 0

  cp_plan_input_stage="$stage_id"
  if [[ "$required_flag" == "1" ]]; then
    cp_plan_input_required="true"
  else
    cp_plan_input_required="false"
  fi
  wizard_workflow_explain_plan_command "$workflow_id" "$required_flag"
}

# wizard_workflow_has_plan_backed_stage
# True when any ordinary stage has planFrom or planFile.
wizard_workflow_has_plan_backed_stage() {
  local idx
  for idx in "${!cp_stages[@]}"; do
    if [[ -n "${cp_stage_plan_from[$idx]:-}" || -n "${cp_stage_plan_files[$idx]:-}" ]]; then
      return 0
    fi
  done
  return 1
}

# wizard_workflow_looks_mutating
# True when any ordinary agent stage can mutate in one turn (write scopes,
# isolated workspace, or inline non-planner work).
wizard_workflow_looks_mutating() {
  local idx stage_type work_source ws_mode
  for idx in "${!cp_stages[@]}"; do
    stage_type="${cp_stage_types[$idx]:-agent}"
    work_source="${cp_stage_work_source[$idx]:-}"
    case "$stage_type" in
      approval|gate|checkpoint|consensus|integrate|router|join) continue ;;
    esac
    [[ "$work_source" == "approval" ]] && continue
    [[ -n "${cp_stage_write_scopes[$idx]:-}" ]] && return 0
    ws_mode="${cp_stage_workspace_mode[$idx]:-}"
    case "$ws_mode" in
      snapshot|worktree) return 0 ;;
    esac
    if [[ -z "${cp_stage_planner_max[$idx]:-}" && -z "${cp_stage_plan_from[$idx]:-}" && -z "${cp_stage_plan_files[$idx]:-}" ]]; then
      if [[ -n "${cp_stage_inline_content[$idx]:-}" || "$work_source" == "inline" || -z "$work_source" ]]; then
        return 0
      fi
    fi
  done
  return 1
}

# wizard_workflow_confirm_mutating_without_plan
# Warn when a mutating workflow has no plan-backed implementation stage; permit after confirm.
wizard_workflow_confirm_mutating_without_plan() {
  local proceed
  if ! wizard_workflow_looks_mutating; then
    return 0
  fi
  if wizard_workflow_has_plan_backed_stage; then
    return 0
  fi
  echo ""
  print_info "Mutating workflow without a plan-backed implementation stage"
  print_hint "- Reusable workflow policy should keep investigation/review here;"
  print_hint "- per-run implementation normally uses a generated or provided Ralph plan (planFrom / --plan)."
  print_hint "- Genuinely bounded one-turn workflows may proceed after confirmation."
  proceed="$(ralph_prompt_yesno "Continue without a plan-backed implementation stage" "n")"
  if [[ "$proceed" != "y" ]]; then
    ralph_die "aborted: add a generated Ralph plan (planFrom) or static planFile stage, then retry"
  fi
}

# wizard_workflow_print_final_review <scope> <dest> <mode>
# Show scope/path/mode/defaults, every planner->planFrom handoff, planInput,
# approval gates, and max TODO ceilings. Distinguishes reusable policy vs per-run plans.
wizard_workflow_print_final_review() {
  local scope="$1"
  local dest="$2"
  local mode="$3"
  local idx stage_id producer max_todos question target defaults_line

  echo ""
  print_info "Final review"
  echo "Scope: ${scope}"
  echo "Path: ${dest}"
  echo "Mode: ${mode}"
  if [[ -n "${cp_defaults_runtime:-}" ]]; then
    defaults_line="runtime=${cp_defaults_runtime}"
    [[ -n "${cp_defaults_model:-}" ]] && defaults_line+=", model=${cp_defaults_model}"
    echo "Defaults: ${defaults_line}"
  else
    echo "Defaults: (none)"
  fi
  echo ""
  print_hint "- This file is reusable workflow policy (investigation/planning/execution/review)."
  print_hint "- Per-run generated plans (planner/planFrom) and operator-provided --plan plans are not stored here."
  echo ""

  echo "Planner -> planFrom handoffs:"
  local found_handoff=0
  for idx in "${!cp_stages[@]}"; do
    producer="${cp_stage_plan_from[$idx]:-}"
    [[ -n "$producer" ]] || continue
    found_handoff=1
    stage_id="${cp_stages[$idx]}"
    max_todos=""
    local pidx
    pidx="$(wizard_create_plan_stage_index "$producer" 2>/dev/null || true)"
    if [[ -n "$pidx" ]]; then
      max_todos="${cp_stage_planner_max[$pidx]:-}"
    fi
    if [[ -n "$max_todos" ]]; then
      echo "  - ${producer} (maxTodos=${max_todos}) -> planFrom ${stage_id}"
    else
      echo "  - ${producer} -> planFrom ${stage_id}"
    fi
  done
  if [[ "$found_handoff" -eq 0 ]]; then
    echo "  (none)"
  fi

  echo "Max TODO ceilings (planner stages):"
  local found_ceiling=0
  for idx in "${!cp_stages[@]}"; do
    max_todos="${cp_stage_planner_max[$idx]:-}"
    [[ -n "$max_todos" ]] || continue
    found_ceiling=1
    echo "  - ${cp_stages[$idx]}: maxTodos=${max_todos}"
  done
  if [[ "$found_ceiling" -eq 0 ]]; then
    echo "  (none)"
  fi

  echo "planInput entry:"
  if [[ -n "${cp_plan_input_stage:-}" ]]; then
    echo "  - stage=${cp_plan_input_stage} required=${cp_plan_input_required:-false}"
  else
    echo "  (none; workflow rejects --plan)"
  fi

  echo "Approval gates / changesTarget:"
  local found_approval=0
  for idx in "${!cp_stages[@]}"; do
    if [[ "${cp_stage_types[$idx]:-}" == "approval" || "${cp_stage_work_source[$idx]:-}" == "approval" ]]; then
      found_approval=1
      question="${cp_stage_question[$idx]:-}"
      target="${cp_stage_changes_target[$idx]:-}"
      echo "  - ${cp_stages[$idx]}: changesTarget=${target}"
      [[ -n "$question" ]] && echo "      question: ${question}"
    fi
  done
  if [[ "$found_approval" -eq 0 ]]; then
    echo "  (none)"
  fi
  echo ""
}
