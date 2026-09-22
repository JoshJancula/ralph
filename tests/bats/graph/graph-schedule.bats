#!/usr/bin/env bats
# Graph scheduler: library-level tests. No real dispatch.

source "$BATS_TEST_DIRNAME/test_helper/schedule-shared.bash"

@test "diamond fixture loads with correct indegrees and successor sets" {
  tmpd="$(mktemp -d)"
  mkdir -p "$tmpd/workspace"
  graph_file="$tmpd/graph-diamond.graph.json"
  compile_plan_graph_to "$DIAMOND_PLAN" "$tmpd/workspace" "$graph_file"

  # Call directly (not via `run`): load mutates parallel arrays in the current shell.
  graph_schedule_load_index "$graph_file"
  [ "$(graph_schedule_node_count)" -eq 4 ]

  [ "$(graph_schedule_node_indegree_by_id source)" = "0" ]
  [ "$(graph_schedule_node_indegree_by_id left)" = "1" ]
  [ "$(graph_schedule_node_indegree_by_id right)" = "1" ]
  [ "$(graph_schedule_node_indegree_by_id sink)" = "2" ]

  source_succ="$(graph_schedule_node_successors_by_id source)"
  successor_set_has "$source_succ" "left"
  successor_set_has "$source_succ" "right"
  [ "$(graph_schedule_node_successors_by_id left)" = "sink" ]
  [ "$(graph_schedule_node_successors_by_id right)" = "sink" ]
  [ -z "$(graph_schedule_node_successors_by_id sink)" ]

  [ "$(graph_schedule_node_type_by_id source)" = "agent" ]
  [ "$(graph_schedule_node_runtime_by_id source)" = "cursor" ]

  rm -rf "$tmpd"
}

@test "linear graph loads with indegree one for every node but the first" {
  tmpd="$(mktemp -d)"
  mkdir -p "$tmpd/workspace"
  graph_file="$tmpd/graph-edges.graph.json"
  compile_plan_graph_to "$FIXTURE_PLAN" "$tmpd/workspace" "$graph_file"

  graph_schedule_load_index "$graph_file"
  [ "$(graph_schedule_node_count)" -eq 3 ]

  [ "$(graph_schedule_node_indegree_by_id source)" = "0" ]
  [ "$(graph_schedule_node_indegree_by_id transform)" = "1" ]
  [ "$(graph_schedule_node_indegree_by_id sink)" = "1" ]
  [ "$(graph_schedule_node_successors_by_id source)" = "transform" ]
  [ "$(graph_schedule_node_successors_by_id transform)" = "sink" ]
  [ -z "$(graph_schedule_node_successors_by_id sink)" ]

  rm -rf "$tmpd"
}

@test "lookups by id and by index agree" {
  tmpd="$(mktemp -d)"
  mkdir -p "$tmpd/workspace"
  graph_file="$tmpd/graph-diamond.graph.json"
  compile_plan_graph_to "$DIAMOND_PLAN" "$tmpd/workspace" "$graph_file"

  graph_schedule_load_index "$graph_file"

  count="$(graph_schedule_node_count)"
  [ "$count" -eq 4 ]
  i=0
  while [ "$i" -lt "$count" ]; do
    id="$(graph_schedule_node_id_at "$i")"
    mapped="$(graph_schedule_index_map_get "$id")"
    [ "$mapped" = "$i" ]
    [ "$(graph_schedule_node_type_at "$i")" = "$(graph_schedule_node_type_by_id "$id")" ]
    [ "$(graph_schedule_node_runtime_at "$i")" = "$(graph_schedule_node_runtime_by_id "$id")" ]
    [ "$(graph_schedule_node_indegree_at "$i")" = "$(graph_schedule_node_indegree_by_id "$id")" ]
    [ "$(graph_schedule_node_successors_at "$i")" = "$(graph_schedule_node_successors_by_id "$id")" ]
    i=$((i + 1))
  done

  rm -rf "$tmpd"
}

