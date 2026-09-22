#!/usr/bin/env bats
source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

CHECK="$REPO_ROOT/scripts/bats-regression-check.sh"

write_suite() {
  local path="$1" body="$2"
  printf '%s\n' '#!/usr/bin/env bats' "$body" >"$path"
}

@test "bats regression check accepts a suite with no failures" {
  local suite baseline
  suite="$BATS_TEST_TMPDIR/passing.bats"
  baseline="$BATS_TEST_TMPDIR/baseline.txt"
  write_suite "$suite" '@test "passes" { true; }'
  : >"$baseline"
  run env RALPH_ARTIFACT_NS="bats-regression-check-$BATS_TEST_NUMBER" bash "$CHECK" --baseline "$baseline" "$suite"
  [ "$status" -eq 0 ]
  [[ "$output" == *"exit=0 new_failures=0 log="* ]]
}

@test "bats regression check accepts a baseline failure" {
  local suite baseline
  suite="$BATS_TEST_TMPDIR/baseline-failure.bats"
  baseline="$BATS_TEST_TMPDIR/baseline.txt"
  write_suite "$suite" '@test "known failure" { false; }'
  printf '%s::%s\n' "${suite##*/}" 'known failure' >"$baseline"
  run env RALPH_ARTIFACT_NS="bats-regression-check-$BATS_TEST_NUMBER" bash "$CHECK" --baseline "$baseline" "$suite"
  [ "$status" -eq 0 ]
}

@test "bats regression check reports a new failure" {
  local suite baseline
  suite="$BATS_TEST_TMPDIR/new-failure.bats"
  baseline="$BATS_TEST_TMPDIR/baseline.txt"
  write_suite "$suite" '@test "new failure" { false; }'
  : >"$baseline"
  run env RALPH_ARTIFACT_NS="bats-regression-check-$BATS_TEST_NUMBER" bash "$CHECK" --baseline "$baseline" "$suite"
  [ "$status" -eq 1 ]
  [[ "$output" == *"${suite##*/}::new failure"* ]]
}

@test "bats regression check rejects zero executed tests" {
  local suite baseline
  suite="$BATS_TEST_TMPDIR/empty.bats"
  baseline="$BATS_TEST_TMPDIR/baseline.txt"
  printf '%s\n' '#!/usr/bin/env bats' >"$suite"
  : >"$baseline"
  run env RALPH_ARTIFACT_NS="bats-regression-check-$BATS_TEST_NUMBER" bash "$CHECK" --baseline "$baseline" "$suite"
  [ "$status" -eq 1 ]
  [[ "$output" == *"zero tests executed"* ]]
}

@test "bats regression check rejects a missing baseline" {
  local suite
  suite="$BATS_TEST_TMPDIR/passing.bats"
  write_suite "$suite" '@test "passes" { true; }'
  run bash "$CHECK" --baseline "$BATS_TEST_TMPDIR/missing.txt" "$suite"
  [ "$status" -eq 2 ]
}
