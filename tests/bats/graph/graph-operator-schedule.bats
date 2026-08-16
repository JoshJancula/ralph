#!/usr/bin/env bats
# Operator-permission pause: persist a request, await-operator, release slots.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-run-base.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-schedule.sh"

setup() {
  TMPD="$(mktemp -d)"
  RUN_DIR="$TMPD/run"
  mkdir -p "$RUN_DIR"
  export GRAPH_OPERATOR_NOW="2026-08-13T00:00:00Z"
  export GRAPH_OPERATOR_EXPIRES_AT="2026-08-13T01:00:00Z"
  export GRAPH_OPERATOR_NONCE="aabbccddeeff00112233445566778899"
  export GRAPH_OPERATOR_REQUEST_ID="op-impl-1"
  unset RALPH_GRAPH_STATE_ROOT RALPH_PLAN_WORKSPACE_ROOT GRAPH_DISPATCH_ORCHESTRATOR 2>/dev/null || true
}

teardown() {
  chmod -R u+w "$TMPD" 2>/dev/null || true
  rm -rf "$TMPD" 2>/dev/null || true
  unset GRAPH_OPERATOR_NOW GRAPH_OPERATOR_EXPIRES_AT GRAPH_OPERATOR_NONCE GRAPH_OPERATOR_REQUEST_ID 2>/dev/null || true
  unset GRAPH_DISPATCH_ORCHESTRATOR 2>/dev/null || true
  unset RALPH_GRAPH_STATE_ROOT RALPH_PLAN_WORKSPACE_ROOT GRAPH_DISPATCH_ORCHESTRATOR 2>/dev/null || true
  unset RALPH_ALLOW_NESTED_RUNS ORCHESTRATOR_RUNNER_TO_CONSOLE RALPH_MODE 2>/dev/null || true
  unset RALPH_ARTIFACT_NS RALPH_GRAPH_MAX_PARALLEL RALPH_GRAPH_MAX_PARALLEL_PER_RUNTIME 2>/dev/null || true
}

permission_report() {
  jq -nc '
    {
      schemaVersion: 1,
      outcome: "failed",
      exitCode: 4,
      permissionRequest: {
        tool: "Bash",
        rule: "Bash(rm:*)",
        decision: "pending"
      }
    }
  '
}

write_operator_pause_graph() {
  local out_path="$1"
  jq -n '
    {
      schemaVersion: 1,
      ralphVersion: "test",
      name: "operator-pause",
      namespace: "operator-pause",
      maxParallel: 1,
      failurePolicy: "cancel",
      nodes: [
        {
          id: "impl",
          type: "agent",
          dependsOn: [],
          derivedFrom: "stage",
          stage: {
            id: "impl",
            runtime: "cursor",
            agent: "implementation",
            workspaceMode: "snapshot",
            outputArtifacts: [{path: "stub-output.md", required: true}],
            _inlineTodos: [{id: "impl-1", content: "work impl", status: "pending"}]
          }
        },
        {
          id: "independent",
          type: "agent",
          dependsOn: [],
          derivedFrom: "stage",
          stage: {
            id: "independent",
            runtime: "claude",
            agent: "implementation",
            workspaceMode: "snapshot",
            outputArtifacts: [{path: "independent.md", required: true}],
            _inlineTodos: [{id: "independent-1", content: "work independent", status: "pending"}]
          }
        },
        {
          id: "child",
          type: "agent",
          dependsOn: ["impl"],
          derivedFrom: "stage",
          stage: {
            id: "child",
            runtime: "cursor",
            agent: "implementation",
            workspaceMode: "snapshot",
            _inlineTodos: [{id: "child-1", content: "work child", status: "pending"}]
          }
        }
      ],
      edges: [{from: "impl", to: "child", reasons: ["declared"]}]
    }
  ' >"$out_path"
}

install_operator_pause_orchestrator() {
  local orch="$1" marker_dir="$2" pause_stage="${3:-impl}"
  mkdir -p "$marker_dir"
  cat >"$orch" <<EOF
#!/usr/bin/env bash
set -euo pipefail
attempt=""
stage=""
prev=""
for arg in "\$@"; do
  if [[ "\$prev" == "--attempt-id" ]]; then
    attempt="\$arg"
  elif [[ "\$prev" == "--single-stage" ]]; then
    stage="\$arg"
  fi
  prev="\$arg"
done
workspace="\${RALPH_AGENT_WORKSPACE:-\$PWD}"
ns="\${RALPH_ARTIFACT_NS:-operator-pause}"
state_root="\${RALPH_PLAN_WORKSPACE_ROOT:-\$workspace/.ralph-workspace}"
report="\$state_root/artifacts/\$ns/stage-outcomes/\${attempt}.json"
mkdir -p "\$(dirname "\$report")" "$marker_dir"
: >"$marker_dir/\$stage.started"
if [[ "\$stage" == "$pause_stage" ]]; then
  printf '%s\n' "{\"schemaVersion\":1,\"runId\":\"operator-pause-run\",\"stageId\":\"\$stage\",\"attemptId\":\"\$attempt\",\"outcome\":\"failed\",\"exitCode\":4,\"permissionRequest\":{\"tool\":\"Bash\",\"rule\":\"Bash(rm:*)\",\"decision\":\"pending\"},\"startedAt\":\"2026-01-01T00:00:00Z\",\"finishedAt\":\"2026-01-01T00:00:01Z\"}" >"\$report"
  : >"$marker_dir/\$stage.finished"
  exit 4
fi
printf 'ok\n' >"\$workspace/\${stage}.md"
printf 'stub artifact\n' >"\$workspace/stub-output.md"
printf 'independent\n' >"\$workspace/independent.md"
printf '%s\n' "{\"schemaVersion\":1,\"runId\":\"operator-pause-run\",\"stageId\":\"\$stage\",\"attemptId\":\"\$attempt\",\"outcome\":\"success\",\"exitCode\":0,\"startedAt\":\"2026-01-01T00:00:02Z\",\"finishedAt\":\"2026-01-01T00:00:03Z\"}" >"\$report"
: >"$marker_dir/\$stage.finished"
exit 0
EOF
  chmod +x "$orch"
}

