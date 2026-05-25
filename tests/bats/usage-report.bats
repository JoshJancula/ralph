#!/usr/bin/env bats
# shellcheck shell=bash

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="$REPO_ROOT/bundle/.ralph/bash-lib/ralph-usage-summary-text.py"
  REPORT_SCRIPT="$REPO_ROOT/bundle/.ralph/usage-report.sh"

  tmpdir="$(mktemp -d)"

  mkdir -p "$tmpdir/PLAN1"
  cat <<'JSON' >"$tmpdir/PLAN1/plan-usage-summary.json"
{
  "schema_version": 1,
  "kind": "plan_usage_summary",
  "plan": "PLAN1.md",
  "plan_key": "PLAN1",
  "artifact_ns": "PLAN1",
  "stage_id": "stage-1",
  "model": "claude-sonnet-4-6",
  "runtime": "claude",
  "invocations": 1,
  "todos_done": 2,
  "todos_total": 2,
  "started_at": "2026-04-17T00:00:00Z",
  "ended_at": "2026-04-17T00:00:10Z",
  "elapsed_seconds": 1,
  "input_tokens": 1,
  "output_tokens": 1,
  "cache_creation_input_tokens": 0,
  "cache_read_input_tokens": 0,
  "max_turn_total_tokens": 1,
  "cache_hit_ratio": 0
}
JSON

  cat <<'JSON' >"$tmpdir/PLAN1/invocation-usage.json"
{
  "schema_version": 1,
  "kind": "plan_invocation_usage_history",
  "invocations": [
    {
      "iteration": 1,
      "model": "claude-sonnet-4-6",
      "runtime": "claude",
      "plan_key": "PLAN1",
      "stage_id": "stage-1",
      "elapsed_seconds": 5,
      "input_tokens": 50,
      "output_tokens": 25,
      "cache_creation_input_tokens": 5,
      "cache_read_input_tokens": 10,
      "max_turn_total_tokens": 300
    },
    {
      "iteration": 2,
      "model": "claude-sonnet-4-6",
      "runtime": "claude",
      "elapsed_seconds": 5,
      "input_tokens": 50,
      "output_tokens": 25,
      "cache_creation_input_tokens": 5,
      "cache_read_input_tokens": 10,
      "max_turn_total_tokens": 500
    }
  ]
}
JSON

  mkdir -p "$tmpdir/PLAN2"
  cat <<'JSON' >"$tmpdir/PLAN2/plan-usage-summary.json"
{
  "schema_version": 1,
  "kind": "plan_usage_summary",
  "plan": "PLAN2.md",
  "plan_key": "PLAN2",
  "artifact_ns": "PLAN2",
  "stage_id": "stage-2",
  "model": "gpt-5.1-codex-mini",
  "runtime": "codex",
  "invocations": 1,
  "todos_done": 2,
  "todos_total": 5,
  "started_at": "2026-04-17T00:00:20Z",
  "ended_at": "2026-04-17T00:00:25Z",
  "elapsed_seconds": 5,
  "input_tokens": 60,
  "output_tokens": 40,
  "cache_creation_input_tokens": 0,
  "cache_read_input_tokens": 0,
  "max_turn_total_tokens": 250,
  "cache_hit_ratio": 0
}
JSON

  cat <<'JSON' >"$tmpdir/PLAN2/invocation-usage.json"
{
  "schema_version": 1,
  "kind": "plan_invocation_usage_history",
  "invocations": [
    {
      "iteration": 1,
      "model": "gpt-5.1-codex-mini",
      "runtime": "codex",
      "plan_key": "PLAN2",
      "stage_id": "stage-2",
      "elapsed_seconds": 5,
      "input_tokens": 60,
      "output_tokens": 40,
      "cache_creation_input_tokens": 0,
      "cache_read_input_tokens": 0,
      "max_turn_total_tokens": 250
    }
  ]
}
JSON

  mkdir -p "$tmpdir/ORCH1"
  cat <<'JSON' >"$tmpdir/ORCH1/orchestration-usage-summary.json"
{
  "schema_version": 1,
  "kind": "orchestration_usage_summary",
  "orchestration": "demo.orch.json",
  "plan_key": "ORCH1",
  "artifact_ns": "ORCH1",
  "started_at": "2026-04-17T01:00:00Z",
  "ended_at": "2026-04-17T01:00:15Z",
  "steps": 2,
  "elapsed_seconds": 15,
  "input_tokens": 30,
  "output_tokens": 20,
  "cache_creation_input_tokens": 2,
  "cache_read_input_tokens": 4,
  "stages": [
    {
      "step": 1,
      "agent": "research",
      "runtime": "claude",
      "input_tokens": 15,
      "output_tokens": 10,
      "cache_creation_input_tokens": 1,
      "cache_read_input_tokens": 2
    },
    {
      "step": 2,
      "agent": "implementation",
      "runtime": "codex",
      "input_tokens": 15,
      "output_tokens": 10,
      "cache_creation_input_tokens": 1,
      "cache_read_input_tokens": 2
    }
  ]
}
JSON

  cat <<'JSON' >"$tmpdir/ORCH1/invocation-usage.json"
{
  "schema_version": 1,
  "kind": "plan_invocation_usage_history",
  "invocations": [
    {
      "iteration": 1,
      "model": "claude-sonnet-4-6",
      "runtime": "claude",
      "plan_key": "ORCH1",
      "stage_id": "research",
      "elapsed_seconds": 7,
      "input_tokens": 15,
      "output_tokens": 10,
      "cache_creation_input_tokens": 1,
      "cache_read_input_tokens": 2,
      "max_turn_total_tokens": 200
    },
    {
      "iteration": 2,
      "model": "gpt-5.1-codex-mini",
      "runtime": "codex",
      "plan_key": "ORCH1",
      "stage_id": "implementation",
      "elapsed_seconds": 8,
      "input_tokens": 15,
      "output_tokens": 10,
      "cache_creation_input_tokens": 1,
      "cache_read_input_tokens": 2,
      "max_turn_total_tokens": 150
    }
  ]
}
JSON
}

