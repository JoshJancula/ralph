#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-state.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-run-base.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-workspace-manager.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-changeset.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/plan-todo.sh"

setup() {
  unset RALPH_GRAPH_SECRET_EXCLUDES RALPH_GRAPH_STATE_ROOT
}

teardown() {
  unset RALPH_GRAPH_SECRET_EXCLUDES RALPH_GRAPH_STATE_ROOT
}

write_config() {
  local project="$1" retention="${2:-keep}" profiles="${3:-}"
  [[ -n "$profiles" ]] || profiles='{}'
  mkdir -p "$project/.ralph"
  jq -cn --arg retention "$retention" --argjson profiles "$profiles" \
    '{schemaVersion:1,retention:$retention,setupProfiles:$profiles}' \
    >"$project/.ralph/graph-workspaces.json"
}

make_project() {
  local project="$1"
  mkdir -p "$project/src"
  printf 'base\n' >"$project/src/app.txt"
  printf '#!/bin/sh\nexit 0\n' >"$project/src/tool.sh"
  chmod +x "$project/src/tool.sh"
}

make_git_project() {
  local project="$1" profiles="${2:-}" retention="${3:-keep}"
  [[ -n "$profiles" ]] || profiles='{}'
  make_project "$project"
  write_config "$project" "$retention" "$profiles"
  git init -q "$project"
  git -C "$project" add .
  git -C "$project" -c user.name=Ralph -c user.email=ralph@example.invalid \
    commit -qm fixture
}

write_graph() {
  local path="$1"
  shift
  local nodes='[]' spec id mode profile stage
  for spec in "$@"; do
    IFS=: read -r id mode profile <<<"$spec"
    stage="$(jq -cn --arg id "$id" --arg mode "$mode" --arg profile "$profile" \
      '{id:$id,runtime:"cursor",agent:"implementation",workspaceMode:$mode}
       + (if $profile == "" then {} else {setupProfile:$profile} end)')"
    nodes="$(printf '%s' "$nodes" | jq -c --arg id "$id" --argjson stage "$stage" \
      '. + [{id:$id,type:"agent",dependsOn:[],derivedFrom:"stage",stage:$stage}]')"
  done
  jq -cn --argjson nodes "$nodes" \
    '{schemaVersion:1,ralphVersion:"test",name:"workspace-test",
      namespace:"workspace-test",maxParallel:4,failurePolicy:"drain",
      nodes:$nodes,edges:[]}' >"$path"
}

prepare_run() {
  local project="$1" state="$2" run_dir="$3" graph="$4" modes="$5"
  mkdir -p "$run_dir"
  jq -cn --arg run "$(basename "$run_dir")" \
    '{schemaVersion:1,ralphVersion:"test",runId:$run,status:"running"}' \
    >"$run_dir/run.json"
  graph_run_base_prepare "$run_dir" \
    "$(jq -cn --arg project "$project" --arg state "$state" --arg agent "$project" \
      '{projectRoot:$project,stateRoot:$state,agentWorkspace:$agent}')" \
    "$modes"
  graph_workspace_prepare_run "$run_dir" "$graph"
}

file_sha() {
  shasum -a 256 "$1" | awk '{print $1}'
}

@test "graph compilation preserves operator workspace mode and setup profile names" {
  local tmpd plan payload
  tmpd="$(mktemp -d)"
  plan="$tmpd/workspace.plan.md"
  cat >"$plan" <<'PLAN'
---
execution: graph
pipeline:
  stages:
    - id: build
      runtime: cursor
      workspaceMode: snapshot
      setupProfile: dependencies
todos:
  - id: build-1
    stage: build
    content: build in isolation
    status: pending
---
PLAN

  run plan_pipeline_graph_json "$plan"
  [ "$status" -eq 0 ]
  payload="$(printf '%s\n' "$output" | awk 'END { print }')"
  [ "$(printf '%s' "$payload" | jq -r '.nodes[0].stage.workspaceMode')" = "snapshot" ]
  [ "$(printf '%s' "$payload" | jq -r '.nodes[0].stage.setupProfile')" = "dependencies" ]
}

