#!/usr/bin/env bash
# One-time acknowledgment: looped AI agent runs can modify the workspace. Prompt on first use of
# run-plan or orchestrator; record consent under the user config directory.
# Skip when RALPH_USAGE_RISKS_ACKNOWLEDGED=1 (automation/CI) or when the marker file exists.

if [[ -n "${RALPH_USAGE_RISK_ACK_LIB_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
RALPH_USAGE_RISK_ACK_LIB_LOADED=1

RALPH_USAGE_RISK_ACK_VERSION=1

ralph_usage_risk_ack_init_colors() {
  UR_C_R="" UR_C_Y="" UR_C_G="" UR_C_C="" UR_C_B="" UR_C_DIM="" UR_C_BOLD="" UR_C_RST=""
  if [[ -t 2 ]] && [[ -z "${NO_COLOR:-}" ]] && [[ "${RALPH_PLAN_NO_COLOR:-${CURSOR_PLAN_NO_COLOR:-0}}" != "1" ]]; then
    UR_C_R="\033[31m"
    UR_C_Y="\033[33m"
    UR_C_G="\033[32m"
    UR_C_C="\033[36m"
    UR_C_B="\033[34m"
    UR_C_DIM="\033[2m"
    UR_C_BOLD="\033[1m"
    UR_C_RST="\033[0m"
  fi
}

ralph_usage_risk_ack_config_dir() {
  local base="${XDG_CONFIG_HOME:-$HOME/.config}"
  printf '%s/ralph' "$base"
}

ralph_usage_risk_ack_marker_path() {
  printf '%s/usage-risk-acknowledgment' "$(ralph_usage_risk_ack_config_dir)"
}

ralph_usage_risk_ack_marker_valid() {
  local path
  path="$(ralph_usage_risk_ack_marker_path)"
  [[ -f "$path" ]] && grep -q "^RALPH_USAGE_RISK_ACK_VERSION=${RALPH_USAGE_RISK_ACK_VERSION}\$" "$path" 2>/dev/null
}

ralph_usage_risk_ack_write_marker() {
  local path dir
  dir="$(ralph_usage_risk_ack_config_dir)"
  path="$(ralph_usage_risk_ack_marker_path)"
  mkdir -p "$dir"
  (
    umask 077
    {
      printf '%s\n' "# Ralph: records that you accepted usage risk warnings for AI agent runners."
      printf 'RALPH_USAGE_RISK_ACK_VERSION=%s\n' "$RALPH_USAGE_RISK_ACK_VERSION"
      printf 'ACKNOWLEDGED_AT=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    } >"$path"
  )
  chmod 600 "$path" 2>/dev/null || true
}

# Exit 0 if acknowledged; otherwise prompt (TTY) or print error and exit 2.
ralph_require_usage_risk_acknowledgment() {
  if [[ "${RALPH_USAGE_RISKS_ACKNOWLEDGED:-}" == "1" ]]; then
    return 0
  fi
  if ralph_usage_risk_ack_marker_valid; then
    return 0
  fi

  ralph_usage_risk_ack_init_colors

  echo "" >&2
  echo -e "${UR_C_Y}${UR_C_BOLD}Ralph usage warning${UR_C_RST}" >&2
  echo -e "${UR_C_DIM}Ralph runs AI coding agents in your workspace on a loop, continuously trying to complete a task.${UR_C_RST}" >&2
  echo -e "${UR_C_DIM}They can edit files, run shell commands, and act without continuous supervision. Misuse, bugs,${UR_C_RST}" >&2
  echo -e "${UR_C_DIM}or unsafe prompts can cause data loss, leak secrets, or damage your system.${UR_C_RST}" >&2
  echo "" >&2
  echo -e "${UR_C_R}${UR_C_BOLD}You must supervise runs and use Ralph only in projects you trust.${UR_C_RST}" >&2

  if [[ -t 0 ]] && [[ -r /dev/tty ]] && [[ -w /dev/tty ]]; then
    local line
    echo "" >&2
    echo -e "${UR_C_C}Type ${UR_C_BOLD}YES${UR_C_RST}${UR_C_C} (all caps) to confirm you understand and accept this risk, or press Enter to abort.${UR_C_RST}" >&2
    read -r line </dev/tty || line=""
    if [[ "$line" == "YES" ]]; then
      ralph_usage_risk_ack_write_marker
      echo -e "${UR_C_G}Acknowledgment saved.${UR_C_RST}" >&2
      return 0
    fi
    echo -e "${UR_C_R}Aborted (no acknowledgment).${UR_C_RST}" >&2
    exit 2
  fi

  echo "" >&2
  echo -e "${UR_C_Y}${UR_C_BOLD}Non-interactive session:${UR_C_RST} ${UR_C_DIM}cannot prompt. Do one of the following, then retry:${UR_C_RST}" >&2
  echo -e "  ${UR_C_DIM}-${UR_C_RST} Run this command once from an interactive terminal and type ${UR_C_BOLD}YES${UR_C_RST} at the prompt" >&2
  echo -e "  ${UR_C_DIM}-${UR_C_RST} Create the marker file (see path below)" >&2
  echo -e "  ${UR_C_DIM}-${UR_C_RST} Set ${UR_C_C}RALPH_USAGE_RISKS_ACKNOWLEDGED=1${UR_C_RST} for automation only" >&2
  echo "" >&2
  echo -e "${UR_C_B}Marker file:${UR_C_RST} ${UR_C_DIM}$(ralph_usage_risk_ack_marker_path)${UR_C_RST}" >&2
  exit 2
}
