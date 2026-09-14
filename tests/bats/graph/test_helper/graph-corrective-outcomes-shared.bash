#!/usr/bin/env bash
# Shared fixtures and helpers for the graph-corrective-outcomes suites.
#
# graph-corrective-outcomes.bats keeps the library-level tests. graph-corrective-outcomes-e2e.bats keeps the
# tests that drive a real dispatch: each boots the orchestrator and
# run-plan once per node, so they run in the acceptance tier rather than
# on the pull-request path.
#
# This is the non-@test body of the original graph-corrective-outcomes.bats in its original
# order. Several helpers are emitted inside heredocs and depend on that
# ordering, so do not reorder.
# Compact correction records, in-place corrective retry, and plan-contract
# waiting (needs-plan-repair) for graph results.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/atomic-json.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-failure-classify.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-run-base.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-schedule.sh"

assert_compact_correction() {
  local record="$1"
  [ -f "$record" ]
  [ "$(jq -r 'keys | sort | join(",")' "$record")" = \
    "failedCompletionComponent,nextAttemptNumber,offendingPaths,verificationResultPath" ]
  [ "$(jq -r 'has("prompt") or has("output") or has("rawOutput") or has("stdout") or has("stderr") or has("text")' "$record")" = "false" ]
}

write_corrective_graph() {
  local out_path="$1" session_resume="${2:-true}"
  jq -n --argjson resume "$session_resume" '
    {
      schemaVersion: 1,
      ralphVersion: "test",
      name: "corrective-retry",
      namespace: "corrective-retry",
      maxParallel: 1,
      failurePolicy: "drain",
      resilience: {
        mode: "bounded",
        transientRetries: 0,
        correctiveRetries: 1,
        denialRecoveryTurns: 0,
        backoffSeconds: [0]
      },
      nodes: [{
        id: "impl",
        type: "agent",
        dependsOn: [],
        derivedFrom: "stage",
        stage: {
          id: "impl",
          runtime: "cursor",
          role: "implementation",
          sessionResume: $resume,
          workspaceMode: "snapshot",
          outputArtifacts: [{path: "stub-output.md", required: true}],
          _inlineTodos: [{id: "impl-1", content: "work impl", status: "pending"}]
        }
      }],
      edges: []
    }
  ' >"$out_path"
}

setup() {
  TMPD="$(mktemp -d)"
  RUN_DIR="$TMPD/run"
  mkdir -p "$RUN_DIR"
  unset RALPH_GRAPH_CORRECTION_RECORD RALPH_GRAPH_PROMPT RALPH_PLAN_PROMPT 2>/dev/null || true
}

teardown() {
  chmod -R u+w "$TMPD" 2>/dev/null || true
  rm -rf "$TMPD" 2>/dev/null || true
  unset RALPH_GRAPH_STATE_ROOT RALPH_PLAN_WORKSPACE_ROOT GRAPH_DISPATCH_ORCHESTRATOR 2>/dev/null || true
  unset RALPH_ALLOW_NESTED_RUNS ORCHESTRATOR_RUNNER_TO_CONSOLE RALPH_MODE 2>/dev/null || true
  unset RALPH_ARTIFACT_NS RALPH_GRAPH_MAX_PARALLEL RALPH_GRAPH_MAX_PARALLEL_PER_RUNTIME 2>/dev/null || true
}














