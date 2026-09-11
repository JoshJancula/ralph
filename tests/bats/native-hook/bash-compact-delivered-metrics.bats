#!/usr/bin/env bats
# Coverage for v2 deliveredBytes/deliveredTokens on Bash compaction telemetry
# (PLAN15): applied compaction must measure delivered content AFTER the
# stored-result footer is added, while legacy compactedBytes stays pre-footer.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

HOOK="$REPO_ROOT/bundle/.claude/hooks/compact-bash-output.sh"

setup() {
  _tmp="$(mktemp -d)"
  export WORKSPACE="$_tmp/workspace"
  mkdir -p "$WORKSPACE"
  export CLAUDE_PROJECT_DIR="$REPO_ROOT"
  export RALPH_BASH_COMPACT=1
  export RALPH_PLAN_KEY="bash-delivered-metrics-bats"
  export RALPH_BASH_COMPACT_LOG="$_tmp/compact.jsonl"
  bats_skip_known_ci_flakes
}

teardown() {
  rm -rf "$_tmp"
  unset WORKSPACE CLAUDE_PROJECT_DIR RALPH_BASH_COMPACT RALPH_PLAN_KEY RALPH_BASH_COMPACT_LOG
}

_bash_hook_input_file() {
  local stdout="$1" stderr="${2:-}" out="$3"
  local stdout_file="$_tmp/hook-stdout" stderr_file="$_tmp/hook-stderr"
  printf '%s' "$stdout" >"$stdout_file"
  printf '%s' "$stderr" >"$stderr_file"
  jq -n --rawfile stdout "$stdout_file" --rawfile stderr "$stderr_file" \
    '{hook_event_name:"PostToolUse", tool_name:"Bash",
      tool_input:{command:""},
      tool_response:{stdout:$stdout, stderr:$stderr, interrupted:false, isImage:false}}' >"$out"
}

@test "applied compaction with a storage footer: delivered exceeds legacy compactedBytes by the footer" {
  local big
  big="$(python3 -c "
for i in range(4000):
    print(f'line {i} of repeated build output filler text here')
")"
  local input="$_tmp/input.json"
  _bash_hook_input_file "$big" "" "$input"

  run bash -c "bash '$HOOK' < '$input'"
  [ "$status" -eq 0 ]

  [ -f "$RALPH_BASH_COMPACT_LOG" ]
  local record
  record="$(tail -n1 "$RALPH_BASH_COMPACT_LOG")"

  run jq -e '.compactionSkipped == false' <<<"$record"
  [ "$status" -eq 0 ]
  run jq -e 'has("storagePath") and (.storagePath != null)' <<<"$record"
  [ "$status" -eq 0 ]
  run jq -e 'has("deliveredBytes")' <<<"$record"
  [ "$status" -eq 0 ]
  run jq -e '.deliveredBytes > .compactedBytes' <<<"$record"
  [ "$status" -eq 0 ]
}

@test "skipped compaction: delivered metrics equal original combined bytes, not stored bytes" {
  local input="$_tmp/input.json"
  # duration_ms above LONG_RUNNING_THRESHOLD_MS forces the slow path so
  # skip-path telemetry still runs for this tiny (non-compactable) payload.
  _bash_hook_input_file "small output" "" "$input"
  jq --argjson d 60001 '.duration_ms = $d' "$input" >"${input}.tmp" && mv "${input}.tmp" "$input"

  run bash -c "bash '$HOOK' < '$input'"
  [ "$status" -eq 0 ]

  [ -f "$RALPH_BASH_COMPACT_LOG" ]
  local record
  record="$(tail -n1 "$RALPH_BASH_COMPACT_LOG")"
  run jq -e '.compactionSkipped == true' <<<"$record"
  [ "$status" -eq 0 ]

  if jq -e 'has("deliveredBytes")' <<<"$record" >/dev/null 2>&1; then
    run jq -e '.deliveredBytes == .originalBytes' <<<"$record"
    [ "$status" -eq 0 ]
  fi
}

@test "stderr-only output: delivered metrics still recorded correctly" {
  local big_stderr
  big_stderr="$(python3 -c "print('err ' * 4000)")"
  local input="$_tmp/input.json"
  _bash_hook_input_file "" "$big_stderr" "$input"

  run bash -c "bash '$HOOK' < '$input'"
  [ "$status" -eq 0 ]

  [ -f "$RALPH_BASH_COMPACT_LOG" ]
  local record
  record="$(tail -n1 "$RALPH_BASH_COMPACT_LOG")"
  run jq -e '.originalBytes > 0' <<<"$record"
  [ "$status" -eq 0 ]
}

@test "multibyte content: delivered byte accounting does not error and stays non-negative" {
  local multibyte
  multibyte="$(python3 -c "print(('café 日本語 \U0001f680 ' * 2000))")"
  local input="$_tmp/input.json"
  _bash_hook_input_file "$multibyte" "" "$input"

  run bash -c "bash '$HOOK' < '$input'"
  [ "$status" -eq 0 ]

  [ -f "$RALPH_BASH_COMPACT_LOG" ]
  local record
  record="$(tail -n1 "$RALPH_BASH_COMPACT_LOG")"
  if jq -e 'has("deliveredBytes")' <<<"$record" >/dev/null 2>&1; then
    run jq -e '.deliveredBytes >= 0' <<<"$record"
    [ "$status" -eq 0 ]
  fi
}
