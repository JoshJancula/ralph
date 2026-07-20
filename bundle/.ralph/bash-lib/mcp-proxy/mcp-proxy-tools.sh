#!/usr/bin/env bash
# Ralph-owned MCP proxy tools (namespaced as ralph_proxy_*).
#
# These are optional, policy-gated replacements for a safe read-only subset of
# runtime-native tools. They are advertised only when proxyOwnedTools is enabled
# in policy and the active runtime supports tool replacement.
#
# First-cut catalog (read-only only): ralph_proxy_read, ralph_proxy_grep,
# ralph_proxy_glob, ralph_proxy_shell. Optional BM25 search: ralph_proxy_search
# (gated by proxyOwnedTools.searchEnabled). Optional repo-map digest:
# ralph_proxy_repomap (gated by proxyOwnedTools.repoMapEnabled). Stored-result follow-up tools:
# ralph_proxy_result_read, ralph_proxy_result_search, ralph_proxy_result_summary,
# ralph_proxy_result_reduce (gated by RALPH_RESULT_REDUCE).
# ralph_proxy_batch runs a bounded list of read-only proxy tools in one call.
# ralph_proxy_edit and ralph_proxy_write are intentionally deferred; use
# runtime-native Edit/Write or upstream Ralph MCP write tools when policy allows.

if [[ -n "${RALPH_MCP_PROXY_TOOLS_LOADED:-}" ]]; then
  return
fi
RALPH_MCP_PROXY_TOOLS_LOADED=1

_MCP_PROXY_TOOLS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${RALPH_COMPACTORS_LOADED:-}" ]]; then
  # Pin while BASH_SOURCE still resolves; subprocess callers may lose it at call time.
  export RALPH_COMPACTORS_LIB_DIR="${RALPH_COMPACTORS_LIB_DIR:-$_MCP_PROXY_TOOLS_LIB_DIR/..}"
  # shellcheck source=/dev/null
  source "$_MCP_PROXY_TOOLS_LIB_DIR/../compactors.sh"
  RALPH_COMPACTORS_LOADED=1
fi
if [[ -z "${RALPH_COMMAND_REWRITER_LOADED:-}" ]]; then
  # shellcheck source=/dev/null
  source "$_MCP_PROXY_TOOLS_LIB_DIR/../command-rewriter.sh"
  RALPH_COMMAND_REWRITER_LOADED=1
fi
if [[ -z "${RALPH_HOOK_TELEMETRY_LOADED:-}" ]]; then
  # shellcheck source=/dev/null
  source "$_MCP_PROXY_TOOLS_LIB_DIR/../hook-telemetry.sh"
  RALPH_HOOK_TELEMETRY_LOADED=1
fi
if [[ -z "${RALPH_NATIVE_SHELL_WRAPPER_LIB_LOADED:-}" ]]; then
  # shellcheck source=/dev/null
  source "$_MCP_PROXY_TOOLS_LIB_DIR/../native-hook/native-shell-wrapper.sh"
fi
if [[ -z "${RALPH_REPO_MAP_LOADED:-}" ]]; then
  # shellcheck source=/dev/null
  source "$_MCP_PROXY_TOOLS_LIB_DIR/../repo-map.sh"
fi
if [[ -z "${RALPH_MCP_PROXY_APPROVALS_LOADED:-}" ]]; then
  # shellcheck source=/dev/null
  source "$_MCP_PROXY_TOOLS_LIB_DIR/mcp-proxy-approvals.sh"
fi
if [[ -z "${RALPH_MCP_PROXY_PLAN_MEMORY_LOADED:-}" ]]; then
  # shellcheck source=/dev/null
  source "$_MCP_PROXY_TOOLS_LIB_DIR/mcp-proxy-plan-memory.sh"
fi
if [[ -z "${RALPH_MCP_PROXY_RESULT_REDUCE_LOADED:-}" ]]; then
  # shellcheck source=/dev/null
  source "$_MCP_PROXY_TOOLS_LIB_DIR/mcp-proxy-result-reduce.sh"
fi

if [[ -z "${RALPH_MCP_PROXY_CAPABILITY_LOADED:-}" ]]; then
  RALPH_MCP_PROXY_CAPABILITY_LOADED=1

  ralph_mcp_proxy_runtime_supports_tool_replacement() {
    local runtime="${1:-${RALPH_MCP_PROXY_RUNTIME:-}}"
    case "$runtime" in
      claude|opencode)
        return 0
        ;;
      cursor|codex)
        return 1
        ;;
      *)
        return 1
        ;;
    esac
  }
fi

readonly RALPH_PROXY_TOOL_PREFIX="ralph_proxy_"

# Prints the exact first-cut owned tool names (one per line). Edit/Write are omitted.
ralph_mcp_proxy_first_cut_owned_tool_names() {
  printf '%s\n' \
    "${RALPH_PROXY_TOOL_PREFIX}read" \
    "${RALPH_PROXY_TOOL_PREFIX}grep" \
    "${RALPH_PROXY_TOOL_PREFIX}glob" \
    "${RALPH_PROXY_TOOL_PREFIX}shell"
}

ralph_mcp_proxy_shell_async_enabled() {
  [[ "${RALPH_PROXY_SHELL_ASYNC:-1}" != "0" ]]
}

ralph_mcp_proxy_search_tools_active() {
  if [[ "${RALPH_MCP_PROXY_POLICY_OWNED_SEARCH_ENABLED:-0}" != "1" ]]; then
    return 1
  fi
  ralph_mcp_proxy_owned_tools_active
}

ralph_mcp_proxy_repomap_tools_active() {
  if [[ "${RALPH_MCP_PROXY_POLICY_OWNED_REPOMAP_ENABLED:-0}" != "1" ]]; then
    return 1
  fi
  ralph_mcp_proxy_owned_tools_active
}

ralph_mcp_proxy_owned_tool_basename() {
  case "${1:-}" in
    "${RALPH_PROXY_TOOL_PREFIX}"read) printf '%s\n' "read" ;;
    "${RALPH_PROXY_TOOL_PREFIX}"grep) printf '%s\n' "grep" ;;
    "${RALPH_PROXY_TOOL_PREFIX}"glob) printf '%s\n' "glob" ;;
    "${RALPH_PROXY_TOOL_PREFIX}"shell) printf '%s\n' "shell" ;;
    "${RALPH_PROXY_TOOL_PREFIX}"shell_start|"${RALPH_PROXY_TOOL_PREFIX}"shell_wait|"${RALPH_PROXY_TOOL_PREFIX}"shell_status|"${RALPH_PROXY_TOOL_PREFIX}"shell_read|"${RALPH_PROXY_TOOL_PREFIX}"shell_cancel)
      if ralph_mcp_proxy_shell_async_enabled; then
        printf '%s\n' "${1#${RALPH_PROXY_TOOL_PREFIX}}"
      else
        return 1
      fi
      ;;
    "${RALPH_PROXY_TOOL_PREFIX}"search)
      if ralph_mcp_proxy_search_tools_active; then
        printf '%s\n' "search"
      else
        return 1
      fi
      ;;
    "${RALPH_PROXY_TOOL_PREFIX}"repomap)
      if ralph_mcp_proxy_repomap_tools_active; then
        printf '%s\n' "repomap"
      else
        return 1
      fi
      ;;
    "${RALPH_PROXY_TOOL_PREFIX}"tool_search)
      if ralph_mcp_proxy_compact_tool_catalog_active; then
        printf '%s\n' "tool_search"
      else
        return 1
      fi
      ;;
    "${RALPH_PROXY_TOOL_PREFIX}"memory_list|"${RALPH_PROXY_TOOL_PREFIX}"memory_read|"${RALPH_PROXY_TOOL_PREFIX}"memory_write|"${RALPH_PROXY_TOOL_PREFIX}"memory_delete)
      if ralph_mcp_proxy_plan_memory_active; then
        printf '%s\n' "${1#${RALPH_PROXY_TOOL_PREFIX}}"
      else
        return 1
      fi
      ;;
    *) return 1 ;;
  esac
}

ralph_mcp_proxy_is_owned_tool() {
  case "${1:-}" in
    ralph_proxy_batch)
      ralph_mcp_proxy_owned_tools_active
      return $?
      ;;
    ralph_proxy_tool_search)
      if ralph_mcp_proxy_compact_tool_catalog_active; then
        return 0
      fi
      return 1
      ;;
  esac
  ralph_mcp_proxy_owned_tool_basename "${1:-}" >/dev/null 2>&1
}

ralph_mcp_proxy_batch_max_operations() {
  local max="${RALPH_MCP_PROXY_BATCH_MAX_OPERATIONS:-4}"
  if [[ ! "$max" =~ ^[0-9]+$ ]] || [[ "$max" -lt 1 ]]; then
    max=4
  fi
  printf '%s\n' "$max"
}

ralph_mcp_proxy_batch_timeout_sec() {
  local timeout="${RALPH_MCP_PROXY_BATCH_TIMEOUT_SEC:-20}"
  if [[ ! "$timeout" =~ ^[0-9]+$ ]] || [[ "$timeout" -lt 1 ]]; then
    timeout=20
  fi
  printf '%s\n' "$timeout"
}

ralph_mcp_proxy_batch_operation_tool_allowed() {
  case "${1:-}" in
    ralph_proxy_read|ralph_proxy_grep|ralph_proxy_glob|ralph_proxy_search|ralph_proxy_result_read|ralph_proxy_result_search|ralph_proxy_result_summary|ralph_proxy_result_reduce)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

ralph_mcp_proxy_batch_preview_line() {
  local text="${1:-}"
  local max="${RALPH_MCP_PROXY_BATCH_PREVIEW_CHARS:-200}"
  text="${text//$'\n'/ }"
  text="${text//$'\r'/ }"
  if [[ "${#text}" -gt "$max" ]]; then
    printf '%s...' "${text:0:max}"
  else
    printf '%s' "$text"
  fi
}

ralph_mcp_proxy_owned_tool_batch_schema_json() {
  local max_ops
  max_ops="$(ralph_mcp_proxy_batch_max_operations)"
  jq -n -c --argjson maxItems "$max_ops" '
    {
      name: "ralph_proxy_batch",
      description: "Run multiple read-only Ralph proxy tools in one call.",
      inputSchema: {
        type: "object",
        properties: {
          operations: {
            type: "array",
            description: "Read-only proxy operations to run in order.",
            maxItems: $maxItems,
            items: {
              type: "object",
              properties: {
                tool: { type: "string", description: "Read-only proxy tool name." },
                arguments: { type: "object", description: "Tool arguments object." }
              },
              required: ["tool"]
            }
          }
        },
        required: ["operations"]
      }
    }
  '
}

ralph_mcp_proxy_owned_tools_active() {
  if [[ "${RALPH_MCP_PROXY_POLICY_OWNED_TOOLS_ENABLED:-0}" != "1" ]]; then
    return 1
  fi
  if [[ "${RALPH_MCP_PROXY_OWNED_TOOLS_FORCE:-0}" == "1" ]]; then
    return 0
  fi
  if [[ -n "${RALPH_MCP_PROXY_RUNTIME:-}" ]]; then
    ralph_mcp_proxy_runtime_supports_tool_replacement "$RALPH_MCP_PROXY_RUNTIME"
    return $?
  fi
  return 1
}

ralph_mcp_proxy_compact_tool_catalog_active() {
  local gate="${RALPH_MCP_COMPACT_TOOL_CATALOG:-}"
  if [[ -n "$gate" ]]; then
    case "$gate" in
      1 | true | yes | on) return 0 ;;
      0 | false | no | off) return 1 ;;
      *)
        echo "RALPH_MCP_COMPACT_TOOL_CATALOG: invalid value '$gate' (use 0 or 1)" >&2
        return 2
        ;;
    esac
  fi
  case "${RALPH_MODE:-no}" in
    ralph | hybrid) return 0 ;;
    *) return 1 ;;
  esac
}

ralph_mcp_proxy_default_core_tool_names() {
  printf '%s\n' \
    ralph_complete_todo \
    ralph_proxy_read \
    ralph_proxy_grep \
    ralph_proxy_shell \
    ralph_proxy_result_read \
    ralph_proxy_batch \
    ralph_proxy_tool_search
}

ralph_mcp_proxy_core_tool_names_json() {
  local names=() raw name
  if [[ -n "${RALPH_MCP_CORE_TOOLS:-}" ]]; then
    raw="${RALPH_MCP_CORE_TOOLS//,/ }"
    raw="${raw//;/ }"
    for name in $raw; do
      [[ -n "$name" ]] || continue
      names+=("$name")
    done
  else
    while IFS= read -r name || [[ -n "$name" ]]; do
      [[ -n "$name" ]] || continue
      names+=("$name")
    done < <(ralph_mcp_proxy_default_core_tool_names)
  fi
  if [[ "${#names[@]}" -eq 0 ]]; then
    jq -nc '[]'
    return 0
  fi
  printf '%s\n' "${names[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))'
}

# Rewrite nextActions entries that reference proxy tools hidden by the
# compact tool catalog. Hidden tools are absent from the client's tools/list,
# so a direct call fails client-side ("No such tool available" / "not found
# on server") before it ever reaches this server. Route those entries through
# ralph_proxy_tool_search action=invoke, which is always in the compact
# catalog and dispatches hidden tools server-side with full policy
# enforcement. No-op when the compact catalog is inactive.
ralph_mcp_proxy_next_actions_catalog_safe_json() {
  local actions_json="${1:-[]}"
  [[ -n "$actions_json" ]] || actions_json='[]'
  if ! ralph_mcp_proxy_compact_tool_catalog_active; then
    printf '%s\n' "$actions_json"
    return 0
  fi
  local core_names
  core_names="$(ralph_mcp_proxy_core_tool_names_json)"
  jq -c --argjson core "$core_names" '
    map(
      if ((.tool // "") as $t
          | ($t | startswith("ralph_proxy_")) and (($core | index($t)) == null))
      then {tool: "ralph_proxy_tool_search",
            args: {action: "invoke", tool: .tool, arguments: (.args // {})}}
      else .
      end
    )
  ' <<<"$actions_json"
}

# Apply ralph_mcp_proxy_next_actions_catalog_safe_json to the .nextActions
# field of a response object, leaving objects without nextActions untouched.
ralph_mcp_proxy_object_next_actions_catalog_safe_json() {
  local obj_json="${1:-}"
  [[ -n "$obj_json" ]] || obj_json='{}'
  local actions_json
  actions_json="$(jq -c '.nextActions // empty' <<<"$obj_json" 2>/dev/null)"
  if [[ -z "$actions_json" ]]; then
    printf '%s\n' "$obj_json"
    return 0
  fi
  actions_json="$(ralph_mcp_proxy_next_actions_catalog_safe_json "$actions_json")"
  jq -c --argjson nextActions "$actions_json" '.nextActions = $nextActions' <<<"$obj_json"
}

ralph_mcp_proxy_owned_tool_meta_tool_search_schema_json() {
  jq -n -c '
    {
      name: "ralph_proxy_tool_search",
      description: "Discover hidden Ralph proxy tools and invoke them server-side with full policy enforcement.",
      inputSchema: {
        type: "object",
        properties: {
          action: {
            type: "string",
            enum: ["search", "invoke"],
            description: "search ranks hidden tools; invoke dispatches one by exact name."
          },
          query: { type: "string", description: "Lexical search query (action=search)." },
          maxResults: { type: "integer", description: "Maximum ranked results (default 10)." },
          tool: { type: "string", description: "Exact discovered tool name (action=invoke)." },
          arguments: { type: "object", description: "Arguments object for the target tool (action=invoke)." }
        },
        required: ["action"]
      }
    }
  '
}

ralph_mcp_proxy_tool_search_rank_script() {
  printf '%s/../python/mcp-proxy-tool-search-rank.py\n' "${RALPH_COMPACTORS_LIB_DIR:-$_MCP_PROXY_TOOLS_LIB_DIR}"
}

ralph_mcp_proxy_tool_catalog_telemetry_log_path() {
  local plan_key="${RALPH_PLAN_KEY:-}"
  local state_root="${RALPH_PLAN_WORKSPACE_ROOT:-}"
  [[ -n "$state_root" ]] || return 1
  if [[ -z "$plan_key" ]]; then
    plan_key="mcp"
  fi
  printf '%s/logs/%s/tool-catalog-telemetry.jsonl\n' "$state_root" "$plan_key"
}

ralph_mcp_proxy_tool_catalog_telemetry_append() {
  local record_json="${1:-}"
  local log_path
  [[ -n "$record_json" ]] || return 0
  ralph_hook_telemetry_enabled || return 0
  log_path="$(ralph_mcp_proxy_tool_catalog_telemetry_log_path 2>/dev/null || true)"
  [[ -n "$log_path" ]] || return 0
  ralph_hook_telemetry_append_jsonl "$log_path" "$record_json"
}

# Emit a lightweight per-search outcome record for retrieval-quality tracking.
# result_count==0 is the in-loop search-miss signal; expanded_fallback marks a
# cross-morphology query that needed subtoken gathering; pool_capped marks a
# truncated candidate pool. No-op unless telemetry is enabled.
ralph_mcp_proxy_search_telemetry_emit() {
  local query="${1:-}" result_count="${2:-0}" candidate_count="${3:-0}"
  local expanded_fallback="${4:-0}" pool_capped="${5:-0}"
  local timestamp query_hash record_json
  ralph_hook_telemetry_enabled || return 0
  command -v jq >/dev/null 2>&1 || return 0
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  query_hash=""
  [[ -n "$query" ]] && query_hash="$(ralph_hook_telemetry_sha256 "$query")"
  [[ "$result_count" =~ ^[0-9]+$ ]] || result_count=0
  [[ "$candidate_count" =~ ^[0-9]+$ ]] || candidate_count=0
  record_json="$(jq -nc \
    --arg timestamp "$timestamp" \
    --arg queryHash "$query_hash" \
    --argjson resultCount "$result_count" \
    --argjson candidateCount "$candidate_count" \
    --argjson expandedFallback "$([[ "$expanded_fallback" == "1" ]] && echo true || echo false)" \
    --argjson poolCapped "$([[ "$pool_capped" == "1" ]] && echo true || echo false)" \
    --argjson searchMiss "$([[ "$result_count" -eq 0 ]] && echo true || echo false)" \
    '{timestamp:$timestamp, event:"search_outcome", queryHash:$queryHash, resultCount:$resultCount, candidateCount:$candidateCount, expandedFallback:$expandedFallback, poolCapped:$poolCapped, searchMiss:$searchMiss}' 2>/dev/null || true)"
  [[ -n "$record_json" ]] || return 0
  ralph_mcp_proxy_tool_catalog_telemetry_append "$record_json"
}

ralph_mcp_proxy_tool_catalog_telemetry_record_json() {
  local event="${1:-}" query="${2:-}" tool_name="${3:-}" rank="${4:-}" outcome="${5:-}"
  local tools_list_count="${6:-}" schema_bytes="${7:-}" args_shape_json="${8:-}"
  local timestamp query_hash rank_json tools_list_count_json schema_bytes_json
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  query_hash=""
  if [[ -n "$query" ]]; then
    query_hash="$(ralph_hook_telemetry_sha256 "$query")"
  fi

  rank_json="null"
  if [[ -n "$rank" && "$rank" =~ ^[0-9]+$ ]]; then
    rank_json="$rank"
  fi

  tools_list_count_json="null"
  if [[ -n "$tools_list_count" && "$tools_list_count" =~ ^[0-9]+$ ]]; then
    tools_list_count_json="$tools_list_count"
  fi

  schema_bytes_json="null"
  if [[ -n "$schema_bytes" && "$schema_bytes" =~ ^[0-9]+$ ]]; then
    schema_bytes_json="$schema_bytes"
  fi

  if [[ -n "$args_shape_json" ]] && jq -e . >/dev/null 2>&1 <<<"$args_shape_json"; then
    :
  else
    args_shape_json='{}'
  fi

  jq -nc \
    --arg timestamp "$timestamp" \
    --arg event "$event" \
    --arg queryHash "$query_hash" \
    --arg toolName "$tool_name" \
    --arg outcome "$outcome" \
    --argjson rank "$rank_json" \
    --argjson toolsListCount "$tools_list_count_json" \
    --argjson schemaBytes "$schema_bytes_json" \
    --argjson argumentShape "$args_shape_json" \
    '{
      timestamp: $timestamp,
      event: $event,
      queryHash: (if $queryHash == "" then null else $queryHash end),
      toolName: (if $toolName == "" then null else $toolName end),
      rank: $rank,
      outcome: (if $outcome == "" then null else $outcome end),
      toolsListCount: $toolsListCount,
      schemaBytes: $schemaBytes,
      argumentShape: $argumentShape
    }'
}

ralph_mcp_proxy_tool_search_sanitize_args_json() {
  local args_json="${1:-}"
  [[ -n "$args_json" ]] || args_json='{}'
  jq -c 'if type == "object" then with_entries(.value = (.value | type)) else {} end' <<<"$args_json" 2>/dev/null || printf '{}'
}

ralph_mcp_proxy_filter_tools_json_by_names() {
  local tools_json="${1:-[]}" names_json="${2:-[]}"
  jq -c --argjson names "$names_json" '
    map(select(.name as $n | ($names | index($n)) != null))
    | sort_by(.name)
  ' <<<"$tools_json"
}

ralph_mcp_proxy_hidden_tools_catalog_json() {
  local tmp_dir
  if ! ralph_mcp_proxy_compact_tool_catalog_active; then
    jq -nc '[]'
    return 0
  fi
  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/ralph-hidden-tools-XXXXXX")"
  ralph_mcp_proxy_owned_tools_full_json >"$tmp_dir/full_proxy.json"
  ralph_mcp_proxy_result_tools_full_json_with_reduce >"$tmp_dir/full_result.json"
  ralph_mcp_proxy_owned_tools_json >"$tmp_dir/adv_proxy.json"
  ralph_mcp_proxy_result_tools_json >"$tmp_dir/adv_result.json"
  jq -nc \
    --slurpfile full_proxy "$tmp_dir/full_proxy.json" \
    --slurpfile full_result "$tmp_dir/full_result.json" \
    --slurpfile advertised_proxy "$tmp_dir/adv_proxy.json" \
    --slurpfile advertised_result "$tmp_dir/adv_result.json" \
    '
      ($full_proxy[0] + $full_result[0]) as $all
      | (($advertised_proxy[0] + $advertised_result[0]) | map(.name)) as $advertised
      | $all | map(select(.name as $n | ($advertised | index($n) | not)))
      | sort_by(.name)
    '
  rm -rf "$tmp_dir"
}

ralph_mcp_proxy_hidden_tool_catalog_entry() {
  local tool_name="${1:-}"
  local catalog_json
  [[ -n "$tool_name" ]] || return 1
  catalog_json="$(ralph_mcp_proxy_hidden_tools_catalog_json)"
  jq -e --arg name "$tool_name" '.[] | select(.name == $name)' <<<"$catalog_json" >/dev/null 2>&1
}

ralph_mcp_proxy_compact_meta_tools_json() {
  if ! ralph_mcp_proxy_compact_tool_catalog_active; then
    jq -nc '[]'
    return 0
  fi
  ralph_mcp_proxy_owned_tool_meta_tool_search_schema_json | jq -c '[.]'
}

ralph_mcp_proxy_record_tools_list_telemetry() {
  local tools_json="${1:-[]}"
  local count schema_bytes record
  count="$(jq -r 'length' <<<"$tools_json")"
  schema_bytes="$(jq -c '.' <<<"$tools_json" | ralph_hook_telemetry_utf8_byte_count)"
  record="$(ralph_mcp_proxy_tool_catalog_telemetry_record_json \
    "tools_list" "" "" "" "" "$count" "$schema_bytes" '{}')"
  ralph_mcp_proxy_tool_catalog_telemetry_append "$record"
}

ralph_mcp_proxy_is_result_tool() {
  case "${1:-}" in
    ralph_proxy_result_read|ralph_proxy_result_search|ralph_proxy_result_summary|ralph_proxy_result_reduce)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

ralph_mcp_proxy_result_tools_full_json() {
  jq -n -c '
    [
      {
        name: "ralph_proxy_result_read",
        description: "Read a stored result by byte or line range. The inline envelope preview is the compacted first-pass answer. Use view=compacted (default) first for build/test/lint output, package-manager installs, CI/server logs, watcher output, and long log files. Use view=raw only for exact source/generated code/structured data or when compacted/search is insufficient.",
        inputSchema: {
          type: "object",
          properties: {
            resultId: { type: "string", description: "Result id." },
            view: {
              type: "string",
              enum: ["compacted", "raw"],
              description: "Stored view to read. Use compacted (default) for logs and command output follow-ups; use raw only for exact/full inspection of source, generated code, structured data, or missing details."
            },
            byteStart: { type: "integer", description: "Start byte offset (0-based)." },
            byteEnd: { type: "integer", description: "End byte offset (exclusive)." },
            lineStart: { type: "integer", description: "Start line (1-based)." },
            lineLimit: { type: "integer", description: "Line limit." }
          },
          required: ["resultId"]
        }
      },
      {
        name: "ralph_proxy_result_search",
        description: "Search result by regex pattern.",
        inputSchema: {
          type: "object",
          properties: {
            pattern: { type: "string", description: "Regex pattern." },
            resultId: { type: "string", description: "Result id (all if omitted)." },
            head_limit: { type: "integer", description: "Line limit." }
          },
          required: ["pattern"]
        }
      },
      {
        name: "ralph_proxy_result_summary",
        description: "Get result metadata and preview.",
        inputSchema: {
          type: "object",
          properties: {
            resultId: { type: "string", description: "Result id." }
          },
          required: ["resultId"]
        }
      }
    ]
  '
}

ralph_mcp_proxy_result_tools_full_json_with_reduce() {
  local base_json reduce_json
  base_json="$(ralph_mcp_proxy_result_tools_full_json)"
  if ! ralph_mcp_proxy_result_reduce_active; then
    printf '%s\n' "$base_json"
    return 0
  fi
  reduce_json="$(ralph_mcp_proxy_result_reduce_tool_schema_json)"
  jq -c --argjson reduce "$reduce_json" '. + [$reduce]' <<<"$base_json"
}

ralph_mcp_proxy_result_tools_json() {
  local full_json core_names
  full_json="$(ralph_mcp_proxy_result_tools_full_json_with_reduce)"
  if ! ralph_mcp_proxy_compact_tool_catalog_active; then
    printf '%s\n' "$full_json"
    return 0
  fi
  core_names="$(ralph_mcp_proxy_core_tool_names_json)"
  ralph_mcp_proxy_filter_tools_json_by_names "$full_json" "$core_names"
}

ralph_mcp_proxy_owned_tool_search_schema_json() {
  jq -n -c '
    {
      name: "ralph_proxy_search",
      description: "BM25-ranked lexical code search.",
      inputSchema: {
        type: "object",
        properties: {
          query: { type: "string", description: "Search query." },
          path: { type: "string", description: "File or directory path." },
          glob: { type: "string", description: "Glob filter." },
          head_limit: { type: "integer", description: "Result limit." }
        },
        required: ["query"]
      }
    }
  '
}

ralph_mcp_proxy_owned_tool_repomap_schema_json() {
  jq -n -c '
    {
      name: "ralph_proxy_repomap",
      description: "Aider-style repo map: files and key symbols.",
      inputSchema: {
        type: "object",
        properties: {
          path: { type: "string", description: "Directory path (default workspace root)." },
          head_limit: { type: "integer", description: "Max files to include." }
        }
      }
    }
  '
}

ralph_mcp_proxy_owned_tools_full_json() {
  local search_entry="" repomap_entry="" memory_entries="[]" async_entries="[]"
  if ralph_mcp_proxy_search_tools_active; then
    search_entry="$(ralph_mcp_proxy_owned_tool_search_schema_json)"
  fi
  if ralph_mcp_proxy_repomap_tools_active; then
    repomap_entry="$(ralph_mcp_proxy_owned_tool_repomap_schema_json)"
  fi
  if ralph_mcp_proxy_plan_memory_active; then
    memory_entries="$(ralph_mcp_proxy_owned_tool_memory_schema_json)"
  fi
  if ralph_mcp_proxy_shell_async_enabled; then
    async_entries='[
      {
        "name": "ralph_proxy_shell_start",
        "description": "Manual fallback: start a long-running allowlisted shell command and return a job id immediately. For verification commands, prefer runner-first verify: metadata instead of async shell loops.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "command": { "type": "string", "description": "Allowlisted command." },
            "description": { "type": "string", "description": "Note for logs." }
          },
          "required": ["command"]
        }
      },
      {
        "name": "ralph_proxy_shell_wait",
        "description": "Manual blocking wait: wait for an async shell job to finish or until the wait window expires. Use this instead of polling ralph_proxy_shell_status when a human is monitoring a job.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "jobId": { "type": "string", "description": "Async shell job id." },
            "tailBytes": { "type": "integer", "description": "Preview tail bytes (default 4096)." },
            "waitSeconds": { "type": "integer", "description": "Seconds to wait before reporting the current status (default 60; clamped to 1..600)." }
          },
          "required": ["jobId"]
        }
      },
      {
        "name": "ralph_proxy_shell_status",
        "description": "Manual spot check: get status and compact tail preview for an async shell job. Not a polling loop—prefer ralph_proxy_shell_wait to block until completion.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "jobId": { "type": "string", "description": "Async shell job id." },
            "tailBytes": { "type": "integer", "description": "Preview tail bytes." }
          },
          "required": ["jobId"]
        }
      },
      {
        "name": "ralph_proxy_shell_read",
        "description": "Manual follow-up: read bounded output from a completed or running async shell job. Use after ralph_proxy_shell_wait or an occasional ralph_proxy_shell_status check.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "jobId": { "type": "string", "description": "Async shell job id." },
            "stream": { "type": "string", "enum": ["stdout", "stderr", "combined"], "description": "Output stream." },
            "tailBytes": { "type": "integer", "description": "Read this many bytes from the end." },
            "byteStart": { "type": "integer", "description": "Start byte offset." },
            "byteEnd": { "type": "integer", "description": "End byte offset, exclusive." }
          },
          "required": ["jobId"]
        }
      },
      {
        "name": "ralph_proxy_shell_cancel",
        "description": "Cancel an async shell job that is no longer needed.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "jobId": { "type": "string", "description": "Async shell job id." }
          },
          "required": ["jobId"]
        }
      }
    ]'
  fi
  jq -n -c \
    --argjson search "$([[ -n "$search_entry" ]] && printf '%s' "$search_entry" || printf 'null')" \
    --argjson repomap "$([[ -n "$repomap_entry" ]] && printf '%s' "$repomap_entry" || printf 'null')" \
    --argjson memory "$memory_entries" \
    --argjson async "$async_entries" \
    --argjson batch "$(ralph_mcp_proxy_owned_tool_batch_schema_json)" '
    [
      {
        name: "ralph_proxy_read",
        description: "Read file with line/byte limits.",
        inputSchema: {
          type: "object",
          properties: {
            path: { type: "string", description: "File path." },
            offset: { type: "integer", description: "Start line (1-based)." },
            limit: { type: "integer", description: "Line limit." }
          },
          required: ["path"]
        }
      },
      {
        name: "ralph_proxy_grep",
        description: "Search files by pattern.",
        inputSchema: {
          type: "object",
          properties: {
            pattern: { type: "string", description: "Search pattern." },
            path: { type: "string", description: "File or directory path." },
            glob: { type: "string", description: "Glob filter." },
            head_limit: { type: "integer", description: "Line limit." }
          },
          required: ["pattern"]
        }
      },
      {
        name: "ralph_proxy_glob",
        description: "Find files by glob pattern.",
        inputSchema: {
          type: "object",
          properties: {
            glob_pattern: { type: "string", description: "Glob pattern." },
            target_directory: { type: "string", description: "Search directory." }
          },
          required: ["glob_pattern"]
        }
      },
      {
        name: "ralph_proxy_shell",
        description: "Execute allowlisted shell command.",
        inputSchema: {
          type: "object",
          properties: {
            command: { type: "string", description: "Allowlisted command." },
            description: { type: "string", description: "Note for logs." }
          },
          required: ["command"]
        }
      }
    ]
    + (if $search == null then [] else [$search] end)
    + (if $repomap == null then [] else [$repomap] end)
    + $memory
    + $async
    + [$batch]
  '
}

ralph_mcp_proxy_owned_tools_json() {
  local full_json core_names filtered meta_json
  full_json="$(ralph_mcp_proxy_owned_tools_full_json)"
  if ! ralph_mcp_proxy_compact_tool_catalog_active; then
    printf '%s\n' "$full_json"
    return 0
  fi
  core_names="$(ralph_mcp_proxy_core_tool_names_json)"
  filtered="$(ralph_mcp_proxy_filter_tools_json_by_names "$full_json" "$core_names")"
  meta_json="$(ralph_mcp_proxy_compact_meta_tools_json)"
  jq -nc --argjson meta "$meta_json" <<<"$filtered" '
    input as $filtered
    | ($filtered + $meta) | unique_by(.name) | sort_by(.name)
  '
}

ralph_mcp_proxy_workspace_realpath() {
  local workspace="${1:-${RALPH_MCP_WORKSPACE:-}}"
  [[ -n "$workspace" ]] || return 1
  (cd "$workspace" 2>/dev/null && pwd -P)
}

ralph_mcp_proxy_merge_owned_tools_into_list() {
  local response_json="${1:-}"
  local owned_json
  if ! ralph_mcp_proxy_owned_tools_active; then
    printf '%s\n' "$response_json"
    return 0
  fi
  owned_json="$(ralph_mcp_proxy_owned_tools_json)"
  jq -c --argjson owned "$owned_json" '
    if (.result.tools? | type) != "array" then
      .result.tools = $owned
    else
      .result.tools = (.result.tools + $owned)
    end
  ' <<< "$response_json"
}

