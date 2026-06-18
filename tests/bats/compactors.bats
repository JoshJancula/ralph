#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

COMPACTORS_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/compactors.sh"
FIXTURE_ROOT="$REPO_ROOT/tests/fixtures/compactors"

load_compactors() {
  # shellcheck source=/dev/null
  source "$COMPACTORS_LIB"
}

assert_compactor_fixture() {
  local case_name="$1"
  local fixture_dir="$FIXTURE_ROOT/$case_name"

  [ -d "$fixture_dir" ] || skip "fixture missing: $case_name"
  [ -f "$fixture_dir/result.json" ] || skip "pinned result missing: $case_name"

  if ! command -v python3 >/dev/null 2>&1; then
    skip "python3 required for compactor tests"
  fi

  local command stdout stderr exit_status expected actual
  command="$(<"$fixture_dir/command.txt")"
  stdout="$(<"$fixture_dir/stdout.txt")"
  stderr="$(<"$fixture_dir/stderr.txt")"
  exit_status="$(<"$fixture_dir/exit_status.txt")"
  expected="$(jq -S . <"$fixture_dir/result.json")"

  run bash -c '
    source "$1"
    export RALPH_COMPACT_STDOUT="$2"
    export RALPH_COMPACT_STDERR="$3"
    ralph_compact_shell_output "$4" "$5"
  ' _ "$COMPACTORS_LIB" "$stdout" "$stderr" "$command" "$exit_status"

  [ "$status" -eq 0 ]
  actual="$(printf '%s\n' "$output" | jq -S .)"
  [ "$actual" = "$expected" ]
}

@test "bats family: successful run matches pinned fixture" {
  assert_compactor_fixture bats-success
}

@test "bats family: failing run preserves failure diagnostics" {
  assert_compactor_fixture bats-failure
}

@test "git status family matches pinned fixture" {
  assert_compactor_fixture git-status
}

@test "git diff family: hunks compact to stat summary" {
  assert_compactor_fixture git-diff-hunks
}

@test "grep family matches pinned fixture" {
  assert_compactor_fixture grep-matches
}

@test "npm test family: passing run matches pinned fixture" {
  assert_compactor_fixture npm-test-passing
}

@test "no-match passthrough: unknown command" {
  assert_compactor_fixture no-match-unknown
  jq -e '.status == "not compacted" and .compacted == false and .family == null' \
    <"$FIXTURE_ROOT/no-match-unknown/result.json"
}

@test "binary output passes through unchanged" {
  assert_compactor_fixture binary-null-byte
  jq -e '.status == "not compacted"' <"$FIXTURE_ROOT/binary-null-byte/result.json"
}

@test "ralph_compact_shell_output_applied reflects compacted status" {
  load_compactors
  if ! command -v python3 >/dev/null 2>&1; then
    skip "python3 required for compactor tests"
  fi

  local compacted_line not_compacted_line
  export RALPH_COMPACT_STDOUT="$(<"$FIXTURE_ROOT/bats-success/stdout.txt")"
  export RALPH_COMPACT_STDERR=""
  compacted_line="$(ralph_compact_shell_output "$(<"$FIXTURE_ROOT/bats-success/command.txt")" 0)"
  export RALPH_COMPACT_STDOUT="$(<"$FIXTURE_ROOT/no-match-unknown/stdout.txt")"
  export RALPH_COMPACT_STDERR=""
  not_compacted_line="$(ralph_compact_shell_output "$(<"$FIXTURE_ROOT/no-match-unknown/command.txt")" 0)"

  ralph_compact_shell_output_applied "$compacted_line"
  ! ralph_compact_shell_output_applied "$not_compacted_line"
}
