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
# JSON path in orchestrator.sh can consume the result with zero
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
  # .nodes[].stage may carry graph-only loopCheck metadata (the scheduler's
  # rework verdict gate, set at graph compile time). That field is not part
  # of the orchestrator v1 stage surface, so strip it while projecting graph
  # stages into the temporary flat .orch.json.
  orch_json="$(jq -c --arg name "$name" --arg ns "$namespace" '
      {
        name: $name,
        namespace: $ns,
        stages: [.nodes[].stage | del(.loopCheck)]
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
    # planFrom / provided-plan consumers bind a registry control copy at
    # dispatch; never materialize a placeholder inline plan for them.
    if [[ "$(printf '%s' "$orch_json" | jq -r ".stages[$i] | has(\"planFrom\")")" == "true" ]]; then
      orch_json="$(printf '%s' "$orch_json" | jq -c "del(.stages[$i]._inlineTodos)")" || {
        echo "Error: failed to strip inline todos from planFrom stage" >&2
        return 1
      }
      continue
    fi
    sid="$(printf '%s' "$orch_json" | jq -r ".stages[$i].id // empty")"
    if [[ -n "$sid" ]] && [[ "$(jq -r --arg id "$sid" '
        .nodes[]? | select(.id == $id) | .planInputBinding.planSourceKind // empty
      ' "$graph_json_path" 2>/dev/null)" == "provided" ]]; then
      orch_json="$(printf '%s' "$orch_json" | jq -c "del(.stages[$i]._inlineTodos) | del(.stages[$i].plan)")" || {
        echo "Error: failed to strip inline todos from provided-plan stage" >&2
        return 1
      }
      continue
    fi
    if [[ "$(printf '%s' "$orch_json" | jq -r ".stages[$i] | has(\"_inlineTodos\")")" != "true" ]]; then
      continue
    fi
    sid="$(printf '%s' "$orch_json" | jq -r ".stages[$i].id // \"stage\"")"
    todos="$(printf '%s' "$orch_json" | jq -c ".stages[$i]._inlineTodos")"
    artifacts="$(printf '%s' "$orch_json" | jq -c ".stages[$i] | [(.artifacts // [])[], (.outputArtifacts // [])[]] | unique_by(.path)")"
    plan_rel=".ralph-workspace/orchestration-plans/$namespace/$(printf '%s-%02d-%s.plan.md' "$namespace" "$((i + 1))" "$sid")"
    plan_abs="$orch_dir/$(printf '%s-%02d-%s.plan.md' "$namespace" "$((i + 1))" "$sid")"
    mkdir -p "$(dirname "$plan_abs")"
    # Idempotent creation only: a rework node's rendered plan may already carry
    # injected evaluator feedback (see _graph_dispatch_inject_rework_feedback)
    # or completed TODO status from a prior dispatch. Re-rendering it every
    # time any node in the graph is materialized would silently discard that
    # state. Only create the plan when it does not already exist, and do so
    # atomically (render to a sibling temp file, then rename-without-clobber)
    # so a concurrent materializer never overwrites a plan another process
    # just created.
    if [[ ! -f "$plan_abs" ]]; then
      local plan_tmp
      plan_tmp="$(mktemp "$(dirname "$plan_abs")/.plan-XXXXXX")" || {
        echo "Error: failed to create temp file for inline plan for stage $sid" >&2
        return 1
      }
      if ! _graph_dispatch_render_inline_stage_plan "$sid" "$namespace" "$todos" "$artifacts" "$state_root" > "$plan_tmp"; then
        rm -f "$plan_tmp"
        echo "Error: failed to render inline plan for stage $sid" >&2
        return 1
      fi
      if ! mv -n "$plan_tmp" "$plan_abs" 2>/dev/null; then
        # Lost the race to another materializer; discard ours and keep the
        # plan that is already on disk.
        rm -f "$plan_tmp"
      fi
    fi
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
#
# Fills GRAPH_DISPATCH_ARGV with the single-stage orchestrator invocation.
#
# G12: before dispatch, this function sets and passes absolute values for
# RALPH_PROJECT_ROOT, RALPH_PLAN_WORKSPACE_ROOT, RALPH_AGENT_WORKSPACE, and
# RALPH_ARTIFACT_ROOT=<state-root>/artifacts/<namespace> as an explicit
# `env` prefix on the child argv -- never relying only on ambient shell
# inheritance from the caller. An already-exported RALPH_PROJECT_ROOT in
# this process's own environment wins (the scheduler may have set a more
# specific project identity root); otherwise it defaults to the isolated
# node workspace. agent_workspace, by contrast, is ALWAYS this call's own
# <workspace> argument -- the isolated node workspace itself -- and must
# never fall back to reading RALPH_AGENT_WORKSPACE from the ambient
# environment: graph-run.sh's own top-level `run`/`resume` handlers export
# that same name pointing at the caller's real (unisolated) project root
# for the whole scheduler process lifetime, and this function is normally
# invoked from that same process before any per-node override is exported.
# An ambient-wins fallback for agent_workspace would silently hand every
# node's agent the live project root instead of its snapshot/worktree,
# defeating workspace isolation for every node. The state root defaults to
# the resolved <state_root> argument. Required outputs therefore always
# resolve to the supervisor's state root while source edits stay confined
# to the isolated agent workspace.
#
# When the compiled stage on the materialized flat .orch.json declares
# toolingProfile, append the resolved KEY=VALUE lines from
# ralph_tooling_profile_env as additional env-prefix entries (after the
# four G12 roots, before the orchestrator command). Profile keys that
# collide with those supervisor-owned roots are skipped; profile values
# still override ambient inheritance for the child because the env prefix
# is per-process. Nothing is exported into the scheduler's own environment.
graph_dispatch_build_argv() {
  local orch_path="$1"
  local node_id="$2"
  local run_id="$3"
  local attempt_id="$4"
  local workspace="$5"
  local state_root="${6:-$workspace/.ralph-workspace}"
  local orchestrator namespace project_root agent_workspace artifact_root
  local tooling_profile="" node_runtime="" profile_env=()

  if [[ -z "$orch_path" || -z "$node_id" || -z "$run_id" || -z "$attempt_id" || -z "$workspace" ]]; then
    echo "Error: graph_dispatch_build_argv requires orch_path, node_id, run_id, attempt_id, workspace" >&2
    return 1
  fi

  orchestrator="$(graph_dispatch_resolve_orchestrator "$workspace")"
  if [[ ! -f "$orchestrator" ]]; then
    echo "Error: orchestrator not found: $orchestrator" >&2
    return 1
  fi

  namespace=""
  if command -v jq >/dev/null 2>&1 && [[ -f "$orch_path" ]]; then
    namespace="$(jq -r '.namespace // empty' "$orch_path" 2>/dev/null)"
  fi
  [[ -n "$namespace" ]] || namespace="$(basename "$orch_path" .orch.json)"

  project_root="${RALPH_PROJECT_ROOT:-$workspace}"
  agent_workspace="$workspace"
  artifact_root="${state_root%/}/artifacts/${namespace}"

  if command -v jq >/dev/null 2>&1 && [[ -f "$orch_path" ]]; then
    tooling_profile="$(jq -r --arg id "$node_id" '
      .stages[] | select(.id == $id) | .toolingProfile // empty
    ' "$orch_path" 2>/dev/null)"
    node_runtime="$(jq -r --arg id "$node_id" '
      .stages[] | select(.id == $id) | .runtime // empty
    ' "$orch_path" 2>/dev/null)"
  fi

  if [[ -n "$tooling_profile" ]]; then
    if ! declare -F ralph_tooling_profile_env >/dev/null 2>&1; then
      # shellcheck source=../tooling-profile.sh
      source "$GRAPH_DISPATCH_RALPH_ROOT/bash-lib/tooling-profile.sh"
    fi
    local line key existing skip profile_lines
    profile_lines="$(ralph_tooling_profile_env "$tooling_profile" "$node_runtime")" || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -n "$line" ]] || continue
      key="${line%%=*}"
      skip=0
      for existing in \
        "RALPH_PROJECT_ROOT=${project_root}" \
        "RALPH_PLAN_WORKSPACE_ROOT=${state_root}" \
        "RALPH_AGENT_WORKSPACE=${agent_workspace}" \
        "RALPH_ARTIFACT_ROOT=${artifact_root}"; do
        if [[ "${existing%%=*}" == "$key" ]]; then
          skip=1
          break
        fi
      done
      [[ "$skip" -eq 1 ]] && continue
      profile_env+=("$line")
    done <<< "$profile_lines"
  fi

  # Strip retired split-knob env vars from the child. Parent Ralph/Cursor
  # sessions still export them as compatibility shims; run-plan refuses them
  # once RALPH_MODE is the sole control plane. Clearing here keeps nested
  # graph/workflow shakeouts (and toolingProfile RALPH_MODE overlays) from
  # inheriting a hard failure.
  local -a workflow_env=()
  local workflow_attempt=""
  if [[ "$attempt_id" =~ __([1-9][0-9]*)$ ]]; then
    workflow_attempt="${BASH_REMATCH[1]}"
  fi
  [[ -n "${RALPH_WORKFLOW_REGISTRY_RUN:-}" ]] \
    && workflow_env+=("RALPH_WORKFLOW_REGISTRY_RUN=${RALPH_WORKFLOW_REGISTRY_RUN}")
  [[ -n "${RALPH_WORKFLOW_RUN_ID:-}" ]] \
    && workflow_env+=("RALPH_WORKFLOW_RUN_ID=${RALPH_WORKFLOW_RUN_ID}")
  # Planner publication freezes generated input under the graph attempt that
  # produced it. Without this projection the single-stage orchestrator falls
  # back to attempt 1 on every graph retry, while planFrom validation correctly
  # asks for the latest graph attempt's manifest.
  [[ -n "${RALPH_WORKFLOW_REGISTRY_RUN:-}" && -n "$workflow_attempt" ]] \
    && workflow_env+=("RALPH_WORKFLOW_STAGE_ATTEMPT=${workflow_attempt}")
  [[ -n "${RALPH_ARTIFACT_NS:-}" ]] \
    && workflow_env+=("RALPH_ARTIFACT_NS=${RALPH_ARTIFACT_NS}")

  GRAPH_DISPATCH_ARGV=(
    env
    -u RALPH_AGENT_TOOL_ACCESS
    -u RALPH_NATIVE_HOOKS
    "RALPH_PROJECT_ROOT=${project_root}"
    "RALPH_PLAN_WORKSPACE_ROOT=${state_root}"
    "RALPH_AGENT_WORKSPACE=${agent_workspace}"
    "RALPH_ARTIFACT_ROOT=${artifact_root}"
    "${workflow_env[@]+"${workflow_env[@]}"}"
    "${profile_env[@]+"${profile_env[@]}"}"
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

# graph_dispatch_node_planfrom_id <graph_json_path> <node_id>
# Prints the frozen planner stage id for a planFrom consumer, or empty.
graph_dispatch_node_planfrom_id() {
  local graph_json_path="$1" node_id="$2"
  jq -r --arg id "$node_id" '
    .nodes[] | select(.id == $id) |
    (.planFromBinding.plannerStageId // .stage.planFrom // empty)
  ' "$graph_json_path" 2>/dev/null
}

# graph_dispatch_apply_planfrom_to_orch <orch_path> <node_id> <control_plan_path>
#
# Sets the projected single-stage orchestration plan field to the control
# copy, removes planFrom (mutex with plan), and preserves sessionStrategy /
# runtime / model routing already on the stage.
graph_dispatch_apply_planfrom_to_orch() {
  local orch_path="$1" node_id="$2" control_plan="$3"
  local tmp
  [[ -f "$orch_path" && -n "$node_id" && -n "$control_plan" ]] || {
    echo "Error: graph_dispatch_apply_planfrom_to_orch requires orch_path, node_id, control_plan" >&2
    return 1
  }
  tmp="$(mktemp "$(dirname "$orch_path")/.orch-planfrom-XXXXXX")" || return 1
  if ! jq --arg id "$node_id" --arg plan "$control_plan" '
      (.stages[] | select(.id == $id)) |= (
        .plan = $plan
        | del(.planFrom)
        | if ((.sessionStrategy // "") == "") then .sessionStrategy = "fresh" else . end
      )
    ' "$orch_path" >"$tmp"; then
    rm -f "$tmp"
    echo "Error: failed to project planFrom control plan onto orch stage $node_id" >&2
    return 1
  fi
  mv -f "$tmp" "$orch_path" || {
    rm -f "$tmp"
    return 1
  }
  return 0
}

# graph_dispatch_bind_planfrom_control --graph-json ... --node-id ... --orch-path ...
#   --registry-run ... --attempt-number N [--plan-run-id ...]
#   [--planner-attempt ...] [--force-fresh]
#   [--graph-workspace ...] [--namespace ...] [--run-id ...]
#
# First-dispatch / resume binder for ordinary planFrom consumers, and fresh
# bind for generated-plan rework clones (--force-fresh). Validates planner
# evidence, creates or reuses the control copy, projects the orch plan field,
# and prints the binding JSON. Missing/invalid/stale evidence fails before the
# caller admits a workspace/runtime.
graph_dispatch_bind_planfrom_control() {
  local graph_json="" node_id="" orch_path="" registry_run="" attempt_number=""
  local plan_run_id="" graph_workspace="" namespace="" run_id="" planner_attempt=""
  local force_fresh=0
  local planner_id binding bind_args=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --graph-json) graph_json="${2:-}"; shift 2 ;;
      --node-id) node_id="${2:-}"; shift 2 ;;
      --orch-path) orch_path="${2:-}"; shift 2 ;;
      --registry-run) registry_run="${2:-}"; shift 2 ;;
      --attempt-number) attempt_number="${2:-}"; shift 2 ;;
      --plan-run-id) plan_run_id="${2:-}"; shift 2 ;;
      --planner-attempt) planner_attempt="${2:-}"; shift 2 ;;
      --force-fresh) force_fresh=1; shift ;;
      --graph-workspace) graph_workspace="${2:-}"; shift 2 ;;
      --namespace) namespace="${2:-}"; shift 2 ;;
      --run-id) run_id="${2:-}"; shift 2 ;;
      *)
        echo "Error: unknown graph_dispatch_bind_planfrom_control argument: $1" >&2
        return 1
        ;;
    esac
  done

  [[ -n "$graph_json" && -n "$node_id" && -n "$orch_path" && -n "$registry_run" && -n "$attempt_number" ]] || {
    echo "Error: graph_dispatch_bind_planfrom_control requires --graph-json --node-id --orch-path --registry-run --attempt-number" >&2
    return 1
  }

  planner_id="$(graph_dispatch_node_planfrom_id "$graph_json" "$node_id")"
  [[ -n "$planner_id" ]] || {
    echo "Error: node $node_id has no frozen planFrom planner binding" >&2
    return 1
  }

  if ! declare -F workflow_state_bind_generated_plan_control >/dev/null 2>&1; then
    # shellcheck source=../workflow/workflow-state.sh
    source "$GRAPH_DISPATCH_RALPH_ROOT/bash-lib/workflow/workflow-state.sh"
  fi

  bind_args=(
    --registry-run "$registry_run"
    --consumer-stage-id "$node_id"
    --consumer-attempt "$attempt_number"
    --planner-stage-id "$planner_id"
  )
  [[ -n "$plan_run_id" ]] && bind_args+=(--plan-run-id "$plan_run_id")
  [[ -n "$planner_attempt" ]] && bind_args+=(--planner-attempt "$planner_attempt")
  [[ "$force_fresh" -eq 1 ]] && bind_args+=(--force-fresh)
  if [[ -n "$graph_workspace" && -n "$namespace" && -n "$run_id" ]]; then
    bind_args+=(--graph-workspace "$graph_workspace" --namespace "$namespace" --run-id "$run_id")
  fi

  binding="$(workflow_state_bind_generated_plan_control "${bind_args[@]}")" || return 1
  graph_dispatch_apply_planfrom_to_orch "$orch_path" "$node_id" \
    "$(printf '%s' "$binding" | jq -r '.controlPlanPath')" || return 1
  printf '%s\n' "$binding"
}

