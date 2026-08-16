#!/usr/bin/env bats
# Tests for the p4-state-v2 ledger schema and p5-attempt-upserts: new
# node/run states, the atomic attempt-upsert writer, v1-normalizing
# readers, future-schema rejection, concurrent/idempotent upserts, and
# max-suffix attempt numbering.
#
# graph_state_init_run and graph_state_write_node remain the v1 writers
# and stay byte-compatible; v2 runs go through graph_state_write_node_v2
# via _graph_schedule_ledger_record. Scheduler coverage lives in
# graph-schedule.bats; v1 resume reads stay in graph-resume.bats.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/plan-todo.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/atomic-json.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-state.sh"

DIAMOND_PLAN="$BATS_TEST_DIRNAME/../../fixtures/graph/graph-diamond.plan.md"

compile_graph() {
  local src_plan="$1" workspace="$2" out_path="$3"
  local plan_file="$workspace/$(basename "$src_plan")"
  cp "$src_plan" "$plan_file"
  plan_pipeline_graph_json "$plan_file" > "$out_path"
}

setup() {
  TMPD="$(mktemp -d)"
  WORKSPACE="$TMPD/ws"
  mkdir -p "$WORKSPACE"
  NAMESPACE="v2-ns"
  RUN_ID="run-v2-001"
  GRAPH_JSON="$TMPD/graph.json"
  compile_graph "$DIAMOND_PLAN" "$WORKSPACE" "$GRAPH_JSON"
  PLAN_FILE="$WORKSPACE/$(basename "$DIAMOND_PLAN")"
}

teardown() {
  rm -rf "$TMPD"
}

# ---------------------------------------------------------------------------
# New states are part of the legal state sets
# ---------------------------------------------------------------------------

@test "v2 node states are appended to the state list without disturbing the original nine" {
  local expected=(pending ready running succeeded failed blocked skipped awaiting-ack cancelled retry-wait awaiting-operator needs-plan-repair interrupted)
  [ "${#GRAPH_STATE_NODE_STATES[@]}" -eq "${#expected[@]}" ]
  local i
  for i in "${!expected[@]}"; do
    [ "${GRAPH_STATE_NODE_STATES[$i]}" = "${expected[$i]}" ]
  done
}

@test "v2 run statuses add interrupted and awaiting-operator" {
  graph_state_validate_run_status "interrupted"
  graph_state_validate_run_status "awaiting-operator"
  graph_state_validate_run_status "running"
}

@test "graph_state_validate_node_state accepts all four new v2 states" {
  graph_state_validate_node_state "retry-wait"
  graph_state_validate_node_state "awaiting-operator"
  graph_state_validate_node_state "needs-plan-repair"
  graph_state_validate_node_state "interrupted"
}

# ---------------------------------------------------------------------------
# New initialization: graph_state_init_run_v2
# ---------------------------------------------------------------------------

@test "graph_state_init_run_v2 writes schemaVersion 2 run.json and v2 pending nodes" {
  run graph_state_init_run_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$PLAN_FILE" "$GRAPH_JSON" 3
  [ "$status" -eq 0 ]

  local run_file
  run_file="$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  [ -f "$run_file" ]
  [ "$(jq -r '.schemaVersion' "$run_file")" = "2" ]
  [ "$(jq -r '.status' "$run_file")" = "running" ]
  [ "$(jq -r '.maxParallel' "$run_file")" = "3" ]

  local nid node_file
  while IFS= read -r nid || [[ -n "$nid" ]]; do
    [[ -z "$nid" ]] && continue
    node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid")"
    [ -f "$node_file" ]
    [ "$(jq -r '.schemaVersion' "$node_file")" = "2" ]
    [ "$(jq -r '.status' "$node_file")" = "pending" ]
    [ "$(jq -c '.attempts' "$node_file")" = "[]" ]
  done < <(jq -r '.nodes[].id' "$GRAPH_JSON")
}

@test "graph_state_init_run_v2 updates the latest symlink like v1 init" {
  run graph_state_init_run_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$PLAN_FILE" "$GRAPH_JSON" 2
  [ "$status" -eq 0 ]
  local resolved
  resolved="$(graph_state_resolve_run_id "$WORKSPACE" "$NAMESPACE" "latest")"
  [ "$resolved" = "$RUN_ID" ]
}

