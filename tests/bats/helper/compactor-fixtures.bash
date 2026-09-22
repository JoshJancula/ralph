# Shared fixture harness for shell-output compactors.
# shellcheck shell=bash

COMPACTORS_LIB="${COMPACTORS_LIB:-$REPO_ROOT/bundle/.ralph/bash-lib/compactors.sh}"
FIXTURE_ROOT="${FIXTURE_ROOT:-$REPO_ROOT/tests/fixtures/compactors}"
JEV_FIXTURE_SRC="${JEV_FIXTURE_SRC:-$REPO_ROOT/tests/fixtures/jev}"

load_compactors() {
  # shellcheck source=/dev/null
  source "$COMPACTORS_LIB"
}

# Enable fixture-transport Jev compaction for one case. Optional arg is a
# fixture case dir whose jev-fixtures/ subdirectory overrides JEV_FIXTURE_DIR
# (used for transport-error replay).
enable_jev_compact_fixture_env() {
  local case_dir="${1-}"
  JEV_TEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/ralph-jev-compact.XXXXXX")"
  export RALPH_JEV_COMPACT=1
  export RALPH_JEV=1
  export JEV_TRANSPORT=fixture
  export TYPESAFE_API_KEY=test-key-for-fixture-transport
  export RALPH_JEV_STATE_DIR="$JEV_TEST_HOME/jev-state"
  mkdir -p "$RALPH_JEV_STATE_DIR"
  if [ -n "$case_dir" ] && [ -d "$case_dir/jev-fixtures" ]; then
    export JEV_FIXTURE_DIR="$case_dir/jev-fixtures"
  else
    export JEV_FIXTURE_DIR="$JEV_FIXTURE_SRC"
  fi
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

assert_compactor_preserves_fixture() {
  local case_name="$1"
  local fixture_dir="$FIXTURE_ROOT/$case_name"
  local fixture_command="" expected_stdout="" expected_stderr="" exit_status=""
  fixture_command="$(<"$fixture_dir/command.txt")"
  expected_stdout="$(<"$fixture_dir/stdout.txt")"
  expected_stderr="$(<"$fixture_dir/stderr.txt")"
  exit_status="$(<"$fixture_dir/exit_status.txt")"

  run bash -c '
    source "$1"
    export RALPH_COMPACT_STDOUT="$2"
    export RALPH_COMPACT_STDERR="$3"
    ralph_compact_shell_output "$4" "$5"
  ' _ "$COMPACTORS_LIB" "$expected_stdout" "$expected_stderr" "$fixture_command" "$exit_status"

  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e --arg stdout "$expected_stdout" --arg stderr "$expected_stderr" '
    .status == "not compacted"
    and .compacted == false
    and .stdout == $stdout
    and .stderr == $stderr
  '
}
