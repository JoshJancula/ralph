#!/usr/bin/env bats
# Successor reuse comparison and linked-run creation: old/new frozen
# graphs, completion fingerprints, and successor run directories.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-state.sh"
source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-successor.sh"

GRAPH_RUN_SH="$REPO_ROOT/bundle/.ralph/graph-run.sh"

setup() {
  TMPD="$(mktemp -d)"
  WORKSPACE="$TMPD/ws"
  mkdir -p "$WORKSPACE"
  NAMESPACE="successor-ns"
  RUN_ID="run-succ-001"
  NEW_RUN_ID="run-succ-002"
  OLD_GRAPH="$TMPD/old-graph.json"
  NEW_GRAPH="$TMPD/new-graph.json"
  PLAN_FILE="$WORKSPACE/successor.plan.md"
  printf '%s\n' '- [x] done' >"$PLAN_FILE"
}

teardown() {
  rm -rf "$TMPD"
}

write_base_graph() {
  local dest="$1"
  jq -n '
    {
      schemaVersion: 1,
      ralphVersion: "test",
      name: "successor",
      namespace: "successor-ns",
      maxParallel: 2,
      failurePolicy: "drain",
      verificationProfiles: [
        {
          name: "ci",
          steps: [
            {name: "unit", command: "true"}
          ]
        }
      ],
      nodes: [
        {
          id: "source",
          type: "agent",
          dependsOn: [],
          stage: {
            id: "source",
            runtime: "cursor",
            instructions: "Research the source input.",
            workspaceMode: "snapshot",
            outputArtifacts: [{path: "shared/input.md", required: true}]
          }
        },
        {
          id: "left",
          type: "agent",
          dependsOn: ["source"],
          stage: {
            id: "left",
            runtime: "cursor",
            instructions: "Implement the left-hand change.",
            workspaceMode: "snapshot",
            writeScopes: ["src/**"],
            inputArtifacts: [{path: "shared/input.md", required: true}],
            outputArtifacts: [{path: "shared/left.md", required: true}]
          }
        },
        {
          id: "right",
          type: "agent",
          dependsOn: ["source"],
          stage: {
            id: "right",
            runtime: "claude",
            instructions: "Implement the right-hand change.",
            workspaceMode: "snapshot",
            inputArtifacts: [{path: "shared/input.md", required: true}],
            outputArtifacts: [{path: "shared/right.md", required: true}]
          }
        },
        {
          id: "sink",
          type: "gate",
          dependsOn: ["left", "right"],
          stage: {
            id: "sink",
            verificationProfile: "ci",
            inputArtifacts: [
              {path: "shared/left.md", required: true},
              {path: "shared/right.md", required: true}
            ]
          }
        }
      ],
      edges: [
        {from: "source", to: "left", reasons: ["declared"]},
        {from: "source", to: "right", reasons: ["declared"]},
        {from: "left", to: "sink", reasons: ["declared"]},
        {from: "right", to: "sink", reasons: ["declared"]}
      ]
    }
  ' >"$dest"
}

init_predecessor() {
  write_base_graph "$OLD_GRAPH"
  cp "$OLD_GRAPH" "$NEW_GRAPH"
  graph_state_init_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$PLAN_FILE" "$OLD_GRAPH" 2 >/dev/null
}

mark_node() {
  local node_id="$1" state="$2" extra="${3-}"
  local aid="${node_id}__${RUN_ID}__1" node_file extra_json
  node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$node_id")"
  extra_json="{}"
  if [[ -n "$extra" ]]; then
    extra_json="$extra"
  fi
  jq -n --arg id "$node_id" --arg aid "$aid" --arg state "$state" --argjson extra "$extra_json" '
    {
      schemaVersion: 3,
      nodeId: $id,
      status: $state,
      lastAttemptId: $aid,
      attempts: [
        {
          attemptId: $aid,
          outcome: $state,
          exitCode: 0,
          startedAt: "2026-01-01T00:00:00Z",
          finishedAt: "2026-01-01T00:00:01Z",
          runtime: "cursor"
        } + $extra
      ]
    } + $extra
  ' >"$node_file"
}

write_exchange() {
  local rel="$1" content="$2"
  local path
  path="$(graph_state_state_root "$WORKSPACE")/artifacts/$NAMESPACE/exchange/$rel"
  mkdir -p "$(dirname "$path")"
  printf '%s' "$content" >"$path"
}

