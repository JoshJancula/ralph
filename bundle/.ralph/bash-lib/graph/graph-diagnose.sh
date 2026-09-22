#!/usr/bin/env bash
# Deterministic-first gate-failure diagnosis and repair-lane feedback routing
# Maps a gate node's gate-result.json to owning write
# scopes/repair lanes declared inside a repairRounds round, escalating to a
# delegation-disabled router/diagnostic agent only when a finding's files
# match more than one lane's writeScopes.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

GRAPH_DIAGNOSE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRAPH_DIAGNOSE_RALPH_ROOT="$(cd "$GRAPH_DIAGNOSE_SCRIPT_DIR/../.." && pwd)"
GRAPH_DIAGNOSE_HELPER="$GRAPH_DIAGNOSE_RALPH_ROOT/python/graph_diagnose.py"

# graph_diagnose_result_path <state_root> <namespace> <diagnose_node_id>
graph_diagnose_result_path() {
  local state_root="$1" namespace="$2" node_id="$3"
  printf '%s/artifacts/%s/diagnose/%s/diagnosis.json\n' \
    "$state_root" "$namespace" "$(printf '%s' "$node_id" | sed 's|[^A-Za-z0-9_.-]|_|g')"
}

# graph_diagnose_gate_result_path <state_root> <namespace> <gate_node_id>
graph_diagnose_gate_result_path() {
  local state_root="$1" namespace="$2" gate_node_id="$3"
  printf '%s/artifacts/%s/gate/%s/gate-result.json\n' \
    "$state_root" "$namespace" "$(printf '%s' "$gate_node_id" | sed 's|[^A-Za-z0-9_.-]|_|g')"
}

# graph_diagnose_lanes_json <graph_json> <diagnose_node_id>
# Prints [{"id": <lane node id>, "writeScopes": [...]}] for every repair-lane
# node whose dependsOn names this diagnose node, derived from the frozen
# graph rather than re-parsing plan authoring input.
graph_diagnose_lanes_json() {
  local graph_json="$1" diagnose_node_id="$2"
  jq -c --arg diag "$diagnose_node_id" '
    [.nodes[] | select((.dependsOn // []) | index($diag)) | select(.id | test("-repair-"))
     | {id: .id, writeScopes: (.stage.writeScopes // [])}]
  ' "$graph_json"
}

# graph_diagnose_changeset_paths <run_dir>
# Prints every captured changeset manifest path under the run's ledger, best
# effort (an epoch's entry integrate node may have no mutating predecessors).
graph_diagnose_changeset_paths() {
  local run_dir="$1"
  [[ -d "$run_dir/changesets/nodes" ]] || return 0
  find "$run_dir/changesets/nodes" -type f -name '*.json' 2>/dev/null
}

# graph_diagnose_run <diagnose_node_id> <gate_node_id> <graph_json> <state_root> <namespace> <run_dir>
# Runs deterministic-first diagnosis for a repair round. Returns:
#   0  every finding resolved deterministically (or has no owner)
#   2  at least one finding is ambiguous and needs router resolution
#   1  error (bad gate-result, missing lanes, etc.)
graph_diagnose_run() {
  local diagnose_node_id="$1" gate_node_id="$2" graph_json="$3" state_root="$4" namespace="$5" run_dir="$6"
  local gate_result lanes_json output rc=0
  gate_result="$(graph_diagnose_gate_result_path "$state_root" "$namespace" "$gate_node_id")"
  if [[ ! -f "$gate_result" ]]; then
    echo "Error: graph-diagnose: gate-result.json not found: $gate_result" >&2
    return 1
  fi
  lanes_json="$(graph_diagnose_lanes_json "$graph_json" "$diagnose_node_id")"
  if [[ "$(printf '%s' "$lanes_json" | jq 'length')" -eq 0 ]]; then
    echo "Error: graph-diagnose: no repair lanes found depending on $diagnose_node_id" >&2
    return 1
  fi
  output="$(graph_diagnose_result_path "$state_root" "$namespace" "$diagnose_node_id")"
  mkdir -p "$(dirname "$output")"

  local -a changeset_args=()
  local cs_path
  while IFS= read -r cs_path; do
    [[ -n "$cs_path" ]] && changeset_args+=("$cs_path")
  done < <(graph_diagnose_changeset_paths "$run_dir")

  python3 "$GRAPH_DIAGNOSE_HELPER" analyze \
    --gate-result "$gate_result" --lanes-json "$lanes_json" \
    --log-root "$state_root" --output "$output" \
    ${changeset_args[@]+--changeset-paths "${changeset_args[@]}"} >/dev/null || rc=$?
  return "$rc"
}

# graph_diagnose_apply_router <diagnose_node_id> <graph_json> <state_root> <namespace> <decision_path>
# Merges a delegation-disabled router/diagnostic agent's decision (an
# ordinary node artifact, never a live nested invocation) into the existing
# diagnosis.json. Returns 0 when every finding is now resolved, 2 if any
# finding remains ambiguous, 1 on error.
graph_diagnose_apply_router() {
  local diagnose_node_id="$1" graph_json="$2" state_root="$3" namespace="$4" decision_path="$5"
  local diagnosis lanes_json rc=0
  diagnosis="$(graph_diagnose_result_path "$state_root" "$namespace" "$diagnose_node_id")"
  if [[ ! -f "$diagnosis" ]]; then
    echo "Error: graph-diagnose: diagnosis.json not found: $diagnosis" >&2
    return 1
  fi
  if [[ ! -f "$decision_path" ]]; then
    echo "Error: graph-diagnose: router decision not found: $decision_path" >&2
    return 1
  fi
  lanes_json="$(graph_diagnose_lanes_json "$graph_json" "$diagnose_node_id")"
  python3 "$GRAPH_DIAGNOSE_HELPER" apply-router \
    --diagnosis "$diagnosis" --decision "$decision_path" \
    --lanes-json "$lanes_json" --output "$diagnosis" >/dev/null || rc=$?
  return "$rc"
}
