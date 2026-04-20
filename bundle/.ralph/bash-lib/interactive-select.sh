#!/usr/bin/env bash

if [[ -n "${RALPH_INTERACTIVE_SELECT_LIB_LOADED:-}" ]]; then
  return
fi
RALPH_INTERACTIVE_SELECT_LIB_LOADED=1

# Module-level variable to track if fzf hint has been shown
_RALPH_FZF_HINT_SHOWN=0

# Public interface:
#   ralph_menu_select -- numbered menu with optional fzf; prints chosen item (see --help in implementation).
# Internal: _ralph_menu_read_tty, _ralph_menu_numeric_prompt, _ralph_menu_run_fzf.

# Internal: print fzf installation hint once per process
_ralph_menu_print_fzf_hint() {
  if [[ "${RALPH_SKIP_FZF_HINT:-}" == "1" ]]; then
    return 0
  fi
  if [[ "$_RALPH_FZF_HINT_SHOWN" -eq 1 ]]; then
    return 0
  fi
  _RALPH_FZF_HINT_SHOWN=1
  if [[ -t 2 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    echo -e "\033[2mtip: install fzf for arrow-key menus (brew install fzf / apt install fzf). set RALPH_SKIP_FZF_HINT=1 to silence.\033[0m" >&2
  else
    echo "tip: install fzf for arrow-key menus (brew install fzf / apt install fzf). set RALPH_SKIP_FZF_HINT=1 to silence." >&2
  fi
}

_ralph_menu_read_tty() {
  local var_name="$1"
  local prompt="$2"
  if [[ -r /dev/tty ]]; then
    read -r -p "$prompt" "$var_name" </dev/tty 2>/dev/null
  else
    read -r -p "$prompt" "$var_name"
  fi
}

_ralph_menu_numeric_prompt() {
  local prompt="$1"
  local default_index="$2"
  shift 2
  local choices=("$@")
  local idx
  local input
  while true; do
    printf '\n' >&2
    idx=1
    for choice in "${choices[@]}"; do
      printf '  %s%2d)%s %s\n' "${C_G:-}" "$idx" "${C_RST:-}" "$choice" >&2
      idx=$((idx + 1))
    done
    local read_prompt=""
    if (( default_index >= 1 && default_index <= ${#choices[@]} )); then
      read_prompt="${C_Y:-}${C_BOLD:-}${prompt}${C_RST:-} ${C_DIM:-}[default ${default_index}]${C_RST:-}: "
    else
      read_prompt="${C_Y:-}${C_BOLD:-}${prompt}${C_RST:-}: "
    fi
    _ralph_menu_read_tty input "$read_prompt"
    if [[ -z "$input" ]]; then
      input="$default_index"
    fi
    if [[ "$input" =~ ^[0-9]+$ ]]; then
      if (( input >= 1 && input <= ${#choices[@]} )); then
        printf '%s' "${choices[$((input - 1))]}"
        return 0
      fi
      echo -e "${C_R:-}Invalid selection.${C_RST:-}" >&2
      continue
    fi
    # Validate literal input against choices
    local valid_choice=0
    for choice in "${choices[@]}"; do
      if [[ "$choice" == "$input" ]]; then
        valid_choice=1
        break
      fi
    done
    if (( valid_choice == 1 )); then
      printf '%s' "$input"
      return 0
    fi
    echo -e "${C_R:-}unknown runtime \"${input}\"; valid: ${choices[*]}${C_RST:-}" >&2
  done
}

_ralph_menu_run_fzf() {
  local prompt="$1"
  shift
  local choices=("$@")
  if [[ -n "${RALPH_NO_FZF:-}" ]]; then
    return 1
  fi
  if ! command -v fzf >/dev/null 2>&1; then
    return 1
  fi
  local selected
  selected="$(printf '%s\n' "${choices[@]}" | fzf --no-sort --height=20 --prompt="$prompt: " --header="Use arrows to move, Enter to select" </dev/tty 2>/dev/null)"
  if [[ -n "$selected" ]]; then
    printf '%s' "$selected"
    return 0
  fi
  return 1
}


ralph_menu_select() {
  local prompt="Select an option"
  local default_index=1
  local non_interactive=0
  local choices=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --prompt)
        prompt="$2"
        shift 2
        ;;
      --default)
        default_index="$2"
        shift 2
        ;;
      --non-interactive)
        non_interactive=1
        shift
        ;;
      --)
        shift
        break
        ;;
      *)
        break
        ;;
    esac
  done

  choices=("$@")
  if (( ${#choices[@]} == 0 )); then
    return 1
  fi

  local selection
  if (( non_interactive == 0 )) && [[ -z "${RALPH_FORCE_NUMERIC_MENU:-}" ]] && [[ -r /dev/tty ]]; then
    selection="$(_ralph_menu_run_fzf "$prompt" "${choices[@]}")" || selection=""
  fi

  if [[ -z "$selection" ]]; then
    # Numeric fallback: show fzf hint once
    _ralph_menu_print_fzf_hint
    selection="$(_ralph_menu_numeric_prompt "$prompt" "$default_index" "${choices[@]}")"
  fi

  if [[ -z "$selection" ]]; then
    return 1
  fi

  printf '%s' "$selection"
}
