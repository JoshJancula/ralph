#!/usr/bin/env bats
source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

STATE_PATHS="$REPO_ROOT/bundle/.ralph/bash-lib/state-paths.sh"
FIXTURE_GENERATOR="$REPO_ROOT/tests/fixtures/state-layout/generate-fixtures.sh"

setup() { fixture_root="$(mktemp -d)"; bash "$FIXTURE_GENERATOR" "$fixture_root"; }
teardown() { rm -rf "$fixture_root"; }

@test "mixed layouts use the recorded catalog version for workflow and graph readers" {
  run bash -c 'source "$1"; RALPH_STATE_LAYOUT=1; ralph_state_workflow_run_dir "$2/mixed" run-2; ralph_state_graph_run_dir "$2/mixed" demo run-2' _ "$STATE_PATHS" "$fixture_root"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$fixture_root/mixed/runs/run-2/engine/workflow"* ]]
  [[ "$output" == *"$fixture_root/mixed/runs/run-2/engine/graph"* ]]
}

@test "state paths preserve spaces and external state roots" {
  external="$fixture_root/external state root"; mkdir -p "$external"; cp -R "$fixture_root/mixed/." "$external/"
  run bash -c 'source "$1"; ralph_state_workflow_run_dir "$2" run-2' _ "$STATE_PATHS" "$external"
  [ "$status" -eq 0 ]
  [[ "$output" == *"/external state root/runs/run-2/engine/workflow" ]]
}

@test "a v1 resume remains v1 after RALPH_STATE_LAYOUT changes" {
  run bash -c 'source "$1"; RALPH_STATE_LAYOUT=2; ralph_state_layout_version "$2/v1" plan-1; ralph_state_plan_attempt_dir "$2/v1" demo plan-1 plan plan-1' _ "$STATE_PATHS" "$fixture_root"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'1\n'* ]]
  [[ "$output" == *"$fixture_root/v1/logs/demo/runs/plan-1"* ]]
}

@test "state resolver refuses traversal and symlink escapes" {
  run bash -c 'source "$1"; ralph_state_path_resolve "$2/mixed" ../escape' _ "$STATE_PATHS" "$fixture_root"
  [ "$status" -ne 0 ]
  run bash -c 'source "$1"; ralph_state_path_resolve "$2/mixed" external-v1-link/nope' _ "$STATE_PATHS" "$fixture_root"
  [ "$status" -ne 0 ]
}

@test "layout 1 resolver returns exact pre-plan paths for every category" {
  local root="$fixture_root/layout1-table"
  mkdir -p "$root"
  root="$(cd "$root" && pwd -P)"
  run bash -c '
    set -euo pipefail
    source "$1"
    export RALPH_STATE_LAYOUT=1
    root="$2"
    key=demo
    run_id=run-1
    ns=demo

    attempt="$(ralph_state_plan_attempt_dir "$root" "$key" "$run_id")"
    [[ "$attempt" == "$root/logs/$key/runs/$run_id" ]]

    # Plan runs index sits beside attempts under the layout-1 runs directory.
    index="$root/logs/$key/runs/index.jsonl"
    [[ "$(dirname -- "$attempt")/index.jsonl" == "$index" ]]

    [[ "$(ralph_state_workflow_run_dir "$root" "$run_id")" == "$root/workflow-runs/$run_id" ]]
    [[ "$(ralph_state_graph_run_dir "$root" "$ns" "$run_id")" == "$root/graph-runs/$ns/$run_id" ]]
    [[ "$(ralph_state_shared_dir "$root" sessions)" == "$root/sessions" ]]
    [[ "$(ralph_state_shared_dir "$root" tool-results)" == "$root/tool-results" ]]
    [[ "$(ralph_state_shared_dir "$root" runtime-config)" == "$root/runtime-config" ]]
    [[ "$(ralph_state_shared_dir "$root" processes)" == "$root/processes" ]]
  ' _ "$STATE_PATHS" "$root"
  [ "$status" -eq 0 ]
}

