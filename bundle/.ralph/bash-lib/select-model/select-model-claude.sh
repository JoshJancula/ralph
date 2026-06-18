#!/usr/bin/env bash

_SELECT_MODEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_INTERACTIVE_LIB="${RALPH_SHARED_RALPH_DIR:-$_SELECT_MODEL_DIR/../../.ralph}/bash-lib/interactive-select.sh"
if [[ -r "$_INTERACTIVE_LIB" ]]; then
  source "$_INTERACTIVE_LIB"
fi

_select_model_common="${_SELECT_MODEL_DIR}/select-model-common.sh"
if [[ -r "$_select_model_common" ]]; then
  source "$_select_model_common"
fi

_claude_select_model_interactive() {
  _select_model_saved_runtime_interactive \
    "claude" \
    "--- Claude (.claude/agents) ---" \
    "Pick a model for the Claude Code CLI (saved models when available, else enter one)." \
    "Model for Claude Code agent" \
    "${C_Y:-}${C_BOLD:-}Enter custom model id${C_RST:-}: "
}

select_model_claude() {
  if [[ "${1:-}" == "--interactive" ]]; then
    _claude_select_model_interactive
    return
  fi
  if [[ "${1:-}" == "--no-interactive" ]]; then
    shift
    echo "${CLAUDE_PLAN_MODEL:-${CURSOR_PLAN_MODEL:-${1:-}}}"
    return
  fi
  if [[ "${1:-}" == "--batch" ]]; then
    shift
    _select_model_batch_dispatch claude CLAUDE_PLAN_MODEL "$@"
    return
  fi
  local em="${CLAUDE_PLAN_MODEL:-${CURSOR_PLAN_MODEL:-}}"
  select_model_claude --batch 0 "$em" ""
}

export -f select_model_claude _claude_select_model_interactive 2>/dev/null || true