write_usage_summary() {
  local logs_root="$1"
  local plan_key="$2"

  mkdir -p "$logs_root/$plan_key"
  cat <<JSON >"$logs_root/$plan_key/plan-usage-summary.json"
{
  "schema_version": 1,
  "kind": "plan_usage_summary",
  "plan": "${plan_key}.md",
  "plan_key": "$plan_key",
  "artifact_ns": "$plan_key",
  "stage_id": "stage-1",
  "model": "claude-sonnet-4-6",
  "runtime": "claude",
  "invocations": 1,
  "todos_done": 1,
  "todos_total": 1,
  "started_at": "2026-04-17T00:00:00Z",
  "ended_at": "2026-04-17T00:00:01Z",
  "elapsed_seconds": 1,
  "input_tokens": 1,
  "output_tokens": 1,
  "cache_creation_input_tokens": 0,
  "cache_read_input_tokens": 0,
  "max_turn_total_tokens": 1,
  "cache_hit_ratio": 0
}
JSON
}

@test "text output contains Overall totals header and Plans count" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  run python3 "$SCRIPT" all --logs-dir "$tmpdir"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }

  [[ "$output" == *"Overall totals"* ]]
  [[ "$output" == *"Plans (2)"* ]]
}

@test "text output lists both distinct models under By model" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  run python3 "$SCRIPT" all --logs-dir "$tmpdir"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }

  [[ "$output" == *"By model (2):"* ]]
  [[ "$output" == *"claude-sonnet-4-6"* ]]
  [[ "$output" == *"gpt-5.1-codex-mini"* ]]
}

@test "usage-report uses the direct local .ralph-workspace by default" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  local workspace_dir="$tmpdir/local-workspace"
  write_usage_summary "$workspace_dir/.ralph-workspace/logs" "DIRECT"

  cd "$workspace_dir"
  run bash "$REPORT_SCRIPT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }

  [[ "$output" == *"Workspace: $workspace_dir"* ]]
  [[ "$output" == *"Logs dir:"*"$workspace_dir/.ralph-workspace/logs"* ]]
}

@test "usage-report discovers a workspace under HOME from a non-workspace directory" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  local home_dir="$tmpdir/home"
  local workspace_dir="$tmpdir/non-workspace"
  write_usage_summary "$home_dir/discovered/.ralph-workspace/logs" "GLOBAL"
  mkdir -p "$workspace_dir"

  cd "$workspace_dir"
  run env HOME="$home_dir" bash "$REPORT_SCRIPT" --full
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }

  [[ "$output" == *"Workspace: $home_dir"* ]]
  [[ "$output" == *"Logs dir:"*"$home_dir/discovered/.ralph-workspace/logs"* ]]
}

