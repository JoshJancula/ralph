#!/usr/bin/env bash

if [[ -n "${RALPH_RUN_PLAN_INVOKE_CURSOR_LOADED:-}" ]]; then
  return
fi
RALPH_RUN_PLAN_INVOKE_CURSOR_LOADED=1

ralph_run_plan_invoke_cursor() {
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

  local args=(-p --force)
  if [[ -n "${SELECTED_MODEL:-}" ]]; then
    args+=(--model "$SELECTED_MODEL")
  fi
  args+=("$PROMPT")

  "$cli" "${args[@]}" 2>&1 | tee -a "$OUTPUT_LOG"
  echo "${PIPESTATUS[0]}" >"$EXIT_CODE_FILE"
}
