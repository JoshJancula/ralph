#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

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
  # projection remains byte-for-byte compatible with orchestration JSON.
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
{"schemaVersion":2,"ralphVersion":"1.0.0","name":"demo","namespace":"demo","maxParallel":2,"failurePolicy":"drain","edges":[]}
EOF
  run bash "$VALIDATE_GRAPH_SCHEMA_SH" "$tmpd/missing-field.graph.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing required field nodes"* ]]

  cat <<'EOF' >"$tmpd/unknown-node.graph.json"
{"schemaVersion":2,"ralphVersion":"1.0.0","name":"demo","namespace":"demo","maxParallel":2,"failurePolicy":"drain","nodes":[{"id":"n1","type":"weird","dependsOn":[],"derivedFrom":"stage","stage":{}}],"edges":[]}
EOF
  run bash "$VALIDATE_GRAPH_SCHEMA_SH" "$tmpd/unknown-node.graph.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"node n1: unknown node type weird"* ]]

  cat <<'EOF' >"$tmpd/absent-edge.graph.json"
{"schemaVersion":2,"ralphVersion":"1.0.0","name":"demo","namespace":"demo","maxParallel":2,"failurePolicy":"drain","nodes":[{"id":"n1","type":"stage","dependsOn":[],"derivedFrom":"stage","stage":{}},{"id":"n2","type":"stage","dependsOn":[],"derivedFrom":"stage","stage":{}}],"edges":[{"from":"n1","to":"missing","reasons":["test"]}]}
EOF
  run bash "$VALIDATE_GRAPH_SCHEMA_SH" "$tmpd/absent-edge.graph.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"edge n1 -> missing references absent node"* ]]

  cat <<'EOF' >"$tmpd/absent-depends.graph.json"
{"schemaVersion":2,"ralphVersion":"1.0.0","name":"demo","namespace":"demo","maxParallel":2,"failurePolicy":"drain","nodes":[{"id":"n1","type":"stage","dependsOn":["missing"],"derivedFrom":"stage","stage":{}}],"edges":[]}
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


@test "agent node role: roleless ordinary agent omits role and agent" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/graph-agent-roleless.plan.md"
  cp "$BATS_TEST_DIRNAME/../../fixtures/graph/graph-agent-roleless.plan.md" "$plan_file"
  expected="$BATS_TEST_DIRNAME/../../fixtures/graph/graph-agent-roleless-compiled.stage.json"

  run plan_pipeline_graph_json "$plan_file"
  [ "$status" -eq 0 ]
  payload="$(json_payload "$output")"

  [ "$(json_field "$payload" '.nodes[] | select(.id=="source") | .type')" = "agent" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="source") | .stage | has("role")')" = "false" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="source") | .stage | has("agent")')" = "false" ]

  actual="$(printf '%s' "$payload" | jq -cS '
    .nodes[] | select(.id=="source") | .stage
    | del(.delegation)
  ')"
  expected_json="$(jq -cS '.' "$expected")"
  [ "$actual" = "$expected_json" ]

  graph_file="$tmpd/graph-agent-roleless.graph.json"
  printf '%s\n' "$payload" >"$graph_file"
  run bash "$VALIDATE_GRAPH_SCHEMA_SH" "$graph_file"
  [ "$status" -eq 0 ]
  rm -rf "$tmpd"
}


@test "type agent: defaults omitted stage type to agent" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/graph-agent-roleless.plan.md"
  cp "$BATS_TEST_DIRNAME/../../fixtures/graph/graph-agent-roleless.plan.md" "$plan_file"

  run plan_pipeline_graph_json "$plan_file"
  [ "$status" -eq 0 ]
  payload="$(json_payload "$output")"
  [ "$(json_field "$payload" '.nodes[] | select(.id=="source") | .type')" = "agent" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="source") | .stage | has("type")')" = "false" ]
  rm -rf "$tmpd"
}

@test "type agent: preserves explicit type agent" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/explicit-agent-type.plan.md"
  cat >"$plan_file" <<'EOF'
---
execution: graph
pipeline:
  stages:
    - id: source
      type: agent
      runtime: cursor
todos:
  - id: source-1
    stage: source
    content: do work
    status: pending
---
EOF

  run plan_pipeline_graph_json "$plan_file"
  [ "$status" -eq 0 ]
  payload="$(json_payload "$output")"
  [ "$(json_field "$payload" '.nodes[] | select(.id=="source") | .type')" = "agent" ]
  rm -rf "$tmpd"
}

@test "removed stage agent: rejects profile-selecting agent with migration guidance" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/removed-agent.plan.md"
  cat >"$plan_file" <<'EOF'
---
execution: graph
pipeline:
  stages:
    - id: source
      runtime: cursor
      agent: research
todos:
  - id: source-1
    stage: source
    content: do work
    status: pending
---
EOF

  run plan_pipeline_graph_json "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"stage source agent:"* ]] || [[ "$output" == *"agent: was removed"* ]]
  [[ "$output" == *"instructions: text"* ]]
  rm -rf "$tmpd"
}

@test "removed stage agent: rejects agentSource with migration guidance" {
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/removed-agent-source.plan.md"
  cat >"$plan_file" <<'EOF'
---
execution: graph
pipeline:
  stages:
    - id: source
      runtime: cursor
      agentSource: /tmp/custom.md
todos:
  - id: source-1
    stage: source
    content: do work
    status: pending
---
EOF

  run plan_pipeline_graph_json "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"agentSource"* ]]
  [[ "$output" == *"instructions: text"* ]]
  rm -rf "$tmpd"
}







