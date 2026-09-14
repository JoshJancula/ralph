#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

BG_SCRIPT="$REPO_ROOT/bundle/.ralph/ralph-bg.sh"
BG_STATE_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-bg-job-state.sh"
SUPERVISOR_PY="$REPO_ROOT/bundle/.ralph/python/ralph_process_supervisor.py"
PLAN_FILE=""

setup_file() {
  export BATS_NO_PARALLELIZE_WITHIN_FILE=true
}

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  TEST_TMPDIR="$(mktemp -d)"
  PLAN_FILE="$TEST_TMPDIR/PLAN.md"
  printf '# Test plan\n- [ ] background launch\n' >"$PLAN_FILE"
  export RALPH_BG_JOBS=1
  export RALPH_BG_JOB_TIMEOUT=120
  export RALPH_BG_MAX_PER_TODO=8
  export RALPH_SESSION_DIR="$TEST_TMPDIR/session"
  export RALPH_PROJECT_ROOT="$TEST_TMPDIR/project"
  export RALPH_PLAN_WORKSPACE_ROOT="$TEST_TMPDIR/state"
  export RALPH_AGENT_WORKSPACE="$TEST_TMPDIR/project"
  export RALPH_PLAN_KEY="bg-launch-test"
  export RUNTIME="cursor"
  export RALPH_RUN_PLAN_ACTIVE=1
  export RALPH_CURRENT_PLAN_PATH="$PLAN_FILE"
  export RALPH_CURRENT_TODO_LINE="2"
  export RALPH_CURRENT_TODO_ORDINAL="2"
  export RALPH_CURRENT_TODO_ID="todo-bg-launch"
  export RALPH_CURRENT_TODO_HASH="hash-launch-abc"
  export RALPH_PROCESS_RUN_ID="run-bg-launch"
  mkdir -p "$RALPH_SESSION_DIR" "$RALPH_AGENT_WORKSPACE"
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

bg_launch_init_process_run() {
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

bg_launch_wait_for_file() {
  local path="$1" attempts="${2:-50}" n=0
  while (( n < attempts )); do
    [[ -f "$path" ]] && return 0
    sleep 0.05
    n=$((n + 1))
  done
  return 1
}

@test "RALPH_BG_JOBS=0 returns a clear disabled message" {
  bg_launch_init_process_run
  export RALPH_BG_JOBS=0
  run bash "$BG_SCRIPT" 'echo noop'
  [ "$status" -eq 0 ]
  run jq -r '.status,.message' <<<"$output"
  [ "${lines[0]}" = "disabled" ]
  [[ "${lines[1]}" == *"RALPH_BG_JOBS=0"* ]]
}

@test "reject use outside run-plan without RALPH_PROCESS_RUN_DIR" {
  unset RALPH_PROCESS_RUN_DIR
  run bash "$BG_SCRIPT" 'echo outside'
  [ "$status" -ne 0 ]
  [[ "$output" == *"RALPH_PROCESS_RUN_DIR"* ]]
}

@test "reject missing TODO identity exports" {
  bg_launch_init_process_run
  unset RALPH_CURRENT_TODO_HASH
  run bash "$BG_SCRIPT" 'echo missing-identity'
  [ "$status" -ne 0 ]
  [[ "$output" == *"TODO identity"* ]]
}

@test "reject unquoted command with multiple argv words" {
  bg_launch_init_process_run
  run bash "$BG_SCRIPT" echo hello
  [ "$status" -ne 0 ]
  [[ "$output" == *"unquoted or malformed"* ]]
}

@test "reject empty quoted command" {
  bg_launch_init_process_run
  run bash "$BG_SCRIPT" ''
  [ "$status" -ne 0 ]
  [[ "$output" == *"must not be empty"* ]]
}

@test "reject multiline malformed command" {
  bg_launch_init_process_run
  run bash "$BG_SCRIPT" $'echo one\necho two'
  [ "$status" -ne 0 ]
  [[ "$output" == *"single-line"* ]]
}

@test "reject command that selects another plan via --plan" {
  bg_launch_init_process_run
  local other_plan="$TEST_TMPDIR/other.plan.md"
  printf '# other\n' >"$other_plan"
  run bash "$BG_SCRIPT" "ralph run --plan $other_plan"
  [ "$status" -ne 0 ]
  [[ "$output" == *"foreign-plan"* ]]
}

@test "reject command that overrides RALPH_CURRENT_TODO_HASH" {
  bg_launch_init_process_run
  run bash "$BG_SCRIPT" 'RALPH_CURRENT_TODO_HASH=other-hash echo hi'
  [ "$status" -ne 0 ]
  [[ "$output" == *"foreign-todo-hash"* ]]
}

@test "successful launch returns job id and end-turn instructions" {
  command -v setsid >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || skip "no isolation primitive"
  bg_launch_init_process_run
  local json job_id
  json="$(bash "$BG_SCRIPT" 'sleep 0.2')"
  [ "$?" -eq 0 ]
  run jq -r '.status,.tier1Available,.message' <<<"$json"
  [ "${lines[0]}" = "launched" ]
  [ "${lines[1]}" = "true" ]
  [[ "${lines[2]}" == *"without a completion marker"* ]]
  job_id="$(jq -r '.jobId' <<<"$json")"
  [[ "$job_id" == bg-* ]]
}

@test "launch writes launched running record with stdout and stderr paths" {
  command -v setsid >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || skip "no isolation primitive"
  bg_launch_init_process_run
  local json job_id meta
  json="$(bash "$BG_SCRIPT" 'sleep 0.2')"
  job_id="$(jq -r '.jobId' <<<"$json")"
  # shellcheck disable=SC1090
  source "$BG_STATE_LIB"
  meta="$(ralph_bg_job_read "$job_id")"
  run jq -r '.state,.launch_mode,.isolated,.source_surface' <<<"$meta"
  [ "${lines[0]}" = "running" ]
  [[ -n "${lines[1]}" ]]
  [ "${lines[2]}" = "true" ]
  [ "${lines[3]}" = "ralph-bg.sh" ]
  [ -f "$RALPH_SESSION_DIR/bg-jobs/$job_id/stdout" ]
  [ -f "$RALPH_SESSION_DIR/bg-jobs/$job_id/stderr" ]
}

@test "reject duplicate outstanding job for the same command" {
  command -v setsid >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || skip "no isolation primitive"
  bg_launch_init_process_run
  bash "$BG_SCRIPT" 'sleep 0.5' >/dev/null
  run bash "$BG_SCRIPT" 'sleep 0.5'
  [ "$status" -ne 0 ]
  [[ "$output" == *"duplicate outstanding"* ]]
}

@test "reject launch when outstanding jobs reach RALPH_BG_MAX_PER_TODO" {
  command -v setsid >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || skip "no isolation primitive"
  bg_launch_init_process_run
  export RALPH_BG_MAX_PER_TODO=1
  bash "$BG_SCRIPT" 'sleep 0.5' >/dev/null
  run bash "$BG_SCRIPT" 'sleep 0.4'
  [ "$status" -ne 0 ]
  [[ "$output" == *"cap exceeded"* ]]
}

@test "register launched job in Ralph process-scope registry" {
  command -v setsid >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || skip "no isolation primitive"
  bg_launch_init_process_run
  local json job_id scope_file
  json="$(bash "$BG_SCRIPT" 'sleep 0.3')"
  job_id="$(jq -r '.jobId' <<<"$json")"
  scope_file="$RALPH_PROCESS_RUN_DIR/scopes/bg-job-${job_id}.json"
  bg_launch_wait_for_file "$scope_file"
  run jq -r '.kind,.status,.bg_job_id' "$scope_file"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "bg-job" ]
  [ "${lines[1]}" = "running" ]
  [ "${lines[2]}" = "$job_id" ]
}

