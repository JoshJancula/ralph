#!/usr/bin/env bash
# Cursor runtime: shared model selection for new-agent and run-plan.
# Source: source "$SCRIPT_DIR/select-model.sh"
#
#   select_model_cursor --interactive
#     Always prompt (new-agent wizard).
#
#   select_model_cursor --batch <non_interactive_0_or_1> <CURSOR_PLAN_MODEL> <config_model>
#     No prompt if non-interactive, or env model set, or no TTY; else same menu as --interactive.
#
#   select_model_cursor --no-interactive [fallback]
#     Print CURSOR_PLAN_MODEL or fallback, never prompt.
#
# Stdout: one model id. Menus on stderr. Uses CURSOR_CLI when set.

_cursor_read_rp() {
  local prompt="$1"
  local _d="$2"
  if [[ -r /dev/tty ]]; then
    read -rp "$prompt" "$_d" </dev/tty 2>/dev/null || return 1
  else
    read -rp "$prompt" "$_d" || return 1
  fi
}

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
  echo "--- Cursor (.cursor/agents) ---" >&2
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

  local custom_index=$(( ${#models[@]} + 1 ))
  echo "Model for Cursor agent:" >&2
  for ((i = 0; i < ${#models[@]}; i++)); do
    if [[ $((i + 1)) -eq "$default_index" ]]; then
      echo "  $((i + 1))) ${models[$i]} (default)" >&2
    else
      echo "  $((i + 1))) ${models[$i]}" >&2
    fi
  done
  echo "  $custom_index) Enter custom model" >&2

  local choice custom_model
  while true; do
    if ! _cursor_read_rp "Select model [$default_index]: " choice; then
      echo ""; return 0
    fi
    choice="${choice:-$default_index}"
    if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#models[@]})); then
      echo "${models[$((choice - 1))]}"; return 0
    fi
    if [[ "$choice" == "$custom_index" ]]; then
      if ! _cursor_read_rp "Enter custom model name: " custom_model; then
        echo ""; return 0
      fi
      if [[ -z "$custom_model" ]]; then
        echo "Custom model cannot be empty." >&2
      else
        echo "$custom_model"; return 0
      fi
    else
      echo "Invalid selection." >&2
    fi
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
    local ni="$1" env_m="$2" cfg="$3"
    if [[ "$ni" == "1" ]]; then
      echo "${env_m:-$cfg}"
      return
    fi
    [[ -n "$env_m" ]] && { echo "$env_m"; return; }
    [[ ! -r /dev/tty ]] && { echo "$cfg"; return; }
    _cursor_select_model_interactive
    return
  fi
  select_model_cursor --batch 0 "${CURSOR_PLAN_MODEL:-}" ""
}

export -f select_model_cursor _cursor_select_model_interactive _cursor_list_models _cursor_detect_cli _cursor_read_rp 2>/dev/null || true
