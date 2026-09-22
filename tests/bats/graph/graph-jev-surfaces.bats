#!/usr/bin/env bats
# Track 3 (Jev surfaces) sourced-function suite.
# Confidence-threshold routing, routing-decision events, Jev router validation,
# and failure-class structured-evidence isolation. Cheap: source libs and call
# functions; never drive a full graph runner.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/plan-todo.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-schedule.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-failure-classify.sh"

RALPH_DIR="$REPO_ROOT/bundle/.ralph"
export RALPH_DIR

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

_t3_write_router_graph() {
  # Args: out_path [include_default=1]
  # Topology: router -> branch-a | branch-b; defaultTarget branch-a when included.
  local out_path="$1"
  local include_default="${2:-1}"
  python3 - "$out_path" "$include_default" <<'PY'
import json, sys
out_path, include_default = sys.argv[1], sys.argv[2] == "1"
router = {
    "allowedTargets": ["branch-a", "branch-b"],
    "onInvalid": "fail",
}
if include_default:
    router["defaultTarget"] = "branch-a"
nodes = [
    {
        "id": "router",
        "type": "router",
        "dependsOn": [],
        "derivedFrom": "stage",
        "stage": {
            "id": "router",
            "runtime": "cursor",
            "router": router,
            "artifacts": [
                {
                    "path": ".ralph-workspace/artifacts/t3/route.json",
                    "schema": "bundle/.ralph/schemas/router-decision.schema.json",
                }
            ],
            "_inlineTodos": [],
        },
    },
    {
        "id": "branch-a",
        "type": "agent",
        "dependsOn": ["router"],
        "derivedFrom": "stage",
        "stage": {"id": "branch-a", "runtime": "cursor", "_inlineTodos": []},
    },
    {
        "id": "branch-b",
        "type": "agent",
        "dependsOn": ["router"],
        "derivedFrom": "stage",
        "stage": {"id": "branch-b", "runtime": "cursor", "_inlineTodos": []},
    },
]
doc = {
    "schemaVersion": 2,
    "ralphVersion": "1.0.0",
    "name": "t3-router",
    "namespace": "t3",
    "maxParallel": 2,
    "failurePolicy": "drain",
    "nodes": nodes,
    "edges": [
        {"from": "router", "to": "branch-a", "reasons": ["declared"]},
        {"from": "router", "to": "branch-b", "reasons": ["declared"]},
    ],
}
with open(out_path, "w", encoding="utf-8") as fh:
    json.dump(doc, fh)
PY
}

_t3_write_triage_graph() {
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
                    "path": ".ralph-workspace/artifacts/t3/triage-classification.md",
                    "required": True,
                },
                {
                    "path": ".ralph-workspace/artifacts/t3/triage-decision.json",
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
doc = {
    "schemaVersion": 2,
    "ralphVersion": "1.0.0",
    "name": "t3-triage",
    "namespace": "t3",
    "maxParallel": 2,
    "failurePolicy": "drain",
    "nodes": nodes,
    "edges": [
        {"from": "classify", "to": "scope-request", "reasons": ["declared"]},
        {"from": "classify", "to": "deep-investigation", "reasons": ["declared"]},
    ],
}
with open(out_path, "w", encoding="utf-8") as fh:
    json.dump(doc, fh)
PY
}

_t3_write_decision() {
  local path="$1" target="$2" confidence="$3" reason="${4:-agent pick}"
  mkdir -p "$(dirname "$path")"
  jq -nc \
    --arg t "$target" \
    --arg r "$reason" \
    --argjson c "$confidence" \
    '{target: $t, reason: $r, confidence: $c}' > "$path"
}

