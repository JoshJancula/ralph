#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/plan-todo.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-state.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-schedule.sh"

DIAMOND_PLAN="$BATS_TEST_DIRNAME/../../fixtures/graph/graph-diamond.plan.md"
EDGES_PLAN="$BATS_TEST_DIRNAME/../../fixtures/graph/graph-edges.plan.md"
STUB_RUN_PLAN="$BATS_TEST_DIRNAME/../../fixtures/orchestrator-single-stage/run-plan-stub.sh"
RALPH_DIR="$REPO_ROOT/bundle/.ralph"
SCHEDULE_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-schedule.sh"

json_payload() {
  printf '%s\n' "$1" | awk 'END{print}'
}

# Compile a plan fixture into a fresh workspace and print the graph path.
compile_graph() {
  local src_plan="$1"
  local workspace="$2"
  local out_path="$3"
  local plan_file="$workspace/$(basename "$src_plan")"
  cp "$src_plan" "$plan_file"
  plan_pipeline_graph_json "$plan_file" > "$out_path"
}

@test "graph_state_init_run writes run.json with the required fields and a frozen graph" {
  tmpd="$(mktemp -d)"
  workspace="$tmpd/ws"
  mkdir -p "$workspace"
  graph_file="$tmpd/graph.json"
  compile_graph "$DIAMOND_PLAN" "$workspace" "$graph_file"
  plan_file="$workspace/graph-diamond.plan.md"

  run graph_state_init_run "$workspace" "graph-diamond" "run-A" "$plan_file" "$graph_file" 4
  [ "$status" -eq 0 ]

  run_file="$(graph_state_run_file "$workspace" "graph-diamond" "run-A")"
  [ -f "$run_file" ]

  [ "$(jq -r '.schemaVersion' "$run_file")" = "1" ]
  [ -n "$(jq -r '.ralphVersion' "$run_file")" ]
  [ "$(jq -r '.runId' "$run_file")" = "run-A" ]
  [ -n "$(jq -r '.planPath' "$run_file")" ]
  [ -n "$(jq -r '.graphSha' "$run_file")" ]
  [ -n "$(jq -r '.startedAt' "$run_file")" ]
  [ "$(jq -r '.status' "$run_file")" = "running" ]
  [ "$(jq -r '.maxParallel' "$run_file")" = "4" ]

  graph_frozen="$(graph_state_graph_file "$workspace" "graph-diamond" "run-A")"
  [ -f "$graph_frozen" ]
  # The frozen graph is byte-identical to the compiled graph.
  cmp "$graph_frozen" "$graph_file"

  # A pending ledger entry exists for every node in the graph.
  node_count="$(jq '.nodes | length' "$graph_frozen")"
  nodes_dir="$(graph_state_nodes_dir "$workspace" "graph-diamond" "run-A")"
  [ "$(find "$nodes_dir" -name '*.json' -type f | wc -l | tr -d ' ')" = "$node_count" ]
  for node_id in $(jq -r '.nodes[].id' "$graph_frozen"); do
    node_file="$(graph_state_node_file "$workspace" "graph-diamond" "run-A" "$node_id")"
    [ -f "$node_file" ]
    [ "$(jq -r '.nodeId' "$node_file")" = "$node_id" ]
    [ "$(jq -r '.status' "$node_file")" = "pending" ]
    [ "$(jq -r '.attempts | length' "$node_file")" = "0" ]
    [ "$(jq -r '.lastAttemptId' "$node_file")" = "null" ]
  done

  rm -rf "$tmpd"
}

@test "node state files are written atomically with no partial JSON observable mid-write" {
  tmpd="$(mktemp -d)"
  workspace="$tmpd/ws"
  mkdir -p "$workspace/.ralph-workspace/graph-runs/ns/run-atomic/nodes"
  node_file="$(graph_state_node_file "$workspace" "ns" "run-atomic" "n1")"

  stop="$tmpd/stop"
  failed="$tmpd/failed"
  rm -f "$stop" "$failed"

  # Background reader continuously jq-validates the node file. Any partial JSON
  # written mid-rename would surface as a jq parse failure.
  (
    while [[ ! -f "$stop" ]]; do
      if [[ -f "$node_file" ]]; then
        if ! jq empty "$node_file" 2>/dev/null; then
          touch "$failed"
          exit 1
        fi
      fi
      sleep 0.005
    done
  ) &
  reader_pid=$!

  for i in $(seq 1 30); do
    graph_state_write_node "$workspace" "ns" "run-atomic" "n1" "running" \
      "att-$i" "success" "$((i % 3))" "2026-01-01T00:00:00Z" \
      "2026-01-01T00:01:00Z" "cursor" "off" "reason-$i"
  done

  touch "$stop"
  wait "$reader_pid" 2>/dev/null || true

  [ ! -f "$failed" ]
  [ "$(jq '.attempts | length' "$node_file")" = "30" ]
  [ "$(jq -r '.lastAttemptId' "$node_file")" = "att-30" ]

  rm -rf "$tmpd"
}

