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

AGENT_CONFIG_TOOL="$WORKSPACE/.ralph/agent-config-tool.sh"

if [[ -z "$RUNTIME" ]]; then
  if [[ -n "${RALPH_PLAN_RUNTIME:-}" ]]; then
    case "${RALPH_PLAN_RUNTIME}" in
      cursor|claude|codex)
        RUNTIME="${RALPH_PLAN_RUNTIME}"
        ;;
      *)
        ralph_die "Error: RALPH_PLAN_RUNTIME must be one of cursor, claude, or codex."
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
RALPH_PLAN_WORKSPACE_ROOT="${RALPH_PLAN_WORKSPACE_ROOT:-$WORKSPACE/.ralph-workspace}"
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
esac

RALPH_INVOKED_CLI=""
case "$RUNTIME" in
  cursor) RALPH_INVOKED_CLI="$CURSOR_CLI" ;;
  claude) RALPH_INVOKED_CLI="$CLAUDE_CLI" ;;
  codex) RALPH_INVOKED_CLI="$CODEX_CLI" ;;
esac

MAX_ITERATIONS="${CURSOR_PLAN_MAX_ITER:-9999}"
case "$RUNTIME" in
  cursor)
    _ralph_gutter_default="${CURSOR_PLAN_GUTTER_ITER:-10}"
    ;;
  claude)
    _ralph_gutter_default="${CLAUDE_PLAN_GUTTER_ITER:-${CURSOR_PLAN_GUTTER_ITER:-10}}"
    ;;
  codex)
    _ralph_gutter_default="${CODEX_PLAN_GUTTER_ITER:-${CLAUDE_PLAN_GUTTER_ITER:-${CURSOR_PLAN_GUTTER_ITER:-10}}}"
    ;;
  *)
    _ralph_gutter_default="${CURSOR_PLAN_GUTTER_ITER:-10}"
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
    codex)  _runtime_env_model="${CODEX_PLAN_MODEL:-${CURSOR_PLAN_MODEL:-}}" ;;
  esac
  if [[ -n "$_runtime_env_model" ]]; then
    SELECTED_MODEL="$_runtime_env_model"
    ralph_run_plan_log "runtime env model override: $SELECTED_MODEL (agent=$PREBUILT_AGENT)"
  fi
  if [[ -n "${PLAN_MODEL_CLI:-}" ]]; then
    SELECTED_MODEL="$PLAN_MODEL_CLI"
    ralph_run_plan_log "CLI --model overrides prebuilt agent default model (agent=$PREBUILT_AGENT)"
  fi
  PREBUILT_AGENT_CONTEXT="$(format_prebuilt_agent_context_block "$WORKSPACE" "$PREBUILT_AGENT")" || {
    echo -e "${C_R}Could not build run context for agent${C_RST} $PREBUILT_AGENT" >&2
    ralph_run_plan_log "ERROR: context build failed for $PREBUILT_AGENT"
    exit 1
  }
  ralph_run_plan_log "prebuilt agent id=$PREBUILT_AGENT model=$SELECTED_MODEL (config validated)"
  if [[ "$RUNTIME" == "claude" ]]; then
    _agents_root_for_tools="$(prebuilt_agents_root "$WORKSPACE")"
    CLAUDE_TOOLS_FROM_AGENT="$(bash "$AGENT_CONFIG_TOOL" allowed-tools "$_agents_root_for_tools" "$PREBUILT_AGENT" 2>/dev/null || true)"
    [[ -n "$CLAUDE_TOOLS_FROM_AGENT" ]] && ralph_run_plan_log "allowed_tools from agent config: $CLAUDE_TOOLS_FROM_AGENT"
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

    echo ""
    echo -e "${C_C}${C_BOLD}══════════════════════════════════════════════════════════════════════${C_RST}"
    echo -e "${C_C}Building plan:${C_RST} $PLAN_PATH"
    echo -e "  ${C_DIM}${C_RST}  ${C_BOLD}TASK ${task_ordinal}${C_RST}  ${C_DIM}|${C_RST}  Complete ${C_G}$done_count/$total_count |${C_RST} Skipped: 0 ${C_DIM}|${C_RST}  ${C_Y}invoke $iteration${C_RST} (line $line_num)"
    echo -e "${C_C}${C_BOLD}══════════════════════════════════════════════════════════════════════${C_RST}"
    echo -e "${C_BOLD}$todo_text${C_RST}"
    echo -e "${C_DIM}Log: $LOG_FILE  |  Output: $OUTPUT_LOG${C_RST}"
    echo ""

    # Refresh resume env from session-id.txt / flags before building PROMPT (compact vs full context).
    ralph_session_apply_resume_strategy

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
        PROMPT+=$'\n\n## Human operator answers (this plan run -- use them)\n'"$(<"$HUMAN_CONTEXT")"
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
        PROMPT+=$'\n\n## Human operator answers (this plan run -- use them)\n'"$(<"$HUMAN_CONTEXT")"
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
            ralph_run_plan_log "downstream stage plan context appended for: ${_ds_stage_list:-none}"
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
        mins=$((elapsed / 60))
        secs=$((elapsed % 60))
        if [[ $mins -gt 0 ]]; then
          echo -e "${C_DIM}[$(date '+%H:%M:%S')] Agent still working (elapsed ${mins}m ${secs}s).${C_RST}" >&2
        else
          echo -e "${C_DIM}[$(date '+%H:%M:%S')] Agent still working (elapsed ${secs}s).${C_RST}" >&2
        fi
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
    ralph_run_plan_log "$RALPH_INVOKED_CLI finished (exit=$exit_code)"

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
