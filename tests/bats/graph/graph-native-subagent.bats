#!/usr/bin/env bats

# Tests for graph-native-subagent.sh
#
# Verification requirements (from TODO #7):
#   1. For each supported adapter, prove a parent can invoke one allowed read-only child.
#   2. The child cannot edit a fixture (verified by checking overlay tools list).
#   3. The child cannot spawn a native child (no Agent in overlay tools).
#   4. The child cannot call cross-runtime delegation (no delegation MCP in overlay).
#   5. The child cannot complete the parent TODO (contract text asserts this).
#   6. Denied agent types are absent or rejected.
#   7. Unsupported runtimes fail before model invocation.
#   8. Output is logged to native-readonly.log.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

_lib="$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-native-subagent.sh"
_invoke_common="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-common.sh"

setup() {
  TMPD="$(mktemp -d)"
  export RALPH_AGENT_WORKSPACE="$TMPD"
  # Unset mode vars so tests start clean
  unset RALPH_PLAN_NATIVE_SUBAGENT_MODE RALPH_PLAN_NATIVE_SUBAGENT_RUNTIME
  unset RALPH_PLAN_NATIVE_SUBAGENT_AGENTS
  unset PROMPT_STATIC
  # shellcheck source=../../../bundle/.ralph/bash-lib/graph/graph-native-subagent.sh
  source "$_lib"
}

teardown() {
  rm -rf "$TMPD"
  unset RALPH_AGENT_WORKSPACE
  unset RALPH_PLAN_NATIVE_SUBAGENT_MODE RALPH_PLAN_NATIVE_SUBAGENT_RUNTIME
  unset RALPH_PLAN_NATIVE_SUBAGENT_AGENTS
  unset PROMPT_STATIC
}

# ---------------------------------------------------------------------------
# Ralph-child removal (fail-closed stubs)
# ---------------------------------------------------------------------------

@test "runtime_supported: every runtime is refused after Ralph-child removal" {
  for rt in claude opencode codex cursor antigravity unknownruntime; do
    run graph_native_subagent_runtime_supported "$rt"
    [ "$status" -ne 0 ]
    [[ "$output" == *"removed"* || "$output" == *"nativeSubagents"* ]]
  done
}

@test "runtime_supported: empty runtime returns 1" {
  run graph_native_subagent_runtime_supported ""
  [ "$status" -ne 0 ]
}

@test "validate_agents: portable allowlist removed" {
  run graph_native_subagent_validate_agents research
  [ "$status" -ne 0 ]
  [[ "$output" == *"removed"* || "$output" == *"allowlist"* || "$output" == *"nativeSubagents"* ]]
}

@test "generate_child_overlay: refuses and writes no file" {
  local out_path="$TMPD/research.md"
  run graph_native_subagent_generate_child_overlay research claude "$out_path"
  [ "$status" -ne 0 ]
  [ ! -f "$out_path" ]
}