SESSION_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-session.sh"
CLEANUP_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/cleanup-plan.sh"
MCP_LOG_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-logging.sh"

@test "resume-run reader resolves layout-1 and layout-2 plan attempt paths" {
  local root_v1 root_v2
  root_v1="$(cd "$fixture_root/v1" && pwd -P)"
  root_v2="$(cd "$fixture_root/mixed" && pwd -P)"
  run bash -c '
    set -euo pipefail
    source "$1"
    source "$2"
    root_v1="$3"
    root_v2="$4"
    export RALPH_PLAN_KEY=demo
    export RALPH_PLAN_WORKSPACE_ROOT="$root_v1"
    index_v1="$(ralph_session_resume_run_index_path)"
    manifest_v1="$(ralph_session_resume_run_manifest_path "$root_v1" demo run-1)"
    [[ "$index_v1" == "$root_v1/logs/demo/runs/index.jsonl" ]]
    [[ "$manifest_v1" == "$root_v1/logs/demo/runs/run-1/run-manifest.json" ]]
    export RALPH_PLAN_WORKSPACE_ROOT="$root_v2"
    index_v2="$(ralph_session_resume_run_index_path)"
    manifest_v2="$(ralph_session_resume_run_manifest_path "$root_v2" demo run-2)"
    [[ "$index_v2" == "$root_v2/cache/indexes/runs.jsonl" ]]
    [[ "$manifest_v2" == "$root_v2/runs/run-2/stages/plan/attempts/run-2/run-manifest.json" ]]
  ' _ "$STATE_PATHS" "$SESSION_LIB" "$root_v1" "$root_v2"
  [ "$status" -eq 0 ]
}

@test "cleanup-plan graph prune reader resolves layout-1 and layout-2 graph run dirs" {
  local root_v1 root_v2
  root_v1="$(cd "$fixture_root/v1" && pwd -P)"
  root_v2="$(cd "$fixture_root/mixed" && pwd -P)"
  run bash -c '
    set -euo pipefail
    source "$1"
    source "$2"
    root_v1="$3"
    root_v2="$4"
    export RALPH_PLAN_WORKSPACE_ROOT="$root_v1"
    ns_v1="$(cleanup_plan_graph_runs_namespace_dir /unused demo)"
    run_v1="$(cleanup_plan_graph_run_dir /unused demo graph-1)"
    [[ "$ns_v1" == "$root_v1/graph-runs/demo" ]]
    [[ "$run_v1" == "$root_v1/graph-runs/demo/graph-1" ]]
    export RALPH_PLAN_WORKSPACE_ROOT="$root_v2"
    run_v2="$(cleanup_plan_graph_run_dir /unused demo run-2)"
    [[ "$run_v2" == "$root_v2/runs/run-2/engine/graph" ]]
  ' _ "$STATE_PATHS" "$CLEANUP_LIB" "$root_v1" "$root_v2"
  [ "$status" -eq 0 ]
}

@test "MCP plan-log reader resolves through state-paths for layout roots" {
  local root_v1 root_v2
  root_v1="$(cd "$fixture_root/v1" && pwd -P)"
  root_v2="$(cd "$fixture_root/mixed" && pwd -P)"
  run bash -c '
    set -euo pipefail
    source "$1"
    source "$2"
    root_v1="$3"
    root_v2="$4"
    export RALPH_PLAN_KEY=demo
    export RALPH_PLAN_WORKSPACE_ROOT="$root_v1"
    log_v1="$(ralph_mcp_proxy_plan_log_path)"
    [[ "$log_v1" == "$root_v1/logs/demo/mcp.log" ]]
    export RALPH_PLAN_WORKSPACE_ROOT="$root_v2"
    log_v2="$(ralph_mcp_proxy_plan_log_path)"
    [[ "$log_v2" == "$root_v2/logs/demo/mcp.log" ]]
  ' _ "$STATE_PATHS" "$MCP_LOG_LIB" "$root_v1" "$root_v2"
  [ "$status" -eq 0 ]
}
