#!/usr/bin/env bash
# PreToolUse:Bash adapter for Codex: wrapper-based native shell compaction via
# shared native-shell-wrapper (pre-tool command rewrite).
#
# Proven on Codex CLI 0.136.0 (2026-06-04, via T5):
# - PreToolUse:Bash input rewrite via updatedInput.command (permissionDecision: allow).
# - Wrapper-based compaction (T5, T3, T1): eligible commands rewrite to native-shell-wrapper
#   invocation; wrapper captures/compacts output and stores originals in
#   .ralph-workspace/tool-results/<plan-key>/ for retrieval via ralph_proxy_result_*.
# - PostToolUse:Bash lifecycle hook exists (T4 proven). Model-visible native shell
#   replacement via PostToolUse is not proven (real smoke test pending).
#   post-tool-bash-telemetry.sh is observability-only.
#
# Gates: RALPH_NATIVE_SHELL_WRAPPER=1 (default on when Ralph enables Codex native hooks via T5)
#        RALPH_BASH_REWRITE=1 for fallback simple rewrite when wrapper is off.
# Fail-open: wrapper load/storage failures or gate off -> raw command execution.

set -uo pipefail

ralph_codex_pre_tool_truthy() {
  case "${1:-}" in
    1 | true | yes | on) return 0 ;;
    *) return 1 ;;
  esac
}

ralph_codex_pre_tool_shell_name() {
  case "${1:-}" in
    Bash | command_execution) return 0 ;;
    *) return 1 ;;
  esac
}

ralph_codex_pre_tool_fail_open() {
  exit 0
}

ralph_codex_pre_tool_workspace() {
  if [[ -n "${WORKSPACE:-}" ]]; then
    printf '%s\n' "$WORKSPACE"
    return 0
  fi
  jq -r '.cwd // empty' <<<"${RALPH_CODEX_PRE_TOOL_INPUT:-{}}"
}

ralph_codex_pre_tool_plan_key() {
  if [[ -n "${RALPH_PLAN_KEY:-}" ]]; then
    printf '%s\n' "$RALPH_PLAN_KEY"
    return 0
  fi
  if [[ -n "${RALPH_ARTIFACT_NS:-}" ]]; then
    printf '%s\n' "$RALPH_ARTIFACT_NS"
    return 0
  fi
  printf 'codex-hook\n'
}

ralph_codex_pre_tool_append_log() {
  local workspace="${1:-}" original_command="${2:-}" rewritten_command="${3:-}" rule_id="${4:-}"
  local plan_key telemetry_lib
  [[ -n "${RALPH_BASH_REWRITE_LOG:-}" ]] || return 0
  plan_key="$(ralph_codex_pre_tool_plan_key)"
  telemetry_lib="$(ralph_native_hook_resolve_bash_lib "$workspace" "hook-telemetry.sh" 2>/dev/null || true)"
  if [[ -z "$telemetry_lib" || ! -f "$telemetry_lib" ]]; then
    return 0
  fi
  # shellcheck source=/dev/null
  source "$telemetry_lib"
  ralph_hook_telemetry_append_rewrite_log \
    "$workspace" \
    "$plan_key" \
    "$original_command" \
    "$rewritten_command" \
    "$rule_id" \
    true
}

ralph_codex_pre_tool_try_wrapper() {
  local command="${1:-}" workspace="${2:-}" plan_key="${3:-}"
  local wrapper_cmd

  declare -F ralph_native_hook_build_wrapper_command >/dev/null 2>&1 || return 1

  wrapper_cmd="$(ralph_native_hook_build_wrapper_command "$workspace" "$command" "codex" "$plan_key")" || return 1
  [[ -n "$wrapper_cmd" ]] || return 1
  printf '%s\n' "$wrapper_cmd"
  return 0
}

ralph_codex_pre_tool_try_rewrite() {
  local command="${1:-}" workspace="${2:-}" plan_key="${3:-}"
  local rewriter_lib rewrite_json rewritten_command rule_id

  rewriter_lib="$(ralph_native_hook_resolve_bash_lib "$workspace" "command-rewriter.sh" 2>/dev/null || true)"
  [[ -n "$rewriter_lib" && -f "$rewriter_lib" ]] || return 1
  # shellcheck source=/dev/null
  source "$rewriter_lib"

  rewrite_json="$(ralph_rewrite_shell_command "$command")" || return 1
  if ! ralph_rewrite_shell_command_applied "$rewrite_json"; then
    return 1
  fi

  rewritten_command="$(jq -r '.rewritten_command // empty' <<<"$rewrite_json")"
  rule_id="$(jq -r '.rule_id // empty' <<<"$rewrite_json")"
  [[ -n "$rewritten_command" ]] || return 1

  ralph_codex_pre_tool_append_log "$workspace" "$command" "$rewritten_command" "$rule_id"
  printf '%s\n' "$rewritten_command"
  return 0
}

