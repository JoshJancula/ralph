#!/usr/bin/env bats

# Regression tests for the setsid pgid race: launching an isolated job and
# reading its pgid before the child's setsid() completed used to capture the
# launcher's own process group. A later timeout group-kill then terminated
# the launcher itself -- inside the MCP server that killed the stdio
# transport and dropped every ralph tool mid-session.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

WRAPPER_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/native-hook/native-shell-wrapper.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

@test "isolated launch records a pgid distinct from the launcher's own" {
  command -v setsid >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || \
    skip "no setsid or python3 for isolated launch"

  run bash -c '
    source "$1"
    my_pgid="$(ralph_native_shell_process_pgid $$)"
    ralph_native_shell_launch_process_group "$2" "sleep 2" bash /dev/null /dev/null
    child_pgid="$RALPH_NATIVE_SHELL_LAUNCH_PGID"
    isolated="$RALPH_NATIVE_SHELL_LAUNCH_ISOLATED"
    kill -TERM "$RALPH_NATIVE_SHELL_LAUNCH_PID" 2>/dev/null || true
    if [ "$isolated" = "true" ] && [ "$child_pgid" = "$my_pgid" ]; then
      echo "FAIL: isolated job shares launcher pgid $my_pgid"
      exit 1
    fi
    echo "ok my=$my_pgid child=$child_pgid isolated=$isolated"
  ' _ "$WRAPPER_LIB" "$TEST_TMPDIR"

  [ "$status" -eq 0 ]
  [[ "$output" == ok* ]]
}

@test "sync timeout kill does not terminate the invoking shell" {
  command -v jq >/dev/null 2>&1 || skip "jq required"

  # Before the fix this invocation died with SIGTERM from its own group-kill
  # instead of returning the timeout JSON.
  run bash -c '
    source "$1"
    result="$(ralph_native_shell_execute_command_json "$2" "sleep 10; echo late" bash 1)"
    printf "ALIVE %s\n" "$result"
  ' _ "$WRAPPER_LIB" "$TEST_TMPDIR"

  [ "$status" -eq 0 ]
  [[ "$output" == ALIVE* ]]
  local json="${output#ALIVE }"
  [ "$(jq -r '.timedOut' <<<"$json")" = "true" ]
  [ "$(jq -r '.exitCode' <<<"$json")" = "124" ]
}

@test "terminate_spawned_job refuses to group-kill the caller's own pgid" {
  run bash -c '
    source "$1"
    my_pgid="$(ralph_native_shell_process_pgid $$)"
    sleep 30 &
    job_pid=$!
    # Deliberately pass our own pgid with isolated=true, simulating the race.
    escalated="$(ralph_native_shell_terminate_spawned_job "$job_pid" "$my_pgid" true 1)"
    echo "SURVIVED escalated=$escalated"
  ' _ "$WRAPPER_LIB"

  [ "$status" -eq 0 ]
  [[ "$output" == SURVIVED* ]]
}
