#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

CORE_FILE="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan-core.sh"

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
    _ralph_append_invocation_usage_history "$3" 1 "m1" "cursor" 3 10 20 0 1 0 0 "2026-04-17T00:00:00Z" "2026-04-17T00:00:03Z" "plan-1" "stage-1" "fresh" "12" "2" "1"
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
assert doc["invocations"][0]["prompt_bytes"] == 0
assert doc["invocations"][0]["todo_bytes"] == 0
assert doc["invocations"][0]["todo_continuation_lines"] == 0
assert doc["invocations"][0]["direct_verification"] is False
assert doc["invocations"][0]["tool_turns"] == 0
assert doc["invocations"][0]["started_at"] == "2026-04-17T00:00:00Z"
assert doc["invocations"][0]["ended_at"] == "2026-04-17T00:00:03Z"
assert doc["invocations"][0]["plan_key"] == "plan-1"
assert doc["invocations"][0]["stage_id"] == "stage-1"
assert doc["invocations"][0]["todo_line"] == 12
assert doc["invocations"][0]["todo_ordinal"] == 2
assert doc["invocations"][0]["todo_completed"] is True
assert doc["invocations"][1]["started_at"] == "2026-04-17T00:00:04Z"
assert doc["invocations"][1]["ended_at"] == "2026-04-17T00:00:09Z"
assert doc["invocations"][1]["plan_key"] == "plan-1"
assert doc["invocations"][1]["stage_id"] == "stage-2"
PY
  ' _ "$core_lib" "$funcs" "$usage_file"

  [ "$status" -eq 0 ]

  rm -rf "$tmpdir"
}

@test "invocation usage history records token reduction diagnostics" {
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
    _ralph_append_invocation_usage_history "$3" 1 "m1" "claude" 5 0 0 0 0 0 0 "2026-04-17T00:00:00Z" "2026-04-17T00:00:05Z" "plan-1" "stage-1" "fresh" "9" "1" "1" "verification_gate" "abc" "0" "0" "1234" "456" "7" "line-2" "1" "five_hour" "3"
    python3 - <<PY
import json
with open("'"$usage_file"'", "r", encoding="utf-8") as fh:
    doc = json.load(fh)
record = doc["invocations"][0]
assert record["prompt_bytes"] == 1234
assert record["todo_bytes"] == 456
assert record["todo_continuation_lines"] == 7
assert record["split_parent_id"] == "line-2"
assert record["direct_verification"] is True
assert record["rate_limit_status"] == "five_hour"
assert record["tool_turns"] == 3
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

@test "demux counts Codex item.completed tool_use events" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  local demux tmpdir usage_file fixture
  demux="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan-cli-json-demux.py"
  tmpdir="$(mktemp -d)"
  usage_file="$tmpdir/codex-tools.usage.json"
  fixture="$REPO_ROOT/tests/fixtures/run-plan-cli-json-demux/codex-with-tools.jsonl"

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

assert d["tool_calls_total"] == 2, f"tool_calls_total={d.get('tool_calls_total')}"
assert d["tool_calls_by_tool"]["read_file"] == 1
assert d["tool_calls_by_tool"]["grep"] == 1
assert d["tool_calls_sequence"] == ["read_file", "grep"]
print("codex tool call demux assertions passed")
PY

  [ "$status" -eq 0 ]
  [[ "$output" == *"codex tool call demux assertions passed"* ]]
  rm -rf "$tmpdir"
}

@test "demux counts Codex duplicate tool ids once" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  local demux tmpdir usage_file
  demux="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan-cli-json-demux.py"
  tmpdir="$(mktemp -d)"
  usage_file="$tmpdir/codex-duplicate-tools.usage.json"

  run python3 - "$demux" "$usage_file" <<'PY'
import json, subprocess, sys

demux = sys.argv[1]
usage_file = sys.argv[2]

line = json.dumps({"type":"item.completed","item":{"id":"tool-1","type":"tool_use","name":"read_file"}})
stdin_data = (line + "\n" + line + "\n").encode()

proc = subprocess.run([sys.executable, demux, "codex", "", usage_file], input=stdin_data, capture_output=True)
assert proc.returncode == 0, proc.stderr.decode()

with open(usage_file) as fh:
    d = json.load(fh)

