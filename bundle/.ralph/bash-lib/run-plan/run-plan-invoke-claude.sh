#!/usr/bin/env bash

if [[ -n "${RALPH_RUN_PLAN_INVOKE_CLAUDE_LOADED:-}" ]]; then
  return
fi
RALPH_RUN_PLAN_INVOKE_CLAUDE_LOADED=1

# Public interface:
#   run_plan_invoke_claude_bare_mode_validate -- normalize CLAUDE_PLAN_BARE.
#   run_plan_invoke_claude_minimal_mode_validate -- normalize CLAUDE_PLAN_MINIMAL.
#   run_plan_invoke_claude_minimal_mcp_lockdown_validate -- normalize CLAUDE_PLAN_MINIMAL_DISABLE_MCP.
#   run_plan_invoke_claude_apply_minimal_flags -- append CLAUDE_PLAN_MINIMAL auth-safe flags.
#   run_plan_invoke_claude_mcp_config_prepare / run_plan_invoke_claude_mcp_config_cleanup -- ralph-mode ephemeral MCP config.
#   run_plan_invoke_claude_native_hooks_prepare / run_plan_invoke_claude_native_hooks_cleanup -- dynamic Claude hook settings overlay.
#   run_plan_invoke_claude_permission_mode_validate -- normalize CLAUDE_PLAN_PERMISSION_MODE.
#   run_plan_invoke_claude_session_resume_args / run_plan_invoke_claude_session_new_args / run_plan_invoke_claude_bare_resume_args -- build argv fragments.
#   run_plan_invoke_claude_bare_resume_warn -- stderr warning when bare resume is not allowed.
#   ralph_run_plan_invoke_claude -- run Claude headless with model, tools, resume; exports log/session paths for demux.
# Env:
#   CLAUDE_PLAN_BARE (truthy enables --bare; default off — requires ANTHROPIC_API_KEY)
#   CLAUDE_PLAN_MINIMAL (truthy enables auth-safe minimal flag composition; default on)
#   CLAUDE_PLAN_MINIMAL_DISABLE_MCP (default on: pass --strict-mcp-config and empty --mcp-config when no effective MCP overlay; off loads native MCP discovery)
#   CLAUDE_PLAN_MINIMAL_TOOLS (csv tool names for --tools in minimal mode; default "Bash,Read,Edit,Write")
#   CLAUDE_PLAN_PERMISSION_MODE (one of default, acceptEdits, auto, bypassPermissions, dontAsk, plan; default unset)

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-plan-invoke-common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../mcp/mcp-setup.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../runtime-overlay/runtime-overlay-claude.sh"

run_plan_invoke_claude_session_resume_args() {
  local args_name="$1"
  eval "$args_name+=(--resume \"\${RALPH_RUN_PLAN_RESUME_SESSION_ID}\")"
}

run_plan_invoke_claude_session_new_args() {
  local args_name="$1"
  eval "$args_name+=(--session-id \"\${RALPH_RUN_PLAN_NEW_SESSION_ID}\")"
}

run_plan_invoke_claude_bare_resume_args() {
  local args_name="$1"
  eval "$args_name+=(--resume)"
}

run_plan_invoke_claude_bare_resume_warn() {
  echo "Warning: resume without a session id requires RALPH_PLAN_ALLOW_UNSAFE_RESUME=1 or --allow-unsafe-resume; omitting bare --resume." >&2
}

run_plan_invoke_claude_bare_mode_validate() {
  local bare="${CLAUDE_PLAN_BARE:-0}"
  case "$bare" in
    1|true|yes|on)
      CLAUDE_PLAN_BARE=1
      export CLAUDE_PLAN_BARE
      return 0
      ;;
    0|false|no|off)
      CLAUDE_PLAN_BARE=0
      export CLAUDE_PLAN_BARE
      return 0
      ;;
    *)
      echo "Error: CLAUDE_PLAN_BARE must be one of 1, true, yes, on, 0, false, no, or off." >&2
      return 1
      ;;
  esac
}

