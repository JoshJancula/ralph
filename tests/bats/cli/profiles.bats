#!/usr/bin/env bats
# Public ralph profiles CLI: list / show / reset learned command profiles.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

PROFILES_CLI="$REPO_ROOT/bundle/.ralph/bash-lib/profiles/profiles-cli.sh"

setup() {
  TEST_WORKSPACE="$(mktemp -d)"
  export RALPH_HOME="$REPO_ROOT"
}

teardown() {
  rm -rf "$TEST_WORKSPACE"
}

_seed_entry() {
  local fingerprint="$1"
  local command="$2"
  local duration_ms="$3"
  python3 -c "
import sys
sys.path.insert(0, '$REPO_ROOT/bundle/.ralph/python')
from pathlib import Path
from command_profiles import record_observation
record_observation(Path(sys.argv[1]), sys.argv[2], sys.argv[3], int(sys.argv[4]))
" "$TEST_WORKSPACE/.ralph-workspace" "$fingerprint" "$command" "$duration_ms"
}

_run_profiles() {
  env RALPH_HOME="$REPO_ROOT" bash "$PROFILES_CLI" "$@" --workspace "$TEST_WORKSPACE"
}

@test "ralph profiles list on an empty store" {
  run _run_profiles list
  [ "$status" -eq 0 ]
  [[ "$output" == *"(no learned command profiles)"* ]]
}

@test "ralph profiles list after seeding two entries sorts by median descending" {
  _seed_entry "fp-slow-aaaaaaaa" "bash scripts/run-bats.sh" 120000
  _seed_entry "fp-fast-bbbbbbbb" "ls -la" 500

  run _run_profiles list
  [ "$status" -eq 0 ]
  [[ "$output" == *"median_s"* ]]
  [[ "$output" == *"fp-slow-aaaaaaaa"* ]]
  [[ "$output" == *"fp-fast-bbbbbbbb"* ]]
  [[ "$output" == *"run-bats"* ]]
  [[ "$output" == *"ls -la"* ]]

  # Slow entry (120s median) must appear before the fast one.
  slow_line="$(printf '%s\n' "$output" | grep -n 'fp-slow-aaaaaaaa' | head -1 | cut -d: -f1)"
  fast_line="$(printf '%s\n' "$output" | grep -n 'fp-fast-bbbbbbbb' | head -1 | cut -d: -f1)"
  [ "$slow_line" -lt "$fast_line" ]
  [[ "$output" == *"120.0"* ]]
  [[ "$output" == *"yes"* ]]  # long_running for the 120s entry
}

@test "ralph profiles show by fingerprint prefix prints full record" {
  _seed_entry "fp-show-cccccccc" "pytest tests/python" 90000
  # Promote history: second observation keeps long_running / promoted_at.
  _seed_entry "fp-show-cccccccc" "pytest tests/python" 95000

  run _run_profiles show fp-show
  [ "$status" -eq 0 ]
  [[ "$output" == *"fingerprint: fp-show-cccccccc"* ]]
  [[ "$output" == *"observation_count: 2"* ]]
  [[ "$output" == *"durations_ms:"* ]]
  [[ "$output" == *"90000"* ]]
  [[ "$output" == *"95000"* ]]
  [[ "$output" == *"long_running: yes"* ]]
  [[ "$output" == *"promoted_at:"* ]]
  [[ "$output" == *"median_s:"* ]]
}

@test "ralph profiles reset of a single entry removes only that entry" {
  _seed_entry "fp-keep-dddddddd" "echo keep" 1000
  _seed_entry "fp-drop-eeeeeeee" "echo drop" 2000

  run _run_profiles reset fp-drop
  [ "$status" -eq 0 ]
  [[ "$output" == *"Reset profile fp-drop-eeeeeeee"* ]]

  run _run_profiles list
  [ "$status" -eq 0 ]
  [[ "$output" == *"fp-keep-dddddddd"* ]]
  [[ "$output" != *"fp-drop-eeeeeeee"* ]]
}

@test "ralph profiles reset whole store refuses non-interactively without --yes" {
  _seed_entry "fp-wipe-ffffffff" "echo wipe" 1000

  run _run_profiles reset </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires --yes"* ]] || [[ "$stderr" == *"requires --yes"* ]]

  run _run_profiles list
  [ "$status" -eq 0 ]
  [[ "$output" == *"fp-wipe-ffffffff"* ]]
}

@test "ralph profiles help mentions list show and reset" {
  run env RALPH_HOME="$REPO_ROOT" bash "$PROFILES_CLI" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"ralph profiles"* ]]
  [[ "$output" == *"list"* ]]
  [[ "$output" == *"show"* ]]
  [[ "$output" == *"reset"* ]]
  [[ "$output" == *"--yes"* ]]
}