# ---------------------------------------------------------------------------
# All legal states: every v1 and v2 state can be the first write for a node
# ---------------------------------------------------------------------------

@test "graph_state_write_node_v2 accepts every legal node state as a first write" {
  graph_state_init_run_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$PLAN_FILE" "$GRAPH_JSON" 2 >/dev/null
  local state i=0 nid
  for state in "${GRAPH_STATE_NODE_STATES[@]}"; do
    nid="probe-${i}"
    run graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "$state"
    [ "$status" -eq 0 ]
    local node_file
    node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid")"
    [ "$(jq -r '.status' "$node_file")" = "$state" ]
    i=$((i + 1))
  done
}

@test "graph_state_write_node_v2 merges one attempts[] object per attemptId across a running-then-terminal pair" {
  graph_state_init_run_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$PLAN_FILE" "$GRAPH_JSON" 2 >/dev/null
  local nid="left"
  local aid="${nid}__${RUN_ID}__1"
  local node_file
  node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid")"

  run graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "running" \
    "$aid" '{"startedAt":"2026-01-01T00:00:00Z","runtime":"cursor"}'
  [ "$status" -eq 0 ]
  [ "$(jq '.attempts | length' "$node_file")" -eq 1 ]

  run graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "succeeded" \
    "$aid" '{"finishedAt":"2026-01-01T00:01:00Z","outcome":"succeeded","exitCode":0,"usageSnapshot":{"input_tokens":5},"usageReliable":true}'
  [ "$status" -eq 0 ]

  # Still one attempt object, not two transition records.
  [ "$(jq '.attempts | length' "$node_file")" -eq 1 ]
  [ "$(jq -r '.attempts[0].attemptId' "$node_file")" = "$aid" ]
  # Fields from both writes are present on the same object.
  [ "$(jq -r '.attempts[0].startedAt' "$node_file")" = "2026-01-01T00:00:00Z" ]
  [ "$(jq -r '.attempts[0].finishedAt' "$node_file")" = "2026-01-01T00:01:00Z" ]
  [ "$(jq -r '.attempts[0].outcome' "$node_file")" = "succeeded" ]
  [ "$(jq -r '.attempts[0].exitCode' "$node_file")" -eq 0 ]
  [ "$(jq -r '.attempts[0].usageReliable' "$node_file")" = "true" ]
  [ "$(jq -r '.attempts[0].usageSnapshot.input_tokens' "$node_file")" -eq 5 ]
}

# ---------------------------------------------------------------------------
# Illegal transitions
# ---------------------------------------------------------------------------

@test "graph_state_validate_node_transition rejects leaving terminal states" {
  ! graph_state_validate_node_transition "succeeded" "running"
  ! graph_state_validate_node_transition "succeeded" "pending"
  ! graph_state_validate_node_transition "skipped" "running"
  ! graph_state_validate_node_transition "cancelled" "pending"
}

@test "graph_state_validate_node_transition rejects skipping straight to a terminal outcome from pending" {
  ! graph_state_validate_node_transition "pending" "succeeded"
  ! graph_state_validate_node_transition "pending" "awaiting-ack"
}

@test "graph_state_validate_node_transition accepts same-state idempotent rewrites" {
  graph_state_validate_node_transition "running" "running"
  graph_state_validate_node_transition "succeeded" "succeeded"
}

@test "graph_state_write_node_v2 rejects an illegal transition and leaves the node unchanged" {
  graph_state_init_run_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$PLAN_FILE" "$GRAPH_JSON" 2 >/dev/null
  local nid="left"
  local node_file
  node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid")"

  graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "running" \
    "${nid}__${RUN_ID}__1" '{"startedAt":"2026-01-01T00:00:00Z"}' >/dev/null
  graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "succeeded" \
    "${nid}__${RUN_ID}__1" '{"outcome":"succeeded","exitCode":0}' >/dev/null

  local before after
  before="$(jq -c . "$node_file")"
  run graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "running"
  [ "$status" -ne 0 ]
  [[ "$output" = *"illegal node state transition"* ]]
  after="$(jq -c . "$node_file")"
  [ "$before" = "$after" ]
}

