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
  local args_json="${1:-{}}"
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
  local plan_key token_cap_triggered=0

  declare -F ralph_hook_telemetry_append_windowing_log >/dev/null 2>&1 || return 0
  plan_key="$(ralph_mcp_proxy_result_tool_plan_key)"
  if [[ "$byte_cap" =~ ^[0-9]+$ ]] && [[ "$byte_cap" -gt 0 ]] && [[ "$original_bytes" -gt "$byte_cap" ]]; then
    token_cap_triggered=1
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
    "$result_id"
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
  local byte_cap token_cap preview returned_bytes original_bytes result_id plan_key
  local breakpoints_json envelope_json compact_text marker read_window
  local original_tokens="" returned_tokens="" token_args=()

  original_bytes=${#storage_text}
  byte_cap="$(ralph_mcp_proxy_result_byte_cap_for_tool "$tool_name")"
  token_cap="$(ralph_mcp_proxy_result_token_cap_for_tool "$tool_name")"

  local needs_envelope=0
  if [[ "$truncated_flag" == "1" ]]; then
    needs_envelope=1
  elif [[ "$byte_cap" =~ ^[0-9]+$ ]] && [[ "$byte_cap" -gt 0 ]] && [[ "${#preview_text}" -gt "$byte_cap" ]]; then
    needs_envelope=1
  elif [[ "$byte_cap" =~ ^[0-9]+$ ]] && [[ "$byte_cap" -gt 0 ]] && [[ "$original_bytes" -gt "$byte_cap" ]]; then
    needs_envelope=1
  elif [[ "$token_cap" =~ ^[0-9]+$ ]] && [[ "$token_cap" -gt 0 ]] \
    && declare -F ralph_mcp_proxy_result_text_exceeds_token_cap >/dev/null 2>&1 \
    && ralph_mcp_proxy_result_text_exceeds_token_cap "$preview_text" "$token_cap"; then
    needs_envelope=1
  elif [[ "$token_cap" =~ ^[0-9]+$ ]] && [[ "$token_cap" -gt 0 ]] \
    && declare -F ralph_mcp_proxy_result_text_exceeds_token_cap >/dev/null 2>&1 \
    && ralph_mcp_proxy_result_text_exceeds_token_cap "$storage_text" "$token_cap"; then
    needs_envelope=1
  fi

  RALPH_MCP_PROXY_LAST_RESULT_ID=""
  RALPH_MCP_PROXY_LAST_RESULT_NEEDS_ENVELOPE=0
  export RALPH_MCP_PROXY_LAST_RESULT_ID RALPH_MCP_PROXY_LAST_RESULT_NEEDS_ENVELOPE

  if [[ "$needs_envelope" -eq 0 ]]; then
    ralph_mcp_proxy_tool_success_json "$preview_text"
    return 0
  fi

  RALPH_MCP_PROXY_LAST_RESULT_NEEDS_ENVELOPE=1
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
      next_actions_json="$(ralph_mcp_proxy_result_envelope_grep_next_actions_json "$result_id" "$grep_pattern" "$read_window")"
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
  envelope_json="$(ralph_mcp_proxy_result_envelope_build_json "$preview" "$original_bytes" "$returned_bytes" "$result_id" "$breakpoints_json" "$next_actions_json" "true" "${token_args[@]}")" || {
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
  ralph_mcp_proxy_append_windowing_telemetry \
    "$workspace" \
    "$tool_name" \
    "$original_bytes" \
    "$returned_bytes" \
    "$original_tokens" \
    "$returned_tokens" \
    "$byte_cap" \
    "$result_id"
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
      '{autoRanged: $autoRanged, guidance: $guidance}')"
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
  next_actions_json="$(ralph_mcp_proxy_result_envelope_default_next_actions_json "$result_id" "$read_window")"
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
    find "$search_root_abs" \
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

ralph_mcp_proxy_owned_tool_grep_search() {
  local pattern="${1:-}"
  local search_path="${2:-}"
  local glob_filter="${3:-}"
  local output_file="${4:-}"
  local tmp_files relpath abs_path base line

  [[ -n "$pattern" && -n "$search_path" && -n "$output_file" ]] || return 1
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
      printf '%s:%s\n' "${search_path##*/}" "$line"
    done < <(grep -En -- "$pattern" "$search_path" 2>/dev/null || true)
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
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -n "$line" ]] || continue
      printf '%s:%s\n' "$relpath" "$line"
    done < <(grep -En -- "$pattern" "$abs_path" 2>/dev/null || true)
  done <"$tmp_files" >>"$output_file"
  rm -f "$tmp_files"
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

  tmp_out="$(mktemp)"
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
      elif ! rg "${rg_args[@]}" "$pattern" "$search_path" >"$tmp_out" 2>/dev/null; then
        : >"$tmp_out"
      fi
    elif ! rg "${rg_args[@]}" "$pattern" "$search_path" >"$tmp_out" 2>/dev/null; then
      : >"$tmp_out"
    fi
  else
    ralph_mcp_proxy_owned_tool_grep_search "$pattern" "$search_path" "$glob_filter" "$tmp_out"
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

  match_metadata_json="$(ralph_mcp_proxy_result_store_match_metadata_from_grep_output "$full_text" 2>/dev/null || true)"
  if [[ -z "$match_metadata_json" ]]; then
    match_metadata_json='[]'
  fi
  cluster_metadata_json="$(ralph_mcp_proxy_result_store_match_clusters_from_metadata "$match_metadata_json" 2>/dev/null || true)"
  if [[ -z "$cluster_metadata_json" ]]; then
    cluster_metadata_json="$match_metadata_json"
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
    '{"storageLayout":"full"}'

  ralph_mcp_proxy_search_dedupe_store \
    "$cache_key" \
    "$mutation_counter" \
    "$full_text" \
    "$truncated" \
    '{"storageLayout":"full"}' \
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
  while IFS= read -r term; do
    [[ -n "$term" ]] || continue
    terms+=("$term")
  done < <(ralph_mcp_proxy_owned_tool_search_normalize_terms "$query")
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

