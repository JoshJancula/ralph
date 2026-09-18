#!/usr/bin/env bats
# Tests for graph-run and stage-outcome retention in cleanup_plan_prune_graph_runs.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/cleanup-plan.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-workspace-manager.sh"

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

# make_prunable_workspace <ns_dir> <run_id> <status> <project_root>
make_prunable_workspace() {
  local ns_dir="$1" run_id="$2" status="$3" project_root="$4"
  local run_dir="$ns_dir/$run_id" node_id="node" node_key path
  make_run "$ns_dir" "$run_id" "$status"
  run_dir="$(cd "$run_dir" && pwd -P)"
  jq --arg project "$project_root" \
    '. + {roots:{projectRoot:$project},workspaceManager:{schemaVersion:1,retention:"prune"}}' \
    "$run_dir/run.json" >"$run_dir/run.tmp"
  mv "$run_dir/run.tmp" "$run_dir/run.json"
  node_key="$(graph_workspace_node_key "$node_id")"
  path="$run_dir/workspaces/nodes/$node_key"
  mkdir -p "$path" "$run_dir/workspaces/metadata"
  printf 'recoverable after-side\n' >"$path/change.txt"
  jq -cn --arg owner "$run_id" --arg node "$node_id" --arg path "$path" \
    '{schemaVersion:1,ownerRunId:$owner,nodeId:$node,mode:"snapshot",workspacePath:$path,
      isolation:true,status:"ready",includesApplied:true,setupCompleted:0}' \
    >"$run_dir/workspaces/metadata/$node_key.json"
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

@test "workspace cleanup prunes terminal copies but preserves changesets and latest/running runs" {
  local workspace project ns_dir node_key terminal_path running_path latest_path
  workspace="$(mktemp -d)"
  project="$workspace/project"
  ns_dir="$workspace/.ralph-workspace/graph-runs/myns"
  mkdir -p "$project" "$ns_dir"
  node_key="$(graph_workspace_node_key node)"

  make_prunable_workspace "$ns_dir" "run-terminal" "succeeded" "$project"
  terminal_path="$ns_dir/run-terminal/workspaces/nodes/$node_key"
  graph_workspace_cleanup_run "$ns_dir/run-terminal"
  [ ! -e "$terminal_path" ]
  [ -f "$ns_dir/run-terminal/workspaces/changesets/$node_key.tar" ]

  make_prunable_workspace "$ns_dir" "run-running" "running" "$project"
  running_path="$ns_dir/run-running/workspaces/nodes/$node_key"
  run graph_workspace_cleanup_run "$ns_dir/run-running"
  [ "$status" -ne 0 ]
  [ -d "$running_path" ]

  make_prunable_workspace "$ns_dir" "run-latest" "succeeded" "$project"
  latest_path="$ns_dir/run-latest/workspaces/nodes/$node_key"
  ln -sfn "run-latest" "$ns_dir/latest"
  graph_workspace_cleanup_run "$ns_dir/run-latest"
  [ -d "$latest_path" ]
}

@test "base retention keeps newest three terminal snapshots and marks old bases pruned" {
  local workspace ns_dir run base
  workspace="$(mktemp -d)"
  ns_dir="$workspace/.ralph-workspace/graph-runs/myns"
  mkdir -p "$ns_dir"

  for run in run-new run-recent run-third run-old run-running; do
    if [[ "$run" == "run-running" ]]; then
      make_run "$ns_dir" "$run" "running"
    else
      make_run "$ns_dir" "$run" "succeeded"
    fi
    mkdir -p "$ns_dir/$run/base/source"
    printf '%s\n' "$run" >"$ns_dir/$run/base/source/evidence.txt"
  done
  set_mtime_days_ago "$ns_dir/run-recent" 1
  set_mtime_days_ago "$ns_dir/run-third" 2
  set_mtime_days_ago "$ns_dir/run-old" 60
  set_mtime_days_ago "$ns_dir/run-running" 90

  RALPH_GRAPH_RUN_MAX_AGE_DAYS=9999 RALPH_GRAPH_RUN_MAX_COUNT=9999 \
    RALPH_GRAPH_BASE_MAX_AGE_DAYS=30 \
    cleanup_plan_prune_graph_runs "$workspace" "myns"

  for run in run-new run-recent run-third; do
    [ -d "$ns_dir/$run/base/source" ]
    [ "$(jq -r '.basePruned // false' "$ns_dir/$run/run.json")" = "false" ]
  done
  [ ! -e "$ns_dir/run-old/base" ]
  [ "$(jq -r '.basePruned' "$ns_dir/run-old/run.json")" = "true" ]
  [ -d "$ns_dir/run-running/base/source" ]
  [ "$(jq -r '.basePruned // false' "$ns_dir/run-running/run.json")" = "false" ]
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

@test "prune_graph_runs leaves namespace-unowned files untouched" {
  local workspace ns_dir state_root decoy historical_file
  workspace="$(mktemp -d)"
  ns_dir="$workspace/.ralph-workspace/graph-runs/myns"
  state_root="$workspace/.ralph-workspace"
  mkdir -p "$ns_dir/run-old/logs" "$ns_dir/run-kept/logs" \
    "$state_root/logs/myns/nodes/shared"
  make_run "$ns_dir" "run-old" "succeeded"
  make_run "$ns_dir" "run-kept" "succeeded"
  printf 'run-owned\n' >"$ns_dir/run-old/logs/supervisor.log"
  decoy="$state_root/logs/myns/nodes/shared/attempt-1.log"
  printf 'not-uniquely-owned\n' >"$decoy"
  historical_file="$state_root/logs/myns/graph-schedule-run-old.log"
  printf 'historical\n' >"$historical_file"
  set_mtime_days_ago "$ns_dir/run-old" 60
  ln -sfn "run-kept" "$ns_dir/latest"

  RALPH_GRAPH_RUN_MAX_AGE_DAYS=30 RALPH_GRAPH_RUN_MAX_COUNT=9999 \
    cleanup_plan_prune_graph_runs "$workspace" "myns"

  [ ! -d "$ns_dir/run-old" ]
  [ -d "$ns_dir/run-kept" ]
  [ -f "$decoy" ]
  [ "$(cat "$decoy")" = "not-uniquely-owned" ]
  [ -f "$historical_file" ]
  [ "$(cat "$historical_file")" = "historical" ]
}