@test "operator schedule pause classifies exit 4 as operator-permission" {
  local class
  class="$(_graph_schedule_result_classification "$(permission_report)")"
  [ "$class" = "operator-permission" ]
  _graph_schedule_result_is_operator_permission "$(permission_report)"
}

@test "operator schedule pause persists a request and sets awaiting-operator" {
  local graph_file workspace ns run_id node_file aid path idx
  graph_file="$TMPD/operator-pause.graph.json"
  write_operator_pause_graph "$graph_file"
  workspace="$TMPD/ws"
  mkdir -p "$workspace"
  ns="operator-pause"
  run_id="run-operator-1"
  printf 'plan\n' >"$workspace/plan.md"
  graph_state_init_run_v2 "$workspace" "$ns" "$run_id" "$workspace/plan.md" "$graph_file" 1

  graph_schedule_load_index "$graph_file"
  GRAPH_SCHEDULE_GRAPH_JSON="$graph_file"
  GRAPH_SCHEDULE_WORKSPACE="$workspace"
  GRAPH_SCHEDULE_LEDGER_NAMESPACE="$ns"
  GRAPH_SCHEDULE_NAMESPACE="$ns"
  GRAPH_SCHEDULE_RUN_ID="$run_id"
  GRAPH_SCHEDULE_LEDGER_RUN_DIR="$(graph_state_run_dir "$workspace" "$ns" "$run_id")"
  GRAPH_SCHEDULE_LEDGER_SCHEMA_VERSION=""
  GRAPH_SCHEDULE_STOP_DISPATCH=0
  GRAPH_SCHEDULE_EXIT_CODE=0
  GRAPH_SCHEDULE_FAILED_NODE=""
  RUN_DIR="$GRAPH_SCHEDULE_LEDGER_RUN_DIR"

  aid="impl__${run_id}__1"
  _graph_schedule_ledger_record "impl" "running" "$aid" "" "" "2026-08-13T00:00:00Z" "" "cursor" "off" ""
  GRAPH_NODE_ATTEMPT_NUMBERS[$(graph_schedule_index_map_get impl)]="1"

  graph_schedule_apply_operator_permission "impl" 4 "operator-permission" "$aid" "$(permission_report)"
  [ "$(graph_schedule_node_state_by_id impl)" = "awaiting-operator" ]
  [ "$GRAPH_SCHEDULE_AWAITING_OPERATOR" -eq 1 ]
  [ "$GRAPH_SCHEDULE_STOP_DISPATCH" -eq 0 ]
  [ -z "$GRAPH_SCHEDULE_FAILED_NODE" ]
  [ "$GRAPH_SCHEDULE_EXIT_CODE" -eq 0 ]

  path="${GRAPH_SCHEDULE_OPERATOR_REQUEST_PATH:-}"
  [ -n "$path" ]
  [ -f "$path" ]
  [[ "$path" == */operator/requests/op-impl-1.json ]]
  [ "$(jq -r '.requestId' "$path")" = "op-impl-1" ]
  [ "$(jq -r '.classification' "$path")" = "operator-permission" ]
  [ "$(jq -r '.nodeId' "$path")" = "impl" ]
  [ "$(jq -r '.attemptId' "$path")" = "$aid" ]
  [ "$(jq -r '.action' "$path")" = "Bash" ]
  [ "$(jq -r '.resource' "$path")" = "Bash(rm:*)" ]
  [ "$(jq -r '.effect' "$path")" = "write" ]
  [ "$(jq -c '.choices' "$path")" = '["allow-once","allow-run","allow-always","deny"]' ]

  node_file="$(graph_state_node_file "$workspace" "$ns" "$run_id" "impl")"
  [ "$(jq -r '.status' "$node_file")" = "awaiting-operator" ]
  [ "$(jq -r '.attempts[0].attemptId' "$node_file")" = "$aid" ]
  [ "$(jq -r '.attempts[0].outcome' "$node_file")" = "awaiting-operator" ]
  [ "$(jq -r '.attempts[0].operatorRequestId' "$node_file")" = "op-impl-1" ]
  [ "$(jq -r '.attempts[0].retryClassification // empty' "$node_file")" = "" ]
  idx="$(graph_schedule_index_map_get impl)"
  [ "${GRAPH_NODE_CORRECTIVE_RETRIES_USED[$idx]}" = "0" ]
  [ ! -e "$RUN_DIR/corrections/impl.json" ]
}