@test "removed role field: every supervisor node type refuses a stale role" {
  # role: was removed from the plan schema; it is now refused everywhere with one
  # message naming inline workflow instructions, not per-node-type guidance.
  local fixture stage_id
  tmpd="$(mktemp -d)"
  for fixture in integrate:merge join:decide gate:check checkpoint:wait router:route; do
    stage_id="${fixture#*:}"
    plan_file="$tmpd/reject-${fixture%%:*}.plan.md"
    cp "$BATS_TEST_DIRNAME/../../fixtures/graph/graph-supervisor-role-reject-${fixture%%:*}.plan.md" "$plan_file"
    run plan_pipeline_graph_json "$plan_file"
    [ "$status" -ne 0 ]
    [[ "$output" == *"role: was removed"* ]]
    [[ "$output" == *"instructions: text"* ]]
  done
  rm -rf "$tmpd"
}

# --- planFrom projection / frozen planner binding (ordinary consumer) ---

GRAPH_COMPILE_LIB="$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-compile.sh"

write_planfrom_graph_plan() {
  local dest="$1"
  cat >"$dest" <<'EOF'
---
name: PlanFrom Compile
execution: graph
pipeline:
  stages:
    - id: plan-implementation
      runtime: cursor
      planner:
        outputMode: plan-file
        maxTodos: 40
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/impl-plan.json
          schema: bundle/.ralph/schemas/planner-output.schema.json
          required: true
    - id: implement
      runtime: cursor
      model: auto
      planFrom: plan-implementation
      dependsOn:
        - plan-implementation
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md
          required: true
todos:
  - id: plan-1
    stage: plan-implementation
    content: Write the implementation plan JSON.
    status: pending
---
EOF
}

@test "planFrom projection freezes planner binding without resolving a plan path" {
  # shellcheck source=/dev/null
  source "$GRAPH_COMPILE_LIB"
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/planfrom.plan.md"
  write_planfrom_graph_plan "$plan_file"

  run graph_compile_plan "$plan_file" "$tmpd/out.graph.json" 1
  [ "$status" -eq 0 ]
  payload="$(json_payload "$output")"

  [ "$(json_field "$payload" '.nodes[] | select(.id=="implement") | .stage.planFrom')" = "plan-implementation" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="implement") | .planFromBinding.plannerStageId')" = "plan-implementation" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="implement") | .planFromBinding.planSourceKind')" = "generated" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="implement") | .stage | has("plan")')" = "false" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="implement") | .stage | has("_inlineTodos")')" = "false" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="implement") | .stage.sessionStrategy')" = "fresh" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="implement") | .stage.runtime')" = "cursor" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="implement") | .stage.model')" = "auto" ]
  rm -rf "$tmpd"
}

@test "frozen planner binding is preserved by graph_compile_freeze_planfrom_bindings" {
  # shellcheck source=/dev/null
  source "$GRAPH_COMPILE_LIB"
  tmpd="$(mktemp -d)"
  graph_file="$tmpd/raw.graph.json"
  cat >"$graph_file" <<'EOF'
{
  "schemaVersion": 1,
  "name": "raw",
  "namespace": "raw",
  "nodes": [
    {
      "id": "implement",
      "type": "agent",
      "dependsOn": ["plan-implementation"],
      "derivedFrom": "stage",
      "stage": {
        "id": "implement",
        "runtime": "cursor",
        "planFrom": "plan-implementation",
        "_inlineTodos": []
      }
    }
  ],
  "edges": []
}
EOF
  run graph_compile_freeze_planfrom_bindings "$graph_file"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.nodes[0].planFromBinding.plannerStageId' "$graph_file")" = "plan-implementation" ]
  [ "$(jq -r '.nodes[0].stage | has("_inlineTodos")' "$graph_file")" = "false" ]
  [ "$(jq -r '.nodes[0].stage.sessionStrategy' "$graph_file")" = "fresh" ]
  rm -rf "$tmpd"
}

@test "invalid generated plan projection rejects planFrom stage that already has a plan path" {
  # shellcheck source=/dev/null
  source "$GRAPH_COMPILE_LIB"
  tmpd="$(mktemp -d)"
  graph_file="$tmpd/bad.graph.json"
  cat >"$graph_file" <<'EOF'
{
  "schemaVersion": 1,
  "name": "bad",
  "namespace": "bad",
  "nodes": [
    {
      "id": "implement",
      "type": "agent",
      "dependsOn": [],
      "derivedFrom": "stage",
      "stage": {
        "id": "implement",
        "runtime": "cursor",
        "planFrom": "plan-implementation",
        "plan": "/tmp/already-resolved.plan.md"
      }
    }
  ],
  "edges": []
}
EOF
  run graph_compile_freeze_planfrom_bindings "$graph_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid generated plan"* ]]
  rm -rf "$tmpd"
}

# --- Dependency provided plan (planInput) compile freeze ---

