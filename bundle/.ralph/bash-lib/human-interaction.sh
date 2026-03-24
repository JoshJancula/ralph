#!/usr/bin/env bash

if [[ -n "${RALPH_HUMAN_INTERACTION_HELPERS_LOADED:-}" ]]; then
  return
fi
RALPH_HUMAN_INTERACTION_HELPERS_LOADED=1

# Public interface:
#   ralph_optional_log -- forwards to orchestrator `log` when defined.
#   ralph_human_ack_tool_path -- resolves .ralph/orchestrator.sh for --human-ack.
#   ralph_forward_human_question_to_orchestrator -- invokes orchestrator with a question file.
#   ralph_record_interactive_reply, ralph_interactive_history_block -- TTY Q&A capture for prompts.
#   ralph_persist_human_exchange -- append exchange to human-replies.md when configured.

# Holds the human exchanges captured during interactive runs.
TTY_HUMAN_HISTORY=""

ralph_optional_log() {
  if [[ "$(type -t log)" == "function" ]]; then
    log "$@"
  fi
}

ralph_human_ack_tool_path() {
  if [[ -n "${RALPH_HUMAN_ACK_TOOL:-}" ]]; then
    printf '%s' "$RALPH_HUMAN_ACK_TOOL"
    return 0
  fi
  if [[ -z "${RALPH_ORCH_FILE:-}" ]]; then
    return 1
  fi
  local ws="${WORKSPACE:-$(pwd)}"
  local candidate="$ws/.ralph/orchestrator.sh"
  if [[ -f "$candidate" ]]; then
    printf '%s' "$candidate"
    return 0
  fi
  return 1
}

ralph_forward_human_question_to_orchestrator() {
  local question_file="$1"
  local plan_path="${2:-${PLAN_PATH:-}}"
  if [[ -z "$question_file" || ! -f "$question_file" ]]; then
    return 1
  fi
  local tool
  tool="$(ralph_human_ack_tool_path)" || return 1
  local args=(--human-ack --human-ack-question-file "$question_file")
  [[ -n "$plan_path" ]] && args+=(--human-ack-plan "$plan_path")
  [[ -n "${WORKSPACE:-}" ]] && args+=(--human-ack-workspace "$WORKSPACE")
  local runner_env=()
  [[ -n "${RALPH_ORCH_FILE:-}" ]] && runner_env+=("RALPH_ORCH_FILE=${RALPH_ORCH_FILE}")
  [[ -n "${RALPH_PLAN_KEY:-}" ]] && runner_env+=("RALPH_PLAN_KEY=${RALPH_PLAN_KEY}")
  [[ -n "${RALPH_ARTIFACT_NS:-}" ]] && runner_env+=("RALPH_ARTIFACT_NS=${RALPH_ARTIFACT_NS}")
  local status
  set +e
  if ((${#runner_env[@]} > 0)); then
    if [[ -n "${LOG_FILE:-}" ]]; then
      env "${runner_env[@]}" bash "$tool" "${args[@]}" >>"$LOG_FILE" 2>&1
    else
      env "${runner_env[@]}" bash "$tool" "${args[@]}"
    fi
  else
    if [[ -n "${LOG_FILE:-}" ]]; then
      bash "$tool" "${args[@]}" >>"$LOG_FILE" 2>&1
    else
      bash "$tool" "${args[@]}"
    fi
  fi
  status=$?
  set -e
  if [[ $status -eq 0 ]]; then
    ralph_optional_log "human-ack bridge: question forwarded via $tool"
  else
    ralph_optional_log "human-ack bridge: tool $tool failed with exit $status"
  fi
  return $status
}

ralph_record_interactive_reply() {
  local question="$1"
  local answer="$2"
  local timestamp
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  TTY_HUMAN_HISTORY+=$'\n### '"$timestamp"$'\n**Agent asked:**\n'"$question"$'\n**Operator answered:**\n'"$answer"$'\n'
}

ralph_interactive_history_block() {
  if [[ -z "${TTY_HUMAN_HISTORY:-}" ]]; then
    return
  fi
  printf '## Human operator answers (interactive run)\n%s\n' "$TTY_HUMAN_HISTORY"
}

ralph_persist_human_exchange() {
  local question="$1"
  local answer="$2"
  local dir="${HUMAN_ARTIFACTS_DIR:-}"
  if [[ -z "$dir" ]]; then
    return 1
  fi
  mkdir -p "$dir"
  local timestamp
  timestamp="$(date '+%Y%m%d%H%M%S')"
  local artifact_file="$dir/human-exchange-${timestamp}.md"
  {
    echo "# Human exchange"
    echo ""
    echo "## Question"
    echo "$question"
    echo ""
    echo "## Answer"
    echo "$answer"
  } >"$artifact_file"
  printf '%s\n' "$artifact_file"
}
