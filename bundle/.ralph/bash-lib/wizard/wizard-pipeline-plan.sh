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
#   wizard_render_pipeline_orchestration_plan -- render a full pipeline orchestration plan file.
#   wizard_create_plan_interactive_execution_mode -- ask simple vs orchestration.
#   wizard_create_plan_interactive_orchestration -- interactive orchestration scaffolding flow.

# shellcheck source=bash-lib/error-handling.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../error-handling.sh"

wizard_create_plan_allowed_runtimes=(cursor claude codex opencode antigravity)
wizard_create_plan_allowed_session_strategies=(fresh resume reset compact)
wizard_create_plan_allowed_context_budgets=(full standard lean)

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

wizard_render_pipeline_orchestration_plan() {
  local plan_name="$1"
  local plan_overview="$2"
  local instructions_line="$3"
  local idx stage_id runtime agent model session context plan_file
  local loop_target loop_max loop_check
  local -a yaml_lines=()
  local requires_yaml produces_yaml todo_id todo_content todo_verification line

  yaml_lines+=("---")
  yaml_lines+=("name: ${plan_name}")
  yaml_lines+=("overview: ${plan_overview}")
  yaml_lines+=("execution: orchestration")
  yaml_lines+=("${instructions_line}")
  yaml_lines+=("pipeline:")
  yaml_lines+=("  stages:")

  for idx in "${!cp_stages[@]}"; do
    stage_id="${cp_stages[$idx]}"
    runtime="${cp_stage_runtimes[$idx]}"
    agent="${cp_stage_agents[$idx]:-}"
    model="${cp_stage_models[$idx]:-}"
    session="${cp_stage_session[$idx]:-}"
    context="${cp_stage_context[$idx]:-}"
    plan_file="${cp_stage_plan_files[$idx]:-}"

    yaml_lines+=("    - id: ${stage_id}")
    if [[ -n "$plan_file" ]]; then
      yaml_lines+=("      planFile: ${plan_file}")
    else
      yaml_lines+=("      runtime: ${runtime}")
      [[ -n "$agent" ]] && yaml_lines+=("      agent: ${agent}")
      [[ -n "$model" ]] && yaml_lines+=("      model: ${model}")
    fi
    [[ -n "$session" ]] && yaml_lines+=("      sessionStrategy: ${session}")
    [[ -n "$context" ]] && yaml_lines+=("      contextBudget: ${context}")

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

    loop_target="$(wizard_create_plan_loop_target "$stage_id")"
    if [[ -n "$loop_target" ]]; then
      loop_max="$(wizard_create_plan_loop_max "$stage_id")"
      loop_check="$(wizard_create_plan_loop_check "$stage_id")"
      yaml_lines+=("      loopBackTo: ${loop_target}")
      yaml_lines+=("      maxIterations: ${loop_max}")
      yaml_lines+=("      loopCheck:")
      yaml_lines+=("        path: ${loop_check}")
    fi
  done

  if ((${#cp_parallel_waves[@]} > 0)); then
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
    plan_file="${cp_stage_plan_files[$idx]:-}"
    todo_id="${stage_id}-1"

    yaml_lines+=("  - id: ${todo_id}")
    yaml_lines+=("    stage: ${stage_id}")

    if [[ -n "$plan_file" ]]; then
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