@test "Dependency provided plan source kind freezes null stage id without plan path" {
  # shellcheck source=/dev/null
  source "$GRAPH_COMPILE_LIB"
  tmpd="$(mktemp -d)"
  graph_file="$tmpd/provided.graph.json"
  cat >"$graph_file" <<'EOF'
{
  "schemaVersion": 1,
  "name": "provided",
  "namespace": "provided",
  "nodes": [
    {
      "id": "implement",
      "type": "agent",
      "dependsOn": [],
      "derivedFrom": "stage",
      "stage": {
        "id": "implement",
        "runtime": "cursor",
        "model": "auto",
        "_inlineTodos": []
      }
    },
    {
      "id": "implement-r1",
      "type": "agent",
      "dependsOn": ["review"],
      "derivedFrom": "rework",
      "stage": {
        "id": "implement-r1",
        "runtime": "cursor",
        "_inlineTodos": []
      }
    },
    {
      "id": "qa",
      "type": "agent",
      "dependsOn": ["implement"],
      "derivedFrom": "stage",
      "stage": {
        "id": "qa",
        "runtime": "cursor",
        "planFrom": "plan-qa"
      }
    }
  ],
  "edges": []
}
EOF

  run graph_compile_freeze_provided_plan_bindings "$graph_file" "implement"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.nodes[] | select(.id=="implement") | .planInputBinding.planSourceKind' "$graph_file")" = "provided" ]
  [ "$(jq -r '.nodes[] | select(.id=="implement") | .planInputBinding.planSourceStageId' "$graph_file")" = "null" ]
  [ "$(jq -r '.nodes[] | select(.id=="implement") | .stage.sessionStrategy' "$graph_file")" = "fresh" ]
  [ "$(jq -r '.nodes[] | select(.id=="implement") | .stage | has("_inlineTodos")' "$graph_file")" = "false" ]
  [ "$(jq -r '.nodes[] | select(.id=="implement") | .stage | has("plan")' "$graph_file")" = "false" ]
  [ "$(jq -r '.nodes[] | select(.id=="implement-r1") | .planInputBinding.planSourceKind' "$graph_file")" = "provided" ]
  [ "$(jq -r '.nodes[] | select(.id=="implement-r1") | .planInputBinding.planSourceStageId' "$graph_file")" = "null" ]
  # Non-consumer planFrom node remains untouched (task-entry byte-compat when
  # freeze_provided is not applied to it).
  [ "$(jq -r '.nodes[] | select(.id=="qa") | .stage.planFrom' "$graph_file")" = "plan-qa" ]
  [ "$(jq -r '.nodes[] | select(.id=="qa") | has("planInputBinding")' "$graph_file")" = "false" ]
  rm -rf "$tmpd"
}

@test "invalid input provided plan projection rejects planInput stage that already has a plan path" {
  # shellcheck source=/dev/null
  source "$GRAPH_COMPILE_LIB"
  tmpd="$(mktemp -d)"
  graph_file="$tmpd/bad-provided.graph.json"
  cat >"$graph_file" <<'EOF'
{
  "schemaVersion": 1,
  "name": "bad",
  "namespace": "bad",
  "nodes": [
    {
      "id": "implement",
      "type": "agent",
      "dependsOn": [],
      "derivedFrom": "stage",
      "stage": {
        "id": "implement",
        "runtime": "cursor",
        "plan": "/tmp/already-resolved.plan.md"
      }
    }
  ],
  "edges": []
}
EOF
  run graph_compile_freeze_provided_plan_bindings "$graph_file" "implement"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid provided plan"* ]]
  rm -rf "$tmpd"
}

@test "task-entry planFrom freeze remains byte-compatible without provided planInput stage" {
  # shellcheck source=/dev/null
  source "$GRAPH_COMPILE_LIB"
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/planfrom.plan.md"
  write_planfrom_graph_plan "$plan_file"
  unset RALPH_WORKFLOW_PLAN_INPUT_STAGE

  run graph_compile_plan "$plan_file" "$tmpd/out.graph.json" 1
  [ "$status" -eq 0 ]
  payload="$(json_payload "$output")"
  [ "$(json_field "$payload" '.nodes[] | select(.id=="implement") | .planFromBinding.planSourceKind')" = "generated" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="implement") | has("planInputBinding")')" = "false" ]
  rm -rf "$tmpd"
}

# --- plan-backed rework: generated planFrom clones keep frozen planner binding ---

EVALUATOR_SCHEMA_REL="bundle/.ralph/schemas/evaluator-verdict.schema.json"

write_planfrom_rework_plan() {
  local dest="$1" iterations="${2:-2}" on_exhausted="${3:-}"
  local on_exhausted_line=""
  [[ -n "$on_exhausted" ]] && on_exhausted_line=$'\n'"      onExhausted: ${on_exhausted}"
  cat >"$dest" <<EOF
---
name: PlanFrom Rework Compile
execution: graph
pipeline:
  stages:
    - id: plan-implementation
      runtime: cursor
      planner:
        outputMode: plan-file
        maxTodos: 40
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/impl-plan.json
          schema: bundle/.ralph/schemas/planner-output.schema.json
          required: true
    - id: implement
      runtime: cursor
      planFrom: plan-implementation
      dependsOn:
        - plan-implementation
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md
          required: true
    - id: review
      runtime: cursor
      dependsOn:
        - implement
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/{{STAGE_ID}}-verdict.json
          schema: ${EVALUATOR_SCHEMA_REL}
          required: true
      loopBackTo: implement
      maxIterations: ${iterations}${on_exhausted_line}
      loopCheck:
        path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/{{STAGE_ID}}-verdict.json
        schema: ${EVALUATOR_SCHEMA_REL}
todos:
  - id: plan-1
    stage: plan-implementation
    content: Write the implementation plan JSON.
    status: pending
  - id: review-1
    stage: review
    content: Review the implementation.
    status: pending
---
EOF
}

