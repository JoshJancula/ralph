#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

TEARDOWN_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/ralph-process-teardown.sh"
BG_STATE_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-bg-job-state.sh"
BG_TEARDOWN_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-bg-teardown.sh"
CLEANUP_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-cleanup.sh"

setup_file() {
  # Teardown tests spawn real process groups and this file's teardown() does a
  # child-scoped pkill; running them concurrently races their process cleanup and
  # can drop a test from the parallel run. Serialize within this file; other files
  # still parallelize.
  export BATS_NO_PARALLELIZE_WITHIN_FILE=true
}

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export WORKSPACE="$TEST_TMPDIR/workspace"
  export RALPH_PLAN_KEY="teardown-test"
  export RALPH_ARTIFACT_NS="teardown-test"
  export RALPH_SESSION_DIR="$TEST_TMPDIR/session"
  export RALPH_PROJECT_ROOT="$WORKSPACE"
  export RALPH_PLAN_WORKSPACE_ROOT="$WORKSPACE/.ralph-workspace"
  export RALPH_AGENT_WORKSPACE="$WORKSPACE"
  export RALPH_CURRENT_TODO_LINE="2"
  export RALPH_CURRENT_TODO_ORDINAL="2"
  export RALPH_CURRENT_TODO_HASH="teardown-hash"
  export RUNTIME="cursor"
  mkdir -p "$WORKSPACE" "$RALPH_SESSION_DIR"
  command -v jq >/dev/null 2>&1 || skip "jq required"
  # shellcheck disable=SC1090
  source "$BG_STATE_LIB"
}

teardown() {
  pkill -P "$$" 2>/dev/null || true
  rm -rf "$TEST_TMPDIR"
}

source_teardown_libs() {
  # shellcheck source=/dev/null
  source "$TEARDOWN_LIB"
  # shellcheck source=/dev/null
  source "$CLEANUP_LIB"
}

@test "agent teardown kills live AGENT_PID process group leader" {
  local marker
  marker="$TEST_TMPDIR/agent-live.marker"

  run bash -c '
    set -euo pipefail
    source "$1"
    set -m
    ( sleep 120 ) &
    AGENT_PID=$!
    echo "$AGENT_PID" >"$2"
    ralph_run_plan_agent_teardown
    if kill -0 "$AGENT_PID" 2>/dev/null; then
      exit 9
    fi
  ' _ "$TEARDOWN_LIB" "$marker"

  [ "$status" -eq 0 ]
  [ -f "$marker" ]
}

@test "agent teardown kills recorded CLI when AGENT_PID leader already exited" {
  local cli_sidecar
  cli_sidecar="$TEST_TMPDIR/cli-pid.sidecar"

  run bash -c '
    set -euo pipefail
    source "$1"
    export RALPH_PLAN_INVOCATION_CLI_PID_FILE="$2"
    (
      sleep 120 &
      printf "%s" "$!" >"$RALPH_PLAN_INVOCATION_CLI_PID_FILE"
      exit 0
    ) &
    AGENT_PID=$!
    wait "$AGENT_PID" || true
    cli_pid="$(cat "$RALPH_PLAN_INVOCATION_CLI_PID_FILE")"
    ralph_run_plan_agent_teardown
    if kill -0 "$cli_pid" 2>/dev/null; then
      exit 9
    fi
    if [[ -f "$RALPH_PLAN_INVOCATION_CLI_PID_FILE" ]]; then
      exit 8
    fi
  ' _ "$TEARDOWN_LIB" "$cli_sidecar"

  [ "$status" -eq 0 ]
}

@test "agent teardown ignores stale or malformed CLI sidecars" {
  local cli_sidecar
  cli_sidecar="$TEST_TMPDIR/cli-pid.sidecar"
  printf 'not-a-pid\n' >"$cli_sidecar"

  run bash -c '
    set -euo pipefail
    source "$1"
    export RALPH_PLAN_INVOCATION_CLI_PID_FILE="$2"
    ralph_run_plan_agent_teardown
    ralph_run_plan_agent_teardown
    [[ ! -f "$RALPH_PLAN_INVOCATION_CLI_PID_FILE" ]]
  ' _ "$TEARDOWN_LIB" "$cli_sidecar"

  [ "$status" -eq 0 ]
}

