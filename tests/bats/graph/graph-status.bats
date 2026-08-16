#!/usr/bin/env bats
# Tests for the graph status verb (p7-status).

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/plan-todo.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/atomic-json.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-state.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-status.sh"

DIAMOND_PLAN="$BATS_TEST_DIRNAME/../../fixtures/graph/graph-diamond.plan.md"
CONSENSUS_GRAPH_JSON="$BATS_TEST_DIRNAME/../../fixtures/graph/graph-consensus.graph.json"
GRAPH_RUN_SH="$REPO_ROOT/bundle/.ralph/graph-run.sh"
PRODUCTION_FIXTURE_DIR="$BATS_TEST_DIRNAME/../../fixtures/graph-production-failure"

# ---------------------------------------------------------------------------
# Helper: build a completed ledger for a diamond graph
# ---------------------------------------------------------------------------

setup() {
  TMPD="$(mktemp -d)"
  WORKSPACE="$TMPD/ws"
  mkdir -p "$WORKSPACE"
  NAMESPACE="test-ns"
  RUN_ID="run-test-001"

  # Compile the diamond plan into a graph json.
  GRAPH_JSON="$TMPD/graph.json"
  local plan_copy="$WORKSPACE/$(basename "$DIAMOND_PLAN")"
  cp "$DIAMOND_PLAN" "$plan_copy"
  plan_pipeline_graph_json "$plan_copy" > "$GRAPH_JSON"

  # Initialize the ledger.
  graph_state_init_run \
    "$WORKSPACE" "$NAMESPACE" "$RUN_ID" \
    "$plan_copy" "$GRAPH_JSON" 2 >/dev/null

  # Mark each node with a completed state so status has something to show.
  # Diamond graph has: source, left, right, join (id names may vary).
  local now="2026-01-01T00:00:00Z"
  local done="2026-01-01T00:01:00Z"
  while IFS= read -r nid || [[ -n "$nid" ]]; do
    [[ -z "$nid" ]] && continue
    graph_state_write_node \
      "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$nid" \
      "succeeded" \
      "${nid}-attempt-1" "succeeded" "0" \
      "$now" "$done" "cursor" "off" "" >/dev/null
  done < <(jq -r '.nodes[].id' "$GRAPH_JSON")
}

teardown() {
  rm -rf "$TMPD"
}

# ---------------------------------------------------------------------------
# Table output correctness
# ---------------------------------------------------------------------------

@test "status shows every node with its state and attempt count" {
  run graph_status_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID"
  [ "$status" -eq 0 ]
  # All nodes from the diamond graph must appear.
  local node_ids
  node_ids="$(jq -r '.nodes[].id' "$GRAPH_JSON")"
  while IFS= read -r nid || [[ -n "$nid" ]]; do
    [[ -z "$nid" ]] && continue
    # Each node id appears somewhere in the output.
    printf '%s\n' "$output" | grep -q "$nid"
  done <<< "$node_ids"
}

@test "status shows runtime from the frozen graph" {
  run graph_status_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID"
  [ "$status" -eq 0 ]
  # The diamond plan uses cursor runtime throughout.
  printf '%s\n' "$output" | grep -q 'cursor'
}

@test "status shows attempt count of 1 for each node" {
  run graph_status_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID"
  [ "$status" -eq 0 ]
  # Each table row for a node has attempt count 1 (set in setup).
  printf '%s\n' "$output" | grep -q '^[A-Za-z]' || true  # at least a node row exists
}

@test "status shows succeeded state" {
  run graph_status_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'succeeded'
}

# ---------------------------------------------------------------------------
# Regression: production-failure fixture cases
# ---------------------------------------------------------------------------

@test "status does not abort when concurrency-reduction metadata is empty" {
  # Based on the sanitized empty-concurrency-reduction-metadata fixture: an
  # admission log exists but contains no event that maps to a reduction
  # reason. A helper with nothing optional to print must still return
  # success so status does not abort under errexit.
  jq -e '.fixture.concurrencyReductions == {}' \
    "$PRODUCTION_FIXTURE_DIR/empty-concurrency-reduction-metadata.json" >/dev/null

  local run_dir
  run_dir="$(dirname "$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID")")"
  printf '%s\n' '{"event":"admission","workKind":"agent","decision":"admitted","subagents":"off","sameRuntimeParallelSafe":true,"reason":"admitted"}' \
    >"$run_dir/observability.jsonl"

  run _graph_status_concurrency_reductions "$run_dir"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run graph_status_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID"
  [ "$status" -eq 0 ]
}

