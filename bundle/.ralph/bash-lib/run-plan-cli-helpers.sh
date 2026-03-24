#!/usr/bin/env bash

if [[ -n "${RALPH_RUN_PLAN_CLI_HELPERS_LOADED:-}" ]]; then
  return
fi
RALPH_RUN_PLAN_CLI_HELPERS_LOADED=1

ralph_resolve_cursor_cli() {
  if command -v cursor-agent &>/dev/null; then
    printf '%s' "cursor-agent"
    return 0
  fi
  if command -v agent &>/dev/null; then
    printf '%s' "agent"
    return 0
  fi
  return 1
}
