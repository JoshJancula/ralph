#!/usr/bin/env bats
# Tests for graph recovery helpers: interrupting orphaned running attempts,
# preserving attempt fields, and appending events.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/plan-todo.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/atomic-json.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-state.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-logs.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-events.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-heartbeat.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-recovery.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-schedule.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-status.sh"

DIAMOND_PLAN="$BATS_TEST_DIRNAME/../../fixtures/graph/graph-diamond.plan.md"
STUB_RUN_PLAN="$BATS_TEST_DIRNAME/../../fixtures/orchestrator-single-stage/run-plan-stub.sh"
RALPH_DIR="$REPO_ROOT/bundle/.ralph"
GRAPH_RUN_SH="$REPO_ROOT/bundle/.ralph/graph-run.sh"

compile_graph() {
  local src_plan="$1" workspace="$2" out_path="$3"
  local plan_file="$workspace/$(basename "$src_plan")"
  cp "$src_plan" "$plan_file"
  plan_pipeline_graph_json "$plan_file" > "$out_path"
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

mark_run_stale() {
  local run_file
  run_file="$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  set_run_json_field "$run_file" "heartbeatAt" "2026-08-12T00:00:00Z"
  set_run_json_field "$run_file" "supervisorPid" "99999"
  set_run_json_field "$run_file" "ownerProcessStartId" "old-start"
}

run_stale_recovery() {
  GRAPH_HEARTBEAT_TTL_SECONDS=1 GRAPH_HEARTBEAT_NOW_EPOCH=1999999999 \
    graph_recovery_attempt_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID"
}

recover_cmd() {
  bash "$GRAPH_RUN_SH" recover "$@" --workspace "$WORKSPACE"
}

ledger_snapshot() {
  local runs_dir
  runs_dir="$(graph_state_runs_root "$WORKSPACE")"
  find "$runs_dir" -type f | sort | while IFS= read -r f; do
    printf '%s %s\n' "$(shasum "$f" | awk '{print $1}')" "$f"
  done
}

# Install stub run-plan and a per-stage behavior orchestrator so resume tests
# never invoke a live/paid runtime.
install_stub_runtimes() {
  local behavior_dir="$1" marker_dir="$2"
  mkdir -p "$WORKSPACE/.ralph" "$WORKSPACE/.ralph-workspace" "$behavior_dir" "$marker_dir"
  cp -R "$RALPH_DIR"/* "$WORKSPACE/.ralph/"
  chmod +x "$WORKSPACE/.ralph"/*.sh 2>/dev/null || true
  chmod +x "$WORKSPACE/.ralph/bash-lib"/*/*.sh 2>/dev/null || true
  cp "$STUB_RUN_PLAN" "$WORKSPACE/.ralph/run-plan.sh"
  chmod +x "$WORKSPACE/.ralph/run-plan.sh"

  cat >"$WORKSPACE/.ralph/orchestrator.sh" <<EOF
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
ns="$NAMESPACE"
run_id="$RUN_ID"
behavior_dir="$behavior_dir"
marker_dir="$marker_dir"
report="\$workspace/.ralph-workspace/artifacts/\$ns/stage-outcomes/\${attempt}.json"
mkdir -p "\$(dirname "\$report")" "\$marker_dir"
printf '%s\\n' "\$\$" >"\$marker_dir/\$stage.pid"
: >"\$marker_dir/\$stage.started"
write_report() {
  local outcome="\$1" exit_code="\$2"
  printf '%s\\n' "{\"schemaVersion\":1,\"runId\":\"\$run_id\",\"stageId\":\"\$stage\",\"attemptId\":\"\$attempt\",\"outcome\":\"\$outcome\",\"exitCode\":\$exit_code,\"startedAt\":\"2026-01-01T00:00:00Z\",\"finishedAt\":\"2026-01-01T00:00:01Z\"}" >"\$report"
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
  *)
    write_report success 0
    : >"\$marker_dir/\$stage.finished"
    exit 0
    ;;
esac
EOF
  chmod +x "$WORKSPACE/.ralph/orchestrator.sh"
  export GRAPH_DISPATCH_ORCHESTRATOR="$WORKSPACE/.ralph/orchestrator.sh"
  export RALPH_ALLOW_NESTED_RUNS=1
  export ORCHESTRATOR_RUNNER_TO_CONSOLE=0
  export RALPH_MODE=no
  export RALPH_ARTIFACT_SCHEMA_VALIDATION=0
  export RALPH_ARTIFACT_PROVENANCE=0
}

setup() {
  TMPD="$(mktemp -d)"
  WORKSPACE="$TMPD/ws"
  mkdir -p "$WORKSPACE"
  NAMESPACE="recovery-ns"
  RUN_ID="run-recovery-001"
  GRAPH_JSON="$TMPD/graph.json"
  compile_graph "$DIAMOND_PLAN" "$WORKSPACE" "$GRAPH_JSON"
  PLAN_FILE="$WORKSPACE/$(basename "$DIAMOND_PLAN")"
  graph_state_init_run_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$PLAN_FILE" "$GRAPH_JSON" 2 >/dev/null
  export GRAPH_RECOVERY_INTERRUPT_AT="2026-08-12T00:00:00Z"
}

teardown() {
  unset RALPH_GRAPH_FOLLOW_INTERVAL RALPH_GRAPH_FOLLOW_MAX_POLLS 2>/dev/null || true
  rm -rf "$TMPD"
}

@test "recovery interrupt attempt terminalizes running attempt as interrupted and preserves logs and usage" {
  local nid="left"
  local aid="${nid}__${RUN_ID}__1"
  local node_file run_dir log_dir
  node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid")"
  run_dir="$(graph_state_run_dir "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  log_dir="$run_dir/logs/nodes/$nid/$aid"

  mkdir -p "$log_dir"
  printf 'runner log line\n' > "$log_dir/runner.log"
  printf 'agent log line\n' > "$log_dir/agent.log"
  printf '{"input_tokens":7,"output_tokens":3}\n' > "$log_dir/usage.json"

  graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "running" \
    "$aid" "{\"startedAt\":\"2026-01-01T00:00:00Z\",\"runtime\":\"cursor\",\"logPaths\":{\"runner\":\"logs/nodes/$nid/$aid/runner.log\",\"agent\":\"logs/nodes/$nid/$aid/agent.log\",\"usage\":\"logs/nodes/$nid/$aid/usage.json\"},\"usageSnapshot\":{\"input_tokens\":7},\"usageReliable\":true}"

  run graph_recovery_interrupt_attempt "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "$aid"
  [ "$status" -eq 0 ]

  [ "$(jq -r '.status' "$node_file")" = "interrupted" ]
  [ "$(jq -r '.attempts[0].attemptId' "$node_file")" = "$aid" ]
  [ "$(jq -r '.attempts[0].outcome' "$node_file")" = "interrupted" ]
  [ "$(jq -r '.attempts[0].finishedAt' "$node_file")" = "2026-08-12T00:00:00Z" ]
  [ "$(jq -r '.attempts[0].startedAt' "$node_file")" = "2026-01-01T00:00:00Z" ]
  [ "$(jq -r '.attempts[0].runtime' "$node_file")" = "cursor" ]
  [ "$(jq -r '.attempts[0].logPaths.runner' "$node_file")" = "logs/nodes/$nid/$aid/runner.log" ]
  [ "$(jq -r '.attempts[0].usageSnapshot.input_tokens' "$node_file")" -eq 7 ]
  [ "$(jq -r '.attempts[0].usageReliable' "$node_file")" = "true" ]

  [ -f "$log_dir/runner.log" ]
  [ -f "$log_dir/agent.log" ]
  [ -f "$log_dir/usage.json" ]
  [ "$(cat "$log_dir/usage.json")" = '{"input_tokens":7,"output_tokens":3}' ]

  [ -f "$run_dir/events.jsonl" ]
  [ "$(jq -r 'select(.event == "node-interrupted") | .nodeId' "$run_dir/events.jsonl")" = "$nid" ]
  [ "$(jq -r 'select(.event == "node-interrupted") | .attemptId' "$run_dir/events.jsonl")" = "$aid" ]
  [ "$(jq -r 'select(.event == "node-interrupted") | .details.attemptId' "$run_dir/events.jsonl")" = "$aid" ]
  [ "$(jq -r 'select(.event == "node-interrupted") | .details.finishedAt' "$run_dir/events.jsonl")" = "2026-08-12T00:00:00Z" ]
}

@test "recovery interrupt attempt is idempotent" {
  local nid="left"
  local aid="${nid}__${RUN_ID}__1"
  local node_file run_dir before after event_count_before event_count_after
  node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid")"
  run_dir="$(graph_state_run_dir "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"

  graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "running" \
    "$aid" '{"startedAt":"2026-01-01T00:00:00Z","runtime":"cursor"}'

  run graph_recovery_interrupt_attempt "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "$aid"
  [ "$status" -eq 0 ]
  before="$(jq -c . "$node_file")"
  event_count_before="$(jq -c 'select(.event == "node-interrupted")' "$run_dir/events.jsonl" 2>/dev/null | wc -l | tr -d ' ')"

  run graph_recovery_interrupt_attempt "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "$aid"
  [ "$status" -eq 0 ]
  after="$(jq -c . "$node_file")"
  event_count_after="$(jq -c 'select(.event == "node-interrupted")' "$run_dir/events.jsonl" 2>/dev/null | wc -l | tr -d ' ')"

  [ "$before" = "$after" ]
  [ "$event_count_before" -eq "$event_count_after" ]
  [ "$event_count_before" -eq 1 ]
}

@test "recovery interrupt attempt rejects non-running node" {
  local nid="left"
  local aid="${nid}__${RUN_ID}__1"
  local node_file
  node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid")"

  graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "pending"

  run graph_recovery_interrupt_attempt "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "$aid"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not running"* ]]
  [ "$(jq -r '.status' "$node_file")" = "pending" ]
}

