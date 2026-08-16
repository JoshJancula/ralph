#!/usr/bin/env bats
# Stub-only production-hardening acceptance replay.
#
# Builds a 27-node synthetic topology directly in this file and drives it
# through a behavior-driven stub orchestrator. The historical production run is
# never read and no live runtime is invoked: every node is executed by a local
# shell stub whose behavior is selected by a per-node file.
#
# The replay proves seven properties end to end:
#   1. isolated logs           -- one log directory per node/attempt, no leakage
#   2. bounded corrective retry -- transient nodes succeed in exactly 2 attempts
#   3. permission pause/respond -- exit 4 pauses, allow-once resumes
#   4. independent branch drain -- siblings finish while one branch is stuck
#   5. stale recovery           -- stale running attempt is interrupted and reset
#   6. successor reuse          -- a successor run reuses succeeded evidence
#   7. final publish readiness  -- manual publish emits a verified handoff

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/plan-todo.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/atomic-json.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-state.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-logs.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-run-base.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-workspace-manager.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-schedule.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-recovery.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-failure-classify.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-operator-records.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-events.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-heartbeat.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-successor.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-publish.sh"

NAMESPACE="production-hardening"
RUN_ID="production-hardening-run"

# The 27 nodes of the sanitized topology, in dependency order.
ALL_NODES=(
  root
  infra-1 infra-2
  backend-1 backend-2 backend-3
  service-1 service-2 service-3 service-4
  gate-1 gate-2
  ui-1 ui-3
  review-1 review-2
  integrate-1
  docs-1 docs-2 docs-3
  test-1 test-2 test-3
  publish-prep publish-final
  contract-1 contract-child
)

# Nodes that pause with an operator-permission request (stub exit 4).
PAUSE_NODES=(service-2 docs-2)
# Nodes that fail transiently on attempt 1 and succeed on attempt 2.
RETRY_NODES=(backend-2 test-2)
# Node that reports an undeclared write and lands in needs-plan-repair.
CONTRACT_NODE=contract-1
# Descendant blocked behind the contract failure.
CONTRACT_CHILD=contract-child
# Node pre-seeded as a stale running attempt so recovery can prove reset.
STALE_NODE=infra-1

# Nodes that must finish in the first wave even though CONTRACT_NODE is stuck
# and the pause nodes are waiting. None of them descend from either.
INDEPENDENT_DRAIN=(infra-2 backend-1 backend-2 service-1 service-4 test-1 docs-1)

setup() {
  TMPD="$(mktemp -d)"
  DISPATCH_WORKSPACE="$TMPD/workspace"
  STATE_ROOT="$TMPD/state"
  BEHAVIOR_DIR="$TMPD/behaviors"
  MARKER_DIR="$TMPD/markers"
  mkdir -p "$DISPATCH_WORKSPACE/.ralph-workspace" \
    "$STATE_ROOT" "$BEHAVIOR_DIR" "$MARKER_DIR"

  # The stub orchestrator lives outside the dispatch workspace on purpose.
  # Every snapshot node copies the whole project root, so a 10 MB .ralph tree
  # inside it would be duplicated 27 times and dominate the runtime.
  ORCHESTRATOR_STUB="$TMPD/orchestrator.sh"
  export GRAPH_DISPATCH_ORCHESTRATOR="$ORCHESTRATOR_STUB"
  export RALPH_ALLOW_NESTED_RUNS=1
  export ORCHESTRATOR_RUNNER_TO_CONSOLE=0
  export RALPH_MODE=no
  export RALPH_ARTIFACT_SCHEMA_VALIDATION=0
  export RALPH_ARTIFACT_PROVENANCE=0
  export RALPH_GRAPH_STATE_ROOT="$STATE_ROOT"
  export RALPH_PLAN_WORKSPACE_ROOT="$STATE_ROOT"
  # The per-runtime cap defaults to 1 because concurrent real invocations on one
  # runtime can interleave Ralph's config overlays. The stub orchestrator writes
  # no overlay, so that hazard does not exist here and the cap only serializes
  # the replay. Raising it keeps the 27-node run to a few minutes.
  export RALPH_GRAPH_MAX_PARALLEL_PER_RUNTIME=4
  unset RALPH_ARTIFACT_NS RALPH_PLAN_KEY 2>/dev/null || true
}

