#!/usr/bin/env bash
# Shared helpers for MCP runtime setup.
#
# Public interface:
#   ralph_mcp_proxy_server_script_path <workspace>
#   ralph_mcp_server_script_path <workspace>
#     -- Print the resolved path to the Ralph MCP server script.
#   ralph_mcp_jev_server_script_path <workspace>
#     -- Print the resolved path to the Jev MCP server script (override-then-default).
#   ralph_mcp_jev_mcp_enabled
#     -- True when RALPH_JEV=1 and RALPH_JEV_MCP=1 (Track 2 registration gate).
#        Preflight may clear RALPH_JEV_MCP on a non-fatal ralph-jev failure.
#   ralph_mcp_jev_mcp_disable <reason>
#     -- Export RALPH_JEV_MCP=0 and RALPH_JEV_MCP_DISABLE_REASON for the rest of
#        this process (used when ralph-jev preflight fails).
#   ralph_mcp_proxy_generate_config <runtime> <output_path> <workspace> [<server_script>]
#   ralph_mcp_generate_config <runtime> <output_path> <workspace> [<server_script>]
#     -- Generate a runtime-specific ephemeral MCP config JSON.
#        With Jev off, output is ralph-only (byte-stable). With Jev on, also
#        registers ralph-jev beside ralph in each runtime's required shape.
#   ralph_mcp_proxy_cleanup_config <path>
#   ralph_mcp_cleanup_config <path>
#     -- Remove the ephemeral config file.
#   ralph_mcp_proxy_preflight [<server_script>] <workspace>
#   ralph_mcp_preflight [<server_script>] <workspace>
#     -- Handshake every Ralph-owned MCP server (ralph always; ralph-jev when
#        Track 2 is enabled). Ralph failures are fatal. ralph-jev failures are
#        non-fatal: log, record RALPH_JEV_MCP_DISABLE_REASON, disable Jev MCP,
#        and continue. Prints "OK" on success; returns 1 only on ralph failure.

if [[ -n "${RALPH_MCP_PROXY_SETUP_LOADED:-}" ]]; then
  return
fi
RALPH_MCP_PROXY_SETUP_LOADED=1

if ! declare -F ralph_normalize_runtime_name >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/runtime-normalize.sh"
fi

# Override to force a specific server script path.
RALPH_MCP_PROXY_SERVER_SCRIPT="${RALPH_MCP_PROXY_SERVER_SCRIPT:-}"
# Override to force a specific Jev MCP server script path.
RALPH_JEV_MCP_SERVER_SCRIPT="${RALPH_JEV_MCP_SERVER_SCRIPT:-}"

# True when both Track 2 switches are explicitly enabled (matches runtime-config-mcp.py).
# Preflight may export RALPH_JEV_MCP=0 after a non-fatal ralph-jev failure.
ralph_mcp_jev_mcp_enabled() {
  [[ "${RALPH_JEV:-}" == "1" && "${RALPH_JEV_MCP:-}" == "1" ]]
}

# Disable Track 2 Jev MCP for the remainder of this process. Jev is advisory:
# an unreachable ralph-jev server must never abort a plan run.
ralph_mcp_jev_mcp_disable() {
  local reason="${1:-preflight_failed}"
  export RALPH_JEV_MCP=0
  export RALPH_JEV_MCP_DISABLE_REASON="$reason"
}

# Resolve RALPH_MODE for MCP catalog checks (defaults to no).
ralph_mcp_proxy_resolve_mode() {
  local mode="${RALPH_MODE:-no}"
  mode="$(tr '[:upper:]' '[:lower:]' <<<"$mode" | tr -d '\r\n')"
  case "$mode" in
    no|native|ralph|hybrid)
      printf '%s' "$mode"
      ;;
    *)
      return 1
      ;;
  esac
}

# True when the compact MCP tool catalog is active.
# Rollout gate: ralph/hybrid unless RALPH_MCP_COMPACT_TOOL_CATALOG=0;
# native/no unless RALPH_MCP_COMPACT_TOOL_CATALOG=1.
ralph_mcp_proxy_compact_tool_catalog_enabled() {
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

# Required tools for tools/list preflight, keyed by RALPH_MODE. Kept in sync with
# get_tool_list_result() in bundle/.ralph/mcp-server.sh and the allowedTools
# surface built in run-plan-invoke-claude.sh.
ralph_mcp_proxy_required_tool_names() {
  local mode compact=0 compact_rc=0
  if ! mode="$(ralph_mcp_proxy_resolve_mode)"; then
    mode="no"
  fi
  ralph_mcp_proxy_compact_tool_catalog_enabled
  compact_rc=$?
  case "$compact_rc" in
    0) compact=1 ;;
    1) compact=0 ;;
    *) return "$compact_rc" ;;
  esac
  case "$mode" in
    native)
      if [[ "$compact" == "1" ]]; then
        printf '%s\n' \
          ralph_run_plan \
          ralph_plan_status \
          ralph_orchestrator_run \
          ralph_complete_todo \
          ralph_proxy_result_read \
          ralph_proxy_tool_search
      else
        printf '%s\n' \
          ralph_run_plan \
          ralph_plan_status \
          ralph_orchestrator_run \
          ralph_complete_todo \
          ralph_proxy_result_read \
          ralph_proxy_result_search \
          ralph_proxy_result_summary
      fi
      ;;
    ralph|hybrid)
      if [[ "$compact" == "1" ]]; then
        printf '%s\n' \
          ralph_run_plan \
          ralph_plan_status \
          ralph_orchestrator_run \
          ralph_complete_todo \
          ralph_proxy_shell \
          ralph_proxy_result_read \
          ralph_proxy_batch
      else
        printf '%s\n' \
          ralph_run_plan \
          ralph_plan_status \
          ralph_orchestrator_run \
          ralph_complete_todo \
          ralph_proxy_shell \
          ralph_proxy_result_read \
          ralph_proxy_result_search \
          ralph_proxy_result_summary
      fi
      ;;
    no)
      ;;
  esac
}

