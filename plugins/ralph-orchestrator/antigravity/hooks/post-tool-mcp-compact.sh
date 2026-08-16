#!/usr/bin/env bash
# GENERATED from bundle/.agents/hooks/post-tool-mcp-compact.sh by scripts/sync-plugin-assets.sh - edit the canonical file
# postToolUse MCP adapter: compact Ralph MCP proxy tool results via updated_mcp_tool_output.
#
# Headless proof (cursor-agent 2026.06.03-0bbb28e, 2026-06-04): postToolUse with
# updated_mcp_tool_output changes agent-visible Ralph MCP tool output on cursor-agent -p.
# Shell output replacement via updated_tool_output remains unproven on this build.
#
# Scopes to Ralph MCP proxy tools only (ralph_proxy_*). Full originals are stored in
# .ralph-workspace/tool-results/<plan-key>/ via the shared result store.
#
# Gate: RALPH_CURSOR_MCP_HOOK_COMPACT=0 opts out. Default on when RALPH_PROXY_SHELL_COMPACT
# is truthy (same default chain as Ralph MCP server compaction). Fail-open: never blocks.

set -uo pipefail

ralph_cursor_mcp_compact_truthy() {
  case "${1:-}" in
    1 | true | yes | on) return 0 ;;
    *) return 1 ;;
  esac
}

ralph_cursor_mcp_compact_fail_open() {
  exit 0
}

ralph_cursor_mcp_compact_enabled() {
  case "${RALPH_CURSOR_MCP_HOOK_COMPACT:-}" in
    0 | false | no | off) return 1 ;;
    1 | true | yes | on) return 0 ;;
  esac
  ralph_cursor_mcp_compact_truthy "${RALPH_PROXY_SHELL_COMPACT:-}"
}

ralph_cursor_mcp_compact_workspace() {
  if [[ -n "${WORKSPACE:-}" ]]; then
    printf '%s\n' "$WORKSPACE"
    return 0
  fi
  local root
  root="$(jq -r '.workspace_roots[0] // .cwd // empty' <<<"${RALPH_CURSOR_MCP_COMPACT_INPUT:-{}}")"
  [[ -n "$root" ]] || return 1
  printf '%s\n' "$root"
}

ralph_cursor_mcp_compact_plan_key() {
  if [[ -n "${RALPH_PLAN_KEY:-}" ]]; then
    printf '%s\n' "$RALPH_PLAN_KEY"
    return 0
  fi
  if [[ -n "${RALPH_ARTIFACT_NS:-}" ]]; then
    printf '%s\n' "$RALPH_ARTIFACT_NS"
    return 0
  fi
  printf 'cursor-mcp-hook\n'
}

ralph_cursor_mcp_compact_normalize_tool_name() {
  local raw="${1:-}"
  raw="${raw#MCP:}"
  raw="${raw#ralph-}"
  printf '%s\n' "$raw"
}

ralph_cursor_mcp_compact_is_ralph_proxy_tool() {
  local tool_name="${1:-}"
  case "$tool_name" in
    ralph_proxy_read | ralph_proxy_grep | ralph_proxy_glob | ralph_proxy_shell) return 0 ;;
    *) return 1 ;;
  esac
}

ralph_cursor_mcp_compact_load_libs() {
  local workspace="${1:-}"
  local lib_dir server_script
  lib_dir="$(ralph_native_hook_resolve_bash_lib_dir "$workspace" 2>/dev/null || true)"
  [[ -n "$lib_dir" && -d "$lib_dir" ]] || return 1
  # shellcheck source=/dev/null
  source "$lib_dir/mcp-proxy/mcp-proxy-policy.sh" || return 1
  # shellcheck source=/dev/null
  source "$lib_dir/mcp-proxy/mcp-proxy-result-store.sh" || return 1
  # shellcheck source=/dev/null
  source "$lib_dir/mcp-proxy/mcp-proxy-result.sh" || return 1
  # shellcheck source=/dev/null
  source "$lib_dir/mcp-proxy/mcp-proxy-tools.sh" || return 1
  # shellcheck source=/dev/null
  source "$lib_dir/hook-telemetry.sh" 2>/dev/null || true
  server_script="$(ralph_native_hook_resolve_ralph_script "$workspace" "mcp-server.sh" 2>/dev/null || true)"
  if [[ -z "$server_script" || ! -f "$server_script" ]]; then
    server_script="${RALPH_DIR:-}/mcp-server.sh"
  fi
  if [[ -z "$server_script" || ! -f "$server_script" ]]; then
    return 1
  fi
  ralph_mcp_proxy_load_policy "$workspace" "$server_script" || return 1
  return 0
}

ralph_cursor_mcp_compact_emit_updated_output() {
  local mcp_result_json="${1:-}"
  jq -nc --argjson output "$mcp_result_json" '{updated_mcp_tool_output: $output}'
}