ralph_mcp_proxy_canonicalize_path() {
  local raw="${1:-}"
  local expanded="$raw"
  if [[ "$expanded" == "~" ]]; then
    expanded="$HOME"
  elif [[ "$expanded" == ~/* ]]; then
    expanded="$HOME/${expanded#~/}"
  fi
  local dir
  dir="$(cd "$(dirname "$expanded")" 2>/dev/null && pwd -P)" || return 1
  printf '%s/%s\n' "$dir" "$(basename "$expanded")"
}

# Resolve a path purely lexically: expand ~, collapse '//' and '/.' segments,
# without touching the filesystem (no symlink resolution, no existence check).
# Callers must guard against '..' separately; this helper assumes the input has
# already passed the parent-traversal check. Used to tell "path does not exist
# yet but would be inside the workspace" apart from "path escapes the workspace".
ralph_mcp_proxy_lexical_path() {
  local raw="${1:-}"
  [[ -n "$raw" ]] || return 1
  if [[ "$raw" == "~" ]]; then
    raw="$HOME"
  elif [[ "$raw" == ~/* ]]; then
    raw="$HOME/${raw#~/}"
  fi
  local seg result=""
  local IFS=/
  for seg in $raw; do
    case "$seg" in
      ''|.) continue ;;
      *) result+="/$seg" ;;
    esac
  done
  printf '%s\n' "${result:-/}"
}

# Transport-safe time cap for the synchronous read-only search tools
# (ralph_proxy_grep / _search / _repomap / _glob). The MCP server processes
# requests on a single stdio read loop, so a search over a large tree blocks
# every queued request and trips the host client's per-request transport
# timeout (`-32001 Request timed out`). Keep this strictly below that client
# timeout. Overridable with RALPH_PROXY_SEARCH_SYNC_TIMEOUT_SECONDS.
ralph_mcp_proxy_search_sync_timeout_seconds() {
  local user_cap="${RALPH_PROXY_SEARCH_SYNC_TIMEOUT_SECONDS:-}"
  if [[ -n "$user_cap" ]] && [[ "$user_cap" =~ ^[0-9]+$ ]] && (( user_cap >= 1 )); then
    printf '%s\n' "$user_cap"
    return 0
  fi
  printf '%s\n' 25
}

# Run a read-only search command with stdout captured to <outfile>, bounded by
# the transport-safe cap when the `timeout` binary is available. Returns the
# command's exit status, or 124 when the cap fired (GNU/BSD `timeout`
# convention) so callers can surface a recoverable "narrow your scope" error
# instead of silently returning zero results or blocking the transport.
# Usage: ralph_mcp_proxy_run_search_cmd <outfile> -- <cmd> [args...]
ralph_mcp_proxy_run_search_cmd() {
  local outfile="${1:-}"
  shift || true
  if [[ "${1:-}" == "--" ]]; then
    shift
  fi
  local secs rc
  secs="$(ralph_mcp_proxy_search_sync_timeout_seconds)"
  if [[ -n "$secs" ]] && command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@" >"$outfile" 2>/dev/null
    rc=$?
  else
    "$@" >"$outfile" 2>/dev/null
    rc=$?
  fi
  return "$rc"
}

# Streaming bounded collector (PLAN15). Runs a search command (ripgrep or
# equivalent), bounds its output to byteCap/lineCap/perLineBytes without ever
# buffering the full result in a Bash variable, and reports whether/why it
# capped via RALPH_MCP_PROXY_GREP_COLLECT_* globals. The output temp file is
# bounded by construction: the awk bounding stage writes accepted lines
# directly to $out_file, one at a time.
#
# Args: out_file byte_cap line_cap per_line_cap -- <command...>
#
# Deliberately runs with pipefail disabled for the duration of the pipeline:
# once the awk stage caps and exits, the upstream search command can receive
# SIGPIPE (exit 141) purely because its reader closed early. That is a
# successful partial search, not a search failure, so it must not be
# conflated with a genuine ripgrep error via an unhandled `cmd | head`-style
# pipeline under the MCP server's active pipefail setting.
ralph_mcp_proxy_bounded_search_collect() {
  local out_file="${1:-}" byte_cap="${2:-}" line_cap="${3:-}" per_line_cap="${4:-}"
  shift 4 || true
  if [[ "${1:-}" == "--" ]]; then
    shift
  fi

  RALPH_MCP_PROXY_GREP_COLLECT_STATUS="error"
  RALPH_MCP_PROXY_GREP_COLLECT_CAPPED="0"
  RALPH_MCP_PROXY_GREP_COLLECT_CAP_REASON=""
  RALPH_MCP_PROXY_GREP_COLLECT_BYTES="0"
  RALPH_MCP_PROXY_GREP_COLLECT_LINES="0"
  RALPH_MCP_PROXY_GREP_COLLECT_ANY_LINE_TRUNCATED="0"
  export RALPH_MCP_PROXY_GREP_COLLECT_STATUS RALPH_MCP_PROXY_GREP_COLLECT_CAPPED \
    RALPH_MCP_PROXY_GREP_COLLECT_CAP_REASON RALPH_MCP_PROXY_GREP_COLLECT_BYTES \
    RALPH_MCP_PROXY_GREP_COLLECT_LINES RALPH_MCP_PROXY_GREP_COLLECT_ANY_LINE_TRUNCATED

  local awk_script="$_MCP_PROXY_TOOLS_LIB_DIR/mcp-proxy-grep-source-cap.awk"
  : >"$out_file"
  if [[ ! -f "$awk_script" ]] || ! [[ "$byte_cap" =~ ^[0-9]+$ ]] || ! [[ "$line_cap" =~ ^[0-9]+$ ]] \
    || ! [[ "$per_line_cap" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  local awk_stderr
  awk_stderr="$(mktemp)"

  local restore_pipefail=0
  if [[ -o pipefail ]]; then
    restore_pipefail=1
    set +o pipefail
  fi

  local secs
  secs="$(ralph_mcp_proxy_search_sync_timeout_seconds)"
  if [[ -n "$secs" ]] && command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@" 2>/dev/null \
      | LC_ALL=C awk -v byteCap="$byte_cap" -v lineCap="$line_cap" -v perLineBytes="$per_line_cap" \
        -v out="$out_file" -f "$awk_script" 2>"$awk_stderr"
  else
    "$@" 2>/dev/null \
      | LC_ALL=C awk -v byteCap="$byte_cap" -v lineCap="$line_cap" -v perLineBytes="$per_line_cap" \
        -v out="$out_file" -f "$awk_script" 2>"$awk_stderr"
  fi
  local -a _pipe_status=("${PIPESTATUS[@]}")
  local cmd_status="${_pipe_status[0]}"
  local awk_status="${_pipe_status[1]:-1}"

  if [[ "$restore_pipefail" -eq 1 ]]; then
    set -o pipefail
  fi

  local capped=0 reason="" lines=0 bytes=0 any_trunc=0
  if [[ -f "$awk_stderr" ]]; then
    local line key value
    while IFS= read -r line; do
      key="${line%%=*}"
      value="${line#*=}"
      case "$key" in
        capped) capped="$value" ;;
        reason) reason="$value" ;;
        lines) lines="$value" ;;
        bytes) bytes="$value" ;;
        anyLineTruncated) any_trunc="$value" ;;
      esac
    done <"$awk_stderr"
  fi
  rm -f "$awk_stderr"

  RALPH_MCP_PROXY_GREP_COLLECT_CAPPED="$capped"
  RALPH_MCP_PROXY_GREP_COLLECT_CAP_REASON="$reason"
  RALPH_MCP_PROXY_GREP_COLLECT_LINES="$lines"
  RALPH_MCP_PROXY_GREP_COLLECT_BYTES="$bytes"
  RALPH_MCP_PROXY_GREP_COLLECT_ANY_LINE_TRUNCATED="$any_trunc"

  if [[ "$awk_status" -ne 0 ]]; then
    RALPH_MCP_PROXY_GREP_COLLECT_STATUS="error"
    return 1
  fi

  if [[ "$capped" == "1" ]]; then
    # Deliberate partial search: cmd_status may be a genuine success (0),
    # no-match-before-cap (rare), or SIGPIPE (141) from the reader closing
    # early. All are a successful bounded capture.
    RALPH_MCP_PROXY_GREP_COLLECT_STATUS="ok"
    return 0
  fi

  case "$cmd_status" in
    0)
      RALPH_MCP_PROXY_GREP_COLLECT_STATUS="ok"
      return 0
      ;;
    1)
      RALPH_MCP_PROXY_GREP_COLLECT_STATUS="no_match"
      return 0
      ;;
    124)
      RALPH_MCP_PROXY_GREP_COLLECT_STATUS="timeout"
      return 124
      ;;
    *)
      RALPH_MCP_PROXY_GREP_COLLECT_STATUS="error"
      return 1
      ;;
  esac
}

# Exec a read-only enumeration command bounded by the transport-safe cap,
# streaming its stdout to the caller's pipe. Unlike ralph_mcp_proxy_run_search_cmd
# this is for pipeline/process-substitution contexts (e.g. `find ... -print0`
# feeding a read loop): on timeout the stream simply ends early and the caller
# proceeds with partial results, which is acceptable for best-effort enumeration.
ralph_mcp_proxy_search_timeout_cmd() {
  local secs
  secs="$(ralph_mcp_proxy_search_sync_timeout_seconds)"
  if [[ -n "$secs" ]] && command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  else
    "$@"
  fi
}

ralph_mcp_proxy_path_is_hidden_debug_log() {
  local candidate="${1:-}"
  local base
  [[ -n "$candidate" ]] || return 1
  base="$(basename "$candidate")"
  [[ "$base" == "plan-output-raw.log" ]]
}

ralph_mcp_proxy_path_under_workspace() {
  local workspace="${1:-}"
  local user_path="${2:-}"
  local require_exists="${3:-1}"
  local candidate canonical workspace_real

  if [[ -z "$workspace" || -z "$user_path" ]]; then
    return 1
  fi
  if [[ "$user_path" =~ (^|/)\.\.(/|$) ]]; then
    return 1
  fi
  if [[ "$user_path" == /* ]]; then
    candidate="$user_path"
  else
    candidate="$workspace/$user_path"
  fi
  if ! canonical="$(ralph_mcp_proxy_canonicalize_path "$candidate")"; then
    return 1
  fi
  workspace_real="$(ralph_mcp_proxy_workspace_realpath "$workspace")" || return 1
  workspace_real="${workspace_real%/}"
  if [[ "$canonical" != "$workspace_real" && "$canonical" != "$workspace_real/"* ]]; then
    return 1
  fi
  if [[ "$require_exists" == "1" && ! -e "$canonical" ]]; then
    return 1
  fi
  printf '%s\n' "$canonical"
}

ralph_mcp_proxy_builtin_read_only_roots() {
  printf '%s\n' "$HOME/.cursor/plans" "$HOME/.claude/plans"
}

ralph_mcp_proxy_builtin_writable_roots() {
  printf '%s\n' '/tmp'
}

ralph_mcp_proxy_expand_home_path() {
  local path="${1:-}"
  if [[ "$path" == "~" ]]; then
    printf '%s\n' "$HOME"
  elif [[ "$path" == "~/"* ]]; then
    printf '%s\n' "$HOME/${path:2}"
  else
    printf '%s\n' "$path"
  fi
}

ralph_mcp_proxy_resolve_allowed_root() {
  local root="${1:-}"
  root="$(ralph_mcp_proxy_expand_home_path "$root")"
  root="${root%/}"
  if [[ -z "$root" ]]; then
    return 1
  fi
  if [[ -d "$root" ]]; then
    (cd "$root" 2>/dev/null && pwd -P)
    return
  fi
  ralph_mcp_proxy_canonicalize_path "$root"
}

ralph_mcp_proxy_resolve_read_only_root() {
  local root="${1:-}"
  root="$(ralph_mcp_proxy_expand_home_path "$root")"
  root="${root%/}"
  local root_real
  if root_real="$(cd "$root" 2>/dev/null && pwd -P)"; then
    printf '%s\n' "$root_real"
  elif [[ "$root" == /* ]]; then
    printf '%s\n' "$root"
  else
    return 1
  fi
}

ralph_mcp_proxy_path_under_root() {
  local path="${1:-}"
  local root="${2:-}"
  path="${path%/}"
  root="${root%/}"
  [[ "$path" == "$root" || "$path" == "$root/"* ]]
}

ralph_mcp_proxy_path_is_allowed() {
  local user_path="${1:-}"
  local require_exists="${2:-1}"
  local canonical candidate
  local canonical_ok=0
  local -a allowed_roots=()

  ralph_mcp_proxy_add_allowed_root() {
    local resolved_root="${1:-}"
    local existing
    [[ -n "$resolved_root" ]] || return 0
    for existing in "${allowed_roots[@]}"; do
      if [[ "$existing" == "$resolved_root" ]]; then
        return 0
      fi
    done
    allowed_roots+=("$resolved_root")
  }

  if [[ -z "$user_path" ]]; then
    return 3
  fi

  if [[ "$user_path" =~ (^|/)\.\.(/|$) ]]; then
    return 1
  fi

  local mcp_workspace="${RALPH_MCP_WORKSPACE:-}"
  local agent_workspace="${RALPH_AGENT_WORKSPACE:-}"
  local plan_workspace_root="${RALPH_PLAN_WORKSPACE_ROOT:-}"

  if [[ -n "$mcp_workspace" ]]; then
    ralph_mcp_proxy_add_allowed_root "$mcp_workspace"
  fi
  if [[ -n "$agent_workspace" && "$agent_workspace" != "$mcp_workspace" ]]; then
    ralph_mcp_proxy_add_allowed_root "$agent_workspace"
  fi
  if [[ -n "$plan_workspace_root" && "$plan_workspace_root" != "$mcp_workspace" && "$plan_workspace_root" != "$agent_workspace" ]]; then
    ralph_mcp_proxy_add_allowed_root "$plan_workspace_root"
  fi

  local tmp_root tmp_root_resolved
  while IFS= read -r tmp_root; do
    if tmp_root_resolved="$(ralph_mcp_proxy_resolve_allowed_root "$tmp_root" 2>/dev/null)"; then
      ralph_mcp_proxy_add_allowed_root "$tmp_root_resolved"
    fi
  done < <(ralph_mcp_proxy_builtin_writable_roots)

  local raw_allowlist="${RALPH_MCP_ALLOWLIST:-}"
  if [[ -n "$raw_allowlist" ]]; then
    local normalized entry
    normalized="$(printf '%s\n' "$raw_allowlist" | tr ',;:' '\n')"
    while IFS= read -r entry; do
      entry="${entry#"${entry%%[![:space:]]*}"}"
      entry="${entry%"${entry##*[![:space:]]}"}"
      if [[ -z "${entry//[[:space:]]/}" ]]; then
        continue
      fi
      local resolved="$entry"
      if [[ "$resolved" == ~* ]]; then
        resolved="${resolved/#\~/$HOME}"
      elif [[ "$resolved" != /* && -n "$mcp_workspace" ]]; then
        resolved="$mcp_workspace/$resolved"
      fi
      if resolved="$(ralph_mcp_proxy_resolve_allowed_root "$resolved" 2>/dev/null)"; then
        ralph_mcp_proxy_add_allowed_root "$resolved"
      fi
    done <<< "$normalized"
  fi

  if [[ ${#allowed_roots[@]} -eq 0 ]]; then
    return 1
  fi

  if [[ "$user_path" == "~/"* ]]; then
    candidate="$HOME/${user_path:2}"
  elif [[ "$user_path" == "~" ]]; then
    candidate="$HOME"
  elif [[ "$user_path" == /* ]]; then
    candidate="$user_path"
  else
    candidate="${mcp_workspace:-${allowed_roots[0]}}/$user_path"
  fi

  canonical=""
  if canonical="$(ralph_mcp_proxy_canonicalize_path "$candidate" 2>/dev/null)"; then
    canonical_ok=1
  fi

  if [[ "$canonical_ok" -eq 1 ]] && ralph_mcp_proxy_path_is_hidden_debug_log "$canonical"; then
    return 4
  fi

  local is_under_allowed=0
  local is_under_read_only=0
  local resolved_path=""

  if [[ "$canonical_ok" -eq 1 ]]; then
    for root in "${allowed_roots[@]}"; do
      local root_real
      root_real="$(ralph_mcp_proxy_resolve_allowed_root "$root" 2>/dev/null)" || continue
      root_real="${root_real%/}"
      if [[ "$canonical" == "$root_real" || "$canonical" == "$root_real/"* ]]; then
        is_under_allowed=1
        resolved_path="$canonical"
        break
      fi
    done
  fi

  if [[ "$is_under_allowed" -eq 0 ]]; then
    local check_path="${canonical:-$candidate}"
    local ro_raw ro_root
    while IFS= read -r ro_raw; do
      ro_root="$(ralph_mcp_proxy_resolve_read_only_root "$ro_raw")" || continue
      if ralph_mcp_proxy_path_under_root "$check_path" "$ro_root"; then
        is_under_read_only=1
        resolved_path="$check_path"
        break
      fi
    done < <(ralph_mcp_proxy_builtin_read_only_roots)
  fi

  if [[ "$is_under_allowed" -eq 0 && "$is_under_read_only" -eq 0 ]]; then
    if [[ -n "${RALPH_MCP_PROXY_CURRENT_TOOL:-}" && -n "${RALPH_MCP_PROXY_CURRENT_ARGS_JSON:-}" ]]; then
      if declare -F ralph_mcp_proxy_scoped_approval_allows >/dev/null 2>&1; then
        if ralph_mcp_proxy_scoped_approval_allows "$RALPH_MCP_PROXY_CURRENT_TOOL" "boundary" "$RALPH_MCP_PROXY_CURRENT_ARGS_JSON"; then
          resolved_path="${canonical:-$candidate}"
          if [[ "$require_exists" == "1" && ! -e "$resolved_path" ]]; then
            return 2
          fi
          printf '%s\n' "$resolved_path"
          return 0
        fi
      fi
    fi
    # Canonicalization can fail for a path whose parent directory does not exist
    # (e.g. a relative path with a wrong prefix). Such a path is a mistake, not a
    # boundary escape. If the lexical (filesystem-free) form would still fall
    # under an allowed root, report "does not exist" (2) instead of "outside the
    # workspace" (1) so callers can return a recoverable error rather than a
    # fatal violation that kills the server.
    if [[ "$canonical_ok" -eq 0 ]]; then
      local lexical
      lexical="$(ralph_mcp_proxy_lexical_path "$candidate" 2>/dev/null || true)"
      if [[ -n "$lexical" ]]; then
        local root root_real root_lex
        for root in "${allowed_roots[@]}"; do
          root_real="$(ralph_mcp_proxy_resolve_allowed_root "$root" 2>/dev/null)" || root_real=""
          root_real="${root_real%/}"
          root_lex="$(ralph_mcp_proxy_lexical_path "$root" 2>/dev/null || true)"
          root_lex="${root_lex%/}"
          if [[ -n "$root_real" && ( "$lexical" == "$root_real" || "$lexical" == "$root_real/"* ) ]]; then
            return 2
          fi
          if [[ -n "$root_lex" && ( "$lexical" == "$root_lex" || "$lexical" == "$root_lex/"* ) ]]; then
            return 2
          fi
        done
      fi
    fi
    return 1
  fi

  if [[ "$require_exists" == "1" && ! -e "$resolved_path" ]]; then
    return 2
  fi

  printf '%s\n' "$resolved_path"
}

ralph_mcp_proxy_resolve_workspace_path() {
  ralph_mcp_proxy_path_under_workspace "${1:-}" "${2:-}" 1
}

ralph_mcp_proxy_normalize_args_json() {
  local raw="${1-}"
  if [[ -z "$raw" ]]; then
    printf '%s' '{}'
  else
    printf '%s' "$raw"
  fi
}

ralph_mcp_proxy_tool_error_json() {
  local message="${1:-tool error}"
  jq -n -c --arg text "$message" '{
    content: [{type: "text", text: $text}],
    isError: true
  }'
}

ralph_mcp_proxy_signal_fatal_violation() {
  local tool="${1:-unknown}"
  local reason="${2:-policy violation}"
  local arguments="${3:-}"
  local category="${4:-boundary}"
  RALPH_MCP_PROXY_FATAL_VIOLATION=1
  RALPH_MCP_PROXY_FATAL_TOOL="$tool"
  RALPH_MCP_PROXY_FATAL_REASON="$reason"
  RALPH_MCP_PROXY_FATAL_ARGUMENTS="$arguments"
  RALPH_MCP_PROXY_FATAL_CATEGORY="$category"
}

ralph_mcp_proxy_tool_success_json() {
  local text="${1:-}"
  jq -n -c --arg text "$text" '{
    content: [{type: "text", text: $text}],
    isError: false
  }'
}

ralph_mcp_proxy_call_arguments_denied() {
  local tool_name="${1:-}"
  local args_json; args_json="$(ralph_mcp_proxy_normalize_args_json "${2-}")"
  local patterns_json="${RALPH_MCP_PROXY_POLICY_DENIED_ARGUMENT_PATTERNS_JSON:-[]}"
  local denied=0
  local reason=""

  if [[ "$(jq -r 'length' <<< "$patterns_json")" -eq 0 ]]; then
    return 1
  fi

  if declare -F ralph_mcp_proxy_scoped_approval_allows >/dev/null 2>&1; then
    if ralph_mcp_proxy_scoped_approval_allows "$tool_name" "denied-arguments" "$args_json"; then
      return 1
    fi
  fi

  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    local pattern_tool pattern_arg pattern_re pattern_desc
    pattern_tool="$(jq -r '.tool // ""' <<< "$entry")"
    pattern_arg="$(jq -r '.argument // ""' <<< "$entry")"
    pattern_re="$(jq -r '.pattern // ""' <<< "$entry")"
    pattern_desc="$(jq -r '.description // ""' <<< "$entry")"
    if [[ -n "$pattern_tool" && "$pattern_tool" != "$tool_name" ]]; then
      continue
    fi
    if [[ -z "$pattern_arg" || -z "$pattern_re" ]]; then
      continue
    fi
    local value
    value="$(jq -r --arg arg "$pattern_arg" '.[$arg] // empty | tostring' <<< "$args_json" 2>/dev/null || true)"
    if [[ -z "$value" ]]; then
      continue
    fi
    if [[ "$value" =~ $pattern_re ]]; then
      denied=1
      if [[ -n "$pattern_desc" ]]; then
        reason="$pattern_desc"
      else
        reason="argument $pattern_arg denied by policy pattern for tool $tool_name"
      fi
      break
    fi
  done < <(jq -c '.[]?' <<< "$patterns_json")

  if [[ "$denied" -eq 1 ]]; then
    RALPH_MCP_PROXY_LAST_DENY_REASON="$reason"
    export RALPH_MCP_PROXY_LAST_DENY_REASON
    return 0
  fi
  return 1
}

ralph_mcp_proxy_append_windowing_telemetry() {
  local workspace="${1:-}" tool_name="${2:-}" original_bytes="${3:-0}" returned_bytes="${4:-0}"
  local original_tokens="${5:-}" returned_tokens="${6:-}" byte_cap="${7:-0}" result_id="${8:-}"
  local inline_candidate_bytes="${9:-}" inline_candidate_tokens="${10:-}"
  local delivered_bytes="${11:-}" delivered_tokens="${12:-}"
  local source_capped="${13:-}" source_cap_reason="${14:-}"
  local source_cap_limit_bytes="${15:-}" source_cap_limit_lines="${16:-}" source_cap_limit_per_line_bytes="${17:-}"
  local plan_key token_cap_triggered=0
  local plan_key_fallback_reason plan_key_fallback

  declare -F ralph_hook_telemetry_append_windowing_log >/dev/null 2>&1 || return 0
  plan_key="$(ralph_mcp_proxy_result_tool_plan_key)"
  plan_key_fallback_reason="$(ralph_mcp_proxy_result_tool_plan_key_fallback_reason)"
  if [[ -n "$plan_key_fallback_reason" ]]; then
    plan_key_fallback="true"
  else
    plan_key_fallback="false"
  fi
  if [[ "$byte_cap" =~ ^[0-9]+$ ]] && [[ "$byte_cap" -gt 0 ]] && [[ "$original_bytes" -gt "$byte_cap" ]]; then
    token_cap_triggered=1
  fi

  # Source-cap fields: only ever report sourceCapped:true (with reason and
  # limits) when the collector actually capped. Never estimate an
  # avoided-byte figure for what collection did not read -- a source cap
  # cannot know unconsumed output without defeating the cap.
  local source_complete=""
  if [[ "$source_capped" == "true" ]]; then
    source_complete="false"
  elif [[ -n "$original_bytes" ]]; then
    source_capped="false"
    source_complete="true"
  fi

  local v2_fields_json="{}"
  if declare -F ralph_hook_telemetry_windowing_v2_fields_json >/dev/null 2>&1 \
    && { [[ "$inline_candidate_bytes" =~ ^[0-9]+$ ]] || [[ "$inline_candidate_tokens" =~ ^[0-9]+$ ]] \
         || [[ "$delivered_bytes" =~ ^[0-9]+$ ]] || [[ "$delivered_tokens" =~ ^[0-9]+$ ]] \
         || [[ "$source_capped" == "true" ]]; }; then
    v2_fields_json="$(ralph_hook_telemetry_windowing_v2_fields_json \
      "$original_bytes" \
      "$inline_candidate_bytes" \
      "$inline_candidate_tokens" \
      "$delivered_bytes" \
      "$delivered_tokens" \
      "$original_bytes" \
      "$source_capped" \
      "$source_complete" \
      "$source_cap_reason" \
      "$source_cap_limit_bytes" \
      "$source_cap_limit_lines" \
      "$source_cap_limit_per_line_bytes")"
  fi

  ralph_hook_telemetry_append_windowing_log \
    "$workspace" \
    "$plan_key" \
    "$tool_name" \
    "$original_bytes" \
    "$returned_bytes" \
    "$original_tokens" \
    "$returned_tokens" \
    "$token_cap_triggered" \
    "$result_id" \
    "$v2_fields_json" \
    "$plan_key_fallback" \
    "$plan_key_fallback_reason"
}

ralph_mcp_proxy_append_readback_telemetry() {
  local workspace="${1:-}" tool_name="${2:-}" result_id="${3:-}" view="${4:-compacted}"
  local text="${5:-}"
  local reason="${6:-${RALPH_MCP_PROXY_LAST_RESULT_READBACK_REASON:-}}"
  local plan_key returned_bytes returned_tokens=""

  declare -F ralph_hook_telemetry_append_result_readback_log >/dev/null 2>&1 || return 0
  [[ -n "$result_id" ]] || return 0
  plan_key="$(ralph_mcp_proxy_result_tool_plan_key)"
  returned_bytes=${#text}
  if declare -F ralph_mcp_proxy_result_estimate_tokens >/dev/null 2>&1; then
    returned_tokens="$(ralph_mcp_proxy_result_estimate_tokens "$text" 2>/dev/null || true)"
  fi
  ralph_hook_telemetry_append_result_readback_log \
    "$workspace" \
    "$plan_key" \
    "$tool_name" \
    "$result_id" \
    "$view" \
    "$returned_bytes" \
    "$returned_tokens" \
    "$reason"
}

ralph_mcp_proxy_owned_tool_maybe_envelope_text_result() {
  local workspace="${1:-}"
  local tool_name="${2:-}"
  local storage_text="${3:-}"
  local truncated_flag="${4:-0}"
  local preview_text="${5:-$storage_text}"
  local match_metadata_json="${6:-[]}"
  local next_actions_json="${7:-}"
  local grep_pattern="${8:-}"
  local metadata_json="${9:-}"
  local extra_envelope_json="${10:-}"
  local source_capped_flag="${11:-0}"
  local byte_cap token_cap preview returned_bytes original_bytes result_id plan_key
  local breakpoints_json envelope_json compact_text marker read_window
  local original_tokens="" returned_tokens="" token_args=()
  local inline_candidate_bytes inline_candidate_tokens=""

  original_bytes=${#storage_text}
  byte_cap="$(ralph_mcp_proxy_result_byte_cap_for_tool "$tool_name")"
  token_cap="$(ralph_mcp_proxy_result_token_cap_for_tool "$tool_name")"

  # Inline candidate: the caller-supplied preview_text as handed in, i.e. the
  # output after tool-level limits (head_limit/max_matches for grep) but
  # before this function's own byte/token delivery caps are applied. This is
  # distinct from original_bytes (the full captured/stored source) and from
  # the final delivered preview computed below.
  inline_candidate_bytes="${#preview_text}"
  inline_candidate_tokens="$(ralph_mcp_proxy_result_estimate_tokens "$preview_text" 2>/dev/null || true)"

  # Two independent questions, deliberately kept apart:
  #
  #   needs_store - is the full source worth keeping for later readback?
  #   can_slim    - does the inline candidate already fit, on a tool whose
  #                 envelope carries no irreplaceable affordances?
  #
  # Collapsing these is what made windowing a net context loss: a grep whose
  # head_limit had already reduced the output to well under the cap still got the
  # full ~1,155-byte envelope purely because the stored source was big, so the
  # scaffolding cost more than inlining the (already small) output would have.
  #
  # Note truncated_flag is hardcoded to 1 by most callers, so it means "store
  # this", not "this was truncated". It cannot drive the envelope decision.
  local needs_store=0 needs_envelope=1 can_slim=0
  if [[ "$truncated_flag" == "1" ]]; then
    needs_store=1
  elif [[ "$byte_cap" =~ ^[0-9]+$ ]] && [[ "$byte_cap" -gt 0 ]] && [[ "${#preview_text}" -gt "$byte_cap" ]]; then
    needs_store=1
  elif [[ "$byte_cap" =~ ^[0-9]+$ ]] && [[ "$byte_cap" -gt 0 ]] && [[ "$original_bytes" -gt "$byte_cap" ]]; then
    needs_store=1
  elif [[ "$token_cap" =~ ^[0-9]+$ ]] && [[ "$token_cap" -gt 0 ]] \
    && declare -F ralph_mcp_proxy_result_text_exceeds_token_cap >/dev/null 2>&1 \
    && ralph_mcp_proxy_result_text_exceeds_token_cap "$preview_text" "$token_cap"; then
    needs_store=1
  elif [[ "$token_cap" =~ ^[0-9]+$ ]] && [[ "$token_cap" -gt 0 ]] \
    && declare -F ralph_mcp_proxy_result_text_exceeds_token_cap >/dev/null 2>&1 \
    && ralph_mcp_proxy_result_text_exceeds_token_cap "$storage_text" "$token_cap"; then
    needs_store=1
  fi

  # The slim envelope applies only when the caller-supplied preview would have
  # been delivered whole anyway -- nothing is being windowed away, so there is
  # nothing for breakpoints or nextActions to page through.
  if declare -F ralph_mcp_proxy_result_tool_supports_slim_envelope >/dev/null 2>&1 \
    && ralph_mcp_proxy_result_tool_supports_slim_envelope "$tool_name"; then
    can_slim=1
    if [[ "$byte_cap" =~ ^[0-9]+$ ]] && [[ "$byte_cap" -gt 0 ]] && [[ "${#preview_text}" -gt "$byte_cap" ]]; then
      can_slim=0
    elif [[ "$token_cap" =~ ^[0-9]+$ ]] && [[ "$token_cap" -gt 0 ]] \
      && declare -F ralph_mcp_proxy_result_text_exceeds_token_cap >/dev/null 2>&1 \
      && ralph_mcp_proxy_result_text_exceeds_token_cap "$preview_text" "$token_cap"; then
      can_slim=0
    fi
  fi
  [[ "$can_slim" -eq 1 ]] && needs_envelope=0

  RALPH_MCP_PROXY_LAST_RESULT_ID=""
  RALPH_MCP_PROXY_LAST_RESULT_NEEDS_ENVELOPE=0
  export RALPH_MCP_PROXY_LAST_RESULT_ID RALPH_MCP_PROXY_LAST_RESULT_NEEDS_ENVELOPE

  if [[ "$needs_store" -eq 0 ]]; then
    ralph_mcp_proxy_tool_success_json "$preview_text"
    return 0
  fi

  RALPH_MCP_PROXY_LAST_RESULT_NEEDS_ENVELOPE="$needs_envelope"
  export RALPH_MCP_PROXY_LAST_RESULT_NEEDS_ENVELOPE

  plan_key="$(ralph_mcp_proxy_result_tool_plan_key)"
  local compact_view=""
  if declare -F ralph_mcp_proxy_result_compact_view >/dev/null 2>&1; then
    compact_view="$(ralph_mcp_proxy_result_compact_view "$storage_text" "$tool_name")"
  fi
  if [[ -n "$compact_view" ]]; then
    result_id="$(ralph_mcp_proxy_result_store_write "$workspace" "$plan_key" "$storage_text" "$tool_name" "$metadata_json" "$compact_view" 2>/dev/null || true)"
  else
    result_id="$(ralph_mcp_proxy_result_store_write "$workspace" "$plan_key" "$storage_text" "$tool_name" "$metadata_json" 2>/dev/null || true)"
  fi
  if [[ -z "$result_id" ]]; then
    marker="$(ralph_mcp_proxy_truncation_marker)"
    if declare -F ralph_mcp_proxy_result_apply_preview_caps >/dev/null 2>&1; then
      ralph_mcp_proxy_result_apply_preview_caps "$preview_text" "$byte_cap" "$token_cap"
      ralph_mcp_proxy_tool_success_json "${RALPH_MCP_PROXY_RESULT_CAP_PREVIEW}${marker}"
    elif [[ "$byte_cap" =~ ^[0-9]+$ ]] && [[ "$byte_cap" -gt 0 ]] && [[ "${#preview_text}" -gt "$byte_cap" ]]; then
      ralph_mcp_proxy_tool_success_json "${preview_text:0:byte_cap}${marker}"
    else
      ralph_mcp_proxy_tool_success_json "$preview_text"
    fi
    return 0
  fi

  RALPH_MCP_PROXY_LAST_RESULT_ID="$result_id"
  export RALPH_MCP_PROXY_LAST_RESULT_ID

  # Source-cap state, when present, travels in extra_envelope_json (set by
  # callers like ralph_mcp_proxy_owned_tool_grep). Parse it once here; both the
  # footer path and the envelope path below need it.
  local source_capped="" source_cap_reason="" source_cap_limit_bytes=""
  local source_cap_limit_lines="" source_cap_limit_per_line_bytes=""
  if [[ -n "$extra_envelope_json" ]] && jq -e '.sourceCapped == true' <<<"$extra_envelope_json" >/dev/null 2>&1; then
    source_capped="true"
    source_cap_reason="$(jq -r '.sourceCapReason // empty' <<<"$extra_envelope_json")"
    source_cap_limit_bytes="$(jq -r '.sourceCapLimitBytes // empty' <<<"$extra_envelope_json")"
    source_cap_limit_lines="$(jq -r '.sourceCapLimitLines // empty' <<<"$extra_envelope_json")"
    source_cap_limit_per_line_bytes="$(jq -r '.sourceCapLimitPerLineBytes // empty' <<<"$extra_envelope_json")"
  fi

  # The inline candidate already fits, so the result is stored for readback but
  # delivered in a slim envelope: same JSON contract, none of the retrieval
  # scaffolding. Building the full envelope here would deliver more bytes than
  # inlining the preview did, which is the defect this path exists to fix.
  if [[ "$needs_envelope" -eq 0 ]]; then
    local slim_json delivered_text delivered_bytes delivered_tokens
    original_tokens="$(ralph_mcp_proxy_result_estimate_tokens "$storage_text" 2>/dev/null || true)"
    returned_tokens="$(ralph_mcp_proxy_result_estimate_tokens "$preview_text" 2>/dev/null || true)"

    slim_json="$(ralph_mcp_proxy_result_slim_envelope_build_json \
      "$preview_text" "$original_bytes" "${#preview_text}" "$result_id" \
      "$original_tokens" "$returned_tokens" "$extra_envelope_json" 2>/dev/null || true)"
    if [[ -z "$slim_json" ]]; then
      ralph_mcp_proxy_tool_success_json "$preview_text"
      return 0
    fi
    delivered_text="$slim_json"

    if declare -F ralph_hook_telemetry_utf8_byte_count >/dev/null 2>&1; then
      delivered_bytes="$(ralph_hook_telemetry_utf8_byte_count "$delivered_text" 2>/dev/null || true)"
    fi
    if [[ -z "$delivered_bytes" ]]; then
      delivered_bytes="$(printf '%s' "$delivered_text" | wc -c | tr -d ' ')"
    fi
    delivered_tokens="$(ralph_mcp_proxy_result_estimate_tokens "$delivered_text" 2>/dev/null || true)"

    ralph_mcp_proxy_append_windowing_telemetry \
      "$workspace" \
      "$tool_name" \
      "$original_bytes" \
      "${#preview_text}" \
      "$original_tokens" \
      "$returned_tokens" \
      "$byte_cap" \
      "$result_id" \
      "$inline_candidate_bytes" \
      "$inline_candidate_tokens" \
      "$delivered_bytes" \
      "$delivered_tokens" \
      "$source_capped" \
      "$source_cap_reason" \
      "$source_cap_limit_bytes" \
      "$source_cap_limit_lines" \
      "$source_cap_limit_per_line_bytes"
    ralph_mcp_proxy_tool_success_json "$delivered_text"
    return 0
  fi

  preview="$preview_text"
  returned_bytes=${#preview_text}
  original_tokens="$(ralph_mcp_proxy_result_estimate_tokens "$storage_text" 2>/dev/null || true)"
  if [[ -n "$compact_view" && "$preview_text" == "$storage_text" ]]; then
    preview="$compact_view"
    returned_bytes=${#compact_view}
  fi
  if declare -F ralph_mcp_proxy_result_apply_preview_caps >/dev/null 2>&1; then
    ralph_mcp_proxy_result_apply_preview_caps "$preview" "$byte_cap" "$token_cap"
    preview="$RALPH_MCP_PROXY_RESULT_CAP_PREVIEW"
    returned_bytes="$RALPH_MCP_PROXY_RESULT_CAP_RETURNED_BYTES"
    if [[ -n "$RALPH_MCP_PROXY_RESULT_CAP_ORIGINAL_TOKENS" ]]; then
      original_tokens="$RALPH_MCP_PROXY_RESULT_CAP_ORIGINAL_TOKENS"
    fi
    if [[ -n "$RALPH_MCP_PROXY_RESULT_CAP_RETURNED_TOKENS" ]]; then
      returned_tokens="$RALPH_MCP_PROXY_RESULT_CAP_RETURNED_TOKENS"
    fi
  elif [[ "$byte_cap" =~ ^[0-9]+$ ]] && [[ "$byte_cap" -gt 0 ]] && [[ "$returned_bytes" -gt "$byte_cap" ]]; then
    preview="${preview_text:0:byte_cap}"
    returned_bytes="$byte_cap"
    returned_tokens="$(ralph_mcp_proxy_result_estimate_tokens "$preview" 2>/dev/null || true)"
  fi

  if [[ -z "$match_metadata_json" ]]; then
    match_metadata_json='[]'
  fi
  breakpoints_json="$(ralph_mcp_proxy_result_store_generate_breakpoints_json "$workspace" "$plan_key" "$result_id" "$original_bytes" "$returned_bytes" "$byte_cap" "$match_metadata_json" 2>/dev/null || true)"
  if [[ -z "$next_actions_json" ]]; then
    read_window=4096
    if [[ "$byte_cap" =~ ^[0-9]+$ ]] && [[ "$byte_cap" -gt 0 ]]; then
      read_window="$byte_cap"
    fi
    if [[ "$tool_name" == "ralph_proxy_grep" || "$tool_name" == "ralph_proxy_search" ]]; then
      next_actions_json="$(ralph_mcp_proxy_result_envelope_grep_next_actions_json "$result_id" "$grep_pattern" "$read_window" "" "$source_capped_flag")"
    elif [[ "$tool_name" == "ralph_proxy_glob" ]]; then
      next_actions_json="$(ralph_mcp_proxy_result_envelope_glob_next_actions_json "$result_id" "$grep_pattern" "$read_window")"
    elif [[ "$tool_name" == "ralph_proxy_result_reduce" ]]; then
      local reduce_source_id reduce_reducer reduce_expression
      reduce_source_id="$(jq -r '.sourceResultId // empty' <<< "${metadata_json:-{}}")"
      reduce_reducer="$(jq -r '.reducer // empty' <<< "${metadata_json:-{}}")"
      reduce_expression="$(jq -r '.expression // empty' <<< "${metadata_json:-{}}")"
      next_actions_json="$(ralph_mcp_proxy_result_envelope_reduce_next_actions_json "$reduce_source_id" "$result_id" "$read_window" "$reduce_reducer" "$reduce_expression")"
    else
      next_actions_json="$(ralph_mcp_proxy_result_envelope_default_next_actions_json "$result_id" "$read_window")"
    fi
  fi
  if [[ "$original_tokens" =~ ^[0-9]+$ ]] && [[ "$returned_tokens" =~ ^[0-9]+$ ]]; then
    token_args=("$original_tokens" "$returned_tokens")
  fi
  if [[ ${#token_args[@]} -eq 0 ]]; then
    token_args=("" "")
  fi
  envelope_json="$(ralph_mcp_proxy_result_envelope_build_json "$preview" "$original_bytes" "$returned_bytes" "$result_id" "$breakpoints_json" "$next_actions_json" "true" "${token_args[@]}" "$extra_envelope_json")" || {
    marker="$(ralph_mcp_proxy_truncation_marker)"
    if [[ "$byte_cap" =~ ^[0-9]+$ ]] && [[ "$byte_cap" -gt 0 ]] && [[ "${#preview_text}" -gt "$byte_cap" ]]; then
      ralph_mcp_proxy_tool_success_json "${preview_text:0:byte_cap}${marker}"
    else
      ralph_mcp_proxy_tool_success_json "$preview_text"
    fi
    return 0
  }
  compact_text="$(ralph_mcp_proxy_result_envelope_compact_text "$envelope_json")" || {
    ralph_mcp_proxy_tool_success_json "$preview_text"
    return 0
  }
  # Delivered: the final compact envelope text actually sent inline, i.e.
  # after preview, breakpoints, retrieval guidance, next actions, token
  # fields, and any source-cap metadata are serialized. Not preview length.
  local delivered_bytes delivered_tokens
  if declare -F ralph_hook_telemetry_utf8_byte_count >/dev/null 2>&1; then
    delivered_bytes="$(ralph_hook_telemetry_utf8_byte_count "$compact_text" 2>/dev/null || true)"
  fi
  if [[ -z "$delivered_bytes" ]]; then
    delivered_bytes="$(printf '%s' "$compact_text" | wc -c | tr -d ' ')"
  fi
  delivered_tokens="$(ralph_mcp_proxy_result_estimate_tokens "$compact_text" 2>/dev/null || true)"

  ralph_mcp_proxy_append_windowing_telemetry \
    "$workspace" \
    "$tool_name" \
    "$original_bytes" \
    "$returned_bytes" \
    "$original_tokens" \
    "$returned_tokens" \
    "$byte_cap" \
    "$result_id" \
    "$inline_candidate_bytes" \
    "$inline_candidate_tokens" \
    "$delivered_bytes" \
    "$delivered_tokens" \
    "$source_capped" \
    "$source_cap_reason" \
    "$source_cap_limit_bytes" \
    "$source_cap_limit_lines" \
    "$source_cap_limit_per_line_bytes"
  ralph_mcp_proxy_tool_success_json "$compact_text"
}

if [[ -z "${_RALPH_PROXY_READ_DEDUPE_INIT:-}" ]]; then
  declare -gA _RALPH_PROXY_READ_DEDUPE_CACHE=()
  declare -gA _RALPH_PROXY_SEARCH_DEDUPE_CACHE=()
  if [[ -z "${RALPH_MCP_PROXY_MUTATION_COUNTER:-}" ]]; then
    RALPH_MCP_PROXY_MUTATION_COUNTER=0
    export RALPH_MCP_PROXY_MUTATION_COUNTER
  fi
  _RALPH_PROXY_READ_DEDUPE_INIT=1
fi

ralph_mcp_proxy_mutation_counter_bump() {
  local current="${RALPH_MCP_PROXY_MUTATION_COUNTER:-0}"
  [[ "$current" =~ ^[0-9]+$ ]] || current=0
  current=$((current + 1))
  RALPH_MCP_PROXY_MUTATION_COUNTER="$current"
  export RALPH_MCP_PROXY_MUTATION_COUNTER
}

ralph_mcp_proxy_read_dedupe_enabled() {
  [[ "${RALPH_PROXY_DEDUPE_READS:-1}" != "0" ]]
}

ralph_mcp_proxy_read_dedupe_cache_key() {
  local resolved="${1:-}"
  local offset="${2:-1}"
  local applied_limit="${3:-0}"
  printf '%s|%s|%s' "$resolved" "$offset" "$applied_limit"
}

ralph_mcp_proxy_read_file_metadata() {
  local resolved="${1:-}"
  local file_size file_mtime
  [[ -f "$resolved" ]] || return 1
  file_size="$(stat -f '%z' "$resolved" 2>/dev/null || stat -c '%s' "$resolved" 2>/dev/null || true)"
  file_mtime="$(stat -f '%m' "$resolved" 2>/dev/null || stat -c '%Y' "$resolved" 2>/dev/null || true)"
  [[ "$file_size" =~ ^[0-9]+$ && "$file_mtime" =~ ^[0-9]+$ ]] || return 1
  printf '%s|%s' "$file_size" "$file_mtime"
}

ralph_mcp_proxy_read_dedupe_store() {
  local cache_key="${1:-}"
  local file_size="${2:-}"
  local file_mtime="${3:-}"
  local storage_text="${4:-}"
  local truncated="${5:-0}"
  local metadata_json="${6:-}"
  local result_id="${7:-}"
  local needs_envelope="${8:-0}"

  ralph_mcp_proxy_read_dedupe_enabled || return 0
  [[ -n "$cache_key" ]] || return 0

  local entry_json
  entry_json="$(
    jq -nc \
      --argjson fileSize "$file_size" \
      --argjson fileMtime "$file_mtime" \
      --arg storageText "$storage_text" \
      --argjson truncated "$truncated" \
      --arg metadataJson "$metadata_json" \
      --arg resultId "$result_id" \
      --argjson needsEnvelope "$needs_envelope" \
      '{
        fileSize: $fileSize,
        fileMtime: $fileMtime,
        storageText: $storageText,
        truncated: $truncated,
        metadataJson: $metadataJson,
        resultId: $resultId,
        needsEnvelope: $needsEnvelope
      }'
  )" || return 1
  [[ -n "$entry_json" ]] || return 1
  _RALPH_PROXY_READ_DEDUPE_CACHE["$cache_key"]="$entry_json"
}

ralph_mcp_proxy_result_read_emit_response() {
  local workspace="${1:-}"
  local result_id="${2:-}"
  local view="${3:-compacted}"
  local text="${4:-}"
  local byte_start="${5:-0}"
  local byte_limit="${6:-0}"
  local auto_ranged="${7:-0}"
  local source_label="${8:-}"

  local byte_cap token_cap read_window preview original_bytes returned_bytes
  local envelope_json next_actions_json breakpoints_json extra_json guidance_text

  byte_cap="$(ralph_mcp_proxy_result_byte_cap_for_tool "ralph_proxy_result_read")"
  token_cap="$(ralph_mcp_proxy_result_token_cap_for_tool "ralph_proxy_result_read")"
  read_window=4096
  if [[ "$byte_cap" =~ ^[0-9]+$ ]] && [[ "$byte_cap" -gt 0 ]]; then
    read_window="$byte_cap"
  fi

  original_bytes=${#text}
  preview="$text"
  returned_bytes="$original_bytes"
  if declare -F ralph_mcp_proxy_result_apply_preview_caps >/dev/null 2>&1; then
    ralph_mcp_proxy_result_apply_preview_caps "$preview" "$byte_cap" "$token_cap"
    preview="$RALPH_MCP_PROXY_RESULT_CAP_PREVIEW"
    returned_bytes="$RALPH_MCP_PROXY_RESULT_CAP_RETURNED_BYTES"
  elif [[ "$byte_cap" =~ ^[0-9]+$ ]] && [[ "$byte_cap" -gt 0 ]] && [[ "$returned_bytes" -gt "$byte_cap" ]]; then
    preview="${text:0:byte_cap}"
    returned_bytes="$byte_cap"
  fi

  local readback_reason=""
  if [[ "$view" == "raw" ]]; then
    readback_reason="raw_exactness"
  elif [[ "$auto_ranged" == "1" ]]; then
    readback_reason="verification"
  fi
  RALPH_MCP_PROXY_LAST_RESULT_READBACK_REASON=""
  export RALPH_MCP_PROXY_LAST_RESULT_READBACK_REASON
  ralph_mcp_proxy_append_readback_telemetry "$workspace" "ralph_proxy_result_read" "$result_id" "$view" "$preview" "$readback_reason"

  if [[ "$returned_bytes" -lt "$original_bytes" ]]; then
    breakpoints_json="$(ralph_mcp_proxy_result_envelope_default_breakpoints_json "$original_bytes" "$returned_bytes")"
    next_actions_json="$(ralph_mcp_proxy_result_envelope_default_next_actions_json "$result_id" "$read_window")"
    guidance_text="Readback capped; page with byteEnd/lineLimit or use result_search before view=raw."
    if [[ "$auto_ranged" == "1" ]]; then
      guidance_text="Auto-ranged raw read; page with byteEnd/lineLimit or use result_search before escalating to more raw bytes."
    fi
    extra_json="$(jq -nc \
      --argjson autoRanged "$([[ "$auto_ranged" == "1" ]] && echo true || echo false)" \
      --arg guidance "$guidance_text" \
      --arg source "$source_label" \
      '{autoRanged: $autoRanged, guidance: $guidance}
        | if $source == "" then . else . + {source: $source} end')"
    envelope_json="$(ralph_mcp_proxy_result_envelope_build_json \
      "$preview" \
      "$original_bytes" \
      "$returned_bytes" \
      "$result_id" \
      "$breakpoints_json" \
      "$next_actions_json" \
      "true" \
      "" \
      "" \
      "$extra_json")" || {
      ralph_mcp_proxy_tool_success_json "$preview"
      return 0
    }
    ralph_mcp_proxy_tool_success_json "$(jq -c . <<< "$envelope_json")"
    return 0
  fi

  if [[ "$auto_ranged" == "1" ]]; then
    ralph_mcp_proxy_tool_success_json "(auto-ranged read; page with byteEnd/lineLimit or use result_search before view=raw)
$text"
    return 0
  fi
  ralph_mcp_proxy_tool_success_json "$text"
}

ralph_mcp_proxy_read_dedupe_emit_cached() {
  local workspace="${1:-}"
  local entry_json="${2:-}"
  local result_id storage_text metadata_json needs_envelope preview
  local original_bytes returned_bytes envelope_json plan_key
  local next_actions_json breakpoints_json read_window byte_cap

  result_id="$(jq -r '.resultId // empty' <<< "$entry_json")"
  storage_text="$(jq -r '.storageText // empty' <<< "$entry_json")"
  metadata_json="$(jq -r '.metadataJson // empty' <<< "$entry_json")"
  needs_envelope="$(jq -r '.needsEnvelope // 0' <<< "$entry_json")"

  preview="(duplicate read suppressed; use ralph_proxy_result_read with resultId)"
  original_bytes=${#storage_text}
  returned_bytes=${#preview}

  byte_cap="$(ralph_mcp_proxy_result_byte_cap_for_tool ralph_proxy_read)"
  read_window=4096
  if [[ "$byte_cap" =~ ^[0-9]+$ ]] && [[ "$byte_cap" -gt 0 ]]; then
    read_window="$byte_cap"
  fi

  if [[ "$needs_envelope" == "1" && -n "$result_id" ]]; then
    next_actions_json="$(ralph_mcp_proxy_result_envelope_default_next_actions_json "$result_id" "$read_window")"
    breakpoints_json="$(ralph_mcp_proxy_result_envelope_default_breakpoints_json "$original_bytes" "$returned_bytes")"
    envelope_json="$(ralph_mcp_proxy_result_envelope_build_json \
      "$preview" \
      "$original_bytes" \
      "$returned_bytes" \
      "$result_id" \
      "$breakpoints_json" \
      "$next_actions_json" \
      "true" \
      "" \
      "" \
      '{"deduped":true}')" || {
      ralph_mcp_proxy_tool_success_json "$preview"
      return 0
    }
    ralph_mcp_proxy_tool_success_json "$(jq -c . <<< "$envelope_json")"
    return 0
  fi

  plan_key="$(ralph_mcp_proxy_result_tool_plan_key)"
  result_id="$(ralph_mcp_proxy_result_store_write "$workspace" "$plan_key" "$storage_text" "ralph_proxy_read" "$metadata_json" 2>/dev/null || true)"
  if [[ -z "$result_id" ]]; then
    ralph_mcp_proxy_tool_success_json "$preview"
    return 0
  fi

  next_actions_json="$(ralph_mcp_proxy_result_envelope_default_next_actions_json "$result_id" "$read_window")"
  breakpoints_json="$(ralph_mcp_proxy_result_envelope_default_breakpoints_json "$original_bytes" "$returned_bytes")"
  envelope_json="$(ralph_mcp_proxy_result_envelope_build_json \
    "$preview" \
    "$original_bytes" \
    "$returned_bytes" \
    "$result_id" \
    "$breakpoints_json" \
    "$next_actions_json" \
    "true" \
    "" \
    "" \
    '{"deduped":true}')" || {
    ralph_mcp_proxy_tool_success_json "$preview"
    return 0
  }
  ralph_mcp_proxy_tool_success_json "$(jq -c . <<< "$envelope_json")"
}

ralph_mcp_proxy_read_dedupe_try_return() {
  local workspace="${1:-}"
  local cache_key="${2:-}"
  local file_size="${3:-}"
  local file_mtime="${4:-}"
  local entry_json cached_size cached_mtime

  ralph_mcp_proxy_read_dedupe_enabled || return 1
  [[ -n "$cache_key" ]] || return 1
  entry_json="${_RALPH_PROXY_READ_DEDUPE_CACHE[$cache_key]:-}"
  [[ -n "$entry_json" ]] || return 1

  cached_size="$(jq -r '.fileSize // empty' <<< "$entry_json")"
  cached_mtime="$(jq -r '.fileMtime // empty' <<< "$entry_json")"
  if [[ "$cached_size" != "$file_size" || "$cached_mtime" != "$file_mtime" ]]; then
    return 1
  fi

  ralph_mcp_proxy_read_dedupe_emit_cached "$workspace" "$entry_json"
  return 0
}

ralph_mcp_proxy_search_dedupe_enabled() {
  [[ "${RALPH_PROXY_DEDUPE_SEARCH:-1}" != "0" ]]
}

ralph_mcp_proxy_search_dedupe_canonical_args() {
  local args_json="${1:-}"
  jq -cS . <<< "$args_json" 2>/dev/null || printf '%s' "$args_json"
}

ralph_mcp_proxy_search_dedupe_cache_key() {
  local tool_name="${1:-}"
  local args_json="${2:-}"
  local canonical_args args_hash

  canonical_args="$(ralph_mcp_proxy_search_dedupe_canonical_args "$args_json")"
  args_hash="$(ralph_mcp_policy_argument_hash "$canonical_args")"
  printf '%s|%s' "$tool_name" "$args_hash"
}

ralph_mcp_proxy_search_dedupe_store() {
  local cache_key="${1:-}"
  local mutation_counter="${2:-0}"
  local storage_text="${3:-}"
  local truncated="${4:-0}"
  local metadata_json="${5:-}"
  local result_id="${6:-}"
  local entry_json

  ralph_mcp_proxy_search_dedupe_enabled || return 0
  [[ -n "$cache_key" ]] || return 0
  [[ "$mutation_counter" =~ ^[0-9]+$ ]] || mutation_counter=0

  entry_json="$(
    jq -nc \
      --argjson mutationCounter "$mutation_counter" \
      --arg storageText "$storage_text" \
      --argjson truncated "$truncated" \
      --arg metadataJson "$metadata_json" \
      --arg resultId "$result_id" \
      '{
        mutationCounter: $mutationCounter,
        storageText: $storageText,
        truncated: $truncated,
        metadataJson: $metadataJson,
        resultId: $resultId
      }'
  )" || return 1
  [[ -n "$entry_json" ]] || return 1
  _RALPH_PROXY_SEARCH_DEDUPE_CACHE["$cache_key"]="$entry_json"
}

ralph_mcp_proxy_search_dedupe_emit_cached() {
  local workspace="${1:-}"
  local tool_name="${2:-}"
  local cache_key="${3:-}"
  local entry_json="${4:-}"
  local result_id storage_text metadata_json preview tool_label
  local original_bytes returned_bytes envelope_json plan_key breakpoints_json next_actions_json read_window byte_cap

  result_id="$(jq -r '.resultId // empty' <<< "$entry_json")"
  storage_text="$(jq -r '.storageText // empty' <<< "$entry_json")"
  metadata_json="$(jq -r '.metadataJson // empty' <<< "$entry_json")"
  tool_label="${tool_name#${RALPH_PROXY_TOOL_PREFIX}}"
  preview="(duplicate ${tool_label} suppressed; use ralph_proxy_result_read with resultId)"
  original_bytes=${#storage_text}
  returned_bytes=${#preview}

  if [[ -z "$result_id" ]]; then
    plan_key="$(ralph_mcp_proxy_result_tool_plan_key)"
    result_id="$(ralph_mcp_proxy_result_store_write "$workspace" "$plan_key" "$storage_text" "$tool_name" "$metadata_json" 2>/dev/null || true)"
    if [[ -n "$result_id" ]]; then
      entry_json="$(jq -c --arg resultId "$result_id" '.resultId = $resultId' <<< "$entry_json" 2>/dev/null || printf '%s' "$entry_json")"
      _RALPH_PROXY_SEARCH_DEDUPE_CACHE["$cache_key"]="$entry_json"
    fi
  fi

  if [[ -z "$result_id" ]]; then
    ralph_mcp_proxy_tool_success_json "$preview"
    return 0
  fi

  byte_cap="$(ralph_mcp_proxy_result_byte_cap_for_tool "$tool_name")"
  read_window=4096
  if [[ "$byte_cap" =~ ^[0-9]+$ ]] && [[ "$byte_cap" -gt 0 ]]; then
    read_window="$byte_cap"
  fi
  breakpoints_json="$(ralph_mcp_proxy_result_envelope_default_breakpoints_json "$original_bytes" "$returned_bytes")"

  # A duplicate of a source-capped search must keep reporting incompleteness
  # on every replay -- it must never be re-emitted as a complete/full result
  # just because it came from the dedupe cache instead of a fresh search.
  local source_capped_cached="0"
  if [[ -n "$metadata_json" ]] && jq -e '.sourceCapped == true' <<<"$metadata_json" >/dev/null 2>&1; then
    source_capped_cached="1"
  fi

  if [[ "$tool_name" == "ralph_proxy_grep" || "$tool_name" == "ralph_proxy_search" ]]; then
    next_actions_json="$(ralph_mcp_proxy_result_envelope_grep_next_actions_json "$result_id" "" "$read_window" "" "$source_capped_cached")"
  else
    next_actions_json="$(ralph_mcp_proxy_result_envelope_default_next_actions_json "$result_id" "$read_window")"
  fi

  local dedupe_extra_json='{"deduped":true}'
  if [[ "$source_capped_cached" == "1" ]]; then
    dedupe_extra_json="$(jq -nc --argjson cached "$metadata_json" \
      '{deduped: true, sourceComplete: false, sourceCapped: true}
       + (
           $cached
           | to_entries
           | map(select(.key | test("^sourceCap|^sourceLastCaptured")))
           | from_entries
         )
       + {guidance: "The source search stopped early after hitting a source cap on the original (now deduped) call; this stored result only covers the captured prefix, not the full search space. Narrow the pattern or path (or use ralph_proxy_result_search on this resultId) for a more complete search rather than treating rawRef as exhaustive."}')"
  fi

  envelope_json="$(ralph_mcp_proxy_result_envelope_build_json \
    "$preview" \
    "$original_bytes" \
    "$returned_bytes" \
    "$result_id" \
    "$breakpoints_json" \
    "$next_actions_json" \
    "true" \
    "" \
    "" \
    "$dedupe_extra_json")" || {
    ralph_mcp_proxy_tool_success_json "$preview"
    return 0
  }
  ralph_mcp_proxy_tool_success_json "$(jq -c . <<< "$envelope_json")"
}

ralph_mcp_proxy_search_dedupe_try_return() {
  local workspace="${1:-}"
  local tool_name="${2:-}"
  local cache_key="${3:-}"
  local mutation_counter="${4:-0}"
  local entry_json cached_counter

  ralph_mcp_proxy_search_dedupe_enabled || return 1
  [[ -n "$cache_key" ]] || return 1
  entry_json="${_RALPH_PROXY_SEARCH_DEDUPE_CACHE[$cache_key]:-}"
  [[ -n "$entry_json" ]] || return 1

  cached_counter="$(jq -r '.mutationCounter // empty' <<< "$entry_json")"
  if [[ "$cached_counter" != "$mutation_counter" ]]; then
    return 1
  fi

  ralph_mcp_proxy_search_dedupe_emit_cached "$workspace" "$tool_name" "$cache_key" "$entry_json"
  return 0
}

ralph_mcp_proxy_owned_tool_read() {
  local workspace="${1:-}"
  local args_json; args_json="$(ralph_mcp_proxy_normalize_args_json "${2-}")"
  local rel_path offset limit max_bytes max_lines
  local resolved byte_count=0 line_count=0 output="" truncated=0
  local applied_limit=0 limit_policy_cap=0
  local file_size="" file_mtime="" cache_key="" dedupe_meta

  rel_path="$(jq -r '.path // empty' <<< "$args_json")"
  offset="$(jq -r '.offset // 1' <<< "$args_json")"
  limit="$(jq -r '.limit // empty' <<< "$args_json")"
  max_bytes="${RALPH_MCP_PROXY_POLICY_OWNED_MAX_READ_BYTES:-65536}"
  max_lines="${RALPH_MCP_PROXY_POLICY_OWNED_MAX_READ_LINES:-500}"

  if [[ -z "$rel_path" ]]; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_read requires path"
    return 0
  fi

  local path_check_result
  path_check_result=0
  resolved="$(ralph_mcp_proxy_path_is_allowed "$rel_path" 0)" || path_check_result=$?

  if [[ "$path_check_result" -eq 3 ]]; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_read requires path"
    return 0
  fi

  if [[ "$path_check_result" -eq 4 ]]; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_read: path is hidden debug output"
    return 0
  fi

  if [[ "$path_check_result" -eq 1 ]]; then
    local candidate resolved_display
    candidate="$rel_path"
    if [[ "$candidate" != /* && -n "${RALPH_MCP_WORKSPACE:-}" ]]; then
      candidate="$RALPH_MCP_WORKSPACE/$candidate"
    fi
    resolved_display="$(ralph_mcp_proxy_canonicalize_path "$candidate" 2>/dev/null || printf '%s' "$candidate")"
    ralph_mcp_proxy_signal_fatal_violation \
      "ralph_proxy_read" \
      "ralph_proxy_read: path is outside the workspace" \
      "path=$rel_path"
    ralph_mcp_proxy_tool_error_json \
      "Plan ${RALPH_CURRENT_PLAN_PATH:-} Todo line ${RALPH_CURRENT_TODO_LINE:-}; Permission requested: external_directory (${resolved_display})"
    return 0
  fi

  if [[ "$path_check_result" -eq 2 ]]; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_read: path does not exist"
    return 0
  fi

  if [[ -z "$resolved" ]]; then
    local resolved_display
    resolved_display="$rel_path"
    if [[ "$resolved_display" != /* && -n "${RALPH_MCP_WORKSPACE:-}" ]]; then
      resolved_display="$RALPH_MCP_WORKSPACE/$resolved_display"
    fi
    resolved_display="$(ralph_mcp_proxy_canonicalize_path "$resolved_display" 2>/dev/null || printf '%s' "$resolved_display")"
    ralph_mcp_proxy_tool_error_json \
      "Plan ${RALPH_CURRENT_PLAN_PATH:-} Todo line ${RALPH_CURRENT_TODO_LINE:-}; Permission requested: external_directory (${resolved_display})"
    return 0
  fi

  if [[ ! -e "$resolved" ]]; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_read: path does not exist"
    return 0
  fi

  if [[ ! -f "$resolved" ]]; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_read: not a regular file"
    return 0
  fi
  if [[ ! "$offset" =~ ^[0-9]+$ ]] || [[ "$offset" -lt 1 ]]; then
    offset=1
  fi
  if [[ -n "$limit" && "$limit" =~ ^[0-9]+$ ]] && [[ "$limit" -gt 0 ]]; then
    applied_limit="$limit"
    if [[ "$limit" -gt "$max_lines" ]]; then
      applied_limit="$max_lines"
      limit_policy_cap=1
    fi
  else
    applied_limit="$max_lines"
    limit_policy_cap=1
  fi
  if [[ "$applied_limit" -gt "$max_lines" ]]; then
    applied_limit="$max_lines"
    limit_policy_cap=1
  fi

  if dedupe_meta="$(ralph_mcp_proxy_read_file_metadata "$resolved" 2>/dev/null)"; then
    file_size="${dedupe_meta%%|*}"
    file_mtime="${dedupe_meta#*|}"
    cache_key="$(ralph_mcp_proxy_read_dedupe_cache_key "$resolved" "$offset" "$applied_limit")"
    if ralph_mcp_proxy_read_dedupe_try_return "$workspace" "$cache_key" "$file_size" "$file_mtime"; then
      return 0
    fi
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    line_count=$((line_count + 1))
    if [[ "$line_count" -lt "$offset" ]]; then
      continue
    fi
    local window="$((line_count - offset + 1))"
    if [[ "$window" -gt "$applied_limit" ]]; then
      if [[ "$limit_policy_cap" -eq 1 ]]; then
        truncated=1
      fi
      break
    fi
    local line_bytes=${#line}
    if [[ $((byte_count + line_bytes + 1)) -gt "$max_bytes" ]]; then
      truncated=1
      break
    fi
    output+="$line"$'\n'
    byte_count=$((byte_count + line_bytes + 1))
  done <"$resolved"

  local stored_line_end
  if [[ "$line_count" -gt 0 ]]; then
    stored_line_end=$((offset + line_count - 1))
  else
    stored_line_end="$offset"
  fi
  local metadata_json
  metadata_json="$(
    jq -nc \
      --argjson lineStart "$offset" \
      --argjson lineEnd "$stored_line_end" \
      --argjson lineLimit "$applied_limit" \
      --argjson lineCount "$line_count" \
      --argjson byteCount "$byte_count" \
      --arg policyLimited "$limit_policy_cap" \
      '{
        storageLayout: "window",
        window: {
          lineStart: $lineStart,
          lineEnd: $lineEnd,
          lineLimit: $lineLimit,
          lineCount: $lineCount,
          byteCount: $byteCount,
          policyLimited: ($policyLimited == 1)
        }
      }'
  )"
  ralph_mcp_proxy_owned_tool_maybe_envelope_text_result \
    "$workspace" \
    "ralph_proxy_read" \
    "$output" \
    "$truncated" \
    "" \
    "" \
    "" \
    "" \
    "$metadata_json"
  if [[ -n "$cache_key" && -n "$file_size" && -n "$file_mtime" ]]; then
    ralph_mcp_proxy_read_dedupe_store \
      "$cache_key" \
      "$file_size" \
      "$file_mtime" \
      "$output" \
      "$truncated" \
      "$metadata_json" \
      "${RALPH_MCP_PROXY_LAST_RESULT_ID:-}" \
      "${RALPH_MCP_PROXY_LAST_RESULT_NEEDS_ENVELOPE:-0}"
  fi
}

ralph_mcp_proxy_is_git_work_tree() {
  local dir="${1:-}"
  [[ -n "$dir" ]] || return 1
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

ralph_mcp_proxy_file_is_binary() {
  local file="${1:-}"
  [[ -f "$file" ]] || return 1
  if od -An -tx1 -N8192 "$file" 2>/dev/null | grep -qE '(^|[[:space:]])00([[:space:]]|$)'; then
    return 0
  fi
  return 1
}

ralph_mcp_proxy_glob_pattern_matches_path() {
  local pattern="${1:-}"
  local relpath="${2:-}"
  local -a candidates=()
  local candidate

  [[ -n "$pattern" && -n "$relpath" ]] || return 1
  candidates+=("$pattern")
  if [[ "$pattern" != */* ]]; then
    candidates+=("**/$pattern")
  fi
  shopt -s globstar 2>/dev/null || true
  for candidate in "${candidates[@]}"; do
    [[ "$relpath" == $candidate ]] && return 0
  done
  return 1
}

