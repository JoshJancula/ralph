#!/usr/bin/env bats
# `ralph workflow runs` and `ralph workflow status` over static registry fixtures.
#
# Invokes the public workflow CLI only. Fixtures are written directly; no engine,
# runtime, or live-state polling is ever started.

bats_require_minimum_version 1.5.0

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

CLI="$REPO_ROOT/bundle/.ralph/workflow-cli.sh"
STATE_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/workflow/workflow-state.sh"
SEQ_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/workflow/workflow-engine-sequential.sh"
STATUS_SCHEMA="$REPO_ROOT/bundle/.ralph/schemas/workflow-status.schema.json"
ARTIFACT_SCHEMA_PY="$REPO_ROOT/bundle/.ralph/python/artifact_json_schema.py"
OPVIEW="$REPO_ROOT/bundle/.ralph/bash-lib/workflow/workflow-operator-view.sh"

setup_file() {
  # Watch/status fixtures share FIX_ROOT; within-file parallelization races the
  # Python viewer subprocesses under -j N and produces intermittent non-zero
  # watch exits. Serialize this file; other bats files still run in parallel.
  export BATS_NO_PARALLELIZE_WITHIN_FILE=true
  command -v jq >/dev/null || skip "jq required"
  [ -f "$CLI" ]
  [ -f "$STATE_LIB" ]
  [ -f "$STATUS_SCHEMA" ]
  [ -f "$ARTIFACT_SCHEMA_PY" ]

  FIX_ROOT="$(mktemp -d "${BATS_TMPDIR:-/tmp}/wlc.XXXXXX")"
  FIX_ROOT="$(cd "$FIX_ROOT" && pwd -P)"
  FIX_PROJECT="$FIX_ROOT/project"
  FIX_STATE="$FIX_PROJECT/.ralph-workspace"
  mkdir -p "$FIX_STATE" "$FIX_ROOT/home"
  export FIX_ROOT FIX_PROJECT FIX_STATE
}

teardown_file() {
  rm -rf "$FIX_ROOT"
}

setup() {
  unset RALPH_WORKFLOW_STATE_ROOT RALPH_PLAN_WORKSPACE_ROOT RALPH_GRAPH_STATE_ROOT
  unset WORKFLOW_STATE_FIXED_RUN_ID WORKFLOW_STATE_FIXED_NOW WORKFLOW_STATE_SKIP_FSYNC
  unset RALPH_SEQ_STAGE_LOG_DIR RALPH_GRAPH_NODE_LOG_DIR RALPH_GRAPH_NODE_LOG_PATH
  # Isolate from ambient workflow-stage identity when bats runs under a live plan.
  unset RALPH_WORKFLOW_RUN_ID RALPH_WORKFLOW_STAGE_ID RALPH_WORKFLOW_STAGE_ATTEMPT
  unset RALPH_WORKFLOW_REGISTRY_RUN RALPH_WORKFLOW_ACTION_NONCE
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

validate_status_json() {
  local json="$1" artifact="$CASE/status.json"
  printf '%s' "$json" >"$artifact"
  python3 "$ARTIFACT_SCHEMA_PY" validate-final-output \
    --schema "$STATUS_SCHEMA" \
    --artifact "$artifact"
}

digest_tree() {
  find "$1" -type f ! -path '*/.create.lock' | LC_ALL=C sort | xargs cksum 2>/dev/null | cksum | awk '{print $1}'
}

write_outer_run() {
  local state_root="$1" run_id="$2" body="$3"
  local run_dir="$state_root/workflow-runs/$run_id"
  mkdir -p "$run_dir"
  printf '%s' "$body" >"$run_dir/run.json"
  chmod a-w "$run_dir/run.json" 2>/dev/null || true
}

write_minimal_graph_json() {
  local path="$1"
  jq -n '{
    schemaVersion: 1,
    namespace: "lifecycle",
    maxParallel: 2,
    nodes: [
      {
        id: "implement",
        type: "agent",
        dependsOn: [],
        derivedFrom: "stage",
        stage: { id: "implement", runtime: "cursor" }
      },
      {
        id: "approve-plan",
        type: "approval",
        dependsOn: ["implement"],
        derivedFrom: "stage",
        stage: {
          id: "approve-plan",
          question: "Approve the implementation plan?",
          changesTarget: "implement"
        }
      }
    ],
    edges: [{ from: "implement", to: "approve-plan" }]
  }' >"$path"
}

seed_dependency_task_run() {
  local state_root="$1" run_id="$2"
  local graph_dir="$state_root/graph-runs/lifecycle/$run_id"
  local registry_run="$state_root/workflow-runs/$run_id"
  local sourcep="$registry_run/plans/implement/attempt-1/source.plan.md"
  local controlp="$registry_run/plans/implement/attempt-1/control.plan.md"
  local graph_json="$graph_dir/graph.json"

  mkdir -p "$registry_run/plans/implement/attempt-1" "$graph_dir/nodes"
  printf '# plan\n- [ ] work\n' >"$sourcep"
  cp -f "$sourcep" "$controlp"
  write_minimal_graph_json "$graph_json"

  write_outer_run "$state_root" "$run_id" "$(jq -cn \
    --arg runId "$run_id" \
    --arg input "$registry_run/input.plan.md" \
    --arg graph "$graph_dir" \
    '{
      schemaVersion: 1,
      runId: $runId,
      workflowId: "feature-delivery",
      sourcePath: "/tmp/wf.md",
      sourceKind: "project",
      mode: "dependency",
      entryKind: "task",
      task: "Fix the timeout regression",
      taskProvenance: "explicit",
      inputPath: $input,
      inputPlan: null,
      state: "waiting",
      createdAt: "2026-08-26T10:00:00Z",
      updatedAt: "2026-08-26T10:05:00Z",
      owner: { pid: null, hostname: null, processStartId: null, heartbeatAt: null },
      engine: { kind: "graph", statePath: $graph, namespace: "lifecycle" }
    }')"
  printf '# plan\n- [ ] work\n' >"$registry_run/input.plan.md"

  jq -n '{
    schemaVersion: 3,
    runId: $runId,
    namespace: "lifecycle",
    status: "awaiting-operator",
    startedAt: "2026-08-26T10:00:00Z",
    heartbeatAt: null,
    supervisorPid: null,
    registryRunPath: $registry
  }' --arg runId "$run_id" --arg registry "$registry_run" >"$graph_dir/run.json"

  jq -n --arg source "$sourcep" --arg control "$controlp" --arg attempt "implement__${run_id}__1" '{
    schemaVersion: 3,
    nodeId: "implement",
    status: "running",
    lastAttemptId: $attempt,
    planPath: $control,
    planRunId: "implement-run-1",
    planSourceKind: "generated",
    planSourceStageId: "plan-implementation",
    originalPlanPath: null,
    sourcePlanPath: $source,
    controlPlanPath: $control,
    currentTodoId: "implement-core",
    completedTodos: 1,
    totalTodos: 3,
    blocker: null,
    attempts: []
  }' >"$graph_dir/nodes/implement.json"

  jq -n --arg attempt "approve-plan__${run_id}__1" '{
    schemaVersion: 3,
    nodeId: "approve-plan",
    status: "awaiting-operator",
    lastAttemptId: $attempt,
    blocker: {
      kind: "approval",
      requestId: "appr-lifecycle-001",
      reasonCode: "human-approval",
      retryable: false,
      changesTarget: "implement"
    },
    attempts: []
  }' >"$graph_dir/nodes/approve-plan.json"

  mkdir -p "$registry_run/actions/requests"
  jq -n --arg runId "$run_id" --arg attempt "approve-plan__${run_id}__1" '{
    requestId: "appr-lifecycle-001",
    kind: "approval",
    runId: $runId,
    stageId: "approve-plan",
    attemptId: $attempt,
    question: "Approve the implementation plan?",
    changesTarget: "implement",
    evidence: [{ path: "/tmp/evidence.md", sha256: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" }],
    choices: ["approve","request-changes","cancel"],
    createdAt: "2026-08-26T10:05:00Z"
  }' >"$registry_run/actions/requests/appr-lifecycle-001.json"
}

