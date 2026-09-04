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
#   ralph_session_todo_* -- tier-2 per-TODO session manifests under todo-sessions/.
#   ralph_session_todo_prepare_invocation -- resolve todo-start|todo-continue and resume env.
#   ralph_session_todo_capture_after_invocation -- persist effective session id to manifest.
#   ralph_session_derive_cli_resume -- set RALPH_PLAN_CLI_RESUME from reason + strategy.
#
# Exported environment (where noted below): visible to CLI wrapper scripts and demux.

RALPH_TODO_SESSION_SCHEMA_VERSION=1
RALPH_TODO_SESSION_STATE_ACTIVE="active"
RALPH_TODO_SESSION_STATE_TERMINAL="terminal"
RALPH_TODO_SESSION_STATE_RETIRED="retired"
RALPH_TODO_INVOCATION_REASON_START="todo-start"
RALPH_TODO_INVOCATION_REASON_CONTINUE="todo-continue"
RALPH_TODO_SESSION_CAPTURE_EXACT="exact"
RALPH_TODO_SESSION_CAPTURE_DEGRADED="degraded"

ralph_session_strategy_is_truthy() {
  case "${1:-0}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

ralph_session_effective_strategy() {
  local strategy="${RALPH_PLAN_SESSION_STRATEGY:-}"
  case "$strategy" in
    reset|compact)
      printf '%s\n' "$strategy"
      return 0
      ;;
  esac

  if ralph_session_strategy_is_truthy "${RALPH_PLAN_CLI_RESUME:-0}"; then
    printf '%s\n' "resume"
    return 0
  fi

  case "$strategy" in
    fresh|resume)
      printf '%s\n' "$strategy"
      return 0
      ;;
  esac

  printf '%s\n' "fresh"
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
    local _project_local_ralph="${_workspace_root}/.ralph"

    if [[ -n "${RALPH_HOME:-}" ]] && [[ ! -d "$_project_local_ralph" ]]; then
      _plan_session_home="${XDG_STATE_HOME:-$HOME/.local/state}/ralph/sessions"
    else
      local _workspace_sessions_root="${RALPH_PLAN_WORKSPACE_ROOT:-${_workspace_root}/.ralph-workspace}"
      _workspace_sessions_root="${_workspace_sessions_root%/}"
      _plan_session_home="${_workspace_sessions_root}/sessions"
    fi
  fi
  RALPH_PLAN_SESSION_HOME="$_plan_session_home"
  # Root directory containing per-plan session folders (runtime-specific session ids, human files, etc.).
  export RALPH_PLAN_SESSION_HOME

  AGENTS_SESSION_ROOT="$RALPH_PLAN_SESSION_HOME"
  RALPH_SESSION_DIR="$AGENTS_SESSION_ROOT/${RALPH_PLAN_KEY}"
  export RALPH_SESSION_DIR
  RALPH_EFFICIENCY_HINT_FILE="$RALPH_SESSION_DIR/last-efficiency-hint.txt"
  export RALPH_EFFICIENCY_HINT_FILE
  mkdir -p "$RALPH_SESSION_DIR"
  chmod 700 "$RALPH_SESSION_DIR"

  local _session_runtime="${RUNTIME:-runtime}"
  SESSION_ID_FILE="$RALPH_SESSION_DIR/session-id.${_session_runtime}.txt"
  SESSION_ID_FILE_LEGACY="$RALPH_SESSION_DIR/session-id.txt"
  # Path to the persisted assistant session id for CLI resume; read by invoke helpers and Python demux.
  export SESSION_ID_FILE
  export SESSION_ID_FILE_LEGACY
  PENDING_HUMAN="$RALPH_SESSION_DIR/pending-human.txt"
  HUMAN_REQUEST_FILE="$RALPH_SESSION_DIR/human-request.json"
  HUMAN_CONTEXT="$RALPH_SESSION_DIR/human-replies.md"
  OPERATOR_RESPONSE_FILE="$RALPH_SESSION_DIR/operator-response.txt"
  HUMAN_INPUT_MD="$RALPH_SESSION_DIR/HUMAN-INPUT-REQUIRED.md"
  RALPH_MCP_ALLOWLIST_FILE="$RALPH_SESSION_DIR/mcp-allowlist.txt"
  PENDING_ABS="$PENDING_HUMAN"
  PENDING_HUMAN_OWNER="$RALPH_SESSION_DIR/pending-human.owner"
  export HUMAN_REQUEST_FILE
  export RALPH_MCP_ALLOWLIST_FILE

  ralph_session_discard_foreign_run_pause

  ralph_session_migrate_legacy "$workspace"
  ralph_session_load_mcp_allowlist

  if [[ -n "${RESUME_SESSION_ID_OVERRIDE:-}" ]]; then
    ralph_session_write_manual_resume "$RESUME_SESSION_ID_OVERRIDE"
  fi
}

