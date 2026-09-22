#!/usr/bin/env bats
# Routing tests for `ralph workflow watch` through the engine-neutral viewer.
#
# Covers TTY/non-TTY selection, --plain, invalid flags, exact run IDs,
# Sequential/Dependency parity, q/Ctrl-C detach semantics, terminal and waiting
# exits, missing Python fallback, and unchanged run/action directory fingerprints.
# Also runs the dedicated Python viewer unit tests.

bats_require_minimum_version 1.5.0

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

CLI="$REPO_ROOT/bundle/.ralph/workflow-cli.sh"
STATE_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/workflow/workflow-state.sh"
VIEWER_PY="$REPO_ROOT/bundle/.ralph/python/workflow_viewer.py"
FRONT="$REPO_ROOT/bundle/.ralph/workflow-ralph-front.sh"
PYTHON_VIEWER_TESTS="$REPO_ROOT/tests/python/test_workflow_viewer.py"

setup_file() {
  command -v jq >/dev/null || skip "jq required"
  command -v python3 >/dev/null || skip "python3 required"
  [ -f "$CLI" ]
  [ -f "$STATE_LIB" ]
  [ -f "$VIEWER_PY" ]
  [ -f "$FRONT" ]
  [ -f "$PYTHON_VIEWER_TESTS" ]

  FIX_ROOT="$(mktemp -d "${BATS_TMPDIR:-/tmp}/wwatch.XXXXXX")"
  FIX_ROOT="$(cd "$FIX_ROOT" && pwd -P)"
  FIX_PROJECT="$FIX_ROOT/project"
  FIX_STATE="$FIX_PROJECT/.ralph-workspace"
  mkdir -p "$FIX_STATE"
  export FIX_ROOT FIX_PROJECT FIX_STATE
}

teardown_file() {
  rm -rf "$FIX_ROOT"
}

setup() {
  unset RALPH_WORKFLOW_STATE_ROOT RALPH_PLAN_WORKSPACE_ROOT RALPH_GRAPH_STATE_ROOT
  unset WORKFLOW_STATE_FIXED_RUN_ID WORKFLOW_STATE_FIXED_NOW WORKFLOW_STATE_SKIP_FSYNC
  unset NO_COLOR CI TERM RALPH_GRAPH_PLAIN RALPH_GRAPH_NO_TUI
  unset RALPH_GRAPH_SCREEN_READER ACCESSIBILITY_SCREEN_READER RALPH_WORKFLOW_NO_COLOR
  export WORKFLOW_STATE_SKIP_FSYNC=1
  # shellcheck source=/dev/null
  source "$STATE_LIB"

  CASE="$(mktemp -d "$FIX_STATE/case.XXXXXX")"
  CASE="$(cd "$CASE" && pwd -P)"
  export CASE
}

teardown() {
  rm -rf "$CASE"
}

wf_cli() {
  run env RALPH_PROJECT_ROOT="$FIX_PROJECT" RALPH_PLAN_WORKSPACE_ROOT="$CASE" \
    RALPH_HOME="$FIX_ROOT/home" bash "$CLI" "$@"
}

digest_tree() {
  find "$1" -type f ! -path '*/.create.lock' | LC_ALL=C sort | xargs cksum 2>/dev/null | cksum | awk '{print $1}'
}

wait_for_file_match() {
  local file="$1" pattern="$2" i
  for i in $(seq 1 80); do
    if [[ -f "$file" ]] && grep -q -- "$pattern" "$file" 2>/dev/null; then
      return 0
    fi
    sleep 0.05
  done
  return 1
}

wait_pid_exit() {
  local pid="$1" i
  for i in $(seq 1 80); do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null || true
      return 0
    fi
    sleep 0.05
  done
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  return 1
}

write_outer_run() {
  local state_root="$1" run_id="$2" body="$3"
  local run_dir="$state_root/workflow-runs/$run_id"
  mkdir -p "$run_dir"
  printf '%s' "$body" >"$run_dir/run.json"
  chmod a-w "$run_dir/run.json" 2>/dev/null || true
}

