#!/usr/bin/env bash
#
# Unified multi-runtime runner for Cursor, Claude, and Codex.
# Usage examples:
#   .ralph/run-plan.sh --runtime cursor --plan PLAN.md
#   .ralph/run-plan.sh --runtime claude --plan PLAN.md --agent research --non-interactive
#   .ralph/run-plan.sh --runtime cursor --model <id> --plan PLAN.md
#   RALPH_PLAN_RUNTIME=codex .ralph/run-plan.sh --plan PLAN.md /path/to/workspace
# The flags (including `--runtime`, optional when interactive) must be supplied before the optional
# workspace positional argument; the workspace path is the final positional argument.
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
#   Iterations:   CURSOR_PLAN_MAX_ITER / CLAUDE_PLAN_MAX_ITER / CODEX_PLAN_MAX_ITER
#   Gutter:       CURSOR_PLAN_GUTTER_ITER / CLAUDE_PLAN_GUTTER_ITER / CODEX_PLAN_GUTTER_ITER
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
# A plan file path is required: pass --plan <path> (relative paths resolve against the workspace directory).
#
# Usage:
#   .ralph/run-plan.sh --runtime cursor --plan PLAN.md
#   .ralph/run-plan.sh --runtime claude --plan PLAN.md /path/repo
#   .ralph/run-plan.sh --runtime codex --plan OTHER.md
#   .ralph/run-plan.sh --runtime cursor --plan docs/plan.md /path/repo
#   .ralph/run-plan.sh --runtime cursor --plan PLAN.md --agent research
#   .ralph/run-plan.sh --runtime cursor --select-agent --plan PLAN.md
#   .ralph/run-plan.sh --runtime claude --non-interactive --agent research --plan PLAN.md
#   .ralph/run-plan.sh --runtime cursor --model gpt-5 --plan PLAN.md
#   .ralph/run-plan.sh --runtime cursor --plan PLAN.md --agent research --model other-id
#   (--no-interactive is an alias for --non-interactive; no model menu when agent/config/--model supplies model)
# Non-interactive mode:

set -euo pipefail

# On macOS, re-exec under caffeinate so the system does not sleep during the plan run.
# Guard variables are normalized so we only re-exec once per invocation.
#
# Shared Ralph (run-plan.sh, bash-lib/, ralph-env-safety.sh, ...) lives under .ralph/.
# Per-runtime trees (.claude/ralph, .cursor/ralph, .codex/ralph) only hold thin wrappers
# and templates. If run-plan.sh is invoked from a runtime ralph dir (or that path is
# what dirname resolves to), use the workspace .ralph copy that contains bash-lib.
ralph_shared_ralph_dir_complete() {
  local d="$1"
  if [[ -f "$d/bash-lib/run-plan-env.sh" && -f "$d/ralph-env-safety.sh" \
    && -f "$d/bash-lib/run-plan-invoke-cursor.sh" \
    && -f "$d/bash-lib/run-plan-invoke-claude.sh" \
    && -f "$d/bash-lib/run-plan-invoke-codex.sh" ]]; then
    return 0
  fi
  return 1
}

ralph_resolve_shared_ralph_dir() {
  local d="$1"
  local ancestor cand2
  if ralph_shared_ralph_dir_complete "$d"; then
    printf '%s\n' "$d"
    return 0
  fi
  # Partial trees under .cursor/ralph, .claude/ralph, or .codex/ralph (or nested layouts)
  # may include some bash-lib files but not invoke helpers; walk up until we find a
  # complete sibling .ralph/ (e.g. workspace/.ralph next to workspace/.cursor).
  ancestor="$(dirname "$d")"
  while [[ "$ancestor" != "/" ]]; do
    cand2="$ancestor/.ralph"
    if ralph_shared_ralph_dir_complete "$cand2"; then
      printf '%s\n' "$(cd "$cand2" && pwd)"
      return 0
    fi
    ancestor="$(dirname "$ancestor")"
  done
  printf '%s\n' "$d"
}

_THIS_RUN_PLAN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_THIS_RUN_PLAN_FILE="$_THIS_RUN_PLAN_DIR/$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(ralph_resolve_shared_ralph_dir "$_THIS_RUN_PLAN_DIR")"
_RESOLVED_RUN_PLAN="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
if [[ -f "$_RESOLVED_RUN_PLAN" ]]; then
  SCRIPT_PATH="$_RESOLVED_RUN_PLAN"
else
  SCRIPT_PATH="$_THIS_RUN_PLAN_FILE"
fi
RALPH_DIR="$SCRIPT_DIR"

# shellcheck source=/Users/joshuajancula/Documents/projects/ralph/.ralph/bash-lib/run-plan-env.sh
source "$SCRIPT_DIR/bash-lib/run-plan-env.sh"
# shellcheck source=/Users/joshuajancula/Documents/projects/ralph/.ralph/bash-lib/menu-select.sh
source "$SCRIPT_DIR/bash-lib/menu-select.sh"

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
# shellcheck source=/Users/joshuajancula/Documents/projects/ralph/bundle/.ralph/ralph-env-safety.sh
source "$RALPH_DIR/ralph-env-safety.sh"
# shellcheck source=/Users/joshuajancula/Documents/projects/ralph/bundle/.ralph/bash-lib/plan-todo.sh
source "$SCRIPT_DIR/bash-lib/plan-todo.sh"

WORKSPACE="$(pwd)"
PLAN_OVERRIDE=""
PREBUILT_AGENT=""
PLAN_MODEL_CLI=""
INTERACTIVE_SELECT_AGENT_FLAG=0
NON_INTERACTIVE_FLAG=0
CLI_RESUME_FLAG=0
NO_CLI_RESUME_FLAG=0
ALLOW_UNSAFE_RESUME_FLAG=0
RESUME_SESSION_ID_OVERRIDE=""
RUNTIME=""
CLAUDE_TOOLS_FROM_AGENT=""
_RALPH_CLI_RESUME_ENV_WAS_SET=0
[[ "${RALPH_PLAN_CLI_RESUME+x}" == x ]] && _RALPH_CLI_RESUME_ENV_WAS_SET=1

# Parse arguments: --plan, --model, --agent, --select-agent, --non-interactive, optional workspace positional
while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --runtime requires an argument (cursor, claude, or codex)." >&2
        exit 1
      fi
      case "$2" in
        cursor|claude|codex)
          RUNTIME="$2"
          ;;
        *)
          echo "Error: --runtime must be one of cursor, claude, or codex." >&2
          exit 1
          ;;
      esac
      shift 2
      ;;
    --plan)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --plan requires a plan file path." >&2
        exit 1
      fi
      PLAN_OVERRIDE="$2"
      shift 2
      ;;
    --model)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --model requires a model id string." >&2
        exit 1
      fi
      PLAN_MODEL_CLI="$2"
      shift 2
      ;;
    --agent)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --agent requires a prebuilt agent name (subdirectory of .<runtime>/agents/)." >&2
        exit 1
      fi
      PREBUILT_AGENT="$2"
      shift 2
      ;;
    --select-agent)
      INTERACTIVE_SELECT_AGENT_FLAG=1
      shift
      ;;
    --non-interactive | --no-interactive)
      NON_INTERACTIVE_FLAG=1
      shift
      ;;
    --cli-resume)
      CLI_RESUME_FLAG=1
      shift
      ;;
    --no-cli-resume)
      NO_CLI_RESUME_FLAG=1
      shift
      ;;
    --allow-unsafe-resume)
      ALLOW_UNSAFE_RESUME_FLAG=1
      shift
      ;;
    --resume)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --resume requires a session id." >&2
        exit 1
      fi
      RESUME_SESSION_ID_OVERRIDE="$2"
      shift 2
      ;;
    *)
      WORKSPACE="$1"
      shift
      ;;
  esac
done

if [[ -n "$PREBUILT_AGENT" && "$INTERACTIVE_SELECT_AGENT_FLAG" == "1" ]]; then
  echo "Error: use only one of --agent <name> and --select-agent." >&2
  exit 1
fi

if [[ "$NON_INTERACTIVE_FLAG" == "1" && "$INTERACTIVE_SELECT_AGENT_FLAG" == "1" ]]; then
  echo "Error: --non-interactive cannot be combined with --select-agent." >&2
  exit 1
fi

WORKSPACE="$(cd "$WORKSPACE" && pwd)"

if [[ -z "$PLAN_OVERRIDE" ]]; then
  echo "Error: --plan <path> is required." >&2
  exit 1
fi

if [[ "$NO_CLI_RESUME_FLAG" == "1" ]]; then
  RALPH_PLAN_CLI_RESUME=0
elif [[ "$CLI_RESUME_FLAG" == "1" ]]; then
  RALPH_PLAN_CLI_RESUME=1