@test "snapshot creates parallel non-Git workspaces without Git metadata and reuses them" {
  local tmpd project state run_dir graph p1 p2 again
  tmpd="$(mktemp -d)"
  project="$tmpd/project"
  state="$tmpd/state"
  run_dir="$state/graph-runs/ns/run"
  graph="$tmpd/graph.json"
  make_project "$project"
  write_config "$project"
  write_graph "$graph" "left:snapshot:" "right:snapshot:"
  prepare_run "$project" "$state" "$run_dir" "$graph" '["snapshot"]'

  graph_workspace_prepare_node "$run_dir" "$graph" left >"$tmpd/left.path" &
  local left_pid=$!
  graph_workspace_prepare_node "$run_dir" "$graph" right >"$tmpd/right.path" &
  local right_pid=$!
  wait "$left_pid"
  wait "$right_pid"
  p1="$(<"$tmpd/left.path")"
  p2="$(<"$tmpd/right.path")"

  [ "$p1" != "$p2" ]
  [ -f "$p1/src/app.txt" ]
  [ -f "$p2/src/app.txt" ]
  [ ! -e "$p1/.git" ]
  [ ! -e "$p2/.git" ]
  printf 'retry marker\n' >"$p1/retry.txt"
  again="$(graph_workspace_prepare_node "$run_dir" "$graph" left)"
  [ "$again" = "$p1" ]
  [ -f "$again/retry.txt" ]
}

