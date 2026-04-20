#!/usr/bin/env bash
#
# Shared helpers for managing CLI session state.
#
# Public interface:
#   ralph_session_init -- creates session dir, sets RALPH_PLAN_SESSION_HOME and SESSION_ID_FILE.
#   ralph_session_migrate_legacy -- copies old .ralph-workspace session files into the new home.
#   ralph_session_write_manual_resume -- writes --resume session id to session-id.<runtime>.txt.
#   ralph_session_generate_uuid -- returns a UUID for pre-generated CLI resume ids.
#   ralph_session_prompt_cli_resume -- interactive session-strategy picker for TTY runs.
#   ralph_session_apply_resume_strategy -- sets RALPH_RUN_PLAN_RESUME_SESSION_ID or RALPH_RUN_PLAN_RESUME_BARE.
#   ralph_session_reset_resume_error_detected -- true when recent logs imply stale/invalid resumed sessions.
#   ralph_session_bump_turn_counter -- increments and returns session turn count.
#   ralph_session_maybe_rotate -- rotates session when threshold reached to cap cache growth.
#
# Exported environment (where noted below): visible to CLI wrapper scripts and demux.

ralph_session_strategy_is_truthy() {
  case "${1:-0}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

ralph_session_effective_strategy() {
  local strategy="${RALPH_PLAN_SESSION_STRATEGY:-}"
  case "$strategy" in
    fresh|resume|reset)
      printf '%s\n' "$strategy"
      return 0
      ;;
  esac

  if ralph_session_strategy_is_truthy "${RALPH_PLAN_CLI_RESUME:-0}"; then
    printf '%s\n' "resume"
  else
    printf '%s\n' "fresh"
  fi
}

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
  # Root directory containing per-plan session folders (runtime-specific session ids, human files, etc.).
  export RALPH_PLAN_SESSION_HOME

  AGENTS_SESSION_ROOT="$RALPH_PLAN_SESSION_HOME"
  RALPH_SESSION_DIR="$AGENTS_SESSION_ROOT/${RALPH_PLAN_KEY}"
  mkdir -p "$RALPH_SESSION_DIR"
  chmod 700 "$RALPH_SESSION_DIR"

  local _session_runtime="${RUNTIME:-runtime}"
  SESSION_ID_FILE="$RALPH_SESSION_DIR/session-id.${_session_runtime}.txt"
  SESSION_ID_FILE_LEGACY="$RALPH_SESSION_DIR/session-id.txt"
  # Path to the persisted assistant session id for CLI resume; read by invoke helpers and Python demux.
  export SESSION_ID_FILE
  export SESSION_ID_FILE_LEGACY
  PENDING_HUMAN="$RALPH_SESSION_DIR/pending-human.txt"
  HUMAN_CONTEXT="$RALPH_SESSION_DIR/human-replies.md"
  OPERATOR_RESPONSE_FILE="$RALPH_SESSION_DIR/operator-response.txt"
  HUMAN_INPUT_MD="$RALPH_SESSION_DIR/HUMAN-INPUT-REQUIRED.md"
  PENDING_ABS="$PENDING_HUMAN"

  ralph_session_migrate_legacy "$workspace"

  if [[ -n "${RESUME_SESSION_ID_OVERRIDE:-}" ]]; then
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
  if [[ -s "$_legacy_plan_sess/session-id.txt" && ! -s "$SESSION_ID_FILE" ]]; then
    ralph_run_plan_log "Ignoring legacy shared session-id.txt in $_legacy_plan_sess; session ids are now runtime-specific"
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
  if [[ -n "${SESSION_ID_FILE_LEGACY:-}" && "$SESSION_ID_FILE_LEGACY" != "$SESSION_ID_FILE" ]]; then
    printf '%s\n' "$session_id" > "$SESSION_ID_FILE_LEGACY"
    chmod 600 "$SESSION_ID_FILE_LEGACY"
  fi
  ralph_run_plan_log "Manual resume session id provided via --resume; recorded in $SESSION_ID_FILE"
}

# Generate a UUID from /proc when available.
# Returns: UUID on stdout, non-zero when /proc is unavailable or unreadable
ralph_session_generate_uuid_from_proc() {
  [[ -r /proc/sys/kernel/random/uuid ]] || return 1
  cat /proc/sys/kernel/random/uuid
}

