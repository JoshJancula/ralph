#!/usr/bin/env bash
# Shared effective runtime MCP configuration overlay resolver.
#
# Public interface:
#   ralph_runtime_config_mcp_script_path -- print python helper path
#   ralph_runtime_config_mcp_needs_resolve -- true when ambient/agent/ralph overlay work is required
#   ralph_runtime_config_mcp_resolve -- build effective catalog; sets RALPH_RUNTIME_MCP_RESOLVE_PATH on success
#   ralph_runtime_config_mcp_apply_summary -- push sanitized summary fields into runtime overlay
#   ralph_runtime_config_mcp_cleanup -- remove ephemeral resolve artifact

if [[ -n "${RALPH_RUNTIME_CONFIG_MCP_LOADED:-}" ]]; then
  return
fi
RALPH_RUNTIME_CONFIG_MCP_LOADED=1

if ! declare -F ralph_normalize_runtime_name >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/runtime-normalize.sh"
fi

if ! declare -F ralph_mcp_proxy_server_script_path >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/mcp/mcp-setup.sh"
fi

RALPH_RUNTIME_MCP_RESOLVE_PATH=""
RALPH_RUNTIME_MCP_SUMMARY_JSON=""

ralph_runtime_config_mcp_script_path() {
  local root="${RALPH_DIR:-${SCRIPT_DIR:-}}"
  if [[ -z "$root" ]]; then
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  fi
  printf '%s/python/runtime-config-mcp.py\n' "$root"
}

ralph_runtime_config_mcp_ambient_source_paths() {
  local runtime="${1:-}"
  local project_root="${2:-${RALPH_PROJECT_ROOT:-${WORKSPACE:-}}}"
  local home="${RALPH_RUNTIME_MCP_HOME:-${HOME:-}}"
  local xdg="${XDG_CONFIG_HOME:-$home/.config}"
  runtime="$(ralph_normalize_runtime_name "$runtime")"
  case "$runtime" in
    cursor)
      printf '%s\n' "$home/.cursor/mcp.json" "$project_root/.cursor/mcp.json"
      ;;
    claude)
      printf '%s\n' \
        "$home/.claude.json" \
        "$home/.claude/.mcp.json" \
        "$project_root/.mcp.json" \
        "$project_root/.claude/settings.local.json"
      ;;
    codex)
      printf '%s\n' "$home/.codex/config.toml" "$project_root/.codex/config.toml"
      ;;
    opencode)
      printf '%s\n' \
        "$xdg/opencode/config.json" \
        "$xdg/opencode/config.jsonc" \
        "$xdg/opencode/opencode.json" \
        "$xdg/opencode/opencode.jsonc" \
        "$project_root/opencode.json" \
        "$project_root/opencode.jsonc" \
        "$project_root/.opencode/opencode.json" \
        "$project_root/.opencode/opencode.jsonc"
      ;;
    antigravity)
      printf '%s\n' "$home/.agents/mcp_config.json" "$project_root/.agents/mcp_config.json"
      ;;
  esac
}

ralph_runtime_config_mcp_ambient_sources_exist() {
  local runtime="${1:-}"
  local project_root="${2:-${RALPH_PROJECT_ROOT:-${WORKSPACE:-}}}"
  local path
  while IFS= read -r path; do
    [[ -n "$path" && -f "$path" ]] && return 0
  done < <(ralph_runtime_config_mcp_ambient_source_paths "$runtime" "$project_root")
  return 1
}

ralph_runtime_config_mcp_needs_resolve() {
  local runtime="${1:-${RUNTIME:-}}"
  local project_root="${2:-${RALPH_PROJECT_ROOT:-${WORKSPACE:-}}}"
  local _ralph_mode="${RALPH_MODE:-no}"
  # For most runtimes, ralph/hybrid mode requires MCP overlay resolution so the
  # effective catalog (ambient + agent + Ralph) is applied to the invocation.
  #
  # Antigravity is different: it runs natively via `agy` and must receive the
  # merged effective MCP catalog through a temporary per-run config file
  # (ANTIGRAVITY_CONFIG) without persisting agent/run overlays.
  if [[ "$runtime" == "antigravity" ]]; then
    # Native-only runs should not write temporary config files; agy reads
    # native `.agents/mcp_config.json` directly.
    local has_agent_additions="0"
    if [[ -n "${RALPH_RUNTIME_MCP_AGENT_ENTRIES_JSON:-}" && "${RALPH_RUNTIME_MCP_AGENT_ENTRIES_JSON}" != "[]" ]]; then
      has_agent_additions="1"
    fi
    if [[ -n "${PREBUILT_AGENT:-}" ]]; then
      has_agent_additions="1"
    fi

    case "$_ralph_mode" in
      ralph|hybrid)
        # In Ralph mode, per-run overlay is needed only when agent/Ralph MCP
        # additions exist. Otherwise, keep pure native behavior.
        [[ "$has_agent_additions" == "1" ]] && return 0 || return 1
        ;;
      *)
        # Outside Ralph mode: only resolve when explicit agent additions exist.
        [[ "$has_agent_additions" == "1" ]] && return 0 || return 1
        ;;
    esac
  fi
  case "$_ralph_mode" in
    # In ralph/hybrid mode we must resolve and apply the effective MCP catalog
    # to the runtime invocation (tests assert the merged overlay inputs).
    ralph|hybrid) return 0 ;;
  esac
  case "${RALPH_AGENT_TOOL_ACCESS:-}" in
    ralph) return 0 ;;
  esac
  if [[ -n "${RALPH_RUNTIME_MCP_AGENT_ENTRIES_JSON:-}" && "${RALPH_RUNTIME_MCP_AGENT_ENTRIES_JSON}" != "[]" ]]; then
    return 0
  fi
  if [[ -n "${PREBUILT_AGENT:-}" ]]; then
    return 0
  fi
  if [[ -n "$runtime" ]] && ralph_runtime_config_mcp_ambient_sources_exist "$runtime" "$project_root"; then
    return 0
  fi
  return 1
}

