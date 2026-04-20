#!/usr/bin/env bash

if [[ -n "${RALPH_MENU_SELECT_LOADED:-}" ]]; then
  return
fi
RALPH_MENU_SELECT_LOADED=1

# Public interface:
#   ralph_menu_select -- lightweight numbered picker (no fzf); see inline Args/Returns below.

# Interactive numbered pick from argv (after --). Prints the chosen word on stdout.
# Options: --prompt TEXT, --default N (1-based). Reads from /dev/tty.
# Returns 0 on success; 1 on empty/invalid input (no stdout).
ralph_menu_select() {
  local prompt="Choose"
  local default_idx=1
  local -a choices=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --prompt)
        prompt="$2"
        shift 2
        ;;
      --default)
        default_idx="$2"
        shift 2
        ;;
      --)
        shift
        choices=("$@")
        break
        ;;
      *)
        echo "ralph_menu_select: unexpected argument: $1 (expected -- before choices)" >&2
        return 1
        ;;
    esac
  done

  if [[ ${#choices[@]} -eq 0 ]]; then
    return 1
  fi

  if ! [[ "$default_idx" =~ ^[0-9]+$ ]] || [[ "$default_idx" -lt 1 ]] || [[ "$default_idx" -gt ${#choices[@]} ]]; then
    default_idx=1
  fi

  local raw idx=1
  printf '\n' >&2
  for choice in "${choices[@]}"; do
    printf '  %s%2d)%s %s\n' "${C_G:-}" "$idx" "${C_RST:-}" "$choice" >&2
    idx=$((idx + 1))
  done
  printf '%s' "${C_Y:-}${C_BOLD:-}${prompt}${C_RST:-} ${C_DIM:-}[${default_idx}]${C_RST:-}: " >&2
  if [[ -p /dev/stdin ]]; then
    read -r raw || raw=""
  elif [[ -t 0 && -r /dev/tty ]]; then
    read -r raw </dev/tty 2>/dev/null || raw=""
  else
    read -r raw || raw=""
  fi
  raw="${raw:-$default_idx}"

  if ! [[ "$raw" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  if [[ "$raw" -lt 1 || "$raw" -gt ${#choices[@]} ]]; then
    return 1
  fi

  printf '%s' "${choices[$((raw - 1))]}"
  return 0
}
