#!/usr/bin/env bash
##
## Invokes `codex exec` with the full plan prompt as a single argv element.
## Used by `.ralph/run-plan.sh` when `--runtime codex`.
##
## Env:
##   CODEX_PLAN_CLI (default: codex)
##   CODEX_PLAN_SANDBOX (upstream codex exec --help values: read-only, workspace-write, danger-full-access; default: workspace-write)
##     danger-full-access removes the sandbox and is high risk
##   CODEX_PLAN_MODEL, CURSOR_PLAN_MODEL
##   CODEX_PLAN_EXEC_EXTRA (space-separated extra args before prompt)
##   CODEX_PLAN_NO_ADD_AGENTS_DIR (default unset): set to 1 to omit --add-dir <workspace>/.ralph-workspace on non-resume runs (default adds it so session and orchestration files under .ralph-workspace/ are visible to Codex; name is historical)
##   RALPH_PLAN_CLI_RESUME=1: pass --json so session id can be captured (python in invoke)
##   RALPH_PLAN_CAPTURE_USAGE=1 (default 1): also pass --json so the demux can collect token usage counters
##   RALPH_RUN_PLAN_RESUME_SESSION_ID: when set, use `codex exec resume <id> ...` instead of one-shot exec
##   RALPH_RUN_PLAN_RESUME_BARE=1 with RALPH_PLAN_ALLOW_UNSAFE_RESUME=1: `codex exec resume --last ...` when no id (unsafe locally)
##   CODEX_PLAN_FULL_AUTO (default 1): controls whether --full-auto is emitted.
##     Upstream, --full-auto sets both sandbox preset (to workspace-write) and approvals preset (to on-request).
##     When 1 (default): --full-auto is passed (current behavior).
##     When 0: --full-auto is omitted; explicit --sandbox is used instead ("explicit flags only" mode).
##     Note: Combining --full-auto with --sandbox values other than workspace-write may be order-dependent
##     per Codex semantics. When you need a strict read-only or danger-full-access sandbox, set
##     CODEX_PLAN_FULL_AUTO=0 to avoid the full-auto preset.
##   CODEX_PLAN_DANGEROUSLY_BYPASS_APPROVALS_AND_SANDBOX (default 0): When 1, appends
##     --dangerously-bypass-approvals-and-sandbox (alias --yolo) to codex exec calls.
##     Use only in isolated, trusted environments; this removes all sandbox and approval controls.
##     See openai/codex#9144 for resume path caveats.

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
case "$sandbox" in
  read-only|workspace-write|danger-full-access)
    ;;
  *)
    echo "Error: CODEX_PLAN_SANDBOX must be one of read-only, workspace-write, or danger-full-access." >&2
    exit 2
    ;;
esac

# `codex exec resume` only accepts options documented under `resume` (no --sandbox/--add-dir);
# flags must come before [SESSION_ID] [PROMPT]. Plain `codex exec` supports --sandbox and --add-dir.
resume_bare=0
resume_session=0
if [[ "${RALPH_RUN_PLAN_RESUME_BARE:-0}" == "1" ]] && [[ "${RALPH_PLAN_ALLOW_UNSAFE_RESUME:-0}" == "1" ]]; then
  resume_bare=1
elif [[ -n "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]]; then
  resume_session=1
fi

full_auto="${CODEX_PLAN_FULL_AUTO:-1}"

# Warn when full-auto is enabled with a non-default sandbox value.
if [[ "$full_auto" == "1" && "$sandbox" != "workspace-write" ]]; then
  echo "Warning: CODEX_PLAN_FULL_AUTO=1 with CODEX_PLAN_SANDBOX=$sandbox may be order-dependent; set CODEX_PLAN_FULL_AUTO=0 for strict sandbox control." >&2
fi

if [[ "$resume_bare" == "1" ]]; then
  if [[ "$full_auto" == "1" ]]; then
    args=(exec resume --last --full-auto)
  else
    args=(exec resume --last)
  fi
elif [[ "$resume_session" == "1" ]]; then
  if [[ "$full_auto" == "1" ]]; then
    args=(exec resume --full-auto)
  else
    args=(exec resume)
  fi
else
  if [[ "$full_auto" == "1" ]]; then
    args=(exec --full-auto --sandbox "$sandbox")
  else
    args=(exec --sandbox "$sandbox")
  fi
fi

model="${CODEX_PLAN_MODEL:-${CURSOR_PLAN_MODEL:-}}"
if [[ -n "$model" && "$model" != "auto" ]]; then
  args+=(--model "$model")
fi

if [[ "$resume_bare" != "1" && "$resume_session" != "1" ]]; then
  if [[ "${CODEX_PLAN_NO_ADD_AGENTS_DIR:-0}" != "1" ]]; then
    _ws_abs="$(cd "$workspace" && pwd)"
    mkdir -p "$_ws_abs/.ralph-workspace"
    args+=(--add-dir "$_ws_abs/.ralph-workspace")
  fi
fi

# Append bypass flag after sandbox/model/add-dir logic, before --json or prompt.
if [[ "${CODEX_PLAN_DANGEROUSLY_BYPASS_APPROVALS_AND_SANDBOX:-0}" == "1" ]]; then
  args+=(--dangerously-bypass-approvals-and-sandbox)
fi

if [[ "${RALPH_PLAN_CLI_RESUME:-0}" == "1" || "${RALPH_PLAN_CAPTURE_USAGE:-1}" == "1" ]]; then
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