ralph_runtime_config_mcp_cleanup() {
  if [[ -n "${RALPH_RUNTIME_MCP_RESOLVE_PATH:-}" && -f "$RALPH_RUNTIME_MCP_RESOLVE_PATH" ]]; then
    rm -f "$RALPH_RUNTIME_MCP_RESOLVE_PATH" 2>/dev/null || true
  fi
  unset RALPH_RUNTIME_MCP_RESOLVE_PATH
  unset RALPH_RUNTIME_MCP_SUMMARY_JSON
}

ralph_runtime_config_mcp_format_failure() {
  local payload="$1"
  if ! command -v jq &>/dev/null; then
    printf '%s\n' "$payload" >&2
    return
  fi
  local runtime agent reason server env_var message
  runtime="$(jq -r '.runtime // .error.runtime // empty' <<<"$payload")"
  agent="$(jq -r '.agent // .error.agent // empty' <<<"$payload")"
  reason="$(jq -r '.error.reason // "mcp_resolve_failed"' <<<"$payload")"
  server="$(jq -r '.error.server // empty' <<<"$payload")"
  env_var="$(jq -r '.error.env_var // empty' <<<"$payload")"
  message="$(jq -r '.error.message // .summary.mcp_failure_reason // "MCP overlay resolve failed"' <<<"$payload")"
  printf 'Error: MCP overlay preflight failed' >&2
  [[ -n "$runtime" ]] && printf ' runtime=%s' "$runtime" >&2
  [[ -n "$agent" ]] && printf ' agent=%s' "$agent" >&2
  printf ': %s' "$message" >&2
  [[ -n "$server" ]] && printf ' (server=%s)' "$server" >&2
  [[ -n "$env_var" ]] && printf ' (env=%s)' "$env_var" >&2
  printf '\n' >&2
  local paths
  paths="$(jq -r '(.error.searched_paths // .summary.mcp_config_sources // []) | join("\n")' <<<"$payload")"
  if [[ -n "$paths" ]]; then
    printf 'Searched MCP config sources:\n' >&2
    while IFS= read -r line; do
      [[ -n "$line" ]] && printf '  - %s\n' "$line" >&2
    done <<<"$paths"
  fi
}

ralph_runtime_config_mcp_apply_summary() {
  local summary_json="${1:-${RALPH_RUNTIME_MCP_SUMMARY_JSON:-}}"
  [[ -n "$summary_json" ]] || return 0
  if ! command -v jq &>/dev/null; then
    return 0
  fi
  local sources names decisions failure
  sources="$(jq -r '.mcp_config_sources // [] | join("\n")' <<<"$summary_json")"
  names="$(jq -r '.mcp_effective_names // [] | join("\n")' <<<"$summary_json")"
  decisions="$(jq -r '.mcp_override_decisions // [] | join("\n")' <<<"$summary_json")"
  failure="$(jq -r '.mcp_failure_reason // empty' <<<"$summary_json")"
  if declare -F runtime_overlay_set_mcp_config_sources >/dev/null 2>&1; then
    runtime_overlay_set_mcp_config_sources "$sources"
  fi
  if declare -F runtime_overlay_set_mcp_effective_names >/dev/null 2>&1; then
    runtime_overlay_set_mcp_effective_names "$names"
  fi
  if declare -F runtime_overlay_set_mcp_override_decisions >/dev/null 2>&1; then
    runtime_overlay_set_mcp_override_decisions "$decisions"
  fi
  if declare -F runtime_overlay_set_mcp_failure_reason >/dev/null 2>&1; then
    runtime_overlay_set_mcp_failure_reason "$failure"
  fi
  if declare -F runtime_overlay_set_mcp_effective >/dev/null 2>&1; then
    if [[ -n "$names" ]]; then
      runtime_overlay_set_mcp_effective "true"
    fi
  fi
}

