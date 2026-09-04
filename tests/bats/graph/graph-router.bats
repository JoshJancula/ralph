#!/usr/bin/env bats
# Tests for p5-router-relaxation:
#  - router_contract.py graph-mode relaxations (backward routing, wave-middle)
#  - graph-schedule.sh router skip propagation
#  - sequential orchestrator backward-routing rejection unchanged

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/plan-todo.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-schedule.sh"

ROUTER_CONTRACT_PY="$REPO_ROOT/bundle/.ralph/python/router_contract.py"
RALPH_DIR="$REPO_ROOT/bundle/.ralph"

# ---------------------------------------------------------------------------
# router_contract.py: graph mode relaxations
# ---------------------------------------------------------------------------

@test "graph mode allows backward routing target when result is acyclic" {
  command -v python3 >/dev/null || skip "python3 required"
  local orch
  orch="$(mktemp)"
  # Router appears AFTER its target by index (backward) -- allowed in graph mode
  # as long as the edge set is acyclic (no cycle edges supplied).
  cat > "$orch" <<'EOF'
{
  "stages": [
    {"id": "branch-a"},
    {
      "id": "router",
      "router": {
        "allowedTargets": ["branch-a"],
        "defaultTarget": "branch-a",
        "onInvalid": "fail"
      }
    }
  ]
}
EOF
  run python3 "$ROUTER_CONTRACT_PY" validate-orchestration \
    --orchestration "$orch" --mode graph
  rm -f "$orch"
  [ "$status" -eq 0 ]
}

@test "graph mode rejects backward routing target when it would form a cycle" {
  command -v python3 >/dev/null || skip "python3 required"
  local orch edges_json
  orch="$(mktemp)"
  cat > "$orch" <<'EOF'
{
  "stages": [
    {"id": "branch-a"},
    {
      "id": "router",
      "router": {
        "allowedTargets": ["branch-a"],
        "defaultTarget": "branch-a",
        "onInvalid": "fail"
      }
    }
  ]
}
EOF
  # Supply an edge set where branch-a -> router, creating a cycle if we add router -> branch-a.
  edges_json='[{"from":"branch-a","to":"router","reasons":["declared"]}]'
  run python3 "$ROUTER_CONTRACT_PY" validate-orchestration \
    --orchestration "$orch" --mode graph \
    --graph-edges-json "$edges_json"
  rm -f "$orch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cycle"* ]]
}

@test "graph mode allows routing to a node inside a former parallel group (wave-middle)" {
  command -v python3 >/dev/null || skip "python3 required"
  local orch
  orch="$(mktemp)"
  # wave-b is the second member of the parallel wave; sequential mode would
  # reject this as "routing into the middle of a parallel wave".
  cat > "$orch" <<'EOF'
{
  "stages": [
    {
      "id": "router",
      "router": {
        "allowedTargets": ["wave-b"],
        "defaultTarget": "wave-b",
        "onInvalid": "fail"
      }
    },
    {"id": "wave-a"},
    {"id": "wave-b"}
  ],
  "parallelStages": ["wave-a, wave-b"]
}
EOF
  run python3 "$ROUTER_CONTRACT_PY" validate-orchestration \
    --orchestration "$orch" --mode graph
  rm -f "$orch"
  [ "$status" -eq 0 ]
}

@test "sequential mode rejects backward routing exactly as before" {
  command -v python3 >/dev/null || skip "python3 required"
  local orch
  orch="$(mktemp)"
  cat > "$orch" <<'EOF'
{
  "stages": [
    {"id": "branch-a"},
    {
      "id": "router",
      "router": {
        "allowedTargets": ["branch-a"],
        "defaultTarget": "branch-a",
        "onInvalid": "fail"
      }
    }
  ]
}
EOF
  run python3 "$ROUTER_CONTRACT_PY" validate-orchestration \
    --orchestration "$orch" --mode sequential
  rm -f "$orch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"backward routing forbidden"* ]]
}

@test "sequential mode rejects backward routing without explicit mode flag" {
  command -v python3 >/dev/null || skip "python3 required"
  local orch
  orch="$(mktemp)"
  cat > "$orch" <<'EOF'
{
  "stages": [
    {"id": "branch-a"},
    {
      "id": "router",
      "router": {
        "allowedTargets": ["branch-a"],
        "defaultTarget": "branch-a",
        "onInvalid": "fail"
      }
    }
  ]
}
EOF
  run python3 "$ROUTER_CONTRACT_PY" validate-orchestration \
    --orchestration "$orch"
  rm -f "$orch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"backward routing forbidden"* ]]
}

