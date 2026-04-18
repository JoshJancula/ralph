## Core run-plan logic moved here; source from run-plan.sh.
## Do not execute directly.
##
## Environment exported for child CLIs and helpers:
##   RALPH_PLAN_KEY -- stable id for this plan (logs, sessions, defaults).
##   RALPH_ARTIFACT_NS -- artifact namespace (defaults to plan key).
##   OUTPUT_LOG -- file path for tee'd assistant CLI output.
##   RALPH_PLAN_CLI_RESUME -- 1 after optional prompt when one session is reused across TODOs.
##
## Public interface (functions): ralph_run_plan_log, ralph_ensure_*_cli, ralph_path_to_file_uri,
## ralph_human_* / ralph_operator_* for human-in-the-loop flows, and related helpers below.
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
RALPH_PLAN_TODO_MAX_ITERATIONS=""
CLAUDE_TOOLS_FROM_AGENT=""
_RALPH_CLI_RESUME_ENV_WAS_SET=0
[[ "${RALPH_PLAN_CLI_RESUME+x}" == x ]] && _RALPH_CLI_RESUME_ENV_WAS_SET=1

ralph_run_plan_parse_args "$@"

# Colors before any interactive menu (runtime picker runs before ralph_run_plan_log() exists).
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
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bash-lib/run-plan-cli-helpers.sh"

ralph_parse_duration() {
  local duration_str="${1:-}"
  if [[ -z "$duration_str" ]]; then
    echo "Error: duration string is empty" >&2
    return 1
  fi

  local num unit seconds

  if [[ "$duration_str" =~ ^([0-9]+)(s|m|h)$ ]]; then
    num="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"
  else
    echo "Error: invalid duration format '$duration_str' (expected e.g. 30s, 5m, 2h)" >&2
    return 1
  fi

  if [[ "$num" -le 0 ]]; then
    echo "Error: duration must be positive (got '$duration_str')" >&2
    return 1
  fi

  case "$unit" in
    s) seconds="$num" ;;
    m) seconds=$((num * 60)) ;;
    h) seconds=$((num * 3600)) ;;
  esac

  echo "$seconds"
}

ralph_resolve_timeout() {
  local raw_timeout="${RALPH_PLAN_INVOCATION_TIMEOUT_RAW:-}"
  local timeout_seconds

  if [[ -n "$raw_timeout" ]]; then
    if ! timeout_seconds="$(ralph_parse_duration "$raw_timeout")"; then
      return 1
    fi
  else
    if ! timeout_seconds="$(ralph_parse_duration "30m")"; then
      return 1
    fi
  fi

  echo "$timeout_seconds"
}

# shellcheck source=/dev/null
source "$SCRIPT_DIR/bash-lib/ralph-format-elapsed.sh"

AGENT_CONFIG_TOOL="$WORKSPACE/.ralph/agent-config-tool.sh"

if [[ -z "$RUNTIME" ]]; then
  if [[ -n "${RALPH_PLAN_RUNTIME:-}" ]]; then
    case "${RALPH_PLAN_RUNTIME}" in
      cursor|claude|codex|opencode)
        RUNTIME="${RALPH_PLAN_RUNTIME}"
        ;;
      *)
        ralph_die "Error: RALPH_PLAN_RUNTIME must be one of cursor, claude, codex, or opencode."
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
  ralph_die "Error: select-model script not found for runtime $RUNTIME ($SELECT_MODEL_SCRIPT)."
fi

# Log to file and optionally stdout (if CURSOR_PLAN_VERBOSE=1)
ralph_run_plan_log() {
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
  local cli
  if ! cli="$(ralph_resolve_cursor_cli)"; then
    ralph_run_plan_log "ERROR: Cursor CLI not found (neither cursor-agent nor agent in PATH)"
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
  CURSOR_CLI="$cli"
}

ralph_ensure_claude_cli() {
  local cli="${CLAUDE_PLAN_CLI:-}"
  if [[ -z "$cli" && -n "$(command -v claude 2>/dev/null)" ]]; then
    cli="claude"
  fi
  if [[ -z "$cli" ]] || ! command -v "$cli" &>/dev/null; then
    ralph_run_plan_log "ERROR: Claude CLI not found (set CLAUDE_PLAN_CLI or install claude)"
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
    ralph_run_plan_log "ERROR: Codex CLI not found (set CODEX_PLAN_CLI or install codex)"
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

# shellcheck source=/Users/joshuajancula/Documents/projects/ralph/bundle/.ralph/bash-lib/run-plan-agent.sh
_run_plan_agent_dir=""
if [[ -n "${SCRIPT_DIR:-}" ]]; then
  _run_plan_agent_dir="$SCRIPT_DIR"
elif [[ -n "${REPO_ROOT:-}" ]]; then
  _run_plan_agent_dir="$REPO_ROOT/.ralph"
else
  _run_plan_agent_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
source "$_run_plan_agent_dir/bash-lib/run-plan-agent.sh"
unset _run_plan_agent_dir
# RUN_PLAN_AGENT_HELPERS_END

PLAN_PATH="$(plan_normalize_path "$PLAN_OVERRIDE" "$WORKSPACE")"

# Per-plan logs and session files under .ralph-workspace/ (override with RALPH_PLAN_WORKSPACE_ROOT).
# Keeps agent-writable paths (pending-human.txt, etc.) out of .ralph-workspace, which some CLIs sandbox or restrict.
PLAN_LOG_NAME="$(plan_log_basename "$PLAN_PATH")"
# Plan namespace for logs, sessions, and templated paths; inherited by subprocesses.
export RALPH_PLAN_KEY="${RALPH_PLAN_KEY:-$PLAN_LOG_NAME}"
# Artifact namespace (often equals plan key); used for {{ARTIFACT_NS}} style paths.
export RALPH_ARTIFACT_NS="${RALPH_ARTIFACT_NS:-$RALPH_PLAN_KEY}"
DEFAULT_RALPH_PLAN_WORKSPACE_ROOT="$WORKSPACE/.ralph-workspace"
if [[ -n "${WORKSPACE_ROOT_OVERRIDE:-}" ]]; then
  DEFAULT_RALPH_PLAN_WORKSPACE_ROOT="$WORKSPACE_ROOT_OVERRIDE"
fi
RALPH_PLAN_WORKSPACE_ROOT="${RALPH_PLAN_WORKSPACE_ROOT:-$DEFAULT_RALPH_PLAN_WORKSPACE_ROOT}"
export RALPH_PROJECT_ROOT="$WORKSPACE"
RALPH_LOG_DIR="$RALPH_PLAN_WORKSPACE_ROOT/logs/$RALPH_ARTIFACT_NS"

ralph_session_init "$WORKSPACE" "$PLAN_LOG_NAME"

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
# Destination for captured CLI stdout/stderr (tee); subprocesses may append via invoke helpers.
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
  opencode)
    ralph_ensure_opencode_cli
    ;;
esac

RALPH_INVOKED_CLI=""
case "$RUNTIME" in
  cursor) RALPH_INVOKED_CLI="$CURSOR_CLI" ;;
  claude) RALPH_INVOKED_CLI="$CLAUDE_CLI" ;;
  codex) RALPH_INVOKED_CLI="$CODEX_CLI" ;;
  opencode) RALPH_INVOKED_CLI="$OPENCODE_CLI" ;;
