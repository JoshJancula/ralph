#!/usr/bin/env bash
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
  echo "--- Claude (.claude/agents) ---" >&2
  echo "Model for Claude Code agent:" >&2
  echo "  1) claude-haiku-4-5 (lighter / fast)" >&2
  echo "  2) claude-sonnet-4 (default)" >&2
  echo "  3) claude-sonnet-4-5" >&2
  echo "  4) Enter custom model id" >&2
  local choice custom_model
  while true; do
    if ! _claude_read_rp "Select model [2]: " choice; then
      echo ""; return 0
    fi
    choice="${choice:-2}"
    case "$choice" in
      1) echo "claude-haiku-4-5"; return 0 ;;
      2) echo "claude-sonnet-4"; return 0 ;;
      3) echo "claude-sonnet-4-5"; return 0 ;;
      4)
        if ! _claude_read_rp "Enter custom model id: " custom_model; then
          echo ""; return 0
        fi
        if [[ -z "$custom_model" ]]; then
          echo "Model cannot be empty." >&2
        else
          echo "$custom_model"; return 0
        fi
        ;;
      *) echo "Invalid selection." >&2 ;;
    esac
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