_t3_jev_router_fixture() {
  local out_path="$1" choice="$2" confidence="$3"
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

_t3_jev_failure_fixture() {
  local out_path="$1" choice="$2" confidence="$3"
  python3 - "$out_path" "$choice" "$confidence" <<'PY'
import json, sys
out, choice, conf = sys.argv[1], sys.argv[2], float(sys.argv[3])
classes = [
    "transient-runtime",
    "agent-correctable",
    "operator-permission",
    "plan-contract",
    "terminal-configuration",
    "integrity",
    "cancelled",
    "unknown",
]
probs = {c: (conf if c == choice else max(0.0, (1.0 - conf) / max(1, len(classes) - 1))) for c in classes}
doc = {
    "model": "jev-1.13.0",
    "answers": {
        "failure_class": {
            "choice": choice,
            "probabilities": probs,
            "confidence": conf,
        }
    },
    "usage": {"input_tokens": 40, "output_tokens": 8},
}
with open(out, "w", encoding="utf-8") as fh:
    json.dump(doc, fh)
PY
}

_t3_setup_apply_env() {
  local tmpd="$1" graph_file="$2" run_id="$3"
  graph_schedule_load_index "$graph_file"
  GRAPH_SCHEDULE_GRAPH_JSON="$graph_file"
  GRAPH_SCHEDULE_WORKSPACE="$tmpd/ws"
  GRAPH_SCHEDULE_NAMESPACE="t3"
  GRAPH_SCHEDULE_LEDGER_RUN_DIR="$tmpd/run"
  GRAPH_SCHEDULE_RUN_ID="$run_id"
  mkdir -p "$GRAPH_SCHEDULE_WORKSPACE" "$GRAPH_SCHEDULE_LEDGER_RUN_DIR"
  export RALPH_JEV_REGISTRY="$REPO_ROOT/bundle/.ralph/jev/questions.registry.json"
}

_t3_assert_routing_event() {
  local events="$1" source="$2" selected="$3"
  [ -f "$events" ]
  jq -s -e \
    --arg src "$source" \
    --arg sel "$selected" \
    '
      map(select(.event == "routing-decision"))
      | length == 1
      and .[0].details.source == $src
      and .[0].details.selectedTarget == $sel
      and (.[0].details | has("alternatives"))
      and (.[0].details | has("reason"))
      and (.[0].details | has("confidence"))
      and .[0].details.questionSetId == "graph.router-confidence"
      and (.[0].details | has("registryVersion"))
    ' "$events"
}

# ---------------------------------------------------------------------------
# 1-3: confidence threshold (no Jev required)
# ---------------------------------------------------------------------------

@test "t3 confidence: below actThreshold takes defaultTarget and source=default" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"
  local tmpd graph_file artifact
  tmpd="$(mktemp -d)"
  graph_file="$tmpd/router.graph.json"
  _t3_write_router_graph "$graph_file" 1
  _t3_setup_apply_env "$tmpd" "$graph_file" "t3-conf-below"
  unset RALPH_JEV TYPESAFE_API_KEY RALPH_JEV_ROUTING

  artifact="$GRAPH_SCHEDULE_WORKSPACE/.ralph-workspace/artifacts/t3/route.json"
  # Agent picks branch-b below actThreshold 0.85; scheduler must force defaultTarget.
  _t3_write_decision "$artifact" "branch-b" "0.40" "torn between branches"

  _graph_schedule_apply_router_decision "router" "$graph_file" "$GRAPH_SCHEDULE_WORKSPACE"

  local a_idx b_idx
  a_idx="$(graph_schedule_index_map_get "branch-a")"
  b_idx="$(graph_schedule_index_map_get "branch-b")"
  [ "${GRAPH_NODE_STATES[$a_idx]}" = "pending" ]
  [ "${GRAPH_NODE_STATES[$b_idx]}" = "skipped" ]

  _t3_assert_routing_event "$tmpd/run/events.jsonl" "default" "branch-a"
  jq -s -e '
    map(select(.event == "routing-decision"))
    | .[0].details.confidence == 0.40
  ' "$tmpd/run/events.jsonl"

  rm -rf "$tmpd"
}

@test "t3 confidence: above actThreshold honors agent target and source=agent" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"
  local tmpd graph_file artifact
  tmpd="$(mktemp -d)"
  graph_file="$tmpd/router.graph.json"
  _t3_write_router_graph "$graph_file" 1
  _t3_setup_apply_env "$tmpd" "$graph_file" "t3-conf-above"
  unset RALPH_JEV TYPESAFE_API_KEY RALPH_JEV_ROUTING

  artifact="$GRAPH_SCHEDULE_WORKSPACE/.ralph-workspace/artifacts/t3/route.json"
  _t3_write_decision "$artifact" "branch-b" "0.92" "clear preference for branch-b"

  _graph_schedule_apply_router_decision "router" "$graph_file" "$GRAPH_SCHEDULE_WORKSPACE"

  local a_idx b_idx
  a_idx="$(graph_schedule_index_map_get "branch-a")"
  b_idx="$(graph_schedule_index_map_get "branch-b")"
  [ "${GRAPH_NODE_STATES[$b_idx]}" = "pending" ]
  [ "${GRAPH_NODE_STATES[$a_idx]}" = "skipped" ]

  _t3_assert_routing_event "$tmpd/run/events.jsonl" "agent" "branch-b"

  rm -rf "$tmpd"
}

