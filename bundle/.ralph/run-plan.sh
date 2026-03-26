#!/usr/bin/env bash
#
# Unified multi-runtime runner for Cursor, Claude, and Codex.
# Usage examples (all flags; no positional plan or workspace paths):
#   .ralph/run-plan.sh --runtime cursor --plan PLAN.md --workspace .
#   .ralph/run-plan.sh --runtime claude --plan PLAN.md --workspace . --agent research --non-interactive
#   .ralph/run-plan.sh --runtime cursor --model <id> --plan PLAN.md --workspace .
#   RALPH_PLAN_RUNTIME=codex .ralph/run-plan.sh --plan PLAN.md --workspace /path/to/workspace
# Omit `--workspace` only when the current working directory is the workspace (it defaults to pwd).
# Omit `--runtime` when RALPH_PLAN_RUNTIME is set or when the interactive runtime prompt runs (TTY).
# CLIs required by runtime:
#   Cursor: https://cursor.com/docs/cli/installation
#   Claude:  https://code.claude.com/docs/en/overview
#   Codex:   https://developers.openai.com/codex/cli/reference
# Aggregated env vars (runtime-specific pipeline merges Cursor → Claude → Codex):
#   Verbose:      CURSOR_PLAN_VERBOSE / CLAUDE_PLAN_VERBOSE / CODEX_PLAN_VERBOSE
#   Color:        CURSOR_PLAN_NO_COLOR / CLAUDE_PLAN_NO_COLOR / CODEX_PLAN_NO_COLOR
#   Logs:         CURSOR_PLAN_LOG / CURSOR_PLAN_OUTPUT_LOG +
#                 CLAUDE_PLAN_LOG / CLAUDE_PLAN_OUTPUT_LOG +
#                 CODEX_PLAN_LOG / CODEX_PLAN_OUTPUT_LOG
#   Plan state dir: RALPH_PLAN_WORKSPACE_ROOT (default: <workspace>/.ralph-workspace) holds plan logs + sessions
#   Iterations:   CURSOR_PLAN_MAX_ITER / CLAUDE_PLAN_MAX_ITER / CODEX_PLAN_MAX_ITER (total agent invocations cap)
#   Gutter:       CURSOR_PLAN_GUTTER_ITER / CLAUDE_PLAN_GUTTER_ITER / CODEX_PLAN_GUTTER_ITER, or --max-iterations <n>
#                 (per-TODO retries before gutter exit; human help / plan edit expected)
#   Progress:     CURSOR_PLAN_PROGRESS_INTERVAL / CLAUDE_PLAN_PROGRESS_INTERVAL / CODEX_PLAN_PROGRESS_INTERVAL
#   Caffeinate:   CURSOR_PLAN_NO_CAFFEINATE / CLAUDE_PLAN_NO_CAFFEINATE / CODEX_PLAN_NO_CAFFEINATE
#   Human prompts: CURSOR_PLAN_DISABLE_HUMAN_PROMPT / CLAUDE_PLAN_DISABLE_HUMAN_PROMPT / CODEX_PLAN_DISABLE_HUMAN_PROMPT
#                  CURSOR_PLAN_NO_OPEN / CLAUDE_PLAN_NO_OPEN / CODEX_PLAN_NO_OPEN
#   Human offline (no TTY): RALPH_HUMAN_POLL_INTERVAL (default 2), RALPH_HUMAN_OFFLINE_EXIT=1 to exit 4 instead of waiting
#   Usage risk (first run): interactive YES prompt once; marker under ${XDG_CONFIG_HOME:-~/.config}/ralph/usage-risk-acknowledgment; RALPH_USAGE_RISKS_ACKNOWLEDGED=1 skips (CI/automation)
#   CLI session resume (optional): RALPH_PLAN_CLI_RESUME=1 or --cli-resume stores a session id under
#     .ralph-workspace/sessions/<RALPH_PLAN_KEY>/session-id.txt and, when that file exists, passes --resume <id> (or runtime
#     equivalent) with a compact prompt (TODO + plan path + human-replies only). Interactive TTY runs ask unless
#     you set the env var or pass --cli-resume / --no-cli-resume.
#   Unsafe bare resume: RALPH_PLAN_ALLOW_UNSAFE_RESUME=1 or --allow-unsafe-resume is required before the runner
#     passes resume without a stored session id (e.g. Codex resume --last). Invoke helpers ignore bare resume without
#     this flag so ad-hoc RALPH_RUN_PLAN_RESUME_BARE cannot resume the wrong session during interactive use.
#   Timeout:      --timeout <duration> (per-agent-invocation timeout, default 30m).
#                 Duration format: compact units such as `30m`, `1800s`, `2h`.
#                 On timeout, exits as `stuck` with exit code `4`.
# A plan file path is required: pass --plan <path> (relative paths resolve against the workspace directory).
#
# Usage:
#   .ralph/run-plan.sh --runtime cursor --plan PLAN.md --workspace .
#   .ralph/run-plan.sh --runtime claude --plan PLAN.md --workspace /path/repo
#   .ralph/run-plan.sh --runtime codex --plan OTHER.md --workspace .
#   .ralph/run-plan.sh --runtime cursor --plan docs/plan.md --workspace /path/repo
#   .ralph/run-plan.sh --runtime cursor --plan PLAN.md --workspace . --agent research
#   .ralph/run-plan.sh --runtime cursor --select-agent --plan PLAN.md --workspace .
#   .ralph/run-plan.sh --runtime claude --non-interactive --agent research --plan PLAN.md --workspace .
#   .ralph/run-plan.sh --runtime cursor --model gpt-5 --plan PLAN.md --workspace .
#   .ralph/run-plan.sh --runtime cursor --plan PLAN.md --workspace . --agent research --model other-id
#   (--no-interactive is an alias for --non-interactive; no model menu when agent/config/--model supplies model)
#   Plan and workspace paths are only accepted as `--plan` / `--workspace` flags (unknown flags error out).
# Non-interactive mode:

