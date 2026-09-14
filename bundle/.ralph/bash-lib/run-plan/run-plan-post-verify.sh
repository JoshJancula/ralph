# shellcheck shell=bash
## Post-TODO verification runner: executes verification after a TODO is marked complete.
## Source from run-plan-core.sh.
## Do not execute directly.

_ralph_completion_sentinel_seen_in_text() {
  local text="$1"
  local script="${SCRIPT_DIR:-}/python/completion_sentinel.py"
  if [[ ! -f "$script" ]] || ! command -v python3 &>/dev/null; then
    grep -Fxq "AGENT_INVOCATION_COMPLETE" <<<"$text"
    return $?
  fi
  PYTHONPATH="${SCRIPT_DIR}/python${PYTHONPATH:+:$PYTHONPATH}" \
    python3 "$script" text <<<"$text" | grep -q '^1$'
}

# Prints the agent's final self-reported verification verdict: "pass", "fail",
# "skip", or "none". Used when no runnable command can be machine-extracted
# from a TODO's verification field and the runner asks the agent to verify and
# report.
_ralph_verification_result_in_text() {
  local text="$1"
  local script="${SCRIPT_DIR:-}/python/verification_result.py"
  if [[ ! -f "$script" ]] || ! command -v python3 &>/dev/null; then
    # Portable fallback (no GNU-only \b): take the last verification verdict
    # line and extract its PASS/FAIL verdict via sed -E (works on BSD and GNU).
    local _last _verdict
    _last="$(printf '%s\n' "$text" | grep -iE 'VERIFICATION(_RESULT| STATUS)[[:space:]]*:[[:space:]]*(PASS|FAIL)' | tail -n 1)"
    _verdict="$(printf '%s\n' "$_last" | sed -nE 's/.*VERIFICATION(_RESULT| STATUS)[[:space:]]*:[[:space:]]*([Pp][Aa][Ss][Ss]|[Ff][Aa][Ii][Ll]).*/\2/p' | tr '[:upper:]' '[:lower:]')"
    case "$_verdict" in
      pass) printf 'pass\n' ;;
      fail) printf 'fail\n' ;;
      *) printf 'none\n' ;;
    esac
    return 0
  fi
  PYTHONPATH="${SCRIPT_DIR}/python${PYTHONPATH:+:$PYTHONPATH}" \
    python3 "$script" text <<<"$text" | head -n 1
}

_ralph_verification_reason_in_text() {
  local text="$1"
  local script="${SCRIPT_DIR:-}/python/verification_result.py"
  if [[ ! -f "$script" ]] || ! command -v python3 &>/dev/null; then
    local _last
    _last="$(printf '%s\n' "$text" | grep -iE 'VERIFICATION(_RESULT| STATUS)[[:space:]]*:[[:space:]]*FAIL' | tail -n 1)"
    printf '%s\n' "$_last" | sed -nE 's/.*VERIFICATION(_RESULT| STATUS)[[:space:]]*:[[:space:]]*[Ff][Aa][Ii][Ll][[:space:]]*:?[[:space:]]*(.*)$/\2/p'
    return 0
  fi
  PYTHONPATH="${SCRIPT_DIR}/python${PYTHONPATH:+:$PYTHONPATH}" \
    python3 "$script" text <<<"$text" | sed -n '2p'
}

# Resolve the verification timeout in seconds. Falls back to 300 when unset or
# not a positive integer.
_ralph_verify_timeout_secs() {
  local t="${RALPH_VERIFY_TIMEOUT:-300}"
  case "$t" in
    ''|*[!0-9]*) t=300 ;;
  esac
  [[ "$t" -gt 0 ]] 2>/dev/null || t=300
  printf '%s' "$t"
}