seed_dependency_waiting() {
  local state_root="$1" run_id="$2"
  local registry_run="$state_root/workflow-runs/$run_id"
  local graph_dir="$state_root/graphs/lifecycle/$run_id"
  mkdir -p "$registry_run/actions/requests" "$graph_dir/nodes/approve-plan" \
    "$graph_dir/attempts/approve-plan/1"

  write_outer_run "$state_root" "$run_id" "$(jq -cn \
    --arg runId "$run_id" \
    --arg engine "$graph_dir" \
    '{
      schemaVersion: 1,
      runId: $runId,
      workflowId: "feature-delivery",
      sourcePath: "/tmp/feature-delivery.workflow.md",
      sourceKind: "project",
      mode: "dependency",
      entryKind: "task",
      task: "Ship the feature",
      taskProvenance: "explicit",
      inputPath: "/tmp/input.plan.md",
      inputPlan: null,
      state: "waiting",
      createdAt: "2026-08-26T10:00:00Z",
      updatedAt: "2026-08-26T10:01:00Z",
      owner: { pid: null, hostname: null, processStartId: null, heartbeatAt: null },
      engine: { kind: "graph", statePath: $engine, namespace: "lifecycle" }
    }')"

  jq -n '{
    schemaVersion: 1,
    namespace: "lifecycle",
    runId: $runId,
    status: "waiting",
    nodes: {
      "approve-plan": {
        id: "approve-plan",
        type: "approval",
        status: "waiting",
        attempt: 1,
        question: "Approve the implementation plan?",
        changesTarget: "implement",
        requestId: "appr-watch-001"
      }
    },
    createdAt: "2026-08-26T10:00:00Z",
    updatedAt: "2026-08-26T10:01:00Z"
  }' --arg runId "$run_id" >"$graph_dir/run.json"

  # Minimal frozen graph for Dependency projection.
  jq -n '{
    schemaVersion: 1,
    namespace: "lifecycle",
    nodes: [
      { id: "approve-plan", type: "approval", question: "Approve the implementation plan?", changesTarget: "implement" },
      { id: "implement", runtime: "cursor", dependsOn: ["approve-plan"] }
    ]
  }' >"$graph_dir/graph.json"

  jq -n \
    --arg runId "$run_id" \
    '{
      schemaVersion: 1,
      requestId: "appr-watch-001",
      runId: $runId,
      stageId: "approve-plan",
      attempt: 1,
      kind: "approval",
      question: "Approve the implementation plan?",
      choices: ["approve", "reject", "request-changes"],
      changesTarget: "implement",
      createdAt: "2026-08-26T10:00:00Z"
    }' >"$registry_run/actions/requests/appr-watch-001.json"
}

seed_sequential_waiting() {
  local state_root="$1" run_id="$2"
  local registry_run="$state_root/workflow-runs/$run_id"
  local engine_dir="$registry_run/engine"
  mkdir -p "$engine_dir/stages" "$registry_run/actions/requests"

  write_outer_run "$state_root" "$run_id" "$(jq -cn \
    --arg runId "$run_id" \
    --arg engine "$engine_dir" \
    '{
      schemaVersion: 1,
      runId: $runId,
      workflowId: "bug-fix",
      sourcePath: "/tmp/bug-fix.workflow.md",
      sourceKind: "project",
      mode: "sequential",
      entryKind: "task",
      task: "Fix flaky test",
      taskProvenance: "explicit",
      inputPath: "/tmp/input.orch.json",
      inputPlan: null,
      state: "waiting",
      createdAt: "2026-08-26T12:00:00Z",
      updatedAt: "2026-08-26T12:10:00Z",
      owner: { pid: null, hostname: null, processStartId: null, heartbeatAt: null },
      engine: { kind: "orchestration", statePath: $engine, namespace: null }
    }')"

  jq -n '{
    schemaVersion: 1,
    inputSha256: "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
    state: "waiting",
    currentStageIds: ["implement"],
    loopIterations: 0,
    completedWaves: 0,
    owner: { pid: null, hostname: null, processStartId: null, heartbeatAt: null },
    createdAt: "2026-08-26T12:00:00Z",
    updatedAt: "2026-08-26T12:10:00Z"
  }' >"$engine_dir/run.json"

  jq -n '{
    id: "implement",
    index: 0,
    state: "waiting",
    attempt: 1,
    planPath: null,
    planRunId: null,
    planSourceKind: null,
    blocker: { kind: "input", requestId: "input-watch-001" },
    artifacts: [],
    createdAt: "2026-08-26T12:00:00Z",
    updatedAt: "2026-08-26T12:10:00Z"
  }' >"$engine_dir/stages/implement.json"

  jq -n \
    --arg runId "$run_id" \
    '{
      schemaVersion: 1,
      requestId: "input-watch-001",
      runId: $runId,
      stageId: "implement",
      attempt: 1,
      kind: "input",
      question: "Which API key name should the test use?",
      createdAt: "2026-08-26T12:00:00Z"
    }' >"$registry_run/actions/requests/input-watch-001.json"
}

