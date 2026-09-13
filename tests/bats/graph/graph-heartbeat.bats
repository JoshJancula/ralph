#!/usr/bin/env bats
# Tests for graph run owner/heartbeat metadata: supervisor PID, hostname,
# process-start identity, and heartbeatAt initialization.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/plan-todo.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/atomic-json.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-state.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-heartbeat.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-schedule.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-status.sh"

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
  NAMESPACE="heartbeat-ns"
  RUN_ID="run-hb-001"
  GRAPH_JSON="$TMPD/graph.json"
  compile_graph "$DIAMOND_PLAN" "$WORKSPACE" "$GRAPH_JSON"
  PLAN_FILE="$WORKSPACE/$(basename "$DIAMOND_PLAN")"
  graph_state_init_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$PLAN_FILE" "$GRAPH_JSON" 2
}

teardown() {
  rm -rf "$TMPD"
}

@test "heartbeat owner metadata is initialized by graph_state_init_run" {
  export GRAPH_STATE_SUPERVISOR_PID=12345
  export GRAPH_STATE_OWNER_HOSTNAME="heartbeat-test-host"
  export GRAPH_STATE_OWNER_PROCESS_START_ID="proc-start-abc"
  export GRAPH_STATE_HEARTBEAT_AT="2026-08-12T01:00:00Z"

  run graph_state_init_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$PLAN_FILE" "$GRAPH_JSON" 2
  [ "$status" -eq 0 ]

  local run_file
  run_file="$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  [ -f "$run_file" ]

  [ "$(jq -r '.schemaVersion' "$run_file")" = "3" ]
  [ "$(jq -r '.status' "$run_file")" = "running" ]
  [ "$(jq -r '.supervisorPid' "$run_file")" = "12345" ]
  [ "$(jq -r '.ownerHostname' "$run_file")" = "heartbeat-test-host" ]
  [ "$(jq -r '.ownerProcessStartId' "$run_file")" = "proc-start-abc" ]
  [ "$(jq -r '.heartbeatAt' "$run_file")" = "2026-08-12T01:00:00Z" ]
}

@test "running graph owner can be rebound from startup process to scheduler" {
  local run_file
  run_file="$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  jq '.supervisorPid = 11111 | .ownerProcessStartId = "startup-process"' \
    "$run_file" >"$run_file.tmp"
  mv "$run_file.tmp" "$run_file"

  export GRAPH_STATE_OWNER_HOSTNAME="scheduler-host"
  export GRAPH_STATE_OWNER_PROCESS_START_ID="scheduler-process"
  export GRAPH_STATE_HEARTBEAT_AT="2026-08-12T01:02:00Z"
  graph_state_rebind_run_owner "$WORKSPACE" "$NAMESPACE" "$RUN_ID" 22222

  [ "$(jq -r '.supervisorPid' "$run_file")" = "22222" ]
  [ "$(jq -r '.ownerHostname' "$run_file")" = "scheduler-host" ]
  [ "$(jq -r '.ownerProcessStartId' "$run_file")" = "scheduler-process" ]
  [ "$(jq -r '.heartbeatAt' "$run_file")" = "2026-08-12T01:02:00Z" ]
}

set_run_json_field() {
  local run_file="$1" field="$2" value="$3"
  local tmp
  tmp="$(mktemp)"
  jq --arg f "$field" --arg v "$value" '.[$f] = $v' "$run_file" > "$tmp"
  mv "$tmp" "$run_file"
}

set_run_json_null() {
  local run_file="$1" field="$2"
  local tmp
  tmp="$(mktemp)"
  jq --arg f "$field" '.[$f] = null' "$run_file" > "$tmp"
  mv "$tmp" "$run_file"
}

@test "heartbeat liveness returns healthy for fresh heartbeat and matching owner process" {
  local run_file heartbeat_epoch
  run_file="$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  heartbeat_epoch="$(graph_heartbeat_parse_iso_to_epoch "2026-08-12T00:00:00Z")"
  set_run_json_field "$run_file" "heartbeatAt" "2026-08-12T00:00:00Z"

  run graph_heartbeat_classify_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID" 60 "$heartbeat_epoch"
  [ "$status" -eq 0 ]
  [ "$output" = "healthy" ]
}

@test "heartbeat liveness returns stale for expired heartbeat and dead process" {
  local run_file
  run_file="$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  set_run_json_field "$run_file" "heartbeatAt" "2026-08-12T00:00:00Z"
  set_run_json_field "$run_file" "supervisorPid" "99999"
  set_run_json_field "$run_file" "ownerProcessStartId" "old-start"

  run graph_heartbeat_classify_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID" 1 1999999999
  [ "$status" -eq 0 ]
  [ "$output" = "stale" ]
}

