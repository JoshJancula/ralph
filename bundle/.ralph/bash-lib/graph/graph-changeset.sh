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

# graph_changeset_needs_rework_seed <graph-json> <node-id>
# True for rework-derived or QA-repair implement clones that name a seed via
# candidateFrom. Evaluators (no writeScopes) are not seeded; they materialize
# a private copy of the candidate instead.
graph_changeset_needs_rework_seed() {
  local graph_json="$1" node_id="$2"
  jq -e --arg id "$node_id" '
    .nodes[] | select(.id == $id) |
    ((.stage.writeScopes // []) | length) > 0
    and ((.stage.seedFrom // "") != "")
  ' "$graph_json" >/dev/null 2>&1
}

# graph_changeset_seed_rework_node <run-dir> <graph-json> <node-id> <attempt-id> <workspace>
# After baseline capture and before dispatch, apply the seed candidate's
# changeset so the new attempt's captured delta is cumulative against the run
# base. Prints seededFrom JSON ({nodeId, attemptId, identity}) or "null".
graph_changeset_seed_rework_node() {
  local run_dir="$1" graph_json="$2" node_id="$3" attempt_id="$4" workspace="$5"
  local seed_id seed_key seed_safe seed_node seed_manifest seed_attempt seed_identity seed_type source_id
  local base_identity integrate_helper output conflict
  local -a manifest_args=()
  if ! graph_changeset_needs_rework_seed "$graph_json" "$node_id"; then
    printf 'null\n'
    return 0
  fi
  seed_id="$(jq -r --arg id "$node_id" \
    '.nodes[] | select(.id == $id) | .stage.seedFrom // empty' "$graph_json")"
  [[ -n "$seed_id" ]] || {
    echo "Error: rework seed missing seedFrom for $node_id" >&2
    return 1
  }
  seed_safe="$(printf '%s' "$seed_id" | sed 's/[^A-Za-z0-9._-]/_/g')"
  seed_node="$run_dir/nodes/$seed_safe.json"
  [[ -f "$seed_node" && "$(jq -r '.status // empty' "$seed_node")" == "succeeded" ]] || {
    echo "Error: candidate-missing: $node_id requires succeeded seed candidate $seed_id" >&2
    return 1
  }
  seed_key="$(graph_changeset_node_key "$seed_id")" || return 1
  seed_type="$(jq -r --arg id "$seed_id" '.nodes[] | select(.id == $id) | .type // empty' "$graph_json")"
  if [[ "$seed_type" == "integrate" ]]; then
    # An integrated candidate has no node changeset of its own; it is the
    # run base plus its integration sources' cumulative changesets.
    if ! declare -F graph_integration_source_node_ids >/dev/null 2>&1; then
      # shellcheck source=graph-integration.sh
      source "$GRAPH_CHANGESET_RALPH_ROOT/bash-lib/graph/graph-integration.sh"
    fi
    while IFS= read -r source_id || [[ -n "$source_id" ]]; do
      [[ -n "$source_id" ]] || continue
      seed_manifest="$(graph_changeset_manifest_path "$run_dir" "$source_id")" || return 1
      [[ -f "$seed_manifest" ]] || {
        echo "Error: candidate-missing: seed changeset for $source_id (via $seed_id) is missing" >&2
        return 1
      }
      manifest_args+=(--manifest "$seed_manifest")
    done < <(graph_integration_source_node_ids "$run_dir" "$graph_json" "$seed_id")
    [[ ${#manifest_args[@]} -gt 0 ]] || {
      echo "Error: candidate-missing: integrated seed $seed_id has no source changesets" >&2
      return 1
    }
  else
    seed_manifest="$(graph_changeset_manifest_path "$run_dir" "$seed_id")" || return 1
    [[ -f "$seed_manifest" ]] || {
      echo "Error: candidate-missing: seed changeset for $seed_id is missing" >&2
      return 1
    }
    manifest_args=(--manifest "$seed_manifest")
  fi
  base_identity="$(jq -r '.sourceBase.filesystemIdentity // .sourceBase.git.treeHash // empty' "$run_dir/run.json")"
  [[ -n "$base_identity" ]] || {
    echo "Error: rework seed requires an immutable run base identity" >&2
    return 1
  }
  integrate_helper="$GRAPH_CHANGESET_RALPH_ROOT/python/graph_integrate.py"
  [[ -f "$integrate_helper" ]] || return 1
  output="$(mktemp "${TMPDIR:-/tmp}/ralph-rework-seed.XXXXXX.json")" || return 1
  conflict="$(mktemp "${TMPDIR:-/tmp}/ralph-rework-seed-conflict.XXXXXX.json")" || {
    rm -f "$output"
    return 1
  }
  if ! python3 "$integrate_helper" \
    --workspace "$workspace" \
    --output "$output" \
    --conflict-output "$conflict" \
    --node-id "$node_id" \
    --base-identity "$base_identity" \
    "${manifest_args[@]}" >/dev/null; then
    echo "Error: failed to apply rework seed changeset from $seed_id into $node_id" >&2
    rm -f "$output" "$conflict"
    return 1
  fi
  rm -f "$output" "$conflict"
  seed_attempt="$(jq -r '.lastAttemptId // .attempts[-1].attemptId // empty' "$seed_node")"
  seed_identity="$(jq -r \
    '.candidateIdentity // .attempts[-1].candidateIdentity // empty' "$seed_node")"
  if [[ -z "$seed_identity" ]]; then
    seed_identity="$(jq -r '.resultIdentity // .contentIdentity // empty' "$seed_manifest")"
  fi
  jq -cn \
    --arg nodeId "$seed_id" \
    --arg attemptId "${seed_attempt:-}" \
    --arg identity "${seed_identity:-}" \
    '{
       nodeId: $nodeId,
       attemptId: (if $attemptId == "" then null else $attemptId end),
       identity: (if $identity == "" then null else $identity end)
     }'
}