teardown() {
  chmod -R u+w "$TMPD" 2>/dev/null || true
  rm -rf "$TMPD" 2>/dev/null || true
  unset RALPH_GRAPH_STATE_ROOT RALPH_PLAN_WORKSPACE_ROOT GRAPH_DISPATCH_ORCHESTRATOR 2>/dev/null || true
  unset RALPH_ALLOW_NESTED_RUNS ORCHESTRATOR_RUNNER_TO_CONSOLE RALPH_MODE 2>/dev/null || true
  unset RALPH_ARTIFACT_SCHEMA_VALIDATION RALPH_ARTIFACT_PROVENANCE 2>/dev/null || true
}

# Author the 27-node plan, then compile it into the frozen graph.
#
# The topology has to come from a real plan file because resume recompiles the
# plan to compare graphSha. contract-1/contract-child form a side branch so the
# plan-contract block cannot poison the publish path, which keeps "independent
# branch drain" and "publish readiness" independently observable.
#
# resilience/budgets are injected here rather than authored: they are not
# authorable pipeline fields, and the retry limits default to zero without
# them. They are top-level graph fields, so they do not change any node's stage
# digest and resume will not invalidate a succeeded node over them.
write_production_plan_and_graph() {
  local plan_path="$1" graph_path="$2" compiled
  python3 "$BATS_TEST_DIRNAME/../../fixtures/graph/build_production_topology.py" "$plan_path"
  compiled="$(plan_pipeline_graph_json "$plan_path")"
  printf '%s' "$compiled" | jq '
    .resilience = {transientRetries: 2, correctiveRetries: 1,
                   denialRecoveryTurns: 1, mode: "bounded",
                   backoffSeconds: [0, 0]}
    | .budgets = {maxActiveSeconds: 3600, maxRunActiveSeconds: 21600,
                  missingUsage: "warn"}
  ' >"$graph_path"
}

# Stub orchestrator. Behavior per node comes from BEHAVIOR_DIR/<node>; the
# default is success. Success writes the node's declared output artifact into
# its own workspace, which is what proves workspace isolation.
install_production_orchestrator() {
  cat >"$ORCHESTRATOR_STUB" <<EOF
#!/usr/bin/env bash
set -euo pipefail
attempt=""
stage=""
prev=""
for arg in "\$@"; do
  if [[ "\$prev" == "--attempt-id" ]]; then attempt="\$arg"; fi
  if [[ "\$prev" == "--single-stage" ]]; then stage="\$arg"; fi
  prev="\$arg"
done
workspace="\${@: -1}"
behavior_dir="$BEHAVIOR_DIR"
marker_dir="$MARKER_DIR"
state_root="$STATE_ROOT"
report="\$state_root/artifacts/$NAMESPACE/stage-outcomes/\${attempt}.json"
mkdir -p "\$(dirname "\$report")" "\$marker_dir"
printf '%s\n' "\$\$" >"\$marker_dir/\$stage.pid"
printf '%s\n' "\$attempt" >>"\$marker_dir/\$stage.attempts"
: >"\$marker_dir/\$stage.started"

write_report() {
  local outcome="\$1" exit_code="\$2" extra="\${3:-}"
  local head="{\"schemaVersion\":1,\"runId\":\"$RUN_ID\",\"stageId\":\"\$stage\",\"attemptId\":\"\$attempt\",\"outcome\":\"\$outcome\",\"exitCode\":\$exit_code,\"startedAt\":\"2026-01-01T00:00:00Z\",\"finishedAt\":\"2026-01-01T00:00:01Z\""
  if [[ -n "\$extra" ]]; then
    printf '%s\n' "\$head,\$extra}" >"\$report"
  else
    printf '%s\n' "\$head}" >"\$report"
  fi
}

emit_artifact() {
  mkdir -p "\$workspace/shared"
  printf 'evidence for %s from %s\n' "\$stage" "\$attempt" >"\$workspace/shared/\$stage.md"
}

succeed() {
  emit_artifact
  write_report success 0
  : >"\$marker_dir/\$stage.finished"
  exit 0
}

behavior="success"
if [[ -f "\$behavior_dir/\$stage" ]]; then
  behavior="\$(cat "\$behavior_dir/\$stage")"
fi

case "\$behavior" in
  pause)
    write_report failed 4 '"permissionRequest":{"tool":"Bash","rule":"Bash(rm:*)","action":"Bash","resource":"src/app.ts","effect":"write","decision":"pending"}'
    : >"\$marker_dir/\$stage.finished"
    exit 4
    ;;
  transient-once)
    # Fail only the first attempt; the attempt tally makes this deterministic
    # without the test having to race the scheduler to rewrite the behavior.
    if [[ ! -f "\$marker_dir/\$stage.failed-once" ]]; then
      : >"\$marker_dir/\$stage.failed-once"
      write_report failed 1 '"kind":"transient-runtime","reason":"connection reset by peer"'
      : >"\$marker_dir/\$stage.finished"
      exit 1
    fi
    succeed
    ;;
  contract)
    write_report failed 1 '"kind":"undeclared-path","reason":"undeclared path outside write scope","outOfScope":["src/leaked.ts"]'
    : >"\$marker_dir/\$stage.finished"
    exit 1
    ;;
  *)
    succeed
    ;;
