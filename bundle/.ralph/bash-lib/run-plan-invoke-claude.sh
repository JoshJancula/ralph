#!/usr/bin/env bash

if [[ -n "${RALPH_RUN_PLAN_INVOKE_CLAUDE_LOADED:-}" ]]; then
  return
fi
RALPH_RUN_PLAN_INVOKE_CLAUDE_LOADED=1

ralph_run_plan_invoke_claude() {
  export OUTPUT_LOG EXIT_CODE_FILE SESSION_ID_FILE

  local cli="${CLAUDE_PLAN_CLI:-}"

  if [[ -z "$cli" ]] && command -v claude &>/dev/null; then
    cli="claude"
  fi

  if [[ -z "$cli" ]] || ! command -v "$cli" &>/dev/null; then
    echo "Error: Claude CLI not found (set CLAUDE_PLAN_CLI or install claude)." >&2
    return 1
  fi

  local -a args=(-p)
  if [[ -n "${SELECTED_MODEL:-}" ]]; then
    args+=(--model "$SELECTED_MODEL")
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

  if [[ -n "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]]; then
    args+=(--resume "$RALPH_RUN_PLAN_RESUME_SESSION_ID")
  elif [[ "${RALPH_RUN_PLAN_RESUME_BARE:-0}" == "1" ]] && [[ "${RALPH_PLAN_ALLOW_UNSAFE_RESUME:-0}" == "1" ]]; then
    args+=(--resume)
  elif [[ "${RALPH_RUN_PLAN_RESUME_BARE:-0}" == "1" ]]; then
    echo "Warning: resume without a session id requires RALPH_PLAN_ALLOW_UNSAFE_RESUME=1 or --allow-unsafe-resume; omitting bare --resume." >&2
  fi

  # Claude --print requires the prompt on stdin or as argv; stdin is reliable across
  # versions (some builds reject trailing prompt after flags).
  if [[ "${RALPH_PLAN_CLI_RESUME:-0}" == "1" ]] && command -v python3 &>/dev/null; then
    local _demux_py
    _demux_py="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-plan-cli-json-demux.py"
    args+=(--verbose)
    args+=(--output-format stream-json)
    printf '%s' "$PROMPT" | "$cli" "${args[@]}" 2>&1 | python3 "$_demux_py" claude "$SESSION_ID_FILE" | tee -a "$OUTPUT_LOG"
    echo "${PIPESTATUS[1]}" >"$EXIT_CODE_FILE"
  else
    if [[ "${RALPH_PLAN_CLI_RESUME:-0}" == "1" ]]; then
      echo "Warning: RALPH_PLAN_CLI_RESUME needs python3 to parse stream-json and update session-id.txt; running without it." >&2
    fi
    printf '%s' "$PROMPT" | "$cli" "${args[@]}" 2>&1 | tee -a "$OUTPUT_LOG"
    echo "${PIPESTATUS[1]}" >"$EXIT_CODE_FILE"
  fi
}