write_changeset() {
  local node_id="$1" identity="${2:-cs-$node_id}"
  local run_dir path
  run_dir="$(graph_state_run_dir "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  path="$run_dir/changesets/nodes/${node_id}.json"
  mkdir -p "$(dirname "$path")"
  jq -n --arg id "$node_id" --arg ident "$identity" \
    '{kind:"graph-changeset", schemaVersion:1, nodeId:$id, contentIdentity:$ident, changes:[]}' \
    >"$path"
}

write_gate_result() {
  local node_id="$1" outcome="${2:-passed}"
  local path
  path="$(graph_state_state_root "$WORKSPACE")/artifacts/$NAMESPACE/gate/${node_id}/gate-result.json"
  mkdir -p "$(dirname "$path")"
  jq -n --arg id "$node_id" --arg outcome "$outcome" \
    '{schemaVersion:1, nodeId:$id, outcome:$outcome, steps:[]}' >"$path"
}

succeed_all() {
  write_exchange "shared/input.md" "input-v1"
  write_exchange "shared/left.md" "left-v1"
  write_exchange "shared/right.md" "right-v1"
  write_changeset "left" "left-identity-1"
  write_gate_result "sink" "passed"
  mark_node "source" "succeeded"
  mark_node "left" "succeeded" '{"changesetHash":"left-identity-1"}'
  mark_node "right" "succeeded"
  mark_node "sink" "succeeded" '{"gateOutcome":"passed"}'
}

store_fingerprints() {
  local node_id fp node_file tmp
  for node_id in source left right sink; do
    fp="$(graph_successor_completion_fingerprint "$OLD_GRAPH" "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$node_id")"
    node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$node_id")"
    tmp="$(mktemp)"
    jq --argjson fp "$fp" '.completionFingerprint = $fp' "$node_file" >"$tmp"
    mv "$tmp" "$node_file"
  done
}

reuse_report() {
  graph_successor_reuse_report "$OLD_GRAPH" "$NEW_GRAPH" "$WORKSPACE" "$NAMESPACE" "$RUN_ID"
}

node_reuse() {
  local report="$1" node_id="$2"
  printf '%s' "$report" | jq -r --arg id "$node_id" '.nodes[] | select(.id == $id) | .reuse'
}

node_reasons() {
  local report="$1" node_id="$2"
  printf '%s' "$report" | jq -c --arg id "$node_id" '.nodes[] | select(.id == $id) | .reasons'
}

has_reason() {
  local report="$1" node_id="$2" reason="$3"
  printf '%s' "$report" | jq -e --arg id "$node_id" --arg r "$reason" \
    '.nodes[] | select(.id == $id) | .reasons | index($r) != null' >/dev/null
}

predecessor_snapshot() {
  local run_dir
  run_dir="$(graph_state_run_dir "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  find "$run_dir" -type f | sort | while IFS= read -r f; do
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum "$f"
    else
      shasum -a 256 "$f"
    fi
  done
}

create_successor() {
  graph_successor_create "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$NEW_GRAPH" "$PLAN_FILE" "${1:-$NEW_RUN_ID}"
}

succ_node_status() {
  local run_id="$1" node_id="$2" node_file
  node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$run_id" "$node_id")"
  jq -r '.status // empty' "$node_file"
}

file_digest() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  else
    shasum -a 256 "$path" | awk '{print $1}'
  fi
}

successor_cmd() {
  bash "$GRAPH_RUN_SH" successor "$@" --workspace "$WORKSPACE"
}

write_cli_plan() {
  cat >"$PLAN_FILE" <<'PLAN'
---
name: successor
namespace: successor-ns
execution: graph
pipeline:
  stages:
    - id: source
      runtime: cursor
      workspaceMode: snapshot
      produces:
        - path: shared/input.md
    - id: left
      runtime: cursor
      instructions: Implement the left-hand change.
      workspaceMode: snapshot
      dependsOn:
        - source
      requires:
        - path: shared/input.md
      produces:
        - path: shared/left.md
    - id: right
      runtime: claude
      workspaceMode: snapshot
      dependsOn:
        - source
      requires:
        - path: shared/input.md
      produces:
        - path: shared/right.md
    - id: sink
      runtime: cursor
      workspaceMode: snapshot
      dependsOn:
        - left
        - right
      requires:
        - path: shared/left.md
        - path: shared/right.md
todos:
  - id: source-1
    stage: source
    content: create the input
    status: pending
  - id: left-1
    stage: left
    content: transform the input on the left branch
    status: pending
  - id: right-1
    stage: right
    content: transform the input on the right branch
    status: pending
  - id: sink-1
    stage: sink
    content: merge the branch outputs
    status: pending
---
PLAN
}

