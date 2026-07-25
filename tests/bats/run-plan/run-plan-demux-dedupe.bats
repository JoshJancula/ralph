#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

fixture_path() {
  printf '%s\n' "$REPO_ROOT/tests/bats/fixtures/stream-json/$1"
}

assert_telemetry_usage_json() {
  local usage_file="$1"
  local large_blob_marker="$2"

  python3 - "$usage_file" "$large_blob_marker" <<'PY'
import json
import sys

usage_file, marker = sys.argv[1:3]

with open(usage_file, encoding="utf-8") as fh:
    usage = json.load(fh)

raw = json.dumps(usage)
assert marker not in raw, "usage JSON must not include raw large argument blobs"

for key in (
    "adjacent_duplicate_tool_calls",
    "repeated_read_targets",
    "repeated_read_extra_calls",
    "plan_file_read_calls",
    "tool_call_targets",
):
    assert key in usage, f"missing {key}"

assert usage["adjacent_duplicate_tool_calls"] == 2, usage
assert usage["repeated_read_targets"] == 2, usage
assert usage["repeated_read_extra_calls"] == 2, usage
assert usage["plan_file_read_calls"] == 2, usage
assert usage["tool_calls_total"] == 7, usage

targets = usage["tool_call_targets"]
assert isinstance(targets, list) and targets, targets
assert all(isinstance(item, dict) for item in targets)
assert all("tool" in item and "family" in item and "target" in item for item in targets)
assert all(len(str(item.get("target") or "")) <= 200 for item in targets)

shell_targets = [item for item in targets if item.get("tool") == "ralph_proxy_shell"]
assert len(shell_targets) == 1, targets
assert str(shell_targets[0]["target"]).startswith("sha256:"), shell_targets[0]

plan_targets = [
    item for item in targets
    if ".ralph-workspace/plans/tool-use-optimization.plan.md" in str(item.get("target") or "")
]
assert len(plan_targets) == 2, targets

grep_targets = [item for item in targets if item.get("tool") == "ralph_proxy_grep"]
assert len(grep_targets) == 2, targets
assert all(item.get("target") == "duplicate.telemetry" for item in grep_targets)
PY
}

@test "demux sums per-turn assistant usage and ignores result event's last-turn input/output" {
  local tmpfile usage_file
  tmpfile="$(mktemp)"
  usage_file="$(mktemp)"

  # Synthetic Claude stream-json modeling a real multi-turn invocation:
  # - init event
  # - three assistant turns, each a per-request delta
  # - final result event whose input/output reflect only the LAST turn while its
  #   cache_read/cache_creation are cumulative (this mixed semantics is what Claude emits).
  # The recorded totals must be the SUM of the per-turn deltas, not the result event's
  # last-turn input/output (otherwise a long TODO collapses to input=10).
  cat > "$tmpfile" <<'STREAM'
{"type": "init", "session_id": "test-session"}
{"type": "assistant", "message": {"usage": {"input_tokens": 200, "output_tokens": 80, "cache_creation_input_tokens": 5000, "cache_read_input_tokens": 0}}}
{"type": "assistant", "message": {"usage": {"input_tokens": 15, "output_tokens": 120, "cache_creation_input_tokens": 3000, "cache_read_input_tokens": 5000}}}
{"type": "assistant", "message": {"usage": {"input_tokens": 10, "output_tokens": 60, "cache_creation_input_tokens": 2000, "cache_read_input_tokens": 8000}}}
{"type": "result", "usage": {"input_tokens": 10, "output_tokens": 60, "cache_creation_input_tokens": 10000, "cache_read_input_tokens": 13000}}
STREAM

  run python3 "$REPO_ROOT/bundle/.ralph/python/run-plan-cli-json-demux.py" claude /dev/null "$usage_file" < "$tmpfile"

  [ "$status" -eq 0 ]
  [ -f "$usage_file" ]

  local input_tokens output_tokens cache_create cache_read
  input_tokens="$(python3 -c "import json; print(json.load(open('$usage_file'))['input_tokens'])" 2>/dev/null || echo "0")"
  output_tokens="$(python3 -c "import json; print(json.load(open('$usage_file'))['output_tokens'])" 2>/dev/null || echo "0")"
  cache_create="$(python3 -c "import json; print(json.load(open('$usage_file'))['cache_creation_input_tokens'])" 2>/dev/null || echo "0")"
  cache_read="$(python3 -c "import json; print(json.load(open('$usage_file'))['cache_read_input_tokens'])" 2>/dev/null || echo "0")"

  # Sum of per-turn deltas: input=200+15+10=225, output=80+120+60=260,
  # cache_create=5000+3000+2000=10000, cache_read=0+5000+8000=13000.
  # NOT the result event's last-turn input=10/output=60.
  [ "$input_tokens" -eq 225 ]
  [ "$output_tokens" -eq 260 ]
  [ "$cache_create" -eq 10000 ]
  [ "$cache_read" -eq 13000 ]

  rm -f "$tmpfile" "$usage_file"
}

@test "demux sums assistant deltas when no result event present" {
  local tmpfile usage_file
  tmpfile="$(mktemp)"
  usage_file="$(mktemp)"

  # Claude stream-json without a result event (e.g. interrupted stream).
  cat > "$tmpfile" <<'STREAM'
{"type": "init", "session_id": "test-session"}
{"type": "assistant", "message": {"usage": {"input_tokens": 100, "output_tokens": 50, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}}}
{"type": "assistant", "message": {"usage": {"input_tokens": 150, "output_tokens": 75, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}}}
STREAM

  run python3 "$REPO_ROOT/bundle/.ralph/python/run-plan-cli-json-demux.py" claude /dev/null "$usage_file" < "$tmpfile"

  [ "$status" -eq 0 ]
  [ -f "$usage_file" ]

  # Sum assistant deltas: 100+150=250, 50+75=125
  local input_tokens output_tokens
  input_tokens="$(python3 -c "import json; print(json.load(open('$usage_file'))['input_tokens'])" 2>/dev/null || echo "0")"
  output_tokens="$(python3 -c "import json; print(json.load(open('$usage_file'))['output_tokens'])" 2>/dev/null || echo "0")"

  [ "$input_tokens" -eq 250 ]
  [ "$output_tokens" -eq 125 ]

  rm -f "$tmpfile" "$usage_file"
}