prepare_required_artifact_retry_harness() {
  local corrective_retries="$1"
  # Keep this adapter test focused on retry state. Usage/active-time accounting
  # has its own suite and otherwise adds repeated durable ledger scans here.
  ralph_fsync_path() { :; }
  graph_schedule_record_attempt_usage() { :; }
  graph_schedule_usage_should_stop() { return 1; }
  graph_schedule_active_time_exhausted() { return 1; }
  graph_schedule_commit_active_time() { :; }
  RETRY_GRAPH="$TMPD/corrective-${corrective_retries}.graph.json"
  write_corrective_graph "$RETRY_GRAPH" true
  jq --argjson retries "$corrective_retries" \
    '.resilience.correctiveRetries = $retries' "$RETRY_GRAPH" >"$RETRY_GRAPH.tmp"
  mv "$RETRY_GRAPH.tmp" "$RETRY_GRAPH"

  DISPATCH_WORKSPACE="$TMPD/workspace-${corrective_retries}"
  RETRY_WORKSPACE="$TMPD/node-workspace-${corrective_retries}"
  mkdir -p "$DISPATCH_WORKSPACE" "$RETRY_WORKSPACE"
  printf 'source\n' >"$RETRY_WORKSPACE/src.txt"
  RETRY_STATE_ROOT="$TMPD/state-${corrective_retries}"
  RETRY_RUN_ID="required-artifact-${corrective_retries}"
  RETRY_RUN_DIR="$RETRY_STATE_ROOT/graph-runs/corrective-retry/$RETRY_RUN_ID"
  RETRY_LEDGER="$RETRY_RUN_DIR/test-ledger.tsv"
  mkdir -p "$RETRY_RUN_DIR"
  export RALPH_GRAPH_STATE_ROOT="$RETRY_STATE_ROOT"
  export RALPH_PLAN_WORKSPACE_ROOT="$RETRY_STATE_ROOT"

  graph_schedule_load_index "$RETRY_GRAPH"
  GRAPH_SCHEDULE_GRAPH_JSON="$RETRY_GRAPH"
  GRAPH_SCHEDULE_WORKSPACE="$DISPATCH_WORKSPACE"
  GRAPH_SCHEDULE_NAMESPACE="corrective-retry"
  GRAPH_SCHEDULE_RUN_ID="$RETRY_RUN_ID"
  GRAPH_SCHEDULE_LEDGER_RUN_DIR="$RETRY_RUN_DIR"
  GRAPH_SCHEDULE_LOG_RUN_DIR="$RETRY_RUN_DIR"
  GRAPH_SCHEDULE_LEDGER_NAMESPACE="corrective-retry"
  GRAPH_SCHEDULE_EXIT_CODE=0
  GRAPH_SCHEDULE_FAILED_NODE=""
  GRAPH_SCHEDULE_STOP_DISPATCH=0
  GRAPH_NODE_STATES[$(graph_schedule_index_map_get impl)]="running"
  GRAPH_NODE_ATTEMPT_NUMBERS[$(graph_schedule_index_map_get impl)]="1"

  _graph_schedule_ledger_record() {
    printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "${3:-}" "${4:-}" "${10:-}" >>"$RETRY_LEDGER"
  }
  printf 'attempt-1-partial\n' >"$RETRY_WORKSPACE/keep-me.txt"
  RETRY_MISSING="$RETRY_WORKSPACE/stub-output.md"
  RETRY_ATTEMPT_ONE="impl__${RETRY_RUN_ID}__1"
  RETRY_REPORT_ONE="$RETRY_STATE_ROOT/artifacts/corrective-retry/stage-outcomes/${RETRY_ATTEMPT_ONE}.json"
  mkdir -p "$(dirname "$RETRY_REPORT_ONE")"
  jq -n --arg run "$RETRY_RUN_ID" --arg attempt "$RETRY_ATTEMPT_ONE" \
    --arg missing "$RETRY_MISSING" '{
      schemaVersion: 2,
      runId: $run,
      stageId: "impl",
      attemptId: $attempt,
      outcome: "failed",
      exitCode: 1,
      failure: {
        classification: "agent-correctable",
        cause: "required-artifact-missing",
        source: "orchestrator",
        summary: "a required artifact was not produced",
        retryable: true,
        operatorAction: "none",
        missingArtifacts: [$missing],
        offendingPaths: [],
        verification: "unknown"
      }
    }' >"$RETRY_REPORT_ONE"
  _graph_schedule_ledger_record impl running "$RETRY_ATTEMPT_ONE" "" "" \
    "2026-01-01T00:00:00Z" "" cursor off ""
  GRAPH_REAP_NODE=impl
  GRAPH_REAP_REPORT_PATH="$RETRY_REPORT_ONE"
  GRAPH_REAP_EXIT_CODE=1
  GRAPH_REAP_MISSING_REPORT=0
}