# Generate a UUID using the best available source on this system.
# Returns: UUID on stdout, non-zero on error
ralph_session_generate_uuid() {
  local _ralph_debug_log_path="/Users/joshuajancula/Documents/projects/ralph/.cursor/debug-214144.log"
  # #region agent log
  printf '{"sessionId":"214144","runId":"uuid-pre-fix","hypothesisId":"S1","location":"run-plan-session.sh:104","message":"generate_uuid entry","data":{"path":"%s"},"timestamp":%s}\n' "$PATH" "$(( $(date +%s) * 1000 ))" >>"$_ralph_debug_log_path"
  # #endregion
  if command -v uuidgen >/dev/null 2>&1; then
    # #region agent log
    printf '{"sessionId":"214144","runId":"uuid-pre-fix","hypothesisId":"S2","location":"run-plan-session.sh:108","message":"uuidgen detected","data":{"uuidgen_path":"%s"},"timestamp":%s}\n' "$(command -v uuidgen 2>/dev/null || printf missing)" "$(( $(date +%s) * 1000 ))" >>"$_ralph_debug_log_path"
    # #endregion
    uuidgen
    # #region agent log
    printf '{"sessionId":"214144","runId":"uuid-pre-fix","hypothesisId":"S3","location":"run-plan-session.sh:111","message":"uuidgen finished","data":{"exit_code":"%s"},"timestamp":%s}\n' "$?" "$(( $(date +%s) * 1000 ))" >>"$_ralph_debug_log_path"
    # #endregion
    return $?
  fi

  if ralph_session_generate_uuid_from_proc; then
    # #region agent log
    printf '{"sessionId":"214144","runId":"uuid-pre-fix","hypothesisId":"S4","location":"run-plan-session.sh:117","message":"proc uuid succeeded","data":{},"timestamp":%s}\n' "$(( $(date +%s) * 1000 ))" >>"$_ralph_debug_log_path"
    # #endregion
    return $?
  fi

  if command -v python3 >/dev/null 2>&1; then
    # #region agent log
    printf '{"sessionId":"214144","runId":"uuid-pre-fix","hypothesisId":"S5","location":"run-plan-session.sh:124","message":"python3 fallback selected","data":{"python3_path":"%s"},"timestamp":%s}\n' "$(command -v python3 2>/dev/null || printf missing)" "$(( $(date +%s) * 1000 ))" >>"$_ralph_debug_log_path"
    # #endregion
    python3 -c 'import uuid; print(uuid.uuid4())'
    return $?
  fi

  echo "Error: unable to generate a UUID for CLI resume." >&2
  return 1
}

# Prompt the user interactively about session behavior across TODOs.
# Args: none
# Returns: 0 after updating RALPH_PLAN_SESSION_STRATEGY / RALPH_PLAN_CLI_RESUME, non-zero on unexpected errors
ralph_session_prompt_cli_resume() {
  local _prompt_enabled="${_RALPH_PROMPT_SESSION_STRATEGY_INTERACTIVE:-${_RALPH_PROMPT_CLI_RESUME_INTERACTIVE:-0}}"
  if [[ "$_prompt_enabled" != "1" ]]; then
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
  echo -e "${C_C}${C_BOLD}Session Strategy${C_RST}" >&2
  echo -e "${C_BOLD}How should ${_cr_runtime_label} handle sessions between TODOs?${C_RST}" >&2
  echo "" >&2
  echo -e "  ${C_G}1${C_RST}  ${C_BOLD}fresh${C_RST}  ${C_DIM}(recommended default) new session behavior per TODO${C_RST}" >&2
  echo -e "  ${C_G}2${C_RST}  ${C_BOLD}resume${C_RST} ${C_DIM}continue exact prior session context${C_RST}" >&2
  echo -e "  ${C_G}3${C_RST}  ${C_BOLD}reset${C_RST}  ${C_DIM}reuse session id with reset command + reset-oriented TODO prompts${C_RST}" >&2
  echo "" >&2
  echo -e "${C_DIM}Session ids are stored at:${C_RST}" >&2
  echo -e "${C_DIM}  ${SESSION_ID_FILE}${C_RST}" >&2
  echo -e "${C_DIM}Python 3 on PATH is required to capture/update ids from JSON output.${C_RST}" >&2
  echo "" >&2
  local _cr_choice _cr_strategy
  if declare -F ralph_menu_select >/dev/null 2>&1; then
    _cr_choice="$(ralph_menu_select --prompt "Session strategy" --default 1 -- "fresh" "resume" "reset")"
  else
    _cr_choice="$(ralph_prompt_text "Session strategy (fresh/resume/reset)" "fresh")"
  fi
  case "$_cr_choice" in
    resume|reset) _cr_strategy="$_cr_choice" ;;
    *) _cr_strategy="fresh" ;;
  esac

  RALPH_PLAN_SESSION_STRATEGY="$_cr_strategy"
  if [[ "$_cr_strategy" == "fresh" ]]; then
    RALPH_PLAN_CLI_RESUME=0
  else
    RALPH_PLAN_CLI_RESUME=1
  fi
  export RALPH_PLAN_SESSION_STRATEGY
  unset _RALPH_PROMPT_CLI_RESUME_INTERACTIVE
  unset _RALPH_PROMPT_SESSION_STRATEGY_INTERACTIVE
}