@test "operator schedule pause releases concurrency and runtime slots" {
  local graph_file idx
  graph_file="$TMPD/operator-pause.graph.json"
  write_operator_pause_graph "$graph_file"
  graph_schedule_load_index "$graph_file"
  GRAPH_SCHEDULE_GRAPH_JSON="$graph_file"
  GRAPH_SCHEDULE_LEDGER_RUN_DIR=""
  GRAPH_SCHEDULE_STOP_DISPATCH=0
  GRAPH_SCHEDULE_MAX_PARALLEL=1
  GRAPH_SCHEDULE_MAX_PARALLEL_PER_RUNTIME=1
  GRAPH_SCHEDULE_TOKEN_CAP=1
  GRAPH_SCHEDULE_USED_TOKEN_SLOTS=0
  _graph_schedule_reset_runtime_occupancy

  idx="$(graph_schedule_index_map_get impl)"
  GRAPH_NODE_HELD_SLOTS[$idx]="1"
  GRAPH_NODE_HELD_TOKEN_SLOTS[$idx]="1"
  _graph_schedule_runtime_reserve_slots "cursor" 1 1
  [ "${GRAPH_NODE_HELD_SLOTS[$idx]}" = "1" ]
  [ "$GRAPH_SCHEDULE_USED_TOKEN_SLOTS" -eq 1 ]
  _graph_schedule_runtime_map_index "cursor"
  [ "${GRAPH_RUNTIME_USED_SLOTS[$GRAPH_RUNTIME_LOOKUP_IDX]}" -eq 1 ]

  graph_schedule_apply_operator_permission "impl" 4 "operator-permission" "impl__run-1__1" "$(permission_report)"
  [ "$(graph_schedule_node_state_by_id impl)" = "awaiting-operator" ]
  [ "${GRAPH_NODE_HELD_SLOTS[$idx]}" = "0" ]
  [ "${GRAPH_NODE_HELD_TOKEN_SLOTS[$idx]}" = "0" ]
  [ "$GRAPH_SCHEDULE_USED_TOKEN_SLOTS" -eq 0 ]
  _graph_schedule_runtime_map_index "cursor"
  [ "${GRAPH_RUNTIME_USED_SLOTS[$GRAPH_RUNTIME_LOOKUP_IDX]}" -eq 0 ]
  [ "$GRAPH_SCHEDULE_STOP_DISPATCH" -eq 0 ]
  [ "${GRAPH_NODE_CORRECTIVE_RETRIES_USED[$idx]}" = "0" ]
}

@test "operator schedule pause does not consume retry or stop independent dispatch" {
  local graph_file idx
  graph_file="$TMPD/operator-pause.graph.json"
  write_operator_pause_graph "$graph_file"
  graph_schedule_load_index "$graph_file"
  GRAPH_SCHEDULE_GRAPH_JSON="$graph_file"
  GRAPH_SCHEDULE_LEDGER_RUN_DIR=""
  GRAPH_SCHEDULE_STOP_DISPATCH=0
  GRAPH_SCHEDULE_FAILED_NODE=""
  GRAPH_SCHEDULE_EXIT_CODE=0
  GRAPH_SCHEDULE_FAILURE_POLICY="cancel"

  idx="$(graph_schedule_index_map_get impl)"
  GRAPH_NODE_CORRECTIVE_RETRIES_USED[$idx]="0"
  graph_schedule_apply_operator_permission "impl" 4 "operator-permission" "impl__run-1__1" "$(permission_report)"

  [ "$(graph_schedule_node_state_by_id impl)" = "awaiting-operator" ]
  [ "$(graph_schedule_node_state_by_id independent)" = "pending" ]
  [ "$(graph_schedule_node_state_by_id child)" = "blocked" ]
  [ "$GRAPH_SCHEDULE_STOP_DISPATCH" -eq 0 ]
  [ -z "$GRAPH_SCHEDULE_FAILED_NODE" ]
  [ "$GRAPH_SCHEDULE_EXIT_CODE" -eq 0 ]
  [ "${GRAPH_NODE_CORRECTIVE_RETRIES_USED[$idx]}" = "0" ]
  [ "$GRAPH_SCHEDULE_CANCEL_REQUESTED" -eq 0 ]
  [ ! -e "$TMPD/run/corrections/impl.json" ]
}

