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

# _CLAUDE_DEFAULT_MODELS is defined by select-model-common.sh (sourced above);
# this fallback only covers the case where the common lib was unreadable.
# Catalog must stay exactly: haiku, sonnet, opus, fable (selected value unchanged).
if [[ -z "${_CLAUDE_DEFAULT_MODELS+x}" ]]; then
  _CLAUDE_DEFAULT_MODELS=("haiku" "sonnet" "opus" "fable")
fi
export _CLAUDE_DEFAULT_MODELS

_claude_select_model_interactive() {
  # Passes the Claude alias catalog so saved IDs merge with missing aliases.
  # Defaults-only preselect index 2 => sonnet. Saved-present preselect stays 1.
  _select_model_saved_runtime_interactive \
    "claude" \
    "--- Claude (.claude/agents) ---" \
    "Pick a model for the Claude Code CLI (saved models when available, else defaults)." \
    "Model for Claude Code agent" \
    "${C_Y:-}${C_BOLD:-}Enter custom model id${C_RST:-}: " \
    "Enter custom model id" \
    "_CLAUDE_DEFAULT_MODELS" \
    2
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
