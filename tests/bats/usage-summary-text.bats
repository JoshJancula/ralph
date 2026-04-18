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
