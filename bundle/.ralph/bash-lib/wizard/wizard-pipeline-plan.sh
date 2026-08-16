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
#   wizard_render_graph_jury_preset -- non-interactive cross-provider review jury graph plan.
#   wizard_render_graph_parallel_implementation_preset -- frozen, isolated implementation lanes.
#   wizard_write_graph_parallel_plan_files -- unique internal plans for the architect and lanes.

# shellcheck source=bash-lib/error-handling.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../error-handling.sh"

wizard_create_plan_allowed_runtimes=(cursor claude codex opencode antigravity)
wizard_create_plan_allowed_session_strategies=(fresh resume reset compact)
wizard_create_plan_allowed_context_budgets=(full standard lean)

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
cp_artifact_entries=()
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
cp_voter_agent=()
cp_voter_model=()

wizard_create_plan_stage_id_valid() {
  [[ -n "$1" && "$1" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]
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
  for entry in "${cp_artifact_entries[@]}"; do
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
  local idx stage_id runtime agent model produces_count
  local loop_idx loop_source loop_target loop_max loop_check loop_flags
  local has_loop_back has_loop_max has_loop_check target_idx source_idx
  local has_loop_check_produce path req

  if ((${#cp_stages[@]} == 0)); then
    ralph_die "pipeline orchestration requires at least one --stage"
  fi

  for idx in "${!cp_stages[@]}"; do
    stage_id="${cp_stages[$idx]}"
    runtime="${cp_stage_runtimes[$idx]:-}"
    agent="${cp_stage_agents[$idx]:-}"
    model="${cp_stage_models[$idx]:-}"

    if [[ -z "$runtime" ]]; then
      ralph_die "stage $stage_id: missing --stage-runtime"
    fi
    if [[ -z "$agent" && -z "$model" ]]; then
      ralph_die "stage $stage_id: missing --stage-agent or --stage-model"
    fi

    produces_count=0
    while IFS='|' read -r path req; do
      [[ -n "$path" ]] && produces_count=$((produces_count + 1))
    done < <(wizard_create_plan_stage_artifacts "$stage_id" "produces")
    if (( produces_count == 0 )); then
      ralph_die "stage $stage_id: missing --stage-produces"
    fi
  done

  for loop_source in "${cp_loop_sources[@]}"; do
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
    for wave in "${cp_parallel_waves[@]}"; do
      IFS=',' read -r -a wave_stages <<< "$wave"
      for stage_in_wave in "${wave_stages[@]}"; do
        stage_in_wave="$(printf '%s' "$stage_in_wave" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [[ -n "$stage_in_wave" ]] || ralph_die "invalid --parallel-wave mapping (empty stage id)"
        wizard_create_plan_require_known_stage "$stage_in_wave" "--parallel-wave"
        seen_count=0
        for s in "${cp_parallel_waves[@]}"; do
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
  local idx stage_id stage_type runtime agent model session context plan_file
  local loop_target loop_max loop_check depends_on policy quorum workspace_mode
  local -a yaml_lines=()
  local requires_yaml produces_yaml todo_id todo_content todo_verification line

  yaml_lines+=("---")
  yaml_lines+=("name: ${plan_name}")
  yaml_lines+=("overview: ${plan_overview}")
  yaml_lines+=("execution: ${mode}")
  yaml_lines+=("${instructions_line}")
  yaml_lines+=("pipeline:")
  if [[ "$mode" == "graph" ]]; then
    [[ -n "$max_parallel" ]] && yaml_lines+=("  maxParallel: ${max_parallel}")
    [[ -n "$edge_derivation" ]] && yaml_lines+=("  edgeDerivation: ${edge_derivation}")
    [[ -n "$failure_policy" ]] && yaml_lines+=("  failurePolicy: ${failure_policy}")
  fi
  yaml_lines+=("  stages:")

  for idx in "${!cp_stages[@]}"; do
    stage_id="${cp_stages[$idx]}"
    stage_type="${cp_stage_types[$idx]:-agent}"
    runtime="${cp_stage_runtimes[$idx]:-}"
    agent="${cp_stage_agents[$idx]:-}"
    model="${cp_stage_models[$idx]:-}"
    session="${cp_stage_session[$idx]:-}"
    context="${cp_stage_context[$idx]:-}"
    plan_file="${cp_stage_plan_files[$idx]:-}"
    depends_on="${cp_stage_depends_on[$idx]:-}"
    policy="${cp_stage_policy[$idx]:-}"
    quorum="${cp_stage_quorum[$idx]:-}"
    workspace_mode="${cp_stage_workspace_mode[$idx]:-}"

    yaml_lines+=("    - id: ${stage_id}")
    if [[ "$mode" == "graph" && "$stage_type" != "agent" ]]; then
      yaml_lines+=("      type: ${stage_type}")
    fi

    if [[ "$stage_type" == "agent" ]]; then
      if [[ -n "$plan_file" ]]; then
        yaml_lines+=("      planFile: ${plan_file}")
      else
        yaml_lines+=("      runtime: ${runtime}")
        [[ -n "$agent" ]] && yaml_lines+=("      agent: ${agent}")
        [[ -n "$model" ]] && yaml_lines+=("      model: ${model}")
      fi
      [[ -n "$session" ]] && yaml_lines+=("      sessionStrategy: ${session}")
      [[ -n "$context" ]] && yaml_lines+=("      contextBudget: ${context}")
    fi

    if [[ "$mode" == "graph" ]]; then
      if [[ "$stage_type" == "consensus" || "$stage_type" == "join" ]]; then
        [[ -n "$policy" ]] && yaml_lines+=("      policy: ${policy}")
        [[ -n "$quorum" ]] && yaml_lines+=("      quorum: ${quorum}")
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

    if [[ "$mode" == "graph" && "$stage_type" == "consensus" ]]; then
      yaml_lines+=("      voters:")
      local vidx voter_id voter_runtime voter_agent voter_model
      for vidx in "${!cp_voter_node[@]}"; do
        [[ "${cp_voter_node[$vidx]}" == "$stage_id" ]] || continue
        voter_id="${cp_voter_id[$vidx]}"
        voter_runtime="${cp_voter_runtime[$vidx]}"
        voter_agent="${cp_voter_agent[$vidx]:-}"
        voter_model="${cp_voter_model[$vidx]:-}"
        yaml_lines+=("        - id: ${voter_id}")
        yaml_lines+=("          runtime: ${voter_runtime}")
        [[ -n "$voter_agent" ]] && yaml_lines+=("          agent: ${voter_agent}")
        [[ -n "$voter_model" ]] && yaml_lines+=("          model: ${voter_model}")
      done
    fi

    if [[ "$mode" == "graph" && "$stage_type" == "agent" && -n "$workspace_mode" ]]; then
      yaml_lines+=("      workspaceMode: ${workspace_mode}")
      if [[ "$workspace_mode" == "shared" ]]; then
        yaml_lines+=("      acknowledgeSharedMutationRisk: true")
        yaml_lines+=("      parallelMutation: allow")
      fi
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
    for wave in "${cp_parallel_waves[@]}"; do
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
  local stage stage_id runtime agent_selection agent agent_is_custom custom_model
  local model_default stage_model session context produces_input requires_input
  local artifact_default loop_idx loop_source loop_target loop_max

  cp_stages=()
  cp_stage_runtimes=()
  cp_stage_agents=()
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
    agent_selection="$(select_agent "$runtime" "$stage_id")"
    IFS=$'\t' read -r agent agent_is_custom custom_model <<< "$agent_selection"
    if [[ "${agent_is_custom:-0}" == "1" ]]; then
      stage_model="$custom_model"
      [[ -n "$stage_model" ]] || ralph_die "Model is required for custom $runtime stage \"$stage_id\"."
      cp_stage_agents+=("")
      cp_stage_models+=("$stage_model")
    else
      model_default="$(agent_model_default "$runtime" "$agent" | tr -d '\n')"
      stage_model="$(select_model_override "$runtime" "$agent" "$model_default")"
      cp_stage_agents+=("$agent")
      cp_stage_models+=("$stage_model")
    fi
    cp_stage_runtimes+=("$runtime")
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

# wizard_render_graph_jury_preset <plan_name> <plan_overview>
#
# Emit a cross-provider review jury graph plan non-interactively.
# The plan contains:
#   - a research node (cursor)
#   - an implement node (claude), consuming research output via derived edge
#   - a review consensus node with three voters on three distinct runtimes
#     (cursor, codex, claude), joined by a veto-policy join node
#   - a human-checkpoint node
#
# This preset is discoverable by name ("cross-provider-jury") and is the
# demonstration of the graph-mode differentiator: three genuinely independent
# providers vote, and a single changes-required blocks under veto policy.
wizard_render_graph_jury_preset() {
  local plan_name="${1:-jury-plan}"
  local plan_overview="${2:-Cross-provider review jury: three independent runtimes vote on every change.}"
  local ns
  ns="{{ARTIFACT_NS}}"

  cat <<EOF
---
name: ${plan_name}
namespace: ${plan_name}
overview: ${plan_overview}
execution: graph
instructions: Execute one TODO at a time.
pipeline:
  maxParallel: 3
  edgeDerivation: both
  failurePolicy: drain
  stages:
    - id: research
      runtime: cursor
      agent: research
      produces:
        - path: "${ns}/research.md"

    - id: implement
      runtime: claude
      agent: implementation
      dependsOn:
        - research
      requires:
        - path: "${ns}/research.md"
      produces:
        - path: "${ns}/implementation.md"

    - id: review
      type: consensus
      policy: veto
      dependsOn:
        - implement
      requires:
        - path: "${ns}/implementation.md"
      voters:
        - id: alpha
          runtime: cursor
          agent: code-review
          sessionStrategy: fresh
        - id: beta
          runtime: codex
          agent: code-review
          sessionStrategy: fresh
        - id: gamma
          runtime: claude
          agent: code-review
          sessionStrategy: fresh

    - id: decide
      type: join
      policy: veto
      dependsOn:
        - review

    - id: human-checkpoint
      type: checkpoint
      dependsOn:
        - decide

todos:
  - id: research-1
    stage: research
    content: |
      Research the change and write findings to the shared artifact.
    verification: |
      Confirm ${ns}/research.md exists and summarizes findings.
    status: pending

  - id: implement-1
    stage: implement
    content: |
      Implement the change described by the research artifact.
    verification: |
      Confirm ${ns}/implementation.md exists with the implementation.
    status: pending

  - id: review-1
    stage: review
    content: |
      Review the implementation and record a verdict in the evaluator-verdict schema.
    verification: |
      Confirm a verdict artifact exists for this voter.
    status: pending

  - id: decide-1
    stage: decide
    content: |
      Apply the veto policy to the three review verdicts.
    verification: |
      Confirm a consensus-result artifact was written under the consensus directory.
    status: pending

  - id: human-checkpoint-1
    stage: human-checkpoint
    content: |
      Wait for a human to acknowledge the decision before closing out.
    verification: |
      Confirm the acknowledgement artifact exists.
    status: pending
isProject: false
---
EOF
}

# wizard_render_graph_parallel_implementation_preset <name> <overview> <lanes>
#   <workspace-mode> <shared-risk-acknowledged> <publish-checkpoint>
#
# Version 1 deliberately freezes a static two-pass design: the architect node
# audits the already-authored lanes and ownership map, but cannot mutate the
# live graph. Graph compile is the topology boundary. Snapshot is the default;
# worktree is an explicit efficiency choice and shared mutation is emitted only
# after the caller has supplied the conspicuous acknowledgement flag.
wizard_render_graph_parallel_implementation_preset() {
  local plan_name="${1:-parallel-implementation}"
  local plan_overview="${2:-Parallel implementation with isolated, owned lanes and deterministic integration.}"
  local lane_count="${3:-2}"
  local workspace_mode="${4:-snapshot}"
  local shared_ack="${5:-false}"
  local publish_checkpoint="${6:-false}"
  local plan_key lane runtime scope plan_file
  plan_key="$(ralph_internal_wizard_sanitize "$plan_name")"

  cat <<EOF
---
name: ${plan_name}
namespace: ${plan_name}
overview: ${plan_overview}
execution: graph
instructions: Two-pass static planning only. Compile freezes the authored shard topology; no node may add nodes while a run is live.
pipeline:
  maxParallel: ${lane_count}
  edgeDerivation: declared
  strictEdges: true
  failurePolicy: drain
  publishMode: manual
  verificationProfiles:
    - name: fast
      steps:
        - name: fast-project-checks
          command: true
          timeout: 300
          continueOnFailure: false
          requiredArtifacts: []
    - name: full
      steps:
        - name: full-project-checks
          command: true
          timeout: 1200
          continueOnFailure: false
          requiredArtifacts: []
  stages:
    - id: plan-shards
      runtime: claude
      agent: architect
      planFile: .ralph-workspace/plans/${plan_key}-parallel/00-plan-shards.plan.md
      workspaceMode: snapshot
      agentGitAccess: off
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/parallel/shard-plan.md
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/parallel/ownership-map.json
EOF

  for ((lane = 1; lane <= lane_count; lane++)); do
    case "$lane" in
      1) runtime="cursor" ;;
      2) runtime="codex" ;;
      3) runtime="claude" ;;
      *) runtime="opencode" ;;
    esac
    scope="src/lane-${lane}/**"
    plan_file=".ralph-workspace/plans/${plan_key}-parallel/$(printf '%02d' "$lane")-lane-${lane}.plan.md"
    cat <<EOF

    - id: lane-${lane}
      runtime: ${runtime}
      agent: implementation
      planFile: ${plan_file}
      dependsOn:
        - plan-shards
      workspaceMode: ${workspace_mode}
      agentGitAccess: off
      writeScopes:
        - ${scope}
EOF
    if [[ "$workspace_mode" == "shared" ]]; then
      cat <<EOF
      parallelMutation: allow
      acknowledgeSharedMutationRisk: ${shared_ack}
EOF
    fi
    cat <<EOF
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/parallel/shard-plan.md
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/parallel/ownership-map.json
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/parallel/lane-${lane}-verification.md
EOF
  done

  cat <<EOF

    - id: full-gate
      type: gate
      profile: full
      dependsOn:
        - implementation-passed

    - id: review
      type: consensus
      policy: veto
      dependsOn:
        - full-gate
      subagents: off
      voters:
        - id: cursor-review
          runtime: cursor
          agent: code-review
          sessionStrategy: fresh
          subagents: off
        - id: codex-review
          runtime: codex
          agent: code-review
          sessionStrategy: fresh
          subagents: off
        - id: claude-review
          runtime: claude
          agent: code-review
          sessionStrategy: fresh
          subagents: off

    - id: review-decision
      type: join
      policy: veto
      dependsOn:
        - review
EOF
  if [[ "$publish_checkpoint" == "true" ]]; then
    cat <<'EOF'

    - id: publish-checkpoint
      type: checkpoint
      dependsOn:
        - review-decision
EOF
  fi

  cat <<EOF

  repairRounds:
    id: implementation
    rounds: 2
    dependsOn:
EOF
  for ((lane = 1; lane <= lane_count; lane++)); do
    printf '      - lane-%d\n' "$lane"
  done
  cat <<EOF
    integrate:
      workspaceMode: snapshot
    gate:
      profile: fast
    diagnose:
      runtime: claude
      agent: architect
      content: Diagnose fast-gate failures against the frozen ownership map and route each finding to exactly one repair lane.
    lanes:
EOF
  for ((lane = 1; lane <= lane_count; lane++)); do
    case "$lane" in
      1) runtime="cursor" ;;
      2) runtime="codex" ;;
      3) runtime="claude" ;;
      *) runtime="opencode" ;;
    esac
    scope="src/lane-${lane}/**"
    plan_file=".ralph-workspace/plans/${plan_key}-parallel/$(printf '%02d' "$lane")-lane-${lane}.plan.md"
    cat <<EOF
      - id: lane-${lane}
        runtime: ${runtime}
        agent: implementation
        planFile: ${plan_file}
        workspaceMode: ${workspace_mode}
        agentGitAccess: off
        writeScopes:
          - ${scope}