@test "recovery interrupt attempt appends event with reason" {
  local nid="left"
  local aid="${nid}__${RUN_ID}__1"
  local run_dir
  run_dir="$(graph_state_run_dir "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"

  graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "running" \
    "$aid" '{"startedAt":"2026-01-01T00:00:00Z","runtime":"cursor"}'

  run graph_recovery_interrupt_attempt "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "$aid" "supervisor died"
  [ "$status" -eq 0 ]

  [ -f "$run_dir/events.jsonl" ]
  [ "$(jq -r 'select(.event == "node-interrupted") | .details.reason' "$run_dir/events.jsonl")" = "supervisor died" ]
}

@test "recovery interrupt attempt rejects missing attempt on running node" {
  local nid="left"
  local aid="${nid}__${RUN_ID}__1"
  local node_file
  node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid")"

  graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "running" \
    "$aid" '{"startedAt":"2026-01-01T00:00:00Z","runtime":"cursor"}'

  run graph_recovery_interrupt_attempt "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "${nid}__${RUN_ID}__9"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
  [ "$(jq -r '.status' "$node_file")" = "running" ]
}

@test "recovery lock acquires and interrupts running attempts for stale run" {
  local nid="left"
  local aid="${nid}__${RUN_ID}__1"
  local run_file node_file run_dir
  run_file="$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid")"
  run_dir="$(graph_state_run_dir "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"

  set_run_json_field "$run_file" "heartbeatAt" "2026-08-12T00:00:00Z"
  set_run_json_field "$run_file" "supervisorPid" "99999"
  set_run_json_field "$run_file" "ownerProcessStartId" "old-start"

  graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "running" \
    "$aid" '{"startedAt":"2026-01-01T00:00:00Z","runtime":"cursor"}'

  GRAPH_HEARTBEAT_TTL_SECONDS=1 GRAPH_HEARTBEAT_NOW_EPOCH=1999999999 \
    run graph_recovery_attempt_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID"
  [ "$status" -eq 0 ]

  [ "$(jq -r '.status' "$node_file")" = "pending" ]
  [ "$(jq -r '.attempts[0].outcome' "$node_file")" = "interrupted" ]
  [ -f "$run_dir/events.jsonl" ]
  [ "$(jq -r 'select(.event == "node-interrupted") | .nodeId' "$run_dir/events.jsonl")" = "$nid" ]
}