ralph_cursor_mcp_compact_main() {
  ralph_cursor_mcp_compact_enabled || ralph_cursor_mcp_compact_fail_open
  command -v jq >/dev/null 2>&1 || ralph_cursor_mcp_compact_fail_open

  RALPH_CURSOR_MCP_COMPACT_INPUT="$(cat)" || ralph_cursor_mcp_compact_fail_open

  local event tool_name raw_tool output_json text workspace plan_key lib_dir
  event="$(jq -r '.hook_event_name // ""' <<<"$RALPH_CURSOR_MCP_COMPACT_INPUT")"
  tool_name="$(jq -r '.tool_name // ""' <<<"$RALPH_CURSOR_MCP_COMPACT_INPUT")"
  if [[ "$event" != "postToolUse" ]]; then
    ralph_cursor_mcp_compact_fail_open
  fi

  raw_tool="$(ralph_cursor_mcp_compact_normalize_tool_name "$tool_name")"
  ralph_cursor_mcp_compact_is_ralph_proxy_tool "$raw_tool" || ralph_cursor_mcp_compact_fail_open

  output_json="$(jq -r '.tool_output // empty' <<<"$RALPH_CURSOR_MCP_COMPACT_INPUT")"
  [[ -n "$output_json" ]] || ralph_cursor_mcp_compact_fail_open
  if ! jq -e . <<<"$output_json" >/dev/null 2>&1; then
    ralph_cursor_mcp_compact_fail_open
  fi

  text="$(jq -r '.content[0].text // empty' <<<"$output_json")"
  [[ -n "$text" ]] || ralph_cursor_mcp_compact_fail_open

  workspace="$(ralph_cursor_mcp_compact_workspace)" || ralph_cursor_mcp_compact_fail_open
  plan_key="$(ralph_cursor_mcp_compact_plan_key)"
  ralph_cursor_mcp_compact_load_libs "$workspace" || ralph_cursor_mcp_compact_fail_open

  export RALPH_MCP_WORKSPACE="$workspace"
  export RALPH_PLAN_KEY="$plan_key"
  export RALPH_MCP_PROXY_POLICY_OWNED_TOOLS_ENABLED=1
  export RALPH_MCP_PROXY_RESULT_ENVELOPE_MODE=1

  if declare -F ralph_mcp_proxy_result_envelope_validate_json >/dev/null 2>&1 \
    && ralph_mcp_proxy_result_envelope_validate_json "$text" 2>/dev/null; then
    ralph_cursor_mcp_compact_fail_open
  fi

  local shaped_json compact_result original_bytes byte_cap
  byte_cap="$(ralph_mcp_proxy_result_byte_cap_for_tool "$raw_tool" 2>/dev/null || printf '0')"
  original_bytes=${#text}
  if [[ "$byte_cap" =~ ^[0-9]+$ ]] && [[ "$byte_cap" -gt 0 ]] && [[ "$original_bytes" -le "$byte_cap" ]]; then
    ralph_cursor_mcp_compact_fail_open
  fi

  compact_result="$(ralph_mcp_proxy_owned_tool_maybe_envelope_text_result \
    "$workspace" \
    "$raw_tool" \
    "$text" \
    0 \
    "$text")"
  [[ -n "$compact_result" ]] || ralph_cursor_mcp_compact_fail_open

  shaped_json="$(jq -r '.content[0].text // empty' <<<"$compact_result")"
  [[ -n "$shaped_json" ]] || ralph_cursor_mcp_compact_fail_open
  if [[ "$shaped_json" == "$text" ]]; then
    ralph_cursor_mcp_compact_fail_open
  fi

  if declare -F ralph_hook_telemetry_append_windowing_log >/dev/null 2>&1; then
    local telemetry_original_bytes="$original_bytes" telemetry_returned_bytes="${#shaped_json}"
    local telemetry_original_tokens="" telemetry_returned_tokens="" telemetry_token_cap=0
    if [[ "$byte_cap" =~ ^[0-9]+$ ]] && [[ "$byte_cap" -gt 0 ]] && [[ "$telemetry_original_bytes" -gt "$byte_cap" ]]; then
      telemetry_token_cap=1
    fi
    if declare -F ralph_mcp_proxy_result_estimate_tokens >/dev/null 2>&1; then
      telemetry_original_tokens="$(ralph_mcp_proxy_result_estimate_tokens "$text" 2>/dev/null || true)"
      telemetry_returned_tokens="$(ralph_mcp_proxy_result_estimate_tokens "$shaped_json" 2>/dev/null || true)"
    fi
    ralph_hook_telemetry_append_windowing_log \
      "$workspace" \
      "$plan_key" \
      "$raw_tool" \
      "$telemetry_original_bytes" \
      "$telemetry_returned_bytes" \
      "$telemetry_original_tokens" \
      "$telemetry_returned_tokens" \
      "$telemetry_token_cap"
  fi

  ralph_cursor_mcp_compact_emit_updated_output "$compact_result"
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

ralph_cursor_mcp_compact_main || ralph_cursor_mcp_compact_fail_open
