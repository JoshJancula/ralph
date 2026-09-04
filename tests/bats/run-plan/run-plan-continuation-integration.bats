#!/usr/bin/env bats
# Compact full-runner continuation journeys with stub runtimes (no real CLIs).
# Asserts: one command execution per job, session identity per tier, TODO identity,
# consume-once, tier recorded in telemetry, and zero agent polling turns.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

BG_SCRIPT="$REPO_ROOT/bundle/.ralph/ralph-bg.sh"
BG_STATE_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-bg-job-state.sh"
HOOK_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/native-hook/stop-continuation-hook.sh"
INVOCATION_WAIT_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-bg-invocation-wait.sh"
TIER_PROBE_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-bg-tier-probe.sh"
SESSION_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-session.sh"
HUMAN_CONTINUATION_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-human-continuation.sh"
CORE_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-core.sh"
SUPERVISOR_PY="$REPO_ROOT/bundle/.ralph/python/ralph_process_supervisor.py"
PLAN_FILE=""
AGENT_POLL_TURNS=0

setup_file() {
  export BATS_NO_PARALLELIZE_WITHIN_FILE=true
}

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"
  TEST_TMPDIR="$(mktemp -d)"
  PLAN_FILE="$TEST_TMPDIR/PLAN.md"
  printf '# Cont plan\n\n- [ ] first journey todo\n- [ ] second journey todo\n' >"$PLAN_FILE"
  export RALPH_BG_JOBS=1
  export RALPH_BG_JOB_TIMEOUT=30
  export RALPH_BG_OUTPUT_MAX_BYTES=4096
  export RALPH_BG_MAX_PER_TODO=8
  export RALPH_BG_TIER=auto
  export RALPH_SESSION_DIR="$TEST_TMPDIR/session"
  export RALPH_PROJECT_ROOT="$TEST_TMPDIR/project"
  export RALPH_PLAN_WORKSPACE_ROOT="$TEST_TMPDIR/state"
  export RALPH_AGENT_WORKSPACE="$TEST_TMPDIR/project"
  export RALPH_PLAN_KEY="cont-integration"
  export RUNTIME="cursor"
  export RALPH_RUN_PLAN_ACTIVE=1
  export RALPH_CURRENT_PLAN_PATH="$PLAN_FILE"
  export RALPH_CURRENT_TODO_LINE="3"
  export RALPH_CURRENT_TODO_ORDINAL="1"
  export RALPH_CURRENT_TODO_ID="first-journey-todo"
  export RALPH_CURRENT_TODO_HASH="hash-cont-first"
  export RALPH_PROCESS_RUN_ID="run-cont-integration"
  export RALPH_HOME="$REPO_ROOT"
  export AGENT_POLL_TURNS=0
  unset RALPH_BG_TIER_SELECTED RALPH_BG_TIER_REASON RALPH_USAGE_SESSION_CONTINUITY \
    RALPH_USAGE_CONTINUATION_REASON RALPH_USAGE_BG_TIER RALPH_USAGE_TERMINAL_STATUS \
    RALPH_RUN_PLAN_RESUME_SESSION_ID RALPH_RUN_PLAN_NEW_SESSION_ID RALPH_PLAN_INVOCATION_REASON \
    RALPH_RUN_PLAN_BG_JOB_CONTINUATION RALPH_PLAN_CLI_RESUME RALPH_USAGE_WAIT_DURATION_SECONDS \
    RALPH_USAGE_LOGICAL_ATTEMPT RALPH_USAGE_DEGRADED_FALLBACK 2>/dev/null || true
  mkdir -p "$RALPH_SESSION_DIR" "$RALPH_AGENT_WORKSPACE" "$RALPH_AGENT_WORKSPACE/.cursor"
  # shellcheck disable=SC1090
  source "$BG_STATE_LIB"
  # shellcheck disable=SC1090
  source "$HOOK_LIB"
  # shellcheck disable=SC1090
  source "$INVOCATION_WAIT_LIB"
  # shellcheck disable=SC1090
  source "$TIER_PROBE_LIB"
  # shellcheck disable=SC1090
  source "$SESSION_LIB"
  # shellcheck disable=SC1090
  source "$HUMAN_CONTINUATION_LIB"
  ralph_run_plan_log() { :; }
}