set -euo pipefail

# ---------------------------------------------------------------------------
# Pipeline (this file): bootstrap, optional caffeinate re-exec, then source
# bash-lib/run-plan-core.sh for the full plan loop (pick next TODO, build prompt,
# invoke Cursor/Claude/Codex, update plan, human gates, session resume).
# ---------------------------------------------------------------------------

# On macOS, re-exec under caffeinate so the system does not sleep during the plan run.
# Guard variables are normalized so we only re-exec once per invocation.
#
# Shared Ralph (run-plan.sh, bash-lib/, ralph-env-safety.sh, ...) lives under .ralph/.
# Per-runtime trees (.claude/ralph, .cursor/ralph, .codex/ralph) only hold thin wrappers
# and templates. If run-plan.sh is invoked from a runtime ralph dir (or that path is
# what dirname resolves to), use the workspace .ralph copy that contains bash-lib.
_THIS_RUN_PLAN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_THIS_RUN_PLAN_FILE="$_THIS_RUN_PLAN_DIR/$(basename "${BASH_SOURCE[0]}")"
# Resolve the copy of .ralph that contains bash-lib (invocation may be from .cursor/ralph etc.).
# shellcheck source=/Users/joshuajancula/Documents/projects/ralph/.ralph/bash-lib/run-plan-runtime.sh
source "$_THIS_RUN_PLAN_DIR/bash-lib/run-plan-runtime.sh"
SCRIPT_DIR="$(ralph_resolve_shared_ralph_dir "$_THIS_RUN_PLAN_DIR")"
_RESOLVED_RUN_PLAN="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
if [[ -f "$_RESOLVED_RUN_PLAN" ]]; then
  SCRIPT_PATH="$_RESOLVED_RUN_PLAN"
else
  SCRIPT_PATH="$_THIS_RUN_PLAN_FILE"
fi
RALPH_DIR="$SCRIPT_DIR"