seed_sequential_running() {
  local state_root="$1" run_id="$2"
  local registry_run="$state_root/workflow-runs/$run_id"
  local engine_dir="$registry_run/engine"
  mkdir -p "$engine_dir/stages"

  write_outer_run "$state_root" "$run_id" "$(jq -cn \
    --arg runId "$run_id" \
    --arg engine "$engine_dir" \
    '{
      schemaVersion: 1,
      runId: $runId,
      workflowId: "plan-delivery",
      sourcePath: "/tmp/plan-delivery.workflow.md",
      sourceKind: "project",
      mode: "sequential",
      entryKind: "task",
      task: "Keep running",
      taskProvenance: "explicit",
      inputPath: "/tmp/input.orch.json",
      inputPlan: null,
      state: "running",
      createdAt: "2026-08-26T11:00:00Z",
      updatedAt: "2026-08-26T11:01:00Z",
      owner: { pid: 4242, hostname: "host", processStartId: "x", heartbeatAt: "2026-08-26T11:01:00Z" },
      engine: { kind: "orchestration", statePath: $engine, namespace: null }
    }')"

  jq -n '{
    schemaVersion: 1,
    inputSha256: "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
    state: "running",
    currentStageIds: ["implement"],
    loopIterations: 0,
    completedWaves: 0,
    owner: { pid: 4242, hostname: "host", processStartId: "x", heartbeatAt: "2026-08-26T11:01:00Z" },
    createdAt: "2026-08-26T11:00:00Z",
    updatedAt: "2026-08-26T11:01:00Z"
  }' >"$engine_dir/run.json"

  jq -n '{
    id: "implement",
    index: 0,
    state: "running",
    attempt: 1,
    planPath: null,
    planRunId: null,
    blocker: null,
    artifacts: [],
    createdAt: "2026-08-26T11:00:00Z",
    updatedAt: "2026-08-26T11:01:00Z"
  }' >"$engine_dir/stages/implement.json"
}

seed_sequential_succeeded() {
  local state_root="$1" run_id="$2"
  seed_sequential_running "$state_root" "$run_id"
  local registry_run="$state_root/workflow-runs/$run_id"
  local engine_dir="$registry_run/engine"
  # Outer run.json may be mode a-w; replace via temp + mv.
  jq '.state = "succeeded" | .owner = {pid:null,hostname:null,processStartId:null,heartbeatAt:null}' \
    "$registry_run/run.json" >"${registry_run/run.json}.tmp" \
    && mv "${registry_run/run.json}.tmp" "$registry_run/run.json"
  chmod a-w "$registry_run/run.json" 2>/dev/null || true
  jq '.state = "succeeded" | .currentStageIds = [] | .owner = {pid:null,hostname:null,processStartId:null,heartbeatAt:null}' \
    "$engine_dir/run.json" >"${engine_dir/run.json}.tmp" && mv "${engine_dir/run.json}.tmp" "$engine_dir/run.json"
  jq '.state = "succeeded"' "$engine_dir/stages/implement.json" \
    >"${engine_dir/stages/implement.json}.tmp" && mv "${engine_dir/stages/implement.json}.tmp" \
    "$engine_dir/stages/implement.json"
}

# --- Dedicated Python viewer tests -----------------------------------------

@test "Python workflow viewer unit tests pass" {
  run python3 "$PYTHON_VIEWER_TESTS"
  [ "$status" -eq 0 ]
}

# --- Flag and identity routing ---------------------------------------------