seed_sequential_plan_run() {
  local state_root="$1" run_id="$2"
  local registry_run="$state_root/workflow-runs/$run_id"
  local engine_dir="$registry_run/engine"
  local sourcep="$registry_run/plans/input/source.plan.md"
  local originalp="$state_root/operator/feature.plan.md"
  local controlp="$registry_run/plans/implement/attempt-1/control.plan.md"
  local orch="$registry_run/input.orch.json"

  mkdir -p "$engine_dir/stages" "$registry_run/plans/implement/attempt-1" \
    "$registry_run/plans/input" "$(dirname "$originalp")"
  printf '# feature\n- [ ] ship\n' >"$originalp"
  cp -f "$originalp" "$sourcep"
  cp -f "$sourcep" "$controlp"

  jq -n '{
    schemaVersion: 1,
    stages: [
      { id: "implement", runtime: "cursor" },
      { id: "approve-plan", type: "approval", question: "Approve?", changesTarget: "implement" }
    ]
  }' >"$orch"

  write_outer_run "$state_root" "$run_id" "$(jq -cn \
    --arg runId "$run_id" \
    --arg input "$orch" \
    --arg original "$originalp" \
    --arg source "$sourcep" \
    --arg manifest "$registry_run/plans/input/manifest.json" \
    --arg engine "$engine_dir" \
    '{
      schemaVersion: 1,
      runId: $runId,
      workflowId: "plan-delivery",
      sourcePath: "/tmp/plan-delivery.workflow.md",
      sourceKind: "project",
      mode: "sequential",
      entryKind: "plan",
      task: "Execute supplied feature plan",
      taskProvenance: "plan-overview",
      inputPath: $input,
      inputPlan: {
        originalPath: $original,
        sourcePath: $source,
        manifestPath: $manifest,
        sha256: "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        format: "classic",
        totalTodos: 2,
        completedTodos: 0,
        openTodos: 2
      },
      state: "running",
      createdAt: "2026-08-26T11:00:00Z",
      updatedAt: "2026-08-26T11:01:00Z",
      owner: { pid: null, hostname: null, processStartId: null, heartbeatAt: null },
      engine: { kind: "orchestration", statePath: $engine, namespace: null }
    }')"

  jq -n '{
    schemaVersion: 1,
    inputSha256: "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
    state: "running",
    currentStageIds: ["implement"],
    loopIterations: 0,
    completedWaves: 0,
    owner: { pid: null, hostname: null, processStartId: null, heartbeatAt: null },
    createdAt: "2026-08-26T11:00:00Z",
    updatedAt: "2026-08-26T11:01:00Z"
  }' >"$engine_dir/run.json"

  jq -n '{
    id: "implement",
    index: 0,
    state: "running",
    attempt: 1,
    planPath: $control,
    planRunId: "implement-run-seq",
    planSourceKind: "provided",
    planSourceStageId: null,
    originalPlanPath: $original,
    sourcePlanPath: $source,
    controlPlanPath: $control,
    currentTodoId: "ship",
    completedTodos: 0,
    totalTodos: 2,
    blocker: null,
    artifacts: [],
    createdAt: "2026-08-26T11:00:00Z",
    updatedAt: "2026-08-26T11:01:00Z"
  }' --arg original "$originalp" --arg source "$sourcep" --arg control "$controlp" \
    >"$engine_dir/stages/implement.json"
}

seed_sequential_input_run() {
  local state_root="$1" run_id="$2"
  local registry_run="$state_root/workflow-runs/$run_id"
  local engine_dir="$registry_run/engine"
  local orch="$registry_run/input.orch.json"

  mkdir -p "$engine_dir/stages"
  jq -n '{ schemaVersion: 1, stages: [{ id: "implement", runtime: "cursor" }] }' >"$orch"

  write_outer_run "$state_root" "$run_id" "$(jq -cn \
    --arg runId "$run_id" \
    --arg input "$orch" \
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
      inputPath: $input,
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
    planSourceStageId: null,
    originalPlanPath: null,
    sourcePlanPath: null,
    controlPlanPath: null,
    currentTodoId: null,
    completedTodos: 0,
    totalTodos: 0,
    blocker: {
      kind: "input",
      requestId: "input-lifecycle-001",
      retryable: false
    },
    artifacts: [],
    createdAt: "2026-08-26T12:00:00Z",
    updatedAt: "2026-08-26T12:10:00Z"
  }' >"$engine_dir/stages/implement.json"

  mkdir -p "$registry_run/actions/requests"
  jq -n '{
    requestId: "input-lifecycle-001",
    kind: "input",
    runId: $runId,
    stageId: "implement",
    attemptId: "implement-1",
    question: "Which API key name should the test use?",
    choices: ["answer","cancel"],
    createdAt: "2026-08-26T12:10:00Z"
  }' --arg runId "$run_id" >"$registry_run/actions/requests/input-lifecycle-001.json"
}

seed_many_runs() {
  local state_root="$1" count="$2"
  local i id wf state
  for i in $(seq 1 "$count"); do
    id="$(printf 'run-20260826T120000Z-%03d-fixed' "$i")"
    wf="bug-fix"
    state="running"
    if (( i % 3 == 0 )); then state="waiting"; wf="plan-delivery"; fi
    if (( i % 5 == 0 )); then state="succeeded"; fi
    write_outer_run "$state_root" "$id" "$(jq -cn \
      --arg runId "$id" --arg wf "$wf" --arg state "$state" --arg ts "2026-08-26T$(printf '%02d' $i):00:00Z" \
      '{
        schemaVersion: 1, runId: $runId, workflowId: $wf, sourcePath: "/tmp/w.md",
        sourceKind: "project", mode: "sequential", entryKind: "task", task: "bulk",
        taskProvenance: "explicit", inputPath: "/tmp/in.orch.json", inputPlan: null,
        state: $state, createdAt: $ts, updatedAt: $ts,
        owner: { pid: null, hostname: null, processStartId: null, heartbeatAt: null },
        engine: { kind: "orchestration", statePath: "/tmp/no-engine", namespace: null }
      }')"
  done
}

# --- runs listing -----------------------------------------------------------