@test "dirty snapshot lanes share one frozen base, isolate changesets, and cannot discover caller Git" {
  local tmpd project state agent run_dir graph left right left_pid right_pid
  local identity_before identity_after status_before status_after refs_before refs_after
  local left_manifest right_manifest left_paths right_paths project_git discovered
  tmpd="$(mktemp -d)"
  project="$tmpd/project"
  agent="$tmpd/agent"
  mkdir -p "$project/src" "$agent"
  write_config "$project"
  printf 'left base\n' >"$project/src/left.txt"
  printf 'right base\n' >"$project/src/right.txt"
  printf 'shared\n' >"$project/src/shared.txt"
  ln -s shared.txt "$project/src/link.txt"
  printf 'control\n' >"$project/.ralph/control.txt"
  printf '.ralph-workspace/\nstate-alias\n' >"$project/.gitignore"
  git init -q "$project"
  git -C "$project" add src .ralph .gitignore
  git -C "$project" -c user.name=Ralph -c user.email=ralph@example.invalid \
    commit -qm fixture
  printf 'tracked dirty\n' >"$project/src/left.txt"
  printf 'untracked dirty\n' >"$project/untracked.txt"
  state="$project/.ralph-workspace"
  mkdir -p "$state"
  ln -s .ralph-workspace "$project/state-alias"
  printf 'state sentinel\n' >"$state/should-not-freeze.txt"
  run_dir="$state/graph-runs/ns/run"
  graph="$tmpd/graph.json"
  jq -cn \
    '{schemaVersion:1,ralphVersion:"test",name:"dirty-base",
      namespace:"dirty-base",maxParallel:2,failurePolicy:"drain",
      nodes:[
        {id:"left",type:"agent",dependsOn:[],derivedFrom:"stage",
         stage:{id:"left",runtime:"cursor",agent:"implementation",
                workspaceMode:"snapshot",writeScopes:["src/left.txt"]}},
        {id:"right",type:"agent",dependsOn:[],derivedFrom:"stage",
         stage:{id:"right",runtime:"cursor",agent:"implementation",
                workspaceMode:"snapshot",writeScopes:["src/right.txt"]}}
      ],edges:[]}' >"$graph"
  mkdir -p "$run_dir"
  jq -cn '{schemaVersion:1,ralphVersion:"test",runId:"run",status:"running"}' \
    >"$run_dir/run.json"
  identity_before="$(python3 "$GRAPH_WORKSPACE_HELPER" identity \
    --source "$project" --state-root "$state" | jq -c .)"
  status_before="$(git -C "$project" status --porcelain=v1 --untracked-files=all)"
  refs_before="$(git -C "$project" show-ref)"
  project_git="$(git -C "$project" rev-parse --show-toplevel)"

  graph_run_base_prepare "$run_dir" \
    "$(jq -cn --arg project "$project" --arg state "$state" --arg agent "$agent" \
      '{projectRoot:$project,stateRoot:$state,agentWorkspace:$agent}')" \
    '["snapshot"]'
  graph_workspace_prepare_run "$run_dir" "$graph"

  [ "$(jq -r '.roots.projectRoot' "$run_dir/run.json")" = "$(cd "$project" && pwd -P)" ]
  [ "$(jq -r '.roots.stateRoot' "$run_dir/run.json")" = "$(cd "$state" && pwd -P)" ]
  [ "$(jq -r '.roots.agentWorkspace' "$run_dir/run.json")" = "$(cd "$agent" && pwd -P)" ]
  [ "$(jq -r '.sourceBase.immutable' "$run_dir/run.json")" = "true" ]
  [ -n "$(jq -r '.sourceBase.filesystemIdentity' "$run_dir/run.json")" ]
  [ "$(jq -r '.sourceBase.git.clean' "$run_dir/run.json")" = "false" ]
  [ -f "$run_dir/base/source/src/left.txt" ]
  [ "$(cat "$run_dir/base/source/src/left.txt")" = "tracked dirty" ]
  [ "$(cat "$run_dir/base/source/untracked.txt")" = "untracked dirty" ]
  [ "$(readlink "$run_dir/base/source/src/link.txt")" = "shared.txt" ]
  [ ! -e "$run_dir/base/source/.git" ]
  [ ! -e "$run_dir/base/source/.ralph" ]
  [ ! -e "$run_dir/base/source/.ralph-workspace" ]
  [ ! -e "$run_dir/base/source/state-alias" ]
  [ ! -e "$run_dir/base/source/should-not-freeze.txt" ]
  ! jq -e '.entries[] | select(.path == ".ralph" or (.path | startswith(".ralph/"))
      or .path == ".ralph-workspace" or (.path | startswith(".ralph-workspace/"))
      or .path == "state-alias" or .path == "should-not-freeze.txt")' \
    "$run_dir/base/manifest.json" >/dev/null

  graph_workspace_prepare_node "$run_dir" "$graph" left >"$tmpd/left.path" &
  left_pid=$!
  graph_workspace_prepare_node "$run_dir" "$graph" right >"$tmpd/right.path" &
  right_pid=$!
  wait "$left_pid"
  wait "$right_pid"
  left="$(<"$tmpd/left.path")"
  right="$(<"$tmpd/right.path")"
  [ "$left" != "$right" ]
  [ "$(cat "$left/src/left.txt")" = "tracked dirty" ]
  [ "$(cat "$right/src/left.txt")" = "tracked dirty" ]
  [ "$(cat "$left/untracked.txt")" = "$(cat "$right/untracked.txt")" ]
  [ "$(readlink "$left/src/link.txt")" = "shared.txt" ]
  [ "$(readlink "$right/src/link.txt")" = "shared.txt" ]
  [ ! -e "$left/.ralph" ]
  [ ! -e "$right/.ralph-workspace" ]
  [ ! -e "$left/state-alias" ]
  run git -C "$left" rev-parse --show-toplevel
  [ "$status" -eq 0 ]
  discovered="$(git -C "$left" rev-parse --show-toplevel 2>/dev/null || true)"
  [ "$discovered" = "$left" ]
  [ "$discovered" != "$project_git" ]
  run git -C "$right" rev-parse --show-toplevel
  [ "$status" -eq 0 ]
  discovered="$(git -C "$right" rev-parse --show-toplevel 2>/dev/null || true)"
  [ "$discovered" = "$right" ]
  [ "$discovered" != "$project_git" ]

  graph_changeset_capture_baseline "$run_dir" "$graph" left a1 "$left"
  graph_changeset_capture_baseline "$run_dir" "$graph" right a1 "$right"
  printf 'left lane\n' >"$left/src/left.txt"
  printf 'right lane\n' >"$right/src/right.txt"
  graph_changeset_capture_node "$run_dir" "$graph" left a1 "$left" "$state"
  graph_changeset_capture_node "$run_dir" "$graph" right a1 "$right" "$state"
  left_manifest="$(graph_changeset_manifest_path "$run_dir" left)"
  right_manifest="$(graph_changeset_manifest_path "$run_dir" right)"
  left_paths="$(jq -r '[.changes[].path] | sort | join(",")' "$left_manifest")"
  right_paths="$(jq -r '[.changes[].path] | sort | join(",")' "$right_manifest")"
  [ "$left_paths" = "src/left.txt" ]
  [ "$right_paths" = "src/right.txt" ]
  [ "$(jq -r '.changes[0].after.sha256' "$left_manifest")" != \
    "$(jq -r '.changes[0].after.sha256' "$right_manifest")" ]
  [ "$(cat "$left/src/right.txt")" = "right base" ]
  [ "$(cat "$right/src/left.txt")" = "tracked dirty" ]

  identity_after="$(python3 "$GRAPH_WORKSPACE_HELPER" identity \
    --source "$project" --state-root "$state" | jq -c .)"
  status_after="$(git -C "$project" status --porcelain=v1 --untracked-files=all)"
  refs_after="$(git -C "$project" show-ref)"
  [ "$identity_after" = "$identity_before" ]
  [ "$(jq -r '.sourceBase.filesystemIdentity' "$run_dir/run.json")" = \
    "$(printf '%s' "$identity_after" | jq -r '.filesystemIdentity')" ]
  [ "$status_after" = "$status_before" ]
  [ "$refs_after" = "$refs_before" ]
  [ "$(cat "$project/src/left.txt")" = "tracked dirty" ]
  [ "$(cat "$project/src/right.txt")" = "right base" ]
  [ "$(cat "$project/untracked.txt")" = "untracked dirty" ]
  [ "$(readlink "$project/src/link.txt")" = "shared.txt" ]
}

