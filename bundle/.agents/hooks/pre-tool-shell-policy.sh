#!/usr/bin/env bash
# preToolUse Shell adapter for Cursor: wrapper-based native shell compaction via
# shared native-shell-wrapper (pre-tool command rewrite).
#
# Proven on Cursor Agent 2026.06.03-0bbb28e (2026-06-04):
# - PreToolUse Shell input rewrite via updated_input.command is agent-visible.
# - Wrapper-based compaction (T3, T1): eligible commands rewrite to native-shell-wrapper
#   invocation; wrapper captures/compacts output and stores originals in
#   .ralph-workspace/tool-results/<plan-key>/ for retrieval via ralph_proxy_result_*.
# - PostToolUse Shell output replacement (updated_tool_output) is NOT agent-visible;
#   no native Shell output mutation claim. post-tool-shell-telemetry.sh is observability only.
#
# Gates: RALPH_NATIVE_SHELL_WRAPPER=1 (default on when Ralph enables Cursor native hooks)
#        RALPH_BASH_REWRITE=1 for fallback simple rewrite when wrapper is off.
# Fail-open: wrapper load/storage failures or gate off -> raw command execution.

set -uo pipefail

ralph_cursor_pre_tool_workspace() {
  if [[ -n "${WORKSPACE:-}" ]]; then
    printf '%s\n' "$WORKSPACE"
    return 0
  fi
  local root
  root="$(jq -r '.workspace_roots[0] // .cwd // empty' <<<"${RALPH_CURSOR_PRE_TOOL_INPUT:-{}}")"
  [[ -n "$root" ]] || return 1
  printf '%s\n' "$root"
}

ralph_cursor_pre_tool_emit_updated_command() {
  local command="${1:-}"
  jq -nc \
    --arg command "$command" \
    '{permission: "allow", updated_input: {command: $command}}'
}

ralph_cursor_pre_tool_rewrite_only() {
  local workspace="${1:-}" command="${2:-}" rewriter_lib="${3:-}"
  local rewrite_json rewritten_command rule_id plan_key

  # shellcheck source=/dev/null
  source "$rewriter_lib"

  rewrite_json="$(ralph_rewrite_shell_command "$command")"
  if ! ralph_rewrite_shell_command_applied "$rewrite_json"; then
    ralph_native_hook_fail_open
  fi

  rewritten_command="$(jq -r '.rewritten_command // empty' <<<"$rewrite_json")"
  rule_id="$(jq -r '.rule_id // empty' <<<"$rewrite_json")"
  [[ -n "$rewritten_command" ]] || ralph_native_hook_fail_open

  plan_key="$(ralph_native_hook_plan_key cursor-hook)"
  ralph_native_hook_append_rewrite_log \
    "$workspace" \
    "$plan_key" \
    "$command" \
    "$rewritten_command" \
    "$rule_id"

  ralph_cursor_pre_tool_emit_updated_command "$rewritten_command"
}

ralph_cursor_pre_tool_wrapper_path() {
  local workspace="${1:-}" command="${2:-}" rewriter_lib="${3:-}"
  local rewrite_json rewritten_command rule_id plan_key wrapper_command

  # shellcheck source=/dev/null
  source "$rewriter_lib"

  rewrite_json="$(ralph_rewrite_shell_command "$command")"
  if ! ralph_rewrite_shell_command_applied "$rewrite_json"; then
    ralph_native_hook_fail_open
  fi

  rewritten_command="$(jq -r '.rewritten_command // empty' <<<"$rewrite_json")"
  rule_id="$(jq -r '.rule_id // empty' <<<"$rewrite_json")"
  [[ -n "$rewritten_command" ]] || ralph_native_hook_fail_open

  plan_key="$(ralph_native_hook_plan_key cursor-hook)"
  wrapper_command="$(ralph_native_hook_build_wrapper_command \
    "$workspace" \
    "$rewritten_command" \
    "cursor" \
    "$plan_key")" || ralph_native_hook_fail_open

  ralph_native_hook_append_rewrite_log \
    "$workspace" \
    "$plan_key" \
    "$command" \
    "$wrapper_command" \
    "$rule_id"

  ralph_cursor_pre_tool_emit_updated_command "$wrapper_command"
}

ralph_cursor_pre_tool_main() {
  command -v jq >/dev/null 2>&1 || ralph_native_hook_fail_open
  command -v python3 >/dev/null 2>&1 || ralph_native_hook_fail_open

  RALPH_CURSOR_PRE_TOOL_INPUT="$(cat)" || ralph_native_hook_fail_open

  local event tool_name command workspace rewriter_lib use_wrapper=0
  event="$(jq -r '.hook_event_name // ""' <<<"$RALPH_CURSOR_PRE_TOOL_INPUT")"
  tool_name="$(jq -r '.tool_name // ""' <<<"$RALPH_CURSOR_PRE_TOOL_INPUT")"
  if [[ "$event" != "preToolUse" || "$tool_name" != "Shell" ]]; then
    ralph_native_hook_fail_open
  fi

  command="$(jq -r '.tool_input.command // ""' <<<"$RALPH_CURSOR_PRE_TOOL_INPUT")"
  [[ -n "$command" ]] || ralph_native_hook_fail_open

  if ralph_native_hook_truthy "${RALPH_NATIVE_SHELL_WRAPPER:-}"; then
    use_wrapper=1
  elif ! ralph_native_hook_truthy "${RALPH_BASH_REWRITE:-}"; then
    ralph_native_hook_fail_open
  fi

  workspace="$(ralph_cursor_pre_tool_workspace)" || ralph_native_hook_fail_open
  [[ -n "$workspace" && -d "$workspace" ]] || ralph_native_hook_fail_open
  rewriter_lib="$(ralph_native_hook_resolve_bash_lib "$workspace" "command-rewriter.sh" 2>/dev/null || true)"
  [[ -n "$rewriter_lib" && -f "$rewriter_lib" ]] || ralph_native_hook_fail_open

  if [[ "$use_wrapper" == "1" ]]; then
    ralph_cursor_pre_tool_wrapper_path "$workspace" "$command" "$rewriter_lib"
  else
    ralph_cursor_pre_tool_rewrite_only "$workspace" "$command" "$rewriter_lib"
  fi
}

_NATIVE_HOOK_BOOTSTRAP="${BASH_SOURCE%/*}/../../.ralph/bash-lib/native-hook/native-hook-bootstrap.sh"
if [[ ! -f "$_NATIVE_HOOK_BOOTSTRAP" ]]; then
  _NATIVE_HOOK_BOOTSTRAP="${RALPH_HOME:-${HOME:-}/.ralph}/bundle/.ralph/bash-lib/native-hook/native-hook-bootstrap.sh"
fi
if [[ ! -f "$_NATIVE_HOOK_BOOTSTRAP" ]]; then
  exit 0
fi
# shellcheck source=/dev/null
source "$_NATIVE_HOOK_BOOTSTRAP"
ralph_native_hook_bootstrap_source_lib || exit 0
unset _NATIVE_HOOK_BOOTSTRAP

ralph_cursor_pre_tool_main
