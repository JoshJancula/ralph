#!/usr/bin/env bash
# Graph mode entrypoint (`ralph graph <verb>`). Only `compile` is implemented
# here; it lets an operator lint and visualize an existing pipeline plan's
# implicit artifact DAG without running anything. run, resume, and status
# land with the scheduler and ledger phases of the GRAPH-MODE plan; render
# grows into the real mermaid/dot/ascii renderer in Phase 7. This script
# never touches the loop execution path in run-plan.sh or orchestrator.sh.
#
# Phase 3 ledger note: each attempt entry must record the resolved stage
# subagents value (inherit|on|off). Omitting it would hide an unaccounted
# token source and corrupt savings/usage comparisons.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RALPH_BASH_LIB="$SCRIPT_DIR/bash-lib"

# shellcheck source=bash-lib/graph/graph-compile.sh
source "$RALPH_BASH_LIB/graph/graph-compile.sh"
# shellcheck source=bash-lib/graph/graph-schedule.sh
source "$RALPH_BASH_LIB/graph/graph-schedule.sh"
# shellcheck source=bash-lib/graph/graph-status.sh
source "$RALPH_BASH_LIB/graph/graph-status.sh"
# shellcheck source=bash-lib/graph/graph-run-base.sh
source "$RALPH_BASH_LIB/graph/graph-run-base.sh"
# shellcheck source=bash-lib/graph/graph-publish.sh
source "$RALPH_BASH_LIB/graph/graph-publish.sh"

graph_run_usage() {
  cat <<'EOF' >&2
Usage: graph-run.sh <verb> [options]

Verbs:
  compile <plan-path> [--render mermaid|dot|ascii] [--out <path>] [--force]
      Compile a graph-mode plan into .graph.json, validate it, and cache the
      result beside the plan. See `graph-run.sh compile --help`.

  run <plan-path> [--namespace <ns>] [--max-parallel <n>]
      Compile and run a graph plan to completion, recording the durable
      run-state ledger under .ralph-workspace/graph-runs/<namespace>/.

  resume <plan-path> --namespace <ns> --run <run-id|latest>
      [--accept-graph-change]
      Resume a graph run. Recompiles the plan and compares graphSha; refuses
      when the graph changed unless --accept-graph-change is supplied, in
      which case affected nodes are invalidated. Succeeded nodes are skipped;
      an orphaned in-flight node is adopted when its StageOutcomeReport is
      present, otherwise reset to pending; failed/cancelled/blocked nodes
      reset to pending.

  status --namespace <ns> --run <run-id|latest> [--workspace <dir>]
      Display the current state of a graph run.  Read-only; safe to call
      against a live in-progress run.  Outputs a table (node, type, runtime,
      state, attempt count, duration) and a mermaid flowchart with per-state
      class definitions.  Consensus nodes include per-voter provenance and
      confidence.

  render <plan-path> [--format mermaid|dot|ascii] [--out <path>]
      Render a compiled graph as mermaid, dot, or ascii.  This is a
      pre-run static view of the graph shape, not the live run state.
EOF
}

main() {
  if [[ $# -eq 0 ]]; then
    graph_run_usage
    exit 1
  fi

  local verb="$1"
  shift

  case "$verb" in
    compile)
      graph_compile_cli "$@"
      ;;
    run)
      graph_run_run_cli "$@"
      ;;
    resume)
      graph_run_resume_cli "$@"
      ;;
    status)
      graph_status_cli "$@"
      ;;
    render)
      # render is the pre-run static graph shape view; status is the live run
      # state view.  render delegates to graph_compile_cli with --render.
      graph_compile_cli --render "${@}"
      ;;
    -h|--help)
      graph_run_usage
      exit 0
      ;;
    *)
      echo "Error: unknown graph verb '$verb'" >&2
      graph_run_usage
      exit 1
      ;;
  esac
}

# graph_run_run_cli <plan-path> [--namespace <ns>] [--max-parallel <n>]
graph_run_run_cli() {
  local plan_path="" namespace="" max_parallel=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --namespace) namespace="$2"; shift 2 ;;
      --namespace=*) namespace="${1#--namespace=}"; shift ;;
      --max-parallel) max_parallel="$2"; shift 2 ;;
      --max-parallel=*) max_parallel="${1#--max-parallel=}"; shift ;;
      -h|--help)
        cat <<'EOF' >&2
