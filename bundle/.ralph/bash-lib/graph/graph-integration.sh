#!/usr/bin/env bash
# Deterministic scheduler-owned integration of predecessor changesets.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

GRAPH_INTEGRATION_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRAPH_INTEGRATION_RALPH_ROOT="$(cd "$GRAPH_INTEGRATION_SCRIPT_DIR/../.." && pwd)"
GRAPH_INTEGRATION_HELPER="$GRAPH_INTEGRATION_RALPH_ROOT/python/graph_integrate.py"

if ! declare -F ralph_atomic_write_json >/dev/null 2>&1; then
  # shellcheck source=../atomic-json.sh
  source "$GRAPH_INTEGRATION_SCRIPT_DIR/../atomic-json.sh"
fi
if ! declare -F graph_workspace_node_key >/dev/null 2>&1; then
  # shellcheck source=graph-workspace-manager.sh
  source "$GRAPH_INTEGRATION_SCRIPT_DIR/graph-workspace-manager.sh"
fi

# graph_integration_artifact_stem <state-root> <namespace> <node-id>
# Shared prefix for the success manifest, conflict artifact, and recovery bundle.
graph_integration_artifact_stem() {
  local state_root="$1" namespace="$2" node_id="$3" key
  key="$(graph_workspace_node_key "$node_id")" || return 1
  printf '%s/artifacts/%s/integration/%s\n' "$state_root" "$namespace" "$key"
}

# graph_integration_conflict_recovery_dir <state-root> <namespace> <node-id>
graph_integration_conflict_recovery_dir() {
  local stem
  stem="$(graph_integration_artifact_stem "$1" "$2" "$3")" || return 1
  printf '%s.recovery\n' "$stem"
}

# graph_integration_inspect_command <namespace> <run-id>
# Exact copyable next command after an integration conflict. Status is
# read-only and surfaces the failed integrate node plus this recovery bundle.
graph_integration_inspect_command() {
  local namespace="$1" run_id="$2"
  printf 'ralph workflow status %q\n' "$run_id"
}