assert d["tool_calls_total"] == 1, d
assert d["tool_calls_by_tool"] == {"read_file": 1}, d
assert d["tool_calls_sequence"] == ["read_file"], d
assert "_tool_call_ids_seen" not in d, d
print("codex duplicate tool id assertions passed")
PY

  [ "$status" -eq 0 ]
  [[ "$output" == *"codex duplicate tool id assertions passed"* ]]
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
    "tool_turns": 2,
    "tool_calls_total": 0,
    "tool_calls_by_tool": {},
    "tool_calls_sequence": [],
}, d
print("opencode demux assertions passed")
PY

  [ "$status" -eq 0 ]
  [[ "$output" == *"opencode demux assertions passed"* ]]
  rm -rf "$tmpdir"
}

@test "demux counts OpenCode ToolPart events by callID" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  local demux tmpdir usage_file
  demux="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan-cli-json-demux.py"
  tmpdir="$(mktemp -d)"
  usage_file="$tmpdir/opencode-tools.usage.json"

  run python3 - "$demux" "$usage_file" <<'PY'
import json, subprocess, sys

demux = sys.argv[1]
usage_file = sys.argv[2]

tool_part = {
    "type": "message.part.updated",
    "properties": {
        "part": {
            "id": "part_1",
            "type": "tool",
            "callID": "call_1",
            "tool": "bash",
            "state": {"status": "running"},
        }
    },
}
tool_part_done = json.loads(json.dumps(tool_part))
tool_part_done["properties"]["part"]["state"] = {"status": "completed"}
second = {
    "type": "message.part.updated",
    "properties": {
        "part": {
            "id": "part_2",
            "type": "tool",
            "callID": "call_2",
            "tool": "edit",
            "state": {"status": "completed"},
        }
    },
}
stdin_data = "\n".join(json.dumps(x) for x in [tool_part, tool_part_done, second]).encode() + b"\n"

proc = subprocess.run([sys.executable, demux, "opencode", "", usage_file], input=stdin_data, capture_output=True)
assert proc.returncode == 0, proc.stderr.decode()

with open(usage_file) as fh:
    d = json.load(fh)

assert d["tool_calls_total"] == 2, d
assert d["tool_calls_by_tool"] == {"bash": 1, "edit": 1}, d
assert d["tool_calls_sequence"] == ["bash", "edit"], d
print("opencode ToolPart assertions passed")
PY

  [ "$status" -eq 0 ]
  [[ "$output" == *"opencode ToolPart assertions passed"* ]]
  rm -rf "$tmpdir"
}

@test "demux does not persist generic OpenCode event ids as session ids" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  local demux tmpdir sid_file usage_file
  demux="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan-cli-json-demux.py"
  tmpdir="$(mktemp -d)"
  sid_file="$tmpdir/session-id.opencode.txt"
  usage_file="$tmpdir/opencode.usage.json"

  run python3 - "$demux" "$sid_file" "$usage_file" <<'PY'
import subprocess, sys
demux = sys.argv[1]
sid_file = sys.argv[2]
usage_file = sys.argv[3]
stdin_data = b'{"type":"step_finish","id":"event-not-session","part":{"tokens":{"input":1,"output":2}}}\n'
proc = subprocess.run([sys.executable, demux, "opencode", sid_file, usage_file], input=stdin_data, capture_output=True)
assert proc.returncode == 0, proc.stderr.decode()
print("opencode generic id ignored")
PY

  [ "$status" -eq 0 ]
  [[ "$output" == *"opencode generic id ignored"* ]]
  [ ! -e "$sid_file" ]
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

@test "plan usage summary reports cumulative and average labels" {
  local hits
  hits="$(grep -cE 'echo -e.*Plan total across .*cache_create=.*cache_read=.*output=.*est=' "$CORE_FILE" || true)"
  [ "$hits" -eq 1 ]

  hits="$(grep -cE 'echo -e.*Per-invocation average:.*cache_create=.*cache_read=.*output=.*est=' "$CORE_FILE" || true)"
  [ "$hits" -eq 1 ]
}

