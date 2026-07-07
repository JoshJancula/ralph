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
    Bash|bash|bashToolCall|shell) printf 'Bash\n' ;;
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
    Bash) printf 'ralph_proxy_shell\n' ;;
    *) printf 'native:%s\n' "$tool_name" ;;
  esac
}

ralph_native_hook_is_native_exploration_tool() {
  local tool_name="${1:-}"
  case "$tool_name" in
    Read | Grep | Glob | SemanticSearch | Bash) return 0 ;;
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
  local context_json
  context_json="$(jq -nc \
    --argjson tool_args "$(jq -c '.tool_input // .tool_args // {}' <<<"$hook_input" 2>/dev/null || printf '{}')" \
    --arg title "$(jq -r '.tool_output.title // .tool_response.title // empty' <<<"$hook_input" 2>/dev/null || true)" \
    --arg path "$(jq -r '.tool_input.path // .tool_args.path // empty' <<<"$hook_input" 2>/dev/null || true)" \
    '{tool_args: $tool_args, title: $title, path: $path}')"
  compact_text="$(ralph_native_hook_compact_text_result \
    "$workspace" \
    "$plan_key" \
    "$proxy_tool" \
    "$text" \
    "$context_json" \
    "$tool_name" \
    "native_result_hook")" \
    || ralph_native_hook_post_tool_native_result_compact_fail_open

  ralph_native_hook_emit_post_tool_compact_output "$compact_text" "$output_json" "$hook_input"
}

ralph_native_hook_native_result_compact_cli_main() {
  local payload="${1:-}"
  [[ -n "$payload" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  ralph_native_hook_result_compact_enabled || return 0

  local tool_name text workspace plan_key proxy_tool compact_text context_json
  tool_name="$(jq -r '.tool_name // ""' <<<"$payload")"
  text="$(jq -r '.text // ""' <<<"$payload")"
  workspace="$(jq -r '.workspace // empty' <<<"$payload")"
  plan_key="$(jq -r '.plan_key // empty' <<<"$payload")"
  context_json="$(jq -c '
    {
      tool_args: (.tool_args // {}),
      title: (.title // ""),
      path: (.path // .tool_args.path // "")
    }
  ' <<<"$payload" 2>/dev/null || printf '{}')"
  [[ -n "$text" ]] || return 0

  tool_name="$(ralph_native_hook_normalize_exploration_tool_name "$tool_name")"
  ralph_native_hook_is_native_exploration_tool "$tool_name" || return 0

  [[ -n "$workspace" ]] || workspace="$(ralph_native_hook_workspace_from_hook_input "{}")" || return 0
  [[ -n "$plan_key" ]] || plan_key="$(ralph_native_hook_plan_key_from_env "opencode-native-result")"

  ralph_native_hook_result_compact_load_libs "$workspace" || return 0
  proxy_tool="$(ralph_native_hook_native_to_proxy_tool "$tool_name")"
  compact_text="$(ralph_native_hook_compact_text_result \
    "$workspace" \
    "$plan_key" \
    "$proxy_tool" \
    "$text" \
    "$context_json" \
    "$tool_name" \
    "native_result_mcp_fallback")" \
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

ralph_native_hook_search_compaction_enabled() {
  case "${RALPH_NATIVE_SEARCH_COMPACT:-}" in
    0 | false | no | off) return 1 ;;
    1 | true | yes | on) return 0 ;;
  esac
  if declare -F ralph_mcp_proxy_contextual_search_enabled >/dev/null 2>&1; then
    ralph_mcp_proxy_contextual_search_enabled && return 0
  fi
  case "${RALPH_MCP_CONTEXTUAL_SEARCH:-}" in
    1 | true | yes | on) return 0 ;;
    0 | false | no | off) return 1 ;;
  esac
  case "${RALPH_MODE:-no}" in
    ralph | hybrid) return 0 ;;
    *) return 1 ;;
  esac
}