@test "runs defaults to 20 newest runs" {
  seed_many_runs "$CASE" 25
  wf_cli runs
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^run-')" -eq 20 ]
}

@test "runs --limit caps the listing" {
  seed_many_runs "$CASE" 25
  wf_cli runs --limit 5
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^run-')" -eq 5 ]
}

@test "runs --all lists every run" {
  seed_many_runs "$CASE" 25
  wf_cli runs --all
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^run-')" -eq 25 ]
}

@test "runs filters by --state and --workflow" {
  seed_many_runs "$CASE" 15
  wf_cli runs --state waiting --workflow plan-delivery
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -ge 1 ]
  [[ "$output" == *"waiting"* ]]
  [[ "$output" == *"plan-delivery"* ]]
  wf_cli runs --state succeeded
  [ "$status" -eq 0 ]
  [[ "$output" == *"succeeded"* ]]
}

@test "runs --json emits an array of outer run summaries" {
  seed_many_runs "$CASE" 3
  wf_cli runs --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e 'type == "array" and length == 3 and .[0].runId != null'
}

@test "runs --tsv emits the stable six-column schema" {
  seed_many_runs "$CASE" 2
  wf_cli runs --tsv
  [ "$status" -eq 0 ]
  [[ "$output" != *$'\033['* ]]
  local lines cols
  lines="$(printf '%s\n' "$output" | grep -c '^run-')"
  [ "$lines" -eq 2 ]
  cols="$(printf '%s\n' "$output" | head -n1 | awk -F'\t' '{print NF}')"
  [ "$cols" -eq 6 ]
}

# --- status: Sequential task entry with plan-run ---------------------------

@test "Sequential status shows task entry and plan-run attribution" {
  local run_id="run-20260826T110000Z-seq-task"
  seed_sequential_plan_run "$CASE" "$run_id"
  wf_cli status "$run_id" --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    .schemaVersion == 1
    and .run.entryKind == "plan"
    and .run.taskProvenance == "plan-overview"
    and (.stages | map(select(.id=="implement")) | length) == 1
    and (.stages[] | select(.id=="implement") | .planRunId) == "implement-run-seq"
    and (.stages[] | select(.id=="implement") | .planSourceKind) == "provided"
    and (.stages[] | select(.id=="implement") | .planSourceStageId) == null
    and (.stages[] | select(.id=="implement") | .currentTodoId) == "ship"
  ' >/dev/null
  run validate_status_json "$output"
  [ "$status" -eq 0 ]
}

@test "Sequential status text includes provided source paths" {
  local run_id="run-20260826T110000Z-seq-plan"
  seed_sequential_plan_run "$CASE" "$run_id"
  wf_cli status "$run_id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Entry: plan"* ]]
  # Standardized operator output labels the supplied original / frozen source /
  # control copies without exposing the internal namespace.
  [[ "$output" == *"Plan source: provided"* ]]
  [[ "$output" == *"Plan producer: null"* ]]
  [[ "$output" == *"Original plan:"* ]]
  [[ "$output" == *"Supplied source:"* ]]
  [[ "$output" == *"Control plan:"* ]]
  [[ "$output" == *"Plan progress: 0/2 TODO ship"* ]]
}

# --- status: Dependency + approval -----------------------------------------

@test "Dependency status shows approval without fake plan progress" {
  local run_id="run-20260826T100000Z-dep-task"
  seed_dependency_task_run "$CASE" "$run_id"
  wf_cli status "$run_id" --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    .run.mode == "dependency"
    and .run.entryKind == "task"
    and (.stages[] | select(.id=="approve-plan") | .stageKind) == "approval"
    and (.stages[] | select(.id=="approve-plan") | .completedTodos) == 0
    and (.stages[] | select(.id=="approve-plan") | .approval.question) != ""
    and (.stages[] | select(.id=="approve-plan") | .requestId) == "appr-lifecycle-001"
  ' >/dev/null
  run validate_status_json "$output"
  [ "$status" -eq 0 ]
}

@test "Dependency status text names approval question and changesTarget" {
  local run_id="run-20260826T100000Z-dep-appr"
  seed_dependency_task_run "$CASE" "$run_id"
  wf_cli status "$run_id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Entry: task (explicit)"* ]]
  [[ "$output" == *"approve-plan"* ]]
  [[ "$output" == *"Question: Approve the implementation plan?"* ]]
  [[ "$output" == *"Changes target: implement"* ]]
  [[ "$output" == *"appr-lifecycle-001"* ]]
}

# --- status: operator input ------------------------------------------------

@test "Sequential operator input status points to actions list" {
  local run_id="run-20260826T120000Z-seq-input"
  seed_sequential_input_run "$CASE" "$run_id"
  wf_cli status "$run_id" --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e --arg runId "$run_id" '
    .diagnosis.reasonCode == "operator-input"
    and .nextAction.argv == ["ralph","workflow","actions","list",$runId]
  ' >/dev/null
  wf_cli status "$run_id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ralph workflow actions list $run_id"* ]]
}

# --- read only + next action -----------------------------------------------

@test "status is read only and never mutates fixture files" {
  local run_id="run-20260826T100000Z-readonly"
  seed_dependency_task_run "$CASE" "$run_id"
  local before after
  before="$(digest_tree "$CASE")"
  wf_cli status "$run_id"
  [ "$status" -eq 0 ]
  wf_cli status "$run_id" --json >/dev/null
  [ "$status" -eq 0 ]
  after="$(digest_tree "$CASE")"
  [ "$before" = "$after" ]
}

@test "failed Dependency status and handoff expose the retained code workspace" {
  local run_id="run-20260826T110000Z-handoff"
  local graph_dir="$CASE/graph-runs/lifecycle/$run_id"
  local workspace="$graph_dir/workspaces/nodes/implement-test"
  local manifest="$graph_dir/changesets/nodes/implement-test.json"
  seed_dependency_task_run "$CASE" "$run_id"
  mkdir -p "$workspace" "$(dirname "$manifest")"
  jq '.state = "failed"' "$CASE/workflow-runs/$run_id/run.json" >"$CASE/outer.tmp"
  mv "$CASE/outer.tmp" "$CASE/workflow-runs/$run_id/run.json"
  jq --arg workspace "$workspace" --arg manifest "$manifest" '
    .status = "failed"
    | .workspaceMode = "worktree"
    | .workspacePath = $workspace
    | .changesetManifest = $manifest
    | .attempts = [{attemptId:"implement__run__1", workspaceMode:"worktree",
                    workspacePath:$workspace, reason:"runtime-failed"}]
  ' "$graph_dir/nodes/implement.json" >"$CASE/node.tmp"
  mv "$CASE/node.tmp" "$graph_dir/nodes/implement.json"
  jq '.status = "skipped" | .blocker = null' "$graph_dir/nodes/approve-plan.json" >"$CASE/approval.tmp"
  mv "$CASE/approval.tmp" "$graph_dir/nodes/approve-plan.json"
  jq --arg workspace "$workspace" '
    .status = "failed"
    | .roots = {projectRoot:$workspace,stateRoot:$workspace,agentWorkspace:$workspace}
    | .sourceBase = {git:{head:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}
  ' "$graph_dir/run.json" >"$CASE/graph-run.tmp"
  mv "$CASE/graph-run.tmp" "$graph_dir/run.json"
  jq -n --arg manifest "$manifest" '{
    schemaVersion:1, kind:"graph-changeset", nodeId:"implement",
    changes:[{path:"src/model.sh"},{path:"tests/model.bats"}]
  }' >"$manifest"

  wf_cli status "$run_id" --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e --arg workspace "$workspace" --arg manifest "$manifest" '
    .stages[] | select(.id == "implement")
    | .workspaceMode == "worktree"
      and .workspacePath == $workspace
      and .workspaceAvailable == true
      and .baseRevision == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      and .changesetManifest == $manifest
      and .changedFiles == ["src/model.sh", "tests/model.bats"]
  ' >/dev/null

  wf_cli handoff "$run_id"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Workflow task handoff"* ]]
  [[ "$output" == *"Workspace: worktree (available)"* ]]
  [[ "$output" == *"Git worktree: yes"* ]]
  [[ "$output" == *"Open code: cd $workspace"* ]]
  [[ "$output" == *"Changeset: $manifest"* ]]
  [[ "$output" == *"src/model.sh"* ]]

  wf_cli handoff "$run_id" --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.run.runId')" = "$run_id" ]
}

