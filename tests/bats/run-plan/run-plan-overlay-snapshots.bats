#!/usr/bin/env bats

@test "overlay snapshots are run-scoped, timeline-indexed, and retained" {
  local repo tmp funcs summary
  repo="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  tmp="$(mktemp -d)"
  funcs="$tmp/funcs.sh"
  summary="$tmp/live-overlay.json"
  printf '%s\n' '{"compaction_saved_bytes":7,"hook_compactions":1,"byte_savings_by_channel":{"shell":3}}' >"$summary"
  sed -n '/^_ralph_runtime_overlay_summary_snapshot_for_usage() {/,/^}$/p' "$repo/bundle/.ralph/bash-lib/run-plan/run-plan-core.sh" >"$funcs"

  run env RALPH_LOG_DIR="$tmp/logs" RALPH_PROCESS_RUN_ID="run-1" RALPH_OVERLAY_SNAPSHOT_RETENTION=2 \
    bash -c 'source "$1"; for n in 1 2 3; do _ralph_runtime_overlay_summary_snapshot_for_usage "$2" "$n" cursor "$n"; done' _ "$funcs" "$summary"
  [ "$status" -eq 0 ]
  [ "$(find "$tmp/logs" -name 'runtime-overlay-summary-*.json' | wc -l | tr -d ' ')" -eq 0 ]
  [ "$(find "$tmp/logs/runs/run-1/overlay" -name 'iter-*.json' | wc -l | tr -d ' ')" -eq 2 ]
  [ "$(wc -l <"$tmp/logs/runs/run-1/overlay-timeline.jsonl" | tr -d ' ')" -eq 3 ]
  while IFS= read -r line; do jq . <<<"$line" >/dev/null; done <"$tmp/logs/runs/run-1/overlay-timeline.jsonl"
  rm -rf "$tmp"
}