ralph_mcp_proxy_basename_matches_glob() {
  local glob_filter="${1:-}"
  local relpath="${2:-}"
  local base="${relpath##*/}"

  [[ -n "$glob_filter" && -n "$base" ]] || return 1
  [[ "$base" == $glob_filter ]]
}

ralph_mcp_proxy_enumerate_eligible_files() {
  local search_root="${1:-}"
  local out_file="${2:-}"
  local search_root_abs git_top abs_path repo_rel rel

  [[ -n "$search_root" && -n "$out_file" ]] || return 1
  if ! search_root_abs="$(cd "$search_root" && pwd -P 2>/dev/null)"; then
    return 1
  fi

  : >"$out_file"

  if ralph_mcp_proxy_is_git_work_tree "$search_root_abs"; then
    git_top="$(git -C "$search_root_abs" rev-parse --show-toplevel 2>/dev/null)" || return 1
    git_top="${git_top%/}"
    while IFS= read -r -d '' repo_rel; do
      [[ -n "$repo_rel" ]] || continue
      abs_path="$git_top/$repo_rel"
      [[ -f "$abs_path" ]] || continue
      case "$abs_path" in
        "$search_root_abs/.ralph-workspace"|"$search_root_abs/.ralph-workspace"/*)
          continue
          ;;
      esac
      case "$abs_path" in
        "$search_root_abs"|"$search_root_abs"/*)
          if [[ "$abs_path" == "$search_root_abs" ]]; then
            rel="${repo_rel##*/}"
          else
            rel="${abs_path#$search_root_abs/}"
          fi
          ralph_mcp_proxy_file_is_binary "$abs_path" && continue
          ralph_mcp_proxy_path_is_hidden_debug_log "$abs_path" && continue
          printf '%s\0' "$rel"
          ;;
      esac
    done >"$out_file" < <(git -C "$search_root_abs" ls-files -co --exclude-standard -z 2>/dev/null)
    return 0
  fi

  while IFS= read -r -d '' abs_path; do
    [[ -n "$abs_path" ]] || continue
    ralph_mcp_proxy_file_is_binary "$abs_path" && continue
    ralph_mcp_proxy_path_is_hidden_debug_log "$abs_path" && continue
    rel="${abs_path#$search_root_abs/}"
    [[ -n "$rel" && "$rel" != "$abs_path" ]] || continue
    printf '%s\0' "$rel"
  done >"$out_file" < <(
    ralph_mcp_proxy_search_timeout_cmd find "$search_root_abs" \
      \( \
        -name .git -o \
        -name .ralph-workspace -o \
        -name node_modules -o \
        -name dist -o \
        -name build -o \
        -name target -o \
        -name .next -o \
        -name .cache -o \
        -name vendor \
      \) -prune -o \
      -type f -print0 2>/dev/null
  )
}

