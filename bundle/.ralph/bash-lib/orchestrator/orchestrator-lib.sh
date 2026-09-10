#!/usr/bin/env bash

if [[ -n "${RALPH_ORCHESTRATOR_LIB_LOADED:-}" ]]; then
  return
fi
RALPH_ORCHESTRATOR_LIB_LOADED=1

if ! declare -F ralph_normalize_runtime_name >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/runtime-normalize.sh"
fi

# Public interface:
#   trim, parse_artifact_csv -- string and CSV parsing for artifact lists.
#   expand_artifact_tokens -- substitute {{ARTIFACT_NS}}, {{PLAN_KEY}}, {{STAGE_ID}} in paths.
#   artifact_paths_append_unique -- dedupe resolved paths in EXPECTED_ARTIFACT_PATHS.
#   orchestrator_normalize_runtime, orchestrator_validate_runtime -- runtime id validation.
#   orchestrator_validate_stage_agent_plan, orchestrator_stage_plan_abs -- stage field checks and paths.
# Stage required outputs are collected only via orch_stage_collect_expected_artifacts
# (orchestrator-verify.sh); profile output_artifacts are never merged.

_orchestrator_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F expand_artifact_tokens >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "$_orchestrator_lib_dir/../artifacts.sh"
fi
unset _orchestrator_lib_dir

orchestrator_normalize_runtime() {
  local runtime="${1:-}"
  runtime="$(ralph_normalize_runtime_name "$runtime")"
  if [[ -z "$runtime" ]]; then
    printf 'cursor'
  else
    printf '%s' "$runtime"
  fi
}

orchestrator_validate_runtime() {
  local runtime
  runtime="$(orchestrator_normalize_runtime "$1")"
  case "$runtime" in
    cursor|claude|codex|opencode|antigravity)
      printf '%s' "$runtime"
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

orchestrator_validate_stage_agent_plan() {
  local agent="$1"
  local plan="$2"
  # Role is optional on orchestration stages; plan remains required.
  [[ -n "$plan" ]]
}

orchestrator_stage_plan_abs() {
  local plan_rel="$1"
  local workspace="${2:-$WORKSPACE}"
  if [[ "$plan_rel" == /* ]]; then
    printf '%s' "$plan_rel"
  else
    printf '%s/%s' "$workspace" "$plan_rel"
  fi
}
