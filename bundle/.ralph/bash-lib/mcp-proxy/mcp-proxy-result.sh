#!/usr/bin/env bash

if [[ -n "${RALPH_MCP_PROXY_RESULT_LOADED:-}" ]]; then
  return
fi
RALPH_MCP_PROXY_RESULT_LOADED=1

_MCP_PROXY_RESULT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${RALPH_MCP_PROXY_RESULT_STORE_LOADED:-}" ]]; then
  # shellcheck source=/dev/null
  source "$_MCP_PROXY_RESULT_LIB_DIR/mcp-proxy-result-store.sh"
fi
if [[ -z "${RALPH_TOKEN_ESTIMATE_LOADED:-}" ]]; then
  # shellcheck source=/dev/null
  source "$_MCP_PROXY_RESULT_LIB_DIR/../token-estimate.sh"
fi

if [[ -z "${RALPH_MCP_PROXY_LOGGING_LOADED:-}" ]]; then
  # shellcheck source=mcp-proxy-logging.sh
  source "$_MCP_PROXY_RESULT_LIB_DIR/mcp-proxy-logging.sh"
fi

ralph_mcp_proxy_result_lookup_key() {
  local method="${1:-}"
  local tool_name="${2:-}"
  if [[ -n "$tool_name" ]]; then
    printf '%s' "$tool_name"
    return 0
  fi
  printf '%s' "$method"
}

# Truncated Ralph proxy MCP results use a compact JSON envelope embedded in
# content: [{type:"text", text:<envelope>}]. Field names are camelCase.
#
# Agent retrieval protocol (preview-first, compacted-next, raw-last):
#   preview              compacted first-pass answer; treat as sufficient unless more context is needed
#   recommendedReadView    "compacted" (normal follow-up) or "raw" (escalation only)
#   compactedRef           {resultId, view:"compacted"} for ralph_proxy_result_read follow-up
#   rawRef                 {resultId, view:"raw"} for exact/full inspection when compacted is insufficient
#
# Required envelope fields:
#   truncated      boolean; true when the full payload was stored and capped inline
#   preview        string; bounded inline compacted preview text
#   originalBytes  non-negative integer; byte length of the full stored payload
#   returnedBytes  non-negative integer; byte length of preview (not envelope JSON)
#   resultId       16-char lowercase hex id for stored dual-view output
#   breakpoints    array of paging anchors (start/end/match ranges)
#   nextActions    array of follow-up MCP tool calls ({tool, arguments, description?})
#
# Breakpoint objects require kind (string). Optional numeric fields byteStart,
# byteEnd, lineStart, and lineEnd must be non-negative integers when present.
#
# NextAction objects require tool (non-empty string) and arguments (object).
#
# Optional additive envelope fields (guidance and telemetry; not required by validation):
#   compactedRef, rawRef, recommendedReadView  dual-view retrieval guidance (see protocol above)
#   originalTokens  non-negative integer; estimated tokens in the full stored payload
#   returnedTokens  non-negative integer; estimated tokens in preview text
ralph_mcp_proxy_result_envelope_validate_json() {
  local envelope_json="${1:-}"
  [[ -n "$envelope_json" ]] || return 1
  jq -e '
    def is_natural:
      (type == "number") and (. >= 0) and ((. | floor) == .);
    def is_result_id:
      (type == "string") and test("^[a-f0-9]{16}$");
    def is_optional_natural($value):
      ($value | type) == "null" or ($value | is_natural);
    def is_breakpoint:
      (type == "object")
      and (.kind? | type == "string" and length > 0)
      and is_optional_natural(.byteStart?)
      and is_optional_natural(.byteEnd?)
      and is_optional_natural(.lineStart?)
      and is_optional_natural(.lineEnd?);
    def is_next_action:
      (type == "object")
      and (.tool? | type == "string" and length > 0)
      and (.arguments? | type == "object")
      and (.description? | type == "null" or type == "string");
    def is_view_ref:
      (type == "object")
      and (.resultId? | is_result_id)
      and (.view? | type == "string" and (. == "compacted" or . == "raw"));
    def is_optional_view_ref($value):
      ($value | type) == "null" or ($value | is_view_ref);
    def is_recommended_read_view($value):
      ($value | type) == "null" or ($value | type == "string" and (. == "compacted" or . == "raw"));
    def is_optional_guidance($value):
      ($value | type) == "null" or (($value | type) == "string");
    (type == "object")
    and (.truncated? | type == "boolean")
    and (.preview? | type == "string")
    and (.originalBytes? | is_natural)
    and (.returnedBytes? | is_natural)
    and (.resultId? | is_result_id)
    and (.breakpoints? | type == "array" and all(.[]?; is_breakpoint))
    and (.nextActions? | type == "array" and all(.[]?; is_next_action))
    and is_optional_view_ref(.compactedRef?)
    and is_optional_view_ref(.rawRef?)
    and is_recommended_read_view(.recommendedReadView?)
    and is_optional_guidance(.guidance?)
  ' <<< "$envelope_json" >/dev/null 2>&1
}