# Proxy shell tools that must stay hidden in native mode.
ralph_mcp_proxy_native_hidden_tool_names() {
  printf '%s\n' \
    ralph_proxy_shell
}

# True when run-plan is executing from the workspace's own .ralph tree (local invocation).
ralph_mcp_proxy_is_workspace_ralph_install() {
  local workspace="${1:-}"
  local ralph_dir="${RALPH_DIR:-}"
  local workspace_ralph resolved_ralph resolved_workspace

  if [[ -z "$workspace" || -z "$ralph_dir" ]]; then
    return 1
  fi

  workspace_ralph="${workspace%/}/.ralph"
  if [[ ! -d "$workspace_ralph" ]]; then
    return 1
  fi

  resolved_ralph="$(cd "$ralph_dir" && pwd -P 2>/dev/null)" || return 1
  resolved_workspace="$(cd "$workspace_ralph" && pwd -P 2>/dev/null)" || return 1
  [[ "$resolved_ralph" == "$resolved_workspace" ]]
}

ralph_mcp_proxy_server_script_path() {
  local workspace="${1:-}"
  local script_dir

  if [[ -n "${RALPH_MCP_PROXY_SERVER_SCRIPT:-}" ]]; then
    printf '%s\n' "$RALPH_MCP_PROXY_SERVER_SCRIPT"
    return 0
  fi

  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."

  # Global invocation (e.g. ralph run-plan): prefer the active Ralph install even when
  # the workspace still has a leftover project-local .ralph/ from an older install.
  if [[ -n "${RALPH_DIR:-}" ]] && ! ralph_mcp_proxy_is_workspace_ralph_install "$workspace"; then
    if [[ -f "${RALPH_DIR}/mcp-server.sh" ]]; then
      printf '%s\n' "${RALPH_DIR}/mcp-server.sh"
      return 0
    fi
  fi

  # Local invocation: run-plan.sh lives in <workspace>/.ralph.
  if [[ -n "$workspace" ]]; then
    if [[ -f "$workspace/.ralph/mcp-server.sh" ]]; then
      printf '%s\n' "$workspace/.ralph/mcp-server.sh"
      return 0
    fi
  fi

  if [[ -f "$script_dir/mcp-server.sh" ]]; then
    printf '%s\n' "$script_dir/mcp-server.sh"
    return 0
  fi
  return 1
}

# Resolve the Jev MCP server script (override-then-default, matching
# ralph_mcp_proxy_server_script_path). Prefer an explicit override, then the
# sibling of the resolved Ralph server, then RALPH_DIR / workspace / script dir.
ralph_mcp_jev_server_script_path() {
  local workspace="${1:-}"
  local script_dir
  local ralph_script sibling

  if [[ -n "${RALPH_JEV_MCP_SERVER_SCRIPT:-}" ]]; then
    printf '%s\n' "$RALPH_JEV_MCP_SERVER_SCRIPT"
    return 0
  fi

  if ralph_script="$(ralph_mcp_proxy_server_script_path "$workspace" 2>/dev/null)"; then
    sibling="$(dirname "$ralph_script")/jev-mcp-server.sh"
    if [[ -f "$sibling" ]]; then
      printf '%s\n' "$sibling"
      return 0
    fi
  fi

  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."

  if [[ -n "${RALPH_DIR:-}" ]] && ! ralph_mcp_proxy_is_workspace_ralph_install "$workspace"; then
    if [[ -f "${RALPH_DIR}/jev-mcp-server.sh" ]]; then
      printf '%s\n' "${RALPH_DIR}/jev-mcp-server.sh"
      return 0
    fi
  fi

  if [[ -n "$workspace" ]]; then
    if [[ -f "$workspace/.ralph/jev-mcp-server.sh" ]]; then
      printf '%s\n' "$workspace/.ralph/jev-mcp-server.sh"
      return 0
    fi
  fi

  if [[ -f "$script_dir/jev-mcp-server.sh" ]]; then
    printf '%s\n' "$script_dir/jev-mcp-server.sh"
    return 0
  fi
  return 1
}