esac

MAX_ITERATIONS="${CURSOR_PLAN_MAX_ITER:-50}"
case "$RUNTIME" in
  cursor)
    _ralph_gutter_default="${CURSOR_PLAN_GUTTER_ITER:-3}"
    ;;
  claude)
    _ralph_gutter_default="${CLAUDE_PLAN_GUTTER_ITER:-${CURSOR_PLAN_GUTTER_ITER:-3}}"
    ;;
  codex)
    _ralph_gutter_default="${CODEX_PLAN_GUTTER_ITER:-${CLAUDE_PLAN_GUTTER_ITER:-${CURSOR_PLAN_GUTTER_ITER:-3}}}"
    ;;
  opencode)
    _ralph_gutter_default="${OPENCODE_PLAN_GUTTER_ITER:-${CODEX_PLAN_GUTTER_ITER:-${CLAUDE_PLAN_GUTTER_ITER:-${CURSOR_PLAN_GUTTER_ITER:-3}}}}"
    ;;
  *)
    _ralph_gutter_default="${CURSOR_PLAN_GUTTER_ITER:-3}"
    ;;
esac
GUTTER_ITERATIONS="${RALPH_PLAN_TODO_MAX_ITERATIONS:-$_ralph_gutter_default}"
unset _ralph_gutter_default

RALPH_PLAN_INVOCATION_TIMEOUT_SECONDS=""
if ! RALPH_PLAN_INVOCATION_TIMEOUT_SECONDS="$(ralph_resolve_timeout)"; then
  ralph_die "Error: failed to resolve invocation timeout"
fi

ralph_run_plan_log "run-plan.sh started (workspace=$WORKSPACE plan=$PLAN_PATH)"
ralph_run_plan_log "plan_path=$PLAN_PATH output_log=$OUTPUT_LOG log_file=$LOG_FILE"
ralph_run_plan_log "artifact namespace: RALPH_ARTIFACT_NS=$RALPH_ARTIFACT_NS RALPH_PLAN_KEY=$RALPH_PLAN_KEY"
ralph_run_plan_log "invocation timeout: ${RALPH_PLAN_INVOCATION_TIMEOUT_SECONDS}s (${RALPH_PLAN_INVOCATION_TIMEOUT_RAW:-default 30m})"

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
  ralph_run_plan_log "ERROR: --non-interactive requires --agent <name>, --model <id>, or CURSOR_PLAN_MODEL"
  echo -e "${C_R}${C_BOLD}Non-interactive mode requires a prebuilt agent, --model <id>, or CURSOR_PLAN_MODEL.${C_RST}" >&2
  exit 1
fi

if [[ ! -f "$PLAN_PATH" ]]; then
  ralph_run_plan_log "ERROR: plan file not found: $PLAN_PATH"
  echo -e "${C_R}${C_BOLD}Plan file not found:${C_RST} ${C_R}$PLAN_PATH${C_RST}"
  echo -e "${C_DIM}Create the plan file or pass a valid path with --plan <path>.${C_RST}"
  exit 1
fi

ralph_run_plan_log "plan file found: $PLAN_PATH"

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
    printf '%s --non-interactive --plan %s --agent %s --workspace %s' \
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

ralph_operator_response_file_owned_by_current_user() {
  local file="${1:-}"
  [[ -f "$file" ]] || return 1
  local current_uid owner_uid
  current_uid="$(id -u)"
  if owner_uid="$(stat -c '%u' "$file" 2>/dev/null)"; then
    :
  elif owner_uid="$(stat -f '%u' "$file" 2>/dev/null)"; then
    :
  else
    echo "Warning: unable to determine owner of $file; rejecting operator response for safety." >&2
    return 1
  fi
  owner_uid="${owner_uid%%$'\n'*}"
  if [[ "$owner_uid" != "$current_uid" ]]; then
    echo "Warning: $file is owned by UID $owner_uid but current UID is $current_uid; ignoring response to prevent injection." >&2
    return 1
  fi
  return 0
}

ralph_remove_human_action_file() {
  if [[ -f "$HUMAN_ACTION_FILE" ]]; then
    rm -f "$HUMAN_ACTION_FILE"
    ralph_run_plan_log "Removed human action file: $HUMAN_ACTION_FILE"
  fi
}

ralph_write_human_action_file() {
  local question="${1:-}"
  if [[ -z "$question" && -f "$PENDING_HUMAN" ]]; then
    question="$(<"$PENDING_HUMAN")"
  fi
  [[ -n "$question" ]] || return 0

  local history="(no operator replies recorded yet)"
  if [[ -f "$HUMAN_CONTEXT" ]] && [[ -s "$HUMAN_CONTEXT" ]]; then
    history="$(<"$HUMAN_CONTEXT")"
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
    printf -- '- Pending question: %s\n' "$PENDING_HUMAN"
    printf -- '- Session directory: %s\n' "$RALPH_SESSION_DIR"
    printf -- '- Plan log: %s\n' "$LOG_FILE"
    printf -- '- Output log: %s\n\n' "$OUTPUT_LOG"
    printf '## Previous operator replies\n\n%s\n' "$history"
  } >"$HUMAN_ACTION_FILE"
  ralph_run_plan_log "Wrote human action file: $HUMAN_ACTION_FILE"
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
    if ! ralph_operator_response_file_owned_by_current_user "$OPERATOR_RESPONSE_FILE"; then
      ralph_run_plan_log "Operator response rejected because $OPERATOR_RESPONSE_FILE is not owned by current user"
      return 1
    fi
    local _pq _pa
    _pq="$(<"$PENDING_HUMAN")"
    _pa="$(<"$OPERATOR_RESPONSE_FILE")"
    {
      echo ""
      echo "### $(date '+%Y-%m-%d %H:%M:%S')"
      echo "**Agent asked:**"
      echo "$_pq"
      echo "**Operator answered:**"
      echo "$_pa"
    } >>"$HUMAN_CONTEXT"
    rm -f "$PENDING_HUMAN" "$OPERATOR_RESPONSE_FILE"
    ralph_run_plan_log "Applied answer from operator-response.txt; continuing plan run"
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
  printf '%s\n' "$(<"$PENDING_HUMAN")"
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
  ralph_run_plan_log "Wrote offline human instructions: $HUMAN_INPUT_MD"

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
    ralph_run_plan_log "EXIT 4: human input required (RALPH_HUMAN_OFFLINE_EXIT=1)"
    exit 4
  fi

  ralph_human_input_write_offline_instructions

  local interval="${RALPH_HUMAN_POLL_INTERVAL:-2}"
  local n=0
  ralph_run_plan_log "Paused (no TTY): polling every ${interval}s for answer in $OPERATOR_RESPONSE_FILE"
  echo -e "${C_DIM}Waiting for a saved answer in operator-response.txt (poll every ${interval}s)...${C_RST}" >&2

  while ! ralph_operator_has_real_answer; do
    sleep "$interval"
    n=$((n + 1))
    if (( n % 15 == 0 )); then
      echo -e "${C_DIM}Still paused; edit and save ${OPERATOR_RESPONSE_FILE}${C_RST}" >&2
      ralph_run_plan_log "still waiting for operator-response (elapsed ~$((n * interval))s)"
    fi
  done

  if ralph_try_consume_human_response; then
    ralph_sync_human_action_file_state
    ralph_run_plan_log "Operator response applied; resuming plan run"
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
    printf '%s\n' "$(<"$PENDING_HUMAN")" >&2
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

