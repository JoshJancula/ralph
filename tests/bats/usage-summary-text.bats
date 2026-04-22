#!/usr/bin/env bats
# shellcheck shell=bash

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="$REPO_ROOT/bundle/.ralph/bash-lib/ralph-usage-summary-text.py"
}

@test "usage summary text renders plan mode" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  local tmpdir summary_file usage_file
  tmpdir="$(mktemp -d)"
  summary_file="$tmpdir/plan-usage-summary.json"
  usage_file="$tmpdir/invocation-usage.json"

  cat <<'JSON' >"$summary_file"
{
  "schema_version": 1,
  "kind": "plan_usage_summary",
  "plan": "PLAN.md",
  "plan_key": "plan-1",
  "artifact_ns": "plan-1",
  "stage_id": "stage-1",
  "model": "m1",
  "runtime": "claude",
  "invocations": 2,
  "todos_done": 1,
  "todos_total": 2,
  "started_at": "2026-04-17T00:00:00Z",
  "ended_at": "2026-04-17T00:00:08Z",
  "elapsed_seconds": 8,
  "input_tokens": 15,
  "output_tokens": 27,
  "cache_creation_input_tokens": 3,
  "cache_read_input_tokens": 5,
  "max_turn_total_tokens": 500,
  "cache_hit_ratio": 0.25
}
JSON

  cat <<'JSON' >"$usage_file"
{
  "schema_version": 1,
  "kind": "plan_invocation_usage_history",
  "invocations": [
    {
      "iteration": 1,
      "model": "m1",
      "runtime": "claude",
      "plan_key": "plan-1",
      "stage_id": "stage-1",
      "started_at": "2026-04-17T00:00:00Z",
      "ended_at": "2026-04-17T00:00:03Z",
      "elapsed_seconds": 3,
      "input_tokens": 10,
      "output_tokens": 20,
      "cache_creation_input_tokens": 1,
      "cache_read_input_tokens": 2,
      "max_turn_total_tokens": 300,
      "cache_hit_ratio": 0.1429
    },
    {
      "iteration": 2,
      "model": "m2",
      "runtime": "claude",
      "elapsed_seconds": 5,
      "input_tokens": 5,
      "output_tokens": 7,
      "cache_creation_input_tokens": 2,
      "cache_read_input_tokens": 3,
      "max_turn_total_tokens": 500,
      "cache_hit_ratio": 0.25
    }
  ]
}
JSON

  run python3 "$SCRIPT" plan --summary "$summary_file" --invocations "$usage_file"
  [ "$status" -eq 0 ] || { echo "$output"; rm -rf "$tmpdir"; return 1; }

  [[ "$output" == *"Plan usage summary"* ]]
  [[ "$output" == *"Summary path: $summary_file"* ]]
  [[ "$output" == *"Invocation path: $usage_file"* ]]
  [[ "$output" == *"Summary: plan=PLAN.md plan_key=plan-1 stage_id=stage-1 runtime=claude model=m1 invocations=2 todos=1/2"* ]]
  [[ "$output" == *"Totals: input=15 output=27 cache_create=3 cache_read=5 max_turn=500 cache_hit_ratio=0.25"* ]]
  [[ "$output" == *"By model (2):"* ]]
  [[ "$output" == *"model=m1 runtime=claude invocations=1 input=10 output=20"* ]]
  [[ "$output" == *"model=m2 runtime=claude invocations=1 input=5 output=7"* ]]

  rm -rf "$tmpdir"
}