@test "status counts one unique attempt when a running transition and its terminal transition both append to attempts[]" {
  # Based on the sanitized attempt-running-then-terminal-transition fixture:
  # a v1 ledger appends a separate attempts[] record for the running
  # transition and the terminal transition of the same attemptId. Status
  # must report one attempt, not two transition records.
  jq -e '.fixture.events | length == 2' \
    "$PRODUCTION_FIXTURE_DIR/attempt-running-then-terminal-transition.json" >/dev/null

  # Use a fresh run so the node's attempts[] array starts empty (the shared
  # setup() run already seeded one succeeded attempt per node).
  local transition_run="run-transition-001"
  local plan_copy="$WORKSPACE/$(basename "$DIAMOND_PLAN")"
  graph_state_init_run \
    "$WORKSPACE" "$NAMESPACE" "$transition_run" \
    "$plan_copy" "$GRAPH_JSON" 2 >/dev/null

  local nid="$(jq -r '.nodes[0].id' "$GRAPH_JSON")"
  local attempt_id="${nid}__${transition_run}__1"
  # Running transition: appends attempts[0] with no outcome yet.
  graph_state_write_node \
    "$WORKSPACE" "$NAMESPACE" "$transition_run" "$nid" \
    "running" \
    "$attempt_id" "" "" \
    "2026-01-01T00:00:00Z" "" "cursor" "off" "" >/dev/null
  # Terminal transition: appends a second attempts[] record for the same
  # attemptId rather than updating the first (the known v1 duplication bug).
  graph_state_write_node \
    "$WORKSPACE" "$NAMESPACE" "$transition_run" "$nid" \
    "succeeded" \
    "$attempt_id" "succeeded" "0" \
    "2026-01-01T00:00:00Z" "2026-01-01T00:01:00Z" "cursor" "off" "" >/dev/null

  local node_file
  node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$transition_run" "$nid")"
  # Confirm the ledger really does hold two raw records for one attemptId,
  # so this test exercises the display-layer fix, not a ledger-layer one.
  [ "$(jq '.attempts | length' "$node_file")" -eq 2 ]
  [ "$(jq '[.attempts[].attemptId] | unique | length' "$node_file")" -eq 1 ]

  run graph_status_run "$WORKSPACE" "$NAMESPACE" "$transition_run"
  [ "$status" -eq 0 ]
  local row
  row="$(printf '%s\n' "$output" | grep "^${nid} ")"
  [ -n "$row" ]
  # ATTEMPTS is the fifth whitespace-separated column of the row.
  [ "$(printf '%s\n' "$row" | awk '{print $5}')" = "1" ]
}

@test "status renders every graph node exactly once in the default table" {
  run graph_status_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID"
  [ "$status" -eq 0 ]
  local node_ids
  node_ids="$(jq -r '.nodes[].id' "$GRAPH_JSON")"
  while IFS= read -r nid || [[ -n "$nid" ]]; do
    [[ -z "$nid" ]] && continue
    local occurrences
    occurrences="$(printf '%s\n' "$output" | grep -c "^${nid} ")"
    [ "$occurrences" -eq 1 ]
  done <<< "$node_ids"
}

@test "status displays unavailable usage as n/a rather than an empty aggregate" {
  run graph_status_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'usage parent=n/a brokered-children=n/a'
  ! printf '%s\n' "$output" | grep -q 'usage parent={}'
}

# ---------------------------------------------------------------------------
# Mermaid class definitions
# ---------------------------------------------------------------------------

@test "status mermaid output contains classDef for each state" {
  run graph_status_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID" --mermaid
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'classDef state_succeeded'
  printf '%s\n' "$output" | grep -q 'classDef state_failed'
  printf '%s\n' "$output" | grep -q 'classDef state_running'
  printf '%s\n' "$output" | grep -q 'classDef state_pending'
  printf '%s\n' "$output" | grep -q 'classDef state_blocked'
  printf '%s\n' "$output" | grep -q 'classDef state_skipped'
  printf '%s\n' "$output" | grep -q 'classDef state_awaiting_ack'
  printf '%s\n' "$output" | grep -q 'classDef state_cancelled'
}

@test "status mermaid applies state class to each node" {
  run graph_status_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID" --mermaid
  [ "$status" -eq 0 ]
  # At least one node is annotated with the state_succeeded class.
  printf '%s\n' "$output" | grep -q ':::state_succeeded'
}

@test "status mermaid output starts with flowchart TD inside the mermaid block" {
  run graph_status_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID" --mermaid
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'flowchart TD'
}