# graph_dispatch_node_provided_plan_kind <graph_json_path> <node_id>
# Prints "provided" when the node carries a frozen planInputBinding, else empty.
graph_dispatch_node_provided_plan_kind() {
  local graph_json_path="$1" node_id="$2"
  jq -r --arg id "$node_id" '
    .nodes[] | select(.id == $id) |
    (.planInputBinding.planSourceKind // empty)
  ' "$graph_json_path" 2>/dev/null
}

# graph_dispatch_apply_provided_to_orch <orch_path> <node_id> <control_plan_path>
#
# Same projection as planFrom: set stage.plan to the control copy and force
# sessionStrategy=fresh when absent. Preserves stage/invocation runtime/model.
graph_dispatch_apply_provided_to_orch() {
  local orch_path="$1" node_id="$2" control_plan="$3"
  local tmp
  [[ -f "$orch_path" && -n "$node_id" && -n "$control_plan" ]] || {
    echo "Error: graph_dispatch_apply_provided_to_orch requires orch_path, node_id, control_plan" >&2
    return 1
  }
  tmp="$(mktemp "$(dirname "$orch_path")/.orch-provided-XXXXXX")" || return 1
  if ! jq --arg id "$node_id" --arg plan "$control_plan" '
      (.stages[] | select(.id == $id)) |= (
        .plan = $plan
        | del(.planFrom)
        | if ((.sessionStrategy // "") == "") then .sessionStrategy = "fresh" else . end
      )
    ' "$orch_path" >"$tmp"; then
    rm -f "$tmp"
    echo "Error: failed to project provided-plan control onto orch stage $node_id" >&2
    return 1
  fi
  mv -f "$tmp" "$orch_path" || {
    rm -f "$tmp"
    return 1
  }
  return 0
}

# graph_dispatch_apply_provided_routing_order <orch_path> <node_id> <source_plan_path>
#   [--stage-runtime RT] [--stage-model M] [--invocation-runtime RT]
#   [--invocation-model M] [--workflow-runtime RT] [--workflow-model M]
#
# Resolves the fixed supplied-plan routing order for the plan-input consumer
# (TODO > stage > invocation > provided-plan header > workflow > saved > native)
# and writes effective runtime/model onto the orch stage only. Never mutates
# the frozen source or original plan.
graph_dispatch_apply_provided_routing_order() {
  local orch_path="" node_id="" source_plan=""
  local stage_runtime="" stage_model="" invocation_runtime="" invocation_model=""
  local workflow_runtime="" workflow_model=""
  local header_runtime="" header_model="" resolved eff_rt eff_model tmp line

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stage-runtime) stage_runtime="${2:-}"; shift 2 ;;
      --stage-model) stage_model="${2:-}"; shift 2 ;;
      --invocation-runtime) invocation_runtime="${2:-}"; shift 2 ;;
      --invocation-model) invocation_model="${2:-}"; shift 2 ;;
      --workflow-runtime) workflow_runtime="${2:-}"; shift 2 ;;
      --workflow-model) workflow_model="${2:-}"; shift 2 ;;
      --*)
        echo "Error: unknown graph_dispatch_apply_provided_routing_order argument: $1" >&2
        return 1
        ;;
      *)
        if [[ -z "$orch_path" ]]; then
          orch_path="$1"
        elif [[ -z "$node_id" ]]; then
          node_id="$1"
        elif [[ -z "$source_plan" ]]; then
          source_plan="$1"
        else
          echo "Error: unexpected positional argument: $1" >&2
          return 1
        fi
        shift
        ;;
    esac
  done

  [[ -f "$orch_path" && -n "$node_id" && -f "$source_plan" ]] || {
    echo "Error: graph_dispatch_apply_provided_routing_order requires orch_path, node_id, source_plan" >&2
    return 1
  }

  if ! declare -F workflow_routing_resolve >/dev/null 2>&1; then
    # shellcheck source=../workflow/workflow-routing.sh
    source "$GRAPH_DISPATCH_RALPH_ROOT/bash-lib/workflow/workflow-routing.sh"
  fi
  if ! declare -F plan_provided_input_fm_scalar >/dev/null 2>&1; then
    # shellcheck source=../plan-todo.sh
    source "$GRAPH_DISPATCH_RALPH_ROOT/bash-lib/plan-todo.sh"
  fi

  # Prefer orch stage pins when callers omit explicit stage overrides.
  if [[ -z "$stage_runtime" ]]; then
    stage_runtime="$(jq -r --arg id "$node_id" '
      .stages[] | select(.id == $id) | .runtime // empty
    ' "$orch_path")"
  fi
  if [[ -z "$stage_model" ]]; then
    stage_model="$(jq -r --arg id "$node_id" '
      .stages[] | select(.id == $id) | .model // empty
    ' "$orch_path")"
  fi

  header_runtime="$(plan_provided_input_fm_scalar "$source_plan" "runtime" 2>/dev/null || true)"
  header_model="$(plan_provided_input_fm_scalar "$source_plan" "model" 2>/dev/null || true)"

  resolved="$(
    workflow_routing_resolve \
      kind=agent \
      plan_input_consumer=1 \
      stage_runtime="$stage_runtime" \
      stage_model="$stage_model" \
      invocation_runtime="$invocation_runtime" \
      invocation_model="$invocation_model" \
      workflow_runtime="$workflow_runtime" \
      workflow_model="$workflow_model" \
      provided_plan_runtime="$header_runtime" \
      provided_plan_model="$header_model"
  )" || return 1

  eff_rt=""
  eff_model=""
  while IFS= read -r line; do
    case "$line" in
      runtime=*) eff_rt="${line#runtime=}" ;;
      model=*) eff_model="${line#model=}" ;;
    esac
  done <<<"$resolved"

  tmp="$(mktemp "$(dirname "$orch_path")/.orch-routing-XXXXXX")" || return 1
  if ! jq --arg id "$node_id" --arg rt "$eff_rt" --arg model "$eff_model" '
      (.stages[] | select(.id == $id)) |= (
        if ($rt != "") then .runtime = $rt else del(.runtime) end
        | if ($model != "") then .model = $model else del(.model) end
      )
    ' "$orch_path" >"$tmp"; then
    rm -f "$tmp"
    echo "Error: failed to apply provided-plan routing order onto orch stage $node_id" >&2
    return 1
  fi
  mv -f "$tmp" "$orch_path" || {
    rm -f "$tmp"
    return 1
  }
  return 0
}