ralph_runtime_config_mcp_resolve() {
  local runtime="${1:-${RUNTIME:-}}"
  local project_root="${2:-${RALPH_PROJECT_ROOT:-${WORKSPACE:-}}}"
  local agent="${3:-${PREBUILT_AGENT:-}}"
  local workspace="${4:-${WORKSPACE:-$project_root}}"
  local preset_agent_entries="${RALPH_RUNTIME_MCP_AGENT_ENTRIES_JSON:-}"

  runtime="$(ralph_normalize_runtime_name "$runtime")"
  ralph_runtime_config_mcp_cleanup

  if ! ralph_runtime_config_mcp_needs_resolve "$runtime" "$project_root"; then
    return 0
  fi

  if ! command -v python3 &>/dev/null; then
    echo "Error: python3 is required for runtime MCP overlay resolution." >&2
    return 1
  fi
  if ! command -v jq &>/dev/null; then
    echo "Error: jq is required for runtime MCP overlay resolution." >&2
    return 1
  fi

  local py_script server_script agent_entries="[]"
  py_script="$(ralph_runtime_config_mcp_script_path)"
  if [[ ! -f "$py_script" ]]; then
    echo "Error: runtime MCP overlay helper missing: $py_script" >&2
    return 1
  fi

  if [[ -n "$preset_agent_entries" ]]; then
    agent_entries="$preset_agent_entries"
  elif [[ -n "$agent" && -n "${AGENT_CONFIG_TOOL:-}" && -f "$AGENT_CONFIG_TOOL" ]]; then
    local agents_root
    if declare -F prebuilt_agents_root >/dev/null 2>&1; then
      agents_root="$(prebuilt_agents_root "$workspace")"
      agent_entries="$(bash "$AGENT_CONFIG_TOOL" mcp-servers "$agents_root" "$agent" 2>/dev/null || printf '[]')"
    fi
  fi

  if declare -F ralph_mcp_proxy_server_script_path >/dev/null 2>&1; then
    server_script="$(ralph_mcp_proxy_server_script_path "$workspace" 2>/dev/null || true)"
  elif declare -F ralph_mcp_server_script_path >/dev/null 2>&1; then
    server_script="$(ralph_mcp_server_script_path "$workspace" 2>/dev/null || true)"
  else
    server_script=""
  fi

  local request_json response_json resolve_path
  request_json="$(jq -n \
    --arg runtime "$runtime" \
    --arg project_root "$project_root" \
    --arg workspace "$workspace" \
    --arg agent "$agent" \
    --arg ralph_mode "${RALPH_MODE:-no}" \
    --arg tool_access "${RALPH_AGENT_TOOL_ACCESS:-}" \
    --arg server_script "$server_script" \
    --arg home "${RALPH_RUNTIME_MCP_HOME:-${HOME:-}}" \
    --argjson agent_mcp_servers "$agent_entries" \
    '{
      runtime: $runtime,
      project_root: $project_root,
      workspace: $workspace,
      agent: $agent,
      ralph_mode: $ralph_mode,
      tool_access: $tool_access,
      ralph_server_script: $server_script,
      home: $home,
      agent_mcp_servers: $agent_mcp_servers
    }')"

  if ! response_json="$(printf '%s' "$request_json" | python3 "$py_script" resolve 2>&1)"; then
    if [[ -z "$response_json" ]] || ! jq -e . >/dev/null 2>&1 <<<"$response_json"; then
      echo "Error: runtime MCP overlay resolver failed to run." >&2
      [[ -n "$response_json" ]] && printf '%s\n' "$response_json" >&2
      return 1
    fi
  fi

  if [[ "$(jq -r '.ok // false' <<<"$response_json")" != "true" ]]; then
    ralph_runtime_config_mcp_format_failure "$response_json"
    RALPH_RUNTIME_MCP_SUMMARY_JSON="$(jq -c '.summary // {}' <<<"$response_json")"
    export RALPH_RUNTIME_MCP_SUMMARY_JSON
    ralph_runtime_config_mcp_apply_summary "$RALPH_RUNTIME_MCP_SUMMARY_JSON"
    return 1
  fi

  resolve_path="$(mktemp "${TMPDIR:-/tmp}/ralph-runtime-mcp-resolve-XXXXXX")"
  jq '.runtime_config' <<<"$response_json" >"$resolve_path"
  RALPH_RUNTIME_MCP_RESOLVE_PATH="$resolve_path"
  RALPH_RUNTIME_MCP_SUMMARY_JSON="$(jq -c '.summary // {}' <<<"$response_json")"
  export RALPH_RUNTIME_MCP_RESOLVE_PATH RALPH_RUNTIME_MCP_SUMMARY_JSON

  if declare -F ralph_mcp_overlay_record_temp_file >/dev/null 2>&1; then
    ralph_mcp_overlay_record_temp_file "$resolve_path"
  fi
  if declare -F ralph_mcp_overlay_register_runtime_cleanup >/dev/null 2>&1; then
    ralph_mcp_overlay_register_runtime_cleanup ralph_runtime_config_mcp_cleanup
  fi

  ralph_runtime_config_mcp_apply_summary "$RALPH_RUNTIME_MCP_SUMMARY_JSON"
  return 0
}