@test "all nine node states round-trip through the ledger" {
  tmpd="$(mktemp -d)"
  workspace="$tmpd/ws"
  mkdir -p "$workspace/.ralph-workspace/graph-runs/ns/run-rt/nodes"

  for state in pending ready running succeeded failed blocked skipped awaiting-ack cancelled; do
    graph_state_write_node "$workspace" "ns" "run-rt" "n1" "$state" \
      "" "" "" "" "" "" "" ""
    got="$(graph_state_node_status "$workspace" "ns" "run-rt" "n1")"
    [ "$got" = "$state" ]
  done

  # The ledger entry schema is preserved across state-only updates.
  node_file="$(graph_state_node_file "$workspace" "ns" "run-rt" "n1")"
  [ "$(jq -r '.schemaVersion' "$node_file")" = "1" ]
  [ "$(jq -r '.nodeId' "$node_file")" = "n1" ]
  [ "$(jq -r '.attempts | length' "$node_file")" = "0" ]

  # Invalid state is rejected.
  run graph_state_write_node "$workspace" "ns" "run-rt" "n1" "bogus" \
    "" "" "" "" "" "" "" ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid node state: bogus"* ]]

  rm -rf "$tmpd"
}

@test "graphSha is stable across two compiles of an unchanged plan and differs after an edit" {
  tmpd="$(mktemp -d)"
  workspace="$tmpd/ws"
  mkdir -p "$workspace"

  plan_src="$tmpd/graph-diamond.plan.md"
  plan_edit="$tmpd/graph-diamond-edited.plan.md"
  cp "$DIAMOND_PLAN" "$plan_src"
  graph_a="$tmpd/a.graph.json"
  graph_b="$tmpd/b.graph.json"
  plan_pipeline_graph_json "$plan_src" > "$graph_a"
  plan_pipeline_graph_json "$plan_src" > "$graph_b"

  sha_a="$(graph_state_compute_graph_sha "$graph_a")"
  sha_b="$(graph_state_compute_graph_sha "$graph_b")"
  [ "$sha_a" = "$sha_b" ]
  [ -n "$sha_a" ]

  # Edit: change a runtime on one node so the compiled graph differs.
  sed 's/runtime: cursor/runtime: claude/' "$plan_src" > "$plan_edit"
  graph_c="$tmpd/c.graph.json"
  plan_pipeline_graph_json "$plan_edit" > "$graph_c"
  sha_c="$(graph_state_compute_graph_sha "$graph_c")"
  [ "$sha_c" != "$sha_a" ]

  rm -rf "$tmpd"
}

@test "the latest symlink points at the newest run" {
  tmpd="$(mktemp -d)"
  workspace="$tmpd/ws"
  mkdir -p "$workspace"
  graph_file="$tmpd/graph.json"
  compile_graph "$EDGES_PLAN" "$workspace" "$graph_file"
  plan_file="$workspace/graph-edges.plan.md"

  graph_state_init_run "$workspace" "ns" "run-old" "$plan_file" "$graph_file" 2
  # Sleep so the second run directory has a strictly newer mtime.
  sleep 1
  graph_state_init_run "$workspace" "ns" "run-new" "$plan_file" "$graph_file" 2

  symlink="$(graph_state_latest_symlink "$workspace" "ns")"
  [ -L "$symlink" ]

  run graph_state_resolve_run_id "$workspace" "ns" latest
  [ "$status" -eq 0 ]
  [ "$output" = "run-new" ]

  # An explicit run id passes through verbatim.
  run graph_state_resolve_run_id "$workspace" "ns" "run-old"
  [ "$status" -eq 0 ]
  [ "$output" = "run-old" ]

  # list_runs returns both, newest last (by mtime).
  runs="$(graph_state_list_runs "$workspace" "ns")"
  [ "$(printf '%s\n' "$runs" | head -n1)" = "run-old" ]
  [ "$(printf '%s\n' "$runs" | tail -n1)" = "run-new" ]

  rm -rf "$tmpd"
}

