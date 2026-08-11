#!/usr/bin/env bash

if [[ -n "${RALPH_RUN_PLAN_INVOKE_COMMON_LOADED:-}" ]]; then
  return
fi
RALPH_RUN_PLAN_INVOKE_COMMON_LOADED=1

# This is the single resolved invocation contract for native subagents.
# Routing owns plan precedence and baseline restoration; adapters must consume
# this variable and must not parse plan metadata themselves.
ralph_run_plan_subagents_mode() {
  local mode="${RALPH_PLAN_SUBAGENTS:-inherit}"
  case "$mode" in
    inherit|on|off) printf '%s' "$mode" ;;
    *)
      echo "Error: resolved subagents mode must be inherit, on, or off (got '$mode')." >&2
      return 1
      ;;
  esac
}

ralph_run_plan_subagents_log_contract() {
  local runtime="$1"
  local mode
  mode="$(ralph_run_plan_subagents_mode)" || return 1
  if declare -F ralph_run_plan_log >/dev/null 2>&1; then
    ralph_run_plan_log "subagents contract: runtime=$runtime mode=$mode"
  fi
}

# The capability matrix is deliberately fail-closed when enabling delegation.
# `off` is portable: Ralph does not add a native dispatch surface, while a
# runtime with a proven surface (currently Claude) also gets its explicit deny
# control. An unsupported runtime may never use `on`.
ralph_run_plan_subagents_require_runtime_capability() {
  local runtime="$1"
  local mode
  mode="$(ralph_run_plan_subagents_mode)" || return 1
  [[ "$mode" == "inherit" || "$mode" == "off" || "$runtime" == "claude" ]] && return 0
  echo "Error: subagents=$mode is unsupported for runtime $runtime until its native delegation capability is proven; refusing to expose ambient delegation." >&2
  return 1
}

# ralph_run_plan_native_subagent_verify_runtime <runtime>
#
# Fail-closed check for native read-only subagent mode. When
# RALPH_PLAN_NATIVE_SUBAGENT_MODE=read-only, the runtime must be in the PROVEN
# set (currently only claude). This check must run before model invocation.
# Returns 0 when the mode is off/unset or the runtime is supported.
# Returns 1 and emits an error when the mode is active but the runtime is not proven.
ralph_run_plan_native_subagent_verify_runtime() {
  local runtime="${1:-}"
  local mode="${RALPH_PLAN_NATIVE_SUBAGENT_MODE:-off}"

  [[ "$mode" != "read-only" ]] && return 0

  # Source the graph-native-subagent library if not already loaded
  local _graph_lib
  _graph_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/../graph" && pwd)/graph-native-subagent.sh"
  if [[ -f "$_graph_lib" ]] && ! declare -F graph_native_subagent_runtime_supported >/dev/null 2>&1; then
    # shellcheck source=../graph/graph-native-subagent.sh
    source "$_graph_lib"
  fi

  if declare -F graph_native_subagent_runtime_supported >/dev/null 2>&1; then
    if ! graph_native_subagent_runtime_supported "$runtime"; then
      echo "Error: RALPH_PLAN_NATIVE_SUBAGENT_MODE=read-only is active but runtime '$runtime' is not supported; refusing to invoke model" >&2
      return 1
    fi
  fi
  return 0
}

