#!/usr/bin/env bats
# shellcheck shell=bash

BENCHMARK_FIXTURE_DIR=""

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  if [[ -z "$BENCHMARK_FIXTURE_DIR" ]]; then
    BENCHMARK_FIXTURE_DIR="$(mktemp -d)"
    (
      cd "$BENCHMARK_FIXTURE_DIR"
      bash "$REPO_ROOT/scripts/setup-test-fixtures.sh"
    )
  fi
  SCRIPT="$REPO_ROOT/bundle/.ralph/benchmark-report.sh"
  LOGS_DIR="$BENCHMARK_FIXTURE_DIR/.ralph-workspace/logs"
  WORKSPACE_DIR="$BENCHMARK_FIXTURE_DIR"
}

teardown_file() {
  if [[ -n "$BENCHMARK_FIXTURE_DIR" ]]; then
    rm -rf "$BENCHMARK_FIXTURE_DIR"
    BENCHMARK_FIXTURE_DIR=""
  fi
}

@test "benchmark-report: markdown output is titled and lists a path row" {
  run bash "$SCRIPT" --workspace "$WORKSPACE_DIR" --logs-dir "$LOGS_DIR" --format markdown
  [ "$status" -eq 0 ]
  [[ "$output" == *"# Ralph Savings Report"* ]]
  [[ "$output" == *"ralph benchmark --write-doc"* ]]
  [[ "$output" == *"## How to read this"* ]]
  [[ "$output" == *"savings-report"* ]]
}

@test "benchmark-report: json output uses the benchmark report kind" {
  run bash "$SCRIPT" --workspace "$WORKSPACE_DIR" --logs-dir "$LOGS_DIR" --format json
  [ "$status" -eq 0 ]
  tmpfile="$(mktemp)"
  printf '%s' "$output" > "$tmpfile"
  run python3 - "$tmpfile" <<'PY'
import json
import sys

with open(sys.argv[1]) as fh:
    doc = json.load(fh)

assert doc["kind"] == "ralph_benchmark_report", doc.get("kind")
assert doc["saved_bytes"] >= 150, f"expected at least 150 saved_bytes, got {doc.get('saved_bytes')}"
assert doc["per_path"]["hook_compaction"]["saved_bytes"] >= 100, f"expected at least 100 hook_compaction bytes, got {doc['per_path']['hook_compaction']['saved_bytes']}"
PY
  [ "$status" -eq 0 ]
  rm -f "$tmpfile"
}

@test "benchmark-report: --write-doc writes a non-empty doc file" {
  doc_file="$BENCHMARK_FIXTURE_DIR/out/BENCHMARKS.md"
  run bash "$SCRIPT" --workspace "$WORKSPACE_DIR" --logs-dir "$LOGS_DIR" --write-doc --output "$doc_file"
  [ "$status" -eq 0 ]
  [ -s "$doc_file" ]
  grep -q "# Ralph Savings Report" "$doc_file"
}
