#!/usr/bin/env bats
# shellcheck shell=bash

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPT="$REPO_ROOT/bundle/.ralph/python/ralph-usage-summary-text.py"
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