compile_cli_plan() {
  local dest="${1:-$OLD_GRAPH}"
  bash "$GRAPH_RUN_SH" compile "$PLAN_FILE" --out "$dest" --force >/dev/null
}

init_cli_predecessor() {
  mkdir -p "$WORKSPACE/.ralph" "$WORKSPACE/.ralph-workspace"
  write_cli_plan
  compile_cli_plan "$OLD_GRAPH"
  cp "$OLD_GRAPH" "$NEW_GRAPH"
  graph_state_init_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$PLAN_FILE" "$OLD_GRAPH" 2 >/dev/null
}

@test "successor evidence reuses unchanged succeeded nodes" {
  init_predecessor
  succeed_all
  run reuse_report
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.readOnly')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.schemaVersion')" = "1" ]
  [ "$(printf '%s' "$output" | jq -r '.predecessorRunId')" = "$RUN_ID" ]
  [ "$(node_reuse "$output" source)" = "true" ]
  [ "$(node_reuse "$output" left)" = "true" ]
  [ "$(node_reuse "$output" right)" = "true" ]
  [ "$(node_reuse "$output" sink)" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.reusable | join(" ")')" = "left right sink source" ]
}

@test "successor evidence refuses non-succeeded statuses and reports a reason" {
  init_predecessor
  write_exchange "shared/input.md" "input-v1"
  write_exchange "shared/left.md" "left-v1"
  write_exchange "shared/right.md" "right-v1"
  write_changeset "left" "left-identity-1"
  write_gate_result "sink" "passed"
  mark_node "source" "succeeded"
  mark_node "left" "succeeded" '{"changesetHash":"left-identity-1"}'
  mark_node "right" "failed" '{"reason":"agent-correctable"}'
  mark_node "sink" "succeeded" '{"gateOutcome":"passed"}'
  run reuse_report
  [ "$status" -eq 0 ]
  [ "$(node_reuse "$output" source)" = "true" ]
  [ "$(node_reuse "$output" left)" = "true" ]
  [ "$(node_reuse "$output" right)" = "false" ]
  [ "$(node_reuse "$output" sink)" = "false" ]
  has_reason "$output" "right" "not-succeeded:failed"
  has_reason "$output" "sink" "ancestor-not-reused:right"
}

@test "successor evidence definition change invalidates that node and descendants" {
  init_predecessor
  succeed_all
  jq '(.nodes[] | select(.id == "left") | .stage.agent) = "qa"' "$OLD_GRAPH" >"$NEW_GRAPH"
  run reuse_report
  [ "$status" -eq 0 ]
  [ "$(node_reuse "$output" source)" = "true" ]
  [ "$(node_reuse "$output" right)" = "true" ]
  [ "$(node_reuse "$output" left)" = "false" ]
  [ "$(node_reuse "$output" sink)" = "false" ]
  has_reason "$output" "left" "definition-changed"
  has_reason "$output" "sink" "ancestors-changed"
  has_reason "$output" "sink" "ancestor-not-reused:left"
}

@test "successor evidence independent branch remains reusable" {
  init_predecessor
  succeed_all
  jq '(.nodes[] | select(.id == "left") | .stage.runtime) = "opencode"' "$OLD_GRAPH" >"$NEW_GRAPH"
  run reuse_report
  [ "$status" -eq 0 ]
  [ "$(node_reuse "$output" right)" = "true" ]
  [ "$(node_reuse "$output" source)" = "true" ]
  [ "$(node_reuse "$output" left)" = "false" ]
  [ "$(node_reuse "$output" sink)" = "false" ]
  [ "$(node_reasons "$output" right)" = "[]" ]
}