elif [[ "$_RALPH_CLI_RESUME_ENV_WAS_SET" == "1" ]]; then
  case "${RALPH_PLAN_CLI_RESUME:-0}" in
    1|true|yes|on) RALPH_PLAN_CLI_RESUME=1 ;;
    *) RALPH_PLAN_CLI_RESUME=0 ;;
  esac
else
  RALPH_PLAN_CLI_RESUME=0
  if [[ -t 0 ]] && [[ -t 1 ]]; then
    _RALPH_PROMPT_CLI_RESUME_INTERACTIVE=1
  fi
fi

RALPH_PLAN_ALLOW_UNSAFE_RESUME="${RALPH_PLAN_ALLOW_UNSAFE_RESUME:-0}"
if [[ "$ALLOW_UNSAFE_RESUME_FLAG" == "1" ]]; then
  RALPH_PLAN_ALLOW_UNSAFE_RESUME=1
fi
case "${RALPH_PLAN_ALLOW_UNSAFE_RESUME:-0}" in
  1|true|yes|on) RALPH_PLAN_ALLOW_UNSAFE_RESUME=1 ;;
  *) RALPH_PLAN_ALLOW_UNSAFE_RESUME=0 ;;
esac
export RALPH_PLAN_ALLOW_UNSAFE_RESUME

# Colors before any interactive menu (runtime picker runs before log() exists).
# Disable with CURSOR_PLAN_NO_COLOR=1 (honored across runtimes).
if [[ -t 1 && "${CURSOR_PLAN_NO_COLOR:-0}" != "1" ]]; then
  C_R=$'\033[31m'
  C_G=$'\033[32m'
  C_Y=$'\033[33m'
  C_B=$'\033[34m'
  C_C=$'\033[36m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RST=$'\033[0m'
else
  C_R="" C_G="" C_Y="" C_B="" C_C="" C_BOLD="" C_DIM="" C_RST=""
fi

# shellcheck source=/dev/null
source "$SCRIPT_DIR/bash-lib/usage-risk-ack.sh"
ralph_require_usage_risk_acknowledgment

AGENT_CONFIG_TOOL="$WORKSPACE/.ralph/agent-config-tool.sh"

# When --runtime and RALPH_PLAN_RUNTIME are both unset, interactive TTY sessions get a menu;
# non-interactive and non-TTY runs must set runtime explicitly.
prompt_select_runtime() {
  if [[ "$NON_INTERACTIVE_FLAG" == "1" ]]; then
    echo "Error: runtime must be provided via --runtime or RALPH_PLAN_RUNTIME (cursor, claude, or codex)." >&2
    return 1
  fi
  if [[ ! -t 0 ]]; then
    echo "Error: runtime must be provided via --runtime or RALPH_PLAN_RUNTIME when stdin is not a terminal." >&2
    return 1
  fi
  echo "" >&2
  echo -e "${C_C}${C_BOLD}Plan runner${C_RST} ${C_DIM}--${C_RST} ${C_BOLD}which CLI runs each TODO?${C_RST}" >&2
  echo "" >&2
  echo -e "  ${C_G}1)${C_RST} Cursor" >&2
  echo -e "  ${C_G}2)${C_RST} Claude Code" >&2
  echo -e "  ${C_G}3)${C_RST} Codex" >&2
  echo "" >&2
  local runtime_choice
  printf '%s' "${C_Y}${C_BOLD}Selection${C_RST}${C_DIM} [1]${C_RST}: " >&2
  read -r runtime_choice </dev/tty 2>/dev/null || runtime_choice="1"
  runtime_choice="${runtime_choice:-1}"
  case "$runtime_choice" in
    1) printf '%s' "cursor" ;;
    2) printf '%s' "claude" ;;
    3) printf '%s' "codex" ;;
    cursor|claude|codex) printf '%s' "$runtime_choice" ;;
    *)
      echo "Error: invalid runtime selection (use 1-3 or cursor, claude, or codex)." >&2
      return 1
      ;;
  esac
}

if [[ -z "$RUNTIME" ]]; then
  if [[ -n "${RALPH_PLAN_RUNTIME:-}" ]]; then
    case "${RALPH_PLAN_RUNTIME}" in
      cursor|claude|codex)
        RUNTIME="${RALPH_PLAN_RUNTIME}"
        ;;
      *)
        echo "Error: RALPH_PLAN_RUNTIME must be one of cursor, claude, or codex." >&2
        exit 1
        ;;
    esac
  else
    RUNTIME="$(prompt_select_runtime)" || exit 1
  fi
fi
HUMAN_ACTION_FILE="$WORKSPACE/HUMAN_ACTION_REQUIRED.md"

AGENTS_ROOT_REL=".${RUNTIME}/agents"

RALPH_RUN_PLAN_RELATIVE=".ralph/run-plan.sh --runtime ${RUNTIME}"

SELECT_MODEL_SCRIPT="$WORKSPACE/.${RUNTIME}/ralph/select-model.sh"
if [[ -f "$SELECT_MODEL_SCRIPT" ]]; then
  # shellcheck disable=SC1090
  source "$SELECT_MODEL_SCRIPT"
else
  echo "Error: select-model script not found for runtime $RUNTIME ($SELECT_MODEL_SCRIPT)." >&2
  exit 1
fi

MAX_ITERATIONS="${CURSOR_PLAN_MAX_ITER:-9999}"
GUTTER_ITERATIONS="${CURSOR_PLAN_GUTTER_ITER:-10}"

# Log to file and optionally stdout (if CURSOR_PLAN_VERBOSE=1)
log() {
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  mkdir -p "$(dirname "$LOG_FILE")"
  echo "[$ts] $*" >> "$LOG_FILE"
  if [[ "${CURSOR_PLAN_VERBOSE:-0}" == "1" ]]; then
    echo -e "${C_DIM}[$ts]${C_RST} $*" >&2
  fi
}

ralph_ensure_cursor_cli() {
  CURSOR_CLI=""
  if command -v cursor-agent &>/dev/null; then
    CURSOR_CLI="cursor-agent"
  elif command -v agent &>/dev/null; then
    CURSOR_CLI="agent"
  else
    log "ERROR: Cursor CLI not found (neither cursor-agent nor agent in PATH)"
    echo -e "${C_R}${C_BOLD}Cursor CLI is not installed or not logged in.${C_RST}"
    echo ""
    echo -e "This script requires the Cursor CLI. Please:"
    echo -e "  1. Install the CLI"
    echo -e "  2. Log in (e.g. run \`agent\` or \`cursor-agent\` and complete sign-in)"
    echo ""
    echo -e "Official installation and login instructions:"
    echo -e "  ${C_C}https://cursor.com/docs/cli/installation${C_RST}"
    echo ""
    echo -e "${C_DIM}After installing, add ~/.local/bin to your PATH, then run \`agent\` to log in and re-run this script.${C_RST}"
    exit 1
  fi
}

ralph_ensure_claude_cli() {
  local cli="${CLAUDE_PLAN_CLI:-}"
  if [[ -z "$cli" && -n "$(command -v claude 2>/dev/null)" ]]; then
    cli="claude"
  fi
  if [[ -z "$cli" ]] || ! command -v "$cli" &>/dev/null; then
    log "ERROR: Claude CLI not found (set CLAUDE_PLAN_CLI or install claude)"
    echo -e "${C_R}${C_BOLD}Claude Code CLI is not installed or not on PATH.${C_RST}"
    echo ""
    echo "Install Claude Code, then ensure \`claude\` is available:"
    echo -e "  ${C_C}https://code.claude.com/docs/en/overview${C_RST}"
    echo -e "  ${C_C}https://code.claude.com/docs/en/headless${C_RST}"
    echo ""
    exit 1
  fi
  CLAUDE_CLI="$cli"
  : "$CLAUDE_CLI"
}

ralph_ensure_codex_cli() {
  local cli="${CODEX_PLAN_CLI:-}"
  if [[ -z "$cli" && -n "$(command -v codex 2>/dev/null)" ]]; then
    cli="codex"
  fi
  if [[ -z "$cli" ]] || ! command -v "$cli" &>/dev/null; then
    log "ERROR: Codex CLI not found (set CODEX_PLAN_CLI or install codex)"
    echo -e "${C_R}${C_BOLD}Codex CLI is not installed or not on PATH.${C_RST}"
    echo ""
    echo "Install the Codex CLI and authenticate. Non-interactive runs use: codex exec"
    echo -e "  ${C_C}https://developers.openai.com/codex/noninteractive${C_RST}"
    echo -e "  ${C_C}https://developers.openai.com/codex/cli/reference${C_RST}"
    echo ""
    exit 1
  fi
  CODEX_CLI="$cli"
  : "$CODEX_CLI"
}