@test "snapshot workspace survives an interrupted manager phase and cannot change repository refs" {
  local tmpd project state run_dir graph path metadata refs_before refs_after manager
  tmpd="$(mktemp -d)"
  project="$tmpd/project"
  state="$tmpd/state"
  run_dir="$state/graph-runs/ns/run"
  graph="$tmpd/graph.json"
  make_git_project "$project"
  write_graph "$graph" "node:snapshot:"
  prepare_run "$project" "$state" "$run_dir" "$graph" '["snapshot"]'

  path="$(graph_workspace_prepare_node "$run_dir" "$graph" node)"
  metadata="$(graph_workspace_node_key node)"
  metadata="$run_dir/workspaces/metadata/$metadata.json"
  jq '.status = "setup"' "$metadata" >"$metadata.tmp"
  mv "$metadata.tmp" "$metadata"
  refs_before="$(git -C "$project" show-ref)"
  printf 'changed\n' >"$path/src/app.txt"
  run git -C "$path" update-ref refs/heads/should-not-exist HEAD
  [ "$status" -ne 0 ]
  manager="$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-workspace-manager.sh"
  [ "$(/bin/bash -c 'source "$1"; graph_workspace_prepare_node "$2" "$3" "$4"' \
    _ "$manager" "$run_dir" "$graph" node)" = "$path" ]
  refs_after="$(git -C "$project" show-ref)"
  [ "$refs_after" = "$refs_before" ]
}

@test "shared backend records that it uses the caller workspace without isolation" {
  local tmpd project state run_dir graph path key metadata
  tmpd="$(mktemp -d)"
  project="$tmpd/project"
  state="$tmpd/state"
  run_dir="$state/graph-runs/ns/run"
  graph="$tmpd/graph.json"
  make_project "$project"
  write_config "$project"
  write_graph "$graph" "node:shared:"
  prepare_run "$project" "$state" "$run_dir" "$graph" '["shared"]'

  path="$(graph_workspace_prepare_node "$run_dir" "$graph" node)"
  key="$(graph_workspace_node_key node)"
  metadata="$run_dir/workspaces/metadata/$key.json"
  [ "$path" = "$(cd "$project" && pwd -P)" ]
  [ "$(jq -r '.mode' "$metadata")" = "shared" ]
  [ "$(jq -r '.isolation' "$metadata")" = "false" ]
}

