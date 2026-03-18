#!/usr/bin/env bash
# Run one plan TODO at a time; loops until all TODOs are complete.
# Requires Cursor CLI (agent or cursor-agent); see https://cursor.com/docs/cli/installation
# Switch plans by editing .cursor/ralph/plan-runner.json or pass --plan.
#
# Usage:
#   .cursor/ralph/run-plan.sh                    # run from repo root (plan from config)
#   .cursor/ralph/run-plan.sh /path/repo         # run from specific repo
#   .cursor/ralph/run-plan.sh --plan OTHER.md    # use OTHER.md as plan (repo root)
#   .cursor/ralph/run-plan.sh --plan docs/plan.md /path/repo
#   .cursor/ralph/run-plan.sh --agent research    # use prebuilt agent model + context from .cursor/agents/research/
#   .cursor/ralph/run-plan.sh --select-agent      # interactive pick of prebuilt agent (TTY)
#   .cursor/ralph/run-plan.sh --non-interactive --agent research --plan PLAN.md
#   (--no-interactive is an alias for --non-interactive; no model menu when agent/config supplies model)
# Non-interactive mode:
#   - disables all prompts (agent/model selection and cleanup prompt)
#   - requires --agent <name> (errors if missing)
#   - errors if resolved plan file is missing
# Without --agent or --select-agent: CURSOR_PLAN_MODEL, config model, or the same interactive model menu as .ralph/new-agent.sh.
#
# Config: .cursor/ralph/plan-runner.json
#   { "plan": "PLAN.md", "model": "sonnet-4.6" }   plan path and optional default model
#
# Claude Code product agent teams are configured in .claude/settings.json for
# users of the Claude CLI; this Cursor CLI runner does not use that feature.
#
# Logging:
#   Per-plan log files: .agents/logs/<artifact-namespace>/plan-runner-<planname>.log and
#   .agents/logs/<artifact-namespace>/plan-runner-<planname>-output.log
#   Set CURSOR_PLAN_VERBOSE=1 to also print script events to stderr.
#   Override: CURSOR_PLAN_LOG=/path/to.log  CURSOR_PLAN_OUTPUT_LOG=/path/to-output.log
#   Disable colored terminal output: CURSOR_PLAN_NO_COLOR=1
#
# Gutter: If stuck on the same TODO for 10+ iterations without completing, script exits.
#   Override: CURSOR_PLAN_GUTTER_ITER=20
#
# Human-in-the-loop: The agent writes .cursor/ralph/.session/<plan-key>/pending-human.txt when it needs you.
# With a TTY: the runner prompts; answer (end with a line containing only .).
# Without a TTY: the runner exits 4, writes HUMAN-INPUT-REQUIRED.md (question + clickable file:// links),
# ensures operator-response.txt exists. You edit operator-response.txt with your answer, then restart the
# same command (orchestrator or run-plan). On restart, Q&A is merged into agent context and the run continues.
#   macOS: opens the instruction file unless CURSOR_PLAN_NO_OPEN=1
#   Disable: CURSOR_PLAN_DISABLE_HUMAN_PROMPT=1 (exit 4 if pending exists)
#
# Progress: While the agent runs, the script prints when the agent produced first output and
#   periodically "Agent still working (elapsed ...)". Interval: CURSOR_PLAN_PROGRESS_INTERVAL (default 30s).
#
# Caffeinate (macOS): On Darwin, the script runs under `caffeinate` so the system does not sleep
#   during execution. Disable with CURSOR_PLAN_NO_CAFFEINATE=1.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

# On macOS, re-exec under caffeinate so the system does not sleep during the plan run.
# CURSOR_PLAN_CAFFEINATED is set so we do not re-exec again when the script runs as caffeinate's child.
# Use bash explicitly: the orchestrator often runs `bash run-plan.sh` without +x; caffeinate would
# exec "$0" as a program and fail with "Permission denied" (exit 126) if the file is not executable.
if [[ "$(uname -s)" == "Darwin" ]] && \
   command -v caffeinate &>/dev/null && \
   [[ "${CURSOR_PLAN_NO_CAFFEINATE:-0}" != "1" ]] && \
   [[ "${CURSOR_PLAN_CAFFEINATED:-0}" != "1" ]]; then
  export CURSOR_PLAN_CAFFEINATED=1
  exec caffeinate -s -i -- /usr/bin/env bash "$SCRIPT_PATH" "$@"