@test "plan-backed rework zero rounds leaves only the original planFrom consumer" {
  # shellcheck source=/dev/null
  source "$GRAPH_COMPILE_LIB"
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/zero.plan.md"
  # No loopBackTo: zero generated rework rounds.
  write_planfrom_graph_plan "$plan_file"

  run graph_compile_plan "$plan_file" "$tmpd/out.graph.json" 1
  [ "$status" -eq 0 ]
  payload="$(json_payload "$output")"
  [ "$(json_field "$payload" '[.nodes[] | select(.id|test("^implement-r"))] | length')" = "0" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="implement") | .planFromBinding.plannerStageId')" = "plan-implementation" ]
  rm -rf "$tmpd"
}

@test "plan-backed rework one round freezes planner binding on implement-r1" {
  # shellcheck source=/dev/null
  source "$GRAPH_COMPILE_LIB"
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/one.plan.md"
  write_planfrom_rework_plan "$plan_file" 1

  run graph_compile_plan "$plan_file" "$tmpd/out.graph.json" 1
  [ "$status" -eq 0 ]
  payload="$(json_payload "$output")"

  [ "$(json_field "$payload" '.nodes[] | select(.id=="implement-r1") | .derivedFrom')" = "rework" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="implement-r1") | .dependsOn | join(",")')" = "review" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="implement-r1") | .stage.planFrom')" = "plan-implementation" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="implement-r1") | .planFromBinding.plannerStageId')" = "plan-implementation" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="implement-r1") | .planFromBinding.planSourceKind')" = "generated" ]
  [ "$(json_field "$payload" '[.nodes[] | select(.id|test("^implement-r"))] | length')" = "1" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="review-approved") | .type')" = "join" ]
  rm -rf "$tmpd"
}

@test "plan-backed rework two rounds keep frozen planner binding independent of review edges" {
  # shellcheck source=/dev/null
  source "$GRAPH_COMPILE_LIB"
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/two.plan.md"
  write_planfrom_rework_plan "$plan_file" 2

  run graph_compile_plan "$plan_file" "$tmpd/out.graph.json" 1
  [ "$status" -eq 0 ]
  payload="$(json_payload "$output")"

  [ "$(json_field "$payload" '.nodes[] | select(.id=="implement-r1") | .dependsOn | join(",")')" = "review" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="implement-r2") | .dependsOn | join(",")')" = "review-r1" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="implement-r1") | .planFromBinding.plannerStageId')" = "plan-implementation" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="implement-r2") | .planFromBinding.plannerStageId')" = "plan-implementation" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="implement") | .planFromBinding.plannerStageId')" = "plan-implementation" ]
  # Review edge is feedback, never a replacement planner.
  [ "$(json_field "$payload" '.nodes[] | select(.id=="implement-r1") | .stage.planFrom')" != "review" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="implement-r2") | .stage.planFrom')" != "review-r1" ]
  rm -rf "$tmpd"
}

@test "plan-backed rework approved early exit routes every review passed edge to the join" {
  # shellcheck source=/dev/null
  source "$GRAPH_COMPILE_LIB"
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/approved.plan.md"
  write_planfrom_rework_plan "$plan_file" 2

  run graph_compile_plan "$plan_file" "$tmpd/out.graph.json" 1
  [ "$status" -eq 0 ]
  payload="$(json_payload "$output")"

  [ "$(json_field "$payload" '[.edges[] | select(.condition=="passed" and .to=="review-approved")] | length')" = "3" ]
  [ "$(json_field "$payload" '[.edges[] | select(.condition=="passed" and .to=="review-approved") | .from] | sort | join(",")')" = "review,review-r1,review-r2" ]
  rm -rf "$tmpd"
}

@test "plan-backed rework loop exhausted omits final changes-required edge under onExhausted fail" {
  # shellcheck source=/dev/null
  source "$GRAPH_COMPILE_LIB"
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/exhausted.plan.md"
  write_planfrom_rework_plan "$plan_file" 2 "fail"

  run graph_compile_plan "$plan_file" "$tmpd/out.graph.json" 1
  [ "$status" -eq 0 ]
  payload="$(json_payload "$output")"

  [ "$(json_field "$payload" '[.edges[] | select(.from=="review-r2" and .condition=="changes-required")] | length')" = "0" ]
  [ "$(json_field "$payload" '[.edges[] | select(.from=="review" and .condition=="changes-required" and .to=="implement-r1")] | length')" = "1" ]
  rm -rf "$tmpd"
}

@test "plan-backed rework rejects planner stage as loopBackTo target" {
  # shellcheck source=/dev/null
  source "$GRAPH_COMPILE_LIB"
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/planner-target.plan.md"
  cat >"$plan_file" <<EOF
---
name: Planner Rework Target
execution: graph
pipeline:
  stages:
    - id: plan-implementation
      runtime: cursor
      planner:
        outputMode: plan-file
        maxTodos: 40
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/impl-plan.json
          schema: bundle/.ralph/schemas/planner-output.schema.json
          required: true
    - id: review
      runtime: cursor
      dependsOn:
        - plan-implementation
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/{{STAGE_ID}}-verdict.json
          schema: ${EVALUATOR_SCHEMA_REL}
          required: true
      loopBackTo: plan-implementation
      maxIterations: 1
      loopCheck:
        path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/{{STAGE_ID}}-verdict.json
        schema: ${EVALUATOR_SCHEMA_REL}
todos:
  - id: plan-1
    stage: plan-implementation
    content: Write plan.
    status: pending
  - id: review-1
    stage: review
    content: Review.
    status: pending
---
EOF

  run graph_compile_plan "$plan_file" "$tmpd/out.graph.json" 1
  [ "$status" -ne 0 ]
  [[ "$output" == *"planner"* ]]
  [[ "$output" == *"plan-implementation"* ]]
  rm -rf "$tmpd"
}

