#!/usr/bin/env bash

if [[ -n "${RALPH_RUBRIC_GRADER_LIB_LOADED:-}" ]]; then
  return
fi
RALPH_RUBRIC_GRADER_LIB_LOADED=1

if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

_ralph_rubric_grader_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_ralph_rubric_grader_dir/review-status.sh"
unset _ralph_rubric_grader_dir

ralph_rubric_grader_resolve_py() {
  local candidate="" dir
  for dir in "${RALPH_ACTIVE_DIR:-}" "${RALPH_DIR:-}" "${SCRIPT_DIR:-}"; do
    [[ -n "$dir" ]] || continue
    if [[ -f "$dir/python/rubric_grader.py" ]]; then
      candidate="$dir/python/rubric_grader.py"
      break
    fi
  done
  if [[ -z "$candidate" ]]; then
    return 1
  fi
  printf '%s\n' "$candidate"
}

ralph_rubric_grader_stage_active() {
  [[ "${RALPH_GRADER_STAGE:-0}" == "1" ]] && ralph_rubric_grader_enabled
}

ralph_rubric_grader_validate_session_strategy() {
  local strategy="${1:-fresh}"
  if ! ralph_rubric_grader_stage_active; then
    return 0
  fi
  if [[ "$strategy" != "fresh" ]]; then
    echo "grader stage requires sessionStrategy: fresh (got ${strategy:-unset})" >&2
    return 1
  fi
  return 0
}

ralph_rubric_grader_apply_session_isolation() {
  if ! ralph_rubric_grader_stage_active; then
    return 0
  fi
  RALPH_PLAN_SESSION_STRATEGY="fresh"
  export RALPH_PLAN_SESSION_STRATEGY
  RALPH_PLAN_CLI_RESUME=0
  export RALPH_PLAN_CLI_RESUME
  unset RALPH_RUN_PLAN_RESUME_SESSION_ID
  unset RALPH_RUN_PLAN_RESUME_BARE
  return 0
}

ralph_rubric_grader_state_dir() {
  printf '%s/rubric-grader\n' "${RALPH_SESSION_DIR:-/tmp}"
}

ralph_rubric_grader_deterministic_path() {
  printf '%s/deterministic.json\n' "$(ralph_rubric_grader_state_dir)"
}

ralph_rubric_grader_run_deterministic() {
  local rubric_abs="$1"
  local workspace="$2"
  local out_path
  out_path="$(ralph_rubric_grader_deterministic_path)"
  local py
  if ! py="$(ralph_rubric_grader_resolve_py)"; then
    echo "rubric grader helper not found" >&2
    return 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required for rubric grading" >&2
    return 1
  fi
  mkdir -p "$(dirname "$out_path")"
  if ! python3 "$py" deterministic \
    --rubric "$rubric_abs" \
    --workspace "$workspace" \
    --artifact-ns "${RALPH_ARTIFACT_NS:-}" \
    --plan-key "${RALPH_PLAN_KEY:-}" \
    --stage-id "${RALPH_STAGE_ID:-}" \
    --timeout "${RALPH_VERIFY_TIMEOUT:-300}" \
    >"$out_path"; then
    return 1
  fi
  printf '%s\n' "$out_path"
}

ralph_rubric_grader_build_prompt_block() {
  local rubric_abs="$1"
  local det_path="$2"
  local py targets sources
  if ! py="$(ralph_rubric_grader_resolve_py)"; then
    return 1
  fi
  targets=""
  if ((${#RALPH_RUN_PLAN_INPUT_ARTIFACT_PATHS[@]} > 0)); then
    targets="$(printf '%s\n' "${RALPH_RUN_PLAN_INPUT_ARTIFACT_PATHS[@]}")"
  fi
  sources="$targets"
  python3 "$py" model-prompt \
    --rubric "$rubric_abs" \
    --deterministic "$det_path" \
    --targets "$targets" \
    --sources "$sources"
}

ralph_rubric_grader_merge_result() {
  local rubric_abs="$1"
  local det_path="$2"
  local model_result="${3:-}"
  local output_abs="$4"
  local py
  if ! py="$(ralph_rubric_grader_resolve_py)"; then
    return 1
  fi
  local args=(merge --rubric "$rubric_abs" --deterministic "$det_path" --output "$output_abs")
  if [[ -n "$model_result" && -f "$model_result" ]]; then
    args+=(--model-result "$model_result")
  fi
  python3 "$py" "${args[@]}"
}

ralph_rubric_grader_resolve_rubric_abs() {
  local rubric_rel="${RALPH_RUBRIC_PATH:-}"
  local workspace="${RALPH_PROJECT_ROOT:-${WORKSPACE:-}}"
  if [[ -z "$rubric_rel" ]]; then
    echo "grader stage missing rubric path" >&2
    return 1
  fi
  if [[ "$rubric_rel" == /* ]]; then
    printf '%s\n' "$rubric_rel"
  else
    printf '%s/%s\n' "${workspace%/}" "$rubric_rel"
  fi
}

ralph_rubric_grader_prepare_prompt() {
  local rubric_abs det_path block rubric_text
  if ! rubric_abs="$(ralph_rubric_grader_resolve_rubric_abs)"; then
    return 1
  fi
  if ! det_path="$(ralph_rubric_grader_run_deterministic "$rubric_abs" "${RALPH_PROJECT_ROOT:-$WORKSPACE}")"; then
    return 1
  fi
  rubric_text="$(cat "$rubric_abs")"
  block="$(ralph_rubric_grader_build_prompt_block "$rubric_abs" "$det_path" 2>/dev/null || true)"
  cat <<EOF
## Independent rubric grader

You are a stateless grader. You receive only the rubric, target artifacts, allowed
sources/tools, and grading instructions below. Do not rely on writer session history,
continuation summaries, or prior hidden reasoning.

### Rubric file
\`\`\`json
${rubric_text}
\`\`\`

${block}
EOF
}
