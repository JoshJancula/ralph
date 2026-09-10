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
#   run_plan_invoke_claude_mcp_config_prepare / run_plan_invoke_claude_mcp_config_cleanup -- ralph-mode ephemeral MCP config containing only the ralph server.
#   run_plan_invoke_claude_mcp_prepare_ralph_layer -- validate + prepare that ephemeral config for the "layered" (non-strict) MCP lockdown mode.
#   run_plan_invoke_claude_native_hooks_prepare / run_plan_invoke_claude_native_hooks_cleanup -- dynamic Claude hook settings overlay.
#   run_plan_invoke_claude_permission_mode_validate -- normalize CLAUDE_PLAN_PERMISSION_MODE.
#   run_plan_invoke_claude_session_resume_args / run_plan_invoke_claude_session_new_args / run_plan_invoke_claude_bare_resume_args -- build argv fragments.
#   run_plan_invoke_claude_bare_resume_warn -- stderr warning when bare resume is not allowed.
#   ralph_run_plan_invoke_claude -- run Claude headless with model, tools, resume; exports log/session paths for demux.
#   run_plan_invoke_claude_disallowed_tools_supported -- help-only probe for --disallowedTools (nativeSubagents=off).
#   run_plan_invoke_claude_native_subagents_preflight -- fail closed when off lacks deny-control support.
#   run_plan_invoke_claude_graph_approval_live_supported -- graph help-only live-channel proof (no model call).
#   run_plan_invoke_claude_graph_approval_capabilities -- advertise only enforceable Claude lifetimes.
#   run_plan_invoke_claude_graph_approval_parse_permission -- elevate a fake-adapter event into the G15 contract.
#   run_plan_invoke_claude_graph_approval_apply / restore -- common resumable overlay fallback.
#   run_plan_invoke_claude_graph_approval_start_or_fallback -- live path only after nonbillable proof.
# Env:
#   CLAUDE_PLAN_BARE (truthy enables --bare; default off — requires ANTHROPIC_API_KEY)
#   CLAUDE_PLAN_MINIMAL (truthy enables auth-safe minimal flag composition; default on)
#   CLAUDE_PLAN_MINIMAL_DISABLE_MCP (explicit override for MCP discovery; unset lets the resolved tooling profile decide -- Ralph profile layers a
#     ralph-only --mcp-config over native discovery, raw stays locked down with --strict-mcp-config and an empty catalog. Explicit 1/true/yes/on always
#     locks down with an empty catalog even for a Ralph profile. Explicit 0/false/no/off always permits native discovery: Ralph profile still layers its
#     ralph-only config non-strictly on top, raw leaves native discovery completely alone.)
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
  # mcp_lockdown_mode (4th arg) controls how MCP discovery is composed:
  #   lockdown (default) -- --strict-mcp-config plus mcp_config_path, or an
  #                          empty {"mcpServers":{}} catalog when no path is
  #                          given. Disables native ambient/CLI MCP discovery.
  #   layered            -- --mcp-config mcp_config_path with NO
  #                          --strict-mcp-config, so native discovery still
  #                          runs and the given config (e.g. the Ralph-only
  #                          server) is layered on top of it.
  #   native             -- no MCP flags at all; native discovery is left
  #                          completely alone.
  local mcp_lockdown_mode="${4:-lockdown}"
  if [[ "${RALPH_RUN_PLAN_RESET_COMMAND_USED:-0}" != "1" ]]; then
    eval "$args_name+=(--disable-slash-commands)"
  fi
  case "$mcp_lockdown_mode" in
    layered)
      if [[ -n "$mcp_config_path" ]]; then
        eval "$args_name+=(--mcp-config \"$mcp_config_path\")"
      fi
      ;;
    native)
      ;;
    *)
      if [[ -n "$mcp_config_path" ]]; then
        eval "$args_name+=(--strict-mcp-config)"
        eval "$args_name+=(--mcp-config \"$mcp_config_path\")"
      else
        eval "$args_name+=(--strict-mcp-config)"
        eval "$args_name+=(--mcp-config '{\"mcpServers\":{}}')"
      fi
      ;;
  esac
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

  # Deliberately does NOT prefer RALPH_RUNTIME_MCP_RESOLVE_PATH (the merged
  # ambient+agent+ralph catalog rebuilt by ralph_runtime_config_mcp_resolve).
  # That rebuilt copy loses ambient MCP server state (for example OAuth/session
  # state) that lives outside the config file. Ralph-profile runs always get an
  # ephemeral config containing ONLY the ralph server here, so native discovery
  # (left on by the caller for a Ralph profile) is what surfaces ambient
  # servers, and this call only ever adds Ralph's own server on top.
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

