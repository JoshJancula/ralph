#!/usr/bin/env bash

if [[ -n "${RALPH_RUN_PLAN_CLI_HELPERS_LOADED:-}" ]]; then
  return
fi
RALPH_RUN_PLAN_CLI_HELPERS_LOADED=1

# Public interface:
#   ralph_resolve_cursor_cli -- prints cursor-agent or agent on PATH, else returns 1.
#   ralph_resolve_opencode_cli -- prints opencode on PATH, else returns 1.
#   ralph_resolve_antigravity_cli -- prints agy on PATH, else returns 1.

ralph_resolve_antigravity_cli() {
  local cli="${ANTIGRAVITY_PLAN_CLI:-}"
  if [[ -z "$cli" && -n "$(command -v agy 2>/dev/null)" ]]; then
    cli="agy"
  fi
  if [[ -z "$cli" ]] || ! command -v "$cli" &>/dev/null; then
    return 1
  fi
  printf '%s' "$cli"
}

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

ralph_resolve_opencode_cli() {
  if command -v opencode &>/dev/null; then
    printf '%s' "opencode"
    return 0
  fi
  return 1
}

export -f ralph_resolve_antigravity_cli 2>/dev/null || true
