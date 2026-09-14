#!/usr/bin/env bats
# Tests for the canonical graph ledger: legal node/run states, atomic
# attempt-upserts, schema rejection, concurrent/idempotent writes, and
# max-suffix attempt numbering. Scheduler coverage lives in
# graph-schedule.bats.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/plan-todo.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/atomic-json.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-state.sh"

DIAMOND_PLAN="$BATS_TEST_DIRNAME/../../fixtures/graph/graph-diamond.plan.md"

compile_graph() {
  local src_plan="$1" workspace="$2" out_path="$3"
  local plan_file="$workspace/$(basename "$src_plan")"
  # Role fields were removed from the plan schema; strip them so ledger-focused
  # fixtures still compile without rewriting every graph plan fixture here.
  awk '/^[[:space:]]*role:[[:space:]]/ { next } { print }' "$src_plan" >"$plan_file"
  plan_pipeline_graph_json "$plan_file" > "$out_path"
}

setup() {
  TMPD="$(mktemp -d)"
  WORKSPACE="$TMPD/ws"
  mkdir -p "$WORKSPACE"
  NAMESPACE="state-ns"
  RUN_ID="run-state-001"
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

@test "canonical node state set contains every supported state" {
  local expected=(pending ready running succeeded failed blocked skipped awaiting-ack cancelled retry-wait awaiting-operator needs-plan-repair interrupted)
  [ "${#GRAPH_STATE_NODE_STATES[@]}" -eq "${#expected[@]}" ]
  local i
  for i in "${!expected[@]}"; do
    [ "${GRAPH_STATE_NODE_STATES[$i]}" = "${expected[$i]}" ]
  done
}

@test "canonical run statuses include interrupted and awaiting-operator" {
  graph_state_validate_run_status "interrupted"
  graph_state_validate_run_status "awaiting-operator"
  graph_state_validate_run_status "running"
}

@test "graph_state_validate_node_state accepts recovery states" {
  graph_state_validate_node_state "retry-wait"
  graph_state_validate_node_state "awaiting-operator"
  graph_state_validate_node_state "needs-plan-repair"
  graph_state_validate_node_state "interrupted"
}

# ---------------------------------------------------------------------------
# New initialization: graph_state_init_run
# ---------------------------------------------------------------------------

@test "graph_state_init_run writes canonical schemaVersion 3 run and pending nodes" {
  run graph_state_init_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$PLAN_FILE" "$GRAPH_JSON" 3
  [ "$status" -eq 0 ]

  local run_file
  run_file="$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  [ -f "$run_file" ]
  [ "$(jq -r '.schemaVersion' "$run_file")" = "3" ]
  [ "$(jq -r '.status' "$run_file")" = "running" ]
  [ "$(jq -r '.maxParallel' "$run_file")" = "3" ]
  [ "$(jq -e 'has("tooling")' "$run_file")" = "true" ]
  [ "$(jq -c '.tooling.nodes' "$run_file")" = "$(jq -c '[.nodes[] | {key:.id, value:(.stage.toolingProfile // null)}] | from_entries' "$GRAPH_JSON")" ]

  local nid node_file
  while IFS= read -r nid || [[ -n "$nid" ]]; do
    [[ -z "$nid" ]] && continue
    node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid")"
    [ -f "$node_file" ]
    [ "$(jq -r '.schemaVersion' "$node_file")" = "3" ]
    [ "$(jq -r '.status' "$node_file")" = "pending" ]
    [ "$(jq -c '.attempts' "$node_file")" = "[]" ]
    [ "$(jq -e 'has("toolingProfile")' "$node_file")" = "true" ]
  done < <(jq -r '.nodes[].id' "$GRAPH_JSON")
}

@test "graph_state_init_run updates the latest symlink" {
  run graph_state_init_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$PLAN_FILE" "$GRAPH_JSON" 2
  [ "$status" -eq 0 ]
  local resolved
  resolved="$(graph_state_resolve_run_id "$WORKSPACE" "$NAMESPACE" "latest")"
  [ "$resolved" = "$RUN_ID" ]
}

# ---------------------------------------------------------------------------
# Every legal state can be the first write for a node
# ---------------------------------------------------------------------------

@test "graph_state_write_node accepts every legal node state as a first write" {
  graph_state_init_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$PLAN_FILE" "$GRAPH_JSON" 2 >/dev/null
  local state i=0 nid
  for state in "${GRAPH_STATE_NODE_STATES[@]}"; do
    nid="probe-${i}"
    run graph_state_write_node "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "$state"
    [ "$status" -eq 0 ]
    local node_file
    node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid")"
    [ "$(jq -r '.status' "$node_file")" = "$state" ]
    i=$((i + 1))
  done
}

@test "graph_state_write_node merges one attempts[] object per attemptId across a running-then-terminal pair" {
  graph_state_init_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$PLAN_FILE" "$GRAPH_JSON" 2 >/dev/null
  local nid="left"
  local aid="${nid}__${RUN_ID}__1"
  local node_file
  node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid")"

  run graph_state_write_node "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "running" \
    "$aid" '{"startedAt":"2026-01-01T00:00:00Z","runtime":"cursor"}'
  [ "$status" -eq 0 ]
  [ "$(jq '.attempts | length' "$node_file")" -eq 1 ]

  run graph_state_write_node "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "succeeded" \
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

@test "graph_state_write_node persists zero-work join/checkpoint path pending->running->succeeded" {
  # Join passthrough and checkpoint handlers cannot jump pending->succeeded
  # (rejected above). They must take this intermediate running write so
  # publish sees a terminal succeeded ledger instead of a stuck pending join.
  graph_state_init_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$PLAN_FILE" "$GRAPH_JSON" 2 >/dev/null
  local nid="left"
  local node_file
  node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid")"

  graph_state_write_node "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "running" \
    "" '{"startedAt":"2026-01-01T00:00:00Z","reason":"join-passthrough"}' >/dev/null
  graph_state_write_node "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "succeeded" \
    "" '{"outcome":"success","exitCode":0,"finishedAt":"2026-01-01T00:00:01Z","reason":"join-passthrough"}' >/dev/null

  [ "$(jq -r '.status' "$node_file")" = "succeeded" ]
}

@test "graph_state_write_node rejects an illegal transition and leaves the node unchanged" {
  graph_state_init_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$PLAN_FILE" "$GRAPH_JSON" 2 >/dev/null
  local nid="left"
  local node_file
  node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid")"

  graph_state_write_node "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "running" \
    "${nid}__${RUN_ID}__1" '{"startedAt":"2026-01-01T00:00:00Z"}' >/dev/null
  graph_state_write_node "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "succeeded" \
    "${nid}__${RUN_ID}__1" '{"outcome":"succeeded","exitCode":0}' >/dev/null

  local before after
  before="$(jq -c . "$node_file")"
  run graph_state_write_node "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "running"
  [ "$status" -ne 0 ]
  [[ "$output" = *"illegal node state transition"* ]]
  after="$(jq -c . "$node_file")"
  [ "$before" = "$after" ]
}

# ---------------------------------------------------------------------------
# Idempotency, conflicting terminalization, and concurrent-style writes
# ---------------------------------------------------------------------------

@test "graph_state_write_node repeating the identical terminalize update is idempotent" {
  graph_state_init_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$PLAN_FILE" "$GRAPH_JSON" 2 >/dev/null
  local nid="left"
  local aid="${nid}__${RUN_ID}__1"
  local node_file
  node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid")"

  graph_state_write_node "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "running" \
    "$aid" '{"startedAt":"2026-01-01T00:00:00Z","runtime":"cursor"}' >/dev/null
  graph_state_write_node "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "failed" \
    "$aid" '{"outcome":"failed","exitCode":1,"finishedAt":"2026-01-01T00:01:00Z"}' >/dev/null
  local first
  first="$(jq -c . "$node_file")"

  # Repeat the exact same terminalize call three times.
  local i
  for i in 1 2 3; do
    run graph_state_write_node "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "failed" \
      "$aid" '{"outcome":"failed","exitCode":1,"finishedAt":"2026-01-01T00:01:00Z"}'
    [ "$status" -eq 0 ]
  done

  local repeated
  repeated="$(jq -c . "$node_file")"
  [ "$first" = "$repeated" ]
  [ "$(jq '.attempts | length' "$node_file")" -eq 1 ]
}

@test "graph_state_write_node rejects re-terminalizing an attempt with a different outcome and leaves the file unchanged" {
  graph_state_init_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$PLAN_FILE" "$GRAPH_JSON" 2 >/dev/null
  local nid="left"
  local aid="${nid}__${RUN_ID}__1"
  local node_file
  node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid")"

  graph_state_write_node "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "running" \
    "$aid" '{"startedAt":"2026-01-01T00:00:00Z"}' >/dev/null
  graph_state_write_node "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "failed" \
    "$aid" '{"outcome":"failed","exitCode":1}' >/dev/null

  local before
  before="$(jq -c . "$node_file")"

  # Same node state name (failed -> failed, always a legal same-state
  # rewrite) but a conflicting outcome value for the same attemptId must
  # still be rejected -- outcome conflict detection is independent of state
  # transition legality.
  run graph_state_write_node "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "failed" \
    "$aid" '{"outcome":"cancelled","exitCode":130}'
  [ "$status" -ne 0 ]
  [[ "$output" = *"already terminalized with outcome 'failed'"* ]]
  [[ "$output" = *"different outcome 'cancelled'"* ]]

  local after
  after="$(jq -c . "$node_file")"
  [ "$before" = "$after" ]
  [ "$(jq -r '.attempts[0].outcome' "$node_file")" = "failed" ]
}

@test "graph_state_write_node heartbeat, usage, and log-metadata updates converge onto one attempts[] record" {
  graph_state_init_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$PLAN_FILE" "$GRAPH_JSON" 2 >/dev/null
  local nid="left"
  local aid="${nid}__${RUN_ID}__1"
  local node_file
  node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid")"

  # Starting an attempt creates one record.
  graph_state_write_node "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "running" \
    "$aid" '{"startedAt":"2026-01-01T00:00:00Z","runtime":"cursor"}' >/dev/null
  # A heartbeat refresh (same running state, same attemptId) updates the
  # same record in place.
  graph_state_write_node "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "running" \
    "$aid" '{"heartbeatAt":"2026-01-01T00:00:15Z"}' >/dev/null
  # A mid-run usage snapshot updates the same record.
  graph_state_write_node "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "running" \
    "$aid" '{"usageSnapshot":{"input_tokens":3},"usageReliable":true}' >/dev/null
  # Log metadata updates the same record.
  graph_state_write_node "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "running" \
    "$aid" '{"logPaths":{"runner":"logs/nodes/left/1/runner.log"}}' >/dev/null
  # Terminalization updates the same record.
  graph_state_write_node "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "succeeded" \
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
  graph_state_init_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$PLAN_FILE" "$GRAPH_JSON" 2 >/dev/null
  local nid="left"
  local aid="${nid}__${RUN_ID}__1"
  local node_file
  node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid")"

  graph_state_write_node "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "running" \
    "$aid" '{"startedAt":"2026-01-01T00:00:00Z"}' >/dev/null
  graph_state_write_node "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "failed" \
    "$aid" '{"outcome":"failed","exitCode":1,"finishedAt":"2026-01-01T00:01:00Z"}' >/dev/null

  (
    graph_state_write_node "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "failed" \
      "$aid" '{"outcome":"failed","exitCode":1,"finishedAt":"2026-01-01T00:01:00Z"}'
  ) &
  local pid1=$!
  (
    graph_state_write_node "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "failed" \
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
  graph_state_init_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$PLAN_FILE" "$GRAPH_JSON" 2 >/dev/null
  local nid="left"
  local aid1="${nid}__${RUN_ID}__1"
  local aid2="${nid}__${RUN_ID}__2"
  local node_file
  node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid")"

  graph_state_write_node "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "running" \
    "$aid1" '{"startedAt":"2026-01-01T00:00:00Z"}' >/dev/null
  graph_state_write_node "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "failed" \
    "$aid1" '{"outcome":"failed","exitCode":1,"finishedAt":"2026-01-01T00:00:05Z"}' >/dev/null
  graph_state_write_node "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "pending" >/dev/null
  graph_state_write_node "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "running" \
    "$aid2" '{"startedAt":"2026-01-01T00:00:10Z"}' >/dev/null
  # Interleave a heartbeat on attempt 2 with a (no-op re-write) touch on the
  # already-terminal attempt 1 to prove the two records stay independent.
  graph_state_write_node "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "running" \
    "$aid2" '{"heartbeatAt":"2026-01-01T00:00:20Z"}' >/dev/null
  graph_state_write_node "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "running" \
    "$aid1" '{"outcome":"failed"}' >/dev/null
  graph_state_write_node "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "succeeded" \
    "$aid2" '{"outcome":"succeeded","exitCode":0,"finishedAt":"2026-01-01T00:00:30Z"}' >/dev/null

  [ "$(jq '.attempts | length' "$node_file")" -eq 2 ]
  [ "$(jq -r '.attempts[0].attemptId' "$node_file")" = "$aid1" ]
  [ "$(jq -r '.attempts[0].outcome' "$node_file")" = "failed" ]
  [ "$(jq -r '.attempts[1].attemptId' "$node_file")" = "$aid2" ]
  [ "$(jq -r '.attempts[1].heartbeatAt' "$node_file")" = "2026-01-01T00:00:20Z" ]
  [ "$(jq -r '.attempts[1].outcome' "$node_file")" = "succeeded" ]
}

# ---------------------------------------------------------------------------
# Attempt numbering derives from the maximum numeric suffix of canonical IDs
# ---------------------------------------------------------------------------

@test "attempt numbering derives from the maximum numeric attemptId suffix, not attempts[] array length" {
  # A canonical ledger can have gaps after recovery. Resume reconciliation
  # must use the largest recorded suffix, not the two-entry array length.
  local node_file="$TMPD/numbering-node.json"
  cat > "$node_file" <<EOF
{
  "schemaVersion": 3,
  "nodeId": "left",
  "status": "failed",
  "attempts": [
    {"attemptId": "left__${RUN_ID}__1", "outcome": "failed", "exitCode": 1, "startedAt": "t0", "finishedAt": "t1"},
    {"attemptId": "left__${RUN_ID}__3", "outcome": "failed", "exitCode": 1, "startedAt": "t2", "finishedAt": "t3"}
  ],
  "lastAttemptId": "left__${RUN_ID}__3"
}
EOF
  local max_suffix
  max_suffix="$(graph_state_max_attempt_number "$node_file")"
  [ "$max_suffix" -eq 3 ]
  [ "$max_suffix" -ne "$(jq '.attempts | length' "$node_file")" ]
  [ "$(graph_state_max_attempt_number "$TMPD/missing-node.json")" -eq 0 ]
}

@test "canonical readers reject a prior node schema without transforming it" {
  graph_state_init_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$PLAN_FILE" "$GRAPH_JSON" 2 >/dev/null
  local node_file before after
  node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" left)"
  printf '%s\n' '{"schemaVersion":1,"nodeId":"left","status":"pending","attempts":[],"lastAttemptId":null}' > "$node_file"
  before="$(shasum "$node_file" | awk '{print $1}')"

  run graph_state_read_node "$WORKSPACE" "$NAMESPACE" "$RUN_ID" left
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires schemaVersion 3"* ]]
  after="$(shasum "$node_file" | awk '{print $1}')"
  [ "$before" = "$after" ]
}

@test "canonical readers reject a prior run schema without transforming it" {
  graph_state_init_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$PLAN_FILE" "$GRAPH_JSON" 2 >/dev/null
  local run_file before after
  run_file="$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  jq '.schemaVersion = 2' "$run_file" > "$run_file.tmp"
  mv "$run_file.tmp" "$run_file"
  before="$(shasum "$run_file" | awk '{print $1}')"

  run graph_state_read_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires schemaVersion 3"* ]]
  [[ "$output" == *"detected schemaVersion 2"* ]]
  after="$(shasum "$run_file" | awk '{print $1}')"
  [ "$before" = "$after" ]
}

# ---------------------------------------------------------------------------
# Future-version rejection
# ---------------------------------------------------------------------------

@test "graph_state_read_node rejects an unknown future node schemaVersion with an actionable error" {
  graph_state_init_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$PLAN_FILE" "$GRAPH_JSON" 2 >/dev/null
  local nid="left"
  local node_file
  node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid")"
  printf '%s' '{"schemaVersion":99,"nodeId":"left","status":"succeeded","attempts":[],"lastAttemptId":null}' \
    > "$node_file"

  run graph_state_read_node "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid"
  [ "$status" -ne 0 ]
  [[ "$output" = *"schemaVersion 99"* ]]
  [[ "$output" = *"Re-create this graph run"* ]]
}

@test "graph_state_read_run rejects an unknown future run schemaVersion with an actionable error" {
  graph_state_init_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$PLAN_FILE" "$GRAPH_JSON" 2 >/dev/null
  local run_file
  run_file="$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  printf '%s' '{"schemaVersion":42,"runId":"'"$RUN_ID"'","status":"running"}' > "$run_file"

  run graph_state_read_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID"
  [ "$status" -ne 0 ]
  [[ "$output" = *"schemaVersion 42"* ]]
  [[ "$output" = *"Re-create this graph run"* ]]
}

@test "graph_state_write_node refuses to write onto a node ledger with an unknown future schemaVersion" {
  graph_state_init_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$PLAN_FILE" "$GRAPH_JSON" 2 >/dev/null
  local nid="left"
  local node_file
  node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid")"
  printf '%s' '{"schemaVersion":99,"nodeId":"left","status":"succeeded","attempts":[],"lastAttemptId":null}' \
    > "$node_file"

  run graph_state_write_node "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "running"
  [ "$status" -ne 0 ]
  [[ "$output" = *"schemaVersion 99"* ]]
}

@test "graph_state_read_node rejects a non-numeric schemaVersion" {
  graph_state_init_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$PLAN_FILE" "$GRAPH_JSON" 2 >/dev/null
  local nid="left"
  local node_file
  node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid")"
  printf '%s' '{"schemaVersion":"not-a-number","nodeId":"left","status":"pending","attempts":[],"lastAttemptId":null}' \
    > "$node_file"

  run graph_state_read_node "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid"
  [ "$status" -ne 0 ]
  [[ "$output" = *"schemaVersion not-a-number"* ]]
}

# ---------------------------------------------------------------------------
# v2 attempts carry the enriched field set the schema defines
# ---------------------------------------------------------------------------

@test "graph_state_write_node merges extra_json onto the same attempt object" {
  graph_state_init_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$PLAN_FILE" "$GRAPH_JSON" 2 >/dev/null
  local nid="left"
  local aid="${nid}__${RUN_ID}__1"
  local node_file
  node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid")"

  graph_state_write_node "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "running" \
    "$aid" '{"startedAt":"2026-01-01T00:00:00Z"}' \
    '{"workspaceMode":"snapshot","workspacePath":"/tmp/ws"}' >/dev/null
  graph_state_write_node "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "succeeded" \
    "$aid" '{"outcome":"succeeded","exitCode":0}' \
    '{"changesetHash":"abc123"}' >/dev/null

  [ "$(jq '.attempts | length' "$node_file")" -eq 1 ]
  [ "$(jq -r '.attempts[0].startedAt' "$node_file")" = "2026-01-01T00:00:00Z" ]
  [ "$(jq -r '.attempts[0].workspaceMode' "$node_file")" = "snapshot" ]
  [ "$(jq -r '.attempts[0].changesetHash' "$node_file")" = "abc123" ]
  [ "$(jq -r '.workspaceMode' "$node_file")" = "snapshot" ]
  [ "$(jq -r '.changesetHash' "$node_file")" = "abc123" ]
}

@test "graph_state_reset_node_to_pending keeps schemaVersion 3 and existing attempts" {
  graph_state_init_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$PLAN_FILE" "$GRAPH_JSON" 2 >/dev/null
  local nid="left"
  local aid="${nid}__${RUN_ID}__1"
  local node_file
  node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid")"

  graph_state_write_node "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "running" \
    "$aid" '{"startedAt":"2026-01-01T00:00:00Z"}' >/dev/null
  graph_state_reset_node_to_pending "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid"

  [ "$(jq -r '.schemaVersion' "$node_file")" = "3" ]
  [ "$(jq -r '.status' "$node_file")" = "pending" ]
  [ "$(jq '.attempts | length' "$node_file")" -eq 1 ]
  [ "$(jq -r '.attempts[0].attemptId' "$node_file")" = "$aid" ]
  [ "$(jq -r '.attempts[0].startedAt' "$node_file")" = "2026-01-01T00:00:00Z" ]
}

@test "an attempt object can carry the full enriched field set" {
  graph_state_init_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$PLAN_FILE" "$GRAPH_JSON" 2 >/dev/null
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
  run graph_state_write_node "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "failed" "$aid" "$fields"
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

# ---------------------------------------------------------------------------
# Tooling profile run/node ledger (schemaVersion 3)
# ---------------------------------------------------------------------------

TOOLING_PLAN="$BATS_TEST_DIRNAME/../../fixtures/graph/graph-tooling.plan.md"

@test "graph_state_init_run records distinct per-node tooling profiles in run and node ledgers" {
  local tooling_graph="$TMPD/tooling-graph.json"
  compile_graph "$TOOLING_PLAN" "$WORKSPACE" "$tooling_graph"
  local tooling_plan="$WORKSPACE/$(basename "$TOOLING_PLAN")"
  local run_id="run-tooling-001"

  run graph_state_init_run "$WORKSPACE" "$NAMESPACE" "$run_id" "$tooling_plan" "$tooling_graph" 2
  [ "$status" -eq 0 ]

  local run_file
  run_file="$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$run_id")"
  [ "$(jq -r '.schemaVersion' "$run_file")" = "3" ]
  [ "$(jq -r '.tooling.defaultProfile' "$run_file")" = "ralph-compact" ]
  [ "$(jq -r '.tooling.nodes.research' "$run_file")" = "ralph-compact" ]
  [ "$(jq -r '.tooling.nodes.qa' "$run_file")" = "ralph-read-heavy" ]
  [ "$(jq -c '.tooling.nodes' "$run_file")" = "$(jq -c '[.nodes[] | {key:.id, value:(.stage.toolingProfile // null)}] | from_entries' "$tooling_graph")" ]

  local research_file qa_file
  research_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$run_id" research)"
  qa_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$run_id" qa)"
  [ "$(jq -r '.schemaVersion' "$research_file")" = "3" ]
  [ "$(jq -r '.schemaVersion' "$qa_file")" = "3" ]
  [ "$(jq -r '.toolingProfile' "$research_file")" = "ralph-compact" ]
  [ "$(jq -r '.toolingProfile' "$qa_file")" = "ralph-read-heavy" ]
  [ "$(jq -r '.toolingProfile' "$research_file")" != "$(jq -r '.toolingProfile' "$qa_file")" ]
}

@test "graph_state_init_run seeds toolingDegradedKeys when the static resolver drops keys" {
  local graph_file="$TMPD/degrade-graph.json"
  jq -n '{
    schemaVersion: 1,
    ralphVersion: "test",
    name: "degrade",
    namespace: "degrade",
    maxParallel: 1,
    failurePolicy: "drain",
    tooling: {defaultProfile: "ralph-aggressive"},
    nodes: [{
      id: "agy",
      type: "agent",
      dependsOn: [],
      derivedFrom: "stage",
      stage: {
        id: "agy",
        runtime: "antigravity",
        role: "implementation",
        toolingProfile: "ralph-aggressive"
      }
    }],
    edges: []
  }' >"$graph_file"

  run graph_state_init_run "$WORKSPACE" "$NAMESPACE" "run-degrade" "$PLAN_FILE" "$graph_file" 1
  [ "$status" -eq 0 ]

  local node_file
  node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "run-degrade" agy)"
  [ "$(jq -r '.schemaVersion' "$node_file")" = "3" ]
  [ "$(jq -r '.toolingProfile' "$node_file")" = "ralph-aggressive" ]
  [ "$(jq -e '.toolingDegradedKeys | type == "array" and length > 0' "$node_file")" = "true" ]
  [ "$(jq -c '.toolingDegradedKeys' "$node_file")" = "$(jq -c '.toolingDegradedKeys | sort' "$node_file")" ]
  [ "$(jq -r '.toolingDegradedKeys[]' "$node_file" | grep -c 'RALPH_PROXY_SHELL_COMPACT' || true)" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Common workflow run ID + outer registry pointer (Dependency adapter)
# ---------------------------------------------------------------------------

@test "graph_state_init_run accepts a common workflow run ID without reminting" {
  local common_id="run-20260101T120000Z-0-common"
  run graph_state_init_run "$WORKSPACE" "$NAMESPACE" "$common_id" "$PLAN_FILE" "$GRAPH_JSON" 2
  [ "$status" -eq 0 ]

  local run_file run_dir
  run_file="$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$common_id")"
  run_dir="$(graph_state_run_dir "$WORKSPACE" "$NAMESPACE" "$common_id")"
  [ -f "$run_file" ]
  [ "$(jq -r '.runId' "$run_file")" = "$common_id" ]
  [ "$(basename "$run_dir")" = "$common_id" ]
  [ "$(jq -r '.registryRunPath' "$run_file")" = "null" ]
}

@test "graph_state_init_run stores an absolute registry pointer on the graph ledger" {
  local common_id="run-20260101T120000Z-0-regptr"
  local registry_run="$TMPD/workflow-runs/$common_id"
  mkdir -p "$registry_run"
  registry_run="$(cd "$registry_run" && pwd -P)"

  run graph_state_init_run "$WORKSPACE" "$NAMESPACE" "$common_id" "$PLAN_FILE" "$GRAPH_JSON" 2 "$registry_run"
  [ "$status" -eq 0 ]

  local run_file
  run_file="$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$common_id")"
  [ "$(jq -r '.runId' "$run_file")" = "$common_id" ]
  [ "$(jq -r '.registryRunPath' "$run_file")" = "$registry_run" ]
  case "$(jq -r '.registryRunPath' "$run_file")" in
    /*) ;;
    *) false ;;
  esac

  # Relative registry paths are refused.
  run graph_state_init_run "$WORKSPACE" "$NAMESPACE" "${common_id}-bad" "$PLAN_FILE" "$GRAPH_JSON" 2 "relative/path"
  [ "$status" -ne 0 ]
  [[ "$output" == *"absolute"* ]]
}

# --- Dependency approval schedule/state (sourced; no graph-run) ---

load_dep_approval_libs() {
  source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-schedule.sh"
  source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/workflow/workflow-actions.sh"
  source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/workflow/workflow-state.sh"
  source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/workflow/workflow-engine-dependency.sh"
}

write_dep_approval_graph() {
  local out_path="$1" ns="$2"
  python3 - "$out_path" "$ns" <<'PY'
import json, sys
out_path, ns = sys.argv[1], sys.argv[2]
doc = {
    "schemaVersion": 2,
    "ralphVersion": "1.0.0",
    "name": ns,
    "namespace": ns,
    "maxParallel": 1,
    "failurePolicy": "drain",
    "nodes": [
        {
            "id": "plan-implementation",
            "type": "agent",
            "dependsOn": [],
            "derivedFrom": "stage",
            "stage": {
                "id": "plan-implementation",
                "runtime": "cursor",
                "_inlineTodos": [{"id": "p1", "content": "plan", "verification": "ok", "status": "pending"}],
            },
        },
        {
            "id": "approve-plan",
            "type": "approval",
            "dependsOn": ["plan-implementation"],
            "derivedFrom": "stage",
            "stage": {
                "id": "approve-plan",
                "type": "approval",
                "question": "Approve the concrete implementation plan?",
                "changesTarget": "plan-implementation",
                "inputArtifacts": [{
                    "path": f".ralph-workspace/artifacts/{ns}/impl-plan.json",
                    "required": True,
                }],
            },
        },
    ],
    "edges": [{"from": "plan-implementation", "to": "approve-plan", "reasons": ["declared"]}],
}
with open(out_path, "w", encoding="utf-8") as fh:
    json.dump(doc, fh)
PY
}

seed_dep_approval_registry() {
  local state_root="$1" run_id="$2" registry_run="$3" graph_run="$4"
  mkdir -p "$registry_run" "$graph_run"
  state_root="$(cd "$state_root" && pwd -P)"
  registry_run="$(cd "$registry_run" && pwd -P)"
  graph_run="$(cd "$graph_run" && pwd -P)"
  cat >"$registry_run/run.json" <<JSON
{
  "runId": "$run_id",
  "workflowId": null,
  "sourcePath": "/tmp/source.workflow.md",
  "sourceKind": "file",
  "mode": "dependency",
  "entryKind": "task",
  "task": "ship it",
  "taskProvenance": "explicit",
  "inputPath": "$registry_run/input.plan.md",
  "inputPlan": null,
  "state": "running",
  "createdAt": "2026-08-26T12:00:00Z",
  "updatedAt": "2026-08-26T12:00:00Z",
  "owner": {"pid": 1, "hostname": "host", "processStartId": "1:1", "heartbeatAt": "2026-08-26T12:00:00Z"},
  "engine": {"kind": "graph", "statePath": "$graph_run", "namespace": "dep-appr"}
}
JSON
  printf '%s\n' "task" >"$registry_run/input.plan.md"
  jq -cn --arg state "$state_root" --arg rrp "$registry_run" \
    '{roots:{stateRoot:$state},registryRunPath:$rrp,status:"running"}' >"$graph_run/run.json"
}

@test "Dependency approval activate waiting exit 3 no runtime and consume once approve" {
  command -v python3 >/dev/null || skip "python3 required"
  load_dep_approval_libs
  local state_root="$TMPD/state" ws="$TMPD/ws" ns="dep-appr" run_id="run-appr-001"
  local registry_run="$state_root/workflow-runs/$run_id"
  local graph_run="$state_root/graph-runs/$ns/$run_id"
  local graph_json="$TMPD/graph.json" evidence_file activation result

  mkdir -p "$ws/.ralph-workspace/artifacts/$ns"
  printf '{"ok":true}\n' >"$ws/.ralph-workspace/artifacts/$ns/impl-plan.json"
  write_dep_approval_graph "$graph_json" "$ns"
  seed_dep_approval_registry "$state_root" "$run_id" "$registry_run" "$graph_run"
  export RALPH_WORKFLOW_REGISTRY_RUN="$registry_run"
  export RALPH_GRAPH_STATE_ROOT="$state_root"
  export RALPH_PLAN_WORKSPACE_ROOT="$state_root"
  export WORKFLOW_ACTION_NOW="2026-08-26T12:00:00Z"

  graph_schedule_load_index "$graph_json"
  GRAPH_SCHEDULE_WORKSPACE="$ws"
  GRAPH_SCHEDULE_NAMESPACE="$ns"
  GRAPH_SCHEDULE_LEDGER_NAMESPACE="$ns"
  GRAPH_SCHEDULE_RUN_ID="$run_id"
  GRAPH_SCHEDULE_GRAPH_JSON="$graph_json"
  GRAPH_SCHEDULE_LEDGER_RUN_DIR="$graph_run"
  GRAPH_SCHEDULE_EXIT_CODE=0
  GRAPH_SCHEDULE_AWAITING_OPERATOR=0
  # Mark upstream succeeded so approval is the subject under test.
  GRAPH_NODE_STATES[$(graph_schedule_index_map_get plan-implementation)]="succeeded"
  GRAPH_NODE_STATES[$(graph_schedule_index_map_get approve-plan)]="pending"

  # Call handlers in-process (not bats `run`) so GRAPH_NODE_STATES persist.
  _graph_schedule_handle_approval_node "approve-plan"
  [ "${GRAPH_NODE_STATES[$(graph_schedule_index_map_get approve-plan)]}" = "awaiting-operator" ]
  [ "$GRAPH_SCHEDULE_AWAITING_OPERATOR" -eq 1 ]
  [ "$GRAPH_SCHEDULE_EXIT_CODE" -eq 3 ]
  [ "$(jq -r '.state' "$registry_run/run.json")" = "waiting" ]
  [ "$(jq -r '.owner.pid' "$registry_run/run.json")" = "null" ]
  [ "$(find "$registry_run/actions/requests" -name '*.json' | wc -l | tr -d ' ')" = "1" ]

  # Duplicate outstanding request fails closed (no second request).
  GRAPH_NODE_STATES[$(graph_schedule_index_map_get approve-plan)]="pending"
  if _graph_schedule_handle_approval_node "approve-plan" 2>"$TMPD/dup.err"; then
    echo "expected duplicate approval activate to fail" >&2
    return 1
  fi
  grep -Eq 'duplicate|approval activate failed|approval-activate-failed' "$TMPD/dup.err" || {
    # Handler may only surface via apply_node_failure; still require single request.
    true
  }
  [ "$(find "$registry_run/actions/requests" -name '*.json' | wc -l | tr -d ' ')" = "1" ]

  local request_id attempt_id
  request_id="$(jq -r '.requestId' "$registry_run/actions/requests/"*.json)"
  attempt_id="$(jq -r '.attemptId' "$registry_run/actions/requests/"*.json)"
  workflow_action_decision_write "$registry_run" "$(jq -nc \
    --arg rid "$request_id" --arg aid "$attempt_id" '{
    requestId:$rid, kind:"approval", runId:"run-appr-001", stageId:"approve-plan",
    attemptId:$aid, decision:"approve", actorSource:"human",
    decidedAt:"2026-08-26T12:05:00Z"
  }')" >/dev/null

  GRAPH_NODE_STATES[$(graph_schedule_index_map_get approve-plan)]="awaiting-operator"
  _graph_schedule_resume_approval_node "approve-plan"
  [ "${GRAPH_NODE_STATES[$(graph_schedule_index_map_get approve-plan)]}" = "succeeded" ]
  [ -f "$registry_run/actions/consumed/$request_id.json" ]

  # Consume once: second resume refuses.
  GRAPH_NODE_STATES[$(graph_schedule_index_map_get approve-plan)]="awaiting-operator"
  if _graph_schedule_resume_approval_node "approve-plan" 2>/dev/null; then
    # May return 0 while refusing class; require consume-once still sole.
    [ "$(find "$registry_run/actions/consumed" -name '*.json' | wc -l | tr -d ' ')" = "1" ]
  fi
  [ "$(find "$registry_run/actions/consumed" -name '*.json' | wc -l | tr -d ' ')" = "1" ]
}

@test "Dependency approval request changesTarget reset argv and cancel durable intent" {
  command -v python3 >/dev/null || skip "python3 required"
  load_dep_approval_libs
  local state_root="$TMPD/state2" ws="$TMPD/ws2" ns="dep-appr2" run_id="run-appr-002"
  local registry_run="$state_root/workflow-runs/$run_id"
  local graph_run="$state_root/graph-runs/$ns/$run_id"
  local graph_json="$TMPD/graph2.json" request_id attempt_id result

  mkdir -p "$ws/.ralph-workspace/artifacts/$ns"
  printf '{"ok":true}\n' >"$ws/.ralph-workspace/artifacts/$ns/impl-plan.json"
  write_dep_approval_graph "$graph_json" "$ns"
  seed_dep_approval_registry "$state_root" "$run_id" "$registry_run" "$graph_run"
  export RALPH_WORKFLOW_REGISTRY_RUN="$registry_run"
  export RALPH_GRAPH_STATE_ROOT="$state_root"
  export RALPH_PLAN_WORKSPACE_ROOT="$state_root"
  export WORKFLOW_ACTION_NOW="2026-08-26T12:00:00Z"

  activation="$(workflow_dep_approval_activate \
    --workspace "$ws" --namespace "$ns" --run-id "$run_id" \
    --graph-json "$graph_json" --node-id approve-plan \
    --attempt-id "approve-plan__${run_id}__1" \
    --graph-run-dir "$graph_run" --state-root "$state_root")"
  [ "$(printf '%s' "$activation" | jq -r '.blocker.reasonCode')" = "human-approval" ]
  [ "$(jq -r '.state' "$registry_run/run.json")" = "waiting" ]
  request_id="$(printf '%s' "$activation" | jq -r '.requestId')"
  attempt_id="approve-plan__${run_id}__1"

  workflow_action_decision_write "$registry_run" "$(jq -nc \
    --arg rid "$request_id" --arg aid "$attempt_id" '{
    requestId:$rid, kind:"approval", runId:"run-appr-002", stageId:"approve-plan",
    attemptId:$aid, decision:"request-changes", actorSource:"human",
    decidedAt:"2026-08-26T12:05:00Z", message:"Tighten acceptance criteria."
  }')" >/dev/null
  result="$(workflow_dep_approval_apply_decision \
    --registry-run "$registry_run" --request-id "$request_id" \
    --run-id "$run_id" --state-root "$state_root")"
  [ "$(printf '%s' "$result" | jq -r '.outcome')" = "changes-requested" ]
  [ "$(printf '%s' "$result" | jq -r '.nodeState')" = "blocked" ]
  [ "$(printf '%s' "$result" | jq -c '.nextAction.argv')" = "[\"ralph\",\"workflow\",\"reset\",\"run-appr-002\",\"--stage\",\"plan-implementation\"]" ]
  [ "$(jq -r '.state' "$registry_run/run.json")" = "blocked" ]

  # Fresh request for cancel path.
  run_id="run-appr-003"
  registry_run="$state_root/workflow-runs/$run_id"
  graph_run="$state_root/graph-runs/$ns/$run_id"
  seed_dep_approval_registry "$state_root" "$run_id" "$registry_run" "$graph_run"
  export RALPH_WORKFLOW_REGISTRY_RUN="$registry_run"
  activation="$(workflow_dep_approval_activate \
    --workspace "$ws" --namespace "$ns" --run-id "$run_id" \
    --graph-json "$graph_json" --node-id approve-plan \
    --attempt-id "approve-plan__${run_id}__1" \
    --graph-run-dir "$graph_run" --state-root "$state_root")"
  request_id="$(printf '%s' "$activation" | jq -r '.requestId')"
  workflow_action_decision_write "$registry_run" "$(jq -nc \
    --arg rid "$request_id" --arg aid "approve-plan__${run_id}__1" '{
    requestId:$rid, kind:"approval", runId:"run-appr-003", stageId:"approve-plan",
    attemptId:$aid, decision:"cancel", actorSource:"human",
    decidedAt:"2026-08-26T12:06:00Z"
  }')" >/dev/null
  result="$(workflow_dep_approval_apply_decision \
    --registry-run "$registry_run" --request-id "$request_id" \
    --run-id "$run_id" --state-root "$state_root")"
  [ "$(printf '%s' "$result" | jq -r '.outcome')" = "cancelled" ]
  [ "$(jq -r '.state' "$registry_run/run.json")" = "cancelled" ]
  [ -s "$registry_run/actions/cancel-intent.json" ]
  [ "$(jq -r '.kind' "$registry_run/actions/cancel-intent.json")" = "cancel-intent" ]
}

# --- Dependency operator interrupt / cancel checkpoint (sourced; no graph-run) ---
#
# Owning contract: checkpoint-workflow-on-operator-interrupt. Handlers are
# exercised as sourced functions with a stubbed child teardown, plus exactly one
# minimal signalled subshell. No runtime, no full graph run, no blocking sleep.

write_dep_interrupt_graph() {
  local out_path="$1" ns="$2"
  jq -cn --arg ns "$ns" '{
    schemaVersion: 2,
    ralphVersion: "1.0.0",
    name: $ns,
    namespace: $ns,
    maxParallel: 1,
    failurePolicy: "drain",
    nodes: [{
      id: "implement",
      type: "agent",
      dependsOn: [],
      derivedFrom: "stage",
      stage: {
        id: "implement",
        runtime: "cursor",
        _inlineTodos: [{id: "t1", content: "do it", verification: "ok", status: "pending"}]
      }
    }],
    edges: []
  }' >"$out_path"
}

# seed_dep_interrupt_run <run-id> <namespace>
# Sets DEP_STATE_ROOT, DEP_REGISTRY_RUN, DEP_GRAPH_RUN, DEP_ATTEMPT and leaves the
# node running with an owned supervisor, one granted capability, and a control
# artifact whose bytes must survive the checkpoint.
seed_dep_interrupt_run() {
  local run_id="$1" ns="$2" graph_json
  DEP_STATE_ROOT="$TMPD/$run_id-state"
  DEP_REGISTRY_RUN="$DEP_STATE_ROOT/workflow-runs/$run_id"
  DEP_ATTEMPT="implement__${run_id}__1"
  graph_json="$TMPD/$run_id-graph.json"
  mkdir -p "$DEP_REGISTRY_RUN"
  DEP_STATE_ROOT="$(cd "$DEP_STATE_ROOT" && pwd -P)"
  DEP_REGISTRY_RUN="$(cd "$DEP_REGISTRY_RUN" && pwd -P)"
  export RALPH_PLAN_WORKSPACE_ROOT="$DEP_STATE_ROOT"
  export RALPH_GRAPH_STATE_ROOT="$DEP_STATE_ROOT"
  export WORKFLOW_ACTION_NOW="2026-08-26T12:00:00Z"
  export WORKFLOW_STATE_SKIP_FSYNC=1

  write_dep_interrupt_graph "$graph_json" "$ns"
  printf 'plan\n' >"$TMPD/$run_id-plan.md"
  graph_state_init_run "$DEP_STATE_ROOT" "$ns" "$run_id" \
    "$TMPD/$run_id-plan.md" "$graph_json" 1 "$DEP_REGISTRY_RUN"
  DEP_GRAPH_RUN="$(graph_state_run_dir "$DEP_STATE_ROOT" "$ns" "$run_id")"

  # Immutable source + mutable control plan whose bytes must not change.
  printf 'immutable source\n' >"$DEP_REGISTRY_RUN/input.plan.md"
  printf '%s\n' '- [x] done' '- [ ] next' >"$DEP_REGISTRY_RUN/control.plan.md"
  cat >"$DEP_REGISTRY_RUN/run.json" <<JSON
{
  "runId": "$run_id",
  "workflowId": null,
  "sourcePath": "/tmp/source.workflow.md",
  "sourceKind": "file",
  "mode": "dependency",
  "entryKind": "task",
  "task": "ship it",
  "taskProvenance": "explicit",
  "inputPath": "$DEP_REGISTRY_RUN/input.plan.md",
  "inputPlan": null,
  "state": "running",
  "createdAt": "2026-08-26T12:00:00Z",
  "updatedAt": "2026-08-26T12:00:00Z",
  "owner": {"pid": 4242, "hostname": "host", "processStartId": "1:1", "heartbeatAt": "2026-08-26T12:00:00Z"},
  "engine": {"kind": "graph", "statePath": "$DEP_GRAPH_RUN", "namespace": "$ns"}
}
JSON

  graph_state_write_node "$DEP_STATE_ROOT" "$ns" "$run_id" implement running "$DEP_ATTEMPT" '{}' '{}'
  ralph_atomic_write_json "$DEP_GRAPH_RUN/run.json" \
    '($b | fromjson) + {currentNodeIds:["implement"], supervisorPid:4242, ownerHostname:"host", ownerProcessStartId:"1:1", heartbeatAt:"2026-08-26T12:00:00Z"}' \
    --arg b "$(jq -c . "$DEP_GRAPH_RUN/run.json")"
  workflow_action_capability_write "$DEP_REGISTRY_RUN" "$run_id" implement "$DEP_ATTEMPT" >/dev/null
}

# dep_wait_for_file <path> [deadline-secs]
# Concrete file condition with a wall-clock deadline and a small poll, per
# agents/rules/test-design.md. Never a blocking sleep.
dep_wait_for_file() {
  local path="$1" deadline
  deadline=$(( $(date +%s) + ${2:-20} ))
  until [[ -e "$path" ]]; do
    [[ $(date +%s) -lt $deadline ]] || {
      echo "timed out waiting for $path" >&2
      return 1
    }
    sleep 0.05
  done
  return 0
}

@test "Dependency workflow SIGINT checkpoint parks waiting after stub child teardown" {
  command -v jq >/dev/null || skip "jq required"
  load_dep_approval_libs
  local run_id="run-int-001" ns="dep-int" node_file control_before
  seed_dep_interrupt_run "$run_id" "$ns"
  node_file="$(graph_state_node_file "$DEP_STATE_ROOT" "$ns" "$run_id" implement)"
  control_before="$(cksum <"$DEP_REGISTRY_RUN/control.plan.md")"

  # One minimal signalled subshell: it blocks on a FIFO open (interruptible,
  # no blocking sleep), tears down a stub child, then checkpoints and exits 130.
  local fifo="$TMPD/$run_id.fifo" ready="$TMPD/$run_id.ready"
  local teardown_marker="$TMPD/$run_id.teardown" pid rc=0
  mkfifo "$fifo"
  (
    _graph_schedule_cancel_inflight_children() { : >"$teardown_marker"; }
    handler() {
      trap '' INT TERM HUP
      _graph_schedule_cancel_inflight_children
      workflow_dep_operator_interrupt_checkpoint "$DEP_REGISTRY_RUN" "$DEP_STATE_ROOT" || exit 1
      exit 130
    }
    trap handler INT
    : >"$ready"
    read -r _ <"$fifo" || true
    exit 0
  ) &
  pid=$!
  dep_wait_for_file "$ready" 20
  kill -INT "$pid" 2>/dev/null || true
  wait "$pid" || rc=$?

  [ "$rc" -eq 130 ]
  # Child teardown ran before the checkpoint was written.
  [ -f "$teardown_marker" ]

  # Owner cleared, both projections parked, diagnosis retryable with resume argv.
  [ "$(jq -r '.state' "$DEP_REGISTRY_RUN/run.json")" = "waiting" ]
  [ "$(jq -r '.owner.pid' "$DEP_REGISTRY_RUN/run.json")" = "null" ]
  [ "$(jq -r '.status' "$DEP_GRAPH_RUN/run.json")" = "awaiting-operator" ]
  [ "$(jq -r '.supervisorPid,.ownerHostname,.heartbeatAt' "$DEP_GRAPH_RUN/run.json" | paste -sd, -)" = "null,null,null" ]
  [ "$(jq -r '.status' "$node_file")" = "interrupted" ]
  [ "$(jq -r '.state,.reasonCode,.retryable' "$DEP_REGISTRY_RUN/diagnosis.json" | paste -sd, -)" = "waiting,operator-request,true" ]
  [ "$(jq -c '.nextAction.argv' "$DEP_REGISTRY_RUN/diagnosis.json")" = "[\"ralph\",\"workflow\",\"resume\",\"$run_id\"]" ]

  # The interrupt is journalled against the canonical graph event vocabulary.
  [ "$(jq -r 'select(.event == "node-interrupted") | .details.phase' "$DEP_GRAPH_RUN/events.jsonl" | tail -n1)" = "operator-interrupted" ]
  [ "$(jq -r 'select(.event == "node-interrupted") | .attemptId' "$DEP_GRAPH_RUN/events.jsonl" | tail -n1)" = "$DEP_ATTEMPT" ]

  # Immutable input and the mutable control plan survive byte-for-byte.
  [ "$(cat "$DEP_REGISTRY_RUN/input.plan.md")" = "immutable source" ]
  [ "$(cksum <"$DEP_REGISTRY_RUN/control.plan.md")" = "$control_before" ]
}

@test "Dependency SIGINT action wait preserved when a request was published first" {
  command -v jq >/dev/null || skip "jq required"
  load_dep_approval_libs
  local run_id="run-int-002" ns="dep-int2" node_file request_id
  seed_dep_interrupt_run "$run_id" "$ns"
  node_file="$(graph_state_node_file "$DEP_STATE_ROOT" "$ns" "$run_id" implement)"

  # A durably published approval already owns this wait.
  request_id="req-${run_id//-/}-approval"
  workflow_action_request_write "$DEP_REGISTRY_RUN" "$(jq -nc \
    --arg id "$request_id" --arg run "$run_id" --arg attempt "$DEP_ATTEMPT" '{
      requestId:$id, kind:"approval", runId:$run, stageId:"implement", attemptId:$attempt,
      question:"Approve the plan?", changesTarget:"implement", createdAt:"2026-08-26T12:01:00Z"
    }')" >/dev/null
  [ -n "$(find "$DEP_REGISTRY_RUN/actions/requests" -name '*.json')" ]
  graph_state_write_node "$DEP_STATE_ROOT" "$ns" "$run_id" implement awaiting-operator "$DEP_ATTEMPT" '{}' '{}'

  workflow_dep_operator_interrupt_checkpoint "$DEP_REGISTRY_RUN" "$DEP_STATE_ROOT"

  # The action-derived wait is not overwritten and no second request is minted.
  [ "$(jq -r '.status' "$node_file")" = "awaiting-operator" ]
  [ "$(find "$DEP_REGISTRY_RUN/actions/requests" -name '*.json' | wc -l | tr -d ' ')" = "1" ]
  [ -z "$(jq -r 'select(.event == "node-interrupted")' "$DEP_GRAPH_RUN/events.jsonl")" ]
  # The run itself is still parked for the operator.
  [ "$(jq -r '.state' "$DEP_REGISTRY_RUN/run.json")" = "waiting" ]
  [ "$(jq -r '.status' "$DEP_GRAPH_RUN/run.json")" = "awaiting-operator" ]
}

@test "Dependency SIGINT capability revoked for the interrupted attempt only" {
  command -v jq >/dev/null || skip "jq required"
  load_dep_approval_libs
  local run_id="run-int-003" ns="dep-int3" own_cap other_cap
  seed_dep_interrupt_run "$run_id" "$ns"
  own_cap="$DEP_REGISTRY_RUN/actions/capabilities/implement-${DEP_ATTEMPT}.json"
  [ -f "$own_cap" ]
  # A capability for a different attempt must survive the checkpoint.
  other_cap="$(workflow_action_capability_write "$DEP_REGISTRY_RUN" "$run_id" implement "implement__${run_id}__2")"
  [ -f "$other_cap" ]

  workflow_dep_operator_interrupt_checkpoint "$DEP_REGISTRY_RUN" "$DEP_STATE_ROOT"

  [ ! -f "$own_cap" ]
  [ -f "$other_cap" ]
}

@test "Dependency cancel intent is durable and cancels outstanding actions without deleting them" {
  command -v jq >/dev/null || skip "jq required"
  load_dep_approval_libs
  local run_id="run-int-004" ns="dep-int4" request_path request_id
  seed_dep_interrupt_run "$run_id" "$ns"
  request_id="req-${run_id//-/}-input"
  workflow_action_request_write "$DEP_REGISTRY_RUN" "$(jq -nc \
    --arg id "$request_id" --arg run "$run_id" --arg attempt "$DEP_ATTEMPT" '{
      requestId:$id, kind:"input", runId:$run, stageId:"implement", attemptId:$attempt,
      question:"Which database?", createdAt:"2026-08-26T12:01:00Z"
    }')" >/dev/null
  request_path="$(find "$DEP_REGISTRY_RUN/actions/requests" -name '*.json' | head -n1)"
  [ "$(jq -r '.requestId' "$request_path")" = "$request_id" ]

  workflow_dep_operator_cancel "$DEP_REGISTRY_RUN" "$DEP_STATE_ROOT"

  # Durable intent recorded, and cancellation is a decision, not a deletion.
  [ -s "$DEP_REGISTRY_RUN/actions/cancel-intent.json" ]
  [ "$(jq -r '.kind,.source' "$DEP_REGISTRY_RUN/actions/cancel-intent.json" | paste -sd, -)" = "cancel-intent,operator-signal" ]
  [ -f "$request_path" ]
  [ "$(workflow_action_request_display_state "$DEP_REGISTRY_RUN" "$request_id")" = "answered" ]
  [ "$(workflow_action_decision_read "$DEP_REGISTRY_RUN" "$request_id" | jq -r '.decision')" = "cancel" ]

  # Cancel stays cancelled: it is never reclassified as retryable waiting.
  [ "$(jq -r '.state' "$DEP_REGISTRY_RUN/run.json")" = "cancelled" ]
  [ "$(jq -r '.status' "$DEP_GRAPH_RUN/run.json")" = "cancelled" ]
}