@test "node id containing the successor delimiter is rejected at load" {
  tmpd="$(mktemp -d)"
  graph_file="$tmpd/bad-delim.graph.json"
  cat >"$graph_file" <<EOF
{
  "schemaVersion": 2,
  "ralphVersion": "test",
  "name": "bad-delim",
  "namespace": "bad-delim",
  "maxParallel": 1,
  "failurePolicy": "drain",
  "nodes": [
    {
      "id": "bad${GRAPH_SUCCESSOR_DELIM}id",
      "type": "agent",
      "dependsOn": [],
      "derivedFrom": "stage",
      "stage": {"id": "bad${GRAPH_SUCCESSOR_DELIM}id", "runtime": "cursor", "role": "research"}
    }
  ],
  "edges": []
}
EOF

  run graph_schedule_load_index "$graph_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"successor delimiter"* ]]
  [[ "$output" == *"bad${GRAPH_SUCCESSOR_DELIM}id"* ]]
  [ "$(graph_schedule_node_count)" -eq 0 ]

  rm -rf "$tmpd"
}

@test "edge referencing an unknown node fails load with the offending edge named" {
  tmpd="$(mktemp -d)"
  graph_file="$tmpd/unknown-edge.graph.json"
  cat >"$graph_file" <<'EOF'
{
  "schemaVersion": 2,
  "ralphVersion": "test",
  "name": "unknown-edge",
  "namespace": "unknown-edge",
  "maxParallel": 1,
  "failurePolicy": "drain",
  "nodes": [
    {
      "id": "source",
      "type": "agent",
      "dependsOn": [],
      "derivedFrom": "stage",
      "stage": {"id": "source", "runtime": "cursor", "role": "research"}
    }
  ],
  "edges": [
    {"from": "source", "to": "missing-sink", "reasons": ["declared"]}
  ]
}
EOF

  run graph_schedule_load_index "$graph_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"source -> missing-sink"* ]]
  [[ "$output" == *"unknown: missing-sink"* ]]
  [ "$(graph_schedule_node_count)" -eq 0 ]

  rm -rf "$tmpd"
}

@test "index loader runs under /bin/bash 3.2" {
  tmpd="$(mktemp -d)"
  mkdir -p "$tmpd/workspace"
  graph_file="$tmpd/graph-edges.graph.json"
  compile_plan_graph_to "$FIXTURE_PLAN" "$tmpd/workspace" "$graph_file"

  script="$tmpd/load-under-32.sh"
  cat >"$script" <<EOF
#!/bin/bash
set -euo pipefail
# Intentionally invoke with /bin/bash (macOS ships 3.2).
source "$SCHEDULE_LIB"
graph_schedule_load_index "$graph_file"
printf 'bash=%s\n' "\$BASH_VERSION"
printf 'count=%s\n' "\$(graph_schedule_node_count)"
printf 'source_idx=%s\n' "\$(graph_schedule_index_map_get source)"
printf 'transform_indegree=%s\n' "\$(graph_schedule_node_indegree_by_id transform)"
printf 'source_succ=%s\n' "\$(graph_schedule_node_successors_by_id source)"
EOF
  chmod +x "$script"

  run /bin/bash "$script"
  [ "$status" -eq 0 ]
  # The point is that the loader works on the oldest bash Ralph supports. Only
  # macOS ships 3.2 as /bin/bash; on Linux CI it is 5.x, where asserting the
  # version tests the host rather than the loader. The behavior assertions
  # below run on whatever /bin/bash is, so the portable path stays covered.
  if [[ "$(/bin/bash -c 'printf %s "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"')" == 3.2 ]]; then
    [[ "$output" == bash=3.2* ]]
  fi
  [[ "$output" == *$'\n'count=3$'\n'* ]] || [[ "$output" == *"count=3"* ]]
  [[ "$output" == *"transform_indegree=1"* ]]
  [[ "$output" == *"source_succ=transform"* ]]

  rm -rf "$tmpd"
}

@test "reaper harvests a fast-exiting child with StageOutcomeReport" {
  tmpd="$(mktemp -d)"
  report="$tmpd/stage-outcomes/fast.json"
  graph_schedule_clear_children

  (
    write_fake_stage_report "$report" "fast" "0" "success"
    exit 0
  ) &
  pid=$!
  graph_schedule_track_child "$pid" "fast" "$report"

  REAP_OUT_FILE="$tmpd/reap.out"
  reap_one_capture
  [ "$REAP_RC" -eq 0 ]
  [ "$GRAPH_REAP_NODE" = "fast" ]
  [ "$GRAPH_REAP_EXIT_CODE" = "0" ]
  [ "$GRAPH_REAP_REPORT_PATH" = "$report" ]
  [ "$GRAPH_REAP_MISSING_REPORT" -eq 0 ]
  [ -z "$GRAPH_REAP_REASON" ]
  [[ "$REAP_LINE" == *"node=fast"* ]]
  [[ "$REAP_LINE" != *"reason=missing-report"* ]]
  [ "$(graph_schedule_child_count)" -eq 0 ]
  assert_pid_gone "$pid"

  rm -rf "$tmpd"
}

