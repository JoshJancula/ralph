#!/usr/bin/env bash

if [[ -n "${RALPH_MCP_PROXY_POLICY_LOADED:-}" ]]; then
  return
fi
RALPH_MCP_PROXY_POLICY_LOADED=1

RALPH_MCP_POLICY_VIOLATION_EXIT_CODE=${RALPH_MCP_POLICY_VIOLATION_EXIT_CODE:-64}

ralph_mcp_policy_canonicalize_path() {
  local path="$1"
  if [[ -z "$path" ]]; then
    return 1
  fi
  if command -v python3 &>/dev/null; then
    python3 - "$path" <<'PY'
import os, sys
print(os.path.realpath(sys.argv[1]))
PY
    return 0
  fi
  if command -v python &>/dev/null; then
    python - "$path" <<'PY'
import os, sys
print(os.path.realpath(sys.argv[1]))
PY
    return 0
  fi
  if command -v realpath &>/dev/null; then
    realpath "$path"
    return 0
  fi
  (cd "$path" 2>/dev/null && pwd)
}

ralph_mcp_policy_plan_key_safe() {
  local plan_key="${1:-}"
  local sanitized
  sanitized="${plan_key//[^a-zA-Z0-9._-]/_}"
  sanitized="${sanitized//../_}"
  if [[ -z "$sanitized" ]]; then
    sanitized="unknown"
  fi
  printf '%s\n' "$sanitized"
}

ralph_mcp_policy_security_dir() {
  local workspace_root="${RALPH_PLAN_WORKSPACE_ROOT:-}"
  if [[ -z "$workspace_root" ]]; then
    local base_workspace="${WORKSPACE:-$(pwd)}"
    workspace_root="$base_workspace/.ralph-workspace"
  fi
  workspace_root="${workspace_root%/}"
  local security_dir="$workspace_root/security"
  mkdir -p "$security_dir"
  ralph_mcp_policy_canonicalize_path "$security_dir"
}

