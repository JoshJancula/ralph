#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

CORE_FILE="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-core.sh"

@test "invocation usage history is written to a single JSON file" {
  [ -x "$(command -v python3)" ] || skip "python3 required for JSON write/update"

  local tmpdir core_lib funcs usage_file
  tmpdir="$(mktemp -d)"
  core_lib="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-core.sh"
  funcs="$tmpdir/funcs.sh"
  usage_file="$tmpdir/invocation-usage.json"

  run bash -c '
    set -euo pipefail
    sed -n "/^_ralph_append_invocation_usage_history() {/,/^}$/p" "$1" >"$2"
    SCRIPT_DIR="$(dirname "$(dirname "$(dirname "$1")")")"
    source "$2"
    _ralph_append_invocation_usage_history "$3" 1 "m1" "cursor" 3 10 20 0 1 0 0 "2026-04-17T00:00:00Z" "2026-04-17T00:00:03Z" "plan-1" "stage-1" "fresh" "12" "2" "1"
    _ralph_append_invocation_usage_history "$3" 2 "m2" "claude" 4 11 21 0 2 500 0.75 "2026-04-17T00:00:04Z" "2026-04-17T00:00:09Z" "plan-1" "stage-2"
    python3 - <<PY
import json
with open("'"$usage_file"'", "r", encoding="utf-8") as fh:
    doc = json.load(fh)
assert doc["kind"] == "plan_invocation_usage_history"
assert doc["schema_version"] == 2
assert len(doc["invocations"]) == 2
assert doc["invocations"][0]["iteration"] == 1
assert doc["invocations"][1]["iteration"] == 2
assert doc["invocations"][1]["max_turn_total_tokens"] == 500
assert doc["invocations"][1]["cache_hit_ratio"] == round(2 / 13, 4)
assert doc["invocations"][0]["cache_efficiency_ratio"] == round(1 / 11, 4)
assert "measurement_source" in doc["invocations"][0]
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
  core_lib="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-core.sh"
  funcs="$tmpdir/funcs.sh"
  usage_file="$tmpdir/invocation-usage.json"

  run bash -c '
    set -euo pipefail
    sed -n "/^_ralph_append_invocation_usage_history() {/,/^}$/p" "$1" >"$2"
    SCRIPT_DIR="$(dirname "$(dirname "$(dirname "$1")")")"
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
  core_lib="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-core.sh"
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
  demux="$REPO_ROOT/bundle/.ralph/python/run-plan-cli-json-demux.py"
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
  demux="$REPO_ROOT/bundle/.ralph/python/run-plan-cli-json-demux.py"
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
  demux="$REPO_ROOT/bundle/.ralph/python/run-plan-cli-json-demux.py"
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
  demux="$REPO_ROOT/bundle/.ralph/python/run-plan-cli-json-demux.py"
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
  demux="$REPO_ROOT/bundle/.ralph/python/run-plan-cli-json-demux.py"
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

expected = {
    "input_tokens": 76268,
    "output_tokens": 1040,
    "cache_creation_input_tokens": 600,
    "cache_read_input_tokens": 16000,
    "max_turn_total_tokens": 0,
    "tool_turns": 4,
    "tool_calls_total": 0,
    "tool_calls_by_tool": {},
    "tool_calls_sequence": [],
    "opencode_cache_fields_seen": 1,
    "ralph_proxy_calls": 0,
    "other_mcp_calls": 0,
    "native_read_like_calls": 0,
    "native_write_like_calls": 0,
    "native_file_read_calls": 0,
    "native_read_compatibility_calls": 0,
    "native_search_calls": 0,
    "native_shell_calls": 0,
    "ralph_mcp_calls": 0,
    "runtime_hook_rewrite_calls": 0,
    "runtime_hook_compaction_calls": 0,
    "unknown_tool_calls": 0,
    "cache_read_per_tool_turn": 4000.0,
    "cache_read_per_tool_call": 0.0,
    "tool_call_targets": [],
    "adjacent_duplicate_tool_calls": 0,
    "repeated_read_targets": 0,
    "repeated_read_extra_calls": 0,
    "plan_file_read_calls": 0,
    "completion_sentinel_seen": False,
}
for key, value in expected.items():
    assert d.get(key) == value, f"{key}: {d.get(key)!r} != {value!r}"
assert d.get("uncached_input_tokens") == 76268
assert d.get("total_input_tokens") == 92868
assert d.get("cache_efficiency_ratio") == round(16000 / 92868, 4)
assert isinstance(d.get("measurement_source"), dict)
print("opencode demux assertions passed")
PY

  [ "$status" -eq 0 ]
  [[ "$output" == *"opencode demux assertions passed"* ]]
  rm -rf "$tmpdir"
}