# ---------------------------------------------------------------------------
# Idempotency, conflicting terminalization, and concurrent-style writes
# ---------------------------------------------------------------------------

@test "graph_state_write_node_v2 repeating the identical terminalize update is idempotent" {
  graph_state_init_run_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$PLAN_FILE" "$GRAPH_JSON" 2 >/dev/null
  local nid="left"
  local aid="${nid}__${RUN_ID}__1"
  local node_file
  node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid")"

  graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "running" \
    "$aid" '{"startedAt":"2026-01-01T00:00:00Z","runtime":"cursor"}' >/dev/null
  graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "failed" \
    "$aid" '{"outcome":"failed","exitCode":1,"finishedAt":"2026-01-01T00:01:00Z"}' >/dev/null
  local first
  first="$(jq -c . "$node_file")"

  # Repeat the exact same terminalize call three times.
  local i
  for i in 1 2 3; do
    run graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "failed" \
      "$aid" '{"outcome":"failed","exitCode":1,"finishedAt":"2026-01-01T00:01:00Z"}'
    [ "$status" -eq 0 ]
  done

  local repeated
  repeated="$(jq -c . "$node_file")"
  [ "$first" = "$repeated" ]
  [ "$(jq '.attempts | length' "$node_file")" -eq 1 ]
}

@test "graph_state_write_node_v2 rejects re-terminalizing an attempt with a different outcome and leaves the file unchanged" {
  graph_state_init_run_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$PLAN_FILE" "$GRAPH_JSON" 2 >/dev/null
  local nid="left"
  local aid="${nid}__${RUN_ID}__1"
  local node_file
  node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid")"

  graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "running" \
    "$aid" '{"startedAt":"2026-01-01T00:00:00Z"}' >/dev/null
  graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "failed" \
    "$aid" '{"outcome":"failed","exitCode":1}' >/dev/null

  local before
  before="$(jq -c . "$node_file")"

  # Same node state name (failed -> failed, always a legal same-state
  # rewrite) but a conflicting outcome value for the same attemptId must
  # still be rejected -- outcome conflict detection is independent of state
  # transition legality.
  run graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "failed" \
    "$aid" '{"outcome":"cancelled","exitCode":130}'
  [ "$status" -ne 0 ]
  [[ "$output" = *"already terminalized with outcome 'failed'"* ]]
  [[ "$output" = *"different outcome 'cancelled'"* ]]

  local after
  after="$(jq -c . "$node_file")"
  [ "$before" = "$after" ]
  [ "$(jq -r '.attempts[0].outcome' "$node_file")" = "failed" ]
}

@test "graph_state_write_node_v2 heartbeat, usage, and log-metadata updates converge onto one attempts[] record" {
  graph_state_init_run_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$PLAN_FILE" "$GRAPH_JSON" 2 >/dev/null
  local nid="left"
  local aid="${nid}__${RUN_ID}__1"
  local node_file
  node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid")"

  # Starting an attempt creates one record.
  graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "running" \
    "$aid" '{"startedAt":"2026-01-01T00:00:00Z","runtime":"cursor"}' >/dev/null
  # A heartbeat refresh (same running state, same attemptId) updates the
  # same record in place.
  graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "running" \
    "$aid" '{"heartbeatAt":"2026-01-01T00:00:15Z"}' >/dev/null
  # A mid-run usage snapshot updates the same record.
  graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "running" \
    "$aid" '{"usageSnapshot":{"input_tokens":3},"usageReliable":true}' >/dev/null
  # Log metadata updates the same record.
  graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "running" \
    "$aid" '{"logPaths":{"runner":"logs/nodes/left/1/runner.log"}}' >/dev/null
  # Terminalization updates the same record.
  graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "succeeded" \
    "$aid" '{"outcome":"succeeded","exitCode":0,"finishedAt":"2026-01-01T00:01:00Z"}' >/dev/null

  [ "$(jq '.attempts | length' "$node_file")" -eq 1 ]
  [ "$(jq -r '.attempts[0].startedAt' "$node_file")" = "2026-01-01T00:00:00Z" ]
  [ "$(jq -r '.attempts[0].heartbeatAt' "$node_file")" = "2026-01-01T00:00:15Z" ]
  [ "$(jq -r '.attempts[0].usageSnapshot.input_tokens' "$node_file")" -eq 3 ]
  [ "$(jq -r '.attempts[0].logPaths.runner' "$node_file")" = "logs/nodes/left/1/runner.log" ]
  [ "$(jq -r '.attempts[0].outcome' "$node_file")" = "succeeded" ]
  [ "$(jq -r '.attempts[0].finishedAt' "$node_file")" = "2026-01-01T00:01:00Z" ]
}