@test "successor evidence input and artifact contract changes are not reused" {
  init_predecessor
  succeed_all
  jq '
    (.nodes[] | select(.id == "right") | .stage.inputArtifacts) += [{"path":"shared/extra.md","required":true}]
    | (.nodes[] | select(.id == "source") | .stage.outputArtifacts) += [{"path":"shared/extra-out.md","required":true}]
  ' "$OLD_GRAPH" >"$NEW_GRAPH"
  run reuse_report
  [ "$status" -eq 0 ]
  [ "$(node_reuse "$output" right)" = "false" ]
  [ "$(node_reuse "$output" source)" = "false" ]
  has_reason "$output" "right" "inputs-changed"
  has_reason "$output" "source" "artifacts-changed"
  has_reason "$output" "right" "missing-evidence:artifact:shared/extra.md"
  has_reason "$output" "source" "missing-evidence:artifact:shared/extra-out.md"
  [ "$(node_reuse "$output" left)" = "false" ]
  has_reason "$output" "left" "ancestor-not-reused:source"
}

@test "successor evidence changeset and gate changes are not reused" {
  init_predecessor
  succeed_all
  jq '
    (.nodes[] | select(.id == "left") | .stage.writeScopes) = ["lib/**"]
    | (.verificationProfiles[] | select(.name == "ci") | .steps) += [{"name":"lint","command":"true"}]
  ' "$OLD_GRAPH" >"$NEW_GRAPH"
  run reuse_report
  [ "$status" -eq 0 ]
  [ "$(node_reuse "$output" left)" = "false" ]
  [ "$(node_reuse "$output" sink)" = "false" ]
  has_reason "$output" "left" "changeset-changed"
  has_reason "$output" "sink" "gates-changed"
  [ "$(node_reuse "$output" source)" = "true" ]
  [ "$(node_reuse "$output" right)" = "true" ]
}

@test "successor evidence missing required evidence is not reused" {
  init_predecessor
  write_exchange "shared/input.md" "input-v1"
  write_exchange "shared/right.md" "right-v1"
  mark_node "source" "succeeded"
  mark_node "left" "succeeded"
  mark_node "right" "succeeded"
  mark_node "sink" "succeeded" '{"gateOutcome":"passed"}'
  run reuse_report
  [ "$status" -eq 0 ]
  [ "$(node_reuse "$output" left)" = "false" ]
  [ "$(node_reuse "$output" sink)" = "false" ]
  has_reason "$output" "left" "missing-evidence:changeset"
  has_reason "$output" "sink" "missing-evidence:gate"
  has_reason "$output" "left" "missing-evidence:artifact:shared/left.md"
}

@test "successor evidence stored fingerprint drift invalidates the node" {
  init_predecessor
  succeed_all
  store_fingerprints
  write_exchange "shared/input.md" "input-v2"
  run reuse_report
  [ "$status" -eq 0 ]
  [ "$(node_reuse "$output" source)" = "false" ]
  [ "$(node_reuse "$output" left)" = "false" ]
  [ "$(node_reuse "$output" right)" = "false" ]
  has_reason "$output" "source" "artifacts-changed"
  has_reason "$output" "left" "inputs-changed"
  has_reason "$output" "right" "inputs-changed"
}

@test "successor evidence added node is not reused and every nonreused node has reasons" {
  init_predecessor
  succeed_all
  jq '
    .nodes += [{
      id: "extra",
      type: "agent",
      dependsOn: ["right"],
      stage: {id: "extra", runtime: "cursor", agent: "qa", workspaceMode: "snapshot"}
    }]
    | .edges += [{from: "right", to: "extra", reasons: ["declared"]}]
  ' "$OLD_GRAPH" >"$NEW_GRAPH"
  run reuse_report
  [ "$status" -eq 0 ]
  [ "$(node_reuse "$output" extra)" = "false" ]
  has_reason "$output" "extra" "added"
  [ "$(printf '%s' "$output" | jq -r '[.nodes[] | select(.reuse == false) | .reasons | length > 0] | all')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '[.nodes[] | select(.reuse == true) | .reasons == []] | all')" = "true" ]
}

@test "successor evidence report is deterministic and leaves the predecessor byte-stable" {
  init_predecessor
  succeed_all
  jq '(.nodes[] | select(.id == "left") | .stage.agent) = "qa"' "$OLD_GRAPH" >"$NEW_GRAPH"
  before="$(predecessor_snapshot)"
  run reuse_report
  [ "$status" -eq 0 ]
  first="$output"
  run reuse_report
  [ "$status" -eq 0 ]
  [ "$output" = "$first" ]
  after="$(predecessor_snapshot)"
  [ "$before" = "$after" ]
  [ "$(printf '%s' "$first" | jq -c '.nodes | map(.id)')" = '["left","right","sink","source"]' ]
}