@test "sequential mode rejects routing into parallel wave middle unchanged" {
  command -v python3 >/dev/null || skip "python3 required"
  local orch
  orch="$(mktemp)"
  cat > "$orch" <<'EOF'
{
  "stages": [
    {
      "id": "router",
      "router": {
        "allowedTargets": ["wave-b"],
        "defaultTarget": "wave-b",
        "onInvalid": "fail"
      }
    },
    {"id": "wave-a"},
    {"id": "wave-b"}
  ],
  "parallelStages": ["wave-a, wave-b"]
}
EOF
  run python3 "$ROUTER_CONTRACT_PY" validate-orchestration \
    --orchestration "$orch"
  rm -f "$orch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"parallel wave"* ]]
}

@test "graph mode resolve-target accepts backward target" {
  command -v python3 >/dev/null || skip "python3 required"
  local artifact
  artifact="$(mktemp)"
  printf '{"target":"branch-a","reason":"test","confidence":0.9}' > "$artifact"
  local router_json='{"allowedTargets":["branch-a"],"defaultTarget":"branch-a","onInvalid":"fail"}'
  # branch-a is at index 0, router at index 1 -- backward in sequential model
  run python3 "$ROUTER_CONTRACT_PY" resolve-target \
    --artifact "$artifact" \
    --router-json "$router_json" \
    --stage-index 1 \
    --stage-ids-json '["branch-a","router"]' \
    --mode graph
  rm -f "$artifact"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"target"'* && "$output" == *'"branch-a"'* ]]
}

# ---------------------------------------------------------------------------
# graph-schedule.sh: router skip propagation (unit-level, no real dispatch)
# ---------------------------------------------------------------------------

# Build a graph JSON with a router node, two branches, and a shared tail.
# Topology:
#   router -> branch-a (selected)
#   router -> branch-b (not selected)
#   branch-b -> child-of-b   (exclusive to branch-b, should be cascade-skipped)
#   branch-a -> shared-tail
#   branch-b -> shared-tail  (reachable via branch-a too, must NOT be skipped)
_write_router_graph() {
  local out_path="$1"
  python3 - "$out_path" <<'PY'
import json, sys
out_path = sys.argv[1]
nodes = [
    {
        "id": "router",
        "type": "router",
        "dependsOn": [],
        "derivedFrom": "stage",
        "stage": {
            "id": "router",
            "runtime": "cursor",
            "router": {
                "allowedTargets": ["branch-a", "branch-b"],
                "defaultTarget": "branch-a",
                "onInvalid": "fail"
            },
            "artifacts": [{"path": ".ralph-workspace/artifacts/test/route.json",
                           "schema": "bundle/.ralph/schemas/router-decision.schema.json"}],
            "_inlineTodos": [],
        },
    },
    {
        "id": "branch-a",
        "type": "agent",
        "dependsOn": ["router"],
        "derivedFrom": "stage",
        "stage": {"id": "branch-a", "runtime": "cursor", "role": "research",
                  "_inlineTodos": []},
    },
    {
        "id": "branch-b",
        "type": "agent",
        "dependsOn": ["router"],
        "derivedFrom": "stage",
        "stage": {"id": "branch-b", "runtime": "cursor", "role": "research",
                  "_inlineTodos": []},
    },
    {
        "id": "child-of-b",
        "type": "agent",
        "dependsOn": ["branch-b"],
        "derivedFrom": "stage",
        "stage": {"id": "child-of-b", "runtime": "cursor", "role": "research",
                  "_inlineTodos": []},
    },
    {
        "id": "shared-tail",
        "type": "agent",
        "dependsOn": ["branch-a", "branch-b"],
        "derivedFrom": "stage",
        "stage": {"id": "shared-tail", "runtime": "cursor", "role": "research",
                  "_inlineTodos": []},
    },
]
edges = [
    {"from": "router", "to": "branch-a", "reasons": ["declared"]},
    {"from": "router", "to": "branch-b", "reasons": ["declared"]},
    {"from": "branch-b", "to": "child-of-b", "reasons": ["declared"]},
    {"from": "branch-a", "to": "shared-tail", "reasons": ["declared"]},
    {"from": "branch-b", "to": "shared-tail", "reasons": ["declared"]},
]
doc = {
    "schemaVersion": 2,
    "ralphVersion": "1.0.0",
    "name": "router-test",
    "namespace": "router-test",
    "maxParallel": 4,
    "failurePolicy": "drain",
    "nodes": nodes,
    "edges": edges,
}
with open(out_path, "w", encoding="utf-8") as fh:
    json.dump(doc, fh)
PY
}

