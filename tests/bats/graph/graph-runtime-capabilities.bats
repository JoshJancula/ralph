#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-schedule.sh"

setup() {
  TMPD="$(mktemp -d)"
  GRAPH_SCHEDULE_MAX_PARALLEL=3
  GRAPH_SCHEDULE_MAX_PARALLEL_PER_RUNTIME=3
  GRAPH_SCHEDULE_TOKEN_CAP=20
  _graph_schedule_reset_runtime_occupancy
}

teardown() { rm -rf "$TMPD"; }

@test "capability matrix proves only invocation-local adapters parallel-safe" {
  local runtime
  for runtime in claude codex opencode antigravity; do
    graph_runtime_same_runtime_parallel_safe "$runtime"
    [[ "$(graph_runtime_overlay_isolation "$runtime")" == temporary-* ]]
  done
  run graph_runtime_same_runtime_parallel_safe cursor
  [ "$status" -ne 0 ]
  [ "$(graph_runtime_overlay_isolation cursor)" = "project-root-overlay-journal" ]
  run graph_runtime_same_runtime_parallel_safe unknown
  [ "$status" -ne 0 ]
}

@test "two and three same-runtime admissions respect adapter proof regardless of workspace mode" {
  local runtime mode i admitted
  for runtime in claude codex opencode antigravity cursor; do
    for mode in snapshot worktree; do
      # Workspace mode is intentionally not an input to capability admission.
      _graph_schedule_reset_runtime_occupancy
      admitted=0
      for i in 1 2 3; do
        if _graph_schedule_runtime_can_admit "$runtime" off 1; then
          _graph_schedule_runtime_reserve_slots "$runtime" 1 1
          admitted=$((admitted + 1))
        fi
      done
      if [[ "$runtime" == cursor ]]; then
        [ "$admitted" -eq 1 ]
      else
        [ "$admitted" -eq 3 ]
      fi
    done
  done
}

@test "structured admission record carries safety runtime and token decisions" {
  GRAPH_SCHEDULE_ADMISSION_LOG_FILE="$TMPD/admission.jsonl"
  : >"$GRAPH_SCHEDULE_ADMISSION_LOG_FILE"
  _graph_schedule_runtime_reserve_slots claude 1 1
  _graph_schedule_log_admission admitted graph-node n1 claude off 1 1 test
  _graph_schedule_log_admission denied graph-node n2 cursor off 1 1 runtime-or-token-cap

  jq -s -e 'any(.[]; .ownerId == "n1" and .sameRuntimeParallelSafe == true and .tokenUsed == 1 and .effectiveRuntimeCap == 3)' "$GRAPH_SCHEDULE_ADMISSION_LOG_FILE" >/dev/null
  jq -s -e 'any(.[]; .ownerId == "n2" and .sameRuntimeParallelSafe == false and .overlayIsolation == "project-root-overlay-journal" and .effectiveRuntimeCap == 1)' "$GRAPH_SCHEDULE_ADMISSION_LOG_FILE" >/dev/null
}

@test "native parent reserves declared runtime allowance in token budget" {
  GRAPH_SCHEDULE_MAX_PARALLEL_PER_RUNTIME=3
  GRAPH_SCHEDULE_TOKEN_CAP=3
  [ "$(_graph_schedule_slots_for_node claude on)" -eq 3 ]
  [ "$(_graph_schedule_slots_for_node claude on 1)" -eq 2 ]
  _graph_schedule_runtime_reserve_slots claude 3 3
  run _graph_schedule_runtime_can_admit codex off 1
  [ "$status" -ne 0 ]
  _graph_schedule_runtime_release_slots claude 3 3
  _graph_schedule_runtime_can_admit codex off 1
}

@test "native allowance preflight fails before dispatch when parent plus children cannot fit" {
  graph="$TMPD/native.graph.json"
  printf '%s\n' '{"nodes":[{"id":"parent","stage":{"runtime":"claude","subagents":"on","delegation":{"native":{"maxParallel":1}}}}]}' >"$graph"
  GRAPH_SCHEDULE_MAX_PARALLEL=1
  GRAPH_SCHEDULE_MAX_PARALLEL_PER_RUNTIME=1
  GRAPH_SCHEDULE_TOKEN_CAP=1
  run graph_schedule_native_budget_preflight "$graph"
  [ "$status" -ne 0 ]
  [[ "$output" == *"parent+native.maxParallel requires 2"* ]]

  GRAPH_SCHEDULE_MAX_PARALLEL=2
  GRAPH_SCHEDULE_MAX_PARALLEL_PER_RUNTIME=2
  GRAPH_SCHEDULE_TOKEN_CAP=2
  graph_schedule_native_budget_preflight "$graph"
}