# Pure-Bash fallback grep collector used when ripgrep is unavailable. When
# byte_cap/line_cap/per_line_cap (args 5-7) are supplied, applies the same
# source-cap contract as ralph_mcp_proxy_bounded_search_collect: per-line
# truncation, a global byte/line budget, and RALPH_MCP_PROXY_GREP_COLLECT_*
# status globals. Stops grepping further files (and further lines within a
# file) as soon as the budget is exhausted -- it does not keep scanning the
# tree merely to discard the extra output. Omitting the cap args preserves
# the prior unbounded behavior for any other caller.
ralph_mcp_proxy_owned_tool_grep_search() {
  local pattern="${1:-}"
  local search_path="${2:-}"
  local glob_filter="${3:-}"
  local output_file="${4:-}"
  local byte_cap="${5:-}" line_cap="${6:-}" per_line_cap="${7:-}"
  local tmp_files relpath abs_path line
  local caps_active=0

  [[ -n "$pattern" && -n "$search_path" && -n "$output_file" ]] || return 1
  : >"$output_file"

  if [[ "$byte_cap" =~ ^[0-9]+$ ]] && [[ "$line_cap" =~ ^[0-9]+$ ]] && [[ "$per_line_cap" =~ ^[0-9]+$ ]]; then
    caps_active=1
    RALPH_MCP_PROXY_GREP_COLLECT_STATUS="no_match"
    RALPH_MCP_PROXY_GREP_COLLECT_CAPPED="0"
    RALPH_MCP_PROXY_GREP_COLLECT_CAP_REASON=""
    RALPH_MCP_PROXY_GREP_COLLECT_BYTES="0"
    RALPH_MCP_PROXY_GREP_COLLECT_LINES="0"
    RALPH_MCP_PROXY_GREP_COLLECT_ANY_LINE_TRUNCATED="0"
    export RALPH_MCP_PROXY_GREP_COLLECT_STATUS RALPH_MCP_PROXY_GREP_COLLECT_CAPPED \
      RALPH_MCP_PROXY_GREP_COLLECT_CAP_REASON RALPH_MCP_PROXY_GREP_COLLECT_BYTES \
      RALPH_MCP_PROXY_GREP_COLLECT_LINES RALPH_MCP_PROXY_GREP_COLLECT_ANY_LINE_TRUNCATED
  fi

  local total_bytes=0 total_lines=0 any_trunc=0 capped=0 reason=""

  # Writes one prefixed match line, applying per-line truncation and the
  # running byte/line budget when caps are active. Returns 1 once capped so
  # the caller can stop feeding it further lines/files.
  _ralph_mcp_proxy_grep_search_emit() {
    local prefixed="$1"
    if [[ "$caps_active" -eq 1 ]]; then
      if [[ "${#prefixed}" -gt "$per_line_cap" ]]; then
        prefixed="${prefixed:0:per_line_cap}"
        any_trunc=1
      fi
      local line_bytes=$(( ${#prefixed} + 1 ))
      if (( total_lines + 1 > line_cap )); then
        capped=1
        reason="line_cap"
        return 1
      fi
      if (( total_bytes + line_bytes > byte_cap )); then
        capped=1
        reason="byte_cap"
        return 1
      fi
      total_bytes=$(( total_bytes + line_bytes ))
      total_lines=$(( total_lines + 1 ))
    fi
    printf '%s\n' "$prefixed" >>"$output_file"
    return 0
  }

  local search_status=0
  if [[ -f "$search_path" ]]; then
    if ralph_mcp_proxy_file_is_binary "$search_path"; then
      search_status=0
    elif [[ -n "$glob_filter" ]] && ! ralph_mcp_proxy_basename_matches_glob "$glob_filter" "${search_path##*/}"; then
      search_status=0
    else
      while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] || continue
        _ralph_mcp_proxy_grep_search_emit "$(printf '%s:%s' "${search_path##*/}" "$line")" || break
      done < <(grep -En -- "$pattern" "$search_path" 2>/dev/null || true)
    fi
  elif [[ -d "$search_path" ]]; then
    tmp_files="$(mktemp)"
    if ! ralph_mcp_proxy_enumerate_eligible_files "$search_path" "$tmp_files"; then
      rm -f "$tmp_files"
      tmp_files=""
    fi
    if [[ -n "$tmp_files" ]]; then
      while IFS= read -r -d '' relpath; do
        [[ -n "$relpath" ]] || continue
        if [[ -n "$glob_filter" ]] && ! ralph_mcp_proxy_basename_matches_glob "$glob_filter" "$relpath"; then
          continue
        fi
        abs_path="$search_path/$relpath"
        [[ -f "$abs_path" ]] || continue
        local file_capped=0
        while IFS= read -r line || [[ -n "$line" ]]; do
          [[ -n "$line" ]] || continue
          if ! _ralph_mcp_proxy_grep_search_emit "$(printf '%s:%s' "$relpath" "$line")"; then
            file_capped=1
            break
          fi
        done < <(grep -En -- "$pattern" "$abs_path" 2>/dev/null || true)
        if [[ "$file_capped" -eq 1 ]]; then
          break
        fi
      done <"$tmp_files"
      rm -f "$tmp_files"
    fi
  fi

  unset -f _ralph_mcp_proxy_grep_search_emit

  if [[ "$caps_active" -eq 1 ]]; then
    RALPH_MCP_PROXY_GREP_COLLECT_CAPPED="$capped"
    RALPH_MCP_PROXY_GREP_COLLECT_CAP_REASON="$reason"
    RALPH_MCP_PROXY_GREP_COLLECT_BYTES="$total_bytes"
    RALPH_MCP_PROXY_GREP_COLLECT_LINES="$total_lines"
    RALPH_MCP_PROXY_GREP_COLLECT_ANY_LINE_TRUNCATED="$any_trunc"
    if [[ "$total_lines" -gt 0 ]]; then
      RALPH_MCP_PROXY_GREP_COLLECT_STATUS="ok"
    else
      RALPH_MCP_PROXY_GREP_COLLECT_STATUS="no_match"
    fi
  fi
  return 0
}

ralph_mcp_proxy_owned_tool_glob_search() {
  local glob_pattern="${1:-}"
  local search_root="${2:-}"
  local output_file="${3:-}"
  local tmp_files relpath
  local -a rg_args=()

  [[ -n "$glob_pattern" && -n "$search_root" && -n "$output_file" ]] || return 1
  : >"$output_file"

  if command -v rg >/dev/null 2>&1; then
    rg_args=(--files --hidden --no-messages)
    rg_args+=(--glob '!**/.git/**')
    rg_args+=(--glob '!**/.ralph-workspace/**')
    rg_args+=(--glob '!**/node_modules/**')
    rg_args+=(--glob '!**/dist/**')
    rg_args+=(--glob '!**/build/**')
    rg_args+=(--glob '!**/target/**')
    rg_args+=(--glob '!**/.next/**')
    rg_args+=(--glob '!**/.cache/**')
    rg_args+=(--glob '!**/vendor/**')
    rg_args+=(--glob '!**/plan-output-raw.log')
    rg_args+=(--glob "$glob_pattern")
    if rg "${rg_args[@]}" "$search_root" 2>/dev/null | LC_ALL=C sort >>"$output_file"; then
      return 0
    fi
  fi

  tmp_files="$(mktemp)"
  ralph_mcp_proxy_enumerate_eligible_files "$search_root" "$tmp_files" || {
    rm -f "$tmp_files"
    return 0
  }

  while IFS= read -r -d '' relpath; do
    [[ -n "$relpath" ]] || continue
    if ralph_mcp_proxy_glob_pattern_matches_path "$glob_pattern" "$relpath"; then
      printf '%s\n' "$relpath"
    fi
  done <"$tmp_files" | LC_ALL=C sort >>"$output_file"
  rm -f "$tmp_files"
}

ralph_mcp_proxy_owned_tool_grep_count_lines() {
  local text="${1:-}"
  if [[ -z "$text" ]]; then
    printf '0\n'
    return 0
  fi
  printf '%s\n' "$text" | wc -l | tr -d ' '
}

ralph_mcp_proxy_owned_tool_grep_head_lines() {
  local text="${1:-}"
  local limit="${2:-0}"
  if [[ -z "$text" ]]; then
    return 0
  fi
  if [[ ! "$limit" =~ ^[0-9]+$ ]] || [[ "$limit" -le 0 ]]; then
    printf '%s' "$text"
    return 0
  fi
  head -n "$limit" <<<"$text"
}

ralph_mcp_proxy_owned_tool_grep() {
  local workspace="${1:-}"
  local args_json; args_json="$(ralph_mcp_proxy_normalize_args_json "${2-}")"
  local pattern rel_path glob_filter head_limit max_matches search_path tmp_out cache_key mutation_counter
  local full_text preview_text match_count return_limit truncated=0
  local match_metadata_json cluster_metadata_json byte_cap

  pattern="$(jq -r '.pattern // empty' <<< "$args_json")"
  rel_path="$(jq -r '.path // "."' <<< "$args_json")"
  glob_filter="$(jq -r '.glob // empty' <<< "$args_json")"
  head_limit="$(jq -r '.head_limit // empty' <<< "$args_json")"
  max_matches="${RALPH_MCP_PROXY_POLICY_OWNED_MAX_GREP_MATCHES:-100}"

  if [[ -z "$pattern" ]]; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_grep requires pattern"
    return 0
  fi
  if [[ "$pattern" == *$'\n'* ]]; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_grep: multiline patterns are not supported"
    return 0
  fi
  if [[ "$rel_path" == "." ]]; then
    if ! search_path="$(ralph_mcp_proxy_workspace_realpath "$workspace")"; then
      ralph_mcp_proxy_signal_fatal_violation \
        "ralph_proxy_grep" \
        "ralph_proxy_grep: workspace not available" \
        "workspace=$workspace"
      ralph_mcp_proxy_tool_error_json "${RALPH_MCP_PROXY_FATAL_REASON:-ralph_proxy_grep workspace denied}"
      return 0
    fi
  else
    local path_check_result
    path_check_result=0
    search_path="$(ralph_mcp_proxy_path_is_allowed "$rel_path" 0)" || path_check_result=$?

    if [[ "$path_check_result" -eq 3 ]]; then
      ralph_mcp_proxy_tool_error_json "ralph_proxy_grep requires path"
      return 0
    fi

    if [[ "$path_check_result" -eq 4 ]]; then
      ralph_mcp_proxy_tool_error_json "ralph_proxy_grep: path is hidden debug output"
      return 0
    fi

    if [[ "$path_check_result" -eq 1 ]]; then
      ralph_mcp_proxy_signal_fatal_violation \
        "ralph_proxy_grep" \
        "ralph_proxy_grep: path is outside the workspace" \
        "path=$rel_path"
      ralph_mcp_proxy_tool_error_json "${RALPH_MCP_PROXY_FATAL_REASON:-ralph_proxy_grep path denied}"
      return 0
    fi

    if [[ "$path_check_result" -eq 2 ]]; then
      ralph_mcp_proxy_tool_error_json "ralph_proxy_grep: path does not exist"
      return 0
    fi

    if [[ -z "$search_path" ]]; then
      ralph_mcp_proxy_tool_error_json "ralph_proxy_grep: path is outside the workspace"
      return 0
    fi

    if [[ ! -e "$search_path" ]]; then
      ralph_mcp_proxy_tool_error_json "ralph_proxy_grep: path does not exist"
      return 0
    fi
  fi

  return_limit="$max_matches"
  if [[ -n "$head_limit" && "$head_limit" =~ ^[0-9]+$ ]]; then
    if [[ "$head_limit" -lt "$return_limit" ]]; then
      return_limit="$head_limit"
    fi
  fi

  mutation_counter="${RALPH_MCP_PROXY_MUTATION_COUNTER:-0}"
  cache_key="$(ralph_mcp_proxy_search_dedupe_cache_key "ralph_proxy_grep" "$args_json")"
  if ralph_mcp_proxy_search_dedupe_try_return "$workspace" "ralph_proxy_grep" "$cache_key" "$mutation_counter"; then
    return 0
  fi
  RALPH_MCP_PROXY_LAST_RESULT_ID=""
  RALPH_MCP_PROXY_LAST_RESULT_NEEDS_ENVELOPE=0
  export RALPH_MCP_PROXY_LAST_RESULT_ID RALPH_MCP_PROXY_LAST_RESULT_NEEDS_ENVELOPE

  byte_cap="$(ralph_mcp_proxy_result_byte_cap_for_tool "ralph_proxy_grep")"
  local source_cap_policy_json source_byte_cap source_line_cap source_per_line_cap
  source_cap_policy_json="$(ralph_mcp_proxy_grep_source_cap_policy_json "$byte_cap")"
  source_byte_cap="$(jq -r '.byteCap' <<<"$source_cap_policy_json")"
  source_line_cap="$(jq -r '.lineCap' <<<"$source_cap_policy_json")"
  source_per_line_cap="$(jq -r '.perLineCap' <<<"$source_cap_policy_json")"

  tmp_out="$(mktemp)"
  local search_rc=0
  local source_capped=0 source_cap_reason="" source_last_line_partial=0
  if command -v rg >/dev/null 2>&1; then
    local -a rg_args=(--line-number --no-heading --color=never)
    if [[ -n "$glob_filter" ]]; then
      rg_args+=(--glob "$glob_filter")
    fi
    if [[ -f "$search_path" ]]; then
      if ralph_mcp_proxy_file_is_binary "$search_path"; then
        : >"$tmp_out"
      elif [[ -n "$glob_filter" ]] && ! ralph_mcp_proxy_basename_matches_glob "$glob_filter" "${search_path##*/}"; then
        : >"$tmp_out"
      else
        ralph_mcp_proxy_bounded_search_collect "$tmp_out" "$source_byte_cap" "$source_line_cap" "$source_per_line_cap" \
          -- rg "${rg_args[@]}" "$pattern" "$search_path"
        search_rc=$?
        source_capped="${RALPH_MCP_PROXY_GREP_COLLECT_CAPPED:-0}"
        source_cap_reason="${RALPH_MCP_PROXY_GREP_COLLECT_CAP_REASON:-}"
        source_last_line_partial="${RALPH_MCP_PROXY_GREP_COLLECT_ANY_LINE_TRUNCATED:-0}"
      fi
    else
      ralph_mcp_proxy_bounded_search_collect "$tmp_out" "$source_byte_cap" "$source_line_cap" "$source_per_line_cap" \
        -- rg "${rg_args[@]}" "$pattern" "$search_path"
      search_rc=$?
      source_capped="${RALPH_MCP_PROXY_GREP_COLLECT_CAPPED:-0}"
      source_cap_reason="${RALPH_MCP_PROXY_GREP_COLLECT_CAP_REASON:-}"
      source_last_line_partial="${RALPH_MCP_PROXY_GREP_COLLECT_ANY_LINE_TRUNCATED:-0}"
    fi
  else
    ralph_mcp_proxy_owned_tool_grep_search "$pattern" "$search_path" "$glob_filter" "$tmp_out" \
      "$source_byte_cap" "$source_line_cap" "$source_per_line_cap"
    search_rc=0
    source_capped="${RALPH_MCP_PROXY_GREP_COLLECT_CAPPED:-0}"
    source_cap_reason="${RALPH_MCP_PROXY_GREP_COLLECT_CAP_REASON:-}"
    source_last_line_partial="${RALPH_MCP_PROXY_GREP_COLLECT_ANY_LINE_TRUNCATED:-0}"
  fi
  # Local snapshot taken; clear the collector's globals immediately so a
  # later, unrelated call in this process cannot inherit stale cap state.
  unset RALPH_MCP_PROXY_GREP_COLLECT_STATUS RALPH_MCP_PROXY_GREP_COLLECT_CAPPED \
    RALPH_MCP_PROXY_GREP_COLLECT_CAP_REASON RALPH_MCP_PROXY_GREP_COLLECT_BYTES \
    RALPH_MCP_PROXY_GREP_COLLECT_LINES RALPH_MCP_PROXY_GREP_COLLECT_ANY_LINE_TRUNCATED

  if [[ "$search_rc" -eq 124 ]]; then
    rm -f "$tmp_out"
    ralph_mcp_proxy_tool_error_json "ralph_proxy_grep: search exceeded $(ralph_mcp_proxy_search_sync_timeout_seconds)s; narrow the path or glob filter and retry"
    return 0
  fi
  if [[ "$search_rc" -ne 0 ]] && [[ "$source_capped" != "1" ]]; then
    : >"$tmp_out"
  fi
  full_text="$(<"$tmp_out")"
  rm -f "$tmp_out"

  match_count="$(ralph_mcp_proxy_owned_tool_grep_count_lines "$full_text")"
  preview_text="$full_text"
  if [[ "$match_count" -gt "$return_limit" ]]; then
    truncated=1
    preview_text="$(ralph_mcp_proxy_owned_tool_grep_head_lines "$full_text" "$return_limit")"
  fi

  byte_cap="$(ralph_mcp_proxy_result_byte_cap_for_tool "ralph_proxy_grep")"
  if [[ "$byte_cap" =~ ^[0-9]+$ ]] && [[ "$byte_cap" -gt 0 ]] && [[ "${#preview_text}" -gt "$byte_cap" ]]; then
    truncated=1
  elif [[ "$match_count" -gt "$max_matches" ]]; then
    truncated=1
  fi

  # A source-capped search stopped early: the agent must always see that the
  # source was incomplete, even if the captured prefix alone fits within
  # return_limit/max_matches. Route through the envelope path unconditionally.
  if [[ "$source_capped" == "1" ]]; then
    truncated=1
  fi

  local storage_metadata_json
  if [[ "$source_capped" == "1" ]]; then
    storage_metadata_json="$(jq -nc \
      --arg reason "$source_cap_reason" \
      --argjson byteCap "$source_byte_cap" \
      --argjson lineCap "$source_line_cap" \
      --argjson perLineCap "$source_per_line_cap" \
      --argjson lastLinePartial "$([[ "$source_last_line_partial" == "1" ]] && printf true || printf false)" \
      '{storageLayout: "prefix", sourceComplete: false, sourceCapped: true, sourceCapReason: $reason,
        sourceCapLimitBytes: $byteCap, sourceCapLimitLines: $lineCap, sourceCapLimitPerLineBytes: $perLineCap,
        sourceLastCapturedLinePartial: $lastLinePartial}')"
  else
    storage_metadata_json='{"storageLayout":"full","sourceComplete":true,"sourceCapped":false}'
  fi

  if [[ "$truncated" -eq 0 ]]; then
    ralph_mcp_proxy_search_dedupe_store \
      "$cache_key" \
      "$mutation_counter" \
      "$full_text" \
      "$truncated" \
      "$storage_metadata_json" \
      "${RALPH_MCP_PROXY_LAST_RESULT_ID:-}"
    ralph_mcp_proxy_tool_success_json "$preview_text"
    return 0
  fi

  match_metadata_json="$(ralph_mcp_proxy_result_store_match_metadata_from_grep_output "$full_text" 2>/dev/null || true)"
  if [[ -z "$match_metadata_json" ]]; then
    match_metadata_json='[]'
  fi
  cluster_metadata_json="$(ralph_mcp_proxy_result_store_match_clusters_from_metadata "$match_metadata_json" 2>/dev/null || true)"
  if [[ -z "$cluster_metadata_json" ]]; then
    cluster_metadata_json="$match_metadata_json"
  fi

  local grep_extra_envelope_json=""
  if [[ "$source_capped" == "1" ]]; then
    grep_extra_envelope_json="$(jq -nc \
      --arg reason "$source_cap_reason" \
      --argjson byteCap "$source_byte_cap" \
      --argjson lineCap "$source_line_cap" \
      --argjson perLineCap "$source_per_line_cap" \
      --argjson lastLinePartial "$([[ "$source_last_line_partial" == "1" ]] && printf true || printf false)" \
      '{
        sourceComplete: false,
        sourceCapped: true,
        sourceCapReason: $reason,
        sourceCapLimitBytes: $byteCap,
        sourceCapLimitLines: $lineCap,
        sourceCapLimitPerLineBytes: $perLineCap,
        sourceLastCapturedLinePartial: $lastLinePartial,
        guidance: "The source search stopped early after hitting a source cap; this preview and the stored raw/compacted views only cover the captured prefix, not the full search space. Narrow the pattern or path (or use ralph_proxy_result_search on this resultId) for a more complete search rather than treating rawRef as exhaustive."
      }')"
  fi

  ralph_mcp_proxy_owned_tool_maybe_envelope_text_result \
    "$workspace" \
    "ralph_proxy_grep" \
    "$full_text" \
    "1" \
    "$preview_text" \
    "$cluster_metadata_json" \
    "" \
    "$pattern" \
    "$storage_metadata_json" \
    "$grep_extra_envelope_json" \
    "$source_capped"

  ralph_mcp_proxy_search_dedupe_store \
    "$cache_key" \
    "$mutation_counter" \
    "$full_text" \
    "$truncated" \
    "$storage_metadata_json" \
    "${RALPH_MCP_PROXY_LAST_RESULT_ID:-}"
}

ralph_mcp_proxy_owned_tool_search_escape_term() {
  local term="${1:-}"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import re, sys; print(re.escape(sys.argv[1]))' "$term"
    return 0
  fi
  printf '%s' "$term" | sed -E 's/([][\\^$.|?*+(){}])/\\\1/g'
}

ralph_mcp_proxy_owned_tool_search_normalize_terms() {
  local query="${1:-}"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$query" <<'PYTHON'
import sys
query = sys.argv[1]
strip_chars = "`'\".,;:!?()[]{}"
seen = set()
terms = []
for raw in query.split():
    term = raw.strip(strip_chars).strip()
    if not term:
        continue
    key = term.lower()
    if key in seen:
        continue
    seen.add(key)
    terms.append(term)
print("\n".join(terms))
PYTHON
    return 0
  fi
  local -a raw_terms=()
  local term key
  IFS=$' \t\n' read -r -a raw_terms <<< "$query"
  for term in "${raw_terms[@]}"; do
    term="${term#"${term%%[![:space:]]*}"}"
    term="${term%"${term##*[![:space:]]}"}"
    term="${term#\"}"
    term="${term%\"}"
    [[ -n "$term" ]] || continue
    printf '%s\n' "$term"
  done | awk '!seen[tolower($0)]++'
}

ralph_mcp_proxy_owned_tool_search_build_or_pattern() {
  local query="${1:-}"
  local -a terms=()
  local term escaped joined=""
  local term_source="${2:-original}"
  local term_cmd=ralph_mcp_proxy_owned_tool_search_normalize_terms
  if [[ "$term_source" == "expanded" ]]; then
    term_cmd=ralph_mcp_proxy_owned_tool_search_expanded_terms
  fi
  while IFS= read -r term; do
    [[ -n "$term" ]] || continue
    terms+=("$term")
  done < <("$term_cmd" "$query")
  if [[ ${#terms[@]} -eq 0 ]]; then
    return 1
  fi
  for term in "${terms[@]}"; do
    escaped="$(ralph_mcp_proxy_owned_tool_search_escape_term "$term")"
    if [[ -n "$joined" ]]; then
      joined+="|"
    fi
    joined+="$escaped"
  done
  printf '%s\n' "$joined"
}

ralph_mcp_proxy_contextual_search_enabled() {
  case "${RALPH_MCP_CONTEXTUAL_SEARCH:-}" in
    1|true|yes|on) return 0 ;;
    0|false|no|off) return 1 ;;
    *)
      case "${RALPH_MODE:-no}" in
        ralph|hybrid) return 0 ;;
        *) return 1 ;;
      esac
      ;;
  esac
}

ralph_mcp_proxy_owned_tool_search_rank_script() {
  printf '%s/../python/mcp-proxy-search-rank.py\n' "${RALPH_COMPACTORS_LIB_DIR:-$_MCP_PROXY_TOOLS_LIB_DIR}"
}

ralph_mcp_proxy_owned_tool_search_normalize_script() {
  printf '%s/../python/mcp-proxy-search-normalize-terms.py\n' "${RALPH_COMPACTORS_LIB_DIR:-$_MCP_PROXY_TOOLS_LIB_DIR}"
}

# Emit original query terms plus derived identifier subtokens (camelCase /
# snake_case / digit splits) so the candidate gather reaches morphological
# variants. Expansion is gated on python3 + the normalize script; without them
# this degrades to plain (un-expanded) normalization, keeping the awk-only path
# internally consistent with the awk ranker (neither side expands).
ralph_mcp_proxy_owned_tool_search_expanded_terms() {
  local query="${1:-}"
  local normalize_script
  normalize_script="$(ralph_mcp_proxy_owned_tool_search_normalize_script)"
  if command -v python3 >/dev/null 2>&1 && [[ -f "$normalize_script" ]]; then
    python3 "$normalize_script" --expand "$query" && return 0
  fi
  ralph_mcp_proxy_owned_tool_search_normalize_terms "$query"
}

ralph_mcp_proxy_owned_tool_search_rank_awk() {
  printf '%s/mcp-proxy-search-rank.awk\n' "${RALPH_COMPACTORS_LIB_DIR:-$_MCP_PROXY_TOOLS_LIB_DIR}"
}

ralph_mcp_proxy_owned_tool_search_rank_candidates() {
  local query="${1:-}"
  local candidates_file="${2:-}"
  local max_results="${3:-50}"
  local output_file="${4:-}"
  local rank_py rank_awk
  local -a rank_args=()

  [[ -n "$query" && -f "$candidates_file" && -n "$output_file" ]] || return 1
  : >"$output_file"

  rank_py="$(ralph_mcp_proxy_owned_tool_search_rank_script)"
  rank_awk="$(ralph_mcp_proxy_owned_tool_search_rank_awk)"

  if command -v python3 >/dev/null 2>&1 && [[ -f "$rank_py" ]]; then
    rank_args=(--query "$query" --max-results "$max_results")
    if ralph_mcp_proxy_contextual_search_enabled; then
      local project_root="${RALPH_MCP_WORKSPACE:-${RALPH_PROJECT_ROOT:-}}"
      local state_root="${RALPH_PLAN_WORKSPACE_ROOT:-}"
      if [[ -z "$state_root" && -n "$project_root" ]]; then
        state_root="${project_root%/}/.ralph-workspace"
      fi
      rank_args+=(--contextual 1)
      if [[ -n "$project_root" ]]; then
        rank_args+=(--project-root "$project_root")
      fi
      if [[ -n "$state_root" ]]; then
        rank_args+=(--state-root "$state_root")
      fi
    else
      rank_args+=(--contextual 0)
    fi
    python3 "$rank_py" "${rank_args[@]}" <"$candidates_file" >"$output_file"
    return $?
  fi
  if [[ -f "$rank_awk" ]] && command -v awk >/dev/null 2>&1; then
    awk -v query="$query" -v max_results="$max_results" -f "$rank_awk" "$candidates_file" >"$output_file"
    return $?
  fi
  head -n "$max_results" <"$candidates_file" >"$output_file"
}