ralph_run_plan_log "session dir=$RALPH_SESSION_DIR"

ralph_session_prompt_cli_resume
# Whether to reuse one assistant session across TODOs (0/1); read by invoke and demux scripts.
export RALPH_PLAN_CLI_RESUME

# After this point, offer optional cleanup on exit (logs and Ralph artifacts).
ALLOW_CLEANUP_PROMPT=1
CLEANUP_SCRIPT="$WORKSPACE/.ralph/cleanup-plan.sh"
EXIT_STATUS="incomplete"
# shellcheck source=/Users/joshuajancula/Documents/projects/ralph/bundle/.ralph/bash-lib/run-plan-cleanup.sh
source "$SCRIPT_DIR/bash-lib/run-plan-cleanup.sh"

# Resolve agent/model: prebuilt (--agent / --select-agent) overrides manual model selection
PREBUILT_AGENT_CONTEXT=""
prompt_agent_source_mode "$WORKSPACE"
if [[ "$INTERACTIVE_SELECT_AGENT_FLAG" == "1" ]]; then
  PREBUILT_AGENT="$(prompt_select_prebuilt_agent "$WORKSPACE")" || exit 1
fi

if [[ -n "$PREBUILT_AGENT" ]]; then
  if [[ ! -f "$AGENT_CONFIG_TOOL" ]]; then
    echo -e "${C_R}agent-config-tool.sh is required for prebuilt agent validation and context.${C_RST}" >&2
    ralph_run_plan_log "ERROR: missing $AGENT_CONFIG_TOOL for agent $PREBUILT_AGENT"
    exit 1
  fi
  _agents_root="$(prebuilt_agents_root "$WORKSPACE")"
  _discovered="$(list_prebuilt_agent_ids "$WORKSPACE" | paste -sd', ' -)"
  ralph_run_plan_log "agent discovery (Cursor): root=$_agents_root ids=[${_discovered:-none}]"
  if ! validate_prebuilt_agent_config "$WORKSPACE" "$PREBUILT_AGENT"; then
    echo -e "${C_R}Invalid agent config for '${PREBUILT_AGENT}'.${C_RST} See .cursor/agents/README.md" >&2
    ralph_run_plan_log "ERROR: validate failed for agent $PREBUILT_AGENT"
    exit 1
  fi
  SELECTED_MODEL="$(read_prebuilt_agent_model "$WORKSPACE" "$PREBUILT_AGENT")" || {
    echo -e "${C_R}Could not read model for prebuilt agent${C_RST} $PREBUILT_AGENT" >&2
    ralph_run_plan_log "ERROR: model read failed for $PREBUILT_AGENT"
    exit 1
  }
  # Runtime-specific model env vars set by the orchestrator for per-stage overrides
  # take precedence over the agent config default, but yield to an explicit --model flag.
  _runtime_env_model=""
  case "$RUNTIME" in
    cursor) _runtime_env_model="${CURSOR_PLAN_MODEL:-}" ;;
    claude) _runtime_env_model="${CLAUDE_PLAN_MODEL:-${CURSOR_PLAN_MODEL:-}}" ;;
    codex)     _runtime_env_model="${CODEX_PLAN_MODEL:-${CURSOR_PLAN_MODEL:-}}" ;;
    opencode)  _runtime_env_model="${OPENCODE_PLAN_MODEL:-${CURSOR_PLAN_MODEL:-}}" ;;
  esac
  if [[ -n "$_runtime_env_model" ]]; then
    SELECTED_MODEL="$_runtime_env_model"
    ralph_run_plan_log "runtime env model override: $SELECTED_MODEL (agent=$PREBUILT_AGENT)"
  fi
  if [[ -n "${PLAN_MODEL_CLI:-}" ]]; then
    SELECTED_MODEL="$PLAN_MODEL_CLI"
    ralph_run_plan_log "CLI --model overrides prebuilt agent default model (agent=$PREBUILT_AGENT)"
  fi
  if [[ "$RUNTIME" == "claude" ]]; then
    PREBUILT_AGENT_CONTEXT="$(RALPH_COMPACT_CONTEXT=0 format_prebuilt_agent_context_block "$WORKSPACE" "$PREBUILT_AGENT")" || {
      echo -e "${C_R}Could not build run context for agent${C_RST} $PREBUILT_AGENT" >&2
      ralph_run_plan_log "ERROR: context build failed for $PREBUILT_AGENT"
      exit 1
    }
  else
    PREBUILT_AGENT_CONTEXT="$(RALPH_COMPACT_CONTEXT=1 format_prebuilt_agent_context_block "$WORKSPACE" "$PREBUILT_AGENT")" || {
      echo -e "${C_R}Could not build run context for agent${C_RST} $PREBUILT_AGENT" >&2
      ralph_run_plan_log "ERROR: context build failed for $PREBUILT_AGENT"
      exit 1
    }
  fi
  ralph_run_plan_log "prebuilt agent id=$PREBUILT_AGENT model=$SELECTED_MODEL (config validated)"
  if [[ "$RUNTIME" == "claude" ]]; then
    _agents_root_for_tools="$(prebuilt_agents_root "$WORKSPACE")"
    CLAUDE_TOOLS_FROM_AGENT="$(bash "$AGENT_CONFIG_TOOL" allowed-tools "$_agents_root_for_tools" "$PREBUILT_AGENT" 2>/dev/null || true)"
    [[ -n "$CLAUDE_TOOLS_FROM_AGENT" ]] && ralph_run_plan_log "allowed_tools from agent config: $CLAUDE_TOOLS_FROM_AGENT"
    RALPH_AGENT_MAX_BUDGET="$(bash "$AGENT_CONFIG_TOOL" max-budget "$_agents_root_for_tools" "$PREBUILT_AGENT" 2>/dev/null || true)"
    export RALPH_AGENT_MAX_BUDGET
    [[ -n "$RALPH_AGENT_MAX_BUDGET" ]] && ralph_run_plan_log "max_budget_usd from agent config: $RALPH_AGENT_MAX_BUDGET"
  else
    CLAUDE_TOOLS_FROM_AGENT=""
  fi
elif [[ -n "${PLAN_MODEL_CLI:-}" ]]; then
  SELECTED_MODEL="$PLAN_MODEL_CLI"
  ralph_run_plan_log "using CLI --model: $SELECTED_MODEL"
else
  SELECTED_MODEL="$(prompt_for_agent)"
  if [[ -n "$SELECTED_MODEL" ]]; then
    ralph_run_plan_log "using model: $SELECTED_MODEL"
  fi
fi

total_invocations=0
# Running token usage totals (accumulated from per-invocation USAGE_FILE written by demux.py).
_total_input_tokens=0
_total_output_tokens=0
_total_cache_creation_tokens=0
_total_cache_read_tokens=0
_total_max_turn_tokens=0
_plan_start_ts="$(date +%s)"
_plan_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

