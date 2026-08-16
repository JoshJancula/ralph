#!/usr/bin/env bash
# GENERATED from bundle/.claude/hooks/rewrite-bash-command.sh by scripts/sync-plugin-assets.sh - edit the canonical file
# PreToolUse:Bash adapter: rewrite simple shell commands via shared Ralph rewriter.
#
# Spike (Claude Code 2.1.158, 2026-05-31):
# - PreToolUse input includes tool_input.command (and optional Bash-only fields).
# - hookSpecificOutput.updatedInput with {command: "..."} replaces tool_input for Bash;
#   preserve other tool_input keys when present.
# - Exit 0 with no stdout leaves the command unchanged.
#
# Gate: RALPH_BASH_REWRITE=1 (default off). Rewrite still fails open.
# Killswitch evaluation runs first when Ralph mode is on; only fatal applies.
# Telemetry: optional RALPH_BASH_REWRITE_LOG JSONL (command hashes, reason, rewriteApplied).
# rewriteApplied is true when updatedInput is emitted; there is no suggest-only hook path.

set -uo pipefail

ralph_claude_killswitch_mode_off() {
  case "${RALPH_MODE:-no}" in
    no | off | false | 0) return 0 ;;
    *) return 1 ;;
  esac
}

ralph_claude_killswitch_record() {
  local record_path="${RALPH_KILLSWITCH_HOOK_RECORD:-}"
  local tool="${1:-}"
  local decision="${2:-}"
  local applied="${3:-false}"
  [[ -n "$record_path" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -nc \
    --arg runtime "claude" \
    --arg tool "$tool" \
    --arg decision "$decision" \
    --argjson applied "$applied" \
    --arg source "native-hook" \
    '{runtime:$runtime,tool:$tool,decision:$decision,applied:$applied,source:$source}' \
    >>"$record_path" 2>/dev/null || true
}

ralph_claude_killswitch_event_json() {
  local tool="${1:-}"
  local arguments="${2:-}"
  local resource="${3:-}"
  jq -nc \
    --argjson schemaVersion 1 \
    --arg source "native-hook" \
    --arg runtime "claude" \
    --arg tool "$tool" \
    --arg action "execute" \
    --arg effect "write" \
    --arg resource "$resource" \
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

ralph_claude_killswitch_from_input() {
  local input_json="${1:-}"
  local workspace="${2:-}"
  local tool command event_json core

  ralph_claude_killswitch_mode_off && {
    ralph_claude_killswitch_record "$(jq -r '.tool_name // ""' <<<"$input_json")" "skip" false
    return 0
  }

  tool="$(jq -r '.tool_name // ""' <<<"$input_json")"
  command="$(jq -r '.tool_input.command // ""' <<<"$input_json")"
  [[ -n "$workspace" && -n "$tool" ]] || return 0

  core="$(ralph_native_hook_resolve_bash_lib "$workspace" "killswitch/killswitch-core.sh" 2>/dev/null || true)"
  [[ -n "$core" && -f "$core" ]] || return 0
  # shellcheck source=/dev/null
  source "$core"

  event_json="$(ralph_claude_killswitch_event_json "$tool" "$command" "")" || return 0
  killswitch_evaluate "$event_json" >/dev/null
  ralph_claude_killswitch_record "$tool" "${KILLSWITCH_DECISION:-allow}" "$([ "${KILLSWITCH_DECISION:-allow}" = "fatal" ] && echo true || echo false)"
  if [[ "${KILLSWITCH_DECISION:-allow}" == "fatal" ]]; then
    killswitch_apply_decision fatal
  fi
  return 0
}

ralph_bash_rewrite_main() {
  if ! command -v jq >/dev/null 2>&1; then
    ralph_native_hook_fail_open
  fi

  RALPH_BASH_REWRITE_INPUT="$(cat)" || ralph_native_hook_fail_open

  local event tool_name command
  event="$(jq -r '.hook_event_name // ""' <<<"$RALPH_BASH_REWRITE_INPUT")"
  tool_name="$(jq -r '.tool_name // ""' <<<"$RALPH_BASH_REWRITE_INPUT")"
  if [[ "$event" != "PreToolUse" || "$tool_name" != "Bash" ]]; then
    ralph_claude_killswitch_record "$tool_name" "nudge" false
    ralph_native_hook_fail_open
  fi

  local project_dir
  project_dir="$(ralph_native_hook_project_dir CLAUDE_PROJECT_DIR RALPH_BASH_REWRITE_INPUT)" || true
  ralph_claude_killswitch_from_input "$RALPH_BASH_REWRITE_INPUT" "${WORKSPACE:-$project_dir}"

  ralph_native_hook_truthy "${RALPH_BASH_REWRITE:-}" || ralph_native_hook_fail_open
  if ! command -v python3 >/dev/null 2>&1; then
    ralph_native_hook_fail_open
  fi

  command="$(jq -r '.tool_input.command // ""' <<<"$RALPH_BASH_REWRITE_INPUT")"
  [[ -n "$command" ]] || ralph_native_hook_fail_open

  local project_dir rewriter_lib rewrite_json rewritten_command rule_id plan_key
  project_dir="$(ralph_native_hook_project_dir CLAUDE_PROJECT_DIR RALPH_BASH_REWRITE_INPUT)" || ralph_native_hook_fail_open
  rewriter_lib="$(ralph_native_hook_resolve_bash_lib "$project_dir" "command-rewriter.sh" 2>/dev/null || true)"
  if [[ -z "$rewriter_lib" || ! -f "$rewriter_lib" ]]; then
    ralph_native_hook_fail_open
  fi
  # shellcheck source=/dev/null
  source "$rewriter_lib"

  rewrite_json="$(ralph_rewrite_shell_command "$command")"
  if ! ralph_rewrite_shell_command_applied "$rewrite_json"; then
    ralph_native_hook_fail_open
  fi

  rewritten_command="$(jq -r '.rewritten_command // empty' <<<"$rewrite_json")"
  rule_id="$(jq -r '.rule_id // empty' <<<"$rewrite_json")"
  [[ -n "$rewritten_command" ]] || ralph_native_hook_fail_open

  plan_key="$(ralph_native_hook_plan_key bash-hook)"
  ralph_native_hook_append_rewrite_log \
    "$project_dir" \
    "$plan_key" \
    "$command" \
    "$rewritten_command" \
    "$rule_id"

  local updated_input
  updated_input="$(
    jq -nc \
      --argjson tool_input "$(jq -c '.tool_input // {}' <<<"$RALPH_BASH_REWRITE_INPUT")" \
      --arg command "$rewritten_command" \
      '$tool_input + {command: $command}'
  )"

  ralph_native_hook_emit_claude_pre_tool_updated_input "$updated_input"
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

ralph_bash_rewrite_main || ralph_native_hook_fail_open