ralph_mcp_proxy_owned_tool_search_relative_path() {
  local search_root="${1:-}"
  local filepath="${2:-}"
  local root="${search_root%/}"
  if [[ -z "$filepath" ]]; then
    return 1
  fi
  if [[ "$filepath" != /* ]]; then
    printf '%s\n' "$filepath"
    return 0
  fi
  if [[ -n "$root" && "$filepath" == "$root"/* ]]; then
    printf '%s\n' "${filepath#$root/}"
    return 0
  fi
  printf '%s\n' "${filepath##*/}"
}

# Per-file ceiling on gathered candidate lines. Distributes the global
# max_candidates budget across files so one large file cannot starve the pool
# and truncation is relevance-distributed rather than first-N-by-path.
ralph_mcp_proxy_owned_tool_search_per_file_cap() {
  local max_candidates="${1:-500}"
  local cap="${RALPH_MCP_SEARCH_PER_FILE_CAP:-40}"
  if ! [[ "$cap" =~ ^[0-9]+$ ]] || [[ "$cap" -lt 1 ]]; then
    cap=40
  fi
  if [[ "$max_candidates" =~ ^[0-9]+$ ]] && [[ "$cap" -gt "$max_candidates" ]]; then
    cap="$max_candidates"
  fi
  printf '%s\n' "$cap"
}

ralph_mcp_proxy_owned_tool_search_gather_rg() {
  local or_pattern="${1:-}"
  local search_path="${2:-}"
  local glob_filter="${3:-}"
  local max_candidates="${4:-500}"
  local output_file="${5:-}"
  local -a rg_args=()
  local count=0
  local per_file_cap last_relpath="" file_count=0
  per_file_cap="$(ralph_mcp_proxy_owned_tool_search_per_file_cap "$max_candidates")"

  [[ -n "$or_pattern" && -n "$search_path" && -n "$output_file" ]] || return 1
  : >"$output_file"
  command -v rg >/dev/null 2>&1 || return 1

  rg_args=(--line-number --no-heading --color=never -i -e "$or_pattern")
  if [[ -n "$glob_filter" ]]; then
    rg_args+=(--glob "$glob_filter")
  fi

  if [[ -f "$search_path" ]]; then
    if ralph_mcp_proxy_file_is_binary "$search_path"; then
      return 0
    fi
    if [[ -n "$glob_filter" ]] && ! ralph_mcp_proxy_basename_matches_glob "$glob_filter" "${search_path##*/}"; then
      return 0
    fi
    rg "${rg_args[@]}" "$search_path" 2>/dev/null | head -n "$max_candidates" | while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      local relpath lineno content
      relpath="${search_path##*/}"
      lineno="${line%%:*}"
      content="${line#*:}"
      printf '%s:%s:%s\n' "$relpath" "$lineno" "$content"
    done >>"$output_file"
    return 0
  fi

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    local relpath lineno content
    relpath="${line%%:*}"
    relpath="$(ralph_mcp_proxy_owned_tool_search_relative_path "$search_path" "$relpath")"
    lineno="${line#*:}"
    lineno="${lineno%%:*}"
    content="${line#*:*:}"
    if [[ "$relpath" != "$last_relpath" ]]; then
      last_relpath="$relpath"
      file_count=0
    fi
    file_count=$((file_count + 1))
    if [[ "$file_count" -gt "$per_file_cap" ]]; then
      RALPH_MCP_PROXY_SEARCH_GATHER_CAPPED=1
      continue
    fi
    count=$((count + 1))
    if [[ "$count" -gt "$max_candidates" ]]; then
      RALPH_MCP_PROXY_SEARCH_GATHER_CAPPED=1
      break
    fi
    printf '%s:%s:%s\n' "$relpath" "$lineno" "$content"
  done < <(rg "${rg_args[@]}" "$search_path" 2>/dev/null || true) >>"$output_file"
}

ralph_mcp_proxy_owned_tool_search_gather_fallback() {
  local or_pattern="${1:-}"
  local search_path="${2:-}"
  local glob_filter="${3:-}"
  local max_candidates="${4:-500}"
  local output_file="${5:-}"
  local tmp_files relpath abs_path line lineno content count=0
  local per_file_cap file_count=0
  per_file_cap="$(ralph_mcp_proxy_owned_tool_search_per_file_cap "$max_candidates")"

  [[ -n "$or_pattern" && -n "$search_path" && -n "$output_file" ]] || return 1
  : >"$output_file"

  if [[ -f "$search_path" ]]; then
    if ralph_mcp_proxy_file_is_binary "$search_path"; then
      return 0
    fi
    if [[ -n "$glob_filter" ]] && ! ralph_mcp_proxy_basename_matches_glob "$glob_filter" "${search_path##*/}"; then
      return 0
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -n "$line" ]] || continue
      lineno="${line%%:*}"
      content="${line#*:}"
      printf '%s:%s:%s\n' "${search_path##*/}" "$lineno" "$content"
    done < <(grep -Ein -- "$or_pattern" "$search_path" 2>/dev/null || true) >>"$output_file"
    return 0
  fi

  [[ -d "$search_path" ]] || return 0

  tmp_files="$(mktemp)"
  ralph_mcp_proxy_enumerate_eligible_files "$search_path" "$tmp_files" || {
    rm -f "$tmp_files"
    return 0
  }

  while IFS= read -r -d '' relpath; do
    [[ -n "$relpath" ]] || continue
    if [[ -n "$glob_filter" ]] && ! ralph_mcp_proxy_basename_matches_glob "$glob_filter" "$relpath"; then
      continue
    fi
    abs_path="$search_path/$relpath"
    [[ -f "$abs_path" ]] || continue
    file_count=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -n "$line" ]] || continue
      file_count=$((file_count + 1))
      if [[ "$file_count" -gt "$per_file_cap" ]]; then
        RALPH_MCP_PROXY_SEARCH_GATHER_CAPPED=1
        break
      fi
      count=$((count + 1))
      if [[ "$count" -gt "$max_candidates" ]]; then
        RALPH_MCP_PROXY_SEARCH_GATHER_CAPPED=1
        rm -f "$tmp_files"
        return 0
      fi
      lineno="${line%%:*}"
      content="${line#*:}"
      printf '%s:%s:%s\n' "$relpath" "$lineno" "$content"
    done < <(grep -Ein -- "$or_pattern" "$abs_path" 2>/dev/null || true)
  done <"$tmp_files" >>"$output_file"
  rm -f "$tmp_files"
}

ralph_mcp_proxy_owned_tool_search_gather_candidates() {
  local or_pattern="${1:-}"
  local search_path="${2:-}"
  local glob_filter="${3:-}"
  local max_candidates="${4:-500}"
  local output_file="${5:-}"

  # Reset the pool-capped signal; the gather backends raise it when a per-file
  # or global cap drops candidate lines so the handler can flag truncation.
  RALPH_MCP_PROXY_SEARCH_GATHER_CAPPED=0

  if ralph_mcp_proxy_owned_tool_search_gather_rg "$or_pattern" "$search_path" "$glob_filter" "$max_candidates" "$output_file"; then
    return 0
  fi
  ralph_mcp_proxy_owned_tool_search_gather_fallback "$or_pattern" "$search_path" "$glob_filter" "$max_candidates" "$output_file"
}

ralph_mcp_proxy_owned_tool_search_match_metadata_json() {
  local ranked_text="${1:-}"
  if [[ -z "$ranked_text" ]]; then
    printf '[]\n'
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json, sys; text = sys.argv[1]; lines = [{"line": idx} for idx, raw in enumerate(text.splitlines(), start=1) if raw.strip()]; print(json.dumps(lines, separators=(",", ":")))' "$ranked_text"
    return 0
  fi
  local -a entries=()
  local line_no=0
  local raw_line
  while IFS= read -r raw_line; do
    [[ -n "$raw_line" ]] || continue
    line_no=$((line_no + 1))
    entries+=("{\"line\":$line_no}")
  done <<< "$ranked_text"
  if [[ ${#entries[@]} -eq 0 ]]; then
    printf '[]\n'
    return 0
  fi
  local joined=""
  local entry
  for entry in "${entries[@]}"; do
    if [[ -n "$joined" ]]; then
      joined+=","
    fi
    joined+="$entry"
  done
  jq -c "[${joined}]"
}

ralph_mcp_proxy_owned_tool_search_to_compact_output() {
  local ranked_file="${1:-}"
  local output_file="${2:-}"
  [[ -f "$ranked_file" && -n "$output_file" ]] || return 1
  : >"$output_file"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    local relpath lineno
    relpath="${line%%:*}"
    lineno="${line#*:}"
    lineno="${lineno%%:*}"
    printf '%s:%s\n' "$relpath" "$lineno"
  done <"$ranked_file" >>"$output_file"
}

ralph_mcp_proxy_owned_tool_search() {
  local workspace="${1:-}"
  local args_json; args_json="$(ralph_mcp_proxy_normalize_args_json "${2-}")"
  local query rel_path glob_filter head_limit
  local search_path or_pattern max_candidates max_results return_limit
  local tmp_candidates tmp_ranked full_text compact_text preview_text
  local match_count candidate_count truncated=0 byte_cap
  local match_metadata_json cluster_metadata_json

  if ! ralph_mcp_proxy_search_tools_active; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_search is disabled by proxy policy (proxyOwnedTools.searchEnabled)"
    return 0
  fi

  query="$(jq -r '.query // empty' <<< "$args_json")"
  rel_path="$(jq -r '.path // "."' <<< "$args_json")"
  glob_filter="$(jq -r '.glob // empty' <<< "$args_json")"
  head_limit="$(jq -r '.head_limit // empty' <<< "$args_json")"
  max_candidates="${RALPH_MCP_PROXY_POLICY_OWNED_MAX_SEARCH_CANDIDATES:-500}"
  max_results="${RALPH_MCP_PROXY_POLICY_OWNED_MAX_SEARCH_RESULTS:-50}"

  if [[ -z "$query" ]]; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_search requires query"
    return 0
  fi
  if [[ "$query" == *$'\n'* ]]; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_search: multiline queries are not supported"
    return 0
  fi
  if ! or_pattern="$(ralph_mcp_proxy_owned_tool_search_build_or_pattern "$query")"; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_search: query has no searchable terms"
    return 0
  fi

  if [[ "$rel_path" == "." ]]; then
    if ! search_path="$(ralph_mcp_proxy_workspace_realpath "$workspace")"; then
      ralph_mcp_proxy_signal_fatal_violation \
        "ralph_proxy_search" \
        "ralph_proxy_search: workspace not available" \
        "workspace=$workspace"
      ralph_mcp_proxy_tool_error_json "${RALPH_MCP_PROXY_FATAL_REASON:-ralph_proxy_search workspace denied}"
      return 0
    fi
  else
    local path_check_result
    path_check_result=0
    search_path="$(ralph_mcp_proxy_path_is_allowed "$rel_path" 0)" || path_check_result=$?

    if [[ "$path_check_result" -eq 3 ]]; then
      ralph_mcp_proxy_tool_error_json "ralph_proxy_search requires path"
      return 0
    fi

    if [[ "$path_check_result" -eq 4 ]]; then
      ralph_mcp_proxy_tool_error_json "ralph_proxy_search: path is hidden debug output"
      return 0
    fi

    if [[ "$path_check_result" -eq 1 ]]; then
      ralph_mcp_proxy_signal_fatal_violation \
        "ralph_proxy_search" \
        "ralph_proxy_search: path is outside the workspace" \
        "path=$rel_path"
      ralph_mcp_proxy_tool_error_json "${RALPH_MCP_PROXY_FATAL_REASON:-ralph_proxy_search path denied}"
      return 0
    fi

    if [[ "$path_check_result" -eq 2 ]]; then
      ralph_mcp_proxy_tool_error_json "ralph_proxy_search: path does not exist"
      return 0
    fi

    if [[ -z "$search_path" ]]; then
      ralph_mcp_proxy_tool_error_json "ralph_proxy_search: path is outside the workspace"
      return 0
    fi

    if [[ ! -e "$search_path" ]]; then
      ralph_mcp_proxy_tool_error_json "ralph_proxy_search: path does not exist"
      return 0
    fi
  fi

  return_limit="$max_results"
  if [[ -n "$head_limit" && "$head_limit" =~ ^[0-9]+$ ]]; then
    if [[ "$head_limit" -lt "$return_limit" ]]; then
      return_limit="$head_limit"
    fi
  fi

  tmp_candidates="$(mktemp)"
  tmp_ranked="$(mktemp)"
  ralph_mcp_proxy_owned_tool_search_gather_candidates \
    "$or_pattern" "$search_path" "$glob_filter" "$max_candidates" "$tmp_candidates"
  candidate_count="$(ralph_mcp_proxy_owned_tool_grep_count_lines "$(<"$tmp_candidates")")"

  # Fallback expansion: only when the literal-term pool is empty (cross-morphology
  # queries like a camelCase term against snake_case code) do we re-gather with
  # identifier subtokens. Expanding unconditionally floods the pool with common
  # subtokens and buries exact matches, so it is strictly a recall backstop.
  local used_expanded_fallback=0
  if [[ "$candidate_count" -eq 0 ]]; then
    local expanded_or_pattern=""
    if expanded_or_pattern="$(ralph_mcp_proxy_owned_tool_search_build_or_pattern "$query" expanded)" \
      && [[ -n "$expanded_or_pattern" && "$expanded_or_pattern" != "$or_pattern" ]]; then
      ralph_mcp_proxy_owned_tool_search_gather_candidates \
        "$expanded_or_pattern" "$search_path" "$glob_filter" "$max_candidates" "$tmp_candidates"
      candidate_count="$(ralph_mcp_proxy_owned_tool_grep_count_lines "$(<"$tmp_candidates")")"
      used_expanded_fallback=1
    fi
  fi
  if ! ralph_mcp_proxy_owned_tool_search_rank_candidates \
    "$query" "$tmp_candidates" "$return_limit" "$tmp_ranked"; then
    rm -f "$tmp_candidates" "$tmp_ranked"
    ralph_mcp_proxy_tool_error_json "ralph_proxy_search: ranking failed"
    return 0
  fi

  full_text="$(<"$tmp_ranked")"
  if [[ -n "$full_text" && "$full_text" != *$'\n' ]]; then
    full_text+=$'\n'
  fi
  compact_text="$(mktemp)"
  ralph_mcp_proxy_owned_tool_search_to_compact_output "$tmp_ranked" "$compact_text"
  preview_text="$(<"$compact_text")"
  if [[ -n "$preview_text" && "$preview_text" != *$'\n' ]]; then
    preview_text+=$'\n'
  fi
  rm -f "$tmp_candidates" "$tmp_ranked" "$compact_text"

  match_count="$(ralph_mcp_proxy_owned_tool_grep_count_lines "$preview_text")"
  ralph_mcp_proxy_search_telemetry_emit \
    "$query" "$match_count" "$candidate_count" \
    "$used_expanded_fallback" "${RALPH_MCP_PROXY_SEARCH_GATHER_CAPPED:-0}" 2>/dev/null || true
  byte_cap="$(ralph_mcp_proxy_result_byte_cap_for_tool "ralph_proxy_search")"
  if [[ "$candidate_count" -gt "$return_limit" ]]; then
    truncated=1
  elif [[ "${RALPH_MCP_PROXY_SEARCH_GATHER_CAPPED:-0}" == "1" ]]; then
    # The candidate pool itself was capped (per-file or global ceiling), so
    # signal truncation even when the returned count fits, letting the agent
    # narrow the path/glob or page via result follow-up tools.
    truncated=1
  elif [[ "$byte_cap" =~ ^[0-9]+$ ]] && [[ "$byte_cap" -gt 0 ]] && [[ "${#preview_text}" -gt "$byte_cap" ]]; then
    truncated=1
    preview_text="$(ralph_mcp_proxy_owned_tool_grep_head_lines "$preview_text" "$return_limit")"
  fi

  if [[ "$truncated" -eq 0 ]]; then
    ralph_mcp_proxy_tool_success_json "$preview_text"
    return 0
  fi

  match_metadata_json="$(ralph_mcp_proxy_owned_tool_search_match_metadata_json "$full_text" 2>/dev/null || true)"
  if [[ -z "$match_metadata_json" ]]; then
    match_metadata_json='[]'
  fi
  cluster_metadata_json="$(ralph_mcp_proxy_result_store_match_clusters_from_metadata "$match_metadata_json" 2>/dev/null || true)"
  if [[ -z "$cluster_metadata_json" ]]; then
    cluster_metadata_json="$match_metadata_json"
  fi

  ralph_mcp_proxy_owned_tool_maybe_envelope_text_result \
    "$workspace" \
    "ralph_proxy_search" \
    "$full_text" \
    "1" \
    "$preview_text" \
    "$cluster_metadata_json" \
    "" \
    "$query" \
    '{"storageLayout":"full"}'
}

ralph_mcp_proxy_owned_tool_repomap() {
  local workspace="${1:-}"
  local args_json; args_json="$(ralph_mcp_proxy_normalize_args_json "${2-}")"
  local rel_path head_limit search_path full_text preview_text byte_cap truncated=0
  local max_files return_limit

  if ! ralph_mcp_proxy_repomap_tools_active; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_repomap is disabled by proxy policy (proxyOwnedTools.repoMapEnabled)"
    return 0
  fi

  rel_path="$(jq -r '.path // "."' <<< "$args_json")"
  head_limit="$(jq -r '.head_limit // empty' <<< "$args_json")"
  max_files="${RALPH_MCP_PROXY_POLICY_OWNED_MAX_REPOMAP_FILES:-500}"
  return_limit="$max_files"
  if [[ -n "$head_limit" && "$head_limit" =~ ^[0-9]+$ ]]; then
    if [[ "$head_limit" -lt "$return_limit" ]]; then
      return_limit="$head_limit"
    fi
  fi

  if [[ "$rel_path" == "." ]]; then
    if ! search_path="$(ralph_mcp_proxy_workspace_realpath "$workspace")"; then
      ralph_mcp_proxy_signal_fatal_violation \
        "ralph_proxy_repomap" \
        "ralph_proxy_repomap: workspace not available" \
        "workspace=$workspace"
      ralph_mcp_proxy_tool_error_json "${RALPH_MCP_PROXY_FATAL_REASON:-ralph_proxy_repomap workspace denied}"
      return 0
    fi
  else
    local path_check_result
    path_check_result=0
    search_path="$(ralph_mcp_proxy_path_is_allowed "$rel_path" 0)" || path_check_result=$?

    if [[ "$path_check_result" -eq 3 ]]; then
      ralph_mcp_proxy_tool_error_json "ralph_proxy_repomap requires path"
      return 0
    fi

    if [[ "$path_check_result" -eq 4 ]]; then
      ralph_mcp_proxy_tool_error_json "ralph_proxy_repomap: path is hidden debug output"
      return 0
    fi

    if [[ "$path_check_result" -eq 1 ]]; then
      ralph_mcp_proxy_signal_fatal_violation \
        "ralph_proxy_repomap" \
        "ralph_proxy_repomap: path is outside the workspace" \
        "path=$rel_path"
      ralph_mcp_proxy_tool_error_json "${RALPH_MCP_PROXY_FATAL_REASON:-ralph_proxy_repomap path denied}"
      return 0
    fi

    if [[ "$path_check_result" -eq 2 ]]; then
      ralph_mcp_proxy_tool_error_json "ralph_proxy_repomap: path does not exist"
      return 0
    fi

    if [[ -z "$search_path" ]]; then
      ralph_mcp_proxy_tool_error_json "ralph_proxy_repomap: path is outside the workspace"
      return 0
    fi

    if [[ ! -e "$search_path" ]]; then
      ralph_mcp_proxy_tool_error_json "ralph_proxy_repomap: path does not exist"
      return 0
    fi

    if [[ ! -d "$search_path" ]]; then
      ralph_mcp_proxy_tool_error_json "ralph_proxy_repomap: path must be a directory"
      return 0
    fi
  fi

  if ! full_text="$(ralph_repo_map_emit_digest "$workspace" "$rel_path" "$return_limit")"; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_repomap: digest generation failed"
    return 0
  fi
  if [[ -n "$full_text" && "$full_text" != *$'\n' ]]; then
    full_text+=$'\n'
  fi
  preview_text="$full_text"
  byte_cap="$(ralph_mcp_proxy_result_byte_cap_for_tool "ralph_proxy_repomap")"
  if [[ "$byte_cap" =~ ^[0-9]+$ ]] && [[ "$byte_cap" -gt 0 ]] && [[ "${#preview_text}" -gt "$byte_cap" ]]; then
    truncated=1
    preview_text="${preview_text:0:byte_cap}"
  fi

  if [[ "$truncated" -eq 0 ]]; then
    ralph_mcp_proxy_tool_success_json "$preview_text"
    return 0
  fi

  ralph_mcp_proxy_owned_tool_maybe_envelope_text_result \
    "$workspace" \
    "ralph_proxy_repomap" \
    "$full_text" \
    "1" \
    "$preview_text" \
    "[]" \
    "" \
    "" \
    '{"storageLayout":"full"}'
}

ralph_mcp_proxy_owned_tool_glob_count_paths() {
  local text="${1:-}"
  if [[ -z "$text" ]]; then
    printf '0\n'
    return 0
  fi
  printf '%s\n' "$text" | awk 'NF { count++ } END { print count + 0 }'
}

ralph_mcp_proxy_owned_tool_glob() {
  local workspace="${1:-}"
  local args_json; args_json="$(ralph_mcp_proxy_normalize_args_json "${2-}")"
  local glob_pattern target_dir max_results search_root tmp_out
  local full_text preview_text result_count byte_cap truncated=0 cache_key mutation_counter

  glob_pattern="$(jq -r '.glob_pattern // empty' <<< "$args_json")"
  target_dir="$(jq -r '.target_directory // "."' <<< "$args_json")"
  max_results="${RALPH_MCP_PROXY_POLICY_OWNED_MAX_GLOB_RESULTS:-200}"

  if [[ -z "$glob_pattern" ]]; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_glob requires glob_pattern"
    return 0
  fi
  if [[ "$glob_pattern" == /* ]]; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_glob: absolute glob patterns are not allowed"
    return 0
  fi
  if [[ "$target_dir" == "." ]]; then
    if ! search_root="$(ralph_mcp_proxy_workspace_realpath "$workspace")"; then
      ralph_mcp_proxy_signal_fatal_violation \
        "ralph_proxy_glob" \
        "ralph_proxy_glob: workspace not available" \
        "workspace=$workspace"
      return 1
    fi
  else
    local path_check_result
    path_check_result=0
    search_root="$(ralph_mcp_proxy_path_is_allowed "$target_dir" 0)" || path_check_result=$?

    if [[ "$path_check_result" -eq 3 ]]; then
      ralph_mcp_proxy_tool_error_json "ralph_proxy_glob requires target_directory"
      return 0
    fi

    if [[ "$path_check_result" -eq 4 ]]; then
      ralph_mcp_proxy_tool_error_json "ralph_proxy_glob: target_directory is hidden debug output"
      return 0
    fi

    if [[ "$path_check_result" -eq 1 ]]; then
      ralph_mcp_proxy_signal_fatal_violation \
        "ralph_proxy_glob" \
        "ralph_proxy_glob: target_directory is outside the workspace" \
        "target_directory=$target_dir"
      ralph_mcp_proxy_tool_error_json "${RALPH_MCP_PROXY_FATAL_REASON:-ralph_proxy_glob target denied}"
      return 0
    fi

    if [[ "$path_check_result" -eq 2 ]]; then
      ralph_mcp_proxy_tool_error_json "ralph_proxy_glob: target_directory does not exist"
      return 0
    fi

    if [[ -z "$search_root" ]]; then
      ralph_mcp_proxy_tool_error_json "ralph_proxy_glob: target_directory is outside the workspace"
      return 0
    fi

    if [[ ! -e "$search_root" ]]; then
      ralph_mcp_proxy_tool_error_json "ralph_proxy_glob: target_directory does not exist"
      return 0
    fi
  fi
  if [[ ! -d "$search_root" ]]; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_glob: target_directory is not a directory"
    return 0
  fi

  mutation_counter="${RALPH_MCP_PROXY_MUTATION_COUNTER:-0}"
  cache_key="$(ralph_mcp_proxy_search_dedupe_cache_key "ralph_proxy_glob" "$args_json")"
  if ralph_mcp_proxy_search_dedupe_try_return "$workspace" "ralph_proxy_glob" "$cache_key" "$mutation_counter"; then
    return 0
  fi
  RALPH_MCP_PROXY_LAST_RESULT_ID=""
  RALPH_MCP_PROXY_LAST_RESULT_NEEDS_ENVELOPE=0
  export RALPH_MCP_PROXY_LAST_RESULT_ID RALPH_MCP_PROXY_LAST_RESULT_NEEDS_ENVELOPE

  tmp_out="$(mktemp)"
  ralph_mcp_proxy_owned_tool_glob_search "$glob_pattern" "$search_root" "$tmp_out"
  full_text="$(<"$tmp_out")"
  rm -f "$tmp_out"
  if [[ -n "$full_text" && "$full_text" != *$'\n' ]]; then
    full_text+=$'\n'
  fi

  result_count="$(ralph_mcp_proxy_owned_tool_glob_count_paths "$full_text")"
  preview_text="$full_text"
  if [[ "$result_count" -gt "$max_results" ]]; then
    truncated=1
    preview_text="$(ralph_mcp_proxy_owned_tool_grep_head_lines "$full_text" "$max_results")"
  fi

  byte_cap="$(ralph_mcp_proxy_result_byte_cap_for_tool "ralph_proxy_glob")"
  if [[ "$byte_cap" =~ ^[0-9]+$ ]] && [[ "$byte_cap" -gt 0 ]] && [[ "${#preview_text}" -gt "$byte_cap" ]]; then
    truncated=1
  elif [[ "$result_count" -gt "$max_results" ]]; then
    truncated=1
  fi

  if [[ "$truncated" -eq 0 ]]; then
    ralph_mcp_proxy_search_dedupe_store \
      "$cache_key" \
      "$mutation_counter" \
      "$full_text" \
      "$truncated" \
      '{"storageLayout":"full"}' \
      "${RALPH_MCP_PROXY_LAST_RESULT_ID:-}"
    ralph_mcp_proxy_tool_success_json "$preview_text"
    return 0
  fi

  ralph_mcp_proxy_owned_tool_maybe_envelope_text_result \
    "$workspace" \
    "ralph_proxy_glob" \
    "$full_text" \
    "1" \
    "$preview_text" \
    "[]" \
    "" \
    "$glob_pattern" \
    '{"storageLayout":"full"}'

  ralph_mcp_proxy_search_dedupe_store \
    "$cache_key" \
    "$mutation_counter" \
    "$full_text" \
    "$truncated" \
    '{"storageLayout":"full"}' \
    "${RALPH_MCP_PROXY_LAST_RESULT_ID:-}"
}

ralph_mcp_proxy_shell_command_allowed_or_scoped() {
  local tool_name="${1:-ralph_proxy_shell}"
  local args_json; args_json="$(ralph_mcp_proxy_normalize_args_json "${2-}")"
  local command="${3:-}"

  if ralph_mcp_proxy_shell_command_allowed "$command"; then
    return 0
  fi
  if declare -F ralph_mcp_proxy_scoped_approval_allows >/dev/null 2>&1; then
    if ralph_mcp_proxy_scoped_approval_allows "$tool_name" "denied-command" "$args_json"; then
      return 0
    fi
  fi
  return 1
}

ralph_mcp_proxy_shell_command_allowed() {
  local command="${1:-}"
  local allowlist_json="${RALPH_MCP_PROXY_POLICY_OWNED_SHELL_ALLOWLIST_JSON:-[]}"
  local allow_all="${RALPH_MCP_PROXY_POLICY_OWNED_ALLOW_ALL_COMMANDS:-0}"
  local allow_shell_ops="${RALPH_MCP_PROXY_POLICY_OWNED_ALLOW_SHELL_OPERATORS:-0}"
  local entry
  local metachar_pattern='[\|\&\;\`\$\<\>]'

  if [[ -z "$command" ]]; then
    return 1
  fi
  if [[ "$allow_shell_ops" != "1" && "$command" =~ $metachar_pattern ]]; then
    return 1
  fi
  if [[ "$allow_all" == "1" ]]; then
    return 0
  fi
  if [[ "$(jq -r 'length' <<< "$allowlist_json")" -eq 0 ]]; then
    return 1
  fi
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    if [[ "$entry" == "*" ]]; then
      return 0
    fi
    if [[ "$command" == "$entry" ]]; then
      return 0
    fi
    if [[ "$entry" == */* ]] && [[ "$command" == "$entry"* ]]; then
      return 0
    fi
    if [[ "$command" == "$entry "* ]]; then
      return 0
    fi
  done < <(jq -r '.[]?' <<< "$allowlist_json")
  return 1
}

ralph_mcp_proxy_shell_compact_enabled() {
  case "${RALPH_PROXY_SHELL_COMPACT:-}" in
    1|true|yes|on)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

ralph_mcp_proxy_shell_rewrite_enabled() {
  case "${RALPH_PROXY_SHELL_REWRITE:-}" in
    1|true|yes|on)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

ralph_mcp_proxy_shell_rewrite_append_log() {
  local workspace="${1:-}" original_command="${2:-}" rewritten_command="${3:-}" rule_id="${4:-}"
  local log_path plan_key timestamp line
  log_path="${RALPH_PROXY_SHELL_REWRITE_LOG:-}"
  [[ -n "$log_path" ]] || return 0
  plan_key="$(ralph_mcp_proxy_result_tool_plan_key)"
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  line="$(
    jq -nc \
      --arg timestamp "$timestamp" \
      --arg workspace "$workspace" \
      --arg planKey "$plan_key" \
      --arg command "$original_command" \
      --arg rewrittenCommand "$rewritten_command" \
      --arg ruleId "$rule_id" \
      '{
        timestamp: $timestamp,
        workspace: $workspace,
        planKey: $planKey,
        command: $command,
        rewrittenCommand: $rewrittenCommand,
        ruleId: (if $ruleId == "" then null else $ruleId end)
      }'
  )"
  mkdir -p "$(dirname "$log_path")" 2>/dev/null || true
  printf '%s\n' "$line" >>"$log_path" 2>/dev/null || true
}

# Apply optional shell rewrite after the original command passed allowlist checks.
# Prints the command to execute on stdout; returns 1 when rewrite broadens policy.
ralph_mcp_proxy_shell_command_after_rewrite() {
  local workspace="${1:-}" command="${2:-}"
  local rewrite_json rewritten_command rule_id

  if ! ralph_mcp_proxy_shell_rewrite_enabled; then
    printf '%s' "$command"
    return 0
  fi

  rewrite_json="$(ralph_rewrite_shell_command "$command")"
  if ! ralph_rewrite_shell_command_applied "$rewrite_json"; then
    printf '%s' "$command"
    return 0
  fi

  rewritten_command="$(jq -r '.rewritten_command // empty' <<<"$rewrite_json")"
  rule_id="$(jq -r '.rule_id // empty' <<<"$rewrite_json")"
  if [[ -z "$rewritten_command" ]]; then
    printf '%s' "$command"
    return 0
  fi

  if ! ralph_mcp_proxy_shell_command_allowed "$rewritten_command"; then
    return 1
  fi

  ralph_mcp_proxy_shell_rewrite_append_log \
    "$workspace" \
    "$command" \
    "$rewritten_command" \
    "$rule_id"

  printf '%s' "$rewritten_command"
  return 0
}

ralph_mcp_proxy_tool_shell_result_json() {
  local exit_code="${1:-0}" envelope_text="${2:-}"
  if [[ "$exit_code" -ne 0 ]]; then
    ralph_mcp_proxy_tool_error_json "$envelope_text"
  else
    ralph_mcp_proxy_tool_success_json "$envelope_text"
  fi
}

ralph_mcp_proxy_owned_tool_shell_finish_success() {
  local workspace="${1:-}"
  local text="${2:-}"
  local max_shell_bytes="${3:-}"
  local preview_text="$text"
  local truncated=0 byte_cap

  if [[ "$max_shell_bytes" =~ ^[0-9]+$ ]] && [[ "$max_shell_bytes" -gt 0 ]] && [[ "${#text}" -gt "$max_shell_bytes" ]]; then
    truncated=1
    preview_text="${text:0:max_shell_bytes}"
  fi

  byte_cap="$(ralph_mcp_proxy_result_byte_cap_for_tool "ralph_proxy_shell")"
  if [[ "$byte_cap" =~ ^[0-9]+$ ]] && [[ "$byte_cap" -gt 0 ]] && [[ "${#preview_text}" -gt "$byte_cap" ]]; then
    truncated=1
  fi

  if [[ "$truncated" -eq 0 ]]; then
    ralph_mcp_proxy_tool_success_json "$text"
    return 0
  fi

  ralph_mcp_proxy_owned_tool_maybe_envelope_text_result \
    "$workspace" \
    "ralph_proxy_shell" \
    "$text" \
    "1" \
    "$preview_text" \
    "" \
    "" \
    "" \
    '{"storageLayout":"full"}'
}

ralph_mcp_proxy_owned_tool_shell_compact() {
  local workspace="${1:-}" command="${2:-}" stdout="${3-}" stderr="${4-}" exit_code="${5:-0}"
  local max_shell_bytes="${6:-}" outcome_json preview_text store_needed result_id result_path envelope_json

  outcome_json="$(ralph_native_shell_compact_pipeline_json \
    "$workspace" \
    "$command" \
    "$stdout" \
    "$stderr" \
    "$exit_code" \
    "$max_shell_bytes" \
    "ralph_proxy_shell")"

  preview_text="$(jq -r '.preview // ""' <<<"$outcome_json")"
  store_needed="$(jq -r '.storeNeeded // false' <<<"$outcome_json")"
  result_id="$(jq -r '.resultId // ""' <<<"$outcome_json")"
  result_path="$(jq -r '.resultPath // ""' <<<"$outcome_json")"

  if [[ "$store_needed" == "false" || "$store_needed" == "0" ]]; then
    if [[ "$exit_code" -ne 0 ]]; then
      ralph_mcp_proxy_tool_error_json "ralph_proxy_shell exited $exit_code: $preview_text"
      return 0
    fi
    ralph_mcp_proxy_owned_tool_shell_finish_success "$workspace" "$preview_text" "$max_shell_bytes"
    return 0
  fi

  if [[ -z "$result_id" ]]; then
    if [[ "$exit_code" -ne 0 ]]; then
      ralph_mcp_proxy_tool_error_json "ralph_proxy_shell exited $exit_code: $preview_text"
      return 0
    fi
    ralph_mcp_proxy_owned_tool_shell_finish_success "$workspace" "$preview_text" "$max_shell_bytes"
    return 0
  fi

  envelope_json="$(ralph_mcp_proxy_shell_compact_envelope_build_json \
    "$command" \
    "$exit_code" \
    "$preview_text" \
    "$(jq -r '.originalBytes // 0' <<<"$outcome_json")" \
    "$(jq -r '.returnedBytes // 0' <<<"$outcome_json")" \
    "$result_id" \
    "$result_path" \
    "$(jq -r '.stdoutCompacted // false' <<<"$outcome_json")" \
    "$(jq -r '.stderrCompacted // false' <<<"$outcome_json")" \
    "$(jq -r '.compactedApplied // false' <<<"$outcome_json")" \
    "$(jq -r '.originalTokens // empty' <<<"$outcome_json")" \
    "$(jq -r '.returnedTokens // empty' <<<"$outcome_json")")"
  ralph_mcp_proxy_tool_shell_result_json "$exit_code" "$(jq -c . <<< "$envelope_json")"
}

ralph_mcp_proxy_result_tool_workspace() {
  local workspace="${RALPH_MCP_WORKSPACE:-${1:-}}"
  [[ -n "$workspace" ]] || return 1
  ralph_mcp_proxy_workspace_realpath "$workspace"
}

ralph_mcp_proxy_result_tool_plan_key() {
  if [[ -n "${RALPH_PLAN_KEY:-}" ]]; then
    printf '%s\n' "$RALPH_PLAN_KEY"
  elif [[ -n "${RALPH_ARTIFACT_NS:-}" ]]; then
    printf '%s\n' "$RALPH_ARTIFACT_NS"
  else
    printf 'default\n'
  fi
}

# Stable, non-sensitive reason code when ralph_mcp_proxy_result_tool_plan_key
# fell back to "default" (neither RALPH_PLAN_KEY nor RALPH_ARTIFACT_NS set),
# or empty when a key was explicitly provided. Computed fresh at each call
# site rather than cached, so it never leaks stale state into a later event.
ralph_mcp_proxy_result_tool_plan_key_fallback_reason() {
  if [[ -n "${RALPH_PLAN_KEY:-}" ]]; then
    return 0
  fi
  if [[ -n "${RALPH_ARTIFACT_NS:-}" ]]; then
    return 0
  fi
  printf 'no_plan_key_or_artifact_ns_env\n'
}

ralph_mcp_proxy_result_tool_index_entry_json() {
  local workspace="${1:-}"
  local plan_key="${2:-}"
  local result_id="${3:-}"
  local index_path
  index_path="$(ralph_mcp_proxy_result_store_index_path "$workspace" "$plan_key")" || return 1
  [[ -f "$index_path" ]] || return 1
  jq -c --arg id "$result_id" 'select(.id == $id) | .' "$index_path" 2>/dev/null | head -n 1
}

ralph_mcp_proxy_result_tool_line_count() {
  local file_path="${1:-}"
  [[ -f "$file_path" ]] || return 1
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$file_path" <<'PYTHON'
import sys

path = sys.argv[1]
count = 0
with open(path, "rb") as fh:
    for _ in fh:
        count += 1
if count == 0:
    with open(path, "rb") as fh:
        if fh.read(1):
            count = 1
print(count)
PYTHON
    return $?
  fi
  wc -l <"$file_path" | tr -d ' '
}

ralph_mcp_proxy_owned_tool_result_read() {
  local workspace="${1:-}"
  local args_json="${2:-}"
  local result_id view byte_start byte_end line_start line_limit plan_key text byte_limit auto_ranged=0 read_window byte_cap

  result_id="$(jq -r '.resultId // empty' <<< "$args_json")"
  view="$(jq -r '.view // "compacted"' <<< "$args_json")"
  byte_start="$(jq -r '.byteStart // 0' <<< "$args_json")"
  byte_end="$(jq -r '.byteEnd // empty' <<< "$args_json")"
  line_start="$(jq -r '.lineStart // empty' <<< "$args_json")"
  line_limit="$(jq -r '.lineLimit // empty' <<< "$args_json")"

  if [[ -z "$result_id" ]]; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_result_read requires resultId"
    return 0
  fi
  case "$view" in
    compacted|raw) ;;
    *)
      ralph_mcp_proxy_tool_error_json "ralph_proxy_result_read: view must be compacted or raw"
      return 0
      ;;
  esac
  if ! ralph_mcp_proxy_result_store_validate_result_id "$result_id"; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_result_read: invalid resultId"
    return 0
  fi
  plan_key="$(ralph_mcp_proxy_result_tool_plan_key)"
  if ! ralph_mcp_proxy_result_store_validate_plan_key "$plan_key"; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_result_read: invalid plan key for stored results"
    return 0
  fi
  if ! ralph_mcp_proxy_result_store_resolve_result_path "$workspace" "$plan_key" "$result_id" "$view" >/dev/null; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_result_read: result not found or path escape blocked"
    return 0
  fi

  byte_cap="$(ralph_mcp_proxy_result_byte_cap_for_tool "ralph_proxy_result_read")"
  read_window=4096
  if [[ "$byte_cap" =~ ^[0-9]+$ ]] && [[ "$byte_cap" -gt 0 ]]; then
    read_window="$byte_cap"
  fi

  # Resolve a source label (the tool that produced this result) so a
  # misremembered/stale resultId reveals itself in the readback envelope. This
  # prevents the model from re-reading e.g. a grep result expecting file content.
  local source_label=""
  local _result_read_entry_json
  _result_read_entry_json="$(ralph_mcp_proxy_result_tool_index_entry_json "$workspace" "$plan_key" "$result_id" 2>/dev/null || true)"
  if [[ -n "$_result_read_entry_json" ]]; then
    source_label="$(jq -r '.tool // empty' <<< "$_result_read_entry_json" 2>/dev/null || true)"
    [[ "$source_label" == "null" ]] && source_label=""
  fi

  if [[ -n "$line_start" && "$line_start" != "null" ]]; then
    if [[ ! "$line_start" =~ ^[0-9]+$ ]] || [[ "$line_start" -lt 1 ]]; then
      ralph_mcp_proxy_tool_error_json "ralph_proxy_result_read: lineStart must be a positive integer"
      return 0
    fi
    if [[ -z "$line_limit" || "$line_limit" == "null" || ! "$line_limit" =~ ^[0-9]+$ ]]; then
      if [[ "$view" == "raw" ]]; then
        line_limit=120
        auto_ranged=1
      else
        line_limit=0
      fi
    fi
    if ! text="$(ralph_mcp_proxy_result_store_read_lines "$workspace" "$plan_key" "$result_id" "$line_start" "$line_limit" "$view" 2>/dev/null)"; then
      ralph_mcp_proxy_tool_error_json "ralph_proxy_result_read: failed to read line range"
      return 0
    fi
    ralph_mcp_proxy_result_read_emit_response "$workspace" "$result_id" "$view" "$text" "$byte_start" "$byte_limit" "$auto_ranged" "$source_label"
    return 0
  fi

  if [[ ! "$byte_start" =~ ^[0-9]+$ ]]; then
    byte_start=0
  fi
  byte_limit=0
  if [[ -n "$byte_end" && "$byte_end" != "null" ]]; then
    if [[ ! "$byte_end" =~ ^[0-9]+$ ]]; then
      ralph_mcp_proxy_tool_error_json "ralph_proxy_result_read: byteEnd must be a non-negative integer"
      return 0
    fi
    if [[ "$byte_end" -le "$byte_start" ]]; then
      ralph_mcp_proxy_tool_error_json "ralph_proxy_result_read: byteEnd must be greater than byteStart"
      return 0
    fi
    byte_limit=$((byte_end - byte_start))
  elif [[ "$view" == "raw" ]]; then
    byte_limit="$read_window"
    auto_ranged=1
  fi
  if ! text="$(ralph_mcp_proxy_result_store_read_bytes "$workspace" "$plan_key" "$result_id" "$byte_start" "$byte_limit" "$view" 2>/dev/null)"; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_result_read: failed to read byte range"
    return 0
  fi
  ralph_mcp_proxy_result_read_emit_response "$workspace" "$result_id" "$view" "$text" "$byte_start" "$byte_limit" "$auto_ranged" "$source_label"
}

