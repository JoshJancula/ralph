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

  ( cd "$workspace" && env -i HOME="$HOME" PATH="$PATH" bash -c "$cmd" </dev/null >"$tmp" 2>&1 ) &
  local cmd_pid=$!

  local waited=0
  while kill -0 "$cmd_pid" 2>/dev/null; do
    if [[ "$waited" -ge "$secs" ]]; then
      RALPH_VERIFY_EXEC_TIMED_OUT=1
      kill -TERM "$cmd_pid" 2>/dev/null || true
      sleep 1
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
    out="$(cd "$workspace" && env -i HOME="$HOME" PATH="$PATH" "$timeout_bin" "$secs" bash -c "$cmd" </dev/null 2>&1)"
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

  ralph_run_plan_log "post-verification scheduled for line=$todo_line command=$_verify_command"

  local _inv_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local _start_time="$(date +%s)"

  {
    echo ""
    echo "================================================================================"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Post-verification for TODO (line $todo_line)"
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
    ralph_run_plan_log "post-verification passed line=$todo_line elapsed=${_inv_elapsed}s"
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
      ralph_run_plan_log "post-verification timed out line=$todo_line after=${_timeout_secs}s elapsed=${_inv_elapsed}s"
      echo -e "${C_Y:-}Verification timed out (line ${todo_line}) after ${_timeout_secs}s${C_RST:-}" >&2
    else
      ralph_run_plan_log "post-verification failed line=$todo_line exit=$_verify_exit elapsed=${_inv_elapsed}s"
      echo -e "${C_Y:-}Verification failed (line ${todo_line}); reopening TODO${C_RST:-}" >&2
    fi

    local _artifact_dir=""
    if [[ -n "$plan_key" ]]; then
      _artifact_dir="$workspace/.ralph-workspace/artifacts/$plan_key/verification"
    elif [[ -n "$artifact_ns" ]]; then
      _artifact_dir="$workspace/.ralph-workspace/artifacts/$artifact_ns/verification"
    else
      _artifact_dir="$workspace/.ralph-workspace/artifacts/verification"
    fi

    mkdir -p "$_artifact_dir"
    _artifact_file="$_artifact_dir/line-${todo_line}-$(date +%s).txt"

    printf '%s\n' "$_verify_output" > "$_artifact_file"

    {
      echo "Post-verification result: FAILED (exit=$_verify_exit)"
      echo "Full output stored: $(basename "$_artifact_file")"
      echo ""
    } >> "$OUTPUT_LOG"

    ralph_run_plan_log "post-verification artifact stored at $(basename "$_artifact_file")"
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