# Minimal env for the Jev decision MCP server. Never inline the API key into
# source; only forward TYPESAFE_API_KEY when already present in this process.
ralph_mcp_jev_build_server_env_json() {
  local workspace="${1:-}"
  if [[ -z "$workspace" ]]; then
    echo "Error: workspace is required for Jev MCP server environment." >&2
    return 1
  fi
  jq -n \
    --arg ws "$workspace" \
    --arg typesafe_key "${TYPESAFE_API_KEY:-}" \
    '{
      RALPH_MCP_WORKSPACE: $ws,
      RALPH_JEV: "1",
      RALPH_JEV_MCP: "1"
    }
    + (if $typesafe_key != "" then {TYPESAFE_API_KEY: $typesafe_key} else {} end)'
}

ralph_mcp_proxy_generate_config() {
  local runtime="${1:-}"
  local output_path="${2:-}"
  local workspace="${3:-}"
  local server_script="${4:-}"

  runtime="$(ralph_normalize_runtime_name "$runtime")"

  if [[ -z "$runtime" ]]; then
    echo "Error: runtime is required for ephemeral MCP config generation." >&2
    return 1
  fi
  case "$runtime" in
    claude|codex|cursor|opencode|antigravity) ;;
    *)
      echo "Error: unsupported runtime '$runtime' for ephemeral MCP config generation." >&2
      return 1
      ;;
  esac
  if [[ -z "$output_path" ]]; then
    echo "Error: output path is required for ephemeral MCP config generation." >&2
    return 1
  fi
  if [[ -z "$workspace" ]]; then
    echo "Error: workspace is required for ephemeral MCP config generation." >&2
    return 1
  fi
  if [[ -z "$server_script" ]]; then
    if ! server_script="$(ralph_mcp_proxy_server_script_path "$workspace")"; then
      echo "Error: could not find Ralph MCP server script for workspace $workspace. Set RALPH_MCP_PROXY_SERVER_SCRIPT or ensure the active Ralph install or workspace has mcp-server.sh." >&2
      return 1
    fi
  fi
  if [[ ! -f "$server_script" ]]; then
    echo "Error: Ralph MCP server script not found: $server_script" >&2
    return 1
  fi

  local config_dir
  config_dir="$(dirname "$output_path")"
  if [[ -e "$config_dir" && ! -d "$config_dir" ]]; then
    echo "Error: ephemeral config directory path exists but is not a directory: $config_dir" >&2
    return 1
  fi
  if ! mkdir -p "$config_dir" 2>/dev/null; then
    echo "Error: cannot create ephemeral config directory $config_dir" >&2
    return 1
  fi

  if ! command -v jq &>/dev/null; then
    echo "Error: jq is required for ephemeral MCP config generation." >&2
    return 1
  fi

  local env_json
  if ! env_json="$(ralph_mcp_proxy_build_server_env_json "$workspace")"; then
    echo "Error: failed to build Ralph MCP server environment JSON." >&2
    return 1
  fi

  # Compose Ralph-owned servers once; render into each runtime's required shape below.
  # Adding another owned server is a gated merge into this catalog object so that
  # with Jev off the ralph-only document stays byte-identical to prior behavior.
  local catalog_json
  if ! catalog_json="$(jq -n \
    --arg cmd "bash" \
    --arg arg1 "$server_script" \
    --argjson env "$env_json" \
    '{
      ralph: {
        command: $cmd,
        args: [$arg1],
        env: $env
      }
    }' 2>/dev/null)"; then
    echo "Error: failed to build Ralph MCP server catalog." >&2
    return 1
  fi

  if ralph_mcp_jev_mcp_enabled; then
    local jev_script jev_env_json
    if ! jev_script="$(ralph_mcp_jev_server_script_path "$workspace")"; then
      echo "Error: could not find Jev MCP server script for workspace $workspace. Set RALPH_JEV_MCP_SERVER_SCRIPT or ensure the active Ralph install or workspace has jev-mcp-server.sh." >&2
      return 1
    fi
    if [[ ! -f "$jev_script" ]]; then
      echo "Error: Jev MCP server script not found: $jev_script" >&2
      return 1
    fi
    if ! jev_env_json="$(ralph_mcp_jev_build_server_env_json "$workspace")"; then
      echo "Error: failed to build Jev MCP server environment JSON." >&2
      return 1
    fi
    if ! catalog_json="$(jq -n \
      --argjson catalog "$catalog_json" \
      --arg cmd "bash" \
      --arg arg1 "$jev_script" \
      --argjson env "$jev_env_json" \
      '$catalog + {
        "ralph-jev": {
          command: $cmd,
          args: [$arg1],
          env: $env
        }
      }' 2>/dev/null)"; then
      echo "Error: failed to add ralph-jev to Ralph MCP server catalog." >&2
      return 1
    fi
  fi

  local rendered
  case "$runtime" in
    claude|codex)
      if ! rendered="$(jq -n \
        --argjson catalog "$catalog_json" \
        '{mcpServers: $catalog}' 2>/dev/null)"; then
        echo "Error: failed to render ephemeral MCP config for $runtime" >&2
        return 1
      fi
      ;;
    cursor|antigravity)
      if ! rendered="$(jq -n \
        --argjson catalog "$catalog_json" \
        '{
          mcpServers: (
            $catalog
            | with_entries(.value = ({type: "stdio"} + .value))
          )
        }' 2>/dev/null)"; then
        echo "Error: failed to render ephemeral MCP config for $runtime" >&2
        return 1
      fi
      ;;
    opencode)
      if ! rendered="$(jq -n \
        --argjson catalog "$catalog_json" \
        '{
          mcp: (
            $catalog
            | with_entries(.value = {
                type: "local",
                command: ([.value.command] + .value.args),
                enabled: true,
                environment: .value.env
              })
          )
        }' 2>/dev/null)"; then
        echo "Error: failed to render ephemeral MCP config for $runtime" >&2
        return 1
      fi
      ;;
    *)
      echo "Error: unsupported runtime '$runtime' for ephemeral MCP config generation." >&2
      return 1
      ;;
  esac

  if ! printf '%s\n' "$rendered" > "$output_path" 2>/dev/null; then
    echo "Error: failed to write ephemeral MCP config to $output_path" >&2
    return 1
  fi

  printf '%s\n' "$output_path"
  return 0
}

