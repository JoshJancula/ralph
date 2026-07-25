#!/usr/bin/env bash

if [[ -n "${RALPH_RUN_PLAN_LOOPBACK_LIB_LOADED:-}" ]]; then
  return
fi
RALPH_RUN_PLAN_LOOPBACK_LIB_LOADED=1

if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$SCRIPT_DIR/bash-lib/review-status.sh"

ralph_run_plan_loopback_state_file() {
  printf '%s/pipeline-loop-state.json\n' "$RALPH_SESSION_DIR"
}

ralph_run_plan_loopback_get_iteration_count() {
  local source_stage="$1"
  local target_stage="$2"
  local state_file
  state_file="$(ralph_run_plan_loopback_state_file)"

  if [[ ! -f "$state_file" ]]; then
    printf '0\n'
    return 0
  fi

  if ! command -v python3 &>/dev/null; then
    printf '0\n'
    return 0
  fi

  local iterations
  if ! iterations="$(python3 - "$state_file" "$source_stage" "$target_stage" <<'PY'
import json
import sys

state_file = sys.argv[1]
source = sys.argv[2]
target = sys.argv[3]
loop_key = f"{source}->{target}"

try:
  with open(state_file, "r", encoding="utf-8") as fh:
    data = json.load(fh)
except (json.JSONDecodeError, ValueError) as exc:
  print(f"Malformed loop state file: {exc}", file=sys.stderr)
  sys.exit(1)

loops = data.get("loops", {})
loop_state = loops.get(loop_key, {})
iterations = loop_state.get("iterations", 0)
print(iterations)
PY
)"; then
    ralph_run_plan_log "ERROR: loop state file malformed at $state_file"
    echo "Error: loop state file is malformed at '$state_file'" >&2
    return 1
  fi

  printf '%s\n' "$iterations"
  return 0
}

ralph_run_plan_loopback_increment_iteration_count() {
  local source_stage="$1"
  local target_stage="$2"
  local state_file
  state_file="$(ralph_run_plan_loopback_state_file)"

  if ! command -v python3 &>/dev/null; then
    return 1
  fi

  mkdir -p "$(dirname "$state_file")"

  local incremented_count
  if ! incremented_count="$(python3 - "$state_file" "$source_stage" "$target_stage" <<'PY'
import json
import sys

state_file = sys.argv[1]
source = sys.argv[2]
target = sys.argv[3]
loop_key = f"{source}->{target}"

try:
  with open(state_file, "r", encoding="utf-8") as fh:
    data = json.load(fh)
except FileNotFoundError:
  data = {"loops": {}}
except (json.JSONDecodeError, ValueError) as exc:
  print(f"Malformed loop state file: {exc}", file=sys.stderr)
  sys.exit(1)

loops = data.get("loops", {})
if loop_key not in loops:
  loops[loop_key] = {"iterations": 0}

loops[loop_key]["iterations"] += 1
data["loops"] = loops

with open(state_file, "w", encoding="utf-8") as fh:
  json.dump(data, fh, indent=2)

print(loops[loop_key]["iterations"])
PY
)"; then
    ralph_run_plan_log "ERROR: loop state file malformed at $state_file"
    echo "Error: loop state file is malformed at '$state_file'" >&2
    return 1
  fi

  printf '%s\n' "$incremented_count"
  return 0
}

ralph_run_plan_loopback_reopen_todos_for_stage() {
  local plan_path="$1"
  local plan_format="$2"
  local stage_id="$3"
  local reopened_count=0

  if ! plan_format_is_yaml "$plan_format"; then
    return 0
  fi

  if ! command -v python3 &>/dev/null; then
    return 0
  fi

  local total_count ordinal metadata_json todo_stage todo_status
  read -r _done_unused total_count <<< "$(count_todos "$plan_path")"
  for ((ordinal = 1; ordinal <= total_count; ordinal++)); do
    metadata_json="$(plan_pipeline_todo_metadata_json "$plan_path" "$ordinal" 2>/dev/null || true)"
    [[ -n "$metadata_json" ]] || continue
    todo_stage="$(printf '%s' "$metadata_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("stage",""))' 2>/dev/null || true)"
    todo_status="$(printf '%s' "$metadata_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' 2>/dev/null || true)"
    if [[ "$todo_stage" == "$stage_id" && "$todo_status" == "completed" ]]; then
      if plan_reopen_todo_by_format "$plan_path" "$plan_format" "$ordinal" >/dev/null 2>&1; then
        reopened_count=$((reopened_count + 1))
      fi
    fi
  done

  printf '%d\n' "$reopened_count"
  return 0
}

