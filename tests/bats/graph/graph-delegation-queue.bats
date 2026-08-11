#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-delegation-queue.sh"
source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-delegation-mcp.sh"
source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-schedule.sh"

setup() { TMPD="$(mktemp -d)"; WS="$TMPD/ws"; mkdir -p "$WS"; }
teardown() { rm -rf "$TMPD"; }

_start() {
  local node="$1" key="$2" runtime="${3:-claude}"
  graph_delegation_ledger_start "$WS" ns run "$node" a "$key" task '{"maxChildren":3}' "$runtime" implementation '' 1 snapshot '[]' ''
}
_queue() { graph_delegation_queue_enqueue "$WS" ns run "$1" "$2" "${3:-3}"; }

@test "concurrent enqueue is atomic and ordered by request time then id" {
  local a b
  a="$(_start parent a)"; b="$(_start parent b)"
  _queue parent "$a" & local p1=$!
  _queue parent "$b" & local p2=$!
  wait "$p1"; wait "$p2"
  [ "$(graph_delegation_queue_pending "$WS" ns run | wc -l | tr -d ' ')" = 2 ]
  graph_delegation_queue_pending "$WS" ns run | jq -e '.delegationId' >/dev/null
}

@test "admission is FIFO and respects run-wide and runtime caps" {
  local a b first
  a="$(_start one a claude)"; b="$(_start two b claude)"
  _queue one "$a"; _queue two "$b"
  first="$(graph_delegation_queue_admit_one "$WS" ns run 1 1)"
  [ "$(jq -r .delegationId <<<"$first")" = "$a" ]
  run graph_delegation_queue_admit_one "$WS" ns run 1 1
  [ "$status" -eq 2 ]
  graph_delegation_ledger_transition "$WS" ns run one "$a" succeeded s pass '{}' '{}' ''
  run graph_delegation_queue_admit_one "$WS" ns run 1 1
  [ "$status" -eq 0 ]
  [ "$(jq -r .delegationId <<<"$output")" = "$b" ]
}

@test "parent maxChildren is enforced atomically" {
  local a b
  a="$(_start parent a)"; b="$(_start parent b)"
  _queue parent "$a" 1
  run _queue parent "$b" 1
  [ "$status" -eq 3 ]
}

@test "cancelled work is skipped before dispatch and survives scheduler restart" {
  local a b
  a="$(_start one a codex)"; b="$(_start two b claude)"
  _queue one "$a"; _queue two "$b"
  graph_delegation_ledger_transition "$WS" ns run one "$a" cancelled '' '' '{}' null cancelled
  # No in-memory state is required: sourcing again represents a scheduler restart.
  unset GRAPH_DELEGATION_QUEUE_LOADED
  source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-delegation-queue.sh"
  run graph_delegation_queue_admit_one "$WS" ns run 2 1
  [ "$status" -eq 0 ]
  [ "$(jq -r .delegationId <<<"$output")" = "$b" ]
}

@test "delegation preflight rejects a parent with no child slot" {
  local graph="$TMPD/graph.json"
  printf '%s\n' '{"nodes":[{"stage":{"delegation":{"maxChildren":1,"crossRuntime":{"mode":"read-only","allowedRuntimes":["claude"]}}}}]}' > "$graph"
  run graph_schedule_delegation_preflight "$graph" 1
  [ "$status" -ne 0 ]
  graph_schedule_delegation_preflight "$graph" 2
}

@test "same runtime broker request is rejected when scheduler supplies parent runtime" {
  export WORKSPACE_ROOT="$WS" RALPH_MCP_SCOPE=graph-node RALPH_GRAPH_NAMESPACE=ns RALPH_GRAPH_RUN_ID=run RALPH_GRAPH_NODE_ID=parent RALPH_GRAPH_ATTEMPT_ID=a RALPH_GRAPH_NODE_RUNTIME=claude RALPH_GRAPH_DELEGATION_DEPTH=0
  export RALPH_GRAPH_NODE_POLICY='{"maxDepth":1,"maxChildren":1,"crossRuntime":{"mode":"read-only","allowedRuntimes":["claude"],"allowedAgents":["research"]}}'
  LAST_ERROR=""; send_error() { LAST_ERROR="$4"; }; send_result() { :; }
  handle_delegate_start '{"task":"x","idempotency_key":"k","runtime":"claude","agent":"research"}' true 1
  [[ "$LAST_ERROR" == *"same-runtime"* ]]
}

