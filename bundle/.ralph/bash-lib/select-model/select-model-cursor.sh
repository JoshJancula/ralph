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

_cursor_detect_cli() {
  if [[ -n "${RALPH_SM_CURSOR_CLI:-}" ]]; then
    return 0
  fi
  if [[ -n "${CURSOR_CLI:-}" ]]; then
    RALPH_SM_CURSOR_CLI="$CURSOR_CLI"
    return 0
  fi
  if command -v cursor-agent >/dev/null 2>&1; then
    RALPH_SM_CURSOR_CLI="cursor-agent"
  elif command -v agent >/dev/null 2>&1; then
    RALPH_SM_CURSOR_CLI="agent"
  else
    RALPH_SM_CURSOR_CLI=""
  fi
}

_cursor_list_models() {
  _cursor_detect_cli
  if [[ -z "$RALPH_SM_CURSOR_CLI" ]]; then
    return 0
  fi
  (
    set +e
    set +o pipefail
    "$RALPH_SM_CURSOR_CLI" --list-models 2>/dev/null \
      | sed -n '1,/^Tip:/p' \
      | sed '/^Tip:/d' \
      | grep -E ' - ' 2>/dev/null \
      | sed -E 's/[[:space:]]+-[[:space:]]+.*$//'
  ) 2>/dev/null || true
}

_cursor_select_model_interactive() {
  echo "" >&2
  echo -e "${C_C:-}${C_BOLD:-}--- Cursor (.cursor/agents) ---${C_RST:-}" >&2
  echo -e "${C_DIM:-}Pick a model for the Cursor CLI.${C_RST:-}" >&2
  local models=() model
  _cursor_detect_cli
  while IFS= read -r model || [[ -n "$model" ]]; do
    [[ -n "$model" ]] && models+=("$model")
  done < <(_cursor_list_models)

  if [[ ${#models[@]} -eq 0 ]]; then
    models=("auto" "gpt-5.1-codex-mini" "gpt-5.1-turbo" "gpt-5" "gpt-4o")
  fi

  local default_index=1 i
  for ((i = 0; i < ${#models[@]}; i++)); do
    if [[ "${models[$i]}" == "auto" ]]; then
      default_index=$((i + 1))
      break
    fi
  done

  local placeholder="Enter custom model"
  local custom_model selection
  while true; do
    selection="$(ralph_menu_select --prompt "Model for Cursor agent" --default "$default_index" -- "${models[@]}" "$placeholder")"
    if [[ -z "$selection" ]]; then
      echo ""
      return 0
    fi
    if [[ "$selection" == "$placeholder" ]]; then
      if ! _select_model_read_rp "${C_Y:-}${C_BOLD:-}Enter custom model name${C_RST:-}: " custom_model; then
        echo ""
        return 0
      fi
      if [[ -z "$custom_model" ]]; then
        echo -e "${C_R:-}Custom model cannot be empty.${C_RST:-}" >&2
        continue
      fi
      echo "$custom_model"
      return 0
    fi
    echo "$selection"
    return 0
  done
}

select_model_cursor() {
  if [[ "${1:-}" == "--interactive" ]]; then
    _cursor_select_model_interactive
    return
  fi
  if [[ "${1:-}" == "--no-interactive" ]]; then
    shift
    echo "${CURSOR_PLAN_MODEL:-${1:-}}"
    return
  fi
  if [[ "${1:-}" == "--batch" ]]; then
    shift
    _select_model_batch_dispatch cursor CURSOR_PLAN_MODEL "$@"
    return
  fi
  select_model_cursor --batch 0 "${CURSOR_PLAN_MODEL:-}" ""
}

export -f select_model_cursor _cursor_select_model_interactive _cursor_list_models _cursor_detect_cli 2>/dev/null || true
