#!/usr/bin/env bash

downstream_stages() {
  local orch_file="$1"
  local current_stage_id="$2"
  local artifact_ns="$3"

  [[ -n "$orch_file" ]] || { echo "orchestration file path required" >&2; return 1; }
  [[ -n "$current_stage_id" ]] || { echo "current stage id required" >&2; return 1; }

  local artifact_ns_value="$artifact_ns"
  if [[ -z "$artifact_ns_value" ]]; then
    artifact_ns_value="${RALPH_ARTIFACT_NS:-${RALPH_PLAN_KEY:-default}}"
  fi

  local jq_bin
  if ! jq_bin="$(command -v jq 2>/dev/null)"; then
    echo "jq is required for downstream_stages" >&2
    return 1
  fi

  [[ -f "$orch_file" ]] || { echo "orchestration file not found: $orch_file" >&2; return 1; }

  if ! "$jq_bin" -e --arg id "$current_stage_id" '.stages[] | select(.id == $id)' "$orch_file" >/dev/null; then
    echo "stage not found: $current_stage_id" >&2
    return 1
  fi

  local -a output_paths=()
  local path
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    path="${path//\{\{ARTIFACT_NS\}\}/$artifact_ns_value}"
    output_paths+=("$path")
  done < <("$jq_bin" -r --arg id "$current_stage_id" '.stages[] | select(.id == $id) | (.outputArtifacts // [])[].path' "$orch_file")

  if (( ${#output_paths[@]} == 0 )); then
    return 0
  fi

  local found_current=0
  local stage_json
  while IFS= read -r stage_json; do
    local stage_id
    stage_id="$("$jq_bin" -r '.id // empty' <<< "$stage_json")"
    if [[ "$found_current" -eq 0 ]]; then
      if [[ "$stage_id" == "$current_stage_id" ]]; then
        found_current=1
      fi
      continue
    fi

    local -a input_paths=()
    local input_path
    while IFS= read -r input_path; do
      [[ -z "$input_path" ]] && continue
      input_path="${input_path//\{\{ARTIFACT_NS\}\}/$artifact_ns_value}"
      input_paths+=("$input_path")
    done < <("$jq_bin" -r '(.inputArtifacts // [])[].path' <<< "$stage_json")

    if (( ${#input_paths[@]} == 0 )); then
      continue
    fi

    local matched=0
    local output_path
    for output_path in "${output_paths[@]}"; do
      local input_path_check
      for input_path_check in "${input_paths[@]}"; do
        if [[ "$output_path" == "$input_path_check" ]]; then
          matched=1
          break 2
        fi
      done
    done

    if [[ "$matched" -eq 0 ]]; then
      continue
    fi

    local plan_path plan_template
    plan_path="$("$jq_bin" -r '.plan // ""' <<< "$stage_json")"
    plan_template="$("$jq_bin" -r '.planTemplate // ""' <<< "$stage_json")"

    echo "---"
    echo "STAGE_ID=$stage_id"
    echo "PLAN_PATH=$plan_path"
    echo "PLAN_TEMPLATE=$plan_template"
  done < <("$jq_bin" -c '.stages[]' "$orch_file")
}