ralph_mcp_proxy_owned_tool_search_gather_rg() {
  local or_pattern="${1:-}"
  local search_path="${2:-}"
  local glob_filter="${3:-}"
  local max_candidates="${4:-500}"
  local output_file="${5:-}"
  local -a rg_args=()
  local count=0

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
    count=$((count + 1))
    if [[ "$count" -gt "$max_candidates" ]]; then
      break
    fi
    local relpath lineno content
    relpath="${line%%:*}"
    relpath="$(ralph_mcp_proxy_owned_tool_search_relative_path "$search_path" "$relpath")"
    lineno="${line#*:}"
    lineno="${lineno%%:*}"
    content="${line#*:*:}"
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
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -n "$line" ]] || continue
      count=$((count + 1))
      if [[ "$count" -gt "$max_candidates" ]]; then
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
  byte_cap="$(ralph_mcp_proxy_result_byte_cap_for_tool "ralph_proxy_search")"
  if [[ "$candidate_count" -gt "$return_limit" ]]; then
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
    ralph_mcp_proxy_result_read_emit_response "$workspace" "$result_id" "$view" "$text" "$byte_start" "$byte_limit" "$auto_ranged"
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
  ralph_mcp_proxy_result_read_emit_response "$workspace" "$result_id" "$view" "$text" "$byte_start" "$byte_limit" "$auto_ranged"
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

ralph_mcp_proxy_shell_job_kill_tree() {
  local root_pid="${1:-}" current child
  [[ "$root_pid" =~ ^[0-9]+$ ]] || return 0
  while IFS= read -r child; do
    [[ -n "$child" ]] || continue
    ralph_mcp_proxy_shell_job_kill_tree "$child"
  done < <(pgrep -P "$root_pid" 2>/dev/null || true)
  kill -TERM "$root_pid" 2>/dev/null || true
  sleep 0.2
  kill -KILL "$root_pid" 2>/dev/null || true
}