@test "status ends with one safe next action or none required" {
  local run_id="run-20260826T120000Z-next"
  seed_sequential_input_run "$CASE" "$run_id"
  wf_cli status "$run_id"
  [ "$status" -eq 0 ]
  # Standardized operator output prints exactly one applicable action line.
  [ "$(printf '%s\n' "$output" | grep -c '^Action: ')" -eq 1 ]
  [[ "$output" == *"Action: ralph workflow actions list $run_id"* ]]

  run_id="run-20260826T999999Z-succeeded"
  write_outer_run "$CASE" "$run_id" "$(jq -cn \
    --arg runId "$run_id" \
    '{
      schemaVersion: 1, runId: $runId, workflowId: "bug-fix", sourcePath: "/tmp/w.md",
      sourceKind: "project", mode: "sequential", entryKind: "task", task: "done",
      taskProvenance: "explicit", inputPath: "/tmp/in.json", inputPlan: null,
      state: "succeeded", createdAt: "2026-08-26T23:00:00Z", updatedAt: "2026-08-26T23:00:00Z",
      owner: { pid: null, hostname: null, processStartId: null, heartbeatAt: null },
      engine: { kind: "orchestration", statePath: "/tmp/no-engine", namespace: null }
    }')"
  wf_cli status "$run_id"
  [ "$status" -eq 0 ]
  # A terminal run still prints exactly one action line, saying none is needed.
  [ "$(printf '%s\n' "$output" | grep -c '^Action: ')" -eq 1 ]
  [[ "$output" == *"Action: none required"* ]]
}

# --- watch / logs -----------------------------------------------------------

wait_for_file_match() {
  local file="$1" pattern="$2" attempts="${3:-200}"
  local i=0
  while [[ "$i" -lt "$attempts" ]]; do
    if grep -q -- "$pattern" "$file" 2>/dev/null; then
      return 0
    fi
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

wait_pid_exit() {
  local pid="$1" attempts="${2:-400}"
  local i=0 st=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 0.05
    i=$((i + 1))
    if [[ "$i" -ge "$attempts" ]]; then
      kill -TERM "$pid" 2>/dev/null || true
      sleep 0.1
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 1
    fi
  done
  wait "$pid" || st=$?
  return "$st"
}

write_dep_stage_logs() {
  local state_root="$1" run_id="$2" stage_id="$3" attempt_n="$4"
  local graph_dir="$state_root/graph-runs/lifecycle/$run_id"
  local attempt_id="${stage_id}__${run_id}__${attempt_n}"
  local log_dir="$graph_dir/logs/nodes/${stage_id}/${attempt_id}"
  mkdir -p "$log_dir" "$graph_dir/nodes"
  printf 'agent-line-1\nagent-line-2\n' >"$log_dir/agent.log"
  printf 'runner-line-1\n' >"$log_dir/runner.log"
  jq -nc \
    --arg nodeId "$stage_id" \
    --arg attemptId "$attempt_id" \
    --arg runner "logs/nodes/${stage_id}/${attempt_id}/runner.log" \
    --arg agent "logs/nodes/${stage_id}/${attempt_id}/agent.log" \
    '{
      schemaVersion: 3,
      nodeId: $nodeId,
      status: "running",
      lastAttemptId: $attemptId,
      attempts: [{
        attemptId: $attemptId,
        logPaths: {runner:$runner, agent:$agent}
      }]
    }' >"$graph_dir/nodes/${stage_id}.json"
}

# Fixture-only writer for pure CLI unit paths (follow, combined parsing, etc.).
# Prefer workflow_seq_prepare_stage_logs for production-path coverage.
write_seq_stage_logs() {
  local state_root="$1" run_id="$2" stage_id="$3" attempt_n="$4"
  local registry_run="$state_root/workflow-runs/$run_id"
  local log_dir="$registry_run/engine/logs/stages/${stage_id}/attempt-${attempt_n}"
  mkdir -p "$log_dir"
  printf 'seq-agent-1\nseq-agent-2\n' >"$log_dir/agent.log"
  printf 'seq-runner-1\n' >"$log_dir/runner.log"
}

# Thin harness: call the Sequential production prepare/export helpers, then
# append bytes the way run-plan / orchestrator would under RALPH_GRAPH_NODE_LOG_DIR.
# Sets PREPARE_SEQ_LOG_DIR in the caller (must not run under command substitution).
prepare_seq_stage_logs_via_production() {
  local state_root="$1" run_id="$2" stage_id="$3" attempt_n="$4"
  local registry_run="$state_root/workflow-runs/$run_id"
  local log_dir
  # shellcheck source=/dev/null
  source "$SEQ_LIB"
  log_dir="$(workflow_seq_prepare_stage_logs "$registry_run" "$stage_id" "$attempt_n")" || return 1
  workflow_seq_export_stage_log_dir "$log_dir" || return 1
  printf 'prod-agent-1\nprod-agent-2\n' >>"$RALPH_GRAPH_NODE_LOG_DIR/agent.log"
  printf 'prod-runner-1\n' >>"$RALPH_SEQ_STAGE_LOG_DIR/runner.log"
  PREPARE_SEQ_LOG_DIR="$log_dir"
}

write_dep_events() {
  local state_root="$1" run_id="$2"
  local graph_dir="$state_root/graph-runs/lifecycle/$run_id"
  mkdir -p "$graph_dir"
  printf '%s\n' \
    '{"schemaVersion":1,"sequence":1,"timestamp":"2026-08-26T10:00:00Z","runId":"'"$run_id"'","event":"run-started","nodeId":"implement","details":{"status":"running"}}' \
    >"$graph_dir/events.jsonl"
}