@test "non-isolated launch terminates job and reports tier 1 unavailable" {
  bg_launch_init_process_run
  local json job_id meta helper status=0
  helper="$TEST_TMPDIR/bg-plain-launch.sh"
  cat >"$helper" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$REPO_ROOT/bundle/.ralph/bash-lib/native-hook/native-shell-wrapper.sh"
ralph_native_shell_launch_process_group() {
  local workspace="\${1:-}" command="\${2:-}" shell_exe="\${3:-bash}" stdout_path="\${4:-}" stderr_path="\${5:-}"
  "\$shell_exe" -c "cd \"\$workspace\" || exit 1; \$command" >"\$stdout_path" 2>"\$stderr_path" &
  RALPH_NATIVE_SHELL_LAUNCH_PID=\$!
  RALPH_NATIVE_SHELL_LAUNCH_PGID="\$RALPH_NATIVE_SHELL_LAUNCH_PID"
  RALPH_NATIVE_SHELL_LAUNCH_SID="\$RALPH_NATIVE_SHELL_LAUNCH_PID"
  RALPH_NATIVE_SHELL_LAUNCH_ISOLATED=false
  RALPH_NATIVE_SHELL_LAUNCH_MODE=plain
}
source "$BG_SCRIPT"
ralph_bg_launch "sleep 5"
EOF
  chmod +x "$helper"
  json="$("$helper" 2>/dev/null)" || status=$?
  [ "$status" -eq 2 ]
  run jq -r '.status,.tier1Available,.reason' <<<"$json"
  [ "${lines[0]}" = "tier1-unavailable" ]
  [ "${lines[1]}" = "false" ]
  [[ "${lines[2]}" == *"non-isolated"* ]]
  job_id="$(jq -r '.jobId' <<<"$json")"
  # shellcheck disable=SC1090
  source "$BG_STATE_LIB"
  meta="$(ralph_bg_job_read "$job_id")"
  run jq -r '.state,.requested_reason,.launch_mode' <<<"$meta"
  [ "${lines[0]}" = "requested" ]
  [[ "${lines[1]}" == *"tier-1-unavailable"* ]]
  [ "${lines[2]}" = "plain" ]
}
