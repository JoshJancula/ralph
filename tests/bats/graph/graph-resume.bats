#!/usr/bin/env bats
# graph-resume: library-level tests. No real dispatch.

source "$BATS_TEST_DIRNAME/test_helper/graph-resume-shared.bash"

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

  [ "$(jq -r '.schemaVersion' "$run_file")" = "3" ]
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
      "att-$i" "{\"outcome\":\"success\",\"exitCode\":$((i % 3)),\"startedAt\":\"2026-01-01T00:00:00Z\",\"finishedAt\":\"2026-01-01T00:01:00Z\",\"runtime\":\"cursor\",\"workspaceMode\":\"off\",\"reason\":\"reason-$i\"}"
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
    graph_state_write_node "$workspace" "ns" "run-rt" "n-$state" "$state"
    got="$(graph_state_node_status "$workspace" "ns" "run-rt" "n-$state")"
    [ "$got" = "$state" ]
  done

  # The ledger entry schema is preserved across state-only updates.
  node_file="$(graph_state_node_file "$workspace" "ns" "run-rt" "n-succeeded")"
  [ "$(jq -r '.schemaVersion' "$node_file")" = "3" ]
  [ "$(jq -r '.nodeId' "$node_file")" = "n-succeeded" ]
  [ "$(jq -r '.attempts | length' "$node_file")" = "0" ]

  # Invalid state is rejected.
  run graph_state_write_node "$workspace" "ns" "run-rt" "n-invalid" "bogus"
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

@test "attempts append to the per-node ledger with runtime and nativeSubagents provenance" {
  tmpd="$(mktemp -d)"
  workspace="$tmpd/ws"
  mkdir -p "$workspace/.ralph-workspace/graph-runs/ns/run-att/nodes"

  graph_state_write_node "$workspace" "ns" "run-att" "n1" "running" \
    "n1__run-att__1" '{"outcome":"success","exitCode":0,"startedAt":"2026-01-01T00:00:00Z","finishedAt":"2026-01-01T00:01:00Z","runtime":"cursor","nativeSubagents":"off"}'
  graph_state_write_node "$workspace" "ns" "run-att" "n1" "succeeded" \
    "n1__run-att__2" '{"outcome":"success","exitCode":0,"startedAt":"2026-01-01T00:02:00Z","finishedAt":"2026-01-01T00:03:00Z","runtime":"claude","nativeSubagents":"inherit","reason":"retry"}' \
    '{"runtime":"claude","nativeSubagents":"inherit"}'

  node_file="$(graph_state_node_file "$workspace" "ns" "run-att" "n1")"
  [ "$(jq -r '.status' "$node_file")" = "succeeded" ]
  [ "$(jq -r '.lastAttemptId' "$node_file")" = "n1__run-att__2" ]
  [ "$(jq -r '.attempts | length' "$node_file")" = "2" ]
  [ "$(jq -r '.attempts[0].attemptId' "$node_file")" = "n1__run-att__1" ]
  [ "$(jq -r '.attempts[0].runtime' "$node_file")" = "cursor" ]
  [ "$(jq -r '.attempts[0].nativeSubagents' "$node_file")" = "off" ]
  [ "$(jq -r '.attempts[1].attemptId' "$node_file")" = "n1__run-att__2" ]
  [ "$(jq -r '.attempts[1].runtime' "$node_file")" = "claude" ]
  [ "$(jq -r '.attempts[1].nativeSubagents' "$node_file")" = "inherit" ]
  [ "$(jq -r '.attempts[1].reason' "$node_file")" = "retry" ]
  # The per-node runtime/nativeSubagents track the latest attempt.
  [ "$(jq -r '.runtime' "$node_file")" = "claude" ]
  [ "$(jq -r '.nativeSubagents' "$node_file")" = "inherit" ]

  rm -rf "$tmpd"
}

@test "graph-run.sh resume rejects a version-2 run ledger naming both versions" {
  tmpd="$(mktemp -d)"
  workspace="$tmpd/ws"
  mkdir -p "$workspace"
  graph_file="$tmpd/graph.json"
  compile_graph "$DIAMOND_PLAN" "$workspace" "$graph_file"
  plan_file="$workspace/graph-diamond.plan.md"
  ns="graph-diamond"
  run_id="run-cli-stale"

  unset RALPH_GRAPH_STATE_ROOT RALPH_PLAN_WORKSPACE_ROOT 2>/dev/null || true
  graph_state_init_run "$workspace" "$ns" "$run_id" "$plan_file" "$graph_file" 2
  run_file="$(graph_state_run_file "$workspace" "$ns" "$run_id")"
  jq '.schemaVersion = 2' "$run_file" >"$run_file.tmp"
  mv "$run_file.tmp" "$run_file"

  run bash -c "cd \"$workspace\" && bash \"$REPO_ROOT/bundle/.ralph/graph-run.sh\" resume \"$plan_file\" --namespace \"$ns\" --run \"$run_id\" --yes"
  [ "$status" -ne 0 ]
  [[ "$output" == *"detected schemaVersion 2"* ]]
  [[ "$output" == *"requires schemaVersion 3"* ]]

  rm -rf "$tmpd"
}