@test "per-invocation usage stderr includes cost and zero-aware estimate when USAGE_FILE is populated" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  local tmpdir usage_file snippet script
  tmpdir="$(mktemp -d)"
  usage_file="$tmpdir/usage.json"
  snippet="$tmpdir/per-invocation.snip.sh"
  script="$tmpdir/per-invocation.sh"

  cat <<'JSON' >"$usage_file"
{
  "schema_version": 1,
  "kind": "plan_invocation_usage_history",
  "invocations": [
    {
      "iteration": 1,
      "model": "claude-sonnet-4-6",
      "runtime": "claude",
      "plan_key": "PLAN9",
      "stage_id": "stage-1",
      "started_at": "2026-04-17T00:00:00Z",
      "ended_at": "2026-04-17T00:00:03Z",
      "elapsed_seconds": 3,
      "input_tokens": 0,
      "output_tokens": 0,
      "cache_creation_input_tokens": 0,
      "cache_read_input_tokens": 0,
      "max_turn_total_tokens": 0,
      "cache_hit_ratio": 0
    }
  ]
}
JSON

  sed -n '/^    # Read per-invocation token usage from demux.py output (only when JSON streaming was active)\./,/^    # Bump session turn counter and maybe rotate to cap cache growth/p' "$CORE_FILE" >"$snippet"

  cat <<EOF >"$script"
#!/usr/bin/env bash
set -euo pipefail
ralph_run_plan_log() { :; }
_ralph_append_invocation_usage_history() { :; }

source "${REPO_ROOT}/bundle/.ralph/bash-lib/ralph-format-elapsed.sh"

USAGE_FILE="\$1"
SELECTED_MODEL="claude-sonnet-4-6"
iteration=3
RUNTIME="claude"
PLAN_PATH="PLAN9.md"
RALPH_PLAN_KEY="PLAN9"
RALPH_STAGE_ID="stage-1"
RALPH_LOG_DIR="\$2"
OUTPUT_LOG="\$2/output.log"
EXIT_CODE_FILE="\$2/exit-code"
START_TIME="\$(date +%s)"
_inv_started_at="2026-04-17T00:00:00Z"
_total_input_tokens=0
_total_output_tokens=0
_total_cache_creation_tokens=0
_total_cache_read_tokens=0
_total_max_turn_tokens=0
_inv_input=0
_inv_output=0
_inv_cache_create=0
_inv_cache_read=0
_inv_max_turn=0
_inv_cache_hit_ratio=0
_inv_elapsed=0
_inv_ended_at="2026-04-17T00:00:03Z"
exit_code=0
_inv_used_resume_session_id=0
_inv_resume_session_id=""
_reset_retry_done_for_line=0
SESSION_ID_FILE="\$2/session-id.claude.txt"
RALPH_PLAN_SESSION_STRATEGY="fresh"
RESUME_SESSION_ID_OVERRIDE=""
line_num=5
task_ordinal=1
todo_text="do thing"
human_gate_satisfied_for_line=0

ralph_session_reset_resume_error_detected() { return 1; }
get_next_todo() { printf '5|- [ ] do thing\n'; }
plan_todo_implies_operator_dialog() { return 1; }

source "\$3"
EOF
  chmod +x "$script"

  run "$script" "$usage_file" "$tmpdir" "$snippet"
  [ "$status" -eq 0 ]
  [[ "$output" == *"invocation 3  input=0  cache_create=0  cache_read=0  output=0  tools=0  est=\$0.000  cache_hit=0%"* ]]

  rm -rf "$tmpdir"
}

@test "plan summary stderr includes cumulative and average lines and respects NO_COLOR" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  local tmpdir snippet script
  tmpdir="$(mktemp -d)"
  snippet="$tmpdir/summary.fn.sh"
  script="$tmpdir/summary.sh"

  sed -n '/^_ralph_write_plan_usage_summary() {/,/^}$/p' "$CORE_FILE" >"$snippet"

  cat <<EOF >"$script"
#!/usr/bin/env bash
set -euo pipefail
source "${REPO_ROOT}/bundle/.ralph/bash-lib/ralph-format-elapsed.sh"
EOF
  cat <<'EOF' >>"$script"
source "$1"
ralph_run_plan_log() { :; }

if [[ "${NO_COLOR:-0}" == "1" ]]; then
  C_DIM=""
  C_RST=""
else
  C_DIM=$'\033[2m'
  C_RST=$'\033[0m'
fi