@test "graph_state_set_run_status updates run.json atomically and validates the new status" {
  tmpd="$(mktemp -d)"
  workspace="$tmpd/ws"
  mkdir -p "$workspace"
  graph_file="$tmpd/graph.json"
  compile_graph "$EDGES_PLAN" "$workspace" "$graph_file"
  plan_file="$workspace/graph-edges.plan.md"

  graph_state_init_run "$workspace" "ns" "run-s" "$plan_file" "$graph_file" 2
  run_file="$(graph_state_run_file "$workspace" "ns" "run-s")"
  [ "$(jq -r '.status' "$run_file")" = "running" ]

  graph_state_set_run_status "$workspace" "ns" "run-s" "succeeded"
  [ "$(jq -r '.status' "$run_file")" = "succeeded" ]

  # Invalid run status is rejected.
  run graph_state_set_run_status "$workspace" "ns" "run-s" "bogus"
  [ "$status" -ne 0 ]

  rm -rf "$tmpd"
}

@test "attempts append to the per-node ledger with runtime and subagents provenance" {
  tmpd="$(mktemp -d)"
  workspace="$tmpd/ws"
  mkdir -p "$workspace/.ralph-workspace/graph-runs/ns/run-att/nodes"

  graph_state_write_node "$workspace" "ns" "run-att" "n1" "running" \
    "n1__run-att__1" "success" 0 "2026-01-01T00:00:00Z" \
    "2026-01-01T00:01:00Z" "cursor" "off" ""
  graph_state_write_node "$workspace" "ns" "run-att" "n1" "succeeded" \
    "n1__run-att__2" "success" 0 "2026-01-01T00:02:00Z" \
    "2026-01-01T00:03:00Z" "claude" "on" "retry"

  node_file="$(graph_state_node_file "$workspace" "ns" "run-att" "n1")"
  [ "$(jq -r '.status' "$node_file")" = "succeeded" ]
  [ "$(jq -r '.lastAttemptId' "$node_file")" = "n1__run-att__2" ]
  [ "$(jq -r '.attempts | length' "$node_file")" = "2" ]
  [ "$(jq -r '.attempts[0].attemptId' "$node_file")" = "n1__run-att__1" ]
  [ "$(jq -r '.attempts[0].runtime' "$node_file")" = "cursor" ]
  [ "$(jq -r '.attempts[0].subagents' "$node_file")" = "off" ]
  [ "$(jq -r '.attempts[1].attemptId' "$node_file")" = "n1__run-att__2" ]
  [ "$(jq -r '.attempts[1].runtime' "$node_file")" = "claude" ]
  [ "$(jq -r '.attempts[1].subagents' "$node_file")" = "on" ]
  [ "$(jq -r '.attempts[1].reason' "$node_file")" = "retry" ]
  # The per-node runtime/subagents track the latest attempt.
  [ "$(jq -r '.runtime' "$node_file")" = "claude" ]
  [ "$(jq -r '.subagents' "$node_file")" = "on" ]

  rm -rf "$tmpd"
}

# --- p3-resume: graph_schedule_resume ----------------------------------------

# Prepare a scratch workspace with a stubbed run-plan. Mirrors the setup in
# graph-schedule.bats so the scheduler can dispatch real single-stage children.
setup_dispatch_workspace() {
  local tmpd="$1"
  DISPATCH_WORKSPACE="$tmpd/workspace"
  mkdir -p "$DISPATCH_WORKSPACE/.ralph" "$DISPATCH_WORKSPACE/.ralph-workspace"

  cp -R "$RALPH_DIR"/* "$DISPATCH_WORKSPACE/.ralph/"
  chmod +x "$DISPATCH_WORKSPACE/.ralph"/*.sh 2>/dev/null || true
  chmod +x "$DISPATCH_WORKSPACE/.ralph/bash-lib"/*/*.sh 2>/dev/null || true

  cp "$STUB_RUN_PLAN" "$DISPATCH_WORKSPACE/.ralph/run-plan.sh"
  chmod +x "$DISPATCH_WORKSPACE/.ralph/run-plan.sh"

  export GRAPH_DISPATCH_ORCHESTRATOR="$DISPATCH_WORKSPACE/.ralph/orchestrator.sh"
  export RALPH_ALLOW_NESTED_RUNS=1
  export ORCHESTRATOR_RUNNER_TO_CONSOLE=0
  export RALPH_MODE=no
  export RALPH_ARTIFACT_SCHEMA_VALIDATION=0
  export RALPH_ARTIFACT_PROVENANCE=0
  unset RALPH_ARTIFACT_NS 2>/dev/null || true
  unset RALPH_PLAN_KEY 2>/dev/null || true
}