# --- Dependency approval compile boundary ---

write_dependency_approval_plan() {
  local dest="$1"
  cat >"$dest" <<'PLAN'
---
name: dep-approval-compile
overview: Dependency approval compile fixture
isProject: false
kind: workflow
mode: dependency
pipeline:
  maxParallel: 1
  stages:
    - id: plan-implementation
      runtime: cursor
      planner:
        outputMode: plan-file
        maxTodos: 10
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/impl-plan.json
          schema: bundle/.ralph/schemas/planner-output.schema.json
          required: true
    - id: approve-plan
      type: approval
      question: Approve the concrete implementation plan?
      changesTarget: plan-implementation
      dependsOn:
        - plan-implementation
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/impl-plan.json
          schema: bundle/.ralph/schemas/planner-output.schema.json
          required: true
    - id: implement
      runtime: cursor
      planFrom: plan-implementation
      dependsOn:
        - approve-plan
        - plan-implementation
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md
          required: true
todos:
  - id: plan-1
    stage: plan-implementation
    content: |
      Emit the planner JSON for:
      {{TASK}}
    status: pending
---
PLAN
}

@test "Dependency approval compiles as frozen supervisor boundary without checkpoint" {
  tmpd="$(mktemp -d)"
  wf="$tmpd/dep-approval.workflow.md"
  plan_file="$tmpd/dep-approval.plan.md"
  write_dependency_approval_plan "$wf"

  run plan_workflow_instantiate "$wf" "ship the fix" "$plan_file"
  [ "$status" -eq 0 ]
  grep -qx 'execution: graph' "$plan_file"

  run plan_pipeline_graph_json "$plan_file"
  [ "$status" -eq 0 ]
  payload="$(json_payload "$output")"
  [ "$(json_field "$payload" '.nodes[] | select(.id=="approve-plan") | .type')" = "approval" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="approve-plan") | .stage.type')" = "approval" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="approve-plan") | .stage.question')" = "Approve the concrete implementation plan?" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="approve-plan") | .stage.changesTarget')" = "plan-implementation" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="approve-plan") | .stage | has("humanAck")')" = "false" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="approve-plan") | .stage.runtime // "null"')" = "null" ]
  [ "$(json_field "$payload" '[.nodes[] | select(.type=="checkpoint")] | length')" = "0" ]
  ! printf '%s' "$payload" | grep -qi 'ORCHESTRATOR_HUMAN_ACK'

  printf '%s\n' "$payload" >"$tmpd/graph.json"
  run bash "$VALIDATE_GRAPH_SCHEMA_SH" "$tmpd/graph.json"
  [ "$status" -eq 0 ]

  source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-compile.sh"
  run graph_compile_assert_approval_boundary "$tmpd/graph.json"
  [ "$status" -eq 0 ]
  rm -rf "$tmpd"
}

@test "Dependency approval schema rejects runtime and humanAck on approval node" {
  tmpd="$(mktemp -d)"
  graph_file="$tmpd/bad-approval.graph.json"
  python3 - "$graph_file" <<'PY'
import json, sys
doc = {
  "schemaVersion": 2,
  "ralphVersion": "1.0.0",
  "name": "bad",
  "namespace": "bad",
  "maxParallel": 1,
  "failurePolicy": "drain",
  "nodes": [{
    "id": "approve-plan",
    "type": "approval",
    "dependsOn": ["plan-implementation"],
    "derivedFrom": "stage",
    "stage": {
      "id": "approve-plan",
      "type": "approval",
      "question": "Approve?",
      "changesTarget": "plan-implementation",
      "runtime": "cursor",
      "inputArtifacts": [{"path": ".ralph-workspace/artifacts/ns/x.json", "required": True}],
    },
  }, {
    "id": "plan-implementation",
    "type": "agent",
    "dependsOn": [],
    "derivedFrom": "stage",
    "stage": {"id": "plan-implementation", "runtime": "cursor"},
  }],
  "edges": [{"from": "plan-implementation", "to": "approve-plan", "reasons": ["declared"]}],
}
json.dump(doc, open(sys.argv[1], "w"))
PY
  run bash "$VALIDATE_GRAPH_SCHEMA_SH" "$graph_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"approval"* ]]
  rm -rf "$tmpd"
}

# --- Workflow routing through dependency compile + dispatch stub argv ---------
# Prove materialized fallbacks become concrete stage.runtime/model on compiled
# JSON while explicit stage/TODO overrides, voters, and instructions stay local.
# Sourced compile/dispatch/planner helpers only — no graph-run / run-plan loop.

GRAPH_DISPATCH_LIB="$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-dispatch.sh"
WORKFLOW_STATE_LIB="$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/workflow/workflow-state.sh"
PLANNER_CONTRACT_PY="$BATS_TEST_DIRNAME/../../../bundle/.ralph/python/planner_contract.py"

_psr_refute_cmd() {
  ! "$@"
}