@test "recovery lock refuses healthy run" {
  local run_file heartbeat_epoch
  run_file="$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  set_run_json_field "$run_file" "heartbeatAt" "2026-08-12T00:00:00Z"
  heartbeat_epoch="$(graph_heartbeat_parse_iso_to_epoch "2026-08-12T00:00:00Z")"

  GRAPH_HEARTBEAT_TTL_SECONDS=60 GRAPH_HEARTBEAT_NOW_EPOCH="$heartbeat_epoch" \
    run graph_recovery_attempt_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID"
  [ "$status" -ne 0 ]
  [[ "$output" == *"refused: run is healthy"* ]]
}

@test "recovery lock refuses unknown run" {
  local run_file
  run_file="$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  set_run_json_null "$run_file" "heartbeatAt"

  run graph_recovery_attempt_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID"
  [ "$status" -ne 0 ]
  [[ "$output" == *"refused: run liveness is unknown"* ]]
}

@test "recovery lock refuses published run" {
  local run_file
  run_file="$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  set_run_json_field "$run_file" "status" "published"
  set_run_json_field "$run_file" "heartbeatAt" "2026-08-12T00:00:00Z"
  set_run_json_field "$run_file" "supervisorPid" "99999"
  set_run_json_field "$run_file" "ownerProcessStartId" "old-start"

  GRAPH_HEARTBEAT_TTL_SECONDS=1 GRAPH_HEARTBEAT_NOW_EPOCH=1999999999 \
    run graph_recovery_attempt_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID"
  [ "$status" -ne 0 ]
  [[ "$output" == *"refused: run is terminal (published)"* ]]
}