ralph_native_hook_context_json_or_empty() {
  local raw="${1:-}"
  if [[ -z "$raw" ]]; then
    printf '%s\n' '{}'
    return 0
  fi
  if jq -e 'type == "object"' <<<"$raw" >/dev/null 2>&1; then
    printf '%s\n' "$raw"
    return 0
  fi
  printf '%s\n' '{}'
}

ralph_native_hook_context_read_path() {
  local context_json path title
  context_json="$(ralph_native_hook_context_json_or_empty "${1:-}")"
  path="$(jq -r '.path // .tool_args.path // empty' <<<"$context_json")"
  if [[ -n "$path" ]]; then
    printf '%s\n' "$path"
    return 0
  fi
  title="$(jq -r '.title // empty' <<<"$context_json")"
  if [[ "$title" =~ ^[Rr]ead[[:space:]]+(.+)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

ralph_native_hook_grep_dedupe_lines() {
  local text="${1:-}"
  [[ -n "$text" ]] || return 0
  awk 'NR == 1 || $0 != prev { print; prev = $0 }' <<<"$text"
}

ralph_native_hook_count_lines() {
  local text="${1:-}"
  if [[ -z "$text" ]]; then
    printf '0\n'
    return 0
  fi
  printf '%s\n' "$text" | wc -l | tr -d ' '
}

ralph_native_hook_prepare_read_envelope() {
  local text="${1:-}" context_json byte_cap="${3:-0}"
  context_json="$(ralph_native_hook_context_json_or_empty "${2:-}")"
  local rel_path line_count byte_count preview_text truncated=0
  local max_lines="${RALPH_MCP_PROXY_POLICY_OWNED_MAX_READ_LINES:-500}"
  local max_bytes="${RALPH_MCP_PROXY_POLICY_OWNED_MAX_READ_BYTES:-65536}"
  local applied_limit="$max_lines"
  local window_text="$text"

  rel_path="$(ralph_native_hook_context_read_path "$context_json" 2>/dev/null || true)"
  line_count="$(ralph_native_hook_count_lines "$text")"
  byte_count=${#text}

  if [[ "$line_count" -gt "$max_lines" ]]; then
    truncated=1
    window_text="$(ralph_mcp_proxy_owned_tool_grep_head_lines "$text" "$max_lines")"
    applied_limit="$max_lines"
  elif [[ "$byte_count" -gt "$max_bytes" ]]; then
    truncated=1
    window_text="${text:0:$max_bytes}"
  fi

  if [[ "$byte_cap" =~ ^[0-9]+$ ]] && [[ "$byte_cap" -gt 0 ]] && [[ "$byte_count" -gt "$byte_cap" ]]; then
    truncated=1
  fi

  preview_text="$window_text"
  if [[ -n "$rel_path" ]]; then
    preview_text="[${rel_path} | lines: ${line_count} | bytes: ${byte_count}]
${window_text}"
  fi

  RALPH_NATIVE_PREP_STORAGE_TEXT="$text"
  RALPH_NATIVE_PREP_PREVIEW_TEXT="$preview_text"
  RALPH_NATIVE_PREP_TRUNCATED="$truncated"
  RALPH_NATIVE_PREP_MATCH_METADATA_JSON='[]'
  RALPH_NATIVE_PREP_PATTERN_OR_QUERY=""
  RALPH_NATIVE_PREP_METADATA_JSON="$(
    jq -nc \
      --arg path "$rel_path" \
      --argjson lineCount "$line_count" \
      --argjson byteCount "$byte_count" \
      --argjson lineLimit "$applied_limit" \
      '{
        storageLayout: "window",
        window: {
          path: (if $path == "" then null else $path end),
          lineCount: $lineCount,
          byteCount: $byteCount,
          lineLimit: $lineLimit
        }
      }'
  )"
  export RALPH_NATIVE_PREP_STORAGE_TEXT RALPH_NATIVE_PREP_PREVIEW_TEXT RALPH_NATIVE_PREP_TRUNCATED
  export RALPH_NATIVE_PREP_MATCH_METADATA_JSON RALPH_NATIVE_PREP_PATTERN_OR_QUERY RALPH_NATIVE_PREP_METADATA_JSON
}

ralph_native_hook_prepare_grep_envelope() {
  local text="${1:-}" context_json byte_cap="${3:-0}"
  context_json="$(ralph_native_hook_context_json_or_empty "${2:-}")"
  local deduped full_text preview_text truncated=0
  local max_matches="${RALPH_MCP_PROXY_POLICY_OWNED_MAX_GREP_MATCHES:-100}"
  local match_count match_metadata_json cluster_metadata_json pattern

  deduped="$(ralph_native_hook_grep_dedupe_lines "$text")"
  full_text="$deduped"
  preview_text="$full_text"
  pattern="$(jq -r '.tool_args.pattern // .pattern // empty' <<<"$context_json")"

  match_count="$(ralph_mcp_proxy_owned_tool_grep_count_lines "$full_text")"
  if [[ "$match_count" -gt "$max_matches" ]]; then
    truncated=1
    preview_text="$(ralph_mcp_proxy_owned_tool_grep_head_lines "$full_text" "$max_matches")"
  fi
  if [[ "$byte_cap" =~ ^[0-9]+$ ]] && [[ "$byte_cap" -gt 0 ]] && [[ "${#preview_text}" -gt "$byte_cap" ]]; then
    truncated=1
  elif [[ "$match_count" -gt "$max_matches" ]]; then
    truncated=1
  fi

  match_metadata_json="$(ralph_mcp_proxy_result_store_match_metadata_from_grep_output "$full_text" 2>/dev/null || true)"
  if [[ -z "$match_metadata_json" ]]; then
    match_metadata_json='[]'
  fi
  cluster_metadata_json="$(ralph_mcp_proxy_result_store_match_clusters_from_metadata "$match_metadata_json" 2>/dev/null || true)"
  if [[ -z "$cluster_metadata_json" ]]; then
    cluster_metadata_json="$match_metadata_json"
  fi

  RALPH_NATIVE_PREP_STORAGE_TEXT="$full_text"
  RALPH_NATIVE_PREP_PREVIEW_TEXT="$preview_text"
  RALPH_NATIVE_PREP_TRUNCATED="$truncated"
  RALPH_NATIVE_PREP_MATCH_METADATA_JSON="$cluster_metadata_json"
  RALPH_NATIVE_PREP_PATTERN_OR_QUERY="$pattern"
  RALPH_NATIVE_PREP_METADATA_JSON='{"storageLayout":"full"}'
  export RALPH_NATIVE_PREP_STORAGE_TEXT RALPH_NATIVE_PREP_PREVIEW_TEXT RALPH_NATIVE_PREP_TRUNCATED
  export RALPH_NATIVE_PREP_MATCH_METADATA_JSON RALPH_NATIVE_PREP_PATTERN_OR_QUERY RALPH_NATIVE_PREP_METADATA_JSON
}

ralph_native_hook_prepare_glob_envelope() {
  local text="${1:-}" context_json byte_cap="${3:-0}"
  context_json="$(ralph_native_hook_context_json_or_empty "${2:-}")"
  local full_text preview_text truncated=0 result_count max_results glob_pattern

  full_text="$text"
  if [[ -n "$full_text" && "$full_text" != *$'\n' ]]; then
    full_text+=$'\n'
  fi
  max_results="${RALPH_MCP_PROXY_POLICY_OWNED_MAX_GLOB_RESULTS:-200}"
  glob_pattern="$(jq -r '.tool_args.glob_pattern // .tool_args.pattern // .glob_pattern // empty' <<<"$context_json")"
  result_count="$(ralph_mcp_proxy_owned_tool_glob_count_paths "$full_text")"
  preview_text="$full_text"

  if [[ "$result_count" -gt "$max_results" ]]; then
    truncated=1
    preview_text="$(ralph_mcp_proxy_owned_tool_grep_head_lines "$full_text" "$max_results")"
    preview_text="glob: ${result_count} path(s); showing first ${max_results}
${preview_text}"
  fi
  if [[ "$byte_cap" =~ ^[0-9]+$ ]] && [[ "$byte_cap" -gt 0 ]] && [[ "${#preview_text}" -gt "$byte_cap" ]]; then
    truncated=1
  elif [[ "$result_count" -gt "$max_results" ]]; then
    truncated=1
  fi

  RALPH_NATIVE_PREP_STORAGE_TEXT="$full_text"
  RALPH_NATIVE_PREP_PREVIEW_TEXT="$preview_text"
  RALPH_NATIVE_PREP_TRUNCATED="$truncated"
  RALPH_NATIVE_PREP_MATCH_METADATA_JSON='[]'
  RALPH_NATIVE_PREP_PATTERN_OR_QUERY="$glob_pattern"
  RALPH_NATIVE_PREP_METADATA_JSON='{"storageLayout":"full"}'
  export RALPH_NATIVE_PREP_STORAGE_TEXT RALPH_NATIVE_PREP_PREVIEW_TEXT RALPH_NATIVE_PREP_TRUNCATED
  export RALPH_NATIVE_PREP_MATCH_METADATA_JSON RALPH_NATIVE_PREP_PATTERN_OR_QUERY RALPH_NATIVE_PREP_METADATA_JSON
}

ralph_native_hook_prepare_search_envelope() {
  local text="${1:-}" context_json byte_cap="${3:-0}"
  context_json="$(ralph_native_hook_context_json_or_empty "${2:-}")"
  local query full_text preview_text truncated=0
  local max_results="${RALPH_MCP_PROXY_POLICY_OWNED_MAX_SEARCH_RESULTS:-50}"
  local tmp_candidates tmp_ranked tmp_compact match_metadata_json cluster_metadata_json
  local candidate_count match_count

  query="$(jq -r '.tool_args.query // .query // empty' <<<"$context_json")"
  full_text="$text"
  preview_text="$full_text"

  if ralph_native_hook_search_compaction_enabled && [[ -n "$query" ]] \
    && declare -F ralph_mcp_proxy_owned_tool_search_rank_candidates >/dev/null 2>&1; then
    tmp_candidates="$(mktemp)"
    tmp_ranked="$(mktemp)"
    tmp_compact="$(mktemp)"
    if command -v python3 >/dev/null 2>&1; then
      python3 - "$tmp_candidates" "$full_text" <<'PYTHON'
import sys

out_path = sys.argv[1]
text = sys.argv[2]
with open(out_path, "w", encoding="utf-8") as fh:
    for index, raw in enumerate(text.splitlines(), start=1):
        line = raw.strip()
        if not line:
            continue
        if line.count(":") >= 2:
            fh.write(f"{line}\n")
            continue
        fh.write(f"native-search:{index}:{line}\n")
PYTHON
      candidate_count="$(ralph_mcp_proxy_owned_tool_grep_count_lines "$(<"$tmp_candidates")")"
      if [[ "$candidate_count" -gt 0 ]] \
        && ralph_mcp_proxy_owned_tool_search_rank_candidates \
          "$query" "$tmp_candidates" "$max_results" "$tmp_ranked"; then
        full_text="$(<"$tmp_ranked")"
        if [[ -n "$full_text" && "$full_text" != *$'\n' ]]; then
          full_text+=$'\n'
        fi
        ralph_mcp_proxy_owned_tool_search_to_compact_output "$tmp_ranked" "$tmp_compact"
        preview_text="$(<"$tmp_compact")"
        if [[ -n "$preview_text" && "$preview_text" != *$'\n' ]]; then
          preview_text+=$'\n'
        fi
      fi
    fi
    rm -f "$tmp_candidates" "$tmp_ranked" "$tmp_compact"
  fi

  match_count="$(ralph_mcp_proxy_owned_tool_grep_count_lines "$preview_text")"
  if [[ "$match_count" -gt "$max_results" ]]; then
    truncated=1
  elif [[ "$byte_cap" =~ ^[0-9]+$ ]] && [[ "$byte_cap" -gt 0 ]] && [[ "${#preview_text}" -gt "$byte_cap" ]]; then
    truncated=1
    preview_text="$(ralph_mcp_proxy_owned_tool_grep_head_lines "$preview_text" "$max_results")"
  fi
  if [[ "${#full_text}" -gt "${#text}" || "$preview_text" != "$text" ]]; then
    truncated=1
  fi

  match_metadata_json="$(ralph_mcp_proxy_owned_tool_search_match_metadata_json "$full_text" 2>/dev/null || true)"
  if [[ -z "$match_metadata_json" ]]; then
    match_metadata_json='[]'
  fi
  cluster_metadata_json="$(ralph_mcp_proxy_result_store_match_clusters_from_metadata "$match_metadata_json" 2>/dev/null || true)"
  if [[ -z "$cluster_metadata_json" ]]; then
    cluster_metadata_json="$match_metadata_json"
  fi

  RALPH_NATIVE_PREP_STORAGE_TEXT="$full_text"
  RALPH_NATIVE_PREP_PREVIEW_TEXT="$preview_text"
  RALPH_NATIVE_PREP_TRUNCATED="$truncated"
  RALPH_NATIVE_PREP_MATCH_METADATA_JSON="$cluster_metadata_json"
  RALPH_NATIVE_PREP_PATTERN_OR_QUERY="$query"
  RALPH_NATIVE_PREP_METADATA_JSON='{"storageLayout":"full"}'
  export RALPH_NATIVE_PREP_STORAGE_TEXT RALPH_NATIVE_PREP_PREVIEW_TEXT RALPH_NATIVE_PREP_TRUNCATED
  export RALPH_NATIVE_PREP_MATCH_METADATA_JSON RALPH_NATIVE_PREP_PATTERN_OR_QUERY RALPH_NATIVE_PREP_METADATA_JSON
}

ralph_native_hook_prepare_exploration_envelope() {
  local proxy_tool="${1:-}" text="${2:-}" context_json byte_cap="${4:-0}"
  context_json="$(ralph_native_hook_context_json_or_empty "${3:-}")"

  case "$proxy_tool" in
    ralph_proxy_read)
      ralph_native_hook_prepare_read_envelope "$text" "$context_json" "$byte_cap"
      ;;
    ralph_proxy_grep)
      ralph_native_hook_prepare_grep_envelope "$text" "$context_json" "$byte_cap"
      ;;
    ralph_proxy_glob)
      ralph_native_hook_prepare_glob_envelope "$text" "$context_json" "$byte_cap"
      ;;
    ralph_proxy_search)
      ralph_native_hook_prepare_search_envelope "$text" "$context_json" "$byte_cap"
      ;;
    *)
      RALPH_NATIVE_PREP_STORAGE_TEXT="$text"
      RALPH_NATIVE_PREP_PREVIEW_TEXT="$text"
      RALPH_NATIVE_PREP_TRUNCATED=0
      RALPH_NATIVE_PREP_MATCH_METADATA_JSON='[]'
      RALPH_NATIVE_PREP_PATTERN_OR_QUERY=""
      RALPH_NATIVE_PREP_METADATA_JSON='{}'
      export RALPH_NATIVE_PREP_STORAGE_TEXT RALPH_NATIVE_PREP_PREVIEW_TEXT RALPH_NATIVE_PREP_TRUNCATED
      export RALPH_NATIVE_PREP_MATCH_METADATA_JSON RALPH_NATIVE_PREP_PATTERN_OR_QUERY RALPH_NATIVE_PREP_METADATA_JSON
      ;;
  esac
}

