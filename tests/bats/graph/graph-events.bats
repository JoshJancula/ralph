#!/usr/bin/env bats
# Tests for the graph event journal (events.jsonl): ordering, concurrency,
# crash-truncated tail, malformed interior records, redaction/size caps, and
# resume sequence continuity.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/atomic-json.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-state.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-logs.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-events.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-status.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-dispatch.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-run-base.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-schedule.sh"

FIXTURE_PLAN="$BATS_TEST_DIRNAME/../../fixtures/graph/graph-edges.plan.md"
STUB_RUN_PLAN="$BATS_TEST_DIRNAME/../../fixtures/orchestrator-single-stage/run-plan-stub.sh"
RALPH_DIR="$REPO_ROOT/bundle/.ralph"

setup() {
  TMPD="$(mktemp -d)"
  DISPATCH_WORKSPACE="$TMPD/workspace"
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
  export RALPH_RUN_PLAN_CAPTURE_FILE="$TMPD/run-plan-capture.json"
  export RUN_PLAN_STUB_EXIT_CODE=0
  export RUN_PLAN_STUB_WRITE_ARTIFACTS="shared/input.md"
  unset RALPH_ARTIFACT_NS 2>/dev/null || true
  unset RALPH_PLAN_KEY 2>/dev/null || true
}

teardown() {
  rm -rf "$TMPD"
}

compile_plan_graph_to() {
  local src_plan="$1"
  local workspace="$2"
  local out_path="$3"
  local plan_file="$workspace/$(basename "$src_plan")"
  cp "$src_plan" "$plan_file"
  plan_pipeline_graph_json "$plan_file" > "$out_path"
}

_status_event_journal_run() {
  local event_content="$1"
  local ws="$TMPD/status-event-ws"
  local state="$TMPD/status-event-state"
  rm -rf "$ws" "$state"
  mkdir -p "$ws"
  local graph_file="$TMPD/status-event-graph.json"
  cat >"$graph_file" <<'EOF'
{"schemaVersion":1,"ralphVersion":"test","name":"status-event","namespace":"status-event","maxParallel":1,"failurePolicy":"drain","nodes":[{"id":"only","type":"agent","dependsOn":[],"derivedFrom":"stage","stage":{"id":"only","runtime":"cursor","agent":"implementation","_inlineTodos":[{"id":"t","content":"Do it","status":"pending"}],"outputArtifacts":[]}}],"edges":[]}
EOF
  touch "$ws/plan.md"
  local run_id="run-001"
  export RALPH_GRAPH_STATE_ROOT="$state"
  export RALPH_PLAN_WORKSPACE_ROOT="$state"
  graph_state_init_run "$ws" status-event "$run_id" "$ws/plan.md" "$graph_file" 2>/dev/null
  graph_state_write_node "$ws" status-event "$run_id" "only" "succeeded" "only-1" "succeeded" "0" "2026-01-01T00:00:00Z" "2026-01-01T00:01:00Z" "cursor" "off" "" >/dev/null
  local run_dir="$state/graph-runs/status-event/$run_id"
  if [[ -n "$event_content" ]]; then
    printf '%s' "$event_content" >"$run_dir/events.jsonl"
  fi
  graph_status_run "$ws" status-event "$run_id" --details
  unset RALPH_GRAPH_STATE_ROOT RALPH_PLAN_WORKSPACE_ROOT
}

@test "events journal is created with run-started and node-spawn records in order" {
  local graph_file tmpd run_id run_dir
  tmpd="$TMPD"
  graph_file="$tmpd/graph.graph.json"
  compile_plan_graph_to "$FIXTURE_PLAN" "$DISPATCH_WORKSPACE" "$graph_file"
  jq '.nodes = [.nodes[] | select(.id == "source")] | .edges = []' "$graph_file" >"$graph_file.one" && mv "$graph_file.one" "$graph_file"

  run_id="events-order-run"
  export RALPH_GRAPH_STATE_ROOT="$tmpd/state"
  export RALPH_PLAN_WORKSPACE_ROOT="$tmpd/state"
  graph_state_init_run "$DISPATCH_WORKSPACE" graph-edges "$run_id" \
    "$DISPATCH_WORKSPACE/graph-edges.plan.md" "$graph_file" 1
  run_dir="$tmpd/state/graph-runs/graph-edges/$run_id"

  local roots_json
  roots_json="$(jq -cn --arg project "$DISPATCH_WORKSPACE" --arg state "$tmpd/state" \
    '{projectRoot:$project,stateRoot:$state,agentWorkspace:$project}')"
  graph_run_base_prepare "$run_dir" "$roots_json" '["shared"]'
  graph_workspace_prepare_run "$run_dir" "$graph_file"

  graph_schedule_run "$graph_file" "$run_id" "$DISPATCH_WORKSPACE" "$run_dir"

  [ -f "$run_dir/events.jsonl" ]
  local count
  count="$(wc -l <"$run_dir/events.jsonl" | tr -d ' ')"
  [ "$count" -ge 2 ]
  [ "$(jq -r '.schemaVersion' "$run_dir/events.jsonl" | head -n1)" = "1" ]
  [ "$(jq -r '.event' "$run_dir/events.jsonl" | head -n1)" = "run-started" ]
  [ "$(jq -r '.runId' "$run_dir/events.jsonl" | head -n1)" = "$run_id" ]
  # Sequence numbers increase monotonically.
  local seqs
  seqs="$(jq -r '.sequence' "$run_dir/events.jsonl")"
  [ "$(printf '%s\n' "$seqs" | sort -n | tail -n1)" = "$(printf '%s\n' "$seqs" | tail -n1)" ]
  # node-spawn appears before node-terminal.
  local spawn_seq terminal_seq
  spawn_seq="$(jq -r 'select(.event == "node-spawn") | .sequence' "$run_dir/events.jsonl" | head -n1)"
  terminal_seq="$(jq -r 'select(.event == "node-terminal") | .sequence' "$run_dir/events.jsonl" | head -n1)"
  [ -n "$spawn_seq" ]
  [ -n "$terminal_seq" ]
  [ "$spawn_seq" -lt "$terminal_seq" ]
  # run-status-changed is the final record.
  [ "$(jq -r '.event' "$run_dir/events.jsonl" | tail -n1)" = "run-status-changed" ]

  unset RALPH_GRAPH_STATE_ROOT RALPH_PLAN_WORKSPACE_ROOT
}