@test "usage-report --full overrides a direct local workspace" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  local home_dir="$tmpdir/home"
  local workspace_dir="$tmpdir/local-workspace"
  write_usage_summary "$workspace_dir/.ralph-workspace/logs" "DIRECT"
  write_usage_summary "$home_dir/discovered/.ralph-workspace/logs" "GLOBAL"

  cd "$workspace_dir"
  run env HOME="$home_dir" bash "$REPORT_SCRIPT" --full
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }

  [[ "$output" == *"Workspace: $home_dir"* ]]
  [[ "$output" == *"Logs dir:"*"$home_dir/discovered/.ralph-workspace/logs"* ]]
}

@test "usage-report --full unions registry and filesystem workspaces" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  local home_dir="$tmpdir/home"
  local registry_workspace="$home_dir/projects/alpha"
  local discovered_workspace="$home_dir/Documents/projects/team/beta"
  local workspace_dir="$tmpdir/non-workspace"
  local reg_file="$tmpdir/workspaces.json"

  write_usage_summary "$registry_workspace/.ralph-workspace/logs" "REGISTRYPLAN"
  write_usage_summary "$discovered_workspace/.ralph-workspace/logs" "DISCOVEREDPLAN"
  mkdir -p "$workspace_dir"

  python3 - "$reg_file" "$registry_workspace" <<'PY'
import json
import os
import sys

registry = sys.argv[1]
workspace = os.path.abspath(sys.argv[2])
records = [{"path": workspace, "lastSeen": "2026-04-17T00:00:00Z", "planKey": "REGISTRYPLAN", "runtime": "claude"}]
with open(registry, "w", encoding="utf-8") as handle:
    json.dump(records, handle)
PY

  cd "$workspace_dir"
  run env HOME="$home_dir" RALPH_WORKSPACES_FILE="$reg_file" bash "$REPORT_SCRIPT" --full
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }

  [[ "$output" == *"REGISTRYPLAN"* ]]
  [[ "$output" == *"DISCOVEREDPLAN"* ]]
}

@test "usage-report honors an explicit --logs-dir without discovering workspaces" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  local home_dir="$tmpdir/home"
  local workspace_dir="$tmpdir/non-workspace"
  local custom_logs_dir="$tmpdir/manual-logs"
  write_usage_summary "$home_dir/discovered/.ralph-workspace/logs" "GLOBAL"
  write_usage_summary "$custom_logs_dir" "MANUAL"
  mkdir -p "$workspace_dir"

  cd "$workspace_dir"
  run env HOME="$home_dir" bash "$REPORT_SCRIPT" --full --logs-dir "$custom_logs_dir"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }

  [[ "$output" == *"Workspace: $home_dir"* ]]
  [[ "$output" == *"Logs dir:"*"$custom_logs_dir"* ]]
}

@test "incomplete plan row is flagged" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  run python3 "$SCRIPT" all --logs-dir "$tmpdir"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }

  [[ "$output" == *"PLAN2"*"incomplete"* ]]
}

@test "JSON format output parses and has correct input_tokens sum" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  run python3 "$SCRIPT" all --logs-dir "$tmpdir" --format json
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }

  echo "$output" | python3 -c 'import json,sys; json.load(sys.stdin)' || { echo "JSON parsing failed"; return 1; }

  local input_tokens
  input_tokens=$(echo "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["overall"]["input_tokens"])')
  [ "$input_tokens" -eq 190 ] || { echo "Expected 190 input_tokens, got $input_tokens"; return 1; }
}

@test "text output uses cumulative invocation history for per-plan rows" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  run python3 "$SCRIPT" all --logs-dir "$tmpdir"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }

  echo "$output" | python3 -c '
import sys

line = ""
for candidate in sys.stdin.read().splitlines():
    parts_try = [p.strip() for p in candidate.split("|")[1:-1]]
    if len(parts_try) >= 2 and parts_try[1] == "PLAN1":
        line = candidate
        break

if not line:
    raise SystemExit("PLAN1 row not found")

parts = [p.strip() for p in line.split("|")[1:-1]]
if len(parts) != 12:
    raise SystemExit(f"unexpected PLAN1 column count: {len(parts)}")