@test "recovery lock refuses terminal run" {
  local run_file
  run_file="$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  graph_state_set_run_status "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "succeeded"
  set_run_json_field "$run_file" "heartbeatAt" "2026-08-12T00:00:00Z"
  set_run_json_field "$run_file" "supervisorPid" "99999"
  set_run_json_field "$run_file" "ownerProcessStartId" "old-start"

  GRAPH_HEARTBEAT_TTL_SECONDS=1 GRAPH_HEARTBEAT_NOW_EPOCH=1999999999 \
    run graph_recovery_attempt_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID"
  [ "$status" -ne 0 ]
  [[ "$output" == *"refused: run is terminal (succeeded)"* ]]
}

@test "recovery lock concurrent recoverers yield exactly one mutation" {
  local nid="left"
  local aid="${nid}__${RUN_ID}__1"
  local run_file node_file run_dir
  run_file="$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid")"
  run_dir="$(graph_state_run_dir "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"

  set_run_json_field "$run_file" "heartbeatAt" "2026-08-12T00:00:00Z"
  set_run_json_field "$run_file" "supervisorPid" "99999"
  set_run_json_field "$run_file" "ownerProcessStartId" "old-start"

  graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "running" \
    "$aid" '{"startedAt":"2026-01-01T00:00:00Z","runtime":"cursor"}'

  local out1 rc1 out2 rc2
  out1="$TMPD/out1.txt"
  rc1="$TMPD/rc1.txt"
  out2="$TMPD/out2.txt"
  rc2="$TMPD/rc2.txt"

  # Group each attempt (env + call + exit-code capture) so the whole unit
  # backgrounds together. "cmd; echo $? >rc &" only backgrounds the trailing
  # echo -- cmd still runs in the foreground -- so both recoverers would run
  # sequentially instead of racing, and bats' errexit would abort the test
  # the moment the second (now-legitimately-refused) call returned nonzero.
  # set +e inside each subshell: one of the two racing recoverers is
  # expected to be legitimately refused (see the assertion below), and
  # bats runs test bodies under errexit, so a bare nonzero from
  # graph_recovery_attempt_run would abort the subshell before it ever
  # records the real exit code.
  (
    set +e
    GRAPH_HEARTBEAT_TTL_SECONDS=1 GRAPH_HEARTBEAT_NOW_EPOCH=1999999999 \
      graph_recovery_attempt_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID" >"$out1" 2>&1
    echo $? >"$rc1"
  ) &
  local pid1=$!
  (
    set +e
    GRAPH_HEARTBEAT_TTL_SECONDS=1 GRAPH_HEARTBEAT_NOW_EPOCH=1999999999 \
      graph_recovery_attempt_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID" >"$out2" 2>&1
    echo $? >"$rc2"
  ) &
  local pid2=$!
  wait "$pid1" "$pid2" || true

  rc1="$(cat "$rc1")"
  rc2="$(cat "$rc2")"

  # At least one recoverer succeeded; the other either succeeded as a no-op
  # or was refused at the lock.
  local successes=0
  [[ "$rc1" -eq 0 ]] && successes=$((successes + 1))
  [[ "$rc2" -eq 0 ]] && successes=$((successes + 1))
  [ "$successes" -ge 1 ]

  # Exactly one mutation: one node-interrupted event for the single running node.
  local event_count
  event_count="$(jq -c 'select(.event == "node-interrupted")' "$run_dir/events.jsonl" 2>/dev/null | wc -l | tr -d ' ')"
  [ "$event_count" -eq 1 ]

  [ "$(jq -r '.status' "$node_file")" = "pending" ]
}