@test "concurrent appends produce ordered, non-interleaved JSON lines" {
  local run_dir
  run_dir="$TMPD/concurrent-run"
  mkdir -p "$run_dir"

  append_event() {
    local n="$1"
    graph_events_append "$run_dir" "run-concurrent" "node-running-update" "node-$n" "attempt-$n" '{"i":'"$n"'}'
  }

  local pids=()
  for n in $(seq 1 20); do
    append_event "$n" &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do
    wait "$pid" || true
  done

  [ -f "$run_dir/events.jsonl" ]
  local count
  count="$(wc -l <"$run_dir/events.jsonl" | tr -d ' ')"
  [ "$count" -eq 20 ]
  # Every line must be valid JSON.
  jq -e '.' "$run_dir/events.jsonl" >/dev/null
  # Sequences are exactly 1..20.
  local seqs
  seqs="$(jq -r '.sequence' "$run_dir/events.jsonl" | sort -n | tr '\n' ',')"
  [ "$seqs" = "1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20," ]
}

@test "next_sequence resumes from the last valid line after a truncated tail" {
  local run_dir
  run_dir="$TMPD/truncated-run"
  mkdir -p "$run_dir"

  printf '{"schemaVersion":1,"sequence":1,"timestamp":"2026-01-01T00:00:00Z","runId":"r","event":"run-started","details":{}}\n' >"$run_dir/events.jsonl"
  printf '{"schemaVersion":1,"sequence":2,"timestamp":"2026-01-01T00:00:01Z","runId":"r","event":"node-spawn","nodeId":"n","details":{}}\n' >>"$run_dir/events.jsonl"
  printf '{"schemaVersion":1,"sequence":3,"timestamp":"2026-01-01T00:00:02Z","runId":"r","event' >>"$run_dir/events.jsonl"

  [ "$(graph_events_next_sequence "$run_dir")" -eq 3 ]
  graph_events_append "$run_dir" "r" "node-terminal" "n" "a" '{"outcome":"succeeded"}'
  [ "$(jq -R 'fromjson? | .sequence' "$run_dir/events.jsonl" | tail -n1)" = "3" ]
}

@test "read_lines ignores one truncated final line but rejects malformed interior lines" {
  local run_dir
  run_dir="$TMPD/malformed-run"
  mkdir -p "$run_dir"

  printf '{"schemaVersion":1,"sequence":1,"runId":"r","event":"run-started","details":{}}\n' >"$run_dir/events.jsonl"
  printf 'this is not json\n' >>"$run_dir/events.jsonl"

  run graph_events_read_lines "$run_dir"
  [ "$status" -ne 0 ]
  [[ "$output" == *"malformed interior event journal line"* ]]

  # Malformed as final line should be ignored.
  printf '{"schemaVersion":1,"sequence":1,"runId":"r","event":"run-started","details":{}}\n' >"$run_dir/events.jsonl"
  printf 'this is not json' >>"$run_dir/events.jsonl"
  run graph_events_read_lines "$run_dir"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 1 ]
}

@test "details are redacted when they contain credential-looking values" {
  local run_dir
  run_dir="$TMPD/redact-run"
  mkdir -p "$run_dir"

  graph_events_append "$run_dir" "r" "node-spawn" "n" "a" '{"apiKey":"secret123","password":"hunter2","token":"abc"}'
  local details
  details="$(jq -r '.details' "$run_dir/events.jsonl")"
  [[ "$details" != *"secret123"* ]]
  [[ "$details" != *"hunter2"* ]]
  [[ "$details" == *"[REDACTED]"* ]]
}