@test "operator schedule pause continues independent branches" {
  local graph_file state_root run_id run_dir roots_json marker_dir orch rc node_file
  graph_file="$TMPD/operator-pause.graph.json"
  write_operator_pause_graph "$graph_file"

  DISPATCH_WORKSPACE="$TMPD/workspace"
  mkdir -p "$DISPATCH_WORKSPACE/.ralph" "$DISPATCH_WORKSPACE/.ralph-workspace"
  printf 'plan\n' >"$DISPATCH_WORKSPACE/operator-pause.plan.md"

  marker_dir="$TMPD/markers"
  orch="$TMPD/orchestrator.sh"
  install_operator_pause_orchestrator "$orch" "$marker_dir" "impl"
  export GRAPH_DISPATCH_ORCHESTRATOR="$orch"
  export RALPH_ALLOW_NESTED_RUNS=1
  export ORCHESTRATOR_RUNNER_TO_CONSOLE=0
  export RALPH_MODE=no
  export RALPH_ARTIFACT_SCHEMA_VALIDATION=0
  export RALPH_ARTIFACT_PROVENANCE=0
  export RALPH_GRAPH_MAX_PARALLEL=1
  export RALPH_GRAPH_MAX_PARALLEL_PER_RUNTIME=1
  export GRAPH_OPERATOR_REQUEST_ID="op-impl-1"

  state_root="$TMPD/state"
  run_id="operator-pause-run"
  export RALPH_GRAPH_STATE_ROOT="$state_root"
  export RALPH_PLAN_WORKSPACE_ROOT="$state_root"
  graph_state_init_run_v2 "$DISPATCH_WORKSPACE" operator-pause "$run_id" \
    "$DISPATCH_WORKSPACE/operator-pause.plan.md" "$graph_file" 1
  run_dir="$state_root/graph-runs/operator-pause/$run_id"
  roots_json="$(jq -cn --arg project "$DISPATCH_WORKSPACE" --arg state "$state_root" \
    '{projectRoot:$project,stateRoot:$state,agentWorkspace:$project}')"
  graph_run_base_prepare "$run_dir" "$roots_json" '["snapshot"]'
  graph_workspace_prepare_run "$run_dir" "$graph_file"

  rc=0
  graph_schedule_run "$graph_file" "$run_id" "$DISPATCH_WORKSPACE" "$run_dir" || rc=$?
  [ "$GRAPH_SCHEDULE_STOP_DISPATCH" -eq 0 ]
  [ "$(graph_schedule_node_state_by_id impl)" = "awaiting-operator" ]
  [ "$(graph_schedule_node_state_by_id independent)" = "succeeded" ]
  [ "$(graph_schedule_node_state_by_id child)" = "blocked" ]
  [ -f "$marker_dir/independent.finished" ]
  [ ! -f "$marker_dir/child.started" ]
  [ -f "$run_dir/operator/requests/op-impl-1.json" ]
  [ "$(jq -r '.classification' "$run_dir/operator/requests/op-impl-1.json")" = "operator-permission" ]
  node_file="$(graph_state_node_file "$DISPATCH_WORKSPACE" operator-pause "$run_id" impl)"
  [ "$(jq -r '.status' "$node_file")" = "awaiting-operator" ]
  [ "$(jq -r '.attempts[0].outcome' "$node_file")" = "awaiting-operator" ]
  [ "$(jq -r '.attempts[0].operatorRequestId' "$node_file")" = "op-impl-1" ]
  [ "$(jq -r '.attempts[0].retryClassification // empty' "$node_file")" = "" ]
  [ "${GRAPH_NODE_CORRECTIVE_RETRIES_USED[$(graph_schedule_index_map_get impl)]}" = "0" ]
  [ ! -e "$run_dir/corrections/impl.json" ]
  [ -z "$GRAPH_SCHEDULE_FAILED_NODE" ]
  [ "$rc" -ne 0 ]
}

write_operator_decision() {
  local run_dir="$1" request_id="$2" decision="${3:-allow-once}"
  local req
  req="$(graph_operator_request_read "$run_dir" "$request_id")"
  graph_operator_decision_write "$run_dir" "$(jq -nc --argjson req "$req" --arg d "$decision" '
    {
      requestId: $req.requestId,
      nonce: $req.nonce,
      namespace: $req.namespace,
      runId: $req.runId,
      nodeId: $req.nodeId,
      attemptId: $req.attemptId,
      runtime: $req.runtime,
      decision: $d,
      actorSource: "test",
      decidedAt: "2026-08-13T00:00:00Z"
    }
  ')"
}

setup_operator_decision_pause() {
  local graph_file="$1" workspace="$2" ns="$3" run_id="$4"
  printf 'plan\n' >"$workspace/plan.md"
  graph_state_init_run_v2 "$workspace" "$ns" "$run_id" "$workspace/plan.md" "$graph_file" 1
  graph_schedule_load_index "$graph_file"
  GRAPH_SCHEDULE_GRAPH_JSON="$graph_file"
  GRAPH_SCHEDULE_WORKSPACE="$workspace"
  GRAPH_SCHEDULE_LEDGER_NAMESPACE="$ns"
  GRAPH_SCHEDULE_NAMESPACE="$ns"
  GRAPH_SCHEDULE_RUN_ID="$run_id"
  GRAPH_SCHEDULE_LEDGER_RUN_DIR="$(graph_state_run_dir "$workspace" "$ns" "$run_id")"
  GRAPH_SCHEDULE_LEDGER_SCHEMA_VERSION=""
  GRAPH_SCHEDULE_STOP_DISPATCH=0
  GRAPH_SCHEDULE_EXIT_CODE=0
  GRAPH_SCHEDULE_FAILED_NODE=""
  GRAPH_SCHEDULE_AWAITING_OPERATOR=0
  RUN_DIR="$GRAPH_SCHEDULE_LEDGER_RUN_DIR"
}