write_seq_events() {
  local state_root="$1" run_id="$2"
  local registry_run="$state_root/workflow-runs/$run_id"
  mkdir -p "$registry_run/engine"
  printf '%s\n' \
    '{"schemaVersion":1,"sequence":0,"timestamp":"2026-08-26T11:00:00Z","runId":"'"$run_id"'","stageId":"implement","event":"stage-started","priorState":null,"newState":"running","details":{}}' \
    >"$registry_run/engine/events.jsonl"
}

@test "watch prints status and action event for dependency approval" {
  local run_id="run-20260826T100000Z-watch-dep"
  export RALPH_WAIT_SCALE=0
  export RALPH_WORKFLOW_FOLLOW_INTERVAL=0.05
  export RALPH_WORKFLOW_FOLLOW_MAX_POLLS=1
  seed_dependency_task_run "$CASE" "$run_id"
  write_dep_events "$CASE" "$run_id"
  wf_cli watch "$run_id" --plain
  [ "$status" -eq 0 ]
  [[ "$output" == *"Workflow status"* ]]
  [[ "$output" == *"approve-plan"* ]]
  [[ "$output" == *"human-approval"* ]]
  [[ "$output" == *"ralph workflow actions list"* ]]
  ! printf '%s\n' "$output" | grep -q 'namespace='
  ! printf '%s\n' "$output" | grep -q 'node='
}

@test "watch prints input action event for sequential operator input" {
  local run_id="run-20260826T120000Z-watch-input"
  export RALPH_WAIT_SCALE=0
  export RALPH_WORKFLOW_FOLLOW_INTERVAL=0.05
  export RALPH_WORKFLOW_FOLLOW_MAX_POLLS=1
  seed_sequential_input_run "$CASE" "$run_id"
  write_seq_events "$CASE" "$run_id"
  wf_cli watch "$run_id" --plain
  [ "$status" -eq 0 ]
  [[ "$output" == *"Workflow status"* ]]
  [[ "$output" == *"operator-input"* ]]
  [[ "$output" == *"ralph workflow actions list $run_id"* ]]
}

@test "watch redacts credential-looking question text" {
  local run_id="run-20260826T120000Z-watch-redact"
  export RALPH_WAIT_SCALE=0
  export RALPH_WORKFLOW_FOLLOW_INTERVAL=0.05
  export RALPH_WORKFLOW_FOLLOW_MAX_POLLS=1
  seed_sequential_input_run "$CASE" "$run_id"
  local req="$CASE/workflow-runs/$run_id/actions/requests/input-lifecycle-001.json"
  jq '.question = "Use api_key=super-secret-token-value"' "$req" >"${req}.tmp" && mv "${req}.tmp" "$req"
  wf_cli watch "$run_id" --plain
  [ "$status" -eq 0 ]
  [[ "$output" == *"Workflow status"* ]]
  ! printf '%s\n' "$output" | grep -q 'super-secret-token-value'
}

@test "plain watch is deterministic and accessible in every forced text environment" {
  local mode run_id
  local -a watch_args
  for mode in non-tty plain no-color ci dumb-term graph-screen-reader accessibility-screen-reader; do
    run_id="run-20260830T120000Z-watch-${mode}"
    seed_sequential_input_run "$CASE" "$run_id"
    write_seq_events "$CASE" "$run_id"
    export RALPH_WAIT_SCALE=0 RALPH_WORKFLOW_FOLLOW_MAX_POLLS=1 RALPH_WORKFLOW_FOLLOW_INTERVAL=0.05
    unset NO_COLOR CI TERM RALPH_GRAPH_PLAIN RALPH_GRAPH_SCREEN_READER ACCESSIBILITY_SCREEN_READER
    case "$mode" in
      plain) export RALPH_GRAPH_PLAIN=1 ;;
      no-color) export NO_COLOR=1 ;;
      ci) export CI=1 ;;
      dumb-term) export TERM=dumb ;;
      graph-screen-reader) export RALPH_GRAPH_SCREEN_READER=1 ;;
      accessibility-screen-reader) export ACCESSIBILITY_SCREEN_READER=1 ;;
    esac
    watch_args=(watch "$run_id")
    [[ "$mode" == "plain" ]] && watch_args+=(--plain)
    wf_cli "${watch_args[@]}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Workflow status"* ]]
    [[ "$output" == *"State: waiting (operator-input)"* ]]
    [[ "$output" == *"Question: Which API key name should the test use?"* ]]
    [[ "$output" == *"Action: answer the outstanding request:"* ]]
    [ "$(printf '%s\n' "$output" | awk '/^Workflow status$/ {count++} END {print count+0}')" -eq 1 ]
    [[ "$output" != *$'\033['* ]]
    [[ "$output" != *$'\033[?1049'* ]]
  done
  unset NO_COLOR CI TERM RALPH_GRAPH_PLAIN RALPH_GRAPH_SCREEN_READER ACCESSIBILITY_SCREEN_READER
}

@test "status JSON and workflow runs TSV keep stdout free of diagnostics" {
  local run_id="run-20260830T130000Z-separation"
  seed_sequential_input_run "$CASE" "$run_id"
  run --separate-stderr env RALPH_PROJECT_ROOT="$FIX_PROJECT" RALPH_PLAN_WORKSPACE_ROOT="$CASE" \
    RALPH_HOME="$FIX_ROOT/home" bash "$CLI" status "$run_id" --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.run.runId == "run-20260830T130000Z-separation"' >/dev/null
  [ -z "$stderr" ]
  [[ "$output" != *$'\033['* ]]

  run --separate-stderr env RALPH_PROJECT_ROOT="$FIX_PROJECT" RALPH_PLAN_WORKSPACE_ROOT="$CASE" \
    RALPH_HOME="$FIX_ROOT/home" bash "$CLI" runs
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\t'* ]]
  [ -z "$stderr" ]
  [[ "$output" != *$'\033['* ]]
}

@test "logs dependency stage attempt stream agent uses public selectors only" {
  local run_id="run-20260826T100000Z-logs-dep"
  seed_dependency_task_run "$CASE" "$run_id"
  write_dep_stage_logs "$CASE" "$run_id" "implement" 1
  run --separate-stderr env RALPH_PROJECT_ROOT="$FIX_PROJECT" RALPH_PLAN_WORKSPACE_ROOT="$CASE" \
    RALPH_HOME="$FIX_ROOT/home" bash "$CLI" logs "$run_id" --stage implement --attempt 1 --stream agent --no-follow
  [ "$status" -eq 0 ]
  [ "$output" = $'agent-line-1\nagent-line-2' ]
  printf '%s\n' "$stderr" | grep -q '# workflow logs'
  printf '%s\n' "$stderr" | grep -q 'stage=implement'
  printf '%s\n' "$stderr" | grep -q 'attempt=1'
  printf '%s\n' "$stderr" | grep -q 'stream=agent'
  ! printf '%s\n' "$stderr" | grep -q 'namespace'
}