ralph_run_plan_loopback_stage_ids_in_range() {
  local plan_path="$1"
  local source_stage="$2"
  local target_stage="$3"

  python3 - "$plan_path" "$source_stage" "$target_stage" <<'PY'
import sys

plan_path = sys.argv[1]
source_stage = sys.argv[2]
target_stage = sys.argv[3]

with open(plan_path, "r", encoding="utf-8") as fh:
    lines = fh.read().splitlines()

in_pipeline = False
in_stages = False
stage_ids = []

for raw_line in lines:
    stripped = raw_line.strip()
    if stripped == "pipeline:":
        in_pipeline = True
        in_stages = False
        continue
    if not in_pipeline:
        continue
    if stripped == "todos:":
        break
    if raw_line.startswith("  stages:"):
        in_stages = True
        continue
    if in_stages and raw_line.startswith("    - id:"):
        stage_ids.append(stripped.split(":", 1)[1].strip())

if source_stage not in stage_ids or target_stage not in stage_ids:
    raise SystemExit(1)

source_idx = stage_ids.index(source_stage)
target_idx = stage_ids.index(target_stage)
if target_idx > source_idx:
    raise SystemExit(1)

for stage_id in stage_ids[target_idx:source_idx + 1]:
    print(stage_id)
PY
}

ralph_run_plan_loopback_reopen_todos_in_range() {
  local plan_path="$1"
  local plan_format="$2"
  local source_stage="$3"
  local target_stage="$4"
  local total_reopened=0

  if ! plan_format_is_yaml "$plan_format"; then
    printf '0\n'
    return 0
  fi

  if ! command -v python3 &>/dev/null; then
    printf '0\n'
    return 0
  fi

  local stage_id
  while IFS= read -r stage_id; do
    [[ -n "$stage_id" ]] || continue
    total_reopened=$((total_reopened + $(ralph_run_plan_loopback_reopen_todos_for_stage "$plan_path" "$plan_format" "$stage_id")))
  done < <(ralph_run_plan_loopback_stage_ids_in_range "$plan_path" "$source_stage" "$target_stage" 2>/dev/null || true)

  printf '%d\n' "$total_reopened"
  return 0
}

