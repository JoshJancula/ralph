#!/usr/bin/env bash

if [[ -n "${RALPH_RUN_PLAN_STRUCTURED_OUTPUT_LOADED:-}" ]]; then
  return
fi
RALPH_RUN_PLAN_STRUCTURED_OUTPUT_LOADED=1

# Rollout gate for structured final-output enforcement.
# Ralph/hybrid mode enables it unless RALPH_FINAL_OUTPUT_SCHEMA=0.
# Native/no mode leaves it disabled unless RALPH_FINAL_OUTPUT_SCHEMA=1.
ralph_final_output_schema_enabled() {
  local gate="${RALPH_FINAL_OUTPUT_SCHEMA:-}"
  if [[ -n "$gate" ]]; then
    case "$gate" in
      0) return 1 ;;
      1) return 0 ;;
      *)
        if declare -F ralph_run_plan_log >/dev/null 2>&1; then
          ralph_run_plan_log "RALPH_FINAL_OUTPUT_SCHEMA: invalid value '$gate' (use 0 or 1)"
        fi
        echo "RALPH_FINAL_OUTPUT_SCHEMA: invalid value '$gate' (use 0 or 1)" >&2
        return 2
        ;;
    esac
  fi
  case "${RALPH_MODE:-no}" in
    ralph|hybrid) return 0 ;;
    *) return 1 ;;
  esac
}

run_plan_structured_output_resolve_py() {
  local candidate="" dir
  for dir in "${RALPH_ACTIVE_DIR:-}" "${RALPH_DIR:-}" "${SCRIPT_DIR:-}"; do
    [[ -n "$dir" ]] || continue
    if [[ -f "$dir/python/artifact_json_schema.py" ]]; then
      candidate="$dir/python/artifact_json_schema.py"
      break
    fi
  done
  if [[ -z "$candidate" ]]; then
    return 1
  fi
  printf '%s\n' "$candidate"
}