@test "logs dependency stage resolves an exact state root without inherited graph root env" {
  local run_id="run-20260826T100000Z-logs-dep-root"
  seed_dependency_task_run "$CASE" "$run_id"
  write_dep_stage_logs "$CASE" "$run_id" "implement" 1
  unset RALPH_PLAN_WORKSPACE_ROOT RALPH_GRAPH_STATE_ROOT
  # shellcheck source=/dev/null
  source "$OPVIEW"

  run --separate-stderr workflow_operator_logs "$CASE" "$run_id" \
    --stage implement --attempt 1 --stream agent --no-follow
  [ "$status" -eq 0 ]
  [ "$output" = $'agent-line-1\nagent-line-2' ]
  [[ "$stderr" == *"# workflow logs  run=$run_id"* ]]
}

@test "logs sequential supervisor stream prints runner log" {
  local run_id="run-20260826T110000Z-logs-seq"
  seed_sequential_plan_run "$CASE" "$run_id"
  write_seq_stage_logs "$CASE" "$run_id" "implement" 1
  run --separate-stderr env RALPH_PROJECT_ROOT="$FIX_PROJECT" RALPH_PLAN_WORKSPACE_ROOT="$CASE" \
    RALPH_HOME="$FIX_ROOT/home" bash "$CLI" logs "$run_id" --stage implement --attempt 1 --stream supervisor --no-follow
  [ "$status" -eq 0 ]
  [ "$output" = $'seq-runner-1' ]
}

@test "logs combined stream prints supervisor then agent bytes" {
  local run_id="run-20260826T110000Z-logs-combined"
  seed_sequential_plan_run "$CASE" "$run_id"
  write_seq_stage_logs "$CASE" "$run_id" "implement" 1
  wf_cli logs "$run_id" --stage implement --stream combined --no-follow
  [ "$status" -eq 0 ]
  [[ "$output" == *"seq-runner-1"* ]]
  [[ "$output" == *"seq-agent-1"* ]]
}

@test "logs follow prints new lines and exits when stage becomes terminal" {
  local run_id="run-20260826T110000Z-logs-follow"
  seed_sequential_plan_run "$CASE" "$run_id"
  write_seq_stage_logs "$CASE" "$run_id" "implement" 1
  local out="$FIX_ROOT/follow.out" err="$FIX_ROOT/follow.err"
  local log_file="$CASE/workflow-runs/$run_id/engine/logs/stages/implement/attempt-1/agent.log"
  local stage_file="$CASE/workflow-runs/$run_id/engine/stages/implement.json"
  export RALPH_WAIT_SCALE=0
  export RALPH_WORKFLOW_FOLLOW_INTERVAL=0.05
  export RALPH_WORKFLOW_FOLLOW_MAX_POLLS=80
  env RALPH_PROJECT_ROOT="$FIX_PROJECT" RALPH_PLAN_WORKSPACE_ROOT="$CASE" \
    RALPH_HOME="$FIX_ROOT/home" bash "$CLI" logs "$run_id" --stage implement --stream agent --follow \
    >"$out" 2>"$err" &
  local follow_pid=$!
  wait_for_file_match "$out" 'seq-agent-1'
  printf 'seq-agent-live\n' >>"$log_file"
  wait_for_file_match "$out" 'seq-agent-live'
  jq '.state = "succeeded"' "$stage_file" >"${stage_file}.tmp" && mv "${stage_file}.tmp" "$stage_file"
  wait_pid_exit "$follow_pid"
  grep -q 'seq-agent-live' "$out"
}

@test "production prepare_stage_logs writes engine logs readable by select and CLI streams" {
  local run_id="run-20260826T110000Z-logs-prod"
  local registry_run log_dir selected
  seed_sequential_plan_run "$CASE" "$run_id"
  registry_run="$CASE/workflow-runs/$run_id"

  PREPARE_SEQ_LOG_DIR=""
  prepare_seq_stage_logs_via_production "$CASE" "$run_id" "implement" 1
  log_dir="$PREPARE_SEQ_LOG_DIR"
  [[ "$log_dir" == "$registry_run/engine/logs/stages/implement/attempt-1" ]]
  [ -f "$log_dir/agent.log" ]
  [ -f "$log_dir/runner.log" ]
  [ ! -L "$log_dir" ]
  [ ! -L "$log_dir/agent.log" ]
  [ ! -L "$log_dir/runner.log" ]
  grep -qx 'prod-agent-1' "$log_dir/agent.log"
  grep -qx 'prod-runner-1' "$log_dir/runner.log"
  [ "${RALPH_GRAPH_NODE_LOG_DIR:-}" = "$log_dir" ]
  [ "${RALPH_SEQ_STAGE_LOG_DIR:-}" = "$log_dir" ]

  selected="$(workflow_seq_stage_log_select "$registry_run" "implement" 1 agent)"
  [ "$selected" = "$log_dir/agent.log" ]
  selected="$(workflow_seq_stage_log_select "$registry_run" "implement" 1 supervisor)"
  [ "$selected" = "$log_dir/runner.log" ]
  selected="$(workflow_seq_stage_log_select "$registry_run" "implement" 1 combined)"
  [ "$(printf '%s\n' "$selected" | wc -l | tr -d ' ')" -eq 2 ]
  [[ "$selected" == *"$log_dir/runner.log"* ]]
  [[ "$selected" == *"$log_dir/agent.log"* ]]

  run --separate-stderr env RALPH_PROJECT_ROOT="$FIX_PROJECT" RALPH_PLAN_WORKSPACE_ROOT="$CASE" \
    RALPH_HOME="$FIX_ROOT/home" bash "$CLI" logs "$run_id" --stage implement --attempt 1 --stream agent --no-follow
  [ "$status" -eq 0 ]
  [ "$output" = $'prod-agent-1\nprod-agent-2' ]

  run --separate-stderr env RALPH_PROJECT_ROOT="$FIX_PROJECT" RALPH_PLAN_WORKSPACE_ROOT="$CASE" \
    RALPH_HOME="$FIX_ROOT/home" bash "$CLI" logs "$run_id" --stage implement --attempt 1 --stream supervisor --no-follow
  [ "$status" -eq 0 ]
  [ "$output" = $'prod-runner-1' ]

  wf_cli logs "$run_id" --stage implement --stream combined --no-follow
  [ "$status" -eq 0 ]
  [[ "$output" == *"prod-runner-1"* ]]
  [[ "$output" == *"prod-agent-1"* ]]

  workflow_seq_clear_stage_log_dir_exports
  [ -z "${RALPH_GRAPH_NODE_LOG_DIR:-}" ]
  [ -z "${RALPH_SEQ_STAGE_LOG_DIR:-}" ]
}

@test "prepare_stage_logs rejects symlink attempt dirs and unsafe stage ids" {
  local run_id="run-20260826T110000Z-logs-contain"
  local registry_run engine_dir outside
  seed_sequential_plan_run "$CASE" "$run_id"
  registry_run="$CASE/workflow-runs/$run_id"
  engine_dir="$registry_run/engine"
  outside="$CASE/outside-logs"
  mkdir -p "$outside" "$engine_dir/logs/stages"
  # shellcheck source=/dev/null
  source "$SEQ_LIB"

  run workflow_seq_prepare_stage_logs "$registry_run" "../escape" 1
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a usable path component"* || "$stderr" == *"not a usable path component"* ]]
  [ ! -e "$engine_dir/logs/stages/../escape" ]

  run workflow_seq_prepare_stage_logs "$registry_run" "foo/bar" 1
  [ "$status" -ne 0 ]

  ln -s "$outside" "$engine_dir/logs/stages/implement"
  run workflow_seq_prepare_stage_logs "$registry_run" "implement" 1
  [ "$status" -ne 0 ]
  [[ "$output" == *"symlink"* || "$stderr" == *"symlink"* ]]
  [ ! -f "$outside/attempt-1/agent.log" ]
  [ ! -f "$outside/attempt-1/runner.log" ]
}

