#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-delegation-ledger.sh"

setup() { TMPD="$(mktemp -d)"; WS="$TMPD/ws"; mkdir -p "$WS"; }
teardown() { rm -rf "$TMPD"; }

start_child() {
  graph_delegation_ledger_start "$WS" ns run-1 parent parent-attempt-1 key-1 'inspect files' \
    '{"maxDepth":1,"crossRuntime":{"mode":"read-only"}}' claude research claude-test 1 snapshot \
    '["artifacts/ns/child-result.json"]' $'---\ntodos:\n  - [ ] inspect\n'
}

@test "start writes immutable child ledger schema and idempotently returns it" {
  local did again dir
  did="$(start_child)"; [ -n "$did" ]
  again="$(start_child)"; [ "$again" = "$did" ]
  dir="$(graph_delegation_ledger_dir "$WS" ns run-1 parent "$did")"
  [ -f "$dir/request.json" ]; [ -f "$dir/policy.json" ]; [ -f "$dir/child.plan.md" ]; [ -f "$dir/status.json" ]
  [ "$(jq -r .status "$dir/status.json")" = queued ]
  [ "$(jq -r .requestFingerprint "$dir/request.json")" != null ]
  [ "$(jq -r .depth "$dir/request.json")" = 1 ]
}

@test "same idempotency key with changed task or policy is rejected" {
  start_child >/dev/null
  run graph_delegation_ledger_start "$WS" ns run-1 parent parent-attempt-1 key-1 'different task' '{"maxDepth":1}' claude research claude-test 1 snapshot '[]' plan
  [ "$status" -ne 0 ]; [[ "$output" == *idempotency* ]]
}

@test "simultaneous duplicate starts publish one durable child record" {
  local one two
  (start_child >"$TMPD/one") & one=$!
  (start_child >"$TMPD/two") & two=$!
  wait "$one"; wait "$two"
  [ "$(cat "$TMPD/one")" = "$(cat "$TMPD/two")" ]
  graph_delegation_ledger_read_status "$WS" ns run-1 parent "$(cat "$TMPD/one")" | jq -e '.status == "queued"' >/dev/null
}

@test "every status transition is atomic, readable, and aggregates usage" {
  local did status
  did="$(start_child)"
  for state in running succeeded failed cancelled awaiting-ack queued; do
    graph_delegation_ledger_transition "$WS" ns run-1 parent "$did" "$state" "a-$state" pass '{"inputTokens":2,"outputTokens":3}' '{"kind":"result"}' reason
    status="$(graph_delegation_ledger_read_status "$WS" ns run-1 parent "$did")"
    [ "$(printf '%s' "$status" | jq -r .status)" = "$state" ]
  done
  status="$(graph_delegation_ledger_read_status "$WS" ns run-1 parent "$did")"
  [ "$(printf '%s' "$status" | jq '.attempts | length')" = 6 ]
  [ "$(printf '%s' "$status" | jq -r .usage.inputTokens)" = 12 ]
  [ "$(printf '%s' "$status" | jq -r .usage.outputTokens)" = 18 ]
}

@test "concurrent status reads never observe malformed JSON" {
  local did status_file stop bad reader
  did="$(start_child)"; status_file="$(graph_delegation_ledger_status_file "$WS" ns run-1 parent "$did")"; stop="$TMPD/stop"; bad="$TMPD/bad"
  (while [ ! -f "$stop" ]; do jq -e . "$status_file" >/dev/null 2>&1 || touch "$bad"; done) & reader=$!
  for i in $(seq 1 25); do graph_delegation_ledger_transition "$WS" ns run-1 parent "$did" running "a-$i" '' '{"tokens":1}' null '' ; done
  touch "$stop"; wait "$reader"
  [ ! -f "$bad" ]; [ "$(jq -r .usage.tokens "$status_file")" = 25 ]
}

@test "missing and corrupt records fail closed and durable records survive process death" {
  local did dir
  did="$(start_child)"; dir="$(graph_delegation_ledger_dir "$WS" ns run-1 parent "$did")"
  (graph_delegation_ledger_transition "$WS" ns run-1 parent "$did" running a1 pass '{"tokens":1}' null '' ; kill -9 "$BASHPID") || true
  graph_delegation_ledger_read_status "$WS" ns run-1 parent "$did" | jq -e '.status == "running"' >/dev/null
  rm "$dir/status.json"; run graph_delegation_ledger_read_status "$WS" ns run-1 parent "$did"; [ "$status" -ne 0 ]
  start_child >/dev/null; printf '{bad' >"$dir/request.json"
  run start_child; [ "$status" -ne 0 ]
}

@test "delegation ledger writes its required log" {
  start_child >/dev/null
  [ -f "$WS/.ralph-workspace/logs/delegation-ledger.log" ]
  grep -q 'delegation=' "$WS/.ralph-workspace/logs/delegation-ledger.log"
}

@test "delegation logs honor an external state root" {
  local external="$TMPD/external-state"
  source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-delegation-queue.sh"
  source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-delegation-runner.sh"
  export RALPH_PLAN_WORKSPACE_ROOT="$external"
  start_child >/dev/null
  graph_delegation_queue_log "$WS" "external queue"
  graph_delegation_runner_log "$WS" "external runner"
  [ -f "$external/logs/delegation-ledger.log" ]
  [ -f "$external/logs/delegation-queue.log" ]
  [ -f "$external/logs/delegated-child-runner.log" ]
  [ ! -e "$WS/.ralph-workspace/logs" ]
}