@test "broker child consumes scheduler runtime and token slots" {
  local did
  did="$(_start parent child-a claude)"
  _queue parent "$did"
  GRAPH_SCHEDULE_MAX_PARALLEL_PER_RUNTIME=2
  GRAPH_SCHEDULE_TOKEN_CAP=2
  GRAPH_SCHEDULE_USED_TOKEN_SLOTS=0
  _graph_schedule_reset_runtime_occupancy

  graph_schedule_admit_delegated_child "$WS" ns run 2 2
  [ "$(jq -r .delegationId <<<"$GRAPH_DELEGATION_ADMITTED_ENTRY")" = "$did" ]
  _graph_schedule_runtime_map_index claude
  [ "${GRAPH_RUNTIME_USED_SLOTS[$GRAPH_RUNTIME_LOOKUP_IDX]}" -eq 1 ]
  [ "$GRAPH_SCHEDULE_USED_TOKEN_SLOTS" -eq 1 ]

  _graph_schedule_runtime_release_slots claude 1 1
  [ "${GRAPH_RUNTIME_USED_SLOTS[$GRAPH_RUNTIME_LOOKUP_IDX]}" -eq 0 ]
  [ "$GRAPH_SCHEDULE_USED_TOKEN_SLOTS" -eq 0 ]
}

@test "unsafe adapter broker child is deferred behind active graph node" {
  local did status_file
  did="$(_start parent child-cursor cursor)"
  _queue parent "$did"
  GRAPH_SCHEDULE_MAX_PARALLEL_PER_RUNTIME=3
  GRAPH_SCHEDULE_TOKEN_CAP=3
  GRAPH_SCHEDULE_USED_TOKEN_SLOTS=0
  _graph_schedule_reset_runtime_occupancy
  _graph_schedule_runtime_reserve_slots cursor 1 1

  run graph_schedule_admit_delegated_child "$WS" ns run 2 3
  [ "$status" -eq 2 ]
  status_file="$(graph_delegation_ledger_status_file "$WS" ns run parent "$did")"
  [ "$(jq -r .status "$status_file")" = "queued" ]
}

@test "scheduler recovery adopts live broker child into runtime and token budgets" {
  local did entry pid
  did="$(_start parent recover-child claude)"
  _queue parent "$did"
  entry="$(graph_delegation_queue_admit_one "$WS" ns run 2 2)"
  [ "$(jq -r .delegationId <<<"$entry")" = "$did" ]
  sleep 30 & pid=$!
  graph_delegation_child_record_process "$WS" ns run parent "$did" "$pid" "$pid"

  GRAPH_SCHEDULE_WORKSPACE="$WS"
  GRAPH_SCHEDULE_NAMESPACE=ns
  GRAPH_SCHEDULE_RUN_ID=run
  GRAPH_SCHEDULE_MAX_PARALLEL=2
  GRAPH_SCHEDULE_MAX_PARALLEL_PER_RUNTIME=2
  GRAPH_SCHEDULE_TOKEN_CAP=2
  GRAPH_DELEGATION_CHILD_PIDS=(); GRAPH_DELEGATION_CHILD_PARENTS=(); GRAPH_DELEGATION_CHILD_IDS=()
  GRAPH_DELEGATION_CHILD_RUNTIMES=(); GRAPH_DELEGATION_CHILD_HELD_SLOTS=(); GRAPH_DELEGATION_CHILD_TOKEN_SLOTS=()
  _graph_schedule_reset_runtime_occupancy
  graph_schedule_recover_delegated_children

  [ "${GRAPH_DELEGATION_CHILD_PIDS[0]}" -eq "$pid" ]
  _graph_schedule_runtime_map_index claude
  [ "${GRAPH_RUNTIME_USED_SLOTS[$GRAPH_RUNTIME_LOOKUP_IDX]}" -eq 1 ]
  [ "$GRAPH_SCHEDULE_USED_TOKEN_SLOTS" -eq 1 ]
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}