@test "orch soft wrapper surfaces prepare failure warning" {
  local run_id="run-20260826T110000Z-logs-soft-prepare"
  local registry_run engine_dir outside stage_json
  seed_sequential_plan_run "$CASE" "$run_id"
  registry_run="$CASE/workflow-runs/$run_id"
  engine_dir="$registry_run/engine"
  outside="$CASE/outside-logs"
  stage_json='{"id":"implement","runtime":"cursor"}'
  mkdir -p "$outside" "$engine_dir/logs/stages/implement"
  ln -s "$outside" "$engine_dir/logs/stages/implement/attempt-2"
  # shellcheck source=/dev/null
  source "$SEQ_LIB"

  run --separate-stderr workflow_seq_orch_journal_before \
    "$registry_run" implement 0 "$stage_json" 0 ""
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"Warning: sequential stage log prepare failed"* ]]
  [ -z "${RALPH_SEQ_STAGE_LOG_DIR:-}" ]
  [ -z "${RALPH_GRAPH_NODE_LOG_DIR:-}" ]
}

@test "stage_log_select ignores symlink log files under engine" {
  local run_id="run-20260826T110000Z-logs-symlink-select"
  local registry_run log_dir outside selected
  seed_sequential_plan_run "$CASE" "$run_id"
  registry_run="$CASE/workflow-runs/$run_id"
  outside="$CASE/outside-agent.log"
  printf 'secret-outside\n' >"$outside"
  # shellcheck source=/dev/null
  source "$SEQ_LIB"

  log_dir="$(workflow_seq_prepare_stage_logs "$registry_run" "implement" 1)"
  printf 'real-agent\n' >"$log_dir/agent.log"
  rm -f "$log_dir/agent.log"
  ln -s "$outside" "$log_dir/agent.log"

  selected="$(workflow_seq_stage_log_select "$registry_run" "implement" 1 agent)"
  [ -z "$selected" ]

  run --separate-stderr env RALPH_PROJECT_ROOT="$FIX_PROJECT" RALPH_PLAN_WORKSPACE_ROOT="$CASE" \
    RALPH_HOME="$FIX_ROOT/home" bash "$CLI" logs "$run_id" --stage implement --attempt 1 --stream agent --no-follow
  [ "$status" -ne 0 ] || [ -z "$output" ]
  ! printf '%s\n' "$output" | grep -q 'secret-outside'
}

@test "logs rejects internal namespace selector with no namespace hint" {
  local run_id="run-20260826T100000Z-logs-ns"
  seed_dependency_task_run "$CASE" "$run_id"
  wf_cli logs "$run_id" --namespace lifecycle --stage implement
  [ "$status" -eq 2 ]
  [[ "$output" == *"does not accept internal namespace/node selectors"* ]]
}

@test "watch Ctrl-C exits viewer only without mutating fixtures" {
  local run_id="run-20260826T110000Z-watch-int"
  seed_sequential_plan_run "$CASE" "$run_id"
  write_seq_events "$CASE" "$run_id"
  # Null owners diagnose as operator-request waits; pin a live owner so watch follows.
  local outer="$CASE/workflow-runs/$run_id/run.json"
  local engine="$CASE/workflow-runs/$run_id/engine/run.json"
  jq '.owner = {pid:4242,hostname:"host",processStartId:"x",heartbeatAt:"2026-08-26T11:01:00Z"}' \
    "$outer" >"${outer}.tmp" && mv "${outer}.tmp" "$outer"
  jq '.owner = {pid:4242,hostname:"host",processStartId:"x",heartbeatAt:"2026-08-26T11:01:00Z"}' \
    "$engine" >"${engine}.tmp" && mv "${engine}.tmp" "$engine"
  local out="$FIX_ROOT/watch-int.out" before after rc=0 child=""
  before="$(digest_tree "$CASE")"
  export RALPH_WAIT_SCALE=0
  export RALPH_WORKFLOW_FOLLOW_INTERVAL=0.05
  export RALPH_WORKFLOW_FOLLOW_MAX_POLLS=80
  env RALPH_PROJECT_ROOT="$FIX_PROJECT" RALPH_PLAN_WORKSPACE_ROOT="$CASE" \
    RALPH_HOME="$FIX_ROOT/home" bash "$CLI" watch "$run_id" --plain >"$out" 2>/dev/null &
  local watch_pid=$!
  wait_for_file_match "$out" 'Workflow status'
  child="$(pgrep -P "$watch_pid" -f 'workflow_viewer.py' 2>/dev/null | head -1 || true)"
  if [[ -z "$child" ]]; then
    child="$(pgrep -f "workflow_viewer.py --run-id $run_id" 2>/dev/null | head -1 || true)"
  fi
  if [[ -n "$child" ]]; then
    kill -TERM "$child" 2>/dev/null || true
  else
    kill -TERM "$watch_pid" 2>/dev/null || true
  fi
  wait_pid_exit "$watch_pid" || true
  after="$(digest_tree "$CASE")"
  [ "$before" = "$after" ]
}

# --- Public workflow actions CLI ---

seed_action_waiting_run() {
  local state_root="$1" run_id="$2" mode="${3:-sequential}"
  local registry_run="$state_root/workflow-runs/$run_id"
  mkdir -p "$registry_run/actions/requests" "$registry_run/actions/capabilities"
  if [[ "$mode" == "dependency" ]]; then
    seed_dependency_task_run "$state_root" "$run_id"
  else
    seed_sequential_plan_run "$state_root" "$run_id"
  fi
  # Outstanding approval request
  jq -nc \
    --arg runId "$run_id" \
    '{
      schemaVersion:1,
      requestId:"appr-cli-001",
      kind:"approval",
      runId:$runId,
      stageId:"approve-plan",
      attemptId:"approve-plan-1",
      choices:["approve","request-changes","cancel"],
      createdAt:"2026-08-26T12:00:00Z",
      question:"Approve the plan?",
      changesTarget:"implement",
      evidence:[{path:"/tmp/evidence.json",sha256:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]
    }' >"$registry_run/actions/requests/appr-cli-001.json"
}

@test "actions list common run ID returns normalized JSON without namespace" {
  local run_id="run-20260826T120000Z-actions-list"
  seed_action_waiting_run "$CASE" "$run_id" sequential
  wf_cli actions list "$run_id" --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r 'type')" = "array" ]
  [ "$(printf '%s' "$output" | jq 'length')" -ge 1 ]
  [ "$(printf '%s' "$output" | jq 'map(has("namespace")) | any')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.[0].kind')" = "approval" ]
}