@test "demux counts OpenCode ToolPart events by callID" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  local demux tmpdir usage_file
  demux="$REPO_ROOT/bundle/.ralph/python/run-plan-cli-json-demux.py"
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
  demux="$REPO_ROOT/bundle/.ralph/python/run-plan-cli-json-demux.py"
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
  local core="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-core.sh"
  local hits
  hits="$(grep -cE 'echo -e.*Model:.*[|].*Runtime:.*[|].*Plan Elapsed:' "$core" || true)"
  [ "$hits" -eq 1 ]
}

@test "plan invocation banner keeps Ralph Mode on the task line and omits a standalone Ralph Mode row" {
  local core="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-core.sh"
  local inline_hits standalone_hits

  inline_hits="$(grep -cF 'echo -e "  ${C_DIM}${C_RST}  ${C_BOLD}TASK ${task_ordinal}${C_RST}  ${C_DIM}|${C_RST}  Complete ${C_G}$done_count/$total_count |${C_RST} Skipped: 0 ${C_DIM}|${C_RST}  ${C_Y}Invoke $iteration${C_RST} (line $line_num)  ${C_DIM}|${C_RST}  ${_banner_ralph_mode_style}Ralph Mode: ${RALPH_MODE:-no}${C_RST}"' "$core" || true)"
  [ "$inline_hits" -eq 1 ]

  standalone_hits="$(grep -cF 'echo -e "  ${_banner_ralph_mode_style}Ralph Mode: ${RALPH_MODE:-no}${C_RST}"' "$core" || true)"
  [ "$standalone_hits" -eq 0 ]
}

@test "plan usage summary reports cumulative and average labels" {
  local hits
  hits="$(grep -cE 'echo -e.*Plan total across .*cache_create=.*cache_read=.*output=.*est=' "$CORE_FILE" || true)"
  [ "$hits" -eq 1 ]

  hits="$(grep -cE 'echo -e.*Per-invocation average:.*cache_create=.*cache_read=.*output=.*est=' "$CORE_FILE" || true)"
  [ "$hits" -eq 1 ]
}

@test "usage block renderer keeps the tables and omits legacy plaintext lines" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  local tmpdir snippet script start_line end_line
  tmpdir="$(mktemp -d)"
  snippet="$tmpdir/usage-block.sh"
  script="$tmpdir/run.sh"

  start_line="$(grep -n '^    _inv_summary_common_args=(' "$CORE_FILE" | head -1 | cut -d: -f1)"
  end_line="$(grep -n '^    _inv_usage_block="$(' "$CORE_FILE" | head -1 | cut -d: -f1)"
  end_line="$(awk -v start="$end_line" 'NR >= start && $0 ~ /^    \)"$/ { print NR; exit }' "$CORE_FILE")"
  sed -n "${start_line},${end_line}p" "$CORE_FILE" >"$snippet"

  cat <<EOF >"$script"
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="${REPO_ROOT}/bundle/.ralph"
_inv_elapsed=3
_inv_input=610827
_inv_output=3178
_inv_cache_create=0
_inv_cache_read=0
_inv_cache_hit_pct=0
_prompt_bytes=0
_todo_bytes=0
_todo_continuation_lines=0
_rate_limit_status=none
_inv_usage_json='{"tool_calls_by_tool":{"ralph_proxy_read":12,"edit":3}}'
iteration=1
RUNTIME="opencode"
_inv_effective_runtime="opencode"
SELECTED_MODEL="ollama-cloud/kimi-k2.5"
task_ordinal=1
line_num=40
done_count=1
total_count=11
source "\$1"
printf '%s\n' "\$_inv_usage_block"
printf '%s\n' '---LOG---'
printf '%s\n' "\$_inv_usage_block_log"
EOF
  chmod +x "$script"

  run "$script" "$snippet"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Runtime Details"* ]]
  [[ "$output" == *"Usage Summary"* ]]
  [[ "$output" == *"Tool Usage Details"* ]]
  [[ "$output" != *"invocation 3  input="* ]]
  [[ "$output" != *"tool access audit:"* ]]

  local log_section
  log_section="${output#*---LOG---$'\n'}"
  [[ "$log_section" == *"Runtime Details"* ]]
  [[ "$(printf '%s' "$log_section" | grep -c $'\x1b' || true)" -eq 0 ]]
  [[ "$log_section" == *"+"* ]]
  [[ "$log_section" != *"┌"* ]]

  rm -rf "$tmpdir"
}