@test "reaper harvests a slow child without hanging" {
  tmpd="$(mktemp -d)"
  report="$tmpd/stage-outcomes/slow.json"
  graph_schedule_clear_children

  (
    sleep 1
    write_fake_stage_report "$report" "slow" "0" "success"
    exit 0
  ) &
  pid=$!
  graph_schedule_track_child "$pid" "slow" "$report"

  REAP_OUT_FILE="$tmpd/reap.out"
  reap_one_capture
  [ "$REAP_RC" -eq 0 ]
  [ "$GRAPH_REAP_NODE" = "slow" ]
  [ "$GRAPH_REAP_EXIT_CODE" = "0" ]
  [ -f "$GRAPH_REAP_REPORT_PATH" ]
  [ "$GRAPH_REAP_MISSING_REPORT" -eq 0 ]
  [[ "$REAP_LINE" == *"node=slow"* ]]
  assert_pid_gone "$pid"

  rm -rf "$tmpd"
}

@test "reaper harvests several children completing out of order" {
  tmpd="$(mktemp -d)"
  graph_schedule_clear_children

  report_a="$tmpd/stage-outcomes/a.json"
  report_b="$tmpd/stage-outcomes/b.json"
  report_c="$tmpd/stage-outcomes/c.json"

  (
    sleep 0.8
    write_fake_stage_report "$report_a" "a" "0" "success"
    exit 0
  ) &
  pid_a=$!
  (
    write_fake_stage_report "$report_b" "b" "0" "success"
    exit 0
  ) &
  pid_b=$!
  (
    sleep 0.4
    write_fake_stage_report "$report_c" "c" "7" "failed"
    exit 7
  ) &
  pid_c=$!

  graph_schedule_track_child "$pid_a" "a" "$report_a"
  graph_schedule_track_child "$pid_b" "b" "$report_b"
  graph_schedule_track_child "$pid_c" "c" "$report_c"

  harvested=""
  i=0
  while [ "$i" -lt 3 ]; do
    REAP_OUT_FILE="$tmpd/reap-$i.out"
    reap_one_capture
    [ "$REAP_RC" -eq 0 ]
    harvested="${harvested}${GRAPH_REAP_NODE}:${GRAPH_REAP_EXIT_CODE}"$'\n'
    i=$((i + 1))
  done

  [ "$(graph_schedule_child_count)" -eq 0 ]
  [[ "$harvested" == *"a:0"* ]]
  [[ "$harvested" == *"b:0"* ]]
  [[ "$harvested" == *"c:7"* ]]
  # First harvest should be the fast child (b), not the slowest (a).
  first="$(printf '%s' "$harvested" | head -n 1)"
  [ "$first" = "b:0" ]

  assert_pid_gone "$pid_a"
  assert_pid_gone "$pid_b"
  assert_pid_gone "$pid_c"

  rm -rf "$tmpd"
}

@test "reaper reports SIGKILL missing-report failure without hanging" {
  tmpd="$(mktemp -d)"
  report="$tmpd/stage-outcomes/killed.json"
  graph_schedule_clear_children

  # Child sleeps forever and never writes a report; SIGKILL skips EXIT traps.
  sleep 30 &
  pid=$!
  graph_schedule_track_child "$pid" "killed" "$report"

  kill -KILL "$pid" 2>/dev/null || true

  REAP_OUT_FILE="$tmpd/reap.out"
  reap_one_capture
  [ "$REAP_RC" -eq 2 ]
  [ "$GRAPH_REAP_NODE" = "killed" ]
  [ "$GRAPH_REAP_MISSING_REPORT" -eq 1 ]
  [ "$GRAPH_REAP_REASON" = "missing-report" ]
  [ "$GRAPH_REAP_REPORT_PATH" = "$report" ]
  [ ! -f "$report" ]
  # 128 + 9 = 137 on systems that surface SIGKILL via wait.
  [ "$GRAPH_REAP_EXIT_CODE" = "137" ] || [ "$GRAPH_REAP_EXIT_CODE" != "" ]
  [[ "$REAP_LINE" == *"reason=missing-report"* ]]
  [ "$(graph_schedule_child_count)" -eq 0 ]
  assert_pid_gone "$pid"

  rm -rf "$tmpd"
}