@test "recovery reset eligibility resets only interrupted nodes to pending" {
  local run_dir source_file left_file right_file sink_file repair_file
  local left_aid source_aid sink_aid
  run_dir="$(graph_state_run_dir "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  source_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "source")"
  left_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "left")"
  right_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "right")"
  sink_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "sink")"
  left_aid="left__${RUN_ID}__1"
  source_aid="source__${RUN_ID}__1"
  sink_aid="sink__${RUN_ID}__1"

  mark_run_stale

  graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "source" "running" \
    "$source_aid" '{"startedAt":"2026-01-01T00:00:00Z","runtime":"cursor"}'
  graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "source" "succeeded" \
    "$source_aid" '{"outcome":"succeeded","finishedAt":"2026-01-01T00:01:00Z"}'

  graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "left" "running" \
    "$left_aid" '{"startedAt":"2026-01-01T00:00:00Z","runtime":"cursor"}'

  graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "right" "skipped"

  graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "sink" "running" \
    "$sink_aid" '{"startedAt":"2026-01-01T00:00:00Z","runtime":"cursor"}'
  graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "sink" "awaiting-operator" \
    "$sink_aid" '{"outcome":"awaiting-operator"}'

  graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "repair" "needs-plan-repair"
  repair_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "repair")"

  GRAPH_HEARTBEAT_TTL_SECONDS=1 GRAPH_HEARTBEAT_NOW_EPOCH=1999999999 \
    run run_stale_recovery
  [ "$status" -eq 0 ]

  [ "$(jq -r '.status' "$left_file")" = "pending" ]
  [ "$(jq -r '.attempts[0].outcome' "$left_file")" = "interrupted" ]
  [ "$(jq -r '.status' "$source_file")" = "succeeded" ]
  [ "$(jq -r '.attempts[0].outcome' "$source_file")" = "succeeded" ]
  [ "$(jq -r '.status' "$right_file")" = "skipped" ]
  [ "$(jq -r '.status' "$sink_file")" = "awaiting-operator" ]
  [ "$(jq -r '.status' "$repair_file")" = "needs-plan-repair" ]
}

@test "recovery reset eligibility preserves succeeded skipped awaiting-operator and needs-plan-repair" {
  local run_dir source_file right_file sink_file repair_file
  local source_aid sink_aid
  run_dir="$(graph_state_run_dir "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  source_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "source")"
  right_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "right")"
  sink_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "sink")"
  source_aid="source__${RUN_ID}__1"
  sink_aid="sink__${RUN_ID}__1"

  mark_run_stale

  graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "source" "running" \
    "$source_aid" '{"startedAt":"2026-01-01T00:00:00Z","runtime":"cursor"}'
  graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "source" "succeeded" \
    "$source_aid" '{"outcome":"succeeded","finishedAt":"2026-01-01T00:01:00Z"}'
  graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "right" "skipped"
  graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "sink" "running" \
    "$sink_aid" '{"startedAt":"2026-01-01T00:00:00Z","runtime":"cursor"}'
  graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "sink" "awaiting-operator" \
    "$sink_aid" '{"outcome":"awaiting-operator"}'
  graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "repair" "needs-plan-repair"
  repair_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "repair")"

  local before_source before_right before_sink before_repair
  before_source="$(jq -c . "$source_file")"
  before_right="$(jq -c . "$right_file")"
  before_sink="$(jq -c . "$sink_file")"
  before_repair="$(jq -c . "$repair_file")"

  GRAPH_HEARTBEAT_TTL_SECONDS=1 GRAPH_HEARTBEAT_NOW_EPOCH=1999999999 \
    run run_stale_recovery
  [ "$status" -eq 0 ]

  [ "$(jq -c . "$source_file")" = "$before_source" ]
  [ "$(jq -c . "$right_file")" = "$before_right" ]
  [ "$(jq -c . "$sink_file")" = "$before_sink" ]
  [ "$(jq -c . "$repair_file")" = "$before_repair" ]

  local recovered_count
  recovered_count="$(jq -c 'select(.event == "node-recovered")' "$run_dir/events.jsonl" 2>/dev/null | wc -l | tr -d ' ')"
  [ "$recovered_count" -eq 0 ]
}

@test "recovery reset eligibility emits recovery start finish and per-node events" {
  local run_dir left_file
  local left_aid
  run_dir="$(graph_state_run_dir "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  left_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "left")"
  left_aid="left__${RUN_ID}__1"

  mark_run_stale
  graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "left" "running" \
    "$left_aid" '{"startedAt":"2026-01-01T00:00:00Z","runtime":"cursor"}'

  GRAPH_HEARTBEAT_TTL_SECONDS=1 GRAPH_HEARTBEAT_NOW_EPOCH=1999999999 \
    run run_stale_recovery
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' "$left_file")" = "pending" ]

  [ -f "$run_dir/events.jsonl" ]
  local events
  events="$(jq -r '.event' "$run_dir/events.jsonl" | tr '\n' ',')"
  [ "$events" = "recovery-start,node-interrupted,node-recovered,recovery-finish," ]

  [ "$(jq -r 'select(.event == "recovery-start") | .runId' "$run_dir/events.jsonl")" = "$RUN_ID" ]
  [ "$(jq -r 'select(.event == "node-interrupted") | .nodeId' "$run_dir/events.jsonl")" = "left" ]
  [ "$(jq -r 'select(.event == "node-recovered") | .nodeId' "$run_dir/events.jsonl")" = "left" ]
  [ "$(jq -r 'select(.event == "node-recovered") | .attemptId' "$run_dir/events.jsonl")" = "$left_aid" ]
  [ "$(jq -r 'select(.event == "node-recovered") | .details.from' "$run_dir/events.jsonl")" = "interrupted" ]
  [ "$(jq -r 'select(.event == "node-recovered") | .details.to' "$run_dir/events.jsonl")" = "pending" ]
  [ "$(jq -r 'select(.event == "recovery-finish") | .details.interruptedAttempts' "$run_dir/events.jsonl")" = "1" ]
  [ "$(jq -r 'select(.event == "recovery-finish") | .details.nodesReset' "$run_dir/events.jsonl")" = "1" ]
}

