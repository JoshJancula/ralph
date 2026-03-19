#!/usr/bin/env bash
# Run one plan TODO at a time; loops until all TODOs are complete.
# Requires Codex CLI (`codex exec`); see https://developers.openai.com/codex/noninteractive
# Switch plans by editing .codex/ralph/plan-runner.json or pass --plan (same flags as Cursor/Claude ralph).
#
# Usage:
#   .codex/ralph/run-plan.sh
#   .codex/ralph/run-plan.sh /path/repo
#   .codex/ralph/run-plan.sh --plan OTHER.md
#   .codex/ralph/run-plan.sh --agent research   # prebuilt agent from .codex/agents/<name>/
#   .codex/ralph/run-plan.sh --select-agent
#   .codex/ralph/run-plan.sh --non-interactive --agent research --plan PLAN.md
# Non-interactive mode:
#   - disables prompts (cleanup prompt)
#   - requires --agent <name>
#   - errors if resolved plan file is missing
#
# Config (first match): .codex/ralph/plan-runner.json, then shared .ralph/plan-runner.json
#   { "plan": "PLAN.md", "model": "auto" }
#
# Codex-specific env:
#   CODEX_PLAN_CLI         path to codex binary (default: codex on PATH)
#   CODEX_PLAN_SANDBOX     passed to codex exec --sandbox (default: workspace-write)
#   CODEX_PLAN_EXEC_EXTRA  extra args before prompt (space-separated)
#
# Shared (CODEX_* or CURSOR_*):
#   *_PLAN_MODEL, *_PLAN_VERBOSE, *_PLAN_LOG, *_PLAN_OUTPUT_LOG, *_PLAN_NO_COLOR
#   *_PLAN_GUTTER_ITER, *_PLAN_MAX_ITER, *_PLAN_PROGRESS_INTERVAL
#   *_PLAN_NO_CAFFEINATE, *_PLAN_CAFFEINATED
#
# Logging:
#   .agents/logs/<artifact-namespace>/plan-runner-<planname>.log and plan-runner-<planname>-output.log
#
# Gutter: same TODO repeated past *_PLAN_GUTTER_ITER (default 10).
# Progress: first output line plus periodic elapsed messages (*_PLAN_PROGRESS_INTERVAL, default 30s).
# Caffeinate (macOS): re-exec under caffeinate unless *_PLAN_NO_CAFFEINATE=1.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

# Re-exec via bash so `bash run-plan.sh` works when the file is not chmod +x (e.g. after editor save).
if [[ "$(uname -s)" == "Darwin" ]] && \
   command -v caffeinate &>/dev/null && \
   [[ "${CODEX_PLAN_NO_CAFFEINATE:-${CLAUDE_PLAN_NO_CAFFEINATE:-${CURSOR_PLAN_NO_CAFFEINATE:-0}}}" != "1" ]] && \
   [[ "${CODEX_PLAN_CAFFEINATED:-${CLAUDE_PLAN_CAFFEINATED:-${CURSOR_PLAN_CAFFEINATED:-0}}}" != "1" ]]; then
  export CODEX_PLAN_CAFFEINATED=1
  exec caffeinate -s -i -- /usr/bin/env bash "$SCRIPT_PATH" "$@"
fi

WORKSPACE="$(pwd)"
PLAN_OVERRIDE=""
PREBUILT_AGENT=""
INTERACTIVE_SELECT_AGENT_FLAG=0
NON_INTERACTIVE_FLAG=0

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
        echo "Error: --agent requires a prebuilt agent name (subdirectory of .codex/agents/)." >&2
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
# shellcheck source=/dev/null
source "$WORKSPACE/.ralph/ralph-env-safety.sh"
AGENT_CONFIG_TOOL="$WORKSPACE/.ralph/agent-config-tool.sh"
AGENTS_ROOT_REL=".codex/agents"

# Shared config discovery: prefer runtime config and fall back to `.ralph/plan-runner.json`.
if [[ -f "$WORKSPACE/.codex/ralph/plan-runner.json" ]]; then
  CONFIG_FILE="$WORKSPACE/.codex/ralph/plan-runner.json"
elif [[ -f "$WORKSPACE/.ralph/plan-runner.json" ]]; then
  CONFIG_FILE="$WORKSPACE/.ralph/plan-runner.json"
else
  CONFIG_FILE="$WORKSPACE/.codex/ralph/plan-runner.json"
fi

