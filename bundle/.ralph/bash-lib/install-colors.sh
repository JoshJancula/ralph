#!/usr/bin/env bash
# ANSI styling for install.sh. Disable with NO_COLOR (empty or unset per convention) or
# RALPH_INSTALL_NO_COLOR=1. No output when sourced except via install_colors_init.

install_colors_init() {
  if [[ ( -t 1 || -t 2 ) && -z "${NO_COLOR:-}" && "${RALPH_INSTALL_NO_COLOR:-0}" != "1" ]]; then
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
  printf '%b\n' "${C_MAG}${C_BOLD}${1:-Ralph}${C_RST} ${C_DIM}${2:-}${C_RST}"
}

install_log_phase() {
  printf '%b\n' "${C_C}${C_BOLD}%s${C_RST}" "$1"
}

install_log_ok() {
  printf '%b\n' "${C_G}${C_BOLD}%s${C_RST} ${C_B}%s${C_RST}" "$1" "$2"
}

install_log_ok_detail() {
  printf '%b\n' "  ${C_DIM}%s${C_RST} ${C_B}%s${C_RST}" "$1" "$2"
}

install_log_skip() {
  printf '%b\n' "${C_Y}%s${C_RST} ${C_DIM}%s${C_RST}" "$1" "$2" >&2
}

install_log_warn() {
  if [[ -n "${2:-}" ]]; then
    printf '%b\n' "${C_Y}${C_BOLD}%s${C_RST} %s" "$1" "$2" >&2
  else
    printf '%b\n' "${C_Y}%s${C_RST}" "$1" >&2
  fi
}

install_log_err() {
  if [[ -n "${2:-}" ]]; then
    printf '%b\n' "${C_R}${C_BOLD}%s${C_RST} %s" "$1" "$2" >&2
  else
    printf '%b\n' "${C_R}%s${C_RST}" "$1" >&2
  fi
}

install_log_dry() {
  printf '%b\n' "${C_Y}${C_BOLD}%s${C_RST} %s" "$1" "$2"
}

install_log_next_header() {
  printf '%b\n' "${C_C}${C_BOLD}%s${C_RST}" "$1"
}

install_log_next_line() {
  printf '%b\n' "  ${C_DIM}%s${C_RST}" "$1"
}

install_log_divider() {
  printf '%b\n' "${C_MAG}${C_DIM}%s${C_RST}" "$1"
}
