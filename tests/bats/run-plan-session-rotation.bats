#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

RUN_PLAN_SESSION_FILE="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan-session.sh"

@test "threshold 0 means no rotation after any number of bumps" {
  [ -f "$RUN_PLAN_SESSION_FILE" ] || skip "run-plan session helper missing"

  local tmpdir
  tmpdir="$(mktemp -d)"
  export RALPH_SESSION_DIR="$tmpdir"

  # Create fake session files
  touch "$tmpdir/session-id.claude.txt"
  echo "test-session-id" > "$tmpdir/session-id.claude.txt"

  run bash -c '
    set -euo pipefail
    source "$1"
    # Bump 5 times with threshold 0
    for i in 1 2 3 4 5; do
      ralph_session_bump_turn_counter
    done
    # Check rotation with threshold 0
    ralph_session_maybe_rotate 0
    # Files should still exist
    [[ -f "$RALPH_SESSION_DIR/session-id.claude.txt" ]] || exit 1
    [[ -f "$RALPH_SESSION_DIR/session-turn-count.txt" ]] || exit 1
  ' _ "$RUN_PLAN_SESSION_FILE"

  [ "$status" -eq 0 ]
  rm -rf "$tmpdir"
}

@test "threshold 3 rotates after three bumps, files deleted" {
  [ -f "$RUN_PLAN_SESSION_FILE" ] || skip "run-plan session helper missing"

  local tmpdir
  tmpdir="$(mktemp -d)"
  export RALPH_SESSION_DIR="$tmpdir"

  # Create fake session files
  touch "$tmpdir/session-id.claude.txt"
  echo "test-session-id" > "$tmpdir/session-id.claude.txt"

  run bash -c '
    set -euo pipefail
    ralph_run_plan_log(){ printf '%s\n' "$*"; }
    source "$1"
    # Bump 3 times with threshold 3
    for i in 1 2 3; do
      ralph_session_bump_turn_counter
    done
    # Check rotation with threshold 3
    ralph_session_maybe_rotate 3 2>&1
    # Files should be deleted
    [[ ! -f "$RALPH_SESSION_DIR/session-id.claude.txt" ]] || exit 1
    [[ ! -f "$RALPH_SESSION_DIR/session-turn-count.txt" ]] || exit 1
  ' _ "$RUN_PLAN_SESSION_FILE"

  [ "$status" -eq 0 ]
  [[ "$output" == *"session rotated after"* ]]
  rm -rf "$tmpdir"
}

@test "threshold 2 with stale counter fires rotation on next bump" {
  [ -f "$RUN_PLAN_SESSION_FILE" ] || skip "run-plan session helper missing"

  local tmpdir
  tmpdir="$(mktemp -d)"
  export RALPH_SESSION_DIR="$tmpdir"

  # Create fake session files with stale counter at 1
  touch "$tmpdir/session-id.claude.txt"
  echo "test-session-id" > "$tmpdir/session-id.claude.txt"
  echo "1" > "$tmpdir/session-turn-count.txt"

  run bash -c '
    set -euo pipefail
    ralph_run_plan_log(){ printf '%s\n' "$*"; }
    source "$1"
    # Bump once more (counter goes from 1 to 2)
    ralph_session_bump_turn_counter
    # Check rotation with threshold 2
    ralph_session_maybe_rotate 2 2>&1
    # Files should be deleted (counter was 1, bumped to 2, threshold 2)
    [[ ! -f "$RALPH_SESSION_DIR/session-id.claude.txt" ]] || exit 1
    [[ ! -f "$RALPH_SESSION_DIR/session-turn-count.txt" ]] || exit 1
  ' _ "$RUN_PLAN_SESSION_FILE"

  [ "$status" -eq 0 ]
  [[ "$output" == *"session rotated after"* ]]
  rm -rf "$tmpdir"
}

@test "missing RALPH_SESSION_DIR makes helpers no-ops returning 0" {
  [ -f "$RUN_PLAN_SESSION_FILE" ] || skip "run-plan session helper missing"

  unset RALPH_SESSION_DIR

  run bash -c '
    set -euo pipefail
    source "$1"
    # Both should succeed (return 0) even without RALPH_SESSION_DIR
    ralph_session_bump_turn_counter
    ralph_session_maybe_rotate 3
  ' _ "$RUN_PLAN_SESSION_FILE"

  [ "$status" -eq 0 ]
}