@test "recovery reset eligibility resets an already-interrupted node without a second interrupt" {
  local run_dir left_file
  local left_aid
  run_dir="$(graph_state_run_dir "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  left_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "left")"
  left_aid="left__${RUN_ID}__1"

  graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "left" "running" \
    "$left_aid" '{"startedAt":"2026-01-01T00:00:00Z","runtime":"cursor"}'
  graph_recovery_interrupt_attempt "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "left" "$left_aid" "pre-recovery interrupt"
  [ "$(jq -r '.status' "$left_file")" = "interrupted" ]

  mark_run_stale
  GRAPH_HEARTBEAT_TTL_SECONDS=1 GRAPH_HEARTBEAT_NOW_EPOCH=1999999999 \
    run run_stale_recovery
  [ "$status" -eq 0 ]

  [ "$(jq -r '.status' "$left_file")" = "pending" ]
  [ "$(jq -r '.attempts[0].outcome' "$left_file")" = "interrupted" ]

  local interrupt_count recovered_count
  interrupt_count="$(jq -c 'select(.event == "node-interrupted")' "$run_dir/events.jsonl" | wc -l | tr -d ' ')"
  recovered_count="$(jq -c 'select(.event == "node-recovered")' "$run_dir/events.jsonl" | wc -l | tr -d ' ')"
  [ "$interrupt_count" -eq 1 ]
  [ "$recovered_count" -eq 1 ]
}

@test "recovery resume accepts a run the explicit helper returned to a resumable status" {
  local run_file left_file run_dir left_aid behavior_dir marker_dir
  local recovery_starts_before recovery_starts_after rc
  behavior_dir="$TMPD/behavior"
  marker_dir="$TMPD/markers"

  compile_graph "$DIAMOND_PLAN" "$WORKSPACE" "$GRAPH_JSON"
  NAMESPACE="$(jq -r '.namespace // "recovery-ns"' "$GRAPH_JSON")"
  PLAN_FILE="$WORKSPACE/$(basename "$DIAMOND_PLAN")"

  # Install stubs before the frozen compile so resume's recompile matches.
  install_stub_runtimes "$behavior_dir" "$marker_dir"
  printf '%s\n' "success" >"$behavior_dir/source"
  printf '%s\n' "success" >"$behavior_dir/left"
  printf '%s\n' "success" >"$behavior_dir/right"
  printf '%s\n' "success" >"$behavior_dir/sink"
  compile_graph "$DIAMOND_PLAN" "$WORKSPACE" "$GRAPH_JSON"
  graph_state_init_run_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$PLAN_FILE" "$GRAPH_JSON" 2 >/dev/null

  run_file="$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  left_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "left")"
  run_dir="$(graph_state_run_dir "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  left_aid="left__${RUN_ID}__1"

  mark_run_stale
  graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "left" "running" \
    "$left_aid" '{"startedAt":"2026-01-01T00:00:00Z","runtime":"cursor"}'

  GRAPH_HEARTBEAT_TTL_SECONDS=1 GRAPH_HEARTBEAT_NOW_EPOCH=1999999999 \
    run run_stale_recovery
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' "$left_file")" = "pending" ]
  [ "$(jq -r '.status' "$run_file")" = "interrupted" ]
  graph_schedule_run_status_is_resumable "$(jq -r '.status' "$run_file")"

  recovery_starts_before="$(jq -c 'select(.event == "recovery-start")' "$run_dir/events.jsonl" 2>/dev/null | wc -l | tr -d ' ')"
  [ "$recovery_starts_before" -eq 1 ]

  rc=0
  GRAPH_REAP_POLL_INTERVAL=0.1 \
    graph_schedule_resume "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$PLAN_FILE" || rc=$?
  [ "$rc" -eq 0 ]
  [ "$(graph_schedule_node_state_by_id source)" = "succeeded" ]
  [ "$(graph_schedule_node_state_by_id left)" = "succeeded" ]
  [ "$(graph_schedule_node_state_by_id right)" = "succeeded" ]
  [ "$(graph_schedule_node_state_by_id sink)" = "succeeded" ]
  [ "$(jq -r '.status' "$run_file")" = "succeeded" ]
  [ -f "$marker_dir/left.finished" ]
  [ -f "$marker_dir/sink.finished" ]

  recovery_starts_after="$(jq -c 'select(.event == "recovery-start")' "$run_dir/events.jsonl" 2>/dev/null | wc -l | tr -d ' ')"
  [ "$recovery_starts_after" -eq "$recovery_starts_before" ]
}