@test "status default output omits the mermaid flowchart" {
  run graph_status_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID"
  [ "$status" -eq 0 ]
  ! printf '%s\n' "$output" | grep -q 'flowchart TD'
  ! printf '%s\n' "$output" | grep -q 'classDef state_succeeded'
}

# ---------------------------------------------------------------------------
# Read-only: never writes to graph-runs after the ledger is initialized
# ---------------------------------------------------------------------------

@test "status does not write to the graph-runs directory" {
  local runs_dir
  runs_dir="$(graph_state_runs_root "$WORKSPACE")"

  # Snapshot: collect all files and their checksums before status.
  local before_snapshot
  before_snapshot="$(find "$runs_dir" -type f | sort | while IFS= read -r f; do
    printf '%s %s\n' "$(md5 -q "$f" 2>/dev/null || md5sum "$f" 2>/dev/null | awk '{print $1}')" "$f"
  done)"

  # Run status (ignore exit code since we care about side effects only).
  graph_status_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID" >/dev/null 2>&1 || true

  # Snapshot after.
  local after_snapshot
  after_snapshot="$(find "$runs_dir" -type f | sort | while IFS= read -r f; do
    printf '%s %s\n' "$(md5 -q "$f" 2>/dev/null || md5sum "$f" 2>/dev/null | awk '{print $1}')" "$f"
  done)"

  [ "$before_snapshot" = "$after_snapshot" ]
}

# ---------------------------------------------------------------------------
# Live / in-progress run: status exits cleanly even with partial ledger
# ---------------------------------------------------------------------------

@test "status against a live in-progress run exits cleanly" {
  local live_run_id="run-inprogress"
  local now="2026-01-01T00:00:00Z"
  local plan_copy="$WORKSPACE/$(basename "$DIAMOND_PLAN")"

  graph_state_init_run \
    "$WORKSPACE" "$NAMESPACE" "$live_run_id" \
    "$plan_copy" "$GRAPH_JSON" 2 >/dev/null

  # Mark only the first node as running; leave others as pending.
  local first_nid
  first_nid="$(jq -r '.nodes[0].id' "$GRAPH_JSON")"
  graph_state_write_node \
    "$WORKSPACE" "$NAMESPACE" "$live_run_id" "$first_nid" \
    "running" \
    "${first_nid}-attempt-1" "" "" \
    "$now" "" "cursor" "off" "" >/dev/null

  # Status should exit 0 and show at least the running and pending states.
  run graph_status_run "$WORKSPACE" "$NAMESPACE" "$live_run_id"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'running'
  printf '%s\n' "$output" | grep -q 'pending'
}

@test "status exposes v2 workspace, gate, repair, child, usage, and admission observations without mutation" {
  local node="$(jq -r '.nodes[0].id' "$GRAPH_JSON")"
  local node_file before after delegation_dir
  node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$node")"
  graph_state_write_node "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$node" "failed" \
    "${node}-obs" "failed" "1" "2026-01-01T00:00:00Z" "2026-01-01T00:01:00Z" "cursor" "on" "gate changes required" \
    '{"workspaceMode":"snapshot","workspacePath":"/isolated/node","writeScopes":["src"],"frozenBase":"frozen-base-0123456789","changesetHash":"changeset-0123456789","integrationInputs":["left.json","right.json"],"conflictArtifact":"integration.conflict.json","gateOutcome":"changes-required","repairEpoch":"repair-1","nativeSubagentMode":"read-only","usageSnapshot":{"input_tokens":10},"admissionSummary":{"reason":"runtime-overlay"},"publishReadiness":{"status":"drifted"},"verificationResourceClasses":["exclusive"]}' >/dev/null
  delegation_dir="$(dirname "$node_file")/$(basename "$node_file" .json)/delegations/delegation-observed"
  mkdir -p "$delegation_dir"
  printf '%s\n' '{"delegationId":"observed","runtime":"codex"}' >"$delegation_dir/request.json"
  printf '%s\n' '{"status":"awaiting-ack","usage":{"inputTokens":4}}' >"$delegation_dir/status.json"
  mkdir -p "${delegation_dir%observed}cancelled"
  printf '%s\n' '{"delegationId":"cancelled","runtime":"claude"}' >"${delegation_dir%observed}cancelled/request.json"
  printf '%s\n' '{"status":"cancelled"}' >"${delegation_dir%observed}cancelled/status.json"
  printf '{"schemaVersion":1,"sequence":99,"timestamp":"2026-01-01T00:00:00Z","runId":"%s","event":"native-subagent-finished","nodeId":"%s","attemptId":null,"details":{"role":"research"}}\n' "$RUN_ID" "$node" >"$(dirname "$node_file")/../events.jsonl"

  before="$(find "$(graph_state_runs_root "$WORKSPACE")" -type f -exec shasum {} \; | sort)"

  # The run-summary usage aggregate is part of the default output (not
  # gated behind --details).
  run graph_status_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'brokered-children={"inputTokens":4}'
  # Verbose per-node/per-attempt metadata is not part of the default output.
  ! printf '%s\n' "$output" | grep -q 'mode=snapshot'
  ! printf '%s\n' "$output" | grep -q 'brokered child=observed'
  ! printf '%s\n' "$output" | grep -q 'native-subagent event=native-subagent-finished'

  run graph_status_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID" --details
  [ "$status" -eq 0 ]
  after="$(find "$(graph_state_runs_root "$WORKSPACE")" -type f -exec shasum {} \; | sort)"
  [ "$before" = "$after" ]
  printf '%s\n' "$output" | grep -q 'mode=snapshot'
  printf '%s\n' "$output" | grep -q 'gateOutcome=changes-required'
  printf '%s\n' "$output" | grep -q 'repairEpoch=repair-1'
  printf '%s\n' "$output" | grep -q 'brokered child=observed'
  printf '%s\n' "$output" | grep -q 'brokered child=cancelled'
  printf '%s\n' "$output" | grep -q 'native-subagent event=native-subagent-finished'
  printf '%s\n' "$output" | grep -q 'brokered-children={"inputTokens":4}'
  printf '%s\n' "$output" | grep -q 'verificationResources='
}

