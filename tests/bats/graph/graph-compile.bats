#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/plan-todo.sh"
export RALPH_RUN_PLAN_LIBRARY_ONLY=1
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/run-plan/run-plan-core.sh"
unset RALPH_RUN_PLAN_LIBRARY_ONLY
VALIDATE_GRAPH_SCHEMA_SH="$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/validate-graph-schema.sh"
GRAPH_RUN_SH="$BATS_TEST_DIRNAME/../../../bundle/.ralph/graph-run.sh"
GRAPH_TEMPLATE_MD="$BATS_TEST_DIRNAME/../../../bundle/.ralph/plan-templates/graph-consensus.plan.template.md"

json_payload() {
  printf '%s\n' "$1" | awk 'END{print}'
}

json_field() {
  printf '%s' "$1" | jq -r "$2"
}

canonical_ralph_version() {
  if [[ -n "${RALPH_VERSION:-}" ]]; then
    printf '%s\n' "$RALPH_VERSION"
    return 0
  fi

  for candidate in \
    "$REPO_ROOT/bundle/.ralph/VERSION" \
    "$REPO_ROOT/bundle/.ralph/version" \
    "$REPO_ROOT/VERSION"
  do
    if [[ -f "$candidate" ]]; then
      awk 'END{print}' "$candidate"
      return 0
    fi
  done

  git -C "$REPO_ROOT" describe --tags --always --dirty 2>/dev/null || printf '1.0.0\n'
}

@test "graph node stage matches build_orch_stage output byte for byte" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/graph-edges.plan.md"
  cp "$BATS_TEST_DIRNAME/../../fixtures/graph/graph-edges.plan.md" "$plan_file"

  run plan_pipeline_orch_json "$plan_file"
  [ "$status" -eq 0 ]
  orch_payload="$(json_payload "$output")"
  expected_stage="$(printf '%s' "$orch_payload" | jq -cS '.stages[] | select(.id=="source")')"

  run plan_pipeline_graph_json "$plan_file"
  [ "$status" -eq 0 ]
  graph_payload="$(json_payload "$output")"
  # Graph mode adds only its frozen delegation policy. The orchestration
  # projection itself remains byte-for-byte compatible with legacy .orch JSON.
  actual_stage="$(printf '%s' "$graph_payload" | jq -cS '.nodes[] | select(.id=="source") | .stage | del(.delegation)')"

  [ "$actual_stage" = "$expected_stage" ]
  rm -rf "$tmpd"
}

@test "graph consensus stages expand to three voters plus a barrier" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/graph-consensus.plan.md"
  cp "$BATS_TEST_DIRNAME/../../fixtures/graph/graph-consensus.plan.md" "$plan_file"

  run plan_pipeline_graph_json "$plan_file"
  [ "$status" -eq 0 ]
  payload="$(json_payload "$output")"

  [ "$(json_field "$payload" '.nodes | map(select(.derivedFrom=="consensus")) | length')" = "4" ]
  [ "$(json_field "$payload" '.nodes | map(select(.type=="consensus-voter")) | length')" = "3" ]
  [ "$(json_field "$payload" '.nodes | map(select(.type=="consensus-barrier")) | length')" = "1" ]
  [ "$(json_field "$payload" '.nodes | map(.id) | index("review")')" = "null" ]
  [ "$(json_field "$payload" '.nodes | map(.id) | index("review:barrier")')" != "null" ]
  rm -rf "$tmpd"
}

@test "graph json carries canonical ralphVersion and omits parallelStages" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/graph-edges.plan.md"
  cp "$BATS_TEST_DIRNAME/../../fixtures/graph/graph-edges.plan.md" "$plan_file"

  run plan_pipeline_graph_json "$plan_file"
  [ "$status" -eq 0 ]
  payload="$(json_payload "$output")"
  graph_node_count="$(json_field "$payload" '.nodes | length')"

  run plan_pipeline_orch_json "$plan_file"
  [ "$status" -eq 0 ]
  orch_payload="$(json_payload "$output")"

  [ "$(json_field "$payload" '.ralphVersion')" = "$(canonical_ralph_version)" ]
  [ "$(json_field "$payload" 'has("parallelStages")')" = "false" ]
  [ "$graph_node_count" = "$(json_field "$orch_payload" '.stages | length')" ]
  rm -rf "$tmpd"
}

@test "graph json validates for diamond and consensus fixtures" {
  tmpd="$(mktemp -d)"
  for fixture in graph-edges.plan.md graph-consensus.plan.md; do
    plan_file="$tmpd/$fixture"
    graph_file="$tmpd/${fixture%.plan.md}.graph.json"
    cp "$BATS_TEST_DIRNAME/../../fixtures/graph/$fixture" "$plan_file"
    run --separate-stderr plan_pipeline_graph_json "$plan_file"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" >"$graph_file"
    run bash "$VALIDATE_GRAPH_SCHEMA_SH" "$graph_file"
    [ "$status" -eq 0 ]
  done
  rm -rf "$tmpd"
}