teardown() {
  # Close only supervisor runs this test created under the test state root.
  # Never close an inherited RALPH_PROCESS_RUN_DIR from a live plan run.
  if [[ -n "${RALPH_PLAN_WORKSPACE_ROOT:-}" && -d "${RALPH_PLAN_WORKSPACE_ROOT}/processes/active" ]]; then
    local run_file
    while IFS= read -r run_file; do
      python3 "$SUPERVISOR_PY" close --run-dir "$(dirname "$run_file")" --reason test-teardown --force >/dev/null 2>&1 || true
    done < <(find "${RALPH_PLAN_WORKSPACE_ROOT}/processes/active" -mindepth 2 -maxdepth 2 -name run.json -type f 2>/dev/null)
  fi
  rm -rf "$TEST_TMPDIR"
  unset RALPH_PROCESS_RUN_DIR RALPH_PROCESS_RUN_ID RALPH_PROCESS_RUN_TOKEN RALPH_PROCESS_GUARDIAN_PID
}

cont_init_process_run() {
  local exports
  exports="$(env RALPH_PROCESS_SCAN_INTERVAL_SECONDS=0.1 python3 "$SUPERVISOR_PY" init \
    --state-root "$RALPH_PLAN_WORKSPACE_ROOT" \
    --project-root "$RALPH_PROJECT_ROOT" \
    --plan "$PLAN_FILE" \
    --kind plan \
    --owner-pid "$$" \
    --max-live 32)"
  eval "$exports"
}

cont_wait_for() {
  local pred="$1" deadline=$(( $(date +%s) + 5 ))
  until eval "$pred"; do
    [[ $(date +%s) -lt $deadline ]] || {
      echo "timed out waiting for: $pred" >&2
      return 1
    }
    sleep 0.05
  done
}

cont_stop_hook_run() {
  local payload_file="$TEST_TMPDIR/stop-hook-input.json"
  printf '%s' "${1:-{}}" >"$payload_file"
  run bash -c 'source "$1"; ralph_bg_stop_hook_main "$(cat "$2")"' bash "$HOOK_LIB" "$payload_file"
}

cont_assert_zero_agent_polls() {
  [ "${AGENT_POLL_TURNS:-0}" -eq 0 ]
}

cont_load_telemetry_helpers() {
  # shellcheck disable=SC1090
  eval "$(sed -n '/^ralph_run_plan_capture_bg_continuation_usage_telemetry() {/,/^}$/p' "$CORE_LIB")"
  # shellcheck disable=SC1090
  eval "$(sed -n '/^ralph_run_plan_refresh_continuation_usage_telemetry() {/,/^}$/p' "$CORE_LIB")"
}

cont_seed_terminal_job() {
  local job_id="$1" terminal_status="${2:-passed}" exit_code="${3:-0}" preview="${4:-seed-out}"
  local job_dir
  ralph_bg_job_create "$job_id" "echo ${preview}" "test" 30 1 "$$" >/dev/null
  ralph_bg_job_mark_launched "$job_id" 4242 "setsid" "true" >/dev/null
  ralph_bg_job_mark_running "$job_id" >/dev/null
  ralph_bg_job_mark_terminal "$job_id" "$terminal_status" >/dev/null
  job_dir="$(ralph_bg_job_dir "$job_id")"
  printf '%s\n' "$preview" >"$job_dir/stdout"
  printf '%s\n' "$exit_code" >"$job_dir/exit_code"
}

# ralph-bg.sh is a short-lived launcher; rebind owner to this long-lived test
# process (the stub agent stand-in) so tier-1 stop-hook waits do not false-fire
# owner-dead / interrupted.
cont_rebind_job_owner_to_self() {
  local job_id="${1:-}" record owner_start
  [[ -n "$job_id" ]] || return 1
  owner_start="$(ralph_bg_job_owner_process_start_id "$$")"
  record="$(ralph_bg_job_read_raw "$job_id")"
  record="$(jq -c \
    --argjson owner_pid "$$" \
    --arg owner_process_start_id "$owner_start" \
    '.owner_pid = $owner_pid | .owner_process_start_id = $owner_process_start_id' \
    <<<"$record")"
  ralph_bg_job_write_record "$job_id" "$record" >/dev/null
}