@test "t3 confidence: no defaultTarget honors low-confidence agent pick without failing" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"
  local tmpd graph_file artifact
  tmpd="$(mktemp -d)"
  graph_file="$tmpd/router.graph.json"
  _t3_write_router_graph "$graph_file" 0
  _t3_setup_apply_env "$tmpd" "$graph_file" "t3-conf-no-default"
  unset RALPH_JEV TYPESAFE_API_KEY RALPH_JEV_ROUTING

  artifact="$GRAPH_SCHEDULE_WORKSPACE/.ralph-workspace/artifacts/t3/route.json"
  _t3_write_decision "$artifact" "branch-b" "0.30" "low confidence but no fallback"

  # Must succeed (not fail the node) and honor the agent pick.
  _graph_schedule_apply_router_decision "router" "$graph_file" "$GRAPH_SCHEDULE_WORKSPACE"

  local a_idx b_idx
  a_idx="$(graph_schedule_index_map_get "branch-a")"
  b_idx="$(graph_schedule_index_map_get "branch-b")"
  [ "${GRAPH_NODE_STATES[$b_idx]}" = "pending" ]
  [ "${GRAPH_NODE_STATES[$a_idx]}" = "skipped" ]

  _t3_assert_routing_event "$tmpd/run/events.jsonl" "agent" "branch-b"

  rm -rf "$tmpd"
}

# ---------------------------------------------------------------------------
# 4-5: confident / invalid Jev router answers
# ---------------------------------------------------------------------------

@test "t3 jev router: confident fixture source=jev and target validated against allowedTargets" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"
  local tmpd graph_file fixture_dir
  tmpd="$(mktemp -d)"
  graph_file="$tmpd/triage.graph.json"
  fixture_dir="$tmpd/fixtures"
  mkdir -p "$fixture_dir" "$tmpd/jev-state" "$tmpd/config" "$tmpd/home"
  _t3_write_triage_graph "$graph_file"
  _t3_jev_router_fixture "$fixture_dir/graph.router-confidence.json" "scope-request" "0.92"
  _t3_setup_apply_env "$tmpd" "$graph_file" "t3-jev-confident"

  export RALPH_JEV_REGISTRY="$REPO_ROOT/bundle/.ralph/jev/questions.registry.json"
  export RALPH_JEV=1
  export RALPH_JEV_ROUTING=1
  export RALPH_JEV_ENV_FILE=0
  export TYPESAFE_API_KEY="test-key-t3-jev"
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

  local decision_path="$GRAPH_SCHEDULE_WORKSPACE/.ralph-workspace/artifacts/t3/triage-decision.json"
  [ -f "$decision_path" ]
  jq -e '
    .target == "scope-request"
    and (.confidence | tonumber) >= 0.85
    and (.reason | test("^jev:"))
  ' "$decision_path"

  local deep_idx
  deep_idx="$(graph_schedule_index_map_get "deep-investigation")"
  [ "${GRAPH_NODE_STATES[$deep_idx]}" = "skipped" ]

  _t3_assert_routing_event "$tmpd/run/events.jsonl" "jev" "scope-request"

  unset RALPH_JEV RALPH_JEV_ROUTING TYPESAFE_API_KEY JEV_TRANSPORT JEV_FIXTURE_DIR
  rm -rf "$tmpd"
}

