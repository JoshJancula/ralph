#!/usr/bin/env bash
# Unified prompt helpers for interactive input across Ralph CLIs.
# Public: ralph_prompt_text, ralph_prompt_yesno, ralph_prompt_choice, ralph_prompt_list.
# Env vars read: NO_COLOR (from https://no-color.org), RALPH_NO_FZF.

# Initialize colors based on NO_COLOR and TTY state.
ralph_ui_init_colors() {
  if [[ -t 1 && "${NO_COLOR+x}" != x ]]; then
    _RALPH_UI_C_G=$'\033[32m'
    _RALPH_UI_C_Y=$'\033[33m'
    _RALPH_UI_C_BOLD=$'\033[1m'
    _RALPH_UI_C_RST=$'\033[0m'
  else
    _RALPH_UI_C_G=""
    _RALPH_UI_C_Y=""
    _RALPH_UI_C_BOLD=""
    _RALPH_UI_C_RST=""
  fi
}
ralph_ui_init_colors

# Read one line from the operator. Prefer real stdin when it is a pipe (piped wizard/CI); use /dev/tty only for
# interactive terminals so stdin can still be redirected while the user types on the console.
# Args: $1 = name of variable to set (printf -v avoids bash 4.3 nameref for macOS bash 3.2).
ralph_ui_read_line() {
  local __line
  if [[ -p /dev/stdin ]]; then
    IFS= read -r __line || true
  elif [[ -t 0 ]] && [[ -r /dev/tty ]]; then
    IFS= read -r __line </dev/tty
  else
    IFS= read -r __line || true
  fi
  printf -v "$1" '%s' "$__line"
}

# Must stay aligned with ralph_internal_wizard_sanitize in wizard-prompts.sh (orchestration stage ids).
ralph_prompt_list_sanitize_stage_label() {
  local value="$1"
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
  value="$(printf '%s' "$value" | tr -c 'a-z0-9-' '-')"
  value="$(printf '%s' "$value" | sed 's/-\+/-/g; s/^-//; s/-$//')"
  printf '%s' "$value"
}

# Matches jq stage_id_ok in scripts/validate-orchestration-schema.sh
ralph_prompt_list_stage_id_valid() {
  [[ -n "$1" && "$1" =~ ^[a-z0-9_]+(-[a-z0-9_]+)*$ ]]
}

# ralph_prompt_text <label> [default]
# Prompts for freeform text input. Returns default on empty input (if provided).
# Pass "" as default to allow empty input (optional field).
# Exit 1 if no default and input is empty after one retry.
ralph_prompt_text() {
  local label="$1"
  local input attempt=0
  local has_default=0
  local default=""

  if [[ $# -ge 2 ]]; then
    has_default=1
    default="$2"
  fi

  while true; do
    if [[ $has_default -eq 1 && -n "$default" ]]; then
      printf '%s [default: %s]: ' "$label" "$default" >&2
    else
      printf '%s: ' "$label" >&2
    fi

    ralph_ui_read_line input

    if [[ -z "$input" ]]; then
      if [[ $has_default -eq 1 ]]; then
        printf '%s' "$default"
        return 0
      fi
      if (( attempt == 0 )); then
        printf '%s is required\n' "$label" >&2
        attempt=$((attempt + 1))
        continue
      fi
      return 1
    fi

    printf '%s' "$input"
    return 0
  done
}

# ralph_prompt_yesno <label> <default(y|n)>
# Prompts for y/n input. Renders [Y/n] or [y/N] per default. Returns literal y or n.
ralph_prompt_yesno() {
  local label="$1"
  local default="$2"
  local input

  if [[ "$default" != "y" && "$default" != "n" ]]; then
    printf 'ralph_prompt_yesno: invalid default "%s" (must be y or n)\n' "$default" >&2
    return 1
  fi

  while true; do
    if [[ "$default" == "y" ]]; then
      printf '%s [Y/n]: ' "$label" >&2
    else
      printf '%s [y/N]: ' "$label" >&2
    fi

    ralph_ui_read_line input

    input="${input:-$default}"
    input="$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')"

    case "$input" in
      y|yes)
        printf 'y'
        return 0
        ;;
      n|no)
        printf 'n'
        return 0
        ;;
      *)
        printf 'please answer y or n\n' >&2
        ;;
    esac
  done
}