ralph_mcp_proxy_shell_job_finish() {
  local workspace="${1:-}" job_dir="${2:-}" command="${3:-}" timeout_sec="${4:-}" max_shell_bytes="${5:-}" start_epoch="${6:-}" exit_code="${7:-0}"
  local status ended_at ended_epoch stdout stderr combined result_id result_path preview outcome_json metadata_json

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
    --arg startedAt "$(cat "$job_dir/started-at.txt" 2>/dev/null || true)" \
    --arg endedAt "$ended_at" \
    --arg resultId "$result_id" \
    --arg resultPath "$result_path" \
    --arg preview "$preview" \
    --argjson pid "$(cat "$job_dir/pid" 2>/dev/null || echo 0)" \
    --argjson exitCode "$exit_code" \
    --argjson timeoutSeconds "$timeout_sec" \
    --argjson startEpoch "$start_epoch" \
    --argjson elapsedSeconds "$((ended_epoch - start_epoch))" \
    --argjson stdoutBytes "$(wc -c <"$job_dir/stdout.log" 2>/dev/null | tr -d ' ' || echo 0)" \
    --argjson stderrBytes "$(wc -c <"$job_dir/stderr.log" 2>/dev/null | tr -d ' ' || echo 0)" \
    --argjson combinedBytes "$(wc -c <"$job_dir/combined.log" 2>/dev/null | tr -d ' ' || echo 0)" \
    '{jobId:$jobId,status:$status,command:$command,pid:$pid,exitCode:$exitCode,timeoutSeconds:$timeoutSeconds,startedAt:$startedAt,startEpoch:$startEpoch,endedAt:$endedAt,elapsedSeconds:$elapsedSeconds,stdoutBytes:$stdoutBytes,stderrBytes:$stderrBytes,combinedBytes:$combinedBytes,resultId:(if $resultId == "" then null else $resultId end),resultPath:(if $resultPath == "" then null else $resultPath end),preview:$preview}' \
    | ralph_mcp_proxy_shell_job_write_state "$job_dir/state.json"
}