DEFAULT_PLAN="PLAN.md"
MAX_ITERATIONS="${CODEX_PLAN_MAX_ITER:-${CLAUDE_PLAN_MAX_ITER:-${CURSOR_PLAN_MAX_ITER:-9999}}}"
GUTTER_ITERATIONS="${CODEX_PLAN_GUTTER_ITER:-${CLAUDE_PLAN_GUTTER_ITER:-${CURSOR_PLAN_GUTTER_ITER:-10}}}"
CODEX_PLAN_VERBOSE="${CODEX_PLAN_VERBOSE:-${CLAUDE_PLAN_VERBOSE:-${CURSOR_PLAN_VERBOSE:-0}}}"
CODEX_PLAN_NO_COLOR="${CODEX_PLAN_NO_COLOR:-${CLAUDE_PLAN_NO_COLOR:-${CURSOR_PLAN_NO_COLOR:-0}}}"

if [[ -t 1 && "$CODEX_PLAN_NO_COLOR" != "1" ]]; then
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

log() {
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  mkdir -p "$(dirname "$LOG_FILE")"
  echo "[$ts] $*" >> "$LOG_FILE"
  if [[ "$CODEX_PLAN_VERBOSE" == "1" ]]; then
    echo -e "${C_DIM}[$ts]${C_RST} $*" >&2
  fi
}

get_plan_path() {
  if [[ -f "$CONFIG_FILE" ]]; then
    local plan
    plan="$(grep -o '"plan"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_FILE" 2>/dev/null | sed 's/.*"\([^"]*\)".*/\1/')"
    if [[ -n "$plan" ]]; then
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

plan_log_basename() {
  local path="$1"
  local base
  base="$(basename "$path" | sed 's/\.[^.]*$//')"
  echo "$base" | sed 's/[^A-Za-z0-9_.-]/_/g'
}

get_config_model() {
  if [[ -f "$CONFIG_FILE" ]]; then
    local model
    model="$(grep -o '"model"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_FILE" 2>/dev/null | sed 's/.*"\([^"]*\)".*/\1/')"
    if [[ -n "$model" ]]; then
      echo "$model"
    fi
  fi
}

prompt_for_agent() {
  local cfg em
  cfg="$(get_config_model)"
  em="${CODEX_PLAN_MODEL:-${CURSOR_PLAN_MODEL:-}}"
  tr -d '\r' <<<"$(select_model_codex --batch "$NON_INTERACTIVE_FLAG" "$em" "$cfg")"
}

prebuilt_agents_root() {
  echo "$1/$AGENTS_ROOT_REL"
}

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

validate_prebuilt_agent_config() {
  local ws="$1"
  local id="$2"
  local root
  root="$(prebuilt_agents_root "$ws")"
  bash "$AGENT_CONFIG_TOOL" validate "$root" "$id" "$ws"
}

read_prebuilt_agent_model() {
  local ws="$1"
  local id="$2"
  local root
  root="$(prebuilt_agents_root "$ws")"
  bash "$AGENT_CONFIG_TOOL" model "$root" "$id"
}

format_prebuilt_agent_context_block() {
  local ws="$1"
  local id="$2"
  local root
  root="$(prebuilt_agents_root "$ws")"
  bash "$AGENT_CONFIG_TOOL" context "$root" "$id" "$ws"
}

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
  echo "  2) Proceed with Codex default model" >&2

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
      echo "Invalid selection. Using default (prebuilt agent)." >&2
      INTERACTIVE_SELECT_AGENT_FLAG=1
      ;;
  esac
}

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
  local n=1 line
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

get_next_todo() {
  local plan_path="$1"
  local line_num=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_num=$((line_num + 1))
    if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+\[[[:space:]]\][[:space:]]*(.*) ]]; then
      echo "${line_num}|${line}"
      return 0
    fi
  done < "$plan_path"
  return 1
}

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

AGENTS_SHARED_DIR="$WORKSPACE/.agents"
PLAN_LOG_NAME="$(plan_log_basename "$PLAN_PATH")"
export RALPH_PLAN_KEY="${RALPH_PLAN_KEY:-$PLAN_LOG_NAME}"
export RALPH_ARTIFACT_NS="${RALPH_ARTIFACT_NS:-$RALPH_PLAN_KEY}"
RALPH_LOG_DIR="$AGENTS_SHARED_DIR/logs/$RALPH_ARTIFACT_NS"
_PLAN_LOG="${CODEX_PLAN_LOG:-${CLAUDE_PLAN_LOG:-${CURSOR_PLAN_LOG:-}}}"
_PLAN_OUTPUT_LOG="${CODEX_PLAN_OUTPUT_LOG:-${CLAUDE_PLAN_OUTPUT_LOG:-${CURSOR_PLAN_OUTPUT_LOG:-}}}"
if [[ -z "$_PLAN_LOG" ]]; then
  LOG_FILE="$RALPH_LOG_DIR/plan-runner-${PLAN_LOG_NAME}.log"
