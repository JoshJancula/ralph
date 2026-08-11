#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-delegation-completion.sh"

setup() {
  TMPD="$(mktemp -d)"; WS="$TMPD/ws"; ART="$TMPD/artifacts"; mkdir -p "$WS" "$ART"
  POLICY='{"maxChildren":4,"crossRuntime":{"mode":"read-only"}}'
}
teardown() { rm -rf "$TMPD"; }

child() {
  graph_delegation_ledger_start "$WS" ns run parent attempt-1 "$1" task "$POLICY" claude research '' 1 snapshot '[]' ''
}
success() {
  local did="$1" path=".ralph-workspace/artifacts/ns/delegated/$1/result.json"
  mkdir -p "$WS/$(dirname "$path")"; printf result >"$WS/$path"
  graph_delegation_ledger_transition "$WS" ns run parent "$did" succeeded child pass '{}' "$(jq -cn --arg p "$path" '{resultArtifact:$p}')" ''
}
gate() { graph_delegation_completion_gate "$WS" ns run parent attempt-1 "$ART"; }

@test "completion footer before queued child finish is blocked without artifacts" {
  child key-queued >/dev/null
  run gate
  [ "$status" -eq 10 ]
  [ ! -e "$ART/input-artifacts.json" ]
}

@test "successful read-only child becomes a parent input artifact" {
  did="$(child key-success)"; success "$did"
  gate
  jq -e --arg d "$did" '.[] | select(.delegationId == $d and .resultArtifact)' "$ART/input-artifacts.json" >/dev/null
  [ -f "$ART/integration-inputs.json" ]
}

@test "missing child result blocks completion after child success" {
  did="$(child key-missing)"
  graph_delegation_ledger_transition "$WS" ns run parent "$did" succeeded child pass '{}' '{}' ''
  run gate
  [ "$status" -eq 10 ]
}

@test "failed child requires a durable acknowledgement before parent completion" {
  did="$(child key-failed)"
  graph_delegation_ledger_transition "$WS" ns run parent "$did" failed child fail '{}' null 'verification failure'
  run gate
  [ "$status" -eq 11 ]
  graph_delegation_ledger_acknowledge "$WS" ns run parent "$did" result-read
  gate
}

@test "bounded child exhaustion creates a pending-human completion result" {
  did="$(child key-exhausted)"
  graph_delegation_ledger_transition "$WS" ns run parent "$did" failed child fail '{}' null 'retry exhaustion'
  run gate
  [ "$status" -eq 12 ]
}

@test "cancelled child is explicitly acknowledged and does not block completion" {
  did="$(child key-cancelled)"
  graph_delegation_ledger_transition "$WS" ns run parent "$did" cancelled child '' '{}' null 'cancelled by parent'
  gate
}

@test "out-of-order child completions remain blocked until every result is available" {
  one="$(child key-one)"; two="$(child key-two)"; success "$two"
  run gate
  [ "$status" -eq 10 ]
  success "$one"; gate
  [ "$(jq length "$ART/input-artifacts.json")" -eq 2 ]
}

@test "same attempt reuses an idempotent successful result and changesets stay integration-only" {
  POLICY='{"maxChildren":4,"crossRuntime":{"mode":"changeset"}}'
  did="$(child key-idempotent)"; same="$(child key-idempotent)"; [ "$did" = "$same" ]
  result="$WS/.ralph-workspace/artifacts/ns/delegated/$did/result.json"
  changeset="$WS/.ralph-workspace/artifacts/ns/delegated/$did/changeset.json"
  integration="$WS/.ralph-workspace/artifacts/ns/delegated/$did/integration.json"
  mkdir -p "$(dirname "$result")"; printf result >"$result"; printf '{}' >"$changeset"; printf '{}' >"$integration"
  graph_delegation_ledger_transition "$WS" ns run parent "$did" succeeded child pass '{}' \
    "$(jq -cn --arg r "$result" --arg c "$changeset" --arg i "$integration" '{resultArtifact:$r,changesetArtifact:$c,integrationResult:$i,integrated:true}')" ''
  gate
  jq -e --arg d "$did" '.[] | select(.delegationId == $d and .apply == "scheduler-integrated")' "$ART/integration-inputs.json" >/dev/null
  [ "$(jq length "$ART/input-artifacts.json")" -eq 0 ]
}
