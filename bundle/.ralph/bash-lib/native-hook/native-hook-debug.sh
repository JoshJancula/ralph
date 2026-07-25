#!/usr/bin/env bash
# Shared fail-open debug writer for native-hook compaction (PLAN15).
#
# Appends one JSONL record per actionable failure only when
# RALPH_NATIVE_HOOK_DEBUG_LOG is set to a writable path. Silent (no stdout,
# no stderr) in every case, including an unset/empty path, an unwritable
# path, or a jq failure: this writer must never cause a hook to behave
# differently or emit visible output.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

if [[ -n "${RALPH_NATIVE_HOOK_DEBUG_LOADED:-}" ]]; then
  return
fi
RALPH_NATIVE_HOOK_DEBUG_LOADED=1

# Minimal dependency-free JSON string escaper (no jq required): escapes
# backslash, double-quote, and control characters. Used only as a fallback
# when jq itself is unavailable, since "missing_jq" is one of the reasons
# this writer must be able to record.
_ralph_native_hook_debug_json_escape() {
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="$(printf '%s' "$s" | tr '\n\t\r' '   ')"
  printf '%s' "$s"
}

# Args: reason_code runtime_hook tool_name reason_text
# reason_code: short stable machine token, e.g. "missing_jq", "malformed_input".
# runtime_hook: e.g. "claude:native_result_hook", "cursor:native_result_hook".
# tool_name: surfaced tool name, or empty when not yet known.
# reason_text: short human-readable non-sensitive detail (no payload content).
ralph_native_hook_debug_log() {
  local reason_code="${1:-}" runtime_hook="${2:-}" tool_name="${3:-}" reason_text="${4:-}"
  local log_path="${RALPH_NATIVE_HOOK_DEBUG_LOG:-}"
  [[ -n "$log_path" ]] || return 0

  local dir
  dir="$(dirname -- "$log_path")" 2>/dev/null || return 0
  [[ -d "$dir" ]] || mkdir -p -- "$dir" 2>/dev/null || return 0

  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown')"

  local line=""
  if command -v jq >/dev/null 2>&1; then
    line="$(jq -nc \
      --arg ts "$ts" \
      --arg runtime_hook "$runtime_hook" \
      --arg tool_name "$tool_name" \
      --arg reason_code "$reason_code" \
      --arg reason_text "$reason_text" \
      '{timestamp: $ts, runtimeHook: $runtime_hook, toolName: $tool_name, reasonCode: $reason_code, reason: $reason_text}' \
      2>/dev/null)" || line=""
  fi
  if [[ -z "$line" ]]; then
    line="$(printf '{"timestamp":"%s","runtimeHook":"%s","toolName":"%s","reasonCode":"%s","reason":"%s"}' \
      "$(_ralph_native_hook_debug_json_escape "$ts")" \
      "$(_ralph_native_hook_debug_json_escape "$runtime_hook")" \
      "$(_ralph_native_hook_debug_json_escape "$tool_name")" \
      "$(_ralph_native_hook_debug_json_escape "$reason_code")" \
      "$(_ralph_native_hook_debug_json_escape "$reason_text")")"
  fi
  [[ -n "$line" ]] || return 0

  printf '%s\n' "$line" >>"$log_path" 2>/dev/null || return 0
  return 0
}