# graph_dispatch_bind_provided_plan_control --graph-json ... --node-id ... --orch-path ...
#   --registry-run ... --attempt-number N [--plan-run-id ...] [--force-fresh]
#   [--invocation-runtime ...] [--invocation-model ...]
#   [--workflow-runtime ...] [--workflow-model ...]
#
# First-dispatch / resume / reset / rework binder for provided planInput
# consumers. Validates common input evidence, creates or reuses the control
# copy, projects orch plan + supplied-plan routing order, and prints binding
# JSON. Missing/corrupt input fails before workspace/runtime admission.
graph_dispatch_bind_provided_plan_control() {
  local graph_json="" node_id="" orch_path="" registry_run="" attempt_number=""
  local plan_run_id="" force_fresh=0
  local invocation_runtime="" invocation_model="" workflow_runtime="" workflow_model=""
  local kind binding bind_args=() control source

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --graph-json) graph_json="${2:-}"; shift 2 ;;
      --node-id) node_id="${2:-}"; shift 2 ;;
      --orch-path) orch_path="${2:-}"; shift 2 ;;
      --registry-run) registry_run="${2:-}"; shift 2 ;;
      --attempt-number) attempt_number="${2:-}"; shift 2 ;;
      --plan-run-id) plan_run_id="${2:-}"; shift 2 ;;
      --force-fresh) force_fresh=1; shift ;;
      --invocation-runtime) invocation_runtime="${2:-}"; shift 2 ;;
      --invocation-model) invocation_model="${2:-}"; shift 2 ;;
      --workflow-runtime) workflow_runtime="${2:-}"; shift 2 ;;
      --workflow-model) workflow_model="${2:-}"; shift 2 ;;
      *)
        echo "Error: unknown graph_dispatch_bind_provided_plan_control argument: $1" >&2
        return 1
        ;;
    esac
  done

  [[ -n "$graph_json" && -n "$node_id" && -n "$orch_path" && -n "$registry_run" && -n "$attempt_number" ]] || {
    echo "Error: graph_dispatch_bind_provided_plan_control requires --graph-json --node-id --orch-path --registry-run --attempt-number" >&2
    return 1
  }

  kind="$(graph_dispatch_node_provided_plan_kind "$graph_json" "$node_id")"
  [[ "$kind" == "provided" ]] || {
    echo "Error: node $node_id has no frozen provided planInputBinding" >&2
    return 1
  }

  if ! declare -F workflow_state_bind_provided_plan_control >/dev/null 2>&1; then
    # shellcheck source=../workflow/workflow-state.sh
    source "$GRAPH_DISPATCH_RALPH_ROOT/bash-lib/workflow/workflow-state.sh"
  fi

  bind_args=(
    --registry-run "$registry_run"
    --consumer-stage-id "$node_id"
    --consumer-attempt "$attempt_number"
  )
  [[ -n "$plan_run_id" ]] && bind_args+=(--plan-run-id "$plan_run_id")
  [[ "$force_fresh" -eq 1 ]] && bind_args+=(--force-fresh)

  binding="$(workflow_state_bind_provided_plan_control "${bind_args[@]}")" || return 1
  control="$(printf '%s' "$binding" | jq -r '.controlPlanPath')"
  source="$(printf '%s' "$binding" | jq -r '.sourcePlanPath')"
  graph_dispatch_apply_provided_to_orch "$orch_path" "$node_id" "$control" || return 1
  graph_dispatch_apply_provided_routing_order "$orch_path" "$node_id" "$source" \
    --invocation-runtime "$invocation_runtime" \
    --invocation-model "$invocation_model" \
    --workflow-runtime "$workflow_runtime" \
    --workflow-model "$workflow_model" || return 1
  printf '%s\n' "$binding"
}

