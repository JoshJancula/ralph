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

# ---------------------------------------------------------------------------
# Jev pre-agent router classifier (RALPH_JEV_ROUTING)
# ---------------------------------------------------------------------------

_jev_router_write_triage_graph() {
  local out_path="$1"
  python3 - "$out_path" <<'PY'
import json, sys
out_path = sys.argv[1]
nodes = [
    {
        "id": "classify",
        "type": "router",
        "dependsOn": [],
        "derivedFrom": "stage",
        "stage": {
            "id": "classify",
            "runtime": "cursor",
            "router": {
                "allowedTargets": ["scope-request", "deep-investigation"],
                "defaultTarget": "deep-investigation",
                "onInvalid": "default",
            },
            "artifacts": [
                {
                    "path": ".ralph-workspace/artifacts/test/triage-classification.md",
                    "required": True,
                },
                {
                    "path": ".ralph-workspace/artifacts/test/triage-decision.json",
                    "required": True,
                    "schema": "bundle/.ralph/schemas/router-decision.schema.json",
                },
            ],
            "_inlineTodos": [],
        },
    },
    {
        "id": "scope-request",
        "type": "agent",
        "dependsOn": ["classify"],
        "derivedFrom": "stage",
        "stage": {"id": "scope-request", "runtime": "cursor", "_inlineTodos": []},
    },
    {
        "id": "deep-investigation",
        "type": "agent",
        "dependsOn": ["classify"],
        "derivedFrom": "stage",
        "stage": {"id": "deep-investigation", "runtime": "cursor", "_inlineTodos": []},
    },
]
edges = [
    {"from": "classify", "to": "scope-request", "reasons": ["declared"]},
    {"from": "classify", "to": "deep-investigation", "reasons": ["declared"]},
]
doc = {
    "schemaVersion": 2,
    "ralphVersion": "1.0.0",
    "name": "jev-router-test",
    "namespace": "test",
    "maxParallel": 2,
    "failurePolicy": "drain",
    "nodes": nodes,
    "edges": edges,
}
with open(out_path, "w", encoding="utf-8") as fh:
    json.dump(doc, fh)
PY
}

_jev_router_fixture() {
  local out_path="$1"
  local choice="$2"
  local confidence="$3"
  python3 - "$out_path" "$choice" "$confidence" <<'PY'
import json, sys
out, choice, conf = sys.argv[1], sys.argv[2], float(sys.argv[3])
doc = {
    "model": "jev-1.13.0",
    "answers": {
        "target": {
            "choice": choice,
            "probabilities": {choice: conf, "other": max(0.0, 1.0 - conf)},
            "confidence": conf,
        },
        "sufficiently_specified": {"noul": conf},
    },
    "usage": {"input_tokens": 40, "output_tokens": 8},
}
with open(out, "w", encoding="utf-8") as fh:
    json.dump(doc, fh)
PY
}

@test "jev router questions populate criteria from allowedTargets at call time" {
  command -v jq >/dev/null || skip "jq required"
  local questions
  export RALPH_DIR="$REPO_ROOT/bundle/.ralph"
  export RALPH_JEV_REGISTRY="$REPO_ROOT/bundle/.ralph/jev/questions.registry.json"
  source "$REPO_ROOT/bundle/.ralph/bash-lib/jev/jev-policy.sh"
  questions="$(_graph_schedule_jev_router_questions '["scope-request","deep-investigation"]')"
  echo "$questions" | jq -e '
    (.target.criteria | has("scope-request"))
    and (.target.criteria | has("deep-investigation"))
    and ((.target.criteria | keys | length) == 2)
    and (.sufficiently_specified.type == "noul")
  '
}