# Model id on stdout. Shared select_model_* from runtime-specific select-model.sh.
prompt_for_agent() {
  local cfg="" em
  case "$RUNTIME" in
    cursor)
      tr -d '\r' <<<"$(select_model_cursor --batch "$NON_INTERACTIVE_FLAG" "${CURSOR_PLAN_MODEL:-}" "$cfg")"
      ;;
    claude)
      em="${CLAUDE_PLAN_MODEL:-${CURSOR_PLAN_MODEL:-}}"
      tr -d '\r' <<<"$(select_model_claude --batch "$NON_INTERACTIVE_FLAG" "$em" "$cfg")"
      ;;
    codex)
      em="${CODEX_PLAN_MODEL:-${CURSOR_PLAN_MODEL:-}}"
      tr -d '\r' <<<"$(select_model_codex --batch "$NON_INTERACTIVE_FLAG" "$em" "$cfg")"
      ;;
    *)
      echo "Error: unsupported runtime for model selection: $RUNTIME" >&2
      return 1
      ;;
  esac
}

# Prebuilt agents live under WORKSPACE/.cursor/agents/<id>/config.json
prebuilt_agents_root() {
  echo "$1/$AGENTS_ROOT_REL"
}

# List agent ids via agent-config-tool (enumerates agent directories with config.json)
list_prebuilt_agent_ids() {
  local ws="$1"
  local root
  root="$(prebuilt_agents_root "$ws")"
  if [[ ! -f "$AGENT_CONFIG_TOOL" ]]; then
    echo "Error: shared agent tool missing: $AGENT_CONFIG_TOOL" >&2
    return 1
  fi
  bash "$AGENT_CONFIG_TOOL" list "$root" 2>/dev/null || true
}

# Validate config.json for agent id; exit non-zero on failure (messages on stderr)
validate_prebuilt_agent_config() {
  local ws="$1"
  local id="$2"
  local root
  root="$(prebuilt_agents_root "$ws")"
  bash "$AGENT_CONFIG_TOOL" validate "$root" "$id" "$ws"
}

# Model id from validated config (stdout)
read_prebuilt_agent_model() {
  local ws="$1"
  local id="$2"
  local root
  root="$(prebuilt_agents_root "$ws")"
  bash "$AGENT_CONFIG_TOOL" model "$root" "$id"
}

# Run context: validated config + inlined rule files + skills/artifacts (stdout)
format_prebuilt_agent_context_block() {
  local ws="$1"
  local id="$2"
  local root
  root="$(prebuilt_agents_root "$ws")"
  bash "$AGENT_CONFIG_TOOL" context "$root" "$id" "$ws"
}

# Interactive pick of prebuilt agent; prints agent id on stdout. Requires TTY.
prompt_select_prebuilt_agent() {
  local ws="$1"
  local list
  list="$(list_prebuilt_agent_ids "$ws")"
  if [[ -z "$list" ]]; then
    echo "Error: no prebuilt agents under $(prebuilt_agents_root "$ws")." >&2
    return 1
  fi
  if [[ ! -t 0 ]]; then
    echo "Error: --select-agent requires an interactive terminal. Use --agent <name> instead." >&2
    return 1
  fi
  if command -v fzf &>/dev/null; then
    local selected
  selected="$(printf '%s\n' "$list" | fzf --no-sort --height=20 --prompt="Prebuilt agent: " --header="Discovered under $AGENTS_ROOT_REL/" 2>/dev/null)" || true
    if [[ -z "$selected" ]]; then
      echo "Error: no prebuilt agent selected." >&2
      return 1
    fi
    echo "$selected"
    return 0
  fi
  echo "" >&2
  echo -e "${C_C}${C_BOLD}Prebuilt agents${C_RST} ${C_DIM}(${AGENTS_ROOT_REL})${C_RST}" >&2
  echo "" >&2
  local n=1
  local line
  local -a ids=()
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    ids+=("$line")
    local m
    m="$(read_prebuilt_agent_model "$ws" "$line" 2>/dev/null)" || m="?"
    printf "  ${C_G}%2d)${C_RST} %s  ${C_DIM}(model: %s)${C_RST}\n" "$n" "$line" "${m:-?}" >&2
    n=$((n + 1))
  done <<< "$list"
  echo "" >&2
  local selection_idx
  printf '%s' "${C_Y}${C_BOLD}Selection${C_RST}${C_DIM} [1]${C_RST}: " >&2
  read -r selection_idx </dev/tty 2>/dev/null || selection_idx="1"
  selection_idx="${selection_idx:-1}"
  if ! [[ "$selection_idx" =~ ^[0-9]+$ ]] || [[ "$selection_idx" -lt 1 ]] || [[ "$selection_idx" -gt ${#ids[@]} ]]; then
    echo "Error: invalid selection." >&2
    return 1
  fi
  printf '%s' "${ids[$((selection_idx - 1))]}"
}

# If prebuilt agents exist and no explicit selection flags were passed, ask whether
# to use a prebuilt agent or pick a model directly.
prompt_agent_source_mode() {
  local ws="$1"
  local list
  list="$(list_prebuilt_agent_ids "$ws")"
  if [[ -z "$list" ]]; then
    return 0
  fi
  if [[ "$NON_INTERACTIVE_FLAG" == "1" ]]; then
    return 0
  fi
  if [[ -n "$PREBUILT_AGENT" || "$INTERACTIVE_SELECT_AGENT_FLAG" == "1" ]]; then
    return 0
  fi
  # Direct model from CLI: skip "prebuilt vs model" menu (--select-agent returns above first).
  if [[ -n "${PLAN_MODEL_CLI:-}" ]]; then
    return 0
  fi

  echo "" >&2
  echo -e "${C_C}${C_BOLD}Agent setup${C_RST}" >&2
  echo -e "${C_DIM}Prebuilt agents under ${AGENTS_ROOT_REL}${C_RST}" >&2
  echo "" >&2
  echo -e "  ${C_G}1)${C_RST} Use a prebuilt agent ${C_DIM}(recommended)${C_RST}" >&2
  echo -e "  ${C_G}2)${C_RST} Select a model directly" >&2
  echo "" >&2

  local mode_choice
  printf '%s' "${C_Y}${C_BOLD}Selection${C_RST}${C_DIM} [1]${C_RST}: " >&2
  read -r mode_choice </dev/tty 2>/dev/null || mode_choice="1"
  mode_choice="${mode_choice:-1}"
  case "$mode_choice" in
    1)
      INTERACTIVE_SELECT_AGENT_FLAG=1
      ;;
    2)
      ;;
    *)
      echo -e "${C_Y}Invalid selection; defaulting to prebuilt agent.${C_RST}" >&2
      INTERACTIVE_SELECT_AGENT_FLAG=1
      ;;
  esac
}

PLAN_PATH="$(plan_normalize_path "$PLAN_OVERRIDE" "$WORKSPACE")"

# Per-plan logs and session files under .ralph-workspace/ (override with RALPH_PLAN_WORKSPACE_ROOT).
# Keeps agent-writable paths (pending-human.txt, etc.) out of .agents, which some CLIs sandbox or restrict.
PLAN_LOG_NAME="$(plan_log_basename "$PLAN_PATH")"
export RALPH_PLAN_KEY="${RALPH_PLAN_KEY:-$PLAN_LOG_NAME}"
export RALPH_ARTIFACT_NS="${RALPH_ARTIFACT_NS:-$RALPH_PLAN_KEY}"
RALPH_PLAN_WORKSPACE_ROOT="${RALPH_PLAN_WORKSPACE_ROOT:-$WORKSPACE/.ralph-workspace}"
RALPH_LOG_DIR="$RALPH_PLAN_WORKSPACE_ROOT/logs/$RALPH_ARTIFACT_NS"
AGENTS_SESSION_ROOT="$RALPH_PLAN_WORKSPACE_ROOT/sessions"
RALPH_SESSION_DIR="$AGENTS_SESSION_ROOT/${RALPH_PLAN_KEY}"
if [[ -z "${CURSOR_PLAN_LOG:-}" ]]; then
  LOG_FILE="$RALPH_LOG_DIR/plan-runner-${PLAN_LOG_NAME}.log"
else
  LOG_FILE="$CURSOR_PLAN_LOG"
fi
if [[ -z "${CURSOR_PLAN_OUTPUT_LOG:-}" ]]; then
  OUTPUT_LOG="$RALPH_LOG_DIR/plan-runner-${PLAN_LOG_NAME}-output.log"
else
  OUTPUT_LOG="$CURSOR_PLAN_OUTPUT_LOG"
fi
export OUTPUT_LOG

ralph_assert_path_not_env_secret "Plan file" "$PLAN_PATH"
ralph_assert_path_not_env_secret "Plan log" "$LOG_FILE"
ralph_assert_path_not_env_secret "Output log" "$OUTPUT_LOG"

case "$RUNTIME" in
  cursor)
    ralph_ensure_cursor_cli
    ;;
  claude)
    ralph_ensure_claude_cli
    ;;
  codex)
    ralph_ensure_codex_cli
    ;;
esac

