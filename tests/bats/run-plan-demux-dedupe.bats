#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

@test "demux prefers result event cumulative usage over sum of assistant deltas" {
  local tmpfile usage_file
  tmpfile="$(mktemp)"
  usage_file="$(mktemp)"

  # Create synthetic Claude stream-json with:
  # - init event
  # - two assistant events with progressive usage
  # - final result event with cumulative usage
  cat > "$tmpfile" <<'STREAM'
{"type": "init", "session_id": "test-session"}
{"type": "assistant", "message": {"usage": {"input_tokens": 100, "output_tokens": 50, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}}}
{"type": "assistant", "message": {"usage": {"input_tokens": 150, "output_tokens": 75, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}}}
{"type": "result", "usage": {"input_tokens": 500, "output_tokens": 250, "cache_creation_input_tokens": 100, "cache_read_input_tokens": 50}}
STREAM

  run python3 "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan-cli-json-demux.py" claude /dev/null "$usage_file" < "$tmpfile"

  [ "$status" -eq 0 ]
  [ -f "$usage_file" ]

  # Usage should equal the result event's cumulative usage, not sum of assistant deltas
  # Sum would be: input=100+150+500=750, output=50+75+250=375
  # Result event: input=500, output=250
  local input_tokens output_tokens
  input_tokens="$(python3 -c "import json; print(json.load(open('$usage_file'))['input_tokens'])" 2>/dev/null || echo "0")"
  output_tokens="$(python3 -c "import json; print(json.load(open('$usage_file'))['output_tokens'])" 2>/dev/null || echo "0")"

  # Should match result event (500, 250), not sum (750, 375)
  [ "$input_tokens" -eq 500 ]
  [ "$output_tokens" -eq 250 ]

  rm -f "$tmpfile" "$usage_file"
}

@test "demux falls back to sum when no result event present" {
  local tmpfile usage_file
  tmpfile="$(mktemp)"
  usage_file="$(mktemp)"

  # Create synthetic Claude stream-json without result event (stream interrupted)
  cat > "$tmpfile" <<'STREAM'
{"type": "init", "session_id": "test-session"}
{"type": "assistant", "message": {"usage": {"input_tokens": 100, "output_tokens": 50, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}}}
{"type": "assistant", "message": {"usage": {"input_tokens": 150, "output_tokens": 75, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}}}
STREAM

  run python3 "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan-cli-json-demux.py" claude /dev/null "$usage_file" < "$tmpfile"

  [ "$status" -eq 0 ]
  [ -f "$usage_file" ]

  # When no result event, should sum assistant deltas: 100+150=250, 50+75=125
  local input_tokens output_tokens
  input_tokens="$(python3 -c "import json; print(json.load(open('$usage_file'))['input_tokens'])" 2>/dev/null || echo "0")"
  output_tokens="$(python3 -c "import json; print(json.load(open('$usage_file'))['output_tokens'])" 2>/dev/null || echo "0")"

  [ "$input_tokens" -eq 250 ]
  [ "$output_tokens" -eq 125 ]

  rm -f "$tmpfile" "$usage_file"
}

@test "demux handles cache tokens correctly with result event" {
  local tmpfile usage_file
  tmpfile="$(mktemp)"
  usage_file="$(mktemp)"

  # Create synthetic Claude stream-json with cache tokens
  cat > "$tmpfile" <<'STREAM'
{"type": "init", "session_id": "test-session"}
{"type": "assistant", "message": {"usage": {"input_tokens": 100, "output_tokens": 50, "cache_creation_input_tokens": 50, "cache_read_input_tokens": 25}}}
{"type": "result", "usage": {"input_tokens": 500, "output_tokens": 250, "cache_creation_input_tokens": 200, "cache_read_input_tokens": 100}}
STREAM

  run python3 "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan-cli-json-demux.py" claude /dev/null "$usage_file" < "$tmpfile"

  [ "$status" -eq 0 ]
  [ -f "$usage_file" ]

  # Should match result event cache values
  local cache_create cache_read
  cache_create="$(python3 -c "import json; print(json.load(open('$usage_file'))['cache_creation_input_tokens'])" 2>/dev/null || echo "0")"
  cache_read="$(python3 -c "import json; print(json.load(open('$usage_file'))['cache_read_input_tokens'])" 2>/dev/null || echo "0")"

  [ "$cache_create" -eq 200 ]
  [ "$cache_read" -eq 100 ]

  rm -f "$tmpfile" "$usage_file"
}