@test "concurrent identical terminalize updates stay one attempts[] record" {
  graph_state_init_run_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$PLAN_FILE" "$GRAPH_JSON" 2 >/dev/null
  local nid="left"
  local aid="${nid}__${RUN_ID}__1"
  local node_file
  node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid")"

  graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "running" \
    "$aid" '{"startedAt":"2026-01-01T00:00:00Z"}' >/dev/null
  graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "failed" \
    "$aid" '{"outcome":"failed","exitCode":1,"finishedAt":"2026-01-01T00:01:00Z"}' >/dev/null

  (
    graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "failed" \
      "$aid" '{"outcome":"failed","exitCode":1,"finishedAt":"2026-01-01T00:01:00Z"}'
  ) &
  local pid1=$!
  (
    graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "failed" \
      "$aid" '{"outcome":"failed","exitCode":1,"finishedAt":"2026-01-01T00:01:00Z"}'
  ) &
  local pid2=$!
  wait "$pid1"
  wait "$pid2"

  [ "$(jq '.attempts | length' "$node_file")" -eq 1 ]
  [ "$(jq -r '.attempts[0].outcome' "$node_file")" = "failed" ]
  [ "$(jq -r '.attempts[0].attemptId' "$node_file")" = "$aid" ]
  jq -e . "$node_file" >/dev/null
}

@test "concurrent-style interleaved writes to two different attemptIds never cross-contaminate" {
  # Simulates two node attempts (e.g. a retry after a failure) racing to
  # update the ledger close together. Each attemptId must end up as its own
  # attempts[] object; nothing must be dropped or merged across attemptIds.
  graph_state_init_run_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$PLAN_FILE" "$GRAPH_JSON" 2 >/dev/null
  local nid="left"
  local aid1="${nid}__${RUN_ID}__1"
  local aid2="${nid}__${RUN_ID}__2"
  local node_file
  node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid")"

  graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "running" \
    "$aid1" '{"startedAt":"2026-01-01T00:00:00Z"}' >/dev/null
  graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "failed" \
    "$aid1" '{"outcome":"failed","exitCode":1,"finishedAt":"2026-01-01T00:00:05Z"}' >/dev/null
  graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "pending" >/dev/null
  graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "running" \
    "$aid2" '{"startedAt":"2026-01-01T00:00:10Z"}' >/dev/null
  # Interleave a heartbeat on attempt 2 with a (no-op re-write) touch on the
  # already-terminal attempt 1 to prove the two records stay independent.
  graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "running" \
    "$aid2" '{"heartbeatAt":"2026-01-01T00:00:20Z"}' >/dev/null
  graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "running" \
    "$aid1" '{"outcome":"failed"}' >/dev/null
  graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "succeeded" \
    "$aid2" '{"outcome":"succeeded","exitCode":0,"finishedAt":"2026-01-01T00:00:30Z"}' >/dev/null

  [ "$(jq '.attempts | length' "$node_file")" -eq 2 ]
  [ "$(jq -r '.attempts[0].attemptId' "$node_file")" = "$aid1" ]
  [ "$(jq -r '.attempts[0].outcome' "$node_file")" = "failed" ]
  [ "$(jq -r '.attempts[1].attemptId' "$node_file")" = "$aid2" ]
  [ "$(jq -r '.attempts[1].heartbeatAt' "$node_file")" = "2026-01-01T00:00:20Z" ]
  [ "$(jq -r '.attempts[1].outcome' "$node_file")" = "succeeded" ]
}