# Discard a permission pause left behind by a different graph run.
#
# The session directory is keyed by namespace and node, not by run id, so it is
# shared by every run of the same graph node. A pause records a question that
# only the run that asked it can answer: its operator request lives under that
# run's operator/requests directory, and the run-local response file it waits on
# is written by that run alone. Once that run ends, the pause is unanswerable,
# but the file survives -- so the next run sees a pending question at session
# init and pauses again before invoking the agent at all, forever.
#
# Only graph runs are scoped this way. A plain `ralph run` deliberately inherits
# a pending pause across invocations, because that is how an operator answers a
# question and resumes: same session dir, next invocation.
ralph_session_discard_foreign_run_pause() {
  [[ -n "${RALPH_GRAPH_RUN_ID:-}" ]] || return 0
  [[ -f "$PENDING_HUMAN" ]] || return 0

  local owner=""
  if [[ -f "$PENDING_HUMAN_OWNER" ]]; then
    owner="$(<"$PENDING_HUMAN_OWNER")"
  fi
  if [[ "$owner" == "$RALPH_GRAPH_RUN_ID" ]]; then
    return 0
  fi

  rm -f "$PENDING_HUMAN" "$PENDING_HUMAN_OWNER" "$OPERATOR_RESPONSE_FILE" \
    "$HUMAN_REQUEST_FILE" "$HUMAN_INPUT_MD" \
    "$RALPH_SESSION_DIR/permission-remediation.json"
  : >"$HUMAN_CONTEXT"
  ralph_run_plan_log "Discarded permission pause from ${owner:-an earlier run} (current graph run ${RALPH_GRAPH_RUN_ID}); it cannot be answered from this run"
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
  for _mig_f in human-replies.md pending-human.txt operator-response.txt HUMAN-INPUT-REQUIRED.md human-request.json mcp-allowlist.txt; do
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

ralph_session_load_mcp_allowlist() {
  local file="${RALPH_MCP_ALLOWLIST_FILE:-}"
  local merged="${RALPH_MCP_ALLOWLIST:-}"
  local entry trimmed

  if [[ -n "$file" && -f "$file" ]]; then
    while IFS= read -r entry; do
      trimmed="${entry#"${entry%%[![:space:]]*}"}"
      trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
      [[ -n "$trimmed" ]] || continue
      case ",$merged," in
        *,"$trimmed",*) ;;
        *)
          if [[ -n "$merged" ]]; then
            merged+=","
          fi
          merged+="$trimmed"
          ;;
      esac
    done < "$file"
  fi

  RALPH_MCP_ALLOWLIST="$merged"
  export RALPH_MCP_ALLOWLIST
}

