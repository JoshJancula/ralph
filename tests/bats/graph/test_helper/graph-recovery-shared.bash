#!/usr/bin/env bash
# Shared fixtures and helpers for the graph-recovery suites.
#
# graph-recovery.bats keeps the library-level tests. graph-recovery-e2e.bats keeps the
# tests that drive a real dispatch: each boots the orchestrator and
# run-plan once per node, so they run in the acceptance tier rather than
# on the pull-request path.
#
# This is the non-@test body of the original graph-recovery.bats in its original
# order. Several helpers are emitted inside heredocs and depend on that
# ordering, so do not reorder.
# Tests for graph recovery helpers: interrupting orphaned running attempts,
# preserving attempt fields, and appending events.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/plan-todo.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/atomic-json.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-state.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-logs.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-events.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-heartbeat.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-recovery.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-schedule.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-status.sh"

DIAMOND_PLAN="$BATS_TEST_DIRNAME/../../fixtures/graph/graph-diamond.plan.md"
STUB_RUN_PLAN="$BATS_TEST_DIRNAME/../../fixtures/orchestrator-single-stage/run-plan-stub.sh"
RALPH_DIR="$REPO_ROOT/bundle/.ralph"
GRAPH_RUN_SH="$REPO_ROOT/bundle/.ralph/graph-run.sh"

compile_graph() {
  local src_plan="$1" workspace="$2" out_path="$3"
  local plan_file="$workspace/$(basename "$src_plan")"
  cp "$src_plan" "$plan_file"
  plan_pipeline_graph_json "$plan_file" > "$out_path"
}

set_run_json_field() {
  local run_file="$1" field="$2" value="$3"
  local tmp
  tmp="$(mktemp)"
  jq --arg f "$field" --arg v "$value" '.[$f] = $v' "$run_file" > "$tmp"
  mv "$tmp" "$run_file"
}

set_run_json_null() {
  local run_file="$1" field="$2"
  local tmp
  tmp="$(mktemp)"
  jq --arg f "$field" '.[$f] = null' "$run_file" > "$tmp"
  mv "$tmp" "$run_file"
}

mark_run_stale() {
  local run_file
  run_file="$(graph_state_run_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  set_run_json_field "$run_file" "heartbeatAt" "2026-08-12T00:00:00Z"
  set_run_json_field "$run_file" "supervisorPid" "99999"
  set_run_json_field "$run_file" "ownerProcessStartId" "old-start"
}

run_stale_recovery() {
  GRAPH_HEARTBEAT_TTL_SECONDS=1 GRAPH_HEARTBEAT_NOW_EPOCH=1999999999 \
    graph_recovery_attempt_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID"
}

recover_cmd() {
  bash "$GRAPH_RUN_SH" recover "$@" --workspace "$WORKSPACE"
}

ledger_snapshot() {
  local runs_dir
  runs_dir="$(graph_state_runs_root "$WORKSPACE")"
  find "$runs_dir" -type f | sort | while IFS= read -r f; do
    printf '%s %s\n' "$(shasum "$f" | awk '{print $1}')" "$f"
  done
}

# Install stub run-plan and a per-stage behavior orchestrator so resume tests
# never invoke a live/paid runtime.
install_stub_runtimes() {
  local behavior_dir="$1" marker_dir="$2"
  mkdir -p "$WORKSPACE/.ralph" "$WORKSPACE/.ralph-workspace" "$behavior_dir" "$marker_dir"
  cp -R "$RALPH_DIR"/* "$WORKSPACE/.ralph/"
  chmod +x "$WORKSPACE/.ralph"/*.sh 2>/dev/null || true
  chmod +x "$WORKSPACE/.ralph/bash-lib"/*/*.sh 2>/dev/null || true
  cp "$STUB_RUN_PLAN" "$WORKSPACE/.ralph/run-plan.sh"
  chmod +x "$WORKSPACE/.ralph/run-plan.sh"

  cat >"$WORKSPACE/.ralph/orchestrator.sh" <<EOF
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
workspace="\${@: -1}"
ns="$NAMESPACE"
run_id="$RUN_ID"
behavior_dir="$behavior_dir"
marker_dir="$marker_dir"
report="\$workspace/.ralph-workspace/artifacts/\$ns/stage-outcomes/\${attempt}.json"
mkdir -p "\$(dirname "\$report")" "\$marker_dir"
printf '%s\\n' "\$\$" >"\$marker_dir/\$stage.pid"
: >"\$marker_dir/\$stage.started"
write_report() {
  local outcome="\$1" exit_code="\$2"
  printf '%s\\n' "{\"schemaVersion\":1,\"runId\":\"\$run_id\",\"stageId\":\"\$stage\",\"attemptId\":\"\$attempt\",\"outcome\":\"\$outcome\",\"exitCode\":\$exit_code,\"startedAt\":\"2026-01-01T00:00:00Z\",\"finishedAt\":\"2026-01-01T00:00:01Z\"}" >"\$report"
}
behavior="success"
if [[ -f "\$behavior_dir/\$stage" ]]; then
  behavior="\$(cat "\$behavior_dir/\$stage")"
fi
case "\$behavior" in
  fail:*)
    ec="\${behavior#fail:}"
    [[ "\$ec" =~ ^[0-9]+$ ]] || ec=1
    write_report failed "\$ec"
    : >"\$marker_dir/\$stage.finished"
    exit "\$ec"
    ;;
  *)
    write_report success 0
    : >"\$marker_dir/\$stage.finished"
    exit 0
    ;;
esac
EOF
  chmod +x "$WORKSPACE/.ralph/orchestrator.sh"
  export GRAPH_DISPATCH_ORCHESTRATOR="$WORKSPACE/.ralph/orchestrator.sh"
  export RALPH_ALLOW_NESTED_RUNS=1
  export ORCHESTRATOR_RUNNER_TO_CONSOLE=0
  export RALPH_MODE=no
  export RALPH_ARTIFACT_SCHEMA_VALIDATION=0
  export RALPH_ARTIFACT_PROVENANCE=0
}

setup() {
  TMPD="$(mktemp -d)"
  WORKSPACE="$TMPD/ws"
  mkdir -p "$WORKSPACE"
  NAMESPACE="recovery-ns"
  RUN_ID="run-recovery-001"
  GRAPH_JSON="$TMPD/graph.json"
  compile_graph "$DIAMOND_PLAN" "$WORKSPACE" "$GRAPH_JSON"
  PLAN_FILE="$WORKSPACE/$(basename "$DIAMOND_PLAN")"
  graph_state_init_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$PLAN_FILE" "$GRAPH_JSON" 2 >/dev/null
  export GRAPH_RECOVERY_INTERRUPT_AT="2026-08-12T00:00:00Z"
}

teardown() {
  unset RALPH_GRAPH_FOLLOW_INTERVAL RALPH_GRAPH_FOLLOW_MAX_POLLS 2>/dev/null || true
  rm -rf "$TMPD"
}