# ralph_prompt_choice <label> <default> <opt1> <opt2> ...
# Prompts for choice from enum. Re-prompts on typo. Returns default on empty.
# Pass "" as default to allow empty input (no constraint).
ralph_prompt_choice() {
  local label="$1"
  local input is_valid
  local has_default=0
  local default=""

  if [[ $# -ge 2 ]]; then
    has_default=1
    default="$2"
  fi

  shift 2
  local opts=("$@")

  # Validate default is in opts (unless default is empty)
  if [[ $has_default -eq 1 && -n "$default" ]]; then
    is_valid=0
    for opt in "${opts[@]}"; do
      if [[ "$opt" == "$default" ]]; then
        is_valid=1
        break
      fi
    done
    if (( is_valid == 0 )); then
      printf 'ralph_prompt_choice: default "%s" not in opts\n' "$default" >&2
      return 1
    fi
  fi

  while true; do
    if [[ $has_default -eq 1 && -n "$default" ]]; then
      printf '%s [default: %s]: ' "$label" "$default" >&2
    else
      printf '%s (options: %s): ' "$label" "${opts[*]}" >&2
    fi

    ralph_ui_read_line input

    if [[ -z "$input" ]]; then
      if [[ $has_default -eq 1 ]]; then
        printf '%s' "$default"
        return 0
      fi
      return 0
    fi

    is_valid=0
    for opt in "${opts[@]}"; do
      if [[ "$opt" == "$input" ]]; then
        is_valid=1
        break
      fi
    done

    if (( is_valid == 1 )); then
      printf '%s' "$input"
      return 0
    fi

    printf 'must be one of: %s\n' "${opts[*]}" >&2
  done
}

# ralph_prompt_list <label> <default-csv> <known-csv> [allow_custom=0]
# Parses comma/space-separated tokens as numeric indices or names.
# If allow_custom is 1, tokens that are not indices or preset names are accepted when they
# sanitize to a non-empty orchestration stage id (lowercase, hyphens; see schema validator).
# Echoes accepted (green) and ignored (yellow) after parsing; re-prompts if ignored non-empty.
# Returns comma-joined accepted list on stdout.
ralph_prompt_list() {
  local label="$1"
  local default_csv="$2"
  local known_csv="$3"
  local allow_custom="${4:-0}"
  local input accepted_arr=() ignored_arr=() token idx custom_id

  # Parse known list into array
  local known_arr=()
  local known_normalized
  known_normalized="$(printf '%s' "$known_csv" | tr ',' ' ')"
  local IFS=' '
  read -r -a known_arr <<< "$known_normalized"
  unset IFS

  while true; do
    printf '%s (comma or space separated, enter for default): ' "$label" >&2

    ralph_ui_read_line input

    if [[ -z "$input" ]]; then
      input="$default_csv"
    fi

    accepted_arr=()
    ignored_arr=()

    # Parse input tokens
    local normalized
    normalized="$(printf '%s' "$input" | tr ',' ' ')"
    local input_tokens=()
    local IFS=' '
    read -r -a input_tokens <<< "$normalized"
    unset IFS

    for token in "${input_tokens[@]-}"; do
      token="$(printf '%s' "$token" | tr -d '[:space:]')"
      [[ -n "$token" ]] || continue

      local resolved_token=""
      if [[ "$token" =~ ^[0-9]+$ ]]; then
        # Numeric index into known list, or (with allow_custom) a literal all-digit stage id
        idx=$((token - 1))
        if (( idx >= 0 && idx < ${#known_arr[@]} )); then
          resolved_token="${known_arr[$idx]}"
        elif [[ "$allow_custom" == "1" ]]; then
          custom_id="$(ralph_prompt_list_sanitize_stage_label "$token")"
          if ralph_prompt_list_stage_id_valid "$custom_id"; then
            resolved_token="$custom_id"
          fi
        fi
      else
        # Name lookup
        for known_item in "${known_arr[@]}"; do
          if [[ "$known_item" == "$token" ]]; then
            resolved_token="$token"
            break
          fi
        done
        if [[ -z "$resolved_token" && "$allow_custom" == "1" ]]; then
          custom_id="$(ralph_prompt_list_sanitize_stage_label "$token")"
          if ralph_prompt_list_stage_id_valid "$custom_id"; then
            resolved_token="$custom_id"
          fi
        fi
      fi

      if [[ -z "$resolved_token" ]]; then
        ignored_arr+=("$token (unknown)")
        continue
      fi

      # Check for duplicates
      local is_dup=0
      if (( ${#accepted_arr[@]} > 0 )); then
        for existing in "${accepted_arr[@]}"; do
          if [[ "$existing" == "$resolved_token" ]]; then
            is_dup=1
            break
          fi
        done
      fi

      if (( is_dup == 1 )); then
        ignored_arr+=("$resolved_token (duplicate)")
      else
        accepted_arr+=("$resolved_token")
      fi
    done

    # Echo back results
    printf 'accepted: %s' "${_RALPH_UI_C_G}" >&2
    if (( ${#accepted_arr[@]} == 0 )); then
      printf '(none)' >&2
    else
      printf '%s' "${accepted_arr[*]}" >&2
    fi
    printf '%s' "${_RALPH_UI_C_RST}" >&2

    if (( ${#ignored_arr[@]} > 0 )); then
      printf '; ignored: %s%s%s' "${_RALPH_UI_C_Y}" "${ignored_arr[*]}" "${_RALPH_UI_C_RST}" >&2
      printf '\npress Enter to keep, or type anything to re-enter: ' >&2

      local confirm
      ralph_ui_read_line confirm

      if [[ -n "$confirm" ]]; then
        printf '\n' >&2
        continue
      fi
    fi

    printf '\n' >&2
    if (( ${#accepted_arr[@]} > 0 )); then
      (IFS=','; printf '%s' "${accepted_arr[*]}")
    fi
    return 0
  done
}
