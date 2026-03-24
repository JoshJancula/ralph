#!/usr/bin/env bash
#
# Shared helpers for managing CLI session state.
#
# Public interface:
#   ralph_session_init -- creates session dir, sets RALPH_PLAN_SESSION_HOME and SESSION_ID_FILE.
#   ralph_session_migrate_legacy -- copies old .ralph-workspace session files into the new home.
#   ralph_session_write_manual_resume -- writes --resume session id to session-id.txt.
#   ralph_session_prompt_cli_resume -- interactive y/n for RALPH_PLAN_CLI_RESUME.
#   ralph_session_apply_resume_strategy -- sets RALPH_RUN_PLAN_RESUME_SESSION_ID or RALPH_RUN_PLAN_RESUME_BARE.
#
# Exported environment (where noted below): visible to CLI wrapper scripts and demux.

# Initialize CLI session directories and helpers for this plan.
# Args: $1 - workspace path; $2 - plan log name (reserved for callers; not read here)
# Returns: 0 on success, non-zero on error
ralph_session_init() {
  local workspace="$1"
  local plan_log_name="$2"

  local _plan_session_home="${RALPH_PLAN_SESSION_HOME:-}"
  if [[ -z "$_plan_session_home" ]]; then
    local _workspace_root="${workspace%/}"
    local _workspace_sessions_root="${RALPH_PLAN_WORKSPACE_ROOT:-${_workspace_root}/.ralph-workspace}"
    _workspace_sessions_root="${_workspace_sessions_root%/}"
    _plan_session_home="${_workspace_sessions_root}/sessions"
  fi
  RALPH_PLAN_SESSION_HOME="$_plan_session_home"
  # Root directory containing per-plan session folders (session-id.txt, human files, etc.).
  export RALPH_PLAN_SESSION_HOME

  AGENTS_SESSION_ROOT="$RALPH_PLAN_SESSION_HOME"
  RALPH_SESSION_DIR="$AGENTS_SESSION_ROOT/${RALPH_PLAN_KEY}"
  mkdir -p "$RALPH_SESSION_DIR"
  chmod 700 "$RALPH_SESSION_DIR"

  SESSION_ID_FILE="$RALPH_SESSION_DIR/session-id.txt"
  # Path to the persisted assistant session id for CLI resume; read by invoke helpers and Python demux.
  export SESSION_ID_FILE
  PENDING_HUMAN="$RALPH_SESSION_DIR/pending-human.txt"
  HUMAN_CONTEXT="$RALPH_SESSION_DIR/human-replies.md"
  OPERATOR_RESPONSE_FILE="$RALPH_SESSION_DIR/operator-response.txt"
  HUMAN_INPUT_MD="$RALPH_SESSION_DIR/HUMAN-INPUT-REQUIRED.md"
  PENDING_ABS="$PENDING_HUMAN"

  ralph_session_migrate_legacy "$workspace"

  if [[ -n "$RESUME_SESSION_ID_OVERRIDE" ]]; then
    ralph_session_write_manual_resume "$RESUME_SESSION_ID_OVERRIDE"
  fi
}

# Migrate session data from legacy .ralph-workspace/sessions if it exists.
# Args: $1 - workspace path
# Returns: 0 on success (migration or no-op), non-zero on error
ralph_session_migrate_legacy() {
  local workspace="$1"
  local _legacy_plan_sess="$workspace/.ralph-workspace/sessions/${RALPH_PLAN_KEY}"
  if [[ ! -d "$_legacy_plan_sess" ]]; then
    return 0
  fi
  if [[ ! -s "$SESSION_ID_FILE" && -s "$_legacy_plan_sess/session-id.txt" ]]; then
    cp "$_legacy_plan_sess/session-id.txt" "$SESSION_ID_FILE"
    chmod 600 "$SESSION_ID_FILE"
    ralph_run_plan_log "Migrated session-id.txt from $_legacy_plan_sess to $RALPH_SESSION_DIR"
  fi
  local _mig_f
  for _mig_f in human-replies.md pending-human.txt operator-response.txt HUMAN-INPUT-REQUIRED.md; do
    if [[ ! -e "$RALPH_SESSION_DIR/$_mig_f" && -e "$_legacy_plan_sess/$_mig_f" ]]; then
      cp -a "$_legacy_plan_sess/$_mig_f" "$RALPH_SESSION_DIR/$_mig_f"
      ralph_run_plan_log "Migrated $_mig_f from legacy .ralph-workspace session dir"
    fi
  done
}

