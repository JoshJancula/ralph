#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-state.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-run-base.sh"

make_non_git_fixture() {
  local root="$1"
  mkdir -p "$root/src" "$root/.cache" "$root/node_modules/pkg" "$root/.git"
  printf 'stable source\n' >"$root/src/app.txt"
  printf '#!/bin/sh\nexit 0\n' >"$root/src/tool.sh"
  chmod +x "$root/src/tool.sh"
  printf 'cache\n' >"$root/.cache/cache.bin"
  printf 'dependency cache\n' >"$root/node_modules/pkg/index.js"
  printf 'not real git metadata\n' >"$root/.git/config"
  printf 'operator secret\n' >"$root/local.secret"
}

make_git_fixture() {
  local root="$1"
  make_non_git_fixture "$root"
  rm -rf "$root/.git"
  rm -f "$root/local.secret"
  git init -q "$root"
  printf 'local.secret\n' >"$root/.gitignore"
  git -C "$root" add src .gitignore
  git -C "$root" -c user.name=Ralph -c user.email=ralph@example.invalid \
    commit -qm "fixture"
}

make_run_file() {
  local run_dir="$1"
  mkdir -p "$run_dir"
  printf '{"schemaVersion":1,"ralphVersion":"test","runId":"run","status":"running"}\n' \
    >"$run_dir/run.json"
}

roots_json() {
  jq -cn --arg project "$1" --arg state "$2" --arg agent "$3" \
    '{projectRoot:$project,stateRoot:$state,agentWorkspace:$agent}'
}

prepare_fixture() {
  local project="$1" state="$2" run_dir="$3" modes="$4"
  mkdir -p "$state"
  make_run_file "$run_dir"
  graph_run_base_prepare "$run_dir" \
    "$(roots_json "$project" "$state" "$project")" "$modes"
}

@test "non-Git snapshot identities are deterministic and dirty sources are accepted" {
  local tmpd project_a project_b state_a state_b run_a run_b identity_a identity_b
  tmpd="$(mktemp -d)"
  project_a="$tmpd/project-a"
  project_b="$tmpd/project-b"
  state_a="$tmpd/state-a"
  state_b="$tmpd/state-b"
  run_a="$state_a/graph-runs/ns/run-a"
  run_b="$state_b/graph-runs/ns/run-b"
  make_non_git_fixture "$project_a"
  cp -R "$project_a" "$project_b"

  prepare_fixture "$project_a" "$state_a" "$run_a" '["snapshot"]'
  prepare_fixture "$project_b" "$state_b" "$run_b" '["snapshot"]'

  identity_a="$(jq -r '.sourceBase.filesystemIdentity' "$run_a/run.json")"
  identity_b="$(jq -r '.sourceBase.filesystemIdentity' "$run_b/run.json")"
  [ -n "$identity_a" ]
  [ "$identity_a" = "$identity_b" ]
  [ "$(jq -r '.sourceBase.git' "$run_a/run.json")" = "null" ]
  [ "$(jq -r '.sourceBase.immutable' "$run_a/run.json")" = "true" ]
  [ "$(jq -r '.sourceBase.toolVersion' "$run_a/run.json")" = "graph-run-base-v1" ]
  [ ! -e "$run_a/base/source/.git" ]
  [ ! -e "$run_a/base/source/.cache" ]
  [ ! -e "$run_a/base/source/node_modules" ]
}

@test "snapshot treats a project nested under an unrelated Git repository as non-Git" {
  local tmpd outer project state run_dir
  tmpd="$(mktemp -d)"
  outer="$tmpd/outer"
  project="$outer/nested-project"
  state="$tmpd/state"
  run_dir="$state/graph-runs/ns/run"
  mkdir -p "$outer"
  git init -q "$outer"
  make_non_git_fixture "$project"

  prepare_fixture "$project" "$state" "$run_dir" '["snapshot"]'

  [ "$(jq -r '.sourceBase.git' "$run_dir/run.json")" = "null" ]
  [ -f "$run_dir/base/source/src/app.txt" ]
}

@test "snapshot records Git provenance while accepting tracked and untracked dirt" {
  local tmpd project state run_dir head
  tmpd="$(mktemp -d)"
  project="$tmpd/project"
  state="$tmpd/state"
  run_dir="$state/graph-runs/ns/run"
  make_git_fixture "$project"
  printf 'tracked dirty\n' >>"$project/src/app.txt"
  printf 'untracked dirty\n' >"$project/new.txt"
  head="$(git -C "$project" rev-parse HEAD)"

  prepare_fixture "$project" "$state" "$run_dir" '["snapshot"]'

  [ "$(jq -r '.sourceBase.git.head' "$run_dir/run.json")" = "$head" ]
  [ "$(jq -r '.sourceBase.git.clean' "$run_dir/run.json")" = "false" ]
  [ -n "$(jq -r '.sourceBase.git.indexHash' "$run_dir/run.json")" ]
  [ -n "$(jq -r '.sourceBase.git.treeHash' "$run_dir/run.json")" ]
  [ -n "$(jq -r '.sourceBase.git.statusFingerprint' "$run_dir/run.json")" ]
  [ -f "$run_dir/base/source/new.txt" ]
  [ ! -e "$run_dir/base/source/.git" ]
}