@test "plan summary stderr includes cumulative and average lines and respects NO_COLOR" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  local tmpdir snippet script
  tmpdir="$(mktemp -d)"
  snippet="$tmpdir/summary.fn.sh"
  script="$tmpdir/summary.sh"

  sed -n '/^run_plan_num_or_zero() {/,/^}$/p' "$CORE_FILE" >"$snippet"
  sed -n '/^_ralph_write_plan_usage_summary() {/,/^}$/p' "$CORE_FILE" >>"$snippet"

  cat <<EOF >"$script"
#!/usr/bin/env bash
set -euo pipefail
source "${REPO_ROOT}/bundle/.ralph/bash-lib/ralph-format-elapsed.sh"
SCRIPT_DIR="${REPO_ROOT}/bundle/.ralph"
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

  sed -n '/^run_plan_num_or_zero() {/,/^}$/p' "$CORE_FILE" >"$snippet"
  sed -n '/^_ralph_write_plan_usage_summary() {/,/^}$/p' "$CORE_FILE" >>"$snippet"

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
assert abs(float(summary["cache_read_per_tool_turn"]) - 30) < 1e-9, summary
assert abs(float(summary["cache_read_per_tool_call"]) - 0) < 1e-9, summary
breakdown = summary.get("model_breakdown")
assert isinstance(breakdown, list) and len(breakdown) == 2, summary
keys = {(item["runtime"], item["model"]) for item in breakdown}
assert keys == {("codex", "gpt-5.4-mini"), ("claude", "claude-sonnet-4-6")}, breakdown
PY

  [[ "$output" == *"Plan total across 2 invocations: input=300 cache_create=5 cache_read=30 output=50 est=\$"* ]]
  [[ "$output" == *"cache_read_per_turn="* ]]
  [[ "$output" == *"cache_read_per_call="* ]]

  rm -rf "$tmpdir"
}

@test "demux extracts Claude message.usage and top-level usage blocks" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  local demux tmpdir usage_file
  demux="$REPO_ROOT/bundle/.ralph/python/run-plan-cli-json-demux.py"
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

@test "demux does not misclassify Claude assistant usage when event also has top-level result payload" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  local demux tmpdir usage_file
  demux="$REPO_ROOT/bundle/.ralph/python/run-plan-cli-json-demux.py"
  tmpdir="$(mktemp -d)"
  usage_file="$tmpdir/claude-result-payload.usage.json"

  run python3 - "$demux" "$usage_file" <<'PY'
import json, subprocess, sys

demux = sys.argv[1]
usage_file = sys.argv[2]

assistant_event = json.dumps({
    "type": "assistant",
    "result": {"status": "intermediate"},
    "message": {"usage": {
        "input_tokens": 120,
        "output_tokens": 18,
        "cache_creation_input_tokens": 4000,
        "cache_read_input_tokens": 0,
    }},
})
result_event = json.dumps({
    "type": "result",
    "usage": {
        "input_tokens": 12,
        "output_tokens": 3,
        "cache_creation_input_tokens": 4000,
        "cache_read_input_tokens": 0,
    },
})
stdin_data = (assistant_event + "\n" + result_event + "\n").encode()

proc = subprocess.run([sys.executable, demux, "claude", "", usage_file], input=stdin_data, capture_output=True)
assert proc.returncode == 0, proc.stderr.decode()

with open(usage_file) as fh:
    d = json.load(fh)

assert d["input_tokens"] == 120, d
assert d["output_tokens"] == 18, d
assert d["cache_creation_input_tokens"] == 4000, d
assert d["cache_read_input_tokens"] == 0, d
print("claude result payload assertions passed")
PY

  [ "$status" -eq 0 ]
  [[ "$output" == *"claude result payload assertions passed"* ]]
  rm -rf "$tmpdir"
}

@test "demux counts Claude tool_use blocks by unique id" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  local demux tmpdir usage_file
  demux="$REPO_ROOT/bundle/.ralph/python/run-plan-cli-json-demux.py"
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
  demux="$REPO_ROOT/bundle/.ralph/python/run-plan-cli-json-demux.py"
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