run_plan_invoke_claude_minimal_mode_validate() {
  local minimal="${CLAUDE_PLAN_MINIMAL:-1}"
  case "$minimal" in
    1|true|yes|on)
      CLAUDE_PLAN_MINIMAL=1
      export CLAUDE_PLAN_MINIMAL
      return 0
      ;;
    0|false|no|off)
      CLAUDE_PLAN_MINIMAL=0
      export CLAUDE_PLAN_MINIMAL
      return 0
      ;;
    *)
      echo "Error: CLAUDE_PLAN_MINIMAL must be one of 1, true, yes, on, 0, false, no, or off." >&2
      return 1
      ;;
  esac
}

run_plan_invoke_claude_minimal_mcp_lockdown_validate() {
  local lock="${CLAUDE_PLAN_MINIMAL_DISABLE_MCP:-1}"
  case "$lock" in
    1|true|yes|on)
      CLAUDE_PLAN_MINIMAL_DISABLE_MCP=1
      export CLAUDE_PLAN_MINIMAL_DISABLE_MCP
      return 0
      ;;
    0|false|no|off)
      CLAUDE_PLAN_MINIMAL_DISABLE_MCP=0
      export CLAUDE_PLAN_MINIMAL_DISABLE_MCP
      return 0
      ;;
    *)
      echo "Error: CLAUDE_PLAN_MINIMAL_DISABLE_MCP must be one of 1, true, yes, on, 0, false, no, or off." >&2
      return 1
      ;;
  esac
}

run_plan_invoke_claude_setting_sources() {
  printf '%s' "user,project,local"
}

run_plan_invoke_claude_apply_minimal_flags() {
  local args_name="$1"
  local mcp_config_path="${2:-}"
  local tools="${3:-${CLAUDE_PLAN_MINIMAL_TOOLS:-Bash,Read,Edit,Write}}"
  if [[ "${RALPH_RUN_PLAN_RESET_COMMAND_USED:-0}" != "1" ]]; then
    eval "$args_name+=(--disable-slash-commands)"
  fi
  if [[ -n "$mcp_config_path" ]]; then
    eval "$args_name+=(--strict-mcp-config)"
    eval "$args_name+=(--mcp-config \"$mcp_config_path\")"
  elif [[ "${CLAUDE_PLAN_MINIMAL_DISABLE_MCP:-1}" == "1" ]]; then
    eval "$args_name+=(--strict-mcp-config)"
    eval "$args_name+=(--mcp-config '{\"mcpServers\":{}}')"
  fi
  eval "$args_name+=(--setting-sources \"$(run_plan_invoke_claude_setting_sources)\")"
  eval "$args_name+=(--tools \"$tools\")"
}

run_plan_invoke_claude_mcp_config_cleanup() {
  if [[ -n "${CLAUDE_PLAN_MCP_CONFIG_PATH:-}" ]] && [[ "${CLAUDE_PLAN_MCP_CONFIG_OWNED:-0}" == "1" ]]; then
    ralph_mcp_cleanup_config "$CLAUDE_PLAN_MCP_CONFIG_PATH"
  fi
  unset CLAUDE_PLAN_MCP_CONFIG_PATH CLAUDE_PLAN_MCP_CONFIG_OWNED
}

run_plan_invoke_claude_mcp_config_prepare() {
  local config_path="${RALPH_MCP_CONFIG_PATH:-}"
  local owns_config=0

  if [[ -n "${RALPH_RUNTIME_MCP_RESOLVE_PATH:-}" && -f "$RALPH_RUNTIME_MCP_RESOLVE_PATH" ]]; then
    CLAUDE_PLAN_MCP_CONFIG_PATH="$RALPH_RUNTIME_MCP_RESOLVE_PATH"
    CLAUDE_PLAN_MCP_CONFIG_OWNED=0
    export CLAUDE_PLAN_MCP_CONFIG_PATH CLAUDE_PLAN_MCP_CONFIG_OWNED
    return 0
  fi

  if [[ -z "$config_path" ]]; then
    config_path="$(mktemp "${TMPDIR:-/tmp}/ralph-claude-mcp-XXXXXX")"
    owns_config=1
  fi

  if ! ralph_mcp_generate_config claude "$config_path" "$WORKSPACE"; then
    if [[ "$owns_config" == "1" ]]; then
      ralph_mcp_cleanup_config "$config_path"
    fi
    return 1
  fi

  ralph_mcp_overlay_record_temp_file "$config_path"

  CLAUDE_PLAN_MCP_CONFIG_PATH="$config_path"
  CLAUDE_PLAN_MCP_CONFIG_OWNED="$owns_config"
  export CLAUDE_PLAN_MCP_CONFIG_PATH CLAUDE_PLAN_MCP_CONFIG_OWNED
  if [[ "$owns_config" == "1" ]]; then
    ralph_mcp_overlay_register_runtime_cleanup run_plan_invoke_claude_mcp_config_cleanup
  fi
}