ralph_mcp_proxy_result_envelope_guidance_json() {
  local result_id="${1:-}"
  [[ -n "$result_id" ]] || return 1
  jq -nc \
    --arg resultId "$result_id" \
    '{
      compactedRef: {resultId: $resultId, view: "compacted"},
      rawRef: {resultId: $resultId, view: "raw"},
      recommendedReadView: "compacted",
      guidance: "The inline preview is the compacted view; use rawRef only when you need the full exact output."
    }'
}

ralph_mcp_proxy_result_compact_view_bias_for_tool() {
  local tool_label="${1:-}"
  case "$tool_label" in
    ralph_proxy_read|ralph_proxy_grep|ralph_proxy_glob|ralph_proxy_search|resources/read)
      printf 'head'
      ;;
    *)
      printf 'tail'
      ;;
  esac
}

# Build a content-aware compacted view for dual-view storage. Head-biased for
# file/search reads; tail-biased for shell/log-like output. Inline preview caps
# are applied separately via ralph_mcp_proxy_result_apply_preview_caps.
# Middle-omit compaction for large head-biased reads (file/grep/glob). Keeps head,
# tail, and error-like lines when output exceeds the read byte cap.
ralph_mcp_proxy_result_compact_view_head_omit_middle() {
  local text="${1:-}"
  local byte_cap="${2:-16384}"
  compacted="$(printf '%s' "$text" | awk -v cap="$byte_cap" '
    BEGIN {
      head_keep = 40
      tail_keep = 40
      omit_marker = "... (lines omitted; full output in raw view) ..."
    }
    {
      lines[NR] = $0
    }
    END {
      n = NR
      if (n == 0) {
        exit
      }
      if (n <= head_keep + tail_keep) {
        for (i = 1; i <= n; i++) {
          print lines[i]
        }
        exit
      }
      for (i = 1; i <= n; i++) {
        keep[i] = 0
      }
      for (i = 1; i <= head_keep; i++) {
        keep[i] = 1
      }
      tail_start = n - tail_keep + 1
      if (tail_start < 1) {
        tail_start = 1
      }
      for (i = tail_start; i <= n; i++) {
        keep[i] = 1
      }
      for (i = 1; i <= n; i++) {
        if (lines[i] ~ /[Ee][Rr][Rr][Oo][Rr]|[Ff][Aa][Ii][Ll]|[Ww][Aa][Rr][Nn]|[Tt][Rr][Aa][Cc][Ee][Bb][Aa][Cc][Kk]|[Ee][Xx][Cc][Ee][Pp][Tt][Ii][Oo][Nn]/) {
          keep[i] = 1
        }
      }
      in_omit = 0
      for (i = 1; i <= n; i++) {
        if (keep[i]) {
          if (in_omit) {
            print omit_marker
            in_omit = 0
          }
          print lines[i]
        } else if (!in_omit) {
          in_omit = 1
        }
      }
    }
  ')"

  if [[ "${#compacted}" -gt "$byte_cap" && "$byte_cap" -gt 0 ]]; then
    compacted="${compacted:0:byte_cap}"
  fi
  printf '%s' "$compacted"
}

ralph_mcp_proxy_result_compact_view() {
  local text="${1:-}"
  local tool_label="${2:-}"
  local bias compacted byte_cap

  if [[ -z "$text" ]]; then
    return 0
  fi

  bias="$(ralph_mcp_proxy_result_compact_view_bias_for_tool "$tool_label")"
  if [[ "$bias" == "head" ]]; then
    byte_cap=16384
    if declare -F ralph_mcp_proxy_result_byte_cap_for_tool >/dev/null 2>&1; then
      byte_cap="$(ralph_mcp_proxy_result_byte_cap_for_tool "$tool_label")"
    fi
    if [[ ! "$byte_cap" =~ ^[0-9]+$ ]] || [[ "$byte_cap" -le 0 ]]; then
      byte_cap=16384
    fi
    if [[ "${#text}" -gt "$byte_cap" ]]; then
      ralph_mcp_proxy_result_compact_view_head_omit_middle "$text" "$byte_cap"
      return 0
    fi
    printf '%s' "$text"
    return 0
  fi

  compacted="$(printf '%s' "$text" | awk '
    BEGIN {
      head_keep = 5
      tail_keep = 40
      omit_marker = "... (lines omitted; full output in raw view) ..."
    }
    {
      lines[NR] = $0
    }
    END {
      n = NR
      if (n == 0) {
        exit
      }
      if (n <= head_keep + tail_keep) {
        for (i = 1; i <= n; i++) {
          print lines[i]
        }
        exit
      }
      for (i = 1; i <= n; i++) {
        keep[i] = 0
      }
      for (i = 1; i <= head_keep; i++) {
        keep[i] = 1
      }
      tail_start = n - tail_keep + 1
      if (tail_start < 1) {
        tail_start = 1
      }
      for (i = tail_start; i <= n; i++) {
        keep[i] = 1
      }
      for (i = 1; i <= n; i++) {
        if (lines[i] ~ /[Ee][Rr][Rr][Oo][Rr]|[Ff][Aa][Ii][Ll]|[Ww][Aa][Rr][Nn]|[Tt][Rr][Aa][Cc][Ee][Bb][Aa][Cc][Kk]|[Ee][Xx][Cc][Ee][Pp][Tt][Ii][Oo][Nn]/) {
          keep[i] = 1
        }
      }
      in_omit = 0
      for (i = 1; i <= n; i++) {
        if (keep[i]) {
          if (in_omit) {
            print omit_marker
            in_omit = 0
          }
          print lines[i]
        } else if (!in_omit) {
          in_omit = 1
        }
      }
    }
  ')"

  printf '%s' "$compacted"
}