RALPH_INVOKED_CLI=""
case "$RUNTIME" in
  cursor) RALPH_INVOKED_CLI="$CURSOR_CLI" ;;
  claude) RALPH_INVOKED_CLI="$CLAUDE_CLI" ;;
  codex) RALPH_INVOKED_CLI="$CODEX_CLI" ;;
esac

log "run-plan.sh started (workspace=$WORKSPACE plan=$PLAN_PATH)"
log "plan_path=$PLAN_PATH output_log=$OUTPUT_LOG log_file=$LOG_FILE"
log "artifact namespace: RALPH_ARTIFACT_NS=$RALPH_ARTIFACT_NS RALPH_PLAN_KEY=$RALPH_PLAN_KEY"

# Startup banner in output log (per-plan)
mkdir -p "$(dirname "$OUTPUT_LOG")"
{
  echo ""
  echo "################################################################################"
  echo "# Plan runner started $(date '+%Y-%m-%d %H:%M:%S') | workspace=$WORKSPACE"
  echo "# Plan: $PLAN_PATH (log prefix: plan-runner-${PLAN_LOG_NAME})"
  echo "################################################################################"
} >> "$OUTPUT_LOG"

if [[ "$NON_INTERACTIVE_FLAG" == "1" && -z "$PREBUILT_AGENT" && -z "${CURSOR_PLAN_MODEL:-}" && -z "${PLAN_MODEL_CLI:-}" ]]; then
  log "ERROR: --non-interactive requires --agent <name>, --model <id>, or CURSOR_PLAN_MODEL"
  echo -e "${C_R}${C_BOLD}Non-interactive mode requires a prebuilt agent, --model <id>, or CURSOR_PLAN_MODEL.${C_RST}" >&2
  exit 1
fi

if [[ ! -f "$PLAN_PATH" ]]; then
  log "ERROR: plan file not found: $PLAN_PATH"
  echo -e "${C_R}${C_BOLD}Plan file not found:${C_RST} ${C_R}$PLAN_PATH${C_RST}"
  echo -e "${C_DIM}Create the plan file or pass a valid path with --plan <path>.${C_RST}"
  exit 1
fi

log "plan file found: $PLAN_PATH"

mkdir -p "$RALPH_SESSION_DIR"
SESSION_ID_FILE="$RALPH_SESSION_DIR/session-id.txt"
export SESSION_ID_FILE
PENDING_HUMAN="$RALPH_SESSION_DIR/pending-human.txt"
HUMAN_CONTEXT="$RALPH_SESSION_DIR/human-replies.md"
OPERATOR_RESPONSE_FILE="$RALPH_SESSION_DIR/operator-response.txt"
HUMAN_INPUT_MD="$RALPH_SESSION_DIR/HUMAN-INPUT-REQUIRED.md"
PENDING_ABS="$PENDING_HUMAN"

_legacy_plan_sess="$WORKSPACE/.agents/sessions/${RALPH_PLAN_KEY}"
if [[ -d "$_legacy_plan_sess" ]]; then
  if [[ ! -s "$SESSION_ID_FILE" && -s "$_legacy_plan_sess/session-id.txt" ]]; then
    cp "$_legacy_plan_sess/session-id.txt" "$SESSION_ID_FILE"
    log "Migrated session-id.txt from $_legacy_plan_sess to $RALPH_SESSION_DIR"
  fi
  _mig_f=""
  for _mig_f in human-replies.md pending-human.txt operator-response.txt HUMAN-INPUT-REQUIRED.md; do
    if [[ ! -e "$RALPH_SESSION_DIR/$_mig_f" && -e "$_legacy_plan_sess/$_mig_f" ]]; then
      cp -a "$_legacy_plan_sess/$_mig_f" "$RALPH_SESSION_DIR/$_mig_f"
      log "Migrated $_mig_f from legacy .agents session dir"
    fi
  done
fi

if [[ -n "$RESUME_SESSION_ID_OVERRIDE" ]]; then
  printf '%s\n' "$RESUME_SESSION_ID_OVERRIDE" > "$SESSION_ID_FILE"
  log "Manual resume session id provided via --resume; recorded in $SESSION_ID_FILE"
fi

ralph_path_to_file_uri() {
  if command -v python3 &>/dev/null; then
    python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).resolve().as_uri())' "$1" 2>/dev/null || echo "file://localhost$1"
  else
    local encoded="${1// /%20}"
    echo "file://$encoded"
  fi
}

ralph_should_persist_human_files() {
  if [[ -t 0 && -t 1 ]]; then
    return 1
  fi
  return 0
}

ralph_restart_command_hint() {
  if [[ -n "${RALPH_ORCH_FILE:-}" ]]; then
    printf '.ralph/orchestrator.sh --orchestration %s' "$(printf '%q' "$RALPH_ORCH_FILE")"
  else
    printf '%s --non-interactive --plan %s --agent %s %s' \
      "$RALPH_RUN_PLAN_RELATIVE" \
      "$(printf '%q' "$PLAN_PATH")" \
      "$(printf '%q' "${PREBUILT_AGENT:-agent}")" \
      "$(printf '%q' "$WORKSPACE")"
  fi
}

ralph_operator_has_real_answer() {
  [[ -s "$OPERATOR_RESPONSE_FILE" ]] || return 1
  local _p _ph
  _p="$(tr -d '[:space:]' <"$OPERATOR_RESPONSE_FILE")"
  _ph="$(printf '%s' '(Replace this line with your answer to the question above, then save.)' | tr -d '[:space:]')"
  [[ "$_p" == "$_ph" ]] && return 1
  [[ -z "$_p" ]] && return 1
  return 0
}

ralph_remove_human_action_file() {
  if [[ -f "$HUMAN_ACTION_FILE" ]]; then
    rm -f "$HUMAN_ACTION_FILE"
    log "Removed human action file: $HUMAN_ACTION_FILE"
  fi
}

ralph_write_human_action_file() {
  local question="${1:-}"
  if [[ -z "$question" && -f "$PENDING_HUMAN" ]]; then
    question="$(cat "$PENDING_HUMAN")"
  fi
  [[ -n "$question" ]] || return 0

  local history="(no operator replies recorded yet)"
  if [[ -f "$HUMAN_CONTEXT" ]] && [[ -s "$HUMAN_CONTEXT" ]]; then
    history="$(cat "$HUMAN_CONTEXT")"
  fi

  local restart_hint
  restart_hint="$(ralph_restart_command_hint)"

  {
    printf '# HUMAN ACTION REQUIRED\n\n'
    printf 'The agent paused this plan step until your response.\n\n'
    printf '## Plan file\n%s\n\n' "$PLAN_PATH"
    printf '## Question from the agent\n\n%s\n\n' "$question"
    printf '## What to do\n'
    printf '1. Open %s and replace the placeholder line with your full answer.\n' "$OPERATOR_RESPONSE_FILE"
    printf '2. Save the file and leave pending-human.txt untouched; it will clear automatically after the answer is applied.\n'
    printf '3. If the plan runner is still running, it continues when you save. Otherwise restart: %s\n\n' "$restart_hint"
    printf '## Session\n'
    printf '- Pending question: %s\n' "$PENDING_HUMAN"
    printf '- Session directory: %s\n' "$RALPH_SESSION_DIR"
    printf '- Plan log: %s\n' "$LOG_FILE"
    printf '- Output log: %s\n\n' "$OUTPUT_LOG"
    printf '## Previous operator replies\n\n%s\n' "$history"
  } >"$HUMAN_ACTION_FILE"
  log "Wrote human action file: $HUMAN_ACTION_FILE"
}

ralph_sync_human_action_file_state() {
  if [[ -f "$PENDING_HUMAN" ]] && ! ralph_operator_has_real_answer; then
    if ralph_should_persist_human_files; then
      ralph_write_human_action_file
    else
      ralph_remove_human_action_file
    fi
  else
    ralph_remove_human_action_file
  fi
}

ralph_try_consume_human_response() {
  if [[ -f "$PENDING_HUMAN" ]] && ralph_operator_has_real_answer; then
    local _pq _pa
    _pq="$(cat "$PENDING_HUMAN")"
    _pa="$(cat "$OPERATOR_RESPONSE_FILE")"
    {
      echo ""
      echo "### $(date '+%Y-%m-%d %H:%M:%S')"
      echo "**Agent asked:**"
      echo "$_pq"
      echo "**Operator answered:**"
      echo "$_pa"
    } >>"$HUMAN_CONTEXT"
    rm -f "$PENDING_HUMAN" "$OPERATOR_RESPONSE_FILE"
    log "Applied answer from operator-response.txt; continuing plan run"
    return 0
  fi
  return 1
}

