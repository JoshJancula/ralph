#!/usr/bin/env bash
# Write-scope baselines and backend-neutral graph changeset capture.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

GRAPH_CHANGESET_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRAPH_CHANGESET_RALPH_ROOT="$(cd "$GRAPH_CHANGESET_SCRIPT_DIR/../.." && pwd)"
GRAPH_CHANGESET_HELPER="$GRAPH_CHANGESET_RALPH_ROOT/python/graph_changeset.py"

if ! declare -F graph_logs_resolve >/dev/null 2>&1; then
  # shellcheck source=graph-logs.sh
  source "$GRAPH_CHANGESET_SCRIPT_DIR/graph-logs.sh"
fi

graph_changeset_node_key() {
  graph_workspace_node_key "$1"
}

graph_changeset_stage_json() {
  local graph_json="$1" node_id="$2"
  jq -c --arg id "$node_id" '.nodes[] | select(.id == $id) | .stage' "$graph_json"
}

graph_changeset_is_mutating() {
  local graph_json="$1" node_id="$2"
  jq -e --arg id "$node_id" '
    .nodes[] | select(.id == $id) | (.stage.writeScopes // []) | length > 0
  ' "$graph_json" >/dev/null 2>&1
}

graph_changeset_baseline_path() {
  local run_dir="$1" node_id="$2" attempt_id="$3" key
  key="$(graph_changeset_node_key "$node_id")" || return 1
  printf '%s/changesets/baselines/%s/%s.json\n' "$run_dir" "$key" "$attempt_id"
}

graph_changeset_manifest_path() {
  local run_dir="$1" node_id="$2" key
  key="$(graph_changeset_node_key "$node_id")" || return 1
  printf '%s/changesets/nodes/%s.json\n' "$run_dir" "$key"
}

graph_changeset_capture_baseline() {
  local run_dir="$1" graph_json="$2" node_id="$3" attempt_id="$4" workspace="$5"
  local baseline
  graph_changeset_is_mutating "$graph_json" "$node_id" || return 0
  [[ -x "$GRAPH_CHANGESET_HELPER" || -f "$GRAPH_CHANGESET_HELPER" ]] || return 1
  baseline="$(graph_changeset_baseline_path "$run_dir" "$node_id" "$attempt_id")" || return 1
  python3 "$GRAPH_CHANGESET_HELPER" baseline \
    --workspace "$workspace" --output "$baseline" >/dev/null
}

graph_changeset_capture_node() {
  local run_dir="$1" graph_json="$2" node_id="$3" attempt_id="$4" workspace="$5" state_root="$6"
  local baseline output stage mode scopes base_identity usage_file usage_json=""
  local capture_args=()
  graph_changeset_is_mutating "$graph_json" "$node_id" || return 0
  baseline="$(graph_changeset_baseline_path "$run_dir" "$node_id" "$attempt_id")" || return 1
  output="$(graph_changeset_manifest_path "$run_dir" "$node_id")" || return 1
  [[ -f "$baseline" ]] || {
    echo "Error: changeset baseline missing for node $node_id attempt $attempt_id" >&2
    return 1
  }
  stage="$(graph_changeset_stage_json "$graph_json" "$node_id")" || return 1
  mode="$(printf '%s' "$stage" | jq -r '.workspaceMode // "shared"')"
  scopes="$(printf '%s' "$stage" | jq -c '.writeScopes // []')"
  base_identity="$(jq -r '.sourceBase.filesystemIdentity // .sourceBase.git.treeHash // "shared-optimistic"' "$run_dir/run.json")"
  local usage_rel
  usage_rel="$(graph_logs_attempt_rel "$run_dir" "$node_id" "$attempt_id" "usage.json" 2>/dev/null || true)"
  if [[ -n "$usage_rel" ]]; then
    usage_file="$(graph_logs_read "$run_dir" "$usage_rel" 2>/dev/null || true)"
  fi
  [[ -n "$usage_file" && -f "$usage_file" ]] && usage_json="$(jq -c . "$usage_file" 2>/dev/null || true)"
  capture_args=(
    capture --workspace "$workspace" --baseline "$baseline" --output "$output"
    --node-id "$node_id" --attempt-id "$attempt_id" --workspace-mode "$mode"
    --base-identity "$base_identity" --write-scopes-json "$scopes"
  )
  [[ -n "$usage_json" ]] && capture_args+=(--usage-json "$usage_json")
  python3 "$GRAPH_CHANGESET_HELPER" "${capture_args[@]}" >/dev/null
}
