#!/usr/bin/env bash
# PostToolUse:Bash adapter: compact successful Bash output via shared Ralph compactors.
#
# Spike (Claude Code 2.1.158, 2026-05-31):
# - PostToolUse input includes tool_response.stdout/stderr/interrupted/isImage/noOutputExpected.
# - Non-zero Bash exits fire PostToolUseFailure with error text and no tool_response; output
#   replacement is not available for failures on this version (see docs/ENVIRONMENT.md).
# - hookSpecificOutput.updatedToolOutput with full Bash shape replaces successful output only.
# - Malformed updatedToolOutput (missing required fields) is ignored by Claude Code.
# Telemetry: optional RALPH_BASH_COMPACT_LOG JSONL (original/compacted bytes, command hash,
# storage path, compaction_skipped). See bundle/.ralph/bash-lib/hook-telemetry.sh.
#
# Gate: RALPH_BASH_COMPACT=1 (default on in native/hybrid when Ralph sets it; RALPH_BASH_COMPACT=0 opts out).
# Fail-open: never blocks the agent.

set -uo pipefail

ralph_bash_compact_main() {
  ralph_native_hook_truthy "${RALPH_BASH_COMPACT:-}" || ralph_native_hook_fail_open

  if ! command -v jq >/dev/null 2>&1; then
    ralph_native_hook_debug_log "missing_jq" "claude:bash_hook" "Bash" "jq not found on PATH"
    ralph_native_hook_fail_open
  fi

  RALPH_BASH_COMPACT_INPUT="$(cat)" || ralph_native_hook_fail_open

  local event tool_name command stdout stderr interrupted is_image
  event="$(jq -r '.hook_event_name // ""' <<<"$RALPH_BASH_COMPACT_INPUT")"
  tool_name="$(jq -r '.tool_name // ""' <<<"$RALPH_BASH_COMPACT_INPUT")"
  if [[ "$event" != "PostToolUse" || "$tool_name" != "Bash" ]]; then
    ralph_native_hook_fail_open
  fi

  if ! jq -e '.tool_response | type == "object"' <<<"$RALPH_BASH_COMPACT_INPUT" >/dev/null 2>&1; then
    ralph_native_hook_debug_log "malformed_input" "claude:bash_hook" "Bash" "tool_response is missing or not an object"
    ralph_native_hook_fail_open
  fi

  command="$(jq -r '.tool_input.command // ""' <<<"$RALPH_BASH_COMPACT_INPUT")"
  stdout="$(jq -r '.tool_response.stdout // ""' <<<"$RALPH_BASH_COMPACT_INPUT")"
  stderr="$(jq -r '.tool_response.stderr // ""' <<<"$RALPH_BASH_COMPACT_INPUT")"
  interrupted="$(jq -r '.tool_response.interrupted // false' <<<"$RALPH_BASH_COMPACT_INPUT")"
  is_image="$(jq -r '.tool_response.isImage // false' <<<"$RALPH_BASH_COMPACT_INPUT")"

  local project_dir compactors_lib
  if ! project_dir="$(ralph_native_hook_project_dir CLAUDE_PROJECT_DIR RALPH_BASH_COMPACT_INPUT)"; then
    ralph_native_hook_debug_log "missing_workspace" "claude:bash_hook" "Bash" "could not resolve project directory"
    ralph_native_hook_fail_open
  fi
  compactors_lib="$(ralph_native_hook_resolve_bash_lib "$project_dir" "compactors.sh" 2>/dev/null || true)"
  if [[ -z "$compactors_lib" || ! -f "$compactors_lib" ]]; then
    ralph_native_hook_debug_log "missing_bootstrap_or_library" "claude:bash_hook" "Bash" "compactors.sh not found"
    ralph_native_hook_fail_open
  fi
  # shellcheck source=/dev/null
  source "$compactors_lib"

  export RALPH_COMPACT_STDOUT="$stdout"
  export RALPH_COMPACT_STDERR="$stderr"
  local compact_json compact_stdout compact_stderr
  local plan_key workspace result_path footer storage_text preview_max

  if ! compact_json="$(ralph_compact_shell_output "$command" 0)"; then
    ralph_native_hook_debug_log "compaction_failed" "claude:bash_hook" "Bash" "ralph_compact_shell_output returned failure"
    ralph_native_hook_fail_open
  fi

  plan_key="$(ralph_native_hook_plan_key bash-hook)"
  workspace="$project_dir"
  local plan_key_fallback_reason plan_key_fallback
  plan_key_fallback_reason="$(ralph_native_hook_plan_key_fallback_reason)"
  if [[ -n "$plan_key_fallback_reason" ]]; then
    plan_key_fallback="true"
  else
    plan_key_fallback="false"
  fi

  if ! ralph_compact_shell_output_applied "$compact_json"; then
    # Skipped/no-op compaction: nothing is rewritten, so the delivered
    # content equals the original output eligible to reach the model (never
    # the on-disk stored original, since none is stored on this path).
    local skip_combined skip_delivered_bytes skip_delivered_tokens=""
    skip_combined="$(ralph_native_hook_combine_streams "$stdout" "$stderr")"
    skip_delivered_bytes="$(printf '%s' "$skip_combined" | wc -c | tr -d ' ')"
    if declare -F ralph_token_estimate_text >/dev/null 2>&1; then
      skip_delivered_tokens="$(ralph_token_estimate_text "$skip_combined" 2>/dev/null || true)"
    fi
    ralph_native_hook_append_compact_log \
      "$workspace" \
      "$plan_key" \
      "$command" \
      "$compact_json" \
      "$stdout" \
      "$stderr" \
      "" \
      0 \
      "$plan_key_fallback" \
      "$plan_key_fallback_reason" \
      "$skip_delivered_bytes" \
      "$skip_delivered_tokens"
    ralph_native_hook_fail_open
  fi

  compact_stdout="$(jq -r '.stdout // ""' <<<"$compact_json")"
  compact_stderr="$(jq -r '.stderr // ""' <<<"$compact_json")"

  preview_max="$(ralph_native_hook_preview_max_bytes)"
  ralph_native_hook_cap_stream_pair compact_stdout compact_stderr "$preview_max"

  storage_text="$(ralph_native_hook_original_storage_json "$command" "$stdout" "$stderr" 0)"
  result_path="$(ralph_native_hook_store_original "$workspace" "$plan_key" "$storage_text" "ralph_bash_compact" || true)"

  if [[ -n "$result_path" ]]; then
    footer="$(ralph_native_hook_bash_compact_footer "$result_path")"
  else
    footer=""
  fi

  # Delivered: add the stored-result footer before measuring, since it is
  # part of what actually reaches the model on an applied compaction. Legacy
  # compactedBytes (measured above from pre-footer compact_json) is preserved
  # unchanged for backward compatibility.
  local delivered_stdout delivered_combined delivered_bytes delivered_tokens
  delivered_stdout="$(ralph_native_hook_append_footer_to_stream "$compact_stdout" "$footer")"
  delivered_combined="$(ralph_native_hook_combine_streams "$delivered_stdout" "$compact_stderr")"
  delivered_bytes="$(printf '%s' "$delivered_combined" | wc -c | tr -d ' ')"
  delivered_tokens=""
  if declare -F ralph_token_estimate_text >/dev/null 2>&1; then
    delivered_tokens="$(ralph_token_estimate_text "$delivered_combined" 2>/dev/null || true)"
  fi

  ralph_native_hook_append_compact_log \
    "$workspace" \
    "$plan_key" \
    "$command" \
    "$compact_json" \
    "$stdout" \
    "$stderr" \
    "${result_path:-}" \
    0 \
    "$plan_key_fallback" \
    "$plan_key_fallback_reason" \
    "$delivered_bytes" \
    "$delivered_tokens"

  ralph_native_hook_emit_claude_post_tool_updated_output \
    "$compact_stdout" \
    "$compact_stderr" \
    "$interrupted" \
    "$is_image" \
    "$footer"
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

_NATIVE_HOOK_DEBUG_LIB="${_NATIVE_HOOK_BOOTSTRAP%/*}/native-hook-debug.sh"
if [[ -f "$_NATIVE_HOOK_DEBUG_LIB" ]]; then
  # shellcheck source=/dev/null
  source "$_NATIVE_HOOK_DEBUG_LIB"
fi
if ! declare -F ralph_native_hook_debug_log >/dev/null 2>&1; then
  ralph_native_hook_debug_log() { return 0; }
fi

ralph_bash_compact_main || ralph_native_hook_fail_open
