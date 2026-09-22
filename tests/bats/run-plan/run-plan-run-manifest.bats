#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  STATE_ROOT="$(mktemp -d)"
  MANIFEST_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-manifest.sh"
}

teardown() { rm -rf "$STATE_ROOT"; }

write_manifest() {
  local run_id="$1"
  run env RALPH_PLAN_WORKSPACE_ROOT="$STATE_ROOT" RALPH_PROCESS_RUN_ID="$run_id" \
    RALPH_STATE_LAYOUT=1 \
    RALPH_PLAN_KEY="manifest-plan" RALPH_ARTIFACT_NS="manifest-plan" RALPH_LOG_DIR="$STATE_ROOT/logs/manifest-plan" \
    RALPH_SESSION_DIR="$STATE_ROOT/sessions/manifest-plan" RUNTIME="cursor" SELECTED_MODEL="stub" \
    RALPH_MODE="hybrid" RALPH_PLAN_REASONING_EFFORT_RESOLVED="high" \
    PLAN_PATH="PLAN.md" EXIT_STATUS="complete" _plan_started_at="2026-01-01T00:00:00Z" total_invocations=1 \
    bash -c 'source "$1"; mkdir -p "$RALPH_LOG_DIR"; printf "{}\n" >"$RALPH_LOG_DIR/plan-usage-summary.json"; ralph_run_plan_write_manifest' _ "$MANIFEST_LIB"
}

@test "run manifest is relative, indexed, and distinct per run" {
  write_manifest "run-one"
  [ "$status" -eq 0 ]
  write_manifest "run-two"
  [ "$status" -eq 0 ]

  local runs="$STATE_ROOT/logs/manifest-plan/runs"
  [ "$(find "$runs" -name run-manifest.json | wc -l | tr -d ' ')" -eq 2 ]
  jq -e '.run_id != "" and .paths.log_dir' "$runs/run-one/run-manifest.json"
  ! jq -e '[.paths[] | select(startswith("/"))] | length > 0' "$runs/run-one/run-manifest.json"
  jq -e '.parent.workflow_run_id == null' "$runs/run-one/run-manifest.json"
  jq -e '.runtime == "cursor" and .model == "stub" and .ralph_mode == "hybrid" and .reasoning_effort == "high"' \
    "$runs/run-one/run-manifest.json"
  [ "$(wc -l <"$runs/index.jsonl" | tr -d ' ')" -eq 2 ]
}

@test "layout 2 running and terminal manifests record mode and model" {
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"

  local run_id="run-layout2" manifest
  run env RALPH_PLAN_WORKSPACE_ROOT="$STATE_ROOT" RALPH_PROCESS_RUN_ID="$run_id" \
    RALPH_STATE_LAYOUT=2 \
    RALPH_PLAN_KEY="manifest-plan" RALPH_ARTIFACT_NS="manifest-plan" RALPH_LOG_DIR="$STATE_ROOT/logs/manifest-plan" \
    RALPH_SESSION_DIR="$STATE_ROOT/sessions/manifest-plan" RUNTIME="cursor" SELECTED_MODEL="" \
    RALPH_MODE="ralph" RALPH_PLAN_REASONING_EFFORT_RESOLVED="" SELECTED_REASONING_EFFORT="" \
    PLAN_PATH="PLAN.md" EXIT_STATUS="incomplete" _plan_started_at="2026-01-01T00:00:00Z" total_invocations=0 \
    bash -c 'source "$1"; mkdir -p "$RALPH_LOG_DIR"; ralph_run_plan_write_manifest running' _ "$MANIFEST_LIB"
  [ "$status" -eq 0 ]

  manifest="$STATE_ROOT/runs/$run_id/stages/plan/attempts/$run_id/run-manifest.json"
  [ -f "$manifest" ]
  jq -e '.status == "running" and .runtime == "cursor" and .model == "" and .ralph_mode == "ralph" and .reasoning_effort == ""' "$manifest"

  run env RALPH_PLAN_WORKSPACE_ROOT="$STATE_ROOT" RALPH_PROCESS_RUN_ID="$run_id" \
    RALPH_STATE_LAYOUT=2 \
    RALPH_PLAN_KEY="manifest-plan" RALPH_ARTIFACT_NS="manifest-plan" RALPH_LOG_DIR="$STATE_ROOT/logs/manifest-plan" \
    RALPH_SESSION_DIR="$STATE_ROOT/sessions/manifest-plan" RUNTIME="cursor" SELECTED_MODEL="gpt-test" \
    RALPH_MODE="ralph" RALPH_PLAN_REASONING_EFFORT_RESOLVED="medium" \
    PLAN_PATH="PLAN.md" EXIT_STATUS="complete" _plan_started_at="2026-01-01T00:00:00Z" total_invocations=1 \
    bash -c 'source "$1"; mkdir -p "$RALPH_LOG_DIR"; ralph_run_plan_write_manifest' _ "$MANIFEST_LIB"
  [ "$status" -eq 0 ]
  jq -e '.status == "complete" and .model == "gpt-test" and .ralph_mode == "ralph" and .reasoning_effort == "medium"' "$manifest"
}