write_plan_contract_graph() {
  local out_path="$1"
  jq -n '
    {
      schemaVersion: 1,
      ralphVersion: "test",
      name: "plan-contract",
      namespace: "plan-contract",
      maxParallel: 1,
      failurePolicy: "drain",
      nodes: [
        {
          id: "contract",
          type: "agent",
          dependsOn: [],
          derivedFrom: "stage",
          stage: {
            id: "contract",
            runtime: "cursor",
            role: "implementation",
            workspaceMode: "snapshot",
            writeScopes: ["src/allowed/**"],
            outputArtifacts: [{path: "stub-output.md", required: true}],
            _inlineTodos: [{id: "contract-1", content: "work contract", status: "pending"}]
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
          dependsOn: ["contract"],
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
      edges: [{from: "contract", to: "child", reasons: ["declared"]}]
    }
  ' >"$out_path"
}

write_plan_contract_diamond_graph() {
  local out_path="$1"
  jq -n '
    {
      schemaVersion: 1,
      ralphVersion: "test",
      name: "plan-contract-diamond",
      namespace: "plan-contract-diamond",
      maxParallel: 1,
      failurePolicy: "drain",
      nodes: [
        {
          id: "source",
          type: "agent",
          dependsOn: [],
          derivedFrom: "stage",
          stage: {
            id: "source",
            runtime: "cursor",
            role: "implementation",
            _inlineTodos: [{id: "source-1", content: "work source", status: "pending"}]
          }
        },
        {
          id: "left",
          type: "agent",
          dependsOn: ["source"],
          derivedFrom: "stage",
          stage: {
            id: "left",
            runtime: "claude",
            role: "implementation",
            writeScopes: ["src/left/**"],
            _inlineTodos: [{id: "left-1", content: "work left", status: "pending"}]
          }
        },
        {
          id: "right",
          type: "agent",
          dependsOn: ["source"],
          derivedFrom: "stage",
          stage: {
            id: "right",
            runtime: "codex",
            role: "implementation",
            _inlineTodos: [{id: "right-1", content: "work right", status: "pending"}]
          }
        },
        {
          id: "sink",
          type: "agent",
          dependsOn: ["left", "right"],
          derivedFrom: "stage",
          stage: {
            id: "sink",
            runtime: "cursor",
            role: "implementation",
            _inlineTodos: [{id: "sink-1", content: "work sink", status: "pending"}]
          }
        }
      ],
      edges: [
        {from: "source", to: "left", reasons: ["declared"]},
        {from: "source", to: "right", reasons: ["declared"]},
        {from: "left", to: "sink", reasons: ["declared"]},
        {from: "right", to: "sink", reasons: ["declared"]}
      ]
    }
  ' >"$out_path"
}

install_plan_contract_orchestrator() {
  local orch="$1" marker_dir="$2" contract_stage="${3:-contract}"
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
ns="\${RALPH_ARTIFACT_NS:-plan-contract}"
state_root="\${RALPH_PLAN_WORKSPACE_ROOT:-\$workspace/.ralph-workspace}"
report="\$state_root/artifacts/\$ns/stage-outcomes/\${attempt}.json"
mkdir -p "\$(dirname "\$report")" "$marker_dir"
: >"$marker_dir/\$stage.started"
if [[ "\$stage" == "$contract_stage" ]]; then
  printf '%s\n' "{\"schemaVersion\":1,\"runId\":\"plan-contract-run\",\"stageId\":\"\$stage\",\"attemptId\":\"\$attempt\",\"outcome\":\"failed\",\"exitCode\":1,\"kind\":\"undeclared-path\",\"outOfScope\":[\"docs/secret.md\"],\"startedAt\":\"2026-01-01T00:00:00Z\",\"finishedAt\":\"2026-01-01T00:00:01Z\"}" >"\$report"
  : >"$marker_dir/\$stage.finished"
  exit 1
fi
printf 'ok\n' >"\$workspace/\${stage}.md"
printf 'stub artifact\n' >"\$workspace/stub-output.md"
printf 'independent\n' >"\$workspace/independent.md"
printf '%s\n' "{\"schemaVersion\":1,\"runId\":\"plan-contract-run\",\"stageId\":\"\$stage\",\"attemptId\":\"\$attempt\",\"outcome\":\"success\",\"exitCode\":0,\"startedAt\":\"2026-01-01T00:00:02Z\",\"finishedAt\":\"2026-01-01T00:00:03Z\"}" >"\$report"
: >"$marker_dir/\$stage.finished"
exit 0
EOF
  chmod +x "$orch"
}