@test "t3 jev router: agent-typed node with stage.router is eligible; no router metadata is not" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"
  local tmpd graph_file bare_file fixture_dir
  tmpd="$(mktemp -d)"
  graph_file="$tmpd/triage.graph.json"
  bare_file="$tmpd/bare.graph.json"
  fixture_dir="$tmpd/fixtures"
  mkdir -p "$fixture_dir" "$tmpd/jev-state" "$tmpd/config" "$tmpd/home"
  _t3_write_triage_graph "$graph_file"
  jq '(.nodes[] | select(.id == "classify") | .type) = "agent"' "$graph_file" >"$graph_file.tmp"
  mv "$graph_file.tmp" "$graph_file"
  jq '(.nodes[] | select(.id == "classify")) |= (.type = "router" | del(.stage.router))' \
    "$graph_file" >"$bare_file"
  _t3_jev_router_fixture "$fixture_dir/graph.router-confidence.json" "scope-request" "0.92"
  _t3_setup_apply_env "$tmpd" "$graph_file" "t3-jev-agent-router"

  export RALPH_JEV_REGISTRY="$REPO_ROOT/bundle/.ralph/jev/questions.registry.json"
  export RALPH_JEV=1
  export RALPH_JEV_ROUTING=1
  export RALPH_JEV_ENV_FILE=0
  export TYPESAFE_API_KEY="test-key-t3-jev"
  export JEV_TRANSPORT=fixture
  export JEV_FIXTURE_DIR="$fixture_dir"
  export RALPH_JEV_STATE_DIR="$tmpd/jev-state"
  export RALPH_CONFIG_HOME="$tmpd/config"
  export HOME="$tmpd/home"
  export RALPH_WAIT_SCALE=0

  source "$REPO_ROOT/bundle/.ralph/bash-lib/jev/jev-key-store.sh"
  source "$REPO_ROOT/bundle/.ralph/bash-lib/jev/jev-client.sh"
  source "$REPO_ROOT/bundle/.ralph/bash-lib/jev/jev-policy.sh"

  # Router metadata absent: not eligible, even for type router.
  GRAPH_SCHEDULE_GRAPH_JSON="$bare_file"
  run _graph_schedule_node_has_router_stage "classify"
  [ "$status" -ne 0 ]
  run _graph_schedule_try_jev_router_node "classify"
  [ "$status" -ne 0 ]

  # Agent type with stage.router: eligible and handled by the Jev path.
  GRAPH_SCHEDULE_GRAPH_JSON="$graph_file"
  _graph_schedule_node_has_router_stage "classify"
  _graph_schedule_try_jev_router_node "classify"
  local deep_idx
  deep_idx="$(graph_schedule_index_map_get "deep-investigation")"
  [ "${GRAPH_NODE_STATES[$deep_idx]}" = "skipped" ]
  _t3_assert_routing_event "$tmpd/run/events.jsonl" "jev" "scope-request"

  unset RALPH_JEV RALPH_JEV_ROUTING TYPESAFE_API_KEY JEV_TRANSPORT JEV_FIXTURE_DIR
  rm -rf "$tmpd"
}

@test "t3 jev router: target outside allowedTargets rejected like an invalid agent pick" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"
  local tmpd graph_file fixture_dir decision_path
  tmpd="$(mktemp -d)"
  graph_file="$tmpd/triage.graph.json"
  fixture_dir="$tmpd/fixtures"
  mkdir -p "$fixture_dir" "$tmpd/jev-state" "$tmpd/config" "$tmpd/home"
  _t3_write_triage_graph "$graph_file"
  _t3_jev_router_fixture "$fixture_dir/graph.router-confidence.json" "not-an-allowed-target" "0.95"
  _t3_setup_apply_env "$tmpd" "$graph_file" "t3-jev-invalid"

  export RALPH_JEV_REGISTRY="$REPO_ROOT/bundle/.ralph/jev/questions.registry.json"
  export RALPH_JEV=1
  export RALPH_JEV_ROUTING=1
  export RALPH_JEV_ENV_FILE=0
  export TYPESAFE_API_KEY="test-key-t3-jev"
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

  decision_path="$GRAPH_SCHEDULE_WORKSPACE/.ralph-workspace/artifacts/t3/triage-decision.json"
  [ -f "$decision_path" ]
  # Raw Jev pick is recorded; resolve-target with onInvalid:default selects defaultTarget.
  jq -e '.target == "not-an-allowed-target"' "$decision_path"

  jq -s -e '
    map(select(.event == "routing-decision"))
    | length == 1
    and .[0].details.selectedTarget == "deep-investigation"
  ' "$tmpd/run/events.jsonl"

  # Same outcome as an agent artifact naming an invalid target with onInvalid:default.
  local agent_tmp agent_graph agent_ws agent_run agent_artifact
  agent_tmp="$(mktemp -d)"
  agent_graph="$agent_tmp/triage.graph.json"
  _t3_write_triage_graph "$agent_graph"
  agent_ws="$agent_tmp/ws"
  agent_run="$agent_tmp/run"
  mkdir -p "$agent_ws" "$agent_run"
  graph_schedule_load_index "$agent_graph"
  GRAPH_SCHEDULE_GRAPH_JSON="$agent_graph"
  GRAPH_SCHEDULE_WORKSPACE="$agent_ws"
  GRAPH_SCHEDULE_LEDGER_RUN_DIR="$agent_run"
  GRAPH_SCHEDULE_RUN_ID="t3-agent-invalid"
  agent_artifact="$agent_ws/.ralph-workspace/artifacts/t3/triage-decision.json"
  _t3_write_decision "$agent_artifact" "not-an-allowed-target" "0.95" "agent invalid pick"
  _graph_schedule_apply_router_decision "classify" "$agent_graph" "$agent_ws"
  jq -s -e '
    map(select(.event == "routing-decision"))
    | length == 1
    and .[0].details.selectedTarget == "deep-investigation"
  ' "$agent_run/events.jsonl"

  unset RALPH_JEV RALPH_JEV_ROUTING TYPESAFE_API_KEY JEV_TRANSPORT JEV_FIXTURE_DIR
  rm -rf "$tmpd" "$agent_tmp"
}