# Record a manual session id override for CLI resume.
# Args: $1 - session id string
# Returns: 0 on success, non-zero on error
ralph_session_write_manual_resume() {
  local session_id="$1"
  printf '%s\n' "$session_id" > "$SESSION_ID_FILE"
  chmod 600 "$SESSION_ID_FILE"
  ralph_run_plan_log "Manual resume session id provided via --resume; recorded in $SESSION_ID_FILE"
}

# Prompt the user interactively about reusing the CLI session across TODOs.
# Args: none
# Returns: 0 after updating RALPH_PLAN_CLI_RESUME, non-zero on unexpected errors
ralph_session_prompt_cli_resume() {
  if [[ "${_RALPH_PROMPT_CLI_RESUME_INTERACTIVE:-0}" != "1" ]]; then
    return 0
  fi
  if [[ "$NON_INTERACTIVE_FLAG" == "1" ]] || ! [[ -t 0 ]] || ! [[ -t 1 ]]; then
    return 0
  fi

  local _cr_runtime_label=""
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
  local _cr_ans=""
  read -r _cr_ans </dev/tty 2>/dev/null || _cr_ans=""
  _cr_ans="$(printf '%s' "${_cr_ans:-}" | tr '[:upper:]' '[:lower:]')"
  if [[ "$_cr_ans" == "y" || "$_cr_ans" == "yes" ]]; then
    RALPH_PLAN_CLI_RESUME=1
  else
    RALPH_PLAN_CLI_RESUME=0
  fi
  unset _RALPH_PROMPT_CLI_RESUME_INTERACTIVE
}

# Apply the configured CLI resume strategy by reading session files or overrides.
# Args: none
# Returns: 0 on success, non-zero on error
ralph_session_apply_resume_strategy() {
  unset RALPH_RUN_PLAN_RESUME_SESSION_ID
  unset RALPH_RUN_PLAN_RESUME_BARE

  if [[ -n "$RESUME_SESSION_ID_OVERRIDE" ]]; then
    # Explicit --resume id: pass through to the runtime wrapper unchanged.
    export RALPH_RUN_PLAN_RESUME_SESSION_ID="$RESUME_SESSION_ID_OVERRIDE"
    return 0
  fi

  if [[ "${RALPH_PLAN_CLI_RESUME:-0}" == "1" ]] && [[ -s "$SESSION_ID_FILE" ]]; then
    local _resume_sid=""
    if read -r _resume_sid < "$SESSION_ID_FILE"; then
      _resume_sid="${_resume_sid//$'\r'/}"
      _resume_sid="${_resume_sid//$'\n'/}"
      _resume_sid="${_resume_sid#"${_resume_sid%%[![:space:]]*}"}"
      _resume_sid="${_resume_sid%"${_resume_sid##*[![:space:]]}"}"
    fi
    if [[ -n "$_resume_sid" ]]; then
      # Session id from session-id.txt for targeted CLI --resume.
      export RALPH_RUN_PLAN_RESUME_SESSION_ID="$_resume_sid"
      ralph_run_plan_log "RALPH_PLAN_CLI_RESUME: using stored session id and compact prompt (--resume on the CLI)"
    fi
  fi

  if [[ "${RALPH_PLAN_CLI_RESUME:-0}" == "1" ]] && [[ -z "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]] && [[ "${RALPH_PLAN_ALLOW_UNSAFE_RESUME:-0}" == "1" ]]; then
    # Flag for runtimes that support resume-without-id (e.g. Codex --last); only when unsafe resume is allowed.
    export RALPH_RUN_PLAN_RESUME_BARE=1
    ralph_run_plan_log "RALPH_PLAN_ALLOW_UNSAFE_RESUME: no stored session id; using bare resume (wrong session possible on a busy host)"
    echo "Warning: bare CLI resume without a stored session id can attach to the wrong session when several projects use the same CLI on one machine. Prefer isolated CI or fix session capture." >&2
  fi
}
