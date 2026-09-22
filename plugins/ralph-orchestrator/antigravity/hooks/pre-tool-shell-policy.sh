#!/usr/bin/env bash
# GENERATED from bundle/.agents/hooks/pre-tool-shell-policy.sh by scripts/sync-plugin-assets.sh - edit the canonical file
# PreToolUse run_command adapter for Antigravity (agy): wrapper-based native shell
# compaction via the shared native-shell-wrapper (pre-tool command rewrite).
#
# agy contract: stdin carries camelCase JSON (toolCall.name, toolCall.args.CommandLine,
# workspacePaths[0]); stdout carries {"decision":"allow"|"deny", "overwrite":{...}}.
# Cursor payload keys (tool_name, tool_input.command, workspace_roots) are not accepted.
#
# Gates: RALPH_NATIVE_SHELL_WRAPPER=1 (wrapper) or RALPH_BASH_REWRITE=1 (simple rewrite).
# Fail-open: any failure or gate off prints {"decision":"allow"} and exits 0.
#
# Telemetry decision: agy PostToolUse carries only stepIdx and error (no output
# bytes, duration, or command), so byte-count and command-hash telemetry cannot be
# produced there. There is no PostToolUse hook; rewrite telemetry is recorded here,
# on the PreToolUse side, via ralph_native_hook_append_rewrite_log.

set -uo pipefail

# The shared fail-open helper exits 0 silently; agy requires a JSON decision on
# stdout, so an EXIT trap answers allow whenever no decision was emitted.
ralph_antigravity_pre_tool_exit_guard() {
  if [[ "${_RALPH_AGY_PRE_TOOL_EMITTED:-0}" != "1" ]]; then
    printf '{"decision":"allow"}\n'
  fi
}
trap ralph_antigravity_pre_tool_exit_guard EXIT

ralph_antigravity_pre_tool_emit_deny() {
  local reason="${1:-blocked by killswitch}"
  _RALPH_AGY_PRE_TOOL_EMITTED=1
  jq -nc --arg reason "$reason" '{decision: "deny", reason: $reason}'
}

ralph_antigravity_pre_tool_emit_updated_command() {
  local command="${1:-}"
  _RALPH_AGY_PRE_TOOL_EMITTED=1
  jq -nc \
    --arg command "$command" \
    '{decision: "allow", overwrite: {CommandLine: $command}}'
}

ralph_antigravity_killswitch_mode_off() {
  case "${RALPH_MODE:-no}" in
    no | off | false | 0) return 0 ;;
    *) return 1 ;;
  esac
}

ralph_antigravity_killswitch_record() {
  local record_path="${RALPH_KILLSWITCH_HOOK_RECORD:-}"
  local tool="${1:-}"
  local decision="${2:-}"
  local applied="${3:-false}"
  [[ -n "$record_path" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -nc \
    --arg runtime "antigravity" \
    --arg tool "$tool" \
    --arg decision "$decision" \
    --argjson applied "$applied" \
    --arg source "native-hook" \
    '{runtime:$runtime,tool:$tool,decision:$decision,applied:$applied,source:$source}' \
    >>"$record_path" 2>/dev/null || true
}

ralph_antigravity_killswitch_event_json() {
  local tool="${1:-}"
  local arguments="${2:-}"
  jq -nc \
    --argjson schemaVersion 1 \
    --arg source "native-hook" \
    --arg runtime "antigravity" \
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

ralph_antigravity_killswitch_from_input() {
  local workspace="${1:-}"
  local tool="${2:-}"
  local command="${3:-}"
  local event_json core

  ralph_antigravity_killswitch_mode_off && {
    ralph_antigravity_killswitch_record "${tool:-}" "skip" false
    return 0
  }
  [[ -n "$workspace" && -n "$tool" ]] || return 0

  # Skip killswitch evaluation when no operator config exists and the
  # stock bundle rules clearly do not match (or no bundle config at all).
  if ! ralph_native_hook_killswitch_needs_full_evaluate "$workspace" "$command"; then
    ralph_antigravity_killswitch_record "$tool" "skip" false
    return 0
  fi

  core="$(ralph_native_hook_resolve_bash_lib "$workspace" "killswitch/killswitch-core.sh" 2>/dev/null || true)"
  [[ -n "$core" && -f "$core" ]] || return 0
  # shellcheck source=/dev/null
  source "$core"

  event_json="$(ralph_antigravity_killswitch_event_json "$tool" "$command")" || return 0
  killswitch_evaluate "$event_json" >/dev/null
  ralph_antigravity_killswitch_record "$tool" "${KILLSWITCH_DECISION:-allow}" "$([ "${KILLSWITCH_DECISION:-allow}" = "fatal" ] && echo true || echo false)"
  if [[ "${KILLSWITCH_DECISION:-allow}" == "fatal" ]]; then
    # killswitch_trigger exits 77 after recording the sentinel; contain it so the
    # hook can still answer agy with a deny decision.
    (killswitch_apply_decision fatal) >/dev/null 2>&1
    ralph_antigravity_pre_tool_emit_deny "${KILLSWITCH_DECISION_REASON:-blocked by killswitch policy}"
    return 1
  fi
  return 0
}

ralph_antigravity_pre_tool_main() {
  command -v jq >/dev/null 2>&1 || ralph_native_hook_fail_open

  RALPH_AGY_PRE_TOOL_INPUT="$(cat)" || ralph_native_hook_fail_open

  local tool_name="" command="" workspace="" rewriter_lib use_wrapper=0 use_rewrite=0
  local parsed
  local final_command rewritten_command="" rule_id="" rewrite_applied=false rewrite_json
  parsed="$(jq -r '
    "tool_name=\(.toolCall.name // "" | tostring | @sh)\n" +
    "command=\(.toolCall.args.CommandLine // "" | tostring | @sh)\n" +
    "workspace=\(.workspacePaths[0] // "" | tostring | @sh)"
  ' <<<"$RALPH_AGY_PRE_TOOL_INPUT" 2>/dev/null)" || ralph_native_hook_fail_open
  eval "$parsed"
  if [[ "$tool_name" != "run_command" ]]; then
    ralph_antigravity_killswitch_record "$tool_name" "nudge" false
    ralph_native_hook_fail_open
  fi

  [[ -n "$command" ]] || ralph_native_hook_fail_open

  [[ -n "$workspace" ]] || ralph_native_hook_fail_open
  ralph_antigravity_killswitch_from_input "$workspace" "$tool_name" "$command" || return 0

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
          "$(ralph_native_hook_plan_key antigravity-hook)" \
          "$command" \
          "$rewritten_command" \
          "$rule_id"
      fi
    fi
  fi

  if [[ "$use_wrapper" == "1" ]]; then
    local plan_key wrapper_command
    plan_key="$(ralph_native_hook_plan_key antigravity-hook)"
    wrapper_command="$(ralph_native_hook_build_wrapper_command \
      "$workspace" \
      "$final_command" \
      "antigravity" \
      "$plan_key")" || {
      if [[ "$rewrite_applied" == "true" ]]; then
        ralph_antigravity_pre_tool_emit_updated_command "$final_command"
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
    ralph_antigravity_pre_tool_emit_updated_command "$wrapper_command"
    return 0
  fi

  if [[ "$rewrite_applied" == "true" ]]; then
    ralph_antigravity_pre_tool_emit_updated_command "$final_command"
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

ralph_antigravity_pre_tool_main
