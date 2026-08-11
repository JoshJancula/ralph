#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/plan-todo.sh"

write_plan() {
  local path="$1" body="$2"
  cat >"$path" <<EOF
---
execution: graph
pipeline:
  stages:
    - id: parent
      runtime: codex
      agent: implementation
$body
---
EOF
}

@test "omitted delegation freezes an off depth-one policy without changing .orch json" {
  local tmpd plan graph orch
  tmpd="$(mktemp -d)"; plan="$tmpd/p.plan.md"
  write_plan "$plan" ""
  run plan_pipeline_graph_json "$plan"; [ "$status" -eq 0 ]
  graph="$(printf '%s\n' "$output" | tail -1)"
  [ "$(printf '%s' "$graph" | jq -c '.nodes[0].stage.delegation')" = '{"maxDepth":1,"maxChildren":0,"native":{"mode":"off"},"crossRuntime":{"mode":"off"}}' ]
  run plan_pipeline_orch_json "$plan"; [ "$status" -eq 0 ]
  orch="$(printf '%s\n' "$output" | tail -1)"
  [ "$(printf '%s' "$orch" | jq '(.stages[0] | has("delegation"))')" = "false" ]
}

@test "legacy subagents on remains accepted and resolves to native read-only" {
  local tmpd plan
  tmpd="$(mktemp -d)"; plan="$tmpd/p.plan.md"
  write_plan "$plan" "      subagents: on"
  run plan_pipeline_graph_json "$plan"; [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | tail -1 | jq -r '.nodes[0].stage.delegation.native.mode')" = "read-only" ]
  [ "$(printf '%s\n' "$output" | tail -1 | jq -r '.nodes[0].stage.subagents')" = "on" ]
}

@test "legacy subagents off and inherit retain their compact behavior" {
  local tmpd plan value
  tmpd="$(mktemp -d)"
  for value in off inherit; do
    plan="$tmpd/$value.plan.md"
    write_plan "$plan" "      subagents: $value"
    run plan_pipeline_graph_json "$plan"; [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | tail -1 | jq -r '.nodes[0].stage.delegation.native.mode')" = "off" ]
  done
}

@test "valid structured native and isolated cross-runtime policy is frozen" {
  local tmpd plan
  tmpd="$(mktemp -d)"; plan="$tmpd/p.plan.md"
  write_plan "$plan" "      workspaceMode: worktree
      delegation:
        maxChildren: 3
        native:
          mode: read-only
          allowedAgents: [research]
          maxParallel: 1
        crossRuntime:
          mode: changeset
          allowedRuntimes: [claude]
          allowedAgents: [implementation]
          maxParallel: 2"
  run plan_pipeline_graph_json "$plan"; [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | tail -1 | jq -r '.nodes[0].stage.delegation.maxDepth')" = 1 ]
  [ "$(printf '%s\n' "$output" | tail -1 | jq -r '.nodes[0].stage.delegation.crossRuntime.mode')" = changeset ]
}

@test "invalid delegation combinations are rejected" {
  local tmpd plan body
  tmpd="$(mktemp -d)"
  for body in \
    '      delegation:\n        maxChildren: 0\n        native:\n          mode: off' \
    '      delegation:\n        maxChildren: 1\n        crossRuntime:\n          mode: read-only\n          allowedRuntimes: [codex]\n          allowedAgents: [research]\n          maxParallel: 1' \
    '      delegation:\n        maxChildren: 1\n        crossRuntime:\n          mode: changeset\n          allowedRuntimes: [claude]\n          allowedAgents: [implementation]\n          maxParallel: 1' \
    '      delegation:\n        maxChildren: 1\n        native:\n          mode: read-only\n          allowedAgents: ["*"]\n          maxParallel: 1'
  do
    plan="$tmpd/p.plan.md"
    write_plan "$plan" "$(printf '%b' "$body")"
    run plan_pipeline_graph_json "$plan"
    [ "$status" -ne 0 ]
  done
}

@test "delegation is forced off or rejected on special nodes" {
  local tmpd plan
  tmpd="$(mktemp -d)"; plan="$tmpd/p.plan.md"
  write_plan "$plan" "      type: checkpoint
      delegation:
        maxChildren: 1
        native:
          mode: read-only
          allowedAgents: [research]
          maxParallel: 1"
  run plan_pipeline_graph_json "$plan"
  [ "$status" -ne 0 ]
}
