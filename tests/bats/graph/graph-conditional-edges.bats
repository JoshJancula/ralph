#!/usr/bin/env bats
# Tests for conditional graph edges (v2-conditional-outcomes).
#
# Coverage:
#   - Compile: pass-to-review fixture compiles cleanly with condition in JSON
#   - Compile: failure-to-repair fixture compiles cleanly with repair edge
#   - Compile: illegal condition token rejected at compile time
#   - Compile: absent changes-required edge (only passed edge) compiles cleanly
#   - Compile: cycle through alternate outcome edge detected
#   - Compile: mixed unconditional + conditional fan-in compiles and contributes indegree
#   - Scheduler: conditional edge stored in GRAPH_NODE_COND_SUCCESSORS not in unconditional
#   - Scheduler: passed outcome releases passed-conditional successor; skips others
#   - Scheduler: changes-required outcome releases repair edge; skips passed branch
#   - Scheduler: changes-required with no edge returns 2 (fail-closed sentinel)
#   - Scheduler: error outcome skips all conditional branches
#   - Scheduler: unselected branch cascades skip to its own successors (indegree tracking)

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/plan-todo.sh"
export RALPH_RUN_PLAN_LIBRARY_ONLY=1
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/run-plan/run-plan-core.sh"
unset RALPH_RUN_PLAN_LIBRARY_ONLY
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-schedule.sh"

FIXTURE_DIR="$BATS_TEST_DIRNAME/../../fixtures/graph"
GRAPH_RUN_SH="$BATS_TEST_DIRNAME/../../../bundle/.ralph/graph-run.sh"

json_payload() {
  printf '%s\n' "$1" | awk 'END{print}'
}

json_field() {
  printf '%s' "$1" | jq -r "$2"
}

compile_fixture_to() {
  local fixture_name="$1" workspace="$2" out_path="$3"
  local plan_file="$workspace/$(basename "$fixture_name")"
  cp "$FIXTURE_DIR/$fixture_name" "$plan_file"
  plan_pipeline_graph_json "$plan_file" >"$out_path"
}

# ---------------------------------------------------------------------------
# Compile: conditional edge round-trips through the JSON compiler
# ---------------------------------------------------------------------------

@test "compile: pass-to-review fixture emits conditional edge with condition=passed" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"
  local tmpd
  tmpd="$(mktemp -d)"
  local out="$tmpd/out.graph.json"

  run compile_fixture_to "graph-cond-pass-to-review.plan.md" "$tmpd" "$out"
  [ "$status" -eq 0 ]
  [ -f "$out" ]

  local cond_edges
  cond_edges="$(jq '[.edges[] | select(.condition != null and .condition != "")]' "$out")"
  [ "$(printf '%s' "$cond_edges" | jq 'length')" -ge 1 ]

  local conditions
  conditions="$(printf '%s' "$cond_edges" | jq -r '.[].condition' | sort -u)"
  [[ "$conditions" == "passed" ]]

  rm -rf "$tmpd"
}

@test "compile: failure-to-repair fixture emits both passed and changes-required edges" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"
  local tmpd
  tmpd="$(mktemp -d)"
  local out="$tmpd/out.graph.json"

  run compile_fixture_to "graph-cond-failure-to-repair.plan.md" "$tmpd" "$out"
  [ "$status" -eq 0 ]

  local conditions
  conditions="$(jq -r '[.edges[] | select(.condition != null and .condition != "") | .condition] | sort | join(",")' "$out")"
  [[ "$conditions" == *"changes-required"* ]]
  [[ "$conditions" == *"passed"* ]]

  rm -rf "$tmpd"
}

@test "compile: mixed unconditional and conditional fan-in compiles cleanly" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"
  local tmpd
  tmpd="$(mktemp -d)"
  local out="$tmpd/out.graph.json"

  run compile_fixture_to "graph-cond-mixed-fan-in.plan.md" "$tmpd" "$out"
  [ "$status" -eq 0 ]

  # finalize has two predecessors: prepare (unconditional) and gate-check (conditional=passed)
  local finalize_indegree
  finalize_indegree="$(jq '[.edges[] | select(.to=="finalize")] | length' "$out")"
  [ "$finalize_indegree" -eq 2 ]

  local uncond_count
  uncond_count="$(jq '[.edges[] | select(.to=="finalize" and (.condition==null or .condition==""))] | length' "$out")"
  [ "$uncond_count" -eq 1 ]

  local cond_count
  cond_count="$(jq '[.edges[] | select(.to=="finalize" and .condition=="passed")] | length' "$out")"
  [ "$cond_count" -eq 1 ]

  rm -rf "$tmpd"
}