ralph_mcp_proxy_result_envelope_is_truncated_json() {
  local envelope_json="${1:-}"
  ralph_mcp_proxy_result_envelope_validate_json "$envelope_json" || return 1
  jq -e '.truncated == true' <<< "$envelope_json" >/dev/null 2>&1
}

ralph_mcp_proxy_result_envelope_default_breakpoints_json() {
  local original_bytes="${1:-0}"
  local returned_bytes="${2:-0}"
  jq -nc \
    --argjson originalBytes "$original_bytes" \
    --argjson returnedBytes "$returned_bytes" \
    '
      ($originalBytes | if . < 0 then 0 else . end) as $orig
      | ($returnedBytes | if . < 0 then 0 else . end) as $ret
      | ($ret | if $ret > 0 then $ret else ($orig | if . > 0 then . else 1 end) end) as $window
      | [
          {kind: "start", byteStart: 0, byteEnd: $window},
          {
            kind: "end",
            byteStart: (if $orig > $window then ($orig - $window) else 0 end),
            byteEnd: $orig
          }
        ]
    '
}

ralph_mcp_proxy_result_envelope_next_actions_include_raw() {
  local recommended_read_view="${1:-compacted}"
  [[ "$recommended_read_view" == "raw" ]]
}

ralph_mcp_proxy_result_envelope_grep_next_actions_json() {
  local result_id="${1:-}"
  local pattern="${2:-}"
  local read_window="${3:-4096}"
  local recommended_read_view="${4:-compacted}"
  jq -nc \
    --arg resultId "$result_id" \
    --arg pattern "$pattern" \
    --argjson readWindow "$read_window" \
    --arg recommendedReadView "$recommended_read_view" \
    '
      ($readWindow | if . < 1 then 4096 else . end) as $window
      | [
          {
            tool: "ralph_proxy_result_search",
            description: "Search the stored grep output for more matches",
            arguments: (
              {resultId: $resultId, pattern: $pattern}
              | if $pattern == "" then del(.pattern) else . end
            )
          },
          {
            tool: "ralph_proxy_result_read",
            description: "Read more of the compacted stored view (normal follow-up after preview)",
            arguments: {resultId: $resultId, view: "compacted", byteStart: 0, byteEnd: $window}
          },
          {
            tool: "ralph_proxy_result_summary",
            description: "Summarize stored grep result size and paging breakpoints",
            arguments: {resultId: $resultId}
          }
        ]
      | if $recommendedReadView == "raw" then
          . + [{
            tool: "ralph_proxy_result_read",
            description: "Read exact/full stored output (escalation only when compacted is insufficient)",
            arguments: {resultId: $resultId, view: "raw", byteStart: 0, byteEnd: $window}
          }]
        else
          .
        end
    '
}

ralph_mcp_proxy_result_envelope_glob_search_pattern() {
  local glob_pattern="${1:-}"
  local search_pattern="$glob_pattern"
  if [[ "$glob_pattern" == *[\*\?]* ]]; then
    search_pattern="${glob_pattern%%[\*\?]*}"
  fi
  search_pattern="${search_pattern//\*\*/}"
  search_pattern="${search_pattern//\*/}"
  search_pattern="${search_pattern//\?/}"
  if [[ -z "$search_pattern" ]]; then
    search_pattern="."
  fi
  printf '%s' "$search_pattern"
}

ralph_mcp_proxy_result_envelope_glob_next_actions_json() {
  local result_id="${1:-}"
  local glob_pattern="${2:-}"
  local read_window="${3:-4096}"
  local recommended_read_view="${4:-compacted}"
  local search_pattern
  search_pattern="$(ralph_mcp_proxy_result_envelope_glob_search_pattern "$glob_pattern")"
  jq -nc \
    --arg resultId "$result_id" \
    --arg pattern "$search_pattern" \
    --argjson readWindow "$read_window" \
    --arg recommendedReadView "$recommended_read_view" \
    '
      ($readWindow | if . < 1 then 4096 else . end) as $window
      | [
          {
            tool: "ralph_proxy_result_search",
            description: "Search stored glob paths for a filename or substring",
            arguments: {resultId: $resultId, pattern: $pattern}
          },
          {
            tool: "ralph_proxy_result_read",
            description: "Read more of the compacted stored view (normal follow-up after preview)",
            arguments: {resultId: $resultId, view: "compacted", byteStart: 0, byteEnd: $window}
          },
          {
            tool: "ralph_proxy_result_summary",
            description: "Summarize stored glob result size and paging breakpoints",
            arguments: {resultId: $resultId}
          }
        ]
      | if $recommendedReadView == "raw" then
          . + [{
            tool: "ralph_proxy_result_read",
            description: "Read exact/full stored output (escalation only when compacted is insufficient)",
            arguments: {resultId: $resultId, view: "raw", byteStart: 0, byteEnd: $window}
          }]
        else
          .
        end
    '
}