ralph_codex_killswitch_mode_off() {
  case "${RALPH_MODE:-no}" in
    no | off | false | 0) return 0 ;;
    *) return 1 ;;
  esac
}

ralph_codex_killswitch_record() {
  local record_path="${RALPH_KILLSWITCH_HOOK_RECORD:-}"
  local tool="${1:-}"
  local decision="${2:-}"
  local applied="${3:-false}"
  [[ -n "$record_path" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -nc \
    --arg runtime "codex" \
    --arg tool "$tool" \
    --arg decision "$decision" \
    --argjson applied "$applied" \
    --arg source "native-hook" \
    '{runtime:$runtime,tool:$tool,decision:$decision,applied:$applied,source:$source}' \
    >>"$record_path" 2>/dev/null || true
}

ralph_codex_killswitch_event_json() {
  local tool="${1:-}"
  local arguments="${2:-}"
  jq -nc \
    --argjson schemaVersion 1 \
    --arg source "native-hook" \
    --arg runtime "codex" \
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

ralph_codex_killswitch_from_input() {
  local input_json="${1:-}"
  local workspace="${2:-}"
  local tool command event_json core

  ralph_codex_killswitch_mode_off && {
    ralph_codex_killswitch_record "$(jq -r '.tool_name // ""' <<<"$input_json")" "skip" false
    return 0
  }

  tool="$(jq -r '.tool_name // ""' <<<"$input_json")"
  command="$(jq -r '.tool_input.command // ""' <<<"$input_json")"
  [[ -n "$workspace" && -n "$tool" ]] || return 0

  core="$(ralph_native_hook_resolve_bash_lib "$workspace" "killswitch/killswitch-core.sh" 2>/dev/null || true)"
  [[ -n "$core" && -f "$core" ]] || return 0
  # shellcheck source=/dev/null
  source "$core"

  event_json="$(ralph_codex_killswitch_event_json "$tool" "$command")" || return 0
  killswitch_evaluate "$event_json" >/dev/null
  ralph_codex_killswitch_record "$tool" "${KILLSWITCH_DECISION:-allow}" "$([ "${KILLSWITCH_DECISION:-allow}" = "fatal" ] && echo true || echo false)"
  if [[ "${KILLSWITCH_DECISION:-allow}" == "fatal" ]]; then
    killswitch_apply_decision fatal
  fi
  return 0
}

ralph_codex_pre_tool_main() {
  command -v jq >/dev/null 2>&1 || ralph_codex_pre_tool_fail_open

  RALPH_CODEX_PRE_TOOL_INPUT="$(cat)" || ralph_codex_pre_tool_fail_open

  local event tool_name command
  event="$(jq -r '.hook_event_name // ""' <<<"$RALPH_CODEX_PRE_TOOL_INPUT")"
  tool_name="$(jq -r '.tool_name // ""' <<<"$RALPH_CODEX_PRE_TOOL_INPUT")"
  if [[ "$event" != "PreToolUse" ]] || ! ralph_codex_pre_tool_shell_name "$tool_name"; then
    ralph_codex_killswitch_record "$tool_name" "nudge" false
    ralph_codex_pre_tool_fail_open
  fi

  command="$(jq -r '.tool_input.command // ""' <<<"$RALPH_CODEX_PRE_TOOL_INPUT")"
  [[ -n "$command" ]] || ralph_codex_pre_tool_fail_open

  local workspace plan_key rewritten_command
  workspace="$(ralph_codex_pre_tool_workspace)" || ralph_codex_pre_tool_fail_open
  ralph_codex_killswitch_from_input "$RALPH_CODEX_PRE_TOOL_INPUT" "$workspace"
  command -v python3 >/dev/null 2>&1 || ralph_codex_pre_tool_fail_open
  [[ -n "$workspace" && -d "$workspace" ]] || ralph_codex_pre_tool_fail_open
  plan_key="$(ralph_codex_pre_tool_plan_key)"

  rewritten_command=""

  if ralph_codex_pre_tool_truthy "${RALPH_NATIVE_SHELL_WRAPPER:-}"; then
    rewritten_command="$(ralph_codex_pre_tool_try_wrapper "$command" "$workspace" "$plan_key")" && [[ -n "$rewritten_command" ]] && true
  fi

  if [[ -z "$rewritten_command" ]] && ralph_codex_pre_tool_truthy "${RALPH_BASH_REWRITE:-}"; then
    rewritten_command="$(ralph_codex_pre_tool_try_rewrite "$command" "$workspace" "$plan_key")" && [[ -n "$rewritten_command" ]] && true
  fi

  [[ -n "$rewritten_command" ]] || ralph_codex_pre_tool_fail_open

  jq -nc \
    --arg command "$rewritten_command" \
    '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "allow",
        updatedInput: {command: $command}
      }
    }'
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

ralph_codex_pre_tool_main
