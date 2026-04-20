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
#   run_plan_invoke_claude_permission_mode_validate -- normalize CLAUDE_PLAN_PERMISSION_MODE.
#   run_plan_invoke_claude_session_resume_args / run_plan_invoke_claude_session_new_args / run_plan_invoke_claude_bare_resume_args -- build argv fragments.
#   run_plan_invoke_claude_bare_resume_warn -- stderr warning when bare resume is not allowed.
#   ralph_run_plan_invoke_claude -- run Claude headless with model, tools, resume; exports log/session paths for demux.
# Env:
#   CLAUDE_PLAN_BARE (truthy enables --bare; default off — requires ANTHROPIC_API_KEY)
#   CLAUDE_PLAN_MINIMAL (truthy enables auth-safe minimal flag composition; default on)
#   CLAUDE_PLAN_MINIMAL_DISABLE_MCP (default on: pass --strict-mcp-config and empty --mcp-config in minimal mode; off loads project MCP)
#   CLAUDE_PLAN_MINIMAL_TOOLS (csv tool names for --tools in minimal mode; default "Bash,Read,Edit,Write")
#   CLAUDE_PLAN_PERMISSION_MODE (one of default, acceptEdits, auto, bypassPermissions, dontAsk, plan; default unset)

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-plan-invoke-common.sh"

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

run_plan_invoke_claude_apply_minimal_flags() {
  local args_name="$1"
  local tools="${CLAUDE_PLAN_MINIMAL_TOOLS:-Bash,Read,Edit,Write}"
  if [[ "${RALPH_RUN_PLAN_RESET_COMMAND_USED:-0}" != "1" ]]; then
    eval "$args_name+=(--disable-slash-commands)"
  fi
  if [[ "${CLAUDE_PLAN_MINIMAL_DISABLE_MCP:-1}" == "1" ]]; then
    eval "$args_name+=(--strict-mcp-config)"
    eval "$args_name+=(--mcp-config '{\"mcpServers\":{}}')"
  fi
  eval "$args_name+=(--setting-sources project,local)"
  eval "$args_name+=(--tools \"$tools\")"
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

  if [[ "${RALPH_CLAUDE_EXCLUDE_DYNAMIC_SYSTEM_PROMPT_SECTIONS:-1}" == "1" ]]; then
    args+=(--exclude-dynamic-system-prompt-sections)
  fi

  local budget=""
  if [[ -n "${RALPH_CLAUDE_MAX_BUDGET_USD:-}" ]]; then
    budget="$RALPH_CLAUDE_MAX_BUDGET_USD"
  elif [[ -n "${RALPH_AGENT_MAX_BUDGET:-}" ]]; then
    budget="$RALPH_AGENT_MAX_BUDGET"
  else
    case "${PREBUILT_AGENT:-}" in
      research)     budget="0.50" ;;
      code-review)  budget="1.00" ;;
      security)     budget="1.00" ;;
      architect)    budget="2.00" ;;
      qa)           budget="2.00" ;;
      implementation) budget="5.00" ;;
      *)            budget="3.00" ;;
    esac
  fi
  if [[ -n "$budget" ]]; then
    args+=(--max-budget-usd "$budget")
  fi

  if ! run_plan_invoke_claude_bare_mode_validate; then return 1; fi
  if ! run_plan_invoke_claude_minimal_mode_validate; then return 1; fi
  if ! run_plan_invoke_claude_minimal_mcp_lockdown_validate; then return 1; fi

  local _bare_idx=-1
  if [[ "${CLAUDE_PLAN_BARE:-0}" == "1" ]]; then
    _bare_idx=${#args[@]}
    # `--bare` skips hooks, LSP, plugin sync, attribution, auto-memory, prefetches,
    # keychain reads, and CLAUDE.md auto-discovery. It lowers overhead but also
    # removes automatic context sources.
    args+=(--bare)
  elif [[ "${CLAUDE_PLAN_MINIMAL:-1}" == "1" ]]; then
    run_plan_invoke_claude_apply_minimal_flags args
  fi

  if ! run_plan_invoke_claude_permission_mode_validate; then
    return 1
  fi
  if [[ -n "${CLAUDE_PLAN_PERMISSION_MODE:-}" ]]; then
    # Modes like `auto` and `bypassPermissions` can reduce or skip approval prompts.
    args+=(--permission-mode "$CLAUDE_PLAN_PERMISSION_MODE")
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

  if [[ -n "$tools_use" ]]; then
    args+=(--allowedTools "$tools_use")
  fi

  run_plan_invoke_common_add_resume_args \
    args \
    run_plan_invoke_claude_session_resume_args \
    run_plan_invoke_claude_session_new_args \
    run_plan_invoke_claude_bare_resume_args \
    run_plan_invoke_claude_bare_resume_warn
  run_plan_invoke_common_add_cli_resume_flags args --verbose --output-format stream-json

  # Use --system-prompt with the stable agent context for prompt caching when available.
  # The dynamic user turn (PROMPT) excludes the agent context in this case (set by run-plan-core.sh).
  if [[ -n "${PROMPT_STATIC:-}" ]]; then
    args+=(--system-prompt "$PROMPT_STATIC")
  fi

  run_plan_invoke_claude_cli() {
    printf '%s' "$PROMPT" | "$cli" "${args[@]}"
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
    run_plan_invoke_common_execute \
      run_plan_invoke_claude_cli \
      claude \
      "Warning: RALPH_PLAN_CLI_RESUME needs python3 to parse stream-json and update session-id.claude.txt; running without it."
  fi
}