ralph_mcp_proxy_owned_tool_result_search() {
  local workspace="${1:-}"
  local args_json="${2:-}"
  local pattern result_id head_limit max_matches plan_key grep_output

  pattern="$(jq -r '.pattern // empty' <<< "$args_json")"
  result_id="$(jq -r '.resultId // empty' <<< "$args_json")"
  head_limit="$(jq -r '.head_limit // empty' <<< "$args_json")"
  max_matches="${RALPH_MCP_PROXY_POLICY_OWNED_MAX_GREP_MATCHES:-100}"

  if [[ -z "$pattern" ]]; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_result_search requires pattern"
    return 0
  fi
  if [[ "$pattern" == *$'\n'* ]]; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_result_search: multiline patterns are not supported"
    return 0
  fi
  plan_key="$(ralph_mcp_proxy_result_tool_plan_key)"
  if ! ralph_mcp_proxy_result_store_validate_plan_key "$plan_key"; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_result_search: invalid plan key for stored results"
    return 0
  fi
  if [[ -n "$result_id" ]]; then
    if ! ralph_mcp_proxy_result_store_validate_result_id "$result_id"; then
      ralph_mcp_proxy_tool_error_json "ralph_proxy_result_search: invalid resultId"
      return 0
    fi
    if ! ralph_mcp_proxy_result_store_resolve_result_path "$workspace" "$plan_key" "$result_id" >/dev/null; then
      ralph_mcp_proxy_tool_error_json "ralph_proxy_result_search: result not found or path escape blocked"
      return 0
    fi
  fi
  if [[ -z "$head_limit" || ! "$head_limit" =~ ^[0-9]+$ ]]; then
    head_limit="$max_matches"
  elif [[ "$head_limit" -gt "$max_matches" ]]; then
    head_limit="$max_matches"
  fi

  if ! grep_output="$(ralph_mcp_proxy_result_store_search "$workspace" "$plan_key" "$pattern" "$result_id" 2>/dev/null)"; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_result_search: search failed"
    return 0
  fi
  if [[ -n "$grep_output" ]]; then
    grep_output="$(printf '%s\n' "$grep_output" | head -n "$head_limit")"
  fi
  if [[ -n "$result_id" ]]; then
    ralph_mcp_proxy_append_readback_telemetry "$workspace" "ralph_proxy_result_search" "$result_id" "compacted" "$grep_output" "search_followup"
  fi
  ralph_mcp_proxy_tool_success_json "$grep_output"
}

ralph_mcp_proxy_owned_tool_result_summary() {
  local workspace="${1:-}"
  local args_json="${2:-}"
  local result_id plan_key entry_json result_path bytes line_count tool_name stored_at
  local breakpoints_json next_actions_json summary_json byte_cap

  result_id="$(jq -r '.resultId // empty' <<< "$args_json")"
  if [[ -z "$result_id" ]]; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_result_summary requires resultId"
    return 0
  fi
  if ! ralph_mcp_proxy_result_store_validate_result_id "$result_id"; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_result_summary: invalid resultId"
    return 0
  fi
  plan_key="$(ralph_mcp_proxy_result_tool_plan_key)"
  if ! ralph_mcp_proxy_result_store_validate_plan_key "$plan_key"; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_result_summary: invalid plan key for stored results"
    return 0
  fi
  if ! result_path="$(ralph_mcp_proxy_result_store_resolve_result_path "$workspace" "$plan_key" "$result_id")"; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_result_summary: result not found or path escape blocked"
    return 0
  fi
  if [[ ! -f "$result_path" ]]; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_result_summary: stored result file missing"
    return 0
  fi

  entry_json="$(ralph_mcp_proxy_result_tool_index_entry_json "$workspace" "$plan_key" "$result_id")"
  bytes="$(wc -c <"$result_path" | tr -d ' ')"
  line_count="$(ralph_mcp_proxy_result_tool_line_count "$result_path")"
  tool_name="$(jq -r '.tool // empty' <<< "${entry_json:-{}}")"
  stored_at="$(jq -r '.storedAt // empty' <<< "${entry_json:-{}}")"
  if [[ -z "$tool_name" || "$tool_name" == "null" ]]; then
    tool_name=""
  fi
  if [[ -z "$stored_at" || "$stored_at" == "null" ]]; then
    stored_at=""
  fi
  local entry_metadata file_metadata metadata_json
  entry_metadata="$(jq -r '.metadata // empty' <<< "${entry_json:-{}}")"
  if [[ "$entry_metadata" == "null" ]]; then
    entry_metadata=""
  fi
  file_metadata="$(ralph_mcp_proxy_result_store_read_metadata "$workspace" "$plan_key" "$result_id" 2>/dev/null || true)"
  if [[ -n "$entry_metadata" ]]; then
    metadata_json="$entry_metadata"
  else
    metadata_json="$file_metadata"
  fi

  byte_cap="$(ralph_mcp_proxy_result_byte_cap_for_tool "ralph_proxy_result_read")"
  breakpoints_json="$(ralph_mcp_proxy_result_store_generate_breakpoints_json "$workspace" "$plan_key" "$result_id" "$bytes" 0 "$byte_cap" "[]" 2>/dev/null || true)"
  if [[ -z "$breakpoints_json" ]]; then
    breakpoints_json="$(ralph_mcp_proxy_result_envelope_default_breakpoints_json "$bytes" 0)"
  fi
  next_actions_json="$(ralph_mcp_proxy_result_envelope_default_next_actions_json "$result_id")"

  summary_json="$(
    jq -nc \
      --arg resultId "$result_id" \
      --argjson bytes "$bytes" \
      --argjson lineCount "$line_count" \
      --arg tool "$tool_name" \
      --arg storedAt "$stored_at" \
      --arg metadata "$metadata_json" \
      --argjson breakpoints "$breakpoints_json" \
      --argjson nextActions "$next_actions_json" \
      '{
        resultId: $resultId,
        bytes: $bytes,
        lineCount: $lineCount,
        tool: (if $tool == "" then null else $tool end),
        storedAt: (if $storedAt == "" then null else $storedAt end),
        metadata: (if $metadata == "" then null else ($metadata | fromjson) end),
        breakpoints: $breakpoints,
        nextActions: $nextActions
      }'
  )"
  ralph_mcp_proxy_tool_success_json "$(jq -c . <<< "$summary_json")"
}

ralph_mcp_proxy_owned_tool_result_reduce() {
  local workspace="${1:-}"
  local args_json="${2:-}"
  local result_id view reducer expression plan_key input_path reduce_request reduce_json
  local output truncated_flag byte_cap read_window next_actions_json metadata_json
  local ignore_case invert_match line_number word_match fixed_strings max_count
  local max_output_bytes max_output_lines timeout_seconds grep_json

  if ! ralph_mcp_proxy_result_reduce_active; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_result_reduce is not enabled"
    return 0
  fi

  result_id="$(jq -r '.resultId // empty' <<< "$args_json")"
  view="$(jq -r '.view // "compacted"' <<< "$args_json")"
  reducer="$(jq -r '.reducer // empty' <<< "$args_json" | tr '[:upper:]' '[:lower:]')"
  expression="$(jq -r '.expression // empty' <<< "$args_json")"

  if [[ -z "$result_id" ]]; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_result_reduce requires resultId"
    return 0
  fi
  if [[ -z "$reducer" ]]; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_result_reduce requires reducer"
    return 0
  fi
  case "$view" in
    compacted|raw) ;;
    *)
      ralph_mcp_proxy_tool_error_json "ralph_proxy_result_reduce: view must be compacted or raw"
      return 0
      ;;
  esac
  case "$reducer" in
    jq|grep|awk) ;;
    *)
      ralph_mcp_proxy_tool_error_json "ralph_proxy_result_reduce: reducer must be jq, grep, or awk"
      return 0
      ;;
  esac
  if ! ralph_mcp_proxy_result_store_validate_result_id "$result_id"; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_result_reduce: invalid resultId"
    return 0
  fi
  plan_key="$(ralph_mcp_proxy_result_tool_plan_key)"
  if ! ralph_mcp_proxy_result_store_validate_plan_key "$plan_key"; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_result_reduce: invalid plan key for stored results"
    return 0
  fi
  if ! input_path="$(ralph_mcp_proxy_result_store_resolve_result_path "$workspace" "$plan_key" "$result_id" "$view")"; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_result_reduce: result not found or path escape blocked"
    return 0
  fi
  if [[ ! -f "$input_path" && "$view" == "compacted" ]]; then
    input_path="$(ralph_mcp_proxy_result_store_resolve_result_path "$workspace" "$plan_key" "$result_id" "raw" 2>/dev/null || true)"
  fi
  if [[ ! -f "$input_path" ]]; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_result_reduce: stored result file missing"
    return 0
  fi

  byte_cap="$(ralph_mcp_proxy_result_byte_cap_for_tool "ralph_proxy_result_reduce")"
  read_window=4096
  if [[ "$byte_cap" =~ ^[0-9]+$ ]] && [[ "$byte_cap" -gt 0 ]]; then
    read_window="$byte_cap"
  fi
  max_output_bytes="$(jq -r '.maxOutputBytes // empty' <<< "$args_json")"
  max_output_lines="$(jq -r '.maxOutputLines // empty' <<< "$args_json")"
  timeout_seconds="$(jq -r '.timeoutSeconds // empty' <<< "$args_json")"
  if [[ -z "$max_output_bytes" || ! "$max_output_bytes" =~ ^[0-9]+$ ]]; then
    max_output_bytes="$byte_cap"
  fi
  if [[ -z "$max_output_lines" || ! "$max_output_lines" =~ ^[0-9]+$ ]]; then
    max_output_lines=500
  fi
  if [[ -z "$timeout_seconds" || ! "$timeout_seconds" =~ ^[0-9]+$ ]]; then
    timeout_seconds=5
  fi

  ignore_case="$(jq -r '.ignoreCase // false' <<< "$args_json")"
  invert_match="$(jq -r '.invertMatch // false' <<< "$args_json")"
  line_number="$(jq -r '.lineNumber // false' <<< "$args_json")"
  word_match="$(jq -r '.wordMatch // false' <<< "$args_json")"
  fixed_strings="$(jq -r '.fixedStrings // false' <<< "$args_json")"
  max_count="$(jq -r '.maxCount // empty' <<< "$args_json")"
  grep_json="$(
    jq -nc \
      --argjson ignoreCase "$([[ "$ignore_case" == "true" ]] && echo true || echo false)" \
      --argjson invertMatch "$([[ "$invert_match" == "true" ]] && echo true || echo false)" \
      --argjson lineNumber "$([[ "$line_number" == "true" ]] && echo true || echo false)" \
      --argjson wordMatch "$([[ "$word_match" == "true" ]] && echo true || echo false)" \
      --argjson fixedStrings "$([[ "$fixed_strings" == "true" ]] && echo true || echo false)" \
      --argjson maxCount "${max_count:-null}" \
      '{
        ignoreCase: $ignoreCase,
        invertMatch: $invertMatch,
        lineNumber: $lineNumber,
        wordMatch: $wordMatch,
        fixedStrings: $fixedStrings,
        maxCount: (if ($maxCount | type) == "number" then $maxCount else null end)
      }'
  )"

  reduce_request="$(
    jq -nc \
      --arg inputPath "$input_path" \
      --arg reducer "$reducer" \
      --arg expression "$expression" \
      --argjson grep "$grep_json" \
      --argjson limits "$(jq -nc \
        --argjson maxOutputBytes "$max_output_bytes" \
        --argjson maxOutputLines "$max_output_lines" \
        --argjson timeoutSeconds "$timeout_seconds" \
        '{maxOutputBytes: $maxOutputBytes, maxOutputLines: $maxOutputLines, timeoutSeconds: $timeoutSeconds}')" \
      '{inputPath: $inputPath, reducer: $reducer, expression: $expression, grep: $grep, limits: $limits}'
  )"

  if ! reduce_json="$(ralph_mcp_proxy_result_reduce_invoke_python "$reduce_request")"; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_result_reduce: ${RALPH_MCP_PROXY_RESULT_REDUCE_ERROR:-reduction failed}"
    return 0
  fi

  output="$(jq -r '.output // ""' <<<"$reduce_json")"
  truncated_flag="$(jq -r '.truncated // false' <<<"$reduce_json")"
  metadata_json="$(
    jq -nc \
      --arg sourceResultId "$result_id" \
      --arg reducer "$reducer" \
      --arg expression "$expression" \
      --arg view "$view" \
      '{sourceResultId: $sourceResultId, reducer: $reducer, expression: $expression, sourceView: $view}'
  )"

  ralph_mcp_proxy_append_readback_telemetry "$workspace" "ralph_proxy_result_reduce" "$result_id" "$view" "$output" "reduce_followup"

  local needs_envelope=0
  if [[ "$truncated_flag" == "true" ]]; then
    needs_envelope=1
  fi
  byte_cap="$(ralph_mcp_proxy_result_byte_cap_for_tool "ralph_proxy_result_reduce")"
  if [[ "$byte_cap" =~ ^[0-9]+$ ]] && [[ "$byte_cap" -gt 0 ]] && [[ "${#output}" -gt "$byte_cap" ]]; then
    needs_envelope=1
  fi

  if [[ "$needs_envelope" -eq 0 ]]; then
    ralph_mcp_proxy_tool_success_json "$output"
    return 0
  fi

  ralph_mcp_proxy_owned_tool_maybe_envelope_text_result \
    "$workspace" \
    "ralph_proxy_result_reduce" \
    "$output" \
    "1" \
    "$output" \
    "[]" \
    "" \
    "" \
    "$metadata_json"
}

ralph_mcp_proxy_shell_job_plan_key() {
  ralph_mcp_proxy_result_tool_plan_key
}

ralph_mcp_proxy_shell_job_root() {
  local workspace="${1:-}"
  local plan_key="${2:-}"
  [[ -n "$workspace" && -n "$plan_key" ]] || return 1
  if ! ralph_mcp_proxy_result_store_validate_plan_key "$plan_key"; then
    return 1
  fi
  printf '%s/.ralph-workspace/tool-results/%s/shell-jobs\n' "$workspace" "$plan_key"
}

ralph_mcp_proxy_shell_job_id_new() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 8 2>/dev/null && return 0
  fi
  printf '%s-%s-%s' "$$" "$(date +%s)" "$RANDOM" | shasum 2>/dev/null | awk '{print substr($1,1,16)}'
}

ralph_mcp_proxy_shell_job_id_valid() {
  [[ "${1:-}" =~ ^[a-fA-F0-9][a-fA-F0-9._-]{0,63}$ ]]
}

ralph_mcp_proxy_shell_job_dir() {
  local workspace="${1:-}" plan_key="${2:-}" job_id="${3:-}" root
  ralph_mcp_proxy_shell_job_id_valid "$job_id" || return 1
  root="$(ralph_mcp_proxy_shell_job_root "$workspace" "$plan_key")" || return 1
  printf '%s/%s\n' "$root" "$job_id"
}

ralph_mcp_proxy_shell_job_write_state() {
  local state_file="${1:-}" tmp_file
  tmp_file="${state_file}.$$"
  cat >"$tmp_file"
  mv "$tmp_file" "$state_file"
}

ralph_mcp_proxy_shell_job_tail_file() {
  local file_path="${1:-}" tail_bytes="${2:-4096}"
  [[ -f "$file_path" ]] || return 0
  if [[ ! "$tail_bytes" =~ ^[0-9]+$ || "$tail_bytes" -le 0 ]]; then
    tail_bytes=4096
  fi
  tail -c "$tail_bytes" "$file_path" 2>/dev/null || true
}

ralph_mcp_proxy_shell_job_read_file_range() {
  local file_path="${1:-}" byte_start="${2:-}" byte_end="${3:-}" tail_bytes="${4:-}"
  [[ -f "$file_path" ]] || return 0
  if [[ -n "$tail_bytes" && "$tail_bytes" != "null" ]]; then
    ralph_mcp_proxy_shell_job_tail_file "$file_path" "$tail_bytes"
    return 0
  fi
  if [[ -z "$byte_start" || "$byte_start" == "null" || ! "$byte_start" =~ ^[0-9]+$ ]]; then
    byte_start=0
  fi
  if [[ -z "$byte_end" || "$byte_end" == "null" ]]; then
    tail -c +"$((byte_start + 1))" "$file_path" 2>/dev/null || true
    return 0
  fi
  if [[ ! "$byte_end" =~ ^[0-9]+$ || "$byte_end" -le "$byte_start" ]]; then
    return 1
  fi
  dd if="$file_path" bs=1 skip="$byte_start" count="$((byte_end - byte_start))" 2>/dev/null || true
}

ralph_mcp_proxy_shell_job_state_json() {
  local job_dir="${1:-}"
  [[ -f "$job_dir/state.json" ]] || return 1
  cat "$job_dir/state.json"
}

ralph_mcp_proxy_shell_command_scope_key() {
  local todo_id="${RALPH_CURRENT_TODO_ID:-}"
  local todo_line="${RALPH_CURRENT_TODO_LINE:-}"
  local todo_ordinal="${RALPH_CURRENT_TODO_ORDINAL:-}"
  local todo_hash="${RALPH_CURRENT_TODO_HASH:-}"
  if [[ -n "$todo_id" ]]; then
    printf 'todo-id-%s\n' "$todo_id"
  elif [[ -n "$todo_line" ]]; then
    printf 'todo-line-%s\n' "$todo_line"
  elif [[ -n "$todo_ordinal" ]]; then
    printf 'todo-ordinal-%s\n' "$todo_ordinal"
  elif [[ -n "$todo_hash" ]]; then
    printf 'todo-hash-%s\n' "$(printf '%s' "$todo_hash" | tr -c 'A-Za-z0-9._-' '_')"
  else
    printf 'plan\n'
  fi
}

ralph_mcp_proxy_shell_command_state_root() {
  local workspace="${1:-}" plan_key="${2:-}"
  printf '%s/.ralph-workspace/tool-results/%s/shell-command-state/%s\n' "$workspace" "$plan_key" "$(ralph_mcp_proxy_shell_command_scope_key)"
}

ralph_mcp_proxy_shell_command_state_dir() {
  local workspace="${1:-}" plan_key="${2:-}" command_hash="${3:-}"
  [[ "$command_hash" =~ ^[a-f0-9]{64}$ ]] || return 1
  printf '%s/%s\n' "$(ralph_mcp_proxy_shell_command_state_root "$workspace" "$plan_key")" "$command_hash"
}

ralph_mcp_proxy_shell_command_state_file() {
  local workspace="${1:-}" plan_key="${2:-}" command_hash="${3:-}" dir
  dir="$(ralph_mcp_proxy_shell_command_state_dir "$workspace" "$plan_key" "$command_hash")" || return 1
  printf '%s/state.json\n' "$dir"
}

ralph_mcp_proxy_shell_command_state_read() {
  local workspace="${1:-}" plan_key="${2:-}" command_hash="${3:-}" file
  file="$(ralph_mcp_proxy_shell_command_state_file "$workspace" "$plan_key" "$command_hash")" || return 1
  [[ -f "$file" ]] || return 1
  cat "$file"
}

ralph_mcp_proxy_shell_command_state_write() {
  local file="${1:-}" tmp
  tmp="${file}.$$"
  mkdir -p "$(dirname "$file")"
  cat >"$tmp"
  mv "$tmp" "$file"
}

ralph_mcp_proxy_shell_command_state_init_json() {
  local command="${1:-}" normalized_command="${2:-}" command_hash="${3:-}"
  jq -nc \
    --arg command "$command" \
    --arg normalizedCommand "$normalized_command" \
    --arg normalizedCommandHash "$command_hash" \
    --arg scopeKey "$(ralph_mcp_proxy_shell_command_scope_key)" \
    '{command:$command,normalizedCommand:$normalizedCommand,normalizedCommandHash:$normalizedCommandHash,scopeKey:$scopeKey,requestCount:0,syncTimeoutCount:0,asyncReuseCount:0,activeJobId:null,lastJobId:null,lastStatus:null,lastRequestAt:null,lastSyncTimeoutAt:null,retryBreakerTripped:false}'
}

ralph_mcp_proxy_shell_command_state_update() {
  local workspace="${1:-}" plan_key="${2:-}" command_hash="${3:-}" jq_filter="${4:-.}" state_json file
  file="$(ralph_mcp_proxy_shell_command_state_file "$workspace" "$plan_key" "$command_hash")" || return 1
  if ! state_json="$(ralph_mcp_proxy_shell_command_state_read "$workspace" "$plan_key" "$command_hash" 2>/dev/null)"; then
    state_json="$(ralph_mcp_proxy_shell_command_state_init_json "" "" "$command_hash")"
  fi
  jq -c "$jq_filter" <<<"$state_json" | ralph_mcp_proxy_shell_command_state_write "$file"
}

ralph_mcp_proxy_shell_job_kill_managed() {
  local pid="${1:-}" pgid="${2:-}" isolated="${3:-false}"
  local escalated=0
  if [[ "$isolated" == "true" || "$isolated" == "1" ]]; then
    if [[ "$pgid" =~ ^[0-9]+$ ]]; then
      kill -TERM -"$pgid" 2>/dev/null || true
      local waited=0
      while (( waited < 10 )) && kill -0 -"$pgid" 2>/dev/null; do
        sleep 0.1
        ((waited++)) || true
      done
      if kill -0 -"$pgid" 2>/dev/null; then
        escalated=1
        kill -KILL -"$pgid" 2>/dev/null || true
      fi
    fi
  elif [[ "$pid" =~ ^[0-9]+$ ]]; then
    ralph_kill_tree "$pid"
    escalated=1
  fi
  printf '%s\n' "$escalated"
}

ralph_mcp_proxy_shell_job_finish() {
  local workspace="${1:-}" job_dir="${2:-}" command="${3:-}" timeout_sec="${4:-}" max_shell_bytes="${5:-}" start_epoch="${6:-}" exit_code="${7:-0}"
  local normalized_command="${8:-}" command_hash="${9:-}" termination_reason="${10:-}"
  local status ended_at ended_epoch stdout stderr combined result_id result_path preview outcome_json metadata_json
  local pid pgid sid supervisor_pid isolated launch_mode kill_escalated

  ended_epoch="$(date +%s)"
  ended_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  stdout="$(cat "$job_dir/stdout.log" 2>/dev/null || true)"
  stderr="$(cat "$job_dir/stderr.log" 2>/dev/null || true)"
  combined="$(ralph_mcp_proxy_shell_combine_streams "$stdout" "$stderr")"
  printf '%s' "$combined" >"$job_dir/combined.log"

  status="failed"
  [[ "$exit_code" -eq 0 ]] && status="passed"
  if [[ "$exit_code" -eq 124 || "$exit_code" -eq 137 ]]; then
    status="timed_out"
  fi
  if [[ "$termination_reason" == "cancelled" ]]; then
    status="cancelled"
  fi

  pid="$(cat "$job_dir/pid" 2>/dev/null || echo 0)"
  pgid="$(cat "$job_dir/pgid" 2>/dev/null || echo 0)"
  sid="$(cat "$job_dir/sid" 2>/dev/null || echo 0)"
  supervisor_pid="$(cat "$job_dir/supervisor.pid" 2>/dev/null || echo 0)"
  isolated="$(cat "$job_dir/isolated-process-group" 2>/dev/null || echo false)"
  launch_mode="$(cat "$job_dir/launch-mode" 2>/dev/null || echo plain)"
  kill_escalated="$(cat "$job_dir/kill-escalated" 2>/dev/null || echo 0)"

  result_id=""
  result_path=""
  preview="$(ralph_mcp_proxy_shell_job_tail_file "$job_dir/combined.log" "$max_shell_bytes")"
  if ralph_mcp_proxy_shell_compact_enabled; then
    outcome_json="$(ralph_native_shell_compact_pipeline_json "$workspace" "$command" "$stdout" "$stderr" "$exit_code" "$max_shell_bytes" "ralph_proxy_shell")"
    result_id="$(jq -r '.resultId // ""' <<<"$outcome_json")"
    result_path="$(jq -r '.resultPath // ""' <<<"$outcome_json")"
    preview="$(jq -r '.preview // ""' <<<"$outcome_json")"
  fi
  if [[ -z "$result_id" ]]; then
    metadata_json="$(jq -nc --arg command "$command" --arg status "$status" --argjson exitCode "$exit_code" '{command:$command,status:$status,exitCode:$exitCode,storageLayout:"full"}')"
    result_id="$(ralph_mcp_proxy_result_store_write "$workspace" "$(ralph_mcp_proxy_shell_job_plan_key)" "$combined" "ralph_proxy_shell" "$metadata_json" 2>/dev/null || true)"
    if [[ -n "$result_id" ]]; then
      result_path="$(ralph_mcp_proxy_result_store_resolve_result_path "$workspace" "$(ralph_mcp_proxy_shell_job_plan_key)" "$result_id" 2>/dev/null || true)"
    fi
  fi

  jq -nc \
    --arg jobId "$(basename "$job_dir")" \
    --arg status "$status" \
    --arg command "$command" \
    --arg normalizedCommand "$normalized_command" \
    --arg normalizedCommandHash "$command_hash" \
    --arg startedAt "$(cat "$job_dir/started-at.txt" 2>/dev/null || true)" \
    --arg endedAt "$ended_at" \
    --arg resultId "$result_id" \
    --arg resultPath "$result_path" \
    --arg preview "$preview" \
    --arg launchMode "$launch_mode" \
    --arg terminationReason "${termination_reason:-}" \
    --argjson pid "${pid:-0}" \
    --argjson pgid "${pgid:-0}" \
    --argjson sid "${sid:-0}" \
    --argjson supervisorPid "${supervisor_pid:-0}" \
    --argjson isolatedProcessGroup "$([[ "$isolated" == "true" || "$isolated" == "1" ]] && printf true || printf false)" \
    --argjson killEscalated "$([[ "$kill_escalated" == "1" ]] && printf true || printf false)" \
    --argjson exitCode "$exit_code" \
    --argjson timeoutSeconds "$timeout_sec" \
    --argjson startEpoch "$start_epoch" \
    --argjson elapsedSeconds "$((ended_epoch - start_epoch))" \
    --argjson stdoutBytes "$(wc -c <"$job_dir/stdout.log" 2>/dev/null | tr -d ' ' || echo 0)" \
    --argjson stderrBytes "$(wc -c <"$job_dir/stderr.log" 2>/dev/null | tr -d ' ' || echo 0)" \
    --argjson combinedBytes "$(wc -c <"$job_dir/combined.log" 2>/dev/null | tr -d ' ' || echo 0)" \
    '{jobId:$jobId,status:$status,command:$command,normalizedCommand:(if $normalizedCommand == "" then null else $normalizedCommand end),normalizedCommandHash:(if $normalizedCommandHash == "" then null else $normalizedCommandHash end),pid:$pid,pgid:$pgid,sid:$sid,supervisorPid:$supervisorPid,isolatedProcessGroup:$isolatedProcessGroup,launchMode:$launchMode,killEscalated:$killEscalated,terminationReason:(if $terminationReason == "" then null else $terminationReason end),exitCode:$exitCode,timeoutSeconds:$timeoutSeconds,startedAt:$startedAt,startEpoch:$startEpoch,endedAt:$endedAt,elapsedSeconds:$elapsedSeconds,stdoutBytes:$stdoutBytes,stderrBytes:$stderrBytes,combinedBytes:$combinedBytes,resultId:(if $resultId == "" then null else $resultId end),resultPath:(if $resultPath == "" then null else $resultPath end),preview:$preview}' \
    | ralph_mcp_proxy_shell_job_write_state "$job_dir/state.json"

  if [[ -n "$command_hash" ]]; then
    local plan_key state_file state_json
    plan_key="$(ralph_mcp_proxy_shell_job_plan_key)"
    state_file="$(ralph_mcp_proxy_shell_command_state_file "$workspace" "$plan_key" "$command_hash" 2>/dev/null || true)"
    if [[ -n "$state_file" ]]; then
      if state_json="$(ralph_mcp_proxy_shell_command_state_read "$workspace" "$plan_key" "$command_hash" 2>/dev/null)"; then
        jq -c \
          --arg lastJobId "$(basename "$job_dir")" \
          --arg lastStatus "$status" \
          '.activeJobId = null | .lastJobId = $lastJobId | .lastStatus = $lastStatus | .retryBreakerTripped = false' \
          <<<"$state_json" | ralph_mcp_proxy_shell_command_state_write "$state_file"
      fi
    fi
  fi
}