# ---------------------------------------------------------------------------
# Attempt numbering derives from the maximum numeric suffix of unique IDs
# ---------------------------------------------------------------------------

@test "attempt numbering derives from the maximum numeric attemptId suffix, not attempts[] array length" {
  # Reproduce the v1 duplication (two array records for one attemptId) plus
  # a gap in numbering. graph_state_max_attempt_number (used by
  # graph-schedule.sh resume reconciliation) must report 3 -- the highest
  # attempt number actually recorded -- not the array length (4 raw
  # records) and not attemptId count (2 unique ids).
  local node_file="$TMPD/numbering-node.json"
  cat > "$node_file" <<EOF
{
  "schemaVersion": 1,
  "nodeId": "left",
  "status": "failed",
  "attempts": [
    {"attemptId": "left__${RUN_ID}__1", "startedAt": "t0"},
    {"attemptId": "left__${RUN_ID}__1", "outcome": "failed", "exitCode": 1, "finishedAt": "t1"},
    {"attemptId": "left__${RUN_ID}__3", "startedAt": "t2"},
    {"attemptId": "left__${RUN_ID}__3", "outcome": "failed", "exitCode": 1, "finishedAt": "t3"}
  ],
  "lastAttemptId": "left__${RUN_ID}__3"
}
EOF
  local max_suffix unique_count
  max_suffix="$(graph_state_max_attempt_number "$node_file")"
  [ "$max_suffix" -eq 3 ]
  [ "$max_suffix" -ne "$(jq '.attempts | length' "$node_file")" ]
  unique_count="$(graph_state_normalize_node_json "$(cat "$node_file")" | jq '.attempts | length')"
  [ "$unique_count" -eq 2 ]
  [ "$max_suffix" -ne "$unique_count" ]
  [ "$(graph_state_max_attempt_number "$TMPD/missing-node.json")" -eq 0 ]
}

# ---------------------------------------------------------------------------
# v1 normalization: in-memory only, never rewrites the source
# ---------------------------------------------------------------------------

@test "graph_state_normalize_node_json merges a v1 running-then-terminal attempt pair in memory" {
  local v1='{"schemaVersion":1,"nodeId":"left","status":"succeeded","attempts":[{"attemptId":"a1","startedAt":"t0","runtime":"cursor"},{"attemptId":"a1","outcome":"succeeded","exitCode":0,"startedAt":"t0","finishedAt":"t1","runtime":"cursor"}],"lastAttemptId":"a1"}'
  local normalized
  normalized="$(graph_state_normalize_node_json "$v1")"
  [ "$(printf '%s' "$normalized" | jq -r '.schemaVersion')" = "2" ]
  [ "$(printf '%s' "$normalized" | jq -r '.sourceSchemaVersion')" = "1" ]
  [ "$(printf '%s' "$normalized" | jq '.attempts | length')" -eq 1 ]
  [ "$(printf '%s' "$normalized" | jq -r '.attempts[0].startedAt')" = "t0" ]
  [ "$(printf '%s' "$normalized" | jq -r '.attempts[0].finishedAt')" = "t1" ]
  [ "$(printf '%s' "$normalized" | jq -r '.attempts[0].outcome')" = "succeeded" ]
}

@test "graph_state_read_node_v2 normalizes a v1 node file without rewriting it" {
  graph_state_init_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$PLAN_FILE" "$GRAPH_JSON" 2 >/dev/null
  local nid="left"
  local aid="${nid}__${RUN_ID}__1"
  graph_state_write_node "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "running" \
    "$aid" "" "" "2026-01-01T00:00:00Z" "" "cursor" "off" "" >/dev/null
  graph_state_write_node "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "succeeded" \
    "$aid" "succeeded" "0" "2026-01-01T00:00:00Z" "2026-01-01T00:01:00Z" "cursor" "off" "" >/dev/null

  local node_file
  node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid")"
  [ "$(jq '.attempts | length' "$node_file")" -eq 2 ]
  [ "$(jq -r '.schemaVersion' "$node_file")" = "1" ]

  local normalized
  normalized="$(graph_state_read_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid")"
  [ "$(printf '%s' "$normalized" | jq '.attempts | length')" -eq 1 ]
  [ "$(printf '%s' "$normalized" | jq -r '.sourceSchemaVersion')" = "1" ]

  # The on-disk v1 file is untouched: still schemaVersion 1, still 2 records.
  [ "$(jq -r '.schemaVersion' "$node_file")" = "1" ]
  [ "$(jq '.attempts | length' "$node_file")" -eq 2 ]
}

