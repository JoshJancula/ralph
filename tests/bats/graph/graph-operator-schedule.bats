#!/usr/bin/env bats
# graph-operator-schedule: library-level tests. No real dispatch.

source "$BATS_TEST_DIRNAME/test_helper/graph-operator-schedule-shared.bash"

@test "live progress follow command translates internal attempt identity to public attempt number" {
  GRAPH_SCHEDULE_RUN_ID="run-20260901T044156Z-0-1EVnfm"

  run _graph_schedule_live_progress_follow_command \
    "review" "review__run-20260901T044156Z-0-1EVnfm__3"
  [ "$status" -eq 0 ]
  [ "$output" = "ralph workflow logs run-20260901T044156Z-0-1EVnfm --stage review --attempt 3" ]
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
  graph_state_init_run "$workspace" "$ns" "$run_id" "$workspace/plan.md" "$graph_file" 1

  graph_schedule_load_index "$graph_file"
  GRAPH_SCHEDULE_GRAPH_JSON="$graph_file"
  GRAPH_SCHEDULE_WORKSPACE="$workspace"
  GRAPH_SCHEDULE_LEDGER_NAMESPACE="$ns"
  GRAPH_SCHEDULE_NAMESPACE="$ns"
  GRAPH_SCHEDULE_RUN_ID="$run_id"
  GRAPH_SCHEDULE_LEDGER_RUN_DIR="$(graph_state_run_dir "$workspace" "$ns" "$run_id")"
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