@test "worktree creates detached parallel workspaces without changing checkout refs or index" {
  local tmpd project state run_dir graph refs_before refs_after index index_before index_after status_before status_after p1 p2
  tmpd="$(mktemp -d)"
  project="$tmpd/project"
  state="$tmpd/state"
  run_dir="$state/graph-runs/ns/run"
  graph="$tmpd/graph.json"
  make_git_project "$project"
  write_graph "$graph" "left:worktree:" "right:worktree:"
  prepare_run "$project" "$state" "$run_dir" "$graph" '["worktree"]'
  refs_before="$(git -C "$project" show-ref)"
  index="$(git -C "$project" rev-parse --git-path index)"
  [[ "$index" == /* ]] || index="$project/$index"
  index_before="$(file_sha "$index")"
  status_before="$(git -C "$project" status --porcelain=v1 --untracked-files=all)"

  graph_workspace_prepare_node "$run_dir" "$graph" left >"$tmpd/left.path" 2>"$tmpd/left.err" &
  local left_pid=$!
  graph_workspace_prepare_node "$run_dir" "$graph" right >"$tmpd/right.path" 2>"$tmpd/right.err" &
  local right_pid=$!
  wait "$left_pid"
  wait "$right_pid"
  p1="$(<"$tmpd/left.path")"
  p2="$(<"$tmpd/right.path")"

  [ "$p1" != "$p2" ]
  ! git -C "$p1" symbolic-ref -q HEAD
  ! git -C "$p2" symbolic-ref -q HEAD
  refs_after="$(git -C "$project" show-ref)"
  index_after="$(file_sha "$index")"
  status_after="$(git -C "$project" status --porcelain=v1 --untracked-files=all)"
  [ "$refs_after" = "$refs_before" ]
  [ "$index_after" = "$index_before" ]
  [ "$status_after" = "$status_before" ]
  [ "$(find "$run_dir/workspaces/git-journal" -name '*-add-started.json' | wc -l | tr -d ' ')" -eq 2 ]
  [ "$(find "$run_dir/workspaces/git-journal" -name '*-add-completed.json' | wc -l | tr -d ' ')" -eq 2 ]
}

@test "interrupted worktree add is adopted and retry reuses the registered path" {
  local tmpd project state run_dir graph key path metadata head result
  tmpd="$(mktemp -d)"
  project="$tmpd/project"
  state="$tmpd/state"
  run_dir="$state/graph-runs/ns/run"
  graph="$tmpd/graph.json"
  make_git_project "$project"
  write_graph "$graph" "node:worktree:"
  prepare_run "$project" "$state" "$run_dir" "$graph" '["worktree"]'
  run_dir="$(cd "$run_dir" && pwd -P)"
  key="$(graph_workspace_node_key node)"
  path="$run_dir/workspaces/nodes/$key"
  metadata="$run_dir/workspaces/metadata/$key.json"
  mkdir -p "$(dirname "$metadata")"
  _graph_workspace_write_metadata "$metadata" run node worktree "$path" "" creating
  head="$(git -C "$project" rev-parse HEAD)"
  git -C "$project" worktree add --detach "$path" "$head" >/dev/null

  result="$(graph_workspace_prepare_node "$run_dir" "$graph" node)"
  [ "$result" = "$path" ]
  printf 'durable\n' >"$path/reused.txt"
  [ "$(graph_workspace_prepare_node "$run_dir" "$graph" node)" = "$path" ]
  [ -f "$path/reused.txt" ]
}

@test "setup profiles freeze commands, report failure, and resume in the same workspace" {
  local tmpd project state run_dir graph profiles path key metadata
  tmpd="$(mktemp -d)"
  project="$tmpd/project"
  state="$tmpd/state"
  run_dir="$state/graph-runs/ns/run"
  graph="$tmpd/graph.json"
  make_project "$project"
  profiles='{"deps":{"commands":["test -f .setup-ready","printf done > setup.out"]}}'
  write_config "$project" keep "$profiles"
  write_graph "$graph" "node:snapshot:deps"
  prepare_run "$project" "$state" "$run_dir" "$graph" '["snapshot"]'

  run graph_workspace_prepare_node "$run_dir" "$graph" node
  [ "$status" -ne 0 ]
  [[ "$output" == *"command 1 failed"* ]]
  key="$(graph_workspace_node_key node)"
  metadata="$run_dir/workspaces/metadata/$key.json"
  path="$(jq -r '.workspacePath' "$metadata")"
  [ "$(jq -r '.status' "$metadata")" = "setup-failed" ]
  printf 'ready\n' >"$path/.setup-ready"
  [ "$(graph_workspace_prepare_node "$run_dir" "$graph" node)" = "$path" ]
  [ "$(cat "$path/setup.out")" = "done" ]
  [ "$(jq -r '.setupCompleted' "$metadata")" -eq 2 ]
}

@test "operator-allowed ignored file is included while undeclared secrets stay excluded" {
  local tmpd project state run_dir graph profiles path
  tmpd="$(mktemp -d)"
  project="$tmpd/project"
  state="$tmpd/state"
  run_dir="$state/graph-runs/ns/run"
  graph="$tmpd/graph.json"
  profiles='{"local":{"includePatterns":[".env.local"],"allowedIgnoredPaths":[".env.local"]}}'
  make_project "$project"
  write_config "$project" keep "$profiles"
  printf '.env.local\nprivate.key\n' >"$project/.gitignore"
  printf 'allowed\n' >"$project/.env.local"
  printf 'blocked\n' >"$project/private.key"
  git init -q "$project"
  git -C "$project" add .
  git -C "$project" -c user.name=Ralph -c user.email=ralph@example.invalid commit -qm fixture
  write_graph "$graph" "node:snapshot:local"
  export RALPH_GRAPH_SECRET_EXCLUDES=$'.env.local\nprivate.key'
  prepare_run "$project" "$state" "$run_dir" "$graph" '["snapshot"]'

  path="$(graph_workspace_prepare_node "$run_dir" "$graph" node)"
  [ "$(cat "$path/.env.local")" = "allowed" ]
  [ ! -e "$path/private.key" ]
}

@test "directory includes reject nested secrets unless the operator allows the exact path" {
  local tmpd project state run_dir graph profiles
  tmpd="$(mktemp -d)"
  project="$tmpd/project"
  state="$tmpd/state"
  run_dir="$state/graph-runs/ns/run"
  graph="$tmpd/graph.json"
  make_project "$project"
  mkdir -p "$project/config"
  printf 'secret\n' >"$project/config/private.key"
  profiles='{"local":{"includePatterns":["config"],"allowedIgnoredPaths":[]}}'
  write_config "$project" keep "$profiles"
  write_graph "$graph" "node:snapshot:local"
  export RALPH_GRAPH_SECRET_EXCLUDES="config/private.key"
  prepare_run "$project" "$state" "$run_dir" "$graph" '["snapshot"]'

  run graph_workspace_prepare_node "$run_dir" "$graph" node
  [ "$status" -ne 0 ]
  [[ "$output" == *"config/private.key is secret"* ]]
}

@test "worktrees scrub declared tracked secrets and restore only operator-allowed paths" {
  local tmpd project state run_dir graph profiles blocked allowed
  tmpd="$(mktemp -d)"
  project="$tmpd/project"
  state="$tmpd/state"
  run_dir="$state/graph-runs/ns/run"
  graph="$tmpd/graph.json"
  profiles='{"local":{"includePatterns":["tracked.secret"],"allowedIgnoredPaths":["tracked.secret"]}}'
  make_project "$project"
  printf 'secret\n' >"$project/tracked.secret"
  write_config "$project" keep "$profiles"
  git init -q "$project"
  git -C "$project" add .
  git -C "$project" -c user.name=Ralph -c user.email=ralph@example.invalid commit -qm fixture
  write_graph "$graph" "blocked:worktree:" "allowed:worktree:local"
  export RALPH_GRAPH_SECRET_EXCLUDES="tracked.secret"
  prepare_run "$project" "$state" "$run_dir" "$graph" '["worktree"]'

  blocked="$(graph_workspace_prepare_node "$run_dir" "$graph" blocked)"
  allowed="$(graph_workspace_prepare_node "$run_dir" "$graph" allowed)"
  [ ! -e "$blocked/tracked.secret" ]
  [ "$(cat "$allowed/tracked.secret")" = "secret" ]
}

@test "secret inclusion without an allowed path and symlink inclusion fail closed" {
  local tmpd project state run_dir graph profiles
  tmpd="$(mktemp -d)"
  project="$tmpd/project"
  state="$tmpd/state"
  run_dir="$state/graph-runs/ns/run-secret"
  graph="$tmpd/secret-graph.json"
  make_project "$project"
  profiles='{"local":{"includePatterns":[".env.local"]}}'
  write_config "$project" keep "$profiles"
  printf 'secret\n' >"$project/.env.local"
  write_graph "$graph" "node:snapshot:local"
  export RALPH_GRAPH_SECRET_EXCLUDES=".env.local"
  prepare_run "$project" "$state" "$run_dir" "$graph" '["snapshot"]'
  run graph_workspace_prepare_node "$run_dir" "$graph" node
  [ "$status" -ne 0 ]
  [[ "$output" == *"name it in allowedIgnoredPaths"* ]]

  unset RALPH_GRAPH_SECRET_EXCLUDES
  project="$tmpd/symlink-project"
  run_dir="$state/graph-runs/ns/run-symlink"
  graph="$tmpd/symlink-graph.json"
  make_project "$project"
  printf 'local\n' >"$project/local.txt"
  ln -s local.txt "$project/local-link"
  profiles='{"local":{"includePatterns":["local-link"],"allowedIgnoredPaths":["local-link"]}}'
  write_config "$project" keep "$profiles"
  write_graph "$graph" "node:snapshot:local"
  prepare_run "$project" "$state" "$run_dir" "$graph" '["snapshot"]'
  run graph_workspace_prepare_node "$run_dir" "$graph" node
  [ "$status" -ne 0 ]
  [[ "$output" == *"must not contain symlinks"* ]]
}

@test "path traversal and model-supplied setup instructions are rejected" {
  local tmpd project state run_dir graph profiles
  tmpd="$(mktemp -d)"
  project="$tmpd/project"
  state="$tmpd/state"
  run_dir="$state/graph-runs/ns/run"
  graph="$tmpd/graph.json"
  make_project "$project"
  profiles='{"bad":{"includePatterns":["../outside"],"allowedIgnoredPaths":[]}}'
  write_config "$project" keep "$profiles"
  write_graph "$graph" "../../node:snapshot:bad"
  prepare_run "$project" "$state" "$run_dir" "$graph" '["snapshot"]'
  run graph_workspace_prepare_node "$run_dir" "$graph" "../../node"
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be a project-relative path"* ]]
  [ ! -e "$state/graph-runs/ns/outside" ]

  jq '(.nodes[0].stage.setupCommands) = ["touch injected"]' "$graph" >"$graph.tmp"
  mv "$graph.tmp" "$graph"
  chmod -R u+w "$run_dir/base"
  rm -rf "$run_dir"
  mkdir -p "$run_dir"
  printf '{"schemaVersion":1,"runId":"run","status":"running"}\n' >"$run_dir/run.json"
  graph_run_base_prepare "$run_dir" \
    "$(jq -cn --arg project "$project" --arg state "$state" --arg agent "$project" \
      '{projectRoot:$project,stateRoot:$state,agentWorkspace:$agent}')" '["snapshot"]'
  run graph_workspace_prepare_run "$run_dir" "$graph"
  [ "$status" -ne 0 ]
  [[ "$output" == *"must come from project graph-workspaces.json"* ]]
}

@test "cleanup enforces retention and ownership and archives before exact removal" {
  local tmpd project state keep_run prune_run graph profiles keep_path prune_path key metadata
  tmpd="$(mktemp -d)"
  project="$tmpd/project"
  state="$tmpd/state"
  keep_run="$state/graph-runs/ns/keep"
  prune_run="$state/graph-runs/ns/prune"
  graph="$tmpd/graph.json"
  make_project "$project"
  write_config "$project" keep '{}'
  write_graph "$graph" "node:snapshot:"
  prepare_run "$project" "$state" "$keep_run" "$graph" '["snapshot"]'
  keep_path="$(graph_workspace_prepare_node "$keep_run" "$graph" node)"
  jq '.status = "succeeded"' "$keep_run/run.json" >"$keep_run/run.tmp"
  mv "$keep_run/run.tmp" "$keep_run/run.json"
  graph_workspace_cleanup_run "$keep_run"
  [ -d "$keep_path" ]

  write_config "$project" prune '{}'
  prepare_run "$project" "$state" "$prune_run" "$graph" '["snapshot"]'
  prune_path="$(graph_workspace_prepare_node "$prune_run" "$graph" node)"
  printf 'recover me\n' >"$prune_path/change.txt"
  key="$(graph_workspace_node_key node)"
  metadata="$prune_run/workspaces/metadata/$key.json"
  jq '.status = "succeeded"' "$prune_run/run.json" >"$prune_run/run.tmp"
  mv "$prune_run/run.tmp" "$prune_run/run.json"
  graph_workspace_cleanup_run "$prune_run"
  [ ! -e "$prune_path" ]
  [ -f "$prune_run/workspaces/changesets/$key.tar" ]
  [ "$(jq -r '.status' "$metadata")" = "pruned" ]

  jq '.workspacePath = "/tmp/not-owned-by-ralph"' "$metadata" >"$metadata.tmp"
  mv "$metadata.tmp" "$metadata"
  run graph_workspace_cleanup_run "$prune_run"
  [ "$status" -ne 0 ]
  [[ "$output" == *"outside exact owned node path"* ]]
}

@test "cleanup refuses running runs and interrupted worktree removal remains recoverable" {
  local tmpd project state run_dir graph path key metadata
  tmpd="$(mktemp -d)"
  project="$tmpd/project"
  state="$tmpd/state"
  run_dir="$state/graph-runs/ns/run"
  graph="$tmpd/graph.json"
  make_git_project "$project" '{}' prune
  write_graph "$graph" "node:worktree:"
  prepare_run "$project" "$state" "$run_dir" "$graph" '["worktree"]'
  path="$(graph_workspace_prepare_node "$run_dir" "$graph" node)"
  run graph_workspace_cleanup_run "$run_dir"
  [ "$status" -ne 0 ]
  [[ "$output" == *"terminal prunable run"* ]]
  [ -d "$path" ]

  jq '.status = "failed"' "$run_dir/run.json" >"$run_dir/run.tmp"
  mv "$run_dir/run.tmp" "$run_dir/run.json"
  key="$(graph_workspace_node_key node)"
  metadata="$run_dir/workspaces/metadata/$key.json"
  _graph_workspace_journal_git "$run_dir" "$key" remove started "$path" \
    "$(git -C "$project" rev-parse HEAD)"
  graph_workspace_cleanup_run "$run_dir"
  [ ! -e "$path" ]
  [ -f "$run_dir/workspaces/changesets/$key.tar" ]
  [ "$(jq -r '.status' "$metadata")" = "pruned" ]
  [ "$(find "$run_dir/workspaces/git-journal/$key" -name '*-remove-completed.json' | wc -l | tr -d ' ')" -eq 1 ]
}

@test "cleanup rejects a symlinked ownership root without deleting the workspace" {
  local tmpd project state run_dir graph path
  tmpd="$(mktemp -d)"
  project="$tmpd/project"
  state="$tmpd/state"
  run_dir="$state/graph-runs/ns/run"
  graph="$tmpd/graph.json"
  make_project "$project"
  write_config "$project" prune '{}'
  write_graph "$graph" "node:snapshot:"
  prepare_run "$project" "$state" "$run_dir" "$graph" '["snapshot"]'
  path="$(graph_workspace_prepare_node "$run_dir" "$graph" node)"
  jq '.status = "succeeded"' "$run_dir/run.json" >"$run_dir/run.tmp"
  mv "$run_dir/run.tmp" "$run_dir/run.json"
  mv "$run_dir/workspaces/nodes" "$run_dir/workspaces/nodes-real"
  ln -s nodes-real "$run_dir/workspaces/nodes"

  run graph_workspace_cleanup_run "$run_dir"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing or unsafe"* ]]
  [ -d "$run_dir/workspaces/nodes-real/$(basename "$path")" ]
}