@test "workflow routing: inherited planner/planFrom pair and instructions become concrete" {
  unset RALPH_WORKFLOW_PLAN_INPUT_STAGE
  tmpd="$(mktemp -d)"
  wf="$tmpd/wf.md"
  plan_file="$tmpd/out.plan.md"
  cat >"$wf" <<'EOF'
---
name: routing-inherit
kind: workflow
mode: dependency
pipeline:
  stages:
    - id: research
      instructions: Keep research read-only.
    - id: plan-implementation
      planner:
        outputMode: plan-file
        maxTodos: 20
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/impl-plan.json
          schema: bundle/.ralph/schemas/planner-output.schema.json
          required: true
      dependsOn:
        - research
    - id: implement
      planFrom: plan-implementation
      dependsOn:
        - plan-implementation
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/handoff.md
          required: true
    - id: ship
      runtime: cursor
      instructions: Different runtime stage.
      dependsOn:
        - implement
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/ship.md
          required: true
    - id: jury
      type: consensus
      policy: majority
      quorum: 2
      minRuntimes: 2
      voters:
        - id: cursor-voter
          runtime: cursor
          model: auto
          instructions: Vote with repository evidence only.
        - id: claude-voter
          runtime: claude
          model: sonnet
          instructions: Vote with repository evidence only.
      dependsOn:
        - ship
todos:
  - id: research-1
    stage: research
    content: Investigate {{TASK}}
    status: pending
  - id: plan-1
    stage: plan-implementation
    content: Plan {{TASK}}
    status: pending
---
EOF

  run plan_workflow_instantiate "$wf" "fix login" "$plan_file" \
    fallback_runtime=claude fallback_model=sonnet
  [ "$status" -eq 0 ]

  run plan_pipeline_graph_json "$plan_file"
  [ "$status" -eq 0 ]
  payload="$(json_payload "$output")"

  # Inherited planner / planFrom pair share concrete fallback routing.
  [ "$(json_field "$payload" '.nodes[] | select(.id=="plan-implementation") | .stage.runtime')" = "claude" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="plan-implementation") | .stage.model')" = "sonnet" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="implement") | .stage.runtime')" = "claude" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="implement") | .stage.model')" = "sonnet" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="research") | .stage.runtime')" = "claude" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="research") | .stage.instructions')" = "Keep research read-only." ]

  # Explicit different-runtime stage keeps local runtime and drops unpaired fallback model.
  [ "$(json_field "$payload" '.nodes[] | select(.id=="ship") | .stage.runtime')" = "cursor" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="ship") | .stage | has("model")')" = "false" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="ship") | .stage.instructions')" = "Different runtime stage." ]

  # Voter pins stay local; container is not an agent stage with fallback model.
  [ "$(json_field "$payload" '.nodes[] | select(.id=="jury:cursor-voter") | .stage.runtime')" = "cursor" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="jury:cursor-voter") | .stage.model')" = "auto" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="jury:claude-voter") | .stage.runtime')" = "claude" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="jury:claude-voter") | .stage.instructions')" = "Vote with repository evidence only." ]

  # Materialized plan did not write routing onto TODOs.
  _psr_refute_cmd awk '/^todos:/{p=1} p && /^[[:space:]]+runtime:/{found=1} END{exit found?0:1}' "$plan_file"
  rm -rf "$tmpd"
}

@test "workflow routing: skipped model stays absent; repair clone keeps stage routing" {
  # shellcheck source=/dev/null
  source "$GRAPH_COMPILE_LIB"
  # Task-entry compile must not inherit a leftover planInput stage from other
  # suites or the operator shell (provided freeze would clear planFrom).
  unset RALPH_WORKFLOW_PLAN_INPUT_STAGE
  tmpd="$(mktemp -d)"
  wf="$tmpd/wf.md"
  plan_file="$tmpd/out.plan.md"
  cat >"$wf" <<EOF
---
name: routing-rework
kind: workflow
mode: dependency
pipeline:
  stages:
    - id: plan-implementation
      planner:
        outputMode: plan-file
        maxTodos: 10
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/impl-plan.json
          schema: bundle/.ralph/schemas/planner-output.schema.json
          required: true
    - id: implement
      planFrom: plan-implementation
      instructions: Implement carefully.
      dependsOn:
        - plan-implementation
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/handoff.md
          required: true
    - id: review
      runtime: cursor
      instructions: Review only.
      dependsOn:
        - implement
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/{{STAGE_ID}}-verdict.json
          schema: ${EVALUATOR_SCHEMA_REL}
          required: true
      loopBackTo: implement
      maxIterations: 1
      loopCheck:
        path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/{{STAGE_ID}}-verdict.json
        schema: ${EVALUATOR_SCHEMA_REL}
todos:
  - id: plan-1
    stage: plan-implementation
    content: Plan {{TASK}}
    status: pending
  - id: review-1
    stage: review
    content: Review
    status: pending
---
EOF

  # Skipped model: fallback_runtime only.
  run plan_workflow_instantiate "$wf" "ship" "$plan_file" fallback_runtime=opencode
  [ "$status" -eq 0 ]
  _psr_refute_cmd grep -E '^[[:space:]]+model:' "$plan_file"

  run graph_compile_plan "$plan_file" "$tmpd/out.graph.json" 1
  [ "$status" -eq 0 ]
  payload="$(json_payload "$output")"

  [ "$(json_field "$payload" '.nodes[] | select(.id=="implement") | .stage.runtime')" = "opencode" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="implement") | .stage | has("model")')" = "false" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="implement") | .stage.instructions')" = "Implement carefully." ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="implement-r1") | .stage.runtime')" = "opencode" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="implement-r1") | .stage | has("model")')" = "false" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="implement-r1") | .stage.instructions')" = "Implement carefully." ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="implement-r1") | .planFromBinding.plannerStageId')" = "plan-implementation" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="plan-implementation") | .stage.runtime')" = "opencode" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="plan-implementation") | .stage | has("model")')" = "false" ]
  rm -rf "$tmpd"
}