expected = {
    "input_tokens": 100,
    "output_tokens": 40,
    "cache_creation_input_tokens": 9,
    "cache_read_input_tokens": 15,
    "max_turn_total_tokens": 0,
    "tool_turns": 0,
    "tool_calls_total": 1,
    "tool_calls_by_tool": {"ralph_proxy_read": 1},
    "tool_calls_sequence": ["ralph_proxy_read"],
    "opencode_cache_fields_seen": 0,
    "ralph_proxy_calls": 1,
    "other_mcp_calls": 0,
    "native_read_like_calls": 0,
    "native_write_like_calls": 0,
    "native_file_read_calls": 0,
    "native_read_compatibility_calls": 0,
    "native_search_calls": 0,
    "native_shell_calls": 0,
    "ralph_mcp_calls": 1,
    "runtime_hook_rewrite_calls": 0,
    "runtime_hook_compaction_calls": 0,
    "unknown_tool_calls": 0,
    "cache_read_per_tool_turn": 15.0,
    "cache_read_per_tool_call": 15.0,
    "tool_call_targets": [
        {
            "family": "read",
            "target": "",
            "tool": "ralph_proxy_read"
        }
    ],
    "adjacent_duplicate_tool_calls": 0,
    "repeated_read_targets": 0,
    "repeated_read_extra_calls": 0,
    "plan_file_read_calls": 0,
    "completion_sentinel_seen": False,
}
for key, value in expected.items():
    assert d.get(key) == value, f"{key}: {d.get(key)!r} != {value!r}"
assert d.get("uncached_input_tokens") == 100
assert d.get("total_input_tokens") == 124
assert d.get("cache_efficiency_ratio") == round(15 / 124, 4)
assert isinstance(d.get("measurement_source"), dict)
print("cursor demux assertions passed")
PY

  [ "$status" -eq 0 ]
  [[ "$output" == *"cursor demux assertions passed"* ]]
  rm -rf "$tmpdir"
}

@test "demux extracts cursor stream-json tool calls and final usage" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  local demux tmpdir usage_file
  demux="$REPO_ROOT/bundle/.ralph/python/run-plan-cli-json-demux.py"
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

@test "rate limit detection ignores allowed Claude telemetry" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  local tmpdir funcs
  tmpdir="$(mktemp -d)"
  funcs="$tmpdir/funcs.sh"
  sed -n '/^ralph_detect_rate_limit_status() {/,/^}$/p' "$CORE_FILE" >"$funcs"

  run bash -c '
    set -euo pipefail
    source "$1"
    text=$'"'"'{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","rateLimitType":"five_hour"}}
'"'"'
    if status=$(ralph_detect_rate_limit_status "$text"); then
      printf "detected:%s\n" "$status"
    else
      printf "none\n"
    fi
  ' _ "$funcs"

  [ "$status" -eq 0 ]
  [[ "$output" == "none" ]]
  rm -rf "$tmpdir"
}

@test "rate limit detection ignores grep hits on rate_limit source symbols" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  local tmpdir funcs
  tmpdir="$(mktemp -d)"
  funcs="$tmpdir/funcs.sh"
  sed -n '/^ralph_detect_rate_limit_status() {/,/^}$/p' "$CORE_FILE" >"$funcs"

  run bash -c '
    set -euo pipefail
    source "$1"
    text="bundle/.ralph/bash-lib/run-plan/run-plan-core.sh:2997: ... \"\${_rate_limit_status:-none}\" ..."
    if status=$(ralph_detect_rate_limit_status "$text"); then
      printf "detected:%s\n" "$status"
    else
      printf "none\n"
    fi
  ' _ "$funcs"

  [ "$status" -eq 0 ]
  [[ "$output" == "none" ]]
  rm -rf "$tmpdir"
}

@test "rate limit detection still flags hard rejection text" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  local tmpdir funcs
  tmpdir="$(mktemp -d)"
  funcs="$tmpdir/funcs.sh"
  sed -n '/^ralph_detect_rate_limit_status() {/,/^}$/p' "$CORE_FILE" >"$funcs"

  run bash -c '
    set -euo pipefail
    source "$1"
    text="Error: request rejected because you have hit your rate limit for this model."
    status=$(ralph_detect_rate_limit_status "$text")
    printf "detected:%s\n" "$status"
  ' _ "$funcs"

  [ "$status" -eq 0 ]
  [[ "$output" == "detected:rate_limited" ]]
  rm -rf "$tmpdir"
}

@test "fresh prompt Rules block in source file contains escaped backticks" {
  # Locate the fresh Rules verification-ownership line by content (robust to line
  # shifts). Escaped backticks here prevent command substitution when the
  # double-quoted PROMPT string is assembled.
  local start_line next_line
  start_line="$(grep -nF 'do not rerun those commands through agent-side \`ralph_proxy_shell_start\`' "$CORE_FILE" | head -1 | cut -d: -f1)"
  [ -n "$start_line" ]
  next_line=$(( start_line + 1 ))

  sed -n "${start_line}p" "$CORE_FILE" | grep -c 'verify:' | grep -qv '^0$'
  sed -n "${start_line}p" "$CORE_FILE" | grep -qF '\`verify:\'
  sed -n "${start_line}p" "$CORE_FILE" | grep -qF '\`ralph_proxy_shell_'
  sed -n "${next_line}p" "$CORE_FILE" | grep -qF '\`verification:\'
  sed -n "${next_line}p" "$CORE_FILE" | grep -qF '\`ralph_proxy_shell_'
}