# ralph_run_plan_native_subagent_append_contract
#
# When RALPH_PLAN_NATIVE_SUBAGENT_MODE=read-only, appends the stable prompt
# contract to PROMPT_STATIC so the parent model is informed of child constraints.
# Idempotent: the contract marker prevents double-injection.
# Callers should invoke this after PROMPT_STATIC is assembled but before the
# invocation argv is built.
ralph_run_plan_native_subagent_append_contract() {
  local mode="${RALPH_PLAN_NATIVE_SUBAGENT_MODE:-off}"
  [[ "$mode" != "read-only" ]] && return 0

  # Guard against double-injection
  if [[ "${PROMPT_STATIC:-}" == *"Native Subagent Contract"* ]]; then
    return 0
  fi

  local _graph_lib
  _graph_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/../graph" && pwd)/graph-native-subagent.sh"
  if [[ -f "$_graph_lib" ]] && ! declare -F graph_native_subagent_prompt_contract >/dev/null 2>&1; then
    # shellcheck source=../graph/graph-native-subagent.sh
    source "$_graph_lib"
  fi

  if declare -F graph_native_subagent_prompt_contract >/dev/null 2>&1; then
    local node_id="${RALPH_STAGE_ID:-${RALPH_CURRENT_TODO_ID:-unknown}}"
    local contract
    contract="$(graph_native_subagent_prompt_contract "$node_id" "${RALPH_PLAN_NATIVE_SUBAGENT_AGENTS:-}")"
    if [[ -n "${PROMPT_STATIC:-}" ]]; then
      PROMPT_STATIC="${PROMPT_STATIC}"$'\n\n'"${contract}"
    else
      PROMPT_STATIC="${contract}"
    fi
    export PROMPT_STATIC
  fi
  return 0
}

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
  ralph_apply_mode_transcript_eviction_defaults "$mode"
}

# shellcheck source=run-plan-reasoning-effort.sh
source "$_ralph_invoke_common_dir/run-plan-reasoning-effort.sh"
# shellcheck source=run-plan-structured-output.sh
source "$_ralph_invoke_common_dir/run-plan-structured-output.sh"

# Public interface:
#   run_plan_invoke_common_add_model_flag -- append --model (or custom flag) from SELECTED_MODEL.
#   run_plan_invoke_common_add_resume_args -- dispatch session vs bare resume argv builders.
#   run_plan_invoke_common_add_cli_resume_flags -- append runtime-specific JSON/resume flags when python3 exists.
#   run_plan_invoke_common_record_cli_pid -- record live runtime CLI PID to sidecar file.
#   run_plan_invoke_common_launch_cli -- launch through the durable scope supervisor.
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

run_plan_invoke_common_record_cli_pid() {
  local cli_pid="$1"
  if [[ -n "${RALPH_PLAN_INVOCATION_CLI_PID_FILE:-}" ]]; then
    printf '%s\n' "$cli_pid" > "$RALPH_PLAN_INVOCATION_CLI_PID_FILE" 2>/dev/null || true
  fi
}

run_plan_invoke_common_launch_cli() {
  local runtime="$1"
  shift
  if declare -F ralph_process_scope_exec >/dev/null 2>&1 && [[ -n "${RALPH_PROCESS_RUN_DIR:-}" ]]; then
    ralph_process_scope_exec runtime "$runtime" "$@"
    return $?
  fi

  # Direct helper tests and third-party callers may source an invoker outside
  # run-plan. Preserve that API while the actual Ralph runner always initializes
  # the required supervisor before reaching this function.
  "$@" &
  local cli_pid=$!
  run_plan_invoke_common_record_cli_pid "$cli_pid"
  wait "$cli_pid"
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
  local _had_errexit=0
  local _had_pipefail=0
  if [[ $- == *e* ]]; then
    _had_errexit=1
  fi
  if shopt -qo pipefail; then
    _had_pipefail=1
  fi
  if [[ -n "${RALPH_PLAN_INVOCATION_CLI_START_FILE:-}" ]]; then
    date +%s >"$RALPH_PLAN_INVOCATION_CLI_START_FILE" 2>/dev/null || true
  fi
  set +e
  set +o pipefail
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
  if [[ "$_had_pipefail" == "1" ]]; then
    set -o pipefail
  else
    set +o pipefail
  fi
  if [[ "$_had_errexit" == "1" ]]; then
    set -e
  else
    set +e
  fi
  echo "$exit_code" >"$EXIT_CODE_FILE"
}
