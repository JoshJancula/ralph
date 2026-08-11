#!/usr/bin/env bats
# Tests for graph-run and stage-outcome retention in cleanup_plan_prune_graph_runs.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/cleanup-plan.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# make_run <ns_dir> <run_id> <status>
# Creates a minimal run directory with a run.json containing the given status.
make_run() {
  local ns_dir="$1" run_id="$2" status="$3"
  local run_dir="$ns_dir/$run_id"
  mkdir -p "$run_dir"
  printf '{"schemaVersion":1,"runId":"%s","status":"%s"}\n' "$run_id" "$status" \
    > "$run_dir/run.json"
}

# set_mtime_days_ago <path> <days>
# Sets the mtime of <path> to N days in the past.
set_mtime_days_ago() {
  local path="$1" days="$2"
  # Compute a timestamp N days ago: YYYYMMDDHHSS format for touch -t.
  local ts
  if ts="$(date -d "$days days ago" +%Y%m%d%H%M 2>/dev/null)"; then
    touch -t "${ts}" "$path"
  elif ts="$(date -v "-${days}d" +%Y%m%d%H%M 2>/dev/null)"; then
    touch -t "${ts}" "$path"
  fi
}

# make_stage_outcome <stage_outcomes_dir> <node_id> <run_id> <attempt>
# Creates a stub stage-outcome JSON file.
make_stage_outcome() {
  local stage_outcomes_dir="$1" node_id="$2" run_id="$3" attempt="$4"
  mkdir -p "$stage_outcomes_dir"
  local attempt_id="${node_id}__${run_id}__${attempt}"
  printf '{"attemptId":"%s","outcome":"succeeded"}\n' "$attempt_id" \
    > "$stage_outcomes_dir/${attempt_id}.json"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test "prune_graph_runs is a no-op on an empty graph-runs directory" {
  local workspace
  workspace="$(mktemp -d)"
  local ns_dir="$workspace/.ralph-workspace/graph-runs/myns"

  # Directory does not exist at all.
  run cleanup_plan_prune_graph_runs "$workspace" "myns"
  [ "$status" -eq 0 ]

  # Directory exists but is empty.
  mkdir -p "$ns_dir"
  run cleanup_plan_prune_graph_runs "$workspace" "myns"
  [ "$status" -eq 0 ]
}

@test "prune_graph_runs removes old terminal runs beyond max count" {
  local workspace
  workspace="$(mktemp -d)"
  local ns_dir="$workspace/.ralph-workspace/graph-runs/myns"
  mkdir -p "$ns_dir"

  # Create 3 terminal runs; max_count=1 means keep only 1 non-latest terminal run.
  make_run "$ns_dir" "run-old" "succeeded"
  make_run "$ns_dir" "run-mid" "failed"
  make_run "$ns_dir" "run-new" "cancelled"

  # Make run-old the oldest, run-new the newest.
  set_mtime_days_ago "$ns_dir/run-old" 10
  set_mtime_days_ago "$ns_dir/run-mid" 5
  # run-new stays at current time (newest).

  # Point latest at run-new (it is always preserved regardless of count).
  ln -sfn "run-new" "$ns_dir/latest"

  # Keep at most 1 non-latest terminal run; run-old is beyond the limit.
  RALPH_GRAPH_RUN_MAX_COUNT=1 RALPH_GRAPH_RUN_MAX_AGE_DAYS=9999 \
    cleanup_plan_prune_graph_runs "$workspace" "myns"

  # run-old is beyond count limit and should be pruned.
  [ ! -d "$ns_dir/run-old" ]
  # run-mid is the one retained non-latest terminal run.
  [ -d "$ns_dir/run-mid" ]
  # run-new is the latest symlink target and is always retained.
  [ -d "$ns_dir/run-new" ]
}

@test "prune_graph_runs removes terminal runs older than max age" {
  local workspace
  workspace="$(mktemp -d)"
  local ns_dir="$workspace/.ralph-workspace/graph-runs/myns"
  mkdir -p "$ns_dir"

  make_run "$ns_dir" "run-ancient" "succeeded"
  make_run "$ns_dir" "run-recent" "succeeded"

  # Make run-ancient 60 days old.
  set_mtime_days_ago "$ns_dir/run-ancient" 60
  # run-recent is current.

  ln -sfn "run-recent" "$ns_dir/latest"

  RALPH_GRAPH_RUN_MAX_AGE_DAYS=30 RALPH_GRAPH_RUN_MAX_COUNT=9999 \
    cleanup_plan_prune_graph_runs "$workspace" "myns"

  [ ! -d "$ns_dir/run-ancient" ]
  [ -d "$ns_dir/run-recent" ]
}

@test "prune_graph_runs preserves the target of the latest symlink" {
  local workspace
  workspace="$(mktemp -d)"
  local ns_dir="$workspace/.ralph-workspace/graph-runs/myns"
  mkdir -p "$ns_dir"

  make_run "$ns_dir" "run-latest" "succeeded"
  make_run "$ns_dir" "run-extra1" "succeeded"
  make_run "$ns_dir" "run-extra2" "succeeded"

  # Make run-latest the oldest (it is still the latest symlink target).
  set_mtime_days_ago "$ns_dir/run-latest" 90

  ln -sfn "run-latest" "$ns_dir/latest"

  RALPH_GRAPH_RUN_MAX_COUNT=1 RALPH_GRAPH_RUN_MAX_AGE_DAYS=1 \
    cleanup_plan_prune_graph_runs "$workspace" "myns"

  # The latest symlink target must not be removed regardless of age or count.
  [ -d "$ns_dir/run-latest" ]
  [ -L "$ns_dir/latest" ]
  [ "$(readlink "$ns_dir/latest")" = "run-latest" ]
}

@test "prune_graph_runs preserves non-terminal (running) runs" {
  local workspace
  workspace="$(mktemp -d)"
  local ns_dir="$workspace/.ralph-workspace/graph-runs/myns"
  mkdir -p "$ns_dir"

  make_run "$ns_dir" "run-live" "running"
  make_run "$ns_dir" "run-old"  "succeeded"

  set_mtime_days_ago "$ns_dir/run-live" 90
  set_mtime_days_ago "$ns_dir/run-old"  90

  ln -sfn "run-old" "$ns_dir/latest"

  RALPH_GRAPH_RUN_MAX_COUNT=0 RALPH_GRAPH_RUN_MAX_AGE_DAYS=1 \
    cleanup_plan_prune_graph_runs "$workspace" "myns"

  # Non-terminal run must not be pruned.
  [ -d "$ns_dir/run-live" ]
}

@test "prune_graph_runs preserves non-terminal (awaiting-ack) runs" {
  local workspace
  workspace="$(mktemp -d)"
  local ns_dir="$workspace/.ralph-workspace/graph-runs/myns"
  mkdir -p "$ns_dir"

  make_run "$ns_dir" "run-ack"  "awaiting-ack"
  make_run "$ns_dir" "run-done" "succeeded"

  set_mtime_days_ago "$ns_dir/run-ack"  90
  set_mtime_days_ago "$ns_dir/run-done" 90

  ln -sfn "run-done" "$ns_dir/latest"

  RALPH_GRAPH_RUN_MAX_COUNT=0 RALPH_GRAPH_RUN_MAX_AGE_DAYS=1 \
    cleanup_plan_prune_graph_runs "$workspace" "myns"

  [ -d "$ns_dir/run-ack" ]
}

@test "prune_graph_runs removes stage-outcome files belonging to pruned runs" {
  local workspace
  workspace="$(mktemp -d)"
  local ns_dir="$workspace/.ralph-workspace/graph-runs/myns"
  local stage_outcomes_dir="$workspace/.ralph-workspace/artifacts/myns/stage-outcomes"
  mkdir -p "$ns_dir" "$stage_outcomes_dir"

  make_run "$ns_dir" "run-pruned" "succeeded"
  make_run "$ns_dir" "run-kept"   "succeeded"

  set_mtime_days_ago "$ns_dir/run-pruned" 60
  # run-kept is current.

  ln -sfn "run-kept" "$ns_dir/latest"

  # Create stage-outcome files for both runs.
  make_stage_outcome "$stage_outcomes_dir" "node-A" "run-pruned" "0"
  make_stage_outcome "$stage_outcomes_dir" "node-B" "run-pruned" "1"
  make_stage_outcome "$stage_outcomes_dir" "node-A" "run-kept"   "0"

  RALPH_GRAPH_RUN_MAX_AGE_DAYS=30 RALPH_GRAPH_RUN_MAX_COUNT=9999 \
    cleanup_plan_prune_graph_runs "$workspace" "myns"

  # Stage outcomes for pruned run must be gone.
  [ ! -f "$stage_outcomes_dir/node-A__run-pruned__0.json" ]
  [ ! -f "$stage_outcomes_dir/node-B__run-pruned__1.json" ]
  # Stage outcomes for kept run must remain.
  [ -f "$stage_outcomes_dir/node-A__run-kept__0.json" ]
}

@test "prune_graph_runs leaves stage-outcome files for retained runs intact" {
  local workspace
  workspace="$(mktemp -d)"
  local ns_dir="$workspace/.ralph-workspace/graph-runs/myns"
  local stage_outcomes_dir="$workspace/.ralph-workspace/artifacts/myns/stage-outcomes"
  mkdir -p "$ns_dir" "$stage_outcomes_dir"

  make_run "$ns_dir" "run-A" "succeeded"
  make_run "$ns_dir" "run-B" "succeeded"

  ln -sfn "run-A" "$ns_dir/latest"

  make_stage_outcome "$stage_outcomes_dir" "node-X" "run-A" "0"
  make_stage_outcome "$stage_outcomes_dir" "node-X" "run-B" "0"

  # Both runs are within limits; neither should be pruned.
  RALPH_GRAPH_RUN_MAX_AGE_DAYS=9999 RALPH_GRAPH_RUN_MAX_COUNT=9999 \
    cleanup_plan_prune_graph_runs "$workspace" "myns"

  [ -d "$ns_dir/run-A" ]
  [ -d "$ns_dir/run-B" ]
  [ -f "$stage_outcomes_dir/node-X__run-A__0.json" ]
  [ -f "$stage_outcomes_dir/node-X__run-B__0.json" ]
}