if parts[4] != "2":
    raise SystemExit(f"expected PLAN1 invocations=2, got {parts[4]}")
if parts[6] != "10s":
    raise SystemExit(f"expected PLAN1 elapsed=10s, got {parts[6]}")
if parts[7] != "100":
    raise SystemExit(f"expected PLAN1 input=100, got {parts[7]}")
if parts[8] != "50":
    raise SystemExit(f"expected PLAN1 output=50, got {parts[8]}")
if parts[10] != "15.38%":
    raise SystemExit(f"expected PLAN1 cache_hit=15.38%, got {parts[10]}")
'
}

@test "text output lists mixed runtimes and models in per-plan rows" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  local mixed_dir
  mixed_dir="$(mktemp -d)"
  mkdir -p "$mixed_dir/MIXED1"
  cat <<'JSON' >"$mixed_dir/MIXED1/plan-usage-summary.json"
{
  "schema_version": 1,
  "kind": "plan_usage_summary",
  "plan": "MIXED1.md",
  "plan_key": "MIXED1",
  "artifact_ns": "MIXED1",
  "model": "claude-haiku-4-5",
  "runtime": "claude",
  "invocations": 1,
  "todos_done": 2,
  "todos_total": 2,
  "started_at": "2026-04-17T02:00:00Z",
  "elapsed_seconds": 1,
  "input_tokens": 1,
  "output_tokens": 1,
  "cache_creation_input_tokens": 0,
  "cache_read_input_tokens": 0
}
JSON
  cat <<'JSON' >"$mixed_dir/MIXED1/invocation-usage.json"
{
  "schema_version": 1,
  "kind": "plan_invocation_usage_history",
  "invocations": [
    {
      "iteration": 1,
      "model": "claude-haiku-4-5",
      "runtime": "claude",
      "elapsed_seconds": 4,
      "input_tokens": 10,
      "output_tokens": 5,
      "cache_creation_input_tokens": 1,
      "cache_read_input_tokens": 2,
      "todo_line": 3,
      "todo_ordinal": 1,
      "todo_completed": true
    },
    {
      "iteration": 2,
      "model": "gpt-5.4-mini",
      "runtime": "codex",
      "elapsed_seconds": 6,
      "input_tokens": 20,
      "output_tokens": 7,
      "cache_creation_input_tokens": 0,
      "cache_read_input_tokens": 3,
      "todo_line": 4,
      "todo_ordinal": 2,
      "todo_completed": true
    }
  ]
}
JSON

  run python3 "$SCRIPT" all --logs-dir "$mixed_dir"
  local cmd_status="$status"
  local cmd_output="$output"
  rm -rf "$mixed_dir"

  [ "$cmd_status" -eq 0 ] || { echo "$cmd_output"; return 1; }

  echo "$cmd_output" | python3 -c '
import re
import sys

lines = sys.stdin.read().splitlines()
line = ""
subrows = []
for candidate in lines:
    parts_try = [p.strip() for p in candidate.split("|")[1:-1]]
    if len(parts_try) >= 2 and parts_try[1] == "MIXED1":
        line = candidate
    elif re.match(r"^\s*\|\s*\|\s*\|\s*(claude|codex)\s*\|", candidate):
        subrows.append(candidate)

if not line:
    raise SystemExit("MIXED1 row not found")

parts = [p.strip() for p in line.split("|")[1:-1]]
if parts[2] != "total":
    raise SystemExit(f"expected total runtime label, got {parts[2]}")
if parts[3] != "all":
    raise SystemExit(f"expected all model label, got {parts[3]}")
if parts[4] != "2":
    raise SystemExit(f"expected invocations=2, got {parts[4]}")
if any(row.split("|")[1].strip() == "-" for row in subrows):
    raise SystemExit(f"subrow still uses dash marker: {subrows}")

parsed = [[p.strip() for p in row.split("|")[1:-1]] for row in subrows]
if not any(row[2] == "claude" and row[3] == "claude-haiku-4-5" and row[4] == "1" and row[5] == "1" and row[7] == "10" and row[8] == "5" for row in parsed):
    raise SystemExit(f"claude subrow missing: {parsed}")
if not any(row[2] == "codex" and row[3] == "gpt-5.4-mini" and row[4] == "1" and row[5] == "1" and row[7] == "20" and row[8] == "7" for row in parsed):
    raise SystemExit(f"codex subrow missing: {parsed}")
