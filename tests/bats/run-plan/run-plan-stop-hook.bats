#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

HOOK_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/native-hook/stop-continuation-hook.sh"
INVOCATION_WAIT_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-bg-invocation-wait.sh"
BG_STATE_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-bg-job-state.sh"
BG_TEARDOWN_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-bg-teardown.sh"
TIER_PROBE_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-bg-tier-probe.sh"
CLAUDE_OVERLAY="$REPO_ROOT/bundle/.ralph/bash-lib/runtime-overlay/runtime-overlay-claude.sh"
RUNTIME_OVERLAY_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/runtime-overlay/runtime-overlay.sh"
CLAUDE_TEMPLATE="$REPO_ROOT/bundle/.claude/settings.json"
BG_SCRIPT="$REPO_ROOT/bundle/.ralph/ralph-bg.sh"
SUPERVISOR_PY="$REPO_ROOT/bundle/.ralph/python/ralph_process_supervisor.py"
PLAN_FILE=""

setup_file() {
  export BATS_NO_PARALLELIZE_WITHIN_FILE=true
}

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  TEST_TMPDIR="$(mktemp -d)"
  PLAN_FILE="$TEST_TMPDIR/PLAN.md"
  printf '# Test plan\n- [ ] stop hook\n' >"$PLAN_FILE"
  export RALPH_BG_JOBS=1
  export RALPH_BG_JOB_TIMEOUT=120
  export RALPH_BG_OUTPUT_MAX_BYTES=4096
  export RALPH_BG_MAX_PER_TODO=8
  export RALPH_SESSION_DIR="$TEST_TMPDIR/session"
  export RALPH_PROJECT_ROOT="$TEST_TMPDIR/project"
  export RALPH_PLAN_WORKSPACE_ROOT="$TEST_TMPDIR/project/.ralph-workspace"
  export RALPH_AGENT_WORKSPACE="$TEST_TMPDIR/project"
  export RALPH_PLAN_KEY="stop-hook-test"
  export RUNTIME="cursor"
  export RALPH_RUN_PLAN_ACTIVE=1
  export RALPH_CURRENT_PLAN_PATH="$PLAN_FILE"
  export RALPH_CURRENT_TODO_LINE="2"
  export RALPH_CURRENT_TODO_ORDINAL="2"
  export RALPH_CURRENT_TODO_ID="todo-stop-hook"
  export RALPH_CURRENT_TODO_HASH="hash-stop-abc"
  export RALPH_PROCESS_RUN_ID="run-stop-hook"
  export RALPH_HOME="$REPO_ROOT"
  mkdir -p "$RALPH_SESSION_DIR" "$RALPH_AGENT_WORKSPACE"
  # shellcheck disable=SC1090
  source "$BG_STATE_LIB"
  # shellcheck disable=SC1090
  source "$HOOK_LIB"
  # shellcheck disable=SC1090
  source "$INVOCATION_WAIT_LIB"
}

teardown() {
  # Close only supervisor runs this test created, found under the test's own
  # state root. Never close "$RALPH_PROCESS_RUN_DIR" directly: inside a live
  # plan run that variable points at the RUNNER'S run, and closing it kills the
  # plan that invoked these tests.
  if [[ -n "${RALPH_PLAN_WORKSPACE_ROOT:-}" && -d "${RALPH_PLAN_WORKSPACE_ROOT}/processes/active" ]]; then
    local run_file
    while IFS= read -r run_file; do
      python3 "$SUPERVISOR_PY" close --run-dir "$(dirname "$run_file")" --reason test-teardown --force >/dev/null 2>&1 || true
    done < <(find "${RALPH_PLAN_WORKSPACE_ROOT}/processes/active" -mindepth 2 -maxdepth 2 -name run.json -type f 2>/dev/null)
  fi
  rm -rf "$TEST_TMPDIR"
  unset RALPH_PROCESS_RUN_DIR RALPH_PROCESS_RUN_ID RALPH_PROCESS_RUN_TOKEN RALPH_PROCESS_GUARDIAN_PID
}