ralph_mcp_proxy_build_server_env_json() {
  local workspace="${1:-}"
  if [[ -z "$workspace" ]]; then
    echo "Error: workspace is required for Ralph MCP server environment." >&2
    return 1
  fi
  local interactivity
  # Drive MCP-side wording for operator-facing proxy denials.
  # NON_INTERACTIVE_FLAG=1 means the runner should not block for operator input.
  if [[ "${NON_INTERACTIVE_FLAG:-0}" == "1" ]]; then
    interactivity="non-interactive"
  else
    interactivity="interactive"
  fi
  jq -n \
    --arg ws "$workspace" \
    --arg project_root "${RALPH_PROJECT_ROOT:-}" \
    --arg agent_workspace "${RALPH_AGENT_WORKSPACE:-}" \
    --arg plan_key "${RALPH_PLAN_KEY:-}" \
    --arg artifact_ns "${RALPH_ARTIFACT_NS:-}" \
    --arg ws_root "${RALPH_PLAN_WORKSPACE_ROOT:-}" \
    --arg allowlist "${RALPH_MCP_ALLOWLIST:-}" \
    --arg policy "${RALPH_MCP_PROXY_POLICY:-}" \
    --arg policy_file "${RALPH_MCP_PROXY_POLICY_FILE:-}" \
    --arg policy_inline "${RALPH_MCP_PROXY_POLICY_INLINE:-}" \
    --arg auth "${RALPH_MCP_AUTH_TOKEN:-}" \
    --arg proxy_compact "${RALPH_PROXY_SHELL_COMPACT:-}" \
    --arg proxy_compact_log "${RALPH_PROXY_SHELL_COMPACT_LOG:-}" \
    --arg result_windowing_log "${RALPH_RESULT_WINDOWING_LOG:-}" \
    --arg ralph_mode "${RALPH_MODE:-no}" \
    --arg interactivity "$interactivity" \
    --arg agent_tool_access "${RALPH_AGENT_TOOL_ACCESS:-}" \
    --arg run_plan_active "${RALPH_RUN_PLAN_ACTIVE:-}" \
    --arg current_plan_path "${RALPH_CURRENT_PLAN_PATH:-}" \
    --arg current_todo_line "${RALPH_CURRENT_TODO_LINE:-}" \
    --arg current_todo_ordinal "${RALPH_CURRENT_TODO_ORDINAL:-}" \
    --arg current_todo_id "${RALPH_CURRENT_TODO_ID:-}" \
    --arg current_todo_hash "${RALPH_CURRENT_TODO_HASH:-}" \
    --arg approval_timeout "${RALPH_APPROVAL_TIMEOUT:-}" \
    --arg approval_poll_interval "${RALPH_APPROVAL_POLL_INTERVAL:-}" \
    --arg approval_progress_interval "${RALPH_APPROVAL_PROGRESS_INTERVAL:-}" \
    '{
      RALPH_MCP_WORKSPACE: $ws,
      RALPH_MODE: $ralph_mode,
      RALPH_MCP_PROXY_INTERACTIVITY: $interactivity
    }
    + (if $project_root != "" then {RALPH_PROJECT_ROOT: $project_root} else {} end)
    + (if $agent_workspace != "" then {RALPH_AGENT_WORKSPACE: $agent_workspace} else {} end)
    + (if $plan_key != "" then {RALPH_PLAN_KEY: $plan_key} else {} end)
    + (if $artifact_ns != "" then {RALPH_ARTIFACT_NS: $artifact_ns} else {} end)
    + (if $ws_root != "" then {RALPH_PLAN_WORKSPACE_ROOT: $ws_root} else {} end)
    + (if $agent_tool_access != "" then {RALPH_AGENT_TOOL_ACCESS: $agent_tool_access} else {} end)
    + (if $run_plan_active != "" then {RALPH_RUN_PLAN_ACTIVE: $run_plan_active} else {} end)
    + (if $current_plan_path != "" then {RALPH_CURRENT_PLAN_PATH: $current_plan_path} else {} end)
    + (if $current_todo_line != "" then {RALPH_CURRENT_TODO_LINE: $current_todo_line} else {} end)
    + (if $current_todo_ordinal != "" then {RALPH_CURRENT_TODO_ORDINAL: $current_todo_ordinal} else {} end)
    + (if $current_todo_id != "" then {RALPH_CURRENT_TODO_ID: $current_todo_id} else {} end)
    + (if $current_todo_hash != "" then {RALPH_CURRENT_TODO_HASH: $current_todo_hash} else {} end)
    + (if $allowlist != "" then {RALPH_MCP_ALLOWLIST: $allowlist} else {} end)
    + (if $policy != "" then {RALPH_MCP_PROXY_POLICY: $policy} else {} end)
    + (if $policy_file != "" then {RALPH_MCP_PROXY_POLICY_FILE: $policy_file} else {} end)
    + (if $policy_inline != "" then {RALPH_MCP_PROXY_POLICY_INLINE: $policy_inline} else {} end)
    + (if $auth != "" then {RALPH_MCP_AUTH_TOKEN: $auth} else {} end)
    + (if $proxy_compact != "" then {RALPH_PROXY_SHELL_COMPACT: $proxy_compact} else {} end)
    + (if $proxy_compact_log != "" then {RALPH_PROXY_SHELL_COMPACT_LOG: $proxy_compact_log} else {} end)
    + (if $result_windowing_log != "" then {RALPH_RESULT_WINDOWING_LOG: $result_windowing_log} else {} end)
    + (if $approval_timeout != "" then {RALPH_APPROVAL_TIMEOUT: $approval_timeout} else {} end)
    + (if $approval_poll_interval != "" then {RALPH_APPROVAL_POLL_INTERVAL: $approval_poll_interval} else {} end)
    + (if $approval_progress_interval != "" then {RALPH_APPROVAL_PROGRESS_INTERVAL: $approval_progress_interval} else {} end)'
}