@test "workflow routing: fallback absent from planner JSON but frozen as plan defaults" {
  command -v python3 >/dev/null || skip "python3 required"
  tmpd="$(mktemp -d)"
  artifact="$tmpd/planner.json"
  plan_out="$tmpd/frozen.plan.md"
  cat >"$artifact" <<'EOF'
{
  "schemaVersion": 2,
  "name": "routing-freeze",
  "overview": "Cover generated TODO override matrix",
  "rationale": "Fewest independently verifiable TODOs.",
  "todos": [
    {
      "id": "baseline",
      "content": "Use plan defaults.",
      "verification": "true",
      "status": "pending"
    },
    {
      "id": "model-only",
      "content": "Model-only generated TODO.",
      "verification": "true",
      "status": "pending",
      "model": "gpt-5"
    },
    {
      "id": "runtime-only",
      "content": "Runtime-only generated TODO.",
      "verification": "true",
      "status": "pending",
      "runtime": "codex"
    },
    {
      "id": "paired",
      "content": "Paired override.",
      "verification": "true",
      "status": "pending",
      "runtime": "claude",
      "model": "opus"
    }
  ]
}
EOF

  # Model-written planner JSON stays routing-neutral at the top level.
  [ "$(jq -r 'has("runtime"),has("model"),has("sessionStrategy")' "$artifact" | paste -sd, -)" = "false,false,false" ]

  run python3 "$PLANNER_CONTRACT_PY" render-plan \
    --artifact "$artifact" \
    --default-runtime cursor \
    --default-model auto \
    --output "$plan_out" \
    --max-todos 40
  [ "$status" -eq 0 ]

  # Frozen plan defaults from consumer/fallback; TODO overrides remain local.
  grep -qE '^runtime: cursor$' "$plan_out"
  grep -qE '^model: auto$' "$plan_out"
  grep -qE '^sessionStrategy: fresh$' "$plan_out"
  awk '/^  - id: model-only$/{p=1;next} p && /^  - id:/{exit} p' "$plan_out" | grep -qx '    model: gpt-5'
  _psr_refute_cmd awk '/^  - id: model-only$/{p=1;next} p && /^  - id:/{exit} p && /^[[:space:]]+runtime:/{found=1} END{exit found?0:1}' "$plan_out"
  awk '/^  - id: runtime-only$/{p=1;next} p && /^  - id:/{exit} p' "$plan_out" | grep -qx '    runtime: codex'
  _psr_refute_cmd awk '/^  - id: runtime-only$/{p=1;next} p && /^  - id:/{exit} p && /^[[:space:]]+model:/{found=1} END{exit found?0:1}' "$plan_out"
  awk '/^  - id: paired$/{p=1;next} p && /^  - id:/{exit} p' "$plan_out" | grep -qx '    runtime: claude'
  awk '/^  - id: paired$/{p=1;next} p && /^  - id:/{exit} p' "$plan_out" | grep -qx '    model: opus'

  # Planner artifact itself was never mutated with frozen defaults.
  [ "$(jq -r 'has("runtime"),has("model")' "$artifact" | paste -sd, -)" = "false,false" ]
  rm -rf "$tmpd"
}

