#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-delegation-completion.sh"
source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-delegation-runner.sh"
source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-delegation-queue.sh"
source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-schedule.sh"

setup() {
  TMPD="$(mktemp -d)"; WS="$TMPD/ws"; ART="$TMPD/artifacts"; mkdir -p "$WS" "$ART"
  NS=ns; RUN=run; PARENT=parent; ATTEMPT=attempt-1
  export GRAPH_SCHEDULE_WORKSPACE="$WS" GRAPH_SCHEDULE_NAMESPACE="$NS" GRAPH_SCHEDULE_RUN_ID="$RUN"
}
teardown() { rm -rf "$TMPD"; }

request() {
  local id="$1" mode="${2:-read-only}"
  jq -cn --arg id "$id" --arg mode "$mode" '{delegatedRunId:$id,task:"inspect files",idempotencyKey:$id,runtime:"codex",mode:$mode,artifactPaths:[]}'
}

start_child() {
  local id="$1" mode="${2:-read-only}"
  graph_delegation_ledger_start "$WS" "$id" "$(request "$id" "$mode")" >/dev/null
  graph_delegation_queue_enqueue "$WS" "$NS" "$RUN" "$PARENT" "$id" 4 2 >/dev/null
}

terminal_result() {
  local id="$1" result="$2"
  graph_delegation_ledger_transition "$WS" "$id" running child-run pass '{}' null >/dev/null
  graph_delegation_ledger_transition "$WS" "$id" succeeded child-run pass '{}' "$result" >/dev/null
}

result_file() { printf '%s/.ralph-workspace/delegated-runs/%s/result-artifact.json\n' "$WS" "$1"; }

@test "restart adopts only a terminal succeeded run with verified result evidence" {
  id=delegated-run-0123456789abcdef01234567; start_child "$id"
  path="$(result_file "$id")"; mkdir -p "$(dirname "$path")"; printf '%s\n' ok >"$path"
  terminal_result "$id" "$(jq -cn --arg p "$path" '{resultArtifact:$p}')"
  graph_schedule_recover_delegated_children
  run graph_delegation_queue_admit_one "$WS" "$NS" "$RUN" 1 1
  [ "$status" -eq 2 ]
  graph_delegation_completion_gate "$WS" "$NS" "$RUN" "$PARENT" "$ATTEMPT" "$ART"
  [ "$(jq length "$ART/input-artifacts.json")" -eq 1 ]
}

@test "missing result evidence blocks parent completion and is not adopted" {
  id=delegated-run-1123456789abcdef01234567; start_child "$id"
  path="$(result_file "$id")"
  terminal_result "$id" "$(jq -cn --arg p "$path" '{resultArtifact:$p}')"
  graph_schedule_recover_delegated_children
  run graph_delegation_completion_gate "$WS" "$NS" "$RUN" "$PARENT" "$ATTEMPT" "$ART"
  [ "$status" -eq 10 ]
}

@test "every declared artifact must have a durable nonempty handoff" {
  id=delegated-run-8123456789abcdef01234567
  declared="$WS/.ralph-workspace/delegated-runs/$id/artifacts/out.json"
  req="$(jq -cn --arg id "$id" '{delegatedRunId:$id,task:"inspect files",idempotencyKey:$id,runtime:"codex",mode:"read-only",artifactPaths:["out.json"]}')"
  graph_delegation_ledger_start "$WS" "$id" "$req" >/dev/null
  graph_delegation_queue_enqueue "$WS" "$NS" "$RUN" "$PARENT" "$id" 4 2 >/dev/null
  mkdir -p "$(dirname "$declared")"; printf '%s\n' artifact >"$declared"
  terminal_result "$id" "$(jq -cn --arg p "$declared" '{resultArtifact:$p,declaredArtifacts:[{declaredPath:"out.json",artifactPath:$p}]}')"
  graph_delegation_completion_gate "$WS" "$NS" "$RUN" "$PARENT" "$ATTEMPT" "$ART"
  [ "$(jq length "$ART/input-artifacts.json")" -eq 1 ]
}

@test "queued and failed or cancelled children prevent normal parent completion" {
  queued=delegated-run-2123456789abcdef01234567; failed=delegated-run-3123456789abcdef01234567; cancelled=delegated-run-4123456789abcdef01234567
  start_child "$queued"; start_child "$failed"; start_child "$cancelled"
  graph_delegation_ledger_transition "$WS" "$failed" running >/dev/null
  graph_delegation_ledger_transition "$WS" "$failed" failed child fail '{}' null failure >/dev/null
  graph_delegation_ledger_transition "$WS" "$cancelled" cancelled queue-cancel cancel '{}' null cancelled >/dev/null
  run graph_delegation_completion_gate "$WS" "$NS" "$RUN" "$PARENT" "$ATTEMPT" "$ART"
  [ "$status" -eq 12 ]
}

@test "orphaned running child is requeued on restart without minting another id" {
  id=delegated-run-5123456789abcdef01234567; start_child "$id"
  graph_delegation_ledger_transition "$WS" "$id" running child-run >/dev/null
  graph_delegation_child_record_process "$WS" "$id" 999999 999999
  graph_schedule_recover_delegated_children
  [ "$(graph_delegation_ledger_read_status "$WS" "$id" | jq -r .status)" = queued ]
  [ "$(jq length "$(graph_delegation_queue_file "$WS" "$NS" "$RUN")")" -eq 1 ]
}

@test "parent cancellation propagates to the child process" {
  id=delegated-run-6123456789abcdef01234567; start_child "$id"
  graph_delegation_ledger_transition "$WS" "$id" running child-run >/dev/null
  (sleep 30) & child=$!
  graph_delegation_child_record_process "$WS" "$id" "$child" 0
  graph_delegation_queue_cancel_parent "$WS" "$NS" "$RUN" "$PARENT" "parent cancelled" >/dev/null
  ! kill -0 "$child" 2>/dev/null
  [ "$(graph_delegation_ledger_read_status "$WS" "$id" | jq -r .status)" = cancelled ]
}

@test "changeset adoption requires verified changeset and integration evidence" {
  id=delegated-run-7123456789abcdef01234567; start_child "$id" changeset
  result="$(result_file "$id")"; changeset="$WS/.ralph-workspace/delegated-runs/$id/changeset.json"; integration="$WS/.ralph-workspace/delegated-runs/$id/integration.json"
  mkdir -p "$(dirname "$result")"; printf result >"$result"
  printf '%s\n' '{"schemaVersion":1,"kind":"graph-changeset","writeScopes":["src/**"],"laneVerification":{"status":"passed"}}' >"$changeset"
  printf '%s\n' '{"schemaVersion":1,"kind":"graph-integration","changeCount":0}' >"$integration"
  terminal_result "$id" "$(jq -cn --arg r "$result" --arg c "$changeset" --arg i "$integration" '{resultArtifact:$r,changesetArtifact:$c,integrationResult:$i,integrated:true}')"
  graph_delegation_completion_gate "$WS" "$NS" "$RUN" "$PARENT" "$ATTEMPT" "$ART"
  [ "$(jq length "$ART/integration-inputs.json")" -eq 1 ]
}