@test "graph schema validator rejects missing required field and invalid references" {
  tmpd="$(mktemp -d)"

  cat <<'EOF' >"$tmpd/missing-field.graph.json"
{"schemaVersion":1,"ralphVersion":"1.0.0","name":"demo","namespace":"demo","maxParallel":2,"failurePolicy":"drain","edges":[]}
EOF
  run bash "$VALIDATE_GRAPH_SCHEMA_SH" "$tmpd/missing-field.graph.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing required field nodes"* ]]

  cat <<'EOF' >"$tmpd/unknown-node.graph.json"
{"schemaVersion":1,"ralphVersion":"1.0.0","name":"demo","namespace":"demo","maxParallel":2,"failurePolicy":"drain","nodes":[{"id":"n1","type":"weird","dependsOn":[],"derivedFrom":"stage","stage":{}}],"edges":[]}
EOF
  run bash "$VALIDATE_GRAPH_SCHEMA_SH" "$tmpd/unknown-node.graph.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"node n1: unknown node type weird"* ]]

  cat <<'EOF' >"$tmpd/absent-edge.graph.json"
{"schemaVersion":1,"ralphVersion":"1.0.0","name":"demo","namespace":"demo","maxParallel":2,"failurePolicy":"drain","nodes":[{"id":"n1","type":"stage","dependsOn":[],"derivedFrom":"stage","stage":{}},{"id":"n2","type":"stage","dependsOn":[],"derivedFrom":"stage","stage":{}}],"edges":[{"from":"n1","to":"missing","reasons":["test"]}]}
EOF
  run bash "$VALIDATE_GRAPH_SCHEMA_SH" "$tmpd/absent-edge.graph.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"edge n1 -> missing references absent node"* ]]

  cat <<'EOF' >"$tmpd/absent-depends.graph.json"
{"schemaVersion":1,"ralphVersion":"1.0.0","name":"demo","namespace":"demo","maxParallel":2,"failurePolicy":"drain","nodes":[{"id":"n1","type":"stage","dependsOn":["missing"],"derivedFrom":"stage","stage":{}}],"edges":[]}
EOF
  run bash "$VALIDATE_GRAPH_SCHEMA_SH" "$tmpd/absent-depends.graph.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"node n1 dependsOn references absent node"* ]]

  rm -rf "$tmpd"
}

@test "graph run CLI requires a verb and rejects an unknown one" {
  run bash "$GRAPH_RUN_SH"
  [ "$status" -ne 0 ]

  run bash "$GRAPH_RUN_SH" bogus-verb
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown graph verb"* ]]
}

@test "ralph graph compile matches the diamond fixture's declared shape with artifact-reasoned derived edges" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/graph-diamond.plan.md"
  cp "$BATS_TEST_DIRNAME/../../fixtures/graph/graph-diamond.plan.md" "$plan_file"

  run bash "$GRAPH_RUN_SH" compile "$plan_file"
  [ "$status" -eq 0 ]
  payload="$(json_payload "$output")"

  [ "$(json_field "$payload" '.nodes | length')" = "4" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="source") | .dependsOn | length')" = "0" ]
  [ "$(json_field "$payload" '(.nodes[] | select(.id=="left") | .dependsOn) == ["source"]')" = "true" ]
  [ "$(json_field "$payload" '(.nodes[] | select(.id=="right") | .dependsOn) == ["source"]')" = "true" ]
  [ "$(json_field "$payload" '(.nodes[] | select(.id=="sink") | .dependsOn | sort) == ["left","right"]')" = "true" ]
  [ "$(json_field "$payload" '[.edges[].reasons[] | select(startswith("artifact:"))] | length > 0')" = "true" ]

  [ -f "$tmpd/graph-diamond.graph.json" ]
  cached="$(cat "$tmpd/graph-diamond.graph.json")"
  [ "$(json_field "$cached" '.name')" != "" ]
  rm -rf "$tmpd"
}

@test "ralph graph compile expands the graph-consensus template into all five node shapes" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/graph-consensus.plan.template.md"
  cp "$GRAPH_TEMPLATE_MD" "$plan_file"

  run bash "$GRAPH_RUN_SH" compile "$plan_file"
  [ "$status" -eq 0 ]
  payload="$(json_payload "$output")"

  [ "$(json_field "$payload" '.nodes | map(select(.id=="research")) | length')" = "1" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="research") | .type')" = "agent" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="implement") | .stage.runtime')" != "$(json_field "$payload" '.nodes[] | select(.id=="research") | .stage.runtime')" ]
  [ "$(json_field "$payload" '.nodes | map(select(.type=="consensus-voter")) | length')" = "3" ]
  [ "$(json_field "$payload" '.nodes | map(select(.type=="consensus-barrier")) | length')" = "1" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="decide") | .type')" = "join" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="decide") | .stage.policy')" = "veto" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="human-checkpoint") | .type')" = "checkpoint" ]
  [ "$(json_field "$payload" '[.edges[].reasons[] | select(startswith("artifact:"))] | length > 0')" = "true" ]
  rm -rf "$tmpd"
}

@test "ralph graph compile fails on the cyclic fixture and names the cycle in traversal order" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/graph-cycle.plan.md"
  cp "$BATS_TEST_DIRNAME/../../fixtures/graph/graph-cycle.plan.md" "$plan_file"

  run bash "$GRAPH_RUN_SH" compile "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cycle detected: a -> b -> c -> a"* ]]
  [ ! -f "$tmpd/graph-cycle.graph.json" ]
  rm -rf "$tmpd"
}

@test "ralph graph compile --render exits cleanly against the Phase 7 stub" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/graph-edges.plan.md"
  cp "$BATS_TEST_DIRNAME/../../fixtures/graph/graph-edges.plan.md" "$plan_file"

  for fmt in mermaid dot ascii; do
    run bash "$GRAPH_RUN_SH" compile "$plan_file" --render "$fmt"
    [ "$status" -eq 0 ]
  done

  run bash "$GRAPH_RUN_SH" compile "$plan_file" --render bogus
  [ "$status" -ne 0 ]
  rm -rf "$tmpd"
}