@test "jev router: RALPH_JEV_ROUTING unset falls through without consulting Jev" {
  command -v python3 >/dev/null || skip "python3 required"
  local tmpd graph_file
  tmpd="$(mktemp -d)"
  graph_file="$tmpd/triage.graph.json"
  _jev_router_write_triage_graph "$graph_file"

  graph_schedule_load_index "$graph_file"
  GRAPH_SCHEDULE_GRAPH_JSON="$graph_file"
  GRAPH_SCHEDULE_WORKSPACE="$tmpd/ws"
  mkdir -p "$GRAPH_SCHEDULE_WORKSPACE"

  unset RALPH_JEV_ROUTING RALPH_JEV TYPESAFE_API_KEY
  run _graph_schedule_try_jev_router_node "classify"
  [ "$status" -eq 1 ]
  [ ! -f "$GRAPH_SCHEDULE_WORKSPACE/.ralph-workspace/artifacts/test/triage-decision.json" ]

  rm -rf "$tmpd"
}

@test "jev router: high-confidence ask_act returns act payload" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"
  local tmpd fixture_dir
  tmpd="$(mktemp -d)"
  fixture_dir="$tmpd/fixtures"
  mkdir -p "$fixture_dir" "$tmpd/jev-state" "$tmpd/config" "$tmpd/home"
  _jev_router_fixture "$fixture_dir/graph.router-confidence.json" "scope-request" "0.92"

  export RALPH_DIR="$REPO_ROOT/bundle/.ralph"
  export RALPH_JEV_REGISTRY="$REPO_ROOT/bundle/.ralph/jev/questions.registry.json"
  export RALPH_JEV=1
  export RALPH_JEV_ROUTING=1
  export RALPH_JEV_ENV_FILE=0
  export TYPESAFE_API_KEY="test-key-jev-router"
  export JEV_TRANSPORT=fixture
  export JEV_FIXTURE_DIR="$fixture_dir"
  export RALPH_JEV_STATE_DIR="$tmpd/jev-state"
  export RALPH_CONFIG_HOME="$tmpd/config"
  export HOME="$tmpd/home"
  export RALPH_WAIT_SCALE=0

  source "$REPO_ROOT/bundle/.ralph/bash-lib/jev/jev-key-store.sh"
  source "$REPO_ROOT/bundle/.ralph/bash-lib/jev/jev-client.sh"
  source "$REPO_ROOT/bundle/.ralph/bash-lib/jev/jev-policy.sh"

  run _graph_schedule_jev_router_ask_act "classify" '["scope-request","deep-investigation"]'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.target == "scope-request" and (.confidence | tonumber) >= 0.85 and (.reason | test("^jev:"))'

  unset RALPH_JEV RALPH_JEV_ROUTING TYPESAFE_API_KEY JEV_TRANSPORT JEV_FIXTURE_DIR
  rm -rf "$tmpd"
}

