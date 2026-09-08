#!/usr/bin/env bats
# Finite workflow status and runs renderers from the shared model/theme.
#
# Sources rendering helpers only; never starts an engine or runtime.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

OPVIEW="$REPO_ROOT/bundle/.ralph/bash-lib/workflow/workflow-operator-view.sh"
STATE_SH="$REPO_ROOT/bundle/.ralph/bash-lib/workflow/workflow-state.sh"
STATUS_SCHEMA="$REPO_ROOT/bundle/.ralph/schemas/workflow-status.schema.json"
ARTIFACT_SCHEMA_PY="$REPO_ROOT/bundle/.ralph/python/artifact_json_schema.py"
STATUS_FIXTURES="$BATS_TEST_DIRNAME/fixtures/status"
STATIC_PY="$REPO_ROOT/bundle/.ralph/python/workflow_static.py"

setup_file() {
  command -v jq >/dev/null || skip "jq required"
  command -v python3 >/dev/null || skip "python3 required"
  [ -f "$OPVIEW" ]
  [ -f "$STATUS_SCHEMA" ]
  [ -f "$ARTIFACT_SCHEMA_PY" ]
  [ -f "$STATIC_PY" ]
}

setup() {
  unset WORKFLOW_OPERATOR_FORCE_COLOR WORKFLOW_OPERATOR_COLOR_DEPTH
  unset WORKFLOW_RUNS_FORCE_TABLE WORKFLOW_RUNS_FORCE_COLOR WORKFLOW_RUNS_NOW
  unset NO_COLOR RALPH_WORKFLOW_NO_COLOR RALPH_NO_COLOR FORCE_COLOR COLUMNS
  # shellcheck source=/dev/null
  source "$OPVIEW"
}

render_status() {
  workflow_operator_render_status "$1"
}

render_start() {
  workflow_operator_render_start "$1"
}

validate_status_fixture() {
  python3 "$ARTIFACT_SCHEMA_PY" validate-final-output \
    --schema "$STATUS_SCHEMA" \
    --artifact "$1"
}

