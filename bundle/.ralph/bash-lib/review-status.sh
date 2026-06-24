#!/usr/bin/env bash

if [[ -n "${RALPH_REVIEW_STATUS_LIB_LOADED:-}" ]]; then
  return
fi
RALPH_REVIEW_STATUS_LIB_LOADED=1

if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

# Rollout gate for the formal evaluator JSON contract.
# Ralph/hybrid mode enables it unless RALPH_EVALUATOR_JSON_CONTRACT=0.
# Native/no mode leaves it disabled unless RALPH_EVALUATOR_JSON_CONTRACT=1.
# Invalid values fail early (return 2).
ralph_evaluator_json_contract_enabled() {
  local gate="${RALPH_EVALUATOR_JSON_CONTRACT:-}"
  if [[ -n "$gate" ]]; then
    case "$gate" in
      0) return 1 ;;
      1) return 0 ;;
      *)
        if declare -F ralph_warn >/dev/null 2>&1; then
          ralph_warn "RALPH_EVALUATOR_JSON_CONTRACT: invalid value '$gate' (use 0 or 1)"
        else
          echo "RALPH_EVALUATOR_JSON_CONTRACT: invalid value '$gate' (use 0 or 1)" >&2
        fi
        return 2
        ;;
    esac
  fi
  case "${RALPH_MODE:-no}" in
    ralph|hybrid) return 0 ;;
    *) return 1 ;;
  esac
}

# Locate the evaluator_contract.py helper across orchestrator and run-plan callers.
ralph_evaluator_resolve_py() {
  local candidate=""
  local dir
  for dir in "${RALPH_ACTIVE_DIR:-}" "${RALPH_DIR:-}" "${SCRIPT_DIR:-}"; do
    [[ -n "$dir" ]] || continue
    if [[ -f "$dir/python/evaluator_contract.py" ]]; then
      candidate="$dir/python/evaluator_contract.py"
      break
    fi
  done
  if [[ -z "$candidate" ]]; then
    return 1
  fi
  printf '%s\n' "$candidate"
}

# ralph_evaluator_parse_status <artifact> [schema_abs]
# Validates the evaluator JSON contract and prints the status (approved|changes-required).
# Returns non-zero (and prints an error to stderr) when the contract is invalid.
ralph_evaluator_parse_status() {
  local artifact="$1"
  local schema="${2:-}"
  local py
  if ! py="$(ralph_evaluator_resolve_py)"; then
    echo "evaluator contract helper not found under Ralph python helpers" >&2
    return 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required to parse the evaluator JSON contract" >&2
    return 1
  fi
  python3 "$py" status --artifact "$artifact" --schema "$schema"
}

# ralph_evaluator_render_feedback_block <artifact> <source_stage> <iteration> <artifact_rel> [schema_abs]
# Prints a delimited, byte-preserving Markdown feedback block for changes-required loopback.
ralph_evaluator_render_feedback_block() {
  local artifact="$1"
  local source_stage="$2"
  local iteration="$3"
  local artifact_rel="$4"
  local schema="${5:-}"
  local py
  if ! py="$(ralph_evaluator_resolve_py)"; then
    echo "evaluator contract helper not found under Ralph python helpers" >&2
    return 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required to render evaluator feedback" >&2
    return 1
  fi
  python3 "$py" feedback-block \
    --artifact "$artifact" \
    --schema "$schema" \
    --source-stage "$source_stage" \
    --iteration "$iteration" \
    --artifact-path "$artifact_rel"
}

# ralph_evaluator_inject_feedback_into_plan <plan_file> <artifact_abs> <source_stage> <iteration> <artifact_rel> [schema_abs]
# Renders the verbatim feedback block and injects it into the looped-back stage's plan.
# Any prior evaluator feedback block is replaced so only the latest feedback is present.
# Returns 0 on success, 1 on failure.
ralph_evaluator_inject_feedback_into_plan() {
  local plan_file="$1"
  local artifact_abs="$2"
  local source_stage="$3"
  local iteration="$4"
  local artifact_rel="$5"
  local schema="${6:-}"

  if [[ ! -f "$plan_file" ]]; then
    echo "evaluator feedback injection: plan file not found: $plan_file" >&2
    return 1
  fi

  local block
  if ! block="$(ralph_evaluator_render_feedback_block "$artifact_abs" "$source_stage" "$iteration" "$artifact_rel" "$schema")"; then
    return 1
  fi

  local tmp
  tmp="$plan_file.evalfb.$$"
  # Strip any existing evaluator feedback block (START..END inclusive).
  awk '
    /<!-- RALPH_EVALUATOR_FEEDBACK: START -->/ { skip = 1 }
    skip != 1 { print }
    /<!-- RALPH_EVALUATOR_FEEDBACK: END -->/ { skip = 0 }
  ' "$plan_file" > "$tmp" || { rm -f "$tmp"; return 1; }

  {
    printf '\n'
    printf '%s' "$block"
  } >> "$tmp"

  mv "$tmp" "$plan_file"
  return 0
}