@test "jev router: high-confidence fixture writes schema-valid artifact and source=jev event" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"
  local tmpd graph_file fixture_dir run_dir
  tmpd="$(mktemp -d)"
  graph_file="$tmpd/triage.graph.json"
  fixture_dir="$tmpd/fixtures"
  run_dir="$tmpd/run"
  mkdir -p "$fixture_dir" "$run_dir" "$tmpd/ws" "$tmpd/jev-state" "$tmpd/config" "$tmpd/home"
  _jev_router_write_triage_graph "$graph_file"
  _jev_router_fixture "$fixture_dir/graph.router-confidence.json" "scope-request" "0.92"

  graph_schedule_load_index "$graph_file"
  GRAPH_SCHEDULE_GRAPH_JSON="$graph_file"
  GRAPH_SCHEDULE_WORKSPACE="$tmpd/ws"
  GRAPH_SCHEDULE_NAMESPACE="test"
  GRAPH_SCHEDULE_LEDGER_RUN_DIR="$run_dir"
  GRAPH_SCHEDULE_RUN_ID="jev-router-high"
  export RALPH_DIR="$REPO_ROOT/bundle/.ralph"
  export RALPH_JEV_REGISTRY="$REPO_ROOT/bundle/.ralph/jev/questions.registry.json"
  export RALPH_JEV=1
  export RALPH_JEV_ROUTING=1
  export RALPH_JEV_ENV_FILE=0
  export TYPESAFE_API_KEY="test-key-jev-router"
  export JEV_TRANSPORT=fixture
  export JEV_FIXTURE_DIR="$fixture_dir"
  export RALPH_JEV_STATE_DIR="$tmpd/jev-state"
  export RALPH_CONFIG_HOME="$tmpd/config"
  export HOME="$tmpd/home"
  export RALPH_WAIT_SCALE=0

  source "$REPO_ROOT/bundle/.ralph/bash-lib/jev/jev-key-store.sh"
  source "$REPO_ROOT/bundle/.ralph/bash-lib/jev/jev-client.sh"
  source "$REPO_ROOT/bundle/.ralph/bash-lib/jev/jev-policy.sh"

  # Call in-process (not via `run`) so GRAPH_NODE_STATES mutations stick.
  _graph_schedule_try_jev_router_node "classify"

  local decision_path="$GRAPH_SCHEDULE_WORKSPACE/.ralph-workspace/artifacts/test/triage-decision.json"
  [ -f "$decision_path" ]
  jq -e '
    .target == "scope-request"
    and (.confidence | tonumber) >= 0.85
    and (.reason | test("^jev:"))
  ' "$decision_path"

  # Machine stub for the prose artifact (Jev cannot author prose).
  [ -f "$GRAPH_SCHEDULE_WORKSPACE/.ralph-workspace/artifacts/test/triage-classification.md" ]
  grep -q 'jev: graph.router-confidence' \
    "$GRAPH_SCHEDULE_WORKSPACE/.ralph-workspace/artifacts/test/triage-classification.md"

  classify_idx="$(graph_schedule_index_map_get "classify")"
  [ "${GRAPH_NODE_STATES[$classify_idx]}" = "succeeded" ]

  deep_idx="$(graph_schedule_index_map_get "deep-investigation")"
  [ "${GRAPH_NODE_STATES[$deep_idx]}" = "skipped" ]

  [ -f "$run_dir/events.jsonl" ]
  jq -s -e '
    map(select(.event == "routing-decision"))
    | length == 1
    and .[0].details.source == "jev"
    and .[0].details.selectedTarget == "scope-request"
    and .[0].details.questionSetId == "graph.router-confidence"
    and (.[0].details | has("alternatives"))
    and (.[0].details | has("reason"))
    and (.[0].details | has("confidence"))
    and (.[0].details | has("registryVersion"))
  ' "$run_dir/events.jsonl"

  unset RALPH_JEV RALPH_JEV_ROUTING TYPESAFE_API_KEY JEV_TRANSPORT JEV_FIXTURE_DIR
  rm -rf "$tmpd"
}

@test "jev router: low-confidence fixture falls through to agent (no artifact)" {
  command -v python3 >/dev/null || skip "python3 required"
  local tmpd graph_file fixture_dir
  tmpd="$(mktemp -d)"
  graph_file="$tmpd/triage.graph.json"
  fixture_dir="$tmpd/fixtures"
  mkdir -p "$fixture_dir" "$tmpd/ws" "$tmpd/jev-state" "$tmpd/config" "$tmpd/home"
  _jev_router_write_triage_graph "$graph_file"
  _jev_router_fixture "$fixture_dir/graph.router-confidence.json" "scope-request" "0.40"

  graph_schedule_load_index "$graph_file"
  GRAPH_SCHEDULE_GRAPH_JSON="$graph_file"
  GRAPH_SCHEDULE_WORKSPACE="$tmpd/ws"
  GRAPH_SCHEDULE_NAMESPACE="test"
  export RALPH_DIR="$REPO_ROOT/bundle/.ralph"
  export RALPH_JEV_REGISTRY="$REPO_ROOT/bundle/.ralph/jev/questions.registry.json"
  export RALPH_JEV=1
  export RALPH_JEV_ROUTING=1
  export RALPH_JEV_ENV_FILE=0
  export TYPESAFE_API_KEY="test-key-jev-router"
  export JEV_TRANSPORT=fixture
  export JEV_FIXTURE_DIR="$fixture_dir"
  export RALPH_JEV_STATE_DIR="$tmpd/jev-state"
  export RALPH_CONFIG_HOME="$tmpd/config"
  export HOME="$tmpd/home"
  export RALPH_WAIT_SCALE=0

  source "$REPO_ROOT/bundle/.ralph/bash-lib/jev/jev-key-store.sh"
  source "$REPO_ROOT/bundle/.ralph/bash-lib/jev/jev-client.sh"
  source "$REPO_ROOT/bundle/.ralph/bash-lib/jev/jev-policy.sh"

  # In-process: fall-through must leave the node pending for agent spawn.
  if _graph_schedule_try_jev_router_node "classify"; then
    echo "expected fall-through (non-zero) for low confidence" >&2
    return 1
  fi
  [ ! -f "$GRAPH_SCHEDULE_WORKSPACE/.ralph-workspace/artifacts/test/triage-decision.json" ]
  classify_idx="$(graph_schedule_index_map_get "classify")"
  [ "${GRAPH_NODE_STATES[$classify_idx]}" = "pending" ]

  unset RALPH_JEV RALPH_JEV_ROUTING TYPESAFE_API_KEY JEV_TRANSPORT JEV_FIXTURE_DIR
  rm -rf "$tmpd"
}

