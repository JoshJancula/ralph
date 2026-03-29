#!/usr/bin/env bash
_SELECT_MODEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_INTERACTIVE_LIB="$_SELECT_MODEL_DIR/../../.ralph/bash-lib/interactive-select.sh"
if [[ -r "$_INTERACTIVE_LIB" ]]; then
  # shellcheck source=/dev/null
  source "$_INTERACTIVE_LIB"
fi
# Opencode runtime: shared model selection for new-agent and run-plan.

_opencode_read_rp() {
  local prompt="$1"
  local _d="$2"
  if [[ -r /dev/tty ]]; then
    read -rp "$prompt" "$_d" </dev/tty 2>/dev/null || return 1
  else
    read -rp "$prompt" "$_d" || return 1
  fi
}

_opencode_list_models_from_cli() {
  (
    set +e
    set +o pipefail
    command -v opencode >/dev/null 2>&1 || exit 0
    opencode models 2>/dev/null | grep -E '^[a-zA-Z0-9/._:-]+$' | sort -u
  ) 2>/dev/null || true
}

_opencode_select_model_interactive() {
  echo "" >&2
  echo -e "${C_C:-}${C_BOLD:-}--- Opencode (.opencode/agents) ---${C_RST:-}" >&2
  echo -e "${C_DIM:-}Pick a model for the Opencode CLI (API list when available, else defaults below).${C_RST:-}" >&2
  local models=() m
  models+=("auto")
  while IFS= read -r m || [[ -n "$m" ]]; do
    [[ -z "$m" || "$m" == "auto" ]] && continue
    models+=("$m")
  done < <(_opencode_list_models_from_cli)

  if [[ ${#models[@]} -le 1 ]]; then
    models=("auto" "anthropic/claude-sonnet-4-5" "anthropic/claude-haiku-4-5" "openai/gpt-4o" "google/gemini-2.0-flash")
  fi

  local default_index=1 i
  for ((i = 0; i < ${#models[@]}; i++)); do
    if [[ "${models[$i]}" == "auto" ]]; then
      default_index=$((i + 1))
      break
    fi
  done

  local placeholder="Enter custom model id"
  local selection custom_model
  while true; do
    selection="$(ralph_menu_select --prompt "Model for Opencode CLI agent (from CLI when available, else defaults)" --default "$default_index" -- "${models[@]}" "$placeholder")"
    if [[ -z "$selection" ]]; then
      echo ""
      return 0
    fi
    if [[ "$selection" == "$placeholder" ]]; then
      if ! _opencode_read_rp "Enter custom model id: " custom_model; then
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

select_model_opencode() {
  if [[ "${1:-}" == "--interactive" ]]; then
    _opencode_select_model_interactive
    return
  fi
  if [[ "${1:-}" == "--no-interactive" ]]; then
    shift
    echo "${OPENCODE_PLAN_MODEL:-${CURSOR_PLAN_MODEL:-${1:-}}}"
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
    _opencode_select_model_interactive
    return
  fi
  local em="${OPENCODE_PLAN_MODEL:-${CURSOR_PLAN_MODEL:-}}"
  select_model_opencode --batch 0 "$em" ""
}

export -f select_model_opencode _opencode_select_model_interactive _opencode_list_models_from_cli _opencode_read_rp 2>/dev/null || true
