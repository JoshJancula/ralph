#!/usr/bin/env bats
# Reconstruction-bundle compaction for terminal graph workspaces.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-state.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-run-base.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-workspace-manager.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-changeset.sh"

CHANGESET_HELPER="$REPO_ROOT/bundle/.ralph/python/graph_changeset.py"
INTEGRATE_HELPER="$REPO_ROOT/bundle/.ralph/python/graph_integrate.py"
SNAPSHOT_HELPER="$REPO_ROOT/bundle/.ralph/python/graph_source_snapshot.py"

setup() {
  unset RALPH_GRAPH_SECRET_EXCLUDES RALPH_GRAPH_STATE_ROOT RALPH_GRAPH_COMPACTION_TEST_INTERRUPT
}

teardown() {
  unset RALPH_GRAPH_SECRET_EXCLUDES RALPH_GRAPH_STATE_ROOT RALPH_GRAPH_COMPACTION_TEST_INTERRUPT
}

write_config() {
  local project="$1"
  mkdir -p "$project/.ralph"
  jq -cn '{schemaVersion:1,retention:"prune",setupProfiles:{}}' \
    >"$project/.ralph/graph-workspaces.json"
}

make_compaction_fixture() {
  local project="$1" state="$2" run_dir="$3" graph="$4"
  mkdir -p "$project/src" "$state"
  write_config "$project"
  printf 'keep\n' >"$project/src/keep.txt"
  printf 'delete-me\n' >"$project/src/delete.txt"
  printf 'mode\n' >"$project/src/mode.sh"
  printf 'shared\n' >"$project/src/shared.txt"
  ln -s shared.txt "$project/src/base-link.txt"
  printf 'dirty tracked\n' >"$project/src/dirty.txt"
  git init -q "$project"
  git -C "$project" add .
  git -C "$project" -c user.name=Ralph -c user.email=ralph@example.invalid \
    commit -qm fixture
  # Dirty tracked + untracked inputs must remain in the frozen base.
  printf 'dirty tracked after commit\n' >"$project/src/dirty.txt"
  printf 'untracked base\n' >"$project/untracked.txt"
  jq -cn \
    '{schemaVersion:1,ralphVersion:"test",name:"compaction",
      namespace:"compaction",maxParallel:1,failurePolicy:"drain",
      nodes:[{id:"build",type:"agent",dependsOn:[],derivedFrom:"stage",
        stage:{id:"build",runtime:"cursor",agent:"implementation",
               workspaceMode:"snapshot",writeScopes:["src/**","new.txt","link.txt"]}}],
      edges:[]}' >"$graph"
  mkdir -p "$run_dir"
  jq -cn '{schemaVersion:1,kind:"graph",ralphVersion:"test",runId:"run",
           namespace:"compaction",status:"running"}' >"$run_dir/run.json"
  graph_run_base_prepare "$run_dir" \
    "$(jq -cn --arg project "$project" --arg state "$state" --arg agent "$project" \
      '{projectRoot:$project,stateRoot:$state,agentWorkspace:$agent}')" \
    '["snapshot"]'
  graph_workspace_prepare_run "$run_dir" "$graph"
}

apply_and_capture() {
  local run_dir="$1" graph="$2" path="$3" state="$4"
  graph_changeset_capture_baseline "$run_dir" "$graph" build a1 "$path"
  rm -f "$path/src/delete.txt"
  chmod 755 "$path/src/mode.sh"
  printf 'new file\n' >"$path/new.txt"
  ln -s new.txt "$path/link.txt"
  printf 'edited keep\n' >"$path/src/keep.txt"
  graph_changeset_capture_node "$run_dir" "$graph" build a1 "$path" "$state"
}

mark_succeeded() {
  local run_dir="$1"
  jq '.status = "succeeded" | .kind = "graph" | .namespace = (.namespace // "compaction")' \
    "$run_dir/run.json" >"$run_dir/run.tmp"
  mv "$run_dir/run.tmp" "$run_dir/run.json"
}

dir_bytes() {
  local path="$1"
  if [[ -e "$path" ]]; then
    du -sk "$path" | awk '{print $1 * 1024}'
  else
    printf '0\n'
  fi
}

dir_files() {
  local path="$1"
  if [[ -e "$path" ]]; then
    find "$path" -type f ! -type l | wc -l | tr -d ' '
  else
    printf '0\n'
  fi
}