compile_plan_graph_to() {
  local src_plan="$1" workspace="$2" out_path="$3"
  local plan_file="$workspace/$(basename "$src_plan")"
  cp "$src_plan" "$plan_file"
  plan_pipeline_graph_json "$plan_file" > "$out_path"
}

# Install a lightweight single-stage orchestrator driven by per-stage behavior
# files under behavior_dir: success | fail:<ec> | sleep:<sec>
install_behavior_orchestrator() {
  local workspace="$1" ns="$2" run_id="$3" behavior_dir="$4" marker_dir="$5"
  mkdir -p "$behavior_dir" "$marker_dir"
  cat >"$workspace/.ralph/orchestrator.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
attempt=""
stage=""
prev=""
for arg in "\$@"; do
  if [[ "\$prev" == "--attempt-id" ]]; then
    attempt="\$arg"
  elif [[ "\$prev" == "--single-stage" ]]; then
    stage="\$arg"
  fi
  prev="\$arg"
done
workspace="\${@: -1}"
ns="$ns"
run_id="$run_id"
behavior_dir="$behavior_dir"
marker_dir="$marker_dir"
report="\$workspace/.ralph-workspace/artifacts/\$ns/stage-outcomes/\${attempt}.json"
mkdir -p "\$(dirname "\$report")" "\$marker_dir"
printf '%s\n' "\$\$" >"\$marker_dir/\$stage.pid"
: >"\$marker_dir/\$stage.started"
write_report() {
  local outcome="\$1" exit_code="\$2"
  printf '%s\n' "{\"schemaVersion\":1,\"runId\":\"\$run_id\",\"stageId\":\"\$stage\",\"attemptId\":\"\$attempt\",\"outcome\":\"\$outcome\",\"exitCode\":\$exit_code,\"startedAt\":\"2026-01-01T00:00:00Z\",\"finishedAt\":\"2026-01-01T00:00:01Z\"}" >"\$report"
}
behavior="success"
if [[ -f "\$behavior_dir/\$stage" ]]; then
  behavior="\$(cat "\$behavior_dir/\$stage")"
fi
case "\$behavior" in
  fail:*)
    ec="\${behavior#fail:}"
    [[ "\$ec" =~ ^[0-9]+$ ]] || ec=1
    write_report failed "\$ec"
    : >"\$marker_dir/\$stage.finished"
    exit "\$ec"
    ;;
  sleep:*)
    sec="\${behavior#sleep:}"
    [[ "\$sec" =~ ^[0-9]+([.][0-9]+)?$ ]] || sec=2
    sleep "\$sec"
    write_report success 0
    : >"\$marker_dir/\$stage.finished"
    exit 0
    ;;
  *)
    write_report success 0
    : >"\$marker_dir/\$stage.finished"
    exit 0
    ;;
esac
EOF
  chmod +x "$workspace/.ralph/orchestrator.sh"
  export GRAPH_DISPATCH_ORCHESTRATOR="$workspace/.ralph/orchestrator.sh"
}

# Start a graph run with the ledger, optionally killing the scheduler parent
# mid-run to simulate a crashed scheduler. Leaves the ledger on disk.
start_ledgered_run() {
  # $1=graph_file $2=workspace $3=run_id $4=kill_after_marker (optional)
  local graph_file="$1" workspace="$2" run_id="$3" kill_marker="${4:-}"
  local run_dir
  run_dir="$(graph_state_run_dir "$workspace" "$(jq -r '.namespace' "$graph_file")" "$run_id")"
  graph_state_init_run "$workspace" "$(jq -r '.namespace' "$graph_file")" \
    "$run_id" "$workspace/$(basename "$graph_file" .graph.json).plan.md" "$graph_file" 2
  graph_schedule_run "$graph_file" "$run_id" "$workspace" "$run_dir" &
  local sched_pid=$!
  if [[ -n "$kill_marker" ]]; then
    local waited=0
    while [[ ! -f "$kill_marker" && "$waited" -lt 60 ]]; do
      sleep 0.25
      waited=$((waited + 1))
    done
    kill -KILL "$sched_pid" 2>/dev/null || true
    wait "$sched_pid" 2>/dev/null || true
  else
    wait "$sched_pid" 2>/dev/null || true
  fi
}