@test "workflow routing: provided plan header under stage/invocation; immutable source and stub argv" {
  # shellcheck source=/dev/null
  source "$WORKFLOW_STATE_LIB"
  # shellcheck source=/dev/null
  source "$GRAPH_DISPATCH_LIB"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/workflow/workflow-routing.sh"

  tmpd="$(mktemp -d)"
  export WORKFLOW_STATE_SKIP_FSYNC=1
  export WORKFLOW_STATE_FIXED_NOW="2026-08-27T16:00:00Z"
  export RALPH_PLAN_WORKSPACE_ROOT="$tmpd"

  mkdir -p "$tmpd/project/plans" "$tmpd/inputs"
  printf '%s\n' '---' 'kind: workflow' 'mode: dependency' '---' >"$tmpd/inputs/wf.md"
  cat >"$tmpd/project/plans/feature.plan.md" <<'EOF'
---
name: Provided Feature
overview: Ship it
runtime: claude
model: plan-header-model
todos:
  - id: one
    content: Do one
    verification: true
    status: pending
  - id: two
    content: Do two
    verification: true
    status: pending
    model: todo-model-only
  - id: three
    content: Do three
    verification: true
    status: pending
    runtime: codex
---
EOF
  printf '# leaf\n- [ ] placeholder\n' >"$tmpd/inputs/sample.plan.md"

  run_id="$(
    workflow_state_create \
      --state-root "$tmpd" \
      --source-path "$tmpd/inputs/wf.md" \
      --source-kind project \
      --mode dependency \
      --entry-kind plan \
      --task "Execute the supplied feature plan" \
      --task-provenance plan-overview \
      --input-file "$tmpd/inputs/sample.plan.md" \
      --workflow-id plan-delivery \
      --engine-namespace plan-delivery
  )"
  workflow_state_import_provided_plan \
    --state-root "$tmpd" \
    --run-id "$run_id" \
    --plan "$tmpd/project/plans/feature.plan.md" \
    --project-root "$tmpd/project" >/dev/null

  source_plan="$tmpd/workflow-runs/$run_id/plans/input/source.plan.md"
  before="$(cksum "$source_plan" | awk '{print $1" "$2}')"
  original_before="$(cksum "$tmpd/project/plans/feature.plan.md" | awk '{print $1" "$2}')"

  graph_json="$tmpd/provided.graph.json"
  orch="$tmpd/provided.orch.json"
  cat >"$graph_json" <<'EOF'
{
  "name": "pd",
  "namespace": "pd",
  "nodes": [
    {
      "id": "implement",
      "type": "agent",
      "dependsOn": [],
      "derivedFrom": "stage",
      "planInputBinding": {
        "planSourceKind": "provided",
        "planSourceStageId": null
      },
      "stage": {
        "id": "implement",
        "runtime": "cursor",
        "model": "stage-model",
        "sessionStrategy": "fresh",
        "instructions": "Use the supplied plan."
      }
    },
    {
      "id": "implement-r1",
      "type": "agent",
      "dependsOn": ["review"],
      "derivedFrom": "rework",
      "planInputBinding": {
        "planSourceKind": "provided",
        "planSourceStageId": null
      },
      "stage": {
        "id": "implement-r1",
        "runtime": "cursor",
        "model": "stage-model",
        "sessionStrategy": "fresh",
        "instructions": "Use the supplied plan."
      }
    }
  ],
  "edges": []
}
EOF
  cat >"$orch" <<'EOF'
{
  "name": "pd",
  "namespace": "pd",
  "stages": [
    {
      "id": "implement",
      "runtime": "cursor",
      "model": "stage-model",
      "sessionStrategy": "fresh",
      "instructions": "Use the supplied plan."
    }
  ]
}
EOF

  export GRAPH_DISPATCH_ORCHESTRATOR="$tmpd/orch-stub.sh"
  printf '#!/bin/bash\nexit 0\n' >"$GRAPH_DISPATCH_ORCHESTRATOR"
  chmod +x "$GRAPH_DISPATCH_ORCHESTRATOR"

  binding="$(
    graph_dispatch_bind_provided_plan_control \
      --graph-json "$graph_json" \
      --node-id implement \
      --orch-path "$orch" \
      --registry-run "$tmpd/workflow-runs/$run_id" \
      --attempt-number 1 \
      --plan-run-id "implement__test__1" \
      --workflow-runtime opencode \
      --workflow-model wf-model
  )"
  control="$(printf '%s' "$binding" | jq -r '.controlPlanPath')"
  [ -f "$control" ]
  [ "$(jq -r '.stages[0].plan' "$orch")" = "$control" ]
  # Stage pins beat provided-plan header and workflow defaults.
  [ "$(jq -r '.stages[0].runtime' "$orch")" = "cursor" ]
  [ "$(jq -r '.stages[0].model' "$orch")" = "stage-model" ]
  [ "$(jq -r '.stages[0].instructions' "$orch")" = "Use the supplied plan." ]

  # Clear stage pins: invocation beats provided-plan header; header beats workflow.
  jq '(.stages[0] |= (del(.runtime) | del(.model)))' "$orch" >"$orch.tmp" && mv "$orch.tmp" "$orch"
  graph_dispatch_apply_provided_routing_order "$orch" implement "$source_plan" \
    --invocation-runtime antigravity \
    --workflow-runtime opencode \
    --workflow-model wf-model
  [ "$(jq -r '.stages[0].runtime' "$orch")" = "antigravity" ]

  jq '(.stages[0] |= (del(.runtime) | del(.model)))' "$orch" >"$orch.tmp" && mv "$orch.tmp" "$orch"
  graph_dispatch_apply_provided_routing_order "$orch" implement "$source_plan" \
    --workflow-runtime opencode \
    --workflow-model wf-model
  [ "$(jq -r '.stages[0].runtime' "$orch")" = "claude" ]
  [ "$(jq -r '.stages[0].model' "$orch")" = "plan-header-model" ]

  # Mutable control retains non-overridden TODO bodies; local TODO overrides stay on control.
  grep -q 'model: todo-model-only' "$control"
  grep -q 'runtime: codex' "$control"
  grep -q 'Do one' "$control"
  # Advance control only (first pending -> completed); source stays pending.
  python3 - "$control" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text(encoding="utf-8")
assert "status: pending" in text
p.write_text(text.replace("status: pending", "status: completed", 1), encoding="utf-8")
PY
  grep -q 'status: completed' "$control"
  grep -q 'status: pending' "$control"

  after="$(cksum "$source_plan" | awk '{print $1" "$2}')"
  original_after="$(cksum "$tmpd/project/plans/feature.plan.md" | awk '{print $1" "$2}')"
  [ "$before" = "$after" ]
  [ "$original_before" = "$original_after" ]
  [ ! -w "$source_plan" ]
  ! grep -q 'status: completed' "$source_plan"
  grep -q 'status: pending' "$source_plan"

  # Restore stage pins for argv projection, then stub orchestrator argv.
  jq '(.stages[0].runtime = "cursor") | (.stages[0].model = "stage-model")' "$orch" \
    >"$orch.tmp" && mv "$orch.tmp" "$orch"
  graph_dispatch_build_argv "$orch" implement "$run_id" "implement__${run_id}__1" "$tmpd" "$tmpd"
  argv_joined="${GRAPH_DISPATCH_ARGV[*]}"
  [[ "$argv_joined" == *"--single-stage implement"* ]]
  [[ "$argv_joined" == *"--orchestration $orch"* ]]
  [ "$(jq -r '.stages[0].runtime' "$orch")" = "cursor" ]
  [ "$(jq -r '.stages[0].model' "$orch")" = "stage-model" ]

  # Provided plan-backed repair clone keeps the same frozen planInputBinding kind.
  [ "$(jq -r '.nodes[] | select(.id=="implement-r1") | .planInputBinding.planSourceKind' "$graph_json")" = "provided" ]
  [ "$(jq -r '.nodes[] | select(.id=="implement-r1") | .stage.runtime' "$graph_json")" = "cursor" ]
  rm -rf "$tmpd"
}