@test "recovery resume status does not invoke recovery implicitly" {
  local run_file left_file run_dir left_aid runs_dir before_snapshot after_snapshot
  run_file="$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  left_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "left")"
  run_dir="$(graph_state_run_dir "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  runs_dir="$(graph_state_runs_root "$WORKSPACE")"
  left_aid="left__${RUN_ID}__1"

  mark_run_stale
  graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "left" "running" \
    "$left_aid" '{"startedAt":"2026-01-01T00:00:00Z","runtime":"cursor"}'

  before_snapshot="$(find "$runs_dir" -type f | sort | while IFS= read -r f; do
    printf '%s %s\n' "$(shasum "$f" | awk '{print $1}')" "$f"
  done)"

  run graph_status_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID"
  [ "$status" -eq 0 ]

  after_snapshot="$(find "$runs_dir" -type f | sort | while IFS= read -r f; do
    printf '%s %s\n' "$(shasum "$f" | awk '{print $1}')" "$f"
  done)"
  [ "$before_snapshot" = "$after_snapshot" ]

  [ "$(jq -r '.status' "$left_file")" = "running" ]
  [ "$(jq -r '.status' "$run_file")" = "running" ]
  [ ! -f "$run_dir/events.jsonl" ] || {
    local recovery_events
    recovery_events="$(jq -c 'select(.event == "recovery-start" or .event == "node-interrupted" or .event == "node-recovered" or .event == "recovery-finish")' "$run_dir/events.jsonl" 2>/dev/null | wc -l | tr -d ' ')"
    [ "$recovery_events" -eq 0 ]
  }
}

@test "recovery resume refuses a published run" {
  local run_file
  run_file="$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  set_run_json_field "$run_file" "status" "published"

  run graph_schedule_resume "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$PLAN_FILE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot resume"* ]]
  [[ "$output" == *"published"* ]]
  [ "$(jq -r '.status' "$run_file")" = "published" ]
}

@test "recovery cli --help exits 0" {
  run bash "$GRAPH_RUN_SH" recover --help
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q -- '--namespace'
  printf '%s\n' "$output" | grep -q -- '--run'
  run bash "$GRAPH_RUN_SH" --help
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q -- 'recover'
}

@test "recovery cli errors without --namespace" {
  run recover_cmd --run "$RUN_ID"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'namespace'
}

@test "recovery cli errors without --run" {
  run recover_cmd --namespace "$NAMESPACE"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'run'
}