@test "compaction restores workspace identity from base plus changeset" {
  local tmpd project state run_dir graph path key recon exclude identity
  tmpd="$(mktemp -d)"
  project="$tmpd/project"
  state="$tmpd/state"
  run_dir="$state/graph-runs/compaction/run"
  graph="$tmpd/graph.json"
  make_compaction_fixture "$project" "$state" "$run_dir" "$graph"
  path="$(graph_workspace_prepare_node "$run_dir" "$graph" build)"
  apply_and_capture "$run_dir" "$graph" "$path" "$state"
  key="$(graph_workspace_node_key build)"
  [ -f "$run_dir/changesets/nodes/$key.json" ]
  [ "$(jq -r '[.changes[] | select(.operation == "deleted")] | length' \
    "$run_dir/changesets/nodes/$key.json")" -eq 1 ]
  [ "$(jq -r '.changes[] | select(.path == "src/mode.sh") | .after.mode' \
    "$run_dir/changesets/nodes/$key.json")" = "493" ]
  [ "$(jq -r '.changes[] | select(.path == "link.txt") | .after.type' \
    "$run_dir/changesets/nodes/$key.json")" = "symlink" ]
  [ -f "$run_dir/base/source/src/dirty.txt" ]
  [ -f "$run_dir/base/source/untracked.txt" ]

  mark_succeeded "$run_dir"
  graph_workspace_cleanup_run "$run_dir"
  [ ! -e "$path" ]
  recon="$run_dir/workspaces/changesets/$key.reconstruction.json"
  [ -f "$recon" ]
  [ ! -e "$run_dir/workspaces/changesets/$key.tar.gz" ]
  [ ! -e "$run_dir/workspaces/changesets/$key.tar" ]
  [ "$(jq -r '.kind' "$recon")" = "graph-workspace-reconstruction" ]
  [ "$(jq -r '.reconstructionVerified' "$recon")" = "true" ]
  [ "$(jq -r '.baseIdentity' "$recon")" = \
    "$(jq -r '.sourceBase.filesystemIdentity' "$run_dir/run.json")" ]
  [ -d "$run_dir/base/source" ]
  [ -f "$run_dir/base/manifest.json" ]

  # Re-apply the recorded bundle and confirm the stored identity.
  local tmp exclude_file
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/ralph-compaction-verify.XXXXXX")"
  exclude_file="$(mktemp "${TMPDIR:-/tmp}/ralph-compaction-excludes.XXXXXX")"
  jq -r '.sourceBase.secretExcludes[]? // empty' "$run_dir/run.json" >"$exclude_file"
  cp -a "$run_dir/base/source"/. "$tmp"/
  chmod -R u+w "$tmp"
  python3 "$INTEGRATE_HELPER" \
    --workspace "$tmp" \
    --output "$tmpd/integrate.json" \
    --conflict-output "$tmpd/conflict.json" \
    --node-id build \
    --base-identity "$(jq -r '.sourceBase.filesystemIdentity' "$run_dir/run.json")" \
    --manifest "$run_dir/changesets/nodes/$key.json" >/dev/null
  identity="$(python3 "$SNAPSHOT_HELPER" identity \
    --source "$tmp" --state-root "$state" --exclude-file "$exclude_file" |
    jq -r '.filesystemIdentity')"
  [ "$identity" = "$(jq -r '.workspaceIdentity' "$recon")" ]
  [ -f "$tmp/new.txt" ]
  [ ! -e "$tmp/src/delete.txt" ]
  [ "$(stat -f '%Lp' "$tmp/src/mode.sh" 2>/dev/null || stat -c '%a' "$tmp/src/mode.sh")" = "755" ]
  [ "$(readlink "$tmp/link.txt")" = "new.txt" ]
  [ "$(cat "$tmp/src/dirty.txt")" = "dirty tracked after commit" ]
  [ "$(cat "$tmp/untracked.txt")" = "untracked base" ]
  chmod -R u+w "$tmp" 2>/dev/null || true
  rm -rf "$tmp" "$exclude_file"
}

@test "interrupted compaction leaves the workspace intact" {
  local tmpd project state run_dir graph path key
  tmpd="$(mktemp -d)"
  project="$tmpd/project"
  state="$tmpd/state"
  run_dir="$state/graph-runs/compaction/run"
  graph="$tmpd/graph.json"
  make_compaction_fixture "$project" "$state" "$run_dir" "$graph"
  path="$(graph_workspace_prepare_node "$run_dir" "$graph" build)"
  apply_and_capture "$run_dir" "$graph" "$path" "$state"
  mark_succeeded "$run_dir"
  key="$(graph_workspace_node_key build)"

  RALPH_GRAPH_COMPACTION_TEST_INTERRUPT=1
  run graph_workspace_cleanup_run "$run_dir"
  [ "$status" -ne 0 ]
  [[ "$output" == *"simulated compaction interrupt"* ]]
  [ -d "$path" ]
  [ -f "$path/new.txt" ]
  # Archive artifacts may exist; the materialized workspace must remain.
  [ -f "$run_dir/workspaces/changesets/$key.reconstruction.json" ] || \
    [ -f "$run_dir/workspaces/changesets/$key.tar.gz" ]
  [ "$(jq -r '.status' "$run_dir/workspaces/metadata/$key.json")" != "pruned" ]
}