@test "agent teardown is idempotent across repeated calls" {
  run bash -c '
    set -euo pipefail
    source "$1"
    set -m
    ( sleep 120 ) &
    AGENT_PID=$!
    ralph_run_plan_agent_teardown
    ralph_run_plan_agent_teardown
    ralph_run_plan_process_teardown_on_exit
    if kill -0 "$AGENT_PID" 2>/dev/null; then
      exit 9
    fi
  ' _ "$TEARDOWN_LIB"

  [ "$status" -eq 0 ]
}

@test "agent teardown stops launcher watchdog process" {
  run bash -c '
    set -euo pipefail
    source "$1"
    sleep 120 &
    watchdog_pid=$!
    export RALPH_LAUNCHER_WATCHDOG_PID=$watchdog_pid
    ralph_run_plan_agent_teardown
    if kill -0 "$watchdog_pid" 2>/dev/null; then
      exit 9
    fi
  ' _ "$TEARDOWN_LIB"

  [ "$status" -eq 0 ]
}

@test "agent teardown cancels runner-owned async shell jobs" {
  command -v jq >/dev/null || skip "jq required"

  local job_dir state_file job_pid
  job_dir="$WORKSPACE/.ralph-workspace/tool-results/$RALPH_PLAN_KEY/shell-jobs/job-1"
  state_file="$job_dir/state.json"
  mkdir -p "$job_dir"

  sleep 120 &
  job_pid=$!

  jq -nc --arg pid "$job_pid" --arg startedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{status:"running", pid:$pid, startedAt:$startedAt}' >"$state_file"

  run bash -c '
    set -euo pipefail
    source "$1"
    export WORKSPACE="$2"
    export RALPH_PLAN_KEY="$3"
    ralph_run_plan_agent_teardown
    if kill -0 "$4" 2>/dev/null; then
      exit 9
    fi
    status="$(jq -r ".status" "$5")"
    [[ "$status" == "cancelled" ]]
  ' _ "$TEARDOWN_LIB" "$WORKSPACE" "$RALPH_PLAN_KEY" "$job_pid" "$state_file"

  [ "$status" -eq 0 ]
  kill -0 "$job_pid" 2>/dev/null && kill -KILL "$job_pid" 2>/dev/null || true
}

@test "agent teardown cancels speculative cache warm background job" {
  local warm_lib record
  warm_lib="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-claude-speculative-cache-warm.sh"
  record="$TEST_TMPDIR/claude-warm-teardown.args"

  run bash -c '
    set -euo pipefail
    source "$1"
    source "$2"
    mkdir -p "$3/bin" "$3/workspace/.ralph-workspace/sessions/teardown-warm/logs/teardown-warm"
    cat <<EOF >"$3/bin/claude"
#!/usr/bin/env bash
if [[ "\${1:-}" == "--help" ]]; then
  echo "  --cache-control <policy>"
  echo "  --max-output-tokens <n>"
  exit 0
fi
sleep 120
EOF
    chmod +x "$3/bin/claude"
    export PATH="$3/bin:$PATH"
    export WORKSPACE="$3/workspace"
    export RALPH_PLAN_KEY=teardown-warm
    export RALPH_PLAN_WORKSPACE_ROOT="$3/workspace/.ralph-workspace"
    export RUNTIME=claude
    export RALPH_CLAUDE_SPECULATIVE_CACHE_WARM=1
    export PROMPT_STATIC="warm-teardown-prefix"

    ralph_claude_speculative_cache_warm_maybe_start 7
    pid="$(ralph_claude_speculative_cache_warm_read_pid)"
    ralph_run_plan_agent_teardown
    if kill -0 "$pid" 2>/dev/null; then
      exit 9
    fi
    if [[ -f "$RALPH_PLAN_SPECULATIVE_CACHE_WARM_PID_FILE" ]]; then
      exit 8
    fi
  ' _ "$TEARDOWN_LIB" "$warm_lib" "$TEST_TMPDIR"

  [ "$status" -eq 0 ]
}