ralph_mcp_proxy_env_assignments() {
  local workspace="${1:-}"
  local env_json key value
  if ! env_json="$(ralph_mcp_proxy_build_server_env_json "$workspace")"; then
    return 1
  fi
  while IFS=$'\t' read -r key value; do
    [[ -n "$key" ]] || continue
    printf '%s=%s\n' "$key" "$value"
  done < <(jq -r 'to_entries[] | [.key, .value] | @tsv' <<< "$env_json")
}

ralph_mcp_jev_env_assignments() {
  local workspace="${1:-}"
  local env_json key value
  if ! env_json="$(ralph_mcp_jev_build_server_env_json "$workspace")"; then
    return 1
  fi
  while IFS=$'\t' read -r key value; do
    [[ -n "$key" ]] || continue
    printf '%s=%s\n' "$key" "$value"
  done < <(jq -r 'to_entries[] | [.key, .value] | @tsv' <<< "$env_json")
}

ralph_mcp_proxy_cleanup_config() {
  local path="${1:-}"
  if [[ -z "$path" ]]; then
    return 0
  fi
  if [[ -f "$path" ]]; then
    rm -f "$path" 2>/dev/null || true
  fi
}

# Handshake one MCP server script. validate_required=1 applies the fatal
# ralph_mcp_proxy_required_tool_names catalog (ralph only). Jev never uses that
# list — its tools are advisory and must not gate the run.
#
# Args: <server_id> <server_script> <workspace> <ralph_mode> <env_kind> <validate_required>
# env_kind: ralph | jev
# On failure prints to stderr and returns 1. On success returns 0 (no stdout).
ralph_mcp_proxy_preflight_one_server() {
  local server_id="${1:-}"
  local server_script="${2:-}"
  local workspace="${3:-}"
  local ralph_mode="${4:-}"
  local env_kind="${5:-ralph}"
  local validate_required="${6:-0}"

  if [[ -z "$server_id" || -z "$server_script" || -z "$workspace" || -z "$ralph_mode" ]]; then
    echo "Error: server_id, server_script, workspace, and ralph_mode are required for MCP server preflight." >&2
    return 1
  fi
  if [[ ! -f "$server_script" ]]; then
    echo "Error: ${server_id} MCP server script not found: $server_script" >&2
    return 1
  fi

  local tmpdir
  tmpdir="$(mktemp -d)"
  local stdout_file="$tmpdir/stdout"
  local stderr_file="$tmpdir/stderr"

  local payload
  payload='{"jsonrpc":"2.0","id":1,"method":"initialize"}
{"jsonrpc":"2.0","id":2,"method":"tools/list"}
{"jsonrpc":"2.0","id":3,"method":"exit"}'

  local -a env_args=()
  local env_line
  case "$env_kind" in
    jev)
      while IFS= read -r env_line; do
        [[ -n "$env_line" ]] && env_args+=("$env_line")
      done < <(ralph_mcp_jev_env_assignments "$workspace")
      ;;
    *)
      while IFS= read -r env_line; do
        [[ -n "$env_line" ]] && env_args+=("$env_line")
      done < <(ralph_mcp_proxy_env_assignments "$workspace")
      ;;
  esac

  local exit_code=0
  env "${env_args[@]}" bash "$server_script" > "$stdout_file" 2> "$stderr_file" <<< "$payload" || exit_code=$?

  if [[ "$exit_code" -ne 0 ]]; then
    rm -rf "$tmpdir"
    echo "Error: ${server_id} MCP server process exited with code $exit_code. Ensure jq is installed and the workspace is valid." >&2
    if [[ -s "$stderr_file" ]]; then
      sed -n '1,5p' "$stderr_file" >&2
    fi
    return 1
  fi

  # Parse the JSON-RPC responses instead of substring-matching: the bash server
  # happily emits shapes that a strict MCP client (Claude Code 2.1.x) silently
  # rejects -- most notably a present-but-null nextCursor, which makes Claude drop
  # every tool from the server while still reporting it as "connected". A grep for
  # '"tools"' passes in that case, so the preflight has to actually validate.
  local init_caps
  if ! init_caps="$(jq -c 'select(.id==1) | .result.capabilities // empty' "$stdout_file" 2>/dev/null)" || [[ -z "$init_caps" ]]; then
    rm -rf "$tmpdir"
    echo "Error: ${server_id} MCP preflight initialize response missing capabilities. Server output did not contain expected handshake result." >&2
    return 1
  fi

  local tools_result
  if ! tools_result="$(jq -c 'select(.id==2) | .result // empty' "$stdout_file" 2>/dev/null)" || [[ -z "$tools_result" ]]; then
    rm -rf "$tmpdir"
    echo "Error: ${server_id} MCP preflight tools/list response missing or unparseable. Server may not have started correctly." >&2
    return 1
  fi

  if ! jq -e '.tools | type == "array" and length > 0' <<< "$tools_result" >/dev/null 2>&1; then
    rm -rf "$tmpdir"
    echo "Error: ${server_id} MCP preflight tools/list returned an empty or non-array tools list." >&2
    return 1
  fi

  # nextCursor must be omitted (or a string) -- a null value makes Claude Code
  # discard the entire tool list. Treat null as a hard failure here so a regression
  # is caught before the agent runs with no tools.
  if ! jq -e 'if has("nextCursor") then (.nextCursor | type == "string") else true end' <<< "$tools_result" >/dev/null 2>&1; then
    rm -rf "$tmpdir"
    echo "Error: ${server_id} MCP preflight tools/list returned a null nextCursor. Claude Code drops every tool from such a server; the server must omit nextCursor when there is no next page." >&2
    return 1
  fi

  if [[ "$validate_required" == "1" ]]; then
    local missing="" tool_name scope
    scope="${RALPH_MCP_SCOPE:-operator}"
    for tool_name in $(ralph_mcp_proxy_required_tool_names); do
      # Restricted graph scopes intentionally hide tools that create top-level
      # work. Their preflight must validate the reduced catalog rather than
      # treating the safety policy as a missing-tool regression.
      if [[ "$scope" != operator ]]; then
        case "$tool_name" in
          ralph_run_plan|ralph_orchestrator_run) continue ;;
        esac
      fi
      if ! jq -e --arg n "$tool_name" '[.tools[]?.name] | index($n) != null' <<< "$tools_result" >/dev/null 2>&1; then
        missing+=" $tool_name"
      fi
    done
    if [[ "$scope" == graph-node ]]; then
      for tool_name in ralph_delegated_run_start ralph_delegated_run_status ralph_delegated_run_wait ralph_delegated_run_result ralph_delegated_run_cancel; do
        if ! jq -e --arg n "$tool_name" '[.tools[]?.name] | index($n) != null' <<< "$tools_result" >/dev/null 2>&1; then
          missing+=" $tool_name"
        fi
      done
    fi
    if [[ -n "$missing" ]]; then
      rm -rf "$tmpdir"
      echo "Error: MCP preflight tools/list is missing required tools for RALPH_MODE=${ralph_mode}:${missing}." >&2
      return 1
    fi

    if [[ "$ralph_mode" == "native" ]]; then
      local hidden="" hidden_tool
      for hidden_tool in $(ralph_mcp_proxy_native_hidden_tool_names); do
        if jq -e --arg n "$hidden_tool" '[.tools[]?.name] | index($n) != null' <<< "$tools_result" >/dev/null 2>&1; then
          hidden+=" $hidden_tool"
        fi
      done
      if [[ -n "$hidden" ]]; then
        rm -rf "$tmpdir"
        echo "Error: MCP preflight tools/list exposes proxy read/search/shell tools in native mode:${hidden}." >&2
        return 1
      fi
    fi
  fi

  rm -rf "$tmpdir"
  return 0
}

