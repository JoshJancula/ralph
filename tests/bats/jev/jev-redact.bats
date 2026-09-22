#!/usr/bin/env bats
# Tests for bundle/.ralph/bash-lib/jev/jev-redact.sh

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

REDACT_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/jev/jev-redact.sh"

setup() {
  command -v jq >/dev/null || skip "jq required"
  [ -f "$REDACT_LIB" ] || skip "jev-redact.sh missing"
}

@test "jev_redact_state preserves multi-line line count" {
  local count
  run bash -c '
    source "$1"
    printf "%s" "line-one
line-two
line-three" | jev_redact_state
  ' _ "$REDACT_LIB"
  [ "$status" -eq 0 ]
  count="$(printf '%s' "$output" | grep -c '^')"
  [ "$count" -eq 3 ]
}

@test "jev_redact_state redacts env-dump assignment values" {
  run bash -c '
    source "$1"
    printf "%s" "FOO_BAR_XYZ=supersecretvalue99" | jev_redact_state
  ' _ "$REDACT_LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"FOO_BAR_XYZ=[REDACTED]"* ]]
  [[ "$output" != *"supersecretvalue99"* ]]
}

@test "jev_redact_state redacts bearer credential assignment" {
  run bash -c '
    source "$1"
    printf "%s" "bearer: my-bearer-secret-token99" | jev_redact_state
  ' _ "$REDACT_LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[REDACTED]"* ]]
  [[ "$output" != *"my-bearer-secret-token99"* ]]
}

@test "jev_redact_state redacts sk- prefixed keys" {
  run bash -c '
    source "$1"
    printf "%s" "key=sk-abcdefghijklmnopqrstuvwxyz" | jev_redact_state
  ' _ "$REDACT_LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[REDACTED]"* ]]
  [[ "$output" != *"sk-abcdefghijklmnopqrstuvwxyz"* ]]
}

@test "jev_redact_state rewrites absolute HOME path to tilde" {
  run env HOME="/tmp/jev-redact-home-fixture" bash -c '
    source "$1"
    printf "%s" "path=/tmp/jev-redact-home-fixture/project/file.txt" | jev_redact_state
  ' _ "$REDACT_LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"~/project/file.txt"* ]]
  [[ "$output" != *"/tmp/jev-redact-home-fixture"* ]]
}

@test "jev_redact_state redacts TYPESAFE_API_KEY values" {
  run env TYPESAFE_API_KEY="typesafe-secret-xyz-999" bash -c '
    source "$1"
    printf "%s" "header typesafe-secret-xyz-999 trailing" | jev_redact_state
  ' _ "$REDACT_LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[REDACTED]"* ]]
  [[ "$output" != *"typesafe-secret-xyz-999"* ]]
}

@test "jev_redact_state preserves ordinary non-secret signal text" {
  run bash -c '
    source "$1"
    printf "%s" "ok JEV_DISTINCTIVE_SIGNAL_TOKEN_abc123 ready" | jev_redact_state
  ' _ "$REDACT_LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"JEV_DISTINCTIVE_SIGNAL_TOKEN_abc123"* ]]
}

@test "jev_redact_state forced failure returns rc 1 with empty stdout" {
  run bash -c '
    source "$1"
    _jev_redact_file() { return 1; }
    printf "%s" "should-not-leak" | jev_redact_state
  ' _ "$REDACT_LIB"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}