ralph_mcp_policy_sentinel_path() {
  local plan_key="${1:-${RALPH_PLAN_KEY:-}}"
  plan_key="${plan_key:-unknown}"
  local sanitized
  sanitized="$(ralph_mcp_policy_plan_key_safe "$plan_key")"
  local dir
  dir="$(ralph_mcp_policy_security_dir)" || return 1
  local candidate="$dir/kill-switch.$sanitized.json"
  local canonical
  canonical="$(ralph_mcp_policy_canonicalize_path "$candidate")" || return 1
  case "$canonical" in
    "$dir"|"${dir}"/*)
      printf '%s\n' "$canonical"
      return 0
      ;;
    *)
      printf 'Error: kill-switch path traversal detected for %s\n' "$plan_key" >&2
      return 1
      ;;
  esac
}

ralph_mcp_policy_argument_summary() {
  local args="${1:-}"
  local summary
  summary="$(printf '%s' "$args" | tr '\n' ' ' | tr -s ' ' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | cut -c1-160)"
  if [[ -z "$summary" ]]; then
    summary="(redacted)"
  fi
  printf '%s\n' "$summary"
}

ralph_mcp_policy_argument_hash() {
  local args="${1:-}"
  if [[ -z "$args" ]]; then
    printf ''
    return 0
  fi
  if command -v python3 &>/dev/null; then
    python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())' "$args"
    return 0
  fi
  if command -v python &>/dev/null; then
    python -c 'import hashlib, sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())' "$args"
    return 0
  fi
  if command -v sha256sum &>/dev/null; then
    printf '%s' "$args" | sha256sum | awk '{print $1}'
    return 0
  fi
  if command -v shasum &>/dev/null; then
    printf '%s' "$args" | shasum -a 256 | awk '{print $1}'
    return 0
  fi
  if command -v openssl &>/dev/null; then
    printf '%s' "$args" | openssl dgst -sha256 | awk '{print $NF}'
    return 0
  fi
  printf ''
}

ralph_mcp_policy_write_kill_switch_sentinel() {
  local tool="${1:-unknown}"
  local category="${2:-policy}"
  local reason="${3:-violation}"
  local arguments="${4:-}"
  local plan_key="${RALPH_PLAN_KEY:-unknown}"
  local sentinel_path
  sentinel_path="$(ralph_mcp_policy_sentinel_path "$plan_key")" || return 1
  local timestamp
  timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  local project_root="${RALPH_PROJECT_ROOT:-${WORKSPACE:-}}"
  local agent_workspace="${RALPH_AGENT_WORKSPACE:-${project_root}}"
  local plan_workspace_root="${RALPH_PLAN_WORKSPACE_ROOT:-${project_root}/.ralph-workspace}"
  local summary
  local hash
  summary="$(ralph_mcp_policy_argument_summary "$arguments")"
  hash="$(ralph_mcp_policy_argument_hash "$arguments")"
  jq -n \
    --arg timestamp "$timestamp" \
    --arg project_root "$project_root" \
    --arg agent_workspace "$agent_workspace" \
    --arg plan_workspace_root "$plan_workspace_root" \
    --arg plan_key "$plan_key" \
    --arg tool "$tool" \
    --arg category "$category" \
    --arg reason "$reason" \
    --arg summary "$summary" \
    --arg hash "$hash" \
    '{
      timestamp: $timestamp,
      project_root: $project_root,
      agent_workspace: $agent_workspace,
      plan_workspace_root: $plan_workspace_root,
      workspace: $project_root,
      plan_key: $plan_key,
      tool: $tool,
      category: $category,
      reason: $reason,
      arguments: {
        summary: $summary,
        hash: $hash
      }
    }' > "$sentinel_path"
}

ralph_mcp_policy_violation_fatal() {
  local tool="${1:-unknown}"
  local category="${2:-policy}"
  local reason="${3:-violation}"
  local arguments="${4:-}"
  ralph_mcp_policy_write_kill_switch_sentinel "$tool" "$category" "$reason" "$arguments"
  return "$RALPH_MCP_POLICY_VIOLATION_EXIT_CODE"
}

ralph_mcp_policy_operator_approval_channel_available() {
  if [[ "${RALPH_AGENT_TOOL_ACCESS:-native}" != "ralph" ]]; then
    return 1
  fi
  if [[ "${RALPH_RUN_PLAN_ACTIVE:-0}" != "1" ]]; then
    return 1
  fi
  if [[ -z "${RALPH_PLAN_KEY:-}" || -z "${RALPH_PLAN_WORKSPACE_ROOT:-}" ]]; then
    return 1
  fi
  return 0
}

ralph_mcp_policy_violation_mode_effective() {
  local configured="${RALPH_MCP_POLICY_VIOLATION_MODE:-}"
  local mode="$configured"

  if [[ -z "$mode" ]]; then
    if ralph_mcp_policy_operator_approval_channel_available; then
      mode="approve"
    else
      mode="fatal"
    fi
  fi

  case "$mode" in
    approve)
      if ralph_mcp_policy_operator_approval_channel_available; then
        printf 'approve'
      else
        printf 'fatal'
      fi
      ;;
    error|fatal)
      printf '%s' "$mode"
      ;;
    *)
      printf 'fatal'
      ;;
  esac
}

ralph_mcp_proxy_policy_example_path() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  printf '%s\n' "$script_dir/../mcp-proxy-policy.example.json"
}

ralph_mcp_proxy_json_array_or_empty() {
  local json="${1:-[]}"
  jq -c 'if type == "array" then . else [] end' <<< "$json"
}

ralph_mcp_proxy_policy_validate_json() {
  local policy_json="${1:-}"
  local policy_source="${2:-policy}"

  if ! jq -e '
    def is_nonempty_string:
      type == "string" and length > 0;
    def is_string_array:
      type == "array" and all(.[]?; is_nonempty_string);
    def is_result_cap_map:
      type == "object" and all(to_entries[]?;
        (.key | is_nonempty_string)
        and ((.value | tostring) | test("^[0-9]+$"))
      );
    def is_denied_argument_pattern:
      type == "object"
      and (.tool? == null or (.tool | is_nonempty_string))
      and (.argument? == null or (.argument | is_nonempty_string))
      and (.pattern? == null or (.pattern | is_nonempty_string))
      and (.mode? == null or (.mode | is_nonempty_string))
      and (.description? == null or (.description | is_nonempty_string));
    def is_upstream:
      type == "object"
      and (.name? == null or (.name | is_nonempty_string))
      and (.type? == null or (.type | is_nonempty_string))
      and (.command? == null or (.command | is_nonempty_string))
      and (.args? == null or (.args | is_string_array))
      and (.env? == null or (.env | type == "object"));
    def is_cache_rules:
      type == "object"
      and (.enabled? == null or (.enabled | type == "boolean"))
      and (.readOnly? == null or (.readOnly | type == "boolean"))
      and (.rules? == null or (.rules | type == "array"));
    def is_logging_rules:
      type == "object"
      and (.requests? == null or (.requests | type == "boolean"))
      and (.responses? == null or (.responses | type == "boolean"))
      and (.upstreams? == null or (.upstreams | type == "boolean"))
      and (.enabled? == null or (.enabled | type == "boolean"));
    def is_proxy_owned_tools:
      type == "object"
      and (.enabled? == null or (.enabled | type == "boolean"))
      and (.maxReadBytes? == null or ((.maxReadBytes | tostring) | test("^[0-9]+$")))
      and (.maxReadLines? == null or ((.maxReadLines | tostring) | test("^[0-9]+$")))
      and (.maxGrepMatches? == null or ((.maxGrepMatches | tostring) | test("^[0-9]+$")))
      and (.maxGlobResults? == null or ((.maxGlobResults | tostring) | test("^[0-9]+$")))
      and (.maxShellOutputBytes? == null or ((.maxShellOutputBytes | tostring) | test("^[0-9]+$")))
      and (.shellTimeoutSeconds? == null or ((.shellTimeoutSeconds | tostring) | test("^[0-9]+$")))
      and (.shellAllowlist? == null or (.shellAllowlist | is_string_array))
      and (.allowAllCommands? == null or (.allowAllCommands | type == "boolean"))
      and (.allowShellOperators? == null or (.allowShellOperators | type == "boolean"))
      and (.searchEnabled? == null or (.searchEnabled | type == "boolean"))
      and (.repoMapEnabled? == null or (.repoMapEnabled | type == "boolean"))
      and (.maxSearchCandidates? == null or ((.maxSearchCandidates | tostring) | test("^[0-9]+$")))
      and (.maxSearchResults? == null or ((.maxSearchResults | tostring) | test("^[0-9]+$")))
      and (.maxRepoMapFiles? == null or ((.maxRepoMapFiles | tostring) | test("^[0-9]+$")));
    def is_policy_fields:
      type == "object"
      and (.name? == null or (.name | is_nonempty_string))
      and (.toolAllowlist? == null or (.toolAllowlist | is_string_array))
      and (.toolDenylist? == null or (.toolDenylist | is_string_array))
      and (.deniedArgumentPatterns? == null or (.deniedArgumentPatterns | type == "array" and all(.[]?; is_denied_argument_pattern)))
      and (.resultByteCap? == null or ((.resultByteCap | tostring) | test("^[0-9]+$")))
      and (.toolResultByteCaps? == null or (.toolResultByteCaps | is_result_cap_map))
      and (.resultTokenCap? == null or ((.resultTokenCap | tostring) | test("^[0-9]+$")))
      and (.toolResultTokenCaps? == null or (.toolResultTokenCaps | is_result_cap_map))
      and (.cache? == null or (.cache | is_cache_rules))
      and (.upstreams? == null or (.upstreams | type == "array" and all(.[]?; is_upstream)))
      and (.logging? == null or (.logging | is_logging_rules))
      and (.proxyOwnedTools? == null or (.proxyOwnedTools | is_proxy_owned_tools))
      and (.truncationMarker? == null or (.truncationMarker | is_nonempty_string));
    def is_policy_document:
      is_policy_fields
      and (.policies? == null or (.policies | type == "object" and all(to_entries[]?; (.key | is_nonempty_string) and (.value | is_policy_fields))));
    type == "object" and is_policy_document
  ' <<< "$policy_json" >/dev/null 2>&1; then
    printf 'Error: proxy policy %s failed schema validation.\n' "$policy_source" >&2
    return 1
  fi
}

ralph_mcp_proxy_policy_read_source_json() {
  local workspace="${1:-}"
  local upstream_script="${2:-}"
  local requested_name="${3:-}"
  local raw_policy_json=""
  local policy_source="default"

  if [[ -z "$workspace" ]]; then
    printf 'Error: workspace is required for proxy policy loading.\n' >&2
    return 1
  fi
  if [[ -z "$upstream_script" ]]; then
    printf 'Error: upstream script is required for proxy policy loading.\n' >&2
    return 1
  fi

  if [[ -n "${RALPH_MCP_PROXY_POLICY_INLINE:-}" ]]; then
    raw_policy_json="${RALPH_MCP_PROXY_POLICY_INLINE}"
    policy_source="inline"
  elif [[ -n "${RALPH_MCP_PROXY_POLICY_FILE:-}" ]]; then
    if [[ ! -f "$RALPH_MCP_PROXY_POLICY_FILE" ]]; then
      printf 'Error: proxy policy file not found: %s\n' "$RALPH_MCP_PROXY_POLICY_FILE" >&2
      return 1
    fi
    raw_policy_json="$(<"$RALPH_MCP_PROXY_POLICY_FILE")"
    policy_source="file:${RALPH_MCP_PROXY_POLICY_FILE}"
  fi

  if [[ -n "$raw_policy_json" ]]; then
    if ! jq -e . >/dev/null 2>&1 <<< "$raw_policy_json"; then
      printf 'Error: proxy policy source is not valid JSON (%s).\n' "$policy_source" >&2
      return 1
    fi
    if ! ralph_mcp_proxy_policy_validate_json "$raw_policy_json" "$policy_source"; then
      return 1
    fi
  fi

  RALPH_MCP_PROXY_POLICY_SOURCE="$policy_source"
  RALPH_MCP_PROXY_POLICY_RAW_JSON="$raw_policy_json"
  export RALPH_MCP_PROXY_POLICY_SOURCE
  export RALPH_MCP_PROXY_POLICY_RAW_JSON
}

ralph_mcp_proxy_policy_select_json() {
  local policy_document_json="${1:-}"
  local requested_name="${2:-}"
  local workspace="${3:-}"
  local upstream_script="${4:-}"

  jq -c \
    --arg requested_name "$requested_name" \
    --arg workspace "$workspace" \
    --arg upstream_script "$upstream_script" \
    'def normalize:
       .name = (.name // (if $requested_name != "" then $requested_name else "default" end))
       | .toolAllowlist = ((.toolAllowlist // .tools.allowlist // .tools.allow // []) | if type == "array" then . else [] end)
       | .toolDenylist = ((.toolDenylist // .tools.denylist // .tools.deny // []) | if type == "array" then . else [] end)
       | .deniedArgumentPatterns = ((.deniedArgumentPatterns // .arguments.denyPatterns // []) | if type == "array" then . else [] end)
       | .resultByteCap = (.resultByteCap // .toolResultByteCap // .tools.resultByteCap // .tools.maxResultBytes // 0)
       | .toolResultByteCaps = ((.toolResultByteCaps // {}) | if type == "object" then . else {} end)
       | .resultTokenCap = (.resultTokenCap // .toolResultTokenCap // .tools.resultTokenCap // 0)
       | .toolResultTokenCaps = ((.toolResultTokenCaps // {}) | if type == "object" then . else {} end)
       | .cache = (.cache // {enabled: false, readOnly: false, rules: []})
       | .upstreams = ((.upstreams // [
           {
             name: "ralph",
             type: "wrapped-upstream",
             command: "bash",
             args: [$upstream_script],
             env: {RALPH_MCP_WORKSPACE: $workspace}
           }
         ]) | if type == "array" then . else [] end)
       | .logging = (.logging // {requests: true, responses: true, upstreams: true});
     if ($requested_name != "" and .policies? and .policies[$requested_name]?) then
       .policies[$requested_name] | normalize
     else
       normalize
     end' <<< "$policy_document_json"
}

# The out-of-the-box default is intentionally permissive: ralph_proxy_shell allows
# any command and shell operators with a generous timeout, because the proxy's job
# is to BOUND output (byte caps + stored-result envelopes), not to sandbox a trusted
# local dev loop. The kill-switch and blocking machinery stay intact -- they still
# fire on real tripwires (tool denylists, deniedArgumentPatterns, path traversal).
# Tighten this by supplying your own policy via RALPH_MCP_PROXY_POLICY_FILE /
# RALPH_MCP_PROXY_POLICY_INLINE (e.g. set proxyOwnedTools.allowAllCommands=false with
# a shellAllowlist). See bundle/.ralph/mcp-proxy-policy.example.json.
ralph_mcp_proxy_default_policy_json() {
  local workspace="${1:-}"
  local upstream_script="${2:-}"
  local policy_name="${3:-default}"
  jq -n \
    --arg name "$policy_name" \
    --arg workspace "$workspace" \
    --arg upstream_script "$upstream_script" \
    '{
      name: $name,
      resultByteCap: 16384,
      toolResultByteCaps: {
        ralph_proxy_read: 16384,
        ralph_proxy_grep: 16384,
        ralph_proxy_glob: 16384,
        ralph_proxy_shell: 8192,
        ralph_proxy_result_read: 16384,
        ralph_proxy_result_search: 16384,
        ralph_proxy_result_summary: 4096,
        ralph_proxy_result_reduce: 16384,
        ralph_proxy_search: 16384,
        ralph_proxy_repomap: 16384,
        "resources/read": 16384
      },
      proxyOwnedTools: {
        enabled: true,
        searchEnabled: false,
        repoMapEnabled: false,
        maxReadBytes: 32768,
        maxReadLines: 250,
        maxGrepMatches: 50,
        maxGlobResults: 100,
        maxSearchCandidates: 500,
        maxSearchResults: 50,
        maxRepoMapFiles: 500,
        maxShellOutputBytes: 8192,
        shellTimeoutSeconds: 600,
        allowAllCommands: true,
        allowShellOperators: true
      },
      upstreams: [
        {
          name: "ralph",
          type: "wrapped-upstream",
          command: "bash",
          args: [$upstream_script],
          env: {
            RALPH_MCP_WORKSPACE: $workspace
          }
        }
      ],
      cache: {
        enabled: true,
        readOnly: true,
        rules: []
      },
      logging: {
        requests: true,
        responses: true,
        upstreams: true
      }
    }'
}

ralph_mcp_proxy_load_policy() {
  local workspace="${1:-}"
  local upstream_script="${2:-}"
  local requested_name="${RALPH_MCP_PROXY_POLICY:-}"
  local raw_policy_json selected_json

  if ! ralph_mcp_proxy_policy_read_source_json "$workspace" "$upstream_script" "$requested_name"; then
    return 1
  fi
  raw_policy_json="${RALPH_MCP_PROXY_POLICY_RAW_JSON:-}"

  if [[ -n "$raw_policy_json" ]]; then
    if ! selected_json="$(ralph_mcp_proxy_policy_select_json "$raw_policy_json" "$requested_name" "$workspace" "$upstream_script")"; then
      printf 'Error: proxy policy selection failed.\n' >&2
      return 1
    fi
  else
    selected_json="$(ralph_mcp_proxy_default_policy_json "$workspace" "$upstream_script" "${requested_name:-default}")"
  fi

  if ! ralph_mcp_proxy_policy_validate_json "$selected_json" "selected policy"; then
    return 1
  fi

  RALPH_MCP_PROXY_POLICY_JSON="$selected_json"
  RALPH_MCP_PROXY_POLICY_NAME="$(jq -r '.name // "default"' <<< "$selected_json")"
  RALPH_MCP_PROXY_POLICY_UPSTREAM_SCRIPT="$upstream_script"
  ralph_mcp_proxy_log_action "policy" "selected source=${RALPH_MCP_PROXY_POLICY_SOURCE} name=${RALPH_MCP_PROXY_POLICY_NAME}"
  ralph_mcp_proxy_log_action "upstream" "registered name=ralph script=$upstream_script workspace=$workspace"

  RALPH_MCP_PROXY_POLICY_TOOL_ALLOWLIST_JSON="$(
    jq -c '(.toolAllowlist // .tools.allowlist // .tools.allow // []) | if type == "array" then . else [] end' <<< "$selected_json"
  )"
  RALPH_MCP_PROXY_POLICY_TOOL_DENYLIST_JSON="$(
    jq -c '(.toolDenylist // .tools.denylist // .tools.deny // []) | if type == "array" then . else [] end' <<< "$selected_json"
  )"
  RALPH_MCP_PROXY_POLICY_DENIED_ARGUMENT_PATTERNS_JSON="$(
    jq -c '(.deniedArgumentPatterns // .arguments.denyPatterns // []) | if type == "array" then . else [] end' <<< "$selected_json"
  )"
  RALPH_MCP_PROXY_POLICY_RESULT_BYTE_CAP="$(
    jq -r '(
      .resultByteCap //
      .toolResultByteCap //
      .tools.resultByteCap //
      .tools.maxResultBytes //
      0
    ) | tonumber? // 0' <<< "$selected_json"
  )"
  RALPH_MCP_PROXY_POLICY_TOOL_RESULT_BYTE_CAPS_JSON="$(
    jq -c '(.toolResultByteCaps // {}) | if type == "object" then . else {} end' <<< "$selected_json"
  )"
  RALPH_MCP_PROXY_POLICY_RESULT_TOKEN_CAP="$(
    jq -r '(
      .resultTokenCap //
      .toolResultTokenCap //
      .tools.resultTokenCap //
      0
    ) | tonumber? // 0' <<< "$selected_json"
  )"
  RALPH_MCP_PROXY_POLICY_TOOL_RESULT_TOKEN_CAPS_JSON="$(
    jq -c '(.toolResultTokenCaps // {}) | if type == "object" then . else {} end' <<< "$selected_json"
  )"
  RALPH_MCP_PROXY_POLICY_CACHE_ENABLED="$(
    jq -r 'if .cache.enabled then 1 else 0 end' <<< "$selected_json"
  )"
  RALPH_MCP_PROXY_POLICY_CACHE_READ_ONLY="$(
    jq -r 'if .cache.readOnly then 1 else 0 end' <<< "$selected_json"
  )"
  RALPH_MCP_PROXY_POLICY_CACHE_RULES_JSON="$(
    jq -c '(.cache.rules // []) | if type == "array" then . else [] end' <<< "$selected_json"
  )"
  RALPH_MCP_PROXY_POLICY_TRUNCATION_MARKER="$(
    jq -r '(.truncationMarker // "...[truncated]") | if type == "string" and length > 0 then . else "...[truncated]" end' <<< "$selected_json"
  )"
  RALPH_MCP_PROXY_POLICY_DESCRIPTION_BYTE_CAP="$(
    jq -r '(
      .toolDescriptionByteCap //
      .tools.descriptionByteCap //
      .tools.maxDescriptionBytes //
      0
    ) | tonumber? // 0' <<< "$selected_json"
  )"
  RALPH_MCP_PROXY_POLICY_LOG_REQUESTS="$(
    jq -r 'if .logging.requests then 1 else 0 end' <<< "$selected_json"
  )"
  RALPH_MCP_PROXY_POLICY_LOG_RESPONSES="$(
    jq -r 'if .logging.responses then 1 else 0 end' <<< "$selected_json"
  )"
  RALPH_MCP_PROXY_POLICY_LOG_UPSTREAMS="$(
    jq -r 'if .logging.upstreams then 1 else 0 end' <<< "$selected_json"
  )"
  RALPH_MCP_PROXY_POLICY_OWNED_TOOLS_ENABLED="$(
    jq -r 'if (.proxyOwnedTools.enabled // false) then 1 else 0 end' <<< "$selected_json"
  )"
  RALPH_MCP_PROXY_POLICY_OWNED_MAX_READ_BYTES="$(
    jq -r '(.proxyOwnedTools.maxReadBytes // 65536) | tonumber? // 65536' <<< "$selected_json"
  )"
  RALPH_MCP_PROXY_POLICY_OWNED_MAX_READ_LINES="$(
    jq -r '(.proxyOwnedTools.maxReadLines // 500) | tonumber? // 500' <<< "$selected_json"
  )"
  RALPH_MCP_PROXY_POLICY_OWNED_MAX_GREP_MATCHES="$(
    jq -r '(.proxyOwnedTools.maxGrepMatches // 100) | tonumber? // 100' <<< "$selected_json"
  )"
  RALPH_MCP_PROXY_POLICY_OWNED_MAX_GLOB_RESULTS="$(
    jq -r '(.proxyOwnedTools.maxGlobResults // 200) | tonumber? // 200' <<< "$selected_json"
  )"
  RALPH_MCP_PROXY_POLICY_OWNED_MAX_SHELL_BYTES="$(
    jq -r '(.proxyOwnedTools.maxShellOutputBytes // 32768) | tonumber? // 32768' <<< "$selected_json"
  )"
  RALPH_MCP_PROXY_POLICY_OWNED_SHELL_TIMEOUT="$(
    jq -r '(.proxyOwnedTools.shellTimeoutSeconds // 10) | tonumber? // 10' <<< "$selected_json"
  )"
  RALPH_MCP_PROXY_POLICY_OWNED_SHELL_ALLOWLIST_JSON="$(
    jq -c '
      (.proxyOwnedTools.shellAllowlist // [
        "git status",
        "git diff",
        "git log -5 --oneline",
        "ls",
        "pwd"
      ]) | if type == "array" then . else [] end
    ' <<< "$selected_json"
  )"
  RALPH_MCP_PROXY_POLICY_OWNED_ALLOW_ALL_COMMANDS="$(
    jq -r 'if (.proxyOwnedTools.allowAllCommands // false) then 1 else 0 end' <<< "$selected_json"
  )"
  RALPH_MCP_PROXY_POLICY_OWNED_ALLOW_SHELL_OPERATORS="$(
    jq -r 'if (.proxyOwnedTools.allowShellOperators // false) then 1 else 0 end' <<< "$selected_json"
  )"
  RALPH_MCP_PROXY_POLICY_OWNED_SEARCH_ENABLED="$(
    jq -r 'if (.proxyOwnedTools.searchEnabled // false) then 1 else 0 end' <<< "$selected_json"
  )"
  RALPH_MCP_PROXY_POLICY_OWNED_REPOMAP_ENABLED="$(
    jq -r 'if (.proxyOwnedTools.repoMapEnabled // false) then 1 else 0 end' <<< "$selected_json"
  )"
  RALPH_MCP_PROXY_POLICY_OWNED_MAX_SEARCH_CANDIDATES="$(
    jq -r '(.proxyOwnedTools.maxSearchCandidates // 500) | tonumber? // 500' <<< "$selected_json"
  )"
  RALPH_MCP_PROXY_POLICY_OWNED_MAX_SEARCH_RESULTS="$(
    jq -r '(.proxyOwnedTools.maxSearchResults // 50) | tonumber? // 50' <<< "$selected_json"
  )"
  RALPH_MCP_PROXY_POLICY_OWNED_MAX_REPOMAP_FILES="$(
    jq -r '(.proxyOwnedTools.maxRepoMapFiles // 500) | tonumber? // 500' <<< "$selected_json"
  )"

  export RALPH_MCP_PROXY_POLICY_SOURCE
  export RALPH_MCP_PROXY_POLICY_JSON
  export RALPH_MCP_PROXY_POLICY_NAME
  export RALPH_MCP_PROXY_POLICY_UPSTREAM_SCRIPT
  export RALPH_MCP_PROXY_POLICY_TOOL_ALLOWLIST_JSON
  export RALPH_MCP_PROXY_POLICY_TOOL_DENYLIST_JSON
  export RALPH_MCP_PROXY_POLICY_DENIED_ARGUMENT_PATTERNS_JSON
  export RALPH_MCP_PROXY_POLICY_RESULT_BYTE_CAP
  export RALPH_MCP_PROXY_POLICY_TOOL_RESULT_BYTE_CAPS_JSON
  export RALPH_MCP_PROXY_POLICY_RESULT_TOKEN_CAP
  export RALPH_MCP_PROXY_POLICY_TOOL_RESULT_TOKEN_CAPS_JSON
  export RALPH_MCP_PROXY_POLICY_CACHE_ENABLED
  export RALPH_MCP_PROXY_POLICY_CACHE_READ_ONLY
  export RALPH_MCP_PROXY_POLICY_CACHE_RULES_JSON
  export RALPH_MCP_PROXY_POLICY_TRUNCATION_MARKER
  export RALPH_MCP_PROXY_POLICY_DESCRIPTION_BYTE_CAP
  export RALPH_MCP_PROXY_POLICY_LOG_REQUESTS
  export RALPH_MCP_PROXY_POLICY_LOG_RESPONSES
  export RALPH_MCP_PROXY_POLICY_LOG_UPSTREAMS
  export RALPH_MCP_PROXY_POLICY_OWNED_TOOLS_ENABLED
  export RALPH_MCP_PROXY_POLICY_OWNED_MAX_READ_BYTES
  export RALPH_MCP_PROXY_POLICY_OWNED_MAX_READ_LINES
  export RALPH_MCP_PROXY_POLICY_OWNED_MAX_GREP_MATCHES
  export RALPH_MCP_PROXY_POLICY_OWNED_MAX_GLOB_RESULTS
  export RALPH_MCP_PROXY_POLICY_OWNED_MAX_SHELL_BYTES
  export RALPH_MCP_PROXY_POLICY_OWNED_SHELL_TIMEOUT
  export RALPH_MCP_PROXY_POLICY_OWNED_SHELL_ALLOWLIST_JSON
  export RALPH_MCP_PROXY_POLICY_OWNED_ALLOW_ALL_COMMANDS
  export RALPH_MCP_PROXY_POLICY_OWNED_ALLOW_SHELL_OPERATORS
  export RALPH_MCP_PROXY_POLICY_OWNED_SEARCH_ENABLED
  export RALPH_MCP_PROXY_POLICY_OWNED_REPOMAP_ENABLED
  export RALPH_MCP_PROXY_POLICY_OWNED_MAX_SEARCH_CANDIDATES
  export RALPH_MCP_PROXY_POLICY_OWNED_MAX_SEARCH_RESULTS
  export RALPH_MCP_PROXY_POLICY_OWNED_MAX_REPOMAP_FILES
}

ralph_mcp_proxy_tool_allowed() {
  local tool_name="${1:-}"
  local allowlist_json="${RALPH_MCP_PROXY_POLICY_TOOL_ALLOWLIST_JSON:-[]}"
  local denylist_json="${RALPH_MCP_PROXY_POLICY_TOOL_DENYLIST_JSON:-[]}"
  if [[ -z "$tool_name" ]]; then
    return 1
  fi
  if jq -e --arg name "$tool_name" '. | index($name) != null' <<< "$denylist_json" >/dev/null 2>&1; then
    return 1
  fi
  if declare -F ralph_mcp_proxy_is_result_tool >/dev/null 2>&1; then
    if ralph_mcp_proxy_is_result_tool "$tool_name"; then
      return 0
    fi
  fi
  if declare -F ralph_mcp_proxy_is_owned_tool >/dev/null 2>&1 \
    && declare -F ralph_mcp_proxy_owned_tools_active >/dev/null 2>&1; then
    if ralph_mcp_proxy_is_owned_tool "$tool_name" && ralph_mcp_proxy_owned_tools_active; then
      return 0
    fi
  fi
  if [[ "$(jq -r 'length' <<< "$allowlist_json")" -gt 0 ]]; then
    jq -e --arg name "$tool_name" '. | index($name) != null' <<< "$allowlist_json" >/dev/null 2>&1
    return $?
  fi
  return 0
}

# Grep source-cap absolute ceilings (PLAN15). These are never exceeded
# regardless of policy/env overrides or a derived working cap; they exist to
# make an unbounded multi-megabyte source capture structurally impossible.
RALPH_MCP_PROXY_GREP_SOURCE_BYTE_CAP_CEILING=4194304
RALPH_MCP_PROXY_GREP_SOURCE_LINE_CAP_CEILING=20000
RALPH_MCP_PROXY_GREP_SOURCE_PER_LINE_BYTE_CAP_CEILING=65536

# Selected defaults (see .ralph-workspace/artifacts/*/grep-source-cap-candidates.md).
RALPH_MCP_PROXY_GREP_SOURCE_BYTE_CAP_DEFAULT=262144
RALPH_MCP_PROXY_GREP_SOURCE_LINE_CAP_DEFAULT=2000
RALPH_MCP_PROXY_GREP_SOURCE_PER_LINE_BYTE_CAP_DEFAULT=4096

