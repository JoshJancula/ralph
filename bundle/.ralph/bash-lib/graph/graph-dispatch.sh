#!/usr/bin/env bash
# Out-of-process node dispatch for graph mode.
#
# Every graph node runs as a fresh orchestrator.sh --single-stage process.
# The in-process orch loop is intentionally never entered: routing baseline
# capture/restore is not re-entrant, and orch_stage_execute mutates globals.
#
# This library materializes a flat .orch.json from .graph.json (every node as a
# stage, no parallelStages), mints attempt ids, and builds/invokes the
# single-stage argument vector. StageOutcomeReport emission stays inside
# orchestrator.sh (atomic mktemp/jq/fsync/rename + EXIT trap).

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

GRAPH_DISPATCH_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRAPH_DISPATCH_RALPH_ROOT="$(cd "$GRAPH_DISPATCH_SCRIPT_DIR/../.." && pwd)"

# Populated by graph_dispatch_build_argv for callers that want to inspect or
# wrap the child invocation. bash 3.2-safe plain array (no namerefs).
GRAPH_DISPATCH_ARGV=()

# graph_dispatch_mint_attempt_id <node_id> <run_id> <attempt_number>
# Attempt ids are composed of the node id, run id, and attempt number so that
# retries never share a StageOutcomeReport path.
graph_dispatch_mint_attempt_id() {
  local node_id="$1"
  local run_id="$2"
  local attempt_number="$3"

  if [[ -z "$node_id" || -z "$run_id" || -z "$attempt_number" ]]; then
    echo "Error: graph_dispatch_mint_attempt_id requires node_id, run_id, and attempt_number" >&2
    return 1
  fi
  if [[ ! "$attempt_number" =~ ^[0-9]+$ ]]; then
    echo "Error: attempt_number must be a non-negative integer (got: $attempt_number)" >&2
    return 1
  fi

  printf '%s__%s__%s\n' "$node_id" "$run_id" "$attempt_number"
}

# graph_dispatch_report_path <workspace> <namespace> <attempt_id>
# Mirrors orch_single_stage_report_path so tests and the scheduler can locate
# the report without parsing orchestrator logs.
graph_dispatch_report_path() {
  local workspace="$1"
  local namespace="$2"
  local attempt_id="$3"
  local state_root="${RALPH_PLAN_WORKSPACE_ROOT:-$workspace/.ralph-workspace}"
  printf '%s/artifacts/%s/stage-outcomes/%s.json\n' \
    "$state_root" "$namespace" "$attempt_id"
}

# graph_dispatch_resolve_orchestrator [workspace]
# Prefers an explicit test/operator override, then the frozen graph tooling
# root, then the Ralph root that shipped this library.  Deliberately do not
# resolve tooling from an isolated node workspace: an agent may mutate that
# copy while it runs, but must never choose the supervisor's next executable.
graph_dispatch_resolve_orchestrator() {
  local workspace="${1:-}"
  if [[ -n "${GRAPH_DISPATCH_ORCHESTRATOR:-}" ]]; then
    printf '%s\n' "$GRAPH_DISPATCH_ORCHESTRATOR"
    return 0
  fi
  if [[ -n "${RALPH_GRAPH_TOOLING_ROOT:-}" \
    && -f "$RALPH_GRAPH_TOOLING_ROOT/orchestrator.sh" ]]; then
    printf '%s\n' "$RALPH_GRAPH_TOOLING_ROOT/orchestrator.sh"
    return 0
  fi
  printf '%s\n' "$GRAPH_DISPATCH_RALPH_ROOT/orchestrator.sh"
}

# Internal: render inline todos into a standalone standard plan (same shape as
# orch_render_inline_stage_plan in orchestrator.sh).
_graph_dispatch_render_inline_stage_plan() {
  local stage_id="$1" ns="$2" todos_json="$3" artifacts_json="${4:-[]}" state_root="${5:-}"
  python3 - "$stage_id" "$ns" "$todos_json" "$artifacts_json" "$state_root" <<'PYRENDER'
import json
import os
import sys

stage_id, ns, todos_json, artifacts_json, state_root = sys.argv[1:6]
todos = json.loads(todos_json) if todos_json else []
artifacts = json.loads(artifacts_json) if artifacts_json else []
if not todos:
    todos = [{"id": f"{stage_id}-task-1", "content": "Complete this stage.",
              "verification": "Confirm the stage is complete.", "status": "pending"}]


def block(text: str) -> str:
    lines = (text or "").splitlines() or [""]
    return "\n".join("      " + ln for ln in lines)


out = ["---", f"name: {ns}-{stage_id}", f"overview: Inline stage {stage_id}",
       "execution: standard", "instructions: Execute one TODO at a time.", "", "todos:"]
required_paths = []
for artifact in artifacts:
    path = artifact.get("path", "") if isinstance(artifact, dict) else str(artifact)
    if not path:
        continue
    path = path.replace("{{ARTIFACT_NS}}", ns).replace("{{STAGE_ID}}", stage_id.replace(":", "_"))
    if path.startswith(".ralph-workspace/") and state_root:
        path = os.path.join(state_root, path[len(".ralph-workspace/"):])
    if path not in required_paths:
        required_paths.append(path)

for index, todo in enumerate(todos):
    content = todo.get("content", "")
    if index == len(todos) - 1 and required_paths:
        content += "\n\nRequired output artifacts (write each exact path):\n" + "\n".join(
            f"- {path}" for path in required_paths
        )
    out.append(f"  - id: {todo.get('id') or stage_id + '-task'}")
    out.append("    content: |")
    out.append(block(content))
    out.append("    verification: |")
    out.append(block(todo.get("verification", "")))
    out.append(f"    status: {todo.get('status') or 'pending'}")
out += ["isProject: false", "---"]
print("\n".join(out))
PYRENDER
}