Usage: graph-run.sh run <plan-path> [--namespace <ns>] [--max-parallel <n>]
EOF
        return 0
        ;;
      --) shift; break ;;
      -*) echo "Error: unknown option '$1'" >&2; return 1 ;;
      *)
        if [[ -n "$plan_path" ]]; then
          echo "Error: unexpected extra argument '$1'" >&2
          return 1
        fi
        plan_path="$1"
        shift
        ;;
    esac
  done
  if [[ -z "$plan_path" ]]; then
    echo "Error: graph run requires a plan path" >&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required for graph run" >&2
    return 1
  fi

  local graph_json compile_graph_tmp workspace roots_json state_root agent_workspace modes_json
  roots_json="$(graph_run_base_resolve_roots "$(pwd)")" || return 1
  workspace="$(printf '%s' "$roots_json" | jq -r '.projectRoot')"
  state_root="$(printf '%s' "$roots_json" | jq -r '.stateRoot')"
  agent_workspace="$(printf '%s' "$roots_json" | jq -r '.agentWorkspace')"
  export RALPH_GRAPH_STATE_ROOT="$state_root"
  export RALPH_PROJECT_ROOT="$workspace"
  export RALPH_PLAN_WORKSPACE_ROOT="$state_root"
  export RALPH_AGENT_WORKSPACE="$agent_workspace"
  # `run` must not leave a compile cache beside a plan in the caller checkout.
  # The durable ledger freezes its own graph.json immediately after compile.
  graph_json="$(mktemp "$state_root/graph-compile.XXXXXX")" || return 1
  compile_graph_tmp="$graph_json"
  if ! graph_compile_plan "$plan_path" "$graph_json" 1 >/dev/null; then
    rm -f "$graph_json"
    return 1
  fi
  if [[ -z "$namespace" ]]; then
    namespace="$(jq -r '.namespace // empty' "$graph_json")"
    if [[ -z "$namespace" ]]; then
      namespace="$(basename "$plan_path")"
      namespace="${namespace%.plan.md}"
      namespace="${namespace%.md}"
    fi
  fi
  if [[ "$(jq -r '.namespace // empty' "$graph_json")" != "$namespace" ]]; then
    local namespaced_graph
    namespaced_graph="$(mktemp "$state_root/graph-namespace.XXXXXX")" || { rm -f "$graph_json"; return 1; }
    jq --arg namespace "$namespace" '.namespace = $namespace' "$graph_json" >"$namespaced_graph" || {
      rm -f "$graph_json" "$namespaced_graph"
      return 1
    }
    mv -f "$namespaced_graph" "$graph_json"
  fi
  local run_id
  run_id="$(graph_state_mint_run_id)"
  local max_p=2
  if [[ -n "$max_parallel" ]]; then
    max_p="$max_parallel"
  else
    max_p="$(jq -r '.maxParallel // 2' "$graph_json")"
  fi
  if ! graph_state_init_run "$workspace" "$namespace" "$run_id" "$plan_path" "$graph_json" "$max_p"; then
    rm -f "$graph_json"
    return 1
  fi
  local run_dir
  run_dir="$(graph_state_run_dir "$workspace" "$namespace" "$run_id")"
  graph_json="$run_dir/graph.json"
  rm -f "$compile_graph_tmp"
  modes_json="$(graph_run_base_modes_json "$graph_json")" || {
    graph_state_set_run_status "$workspace" "$namespace" "$run_id" "failed" 2>/dev/null || true
    return 1
  }
  if ! graph_run_base_prepare "$run_dir" "$roots_json" "$modes_json"; then
    graph_state_set_run_status "$workspace" "$namespace" "$run_id" "failed" 2>/dev/null || true
    return 1
  fi
  if ! graph_workspace_prepare_run "$run_dir" "$graph_json"; then
    graph_state_set_run_status "$workspace" "$namespace" "$run_id" "failed" 2>/dev/null || true
    return 1
  fi
  local schedule_rc=0 publish_rc=0
  graph_schedule_run "$graph_json" "$run_id" "$workspace" "$run_dir" || schedule_rc=$?
  graph_publish_finalize "$run_dir" "$graph_json" "$workspace" || publish_rc=$?
  if [[ "$schedule_rc" -eq 0 && "$publish_rc" -ne 0 ]]; then
    schedule_rc="$publish_rc"
  fi
  case "$(jq -r '.status // empty' "$run_dir/run.json")" in
    succeeded|failed|cancelled)
      if ! graph_publish_should_retain "$run_dir" "$graph_json"; then
        graph_workspace_cleanup_run "$run_dir" || {
          [[ "$schedule_rc" -ne 0 ]] || schedule_rc=1
        }
      fi
      ;;
  esac
  return "$schedule_rc"
}