@test "jev router: target outside allowedTargets is rejected like an agent invalid target" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"
  local tmpd graph_file fixture_dir run_dir decision_path
  tmpd="$(mktemp -d)"
  graph_file="$tmpd/triage.graph.json"
  fixture_dir="$tmpd/fixtures"
  run_dir="$tmpd/run"
  mkdir -p "$fixture_dir" "$run_dir" "$tmpd/ws" "$tmpd/jev-state" "$tmpd/config" "$tmpd/home"
  _jev_router_write_triage_graph "$graph_file"
  # Fixture names a target not in allowedTargets.
  _jev_router_fixture "$fixture_dir/graph.router-confidence.json" "not-an-allowed-target" "0.95"

  graph_schedule_load_index "$graph_file"
  GRAPH_SCHEDULE_GRAPH_JSON="$graph_file"
  GRAPH_SCHEDULE_WORKSPACE="$tmpd/ws"
  GRAPH_SCHEDULE_NAMESPACE="test"
  GRAPH_SCHEDULE_LEDGER_RUN_DIR="$run_dir"
  GRAPH_SCHEDULE_RUN_ID="jev-router-invalid"
  export RALPH_DIR="$REPO_ROOT/bundle/.ralph"
  export RALPH_JEV_REGISTRY="$REPO_ROOT/bundle/.ralph/jev/questions.registry.json"
  export RALPH_JEV=1
  export RALPH_JEV_ROUTING=1
  export RALPH_JEV_ENV_FILE=0
  export TYPESAFE_API_KEY="test-key-jev-router"
  export JEV_TRANSPORT=fixture
  export JEV_FIXTURE_DIR="$fixture_dir"
  export RALPH_JEV_STATE_DIR="$tmpd/jev-state"
  export RALPH_CONFIG_HOME="$tmpd/config"
  export HOME="$tmpd/home"
  export RALPH_WAIT_SCALE=0

  source "$REPO_ROOT/bundle/.ralph/bash-lib/jev/jev-key-store.sh"
  source "$REPO_ROOT/bundle/.ralph/bash-lib/jev/jev-client.sh"
  source "$REPO_ROOT/bundle/.ralph/bash-lib/jev/jev-policy.sh"

  _graph_schedule_try_jev_router_node "classify"

  decision_path="$GRAPH_SCHEDULE_WORKSPACE/.ralph-workspace/artifacts/test/triage-decision.json"
  [ -f "$decision_path" ]
  # Artifact still records Jev's raw pick; resolve-target with onInvalid:default
  # selects defaultTarget (deep-investigation), same as an invalid agent pick.
  jq -e '.target == "not-an-allowed-target"' "$decision_path"

  [ -f "$run_dir/events.jsonl" ]
  jq -s -e '
    map(select(.event == "routing-decision"))
    | length == 1
    and .[0].details.selectedTarget == "deep-investigation"
  ' "$run_dir/events.jsonl"

  unset RALPH_JEV RALPH_JEV_ROUTING TYPESAFE_API_KEY JEV_TRANSPORT JEV_FIXTURE_DIR
  rm -rf "$tmpd"
}
