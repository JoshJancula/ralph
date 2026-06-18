#!/usr/bin/env bash
# Shared native tool result compaction for Cursor/Codex post-tool hooks.
# Uses the same envelope/store path as Ralph MCP proxy tools without loading
# proxy policy timeouts, allowlists, or path guards.

if [[ -n "${RALPH_NATIVE_RESULT_COMPACT_LOADED:-}" ]]; then
  return
fi
RALPH_NATIVE_RESULT_COMPACT_LOADED=1

ralph_native_hook_result_compact_truthy() {
  case "${1:-}" in
    1 | true | yes | on) return 0 ;;
    *) return 1 ;;
  esac
}

ralph_native_hook_result_compact_enabled() {
  case "${RALPH_NATIVE_RESULT_COMPACT:-}" in
    0 | false | no | off) return 1 ;;
    1 | true | yes | on) return 0 ;;
  esac
  case "${RALPH_CURSOR_NATIVE_RESULT_HOOK_COMPACT:-}" in
    0 | false | no | off) return 1 ;;
    1 | true | yes | on) return 0 ;;
  esac
  ralph_native_hook_result_compact_truthy "${RALPH_BASH_COMPACT:-}" && return 0
  ralph_native_hook_result_compact_truthy "${RALPH_PROXY_SHELL_COMPACT:-}" && return 0
  return 1
}

ralph_native_hook_result_preview_max_bytes() {
  local cap="${RALPH_NATIVE_RESULT_PREVIEW_MAX_BYTES:-${RALPH_HOOK_RESULT_BYTE_CAP:-16384}}"
  if [[ "$cap" =~ ^[0-9]+$ ]] && [[ "$cap" -gt 0 ]]; then
    printf '%s\n' "$cap"
  else
    printf '16384\n'
  fi
}

ralph_native_hook_result_compact_configure_caps() {
  local byte_cap
  byte_cap="$(ralph_native_hook_result_preview_max_bytes)"
  export RALPH_HOOK_RESULT_BYTE_CAP="$byte_cap"
  export RALPH_HOOK_RESULT_TOKEN_CAP="${RALPH_HOOK_RESULT_TOKEN_CAP:-0}"
  export RALPH_MCP_PROXY_POLICY_RESULT_BYTE_CAP="$byte_cap"
  export RALPH_MCP_PROXY_POLICY_RESULT_TOKEN_CAP=0
  export RALPH_MCP_PROXY_POLICY_TOOL_RESULT_BYTE_CAPS_JSON='{}'
  export RALPH_MCP_PROXY_POLICY_TOOL_RESULT_TOKEN_CAPS_JSON='{}'
  export RALPH_MCP_PROXY_RESULT_ENVELOPE_MODE=1
}

ralph_native_hook_result_compact_load_libs() {
  local workspace="${1:-}"
  local lib_dir
  lib_dir="$(ralph_native_hook_resolve_bash_lib_dir "$workspace" 2>/dev/null || true)"
  [[ -n "$lib_dir" && -d "$lib_dir" ]] || return 1
  ralph_native_hook_result_compact_configure_caps
  # shellcheck source=/dev/null
  source "$lib_dir/mcp-proxy/mcp-proxy-result-store.sh" || return 1
  # shellcheck source=/dev/null
  source "$lib_dir/mcp-proxy/mcp-proxy-result.sh" || return 1
  # shellcheck source=/dev/null
  source "$lib_dir/mcp-proxy/mcp-proxy-tools.sh" || return 1
  # shellcheck source=/dev/null
  source "$lib_dir/hook-telemetry.sh" 2>/dev/null || true
  return 0
}

ralph_native_hook_normalize_exploration_tool_name() {
  local raw="${1:-}"
  case "$raw" in
    Read|read|readToolCall|ReadToolCall|read_file) printf 'Read\n' ;;
    Grep|grep|grepToolCall|GrepToolCall|grep_files) printf 'Grep\n' ;;
    Glob|glob|globToolCall|GlobToolCall|glob_file_search) printf 'Glob\n' ;;
    SemanticSearch|semanticSearch|semanticSearchToolCall|search) printf 'SemanticSearch\n' ;;
    *) printf '%s\n' "$raw" ;;
  esac
}