@test "heartbeat liveness returns stale for expired heartbeat and pid reuse" {
  local run_file owner_start
  run_file="$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  owner_start="$(graph_heartbeat_process_start_id_of_pid "$$")" || skip "process start identity is unavailable in this environment"
  set_run_json_field "$run_file" "heartbeatAt" "2026-08-12T00:00:00Z"
  set_run_json_field "$run_file" "supervisorPid" "$$"
  set_run_json_field "$run_file" "ownerProcessStartId" "different-start-id"

  run graph_heartbeat_classify_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID" 1 1999999999
  [ "$status" -eq 0 ]
  [ "$output" = "stale" ]
}

@test "heartbeat liveness returns unknown when heartbeat is missing" {
  local run_file
  run_file="$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  set_run_json_null "$run_file" "heartbeatAt"

  run graph_heartbeat_classify_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID"
  [ "$status" -eq 0 ]
  [ "$output" = "unknown" ]
}

@test "heartbeat liveness returns unknown when process inspection is unavailable" {
  local run_file
  run_file="$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  set_run_json_field "$run_file" "heartbeatAt" "2026-08-12T00:00:00Z"
  set_run_json_field "$run_file" "supervisorPid" "$$"
  set_run_json_field "$run_file" "ownerProcessStartId" "identity-not-needed-when-inspection-is-off"

  GRAPH_HEARTBEAT_PROCESS_LOOKUP=off \
    run graph_heartbeat_classify_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID" 1 1999999999
  [ "$status" -eq 0 ]
  [ "$output" = "unknown" ]
}

@test "heartbeat liveness returns unknown when supervisor pid is missing" {
  local run_file
  run_file="$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  set_run_json_field "$run_file" "heartbeatAt" "2026-08-12T00:00:00Z"
  set_run_json_null "$run_file" "supervisorPid"
  set_run_json_field "$run_file" "ownerProcessStartId" "some-start"

  run graph_heartbeat_classify_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID" 1 1999999999
  [ "$status" -eq 0 ]
  [ "$output" = "unknown" ]
}

@test "heartbeat liveness returns stale for a dead owner even when start identity is unavailable" {
  local run_file
  run_file="$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  set_run_json_field "$run_file" "heartbeatAt" "2026-08-12T00:00:00Z"
  set_run_json_field "$run_file" "supervisorPid" "99999"
  set_run_json_null "$run_file" "ownerProcessStartId"

  run graph_heartbeat_classify_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID" 1 1999999999
  [ "$status" -eq 0 ]
  [ "$output" = "stale" ]
}

@test "heartbeat liveness returns unknown for expired heartbeat with alive matching owner" {
  local run_file owner_start
  run_file="$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  owner_start="$(graph_heartbeat_process_start_id_of_pid "$$")" || skip "process start identity is unavailable in this environment"
  set_run_json_field "$run_file" "heartbeatAt" "2026-08-12T00:00:00Z"
  set_run_json_field "$run_file" "supervisorPid" "$$"
  set_run_json_field "$run_file" "ownerProcessStartId" "$owner_start"

  run graph_heartbeat_classify_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID" 1 1999999999
  [ "$status" -eq 0 ]
  [ "$output" = "unknown" ]
}

@test "heartbeat state update run heartbeat and idempotent repeat" {
  local run_file before after
  run_file="$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  [ "$(jq -r '.status' "$run_file")" = "running" ]

  export GRAPH_STATE_HEARTBEAT_AT="2026-08-12T01:00:30Z"
  run graph_state_update_run_heartbeat "$WORKSPACE" "$NAMESPACE" "$RUN_ID"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.heartbeatAt' "$run_file")" = "2026-08-12T01:00:30Z" ]

  before="$(shasum "$run_file" | awk '{print $1}')"
  run graph_state_update_run_heartbeat "$WORKSPACE" "$NAMESPACE" "$RUN_ID"
  [ "$status" -eq 0 ]
  after="$(shasum "$run_file" | awk '{print $1}')"
  [ "$before" = "$after" ]
}

@test "heartbeat state update accepts explicit timestamp argument" {
  local run_file
  run_file="$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"

  run graph_state_update_run_heartbeat "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "2026-08-12T02:00:00Z"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.heartbeatAt' "$run_file")" = "2026-08-12T02:00:00Z" ]
}

@test "heartbeat state update rejects terminal run heartbeat updates" {
  local run_file
  run_file="$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  graph_state_set_run_status "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "succeeded"
  [ "$(jq -r '.status' "$run_file")" = "succeeded" ]

  export GRAPH_STATE_HEARTBEAT_AT="2026-08-12T01:00:30Z"
  run graph_state_update_run_heartbeat "$WORKSPACE" "$NAMESPACE" "$RUN_ID"
  [ "$status" -ne 0 ]
  [[ "$output" = *"terminal run"* ]]
  [ "$(jq -r '.heartbeatAt' "$run_file")" != "2026-08-12T01:00:30Z" ]
}

