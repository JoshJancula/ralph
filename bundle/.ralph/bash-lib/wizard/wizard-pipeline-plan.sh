#!/usr/bin/env bash
# Shared helpers for pipeline-format plan scaffolding (create-plan and wizard).
#
# Public interface:
#   wizard_parse_stage_mapping -- parse stage-id=value mappings from CLI flags.
#   wizard_create_plan_stage_index -- resolve stage id to array index.
#   wizard_create_plan_validate_orchestration -- validate non-interactive orchestration flags.
#   wizard_render_artifact_list_yaml -- render produces/requires YAML arrays.
#   wizard_render_todo_artifact_content -- TODO content with read/write artifact paths.
#   wizard_render_todo_verification -- verification text for required outputs.
#   wizard_render_pipeline_plan -- render a full orchestration or graph pipeline plan file.
#   wizard_render_pipeline_orchestration_plan -- orchestration-only convenience wrapper.
#   wizard_create_plan_interactive_execution_mode -- ask simple vs orchestration.
#   wizard_create_plan_interactive_orchestration -- interactive orchestration scaffolding flow.
#   wizard_render_graph_creation_receipt -- G02 post-creation receipt: the four
#       exact next commands (validate/render/preflight/run) using the actual
#       shell-escaped plan path, with only `run` labeled mutating.
#   wizard_render_graph_cancellation_receipt -- G02 cancellation receipt: the
#       fixed "no command was run" message; never prints a command.
#   wizard_render_graph_validation_failure_receipt -- G02 validation-failure
#       receipt: only the one failing validation command plus remediation.
#   wizard_graph_authoring_contract_path -- resolve G18 graph-authoring-contract.json.
#   wizard_graph_authoring_collect_node_types -- contract-driven node type menus.
#   wizard_graph_authoring_configure_nodes -- per-node configuration from the contract.
#   wizard_graph_run_interactive -- full interactive graph plan authoring flow.

# shellcheck source=bash-lib/error-handling.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../error-handling.sh"

wizard_create_plan_allowed_runtimes=(cursor claude codex opencode antigravity)
wizard_create_plan_allowed_session_strategies=(fresh resume reset compact)
wizard_create_plan_allowed_context_budgets=(full standard lean)

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
cp_artifact_entries=()
# Run-level tooling policy (pipeline.tooling); empty default profile omits the block.
cp_tooling_default_profile=""
cp_tooling_overrides=()
cp_parallel_waves=()
cp_loop_sources=()
cp_loop_targets=()
cp_loop_max_iters=()
cp_loop_check_paths=()

# Graph-mode-only stage fields (indices align with cp_stages).
cp_stage_depends_on=()
cp_stage_policy=()
cp_stage_quorum=()
cp_stage_workspace_mode=()

# Flattened consensus voter rows (each row tagged with its owning node id).
cp_voter_node=()
cp_voter_id=()
cp_voter_runtime=()
cp_voter_model=()

# Additional graph authoring fields (indices align with cp_stages).
cp_stage_profile=()
cp_stage_write_scopes=()
cp_stage_router_allowed=()
cp_stage_router_default=()
cp_stage_router_terminal=()
cp_stage_router_on_invalid=()

# Sequential workflow authoring fields (indices align with cp_stages).
# work_source: inline|static-plan|generated-plan|approval|planner (producer marked by consumer)
cp_stage_work_source=()
cp_stage_plan_from=()
cp_stage_planner_max=()
cp_stage_question=()
cp_stage_changes_target=()
cp_stage_instructions=()

# Optional pipeline.verificationProfiles for gate nodes (parallel arrays).
cp_vp_name=()
cp_vp_step_name=()
cp_vp_step_command=()

wizard_graph_authoring_contract_path() {
  local root="${1:-${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.ralph}}"
  printf '%s/schemas/graph-authoring-contract.json' "$root"
}

wizard_graph_authoring_require_jq() {
  command -v jq >/dev/null 2>&1 || ralph_die \
    "graph authoring requires jq (install jq, or use 'ralph create workflow --mode sequential' for a sequential workflow, which does not need it)"
}

# wizard_graph_wrap <indent> <text>
# Word-wraps operator help to the terminal width so contract help text does not
# print as one unreadable line. Falls back to 80 columns when COLUMNS is unset.
wizard_graph_wrap() {
  local indent="$1" text="$2"
  local width="${COLUMNS:-0}"
  if [[ ! "$width" =~ ^[0-9]+$ ]] || ((width < 40)); then
    width=80
  fi
  printf '%s' "$text" | awk -v indent="$indent" -v width="$width" '
    BEGIN { limit = width - length(indent) - 1; if (limit < 30) limit = 30; line = "" }
    {
      for (i = 1; i <= NF; i++) {
        if (line == "") { line = $i }
        else if (length(line) + 1 + length($i) <= limit) { line = line " " $i }
        else { print indent line; line = $i }
      }
    }
    END { if (line != "") print indent line }
  '
}

# wizard_graph_explain <text>
# Prints wrapped, dimmed explanatory prose above a prompt.
wizard_graph_explain() {
  local line
  printf '\n' >&2
  while IFS= read -r line; do
    printf '%s%s%s\n' "${c_dim:-}" "$line" "${c_reset:-}" >&2
  done < <(wizard_graph_wrap "  " "$1")
}

wizard_graph_authoring_topic_help_text() {
  local topic="$1"
  local contract_path
  contract_path="$(wizard_graph_authoring_contract_path)"
  wizard_graph_authoring_require_jq
  [[ -f "$contract_path" ]] || ralph_die "missing graph authoring contract: $contract_path"
  jq -r --arg topic "$topic" '.operatorTopics[$topic].help // empty' "$contract_path"
}

wizard_graph_authoring_print_topic_help() {
  local help_text
  help_text="$(wizard_graph_authoring_topic_help_text "$1")"
  [[ -n "$help_text" ]] && wizard_graph_explain "$help_text"
  return 0
}

# wizard_graph_authoring_choice_descs <group> <option>...
# Echoes one "--desc <text>" pair per option, in option order, pulled from
# contract .choiceHelp[group]. Options with no entry get an empty description so
# the pairing with the choice list stays positional.
wizard_graph_authoring_choice_descs() {
  local group="$1"; shift
  local contract_path opt desc
  contract_path="$(wizard_graph_authoring_contract_path)"
  wizard_graph_authoring_require_jq
  for opt in "$@"; do
    desc="$(jq -r --arg g "$group" --arg o "$opt" '.choiceHelp[$g][$o] // ""' "$contract_path")"
    printf '%s\n%s\n' "--desc" "$desc"
  done
}

# wizard_graph_menu <group> <prompt> <default-index> <option>...
# ralph_menu_select with each option annotated from contract .choiceHelp[group].
wizard_graph_menu() {
  local group="$1" prompt="$2" default_idx="$3"; shift 3
  local args=() line
  while IFS= read -r line; do
    args+=("$line")
  done < <(wizard_graph_authoring_choice_descs "$group" "$@")
  ralph_menu_select --prompt "$prompt" --default "$default_idx" "${args[@]}" -- "$@"
}

wizard_graph_authoring_node_type_labels() {
  local contract_path
  contract_path="$(wizard_graph_authoring_contract_path)"
  wizard_graph_authoring_require_jq
  [[ -f "$contract_path" ]] || ralph_die "missing graph authoring contract: $contract_path"
  jq -r '.nodeTypes | to_entries | sort_by(.value.wizardOrder) | .[].key' "$contract_path"
}