@test "demux falls back to result usage when only a result event carries usage" {
  local tmpfile usage_file
  tmpfile="$(mktemp)"
  usage_file="$(mktemp)"

  # Degenerate stream: no per-turn assistant usage, only a final result event.
  # The result event's usage is the best (only) signal available, so use it.
  cat > "$tmpfile" <<'STREAM'
{"type": "init", "session_id": "test-session"}
{"type": "result", "usage": {"input_tokens": 500, "output_tokens": 250, "cache_creation_input_tokens": 200, "cache_read_input_tokens": 100}}
STREAM

  run python3 "$REPO_ROOT/bundle/.ralph/python/run-plan-cli-json-demux.py" claude /dev/null "$usage_file" < "$tmpfile"

  [ "$status" -eq 0 ]
  [ -f "$usage_file" ]

  local input_tokens output_tokens cache_create cache_read
  input_tokens="$(python3 -c "import json; print(json.load(open('$usage_file'))['input_tokens'])" 2>/dev/null || echo "0")"
  output_tokens="$(python3 -c "import json; print(json.load(open('$usage_file'))['output_tokens'])" 2>/dev/null || echo "0")"
  cache_create="$(python3 -c "import json; print(json.load(open('$usage_file'))['cache_creation_input_tokens'])" 2>/dev/null || echo "0")"
  cache_read="$(python3 -c "import json; print(json.load(open('$usage_file'))['cache_read_input_tokens'])" 2>/dev/null || echo "0")"

  [ "$input_tokens" -eq 500 ]
  [ "$output_tokens" -eq 250 ]
  [ "$cache_create" -eq 200 ]
  [ "$cache_read" -eq 100 ]

  rm -f "$tmpfile" "$usage_file"
}

@test "demux sums cache tokens across turns alongside a result event" {
  local tmpfile usage_file
  tmpfile="$(mktemp)"
  usage_file="$(mktemp)"

  # Two assistant turns carrying cache deltas, plus a result event. The recorded
  # cache totals are the sum of the per-turn deltas (which in real Claude output equals
  # the result event's cumulative cache figures).
  cat > "$tmpfile" <<'STREAM'
{"type": "init", "session_id": "test-session"}
{"type": "assistant", "message": {"usage": {"input_tokens": 100, "output_tokens": 50, "cache_creation_input_tokens": 50, "cache_read_input_tokens": 25}}}
{"type": "assistant", "message": {"usage": {"input_tokens": 20, "output_tokens": 40, "cache_creation_input_tokens": 150, "cache_read_input_tokens": 75}}}
{"type": "result", "usage": {"input_tokens": 20, "output_tokens": 40, "cache_creation_input_tokens": 200, "cache_read_input_tokens": 100}}
STREAM

  run python3 "$REPO_ROOT/bundle/.ralph/python/run-plan-cli-json-demux.py" claude /dev/null "$usage_file" < "$tmpfile"

  [ "$status" -eq 0 ]
  [ -f "$usage_file" ]

  local cache_create cache_read
  cache_create="$(python3 -c "import json; print(json.load(open('$usage_file'))['cache_creation_input_tokens'])" 2>/dev/null || echo "0")"
  cache_read="$(python3 -c "import json; print(json.load(open('$usage_file'))['cache_read_input_tokens'])" 2>/dev/null || echo "0")"

  # Sum of per-turn cache deltas: create=50+150=200, read=25+75=100
  [ "$cache_create" -eq 200 ]
  [ "$cache_read" -eq 100 ]

  rm -f "$tmpfile" "$usage_file"
}

@test "demux records duplicate and target telemetry for cursor stream fixtures" {
  command -v python3 >/dev/null || skip "python3 required"

  local fixture usage_file tmp_dir large_blob_marker
  fixture="$(fixture_path cursor-telemetry.ndjson)"
  tmp_dir="$(mktemp -d)"
  usage_file="$tmp_dir/cursor-telemetry.usage.json"
  large_blob_marker="SENSITIVE_LARGE_COMMAND_BLOB_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

  run python3 "$REPO_ROOT/bundle/.ralph/python/run-plan-cli-json-demux.py" \
    cursor /dev/null "$usage_file" <"$fixture"

  [ "$status" -eq 0 ]
  [ -f "$usage_file" ]
  assert_telemetry_usage_json "$usage_file" "$large_blob_marker"

  rm -rf "$tmp_dir"
}

@test "demux records duplicate and target telemetry for opencode stream fixtures" {
  command -v python3 >/dev/null || skip "python3 required"

  local fixture usage_file tmp_dir large_blob_marker
  fixture="$(fixture_path opencode-telemetry.ndjson)"
  tmp_dir="$(mktemp -d)"
  usage_file="$tmp_dir/opencode-telemetry.usage.json"
  large_blob_marker="SENSITIVE_LARGE_COMMAND_BLOB_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

  run python3 "$REPO_ROOT/bundle/.ralph/python/run-plan-cli-json-demux.py" \
    opencode /dev/null "$usage_file" <"$fixture"

  [ "$status" -eq 0 ]
  [ -f "$usage_file" ]
  assert_telemetry_usage_json "$usage_file" "$large_blob_marker"

  rm -rf "$tmp_dir"
}
