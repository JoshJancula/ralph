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

_codex_select_model_interactive() {
  _select_model_saved_runtime_interactive \
    "codex" \
    "--- Codex (.codex/agents) ---" \
    "Pick a model for the Codex CLI (saved models when available, else enter one)." \
    "Model for Codex CLI agent" \
    "Enter custom model id: "
}

select_model_codex() {
  if [[ "${1:-}" == "--interactive" ]]; then
    _codex_select_model_interactive
    return
  fi
  if [[ "${1:-}" == "--no-interactive" ]]; then
    shift
    echo "${CODEX_PLAN_MODEL:-${CURSOR_PLAN_MODEL:-${1:-}}}"
    return
  fi
  if [[ "${1:-}" == "--batch" ]]; then
    shift
    _select_model_batch_dispatch codex CODEX_PLAN_MODEL "$@"
    return
  fi
  local em="${CODEX_PLAN_MODEL:-${CURSOR_PLAN_MODEL:-}}"
  select_model_codex --batch 0 "$em" ""
}

export -f select_model_codex _codex_select_model_interactive 2>/dev/null || true
