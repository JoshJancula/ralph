#!/usr/bin/env bats
# Tests for gate-failure diagnosis and repair-lane feedback routing
# (v2-feedback-routing): the graph-diagnose.sh wrapper end to end, and the
# repair-epoch compiler's injection of exact diagnosis/gate artifact paths
# into reopened repair-lane plans.
#
# Python-level ownership-mapping scenarios (single-owner, multiple-owner,
# shared-file ambiguity, infrastructure error, no file path, malicious log
# text, missing owner) are covered directly in
# tests/python/test_graph_diagnose.py; this file covers the shell wrapper
# and compile-time wiring around that logic.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/plan-todo.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-diagnose.sh"

FIXTURE_DIR="$BATS_TEST_DIRNAME/../../fixtures/graph"

setup() {
  TMPD="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMPD"
}

write_gate_result() {
  # $1=state_root $2=namespace $3=gate_node_id $4=outcome $5=log_content
  local state_root="$1" ns="$2" gate_id="$3" outcome="$4" log_content="$5"
  local gate_dir="$state_root/artifacts/$ns/gate/$gate_id"
  mkdir -p "$gate_dir"
  printf '%s\n' "$log_content" >"$gate_dir/step0.log"
  python3 - "$gate_dir/gate-result.json" "$gate_id" "$outcome" "artifacts/$ns/gate/$gate_id/step0.log" <<'PY'
import json, sys
out, node_id, outcome, artifact_path = sys.argv[1:]
payload = {
    "schemaVersion": 1,
    "nodeId": node_id,
    "profileName": "ci",
    "outcome": outcome,
    "startedAt": "2026-01-01T00:00:00Z",
    "finishedAt": "2026-01-01T00:00:01Z",
    "steps": [{"name": "test", "command": "pytest", "outcome": "failed", "artifactPath": artifact_path}],
}
if outcome == "error":
    payload["errorReason"] = "non-allowlisted-command:curl"
with open(out, "w") as fh:
    json.dump(payload, fh)
PY
}

write_lanes_graph() {
  # $1=out_path $2=diagnose_id  -- two repair lanes with disjoint writeScopes
  local out_path="$1" diagnose_id="$2"
  cat >"$out_path" <<EOF
{"nodes":[
  {"id":"$diagnose_id","dependsOn":["gate-1"],"stage":{}},
  {"id":"$diagnose_id-repair-lane-a","dependsOn":["$diagnose_id"],"stage":{"writeScopes":["src/lane_a/**"]}},
  {"id":"$diagnose_id-repair-lane-b","dependsOn":["$diagnose_id"],"stage":{"writeScopes":["src/lane_b/**"]}}
]}
EOF
}

@test "graph_diagnose_run: single-owner failure resolves deterministically with exit 0" {
  command -v jq >/dev/null || skip "jq required"
  local state_root="$TMPD/state" ns="ns" gate_id="gate-1" diag_id="diag-1"
  write_gate_result "$state_root" "$ns" "$gate_id" "changes-required" "FAIL src/lane_a/thing.py:1 broke"
  local graph_json="$TMPD/g.json"
  write_lanes_graph "$graph_json" "$diag_id"

  run graph_diagnose_run "$diag_id" "$gate_id" "$graph_json" "$state_root" "$ns" "$TMPD/rundir"
  [ "$status" -eq 0 ]

  local diagnosis
  diagnosis="$(graph_diagnose_result_path "$state_root" "$ns" "$diag_id")"
  [ -f "$diagnosis" ]
  [ "$(jq -r '.findings[0].owner' "$diagnosis")" = "$diag_id-repair-lane-a" ]
  [ "$(jq '.ambiguous | length' "$diagnosis")" -eq 0 ]
}

@test "graph_diagnose_run: shared-file ambiguity returns exit 2 and stays unresolved until router applied" {
  command -v jq >/dev/null || skip "jq required"
  local state_root="$TMPD/state" ns="ns" gate_id="gate-1" diag_id="diag-1"
  write_gate_result "$state_root" "$ns" "$gate_id" "changes-required" "FAIL src/shared/thing.py:1 broke"
  local graph_json="$TMPD/g.json"
  cat >"$graph_json" <<EOF
{"nodes":[
  {"id":"$diag_id","dependsOn":["gate-1"],"stage":{}},
  {"id":"$diag_id-repair-lane-a","dependsOn":["$diag_id"],"stage":{"writeScopes":["src/shared/**"]}},
  {"id":"$diag_id-repair-lane-b","dependsOn":["$diag_id"],"stage":{"writeScopes":["src/shared/**"]}}
]}
EOF

  run graph_diagnose_run "$diag_id" "$gate_id" "$graph_json" "$state_root" "$ns" "$TMPD/rundir"
  [ "$status" -eq 2 ]

  local diagnosis
  diagnosis="$(graph_diagnose_result_path "$state_root" "$ns" "$diag_id")"
  [ "$(jq '.ambiguous | length' "$diagnosis")" -eq 1 ]

  # Apply a router decision naming a valid in-scope candidate.
  local decision="$TMPD/decision.json"
  printf '{"assignments":[{"findingIndex":0,"owner":"%s","reason":"picked a"}]}\n' "$diag_id-repair-lane-a" >"$decision"
  run graph_diagnose_apply_router "$diag_id" "$graph_json" "$state_root" "$ns" "$decision"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.findings[0].owner' "$diagnosis")" = "$diag_id-repair-lane-a" ]
  [ "$(jq -r '.findings[0].ownerReason' "$diagnosis")" = "router-agent" ]
}