ralph_run_plan_invoke_claude_proxy_tool_names() {
  local _old_ifs="$IFS"
  local -a tools_list=()
  local compact_catalog=1

  # Use the tool namespace detected by ralph_mcp_proxy_preflight during the
  # deterministic handshake. Fall back to "mcp__ralph__" (server is always
  # registered as "ralph" in the generated MCP config).
  local _ns="${RALPH_MCP_TOOL_NAMESPACE:-mcp__ralph__}"

  if declare -F ralph_mcp_proxy_compact_tool_catalog_enabled >/dev/null 2>&1; then
    ralph_mcp_proxy_compact_tool_catalog_enabled
    compact_catalog=$?
  else
    case "${RALPH_MCP_COMPACT_TOOL_CATALOG:-}" in
      1 | true | yes | on) compact_catalog=0 ;;
      0 | false | no | off) compact_catalog=1 ;;
      "")
        case "${RALPH_MODE:-no}" in
          ralph | hybrid) compact_catalog=0 ;;
          *) compact_catalog=1 ;;
        esac
        ;;
      *) compact_catalog=2 ;;
    esac
  fi

  case "$compact_catalog" in
    1)
      tools_list=(
        "${_ns}ralph_proxy_read"
        "${_ns}ralph_proxy_grep"
        "${_ns}ralph_proxy_glob"
        "${_ns}ralph_proxy_shell"
        "${_ns}ralph_proxy_result_read"
        "${_ns}ralph_proxy_result_search"
        "${_ns}ralph_proxy_result_summary"
        "${_ns}ralph_proxy_batch"
      )
      ;;
    0)
      tools_list=(
        "${_ns}ralph_proxy_read"
        "${_ns}ralph_proxy_grep"
        "${_ns}ralph_proxy_shell"
        "${_ns}ralph_proxy_result_read"
        "${_ns}ralph_proxy_batch"
        "${_ns}ralph_proxy_tool_search"
      )
      ;;
    *)
      echo "RALPH_MCP_COMPACT_TOOL_CATALOG: invalid value '${RALPH_MCP_COMPACT_TOOL_CATALOG:-}' (use 0 or 1)" >&2
      return 1
      ;;
  esac

  if [[ "${RALPH_MCP_PROXY_POLICY_OWNED_SEARCH_ENABLED:-0}" == "1" ]]; then
    tools_list+=("${_ns}ralph_proxy_search")
  fi
  if [[ "${RALPH_MCP_PROXY_POLICY_OWNED_REPOMAP_ENABLED:-0}" == "1" ]]; then
    tools_list+=("${_ns}ralph_proxy_repomap")
  fi
  if [[ "${RALPH_PROXY_SHELL_ASYNC:-1}" != "0" ]]; then
    tools_list+=(
      "${_ns}ralph_proxy_shell_start"
      "${_ns}ralph_proxy_shell_wait"
      "${_ns}ralph_proxy_shell_status"
      "${_ns}ralph_proxy_shell_read"
      "${_ns}ralph_proxy_shell_cancel"
    )
  fi

  IFS=','
  printf '%s' "${tools_list[*]}"
  IFS="$_old_ifs"
}