@test "prompt_contract: emits no Ralph-child contract text" {
  run graph_native_subagent_prompt_contract "n1" "research"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "setup: always refuses and writes no overlay artifacts" {
  local overlay_dir="$TMPD/overlays"
  mkdir -p "$overlay_dir"
  export RALPH_MCP_SCOPE="graph-node"
  export RALPH_GRAPH_DELEGATION_DEPTH="0"
  local delegation='{"maxDepth":1,"maxChildren":2,"native":{"mode":"read-only","allowedAgents":["research"],"maxParallel":1},"crossRuntime":{"mode":"off"}}'
  run graph_native_subagent_setup "$delegation" claude "$TMPD" "test-node" "$overlay_dir"
  [ "$status" -ne 0 ]
  [[ "$output" == *"removed"* || "$output" == *"nativeSubagents"* ]]
  [ -z "$(find "$overlay_dir" -type f 2>/dev/null)" ]
}

@test "setup: child scope still denied with no overlay artifacts" {
  local overlay_dir="$TMPD/overlays-child"
  mkdir -p "$overlay_dir"
  export RALPH_MCP_SCOPE="native-subagent"
  export RALPH_GRAPH_DELEGATION_DEPTH="1"
  local delegation='{"native":{"mode":"read-only","allowedAgents":["research"]}}'
  run graph_native_subagent_setup "$delegation" claude "$TMPD" "child-node" "$overlay_dir"
  [ "$status" -ne 0 ]
  [ -z "$(find "$overlay_dir" -type f 2>/dev/null)" ]
}

@test "env_from_delegation: always resolves to off" {
  local delegation='{"native":{"mode":"read-only","allowedAgents":["research"]}}'
  graph_native_subagent_env_from_delegation "$delegation" claude
  [ "${RALPH_PLAN_NATIVE_SUBAGENT_MODE:-}" = "off" ]
}

@test "invoke-common: verify_runtime is a no-op after Ralph-child removal" {
  export RALPH_PLAN_NATIVE_SUBAGENT_MODE=read-only
  source "$_invoke_common"
  run ralph_run_plan_native_subagent_verify_runtime opencode
  [ "$status" -eq 0 ]
}

@test "invoke-common: append_contract never injects Ralph-child contract" {
  export RALPH_PLAN_NATIVE_SUBAGENT_MODE=read-only
  PROMPT_STATIC="original content"
  export PROMPT_STATIC
  export RALPH_STAGE_ID="my-stage"
  source "$_invoke_common"
  ralph_run_plan_native_subagent_append_contract
  [ "$PROMPT_STATIC" = "original content" ]
  [[ "$PROMPT_STATIC" != *"Native Subagent Contract"* ]]
}

@test "collect_failure_evidence: no Ralph-child ledger to scan" {
  run graph_native_subagent_collect_failure_evidence "attempt-1" "$TMPD" "$TMPD/test.log"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Graph/orchestration nativeSubagents authoring schema (roles redesign)
# ---------------------------------------------------------------------------

json_payload() {
  printf '%s\n' "$1" | awk 'END{print}'
}

@test "schema: accepts nativeSubagents off and inherit on agent stages" {
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/plan-todo.sh"
  local tmpd plan_file
  tmpd="$(mktemp -d)"
  for mode in off inherit; do
    plan_file="$tmpd/native-$mode.plan.md"
    cat >"$plan_file" <<EOF
---
execution: graph
pipeline:
  stages:
    - id: source
      runtime: cursor
      nativeSubagents: $mode
todos:
  - id: source-1
    stage: source
    content: do work
    status: pending
---
EOF
    run plan_pipeline_graph_json "$plan_file"
    [ "$status" -eq 0 ]
    payload="$(json_payload "$output")"
    [ "$(printf '%s' "$payload" | jq -r '.nodes[] | select(.id=="source") | .stage.nativeSubagents')" = "$mode" ]
    [ "$(printf '%s' "$payload" | jq -r '.nodes[] | select(.id=="source") | .stage | has("subagents")')" = "false" ]
  done
  rm -rf "$tmpd"
}

@test "default: omitted nativeSubagents compiles per-runtime deny capability" {
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/plan-todo.sh"
  local tmpd plan_file payload
  tmpd="$(mktemp -d)"

  # Runtimes with a proven deny boundary default to off.
  for rt in claude codex; do
    plan_file="$tmpd/native-default-$rt.plan.md"
    cat >"$plan_file" <<EOF
---
execution: graph
pipeline:
  stages:
    - id: source
      runtime: $rt
todos:
  - id: source-1
    stage: source
    content: do work
    status: pending
---
EOF
    run plan_pipeline_graph_json "$plan_file"
    [ "$status" -eq 0 ]
    payload="$(json_payload "$output")"
    [ "$(printf '%s' "$payload" | jq -r '.nodes[] | select(.id=="source") | .stage.nativeSubagents')" = "off" ]
    [ "$(printf '%s' "$payload" | jq -r '.nodes[] | select(.id=="source") | .stage | has("subagents")')" = "false" ]
  done

  # Runtimes with no proven deny boundary default to inherit: Ralph must not
  # pick a value that would refuse to invoke a stage nobody set to off.
  for rt in cursor opencode antigravity; do
    plan_file="$tmpd/native-default-$rt.plan.md"
    cat >"$plan_file" <<EOF
---
execution: graph
pipeline:
  stages:
    - id: source
      runtime: $rt
todos:
  - id: source-1
    stage: source
    content: do work
    status: pending
---
EOF
    run plan_pipeline_graph_json "$plan_file"
    [ "$status" -eq 0 ]
    payload="$(json_payload "$output")"
    [ "$(printf '%s' "$payload" | jq -r '.nodes[] | select(.id=="source") | .stage.nativeSubagents')" = "inherit" ]
  done

  # The frozen delegated-run policy is unchanged by the nativeSubagents default.
  plan_file="$tmpd/native-default-cursor.plan.md"
  run plan_pipeline_graph_json "$plan_file"
  [ "$status" -eq 0 ]
  payload="$(json_payload "$output")"
  [ "$(printf '%s' "$payload" | jq -c '.nodes[] | select(.id=="source") | .stage.delegation')" = '{"delegatedRuns":{"mode":"off","runtimes":[],"roles":[],"maxRuns":0,"maxParallel":0}}' ]
  rm -rf "$tmpd"
}

@test "default: the compiler deny-capability table matches graph-runtime-capabilities" {
  # The compiler cannot source the bash capability table, so the duplicated set
  # is asserted against it here rather than left to drift.
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-runtime-capabilities.sh"
  local py_set rt bash_supported
  py_set="$(sed -n 's/^NATIVE_SUBAGENTS_OFF_SUPPORTED_RUNTIMES = {\(.*\)}$/\1/p' \
    "$REPO_ROOT/bundle/.ralph/bash-lib/plan-todo.sh" | tr -d '" ' | tr ',' '\n' | sort | tr '\n' ' ')"
  bash_supported=""
  for rt in cursor claude codex opencode antigravity; do
    if graph_runtime_native_subagents_off_supported "$rt"; then
      bash_supported="$bash_supported$rt\n"
    fi
  done
  bash_supported="$(printf "$bash_supported" | sort | tr '\n' ' ')"
  [ "$py_set" = "$bash_supported" ]
}

@test "removed: rejects stage subagents with migration guidance" {
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/plan-todo.sh"
  local tmpd plan_file
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/removed-subagents.plan.md"
  cat >"$plan_file" <<'EOF'
---
execution: graph
pipeline:
  stages:
    - id: source
      runtime: cursor
      subagents: inherit
todos:
  - id: source-1
    stage: source
    content: do work
    status: pending
---
EOF
  run plan_pipeline_graph_json "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"subagents: was removed"* ]] || [[ "$output" == *"subagents was removed"* ]]
  [[ "$output" == *"nativeSubagents"* ]]
  [[ "$output" != *"ralph migrate"* ]]
  rm -rf "$tmpd"
}

@test "removed: rejects delegation.native with migration guidance" {
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/plan-todo.sh"
  local tmpd plan_file
  tmpd="$(mktemp -d)"
  plan_file="$tmpd/removed-delegation-native.plan.md"
  cat >"$plan_file" <<'EOF'
---
execution: graph
pipeline:
  stages:
    - id: source
      runtime: cursor
      delegation:
        native:
          mode: read-only
          allowedAgents:
            - research
          maxParallel: 1
todos:
  - id: source-1
    stage: source
    content: do work
    status: pending
---
EOF
  run plan_pipeline_graph_json "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"delegation.native"* ]]
  [[ "$output" == *"was removed"* ]]
  [[ "$output" == *"nativeSubagents"* ]]
  [[ "$output" != *"ralph migrate"* ]]
  rm -rf "$tmpd"
}

# ---------------------------------------------------------------------------
# State / scheduler / status / resume: resolved nativeSubagents (roles redesign)
# ---------------------------------------------------------------------------

@test "scheduler: load_index stores resolved nativeSubagents and rejects on" {
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-schedule.sh"
  local graph
  graph="$TMPD/sched-load.graph.json"
  printf '%s\n' '{"schemaVersion":2,"ralphVersion":"1.0.0","name":"t","namespace":"t","maxParallel":1,"nodes":[{"id":"a","type":"agent","dependsOn":[],"stage":{"id":"a","runtime":"cursor","nativeSubagents":"inherit"}},{"id":"b","type":"agent","dependsOn":[],"stage":{"id":"b","runtime":"claude"}}],"edges":[]}' >"$graph"
  graph_schedule_load_index "$graph"
  [ "$(graph_schedule_node_native_subagents_by_id a)" = "inherit" ]
  [ "$(graph_schedule_node_native_subagents_by_id b)" = "off" ]
  [ "$(_graph_schedule_slots_for_node)" -eq 1 ]

  printf '%s\n' '{"schemaVersion":2,"ralphVersion":"1.0.0","name":"t","namespace":"t","maxParallel":1,"nodes":[{"id":"bad","type":"agent","dependsOn":[],"stage":{"id":"bad","runtime":"cursor","nativeSubagents":"on"}}],"edges":[]}' >"$graph"
  run graph_schedule_load_index "$graph"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid nativeSubagents"* ]]
}

@test "scheduler: admission logs nativeSubagents and never reserves child slots" {
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-schedule.sh"
  unset RALPH_PLAN_WORKSPACE_ROOT RALPH_GRAPH_STATE_ROOT
  graph="$TMPD/sched-admit.graph.json"
  admission="$TMPD/admission.jsonl"
  printf '%s\n' '{"schemaVersion":2,"ralphVersion":"1.0.0","name":"t","namespace":"t","maxParallel":2,"nodes":[{"id":"n1","type":"agent","dependsOn":[],"stage":{"id":"n1","runtime":"claude","nativeSubagents":"inherit"}}],"edges":[]}' >"$graph"
  graph_schedule_load_index "$graph"
  [[ ${#GRAPH_NODE_HELD_SLOTS[@]} -eq 1 ]]
  GRAPH_SCHEDULE_MAX_PARALLEL=2
  GRAPH_SCHEDULE_MAX_PARALLEL_PER_RUNTIME=2
  GRAPH_SCHEDULE_TOKEN_CAP=2
  GRAPH_SCHEDULE_ADMISSION_LOG_FILE="$admission"
  : >"$admission"
  reserve_err="$TMPD/reserve.err"
  _graph_schedule_runtime_reserve n1 claude inherit 2>"$reserve_err"
  [[ "${GRAPH_NODE_HELD_SLOTS[0]}" == "1" ]]
  [[ -s "$admission" ]]
  jq -s -e 'length == 1 and .[0].nativeSubagents == "inherit" and .[0].runtimeSlots == 1 and (.[0] | has("subagents") | not)' "$admission" >/dev/null
  ! grep -q 'reserves runtime=' "$reserve_err"
  _graph_schedule_runtime_release n1
  [[ "${GRAPH_NODE_HELD_SLOTS[0]}" == "0" ]]
  run graph_schedule_native_budget_preflight "$graph"
  [ "$status" -eq 0 ]
}

@test "state: ledger attempt records resolved nativeSubagents not subagents" {
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-state.sh"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-schedule.sh"
  unset RALPH_PLAN_WORKSPACE_ROOT RALPH_GRAPH_STATE_ROOT
  workspace="$TMPD/ws-state"
  state_ns="native-state"
  state_run="run-state-1"
  mkdir -p "$workspace"
  graph="$TMPD/state.graph.json"
  printf '%s\n' '{"schemaVersion":2,"ralphVersion":"1.0.0","name":"'"$state_ns"'","namespace":"'"$state_ns"'","maxParallel":1,"nodes":[{"id":"n1","type":"agent","dependsOn":[],"stage":{"id":"n1","runtime":"cursor","nativeSubagents":"inherit"}}],"edges":[]}' >"$graph"
  graph_schedule_load_index "$graph"
  graph_state_init_run "$workspace" "$state_ns" "$state_run" "$graph" "$graph" 1 >/dev/null
  GRAPH_SCHEDULE_WORKSPACE="$workspace"
  GRAPH_SCHEDULE_LEDGER_NAMESPACE="$state_ns"
  GRAPH_SCHEDULE_RUN_ID="$state_run"
  GRAPH_SCHEDULE_LEDGER_RUN_DIR="$(graph_state_run_dir "$workspace" "$state_ns" "$state_run")"
  GRAPH_SCHEDULE_GRAPH_JSON="$graph"
  [[ -n "$GRAPH_SCHEDULE_LEDGER_RUN_DIR" ]]
  _graph_schedule_ledger_record n1 running "n1__${state_run}__1" "" "" "2026-01-01T00:00:00Z" "" "cursor" "inherit" ""
  node_file="$(graph_state_node_file "$workspace" "$state_ns" "$state_run" "n1")"
  [ -f "$node_file" ]
  [ "$(jq -r '.attempts[0].nativeSubagents' "$node_file")" = "inherit" ]
  [ "$(jq -r '.attempts[0] | has("subagents")' "$node_file")" = "false" ]
}

@test "resume: rewritten attempts keep nativeSubagents provenance across writes" {
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-state.sh"
  unset RALPH_PLAN_WORKSPACE_ROOT RALPH_GRAPH_STATE_ROOT
  workspace="$TMPD/ws-resume"
  state_ns="native-resume"
  state_run="run-resume-1"
  mkdir -p "$workspace/.ralph-workspace/graph-runs/$state_ns/$state_run/nodes"
  graph_state_write_node "$workspace" "$state_ns" "$state_run" "n1" "running" \
    "n1__${state_run}__1" '{"startedAt":"2026-01-01T00:00:00Z","runtime":"cursor","nativeSubagents":"off"}'
  graph_state_write_node "$workspace" "$state_ns" "$state_run" "n1" "succeeded" \
    "n1__${state_run}__1" '{"outcome":"success","exitCode":0,"finishedAt":"2026-01-01T00:01:00Z","runtime":"cursor","nativeSubagents":"off"}' \
    '{"runtime":"cursor","nativeSubagents":"off"}'
  node_file="$(graph_state_node_file "$workspace" "$state_ns" "$state_run" "n1")"
  [ "$(jq -r '.attempts | length' "$node_file")" = "1" ]
  [ "$(jq -r '.attempts[0].nativeSubagents' "$node_file")" = "off" ]
  [ "$(jq -r '.nativeSubagents' "$node_file")" = "off" ]
  [ "$(jq -r 'has("subagents")' "$node_file")" = "false" ]
}

@test "status: details print nativeSubagents and omit reservation reductions" {
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-state.sh"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-status.sh"
  unset RALPH_PLAN_WORKSPACE_ROOT RALPH_GRAPH_STATE_ROOT
  workspace="$TMPD/ws-status"
  state_ns="native-status"
  state_run="run-status-1"
  mkdir -p "$workspace/.ralph-workspace/graph-runs/$state_ns/$state_run/nodes"
  graph_state_write_node "$workspace" "$state_ns" "$state_run" "n1" "succeeded" \
    "n1__${state_run}__1" \
    '{"outcome":"success","exitCode":0,"startedAt":"2026-01-01T00:00:00Z","finishedAt":"2026-01-01T00:01:00Z","runtime":"cursor","nativeSubagents":"inherit"}' \
    '{"nativeSubagents":"inherit","nativeSubagentMode":"inherit"}'
  node_file="$(graph_state_node_file "$workspace" "$state_ns" "$state_run" "n1")"
  run _graph_status_node_extra "$node_file" "n1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nativeSubagents=inherit"* ]]
  [[ "$output" != *"native-subagent-reservation"* ]]

  run_dir="$(graph_state_run_dir "$workspace" "$state_ns" "$state_run")"
  events='{"event":"admission","details":{"workKind":"graph-node","decision":"admitted","nativeSubagents":"inherit","sameRuntimeParallelSafe":true,"reason":"runtime-and-token-cap"}}'
  run _graph_status_concurrency_reductions "$run_dir" "$events"
  [ "$status" -eq 0 ]
  [[ "$output" != *"native-subagent-reservation"* ]]
}
