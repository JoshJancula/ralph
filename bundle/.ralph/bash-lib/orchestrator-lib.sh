#!/usr/bin/env bash

if [[ -n "${RALPH_ORCHESTRATOR_LIB_LOADED:-}" ]]; then
  return
fi
RALPH_ORCHESTRATOR_LIB_LOADED=1

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

parse_artifact_csv() {
  EXPECTED_ARTIFACT_PATHS=()
  local csv="$1"
  [[ -z "$csv" ]] && return 0
  local IFS=,
  local piece
  for piece in $csv; do
    piece="$(trim "$piece")"
    [[ -n "$piece" ]] && EXPECTED_ARTIFACT_PATHS+=("$piece")
  done
}

expand_artifact_tokens() {
  local p="$1"
  local ns="${RALPH_ARTIFACT_NS:-$ORCH_BASENAME}"
  local stage_id="${RALPH_STAGE_ID:-}"
  p="${p//\{\{ARTIFACT_NS\}\}/$ns}"
  p="${p//\{\{PLAN_KEY\}\}/$ns}"
  p="${p//\{\{STAGE_ID\}\}/$stage_id}"
  printf '%s' "$p"
}

artifact_paths_append_unique() {
  local new
  new="$(expand_artifact_tokens "$1")"
  local ex
  if ((${#EXPECTED_ARTIFACT_PATHS[@]:-0} > 0)); then
    for ex in "${EXPECTED_ARTIFACT_PATHS[@]}"; do
      [[ "$ex" == "$new" ]] && return 0
    done
  fi
  EXPECTED_ARTIFACT_PATHS+=("$new")
}

merge_required_artifacts_from_agent() {
  local agent_id="$1"
  local runtime="$2"
  local agents_root
  if [[ "$runtime" == "cursor" ]]; then
    agents_root="$WORKSPACE/.cursor/agents"
  elif [[ "$runtime" == "codex" ]]; then
    agents_root="$WORKSPACE/.codex/agents"
  else
    agents_root="$WORKSPACE/.claude/agents"
  fi
  [[ -z "$AGENT_CONFIG_TOOL_SH" ]] && return 0
  [[ ! -f "$agents_root/$agent_id/config.json" ]] && return 0
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    artifact_paths_append_unique "$line"
  done < <(bash "$AGENT_CONFIG_TOOL_SH" required-artifacts "$agents_root" "$agent_id" 2>/dev/null) || true
}

orchestrator_normalize_runtime() {
  local runtime="${1:-}"
  runtime="$(printf '%s' "$runtime" | tr '[:upper:]' '[:lower:]')"
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
    cursor|claude|codex)
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
  [[ -n "$agent" && -n "$plan" ]]
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