ralph_run_plan_invoke_claude_completion_tool_names() {
  local _ns="${RALPH_MCP_TOOL_NAMESPACE:-mcp__ralph__}"
  printf '%s\n' "${_ns}ralph_complete_todo"
}

ralph_run_plan_invoke_claude_delegation_tool_names() {
  [[ "${RALPH_MCP_SCOPE:-operator}" == graph-node ]] || return 0
  local _ns="${RALPH_MCP_TOOL_NAMESPACE:-mcp__ralph__}"
  printf '%s' "${_ns}ralph_delegate_start,${_ns}ralph_delegate_status,${_ns}ralph_delegate_wait,${_ns}ralph_delegate_result,${_ns}ralph_delegate_cancel"
}

ralph_run_plan_invoke_claude_allowed_tools_list() {
  local tools_use="${1:-}"
  local strip_native_read_tools="${2:-0}"
  local strip_native_bash_tools="${3:-0}"
  local _old_ifs="$IFS"
  local -a tools_list=()

  if [[ -z "$tools_use" ]]; then
    tools_use=""
  fi

  IFS=','
  for tool in $tools_use; do
    IFS="$_old_ifs"
    tool="${tool// /}"
    case "$tool" in
      Bash)
        if [[ "$strip_native_bash_tools" == "1" ]]; then
          :
        else
          tools_list+=("$tool")
        fi
        ;;
      Read)
        if [[ "$strip_native_read_tools" == "1" ]]; then
          :
        else
          tools_list+=("$tool")
        fi
        ;;
      Edit|Write)
        tools_list+=("$tool")
        ;;
      "")
        ;;
      *)
        tools_list+=("$tool")
        ;;
    esac
    IFS=','
  done
  IFS="$_old_ifs"

  tools_use="$(ralph_run_plan_invoke_claude_proxy_tool_names)"
  if [[ -n "$tools_use" ]]; then
    IFS=','
    for tool in $tools_use; do
      IFS="$_old_ifs"
      tools_list+=("$tool")
      IFS=','
    done
    IFS="$_old_ifs"
  fi

  tools_use="$(ralph_run_plan_invoke_claude_completion_tool_names)"
  if [[ -n "$tools_use" ]]; then
    IFS=','
    for tool in $tools_use; do
      IFS="$_old_ifs"
      tools_list+=("$tool")
      IFS=','
    done
    IFS="$_old_ifs"
  fi

  tools_use="$(ralph_run_plan_invoke_claude_delegation_tool_names)"
  if [[ -n "$tools_use" ]]; then
    IFS=','
    for tool in $tools_use; do
      IFS="$_old_ifs"
      tools_list+=("$tool")
      IFS=','
    done
    IFS="$_old_ifs"
  fi

  IFS=','
  printf '%s' "${tools_list[*]}"
  IFS="$_old_ifs"
}

run_plan_invoke_claude_permission_mode_validate() {
  local mode="${CLAUDE_PLAN_PERMISSION_MODE:-}"
  case "$mode" in
    default|acceptEdits|auto|bypassPermissions|dontAsk|plan)
      return 0
      ;;
    "")
      return 0
      ;;
    *)
      echo "Error: CLAUDE_PLAN_PERMISSION_MODE must be one of default, acceptEdits, auto, bypassPermissions, dontAsk, or plan." >&2
      return 1
      ;;
  esac
}

