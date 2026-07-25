#!/usr/bin/env bats
# Unit coverage for the shared native-hook fail-open debug writer (PLAN15).

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

DEBUG_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/native-hook/native-hook-debug.sh"

setup() {
  _tmp="$(mktemp -d)"
  # shellcheck source=/dev/null
  source "$DEBUG_LIB"
}

teardown() {
  rm -rf "$_tmp"
  unset RALPH_NATIVE_HOOK_DEBUG_LOG
}

@test "valid write produces one properly escaped JSONL line" {
  export RALPH_NATIVE_HOOK_DEBUG_LOG="$_tmp/debug.jsonl"
  run ralph_native_hook_debug_log "malformed_input" "claude:native_result_hook" "Read" 'quote " and newline-ish \n text'
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  [ -f "$RALPH_NATIVE_HOOK_DEBUG_LOG" ]
  run wc -l < "$RALPH_NATIVE_HOOK_DEBUG_LOG"
  [ "$(tr -d ' ' <<<"$output")" = "1" ]

  run jq -e . "$RALPH_NATIVE_HOOK_DEBUG_LOG"
  [ "$status" -eq 0 ]

  run jq -r '.reasonCode' "$RALPH_NATIVE_HOOK_DEBUG_LOG"
  [ "$output" = "malformed_input" ]
  run jq -r '.toolName' "$RALPH_NATIVE_HOOK_DEBUG_LOG"
  [ "$output" = "Read" ]
  run jq -r '.runtimeHook' "$RALPH_NATIVE_HOOK_DEBUG_LOG"
  [ "$output" = "claude:native_result_hook" ]
  run jq -r '.reason' "$RALPH_NATIVE_HOOK_DEBUG_LOG"
  [ "$output" = 'quote " and newline-ish \n text' ]
}

@test "unset log path is silent and creates nothing" {
  unset RALPH_NATIVE_HOOK_DEBUG_LOG
  run ralph_native_hook_debug_log "missing_jq" "claude:native_result_hook" "Read" "jq not found"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$_tmp/debug.jsonl" ]
}

@test "empty log path is silent and creates nothing" {
  export RALPH_NATIVE_HOOK_DEBUG_LOG=""
  run ralph_native_hook_debug_log "missing_jq" "claude:native_result_hook" "Read" "jq not found"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "unwritable path fails open silently" {
  local ro_dir="$_tmp/readonly"
  mkdir -p "$ro_dir"
  chmod 555 "$ro_dir"
  export RALPH_NATIVE_HOOK_DEBUG_LOG="$ro_dir/nested/debug.jsonl"
  run ralph_native_hook_debug_log "compaction_failed" "cursor:native_result_hook" "Grep" "store failed"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  chmod 755 "$ro_dir"
}

@test "two concurrent short appends both land without corruption" {
  export RALPH_NATIVE_HOOK_DEBUG_LOG="$_tmp/concurrent.jsonl"
  ( ralph_native_hook_debug_log "missing_workspace" "claude:native_result_hook" "Read" "no workspace" ) &
  local pid1=$!
  ( ralph_native_hook_debug_log "unrecognized_shape" "claude:native_result_hook" "Grep" "no text field" ) &
  local pid2=$!
  wait "$pid1"
  wait "$pid2"

  run wc -l < "$RALPH_NATIVE_HOOK_DEBUG_LOG"
  [ "$(tr -d ' ' <<<"$output")" = "2" ]

  while IFS= read -r line; do
    printf '%s' "$line" | jq -e . >/dev/null
  done < "$RALPH_NATIVE_HOOK_DEBUG_LOG"
}