# wizard_graph_authoring_print_node_type_guide
# One-time cheat sheet printed before the first node-type question: what each
# type is for and a concrete example, so the operator is not picking from a
# list of bare words they have never seen defined.
wizard_graph_authoring_print_node_type_guide() {
  local contract_path label summary when example
  contract_path="$(wizard_graph_authoring_contract_path)"
  wizard_graph_authoring_require_jq
  [[ -f "$contract_path" ]] || ralph_die "missing graph authoring contract: $contract_path"

  print_info "Node types"
  wizard_graph_authoring_print_topic_help "nodeTypes"
  printf '\n' >&2
  while IFS=$'\t' read -r label summary when example; do
    [[ -n "$label" ]] || continue
    printf '  %s%s%s  %s\n' "${c_bold:-}" "$label" "${c_reset:-}" "$summary" >&2
    [[ -n "$when" ]] && wizard_graph_wrap "      " "$when" >&2
    [[ -n "$example" ]] && printf '      %se.g. %s%s\n' "${c_dim:-}" "$example" "${c_reset:-}" >&2
    printf '\n' >&2
  done < <(jq -r '
    .nodeTypes | to_entries | sort_by(.value.wizardOrder) | .[] |
    [.key, (.value.summary // ""), (.value.whenToUse // ""), (.value.example // "")] | @tsv
  ' "$contract_path")
}

wizard_graph_authoring_select_node_type() {
  local stage_id="$1"
  local contract_path default_index=1 labels=() descs=() label summary
  contract_path="$(wizard_graph_authoring_contract_path)"
  wizard_graph_authoring_require_jq
  while IFS=$'\t' read -r label summary; do
    [[ -n "$label" ]] || continue
    labels+=("$label")
    descs+=("--desc" "$summary")
  done < <(jq -r '
    .nodeTypes | to_entries | sort_by(.value.wizardOrder) | .[] |
    [.key, (.value.summary // "")] | @tsv
  ' "$contract_path")
  ((${#labels[@]} > 0)) || ralph_die "graph authoring contract defines no node types"
  ralph_menu_select --prompt "Node type for \"$stage_id\"" --default "$default_index" \
    "${descs[@]}" -- "${labels[@]}"
}

wizard_graph_authoring_default_workspace_mode() {
  local contract_path
  contract_path="$(wizard_graph_authoring_contract_path)"
  wizard_graph_authoring_require_jq
  jq -r '.defaults.workspaceMode // "snapshot"' "$contract_path"
}

wizard_graph_authoring_configure_write_scopes() {
  local node_id="$1"
  local scopes_input
  wizard_graph_authoring_print_topic_help "writeScopes"
  scopes_input="$(ralph_prompt_text "Write scopes for \"$node_id\" (comma-separated globs, optional)" "")"
  printf '%s' "$scopes_input"
}

wizard_graph_authoring_configure_router() {
  local node_id="$1" known_csv="$2"
  local allowed default_target terminal on_invalid
  wizard_graph_authoring_print_topic_help "routerTargets"
  wizard_graph_explain "Name the branches this router chooses between. They must be node ids declared in this plan; type new ids here and add those nodes on the next pass if they do not exist yet."
  allowed="$(ralph_prompt_list "Router allowed targets for \"$node_id\"" "$known_csv" "$known_csv" "1")"
  [[ -n "$allowed" ]] || ralph_die "router node \"$node_id\" requires at least one allowed target"
  default_target="$(ralph_prompt_text "Router default target for \"$node_id\"" "${allowed%%,*}")"
  [[ -n "$default_target" ]] || ralph_die "router node \"$node_id\" requires a default target"
  wizard_graph_explain "Terminal outcomes end routing without picking any branch, for example \"no-change\" when there is nothing left to do. Leave blank if every run should continue down a branch."
  terminal="$(ralph_prompt_text "Router terminal outcomes (comma-separated, optional)" "")"
  on_invalid="$(wizard_graph_menu onInvalid "If the router picks an invalid target for \"$node_id\"" 1 "fail" "default")"
  printf '%s\t%s\t%s\t%s' "$allowed" "$default_target" "$terminal" "$on_invalid"
}

wizard_graph_authoring_reset_graph_arrays() {
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
  cp_stage_profile=()
  cp_stage_write_scopes=()
  cp_stage_router_allowed=()
  cp_stage_router_default=()
  cp_stage_router_terminal=()
  cp_stage_router_on_invalid=()
  cp_stage_work_source=()
  cp_stage_plan_from=()
  cp_stage_planner_max=()
  cp_stage_question=()
  cp_stage_changes_target=()
  cp_stage_instructions=()
  cp_artifact_entries=()
  cp_parallel_waves=()
  cp_voter_node=()
  cp_voter_id=()
  cp_voter_runtime=()
  cp_voter_model=()
  cp_vp_name=()
  cp_vp_step_name=()
  cp_vp_step_command=()
}

wizard_sequential_reset_arrays() {
  wizard_graph_authoring_reset_graph_arrays
  cp_tooling_default_profile=""
  cp_tooling_overrides=()
  cp_loop_sources=()
  cp_loop_targets=()
  cp_loop_max_iters=()
  cp_loop_check_paths=()
  cp_defaults_runtime=""
  cp_defaults_model=""
  cp_plan_input_stage=""
  cp_plan_input_required=""
  cp_workflow_scope=""
  cp_workflow_dest=""
  cp_parallel_waves=()
}

wizard_graph_authoring_collect_node_types() {
  local stage_id node_type
  wizard_graph_authoring_print_node_type_guide
  for stage_id in "$@"; do
    cp_stages+=("$stage_id")
    node_type="$(wizard_graph_authoring_select_node_type "$stage_id")"
    cp_stage_types+=("$node_type")
  done
}

# wizard_graph_authoring_print_node_banner <index> <total> <node_id> <type>
# Header for one node's configuration block: which node, which type, what that
# type does, and what is about to be asked. Without this the operator sees a
# long unlabeled run of prompts and loses track of which node they are on.
wizard_graph_authoring_print_node_banner() {
  local position="$1" total="$2" node_id="$3" node_type="$4"
  local contract_path summary
  contract_path="$(wizard_graph_authoring_contract_path)"
  wizard_graph_authoring_require_jq
  summary="$(jq -r --arg t "$node_type" '.nodeTypes[$t].summary // ""' "$contract_path")"
  printf '\n' >&2
  print_info "Node ${position}/${total}: \"${node_id}\" (${node_type})" >&2
  [[ -n "$summary" ]] && wizard_graph_explain "$summary"
  return 0
}

wizard_graph_authoring_configure_nodes() {
  local mode="${1:-graph}"
  local plan_name="${2:?wizard_graph_authoring_configure_nodes requires plan name}"
  local noun="node"
  local idx stage_id stage_type runtime role model native_subagents plan_file inline_content inline_verification
  local depends_on policy quorum workspace_mode write_scopes profile gate_profile session context
  local known_csv earlier_ids router_runtime router_selection router_is_custom router_model
  local router_cfg router_allowed router_default router_terminal router_on_invalid
  local work_source plan_from question changes_target instructions pair
  local requires_input produces_input use_plan_file create_stub stub_dir stub_dest
  local plan_file_default stage_plan_name

  print_step "3/4" "Configure each ${noun}"
  wizard_graph_explain "Each node is configured in turn. Questions marked optional can be left blank and hand-edited in the generated plan later."
  printf '\n' >&2

  local node_total="${#cp_stages[@]}"
  for idx in "${!cp_stages[@]}"; do
    stage_id="${cp_stages[$idx]}"
    stage_type="${cp_stage_types[$idx]}"
    runtime=""
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
    write_scopes=""
    profile=""
    router_allowed=""
    router_default=""
    router_terminal=""
    router_on_invalid=""
    work_source=""
    plan_from=""
    question=""
    changes_target=""
    instructions=""
    pair=""
    requires_input=""
    produces_input=""

    wizard_graph_authoring_print_node_banner "$((idx + 1))" "$node_total" "$stage_id" "$stage_type"

    known_csv=""
    if ((idx > 0)); then
      earlier_ids=("${cp_stages[@]:0:$idx}")
      known_csv="$(IFS=','; printf '%s' "${earlier_ids[*]}")"
    fi
    if [[ -n "$known_csv" ]]; then
      wizard_graph_authoring_print_topic_help "dependsOn"
    else
      wizard_graph_explain "\"$stage_id\" is the first node, so it has no upstream nodes to depend on and starts immediately."
    fi
    depends_on="$(select_depends_on "$stage_id" "$known_csv")"

    case "$stage_type" in
      consensus)
        policy="$(wizard_graph_menu policy "How should the votes decide the outcome for \"$stage_id\"" 1 "veto" "unanimous" "quorum" "adjudicate")"
        if [[ "$policy" == "quorum" ]]; then
          wizard_graph_explain "How many approvals are needed to pass. Keep it below the voter count, otherwise quorum behaves exactly like unanimous."
          quorum="$(ralph_prompt_text "Quorum count for \"$stage_id\"" "2")"
        fi
        wizard_graph_authoring_print_topic_help "voters"
        configure_voters "$stage_id"
        ;;
      join)
        wizard_graph_explain "A join tallies verdicts written by upstream nodes. Make sure this node's dependsOn lists every node whose verdict should count."
        policy="$(wizard_graph_menu policy "How should the upstream verdicts decide \"$stage_id\"" 1 "veto" "unanimous" "quorum" "adjudicate")"
        ;;
      checkpoint)
        wizard_graph_explain "Nothing to configure. The run pauses here until a human acknowledges \"$stage_id\"; branches that do not depend on it keep running."
        ;;
      approval)
        # Public approval gate: question + resettable ancestor changesTarget.
        # Never expose checkpoint vocabulary or agent/plan/runtime fields.
        work_source="approval"
        wizard_sequential_print_approval_decisions
        question="$(ralph_prompt_text "Exact approval question for \"$stage_id\"" "")"
        [[ -n "$question" ]] || ralph_die "approval \"$stage_id\" requires a non-empty question"
        if [[ -n "$known_csv" ]]; then
          # Prefer ordinary upstream ancestors (exclude approvals) for changesTarget.
          local ancestor_csv="" ancestor_id
          local old_ifs="$IFS"
          IFS=','
          for ancestor_id in $known_csv; do
            ancestor_id="$(printf '%s' "$ancestor_id" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            [[ -n "$ancestor_id" ]] || continue
            local aidx
            aidx="$(wizard_create_plan_stage_index "$ancestor_id" 2>/dev/null || true)"
            if [[ -n "$aidx" && "${cp_stage_types[$aidx]:-agent}" == "approval" ]]; then
              continue
            fi
            if [[ -n "$ancestor_csv" ]]; then
              ancestor_csv+=",$ancestor_id"
            else
              ancestor_csv="$ancestor_id"
            fi
          done
          IFS="$old_ifs"
          changes_target="$(wizard_sequential_select_changes_target "$stage_id" "$ancestor_csv")"
        else
          ralph_die "approval \"$stage_id\" requires an upstream changesTarget"
        fi
        if [[ -z "$depends_on" ]]; then
          depends_on="$changes_target"
        elif [[ ",${depends_on}," != *",${changes_target},"* ]]; then
          depends_on="${depends_on},${changes_target}"
        fi
        requires_input="$(ralph_prompt_text "Required artifact path to review for \"$stage_id\" (optional)" \
          ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/${changes_target}.md")"
        if [[ -n "$requires_input" ]]; then
          wizard_create_plan_append_artifact "$stage_id" "$requires_input" "true" "requires"
        fi
        ;;
      gate)
        wizard_graph_authoring_print_topic_help "verificationProfile"
        gate_profile="$(ralph_prompt_text "Verification profile name for \"$stage_id\" (optional)" "")"
        profile="$gate_profile"
        if [[ -n "$gate_profile" ]]; then
          cp_vp_name+=("$gate_profile")
          cp_vp_step_name+=("check")
          cp_vp_step_command+=("true")
          wizard_graph_explain "Scaffolded profile \"$gate_profile\" with one placeholder step that always passes. Replace its command in pipeline.verificationProfiles before running."
        fi
        wizard_graph_explain "A required input artifact makes the gate wait for that file and fail fast if it is missing or empty. Leave blank if this gate only runs commands."
        requires_input="$(ralph_prompt_text "Required input artifact for \"$stage_id\" (optional)" "")"
        if [[ -n "$requires_input" ]]; then
          wizard_create_plan_append_artifact "$stage_id" "$requires_input" "true" "requires"
        fi
        ;;
      integrate)
        workspace_mode="$(wizard_graph_authoring_default_workspace_mode)"
        wizard_graph_explain "Using workspaceMode ${workspace_mode}, so your real files stay untouched until the merge succeeds. Make sure dependsOn lists every isolated node whose edits should be merged here."
        ;;
      router)
        wizard_graph_explain "The router itself is a model call: it reads the upstream result and names one branch to take. Pick the runtime that makes that call."
        router_runtime="$(select_runtime "$stage_id")"
        runtime="$router_runtime"
        wizard_print_runtime_role_model_subagents "Node $stage_id" "$runtime" "" ""
        router_cfg="$(wizard_graph_authoring_configure_router "$stage_id" "$known_csv")"
        IFS=$'\t' read -r router_allowed router_default router_terminal router_on_invalid <<< "$router_cfg"
        ;;
      agent|*)
        if [[ "${wizard_public_mode:-}" == "dependency" ]]; then
          # Same three exact work-source choices as Sequential.
          work_source="$(wizard_sequential_select_work_source "$stage_id")"
          case "$work_source" in
            "$wizard_sequential_work_source_inline")
              work_source="inline"
              pair="$(wizard_sequential_optional_runtime_model "$stage_id")"
              runtime="${pair%%$'\t'*}"
              model="${pair#*$'\t'}"
              instructions="$(ralph_prompt_text "Inline instructions for \"$stage_id\" (optional)" "")"
              inline_content="$(ralph_prompt_text "Bounded inline action for \"$stage_id\" ({{TASK}} is added if missing)" "")"
              inline_verification="$(ralph_prompt_text "Verification for \"$stage_id\" inline action (optional)" "")"
              ;;
            "$wizard_sequential_work_source_static")
              work_source="static-plan"
              pair="$(wizard_sequential_optional_runtime_model "$stage_id")"
              runtime="${pair%%$'\t'*}"
              model="${pair#*$'\t'}"
              plan_file="$(ralph_prompt_text "Existing static plan file for \"$stage_id\"" \
                ".ralph-workspace/plans/${plan_name}-${stage_id}.plan.md")"
              [[ -n "$plan_file" ]] || ralph_die "static plan file path required for \"$stage_id\""
              ;;
            "$wizard_sequential_work_source_generated")
              work_source="generated-plan"
              wizard_sequential_explain_generated_plan
              local producer max_todos producer_idx agent_csv
              agent_csv="$known_csv"
              producer="$(wizard_sequential_select_producer_stage "$stage_id" "$agent_csv")"
              max_todos="$(wizard_sequential_prompt_max_todos 100)"
              producer_idx="$(wizard_create_plan_stage_index "$producer")" || \
                ralph_die "unknown producer stage \"$producer\""
              if [[ "${cp_stage_types[$producer_idx]:-agent}" == "approval" ]]; then
                ralph_die "planner producer \"$producer\" cannot be an approval stage"
              fi
              # Mark producer as planner; clear static planFile if present.
              while ((${#cp_stage_planner_max[@]} <= producer_idx)); do
                cp_stage_planner_max+=("")
              done
              cp_stage_planner_max[$producer_idx]="$max_todos"
              while ((${#cp_stage_plan_files[@]} <= producer_idx)); do
                cp_stage_plan_files+=("")
              done
              cp_stage_plan_files[$producer_idx]=""
              while ((${#cp_stage_inline_content[@]} <= producer_idx)); do
                cp_stage_inline_content+=("")
              done
              if [[ -z "${cp_stage_inline_content[$producer_idx]:-}" ]]; then
                cp_stage_inline_content[$producer_idx]="Plan the fewest independently verifiable TODOs that fully cover:
{{TASK}}"
              fi
              plan_from="$producer"
              if [[ -z "$depends_on" ]]; then
                depends_on="$producer"
              elif [[ ",${depends_on}," != *",${producer},"* ]]; then
                depends_on="${depends_on},${producer}"
              fi
              pair="$(wizard_sequential_optional_runtime_model "$stage_id")"
              runtime="${pair%%$'\t'*}"
              model="${pair#*$'\t'}"
              instructions="$(ralph_prompt_text "Inline instructions for \"$stage_id\" consumer (optional)" "")"
              ;;
            *)
              ralph_die "unknown work source for \"$stage_id\": $work_source"
              ;;
          esac
          if [[ -z "$plan_file" ]]; then
            wizard_graph_authoring_print_topic_help "workspace"
            workspace_mode="$(select_workspace_mode "$stage_id")"
            if [[ "$workspace_mode" != "shared" ]]; then
              write_scopes="$(wizard_graph_authoring_configure_write_scopes "$stage_id")"
            fi
          fi
        else
          wizard_graph_authoring_print_topic_help "planFile"
          use_plan_file="$(ralph_menu_select --prompt "Where do \"$stage_id\" instructions live" --default 1 \
            --desc "One todo written here in the graph plan. Best for short tasks." \
            --desc "Its own plan file with a full todo checklist. Best for multi-step work." \
            -- "inline" "plan file")"
          if [[ "$use_plan_file" == "plan file" ]]; then
            work_source="static-plan"
            plan_file_default=".ralph-workspace/plans/${plan_name}-${stage_id}.plan.md"
            plan_file="$(ralph_prompt_text "Plan file path for \"$stage_id\"" "$plan_file_default")"
            [[ -n "$plan_file" ]] || ralph_die "plan file path required for node \"$stage_id\""
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
                  "overview: Node plan for ${stage_id} in ${plan_name}" \
                  "mode: standard" \
                  "instructions: Execute one TODO at a time." \
                  "" \
                  "todos:" \
                  "  - id: ${stage_id}-task-1" \
                  "    content: |" \
                  "      Describe the task for this node here." \
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
            work_source="inline"
            runtime="$(select_runtime "$stage_id")"
            role="$(select_role "$stage_id")"
            native_subagents="$(select_native_subagents "$stage_id")"
            wizard_print_runtime_role_model_subagents "Node $stage_id" "$runtime" "$role" "$native_subagents"
            wizard_graph_explain "What this node should do, in plain language. Leave blank to fill the todo in by hand afterwards."
            inline_content="$(ralph_prompt_text "Content/instructions for \"$stage_id\" todo (optional)" "")"
            wizard_graph_explain "How the runner confirms the work is done, for example \"npm test passes\". Every todo should have one."
            inline_verification="$(ralph_prompt_text "Verification steps for \"$stage_id\" todo (optional)" "")"
          fi
          if [[ -z "$plan_file" ]]; then
            wizard_graph_authoring_print_topic_help "workspace"
            workspace_mode="$(select_workspace_mode "$stage_id")"
            if [[ "$workspace_mode" != "shared" ]]; then
              write_scopes="$(wizard_graph_authoring_configure_write_scopes "$stage_id")"
            fi
          fi
        fi
        ;;
    esac

    if [[ "$stage_type" == "agent" && "${wizard_public_mode:-}" != "dependency" ]]; then
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
    cp_stage_profile+=("$profile")
    cp_stage_write_scopes+=("$write_scopes")
    cp_stage_router_allowed+=("${router_allowed:-}")
    cp_stage_router_default+=("${router_default:-}")
    cp_stage_router_terminal+=("${router_terminal:-}")
    cp_stage_router_on_invalid+=("${router_on_invalid:-}")
    cp_stage_work_source+=("${work_source:-}")
    cp_stage_plan_from+=("${plan_from:-}")
    # planner_max may already be written for an earlier producer index; pad only.
    while ((${#cp_stage_planner_max[@]} <= idx)); do
      cp_stage_planner_max+=("")
    done
    cp_stage_question+=("${question:-}")
    cp_stage_changes_target+=("${changes_target:-}")
    cp_stage_instructions+=("${instructions:-}")

    if [[ "$stage_type" == "agent" && -z "$plan_file" && -z "$plan_from" ]]; then
      wizard_graph_authoring_print_topic_help "artifacts"
      wizard_graph_explain "Paths are project-relative and may use {{ARTIFACT_NS}} for the plan namespace, e.g. .ralph-workspace/artifacts/{{ARTIFACT_NS}}/${stage_id}.md"
      produces_input="$(ralph_prompt_text "Output artifact \"$stage_id\" must write (optional)" "")"
      if [[ -n "$produces_input" ]]; then
        wizard_create_plan_append_artifact "$stage_id" "$produces_input" "true" "produces"
      fi
      requires_input="$(ralph_prompt_text "Input artifact \"$stage_id\" must read first (optional)" "")"
      if [[ -n "$requires_input" ]]; then
        wizard_create_plan_append_artifact "$stage_id" "$requires_input" "true" "requires"
      fi
    elif [[ "$stage_type" == "agent" && -n "$plan_from" ]]; then
      produces_input="$(ralph_prompt_text "Output artifact \"$stage_id\" must write (optional)" "")"
      if [[ -n "$produces_input" ]]; then
        wizard_create_plan_append_artifact "$stage_id" "$produces_input" "true" "produces"
      fi
      requires_input="$(ralph_prompt_text "Input artifact \"$stage_id\" must read first (optional)" "")"
      if [[ -n "$requires_input" ]]; then
        wizard_create_plan_append_artifact "$stage_id" "$requires_input" "true" "requires"
      fi
    fi
  done
}

# wizard_graph_render_review <dest> <max_parallel> <edge_derivation> <failure_policy>
#
# Final pre-write summary. Shows the run-wide settings, then each node grouped
# into the waves it can actually run in, with the details that were configured
# (who runs it, isolation, artifacts, policy). The wave grouping is the point:
# it is the only place the operator sees what their dependsOn answers actually
# bought them in terms of parallelism before committing.
wizard_graph_render_review() {
  local dest="$1" max_parallel="$2" edge_derivation="$3" failure_policy="$4"
  local idx wave placed_count total="${#cp_stages[@]}"
  local -a wave_of=()
  local dep deps_csv resolved

  for idx in "${!cp_stages[@]}"; do
    wave_of+=("-1")
  done

  # Longest-path layering: a node sits one wave after its latest dependency.
  # Unresolvable ids (a dependsOn naming a node that is not in this plan) stop
  # the loop rather than spinning, and fall through to the "unscheduled" list.
  wave=0
  placed_count=0
  while ((placed_count < total)); do
    local progressed=0
    for idx in "${!cp_stages[@]}"; do
      [[ "${wave_of[$idx]}" == "-1" ]] || continue
      deps_csv="${cp_stage_depends_on[$idx]:-}"
      resolved=1
      if [[ -n "$deps_csv" ]]; then
        local old_ifs="$IFS"
        IFS=','
        for dep in $deps_csv; do
          [[ -n "$dep" ]] || continue
          local dep_idx found=0 j
          for j in "${!cp_stages[@]}"; do
            if [[ "${cp_stages[$j]}" == "$dep" ]]; then
              found=1
              dep_idx="$j"
              break
            fi
          done
          if ((found == 0)) || [[ "${wave_of[$dep_idx]}" == "-1" ]] || ((wave_of[dep_idx] >= wave)); then
            resolved=0
            break
          fi
        done
        IFS="$old_ifs"
      fi
      if ((resolved == 1)); then
        wave_of[idx]="$wave"
        placed_count=$((placed_count + 1))
        progressed=1
      fi
    done
    ((progressed == 1)) || break
    wave=$((wave + 1))
  done

  printf '\n' >&2
  printf '%sPlan:%s %s\n' "${c_bold:-}" "${c_reset:-}" "$dest" >&2
  printf '%smaxParallel %s | edgeDerivation %s | failurePolicy %s%s\n\n' \
    "${c_dim:-}" "$max_parallel" "$edge_derivation" "$failure_policy" "${c_reset:-}" >&2

  local w=0
  while ((w < wave)); do
    local wave_members=()
    for idx in "${!cp_stages[@]}"; do
      [[ "${wave_of[$idx]}" == "$w" ]] && wave_members+=("$idx")
    done
    if ((${#wave_members[@]} > 0)); then
      if ((${#wave_members[@]} > 1)); then
        printf '  %sWave %s%s %s(%s nodes run in parallel)%s\n' \
          "${c_bold:-}" "$((w + 1))" "${c_reset:-}" "${c_dim:-}" "${#wave_members[@]}" "${c_reset:-}" >&2
      else
        printf '  %sWave %s%s\n' "${c_bold:-}" "$((w + 1))" "${c_reset:-}" >&2
      fi
      for idx in "${wave_members[@]}"; do
        wizard_graph_render_review_node "$idx"
      done
      printf '\n' >&2
    fi
    w=$((w + 1))
  done

  local unscheduled=()
  for idx in "${!cp_stages[@]}"; do
    [[ "${wave_of[$idx]}" == "-1" ]] && unscheduled+=("$idx")
  done
  if ((${#unscheduled[@]} > 0)); then
    printf '  %sUnscheduled%s %s(dependsOn names a node not in this plan, or forms a cycle)%s\n' \
      "${c_yellow:-}" "${c_reset:-}" "${c_dim:-}" "${c_reset:-}" >&2
    for idx in "${unscheduled[@]}"; do
      wizard_graph_render_review_node "$idx"
    done
    printf '\n' >&2
    print_hint "Validation will reject these; fix them in the generated plan or restart the wizard." >&2
  fi
}

# wizard_graph_render_review_node <index>
# One indented node line plus its configured detail lines.
wizard_graph_render_review_node() {
  local idx="$1"
  local details=()
  printf '    %s%s%s %s[%s]%s\n' \
    "${c_bold:-}" "${cp_stages[$idx]}" "${c_reset:-}" \
    "${c_dim:-}" "${cp_stage_types[$idx]}" "${c_reset:-}" >&2

  [[ -n "${cp_stage_depends_on[$idx]:-}" ]] && details+=("after: ${cp_stage_depends_on[$idx]}")
  if [[ -n "${cp_stage_plan_files[$idx]:-}" ]]; then
    details+=("plan: ${cp_stage_plan_files[$idx]}")
  elif [[ -n "${cp_stage_runtimes[$idx]:-}" ]]; then
    details+=("runtime: ${cp_stage_runtimes[$idx]}")
    details+=("role: ${cp_stage_roles[$idx]:-none}")
    if [[ -n "${cp_stage_models[$idx]:-}" ]]; then
      details+=("model source: stage override (${cp_stage_models[$idx]})")
    else
      details+=("model source: runtime saved/default")
    fi
    details+=("native subagents: ${cp_stage_native_subagents[$idx]:-off}")
  fi
  [[ -n "${cp_stage_workspace_mode[$idx]:-}" ]] && details+=("writes in: ${cp_stage_workspace_mode[$idx]}")
  [[ -n "${cp_stage_write_scopes[$idx]:-}" ]] && details+=("scoped to: ${cp_stage_write_scopes[$idx]}")
  if [[ -n "${cp_stage_policy[$idx]:-}" ]]; then
    local policy_detail="policy: ${cp_stage_policy[$idx]}"
    [[ -n "${cp_stage_quorum[$idx]:-}" ]] && policy_detail+=" (${cp_stage_quorum[$idx]} needed)"
    details+=("$policy_detail")
  fi
  [[ -n "${cp_stage_profile[$idx]:-}" ]] && details+=("profile: ${cp_stage_profile[$idx]}")
  [[ -n "${cp_stage_router_allowed[$idx]:-}" ]] && \
    details+=("routes to: ${cp_stage_router_allowed[$idx]} (default ${cp_stage_router_default[$idx]:-none})")

  local voter_list="" v
  for v in "${!cp_voter_node[@]}"; do
    if [[ "${cp_voter_node[$v]}" == "${cp_stages[$idx]}" ]]; then
      [[ -n "$voter_list" ]] && voter_list+=", "
      voter_list+="${cp_voter_id[$v]}@${cp_voter_runtime[$v]} model-source=runtime-saved/default native-subagents=off"
    fi
  done
  [[ -n "$voter_list" ]] && details+=("voters: $voter_list")

  # cp_artifact_entries rows are "stage|path|required|bucket" (see
  # wizard_create_plan_append_artifact). The ${arr[@]+...} guard keeps empty
  # arrays from tripping `set -u` on bash 3.2, which is what stock macOS ships.
  local entry a_sid a_path a_bucket
  for entry in ${cp_artifact_entries[@]+"${cp_artifact_entries[@]}"}; do
    IFS='|' read -r a_sid a_path _ a_bucket <<< "$entry"
    [[ "$a_sid" == "${cp_stages[$idx]}" ]] || continue
    details+=("${a_bucket}: ${a_path}")
  done

  local d
  for d in ${details[@]+"${details[@]}"}; do
    printf '      %s%s%s\n' "${c_dim:-}" "$d" "${c_reset:-}" >&2
  done
}

# wizard_graph_run_interactive
#
# Interactive graph plan authoring using the G18 contract. Populates cp_* arrays,
# renders the plan to workspace/.ralph-workspace/plans/<name>.plan.md, and
# prints the G02 creation receipt. Assumes wizard-prompts.sh and ui-prompt.sh
# are already sourced and workspace/SCRIPT_DIR are set.
wizard_graph_run_interactive() {
  local plan_name plan_overview instructions_line dest plans_dir tmp_dest confirm_write
  local max_parallel edge_derivation failure_policy selected_stage_ids _s _sid stage_id
  local render_mode="${wizard_workflow_engine:-graph}"

  if [[ "${wizard_output_format:-plan}" == "workflow" ]]; then
    print_step "1/4" "Workflow metadata"
    wizard_graph_explain "A reusable workflow describes stage shape and tooling policy. Each agent stage todo carries a {{TASK}} token that is filled in when you instantiate the workflow with a work request."
    if [[ "${wizard_workflow_metadata_done:-}" != "1" ]]; then
      read_workflow_info
    fi
    plan_name="$workflow_name"
    plan_overview="${pipeline_description:-Reusable graph workflow for $plan_name}"
    if [[ -z "$pipeline_name" ]]; then
      pipeline_name="$plan_name"
    fi
    plans_dir="$workspace/.ralph-workspace/workflows"
    dest="$plans_dir/${plan_name}.workflow.md"
    if [[ -e "$dest" ]]; then
      ralph_die "workflow already exists: $dest"
    fi
  else
    print_step "1/4" "Plan metadata"
    wizard_graph_explain "A graph plan describes nodes and the dependencies between them. Ralph runs nodes as soon as their dependencies are satisfied, so independent work overlaps automatically."
    wizard_graph_explain "Four steps: name the plan and set run-wide limits, list the node ids, configure each node, then review and write. Nothing is written to disk until you confirm at the end."
    read_pipeline_info

    plan_name="${namespace:-graph}"
    plan_overview="${pipeline_description:-Multi-stage graph plan for $plan_name}"
    if [[ -z "$pipeline_name" ]]; then
      pipeline_name="$plan_name"
    fi

    plans_dir="$workspace/.ralph-workspace/plans"
    dest="$plans_dir/${plan_name}.plan.md"
    if [[ -e "$dest" ]]; then
      ralph_die "plan already exists: $dest"
    fi
  fi

  instructions_line="instructions: Execute one TODO at a time."
  local template_path="${SCRIPT_DIR}/plan-templates/pipeline-simple.plan.template.md"
  if [[ -f "$template_path" ]]; then
    local _il
    _il="$(awk '/^instructions:/{print; exit}' "$template_path")"
    [[ -n "$_il" ]] && instructions_line="$_il"
  fi

  print_info "Run-wide settings"
  wizard_graph_explain "These three apply to the whole graph. The defaults are the recommended starting point; press enter to accept each."
  wizard_graph_authoring_print_topic_help "maxParallel"
  local max_parallel_default="3"
  if declare -F wizard_workflow_template_max_parallel_default >/dev/null 2>&1; then
    max_parallel_default="$(wizard_workflow_template_max_parallel_default)"
  fi
  max_parallel="$(ralph_prompt_text "Max parallel nodes" "$max_parallel_default")"
  edge_derivation="$(wizard_graph_menu edgeDerivation "How should Ralph work out the run order" 3 "declared" "artifacts" "both")"
  failure_policy="$(wizard_graph_menu failurePolicy "If a node fails" 1 "drain" "cancel")"

  print_step "2/4" "Node list"
  wizard_graph_explain "Name every node in the graph now; you will choose what each one does next. Ids use letters, digits, and hyphens, separated by commas or spaces. Order here does not set run order, dependencies do."
  read_graph_nodes

  selected_stage_ids=()
  for _s in "${selected_stages[@]}"; do
    _sid="$(ralph_internal_wizard_sanitize "$_s")"
    [[ -n "$_sid" ]] || ralph_die "Node \"$_s\" sanitizes to empty"
    selected_stage_ids+=("$_sid")
  done
  ((${#selected_stage_ids[@]} > 0)) || ralph_die "No nodes configured"

  if [[ -n "${wizard_workflow_template_source:-}" ]]; then
    print_info "Dependencies"
    wizard_graph_explain "Each node can depend on earlier nodes. Accept the template defaults or edit the dependency list per node."
    wizard_workflow_template_configure_dependencies
  fi

  print_info "Tooling profiles"
  wizard_graph_authoring_print_topic_help "tooling"
  cp_tooling_default_profile=""
  cp_tooling_overrides=()
  wizard_prompt_tooling_policy "${selected_stage_ids[@]}"
  cp_tooling_default_profile="${wizard_tooling_default_profile:-}"
  cp_tooling_overrides=(${wizard_tooling_overrides[@]+"${wizard_tooling_overrides[@]}"})

  if [[ -n "${wizard_workflow_template_source:-}" ]]; then
    cp_stages=("${selected_stage_ids[@]}")
    cp_stage_types=()
    for _s in "${selected_stage_ids[@]}"; do
      cp_stage_types+=("agent")
    done
  else
    wizard_graph_authoring_reset_graph_arrays
    wizard_graph_authoring_collect_node_types "${selected_stage_ids[@]}"
    wizard_graph_authoring_configure_nodes graph "$plan_name"
  fi

  print_step "4/4" "Review and write"
  wizard_graph_render_review "$dest" "$max_parallel" "$edge_derivation" "$failure_policy"

  confirm_write="$(ralph_prompt_yesno "Write this plan" "y")"
  if [[ "$confirm_write" == "n" ]]; then
    wizard_render_graph_cancellation_receipt
    return 0
  fi

  mkdir -p "$plans_dir"
  tmp_dest="$(mktemp "${TMPDIR:-/tmp}/ralph-graph-wizard.XXXXXX")"
  trap 'rm -f "$tmp_dest"' EXIT

  if [[ -n "${wizard_workflow_template_source:-}" && "${wizard_output_format:-plan}" == "workflow" ]]; then
    wizard_workflow_template_write_dest "$tmp_dest" "$plan_name" "$plan_overview"
  else
    wizard_render_pipeline_plan "$render_mode" "$plan_name" "$plan_overview" "$instructions_line" \
      "$max_parallel" "$edge_derivation" "$failure_policy" > "$tmp_dest"
  fi

  mv "$tmp_dest" "$dest"
  trap - EXIT

  if [[ "${wizard_output_format:-plan}" == "workflow" ]]; then
    # shellcheck source=bash-lib/plan-todo.sh
    source "${SCRIPT_DIR}/bash-lib/plan-todo.sh"
    plan_workflow_validate "$dest" || ralph_die "workflow validation failed: $dest"
    echo "Created workflow: .ralph-workspace/workflows/${plan_name}.workflow.md"
    echo ""
    echo "Start with:"
    echo "  ralph workflow start ${plan_name} --task \"<work request>\""
  else
    wizard_render_graph_creation_receipt "$dest"
  fi
}

wizard_create_plan_stage_id_valid() {
  [[ -n "$1" && "$1" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]
}

# wizard_workflow_todo_content_with_task <content> <stage_type> <plan_file>
# Ensures agent inline todos carry the reusable {{TASK}} token.
wizard_workflow_todo_content_with_task() {
  local content="$1"
  local stage_type="$2"
  local plan_file="$3"

  if [[ "$stage_type" != "agent" && "$stage_type" != "router" ]] || [[ -n "$plan_file" ]]; then
    printf '%s' "$content"
    return 0
  fi
  if [[ "$content" == *'{{TASK}}'* ]]; then
    printf '%s' "$content"
    return 0
  fi
  if [[ -z "$content" ]]; then
    printf '{{TASK}}'
    return 0
  fi
  printf '%s\n\n{{TASK}}' "$content"
}

wizard_parse_stage_mapping() {
  local raw="$1"
  local flag_name="$2"
  local stage_id value

  if [[ -z "$raw" || "$raw" != *"="* ]]; then
    ralph_die "invalid $flag_name mapping (expected stage-id=value): $raw"
  fi
  stage_id="${raw%%=*}"
  value="${raw#*=}"
  if [[ -z "$stage_id" || -z "$value" ]]; then
    ralph_die "invalid $flag_name mapping (empty stage id or value): $raw"
  fi
  stage_id="$(ralph_internal_wizard_sanitize "$stage_id")"
  if ! wizard_create_plan_stage_id_valid "$stage_id"; then
    ralph_die "invalid $flag_name mapping (invalid stage id): $raw"
  fi
  printf '%s\t%s' "$stage_id" "$value"
}

wizard_create_plan_stage_index() {
  local target="$1"
  local idx
  for idx in "${!cp_stages[@]}"; do
    if [[ "${cp_stages[$idx]}" == "$target" ]]; then
      printf '%s' "$idx"
      return 0
    fi
  done
  return 1
}

wizard_create_plan_require_known_stage() {
  local stage_id="$1"
  local flag_name="$2"
  if ! wizard_create_plan_stage_index "$stage_id" >/dev/null; then
    ralph_die "unknown stage id in $flag_name: $stage_id"
  fi
}

wizard_create_plan_append_artifact() {
  local stage_id="$1"
  local path="$2"
  local required="$3"
  local bucket="$4"
  cp_artifact_entries+=("${stage_id}|${path}|${required}|${bucket}")
}

wizard_create_plan_stage_artifacts() {
  local stage_id="$1"
  local bucket="$2"
  local entry sid path req bkt
  for entry in ${cp_artifact_entries[@]+"${cp_artifact_entries[@]}"}; do
    IFS='|' read -r sid path req bkt <<< "$entry"
    [[ "$sid" == "$stage_id" && "$bkt" == "$bucket" ]] || continue
    printf '%s|%s\n' "$path" "$req"
  done
}

wizard_create_plan_loop_index() {
  local target="$1"
  local idx
  for idx in "${!cp_loop_sources[@]}"; do
    if [[ "${cp_loop_sources[$idx]}" == "$target" ]]; then
      printf '%s' "$idx"
      return 0
    fi
  done
  return 1
}

wizard_create_plan_set_loop() {
  local source="$1"
  local target="$2"
  local max_iter="$3"
  local check_path="$4"
  local idx
  idx="$(wizard_create_plan_loop_index "$source" || true)"
  if [[ -n "$idx" ]]; then
    cp_loop_targets[$idx]="$target"
    cp_loop_max_iters[$idx]="$max_iter"
    cp_loop_check_paths[$idx]="$check_path"
    return 0
  fi
  cp_loop_sources+=("$source")
  cp_loop_targets+=("$target")
  cp_loop_max_iters+=("$max_iter")
  cp_loop_check_paths+=("$check_path")
}

wizard_create_plan_loop_target() {
  local source="$1"
  local idx
  idx="$(wizard_create_plan_loop_index "$source" || true)"
  if [[ -n "$idx" ]]; then
    printf '%s' "${cp_loop_targets[$idx]}"
  fi
  return 0
}

wizard_create_plan_loop_max() {
  local source="$1"
  local idx
  idx="$(wizard_create_plan_loop_index "$source" || true)"
  if [[ -n "$idx" ]]; then
    printf '%s' "${cp_loop_max_iters[$idx]}"
  fi
  return 0
}

wizard_create_plan_loop_check() {
  local source="$1"
  local idx
  idx="$(wizard_create_plan_loop_index "$source" || true)"
  if [[ -n "$idx" ]]; then
    printf '%s' "${cp_loop_check_paths[$idx]}"
  fi
  return 0
}

wizard_create_plan_validate_runtime() {
  local runtime="$1"
  local flag_name="$2"
  local allowed
  for allowed in "${wizard_create_plan_allowed_runtimes[@]}"; do
    [[ "$runtime" == "$allowed" ]] && return 0
  done
  ralph_die "invalid runtime in $flag_name: $runtime"
}

wizard_create_plan_validate_session_strategy() {
  local value="$1"
  local flag_name="$2"
  local allowed
  for allowed in "${wizard_create_plan_allowed_session_strategies[@]}"; do
    [[ "$value" == "$allowed" ]] && return 0
  done
  ralph_die "invalid session strategy in $flag_name: $value"
}

wizard_create_plan_validate_context_budget() {
  local value="$1"
  local flag_name="$2"
  local allowed
  for allowed in "${wizard_create_plan_allowed_context_budgets[@]}"; do
    [[ "$value" == "$allowed" ]] && return 0
  done
  ralph_die "invalid context budget in $flag_name: $value"
}

wizard_create_plan_validate_orchestration() {
  local idx stage_id runtime model produces_count
  local loop_idx loop_source loop_target loop_max loop_check loop_flags
  local has_loop_back has_loop_max has_loop_check target_idx source_idx
  local has_loop_check_produce path req

  if ((${#cp_stages[@]} == 0)); then
    ralph_die "pipeline orchestration requires at least one --stage"
  fi

  for idx in "${!cp_stages[@]}"; do
    stage_id="${cp_stages[$idx]}"
    runtime="${cp_stage_runtimes[$idx]:-}"
    model="${cp_stage_models[$idx]:-}"

    if [[ -z "$runtime" ]]; then
      ralph_die "stage $stage_id: missing --stage-runtime"
    fi
    produces_count=0
    while IFS='|' read -r path req; do
      [[ -n "$path" ]] && produces_count=$((produces_count + 1))
    done < <(wizard_create_plan_stage_artifacts "$stage_id" "produces")
    if (( produces_count == 0 )); then
      ralph_die "stage $stage_id: missing --stage-produces"
    fi
  done

  for loop_source in ${cp_loop_sources[@]+"${cp_loop_sources[@]}"}; do
    loop_target="$(wizard_create_plan_loop_target "$loop_source")"
    loop_max="$(wizard_create_plan_loop_max "$loop_source")"
    loop_check="$(wizard_create_plan_loop_check "$loop_source")"
    has_loop_back=0
    has_loop_max=0
    has_loop_check=0
    [[ -n "$loop_target" ]] && has_loop_back=1
    [[ -n "$loop_max" ]] && has_loop_max=1
    [[ -n "$loop_check" ]] && has_loop_check=1
    loop_flags=$((has_loop_back + has_loop_max + has_loop_check))
    if (( loop_flags > 0 && loop_flags < 3 )); then
      ralph_die "stage $loop_source: partial loop declaration (loopBackTo, maxIterations, and loopCheck must all be provided)"
    fi
  done

  for loop_idx in "${!cp_loop_sources[@]}"; do
    loop_source="${cp_loop_sources[$loop_idx]}"
    loop_target="${cp_loop_targets[$loop_idx]}"
    loop_max="${cp_loop_max_iters[$loop_idx]}"
    loop_check="${cp_loop_check_paths[$loop_idx]}"
    [[ -n "$loop_target" ]] || continue

    if [[ -z "$loop_max" || -z "$loop_check" ]]; then
      ralph_die "stage $loop_source: partial loop declaration (loopBackTo, maxIterations, and loopCheck must all be provided)"
    fi
    if [[ ! "$loop_max" =~ ^[1-9][0-9]*$ ]]; then
      ralph_die "stage $loop_source: invalid --stage-max-iterations value: $loop_max"
    fi

    source_idx="$(wizard_create_plan_stage_index "$loop_source")"
    target_idx="$(wizard_create_plan_stage_index "$loop_target")" || ralph_die "stage $loop_source: loopBackTo refers to unknown stage: $loop_target"
    if (( target_idx >= source_idx )); then
      ralph_die "stage $loop_source: loopBackTo must refer to an earlier stage"
    fi

    has_loop_check_produce=0
    while IFS='|' read -r path req; do
      [[ "$path" == "$loop_check" && "$req" == "true" ]] && has_loop_check_produce=1
    done < <(wizard_create_plan_stage_artifacts "$loop_source" "produces")
    if (( has_loop_check_produce == 0 )); then
      ralph_die "stage $loop_source: loopCheck.path must appear in --stage-produces with required: true"
    fi
  done

  if ((${#cp_parallel_waves[@]} > 0)); then
    local wave stage_in_wave seen_count s
    for wave in ${cp_parallel_waves[@]+"${cp_parallel_waves[@]}"}; do
      IFS=',' read -r -a wave_stages <<< "$wave"
      for stage_in_wave in "${wave_stages[@]}"; do
        stage_in_wave="$(printf '%s' "$stage_in_wave" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [[ -n "$stage_in_wave" ]] || ralph_die "invalid --parallel-wave mapping (empty stage id)"
        wizard_create_plan_require_known_stage "$stage_in_wave" "--parallel-wave"
        seen_count=0
        for s in ${cp_parallel_waves[@]+"${cp_parallel_waves[@]}"}; do
          IFS=',' read -r -a _parts <<< "$s"
          for _p in "${_parts[@]}"; do
            _p="$(printf '%s' "$_p" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            [[ "$_p" == "$stage_in_wave" ]] && seen_count=$((seen_count + 1))
          done
        done
        if (( seen_count > 1 )); then
          ralph_die "duplicate stage id in --parallel-wave: $stage_in_wave"
        fi
      done
    done
  fi
}

wizard_render_artifact_list_yaml() {
  local stage_id="$1"
  local bucket="$2"
  local indent="$3"
  local -a lines=()
  local path req

  while IFS='|' read -r path req; do
    [[ -n "$path" ]] || continue
    lines+=("${indent}- path: ${path}")
    if [[ "$req" == "false" ]]; then
      lines+=("${indent}  required: false")
    else
      lines+=("${indent}  required: true")
    fi
  done < <(wizard_create_plan_stage_artifacts "$stage_id" "$bucket")

  if ((${#lines[@]} == 0)); then
    return 0
  fi
  local IFS=$'\n'
  printf '%s\n' "${lines[*]}"
}

wizard_render_todo_artifact_content() {
  local stage_id="$1"
  local -a write_paths=() read_paths=()
  local path req

  while IFS='|' read -r path req; do
    [[ -n "$path" ]] || continue
    write_paths+=("$path")
  done < <(wizard_create_plan_stage_artifacts "$stage_id" "produces")

  while IFS='|' read -r path req; do
    [[ -n "$path" ]] || continue
    read_paths+=("$path")
  done < <(wizard_create_plan_stage_artifacts "$stage_id" "requires")

  if ((${#read_paths[@]} > 0)); then
    printf 'Read input artifacts:\n'
    for path in "${read_paths[@]}"; do
      printf '  - %s\n' "$path"
    done
  fi
  if ((${#write_paths[@]} > 0)); then
    if ((${#read_paths[@]} > 0)); then
      printf '\n'
    fi
    printf 'Write outputs:\n'
    for path in "${write_paths[@]}"; do
      printf '  - %s\n' "$path"
    done
  fi
  if ((${#read_paths[@]} == 0 && ${#write_paths[@]} == 0)); then
    printf 'Complete the %s stage work.' "$stage_id"
  fi
}

wizard_render_todo_verification() {
  local stage_id="$1"
  local -a required_paths=()
  local path req

  while IFS='|' read -r path req; do
    [[ -n "$path" && "$req" != "false" ]] || continue
    required_paths+=("$path")
  done < <(wizard_create_plan_stage_artifacts "$stage_id" "produces")

  if ((${#required_paths[@]} == 0)); then
    printf 'Confirm required outputs for stage %s exist and are non-empty.' "$stage_id"
    return 0
  fi

  if ((${#required_paths[@]} == 1)); then
    printf 'Confirm %s exists and is non-empty.' "${required_paths[0]}"
    return 0
  fi

  printf 'Confirm required outputs exist and are non-empty:\n'
  for path in "${required_paths[@]}"; do
    printf '  - %s\n' "$path"
  done
}

wizard_orch_stage_to_pipeline_stage_json() {
  local stage_json="$1"
  python3 - "$stage_json" <<'PY'
import json, sys

stage = json.loads(sys.argv[1])
out = {}
for key in ("id", "runtime", "agent", "model"):
    if key in stage and stage[key] not in ("", None):
        out[key] = stage[key]

if stage.get("sessionStrategy") not in ("", None):
    out["sessionStrategy"] = stage["sessionStrategy"]
elif stage.get("sessionResume") not in ("", None):
    out["sessionStrategy"] = "resume" if stage["sessionResume"] else "fresh"

if stage.get("contextBudget") not in ("", None):
    out["contextBudget"] = stage["contextBudget"]

produces = []
for artifact in stage.get("artifacts", []) or []:
    path = artifact.get("path")
    if path:
        produces.append({"path": path, "required": bool(artifact.get("required", True))})
for artifact in stage.get("outputArtifacts", []) or []:
    path = artifact.get("path")
    if path:
        produces.append({"path": path, "required": bool(artifact.get("required", True))})
if produces:
    out["produces"] = produces

requires = []
for artifact in stage.get("inputArtifacts", []) or []:
    path = artifact.get("path")
    if path:
        requires.append({"path": path, "required": bool(artifact.get("required", True))})
if requires:
    out["requires"] = requires

loop = stage.get("loopControl") or {}
if loop.get("loopBackTo") not in ("", None):
    out["loopBackTo"] = loop["loopBackTo"]
if loop.get("maxIterations") not in ("", None):
    out["maxIterations"] = loop["maxIterations"]

print(json.dumps(out, separators=(",", ":")))
PY
}

# wizard_render_pipeline_plan <mode> <plan_name> <plan_overview> <instructions_line>
#   [max_parallel] [edge_derivation] [failure_policy]
#
# mode is "orchestration" or "graph". Both share the same stages:/requires:/
# produces:/todos: shape (a graph node is a pipeline stage plus a few extra
# fields), so this single function renders both instead of duplicating the
# stage/todo loops per mode. Reads cp_stages[]/cp_stage_types[]/... and, for
# graph mode, cp_stage_depends_on[]/cp_stage_policy[]/cp_stage_quorum[]/
# cp_stage_workspace_mode[]/cp_voter_*[] populated by the caller.
wizard_render_pipeline_plan() {
  local mode="$1"
  local plan_name="$2"
  local plan_overview="$3"
  local instructions_line="$4"
  local max_parallel="${5:-}"
  local edge_derivation="${6:-}"
  local failure_policy="${7:-}"
  local idx stage_id stage_type runtime agent role model native_subagents session context plan_file
  local loop_target loop_max loop_check depends_on policy quorum workspace_mode
  local profile write_scopes router_allowed router_default router_terminal router_on_invalid
  local dep_id vpidx scope_token graph_shape="false"
  local -a yaml_lines=()
  local requires_yaml produces_yaml todo_id todo_content todo_verification line

  if [[ "$mode" == "graph" || ( "${wizard_output_format:-plan}" == "workflow" && "${wizard_workflow_engine:-$mode}" == "graph" ) ]]; then
    graph_shape="true"
  fi

  yaml_lines+=("---")
  yaml_lines+=("name: ${plan_name}")
  yaml_lines+=("overview: ${plan_overview}")
  if [[ "${wizard_output_format:-plan}" == "workflow" ]]; then
    local wf_engine="${wizard_workflow_engine:-$mode}" wf_public_mode
    case "$wf_engine" in
      graph) wf_public_mode="dependency" ;;
      orchestration) wf_public_mode="sequential" ;;
      *) wf_public_mode="$wf_engine" ;;
    esac
    yaml_lines+=("kind: workflow")
    yaml_lines+=("mode: ${wf_public_mode}")
  else
    local pl_public_mode
    case "$mode" in
      graph) pl_public_mode="dependency" ;;
      orchestration) pl_public_mode="sequential" ;;
      *) pl_public_mode="$mode" ;;
    esac
    yaml_lines+=("mode: ${pl_public_mode}")
  fi
  yaml_lines+=("${instructions_line}")
  yaml_lines+=("pipeline:")
  if [[ "$graph_shape" == "true" ]]; then
    [[ -n "$max_parallel" ]] && yaml_lines+=("  maxParallel: ${max_parallel}")
    [[ -n "$edge_derivation" ]] && yaml_lines+=("  edgeDerivation: ${edge_derivation}")
    [[ -n "$failure_policy" ]] && yaml_lines+=("  failurePolicy: ${failure_policy}")
    if ((${#cp_vp_name[@]} > 0)); then
      yaml_lines+=("  verificationProfiles:")
      for vpidx in "${!cp_vp_name[@]}"; do
        yaml_lines+=("    - name: ${cp_vp_name[$vpidx]}")
        yaml_lines+=("      steps:")
        yaml_lines+=("        - name: ${cp_vp_step_name[$vpidx]}")
        yaml_lines+=("          command: ${cp_vp_step_command[$vpidx]}")
      done
    fi
  fi
  if [[ -n "${cp_tooling_default_profile:-}" ]]; then
    yaml_lines+=("  tooling:")
    yaml_lines+=("    defaultProfile: ${cp_tooling_default_profile}")
    if ((${#cp_tooling_overrides[@]} > 0)); then
      yaml_lines+=("    overrides:")
      local tooling_override
      for tooling_override in "${cp_tooling_overrides[@]}"; do
        [[ -n "$tooling_override" ]] || continue
        yaml_lines+=("      ${tooling_override%%=*}: ${tooling_override#*=}")
      done
    fi
  fi
  yaml_lines+=("  stages:")

  for idx in "${!cp_stages[@]}"; do
    stage_id="${cp_stages[$idx]}"
    stage_type="${cp_stage_types[$idx]:-agent}"
    runtime="${cp_stage_runtimes[$idx]:-}"
    role="${cp_stage_roles[$idx]:-}"
    model="${cp_stage_models[$idx]:-}"
    native_subagents="${cp_stage_native_subagents[$idx]:-}"
    session="${cp_stage_session[$idx]:-}"
    context="${cp_stage_context[$idx]:-}"
    plan_file="${cp_stage_plan_files[$idx]:-}"
    depends_on="${cp_stage_depends_on[$idx]:-}"
    policy="${cp_stage_policy[$idx]:-}"
    quorum="${cp_stage_quorum[$idx]:-}"
    workspace_mode="${cp_stage_workspace_mode[$idx]:-}"
    profile="${cp_stage_profile[$idx]:-}"
    write_scopes="${cp_stage_write_scopes[$idx]:-}"
    router_allowed="${cp_stage_router_allowed[$idx]:-}"
    router_default="${cp_stage_router_default[$idx]:-}"
    router_terminal="${cp_stage_router_terminal[$idx]:-}"
    router_on_invalid="${cp_stage_router_on_invalid[$idx]:-}"

    yaml_lines+=("    - id: ${stage_id}")
    if [[ "$graph_shape" == "true" && "$stage_type" != "agent" ]]; then
      yaml_lines+=("      type: ${stage_type}")
    fi

    if [[ "$stage_type" == "agent" ]]; then
      if [[ -n "$plan_file" ]]; then
        yaml_lines+=("      planFile: ${plan_file}")
      else
        yaml_lines+=("      runtime: ${runtime}")
        [[ -n "$native_subagents" ]] && yaml_lines+=("      nativeSubagents: ${native_subagents}")
        [[ -n "$model" ]] && yaml_lines+=("      model: ${model}")
      fi
      [[ -n "$session" ]] && yaml_lines+=("      sessionStrategy: ${session}")
      [[ -n "$context" ]] && yaml_lines+=("      contextBudget: ${context}")
    fi

    if [[ "$graph_shape" == "true" ]]; then
      if [[ "$stage_type" == "consensus" || "$stage_type" == "join" ]]; then
        [[ -n "$policy" ]] && yaml_lines+=("      policy: ${policy}")
        [[ -n "$quorum" ]] && yaml_lines+=("      quorum: ${quorum}")
      fi
      if [[ "$stage_type" == "gate" && -n "$profile" ]]; then
        yaml_lines+=("      profile: ${profile}")
      fi
      if [[ -n "$depends_on" ]]; then
        yaml_lines+=("      dependsOn:")
        local dep_id
        local -a dep_ids=()
        IFS=',' read -r -a dep_ids <<< "$depends_on"
        for dep_id in "${dep_ids[@]}"; do
          dep_id="$(printf '%s' "$dep_id" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
          [[ -n "$dep_id" ]] || continue
          yaml_lines+=("        - ${dep_id}")
        done
      fi
    fi

    requires_yaml="$(wizard_render_artifact_list_yaml "$stage_id" "requires" "        ")"
    produces_yaml="$(wizard_render_artifact_list_yaml "$stage_id" "produces" "        ")"
    if [[ -n "$requires_yaml" ]]; then
      yaml_lines+=("      requires:")
      while IFS= read -r line; do [[ -n "$line" ]] && yaml_lines+=("$line"); done <<< "$requires_yaml"
    fi
    if [[ -n "$produces_yaml" ]]; then
      yaml_lines+=("      produces:")
      while IFS= read -r line; do [[ -n "$line" ]] && yaml_lines+=("$line"); done <<< "$produces_yaml"
    fi

    if [[ "$graph_shape" == "true" && "$stage_type" == "consensus" ]]; then
      yaml_lines+=("      voters:")
      local vidx voter_id voter_runtime voter_model
      for vidx in "${!cp_voter_node[@]}"; do
        [[ "${cp_voter_node[$vidx]}" == "$stage_id" ]] || continue
        voter_id="${cp_voter_id[$vidx]}"
        voter_runtime="${cp_voter_runtime[$vidx]}"
        voter_model="${cp_voter_model[$vidx]:-}"
        yaml_lines+=("        - id: ${voter_id}")
        yaml_lines+=("          runtime: ${voter_runtime}")
        [[ -n "$voter_model" ]] && yaml_lines+=("          model: ${voter_model}")
      done
    fi

    if [[ "$graph_shape" == "true" && (("$stage_type" == "agent" && -n "$workspace_mode") || "$stage_type" == "integrate") && -n "$workspace_mode" ]]; then
      yaml_lines+=("      workspaceMode: ${workspace_mode}")
      if [[ "$workspace_mode" == "shared" ]]; then
        yaml_lines+=("      acknowledgeSharedMutationRisk: true")
        yaml_lines+=("      parallelMutation: allow")
      fi
    fi

    if [[ "$graph_shape" == "true" && "$stage_type" == "agent" && -n "$write_scopes" ]]; then
      yaml_lines+=("      writeScopes:")
      local -a scope_tokens=()
      IFS=',' read -r -a scope_tokens <<< "$write_scopes"
      for scope_token in "${scope_tokens[@]}"; do
        scope_token="$(printf '%s' "$scope_token" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [[ -n "$scope_token" ]] || continue
        yaml_lines+=("        - ${scope_token}")
      done
    fi

    if [[ "$graph_shape" == "true" && "$stage_type" == "router" && -n "$router_allowed" ]]; then
      yaml_lines+=("      router:")
      yaml_lines+=("        allowedTargets:")
      local -a target_tokens=()
      IFS=',' read -r -a target_tokens <<< "$router_allowed"
      for dep_id in "${target_tokens[@]}"; do
        dep_id="$(printf '%s' "$dep_id" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [[ -n "$dep_id" ]] || continue
        yaml_lines+=("          - ${dep_id}")
      done
      [[ -n "$router_default" ]] && yaml_lines+=("        defaultTarget: ${router_default}")
      if [[ -n "$router_terminal" ]]; then
        yaml_lines+=("        terminalOutcomes:")
        IFS=',' read -r -a target_tokens <<< "$router_terminal"
        for dep_id in "${target_tokens[@]}"; do
          dep_id="$(printf '%s' "$dep_id" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
          [[ -n "$dep_id" ]] || continue
          yaml_lines+=("          - ${dep_id}")
        done
      fi
      [[ -n "$router_on_invalid" ]] && yaml_lines+=("        onInvalid: ${router_on_invalid}")
    fi

    if [[ "$mode" == "orchestration" ]]; then
      loop_target="$(wizard_create_plan_loop_target "$stage_id")"
      if [[ -n "$loop_target" ]]; then
        loop_max="$(wizard_create_plan_loop_max "$stage_id")"
        loop_check="$(wizard_create_plan_loop_check "$stage_id")"
        yaml_lines+=("      loopBackTo: ${loop_target}")
        yaml_lines+=("      maxIterations: ${loop_max}")
        yaml_lines+=("      loopCheck:")
        yaml_lines+=("        path: ${loop_check}")
      fi
    fi
  done

  if [[ "$mode" == "orchestration" ]] && ((${#cp_parallel_waves[@]} > 0)); then
    yaml_lines+=("  parallelStages:")
    local wave rendered_wave w
    for wave in ${cp_parallel_waves[@]+"${cp_parallel_waves[@]}"}; do
      local -a wave_ids=()
      IFS=',' read -r -a wave_ids <<< "$wave"
      rendered_wave=""
      for w in "${wave_ids[@]}"; do
        w="$(printf '%s' "$w" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [[ -n "$w" ]] || continue
        if [[ -n "$rendered_wave" ]]; then
          rendered_wave+=", ${w}"
        else
          rendered_wave="$w"
        fi
      done
      yaml_lines+=("    - [${rendered_wave}]")
    done
  fi

  yaml_lines+=("")
  yaml_lines+=("todos:")

  for idx in "${!cp_stages[@]}"; do
    stage_id="${cp_stages[$idx]}"
    stage_type="${cp_stage_types[$idx]:-agent}"
    plan_file="${cp_stage_plan_files[$idx]:-}"
    policy="${cp_stage_policy[$idx]:-}"
    todo_id="${stage_id}-1"

    yaml_lines+=("  - id: ${todo_id}")
    yaml_lines+=("    stage: ${stage_id}")

    if [[ "$stage_type" == "consensus" ]]; then
      yaml_lines+=("    content: |")
      yaml_lines+=("      Review the upstream result and record a verdict for the ${policy:-veto} policy.")
      yaml_lines+=("    verification: |")
      yaml_lines+=("      Confirm a verdict artifact exists for this voter.")
    elif [[ "$stage_type" == "join" ]]; then
      yaml_lines+=("    content: |")
      yaml_lines+=("      Apply the ${policy:-veto} policy to the upstream verdicts.")
      yaml_lines+=("    verification: |")
      yaml_lines+=("      Confirm a consensus-result artifact was written under the consensus directory.")
    elif [[ "$stage_type" == "checkpoint" ]]; then
      yaml_lines+=("    content: |")
      yaml_lines+=("      Wait for a human to acknowledge \"${stage_id}\" before closing out.")
      yaml_lines+=("    verification: |")
      yaml_lines+=("      Confirm the acknowledgement artifact exists.")
    elif [[ "$stage_type" == "gate" ]]; then
      yaml_lines+=("    content: |")
      yaml_lines+=("      Run the declared verification profile for this gate.")
      yaml_lines+=("    verification: |")
      yaml_lines+=("      Confirm the gate outcome records passed or changes-required.")
    elif [[ "$stage_type" == "integrate" ]]; then
      yaml_lines+=("    content: |")
      yaml_lines+=("      Merge upstream isolated changesets in declared dependency order.")
      yaml_lines+=("    verification: |")
      yaml_lines+=("      Confirm integration produced a changeset manifest without conflicts.")
    elif [[ "$stage_type" == "router" ]]; then
      yaml_lines+=("    content: |")
      yaml_lines+=("      Choose the next branch target from the allowed router targets.")
      yaml_lines+=("    verification: |")
      yaml_lines+=("      Confirm a router-decision artifact names one allowed target.")
    elif [[ -n "$plan_file" ]]; then
      yaml_lines+=("    content: |")
      yaml_lines+=("      Run nested plan: ${plan_file}")
      yaml_lines+=("    verification: |")
      yaml_lines+=("      Nested plan completed successfully.")
    else
      if [[ -n "${cp_stage_inline_content[$idx]:-}" ]]; then
        todo_content="${cp_stage_inline_content[$idx]}"
      else
        todo_content="$(wizard_render_todo_artifact_content "$stage_id")"
      fi
      if [[ -n "${cp_stage_inline_verification[$idx]:-}" ]]; then
        todo_verification="${cp_stage_inline_verification[$idx]}"
      else
        todo_verification="$(wizard_render_todo_verification "$stage_id")"
      fi
      if [[ "${wizard_output_format:-plan}" == "workflow" ]]; then
        todo_content="$(wizard_workflow_todo_content_with_task "$todo_content" "$stage_type" "$plan_file")"
      fi
      yaml_lines+=("    content: |")
      while IFS= read -r line || [[ -n "${line:-}" ]]; do
        yaml_lines+=("      ${line}")
      done <<< "$todo_content"
      yaml_lines+=("    verification: |")
      while IFS= read -r line || [[ -n "${line:-}" ]]; do
        yaml_lines+=("      ${line}")
      done <<< "$todo_verification"
    fi

    yaml_lines+=("    status: pending")
  done

  yaml_lines+=("isProject: false")
  yaml_lines+=("---")

  local IFS=$'\n'
  printf '%s\n' "${yaml_lines[*]}"
}

# wizard_render_pipeline_orchestration_plan <plan_name> <plan_overview> <instructions_line>
# Backward-compatible entry point for the orchestration-only shape; delegates
# to wizard_render_pipeline_plan.
wizard_render_pipeline_orchestration_plan() {
  wizard_render_pipeline_plan orchestration "$1" "$2" "$3"
}

wizard_create_plan_interactive_execution_mode() {
  ralph_menu_select --prompt "Plan execution mode" --default 1 -- "standard" "orchestration"
}

wizard_create_plan_interactive_orchestration() {
  local plan_name="$1"
  local plan_overview="$2"
  local instructions_line="$3"
  local stage stage_id runtime role native_subagents session context produces_input requires_input
  local artifact_default loop_idx loop_source loop_target loop_max

  cp_stages=()
  cp_stage_runtimes=()
  cp_stage_roles=()
  cp_stage_native_subagents=()
  cp_stage_models=()
  cp_stage_session=()
  cp_stage_context=()
  cp_artifact_entries=()
  cp_parallel_waves=()
  cp_loop_sources=()
  cp_loop_targets=()
  cp_loop_max_iters=()
  cp_loop_check_paths=()

  print_step "1/4" "Stage list"
  read_stages
  if ((${#selected_stages[@]} == 0)); then
    ralph_die "No stages configured"
  fi

  for stage in "${selected_stages[@]}"; do
    stage_id="$(ralph_internal_wizard_sanitize "$stage")"
    [[ -n "$stage_id" ]] || ralph_die "Stage \"$stage\" sanitizes to empty"
    cp_stages+=("$stage_id")
  done

  print_step "2/4" "Configure each stage"
  for stage_id in "${cp_stages[@]}"; do
    print_info "Configuring stage \"$stage_id\""
    runtime="$(select_runtime "$stage_id")"
    role="$(select_role "$stage_id")"
    native_subagents="$(select_native_subagents "$stage_id")"
    wizard_print_runtime_role_model_subagents "Stage $stage_id" "$runtime" "$role" "$native_subagents"
    cp_stage_runtimes+=("$runtime")
    cp_stage_roles+=("$role")
    cp_stage_native_subagents+=("$native_subagents")
    cp_stage_models+=("")
    session="$(select_session_strategy "$stage_id")"
    context="$(select_context_budget "$stage_id")"
    cp_stage_session+=("$session")
    cp_stage_context+=("$context")
  done

  print_step "3/4" "Stage artifacts"
  for stage_id in "${cp_stages[@]}"; do
    artifact_default=".ralph-workspace/artifacts/{{ARTIFACT_NS}}/$(artifact_file_for_stage "$stage_id")"
    produces_input="$(ralph_prompt_text "Output artifact path for \"$stage_id\"" "$artifact_default")"
    [[ -n "$produces_input" ]] || ralph_die "stage $stage_id: missing output artifact path"
    wizard_create_plan_append_artifact "$stage_id" "$produces_input" "true" "produces"

    requires_input="$(ralph_prompt_text "Required input artifact path for \"$stage_id\" (optional)" "")"
    if [[ -n "$requires_input" ]]; then
      wizard_create_plan_append_artifact "$stage_id" "$requires_input" "true" "requires"
    fi
  done

  stage_ids=("${cp_stages[@]}")
  configure_parallel_stages
  cp_parallel_waves=("${parallel_stage_waves[@]}")

  print_step "4/4" "Loop rules (optional)"
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

  wizard_create_plan_validate_orchestration
  wizard_render_pipeline_orchestration_plan "$plan_name" "$plan_overview" "$instructions_line"
}



# ---------------------------------------------------------------------------
# Graph completion branch (G02): the post-authoring receipt every graph
# wizard/CLI creation path prints. These three functions are pure text
# producers -- they never execute, compile, or run a graph; they only print
# the commands an operator would run next. Callers (the interactive
# pipeline-wizard.sh and non-interactive create-plan.sh graph completion
# branches) select exactly one of the three depending on outcome:
#   - success:            wizard_render_graph_creation_receipt <plan-path>
#   - operator cancelled: wizard_render_graph_cancellation_receipt
#   - validation failed:  wizard_render_graph_validation_failure_receipt \
#                             <failing-command> <remediation>
# ---------------------------------------------------------------------------

# wizard_render_graph_creation_receipt <plan-path>
#
# G02: after a successful graph plan is written, print exactly four
# copy-pasteable next commands built from the actual, shell-escaped plan
# path (handles spaces and other shell-significant characters via `%q`).
# The first three (validate, render, preflight) are read-only; only the
# fourth (`run`) is labeled mutating -- it is the only one that creates a
# run-state ledger entry or can invoke a paid model.
wizard_render_graph_creation_receipt() {
  local plan_path="${1:?wizard_render_graph_creation_receipt requires a plan path}"
  local quoted
  quoted="$(printf '%q' "$plan_path")"

  printf 'Created graph plan: %s\n' "$quoted"
  printf '\n'
  printf 'Next steps:\n'
  printf '  1) bash .ralph/validate-plan.sh %s\n' "$quoted"
  printf '     read-only: validate plan syntax\n'
  printf '  2) ralph workflow inspect --file %s --format mermaid\n' "$quoted"
  printf '     read-only: view the graph shape\n'
  printf '  3) ralph workflow inspect --file %s\n' "$quoted"
  printf '     read-only: capability report and invocation preview\n'
  printf '  4) ralph workflow start --file %s --task "<work request>"\n' "$quoted"
  printf '     MUTATING: creates a run-state ledger and may invoke a paid model\n'
  printf '\n'
  printf 'Only step 4 (run) mutates state or invokes a model; steps 1-3 are read-only.\n'
}

# wizard_render_graph_cancellation_receipt
#
# G02: the exact, fixed cancellation receipt. Prints one line and nothing
# else -- no plan path, no command, because none was run.
wizard_render_graph_cancellation_receipt() {
  printf 'No plan created; no command was run.\n'
}

# wizard_render_graph_validation_failure_receipt <failing-command> <remediation>
#
# G02: on validation failure, print only the one failing validation command
# and its remediation -- never the full four-command receipt, and never a
# partial/mixed dump of unrelated commands.
wizard_render_graph_validation_failure_receipt() {
  local failing_command="${1:?wizard_render_graph_validation_failure_receipt requires a failing command}"
  local remediation="${2:?wizard_render_graph_validation_failure_receipt requires remediation text}"

  printf '%s\n' "$failing_command"
  printf '%s\n' "$remediation"
}

# wizard_sequential_yaml_block <indent_spaces> <text>
# Emit a YAML block scalar (|). Empty text emits nothing.
wizard_sequential_yaml_block() {
  local indent="$1"
  local text="${2-}"
  local line
  [[ -n "$text" ]] || return 0
  printf '%s|\n' "$indent"
  while IFS= read -r line || [[ -n "$line" ]]; do
    printf '%s  %s\n' "$indent" "$line"
  done <<< "$text"
}

# wizard_render_sequential_workflow <plan_name> <plan_overview> [instructions_line]
# Emit kind: workflow / mode: sequential authored source from cp_* arrays.
# Never emits engine, graph, orchestration, or humanAck vocabulary.
wizard_render_sequential_workflow() {
  local plan_name="$1"
  local plan_overview="$2"
  local instructions_line="${3:-instructions: Execute one TODO at a time. Keep reusable policy here; pass the concrete request via {{TASK}} at start.}"
  local idx stage_id stage_type runtime model plan_file plan_from planner_max
  local question changes_target instructions depends_on work_source
  local -a yaml_lines=()
  local requires_yaml produces_yaml line todo_id todo_content todo_verification
  local planner_schema="bundle/.ralph/schemas/planner-output.schema.json"

  yaml_lines+=("---")
  yaml_lines+=("name: ${plan_name}")
  yaml_lines+=("overview: ${plan_overview}")
  yaml_lines+=("kind: workflow")
  yaml_lines+=("mode: sequential")
  local header_extra
  header_extra="$(wizard_workflow_emit_defaults_plan_input_yaml)"
  if [[ -n "$header_extra" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -n "$line" ]] && yaml_lines+=("$line")
    done <<< "$header_extra"
  fi
  yaml_lines+=("${instructions_line}")
  yaml_lines+=("pipeline:")

  if [[ -n "${cp_tooling_default_profile:-}" ]]; then
    yaml_lines+=("  tooling:")
    yaml_lines+=("    defaultProfile: ${cp_tooling_default_profile}")
    if ((${#cp_tooling_overrides[@]} > 0)); then
      yaml_lines+=("    overrides:")
      local tooling_override
      for tooling_override in "${cp_tooling_overrides[@]}"; do
        [[ -n "$tooling_override" ]] || continue
        yaml_lines+=("      ${tooling_override%%=*}: ${tooling_override#*=}")
      done
    fi
  fi

  yaml_lines+=("  stages:")

  for idx in "${!cp_stages[@]}"; do
    stage_id="${cp_stages[$idx]}"
    stage_type="${cp_stage_types[$idx]:-agent}"
    runtime="${cp_stage_runtimes[$idx]:-}"
    model="${cp_stage_models[$idx]:-}"
    plan_file="${cp_stage_plan_files[$idx]:-}"
    plan_from="${cp_stage_plan_from[$idx]:-}"
    planner_max="${cp_stage_planner_max[$idx]:-}"
    question="${cp_stage_question[$idx]:-}"
    changes_target="${cp_stage_changes_target[$idx]:-}"
    instructions="${cp_stage_instructions[$idx]:-}"
    depends_on="${cp_stage_depends_on[$idx]:-}"
    work_source="${cp_stage_work_source[$idx]:-}"

    yaml_lines+=("    - id: ${stage_id}")

    if [[ "$stage_type" == "approval" || "$work_source" == "approval" ]]; then
      yaml_lines+=("      type: approval")
      yaml_lines+=("      question: ${question}")
      yaml_lines+=("      changesTarget: ${changes_target}")
      if [[ -n "$depends_on" ]]; then
        yaml_lines+=("      dependsOn:")
        local dep_id
        local -a dep_ids=()
        IFS=',' read -r -a dep_ids <<< "$depends_on"
        for dep_id in "${dep_ids[@]}"; do
          dep_id="$(printf '%s' "$dep_id" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
          [[ -n "$dep_id" ]] || continue
          yaml_lines+=("        - ${dep_id}")
        done
      fi
      requires_yaml="$(wizard_render_artifact_list_yaml "$stage_id" "requires" "        ")"
      if [[ -n "$requires_yaml" ]]; then
        yaml_lines+=("      requires:")
        while IFS= read -r line; do [[ -n "$line" ]] && yaml_lines+=("$line"); done <<< "$requires_yaml"
      fi
      continue
    fi

    if [[ -n "$planner_max" ]]; then
      yaml_lines+=("      planner:")
      yaml_lines+=("        outputMode: plan-file")
      yaml_lines+=("        maxTodos: ${planner_max}")
    fi

    if [[ -n "$plan_from" ]]; then
      yaml_lines+=("      planFrom: ${plan_from}")
    elif [[ -n "$plan_file" ]]; then
      yaml_lines+=("      planFile: ${plan_file}")
    fi

    [[ -n "$runtime" ]] && yaml_lines+=("      runtime: ${runtime}")
    [[ -n "$model" ]] && yaml_lines+=("      model: ${model}")

    if [[ -n "$instructions" ]]; then
      yaml_lines+=("      instructions: |")
      while IFS= read -r line || [[ -n "$line" ]]; do
        yaml_lines+=("        ${line}")
      done <<< "$instructions"
    fi

    if [[ -n "$depends_on" ]]; then
      yaml_lines+=("      dependsOn:")
      local dep_id
      local -a dep_ids=()
      IFS=',' read -r -a dep_ids <<< "$depends_on"
      for dep_id in "${dep_ids[@]}"; do
        dep_id="$(printf '%s' "$dep_id" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [[ -n "$dep_id" ]] || continue
        yaml_lines+=("        - ${dep_id}")
      done
    fi

    requires_yaml="$(wizard_render_artifact_list_yaml "$stage_id" "requires" "        ")"
    produces_yaml="$(wizard_render_artifact_list_yaml "$stage_id" "produces" "        ")"
    if [[ -n "$requires_yaml" ]]; then
      yaml_lines+=("      requires:")
      while IFS= read -r line; do [[ -n "$line" ]] && yaml_lines+=("$line"); done <<< "$requires_yaml"
    fi

    local emitted_planner_json=0
    if [[ -n "$produces_yaml" ]]; then
      yaml_lines+=("      produces:")
      while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        yaml_lines+=("$line")
        # Attach planner schema on the required .json produce path for this stage.
        if [[ -n "$planner_max" && "$line" == *"path: "*".json" ]]; then
          yaml_lines+=("          schema: ${planner_schema}")
          emitted_planner_json=1
        fi
      done <<< "$produces_yaml"
    fi
    if [[ -n "$planner_max" && "$emitted_planner_json" -eq 0 ]]; then
      if [[ -z "$produces_yaml" ]]; then
        yaml_lines+=("      produces:")
      fi
      yaml_lines+=("        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/${stage_id}-plan.json")
      yaml_lines+=("          schema: ${planner_schema}")
      yaml_lines+=("          required: true")
    fi
  done

  if ((${#cp_parallel_waves[@]} > 0)); then
    yaml_lines+=("  parallelStages:")
    local wave rendered_wave w
    for wave in ${cp_parallel_waves[@]+"${cp_parallel_waves[@]}"}; do
      local -a wave_ids=()
      IFS=',' read -r -a wave_ids <<< "$wave"
      rendered_wave=""
      for w in "${wave_ids[@]}"; do
        w="$(printf '%s' "$w" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [[ -n "$w" ]] || continue
        if [[ -n "$rendered_wave" ]]; then
          rendered_wave+=", ${w}"
        else
          rendered_wave="$w"
        fi
      done
      yaml_lines+=("    - [${rendered_wave}]")
    done
  fi

  yaml_lines+=("")
  yaml_lines+=("todos:")

  local wrote_todo=0
  for idx in "${!cp_stages[@]}"; do
    stage_id="${cp_stages[$idx]}"
    stage_type="${cp_stage_types[$idx]:-agent}"
    work_source="${cp_stage_work_source[$idx]:-}"
    plan_file="${cp_stage_plan_files[$idx]:-}"
    plan_from="${cp_stage_plan_from[$idx]:-}"
    planner_max="${cp_stage_planner_max[$idx]:-}"

    # Approval gates and planFrom consumers do not take authored TODOs.
    if [[ "$stage_type" == "approval" || "$work_source" == "approval" ]]; then
      continue
    fi
    if [[ -n "$plan_from" ]]; then
      continue
    fi
    if [[ -n "$plan_file" && -z "$planner_max" ]]; then
      # Static planFile stages are plan-backed; no authored inline TODO.
      continue
    fi
    # planInput consumer is plan-backed via supplied --plan; no authored TODOs.
    if [[ -n "${cp_plan_input_stage:-}" && "$stage_id" == "$cp_plan_input_stage" ]]; then
      continue
    fi

    todo_id="${stage_id}-1"
    wrote_todo=1
    yaml_lines+=("  - id: ${todo_id}")
    yaml_lines+=("    stage: ${stage_id}")

    if [[ -n "${cp_stage_inline_content[$idx]:-}" ]]; then
      todo_content="${cp_stage_inline_content[$idx]}"
    elif [[ -n "$planner_max" ]]; then
      todo_content="Plan the fewest independently verifiable TODOs that fully cover:
{{TASK}}"
    else
      todo_content="$(wizard_render_todo_artifact_content "$stage_id")"
    fi
    todo_content="$(wizard_workflow_todo_content_with_task "$todo_content" "agent" "")"

    if [[ -n "${cp_stage_inline_verification[$idx]:-}" ]]; then
      todo_verification="${cp_stage_inline_verification[$idx]}"
    elif [[ -n "$planner_max" ]]; then
      todo_verification="Confirm the required planner JSON artifact exists and validates."
    else
      todo_verification="$(wizard_render_todo_verification "$stage_id")"
    fi

    yaml_lines+=("    content: |")
    while IFS= read -r line || [[ -n "$line" ]]; do
      yaml_lines+=("      ${line}")
    done <<< "$todo_content"
    yaml_lines+=("    verification: |")
    while IFS= read -r line || [[ -n "$line" ]]; do
      yaml_lines+=("      ${line}")
    done <<< "$todo_verification"
    yaml_lines+=("    status: pending")
  done

  if (( wrote_todo == 0 )); then
    # Validator requires at least one TODO when agent stages exist without planFile/planFrom;
    # all-approval or all-planFrom workflows still need a seed TODO on a planner/inline stage.
    yaml_lines+=("  - id: workflow-policy-1")
    yaml_lines+=("    content: |")
    yaml_lines+=("      Reusable Sequential workflow policy for:")
    yaml_lines+=("      {{TASK}}")
    yaml_lines+=("    verification: |")
    yaml_lines+=("      Confirm workflow authoring is complete.")
    yaml_lines+=("    status: pending")
  fi

  yaml_lines+=("---")

  local out
  out="$(printf '%s\n' "${yaml_lines[@]}")"
  if wizard_sequential_text_has_forbidden_vocab "$out"; then
    ralph_die "sequential workflow render leaked internal vocabulary"
  fi
  printf '%s\n' "$out"
}

# wizard_sequential_ensure_depends_on <idx> <dep_id>
# Append dep_id to cp_stage_depends_on[idx] if missing.
wizard_sequential_ensure_depends_on() {
  local idx="$1"
  local dep_id="$2"
  local current="${cp_stage_depends_on[$idx]:-}"
  if [[ -z "$current" ]]; then
    cp_stage_depends_on[$idx]="$dep_id"
    return 0
  fi
  local tok
  local IFS=','
  for tok in $current; do
    tok="$(printf '%s' "$tok" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ "$tok" == "$dep_id" ]] && return 0
  done
  unset IFS
  cp_stage_depends_on[$idx]="${current},${dep_id}"
}

# wizard_sequential_prior_stage_csv <idx>
# Comma-separated stage ids before idx (ordered stages).
wizard_sequential_prior_stage_csv() {
  local idx="$1"
  local i csv=""
  for ((i = 0; i < idx; i++)); do
    if [[ -n "$csv" ]]; then
      csv+=",${cp_stages[$i]}"
    else
      csv="${cp_stages[$i]}"
    fi
  done
  printf '%s' "$csv"
}

# wizard_sequential_prior_planner_csv <idx>
# Earlier stages that already have planner maxTodos set (or can become planners).
# For generated-plan selection, any earlier ordinary (non-approval) stage is eligible.
wizard_sequential_prior_agent_csv() {
  local idx="$1"
  local i csv=""
  for ((i = 0; i < idx; i++)); do
    if [[ "${cp_stage_types[$i]:-agent}" == "approval" || "${cp_stage_work_source[$i]:-}" == "approval" ]]; then
      continue
    fi
    if [[ -n "$csv" ]]; then
      csv+=",${cp_stages[$i]}"
    else
      csv="${cp_stages[$i]}"
    fi
  done
  printf '%s' "$csv"
}

# wizard_sequential_configure_stages
# Interactive per-stage authoring for Sequential mode.
wizard_sequential_configure_stages() {
  local idx stage_id kind work_source runtime model pair
  local producer max_todos question changes_target prior_csv agent_csv
  local plan_file instructions inline_content inline_verification
  local requires_input produces_input

  for idx in "${!cp_stages[@]}"; do
    stage_id="${cp_stages[$idx]}"
    print_info "Configuring ordered stage \"$stage_id\""

    kind="$(wizard_sequential_select_stage_kind "$stage_id")"
    if [[ "$kind" == "approval" ]]; then
      cp_stage_types[$idx]="approval"
      cp_stage_work_source[$idx]="approval"
      wizard_sequential_print_approval_decisions
      question="$(ralph_prompt_text "Exact approval question for \"$stage_id\"" "")"
      [[ -n "$question" ]] || ralph_die "approval \"$stage_id\" requires a non-empty question"
      prior_csv="$(wizard_sequential_prior_agent_csv "$idx")"
      changes_target="$(wizard_sequential_select_changes_target "$stage_id" "$prior_csv")"
      cp_stage_question[$idx]="$question"
      cp_stage_changes_target[$idx]="$changes_target"
      wizard_sequential_ensure_depends_on "$idx" "$changes_target"
      requires_input="$(ralph_prompt_text "Required artifact path to review for \"$stage_id\" (optional)" \
        ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/$(artifact_file_for_stage "$changes_target")")"
      if [[ -n "$requires_input" ]]; then
        wizard_create_plan_append_artifact "$stage_id" "$requires_input" "true" "requires"
      fi
      cp_stage_runtimes[$idx]=""
      cp_stage_models[$idx]=""
      cp_stage_plan_files[$idx]=""
      cp_stage_plan_from[$idx]=""
      cp_stage_planner_max[$idx]=""
      cp_stage_instructions[$idx]=""
      cp_stage_inline_content[$idx]=""
      cp_stage_inline_verification[$idx]=""
      continue
    fi

    cp_stage_types[$idx]="agent"
    work_source="$(wizard_sequential_select_work_source "$stage_id")"
    cp_stage_work_source[$idx]="$work_source"
    cp_stage_question[$idx]=""
    cp_stage_changes_target[$idx]=""

    case "$work_source" in
      "$wizard_sequential_work_source_inline")
        pair="$(wizard_sequential_optional_runtime_model "$stage_id")"
        runtime="${pair%%$'\t'*}"
        model="${pair#*$'\t'}"
        cp_stage_runtimes[$idx]="$runtime"
        cp_stage_models[$idx]="$model"
        instructions="$(ralph_prompt_text "Inline instructions for \"$stage_id\" (optional)" "")"
        cp_stage_instructions[$idx]="$instructions"
        inline_content="$(ralph_prompt_text "Bounded inline action for \"$stage_id\" ({{TASK}} is added if missing)" "")"
        inline_verification="$(ralph_prompt_text "Verification for \"$stage_id\" inline action (optional)" "")"
        cp_stage_inline_content[$idx]="$inline_content"
        cp_stage_inline_verification[$idx]="$inline_verification"
        cp_stage_plan_files[$idx]=""
        cp_stage_plan_from[$idx]=""
        # Keep planner_max if a later consumer already marked this producer.
        ;;
      "$wizard_sequential_work_source_static")
        pair="$(wizard_sequential_optional_runtime_model "$stage_id")"
        runtime="${pair%%$'\t'*}"
        model="${pair#*$'\t'}"
        cp_stage_runtimes[$idx]="$runtime"
        cp_stage_models[$idx]="$model"
        plan_file="$(ralph_prompt_text "Existing static plan file for \"$stage_id\"" \
          ".ralph-workspace/plans/${plan_name:-workflow}-${stage_id}.plan.md")"
        [[ -n "$plan_file" ]] || ralph_die "static plan file path required for \"$stage_id\""
        cp_stage_plan_files[$idx]="$plan_file"
        cp_stage_plan_from[$idx]=""
        cp_stage_instructions[$idx]=""
        cp_stage_inline_content[$idx]=""
        cp_stage_inline_verification[$idx]=""
        ;;
      "$wizard_sequential_work_source_generated")
        wizard_sequential_explain_generated_plan
        agent_csv="$(wizard_sequential_prior_agent_csv "$idx")"
        producer="$(wizard_sequential_select_producer_stage "$stage_id" "$agent_csv")"
        max_todos="$(wizard_sequential_prompt_max_todos 100)"
        local producer_idx
        producer_idx="$(wizard_create_plan_stage_index "$producer")" || \
          ralph_die "unknown producer stage \"$producer\""
        cp_stage_planner_max[$producer_idx]="$max_todos"
        # Producer must remain an ordinary agent with planner schema (not approval).
        if [[ "${cp_stage_types[$producer_idx]:-agent}" == "approval" ]]; then
          ralph_die "planner producer \"$producer\" cannot be an approval stage"
        fi
        # If producer was a static plan, clear planFile — planner owns the work source.
        if [[ -n "${cp_stage_plan_files[$producer_idx]:-}" ]]; then
          cp_stage_plan_files[$producer_idx]=""
        fi
        if [[ -z "${cp_stage_inline_content[$producer_idx]:-}" ]]; then
          cp_stage_inline_content[$producer_idx]="Plan the fewest independently verifiable TODOs that fully cover:
{{TASK}}"
        fi
        cp_stage_plan_from[$idx]="$producer"
        cp_stage_plan_files[$idx]=""
        wizard_sequential_ensure_depends_on "$idx" "$producer"
        pair="$(wizard_sequential_optional_runtime_model "$stage_id")"
        runtime="${pair%%$'\t'*}"
        model="${pair#*$'\t'}"
        cp_stage_runtimes[$idx]="$runtime"
        cp_stage_models[$idx]="$model"
        instructions="$(ralph_prompt_text "Inline instructions for \"$stage_id\" consumer (optional)" "")"
        cp_stage_instructions[$idx]="$instructions"
        cp_stage_inline_content[$idx]=""
        cp_stage_inline_verification[$idx]=""
        cp_stage_planner_max[$idx]=""
        ;;
      *)
        ralph_die "unknown work source for \"$stage_id\": $work_source"
        ;;
    esac

    # Default predecessor edge for ordered Sequential stages (skipped when already set).
    if (( idx > 0 )) && [[ -z "${cp_stage_depends_on[$idx]:-}" ]]; then
      wizard_sequential_ensure_depends_on "$idx" "${cp_stages[$((idx - 1))]}"
    fi

    produces_input="$(ralph_prompt_text "Output artifact path for \"$stage_id\" (optional)" "")"
    if [[ -n "$produces_input" ]]; then
      wizard_create_plan_append_artifact "$stage_id" "$produces_input" "true" "produces"
    fi
    requires_input="$(ralph_prompt_text "Required input artifact for \"$stage_id\" (optional)" "")"
    if [[ -n "$requires_input" ]]; then
      wizard_create_plan_append_artifact "$stage_id" "$requires_input" "true" "requires"
    fi
  done
}

# wizard_sequential_run_interactive
# Full Sequential workflow authoring entry used by pipeline-wizard.
wizard_sequential_run_interactive() {
  local plan_name plan_overview instructions_line dest plans_dir confirm_write
  local workspace="${workspace:-$(pwd)}"
  local total_steps=6
  local scope_triplet scope

  wizard_workflow_require_interactive_stdin

  wizard_output_format="workflow"
  wizard_sequential_reset_arrays

  print_step "1/$total_steps" "Sequential workflow metadata"
  print_hint "- Authored files use kind: workflow and mode: sequential."
  print_hint "- Ordered stages run in list order; optional parallel waves are declared explicitly."
  print_hint "- Pass the concrete request at start via {{TASK}}; keep reusable policy in the workflow."
  print_hint "- --mode only preselects scheduling; remaining authoring stays interactive."

  if [[ "${wizard_workflow_metadata_done:-}" == "1" ]]; then
    plan_name="$workflow_name"
    plan_overview="${pipeline_description:-Reusable Sequential workflow for $plan_name}"
  else
    local name desc
    name="$(ralph_prompt_text "Workflow name (lowercase letters, digits, hyphens)")"
    [[ -n "$name" ]] || ralph_die "Workflow name is required"
    if ! wizard_workflow_name_valid "$name"; then
      ralph_die "invalid workflow name: $name (use lowercase letters, digits, and hyphens only)"
    fi
    workflow_name="$name"
    pipeline_name="$name"
    namespace="$name"
    desc="$(ralph_prompt_text "Description" "Reusable Sequential workflow for $name")"
    pipeline_description="$desc"
    plan_name="$workflow_name"
    plan_overview="$pipeline_description"
  fi

  scope_triplet="$(wizard_workflow_resolve_create_dest "$plan_name" "$workspace")"
  IFS=$'\t' read -r scope plans_dir dest <<< "$scope_triplet"
  cp_workflow_scope="$scope"
  cp_workflow_dest="$dest"
  if [[ -e "$dest" ]]; then
    ralph_die "workflow already exists: $dest"
  fi

  wizard_workflow_prompt_defaults

  instructions_line="instructions: Execute one TODO at a time. Keep reusable Sequential policy here; pass the concrete request via {{TASK}} at start."

  print_step "2/$total_steps" "Ordered stages"
  print_hint "- List stages in execution order (letters, digits, hyphens)."
  print_hint "- Include approval stage ids when you need approve | request-changes | cancel gates."
  read_stages

  selected_stage_ids=()
  local _s _sid
  for _s in ${selected_stages[@]+"${selected_stages[@]}"}; do
    _sid="$(ralph_internal_wizard_sanitize "$_s")"
    [[ -n "$_sid" ]] || ralph_die "Stage \"$_s\" sanitizes to empty"
    selected_stage_ids+=("$_sid")
  done
  ((${#selected_stage_ids[@]} > 0)) || ralph_die "No stages configured"

  local stage_id
  for stage_id in "${selected_stage_ids[@]}"; do
    cp_stages+=("$stage_id")
    cp_stage_types+=("agent")
    cp_stage_runtimes+=("")
    cp_stage_roles+=("")
    cp_stage_models+=("")
    cp_stage_native_subagents+=("")
    cp_stage_session+=("")
    cp_stage_context+=("")
    cp_stage_plan_files+=("")
    cp_stage_inline_content+=("")
    cp_stage_inline_verification+=("")
    cp_stage_depends_on+=("")
    cp_stage_work_source+=("")
    cp_stage_plan_from+=("")
    cp_stage_planner_max+=("")
    cp_stage_question+=("")
    cp_stage_changes_target+=("")
    cp_stage_instructions+=("")
  done

  print_step "3/$total_steps" "Configure each ordered stage"
  print_hint "- Ordinary agent stages choose exactly one work source: bounded inline action, existing static plan file, or generated Ralph plan."
  wizard_sequential_configure_stages

  print_step "4/$total_steps" "Parallel waves (optional)"
  stage_ids=("${cp_stages[@]}")
  configure_sequential_parallel_waves
  cp_parallel_waves=(${parallel_stage_waves[@]+"${parallel_stage_waves[@]}"})

  print_step "5/$total_steps" "planInput (optional)"
  wizard_workflow_prompt_plan_input "$plan_name"

  print_step "6/$total_steps" "Review and write"
  wizard_workflow_print_final_review "$scope" "$dest" "sequential"
  wizard_workflow_confirm_mutating_without_plan

  confirm_write="$(ralph_prompt_yesno "Write this Sequential workflow" "y")"
  if [[ "$confirm_write" == "n" ]]; then
    echo "aborted; no files created"
    return 0
  fi

  wizard_workflow_atomic_validate_and_rename "$dest" \
    wizard_render_sequential_workflow "$plan_name" "$plan_overview" "$instructions_line"

  echo "Created workflow (${scope}): ${dest}"
  echo ""
  echo "Start with:"
  if [[ "${cp_plan_input_required:-}" == "true" ]]; then
    echo "  ralph workflow start ${plan_name} --plan \"<leaf-plan-path>\""
  else
    echo "  ralph workflow start ${plan_name} --task \"<work request>\""
  fi
}

# --- Dependency workflow authoring -------------------------------------------

# wizard_dependency_explain_planfrom_rework
# Explain that each repair round receives a fresh control copy of the immutable source.
wizard_dependency_explain_planfrom_rework() {
  print_hint "- Bounded rework is allowed only when the loopBackTo target is a planFrom consumer."
  print_hint "- Each repair round gets a fresh control copy of the same immutable generated plan source."
  print_hint "- Static planFile targets are rejected; approval nodes cannot be rework targets."
}

# wizard_dependency_validate_rework_target <target_id>
# Return 0 when target is a planFrom consumer; die with a clear reason otherwise.
wizard_dependency_validate_rework_target() {
  local target_id="$1"
  local idx
  idx="$(wizard_create_plan_stage_index "$target_id")" || \
    ralph_die "rework target \"$target_id\" is not a declared stage"
  if [[ "${cp_stage_types[$idx]:-agent}" == "approval" || "${cp_stage_work_source[$idx]:-}" == "approval" ]]; then
    ralph_die "approval \"$target_id\" cannot be a rework target"
  fi
  if [[ -n "${cp_stage_plan_files[$idx]:-}" && -z "${cp_stage_plan_from[$idx]:-}" ]]; then
    ralph_die "static planFile rework rejected for \"$target_id\"; use a planFrom consumer instead"
  fi
  if [[ -z "${cp_stage_plan_from[$idx]:-}" ]]; then
    ralph_die "rework target \"$target_id\" must be a planFrom consumer (generated Ralph plan)"
  fi
  return 0
}

# wizard_dependency_configure_rework
# Optional bounded rework: review source -> planFrom target only.
wizard_dependency_configure_rework() {
  local add_rework source_id target_id max_iter check_path
  local -a eligible_sources=() eligible_targets=()
  local idx stage_id

  print_info "Bounded rework (optional)"
  wizard_dependency_explain_planfrom_rework

  for idx in "${!cp_stages[@]}"; do
    stage_id="${cp_stages[$idx]}"
    if [[ "${cp_stage_types[$idx]:-agent}" == "approval" ]]; then
      continue
    fi
    if [[ -n "${cp_stage_plan_from[$idx]:-}" ]]; then
      eligible_targets+=("$stage_id")
    fi
    if [[ "${cp_stage_types[$idx]:-agent}" == "agent" ]]; then
      eligible_sources+=("$stage_id")
    fi
  done

  if ((${#eligible_targets[@]} == 0)); then
    print_hint "No planFrom consumers declared; skipping rework authoring."
    return 0
  fi

  add_rework="$(ralph_prompt_yesno "Add bounded rework for a planFrom target" "n")"
  [[ "$add_rework" == "y" ]] || return 0

  source_id="$(ralph_menu_select --prompt "Review stage that may send work back" --default 1 -- "${eligible_sources[@]}")"
  target_id="$(ralph_menu_select --prompt "planFrom rework target (fresh control copy each round)" --default 1 -- "${eligible_targets[@]}")"
  wizard_dependency_validate_rework_target "$target_id"
  max_iter="$(ralph_prompt_text "Max rework iterations for \"$source_id\"" "2")"
  if ! [[ "$max_iter" =~ ^[0-9]+$ ]] || (( max_iter < 1 || max_iter > 5 )); then
    print_hint "Invalid maxIterations; using 2."
    max_iter=2
  fi
  check_path=".ralph-workspace/artifacts/{{ARTIFACT_NS}}/{{STAGE_ID}}-verdict.json"
  wizard_create_plan_set_loop "$source_id" "$target_id" "$max_iter" "$check_path"
  wizard_create_plan_append_artifact "$source_id" "$check_path" "true" "produces"
  print_hint "Each repair round for \"$target_id\" receives a fresh control copy of the immutable plan source."
}

# wizard_render_dependency_workflow <plan_name> <plan_overview> [instructions_line]
#   [max_parallel] [edge_derivation] [failure_policy]
# Emit kind: workflow / mode: dependency only (never engine:).
wizard_render_dependency_workflow() {
  local plan_name="$1"
  local plan_overview="$2"
  local instructions_line="${3-}"
  local max_parallel="${4:-3}"
  local edge_derivation="${5:-both}"
  local failure_policy="${6:-drain}"
  local idx stage_id stage_type runtime model plan_file plan_from planner_max
  local question changes_target instructions depends_on work_source
  local policy quorum workspace_mode profile write_scopes
  local router_allowed router_default router_terminal router_on_invalid
  local loop_target loop_max loop_check
  local -a yaml_lines=()
  local requires_yaml produces_yaml line todo_id todo_content todo_verification
  local planner_schema="bundle/.ralph/schemas/planner-output.schema.json"
  local verdict_schema="bundle/.ralph/schemas/evaluator-verdict.schema.json"
  local dep_id scope_token vpidx

  if [[ -z "$instructions_line" ]]; then
    instructions_line='instructions: Execute one TODO at a time. Keep reusable Dependency policy here; pass the concrete request via {{TASK}} at start.'
  fi

  yaml_lines+=("---")
  yaml_lines+=("name: ${plan_name}")
  yaml_lines+=("overview: ${plan_overview}")
  yaml_lines+=("kind: workflow")
  yaml_lines+=("mode: dependency")
  local header_extra
  header_extra="$(wizard_workflow_emit_defaults_plan_input_yaml)"
  if [[ -n "$header_extra" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -n "$line" ]] && yaml_lines+=("$line")
    done <<< "$header_extra"
  fi
  yaml_lines+=("${instructions_line}")
  yaml_lines+=("pipeline:")
  [[ -n "$max_parallel" ]] && yaml_lines+=("  maxParallel: ${max_parallel}")
  [[ -n "$edge_derivation" ]] && yaml_lines+=("  edgeDerivation: ${edge_derivation}")
  [[ -n "$failure_policy" ]] && yaml_lines+=("  failurePolicy: ${failure_policy}")

  if ((${#cp_vp_name[@]} > 0)); then
    yaml_lines+=("  verificationProfiles:")
    for vpidx in "${!cp_vp_name[@]}"; do
      yaml_lines+=("    - name: ${cp_vp_name[$vpidx]}")
      yaml_lines+=("      steps:")
      yaml_lines+=("        - name: ${cp_vp_step_name[$vpidx]}")
      yaml_lines+=("          command: ${cp_vp_step_command[$vpidx]}")
    done
  fi

  if [[ -n "${cp_tooling_default_profile:-}" ]]; then
    yaml_lines+=("  tooling:")
    yaml_lines+=("    defaultProfile: ${cp_tooling_default_profile}")
    if ((${#cp_tooling_overrides[@]} > 0)); then
      yaml_lines+=("    overrides:")
      local tooling_override
      for tooling_override in "${cp_tooling_overrides[@]}"; do
        [[ -n "$tooling_override" ]] || continue
        yaml_lines+=("      ${tooling_override%%=*}: ${tooling_override#*=}")
      done
    fi
  fi

  yaml_lines+=("  stages:")

  for idx in "${!cp_stages[@]}"; do
    stage_id="${cp_stages[$idx]}"
    stage_type="${cp_stage_types[$idx]:-agent}"
    runtime="${cp_stage_runtimes[$idx]:-}"
    model="${cp_stage_models[$idx]:-}"
    plan_file="${cp_stage_plan_files[$idx]:-}"
    plan_from="${cp_stage_plan_from[$idx]:-}"
    planner_max="${cp_stage_planner_max[$idx]:-}"
    question="${cp_stage_question[$idx]:-}"
    changes_target="${cp_stage_changes_target[$idx]:-}"
    instructions="${cp_stage_instructions[$idx]:-}"
    depends_on="${cp_stage_depends_on[$idx]:-}"
    work_source="${cp_stage_work_source[$idx]:-}"
    policy="${cp_stage_policy[$idx]:-}"
    quorum="${cp_stage_quorum[$idx]:-}"
    workspace_mode="${cp_stage_workspace_mode[$idx]:-}"
    profile="${cp_stage_profile[$idx]:-}"
    write_scopes="${cp_stage_write_scopes[$idx]:-}"
    router_allowed="${cp_stage_router_allowed[$idx]:-}"
    router_default="${cp_stage_router_default[$idx]:-}"
    router_terminal="${cp_stage_router_terminal[$idx]:-}"
    router_on_invalid="${cp_stage_router_on_invalid[$idx]:-}"

    yaml_lines+=("    - id: ${stage_id}")

    if [[ "$stage_type" == "approval" || "$work_source" == "approval" ]]; then
      yaml_lines+=("      type: approval")
      yaml_lines+=("      question: ${question}")
      yaml_lines+=("      changesTarget: ${changes_target}")
      if [[ -n "$depends_on" ]]; then
        yaml_lines+=("      dependsOn:")
        local -a dep_ids=()
        IFS=',' read -r -a dep_ids <<< "$depends_on"
        for dep_id in "${dep_ids[@]}"; do
          dep_id="$(printf '%s' "$dep_id" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
          [[ -n "$dep_id" ]] || continue
          yaml_lines+=("        - ${dep_id}")
        done
      fi
      requires_yaml="$(wizard_render_artifact_list_yaml "$stage_id" "requires" "        ")"
      if [[ -n "$requires_yaml" ]]; then
        yaml_lines+=("      requires:")
        while IFS= read -r line; do [[ -n "$line" ]] && yaml_lines+=("$line"); done <<< "$requires_yaml"
      fi
      continue
    fi

    if [[ "$stage_type" != "agent" ]]; then
      yaml_lines+=("      type: ${stage_type}")
    fi

    if [[ -n "$planner_max" ]]; then
      yaml_lines+=("      planner:")
      yaml_lines+=("        outputMode: plan-file")
      yaml_lines+=("        maxTodos: ${planner_max}")
    fi

    if [[ -n "$plan_from" ]]; then
      yaml_lines+=("      planFrom: ${plan_from}")
    elif [[ -n "$plan_file" ]]; then
      yaml_lines+=("      planFile: ${plan_file}")
    fi

    if [[ "$stage_type" == "agent" ]]; then
      [[ -n "$runtime" ]] && yaml_lines+=("      runtime: ${runtime}")
      [[ -n "$model" ]] && yaml_lines+=("      model: ${model}")
    elif [[ "$stage_type" == "router" && -n "$runtime" ]]; then
      yaml_lines+=("      runtime: ${runtime}")
    fi

    if [[ -n "$instructions" ]]; then
      yaml_lines+=("      instructions: |")
      while IFS= read -r line || [[ -n "$line" ]]; do
        yaml_lines+=("        ${line}")
      done <<< "$instructions"
    fi

    if [[ "$stage_type" == "consensus" || "$stage_type" == "join" ]]; then
      [[ -n "$policy" ]] && yaml_lines+=("      policy: ${policy}")
      [[ -n "$quorum" ]] && yaml_lines+=("      quorum: ${quorum}")
    fi
    if [[ "$stage_type" == "gate" && -n "$profile" ]]; then
      yaml_lines+=("      profile: ${profile}")
    fi

    if [[ -n "$depends_on" ]]; then
      yaml_lines+=("      dependsOn:")
      local -a dep_ids=()
      IFS=',' read -r -a dep_ids <<< "$depends_on"
      for dep_id in "${dep_ids[@]}"; do
        dep_id="$(printf '%s' "$dep_id" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [[ -n "$dep_id" ]] || continue
        yaml_lines+=("        - ${dep_id}")
      done
    fi

    requires_yaml="$(wizard_render_artifact_list_yaml "$stage_id" "requires" "        ")"
    produces_yaml="$(wizard_render_artifact_list_yaml "$stage_id" "produces" "        ")"
    if [[ -n "$requires_yaml" ]]; then
      yaml_lines+=("      requires:")
      while IFS= read -r line; do [[ -n "$line" ]] && yaml_lines+=("$line"); done <<< "$requires_yaml"
    fi

    loop_target="$(wizard_create_plan_loop_target "$stage_id")"
    loop_check=""
    if [[ -n "$loop_target" ]]; then
      loop_check="$(wizard_create_plan_loop_check "$stage_id")"
    fi

    local emitted_planner_json=0
    if [[ -n "$produces_yaml" ]]; then
      yaml_lines+=("      produces:")
      while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        yaml_lines+=("$line")
        if [[ -n "$planner_max" && "$line" == *"path: "*".json" ]]; then
          yaml_lines+=("          schema: ${planner_schema}")
          emitted_planner_json=1
        fi
        if [[ -n "$loop_check" && "$line" == *"path: ${loop_check}" ]]; then
          yaml_lines+=("          schema: ${verdict_schema}")
        fi
      done <<< "$produces_yaml"
    fi
    if [[ -n "$planner_max" && "$emitted_planner_json" -eq 0 ]]; then
      if [[ -z "$produces_yaml" ]]; then
        yaml_lines+=("      produces:")
      fi
      yaml_lines+=("        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/${stage_id}-plan.json")
      yaml_lines+=("          schema: ${planner_schema}")
      yaml_lines+=("          required: true")
    fi

    if [[ "$stage_type" == "consensus" ]]; then
      yaml_lines+=("      voters:")
      local vidx voter_id voter_runtime
      for vidx in "${!cp_voter_node[@]}"; do
        [[ "${cp_voter_node[$vidx]}" == "$stage_id" ]] || continue
        voter_id="${cp_voter_id[$vidx]}"
        voter_runtime="${cp_voter_runtime[$vidx]}"
        yaml_lines+=("        - id: ${voter_id}")
        yaml_lines+=("          runtime: ${voter_runtime}")
      done
    fi

    if [[ (("$stage_type" == "agent" && -n "$workspace_mode") || "$stage_type" == "integrate") && -n "$workspace_mode" ]]; then
      yaml_lines+=("      workspaceMode: ${workspace_mode}")
      if [[ "$workspace_mode" == "shared" ]]; then
        yaml_lines+=("      acknowledgeSharedMutationRisk: true")
        yaml_lines+=("      parallelMutation: allow")
      fi
    fi

    if [[ "$stage_type" == "agent" && -n "$write_scopes" ]]; then
      yaml_lines+=("      writeScopes:")
      local -a scope_tokens=()
      IFS=',' read -r -a scope_tokens <<< "$write_scopes"
      for scope_token in "${scope_tokens[@]}"; do
        scope_token="$(printf '%s' "$scope_token" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [[ -n "$scope_token" ]] || continue
        if [[ "$scope_token" == *"*"* || "$scope_token" == *" "* ]]; then
          yaml_lines+=("        - \"${scope_token}\"")
        else
          yaml_lines+=("        - ${scope_token}")
        fi
      done
    fi

    if [[ "$stage_type" == "router" && -n "$router_allowed" ]]; then
      yaml_lines+=("      router:")
      yaml_lines+=("        allowedTargets:")
      local -a target_tokens=()
      IFS=',' read -r -a target_tokens <<< "$router_allowed"
      for dep_id in "${target_tokens[@]}"; do
        dep_id="$(printf '%s' "$dep_id" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [[ -n "$dep_id" ]] || continue
        yaml_lines+=("          - ${dep_id}")
      done
      [[ -n "$router_default" ]] && yaml_lines+=("        defaultTarget: ${router_default}")
      if [[ -n "$router_terminal" ]]; then
        yaml_lines+=("        terminalOutcomes:")
        IFS=',' read -r -a target_tokens <<< "$router_terminal"
        for dep_id in "${target_tokens[@]}"; do
          dep_id="$(printf '%s' "$dep_id" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
          [[ -n "$dep_id" ]] || continue
          yaml_lines+=("          - ${dep_id}")
        done
      fi
      [[ -n "$router_on_invalid" ]] && yaml_lines+=("        onInvalid: ${router_on_invalid}")
    fi

    if [[ -n "$loop_target" ]]; then
      loop_max="$(wizard_create_plan_loop_max "$stage_id")"
      [[ -n "$loop_check" ]] || loop_check="$(wizard_create_plan_loop_check "$stage_id")"
      yaml_lines+=("      loopBackTo: ${loop_target}")
      yaml_lines+=("      maxIterations: ${loop_max}")
      yaml_lines+=("      loopCheck:")
      yaml_lines+=("        path: ${loop_check}")
      yaml_lines+=("        schema: ${verdict_schema}")
      yaml_lines+=("      onExhausted: fail")
    fi
  done

  yaml_lines+=("")
  yaml_lines+=("todos:")

  local wrote_todo=0
  for idx in "${!cp_stages[@]}"; do
    stage_id="${cp_stages[$idx]}"
    stage_type="${cp_stage_types[$idx]:-agent}"
    plan_file="${cp_stage_plan_files[$idx]:-}"
    plan_from="${cp_stage_plan_from[$idx]:-}"
    work_source="${cp_stage_work_source[$idx]:-}"
    policy="${cp_stage_policy[$idx]:-}"

    if [[ "$stage_type" == "approval" || "$work_source" == "approval" ]]; then
      continue
    fi
    if [[ -n "$plan_from" || -n "$plan_file" ]]; then
      continue
    fi
    if [[ -n "${cp_plan_input_stage:-}" && "$stage_id" == "$cp_plan_input_stage" ]]; then
      continue
    fi

    wrote_todo=1
    todo_id="${stage_id}-1"
    yaml_lines+=("  - id: ${todo_id}")
    yaml_lines+=("    stage: ${stage_id}")

    if [[ "$stage_type" == "consensus" ]]; then
      yaml_lines+=("    content: |")
      yaml_lines+=("      Review the upstream result and record a verdict for the ${policy:-veto} policy.")
      yaml_lines+=("    verification: |")
      yaml_lines+=("      Confirm a verdict artifact exists for this voter.")
    elif [[ "$stage_type" == "join" ]]; then
      yaml_lines+=("    content: |")
      yaml_lines+=("      Apply the ${policy:-veto} policy to the upstream verdicts.")
      yaml_lines+=("    verification: |")
      yaml_lines+=("      Confirm a consensus-result artifact was written under the consensus directory.")
    elif [[ "$stage_type" == "checkpoint" ]]; then
      yaml_lines+=("    content: |")
      yaml_lines+=("      Wait for a human to acknowledge \"${stage_id}\" before closing out.")
      yaml_lines+=("    verification: |")
      yaml_lines+=("      Confirm the acknowledgement artifact exists.")
    elif [[ "$stage_type" == "gate" ]]; then
      yaml_lines+=("    content: |")
      yaml_lines+=("      Run the declared verification profile for this gate.")
      yaml_lines+=("    verification: |")
      yaml_lines+=("      Confirm the gate outcome records passed or changes-required.")
    elif [[ "$stage_type" == "integrate" ]]; then
      yaml_lines+=("    content: |")
      yaml_lines+=("      Merge upstream isolated changesets in declared dependency order.")
      yaml_lines+=("    verification: |")
      yaml_lines+=("      Confirm integration produced a changeset manifest without conflicts.")
    elif [[ "$stage_type" == "router" ]]; then
      yaml_lines+=("    content: |")
      yaml_lines+=("      Choose the next branch target from the allowed router targets.")
      yaml_lines+=("    verification: |")
      yaml_lines+=("      Confirm a router-decision artifact names one allowed target.")
    else
      if [[ -n "${cp_stage_inline_content[$idx]:-}" ]]; then
        todo_content="${cp_stage_inline_content[$idx]}"
      else
        todo_content="$(wizard_render_todo_artifact_content "$stage_id")"
      fi
      if [[ -n "${cp_stage_inline_verification[$idx]:-}" ]]; then
        todo_verification="${cp_stage_inline_verification[$idx]}"
      else
        todo_verification="$(wizard_render_todo_verification "$stage_id")"
      fi
      todo_content="$(wizard_workflow_todo_content_with_task "$todo_content" "$stage_type" "")"
      yaml_lines+=("    content: |")
      while IFS= read -r line || [[ -n "${line:-}" ]]; do
        yaml_lines+=("      ${line}")
      done <<< "$todo_content"
      yaml_lines+=("    verification: |")
      while IFS= read -r line || [[ -n "${line:-}" ]]; do
        yaml_lines+=("      ${line}")
      done <<< "$todo_verification"
    fi
    yaml_lines+=("    status: pending")
  done

  if (( wrote_todo == 0 )); then
    yaml_lines+=("  - id: workflow-policy-1")
    yaml_lines+=("    content: |")
    yaml_lines+=("      Reusable Dependency workflow policy for:")
    yaml_lines+=("      {{TASK}}")
    yaml_lines+=("    verification: |")
    yaml_lines+=("      Confirm workflow authoring is complete.")
    yaml_lines+=("    status: pending")
  fi

  yaml_lines+=("---")

  local out
  out="$(printf '%s\n' "${yaml_lines[@]}")"
  if wizard_dependency_text_has_forbidden_vocab "$out"; then
    ralph_die "dependency workflow render leaked internal vocabulary"
  fi
  printf '%s\n' "$out"
}

# wizard_dependency_run_interactive
# Public Dependency workflow authoring: reuses DAG/supervisor prompts, emits mode: dependency.
wizard_dependency_run_interactive() {
  local plan_name plan_overview instructions_line dest plans_dir confirm_write
  local max_parallel edge_derivation failure_policy selected_stage_ids _s _sid
  local workspace="${workspace:-$(pwd)}"
  local scope_triplet scope

  wizard_workflow_require_interactive_stdin

  wizard_public_mode="dependency"
  wizard_output_format="workflow"
  wizard_workflow_engine=""
  wizard_sequential_reset_arrays
  cp_loop_sources=()
  cp_loop_targets=()
  cp_loop_max_iters=()
  cp_loop_check_paths=()

  print_step "1/6" "Dependency workflow metadata"
  print_hint "- Authored files use kind: workflow and mode: dependency."
  print_hint "- Prerequisites, supervisors, branching, gates, isolation, and rework are dependency-driven."
  print_hint "- Pass the concrete request at start via {{TASK}}; keep reusable policy in the workflow."
  print_hint "- --mode only preselects scheduling; remaining authoring stays interactive."

  if [[ "${wizard_workflow_metadata_done:-}" == "1" ]]; then
    plan_name="$workflow_name"
    plan_overview="${pipeline_description:-Reusable Dependency workflow for $plan_name}"
  else
    local name desc
    name="$(ralph_prompt_text "Workflow name (lowercase letters, digits, hyphens)")"
    [[ -n "$name" ]] || ralph_die "Workflow name is required"
    if ! wizard_workflow_name_valid "$name"; then
      ralph_die "invalid workflow name: $name (use lowercase letters, digits, and hyphens only)"
    fi
    workflow_name="$name"
    pipeline_name="$name"
    namespace="$name"
    desc="$(ralph_prompt_text "Description" "Reusable Dependency workflow for $name")"
    pipeline_description="$desc"
    plan_name="$workflow_name"
    plan_overview="$pipeline_description"
  fi

  scope_triplet="$(wizard_workflow_resolve_create_dest "$plan_name" "$workspace")"
  IFS=$'\t' read -r scope plans_dir dest <<< "$scope_triplet"
  cp_workflow_scope="$scope"
  cp_workflow_dest="$dest"
  if [[ -e "$dest" ]]; then
    ralph_die "workflow already exists: $dest"
  fi

  wizard_workflow_prompt_defaults

  instructions_line="instructions: Execute one TODO at a time. Keep reusable Dependency policy here; pass the concrete request via {{TASK}} at start."

  print_info "Run-wide settings"
  wizard_graph_authoring_print_topic_help "maxParallel"
  max_parallel="$(ralph_prompt_text "Max parallel nodes" "3")"
  edge_derivation="$(wizard_graph_menu edgeDerivation "How should Ralph work out the run order" 3 "declared" "artifacts" "both")"
  failure_policy="$(wizard_graph_menu failurePolicy "If a node fails" 1 "drain" "cancel")"

  print_step "2/6" "Node list"
  wizard_graph_explain "Name every node now; dependencies decide run order. Include approval ids for approve | request-changes | cancel gates."
  read_graph_nodes

  selected_stage_ids=()
  for _s in "${selected_stages[@]}"; do
    _sid="$(ralph_internal_wizard_sanitize "$_s")"
    [[ -n "$_sid" ]] || ralph_die "Node \"$_s\" sanitizes to empty"
    selected_stage_ids+=("$_sid")
  done
  ((${#selected_stage_ids[@]} > 0)) || ralph_die "No nodes configured"

  print_info "Tooling profiles"
  wizard_graph_authoring_print_topic_help "tooling"
  cp_tooling_default_profile=""
  cp_tooling_overrides=()
  wizard_prompt_tooling_policy "${selected_stage_ids[@]}"
  cp_tooling_default_profile="${wizard_tooling_default_profile:-}"
  cp_tooling_overrides=(${wizard_tooling_overrides[@]+"${wizard_tooling_overrides[@]}"})

  wizard_graph_authoring_reset_graph_arrays
  cp_loop_sources=()
  cp_loop_targets=()
  cp_loop_max_iters=()
  cp_loop_check_paths=()
  wizard_graph_authoring_collect_node_types "${selected_stage_ids[@]}"
  wizard_graph_authoring_configure_nodes graph "$plan_name"

  print_step "3/6" "Bounded rework"
  wizard_dependency_configure_rework

  print_step "4/6" "planInput (optional)"
  wizard_workflow_prompt_plan_input "$plan_name"

  print_step "5/6" "Review and write"
  wizard_workflow_print_final_review "$scope" "$dest" "dependency"
  wizard_graph_render_review "$dest" "$max_parallel" "$edge_derivation" "$failure_policy"
  wizard_workflow_confirm_mutating_without_plan

  confirm_write="$(ralph_prompt_yesno "Write this Dependency workflow" "y")"
  if [[ "$confirm_write" == "n" ]]; then
    echo "aborted; no files created"
    return 0
  fi

  wizard_workflow_atomic_validate_and_rename "$dest" \
    wizard_render_dependency_workflow "$plan_name" "$plan_overview" "$instructions_line" \
    "$max_parallel" "$edge_derivation" "$failure_policy"

  echo "Created workflow (${scope}): ${dest}"
  echo ""
  echo "Start with:"
  if [[ "${cp_plan_input_required:-}" == "true" ]]; then
    echo "  ralph workflow start ${plan_name} --plan \"<leaf-plan-path>\""
  else
    echo "  ralph workflow start ${plan_name} --task \"<work request>\""
  fi
}