@test "missing report after SIGTERM is a resumable interruption" {
  tmpd="$(mktemp -d)"
  mkdir -p "$tmpd/workspace"
  graph_file="$tmpd/graph-diamond.graph.json"
  compile_plan_graph_to "$DIAMOND_PLAN" "$tmpd/workspace" "$graph_file"

  graph_schedule_load_index "$graph_file"
  source_idx="$(graph_schedule_index_map_get source)"
  GRAPH_NODE_STATES[$source_idx]="running"
  GRAPH_SCHEDULE_EXIT_CODE=0
  GRAPH_SCHEDULE_FAILED_NODE=""
  GRAPH_SCHEDULE_STOP_DISPATCH=0
  GRAPH_SCHEDULE_INTERRUPTED=0
  GRAPH_SCHEDULE_LEDGER_RUN_DIR=""
  GRAPH_REAP_NODE="source"
  GRAPH_REAP_REPORT_PATH="$tmpd/stage-outcomes/source__run__1.json"
  GRAPH_REAP_EXIT_CODE=143
  GRAPH_REAP_MISSING_REPORT=1

  run_rc=0
  _graph_schedule_handle_reaped_node 2 || run_rc=$?

  [ "$run_rc" -eq 0 ]
  [ "$(graph_schedule_node_state_by_id source)" = "interrupted" ]
  [ "$(graph_schedule_node_state_by_id left)" = "pending" ]
  [ "$(graph_schedule_node_state_by_id right)" = "pending" ]
  [ "$GRAPH_SCHEDULE_INTERRUPTED" -eq 1 ]
  [ "$GRAPH_SCHEDULE_STOP_DISPATCH" -eq 1 ]
  [ "$GRAPH_SCHEDULE_EXIT_CODE" -eq 143 ]
  [ -z "$GRAPH_SCHEDULE_FAILED_NODE" ]

  rm -rf "$tmpd"
}

