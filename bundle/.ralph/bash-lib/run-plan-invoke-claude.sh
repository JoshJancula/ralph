#!/usr/bin/env bash

if [[ -n "${RALPH_RUN_PLAN_INVOKE_CLAUDE_LOADED:-}" ]]; then
  return
fi
RALPH_RUN_PLAN_INVOKE_CLAUDE_LOADED=1

ralph_run_plan_invoke_claude() {
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

  # Claude --print requires the prompt on stdin or as argv; stdin is reliable across
  # versions (some builds reject trailing prompt after flags).
  printf '%s' "$PROMPT" | "$cli" "${args[@]}" 2>&1 | tee -a "$OUTPUT_LOG"
  echo "${PIPESTATUS[1]}" >"$EXIT_CODE_FILE"
}
