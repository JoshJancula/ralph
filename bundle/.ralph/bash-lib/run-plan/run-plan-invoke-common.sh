#!/usr/bin/env bash

if [[ -n "${RALPH_RUN_PLAN_INVOKE_COMMON_LOADED:-}" ]]; then
  return
fi
RALPH_RUN_PLAN_INVOKE_COMMON_LOADED=1

_ralph_invoke_common_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F ralph_apply_mode_compaction_defaults >/dev/null 2>&1; then
  # shellcheck source=run-plan-args.sh
  source "$_ralph_invoke_common_dir/run-plan-args.sh"
fi

# Derive legacy internal knobs from RALPH_MODE for direct invoke-helper callers
# (unit tests and scripts that set RALPH_MODE without running parse_args).
ralph_run_plan_sync_mode_knobs() {
  local mode="${RALPH_MODE:-no}"
  local _native_hooks_target
  local _agent_tool_access_target
  case "$mode" in
    no)
      _agent_tool_access_target="native"
      _native_hooks_target="off"
      ;;
    native)
      _agent_tool_access_target="native"
      _native_hooks_target="auto"
      ;;
    ralph)
      _agent_tool_access_target="ralph"
      _native_hooks_target="off"
      ;;
    hybrid)
      _agent_tool_access_target="ralph"
      _native_hooks_target="auto"
      ;;
    *)
      _agent_tool_access_target="native"
      _native_hooks_target="off"
      ;;
  esac
  # When RALPH_MODE is explicitly set, always derive from it.
  # When RALPH_MODE is not set (defaulted), only set if not already set,
  # so that callers that set RALPH_AGENT_TOOL_ACCESS or RALPH_NATIVE_HOOKS directly
  # have their value respected.
  if [[ -n "${RALPH_MODE:-}" || -z "${RALPH_AGENT_TOOL_ACCESS:-}" ]]; then
    RALPH_AGENT_TOOL_ACCESS="$_agent_tool_access_target"
  fi
  if [[ -n "${RALPH_MODE:-}" || -z "${RALPH_NATIVE_HOOKS:-}" ]]; then
    RALPH_NATIVE_HOOKS="$_native_hooks_target"
  fi
  export RALPH_AGENT_TOOL_ACCESS RALPH_NATIVE_HOOKS
  case "$mode" in
    ralph|hybrid) RALPH_MCP_TOOLS_ENABLED=1 ;;
    *) RALPH_MCP_TOOLS_ENABLED=0 ;;
  esac
  export RALPH_MCP_TOOLS_ENABLED
  ralph_apply_mode_compaction_defaults "$mode"
}

# Public interface:
#   run_plan_invoke_common_add_model_flag -- append --model (or custom flag) from SELECTED_MODEL.
#   run_plan_invoke_common_add_resume_args -- dispatch session vs bare resume argv builders.
#   run_plan_invoke_common_add_cli_resume_flags -- append runtime-specific JSON/resume flags when python3 exists.
#   run_plan_invoke_common_execute -- pipe CLI through demux+tee or plain tee; writes EXIT_CODE_FILE.

run_plan_invoke_common_add_model_flag() {
  local args_name="$1"
  local flag="${2:---model}"

  if [[ -n "${SELECTED_MODEL:-}" ]]; then
    eval "$args_name+=(\"$flag\" \"\${SELECTED_MODEL}\")"
  fi
}

run_plan_invoke_common_add_resume_args() {
  local args_name="$1"
  local session_fn="$2"
  local new_fn="$3"
  local bare_fn="$4"
  local warn_fn="$5"

  if [[ -n "${RALPH_RUN_PLAN_NEW_SESSION_ID:-}" ]]; then
    "$new_fn" "$args_name"
  elif [[ -n "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]]; then
    "$session_fn" "$args_name"
  elif [[ "${RALPH_RUN_PLAN_RESUME_BARE:-0}" == "1" ]]; then
    if [[ "${RALPH_PLAN_ALLOW_UNSAFE_RESUME:-0}" == "1" ]]; then
      "$bare_fn" "$args_name"
    else
      "$warn_fn"
    fi
  fi
}

run_plan_invoke_common_add_cli_resume_flags() {
  local args_name="$1"
  shift
  local flags=("$@")

  if [[ ( "${RALPH_PLAN_CLI_RESUME:-0}" == "1" || "${RALPH_PLAN_CAPTURE_USAGE:-1}" == "1" ) ]] && command -v python3 &>/dev/null; then
    local flag
    for flag in "${flags[@]}"; do
      eval "$args_name+=(\"$flag\")"
    done
  fi
}

run_plan_invoke_common_execute() {
  local runner_fn="$1"
  local runtime="$2"
  local python_warning="$3"
  local pretty_mode="${RALPH_PLAN_PRETTY:-auto}"
  local _pretty="0"

  local demux_py
  demux_py="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../python/run-plan-cli-json-demux.py"

  case "$pretty_mode" in
    1) _pretty="1" ;;
    0) _pretty="0" ;;
    *)
      if [[ -t 1 && -z "${NO_COLOR:-}" && "${CURSOR_PLAN_NO_COLOR:-0}" != "1" && "${RALPH_PLAN_NO_COLOR:-0}" != "1" ]]; then
        _pretty="1"
      fi
      ;;
  esac

  # USAGE_FILE receives token usage JSON from demux when JSON streaming is active.
  export USAGE_FILE="${USAGE_FILE:-}"
  if [[ -z "$USAGE_FILE" && -n "${EXIT_CODE_FILE:-}" ]]; then
    # Match run-plan-core naming: .plan-runner-usage.<pid>.json (not .plan-runner-exit.<pid>.usage...)
    _exit_base="${EXIT_CODE_FILE%.$$}"
    USAGE_FILE="${_exit_base/.plan-runner-exit/.plan-runner-usage}.$$.json"
  fi

  local exit_code
  if [[ -n "${RALPH_PLAN_INVOCATION_CLI_START_FILE:-}" ]]; then
    date +%s >"$RALPH_PLAN_INVOCATION_CLI_START_FILE" 2>/dev/null || true
  fi
  if [[ ( "${RALPH_PLAN_CLI_RESUME:-0}" == "1" || "${RALPH_PLAN_CAPTURE_USAGE:-1}" == "1" ) ]] && command -v python3 &>/dev/null; then
    if [[ -n "${OUTPUT_LOG:-}" ]]; then
      "$runner_fn" 2>&1 | python3 "$demux_py" "$runtime" "${SESSION_ID_FILE:-}" "${USAGE_FILE:-}" "$OUTPUT_LOG" "$_pretty"
    else
      "$runner_fn" 2>&1 | python3 "$demux_py" "$runtime" "${SESSION_ID_FILE:-}" "${USAGE_FILE:-}" | tee -a "$OUTPUT_LOG"
    fi
    exit_code="${PIPESTATUS[0]}"
  else
    if [[ "${RALPH_PLAN_CLI_RESUME:-0}" == "1" ]] && [[ -n "$python_warning" ]]; then
      echo "$python_warning" >&2
    fi
    "$runner_fn" 2>&1 | tee -a "$OUTPUT_LOG"
    exit_code="${PIPESTATUS[0]}"
  fi
  echo "$exit_code" >"$EXIT_CODE_FILE"
}
