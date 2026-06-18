#!/usr/bin/env bash
# ANSI styling for install.sh. Disable when NO_COLOR is set (any value; see https://no-color.org) or
# RALPH_INSTALL_NO_COLOR=1. No output when sourced except via install_colors_init.
#
# All printf calls use an explicit format string as the first argument so placeholders are never
# mistaken for literal text (printf only interprets % in the format string, not in data arguments).

install_colors_init() {
  if [[ ( -t 1 || -t 2 ) && "${NO_COLOR+x}" != x && "${RALPH_INSTALL_NO_COLOR:-0}" != "1" ]]; then
    C_R=$'\033[31m'
    C_G=$'\033[32m'
    C_Y=$'\033[33m'
    C_B=$'\033[34m'
    C_MAG=$'\033[35m'
    C_C=$'\033[36m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_RST=$'\033[0m'
  else
    C_R="" C_G="" C_Y="" C_B="" C_MAG="" C_C="" C_BOLD="" C_DIM="" C_RST=""
  fi
}

install_log_banner() {
  printf '%b%s%b %b%s%b\n' "${C_MAG}${C_BOLD}" "${1:-Ralph}" "${C_RST}" "${C_DIM}" "${2:-}" "${C_RST}"
}

install_log_phase() {
  printf '%b%s%b\n' "${C_C}${C_BOLD}" "$1" "${C_RST}"
}

install_log_ok() {
  printf '%b%s%b %b%s%b\n' "${C_G}${C_BOLD}" "$1" "${C_RST}" "${C_B}" "$2" "${C_RST}"
}

install_log_ok_detail() {
  printf '  %b%s%b %b%s%b\n' "${C_DIM}" "$1" "${C_RST}" "${C_B}" "$2" "${C_RST}"
}

install_log_skip() {
  printf '%b%s%b %b%s%b\n' "${C_Y}" "$1" "${C_RST}" "${C_DIM}" "$2" "${C_RST}" >&2
}

install_log_warn() {
  if [[ -n "${2:-}" ]]; then
    printf '%b%s%b %s\n' "${C_Y}${C_BOLD}" "$1" "${C_RST}" "$2" >&2
  else
    printf '%b%s%b\n' "${C_Y}" "$1" "${C_RST}" >&2
  fi
}

install_log_err() {
  if [[ -n "${2:-}" ]]; then
    printf '%b%s%b %s\n' "${C_R}${C_BOLD}" "$1" "${C_RST}" "$2" >&2
  else
    printf '%b%s%b\n' "${C_R}" "$1" "${C_RST}" >&2
  fi
}

install_log_dry() {
  printf '%b%s%b %s\n' "${C_Y}${C_BOLD}" "$1" "${C_RST}" "$2"
}

install_log_next_header() {
  printf '%b%s%b\n' "${C_C}${C_BOLD}" "$1" "${C_RST}"
}

install_log_next_line() {
  printf '  %b%s%b\n' "${C_DIM}" "$1" "${C_RST}"
}

install_log_divider() {
  printf '%b%s%b\n' "${C_MAG}${C_DIM}" "$1" "${C_RST}"
}