solid_borders = [line for line in lines if re.match(r"^\s*\+-[-+]+\+$", line)]
if len(solid_borders) < 4:
    raise SystemExit(f"expected a solid divider between plan blocks, got {len(solid_borders)} borders")
'
}

@test "global usage-report includes the source project in plan rows" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  local ws_a="$tmpdir/project-a"
  local ws_b="$tmpdir/project-b"
  local home_dir="$tmpdir/home"
  local reg_file="$tmpdir/workspaces.json"
  local outside_dir="$tmpdir/outside"
  mkdir -p "$ws_a" "$ws_b" "$outside_dir" "$home_dir"
  write_usage_summary "$ws_a/.ralph-workspace/logs" "ALPHA"
  write_usage_summary "$ws_b/.ralph-workspace/logs" "BETA"

  python3 - "$reg_file" "$ws_a" "$ws_b" <<'PY'
import json
import os
import sys

registry = sys.argv[1]
workspaces = [os.path.abspath(sys.argv[2]), os.path.abspath(sys.argv[3])]
records = [{"path": ws, "lastSeen": "2026-04-17T00:00:00Z", "planKey": "ALPHA", "runtime": "claude"} for ws in workspaces]
with open(registry, "w", encoding="utf-8") as handle:
    json.dump(records, handle)
PY

  cd "$outside_dir"
  run env RALPH_WORKSPACES_FILE="$reg_file" HOME="$home_dir" bash "$REPORT_SCRIPT" --full
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }

  echo "$output" | python3 -c '
import re
import sys

lines = sys.stdin.read().splitlines()
if not any(re.match(r"^\s*\|\s*project-a\s*\|\s*ALPHA\s*\|", line) for line in lines):
    raise SystemExit("ALPHA row missing project-a source label")
if not any(re.match(r"^\s*\|\s*project-b\s*\|\s*BETA\s*\|", line) for line in lines):
    raise SystemExit("BETA row missing project-b source label")
'
}

@test "text output lists duplicate plan keys under separate project groups" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  local ws_a="$tmpdir/dup-plan-a"
  local ws_b="$tmpdir/dup-plan-b"
  mkdir -p "$ws_a" "$ws_b"
  write_usage_summary "$ws_a/.ralph-workspace/logs" "SAMEKEY"
  write_usage_summary "$ws_b/.ralph-workspace/logs" "SAMEKEY"

  run python3 "$SCRIPT" all --logs-dir "$ws_a/.ralph-workspace/logs" --logs-dir "$ws_b/.ralph-workspace/logs"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }

  echo "$output" | python3 -c '
import sys

lines = sys.stdin.read().splitlines()
hits = []
for line in lines:
    parts = [p.strip() for p in line.split("|")[1:-1]]
    if len(parts) == 12 and parts[1] == "SAMEKEY":
        hits.append(parts[0])
if hits != ["dup-plan-a", "dup-plan-b"]:
    raise SystemExit(f"expected one SAMEKEY row per project dup-plan-a then dup-plan-b, got {hits}")
'
}

@test "JSON format reports cumulative plan metrics when summary is stale" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  run python3 "$SCRIPT" all --logs-dir "$tmpdir" --format json
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }

  echo "$output" | python3 -c '
import json
import sys

doc = json.load(sys.stdin)
plans = doc.get("plans", [])
plan1 = None
for plan in plans:
    if plan.get("plan_key") == "PLAN1":
        plan1 = plan
        break

if not plan1:
    raise SystemExit("PLAN1 entry missing from JSON output")

assert plan1.get("invocations") == 2, plan1
assert plan1.get("elapsed_seconds") == 10, plan1
assert plan1.get("input_tokens") == 100, plan1
assert plan1.get("output_tokens") == 50, plan1
assert plan1.get("cache_creation_input_tokens") == 10, plan1
assert plan1.get("cache_read_input_tokens") == 20, plan1
assert abs(float(plan1.get("cache_hit_ratio", 0)) - 0.1538) < 1e-9, plan1
assert plan1.get("todos_done") == 2, plan1
assert plan1.get("todos_total") == 2, plan1
'
}

@test "empty logs directory produces Overall totals with zero counts" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  local emptydir
  emptydir="$(mktemp -d)"
  trap "rm -rf '$emptydir'" RETURN

  run python3 "$SCRIPT" all --logs-dir "$emptydir"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }

  [[ "$output" == *"Overall totals"* ]]
  [[ "$output" == *"input=0"* ]]
  [[ "$output" == *"output=0"* ]]
}