@test "resume skips succeeded nodes, adopts an orphaned report for a running node, and completes" {
  tmpd="$(mktemp -d)"
  setup_dispatch_workspace "$tmpd"
  graph_file="$tmpd/graph-diamond.graph.json"
  compile_plan_graph_to "$DIAMOND_PLAN" "$DISPATCH_WORKSPACE" "$graph_file"
  ns="$(jq -r '.namespace' "$graph_file")"
  plan_file="$DISPATCH_WORKSPACE/$(basename "$DIAMOND_PLAN")"

  behavior_dir="$tmpd/behavior"
  marker_dir="$tmpd/markers"
  mkdir -p "$behavior_dir" "$marker_dir"
  # source succeeds; left sleeps long enough to kill the scheduler mid-flight.
  printf '%s\n' "success" >"$behavior_dir/source"
  printf '%s\n' "sleep:30" >"$behavior_dir/left"
  printf '%s\n' "success" >"$behavior_dir/right"
  printf '%s\n' "success" >"$behavior_dir/sink"
  install_behavior_orchestrator "$DISPATCH_WORKSPACE" "$ns" "resume-adopt" \
    "$behavior_dir" "$marker_dir"

  run_id="resume-adopt"
  run_dir="$(graph_state_run_dir "$DISPATCH_WORKSPACE" "$ns" "$run_id")"
  graph_state_init_run "$DISPATCH_WORKSPACE" "$ns" "$run_id" "$plan_file" "$graph_file" 2

  # Run the scheduler in the background so we can kill it once `left` is running.
  GRAPH_REAP_POLL_INTERVAL=0.1 graph_schedule_run "$graph_file" "$run_id" "$DISPATCH_WORKSPACE" "$run_dir" &
  sched_pid=$!
  # Wait for `left` to start (it sleeps 30s) and `right` to finish, then kill
  # the scheduler mid-flight. right succeeds quickly; left is still in-flight.
  waited=0
  while { [[ ! -f "$marker_dir/left.started" ]] || [[ ! -f "$marker_dir/right.finished" ]]; } && [[ "$waited" -lt 120 ]]; do
    sleep 0.25
    waited=$((waited + 1))
  done
  [ -f "$marker_dir/left.started" ]
  [ -f "$marker_dir/right.finished" ]
  [ -f "$marker_dir/source.finished" ]
  kill -KILL "$sched_pid" 2>/dev/null || true
  wait "$sched_pid" 2>/dev/null || true

  # source is succeeded in the ledger; left is running (orphaned). right may be
  # either succeeded (if the scheduler reaped it before being killed) or running
  # (if the kill happened first) — both are reconciled correctly by resume.
  [ "$(graph_state_node_status "$DISPATCH_WORKSPACE" "$ns" "$run_id" "source")" = "succeeded" ]
  left_status="$(graph_state_node_status "$DISPATCH_WORKSPACE" "$ns" "$run_id" "left")"
  [[ "$left_status" == "running" || "$left_status" == "pending" ]]

  # Write an orphaned success report for left's last attempt so resume can adopt it.
  left_last="$(graph_state_node_last_attempt_id "$DISPATCH_WORKSPACE" "$ns" "$run_id" "left")"
  if [[ -n "$left_last" ]]; then
    report_path="$(graph_dispatch_report_path "$DISPATCH_WORKSPACE" "$ns" "$left_last")"
    mkdir -p "$(dirname "$report_path")"
    printf '%s\n' "{\"schemaVersion\":1,\"runId\":\"$run_id\",\"stageId\":\"left\",\"attemptId\":\"$left_last\",\"outcome\":\"success\",\"exitCode\":0,\"startedAt\":\"2026-01-01T00:00:00Z\",\"finishedAt\":\"2026-01-01T00:00:01Z\"}" >"$report_path"
  fi

  # Resume: left should be adopted as succeeded, sink should run, run completes.
  unset RALPH_ARTIFACT_NS RALPH_PLAN_KEY 2>/dev/null || true
  rc=0
  graph_schedule_resume "$DISPATCH_WORKSPACE" "$ns" "latest" "$plan_file" || rc=$?
  [ "$rc" -eq 0 ]
  [ "$(graph_schedule_node_state_by_id source)" = "succeeded" ]
  [ "$(graph_schedule_node_state_by_id left)" = "succeeded" ]
  [ "$(graph_schedule_node_state_by_id right)" = "succeeded" ]
  [ "$(graph_schedule_node_state_by_id sink)" = "succeeded" ]
  [ -f "$marker_dir/sink.finished" ]
  run_file="$(graph_state_run_file "$DISPATCH_WORKSPACE" "$ns" "$run_id")"
  [ "$(jq -r '.status' "$run_file")" = "succeeded" ]

  rm -rf "$tmpd"
}

