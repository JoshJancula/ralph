#!/usr/bin/env bash
# Shared fixtures and helpers for the graph-operator-schedule suites.
#
# graph-operator-schedule.bats keeps the library-level tests. graph-operator-schedule-e2e.bats keeps the
# tests that drive a real dispatch: each boots the orchestrator and
# run-plan once per node, so they run in the acceptance tier rather than
# on the pull-request path.
#
# This is the non-@test body of the original graph-operator-schedule.bats in its original
# order. Several helpers are emitted inside heredocs and depend on that
# ordering, so do not reorder.
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
  # Live progress rendering has dedicated coverage; disable it in these
  # scheduler-transition tests so child reaping remains fast and deterministic.
  export GRAPH_LIVE_PROGRESS=0
  unset RALPH_GRAPH_STATE_ROOT RALPH_PLAN_WORKSPACE_ROOT GRAPH_DISPATCH_ORCHESTRATOR 2>/dev/null || true
}

teardown() {
  chmod -R u+w "$TMPD" 2>/dev/null || true
  rm -rf "$TMPD" 2>/dev/null || true
  unset GRAPH_OPERATOR_NOW GRAPH_OPERATOR_EXPIRES_AT GRAPH_OPERATOR_NONCE GRAPH_OPERATOR_REQUEST_ID GRAPH_LIVE_PROGRESS 2>/dev/null || true
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
            role: "implementation",
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
            role: "implementation",
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
            role: "implementation",
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
  GRAPH_SCHEDULE_AWAITING_OPERATOR=0
  RUN_DIR="$GRAPH_SCHEDULE_LEDGER_RUN_DIR"
}






# --- G09 bounded live progress ----------------------------------------------

write_live_progress_graph() {
  local out_path="$1"
  jq -n '
    {
      schemaVersion: 1,
      ralphVersion: "test",
      name: "live-progress",
      namespace: "live-progress",
      maxParallel: 1,
      failurePolicy: "cancel",
      nodes: [
        {
          id: "slow",
          type: "agent",
          dependsOn: [],
          derivedFrom: "stage",
          stage: {
            id: "slow",
            runtime: "cursor",
            role: "implementation",
            model: "fake-model-1",
            workspaceMode: "snapshot",
            outputArtifacts: [{path: "slow-out.md", required: true}],
            _inlineTodos: [{id: "slow-1", content: "work slowly", status: "pending"}]
          }
        },
        {
          id: "pending-sib",
          type: "agent",
          dependsOn: [],
          derivedFrom: "stage",
          stage: {
            id: "pending-sib",
            runtime: "claude",
            role: "implementation",
            workspaceMode: "snapshot",
            outputArtifacts: [{path: "pending-sib-out.md", required: true}],
            _inlineTodos: [{id: "sib-1", content: "wait turn", status: "pending"}]
          }
        }
      ],
      edges: []
    }
  ' >"$out_path"
}

install_slow_fake_orchestrator() {
  local orch="$1" marker_dir="$2"
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
ns="\${RALPH_ARTIFACT_NS:-live-progress}"
state_root="\${RALPH_PLAN_WORKSPACE_ROOT:-\$workspace/.ralph-workspace}"
report="\$state_root/artifacts/\$ns/stage-outcomes/\${attempt}.json"
mkdir -p "\$(dirname "\$report")" "$marker_dir"
: >"$marker_dir/\$stage.started"
printf '%s\n' "\$\$" >"$marker_dir/\$stage.pid"

# Structured runner marker for current TODO (G09).
printf '%s\n' "{\"currentTodoId\":\"\${stage}-1\"}"

agent_log="\${RALPH_GRAPH_NODE_LOG_DIR:-}/agent.log"
if [[ -n "\${RALPH_GRAPH_NODE_LOG_DIR:-}" ]]; then
  mkdir -p "\$RALPH_GRAPH_NODE_LOG_DIR"
  {
    printf '%s\n' "thinking: do not expose this chain-of-thought"
    printf '%s\n' "password=super-secret-token-value"
    printf '%s\n' "agent working on \${stage}-1 feature"
  } >>"\$agent_log"
fi
: >"$marker_dir/\$stage.progressed"

# Stay alive long enough for a G09 heartbeat and a follow detach.
sleep 3

printf 'ok\n' >"\$workspace/\${stage}-out.md"
printf '%s\n' "{\"schemaVersion\":1,\"runId\":\"live-progress-run\",\"stageId\":\"\$stage\",\"attemptId\":\"\$attempt\",\"outcome\":\"success\",\"exitCode\":0,\"startedAt\":\"2026-01-01T00:00:00Z\",\"finishedAt\":\"2026-01-01T00:00:04Z\"}" >"\$report"
: >"$marker_dir/\$stage.finished"
exit 0
EOF
  chmod +x "$orch"
}
