#!/usr/bin/env bats

# Fault-injection matrix for the opt-in graph-v2 composite success contract.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-composite-success.sh"

setup() {
  TMPD="$(mktemp -d)"
  WS="$TMPD/workspace"; STATE="$TMPD/state"; mkdir -p "$WS" "$STATE"
  PLAN="$TMPD/node.plan.md"; printf '%s\n' '- [x] completed work' >"$PLAN"
  GRAPH="$TMPD/graph.json"
  printf '%s\n' '{"namespace":"ns","nodes":[{"id":"node","stage":{"id":"node"}}],"edges":[],"verificationProfiles":[]}' >"$GRAPH"
  RUN="$TMPD/run.json"; printf '%s\n' '{"sourceBase":{"filesystemIdentity":"base"}}' >"$RUN"
  REPORT="$TMPD/report.json"
  printf '%s\n' '{"schemaVersion":1,"runId":"run","stageId":"node","attemptId":"node__run__1","outcome":"success","exitCode":0,"startedAt":"2026-01-01T00:00:00Z","finishedAt":"2026-01-01T00:00:01Z"}' >"$REPORT"
}
teardown() { rm -rf "$TMPD"; }

validate() {
  graph_composite_success_validate "$REPORT" "$GRAPH" "$RUN" node run node__run__1 "$WS" "$STATE" ns "$PLAN" "${1:-}"
}

@test "accepts only a complete, durable composite success" {
  validate
  [ -s "$STATE/artifacts/ns/composite-success/node/node__run__1.json" ]
  jq -e '.components | all(.[]; . == true or . == false)' "$STATE/artifacts/ns/composite-success/node/node__run__1.json" >/dev/null
}

@test "fault matrix rejects incomplete plan, pending human, malformed footer evidence, and missing changeset" {
  printf '%s\n' '- [ ] pending work' >"$PLAN"
  run validate; [ "$status" -ne 0 ]
  printf '%s\n' '- [x] completed work' >"$PLAN"

  mkdir -p "$STATE/sessions/ns-node"; : >"$STATE/sessions/ns-node/pending-human.txt"
  run validate; [ "$status" -ne 0 ]
  rm -f "$STATE/sessions/ns-node/pending-human.txt"

  sed 's/"success"/"failed"/' "$REPORT" >"$TMPD/bad-report.json"; mv "$TMPD/bad-report.json" "$REPORT"
  run validate; [ "$status" -ne 0 ]
  printf '%s\n' '{"schemaVersion":1,"runId":"run","stageId":"node","attemptId":"node__run__1","outcome":"success","exitCode":0,"startedAt":"2026-01-01T00:00:00Z","finishedAt":"2026-01-01T00:00:01Z"}' >"$REPORT"

  printf '%s\n' '{"namespace":"ns","nodes":[{"id":"node","stage":{"id":"node","writeScopes":["src/**"]}}],"edges":[],"verificationProfiles":[]}' >"$GRAPH"
  run validate; [ "$status" -ne 0 ]
}

@test "input changes invalidate a recorded success while stable inputs remain reusable" {
  mkdir -p "$STATE/artifacts/ns/exchange"
  printf original >"$STATE/artifacts/ns/exchange/input.json"
  printf '%s\n' '{"namespace":"ns","nodes":[{"id":"node","stage":{"id":"node","inputArtifacts":["input.json"]}}],"edges":[],"verificationProfiles":[]}' >"$GRAPH"
  validate
  graph_composite_success_reusable "$GRAPH" "$RUN" node run node__run__1 "$STATE" ns
  printf changed >"$STATE/artifacts/ns/exchange/input.json"
  run graph_composite_success_reusable "$GRAPH" "$RUN" node run node__run__1 "$STATE" ns
  [ "$status" -ne 0 ]
}
