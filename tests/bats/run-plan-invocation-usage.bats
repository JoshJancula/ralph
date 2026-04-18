#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

@test "invocation usage history is written to a single JSON file" {
  [ -x "$(command -v python3)" ] || skip "python3 required for JSON write/update"

  local tmpdir core_lib funcs usage_file
  tmpdir="$(mktemp -d)"
  core_lib="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan-core.sh"
  funcs="$tmpdir/funcs.sh"
  usage_file="$tmpdir/invocation-usage.json"

  run bash -c '
    set -euo pipefail
    sed -n "/^_ralph_append_invocation_usage_history() {/,/^}$/p" "$1" >"$2"
    source "$2"
    _ralph_append_invocation_usage_history "$3" 1 "m1" "cursor" 3 10 20 0 1 0 0 "2026-04-17T00:00:00Z" "2026-04-17T00:00:03Z" "plan-1" "stage-1"
    _ralph_append_invocation_usage_history "$3" 2 "m2" "claude" 4 11 21 0 2 500 0.75 "2026-04-17T00:00:04Z" "2026-04-17T00:00:09Z" "plan-1" "stage-2"
    python3 - <<PY
import json
with open("'"$usage_file"'", "r", encoding="utf-8") as fh:
    doc = json.load(fh)
assert doc["kind"] == "plan_invocation_usage_history"
assert len(doc["invocations"]) == 2
assert doc["invocations"][0]["iteration"] == 1
assert doc["invocations"][1]["iteration"] == 2
assert doc["invocations"][1]["max_turn_total_tokens"] == 500
assert doc["invocations"][1]["cache_hit_ratio"] == 0.75
assert doc["invocations"][0]["started_at"] == "2026-04-17T00:00:00Z"
assert doc["invocations"][0]["ended_at"] == "2026-04-17T00:00:03Z"
assert doc["invocations"][0]["plan_key"] == "plan-1"
assert doc["invocations"][0]["stage_id"] == "stage-1"
assert doc["invocations"][1]["started_at"] == "2026-04-17T00:00:04Z"
assert doc["invocations"][1]["ended_at"] == "2026-04-17T00:00:09Z"
assert doc["invocations"][1]["plan_key"] == "plan-1"
assert doc["invocations"][1]["stage_id"] == "stage-2"
PY
  ' _ "$core_lib" "$funcs" "$usage_file"

  [ "$status" -eq 0 ]

  rm -rf "$tmpdir"
}

@test "invocation usage history fallback writes optional fields without python3" {
  [ -x "$(command -v python3)" ] || skip "python3 required for JSON write/update"

  local tmpdir core_lib funcs usage_file tmpbin
  tmpdir="$(mktemp -d)"
  core_lib="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan-core.sh"
  funcs="$tmpdir/funcs.sh"
  usage_file="$tmpdir/invocation-usage.json"
  tmpbin="$tmpdir/bin"
  mkdir -p "$tmpbin"
  ln -s "$(command -v mkdir)" "$tmpbin/mkdir"
  ln -s "$(command -v dirname)" "$tmpbin/dirname"
  ln -s "$(command -v cat)" "$tmpbin/cat"
  sed -n "/^_ralph_append_invocation_usage_history() {/,/^}$/p" "$core_lib" >"$funcs"

  run bash -c '
    set -euo pipefail
    PATH="$1"
    source "$2"
    _ralph_append_invocation_usage_history "$3" 3 "m3" "codex" 7 12 13 1 4 25 0.125 "2026-04-17T02:00:00Z" "2026-04-17T02:00:07Z" "plan-2" "stage-3"
  ' _ "$tmpbin" "$funcs" "$usage_file"

  [ "$status" -eq 0 ]

  python3 - "$usage_file" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    doc = json.load(fh)

record = doc["invocations"][0]
assert record["iteration"] == 3
assert record["started_at"] == "2026-04-17T02:00:00Z"
assert record["ended_at"] == "2026-04-17T02:00:07Z"
assert record["plan_key"] == "plan-2"
assert record["stage_id"] == "stage-3"
PY

  rm -rf "$tmpdir"
}

@test "demux extracts Codex token_count events without double counting" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  local demux tmpdir usage_file
  demux="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan-cli-json-demux.py"
  tmpdir="$(mktemp -d)"
  usage_file="$tmpdir/codex.usage.json"

  # Two successive token_count events: only the LAST total_token_usage should be recorded.
  # last_token_usage.total_tokens tracks the per-turn max.
  run python3 - "$demux" "$usage_file" <<'PY'
import json, subprocess, sys, tempfile, os

demux = sys.argv[1]
usage_file = sys.argv[2]