ralph_session_append_mcp_allowlist_entries() {
  local file="${RALPH_MCP_ALLOWLIST_FILE:-}"
  local entry trimmed

  [[ -n "$file" ]] || return 1
  mkdir -p "$(dirname "$file")"
  touch "$file"

  for entry in "$@"; do
    trimmed="${entry#"${entry%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [[ -n "$trimmed" ]] || continue
    if ! grep -Fxq -- "$trimmed" "$file" 2>/dev/null; then
      printf '%s\n' "$trimmed" >> "$file"
      chmod 600 "$file" 2>/dev/null || true
    fi
  done

  ralph_session_load_mcp_allowlist
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
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen
    return $?
  fi

  if ralph_session_generate_uuid_from_proc; then
    return $?
  fi

  if command -v python3 >/dev/null 2>&1; then
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
  if [[ "${RALPH_SESSION_STRATEGY_PROMPT_ASSUME_TTY:-0}" != "1" ]]; then
    if [[ "$NON_INTERACTIVE_FLAG" == "1" ]] || ! [[ -t 0 ]] || ! [[ -t 1 ]]; then
      return 0
    fi
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
  echo -e "  ${C_G}4${C_RST}  ${C_BOLD}compact${C_RST} ${C_DIM}reuse session id with a compact command prefix before each TODO${C_RST}" >&2
  echo "" >&2
  echo -e "${C_DIM}Session ids are stored at:${C_RST}" >&2
  echo -e "${C_DIM}  ${SESSION_ID_FILE}${C_RST}" >&2
  echo -e "${C_DIM}Python 3 on PATH is required to capture/update ids from JSON output.${C_RST}" >&2
  echo "" >&2
  local _cr_choice _cr_strategy
  if declare -F ralph_menu_select >/dev/null 2>&1; then
    _cr_choice="$(ralph_menu_select --prompt "Session strategy" --default 1 -- "fresh" "resume" "reset" "compact")"
  else
    _cr_choice="$(ralph_prompt_text "Session strategy (fresh/resume/reset/compact)" "fresh")"
  fi
  case "$_cr_choice" in
    resume|reset|compact) _cr_strategy="$_cr_choice" ;;
    *) _cr_strategy="fresh" ;;
  esac

  RALPH_PLAN_SESSION_STRATEGY="$_cr_strategy"
  export RALPH_PLAN_SESSION_STRATEGY
  unset RALPH_PLAN_INVOCATION_REASON
  ralph_session_derive_cli_resume
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
    export RALPH_PLAN_SESSION_STRATEGY
    unset RALPH_PLAN_INVOCATION_REASON
    ralph_session_derive_cli_resume
    return 0
  fi

  local _strategy=""
  _strategy="$(ralph_session_effective_strategy)"
  RALPH_PLAN_SESSION_STRATEGY="$_strategy"
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
    if [[ "${RUNTIME:-}" == "opencode" ]]; then
      ralph_run_plan_log "session strategy resume: no stored opencode session id yet; running fresh once to capture it"
      return 0
    fi
    local _new_session_id=""
    if _new_session_id="$(ralph_session_generate_uuid)"; then
      printf '%s\n' "$_new_session_id" > "$SESSION_ID_FILE"
      chmod 600 "$SESSION_ID_FILE"
      export RALPH_RUN_PLAN_NEW_SESSION_ID="$_new_session_id"
      ralph_run_plan_log "session strategy resume: pre-generated new session id and will use --session-id on first run"
      return 0
    fi
  fi

  if ([[ "$_strategy" == "reset" ]] || [[ "$_strategy" == "compact" ]]) && [[ -z "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]] && [[ "${RALPH_PLAN_ALLOW_UNSAFE_RESUME:-0}" != "1" ]]; then
    if [[ "${RUNTIME:-}" == "claude" ]]; then
      local _reset_new_session_id=""
      if _reset_new_session_id="$(ralph_session_generate_uuid)"; then
        printf '%s\n' "$_reset_new_session_id" > "$SESSION_ID_FILE"
        chmod 600 "$SESSION_ID_FILE"
        export RALPH_RUN_PLAN_NEW_SESSION_ID="$_reset_new_session_id"
        ralph_run_plan_log "session strategy $_strategy: pre-generated first Claude session id for bootstrap"
        return 0
      fi
    fi
    ralph_run_plan_log "session strategy $_strategy: no stored session id yet; running fresh once to capture it"
    return 0
  fi

  if [[ -z "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]] && [[ "${RALPH_PLAN_ALLOW_UNSAFE_RESUME:-0}" == "1" ]]; then
    # Flag for runtimes that support resume-without-id (e.g. Codex --last); only when unsafe resume is allowed.
    export RALPH_RUN_PLAN_RESUME_BARE=1
    ralph_run_plan_log "session strategy $_strategy with RALPH_PLAN_ALLOW_UNSAFE_RESUME=1: using bare resume (wrong session possible on a busy host)"
    echo "Warning: bare CLI resume without a stored session id can attach to the wrong session when several projects use the same CLI on one machine. Prefer isolated CI or fix session capture." >&2
  fi

  if [[ -z "${RALPH_PLAN_INVOCATION_REASON:-}" ]]; then
    ralph_session_derive_cli_resume
  fi
}

# Tier-2 per-TODO session manifest helpers (todo-sessions/<sanitized-key>.json).

ralph_session_todo_require_session_dir() {
  [[ -n "${RALPH_SESSION_DIR:-}" ]] || {
    printf '%s\n' "Error: RALPH_SESSION_DIR is required for TODO session manifests" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || {
    printf '%s\n' "Error: jq is required for TODO session manifests" >&2
    return 1
  }
}

ralph_session_todo_sanitize_key() {
  local raw="${1:-}"
  local sanitized
  [[ -n "$raw" ]] || return 1
  [[ "$raw" != /* ]] || return 1
  [[ "$raw" != *"/"* && "$raw" != *".."* ]] || return 1
  sanitized="$(printf '%s' "$raw" | LC_ALL=C tr -cd '[:print:]' | sed 's/[^A-Za-z0-9._-]/_/g')"
  [[ -n "$sanitized" ]] || return 1
  [[ "$sanitized" != "." && "$sanitized" != ".." ]] || return 1
  printf '%s\n' "$sanitized"
}

ralph_session_todo_run_id() {
  if [[ -n "${RALPH_PROCESS_RUN_ID:-}" ]]; then
    printf '%s\n' "$RALPH_PROCESS_RUN_ID"
  elif [[ -n "${RALPH_GRAPH_RUN_ID:-}" ]]; then
    printf '%s\n' "$RALPH_GRAPH_RUN_ID"
  elif [[ -n "${RALPH_WORKFLOW_RUN_ID:-}" ]]; then
    printf '%s\n' "$RALPH_WORKFLOW_RUN_ID"
  else
    printf '%s\n' ""
  fi
}

ralph_session_todo_identity_json() {
  jq -nc \
    --arg projectRoot "${RALPH_PROJECT_ROOT:-}" \
    --arg stateRoot "${RALPH_PLAN_WORKSPACE_ROOT:-}" \
    --arg agentWorkspace "${RALPH_AGENT_WORKSPACE:-}" \
    --arg planKey "${RALPH_PLAN_KEY:-}" \
    --arg runtime "${RUNTIME:-${RALPH_PLAN_RUNTIME:-}}" \
    --arg runId "$(ralph_session_todo_run_id)" \
    --arg todoLine "${RALPH_CURRENT_TODO_LINE:-}" \
    --arg todoOrdinal "${RALPH_CURRENT_TODO_ORDINAL:-}" \
    --arg todoId "${RALPH_CURRENT_TODO_ID:-}" \
    --arg todoHash "${RALPH_CURRENT_TODO_HASH:-}" \
    --arg workflowRunId "${RALPH_WORKFLOW_RUN_ID:-}" \
    --arg workflowStageId "${RALPH_WORKFLOW_STAGE_ID:-}" \
    --arg workflowStageAttempt "${RALPH_WORKFLOW_STAGE_ATTEMPT:-}" \
    '{
      projectRoot: (if $projectRoot == "" then null else $projectRoot end),
      stateRoot: (if $stateRoot == "" then null else $stateRoot end),
      agentWorkspace: (if $agentWorkspace == "" then null else $agentWorkspace end),
      planKey: (if $planKey == "" then null else $planKey end),
      runtime: (if $runtime == "" then null else $runtime end),
      runId: (if $runId == "" then null else $runId end),
      todoLine: (if $todoLine == "" then null else $todoLine end),
      todoOrdinal: (if $todoOrdinal == "" then null else $todoOrdinal end),
      todoId: (if $todoId == "" then null else $todoId end),
      todoHash: (if $todoHash == "" then null else $todoHash end),
      workflowRunId: (if $workflowRunId == "" then null else $workflowRunId end),
      workflowStageId: (if $workflowStageId == "" then null else $workflowStageId end),
      workflowStageAttempt: (if $workflowStageAttempt == "" then null else $workflowStageAttempt end)
    }'
}

ralph_session_todo_attempt_key() {
  local identity_json="${1:-}"
  jq -c '[
    .planKey // "",
    .todoLine // "",
    .todoOrdinal // "",
    .todoId // "",
    .todoHash // "",
    .workflowRunId // "",
    .workflowStageId // "",
    .workflowStageAttempt // ""
  ] | join("|")' <<<"$identity_json"
}

ralph_session_todo_manifest_raw_key() {
  local identity_json="${1:-$(ralph_session_todo_identity_json)}"
  local todo_id todo_line todo_ordinal todo_hash
  todo_id="$(jq -r '.todoId // empty' <<<"$identity_json")"
  if [[ -n "$todo_id" ]]; then
    printf '%s\n' "$todo_id"
    return 0
  fi
  todo_line="$(jq -r '.todoLine // empty' <<<"$identity_json")"
  todo_ordinal="$(jq -r '.todoOrdinal // empty' <<<"$identity_json")"
  todo_hash="$(jq -r '.todoHash // empty' <<<"$identity_json")"
  printf '%s\n' "line-${todo_line}-ord-${todo_ordinal}-hash-${todo_hash}"
}

ralph_session_todo_manifest_key() {
  local identity_json="${1:-$(ralph_session_todo_identity_json)}"
  local raw_key sanitized
  raw_key="$(ralph_session_todo_manifest_raw_key "$identity_json")" || return 1
  sanitized="$(ralph_session_todo_sanitize_key "$raw_key")" || return 1
  printf '%s\n' "$sanitized"
}

ralph_session_todo_manifest_dir() {
  ralph_session_todo_require_session_dir || return 1
  printf '%s/todo-sessions\n' "$RALPH_SESSION_DIR"
}

ralph_session_todo_manifest_path() {
  local manifest_key="${1:-}"
  local dir
  [[ -n "$manifest_key" ]] || return 1
  [[ "$manifest_key" != *"/"* && "$manifest_key" != *".."* ]] || return 1
  dir="$(ralph_session_todo_manifest_dir)" || return 1
  printf '%s/%s.json\n' "$dir" "$manifest_key"
}

ralph_session_todo_valid_state() {
  local state="${1:-}"
  case "$state" in
    "$RALPH_TODO_SESSION_STATE_ACTIVE"|"$RALPH_TODO_SESSION_STATE_TERMINAL"|"$RALPH_TODO_SESSION_STATE_RETIRED")
      return 0
      ;;
  esac
  return 1
}

ralph_session_todo_atomic_write_manifest() {
  local target_path="${1:-}"
  local json_payload="${2:-}"
  local target_dir tmp_file
  [[ -n "$target_path" && -n "$json_payload" ]] || return 1
  target_dir="$(dirname "$target_path")"
  mkdir -p "$target_dir" || return 1
  chmod 700 "$target_dir" 2>/dev/null || true
  tmp_file="$(mktemp "$target_dir/.todo-session-XXXXXX" 2>/dev/null)" || return 1
  printf '%s\n' "$json_payload" >"$tmp_file" || {
    rm -f "$tmp_file"
    return 1
  }
  chmod 0600 "$tmp_file" 2>/dev/null || true
  if ! mv -f "$tmp_file" "$target_path" 2>/dev/null; then
    rm -f "$tmp_file"
    return 1
  fi
  chmod 0600 "$target_path" 2>/dev/null || true
  return 0
}

ralph_session_todo_manifest_malformed_reason() {
  local record="${1:-}"
  jq -e '
    type == "object"
    and (.schema_version | type) == "number"
    and (.schema_version == '"$RALPH_TODO_SESSION_SCHEMA_VERSION"')
    and (.manifest_key | type) == "string" and (.manifest_key | length) > 0
    and (.state | type) == "string"
    and (.runtime | type) == "string" and (.runtime | length) > 0
    and (.identity | type) == "object"
    and (.created_at | type) == "string"
    and (.updated_at | type) == "string"
  ' <<<"$record" >/dev/null 2>&1 || {
    printf '%s\n' "malformed-record"
    return 0
  }
  if ! ralph_session_todo_valid_state "$(jq -r '.state' <<<"$record")"; then
    printf '%s\n' "malformed-state"
    return 0
  fi
  local manifest_key record_key
  manifest_key="$(jq -r '.manifest_key' <<<"$record")"
  record_key="$(ralph_session_todo_sanitize_key "$(ralph_session_todo_manifest_raw_key "$(jq -c '.identity' <<<"$record")")")" || {
    printf '%s\n' "invalid-manifest-key"
    return 0
  }
  if [[ "$manifest_key" != "$record_key" ]]; then
    printf '%s\n' "manifest-key-mismatch"
    return 0
  fi
  printf '%s\n' ""
}

ralph_session_todo_identity_mismatch_reason() {
  local record="${1:-}"
  local current_identity current_runtime record_runtime
  local current_run record_run
  local current_hash record_hash
  local current_attempt record_attempt
  local current_todo_id record_todo_id
  local current_line record_line
  local current_ordinal record_ordinal

  current_identity="$(ralph_session_todo_identity_json)"
  current_runtime="$(jq -r '.runtime // empty' <<<"$current_identity")"
  record_runtime="$(jq -r '.runtime // empty' <<<"$record")"
  if [[ -n "$current_runtime" && -n "$record_runtime" && "$current_runtime" != "$record_runtime" ]]; then
    printf '%s\n' "mismatched-runtime"
    return 0
  fi

  current_run="$(jq -r '.runId // empty' <<<"$current_identity")"
  record_run="$(jq -r '.identity.runId // empty' <<<"$record")"
  if [[ -n "$current_run" && -n "$record_run" && "$current_run" != "$record_run" ]]; then
    printf '%s\n' "foreign-run-id"
    return 0
  fi

  current_hash="$(jq -r '.todoHash // empty' <<<"$current_identity")"
  record_hash="$(jq -r '.identity.todoHash // empty' <<<"$record")"
  if [[ -n "$current_hash" && -n "$record_hash" && "$current_hash" != "$record_hash" ]]; then
    printf '%s\n' "mismatched-todo-hash"
    return 0
  fi

  current_todo_id="$(jq -r '.todoId // empty' <<<"$current_identity")"
  record_todo_id="$(jq -r '.identity.todoId // empty' <<<"$record")"
  if [[ -n "$current_todo_id" && -n "$record_todo_id" && "$current_todo_id" != "$record_todo_id" ]]; then
    printf '%s\n' "foreign-todo-id"
    return 0
  fi

  current_line="$(jq -r '.todoLine // empty' <<<"$current_identity")"
  record_line="$(jq -r '.identity.todoLine // empty' <<<"$record")"
  if [[ -n "$current_line" && -n "$record_line" && "$current_line" != "$record_line" ]]; then
    printf '%s\n' "foreign-todo-line"
    return 0
  fi

  current_ordinal="$(jq -r '.todoOrdinal // empty' <<<"$current_identity")"
  record_ordinal="$(jq -r '.identity.todoOrdinal // empty' <<<"$record")"
  if [[ -n "$current_ordinal" && -n "$record_ordinal" && "$current_ordinal" != "$record_ordinal" ]]; then
    printf '%s\n' "foreign-todo-ordinal"
    return 0
  fi

  current_attempt="$(jq -r '.workflowStageAttempt // empty' <<<"$current_identity")"
  record_attempt="$(jq -r '.identity.workflowStageAttempt // empty' <<<"$record")"
  if [[ -n "$current_attempt" && -n "$record_attempt" && "$current_attempt" != "$record_attempt" ]]; then
    printf '%s\n' "mismatched-workflow-attempt"
    return 0
  fi

  printf '%s\n' ""
}

ralph_session_todo_validate_manifest() {
  local record="${1:-}"
  local allow_retired="${2:-0}"
  local reason state

  reason="$(ralph_session_todo_manifest_malformed_reason "$record")"
  if [[ -n "$reason" ]]; then
    printf '%s\n' "Error: TODO session manifest rejected ($reason)" >&2
    return 1
  fi

  state="$(jq -r '.state' <<<"$record")"
  if [[ "$state" == "$RALPH_TODO_SESSION_STATE_RETIRED" && "$allow_retired" != "1" ]]; then
    printf '%s\n' "Error: TODO session manifest is retired" >&2
    return 1
  fi

  reason="$(ralph_session_todo_identity_mismatch_reason "$record")"
  if [[ -n "$reason" ]]; then
    if [[ "$allow_retired" == "1" && "$state" == "$RALPH_TODO_SESSION_STATE_RETIRED" ]]; then
      :
    else
      printf '%s\n' "Error: TODO session manifest rejected ($reason)" >&2
      return 1
    fi
  fi

  jq -c '.' <<<"$record"
}

ralph_session_todo_read_raw() {
  local manifest_key="${1:-}"
  local manifest_path
  manifest_path="$(ralph_session_todo_manifest_path "$manifest_key")" || return 1
  [[ -f "$manifest_path" ]] || {
    printf '%s\n' "Error: TODO session manifest not found: $manifest_key" >&2
    return 1
  }
  jq -c '.' "$manifest_path"
}

ralph_session_todo_read() {
  local manifest_key="${1:-}" allow_retired="${2:-0}" record
  record="$(ralph_session_todo_read_raw "$manifest_key")" || return 1
  ralph_session_todo_validate_manifest "$record" "$allow_retired"
}

ralph_session_todo_select_manifest() {
  local allow_retired="${1:-0}" manifest_key record
  manifest_key="$(ralph_session_todo_manifest_key)" || return 1
  record="$(ralph_session_todo_read "$manifest_key" "$allow_retired")" || return 1
  jq -c '.' <<<"$record"
}

ralph_session_todo_create_manifest_json() {
  local session_id="${1:-}"
  local capture="${2:-}"
  local identity manifest_key runtime now_iso

  identity="$(ralph_session_todo_identity_json)"
  manifest_key="$(ralph_session_todo_manifest_key "$identity")" || return 1
  runtime="$(jq -r '.runtime // empty' <<<"$identity")"
  [[ -n "$runtime" ]] || return 1
  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u)"

  jq -nc \
    --argjson schema_version "$RALPH_TODO_SESSION_SCHEMA_VERSION" \
    --arg manifest_key "$manifest_key" \
    --arg state "$RALPH_TODO_SESSION_STATE_ACTIVE" \
    --arg runtime "$runtime" \
    --arg session_id "$session_id" \
    --arg capture "$capture" \
    --arg created_at "$now_iso" \
    --arg updated_at "$now_iso" \
    --argjson identity "$identity" \
    '{
      schema_version: $schema_version,
      manifest_key: $manifest_key,
      state: $state,
      runtime: $runtime,
      session_id: (if $session_id == "" then null else $session_id end),
      capture: (if $capture == "" then null else $capture end),
      identity: $identity,
      created_at: $created_at,
      updated_at: $updated_at,
      retired_at: null
    }'
}

ralph_session_todo_write_manifest() {
  local manifest_key="${1:-}"
  local record="${2:-}"
  local manifest_path

  ralph_session_todo_require_session_dir || return 1
  manifest_path="$(ralph_session_todo_manifest_path "$manifest_key")" || return 1
  record="$(ralph_session_todo_validate_manifest "$record" 1)" || return 1
  ralph_session_todo_atomic_write_manifest "$manifest_path" "$record"
}

ralph_session_todo_write_manifest_raw() {
  local manifest_key="${1:-}"
  local record="${2:-}"
  local manifest_path reason

  ralph_session_todo_require_session_dir || return 1
  manifest_path="$(ralph_session_todo_manifest_path "$manifest_key")" || return 1
  reason="$(ralph_session_todo_manifest_malformed_reason "$record")"
  if [[ -n "$reason" ]]; then
    printf '%s\n' "Error: TODO session manifest rejected ($reason)" >&2
    return 1
  fi
  ralph_session_todo_atomic_write_manifest "$manifest_path" "$record"
}

ralph_session_todo_create() {
  local session_id="${1:-}"
  local capture="${2:-}"
  local manifest_key manifest_path record

  ralph_session_todo_require_session_dir || return 1
  record="$(ralph_session_todo_create_manifest_json "$session_id" "$capture")" || return 1
  manifest_key="$(jq -r '.manifest_key' <<<"$record")"
  manifest_path="$(ralph_session_todo_manifest_path "$manifest_key")" || return 1
  if [[ -e "$manifest_path" ]]; then
    local existing_state=""
    if existing_state="$(jq -r '.state // empty' "$manifest_path" 2>/dev/null)"; then
      if [[ "$existing_state" == "$RALPH_TODO_SESSION_STATE_RETIRED" ]]; then
        rm -f "$manifest_path"
      else
        printf '%s\n' "Error: TODO session manifest already exists: $manifest_key" >&2
        return 1
      fi
    else
      printf '%s\n' "Error: TODO session manifest already exists: $manifest_key" >&2
      return 1
    fi
  fi
  ralph_session_todo_atomic_write_manifest "$manifest_path" "$record" || return 1
  jq -c '.' <<<"$record"
}

ralph_session_todo_update_state() {
  local manifest_key="${1:-}"
  local new_state="${2:-}"
  local session_id="${3:-}"
  local capture="${4:-}"
  local record state now_iso updated

  ralph_session_todo_valid_state "$new_state" || return 1
  record="$(ralph_session_todo_read "$manifest_key" 1)" || return 1
  state="$(jq -r '.state' <<<"$record")"
  case "$state" in
    "$RALPH_TODO_SESSION_STATE_ACTIVE")
      [[ "$new_state" == "$RALPH_TODO_SESSION_STATE_TERMINAL" || "$new_state" == "$RALPH_TODO_SESSION_STATE_RETIRED" ]] || {
        printf '%s\n' "Error: invalid TODO session manifest state transition ($state -> $new_state)" >&2
        return 1
      }
      ;;
    "$RALPH_TODO_SESSION_STATE_TERMINAL")
      [[ "$new_state" == "$RALPH_TODO_SESSION_STATE_RETIRED" ]] || {
        printf '%s\n' "Error: invalid TODO session manifest state transition ($state -> $new_state)" >&2
        return 1
      }
      ;;
    *)
      printf '%s\n' "Error: TODO session manifest state is not updatable ($state)" >&2
      return 1
      ;;
  esac

  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u)"
  updated="$(jq -c \
    --arg state "$new_state" \
    --arg updated_at "$now_iso" \
    --arg session_id "$session_id" \
    --arg capture "$capture" \
    --arg retired_at "$now_iso" \
    '.state = $state
     | .updated_at = $updated_at
     | .session_id = (if $session_id == "" then .session_id else $session_id end)
     | .capture = (if $capture == "" then .capture else $capture end)
     | .retired_at = (if $state == "retired" then $retired_at else .retired_at end)' <<<"$record")"
  ralph_session_todo_write_manifest "$manifest_key" "$updated" || return 1
  ralph_session_todo_read "$manifest_key" 1
}

ralph_session_todo_mark_terminal() {
  local manifest_key="${1:-}"
  local session_id="${2:-}"
  local capture="${3:-}"
  ralph_session_todo_update_state "$manifest_key" "$RALPH_TODO_SESSION_STATE_TERMINAL" "$session_id" "$capture"
}

ralph_session_todo_mark_retired() {
  local manifest_key="${1:-}"
  ralph_session_todo_update_state "$manifest_key" "$RALPH_TODO_SESSION_STATE_RETIRED" "" ""
}

# Derive RALPH_PLAN_CLI_RESUME from supervisor-owned invocation reason and session strategy.
ralph_session_derive_cli_resume() {
  local reason="${RALPH_PLAN_INVOCATION_REASON:-$RALPH_TODO_INVOCATION_REASON_START}"
  local strategy="${RALPH_PLAN_SESSION_STRATEGY:-fresh}"

  case "$reason" in
    "$RALPH_TODO_INVOCATION_REASON_CONTINUE")
      RALPH_PLAN_CLI_RESUME=1
      ;;
    "$RALPH_TODO_INVOCATION_REASON_START")
      case "$strategy" in
        resume|reset|compact) RALPH_PLAN_CLI_RESUME=1 ;;
        *) RALPH_PLAN_CLI_RESUME=0 ;;
      esac
      ;;
    *)
      RALPH_PLAN_CLI_RESUME=0
      ;;
  esac
  export RALPH_PLAN_CLI_RESUME
}

ralph_session_todo_read_effective_session_id() {
  local from_file=""
  if [[ -n "${SESSION_ID_FILE:-}" && -s "$SESSION_ID_FILE" ]]; then
    if read -r from_file < "$SESSION_ID_FILE"; then
      from_file="${from_file//$'\r'/}"
      from_file="${from_file//$'\n'/}"
      from_file="${from_file#"${from_file%%[![:space:]]*}"}"
      from_file="${from_file%"${from_file##*[![:space:]]}"}"
    fi
  fi
  printf '%s\n' "$from_file"
}

ralph_session_todo_export_paths() {
  local manifest_key=""
  unset RALPH_TODO_SESSION_MANIFEST_KEY RALPH_TODO_SESSION_MANIFEST_PATH RALPH_TODO_SESSION_MANIFEST_DIR
  if ! manifest_key="$(ralph_session_todo_manifest_key 2>/dev/null)"; then
    export RALPH_TODO_SESSION_MANIFEST_KEY=""
    export RALPH_TODO_SESSION_MANIFEST_PATH=""
    export RALPH_TODO_SESSION_MANIFEST_DIR=""
    return 0
  fi
  RALPH_TODO_SESSION_MANIFEST_KEY="$manifest_key"
  RALPH_TODO_SESSION_MANIFEST_DIR="$(ralph_session_todo_manifest_dir 2>/dev/null || true)"
  RALPH_TODO_SESSION_MANIFEST_PATH="$(ralph_session_todo_manifest_path "$manifest_key" 2>/dev/null || true)"
  export RALPH_TODO_SESSION_MANIFEST_KEY
  export RALPH_TODO_SESSION_MANIFEST_DIR
  export RALPH_TODO_SESSION_MANIFEST_PATH
}

ralph_session_todo_reconcile_stale_manifest() {
  local manifest_key manifest_path record state
  manifest_key="$(ralph_session_todo_manifest_key 2>/dev/null)" || return 0
  manifest_path="$(ralph_session_todo_manifest_path "$manifest_key" 2>/dev/null)" || return 0
  [[ -f "$manifest_path" ]] || return 0
  if ralph_session_todo_select_manifest >/dev/null 2>&1; then
    return 0
  fi
  record="$(ralph_session_todo_read_raw "$manifest_key" 2>/dev/null)" || return 0
  state="$(jq -r '.state' <<<"$record")"
  [[ "$state" == "$RALPH_TODO_SESSION_STATE_RETIRED" ]] && return 0
  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u)"
  record="$(jq -c \
    --arg state "$RALPH_TODO_SESSION_STATE_RETIRED" \
    --arg updated_at "$now_iso" \
    --arg retired_at "$now_iso" \
    '.state = $state | .updated_at = $updated_at | .retired_at = $retired_at' <<<"$record")"
  ralph_session_todo_write_manifest_raw "$manifest_key" "$record" >/dev/null 2>&1 || true
}

# Reactivate a terminal/retired manifest for post-verification repair continuation.
# Args: optional continuation record JSON (uses embedded session when present).
ralph_session_todo_reactivate_for_repair() {
  local continuation_record="${1:-}"
  local manifest_key record state session_id capture now_iso updated

  manifest_key="$(ralph_session_todo_manifest_key 2>/dev/null)" || return 1
  record="$(ralph_session_todo_read_raw "$manifest_key" 2>/dev/null)" || return 1
  state="$(jq -r '.state' <<<"$record")"
  case "$state" in
    "$RALPH_TODO_SESSION_STATE_ACTIVE")
      return 0
      ;;
    "$RALPH_TODO_SESSION_STATE_TERMINAL" | "$RALPH_TODO_SESSION_STATE_RETIRED")
      ;;
    *)
      return 1
      ;;
  esac

  session_id="$(jq -r '.session_id // empty' <<<"$record")"
  capture="$(jq -r '.capture // empty' <<<"$record")"
  if [[ -n "$continuation_record" ]]; then
    if [[ -z "$session_id" ]]; then
      session_id="$(jq -r '.session.session_id // empty' <<<"$continuation_record")"
    fi
    if [[ -z "$capture" ]]; then
      capture="$(jq -r '.session.capture // empty' <<<"$continuation_record")"
    fi
  fi
  [[ -n "$capture" ]] || capture="${RALPH_TODO_SESSION_CAPTURE_DEGRADED:-degraded}"

  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u)"
  updated="$(jq -c \
    --arg state "$RALPH_TODO_SESSION_STATE_ACTIVE" \
    --arg updated_at "$now_iso" \
    --arg session_id "$session_id" \
    --arg capture "$capture" \
    '.state = $state
     | .updated_at = $updated_at
     | .retired_at = null
     | .session_id = (if $session_id == "" then null else $session_id end)
     | .capture = $capture' <<<"$record")"
  ralph_session_todo_write_manifest_raw "$manifest_key" "$updated" >/dev/null 2>&1 || return 1
  return 0
}

ralph_session_todo_resolve_invocation_reason() {
  local record state session_id
  if record="$(ralph_session_todo_select_manifest 2>/dev/null)"; then
    state="$(jq -r '.state' <<<"$record")"
    session_id="$(jq -r '.session_id // empty' <<<"$record")"
    if [[ "$state" == "$RALPH_TODO_SESSION_STATE_ACTIVE" && -n "$session_id" ]]; then
      printf '%s\n' "$RALPH_TODO_INVOCATION_REASON_CONTINUE"
      return 0
    fi
  fi
  printf '%s\n' "$RALPH_TODO_INVOCATION_REASON_START"
}

ralph_session_todo_update_capture() {
  local manifest_key="${1:-}"
  local session_id="${2:-}"
  local capture="${3:-}"
  local record now_iso updated

  [[ -n "$manifest_key" && -n "$capture" ]] || return 1
  record="$(ralph_session_todo_read "$manifest_key" 1)" || return 1
  [[ "$(jq -r '.state' <<<"$record")" == "$RALPH_TODO_SESSION_STATE_ACTIVE" ]] || return 1
  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u)"
  updated="$(jq -c \
    --arg updated_at "$now_iso" \
    --arg session_id "$session_id" \
    --arg capture "$capture" \
    '.updated_at = $updated_at
     | .session_id = (if $session_id == "" then null else $session_id end)
     | .capture = $capture' <<<"$record")"
  ralph_session_todo_write_manifest "$manifest_key" "$updated" || return 1
  jq -c '.' <<<"$updated"
}

ralph_session_todo_prepare_invocation() {
  local reason record session_id manifest_key manifest_path

  ralph_session_todo_reconcile_stale_manifest
  ralph_session_apply_resume_strategy

  reason="$(ralph_session_todo_resolve_invocation_reason)"
  if declare -F ralph_human_continuation_try_apply >/dev/null 2>&1 \
    && ralph_human_continuation_try_apply; then
    reason="${RALPH_TODO_INVOCATION_REASON_CONTINUE:-todo-continue}"
  elif declare -F ralph_post_verify_repair_try_apply >/dev/null 2>&1 \
    && ralph_post_verify_repair_try_apply; then
    reason="${RALPH_TODO_INVOCATION_REASON_CONTINUE:-todo-continue}"
  elif declare -F workflow_action_continuation_try_apply >/dev/null 2>&1 \
    && workflow_action_continuation_try_apply; then
    reason="${RALPH_TODO_INVOCATION_REASON_CONTINUE:-todo-continue}"
  fi
  RALPH_PLAN_INVOCATION_REASON="$reason"
  export RALPH_PLAN_INVOCATION_REASON
  ralph_session_todo_export_paths

  if [[ "$reason" == "$RALPH_TODO_INVOCATION_REASON_CONTINUE" ]]; then
    record="$(ralph_session_todo_select_manifest)" || return 1
    session_id="$(jq -r '.session_id // empty' <<<"$record")"
    manifest_key="$(jq -r '.manifest_key // empty' <<<"$record")"
    if [[ -n "$session_id" ]]; then
      unset RALPH_RUN_PLAN_NEW_SESSION_ID
      unset RALPH_RUN_PLAN_RESUME_BARE
      export RALPH_RUN_PLAN_RESUME_SESSION_ID="$session_id"
      if declare -F ralph_run_plan_log >/dev/null 2>&1; then
        ralph_run_plan_log "todo session $reason: using exact TODO-bound session id from manifest (${manifest_key:-unknown})"
      fi
    fi
  fi

  ralph_session_derive_cli_resume
  return 0
}

ralph_session_todo_capture_after_invocation() {
  local session_id capture manifest_key manifest_path record state

  ralph_session_todo_require_session_dir || return 0
  [[ -n "${RALPH_CURRENT_TODO_LINE:-}" ]] || return 0

  session_id="$(ralph_session_todo_read_effective_session_id)"
  if [[ -n "$session_id" ]]; then
    capture="$RALPH_TODO_SESSION_CAPTURE_EXACT"
  else
    capture="$RALPH_TODO_SESSION_CAPTURE_DEGRADED"
  fi

  manifest_key="$(ralph_session_todo_manifest_key 2>/dev/null)" || return 0
  manifest_path="$(ralph_session_todo_manifest_path "$manifest_key" 2>/dev/null)" || return 0

  if [[ -f "$manifest_path" ]]; then
    if record="$(ralph_session_todo_read "$manifest_key" 1 2>/dev/null)"; then
      state="$(jq -r '.state' <<<"$record")"
      if [[ "$state" == "$RALPH_TODO_SESSION_STATE_ACTIVE" ]]; then
        ralph_session_todo_update_capture "$manifest_key" "$session_id" "$capture" >/dev/null 2>&1 || true
        return 0
      fi
    fi
  fi

  if ralph_session_todo_create "$session_id" "$capture" >/dev/null 2>&1; then
    return 0
  fi

  ralph_session_todo_update_capture "$manifest_key" "$session_id" "$capture" >/dev/null 2>&1 || true
}

# shellcheck source=run-plan-human-continuation.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-plan-human-continuation.sh"

ralph_session_todo_retire_at_boundary() {
  local manifest_key record state session_id capture

  manifest_key="$(ralph_session_todo_manifest_key 2>/dev/null)" || return 0
  record="$(ralph_session_todo_read "$manifest_key" 1 2>/dev/null)" || return 0
  state="$(jq -r '.state' <<<"$record")"
  session_id="$(ralph_session_todo_read_effective_session_id)"
  capture="$(jq -r '.capture // empty' <<<"$record")"
  [[ -n "$capture" ]] || capture="$RALPH_TODO_SESSION_CAPTURE_DEGRADED"

  case "$state" in
    "$RALPH_TODO_SESSION_STATE_ACTIVE")
      ralph_session_todo_mark_terminal "$manifest_key" "$session_id" "$capture" >/dev/null 2>&1 || true
      ralph_session_todo_mark_retired "$manifest_key" >/dev/null 2>&1 || true
      ;;
    "$RALPH_TODO_SESSION_STATE_TERMINAL")
      ralph_session_todo_mark_retired "$manifest_key" >/dev/null 2>&1 || true
      ;;
  esac
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

  # Keep '-' at the end of the character class so grep does not treat it as a range.
  if printf '%s\n' "$_recent" | grep -Eiq \
    'session[^[:alnum:]]*(not[[:space:]_-]*found|does[[:space:]_-]*not[[:space:]_-]*exist|missing|invalid)|unknown[[:space:]_-]*session|no[[:space:]_-]*such[[:space:]_-]*session|chat[^[:alnum:]]*not[[:space:]_-]*found|thread[^[:alnum:]]*not[[:space:]_-]*found'; then
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
  if [[ -f "${PENDING_HUMAN:-}" ]] || [[ -f "${PENDING_ABS:-}" && -s "${PENDING_ABS:-}" ]]; then
    if declare -F ralph_run_plan_log >/dev/null 2>&1; then
      ralph_run_plan_log "session rotation deferred at persisted wait boundary"
    fi
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