_ralph_write_plan_usage_summary() {
  local _done="$1" _total="$2"
  local _elapsed=$(( $(date +%s) - _plan_start_ts ))
  local _ended_at
  _ended_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local _summary_dir="$RALPH_LOG_DIR"
  local _summary_text=""
  mkdir -p "$_summary_dir"
  local _summary_cache_hit_ratio=0
  local _summary_total_input=$(( _total_input_tokens + _total_cache_read_tokens + _total_cache_creation_tokens ))
  local _summary_total_tokens=$(( _total_input_tokens + _total_output_tokens + _total_cache_creation_tokens + _total_cache_read_tokens ))
  if [[ "$_summary_total_input" -gt 0 ]]; then
    _summary_cache_hit_ratio="$(python3 -c "print(round(${_total_cache_read_tokens}/${_summary_total_input},4))" 2>/dev/null || echo 0)"
  fi
  cat > "$_summary_dir/plan-usage-summary.json" << _SUMMARY_EOF
{"schema_version":1,"kind":"plan_usage_summary","plan":"${PLAN_PATH}","plan_key":"${RALPH_PLAN_KEY:-${RALPH_ARTIFACT_NS:-}}","artifact_ns":"${RALPH_ARTIFACT_NS:-${RALPH_PLAN_KEY:-}}","stage_id":"${RALPH_STAGE_ID:-}","model":"${SELECTED_MODEL:-}","runtime":"${RUNTIME}","invocations":${total_invocations},"todos_done":${_done},"todos_total":${_total},"started_at":"${_plan_started_at}","ended_at":"${_ended_at}","elapsed_seconds":${_elapsed},"input_tokens":${_total_input_tokens},"output_tokens":${_total_output_tokens},"cache_creation_input_tokens":${_total_cache_creation_tokens},"cache_read_input_tokens":${_total_cache_read_tokens},"max_turn_total_tokens":${_total_max_turn_tokens},"cache_hit_ratio":${_summary_cache_hit_ratio}}
_SUMMARY_EOF
  if command -v python3 &>/dev/null && [[ -f "$RALPH_LOG_DIR/invocation-usage.json" ]]; then
    python3 - "$_summary_dir/plan-usage-summary.json" "$RALPH_LOG_DIR/invocation-usage.json" <<'PY'
import json
import os
import sys

summary_path = sys.argv[1]
usage_path = sys.argv[2]

try:
    with open(summary_path, "r", encoding="utf-8") as fh:
        summary = json.load(fh)
    with open(usage_path, "r", encoding="utf-8") as fh:
        usage = json.load(fh)
    invocations = usage.get("invocations")
    if not isinstance(summary, dict) or not isinstance(invocations, list):
        raise ValueError("invalid summary or usage data")
    grouped = {}
    for record in invocations:
        if not isinstance(record, dict):
            continue
        key = (str(record.get("runtime") or ""), str(record.get("model") or ""))
        bucket = grouped.setdefault(key, {
            "runtime": key[0],
            "model": key[1],
            "invocations": 0,
            "elapsed_seconds": 0,
            "input_tokens": 0,
            "output_tokens": 0,
            "cache_creation_input_tokens": 0,
            "cache_read_input_tokens": 0,
            "max_turn_total_tokens": 0,
        })
        bucket["invocations"] += 1
        bucket["elapsed_seconds"] += int(record.get("elapsed_seconds") or 0)
        bucket["input_tokens"] += int(record.get("input_tokens") or 0)
        bucket["output_tokens"] += int(record.get("output_tokens") or 0)
        bucket["cache_creation_input_tokens"] += int(record.get("cache_creation_input_tokens") or 0)
        bucket["cache_read_input_tokens"] += int(record.get("cache_read_input_tokens") or 0)
        bucket["max_turn_total_tokens"] = max(bucket["max_turn_total_tokens"], int(record.get("max_turn_total_tokens") or 0))
    breakdown = []
    for key in sorted(grouped):
        bucket = grouped[key]
        total_input = bucket["input_tokens"] + bucket["cache_creation_input_tokens"] + bucket["cache_read_input_tokens"]
        cache_hit_ratio = 0.0
        if total_input > 0:
            cache_hit_ratio = round(bucket["cache_read_input_tokens"] / total_input, 4)
        breakdown.append({
            "runtime": bucket["runtime"],
            "model": bucket["model"],
            "invocations": bucket["invocations"],
            "elapsed_seconds": bucket["elapsed_seconds"],
            "input_tokens": bucket["input_tokens"],
            "output_tokens": bucket["output_tokens"],
            "cache_creation_input_tokens": bucket["cache_creation_input_tokens"],
            "cache_read_input_tokens": bucket["cache_read_input_tokens"],
            "max_turn_total_tokens": bucket["max_turn_total_tokens"],
            "cache_hit_ratio": cache_hit_ratio,
        })
    summary["model_breakdown"] = breakdown
    tmp = f"{summary_path}.tmp.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(summary, fh)
        fh.write("\n")
    os.replace(tmp, summary_path)
except Exception as exc:
    sys.stderr.write(f"plan-usage-summary model_breakdown update failed: {type(exc).__name__}: {exc}\n")
PY
  fi
  if command -v python3 &>/dev/null && [[ -f "$RALPH_LOG_DIR/invocation-usage.json" ]]; then
    _summary_text="$(
      python3 "$SCRIPT_DIR/bash-lib/ralph-usage-summary-text.py" plan \
        --summary "$_summary_dir/plan-usage-summary.json" \
        --invocations "$RALPH_LOG_DIR/invocation-usage.json" 2>/dev/null || true
    )"
  fi
  local _elapsed_fmt
  _elapsed_fmt="$(ralph_format_elapsed_secs "$_elapsed")"
  ralph_run_plan_log "plan usage summary: invocations=${total_invocations} input=${_total_input_tokens} output=${_total_output_tokens} cache_create=${_total_cache_creation_tokens} cache_read=${_total_cache_read_tokens} max_turn=${_total_max_turn_tokens} cache_hit_ratio=${_summary_cache_hit_ratio} elapsed=${_elapsed_fmt}"
  echo -e "${C_DIM}Token usage: input=${_total_input_tokens} output=${_total_output_tokens} cache_create=${_total_cache_creation_tokens} cache_read=${_total_cache_read_tokens} total=${_summary_total_tokens} elapsed=${_elapsed_fmt}${C_RST}"
  if [[ -n "$_summary_text" ]]; then
    printf '%s\n' "${C_DIM}${_summary_text}${C_RST}"
  else
    echo -e "${C_DIM}Total elapsed time: ${_elapsed_fmt}${C_RST}"
  fi
}