# Disable Jev MCP after a non-fatal ralph-jev preflight failure. Logs a warning,
# records RALPH_JEV_MCP_DISABLE_REASON, and clears the Track 2 gate so later
# generate_config / allow-list builders omit ralph-jev for the rest of the run.
ralph_mcp_proxy_preflight_disable_jev() {
  local detail="${1:-unknown failure}"
  local reason="ralph-jev preflight failed: ${detail}"
  ralph_mcp_jev_mcp_disable "$reason"
  echo "Warning: ${reason}. Disabling Jev MCP for the remainder of this run; continuing with ralph only." >&2
}

ralph_mcp_proxy_preflight() {
  local server_script="${1:-}"
  local workspace="${2:-}"

  if [[ -z "$workspace" && -n "$server_script" ]]; then
    workspace="$server_script"
    server_script=""
  fi

  if [[ -z "$workspace" ]]; then
    echo "Error: workspace is required for MCP preflight." >&2
    return 1
  fi
  if [[ -z "$server_script" ]]; then
    if ! server_script="$(ralph_mcp_proxy_server_script_path "$workspace")"; then
      echo "Error: could not find Ralph MCP server script for preflight (workspace $workspace). Set RALPH_MCP_PROXY_SERVER_SCRIPT or ensure the active Ralph install or workspace has mcp-server.sh." >&2
      return 1
    fi
  fi
  if [[ ! -f "$server_script" ]]; then
    echo "Error: Ralph MCP server script not found: $server_script" >&2
    return 1
  fi

  local ralph_mode
  if ! ralph_mode="$(ralph_mcp_proxy_resolve_mode)"; then
    echo "Error: RALPH_MODE must be one of no, native, ralph, or hybrid." >&2
    return 1
  fi
  if [[ "$ralph_mode" == "no" ]]; then
    echo "Error: Ralph MCP preflight cannot run with RALPH_MODE=no. Use native, ralph, or hybrid when starting the MCP server." >&2
    return 1
  fi

  # Ralph is a hard dependency: required-tool catalog failure aborts the run.
  # Error wording stays recognizable to existing bats (substring asserts).
  if ! ralph_mcp_proxy_preflight_one_server \
      "Ralph" "$server_script" "$workspace" "$ralph_mode" "ralph" "1"; then
    return 1
  fi

  # ralph-jev is advisory. Handshake it when gated on, but never fail the run.
  # Do not consult ralph_mcp_proxy_required_tool_names for Jev tools.
  if ralph_mcp_jev_mcp_enabled; then
    local jev_script jev_err
    if ! jev_script="$(ralph_mcp_jev_server_script_path "$workspace" 2>/dev/null)"; then
      ralph_mcp_proxy_preflight_disable_jev "could not resolve jev-mcp-server.sh"
    elif [[ ! -f "$jev_script" ]]; then
      ralph_mcp_proxy_preflight_disable_jev "server script not found: $jev_script"
    else
      if ! jev_err="$(ralph_mcp_proxy_preflight_one_server \
          "ralph-jev" "$jev_script" "$workspace" "$ralph_mode" "jev" "0" 2>&1)"; then
        # Collapse to a single-line reason for the disable record.
        local jev_reason
        jev_reason="$(printf '%s\n' "$jev_err" | head -n 1 | sed 's/^Error: //')"
        [[ -n "$jev_reason" ]] || jev_reason="handshake failed"
        printf '%s\n' "$jev_err" >&2
        ralph_mcp_proxy_preflight_disable_jev "$jev_reason"
      fi
    fi
  fi

  echo "OK"
  return 0
}