fi
# shellcheck source=ralph-env-safety.sh
source "$SCRIPT_DIR/ralph-env-safety.sh"
AGENT_CONFIG_TOOL="$SCRIPT_DIR/agent-config-tool.sh"
AGENTS_ROOT_REL=".cursor/agents"

WORKSPACE="$(pwd)"
PLAN_OVERRIDE=""
PREBUILT_AGENT=""
INTERACTIVE_SELECT_AGENT_FLAG=0
NON_INTERACTIVE_FLAG=0

# Parse arguments: --plan, --agent, --select-agent, --non-interactive, optional workspace positional
while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --plan requires a plan file path." >&2
        exit 1
      fi
      PLAN_OVERRIDE="$2"
      shift 2
      ;;
    --agent)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --agent requires a prebuilt agent name (subdirectory of .cursor/agents/)." >&2
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

# shellcheck source=select-model.sh
source "$SCRIPT_DIR/select-model.sh"

CONFIG_FILE="$WORKSPACE/.cursor/ralph/plan-runner.json"
DEFAULT_PLAN="PLAN.md"
MAX_ITERATIONS="${CURSOR_PLAN_MAX_ITER:-9999}"
GUTTER_ITERATIONS="${CURSOR_PLAN_GUTTER_ITER:-10}"

# Colors (only when stdout is a TTY); set CURSOR_PLAN_NO_COLOR=1 to disable
if [[ -t 1 && "${CURSOR_PLAN_NO_COLOR:-0}" != "1" ]]; then
  C_R="\033[31m"
  C_G="\033[32m"
  C_Y="\033[33m"
  C_B="\033[34m"
  C_C="\033[36m"
  C_M="\033[35m"
  C_BOLD="\033[1m"
  C_DIM="\033[2m"
  C_RST="\033[0m"
else
  C_R="" C_G="" C_Y="" C_B="" C_C="" C_M="" C_BOLD="" C_DIM="" C_RST=""
fi

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

# Resolve plan file path from config or default (used when no --plan override)
get_plan_path() {
  if [[ -f "$CONFIG_FILE" ]]; then
    local plan
    plan="$(grep -o '"plan"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_FILE" 2>/dev/null | sed 's/.*"\([^"]*\)".*/\1/')"
    if [[ -n "$plan" ]]; then
      # Absolute path or ~: use as-is (expand ~); otherwise relative to workspace
      if [[ "$plan" == /* ]]; then
        echo "$plan"
      elif [[ "$plan" == ~* ]]; then
        echo "${plan/#\~/$HOME}"
      else
        echo "$WORKSPACE/$plan"
      fi
      return
    fi
  fi
  echo "$WORKSPACE/$DEFAULT_PLAN"
}

# Derive a safe log suffix from plan path (e.g. PLAN.md -> PLAN, docs/my-plan.md -> my-plan)
plan_log_basename() {
  local path="$1"
  local base
  base="$(basename "$path" | sed 's/\.[^.]*$//')"
  echo "$base" | sed 's/[^A-Za-z0-9_.-]/_/g'
}

# Read optional "model" from config (agent/model id for cursor-agent)
get_config_model() {
  if [[ -f "$CONFIG_FILE" ]]; then
    local model
    model="$(grep -o '"model"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_FILE" 2>/dev/null | sed 's/.*"\([^"]*\)".*/\1/')"
    if [[ -n "$model" ]]; then
      echo "$model"
    fi
  fi
}

# Model id on stdout. Shared select_model_cursor from .cursor/ralph/select-model.sh.
prompt_for_agent() {
  local cfg
  cfg="$(get_config_model)"
  tr -d '\r' <<<"$(select_model_cursor --batch "$NON_INTERACTIVE_FLAG" "${CURSOR_PLAN_MODEL:-}" "$cfg")"
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
    selected="$(echo "$list" | fzf --no-sort --height=20 --prompt="Prebuilt agent: " --header="Discovered under $AGENTS_ROOT_REL/" </dev/tty 2>/dev/null)" || true
    if [[ -z "$selected" ]]; then
      echo "Error: no prebuilt agent selected." >&2
      return 1
    fi
    echo "$selected"
    return 0
  fi
  echo "" >&2
  echo "Prebuilt agents:" >&2
  local n=1
  local line
  local -a ids=()
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    ids+=("$line")
    local m
    m="$(read_prebuilt_agent_model "$ws" "$line" 2>/dev/null)" || m="?"
    printf "  %2d) %s  (model: %s)\n" "$n" "$line" "${m:-?}" >&2
    n=$((n + 1))
  done <<< "$list"
  echo "" >&2
  local choice
  read -r -p "Pick prebuilt agent (1-$((n - 1))): " choice </dev/tty 2>/dev/null || true
  if [[ ! "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 || "$choice" -ge "$n" ]]; then
    echo "Error: invalid selection." >&2
    return 1
  fi
  echo "${ids[$((choice - 1))]}"
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

  echo "" >&2
  echo "Prebuilt agents detected under $AGENTS_ROOT_REL/." >&2
  echo "Choose how to run this plan:" >&2
  echo "  1) Use a prebuilt agent (recommended)" >&2
  echo "  2) Select a model directly" >&2

  local mode_choice
  read -r -p "Selection [1]: " mode_choice </dev/tty 2>/dev/null || mode_choice="1"
  mode_choice="${mode_choice:-1}"
  case "$mode_choice" in
    1)
      INTERACTIVE_SELECT_AGENT_FLAG=1
      ;;
    2)
      ;;
    *)
      echo "Invalid selection; defaulting to prebuilt agent." >&2
      INTERACTIVE_SELECT_AGENT_FLAG=1
      ;;
  esac
}