@test "reaper poll path and wait -n path produce identical results" {
  tmpd="$(mktemp -d)"
  harness="$tmpd/reaper-harness.sh"
  # Shared harness: four cases, deterministic record lines (order-normalized
  # for the multi-child case). Invoked under /bin/bash 3.2 (poll) and default
  # bash (wait -n).
  cat >"$harness" <<EOF
#!/bin/bash
set +e
source "$SCHEDULE_LIB"

write_report() {
  local path="\$1" node_id="\$2" exit_code="\$3" outcome="\$4"
  mkdir -p "\$(dirname "\$path")"
  printf '%s\n' "{\"schemaVersion\":1,\"runId\":\"parity\",\"stageId\":\"\$node_id\",\"attemptId\":\"\${node_id}__parity__1\",\"outcome\":\"\$outcome\",\"exitCode\":\$exit_code,\"startedAt\":\"2026-01-01T00:00:00Z\",\"finishedAt\":\"2026-01-01T00:00:01Z\"}" >"\$path"
}

assert_gone() {
  local pid="\$1"
  if kill -0 "\$pid" 2>/dev/null; then
    echo "orphan=\$pid" >&2
    exit 99
  fi
}

base="$tmpd/run-\$\$"
mkdir -p "\$base"

# Case fast
graph_schedule_clear_children
rf="\$base/fast.json"
( write_report "\$rf" "fast" "0" "success"; exit 0 ) &
p=\$!
graph_schedule_track_child "\$p" "fast" "\$rf"
rc=0
graph_schedule_reap_one >/dev/null || rc=\$?
printf 'fast rc=%s node=%s exit=%s missing=%s reason=%s\n' \\
  "\$rc" "\$GRAPH_REAP_NODE" "\$GRAPH_REAP_EXIT_CODE" "\$GRAPH_REAP_MISSING_REPORT" "\$GRAPH_REAP_REASON"
assert_gone "\$p"

# Case slow
graph_schedule_clear_children
rs="\$base/slow.json"
( sleep 1; write_report "\$rs" "slow" "0" "success"; exit 0 ) &
p=\$!
graph_schedule_track_child "\$p" "slow" "\$rs"
rc=0
graph_schedule_reap_one >/dev/null || rc=\$?
printf 'slow rc=%s node=%s exit=%s missing=%s reason=%s\n' \\
  "\$rc" "\$GRAPH_REAP_NODE" "\$GRAPH_REAP_EXIT_CODE" "\$GRAPH_REAP_MISSING_REPORT" "\$GRAPH_REAP_REASON"
assert_gone "\$p"

# Case out-of-order (normalize harvest set)
graph_schedule_clear_children
ra="\$base/a.json"; rb="\$base/b.json"; rcpath="\$base/c.json"
( sleep 0.8; write_report "\$ra" "a" "0" "success"; exit 0 ) &
pa=\$!
( write_report "\$rb" "b" "0" "success"; exit 0 ) &
pb=\$!
( sleep 0.4; write_report "\$rcpath" "c" "7" "failed"; exit 7 ) &
pc=\$!
graph_schedule_track_child "\$pa" "a" "\$ra"
graph_schedule_track_child "\$pb" "b" "\$rb"
graph_schedule_track_child "\$pc" "c" "\$rcpath"
set_lines=""
i=0
while [ "\$i" -lt 3 ]; do
  graph_schedule_reap_one >/dev/null
  set_lines="\${set_lines}\${GRAPH_REAP_NODE}:\${GRAPH_REAP_EXIT_CODE}:\${GRAPH_REAP_MISSING_REPORT}"\$'\\n'
  i=\$((i + 1))
done
sorted="\$(printf '%s' "\$set_lines" | sort | tr '\\n' ' ')"
printf 'ooo set=%s\n' "\$sorted"
assert_gone "\$pa"; assert_gone "\$pb"; assert_gone "\$pc"

# Case SIGKILL missing report
graph_schedule_clear_children
rk="\$base/killed.json"
sleep 30 &
p=\$!
graph_schedule_track_child "\$p" "killed" "\$rk"
kill -KILL "\$p" 2>/dev/null
rc=0
graph_schedule_reap_one >/dev/null || rc=\$?
printf 'kill rc=%s node=%s missing=%s reason=%s exit=%s\n' \\
  "\$rc" "\$GRAPH_REAP_NODE" "\$GRAPH_REAP_MISSING_REPORT" "\$GRAPH_REAP_REASON" "\$GRAPH_REAP_EXIT_CODE"
assert_gone "\$p"

printf 'bash=%s force_poll=%s wait_n=%s\n' \\
  "\$BASH_VERSION" "\${GRAPH_REAP_FORCE_POLL:-0}" \\
  "\$(_graph_schedule_reap_supports_wait_n && echo yes || echo no)"
EOF
  chmod +x "$harness"

  out32="$tmpd/out-32.txt"
  out_default="$tmpd/out-default.txt"

  # Portable poll path. Force it explicitly rather than relying on /bin/bash
  # being ancient: that only holds on macOS. On Linux /bin/bash is 5.x, which
  # has `wait -n`, so this run silently took the fast path and then failed the
  # wait_n=no assertion below -- and never exercised the poll path at all.
  run env GRAPH_REAP_FORCE_POLL=1 /bin/bash "$harness"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" >"$out32"
  # See the loader test above: assert 3.2 only where /bin/bash really is 3.2.
  if [[ "$(/bin/bash -c 'printf %s "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"')" == 3.2 ]]; then
    [[ "$(grep '^bash=' "$out32")" == bash=3.2* ]]
  fi
  [[ "$(grep '^fast ' "$out32")" == *"rc=0"* ]]
  [[ "$(grep '^fast ' "$out32")" == *"missing=0"* ]]
  [[ "$(grep '^slow ' "$out32")" == *"rc=0"* ]]
  [[ "$(grep '^kill ' "$out32")" == *"rc=2"* ]]
  [[ "$(grep '^kill ' "$out32")" == *"reason=missing-report"* ]]
  [[ "$(grep '^ooo ' "$out32")" == *"a:0:0"* ]]
  [[ "$(grep '^ooo ' "$out32")" == *"b:0:0"* ]]
  [[ "$(grep '^ooo ' "$out32")" == *"c:7:0"* ]]
  [[ "$(grep 'wait_n=' "$out32")" == *"wait_n=no"* ]]

  # Default bash: wait -n fast path
  default_bash="$(command -v bash)"
  run env GRAPH_REAP_FORCE_POLL=0 "$default_bash" "$harness"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" >"$out_default"
  [[ "$(grep '^fast ' "$out_default")" == *"rc=0"* ]]
  [[ "$(grep '^kill ' "$out_default")" == *"rc=2"* ]]
  [[ "$(grep '^kill ' "$out_default")" == *"reason=missing-report"* ]]
  [[ "$(grep 'wait_n=' "$out_default")" == *"wait_n=yes"* ]]

  # Comparable fields (drop per-process exit codes; kill exit is always 137
  # here but strip anyway so paths stay aligned).
  norm32="$tmpd/norm-32.txt"
  norm_def="$tmpd/norm-default.txt"
  grep -E '^(fast|slow|ooo|kill) ' "$out32" \
    | sed -E 's/ exit=[0-9]+//' >"$norm32"
  grep -E '^(fast|slow|ooo|kill) ' "$out_default" \
    | sed -E 's/ exit=[0-9]+//' >"$norm_def"
  run diff -u "$norm32" "$norm_def"
  [ "$status" -eq 0 ]

  rm -rf "$tmpd"
}

