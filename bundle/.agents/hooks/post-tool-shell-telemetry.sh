#!/usr/bin/env bash
# postToolUse Shell telemetry for Cursor (observability only).
#
# Headless proof (cursor-agent 2026.06.03-0bbb28e, 2026-06-04): updated_tool_output
# does not change agent-visible Shell stdout on cursor-agent -p; do not enable
# RALPH_BASH_COMPACT for Cursor native hooks.
#
# Optional JSONL audit path: RALPH_BASH_TELEMETRY_LOG

set -uo pipefail

ralph_cursor_post_tool_fail_open() {
  exit 0
}

ralph_cursor_post_tool_workspace() {
  if [[ -n "${WORKSPACE:-}" ]]; then
    printf '%s\n' "$WORKSPACE"
    return 0
  fi
  local root
  root="$(jq -r '.workspace_roots[0] // .cwd // empty' <<<"${RALPH_CURSOR_POST_TOOL_INPUT:-{}}")"
  [[ -n "$root" ]] || return 1
  printf '%s\n' "$root"
}

ralph_cursor_post_tool_plan_key() {
  if [[ -n "${RALPH_PLAN_KEY:-}" ]]; then
    printf '%s\n' "$RALPH_PLAN_KEY"
    return 0
  fi
  if [[ -n "${RALPH_ARTIFACT_NS:-}" ]]; then
    printf '%s\n' "$RALPH_ARTIFACT_NS"
    return 0
  fi
  printf 'cursor-hook\n'
}

ralph_cursor_post_tool_main() {
  command -v jq >/dev/null 2>&1 || ralph_cursor_post_tool_fail_open

  RALPH_CURSOR_POST_TOOL_INPUT="$(cat)" || ralph_cursor_post_tool_fail_open

  local event tool_name command stdout stderr log_path workspace plan_key telemetry_lib
  event="$(jq -r '.hook_event_name // ""' <<<"$RALPH_CURSOR_POST_TOOL_INPUT")"
  tool_name="$(jq -r '.tool_name // ""' <<<"$RALPH_CURSOR_POST_TOOL_INPUT")"
  if [[ "$event" != "postToolUse" || "$tool_name" != "Shell" ]]; then
    ralph_cursor_post_tool_fail_open
  fi

  log_path="${RALPH_BASH_TELEMETRY_LOG:-}"
  [[ -n "$log_path" ]] || ralph_cursor_post_tool_fail_open

  command="$(jq -r '.tool_input.command // ""' <<<"$RALPH_CURSOR_POST_TOOL_INPUT")"
  stdout="$(jq -r '.tool_output.stdout // ""' <<<"$RALPH_CURSOR_POST_TOOL_INPUT")"
  stderr="$(jq -r '.tool_output.stderr // ""' <<<"$RALPH_CURSOR_POST_TOOL_INPUT")"

  workspace="$(ralph_cursor_post_tool_workspace)" || ralph_cursor_post_tool_fail_open
  plan_key="$(ralph_cursor_post_tool_plan_key)"
  _NATIVE_HOOK_BOOTSTRAP="${BASH_SOURCE%/*}/../../.ralph/bash-lib/native-hook/native-hook-bootstrap.sh"
  if [[ ! -f "$_NATIVE_HOOK_BOOTSTRAP" ]]; then
    _NATIVE_HOOK_BOOTSTRAP="${RALPH_HOME:-${HOME:-}/.ralph}/bundle/.ralph/bash-lib/native-hook/native-hook-bootstrap.sh"
  fi
  if [[ -f "$_NATIVE_HOOK_BOOTSTRAP" ]]; then
    # shellcheck source=/dev/null
    source "$_NATIVE_HOOK_BOOTSTRAP"
    ralph_native_hook_bootstrap_source_lib || true
  fi

  telemetry_lib="$(ralph_native_hook_resolve_bash_lib "$workspace" "hook-telemetry.sh" 2>/dev/null || true)"
  if [[ -z "$telemetry_lib" || ! -f "$telemetry_lib" ]]; then
    ralph_cursor_post_tool_fail_open
  fi
  # shellcheck source=/dev/null
  source "$telemetry_lib"
  ralph_hook_telemetry_append_compact_log \
    "$workspace" \
    "$plan_key" \
    "$command" \
    "$stdout" \
    "$stderr" \
    "$stdout" \
    "$stderr" \
    "cursor-native-telemetry-only" \
    false
}

ralph_cursor_post_tool_main