@test "operator schedule decision consumes a valid decision once" {
  local graph_file workspace ns run_id aid path consumed
  graph_file="$TMPD/operator-decision.graph.json"
  write_operator_pause_graph "$graph_file"
  workspace="$TMPD/ws"
  mkdir -p "$workspace"
  ns="operator-pause"
  run_id="run-decision-1"
  setup_operator_decision_pause "$graph_file" "$workspace" "$ns" "$run_id"

  aid="impl__${run_id}__1"
  _graph_schedule_ledger_record "impl" "running" "$aid" "" "" "2026-08-13T00:00:00Z" "" "cursor" "off" ""
  GRAPH_NODE_ATTEMPT_NUMBERS[$(graph_schedule_index_map_get impl)]="1"
  graph_schedule_apply_operator_permission "impl" 4 "operator-permission" "$aid" "$(permission_report)"
  [ "$(graph_schedule_node_state_by_id impl)" = "awaiting-operator" ]

  path="$(write_operator_decision "$RUN_DIR" "op-impl-1" "allow-once")"
  [ -f "$path" ]
  [ "$(jq -r '.decision' "$path")" = "allow-once" ]

  consumed="$(graph_schedule_consume_operator_decision "$RUN_DIR" "op-impl-1")"
  [ -f "$consumed" ]
  [[ "$consumed" == */operator/consumed/op-impl-1.json ]]
  [ "$(jq -r '.requestId' "$consumed")" = "op-impl-1" ]
  [ "$(jq -r '.decision' "$consumed")" = "allow-once" ]
  [ "$(jq -r '.path' "$consumed")" = "adapter-continuation" ]
  [ "$(jq -r '.consumedAt' "$consumed")" = "2026-08-13T00:00:00Z" ]
  graph_schedule_operator_decision_is_consumed "$RUN_DIR" "op-impl-1"

  run graph_schedule_consume_operator_decision "$RUN_DIR" "op-impl-1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"already consumed"* ]]
  [ "$(jq -r '.consumedAt' "$consumed")" = "2026-08-13T00:00:00Z" ]
  [ "$(jq -r '.decision' "$path")" = "allow-once" ]
}

@test "operator schedule decision allow uses adapter continuation path" {
  local graph_file workspace ns run_id aid record
  graph_file="$TMPD/operator-decision.graph.json"
  write_operator_pause_graph "$graph_file"
  workspace="$TMPD/ws"
  mkdir -p "$workspace"
  ns="operator-pause"
  run_id="run-decision-allow"
  setup_operator_decision_pause "$graph_file" "$workspace" "$ns" "$run_id"

  aid="impl__${run_id}__1"
  _graph_schedule_ledger_record "impl" "running" "$aid" "" "" "2026-08-13T00:00:00Z" "" "cursor" "off" ""
  GRAPH_NODE_ATTEMPT_NUMBERS[$(graph_schedule_index_map_get impl)]="1"
  graph_schedule_apply_operator_permission "impl" 4 "operator-permission" "$aid" "$(permission_report)"
  write_operator_decision "$RUN_DIR" "op-impl-1" "allow-once" >/dev/null

  graph_schedule_apply_operator_decision "impl" "op-impl-1" >"$TMPD/allow.path"
  record="$(cat "$TMPD/allow.path")"
  [ -f "$record" ]
  [[ "$record" == */operator/continuations/op-impl-1.json ]]
  [ "$(jq -r '.path' "$record")" = "adapter-continuation" ]
  [ "$(jq -r '.decision' "$record")" = "allow-once" ]
  [ "$(jq -r '.requestId' "$record")" = "op-impl-1" ]
  [ "$(jq -r '.nextAttemptNumber' "$record")" = "2" ]
  [ "$(jq -r '.granted.action' "$record")" = "Bash" ]
  ! jq -e '.prompt or .output or .rawOutput or .stdout or .stderr or .text' "$record" >/dev/null
  [ "$(graph_schedule_node_state_by_id impl)" = "pending" ]
  [ "$GRAPH_SCHEDULE_AWAITING_OPERATOR" -eq 0 ]
  graph_schedule_operator_decision_is_consumed "$RUN_DIR" "op-impl-1"

  GRAPH_SCHEDULE_SPAWN_OPERATOR_RECORD=""
  GRAPH_SCHEDULE_SPAWN_OPERATOR_PATH_KIND=""
  _graph_schedule_prepare_operator_decision_spawn "impl" "2" ""
  [ "$GRAPH_SCHEDULE_SPAWN_OPERATOR_RECORD" = "$record" ]
  [ "$GRAPH_SCHEDULE_SPAWN_OPERATOR_PATH_KIND" = "adapter-continuation" ]

  _graph_schedule_prepare_operator_decision_spawn "impl" "1" ""
  [ -z "$GRAPH_SCHEDULE_SPAWN_OPERATOR_RECORD" ]
  [ -z "$GRAPH_SCHEDULE_SPAWN_OPERATOR_PATH_KIND" ]

  run graph_schedule_apply_operator_decision "impl" "op-impl-1"
  [ "$status" -ne 0 ]
}