# Homegrown timeout watchdog for environments without coreutils `timeout`.
# Runs the command in the background, waits up to <secs>, and kills it if it
# overruns. Sets RALPH_VERIFY_EXEC_OUTPUT / RALPH_VERIFY_EXEC_EXIT /
# RALPH_VERIFY_EXEC_TIMED_OUT.
_ralph_exec_verification_watchdog() {
  local workspace="$1" cmd="$2" secs="$3"
  local tmp
  tmp="$(mktemp 2>/dev/null || printf '/tmp/ralph-verify-%s.out' "$$")"
  RALPH_VERIFY_EXEC_TIMED_OUT=0

  if declare -F ralph_process_scope_exec >/dev/null 2>&1 && [[ -n "${RALPH_PROCESS_RUN_DIR:-}" ]]; then
    ralph_process_scope_exec verify shell bash -c \
      'cd "$1" && exec env -i HOME="$HOME" PATH="$PATH" RALPH_PROCESS_SCOPE_TOKEN="$RALPH_PROCESS_SCOPE_TOKEN" bash -c "$2"' \
      _ "$workspace" "$cmd" </dev/null >"$tmp" 2>&1 &
  else
    ( cd "$workspace" && env -i HOME="$HOME" PATH="$PATH" bash -c "$cmd" </dev/null >"$tmp" 2>&1 ) &
  fi
  local cmd_pid=$!

  local waited=0
  while kill -0 "$cmd_pid" 2>/dev/null; do
    if [[ "$waited" -ge "$secs" ]]; then
      RALPH_VERIFY_EXEC_TIMED_OUT=1
      kill -TERM "$cmd_pid" 2>/dev/null || true
      ralph_wait 1
      kill -KILL "$cmd_pid" 2>/dev/null || true
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done

  local exit_code=0
  if [[ "$RALPH_VERIFY_EXEC_TIMED_OUT" == "1" ]]; then
    wait "$cmd_pid" 2>/dev/null || true
    exit_code=124
  else
    set +e
    wait "$cmd_pid"
    exit_code=$?
    set -e
  fi

  RALPH_VERIFY_EXEC_OUTPUT="$(cat "$tmp" 2>/dev/null || printf '')"
  RALPH_VERIFY_EXEC_EXIT="$exit_code"
  rm -f "$tmp" 2>/dev/null || true
}

# Execute a verification command bounded by a timeout and isolated from stdin so
# an interactive or hanging command (for example one that prompts on /dev/tty)
# can never freeze the runner. Prints a terminal-visible status line to stderr
# before running so the user is never left guessing during a long check.
# Args: <workspace> <command> <todo_line>
# Sets: RALPH_VERIFY_EXEC_OUTPUT, RALPH_VERIFY_EXEC_EXIT, RALPH_VERIFY_EXEC_TIMED_OUT
_ralph_exec_verification_command() {
  local workspace="$1" cmd="$2" todo_line="${3:-}"
  local secs
  secs="$(_ralph_verify_timeout_secs)"
  RALPH_VERIFY_EXEC_TIMED_OUT=0

  echo -e "${C_DIM:-}Running verification checks now (line ${todo_line}; timeout ${secs}s): ${cmd}${C_RST:-}" >&2

  local timeout_bin=""
  if command -v timeout >/dev/null 2>&1; then
    timeout_bin="timeout"
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_bin="gtimeout"
  fi

  if [[ -n "$timeout_bin" ]]; then
    local out exit_code
    set +e
    if declare -F ralph_process_scope_exec >/dev/null 2>&1 && [[ -n "${RALPH_PROCESS_RUN_DIR:-}" ]]; then
      out="$(ralph_process_scope_exec verify shell bash -c \
        'cd "$1" && exec env -i HOME="$HOME" PATH="$PATH" RALPH_PROCESS_SCOPE_TOKEN="$RALPH_PROCESS_SCOPE_TOKEN" "$2" "$3" bash -c "$4"' \
        _ "$workspace" "$timeout_bin" "$secs" "$cmd" </dev/null 2>&1)"
    else
      out="$(cd "$workspace" && env -i HOME="$HOME" PATH="$PATH" "$timeout_bin" "$secs" bash -c "$cmd" </dev/null 2>&1)"
    fi
    exit_code=$?
    set -e
    RALPH_VERIFY_EXEC_OUTPUT="$out"
    RALPH_VERIFY_EXEC_EXIT="$exit_code"
    if [[ "$exit_code" -eq 124 ]]; then
      RALPH_VERIFY_EXEC_TIMED_OUT=1
    fi
  else
    _ralph_exec_verification_watchdog "$workspace" "$cmd" "$secs"
  fi
}