@test "usage-report inside workspace uses local .ralph-workspace/logs by default" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  local ws_dir="$tmpdir/local-ws"
  write_usage_summary "$ws_dir/.ralph-workspace/logs" "MYPLAN"
  mkdir -p "$ws_dir"

  cd "$ws_dir"
  run env RALPH_WORKSPACES_FILE=/nonexistent bash "$REPORT_SCRIPT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }

  [[ "$output" == *"MYPLAN"* ]]
  [[ "$output" == *"Logs dir:"*"$ws_dir/.ralph-workspace/logs"* ]]
}

@test "usage-report outside workspace auto-collects from registry" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  local reg_ws="$tmpdir/reg-workspace"
  local outside_dir="$tmpdir/no-workspace-here"
  write_usage_summary "$reg_ws/.ralph-workspace/logs" "REGPLAN"
  mkdir -p "$reg_ws" "$outside_dir"

  local reg_file="$tmpdir/workspaces.json"
  python3 - "$reg_file" "$reg_ws" <<'PY'
import json, os, sys
registry = sys.argv[1]
ws = sys.argv[2]
records = [
    {"path": ws, "lastSeen": "2026-04-17T00:00:00Z", "planKey": "REGPLAN", "runtime": "claude"},
]
with open(registry, "w", encoding="utf-8") as handle:
    json.dump(records, handle)
PY

  cd "$outside_dir"
  run env RALPH_WORKSPACES_FILE="$reg_file" HOME="$tmpdir" bash "$REPORT_SCRIPT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }

  [[ "$output" == *"REGPLAN"* ]]
}

@test "usage-report --full from inside a workspace forces global collection" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  local ws_dir="$tmpdir/local-ws"
  local reg_ws="$tmpdir/reg-workspace"
  write_usage_summary "$ws_dir/.ralph-workspace/logs" "LOCALPLAN"
  write_usage_summary "$reg_ws/.ralph-workspace/logs" "GLOBALPLAN"
  mkdir -p "$ws_dir" "$reg_ws"

  local reg_file="$tmpdir/workspaces.json"
  python3 - "$reg_file" "$reg_ws" <<'PY'
import json, os, sys
registry = sys.argv[1]
ws = os.path.abspath(sys.argv[2])
records = [
    {"path": ws, "lastSeen": "2026-04-17T00:00:00Z", "planKey": "GLOBALPLAN", "runtime": "claude"},
]
with open(registry, "w", encoding="utf-8") as handle:
    json.dump(records, handle)
PY

  cd "$ws_dir"
  run env RALPH_WORKSPACES_FILE="$reg_file" HOME="$tmpdir" bash "$REPORT_SCRIPT" --full
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }

  [[ "$output" == *"GLOBALPLAN"* ]]
}

@test "usage-report with missing registry falls back to filesystem search" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  local home_dir="$tmpdir/home_fallback"
  local fs_ws="$home_dir/projects/myproj"
  write_usage_summary "$fs_ws/.ralph-workspace/logs" "FSLAN"
  mkdir -p "$fs_ws"
  local outside_dir="$tmpdir/no-workspace-here"
  mkdir -p "$outside_dir"

  cd "$outside_dir"
  run env RALPH_WORKSPACES_FILE=/nonexistent/path HOME="$home_dir" bash "$REPORT_SCRIPT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }

  [[ "$output" == *"FSLAN"* ]]
}

@test "usage-report with explicit --logs-dir ignores registry and workspace discovery" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  local ws_dir="$tmpdir/local-ws"
  local custom_logs="$tmpdir/manual-logs"
  write_usage_summary "$ws_dir/.ralph-workspace/logs" "LOCALPLAN"
  write_usage_summary "$custom_logs" "MANUALPLAN"
  mkdir -p "$ws_dir"

  cd "$ws_dir"
  run env RALPH_WORKSPACES_FILE=/nonexistent bash "$REPORT_SCRIPT" --logs-dir "$custom_logs"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }

  [[ "$output" == *"MANUALPLAN"* ]]
  [[ "$output" != *"LOCALPLAN"* ]]
}

teardown() {
  rm -rf "$tmpdir"
}