ralph_mcp_proxy_result_envelope_default_next_actions_json() {
  local result_id="${1:-}"
  local read_window="${2:-4096}"
  local recommended_read_view="${3:-compacted}"
  jq -nc \
    --arg resultId "$result_id" \
    --argjson readWindow "$read_window" \
    --arg recommendedReadView "$recommended_read_view" \
    '
      ($readWindow | if . < 1 then 4096 else . end) as $window
      | [
          {
            tool: "ralph_proxy_result_read",
            description: "Read more of the compacted stored view (normal follow-up after preview)",
            arguments: {resultId: $resultId, view: "compacted", byteStart: 0, byteEnd: $window}
          },
          {
            tool: "ralph_proxy_result_summary",
            description: "Summarize stored result size and paging options",
            arguments: {resultId: $resultId}
          }
        ]
      | if $recommendedReadView == "raw" then
          . + [{
            tool: "ralph_proxy_result_read",
            description: "Read exact/full stored output (escalation only when compacted is insufficient)",
            arguments: {resultId: $resultId, view: "raw", byteStart: 0, byteEnd: $window}
          }]
        else
          .
        end
    '
}

ralph_mcp_proxy_result_envelope_build_json() {
  local preview="${1:-}"
  local original_bytes="${2:-0}"
  local returned_bytes="${3:-0}"
  local result_id="${4:-}"
  local breakpoints_json="${5:-}"
  local next_actions_json="${6:-}"
  local truncated_flag="${7:-true}"
  local original_tokens="${8:-}"
  local returned_tokens="${9:-}"
  local extra_json="${10:-}"

  if [[ -z "$breakpoints_json" ]]; then
    breakpoints_json="$(ralph_mcp_proxy_result_envelope_default_breakpoints_json "$original_bytes" "$returned_bytes")"
  fi
  if [[ -z "$next_actions_json" ]]; then
    next_actions_json="$(ralph_mcp_proxy_result_envelope_default_next_actions_json "$result_id")"
  fi

  local include_tokens="false"
  if [[ "$original_tokens" =~ ^[0-9]+$ ]] && [[ "$returned_tokens" =~ ^[0-9]+$ ]]; then
    include_tokens="true"
  fi

  local guidance_json="" guidance_payload="{}"
  if [[ -n "$result_id" ]]; then
    guidance_json="$(ralph_mcp_proxy_result_envelope_guidance_json "$result_id" 2>/dev/null || true)"
  fi
  if [[ -n "$guidance_json" ]]; then
    guidance_payload="$guidance_json"
  fi

  local extra_payload="{}"
  if [[ -n "$extra_json" ]]; then
    extra_payload="$(jq -c . <<< "$extra_json" 2>/dev/null || printf '{}')"
  fi

  jq -nc \
    --arg preview "$preview" \
    --arg resultId "$result_id" \
    --arg truncatedFlag "$truncated_flag" \
    --argjson originalBytes "$original_bytes" \
    --argjson returnedBytes "$returned_bytes" \
    --argjson breakpoints "$breakpoints_json" \
    --argjson nextActions "$next_actions_json" \
    --arg includeTokens "$include_tokens" \
    --argjson originalTokens "${original_tokens:-0}" \
    --argjson returnedTokens "${returned_tokens:-0}" \
    --argjson guidance "$guidance_payload" \
    --argjson extra "$extra_payload" \
    '
      ($truncatedFlag | ascii_downcase) as $flag
      | ($flag == "true" or $flag == "1" or $flag == "yes" or $flag == "on") as $truncated
      | {
          truncated: $truncated,
          preview: $preview,
          originalBytes: $originalBytes,
          returnedBytes: $returnedBytes,
          resultId: $resultId,
          breakpoints: $breakpoints,
          nextActions: $nextActions
        }
      | if ($guidance | type) == "object" and ($guidance | length) > 0 then
          . + $guidance
        else
          .
        end
      | if $includeTokens == "true" then
          . + {originalTokens: $originalTokens, returnedTokens: $returnedTokens}
        else
          .
        end
      | if ($extra | type) == "object" and ($extra | length) > 0 then
          . + $extra
        else
          .
        end
    '
}

ralph_mcp_proxy_result_estimate_tokens() {
  local text="${1:-}"
  if ! declare -F ralph_token_estimate_text >/dev/null 2>&1; then
    return 1
  fi
  ralph_token_estimate_text "$text"
}