@test "router skip marks non-selected branch as skipped" {
  command -v python3 >/dev/null || skip "python3 required"
  local tmpd graph_file
  tmpd="$(mktemp -d)"
  graph_file="$tmpd/router.graph.json"
  _write_router_graph "$graph_file"

  graph_schedule_load_index "$graph_file"
  GRAPH_SCHEDULE_GRAPH_JSON="$graph_file"

  # Simulate router succeeding: release its successors (decrement indegrees).
  _graph_schedule_release_successors "router"
  # Set router state to succeeded.
  router_idx="$(graph_schedule_index_map_get "router")"
  GRAPH_NODE_STATES[$router_idx]="succeeded"

  # Apply the router skip with branch-a selected.
  _graph_schedule_mark_router_skipped "router" "branch-a" "branch-a branch-b"

  branch_b_idx="$(graph_schedule_index_map_get "branch-b")"
  [ "${GRAPH_NODE_STATES[$branch_b_idx]}" = "skipped" ]

  rm -rf "$tmpd"
}

@test "router skip does not skip the selected branch" {
  command -v python3 >/dev/null || skip "python3 required"
  local tmpd graph_file
  tmpd="$(mktemp -d)"
  graph_file="$tmpd/router.graph.json"
  _write_router_graph "$graph_file"

  graph_schedule_load_index "$graph_file"
  GRAPH_SCHEDULE_GRAPH_JSON="$graph_file"

  _graph_schedule_release_successors "router"
  router_idx="$(graph_schedule_index_map_get "router")"
  GRAPH_NODE_STATES[$router_idx]="succeeded"

  _graph_schedule_mark_router_skipped "router" "branch-a" "branch-a branch-b"

  branch_a_idx="$(graph_schedule_index_map_get "branch-a")"
  [ "${GRAPH_NODE_STATES[$branch_a_idx]}" = "pending" ]

  rm -rf "$tmpd"
}

@test "router skip cascades to exclusive descendant of skipped branch" {
  command -v python3 >/dev/null || skip "python3 required"
  local tmpd graph_file
  tmpd="$(mktemp -d)"
  graph_file="$tmpd/router.graph.json"
  _write_router_graph "$graph_file"

  graph_schedule_load_index "$graph_file"
  GRAPH_SCHEDULE_GRAPH_JSON="$graph_file"

  _graph_schedule_release_successors "router"
  router_idx="$(graph_schedule_index_map_get "router")"
  GRAPH_NODE_STATES[$router_idx]="succeeded"

  _graph_schedule_mark_router_skipped "router" "branch-a" "branch-a branch-b"

  # child-of-b depends only on branch-b, which was skipped -> must be cascade-skipped.
  child_idx="$(graph_schedule_index_map_get "child-of-b")"
  [ "${GRAPH_NODE_STATES[$child_idx]}" = "skipped" ]

  rm -rf "$tmpd"
}

@test "router skip does not skip descendant that has another live path" {
  command -v python3 >/dev/null || skip "python3 required"
  local tmpd graph_file
  tmpd="$(mktemp -d)"
  graph_file="$tmpd/router.graph.json"
  _write_router_graph "$graph_file"

  graph_schedule_load_index "$graph_file"
  GRAPH_SCHEDULE_GRAPH_JSON="$graph_file"

  _graph_schedule_release_successors "router"
  router_idx="$(graph_schedule_index_map_get "router")"
  GRAPH_NODE_STATES[$router_idx]="succeeded"

  _graph_schedule_mark_router_skipped "router" "branch-a" "branch-a branch-b"

  # shared-tail depends on both branch-a (live) and branch-b (skipped).
  # branch-a has not skipped its predecessor slot, so shared-tail must NOT be skipped.
  tail_idx="$(graph_schedule_index_map_get "shared-tail")"
  [ "${GRAPH_NODE_STATES[$tail_idx]}" = "pending" ]

  rm -rf "$tmpd"
}

@test "router skip releases indegree of shared-tail so it becomes ready after branch-a succeeds" {
  command -v python3 >/dev/null || skip "python3 required"
  local tmpd graph_file
  tmpd="$(mktemp -d)"
  graph_file="$tmpd/router.graph.json"
  _write_router_graph "$graph_file"

  graph_schedule_load_index "$graph_file"
  GRAPH_SCHEDULE_GRAPH_JSON="$graph_file"

  _graph_schedule_release_successors "router"
  router_idx="$(graph_schedule_index_map_get "router")"
  GRAPH_NODE_STATES[$router_idx]="succeeded"

  _graph_schedule_mark_router_skipped "router" "branch-a" "branch-a branch-b"

  # After branch-a succeeds, it releases shared-tail's remaining indegree.
  _graph_schedule_release_successors "branch-a"
  branch_a_idx="$(graph_schedule_index_map_get "branch-a")"
  GRAPH_NODE_STATES[$branch_a_idx]="succeeded"

  tail_idx="$(graph_schedule_index_map_get "shared-tail")"
  # shared-tail remaining indegree should now be 0 (branch-b released by skip,
  # branch-a released by success) -> becomes ready (pending with indegree=0).
  [ "${GRAPH_NODE_REMAINING_INDEGREE[$tail_idx]}" = "0" ]
  [ "${GRAPH_NODE_STATES[$tail_idx]}" = "pending" ]

  rm -rf "$tmpd"
}
