#!/usr/bin/env bats
# shellcheck shell=bash

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

RUN_PLAN_SESSION_FILE="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan-session.sh"
RUN_PLAN_INVOKE_CLAUDE_FILE="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan-invoke-claude.sh"

@test "ralph_session_apply_resume_strategy pre-generates a UUID then resumes it on the next call" {
  [ -f "$RUN_PLAN_SESSION_FILE" ] || skip "run-plan session helper missing"
  [ -f "$RUN_PLAN_INVOKE_CLAUDE_FILE" ] || skip "run-plan claude helper missing"

  local tmpdir bin_dir
  tmpdir="$(mktemp -d)"
  bin_dir="$tmpdir/bin"
  mkdir -p "$bin_dir"

  cat <<'EOF' >"$bin_dir/uuidgen"
#!/bin/bash
printf '%s\n' "11111111-1111-4111-8111-111111111111"
EOF
  chmod +x "$bin_dir/uuidgen"

  run bash -c '
    set -euo pipefail
    ralph_run_plan_log(){ :; }
    source "$1"
    source "$2"
    PATH="$3:$PATH"
    SESSION_ID_FILE="$4/session-id.claude.txt"
    mkdir -p "$(dirname "$SESSION_ID_FILE")"
    export SESSION_ID_FILE PATH
    RALPH_PLAN_CLI_RESUME=1
    export RALPH_PLAN_CLI_RESUME
    unset RESUME_SESSION_ID_OVERRIDE RALPH_RUN_PLAN_RESUME_SESSION_ID RALPH_RUN_PLAN_NEW_SESSION_ID RALPH_RUN_PLAN_RESUME_BARE

    ralph_session_apply_resume_strategy
    first_new="${RALPH_RUN_PLAN_NEW_SESSION_ID:-}"
    first_resume="${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}"
    first_file="$(cat "$SESSION_ID_FILE")"
    first_args=()
    run_plan_invoke_claude_session_new_args first_args

    ralph_session_apply_resume_strategy
    second_new="${RALPH_RUN_PLAN_NEW_SESSION_ID:-}"
    second_resume="${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}"
    second_args=()
    run_plan_invoke_claude_session_resume_args second_args

    printf "FIRST_NEW=%s\n" "$first_new"
    printf "FIRST_RESUME=%s\n" "$first_resume"
    printf "FIRST_FILE=%s\n" "$first_file"
    printf "FIRST_ARG0=%s\n" "${first_args[0]}"
    printf "FIRST_ARG1=%s\n" "${first_args[1]}"
    printf "SECOND_NEW=%s\n" "$second_new"
    printf "SECOND_RESUME=%s\n" "$second_resume"
    printf "SECOND_FILE=%s\n" "$(cat "$SESSION_ID_FILE")"
    printf "SECOND_ARG0=%s\n" "${second_args[0]}"
    printf "SECOND_ARG1=%s\n" "${second_args[1]}"
  ' _ "$RUN_PLAN_SESSION_FILE" "$RUN_PLAN_INVOKE_CLAUDE_FILE" "$bin_dir" "$tmpdir"

  [ "$status" -eq 0 ]
  [[ "$output" == *"FIRST_NEW=11111111-1111-4111-8111-111111111111"* ]]
  [[ "$output" == *"FIRST_RESUME="* ]]
  [[ "$output" == *"FIRST_FILE=11111111-1111-4111-8111-111111111111"* ]]
  [[ "$output" == *"FIRST_ARG0=--session-id"* ]]
  [[ "$output" == *"FIRST_ARG1=11111111-1111-4111-8111-111111111111"* ]]
  [[ "$output" == *"SECOND_NEW="* ]]
  [[ "$output" == *"SECOND_RESUME=11111111-1111-4111-8111-111111111111"* ]]
  [[ "$output" == *"SECOND_FILE=11111111-1111-4111-8111-111111111111"* ]]
  [[ "$output" == *"SECOND_ARG0=--resume"* ]]
  [[ "$output" == *"SECOND_ARG1=11111111-1111-4111-8111-111111111111"* ]]

  rm -rf "$tmpdir"
}