ralph_mcp_proxy_shell_job_running_json() {
  local job_id="${1:-}" command="${2:-}" timeout_sec="${3:-}" started_at="${4:-}" start_epoch="${5:-}" pid="${6:-0}" pgid="${7:-0}" sid="${8:-0}" supervisor_pid="${9:-0}" normalized_command="${10:-}" command_hash="${11:-}" launch_mode="${12:-plain}" isolated="${13:-true}"
  local isolated_json=false
  [[ "$isolated" == "true" || "$isolated" == "1" ]] && isolated_json=true
  jq -nc \
    --arg jobId "$job_id" \
    --arg status "running" \
    --arg command "$command" \
    --arg normalizedCommand "$normalized_command" \
    --arg normalizedCommandHash "$command_hash" \
    --arg startedAt "$started_at" \
    --arg launchMode "$launch_mode" \
    --argjson startEpoch "$start_epoch" \
    --argjson timeoutSeconds "$timeout_sec" \
    --argjson pid "${pid:-0}" \
    --argjson pgid "${pgid:-0}" \
    --argjson sid "${sid:-0}" \
    --argjson supervisorPid "${supervisor_pid:-0}" \
    --argjson isolatedProcessGroup "$isolated_json" \
    '{jobId:$jobId,status:$status,command:$command,normalizedCommand:(if $normalizedCommand == "" then null else $normalizedCommand end),normalizedCommandHash:(if $normalizedCommandHash == "" then null else $normalizedCommandHash end),pid:$pid,pgid:$pgid,sid:$sid,supervisorPid:$supervisorPid,isolatedProcessGroup:$isolatedProcessGroup,launchMode:$launchMode,exitCode:null,timeoutSeconds:$timeoutSeconds,startedAt:$startedAt,startEpoch:$startEpoch,endedAt:null,elapsedSeconds:0,stdoutBytes:0,stderrBytes:0,combinedBytes:0,resultId:null,resultPath:null,preview:""}'
}

ralph_mcp_proxy_shell_job_start_managed() {
  local workspace="${1:-}" command="${2:-}" timeout_sec="${3:-}" max_shell_bytes="${4:-}" normalized_command="${5:-}" command_hash="${6:-}"
  local plan_key job_id job_dir started_at start_epoch launch_json pid pgid sid isolated launch_mode supervisor_pid

  plan_key="$(ralph_mcp_proxy_shell_job_plan_key)"
  job_id="$(ralph_mcp_proxy_shell_job_id_new)"
  job_dir="$(ralph_mcp_proxy_shell_job_dir "$workspace" "$plan_key" "$job_id")" || return 1
  mkdir -p "$job_dir"
  started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  start_epoch="$(date +%s)"
  printf '%s\n' "$started_at" >"$job_dir/started-at.txt"
  ralph_mcp_proxy_shell_job_running_json "$job_id" "$command" "$timeout_sec" "$started_at" "$start_epoch" 0 0 0 0 "$normalized_command" "$command_hash" "pending" "false" | ralph_mcp_proxy_shell_job_write_state "$job_dir/state.json"

  (
    set +e
    local _exit=0 _timed_out=0 _kill_escalated=0 _now
    ralph_native_shell_launch_process_group "$workspace" "$command" "bash" "$job_dir/stdout.log" "$job_dir/stderr.log"
    pid="${RALPH_NATIVE_SHELL_LAUNCH_PID:-0}"
    pgid="${RALPH_NATIVE_SHELL_LAUNCH_PGID:-0}"
    sid="${RALPH_NATIVE_SHELL_LAUNCH_SID:-0}"
    isolated="${RALPH_NATIVE_SHELL_LAUNCH_ISOLATED:-false}"
    launch_mode="${RALPH_NATIVE_SHELL_LAUNCH_MODE:-plain}"
    printf '%s\n' "$pid" >"$job_dir/pid"
    printf '%s\n' "$pgid" >"$job_dir/pgid"
    printf '%s\n' "$sid" >"$job_dir/sid"
    printf '%s\n' "$isolated" >"$job_dir/isolated-process-group"
    printf '%s\n' "$launch_mode" >"$job_dir/launch-mode"
    printf '%s\n' "$$" >"$job_dir/supervisor.pid"
    ralph_mcp_proxy_shell_job_running_json "$job_id" "$command" "$timeout_sec" "$started_at" "$start_epoch" "$pid" "$pgid" "$sid" "$$" "$normalized_command" "$command_hash" "$launch_mode" "$isolated" | ralph_mcp_proxy_shell_job_write_state "$job_dir/state.json"

    while ralph_native_shell_pid_running "$pid"; do
      _now="$(date +%s)"
      if (( _now - start_epoch >= timeout_sec )); then
        _timed_out=1
        _kill_escalated="$(ralph_mcp_proxy_shell_job_kill_managed "$pid" "$pgid" "$isolated")"
        printf '%s\n' "$_kill_escalated" >"$job_dir/kill-escalated"
        ralph_mcp_proxy_log_action "process-group-timeout" "tool=ralph_proxy_shell jobId=$job_id pgid=$pgid commandHash=${command_hash:0:12} escalated=$_kill_escalated"
        break
      fi
      sleep 0.1
    done

    wait "$pid" 2>/dev/null
    _exit=$?
    if (( _timed_out == 1 )); then
      _exit=124
    fi
    ralph_mcp_proxy_shell_job_finish "$workspace" "$job_dir" "$command" "$timeout_sec" "$max_shell_bytes" "$start_epoch" "$_exit" "$normalized_command" "$command_hash"
  ) &
  supervisor_pid=$!
  disown "$supervisor_pid" 2>/dev/null || true
  printf '%s\n' "$supervisor_pid" >"$job_dir/supervisor.pid"

  jq -c --argjson supervisorPid "$supervisor_pid" '.supervisorPid = $supervisorPid' "$job_dir/state.json" | ralph_mcp_proxy_shell_job_write_state "$job_dir/state.json"
  RALPH_MCP_PROXY_SHELL_JOB_START_JSON="$(cat "$job_dir/state.json")"
  export RALPH_MCP_PROXY_SHELL_JOB_START_JSON
}

ralph_mcp_proxy_owned_tool_shell_start() {
  local workspace="${1:-}"
  local args_json; args_json="$(ralph_mcp_proxy_normalize_args_json "${2-}")"
  local command original_command timeout_sec max_shell_bytes running_json

  command="$(jq -r '.command // empty' <<< "$args_json")"
  original_command="$command"
  timeout_sec="${RALPH_MCP_PROXY_POLICY_OWNED_SHELL_TIMEOUT:-10}"
  max_shell_bytes="${RALPH_MCP_PROXY_POLICY_OWNED_MAX_SHELL_BYTES:-32768}"

  if [[ -z "$command" ]]; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_shell_start requires command"
    return 0
  fi
  if ! ralph_mcp_proxy_shell_command_allowed_or_scoped "ralph_proxy_shell_start" "$args_json" "$command"; then
    ralph_mcp_proxy_signal_fatal_violation "ralph_proxy_shell_start" "ralph_proxy_shell_start: command is not on the read-only allowlist" "command=$command" "denied-command"
    ralph_mcp_proxy_tool_error_json "${RALPH_MCP_PROXY_FATAL_REASON:-ralph_proxy_shell_start command denied}"
    return 0
  fi
  if ! command="$(ralph_mcp_proxy_shell_command_after_rewrite "$workspace" "$command")"; then
    ralph_mcp_proxy_signal_fatal_violation "ralph_proxy_shell_start" "ralph_proxy_shell_start: rewritten command is not on the read-only allowlist" "command=$original_command" "denied-command"
    ralph_mcp_proxy_tool_error_json "${RALPH_MCP_PROXY_FATAL_REASON:-ralph_proxy_shell_start command denied}"
    return 0
  fi

  ralph_mcp_proxy_mutation_counter_bump

  if ! ralph_mcp_proxy_shell_job_start_managed "$workspace" "$command" "$timeout_sec" "$max_shell_bytes" "" ""; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_shell_start: failed to launch managed job"
    return 0
  fi
  running_json="${RALPH_MCP_PROXY_SHELL_JOB_START_JSON:-}"

  local start_response_json
  start_response_json="$(
    jq -c \
      --arg nextWait "ralph_proxy_shell_wait" \
      --arg nextRead "ralph_proxy_shell_read" \
      '. + {nextActions:[{tool:$nextWait,args:{jobId:.jobId}},{tool:$nextRead,args:{jobId:.jobId,stream:"combined",tailBytes:8192}}]}' \
      <<<"$running_json"
  )"
  ralph_mcp_proxy_tool_success_json "$(ralph_mcp_proxy_object_next_actions_catalog_safe_json "$start_response_json")"
}

ralph_mcp_proxy_owned_tool_shell_status() {
  local workspace="${1:-}"
  local args_json job_id plan_key job_dir response_json
  args_json="$(ralph_mcp_proxy_normalize_args_json "${2-}")"
  job_id="$(jq -r '.jobId // empty' <<< "$args_json")"
  plan_key="$(ralph_mcp_proxy_shell_job_plan_key)"
  job_dir="$(ralph_mcp_proxy_shell_job_dir "$workspace" "$plan_key" "$job_id")" || {
    ralph_mcp_proxy_tool_error_json "ralph_proxy_shell_status: invalid jobId"
    return 0
  }
  [[ -f "$job_dir/state.json" ]] || {
    ralph_mcp_proxy_tool_error_json "ralph_proxy_shell_status: job not found"
    return 0
  }
  response_json="$(ralph_mcp_proxy_shell_status_response_json "$job_dir" "$args_json")"
  ralph_mcp_proxy_tool_success_json "$response_json"
}

ralph_mcp_proxy_shell_status_response_json() {
  local job_dir="${1:-}" args_json="${2:-}" tail_bytes state status pid pgid isolated now started_epoch preview stdout_bytes stderr_bytes combined_bytes response_json
  [[ -n "$args_json" ]] || args_json='{}'
  tail_bytes="$(jq -r '.tailBytes // 4096' <<< "$args_json")"
  state="$(cat "$job_dir/state.json")"
  status="$(jq -r '.status // "unknown"' <<< "$state")"
  pid="$(jq -r '.pid // empty' <<< "$state")"
  pgid="$(jq -r '.pgid // empty' <<< "$state")"
  isolated="$(jq -r '.isolatedProcessGroup // false' <<< "$state")"
  stdout_bytes="$(wc -c <"$job_dir/stdout.log" 2>/dev/null | tr -d ' ' || echo 0)"
  stderr_bytes="$(wc -c <"$job_dir/stderr.log" 2>/dev/null | tr -d ' ' || echo 0)"
  cat "$job_dir/stdout.log" "$job_dir/stderr.log" 2>/dev/null >"$job_dir/combined.current.log" || true
  combined_bytes="$(wc -c <"$job_dir/combined.current.log" 2>/dev/null | tr -d ' ' || echo 0)"
  preview="$(ralph_mcp_proxy_shell_job_tail_file "$job_dir/combined.current.log" "$tail_bytes")"
  if [[ "$status" == "running" && "$isolated" == "true" && "$pgid" =~ ^[0-9]+$ ]] && ! kill -0 -"$pgid" 2>/dev/null; then
    status="unknown"
  elif [[ "$status" == "running" && "$pid" =~ ^[0-9]+$ ]] && ! kill -0 "$pid" 2>/dev/null; then
    status="unknown"
  fi
  now="$(date +%s)"
  started_epoch="$(jq -r '.startEpoch // empty' <<< "$state")"
  [[ "$started_epoch" =~ ^[0-9]+$ ]] || started_epoch="$now"
  response_json="$(jq -c \
    --arg status "$status" \
    --arg preview "$preview" \
    --argjson elapsedSeconds "$((now - started_epoch))" \
    --argjson stdoutBytes "$stdout_bytes" \
    --argjson stderrBytes "$stderr_bytes" \
    --argjson combinedBytes "$combined_bytes" \
    '.status = $status | .elapsedSeconds = $elapsedSeconds | .stdoutBytes = $stdoutBytes | .stderrBytes = $stderrBytes | .combinedBytes = $combinedBytes | .preview = $preview' \
    <<< "$state")"
  printf '%s' "$response_json"
}

ralph_mcp_proxy_owned_tool_shell_wait() {
  local workspace="${1:-}"
  local args_json job_id plan_key job_dir wait_seconds tail_bytes start_epoch deadline now status response_json next_actions
  args_json="$(ralph_mcp_proxy_normalize_args_json "${2-}")"
  job_id="$(jq -r '.jobId // empty' <<< "$args_json")"
  plan_key="$(ralph_mcp_proxy_shell_job_plan_key)"
  job_dir="$(ralph_mcp_proxy_shell_job_dir "$workspace" "$plan_key" "$job_id")" || {
    ralph_mcp_proxy_tool_error_json "ralph_proxy_shell_wait: invalid jobId"
    return 0
  }
  [[ -f "$job_dir/state.json" ]] || {
    ralph_mcp_proxy_tool_error_json "ralph_proxy_shell_wait: job not found"
    return 0
  }
  wait_seconds="$(jq -r '.waitSeconds // 60' <<< "$args_json")"
  if ! [[ "$wait_seconds" =~ ^[0-9]+$ ]]; then
    wait_seconds=60
  fi
  if (( wait_seconds < 1 )); then
    wait_seconds=1
  elif (( wait_seconds > 600 )); then
    wait_seconds=600
  fi
  tail_bytes="$(jq -r '.tailBytes // 4096' <<< "$args_json")"
  if ! [[ "$tail_bytes" =~ ^[0-9]+$ ]]; then
    tail_bytes=4096
  fi
  args_json="$(jq --argjson tailBytes "$tail_bytes" '.tailBytes = $tailBytes' <<< "$args_json")"

  response_json="$(ralph_mcp_proxy_shell_status_response_json "$job_dir" "$args_json")"
  status="$(jq -r '.status // "unknown"' <<< "$response_json")"
  if [[ "$status" != "running" ]]; then
    ralph_mcp_proxy_tool_success_json "$response_json"
    return 0
  fi

  start_epoch="$(date +%s)"
  deadline=$((start_epoch + wait_seconds))
  while :; do
    now="$(date +%s)"
    if (( now >= deadline )); then
      break
    fi
    sleep 1
    response_json="$(ralph_mcp_proxy_shell_status_response_json "$job_dir" "$args_json")"
    status="$(jq -r '.status // "unknown"' <<< "$response_json")"
    if [[ "$status" != "running" ]]; then
      ralph_mcp_proxy_tool_success_json "$response_json"
      return 0
    fi
  done

  next_actions="$(jq -nc \
    --arg jobId "$job_id" \
    --argjson tailBytes "$tail_bytes" \
    --argjson waitSeconds "$wait_seconds" \
    '[{tool:"ralph_proxy_shell_wait",args:{jobId:$jobId,tailBytes:$tailBytes,waitSeconds:$waitSeconds}},{tool:"ralph_proxy_shell_read",args:{jobId:$jobId,stream:"combined",tailBytes:$tailBytes}}]'
  )"
  next_actions="$(ralph_mcp_proxy_next_actions_catalog_safe_json "$next_actions")"
  response_json="$(jq --argjson waitTimedOut true --argjson nextActions "$next_actions" '. + {waitTimedOut:$waitTimedOut,nextActions:$nextActions}' <<< "$response_json")"
  ralph_mcp_proxy_tool_success_json "$response_json"
}

ralph_mcp_proxy_owned_tool_shell_read() {
  local workspace="${1:-}"
  local args_json job_id plan_key job_dir stream file_path byte_start byte_end tail_bytes text
  args_json="$(ralph_mcp_proxy_normalize_args_json "${2-}")"
  job_id="$(jq -r '.jobId // empty' <<< "$args_json")"
  stream="$(jq -r '.stream // "combined"' <<< "$args_json")"
  byte_start="$(jq -r '.byteStart // empty' <<< "$args_json")"
  byte_end="$(jq -r '.byteEnd // empty' <<< "$args_json")"
  tail_bytes="$(jq -r '.tailBytes // empty' <<< "$args_json")"
  plan_key="$(ralph_mcp_proxy_shell_job_plan_key)"
  job_dir="$(ralph_mcp_proxy_shell_job_dir "$workspace" "$plan_key" "$job_id")" || {
    ralph_mcp_proxy_tool_error_json "ralph_proxy_shell_read: invalid jobId"
    return 0
  }
  [[ -f "$job_dir/state.json" ]] || {
    ralph_mcp_proxy_tool_error_json "ralph_proxy_shell_read: job not found"
    return 0
  }
  case "$stream" in
    stdout) file_path="$job_dir/stdout.log" ;;
    stderr) file_path="$job_dir/stderr.log" ;;
    combined)
      cat "$job_dir/stdout.log" "$job_dir/stderr.log" 2>/dev/null >"$job_dir/combined.current.log" || true
      file_path="$job_dir/combined.current.log"
      ;;
    *)
      ralph_mcp_proxy_tool_error_json "ralph_proxy_shell_read: stream must be stdout, stderr, or combined"
      return 0
      ;;
  esac
  if ! text="$(ralph_mcp_proxy_shell_job_read_file_range "$file_path" "$byte_start" "$byte_end" "$tail_bytes")"; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_shell_read: invalid byte range"
    return 0
  fi
  ralph_mcp_proxy_tool_success_json "$text"
}

ralph_mcp_proxy_owned_tool_shell_cancel() {
  local workspace="${1:-}"
  local args_json job_id plan_key job_dir state pid pgid isolated now started_epoch response_json kill_escalated
  args_json="$(ralph_mcp_proxy_normalize_args_json "${2-}")"
  job_id="$(jq -r '.jobId // empty' <<< "$args_json")"
  plan_key="$(ralph_mcp_proxy_shell_job_plan_key)"
  job_dir="$(ralph_mcp_proxy_shell_job_dir "$workspace" "$plan_key" "$job_id")" || {
    ralph_mcp_proxy_tool_error_json "ralph_proxy_shell_cancel: invalid jobId"
    return 0
  }
  [[ -f "$job_dir/state.json" ]] || {
    ralph_mcp_proxy_tool_error_json "ralph_proxy_shell_cancel: job not found"
    return 0
  }
  state="$(cat "$job_dir/state.json")"
  pid="$(jq -r '.pid // empty' <<< "$state")"
  pgid="$(jq -r '.pgid // empty' <<< "$state")"
  isolated="$(jq -r '.isolatedProcessGroup // false' <<< "$state")"
  kill_escalated="$(ralph_mcp_proxy_shell_job_kill_managed "$pid" "$pgid" "$isolated")"
  printf '%s\n' "$kill_escalated" >"$job_dir/kill-escalated"
  ralph_mcp_proxy_log_action "process-group-cancel" "tool=ralph_proxy_shell jobId=$job_id pgid=$pgid escalated=$kill_escalated"
  now="$(date +%s)"
  started_epoch="$(jq -r '.startEpoch // empty' <<< "$state")"
  [[ "$started_epoch" =~ ^[0-9]+$ ]] || started_epoch="$now"
  response_json="$(jq -c \
    --arg status "cancelled" \
    --arg endedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg terminationReason "cancelled" \
    --argjson killEscalated "$([[ "$kill_escalated" == "1" ]] && printf true || printf false)" \
    --argjson elapsedSeconds "$((now - started_epoch))" \
    '.status = $status | .endedAt = $endedAt | .terminationReason = $terminationReason | .killEscalated = $killEscalated | .elapsedSeconds = $elapsedSeconds' \
    <<< "$state")"
  printf '%s\n' "$response_json" >"$job_dir/state.json"
  local command_hash
  command_hash="$(jq -r '.normalizedCommandHash // empty' <<<"$state")"
  if [[ -n "$command_hash" ]]; then
    local state_file command_state_json
    state_file="$(ralph_mcp_proxy_shell_command_state_file "$workspace" "$plan_key" "$command_hash" 2>/dev/null || true)"
    if [[ -n "$state_file" ]] && command_state_json="$(ralph_mcp_proxy_shell_command_state_read "$workspace" "$plan_key" "$command_hash" 2>/dev/null)"; then
      jq -c --arg lastJobId "$job_id" '.activeJobId = null | .lastJobId = $lastJobId | .lastStatus = "cancelled"' <<<"$command_state_json" | ralph_mcp_proxy_shell_command_state_write "$state_file"
    fi
  fi
  ralph_mcp_proxy_tool_success_json "$response_json"
}

ralph_mcp_proxy_owned_tool_shell_sync_timeout_seconds() {
  # Hard ceiling for the synchronous ralph_proxy_shell path. Keep it strictly
  # below the typical host MCP client transport timeout (Claude's default is
  # 60s) so the single stdio read loop never blocks long enough to produce
  # `-32000 Connection closed`. The policy-owned shell timeout still governs
  # the underlying `timeout` wrapper; this value is a safety net above which we
  # hand the command off to the async job machinery instead of blocking the
  # transport. A command with an explicit `timeoutSeconds` arg below this cap
  # continues to run synchronously.
  local policy_timeout="${1:-}"
  local default_cap=30
  local user_cap
  user_cap="${RALPH_PROXY_SHELL_SYNC_TIMEOUT_SECONDS:-}"
  if [[ -n "$user_cap" ]] && [[ "$user_cap" =~ ^[0-9]+$ ]] && (( user_cap >= 1 )); then
    if [[ -n "$policy_timeout" ]] && [[ "$policy_timeout" =~ ^[0-9]+$ ]] && (( user_cap > policy_timeout )); then
      printf '%s\n' "$policy_timeout"
      return 0
    fi
    printf '%s\n' "$user_cap"
    return 0
  fi
  printf '%s\n' "$default_cap"
}

