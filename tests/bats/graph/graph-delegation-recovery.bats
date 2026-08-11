#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-schedule.sh"

setup() {
  TMPD="$(mktemp -d)"; WS="$TMPD/ws"; mkdir -p "$WS"
  export GRAPH_SCHEDULE_WORKSPACE="$WS" GRAPH_SCHEDULE_NAMESPACE=ns GRAPH_SCHEDULE_RUN_ID=run
}
teardown() { rm -rf "$TMPD"; }

_start() {
  graph_delegation_ledger_start "$WS" ns run parent attempt "$1" task '{"maxChildren":1}' codex research '' 1 snapshot '[]' ''
}

@test "recovery adopts a completed child outcome without redispatching it" {
  did="$(_start completed)"
  graph_delegation_queue_enqueue "$WS" ns run parent "$did" 1
  graph_delegation_ledger_transition "$WS" ns run parent "$did" succeeded child pass '{}' '{"resultArtifact":"result.json"}' ''
  graph_schedule_recover_delegated_children
  graph_delegation_ledger_read_status "$WS" ns run parent "$did" | jq -e '.status == "succeeded" and .finalResult.resultArtifact == "result.json"' >/dev/null
  run graph_delegation_queue_admit_one "$WS" ns run 1 1
  [ "$status" -eq 2 ]
}

@test "recovery only requeues a dead running child so its remaining plan is resumed" {
  did="$(_start retry)"
  graph_delegation_queue_enqueue "$WS" ns run parent "$did" 1
  graph_delegation_ledger_transition "$WS" ns run parent "$did" running old '' '{}' null ''
  graph_delegation_child_record_process "$WS" ns run parent "$did" 999999 999999
  plan="$(graph_delegation_ledger_plan_file "$WS" ns run parent "$did")"; printf '%s\n' '- [x] done' '- [ ] remaining' >"$plan"
  graph_schedule_recover_delegated_children
  graph_delegation_ledger_read_status "$WS" ns run parent "$did" | jq -e '.status == "queued"' >/dev/null
  grep -q '^- \[ \] remaining' "$plan"
}

@test "child cancellation kills only the child session and leaves parent alive" {
  did="$(_start cancel)"
  graph_delegation_ledger_transition "$WS" ns run parent "$did" running child '' '{}' null ''
  ( sleep 30 ) & child=$!
  process_file="$(graph_delegation_ledger_process_file "$WS" ns run parent "$did")"
  ralph_atomic_write_json "$process_file" '{pid:$pid,pgid:0}' --argjson pid "$child"
  ( sleep 30 ) & parent=$!
  graph_delegation_child_cancel "$WS" ns run parent "$did"
  ! kill -0 "$child" 2>/dev/null
  kill -0 "$parent" 2>/dev/null
  kill "$parent" 2>/dev/null || true
}