# run_plan_invoke_claude_mcp_prepare_ralph_layer <tools_use>
# Validates the ralph-profile MCP preconditions (bare mode, allowed tools),
# then prepares the ralph-only ephemeral MCP config via
# run_plan_invoke_claude_mcp_config_prepare. On success, CLAUDE_PLAN_MCP_CONFIG_PATH
# / CLAUDE_PLAN_MCP_CONFIG_OWNED are exported by that call for the caller to read.
run_plan_invoke_claude_mcp_prepare_ralph_layer() {
  local tools_use="$1"
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
  printf '%s' "${_ns}ralph_delegated_run_start,${_ns}ralph_delegated_run_status,${_ns}ralph_delegated_run_wait,${_ns}ralph_delegated_run_result,${_ns}ralph_delegated_run_cancel"
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

# run_plan_invoke_claude_disallowed_tools_supported [cli]
# Help-only. Never starts a session or sends a prompt. Returns 0 when the
# installed Claude CLI advertises --disallowedTools (Claude's proven Agent deny).
run_plan_invoke_claude_disallowed_tools_supported() {
  local cli_name="${1:-${CLAUDE_PLAN_CLI:-claude}}"
  local help_text

  if ! command -v "$cli_name" >/dev/null 2>&1; then
    return 1
  fi
  if ! help_text="$("$cli_name" --help 2>/dev/null)"; then
    return 1
  fi
  [[ "$help_text" == *"--disallowedTools"* ]]
}

# run_plan_invoke_claude_native_subagents_preflight [cli]
# nativeSubagents=off requires the proven --disallowedTools deny control before
# invocation. inherit preserves ambient behavior and skips this probe.
run_plan_invoke_claude_native_subagents_preflight() {
  local cli_name="${1:-${CLAUDE_PLAN_CLI:-claude}}"
  local mode

  mode="$(ralph_run_plan_native_subagents_mode)" || return 1
  [[ "$mode" == "off" ]] || return 0

  if run_plan_invoke_claude_disallowed_tools_supported "$cli_name"; then
    return 0
  fi
  echo "Error: nativeSubagents=off requires Claude CLI support for --disallowedTools; refusing to invoke (upgrade Claude CLI or use nativeSubagents=inherit)." >&2
  return 1
}

ralph_run_plan_invoke_claude() {
  ralph_run_plan_sync_mode_knobs
  ralph_run_plan_subagents_log_contract claude || return 1
  ralph_run_plan_subagents_require_runtime_capability claude || return 1
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

  # nativeSubagents=off: verify deny control before building argv / invoking.
  # inherit: skip; do not alter ambient Agent availability.
  if ! run_plan_invoke_claude_native_subagents_preflight "$cli"; then
    return 1
  fi

  local -a args=(-p)
  run_plan_invoke_common_add_model_flag args --model
  if ! run_plan_invoke_common_add_reasoning_effort_flag args claude "$cli"; then
    return 1
  fi
  run_plan_invoke_common_add_structured_output_flag args claude "$cli"

  if [[ -n "${RALPH_CLAUDE_MAX_BUDGET_USD:-}" ]]; then
    args+=(--max-budget-usd "$RALPH_CLAUDE_MAX_BUDGET_USD")
  fi

  if ! run_plan_invoke_claude_bare_mode_validate; then return 1; fi
  if ! run_plan_invoke_claude_minimal_mode_validate; then return 1; fi

  # Capture whether the operator explicitly set the MCP lockdown override
  # BEFORE minimal_mcp_lockdown_validate normalizes/defaults it to "1", so the
  # profile-driven decision below can tell "operator said so" apart from
  # "unset, let the profile decide". CLAUDE_PLAN_MINIMAL_DISABLE_MCP is only
  # ever set here by an explicit env var or the --claude-allow-mcp /
  # --no-claude-allow-mcp flags (see run-plan-args.sh).
  local _mcp_lockdown_explicit=0
  [[ "${CLAUDE_PLAN_MINIMAL_DISABLE_MCP+set}" == "set" ]] && _mcp_lockdown_explicit=1
  if ! run_plan_invoke_claude_minimal_mcp_lockdown_validate; then return 1; fi

  run_plan_invoke_claude_native_hooks_prepare

  # "Ralph profile" below means the Ralph MCP proxy tools are in play for this
  # invocation: RALPH_MODE=ralph, RALPH_MODE=hybrid, or the legacy
  # RALPH_AGENT_TOOL_ACCESS=ralph override. Everything else -- including the
  # tooling-profiles.json "raw" profile, which sets RALPH_MODE=no -- is "raw".
  local _ralph_mode="${RALPH_MODE:-no}"
  local ralph_tools_mode=0
  if [[ "$_ralph_mode" == "ralph" || "$_ralph_mode" == "hybrid" || "${RALPH_AGENT_TOOL_ACCESS:-}" == "ralph" ]]; then
    ralph_tools_mode=1
  fi

  local tools_use
  if [[ "${CLAUDE_PLAN_NO_ALLOWED_TOOLS:-0}" == "1" ]]; then
    tools_use=""
  elif [[ "${CLAUDE_PLAN_ALLOWED_TOOLS+set}" == "set" ]]; then
    tools_use="$CLAUDE_PLAN_ALLOWED_TOOLS"
  else
    tools_use="Bash,Read,Edit,Write"
  fi

  # nativeSubagents=off uses --disallowedTools Agent (proven deny). inherit
  # leaves argv untouched so ambient Agent availability is preserved.
  local subagents_mode
  subagents_mode="$(ralph_run_plan_native_subagents_mode)" || return 1

  # Decide how MCP discovery is composed for this invocation. This is a
  # deliberate contract, not a bug fix: Ralph-profile runs never rebuild
  # ambient MCP servers into a merged, ephemeral --mcp-config (that rebuild
  # loses ambient state -- e.g. OAuth/session state -- that does not live in
  # the config file). Precedence, highest first:
  #   1. Explicit CLAUDE_PLAN_MINIMAL_DISABLE_MCP=1 -- always strict lockdown
  #      with an empty catalog, even for a Ralph profile.
  #   2. Explicit CLAUDE_PLAN_MINIMAL_DISABLE_MCP=0 -- always permits native
  #      discovery. Ralph profile also layers the one-server Ralph config
  #      non-strictly on top; raw leaves native discovery alone entirely.
  #   3. Unset -- the resolved profile decides: Ralph profile layers the
  #      Ralph-only config non-strictly, raw keeps today's strict/empty
  #      lockdown default.
  # See run_plan_invoke_claude_apply_minimal_flags for the argv composition
  # of each mcp_lockdown_mode.
  local mcp_lockdown_mode="lockdown"
  local mcp_config_path=""
  local mcp_overlay_effective=0
  local mcp_overlay_decision=""

  if [[ "$_mcp_lockdown_explicit" == "1" && "${CLAUDE_PLAN_MINIMAL_DISABLE_MCP}" == "1" ]]; then
    mcp_overlay_decision="explicit_lockdown"
  elif [[ "$_mcp_lockdown_explicit" == "1" && "${CLAUDE_PLAN_MINIMAL_DISABLE_MCP}" == "0" ]]; then
    if [[ "$ralph_tools_mode" == "1" ]]; then
      if ! run_plan_invoke_claude_mcp_prepare_ralph_layer "$tools_use"; then
        return 1
      fi
      mcp_config_path="$CLAUDE_PLAN_MCP_CONFIG_PATH"
      mcp_lockdown_mode="layered"
      mcp_overlay_effective=1
      mcp_overlay_decision="explicit_permit_ralph_layered"
    else
      mcp_lockdown_mode="native"
      mcp_overlay_decision="explicit_permit_native"
    fi
  elif [[ "$ralph_tools_mode" == "1" ]]; then
    if ! run_plan_invoke_claude_mcp_prepare_ralph_layer "$tools_use"; then
      return 1
    fi
    mcp_config_path="$CLAUDE_PLAN_MCP_CONFIG_PATH"
    mcp_lockdown_mode="layered"
    mcp_overlay_effective=1
    mcp_overlay_decision="profile_ralph_layered"
  else
    mcp_overlay_decision="profile_raw_lockdown"
  fi

  if declare -F runtime_overlay_set_mcp_override_decisions >/dev/null 2>&1; then
    runtime_overlay_set_mcp_override_decisions "$mcp_overlay_decision"
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
    run_plan_invoke_claude_apply_minimal_flags args "$mcp_config_path" "$tools_use" "$mcp_lockdown_mode"
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

  # Fresh/checkpoint turns pass stable context via --system-prompt for Anthropic prompt caching.
  # The dynamic user turn (PROMPT) excludes that context (set by run-plan-core.sh).
  # Claude ignores --exclude-dynamic-system-prompt-sections when --system-prompt is supplied,
  # so only pass exclude-dynamic on resume/reset paths where PROMPT_STATIC is empty.
  if [[ -n "${PROMPT_STATIC:-}" ]]; then
    args+=(--system-prompt "$PROMPT_STATIC")
  elif [[ "${RALPH_CLAUDE_EXCLUDE_DYNAMIC_SYSTEM_PROMPT_SECTIONS:-1}" == "1" ]]; then
    args+=(--exclude-dynamic-system-prompt-sections)
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

  if [[ -n "$mcp_config_path" ]] && [[ "${CLAUDE_PLAN_MCP_CONFIG_OWNED:-0}" == "1" ]]; then
    run_plan_invoke_claude_mcp_config_cleanup
  fi
  run_plan_invoke_claude_native_hooks_cleanup

  if declare -F runtime_overlay_write_summary >/dev/null 2>&1; then
    runtime_overlay_write_summary || true
  fi
}

# Graph-only Claude approval transport.
# A live structured channel is used only after nonbillable `--help` proof of
# `--permission-prompt-tool`. Otherwise the common resumable overlay is used.
# Advertised lifetimes are only those enforceable without ambient user writes:
# once and run. always-policy is Ralph project policy reapplied through future
# temporary overlays, never a native Claude lifetime.
# Normal non-graph `ralph_run_plan_invoke_claude` does not call these helpers.

run_plan_invoke_claude_graph_approval_graph_enabled() {
  case "${RALPH_GRAPH_APPROVAL:-}" in
    1|true|yes|on)
      return 0
      ;;
  esac
  [[ -n "${RALPH_GRAPH_NODE_ID:-}" ]]
}