else
  LOG_FILE="$_PLAN_LOG"
fi
if [[ -z "$_PLAN_OUTPUT_LOG" ]]; then
  OUTPUT_LOG="$RALPH_LOG_DIR/plan-runner-${PLAN_LOG_NAME}-output.log"
else
  OUTPUT_LOG="$_PLAN_OUTPUT_LOG"
fi

ralph_assert_path_not_env_secret "Plan file" "$PLAN_PATH"
ralph_assert_path_not_env_secret "Plan log" "$LOG_FILE"
ralph_assert_path_not_env_secret "Output log" "$OUTPUT_LOG"

CODEX_CLI="${CODEX_PLAN_CLI:-}"
if [[ -z "$CODEX_CLI" ]] && command -v codex &>/dev/null; then
  CODEX_CLI="codex"
fi
if [[ -z "$CODEX_CLI" ]] || ! command -v "$CODEX_CLI" &>/dev/null; then
  mkdir -p "$(dirname "${LOG_FILE:-$RALPH_LOG_DIR/plan-runner.log}")"
  LOG_FILE="${LOG_FILE:-$RALPH_LOG_DIR/plan-runner.log}"
  log "ERROR: Codex CLI not found (set CODEX_PLAN_CLI or install codex)"
  echo -e "${C_R}${C_BOLD}Codex CLI is not installed or not on PATH.${C_RST}"
  echo ""
  echo "Install the Codex CLI and authenticate. Non-interactive runs use: codex exec"
  echo -e "  ${C_C}https://developers.openai.com/codex/noninteractive${C_RST}"
  echo -e "  ${C_C}https://developers.openai.com/codex/cli/reference${C_RST}"
  echo ""
  exit 1
fi

log "run-plan.sh started (workspace=$WORKSPACE plan=$PLAN_PATH)"
log "config=$CONFIG_FILE plan_path=$PLAN_PATH output_log=$OUTPUT_LOG log_file=$LOG_FILE"
log "artifact namespace: RALPH_ARTIFACT_NS=$RALPH_ARTIFACT_NS RALPH_PLAN_KEY=$RALPH_PLAN_KEY"

mkdir -p "$(dirname "$OUTPUT_LOG")"
{
  echo ""
  echo "################################################################################"
  echo "# Plan runner (Codex) started $(date '+%Y-%m-%d %H:%M:%S') | workspace=$WORKSPACE"
  echo "# Plan: $PLAN_PATH (log prefix: plan-runner-${PLAN_LOG_NAME})"
  echo "################################################################################"
} >> "$OUTPUT_LOG"

if [[ "$NON_INTERACTIVE_FLAG" == "1" && -z "$PREBUILT_AGENT" && -z "${CODEX_PLAN_MODEL:-${CURSOR_PLAN_MODEL:-}}" ]]; then
  log "ERROR: --non-interactive requires --agent <name> or CODEX_PLAN_MODEL"
  echo -e "${C_R}${C_BOLD}Non-interactive mode requires either a prebuilt agent or CODEX_PLAN_MODEL.${C_RST}" >&2
  exit 1
fi

if [[ ! -f "$PLAN_PATH" ]]; then
  log "ERROR: plan file not found: $PLAN_PATH"
  echo -e "${C_R}${C_BOLD}Plan file not found:${C_RST} ${C_R}$PLAN_PATH${C_RST}"
  echo -e "${C_DIM}Create it, set .codex/ralph/plan-runner.json (or .ralph/plan-runner.json), or pass --plan <path>.${C_RST}"
  exit 1
fi

log "plan file found: $PLAN_PATH"