@test "a node left running with no report resets to pending on resume" {
  tmpd="$(mktemp -d)"
  setup_dispatch_workspace "$tmpd"
  graph_file="$tmpd/graph-diamond.graph.json"
  compile_plan_graph_to "$DIAMOND_PLAN" "$DISPATCH_WORKSPACE" "$graph_file"
  ns="$(jq -r '.namespace' "$graph_file")"
  plan_file="$DISPATCH_WORKSPACE/$(basename "$DIAMOND_PLAN")"

  behavior_dir="$tmpd/behavior"
  marker_dir="$tmpd/markers"
  mkdir -p "$behavior_dir" "$marker_dir"
  printf '%s\n' "success" >"$behavior_dir/source"
  printf '%s\n' "sleep:30" >"$behavior_dir/left"
  printf '%s\n' "success" >"$behavior_dir/right"
  printf '%s\n' "success" >"$behavior_dir/sink"
  install_behavior_orchestrator "$DISPATCH_WORKSPACE" "$ns" "resume-no-report" \
    "$behavior_dir" "$marker_dir"

  run_id="resume-no-report"
  run_dir="$(graph_state_run_dir "$DISPATCH_WORKSPACE" "$ns" "$run_id")"
  graph_state_init_run "$DISPATCH_WORKSPACE" "$ns" "$run_id" "$plan_file" "$graph_file" 2

  GRAPH_REAP_POLL_INTERVAL=0.1 graph_schedule_run "$graph_file" "$run_id" "$DISPATCH_WORKSPACE" "$run_dir" &
  sched_pid=$!
  waited=0
  while [[ ! -f "$marker_dir/left.started" && "$waited" -lt 80 ]]; do
    sleep 0.25
    waited=$((waited + 1))
  done
  [ -f "$marker_dir/left.started" ]
  kill -KILL "$sched_pid" 2>/dev/null || true
  wait "$sched_pid" 2>/dev/null || true

  # Manually mark left as running in the ledger if it is not already, to make
  # the test deterministic regardless of reap timing.
  if [[ "$(graph_state_node_status "$DISPATCH_WORKSPACE" "$ns" "$run_id" "left")" != "running" ]]; then
    left_last="$(graph_state_node_last_attempt_id "$DISPATCH_WORKSPACE" "$ns" "$run_id" "left")"
    graph_state_write_node "$DISPATCH_WORKSPACE" "$ns" "$run_id" "left" "running" \
      "${left_last:-left__${run_id}__1}" "" "" "2026-01-01T00:00:00Z" "" "claude" "inherit" "" 2>/dev/null || true
  fi
  [ "$(graph_state_node_status "$DISPATCH_WORKSPACE" "$ns" "$run_id" "left")" = "running" ]

  # No report written for left's last attempt — resume must reset it to pending.
  unset RALPH_ARTIFACT_NS RALPH_PLAN_KEY 2>/dev/null || true
  rc=0
  graph_schedule_resume "$DISPATCH_WORKSPACE" "$ns" "latest" "$plan_file" || rc=$?
  [ "$rc" -eq 0 ]
  [ "$(graph_schedule_node_state_by_id source)" = "succeeded" ]
  [ "$(graph_schedule_node_state_by_id right)" = "succeeded" ]
  [ "$(graph_schedule_node_state_by_id left)" = "succeeded" ]
  [ "$(graph_schedule_node_state_by_id sink)" = "succeeded" ]
  [ -f "$marker_dir/left.finished" ]
  [ -f "$marker_dir/sink.finished" ]
  [[ "$(graph_state_node_last_attempt_id "$DISPATCH_WORKSPACE" "$ns" "$run_id" left)" == *"__2" ]]

  rm -rf "$tmpd"
}

