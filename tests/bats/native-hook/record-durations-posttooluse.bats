#!/usr/bin/env bats
# PostToolUse Bash duration recording into the command-profiles store
# (PLAN-HOOK-DIET record-durations-posttooluse). Pure observation: never
# alters compaction output or exit status. No RALPH_COMMAND_PROFILING gate.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

FIXTURE_DIR="$REPO_ROOT/tests/fixtures/native-hook"
HOOK="$REPO_ROOT/bundle/.claude/hooks/compact-bash-output.sh"

setup() {
  _tmp="$(mktemp -d)"
  export CLAUDE_PROJECT_DIR="$_tmp/project"
  mkdir -p "$CLAUDE_PROJECT_DIR"
  ln -sfn "$REPO_ROOT/.ralph" "$CLAUDE_PROJECT_DIR/.ralph"
  export RALPH_BASH_COMPACT=1
  export RALPH_PLAN_KEY="record-durations-bats"
  export RALPH_BASH_COMPACT_LOG="$_tmp/compact.jsonl"
  bats_skip_known_ci_flakes
}

teardown() {
  rm -rf "$_tmp"
  unset CLAUDE_PROJECT_DIR RALPH_BASH_COMPACT RALPH_PLAN_KEY RALPH_BASH_COMPACT_LOG
}

_store_path() {
  printf '%s/.ralph-workspace/command-profiles/profiles.json\n' "$CLAUDE_PROJECT_DIR"
}

_expected_fingerprint() {
  local command="$1"
  python3 -c "
import sys
sys.path.insert(0, '$REPO_ROOT/bundle/.ralph/python')
from command_fingerprint import fingerprint
print(fingerprint(sys.argv[1]) or '')
" "$command"
}

@test "bash.json-derived payload with duration records an observation in the store" {
  # bash.json carries a real duration_ms (11180) but its captured command is
  # bail-shaped (semicolon inside -c), so fingerprint is None. Keep the
  # fixture's duration and response shape; use a fingerprintable command so
  # the store write path is exercised.
  local input expected_fp duration store
  input="$_tmp/input.json"
  jq --arg cmd 'bash scripts/run-bats.sh' \
    '.tool_input.command = $cmd' \
    "$FIXTURE_DIR/bash.json" >"$input"

  duration="$(jq -r '.duration_ms' "$input")"
  [ "$duration" = "11180" ]
  expected_fp="$(_expected_fingerprint 'bash scripts/run-bats.sh')"
  [ -n "$expected_fp" ]

  run bash -c "bash '$HOOK' < '$input'"
  [ "$status" -eq 0 ]

  store="$(_store_path)"
  [ -f "$store" ]
  run jq -e --arg fp "$expected_fp" --argjson d "$duration" '
    .entries[$fp].durations_ms | index($d) != null
  ' "$store"
  [ "$status" -eq 0 ]
  run jq -e --arg fp "$expected_fp" '
    .entries[$fp].observation_count >= 1
  ' "$store"
  [ "$status" -eq 0 ]

  # Telemetry carries the same durationMs + fingerprint for audit.
  [ -f "$RALPH_BASH_COMPACT_LOG" ]
  run jq -e --arg fp "$expected_fp" --argjson d "$duration" '
    .durationMs == $d and .fingerprint == $fp
  ' "$RALPH_BASH_COMPACT_LOG"
  [ "$status" -eq 0 ]
}

@test "payload with no duration_ms records nothing and still exits 0" {
  local input
  input="$_tmp/no-duration.json"
  jq --arg cmd 'bash scripts/run-bats.sh' \
    'del(.duration_ms) | .tool_input.command = $cmd' \
    "$FIXTURE_DIR/bash.json" >"$input"

  run bash -c "bash '$HOOK' < '$input'"
  [ "$status" -eq 0 ]
  [ ! -f "$(_store_path)" ]
}