_run_plan_structured_output_schema_abs() {
  local schema_rel="${RALPH_STRUCTURED_OUTPUT_SCHEMA:-}"
  local workspace="${RALPH_PROJECT_ROOT:-${WORKSPACE:-}}"
  [[ -n "$schema_rel" ]] || return 1
  if [[ "$schema_rel" == /* ]]; then
    printf '%s\n' "$schema_rel"
  else
    printf '%s/%s\n' "${workspace%/}" "$schema_rel"
  fi
}

run_plan_structured_output_resolve_schema_abs() {
  local schema_abs
  if ! schema_abs="$(_run_plan_structured_output_schema_abs 2>/dev/null)"; then
    return 1
  fi
  if [[ ! -f "$schema_abs" ]]; then
    echo "structured output schema file not found: ${RALPH_STRUCTURED_OUTPUT_SCHEMA:-}" >&2
    return 1
  fi
  printf '%s\n' "$schema_abs"
}

run_plan_structured_output_active() {
  ralph_final_output_schema_enabled || return 1
  local schema_abs
  schema_abs="$(run_plan_structured_output_resolve_schema_abs 2>/dev/null || true)"
  [[ -n "$schema_abs" && -f "$schema_abs" ]]
}

_run_plan_structured_output_compact_json() {
  local schema_abs="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1], encoding="utf-8")), separators=(",",":")))' "$schema_abs"
  else
    tr -d '[:space:]' <"$schema_abs"
  fi
}

_run_plan_invoke_claude_json_schema_supported() {
  local cli_name="${1:-${CLAUDE_PLAN_CLI:-claude}}"
  command -v "$cli_name" >/dev/null 2>&1 || return 1
  "$cli_name" --help 2>&1 | grep -q -- '--json-schema'
}

_run_plan_invoke_codex_output_schema_supported() {
  local cli_name="${1:-${CODEX_PLAN_CLI:-${CODEX_CLI:-codex}}}"
  command -v "$cli_name" >/dev/null 2>&1 || return 1
  "$cli_name" --help 2>&1 | grep -q -- 'output-schema'
}

# Append structured-output CLI flags when capability-detected.
# Sets RALPH_STRUCTURED_OUTPUT_CLI_APPLIED to claude-json-schema, codex-output-schema, or none.
run_plan_invoke_common_add_structured_output_flag() {
  local args_name="$1"
  local runtime="${2:-${RUNTIME:-}}"
  local cli_name="${3:-}"
  local schema_abs compact_json

  RALPH_STRUCTURED_OUTPUT_CLI_APPLIED="none"
  export RALPH_STRUCTURED_OUTPUT_CLI_APPLIED

  if ! run_plan_structured_output_active; then
    return 0
  fi

  schema_abs="$(run_plan_structured_output_resolve_schema_abs)" || return 0

  case "$runtime" in
    claude)
      cli_name="${cli_name:-${CLAUDE_PLAN_CLI:-claude}}"
      if _run_plan_invoke_claude_json_schema_supported "$cli_name"; then
        compact_json="$(_run_plan_structured_output_compact_json "$schema_abs")"
        eval "$args_name+=(--json-schema $(printf '%q' "$compact_json"))"
        RALPH_STRUCTURED_OUTPUT_CLI_APPLIED="claude-json-schema"
        export RALPH_STRUCTURED_OUTPUT_CLI_APPLIED
        if declare -F ralph_run_plan_log >/dev/null 2>&1; then
          ralph_run_plan_log "structured output: applied Claude --json-schema"
        fi
      fi
      ;;
    codex)
      cli_name="${cli_name:-${CODEX_PLAN_CLI:-${CODEX_CLI:-codex}}}"
      if _run_plan_invoke_codex_output_schema_supported "$cli_name"; then
        eval "$args_name+=(--output-schema $(printf '%q' "$schema_abs"))"
        RALPH_STRUCTURED_OUTPUT_CLI_APPLIED="codex-output-schema"
        export RALPH_STRUCTURED_OUTPUT_CLI_APPLIED
        if declare -F ralph_run_plan_log >/dev/null 2>&1; then
          ralph_run_plan_log "structured output: applied Codex --output-schema"
        fi
      fi
      ;;
    *)
      ;;
  esac
}

run_plan_structured_output_needs_prompt_contract() {
  local runtime="${1:-${RUNTIME:-}}"
  local cli_name=""
  if ! run_plan_structured_output_active; then
    return 1
  fi
  case "$runtime" in
    claude)
      cli_name="${CLAUDE_PLAN_CLI:-claude}"
      if _run_plan_invoke_claude_json_schema_supported "$cli_name"; then
        return 1
      fi
      return 0
      ;;
    codex)
      cli_name="${CODEX_PLAN_CLI:-${CODEX_CLI:-codex}}"
      if _run_plan_invoke_codex_output_schema_supported "$cli_name"; then
        return 1
      fi
      return 0
      ;;
    *)
      return 0
      ;;
  esac
}

run_plan_structured_output_build_prompt_block() {
  local schema_abs compact_json
  if ! schema_abs="$(run_plan_structured_output_resolve_schema_abs 2>/dev/null)"; then
    return 1
  fi
  compact_json="$(_run_plan_structured_output_compact_json "$schema_abs")"
  cat <<EOF
## Structured final output (JSON only)

Your final response must be valid JSON matching this schema exactly. Do not wrap
the JSON in markdown prose, explanations, or code fences unless the schema itself
requires strings. No additional keys beyond what the schema allows.

Schema:
\`\`\`json
${compact_json}
\`\`\`

Emit only the JSON object as your final output.
EOF
}

# Resolve finalOutputSchema for an orchestration stage JSON object.
# Explicit finalOutputSchema wins; otherwise infer defaults for grader, router,
# planner, and evaluator loop stages.
orch_resolve_final_output_schema() {
  local stage_json="$1"
  local schema=""
  schema="$(printf '%s' "$stage_json" | jq -r '.finalOutputSchema // empty' 2>/dev/null || echo "")"
  if [[ -n "$schema" ]]; then
    printf '%s\n' "$schema"
    return 0
  fi
  if printf '%s' "$stage_json" | jq -e '.grader == true' >/dev/null 2>&1; then
    printf '%s\n' "bundle/.ralph/schemas/rubric-result.schema.json"
    return 0
  fi
  if printf '%s' "$stage_json" | jq -e '.router | type == "object"' >/dev/null 2>&1; then
    printf '%s\n' "bundle/.ralph/schemas/router-decision.schema.json"
    return 0
  fi
  if printf '%s' "$stage_json" | jq -e '.planner | type == "object"' >/dev/null 2>&1; then
    printf '%s\n' "bundle/.ralph/schemas/planner-output.schema.json"
    return 0
  fi
  schema="$(printf '%s' "$stage_json" | jq -r '.loopControl.evaluatorSchema // empty' 2>/dev/null || echo "")"
  if [[ -n "$schema" ]]; then
    printf '%s\n' "$schema"
    return 0
  fi
  return 0
}

# Validate structured final output from agent text and/or produced JSON artifacts.
# Returns 0 when validation is disabled, passes, or no schema is configured.
run_plan_validate_structured_final_output() {
  local output_text="${1:-}"
  local plan_path="${2:-${PLAN_PATH:-}}"
  local todo_target="${3:-}"
  local py schema_abs artifact_abs artifact_rel args

  if ! run_plan_structured_output_active; then
    return 0
  fi
  if ! schema_abs="$(run_plan_structured_output_resolve_schema_abs 2>/dev/null)"; then
    return 0
  fi
  if ! py="$(run_plan_structured_output_resolve_py)"; then
    echo "structured output validator not found under Ralph python helpers" >&2
    return 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required for structured final-output validation" >&2
    return 1
  fi

  args=(validate-final-output --schema "$schema_abs")
  if [[ -n "$output_text" ]]; then
    args+=(--text "$output_text")
  fi

  if [[ -n "$plan_path" && -n "$todo_target" ]] && declare -F ralph_run_plan_artifact_abs_path >/dev/null 2>&1; then
    while IFS=$'\t' read -r _required_flag raw_path || [[ -n "$raw_path" ]]; do
      [[ -n "$raw_path" ]] || continue
      [[ "$raw_path" == *.json ]] || continue
      artifact_rel="$(expand_artifact_tokens "$raw_path")"
      artifact_abs="$(ralph_run_plan_artifact_abs_path "$artifact_rel")"
      if [[ -f "$artifact_abs" && -s "$artifact_abs" ]]; then
        args+=(--artifact "$artifact_abs")
      fi
    done < <(ralph_run_plan_pipeline_artifact_entries "$plan_path" "$todo_target" "produces" 2>/dev/null || true)
  fi

  if ! python3 "$py" "${args[@]}"; then
    if declare -F ralph_run_plan_log >/dev/null 2>&1; then
      ralph_run_plan_log "structured final-output validation failed schema=${RALPH_STRUCTURED_OUTPUT_SCHEMA:-}"
    fi
    return 1
  fi
  if declare -F ralph_run_plan_log >/dev/null 2>&1; then
    ralph_run_plan_log "structured final-output validation passed schema=${RALPH_STRUCTURED_OUTPUT_SCHEMA:-}"
  fi
  return 0
}
