#!/usr/bin/env bash

if [[ -n "${RALPH_RUN_PLAN_INVOKE_CURSOR_LOADED:-}" ]]; then
  return
fi
RALPH_RUN_PLAN_INVOKE_CURSOR_LOADED=1

_run_plan_invoke_cursor_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_run_plan_invoke_cursor_dir/run-plan-cli-helpers.sh"
# shellcheck source=/dev/null
source "$_run_plan_invoke_cursor_dir/run-plan-invoke-common.sh"
unset _run_plan_invoke_cursor_dir

run_plan_invoke_cursor_session_resume_args() {
  local args_name="$1"
  eval "$args_name+=(--resume \"\${RALPH_RUN_PLAN_RESUME_SESSION_ID}\")"
}

run_plan_invoke_cursor_bare_resume_args() {
  local args_name="$1"
  eval "$args_name+=(--resume --continue)"
}

run_plan_invoke_cursor_bare_resume_warn() {
  echo "Warning: resume without a session id requires RALPH_PLAN_ALLOW_UNSAFE_RESUME=1 or --allow-unsafe-resume; omitting bare --resume." >&2
}

ralph_run_plan_invoke_cursor() {
  export OUTPUT_LOG EXIT_CODE_FILE SESSION_ID_FILE

  local cli=""
  if ! cli="$(ralph_resolve_cursor_cli)"; then
    echo "Error: Cursor CLI not found (cursor-agent or agent missing from PATH)." >&2
    return 1
  fi

  # shellcheck disable=SC2034
  CURSOR_CLI="$cli"

  local -a args=(-p --force)
  run_plan_invoke_common_add_model_flag args --model
  run_plan_invoke_common_add_resume_args \
    args \
    run_plan_invoke_cursor_session_resume_args \
    run_plan_invoke_cursor_bare_resume_args \
    run_plan_invoke_cursor_bare_resume_warn
  run_plan_invoke_common_add_cli_resume_flags args --output-format json
  args+=("$PROMPT")

  run_plan_invoke_cursor_cli() {
    "$cli" "${args[@]}"
  }

  run_plan_invoke_common_execute \
    run_plan_invoke_cursor_cli \
    cursor \
    "Warning: RALPH_PLAN_CLI_RESUME needs python3 to parse JSON and update session-id.txt; running without it."
}