_run_plan_invoke_claude_graph_approval_ensure_adapter() {
  if declare -F ralph_approval_adapter_capabilities >/dev/null 2>&1; then
    return 0
  fi
  # shellcheck source=/dev/null
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-plan-approval-adapter.sh"
}

_run_plan_invoke_claude_graph_approval_live_capability_missing() {
  local cli_name="${1:-claude}"
  local help_text
  local -a missing=()

  if ! command -v "$cli_name" >/dev/null 2>&1; then
    printf '%s\n' "claude cli"
    return 0
  fi

  if ! help_text="$("$cli_name" --help 2>/dev/null)"; then
    missing+=("claude permission-prompt-tool")
    printf '%s\n' "${missing[@]}"
    return 0
  fi

  if [[ "$help_text" != *"--permission-prompt-tool"* && "$help_text" != *"permission-prompt-tool"* ]]; then
    missing+=("claude permission-prompt-tool")
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    printf '%s\n' "${missing[@]}"
  fi
}

# run_plan_invoke_claude_graph_approval_live_supported [cli]
# Help-only. Never starts a session or sends a prompt.
run_plan_invoke_claude_graph_approval_live_supported() {
  local cli_name="${1:-${CLAUDE_PLAN_CLI:-claude}}"
  local missing
  missing="$(_run_plan_invoke_claude_graph_approval_live_capability_missing "$cli_name")"
  [[ -z "$missing" ]]
}

