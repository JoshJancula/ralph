#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

SUPERVISOR_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/ralph-process-supervisor.sh"
SUPERVISOR_PY="$REPO_ROOT/bundle/.ralph/python/ralph_process_supervisor.py"

setup_file() {
  # Process-supervisor tests start and reap real managed processes. Running them
  # concurrently within this file races their state dirs and reaping and can drop
  # a test from the parallel run. Serialize within this file; other files still
  # parallelize.
  export BATS_NO_PARALLELIZE_WITHIN_FILE=true
}

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  STATE_ROOT="$TEST_TMPDIR/state"
  PLAN_FILE="$TEST_TMPDIR/PLAN.md"
  printf '# Test plan\n- [ ] managed process test\n' >"$PLAN_FILE"
}

teardown() {
  if [[ -d "$STATE_ROOT/processes/active" ]]; then
    local run_file
    while IFS= read -r run_file; do
      python3 "$SUPERVISOR_PY" close --run-dir "$(dirname "$run_file")" --reason test-teardown --force >/dev/null 2>&1 || true
    done < <(find "$STATE_ROOT/processes/active" -mindepth 2 -maxdepth 2 -name run.json -type f 2>/dev/null)
  fi
  rm -rf "$TEST_TMPDIR"
}

wait_for_file() {
  local path="$1" attempts="${2:-100}"
  local n=0
  while (( n < attempts )); do
    [[ -s "$path" ]] && return 0
    sleep 0.1
    n=$((n + 1))
  done
  return 1
}

wait_for_pid_gone() {
  local pid="$1" attempts="${2:-120}"
  local n=0
  while (( n < attempts )); do
    if ! kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
    n=$((n + 1))
  done
  return 1
}

@test "process registry lists an active run and rejects a duplicate plan lease" {
  local exports run_dir
  exports="$(env RALPH_PROCESS_SCAN_INTERVAL_SECONDS=0.1 python3 "$SUPERVISOR_PY" init \
    --state-root "$STATE_ROOT" --project-root "$TEST_TMPDIR" --plan "$PLAN_FILE" \
    --kind plan --owner-pid "$$" --max-live 32)"
  eval "$exports"
  run_dir="$RALPH_PROCESS_RUN_DIR"

  run python3 "$SUPERVISOR_PY" list --state-root "$STATE_ROOT" --json
  [ "$status" -eq 0 ]
  [[ "$output" == *"$RALPH_PROCESS_RUN_ID"* ]]
  [[ "$output" == *"$PLAN_FILE"* ]]

  run python3 "$SUPERVISOR_PY" init \
    --state-root "$STATE_ROOT" --project-root "$TEST_TMPDIR" --plan "$PLAN_FILE" \
    --kind plan --owner-pid "$$" --max-live 32
  [ "$status" -eq 2 ]
  [[ "$output" == *"already active"* ]]

  run python3 "$SUPERVISOR_PY" close --run-dir "$run_dir" --reason test-complete
  [ "$status" -eq 0 ]
}

@test "scope process cap terminates the session and exits 78" {
  local exports
  exports="$(env RALPH_PROCESS_SCAN_INTERVAL_SECONDS=0.1 python3 "$SUPERVISOR_PY" init \
    --state-root "$STATE_ROOT" --project-root "$TEST_TMPDIR" --plan "$PLAN_FILE" \
    --kind plan --owner-pid "$$" --max-live 32)"
  eval "$exports"

  run env RALPH_PROCESS_TERM_GRACE_SECONDS=1 RALPH_PROCESS_KILL_GRACE_SECONDS=1 \
    python3 "$SUPERVISOR_PY" run-scope \
      --run-dir "$RALPH_PROCESS_RUN_DIR" --scope-id cap --kind test --runtime python \
      --scope-owner-pid "$$" --max-live 2 -- \
      python3 -c 'import subprocess,time; children=[subprocess.Popen(["sleep","30"]) for _ in range(4)]; time.sleep(30)'
  [ "$status" -eq 78 ]
  [ -s "$RALPH_PROCESS_RUN_DIR/abort.json" ]
}

@test "detached guardian reaps a runtime and an escaped session after owner SIGKILL" {
  local launcher="$TEST_TMPDIR/launcher.sh"
  local run_dir_file="$TEST_TMPDIR/run-dir"
  local root_pid_file="$TEST_TMPDIR/root-pid"
  local escaped_pid_file="$TEST_TMPDIR/escaped-pid"
  cat >"$launcher" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$1"
ralph_process_run_init "$2" "$3" "$4" plan
printf '%s\n' "$RALPH_PROCESS_RUN_DIR" >"$5"
export ROOT_PID_FILE="$6"
export ESCAPED_PID_FILE="$7"
ralph_process_scope_exec test python python3 - <<'PY'
import os, subprocess, sys, time
from pathlib import Path

Path(os.environ["ROOT_PID_FILE"]).write_text(str(os.getpid()))
escaped_code = '''
import os, signal, time
from pathlib import Path
signal.signal(signal.SIGTERM, signal.SIG_IGN)
Path(os.environ["ESCAPED_PID_FILE"]).write_text(str(os.getpid()))
while True:
    time.sleep(1)
'''
child = subprocess.Popen([sys.executable, "-c", escaped_code], start_new_session=True)
child.wait()
PY
EOF
  chmod +x "$launcher"

  env RALPH_PROCESS_TERM_GRACE_SECONDS=1 RALPH_PROCESS_KILL_GRACE_SECONDS=1 \
    bash "$launcher" "$SUPERVISOR_LIB" "$STATE_ROOT" "$TEST_TMPDIR" "$PLAN_FILE" \
      "$run_dir_file" "$root_pid_file" "$escaped_pid_file" &
  local owner_pid=$!
  wait_for_file "$run_dir_file"
  wait_for_file "$root_pid_file"
  wait_for_file "$escaped_pid_file"
  local root_pid escaped_pid run_dir
  root_pid="$(cat "$root_pid_file")"
  escaped_pid="$(cat "$escaped_pid_file")"
  run_dir="$(cat "$run_dir_file")"

  kill -KILL "$owner_pid"
  wait "$owner_pid" 2>/dev/null || true
  wait_for_pid_gone "$root_pid"
  wait_for_pid_gone "$escaped_pid"

  local n=0
  while (( n < 50 )) && ! grep -q '"termination_reason": "owner-exited"' "$run_dir/run.json" 2>/dev/null; do
    sleep 0.1
    n=$((n + 1))
  done

  run python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["termination_reason"])' "$run_dir/run.json"
  [ "$status" -eq 0 ]
  [ "$output" = "owner-exited" ]
}

@test "nested run is denied by default and an intentional attach honors depth" {
  run bash -c '
    set -euo pipefail
    source "$1"
    ralph_process_run_init "$2" "$3" "$4" plan
    if ralph_process_run_init "$2" "$3" "$5" plan; then
      exit 9
    fi
    RALPH_ALLOW_NESTED_RUNS=1
    export RALPH_ALLOW_NESTED_RUNS
    ralph_process_run_init "$2" "$3" "$5" plan
    [[ "$RALPH_PROCESS_RUN_DEPTH" == "1" ]]
    ralph_process_run_close nested-finished
  ' _ "$SUPERVISOR_LIB" "$STATE_ROOT" "$TEST_TMPDIR" "$PLAN_FILE" "$TEST_TMPDIR/NESTED.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nested Ralph runs are disabled"* ]]
}
