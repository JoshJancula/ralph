#!/usr/bin/env bats

# G18: the machine-readable authoring contract is consumed by the graph
# parser, and every public pipeline field is either preserved or rejected.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/plan-todo.sh"

CONTRACT="$REPO_ROOT/bundle/.ralph/schemas/graph-authoring-contract.json"

setup() {
  TMPD="$(mktemp -d)"
  PLAN="$TMPD/authoring.plan.md"
}

teardown() {
  rm -rf "$TMPD"
}

write_authoring_plan() {
  local fields="${1:-}"
  {
    printf '%s\n' '---' 'name: authoring-roundtrip' 'execution: graph' 'pipeline:'
    if [[ -n "$fields" ]]; then
      printf '%s\n' "$fields"
    fi
    printf '%s\n' \
      '  stages:' \
      '    - id: source' \
      '      runtime: cursor' \
      '      instructions: Research the task and write findings.' \
      '    - id: sink' \
      '      runtime: codex' \
      '      instructions: Implement the change end to end.' \
      '      dependsOn: [source]' \
      'todos:' \
      '  - id: source-work' \
      '    stage: source' \
      '    content: create input' \
      '    status: pending' \
      '  - id: sink-work' \
      '    stage: sink' \
      '    content: consume input' \
      '    status: pending' \
      '---'
  } >"$PLAN"
}

@test "G18 contract defaults are the graph compiler defaults" {
  [ -f "$CONTRACT" ]
  write_authoring_plan

  run plan_pipeline_graph_json "$PLAN"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e --slurpfile contract "$CONTRACT" '
    .maxParallel == $contract[0].defaults.maxParallel and
    .edgeDerivation == $contract[0].defaults.edgeDerivation and
    .failurePolicy == $contract[0].defaults.failurePolicy and
    .publishMode == $contract[0].defaults.publishMode and
    .strictEdges == $contract[0].pipelineFields.strictEdges.default
  ' >/dev/null
}

@test "G18 public pipeline fields round-trip without being dropped" {
  write_authoring_plan $'  maxParallel: 4\n  edgeDerivation: declared\n  failurePolicy: cancel\n  strictEdges: true\n  publishMode: on-verified'

  run plan_pipeline_graph_json "$PLAN"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '
    .maxParallel == 4 and
    .edgeDerivation == "declared" and
    .failurePolicy == "cancel" and
    .strictEdges == true and
    .publishMode == "on-verified"
  ' >/dev/null
}

@test "G18 invalid public pipeline fields fail with precise migration guidance" {
  local case_row fields expected
  while IFS='|' read -r fields expected; do
    write_authoring_plan "$fields"
    run plan_pipeline_graph_json "$PLAN"
    [ "$status" -ne 0 ]
    [[ "$output" == *"$expected"* ]]
  done <<'CASES'
  maxParallel: 0|maxParallel must be an integer greater than or equal to 1
  edgeDerivation: sideways|invalid edgeDerivation value
  failurePolicy: continue|invalid failurePolicy value
  strictEdges: yes|invalid boolean value 'yes'
  publishMode: automatic|invalid publishMode value
CASES
}

@test "G18 contract enumerates every wizard-authored node type" {
  jq -e '
    (.nodeTypes | keys | sort) ==
    (["agent", "approval", "checkpoint", "consensus", "gate", "integrate", "join", "router"] | sort)
  ' "$CONTRACT" >/dev/null
}
