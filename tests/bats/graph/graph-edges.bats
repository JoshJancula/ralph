#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/plan-todo.sh"
export RALPH_RUN_PLAN_LIBRARY_ONLY=1
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/run-plan/run-plan-core.sh"
unset RALPH_RUN_PLAN_LIBRARY_ONLY

json_field() {
  printf '%s' "$1" | jq -r "$2"
}

json_payload() {
  printf '%s\n' "$1" | awk 'END{print}'
}

@test "plan_pipeline_orch_json warns on every zero-inbound node" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/graph-zero-inbound.plan.md"
  cp "$BATS_TEST_DIRNAME/../../fixtures/graph/graph-zero-inbound.plan.md" "$plan_file"

  run plan_pipeline_orch_json "$plan_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Warning: zero-inbound nodes: alpha, beta, delta"* ]]
  rm -rf "$tmpd"
}

@test "plan_pipeline_orch_json promotes zero-inbound nodes to an error in strict mode" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/graph-zero-inbound-strict.plan.md"
  cp "$BATS_TEST_DIRNAME/../../fixtures/graph/graph-zero-inbound.plan.md" "$plan_file"
  python3 - "$plan_file" <<'PYTHON'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
path.write_text(text.replace("pipeline:\n", "pipeline:\n  strictEdges: true\n", 1))
PYTHON

  run plan_pipeline_orch_json "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Error: zero-inbound nodes: alpha, beta, delta"* ]]
  rm -rf "$tmpd"
}

@test "plan_pipeline_orch_json emits no zero-inbound warning for a single-root graph" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/graph-single-root.plan.md"
  cp "$BATS_TEST_DIRNAME/../../fixtures/graph/graph-edges.plan.md" "$plan_file"

  run plan_pipeline_orch_json "$plan_file"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Warning: zero-inbound nodes:"* ]]
  rm -rf "$tmpd"
}

@test "plan_pipeline_orch_json reports external preconditions" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/graph-zero-inbound.plan.md"
  cp "$BATS_TEST_DIRNAME/../../fixtures/graph/graph-zero-inbound.plan.md" "$plan_file"

  run plan_pipeline_orch_json "$plan_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Warning: external preconditions: external/input.md (consumer delta)"* ]]
  payload="$(json_payload "$output")"
  [ "$(json_field "$payload" '.externalPreconditions | length')" = "1" ]
  [ "$(json_field "$payload" '.externalPreconditions[0].path')" = "external/input.md" ]
  [ "$(json_field "$payload" '.externalPreconditions[0].consumer')" = "delta" ]
  rm -rf "$tmpd"
}