# run_plan_invoke_claude_graph_approval_capabilities [cli]
# Overlay can enforce once and run. Live streaming is true only after help proof.
# always-policy stays unsupported: it must not edit ambient user files.
run_plan_invoke_claude_graph_approval_capabilities() {
  local cli_name="${1:-${CLAUDE_PLAN_CLI:-claude}}"
  local live="false"
  local proof

  _run_plan_invoke_claude_graph_approval_ensure_adapter || return 1
  if run_plan_invoke_claude_graph_approval_live_supported "$cli_name"; then
    live="true"
  fi
  proof="$(jq -nc --argjson live "$live" '{
    liveRequestStreaming: $live,
    sameOperationResponse: $live,
    sessionContinuation: true,
    lifetimes: {once: true, run: true, "always-policy": false}
  }')"
  ralph_approval_adapter_capabilities claude "$proof"
}

# run_plan_invoke_claude_graph_approval_parse_permission <fake-adapter-event-json>
# Elevates a Claude fake-adapter permission event into the G15 actionable
# request contract. Choices/lifetimes come only from Claude capabilities
# (once+run; never advertise always-policy).
run_plan_invoke_claude_graph_approval_parse_permission() {
  local raw="${1:-}"
  local fields caps

  if [[ -z "$raw" ]]; then
    echo "Error: Claude graph approval parse requires a permission event" >&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required for Claude graph approval parse" >&2
    return 1
  fi
  if ! printf '%s' "$raw" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "Error: Claude graph approval parse requires a JSON object" >&2
    return 1
  fi
  _run_plan_invoke_claude_graph_approval_ensure_adapter || return 1

  if printf '%s' "$raw" | jq -e '
    def lower($v):
      if $v == null then ""
      elif ($v | type) == "string" then ($v | ascii_downcase)
      else "" end;
    (lower(.tool // .permissionRequest.tool // "")) == "permission"
    and (lower(.action // .permissionRequest.action // "")) == "permission"
    and (lower(.effect // .permissionRequest.effect // "")) == "write"
  ' >/dev/null 2>&1; then
    ralph_approval_adapter_permission_unknown claude \
      "generic permission/permission/write is not actionable"
    return 0
  fi

  fields="$(printf '%s' "$raw" | jq -ce '
    def str($v):
      if $v == null then ""
      elif ($v | type) == "string" then $v
      elif ($v | type) == "number" then ($v | tostring)
      else "" end;
    {
      runtime: "claude",
      sessionId: str(.sessionId // .sessionID // .session // .permissionRequest.sessionId // ""),
      nativeRequestId: str(.nativeRequestId // .requestId // .id // .permissionRequest.nativeRequestId // ""),
      tool: str(.tool // .tool_name // .permissionRequest.tool // ""),
      action: str(.action // .permissionRequest.action // ""),
      resource: str(.resource // .command // .path // .permissionRequest.resource // ""),
      effect: str(.effect // .permissionRequest.effect // ""),
      reason: str(.reason // .permissionRequest.reason // ""),
      expiresAt: (.expiresAt // null)
    }
  ' 2>/dev/null)" || {
    ralph_approval_adapter_permission_unknown claude \
      "Claude permission event is missing actionable identity"
    return 0
  }

  caps="$(run_plan_invoke_claude_graph_approval_capabilities "${CLAUDE_PLAN_CLI:-claude}")" || return 1
  ralph_approval_adapter_build_permission_record "$fields" "$caps"
}

# run_plan_invoke_claude_graph_approval_fallback [reason]
run_plan_invoke_claude_graph_approval_fallback() {
  local reason="${1:-unsupported}"
  if ! command -v jq >/dev/null 2>&1; then
    printf '%s\n' "{\"schemaVersion\":1,\"runtime\":\"claude\",\"fallback\":true,\"reason\":\"${reason}\",\"path\":\"overlay\"}"
    return 0
  fi
  jq -nc --arg reason "$reason" '{
    schemaVersion: 1,
    runtime: "claude",
    fallback: true,
    reason: $reason,
    path: "overlay",
    liveRequestStreaming: false
  }'
}

run_plan_invoke_claude_graph_approval_settings_target() {
  local root="${WORKSPACE:-${RALPH_PROJECT_ROOT:-}}"
  if [[ -z "$root" ]]; then
    echo "Error: Claude graph approval overlay requires WORKSPACE or RALPH_PROJECT_ROOT" >&2
    return 1
  fi
  printf '%s/.claude/settings.json' "$root"
}

# run_plan_invoke_claude_graph_approval_permission_rule <action> <resource> <effect>
run_plan_invoke_claude_graph_approval_permission_rule() {
  local action="$1" resource="$2" effect="$3"
  action="$(printf '%s' "$action" | tr '[:upper:]' '[:lower:]')"
  effect="$(printf '%s' "$effect" | tr '[:upper:]' '[:lower:]')"
  resource="${resource#"${resource%%[![:space:]]*}"}"
  resource="${resource%"${resource##*[![:space:]]}"}"
  if [[ -z "$resource" || "$resource" == *$'\n'* || "$resource" == *')'* ]]; then
    echo "Error: Claude graph approval resource must be a non-empty single line without ')'" >&2
    return 1
  fi
  case "$effect" in
    network)
      printf 'WebFetch(domain:%s)' "$resource"
      ;;
    read)
      case "$action" in
        bash) printf 'Bash(%s)' "$resource" ;;
        *) printf 'Read(%s)' "$resource" ;;
      esac
      ;;
    write)
      case "$action" in
        bash) printf 'Bash(%s)' "$resource" ;;
        write) printf 'Write(%s)' "$resource" ;;
        *) printf 'Edit(%s)' "$resource" ;;
      esac
      ;;
    *)
      echo "Error: Claude graph approval effect is unsupported: ${effect:-<empty>}" >&2
      return 1
      ;;
  esac
}

# Merge a Claude settings object with an exact allow or deny rule. Deny wins.
_run_plan_invoke_claude_graph_approval_merge_settings() {
  local existing="$1"
  local rule="$2"
  local kind="$3"
  if [[ -z "$existing" ]] || ! printf '%s' "$existing" | jq -e 'type == "object"' >/dev/null 2>&1; then
    existing='{}'
  fi
  printf '%s' "$existing" | jq -c --arg rule "$rule" --arg kind "$kind" '
    . as $src
    | (($src.permissions // {}) | type == "object") as $ok
    | (if $ok then ($src.permissions.allow // []) else [] end) as $allow0
    | (if $ok then ($src.permissions.deny // []) else [] end) as $deny0
    | (if ($allow0 | type) == "array" then $allow0 else [] end) as $allow
    | (if ($deny0 | type) == "array" then $deny0 else [] end) as $deny
    | (if $kind == "deny" then ($deny + [$rule] | unique) else $deny end) as $deny1
    | (if $kind == "deny" then [$allow[] | select(. != $rule)]
       elif ($deny1 | index($rule)) == null then ($allow + [$rule] | unique)
       else $allow end) as $allow1
    | ($src + {
        permissions: ((($src.permissions // {}) | if type == "object" then . else {} end) + {
          allow: $allow1,
          deny: $deny1
        })
      })
  '
}

_run_plan_invoke_claude_graph_approval_write_target() {
  local target="$1" overlay_text="$2"
  local existed=0 backup="" tmp_path
  _run_plan_invoke_claude_graph_approval_ensure_adapter || return 1
  ralph_approval_adapter_ensure_overlay_state claude || return 1
  if declare -F _runtime_overlay_abs_path >/dev/null 2>&1; then
    target="$(_runtime_overlay_abs_path "$target")"
  fi
  if ralph_approval_adapter_is_ambient_user_path "$target"; then
    echo "Error: Claude graph approval refuses ambient user path: $target" >&2
    return 1
  fi
  ralph_approval_adapter_overlay_load_state || true
  if [[ -f "$target" ]]; then
    existed=1
  fi
  runtime_overlay_record_original_file "$target" "" 1 || return 1
  if [[ ${#RUNTIME_OVERLAY_MUTATED_BACKUPS[@]} -gt 0 ]]; then
    backup="${RUNTIME_OVERLAY_MUTATED_BACKUPS[${#RUNTIME_OVERLAY_MUTATED_BACKUPS[@]}-1]}"
  fi
  mkdir -p "$(dirname "$target")"
  tmp_path="${target}.ralph-approval.tmp"
  if ! printf '%s\n' "$overlay_text" >"$tmp_path"; then
    runtime_overlay_restore_file "$target" "$backup" "$existed" || true
    echo "Error: Claude graph approval failed to write $target" >&2
    return 1
  fi
  mv "$tmp_path" "$target"
  RALPH_APPROVAL_ADAPTER_OVERLAY_TARGETS+=("$target")
  RALPH_APPROVAL_ADAPTER_OVERLAY_BACKUPS+=("$backup")
  RALPH_APPROVAL_ADAPTER_OVERLAY_EXISTED+=("$existed")
  ralph_approval_adapter_overlay_install_traps
  ralph_approval_adapter_overlay_save_state || true
  jq -nc --arg target "$target" --arg backup "$backup" '{target:$target,backup:(if $backup == "" then null else $backup end)}'
}

# run_plan_invoke_claude_graph_approval_apply <request-json>
# Graph-only. Builds an equal-or-narrower project settings overlay, journals
# the original, and resumes the same session when continuation is supported.
run_plan_invoke_claude_graph_approval_apply() {
  local input="${1:-}"
  local caps translated decision lifetime grant_json
  local action resource effect rule kind
  local target existing overlay_text session_id tmp_dir

  if ! run_plan_invoke_claude_graph_approval_graph_enabled; then
    echo "Error: Claude graph approval apply is graph-only" >&2
    return 1
  fi
  _run_plan_invoke_claude_graph_approval_ensure_adapter || return 1
  if [[ -z "$input" ]] || ! printf '%s' "$input" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "Error: Claude graph approval apply requires a JSON object" >&2
    return 1
  fi
  ralph_approval_adapter_reject_dangerous_fallback "$(printf '%s' "$input" | jq -r '.fallback // empty')" || return 1
  ralph_approval_adapter_reject_dangerous_fallback "$(printf '%s' "$input" | jq -r '.permissionMode // .permission_mode // empty')" || return 1

  caps="$(run_plan_invoke_claude_graph_approval_capabilities "${CLAUDE_PLAN_CLI:-claude}")"
  translated="$(ralph_approval_adapter_translate_decision "$input" "$caps")" || return 1
  decision="$(printf '%s' "$translated" | jq -r '.decision')"
  lifetime="$(printf '%s' "$translated" | jq -r '.lifetime')"
  grant_json="$(printf '%s' "$translated" | jq -c '.grant')"
  session_id="$(printf '%s' "$input" | jq -r '.sessionId // .session_id // empty')"
  target="$(printf '%s' "$input" | jq -r '.target // empty')"
  if [[ -z "$target" ]]; then
    target="$(run_plan_invoke_claude_graph_approval_settings_target)" || return 1
  fi
  if ralph_approval_adapter_is_ambient_user_path "$target"; then
    echo "Error: Claude graph approval refuses ambient user path: $target" >&2
    return 1
  fi

  if [[ "$decision" == "deny" ]]; then
    action="$(printf '%s' "$input" | jq -r '.request.action // .action // "Bash"')"
    resource="$(printf '%s' "$input" | jq -r '.request.resource // .resource // empty')"
    effect="$(printf '%s' "$input" | jq -r '.request.effect // .effect // "write"')"
    kind="deny"
  else
    action="$(printf '%s' "$grant_json" | jq -r '.action')"
    resource="$(printf '%s' "$grant_json" | jq -r '.resource')"
    effect="$(printf '%s' "$grant_json" | jq -r '.effect')"
    kind="allow"
  fi
  rule="$(run_plan_invoke_claude_graph_approval_permission_rule "$action" "$resource" "$effect")" || return 1

  existing="{}"
  if [[ -f "$target" ]]; then
    existing="$(cat "$target")"
  fi
  overlay_text="$(_run_plan_invoke_claude_graph_approval_merge_settings "$existing" "$rule" "$kind")" || return 1

  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/ralph-claude-approval.XXXXXX")" || return 1

  if [[ "$decision" == "deny" ]]; then
    if ! _run_plan_invoke_claude_graph_approval_write_target "$target" "$overlay_text" >"$tmp_dir/write.json"; then
      rm -rf "$tmp_dir"
      return 1
    fi
    if ! ralph_approval_adapter_overlay_fallback "$(jq -nc --arg runtime claude '{decision:"deny",runtime:$runtime}')" "$caps" >"$tmp_dir/fallback.json"; then
      rm -rf "$tmp_dir"
      return 1
    fi
    jq -nc \
      --argjson applied "$(cat "$tmp_dir/fallback.json")" \
      --argjson write "$(cat "$tmp_dir/write.json")" \
      --argjson grant "$grant_json" \
      --arg lifetime "$lifetime" \
      --arg decision "$decision" \
      --arg session "$session_id" \
      --arg overlay "$overlay_text" \
      '{
        schemaVersion: 1,
        runtime: "claude",
        path: "overlay",
        fallback: "overlay",
        applied: true,
        decision: $decision,
        lifetime: $lifetime,
        grant: $grant,
        equalOrNarrower: true,
        continuation: $applied.continuation,
        sessionStrategy: $applied.sessionStrategy,
        sessionId: (if $session == "" then null else $session end),
        target: $write.target,
        backup: $write.backup,
        restored: false,
        overlay: ($overlay | fromjson)
      }'
    rm -rf "$tmp_dir"
    return 0
  fi

  if ! ralph_approval_adapter_overlay_fallback "$(jq -nc \
    --arg runtime claude \
    --arg decision "$decision" \
    --arg target "$target" \
    --arg session "$session_id" \
    --argjson grant "$grant_json" \
    --argjson overlay "$overlay_text" \
    --arg action "$action" \
    --arg resource "$resource" \
    --arg effect "$effect" \
    '{
      decision: $decision,
      runtime: $runtime,
      action: $action,
      resource: $resource,
      effect: $effect,
      grant: $grant,
      target: $target,
      overlay: $overlay,
      sessionId: $session
    }')" "$caps" >"$tmp_dir/applied.json"; then
    rm -rf "$tmp_dir"
    return 1
  fi

  jq -c \
    --argjson overlay "$overlay_text" \
    '. + {runtime:"claude", path:"overlay", overlay:$overlay}' \
    "$tmp_dir/applied.json"
  rm -rf "$tmp_dir"
}

# run_plan_invoke_claude_graph_approval_restore [reason]
run_plan_invoke_claude_graph_approval_restore() {
  _run_plan_invoke_claude_graph_approval_ensure_adapter || return 1
  ralph_approval_adapter_overlay_restore "${1:-success}"
}

# run_plan_invoke_claude_graph_approval_start_or_fallback [cli] [request-json]
# Live channel only after nonbillable help proof. Otherwise overlay fallback.
run_plan_invoke_claude_graph_approval_start_or_fallback() {
  local cli="${1:-${CLAUDE_PLAN_CLI:-claude}}"
  local request="${2:-}"
  local caps

  if ! run_plan_invoke_claude_graph_approval_graph_enabled; then
    echo "Error: Claude graph approval is graph-only" >&2
    return 1
  fi
  _run_plan_invoke_claude_graph_approval_ensure_adapter || return 1

  if run_plan_invoke_claude_graph_approval_live_supported "$cli"; then
    caps="$(run_plan_invoke_claude_graph_approval_capabilities "$cli")"
    jq -nc --argjson caps "$caps" '{
      schemaVersion: 1,
      runtime: "claude",
      fallback: false,
      path: "live",
      channel: "permission-prompt-tool",
      liveRequestStreaming: $caps.liveRequestStreaming,
      sameOperationResponse: $caps.sameOperationResponse,
      sessionContinuation: $caps.sessionContinuation,
      lifetimes: $caps.lifetimes
    }'
    return 0
  fi

  if [[ -n "$request" ]]; then
    run_plan_invoke_claude_graph_approval_apply "$request" || return 1
    return 2
  fi
  run_plan_invoke_claude_graph_approval_fallback "unsupported"
  return 2
}