ALLOW_CLEANUP_PROMPT=1
CLEANUP_SCRIPT="$WORKSPACE/.ralph/cleanup-plan.sh"
prompt_cleanup_on_exit() {
  trap - EXIT
  [[ "${ALLOW_CLEANUP_PROMPT:-0}" == "1" ]] || return 0
  [[ "$NON_INTERACTIVE_FLAG" == "1" ]] && return 0
  local cmd_quoted
  cmd_quoted="\"$CLEANUP_SCRIPT\" ${RALPH_ARTIFACT_NS:-<artifact-namespace>} \"$WORKSPACE\""
  echo ""
  if [[ -t 0 && -t 1 ]]; then
    local ans
    read -r -p "Run cleanup now? [y/N] " ans </dev/tty 2>/dev/null || ans=""
    ans="$(echo "$ans" | tr '[:upper:]' '[:lower:]')"
    if [[ "$ans" == "y" || "$ans" == "yes" ]]; then
      "$CLEANUP_SCRIPT" "${RALPH_ARTIFACT_NS:-}" "$WORKSPACE"
      return 0
    fi
  fi
  echo "Cleanup command: $cmd_quoted"
}
trap prompt_cleanup_on_exit EXIT

PREBUILT_AGENT_CONTEXT=""
prompt_agent_source_mode "$WORKSPACE"
if [[ "$INTERACTIVE_SELECT_AGENT_FLAG" == "1" ]]; then
  PREBUILT_AGENT="$(prompt_select_prebuilt_agent "$WORKSPACE")" || exit 1
fi

if [[ -n "$PREBUILT_AGENT" ]]; then
  if [[ ! -f "$AGENT_CONFIG_TOOL" ]]; then
    echo -e "${C_R}.ralph/agent-config-tool.sh is required for prebuilt agents.${C_RST}" >&2
    log "ERROR: agent tooling missing for $PREBUILT_AGENT"
    exit 1
  fi
  _agents_root="$(prebuilt_agents_root "$WORKSPACE")"
  _discovered="$(list_prebuilt_agent_ids "$WORKSPACE" | paste -sd', ' -)"
  log "agent discovery (Codex): root=$_agents_root ids=[${_discovered:-none}]"
  if ! validate_prebuilt_agent_config "$WORKSPACE" "$PREBUILT_AGENT"; then
    echo -e "${C_R}Invalid agent config for '${PREBUILT_AGENT}'.${C_RST} See .codex/agents/README.md" >&2
    log "ERROR: validate failed for agent $PREBUILT_AGENT"
    exit 1
  fi
  agent_default_model="$(read_prebuilt_agent_model "$WORKSPACE" "$PREBUILT_AGENT")" || {
    echo -e "${C_R}Could not read model for prebuilt agent${C_RST} $PREBUILT_AGENT" >&2
    log "ERROR: model read failed for $PREBUILT_AGENT"
    exit 1
  }

  # Check for env var override, else use agent default (no prompt for prebuilt agents)
  if [[ -n "${CODEX_PLAN_MODEL:-${CURSOR_PLAN_MODEL:-}}" ]]; then
    SELECTED_MODEL="${CODEX_PLAN_MODEL:-${CURSOR_PLAN_MODEL:-}}"
    log "model override from env: $SELECTED_MODEL"
  else
    SELECTED_MODEL="$agent_default_model"
    log "using agent default model: $SELECTED_MODEL"
  fi
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

iteration=0
LAST_TODO_LINE=""
ITERATIONS_ON_SAME_TODO=0

