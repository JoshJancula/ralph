#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

LIB="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-bg-job-state.sh"

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  TEST_TMPDIR="$(mktemp -d)"
  export RALPH_SESSION_DIR="$TEST_TMPDIR/session"
  export RALPH_PROJECT_ROOT="$TEST_TMPDIR/project"
  export RALPH_PLAN_WORKSPACE_ROOT="$TEST_TMPDIR/state"
  export RALPH_AGENT_WORKSPACE="$TEST_TMPDIR/project"
  export RALPH_PLAN_KEY="bg-job-test"
  export RUNTIME="cursor"
  export RALPH_PROCESS_RUN_ID="run-abc"
  export RALPH_CURRENT_TODO_LINE="1"
  export RALPH_CURRENT_TODO_ORDINAL="1"
  export RALPH_CURRENT_TODO_ID="todo-1"
  export RALPH_CURRENT_TODO_HASH="hash-abc123"
  export RALPH_BG_MAX_PER_TODO=8
  mkdir -p "$RALPH_SESSION_DIR"
  # shellcheck disable=SC1090
  source "$LIB"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

bg_job_seed_identity() {
  export RALPH_PROCESS_RUN_ID="${1:-run-abc}"
  export RALPH_CURRENT_TODO_HASH="${2:-hash-abc123}"
  export RALPH_WORKFLOW_STAGE_ATTEMPT="${3:-}"
}

bg_job_advance_to_terminal() {
  local job_id="${1:-job-1}"
  local terminal_status="${2:-passed}"
  ralph_bg_job_create "$job_id" "echo hello" "test" 3600 1 "$$" >/dev/null
  ralph_bg_job_mark_launched "$job_id" "$$" "setsid" "true" >/dev/null
  ralph_bg_job_mark_running "$job_id" >/dev/null
  ralph_bg_job_mark_terminal "$job_id" "$terminal_status" >/dev/null
}

@test "create writes schema_version 1 requested record with identity and command hash" {
  bg_job_seed_identity
  local record hash
  record="$(ralph_bg_job_create "job-1" "echo hello" "test-surface" 3600 1 "$$")"
  [ "$?" -eq 0 ]
  run jq -r '.schema_version' <<<"$record"
  [ "$output" = "1" ]
  run jq -r '.state' <<<"$record"
  [ "$output" = "requested" ]
  run jq -r '.identity.planKey' <<<"$record"
  [ "$output" = "bg-job-test" ]
  run jq -r '.identity.runId' <<<"$record"
  [ "$output" = "run-abc" ]
  hash="$(ralph_bg_job_command_hash "echo hello")"
  run jq -r '.command_hash' <<<"$record"
  [ "$output" = "$hash" ]
}

@test "meta.json is written mode 0600 via atomic temp then mv" {
  bg_job_seed_identity
  ralph_bg_job_create "job-mode" "true" "test" 60 1 "$$" >/dev/null
  local meta mode
  meta="$(ralph_bg_job_meta_path "job-mode")"
  [ -f "$meta" ]
  # GNU coreutils first -- see the todo-session manifest mode test.
  mode="$(stat -c '%a' "$meta" 2>/dev/null || stat -f '%OLp' "$meta")"
  [ "$mode" = "600" ]
}

@test "read returns validated record for current identity" {
  bg_job_seed_identity
  ralph_bg_job_create "job-read" "sleep 1" "test" 120 1 "$$" >/dev/null
  run ralph_bg_job_read "job-read"
  [ "$status" -eq 0 ]
  run jq -r '.job_id' <<<"$output"
  [ "$output" = "job-read" ]
}

@test "state machine advances requested -> launched -> running -> terminal -> consumed" {
  bg_job_seed_identity
  local record
  record="$(ralph_bg_job_create "job-flow" "echo ok" "test" 3600 1 "$$")"
  run jq -r '.state' <<<"$record"
  [ "$output" = "requested" ]

  record="$(ralph_bg_job_mark_launched "job-flow" 4242 "setsid" "true")"
  run jq -r '.state' <<<"$record"
  [ "$output" = "launched" ]
  run jq -r '.launch_mode' <<<"$record"
  [ "$output" = "setsid" ]
  run jq -r '.isolated' <<<"$record"
  [ "$output" = "true" ]

  record="$(ralph_bg_job_mark_running "job-flow")"
  run jq -r '.state' <<<"$record"
  [ "$output" = "running" ]

  record="$(ralph_bg_job_mark_terminal "job-flow" "passed")"
  run jq -r '.state,.terminal_status' <<<"$record"
  [ "${lines[0]}" = "terminal" ]
  [ "${lines[1]}" = "passed" ]

  record="$(ralph_bg_job_consume "job-flow")"
  run jq -r '.state,.consumed_at' <<<"$record"
  [ "${lines[0]}" = "consumed" ]
  [[ -n "${lines[1]}" ]]
}

@test "reject invalid state transition requested -> terminal" {
  bg_job_seed_identity
  ralph_bg_job_create "job-bad-x" "echo x" "test" 60 1 "$$" >/dev/null
  run ralph_bg_job_mark_terminal "job-bad-x" "failed"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires running state"* ]]
}

