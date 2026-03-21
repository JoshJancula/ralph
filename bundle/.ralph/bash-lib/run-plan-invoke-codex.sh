#!/usr/bin/env bash

if [[ -n "${RALPH_RUN_PLAN_INVOKE_CODEX_LOADED:-}" ]]; then
  return
fi
RALPH_RUN_PLAN_INVOKE_CODEX_LOADED=1

ralph_run_plan_invoke_codex() {
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

  "$WORKSPACE/.codex/ralph/codex-exec-prompt.sh" "$prompt_file" "$WORKSPACE" 2>&1 | tee -a "$OUTPUT_LOG"
  echo "${PIPESTATUS[0]}" >"$EXIT_CODE_FILE"
  rm -f "$prompt_file"
}