@test "successor create writes a new run directory, frozen graph, and predecessor id/digests" {
  init_predecessor
  succeed_all
  before="$(predecessor_snapshot)"
  pred_run_file="$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  pred_graph="$(graph_state_graph_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  pred_run_sha="$(file_digest "$pred_run_file")"
  pred_graph_sha="$(graph_state_compute_graph_sha "$pred_graph")"
  new_graph_sha="$(graph_state_compute_graph_sha "$NEW_GRAPH")"

  run create_successor
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.successorRunId')" = "$NEW_RUN_ID" ]
  [ "$(printf '%s' "$output" | jq -r '.predecessorRunId')" = "$RUN_ID" ]
  [ "$(printf '%s' "$output" | jq -r '.predecessorGraphSha')" = "$pred_graph_sha" ]
  [ "$(printf '%s' "$output" | jq -r '.predecessorRunSha')" = "$pred_run_sha" ]
  [ "$(printf '%s' "$output" | jq -r '.graphSha')" = "$new_graph_sha" ]
  [ "$(printf '%s' "$output" | jq -r '.reusable | join(" ")')" = "left right sink source" ]
  [ "$(printf '%s' "$output" | jq -r '.pending | length')" = "0" ]

  succ_run="$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$NEW_RUN_ID")"
  succ_graph="$(graph_state_graph_file "$WORKSPACE" "$NAMESPACE" "$NEW_RUN_ID")"
  [ -f "$succ_run" ]
  [ -f "$succ_graph" ]
  [ "$(jq -r '.runId' "$succ_run")" = "$NEW_RUN_ID" ]
  [ "$(jq -r '.predecessorRunId' "$succ_run")" = "$RUN_ID" ]
  [ "$(jq -r '.predecessorGraphSha' "$succ_run")" = "$pred_graph_sha" ]
  [ "$(jq -r '.predecessorRunSha' "$succ_run")" = "$pred_run_sha" ]
  [ "$(jq -r '.graphSha' "$succ_run")" = "$new_graph_sha" ]
  [ "$(file_digest "$succ_graph")" = "$(file_digest "$NEW_GRAPH")" ]
  [ "$(succ_node_status "$NEW_RUN_ID" source)" = "succeeded" ]
  [ "$(succ_node_status "$NEW_RUN_ID" left)" = "succeeded" ]
  [ "$(succ_node_status "$NEW_RUN_ID" right)" = "succeeded" ]
  [ "$(succ_node_status "$NEW_RUN_ID" sink)" = "succeeded" ]
  [ "$(file_digest "$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$NEW_RUN_ID" left)")" = \
    "$(file_digest "$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" left)")" ]
  [ "$(file_digest "$(graph_state_run_dir "$WORKSPACE" "$NAMESPACE" "$NEW_RUN_ID")/changesets/nodes/left.json")" = \
    "$(file_digest "$(graph_state_run_dir "$WORKSPACE" "$NAMESPACE" "$RUN_ID")/changesets/nodes/left.json")" ]
  after="$(predecessor_snapshot)"
  [ "$before" = "$after" ]
}

@test "successor create copies only reusable evidence and starts changed nodes pending" {
  init_predecessor
  succeed_all
  jq '(.nodes[] | select(.id == "left") | .stage.agent) = "qa"' "$OLD_GRAPH" >"$NEW_GRAPH"
  before="$(predecessor_snapshot)"

  run create_successor
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.reusable | join(" ")')" = "right source" ]
  [ "$(printf '%s' "$output" | jq -r '.pending | join(" ")')" = "left sink" ]
  [ "$(succ_node_status "$NEW_RUN_ID" source)" = "succeeded" ]
  [ "$(succ_node_status "$NEW_RUN_ID" right)" = "succeeded" ]
  [ "$(succ_node_status "$NEW_RUN_ID" left)" = "pending" ]
  [ "$(succ_node_status "$NEW_RUN_ID" sink)" = "pending" ]
  [ "$(file_digest "$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$NEW_RUN_ID" source)")" = \
    "$(file_digest "$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" source)")" ]
  [ "$(file_digest "$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$NEW_RUN_ID" left)")" != \
    "$(file_digest "$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" left)")" ]
  [ ! -f "$(graph_state_run_dir "$WORKSPACE" "$NAMESPACE" "$NEW_RUN_ID")/changesets/nodes/left.json" ]
  [ -f "$(graph_state_run_dir "$WORKSPACE" "$NAMESPACE" "$RUN_ID")/changesets/nodes/left.json" ]
  after="$(predecessor_snapshot)"
  [ "$before" = "$after" ]
}

