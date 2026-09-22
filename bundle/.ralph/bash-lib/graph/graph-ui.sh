#!/usr/bin/env bash
# Operator-facing presentation for graph mode.
#
# Graph runs are the one Ralph surface where several agents work at once and the
# operator cannot see any of them. Every scheduler line therefore has to carry
# its own context: which node, what happened, and where to look next. This file
# owns that formatting so the scheduler, gate, and run entry points stay
# consistent instead of each hand-rolling an "echo prefix=value" line.
#
# Color follows the NO_COLOR convention (https://no-color.org) and is dropped
# whenever stderr is not a terminal, so piping to a file yields clean text.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

GRAPH_UI_READY="${GRAPH_UI_READY:-0}"

graph_ui_init() {
  [[ "$GRAPH_UI_READY" == "1" ]] && return 0
  if [[ -t 2 && "${NO_COLOR+x}" != x && "${RALPH_GRAPH_NO_COLOR:-0}" != "1" ]]; then
    GRAPH_UI_R=$'\033[31m'
    GRAPH_UI_G=$'\033[32m'
    GRAPH_UI_Y=$'\033[33m'
    GRAPH_UI_B=$'\033[34m'
    GRAPH_UI_MAG=$'\033[35m'
    GRAPH_UI_C=$'\033[36m'
    GRAPH_UI_BOLD=$'\033[1m'
    GRAPH_UI_DIM=$'\033[2m'
    GRAPH_UI_RST=$'\033[0m'
  else
    GRAPH_UI_R="" GRAPH_UI_G="" GRAPH_UI_Y="" GRAPH_UI_B="" GRAPH_UI_MAG=""
    GRAPH_UI_C="" GRAPH_UI_BOLD="" GRAPH_UI_DIM="" GRAPH_UI_RST=""
  fi
  GRAPH_UI_READY=1
  return 0
}

# Horizontal rule sized to a fixed 72 columns. Fixed width keeps the scheduler's
# interleaved output aligned even when nodes write concurrently.
graph_ui_rule() {
  graph_ui_init
  printf '%b%s%b\n' "$GRAPH_UI_DIM" "------------------------------------------------------------------------" "$GRAPH_UI_RST" >&2
}

# graph_ui_banner <title> [subtitle]
graph_ui_banner() {
  graph_ui_init
  printf '\n' >&2
  graph_ui_rule
  if [[ -n "${2:-}" ]]; then
    printf '%b%s%b %b%s%b\n' "${GRAPH_UI_MAG}${GRAPH_UI_BOLD}" "$1" "$GRAPH_UI_RST" "$GRAPH_UI_DIM" "$2" "$GRAPH_UI_RST" >&2
  else
    printf '%b%s%b\n' "${GRAPH_UI_MAG}${GRAPH_UI_BOLD}" "$1" "$GRAPH_UI_RST" >&2
  fi
  graph_ui_rule
}

# graph_ui_kv <label> <value> - aligned detail line under a banner or event.
graph_ui_kv() {
  graph_ui_init
  printf '  %b%-14s%b %s\n' "$GRAPH_UI_DIM" "$1" "$GRAPH_UI_RST" "${2:-}" >&2
}

# graph_ui_section <title> - lightweight group heading between phases.
graph_ui_section() {
  graph_ui_init
  printf '\n%b%s%b\n' "${GRAPH_UI_C}${GRAPH_UI_BOLD}" "$1" "$GRAPH_UI_RST" >&2
}

# Status vocabulary shared by node events and the closing summary. Keeping the
# glyph set ASCII avoids width surprises in terminals that render wide symbols
# inconsistently, and satisfies the project's no-emoji rule.
#
# Assigns to GRAPH_UI_STATUS_COLOR / GRAPH_UI_STATUS_GLYPH rather than printing.
# graph_ui_node runs on the scheduler's node-spawn path, where every fork costs
# real time: a subprocess here delays the next spawn and narrows the window in
# which sibling nodes genuinely overlap.
GRAPH_UI_STATUS_COLOR=""
GRAPH_UI_STATUS_GLYPH=""
_graph_ui_set_status_style() {
  graph_ui_init
  case "$1" in
    start|running|spawn)
      GRAPH_UI_STATUS_COLOR="$GRAPH_UI_C"; GRAPH_UI_STATUS_GLYPH="->" ;;
    passed|succeeded|ok)
      GRAPH_UI_STATUS_COLOR="$GRAPH_UI_G"; GRAPH_UI_STATUS_GLYPH="ok" ;;
    failed|error)
      GRAPH_UI_STATUS_COLOR="$GRAPH_UI_R"; GRAPH_UI_STATUS_GLYPH="XX" ;;
    blocked|skipped)
      GRAPH_UI_STATUS_COLOR="$GRAPH_UI_Y"; GRAPH_UI_STATUS_GLYPH=".." ;;
    awaiting-ack)
      GRAPH_UI_STATUS_COLOR="$GRAPH_UI_Y"; GRAPH_UI_STATUS_GLYPH="??" ;;
    cancelled)
      GRAPH_UI_STATUS_COLOR="$GRAPH_UI_DIM"; GRAPH_UI_STATUS_GLYPH="--" ;;
    *)
      GRAPH_UI_STATUS_COLOR="$GRAPH_UI_B"; GRAPH_UI_STATUS_GLYPH="  " ;;
  esac
}

# graph_ui_node <status> <node-id> [detail]
#
# The primary lifecycle line. Node id is the anchor an operator scans for, so it
# stays bold and immediately after the status glyph.
graph_ui_node() {
  graph_ui_init
  local status="$1" node_id="$2" detail="${3:-}"
  local color glyph
  _graph_ui_set_status_style "$status"
  color="$GRAPH_UI_STATUS_COLOR"
  glyph="$GRAPH_UI_STATUS_GLYPH"
  if [[ -n "$detail" ]]; then
    printf '%b%s%b %b%s%b %b%s%b\n' \
      "$color" "$glyph" "$GRAPH_UI_RST" \
      "$GRAPH_UI_BOLD" "$node_id" "$GRAPH_UI_RST" \
      "$GRAPH_UI_DIM" "$detail" "$GRAPH_UI_RST" >&2
  else
    printf '%b%s%b %b%s%b\n' \
      "$color" "$glyph" "$GRAPH_UI_RST" \
      "$GRAPH_UI_BOLD" "$node_id" "$GRAPH_UI_RST" >&2
  fi
}

# graph_ui_detail <text> - indented continuation under a node event.
graph_ui_detail() {
  graph_ui_init
  printf '   %b%s%b\n' "$GRAPH_UI_DIM" "$1" "$GRAPH_UI_RST" >&2
}

# graph_ui_cause <text> - the reason a node failed. Deliberately uncolored body
# on a red label: provider error strings are the payload and must stay readable.
graph_ui_cause() {
  graph_ui_init
  printf '   %bcause:%b %s\n' "${GRAPH_UI_R}${GRAPH_UI_BOLD}" "$GRAPH_UI_RST" "$1" >&2
}

graph_ui_warn() {
  graph_ui_init
  printf '%b%s%b %s\n' "${GRAPH_UI_Y}${GRAPH_UI_BOLD}" "warning" "$GRAPH_UI_RST" "$1" >&2
}

graph_ui_error() {
  graph_ui_init
  printf '%b%s%b %s\n' "${GRAPH_UI_R}${GRAPH_UI_BOLD}" "error" "$GRAPH_UI_RST" "$1" >&2
}
