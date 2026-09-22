#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"
# shellcheck source=helper/compactor-fixtures.bash
source "$BATS_TEST_DIRNAME/helper/compactor-fixtures.bash"

setup() {
  # Keep default-off: Jev-enabled cases in sibling files must not leak here.
  unset RALPH_JEV_COMPACT RALPH_JEV JEV_TRANSPORT JEV_FIXTURE_DIR TYPESAFE_API_KEY RALPH_JEV_STATE_DIR \
    RALPH_COMPACT_GENERIC_FALLBACK RALPH_COMPACT_FAILURE 2>/dev/null || true
  JEV_TEST_HOME=""
}

teardown() {
  if [ -n "${JEV_TEST_HOME:-}" ] && [ -d "$JEV_TEST_HOME" ]; then
    rm -rf "$JEV_TEST_HOME"
  fi
  unset JEV_TEST_HOME
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

@test "git diff source remains verbatim" {
  assert_compactor_preserves_fixture git-diff-hunks
}

@test "grep search output remains verbatim" {
  assert_compactor_preserves_fixture grep-matches
}

@test "npm test family: passing run matches pinned fixture" {
  assert_compactor_fixture npm-test-passing
}

@test "npm install family: successful run compacts dependency output" {
  assert_compactor_fixture npm-install-success
}

@test "pip install family: failure preserves error details" {
  assert_compactor_fixture pip-install-failure
}

@test "cargo build family: successful run compacts build output" {
  assert_compactor_fixture cargo-build-success
}

@test "cargo build family: failure preserves compiler errors" {
  assert_compactor_fixture cargo-build-failure
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