@test "compile: illegal condition token is rejected" {
  command -v python3 >/dev/null || skip "python3 required"
  local tmpd
  tmpd="$(mktemp -d)"

  # Inline plan with a bad condition token.
  local plan_file="$tmpd/bad-condition.plan.md"
  cat >"$plan_file" <<'PLAN'
---
execution: graph
pipeline:
  stages:
    - id: source
      runtime: cursor
    - id: sink
      runtime: cursor
      dependsOn:
        - id: source
          condition: rejected-invalid
todos:
  - id: source-1
    stage: source
    content: do something
    status: pending
  - id: sink-1
    stage: sink
    content: do something else
    status: pending
---
PLAN

  run plan_pipeline_graph_json "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid edge condition"* ]] || [[ "$output" == *"rejected-invalid"* ]]

  rm -rf "$tmpd"
}

@test "compile: conditional cycle through alternate outcome is detected" {
  command -v python3 >/dev/null || skip "python3 required"
  local tmpd
  tmpd="$(mktemp -d)"

  # a -> b (unconditional), b -> a (conditional=passed) forms a cycle via any path.
  local plan_file="$tmpd/cond-cycle.plan.md"
  cat >"$plan_file" <<'PLAN'
---
execution: graph
pipeline:
  stages:
    - id: a
      runtime: cursor
      dependsOn:
        - id: b
          condition: passed
    - id: b
      runtime: cursor
      dependsOn:
        - a
todos:
  - id: a-1
    stage: a
    content: node a
    status: pending
  - id: b-1
    stage: b
    content: node b
    status: pending
---
PLAN

  run plan_pipeline_graph_json "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cycle"* ]]

  rm -rf "$tmpd"
}

# ---------------------------------------------------------------------------
# Scheduler: index loading with conditional edges
# ---------------------------------------------------------------------------

@test "scheduler: conditional edge stored in cond_successors, not in unconditional successors" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"
  local tmpd
  tmpd="$(mktemp -d)"
  local out="$tmpd/out.graph.json"

  compile_fixture_to "graph-cond-pass-to-review.plan.md" "$tmpd" "$out"
  graph_schedule_load_index "$out"

  # gate-review -> publish is a conditional(passed) edge.
  # It must NOT appear in unconditional successors of gate-review.
  local uncond_succ
  uncond_succ="$(graph_schedule_node_successors_by_id "gate-review")"
  [[ "$uncond_succ" != *"publish"* ]]

  # It MUST appear in cond_successors of gate-review.
  local cond_succ
  cond_succ="$(graph_schedule_node_cond_successors_by_id "gate-review")"
  [[ "$cond_succ" == *"passed:publish"* ]]

  rm -rf "$tmpd"
}

@test "scheduler: conditional edge contributes to indegree of target node" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"
  local tmpd
  tmpd="$(mktemp -d)"
  local out="$tmpd/out.graph.json"

  compile_fixture_to "graph-cond-pass-to-review.plan.md" "$tmpd" "$out"
  graph_schedule_load_index "$out"

  # publish depends on gate-review (conditional=passed); indegree must be >= 1.
  local publish_indegree
  publish_indegree="$(graph_schedule_node_indegree_by_id "publish")"
  [ "$publish_indegree" -ge 1 ]

  rm -rf "$tmpd"
}

@test "scheduler: mixed fan-in node has indegree 2 (one uncond + one cond)" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"
  local tmpd
  tmpd="$(mktemp -d)"
  local out="$tmpd/out.graph.json"

  compile_fixture_to "graph-cond-mixed-fan-in.plan.md" "$tmpd" "$out"
  graph_schedule_load_index "$out"

  local finalize_indegree
  finalize_indegree="$(graph_schedule_node_indegree_by_id "finalize")"
  [ "$finalize_indegree" -eq 2 ]

  rm -rf "$tmpd"
}

# ---------------------------------------------------------------------------
# Scheduler: apply_conditional_outcome routing
# ---------------------------------------------------------------------------

# Build a minimal graph JSON directly for scheduler-level tests that do not
# need a real compilation pass. Avoids requiring python3 for pure routing tests.
write_cond_graph() {
  # $1=output_path, $2=nodes_json, $3=edges_json
  local out_path="$1" nodes_json="$2" edges_json="$3"
  cat >"$out_path" <<EOF
{
  "schemaVersion": 2,
  "ralphVersion": "test",
  "name": "cond-test",
  "namespace": "cond-test",
  "maxParallel": 4,
  "failurePolicy": "drain",
  "nodes": $nodes_json,
  "edges": $edges_json
}
EOF
}