ralph_mcp_proxy_owned_tool_shell_handoff_json() {
  # Structured handoff returned when a synchronous ralph_proxy_shell command
  # would exceed the server-side hard timeout. The agent can re-issue the same
  # command with ralph_proxy_shell_start and wait with ralph_proxy_shell_wait,
  # or the caller can drive the returned nextActions directly.
  local command="${1:-}"
  local timeout_seconds="${2:-}"
  local handoff_message="${3:-}"
  local command_hash="${4:-}"
  local job_json="${5:-}"
  local reused="${6:-false}"
  local created="${7:-false}"
  [[ -n "$job_json" ]] || job_json='{}'
  local reused_json=false
  local created_json=false
  [[ "$reused" == "true" || "$reused" == "1" ]] && reused_json=true
  [[ "$created" == "true" || "$created" == "1" ]] && created_json=true

  local handoff_json
  handoff_json="$(jq -nc \
    --arg command "$command" \
    --arg timeoutSeconds "$timeout_seconds" \
    --arg handoffMessage "$handoff_message" \
    --arg normalizedCommandHash "$command_hash" \
    --arg waitTool "ralph_proxy_shell_wait" \
    --arg statusTool "ralph_proxy_shell_status" \
    --arg readTool "ralph_proxy_shell_read" \
    --argjson job "$job_json" \
    --argjson asyncJobReused "$reused_json" \
    --argjson asyncJobCreated "$created_json" \
    '{
      shellTimeoutHandoff: true,
      command: $command,
      normalizedCommandHash: $normalizedCommandHash,
      jobId: ($job.jobId // null),
      asyncJobReused: $asyncJobReused,
      asyncJobCreated: $asyncJobCreated,
      timeoutSeconds: $timeoutSeconds,
      message: $handoffMessage,
      nextActions: [
        {tool: $waitTool, args: {jobId: ($job.jobId // "<jobId>"), waitSeconds: ($timeoutSeconds | tonumber)}},
        {tool: $statusTool, args: {jobId: ($job.jobId // "<jobId>")}},
        {tool: $readTool, args: {jobId: ($job.jobId // "<jobId>"), stream: "combined", tailBytes: 8192}}
      ]
    }')"
  ralph_mcp_proxy_object_next_actions_catalog_safe_json "$handoff_json"
}

ralph_mcp_proxy_shell_request_record_json() {
  local state_json="${1:-}"
  [[ -n "$state_json" ]] || state_json='{}'
  jq -c --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.requestCount = ((.requestCount // 0) + 1) | .lastRequestAt = $now' \
    <<<"$state_json"
}

ralph_mcp_proxy_shell_state_capture_timeout_json() {
  local state_json="${1:-}"
  [[ -n "$state_json" ]] || state_json='{}'
  jq -c --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.syncTimeoutCount = ((.syncTimeoutCount // 0) + 1) | .lastSyncTimeoutAt = $now' \
    <<<"$state_json"
}

ralph_mcp_proxy_shell_job_is_running() {
  local workspace="${1:-}" plan_key="${2:-}" job_id="${3:-}" job_dir state status pgid isolated pid
  job_dir="$(ralph_mcp_proxy_shell_job_dir "$workspace" "$plan_key" "$job_id" 2>/dev/null || true)"
  [[ -n "$job_dir" && -f "$job_dir/state.json" ]] || return 1
  state="$(cat "$job_dir/state.json")"
  status="$(jq -r '.status // ""' <<<"$state")"
  [[ "$status" == "running" ]] || return 1
  pgid="$(jq -r '.pgid // empty' <<<"$state")"
  isolated="$(jq -r '.isolatedProcessGroup // false' <<<"$state")"
  pid="$(jq -r '.pid // empty' <<<"$state")"
  if [[ "$isolated" == "true" && "$pgid" =~ ^[0-9]+$ ]]; then
    kill -0 -"$pgid" 2>/dev/null
    return $?
  fi
  ralph_native_shell_pid_running "$pid"
}

ralph_mcp_proxy_shell_command_acquire_job_json() {
  local workspace="${1:-}" command="${2:-}" timeout_sec="${3:-}" max_shell_bytes="${4:-}" normalized_command="${5:-}" command_hash="${6:-}" reason="${7:-}"
  local plan_key state_file state_json active_job_id running_json
  local reused=false created=false

  plan_key="$(ralph_mcp_proxy_shell_job_plan_key)"
  state_file="$(ralph_mcp_proxy_shell_command_state_file "$workspace" "$plan_key" "$command_hash")" || return 1
  if ! state_json="$(ralph_mcp_proxy_shell_command_state_read "$workspace" "$plan_key" "$command_hash" 2>/dev/null)"; then
    state_json="$(ralph_mcp_proxy_shell_command_state_init_json "$command" "$normalized_command" "$command_hash")"
  fi
  state_json="$(jq -c \
    --arg command "$command" \
    --arg normalizedCommand "$normalized_command" \
    --arg normalizedCommandHash "$command_hash" \
    '.command = $command | .normalizedCommand = $normalizedCommand | .normalizedCommandHash = $normalizedCommandHash' \
    <<<"$state_json")"
  state_json="$(ralph_mcp_proxy_shell_request_record_json "$state_json")"

  active_job_id="$(jq -r '.activeJobId // empty' <<<"$state_json")"
  if [[ -n "$active_job_id" ]] && ralph_mcp_proxy_shell_job_is_running "$workspace" "$plan_key" "$active_job_id"; then
    reused=true
    running_json="$(ralph_mcp_proxy_shell_job_state_json "$(ralph_mcp_proxy_shell_job_dir "$workspace" "$plan_key" "$active_job_id")")"
    state_json="$(jq -c '.asyncReuseCount = ((.asyncReuseCount // 0) + 1)' <<<"$state_json")"
  else
    ralph_mcp_proxy_shell_job_start_managed "$workspace" "$command" "$timeout_sec" "$max_shell_bytes" "$normalized_command" "$command_hash" || return 1
    running_json="${RALPH_MCP_PROXY_SHELL_JOB_START_JSON:-}"
    created=true
    active_job_id="$(jq -r '.jobId // empty' <<<"$running_json")"
  fi

  state_json="$(jq -c \
    --arg activeJobId "$active_job_id" \
    --arg lastJobId "$active_job_id" \
    --arg lastStatus "running" \
    --arg reason "$reason" \
    '.activeJobId = $activeJobId | .lastJobId = $lastJobId | .lastStatus = $lastStatus | .lastReason = $reason' \
    <<<"$state_json")"
  printf '%s\n' "$state_json" | ralph_mcp_proxy_shell_command_state_write "$state_file"

  RALPH_MCP_PROXY_SHELL_COMMAND_ACQUIRE_JSON="$(jq -nc \
    --argjson job "$running_json" \
    --argjson state "$state_json" \
    --argjson reused "$([[ "$reused" == "true" ]] && printf true || printf false)" \
    --argjson created "$([[ "$created" == "true" ]] && printf true || printf false)" \
    '{job:$job,state:$state,reused:$reused,created:$created}')"
  export RALPH_MCP_PROXY_SHELL_COMMAND_ACQUIRE_JSON
}

ralph_mcp_proxy_shell_retry_breaker_error_json() {
  local command="${1:-}" command_hash="${2:-}" state_json="${3:-}" job_json="${4:-}"
  [[ -n "$state_json" ]] || state_json='{}'
  [[ -n "$job_json" ]] || job_json='{}'
  local breaker_json
  breaker_json="$(jq -nc \
    --arg command "$command" \
    --arg normalizedCommandHash "$command_hash" \
    --argjson state "$state_json" \
    --argjson job "$job_json" \
    '{
      syncShellRetryBlocked: true,
      command: $command,
      normalizedCommandHash: $normalizedCommandHash,
      jobId: ($job.jobId // $state.activeJobId // $state.lastJobId // null),
      message: "Repeated synchronous requests for the same managed verification command were blocked. Use the existing async job with ralph_proxy_shell_wait, ralph_proxy_shell_status, or ralph_proxy_shell_read instead of reissuing ralph_proxy_shell.",
      nextActions: [
        {tool: "ralph_proxy_shell_wait", args: {jobId: ($job.jobId // $state.activeJobId // $state.lastJobId // "<jobId>"), waitSeconds: 120}},
        {tool: "ralph_proxy_shell_status", args: {jobId: ($job.jobId // $state.activeJobId // $state.lastJobId // "<jobId>")}},
        {tool: "ralph_proxy_shell_read", args: {jobId: ($job.jobId // $state.activeJobId // $state.lastJobId // "<jobId>"), stream: "combined", tailBytes: 8192}}
      ]
    }')"
  ralph_mcp_proxy_object_next_actions_catalog_safe_json "$breaker_json"
}

ralph_mcp_proxy_shell_trim_spaces() {
  local text="${1:-}"
  text="${text#"${text%%[![:space:]]*}"}"
  text="${text%"${text##*[![:space:]]}"}"
  printf '%s' "$text"
}

ralph_mcp_proxy_shell_unquote_outer() {
  local text; text="$(ralph_mcp_proxy_shell_trim_spaces "${1:-}")"
  local first last len
  len="${#text}"
  if (( len >= 2 )); then
    first="${text:0:1}"
    last="${text:len-1:1}"
    if [[ "$first" == "$last" && ( "$first" == "'" || "$first" == '"' ) ]]; then
      printf '%s' "${text:1:len-2}"
      return 0
    fi
  fi
  printf '%s' "$text"
}

ralph_mcp_proxy_shell_normalize_command_shape() {
  local command; command="$(ralph_mcp_proxy_shell_trim_spaces "${1:-}")"
  local previous="" inner depth=0

  while [[ -n "$command" && "$command" != "$previous" && $depth -lt 12 ]]; do
    previous="$command"
    depth=$((depth + 1))
    command="$(ralph_mcp_proxy_shell_trim_spaces "$command")"

    while [[ "$command" =~ ^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+[[:space:]]+(.+)$ ]]; do
      command="${BASH_REMATCH[1]}"
      command="$(ralph_mcp_proxy_shell_trim_spaces "$command")"
    done
    if [[ "$command" =~ ^env[[:space:]]+(.+)$ ]]; then
      command="${BASH_REMATCH[1]}"
      while [[ "$command" =~ ^-[A-Za-z]+[[:space:]]+(.+)$ ]]; do
        command="${BASH_REMATCH[1]}"
      done
      while [[ "$command" =~ ^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+[[:space:]]+(.+)$ ]]; do
        command="${BASH_REMATCH[1]}"
      done
    fi
    if [[ "$command" == cd[[:space:]]* && "$command" == *"&&"* ]]; then
      command="${command#*&&}"
      command="$(ralph_mcp_proxy_shell_trim_spaces "$command")"
    fi
    if [[ "$command" =~ ^(bash|sh)[[:space:]]+-l?c[[:space:]]+(.+)$ ]]; then
      inner="$(ralph_mcp_proxy_shell_unquote_outer "${BASH_REMATCH[2]}")"
      if [[ -n "$inner" ]]; then
        command="$inner"
      fi
    fi
    if [[ "$command" =~ ^(.+)[[:space:]]*\|[[:space:]]*(tail|head|sed|cat)([[:space:]].*)?$ ]]; then
      command="${BASH_REMATCH[1]}"
    fi
  done

  command="$(printf '%s' "$command" | tr '\n' ' ' | tr -s '[:space:]' ' ' | tr '[:upper:]' '[:lower:]')"
  ralph_mcp_proxy_shell_trim_spaces "$command"
}

# Returns 0 (true) when the command matches a known verification/build shape
# that is likely to block the synchronous shell for a long time, even when the
# command is wrapped in cd/env/bash -c forms or tailed through a trailing pipe.
ralph_mcp_proxy_shell_is_long_verification_command() {
  local command="${1:-}"
  local cmd_stripped
  cmd_stripped="$(ralph_mcp_proxy_shell_normalize_command_shape "$command")"

  if [[ "$cmd_stripped" =~ ^(npm|yarn|pnpm)[[:space:]]+(test|install|ci|audit)([[:space:]]|$) ]] || \
     [[ "$cmd_stripped" =~ ^(npm|yarn|pnpm)[[:space:]]+run[[:space:]]+(test|test:cov|lint|build|check|typecheck|e2e|ci|coverage)([[:space:]]|$) ]]; then
    return 0
  fi
  if [[ "$cmd_stripped" =~ (^|[[:space:]])(--coverage|coveragereporters=|coverage)([[:space:]]|$) ]]; then
    return 0
  fi
  if [[ "$cmd_stripped" =~ ^make[[:space:]]+(check|test|docs|all|install|build)([[:space:]]|$) ]]; then
    return 0
  fi
  if [[ "$cmd_stripped" =~ ^(pytest|jest|mocha|vitest)([[:space:]]|$) ]] || \
     [[ "$cmd_stripped" =~ ^vitest[[:space:]]+run([[:space:]]|$) ]]; then
    return 0
  fi
  if [[ "$cmd_stripped" =~ ^cargo[[:space:]]+(test|build|check)([[:space:]]|$) ]]; then
    return 0
  fi
  if [[ "$cmd_stripped" =~ ^go[[:space:]]+(test|build|vet)([[:space:]]|$) ]]; then
    return 0
  fi
  if [[ "$cmd_stripped" =~ ^python[3]?[[:space:]]+-m[[:space:]]+(pytest|unittest)([[:space:]]|$) ]]; then
    return 0
  fi
  if [[ "$cmd_stripped" =~ ^(bash|sh)[[:space:]].*docs[-_]check ]] || \
     [[ "$cmd_stripped" =~ docs[-_](check|build|generate) ]]; then
    return 0
  fi
  return 1
}

ralph_mcp_proxy_shell_dedupe_retry_limit() {
  local limit="${RALPH_PROXY_SHELL_DEDUPE_RETRY_LIMIT:-3}"
  if [[ ! "$limit" =~ ^[0-9]+$ || "$limit" -lt 1 ]]; then
    limit=3
  fi
  printf '%s\n' "$limit"
}

ralph_mcp_proxy_shell_long_verification_guidance_json() {
  local command="${1:-}" command_hash="${2:-}" job_json="${3:-}" reused="${4:-false}" created="${5:-false}"
  [[ -n "$job_json" ]] || job_json='{}'
  local reused_json=false
  local created_json=false
  [[ "$reused" == "true" || "$reused" == "1" ]] && reused_json=true
  [[ "$created" == "true" || "$created" == "1" ]] && created_json=true
  local guidance_json
  guidance_json="$(jq -nc \
    --arg command "$command" \
    --arg normalizedCommandHash "$command_hash" \
    --arg startTool "ralph_proxy_shell_start" \
    --arg waitTool "ralph_proxy_shell_wait" \
    --arg statusTool "ralph_proxy_shell_status" \
    --arg readTool "ralph_proxy_shell_read" \
    --argjson job "$job_json" \
    --argjson asyncJobReused "$reused_json" \
    --argjson asyncJobCreated "$created_json" \
    '{
      syncShellVerificationSteered: true,
      command: $command,
      normalizedCommandHash: $normalizedCommandHash,
      jobId: ($job.jobId // null),
      asyncJobReused: $asyncJobReused,
      asyncJobCreated: $asyncJobCreated,
      message: "This command matches a long-running verification or build pattern. Ralph started or reused a managed async job instead of executing it through synchronous ralph_proxy_shell. Use ralph_proxy_shell_wait or ralph_proxy_shell_read, or move the command into runner-owned verify: metadata.",
      nextActions: [
        {tool: $waitTool, args: {jobId: ($job.jobId // "<jobId>"), waitSeconds: 120}},
        {tool: $statusTool, args: {jobId: ($job.jobId // "<jobId>")}},
        {tool: $readTool, args: {jobId: ($job.jobId // "<jobId>"), stream: "combined", tailBytes: 8192}}
      ]
    }')"
  ralph_mcp_proxy_object_next_actions_catalog_safe_json "$guidance_json"
}

ralph_mcp_proxy_shell_verify_steer_enabled() {
  case "${RALPH_PROXY_SHELL_VERIFY_STEER:-1}" in
    0|false|no|off) return 1 ;;
    *) return 0 ;;
  esac
}

ralph_mcp_proxy_owned_tool_shell() {
  local workspace="${1:-}"
  local args_json; args_json="$(ralph_mcp_proxy_normalize_args_json "${2-}")"
  local command original_command timeout_sec sync_timeout_sec max_shell_bytes stdout stderr text exit_code
  local normalized_command command_hash state_json managed_json managed_job_json managed_state_json managed_reused managed_created retry_limit
  local exec_json timed_out kill_escalated

  command="$(jq -r '.command // empty' <<< "$args_json")"
  original_command="$command"
  timeout_sec="${RALPH_MCP_PROXY_POLICY_OWNED_SHELL_TIMEOUT:-10}"
  max_shell_bytes="${RALPH_MCP_PROXY_POLICY_OWNED_MAX_SHELL_BYTES:-32768}"

  if [[ -z "$command" ]]; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_shell requires command"
    return 0
  fi
  if ! ralph_mcp_proxy_shell_command_allowed_or_scoped "ralph_proxy_shell" "$args_json" "$command"; then
    ralph_mcp_proxy_signal_fatal_violation \
      "ralph_proxy_shell" \
      "ralph_proxy_shell: command is not on the read-only allowlist" \
      "command=$command" \
      "denied-command"
    ralph_mcp_proxy_tool_error_json "${RALPH_MCP_PROXY_FATAL_REASON:-ralph_proxy_shell command denied}"
    return 0
  fi

  if ! command="$(ralph_mcp_proxy_shell_command_after_rewrite "$workspace" "$command")"; then
    ralph_mcp_proxy_signal_fatal_violation \
      "ralph_proxy_shell" \
      "ralph_proxy_shell: rewritten command is not on the read-only allowlist" \
      "command=$original_command" \
      "denied-command"
    ralph_mcp_proxy_tool_error_json "${RALPH_MCP_PROXY_FATAL_REASON:-ralph_proxy_shell command denied}"
    return 0
  fi

  normalized_command="$(ralph_mcp_proxy_shell_normalize_command_shape "$command")"
  command_hash="$(ralph_hook_telemetry_sha256 "$normalized_command")"
  if ! state_json="$(ralph_mcp_proxy_shell_command_state_read "$workspace" "$(ralph_mcp_proxy_shell_job_plan_key)" "$command_hash" 2>/dev/null)"; then
    state_json="$(ralph_mcp_proxy_shell_command_state_init_json "$command" "$normalized_command" "$command_hash")"
  fi

  # Server-side heuristic: detect verification/build commands that are likely to
  # block the synchronous shell long enough to trigger a transport timeout. For
  # matched commands, synchronous shell execution is disallowed; Ralph creates or
  # reuses a managed async job and returns the job contract immediately.
  if ralph_mcp_proxy_shell_verify_steer_enabled && \
     ralph_mcp_proxy_shell_is_long_verification_command "$command" "$args_json"; then
    retry_limit="$(ralph_mcp_proxy_shell_dedupe_retry_limit)"
    ralph_mcp_proxy_shell_command_acquire_job_json "$workspace" "$command" "$timeout_sec" "$max_shell_bytes" "$normalized_command" "$command_hash" "verify-steer" || {
      ralph_mcp_proxy_tool_error_json "ralph_proxy_shell failed to create managed async verification job"
      return 0
    }
    managed_json="${RALPH_MCP_PROXY_SHELL_COMMAND_ACQUIRE_JSON:-}"
    managed_job_json="$(jq -c '.job' <<<"$managed_json")"
    managed_state_json="$(jq -c '.state' <<<"$managed_json")"
    managed_reused="$(jq -r '.reused' <<<"$managed_json")"
    managed_created="$(jq -r '.created' <<<"$managed_json")"
    if (( $(jq -r '.requestCount // 0' <<<"$managed_state_json") > retry_limit )); then
      local blocker_json
      blocker_json="$(ralph_mcp_proxy_shell_retry_breaker_error_json "$command" "$command_hash" "$managed_state_json" "$managed_job_json")"
      ralph_mcp_proxy_log_action "retry-breaker" "tool=ralph_proxy_shell commandHash=${command_hash:0:12} jobId=$(jq -r '.jobId // ""' <<<"$managed_job_json")"
      ralph_mcp_proxy_tool_error_json "$blocker_json"
      return 0
    fi
    local guidance_json
    guidance_json="$(ralph_mcp_proxy_shell_long_verification_guidance_json "$command" "$command_hash" "$managed_job_json" "$managed_reused" "$managed_created")"
    ralph_mcp_proxy_log_action "verify-steer" "tool=ralph_proxy_shell commandHash=${command_hash:0:12} reused=$managed_reused created=$managed_created"
    if [[ "$managed_reused" == "true" ]]; then
      ralph_mcp_proxy_log_action "async-job-reuse" "tool=ralph_proxy_shell commandHash=${command_hash:0:12} jobId=$(jq -r '.jobId // ""' <<<"$managed_job_json")"
    fi
    ralph_mcp_proxy_tool_success_json "$guidance_json"
    return 0
  fi

  if (( $(jq -r '.syncTimeoutCount // 0' <<<"$state_json") > 0 )); then
    ralph_mcp_proxy_shell_command_acquire_job_json "$workspace" "$command" "$timeout_sec" "$max_shell_bytes" "$normalized_command" "$command_hash" "prior-sync-timeout" || {
      ralph_mcp_proxy_tool_error_json "ralph_proxy_shell failed to create managed async timeout job"
      return 0
    }
    managed_json="${RALPH_MCP_PROXY_SHELL_COMMAND_ACQUIRE_JSON:-}"
    managed_job_json="$(jq -c '.job' <<<"$managed_json")"
    managed_reused="$(jq -r '.reused' <<<"$managed_json")"
    managed_created="$(jq -r '.created' <<<"$managed_json")"
    local prior_timeout_json
    prior_timeout_json="$(ralph_mcp_proxy_owned_tool_shell_handoff_json \
      "$command" \
      "$timeout_sec" \
      "This command previously exceeded the synchronous transport-safe timeout for the current plan/TODO. Ralph reused or created a managed async job instead of attempting sync execution again." \
      "$command_hash" \
      "$managed_job_json" \
      "$managed_reused" \
      "$managed_created")"
    ralph_mcp_proxy_log_action "timeout-handoff-reuse" "tool=ralph_proxy_shell commandHash=${command_hash:0:12} reused=$managed_reused created=$managed_created"
    ralph_mcp_proxy_tool_success_json "$prior_timeout_json"
    return 0
  fi

  ralph_mcp_proxy_mutation_counter_bump

  sync_timeout_sec="$(ralph_mcp_proxy_owned_tool_shell_sync_timeout_seconds "$timeout_sec")"

  # Determine how long we are willing to block the single stdio read loop for a
  # synchronous command. Use the caller's explicit timeoutSeconds when provided,
  # otherwise fall back to the policy-owned shell timeout. Clamp execution to the
  # transport-safe sync cap so long commands cannot outlive Claude's MCP client
  # transport timeout and kill the connection. Short bounded commands finish well
  # before the cap and behave exactly as before.
  local requested_timeout execute_timeout
  requested_timeout="$(jq -r '.timeoutSeconds // empty' <<< "$args_json")"
  if [[ -z "$requested_timeout" || "$requested_timeout" == "null" ]] || [[ ! "$requested_timeout" =~ ^[0-9]+$ ]] || (( requested_timeout <= 0 )); then
    requested_timeout="$timeout_sec"
  fi
  execute_timeout="$requested_timeout"
  if (( execute_timeout > sync_timeout_sec )); then
    execute_timeout="$sync_timeout_sec"
  fi

  exec_json="$(ralph_native_shell_execute_command_json "$workspace" "$command" "bash" "$execute_timeout")"
  stdout="$(jq -r '.stdout // ""' <<<"$exec_json")"
  stderr="$(jq -r '.stderr // ""' <<<"$exec_json")"
  exit_code="$(jq -r '.exitCode // 0' <<<"$exec_json")"
  timed_out="$(jq -r '.timedOut // false' <<<"$exec_json")"
  kill_escalated="$(jq -r '.killEscalated // false' <<<"$exec_json")"

  # When the transport-safe cap fires (timeout exit code 124), do not return a
  # generic error and do not let the transport close. Record the timeout and
  # transition the command into a managed async job contract for this plan/TODO.
  if [[ "$exit_code" -eq 124 || "$timed_out" == "true" ]]; then
    state_json="$(ralph_mcp_proxy_shell_state_capture_timeout_json "$state_json")"
    printf '%s\n' "$state_json" | ralph_mcp_proxy_shell_command_state_write "$(ralph_mcp_proxy_shell_command_state_file "$workspace" "$(ralph_mcp_proxy_shell_job_plan_key)" "$command_hash")"
    ralph_mcp_proxy_shell_command_acquire_job_json "$workspace" "$command" "$timeout_sec" "$max_shell_bytes" "$normalized_command" "$command_hash" "sync-timeout-handoff" || {
      ralph_mcp_proxy_tool_error_json "ralph_proxy_shell failed to create managed async timeout job"
      return 0
    }
    managed_json="${RALPH_MCP_PROXY_SHELL_COMMAND_ACQUIRE_JSON:-}"
    managed_job_json="$(jq -c '.job' <<<"$managed_json")"
    managed_reused="$(jq -r '.reused' <<<"$managed_json")"
    managed_created="$(jq -r '.created' <<<"$managed_json")"
    local handoff_json
    handoff_json="$(ralph_mcp_proxy_owned_tool_shell_handoff_json \
      "$command" \
      "$sync_timeout_sec" \
      "Synchronous shell command reached the transport-safe timeout (${sync_timeout_sec}s). Ralph created or reused a managed async job so the same command will not be relaunched through synchronous shell for this plan/TODO." \
      "$command_hash" \
      "$managed_job_json" \
      "$managed_reused" \
      "$managed_created")"
    ralph_mcp_proxy_log_action "timeout-handoff" "tool=ralph_proxy_shell cap=${sync_timeout_sec}s commandHash=${command_hash:0:12} killEscalated=$kill_escalated reused=$managed_reused created=$managed_created"
    ralph_mcp_proxy_tool_success_json "$handoff_json"
    return 0
  fi

  if ralph_mcp_proxy_shell_compact_enabled; then
    ralph_mcp_proxy_owned_tool_shell_compact \
      "$workspace" \
      "$command" \
      "$stdout" \
      "$stderr" \
      "$exit_code" \
      "$max_shell_bytes"
    return 0
  fi

  text="$(ralph_mcp_proxy_shell_combine_streams "$stdout" "$stderr")"
  if [[ "$exit_code" -ne 0 ]]; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_shell exited $exit_code: $text"
    return 0
  fi

  ralph_mcp_proxy_owned_tool_shell_finish_success "$workspace" "$text" "$max_shell_bytes"
}

ralph_mcp_proxy_owned_tool_batch() {
  local workspace="${1:-}"
  local args_json; args_json="$(ralph_mcp_proxy_normalize_args_json "${2-}")"
  local max_ops op_count i=0 report_lines=() report preview op_json op_tool op_args op_result op_text op_is_error op_status
  local op_result_tmp batch_timeout_sec start_epoch current_epoch elapsed_sec
  local has_timeout_error=0 completed_ops=0

  max_ops="$(ralph_mcp_proxy_batch_max_operations)"
  batch_timeout_sec="$(ralph_mcp_proxy_batch_timeout_sec)"
  start_epoch="$(date +%s)"

  if ! jq -e '.operations | type == "array"' <<< "$args_json" >/dev/null 2>&1; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_batch requires operations array"
    return 0
  fi

  op_count="$(jq -r '.operations | length' <<< "$args_json")"
  if [[ "$op_count" -eq 0 ]]; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_batch requires at least one operation"
    return 0
  fi
  if [[ "$op_count" -gt "$max_ops" ]]; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_batch: too many operations (max $max_ops)"
    return 0
  fi

  while [[ "$i" -lt "$op_count" ]]; do
    current_epoch="$(date +%s)"
    elapsed_sec=$((current_epoch - start_epoch))
    if [[ "$elapsed_sec" -ge "$batch_timeout_sec" ]]; then
      has_timeout_error=1
      report_lines+=("$((i + 1)). (remaining operations): timeout | batch exceeded ${batch_timeout_sec}s limit")
      break
    fi

    op_json="$(jq -c ".operations[$i]" <<< "$args_json")"
    op_tool="$(jq -r '.tool // empty' <<< "$op_json")"
    op_args="$(jq -c '.arguments // {}' <<< "$op_json")"
    i=$((i + 1))

    if [[ -z "$op_tool" ]]; then
      report_lines+=("$i. (missing tool): error | tool name required")
      continue
    fi

    if ! ralph_mcp_proxy_batch_operation_tool_allowed "$op_tool"; then
      report_lines+=("$i. $op_tool: error | operation tool not allowed in batch")
      continue
    fi

    if [[ "$op_tool" == "ralph_proxy_search" ]] && ! ralph_mcp_proxy_search_tools_active; then
      report_lines+=("$i. $op_tool: error | ralph_proxy_search is not enabled")
      continue
    fi

    RALPH_MCP_PROXY_FATAL_VIOLATION=0
    RALPH_MCP_PROXY_FATAL_TOOL=""
    RALPH_MCP_PROXY_FATAL_REASON=""
    op_result_tmp="$(mktemp)"
    # Enforce the remaining batch budget on each operation, not just between
    # operations. A single slow grep/read can otherwise block the stdio loop
    # past the host MCP request timeout and kill the transport. Run the
    # operation in a subshell, persist any fatal-violation state to a sidecar
    # file (shell variables do not survive the fork), and kill it if the
    # remaining budget expires.
    local op_remaining_sec op_fatal_tmp op_pid op_waited_ticks op_timed_out
    op_remaining_sec=$((batch_timeout_sec - elapsed_sec))
    op_fatal_tmp="$(mktemp)"
    rm -f "$op_fatal_tmp"
    (
      ralph_mcp_proxy_call_owned_tool "$workspace" "$op_tool" "$op_args" >"$op_result_tmp"
      if [[ "${RALPH_MCP_PROXY_FATAL_VIOLATION:-0}" == "1" ]]; then
        jq -nc \
          --arg tool "${RALPH_MCP_PROXY_FATAL_TOOL:-}" \
          --arg reason "${RALPH_MCP_PROXY_FATAL_REASON:-}" \
          --arg arguments "${RALPH_MCP_PROXY_FATAL_ARGUMENTS:-}" \
          --arg category "${RALPH_MCP_PROXY_FATAL_CATEGORY:-}" \
          '{tool:$tool,reason:$reason,arguments:$arguments,category:$category}' >"$op_fatal_tmp"
      fi
    ) &
    op_pid=$!
    op_timed_out=0
    op_waited_ticks=0
    while kill -0 "$op_pid" 2>/dev/null; do
      if (( op_waited_ticks >= op_remaining_sec * 10 )); then
        op_timed_out=1
        if declare -F ralph_kill_tree >/dev/null 2>&1; then
          ralph_kill_tree "$op_pid"
        else
          kill -TERM "$op_pid" 2>/dev/null || true
          sleep 0.2
          kill -KILL "$op_pid" 2>/dev/null || true
        fi
        break
      fi
      sleep 0.1
      ((op_waited_ticks++)) || true
    done
    wait "$op_pid" 2>/dev/null || true
    if [[ -s "$op_fatal_tmp" ]]; then
      RALPH_MCP_PROXY_FATAL_VIOLATION=1
      RALPH_MCP_PROXY_FATAL_TOOL="$(jq -r '.tool // ""' <"$op_fatal_tmp")"
      RALPH_MCP_PROXY_FATAL_REASON="$(jq -r '.reason // ""' <"$op_fatal_tmp")"
      RALPH_MCP_PROXY_FATAL_ARGUMENTS="$(jq -r '.arguments // ""' <"$op_fatal_tmp")"
      RALPH_MCP_PROXY_FATAL_CATEGORY="$(jq -r '.category // ""' <"$op_fatal_tmp")"
    fi
    rm -f "$op_fatal_tmp"
    if [[ "$op_timed_out" == "1" ]]; then
      has_timeout_error=1
      report_lines+=("$i. $op_tool: timeout | operation exceeded remaining batch budget (${batch_timeout_sec}s total)")
      rm -f "$op_result_tmp"
      continue
    fi
    op_result="$(<"$op_result_tmp")"
    rm -f "$op_result_tmp"
    completed_ops=$((completed_ops + 1))
    op_is_error="$(jq -r '.isError // false' <<< "$op_result")"
    op_text="$(jq -r '.content[0].text // empty' <<< "$op_result")"
    if jq -e 'type == "object" and has("preview")' <<<"$op_text" >/dev/null 2>&1; then
      op_text="$(jq -r '.preview // empty' <<< "$op_text")"
    fi
    preview="$(ralph_mcp_proxy_batch_preview_line "$op_text")"

    if [[ "${RALPH_MCP_PROXY_FATAL_VIOLATION:-0}" == "1" ]]; then
      op_status="error"
      report_lines+=("$i. $op_tool: $op_status | $preview")
      report="$(printf '%s\n' "${report_lines[@]}")"
      if [[ -n "${RALPH_MCP_PROXY_FATAL_REASON:-}" ]]; then
        report+=$'\n'"FATAL: ${RALPH_MCP_PROXY_FATAL_REASON}"
      fi
      ralph_mcp_proxy_tool_error_json "$report"
      return 0
    fi

    if [[ "$op_is_error" == "true" ]]; then
      op_status="error"
    else
      op_status="ok"
    fi
    report_lines+=("$i. $op_tool: $op_status | $preview")
  done

  report="$(printf '%s\n' "${report_lines[@]}")"
  if [[ "$has_timeout_error" == "1" ]]; then
    report+=$'\n'"PARTIAL_FAILURE: batch timeout (completed $completed_ops/$op_count operations)"
    ralph_mcp_proxy_tool_error_json "$report"
  else
    ralph_mcp_proxy_tool_success_json "$report"
  fi
}

ralph_mcp_proxy_owned_tool_tool_search() {
  local workspace="${1:-}"
  local args_json="${2:-}"
  [[ -n "$args_json" ]] || args_json='{}'
  local action query max_results target_tool target_args rank_script catalog_json
  local ranked_json record args_shape outcome rank_value

  if ! ralph_mcp_proxy_compact_tool_catalog_active; then
    ralph_mcp_proxy_tool_error_json "ralph_proxy_tool_search requires RALPH_MCP_COMPACT_TOOL_CATALOG"
    return 0
  fi

  action="$(jq -r '.action // empty' <<<"$args_json")"
  case "$action" in
    search)
      query="$(jq -r '.query // empty' <<<"$args_json")"
      if [[ -z "$query" ]]; then
        ralph_mcp_proxy_tool_error_json "ralph_proxy_tool_search action=search requires query"
        record="$(ralph_mcp_proxy_tool_catalog_telemetry_record_json "tool_search_search" "" "" "" "invalid_args" "" "" '{}')"
        ralph_mcp_proxy_tool_catalog_telemetry_append "$record"
        return 0
      fi
      max_results="$(jq -r '.maxResults // 10' <<<"$args_json")"
      if [[ ! "$max_results" =~ ^[0-9]+$ ]] || [[ "$max_results" -lt 1 ]]; then
        max_results=10
      fi
      if [[ "$max_results" -gt 50 ]]; then
        max_results=50
      fi
      catalog_json="$(ralph_mcp_proxy_hidden_tools_catalog_json)"
      rank_script="$(ralph_mcp_proxy_tool_search_rank_script)"
      if ! command -v python3 >/dev/null 2>&1 || [[ ! -f "$rank_script" ]]; then
        ralph_mcp_proxy_tool_error_json "ralph_proxy_tool_search ranker unavailable"
        return 0
      fi
      ranked_json="$(jq -c '.' <<<"$catalog_json" | python3 "$rank_script" --query "$query" --max-results "$max_results")"
      record="$(ralph_mcp_proxy_tool_catalog_telemetry_record_json \
        "tool_search_search" "$query" "" "" "ok" "" "" '{}')"
      ralph_mcp_proxy_tool_catalog_telemetry_append "$record"
      ralph_mcp_proxy_tool_success_json "$ranked_json"
      ;;
    invoke)
      target_tool="$(jq -r '.tool // empty' <<<"$args_json")"
      target_args="$(jq -c '.arguments // {}' <<<"$args_json")"
      args_shape="$(ralph_mcp_proxy_tool_search_sanitize_args_json "$target_args")"
      if [[ -z "$target_tool" ]]; then
        ralph_mcp_proxy_tool_error_json "ralph_proxy_tool_search action=invoke requires tool"
        record="$(ralph_mcp_proxy_tool_catalog_telemetry_record_json \
          "tool_search_invoke" "" "" "" "invalid_args" "" "" "$args_shape")"
        ralph_mcp_proxy_tool_catalog_telemetry_append "$record"
        return 0
      fi
      if [[ "$target_tool" == "ralph_proxy_tool_search" ]]; then
        ralph_mcp_proxy_tool_error_json "ralph_proxy_tool_search cannot invoke itself"
        record="$(ralph_mcp_proxy_tool_catalog_telemetry_record_json \
          "tool_search_invoke" "" "$target_tool" "" "recursive_rejected" "" "" "$args_shape")"
        ralph_mcp_proxy_tool_catalog_telemetry_append "$record"
        return 0
      fi
      if ! ralph_mcp_proxy_hidden_tool_catalog_entry "$target_tool"; then
        ralph_mcp_proxy_tool_error_json "ralph_proxy_tool_search: unknown or advertised tool: $target_tool"
        record="$(ralph_mcp_proxy_tool_catalog_telemetry_record_json \
          "tool_search_invoke" "" "$target_tool" "" "unknown_tool" "" "" "$args_shape")"
        ralph_mcp_proxy_tool_catalog_telemetry_append "$record"
        return 0
      fi
      if ! ralph_mcp_proxy_tool_allowed "$target_tool"; then
        ralph_mcp_proxy_tool_error_json "ralph_proxy_tool_search: tool denied by policy: $target_tool"
        record="$(ralph_mcp_proxy_tool_catalog_telemetry_record_json \
          "tool_search_invoke" "" "$target_tool" "" "policy_denied" "" "" "$args_shape")"
        ralph_mcp_proxy_tool_catalog_telemetry_append "$record"
        return 0
      fi
      rank_value="$(jq -r '.rank // empty' <<<"$args_json")"
      if [[ -n "$rank_value" && "$rank_value" =~ ^[0-9]+$ ]]; then
        :
      else
        rank_value=""
      fi
      ralph_mcp_proxy_call_owned_tool "$workspace" "$target_tool" "$target_args"
      outcome="dispatched"
      if [[ "${RALPH_MCP_PROXY_FATAL_VIOLATION:-0}" == "1" ]]; then
        outcome="fatal_violation"
      fi
      record="$(ralph_mcp_proxy_tool_catalog_telemetry_record_json \
        "tool_search_invoke" "" "$target_tool" "$rank_value" "$outcome" "" "" "$args_shape")"
      ralph_mcp_proxy_tool_catalog_telemetry_append "$record"
      ;;
    *)
      ralph_mcp_proxy_tool_error_json "ralph_proxy_tool_search requires action=search or action=invoke"
      record="$(ralph_mcp_proxy_tool_catalog_telemetry_record_json \
        "tool_search" "" "" "" "invalid_action" "" "" '{}')"
      ralph_mcp_proxy_tool_catalog_telemetry_append "$record"
      ;;
  esac
}

ralph_mcp_proxy_call_owned_tool() {
  local workspace="${1:-}"
  local tool_name="${2:-}"
  local args_json; args_json="$(ralph_mcp_proxy_normalize_args_json "${3-}")"

  RALPH_MCP_PROXY_FATAL_VIOLATION=0
  RALPH_MCP_PROXY_FATAL_TOOL=""
  RALPH_MCP_PROXY_FATAL_REASON=""
  RALPH_MCP_PROXY_FATAL_ARGUMENTS=""
  RALPH_MCP_PROXY_FATAL_CATEGORY="boundary"
  RALPH_MCP_PROXY_CURRENT_TOOL="$tool_name"
  RALPH_MCP_PROXY_CURRENT_ARGS_JSON="$args_json"
  export RALPH_MCP_PROXY_CURRENT_TOOL RALPH_MCP_PROXY_CURRENT_ARGS_JSON

  if ralph_mcp_proxy_call_arguments_denied "$tool_name" "$args_json"; then
    ralph_mcp_proxy_signal_fatal_violation \
      "$tool_name" \
      "tool arguments denied by proxy policy: ${RALPH_MCP_PROXY_LAST_DENY_REASON:-denied}" \
      "$args_json" \
      "denied-arguments"
    ralph_mcp_proxy_tool_error_json "${RALPH_MCP_PROXY_FATAL_REASON:-ralph_proxy_tool arguments denied}"
    unset RALPH_MCP_PROXY_CURRENT_TOOL RALPH_MCP_PROXY_CURRENT_ARGS_JSON
    return 0
  fi
  if ! ralph_mcp_proxy_tool_allowed "$tool_name"; then
    ralph_mcp_proxy_signal_fatal_violation \
      "$tool_name" \
      "tool denied by proxy policy: $tool_name" \
      "tool=$tool_name" \
      "boundary"
    ralph_mcp_proxy_tool_error_json "${RALPH_MCP_PROXY_FATAL_REASON:-ralph_proxy_tool denied}"
    unset RALPH_MCP_PROXY_CURRENT_TOOL RALPH_MCP_PROXY_CURRENT_ARGS_JSON
    return 0
  fi

  case "$tool_name" in
    ralph_proxy_read)
      ralph_mcp_proxy_owned_tool_read "$workspace" "$args_json"
      ;;
    ralph_proxy_grep)
      ralph_mcp_proxy_owned_tool_grep "$workspace" "$args_json"
      ;;
    ralph_proxy_search)
      ralph_mcp_proxy_owned_tool_search "$workspace" "$args_json"
      ;;
    ralph_proxy_repomap)
      ralph_mcp_proxy_owned_tool_repomap "$workspace" "$args_json"
      ;;
    ralph_proxy_glob)
      ralph_mcp_proxy_owned_tool_glob "$workspace" "$args_json"
      ;;
    ralph_proxy_shell)
      ralph_mcp_proxy_owned_tool_shell "$workspace" "$args_json"
      ;;
    ralph_proxy_shell_start)
      ralph_mcp_proxy_owned_tool_shell_start "$workspace" "$args_json"
      ;;
    ralph_proxy_shell_wait)
      ralph_mcp_proxy_owned_tool_shell_wait "$workspace" "$args_json"
      ;;
    ralph_proxy_shell_status)
      ralph_mcp_proxy_owned_tool_shell_status "$workspace" "$args_json"
      ;;
    ralph_proxy_shell_read)
      ralph_mcp_proxy_owned_tool_shell_read "$workspace" "$args_json"
      ;;
    ralph_proxy_shell_cancel)
      ralph_mcp_proxy_owned_tool_shell_cancel "$workspace" "$args_json"
      ;;
    ralph_proxy_result_read)
      ralph_mcp_proxy_owned_tool_result_read "$workspace" "$args_json"
      ;;
    ralph_proxy_result_search)
      ralph_mcp_proxy_owned_tool_result_search "$workspace" "$args_json"
      ;;
    ralph_proxy_result_summary)
      ralph_mcp_proxy_owned_tool_result_summary "$workspace" "$args_json"
      ;;
    ralph_proxy_result_reduce)
      ralph_mcp_proxy_owned_tool_result_reduce "$workspace" "$args_json"
      ;;
    ralph_proxy_batch)
      ralph_mcp_proxy_owned_tool_batch "$workspace" "$args_json"
      ;;
    ralph_proxy_tool_search)
      ralph_mcp_proxy_owned_tool_tool_search "$workspace" "$args_json"
      ;;
    ralph_proxy_memory_list)
      ralph_mcp_proxy_owned_tool_memory_list "$workspace" "$args_json"
      ;;
    ralph_proxy_memory_read)
      ralph_mcp_proxy_owned_tool_memory_read "$workspace" "$args_json"
      ;;
    ralph_proxy_memory_write)
      ralph_mcp_proxy_owned_tool_memory_write "$workspace" "$args_json"
      ;;
    ralph_proxy_memory_delete)
      ralph_mcp_proxy_owned_tool_memory_delete "$workspace" "$args_json"
      ;;
    *)
      ralph_mcp_proxy_tool_error_json "unknown Ralph proxy tool: $tool_name"
      ;;
  esac
  unset RALPH_MCP_PROXY_CURRENT_TOOL RALPH_MCP_PROXY_CURRENT_ARGS_JSON
}
