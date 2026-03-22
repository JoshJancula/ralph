#!/usr/bin/env bash

if [[ -n "${RALPH_RUN_PLAN_INVOKE_CODEX_LOADED:-}" ]]; then
  return
fi
RALPH_RUN_PLAN_INVOKE_CODEX_LOADED=1

ralph_run_plan_invoke_codex() {
  export OUTPUT_LOG EXIT_CODE_FILE SESSION_ID_FILE
  export RALPH_PLAN_CLI_RESUME
  if [[ -n "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]]; then
    export RALPH_RUN_PLAN_RESUME_SESSION_ID
  else
    unset RALPH_RUN_PLAN_RESUME_SESSION_ID
  fi
  if [[ "${RALPH_RUN_PLAN_RESUME_BARE:-0}" == "1" ]] && [[ "${RALPH_PLAN_ALLOW_UNSAFE_RESUME:-0}" == "1" ]]; then
    export RALPH_RUN_PLAN_RESUME_BARE
  elif [[ "${RALPH_RUN_PLAN_RESUME_BARE:-0}" == "1" ]]; then
    echo "Warning: resume without a session id requires RALPH_PLAN_ALLOW_UNSAFE_RESUME=1 or --allow-unsafe-resume; not using Codex resume --last." >&2
    unset RALPH_RUN_PLAN_RESUME_BARE
  else
    unset RALPH_RUN_PLAN_RESUME_BARE
  fi

  local prompt_file
  prompt_file="$(mktemp "${TMPDIR:-/tmp}/ralph-codex-prompt.XXXXXX")"
  printf '%s' "$PROMPT" >"$prompt_file"

  if [[ -n "${CODEX_CLI:-}" ]]; then
    export CODEX_PLAN_CLI="$CODEX_CLI"
  elif [[ -z "${CODEX_PLAN_CLI:-}" ]] && command -v codex &>/dev/null; then
    export CODEX_PLAN_CLI="codex"
  fi

  if [[ -n "${SELECTED_MODEL:-}" && "$SELECTED_MODEL" != "auto" ]]; then
    export CODEX_PLAN_MODEL="$SELECTED_MODEL"
  else
    export CODEX_PLAN_MODEL=""
  fi

  if [[ "${RALPH_PLAN_CLI_RESUME:-0}" == "1" ]] && command -v python3 &>/dev/null; then
    local _demux_py
    _demux_py="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-plan-cli-json-demux.py"
    "$WORKSPACE/.codex/ralph/codex-exec-prompt.sh" "$prompt_file" "$WORKSPACE" 2>&1 | python3 "$_demux_py" codex "$SESSION_ID_FILE" | tee -a "$OUTPUT_LOG"
    echo "${PIPESTATUS[0]}" >"$EXIT_CODE_FILE"
  else
    if [[ "${RALPH_PLAN_CLI_RESUME:-0}" == "1" ]]; then
      echo "Warning: RALPH_PLAN_CLI_RESUME needs python3 to parse --json and update session-id.txt; running without it." >&2
    fi
    "$WORKSPACE/.codex/ralph/codex-exec-prompt.sh" "$prompt_file" "$WORKSPACE" 2>&1 | tee -a "$OUTPUT_LOG"
    echo "${PIPESTATUS[0]}" >"$EXIT_CODE_FILE"
  fi
  rm -f "$prompt_file"
}