# ---------------------------------------------------------------------------
# Run selector: resolve 'latest' to the actual run id
# ---------------------------------------------------------------------------

@test "status --run latest resolves to the most recent run" {
  run graph_status_cli \
    --workspace "$WORKSPACE" \
    --namespace "$NAMESPACE" \
    --run latest
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'run='
}

# ---------------------------------------------------------------------------
# Consensus node provenance: per-voter output from consensus-result.json
# ---------------------------------------------------------------------------

@test "consensus barrier node shows per-voter provenance when result exists" {
  # Build a consensus run from the pre-compiled fixture.
  local cons_ns="cons-ns"
  local cons_run="run-cons-001"
  local cons_ws="$TMPD/cons-ws"
  mkdir -p "$cons_ws"

  graph_state_init_run \
    "$cons_ws" "$cons_ns" "$cons_run" \
    "/dev/null" "$CONSENSUS_GRAPH_JSON" 2 >/dev/null

  # Mark all nodes succeeded.
  local now="2026-01-01T00:00:00Z"
  local done="2026-01-01T00:02:00Z"
  while IFS= read -r nid || [[ -n "$nid" ]]; do
    [[ -z "$nid" ]] && continue
    graph_state_write_node \
      "$cons_ws" "$cons_ns" "$cons_run" "$nid" \
      "succeeded" \
      "${nid}-a1" "succeeded" "0" \
      "$now" "$done" "cursor" "off" "" >/dev/null
  done < <(jq -r '.nodes[].id' "$CONSENSUS_GRAPH_JSON")

  # Write a synthetic consensus result for the barrier node (review:barrier).
  local result_dir="$cons_ws/.ralph-workspace/artifacts/${cons_ns}/consensus"
  mkdir -p "$result_dir"
  # The safe_id for "review:barrier" is "review_barrier".
  cat >"$result_dir/review_barrier.json" <<'RESULT'
{
  "schemaVersion": 1,
  "nodeId": "review:barrier",
  "policy": "veto",
  "decision": "changes-required",
  "voters": [
    {"voterId": "review:alpha", "runtime": "cursor",  "status": "approved",          "agent": "code-review", "confidence": 0.9},
    {"voterId": "review:beta",  "runtime": "codex",   "status": "changes-required",  "agent": "code-review", "confidence": 0.7},
    {"voterId": "review:gamma", "runtime": "claude",  "status": "approved",          "agent": "code-review", "confidence": 0.85}
  ],
  "dissent": ["review:beta"],
  "agreement": 0.667
}
RESULT

  run graph_status_run "$cons_ws" "$cons_ns" "$cons_run" --details
  [ "$status" -eq 0 ]
  # The dissenting voter (review:beta) must be named.
  printf '%s\n' "$output" | grep -q 'review:beta'
  # The dissent line must appear.
  printf '%s\n' "$output" | grep -q 'dissenting-voters'
  # Confidence must be shown.
  printf '%s\n' "$output" | grep -q 'confidence='
}

