#!/usr/bin/env bash
# GENERATED from bundle/.cursor/hooks/pre-tool-shell-policy.sh by scripts/sync-plugin-assets.sh - edit the canonical file
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

ralph_cursor_killswitch_mode_off() {
  case "${RALPH_MODE:-no}" in
    no | off | false | 0) return 0 ;;
    *) return 1 ;;
  esac
}

ralph_cursor_killswitch_record() {
  local record_path="${RALPH_KILLSWITCH_HOOK_RECORD:-}"
  local tool="${1:-}"
  local decision="${2:-}"
  local applied="${3:-false}"
  [[ -n "$record_path" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -nc \
    --arg runtime "cursor" \
    --arg tool "$tool" \
    --arg decision "$decision" \
    --argjson applied "$applied" \
    --arg source "native-hook" \
    '{runtime:$runtime,tool:$tool,decision:$decision,applied:$applied,source:$source}' \
    >>"$record_path" 2>/dev/null || true
}

ralph_cursor_killswitch_event_json() {
  local tool="${1:-}"
  local arguments="${2:-}"
  jq -nc \
    --argjson schemaVersion 1 \
    --arg source "native-hook" \
    --arg runtime "cursor" \
    --arg tool "$tool" \
    --arg action "execute" \
    --arg effect "write" \
    --arg resource "" \
    --arg arguments "$arguments" \
    '{
      schemaVersion: $schemaVersion,
      source: $source,
      runtime: $runtime,
      tool: $tool,
      action: $action,
      effect: $effect,
      resource: $resource,
      arguments: $arguments
    }'
}

ralph_cursor_killswitch_from_input() {
  local input_json="${1:-}"
  local workspace="${2:-}"
  local tool="${3:-}"
  local command="${4:-}"
  local event_json core

  ralph_cursor_killswitch_mode_off && {
    ralph_cursor_killswitch_record "${tool:-}" "skip" false
    return 0
  }

  if [[ -z "$tool" || -z "$command" ]]; then
    tool="$(jq -r '.tool_name // ""' <<<"$input_json")"
    command="$(jq -r '.tool_input.command // ""' <<<"$input_json")"
  fi
  [[ -n "$workspace" && -n "$tool" ]] || return 0

  # (b) Skip killswitch evaluation when no operator config exists and the
  # stock bundle rules clearly do not match (or no bundle config at all).
  if ! ralph_native_hook_killswitch_needs_full_evaluate "$workspace" "$command"; then
    ralph_cursor_killswitch_record "$tool" "skip" false
    return 0
  fi

  core="$(ralph_native_hook_resolve_bash_lib "$workspace" "killswitch/killswitch-core.sh" 2>/dev/null || true)"
  [[ -n "$core" && -f "$core" ]] || return 0
  # shellcheck source=/dev/null
  source "$core"

  event_json="$(ralph_cursor_killswitch_event_json "$tool" "$command")" || return 0
  killswitch_evaluate "$event_json" >/dev/null
  ralph_cursor_killswitch_record "$tool" "${KILLSWITCH_DECISION:-allow}" "$([ "${KILLSWITCH_DECISION:-allow}" = "fatal" ] && echo true || echo false)"
  if [[ "${KILLSWITCH_DECISION:-allow}" == "fatal" ]]; then
    killswitch_apply_decision fatal
  fi
  return 0
}

ralph_cursor_pre_tool_main() {
  command -v jq >/dev/null 2>&1 || ralph_native_hook_fail_open

  RALPH_CURSOR_PRE_TOOL_INPUT="$(cat)" || ralph_native_hook_fail_open

  local event tool_name command workspace rewriter_lib use_wrapper=0 use_rewrite=0
  local final_command rewritten_command="" rule_id="" rewrite_applied=false rewrite_json
  eval "$(jq -r '
    "event=\(.hook_event_name // "" | @sh)\n" +
    "tool_name=\(.tool_name // "" | @sh)\n" +
    "command=\(.tool_input.command // "" | @sh)"
  ' <<<"$RALPH_CURSOR_PRE_TOOL_INPUT")" || ralph_native_hook_fail_open
  if [[ "$event" != "preToolUse" || "$tool_name" != "Shell" ]]; then
    ralph_cursor_killswitch_record "$tool_name" "nudge" false
    ralph_native_hook_fail_open
  fi

  [[ -n "$command" ]] || ralph_native_hook_fail_open

  workspace="$(ralph_cursor_pre_tool_workspace)" || ralph_native_hook_fail_open
  ralph_cursor_killswitch_from_input "$RALPH_CURSOR_PRE_TOOL_INPUT" "$workspace" "$tool_name" "$command"

  if ralph_native_hook_truthy "${RALPH_NATIVE_SHELL_WRAPPER:-}"; then
    use_wrapper=1
  fi
  if ralph_native_hook_truthy "${RALPH_BASH_REWRITE:-}"; then
    use_rewrite=1
  fi
  if [[ "$use_wrapper" != "1" && "$use_rewrite" != "1" ]]; then
    ralph_native_hook_fail_open
  fi

  [[ -n "$workspace" && -d "$workspace" ]] || ralph_native_hook_fail_open
  final_command="$command"

  # (a) Skip rewrite/registry python3 when RALPH_BASH_REWRITE is not truthy.
  if [[ "$use_rewrite" == "1" ]]; then
    command -v python3 >/dev/null 2>&1 || ralph_native_hook_fail_open
    rewriter_lib="$(ralph_native_hook_resolve_bash_lib "$workspace" "command-rewriter.sh" 2>/dev/null || true)"
    [[ -n "$rewriter_lib" && -f "$rewriter_lib" ]] || ralph_native_hook_fail_open
    # shellcheck source=/dev/null
    source "$rewriter_lib"
    rewrite_json="$(ralph_rewrite_shell_command "$command")"
    if ralph_rewrite_shell_command_applied "$rewrite_json"; then
      rewritten_command="$(jq -r '.rewritten_command // empty' <<<"$rewrite_json")"
      rule_id="$(jq -r '.rule_id // empty' <<<"$rewrite_json")"
      if [[ -n "$rewritten_command" ]]; then
        rewrite_applied=true
        final_command="$rewritten_command"
        ralph_native_hook_append_rewrite_log \
          "$workspace" \
          "$(ralph_native_hook_plan_key cursor-hook)" \
          "$command" \
          "$rewritten_command" \
          "$rule_id"
      fi
    fi
  fi

  if [[ "$use_wrapper" == "1" ]]; then
    local plan_key wrapper_command
    plan_key="$(ralph_native_hook_plan_key cursor-hook)"
    wrapper_command="$(ralph_native_hook_build_wrapper_command \
      "$workspace" \
      "$final_command" \
      "cursor" \
      "$plan_key")" || {
      # Wrapper unavailable: fall back to rewrite-only emission when applied.
      if [[ "$rewrite_applied" == "true" ]]; then
        ralph_cursor_pre_tool_emit_updated_command "$final_command"
        return 0
      fi
      ralph_native_hook_fail_open
    }
    if [[ "$rewrite_applied" == "true" ]]; then
      ralph_native_hook_append_rewrite_log \
        "$workspace" \
        "$plan_key" \
        "$command" \
        "$wrapper_command" \
        "${rule_id:-wrapper}"
    fi
    ralph_cursor_pre_tool_emit_updated_command "$wrapper_command"
    return 0
  fi

  # Rewrite-only path (wrapper off).
  if [[ "$rewrite_applied" == "true" ]]; then
    ralph_cursor_pre_tool_emit_updated_command "$final_command"
    return 0
  fi
  ralph_native_hook_fail_open
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
