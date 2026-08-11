#!/usr/bin/env bash
# Deterministic scheduler-owned integration of predecessor changesets.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

GRAPH_INTEGRATION_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRAPH_INTEGRATION_RALPH_ROOT="$(cd "$GRAPH_INTEGRATION_SCRIPT_DIR/../.." && pwd)"
GRAPH_INTEGRATION_HELPER="$GRAPH_INTEGRATION_RALPH_ROOT/python/graph_integrate.py"

# graph_integration_run <run-dir> <graph-json> <node-id> <workspace> <state-root> <namespace>
graph_integration_run() {
  local run_dir="$1" graph_json="$2" node_id="$3" workspace="$4" state_root="$5" namespace="$6"
  local base_identity output conflict dep manifest key
  local args=()
  [[ -f "$run_dir/run.json" && -f "$graph_json" && -d "$workspace" ]] || return 1
  base_identity="$(jq -r '.sourceBase.filesystemIdentity // .sourceBase.git.treeHash // empty' "$run_dir/run.json")"
  [[ -n "$base_identity" ]] || {
    echo "Error: integrate node requires an immutable snapshot or worktree run base" >&2
    return 1
  }
  output="$state_root/artifacts/$namespace/integration/$(graph_workspace_node_key "$node_id").json"
  conflict="$state_root/artifacts/$namespace/integration/$(graph_workspace_node_key "$node_id").conflict.json"
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
  done < <(jq -r --arg id "$node_id" '
    (.nodes[] | select(.id == $id) | .dependsOn) as $deps |
    .nodes[] | select(.id as $candidate | $deps | index($candidate)) | .id
  ' "$graph_json")
  [[ ${#args[@]} -gt 10 ]] || {
    echo "Error: integrate node $node_id requires predecessor changesets" >&2
    return 1
  }
  python3 "$GRAPH_INTEGRATION_HELPER" "${args[@]}" >/dev/null
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
  done < <(jq -r --arg id "$node_id" '
    (.nodes[] | select(.id == $id) | .dependsOn) as $deps |
    .nodes[] | select(.id as $candidate | $deps | index($candidate)) | .id
  ' "$graph_json"))"
  if [[ -z "$manifests" ]]; then
    printf '[]\n'
    return 0
  fi
  printf '%s\n' "$manifests" | jq -R . | jq -s .
}