stop_hook_init_process_run() {
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

stop_hook_run() {
  local payload="${1-}"
  [[ -n "$payload" ]] || payload='{}'
  local payload_file="$TEST_TMPDIR/stop-hook-input.json"
  printf '%s' "$payload" >"$payload_file"
  run bash -c 'source "$1"; ralph_bg_stop_hook_main "$(cat "$2")"' bash "$HOOK_LIB" "$payload_file"
}

stop_hook_advance_to_terminal() {
  local job_id="${1:-job-1}" terminal_status="${2:-passed}" exit_code="${3:-0}"
  local job_dir
  ralph_bg_job_create "$job_id" "echo stop-hook" "test" 120 1 "$$" >/dev/null
  ralph_bg_job_mark_launched "$job_id" 4242 "setsid" "true" >/dev/null
  ralph_bg_job_mark_running "$job_id" >/dev/null
  ralph_bg_job_mark_terminal "$job_id" "$terminal_status" >/dev/null
  job_dir="$(ralph_bg_job_dir "$job_id")"
  printf '%s\n' "line-one" >"$job_dir/stdout"
  printf '%s\n' "$exit_code" >"$job_dir/exit_code"
}

invocation_wait_seed_terminal_job() {
  local job_id="${1:-tier2-job}" terminal_status="${2:-passed}" exit_code="${3:-0}"
  export RALPH_BG_TIER_SELECTED=invocation
  stop_hook_advance_to_terminal "$job_id" "$terminal_status" "$exit_code"
}

@test "release immediately when no outstanding job exists" {
  stop_hook_run '{}'
  [ "$status" -eq 0 ]
  run jq -r '.decision,.releaseReason' <<<"$output"
  [ "${lines[0]}" = "release" ]
  [ "${lines[1]}" = "no-outstanding-job" ]
}

@test "release when RALPH_BG_JOBS is disabled" {
  export RALPH_BG_JOBS=0
  stop_hook_advance_to_terminal "job-disabled" "passed"
  stop_hook_run '{}'
  [ "$status" -eq 0 ]
  run jq -r '.decision,.releaseReason' <<<"$output"
  [ "${lines[0]}" = "release" ]
  [ "${lines[1]}" = "bg-jobs-disabled" ]
}

@test "release when runtime stop_hook_active guard is set" {
  stop_hook_advance_to_terminal "job-guard" "passed"
  stop_hook_run '{"stop_hook_active":true}'
  [ "$status" -eq 0 ]
  run jq -r '.decision,.releaseReason' <<<"$output"
  [ "${lines[0]}" = "release" ]
  [ "${lines[1]}" = "runtime-guard-active" ]
}

@test "release when runtime loop_count reaches loop_limit" {
  stop_hook_advance_to_terminal "job-loop" "passed"
  stop_hook_run '{"loop_count":5,"loop_limit":5}'
  [ "$status" -eq 0 ]
  run jq -r '.decision,.releaseReason' <<<"$output"
  [ "${lines[0]}" = "release" ]
  [ "${lines[1]}" = "runtime-guard-active" ]
}

@test "terminal job emits continue payload with required fields" {
  stop_hook_advance_to_terminal "job-payload" "failed" 7
  stop_hook_run '{}'
  [ "$status" -eq 0 ]
  run jq -r '.decision,.continuation.jobId,.continuation.status,.continuation.exitCode,.continuation.elapsedSeconds,.continuation.preview' <<<"$output"
  [ "${lines[0]}" = "continue" ]
  [ "${lines[1]}" = "job-payload" ]
  [ "${lines[2]}" = "failed" ]
  [ "${lines[3]}" = "7" ]
  [[ -n "${lines[4]}" ]]
  [[ "${lines[5]}" == *"line-one"* ]]
}

@test "consume job exactly once and second hook fire releases" {
  stop_hook_advance_to_terminal "job-consume" "passed" 0
  stop_hook_run '{}'
  [ "$status" -eq 0 ]
  run jq -r '.decision' <<<"$output"
  [ "$output" = "continue" ]
  run ralph_bg_job_read "job-consume" 1
  [ "$status" -eq 0 ]
  run jq -r '.state' <<<"$output"
  [ "$output" = "consumed" ]
  stop_hook_run '{}'
  [ "$status" -eq 0 ]
  run jq -r '.decision,.releaseReason' <<<"$output"
  [ "${lines[0]}" = "release" ]
  [ "${lines[1]}" = "no-outstanding-job" ]
}

@test "continuation cap releases instead of continuing again" {
  export RALPH_BG_MAX_PER_TODO=1
  stop_hook_advance_to_terminal "job-cap" "passed" 0
  stop_hook_run '{}'
  [ "$status" -eq 0 ]
  stop_hook_advance_to_terminal "job-cap-2" "passed" 0
  stop_hook_run '{}'
  [ "$status" -eq 0 ]
  run jq -r '.decision,.releaseReason' <<<"$output"
  [ "${lines[0]}" = "release" ]
  [ "${lines[1]}" = "continuation-cap" ]
}

@test "command summary redacts secrets and truncates long commands" {
  local summary long_cmd
  long_cmd="$(printf 'x%.0s' {1..200}) SECRET=super-secret-value"
  summary="$(ralph_bg_stop_hook_command_summary "$long_cmd")"
  [[ "$summary" == *"[REDACTED]"* ]]
  [[ "$summary" != *"super-secret-value"* ]]
  [[ ${#summary} -le 160 ]]
}

@test "preview is capped by RALPH_BG_OUTPUT_MAX_BYTES" {
  local job_id="job-preview-cap" job_dir big preview
  export RALPH_BG_OUTPUT_MAX_BYTES=64
  stop_hook_advance_to_terminal "$job_id" "passed" 0
  job_dir="$(ralph_bg_job_dir "$job_id")"
  big="$(printf 'y%.0s' {1..500})"
  printf '%s' "$big" >"$job_dir/stdout"
  stop_hook_run '{}'
  [ "$status" -eq 0 ]
  preview="$(jq -r '.continuation.preview' <<<"$output")"
  [[ ${#preview} -le 64 ]]
}

@test "stores full output and returns result id and path" {
  local job_id="job-store" job_dir
  stop_hook_advance_to_terminal "$job_id" "passed" 0
  job_dir="$(ralph_bg_job_dir "$job_id")"
  printf '%s\n' "stored-output-line" >"$job_dir/stdout"
  stop_hook_run '{}'
  [ "$status" -eq 0 ]
  run jq -r '.continuation.resultId,.continuation.resultPath' <<<"$output"
  [[ -n "${lines[0]}" ]]
  [[ "${lines[1]}" == *"${lines[0]}"* ]]
  [[ -f "${lines[1]}" ]]
}

@test "waits for a running isolated background job to finish" {
  command -v setsid >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || skip "no isolation primitive"
  stop_hook_init_process_run
  bash "$BG_SCRIPT" 'sleep 0.2 && echo waited-ok' >/dev/null
  stop_hook_run '{}'
  [ "$status" -eq 0 ]
  run jq -r '.decision,.continuation.status,.continuation.preview' <<<"$output"
  [ "${lines[0]}" = "continue" ]
  [ "${lines[1]}" = "passed" ]
  [[ "${lines[2]}" == *"waited-ok"* ]]
}

@test "job timeout marks timed_out terminal status" {
  command -v setsid >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || skip "no isolation primitive"
  stop_hook_init_process_run
  export RALPH_BG_JOB_TIMEOUT=1
  bash "$BG_SCRIPT" 'sleep 5' >/dev/null
  stop_hook_run '{}'
  [ "$status" -eq 0 ]
  run jq -r '.decision,.continuation.status,.continuation.exitCode' <<<"$output"
  [ "${lines[0]}" = "continue" ]
  [ "${lines[1]}" = "timed_out" ]
  [ "${lines[2]}" = "124" ]
}

@test "foreign run id job is ignored and hook releases" {
  ralph_bg_job_create "job-foreign" "echo foreign" "test" 60 1 "$$" >/dev/null
  ralph_bg_job_mark_launched "job-foreign" 1111 "setsid" "true" >/dev/null
  ralph_bg_job_mark_running "job-foreign" >/dev/null
  ralph_bg_job_mark_terminal "job-foreign" "passed" >/dev/null
  export RALPH_PROCESS_RUN_ID="run-other"
  stop_hook_run '{}'
  [ "$status" -eq 0 ]
  run jq -r '.decision,.releaseReason' <<<"$output"
  [ "${lines[0]}" = "release" ]
  [ "${lines[1]}" = "no-outstanding-job" ]
}

@test "missing plan context releases fail-open" {
  unset RALPH_CURRENT_TODO_HASH
  stop_hook_run '{}'
  [ "$status" -eq 0 ]
  run jq -r '.decision,.releaseReason' <<<"$output"
  [ "${lines[0]}" = "release" ]
  [ "${lines[1]}" = "missing-context" ]
}

@test "stdin entrypoint reads payload and continues terminal job" {
  stop_hook_advance_to_terminal "job-stdin" "passed" 0
  run bash "$HOOK_LIB" <<<"{}"
  [ "$status" -eq 0 ]
  run jq -r '.decision,.continuation.jobId' <<<"$output"
  [ "${lines[0]}" = "continue" ]
  [ "${lines[1]}" = "job-stdin" ]
}

@test "tier stop hook gate requires RALPH_BG_TIER_SELECTED hook" {
  # shellcheck disable=SC1090
  source "$TIER_PROBE_LIB"
  export RALPH_BG_JOBS=1
  export RALPH_BG_TIER_SELECTED=invocation
  run ralph_bg_tier_stop_hook_enabled
  [ "$status" -ne 0 ]
  export RALPH_BG_TIER_SELECTED=hook
  run ralph_bg_tier_stop_hook_enabled
  [ "$status" -eq 0 ]
}

@test "claude merge omits stop hook when tier probe selects invocation fallback" {
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"
  # shellcheck disable=SC1090
  source "$TIER_PROBE_LIB"
  export RALPH_BG_JOBS=1
  export RALPH_BG_TIER=invocation
  export RUNTIME=claude
  ralph_bg_tier_probe_apply claude >/dev/null
  source "$CLAUDE_OVERLAY"
  mkdir -p "$RALPH_AGENT_WORKSPACE/.claude"
  printf '%s\n' '{"hooks":{}}' >"$RALPH_AGENT_WORKSPACE/.claude/settings.json"
  local include_stop=0
  if ralph_bg_tier_stop_hook_enabled; then
    include_stop=1
  fi
  [ "$include_stop" -eq 0 ]
  runtime_overlay_claude_merge_settings_file "$RALPH_AGENT_WORKSPACE/.claude/settings.json" "$CLAUDE_TEMPLATE" "$include_stop"
  run jq -r '.hooks.Stop // empty' "$RALPH_AGENT_WORKSPACE/.claude/settings.json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "stop hook owner-dead marks interrupted when runtime pid exits while blocked" {
  # shellcheck disable=SC1090
  source "$BG_TEARDOWN_LIB"
  local job_id="job-owner-dead" owner_pid owner_start fake_job_pid
  ralph_bg_job_create "$job_id" "sleep 60" "test" 120 1 "$$" >/dev/null
  owner_pid="999999"
  owner_start="fake-start-id"
  fake_job_pid="999995"
  record="$(ralph_bg_job_read_raw "$job_id")"
  record="$(jq -c \
    --argjson owner_pid "$owner_pid" \
    --arg owner_process_start_id "$owner_start" \
    --argjson job_pid "$fake_job_pid" \
    --arg job_process_start_id "fake-job-start" \
    '.owner_pid = $owner_pid
     | .owner_process_start_id = $owner_process_start_id
     | .job_pid = $job_pid
     | .job_process_start_id = $job_process_start_id
     | .state = "running"
     | .isolated = true' <<<"$record")"
  ralph_bg_job_write_record "$job_id" "$record" >/dev/null
  stop_hook_run '{}'
  [ "$status" -eq 0 ]
  run jq -r '.decision,.continuation.status' <<<"$output"
  [ "${lines[0]}" = "continue" ]
  [ "${lines[1]}" = "interrupted" ]
  run ralph_bg_job_read "$job_id" 1
  run jq -r '.terminal_status' <<<"$output"
  [ "$output" = "interrupted" ]
}

@test "stop hook requires consecutive negative pid checks before exit" {
  # shellcheck disable=SC1090
  source "$BG_STATE_LIB"
  local job_id="job-pid-liveness" fake_pid="999998"
  ralph_bg_job_create "$job_id" "sleep 60" "test" 120 1 "$$" >/dev/null
  ralph_bg_job_mark_launched "$job_id" "$fake_pid" "setsid" "true" >/dev/null
  ralph_bg_job_mark_running "$job_id" >/dev/null
  stop_hook_run '{}'
  [ "$status" -eq 0 ]
  run jq -r '.decision,.continuation.status' <<<"$output"
  [ "${lines[0]}" = "continue" ]
  [[ "${lines[1]}" == failed || "${lines[1]}" == unknown || "${lines[1]}" == passed ]]
}

@test "restart recovery adopts requested background job" {
  # shellcheck disable=SC1090
  source "$BG_TEARDOWN_LIB"
  export RALPH_BG_JOBS=1
  ralph_bg_job_create "job-restart-requested" "sleep 60" "test" 120 1 999999 >/dev/null
  ralph_bg_job_recover_on_restart
  [[ -f "$RALPH_SESSION_DIR/bg-jobs/recovery-report.json" ]]
  run jq -r '.[0].action,.[0].jobId' "$RALPH_SESSION_DIR/bg-jobs/recovery-report.json"
  [ "${lines[0]}" = "adopt-requested" ]
  [ "${lines[1]}" = "job-restart-requested" ]
  run ralph_bg_job_read "job-restart-requested"
  run jq -r '.state' <<<"$output"
  [ "$output" = "requested" ]
}

@test "restart recovery finalizes running job with dead owner as unknown or interrupted" {
  # shellcheck disable=SC1090
  source "$BG_TEARDOWN_LIB"
  export RALPH_BG_JOBS=1
  local record
  ralph_bg_job_create "job-restart-dead-owner" "sleep 60" "test" 120 1 999999 >/dev/null
  ralph_bg_job_mark_launched "job-restart-dead-owner" 999997 "setsid" "true" >/dev/null
  ralph_bg_job_mark_running "job-restart-dead-owner" >/dev/null
  ralph_bg_job_recover_on_restart
  run ralph_bg_job_read "job-restart-dead-owner" 1
  run jq -r '.state,.terminal_status' <<<"$output"
  [ "${lines[0]}" = "terminal" ]
  [[ "${lines[1]}" == interrupted || "${lines[1]}" == unknown ]]
  run jq -r '.[0].action,.[0].replay' "$RALPH_SESSION_DIR/bg-jobs/recovery-report.json"
  [ "${lines[0]}" = "finalize-dead-owner" ]
  [ "${lines[1]}" = "false" ]
}

@test "tier2 invocation-boundary waits for terminal job and persists continuation record" {
  invocation_wait_seed_terminal_job "tier2-wait" "passed" 0
  set +e
  ralph_bg_invocation_wait_after_turn
  status=$?
  set -e
  [ "$status" -eq 10 ]
  [[ -f "$RALPH_SESSION_DIR/continuations/tier2-wait.json" ]]
  run jq -r '.tier,.reason,.continuation.jobId,.continuation.preview' "$RALPH_SESSION_DIR/continuations/tier2-wait.json"
  [ "${lines[0]}" = "invocation" ]
  [ "${lines[1]}" = "bg-job-result" ]
  [ "${lines[2]}" = "tier2-wait" ]
  [[ "${lines[3]}" == *"line-one"* ]]
  [[ -n "${RALPH_RUN_PLAN_BG_JOB_CONTINUATION:-}" ]]
}

@test "tier2 invocation-boundary consumes job exactly once" {
  invocation_wait_seed_terminal_job "tier2-consume" "passed" 0
  run ralph_bg_invocation_wait_after_turn
  [ "$status" -eq 10 ]
  run ralph_bg_job_read "tier2-consume" 1
  run jq -r '.state' <<<"$output"
  [ "$output" = "consumed" ]
  run ralph_bg_invocation_wait_after_turn
  [ "$status" -eq 0 ]
  [[ -z "${RALPH_RUN_PLAN_BG_JOB_CONTINUATION:-}" ]]
}

@test "tier2 invocation-boundary skips when tier selected is hook" {
  export RALPH_BG_TIER_SELECTED=hook
  invocation_wait_seed_terminal_job "tier2-hook-skip" "passed" 0
  export RALPH_BG_TIER_SELECTED=hook
  run ralph_bg_invocation_wait_after_turn
  [ "$status" -eq 0 ]
  run ralph_bg_job_read "tier2-hook-skip"
  run jq -r '.state' <<<"$output"
  [ "$output" = "terminal" ]
}