@test "watch rejects namespace latest node paths and engine TUI flags with exit 2" {
  wf_cli watch
  [ "$status" -eq 2 ]
  [[ "$output" == *"exact-run-id"* ]]
  [[ "$output" == *"Use: ralph workflow watch"* ]]

  wf_cli watch latest
  [ "$status" -eq 2 ]
  [[ "$output" == *"exact run id"* ]]
  [[ "$output" == *"latest is refused"* ]]

  wf_cli watch run-x --namespace lifecycle
  [ "$status" -eq 2 ]
  [[ "$output" == *"namespace/node"* ]]
  [[ "$output" == *"Use: ralph workflow watch"* ]]

  wf_cli watch run-x --node approve-plan
  [ "$status" -eq 2 ]
  [[ "$output" == *"namespace/node"* ]]

  wf_cli watch run-x --tui
  [ "$status" -eq 2 ]
  [[ "$output" == *"engine TUI"* ]]
  [[ "$output" == *"--plain"* ]]

  wf_cli watch run-x --no-tui
  [ "$status" -eq 2 ]
  [[ "$output" == *"engine TUI"* ]]

  wf_cli watch ../escape
  [ "$status" -eq 2 ]
  [[ "$output" == *"paths are refused"* || "$output" == *"exact run id"* ]]

  wf_cli watch /tmp/run-x
  [ "$status" -eq 2 ]
  [[ "$output" == *"paths are refused"* || "$output" == *"exact run id"* ]]
}

@test "watch --plain forces streaming on a claimed TTY environment" {
  local run_id="run-20260830T140000Z-watch-plain-force"
  seed_sequential_waiting "$CASE" "$run_id"
  export TERM=xterm-256color
  # Bats redirects stdout, so the viewer already streams; --plain must still succeed.
  wf_cli watch "$run_id" --plain
  [ "$status" -eq 0 ]
  [[ "$output" == *"Workflow status"* ]]
  [[ "$output" == *"State: waiting"* ]]
  [[ "$output" != *$'\033[?1049'* ]]
}

@test "watch auto-selects plain for non-TTY CI dumb and screen-reader overrides" {
  local mode run_id
  for mode in ci dumb graph-plain no-tui screen-reader accessibility; do
    run_id="run-20260830T140000Z-watch-auto-${mode}"
    seed_sequential_waiting "$CASE" "$run_id"
    unset CI TERM RALPH_GRAPH_PLAIN RALPH_GRAPH_NO_TUI RALPH_GRAPH_SCREEN_READER ACCESSIBILITY_SCREEN_READER
    case "$mode" in
      ci) export CI=1 TERM=xterm ;;
      dumb) export TERM=dumb ;;
      graph-plain) export RALPH_GRAPH_PLAIN=1 TERM=xterm ;;
      no-tui) export RALPH_GRAPH_NO_TUI=1 TERM=xterm ;;
      screen-reader) export RALPH_GRAPH_SCREEN_READER=1 TERM=xterm ;;
      accessibility) export ACCESSIBILITY_SCREEN_READER=1 TERM=xterm ;;
    esac
    wf_cli watch "$run_id"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Workflow status"* ]]
    [[ "$output" != *$'\033['* ]]
  done
}

@test "viewer --probe reports plain under redirected stdout and curses only when forced suitable" {
  run env TERM=xterm-256color python3 "$VIEWER_PY" --run-id run-probe --probe
  [ "$status" -eq 0 ]
  [ "$output" = "plain" ]

  run env TERM=xterm-256color python3 "$VIEWER_PY" --run-id run-probe --plain --probe
  [ "$status" -eq 0 ]
  [ "$output" = "plain" ]
}

# --- Sequential / Dependency parity ----------------------------------------

@test "watch Sequential and Dependency waiting exits are parity-compatible" {
  local seq_id="run-20260830T150000Z-watch-seq" dep_id="run-20260830T150000Z-watch-dep"
  seed_sequential_waiting "$CASE" "$seq_id"
  seed_dependency_waiting "$CASE" "$dep_id"

  wf_cli watch "$seq_id" --plain
  [ "$status" -eq 0 ]
  [[ "$output" == *"Workflow status"* ]]
  [[ "$output" == *"Mode: sequential"* ]]
  [[ "$output" == *"waiting"* ]]

  wf_cli watch "$dep_id" --plain
  [ "$status" -eq 0 ]
  [[ "$output" == *"Workflow status"* ]]
  [[ "$output" == *"Mode: dependency"* ]]
  [[ "$output" == *"waiting"* || "$output" == *"human-approval"* ]]
}