# Find first unchecked TODO line; output is "line_number|full_line_text"
get_next_todo() {
  local plan_path="$1"
  local line_num=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_num=$((line_num + 1))
    # Match "- [ ]" or "- [ ] " (optional space in bracket)
    if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+\[[[:space:]]\][[:space:]]*(.*) ]]; then
      echo "${line_num}|${line}"
      return 0
    fi
  done < "$plan_path"
  return 1
}

# Count TODOs for display (lines like "- [ ]" or "- [x]")
count_todos() {
  local plan_path="$1"
  local total=0
  local done=0
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+\[[[:space:]]\][[:space:]] ]]; then
      total=$((total + 1))
    elif [[ "$line" =~ ^[[:space:]]*-[[:space:]]+\[x\][[:space:]] ]]; then
      total=$((total + 1))
      done=$((done + 1))
    fi
  done < "$plan_path"
  echo "$done $total"
}

# Resolve plan path: --plan override takes precedence over config
if [[ -n "$PLAN_OVERRIDE" ]]; then
  if [[ "$PLAN_OVERRIDE" == /* ]]; then
    PLAN_PATH="$PLAN_OVERRIDE"
  elif [[ "$PLAN_OVERRIDE" == ~* ]]; then
    PLAN_PATH="${PLAN_OVERRIDE/#\~/$HOME}"
  else
    PLAN_PATH="$WORKSPACE/$PLAN_OVERRIDE"
  fi
else
  PLAN_PATH="$(get_plan_path)"
fi

# Per-plan log files under .agents/logs/<artifact-namespace> (unless overridden by env)
AGENTS_SHARED_DIR="$WORKSPACE/.agents"
PLAN_LOG_NAME="$(plan_log_basename "$PLAN_PATH")"
export RALPH_PLAN_KEY="${RALPH_PLAN_KEY:-$PLAN_LOG_NAME}"
export RALPH_ARTIFACT_NS="${RALPH_ARTIFACT_NS:-$RALPH_PLAN_KEY}"
RALPH_LOG_DIR="$AGENTS_SHARED_DIR/logs/$RALPH_ARTIFACT_NS"
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

ralph_assert_path_not_env_secret "Plan file" "$PLAN_PATH"
ralph_assert_path_not_env_secret "Plan log" "$LOG_FILE"
ralph_assert_path_not_env_secret "Output log" "$OUTPUT_LOG"

# Check for Cursor CLI (agent or cursor-agent); exit early if not installed
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

log "run-plan.sh started (workspace=$WORKSPACE plan=$PLAN_PATH)"
log "config=$CONFIG_FILE plan_path=$PLAN_PATH output_log=$OUTPUT_LOG log_file=$LOG_FILE"
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

if [[ "$NON_INTERACTIVE_FLAG" == "1" && -z "$PREBUILT_AGENT" ]]; then
  log "ERROR: --non-interactive requires --agent <name>"
  echo -e "${C_R}${C_BOLD}Non-interactive mode requires an explicit agent.${C_RST} Use --agent <name>." >&2
  exit 1
fi

if [[ ! -f "$PLAN_PATH" ]]; then
  log "ERROR: plan file not found: $PLAN_PATH"
  echo -e "${C_R}${C_BOLD}Plan file not found:${C_RST} ${C_R}$PLAN_PATH${C_RST}"
  echo -e "${C_DIM}Create it, set .cursor/ralph/plan-runner.json, or pass --plan <path> to use a different plan.${C_RST}"
  exit 1
fi

log "plan file found: $PLAN_PATH"

_SESSION_KEY="${RALPH_PLAN_KEY//[^A-Za-z0-9_.-]/_}"
RALPH_SESSION_DIR="$WORKSPACE/.cursor/ralph/.session/$_SESSION_KEY"
mkdir -p "$RALPH_SESSION_DIR"
PENDING_HUMAN="$RALPH_SESSION_DIR/pending-human.txt"
HUMAN_CONTEXT="$RALPH_SESSION_DIR/human-replies.md"
OPERATOR_RESPONSE_FILE="$RALPH_SESSION_DIR/operator-response.txt"
HUMAN_INPUT_MD="$RALPH_SESSION_DIR/HUMAN-INPUT-REQUIRED.md"
PENDING_ABS="$PENDING_HUMAN"

ralph_path_to_file_uri() {
  if command -v python3 &>/dev/null; then
    python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).resolve().as_uri())' "$1" 2>/dev/null || echo "file://localhost$1"
  else
    echo "file://$(echo "$1" | sed 's/ /%20/g')"
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

ralph_human_input_required_exit() {
  local _iu _ir _cmd_hint
  _iu="$(ralph_path_to_file_uri "$HUMAN_INPUT_MD")"
  _ir="$(ralph_path_to_file_uri "$OPERATOR_RESPONSE_FILE")"
  if [[ -n "${RALPH_ORCH_FILE:-}" ]]; then
    _cmd_hint=".ralph/orchestrator.sh --orchestration $(printf '%q' "$RALPH_ORCH_FILE")"
  else
    _cmd_hint=".cursor/ralph/run-plan.sh --non-interactive --plan $(printf '%q' "$PLAN_PATH") --agent $(printf '%q' "${PREBUILT_AGENT:-agent}") $(printf '%q' "$WORKSPACE")"
  fi
  {
    echo "# Human input required"
    echo ""
    echo "The agent stopped this plan step until you answer."
    echo ""
    echo "## Question from the agent"
    echo ""
    cat "$PENDING_HUMAN"
    echo ""
    echo "## What to do"
    echo ""
    echo "1. Open **operator-response.txt** in this same folder, write your full answer, and save."
    echo "2. Restart the same command you ran (orchestrator or run-plan). Do not delete pending-human.txt before restarting; it will be cleared automatically after your answer is applied."
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
    echo ""
    echo "## Example restart"
    echo ""
    echo "${_cmd_hint}"
  } >"$HUMAN_INPUT_MD"

  printf '%s\n' '(Replace this line with your answer to the question above, then save.)' >"$OPERATOR_RESPONSE_FILE"

  log "EXIT 4: human input required (no TTY). Wrote $HUMAN_INPUT_MD"
  echo "" >&2
  echo -e "${C_Y}${C_BOLD}Human input required -- exiting so you can answer offline.${C_RST}" >&2
  echo "" >&2
  echo "  Instruction page (open in editor or click if your terminal supports file links):" >&2
  echo "    ${_iu}" >&2
  echo "" >&2
  echo "  Write your answer here, then save:" >&2
  echo "    ${_ir}" >&2
  echo "" >&2
  echo "  Then restart the same script (orchestrator or run-plan)." >&2
  echo "  Log: $LOG_FILE" >&2

  if [[ "$(uname -s)" == "Darwin" ]] && [[ "${CURSOR_PLAN_NO_OPEN:-0}" != "1" ]] && command -v open &>/dev/null; then
    open "$HUMAN_INPUT_MD" 2>/dev/null || true
    echo "  (Opened HUMAN-INPUT-REQUIRED.md in your default app.)" >&2
  fi
  exit 4
}

if ralph_try_consume_human_response; then
  :
elif [[ ! -f "$PENDING_HUMAN" ]]; then
  : >"$HUMAN_CONTEXT"
  rm -f "$OPERATOR_RESPONSE_FILE" "$HUMAN_INPUT_MD"
fi

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
  else
    ralph_human_input_required_exit
  fi
fi

log "session dir=$RALPH_SESSION_DIR"

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
    read -r -p "Run cleanup now? [y/N] " ans </dev/tty 2>/dev/null || ans=""
    ans="$(echo "$ans" | tr '[:upper:]' '[:lower:]')"
    if [[ "$ans" == "y" || "$ans" == "yes" ]]; then
  "$CLEANUP_SCRIPT" "${RALPH_ARTIFACT_NS:-}" "$WORKSPACE"
      return 0
    fi
  fi
  echo "Cleanup command: .ralph/cleanup-plan.sh ${RALPH_ARTIFACT_NS:-<artifact-namespace>} ${WORKSPACE}"
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
  PREBUILT_AGENT_CONTEXT="$(format_prebuilt_agent_context_block "$WORKSPACE" "$PREBUILT_AGENT")" || {
    echo -e "${C_R}Could not build run context for agent${C_RST} $PREBUILT_AGENT" >&2
    log "ERROR: context build failed for $PREBUILT_AGENT"
    exit 1
  }
  log "prebuilt agent id=$PREBUILT_AGENT model=$SELECTED_MODEL (config validated)"
else
  SELECTED_MODEL="$(prompt_for_agent)"
  if [[ -n "$SELECTED_MODEL" ]]; then
    log "using model: $SELECTED_MODEL"
  fi
fi

total_invocations=0

while true; do
  if ! next=$(get_next_todo "$PLAN_PATH"); then
    read -r done total <<< "$(count_todos "$PLAN_PATH")"
    log "all complete (done=$done total=$total) after $total_invocations agent invocation(s)"
    {
      echo ""
      echo "################################################################################"
      echo "# All TODOs complete ($done/$total) - $(date '+%Y-%m-%d %H:%M:%S')"
      echo "################################################################################"
    } >> "$OUTPUT_LOG"
    echo ""
    echo -e "${C_G}${C_BOLD}All TODOs complete${C_RST} ${C_G}($done/$total)${C_RST}."
    echo -e "${C_DIM}Output log: $OUTPUT_LOG${C_RST}"
    EXIT_STATUS="complete"
    exit 0
  fi

  line_num="${next%%|*}"
  full_line="${next#*|}"
  todo_text="$(echo "$full_line" | sed -E 's/^[[:space:]]*-[[:space:]]+\[[[:space:]]\][[:space:]]*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

  attempts_on_line=0
  while true; do
    total_invocations=$((total_invocations + 1))
    if [[ $total_invocations -gt $MAX_ITERATIONS ]]; then
      log "exceeded CURSOR_PLAN_MAX_ITER=$MAX_ITERATIONS"
      echo -e "${C_R}Too many agent invocations ($MAX_ITERATIONS).${C_RST} Raise CURSOR_PLAN_MAX_ITER or fix the plan." >&2
      exit 1
    fi
    iteration=$total_invocations

    read -r done total <<< "$(count_todos "$PLAN_PATH")"
    remaining=$((total - done))

    log "invocation=$iteration next_todo line=$line_num done=$done total=$total remaining=$remaining attempts_on_line=$attempts_on_line"
    log "todo_text: $todo_text"

    echo ""
    echo -e "${C_C}${C_BOLD}══════════════════════════════════════════════════════════════${C_RST}"
    echo -e "${C_C}Building plan:${C_RST} $PLAN_PATH  ${C_DIM}|${C_RST}  ${C_G}$done/$total${C_RST}  ${C_DIM}|${C_RST}  ${C_Y}invoke $iteration${C_RST} (line $line_num)"
    echo -e "${C_C}${C_BOLD}══════════════════════════════════════════════════════════════${C_RST}"
    echo -e "${C_BOLD}$todo_text${C_RST}"
    echo -e "${C_DIM}Log: $LOG_FILE  |  Output: $OUTPUT_LOG${C_RST}"
    echo ""

    PROMPT="You are executing a single step of a plan. Do exactly this and nothing else:

**TODO:** $todo_text

**Rules:**
1. Implement only this one TODO.
2. Before running build, test, lint, or dev commands, use the toolchain and environment this repository documents (README, CONTRIBUTING, AGENTS.md, version files, Docker/devcontainer, etc.). Do not assume a specific language, runtime, or package manager.
3. Follow verification steps written in the plan file. If the plan says how to handle failing checks (revert, document in a named file, etc.), follow those instructions.
4. Then open the plan file \`$PLAN_PATH\`, find the line with this TODO (the first unchecked \`- [ ]\`), change \`[ ]\` to \`[x]\`, save the file, and stop.
5. Do not do the next TODO; only this one.
6. Human input: If you cannot complete this TODO without a policy or technical decision from the human operator, do NOT mark the checkbox. Write only your question (plain text, be specific) to this file (create parent directories if needed):
   $PENDING_ABS
   Then stop. With a terminal the operator answers interactively. Without a terminal the runner exits, writes HUMAN-INPUT-REQUIRED.md with links, and the operator edits operator-response.txt in the same session folder then restarts the script; you will run again with their answer. If you can finish without asking, mark [x] and do not create that file.

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

    log "invoking $CURSOR_CLI (model=${SELECTED_MODEL:-default})${PREBUILT_AGENT:+ prebuilt_agent=$PREBUILT_AGENT}"
    start_ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "${C_G}Starting agent ${C_BOLD}(${SELECTED_MODEL:-default})${C_RST}${C_G} for this TODO at ${start_ts}...${C_RST}"
    echo ""

    {
      echo ""
      echo "================================================================================"
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] Invocation $iteration | TODO (line $line_num): $todo_text"
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

    run_agent() {
      if [[ -n "${SELECTED_MODEL:-}" ]]; then
        "$CURSOR_CLI" -p --force --model "$SELECTED_MODEL" "$PROMPT" 2>&1 | tee -a "$OUTPUT_LOG"
      else
        "$CURSOR_CLI" -p --force "$PROMPT" 2>&1 | tee -a "$OUTPUT_LOG"
      fi
      echo "${PIPESTATUS[0]}" >"$EXIT_CODE_FILE"
    }

    set +e
    run_agent &
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
    log "$CURSOR_CLI finished (exit=$exit_code)"

    echo "" >>"$OUTPUT_LOG"
    echo "--- End invocation $iteration ---" >>"$OUTPUT_LOG"

    if ! next_after=$(get_next_todo "$PLAN_PATH"); then
      read -r done total <<< "$(count_todos "$PLAN_PATH")"
      log "all complete (done=$done total=$total)"
      {
        echo ""
        echo "################################################################################"
        echo "# All TODOs complete ($done/$total) - $(date '+%Y-%m-%d %H:%M:%S')"
        echo "################################################################################"
      } >>"$OUTPUT_LOG"
      echo ""
      echo -e "${C_G}${C_BOLD}All TODOs complete${C_RST} ${C_G}($done/$total)${C_RST}."
      echo -e "${C_DIM}Output log: $OUTPUT_LOG${C_RST}"
      EXIT_STATUS="complete"
      exit 0
    fi
    next_line="${next_after%%|*}"

    if [[ "$next_line" != "$line_num" ]]; then
      log "TODO line $line_num completed; next open TODO is line $next_line"
      rm -f "$PENDING_HUMAN"
      break
    fi

    if [[ -f "$PENDING_HUMAN" ]]; then
      if [[ "${CURSOR_PLAN_DISABLE_HUMAN_PROMPT:-0}" == "1" ]]; then
        log "ERROR: $PENDING_HUMAN exists but CURSOR_PLAN_DISABLE_HUMAN_PROMPT=1"
        echo -e "${C_R}Agent requested human input; prompts disabled. Remove pending file or unset CURSOR_PLAN_DISABLE_HUMAN_PROMPT.${C_RST}" >&2
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
        echo -e "${C_G}Answer recorded. Re-running agent for this TODO...${C_RST}" >&2
        attempts_on_line=0
        sleep 1
        continue
      fi
      ralph_human_input_required_exit
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
