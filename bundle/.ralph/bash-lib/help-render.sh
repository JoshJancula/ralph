#!/usr/bin/env bash
# Shared presentation helpers for public Ralph command help.  They intentionally
# do not parse command semantics: each command remains the owner of its contract.
#
# Color applies only when stdout is a TTY. NO_COLOR (any value; https://no-color.org)
# or RALPH_INSTALL_NO_COLOR=1 disables escapes so redirected/machine output stays plain.

ralph_help_style_init() {
  RALPH_HELP_BOLD="" RALPH_HELP_CYAN="" RALPH_HELP_YELLOW="" RALPH_HELP_DIM="" RALPH_HELP_RESET=""
  if [[ -t 1 && "${NO_COLOR+x}" != x && "${RALPH_INSTALL_NO_COLOR:-0}" != "1" ]]; then
    RALPH_HELP_BOLD=$'\033[1m'; RALPH_HELP_CYAN=$'\033[36m'
    RALPH_HELP_YELLOW=$'\033[33m'; RALPH_HELP_DIM=$'\033[2m'; RALPH_HELP_RESET=$'\033[0m'
  fi
}

# Fold width for wrapped help text (description indent is four spaces).
ralph_help_text_width() {
  local w="${COLUMNS:-80}"
  (( w >= 40 )) || w=80
  w=$(( w - 4 ))
  (( w < 36 )) && w=36
  (( w > 100 )) && w=100
  printf '%s' "$w"
}

ralph_help_title() {
  ralph_help_style_init
  printf '%s%s%s\n' "${RALPH_HELP_BOLD}${RALPH_HELP_CYAN}" "$1" "$RALPH_HELP_RESET"
}

ralph_help_section() { printf '\n%s%s%s\n' "${RALPH_HELP_BOLD}${RALPH_HELP_YELLOW}" "$1" "$RALPH_HELP_RESET"; }

ralph_help_command() {
  local synopsis="$1" description="$2" width
  width="$(ralph_help_text_width)"
  printf '\n  %s%s%s\n' "${RALPH_HELP_BOLD}${RALPH_HELP_CYAN}" "$synopsis" "$RALPH_HELP_RESET"
  printf '%s\n' "$description" | fold -s -w "$width" | sed 's/^/    /'
}

ralph_help_option() {
  local flag="$1" arguments="$2" description="$3" width
  width="$(ralph_help_text_width)"
  printf '  %s%s%s' "${RALPH_HELP_BOLD}${RALPH_HELP_CYAN}" "$flag" "$RALPH_HELP_RESET"
  [[ -n "$arguments" ]] && printf ' %s%s%s' "$RALPH_HELP_DIM" "$arguments" "$RALPH_HELP_RESET"
  printf '\n'
  [[ -n "$description" ]] || return 0
  printf '%s\n' "$description" | fold -s -w "$width" | sed 's/^/    /'
}

ralph_help_note() { printf '%s%s%s\n' "$RALPH_HELP_DIM" "$1" "$RALPH_HELP_RESET"; }

# Render existing command-owned help heredocs consistently while they are
# migrated. It preserves every line and only adds terminal-safe presentation.
ralph_help_render() {
  ralph_help_style_init
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      Usage:*) printf '%s%s%s\n' "${RALPH_HELP_BOLD}${RALPH_HELP_CYAN}" "$line" "$RALPH_HELP_RESET" ;;
      Commands:|Subcommands:|Options:|Examples:|Environment:|Constraints:|Runtimes:|Legacy\ compatibility:)
        printf '\n%s%s%s\n' "${RALPH_HELP_BOLD}${RALPH_HELP_YELLOW}" "$line" "$RALPH_HELP_RESET" ;;
      '  --'*|'  -'*) printf '%s%s%s\n' "$RALPH_HELP_CYAN" "$line" "$RALPH_HELP_RESET" ;;
      *) printf '%s\n' "$line" ;;
    esac
  done
}