SELECTED_MODEL="claude-sonnet-4-6"
RUNTIME="claude"
PLAN_PATH="PLAN9.md"
RALPH_PLAN_KEY="PLAN9"
RALPH_ARTIFACT_NS="PLAN9"
RALPH_STAGE_ID="stage-1"
RALPH_LOG_DIR="$2"
mkdir -p "$RALPH_LOG_DIR"
total_invocations=3
_plan_start_ts="$(( $(date +%s) - 5 ))"
_plan_started_at="2026-04-17T00:00:00Z"
_total_input_tokens=12345
_total_output_tokens=4321
_total_cache_creation_tokens=67
_total_cache_read_tokens=89
_total_max_turn_tokens=500

_ralph_write_plan_usage_summary 1 3
EOF
  chmod +x "$script"

  run env NO_COLOR=1 "$script" "$snippet" "$tmpdir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Plan total across 3 invocations: input=12,345 cache_create=67 cache_read=89 output=4,321 est=\$"* ]]
  [[ "$output" == *"Per-invocation average: input=4,115 cache_create=22 cache_read=30 output=1,440 est=\$"* ]]
  [[ "$output" != *$'\e['* ]]

  rm -rf "$tmpdir"
}

@test "plan summary recomputes totals and model breakdown from invocation history" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  local tmpdir snippet script
  tmpdir="$(mktemp -d)"
  snippet="$tmpdir/summary.fn.sh"
  script="$tmpdir/summary.sh"

  sed -n '/^_ralph_write_plan_usage_summary() {/,/^}$/p' "$CORE_FILE" >"$snippet"

  cat <<EOF >"$script"
#!/usr/bin/env bash
set -euo pipefail
source "${REPO_ROOT}/bundle/.ralph/bash-lib/ralph-format-elapsed.sh"
EOF
  cat <<'EOF' >>"$script"
source "$1"
ralph_run_plan_log() { :; }
C_DIM=""
C_RST=""

SELECTED_MODEL="gpt-5.4-mini"
RUNTIME="codex"
PLAN_PATH="PLAN9.md"
RALPH_PLAN_KEY="PLAN9"
RALPH_ARTIFACT_NS="PLAN9"
RALPH_STAGE_ID=""
RALPH_LOG_DIR="$2"
SCRIPT_DIR="${REPO_ROOT}/bundle/.ralph"
mkdir -p "$RALPH_LOG_DIR"
cat >"$RALPH_LOG_DIR/invocation-usage.json" <<'JSON'
{
  "schema_version": 1,
  "kind": "plan_invocation_usage_history",
  "invocations": [
    {
      "iteration": 1,
      "model": "gpt-5.4-mini",
      "runtime": "codex",
      "elapsed_seconds": 3,
      "input_tokens": 100,
      "output_tokens": 20,
      "cache_creation_input_tokens": 0,
      "cache_read_input_tokens": 10,
      "max_turn_total_tokens": 400,
      "started_at": "2026-04-17T00:00:00Z",
      "ended_at": "2026-04-17T00:00:03Z"
    },
    {
      "iteration": 2,
      "model": "claude-sonnet-4-6",
      "runtime": "claude",
      "elapsed_seconds": 7,
      "input_tokens": 200,
      "output_tokens": 30,
      "cache_creation_input_tokens": 5,
      "cache_read_input_tokens": 20,
      "max_turn_total_tokens": 900,
      "started_at": "2026-04-17T00:01:00Z",
      "ended_at": "2026-04-17T00:01:07Z"
    }
  ]
}
JSON
total_invocations=1
_plan_start_ts="$(( $(date +%s) - 1 ))"
_plan_started_at="2026-04-17T00:02:00Z"
_total_input_tokens=1
_total_output_tokens=1
_total_cache_creation_tokens=0
_total_cache_read_tokens=0
_total_max_turn_tokens=1

_ralph_write_plan_usage_summary 1 2
EOF
  chmod +x "$script"

  run env NO_COLOR=1 "$script" "$snippet" "$tmpdir"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }

  python3 - "$tmpdir/plan-usage-summary.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    summary = json.load(fh)

assert summary["invocations"] == 2, summary
assert summary["elapsed_seconds"] == 10, summary
assert summary["input_tokens"] == 300, summary
assert summary["output_tokens"] == 50, summary
assert summary["cache_creation_input_tokens"] == 5, summary
assert summary["cache_read_input_tokens"] == 30, summary
assert summary["max_turn_total_tokens"] == 900, summary
assert summary["started_at"] == "2026-04-17T00:00:00Z", summary
assert summary["ended_at"] == "2026-04-17T00:01:07Z", summary
assert abs(float(summary["cache_hit_ratio"]) - 0.0896) < 1e-9, summary
breakdown = summary.get("model_breakdown")
assert isinstance(breakdown, list) and len(breakdown) == 2, summary
keys = {(item["runtime"], item["model"]) for item in breakdown}
assert keys == {("codex", "gpt-5.4-mini"), ("claude", "claude-sonnet-4-6")}, breakdown
PY

  [[ "$output" == *"Plan total across 2 invocations: input=300 cache_create=5 cache_read=30 output=50 est=\$"* ]]

  rm -rf "$tmpdir"
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