# Clamps $2 to [1, $3]. Falls back to $1 (the default) when $2 is empty,
# non-numeric, zero, or negative. Pure: no side effects, no env reads.
ralph_mcp_proxy_grep_source_cap_clamp() {
  local default_value="${1:-0}" candidate="${2:-}" ceiling="${3:-0}"
  if [[ ! "$candidate" =~ ^[0-9]+$ ]] || [[ "$candidate" -le 0 ]]; then
    candidate="$default_value"
  fi
  if [[ "$candidate" -gt "$ceiling" ]]; then
    candidate="$ceiling"
  fi
  if [[ "$candidate" -le 0 ]]; then
    candidate="$ceiling"
  fi
  printf '%s\n' "$candidate"
}

# Resolves grep source byte/line/per-line caps as a JSON object
# {"byteCap":N,"lineCap":N,"perLineCap":N}. Pure given its inputs/env: same
# arguments and environment always produce the same result.
#
# Args: optional result_byte_cap (used only to raise the byte cap floor when
# the result cap legitimately needs more room; still clamped to the ceiling).
#
# Overrides (each independently optional, invalid values are ignored):
#   RALPH_MCP_PROXY_POLICY_OWNED_GREP_SOURCE_BYTE_CAP
#   RALPH_MCP_PROXY_POLICY_OWNED_GREP_SOURCE_LINE_CAP
#   RALPH_MCP_PROXY_POLICY_OWNED_GREP_SOURCE_PER_LINE_BYTE_CAP
ralph_mcp_proxy_grep_source_cap_policy_json() {
  local result_byte_cap="${1:-}"
  local byte_cap line_cap per_line_cap byte_floor

  byte_floor="$RALPH_MCP_PROXY_GREP_SOURCE_BYTE_CAP_DEFAULT"
  if [[ "$result_byte_cap" =~ ^[0-9]+$ ]] && [[ "$result_byte_cap" -gt "$byte_floor" ]]; then
    byte_floor="$result_byte_cap"
  fi

  byte_cap="$(ralph_mcp_proxy_grep_source_cap_clamp \
    "$byte_floor" \
    "${RALPH_MCP_PROXY_POLICY_OWNED_GREP_SOURCE_BYTE_CAP:-}" \
    "$RALPH_MCP_PROXY_GREP_SOURCE_BYTE_CAP_CEILING")"
  line_cap="$(ralph_mcp_proxy_grep_source_cap_clamp \
    "$RALPH_MCP_PROXY_GREP_SOURCE_LINE_CAP_DEFAULT" \
    "${RALPH_MCP_PROXY_POLICY_OWNED_GREP_SOURCE_LINE_CAP:-}" \
    "$RALPH_MCP_PROXY_GREP_SOURCE_LINE_CAP_CEILING")"
  per_line_cap="$(ralph_mcp_proxy_grep_source_cap_clamp \
    "$RALPH_MCP_PROXY_GREP_SOURCE_PER_LINE_BYTE_CAP_DEFAULT" \
    "${RALPH_MCP_PROXY_POLICY_OWNED_GREP_SOURCE_PER_LINE_BYTE_CAP:-}" \
    "$RALPH_MCP_PROXY_GREP_SOURCE_PER_LINE_BYTE_CAP_CEILING")"

  jq -nc \
    --argjson byteCap "$byte_cap" \
    --argjson lineCap "$line_cap" \
    --argjson perLineCap "$per_line_cap" \
    '{byteCap: $byteCap, lineCap: $lineCap, perLineCap: $perLineCap}'
}