_ralph_append_invocation_usage_history() {
  local _path="$1"
  local _iteration="$2"
  local _model="$3"
  local _runtime="$4"
  local _elapsed_seconds="$5"
  local _input_tokens="$6"
  local _output_tokens="$7"
  local _cache_create="$8"
  local _cache_read="$9"
  local _max_turn="${10:-0}"
  local _cache_hit_ratio="${11:-0}"
  local _started_at="${12:-}"
  local _ended_at="${13:-}"
  local _plan_key="${14:-}"
  local _stage_id="${15:-}"

  mkdir -p "$(dirname "$_path")"

  if command -v python3 &>/dev/null; then
    python3 - "$_path" "$_iteration" "$_model" "$_runtime" "$_elapsed_seconds" "$_input_tokens" "$_output_tokens" "$_cache_create" "$_cache_read" "$_max_turn" "$_cache_hit_ratio" "$_started_at" "$_ended_at" "$_plan_key" "$_stage_id" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

path = sys.argv[1]
iteration = int(sys.argv[2])
model = sys.argv[3]
runtime = sys.argv[4]
elapsed_seconds = int(sys.argv[5])
input_tokens = int(sys.argv[6])
output_tokens = int(sys.argv[7])
cache_creation_input_tokens = int(sys.argv[8])
cache_read_input_tokens = int(sys.argv[9])
max_turn_total_tokens = int(sys.argv[10])
try:
    cache_hit_ratio = float(sys.argv[11])
except (ValueError, IndexError):
    cache_hit_ratio = 0.0
started_at = sys.argv[12] if len(sys.argv) > 12 else ""
ended_at = sys.argv[13] if len(sys.argv) > 13 else ""
plan_key = sys.argv[14] if len(sys.argv) > 14 else ""
stage_id = sys.argv[15] if len(sys.argv) > 15 else ""

record = {
    "iteration": iteration,
    "model": model,
    "runtime": runtime,
    "elapsed_seconds": elapsed_seconds,
    "input_tokens": input_tokens,
    "output_tokens": output_tokens,
    "cache_creation_input_tokens": cache_creation_input_tokens,
    "cache_read_input_tokens": cache_read_input_tokens,
    "max_turn_total_tokens": max_turn_total_tokens,
    "cache_hit_ratio": round(cache_hit_ratio, 4),
    }

for key, value in (
    ("started_at", started_at),
    ("ended_at", ended_at),
    ("plan_key", plan_key),
    ("stage_id", stage_id),
):
    if value:
        record[key] = value

doc = {
    "schema_version": 1,
    "kind": "plan_invocation_usage_history",
    "updated_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "invocations": [],
    }

if os.path.exists(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            existing = json.load(fh)
        if isinstance(existing, dict) and isinstance(existing.get("invocations"), list):
            doc = existing
    except Exception:
        pass

doc["updated_at"] = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
inv = doc.setdefault("invocations", [])
inv.append(record)

tmp = f"{path}.tmp.{os.getpid()}"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(doc, fh)
    fh.write("\n")
os.replace(tmp, path)
PY
    return 0
  fi

  local _extra_fields=""
  if [[ -n "$_started_at" ]]; then
    _extra_fields+=",\"started_at\":\"${_started_at}\""
  fi
  if [[ -n "$_ended_at" ]]; then
    _extra_fields+=",\"ended_at\":\"${_ended_at}\""
  fi
  if [[ -n "$_plan_key" ]]; then
    _extra_fields+=",\"plan_key\":\"${_plan_key}\""
  fi
  if [[ -n "$_stage_id" ]]; then
    _extra_fields+=",\"stage_id\":\"${_stage_id}\""
  fi

  cat >"$_path" <<USAGE_EOF
{"schema_version":1,"kind":"plan_invocation_usage_history","invocations":[{"iteration":${_iteration},"model":"${_model}","runtime":"${_runtime}","elapsed_seconds":${_elapsed_seconds},"input_tokens":${_input_tokens},"output_tokens":${_output_tokens},"cache_creation_input_tokens":${_cache_create},"cache_read_input_tokens":${_cache_read},"max_turn_total_tokens":${_max_turn},"cache_hit_ratio":${_cache_hit_ratio}${_extra_fields}}]}
USAGE_EOF
}

# Outer loop: one iteration per "next open TODO" in the plan file.
# Inner loop (below): retry the same TODO until it is marked [x], human input is satisfied, or limits hit.
while true; do
  if ! next=$(get_next_todo "$PLAN_PATH"); then
    read -r done_count total_count <<< "$(count_todos "$PLAN_PATH")"
    ralph_run_plan_log "all complete (done=$done_count total=$total_count) after $total_invocations agent invocation(s)"
    {
      echo ""
      echo "################################################################################"
      echo "# All TODOs complete ($done_count/$total_count) - $(date '+%Y-%m-%d %H:%M:%S')"
      echo "################################################################################"
    } >> "$OUTPUT_LOG"
    echo ""
    echo -e "${C_G}${C_BOLD}All TODOs complete${C_RST} ${C_G}($done_count/$total_count)${C_RST}."
    _ralph_write_plan_usage_summary "$done_count" "$total_count"
    echo -e "${C_DIM}Output log: $OUTPUT_LOG${C_RST}"
    EXIT_STATUS="complete"
    exit 0
  fi

  line_num="${next%%|*}"
  full_line="${next#*|}"
  todo_text="$(plan_open_todo_body "$full_line")"

  attempts_on_line=0
  human_gate_satisfied_for_line=0
  # Same checklist line: re-invoke assistant if the box stayed [ ], pending-human was cleared, or gutter retry.
  while true; do
    total_invocations=$((total_invocations + 1))
    if [[ $total_invocations -gt $MAX_ITERATIONS ]]; then
      ralph_run_plan_log "exceeded plan max invocations (CURSOR_PLAN_MAX_ITER etc.) limit=$MAX_ITERATIONS"
      echo -e "${C_R}Too many agent invocations ($MAX_ITERATIONS).${C_RST} Raise CURSOR_PLAN_MAX_ITER or fix the plan." >&2
      exit 1
    fi
    iteration=$total_invocations

    read -r done_count total_count <<< "$(count_todos "$PLAN_PATH")"
    remaining=$((total_count - done_count))

    ralph_run_plan_log "invocation=$iteration next_todo line=$line_num done=$done_count total=$total_count remaining=$remaining attempts_on_line=$attempts_on_line"
    ralph_run_plan_log "todo_text: $todo_text"
    _session_label="none"
    if [[ -n "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]]; then
      _session_label="${RALPH_RUN_PLAN_RESUME_SESSION_ID}"
    elif [[ "${RALPH_RUN_PLAN_RESUME_BARE:-0}" == "1" ]]; then
      _session_label="bare"
    fi
    ralph_run_plan_log "current task line=$line_num session=$_session_label"

    task_ordinal="$(plan_todo_ordinal_at_line "$PLAN_PATH" "$line_num")"
    _banner_plan_secs=$(( $(date +%s) - _plan_start_ts ))
    _banner_plan_str="$(ralph_format_elapsed_secs "$_banner_plan_secs")"

    echo ""
    echo -e "${C_C}${C_BOLD}═══════════════════════════════════════════════════════════════════════════════════${C_RST}"
    echo -e "${C_C}Building plan:${C_RST} $PLAN_PATH"
    echo -e "${C_DIM}-----------------------------------------------------------------------------------${C_RST}"
    echo -e "  ${C_DIM}${C_RST}  ${C_BOLD}TASK ${task_ordinal}${C_RST}  ${C_DIM}|${C_RST}  Complete ${C_G}$done_count/$total_count |${C_RST} Skipped: 0 ${C_DIM}|${C_RST}  ${C_Y}invoke $iteration${C_RST} (line $line_num)"
    echo -e "${C_DIM}-----------------------------------------------------------------------------------${C_RST}"
    echo -e "  ${C_C}model:${C_RST} ${C_BOLD}${SELECTED_MODEL:-default}${C_RST}  ${C_DIM}|${C_RST}  ${C_C}runtime:${C_RST} ${C_BOLD}${RUNTIME}${C_RST}  ${C_DIM}|${C_RST}  ${C_C}plan elapsed:${C_RST} ${C_BOLD}${_banner_plan_str}${C_RST}"
    echo -e "${C_C}${C_BOLD}═══════════════════════════════════════════════════════════════════════════════════${C_RST}"
    echo -e "${C_BOLD}$todo_text${C_RST}"
    echo -e "${C_DIM}Log: $LOG_FILE  |  Output: $OUTPUT_LOG${C_RST}"
    echo ""

    # Refresh resume env from session-id.txt / flags before building PROMPT (compact vs full context).
    ralph_session_apply_resume_strategy

    _hc_included_bytes=0
    _ds_stage_count=0
    _prompt_mode="fresh"
    if [[ -n "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]] || ([[ "${RALPH_RUN_PLAN_RESUME_BARE:-0}" == "1" ]] && [[ "${RALPH_PLAN_ALLOW_UNSAFE_RESUME:-0}" == "1" ]]); then
      _prompt_mode="resume"
      if [[ -n "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]]; then
        _resume_intro="Continuing the same CLI session (--resume)."
      else
        _resume_intro="Continuing via bare CLI resume (last-session semantics; isolated CI only)."
      fi
      PROMPT_STATIC=""
      PROMPT="$_resume_intro

**TODO (line $line_num):** $todo_text

Open \`$PLAN_PATH\`, complete this TODO, change \`- [ ]\` to \`- [x]\` on that line, save, and stop. Do not start the next item.

If you need operator input before finishing, write your question to \`$PENDING_ABS\` and stop without marking [x]."

      if [[ -f "$HUMAN_CONTEXT" ]] && [[ -s "$HUMAN_CONTEXT" ]]; then
        _hc_max="${RALPH_HUMAN_CONTEXT_MAX_BYTES:-8192}"
        _hc_size="$(wc -c < "$HUMAN_CONTEXT" 2>/dev/null || echo 0)"
        if [[ "$_hc_size" -gt "$_hc_max" ]]; then
          _hc_content="$(tail -c "$_hc_max" "$HUMAN_CONTEXT")"
          PROMPT+=$'\n\n## Human operator answers\n[Note: trimmed to last '"$_hc_max"' bytes]\n'"$_hc_content"
          _hc_included_bytes="$_hc_max"
        else
          PROMPT+=$'\n\n## Human operator answers\n'"$(<"$HUMAN_CONTEXT")"
          _hc_included_bytes="$_hc_size"
        fi
      fi
    else
      # Per-TODO variable portion -- kept short so PROMPT_STATIC carries the bulk.
      PROMPT="Complete exactly this TODO and nothing else:

**TODO (line $line_num):** $todo_text

**Plan file:** \`$PLAN_PATH\`

Rules:
- Use the repo toolchain documented in README/AGENTS.md. Follow verification steps in the plan.
- Prefer targeted search and partial file/log reads first; avoid full log reads unless needed.
- When done, mark \`- [ ]\` on line $line_num as \`- [x]\` and stop.
- If operator input is needed first, write your question to \`$PENDING_ABS\` and stop without marking [x]."

      if [[ -f "$HUMAN_CONTEXT" ]] && [[ -s "$HUMAN_CONTEXT" ]]; then
        _hc_max="${RALPH_HUMAN_CONTEXT_MAX_BYTES:-8192}"
        if [[ "${RALPH_PLAN_CONTEXT_BUDGET:-standard}" != "full" ]]; then
          _hc_max="${RALPH_HUMAN_CONTEXT_MAX_BYTES_NO_RESUME:-2048}"
        fi
        _hc_size="$(wc -c < "$HUMAN_CONTEXT" 2>/dev/null || echo 0)"
        if [[ "$_hc_size" -gt "$_hc_max" ]]; then
          _hc_content="$(tail -c "$_hc_max" "$HUMAN_CONTEXT")"
          PROMPT+=$'\n\n## Human operator answers\n[Note: trimmed to last '"$_hc_max"' bytes]\n'"$_hc_content"
          _hc_included_bytes="$_hc_max"
        else
          PROMPT+=$'\n\n## Human operator answers\n'"$(<"$HUMAN_CONTEXT")"
          _hc_included_bytes="$_hc_size"
        fi
      fi

      # PROMPT_STATIC holds stable per-run context (artifact namespace, agent rules + skills) for
      # --system-prompt caching on Claude. Non-Claude runtimes get it appended to PROMPT.
      # Build the static prefix with namespace info so it is cached alongside agent context.
      _ns_block=""
      if [[ -n "${RALPH_ARTIFACT_NS:-}" || -n "${RALPH_PLAN_KEY:-}" ]]; then
        _ns_block="Artifact namespace: RALPH_ARTIFACT_NS=${RALPH_ARTIFACT_NS:-}  RALPH_PLAN_KEY=${RALPH_PLAN_KEY:-}
Use namespace-aware artifact paths when writing handoff files."
      fi

      if [[ -n "$PREBUILT_AGENT_CONTEXT" ]]; then
        if [[ -n "$_ns_block" ]]; then
          PROMPT_STATIC="${_ns_block}"$'\n\n'"${PREBUILT_AGENT_CONTEXT}"
        else
          PROMPT_STATIC="$PREBUILT_AGENT_CONTEXT"
        fi
        if [[ "$RUNTIME" != "claude" ]]; then
          PROMPT+=$'\n'"$PROMPT_STATIC"
        fi
      elif [[ -n "$_ns_block" ]]; then
        PROMPT_STATIC="$_ns_block"
        if [[ "$RUNTIME" != "claude" ]]; then
          PROMPT+=$'\n'"$_ns_block"
        fi
      else
        PROMPT_STATIC=""
      fi
      case "${PREBUILT_AGENT:-}" in
        research|security|code-review)
          ralph_run_plan_log "skipping downstream stage context for read-only agent: $PREBUILT_AGENT"
          ;;
        *)
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
                _ds_stage_limit="${RALPH_DOWNSTREAM_STAGE_LIMIT:-1}"
                if [[ "${RALPH_PLAN_CONTEXT_BUDGET:-standard}" == "lean" ]]; then
                  _ds_stage_limit="${RALPH_DOWNSTREAM_STAGE_LIMIT_NO_RESUME:-0}"
                fi
                _ds_stage_count=0
                for _ds_entry in "${_ds_stage_entries[@]}"; do
                  if [[ "$_ds_stage_limit" -gt 0 && "$_ds_stage_count" -ge "$_ds_stage_limit" ]]; then
                    break
                  fi
                  _ds_stage_id="${_ds_entry%%|*}"
                  _ds_rest="${_ds_entry#*|}"
                  _ds_plan_path="${_ds_rest%%|*}"
                  _ds_plan_template="${_ds_rest#*|}"
                  PROMPT+=$'\n'"- Stage ID: ${_ds_stage_id:-unknown}, plan path: ${_ds_plan_path:-none}, template path: ${_ds_plan_template:-none}"
                  _ds_stage_list+="${_ds_stage_id:-unknown}, "
                  _ds_stage_count=$(( _ds_stage_count + 1 ))
                done
                _ds_stage_list="${_ds_stage_list%, }"
                ralph_run_plan_log "downstream stage plan context appended for: ${_ds_stage_list:-none} (limit=${_ds_stage_limit})"
              fi
            fi
          fi
          ;;
      esac
    fi

    #region agent log
    if [[ -d "/Users/joshuajancula/Documents/projects/ralph/.cursor" ]]; then
      _dbg_ts=$(( $(date +%s) * 1000 ))
      _dbg_prompt_static_len=${#PROMPT_STATIC}
      _dbg_prompt_len=${#PROMPT}
      _dbg_has_resume_sid=0
      [[ -n "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]] && _dbg_has_resume_sid=1
      printf '%s\n' "{\"sessionId\":\"91b133\",\"id\":\"log_${_dbg_ts}_prompt_shape_$$\",\"timestamp\":${_dbg_ts},\"location\":\"bundle/.ralph/bash-lib/run-plan-core.sh:while_loop_prompt_build\",\"message\":\"prompt branch built\",\"data\":{\"prompt_mode\":\"${_prompt_mode}\",\"line_num\":\"${line_num}\",\"has_resume_session_id\":${_dbg_has_resume_sid},\"resume_bare\":\"${RALPH_RUN_PLAN_RESUME_BARE:-0}\",\"prompt_len\":${_dbg_prompt_len},\"prompt_static_len\":${_dbg_prompt_static_len}},\"runId\":\"initial\",\"hypothesisId\":\"H2\"}" >> "/Users/joshuajancula/Documents/projects/ralph/.cursor/debug-91b133.log" || true
    fi
    #endregion agent log

    # Export PROMPT_STATIC so invoke scripts can use it for --system-prompt caching.
    export PROMPT_STATIC
    # Prompt size measurement and warning.
    _prompt_bytes="${#PROMPT}"
    _prompt_est_tokens=$(( _prompt_bytes / 4 ))
    ralph_run_plan_log "prompt size: bytes=${_prompt_bytes} est_tokens=${_prompt_est_tokens}"
    ralph_run_plan_log "context footprint: mode=${_prompt_mode} context_budget=${RALPH_PLAN_CONTEXT_BUDGET:-standard} hc_bytes=${_hc_included_bytes:-0} ds_stages=${_ds_stage_count:-0}"
    _prompt_warn_threshold="${RALPH_PROMPT_SIZE_WARN_BYTES:-40000}"
    if [[ "$_prompt_bytes" -gt "$_prompt_warn_threshold" ]]; then
      echo "Warning: prompt is large (${_prompt_bytes} bytes, ~${_prompt_est_tokens} tokens). Consider reducing rules, human context, or downstream stages." >&2
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
    ralph_run_plan_log "invoking $RALPH_INVOKED_CLI (model=${SELECTED_MODEL:-default})${_invoke_resume_note}${PREBUILT_AGENT:+ prebuilt_agent=$PREBUILT_AGENT}"
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

    # Sidecar files for this invocation: CLI exit code; AGENT_PID watches the background shell.
    EXIT_CODE_FILE="$RALPH_LOG_DIR/.plan-runner-exit.$$"
    # Per-invocation usage JSON written by demux.py when JSON streaming is enabled.
    USAGE_FILE="$RALPH_LOG_DIR/.plan-runner-usage.$$.json"
    export USAGE_FILE
    rm -f "$USAGE_FILE"
    PROGRESS_INTERVAL="${CURSOR_PLAN_PROGRESS_INTERVAL:-30}"
    START_TIME="$(date +%s)"
    _inv_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
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
      opencode)
        # shellcheck source=/Users/joshuajancula/Documents/projects/ralph/bundle/.ralph/bash-lib/run-plan-invoke-opencode.sh
        source "$SCRIPT_DIR/bash-lib/run-plan-invoke-opencode.sh"
        ralph_run_plan_invoke_opencode &
        ;;
      *)
        ralph_die "Error: unsupported runtime for invocation: $RUNTIME"
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
        _inv_elapsed_str="$(ralph_format_elapsed_secs "$elapsed")"
        _run_elapsed_str="$(ralph_format_elapsed_secs "$((now - _plan_start_ts))")"
        echo -e "${C_DIM}[$(date '+%H:%M:%S')] Agent still working (invocation ${_inv_elapsed_str}, run ${_run_elapsed_str}).${C_RST}" >&2
      fi

      if [[ $elapsed -gt "$RALPH_PLAN_INVOCATION_TIMEOUT_SECONDS" ]]; then
        echo "" >&2
        echo -e "${C_R}${C_BOLD}Invocation stuck: timeout exceeded (${elapsed}s > ${RALPH_PLAN_INVOCATION_TIMEOUT_SECONDS}s).${C_RST}" >&2
        echo -e "${C_R}Terminating agent process (PID $AGENT_PID).${C_RST}" >&2
        ralph_run_plan_log "Invocation timeout exceeded: elapsed=${elapsed}s limit=${RALPH_PLAN_INVOCATION_TIMEOUT_SECONDS}s; killing agent (PID $AGENT_PID)"
        kill -TERM "$AGENT_PID" 2>/dev/null || true
        sleep 2
        if kill -0 "$AGENT_PID" 2>/dev/null; then
          kill -KILL "$AGENT_PID" 2>/dev/null || true
        fi
        echo "" >> "$OUTPUT_LOG"
        echo "--- Invocation terminated due to timeout (elapsed ${elapsed}s > ${RALPH_PLAN_INVOCATION_TIMEOUT_SECONDS}s) ---" >> "$OUTPUT_LOG"
        EXIT_STATUS="stuck"
        exit 4
      fi
    done

    wait "$AGENT_PID" 2>/dev/null || true
    exit_code=125
    if [[ -f "$EXIT_CODE_FILE" ]]; then
      exit_code="$(cat "$EXIT_CODE_FILE")"
      rm -f "$EXIT_CODE_FILE"
    fi
    set -e
    _inv_ended_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    _inv_elapsed=$(( $(date +%s) - START_TIME ))
    ralph_run_plan_log "$RALPH_INVOKED_CLI finished (exit=$exit_code elapsed=${_inv_elapsed}s)"

    # Read per-invocation token usage from demux.py output (only when JSON streaming was active).
    _inv_input=0; _inv_output=0; _inv_cache_create=0; _inv_cache_read=0; _inv_max_turn=0
    if [[ -f "$USAGE_FILE" ]]; then
      if command -v python3 &>/dev/null; then
        _inv_usage_json="$(<"$USAGE_FILE")"
        _inv_input="$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('input_tokens',0))" "$_inv_usage_json" 2>/dev/null || echo 0)"
        _inv_output="$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('output_tokens',0))" "$_inv_usage_json" 2>/dev/null || echo 0)"
        _inv_cache_create="$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('cache_creation_input_tokens',0))" "$_inv_usage_json" 2>/dev/null || echo 0)"
        _inv_cache_read="$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('cache_read_input_tokens',0))" "$_inv_usage_json" 2>/dev/null || echo 0)"
        _inv_max_turn="$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('max_turn_total_tokens',0))" "$_inv_usage_json" 2>/dev/null || echo 0)"
      fi
      rm -f "$USAGE_FILE"
    fi
    # Compute per-invocation cache_hit_ratio = cache_read / (input + cache_read + cache_create).
    _inv_cache_hit_ratio=0
    _inv_total_input=$(( _inv_input + _inv_cache_read + _inv_cache_create ))
    if [[ "$_inv_total_input" -gt 0 ]] && command -v python3 &>/dev/null; then
      _inv_cache_hit_ratio="$(python3 -c "print(round(${_inv_cache_read}/${_inv_total_input},4))" 2>/dev/null || echo 0)"
    fi
    _total_input_tokens=$(( _total_input_tokens + _inv_input ))
    _total_output_tokens=$(( _total_output_tokens + _inv_output ))
    _total_cache_creation_tokens=$(( _total_cache_creation_tokens + _inv_cache_create ))
    _total_cache_read_tokens=$(( _total_cache_read_tokens + _inv_cache_read ))
    if [[ "$_inv_max_turn" -gt "$_total_max_turn_tokens" ]]; then
      _total_max_turn_tokens="$_inv_max_turn"
    fi

    # Write consolidated per-invocation usage history JSON.
    _inv_usage_file="$RALPH_LOG_DIR/invocation-usage.json"
    _ralph_append_invocation_usage_history \
      "$_inv_usage_file" \
      "$iteration" \
      "${SELECTED_MODEL:-}" \
      "$RUNTIME" \
      "$_inv_elapsed" \
      "$_inv_input" \
      "$_inv_output" \
      "$_inv_cache_create" \
      "$_inv_cache_read" \
      "$_inv_max_turn" \
      "$_inv_cache_hit_ratio" \
      "$_inv_started_at" \
      "$_inv_ended_at" \
      "${RALPH_PLAN_KEY:-}" \
      "${RALPH_STAGE_ID:-}"
    ralph_run_plan_log "invocation $iteration usage: input=${_inv_input} output=${_inv_output} cache_create=${_inv_cache_create} cache_read=${_inv_cache_read} max_turn=${_inv_max_turn} cache_hit_ratio=${_inv_cache_hit_ratio} elapsed=${_inv_elapsed}s"

    echo "" >>"$OUTPUT_LOG"
    echo "--- End invocation $iteration ---" >>"$OUTPUT_LOG"

    if ! next_after=$(get_next_todo "$PLAN_PATH"); then
      read -r done_count total_count <<< "$(count_todos "$PLAN_PATH")"
      ralph_run_plan_log "all complete (done=$done_count total=$total_count)"
      {
        echo ""
        echo "################################################################################"
        echo "# All TODOs complete ($done_count/$total_count) - $(date '+%Y-%m-%d %H:%M:%S')"
        echo "################################################################################"
      } >>"$OUTPUT_LOG"
      echo ""
      echo -e "${C_G}${C_BOLD}All TODOs complete${C_RST} ${C_G}($done_count/$total_count)${C_RST}."
      _ralph_write_plan_usage_summary "$done_count" "$total_count"
      echo -e "${C_DIM}Output log: $OUTPUT_LOG${C_RST}"
      EXIT_STATUS="complete"
      exit 0
    fi
    next_line="${next_after%%|*}"

    if [[ "$next_line" != "$line_num" ]]; then
      if plan_todo_implies_operator_dialog "$todo_text" && [[ "$human_gate_satisfied_for_line" -eq 0 ]]; then
        ralph_run_plan_log "TODO line $line_num implies operator dialog but advanced without a recorded human reply; reopening checklist line and pausing"
        echo "" >&2
        echo -e "${C_Y}${C_BOLD}This TODO asks the user for input, but the agent marked it done without using pending-human.txt.${C_RST}" >&2
        echo -e "${C_DIM}Reopening the item and pausing for your reply (same rules as a normal agent question).${C_RST}" >&2
        if ! plan_reopen_todo_at_line "$PLAN_PATH" "$line_num"; then
          ralph_run_plan_log "ERROR: could not reopen TODO at line $line_num after missing human gate"
          echo -e "${C_R}Could not reopen plan line $line_num; fix PLAN.md manually.${C_RST}" >&2
          exit 1
        fi
        printf '%s\n' "$todo_text" >"$PENDING_HUMAN"
        chmod 600 "$PENDING_HUMAN"
        ralph_sync_human_action_file_state
      else
        ralph_run_plan_log "TODO line $line_num completed; next open TODO is line $next_line"
        rm -f "$PENDING_HUMAN"
        break
      fi
    fi

    ralph_sync_human_action_file_state

    if [[ -f "$PENDING_HUMAN" ]]; then
      if [[ "$HUMAN_PROMPT_DISABLE_FLAG" == "1" ]]; then
        ralph_run_plan_log "ERROR: $PENDING_HUMAN exists but human prompt disable flag is active"
        echo -e "${C_R}Agent requested human input; prompts disabled. Remove pending file or unset CURSOR_PLAN_DISABLE_HUMAN_PROMPT or RALPH_PLAN_DISABLE_HUMAN_PROMPT.${C_RST}" >&2
        exit 4
      fi
      _saved_q="$(<"$PENDING_HUMAN")"
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
        ralph_run_plan_log "human reply recorded (TTY); re-invoking agent for line $line_num"
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
      ralph_run_plan_log "GUTTER: line $line_num unchanged after $attempts_on_line attempts (per-TODO limit=$GUTTER_ITERATIONS)"
      _gutter_help_msg="Plan runner stopped (gutter): this TODO stayed open after $attempts_on_line attempts (per-TODO limit is $GUTTER_ITERATIONS). Unblock by fixing the task, editing the plan line, or raising the limit (CURSOR_PLAN_GUTTER_ITER / CLAUDE_PLAN_GUTTER_ITER / CODEX_PLAN_GUTTER_ITER or --max-iterations). To ask you a question, the agent should write to: $PENDING_ABS"
      if ralph_should_persist_human_files; then
        ralph_write_human_action_file "$_gutter_help_msg"
      fi
      echo "" >&2
      echo -e "${C_R}${C_BOLD}Agent did not complete this TODO after $attempts_on_line tries (gutter limit $GUTTER_ITERATIONS).${C_RST}" >&2
      echo -e "  Plan: $PLAN_PATH  Line $line_num: $todo_text" >&2
      echo -e "${C_DIM}Human help needed: adjust the plan or complete the work, then re-run.${C_RST}" >&2
      echo -e "${C_DIM}To ask you a question instead of retrying blindly, the agent should write to:${C_RST}" >&2
      echo "  $PENDING_ABS" >&2
      exit 1
    fi
    ralph_run_plan_log "TODO line $line_num still open (attempt $attempts_on_line/$GUTTER_ITERATIONS); retrying"
    sleep 2
  done
done