@test "successor create starts added nodes pending" {
  init_predecessor
  succeed_all
  jq '
    .nodes += [{
      id: "extra",
      type: "agent",
      dependsOn: ["right"],
      stage: {id: "extra", runtime: "cursor", agent: "qa", workspaceMode: "snapshot"}
    }]
    | .edges += [{from: "right", to: "extra", reasons: ["declared"]}]
  ' "$OLD_GRAPH" >"$NEW_GRAPH"

  run create_successor
  [ "$status" -eq 0 ]
  [ "$(succ_node_status "$NEW_RUN_ID" extra)" = "pending" ]
  [ "$(succ_node_status "$NEW_RUN_ID" source)" = "succeeded" ]
  [ "$(succ_node_status "$NEW_RUN_ID" right)" = "succeeded" ]
  has_reason "$output" "extra" "added"
  [ "$(printf '%s' "$output" | jq -r '.pending | index("extra") != null')" = "true" ]
  [ ! -f "$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" extra)" ]
}

@test "successor create leaves the predecessor byte-stable and refuses an existing successor" {
  init_predecessor
  succeed_all
  before="$(predecessor_snapshot)"
  run create_successor
  [ "$status" -eq 0 ]
  first="$output"
  after="$(predecessor_snapshot)"
  [ "$before" = "$after" ]

  run create_successor
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]]
  after_again="$(predecessor_snapshot)"
  [ "$before" = "$after_again" ]
  [ "$(jq -r '.runId' "$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$NEW_RUN_ID")")" = "$NEW_RUN_ID" ]
  [ "$(printf '%s' "$first" | jq -r '.successorRunId')" = "$NEW_RUN_ID" ]
}

@test "successor cli --help exits 0 and documents --from --plan and dry-run" {
  run bash "$GRAPH_RUN_SH" successor --help
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q -- '--from'
  printf '%s\n' "$output" | grep -q -- '--plan'
  run bash "$GRAPH_RUN_SH" --help
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'successor'
  printf '%s\n' "$output" | grep -q -- '--from'
  printf '%s\n' "$output" | grep -q -- '--plan'
  printf '%s\n' "$output" | grep -q 'dry-run'
}

@test "successor cli errors without --from" {
  write_cli_plan
  run successor_cmd --plan "$PLAN_FILE"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q -- '--from'
}

@test "successor cli errors without --plan" {
  run successor_cmd --from "$RUN_ID"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q -- '--plan'
}

@test "successor cli dry-run reports reuse without creating a successor or mutating the predecessor" {
  init_cli_predecessor
  succeed_all
  before="$(predecessor_snapshot)"
  run successor_cmd --from "$RUN_ID" --plan "$PLAN_FILE"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.dryRun')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.create')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.readOnly')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.predecessorRunId')" = "$RUN_ID" ]
  [[ "$(printf '%s' "$output" | jq -r '.nextCommand')" == *"bash .ralph/graph-run.sh successor"*"--create"* ]]
  [ "$(printf '%s' "$output" | jq -r '.nextCommandArgv[-1]')" = "--create" ]
  [ "$(node_reuse "$output" source)" = "true" ]
  [ "$(node_reuse "$output" left)" = "true" ]
  [ "$(node_reuse "$output" right)" = "true" ]
  [ "$(node_reuse "$output" sink)" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.reusable | join(" ")')" = "left right sink source" ]
  [ ! -f "$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$NEW_RUN_ID")" ]
  after="$(predecessor_snapshot)"
  [ "$before" = "$after" ]
}