ralph_human_input_write_offline_instructions() {
  local _iu _ir _cmd_hint
  _iu="$(ralph_path_to_file_uri "$HUMAN_INPUT_MD")"
  _ir="$(ralph_path_to_file_uri "$OPERATOR_RESPONSE_FILE")"
  _cmd_hint="$(ralph_restart_command_hint)"
  {
    echo "# Paused for human input"
    echo ""
    echo "The plan runner is waiting in this same process until you answer (same behavior as an interactive TTY prompt)."
    echo ""
    echo "## Question from the agent"
    echo ""
    cat "$PENDING_HUMAN"
    echo ""
    echo "## What to do"
    echo ""
    echo "1. Open **operator-response.txt** in this folder, write your full answer, and save."
    echo "2. The runner detects the save and continues automatically. Do not delete pending-human.txt; it clears after your answer is applied."
    echo "3. If this process is no longer running, restart with: ${_cmd_hint}"
    echo ""
    echo "## Clickable links (terminal or browser address bar)"
    echo ""
    echo "- This instruction page: ${_iu}"
    echo "- Your answer file (edit here): ${_ir}"
    echo ""
    echo "## Paths"
    echo ""
    echo "- Session directory: $RALPH_SESSION_DIR"
    echo "- Plan file: $PLAN_PATH"
  } >"$HUMAN_INPUT_MD"

  if [[ ! -f "$OPERATOR_RESPONSE_FILE" ]] || [[ ! -s "$OPERATOR_RESPONSE_FILE" ]]; then
    printf '%s\n' '(Replace this line with your answer to the question above, then save.)' >"$OPERATOR_RESPONSE_FILE"
  fi
  ralph_write_human_action_file
  log "Wrote offline human instructions: $HUMAN_INPUT_MD"

  echo "" >&2
  echo -e "${C_Y}${C_BOLD}Paused for human input (no TTY).${C_RST}" >&2
  echo "  Instruction page: ${_iu}" >&2
  echo "  Answer file: ${_ir}" >&2
  echo "  Log: $LOG_FILE" >&2

  if [[ "$(uname -s)" == "Darwin" ]] && [[ "$HUMAN_PROMPT_NO_OPEN_FLAG" != "1" ]] && command -v open &>/dev/null; then
    open "$HUMAN_INPUT_MD" 2>/dev/null || true
    echo "  (Opened HUMAN-INPUT-REQUIRED.md in your default app.)" >&2
  fi
}

# When stdin is not a TTY, block until operator-response.txt has a real answer (orchestrator and CI can wait in-process).
ralph_human_pause_for_operator_offline() {
  if [[ "${RALPH_HUMAN_OFFLINE_EXIT:-0}" == "1" ]]; then
    ralph_human_input_write_offline_instructions
    log "EXIT 4: human input required (RALPH_HUMAN_OFFLINE_EXIT=1)"
    exit 4
  fi

  ralph_human_input_write_offline_instructions

  local interval="${RALPH_HUMAN_POLL_INTERVAL:-2}"
  local n=0
  log "Paused (no TTY): polling every ${interval}s for answer in $OPERATOR_RESPONSE_FILE"
  echo -e "${C_DIM}Waiting for a saved answer in operator-response.txt (poll every ${interval}s)...${C_RST}" >&2

  while ! ralph_operator_has_real_answer; do
    sleep "$interval"
    n=$((n + 1))
    if (( n % 15 == 0 )); then
      echo -e "${C_DIM}Still paused; edit and save ${OPERATOR_RESPONSE_FILE}${C_RST}" >&2
      log "still waiting for operator-response (elapsed ~$((n * interval))s)"
    fi
  done

  if ralph_try_consume_human_response; then
    ralph_sync_human_action_file_state
    log "Operator response applied; resuming plan run"
    echo -e "${C_G}Answer received. Continuing.${C_RST}" >&2
  fi
}

if ralph_try_consume_human_response; then
  :
elif [[ ! -f "$PENDING_HUMAN" ]]; then
  : >"$HUMAN_CONTEXT"
  rm -f "$OPERATOR_RESPONSE_FILE" "$HUMAN_INPUT_MD"
fi

ralph_sync_human_action_file_state

if [[ -f "$PENDING_HUMAN" ]] && ! ralph_operator_has_real_answer; then
  if [[ -t 0 ]] && [[ -t 1 ]]; then
    echo "" >&2
    echo -e "${C_Y}A previous run left a question. Answer below (end with line containing only .):${C_RST}" >&2
    cat "$PENDING_HUMAN" >&2
    echo "" >&2
    _hb=""
    while IFS= read -r _hl </dev/tty; do
      [[ "$_hl" == "." ]] && break
      _hb+="${_hl}"$'\n'
    done
    printf '%s\n' "${_hb:-(empty reply)}" >"$OPERATOR_RESPONSE_FILE"
    ralph_try_consume_human_response || true
    ralph_sync_human_action_file_state
  else
    ralph_human_pause_for_operator_offline
  fi
fi

log "session dir=$RALPH_SESSION_DIR"

if [[ "${_RALPH_PROMPT_CLI_RESUME_INTERACTIVE:-0}" == "1" ]]; then
  if [[ "$NON_INTERACTIVE_FLAG" != "1" ]] && [[ -t 0 ]] && [[ -t 1 ]]; then
    _cr_runtime_label=""
    case "$RUNTIME" in
      cursor) _cr_runtime_label="Cursor" ;;
      claude) _cr_runtime_label="Claude Code" ;;
      codex) _cr_runtime_label="Codex" ;;
      *) _cr_runtime_label="this agent" ;;
    esac
    echo "" >&2
    echo -e "${C_C}${C_BOLD}Session reuse${C_RST}" >&2
    echo -e "${C_BOLD}Keep one ${_cr_runtime_label} session for every TODO in this plan?${C_RST}" >&2
    echo "" >&2
    echo -e "${C_DIM}Use one session for the whole plan when it is short (about five TODOs or fewer). Ralph keeps each step narrow so history does not balloon; a leaner thread costs less in tokens and tends to run faster.${C_RST}" >&2
    echo -e "${C_DIM}For longer plans, prefer a new session per TODO.${C_RST}" >&2
    echo "" >&2
    echo -e "  ${C_G}y${C_RST}  ${C_BOLD}Yes${C_RST} -- same conversation across TODOs ${C_DIM}(remembers context)${C_RST}" >&2
    echo -e "  ${C_G}n${C_RST}  ${C_BOLD}No${C_RST}  -- new session per TODO ${C_DIM}(simpler; default: press Enter)${C_RST}" >&2
    echo "" >&2
    echo -e "${C_DIM}If Yes, an id is saved to:${C_RST}" >&2
    echo -e "${C_DIM}  ${SESSION_ID_FILE}${C_RST}" >&2
    echo -e "${C_DIM}Python 3 on PATH is required to capture that id from tool output.${C_RST}" >&2
    echo "" >&2
    printf '%s' "${C_Y}${C_BOLD}Your answer${C_RST}${C_DIM} -- type y or n, then Enter [y/N]${C_RST}: " >&2
    _cr_ans=""
    read -r _cr_ans </dev/tty 2>/dev/null || _cr_ans=""
    _cr_ans="$(echo "${_cr_ans:-}" | tr '[:upper:]' '[:lower:]')"
    unset _cr_runtime_label
    if [[ "$_cr_ans" == "y" || "$_cr_ans" == "yes" ]]; then
      RALPH_PLAN_CLI_RESUME=1
    else
      RALPH_PLAN_CLI_RESUME=0
    fi
  fi
  unset _RALPH_PROMPT_CLI_RESUME_INTERACTIVE
fi
export RALPH_PLAN_CLI_RESUME

# After this point, offer optional cleanup on exit (logs and Ralph artifacts).
ALLOW_CLEANUP_PROMPT=1
CLEANUP_SCRIPT="$WORKSPACE/.ralph/cleanup-plan.sh"
EXIT_STATUS="incomplete"
prompt_cleanup_on_exit() {
  trap - EXIT
  [[ "${ALLOW_CLEANUP_PROMPT:-0}" == "1" ]] || return 0
  [[ "$NON_INTERACTIVE_FLAG" == "1" ]] && return 0
  echo ""
  if [[ "$EXIT_STATUS" == "complete" ]]; then
    echo -e "${C_DIM}All TODOs are complete. Logs and artifacts available at:${C_RST}"
    echo -e "  ${C_B}Logs directory:${C_RST} $RALPH_LOG_DIR"
    echo -e "  ${C_B}Output log:${C_RST} $OUTPUT_LOG"
    echo -e "  ${C_B}Plan log:${C_RST} $LOG_FILE"
    echo ""
    echo -e "${C_DIM}To clean up logs and temporary files, run:${C_RST}"
    echo -e "  ${C_C}.ralph/cleanup-plan.sh ${RALPH_ARTIFACT_NS:-<artifact-namespace>} ${WORKSPACE}${C_RST}"
    return 0
  fi
  if [[ -t 0 && -t 1 ]]; then
    local ans
    echo -e "${C_C}${C_BOLD}Cleanup${C_RST}" >&2
    printf '%s' "${C_Y}${C_BOLD}Run cleanup now?${C_RST}${C_DIM} [y/N]${C_RST}: " >&2
    read -r ans </dev/tty 2>/dev/null || ans=""
    ans="$(echo "$ans" | tr '[:upper:]' '[:lower:]')"
    if [[ "$ans" == "y" || "$ans" == "yes" ]]; then
      "$CLEANUP_SCRIPT" "${RALPH_ARTIFACT_NS:-}" "$WORKSPACE"
      return 0
    fi
  fi
  echo -e "${C_DIM}Cleanup command:${C_RST} ${C_C}.ralph/cleanup-plan.sh ${RALPH_ARTIFACT_NS:-<artifact-namespace>} ${WORKSPACE}${C_RST}"
}
trap prompt_cleanup_on_exit EXIT