ralph_run_plan_invoke_claude() {
  ralph_run_plan_sync_mode_knobs
  ralph_run_plan_subagents_log_contract claude || return 1
  ralph_run_plan_subagents_require_runtime_capability claude || return 1
  # Fail before model invocation when native subagent mode is active but runtime is unproven.
  ralph_run_plan_native_subagent_verify_runtime claude || return 1
  # Inject the native subagent prompt contract into PROMPT_STATIC when mode is read-only.
  ralph_run_plan_native_subagent_append_contract || return 1
  # Paths and flags the Python demux / tee pipeline expects in the environment.
  export OUTPUT_LOG EXIT_CODE_FILE SESSION_ID_FILE

  # Claude-specific session rotation default to cap cache growth (overridable by user).
  : "${RALPH_PLAN_SESSION_MAX_TURNS:=8}"
  export RALPH_PLAN_SESSION_MAX_TURNS

  local cli="${CLAUDE_PLAN_CLI:-}"

  if [[ -z "$cli" ]] && command -v claude &>/dev/null; then
    cli="claude"
  fi

  if [[ -z "$cli" ]] || ! command -v "$cli" &>/dev/null; then
    echo "Error: Claude CLI not found (set CLAUDE_PLAN_CLI or install claude)." >&2
    return 1
  fi

  local -a args=(-p)
  run_plan_invoke_common_add_model_flag args --model
  if ! run_plan_invoke_common_add_reasoning_effort_flag args claude "$cli"; then
    return 1
  fi
  run_plan_invoke_common_add_structured_output_flag args claude "$cli"

  local budget=""
  if [[ -n "${RALPH_CLAUDE_MAX_BUDGET_USD:-}" ]]; then
    budget="$RALPH_CLAUDE_MAX_BUDGET_USD"
  elif [[ -n "${RALPH_AGENT_MAX_BUDGET:-}" ]]; then
    budget="$RALPH_AGENT_MAX_BUDGET"
  fi
  if [[ -n "$budget" ]]; then
    args+=(--max-budget-usd "$budget")
  fi

  if ! run_plan_invoke_claude_bare_mode_validate; then return 1; fi
  if ! run_plan_invoke_claude_minimal_mode_validate; then return 1; fi
  if ! run_plan_invoke_claude_minimal_mcp_lockdown_validate; then return 1; fi

  run_plan_invoke_claude_native_hooks_prepare

  # Use RALPH_MODE and RALPH_AGENT_TOOL_ACCESS to determine MCP injection behavior
  local _ralph_mode="${RALPH_MODE:-no}"
  local ralph_tools_mode=0
  if [[ "$_ralph_mode" == "ralph" || "$_ralph_mode" == "hybrid" || "${RALPH_AGENT_TOOL_ACCESS:-}" == "ralph" ]]; then
    ralph_tools_mode=1
    # Auto-enable MCP when RALPH_MODE is ralph or hybrid
    if [[ "${CLAUDE_PLAN_MINIMAL_DISABLE_MCP:-1}" == "1" ]]; then
      CLAUDE_PLAN_MINIMAL_DISABLE_MCP=0
      export CLAUDE_PLAN_MINIMAL_DISABLE_MCP
    fi
  fi

  local tools_use
  if [[ "${CLAUDE_PLAN_NO_ALLOWED_TOOLS:-0}" == "1" ]]; then
    tools_use=""
  elif [[ "${CLAUDE_PLAN_ALLOWED_TOOLS+set}" == "set" ]]; then
    tools_use="$CLAUDE_PLAN_ALLOWED_TOOLS"
  elif [[ -n "${CLAUDE_TOOLS_FROM_AGENT:-}" ]]; then
    tools_use="$CLAUDE_TOOLS_FROM_AGENT"
  else
    tools_use="Bash,Read,Edit,Write"
  fi

  # `Agent` is Claude's native dispatch tool.  Do this only from the resolved
  # runner contract: inherit deliberately leaves the historical argv untouched.
  local subagents_mode
  subagents_mode="$(ralph_run_plan_subagents_mode)" || return 1
  case "$subagents_mode" in
    on)
      case ",$tools_use," in
        *,Agent,*) ;;
        *) tools_use="${tools_use:+$tools_use,}Agent" ;;
      esac
      ;;
    off)
      # A deny flag is needed even when an ambient/native agent profile adds
      # Agent after Ralph selected its normal allowed-tools list.
      ;;
  esac

  local mcp_config_path=""
  local mcp_overlay_effective=0
  if [[ -n "${RALPH_RUNTIME_MCP_RESOLVE_PATH:-}" && -f "$RALPH_RUNTIME_MCP_RESOLVE_PATH" ]]; then
    mcp_config_path="$RALPH_RUNTIME_MCP_RESOLVE_PATH"
    CLAUDE_PLAN_MCP_CONFIG_PATH="$mcp_config_path"
    CLAUDE_PLAN_MCP_CONFIG_OWNED=0
    export CLAUDE_PLAN_MCP_CONFIG_PATH CLAUDE_PLAN_MCP_CONFIG_OWNED
    mcp_overlay_effective=1
  elif [[ "$ralph_tools_mode" == "1" ]]; then
    if [[ "${CLAUDE_PLAN_BARE:-0}" == "1" ]]; then
      echo "Error: Agent Tool Access (ralph) is incompatible with CLAUDE_PLAN_BARE=1 because ralph mode needs the auth-safe minimal path to inject the MCP config. Re-run with --no-claude-bare (or unset CLAUDE_PLAN_BARE)." >&2
      return 1
    fi
    if [[ -z "$tools_use" ]]; then
      echo "Error: Agent Tool Access (ralph) requires --allowedTools so the tool surface can match the CLI tool surface. Re-run without CLAUDE_PLAN_NO_ALLOWED_TOOLS=1." >&2
      run_plan_invoke_claude_native_hooks_cleanup
      return 1
    fi
    if ! run_plan_invoke_claude_mcp_config_prepare; then
      run_plan_invoke_claude_native_hooks_cleanup
      return 1
    fi
    mcp_config_path="$CLAUDE_PLAN_MCP_CONFIG_PATH"
    mcp_overlay_effective=1
  fi
  if [[ "$mcp_overlay_effective" == "1" ]]; then
    if declare -F runtime_overlay_set_mcp_effective >/dev/null 2>&1; then
      runtime_overlay_set_mcp_effective "true"
    fi
  elif declare -F runtime_overlay_set_mcp_effective >/dev/null 2>&1; then
    runtime_overlay_set_mcp_effective "false"
  fi
  if [[ "$ralph_tools_mode" == "1" ]]; then

    if [[ "${RALPH_MCP_PREFLIGHT_PASSED:-0}" == "1" ]] && [[ "${RALPH_CLAUDE_RALPH_STRICT_PROXY+set}" != "set" ]] && { [[ "${_ralph_mode}" == "ralph" ]] || [[ "${RALPH_AGENT_TOOL_ACCESS:-}" == "ralph" ]]; }; then
      RALPH_CLAUDE_RALPH_STRICT_PROXY=1
      export RALPH_CLAUDE_RALPH_STRICT_PROXY
    fi

    # In ralph strict-proxy mode we replace native Bash with the bounded
    # ralph_proxy_shell once preflight proves Claude can reach the proxy.
    #
    # We deliberately do NOT strip native Read by default. Claude Code's Edit and
    # Write tools refuse to modify an existing file unless it was first read by
    # the native Read tool ("File has not been read yet. Read it first before
    # writing to it."), and a ralph_proxy_read does not satisfy that internal
    # read-tracking. Stripping native Read therefore deadlocks every edit/write of
    # an existing file -- the agent can neither Read (stripped) nor Edit (needs a
    # prior native Read) and correctly bails. Native Read stays available (proxy
    # reads are still preferred for bounded large reads via prompt guidance).
    # Set RALPH_CLAUDE_RALPH_STRICT_PROXY_STRIP_READ=1 only for read-only/analysis
    # plans that never modify existing files.
    local strip_native_read_tools=0
    local strip_native_bash_tools=0
    case "${RALPH_CLAUDE_RALPH_STRICT_PROXY:-0}" in
      1|true|yes|on)
        if [[ "${RALPH_MCP_PREFLIGHT_PASSED:-0}" == "1" ]]; then
          strip_native_bash_tools=1
          case "${RALPH_CLAUDE_RALPH_STRICT_PROXY_STRIP_READ:-0}" in
            1|true|yes|on)
              strip_native_read_tools=1
              ;;
          esac
        fi
        ;;
    esac

    tools_use="$(ralph_run_plan_invoke_claude_allowed_tools_list "$tools_use" "$strip_native_read_tools" "$strip_native_bash_tools")"
  fi

  local _bare_idx=-1
  if [[ "${CLAUDE_PLAN_BARE:-0}" == "1" ]]; then
    _bare_idx=${#args[@]}
    # `--bare` skips hooks, LSP, plugin sync, attribution, auto-memory, prefetches,
    # keychain reads, and CLAUDE.md auto-discovery. It lowers overhead but also
    # removes automatic context sources.
    args+=(--bare)
  elif [[ "${CLAUDE_PLAN_MINIMAL:-1}" == "1" || "$ralph_tools_mode" == "1" ]]; then
    run_plan_invoke_claude_apply_minimal_flags args "$mcp_config_path" "$tools_use"
  fi

  if ! run_plan_invoke_claude_permission_mode_validate; then
    if [[ -n "$mcp_config_path" ]] && [[ "${CLAUDE_PLAN_MCP_CONFIG_OWNED:-0}" == "1" ]]; then
      run_plan_invoke_claude_mcp_config_cleanup
    fi
    run_plan_invoke_claude_native_hooks_cleanup
    return 1
  fi
  if [[ -n "${CLAUDE_PLAN_PERMISSION_MODE:-}" ]]; then
    # Modes like `auto` and `bypassPermissions` can reduce or skip approval prompts.
    args+=(--permission-mode "$CLAUDE_PLAN_PERMISSION_MODE")
  fi

  if [[ -n "$tools_use" ]]; then
    args+=(--allowedTools "$tools_use")
  fi
  if [[ "$subagents_mode" == "off" ]]; then
    args+=(--disallowedTools Agent)
  fi

  run_plan_invoke_common_add_resume_args \
    args \
    run_plan_invoke_claude_session_resume_args \
    run_plan_invoke_claude_session_new_args \
    run_plan_invoke_claude_bare_resume_args \
    run_plan_invoke_claude_bare_resume_warn
  run_plan_invoke_common_add_cli_resume_flags args --verbose --output-format stream-json

  # Native --agent flag passthrough (adapter-native-md phase):
  # When RALPH_AGENT_NATIVE_NAME is set and RALPH_AGENT_NATIVE_PASSTHROUGH is on,
  # add --agent flag and suppress the agent-derived --system-prompt context.
  # The claude CLI --agent <name> flag:
  # - Coexists without conflicts alongside --allowedTools, --mcp-config
  # - Is a session/identity override flag (not a file resolver)
  # - Does NOT auto-discover local .claude/agents/<name>.md files
  # - Requires pre-registered agents in Claude app config or fails with unknown-agent
  local _native_passthrough_idx=-1
  if [[ -n "${RALPH_AGENT_NATIVE_NAME:-}" ]] && [[ "${RALPH_AGENT_NATIVE_PASSTHROUGH}" != "0" ]]; then
    args+=("--agent" "$RALPH_AGENT_NATIVE_NAME")
    _native_passthrough_idx=$((${#args[@]} - 2))
  fi

  # Fresh/checkpoint turns pass stable context via --system-prompt for Anthropic prompt caching.
  # The dynamic user turn (PROMPT) excludes that context (set by run-plan-core.sh).
  # Claude ignores --exclude-dynamic-system-prompt-sections when --system-prompt is supplied,
  # so only pass exclude-dynamic on resume/reset paths where PROMPT_STATIC is empty.
  # Skip --system-prompt when native passthrough is active (agent context comes from Claude).
  if [[ $_native_passthrough_idx -lt 0 ]]; then
    if [[ -n "${PROMPT_STATIC:-}" ]]; then
      args+=(--system-prompt "$PROMPT_STATIC")
    elif [[ "${RALPH_CLAUDE_EXCLUDE_DYNAMIC_SYSTEM_PROMPT_SECTIONS:-1}" == "1" ]]; then
      args+=(--exclude-dynamic-system-prompt-sections)
    fi
  fi

  run_plan_invoke_claude_cli() {
    local agent_ws="${RALPH_AGENT_WORKSPACE:-$(pwd)}"
    printf '%s' "$PROMPT" | (
      cd "$agent_ws" || exit 1
      run_plan_invoke_common_launch_cli claude "$cli" "${args[@]}"
    )
  }

  run_plan_invoke_common_execute \
    run_plan_invoke_claude_cli \
    claude \
    "Warning: RALPH_PLAN_CLI_RESUME needs python3 to parse stream-json and update session-id.claude.txt; running without it."

  if [[ $_bare_idx -ge 0 ]] && [[ -s "$EXIT_CODE_FILE" ]] && [[ "$(cat "$EXIT_CODE_FILE")" != "0" ]] && [[ -s "$OUTPUT_LOG" ]] && [[ "$(cat "$OUTPUT_LOG")" == *"Not logged in"* || "$(cat "$OUTPUT_LOG")" == *"Please run /login"* ]]; then
    args=("${args[@]:0:_bare_idx}" "${args[@]:_bare_idx+1}")
    CLAUDE_PLAN_BARE=0
    export CLAUDE_PLAN_BARE
    CLAUDE_PLAN_MINIMAL=1
    export CLAUDE_PLAN_MINIMAL
    run_plan_invoke_claude_apply_minimal_flags args
    echo "Note: claude reported 'Not logged in' with --bare (which skips keychain reads). Retrying once with CLAUDE_PLAN_MINIMAL=1 instead and persisting that for the rest of this process. Set ANTHROPIC_API_KEY (or unset CLAUDE_PLAN_BARE to use the safe default) to silence." >&2
    rm -f "${RALPH_PLAN_INVOCATION_CLI_PID_FILE:-}" 2>/dev/null || true
    run_plan_invoke_common_execute \
      run_plan_invoke_claude_cli \
      claude \
      "Warning: RALPH_PLAN_CLI_RESUME needs python3 to parse stream-json and update session-id.claude.txt; running without it."
  fi

  # Native passthrough fallback: if --agent failed due to unknown agent and passthrough was active,
  # retry with inlined context and suppress --agent flag (mirror --bare login fallback).
  if [[ $_native_passthrough_idx -ge 0 ]] && [[ -s "$EXIT_CODE_FILE" ]] && [[ "$(cat "$EXIT_CODE_FILE")" != "0" ]] && [[ -s "$OUTPUT_LOG" ]] && [[ "$(cat "$OUTPUT_LOG")" == *"unknown agent"* || "$(cat "$OUTPUT_LOG")" == *"agent not found"* ]]; then
    # Remove --agent flag and its argument
    args=("${args[@]:0:_native_passthrough_idx}" "${args[@]:$((_native_passthrough_idx+2))}")
    # Re-add --system-prompt with inlined context (fallback to PREBUILT_AGENT_CONTEXT if available)
    if [[ -n "${PREBUILT_AGENT_CONTEXT:-}" ]]; then
      local _fallback_prompt_static="${PROMPT_STATIC:-}${PREBUILT_AGENT_CONTEXT}"
      if [[ -n "$_fallback_prompt_static" ]]; then
        args+=(--system-prompt "$_fallback_prompt_static")
      fi
    fi
    echo "Note: claude reported unknown agent with --agent '$RALPH_AGENT_NATIVE_NAME'. Retrying once without --agent flag and with inlined context. Register the agent in Claude app config or set RALPH_AGENT_NATIVE_PASSTHROUGH=off to use the full inlined mode." >&2
    rm -f "${RALPH_PLAN_INVOCATION_CLI_PID_FILE:-}" 2>/dev/null || true
    run_plan_invoke_common_execute \
      run_plan_invoke_claude_cli \
      claude \
      "Warning: RALPH_PLAN_CLI_RESUME needs python3 to parse stream-json and update session-id.claude.txt; running without it."
  fi

  if [[ -n "$mcp_config_path" ]] && [[ "${CLAUDE_PLAN_MCP_CONFIG_OWNED:-0}" == "1" ]]; then
    run_plan_invoke_claude_mcp_config_cleanup
  fi
  run_plan_invoke_claude_native_hooks_cleanup

  if declare -F runtime_overlay_write_summary >/dev/null 2>&1; then
    runtime_overlay_write_summary || true
  fi
}