@test "operator schedule decision deny permits at most one compact alternative turn" {
  local graph_file workspace ns run_id aid record idx path rc
  graph_file="$TMPD/operator-decision.graph.json"
  write_operator_pause_graph "$graph_file"
  workspace="$TMPD/ws"
  mkdir -p "$workspace"
  ns="operator-pause"
  run_id="run-decision-deny"
  setup_operator_decision_pause "$graph_file" "$workspace" "$ns" "$run_id"

  aid="impl__${run_id}__1"
  _graph_schedule_ledger_record "impl" "running" "$aid" "" "" "2026-08-13T00:00:00Z" "" "cursor" "off" ""
  GRAPH_NODE_ATTEMPT_NUMBERS[$(graph_schedule_index_map_get impl)]="1"
  graph_schedule_apply_operator_permission "impl" 4 "operator-permission" "$aid" "$(permission_report)"
  write_operator_decision "$RUN_DIR" "op-impl-1" "deny" >/dev/null

  graph_schedule_apply_operator_decision "impl" "op-impl-1" >"$TMPD/deny.path"
  record="$(cat "$TMPD/deny.path")"
  [ -f "$record" ]
  [[ "$record" == */operator/alternatives/impl.json ]]
  [ "$(jq -r '.path' "$record")" = "compact-alternative" ]
  [ "$(jq -r '.decision' "$record")" = "deny" ]
  [ "$(jq -r '.nextAttemptNumber' "$record")" = "2" ]
  ! jq -e '.prompt or .output or .rawOutput or .stdout or .stderr or .text' "$record" >/dev/null
  [ "$(graph_schedule_node_state_by_id impl)" = "pending" ]
  idx="$(graph_schedule_index_map_get impl)"
  [ "${GRAPH_NODE_OPERATOR_DENY_TURNS_USED[$idx]}" = "1" ]
  [ "${GRAPH_NODE_CORRECTIVE_RETRIES_USED[$idx]}" = "0" ]

  run graph_schedule_write_operator_alternative_turn "$RUN_DIR" "impl" "op-impl-1" "3"
  [ "$status" -ne 0 ]
  [[ "$output" == *"already used"* ]]

  GRAPH_SCHEDULE_SPAWN_OPERATOR_RECORD=""
  GRAPH_SCHEDULE_SPAWN_OPERATOR_PATH_KIND=""
  _graph_schedule_prepare_operator_decision_spawn "impl" "2" ""
  [ "$GRAPH_SCHEDULE_SPAWN_OPERATOR_RECORD" = "$record" ]
  [ "$GRAPH_SCHEDULE_SPAWN_OPERATOR_PATH_KIND" = "compact-alternative" ]

  export GRAPH_OPERATOR_REQUEST_ID="op-impl-2"
  GRAPH_NODE_STATES[$idx]="awaiting-operator"
  GRAPH_SCHEDULE_AWAITING_OPERATOR=1
  aid="impl__${run_id}__2"
  GRAPH_NODE_ATTEMPT_NUMBERS[$idx]="2"
  _graph_schedule_ledger_record "impl" "running" \
    "$aid" "" "" "2026-08-13T00:00:02Z" "" "cursor" "off" ""
  _graph_schedule_ledger_record "impl" "awaiting-operator" \
    "$aid" "awaiting-operator" "4" "" "2026-08-13T00:00:03Z" \
    "cursor" "off" "operator-permission" '{"operatorRequestId":"op-impl-2"}'
  graph_schedule_persist_operator_request "impl" "$aid" "$(permission_report)" >/dev/null
  write_operator_decision "$RUN_DIR" "op-impl-2" "deny" >/dev/null
  rc=0
  graph_schedule_apply_operator_decision "impl" "op-impl-2" >"$TMPD/deny2.path" || rc=$?
  [ "$rc" -ne 0 ]
  [ "$(graph_schedule_node_state_by_id impl)" = "failed" ]
  [ "$(jq -r '.path' "$record")" = "compact-alternative" ]
  [ "$(jq -r '.nextAttemptNumber' "$record")" = "2" ]
  unset GRAPH_OPERATOR_REQUEST_ID
}

