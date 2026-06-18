#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

CORE_FILE="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-core.sh"

# Extract just the numeric sanitizer so it can be exercised in isolation.
setup() {
  TMPDIR_LOCAL="$(mktemp -d)"
  FUNC_FILE="$TMPDIR_LOCAL/num.sh"
  sed -n '/^run_plan_num_or_zero() {/,/^}$/p' "$CORE_FILE" >"$FUNC_FILE"
}

teardown() {
  rm -rf "$TMPDIR_LOCAL"
}

@test "run_plan_num_or_zero passes through plain integers" {
  run bash -c 'source "$1"; run_plan_num_or_zero "23"' _ "$FUNC_FILE"
  [ "$status" -eq 0 ]
  [ "$output" = "23" ]
}

@test "run_plan_num_or_zero preserves decimals (cache ratios)" {
  run bash -c 'source "$1"; run_plan_num_or_zero "0.826"' _ "$FUNC_FILE"
  [ "$output" = "0.826" ]
}

@test "run_plan_num_or_zero zeroes whitespace-bearing values" {
  run bash -c 'source "$1"; run_plan_num_or_zero "23 25"' _ "$FUNC_FILE"
  [ "$output" = "0" ]
}

@test "run_plan_num_or_zero zeroes empty values" {
  run bash -c 'source "$1"; run_plan_num_or_zero ""' _ "$FUNC_FILE"
  [ "$output" = "0" ]
}

@test "sanitized fields produce valid summary JSON even with malformed counts" {
  command -v python3 >/dev/null 2>&1 || skip "python3 required"
  # Simulate the historical corruption: todos_done held "23 25" and todos_total
  # was empty. After sanitization the emitted JSON must parse.
  run bash -c '
    set -euo pipefail
    source "$1"
    _done="$(run_plan_num_or_zero "23 25")"
    _total="$(run_plan_num_or_zero "")"
    printf "{\"todos_done\":%s,\"todos_total\":%s}\n" "$_done" "$_total"
  ' _ "$FUNC_FILE"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d=={"todos_done":0,"todos_total":0}, d'
}