ralph_native_hook_native_to_proxy_tool() {
  local tool_name="${1:-}"
  case "$tool_name" in
    Read) printf 'ralph_proxy_read\n' ;;
    Grep) printf 'ralph_proxy_grep\n' ;;
    Glob) printf 'ralph_proxy_glob\n' ;;
    SemanticSearch) printf 'ralph_proxy_search\n' ;;
    *) printf 'native:%s\n' "$tool_name" ;;
  esac
}

ralph_native_hook_is_native_exploration_tool() {
  local tool_name="${1:-}"
  case "$tool_name" in
    Read | Grep | Glob | SemanticSearch) return 0 ;;
    *) return 1 ;;
  esac
}

ralph_native_hook_extract_tool_output_text() {
  local output_json="${1:-}"
  [[ -n "$output_json" ]] || return 1
  if ! jq -e . <<<"$output_json" >/dev/null 2>&1; then
    printf '%s' "$output_json"
    return 0
  fi
  local text
  text="$(jq -r '
    if (.content | type) == "string" and ((.content // "") | length) > 0 then .content
    elif (.content | type) == "array" and ((.content[0].text // "") | length) > 0 then .content[0].text
    elif ((.success.content // "") | length) > 0 then .success.content
    elif ((.result.success.content // "") | length) > 0 then .result.success.content
    elif ((.text // "") | length) > 0 then .text
    elif (.output | type) == "string" then .output
    else empty end
  ' <<<"$output_json")"
  [[ -n "$text" ]] || return 1
  printf '%s' "$text"
}

# Backward-compatible alias for Cursor hook callers.
ralph_native_hook_extract_cursor_tool_output_text() {
  ralph_native_hook_extract_tool_output_text "$@"
}

ralph_native_hook_emit_claude_exploration_updated_output() {
  local compact_text="${1:-}" original_json="${2:-}"
  if jq -e 'type == "object"' <<<"$original_json" >/dev/null 2>&1; then
    if jq -e '.content | type == "string"' <<<"$original_json" >/dev/null 2>&1; then
      jq -nc --arg text "$compact_text" --argjson orig "$original_json" \
        '{hookSpecificOutput: {hookEventName: "PostToolUse", updatedToolOutput: ($orig | .content = $text)}}'
      return 0
    fi
    if jq -e '.content | type == "array"' <<<"$original_json" >/dev/null 2>&1; then
      jq -nc --arg text "$compact_text" --argjson orig "$original_json" \
        '{hookSpecificOutput: {hookEventName: "PostToolUse", updatedToolOutput: ($orig | .content = [{type: "text", text: $text}])}}'
      return 0
    fi
    jq -nc --arg text "$compact_text" --argjson orig "$original_json" \
      '{hookSpecificOutput: {hookEventName: "PostToolUse", updatedToolOutput: ($orig + {content: $text})}}'
    return 0
  fi
  jq -nc --arg text "$compact_text" \
    '{hookSpecificOutput: {hookEventName: "PostToolUse", updatedToolOutput: $text}}'
}

ralph_native_hook_emit_post_tool_compact_output() {
  local compact_text="${1:-}" output_json="${2:-}" hook_input="${3:-}"
  if jq -e '.tool_output' <<<"$hook_input" >/dev/null 2>&1; then
    ralph_native_hook_emit_cursor_updated_tool_output "$compact_text" "$output_json"
    return 0
  fi
  ralph_native_hook_emit_claude_exploration_updated_output "$compact_text" "$output_json"
}

ralph_native_hook_post_tool_event_is_result_compact() {
  local event="${1:-}"
  case "$event" in
    PostToolUse | postToolUse) return 0 ;;
    *) return 1 ;;
  esac
}

ralph_native_hook_workspace_from_hook_input() {
  local hook_input="${1:-}"
  if [[ -n "${WORKSPACE:-}" ]]; then
    printf '%s\n' "$WORKSPACE"
    return 0
  fi
  local root
  root="$(jq -r '.workspace_roots[0] // .cwd // empty' <<<"$hook_input")"
  if [[ -n "$root" ]]; then
    printf '%s\n' "$root"
    return 0
  fi
  if declare -F ralph_native_hook_project_dir >/dev/null 2>&1; then
    local _ralph_hook_input="$hook_input"
    root="$(ralph_native_hook_project_dir CLAUDE_PROJECT_DIR _ralph_hook_input 2>/dev/null || true)"
    if [[ -n "$root" ]]; then
      printf '%s\n' "$root"
      return 0
    fi
  fi
  return 1
}

ralph_native_hook_plan_key_from_env() {
  local fallback="${1:-native-result-hook}"
  if [[ -n "${RALPH_PLAN_KEY:-}" ]]; then
    printf '%s\n' "$RALPH_PLAN_KEY"
    return 0
  fi
  if [[ -n "${RALPH_ARTIFACT_NS:-}" ]]; then
    printf '%s\n' "$RALPH_ARTIFACT_NS"
    return 0
  fi
  printf '%s\n' "$fallback"
}

ralph_native_hook_post_tool_native_result_compact_fail_open() {
  exit 0
}

ralph_native_hook_post_tool_native_result_compact_main() {
  local hook_input="${1:-}"
  [[ -n "$hook_input" ]] || ralph_native_hook_post_tool_native_result_compact_fail_open

  ralph_native_hook_result_compact_enabled || ralph_native_hook_post_tool_native_result_compact_fail_open
  command -v jq >/dev/null 2>&1 || ralph_native_hook_post_tool_native_result_compact_fail_open

  local event tool_name output_json text workspace plan_key proxy_tool compact_text
  event="$(jq -r '.hook_event_name // ""' <<<"$hook_input")"
  ralph_native_hook_post_tool_event_is_result_compact "$event" \
    || ralph_native_hook_post_tool_native_result_compact_fail_open

  tool_name="$(jq -r '.tool_name // ""' <<<"$hook_input")"
  tool_name="$(ralph_native_hook_normalize_exploration_tool_name "$tool_name")"
  ralph_native_hook_is_native_exploration_tool "$tool_name" \
    || ralph_native_hook_post_tool_native_result_compact_fail_open

  if jq -e '.tool_output' <<<"$hook_input" >/dev/null 2>&1; then
    output_json="$(jq -c '.tool_output' <<<"$hook_input")"
  elif jq -e '.tool_response' <<<"$hook_input" >/dev/null 2>&1; then
    output_json="$(jq -c '.tool_response' <<<"$hook_input")"
  else
    ralph_native_hook_post_tool_native_result_compact_fail_open
  fi
  [[ -n "$output_json" ]] || ralph_native_hook_post_tool_native_result_compact_fail_open

  text="$(ralph_native_hook_extract_tool_output_text "$output_json")" \
    || ralph_native_hook_post_tool_native_result_compact_fail_open

  workspace="$(ralph_native_hook_workspace_from_hook_input "$hook_input")" \
    || ralph_native_hook_post_tool_native_result_compact_fail_open
  plan_key="$(ralph_native_hook_plan_key_from_env "native-result-hook")"
  ralph_native_hook_result_compact_load_libs "$workspace" \
    || ralph_native_hook_post_tool_native_result_compact_fail_open

  proxy_tool="$(ralph_native_hook_native_to_proxy_tool "$tool_name")"
  compact_text="$(ralph_native_hook_compact_text_result "$workspace" "$plan_key" "$proxy_tool" "$text")" \
    || ralph_native_hook_post_tool_native_result_compact_fail_open

  ralph_native_hook_emit_post_tool_compact_output "$compact_text" "$output_json" "$hook_input"
}

ralph_native_hook_native_result_compact_cli_main() {
  local payload="${1:-}"
  [[ -n "$payload" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  ralph_native_hook_result_compact_enabled || return 0

  local tool_name text workspace plan_key proxy_tool compact_text hook_input
  tool_name="$(jq -r '.tool_name // ""' <<<"$payload")"
  text="$(jq -r '.text // ""' <<<"$payload")"
  workspace="$(jq -r '.workspace // empty' <<<"$payload")"
  plan_key="$(jq -r '.plan_key // empty' <<<"$payload")"
  [[ -n "$text" ]] || return 0

  tool_name="$(ralph_native_hook_normalize_exploration_tool_name "$tool_name")"
  ralph_native_hook_is_native_exploration_tool "$tool_name" || return 0

  [[ -n "$workspace" ]] || workspace="$(ralph_native_hook_workspace_from_hook_input "{}")" || return 0
  [[ -n "$plan_key" ]] || plan_key="$(ralph_native_hook_plan_key_from_env "opencode-native-result")"

  ralph_native_hook_result_compact_load_libs "$workspace" || return 0
  proxy_tool="$(ralph_native_hook_native_to_proxy_tool "$tool_name")"
  compact_text="$(ralph_native_hook_compact_text_result "$workspace" "$plan_key" "$proxy_tool" "$text")" \
    || return 0

  jq -nc --arg text "$compact_text" '{applied: true, compacted: $text}'
}

ralph_native_hook_emit_cursor_updated_tool_output() {
  local compact_text="${1:-}" original_json="${2:-}"
  if jq -e '.success.content' <<<"$original_json" >/dev/null 2>&1; then
    jq -nc --arg text "$compact_text" --argjson orig "$original_json" \
      '{updated_tool_output: ($orig | .success.content = $text)}'
    return 0
  fi
  if jq -e '.content[0].text' <<<"$original_json" >/dev/null 2>&1; then
    jq -nc --arg text "$compact_text" --argjson orig "$original_json" \
      '{updated_tool_output: ($orig | .content[0].text = $text)}'
    return 0
  fi
  jq -nc --arg text "$compact_text" '{updated_tool_output: {content: $text}}'
}

ralph_native_hook_compact_text_result() {
  local workspace="${1:-}" plan_key="${2:-}" proxy_tool="${3:-}" text="${4:-}"
  local byte_cap original_bytes compact_result shaped_json

  [[ -n "$workspace" && -n "$text" ]] || return 1
  byte_cap="$(ralph_mcp_proxy_result_byte_cap_for_tool "$proxy_tool" 2>/dev/null || ralph_native_hook_result_preview_max_bytes)"
  original_bytes=${#text}

  if declare -F ralph_mcp_proxy_result_envelope_validate_json >/dev/null 2>&1 \
    && ralph_mcp_proxy_result_envelope_validate_json "$text" 2>/dev/null; then
    return 1
  fi

  if [[ "$byte_cap" =~ ^[0-9]+$ ]] && [[ "$byte_cap" -gt 0 ]] && [[ "$original_bytes" -le "$byte_cap" ]]; then
    return 1
  fi

  export RALPH_MCP_WORKSPACE="$workspace"
  export RALPH_PLAN_KEY="$plan_key"

  compact_result="$(ralph_mcp_proxy_owned_tool_maybe_envelope_text_result \
    "$workspace" \
    "$proxy_tool" \
    "$text" \
    0 \
    "$text")"
  [[ -n "$compact_result" ]] || return 1

  shaped_json="$(jq -r '.content[0].text // empty' <<<"$compact_result")"
  [[ -n "$shaped_json" ]] || return 1
  if [[ "$shaped_json" == "$text" ]]; then
    return 1
  fi

  if declare -F ralph_hook_telemetry_append_windowing_log >/dev/null 2>&1; then
    local telemetry_returned_bytes="${#shaped_json}"
    local telemetry_original_tokens="" telemetry_returned_tokens=""
    if declare -F ralph_mcp_proxy_result_estimate_tokens >/dev/null 2>&1; then
      telemetry_original_tokens="$(ralph_mcp_proxy_result_estimate_tokens "$text" 2>/dev/null || true)"
      telemetry_returned_tokens="$(ralph_mcp_proxy_result_estimate_tokens "$shaped_json" 2>/dev/null || true)"
    fi
    ralph_hook_telemetry_append_windowing_log \
      "$workspace" \
      "$plan_key" \
      "$proxy_tool" \
      "$original_bytes" \
      "$telemetry_returned_bytes" \
      "$telemetry_original_tokens" \
      "$telemetry_returned_tokens" \
      "$byte_cap"
  fi

  printf '%s\n' "$shaped_json"
  return 0
}