@test "scheduler: passed outcome releases passed-conditional successor" {
  command -v jq >/dev/null || skip "jq required"
  local tmpd
  tmpd="$(mktemp -d)"
  local gj="$tmpd/g.graph.json"

  write_cond_graph "$gj" \
    '[
      {"id":"gate","type":"gate","dependsOn":[],"derivedFrom":"declared","stage":{"id":"gate"}},
      {"id":"publish","type":"agent","dependsOn":["gate"],"derivedFrom":"stage","stage":{"id":"publish","runtime":"cursor","role":"impl"}}
    ]' \
    '[
      {"from":"gate","to":"publish","reasons":["declared"],"condition":"passed"}
    ]'

  graph_schedule_load_index "$gj"

  # publish indegree should start at 1.
  [ "$(graph_schedule_node_indegree_by_id publish)" -eq 1 ]

  # Apply passed outcome from gate.
  _graph_schedule_apply_conditional_outcome "gate" "passed"

  # After release, remaining indegree of publish should be 0.
  local pub_idx
  pub_idx="$(graph_schedule_index_map_get publish)"
  [ "${GRAPH_NODE_REMAINING_INDEGREE[$pub_idx]}" -eq 0 ]

  rm -rf "$tmpd"
}

@test "scheduler: non-matching conditional branch is marked skipped" {
  command -v jq >/dev/null || skip "jq required"
  local tmpd
  tmpd="$(mktemp -d)"
  local gj="$tmpd/g.graph.json"

  # gate -[passed]-> publish
  # gate -[changes-required]-> repair
  # When outcome=passed, repair should become skipped.
  write_cond_graph "$gj" \
    '[
      {"id":"gate","type":"gate","dependsOn":[],"derivedFrom":"declared","stage":{"id":"gate"}},
      {"id":"publish","type":"agent","dependsOn":["gate"],"derivedFrom":"stage","stage":{"id":"publish","runtime":"cursor","role":"impl"}},
      {"id":"repair","type":"agent","dependsOn":["gate"],"derivedFrom":"stage","stage":{"id":"repair","runtime":"cursor","role":"impl"}}
    ]' \
    '[
      {"from":"gate","to":"publish","reasons":["declared"],"condition":"passed"},
      {"from":"gate","to":"repair","reasons":["declared"],"condition":"changes-required"}
    ]'

  graph_schedule_load_index "$gj"

  _graph_schedule_apply_conditional_outcome "gate" "passed"

  local repair_idx
  repair_idx="$(graph_schedule_index_map_get repair)"
  [ "${GRAPH_NODE_STATES[$repair_idx]}" = "skipped" ]

  rm -rf "$tmpd"
}

@test "scheduler: changes-required releases repair edge and succeeds" {
  command -v jq >/dev/null || skip "jq required"
  local tmpd
  tmpd="$(mktemp -d)"
  local gj="$tmpd/g.graph.json"

  write_cond_graph "$gj" \
    '[
      {"id":"gate","type":"gate","dependsOn":[],"derivedFrom":"declared","stage":{"id":"gate"}},
      {"id":"repair","type":"agent","dependsOn":["gate"],"derivedFrom":"stage","stage":{"id":"repair","runtime":"cursor","role":"impl"}}
    ]' \
    '[
      {"from":"gate","to":"repair","reasons":["declared"],"condition":"changes-required"}
    ]'

  graph_schedule_load_index "$gj"

  # Call directly (not via `run`) so array mutations propagate in the current shell.
  local cond_rc=0
  _graph_schedule_apply_conditional_outcome "gate" "changes-required" || cond_rc=$?
  [ "$cond_rc" -eq 0 ]

  local repair_idx
  repair_idx="$(graph_schedule_index_map_get repair)"
  [ "${GRAPH_NODE_REMAINING_INDEGREE[$repair_idx]}" -eq 0 ]

  rm -rf "$tmpd"
}

@test "scheduler: changes-required with no repair edge returns 2 (fail-closed)" {
  command -v jq >/dev/null || skip "jq required"
  local tmpd
  tmpd="$(mktemp -d)"
  local gj="$tmpd/g.graph.json"

  # Only a passed conditional edge; no changes-required edge.
  write_cond_graph "$gj" \
    '[
      {"id":"gate","type":"gate","dependsOn":[],"derivedFrom":"declared","stage":{"id":"gate"}},
      {"id":"publish","type":"agent","dependsOn":["gate"],"derivedFrom":"stage","stage":{"id":"publish","runtime":"cursor","role":"impl"}}
    ]' \
    '[
      {"from":"gate","to":"publish","reasons":["declared"],"condition":"passed"}
    ]'

  graph_schedule_load_index "$gj"

  run _graph_schedule_apply_conditional_outcome "gate" "changes-required"
  # Returns 2 to signal "no changes-required edge found".
  [ "$status" -eq 2 ]

  rm -rf "$tmpd"
}