# ---------------------------------------------------------------------------
# v1 byte stability after reads
# ---------------------------------------------------------------------------

@test "reading a v1 node and run through the v2 readers never changes their bytes" {
  graph_state_init_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$PLAN_FILE" "$GRAPH_JSON" 2 >/dev/null
  local nid="left"
  graph_state_write_node "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "succeeded" \
    "${nid}-a1" "succeeded" "0" "2026-01-01T00:00:00Z" "2026-01-01T00:01:00Z" "cursor" "off" "" >/dev/null

  local run_file node_file before_run before_node after_run after_node
  run_file="$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid")"
  before_run="$(shasum "$run_file" | awk '{print $1}')"
  before_node="$(shasum "$node_file" | awk '{print $1}')"

  graph_state_read_run_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" >/dev/null
  graph_state_read_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" >/dev/null
  # Read multiple times; a read must be idempotent with respect to disk state.
  graph_state_read_run_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" >/dev/null
  graph_state_read_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" >/dev/null

  after_run="$(shasum "$run_file" | awk '{print $1}')"
  after_node="$(shasum "$node_file" | awk '{print $1}')"
  [ "$before_run" = "$after_run" ]
  [ "$before_node" = "$after_node" ]
}

# ---------------------------------------------------------------------------
# Future-version rejection
# ---------------------------------------------------------------------------

@test "graph_state_read_node_v2 rejects an unknown future node schemaVersion with an actionable error" {
  graph_state_init_run_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$PLAN_FILE" "$GRAPH_JSON" 2 >/dev/null
  local nid="left"
  local node_file
  node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid")"
  printf '%s' '{"schemaVersion":99,"nodeId":"left","status":"succeeded","attempts":[],"lastAttemptId":null}' \
    > "$node_file"

  run graph_state_read_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid"
  [ "$status" -ne 0 ]
  [[ "$output" = *"schemaVersion 99"* ]]
  [[ "$output" = *"Upgrade Ralph"* ]]
}

@test "graph_state_read_run_v2 rejects an unknown future run schemaVersion with an actionable error" {
  graph_state_init_run_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$PLAN_FILE" "$GRAPH_JSON" 2 >/dev/null
  local run_file
  run_file="$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  printf '%s' '{"schemaVersion":42,"runId":"'"$RUN_ID"'","status":"running"}' > "$run_file"

  run graph_state_read_run_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID"
  [ "$status" -ne 0 ]
  [[ "$output" = *"schemaVersion 42"* ]]
  [[ "$output" = *"Upgrade Ralph"* ]]
}

@test "graph_state_write_node_v2 refuses to write onto a node ledger with an unknown future schemaVersion" {
  graph_state_init_run_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$PLAN_FILE" "$GRAPH_JSON" 2 >/dev/null
  local nid="left"
  local node_file
  node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid")"
  printf '%s' '{"schemaVersion":99,"nodeId":"left","status":"succeeded","attempts":[],"lastAttemptId":null}' \
    > "$node_file"

  run graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "running"
  [ "$status" -ne 0 ]
  [[ "$output" = *"schemaVersion 99"* ]]
}

@test "graph_state_read_node_v2 rejects a non-numeric schemaVersion" {
  graph_state_init_run_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$PLAN_FILE" "$GRAPH_JSON" 2 >/dev/null
  local nid="left"
  local node_file
  node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid")"
  printf '%s' '{"schemaVersion":"not-a-number","nodeId":"left","status":"pending","attempts":[],"lastAttemptId":null}' \
    > "$node_file"

  run graph_state_read_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid"
  [ "$status" -ne 0 ]
  [[ "$output" = *"non-numeric schemaVersion"* ]]
}