@test "operator schedule decision exits 3 only when wait is unresolved and no work remains" {
  local graph_file state_root run_id run_dir roots_json marker_dir orch rc
  graph_file="$TMPD/operator-pause.graph.json"
  write_operator_pause_graph "$graph_file"

  DISPATCH_WORKSPACE="$TMPD/workspace"
  mkdir -p "$DISPATCH_WORKSPACE/.ralph" "$DISPATCH_WORKSPACE/.ralph-workspace"
  printf 'plan\n' >"$DISPATCH_WORKSPACE/operator-pause.plan.md"

  marker_dir="$TMPD/markers"
  orch="$TMPD/orchestrator.sh"
  install_operator_pause_orchestrator "$orch" "$marker_dir" "impl"
  export GRAPH_DISPATCH_ORCHESTRATOR="$orch"
  export RALPH_ALLOW_NESTED_RUNS=1
  export ORCHESTRATOR_RUNNER_TO_CONSOLE=0
  export RALPH_MODE=no
  export RALPH_ARTIFACT_SCHEMA_VALIDATION=0
  export RALPH_ARTIFACT_PROVENANCE=0
  export RALPH_GRAPH_MAX_PARALLEL=1
  export RALPH_GRAPH_MAX_PARALLEL_PER_RUNTIME=1
  export GRAPH_OPERATOR_REQUEST_ID="op-impl-1"

  state_root="$TMPD/state"
  run_id="operator-decision-exit"
  export RALPH_GRAPH_STATE_ROOT="$state_root"
  export RALPH_PLAN_WORKSPACE_ROOT="$state_root"
  graph_state_init_run_v2 "$DISPATCH_WORKSPACE" operator-pause "$run_id" \
    "$DISPATCH_WORKSPACE/operator-pause.plan.md" "$graph_file" 1
  run_dir="$state_root/graph-runs/operator-pause/$run_id"
  roots_json="$(jq -cn --arg project "$DISPATCH_WORKSPACE" --arg state "$state_root" \
    '{projectRoot:$project,stateRoot:$state,agentWorkspace:$project}')"
  graph_run_base_prepare "$run_dir" "$roots_json" '["snapshot"]'
  graph_workspace_prepare_run "$run_dir" "$graph_file"

  rc=0
  graph_schedule_run "$graph_file" "$run_id" "$DISPATCH_WORKSPACE" "$run_dir" || rc=$?
  [ "$rc" -eq 3 ]
  [ -z "$GRAPH_SCHEDULE_FAILED_NODE" ]
  [ "$GRAPH_SCHEDULE_AWAITING_OPERATOR" -eq 1 ]
  [ "$(graph_schedule_node_state_by_id impl)" = "awaiting-operator" ]
  [ "$(graph_schedule_node_state_by_id independent)" = "succeeded" ]
  [ "$(graph_schedule_node_state_by_id child)" = "blocked" ]
  [ -f "$marker_dir/independent.finished" ]
  [ ! -f "$marker_dir/child.started" ]
  [ -f "$run_dir/operator/requests/op-impl-1.json" ]
  [ ! -e "$run_dir/operator/consumed/op-impl-1.json" ]
}

