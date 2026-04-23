#!/usr/bin/env bash

if [[ -n "${RALPH_RUN_PLAN_INVOKE_OPENCODE_LOADED:-}" ]]; then
  return
fi
RALPH_RUN_PLAN_INVOKE_OPENCODE_LOADED=1

# Public interface:
#   run_plan_invoke_opencode_session_resume_args / run_plan_invoke_opencode_bare_resume_args -- build argv fragments.
#   run_plan_invoke_opencode_bare_resume_warn -- stderr warning when bare resume is not allowed.
#   ralph_run_plan_invoke_opencode -- run `opencode run` (non-interactive) with model, resume; exports log/session paths for demux.

_run_plan_invoke_opencode_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_run_plan_invoke_opencode_dir/run-plan-cli-helpers.sh"
# shellcheck source=/dev/null
source "$_run_plan_invoke_opencode_dir/run-plan-invoke-common.sh"
unset _run_plan_invoke_opencode_dir

run_plan_invoke_opencode_session_resume_args() {
  local args_name="$1"
  eval "$args_name+=(--session \"\${RALPH_RUN_PLAN_RESUME_SESSION_ID}\")"
}

run_plan_invoke_opencode_session_new_args() {
  :
}

run_plan_invoke_opencode_bare_resume_args() {
  local args_name="$1"
  eval "$args_name+=(--continue)"
}

run_plan_invoke_opencode_bare_resume_warn() {
  echo "Warning: resume without a session id requires RALPH_PLAN_ALLOW_UNSAFE_RESUME=1 or --allow-unsafe-resume; omitting bare opencode run --continue." >&2
}

ralph_run_plan_invoke_opencode() {
  # Paths and flags the Python demux / tee pipeline expects in the environment.
  export OUTPUT_LOG EXIT_CODE_FILE SESSION_ID_FILE

  # Resolve CLI before nvm use because nvm may change PATH and break the resolved path.
  local cli="${OPENCODE_PLAN_CLI:-}"

  if [[ -z "$cli" ]]; then
    if cli="$(ralph_resolve_opencode_cli)"; then
      : # resolved
    else
      echo "Error: OpenCode CLI not found (set OPENCODE_PLAN_CLI or install opencode)." >&2
      return 1
    fi
  fi

  if ! command -v "$cli" &>/dev/null; then
    echo "Error: OpenCode CLI not found at '$cli'." >&2
    return 1
  fi

  # Store absolute path before nvm use potentially changes PATH.
  cli="$(command -v "$cli")"

  # Ensure node v22 is active so the correct opencode binary is found and used.
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  if [[ -s "$NVM_DIR/nvm.sh" ]]; then
    # shellcheck source=/dev/null
    source "$NVM_DIR/nvm.sh" --no-use 2>/dev/null
    nvm use 22 --silent 2>/dev/null || true
  fi

  if ! command -v "$cli" &>/dev/null; then
    echo "Error: OpenCode CLI not found at '$cli'." >&2
    return 1
  fi

  # `opencode` with no subcommand starts the TUI; headless automation uses `opencode run` (see https://opencode.ai/docs/cli).
  local -a args=(run --agent build)
  run_plan_invoke_common_add_model_flag args --model

  run_plan_invoke_common_add_resume_args \
    args \
    run_plan_invoke_opencode_session_resume_args \
    run_plan_invoke_opencode_session_new_args \
    run_plan_invoke_opencode_bare_resume_args \
    run_plan_invoke_opencode_bare_resume_warn
  # On `opencode run`, `-f`/`--file` attaches files; JSON event stream uses `--format json`.
  run_plan_invoke_common_add_cli_resume_flags args --format json

  args+=("$PROMPT")

  run_plan_invoke_opencode_cli() {
    "$cli" "${args[@]}"
  }

  run_plan_invoke_common_execute \
    run_plan_invoke_opencode_cli \
    opencode \
    "Warning: RALPH_PLAN_CLI_RESUME needs python3 to parse JSON and update session-id.opencode.txt; running without it."
}