evt1 = json.dumps({"timestamp": "t1", "type": "event_msg", "payload": {
    "type": "token_count",
    "info": {
        "total_token_usage": {"input_tokens": 100, "cached_input_tokens": 10, "output_tokens": 20, "reasoning_output_tokens": 5, "total_tokens": 120},
        "last_token_usage": {"input_tokens": 100, "cached_input_tokens": 10, "output_tokens": 20, "reasoning_output_tokens": 5, "total_tokens": 120},
    }
}})
evt2 = json.dumps({"timestamp": "t2", "type": "event_msg", "payload": {
    "type": "token_count",
    "info": {
        "total_token_usage": {"input_tokens": 200, "cached_input_tokens": 50, "output_tokens": 35, "reasoning_output_tokens": 10, "total_tokens": 235},
        "last_token_usage": {"input_tokens": 100, "cached_input_tokens": 40, "output_tokens": 15, "reasoning_output_tokens": 5, "total_tokens": 115},
    }
}})
stdin_data = (evt1 + "\n" + evt2 + "\n").encode()

proc = subprocess.run([sys.executable, demux, "codex", "", usage_file], input=stdin_data, capture_output=True)
assert proc.returncode == 0, proc.stderr.decode()

with open(usage_file) as fh:
    d = json.load(fh)

# input_tokens = total.input_tokens - total.cached_input_tokens = 200-50 = 150 (from last event only)
assert d["input_tokens"] == 150, f"input_tokens={d['input_tokens']}"
# cache_read_input_tokens = total.cached_input_tokens = 50
assert d["cache_read_input_tokens"] == 50, f"cache_read={d['cache_read_input_tokens']}"
# output_tokens = total.output_tokens + total.reasoning = 35+10 = 45
assert d["output_tokens"] == 45, f"output_tokens={d['output_tokens']}"
# max_turn_total_tokens = max(last.total_tokens) = max(120,115) = 120
assert d["max_turn_total_tokens"] == 120, f"max_turn={d['max_turn_total_tokens']}"
print("codex demux assertions passed")
PY

  [ "$status" -eq 0 ]
  [[ "$output" == *"codex demux assertions passed"* ]]
  rm -rf "$tmpdir"
}

@test "demux extracts Codex turn.completed usage events" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  local demux tmpdir usage_file fixture
  demux="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan-cli-json-demux.py"
  tmpdir="$(mktemp -d)"
  usage_file="$tmpdir/codex-turn-completed.usage.json"
  fixture="$REPO_ROOT/tests/fixtures/run-plan-cli-json-demux/codex-turn-completed.jsonl"

  run python3 - "$demux" "$usage_file" "$fixture" <<'PY'
import json, subprocess, sys

demux = sys.argv[1]
usage_file = sys.argv[2]
fixture = sys.argv[3]

with open(fixture, encoding="utf-8") as fh:
    stdin_data = fh.read().encode()

proc = subprocess.run([sys.executable, demux, "codex", "", usage_file], input=stdin_data, capture_output=True)
assert proc.returncode == 0, proc.stderr.decode()

with open(usage_file) as fh:
    d = json.load(fh)

assert d["input_tokens"] == 16384, f"input_tokens={d['input_tokens']}"
assert d["cache_read_input_tokens"] == 2560, f"cache_read={d['cache_read_input_tokens']}"
assert d["output_tokens"] == 33, f"output_tokens={d['output_tokens']}"
assert d["cache_creation_input_tokens"] == 0
# Derived fallback when total_tokens is absent in turn.completed.usage.
assert d["max_turn_total_tokens"] == 18977, f"max_turn={d['max_turn_total_tokens']}"
print("codex turn.completed demux assertions passed")
PY

  [ "$status" -eq 0 ]
  [[ "$output" == *"codex turn.completed demux assertions passed"* ]]
  rm -rf "$tmpdir"
}

@test "demux extracts OpenCode step_finish tokens from fixture" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  local demux tmpdir usage_file fixture
  demux="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan-cli-json-demux.py"
  tmpdir="$(mktemp -d)"
  usage_file="$tmpdir/opencode.usage.json"
  fixture="$REPO_ROOT/tests/fixtures/run-plan-cli-json-demux/opencode-step-finish.jsonl"

  run python3 - "$demux" "$usage_file" "$fixture" <<'PY'
import json, subprocess, sys
demux = sys.argv[1]
usage_file = sys.argv[2]
fixture = sys.argv[3]

with open(fixture, encoding="utf-8") as fh:
    stdin_data = fh.read().encode()

proc = subprocess.run([sys.executable, demux, "opencode", "", usage_file], input=stdin_data, capture_output=True)
assert proc.returncode == 0, proc.stderr.decode()

with open(usage_file) as fh:
    d = json.load(fh)

