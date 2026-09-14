#!/usr/bin/env bats

# Fault-injection matrix for the opt-in graph-v2 composite success contract.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-composite-success.sh"
source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-schedule.sh"

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

write_denied_diagnostic_report() {
  local essential="${1:-false}"
  jq -n --argjson essential "$essential" '
    {
      schemaVersion: 1,
      runId: "run",
      stageId: "node",
      attemptId: "node__run__1",
      outcome: "failed",
      exitCode: 4,
      startedAt: "2026-01-01T00:00:00Z",
      finishedAt: "2026-01-01T00:00:01Z",
      diagnostic: {essential: $essential, decision: "deny", kind: "diagnostic"}
    }
  ' >"$REPORT"
}

accept_denied_diagnostic() {
  graph_schedule_try_accept_denied_nonessential_diagnostic \
    "$REPORT" "$GRAPH" "$RUN" node run node__run__1 "$WS" "$STATE" ns "$PLAN" "${1:-}"
}

@test "composite success diagnostic denial keeps succeeded node after completion" {
  write_denied_diagnostic_report false
  accept_denied_diagnostic
  record="$STATE/artifacts/ns/composite-success/node/node__run__1.json"
  [ -s "$record" ]
  jq -e '.components | all(.[]; . == true or . == false)' "$record" >/dev/null
  [ "$(jq -r '.diagnosticEvidence.denied' "$record")" = "true" ]
  [ "$(jq -r '.diagnosticEvidence.essential' "$record")" = "false" ]
  [ "$(jq -r '.diagnosticEvidence.decision' "$record")" = "deny" ]
  [ "$(jq -r '.diagnosticEvidence.kind' "$record")" = "diagnostic" ]
  graph_composite_success_reusable "$GRAPH" "$RUN" node run node__run__1 "$STATE" ns
}

@test "composite success diagnostic denial does not apply before completion" {
  write_denied_diagnostic_report false
  printf '%s\n' '- [ ] pending work' >"$PLAN"
  run accept_denied_diagnostic
  [ "$status" -ne 0 ]
  [ ! -e "$STATE/artifacts/ns/composite-success/node/node__run__1.json" ]

  printf '%s\n' '- [x] completed work' >"$PLAN"
  mkdir -p "$STATE/sessions/ns-node"
  : >"$STATE/sessions/ns-node/pending-human.txt"
  run accept_denied_diagnostic
  [ "$status" -ne 0 ]
  [ ! -e "$STATE/artifacts/ns/composite-success/node/node__run__1.json" ]
}

@test "composite success diagnostic denial does not apply to essential or ordinary permission denials" {
  write_denied_diagnostic_report true
  run accept_denied_diagnostic
  [ "$status" -ne 0 ]
  [ ! -e "$STATE/artifacts/ns/composite-success/node/node__run__1.json" ]

  printf '%s\n' '{"schemaVersion":1,"runId":"run","stageId":"node","attemptId":"node__run__1","outcome":"failed","exitCode":4,"startedAt":"2026-01-01T00:00:00Z","finishedAt":"2026-01-01T00:00:01Z","permissionRequest":{"tool":"Bash","decision":"deny"}}' >"$REPORT"
  run accept_denied_diagnostic
  [ "$status" -ne 0 ]
  [ ! -e "$STATE/artifacts/ns/composite-success/node/node__run__1.json" ]
}

@test "composite success diagnostic denial records denial on already satisfied success" {
  validate
  record="$STATE/artifacts/ns/composite-success/node/node__run__1.json"
  [ -s "$record" ]
  write_denied_diagnostic_report false
  graph_schedule_record_diagnostic_denial "$record" "$REPORT" "$REPORT"
  [ "$(jq -r '.diagnosticEvidence.denied' "$record")" = "true" ]
  [ "$(jq -r '.diagnosticEvidence.decision' "$record")" = "deny" ]
  jq -e '.components | all(.[]; . == true or . == false)' "$record" >/dev/null
  graph_composite_success_reusable "$GRAPH" "$RUN" node run node__run__1 "$STATE" ns
}