@test "heartbeat state update running attempt heartbeat and idempotent repeat" {
  local nid="left"
  local aid="${nid}__${RUN_ID}__1"
  local node_file before after
  node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid")"

  graph_state_write_node "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "running" \
    "$aid" '{"startedAt":"2026-01-01T00:00:00Z","runtime":"cursor"}' >/dev/null

  export GRAPH_STATE_HEARTBEAT_AT="2026-01-01T00:00:15Z"
  run graph_state_update_attempt_heartbeat "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "$aid"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' "$node_file")" = "running" ]
  [ "$(jq -r '.attempts[0].heartbeatAt' "$node_file")" = "2026-01-01T00:00:15Z" ]

  before="$(shasum "$node_file" | awk '{print $1}')"
  run graph_state_update_attempt_heartbeat "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "$aid"
  [ "$status" -eq 0 ]
  after="$(shasum "$node_file" | awk '{print $1}')"
  [ "$before" = "$after" ]
}

@test "heartbeat state update accepts explicit attempt timestamp argument" {
  local nid="left"
  local aid="${nid}__${RUN_ID}__1"
  local node_file
  node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid")"

  graph_state_write_node "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "running" \
    "$aid" '{"startedAt":"2026-01-01T00:00:00Z"}' >/dev/null

  run graph_state_update_attempt_heartbeat "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "$aid" "2026-01-01T00:00:45Z"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.attempts[0].heartbeatAt' "$node_file")" = "2026-01-01T00:00:45Z" ]
}

@test "heartbeat state update rejects terminal attempt heartbeat updates" {
  local nid="left"
  local aid="${nid}__${RUN_ID}__1"
  local node_file
  node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid")"

  graph_state_write_node "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "running" \
    "$aid" '{"startedAt":"2026-01-01T00:00:00Z","outcome":"succeeded","exitCode":0,"finishedAt":"2026-01-01T00:01:00Z"}' >/dev/null

  export GRAPH_STATE_HEARTBEAT_AT="2026-01-01T00:00:15Z"
  run graph_state_update_attempt_heartbeat "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "$aid"
  [ "$status" -ne 0 ]
  [[ "$output" = *"terminal attempt"* ]]
  [ "$(jq -r '.attempts[0].heartbeatAt' "$node_file")" != "2026-01-01T00:00:15Z" ]
}

@test "heartbeat state update rejects attempt heartbeat when node is not running" {
  local nid="left"
  local aid="${nid}__${RUN_ID}__1"
  local node_file
  node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid")"

  graph_state_write_node "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "running" \
    "$aid" '{"startedAt":"2026-01-01T00:00:00Z"}' >/dev/null
  graph_state_write_node "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "succeeded" \
    "$aid" '{"outcome":"succeeded","exitCode":0,"finishedAt":"2026-01-01T00:01:00Z"}' >/dev/null

  export GRAPH_STATE_HEARTBEAT_AT="2026-01-01T00:00:15Z"
  run graph_state_update_attempt_heartbeat "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "$aid"
  [ "$status" -ne 0 ]
  [[ "$output" = *"not running"* ]]
  [ "$(jq -r '.attempts[0].heartbeatAt' "$node_file")" != "2026-01-01T00:00:15Z" ]
}

@test "heartbeat state update rejects heartbeat for missing attempt" {
  local nid="left"
  local aid="${nid}__${RUN_ID}__1"
  local node_file
  node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid")"

  graph_state_write_node "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "running" \
    "$aid" '{"startedAt":"2026-01-01T00:00:00Z"}' >/dev/null

  export GRAPH_STATE_HEARTBEAT_AT="2026-01-01T00:00:15Z"
  run graph_state_update_attempt_heartbeat "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "${nid}__${RUN_ID}__9"
  [ "$status" -ne 0 ]
  [[ "$output" = *"not found"* ]]
}