ralph_mcp_proxy_owned_tool_shell_start() {
  local workspace="${1:-}"
  local args_json; args_json="$(ralph_mcp_proxy_normalize_args_json "${2-}")"
  local command original_command timeout_sec max_shell_bytes plan_key job_id job_dir started_at start_epoch pid

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

  plan_key="$(ralph_mcp_proxy_shell_job_plan_key)"
  job_id="$(ralph_mcp_proxy_shell_job_id_new)"
  job_dir="$(ralph_mcp_proxy_shell_job_dir "$workspace" "$plan_key" "$job_id")" || {
    ralph_mcp_proxy_tool_error_json "ralph_proxy_shell_start: invalid job path"
    return 0
  }
  mkdir -p "$job_dir"
  started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  start_epoch="$(date +%s)"
  printf '%s\n' "$started_at" >"$job_dir/started-at.txt"

  jq -nc \
    --arg jobId "$job_id" \
    --arg status "running" \
    --arg command "$command" \
    --arg startedAt "$started_at" \
    --argjson startEpoch "$start_epoch" \
    --argjson timeoutSeconds "$timeout_sec" \
    '{jobId:$jobId,status:$status,command:$command,pid:null,exitCode:null,timeoutSeconds:$timeoutSeconds,startedAt:$startedAt,startEpoch:$startEpoch,endedAt:null,elapsedSeconds:0,stdoutBytes:0,stderrBytes:0,combinedBytes:0,resultId:null,resultPath:null,preview:""}' \
    | ralph_mcp_proxy_shell_job_write_state "$job_dir/state.json"

  (
    set +e
    local _exit=0
    if command -v timeout >/dev/null 2>&1; then
      timeout "$timeout_sec" bash -c "cd \"\$1\" && $command" _ "$workspace" >"$job_dir/stdout.log" 2>"$job_dir/stderr.log"
      _exit=$?
    else
      bash -c "cd \"\$1\" && $command" _ "$workspace" >"$job_dir/stdout.log" 2>"$job_dir/stderr.log"
      _exit=$?
    fi
    ralph_mcp_proxy_shell_job_finish "$workspace" "$job_dir" "$command" "$timeout_sec" "$max_shell_bytes" "$start_epoch" "$_exit"
  ) &
  pid=$!
  disown "$pid" 2>/dev/null || true
  printf '%s\n' "$pid" >"$job_dir/pid"
  jq --argjson pid "$pid" '.pid = $pid' "$job_dir/state.json" | ralph_mcp_proxy_shell_job_write_state "$job_dir/state.json"

  ralph_mcp_proxy_tool_success_json "$(
    jq -c \
      --arg nextWait "ralph_proxy_shell_wait" \
      --arg nextRead "ralph_proxy_shell_read" \
      '. + {nextActions:[{tool:$nextWait,args:{jobId:.jobId}},{tool:$nextRead,args:{jobId:.jobId,stream:"combined",tailBytes:8192}}]}' \
      "$job_dir/state.json"
  )"
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
  local job_dir="${1:-}" args_json="${2:-{}}" tail_bytes state status pid now started_epoch preview stdout_bytes stderr_bytes combined_bytes response_json
  tail_bytes="$(jq -r '.tailBytes // 4096' <<< "$args_json")"
  state="$(cat "$job_dir/state.json")"
  status="$(jq -r '.status // "unknown"' <<< "$state")"
  pid="$(jq -r '.pid // empty' <<< "$state")"
  stdout_bytes="$(wc -c <"$job_dir/stdout.log" 2>/dev/null | tr -d ' ' || echo 0)"
  stderr_bytes="$(wc -c <"$job_dir/stderr.log" 2>/dev/null | tr -d ' ' || echo 0)"
  cat "$job_dir/stdout.log" "$job_dir/stderr.log" 2>/dev/null >"$job_dir/combined.current.log" || true
  combined_bytes="$(wc -c <"$job_dir/combined.current.log" 2>/dev/null | tr -d ' ' || echo 0)"
  preview="$(ralph_mcp_proxy_shell_job_tail_file "$job_dir/combined.current.log" "$tail_bytes")"
  if [[ "$status" == "running" && "$pid" =~ ^[0-9]+$ ]] && ! kill -0 "$pid" 2>/dev/null; then
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
  local args_json job_id plan_key job_dir state pid now started_epoch response_json
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
  if [[ "$pid" =~ ^[0-9]+$ ]]; then
    ralph_mcp_proxy_shell_job_kill_tree "$pid"
  fi
  now="$(date +%s)"
  started_epoch="$(jq -r '.startEpoch // empty' <<< "$state")"
  [[ "$started_epoch" =~ ^[0-9]+$ ]] || started_epoch="$now"
  response_json="$(jq -c \
    --arg status "cancelled" \
    --arg endedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson elapsedSeconds "$((now - started_epoch))" \
    '.status = $status | .endedAt = $endedAt | .elapsedSeconds = $elapsedSeconds' \
    <<< "$state")"
  printf '%s\n' "$response_json" >"$job_dir/state.json"
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

  jq -nc \
    --arg command "$command" \
    --arg timeoutSeconds "$timeout_seconds" \
    --arg handoffMessage "$handoff_message" \
    --arg nextTool "ralph_proxy_shell_start" \
    --arg waitTool "ralph_proxy_shell_wait" \
    --arg readTool "ralph_proxy_shell_read" \
    '{
      shellTimeoutHandoff: true,
      command: $command,
      timeoutSeconds: $timeoutSeconds,
      message: $handoffMessage,
      nextActions: [
        {tool: $nextTool, args: {command: $command}},
        {tool: $waitTool, args: {jobId: "<jobId from start response>", waitSeconds: $timeoutSeconds}},
        {tool: $readTool, args: {jobId: "<jobId from start response>", stream: "combined", tailBytes: 8192}}
      ]
    }'
}