@test "interrupt trap handler exits 130 for INT" {
  run bash -c '
    set -euo pipefail
    _ralph_finalize_plan_usage_on_exit() { :; }
    export -f _ralph_finalize_plan_usage_on_exit
    source "$1"
    source "$2"
    ralph_run_plan_interrupt_trap_handler INT
  ' _ "$TEARDOWN_LIB" "$CLEANUP_LIB"

  [ "$status" -eq 130 ]
}

@test "interrupt trap handler exits 143 for TERM" {
  run bash -c '
    set -euo pipefail
    _ralph_finalize_plan_usage_on_exit() { :; }
    export -f _ralph_finalize_plan_usage_on_exit
    source "$1"
    source "$2"
    ralph_run_plan_interrupt_trap_handler TERM
  ' _ "$TEARDOWN_LIB" "$CLEANUP_LIB"

  [ "$status" -eq 143 ]
}

@test "interrupt trap handler exits 129 for HUP" {
  run bash -c '
    set -euo pipefail
    _ralph_finalize_plan_usage_on_exit() { :; }
    export -f _ralph_finalize_plan_usage_on_exit
    source "$1"
    source "$2"
    ralph_run_plan_interrupt_trap_handler HUP
  ' _ "$TEARDOWN_LIB" "$CLEANUP_LIB"

  [ "$status" -eq 129 ]
}

@test "agent teardown preserves outstanding durable background jobs" {
  local job_id job_pid
  sleep 120 &
  job_pid=$!
  job_id="job-teardown-preserve"
  ralph_bg_job_create "$job_id" "sleep 120" "test" 120 1 "$$" >/dev/null
  ralph_bg_job_mark_launched "$job_id" "$job_pid" "setsid" "true" >/dev/null
  ralph_bg_job_mark_running "$job_id" >/dev/null

  run bash -c '
    set -euo pipefail
    source "$1"
    source "$2"
    export RALPH_SESSION_DIR="$3"
    export RALPH_PLAN_KEY="$4"
    export RALPH_CURRENT_TODO_LINE=2
    export RALPH_CURRENT_TODO_ORDINAL=2
    export RALPH_CURRENT_TODO_HASH=teardown-hash
    export RUNTIME=cursor
    ralph_run_plan_agent_teardown
    kill -0 "$5"
    state="$(ralph_bg_job_read "$6" 1 | jq -r .state)"
    [[ "$state" == "running" ]]
  ' _ "$TEARDOWN_LIB" "$BG_STATE_LIB" "$RALPH_SESSION_DIR" "$RALPH_PLAN_KEY" "$job_pid" "$job_id"

  [ "$status" -eq 0 ]
  kill -0 "$job_pid" 2>/dev/null && kill -KILL "$job_pid" 2>/dev/null || true
}

@test "plan-exit teardown cancels outstanding tier-1 background job" {
  local job_id job_pid
  sleep 120 &
  job_pid=$!
  job_id="job-teardown-cancel"
  ralph_bg_job_create "$job_id" "sleep 120" "test" 120 1 "$$" >/dev/null
  ralph_bg_job_mark_launched "$job_id" "$job_pid" "setsid" "true" >/dev/null
  ralph_bg_job_mark_running "$job_id" >/dev/null

  run bash -c '
    set -euo pipefail
    source "$1"
    export RALPH_SESSION_DIR="$2"
    export RALPH_PLAN_KEY="$3"
    export RALPH_CURRENT_TODO_LINE=2
    export RALPH_CURRENT_TODO_ORDINAL=2
    export RALPH_CURRENT_TODO_HASH=teardown-hash
    export RUNTIME=cursor
    ralph_run_plan_process_teardown_on_exit
    if kill -0 "$4" 2>/dev/null; then
      exit 9
    fi
    status="$(ralph_bg_job_read "$5" 1 | jq -r .terminal_status)"
    [[ "$status" == "cancelled" ]]
  ' _ "$TEARDOWN_LIB" "$RALPH_SESSION_DIR" "$RALPH_PLAN_KEY" "$job_pid" "$job_id"

  [ "$status" -eq 0 ]
  kill -0 "$job_pid" 2>/dev/null && kill -KILL "$job_pid" 2>/dev/null || true
}