@test "editing the plan and then resuming refuses without --accept-graph-change and names changed nodes" {
  tmpd="$(mktemp -d)"
  setup_dispatch_workspace "$tmpd"
  graph_file="$tmpd/graph-diamond.graph.json"
  compile_plan_graph_to "$DIAMOND_PLAN" "$DISPATCH_WORKSPACE" "$graph_file"
  ns="$(jq -r '.namespace' "$graph_file")"
  plan_file="$DISPATCH_WORKSPACE/$(basename "$DIAMOND_PLAN")"

  behavior_dir="$tmpd/behavior"
  marker_dir="$tmpd/markers"
  mkdir -p "$behavior_dir" "$marker_dir"
  printf '%s\n' "success" >"$behavior_dir/source"
  printf '%s\n' "success" >"$behavior_dir/left"
  printf '%s\n' "success" >"$behavior_dir/right"
  printf '%s\n' "success" >"$behavior_dir/sink"
  install_behavior_orchestrator "$DISPATCH_WORKSPACE" "$ns" "resume-refuse" \
    "$behavior_dir" "$marker_dir"

  run_id="resume-refuse"
  run_dir="$(graph_state_run_dir "$DISPATCH_WORKSPACE" "$ns" "$run_id")"
  graph_state_init_run "$DISPATCH_WORKSPACE" "$ns" "$run_id" "$plan_file" "$graph_file" 2
  unset RALPH_ARTIFACT_NS RALPH_PLAN_KEY 2>/dev/null || true
  graph_schedule_run "$graph_file" "$run_id" "$DISPATCH_WORKSPACE" "$run_dir"
  [ "$GRAPH_SCHEDULE_EXIT_CODE" -eq 0 ]
  [ "$(graph_state_node_status "$DISPATCH_WORKSPACE" "$ns" "$run_id" "source")" = "succeeded" ]

  # Edit the plan: change left's runtime so the compiled graph differs.
  sed 's/runtime: cursor/runtime: codex/' "$plan_file" >"$tmpd/edited.plan.md"
  cp "$tmpd/edited.plan.md" "$plan_file"

  rc=0
  resume_err="$tmpd/resume.err"
  graph_schedule_resume "$DISPATCH_WORKSPACE" "$ns" "latest" "$plan_file" 2>"$resume_err" || rc=$?
  [ "$rc" -ne 0 ]
  [[ "$(cat "$resume_err")" == *"graph changed"* ]]
  [[ "$(cat "$resume_err")" == *"--accept-graph-change"* ]]
  # The changed node (left) is named in the refusal context (graphSha differs).
  [[ "$(cat "$resume_err")" == *"old graphSha="* ]]
  [[ "$(cat "$resume_err")" == *"new graphSha="* ]]

  rm -rf "$tmpd"
}

@test "resume proceeds with correct invalidation when --accept-graph-change is supplied" {
  tmpd="$(mktemp -d)"
  setup_dispatch_workspace "$tmpd"
  graph_file="$tmpd/graph-diamond.graph.json"
  compile_plan_graph_to "$DIAMOND_PLAN" "$DISPATCH_WORKSPACE" "$graph_file"
  ns="$(jq -r '.namespace' "$graph_file")"
  plan_file="$DISPATCH_WORKSPACE/$(basename "$DIAMOND_PLAN")"

  behavior_dir="$tmpd/behavior"
  marker_dir="$tmpd/markers"
  mkdir -p "$behavior_dir" "$marker_dir"
  printf '%s\n' "success" >"$behavior_dir/source"
  printf '%s\n' "success" >"$behavior_dir/left"
  printf '%s\n' "success" >"$behavior_dir/right"
  printf '%s\n' "success" >"$behavior_dir/sink"
  install_behavior_orchestrator "$DISPATCH_WORKSPACE" "$ns" "resume-accept" \
    "$behavior_dir" "$marker_dir"

  run_id="resume-accept"
  run_dir="$(graph_state_run_dir "$DISPATCH_WORKSPACE" "$ns" "$run_id")"
  graph_state_init_run "$DISPATCH_WORKSPACE" "$ns" "$run_id" "$plan_file" "$graph_file" 2
  unset RALPH_ARTIFACT_NS RALPH_PLAN_KEY 2>/dev/null || true
  graph_schedule_run "$graph_file" "$run_id" "$DISPATCH_WORKSPACE" "$run_dir"
  [ "$GRAPH_SCHEDULE_EXIT_CODE" -eq 0 ]
  # All nodes succeeded before the edit.
  [ "$(graph_state_node_status "$DISPATCH_WORKSPACE" "$ns" "$run_id" "source")" = "succeeded" ]
  [ "$(graph_state_node_status "$DISPATCH_WORKSPACE" "$ns" "$run_id" "left")" = "succeeded" ]
  [ "$(graph_state_node_status "$DISPATCH_WORKSPACE" "$ns" "$run_id" "sink")" = "succeeded" ]

  # Edit: change left's runtime so left's own stage JSON and sink's ancestor
  # set both change. source and right are unaffected.
  sed 's/runtime: cursor/runtime: codex/' "$plan_file" >"$tmpd/edited.plan.md"
  cp "$tmpd/edited.plan.md" "$plan_file"

  rc=0
  resume_err="$tmpd/resume.err"
  graph_schedule_resume "$DISPATCH_WORKSPACE" "$ns" "latest" "$plan_file" \
    --accept-graph-change 2>"$resume_err" || rc=$?
  [ "$rc" -eq 0 ]
  # left and sink were invalidated and re-run; source and right stayed succeeded.
  [ "$(graph_schedule_node_state_by_id source)" = "succeeded" ]
  [ "$(graph_schedule_node_state_by_id right)" = "succeeded" ]
  [ "$(graph_schedule_node_state_by_id left)" = "succeeded" ]
  [ "$(graph_schedule_node_state_by_id sink)" = "succeeded" ]
  # The invalidation log names the changed nodes.
  [[ "$(cat "$resume_err")" == *"node=left"* ]]
  [[ "$(cat "$resume_err")" == *"node=sink"* ]]
  run_file="$(graph_state_run_file "$DISPATCH_WORKSPACE" "$ns" "$run_id")"
  [ "$(jq -r '.status' "$run_file")" = "succeeded" ]

  rm -rf "$tmpd"
}