# _graph_dispatch_rework_plan_abs_path <graph_json_path> <plan_root> <node_id> <namespace>
#
# Recomputes the absolute inline-plan path graph_dispatch_materialize_orch
# assigns a node, without re-materializing anything. Mirrors that function's
# plan_abs formula exactly (plan_root defaults to workspace in callers that do
# not pass a separate ledger run directory).
_graph_dispatch_rework_plan_abs_path() {
  local graph_json_path="$1" plan_root="$2" node_id="$3" namespace="$4"
  local idx orch_dir
  idx="$(jq -r --arg id "$node_id" \
    '[.nodes[].id] | index($id) // empty' "$graph_json_path" 2>/dev/null)"
  if [[ -z "$idx" ]]; then
    return 1
  fi
  orch_dir="$plan_root/orchestration-plans/$namespace"
  printf '%s/%s\n' "$orch_dir" \
    "$(printf '%s-%02d-%s.plan.md' "$namespace" "$((idx + 1))" "$node_id")"
}

# _graph_dispatch_inject_rework_feedback <graph_json_path> <node_id> <workspace> <namespace> <state_root>
#   [plan_root] [orch_path]
#
# Injects the prior review round's verdict feedback into a rework target
# node's rendered inline plan, generated planFrom control copy, or
# provided-plan control copy, immediately before that node is dispatched.
# No-op (returns 0) for any node that is not a rework-derived node, or whose
# single upstream dependency does not declare a loopCheck (i.e. is not the
# review stage that produced a verdict for this node to act on) -- only
# rework target rounds satisfy both, since expand_rework_nodes always makes
# a target round dependOn exactly the review node/round that gated it, and
# only review nodes carry a compiled stage.loopCheck (graph node-only
# metadata; see build_orch_stage / the graph node-emission path in
# plan-todo.sh).
#
# A rework node whose required upstream verdict artifact is missing or
# invalid at this authoritative call site is a hard dispatch failure: the
# caller must not proceed to invoke the model. Generated planFrom and
# provided-plan rework clones inject into the mutable control copy (never
# the planner JSON, immutable generated/provided source, or original).
# Inline-plan rework nodes still require a materialized inline plan.
_graph_dispatch_inject_rework_feedback() {
  local graph_json_path="$1" node_id="$2" workspace="$3" namespace="$4" state_root="$5"
  local plan_root="${6:-$workspace}"
  local orch_path="${7:-}"
  local run_id="${8:-}"

  local derived_from recovery_feedback=""
  derived_from="$(jq -r --arg id "$node_id" \
    '.nodes[] | select(.id == $id) | .derivedFrom // empty' "$graph_json_path" 2>/dev/null)"
  [[ "$derived_from" == "rework" ]] || return 0

  if [[ -n "$run_id" ]] && declare -F graph_state_read_node >/dev/null 2>&1; then
    recovery_feedback="$(graph_state_read_node "$state_root" "$namespace" "$run_id" "$node_id" 2>/dev/null \
      | jq -c --arg id "$node_id" \
        'select((.recoveryFeedback.targetStageId // "") == $id) | .recoveryFeedback' 2>/dev/null || true)"
  fi

  local source_stage
  if [[ -n "$recovery_feedback" ]]; then
    source_stage="$(printf '%s' "$recovery_feedback" | jq -r '.sourceStageId // empty')"
  else
    source_stage="$(jq -r --arg id "$node_id" \
      '.nodes[] | select(.id == $id) | (.dependsOn // [])[0] // empty' "$graph_json_path" 2>/dev/null)"
  fi
  [[ -n "$source_stage" ]] || return 0

  local loop_check_path
  if [[ -n "$recovery_feedback" ]]; then
    loop_check_path="$(printf '%s' "$recovery_feedback" | jq -r '.artifactRelativePath // empty')"
  else
    loop_check_path="$(jq -r --arg id "$source_stage" \
      '.nodes[] | select(.id == $id) | .stage.loopCheck.path // empty' "$graph_json_path" 2>/dev/null)"
  fi
  [[ -n "$loop_check_path" ]] || return 0

  local loop_check_schema
  if [[ -n "$recovery_feedback" ]]; then
    loop_check_schema="$(printf '%s' "$recovery_feedback" | jq -r '.schemaPath // empty')"
  else
    loop_check_schema="$(jq -r --arg id "$source_stage" \
      '.nodes[] | select(.id == $id) | .stage.loopCheck.schema // empty' "$graph_json_path" 2>/dev/null)"
  fi
  # loopCheck.schema is authored project-root-relative (matching the
  # orchestrator's own loopControl.evaluatorSchema convention); resolve it
  # against the workspace when it is not already absolute.
  if [[ -n "$loop_check_schema" && "$loop_check_schema" != /* ]]; then
    loop_check_schema="$workspace/$loop_check_schema"
  fi

  local stage_id_sub="${source_stage//:/_}"
  local resolved_path="$loop_check_path"
  resolved_path="${resolved_path//\{\{ARTIFACT_NS\}\}/$namespace}"
  resolved_path="${resolved_path//\{\{STAGE_ID\}\}/$stage_id_sub}"

  local artifact_rel="$resolved_path"
  local artifact_abs="$resolved_path"
  if [[ "$resolved_path" == .ralph-workspace/* && -n "$state_root" ]]; then
    artifact_abs="$state_root/${resolved_path#.ralph-workspace/}"
  fi

  if [[ ! -f "$artifact_abs" ]]; then
    echo "Error: rework node $node_id requires the evaluator verdict artifact from $source_stage, but it is missing: $artifact_abs" >&2
    return 1
  fi

  local iteration="1"
  if [[ -n "$recovery_feedback" ]]; then
    iteration="$(printf '%s' "$recovery_feedback" | jq -r '.iteration // 1')"
  elif [[ "$node_id" =~ -r([0-9]+)$ ]]; then
    iteration="${BASH_REMATCH[1]}"
  fi

  local plan_abs=""
  local provided_kind planfrom_id
  provided_kind="$(graph_dispatch_node_provided_plan_kind "$graph_json_path" "$node_id")"
  planfrom_id="$(graph_dispatch_node_planfrom_id "$graph_json_path" "$node_id")"
  if [[ -n "$orch_path" && -f "$orch_path" ]]; then
    plan_abs="$(jq -r --arg id "$node_id" \
      '.stages[] | select(.id == $id) | .plan // empty' "$orch_path" 2>/dev/null)"
  fi
  if [[ -z "$plan_abs" || ! -f "$plan_abs" ]]; then
    if [[ "$provided_kind" == "provided" ]]; then
      echo "Error: provided-plan rework node $node_id has no control plan for feedback injection" >&2
      return 1
    fi
    if [[ -n "$planfrom_id" ]]; then
      echo "Error: planFrom rework node $node_id has no control plan for feedback injection" >&2
      return 1
    fi
    plan_abs="$(_graph_dispatch_rework_plan_abs_path "$graph_json_path" "$plan_root" "$node_id" "$namespace")" || {
      echo "Error: rework node $node_id: could not resolve its own graph node index" >&2
      return 1
    }
  fi
  if [[ ! -f "$plan_abs" ]]; then
    echo "Error: rework node $node_id has no materialized inline plan at $plan_abs" >&2
    return 1
  fi

  if ! declare -F ralph_evaluator_inject_feedback_into_plan >/dev/null 2>&1; then
    # shellcheck source=../review-status.sh
    source "$GRAPH_DISPATCH_RALPH_ROOT/bash-lib/review-status.sh"
  fi

  ralph_evaluator_inject_feedback_into_plan \
    "$plan_abs" "$artifact_abs" "$source_stage" "$iteration" "$artifact_rel" "$loop_check_schema" || {
    echo "Error: rework node $node_id: failed to inject evaluator feedback from $source_stage" >&2
    return 1
  }
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
  local state_root="${RALPH_PLAN_WORKSPACE_ROOT:-$workspace/.ralph-workspace}"

  orch_path="$(graph_dispatch_materialize_orch "$graph_json_path" "$workspace")" || return 1

  namespace="$(jq -r '.namespace // empty' "$orch_path")"
  [[ -n "$namespace" ]] || namespace="$(basename "$orch_path" .orch.json)"

  # Authoritative injection point: the upstream review verdict this rework
  # node depends on is guaranteed to exist by the time this node is actually
  # dispatched (never during bulk/pre-run plan materialization above, where
  # the verdict may not exist yet). A missing/invalid verdict here fails the
  # dispatch outright rather than silently skipping the model invocation.
  _graph_dispatch_inject_rework_feedback "$graph_json_path" "$node_id" "$workspace" "$namespace" "$state_root" || return 1

  attempt_id="$(graph_dispatch_mint_attempt_id "$node_id" "$run_id" "$attempt_number")" || return 1
  graph_dispatch_build_argv "$orch_path" "$node_id" "$run_id" "$attempt_id" "$workspace" || return 1

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