ralph_native_hook_compact_text_result() {
  local workspace="${1:-}" plan_key="${2:-}" proxy_tool="${3:-}" text="${4:-}"
  local context_json byte_cap original_bytes compact_result shaped_json
  local storage_text preview_text truncated_flag match_metadata_json metadata_json pattern_or_query
  local surfaced_tool_name="${6:-}" windowing_channel="${7:-}"
  local saved_windowing_channel saved_surfaced_tool saved_normalized_tool

  [[ -n "$workspace" && -n "$text" ]] || return 1
  context_json="$(ralph_native_hook_context_json_or_empty "${5:-}")"
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

  ralph_native_hook_prepare_exploration_envelope "$proxy_tool" "$text" "$context_json" "$byte_cap"
  storage_text="${RALPH_NATIVE_PREP_STORAGE_TEXT:-$text}"
  preview_text="${RALPH_NATIVE_PREP_PREVIEW_TEXT:-$text}"
  truncated_flag="${RALPH_NATIVE_PREP_TRUNCATED:-0}"
  match_metadata_json="${RALPH_NATIVE_PREP_MATCH_METADATA_JSON:-[]}"
  metadata_json="${RALPH_NATIVE_PREP_METADATA_JSON:-}"
  [[ -n "$metadata_json" ]] || metadata_json='{}'
  pattern_or_query="${RALPH_NATIVE_PREP_PATTERN_OR_QUERY:-}"

  if [[ "$truncated_flag" != "1" && "$preview_text" == "$storage_text" ]]; then
    truncated_flag=1
  fi

  saved_windowing_channel="${RALPH_RESULT_WINDOWING_CHANNEL:-}"
  saved_surfaced_tool="${RALPH_RESULT_WINDOWING_SURFACED_TOOL_NAME:-}"
  saved_normalized_tool="${RALPH_RESULT_WINDOWING_NORMALIZED_TOOL_NAME:-}"
  if [[ -n "$windowing_channel" ]]; then
    export RALPH_RESULT_WINDOWING_CHANNEL="$windowing_channel"
  fi
  if [[ -n "$surfaced_tool_name" ]]; then
    export RALPH_RESULT_WINDOWING_SURFACED_TOOL_NAME="$surfaced_tool_name"
    export RALPH_RESULT_WINDOWING_NORMALIZED_TOOL_NAME="$proxy_tool"
  fi

  compact_result="$(ralph_mcp_proxy_owned_tool_maybe_envelope_text_result \
    "$workspace" \
    "$proxy_tool" \
    "$storage_text" \
    "$truncated_flag" \
    "$preview_text" \
    "$match_metadata_json" \
    "" \
    "$pattern_or_query" \
    "$metadata_json")"

  if [[ -n "$windowing_channel" ]]; then
    if [[ -n "$saved_windowing_channel" ]]; then
      export RALPH_RESULT_WINDOWING_CHANNEL="$saved_windowing_channel"
    else
      unset RALPH_RESULT_WINDOWING_CHANNEL
    fi
  fi
  if [[ -n "$surfaced_tool_name" ]]; then
    if [[ -n "$saved_surfaced_tool" ]]; then
      export RALPH_RESULT_WINDOWING_SURFACED_TOOL_NAME="$saved_surfaced_tool"
    else
      unset RALPH_RESULT_WINDOWING_SURFACED_TOOL_NAME
    fi
    if [[ -n "$saved_normalized_tool" ]]; then
      export RALPH_RESULT_WINDOWING_NORMALIZED_TOOL_NAME="$saved_normalized_tool"
    else
      unset RALPH_RESULT_WINDOWING_NORMALIZED_TOOL_NAME
    fi
  fi

  [[ -n "$compact_result" ]] || return 1

  shaped_json="$(jq -r '.content[0].text // empty' <<<"$compact_result")"
  [[ -n "$shaped_json" ]] || return 1
  if [[ "$shaped_json" == "$text" ]]; then
    return 1
  fi

  printf '%s\n' "$shaped_json"
  return 0
}