# Apply the configured CLI resume strategy by reading session files or overrides.
# Args: none
# Returns: 0 on success, non-zero on error
ralph_session_apply_resume_strategy() {
  unset RALPH_RUN_PLAN_RESUME_SESSION_ID
  unset RALPH_RUN_PLAN_NEW_SESSION_ID
  unset RALPH_RUN_PLAN_RESUME_BARE

  if [[ -n "${RESUME_SESSION_ID_OVERRIDE:-}" ]]; then
    # Explicit --resume id: pass through to the runtime wrapper unchanged.
    export RALPH_RUN_PLAN_RESUME_SESSION_ID="$RESUME_SESSION_ID_OVERRIDE"
    RALPH_PLAN_SESSION_STRATEGY="resume"
    RALPH_PLAN_CLI_RESUME=1
    export RALPH_PLAN_SESSION_STRATEGY
    return 0
  fi

  local _strategy=""
  _strategy="$(ralph_session_effective_strategy)"
  RALPH_PLAN_SESSION_STRATEGY="$_strategy"
  case "$_strategy" in
    resume|reset) RALPH_PLAN_CLI_RESUME=1 ;;
    *) RALPH_PLAN_CLI_RESUME=0 ;;
  esac
  export RALPH_PLAN_SESSION_STRATEGY

  if [[ "$_strategy" == "fresh" ]]; then
    return 0
  fi

  if [[ -s "$SESSION_ID_FILE" ]]; then
    local _resume_sid=""
    if read -r _resume_sid < "$SESSION_ID_FILE"; then
      _resume_sid="${_resume_sid//$'\r'/}"
      _resume_sid="${_resume_sid//$'\n'/}"
      _resume_sid="${_resume_sid#"${_resume_sid%%[![:space:]]*}"}"
      _resume_sid="${_resume_sid%"${_resume_sid##*[![:space:]]}"}"
    fi
    if [[ -n "$_resume_sid" ]]; then
      # Session id from session-id.<runtime>.txt for targeted CLI --resume.
      export RALPH_RUN_PLAN_RESUME_SESSION_ID="$_resume_sid"
      ralph_run_plan_log "session strategy $_strategy: using stored session id (--resume on the CLI)"
    fi
  fi

  if [[ "$_strategy" == "resume" ]] && [[ ! -s "$SESSION_ID_FILE" ]] && [[ -z "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]] && [[ "${RALPH_PLAN_ALLOW_UNSAFE_RESUME:-0}" != "1" ]]; then
    local _new_session_id=""
    if _new_session_id="$(ralph_session_generate_uuid)"; then
      printf '%s\n' "$_new_session_id" > "$SESSION_ID_FILE"
      chmod 600 "$SESSION_ID_FILE"
      export RALPH_RUN_PLAN_NEW_SESSION_ID="$_new_session_id"
      ralph_run_plan_log "session strategy resume: pre-generated new session id and will use --session-id on first run"
      return 0
    fi
  fi

  if [[ "$_strategy" == "reset" ]] && [[ -z "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]] && [[ "${RALPH_PLAN_ALLOW_UNSAFE_RESUME:-0}" != "1" ]]; then
    if [[ "${RUNTIME:-}" == "claude" ]]; then
      local _reset_new_session_id=""
      if _reset_new_session_id="$(ralph_session_generate_uuid)"; then
        printf '%s\n' "$_reset_new_session_id" > "$SESSION_ID_FILE"
        chmod 600 "$SESSION_ID_FILE"
        export RALPH_RUN_PLAN_NEW_SESSION_ID="$_reset_new_session_id"
        ralph_run_plan_log "session strategy reset: pre-generated first Claude session id for bootstrap"
        return 0
      fi
    fi
    ralph_run_plan_log "session strategy reset: no stored session id yet; running fresh once to capture it"
    return 0
  fi

  if [[ -z "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]] && [[ "${RALPH_PLAN_ALLOW_UNSAFE_RESUME:-0}" == "1" ]]; then
    # Flag for runtimes that support resume-without-id (e.g. Codex --last); only when unsafe resume is allowed.
    export RALPH_RUN_PLAN_RESUME_BARE=1
    ralph_run_plan_log "session strategy $_strategy with RALPH_PLAN_ALLOW_UNSAFE_RESUME=1: using bare resume (wrong session possible on a busy host)"
    echo "Warning: bare CLI resume without a stored session id can attach to the wrong session when several projects use the same CLI on one machine. Prefer isolated CI or fix session capture." >&2
  fi
}

ralph_session_reset_resume_error_detected() {
  local runtime="${1:-}"
  local output_log="${2:-}"
  [[ -n "$runtime" ]] || return 1
  [[ -n "$output_log" ]] || return 1
  [[ -f "$output_log" ]] || return 1

  local _recent
  _recent="$(tail -n 240 "$output_log" 2>/dev/null || true)"
  [[ -n "$_recent" ]] || return 1

  if printf '%s\n' "$_recent" | grep -Eiq \
    'session[^[:alnum:]]*(not[[:space:]-_]*found|does[[:space:]-_]*not[[:space:]-_]*exist|missing|invalid)|unknown[[:space:]-_]*session|no[[:space:]-_]*such[[:space:]-_]*session|chat[^[:alnum:]]*not[[:space:]-_]*found|thread[^[:alnum:]]*not[[:space:]-_]*found'; then
    return 0
  fi
  return 1
}

# Bump the session turn counter atomically.
# Returns the new count on stdout, or empty if RALPH_SESSION_DIR is unset.
ralph_session_bump_turn_counter() {
  if [[ -z "${RALPH_SESSION_DIR:-}" ]]; then
    return 0
  fi
  local _count_file="$RALPH_SESSION_DIR/session-turn-count.txt"
  local _count=0
  if [[ -f "$_count_file" ]]; then
    _count=$(cat "$_count_file" 2>/dev/null || echo 0)
    _count=$((_count + 1))
  else
    _count=1
  fi
  printf '%d' "$_count" > "$_count_file" || true
  printf '%d' "$_count"
}

# Check if session should rotate based on threshold.
# Args: $1 - threshold (number of turns before rotation, 0 means disabled)
# If threshold reached, deletes session files and logs rotation.
ralph_session_maybe_rotate() {
  local _threshold="${1:-0}"
  if [[ -z "${RALPH_SESSION_DIR:-}" ]] || [[ "$_threshold" -le 0 ]]; then
    return 0
  fi
  local _count_file="$RALPH_SESSION_DIR/session-turn-count.txt"
  local _count=0
  if [[ -f "$_count_file" ]]; then
    _count=$(cat "$_count_file" 2>/dev/null || echo 0)
  fi
  if [[ "$_count" -ge "$_threshold" ]]; then
    # Rotation triggered
    rm -f "$RALPH_SESSION_DIR"/session-id.*.txt 2>/dev/null || true
    rm -f "$_count_file" 2>/dev/null || true
    ralph_run_plan_log "session rotated after $_count turns to cap cache growth; next invocation starts a fresh CLI session."
  fi
}