@test "ralph_session_maybe_rotate clears the stored id so the next call generates a new one" {
  [ -f "$RUN_PLAN_SESSION_FILE" ] || skip "run-plan session helper missing"
  [ -f "$RUN_PLAN_INVOKE_CLAUDE_FILE" ] || skip "run-plan claude helper missing"

  local tmpdir bin_dir
  tmpdir="$(mktemp -d)"
  bin_dir="$tmpdir/bin"
  mkdir -p "$bin_dir"

  cat <<'EOF' >"$bin_dir/uuidgen"
#!/bin/bash
printf '%s\n' "22222222-2222-4222-8222-222222222222"
EOF
  chmod +x "$bin_dir/uuidgen"

  run bash -c '
    set -euo pipefail
    ralph_run_plan_log(){ :; }
    source "$1"
    source "$2"
    PATH="$3:$PATH"
    RALPH_SESSION_DIR="$4"
    SESSION_ID_FILE="$4/session-id.claude.txt"
    export RALPH_SESSION_DIR SESSION_ID_FILE PATH
    RALPH_PLAN_CLI_RESUME=1
    export RALPH_PLAN_CLI_RESUME

    printf "%s\n" "old-uuid" > "$SESSION_ID_FILE"
    printf "%s\n" "1" > "$RALPH_SESSION_DIR/session-turn-count.txt"
    ralph_session_maybe_rotate 1
    [[ ! -e "$SESSION_ID_FILE" ]]

    ralph_session_apply_resume_strategy
    printf "NEW=%s\n" "${RALPH_RUN_PLAN_NEW_SESSION_ID:-}"
    printf "RESUME=%s\n" "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}"
    printf "FILE=%s\n" "$(cat "$SESSION_ID_FILE")"
  ' _ "$RUN_PLAN_SESSION_FILE" "$RUN_PLAN_INVOKE_CLAUDE_FILE" "$bin_dir" "$tmpdir"

  [ "$status" -eq 0 ]
  [[ "$output" == *"NEW=22222222-2222-4222-8222-222222222222"* ]]
  [[ "$output" == *"RESUME="* ]]
  [[ "$output" == *"FILE=22222222-2222-4222-8222-222222222222"* ]]

  rm -rf "$tmpdir"
}

@test "ralph_session_apply_resume_strategy skips UUID generation when CLI resume is disabled" {
  [ -f "$RUN_PLAN_SESSION_FILE" ] || skip "run-plan session helper missing"
  [ -f "$RUN_PLAN_INVOKE_CLAUDE_FILE" ] || skip "run-plan claude helper missing"

  local tmpdir bin_dir call_count
  tmpdir="$(mktemp -d)"
  bin_dir="$tmpdir/bin"
  call_count="$tmpdir/uuidgen.count"
  mkdir -p "$bin_dir"

  cat <<EOF >"$bin_dir/uuidgen"
#!/bin/bash
count=0
if [[ -f "$call_count" ]]; then
  count="\$(cat "$call_count")"
fi
count=\$((count + 1))
printf '%s\n' "\$count" > "$call_count"
printf '%s\n' "33333333-3333-4333-8333-333333333333"
EOF
  chmod +x "$bin_dir/uuidgen"

  run bash -c '
    set -euo pipefail
    ralph_run_plan_log(){ :; }
    source "$1"
    source "$2"
    PATH="$3:$PATH"
    SESSION_ID_FILE="$4/session-id.claude.txt"
    export SESSION_ID_FILE PATH
    RALPH_PLAN_CLI_RESUME=0
    export RALPH_PLAN_CLI_RESUME
    unset RESUME_SESSION_ID_OVERRIDE RALPH_RUN_PLAN_RESUME_SESSION_ID RALPH_RUN_PLAN_NEW_SESSION_ID RALPH_RUN_PLAN_RESUME_BARE

    ralph_session_apply_resume_strategy
    args=()
    if [[ -n "${RALPH_RUN_PLAN_NEW_SESSION_ID:-}" ]]; then
      run_plan_invoke_claude_session_new_args args
    fi

    printf "NEW=%s\n" "${RALPH_RUN_PLAN_NEW_SESSION_ID:-}"
    printf "RESUME=%s\n" "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}"
    printf "ARGC=%s\n" "${#args[@]}"
    printf "FILE_EXISTS=%s\n" "$([[ -e "$SESSION_ID_FILE" ]] && echo yes || echo no)"
    printf "COUNT_EXISTS=%s\n" "$([[ -e "$5" ]] && echo yes || echo no)"
  ' _ "$RUN_PLAN_SESSION_FILE" "$RUN_PLAN_INVOKE_CLAUDE_FILE" "$bin_dir" "$tmpdir" "$call_count"

  [ "$status" -eq 0 ]
  [[ "$output" == *"NEW="* ]]
  [[ "$output" == *"RESUME="* ]]
  [[ "$output" == *"ARGC=0"* ]]
  [[ "$output" == *"FILE_EXISTS=no"* ]]
  [[ "$output" == *"COUNT_EXISTS=no"* ]]

  rm -rf "$tmpdir"
}