@test "oversized details are truncated with a size marker" {
  local run_dir huge
  run_dir="$TMPD/size-run"
  mkdir -p "$run_dir"

  huge="$(python3 -c 'import json; print(json.dumps({"blob":"x"*65536}))')"
  graph_events_append "$run_dir" "r" "node-spawn" "n" "a" "$huge"
  local details bytes
  details="$(jq -r '.details' "$run_dir/events.jsonl")"
  [[ "$details" == *"_truncated"* ]]
  bytes="$(printf '%s' "$details" | wc -c | tr -d ' ')"
  [ "$bytes" -le 1024 ]
}

@test "max_sequence returns the highest valid sequence" {
  local run_dir
  run_dir="$TMPD/seq-run"
  mkdir -p "$run_dir"

  printf '{"schemaVersion":1,"sequence":7,"runId":"r","event":"run-started","details":{}}\n' >"$run_dir/events.jsonl"
  [ "$(graph_events_max_sequence "$run_dir")" -eq 7 ]
}

@test "scheduled run appends node-spawn, node-terminal, and run-status-changed events" {
  local graph_file tmpd run_id run_dir
  tmpd="$TMPD"
  graph_file="$tmpd/one.graph.json"
  cat >"$graph_file" <<EOF
{"schemaVersion":1,"ralphVersion":"test","name":"one","namespace":"one","maxParallel":1,"failurePolicy":"drain","nodes":[{"id":"only","type":"agent","dependsOn":[],"derivedFrom":"stage","stage":{"id":"only","runtime":"cursor","agent":"implementation","_inlineTodos":[{"id":"t","content":"Do it","status":"pending"}],"outputArtifacts":[]}}],"edges":[]}
EOF

  run_id="events-sched-run"
  export RALPH_GRAPH_STATE_ROOT="$tmpd/state"
  export RALPH_PLAN_WORKSPACE_ROOT="$tmpd/state"
  graph_state_init_run "$DISPATCH_WORKSPACE" one "$run_id" \
    "$DISPATCH_WORKSPACE/one.plan.md" "$graph_file" 1
  run_dir="$tmpd/state/graph-runs/one/$run_id"

  local roots_json
  roots_json="$(jq -cn --arg project "$DISPATCH_WORKSPACE" --arg state "$tmpd/state" \
    '{projectRoot:$project,stateRoot:$state,agentWorkspace:$project}')"
  graph_run_base_prepare "$run_dir" "$roots_json" '["shared"]'
  graph_workspace_prepare_run "$run_dir" "$graph_file"

  graph_schedule_run "$graph_file" "$run_id" "$DISPATCH_WORKSPACE" "$run_dir"
  [ "$GRAPH_SCHEDULE_EXIT_CODE" -eq 0 ]

  [ -f "$run_dir/events.jsonl" ]
  [ "$(jq -r '.event' "$run_dir/events.jsonl" | head -n1)" = "run-started" ]
  [ "$(jq -r '.event' "$run_dir/events.jsonl" | tail -n1)" = "run-status-changed" ]
  jq -r '.event' "$run_dir/events.jsonl" | grep -qx 'node-spawn'
  jq -r '.event' "$run_dir/events.jsonl" | grep -qx 'node-terminal'

  unset RALPH_GRAPH_STATE_ROOT RALPH_PLAN_WORKSPACE_ROOT
}

@test "status event journal: missing journal is nonfatal" {
  run _status_event_journal_run ""
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '^only '
  ! printf '%s\n' "$output" | grep -q 'Warning: event journal'
}

@test "status event journal: one crash-truncated tail is nonfatal" {
  local events
  events='{"schemaVersion":1,"sequence":1,"timestamp":"2026-01-01T00:00:00Z","runId":"run-001","event":"native-subagent-spawn","nodeId":"only","attemptId":"only-1","details":{"role":"research"}}
{"schemaVersion":1,"sequence":2,"timestamp":"2026-01-01T00:00:01Z","runId":"run-001","event":"'
  run _status_event_journal_run "$events"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'native-subagent event=native-subagent-spawn'
  ! printf '%s\n' "$output" | grep -q 'Warning: event journal'
}

@test "status event journal: malformed interior line produces a concise warning" {
  local events
  events='{"schemaVersion":1,"sequence":1,"timestamp":"2026-01-01T00:00:00Z","runId":"run-001","event":"native-subagent-spawn","nodeId":"only","attemptId":"only-1","details":{}}
this is not json
{"schemaVersion":1,"sequence":3,"timestamp":"2026-01-01T00:00:02Z","runId":"run-001","event":"native-subagent-finished","nodeId":"only","attemptId":"only-1","details":{}}'
  run _status_event_journal_run "$events"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'Warning: event journal has a malformed interior line'
  printf '%s\n' "$output" | grep -q '^only '
  # The second valid event after the malformed line is not reported.
  ! printf '%s\n' "$output" | grep -q 'native-subagent-finished'
  # The journal and ledger are not mutated.
  local state="$TMPD/status-event-state"
  local journal="$state/graph-runs/status-event/run-001/events.jsonl"
  [ -f "$journal" ]
  grep -q 'native-subagent-spawn' "$journal"
  grep -q 'this is not json' "$journal"
  grep -q 'native-subagent-finished' "$journal"
  [ "$(jq -r '.status' "$state/graph-runs/status-event/run-001/nodes/only.json")" = "succeeded" ]
}