# Opt-in end-to-end gate: spawn the real claude CLI against the ephemeral MCP
# config and confirm it actually registers and can invoke a ralph_proxy_* tool.
# The deterministic ralph_mcp_proxy_preflight catches known-bad response shapes for
# free; this catches unknown client-side quirks at the cost of one cheap API call.
# Enable with RALPH_MCP_CLI_PREFLIGHT=1. Return codes:
#   0 -> a ralph proxy tool was invoked (registration confirmed end-to-end)
#   1 -> the CLI ran cleanly but never reached a ralph tool (registration broken)
#   2 -> inconclusive (no CLI / auth / credit / rate limit); caller should warn, not block
ralph_mcp_claude_cli_preflight() {
  local workspace="${1:-}"
  local model="${2:-}"
  local cli="${CLAUDE_PLAN_CLI:-claude}"

  if [[ -z "$workspace" ]]; then
    echo "Note: skipping claude CLI MCP preflight; workspace not provided." >&2
    return 2
  fi
  if ! command -v "$cli" >/dev/null 2>&1; then
    echo "Note: skipping claude CLI MCP preflight; '$cli' not found." >&2
    return 2
  fi

  local cfg
  cfg="$(mktemp "${TMPDIR:-/tmp}/ralph-cli-preflight-XXXXXX")"
  if ! ralph_mcp_proxy_generate_config claude "$cfg" "$workspace" >/dev/null; then
    ralph_mcp_proxy_cleanup_config "$cfg"
    echo "Note: skipping claude CLI MCP preflight; could not generate MCP config." >&2
    return 2
  fi

  local -a model_args=()
  [[ -n "$model" ]] && model_args=(--model "$model")

  # Use the tool namespace detected during the deterministic preflight when available.
  # The server config registers as "ralph", so the Claude-side prefix is "mcp__ralph__".
  # Fall back to that known value if RALPH_MCP_TOOL_NAMESPACE is unset.
  local probe_tool_prefix="${RALPH_MCP_TOOL_NAMESPACE:-mcp__ralph__}"
  local probe_tool="${probe_tool_prefix}ralph_proxy_read"
  local prompt="You MUST call the tool ${probe_tool} with {\"path\":\"AGENTS.md\"} right now and nothing else."
  local out cli_status
  out="$(printf '%s' "$prompt" | "$cli" -p --output-format stream-json --verbose \
    "${model_args[@]}" --permission-mode bypassPermissions \
    --strict-mcp-config --mcp-config "$cfg" \
    --allowedTools "$probe_tool" 2>&1)"
  cli_status=$?
  ralph_mcp_proxy_cleanup_config "$cfg"

  # The only reliable end-to-end signal is the model actually emitting a tool_use
  # for a ralph proxy tool -- MCP tools never appear in the init `tools` snapshot
  # even when they work.
  local tool_prefix_pattern="${probe_tool_prefix}"
  [[ -z "$tool_prefix_pattern" ]] && tool_prefix_pattern="ralph_proxy_"
  if printf '%s\n' "$out" \
    | jq -e --arg prefix "$tool_prefix_pattern" \
      'select(.type=="assistant") | .message.content[]? | select(.type=="tool_use" and ((.name // "") | startswith($prefix)))' \
      >/dev/null 2>&1; then
    return 0
  fi

  # A clean success result with no ralph tool_use means the tools did not register.
  # Anything else (API/auth error, empty output, non-zero exit) is infrastructure,
  # not a registration failure, so we must not block plans on it.
  if printf '%s\n' "$out" \
    | jq -e 'select(.type=="result" and ((.is_error // false) | not) and (.subtype == "success"))' \
      >/dev/null 2>&1; then
    echo "Error: claude ran but never invoked ${probe_tool}; the ralph MCP tools are not registering in this claude build (likely a tools/list response shape it rejects)." >&2
    return 1
  fi

  echo "Note: claude CLI MCP preflight inconclusive (cli exit=$cli_status; likely auth, credit, or rate limit). Skipping the live gate." >&2
  return 2
}