@test "heartbeat scheduler tick refreshes run and running attempt after interval" {
  local run_file node_file nid aid idx run_before run_after node_before node_after

  run_file="$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  nid="left"
  aid="${nid}__${RUN_ID}__1"
  node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid")"

  graph_schedule_load_index "$GRAPH_JSON"

  graph_state_write_node "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "running" \
    "$aid" '{"startedAt":"2026-01-01T00:00:00Z","runtime":"cursor"}' >/dev/null

  idx="$(graph_schedule_index_map_get "$nid")"
  GRAPH_NODE_STATES[$idx]="running"

  GRAPH_SCHEDULE_WORKSPACE="$WORKSPACE"
  GRAPH_SCHEDULE_NAMESPACE="$NAMESPACE"
  GRAPH_SCHEDULE_RUN_ID="$RUN_ID"

  export GRAPH_HEARTBEAT_INTERVAL_SECONDS=2
  GRAPH_HEARTBEAT_LAST_TICK_EPOCH=0

  export GRAPH_HEARTBEAT_NOW_EPOCH=1000
  export GRAPH_STATE_HEARTBEAT_AT="2026-01-01T00:00:00Z"
  graph_schedule_tick_heartbeat
  [ "$?" -eq 0 ]
  [ "$(jq -r '.heartbeatAt' "$run_file")" = "2026-01-01T00:00:00Z" ]
  [ "$(jq -r '.attempts[0].heartbeatAt' "$node_file")" = "2026-01-01T00:00:00Z" ]

  run_before="$(shasum "$run_file" | awk '{print $1}')"
  node_before="$(shasum "$node_file" | awk '{print $1}')"
  export GRAPH_HEARTBEAT_NOW_EPOCH=1001
  export GRAPH_STATE_HEARTBEAT_AT="2026-01-01T00:00:01Z"
  graph_schedule_tick_heartbeat
  [ "$?" -eq 0 ]
  run_after="$(shasum "$run_file" | awk '{print $1}')"
  node_after="$(shasum "$node_file" | awk '{print $1}')"
  [ "$run_before" = "$run_after" ]
  [ "$node_before" = "$node_after" ]

  export GRAPH_HEARTBEAT_NOW_EPOCH=1002
  export GRAPH_STATE_HEARTBEAT_AT="2026-01-01T00:00:02Z"
  graph_schedule_tick_heartbeat
  [ "$?" -eq 0 ]
  [ "$(jq -r '.heartbeatAt' "$run_file")" = "2026-01-01T00:00:02Z" ]
  [ "$(jq -r '.attempts[0].heartbeatAt' "$node_file")" = "2026-01-01T00:00:02Z" ]
}

@test "heartbeat status default shows concise owner-health field" {
  local run_file
  run_file="$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"

  # Ensure the heartbeat is fresh so the classifier returns healthy.
  set_run_json_field "$run_file" "heartbeatAt" "2026-08-12T00:00:00Z"
  export GRAPH_HEARTBEAT_NOW_EPOCH="$(graph_heartbeat_parse_iso_to_epoch "2026-08-12T00:00:00Z")"

  run graph_status_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'owner-health=healthy'
}

@test "heartbeat status default shows unknown when heartbeat is missing" {
  local run_file
  run_file="$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  set_run_json_null "$run_file" "heartbeatAt"

  run graph_status_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'owner-health=unknown'
}

@test "heartbeat status json includes structured owner health fields" {
  local run_file
  run_file="$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"

  set_run_json_field "$run_file" "heartbeatAt" "2026-08-12T00:00:00Z"
  export GRAPH_HEARTBEAT_NOW_EPOCH="$(graph_heartbeat_parse_iso_to_epoch "2026-08-12T00:00:00Z")"

  run graph_status_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID" --json
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  printf '%s\n' "$output" | jq -e '.ownerHealth == "healthy"' >/dev/null
  printf '%s\n' "$output" | jq -e '.runId == "run-hb-001"' >/dev/null
  printf '%s\n' "$output" | jq -e '.namespace == "heartbeat-ns"' >/dev/null
  printf '%s\n' "$output" | jq -e '.status == "running"' >/dev/null
  printf '%s\n' "$output" | jq -e '(.nodes | type) == "array"' >/dev/null
  printf '%s\n' "$output" | jq -e '(.concurrencyReductions | type) == "array"' >/dev/null
}

@test "heartbeat status json shows unknown when liveness cannot be proved" {
  local run_file
  run_file="$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  set_run_json_null "$run_file" "heartbeatAt"

  run graph_status_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID" --json
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.ownerHealth == "unknown"' >/dev/null
}

@test "heartbeat status read-only classifier does not repair state" {
  local run_file before after
  run_file="$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  set_run_json_null "$run_file" "heartbeatAt"

  before="$(shasum "$run_file" | awk '{print $1}')"
  run graph_status_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID"
  [ "$status" -eq 0 ]
  after="$(shasum "$run_file" | awk '{print $1}')"
  [ "$before" = "$after" ]
  printf '%s\n' "$output" | grep -q 'owner-health=unknown'
}

@test "heartbeat status read-only json does not repair state" {
  local run_file before after
  run_file="$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  set_run_json_null "$run_file" "heartbeatAt"

  before="$(shasum "$run_file" | awk '{print $1}')"
  run graph_status_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID" --json
  [ "$status" -eq 0 ]
  after="$(shasum "$run_file" | awk '{print $1}')"
  [ "$before" = "$after" ]
  printf '%s\n' "$output" | jq -e '.ownerHealth == "unknown"' >/dev/null
}
