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
##   CODEX_PLAN_NO_ADD_AGENTS_DIR (default unset): set to 1 to skip --add-dir for .agents/

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
args=(exec --full-auto --sandbox "$sandbox")

model="${CODEX_PLAN_MODEL:-${CURSOR_PLAN_MODEL:-}}"
if [[ -n "$model" && "$model" != "auto" ]]; then
  args+=(--model "$model")
fi

# Human prompts, sessions, and artifacts live under .agents/ (often gitignored). Codex
# workspace-write may not treat that tree as writable; --add-dir grants access.
if [[ "${CODEX_PLAN_NO_ADD_AGENTS_DIR:-0}" != "1" ]]; then
  _ws_abs="$(cd "$workspace" && pwd)"
  mkdir -p "$_ws_abs/.agents"
  args+=(--add-dir "$_ws_abs/.agents")
fi

if [[ -n "${CODEX_PLAN_EXEC_EXTRA:-}" ]]; then
  read -r -a extra_args <<< "${CODEX_PLAN_EXEC_EXTRA}"
  if [[ ${#extra_args[@]} -gt 0 ]]; then
    args+=("${extra_args[@]}")
  fi
fi

args+=("$prompt")

(
  cd "$workspace"
  exec "$cli" "${args[@]}"
)