# Returns 0 (true) when the command matches a known verification/build shape
# that is likely to block the synchronous shell for a long time. Patterns:
# npm test, npm run <test|lint|build|check>, yarn/pnpm equivalents,
# package-manager install, make <check|test|docs>, large unbounded find, etc.
# Commands that pass an explicit timeoutSeconds are exempt (the caller signals
# they know the runtime).
ralph_mcp_proxy_shell_is_long_verification_command() {
  local command="${1:-}"
  local args_json="${2:-{}}"

  # Commands with explicit timeoutSeconds are caller-managed; skip the heuristic.
  local req_timeout
  req_timeout="$(jq -r '.timeoutSeconds // empty' <<<"$args_json" 2>/dev/null)"
  if [[ -n "$req_timeout" && "$req_timeout" != "null" && "$req_timeout" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  # Strip leading env assignments and sudo for pattern matching
  local cmd_stripped="$command"
  # Remove leading VAR=val pairs
  while [[ "$cmd_stripped" =~ ^[A-Za-z_][A-Za-z0-9_]*=([^[:space:]]*)[[:space:]]+ ]]; do
    cmd_stripped="${cmd_stripped#*=*[[:space:]]}"
  done
  # Remove leading whitespace
  cmd_stripped="${cmd_stripped#"${cmd_stripped%%[! ]*}"}"

  # npm / yarn / pnpm test, lint, build, check, install, ci, audit
  if [[ "$cmd_stripped" =~ ^(npm|yarn|pnpm)[[:space:]]+(test|install|ci|audit)[[:space:]] ]] || \
     [[ "$cmd_stripped" =~ ^(npm|yarn|pnpm)[[:space:]]+(test|install|ci|audit)$ ]]; then
    return 0
  fi
  if [[ "$cmd_stripped" =~ ^(npm|yarn|pnpm)[[:space:]]+run[[:space:]]+(test|lint|build|check|typecheck|e2e|ci)[[:space:]] ]] || \
     [[ "$cmd_stripped" =~ ^(npm|yarn|pnpm)[[:space:]]+run[[:space:]]+(test|lint|build|check|typecheck|e2e|ci)$ ]]; then
    return 0
  fi

  # make check, make test, make docs, make all, make install
  if [[ "$cmd_stripped" =~ ^make[[:space:]]+(check|test|docs|all|install|build)[[:space:]] ]] || \
     [[ "$cmd_stripped" =~ ^make[[:space:]]+(check|test|docs|all|install|build)$ ]]; then
    return 0
  fi

  # pytest, jest, mocha, cargo test, go test, python -m pytest
  if [[ "$cmd_stripped" =~ ^(pytest|jest|mocha|vitest)[[:space:]] ]] || \
     [[ "$cmd_stripped" =~ ^(pytest|jest|mocha|vitest)$ ]]; then
    return 0
  fi
  if [[ "$cmd_stripped" =~ ^cargo[[:space:]]+(test|build|check)[[:space:]] ]] || \
     [[ "$cmd_stripped" =~ ^cargo[[:space:]]+(test|build|check)$ ]]; then
    return 0
  fi
  if [[ "$cmd_stripped" =~ ^go[[:space:]]+(test|build|vet)[[:space:]] ]] || \
     [[ "$cmd_stripped" =~ ^go[[:space:]]+(test|build|vet)$ ]]; then
    return 0
  fi
  if [[ "$cmd_stripped" =~ ^python[3]?[[:space:]]+-m[[:space:]]+(pytest|unittest)[[:space:]] ]] || \
     [[ "$cmd_stripped" =~ ^python[3]?[[:space:]]+-m[[:space:]]+(pytest|unittest)$ ]]; then
    return 0
  fi

  # Docs checks
  if [[ "$cmd_stripped" =~ ^(bash|sh)[[:space:]].*docs[-_]check ]] || \
     [[ "$cmd_stripped" =~ docs[-_](check|build|generate) ]]; then
    return 0
  fi

  return 1
}

ralph_mcp_proxy_shell_long_verification_guidance_json() {
  local command="${1:-}"
  jq -nc \
    --arg command "$command" \
    --arg startTool "ralph_proxy_shell_start" \
    --arg waitTool "ralph_proxy_shell_wait" \
    --arg readTool "ralph_proxy_shell_read" \
    '{
      syncShellVerificationSteered: true,
      command: $command,
      message: "This command matches a long-running verification or build pattern. Use ralph_proxy_shell_start to run it asynchronously and poll with ralph_proxy_shell_wait, or use runner-owned verify: metadata in the plan so the runner executes it outside the MCP transport. Synchronous ralph_proxy_shell is reserved for short bounded exploratory commands.",
      nextActions: [
        {tool: $startTool, args: {command: $command}},
        {tool: $waitTool, args: {jobId: "<jobId from start response>", waitSeconds: 120}},
        {tool: $readTool, args: {jobId: "<jobId from start response>", stream: "combined", tailBytes: 8192}}
      ]
    }'
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
  local command original_command timeout_sec sync_timeout_sec max_shell_bytes tmp_out tmp_err stdout stderr text exit_code

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

  # Server-side heuristic: detect verification/build commands that are likely to
  # block the synchronous shell long enough to trigger a transport timeout. Return
  # a structured guidance before execution so the agent can switch to async.
  # The hard timeout below is the safety net; this is the early steer.
  if ralph_mcp_proxy_shell_verify_steer_enabled && \
     ralph_mcp_proxy_shell_is_long_verification_command "$command" "$args_json"; then
    local guidance_json
    guidance_json="$(ralph_mcp_proxy_shell_long_verification_guidance_json "$command")"
    ralph_mcp_proxy_log_action "verify-steer" "tool=ralph_proxy_shell command=${command:0:120}"
    ralph_mcp_proxy_tool_success_json "$guidance_json"
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

  local exec_json
  exec_json="$(ralph_native_shell_execute_command_json "$workspace" "$command" "bash" "$execute_timeout")"
  stdout="$(jq -r '.stdout // ""' <<<"$exec_json")"
  stderr="$(jq -r '.stderr // ""' <<<"$exec_json")"
  exit_code="$(jq -r '.exitCode // 0' <<<"$exec_json")"

  # When the transport-safe cap fires (timeout exit code 124), do not return a
  # generic error and do not let the transport close. Return a structured
  # handoff that points the agent at the async job machinery.
  if [[ "$exit_code" -eq 124 ]]; then
    local handoff_json
    handoff_json="$(ralph_mcp_proxy_owned_tool_shell_handoff_json \
      "$command" \
      "$sync_timeout_sec" \
      "Synchronous shell command reached the transport-safe timeout (${sync_timeout_sec}s). Re-issue with ralph_proxy_shell_start, wait with ralph_proxy_shell_wait, or read the result with ralph_proxy_shell_read.")"
    ralph_mcp_proxy_log_action "timeout-handoff" "tool=ralph_proxy_shell cap=${sync_timeout_sec}s command=${command:0:120}"
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
  local has_timeout_error=0

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
    ralph_mcp_proxy_call_owned_tool "$workspace" "$op_tool" "$op_args" >"$op_result_tmp"
    op_result="$(<"$op_result_tmp")"
    rm -f "$op_result_tmp"
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
    report+=$'\n'"PARTIAL_FAILURE: batch timeout (completed $i/$op_count operations)"
    ralph_mcp_proxy_tool_error_json "$report"
  else
    ralph_mcp_proxy_tool_success_json "$report"
  fi
}

ralph_mcp_proxy_owned_tool_tool_search() {
  local workspace="${1:-}"
  local args_json="${2:-{}}"
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