# ---------------------------------------------------------------------------
# v2 attempts carry the enriched field set the schema defines
# ---------------------------------------------------------------------------

@test "graph_state_write_node_v2 merges extra_json onto the same attempt object" {
  graph_state_init_run_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$PLAN_FILE" "$GRAPH_JSON" 2 >/dev/null
  local nid="left"
  local aid="${nid}__${RUN_ID}__1"
  local node_file
  node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid")"

  graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "running" \
    "$aid" '{"startedAt":"2026-01-01T00:00:00Z"}' \
    '{"workspaceMode":"snapshot","workspacePath":"/tmp/ws"}' >/dev/null
  graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "succeeded" \
    "$aid" '{"outcome":"succeeded","exitCode":0}' \
    '{"changesetHash":"abc123"}' >/dev/null

  [ "$(jq '.attempts | length' "$node_file")" -eq 1 ]
  [ "$(jq -r '.attempts[0].startedAt' "$node_file")" = "2026-01-01T00:00:00Z" ]
  [ "$(jq -r '.attempts[0].workspaceMode' "$node_file")" = "snapshot" ]
  [ "$(jq -r '.attempts[0].changesetHash' "$node_file")" = "abc123" ]
  [ "$(jq -r '.workspaceMode' "$node_file")" = "snapshot" ]
  [ "$(jq -r '.changesetHash' "$node_file")" = "abc123" ]
}

@test "graph_state_reset_node_to_pending on a v2 node keeps schemaVersion 2 and existing attempts" {
  graph_state_init_run_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$PLAN_FILE" "$GRAPH_JSON" 2 >/dev/null
  local nid="left"
  local aid="${nid}__${RUN_ID}__1"
  local node_file
  node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid")"

  graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "running" \
    "$aid" '{"startedAt":"2026-01-01T00:00:00Z"}' >/dev/null
  graph_state_reset_node_to_pending "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid"

  [ "$(jq -r '.schemaVersion' "$node_file")" = "2" ]
  [ "$(jq -r '.status' "$node_file")" = "pending" ]
  [ "$(jq '.attempts | length' "$node_file")" -eq 1 ]
  [ "$(jq -r '.attempts[0].attemptId' "$node_file")" = "$aid" ]
  [ "$(jq -r '.attempts[0].startedAt' "$node_file")" = "2026-01-01T00:00:00Z" ]
}

@test "a v2 attempt object can carry the full enriched field set" {
  graph_state_init_run_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$PLAN_FILE" "$GRAPH_JSON" 2 >/dev/null
  # A node not seeded by init_run_v2, so this is an unconstrained first
  # write and can legally land directly on a terminal state.
  local nid="probe-fields"
  local aid="${nid}__${RUN_ID}__1"
  local fields='{
    "startedAt":"2026-01-01T00:00:00Z",
    "finishedAt":"2026-01-01T00:01:00Z",
    "outcome":"failed",
    "exitCode":1,
    "runtime":"cursor",
    "reason":"gate-changes-required",
    "logPaths":{"runner":"logs/nodes/left/1/runner.log","agent":"logs/nodes/left/1/agent.log"},
    "usageSnapshot":{"input_tokens":10,"output_tokens":2},
    "usageReliable":false,
    "retryClassification":"transient",
    "heartbeatAt":"2026-01-01T00:00:30Z",
    "operatorRequestId":"req-0001"
  }'
  run graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "failed" "$aid" "$fields"
  [ "$status" -eq 0 ]

  local node_file
  node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid")"
  [ "$(jq -r '.attempts[0].reason' "$node_file")" = "gate-changes-required" ]
  [ "$(jq -r '.attempts[0].logPaths.runner' "$node_file")" = "logs/nodes/left/1/runner.log" ]
  [ "$(jq -r '.attempts[0].usageReliable' "$node_file")" = "false" ]
  [ "$(jq -r '.attempts[0].retryClassification' "$node_file")" = "transient" ]
  [ "$(jq -r '.attempts[0].heartbeatAt' "$node_file")" = "2026-01-01T00:00:30Z" ]
  [ "$(jq -r '.attempts[0].operatorRequestId' "$node_file")" = "req-0001" ]
}
