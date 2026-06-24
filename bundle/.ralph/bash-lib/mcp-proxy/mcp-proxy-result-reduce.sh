#!/usr/bin/env bash
# Ralph stored-result local reduction MCP proxy helpers.

if [[ -n "${RALPH_MCP_PROXY_RESULT_REDUCE_LOADED:-}" ]]; then
  return
fi
RALPH_MCP_PROXY_RESULT_REDUCE_LOADED=1

_MCP_PROXY_RESULT_REDUCE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ralph_mcp_proxy_result_reduce_py() {
  printf '%s/../../python/mcp_proxy_result_reduce.py\n' "$_MCP_PROXY_RESULT_REDUCE_LIB_DIR"
}

# Rollout gate: ralph/hybrid unless RALPH_RESULT_REDUCE=0; native/no unless =1.
ralph_mcp_proxy_result_reduce_enabled() {
  local gate="${RALPH_RESULT_REDUCE:-}"
  if [[ -n "$gate" ]]; then
    case "$gate" in
      0) return 1 ;;
      1) return 0 ;;
      *)
        echo "RALPH_RESULT_REDUCE: invalid value '$gate' (use 0 or 1)" >&2
        return 2
        ;;
    esac
  fi
  case "${RALPH_MODE:-no}" in
    ralph|hybrid) return 0 ;;
    *) return 1 ;;
  esac
}

ralph_mcp_proxy_result_reduce_active() {
  if ! ralph_mcp_proxy_result_reduce_enabled; then
    return 1
  fi
  command -v python3 >/dev/null 2>&1 || return 1
  local script
  script="$(ralph_mcp_proxy_result_reduce_py)"
  [[ -f "$script" ]] || return 1
  return 0
}

ralph_mcp_proxy_result_reduce_tool_schema_json() {
  jq -n -c '
    {
      name: "ralph_proxy_result_reduce",
      description: "Reduce a stored result locally with jq, grep, or restricted awk before returning data to model context. Input is an existing stored result only.",
      inputSchema: {
        type: "object",
        properties: {
          resultId: { type: "string", description: "Source stored result id." },
          view: {
            type: "string",
            enum: ["compacted", "raw"],
            description: "Stored view to reduce (default compacted)."
          },
          reducer: {
            type: "string",
            enum: ["jq", "grep", "awk"],
            description: "Reduction engine."
          },
          expression: {
            type: "string",
            description: "jq filter, grep pattern, or restricted awk program."
          },
          ignoreCase: { type: "boolean", description: "grep: case-insensitive match." },
          invertMatch: { type: "boolean", description: "grep: invert match." },
          lineNumber: { type: "boolean", description: "grep: prefix lines with line numbers." },
          wordMatch: { type: "boolean", description: "grep: match whole words only." },
          fixedStrings: { type: "boolean", description: "grep: treat pattern as fixed string." },
          maxCount: { type: "integer", description: "grep: maximum matching lines." },
          maxOutputBytes: { type: "integer", description: "Cap reduced output bytes." },
          maxOutputLines: { type: "integer", description: "Cap reduced output lines." },
          timeoutSeconds: { type: "integer", description: "Reduction time limit in seconds." }
        },
        required: ["resultId", "reducer", "expression"]
      }
    }
  '
}

ralph_mcp_proxy_result_envelope_reduce_next_actions_json() {
  local source_result_id="${1:-}"
  local reduced_result_id="${2:-}"
  local read_window="${3:-4096}"
  local reducer="${4:-}"
  local expression="${5:-}"
  jq -nc \
    --arg sourceResultId "$source_result_id" \
    --arg reducedResultId "$reduced_result_id" \
    --arg reducer "$reducer" \
    --arg expression "$expression" \
    --argjson readWindow "$read_window" \
    '
      ($readWindow | if . < 1 then 4096 else . end) as $window
      | [
          {
            tool: "ralph_proxy_result_reduce",
            description: "Run another local reduction on the source stored result",
            arguments: {
              resultId: $sourceResultId,
              view: "compacted",
              reducer: $reducer,
              expression: $expression
            }
          },
          {
            tool: "ralph_proxy_result_search",
            description: "Search the reduced output for more matches",
            arguments: (
              if $reducedResultId != "" then {resultId: $reducedResultId, pattern: "."}
              else {resultId: $sourceResultId, pattern: "."}
              end
            )
          },
          {
            tool: "ralph_proxy_result_read",
            description: "Read more of the reduced stored view",
            arguments: (
              if $reducedResultId != "" then
                {resultId: $reducedResultId, view: "compacted", byteStart: 0, byteEnd: $window}
              else
                {resultId: $sourceResultId, view: "compacted", byteStart: 0, byteEnd: $window}
              end
            )
          },
          {
            tool: "ralph_proxy_result_summary",
            description: "Summarize reduced result size and paging breakpoints",
            arguments: {
              resultId: (if $reducedResultId != "" then $reducedResultId else $sourceResultId end)
            }
          }
        ]
    '
}

ralph_mcp_proxy_result_reduce_invoke_python() {
  local request_json="${1:-}"
  local script output_json
  script="$(ralph_mcp_proxy_result_reduce_py)"
  if ! output_json="$(printf '%s' "$request_json" | python3 "$script" 2>/dev/null)"; then
    return 1
  fi
  if ! jq -e '.ok == true' <<<"$output_json" >/dev/null 2>&1; then
    RALPH_MCP_PROXY_RESULT_REDUCE_ERROR="$(jq -r '.error // "reduction failed"' <<<"$output_json" 2>/dev/null || true)"
    export RALPH_MCP_PROXY_RESULT_REDUCE_ERROR
    return 1
  fi
  printf '%s' "$output_json"
}