@test "fixed status records validate against the public status schema" {
  local fixture
  shopt -s nullglob
  for fixture in "$STATUS_FIXTURES"/*.json; do
    run validate_status_fixture "$fixture"
    [ "$status" -eq 0 ]
  done
  shopt -u nullglob
}

@test "operator status refreshes a running plan-backed stage from its contained control plan" {
  local registry control stages refreshed
  registry="$BATS_TEST_TMPDIR/registry-run"
  control="$registry/plans/implement/attempt-1/control.plan.md"
  mkdir -p "$(dirname "$control")"
  cat >"$control" <<'EOF'
---
todos:
  - id: first
    content: first work
    status: completed
  - id: second
    content: second work
    status: pending
---
EOF
  stages='[{"id":"implement","state":"running","planSourceKind":"generated","controlPlanPath":"'"$control"'","completedTodos":0,"totalTodos":2,"currentTodoId":"first"}]'

  refreshed="$(_workflow_operator_view_refresh_live_plan_progress "$registry" "$stages")"
  printf '%s' "$refreshed" | jq -e '
    .[0].completedTodos == 1
    and .[0].totalTodos == 2
    and .[0].currentTodoId == "second"
  ' >/dev/null
}

@test "Sequential task entry start render shows outcome and watch action" {
  local record
  record="$(jq -cn \
    --arg runId "run-20260827T010000Z-seq-task" \
    '{runId:$runId, workflowId:"bug-fix", mode:"sequential", entryKind:"task",
      taskProvenance:"explicit", task:"Fix timeout", state:"running"}')"
  run render_start "$record"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Outcome: running (workflow started)"* ]]
  [[ "$output" == *"Entry: task (explicit)"* ]]
  [[ "$output" == *"Mode: sequential"* ]]
  [[ "$output" == *"Action:"*"ralph workflow watch run-20260827T010000Z-seq-task"* ]]
  [[ "$output" == *"Status:"*"ralph workflow status run-20260827T010000Z-seq-task"* ]]
}

@test "provided plan entry render shows original and supplied source paths" {
  local status
  status="$(jq -cn \
    --arg runId "run-20260827T020000Z-plan" \
    --arg original "/tmp/project/feature.plan.md" \
    --arg source "/tmp/state/workflow-runs/run/plans/input/source.plan.md" \
    '{
      schemaVersion: 1,
      run: {
        runId: $runId, workflowId: "plan-delivery", mode: "sequential",
        entryKind: "plan", task: "Execute supplied plan", taskProvenance: "plan-overview",
        inputPlan: {originalPath: $original, sourcePath: $source}
      },
      stages: [{
        id: "implement", state: "running", stageKind: "plan-backed",
        planSourceKind: "provided", planSourceStageId: null,
        originalPlanPath: $original, sourcePlanPath: $source,
        controlPlanPath: "/tmp/state/workflow-runs/run/plans/implement/attempt-1/control.plan.md",
        completedTodos: 0, totalTodos: 2, currentTodoId: "ship"
      }],
      diagnosis: {state: "running", reasonCode: "live-owner", summary: "progress", stageId: "implement", retryable: true},
      nextAction: null
    }')"
  run render_status "$status"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Entry: plan (plan-overview)"* ]]
  [[ "$output" == *"Original plan:"*"/tmp/project/feature.plan.md"* ]]
  [[ "$output" == *"Supplied source:"* ]]
  [[ "$output" == *"Control plan:"* ]]
  [[ "$output" != *"namespace"* ]]
}

@test "Sequential operator input wait prints question request and respond command" {
  local status
  status="$(jq -cn \
    --arg runId "run-20260827T030000Z-input" \
    '{
      schemaVersion: 1,
      run: {runId:$runId, workflowId:"bug-fix", mode:"sequential", entryKind:"task",
        task:"Fix flaky test", taskProvenance:"explicit"},
      stages: [{id:"implement", state:"waiting", stageKind:"executable",
        blocker:{kind:"input", requestId:"inp-op-001"}}],
      diagnosis: {state:"waiting", reasonCode:"operator-input",
        summary:"the run is waiting for the operator to answer an input request",
        stageId:"implement", requestKind:"input", requestId:"inp-op-001", retryable:false,
        nextAction:{label:"answer", argv:["ralph","workflow","actions","list",$runId]}},
      nextAction:{label:"answer", argv:["ralph","workflow","actions","list",$runId]}
    }')"
  run render_status "$status"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Outcome: waiting (operator-input)"* ]]
  [[ "$output" == *"Question:"* ]]
  [[ "$output" == *"Request: inp-op-001"* ]]
  [[ "$output" == *"Respond:"*"ralph workflow actions respond run-20260827T030000Z-input inp-op-001"* ]]
  [[ "$output" == *"Action:"*"ralph workflow actions list run-20260827T030000Z-input"* ]]
  [ "$(printf '%s\n' "$output" | grep -c '^Action: ')" -eq 1 ]
}

@test "answered input status prints resume action" {
  local status
  status="$(jq -cn \
    --arg runId "run-20260827T040000Z-answered" \
    '{
      schemaVersion: 1,
      run: {runId:$runId, workflowId:"bug-fix", mode:"sequential", entryKind:"task",
        task:"Fix flaky test", taskProvenance:"explicit"},
      stages: [{id:"implement", state:"waiting", stageKind:"executable"}],
      diagnosis: {state:"waiting", reasonCode:"operator-input",
        summary:"the operator answered the input request; resume consumes it once",
        stageId:"implement", requestKind:"input", requestId:"inp-op-002", retryable:true,
        nextAction:{label:"resume", argv:["ralph","workflow","resume",$runId]}},
      nextAction:{label:"resume", argv:["ralph","workflow","resume",$runId]}
    }')"
  run render_status "$status"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Resume: ralph workflow resume run-20260827T040000Z-answered"* ]]
  [[ "$output" == *"Action:"*"ralph workflow resume run-20260827T040000Z-answered"* ]]
}

@test "Dependency approval pending prints evidence question and decisions" {
  local status
  status="$(jq -cn \
    --arg runId "run-20260827T050000Z-appr" \
    '{
      schemaVersion: 1,
      run: {runId:$runId, workflowId:"feature-delivery", mode:"dependency", entryKind:"task",
        task:"Ship feature", taskProvenance:"explicit"},
      stages: [{
        id:"approve-plan", state:"waiting", stageKind:"approval",
        approval:{question:"Approve the implementation plan?", changesTarget:"implement"},
        requestId:"appr-op-001", requestState:"outstanding",
        evidence:[{path:"/tmp/evidence.md"}]
      }],
      diagnosis: {state:"waiting", reasonCode:"human-approval",
        summary:"the run is waiting for the operator to decide an approval gate",
        stageId:"approve-plan", requestKind:"approval", requestId:"appr-op-001", retryable:false,
        nextAction:{label:"answer", argv:["ralph","workflow","actions","list",$runId]}},
      nextAction:{label:"answer", argv:["ralph","workflow","actions","list",$runId]}
    }')"
  run render_status "$status"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Mode: dependency"* ]]
  [[ "$output" == *"Question: Approve the implementation plan?"* ]]
  [[ "$output" == *"Evidence: 1 artifact(s)"* ]]
  [[ "$output" == *"Decisions:"*"ralph workflow actions list run-20260827T050000Z-appr"* ]]
}

@test "changes requested status prints reset target" {
  local status
  status="$(jq -cn \
    --arg runId "run-20260827T060000Z-changes" \
    '{
      schemaVersion: 1,
      run: {runId:$runId, workflowId:"feature-delivery", mode:"dependency", entryKind:"task",
        task:"Ship feature", taskProvenance:"explicit"},
      stages: [{
        id:"approve-plan", state:"blocked", stageKind:"approval",
        approval:{question:"Approve?", changesTarget:"implement"},
        requestId:"appr-op-002", requestState:"answered"
      }],
      diagnosis: {state:"blocked", reasonCode:"human-changes-requested",
        summary:"the operator requested changes at approve-plan; reset implement and resume",
        stageId:"approve-plan", requestKind:"approval", requestId:"appr-op-002", retryable:false,
        nextAction:{label:"reset", argv:["ralph","workflow","reset",$runId,"--stage","implement"]}},
      nextAction:{label:"reset", argv:["ralph","workflow","reset",$runId,"--stage","implement"]}
    }')"
  run render_status "$status"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Outcome: blocked (human-changes-requested)"* ]]
  [[ "$output" == *"Reset target: implement"* ]]
  [[ "$output" == *"Action:"*"ralph workflow reset run-20260827T060000Z-changes --stage implement"* ]]
}

@test "clean interruption resume shows resumes-at and resume action" {
  local status
  status="$(jq -cn \
    --arg runId "run-20260827T070000Z-resume" \
    '{
      schemaVersion: 1,
      run: {runId:$runId, workflowId:"plan-delivery", mode:"sequential", entryKind:"plan",
        task:"Execute supplied plan", taskProvenance:"plan-filename"},
      stages: [{
        id:"implement", state:"waiting", stageKind:"plan-backed",
        planSourceKind:"provided", completedTodos:1, totalTodos:3, currentTodoId:"todo-2",
        originalPlanPath:"/tmp/original.plan.md", sourcePlanPath:"/tmp/source.plan.md",
        controlPlanPath:"/tmp/control.plan.md"
      }],
      diagnosis: {state:"waiting", reasonCode:"operator-request",
        summary:"the run was interrupted cleanly and can be resumed as is",
        stageId:"implement", retryable:true,
        nextAction:{label:"resume", argv:["ralph","workflow","resume",$runId]}},
      nextAction:{label:"resume", argv:["ralph","workflow","resume",$runId]}
    }')"
  run render_status "$status"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Resumes at: stage implement TODO todo-2 (1/3)"* ]]
  [[ "$output" == *"Resume: ralph workflow resume run-20260827T070000Z-resume"* ]]
  [[ "$output" == *"Action:"*"ralph workflow resume run-20260827T070000Z-resume"* ]]
}

@test "plan progress line appears for plan-backed Sequential stage" {
  local status
  status="$(jq -cn \
    --arg runId "run-20260827T080000Z-progress" \
    '{
      schemaVersion: 1,
      run: {runId:$runId, workflowId:"bug-fix", mode:"sequential", entryKind:"task",
        task:"Fix bug", taskProvenance:"explicit"},
      stages: [{
        id:"implement", state:"running", stageKind:"plan-backed",
        planSourceKind:"generated", planSourceStageId:"plan-implementation",
        completedTodos:2, totalTodos:5, currentTodoId:"impl-3"
      }],
      diagnosis: {state:"running", reasonCode:"live-owner", stageId:"implement", retryable:true},
      nextAction: null
    }')"
  run render_status "$status"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Plan progress: 2/5 TODO impl-3"* ]]
  [[ "$output" == *"Plan source: generated"* ]]
  [[ "$output" == *"Plan producer: plan-implementation"* ]]
}

@test "human terminal hold for human-verified delivery workflow" {
  local status
  status="$(jq -cn \
    --arg runId "run-20260827T090000Z-hold" \
    '{
      schemaVersion: 1,
      run: {runId:$runId, workflowId:"human-verified-delivery", mode:"dependency",
        entryKind:"task", task:"Deliver with gates", taskProvenance:"explicit"},
      stages: [{
        id:"approve-result", state:"waiting", stageKind:"approval",
        approval:{question:"Accept verified results?", changesTarget:"plan-implementation"},
        requestId:"appr-result-001", requestState:"outstanding", evidence:[]
      }],
      diagnosis: {state:"waiting", reasonCode:"human-approval", stageId:"approve-result",
        requestKind:"approval", requestId:"appr-result-001", retryable:false,
        nextAction:{label:"answer", argv:["ralph","workflow","actions","list",$runId]}},
      nextAction:{label:"answer", argv:["ralph","workflow","actions","list",$runId]}
    }')"
  run render_status "$status"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Terminal hold:"*"approve-result"* ]]
}

@test "status fixtures render every outcome class with one Action line" {
  local fixture name plain
  shopt -s nullglob
  for fixture in "$STATUS_FIXTURES"/*.json; do
    name="$(basename "$fixture")"
    plain="$(python3 "$STATIC_PY" status --depth 0 <"$fixture")"
    [[ "$plain" == Outcome:* ]]
    [ "$(printf '%s\n' "$plain" | grep -c '^Action: ')" -eq 1 ]
    [[ "$plain" != *$'\033['* ]]
  done
  shopt -u nullglob
}

@test "semantic colors map green yellow cyan red to intended roles" {
  local running failed succeeded waiting
  running="$(python3 "$STATIC_PY" status --depth 16 --force-color \
    <"$STATUS_FIXTURES/sequential-task-running.json")"
  failed="$(python3 "$STATIC_PY" status --depth 16 --force-color \
    <"$STATUS_FIXTURES/sequential-failed.json")"
  succeeded="$(python3 "$STATIC_PY" status --depth 16 --force-color \
    <"$STATUS_FIXTURES/dependency-plan-succeeded.json")"
  waiting="$(python3 "$STATIC_PY" status --depth 16 --force-color \
    <"$STATUS_FIXTURES/dependency-approval-wait.json")"

  # Cyan accent on running outcome value
  [[ "$running" == *$'\033[36m'*running*$'\033[0m'* ]]
  # Red failure on stage-failed diagnosis
  [[ "$failed" == *$'\033[31m'*failed*$'\033[0m'* ]]
  # Green success
  [[ "$succeeded" == *$'\033[32m'*succeeded*$'\033[0m'* ]]
  # Yellow/amber warning on waiting
  [[ "$waiting" == *$'\033[33m'*waiting*$'\033[0m'* ]]

  local c256
  c256="$(python3 "$STATIC_PY" status --depth 256 --force-color \
    <"$STATUS_FIXTURES/sequential-task-running.json")"
  [[ "$c256" == *"38;5;80"* ]]
}

@test "NO_COLOR and RALPH_WORKFLOW_NO_COLOR disable status ANSI" {
  local status_json
  status_json="$(cat "$STATUS_FIXTURES/sequential-task-running.json")"
  run env NO_COLOR=1 bash -c 'source "$1"; workflow_operator_render_status "$2"' bash "$OPVIEW" "$status_json"
  [ "$status" -eq 0 ]
  [[ "$output" != *$'\033['* ]]

  run env RALPH_WORKFLOW_NO_COLOR=1 WORKFLOW_OPERATOR_FORCE_COLOR=1 bash -c \
    'source "$1"; workflow_operator_render_status "$2"' bash "$OPVIEW" "$status_json"
  [ "$status" -eq 0 ]
  [[ "$output" != *$'\033['* ]]
}

@test "status width clipping keeps long tasks readable" {
  local long_task status_json out
  long_task="$(printf 'x%.0s' {1..200})"
  status_json="$(jq -cn --arg task "$long_task" \
    '{schemaVersion:1, run:{runId:"run-long", workflowId:"bug-fix", mode:"sequential",
      entryKind:"task", task:$task, taskProvenance:"explicit", state:"running",
      sourcePath:"/x", sourceKind:"project", inputPath:"/y",
      createdAt:"2026-08-27T01:00:00Z", updatedAt:"2026-08-27T01:00:00Z", inputPlan:null},
      stages:[], diagnosis:{state:"running", reasonCode:"live-owner", summary:"",
      stageId:null, requestKind:null, requestId:null, evidence:[], retryable:true, nextAction:null},
      nextAction:null}')"
  out="$(printf '%s' "$status_json" | COLUMNS=60 python3 "$STATIC_PY" status --depth 0 --width 60)"
  [[ "$out" == *"Task:"*"..."* ]]
  [[ "$out" != *"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"* ]]
}

# --- runs list --------------------------------------------------------------

@test "runs table shows aligned columns and semantic state colors" {
  local rows out
  rows="$(jq -cn \
    '[{runId:"run-20260827T010000Z-a", workflowId:"bug-fix", mode:"sequential",
       entryKind:"task", state:"running", createdAt:"2026-08-27T01:00:00Z",
       updatedAt:"2026-08-27T01:01:00Z", task:"Fix timeout"},
      {runId:"run-20260827T010000Z-b", workflowId:"feature-delivery", mode:"dependency",
       entryKind:"plan", state:"failed", createdAt:"2026-08-27T00:00:00Z",
       updatedAt:"2026-08-27T00:30:00Z", task:"Ship feature"},
      {runId:"run-20260827T010000Z-c", workflowId:"plan-delivery", mode:"sequential",
       entryKind:"task", state:"waiting", createdAt:"2026-08-27T01:02:00Z",
       updatedAt:"2026-08-27T01:04:00Z", task:"Wait"},
      {runId:"run-20260827T010000Z-d", workflowId:"bug-fix", mode:"sequential",
       entryKind:"task", state:"succeeded", createdAt:"2026-08-26T01:00:00Z",
       updatedAt:"2026-08-26T02:00:00Z", task:"Done"}]')"
  out="$(printf '%s' "$rows" | python3 "$STATIC_PY" runs-table --depth 16 --force-color \
    --width 100 --now 2026-08-27T01:05:00Z)"
  [[ "$out" == *"ID"* ]]
  [[ "$out" == *"WORKFLOW"* ]]
  [[ "$out" == *"STATE"* ]]
  [[ "$out" == *"AGE"* ]]
  [[ "$out" == *"TASK"* ]]
  [[ "$out" == *$'\033[36m'*running*$'\033[0m'* ]]
  [[ "$out" == *$'\033[31m'*failed*$'\033[0m'* ]]
  [[ "$out" == *$'\033[33m'*waiting*$'\033[0m'* ]]
  [[ "$out" == *$'\033[32m'*succeeded*$'\033[0m'* ]]
}

@test "runs table empty list and long id truncation" {
  local out rows
  out="$(printf '[]' | python3 "$STATIC_PY" runs-table --depth 0 --width 80)"
  [[ "$out" == *"No workflow runs found."* ]]

  rows="$(jq -cn \
    '[{runId:"run-20260827T010000Z-verylongidentifier-extra-tail",
       workflowId:"feature-delivery", mode:"dependency", entryKind:"task",
       state:"running", createdAt:"2026-08-27T01:00:00Z",
       updatedAt:"2026-08-27T01:00:00Z",
       task:"A very long task description that should truncate on a narrow terminal"}]')"
  out="$(printf '%s' "$rows" | python3 "$STATIC_PY" runs-table --depth 0 --width 40 \
    --now 2026-08-27T01:05:00Z)"
  [[ "$out" == *"..."* ]]
  local line
  while IFS= read -r line; do
    [ "${#line}" -le 40 ]
  done <<<"$out"
}

@test "runs --tsv and redirected TSV stay ANSI-free with stable schema" {
  # shellcheck source=/dev/null
  source "$STATE_SH"
  local case_root runs_root
  case_root="$(mktemp -d "${BATS_TEST_TMPDIR}/runs-tsv.XXXXXX")"
  runs_root="$case_root/workflow-runs"
  mkdir -p "$runs_root/run-20260827T010000Z-tsv/engine"
  jq -cn '{
    schemaVersion:1, runId:"run-20260827T010000Z-tsv", workflowId:"bug-fix",
    sourcePath:"/tmp/w.md", sourceKind:"project", mode:"sequential", entryKind:"task",
    task:"tsv check", taskProvenance:"explicit", inputPath:"/tmp/in.json", inputPlan:null,
    state:"running", createdAt:"2026-08-27T01:00:00Z", updatedAt:"2026-08-27T01:00:00Z",
    owner:{pid:null, hostname:null, processStartId:null, heartbeatAt:null},
    engine:{kind:"orchestration", statePath:"/tmp/e", namespace:null}
  }' >"$runs_root/run-20260827T010000Z-tsv/run.json"

  run workflow_state_list "$case_root" --tsv
  [ "$status" -eq 0 ]
  [ "$output" = $'run-20260827T010000Z-tsv\tbug-fix\tsequential\ttask\trunning\t2026-08-27T01:00:00Z' ]
  [[ "$output" != *$'\033['* ]]

  run workflow_state_list "$case_root" --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    type=="array" and length==1 and .[0].runId=="run-20260827T010000Z-tsv"
    and .[0].task=="tsv check" and (.[] | tostring | contains("\u001b") | not)
  ' >/dev/null

  # Redirected (non-TTY) default remains TSV.
  run workflow_state_list "$case_root"
  [ "$status" -eq 0 ]
  [ "$output" = $'run-20260827T010000Z-tsv\tbug-fix\tsequential\ttask\trunning\t2026-08-27T01:00:00Z' ]
}

@test "forced runs table path honors NO_COLOR" {
  # shellcheck source=/dev/null
  source "$STATE_SH"
  local case_root
  case_root="$(mktemp -d "${BATS_TEST_TMPDIR}/runs-table.XXXXXX")"
  mkdir -p "$case_root/workflow-runs/run-20260827T010000Z-tbl"
  jq -cn '{
    schemaVersion:1, runId:"run-20260827T010000Z-tbl", workflowId:"bug-fix",
    sourcePath:"/tmp/w.md", sourceKind:"project", mode:"sequential", entryKind:"task",
    task:"table", taskProvenance:"explicit", inputPath:"/tmp/in.json", inputPlan:null,
    state:"succeeded", createdAt:"2026-08-27T01:00:00Z", updatedAt:"2026-08-27T01:00:00Z",
    owner:{pid:null, hostname:null, processStartId:null, heartbeatAt:null},
    engine:{kind:"orchestration", statePath:"/tmp/e", namespace:null}
  }' >"$case_root/workflow-runs/run-20260827T010000Z-tbl/run.json"

  run env WORKFLOW_RUNS_FORCE_TABLE=1 NO_COLOR=1 WORKFLOW_RUNS_NOW=2026-08-27T01:05:00Z \
    COLUMNS=100 bash -c 'source "$1"; workflow_state_list "$2"' bash "$STATE_SH" "$case_root"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ID"* ]]
  [[ "$output" == *"succeeded"* ]]
  [[ "$output" == *"bug-fix"* ]]
  [[ "$output" != *$'\033['* ]]
}