# graph_integration_source_node_ids <run-dir> <graph-json> <integrate-node-id>
# Resolve the nearest succeeded mutating predecessor on every active incoming
# branch. Supervisor and read-only agent nodes are passthroughs: they cannot
# own a changeset, so integration walks through them. Traversal stops at the
# first mutating node on each branch so rework integrates the selected repair
# rather than replaying every earlier mutation in that branch.
graph_integration_source_node_ids() {
  local run_dir="$1" graph_json="$2" node_id="$3"
  local active='{}' node_file row
  local -a node_files=()
  local nullglob_was_set=0

  [[ -d "$run_dir/nodes" && -f "$graph_json" && -n "$node_id" ]] || return 1
  shopt -q nullglob && nullglob_was_set=1
  shopt -s nullglob
  node_files=("$run_dir"/nodes/*.json)
  if [[ "$nullglob_was_set" -eq 0 ]]; then
    shopt -u nullglob
  fi
  for node_file in "${node_files[@]}"; do
    row="$(jq -c '{key:(.nodeId // ""), value:((.status // "") == "succeeded")}' "$node_file" 2>/dev/null || true)"
    [[ -n "$row" && "$(printf '%s' "$row" | jq -r '.key // empty')" != "" ]] || continue
    active="$(jq -cn --argjson base "$active" --argjson row "$row" '$base + {($row.key):$row.value}')"
  done

  jq -r --arg id "$node_id" --argjson active "$active" '
    def graph_node($node_id): .nodes[] | select(.id == $node_id);
    def predecessors($node_id):
      ([graph_node($node_id).dependsOn[]?]
       + [.edges[]? | select(.to == $node_id) | .from])
      | unique;
    def sources($node_id):
      predecessors($node_id)[] as $predecessor
      | select($active[$predecessor] == true)
      | if ((graph_node($predecessor).stage.writeScopes // []) | length) > 0
        then $predecessor
        else sources($predecessor)
        end;
    ([sources($id)] | unique) as $source_ids
    | .nodes[]
    | select(.id as $candidate | $source_ids | index($candidate))
    | .id
  ' "$graph_json"
}

# graph_integration_retain_manifest <manifest> <dest-dir>
# Copy one predecessor changeset and its blobs so conflict attribution survives
# later overwrite of the live changeset path.
graph_integration_retain_manifest() {
  local manifest="$1" dest_dir="$2" blob src dest
  [[ -f "$manifest" && -n "$dest_dir" ]] || return 1
  mkdir -p "$dest_dir" || return 1
  cp "$manifest" "$dest_dir/manifest.json" || return 1
  while IFS= read -r blob || [[ -n "$blob" ]]; do
    [[ -n "$blob" ]] || continue
    src="$(dirname "$manifest")/$blob"
    dest="$dest_dir/$blob"
    [[ -f "$src" ]] || continue
    mkdir -p "$(dirname "$dest")" || return 1
    cp "$src" "$dest" || return 1
  done < <(jq -r '.changes[]? | .blob // empty' "$manifest")
}

# graph_integration_write_conflict_recovery <run-dir> <graph-json> <node-id> \
#   <workspace> <state-root> <namespace> <conflict-file>
# On conflict, publish nothing. Retain attributable inputs, the conflict
# record, the integration base, and the exact operator inspect command.
graph_integration_write_conflict_recovery() {
  local run_dir="$1" graph_json="$2" node_id="$3" workspace="$4"
  local state_root="$5" namespace="$6" conflict="$7"
  local bundle receipt run_id command base_identity frozen_source frozen_manifest
  local inputs_json retained_json paths_json original retained node_key dep_id
  [[ -f "$run_dir/run.json" && -f "$conflict" && -d "$workspace" ]] || return 1
  bundle="$(graph_integration_conflict_recovery_dir "$state_root" "$namespace" "$node_id")" || return 1
  receipt="$bundle/receipt.json"
  run_id="$(jq -r '.runId // empty' "$run_dir/run.json")"
  [[ -n "$run_id" ]] || return 1
  command="$(graph_integration_inspect_command "$namespace" "$run_id")"
  command="${command%$'\n'}"
  base_identity="$(jq -r '.sourceBase.filesystemIdentity // .sourceBase.git.treeHash // empty' "$run_dir/run.json")"
  frozen_source="$(jq -r '.sourceBase.sourcePath // empty' "$run_dir/run.json")"
  frozen_manifest="$(jq -r '.sourceBase.manifestPath // empty' "$run_dir/run.json")"
  rm -rf "$bundle"
  mkdir -p "$bundle/inputs" || return 1
  cp "$conflict" "$bundle/conflict.json" || return 1

  inputs_json="$(jq -c '.inputs // []' "$conflict" 2>/dev/null || printf '[]\n')"
  if [[ "$(printf '%s' "$inputs_json" | jq 'length')" -eq 0 ]]; then
    inputs_json="$(graph_integration_input_manifests_json "$run_dir" "$graph_json" "$node_id" | jq -c 'map({nodeId:"",attemptId:null,contentIdentity:null,manifestPath:.})')"
  fi
  retained_json='[]'
  while IFS= read -r original || [[ -n "$original" ]]; do
    [[ -n "$original" ]] || continue
    dep_id="$(printf '%s' "$inputs_json" | jq -r --arg p "$original" '[.[] | select(.manifestPath == $p) | .nodeId // empty][0] // empty')"
    if [[ -z "$dep_id" ]]; then
      node_key="$(basename "$original" .json)"
    else
      node_key="$(graph_workspace_node_key "$dep_id" 2>/dev/null || basename "$original" .json)"
    fi
    retained="$bundle/inputs/$node_key"
    if [[ -f "$original" ]]; then
      graph_integration_retain_manifest "$original" "$retained" || return 1
    else
      mkdir -p "$retained"
    fi
    retained_json="$(printf '%s' "$retained_json" | jq -c \
      --argjson src "$inputs_json" \
      --arg p "$original" \
      --arg retained "$retained/manifest.json" \
      --arg dir "$retained" \
      '. + [($src[] | select(.manifestPath == $p) | . + {retainedManifest:$retained,retainedDir:$dir})]')"
  done < <(printf '%s' "$inputs_json" | jq -r '.[] | .manifestPath // empty')

  paths_json="$(jq -c '.conflictingPaths // ([.conflicts[]? | .path] | unique)' "$conflict")"
  ralph_atomic_write_json "$receipt" \
    '{
      schemaVersion: 1,
      kind: "graph-integration-conflict-receipt",
      integrationNodeId: $nodeId,
      runId: $runId,
      namespace: $namespace,
      status: "conflict",
      conflictingPaths: $paths,
      integrationBase: {
        filesystemIdentity: (if $base == "" then null else $base end),
        workspacePath: $workspace,
        frozenSourcePath: (if $frozen == "" then null else $frozen end),
        manifestPath: (if $frozenManifest == "" then null else $frozenManifest end)
      },
      inputs: $inputs,
      conflictArtifact: $conflict,
      recoveryBundle: $bundle,
      inspectCommand: $command,
      nextCommand: $command,
      updatedAt: $now
    }' \
    --arg nodeId "$node_id" --arg runId "$run_id" --arg namespace "$namespace" \
    --argjson paths "$paths_json" --arg base "$base_identity" \
    --arg workspace "$workspace" --arg frozen "$frozen_source" \
    --arg frozenManifest "$frozen_manifest" --argjson inputs "$retained_json" \
    --arg conflict "$conflict" --arg bundle "$bundle" --arg command "$command" \
    --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" || return 1

  echo "Error: integration conflict for node $node_id; published nothing" >&2
  echo "Conflicting paths: $(printf '%s' "$paths_json" | jq -r 'join(", ")')" >&2
  echo "Recovery bundle: $bundle" >&2
  echo "Inspect with: $command" >&2
}

# graph_integration_run <run-dir> <graph-json> <node-id> <workspace> <state-root> <namespace>
graph_integration_run() {
  local run_dir="$1" graph_json="$2" node_id="$3" workspace="$4" state_root="$5" namespace="$6"
  local base_identity output conflict dep manifest key stem bundle rc=0
  local args=()
  [[ -f "$run_dir/run.json" && -f "$graph_json" && -d "$workspace" ]] || return 1
  base_identity="$(jq -r '.sourceBase.filesystemIdentity // .sourceBase.git.treeHash // empty' "$run_dir/run.json")"
  [[ -n "$base_identity" ]] || {
    echo "Error: integrate node requires an immutable snapshot or worktree run base" >&2
    return 1
  }
  stem="$(graph_integration_artifact_stem "$state_root" "$namespace" "$node_id")" || return 1
  output="$stem.json"
  conflict="$stem.conflict.json"
  bundle="$stem.recovery"
  args=(
    --workspace "$workspace" --output "$output" --conflict-output "$conflict"
    --node-id "$node_id" --base-identity "$base_identity"
  )
  # Graph array order is the stable application order; dependsOn order in
  # authored YAML or jq object traversal never controls integration results.
  while IFS= read -r dep || [[ -n "$dep" ]]; do
    [[ -n "$dep" ]] || continue
    key="$(graph_workspace_node_key "$dep")" || return 1
    manifest="$run_dir/changesets/nodes/$key.json"
    [[ -f "$manifest" ]] || {
      echo "Error: integrate node $node_id missing predecessor changeset: $dep ($manifest)" >&2
      return 1
    }
    args+=(--manifest "$manifest")
  done < <(graph_integration_source_node_ids "$run_dir" "$graph_json" "$node_id")
  [[ ${#args[@]} -gt 10 ]] || {
    echo "Error: integrate node $node_id requires predecessor changesets" >&2
    return 1
  }
  python3 "$GRAPH_INTEGRATION_HELPER" "${args[@]}" >/dev/null || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    rm -rf "$bundle"
    return 0
  fi
  if [[ -f "$conflict" ]]; then
    graph_integration_write_conflict_recovery \
      "$run_dir" "$graph_json" "$node_id" "$workspace" "$state_root" "$namespace" "$conflict" || true
  fi
  return "$rc"
}

# graph_integration_input_manifests_json <run-dir> <graph-json> <node-id>
# Prints a JSON array of predecessor changeset manifest paths consumed by the
# given integrate node. Returns an empty array when the node is not an integrate
# node or has no predecessor changesets.
graph_integration_input_manifests_json() {
  local run_dir="$1" graph_json="$2" node_id="$3"
  local manifest key
  [[ -f "$run_dir/run.json" && -f "$graph_json" ]] || { printf '[]\n'; return 0; }
  jq -e --arg id "$node_id" '.nodes[] | select(.id == $id) | .type == "integrate"' "$graph_json" >/dev/null 2>&1 || { printf '[]\n'; return 0; }
  local manifests
  manifests="$(while IFS= read -r dep || [[ -n "$dep" ]]; do
    [[ -n "$dep" ]] || continue
    key="$(graph_workspace_node_key "$dep")" || continue
    manifest="$run_dir/changesets/nodes/$key.json"
    [[ -f "$manifest" ]] || continue
    printf '%s\n' "$manifest"
  done < <(graph_integration_source_node_ids "$run_dir" "$graph_json" "$node_id"))"
  if [[ -z "$manifests" ]]; then
    printf '[]\n'
    return 0
  fi
  printf '%s\n' "$manifests" | jq -R . | jq -s .
}