# Resolve agent/model: prebuilt (--agent / --select-agent) overrides manual model selection
PREBUILT_AGENT_CONTEXT=""
prompt_agent_source_mode "$WORKSPACE"
if [[ "$INTERACTIVE_SELECT_AGENT_FLAG" == "1" ]]; then
  PREBUILT_AGENT="$(prompt_select_prebuilt_agent "$WORKSPACE")" || exit 1
fi

if [[ -n "$PREBUILT_AGENT" ]]; then
  if [[ ! -f "$AGENT_CONFIG_TOOL" ]]; then
    echo -e "${C_R}agent-config-tool.sh is required for prebuilt agent validation and context.${C_RST}" >&2
    log "ERROR: missing $AGENT_CONFIG_TOOL for agent $PREBUILT_AGENT"
    exit 1
  fi
  _agents_root="$(prebuilt_agents_root "$WORKSPACE")"
  _discovered="$(list_prebuilt_agent_ids "$WORKSPACE" | paste -sd', ' -)"
  log "agent discovery (Cursor): root=$_agents_root ids=[${_discovered:-none}]"
  if ! validate_prebuilt_agent_config "$WORKSPACE" "$PREBUILT_AGENT"; then
    echo -e "${C_R}Invalid agent config for '${PREBUILT_AGENT}'.${C_RST} See .cursor/agents/README.md" >&2
    log "ERROR: validate failed for agent $PREBUILT_AGENT"
    exit 1
  fi
  SELECTED_MODEL="$(read_prebuilt_agent_model "$WORKSPACE" "$PREBUILT_AGENT")" || {
    echo -e "${C_R}Could not read model for prebuilt agent${C_RST} $PREBUILT_AGENT" >&2
    log "ERROR: model read failed for $PREBUILT_AGENT"
    exit 1
  }
  if [[ -n "${PLAN_MODEL_CLI:-}" ]]; then
    SELECTED_MODEL="$PLAN_MODEL_CLI"
    log "CLI --model overrides prebuilt agent default model (agent=$PREBUILT_AGENT)"
  fi
  PREBUILT_AGENT_CONTEXT="$(format_prebuilt_agent_context_block "$WORKSPACE" "$PREBUILT_AGENT")" || {
    echo -e "${C_R}Could not build run context for agent${C_RST} $PREBUILT_AGENT" >&2
    log "ERROR: context build failed for $PREBUILT_AGENT"
    exit 1
  }
  log "prebuilt agent id=$PREBUILT_AGENT model=$SELECTED_MODEL (config validated)"
  if [[ "$RUNTIME" == "claude" ]]; then
    _agents_root_for_tools="$(prebuilt_agents_root "$WORKSPACE")"
    CLAUDE_TOOLS_FROM_AGENT="$(bash "$AGENT_CONFIG_TOOL" allowed-tools "$_agents_root_for_tools" "$PREBUILT_AGENT" 2>/dev/null || true)"
    [[ -n "$CLAUDE_TOOLS_FROM_AGENT" ]] && log "allowed_tools from agent config: $CLAUDE_TOOLS_FROM_AGENT"
  else
    CLAUDE_TOOLS_FROM_AGENT=""
  fi
elif [[ -n "${PLAN_MODEL_CLI:-}" ]]; then
  SELECTED_MODEL="$PLAN_MODEL_CLI"
  log "using CLI --model: $SELECTED_MODEL"
else
  SELECTED_MODEL="$(prompt_for_agent)"
  if [[ -n "$SELECTED_MODEL" ]]; then
    log "using model: $SELECTED_MODEL"
  fi
fi

total_invocations=0