# ralph_extract_review_status_with_schema <artifact> [schema_abs]
# When a non-empty schema is supplied and the JSON contract gate is enabled, parse
# only the validated JSON contract (no markdown fallback for that artifact).
# Otherwise fall back to the legacy REVIEW_STATUS markdown parser.
# Rollout gate for independent rubric grader stages.
# Ralph/hybrid mode enables it unless RALPH_RUBRIC_GRADER=0.
# Native/no mode leaves it disabled unless RALPH_RUBRIC_GRADER=1.
ralph_rubric_grader_enabled() {
  local gate="${RALPH_RUBRIC_GRADER:-}"
  if [[ -n "$gate" ]]; then
    case "$gate" in
      0) return 1 ;;
      1) return 0 ;;
      *)
        if declare -F ralph_warn >/dev/null 2>&1; then
          ralph_warn "RALPH_RUBRIC_GRADER: invalid value '$gate' (use 0 or 1)"
        else
          echo "RALPH_RUBRIC_GRADER: invalid value '$gate' (use 0 or 1)" >&2
        fi
        return 2
        ;;
    esac
  fi
  case "${RALPH_MODE:-no}" in
    ralph|hybrid) return 0 ;;
    *) return 1 ;;
  esac
}

ralph_schema_is_rubric_result() {
  local schema="${1:-}"
  [[ "$schema" == *"rubric-result.schema.json" ]]
}

ralph_rubric_contract_resolve_py() {
  local candidate="" dir
  for dir in "${RALPH_ACTIVE_DIR:-}" "${RALPH_DIR:-}" "${SCRIPT_DIR:-}"; do
    [[ -n "$dir" ]] || continue
    if [[ -f "$dir/python/rubric_contract.py" ]]; then
      candidate="$dir/python/rubric_contract.py"
      break
    fi
  done
  if [[ -z "$candidate" ]]; then
    return 1
  fi
  printf '%s\n' "$candidate"
}

ralph_rubric_parse_status() {
  local artifact="$1"
  local schema="${2:-}"
  local py
  if ! py="$(ralph_rubric_contract_resolve_py)"; then
    echo "rubric contract helper not found under Ralph python helpers" >&2
    return 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required to parse the rubric result contract" >&2
    return 1
  fi
  python3 "$py" status --artifact "$artifact" --schema "$schema"
}

ralph_rubric_render_feedback_block() {
  local artifact="$1"
  local source_stage="$2"
  local iteration="$3"
  local artifact_rel="$4"
  local schema="${5:-}"
  local py
  if ! py="$(ralph_rubric_contract_resolve_py)"; then
    echo "rubric contract helper not found under Ralph python helpers" >&2
    return 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required to render rubric feedback" >&2
    return 1
  fi
  python3 "$py" feedback-block \
    --artifact "$artifact" \
    --schema "$schema" \
    --source-stage "$source_stage" \
    --iteration "$iteration" \
    --artifact-path "$artifact_rel"
}

ralph_rubric_inject_feedback_into_plan() {
  local plan_file="$1"
  local artifact_abs="$2"
  local source_stage="$3"
  local iteration="$4"
  local artifact_rel="$5"
  local schema="${6:-}"

  if [[ ! -f "$plan_file" ]]; then
    echo "rubric feedback injection: plan file not found: $plan_file" >&2
    return 1
  fi

  local block
  if ! block="$(ralph_rubric_render_feedback_block "$artifact_abs" "$source_stage" "$iteration" "$artifact_rel" "$schema")"; then
    return 1
  fi

  local tmp="$plan_file.rubricfb.$$"
  awk '
    /<!-- RALPH_EVALUATOR_FEEDBACK: START -->/ { skip = 1 }
    skip != 1 { print }
    /<!-- RALPH_EVALUATOR_FEEDBACK: END -->/ { skip = 0 }
  ' "$plan_file" > "$tmp" || { rm -f "$tmp"; return 1; }
  {
    printf '\n'
    printf '%s' "$block"
  } >> "$tmp"
  mv "$tmp" "$plan_file"
  return 0
}

ralph_extract_review_status_with_schema() {
  local artifact="$1"
  local schema="${2:-}"
  if [[ -n "$schema" ]] && ralph_schema_is_rubric_result "$schema" && ralph_rubric_grader_enabled 2>/dev/null; then
    ralph_rubric_parse_status "$artifact" "$schema"
    return $?
  fi
  if [[ -n "$schema" ]] && ralph_evaluator_json_contract_enabled; then
    ralph_evaluator_parse_status "$artifact" "$schema"
    return $?
  fi
  ralph_extract_review_status "$artifact"
}

ralph_extract_review_status() {
  local path="$1"

  if [[ ! -f "$path" ]]; then
    printf 'missing_file\n'
    return 1
  fi

  local start_marker="<!-- REVIEW_STATUS: START -->"
  local end_marker="<!-- REVIEW_STATUS: END -->"
  local status_line=""

  status_line=$(sed -n "/$start_marker/,/$end_marker/p" "$path" | grep "^status:" || true)

  if [[ -z "$status_line" ]]; then
    printf 'missing_status\n'
    return 1
  fi

  local status_value
  status_value=$(printf '%s' "$status_line" | sed 's/^status:[[:space:]]*//' | tr -d ' ')

  case "$status_value" in
    approved|changes-required)
      printf '%s\n' "$status_value"
      return 0
      ;;
    *)
      printf 'invalid\n'
      return 1
      ;;
  esac
}