@test "graph_diagnose_run: infrastructure error produces one unowned finding, exit 0" {
  command -v jq >/dev/null || skip "jq required"
  local state_root="$TMPD/state" ns="ns" gate_id="gate-1" diag_id="diag-1"
  write_gate_result "$state_root" "$ns" "$gate_id" "error" "irrelevant"
  local graph_json="$TMPD/g.json"
  write_lanes_graph "$graph_json" "$diag_id"

  run graph_diagnose_run "$diag_id" "$gate_id" "$graph_json" "$state_root" "$ns" "$TMPD/rundir"
  [ "$status" -eq 0 ]

  local diagnosis
  diagnosis="$(graph_diagnose_result_path "$state_root" "$ns" "$diag_id")"
  [ "$(jq -r '.findings[0].ownerReason' "$diagnosis")" = "infrastructure-error" ]
  [ "$(jq -r '.findings[0].owner' "$diagnosis")" = "null" ]
}

@test "graph_diagnose_run: exact feedback reaches only the assigned lane's assignment list" {
  command -v jq >/dev/null || skip "jq required"
  local state_root="$TMPD/state" ns="ns" gate_id="gate-1" diag_id="diag-1"
  write_gate_result "$state_root" "$ns" "$gate_id" "changes-required" "FAIL src/lane_a/thing.py:1 broke"
  local graph_json="$TMPD/g.json"
  write_lanes_graph "$graph_json" "$diag_id"

  graph_diagnose_run "$diag_id" "$gate_id" "$graph_json" "$state_root" "$ns" "$TMPD/rundir"

  local diagnosis
  diagnosis="$(graph_diagnose_result_path "$state_root" "$ns" "$diag_id")"
  [ "$(jq -r ".laneAssignments[\"$diag_id-repair-lane-a\"] | length" "$diagnosis")" -eq 1 ]
  [ "$(jq -r ".laneAssignments[\"$diag_id-repair-lane-b\"] | length" "$diagnosis")" -eq 0 ]
}

@test "graph_diagnose_run: errors when no repair lanes depend on the diagnose node" {
  command -v jq >/dev/null || skip "jq required"
  local state_root="$TMPD/state" ns="ns" gate_id="gate-1" diag_id="diag-1"
  write_gate_result "$state_root" "$ns" "$gate_id" "changes-required" "FAIL src/x.py:1 broke"
  local graph_json="$TMPD/g.json"
  printf '{"nodes":[{"id":"%s","dependsOn":["%s"],"stage":{}}]}\n' "$diag_id" "$gate_id" >"$graph_json"

  run graph_diagnose_run "$diag_id" "$gate_id" "$graph_json" "$state_root" "$ns" "$TMPD/rundir"
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Compile-time content injection
# ---------------------------------------------------------------------------

@test "compile: repair lane content is injected with exact diagnosis and gate result paths" {
  command -v jq >/dev/null || skip "jq required"
  local plan_file="$TMPD/plan.md"
  cp "$FIXTURE_DIR/graph-repair-rounds.plan.md" "$plan_file"
  local out="$TMPD/out.json"
  plan_pipeline_graph_json "$plan_file" >"$out"

  local lane_content
  lane_content="$(jq -r '.nodes[] | select(.id == "fix-r1-repair-lane-a") | .stage._inlineTodos[0].content' "$out")"
  [[ "$lane_content" == *"artifacts/{{ARTIFACT_NS}}/diagnose/fix-r1-diagnose/diagnosis.json"* ]]
  [[ "$lane_content" == *"artifacts/{{ARTIFACT_NS}}/gate/fix-gate/gate-result.json"* ]]
  [[ "$lane_content" == *"fix-r1-repair-lane-a"* ]]

  # Round 2's lane content points at round 1's regate, not the entry gate.
  local lane2_content
  lane2_content="$(jq -r '.nodes[] | select(.id == "fix-r2-repair-lane-a") | .stage._inlineTodos[0].content' "$out")"
  [[ "$lane2_content" == *"artifacts/{{ARTIFACT_NS}}/gate/fix-r1-regate/gate-result.json"* ]]
}

@test "compile: default diagnose content (no author override) still names exact artifact paths" {
  command -v jq >/dev/null || skip "jq required"
  local plan_file="$TMPD/plan.md"
  # Strip the fixture's explicit diagnose content line to exercise the default.
  grep -v 'content: diagnose gate failures' "$FIXTURE_DIR/graph-repair-rounds.plan.md" >"$plan_file"
  local out="$TMPD/out.json"
  plan_pipeline_graph_json "$plan_file" >"$out"

  local diag_content
  diag_content="$(jq -r '.nodes[] | select(.id == "fix-r1-diagnose") | .stage._inlineTodos[0].content' "$out")"
  [[ "$diag_content" == *"artifacts/{{ARTIFACT_NS}}/gate/fix-gate/gate-result.json"* ]]
  [[ "$diag_content" == *"artifacts/{{ARTIFACT_NS}}/diagnose/fix-r1-diagnose/diagnosis.json"* ]]
  [[ "$diag_content" == *"deterministic"* ]]
}
