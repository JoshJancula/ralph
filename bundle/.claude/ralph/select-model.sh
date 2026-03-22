#!/usr/bin/env bash
_SELECT_MODEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_INTERACTIVE_LIB="$_SELECT_MODEL_DIR/../../.ralph/bash-lib/interactive-select.sh"
if [[ -r "$_INTERACTIVE_LIB" ]]; then
  # shellcheck source=/dev/null
  source "$_INTERACTIVE_LIB"
fi
# Claude runtime: shared model selection for new-agent and run-plan.
# Source: source "$SCRIPT_DIR/select-model.sh"

_claude_read_rp() {
  local prompt="$1"
  local _d="$2"
  if [[ -r /dev/tty ]]; then
    read -rp "$prompt" "$_d" </dev/tty 2>/dev/null || return 1
  else
    read -rp "$prompt" "$_d" || return 1
  fi
}

_claude_select_model_interactive() {
  echo "" >&2
  echo -e "${C_C:-}${C_BOLD:-}--- Claude (.claude/agents) ---${C_RST:-}" >&2
  echo -e "${C_DIM:-}Pick a model for the Claude Code CLI.${C_RST:-}" >&2
  local choices=("claude-haiku-4-5" "claude-sonnet-4" "claude-sonnet-4-5")
  local placeholder="Enter custom model id"
  local selection custom_model
  while true; do
    selection="$(ralph_menu_select --prompt "Model for Claude Code agent" --default 2 -- "${choices[@]}" "$placeholder")"
    if [[ -z "$selection" ]]; then
      echo ""
      return 0
    fi
    if [[ "$selection" == "$placeholder" ]]; then
      if ! _claude_read_rp "${C_Y:-}${C_BOLD:-}Enter custom model id${C_RST:-}: " custom_model; then
        echo ""
        return 0
      fi
      if [[ -z "$custom_model" ]]; then
        echo -e "${C_R:-}Model cannot be empty.${C_RST:-}" >&2
        continue
      fi
      echo "$custom_model"
      return 0
    fi
    echo "$selection"
    return 0
  done
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
    local ni="$1" env_m="$2" cfg="$3"
    local resolved="${env_m}"
    [[ -z "$resolved" && -n "${CURSOR_PLAN_MODEL:-}" ]] && resolved="${CURSOR_PLAN_MODEL}"
    if [[ "$ni" == "1" ]]; then
      echo "${resolved:-$cfg}"
      return
    fi
    [[ -n "$resolved" ]] && { echo "$resolved"; return; }
    [[ ! -r /dev/tty ]] && { echo "$cfg"; return; }
    _claude_select_model_interactive
    return
  fi
  local em="${CLAUDE_PLAN_MODEL:-${CURSOR_PLAN_MODEL:-}}"
  select_model_claude --batch 0 "$em" ""
}

export -f select_model_claude _claude_select_model_interactive _claude_read_rp 2>/dev/null || true