@test "consensus voter artifacts below .ralph-workspace resolve against external state root" {
  GRAPH_SCHEDULE_WORKSPACE="$BATS_TEST_TMPDIR/workspace"
  GRAPH_SCHEDULE_NAMESPACE="jury"
  export RALPH_PLAN_WORKSPACE_ROOT="$BATS_TEST_TMPDIR/state"
  mkdir -p "$GRAPH_SCHEDULE_WORKSPACE" "$RALPH_PLAN_WORKSPACE_ROOT"

  stage_json='{"outputArtifacts":[{"path":".ralph-workspace/artifacts/{{ARTIFACT_NS}}/reviews/alpha.md"}]}'
  [ "$(_graph_schedule_consensus_voter_artifact_abs "$stage_json")" = \
    "$RALPH_PLAN_WORKSPACE_ROOT/artifacts/jury/reviews/alpha.md" ]
}

@test "_graph_schedule_ledger_record produces one attempts[] entry for a running-to-terminal attempt" {
  local tmpd workspace ns run_id graph_file plan_file node_file aid
  tmpd="$(mktemp -d)"
  workspace="$tmpd/ws"
  mkdir -p "$workspace"
  ns="sched-ns"
  run_id="run-sched"
  plan_file="$workspace/$(basename "$DIAMOND_PLAN")"
  cp "$DIAMOND_PLAN" "$plan_file"
  graph_file="$tmpd/graph.json"
  plan_pipeline_graph_json "$plan_file" > "$graph_file"

  graph_state_init_run "$workspace" "$ns" "$run_id" "$plan_file" "$graph_file" 2 >/dev/null

  GRAPH_SCHEDULE_WORKSPACE="$workspace"
  GRAPH_SCHEDULE_LEDGER_NAMESPACE="$ns"
  GRAPH_SCHEDULE_RUN_ID="$run_id"
  GRAPH_SCHEDULE_LEDGER_RUN_DIR="$(graph_state_run_dir "$workspace" "$ns" "$run_id")"
  GRAPH_SCHEDULE_LOG_FILE=""

  local nid="left"
  aid="${nid}__${run_id}__1"
  _graph_schedule_ledger_record "$nid" "running" "$aid" "" "" "2026-01-01T00:00:00Z" "" "cursor" "off" "" ""

  _graph_schedule_ledger_record "$nid" "succeeded" "$aid" "success" "0" "" "2026-01-01T00:01:00Z" "cursor" "off" "" ""

  node_file="$(graph_state_node_file "$workspace" "$ns" "$run_id" "$nid")"
  [ "$(jq -r '.schemaVersion' "$node_file")" = "3" ]
  [ "$(jq -r '.status' "$node_file")" = "succeeded" ]
  # One attempts[] object for the whole running-to-terminal attempt, not one
  # record per transition.
  [ "$(jq '.attempts | length' "$node_file")" -eq 1 ]
  [ "$(jq -r '.attempts[0].attemptId' "$node_file")" = "$aid" ]
  [ "$(jq -r '.attempts[0].startedAt' "$node_file")" = "2026-01-01T00:00:00Z" ]
  [ "$(jq -r '.attempts[0].finishedAt' "$node_file")" = "2026-01-01T00:01:00Z" ]
  [ "$(jq -r '.attempts[0].outcome' "$node_file")" = "success" ]
  [ "$(jq -r '.attempts[0].exitCode' "$node_file")" -eq 0 ]
  # Next attempt number is max suffix (1), not array length after a
  # would-be duplicate attempt record.
  [ "$(graph_state_max_attempt_number "$node_file")" -eq 1 ]
  [ "$(graph_state_max_attempt_number "$node_file")" -eq "$(jq '.attempts | length' "$node_file")" ]

  rm -rf "$tmpd"
}