_ralph_should_verify_to_complete() {
  local todo_text="$1"

  if [[ "${RALPH_PLAN_VERIFY_TO_COMPLETE:-1}" == "0" ]]; then
    return 1
  fi

  local _verify_command=""
  _verify_command="$(ralph_plan_verify_to_complete_command "$todo_text" 2>/dev/null || true)"
  [[ -n "$_verify_command" ]]
}

# Note: the former `_ralph_run_verify_to_complete` (a pre-mark verification gate
# used only when the agent emitted no completion sentinel) has been removed. The
# runner now marks first and runs the single unified verification gate
# (`_ralph_run_post_verification`) for every completed TODO, so behavior is
# identical regardless of whether the sentinel was emitted.
# `_ralph_should_verify_to_complete` is retained: it tells the runner that a
# runnable verification command exists and can act as the completion signal for
# sentinel-less runtimes.

_ralph_should_run_post_verification() {
  local todo_text="$1"
  local plan_verify_command="${2:-}"

  if [[ "${RALPH_POST_VERIFY:-1}" == "0" ]]; then
    return 1
  fi

  if [[ -n "${RALPH_VERIFY_AFTER_TODO:-}" ]]; then
    return 0
  fi

  if [[ -n "$plan_verify_command" ]]; then
    return 0
  fi

  local _todo_cmd=""
  _todo_cmd="$(ralph_plan_post_verification_command "$todo_text" 2>/dev/null || true)"
  if [[ -n "$_todo_cmd" ]]; then
    return 0
  fi

  if [[ "${RALPH_PLAN_VERIFY_AFTER_TODO:-0}" == "1" ]]; then
    return 0
  fi

  return 1
}

_ralph_todo_declares_verification_metadata() {
  local todo_text="$1"
  grep -qiE '(^|[[:space:]])(verification|verify)[[:space:]]*:' <<<"$todo_text"
}

_ralph_todo_declares_strict_verify() {
  local todo_text="$1"
  grep -qiE '(^|[[:space:]])verify[[:space:]]*:' <<<"$todo_text"
}