@test "fresh completion rules block executes without command substitution errors" {
  local tmpdir funcs output
  tmpdir="$(mktemp -d)"
  funcs="$tmpdir/funcs.sh"
  sed -n '/^ralph_run_plan_fresh_completion_rules_block() {/,/^}$/p' "$CORE_FILE" >"$funcs"

  run bash -c '
    set -euo pipefail
    source "$1"
    ralph_run_plan_fresh_completion_rules_block 42 /tmp/pending.txt 1
  ' _ "$funcs"

  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [[ "$output" == *"completion footer"* ]] || [[ "$output" == *"TODO"* ]]

  rm -rf "$tmpdir"
}

@test "invocation usage history records continuation summary telemetry from env" {
  [ -x "$(command -v python3)" ] || skip "python3 required for JSON write/update"

  local tmpdir core_lib funcs usage_file
  tmpdir="$(mktemp -d)"
  core_lib="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-core.sh"
  funcs="$tmpdir/funcs.sh"
  usage_file="$tmpdir/invocation-usage.json"

  run bash -c '
    set -euo pipefail
    sed -n "/^_ralph_append_invocation_usage_history() {/,/^}$/p" "$1" >"$2"
    SCRIPT_DIR="$(dirname "$(dirname "$(dirname "$1")")")"
    source "$2"
    export RALPH_CONTINUATION_SUMMARY_BYTES=1200
    export RALPH_CONTINUATION_SUMMARY_ENTRY_COUNT=2
    export RALPH_CONTINUATION_SUMMARY_TRUNCATION_COUNT=1
    _ralph_append_invocation_usage_history "$3" 1 "m1" "cursor" 3 10 20 0 1 0 0 "2026-04-17T00:00:00Z" "2026-04-17T00:00:03Z" "plan-1" "" "fresh" "12" "2" "0"
    python3 - <<PY
import json
with open("'"$usage_file"'", "r", encoding="utf-8") as fh:
    doc = json.load(fh)
record = doc["invocations"][0]
assert record["continuation_summary_bytes"] == 1200
assert record["continuation_summary_entry_count"] == 2
assert record["continuation_summary_truncation_count"] == 1
PY
  ' _ "$core_lib" "$funcs" "$usage_file"

  [ "$status" -eq 0 ]

  rm -rf "$tmpdir"
}

@test "invocation usage history records speculative cache warm separately" {
  [ -x "$(command -v python3)" ] || skip "python3 required for JSON write/update"

  local tmpdir core_lib funcs usage_file
  tmpdir="$(mktemp -d)"
  core_lib="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-core.sh"
  funcs="$tmpdir/funcs.sh"
  usage_file="$tmpdir/invocation-usage.json"

  run bash -c '
    set -euo pipefail
    sed -n "/^_ralph_append_invocation_usage_history() {/,/^}$/p" "$1" >"$2"
    SCRIPT_DIR="$(dirname "$(dirname "$(dirname "$1")")")"
    source "$2"
    export RALPH_USAGE_INVOCATION_KIND=speculative_cache_warm
    _ralph_append_invocation_usage_history "$3" 2 "m1" "claude" 1 1000 1 900 0 0 0 "2026-04-17T00:00:10Z" "2026-04-17T00:00:11Z" "plan-1" "" "speculative_cache_warm" "20" "2" "0"
    unset RALPH_USAGE_INVOCATION_KIND
    _ralph_append_invocation_usage_history "$3" 2 "m1" "claude" 30 500 200 0 100 0 0.2 "2026-04-17T00:00:12Z" "2026-04-17T00:00:42Z" "plan-1" "" "fresh" "21" "3" "1"
    python3 - <<PY
import json
with open("'"$usage_file"'", "r", encoding="utf-8") as fh:
    doc = json.load(fh)
assert len(doc["invocations"]) == 2
warm = doc["invocations"][0]
productive = doc["invocations"][1]
assert warm["invocation_kind"] == "speculative_cache_warm"
assert productive.get("invocation_kind") is None
assert warm["output_tokens"] == 1
assert productive["output_tokens"] == 200
assert warm["session_strategy"] == "speculative_cache_warm"
assert productive["session_strategy"] == "fresh"
PY
  ' _ "$core_lib" "$funcs" "$usage_file"

  [ "$status" -eq 0 ]

  rm -rf "$tmpdir"
}