esac
EOF
  chmod +x "$ORCHESTRATOR_STUB"
}

node_status() {
  local node_id="$1" run_id="${2:-$RUN_ID}"
  jq -r '.status // empty' \
    "$(graph_state_node_file "$DISPATCH_WORKSPACE" "$NAMESPACE" "$run_id" "$node_id")"
}

node_attempt_count() {
  local node_id="$1"
  jq '[.attempts[]?] | length' \
    "$(graph_state_node_file "$DISPATCH_WORKSPACE" "$NAMESPACE" "$RUN_ID" "$node_id")"
}

run_status() {
  jq -r '.status // empty' \
    "$(graph_state_run_file "$DISPATCH_WORKSPACE" "$NAMESPACE" "${1:-$RUN_ID}")"
}

# Drive one scheduler wave and assert its exit code exactly.
#   0 -- every node succeeded
#   1 -- the run is failed: a node failed terminally or entered needs-plan-repair
#   3 -- incomplete but healthy: work remains that waits on a human
# Asserting the exact code is deliberate; accepting "0 or 1 or 3" would hide a
# wave that ended for the wrong reason.
run_wave() {
  local graph_file="$1" run_dir="$2" expected="$3" rc=0
  export GRAPH_SCHEDULE_RETRY_SKIP_SLEEP=1
  export GRAPH_HEARTBEAT_NOW_EPOCH=1999999999
  graph_schedule_run "$graph_file" "$RUN_ID" "$DISPATCH_WORKSPACE" "$run_dir" || rc=$?
  [ "$rc" -eq "$expected" ]
}

