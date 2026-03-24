#!/usr/bin/env bash

if [[ -n "${RALPH_RUN_PLAN_INVOKE_COMMON_LOADED:-}" ]]; then
  return
fi
RALPH_RUN_PLAN_INVOKE_COMMON_LOADED=1

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
  local bare_fn="$3"
  local warn_fn="$4"

  if [[ -n "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]]; then
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

  if [[ "${RALPH_PLAN_CLI_RESUME:-0}" == "1" ]] && command -v python3 &>/dev/null; then
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

  local demux_py
  demux_py="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-plan-cli-json-demux.py"

  local exit_code
  if [[ "${RALPH_PLAN_CLI_RESUME:-0}" == "1" ]] && command -v python3 &>/dev/null; then
    "$runner_fn" 2>&1 | python3 "$demux_py" "$runtime" "$SESSION_ID_FILE" | tee -a "$OUTPUT_LOG"
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