ralph_mcp_proxy_result_byte_cap_for_tool() {
  local tool_name="${1:-}"
  local tool_caps_json="${RALPH_MCP_PROXY_POLICY_TOOL_RESULT_BYTE_CAPS_JSON:-{}}"
  local tool_cap global_cap hook_cap

  hook_cap="${RALPH_HOOK_RESULT_BYTE_CAP:-}"
  if [[ -n "$hook_cap" && "$hook_cap" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$hook_cap"
    return 0
  fi

  if [[ -n "$tool_name" ]]; then
    tool_cap="$(jq -r --arg name "$tool_name" '.[$name] // empty' <<< "$tool_caps_json" 2>/dev/null || true)"
    if [[ -n "$tool_cap" && "$tool_cap" != "null" ]]; then
      printf '%s\n' "$tool_cap"
      return 0
    fi
  fi

  global_cap="${RALPH_MCP_PROXY_POLICY_RESULT_BYTE_CAP:-0}"
  if [[ -z "$global_cap" ]]; then
    global_cap=0
  fi
  printf '%s\n' "$global_cap"
}

ralph_mcp_proxy_result_token_cap_for_tool() {
  local tool_name="${1:-}"
  local tool_caps_json="${RALPH_MCP_PROXY_POLICY_TOOL_RESULT_TOKEN_CAPS_JSON:-{}}"
  local tool_cap global_cap hook_cap

  hook_cap="${RALPH_HOOK_RESULT_TOKEN_CAP:-}"
  if [[ -n "$hook_cap" && "$hook_cap" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$hook_cap"
    return 0
  fi

  if [[ -n "$tool_name" ]]; then
    tool_cap="$(jq -r --arg name "$tool_name" '.[$name] // empty' <<< "$tool_caps_json" 2>/dev/null || true)"
    if [[ -n "$tool_cap" && "$tool_cap" != "null" ]]; then
      printf '%s\n' "$tool_cap"
      return 0
    fi
  fi

  global_cap="${RALPH_MCP_PROXY_POLICY_RESULT_TOKEN_CAP:-0}"
  if [[ -z "$global_cap" ]]; then
    global_cap=0
  fi
  printf '%s\n' "$global_cap"
}

ralph_mcp_proxy_result_caps_active_for_tool() {
  local tool_name="${1:-}"
  local byte_cap token_cap
  byte_cap="$(ralph_mcp_proxy_result_byte_cap_for_tool "$tool_name")"
  token_cap="$(ralph_mcp_proxy_result_token_cap_for_tool "$tool_name")"
  if [[ "$byte_cap" =~ ^[0-9]+$ ]] && [[ "$byte_cap" -gt 0 ]]; then
    return 0
  fi
  if [[ "$token_cap" =~ ^[0-9]+$ ]] && [[ "$token_cap" -gt 0 ]]; then
    return 0
  fi
  return 1
}

ralph_mcp_proxy_truncation_marker() {
  printf '%s' "${RALPH_MCP_PROXY_POLICY_TRUNCATION_MARKER:-...[truncated]}"
}

ralph_mcp_proxy_truncate_text() {
  local text="${1:-}"
  local limit="${2:-0}"
  local marker="${3:-}"
  if [[ -z "$marker" ]]; then
    marker="$(ralph_mcp_proxy_truncation_marker)"
  fi
  if [[ "$limit" =~ ^[0-9]+$ ]] && [[ "$limit" -gt 0 ]] && [[ "${#text}" -gt "$limit" ]]; then
    printf '%s%s' "${text:0:limit}" "$marker"
    return 0
  fi
  printf '%s' "$text"
}