_ralph_run_post_verification() {
  local todo_text="$1"
  local todo_line="$2"
  local workspace="$3"
  local plan_key="${4:-}"
  local artifact_ns="${5:-}"
  local verification_tracking_file="${6:-}"
  local plan_verify_command="${7:-}"

  local _verify_command=""
  local _verify_env="${RALPH_VERIFY_AFTER_TODO:-}"

  POST_VERIFICATION_FAILURE_SUMMARY=""
  POST_VERIFICATION_FAILURE_ARTIFACT=""
  POST_VERIFICATION_FAILURE_COMMAND=""

  if [[ -n "$_verify_env" ]]; then
    _verify_command="$_verify_env"
    POST_VERIFICATION_FAILURE_COMMAND="$_verify_env"
  else
    _verify_command="$(ralph_plan_post_verification_command "$todo_text" 2>/dev/null || true)"
    if [[ -z "$_verify_command" && -n "$plan_verify_command" ]]; then
      _verify_command="$plan_verify_command"
      POST_VERIFICATION_FAILURE_COMMAND="$plan_verify_command"
    else
      POST_VERIFICATION_FAILURE_COMMAND="$_verify_command"
    fi
  fi

  if [[ -z "$_verify_command" ]]; then
    printf '%s\n%s\n%s\n' "missing" "" ""
    return 0
  fi

  # Defense in depth: never run a string that is not valid shell as a command.
  # Natural-language prose (for example with parentheses) would otherwise raise a
  # bash syntax error and be misread as a verification failure, unmarking a
  # completed TODO. Route these to the agent-verification path instead.
  if ! bash -n -c "$_verify_command" 2>/dev/null; then
    ralph_run_plan_log "post-verification command not runnable for line=$todo_line; routing to agent verification"
    printf '%s\n%s\n%s\n' "invalid" "strict_verify_command_invalid: declared verify command is not a valid shell command" ""
    return 0
  fi

  ralph_run_plan_log "post-verification (runner-owned) scheduled for line=$todo_line command=$_verify_command"

  if declare -F ralph_claude_speculative_cache_warm_maybe_start >/dev/null 2>&1; then
    ralph_claude_speculative_cache_warm_maybe_start "$todo_line"
  fi

  local _inv_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local _start_time="$(date +%s)"

  {
    echo ""
    echo "================================================================================"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Post-verification (runner-owned) for TODO (line $todo_line)"
    echo "Command: $_verify_command"
    echo "================================================================================"
    echo ""
  } >> "$OUTPUT_LOG"

  local _artifact_file=""
  local _verify_output=""
  local _verify_exit=0

  _ralph_exec_verification_command "$workspace" "$_verify_command" "$todo_line"
  _verify_output="$RALPH_VERIFY_EXEC_OUTPUT"
  _verify_exit="$RALPH_VERIFY_EXEC_EXIT"
  local _verify_timed_out="${RALPH_VERIFY_EXEC_TIMED_OUT:-0}"

  local _inv_ended_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local _inv_elapsed=$(( $(date +%s) - _start_time ))

  local _verify_status=""
  local _verification_bytes_suppressed=${#_verify_output}

  if [[ "$_verify_exit" -eq 0 ]]; then
    _verify_status="passed"
    ralph_run_plan_log "post-verification (runner-owned) passed line=$todo_line elapsed=${_inv_elapsed}s"
    echo -e "${C_DIM:-}Verification passed (line ${todo_line})${C_RST:-}" >&2
    {
      echo "Post-verification result: PASSED"
      echo ""
    } >> "$OUTPUT_LOG"
  else
    _verify_status="failed"
    if [[ "$_verify_timed_out" == "1" ]]; then
      local _timeout_secs
      _timeout_secs="$(_ralph_verify_timeout_secs)"
      _verify_output="verification command timed out after ${_timeout_secs}s"$'\n'"$_verify_output"
      _verification_bytes_suppressed=${#_verify_output}
      ralph_run_plan_log "post-verification (runner-owned) timed out line=$todo_line after=${_timeout_secs}s elapsed=${_inv_elapsed}s"
      echo -e "${C_Y:-}Verification timed out (line ${todo_line}) after ${_timeout_secs}s${C_RST:-}" >&2
    else
      ralph_run_plan_log "post-verification (runner-owned) failed line=$todo_line exit=$_verify_exit elapsed=${_inv_elapsed}s"
      echo -e "${C_Y:-}Verification failed (line ${todo_line}); reopening TODO${C_RST:-}" >&2
    fi

    local _artifact_dir=""
    local _verification_state_root="${RALPH_PLAN_WORKSPACE_ROOT:-$workspace/.ralph-workspace}"
    if [[ -n "$plan_key" ]]; then
      _artifact_dir="$_verification_state_root/artifacts/$plan_key/verification"
    elif [[ -n "$artifact_ns" ]]; then
      _artifact_dir="$_verification_state_root/artifacts/$artifact_ns/verification"
    else
      _artifact_dir="$_verification_state_root/artifacts/verification"
    fi

    mkdir -p "$_artifact_dir"
    _artifact_file="$_artifact_dir/line-${todo_line}-$(date +%s).txt"

    printf '%s\n' "$_verify_output" > "$_artifact_file"

    {
      echo "Post-verification result: FAILED (exit=$_verify_exit)"
      echo "Compact artifact stored: $(basename "$_artifact_file")"
      echo ""
    } >> "$OUTPUT_LOG"

    ralph_run_plan_log "post-verification (runner-owned) compact artifact stored at $(basename "$_artifact_file")"
  fi

  local _failure_summary=""
  local _failure_artifact_path=""
  if [[ "$_verify_status" == "failed" ]]; then
    local _summary="$(_ralph_extract_verification_summary "$_verify_output")"
    _failure_summary="${_summary:-$todo_text}"
    _failure_summary="${_failure_summary//$'\n'/ }"
    _failure_summary="${_failure_summary//  / }"
    if [[ -n "$_artifact_file" ]]; then
      if [[ "$_artifact_file" == "$workspace"* ]]; then
        _failure_artifact_path=".${_artifact_file#$workspace}"
      else
        _failure_artifact_path="$_artifact_file"
      fi
    fi
  fi

  if [[ -n "$verification_tracking_file" ]]; then
    printf '%s\n' "line=$todo_line status=$_verify_status bytes_suppressed=$_verification_bytes_suppressed elapsed=$_inv_elapsed" >> "$verification_tracking_file"
  fi

  if declare -F ralph_claude_speculative_cache_warm_finalize >/dev/null 2>&1; then
    ralph_claude_speculative_cache_warm_finalize
  fi

  printf '%s\n%s\n%s\n' "$_verify_status" "$_failure_summary" "$_failure_artifact_path"
}

_ralph_extract_verification_summary() {
  local output="$1"
  local max_lines=3
  local summary
  # Ensure we have at least some output
  if [[ -z "${output// /}" ]]; then
    summary=""
  else
    summary="$(printf '%s\n' "$output" | head -n "$max_lines" | sed 's/^/  /')"
  fi
  printf '%s' "$summary"
}

# ---------------------------------------------------------------------------
# Tier-2 post-verification repair continuation records (consume-once).
#
# Runner-owned post-verification runs after the invocation ends. Persist a
# bounded continuation record under $RALPH_SESSION_DIR/continuations/ and resolve
# todo-continue on the next invocation via the per-TODO session manifest,
# regardless of cross-TODO session strategy.
# ---------------------------------------------------------------------------

if [[ -z "${RALPH_POST_VERIFY_REPAIR_LOADED:-}" ]]; then
RALPH_POST_VERIFY_REPAIR_LOADED=1

ralph_post_verify_repair_require_session_dir() {
  [[ -n "${RALPH_SESSION_DIR:-}" ]] || {
    printf '%s\n' "Error: RALPH_SESSION_DIR is required for post-verification repair continuation" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || {
    printf '%s\n' "Error: jq is required for post-verification repair continuation" >&2
    return 1
  }
}

ralph_post_verify_repair_root() {
  ralph_post_verify_repair_require_session_dir || return 1
  printf '%s/continuations\n' "$RALPH_SESSION_DIR"
}

ralph_post_verify_repair_record_path() {
  local request_id="${1:-}"
  local root
  [[ -n "$request_id" && "$request_id" != *"/"* && "$request_id" != *".."* ]] || return 1
  root="$(ralph_post_verify_repair_root)" || return 1
  printf '%s/%s.json\n' "$root" "$request_id"
}

ralph_post_verify_repair_consumed_marker_path() {
  local request_id="${1:-}" record_path
  record_path="$(ralph_post_verify_repair_record_path "$request_id")" || return 1
  printf '%s.consumed\n' "$record_path"
}

ralph_post_verify_repair_request_id_for_attempt() {
  local attempt_key="${1:-}"
  local hash=""
  [[ -n "$attempt_key" ]] || return 1
  if command -v shasum >/dev/null 2>&1; then
    hash="$(printf '%s' "$attempt_key" | shasum -a 256 | awk '{print $1}' | head -c 16)"
  elif command -v sha256sum >/dev/null 2>&1; then
    hash="$(printf '%s' "$attempt_key" | sha256sum | awk '{print $1}' | head -c 16)"
  else
    hash="$(printf '%s' "$attempt_key" | tr -c '[:alnum:]' '-' | head -c 16)"
  fi
  printf 'post-verification-repair-%s\n' "$hash"
}

ralph_post_verify_repair_capture_session_context() {
  local manifest_key record session_id capture
  session_id=""
  capture="${RALPH_TODO_SESSION_CAPTURE_DEGRADED:-degraded}"
  if declare -F ralph_session_todo_manifest_key >/dev/null 2>&1 \
    && manifest_key="$(ralph_session_todo_manifest_key 2>/dev/null)"; then
    if record="$(ralph_session_todo_read_raw "$manifest_key" 2>/dev/null)"; then
      session_id="$(jq -r '.session_id // empty' <<<"$record")"
      capture="$(jq -r '.capture // empty' <<<"$record")"
      [[ -n "$capture" ]] || capture="${RALPH_TODO_SESSION_CAPTURE_DEGRADED:-degraded}"
    fi
  fi
  jq -nc \
    --arg session_id "$session_id" \
    --arg capture "$capture" \
    '{session_id: (if $session_id == "" then null else $session_id end), capture: $capture}'
}

ralph_post_verify_repair_persist() {
  local failure_reason="${1:-strict_verify_command_failed}"
  local failure_summary="${2:-}"
  local failure_artifact="${3:-}"
  local failure_command="${4:-}"
  local todo_line="${5:-}"
  local identity attempt_key request_id path marker now_iso record session_ctx

  ralph_post_verify_repair_require_session_dir || return 1
  declare -F ralph_session_todo_identity_json >/dev/null 2>&1 || return 1
  declare -F ralph_session_todo_attempt_key >/dev/null 2>&1 || return 1
  identity="$(ralph_session_todo_identity_json)" || return 1
  attempt_key="$(ralph_session_todo_attempt_key "$identity")"
  request_id="$(ralph_post_verify_repair_request_id_for_attempt "$attempt_key")" || return 1
  path="$(ralph_post_verify_repair_record_path "$request_id")" || return 1
  marker="$(ralph_post_verify_repair_consumed_marker_path "$request_id")" || return 1
  [[ ! -f "$path" ]] || return 1
  [[ ! -f "$marker" ]] || return 1

  session_ctx="$(ralph_post_verify_repair_capture_session_context)"
  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u)"
  record="$(jq -nc \
    --argjson schema_version 1 \
    --arg kind "post-verification-repair" \
    --arg request_id "$request_id" \
    --arg tier "invocation" \
    --arg reason "post-verification-repair" \
    --arg failure_reason "$failure_reason" \
    --arg failure_summary "$failure_summary" \
    --arg failure_artifact "$failure_artifact" \
    --arg failure_command "$failure_command" \
    --arg todo_line "$todo_line" \
    --arg attempt_key "$attempt_key" \
    --argjson identity "$identity" \
    --argjson session "$session_ctx" \
    --arg created_at "$now_iso" \
    '{
      schema_version: $schema_version,
      kind: $kind,
      request_id: $request_id,
      tier: $tier,
      reason: $reason,
      failure_reason: $failure_reason,
      failure_summary: $failure_summary,
      failure_artifact: (if $failure_artifact == "" then null else $failure_artifact end),
      failure_command: (if $failure_command == "" then null else $failure_command end),
      todo_line: (if $todo_line == "" then null else $todo_line end),
      attempt_key: $attempt_key,
      identity: $identity,
      session: $session,
      consumed: false,
      created_at: $created_at,
      consumed_at: null
    }')"

  mkdir -p "$(dirname "$path")"
  umask 077
  printf '%s\n' "$record" >"${path}.tmp" && mv -f "${path}.tmp" "$path"
  chmod 600 "$path" 2>/dev/null || true
  jq -c '.' <<<"$record"
}

ralph_post_verify_repair_find_pending() {
  local root attempt_key current_key record_path record consumed marker
  ralph_post_verify_repair_require_session_dir || return 1
  declare -F ralph_session_todo_attempt_key >/dev/null 2>&1 || return 1
  root="$(ralph_post_verify_repair_root)" || return 1
  [[ -d "$root" ]] || return 1
  current_key="$(ralph_session_todo_attempt_key "$(ralph_session_todo_identity_json)")"
  for record_path in "$root"/post-verification-repair-*.json; do
    [[ -f "$record_path" ]] || continue
    record="$(jq -c '.' "$record_path" 2>/dev/null)" || continue
    [[ "$(jq -r '.kind // empty' <<<"$record")" == "post-verification-repair" ]] || continue
    [[ "$(jq -r '.consumed // false' <<<"$record")" == "false" ]] || continue
    attempt_key="$(jq -r '.attempt_key // empty' <<<"$record")"
    [[ -n "$attempt_key" && "$attempt_key" == "$current_key" ]] || continue
    marker="$(ralph_post_verify_repair_consumed_marker_path "$(jq -r '.request_id // empty' <<<"$record")")"
    [[ ! -f "$marker" ]] || continue
    jq -c '.' <<<"$record"
    return 0
  done
  return 1
}

ralph_post_verify_repair_mark_consumed() {
  local request_id="${1:-}" path marker now_iso
  [[ -n "$request_id" ]] || return 1
  path="$(ralph_post_verify_repair_record_path "$request_id")" || return 1
  marker="$(ralph_post_verify_repair_consumed_marker_path "$request_id")" || return 1
  [[ -f "$path" ]] || return 1
  [[ ! -f "$marker" ]] || return 1
  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u)"
  jq -c --arg consumed_at "$now_iso" '.consumed = true | .consumed_at = $consumed_at' "$path" >"${path}.tmp" \
    && mv -f "${path}.tmp" "$path"
  printf '%s\n' "$now_iso" >"${marker}.tmp" && mv -f "${marker}.tmp" "$marker"
}