ralph_mcp_overlay_lifecycle_available() {
  if ! declare -F runtime_overlay_record_external_temp_file >/dev/null 2>&1; then
    return 1
  fi
  if [[ -n "${RUNTIME_OVERLAY_STATE_DIR:-}" || "${_RALPH_RUNTIME_OVERLAY_ACTIVE:-0}" == "1" ]]; then
    return 0
  fi
  return 1
}

ralph_mcp_overlay_record_temp_file() {
  local path="${1:-}"
  if [[ -z "$path" ]]; then
    return 0
  fi
  if ralph_mcp_overlay_lifecycle_available; then
    runtime_overlay_record_external_temp_file "$path"
  fi
}

ralph_mcp_overlay_record_workspace_mutation() {
  local target="${1:-}"
  local had_file="${2:-0}"
  if [[ -z "$target" ]] || ! ralph_mcp_overlay_lifecycle_available; then
    return 0
  fi
  if [[ "$had_file" == "1" ]]; then
    if declare -F runtime_overlay_record_original_file >/dev/null 2>&1; then
      runtime_overlay_record_original_file "$target"
    fi
  elif declare -F runtime_overlay_record_generated_file >/dev/null 2>&1; then
    runtime_overlay_record_generated_file "$target"
  fi
}

ralph_mcp_overlay_register_runtime_cleanup() {
  local cleanup_fn="${1:-}"
  if [[ -z "$cleanup_fn" ]]; then
    return 0
  fi
  if declare -F ralph_runtime_overlay_chain_exit_trap >/dev/null 2>&1; then
    ralph_runtime_overlay_chain_exit_trap "$cleanup_fn"
    return 0
  fi
  if declare -F runtime_overlay_register_cleanup >/dev/null 2>&1; then
    runtime_overlay_register_cleanup "$cleanup_fn"
    return 0
  fi
  # Unit tests and other callers without run-plan overlay still need temp MCP cleanup.
  trap "$cleanup_fn" EXIT
}

ralph_mcp_server_script_path() { ralph_mcp_proxy_server_script_path "$@"; }
ralph_mcp_generate_config() { ralph_mcp_proxy_generate_config "$@"; }
ralph_mcp_cleanup_config() { ralph_mcp_proxy_cleanup_config "$@"; }
ralph_mcp_preflight() { ralph_mcp_proxy_preflight "$@"; }

ralph_mcp_codex_strict_proxy_active() {
  case "${RALPH_AGENT_TOOL_ACCESS:-}" in
    ralph) ;;
    *) return 1 ;;
  esac
  [[ "${RALPH_AGENT_TOOL_ACCESS_REQUIRE_PROXY:-0}" == "1" || "${RALPH_STRICT_PROXY:-0}" == "1" ]]
}