# ---------------------------------------------------------------------------
# 6: failure classification structured tiers unreachable by Jev
# ---------------------------------------------------------------------------

@test "t3 failure: structured evidence classifies identically with Jev enabled and disabled" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"
  local tmpd fixture_dir report disabled_out enabled_out
  tmpd="$(mktemp -d)"
  fixture_dir="$tmpd/fixtures"
  mkdir -p "$fixture_dir" "$tmpd/jev-state" "$tmpd/config" "$tmpd/home"
  # Fixture would claim agent-correctable; structured kind:network must win.
  _t3_jev_failure_fixture "$fixture_dir/graph.failure-class.json" "agent-correctable" "0.95"
  report='{"kind":"network","summary":"provider connection reset"}'

  unset RALPH_JEV TYPESAFE_API_KEY JEV_TRANSPORT JEV_FIXTURE_DIR \
    RALPH_JEV_STATE_DIR RALPH_JEV_ENV_FILE RALPH_JEV_REGISTRY
  disabled_out="$(graph_failure_classify "$report")"

  export RALPH_JEV_REGISTRY="$REPO_ROOT/bundle/.ralph/jev/questions.registry.json"
  export RALPH_JEV=1
  export RALPH_JEV_ENV_FILE=0
  export TYPESAFE_API_KEY="test-key-t3-failure"
  export JEV_TRANSPORT=fixture
  export JEV_FIXTURE_DIR="$fixture_dir"
  export RALPH_JEV_STATE_DIR="$tmpd/jev-state"
  export RALPH_CONFIG_HOME="$tmpd/config"
  export HOME="$tmpd/home"
  export RALPH_WAIT_SCALE=0
  enabled_out="$(graph_failure_classify "$report")"

  [ "$disabled_out" = "$enabled_out" ]
  [ "$(printf '%s' "$enabled_out" | jq -r '.classification')" = "transient-runtime" ]

  unset RALPH_JEV TYPESAFE_API_KEY JEV_TRANSPORT JEV_FIXTURE_DIR \
    RALPH_JEV_STATE_DIR RALPH_JEV_ENV_FILE RALPH_JEV_REGISTRY
  rm -rf "$tmpd"
}

# ---------------------------------------------------------------------------
# 7: RALPH_JEV unset leaves threshold + failure classify behavior intact
# ---------------------------------------------------------------------------

@test "t3 absence: RALPH_JEV unset preserves threshold routing and structured failure classify" {
  command -v python3 >/dev/null || skip "python3 required"
  command -v jq >/dev/null || skip "jq required"
  local tmpd graph_file artifact report
  tmpd="$(mktemp -d)"
  graph_file="$tmpd/router.graph.json"
  _t3_write_router_graph "$graph_file" 1
  _t3_setup_apply_env "$tmpd" "$graph_file" "t3-absence"

  unset RALPH_JEV TYPESAFE_API_KEY RALPH_JEV_ROUTING JEV_TRANSPORT JEV_FIXTURE_DIR

  artifact="$GRAPH_SCHEDULE_WORKSPACE/.ralph-workspace/artifacts/t3/route.json"
  _t3_write_decision "$artifact" "branch-b" "0.40" "absence check"
  _graph_schedule_apply_router_decision "router" "$graph_file" "$GRAPH_SCHEDULE_WORKSPACE"
  _t3_assert_routing_event "$tmpd/run/events.jsonl" "default" "branch-a"

  report='{"kind":"network","summary":"provider connection reset"}'
  run graph_failure_classify "$report"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.classification')" = "transient-runtime" ]

  rm -rf "$tmpd"
}
