#!/usr/bin/env bash
##
## Invokes `codex exec` with the full plan prompt as a single argv element.
## Used by `.ralph/run-plan.sh` when `--runtime codex`.
##
## Env:
##   CODEX_PLAN_CLI (default: codex)
##   CODEX_PLAN_SANDBOX (default: workspace-write)
##   CODEX_PLAN_MODEL, CURSOR_PLAN_MODEL
##   CODEX_PLAN_EXEC_EXTRA (space-separated extra args before prompt)
##   CODEX_PLAN_NO_ADD_AGENTS_DIR (default unset): set to 1 to skip --add-dir for .agents/ (plan human files use .ralph-workspace/, not .agents)
##   RALPH_PLAN_CLI_RESUME=1: pass --json so session id can be captured (python in invoke)
##   RALPH_RUN_PLAN_RESUME_SESSION_ID: when set, use `codex exec resume <id> ...` instead of one-shot exec
##   RALPH_RUN_PLAN_RESUME_BARE=1 with RALPH_PLAN_ALLOW_UNSAFE_RESUME=1: `codex exec resume --last ...` when no id (unsafe locally)

set -euo pipefail

prompt_file="${1:-}"
workspace="${2:-}"

if [[ -z "$prompt_file" || -z "$workspace" ]]; then
  echo 'Usage: codex-exec-prompt.sh <prompt-file> <workspace>' >&2
  exit 2
fi

prompt="$(<"$prompt_file")"

cli="${CODEX_PLAN_CLI:-${CURSOR_PLAN_CLI:-codex}}"
sandbox="${CODEX_PLAN_SANDBOX:-workspace-write}"

# `codex exec resume` only accepts options documented under `resume` (no --sandbox/--add-dir);
# flags must come before [SESSION_ID] [PROMPT]. Plain `codex exec` supports --sandbox and --add-dir.
resume_bare=0
resume_session=0
if [[ "${RALPH_RUN_PLAN_RESUME_BARE:-0}" == "1" ]] && [[ "${RALPH_PLAN_ALLOW_UNSAFE_RESUME:-0}" == "1" ]]; then
  resume_bare=1
elif [[ -n "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]]; then
  resume_session=1
fi

if [[ "$resume_bare" == "1" ]]; then
  args=(exec resume --last --full-auto)
elif [[ "$resume_session" == "1" ]]; then
  args=(exec resume --full-auto)
else
  args=(exec --full-auto --sandbox "$sandbox")
fi

model="${CODEX_PLAN_MODEL:-${CURSOR_PLAN_MODEL:-}}"
if [[ -n "$model" && "$model" != "auto" ]]; then
  args+=(--model "$model")
fi

if [[ "$resume_bare" != "1" && "$resume_session" != "1" ]]; then
  if [[ "${CODEX_PLAN_NO_ADD_AGENTS_DIR:-0}" != "1" ]]; then
    _ws_abs="$(cd "$workspace" && pwd)"
    mkdir -p "$_ws_abs/.agents"
    args+=(--add-dir "$_ws_abs/.agents")
  fi
fi

if [[ "${RALPH_PLAN_CLI_RESUME:-0}" == "1" ]]; then
  args+=(--json)
fi

if [[ -n "${CODEX_PLAN_EXEC_EXTRA:-}" ]]; then
  read -r -a extra_args <<< "${CODEX_PLAN_EXEC_EXTRA}"
  if [[ ${#extra_args[@]} -gt 0 ]]; then
    args+=("${extra_args[@]}")
  fi
fi

if [[ "$resume_session" == "1" ]]; then
  args+=("${RALPH_RUN_PLAN_RESUME_SESSION_ID}")
fi

args+=("$prompt")

(
  cd "$workspace"
  exec "$cli" "${args[@]}"
)
