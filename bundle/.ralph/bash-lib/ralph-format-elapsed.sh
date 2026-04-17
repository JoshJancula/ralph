#!/usr/bin/env bash
# Human-readable elapsed duration for terminal summaries (plan runs and orchestrator).
# Source from run-plan-core and orchestrator; do not execute directly.

if [[ -n "${RALPH_FORMAT_ELAPSED_LOADED:-}" ]]; then
  return
fi
RALPH_FORMAT_ELAPSED_LOADED=1

# Format seconds as "Hh Mm Ss", "Mm Ss", or "Ss" for terminal banners and summaries.
ralph_format_elapsed_secs() {
  local total="$1"
  local h=$((total / 3600))
  local rem=$((total % 3600))
  local m=$((rem / 60))
  local s=$((rem % 60))
  if [[ $h -gt 0 ]]; then
    echo "${h}h ${m}m ${s}s"
  elif [[ $m -gt 0 ]]; then
    echo "${m}m ${s}s"
  else
    echo "${s}s"
  fi
}
