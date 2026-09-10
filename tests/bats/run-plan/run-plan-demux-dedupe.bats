#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

fixture_path() {
  printf '%s\n' "$REPO_ROOT/tests/bats/fixtures/stream-json/$1"
}

@test "demux renders Antigravity stream-json live text and captures session and usage" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  local tmpdir stream usage_file session_file output_file
  tmpdir="$(mktemp -d)"
  stream="$tmpdir/antigravity.ndjson"
  usage_file="$tmpdir/usage.json"
  session_file="$tmpdir/session.txt"
  output_file="$tmpdir/output.log"

  cat >"$stream" <<'STREAM'
{"event":"init","conversation_id":"agy-conversation-1","init":{"model":"gemini-3.1-pro-low"}}
{"event":"step_update","step_update":{"conversation_id":"agy-conversation-1","step_index":3,"state":"ACTIVE","step_type":"agent_response","text_delta":"Working"}}
{"event":"step_update","step_update":{"conversation_id":"agy-conversation-1","step_index":3,"state":"DONE","step_type":"agent_response","text_delta":" now","usage":{"input_tokens":100,"output_tokens":20,"thinking_tokens":10,"cache_read_tokens":40,"total_tokens":120}}}
{"event":"step_update","step_update":{"conversation_id":"agy-conversation-1","step_index":4,"state":"DONE","step_type":"checkpoint","usage":{"input_tokens":5,"output_tokens":2,"thinking_tokens":0,"cache_read_tokens":3,"total_tokens":7}}}
{"event":"result","result":{"conversation_id":"agy-conversation-1","status":"SUCCESS","response":"Working now","usage":{"input_tokens":105,"output_tokens":22,"thinking_tokens":10,"cache_read_tokens":43,"total_tokens":127}}}
STREAM

  run python3 "$REPO_ROOT/bundle/.ralph/python/run-plan-cli-json-demux.py" antigravity "$session_file" "$usage_file" "$output_file" 0 <"$stream"

  [ "$status" -eq 0 ]
  [ "$output" = $'Working\nnow' ]
  grep -Fxq -- "agy-conversation-1" "$session_file"
  grep -Fxq -- "Working" "$output_file"
  grep -Fxq -- "now" "$output_file"
  ! grep -Fq -- '"event"' "$output_file"

  run python3 - "$usage_file" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    usage = json.load(fh)

assert usage["input_tokens"] == 105, usage
assert usage["output_tokens"] == 22, usage
assert usage["cache_read_input_tokens"] == 43, usage
assert usage["max_turn_total_tokens"] == 120, usage
assert usage["usage_unsupported"] is False, usage
PY
  [ "$status" -eq 0 ]

  rm -rf "$tmpdir"
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

@test "demux prefers per-request sum over a result event that undercounts" {
  local tmpfile usage_file
  tmpfile="$(mktemp)"
  usage_file="$(mktemp)"

  # Synthetic stream with NO message ids, so every assistant event is treated as its
  # own API request. The result event here reports last-turn-only input/output with
  # cumulative cache fields.
  #
  # NOTE: captured real Claude streams do NOT behave this way -- the result event is
  # the exact cross-request sum for all four fields, and per-event output_tokens are
  # stale partials (see tests/python/test_demux_claude_usage.py, built from a real
  # capture). This fixture was written from that older assumption, and it is kept as
  # a guard for the per-field max() in _finalize_claude_usage: whichever source is
  # populated wins, so a CLI that did undercount in `result` would still be recorded
  # correctly rather than collapsing to input=10.
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

  # Per-request sum: input=200+15+10=225, output=80+120+60=260,
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

@test "demux attributes repeated content-block events to one API request" {
  local tmpfile usage_file
  tmpfile="$(mktemp)"
  usage_file="$(mktemp)"

  # Claude emits one assistant event per CONTENT BLOCK, each repeating the same
  # message.id and a copy of that request's usage. Two requests, five events here.
  # Summing events would report cache_read 3*1000 + 2*4000 = 11000 instead of 5000.
  cat > "$tmpfile" <<'STREAM'
{"type": "system", "subtype": "init", "session_id": "test-session"}
{"type": "assistant", "message": {"id": "msg_A", "usage": {"input_tokens": 10, "output_tokens": 2, "cache_creation_input_tokens": 700, "cache_read_input_tokens": 1000}}}
{"type": "assistant", "message": {"id": "msg_A", "usage": {"input_tokens": 10, "output_tokens": 2, "cache_creation_input_tokens": 700, "cache_read_input_tokens": 1000}}}
{"type": "assistant", "message": {"id": "msg_A", "usage": {"input_tokens": 10, "output_tokens": 2, "cache_creation_input_tokens": 700, "cache_read_input_tokens": 1000}}}
{"type": "assistant", "message": {"id": "msg_B", "usage": {"input_tokens": 8, "output_tokens": 1, "cache_creation_input_tokens": 300, "cache_read_input_tokens": 4000}}}
{"type": "assistant", "message": {"id": "msg_B", "usage": {"input_tokens": 8, "output_tokens": 1, "cache_creation_input_tokens": 300, "cache_read_input_tokens": 4000}}}
{"type": "result", "subtype": "success", "usage": {"input_tokens": 18, "output_tokens": 450, "cache_creation_input_tokens": 1000, "cache_read_input_tokens": 5000}}
STREAM

  run python3 "$REPO_ROOT/bundle/.ralph/python/run-plan-cli-json-demux.py" claude /dev/null "$usage_file" < "$tmpfile"

  [ "$status" -eq 0 ]
  [ -f "$usage_file" ]

  local field
  for field in input_tokens:18 output_tokens:450 cache_creation_input_tokens:1000 \
               cache_read_input_tokens:5000 tool_turns:2; do
    local key="${field%%:*}" want="${field##*:}" got
    got="$(python3 -c "import json; print(json.load(open('$usage_file'))['$key'])")"
    [ "$got" -eq "$want" ] || {
      echo "$key: got $got want $want" >&2
      false
    }
  done

  rm -f "$tmpfile" "$usage_file"
}