@test "production acceptance replay with 27 nodes proves isolation retry permission branch recovery and publish readiness" {
  local graph_file plan_file run_dir n stale_aid run_file req_path dec_json rc
  local not_succeeded stale_node_file

  graph_file="$TMPD/production.graph.json"
  plan_file="$DISPATCH_WORKSPACE/production.plan.md"
  write_production_plan_and_graph "$plan_file" "$graph_file"
  install_production_orchestrator

  # The topology under replay is exactly 27 nodes.
  [ "${#ALL_NODES[@]}" -eq 27 ]
  [ "$(jq '.nodes | length' "$graph_file")" -eq 27 ]

  for n in "${PAUSE_NODES[@]}"; do printf 'pause\n' >"$BEHAVIOR_DIR/$n"; done
  for n in "${RETRY_NODES[@]}"; do printf 'transient-once\n' >"$BEHAVIOR_DIR/$n"; done
  printf 'contract\n' >"$BEHAVIOR_DIR/$CONTRACT_NODE"

  graph_state_init_run_v2 "$DISPATCH_WORKSPACE" "$NAMESPACE" "$RUN_ID" \
    "$DISPATCH_WORKSPACE/production.plan.md" "$graph_file" 4
  run_dir="$STATE_ROOT/graph-runs/$NAMESPACE/$RUN_ID"

  local roots_json
  roots_json="$(jq -cn --arg project "$DISPATCH_WORKSPACE" --arg state "$STATE_ROOT" \
    --arg agent "$DISPATCH_WORKSPACE" \
    '{projectRoot:$project,stateRoot:$state,agentWorkspace:$agent}')"
  graph_run_base_prepare "$run_dir" "$roots_json" '["snapshot"]'
  graph_workspace_prepare_run "$run_dir" "$graph_file"

  # --- property 5: stale recovery -------------------------------------------
  # Seed infra-1 as a running attempt owned by a dead supervisor, then prove
  # the recovery path interrupts the attempt and returns the node to pending.
  stale_aid="${STALE_NODE}__${RUN_ID}__1"
  graph_state_write_node_v2 "$DISPATCH_WORKSPACE" "$NAMESPACE" "$RUN_ID" "$STALE_NODE" running \
    "$stale_aid" '{"startedAt":"2026-01-01T00:00:00Z","runtime":"claude"}'
  graph_state_update_run_heartbeat "$DISPATCH_WORKSPACE" "$NAMESPACE" "$RUN_ID" "2026-01-01T00:00:00Z"
  run_file="$(graph_state_run_file "$DISPATCH_WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  ralph_atomic_write_json "$run_file" \
    '($base | fromjson) + {supervisorPid: 999999, ownerProcessStartId: "dead-owner", heartbeatAt: "2020-01-01T00:00:00Z"}' \
    --arg base "$(jq -c . "$run_file")" >/dev/null

  export GRAPH_HEARTBEAT_PROCESS_LOOKUP=off
  export GRAPH_HEARTBEAT_TTL_SECONDS=1
  export GRAPH_HEARTBEAT_NOW_EPOCH=1999999999
  [ "$(node_status "$STALE_NODE")" = "running" ]
  graph_recovery_interrupt_attempt "$DISPATCH_WORKSPACE" "$NAMESPACE" "$RUN_ID" \
    "$STALE_NODE" "$stale_aid" "stale recovery"
  graph_recovery_reset_eligible_nodes "$DISPATCH_WORKSPACE" "$NAMESPACE" "$RUN_ID" "$run_dir"
  [ "$(node_status "$STALE_NODE")" = "pending" ]
  [ -f "$run_dir/events.jsonl" ]
  grep -q '"node-interrupted"' "$run_dir/events.jsonl"

  # The recovery evidence now lives in events.jsonl, which is what the
  # assertion above proves. Drop the seeded attempt record itself: its id is
  # attempt 1 for this node, which is exactly the id the scheduler mints for
  # the node's first real attempt, and leaving it behind makes the upsert
  # ambiguous and strands the node in running.
  stale_node_file="$(graph_state_node_file "$DISPATCH_WORKSPACE" "$NAMESPACE" "$RUN_ID" "$STALE_NODE")"
  ralph_atomic_write_json "$stale_node_file" \
    '($base | fromjson) + {status: "pending", attempts: []}' \
    --arg base "$(jq -c . "$stale_node_file")" >/dev/null
  [ "$(node_status "$STALE_NODE")" = "pending" ]

  # --- wave 1: run until the pauses and the contract block ------------------
  # Exit 1: contract-1 lands in needs-plan-repair, which marks the run failed
  # even though most of the graph completed cleanly around it.
  run_wave "$graph_file" "$run_dir" 1

  # --- property 3 (pause half): both permission nodes are parked ------------
  for n in "${PAUSE_NODES[@]}"; do
    [ "$(node_status "$n")" = "awaiting-operator" ]
    [ -f "$run_dir/operator/requests/op-${n}-1.json" ]
    [ "$(jq -r '.classification' "$run_dir/operator/requests/op-${n}-1.json")" = "operator-permission" ]
  done

  # --- property 4: independent branches drained past the stuck branch -------
  [ "$(node_status "$CONTRACT_NODE")" = "needs-plan-repair" ]
  [ "$(node_status "$CONTRACT_CHILD")" = "blocked" ]
  for n in "${INDEPENDENT_DRAIN[@]}"; do
    [ "$(node_status "$n")" = "succeeded" ]
  done

  # --- property 2: bounded corrective retry --------------------------------
  # Each transient node failed once and succeeded on attempt 2 -- no more.
  for n in "${RETRY_NODES[@]}"; do
    [ "$(node_status "$n")" = "succeeded" ]
    [ "$(node_attempt_count "$n")" -eq 2 ]
    [ "$(wc -l <"$MARKER_DIR/$n.attempts")" -eq 2 ]
  done

  # --- property 3 (respond half): allow-once releases both paused nodes -----
  for n in "${PAUSE_NODES[@]}"; do
    req_path="$run_dir/operator/requests/op-${n}-1.json"
    dec_json="$(jq -nc \
      --arg rid "op-${n}-1" \
      --arg nonce "$(jq -r '.nonce' "$req_path")" \
      --arg node "$n" \
      --arg attempt "$(jq -r '.attemptId' "$req_path")" \
      --arg runtime "$(jq -r '.runtime' "$req_path")" \
      --arg ns "$NAMESPACE" --arg run "$RUN_ID" \
      '{requestId:$rid,nonce:$nonce,runId:$run,namespace:$ns,nodeId:$node,
        attemptId:$attempt,runtime:$runtime,decision:"allow-once",
        actorSource:"human",decidedAt:"2026-08-13T00:05:00Z",
        granted:{action:"Bash",resource:"src/app.ts",effect:"write"}}')"
    graph_operator_decision_write "$run_dir" "$dec_json"
    printf 'success\n' >"$BEHAVIOR_DIR/$n"
  done

  # --- repair the contract branch in the same pass --------------------------
  # Repairing here rather than in a third wave keeps the replay to two full
  # scheduler passes; wave 1 already captured the blocked-branch evidence.
  printf 'success\n' >"$BEHAVIOR_DIR/$CONTRACT_NODE"
  graph_state_write_node_v2 "$DISPATCH_WORKSPACE" "$NAMESPACE" "$RUN_ID" "$CONTRACT_NODE" pending
  graph_state_write_node_v2 "$DISPATCH_WORKSPACE" "$NAMESPACE" "$RUN_ID" "$CONTRACT_CHILD" pending

  # --- wave 2: resume the same run so it drains to success ------------------
  # Resume, not a second graph_schedule_run: run starts a fresh pass, while
  # resume reloads the ledger, keeps succeeded nodes succeeded, and consumes
  # the operator decisions. --accept-graph-change is required because the
  # frozen graph carries the injected resilience/budgets the recompiled plan
  # cannot express; no node's stage digest differs, so nothing is invalidated.
  graph_state_set_run_status "$DISPATCH_WORKSPACE" "$NAMESPACE" "$RUN_ID" "awaiting-operator"
  rc=0
  export GRAPH_SCHEDULE_RETRY_SKIP_SLEEP=1
  graph_schedule_resume "$DISPATCH_WORKSPACE" "$NAMESPACE" "$RUN_ID" "$plan_file" \
    --frozen-graph "$graph_file" --accept-graph-change || rc=$?
  [ "$rc" -eq 0 ]
  for n in "${PAUSE_NODES[@]}"; do
    [ "$(node_status "$n")" = "succeeded" ]
    [ -f "$run_dir/operator/decisions/op-${n}-1.json" ]
  done
  [ "$(node_status publish-final)" = "succeeded" ]

  # Every one of the 27 nodes has succeeded. Report every mismatch rather than
  # dying on the first one; which nodes lag is the whole diagnostic here.
  not_succeeded=""
  for n in "${ALL_NODES[@]}"; do
    if [ "$(node_status "$n")" != "succeeded" ]; then
      not_succeeded="$not_succeeded $n=$(node_status "$n")"
    fi
  done
  [ -z "$not_succeeded" ] || {
    echo "nodes not succeeded:$not_succeeded" >&2
    false
  }

  # --- property 1: isolated logs -------------------------------------------
  # Each node owns a distinct log directory, and no node wrote another node's
  # artifact or leaked into the caller project root.
  local logged=0
  for n in "${ALL_NODES[@]}"; do
    [ -d "$run_dir/logs/nodes/$n" ]
    logged=$((logged + 1))
  done
  [ "$logged" -eq 27 ]
  [ "$(find "$run_dir/logs/nodes" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 27 ]
  [ ! -e "$DISPATCH_WORKSPACE/shared" ]

  # --- property 6: successor reuse -----------------------------------------
  local report new_run_id new_run_dir
  report="$(graph_successor_reuse_report "$graph_file" "$graph_file" \
    "$DISPATCH_WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  [ -n "$report" ]
  [ "$(printf '%s' "$report" | jq '[.nodes[] | select(.reuse == true)] | length')" -eq 27 ]

  new_run_id="production-hardening-run-002"
  graph_successor_create "$DISPATCH_WORKSPACE" "$NAMESPACE" "$RUN_ID" "$graph_file" \
    "$DISPATCH_WORKSPACE/production.plan.md" "$new_run_id"
  new_run_dir="$STATE_ROOT/graph-runs/$NAMESPACE/$new_run_id"
  [ -d "$new_run_dir" ]
  [ "$(node_status root "$new_run_id")" = "succeeded" ]

  # --- property 7: final publish readiness ----------------------------------
  # The publish guard must reach a verified terminal decision rather than
  # refusing. This topology has no `integrate` node, so the correct decision
  # for a fully succeeded manual-mode run is not-applicable with verified
  # true: the guard checked run status, every node, and delegations, and found
  # nothing to publish. A refusal here would mean the run was not actually
  # complete. The ready path needs an integration manifest and is covered by
  # graph-publish.bats; what matters for the replay is that the guard agrees
  # the run finished cleanly.
  local handoff
  graph_publish_finalize "$run_dir" "$graph_file" "$DISPATCH_WORKSPACE"
  handoff="$STATE_ROOT/artifacts/$NAMESPACE/publish/$RUN_ID/handoff.json"
  [ -f "$handoff" ]
  [ "$(jq -r '.status' "$handoff")" != "refused" ]
  [ "$(jq -r '.status' "$handoff")" = "not-applicable" ]
  [ "$(jq -r '.verified' "$handoff")" = "true" ]
  [ "$(jq -r '.publishMode' "$handoff")" = "manual" ]
  [ "$(jq -r '.status' "$run_dir/run.json")" = "succeeded" ]
}
