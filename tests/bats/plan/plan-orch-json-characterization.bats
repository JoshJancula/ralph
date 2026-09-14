#!/usr/bin/env bats

# Characterization test for the .orch.json shape produced from a structured plan.
# Compares the generated orchestration JSON against a committed golden snapshot so
# that future parser changes can prove existing output is unchanged.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

orchestrator="$REPO_ROOT/.ralph/orchestrator.sh"
golden="$REPO_ROOT/tests/fixtures/orchestration/orch-json-characterization.orch.json"
plan_fixture="$REPO_ROOT/tests/fixtures/orchestration/orch-json-characterization.plan.md"

setup() {
  WS="$(mktemp -d)"
}

teardown() {
  rm -rf "$WS"
}

@test "orchestrator produces unchanged .orch.json from structured plan fixture" {
  [[ -f "$plan_fixture" ]]
  [[ -f "$golden" ]]
  cp "$plan_fixture" "$WS/orch-json-characterization.plan.md"

  run env RALPH_ALLOW_NESTED_RUNS=1 ORCH_NORMALIZE_ONLY=1 ORCHESTRATOR_NO_COLOR=1 bash "$orchestrator" --orchestration "$WS/orch-json-characterization.plan.md" "$WS"
  [ "$status" -eq 0 ]

  gen="$WS/.ralph-workspace/orchestration-plans/orch-json-characterization/orch-json-characterization.orch.json"
  [ -f "$gen" ]

  ws_abs="$(cd "$WS" && pwd)"
  run diff <(jq -S . "$golden") <(jq --arg ws "$ws_abs" -S 'walk(if type == "string" and startswith($ws) then "{{WS}}" + .[$ws | length:] else . end)' "$gen")
  [ "$status" -eq 0 ]
}