# Shared libraries: env merge per runtime, menus, errors, CLI parse, session paths.
# shellcheck source=/Users/joshuajancula/Documents/projects/ralph/.ralph/bash-lib/run-plan-env.sh
source "$SCRIPT_DIR/bash-lib/run-plan-env.sh"
# shellcheck source=/Users/joshuajancula/Documents/projects/ralph/.ralph/bash-lib/menu-select.sh
source "$SCRIPT_DIR/bash-lib/menu-select.sh"
# shellcheck source=/Users/joshuajancula/Documents/projects/ralph/.ralph/bash-lib/error-handling.sh
source "$SCRIPT_DIR/bash-lib/error-handling.sh"
# shellcheck source=/Users/joshuajancula/Documents/projects/ralph/.ralph/bash-lib/run-plan-args.sh
source "$SCRIPT_DIR/bash-lib/run-plan-args.sh"
# shellcheck source=/Users/joshuajancula/Documents/projects/ralph/.ralph/bash-lib/run-plan-session.sh
source "$SCRIPT_DIR/bash-lib/run-plan-session.sh"

# Infer runtime from argv early so caffeinate re-exec picks up the right *_PLAN_* env chain.
CAFFEINATE_RUNTIME="${RALPH_PLAN_RUNTIME:-}"
if [[ -z "$CAFFEINATE_RUNTIME" ]]; then
  cmdline_args=("$@")
  for idx in "${!cmdline_args[@]}"; do
    if [[ "${cmdline_args[idx]}" == "--runtime" ]]; then
      next_idx=$((idx + 1))
      if [[ $next_idx -lt ${#cmdline_args[@]} ]]; then
        CAFFEINATE_RUNTIME="${cmdline_args[next_idx]}"
      fi
      break
    fi
  done
fi

case "$CAFFEINATE_RUNTIME" in
  cursor|claude|codex)
    ralph_run_plan_load_env_for_runtime "$CAFFEINATE_RUNTIME"
    ;;
esac

# Normalize the human prompt overrides so RALPH helpers can reuse the legacy names.
# Prefer explicit RALPH_PLAN_* values but fall back to CURSOR_PLAN_* for backwards compatibility.
HUMAN_PROMPT_DISABLE_FLAG="${RALPH_PLAN_DISABLE_HUMAN_PROMPT:-${CURSOR_PLAN_DISABLE_HUMAN_PROMPT:-0}}"
HUMAN_PROMPT_NO_OPEN_FLAG="${RALPH_PLAN_NO_OPEN:-${CURSOR_PLAN_NO_OPEN:-0}}"

RALPH_PLAN_NO_CAFFEINATE="${RALPH_PLAN_NO_CAFFEINATE:-0}"
RALPH_PLAN_CAFFEINATED="${RALPH_PLAN_CAFFEINATED:-0}"

# CURSOR_PLAN_CAFFEINATED / CLAUDE_PLAN_CAFFEINATED / CODEX_PLAN_CAFFEINATED
# ensure legacy scripts also notice the guard state.
if [[ "$(uname -s)" == "Darwin" ]] && \
   command -v caffeinate &>/dev/null && \
   [[ "${RALPH_PLAN_NO_CAFFEINATE}" != "1" ]] && \
   [[ "${RALPH_PLAN_CAFFEINATED}" != "1" ]]; then
  export RALPH_PLAN_CAFFEINATED=1
  export CURSOR_PLAN_CAFFEINATED=1
  export CLAUDE_PLAN_CAFFEINATED=1
  export CODEX_PLAN_CAFFEINATED=1
  exec caffeinate -s -i -- /usr/bin/env bash "$SCRIPT_PATH" "$@"
fi
# Block dangerous paths (e.g. .env) from plan/log targets.
# shellcheck source=/Users/joshuajancula/Documents/projects/ralph/bundle/.ralph/ralph-env-safety.sh
source "$RALPH_DIR/ralph-env-safety.sh"
# Markdown checklist helpers used by run-plan-core.
# shellcheck source=/Users/joshuajancula/Documents/projects/ralph/bundle/.ralph/bash-lib/plan-todo.sh
source "$SCRIPT_DIR/bash-lib/plan-todo.sh"

# Main runner: parse_args already ran inside run-plan-core; executes until all TODOs done or failure.
# shellcheck source=/Users/joshuajancula/Documents/projects/ralph/bundle/.ralph/bash-lib/run-plan-core.sh
source "$SCRIPT_DIR/bash-lib/run-plan-core.sh"