EOF
    if [[ "$workspace_mode" == "shared" ]]; then
      cat <<EOF
        parallelMutation: allow
        acknowledgeSharedMutationRisk: ${shared_ack}
EOF
    fi
    cat <<EOF
        content: Repair only findings assigned to lane-${lane}; do not widen ${scope} or change the frozen graph.
        verification: Re-run lane-${lane} verification before returning a changeset.
EOF
  done
  cat <<EOF
    reintegrate:
      workspaceMode: snapshot

todos: []
isProject: false
---
EOF
}

wizard_write_graph_parallel_plan_files() {
  local workspace="$1" plan_name="$2" lane_count="$3"
  local plan_key plans_dir lane scope plan_file
  plan_key="$(ralph_internal_wizard_sanitize "$plan_name")"
  plans_dir="$workspace/.ralph-workspace/plans/${plan_key}-parallel"
  mkdir -p "$plans_dir"

  cat >"$plans_dir/00-plan-shards.plan.md" <<EOF
---
name: ${plan_name} static shard proposal
overview: Audit the pre-authored static lanes before graph compile freezes execution.
execution: standard
instructions: Do not add nodes or mutate the graph. Produce the shard plan and one-owner-per-path ownership map for operator or compile-time validation.
todos:
  - id: propose-static-shards
    content: Write .ralph-workspace/artifacts/{{ARTIFACT_NS}}/parallel/shard-plan.md and .ralph-workspace/artifacts/{{ARTIFACT_NS}}/parallel/ownership-map.json for the ${lane_count} fixed lanes. Confirm every intended path is covered once and identify the explicit integration or repair owner for any intentional overlap.
    verification: Confirm the topology is static, all lane plan files are unique, and no live-run graph mutation is proposed.
    status: pending
isProject: false
---
EOF

  for ((lane = 1; lane <= lane_count; lane++)); do
    scope="src/lane-${lane}/**"
    plan_file="$plans_dir/$(printf '%02d' "$lane")-lane-${lane}.plan.md"
    cat >"$plan_file" <<EOF
---
name: ${plan_name} lane ${lane}
overview: Implement the statically assigned lane-${lane} shard.
execution: standard
instructions: Change only ${scope}; never edit the frozen graph or another lane plan.
todos:
  - id: implement-lane-${lane}
    content: Read the shard plan and ownership map, implement lane-${lane}, and write .ralph-workspace/artifacts/{{ARTIFACT_NS}}/parallel/lane-${lane}-verification.md.
    verification: Run lane-local checks for ${scope} and record the exact commands and results in the lane verification artifact.
    status: pending
isProject: false
---
EOF
  done
}