@test "usage summary text renders orch mode" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  local tmpdir summary_file usage_file
  tmpdir="$(mktemp -d)"
  summary_file="$tmpdir/orchestration-usage-summary.json"
  usage_file="$tmpdir/invocation-usage.json"

  cat <<'JSON' >"$summary_file"
{
  "schema_version": 1,
  "kind": "orchestration_usage_summary",
  "orchestration": "demo.orch.json",
  "plan_key": "orch-1",
  "artifact_ns": "orch-1",
  "started_at": "2026-04-17T01:00:00Z",
  "ended_at": "2026-04-17T01:00:08Z",
  "steps": 2,
  "elapsed_seconds": 8,
  "input_tokens": 20,
  "output_tokens": 30,
  "cache_creation_input_tokens": 4,
  "cache_read_input_tokens": 6,
  "stages": [
    {
      "step": 1,
      "agent": "research",
      "runtime": "claude",
      "input_tokens": 7,
      "output_tokens": 8,
      "cache_creation_input_tokens": 1,
      "cache_read_input_tokens": 2
    },
    {
      "step": 2,
      "agent": "implementation",
      "runtime": "codex",
      "input_tokens": 13,
      "output_tokens": 22,
      "cache_creation_input_tokens": 3,
      "cache_read_input_tokens": 4
    }
  ]
}
JSON

  cat <<'JSON' >"$usage_file"
{
  "schema_version": 1,
  "kind": "plan_invocation_usage_history",
  "invocations": [
    {
      "iteration": 1,
      "model": "claude-sonnet-4-6",
      "runtime": "claude",
      "plan_key": "orch-1",
      "stage_id": "research",
      "elapsed_seconds": 3,
      "input_tokens": 7,
      "output_tokens": 8,
      "cache_creation_input_tokens": 1,
      "cache_read_input_tokens": 2,
      "max_turn_total_tokens": 150
    },
    {
      "iteration": 2,
      "model": "gpt-5.1-codex-mini",
      "runtime": "codex",
      "plan_key": "orch-1",
      "stage_id": "implementation",
      "elapsed_seconds": 5,
      "input_tokens": 13,
      "output_tokens": 22,
      "cache_creation_input_tokens": 3,
      "cache_read_input_tokens": 4,
      "max_turn_total_tokens": 250
    }
  ]
}
JSON

  run python3 "$SCRIPT" orch --summary "$summary_file" --invocations "$usage_file"
  [ "$status" -eq 0 ] || { echo "$output"; rm -rf "$tmpdir"; return 1; }

  [[ "$output" == *"Orchestration usage summary"* ]]
  [[ "$output" == *"Summary path: $summary_file"* ]]
  [[ "$output" == *"Invocation path: $usage_file"* ]]
  [[ "$output" == *"Summary: orchestration=demo.orch.json plan_key=orch-1 artifact_ns=orch-1 steps=2 input=20 output=30 cache_create=4 cache_read=6"* ]]
  [[ "$output" == *"By model (2):"* ]]
  [[ "$output" == *"model=claude-sonnet-4-6 runtime=claude invocations=1"* ]]
  [[ "$output" == *"model=gpt-5.1-codex-mini runtime=codex invocations=1"* ]]
  [[ "$output" == *"Stages (2):"* ]]
  [[ "$output" == *"step=1 agent=research runtime=claude"* ]]
  [[ "$output" == *"step=2 agent=implementation runtime=codex"* ]]
  [[ "$output" == *"cache_create=1 cache_read=2"* ]]

  rm -rf "$tmpdir"
}

@test "usage summary text all mode prefers cumulative plan metrics from invocation history" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  local tmpdir logs_dir plan_dir
  tmpdir="$(mktemp -d)"
  logs_dir="$tmpdir/logs"
  plan_dir="$logs_dir/PLANR"
  mkdir -p "$plan_dir"

  cat <<'JSON' >"$plan_dir/plan-usage-summary.json"
{
  "schema_version": 1,
  "kind": "plan_usage_summary",
  "plan": "PLANR.md",
  "plan_key": "PLANR",
  "artifact_ns": "PLANR",
  "stage_id": "stage-r",
  "model": "m1",
  "runtime": "claude",
  "invocations": 1,
  "todos_done": 2,
  "todos_total": 2,
  "started_at": "2026-04-17T00:00:00Z",
  "ended_at": "2026-04-17T00:00:09Z",
  "elapsed_seconds": 1,
  "input_tokens": 1,
  "output_tokens": 1,
  "cache_creation_input_tokens": 0,
  "cache_read_input_tokens": 0,
  "max_turn_total_tokens": 1,
  "cache_hit_ratio": 0
}
JSON

  cat <<'JSON' >"$plan_dir/invocation-usage.json"
{
  "schema_version": 1,
  "kind": "plan_invocation_usage_history",
  "invocations": [
    {
      "iteration": 1,
      "model": "m1",
      "runtime": "claude",
      "elapsed_seconds": 7,
      "input_tokens": 10,
      "output_tokens": 3,
      "cache_creation_input_tokens": 1,
      "cache_read_input_tokens": 2,
      "max_turn_total_tokens": 70
    },
    {
      "iteration": 2,
      "model": "m1",
      "runtime": "claude",
      "elapsed_seconds": 8,
      "input_tokens": 20,
      "output_tokens": 4,
      "cache_creation_input_tokens": 2,
      "cache_read_input_tokens": 1,
      "max_turn_total_tokens": 80
    }
  ]
}
JSON

  run python3 "$SCRIPT" all --logs-dir "$logs_dir"
  [ "$status" -eq 0 ] || { echo "$output"; rm -rf "$tmpdir"; return 1; }

  echo "$output" | python3 -c '