@test "plan-exit teardown marks background job interrupted on signal exit status" {
  local job_id
  job_id="job-teardown-interrupted"
  ralph_bg_job_create "$job_id" "sleep 120" "test" 120 1 "$$" >/dev/null
  ralph_bg_job_mark_launched "$job_id" 999996 "setsid" "true" >/dev/null
  ralph_bg_job_mark_running "$job_id" >/dev/null

  run bash -c '
    set -euo pipefail
    source "$1"
    export RALPH_SESSION_DIR="$2"
    export RALPH_PLAN_KEY="$3"
    export RALPH_CURRENT_TODO_LINE=2
    export RALPH_CURRENT_TODO_ORDINAL=2
    export RALPH_CURRENT_TODO_HASH=teardown-hash
    export RUNTIME=cursor
    export EXIT_STATUS=interrupted
    ralph_run_plan_process_teardown_on_exit
    status="$(ralph_bg_job_read "$4" 1 | jq -r .terminal_status)"
    [[ "$status" == "interrupted" ]]
  ' _ "$TEARDOWN_LIB" "$RALPH_SESSION_DIR" "$RALPH_PLAN_KEY" "$job_id"

  [ "$status" -eq 0 ]
}

@test "background job safe terminate skips pid reuse mismatch" {
  run bash -c '
    set -euo pipefail
    source "$1"
    sleep 300 &
    unrelated_pid=$!
    kill -0 "$unrelated_pid"
    record="$(ralph_bg_job_create_record_json "job-pid-reuse" "sleep 120" "test" 120 1 "$$")"
    record="$(jq -c \
      --argjson job_pid "$unrelated_pid" \
      --arg job_process_start_id "wrong-start-id" \
      --arg state "$RALPH_BG_JOB_STATE_RUNNING" \
      ".job_pid = \$job_pid | .job_process_start_id = \$job_process_start_id | .state = \$state | .isolated = true" <<<"$record")"
    if ralph_bg_job_safe_terminate "$record"; then
      exit 8
    fi
    kill -0 "$unrelated_pid"
    kill -TERM "$unrelated_pid" 2>/dev/null || true
  ' _ "$BG_TEARDOWN_LIB"

  [ "$status" -eq 0 ]
}

@test "native shell pid_running validates process start id" {
  local wrapper_lib start_id
  wrapper_lib="$REPO_ROOT/bundle/.ralph/bash-lib/native-hook/native-shell-wrapper.sh"
  # shellcheck disable=SC1090
  source "$wrapper_lib"
  start_id="$(ralph_native_shell_process_start_id_of_pid $$)"
  [[ -n "$start_id" ]]
  run ralph_native_shell_pid_running "$$" "$start_id"
  [ "$status" -eq 0 ]
  run ralph_native_shell_pid_running "$$" "wrong-start-id"
  [ "$status" -eq 1 ]
}

@test "restart recovery runs from bg teardown library" {
  # shellcheck disable=SC1090
  source "$BG_TEARDOWN_LIB"
  export RALPH_BG_JOBS=1
  ralph_bg_job_create "job-recover-lib" "echo recover" "test" 60 1 888888 >/dev/null
  ralph_bg_job_recover_on_restart
  [[ -f "$RALPH_SESSION_DIR/bg-jobs/recovery-report.json" ]]
  run jq -r '.[0].jobId' "$RALPH_SESSION_DIR/bg-jobs/recovery-report.json"
  [ "$output" = "job-recover-lib" ]
}