@test "actions list Sequential mode lists common records" {
  local run_id="run-20260826T120000Z-actions-seq"
  seed_action_waiting_run "$CASE" "$run_id" sequential
  wf_cli actions list "$run_id" --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r 'map(.kind) | unique | join(",")')" = "approval" ]
}

@test "actions list rejects latest and namespace selectors" {
  local run_id="run-20260826T120000Z-actions-ns"
  seed_action_waiting_run "$CASE" "$run_id" sequential
  wf_cli actions list latest
  [ "$status" -eq 2 ]
  [[ "$output" == *"exact"* || "$output" == *"latest"* ]]

  wf_cli actions list "$run_id" --namespace lifecycle
  [ "$status" -eq 2 ]
  [[ "$output" == *"namespace"* || "$output" == *"latest"* ]]
}

@test "actions respond confirmation required without --yes" {
  local run_id="run-20260826T120000Z-actions-confirm"
  seed_action_waiting_run "$CASE" "$run_id" sequential
  run env RALPH_PROJECT_ROOT="$FIX_PROJECT" RALPH_PLAN_WORKSPACE_ROOT="$CASE" \
    RALPH_HOME="$FIX_ROOT/home" bash "$CLI" actions respond "$run_id" appr-cli-001 \
    --decision approve </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"--yes"* || "$output" == *"confirm"* ]]
  [ ! -e "$CASE/workflow-runs/$run_id/actions/decisions/appr-cli-001.json" ]
}

@test "actions respond decision enum and message required for request-changes" {
  local run_id="run-20260826T120000Z-actions-enum"
  seed_action_waiting_run "$CASE" "$run_id" sequential
  wf_cli actions respond "$run_id" appr-cli-001 --decision allow-once --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"decision enum"* || "$output" == *"does not include"* || "$output" == *"choice"* ]]

  wf_cli actions respond "$run_id" appr-cli-001 --decision request-changes --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"message required"* || "$output" == *"message"* ]]
}

@test "actions respond approve prints resume next action with confirmation" {
  local run_id="run-20260826T120000Z-actions-respond"
  seed_action_waiting_run "$CASE" "$run_id" sequential
  wf_cli actions respond "$run_id" appr-cli-001 --decision approve --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"confirmed-noninteractive"* || "$output" == *"resume"* ]]
  [[ "$output" == *"ralph workflow resume $run_id"* ]]
  [ -f "$CASE/workflow-runs/$run_id/actions/decisions/appr-cli-001.json" ]
}

@test "stage request spoof refusal without supervisor identity" {
  wf_cli actions request --question "Which config?"
  [ "$status" -ne 0 ]
  [[ "$output" == *"standalone"* || "$output" == *"spoof"* || "$output" == *"supervisor"* ]]
}

@test "stage request with capability nonce creates input for common run ID" {
  local run_id="run-20260826T120000Z-stage-req"
  seed_action_waiting_run "$CASE" "$run_id" sequential
  local registry_run="$CASE/workflow-runs/$run_id"
  local nonce="aabbccddeeff00112233445566778899"
  mkdir -p "$registry_run/actions/capabilities"
  jq -nc --arg runId "$run_id" \
    '{runId:$runId,stageId:"implement",attemptId:"implement-1",nonce:"aabbccddeeff00112233445566778899",createdAt:"2026-08-26T12:00:00Z"}' \
    >"$registry_run/actions/capabilities/implement-implement-1.json"

  run env RALPH_PROJECT_ROOT="$FIX_PROJECT" RALPH_PLAN_WORKSPACE_ROOT="$CASE" \
    RALPH_HOME="$FIX_ROOT/home" \
    RALPH_WORKFLOW_RUN_ID="$run_id" \
    RALPH_WORKFLOW_STAGE_ID=implement \
    RALPH_WORKFLOW_STAGE_ATTEMPT=implement-1 \
    RALPH_WORKFLOW_REGISTRY_RUN="$registry_run" \
    RALPH_WORKFLOW_ACTION_NONCE="$nonce" \
    bash "$CLI" actions request --question "Which staging config name?"
  [ "$status" -eq 0 ]
  [[ "$output" != *"$nonce"* ]]
  [[ "$output" == *"Created input request"* ]]
  local req_path
  req_path="$(ls "$registry_run/actions/requests"/inp-*.json | head -1)"
  [ -f "$req_path" ]
  [ "$(jq -r 'has("nonce")' "$req_path")" = "false" ]
  [ "$(jq -r '.kind' "$req_path")" = "input" ]
}

@test "stale attempt stage request is refused" {
  local run_id="run-20260826T120000Z-stale-att"
  seed_action_waiting_run "$CASE" "$run_id" sequential
  local registry_run="$CASE/workflow-runs/$run_id"
  local nonce="aabbccddeeff00112233445566778899"
  mkdir -p "$registry_run/actions/capabilities"
  jq -nc --arg runId "$run_id" \
    '{runId:$runId,stageId:"implement",attemptId:"implement-1",nonce:"aabbccddeeff00112233445566778899",createdAt:"2026-08-26T12:00:00Z"}' \
    >"$registry_run/actions/capabilities/implement-implement-1.json"

  run env RALPH_PROJECT_ROOT="$FIX_PROJECT" RALPH_PLAN_WORKSPACE_ROOT="$CASE" \
    RALPH_HOME="$FIX_ROOT/home" \
    RALPH_WORKFLOW_RUN_ID="$run_id" \
    RALPH_WORKFLOW_STAGE_ID=implement \
    RALPH_WORKFLOW_STAGE_ATTEMPT=implement-99 \
    RALPH_WORKFLOW_REGISTRY_RUN="$registry_run" \
    RALPH_WORKFLOW_ACTION_NONCE="$nonce" \
    bash "$CLI" actions request --question "Which staging config name?"
  [ "$status" -ne 0 ]
  [[ "$output" == *"stale"* || "$output" == *"missing"* || "$output" == *"does not match"* || "$output" == *"capability"* ]]
}

@test "approvals list is mode-independent and permission-only" {
  wf_cli actions approvals list --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.approvals | type')" = "array" ]
}

@test "approvals revoke requires confirmation without --yes" {
  run env RALPH_PROJECT_ROOT="$FIX_PROJECT" RALPH_PLAN_WORKSPACE_ROOT="$CASE" \
    RALPH_HOME="$FIX_ROOT/home" bash "$CLI" actions approvals revoke \
    --runtime cursor --action Bash --resource src/app.ts --effect write </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"--yes"* || "$output" == *"confirm"* ]]
}

@test "actions help has no namespace no latest no publish verb" {
  wf_cli actions --help
  [ "$status" -eq 0 ]
  [[ "$output" != *"--namespace"* ]]
  [[ "$output" != *"--latest"* ]]
  [[ "$output" != *"publish"* ]] || [[ "$output" == *"no publish verb"* ]]
  [[ "$output" == *"actions list"* ]]
  [[ "$output" == *"actions respond"* ]]
  [[ "$output" == *"actions request"* ]]
  [[ "$output" == *"approvals list"* ]]
  [[ "$output" == *"approvals revoke"* ]]

  wf_cli --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"no publish verb"* || "$output" != *"  publish"* ]]
  [[ "$output" != *"--latest"* ]]
}