@test "recovery cli recovers a stale run" {
  local nid="left"
  local aid="${nid}__${RUN_ID}__1"
  local node_file run_file run_dir
  node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid")"
  run_file="$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  run_dir="$(graph_state_run_dir "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"

  mark_run_stale
  graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" "running" \
    "$aid" '{"startedAt":"2026-01-01T00:00:00Z","runtime":"cursor"}'

  GRAPH_HEARTBEAT_TTL_SECONDS=1 GRAPH_HEARTBEAT_NOW_EPOCH=1999999999 \
    run recover_cmd --namespace "$NAMESPACE" --run "$RUN_ID"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' "$node_file")" = "pending" ]
  [ "$(jq -r '.attempts[0].outcome' "$node_file")" = "interrupted" ]
  [ "$(jq -r '.status' "$run_file")" = "interrupted" ]
  [ "$(jq -r 'select(.event == "recovery-start") | .runId' "$run_dir/events.jsonl")" = "$RUN_ID" ]
}

@test "recovery cli prints refusal for a healthy run" {
  local run_file heartbeat_epoch
  run_file="$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  set_run_json_field "$run_file" "heartbeatAt" "2026-08-12T00:00:00Z"
  heartbeat_epoch="$(graph_heartbeat_parse_iso_to_epoch "2026-08-12T00:00:00Z")"

  GRAPH_HEARTBEAT_TTL_SECONDS=60 GRAPH_HEARTBEAT_NOW_EPOCH="$heartbeat_epoch" \
    run recover_cmd --namespace "$NAMESPACE" --run "$RUN_ID"
  [ "$status" -ne 0 ]
  [[ "$output" == *"refused: run is healthy"* ]]
}

@test "recovery cli prints refusal for an unknown run" {
  local run_file
  run_file="$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  set_run_json_null "$run_file" "heartbeatAt"

  run recover_cmd --namespace "$NAMESPACE" --run "$RUN_ID"
  [ "$status" -ne 0 ]
  [[ "$output" == *"refused: run liveness is unknown"* ]]
}

@test "recovery cli prints refusal for a published run" {
  local run_file
  run_file="$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  set_run_json_field "$run_file" "status" "published"
  set_run_json_field "$run_file" "heartbeatAt" "2026-08-12T00:00:00Z"
  set_run_json_field "$run_file" "supervisorPid" "99999"
  set_run_json_field "$run_file" "ownerProcessStartId" "old-start"

  GRAPH_HEARTBEAT_TTL_SECONDS=1 GRAPH_HEARTBEAT_NOW_EPOCH=1999999999 \
    run recover_cmd --namespace "$NAMESPACE" --run "$RUN_ID"
  [ "$status" -ne 0 ]
  [[ "$output" == *"refused: run is terminal (published)"* ]]
}

@test "recovery cli prints refusal for a terminal run" {
  local run_file
  run_file="$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  graph_state_set_run_status "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "succeeded"
  set_run_json_field "$run_file" "heartbeatAt" "2026-08-12T00:00:00Z"
  set_run_json_field "$run_file" "supervisorPid" "99999"
  set_run_json_field "$run_file" "ownerProcessStartId" "old-start"

  GRAPH_HEARTBEAT_TTL_SECONDS=1 GRAPH_HEARTBEAT_NOW_EPOCH=1999999999 \
    run recover_cmd --namespace "$NAMESPACE" --run "$RUN_ID"
  [ "$status" -ne 0 ]
  [[ "$output" == *"refused: run is terminal (succeeded)"* ]]
}

@test "recovery cli status does not recover" {
  local run_file left_file run_dir left_aid before_snapshot after_snapshot
  run_file="$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  left_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "left")"
  run_dir="$(graph_state_run_dir "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  left_aid="left__${RUN_ID}__1"

  mark_run_stale
  graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "left" "running" \
    "$left_aid" '{"startedAt":"2026-01-01T00:00:00Z","runtime":"cursor"}'

  before_snapshot="$(ledger_snapshot)"
  run bash "$GRAPH_RUN_SH" status --namespace "$NAMESPACE" --run "$RUN_ID" --workspace "$WORKSPACE"
  [ "$status" -eq 0 ]
  after_snapshot="$(ledger_snapshot)"
  [ "$before_snapshot" = "$after_snapshot" ]

  [ "$(jq -r '.status' "$left_file")" = "running" ]
  [ "$(jq -r '.status' "$run_file")" = "running" ]
  [ ! -f "$run_dir/events.jsonl" ] || {
    local recovery_events
    recovery_events="$(jq -c 'select(.event == "recovery-start" or .event == "node-interrupted" or .event == "node-recovered" or .event == "recovery-finish")' "$run_dir/events.jsonl" 2>/dev/null | wc -l | tr -d ' ')"
    [ "$recovery_events" -eq 0 ]
  }
}

@test "recovery cli attach does not recover" {
  local run_file left_file run_dir left_aid before_snapshot after_snapshot
  run_file="$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  left_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "left")"
  run_dir="$(graph_state_run_dir "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  left_aid="left__${RUN_ID}__1"

  mark_run_stale
  graph_state_write_node_v2 "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "left" "running" \
    "$left_aid" '{"startedAt":"2026-01-01T00:00:00Z","runtime":"cursor"}'

  before_snapshot="$(ledger_snapshot)"
  export RALPH_GRAPH_FOLLOW_INTERVAL=0.05
  export RALPH_GRAPH_FOLLOW_MAX_POLLS=2
  run bash "$GRAPH_RUN_SH" attach --namespace "$NAMESPACE" --run "$RUN_ID" --workspace "$WORKSPACE"
  [ "$status" -eq 0 ]
  after_snapshot="$(ledger_snapshot)"
  [ "$before_snapshot" = "$after_snapshot" ]

  [ "$(jq -r '.status' "$left_file")" = "running" ]
  [ "$(jq -r '.status' "$run_file")" = "running" ]
  [ ! -f "$run_dir/events.jsonl" ] || {
    local recovery_events
    recovery_events="$(jq -c 'select(.event == "recovery-start" or .event == "node-interrupted" or .event == "node-recovered" or .event == "recovery-finish")' "$run_dir/events.jsonl" 2>/dev/null | wc -l | tr -d ' ')"
    [ "$recovery_events" -eq 0 ]
  }
}
