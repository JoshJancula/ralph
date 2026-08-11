#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/plan-todo.sh"

CHANGESET_HELPER="$REPO_ROOT/bundle/.ralph/python/graph_changeset.py"

@test "graph compiler preserves write policy and rejects unacknowledged shared mutation" {
  local tmpd plan payload
  tmpd="$(mktemp -d)"
  plan="$tmpd/write-policy.plan.md"
  cat >"$plan" <<'PLAN'
---
execution: graph
pipeline:
  stages:
    - id: build
      runtime: cursor
      agent: implementation
      workspaceMode: snapshot
      agentGitAccess: off
      writeScopes:
        - src/**
todos:
  - id: build-1
    stage: build
    content: change source
    status: pending
---
PLAN
  run plan_pipeline_graph_json "$plan"
  [ "$status" -eq 0 ]
  payload="$(printf '%s\n' "$output" | awk 'END { print }')"
  [ "$(printf '%s' "$payload" | jq -r '.nodes[0].stage.agentGitAccess')" = "off" ]
  [ "$(printf '%s' "$payload" | jq -r '.nodes[0].stage.writeScopes[0]')" = "src/**" ]

  sed -i.bak 's/workspaceMode: snapshot/workspaceMode: shared/' "$plan"
  run plan_pipeline_graph_json "$plan"
  [ "$status" -ne 0 ]
  [[ "$output" = *"shared mutation requires"* ]]
}

@test "changeset captures add delete rename mode binary and deterministic content identity" {
  local tmpd workspace baseline first second third
  tmpd="$(mktemp -d)"
  workspace="$tmpd/workspace"
  mkdir -p "$workspace/src"
  printf 'old\n' >"$workspace/src/delete.txt"
  printf 'rename\n' >"$workspace/src/old-name.txt"
  printf 'mode\n' >"$workspace/src/mode.sh"
  baseline="$tmpd/baseline.json"
  python3 "$CHANGESET_HELPER" baseline --workspace "$workspace" --output "$baseline" >/dev/null

  rm "$workspace/src/delete.txt"
  mv "$workspace/src/old-name.txt" "$workspace/src/new-name.txt"
  chmod 755 "$workspace/src/mode.sh"
  printf 'new\n' >"$workspace/src/new.txt"
  printf '\0binary\n' >"$workspace/src/data.bin"
  ln -s new.txt "$workspace/src/link.txt"
  first="$tmpd/first/changeset.json"
  second="$tmpd/second/changeset.json"
  third="$tmpd/third/changeset.json"
  python3 "$CHANGESET_HELPER" capture --workspace "$workspace" --baseline "$baseline" \
    --output "$first" --node-id build --attempt-id a1 --workspace-mode snapshot \
    --base-identity base-one --write-scopes-json '["src/**"]' >/dev/null
  python3 "$CHANGESET_HELPER" capture --workspace "$workspace" --baseline "$baseline" \
    --output "$second" --node-id build --attempt-id a2 --workspace-mode worktree \
    --base-identity base-one --write-scopes-json '["src/**"]' >/dev/null
  python3 "$CHANGESET_HELPER" capture --workspace "$workspace" --baseline "$baseline" \
    --output "$third" --node-id build --attempt-id a3 --workspace-mode shared \
    --base-identity base-one --write-scopes-json '["src/**"]' >/dev/null

  [ "$(jq '[.changes[] | select(.operation == "deleted")] | length' "$first")" -eq 1 ]
  [ "$(jq '[.changes[] | select(.operation == "renamed")] | length' "$first")" -eq 1 ]
  [ "$(jq '[.changes[] | select(.path == "src/mode.sh" and .after.mode == 493)] | length' "$first")" -eq 1 ]
  [ "$(jq -r '.changes[] | select(.path == "src/data.bin") | .binary' "$first")" = "true" ]
  [ "$(jq -r '.changes[] | select(.path == "src/link.txt") | .after.type' "$first")" = "symlink" ]
  [ "$(jq -r '.contentIdentity' "$first")" = "$(jq -r '.contentIdentity' "$second")" ]
  [ "$(jq -r '.contentIdentity' "$first")" = "$(jq -r '.contentIdentity' "$third")" ]
  while IFS= read -r blob; do
    [ -f "$(dirname "$first")/$blob" ]
  done < <(jq -r '.changes[] | .blob // empty' "$first")
}

@test "changeset fails closed on out-of-scope control and unsafe symlink edits" {
  local tmpd workspace baseline
  tmpd="$(mktemp -d)"
  workspace="$tmpd/workspace"
  mkdir -p "$workspace/src" "$workspace/docs" "$workspace/.ralph"
  printf 'base\n' >"$workspace/src/ok.txt"
  printf 'control\n' >"$workspace/.ralph/control.sh"
  baseline="$tmpd/baseline.json"
  python3 "$CHANGESET_HELPER" baseline --workspace "$workspace" --output "$baseline" >/dev/null

  printf 'outside\n' >"$workspace/docs/no.txt"
  run python3 "$CHANGESET_HELPER" capture --workspace "$workspace" --baseline "$baseline" \
    --output "$tmpd/out.json" --node-id build --attempt-id a1 --workspace-mode snapshot \
    --base-identity base --write-scopes-json '["src/**"]'
  [ "$status" -ne 0 ]
  [[ "$output" = *"outOfScope"* ]]

  rm "$workspace/docs/no.txt"
  printf 'changed\n' >"$workspace/.ralph/control.sh"
  run python3 "$CHANGESET_HELPER" capture --workspace "$workspace" --baseline "$baseline" \
    --output "$tmpd/control.json" --node-id build --attempt-id a1 --workspace-mode snapshot \
    --base-identity base --write-scopes-json '["src/**"]'
  [ "$status" -ne 0 ]
  [[ "$output" = *"controlPaths"* ]]

  printf 'control\n' >"$workspace/.ralph/control.sh"
  ln -s ../../outside "$workspace/src/escape"
  run python3 "$CHANGESET_HELPER" capture --workspace "$workspace" --baseline "$baseline" \
    --output "$tmpd/symlink.json" --node-id build --attempt-id a1 --workspace-mode snapshot \
    --base-identity base --write-scopes-json '["src/**"]'
  [ "$status" -ne 0 ]
  [[ "$output" = *"unsafe escaping symlink"* ]]
}

@test "compiler rejects unordered overlapping scopes and unproved worktree Git isolation" {
  local tmpd plan
  tmpd="$(mktemp -d)"
  plan="$tmpd/overlap.plan.md"
  cat >"$plan" <<'PLAN'
---
execution: graph
pipeline:
  stages:
    - id: left
      runtime: cursor
      agent: implementation
      workspaceMode: snapshot
      writeScopes: [src/**]
    - id: right
      runtime: codex
      agent: implementation
      workspaceMode: snapshot
      writeScopes: [src/api/**]
todos:
  - id: left-1
    stage: left
    content: left
    status: pending
  - id: right-1
    stage: right
    content: right
    status: pending
---
PLAN
  run plan_pipeline_graph_json "$plan"
  [ "$status" -ne 0 ]
  [[ "$output" = *"writeScopes overlap"* ]]

  plan="$tmpd/worktree.plan.md"
  cat >"$plan" <<'PLAN'
---
execution: graph
pipeline:
  stages:
    - id: build
      runtime: cursor
      agent: implementation
      workspaceMode: worktree
      writeScopes: [src/**]
todos:
  - id: build-1
    stage: build
    content: build
    status: pending
---
PLAN
  unset RALPH_GRAPH_GIT_SANDBOX_PROVEN
  run plan_pipeline_graph_json "$plan"
  [ "$status" -ne 0 ]
  [[ "$output" = *"proved runtime sandbox boundary"* ]]
  export RALPH_GRAPH_GIT_SANDBOX_PROVEN=1
  run plan_pipeline_graph_json "$plan"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | awk 'END { print }' | jq -r '.nodes[0].stage.agentGitAccess')" = "off" ]
  unset RALPH_GRAPH_GIT_SANDBOX_PROVEN
}

@test "run-plan TODO gate validates scope before checkbox advancement" {
  local tmpd workspace baseline core checkpoint
  tmpd="$(mktemp -d)"
  workspace="$tmpd/workspace"
  mkdir -p "$workspace/src" "$workspace/docs" "$tmpd/state"
  printf 'base\n' >"$workspace/src/base.txt"
  baseline="$tmpd/baseline.json"
  python3 "$CHANGESET_HELPER" baseline --workspace "$workspace" --output "$baseline" >/dev/null
  core="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-core.sh"
  eval "$(sed -n '/^ralph_graph_write_scope_verify_todo()/,/^}/p' "$core")"
  ralph_run_plan_log() { :; }
  export WORKSPACE="$workspace"
  export RALPH_AGENT_WORKSPACE="$workspace"
  export RALPH_PLAN_WORKSPACE_ROOT="$tmpd/state"
  export RALPH_ARTIFACT_NS="scope-test"
  export RALPH_GRAPH_NODE_ID="build"
  export RALPH_GRAPH_ATTEMPT_ID="attempt-1"
  export RALPH_GRAPH_CHANGESET_BASELINE="$baseline"
  export RALPH_GRAPH_CHANGESET_HELPER="$CHANGESET_HELPER"
  export RALPH_GRAPH_WRITE_SCOPES_JSON='["src/**"]'
  export RALPH_GRAPH_WORKSPACE_MODE="snapshot"
  export RALPH_GRAPH_BASE_IDENTITY="base"

  printf 'valid\n' >"$workspace/src/valid.txt"
  run ralph_graph_write_scope_verify_todo todo-1
  [ "$status" -eq 0 ]
  checkpoint="$tmpd/state/artifacts/scope-test/changeset-checkpoints/build/attempt-1/todo-1.json"
  [ -f "$checkpoint" ]

  printf 'invalid\n' >"$workspace/docs/invalid.txt"
  run ralph_graph_write_scope_verify_todo todo-2
  [ "$status" -ne 0 ]
}