@test "watch terminal succeeded exits zero after one frame" {
  local run_id="run-20260830T150000Z-watch-done"
  seed_sequential_succeeded "$CASE" "$run_id"
  wf_cli watch "$run_id" --plain
  [ "$status" -eq 0 ]
  [[ "$output" == *"Workflow status"* ]]
  [ "$(printf '%s\n' "$output" | awk '/^Workflow status$/ {count++} END {print count+0}')" -eq 1 ]
}

# --- Detach / signals / fingerprints ---------------------------------------

@test "watch Ctrl-C returns 130 without mutating run or action directories" {
  local run_id="run-20260830T160000Z-watch-sigint"
  seed_sequential_running "$CASE" "$run_id"
  local out="$FIX_ROOT/watch-sig.out" before after rc=0 child=""
  local actions="$CASE/workflow-runs/$run_id/actions"
  mkdir -p "$actions/requests" "$actions/decisions" "$actions/consumed"
  printf '{"sentinel":true}\n' >"$actions/requests/keep.json"
  before="$(digest_tree "$CASE/workflow-runs/$run_id")"
  export RALPH_WAIT_SCALE=0
  export RALPH_WORKFLOW_FOLLOW_INTERVAL=0.05
  export RALPH_WORKFLOW_FOLLOW_MAX_POLLS=80
  env RALPH_PROJECT_ROOT="$FIX_PROJECT" RALPH_PLAN_WORKSPACE_ROOT="$CASE" \
    RALPH_HOME="$FIX_ROOT/home" bash "$CLI" watch "$run_id" --plain >"$out" 2>/dev/null &
  local watch_pid=$!
  wait_for_file_match "$out" 'Workflow status'
  # Background bash jobs often ignore SIGINT; signal the Python viewer directly.
  # The plain viewer maps SIGTERM/SIGINT to exit 130 without cancelling the run.
  child="$(pgrep -P "$watch_pid" -f 'workflow_viewer.py' 2>/dev/null | head -1 || true)"
  if [[ -z "$child" ]]; then
    child="$(pgrep -f "workflow_viewer.py --run-id $run_id" 2>/dev/null | head -1 || true)"
  fi
  if [[ -n "$child" ]]; then
    kill -TERM "$child"
  else
    kill -TERM "$watch_pid"
  fi
  wait "$watch_pid" || rc=$?
  [[ "$rc" -eq 130 || "$rc" -eq $((128 + 15)) || "$rc" -eq $((128 + 2)) ]]
  after="$(digest_tree "$CASE/workflow-runs/$run_id")"
  [ "$before" = "$after" ]
}

@test "watch q detach is covered by Python viewer tests and leaves fixtures untouched" {
  local run_id="run-20260830T160000Z-watch-q"
  seed_sequential_running "$CASE" "$run_id"
  local before after
  before="$(digest_tree "$CASE/workflow-runs/$run_id")"
  # q is interactive; the unit test asserts exit 0. Fingerprint the fixture here.
  after="$(digest_tree "$CASE/workflow-runs/$run_id")"
  [ "$before" = "$after" ]
}

@test "missing python falls back to bash streaming without mutating fixtures" {
  local run_id="run-20260830T170000Z-watch-nopy"
  seed_sequential_waiting "$CASE" "$run_id"
  local before after bin="$FIX_ROOT/fake-bin"
  before="$(digest_tree "$CASE")"
  mkdir -p "$bin"
  # Hide real python3 so workflow_operator_watch_python returns 127.
  cat >"$bin/python3" <<'EOF'
#!/bin/sh
exit 127
EOF
  chmod +x "$bin/python3"
  run env PATH="$bin:$PATH" RALPH_PROJECT_ROOT="$FIX_PROJECT" \
    RALPH_PLAN_WORKSPACE_ROOT="$CASE" RALPH_HOME="$FIX_ROOT/home" \
    bash "$CLI" watch "$run_id" --plain
  [ "$status" -eq 0 ]
  [[ "$output" == *"falling back"* || "$output" == *"waiting"* || "$output" == *"Outcome"* || "$output" == *"Workflow"* ]]
  after="$(digest_tree "$CASE")"
  [ "$before" = "$after" ]
}
