#!/usr/bin/env bash
# GENERATED from bundle/.claude/hooks/rewrite-bash-command.sh by scripts/sync-plugin-assets.sh - edit the canonical file
# PreToolUse:Bash adapter: rewrite simple shell commands via shared Ralph rewriter,
# and optionally inject run_in_background for learned long_running fingerprints.
#
# The shared registry (bundle/.ralph/python/shell_command_registry.py) holds
# two kinds of rules: match-only rules exist solely to classify a command for
# the compaction layer and never alter the command text; rewrite rules alter
# the command text before it runs. Exactly two rewrite rules exist, and both
# only fire when the user passed no conflicting flags of their own:
#   pytest -> pytest -q --tb=line
#   tsc    -> tsc --pretty false
# tests/python/test_shell_command_registry.py asserts this set stays at
# exactly two rules, so adding or removing a rewrite rule must also update
# this comment and the table in docs/HOOKS.md.
#
# Spike (Claude Code 2.1.158, 2026-05-31):
# - PreToolUse input includes tool_input.command (and optional Bash-only fields).
# - hookSpecificOutput.updatedInput with {command: "..."} replaces tool_input for Bash;
#   preserve other tool_input keys when present.
# - Exit 0 with no stdout leaves the command unchanged.
#
# Spike (Claude Code 2.1.260, 2026-09-04): PreToolUse updatedInput with
# run_in_background: true (command preserved) is honored; the CLI returns a
# background shell id as the tool result so the model knows to retrieve output
# via BashOutput rather than assuming the command produced none.
#
# Gates:
# - Rewrite: RALPH_BASH_REWRITE=1 (no Ralph-mode default; unset => off).
# - Auto-background: the auto_background channel (defaults ON for RALPH_MODE
#   native|hybrid; shares RALPH_BASH_REWRITE for explicit opt-in/opt-out).
# Killswitch evaluation runs first when Ralph mode is on; only fatal applies.
# Telemetry: optional RALPH_BASH_REWRITE_LOG JSONL (command hashes, reason, rewriteApplied).
# rewriteApplied is true when updatedInput is emitted for a command rewrite;
# auto-background may also emit updatedInput without a rewrite.

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

# True when the auto_background channel is effective for Claude under the
# current RALPH_MODE / RALPH_BASH_REWRITE provenance.
ralph_bash_auto_background_effective() {
  local workspace="${1:-}"
  local eff_lib record

  eff_lib="$(ralph_native_hook_resolve_bash_lib "$workspace" "run-plan/run-plan-effective-hook-config.sh" 2>/dev/null || true)"
  [[ -n "$eff_lib" && -f "$eff_lib" ]] || return 1
  # shellcheck source=/dev/null
  source "$eff_lib"
  declare -F ralph_effective_hook_config_resolve >/dev/null 2>&1 || return 1
  record="$(ralph_effective_hook_config_resolve "auto_background" "claude" "${RALPH_MODE:-no}" 2>/dev/null || true)"
  [[ -n "$record" ]] || return 1
  jq -e '.effective == true' <<<"$record" >/dev/null 2>&1
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

  if ! command -v python3 >/dev/null 2>&1; then
    ralph_native_hook_fail_open
  fi

  command="$(jq -r '.tool_input.command // ""' <<<"$RALPH_BASH_REWRITE_INPUT")"
  [[ -n "$command" ]] || ralph_native_hook_fail_open

  project_dir="$(ralph_native_hook_project_dir CLAUDE_PROJECT_DIR RALPH_BASH_REWRITE_INPUT)" || ralph_native_hook_fail_open

  local rewrite_enabled=false auto_bg_effective=false
  if ralph_native_hook_truthy "${RALPH_BASH_REWRITE:-}"; then
    rewrite_enabled=true
  fi
  if ralph_bash_auto_background_effective "$project_dir"; then
    auto_bg_effective=true
  fi
  if [[ "$rewrite_enabled" != "true" && "$auto_bg_effective" != "true" ]]; then
    ralph_native_hook_fail_open
  fi

  local rewritten_command="" rule_id="" rewrite_applied=false
  if [[ "$rewrite_enabled" == "true" ]]; then
    local rewriter_lib rewrite_json
    rewriter_lib="$(ralph_native_hook_resolve_bash_lib "$project_dir" "command-rewriter.sh" 2>/dev/null || true)"
    if [[ -n "$rewriter_lib" && -f "$rewriter_lib" ]]; then
      # shellcheck source=/dev/null
      source "$rewriter_lib"
      rewrite_json="$(ralph_rewrite_shell_command "$command")"
      if ralph_rewrite_shell_command_applied "$rewrite_json"; then
        rewritten_command="$(jq -r '.rewritten_command // empty' <<<"$rewrite_json")"
        rule_id="$(jq -r '.rule_id // empty' <<<"$rewrite_json")"
        if [[ -n "$rewritten_command" ]]; then
          rewrite_applied=true
          local plan_key
          plan_key="$(ralph_native_hook_plan_key bash-hook)"
          ralph_native_hook_append_rewrite_log \
            "$project_dir" \
            "$plan_key" \
            "$command" \
            "$rewritten_command" \
            "$rule_id"
        fi
      fi
    fi
  fi

  local final_command="$command"
  if [[ "$rewrite_applied" == "true" ]]; then
    final_command="$rewritten_command"
  fi

  # Auto-background: query command_profiles for a long_running, non-denylisted
  # fingerprint. Inject run_in_background only when the auto_background channel
  # is effective. The model is informed automatically because the CLI returns a
  # background shell id as the Bash tool result, so the agent retrieves output
  # via BashOutput rather than assuming the command produced none.
  local inject_bg=false
  if [[ "$auto_bg_effective" == "true" ]]; then
    local fingerprint already_bg
    fingerprint="$(ralph_native_hook_command_fingerprint "$project_dir" "$final_command" 2>/dev/null || true)"
    already_bg="$(jq -r '.tool_input.run_in_background // false' <<<"$RALPH_BASH_REWRITE_INPUT")"
    if [[ -n "$fingerprint" ]] && \
      ralph_native_hook_injection_eligible "$project_dir" "$final_command" "$fingerprint" "$already_bg"; then
      inject_bg=true
    fi
  fi

  if [[ "$rewrite_applied" != "true" && "$inject_bg" != "true" ]]; then
    ralph_native_hook_fail_open
  fi

  local updated_input
  if [[ "$rewrite_applied" == "true" && "$inject_bg" == "true" ]]; then
    updated_input="$(
      jq -nc \
        --argjson tool_input "$(jq -c '.tool_input // {}' <<<"$RALPH_BASH_REWRITE_INPUT")" \
        --arg command "$final_command" \
        --argjson run_in_background true \
        '$tool_input + {command: $command, run_in_background: $run_in_background}'
    )"
  elif [[ "$rewrite_applied" == "true" ]]; then
    updated_input="$(
      jq -nc \
        --argjson tool_input "$(jq -c '.tool_input // {}' <<<"$RALPH_BASH_REWRITE_INPUT")" \
        --arg command "$final_command" \
        '$tool_input + {command: $command}'
    )"
  else
    updated_input="$(
      jq -nc \
        --argjson tool_input "$(jq -c '.tool_input // {}' <<<"$RALPH_BASH_REWRITE_INPUT")" \
        --argjson run_in_background true \
        '$tool_input + {run_in_background: $run_in_background}'
    )"
  fi

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