while true; do
  if ! next=$(get_next_todo "$PLAN_PATH"); then
    read -r done_count total_count <<< "$(count_todos "$PLAN_PATH")"
    log "all complete (done=$done_count total=$total_count) after $total_invocations agent invocation(s)"
    {
      echo ""
      echo "################################################################################"
      echo "# All TODOs complete ($done_count/$total_count) - $(date '+%Y-%m-%d %H:%M:%S')"
      echo "################################################################################"
    } >> "$OUTPUT_LOG"
    echo ""
    echo -e "${C_G}${C_BOLD}All TODOs complete${C_RST} ${C_G}($done_count/$total_count)${C_RST}."
    echo -e "${C_DIM}Output log: $OUTPUT_LOG${C_RST}"
    EXIT_STATUS="complete"
    exit 0
  fi

  line_num="${next%%|*}"
  full_line="${next#*|}"
  todo_text="$(plan_open_todo_body "$full_line")"

  attempts_on_line=0
  human_gate_satisfied_for_line=0
  while true; do
    total_invocations=$((total_invocations + 1))
    if [[ $total_invocations -gt $MAX_ITERATIONS ]]; then
      log "exceeded CURSOR_PLAN_MAX_ITER=$MAX_ITERATIONS"
      echo -e "${C_R}Too many agent invocations ($MAX_ITERATIONS).${C_RST} Raise CURSOR_PLAN_MAX_ITER or fix the plan." >&2
      exit 1
    fi
    iteration=$total_invocations

    read -r done_count total_count <<< "$(count_todos "$PLAN_PATH")"
    remaining=$((total_count - done_count))

    log "invocation=$iteration next_todo line=$line_num done=$done_count total=$total_count remaining=$remaining attempts_on_line=$attempts_on_line"
    log "todo_text: $todo_text"
    _session_label="none"
    if [[ -n "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]]; then
      _session_label="${RALPH_RUN_PLAN_RESUME_SESSION_ID}"
    elif [[ "${RALPH_RUN_PLAN_RESUME_BARE:-0}" == "1" ]]; then
      _session_label="bare"
    fi
    log "current task line=$line_num session=$_session_label"

    task_ordinal="$(plan_todo_ordinal_at_line "$PLAN_PATH" "$line_num")"

    echo ""
    echo -e "${C_C}${C_BOLD}══════════════════════════════════════════════════════════════════════${C_RST}"
    echo -e "${C_C}Building plan:${C_RST} $PLAN_PATH"
    echo -e "  ${C_DIM}${C_RST}  ${C_BOLD}TASK ${task_ordinal}${C_RST}  ${C_DIM}|${C_RST}  Complete ${C_G}$done_count/$total_count |${C_RST} Skipped: 0 ${C_DIM}|${C_RST}  ${C_Y}invoke $iteration${C_RST} (line $line_num)"
    echo -e "${C_C}${C_BOLD}══════════════════════════════════════════════════════════════════════${C_RST}"
    echo -e "${C_BOLD}$todo_text${C_RST}"
    echo -e "${C_DIM}Log: $LOG_FILE  |  Output: $OUTPUT_LOG${C_RST}"
    echo ""

    unset RALPH_RUN_PLAN_RESUME_SESSION_ID
    unset RALPH_RUN_PLAN_RESUME_BARE
    if [[ -n "$RESUME_SESSION_ID_OVERRIDE" ]]; then
      export RALPH_RUN_PLAN_RESUME_SESSION_ID="$RESUME_SESSION_ID_OVERRIDE"
    elif [[ "${RALPH_PLAN_CLI_RESUME:-0}" == "1" ]] && [[ -s "$SESSION_ID_FILE" ]]; then
      _resume_sid=""
      if read -r _resume_sid < "$SESSION_ID_FILE"; then
        _resume_sid="${_resume_sid//$'\r'/}"
        _resume_sid="${_resume_sid//$'\n'/}"
        _resume_sid="${_resume_sid#"${_resume_sid%%[![:space:]]*}"}"
        _resume_sid="${_resume_sid%"${_resume_sid##*[![:space:]]}"}"
      fi
      if [[ -n "$_resume_sid" ]]; then
        export RALPH_RUN_PLAN_RESUME_SESSION_ID="$_resume_sid"
        log "RALPH_PLAN_CLI_RESUME: using stored session id and compact prompt (--resume on the CLI)"
      fi
    fi
    if [[ "${RALPH_PLAN_CLI_RESUME:-0}" == "1" ]] && [[ -z "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]] && [[ "${RALPH_PLAN_ALLOW_UNSAFE_RESUME:-0}" == "1" ]]; then
      export RALPH_RUN_PLAN_RESUME_BARE=1
      log "RALPH_PLAN_ALLOW_UNSAFE_RESUME: no stored session id; using bare resume (wrong session possible on a busy host)"
      echo "Warning: bare CLI resume without a stored session id can attach to the wrong session when several projects use the same CLI on one machine. Prefer isolated CI or fix session capture." >&2
    fi

    if [[ -n "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]] || ([[ "${RALPH_RUN_PLAN_RESUME_BARE:-0}" == "1" ]] && [[ "${RALPH_PLAN_ALLOW_UNSAFE_RESUME:-0}" == "1" ]]); then
      if [[ -n "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]]; then
        _resume_intro="You are continuing the same CLI session for this workspace (runner session id is on file; the CLI is invoked with --resume)."
      else
        _resume_intro="You are continuing this workspace run using bare CLI resume (no session id on file; the CLI uses last-session semantics). This is unsafe on a shared workstation; typical in isolated CI."
      fi
      PROMPT="$_resume_intro

**Current TODO only (line $line_num):** $todo_text

**Plan file:** $PLAN_PATH
Open it, finish this TODO, change only the matching \`- [ ]\` to \`- [x]\`, save, and stop. Do not start the next unchecked item. Use the repo toolchain as documented (README, AGENTS.md, etc.).

**Artifact namespace:** RALPH_ARTIFACT_NS=$RALPH_ARTIFACT_NS  RALPH_PLAN_KEY=$RALPH_PLAN_KEY

**Human input (file only -- the runner does not read your assistant output):** If the operator must answer or choose before you can complete this TODO, do NOT mark [x]. Questions you ask only in your assistant message do not pause the run; the same TODO will be dispatched again. You MUST write your question as plain text to this path (create parent directories if needed):
$PENDING_ABS
Overwrite that file with your question, then stop this turn without checking the box. With a TTY the operator may answer inline; without a TTY the runner waits in-process for operator-response.txt. If you can finish without asking, mark [x] and do not create pending-human.txt.

If this TODO tells you to ask or confirm something with the user, you still must use that file first; marking [x] without a recorded operator reply from the runner is incorrect."

      if [[ -f "$HUMAN_CONTEXT" ]] && [[ -s "$HUMAN_CONTEXT" ]]; then
        PROMPT+=$'\n\n## Human operator answers (this plan run -- use them)\n'"$(cat "$HUMAN_CONTEXT")"
      fi
    else
      PROMPT="You are executing a single step of a plan. Do exactly this and nothing else:

**TODO:** $todo_text

**Rules:**
1. Implement only this one TODO.
2. Before running build, test, lint, or dev commands, use the toolchain and environment this repository documents (README, CONTRIBUTING, AGENTS.md, version files, Docker/devcontainer, etc.). Do not assume a specific language, runtime, or package manager.
3. Follow verification steps written in the plan file. If the plan says how to handle failing checks (revert, document in a named file, etc.), follow those instructions.
4. Then open the plan file \`$PLAN_PATH\`, find the line with this TODO (the first unchecked \`- [ ]\`), change \`[ ]\` to \`[x]\`, save the file, and stop.
5. Do not do the next TODO; only this one.
6. Human input (file only -- the runner does not read your chat): If the operator must answer or choose before you can complete this TODO, do NOT mark [x]. Questions you ask only in your assistant message do not pause the run; the same TODO will be dispatched again. You MUST write your question as plain text to this path (create parent directories if needed):
   $PENDING_ABS
   Overwrite that file with your question, then stop this turn without checking the box. With a TTY the operator may answer inline; without a TTY the runner waits in-process for operator-response.txt. If you can finish without asking, mark [x] and do not create pending-human.txt.

The plan file is at: $PLAN_PATH
The TODO to complete and then mark [x] is on line $line_num.

Artifact namespace for this run:
- RALPH_ARTIFACT_NS=$RALPH_ARTIFACT_NS
- RALPH_PLAN_KEY=$RALPH_PLAN_KEY

When writing handoff artifacts, use the namespace-aware paths from the prebuilt agent context."

      if [[ -f "$HUMAN_CONTEXT" ]] && [[ -s "$HUMAN_CONTEXT" ]]; then
        PROMPT+=$'\n\n## Human operator answers (this plan run -- use them)\n'"$(cat "$HUMAN_CONTEXT")"
      fi

      if [[ -n "$PREBUILT_AGENT_CONTEXT" ]]; then
        PROMPT+=$'\n'"$PREBUILT_AGENT_CONTEXT"
      fi
      if [[ -n "${RALPH_ORCH_FILE:-}" && -f "${RALPH_ORCH_FILE}" && -n "$PREBUILT_AGENT" && -f "$AGENT_CONFIG_TOOL" ]]; then
        _downstream_raw="$(bash "$AGENT_CONFIG_TOOL" downstream-stages "$RALPH_ORCH_FILE" "$PREBUILT_AGENT" "${RALPH_ARTIFACT_NS:-}" 2>/dev/null)" || _downstream_raw=""
        if [[ -n "$_downstream_raw" ]]; then
          PROMPT+=$'\n'"## Stage Plan Generation Responsibility"
          PROMPT+=$'\n'"The downstream stages below rely on you to populate their templates before they run. Complete the {{TODOS}} and {{ADDITIONAL_CONTEXT}} markers for each listed stage, write the plan file at the plan path, and hand the completed artifact off before moving ahead."
          _ds_stage_entries=()
          _ds_stage_id=""
          _ds_plan_path=""
          _ds_plan_template=""
          while IFS= read -r _ds_line || [[ -n "$_ds_line" ]]; do
            if [[ "$_ds_line" == "---" ]]; then
              if [[ -n "$_ds_stage_id" || -n "$_ds_plan_path" || -n "$_ds_plan_template" ]]; then
                _ds_stage_entries+=("$_ds_stage_id|$_ds_plan_path|$_ds_plan_template")
                _ds_stage_id=""
                _ds_plan_path=""
                _ds_plan_template=""
              fi
              continue
            fi
            case "$_ds_line" in
              STAGE_ID=*) _ds_stage_id="${_ds_line#STAGE_ID=}";;
              PLAN_PATH=*) _ds_plan_path="${_ds_line#PLAN_PATH=}";;
              PLAN_TEMPLATE=*) _ds_plan_template="${_ds_line#PLAN_TEMPLATE=}";;
            esac
          done <<< "$_downstream_raw"
          if [[ -n "$_ds_stage_id" || -n "$_ds_plan_path" || -n "$_ds_plan_template" ]]; then
            _ds_stage_entries+=("$_ds_stage_id|$_ds_plan_path|$_ds_plan_template")
          fi
          if [[ ${#_ds_stage_entries[@]} -gt 0 ]]; then
            _ds_stage_list=""
            for _ds_entry in "${_ds_stage_entries[@]}"; do
              _ds_stage_id="${_ds_entry%%|*}"
              _ds_rest="${_ds_entry#*|}"
              _ds_plan_path="${_ds_rest%%|*}"
              _ds_plan_template="${_ds_rest#*|}"
              PROMPT+=$'\n'"- Stage ID: ${_ds_stage_id:-unknown}, plan path: ${_ds_plan_path:-none}, template path: ${_ds_plan_template:-none}"
              _ds_stage_list+="${_ds_stage_id:-unknown}, "
            done
            _ds_stage_list="${_ds_stage_list%, }"
            log "downstream stage plan context appended for: ${_ds_stage_list:-none}"
          fi
        fi
      fi
    fi

    _invoke_resume_note=""
    _banner_resume_note=""
    if [[ -n "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]]; then
      _invoke_resume_note=" session_id=${RALPH_RUN_PLAN_RESUME_SESSION_ID}"
      _banner_resume_note=", session ${RALPH_RUN_PLAN_RESUME_SESSION_ID}"
    elif [[ "${RALPH_RUN_PLAN_RESUME_BARE:-0}" == "1" ]]; then
      _invoke_resume_note=" resume=bare"
      _banner_resume_note=", bare resume"
    fi
    log "invoking $RALPH_INVOKED_CLI (model=${SELECTED_MODEL:-default})${_invoke_resume_note}${PREBUILT_AGENT:+ prebuilt_agent=$PREBUILT_AGENT}"
    start_ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "${C_G}Starting agent ${C_BOLD}(${SELECTED_MODEL:-default})${C_RST}${C_G}${_banner_resume_note} for this TODO at ${start_ts}...${C_RST}"
    echo ""

    {
      echo ""
      echo "================================================================================"
      _olog_inv="[$(date '+%Y-%m-%d %H:%M:%S')] Invocation $iteration | TODO (line $line_num): $todo_text"
      if [[ -n "$_invoke_resume_note" ]]; then
        _olog_inv+=" |${_invoke_resume_note# }"
      fi
      echo "$_olog_inv"
      echo "================================================================================"
      echo ""
    } >> "$OUTPUT_LOG"

    cd "$WORKSPACE"

    EXIT_CODE_FILE="$RALPH_LOG_DIR/.plan-runner-exit.$$"
    PROGRESS_INTERVAL="${CURSOR_PLAN_PROGRESS_INTERVAL:-30}"
    START_TIME="$(date +%s)"
    LOG_SIZE_AT_START="$(wc -c < "$OUTPUT_LOG" 2>/dev/null || echo 0)"
    FIRST_RESPONSE_SHOWN=0
    LAST_PROGRESS_AT=0

    set +e
    case "$RUNTIME" in
      cursor)
        # shellcheck source=/Users/joshuajancula/Documents/projects/ralph/bundle/.ralph/bash-lib/run-plan-invoke-cursor.sh
        source "$SCRIPT_DIR/bash-lib/run-plan-invoke-cursor.sh"
        ralph_run_plan_invoke_cursor &
        ;;
      claude)
        # shellcheck source=/Users/joshuajancula/Documents/projects/ralph/bundle/.ralph/bash-lib/run-plan-invoke-claude.sh
        source "$SCRIPT_DIR/bash-lib/run-plan-invoke-claude.sh"
        ralph_run_plan_invoke_claude &
        ;;
      codex)
        # shellcheck source=/Users/joshuajancula/Documents/projects/ralph/.ralph/bash-lib/run-plan-invoke-codex.sh
        source "$SCRIPT_DIR/bash-lib/run-plan-invoke-codex.sh"
        ralph_run_plan_invoke_codex &
        ;;
      *)
        echo "Error: unsupported runtime for invocation: $RUNTIME" >&2
        exit 1
        ;;
    esac
    AGENT_PID=$!

    while kill -0 "$AGENT_PID" 2>/dev/null; do
      sleep 8
      if ! kill -0 "$AGENT_PID" 2>/dev/null; then
        break
      fi
      now="$(date +%s)"
      elapsed=$((now - START_TIME))

      if [[ $FIRST_RESPONSE_SHOWN -eq 0 ]]; then
        current_size="$(wc -c < "$OUTPUT_LOG" 2>/dev/null || echo 0)"
        if [[ "$current_size" -gt "$LOG_SIZE_AT_START" ]]; then
          FIRST_RESPONSE_SHOWN=1
          new_bytes=$((current_size - LOG_SIZE_AT_START))
          first_line="$(tail -c "$new_bytes" "$OUTPUT_LOG" 2>/dev/null | head -1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | head -c 120)"
          if [[ -n "$first_line" ]]; then
            echo -e "${C_DIM}[$(date '+%H:%M:%S')] Agent first output: ${first_line}${C_RST}" >&2
          else
            echo -e "${C_DIM}[$(date '+%H:%M:%S')] Agent has started producing output.${C_RST}" >&2
          fi
        fi
      fi

      if [[ $elapsed -ge $((LAST_PROGRESS_AT + PROGRESS_INTERVAL)) ]]; then
        LAST_PROGRESS_AT=$elapsed
        mins=$((elapsed / 60))
        secs=$((elapsed % 60))
        if [[ $mins -gt 0 ]]; then
          echo -e "${C_DIM}[$(date '+%H:%M:%S')] Agent still working (elapsed ${mins}m ${secs}s).${C_RST}" >&2
        else
          echo -e "${C_DIM}[$(date '+%H:%M:%S')] Agent still working (elapsed ${secs}s).${C_RST}" >&2
        fi
      fi
    done

    wait "$AGENT_PID" 2>/dev/null || true
    exit_code=125
    if [[ -f "$EXIT_CODE_FILE" ]]; then
      exit_code="$(cat "$EXIT_CODE_FILE")"
      rm -f "$EXIT_CODE_FILE"
    fi
    set -e
    log "$RALPH_INVOKED_CLI finished (exit=$exit_code)"

    echo "" >>"$OUTPUT_LOG"
    echo "--- End invocation $iteration ---" >>"$OUTPUT_LOG"

    if ! next_after=$(get_next_todo "$PLAN_PATH"); then
      read -r done_count total_count <<< "$(count_todos "$PLAN_PATH")"
      log "all complete (done=$done_count total=$total_count)"
      {
        echo ""
        echo "################################################################################"
        echo "# All TODOs complete ($done_count/$total_count) - $(date '+%Y-%m-%d %H:%M:%S')"
        echo "################################################################################"
      } >>"$OUTPUT_LOG"
      echo ""
      echo -e "${C_G}${C_BOLD}All TODOs complete${C_RST} ${C_G}($done_count/$total_count)${C_RST}."
      echo -e "${C_DIM}Output log: $OUTPUT_LOG${C_RST}"
      EXIT_STATUS="complete"
      exit 0
    fi
    next_line="${next_after%%|*}"

    if [[ "$next_line" != "$line_num" ]]; then
      if plan_todo_implies_operator_dialog "$todo_text" && [[ "$human_gate_satisfied_for_line" -eq 0 ]]; then
        log "TODO line $line_num implies operator dialog but advanced without a recorded human reply; reopening checklist line and pausing"
        echo "" >&2
        echo -e "${C_Y}${C_BOLD}This TODO asks the user for input, but the agent marked it done without using pending-human.txt.${C_RST}" >&2
        echo -e "${C_DIM}Reopening the item and pausing for your reply (same rules as a normal agent question).${C_RST}" >&2
        if ! plan_reopen_todo_at_line "$PLAN_PATH" "$line_num"; then
          log "ERROR: could not reopen TODO at line $line_num after missing human gate"
          echo -e "${C_R}Could not reopen plan line $line_num; fix PLAN.md manually.${C_RST}" >&2
          exit 1
        fi
        printf '%s\n' "$todo_text" >"$PENDING_HUMAN"
        ralph_sync_human_action_file_state
      else
        log "TODO line $line_num completed; next open TODO is line $next_line"
        rm -f "$PENDING_HUMAN"
        break
      fi
    fi

    ralph_sync_human_action_file_state

    if [[ -f "$PENDING_HUMAN" ]]; then
      if [[ "$HUMAN_PROMPT_DISABLE_FLAG" == "1" ]]; then
        log "ERROR: $PENDING_HUMAN exists but human prompt disable flag is active"
        echo -e "${C_R}Agent requested human input; prompts disabled. Remove pending file or unset CURSOR_PLAN_DISABLE_HUMAN_PROMPT or RALPH_PLAN_DISABLE_HUMAN_PROMPT.${C_RST}" >&2
        exit 4
      fi
      _saved_q="$(cat "$PENDING_HUMAN")"
      human_block=""

      if [[ -t 0 ]] && [[ -t 1 ]]; then
        echo "" >&2
        echo -e "${C_Y}${C_BOLD}--- Agent question (TODO stays open until resolved) ---${C_RST}" >&2
        echo "$_saved_q" >&2
        echo "" >&2
      echo -e "${C_B}Your answer (finish with a line containing only a dot):${C_RST}" >&2
        while IFS= read -r _hl </dev/tty; do
          [[ "$_hl" == "." ]] && break
          human_block+="${_hl}"$'\n'
        done
        if [[ -z "${human_block//[$' \t\n']/}" ]]; then
          human_block="(empty reply)"
        fi
        rm -f "$PENDING_HUMAN"
        {
          echo ""
          echo "### $(date '+%Y-%m-%d %H:%M:%S')"
          echo "**Agent asked:**"
          echo "$_saved_q"
          echo "**Operator answered:**"
          echo "$human_block"
        } >>"$HUMAN_CONTEXT"
        log "human reply recorded (TTY); re-invoking agent for line $line_num"
        ralph_sync_human_action_file_state
        echo -e "${C_G}Answer recorded. Re-running agent for this TODO...${C_RST}" >&2
        human_gate_satisfied_for_line=1
        attempts_on_line=0
        sleep 1
        continue
      fi
      ralph_human_pause_for_operator_offline
      human_gate_satisfied_for_line=1
      attempts_on_line=0
      sleep 1
      continue
    fi

    attempts_on_line=$((attempts_on_line + 1))
    if [[ $attempts_on_line -gt $GUTTER_ITERATIONS ]]; then
      log "GUTTER: line $line_num unchanged after $attempts_on_line attempts"
      echo "" >&2
      echo -e "${C_R}${C_BOLD}Agent did not complete this TODO after $attempts_on_line tries.${C_RST}" >&2
      echo -e "  Plan: $PLAN_PATH  Line $line_num: $todo_text" >&2
      echo -e "${C_DIM}To ask you a question instead of retrying blindly, the agent should write to:${C_RST}" >&2
      echo "  $PENDING_ABS" >&2
      exit 1
    fi
    log "TODO line $line_num still open (attempt $attempts_on_line/$GUTTER_ITERATIONS); retrying"
    sleep 2
  done
done