@test "scheduler: error outcome skips all conditional branches" {
  command -v jq >/dev/null || skip "jq required"
  local tmpd
  tmpd="$(mktemp -d)"
  local gj="$tmpd/g.graph.json"

  write_cond_graph "$gj" \
    '[
      {"id":"gate","type":"gate","dependsOn":[],"derivedFrom":"declared","stage":{"id":"gate"}},
      {"id":"publish","type":"agent","dependsOn":["gate"],"derivedFrom":"stage","stage":{"id":"publish","runtime":"cursor","role":"impl"}},
      {"id":"repair","type":"agent","dependsOn":["gate"],"derivedFrom":"stage","stage":{"id":"repair","runtime":"cursor","role":"impl"}}
    ]' \
    '[
      {"from":"gate","to":"publish","reasons":["declared"],"condition":"passed"},
      {"from":"gate","to":"repair","reasons":["declared"],"condition":"changes-required"}
    ]'

  graph_schedule_load_index "$gj"

  # On error: skip all conditional branches.
  _graph_schedule_skip_cond_branches "gate" "error" \
    $(_graph_schedule_cond_successor_nodes_for "gate") || true

  local publish_idx repair_idx
  publish_idx="$(graph_schedule_index_map_get publish)"
  repair_idx="$(graph_schedule_index_map_get repair)"
  [ "${GRAPH_NODE_STATES[$publish_idx]}" = "skipped" ]
  [ "${GRAPH_NODE_STATES[$repair_idx]}" = "skipped" ]

  rm -rf "$tmpd"
}

@test "scheduler: skipped branch cascades skip to its own successors" {
  command -v jq >/dev/null || skip "jq required"
  local tmpd
  tmpd="$(mktemp -d)"
  local gj="$tmpd/g.graph.json"

  # gate -[passed]-> publish -> final
  # gate -[changes-required]-> repair
  # When outcome=passed, repair is skipped; no downstream of repair so nothing else skipped.
  # When outcome=changes-required, publish is skipped, and its downstream (final) must also skip.
  write_cond_graph "$gj" \
    '[
      {"id":"gate","type":"gate","dependsOn":[],"derivedFrom":"declared","stage":{"id":"gate"}},
      {"id":"publish","type":"agent","dependsOn":["gate"],"derivedFrom":"stage","stage":{"id":"publish","runtime":"cursor","role":"impl"}},
      {"id":"final","type":"agent","dependsOn":["publish"],"derivedFrom":"stage","stage":{"id":"final","runtime":"cursor","role":"impl"}},
      {"id":"repair","type":"agent","dependsOn":["gate"],"derivedFrom":"stage","stage":{"id":"repair","runtime":"cursor","role":"impl"}}
    ]' \
    '[
      {"from":"gate","to":"publish","reasons":["declared"],"condition":"passed"},
      {"from":"publish","to":"final","reasons":["declared"]},
      {"from":"gate","to":"repair","reasons":["declared"],"condition":"changes-required"}
    ]'

  graph_schedule_load_index "$gj"

  # Apply changes-required: publish (and its successor final) should be skipped;
  # repair should be released.
  _graph_schedule_apply_conditional_outcome "gate" "changes-required"

  local publish_idx final_idx repair_idx
  publish_idx="$(graph_schedule_index_map_get publish)"
  final_idx="$(graph_schedule_index_map_get final)"
  repair_idx="$(graph_schedule_index_map_get repair)"

  [ "${GRAPH_NODE_STATES[$publish_idx]}" = "skipped" ]
  [ "${GRAPH_NODE_STATES[$final_idx]}" = "skipped" ]
  # repair's remaining indegree released.
  [ "${GRAPH_NODE_REMAINING_INDEGREE[$repair_idx]}" -eq 0 ]

  rm -rf "$tmpd"
}

# ---------------------------------------------------------------------------
# Render: conditional edges show condition labels
# ---------------------------------------------------------------------------

@test "render: mermaid output includes condition label on conditional edge" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"
  local tmpd
  tmpd="$(mktemp -d)"
  local plan_file="$tmpd/graph-cond-pass-to-review.plan.md"
  cp "$FIXTURE_DIR/graph-cond-pass-to-review.plan.md" "$plan_file"

  run bash "$GRAPH_RUN_SH" compile "$plan_file" --render mermaid
  [ "$status" -eq 0 ]
  [[ "$output" == *"passed"* ]]

  rm -rf "$tmpd"
}

@test "render: ascii output shows condition in edge line" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"
  local tmpd
  tmpd="$(mktemp -d)"
  local plan_file="$tmpd/graph-cond-pass-to-review.plan.md"
  cp "$FIXTURE_DIR/graph-cond-pass-to-review.plan.md" "$plan_file"

  run bash "$GRAPH_RUN_SH" compile "$plan_file" --render ascii
  [ "$status" -eq 0 ]
  [[ "$output" == *"passed"* ]]

  rm -rf "$tmpd"
}