@test "resuming a fully completed run is a clean no-op" {
  tmpd="$(mktemp -d)"
  setup_dispatch_workspace "$tmpd"
  graph_file="$tmpd/graph-diamond.graph.json"
  compile_plan_graph_to "$DIAMOND_PLAN" "$DISPATCH_WORKSPACE" "$graph_file"
  ns="$(jq -r '.namespace' "$graph_file")"
  plan_file="$DISPATCH_WORKSPACE/$(basename "$DIAMOND_PLAN")"

  behavior_dir="$tmpd/behavior"
  marker_dir="$tmpd/markers"
  mkdir -p "$behavior_dir" "$marker_dir"
  printf '%s\n' "success" >"$behavior_dir/source"
  printf '%s\n' "success" >"$behavior_dir/left"
  printf '%s\n' "success" >"$behavior_dir/right"
  printf '%s\n' "success" >"$behavior_dir/sink"
  install_behavior_orchestrator "$DISPATCH_WORKSPACE" "$ns" "resume-noop" \
    "$behavior_dir" "$marker_dir"

  run_id="resume-noop"
  run_dir="$(graph_state_run_dir "$DISPATCH_WORKSPACE" "$ns" "$run_id")"
  graph_state_init_run "$DISPATCH_WORKSPACE" "$ns" "$run_id" "$plan_file" "$graph_file" 2
  unset RALPH_ARTIFACT_NS RALPH_PLAN_KEY 2>/dev/null || true
  graph_schedule_run "$graph_file" "$run_id" "$DISPATCH_WORKSPACE" "$run_dir"
  [ "$GRAPH_SCHEDULE_EXIT_CODE" -eq 0 ]
  [ "$(graph_state_node_status "$DISPATCH_WORKSPACE" "$ns" "$run_id" "source")" = "succeeded" ]
  [ "$(graph_state_node_status "$DISPATCH_WORKSPACE" "$ns" "$run_id" "sink")" = "succeeded" ]
  run_file="$(graph_state_run_file "$DISPATCH_WORKSPACE" "$ns" "$run_id")"
  [ "$(jq -r '.status' "$run_file")" = "succeeded" ]

  # Resume the completed run without any plan edit: clean no-op.
  rc=0
  resume_err="$tmpd/resume.err"
  graph_schedule_resume "$DISPATCH_WORKSPACE" "$ns" "latest" "$plan_file" 2>"$resume_err" || rc=$?
  [ "$rc" -eq 0 ]
  [[ "$(cat "$resume_err")" == *"no-op"* ]]
  [ "$(graph_schedule_node_state_by_id source)" = "succeeded" ]
  [ "$(graph_schedule_node_state_by_id sink)" = "succeeded" ]
  [ "$(jq -r '.status' "$run_file")" = "succeeded" ]
  # No new sink run (marker already present from the first run).
  [ -f "$marker_dir/sink.finished" ]

  rm -rf "$tmpd"
}