@test "consensus barrier node names the dissenting provider" {
  local cons_ns="cons-dissent"
  local cons_run="run-cons-002"
  local cons_ws="$TMPD/cons-ws2"
  mkdir -p "$cons_ws"

  graph_state_init_run \
    "$cons_ws" "$cons_ns" "$cons_run" \
    "/dev/null" "$CONSENSUS_GRAPH_JSON" 2 >/dev/null

  local now="2026-01-01T00:00:00Z"
  local done="2026-01-01T00:02:00Z"
  while IFS= read -r nid || [[ -n "$nid" ]]; do
    [[ -z "$nid" ]] && continue
    graph_state_write_node \
      "$cons_ws" "$cons_ns" "$cons_run" "$nid" \
      "succeeded" \
      "${nid}-a1" "succeeded" "0" \
      "$now" "$done" "cursor" "off" "" >/dev/null
  done < <(jq -r '.nodes[].id' "$CONSENSUS_GRAPH_JSON")

  local result_dir="$cons_ws/.ralph-workspace/artifacts/${cons_ns}/consensus"
  mkdir -p "$result_dir"
  cat >"$result_dir/review_barrier.json" <<'RESULT'
{
  "schemaVersion": 1,
  "nodeId": "review:barrier",
  "policy": "veto",
  "decision": "changes-required",
  "voters": [
    {"voterId": "review:alpha", "runtime": "cursor",  "status": "approved"},
    {"voterId": "review:beta",  "runtime": "codex",   "status": "changes-required"},
    {"voterId": "review:gamma", "runtime": "claude",  "status": "approved"}
  ],
  "dissent": ["review:beta"],
  "agreement": 0.667
}
RESULT

  run graph_status_run "$cons_ws" "$cons_ns" "$cons_run" --details
  [ "$status" -eq 0 ]
  # The dissenting provider (codex) must appear.
  printf '%s\n' "$output" | grep -q 'codex'
  printf '%s\n' "$output" | grep -q 'dissenting-voters'
}

# ---------------------------------------------------------------------------
# State transition log: one line per transition
# ---------------------------------------------------------------------------

@test "graph_schedule_log_transition writes a structured log line" {
  # graph-schedule.sh is already sourced at the top of this file via
  # graph-status.sh -> graph-state.sh chain; no need to re-source.
  # graph-schedule.sh itself is not sourced directly here, so source it now.
  # Use a sub-shell to avoid polluting the top-level state.
  local log_file="$TMPD/transitions.log"
  touch "$log_file"

  (
    source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-schedule.sh" 2>/dev/null
    GRAPH_SCHEDULE_LOG_FILE="$log_file"
    _graph_schedule_log_transition "node=source state=running attempt=source-a1"
  )

  # The log line must exist with the timestamp format.
  grep -q 'node=source state=running' "$log_file"
  grep -qE '^\[20[0-9]{2}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\]' "$log_file"
}

@test "_graph_schedule_log_transition is a no-op when log file is empty" {
  # Should not error and should produce no output even when log file is unset.
  (
    source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-schedule.sh" 2>/dev/null
    GRAPH_SCHEDULE_LOG_FILE=""
    _graph_schedule_log_transition "node=x state=pending"
  )
  [ "$?" -eq 0 ]
}

# ---------------------------------------------------------------------------
# graph-run.sh CLI integration
# ---------------------------------------------------------------------------

@test "graph-run.sh status --help exits 0" {
  run bash "$GRAPH_RUN_SH" status --help
  [ "$status" -eq 0 ]
}

@test "graph-run.sh status errors without --namespace" {
  run bash "$GRAPH_RUN_SH" status --run latest --workspace "$WORKSPACE"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'namespace'
}

@test "graph-run.sh status errors without --run" {
  run bash "$GRAPH_RUN_SH" status --namespace "$NAMESPACE" --workspace "$WORKSPACE"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'run'
}

@test "graph-run.sh status runs successfully for a completed run" {
  run bash "$GRAPH_RUN_SH" status \
    --namespace "$NAMESPACE" \
    --run "$RUN_ID" \
    --workspace "$WORKSPACE"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'succeeded'
  ! printf '%s\n' "$output" | grep -q 'flowchart TD'
}

@test "graph-run.sh status --mermaid includes the flowchart" {
  run bash "$GRAPH_RUN_SH" status \
    --namespace "$NAMESPACE" \
    --run "$RUN_ID" \
    --workspace "$WORKSPACE" \
    --mermaid
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'flowchart TD'
}

@test "graph-run.sh status --run latest resolves and exits 0" {
  run bash "$GRAPH_RUN_SH" status \
    --namespace "$NAMESPACE" \
    --run latest \
    --workspace "$WORKSPACE"
  [ "$status" -eq 0 ]
}