# graph_run_resume_cli <plan-path> --namespace <ns> --run <run-id|latest>
#   [--accept-graph-change]
graph_run_resume_cli() {
  local plan_path="" namespace="" run_token="" accept_change=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --namespace) namespace="$2"; shift 2 ;;
      --namespace=*) namespace="${1#--namespace=}"; shift ;;
      --run) run_token="$2"; shift 2 ;;
      --run=*) run_token="${1#--run=}"; shift ;;
      --accept-graph-change) accept_change=1; shift ;;
      -h|--help)
        cat <<'EOF' >&2
Usage: graph-run.sh resume <plan-path> --namespace <ns> --run <run-id|latest> [--accept-graph-change]
EOF
        return 0
        ;;
      --) shift; break ;;
      -*) echo "Error: unknown option '$1'" >&2; return 1 ;;
      *)
        if [[ -n "$plan_path" ]]; then
          echo "Error: unexpected extra argument '$1'" >&2
          return 1
        fi
        plan_path="$1"
        shift
        ;;
    esac
  done
  if [[ -z "$plan_path" || -z "$namespace" || -z "$run_token" ]]; then
    echo "Error: graph resume requires <plan-path> --namespace <ns> --run <run-id|latest>" >&2
    return 1
  fi
  local extra=()
  if [[ "$accept_change" -eq 1 ]]; then
    extra+=(--accept-graph-change)
  fi
  local workspace roots_json state_root agent_workspace
  roots_json="$(graph_run_base_resolve_roots "$(pwd)")" || return 1
  workspace="$(printf '%s' "$roots_json" | jq -r '.projectRoot')"
  state_root="$(printf '%s' "$roots_json" | jq -r '.stateRoot')"
  agent_workspace="$(printf '%s' "$roots_json" | jq -r '.agentWorkspace')"
  export RALPH_GRAPH_STATE_ROOT="$state_root"
  export RALPH_PROJECT_ROOT="$workspace"
  export RALPH_PLAN_WORKSPACE_ROOT="$state_root"
  export RALPH_AGENT_WORKSPACE="$agent_workspace"
  local resolved_run_id resume_run_dir resume_rc=0 publish_rc=0 frozen_graph
  resolved_run_id="$(graph_state_resolve_run_id "$workspace" "$namespace" "$run_token")" || return 1
  resume_run_dir="$(graph_state_run_dir "$workspace" "$namespace" "$resolved_run_id")"
  graph_schedule_resume "$workspace" "$namespace" "$run_token" "$plan_path" "${extra[@]}" || resume_rc=$?
  frozen_graph="$resume_run_dir/graph.json"
  if [[ -f "$resume_run_dir/run.json" && -f "$frozen_graph" ]]; then
    graph_publish_finalize "$resume_run_dir" "$frozen_graph" "$workspace" || publish_rc=$?
    if [[ "$resume_rc" -eq 0 && "$publish_rc" -ne 0 ]]; then
      resume_rc="$publish_rc"
    fi
  fi
  if [[ -f "$resume_run_dir/run.json" ]]; then
    case "$(jq -r '.status // empty' "$resume_run_dir/run.json")" in
      succeeded|failed|cancelled)
        if jq -e '.workspaceManager.schemaVersion == 1' "$resume_run_dir/run.json" >/dev/null 2>&1 \
          && ! graph_publish_should_retain "$resume_run_dir" "$frozen_graph"; then
          graph_workspace_cleanup_run "$resume_run_dir" || {
            [[ "$resume_rc" -ne 0 ]] || resume_rc=1
          }
        fi
        ;;
    esac
  fi
  return "$resume_rc"
}

main "$@"