@test "repeated-run compaction reduces files and bytes versus full workspace retention" {
  local tmpd project state run_a run_b graph path_a path_b key
  local before_files before_bytes after_files after_bytes
  tmpd="$(mktemp -d)"
  project="$tmpd/project"
  state="$tmpd/state"
  graph="$tmpd/graph.json"
  run_a="$state/graph-runs/compaction/run-a"
  run_b="$state/graph-runs/compaction/run-b"

  mkdir -p "$project/src/bulk" "$state"
  write_config "$project"
  printf 'keep\n' >"$project/src/keep.txt"
  printf 'delete-me\n' >"$project/src/delete.txt"
  printf 'mode\n' >"$project/src/mode.sh"
  printf 'shared\n' >"$project/src/shared.txt"
  ln -s shared.txt "$project/src/base-link.txt"
  printf 'dirty tracked\n' >"$project/src/dirty.txt"
  local i
  for i in $(seq 1 40); do
    printf 'bulk payload %s\n' "$i" >"$project/src/bulk/file-$i.txt"
    python3 -c 'import sys; sys.stdout.buffer.write(b"x"*8192)' >>"$project/src/bulk/file-$i.txt"
  done
  git init -q "$project"
  git -C "$project" add .
  git -C "$project" -c user.name=Ralph -c user.email=ralph@example.invalid \
    commit -qm fixture
  printf 'dirty tracked after commit\n' >"$project/src/dirty.txt"
  printf 'untracked base\n' >"$project/untracked.txt"
  jq -cn \
    '{schemaVersion:1,ralphVersion:"test",name:"compaction",
      namespace:"compaction",maxParallel:1,failurePolicy:"drain",
      nodes:[{id:"build",type:"agent",dependsOn:[],derivedFrom:"stage",
        stage:{id:"build",runtime:"cursor",agent:"implementation",
               workspaceMode:"snapshot",writeScopes:["src/**","new.txt","link.txt"]}}],
      edges:[]}' >"$graph"
  mkdir -p "$run_a"
  jq -cn '{schemaVersion:1,kind:"graph",ralphVersion:"test",runId:"run-a",
           namespace:"compaction",status:"running"}' >"$run_a/run.json"
  graph_run_base_prepare "$run_a" \
    "$(jq -cn --arg project "$project" --arg state "$state" --arg agent "$project" \
      '{projectRoot:$project,stateRoot:$state,agentWorkspace:$agent}')" \
    '["snapshot"]'
  graph_workspace_prepare_run "$run_a" "$graph"
  path_a="$(graph_workspace_prepare_node "$run_a" "$graph" build)"
  apply_and_capture "$run_a" "$graph" "$path_a" "$state"

  # Clone a second run with the same shape for a repeated-run fixture.
  mkdir -p "$run_b"
  cp -a "$run_a"/. "$run_b"/
  run_b="$(cd "$run_b" && pwd -P)"
  key="$(graph_workspace_node_key build)"
  path_b="$run_b/workspaces/nodes/$key"
  jq --arg run run-b \
    --arg source "$run_b/base/source" \
    --arg manifest "$run_b/base/manifest.json" \
    '.runId = $run
     | .sourceBase.sourcePath = $source
     | .sourceBase.manifestPath = $manifest' \
    "$run_b/run.json" >"$run_b/run.tmp"
  mv "$run_b/run.tmp" "$run_b/run.json"
  jq --arg owner run-b --arg path "$path_b" \
    '.ownerRunId = $owner | .workspacePath = $path' \
    "$run_b/workspaces/metadata/$key.json" >"$run_b/workspaces/metadata/$key.json.tmp"
  mv "$run_b/workspaces/metadata/$key.json.tmp" "$run_b/workspaces/metadata/$key.json"

  before_files="$(dir_files "$run_a/workspaces/nodes")"
  before_bytes="$(dir_bytes "$run_a/workspaces/nodes")"
  before_files=$((before_files + $(dir_files "$run_b/workspaces/nodes")))
  before_bytes=$((before_bytes + $(dir_bytes "$run_b/workspaces/nodes")))

  mark_succeeded "$run_a"
  mark_succeeded "$run_b"
  graph_workspace_cleanup_run "$run_a"
  graph_workspace_cleanup_run "$run_b"

  after_files="$(dir_files "$run_a/workspaces")"
  after_bytes="$(dir_bytes "$run_a/workspaces")"
  after_files=$((after_files + $(dir_files "$run_b/workspaces")))
  after_bytes=$((after_bytes + $(dir_bytes "$run_b/workspaces")))

  printf 'compaction before files=%s bytes=%s after files=%s bytes=%s\n' \
    "$before_files" "$before_bytes" "$after_files" "$after_bytes" >&2
  [ ! -e "$path_a" ]
  [ ! -e "$path_b" ]
  [ -f "$run_a/workspaces/changesets/$key.reconstruction.json" ]
  [ -f "$run_b/workspaces/changesets/$key.reconstruction.json" ]
  [ -d "$run_a/base/source" ]
  [ -d "$run_b/base/source" ]
  [ "$after_files" -lt "$before_files" ]
  [ "$after_bytes" -lt "$before_bytes" ]
}