ralph_run_plan_loopback_check_and_handle() {
  local plan_path="$1"
  local plan_format="$2"
  local todo_target="$3"
  local line_num="$4"

  if ! plan_format_is_yaml "$plan_format"; then
    return 0
  fi

  if ! declare -F plan_pipeline_effective_metadata_json &>/dev/null 2>&1; then
    return 0
  fi

  local metadata_json
  metadata_json=$(plan_pipeline_effective_metadata_json "$plan_path" "$todo_target" 2>/dev/null || true)

  if [[ -z "$metadata_json" ]]; then
    return 0
  fi

  local loop_back_to loop_check_path max_iterations source_stage
  source_stage=$(printf '%s' "$metadata_json" | python3 -c "import json, sys; d=json.load(sys.stdin); print(d.get('stage', ''))" 2>/dev/null || true)

  if [[ -z "$source_stage" ]]; then
    return 0
  fi

  loop_back_to=$(printf '%s' "$metadata_json" | python3 -c "import json, sys; d=json.load(sys.stdin); print(d.get('loopBackTo', ''))" 2>/dev/null || true)
  loop_check_path=$(printf '%s' "$metadata_json" | python3 -c "import json, sys; d=json.load(sys.stdin); print(d.get('loopCheck', {}).get('path', ''))" 2>/dev/null || true)
  max_iterations=$(printf '%s' "$metadata_json" | python3 -c "import json, sys; d=json.load(sys.stdin); print(d.get('maxIterations', ''))" 2>/dev/null || true)

  local loop_check_schema on_exhausted
  loop_check_schema=$(printf '%s' "$metadata_json" | python3 -c "import json, sys; d=json.load(sys.stdin); print(d.get('loopCheck', {}).get('schema', ''))" 2>/dev/null || true)
  on_exhausted=$(printf '%s' "$metadata_json" | python3 -c "import json, sys; d=json.load(sys.stdin); print(d.get('onExhausted', ''))" 2>/dev/null || true)

  if [[ -z "$loop_back_to" || -z "$loop_check_path" || -z "$max_iterations" ]]; then
    return 0
  fi

  local resolved_loop_check_path loop_check_abs_path
  resolved_loop_check_path="$(expand_artifact_tokens "$loop_check_path")"
  loop_check_abs_path="$(ralph_run_plan_artifact_abs_path "$resolved_loop_check_path")"

  if [[ ! -f "$loop_check_abs_path" ]]; then
    ralph_run_plan_log "ERROR: loop-check artifact missing for stage=$source_stage path=$resolved_loop_check_path"
    echo "Error: loop-check artifact missing for stage '$source_stage' at path '$resolved_loop_check_path'" >&2
    return 1
  fi

  # Resolve an evaluator schema (project-root-relative) when declared. When present
  # and the JSON-contract gate is enabled, the artifact is parsed only as validated
  # JSON; otherwise the legacy REVIEW_STATUS markdown parser is used.
  local loop_check_schema_abs=""
  if [[ -n "$loop_check_schema" ]]; then
    loop_check_schema_abs="$(ralph_run_plan_artifact_abs_path "$(expand_artifact_tokens "$loop_check_schema")")"
  fi

  local status
  if ! status="$(ralph_extract_review_status_with_schema "$loop_check_abs_path" "$loop_check_schema_abs" 2>/dev/null)"; then
    status="${status:-missing_status}"
    ralph_run_plan_log "ERROR: invalid loop-check artifact for stage=$source_stage path=$resolved_loop_check_path status=$status"
    echo "Error: loop-check artifact invalid for stage '$source_stage' at path '$resolved_loop_check_path' (status: $status)" >&2
    return 1
  fi

  case "$status" in
    approved)
      ralph_run_plan_log "loopback approved for stage=$source_stage target=$loop_back_to path=$resolved_loop_check_path (no reopening)"
      return 0
      ;;
    changes-required)
      local current_iterations
      if ! current_iterations="$(ralph_run_plan_loopback_get_iteration_count "$source_stage" "$loop_back_to")"; then
        return 1
      fi

      if (( current_iterations >= max_iterations )); then
        ralph_run_plan_log "loopback max iterations reached for stage=$source_stage target=$loop_back_to iterations=$current_iterations max=$max_iterations onExhausted=${on_exhausted:-fail}"
        if [[ "$on_exhausted" == "proceed" ]]; then
          echo "loopback exhausted after $current_iterations iteration(s) for stage '$source_stage'; proceeding per onExhausted: proceed" >&2
          return 0
        fi
        echo "Error: loopback exhausted after $current_iterations iteration(s) for stage '$source_stage' (maxIterations=$max_iterations); review still requires changes" >&2
        return 1
      fi

      local incremented_count
      if ! incremented_count="$(ralph_run_plan_loopback_increment_iteration_count "$source_stage" "$loop_back_to")"; then
        return 1
      fi
      ralph_run_plan_log "loopback changes-required for stage=$source_stage target=$loop_back_to iterations=$incremented_count"

      # Inject reviewer feedback verbatim into the looped-back plan when the
      # evaluator declared a JSON schema. Failure to inject is non-fatal: the
      # loop still reopens todos so the work resumes.
      if [[ -n "$loop_check_schema_abs" ]]; then
        if ralph_schema_is_rubric_result "$loop_check_schema_abs" && ralph_rubric_grader_enabled 2>/dev/null; then
          if ralph_rubric_inject_feedback_into_plan \
            "$plan_path" "$loop_check_abs_path" "$source_stage" "$incremented_count" \
            "$resolved_loop_check_path" "$loop_check_schema_abs"; then
            ralph_run_plan_log "loopback injected rubric grader feedback for stage=$source_stage iteration=$incremented_count"
          else
            ralph_run_plan_log "WARN: failed to inject rubric grader feedback for stage=$source_stage iteration=$incremented_count"
          fi
        elif ralph_evaluator_json_contract_enabled 2>/dev/null; then
          if ralph_evaluator_inject_feedback_into_plan \
            "$plan_path" "$loop_check_abs_path" "$source_stage" "$incremented_count" \
            "$resolved_loop_check_path" "$loop_check_schema_abs"; then
            ralph_run_plan_log "loopback injected evaluator feedback for stage=$source_stage iteration=$incremented_count"
          else
            ralph_run_plan_log "WARN: failed to inject evaluator feedback for stage=$source_stage iteration=$incremented_count"
          fi
        fi
      fi

      local reopened
      reopened=$(ralph_run_plan_loopback_reopen_todos_in_range "$plan_path" "$plan_format" "$source_stage" "$loop_back_to" 2>/dev/null || true)

      if [[ -n "$reopened" && "$reopened" != "0" ]]; then
        read -r done_count total_count <<< "$(count_todos "$plan_path")"
        echo "loopback reopened $reopened TODO(s); progress is now $done_count/$total_count" >&2
        ralph_run_plan_log "loopback reopened=$reopened progress=$done_count/$total_count"
        return 2
      fi
      return 0
      ;;
    *)
      ralph_run_plan_log "ERROR: unknown loop-check status for stage=$source_stage path=$resolved_loop_check_path status=$status"
      echo "Error: loop-check artifact unknown status for stage '$source_stage' at path '$resolved_loop_check_path' (status: $status)" >&2
      return 1
      ;;
  esac
}