assert d == {
    "input_tokens": 38134,
    "output_tokens": 520,
    "cache_creation_input_tokens": 300,
    "cache_read_input_tokens": 8000,
    "max_turn_total_tokens": 0,
}, d
print("opencode demux assertions passed")
PY

  [ "$status" -eq 0 ]
  [[ "$output" == *"opencode demux assertions passed"* ]]
  rm -rf "$tmpdir"
}

@test "ralph_format_elapsed_secs formats seconds for plan and orchestration summaries" {
  local fmt_lib="$REPO_ROOT/bundle/.ralph/bash-lib/ralph-format-elapsed.sh"
  run bash -c 'set -euo pipefail; source "$1"; ralph_format_elapsed_secs 0' _ "$fmt_lib"
  [ "$status" -eq 0 ]
  [ "$output" = "0s" ]

  run bash -c 'set -euo pipefail; source "$1"; ralph_format_elapsed_secs 45' _ "$fmt_lib"
  [ "$status" -eq 0 ]
  [ "$output" = "45s" ]

  run bash -c 'set -euo pipefail; source "$1"; ralph_format_elapsed_secs 282' _ "$fmt_lib"
  [ "$status" -eq 0 ]
  [ "$output" = "4m 42s" ]

  run bash -c 'set -euo pipefail; source "$1"; ralph_format_elapsed_secs 3792' _ "$fmt_lib"
  [ "$status" -eq 0 ]
  [ "$output" = "1h 3m 12s" ]
}

@test "plan invocation banner keeps model, runtime, and plan elapsed on one delimiter-separated line" {
  local core="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan-core.sh"
  local hits
  hits="$(grep -cE 'echo -e.*model:.*[|].*runtime:.*[|].*plan elapsed' "$core" || true)"
  [ "$hits" -eq 1 ]
}

@test "plan usage summary reports cache creation and total tokens" {
  local core="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan-core.sh"
  local hits
  hits="$(grep -cE 'echo -e.*Token usage:.*cache_create=.*total=' "$core" || true)"
  [ "$hits" -eq 1 ]
}

@test "demux extracts Claude message.usage and top-level usage blocks" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  local demux tmpdir usage_file
  demux="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan-cli-json-demux.py"
  tmpdir="$(mktemp -d)"
  usage_file="$tmpdir/claude.usage.json"

  run python3 - "$demux" "$usage_file" <<'PY'
import json, subprocess, sys

demux = sys.argv[1]
usage_file = sys.argv[2]

line1 = json.dumps({"message": {"usage": {
    "input_tokens": 10, "output_tokens": 5,
    "cache_creation_input_tokens": 1, "cache_read_input_tokens": 2,
}}})
line2 = json.dumps({"usage": {
    "input_tokens": 3, "output_tokens": 1,
    "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0,
}})
stdin_data = (line1 + "\n" + line2 + "\n").encode()

proc = subprocess.run([sys.executable, demux, "claude", "", usage_file], input=stdin_data, capture_output=True)
assert proc.returncode == 0, proc.stderr.decode()

with open(usage_file) as fh:
    d = json.load(fh)

assert d["input_tokens"] == 13, f"input_tokens={d['input_tokens']}"
assert d["output_tokens"] == 6, f"output_tokens={d['output_tokens']}"
assert d["cache_creation_input_tokens"] == 1
assert d["cache_read_input_tokens"] == 2
print("claude demux assertions passed")
PY

  [ "$status" -eq 0 ]
  [[ "$output" == *"claude demux assertions passed"* ]]
  rm -rf "$tmpdir"
}

@test "demux extracts cursor cache tokens from fixture" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  local demux tmpdir usage_file fixture
  demux="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan-cli-json-demux.py"
  tmpdir="$(mktemp -d)"
  usage_file="$tmpdir/cursor-demux.usage.json"
  fixture="$REPO_ROOT/tests/fixtures/run-plan-cli-json-demux/cursor-cache-tokens.jsonl"

  run python3 - "$demux" "$usage_file" "$fixture" <<'PY'
import json, subprocess, sys
demux = sys.argv[1]
usage_file = sys.argv[2]
fixture = sys.argv[3]

with open(fixture, encoding="utf-8") as fh:
    stdin_data = fh.read().encode()

proc = subprocess.run([sys.executable, demux, "cursor", "", usage_file], input=stdin_data, capture_output=True)
assert proc.returncode == 0, proc.stderr.decode()

with open(usage_file) as fh:
    d = json.load(fh)

assert d == {
    "input_tokens": 100,
    "output_tokens": 40,
    "cache_creation_input_tokens": 9,
    "cache_read_input_tokens": 15,
    "max_turn_total_tokens": 0,
}, d
print("cursor demux assertions passed")
PY

  [ "$status" -eq 0 ]
  [[ "$output" == *"cursor demux assertions passed"* ]]
  rm -rf "$tmpdir"
}