while [[ $iteration -lt $MAX_ITERATIONS ]]; do
  iteration=$((iteration + 1))

  if ! next=$(get_next_todo "$PLAN_PATH"); then
    read -r done total <<< "$(count_todos "$PLAN_PATH")"
    log "all complete (done=$done total=$total) after $iteration iteration(s)"
    {
      echo ""
      echo "################################################################################"
      echo "# All TODOs complete ($done/$total) - $(date '+%Y-%m-%d %H:%M:%S')"
      echo "################################################################################"
    } >> "$OUTPUT_LOG"
    echo ""
    echo -e "${C_G}${C_BOLD}All TODOs complete${C_RST} ${C_G}($done/$total)${C_RST}."
    echo -e "${C_DIM}Output log: $OUTPUT_LOG${C_RST}"
    exit 0
  fi

  line_num="${next%%|*}"
  full_line="${next#*|}"
  todo_text="$(echo "$full_line" | sed -E 's/^[[:space:]]*-[[:space:]]+\[[[:space:]]\][[:space:]]*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

  if [[ "$line_num" == "$LAST_TODO_LINE" ]]; then
    ITERATIONS_ON_SAME_TODO=$((ITERATIONS_ON_SAME_TODO + 1))
  else
    LAST_TODO_LINE="$line_num"
    ITERATIONS_ON_SAME_TODO=1
  fi
  if [[ $ITERATIONS_ON_SAME_TODO -gt $GUTTER_ITERATIONS ]]; then
    log "GUTTER: stuck on same TODO (line $line_num) for $ITERATIONS_ON_SAME_TODO iterations; exiting for human intervention"
    echo "" >&2
    echo -e "${C_R}${C_BOLD}Agent stuck on the same TODO for $ITERATIONS_ON_SAME_TODO iterations.${C_RST}"
    echo -e "${C_Y}Stopped to request human intervention.${C_RST}"
    echo ""
    echo -e "  Plan: $PLAN_PATH"
    echo -e "  TODO (line $line_num): $todo_text"
    echo ""
    echo -e "${C_DIM}Resolve or adjust the plan, then re-run. Override gutter with CODEX_PLAN_GUTTER_ITER or CURSOR_PLAN_GUTTER_ITER=N.${C_RST}"
    exit 1
  fi

  read -r done total <<< "$(count_todos "$PLAN_PATH")"
  remaining=$((total - done))

  log "iteration=$iteration next_todo line=$line_num done=$done total=$total remaining=$remaining (same_todo_iter=$ITERATIONS_ON_SAME_TODO)"
  log "todo_text: $todo_text"

  echo ""
  echo -e "${C_C}${C_BOLD}══════════════════════════════════════════════════════════════${C_RST}"
  echo -e "${C_C}Building plan:${C_RST} $PLAN_PATH  ${C_DIM}|${C_RST}  ${C_G}$done/$total${C_RST}  ${C_DIM}|${C_RST}  ${C_Y}TODO $iteration${C_RST} (line $line_num)"
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

The plan file is at: $PLAN_PATH
The TODO to complete and then mark [x] is on line $line_num.

Artifact namespace for this run:
- RALPH_ARTIFACT_NS=$RALPH_ARTIFACT_NS
- RALPH_PLAN_KEY=$RALPH_PLAN_KEY

When writing handoff artifacts, use the namespace-aware paths from the prebuilt agent context."
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

  log "invoking codex exec (model=${SELECTED_MODEL:-default})${PREBUILT_AGENT:+ prebuilt_agent=$PREBUILT_AGENT}"
  start_ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo -e "${C_G}Starting agent ${C_BOLD}(${SELECTED_MODEL:-default})${C_RST}${C_G} for this TODO at ${start_ts}...${C_RST}"
  echo ""

  {
    echo ""
    echo "================================================================================"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Iteration $iteration | TODO (line $line_num): $todo_text"
    echo "================================================================================"
    echo ""
  } >> "$OUTPUT_LOG"

  cd "$WORKSPACE"

  EXIT_CODE_FILE="$RALPH_LOG_DIR/.plan-runner-exit.$$"
  PROGRESS_INTERVAL="${CODEX_PLAN_PROGRESS_INTERVAL:-${CLAUDE_PLAN_PROGRESS_INTERVAL:-${CURSOR_PLAN_PROGRESS_INTERVAL:-30}}}"
  START_TIME="$(date +%s)"
  LOG_SIZE_AT_START="$(wc -c < "$OUTPUT_LOG" 2>/dev/null || echo 0)"
  FIRST_RESPONSE_SHOWN=0
  LAST_PROGRESS_AT=0

  run_agent() {
  local pf
  pf="$(mktemp "${TMPDIR:-/tmp}/ralph-codex-prompt.XXXXXX")"
  printf '%s' "$PROMPT" > "$pf"
  export CODEX_PLAN_CLI="$CODEX_CLI"
  if [[ -n "${SELECTED_MODEL:-}" && "$SELECTED_MODEL" != "auto" ]]; then
    export CODEX_PLAN_MODEL="$SELECTED_MODEL"
  else
    export CODEX_PLAN_MODEL=""
  fi
  "$SCRIPT_DIR/codex-exec-prompt.sh" "$pf" "$WORKSPACE" 2>&1 | tee -a "$OUTPUT_LOG"
  echo "${PIPESTATUS[0]}" > "$EXIT_CODE_FILE"
  rm -f "$pf"
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
  log "codex exec finished (exit=$exit_code)"

  echo "" >> "$OUTPUT_LOG"
  echo "--- End iteration $iteration ---" >> "$OUTPUT_LOG"

  sleep 2
done

log "max iterations reached ($MAX_ITERATIONS)"
echo -e "${C_Y}Max iterations ($MAX_ITERATIONS) reached.${C_RST} Re-run to continue."
exit 1