@test "reject malformed record missing schema_version on write" {
  bg_job_seed_identity
  local meta bad
  meta="$(ralph_bg_job_meta_path "job-malformed")"
  mkdir -p "$(dirname "$meta")"
  bad='{"job_id":"job-malformed","state":"requested","command":"x","command_hash":"abc","source_surface":"t","timeout_seconds":1,"owner_pid":1,"owner_process_start_id":"x","tier":1,"identity":{}}'
  ralph_bg_job_atomic_write_meta "$meta" "$bad"
  run ralph_bg_job_read "job-malformed"
  [ "$status" -ne 0 ]
  [[ "$output" == *"malformed-record"* ]]
}

@test "reject mismatched TODO hash on read" {
  bg_job_seed_identity "run-abc" "hash-original"
  ralph_bg_job_create "job-hash" "echo x" "test" 60 1 "$$" >/dev/null
  export RALPH_CURRENT_TODO_HASH="hash-different"
  run ralph_bg_job_read "job-hash"
  [ "$status" -ne 0 ]
  [[ "$output" == *"mismatched-todo-hash"* ]]
}

@test "reject foreign run id on read" {
  bg_job_seed_identity "run-original"
  ralph_bg_job_create "job-run" "echo x" "test" 60 1 "$$" >/dev/null
  export RALPH_PROCESS_RUN_ID="run-foreign"
  run ralph_bg_job_read "job-run"
  [ "$status" -ne 0 ]
  [[ "$output" == *"foreign-run-id"* ]]
}

@test "reject mismatched workflow attempt on read" {
  bg_job_seed_identity "run-abc" "hash-abc123" "attempt-1"
  export RALPH_WORKFLOW_RUN_ID="wf-run"
  export RALPH_WORKFLOW_STAGE_ID="stage-a"
  ralph_bg_job_create "job-wf" "echo x" "test" 60 1 "$$" >/dev/null
  export RALPH_WORKFLOW_STAGE_ATTEMPT="attempt-2"
  run ralph_bg_job_read "job-wf"
  [ "$status" -ne 0 ]
  [[ "$output" == *"mismatched-workflow-attempt"* ]]
}

@test "reject replay of consumed record on read and transition" {
  bg_job_seed_identity
  bg_job_advance_to_terminal "job-replay" "passed"
  ralph_bg_job_consume "job-replay" >/dev/null
  run ralph_bg_job_read "job-replay"
  [ "$status" -ne 0 ]
  [[ "$output" == *"already consumed"* ]]
  run ralph_bg_job_consume "job-replay"
  [ "$status" -ne 0 ]
}

@test "reject non-isolated launch" {
  bg_job_seed_identity
  ralph_bg_job_create "job-iso" "echo x" "test" 60 1 "$$" >/dev/null
  run ralph_bg_job_mark_launched "job-iso" 9999 "plain" "false"
  [ "$status" -ne 0 ]
  [[ "$output" == *"non-isolated"* ]]
}

@test "reject create when outstanding jobs reach RALPH_BG_MAX_PER_TODO" {
  bg_job_seed_identity
  export RALPH_BG_MAX_PER_TODO=2
  ralph_bg_job_create "cap-1" "echo 1" "test" 60 1 "$$" >/dev/null
  ralph_bg_job_create "cap-2" "echo 2" "test" 60 1 "$$" >/dev/null
  run ralph_bg_job_create "cap-3" "echo 3" "test" 60 1 "$$"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cap exceeded"* ]]
}

@test "terminal jobs do not count toward outstanding cap" {
  bg_job_seed_identity
  export RALPH_BG_MAX_PER_TODO=2
  bg_job_advance_to_terminal "cap-term-1" "passed"
  ralph_bg_job_create "cap-term-2" "echo 2" "test" 60 1 "$$" >/dev/null
  run ralph_bg_job_create "cap-term-3" "echo 3" "test" 60 1 "$$"
  [ "$status" -eq 0 ]
}

@test "reject invalid terminal status values" {
  bg_job_seed_identity
  ralph_bg_job_create "job-bad-term" "echo x" "test" 60 1 "$$" >/dev/null
  ralph_bg_job_mark_launched "job-bad-term" 1111 "setsid" "true" >/dev/null
  ralph_bg_job_mark_running "job-bad-term" >/dev/null
  run ralph_bg_job_mark_terminal "job-bad-term" "exploded"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid background job terminal status"* ]]
}

@test "all six terminal statuses are accepted" {
  bg_job_seed_identity
  local term_status job_id
  for term_status in passed failed timed_out cancelled interrupted unknown; do
    job_id="term-$term_status"
    ralph_bg_job_create "$job_id" "echo $term_status" "test" 60 1 "$$" >/dev/null
    ralph_bg_job_mark_launched "$job_id" 2000 "setsid" "true" >/dev/null
    ralph_bg_job_mark_running "$job_id" >/dev/null
    run ralph_bg_job_mark_terminal "$job_id" "$term_status"
    [ "$status" -eq 0 ]
    run jq -r '.terminal_status' <<<"$output"
    [ "$output" = "$term_status" ]
  done
}

@test "owner pid and process start id are recorded at create" {
  bg_job_seed_identity
  local record
  record="$(ralph_bg_job_create "job-owner" "echo owner" "test" 60 1 "$$")"
  run jq -r '.owner_pid' <<<"$record"
  [ "$output" = "$$" ]
  run jq -r '.owner_process_start_id' <<<"$record"
  [[ -n "$output" ]]
}