import re
import sys

line = ""
for candidate in sys.stdin.read().splitlines():
    if re.match(r"^\s*\|\s*PLANR\s*\|", candidate):
        line = candidate
        break

if not line:
    raise SystemExit("PLANR row not found")

parts = [p.strip() for p in line.split("|")[1:-1]]
if len(parts) != 10:
    raise SystemExit(f"unexpected PLANR column count: {len(parts)}")

if parts[3] != "2":
    raise SystemExit(f"expected invocations=2, got {parts[3]}")
if parts[5] != "15s":
    raise SystemExit(f"expected elapsed=15s, got {parts[5]}")
if parts[6] != "30":
    raise SystemExit(f"expected input=30, got {parts[6]}")
if parts[7] != "7":
    raise SystemExit(f"expected output=7, got {parts[7]}")
if parts[8] != "8.33%":
    raise SystemExit(f"expected cache_hit=8.33%, got {parts[8]}")
'

  rm -rf "$tmpdir"
}

@test "usage summary text all mode json output uses cumulative plan metrics" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  local tmpdir logs_dir plan_dir
  tmpdir="$(mktemp -d)"
  logs_dir="$tmpdir/logs"
  plan_dir="$logs_dir/PLANR"
  mkdir -p "$plan_dir"

  cat <<'JSON' >"$plan_dir/plan-usage-summary.json"
{
  "schema_version": 1,
  "kind": "plan_usage_summary",
  "plan": "PLANR.md",
  "plan_key": "PLANR",
  "artifact_ns": "PLANR",
  "stage_id": "stage-r",
  "model": "m1",
  "runtime": "claude",
  "invocations": 1,
  "todos_done": 2,
  "todos_total": 2,
  "elapsed_seconds": 1,
  "input_tokens": 1,
  "output_tokens": 1,
  "cache_creation_input_tokens": 0,
  "cache_read_input_tokens": 0,
  "max_turn_total_tokens": 1,
  "cache_hit_ratio": 0
}
JSON

  cat <<'JSON' >"$plan_dir/invocation-usage.json"
{
  "schema_version": 1,
  "kind": "plan_invocation_usage_history",
  "invocations": [
    {
      "iteration": 1,
      "model": "m1",
      "runtime": "claude",
      "elapsed_seconds": 7,
      "input_tokens": 10,
      "output_tokens": 3,
      "cache_creation_input_tokens": 1,
      "cache_read_input_tokens": 2,
      "max_turn_total_tokens": 70
    },
    {
      "iteration": 2,
      "model": "m1",
      "runtime": "claude",
      "elapsed_seconds": 8,
      "input_tokens": 20,
      "output_tokens": 4,
      "cache_creation_input_tokens": 2,
      "cache_read_input_tokens": 1,
      "max_turn_total_tokens": 80
    }
  ]
}
JSON

  run python3 "$SCRIPT" all --logs-dir "$logs_dir" --format json
  [ "$status" -eq 0 ] || { echo "$output"; rm -rf "$tmpdir"; return 1; }

  echo "$output" | python3 -c '
import json
import sys

doc = json.load(sys.stdin)
plans = doc.get("plans", [])
if len(plans) != 1:
    raise SystemExit(f"expected one plan, got {len(plans)}")
plan = plans[0]
assert plan.get("plan_key") == "PLANR", plan
assert plan.get("invocations") == 2, plan
assert plan.get("elapsed_seconds") == 15, plan
assert plan.get("input_tokens") == 30, plan
assert plan.get("output_tokens") == 7, plan
assert plan.get("cache_creation_input_tokens") == 3, plan
assert plan.get("cache_read_input_tokens") == 3, plan
assert abs(float(plan.get("cache_hit_ratio", 0)) - 0.0833) < 1e-9, plan
assert plan.get("todos_done") == 2, plan
assert plan.get("todos_total") == 2, plan
'

  rm -rf "$tmpdir"
}