# Returns 0 when a pending post-verification repair continuation was consumed.
ralph_post_verify_repair_try_apply() {
  local record request_id failure_reason failure_summary failure_artifact failure_command
  record="$(ralph_post_verify_repair_find_pending 2>/dev/null || true)"
  [[ -n "$record" ]] || return 1
  request_id="$(jq -r '.request_id // empty' <<<"$record")"
  [[ -n "$request_id" ]] || return 1
  ralph_post_verify_repair_mark_consumed "$request_id" || return 1

  if declare -F ralph_session_todo_reactivate_for_repair >/dev/null 2>&1; then
    ralph_session_todo_reactivate_for_repair "$record" >/dev/null 2>&1 || true
  fi

  failure_reason="$(jq -r '.failure_reason // empty' <<<"$record")"
  failure_summary="$(jq -r '.failure_summary // empty' <<<"$record")"
  failure_artifact="$(jq -r '.failure_artifact // empty' <<<"$record")"
  failure_command="$(jq -r '.failure_command // empty' <<<"$record")"

  POST_VERIFICATION_FAILURE_REASON="${failure_reason:-strict_verify_command_failed}"
  POST_VERIFICATION_FAILURE_SUMMARY="$failure_summary"
  POST_VERIFICATION_FAILURE_ARTIFACT="$failure_artifact"
  POST_VERIFICATION_FAILURE_COMMAND="$failure_command"

  RALPH_PLAN_INVOCATION_REASON="${RALPH_TODO_INVOCATION_REASON_CONTINUE:-todo-continue}"
  export RALPH_PLAN_INVOCATION_REASON
  RALPH_POST_VERIFY_REPAIR_CONTINUATION=1
  export RALPH_POST_VERIFY_REPAIR_CONTINUATION
  if declare -F ralph_run_plan_log >/dev/null 2>&1; then
    ralph_run_plan_log "tier2 post-verification repair continuation: consumed record ${request_id}; scheduling todo-continue invocation"
  fi
  return 0
}

fi