# graph_dispatch_materialize_orch <graph_json_path> <workspace> [out_orch_path] [plan_root]
#
# Builds a flat .orch.json from .graph.json: one stage per node (the nested
# stage object already byte-compatible with build_orch_stage), no
# parallelStages. Expands _inlineTodos into orchestration plan files so the
# legacy JSON path in orchestrator.sh can consume the result with zero
# executor changes. Prints the orch path on stdout.
graph_dispatch_materialize_orch() {
  local graph_json_path="$1"
  local workspace="$2"
  local out_orch_path="${3:-}"
  local plan_root="${4:-$workspace}"

  if [[ ! -f "$graph_json_path" ]]; then
    echo "Error: graph json not found: $graph_json_path" >&2
    return 1
  fi
  if [[ -z "$workspace" || ! -d "$workspace" ]]; then
    echo "Error: workspace directory required for orch materialization" >&2
    return 1
  fi
  if [[ -z "$plan_root" || ! -d "$plan_root" ]]; then
    echo "Error: plan materialization root required for graph dispatch" >&2
    return 1
  fi
  plan_root="$(cd "$plan_root" && pwd -P)" || return 1
  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required to materialize flat .orch.json" >&2
    return 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: python3 is required to materialize inline stage plans" >&2
    return 1
  fi
  if ! jq empty "$graph_json_path" 2>/dev/null; then
    echo "Error: invalid graph json: $graph_json_path" >&2
    return 1
  fi

  local name namespace stage_count
  name="$(jq -r '.name // empty' "$graph_json_path")"
  namespace="$(jq -r '.namespace // empty' "$graph_json_path")"
  if [[ -z "$namespace" ]]; then
    namespace="$(basename "$graph_json_path" .graph.json)"
    namespace="${namespace%.json}"
  fi
  if [[ -z "$name" ]]; then
    name="$namespace"
  fi

  stage_count="$(jq '.nodes | length' "$graph_json_path")"
  if [[ -z "$stage_count" || "$stage_count" -eq 0 ]]; then
    echo "Error: graph has no nodes to materialize: $graph_json_path" >&2
    return 1
  fi

  local orch_dir
  orch_dir="$plan_root/orchestration-plans/$namespace"
  mkdir -p "$orch_dir"

  if [[ -z "$out_orch_path" ]]; then
    out_orch_path="$orch_dir/${namespace}.orch.json"
  fi
  mkdir -p "$(dirname "$out_orch_path")"

  # Flat orch: every node stage, never parallelStages. Keep key order stable for
  # characterization; drop parallelStages explicitly even if a future graph
  # emitter adds one.
  local orch_json
  orch_json="$(jq -c --arg name "$name" --arg ns "$namespace" '
      {
        name: $name,
        namespace: $ns,
        stages: [.nodes[].stage]
      }
      + (if (.ralphMode // "") != "" then {ralphMode: .ralphMode} else {} end)
      | del(.parallelStages)
    ' "$graph_json_path")" || {
    echo "Error: failed to project stages from graph json" >&2
    return 1
  }

  local i sid todos artifacts state_root plan_rel plan_abs plan_value
  state_root="${RALPH_PLAN_WORKSPACE_ROOT:-$workspace/.ralph-workspace}"
  for ((i = 0; i < stage_count; i++)); do
    if [[ "$(printf '%s' "$orch_json" | jq -r ".stages[$i] | has(\"_inlineTodos\")")" != "true" ]]; then
      continue
    fi
    sid="$(printf '%s' "$orch_json" | jq -r ".stages[$i].id // \"stage\"")"
    todos="$(printf '%s' "$orch_json" | jq -c ".stages[$i]._inlineTodos")"
    artifacts="$(printf '%s' "$orch_json" | jq -c ".stages[$i] | [(.artifacts // [])[], (.outputArtifacts // [])[]] | unique_by(.path)")"
    plan_rel=".ralph-workspace/orchestration-plans/$namespace/$(printf '%s-%02d-%s.plan.md' "$namespace" "$((i + 1))" "$sid")"
    plan_abs="$orch_dir/$(printf '%s-%02d-%s.plan.md' "$namespace" "$((i + 1))" "$sid")"
    mkdir -p "$(dirname "$plan_abs")"
    _graph_dispatch_render_inline_stage_plan "$sid" "$namespace" "$todos" "$artifacts" "$state_root" > "$plan_abs" || {
      echo "Error: failed to render inline plan for stage $sid" >&2
      return 1
    }
    plan_value="$plan_rel"
    if [[ "$plan_root" != "$workspace" ]]; then
      plan_value="$plan_abs"
    fi
    orch_json="$(printf '%s' "$orch_json" | jq -c --arg p "$plan_value" \
      "(.stages[$i].plan) = \$p | del(.stages[$i]._inlineTodos)")" || {
      echo "Error: failed to attach plan path for stage $sid" >&2
      return 1
    }
  done

  if printf '%s\n' "$orch_json" | jq 'has("parallelStages")' | grep -q true; then
    echo "Error: materialized orch must not carry parallelStages" >&2
    return 1
  fi

  # Atomic write: temp in the destination dir, then rename.
  local tmp
  tmp="$(mktemp "$orch_dir/.orch-XXXXXX")" || return 1
  if ! printf '%s\n' "$orch_json" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! mv -f "$tmp" "$out_orch_path"; then
    rm -f "$tmp"
    return 1
  fi

  printf '%s\n' "$out_orch_path"
  return 0
}

# graph_dispatch_build_argv <orch_path> <node_id> <run_id> <attempt_id>
#   <workspace> [state_root]
# Fills GRAPH_DISPATCH_ARGV with the single-stage orchestrator invocation.
graph_dispatch_build_argv() {
  local orch_path="$1"
  local node_id="$2"
  local run_id="$3"
  local attempt_id="$4"
  local workspace="$5"
  local state_root="${6:-$workspace/.ralph-workspace}"
  local orchestrator

  if [[ -z "$orch_path" || -z "$node_id" || -z "$run_id" || -z "$attempt_id" || -z "$workspace" ]]; then
    echo "Error: graph_dispatch_build_argv requires orch_path, node_id, run_id, attempt_id, workspace" >&2
    return 1
  fi

  orchestrator="$(graph_dispatch_resolve_orchestrator "$workspace")"
  if [[ ! -f "$orchestrator" ]]; then
    echo "Error: orchestrator not found: $orchestrator" >&2
    return 1
  fi

  GRAPH_DISPATCH_ARGV=(
    bash "$orchestrator"
    --orchestration "$orch_path"
    --single-stage "$node_id"
    --run-id "$run_id"
    --attempt-id "$attempt_id"
    --workspace-root "$state_root"
    "$workspace"
  )
  return 0
}

# graph_dispatch_run_node <graph_json_path> <node_id> <run_id> <attempt_number> <workspace>
#
# Materializes the flat orch (idempotent), mints an attempt id, and invokes
# orchestrator.sh as a fresh process. Prints the attempt id on stdout. The
# StageOutcomeReport lands at graph_dispatch_report_path for that attempt.
graph_dispatch_run_node() {
  local graph_json_path="$1"
  local node_id="$2"
  local run_id="$3"
  local attempt_number="$4"
  local workspace="$5"

  local orch_path attempt_id namespace rc

  orch_path="$(graph_dispatch_materialize_orch "$graph_json_path" "$workspace")" || return 1
  attempt_id="$(graph_dispatch_mint_attempt_id "$node_id" "$run_id" "$attempt_number")" || return 1
  graph_dispatch_build_argv "$orch_path" "$node_id" "$run_id" "$attempt_id" "$workspace" || return 1

  namespace="$(jq -r '.namespace // empty' "$orch_path")"
  [[ -n "$namespace" ]] || namespace="$(basename "$orch_path" .orch.json)"

  rc=0
  # Graph mode is an intentional out-of-process nest of orchestrator.sh under
  # the scheduler (and often under a managed Ralph session). Opt the child in
  # without mutating the caller's environment.
  RALPH_ALLOW_NESTED_RUNS=1 "${GRAPH_DISPATCH_ARGV[@]}" || rc=$?

  # Always surface the attempt id so callers can locate the report even when
  # the child exits non-zero (failed/cancelled reports are still written).
  printf '%s\n' "$attempt_id"
  return "$rc"
}