@test "successor cli dry-run reports reasons when the plan definition changes" {
  init_cli_predecessor
  succeed_all
  before="$(predecessor_snapshot)"
  awk '
    /id: left/ { in_left=1 }
    in_left && /instructions: Implement the left-hand change\./ { sub(/left-hand/, "qa"); in_left=0 }
    { print }
  ' "$PLAN_FILE" >"$TMPD/changed.plan.md"
  mv "$TMPD/changed.plan.md" "$PLAN_FILE"
  run successor_cmd --from "$RUN_ID" --plan "$PLAN_FILE" --dry-run
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.dryRun')" = "true" ]
  [ "$(node_reuse "$output" source)" = "true" ]
  [ "$(node_reuse "$output" right)" = "true" ]
  [ "$(node_reuse "$output" left)" = "false" ]
  [ "$(node_reuse "$output" sink)" = "false" ]
  has_reason "$output" "left" "definition-changed"
  [ ! -d "$(graph_state_run_dir "$WORKSPACE" "$NAMESPACE" "$NEW_RUN_ID")" ]
  after="$(predecessor_snapshot)"
  [ "$before" = "$after" ]
}

@test "successor cli --create writes a successor run and leaves the predecessor byte-stable" {
  init_cli_predecessor
  succeed_all
  before="$(predecessor_snapshot)"
  run successor_cmd --from "$RUN_ID" --plan "$PLAN_FILE" --create --run-id "$NEW_RUN_ID"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.dryRun')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.create')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.successorRunId')" = "$NEW_RUN_ID" ]
  [ "$(printf '%s' "$output" | jq -r '.predecessorRunId')" = "$RUN_ID" ]
  [ "$(printf '%s' "$output" | jq -r '.reusable | join(" ")')" = "left right sink source" ]
  [ "$(succ_node_status "$NEW_RUN_ID" source)" = "succeeded" ]
  [ "$(succ_node_status "$NEW_RUN_ID" left)" = "succeeded" ]
  [ "$(jq -r '.predecessorRunId' "$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$NEW_RUN_ID")")" = "$RUN_ID" ]
  after="$(predecessor_snapshot)"
  [ "$before" = "$after" ]
}

@test "successor cli --create refuses to mutate the predecessor when the successor already exists" {
  init_cli_predecessor
  succeed_all
  run successor_cmd --from "$RUN_ID" --plan "$PLAN_FILE" --create --run-id "$NEW_RUN_ID"
  [ "$status" -eq 0 ]
  before="$(predecessor_snapshot)"
  run successor_cmd --from "$RUN_ID" --plan "$PLAN_FILE" --create --run-id "$NEW_RUN_ID"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'already exists'
  after="$(predecessor_snapshot)"
  [ "$before" = "$after" ]
  [ "$(jq -r '.runId' "$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$NEW_RUN_ID")")" = "$NEW_RUN_ID" ]
}

@test "successor cli refuses an ambiguous --from selector" {
  init_cli_predecessor
  succeed_all
  graph_state_init_run "$WORKSPACE" "other-ns" "$RUN_ID" "$PLAN_FILE" "$OLD_GRAPH" 2 >/dev/null
  before="$(predecessor_snapshot)"
  run successor_cmd --from "$RUN_ID" --plan "$PLAN_FILE"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'ambiguous'
  printf '%s\n' "$output" | grep -q -- '--namespace'
  [ ! -d "$(graph_state_run_dir "$WORKSPACE" "$NAMESPACE" "$NEW_RUN_ID")" ]
  after="$(predecessor_snapshot)"
  [ "$before" = "$after" ]

  run successor_cmd --from "$RUN_ID" --plan "$PLAN_FILE" --namespace "$NAMESPACE"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.dryRun')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.predecessorRunId')" = "$RUN_ID" ]
}

@test "successor cli --from latest without --namespace is ambiguous" {
  init_cli_predecessor
  succeed_all
  run successor_cmd --from latest --plan "$PLAN_FILE"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'ambiguous'
  printf '%s\n' "$output" | grep -q -- '--namespace'
  [ ! -d "$(graph_state_run_dir "$WORKSPACE" "$NAMESPACE" "$NEW_RUN_ID")" ]
}

@test "successor cli --from latest with --namespace dry-runs the predecessor" {
  init_cli_predecessor
  succeed_all
  run successor_cmd --from latest --plan "$PLAN_FILE" --namespace "$NAMESPACE"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.dryRun')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.predecessorRunId')" = "$RUN_ID" ]
  [ "$(node_reuse "$output" source)" = "true" ]
}