@test "demux counts Claude tool_use blocks by unique id" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  local demux tmpdir usage_file
  demux="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan-cli-json-demux.py"
  tmpdir="$(mktemp -d)"
  usage_file="$tmpdir/claude-tools.usage.json"

  run python3 - "$demux" "$usage_file" <<'PY'
import json, subprocess, sys

demux = sys.argv[1]
usage_file = sys.argv[2]

assistant_event = {
    "type": "assistant",
    "message": {
        "content": [
            {"type": "tool_use", "id": "toolu_1", "name": "Read", "input": {"file_path": "a"}},
            {"type": "tool_use", "id": "toolu_2", "name": "Bash", "input": {"command": "rg x"}},
        ]
    },
}
duplicate = {
    "type": "assistant",
    "message": {
        "content": [
            {"type": "tool_use", "id": "toolu_1", "name": "Read", "input": {"file_path": "a"}}
        ]
    },
}
stdin_data = (json.dumps(assistant_event) + "\n" + json.dumps(duplicate) + "\n").encode()

proc = subprocess.run([sys.executable, demux, "claude", "", usage_file], input=stdin_data, capture_output=True)
assert proc.returncode == 0, proc.stderr.decode()

with open(usage_file) as fh:
    d = json.load(fh)

assert d["tool_calls_total"] == 2, d
assert d["tool_calls_by_tool"] == {"Read": 1, "Bash": 1}, d
assert d["tool_calls_sequence"] == ["Read", "Bash"], d
print("claude tool_use assertions passed")
PY

  [ "$status" -eq 0 ]
  [[ "$output" == *"claude tool_use assertions passed"* ]]
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
    "tool_turns": 0,
    "tool_calls_total": 0,
    "tool_calls_by_tool": {},
    "tool_calls_sequence": [],
}, d
print("cursor demux assertions passed")
PY

  [ "$status" -eq 0 ]
  [[ "$output" == *"cursor demux assertions passed"* ]]
  rm -rf "$tmpdir"
}

@test "demux extracts cursor stream-json tool calls and final usage" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  local demux tmpdir usage_file
  demux="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan-cli-json-demux.py"
  tmpdir="$(mktemp -d)"
  usage_file="$tmpdir/cursor-stream.usage.json"

  run python3 - "$demux" "$usage_file" <<'PY'
import json, subprocess, sys

demux = sys.argv[1]
usage_file = sys.argv[2]

events = [
    {"type": "assistant", "tool_calls": [{"id": "call_1", "function": {"name": "read_file"}}]},
    {"type": "assistant", "tool_calls": [{"id": "call_1", "function": {"name": "read_file"}}]},
    {"type": "tool_call", "id": "call_2", "name": "grep"},
    {"type": "result", "usage": {"inputTokens": 100, "outputTokens": 40, "cacheReadTokens": 15, "cacheWriteTokens": 9}},
]
stdin_data = "\n".join(json.dumps(x) for x in events).encode() + b"\n"

proc = subprocess.run([sys.executable, demux, "cursor", "", usage_file], input=stdin_data, capture_output=True)
assert proc.returncode == 0, proc.stderr.decode()

with open(usage_file) as fh:
    d = json.load(fh)

assert d["input_tokens"] == 100, d
assert d["output_tokens"] == 40, d
assert d["cache_read_input_tokens"] == 15, d
assert d["cache_creation_input_tokens"] == 9, d
assert d["tool_calls_total"] == 2, d
assert d["tool_calls_by_tool"] == {"read_file": 1, "grep": 1}, d
assert d["tool_calls_sequence"] == ["read_file", "grep"], d
print("cursor stream-json tool assertions passed")
PY

  [ "$status" -eq 0 ]
  [[ "$output" == *"cursor stream-json tool assertions passed"* ]]
  rm -rf "$tmpdir"
}
