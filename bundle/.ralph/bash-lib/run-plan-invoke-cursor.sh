#!/usr/bin/env bash

if [[ -n "${RALPH_RUN_PLAN_INVOKE_CURSOR_LOADED:-}" ]]; then
  return
fi
RALPH_RUN_PLAN_INVOKE_CURSOR_LOADED=1

ralph_run_plan_invoke_cursor() {
  export OUTPUT_LOG EXIT_CODE_FILE SESSION_ID_FILE

  local cli=""

  if command -v cursor-agent &>/dev/null; then
    cli="cursor-agent"
  elif command -v agent &>/dev/null; then
    cli="agent"
  else
    echo "Error: Cursor CLI not found (cursor-agent or agent missing from PATH)." >&2
    return 1
  fi

  # shellcheck disable=SC2034
  CURSOR_CLI="$cli"

  local -a args=(-p --force)
  if [[ -n "${SELECTED_MODEL:-}" ]]; then
    args+=(--model "$SELECTED_MODEL")
  fi
  if [[ -n "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]]; then
    args+=(--resume "$RALPH_RUN_PLAN_RESUME_SESSION_ID")
  elif [[ "${RALPH_RUN_PLAN_RESUME_BARE:-0}" == "1" ]] && [[ "${RALPH_PLAN_ALLOW_UNSAFE_RESUME:-0}" == "1" ]]; then
    args+=(--resume --continue)
  elif [[ "${RALPH_RUN_PLAN_RESUME_BARE:-0}" == "1" ]]; then
    echo "Warning: resume without a session id requires RALPH_PLAN_ALLOW_UNSAFE_RESUME=1 or --allow-unsafe-resume; omitting bare --resume." >&2
  fi
  if [[ "${RALPH_PLAN_CLI_RESUME:-0}" == "1" ]]; then
    args+=(--output-format json)
  fi
  args+=("$PROMPT")

  if [[ "${RALPH_PLAN_CLI_RESUME:-0}" == "1" ]] && command -v python3 &>/dev/null; then
    local _demux_py
    _demux_py="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-plan-cli-json-demux.py"
    "$cli" "${args[@]}" 2>&1 | python3 "$_demux_py" cursor "$SESSION_ID_FILE" | tee -a "$OUTPUT_LOG"
    echo "${PIPESTATUS[0]}" >"$EXIT_CODE_FILE"
  else
    if [[ "${RALPH_PLAN_CLI_RESUME:-0}" == "1" ]]; then
      echo "Warning: RALPH_PLAN_CLI_RESUME needs python3 to parse JSON and update session-id.txt; running without it." >&2
      args=(-p --force)
      [[ -n "${SELECTED_MODEL:-}" ]] && args+=(--model "$SELECTED_MODEL")
      if [[ -n "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]]; then
        args+=(--resume "$RALPH_RUN_PLAN_RESUME_SESSION_ID")
      elif [[ "${RALPH_RUN_PLAN_RESUME_BARE:-0}" == "1" ]] && [[ "${RALPH_PLAN_ALLOW_UNSAFE_RESUME:-0}" == "1" ]]; then
        args+=(--resume --continue)
      elif [[ "${RALPH_RUN_PLAN_RESUME_BARE:-0}" == "1" ]]; then
        echo "Warning: resume without a session id requires RALPH_PLAN_ALLOW_UNSAFE_RESUME=1 or --allow-unsafe-resume; omitting bare --resume." >&2
      fi
      args+=("$PROMPT")
    fi
    "$cli" "${args[@]}" 2>&1 | tee -a "$OUTPUT_LOG"
    echo "${PIPESTATUS[0]}" >"$EXIT_CODE_FILE"
  fi
}