@test "operator schedule decision allow resumes through adapter continuation" {
  local graph_file state_root run_id run_dir roots_json marker_dir orch rc plan_file
  local node_file record
  graph_file="$TMPD/operator-pause.graph.json"
  write_operator_pause_graph "$graph_file"

  DISPATCH_WORKSPACE="$TMPD/workspace"
  mkdir -p "$DISPATCH_WORKSPACE/.ralph" "$DISPATCH_WORKSPACE/.ralph-workspace"
  plan_file="$DISPATCH_WORKSPACE/operator-pause.plan.md"
  cat >"$plan_file" <<'EOF'
---
name: operator-pause
namespace: operator-pause
execution: graph
pipeline:
  stages:
    - id: impl
      runtime: cursor
      agent: implementation
    - id: independent
      runtime: claude
      agent: implementation
    - id: child
      runtime: cursor
      agent: implementation
      dependsOn:
        - impl
todos:
  - id: impl-1
    stage: impl
    content: work impl
    status: pending
  - id: independent-1
    stage: independent
    content: work independent
    status: pending
  - id: child-1
    stage: child
    content: work child
    status: pending
---
EOF

  marker_dir="$TMPD/markers"
  orch="$TMPD/orchestrator.sh"
  cat >"$orch" <<EOF
#!/usr/bin/env bash
set -euo pipefail
attempt=""
stage=""
prev=""
for arg in "\$@"; do
  if [[ "\$prev" == "--attempt-id" ]]; then
    attempt="\$arg"
  elif [[ "\$prev" == "--single-stage" ]]; then
    stage="\$arg"
  fi
  prev="\$arg"
done
workspace="\${RALPH_AGENT_WORKSPACE:-\$PWD}"
ns="\${RALPH_ARTIFACT_NS:-operator-pause}"
state_root="\${RALPH_PLAN_WORKSPACE_ROOT:-\$workspace/.ralph-workspace}"
report="\$state_root/artifacts/\$ns/stage-outcomes/\${attempt}.json"
mkdir -p "\$(dirname "\$report")" "$marker_dir"
: >"$marker_dir/\$stage.started"
if [[ "\$stage" == "impl" && -z "\${RALPH_GRAPH_APPROVAL_PATH:-}" ]]; then
  printf '%s\n' "{\"schemaVersion\":1,\"runId\":\"operator-pause-run\",\"stageId\":\"\$stage\",\"attemptId\":\"\$attempt\",\"outcome\":\"failed\",\"exitCode\":4,\"permissionRequest\":{\"tool\":\"Bash\",\"rule\":\"Bash(rm:*)\",\"decision\":\"pending\"},\"startedAt\":\"2026-01-01T00:00:00Z\",\"finishedAt\":\"2026-01-01T00:00:01Z\"}" >"\$report"
  : >"$marker_dir/\$stage.finished"
  exit 4
fi
if [[ -n "\${RALPH_GRAPH_OPERATOR_DECISION:-}" ]]; then
  printf '%s\n' "\$RALPH_GRAPH_OPERATOR_DECISION" >"$marker_dir/operator-decision-path"
  printf '%s\n' "\${RALPH_GRAPH_APPROVAL_PATH:-}" >"$marker_dir/approval-path"
  printf '%s\n' "\${RALPH_PLAN_SESSION_STRATEGY:-}" >"$marker_dir/session-strategy"
  printf '%s\n' "\${RALPH_PLAN_CLI_RESUME:-}" >"$marker_dir/cli-resume"
  printf '%s\n' "\${RALPH_GRAPH_PROMPT-__unset__}" >"$marker_dir/graph-prompt"
fi
printf 'ok\n' >"\$workspace/\${stage}.md"
printf 'stub artifact\n' >"\$workspace/stub-output.md"
printf 'independent\n' >"\$workspace/independent.md"
printf '%s\n' "{\"schemaVersion\":1,\"runId\":\"operator-pause-run\",\"stageId\":\"\$stage\",\"attemptId\":\"\$attempt\",\"outcome\":\"success\",\"exitCode\":0,\"startedAt\":\"2026-01-01T00:00:02Z\",\"finishedAt\":\"2026-01-01T00:00:03Z\"}" >"\$report"
: >"$marker_dir/\$stage.finished"
exit 0
EOF
  chmod +x "$orch"
  export GRAPH_DISPATCH_ORCHESTRATOR="$orch"
  export RALPH_ALLOW_NESTED_RUNS=1
  export ORCHESTRATOR_RUNNER_TO_CONSOLE=0
  export RALPH_MODE=no
  export RALPH_ARTIFACT_SCHEMA_VALIDATION=0
  export RALPH_ARTIFACT_PROVENANCE=0
  export RALPH_GRAPH_MAX_PARALLEL=1
  export RALPH_GRAPH_MAX_PARALLEL_PER_RUNTIME=1
  export GRAPH_OPERATOR_REQUEST_ID="op-impl-1"

  state_root="$TMPD/state"
  run_id="operator-decision-allow-run"
  export RALPH_GRAPH_STATE_ROOT="$state_root"
  export RALPH_PLAN_WORKSPACE_ROOT="$state_root"
  graph_state_init_run_v2 "$DISPATCH_WORKSPACE" operator-pause "$run_id" \
    "$plan_file" "$graph_file" 1
  run_dir="$state_root/graph-runs/operator-pause/$run_id"
  roots_json="$(jq -cn --arg project "$DISPATCH_WORKSPACE" --arg state "$state_root" \
    '{projectRoot:$project,stateRoot:$state,agentWorkspace:$project}')"
  graph_run_base_prepare "$run_dir" "$roots_json" '["snapshot"]'
  graph_workspace_prepare_run "$run_dir" "$graph_file"

  rc=0
  graph_schedule_run "$graph_file" "$run_id" "$DISPATCH_WORKSPACE" "$run_dir" || rc=$?
  [ "$rc" -eq 3 ]
  [ "$(graph_schedule_node_state_by_id impl)" = "awaiting-operator" ]
  [ "$(graph_schedule_node_state_by_id independent)" = "succeeded" ]

  write_operator_decision "$run_dir" "op-impl-1" "allow-once" >/dev/null
  graph_state_set_run_status "$DISPATCH_WORKSPACE" operator-pause "$run_id" "awaiting-operator"

  rc=0
  graph_schedule_resume "$DISPATCH_WORKSPACE" operator-pause "$run_id" "$plan_file" \
    --frozen-graph "$graph_file" --accept-graph-change || rc=$?
  [ "$rc" -eq 0 ]
  [ "$(graph_schedule_node_state_by_id impl)" = "succeeded" ]
  [ "$(graph_schedule_node_state_by_id independent)" = "succeeded" ]
  [ "$(graph_schedule_node_state_by_id child)" = "succeeded" ]
  [ -f "$marker_dir/operator-decision-path" ]
  record="$(cat "$marker_dir/operator-decision-path")"
  [ -f "$record" ]
  [ "$(jq -r '.path' "$record")" = "adapter-continuation" ]
  [ "$(cat "$marker_dir/approval-path")" = "adapter-continuation" ]
  [ "$(cat "$marker_dir/session-strategy")" = "resume" ]
  [ "$(cat "$marker_dir/cli-resume")" = "1" ]
  [ "$(cat "$marker_dir/graph-prompt")" = "__unset__" ]
  node_file="$(graph_state_node_file "$DISPATCH_WORKSPACE" operator-pause "$run_id" impl)"
  [ "$(jq -r '.status' "$node_file")" = "succeeded" ]
  [ "$(jq '.attempts | length' "$node_file")" -ge 2 ]
}