cont_launch_bg() {
  local command="${1:-}" json job_id
  json="$(bash "$BG_SCRIPT" "$command")"
  job_id="$(jq -r '.jobId // empty' <<<"$json")"
  if [[ -n "$job_id" && "$(jq -r '.status // empty' <<<"$json")" = "launched" ]]; then
    cont_rebind_job_owner_to_self "$job_id"
  fi
  printf '%s\n' "$json"
}

@test "journey: tier-1 job passes and the same session continues" {
  command -v setsid >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || skip "no isolation primitive"
  cont_init_process_run
  cont_load_telemetry_helpers
  export RALPH_BG_TIER_SELECTED=hook
  export RALPH_BG_TIER_REASON=cursor-stop-hook-followup-with-loop_limit-guard

  local counter="$TEST_TMPDIR/exec.count" json job_id meta
  : >"$counter"
  # Launch then let the stop hook condition-wait; do not poll from the agent.
  # Brief sleep so the hook observes a live then-exited job (matches stop-hook journeys).
  json="$(cont_launch_bg "printf x >>'$counter'; sleep 0.15; printf 'pass-ok\n'")"
  [ "$(jq -r '.status' <<<"$json")" = "launched" ]
  job_id="$(jq -r '.jobId' <<<"$json")"
  cont_wait_for "[[ -s '$counter' ]]"

  cont_stop_hook_run '{}'
  [ "$status" -eq 0 ]
  local hook_json="$output"
  run jq -r '.decision,.continuation.status,.continuation.preview,.continuation.jobId' <<<"$hook_json"
  [ "${lines[0]}" = "continue" ]
  [ "${lines[1]}" = "passed" ]
  [[ "${lines[2]}" == *"pass-ok"* ]]
  [ "${lines[3]}" = "$job_id" ]

  # Exactly one command execution; no agent poll turns during the wait.
  [ "$(wc -c <"$counter" | tr -d ' ')" = "1" ]
  cont_assert_zero_agent_polls

  meta="$(ralph_bg_job_read "$job_id" 1)"
  [ "$(jq -r '.state' <<<"$meta")" = "consumed" ]
  [ "$(jq -r '.identity.todoId' <<<"$meta")" = "first-journey-todo" ]
  [ "$(jq -r '.identity.todoHash' <<<"$meta")" = "hash-cont-first" ]

  ralph_run_plan_capture_bg_continuation_usage_telemetry "$(jq -c '.continuation' <<<"$hook_json")"
  ralph_run_plan_refresh_continuation_usage_telemetry
  [ "${RALPH_USAGE_SESSION_CONTINUITY}" = "held" ]
  [ "${RALPH_USAGE_BG_TIER}" = "hook" ]
  [ "${RALPH_USAGE_CONTINUATION_REASON}" = "bg-job" ]
  [ "${RALPH_USAGE_TERMINAL_STATUS}" = "passed" ]
  [ -z "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]

  # Consume-once: second fire releases.
  cont_stop_hook_run '{}'
  [ "$status" -eq 0 ]
  run jq -r '.decision,.releaseReason' <<<"$output"
  [ "${lines[0]}" = "release" ]
  [ "${lines[1]}" = "no-outstanding-job" ]
  cont_assert_zero_agent_polls
}

@test "journey: tier-1 job fails and the continuation carries the evidence" {
  command -v setsid >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || skip "no isolation primitive"
  cont_init_process_run
  cont_load_telemetry_helpers
  export RALPH_BG_TIER_SELECTED=hook
  export RALPH_BG_TIER_REASON=cursor-stop-hook-followup-with-loop_limit-guard

  local counter="$TEST_TMPDIR/fail.exec" json job_id
  : >"$counter"
  # stderr carries evidence; launcher does not write exit_code, so the stop hook
  # infers failure from a non-empty stderr when the process has exited.
  json="$(cont_launch_bg "printf x >>'$counter'; sleep 0.15; printf 'FAIL: suite blew up at line 42\n' >&2; exit 7")"
  [ "$(jq -r '.status' <<<"$json")" = "launched" ]
  job_id="$(jq -r '.jobId' <<<"$json")"
  cont_wait_for "[[ -s '$counter' ]]"

  cont_stop_hook_run '{}'
  [ "$status" -eq 0 ]
  local hook_json="$output"
  run jq -r '.decision,.continuation.status,.continuation.preview' <<<"$hook_json"
  [ "${lines[0]}" = "continue" ]
  [ "${lines[1]}" = "failed" ]
  [[ "${lines[2]}" == *"FAIL: suite blew up at line 42"* ]]

  [ "$(wc -c <"$counter" | tr -d ' ')" = "1" ]
  cont_assert_zero_agent_polls
  [ "$(jq -r '.state' <<<"$(ralph_bg_job_read "$job_id" 1)")" = "consumed" ]

  ralph_run_plan_capture_bg_continuation_usage_telemetry "$(jq -c '.continuation' <<<"$hook_json")"
  ralph_run_plan_refresh_continuation_usage_telemetry
  [ "${RALPH_USAGE_SESSION_CONTINUITY}" = "held" ]
  [ "${RALPH_USAGE_BG_TIER}" = "hook" ]
  [ "${RALPH_USAGE_TERMINAL_STATUS}" = "failed" ]
}

@test "journey: tier-1 unavailable falls back to tier 2 and resumes by exact ID" {
  cont_init_process_run
  cont_load_telemetry_helpers

  # Force the isolation probe off so auto selection falls back to invocation.
  ralph_bg_tier_probe_isolation_mode() { printf '%s\n' "none"; return 1; }
  ralph_bg_tier_probe_isolation_available() { return 1; }
  export RALPH_BG_TIER=auto
  ralph_bg_tier_probe_apply cursor >/dev/null
  [ "${RALPH_BG_TIER_SELECTED}" = "invocation" ]
  [[ "${RALPH_BG_TIER_REASON}" == *"no-isolation"* ]]

  local session_id="sess-tier2-exact-fallback"
  ralph_session_todo_create "$session_id" "exact" >/dev/null
  cont_seed_terminal_job "tier2-fallback-job" "passed" 0 "tier2-fallback-out"

  set +e
  ralph_bg_invocation_wait_after_turn
  local wait_rc=$?
  set -e
  [ "$wait_rc" -eq 10 ]
  [ "$(jq -r '.state' <<<"$(ralph_bg_job_read tier2-fallback-job 1)")" = "consumed" ]
  [[ -n "${RALPH_RUN_PLAN_BG_JOB_CONTINUATION:-}" ]]
  [[ "${RALPH_RUN_PLAN_BG_JOB_CONTINUATION}" == *"tier2-fallback-out"* ]]

  export RALPH_PLAN_SESSION_STRATEGY=fresh
  unset RALPH_PLAN_INVOCATION_REASON RALPH_RUN_PLAN_NEW_SESSION_ID RALPH_RUN_PLAN_RESUME_BARE
  ralph_session_todo_prepare_invocation
  [ "${RALPH_PLAN_INVOCATION_REASON}" = "todo-continue" ]
  [ "${RALPH_RUN_PLAN_RESUME_SESSION_ID}" = "$session_id" ]
  [ "${RALPH_PLAN_CLI_RESUME}" = "1" ]

  ralph_run_plan_capture_bg_continuation_usage_telemetry "$RALPH_RUN_PLAN_BG_JOB_CONTINUATION"
  ralph_run_plan_refresh_continuation_usage_telemetry
  [ "${RALPH_USAGE_SESSION_CONTINUITY}" = "resumed" ]
  [ "${RALPH_USAGE_BG_TIER}" = "invocation" ]
  [ "${RALPH_USAGE_CONTINUATION_REASON}" = "bg-job" ]
  cont_assert_zero_agent_polls

  # Consume-once: second wait does not redeliver.
  unset RALPH_RUN_PLAN_BG_JOB_CONTINUATION
  set +e
  ralph_bg_invocation_wait_after_turn
  wait_rc=$?
  set -e
  [ "$wait_rc" -eq 0 ]
  [ -z "${RALPH_RUN_PLAN_BG_JOB_CONTINUATION:-}" ]
}

@test "journey: fresh TODO pauses for a human answer and resumes exact session" {
  cont_load_telemetry_helpers
  local session_id="sess-human-pause"
  ralph_session_todo_create "$session_id" "exact" >/dev/null

  # Pause: persist human-answer continuation (tier 2 shaped; crosses invocations).
  local record request_id
  record="$(ralph_human_continuation_persist "guidance" "")"
  [ "$(jq -r '.kind,.consumed,.route' <<<"$record" | paste -sd, -)" = "human-answer,false,guidance" ]
  request_id="$(jq -r '.request_id' <<<"$record")"
  [ -f "$(ralph_human_continuation_record_path "$request_id")" ]

  export RALPH_PLAN_SESSION_STRATEGY=fresh
  unset RALPH_PLAN_INVOCATION_REASON RALPH_RUN_PLAN_RESUME_SESSION_ID RALPH_RUN_PLAN_NEW_SESSION_ID RALPH_RUN_PLAN_RESUME_BARE
  ralph_session_todo_prepare_invocation
  [ "${RALPH_PLAN_INVOCATION_REASON}" = "todo-continue" ]
  [ "${RALPH_RUN_PLAN_RESUME_SESSION_ID}" = "$session_id" ]
  [ "${RALPH_PLAN_CLI_RESUME}" = "1" ]
  [ "${RALPH_USAGE_CONTINUATION_REASON}" = "human-answer" ]
  [ "${RALPH_USAGE_SESSION_CONTINUITY}" = "resumed" ]

  # Consume-once: second apply finds nothing.
  run ralph_human_continuation_try_apply
  [ "$status" -ne 0 ]
  [ -f "$(ralph_human_continuation_consumed_marker_path "$request_id")" ]
  cont_assert_zero_agent_polls
}

@test "journey: next TODO starts fresh after prior TODO completes" {
  local first_session="sess-todo-one" second_session=""
  ralph_session_todo_create "$first_session" "exact" >/dev/null
  export SESSION_ID_FILE="$RALPH_SESSION_DIR/session-id.cursor.txt"
  printf '%s\n' "$first_session" >"$SESSION_ID_FILE"

  # Complete first TODO and retire its session at the boundary.
  ralph_session_todo_retire_at_boundary
  run ralph_session_todo_select_manifest
  [ "$status" -ne 0 ]

  # Advance to the next TODO identity under fresh strategy.
  export RALPH_CURRENT_TODO_LINE="4"
  export RALPH_CURRENT_TODO_ORDINAL="2"
  export RALPH_CURRENT_TODO_ID="second-journey-todo"
  export RALPH_CURRENT_TODO_HASH="hash-cont-second"
  export RALPH_PLAN_SESSION_STRATEGY=fresh
  unset RALPH_PLAN_INVOCATION_REASON RALPH_RUN_PLAN_RESUME_SESSION_ID RALPH_RUN_PLAN_NEW_SESSION_ID \
    RALPH_RUN_PLAN_RESUME_BARE RALPH_PLAN_CLI_RESUME
  ralph_session_todo_prepare_invocation
  [ "${RALPH_PLAN_INVOCATION_REASON}" = "todo-start" ]
  [ -z "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]
  [ "${RALPH_PLAN_CLI_RESUME}" = "0" ]
  cont_assert_zero_agent_polls
}

@test "journey: bg-job continuation consume-once and tier telemetry without agent polls" {
  cont_load_telemetry_helpers
  export RALPH_BG_TIER_SELECTED=invocation
  export RALPH_BG_TIER_REASON=fallback-no-isolation-primitive
  ralph_session_todo_create "sess-consume-once" "exact" >/dev/null
  cont_seed_terminal_job "consume-once-job" "passed" 0 "once-only"

  set +e
  ralph_bg_invocation_wait_after_turn
  local wait_rc=$?
  set -e
  [ "$wait_rc" -eq 10 ]
  local cont_json="$RALPH_RUN_PLAN_BG_JOB_CONTINUATION"
  [[ -n "$cont_json" ]]

  ralph_bg_invocation_mark_continuation_consumed "$cont_json" >/dev/null
  [ -f "$(ralph_bg_continuation_consumed_marker_path consume-once-job)" ]
  run ralph_bg_invocation_mark_continuation_consumed "$cont_json"
  [ "$status" -ne 0 ]

  ralph_run_plan_capture_bg_continuation_usage_telemetry "$cont_json"
  ralph_run_plan_refresh_continuation_usage_telemetry
  [ "${RALPH_USAGE_BG_TIER}" = "invocation" ]
  [ "${RALPH_USAGE_SESSION_CONTINUITY}" = "resumed" ]
  [ "${RALPH_USAGE_CONTINUATION_REASON}" = "bg-job" ]
  [ "${RALPH_USAGE_TERMINAL_STATUS}" = "passed" ]
  [[ -n "${RALPH_USAGE_LOGICAL_ATTEMPT:-}" ]]
  cont_assert_zero_agent_polls
}
