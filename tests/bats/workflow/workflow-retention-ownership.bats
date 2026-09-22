#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/retention.sh"

make_workflow() {
  local state="$1" id="$2" namespace="$3" status="$4" graph_status="$5"
  local registry="$state/workflow-runs/$id" graph="$state/graph-runs/$namespace/$id"
  mkdir -p "$registry" "$graph" "$state/artifacts/$namespace"
  jq -n --arg state "$status" --arg ns "$namespace" --arg path "$graph" \
    '{state:$state,artifactNamespace:$ns,engine:{statePath:$path}}' >"$registry/run.json"
  jq -n --arg status "$graph_status" --arg registry "$registry" \
    '{kind:"graph",status:$status,registryRunPath:$registry}' >"$graph/run.json"
}

@test "oversized artifacts at intermediate stage exit keep the outer run namespace" {
  local state; state="$(mktemp -d)"
  make_workflow "$state" live shared running running
  dd if=/dev/zero of="$state/artifacts/shared/blob" bs=1024 count=2 2>/dev/null
  run ralph_retention_prune_artifacts "$state/artifacts/shared" 0 1 "$state" shared
  [ "$output" = 0 ]; [ -d "$state/artifacts/shared" ]
}

@test "two workflows sharing a namespace, one terminal, keep it" {
  local state; state="$(mktemp -d)"
  make_workflow "$state" done shared succeeded succeeded
  make_workflow "$state" live shared running running
  run ralph_retention_eligibility "$state" artifact "$state/artifacts/shared" shared
  [ "$status" -ne 0 ]; [ "$output" = "nonterminal-workflow-run" ]
}

@test "a run waiting on a pending action keeps everything" {
  local state; state="$(mktemp -d)"
  make_workflow "$state" wait shared awaiting-operator awaiting-operator
  run ralph_retention_eligibility "$state" artifact "$state/artifacts/shared" shared
  [ "$status" -ne 0 ]
}

@test "an interrupted resumable graph run keeps its namespace and workspaces" {
  local state graph; state="$(mktemp -d)"; graph="$state/graph-runs/n/run"
  mkdir -p "$graph/workspaces/nodes/a"; printf '{"kind":"graph","status":"interrupted"}\n' >"$graph/run.json"
  run ralph_retention_eligibility "$state" graph-run "$graph" n
  [ "$status" -ne 0 ]; [ "$output" = "resumable-graph-run" ]; [ -d "$graph/workspaces" ]
}

@test "an unpublished failed candidate is protected" {
  local state; state="$(mktemp -d)"
  make_workflow "$state" failed shared failed failed
  run ralph_retention_eligibility "$state" artifact "$state/artifacts/shared" shared
  [ "$status" -ne 0 ]; [ "$output" = "unpublished-failed-candidate" ]
}

@test "a journal with unrestored originals is protected" {
  local state journal; state="$(mktemp -d)"; journal="$state/runtime-config/key/journals/j.json"
  mkdir -p "$(dirname "$journal")"; printf '{"mutated_files":[{"restored":false}]}\n' >"$journal"
  run ralph_retention_eligibility "$state" journal "$journal"
  [ "$status" -ne 0 ]; [ "$output" = "unrestored-originals" ]
}

@test "a run directory without run-manifest.json is protected with reason unknown-owner" {
  local state root; state="$(mktemp -d)"; root="$state/logs/shared/runs/open"
  mkdir -p "$root" "$state/artifacts/shared"
  run ralph_retention_eligibility "$state" artifact "$state/artifacts/shared" shared
  [ "$status" -ne 0 ]; [ "$output" = "unknown-owner" ]
}

@test "corrupt JSON is protected with reason corrupt-metadata" {
  local state root; state="$(mktemp -d)"; root="$state/logs/shared/runs/bad"
  mkdir -p "$root" "$state/artifacts/shared"; printf '{bad}\n' >"$root/run-manifest.json"
  run ralph_retention_eligibility "$state" artifact "$state/artifacts/shared" shared
  [ "$status" -ne 0 ]; [ "$output" = "corrupt-metadata" ]
}

@test "a standalone terminal run older than the age limit is pruned" {
  local state root; state="$(mktemp -d)"; root="$state/logs/key/runs"; mkdir -p "$root/old"
  printf '{"kind":"ralph_run_manifest","status":"complete"}\n' >"$root/old/run-manifest.json"
  touch -t 202001010000 "$root/old"
  ralph_retention_prune_dirs "$root" 10 1 "$state" plan-run >/dev/null
  [ ! -d "$root/old" ]
}

@test "a graph run written before the kind field existed is judged, not corrupt" {
  local state="$BATS_TEST_TMPDIR/state" legacy="$BATS_TEST_TMPDIR/state/graph-runs/ns/run-old" bad="$BATS_TEST_TMPDIR/state/graph-runs/ns/run-bad"
  mkdir -p "$legacy" "$bad"
  printf '{"schemaVersion":3,"runId":"run-old","graphSha":"abc","status":"succeeded"}\n' >"$legacy/run.json"
  printf '{"schemaVersion":3,"status":"succeeded"}\n' >"$bad/run.json"
  run ralph_retention_eligibility "$state" graph-run "$legacy"
  [ "$output" = eligible ]
  run ralph_retention_eligibility "$state" graph-run "$bad"
  [ "$output" = corrupt-metadata ]
}

@test "automatic retention prunes old terminal layout-2 runs as whole subtrees" {
  local state="$BATS_TEST_TMPDIR/state" old="$BATS_TEST_TMPDIR/state/runs/run-old" live="$BATS_TEST_TMPDIR/state/runs/run-live" mine="$BATS_TEST_TMPDIR/state/runs/run-mine"
  mkdir -p "$old/stages/plan/attempts/run-old" "$live" "$mine"
  printf '{"layoutVersion":2,"runId":"run-old","status":"complete"}\n' >"$old/run.json"
  printf '{"layoutVersion":2,"runId":"run-live","status":"running"}\n' >"$live/run.json"
  printf '{"layoutVersion":2,"runId":"run-mine","status":"complete"}\n' >"$mine/run.json"
  touch -t 202001010000 "$old" "$live" "$mine"
  RALPH_PROCESS_RUN_ID=run-mine RALPH_RETENTION_LOG_RUNS_MAX_AGE_DAYS=1 \
    ralph_retention_auto_prune "$state" leaf.plan >/dev/null
  [ ! -d "$old" ]
  [ -d "$live" ]
  [ -d "$mine" ]
}