@test "worktree mode rejects non-Git tracked-dirty and untracked-dirty sources" {
  local tmpd project state run_dir
  tmpd="$(mktemp -d)"

  project="$tmpd/non-git"
  state="$tmpd/state-non-git"
  run_dir="$state/graph-runs/ns/run"
  make_non_git_fixture "$project"
  run prepare_fixture "$project" "$state" "$run_dir" '["worktree"]'
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires a Git repository"* ]]
  [ ! -e "$run_dir/base/source" ]

  project="$tmpd/tracked-dirty"
  state="$tmpd/state-tracked"
  run_dir="$state/graph-runs/ns/run"
  make_git_fixture "$project"
  printf 'dirty\n' >>"$project/src/app.txt"
  run prepare_fixture "$project" "$state" "$run_dir" '["worktree"]'
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires a clean tracked and untracked worktree"* ]]

  project="$tmpd/untracked-dirty"
  state="$tmpd/state-untracked"
  run_dir="$state/graph-runs/ns/run"
  make_git_fixture "$project"
  printf 'dirty\n' >"$project/untracked.txt"
  run prepare_fixture "$project" "$state" "$run_dir" '["worktree"]'
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires a clean tracked and untracked worktree"* ]]
}

@test "worktree mode accepts documented caches and a clean detached HEAD" {
  local tmpd project state run_dir head
  tmpd="$(mktemp -d)"
  project="$tmpd/project"
  state="$tmpd/state"
  run_dir="$state/graph-runs/ns/run"
  make_git_fixture "$project"
  head="$(git -C "$project" rev-parse HEAD)"
  git -C "$project" checkout -q --detach "$head"
  printf 'ignored by source policy\n' >"$project/.cache/runtime.bin"
  printf 'ignored.env\n' >>"$project/.git/info/exclude"
  printf 'must be declared\n' >"$project/ignored.env"

  run prepare_fixture "$project" "$state" "$run_dir" '["worktree"]'
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires a clean tracked and untracked worktree"* ]]
  export RALPH_GRAPH_SECRET_EXCLUDES="ignored.env"

  prepare_fixture "$project" "$state" "$run_dir" '["worktree"]'

  [ "$(jq -r '.sourceBase.git.head' "$run_dir/run.json")" = "$head" ]
  [ "$(jq -r '.sourceBase.git.clean' "$run_dir/run.json")" = "true" ]
  [ ! -e "$run_dir/base/source/.cache" ]
  [ ! -e "$run_dir/base/source/ignored.env" ]
  unset RALPH_GRAPH_SECRET_EXCLUDES
}

@test "declared secrets and Git metadata never enter the frozen source" {
  local tmpd project state run_dir manifest
  tmpd="$(mktemp -d)"
  project="$tmpd/project"
  state="$tmpd/state"
  run_dir="$state/graph-runs/ns/run"
  make_git_fixture "$project"
  printf 'operator secret\n' >"$project/local.secret"
  export RALPH_GRAPH_SECRET_EXCLUDES="local.secret"

  prepare_fixture "$project" "$state" "$run_dir" '["snapshot"]'

  manifest="$run_dir/base/manifest.json"
  [ ! -e "$run_dir/base/source/local.secret" ]
  [ ! -e "$run_dir/base/source/.git" ]
  ! jq -e '.entries[] | select(.path == "local.secret" or (.path | startswith(".git/")))' \
    "$manifest" >/dev/null
  unset RALPH_GRAPH_SECRET_EXCLUDES
}

@test "nested invocation resolves project root and records an external state root" {
  local tmpd project nested state roots run_dir project_real nested_real state_real
  tmpd="$(mktemp -d)"
  project="$tmpd/project"
  nested="$project/packages/app"
  state="$tmpd/external-state"
  mkdir -p "$nested" "$project/.ralph"
  printf 'source\n' >"$project/source.txt"
  export RALPH_PLAN_WORKSPACE_ROOT="$state"
  roots="$(graph_run_base_resolve_roots "$nested")"
  project_real="$(cd "$project" && pwd -P)"
  nested_real="$(cd "$nested" && pwd -P)"
  state_real="$(cd "$state" && pwd -P)"
  [ "$(printf '%s' "$roots" | jq -r '.projectRoot')" = "$project_real" ]
  [ "$(printf '%s' "$roots" | jq -r '.stateRoot')" = "$state_real" ]
  [ "$(printf '%s' "$roots" | jq -r '.agentWorkspace')" = "$nested_real" ]

  run_dir="$state/graph-runs/ns/run"
  make_run_file "$run_dir"
  graph_run_base_prepare "$run_dir" "$roots" '["snapshot"]'
  [ "$(jq -r '.roots.projectRoot' "$run_dir/run.json")" = "$project_real" ]
  [ "$(jq -r '.roots.stateRoot' "$run_dir/run.json")" = "$state_real" ]
  [ "$(jq -r '.roots.agentWorkspace' "$run_dir/run.json")" = "$nested_real" ]
  [ ! -e "$project/.ralph-workspace" ]
  unset RALPH_PLAN_WORKSPACE_ROOT
}