ralph_mcp_proxy_result_text_exceeds_token_cap() {
  local text="${1:-}"
  local token_cap="${2:-0}"
  local estimate
  if [[ ! "$token_cap" =~ ^[0-9]+$ ]] || [[ "$token_cap" -le 0 ]]; then
    return 1
  fi
  estimate="$(ralph_mcp_proxy_result_estimate_tokens "$text" 2>/dev/null || true)"
  [[ "$estimate" =~ ^[0-9]+$ ]] || return 1
  [[ "$estimate" -gt "$token_cap" ]]
}

ralph_mcp_proxy_result_truncate_to_token_cap() {
  local text="${1:-}"
  local token_cap="${2:-0}"
  if [[ ! "$token_cap" =~ ^[0-9]+$ ]] || [[ "$token_cap" -le 0 ]]; then
    printf '%s' "$text"
    return 0
  fi
  local estimate lo hi mid best prefix tok
  estimate="$(ralph_mcp_proxy_result_estimate_tokens "$text" 2>/dev/null || true)"
  if [[ ! "$estimate" =~ ^[0-9]+$ ]] || [[ "$estimate" -le "$token_cap" ]]; then
    printf '%s' "$text"
    return 0
  fi
  lo=0
  hi=${#text}
  best=0
  while [[ "$lo" -le "$hi" ]]; do
    mid=$(( (lo + hi) / 2 ))
    prefix="${text:0:mid}"
    tok="$(ralph_mcp_proxy_result_estimate_tokens "$prefix" 2>/dev/null || true)"
    if [[ "$tok" =~ ^[0-9]+$ ]] && [[ "$tok" -le "$token_cap" ]]; then
      best="$mid"
      lo=$((mid + 1))
    else
      hi=$((mid - 1))
    fi
  done
  printf '%s' "${text:0:best}"
}

# Apply byte and token caps to preview text. Sets:
#   RALPH_MCP_PROXY_RESULT_CAP_PREVIEW
#   RALPH_MCP_PROXY_RESULT_CAP_RETURNED_BYTES
#   RALPH_MCP_PROXY_RESULT_CAP_ORIGINAL_TOKENS
#   RALPH_MCP_PROXY_RESULT_CAP_RETURNED_TOKENS
ralph_mcp_proxy_result_apply_preview_caps() {
  local text="${1:-}"
  local byte_cap="${2:-0}"
  local token_cap="${3:-0}"
  local preview="$text"
  local returned_bytes=${#text}
  local original_tokens="" returned_tokens=""

  RALPH_MCP_PROXY_RESULT_CAP_PREVIEW="$preview"
  RALPH_MCP_PROXY_RESULT_CAP_RETURNED_BYTES="$returned_bytes"
  RALPH_MCP_PROXY_RESULT_CAP_ORIGINAL_TOKENS=""
  RALPH_MCP_PROXY_RESULT_CAP_RETURNED_TOKENS=""

  original_tokens="$(ralph_mcp_proxy_result_estimate_tokens "$text" 2>/dev/null || true)"
  if [[ "$original_tokens" =~ ^[0-9]+$ ]]; then
    RALPH_MCP_PROXY_RESULT_CAP_ORIGINAL_TOKENS="$original_tokens"
  fi

  if [[ "$byte_cap" =~ ^[0-9]+$ ]] && [[ "$byte_cap" -gt 0 ]] && [[ "$returned_bytes" -gt "$byte_cap" ]]; then
    preview="${text:0:byte_cap}"
    returned_bytes="$byte_cap"
  fi

  if [[ "$token_cap" =~ ^[0-9]+$ ]] && [[ "$token_cap" -gt 0 ]] \
    && ralph_mcp_proxy_result_text_exceeds_token_cap "$preview" "$token_cap"; then
    preview="$(ralph_mcp_proxy_result_truncate_to_token_cap "$preview" "$token_cap")"
    returned_bytes=${#preview}
  fi

  returned_tokens="$(ralph_mcp_proxy_result_estimate_tokens "$preview" 2>/dev/null || true)"
  if [[ "$returned_tokens" =~ ^[0-9]+$ ]]; then
    RALPH_MCP_PROXY_RESULT_CAP_RETURNED_TOKENS="$returned_tokens"
  fi

  RALPH_MCP_PROXY_RESULT_CAP_PREVIEW="$preview"
  RALPH_MCP_PROXY_RESULT_CAP_RETURNED_BYTES="$returned_bytes"
}

ralph_mcp_proxy_result_envelope_mode_enabled() {
  local explicit="${1:-}"
  if [[ -n "$explicit" ]]; then
    case "$explicit" in
      1|true|yes|on) return 0 ;;
      *) return 1 ;;
    esac
  fi
  case "${RALPH_MCP_PROXY_RESULT_ENVELOPE_MODE:-}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

ralph_mcp_proxy_result_store_context_workspace() {
  local workspace="${RALPH_MCP_WORKSPACE:-}"
  [[ -n "$workspace" ]] || return 1
  (cd "$workspace" && pwd)
}

ralph_mcp_proxy_result_store_context_plan_key() {
  if [[ -n "${RALPH_PLAN_KEY:-}" ]]; then
    printf '%s\n' "$RALPH_PLAN_KEY"
  elif [[ -n "${RALPH_ARTIFACT_NS:-}" ]]; then
    printf '%s\n' "$RALPH_ARTIFACT_NS"
  else
    printf 'default\n'
  fi
}

# Full-result storage is limited to Ralph proxy MCP tools and resources/read text payloads.
# Runtime-native tool names (Read, Bash, grep, etc.) may be truncated inline but are never persisted.
ralph_mcp_proxy_result_store_context_allows_storage() {
  local method="${1:-}"
  local lookup_key="${2:-}"

  if [[ "$method" == "resources/read" ]]; then
    return 0
  fi
  if [[ -n "$lookup_key" && "$lookup_key" == ralph_proxy_* ]]; then
    return 0
  fi
  return 1
}

ralph_mcp_proxy_result_store_tool_name_allowed() {
  local tool_name="${1:-}"
  if [[ -z "$tool_name" ]]; then
    return 0
  fi
  if [[ "$tool_name" == "resources/read" ]]; then
    return 0
  fi
  [[ "$tool_name" == ralph_proxy_* ]]
}

ralph_mcp_proxy_shape_one_text() {
  local text="${1:-}"
  local byte_cap="${2:-0}"
  local envelope_mode="${3:-0}"
  local workspace="${4:-}"
  local plan_key="${5:-}"
  local tool_label="${6:-}"
  local method="${7:-}"
  local token_cap="${8:-0}"

  if ralph_mcp_proxy_result_envelope_validate_json "$text" 2>/dev/null; then
    ralph_mcp_proxy_result_envelope_compact_text "$text"
    return 0
  fi

  local text_len=${#text}
  local use_envelope=0
  local truncated=0
  local byte_exceeded=0
  local token_exceeded=0

  if [[ "$byte_cap" =~ ^[0-9]+$ ]] && [[ "$byte_cap" -gt 0 ]] && [[ "$text_len" -gt "$byte_cap" ]]; then
    byte_exceeded=1
  fi
  if [[ "$token_cap" =~ ^[0-9]+$ ]] && [[ "$token_cap" -gt 0 ]] \
    && ralph_mcp_proxy_result_text_exceeds_token_cap "$text" "$token_cap"; then
    token_exceeded=1
  fi
  if [[ "$byte_exceeded" -eq 1 || "$token_exceeded" -eq 1 ]]; then
    use_envelope=1
    truncated=1
  fi

  if [[ "$use_envelope" -eq 0 ]]; then
    printf '%s' "$text"
    return 0
  fi

  local preview="$text"
  local compact_view=""
  local returned_bytes="$text_len"
  local original_bytes="$text_len"
  local original_tokens="" returned_tokens=""
  local result_id=""
  local truncation_marker
  truncation_marker="$(ralph_mcp_proxy_truncation_marker)"

  original_tokens="$(ralph_mcp_proxy_result_estimate_tokens "$text" 2>/dev/null || true)"
  if [[ "$truncated" -eq 1 ]]; then
    compact_view="$(ralph_mcp_proxy_result_compact_view "$text" "$tool_label")"
    preview="$compact_view"
    ralph_mcp_proxy_result_apply_preview_caps "$preview" "$byte_cap" "$token_cap"
    preview="$RALPH_MCP_PROXY_RESULT_CAP_PREVIEW"
    returned_bytes="$RALPH_MCP_PROXY_RESULT_CAP_RETURNED_BYTES"
    if [[ -n "$RALPH_MCP_PROXY_RESULT_CAP_ORIGINAL_TOKENS" ]]; then
      original_tokens="$RALPH_MCP_PROXY_RESULT_CAP_ORIGINAL_TOKENS"
    fi
    if [[ -n "$RALPH_MCP_PROXY_RESULT_CAP_RETURNED_TOKENS" ]]; then
      returned_tokens="$RALPH_MCP_PROXY_RESULT_CAP_RETURNED_TOKENS"
    fi
  elif [[ "$original_tokens" =~ ^[0-9]+$ ]]; then
    returned_tokens="$original_tokens"
  fi

  if [[ -n "$workspace" && -n "$plan_key" ]] \
    && ralph_mcp_proxy_result_store_context_allows_storage "$method" "$tool_label"; then
    if [[ -n "$compact_view" ]]; then
      result_id="$(ralph_mcp_proxy_result_store_write "$workspace" "$plan_key" "$text" "$tool_label" "" "$compact_view" 2>/dev/null || true)"
    else
      result_id="$(ralph_mcp_proxy_result_store_write "$workspace" "$plan_key" "$text" "$tool_label" 2>/dev/null || true)"
    fi
  fi

  if [[ -z "$result_id" ]]; then
    if [[ "$truncated" -eq 1 ]]; then
      printf '%s%s' "$preview" "$truncation_marker"
    else
      printf '%s' "$text"
    fi
    return 0
  fi

  local envelope_json truncated_flag="true" breakpoints_json="" token_args=()
  if [[ "$truncated" -eq 0 ]]; then
    truncated_flag="false"
  fi
  breakpoints_json="$(ralph_mcp_proxy_result_store_generate_breakpoints_json "$workspace" "$plan_key" "$result_id" "$original_bytes" "$returned_bytes" "$byte_cap" "[]" 2>/dev/null || true)"
  if [[ "$original_tokens" =~ ^[0-9]+$ ]] && [[ "$returned_tokens" =~ ^[0-9]+$ ]]; then
    token_args=("$original_tokens" "$returned_tokens")
  fi
  envelope_json="$(ralph_mcp_proxy_result_envelope_build_json "$preview" "$original_bytes" "$returned_bytes" "$result_id" "$breakpoints_json" "" "$truncated_flag" "${token_args[@]}")" || {
    if [[ "$truncated" -eq 1 ]]; then
      printf '%s%s' "$preview" "$truncation_marker"
    else
      printf '%s' "$text"
    fi
    return 0
  }
  ralph_mcp_proxy_result_envelope_compact_text "$envelope_json"
}

ralph_mcp_proxy_result_envelope_compact_text() {
  local envelope_json="${1:-}"
  ralph_mcp_proxy_result_envelope_validate_json "$envelope_json" || return 1
  jq -c . <<< "$envelope_json"
}

ralph_mcp_proxy_result_envelope_to_mcp_result_json() {
  local envelope_json="${1:-}"
  local compact_text
  compact_text="$(ralph_mcp_proxy_result_envelope_compact_text "$envelope_json")" || return 1
  jq -nc \
    --arg text "$compact_text" \
    '{
      content: [{type: "text", text: $text}],
      isError: false
    }'
}

ralph_mcp_proxy_result_envelope_from_mcp_result_json() {
  local response_json="${1:-}"
  jq -r '
    if (.content? | type) == "array" then
      (.content[0].text // empty)
    elif (.result.content? | type) == "array" then
      (.result.content[0].text // empty)
    else
      empty
    end
  ' <<< "$response_json"
}

ralph_mcp_proxy_result_envelope_mcp_result_is_valid() {
  local response_json="${1:-}"
  local envelope_text
  envelope_text="$(ralph_mcp_proxy_result_envelope_from_mcp_result_json "$response_json")"
  [[ -n "$envelope_text" ]] || return 1
  ralph_mcp_proxy_result_envelope_validate_json "$envelope_text"
}

ralph_mcp_proxy_shape_tools_list() {
  local response_json="${1:-}"
  local allowlist_json="${RALPH_MCP_PROXY_POLICY_TOOL_ALLOWLIST_JSON:-[]}"
  local denylist_json="${RALPH_MCP_PROXY_POLICY_TOOL_DENYLIST_JSON:-[]}"
  local description_cap="${RALPH_MCP_PROXY_POLICY_DESCRIPTION_BYTE_CAP:-0}"
  local truncation_marker
  truncation_marker="$(ralph_mcp_proxy_truncation_marker)"
  local before_count after_count truncated_count shaped_json

  before_count="$(jq -r 'if (.result.tools? | type) == "array" then .result.tools | length else 0 end' <<< "$response_json")"
  shaped_json="$(
    jq -c \
      --argjson allowlist "$allowlist_json" \
      --argjson denylist "$denylist_json" \
      --argjson description_cap "$description_cap" \
      --arg truncation_marker "$truncation_marker" \
      --arg owned_prefix "ralph_proxy_" \
      '
        if (.result.tools? | type) != "array" then
          .
        else
          .result.tools |= map(
            . as $tool
            | ($tool.name // "") as $tool_name
            | if ($tool_name | startswith($owned_prefix)) then
                $tool
              elif (($allowlist | length) > 0 and ($allowlist | index($tool_name) | not)) then
                empty
              elif ($denylist | index($tool_name)) then
                empty
              else
                $tool
                | if ($description_cap | tonumber) > 0 and (.description? | type == "string") and (.description | length > ($description_cap | tonumber)) then
                    .description = (.description[0:($description_cap | tonumber)] + $truncation_marker)
                  else
                    .
                  end
              end
          )
        end
      ' <<< "$response_json"
  )"
  after_count="$(jq -r 'if (.result.tools? | type) == "array" then .result.tools | length else 0 end' <<< "$shaped_json")"
  if [[ "$after_count" -lt "$before_count" ]]; then
    ralph_mcp_proxy_log_action "denied" "tools/list filtered $((before_count - after_count)) tool(s) by policy=${RALPH_MCP_PROXY_POLICY_NAME:-default}"
  fi
  if [[ "$description_cap" =~ ^[0-9]+$ ]] && [[ "$description_cap" -gt 0 ]]; then
    truncated_count="$(jq -r --argjson cap "$description_cap" 'if (.result.tools? | type) != "array" then 0 else ([.result.tools[]? | select((.description? | type) == "string" and (.description | length > $cap))] | length) end' <<< "$response_json")"
    if [[ "$truncated_count" -gt 0 ]]; then
      ralph_mcp_proxy_log_action "truncate" "tools/list descriptions truncated for $truncated_count tool(s) at cap=$description_cap"
    fi
  fi
  printf '%s\n' "$shaped_json"
}

ralph_mcp_proxy_shape_text_result() {
  local method="${1:-}"
  local tool_name="${2:-}"
  local response_json="${3:-}"
  local envelope_mode_arg="${4:-}"
  local lookup_key byte_cap token_cap envelope_mode workspace plan_key tool_label
  lookup_key="$(ralph_mcp_proxy_result_lookup_key "$method" "$tool_name")"
  byte_cap="$(ralph_mcp_proxy_result_byte_cap_for_tool "$lookup_key")"
  token_cap="$(ralph_mcp_proxy_result_token_cap_for_tool "$lookup_key")"
  envelope_mode=0
  if ralph_mcp_proxy_result_envelope_mode_enabled "$envelope_mode_arg"; then
    envelope_mode=1
  fi
  workspace=""
  plan_key=""
  workspace="$(ralph_mcp_proxy_result_store_context_workspace 2>/dev/null || true)"
  plan_key="$(ralph_mcp_proxy_result_store_context_plan_key 2>/dev/null || true)"
  tool_label="$lookup_key"

  if ! ralph_mcp_proxy_result_caps_active_for_tool "$lookup_key" && [[ "$envelope_mode" -eq 0 ]]; then
    printf '%s\n' "$response_json"
    return 0
  fi
  if [[ "$(jq -r 'if (.result? | type) == "object" then "yes" else "no" end' <<< "$response_json")" != "yes" ]]; then
    printf '%s\n' "$response_json"
    return 0
  fi

  local shaped_json="$response_json"
  local content_count contents_count idx text shaped_text
  local enveloped_count=0 truncated_count=0

  content_count="$(jq -r 'if (.result.content? | type) == "array" then .result.content | length else 0 end' <<< "$shaped_json")"
  for ((idx = 0; idx < content_count; idx++)); do
    text="$(jq -r ".result.content[$idx].text // empty" <<< "$shaped_json")"
    [[ -n "$text" ]] || continue
    shaped_text="$(ralph_mcp_proxy_shape_one_text "$text" "$byte_cap" "$envelope_mode" "$workspace" "$plan_key" "$tool_label" "$method" "$token_cap")"
    if [[ "$shaped_text" != "$text" ]]; then
      if ralph_mcp_proxy_result_envelope_validate_json "$shaped_text" 2>/dev/null; then
        enveloped_count=$((enveloped_count + 1))
      elif [[ "${#text}" -gt "$byte_cap" ]] \
        || ralph_mcp_proxy_result_text_exceeds_token_cap "$text" "$token_cap"; then
        truncated_count=$((truncated_count + 1))
      fi
      shaped_json="$(jq -c --arg text "$shaped_text" ".result.content[$idx].text = \$text" <<< "$shaped_json")"
    fi
  done

  contents_count="$(jq -r 'if (.result.contents? | type) == "array" then .result.contents | length else 0 end' <<< "$shaped_json")"
  for ((idx = 0; idx < contents_count; idx++)); do
    text="$(jq -r ".result.contents[$idx].text // empty" <<< "$shaped_json")"
    [[ -n "$text" ]] || continue
    shaped_text="$(ralph_mcp_proxy_shape_one_text "$text" "$byte_cap" "$envelope_mode" "$workspace" "$plan_key" "$tool_label" "$method" "$token_cap")"
    if [[ "$shaped_text" != "$text" ]]; then
      if ralph_mcp_proxy_result_envelope_validate_json "$shaped_text" 2>/dev/null; then
        enveloped_count=$((enveloped_count + 1))
      elif [[ "${#text}" -gt "$byte_cap" ]] \
        || ralph_mcp_proxy_result_text_exceeds_token_cap "$text" "$token_cap"; then
        truncated_count=$((truncated_count + 1))
      fi
      shaped_json="$(jq -c --arg text "$shaped_text" ".result.contents[$idx].text = \$text" <<< "$shaped_json")"
    fi
  done

  if [[ "$enveloped_count" -gt 0 ]]; then
    ralph_mcp_proxy_log_action "truncate" "$method response stored and enveloped for $enveloped_count content item(s) at byte_cap=$byte_cap token_cap=$token_cap lookup=$lookup_key"
  elif [[ "$truncated_count" -gt 0 ]]; then
    ralph_mcp_proxy_log_action "truncate" "$method response truncated for $truncated_count content item(s) at byte_cap=$byte_cap token_cap=$token_cap lookup=$lookup_key"
  fi
  printf '%s\n' "$shaped_json"
}

ralph_mcp_proxy_shape_response() {
  local method="${1:-}"
  local params_json="${2:-}"
  local response_json="${3:-}"
  case "$method" in
    tools/list)
      ralph_mcp_proxy_shape_tools_list "$response_json"
      ;;
    tools/call|resources/read)
      local tool_name=""
      if [[ "$method" == "tools/call" ]]; then
        tool_name="$(jq -r '.name // empty' <<< "$params_json" 2>/dev/null || true)"
      fi
      ralph_mcp_proxy_shape_text_result "$method" "$tool_name" "$response_json"
      ;;
    *)
      printf '%s\n' "$response_json"
      ;;
  esac
}