@test "source mutation during capture fails closed and removes partial base" {
  local tmpd project state run_dir mutator ready
  tmpd="$(mktemp -d)"
  project="$tmpd/project"
  state="$tmpd/state"
  run_dir="$state/graph-runs/ns/run"
  make_non_git_fixture "$project"
  mkdir -p "$state"
  make_run_file "$run_dir"
  export RALPH_GRAPH_BASE_TEST_DELAY_MS=300
  ready="$tmpd/capture-ready"
  export RALPH_GRAPH_BASE_TEST_READY_FILE="$ready"
  (
    while [[ ! -f "$ready" ]]; do sleep 0.01; done
    printf 'mutated during capture\n' >"$project/src/app.txt"
  ) &
  mutator=$!
  run graph_run_base_prepare "$run_dir" \
    "$(roots_json "$project" "$state" "$project")" '["snapshot"]'
  wait "$mutator"
  [ "$status" -ne 0 ]
  [[ "$output" == *"source changed while materializing frozen run base"* ]]
  [ ! -e "$run_dir/base" ]
  [ "$(jq -r '.sourceBase // null' "$run_dir/run.json")" = "null" ]
  unset RALPH_GRAPH_BASE_TEST_DELAY_MS RALPH_GRAPH_BASE_TEST_READY_FILE
}

@test "invalid exclusions and pre-existing bases fail closed without downgrade" {
  local tmpd project state run_dir
  tmpd="$(mktemp -d)"
  project="$tmpd/project"
  state="$tmpd/state"
  run_dir="$state/graph-runs/ns/run"
  make_non_git_fixture "$project"
  mkdir -p "$state"
  make_run_file "$run_dir"
  export RALPH_GRAPH_SECRET_EXCLUDES="../outside"

  run graph_run_base_prepare "$run_dir" \
    "$(roots_json "$project" "$state" "$project")" '["snapshot"]'
  [ "$status" -ne 0 ]
  [[ "$output" == *"secret exclusion must be a project-relative path"* ]]
  [ ! -e "$run_dir/base" ]
  [ "$(jq -r '.sourceBase // null' "$run_dir/run.json")" = "null" ]
  unset RALPH_GRAPH_SECRET_EXCLUDES

  printf 'outside\n' >"$tmpd/outside.secret"
  ln -s "$tmpd/outside.secret" "$project/external-link"
  run graph_run_base_prepare "$run_dir" \
    "$(roots_json "$project" "$state" "$project")" '["snapshot"]'
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsafe absolute symlink in source"* ]]
  [ ! -e "$run_dir/base" ]
  rm -f "$project/external-link"

  mkdir -p "$run_dir/base"
  printf 'owned\n' >"$run_dir/base/sentinel"
  run graph_run_base_prepare "$run_dir" \
    "$(roots_json "$project" "$state" "$project")" '["snapshot"]'
  [ "$status" -ne 0 ]
  [[ "$output" == *"graph run base already exists"* ]]
  [ "$(cat "$run_dir/base/sentinel")" = "owned" ]
}

@test "snapshot excludes the control alias but preserves its physical in-tree source" {
  local tmpd project state run_dir
  tmpd="$(mktemp -d)"
  project="$tmpd/project"
  state="$tmpd/state"
  run_dir="$state/graph-runs/ns/run"
  make_non_git_fixture "$project"
  mkdir -p "$project/bundle/.ralph/bash-lib" "$state"
  printf 'product source\n' >"$project/bundle/.ralph/bash-lib/example.sh"
  ln -s bundle/.ralph "$project/.ralph"
  make_run_file "$run_dir"

  graph_run_base_prepare "$run_dir" \
    "$(roots_json "$project" "$state" "$project")" '["snapshot"]'

  [ ! -e "$run_dir/base/source/.ralph" ]
  [ "$(cat "$run_dir/base/source/bundle/.ralph/bash-lib/example.sh")" = "product source" ]
  jq -e '.entries[] | select(.path == "bundle/.ralph/bash-lib/example.sh")' \
    "$run_dir/base/manifest.json" >/dev/null
}

@test "shared mode records no immutable base and never falls back from isolation" {
  local tmpd project state run_dir
  tmpd="$(mktemp -d)"
  project="$tmpd/project"
  state="$tmpd/state"
  run_dir="$state/graph-runs/ns/run"
  make_non_git_fixture "$project"

  prepare_fixture "$project" "$state" "$run_dir" '["shared"]'

  [ "$(jq -r '.sourceBase.requestedModes[0]' "$run_dir/run.json")" = "shared" ]
  [ "$(jq -r '.sourceBase.immutable' "$run_dir/run.json")" = "false" ]
  [ "$(jq -r '.sourceBase.filesystemIdentity' "$run_dir/run.json")" = "null" ]
  [ ! -e "$run_dir/base" ]
}
