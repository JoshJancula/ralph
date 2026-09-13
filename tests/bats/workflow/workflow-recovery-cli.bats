#!/usr/bin/env bats
# Public `ralph workflow resume|reset|recover|cancel <exact-run-id> [--yes]`
# plus engine resume/reset/recover/cancel primitives.
#
# Design (agents/rules/test-design.md):
# - State cases source engine resume/reset/recover/cancel APIs (no graph-run /
#   orchestrator / runtime).
# - Public CLI cases use RALPH_WORKFLOW_RESUME_ENGINE_STUB so resume dispatch
#   never launches engines; recover/cancel have no engine launch.
#
# Contracts: resume retry set, exact ID, terminal/live refusal, clean
# interruption, answered-input consume-once + injection, approved gate,
# unresolved action guidance, changes-requested reset guidance, provided
# control plan retention, skip succeeded, both modes; Dependency/Sequential
# reset planner/applier preview, archive, planner/consumer, parallel waves,
# human feedback, derived-supervisor invalidation, unsafe refusals;
# recover/cancel exact ID, reject latest, preview/confirmation, outer state,
# events, both modes, next action.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

CLI="$REPO_ROOT/bundle/.ralph/workflow-cli.sh"
STATE_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/workflow/workflow-state.sh"
SEQ_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/workflow/workflow-engine-sequential.sh"
DEP_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/workflow/workflow-engine-dependency.sh"
ACTIONS_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/workflow/workflow-actions.sh"

setup_file() {
  command -v jq >/dev/null || skip "jq required"
  [ -f "$CLI" ]
  [ -f "$STATE_LIB" ]
  [ -f "$SEQ_LIB" ]
  [ -f "$DEP_LIB" ]
  [ -f "$ACTIONS_LIB" ]
  FIX_ROOT="$(mktemp -d "${BATS_TMPDIR:-/tmp}/wrc.XXXXXX")"
  FIX_ROOT="$(cd "$FIX_ROOT" && pwd -P)"
  FIX_PROJECT="$FIX_ROOT/project"
  FIX_STATE="$FIX_PROJECT/.ralph-workspace"
  mkdir -p "$FIX_STATE"
  export FIX_ROOT FIX_PROJECT FIX_STATE
  export BATS_NO_PARALLELIZE_WITHIN_FILE=true
}

teardown_file() {
  rm -rf "$FIX_ROOT"
}

setup() {
  unset RALPH_WORKFLOW_STATE_ROOT RALPH_PLAN_WORKSPACE_ROOT RALPH_GRAPH_STATE_ROOT
  unset RALPH_WORKFLOW_RESUME_ENGINE_STUB RALPH_WORKFLOW_RESUME_SEQUENTIAL_CONTINUE
  unset WORKFLOW_STATE_FIXED_RUN_ID WORKFLOW_STATE_FIXED_NOW WORKFLOW_STATE_SKIP_FSYNC
  unset WORKFLOW_SEQ_FIXED_NOW WORKFLOW_SEQ_FIXED_RESET_SUFFIX WORKFLOW_ACTION_NOW
  unset WORKFLOW_DEP_FIXED_RESET_SUFFIX
  export WORKFLOW_STATE_SKIP_FSYNC=1
  export WORKFLOW_SEQ_SKIP_FSYNC=1
  export WORKFLOW_SEQ_FIXED_NOW="2026-08-26T15:00:00Z"
  export WORKFLOW_ACTION_NOW="2026-08-26T15:00:00Z"
  export RALPH_WAIT_SCALE=0
  # shellcheck source=/dev/null
  source "$STATE_LIB"
  # shellcheck source=/dev/null
  source "$ACTIONS_LIB"
  # shellcheck source=/dev/null
  source "$SEQ_LIB"
  # shellcheck source=/dev/null
  source "$DEP_LIB"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-heartbeat.sh"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-recovery.sh"

  CASE="$(mktemp -d "$FIX_STATE/case.XXXXXX")"
  CASE="$(cd "$CASE" && pwd -P)"
  export CASE
  STUB="$CASE/resume-dispatch.stub"
  : >"$STUB"
  export RALPH_WORKFLOW_RESUME_ENGINE_STUB="$STUB"
}

teardown() {
  rm -rf "$CASE"
}

wf_cli() {
  run env RALPH_PROJECT_ROOT="$FIX_PROJECT" RALPH_PLAN_WORKSPACE_ROOT="$CASE" \
    RALPH_HOME="$FIX_ROOT/home" RALPH_AGENT_WORKSPACE="$FIX_PROJECT" \
    RALPH_WORKFLOW_RESUME_ENGINE_STUB="$STUB" \
    RALPH_WORKFLOW_SKIP_STATUS_PREVIEW="${RALPH_WORKFLOW_SKIP_STATUS_PREVIEW:-1}" \
    bash "$CLI" "$@"
}

# Like wf_cli but forces non-TTY stdin so confirmation without --yes refuses.
wf_cli_notty() {
  run env RALPH_PROJECT_ROOT="$FIX_PROJECT" RALPH_PLAN_WORKSPACE_ROOT="$CASE" \
    RALPH_HOME="$FIX_ROOT/home" RALPH_AGENT_WORKSPACE="$FIX_PROJECT" \
    RALPH_WORKFLOW_RESUME_ENGINE_STUB="$STUB" \
    RALPH_WORKFLOW_SKIP_STATUS_PREVIEW="${RALPH_WORKFLOW_SKIP_STATUS_PREVIEW:-1}" \
    bash -c 'exec < /dev/null; exec bash "$@"' bash "$CLI" "$@"
}

write_outer_run() {
  local state_root="$1" run_id="$2" body="$3"
  local run_dir="$state_root/workflow-runs/$run_id"
  mkdir -p "$run_dir"
  printf '%s' "$body" >"$run_dir/run.json"
}

write_minimal_graph_json() {
  local path="$1"
  jq -n '{
    schemaVersion: 1,
    namespace: "recovery",
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
          question: "Approve?",
          changesTarget: "implement"
        }
      }
    ],
    edges: [{ from: "implement", to: "approve-plan" }]
  }' >"$path"
}

seed_seq_inputs() {
  mkdir -p "$CASE/inputs"
  printf '%s\n' '---' 'kind: workflow' 'mode: sequential' 'overview: recovery' '---' >"$CASE/inputs/wf.md"
  cat >"$CASE/inputs/sample.orch.json" <<'ORCH'
{
  "name": "seq-recovery",
  "namespace": "seq-recovery",
  "stages": [
    {
      "id": "investigate",
      "runtime": "cursor",
      "artifacts": [{"path": ".ralph-workspace/artifacts/seq-recovery/investigation.md", "required": true}]
    },
    {
      "id": "implement",
      "runtime": "cursor",
      "plan": "stages/implement.plan.md"
    },
    {
      "id": "approve-plan",
      "type": "approval",
      "question": "Approve?",
      "changesTarget": "investigate",
      "inputArtifacts": [
        {"path": ".ralph-workspace/artifacts/seq-recovery/investigation.md", "required": true}
      ]
    }
  ]
}
ORCH
}

seed_sequential_run() {
  local preferred="${1:-}"
  local run_id registry_run
  seed_seq_inputs
  if [[ -n "$preferred" ]]; then
    export WORKFLOW_STATE_FIXED_RUN_ID="$preferred"
  else
    unset WORKFLOW_STATE_FIXED_RUN_ID
  fi
  run_id="$(
    workflow_state_create \
      --state-root "$CASE" \
      --source-path "$CASE/inputs/wf.md" \
      --source-kind project \
      --mode sequential \
      --entry-kind task \
      --task "Recovery fixture" \
      --task-provenance explicit \
      --input-file "$CASE/inputs/sample.orch.json" \
      --workflow-id seq-recovery \
      --state waiting
  )"
  unset WORKFLOW_STATE_FIXED_RUN_ID
  registry_run="$CASE/workflow-runs/$run_id"
  input_path="$(jq -r '.inputPath' "$registry_run/run.json")"
  workflow_seq_init_engine \
    --registry-run "$registry_run" \
    --input-file "$input_path" \
    --run-id "$run_id" >/dev/null
  printf '%s\n' "$run_id"
}

seed_dependency_run() {
  local preferred="${1:-}"
  local run_id registry_run graph_dir sourcep controlp graph_json
  mkdir -p "$CASE/inputs"
  printf '%s\n' '---' 'kind: workflow' 'mode: dependency' 'overview: recovery' '---' >"$CASE/inputs/wf-dep.md"
  write_minimal_graph_json "$CASE/inputs/sample.graph.json"
  # Materialized plan input for dependency registry create
  printf '# plan\n- [ ] work\n' >"$CASE/inputs/dep.input.plan.md"

  if [[ -n "$preferred" ]]; then
    export WORKFLOW_STATE_FIXED_RUN_ID="$preferred"
  else
    unset WORKFLOW_STATE_FIXED_RUN_ID
  fi
  run_id="$(
    workflow_state_create \
      --state-root "$CASE" \
      --source-path "$CASE/inputs/wf-dep.md" \
      --source-kind project \
      --mode dependency \
      --entry-kind task \
      --task "Recovery fixture" \
      --task-provenance explicit \
      --input-file "$CASE/inputs/dep.input.plan.md" \
      --workflow-id feature-delivery \
      --engine-namespace recovery \
      --state waiting
  )"
  unset WORKFLOW_STATE_FIXED_RUN_ID
  registry_run="$CASE/workflow-runs/$run_id"
  graph_dir="$CASE/graph-runs/recovery/$run_id"
  sourcep="$registry_run/plans/implement/attempt-1/source.plan.md"
  controlp="$registry_run/plans/implement/attempt-1/control.plan.md"
  graph_json="$graph_dir/graph.json"

  mkdir -p "$registry_run/plans/implement/attempt-1" "$graph_dir/nodes"
  printf '# plan\n- [ ] work\n' >"$sourcep"
  cp -f "$sourcep" "$controlp"
  write_minimal_graph_json "$graph_json"

  workflow_state_update "$CASE" "$run_id" \
    '.engine = {kind:"graph", statePath:$sp, namespace:"recovery"}' \
    --arg sp "$graph_dir"

  export RALPH_GRAPH_STATE_ROOT="$CASE"
  export RALPH_PLAN_WORKSPACE_ROOT="$CASE"
  jq -n --arg runId "$run_id" --arg registry "$registry_run" '{
    schemaVersion: 3,
    runId: $runId,
    namespace: "recovery",
    status: "awaiting-operator",
    startedAt: "2026-08-26T10:00:00Z",
    heartbeatAt: null,
    supervisorPid: null,
    registryRunPath: $registry
  }' >"$graph_dir/run.json"

  jq -n --arg source "$sourcep" --arg control "$controlp" '{
    schemaVersion: 3,
    nodeId: "implement",
    status: "interrupted",
    lastAttemptId: "implement-1",
    planPath: $control,
    planRunId: "implement-run-1",
    planSourceKind: "provided",
    planSourceStageId: null,
    originalPlanPath: null,
    sourcePlanPath: $source,
    controlPlanPath: $control,
    currentTodoId: "work",
    completedTodos: 0,
    totalTodos: 1,
    blocker: null,
    attempts: []
  }' >"$graph_dir/nodes/implement.json"

  jq -n '{
    schemaVersion: 3,
    nodeId: "approve-plan",
    status: "pending",
    lastAttemptId: null,
    attempts: []
  }' >"$graph_dir/nodes/approve-plan.json"

  printf '%s\n' "$run_id"
}

write_input_request() {
  local run_dir="$1" request_id="${2:-inp-001}" stage_id="${3:-investigate}"
  workflow_action_request_write "$run_dir" "$(jq -nc \
    --arg requestId "$request_id" \
    --arg stageId "$stage_id" \
    --arg runId "$(basename "$run_dir")" \
    '{
      requestId: $requestId,
      kind: "input",
      runId: $runId,
      stageId: $stageId,
      attemptId: ($stageId + "-1"),
      choices: ["answer","cancel"],
      createdAt: "2026-08-26T15:00:00Z",
      question: "Which target?",
      details: "staging or production name only"
    }')" >/dev/null
}

write_approval_request() {
  local run_dir="$1" request_id="${2:-appr-001}" stage_id="${3:-approve-plan}"
  workflow_action_request_write "$run_dir" "$(jq -nc \
    --arg requestId "$request_id" \
    --arg stageId "$stage_id" \
    --arg runId "$(basename "$run_dir")" \
    '{
      requestId: $requestId,
      kind: "approval",
      runId: $runId,
      stageId: $stageId,
      attemptId: ($stageId + "-1"),
      choices: ["approve","request-changes","cancel"],
      createdAt: "2026-08-26T15:00:00Z",
      question: "Approve?",
      changesTarget: "investigate",
      evidence: [
        {path: "/tmp/evidence.md", sha256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
      ]
    }')" >/dev/null
}

# --- public CLI parsing / exact ID ------------------------------------------

@test "resume CLI requires exact ID and rejects latest plan namespace" {
  wf_cli resume
  [ "$status" -eq 2 ]
  [[ "$output" == *"exact-run-id"* ]]

  wf_cli resume latest --yes
  [ "$status" -eq 2 ]
  [[ "$output" == *"exact run id"* ]]

  wf_cli resume run-x --namespace recovery --yes
  [ "$status" -eq 2 ]
  [[ "$output" == *"plan/namespace/node"* ]]

  wf_cli resume run-x --plan /tmp/x.plan.md --yes
  [ "$status" -eq 2 ]
  [[ "$output" == *"plan/namespace/node"* ]]
}

@test "resume CLI both modes preview retry set and stub dispatch with --yes" {
  local run_id registry_run
  run_id="$(seed_sequential_run run-seq-cli)"
  registry_run="$CASE/workflow-runs/$run_id"
  mkdir -p "$CASE/artifacts/seq-recovery"
  printf 'ok\n' >"$CASE/artifacts/seq-recovery/investigation.md"
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id investigate --state running --attempt 1
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id investigate --state succeeded \
    --terminal-result succeeded \
    --artifacts-json '[".ralph-workspace/artifacts/seq-recovery/investigation.md"]'
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id implement --state failed --attempt 1
  workflow_seq_update_run --registry-run "$registry_run" --state running --owner-json "$(_workflow_seq_null_owner_json)"
  workflow_seq_update_run --registry-run "$registry_run" --state failed --owner-json "$(_workflow_seq_null_owner_json)"
  workflow_state_clear_owner_and_set_state "$CASE" "$run_id" failed

  wf_cli resume "$run_id" --yes
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"Retry set:"* ]] || [[ "$output" == *"Resumed workflow run"* ]]
  [[ "$output" == *"confirmed-noninteractive"* ]] || [[ "$output" == *"Resumed"* ]]
  grep -q $'sequential\t'"$run_id"$'\t' "$STUB"

  : >"$STUB"
  run_id="$(seed_dependency_run run-dep-cli)"
  wf_cli resume "$run_id" --yes
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"Retry set:"* ]] || [[ "$output" == *"Resumed"* ]]
  grep -q $'dependency\t'"$run_id"$'\t' "$STUB"
}

@test "resume CLI refuses terminal and live-running runs" {
  local run_id registry_run
  run_id="$(seed_sequential_run run-term)"
  registry_run="$CASE/workflow-runs/$run_id"
  workflow_seq_update_run --registry-run "$registry_run" --state running --owner-json "$(_workflow_seq_null_owner_json)"
  workflow_seq_update_run --registry-run "$registry_run" --state cancelled --owner-json "$(_workflow_seq_null_owner_json)"
  workflow_state_clear_owner_and_set_state "$CASE" "$run_id" cancelled
  wf_cli resume "$run_id" --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"terminal"* || "$output" == *"refuses"* || "$output" == *"cancelled"* ]]

  run_id="$(seed_sequential_run run-live)"
  registry_run="$CASE/workflow-runs/$run_id"
  # Healthy live owner: same pid + start id as this shell so classification is healthy.
  workflow_seq_update_run --registry-run "$registry_run" --state running \
    --owner-json "$(jq -cn --argjson pid "$$" --arg host "$(hostname)" \
      '{pid:$pid,hostname:$host,processStartId:"live-test",heartbeatAt:"2099-01-01T00:00:00Z"}')"
  workflow_state_update "$CASE" "$run_id" \
    '.state = "running" | .owner = {pid:$pid,hostname:$host,processStartId:"live-test",heartbeatAt:"2099-01-01T00:00:00Z"}' \
    --argjson pid "$$" --arg host "$(hostname)"
  wf_cli resume "$run_id" --yes
  [ "$status" -ne 0 ]
}

# --- Sequential engine primitives -------------------------------------------

@test "Sequential clean interruption answered input consume once approved gate" {
  local run_id registry_run control
  run_id="$(seed_sequential_run run-seq-wait)"
  registry_run="$CASE/workflow-runs/$run_id"
  mkdir -p "$CASE/.ralph-workspace/artifacts/seq-recovery" "$registry_run/plans/investigate/attempt-1"
  printf 'ok\n' >"$CASE/.ralph-workspace/artifacts/seq-recovery/investigation.md"
  control="$registry_run/plans/investigate/attempt-1/control.plan.md"
  printf '%s\n' '---' 'name: ctrl' '---' '- [ ] open-todo' >"$control"

  # Clean interruption
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id investigate --state running --attempt 1
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id investigate --state waiting --attempt 1 \
    --control-plan-path "$control" --current-todo-id open-todo --plan-source-kind generated \
    --completed-todos 0 --total-todos 1 --blocker-json null
  workflow_seq_update_run --registry-run "$registry_run" --state waiting --owner-json "$(_workflow_seq_null_owner_json)"
  run workflow_seq_resume --registry-run "$registry_run" --workspace "$CASE" --dry-run
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.stages[] | select(.stageId=="investigate") | .action')" = "retry-clean-interruption" ]

  # Answered input: consume once + injection
  write_input_request "$registry_run" inp-001 investigate
  workflow_action_decision_write "$registry_run" "$(jq -nc \
    --arg runId "$run_id" \
    '{requestId:"inp-001",kind:"input",runId:$runId,stageId:"investigate",attemptId:"investigate-1",decision:"answer",message:"use staging",actorSource:"test",decidedAt:"2026-08-26T15:00:00Z"}')" >/dev/null
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id investigate --state waiting --attempt 1 \
    --control-plan-path "$control" --current-todo-id open-todo --plan-source-kind generated \
    --completed-todos 0 --total-todos 1 \
    --blocker-json '{"kind":"input","requestId":"inp-001","reasonCode":"operator-input","retryable":true}' \
    --skip-transition-check
  run workflow_seq_resume --registry-run "$registry_run" --workspace "$CASE"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(printf '%s' "$output" | jq -r '.stages[] | select(.stageId=="investigate") | .action')" = "retry-answered-input" ]
  [ -f "$registry_run/actions/consumed/inp-001.json" ]
  [ -f "$registry_run/actions/injections/inp-001.md" ]
  grep -q 'OPERATOR_INPUT_RESPONSE: START' "$registry_run/actions/injections/inp-001.md"
  [ "$(jq -r '.controlPlanPath,.currentTodoId' "$registry_run/engine/stages/investigate.json" | paste -sd, -)" = "$control,open-todo" ]
  run workflow_action_consume_once "$registry_run" inp-001 resume
  [ "$status" -ne 0 ]

  # Approved gate
  run_id="$(seed_sequential_run run-seq-gate)"
  registry_run="$CASE/workflow-runs/$run_id"
  mkdir -p "$CASE/.ralph-workspace/artifacts/seq-recovery"
  printf 'ok\n' >"$CASE/.ralph-workspace/artifacts/seq-recovery/investigation.md"
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id investigate --state running --attempt 1
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id investigate --state succeeded \
    --terminal-result succeeded \
    --artifacts-json '[".ralph-workspace/artifacts/seq-recovery/investigation.md"]'
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id implement --state running --attempt 1
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id implement --state succeeded --terminal-result succeeded
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id approve-plan --state running --attempt 1
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id approve-plan --state waiting \
    --blocker-json '{"kind":"approval","requestId":"appr-001","reasonCode":"human-approval","retryable":true,"changesTarget":"investigate"}'
  write_approval_request "$registry_run" appr-001 approve-plan
  workflow_action_decision_write "$registry_run" "$(jq -nc \
    --arg runId "$run_id" \
    '{requestId:"appr-001",kind:"approval",runId:$runId,stageId:"approve-plan",attemptId:"approve-plan-1",decision:"approve",actorSource:"test",decidedAt:"2026-08-26T15:00:00Z"}')" >/dev/null
  workflow_seq_update_run --registry-run "$registry_run" --state waiting --owner-json "$(_workflow_seq_null_owner_json)"
  run workflow_seq_resume --registry-run "$registry_run" --workspace "$CASE"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(printf '%s' "$output" | jq -r '.stages[] | select(.stageId=="approve-plan") | .action')" = "complete-approved-gate" ]
  [ "$(jq -r '.state' "$registry_run/engine/stages/approve-plan.json")" = "succeeded" ]
  [ -f "$registry_run/actions/consumed/appr-001.json" ]
}

@test "Sequential unresolved action and changes requested refuse with guidance" {
  local run_id registry_run
  run_id="$(seed_sequential_run run-seq-refuse)"
  registry_run="$CASE/workflow-runs/$run_id"
  write_approval_request "$registry_run" appr-u approve-plan
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id approve-plan --state running --attempt 1
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id approve-plan --state waiting \
    --blocker-json '{"kind":"approval","requestId":"appr-u","reasonCode":"human-approval","retryable":false,"changesTarget":"investigate"}'
  workflow_seq_update_run --registry-run "$registry_run" --state waiting --owner-json "$(_workflow_seq_null_owner_json)"
  workflow_state_clear_owner_and_set_state "$CASE" "$run_id" waiting

  wf_cli resume "$run_id" --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"actions list"* ]]

  workflow_seq_write_stage --registry-run "$registry_run" --stage-id approve-plan --state blocked \
    --blocker-json '{"kind":"approval","requestId":"appr-u","reasonCode":"human-changes-requested","retryable":false,"changesTarget":"investigate"}' \
    --skip-transition-check
  workflow_action_decision_write "$registry_run" "$(jq -nc \
    --arg runId "$run_id" \
    '{requestId:"appr-u",kind:"approval",runId:$runId,stageId:"approve-plan",attemptId:"approve-plan-1",decision:"request-changes",message:"fix it",actorSource:"test",decidedAt:"2026-08-26T15:00:00Z"}')" >/dev/null
  workflow_state_clear_owner_and_set_state "$CASE" "$run_id" blocked
  wf_cli resume "$run_id" --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"reset"* ]]
}

@test "Sequential skip succeeded and provided control plan retained on resume" {
  local run_id registry_run control sourcep
  run_id="$(seed_sequential_run run-seq-skip)"
  registry_run="$CASE/workflow-runs/$run_id"
  mkdir -p "$CASE/.ralph-workspace/artifacts/seq-recovery" "$registry_run/plans/implement/attempt-1"
  printf 'ok\n' >"$CASE/.ralph-workspace/artifacts/seq-recovery/investigation.md"
  sourcep="$registry_run/plans/implement/attempt-1/source.plan.md"
  control="$registry_run/plans/implement/attempt-1/control.plan.md"
  printf '%s\n' '---' 'name: src' '---' '- [x] done' '- [ ] open' >"$sourcep"
  cp -f "$sourcep" "$control"

  workflow_seq_write_stage --registry-run "$registry_run" --stage-id investigate --state running --attempt 1
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id investigate --state succeeded \
    --terminal-result succeeded \
    --artifacts-json '[".ralph-workspace/artifacts/seq-recovery/investigation.md"]'
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id implement --state failed --attempt 1 \
    --control-plan-path "$control" --source-plan-path "$sourcep" \
    --plan-source-kind provided --current-todo-id open \
    --completed-todos 1 --total-todos 2
  workflow_seq_update_run --registry-run "$registry_run" --state failed --owner-json "$(_workflow_seq_null_owner_json)"

  run workflow_seq_resume --registry-run "$registry_run" --workspace "$CASE"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(printf '%s' "$output" | jq -r '.stages[] | select(.stageId=="investigate") | .action')" = "skip-succeeded" ]
  [ "$(printf '%s' "$output" | jq -r '.stages[] | select(.stageId=="implement") | .action')" = "retry" ]
  [ "$(printf '%s' "$output" | jq -r '.stages[] | select(.stageId=="implement") | .controlPlanPath')" = "$control" ]
  [ "$(jq -r '.controlPlanPath,.planSourceKind,.currentTodoId' "$registry_run/engine/stages/implement.json" | paste -sd, -)" = "$control,provided,open" ]
  # Source bytes unchanged
  cmp -s "$sourcep" "$control" || true
  [ "$(jq -r '.state' "$registry_run/engine/stages/investigate.json")" = "succeeded" ]
}

# --- Dependency engine primitives -------------------------------------------

@test "Dependency clean interruption answered input consume once approved gate both modes" {
  local run_id registry_run graph_dir control
  run_id="$(seed_dependency_run run-dep-wait)"
  registry_run="$CASE/workflow-runs/$run_id"
  graph_dir="$CASE/graph-runs/recovery/$run_id"
  control="$registry_run/plans/implement/attempt-1/control.plan.md"

  run workflow_dep_resume --state-root "$CASE" --run-id "$run_id" --workspace "$FIX_PROJECT" --dry-run
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(printf '%s' "$output" | jq -r '.mode')" = "dependency" ]
  [ "$(printf '%s' "$output" | jq -r '.stages[] | select(.stageId=="implement") | .action')" = "retry" ]

  # Answered input on implement
  jq --arg control "$control" \
    '.status="awaiting-operator" | .blocker={kind:"input",requestId:"inp-d1",reasonCode:"operator-input",retryable:true} | .controlPlanPath=$control | .currentTodoId="work" | .planSourceKind="provided" | .completedTodos=0 | .totalTodos=1' \
    "$graph_dir/nodes/implement.json" >"$graph_dir/nodes/implement.json.tmp"
  mv -f "$graph_dir/nodes/implement.json.tmp" "$graph_dir/nodes/implement.json"
  write_input_request "$registry_run" inp-d1 implement
  workflow_action_decision_write "$registry_run" "$(jq -nc \
    --arg runId "$run_id" \
    '{requestId:"inp-d1",kind:"input",runId:$runId,stageId:"implement",attemptId:"implement-1",decision:"answer",message:"ship it",actorSource:"test",decidedAt:"2026-08-26T15:00:00Z"}')" >/dev/null

  run workflow_dep_resume --state-root "$CASE" --run-id "$run_id" --workspace "$FIX_PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(printf '%s' "$output" | jq -r '.stages[] | select(.stageId=="implement") | .action')" = "retry-answered-input" ]
  [ -f "$registry_run/actions/consumed/inp-d1.json" ]
  [ -f "$registry_run/actions/injections/inp-d1.md" ]
  [ "$(jq -r '.controlPlanPath,.currentTodoId,.status' "$graph_dir/nodes/implement.json" | paste -sd, -)" = "$control,work,pending" ]
  run workflow_action_consume_once "$registry_run" inp-d1 resume
  [ "$status" -ne 0 ]

  # Approved gate
  run_id="$(seed_dependency_run run-dep-gate)"
  registry_run="$CASE/workflow-runs/$run_id"
  graph_dir="$CASE/graph-runs/recovery/$run_id"
  jq '.status="succeeded"' "$graph_dir/nodes/implement.json" >"$graph_dir/nodes/implement.json.tmp"
  mv -f "$graph_dir/nodes/implement.json.tmp" "$graph_dir/nodes/implement.json"
  jq '.status="awaiting-operator" | .blocker={kind:"approval",requestId:"appr-d1",reasonCode:"human-approval",retryable:true,changesTarget:"implement"}' \
    "$graph_dir/nodes/approve-plan.json" >"$graph_dir/nodes/approve-plan.json.tmp"
  mv -f "$graph_dir/nodes/approve-plan.json.tmp" "$graph_dir/nodes/approve-plan.json"
  write_approval_request "$registry_run" appr-d1 approve-plan
  # Fix changesTarget on request for dependency
  jq '.changesTarget="implement"' "$registry_run/actions/requests/appr-d1.json" >"$registry_run/actions/requests/appr-d1.json.tmp"
  mv -f "$registry_run/actions/requests/appr-d1.json.tmp" "$registry_run/actions/requests/appr-d1.json"
  chmod u+w "$registry_run/actions/requests/appr-d1.json" 2>/dev/null || true
  workflow_action_decision_write "$registry_run" "$(jq -nc \
    --arg runId "$run_id" \
    '{requestId:"appr-d1",kind:"approval",runId:$runId,stageId:"approve-plan",attemptId:"approve-plan-1",decision:"approve",actorSource:"test",decidedAt:"2026-08-26T15:00:00Z"}')" >/dev/null

  run workflow_dep_resume --state-root "$CASE" --run-id "$run_id" --workspace "$FIX_PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(printf '%s' "$output" | jq -r '.stages[] | select(.stageId=="approve-plan") | .action')" = "complete-approved-gate" ]
  [ "$(jq -r '.status' "$graph_dir/nodes/approve-plan.json")" = "succeeded" ]
  [ -f "$registry_run/actions/consumed/appr-d1.json" ]
}

@test "Dependency unresolved action changes requested skip succeeded provided control plan" {
  local run_id registry_run graph_dir control sourcep
  run_id="$(seed_dependency_run run-dep-refuse)"
  registry_run="$CASE/workflow-runs/$run_id"
  graph_dir="$CASE/graph-runs/recovery/$run_id"
  control="$registry_run/plans/implement/attempt-1/control.plan.md"
  sourcep="$registry_run/plans/implement/attempt-1/source.plan.md"

  write_approval_request "$registry_run" appr-x approve-plan
  jq '.status="awaiting-operator" | .blocker={kind:"approval",requestId:"appr-x",reasonCode:"human-approval",retryable:false,changesTarget:"implement"}' \
    "$graph_dir/nodes/approve-plan.json" >"$graph_dir/nodes/approve-plan.json.tmp"
  mv -f "$graph_dir/nodes/approve-plan.json.tmp" "$graph_dir/nodes/approve-plan.json"
  jq '.status="succeeded" | .controlPlanPath=$c | .sourcePlanPath=$s | .planSourceKind="provided"' \
    --arg c "$control" --arg s "$sourcep" \
    "$graph_dir/nodes/implement.json" >"$graph_dir/nodes/implement.json.tmp"
  mv -f "$graph_dir/nodes/implement.json.tmp" "$graph_dir/nodes/implement.json"

  run workflow_dep_resume --state-root "$CASE" --run-id "$run_id" --workspace "$FIX_PROJECT" --dry-run
  [ "$status" -ne 0 ]
  [ "$(printf '%s' "$output" | jq -r '.ok')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.stages[] | select(.stageId=="approve-plan") | .action')" = "refuse" ]
  [ "$(printf '%s' "$output" | jq -r '.stages[] | select(.stageId=="implement") | .action')" = "skip-succeeded" ]

  workflow_state_clear_owner_and_set_state "$CASE" "$run_id" waiting
  wf_cli resume "$run_id" --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"actions list"* ]]

  # changes requested
  workflow_action_decision_write "$registry_run" "$(jq -nc \
    --arg runId "$run_id" \
    '{requestId:"appr-x",kind:"approval",runId:$runId,stageId:"approve-plan",attemptId:"approve-plan-1",decision:"request-changes",message:"fix",actorSource:"test",decidedAt:"2026-08-26T15:00:00Z"}')" >/dev/null
  jq '.status="blocked" | .blocker={kind:"approval",requestId:"appr-x",reasonCode:"human-changes-requested",retryable:false,changesTarget:"implement"} | .reasonCode="human-changes-requested"' \
    "$graph_dir/nodes/approve-plan.json" >"$graph_dir/nodes/approve-plan.json.tmp"
  mv -f "$graph_dir/nodes/approve-plan.json.tmp" "$graph_dir/nodes/approve-plan.json"
  workflow_state_clear_owner_and_set_state "$CASE" "$run_id" blocked
  wf_cli resume "$run_id" --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"reset"* ]]

  # Provided control plan retained across successful resume of interrupted implement
  run_id="$(seed_dependency_run run-dep-ctrl)"
  registry_run="$CASE/workflow-runs/$run_id"
  graph_dir="$CASE/graph-runs/recovery/$run_id"
  control="$registry_run/plans/implement/attempt-1/control.plan.md"
  sourcep="$registry_run/plans/implement/attempt-1/source.plan.md"
  before_ctrl="$(cksum "$control" | awk '{print $1}')"
  before_src="$(cksum "$sourcep" | awk '{print $1}')"
  run workflow_dep_resume --state-root "$CASE" --run-id "$run_id" --workspace "$FIX_PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cksum "$control" | awk '{print $1}')" = "$before_ctrl" ]
  [ "$(cksum "$sourcep" | awk '{print $1}')" = "$before_src" ]
  [ "$(jq -r '.controlPlanPath,.planSourceKind' "$graph_dir/nodes/implement.json" | paste -sd, -)" = "$control,provided" ]
}

# --- Dependency reset primitive ---------------------------------------------

write_planner_graph_json() {
  local path="$1"
  jq -n '{
    schemaVersion: 1,
    namespace: "recovery",
    maxParallel: 2,
    nodes: [
      {
        id: "plan-implementation",
        type: "agent",
        dependsOn: [],
        derivedFrom: "stage",
        stage: {
          id: "plan-implementation",
          runtime: "cursor",
          planner: {outputMode: "plan-file", maxTodos: 40}
        }
      },
      {
        id: "implement",
        type: "agent",
        dependsOn: ["plan-implementation"],
        derivedFrom: "stage",
        planFromBinding: {plannerStageId: "plan-implementation", planSourceKind: "generated"},
        stage: {
          id: "implement",
          runtime: "cursor",
          planFrom: "plan-implementation"
        }
      },
      {
        id: "approve-plan",
        type: "approval",
        dependsOn: ["implement"],
        derivedFrom: "stage",
        stage: {
          id: "approve-plan",
          question: "Approve?",
          changesTarget: "plan-implementation"
        }
      },
      {
        id: "integrate",
        type: "integrate",
        dependsOn: ["approve-plan"],
        derivedFrom: "stage",
        stage: {id: "integrate"}
      }
    ],
    edges: [
      {from: "plan-implementation", to: "implement"},
      {from: "implement", to: "approve-plan"},
      {from: "approve-plan", to: "integrate"}
    ]
  }' >"$path"
}

seed_dependency_planner_run() {
  local preferred="${1:-}"
  local run_id registry_run graph_dir sourcep controlp graph_json
  mkdir -p "$CASE/inputs"
  printf '%s\n' '---' 'kind: workflow' 'mode: dependency' 'overview: recovery' '---' >"$CASE/inputs/wf-dep-plan.md"
  write_planner_graph_json "$CASE/inputs/sample.planner.graph.json"
  printf '# plan\n- [ ] work\n' >"$CASE/inputs/dep.input.plan.md"

  if [[ -n "$preferred" ]]; then
    export WORKFLOW_STATE_FIXED_RUN_ID="$preferred"
  else
    unset WORKFLOW_STATE_FIXED_RUN_ID
  fi
  run_id="$(
    workflow_state_create \
      --state-root "$CASE" \
      --source-path "$CASE/inputs/wf-dep-plan.md" \
      --source-kind project \
      --mode dependency \
      --entry-kind task \
      --task "Planner reset fixture" \
      --task-provenance explicit \
      --input-file "$CASE/inputs/dep.input.plan.md" \
      --workflow-id feature-delivery \
      --engine-namespace recovery \
      --state blocked
  )"
  unset WORKFLOW_STATE_FIXED_RUN_ID
  registry_run="$CASE/workflow-runs/$run_id"
  graph_dir="$CASE/graph-runs/recovery/$run_id"
  sourcep="$registry_run/plans/plan-implementation/attempt-1/source.plan.md"
  controlp="$registry_run/plans/implement/attempt-1/control.plan.md"
  jq '.recoveryFeedback={sourceStageId:"old-review",targetStageId:"implement"}' \
    "$graph_dir/nodes/implement.json" >"$graph_dir/nodes/implement.json.tmp"
  mv -f "$graph_dir/nodes/implement.json.tmp" "$graph_dir/nodes/implement.json"
  graph_json="$graph_dir/graph.json"

  mkdir -p \
    "$registry_run/plans/plan-implementation/attempt-1" \
    "$registry_run/plans/implement/attempt-1" \
    "$graph_dir/nodes"
  printf '# plan\n- [ ] work\n' >"$sourcep"
  printf '%s\n' '{"schemaVersion":1,"producerStageId":"plan-implementation","producerAttempt":1,"planPath":"'"$sourcep"'","planSha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","todoCount":1,"createdAt":"2026-08-26T15:00:00Z"}' \
    >"$registry_run/plans/plan-implementation/attempt-1/manifest.json"
  cp -f "$sourcep" "$controlp"
  write_planner_graph_json "$graph_json"

  workflow_state_update "$CASE" "$run_id" \
    '.engine = {kind:"graph", statePath:$sp, namespace:"recovery"}' \
    --arg sp "$graph_dir"

  export RALPH_GRAPH_STATE_ROOT="$CASE"
  export RALPH_PLAN_WORKSPACE_ROOT="$CASE"
  export WORKFLOW_DEP_FIXED_RESET_SUFFIX="abc123"
  jq -n --arg runId "$run_id" --arg registry "$registry_run" '{
    schemaVersion: 3,
    runId: $runId,
    namespace: "recovery",
    status: "failed",
    startedAt: "2026-08-26T10:00:00Z",
    heartbeatAt: null,
    supervisorPid: null,
    registryRunPath: $registry
  }' >"$graph_dir/run.json"

  jq -n --arg source "$sourcep" '{
    schemaVersion: 3,
    nodeId: "plan-implementation",
    status: "succeeded",
    lastAttemptId: "plan-implementation__'"$run_id"'__1",
    planSourceKind: null,
    sourcePlanPath: $source,
    controlPlanPath: null,
    attempts: [{attemptId: "plan-implementation__'"$run_id"'__1", outcome: "success"}]
  }' >"$graph_dir/nodes/plan-implementation.json"

  jq -n --arg source "$sourcep" --arg control "$controlp" '{
    schemaVersion: 3,
    nodeId: "implement",
    status: "failed",
    lastAttemptId: "implement__'"$run_id"'__1",
    planPath: $control,
    planRunId: "implement-run-1",
    planSourceKind: "generated",
    planSourceStageId: "plan-implementation",
    sourcePlanPath: $source,
    controlPlanPath: $control,
    currentTodoId: "work",
    completedTodos: 0,
    totalTodos: 1,
    blocker: null,
    attempts: [{attemptId: "implement__'"$run_id"'__1", outcome: "failure"}]
  }' >"$graph_dir/nodes/implement.json"

  jq -n '{
    schemaVersion: 3,
    nodeId: "approve-plan",
    status: "pending",
    lastAttemptId: null,
    attempts: []
  }' >"$graph_dir/nodes/approve-plan.json"

  jq -n '{
    schemaVersion: 3,
    nodeId: "integrate",
    status: "pending",
    lastAttemptId: null,
    attempts: []
  }' >"$graph_dir/nodes/integrate.json"

  printf '%s\n' "$run_id"
}

@test "Dependency reset primitive plans selected stage plus dependency downstream" {
  local run_id registry_run preview
  run_id="$(seed_dependency_planner_run run-dep-reset-plan)"
  registry_run="$CASE/workflow-runs/$run_id"

  run workflow_dep_reset_plan \
    --state-root "$CASE" \
    --run-id "$run_id" \
    --stage plan-implementation \
    --workspace "$FIX_PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  preview="$output"
  [ "$(printf '%s' "$preview" | jq -r '.ok')" = "true" ]
  [ "$(printf '%s' "$preview" | jq -r '.dryRun')" = "true" ]
  [ "$(printf '%s' "$preview" | jq -r '.mode')" = "dependency" ]
  [ "$(printf '%s' "$preview" | jq -r '.stageId')" = "plan-implementation" ]
  # Selected first, then sorted dependents
  [ "$(printf '%s' "$preview" | jq -r '[.stages[].stageId] | join(" ")')" = "plan-implementation approve-plan implement integrate" ]
  [ "$(printf '%s' "$preview" | jq -r '.stages[] | select(.stageId=="plan-implementation") | .planAction')" = "new-planner-attempt" ]
  [ "$(printf '%s' "$preview" | jq -r '.stages[] | select(.stageId=="implement") | .planAction')" = "wait-upstream" ]
  [ "$(printf '%s' "$preview" | jq -r '.stages[] | select(.stageId=="approve-plan") | .action')" = "invalidate" ]
  [ "$(printf '%s' "$preview" | jq -r '.stages[] | select(.stageId=="integrate") | .role')" = "derived-supervisor" ]
}

@test "dependency archive preserves immutable sources and dependency dry-run is byte-nonmutating" {
  local run_id registry_run graph_dir sourcep controlp before after archive
  run_id="$(seed_dependency_planner_run run-dep-reset-dry)"
  registry_run="$CASE/workflow-runs/$run_id"
  graph_dir="$CASE/graph-runs/recovery/$run_id"
  sourcep="$registry_run/plans/plan-implementation/attempt-1/source.plan.md"
  controlp="$registry_run/plans/implement/attempt-1/control.plan.md"

  before="$(find "$registry_run" "$graph_dir" -type f -print0 | sort -z | xargs -0 cksum | cksum)"
  run workflow_dep_reset_plan \
    --state-root "$CASE" --run-id "$run_id" --stage plan-implementation --workspace "$FIX_PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  after="$(find "$registry_run" "$graph_dir" -type f -print0 | sort -z | xargs -0 cksum | cksum)"
  [ "$before" = "$after" ]

  run workflow_dep_reset_apply \
    --state-root "$CASE" --run-id "$run_id" --stage plan-implementation --workspace "$FIX_PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  archive="$(printf '%s' "$output" | jq -r '.archivePath')"
  [ -d "$archive" ]
  [ -f "$archive/nodes/plan-implementation.json" ]
  [ -f "$archive/nodes/implement.json" ]
  [ -f "$sourcep" ]
  [ -f "$registry_run/plans/plan-implementation/attempt-1/manifest.json" ]
  [ "$(jq -r '.state' "$registry_run/run.json")" = "blocked" ]
  [ "$(jq -r '.status' "$graph_dir/nodes/plan-implementation.json")" = "pending" ]
  [ "$(jq -r '.waitingForPlanner // false' "$graph_dir/nodes/implement.json")" = "true" ]
  [ "$(jq -r 'has("recoveryFeedback")' "$graph_dir/nodes/implement.json")" = "false" ]
  [ ! -f "$controlp" ] || [ "$(jq -r '.controlPlanPath // empty' "$graph_dir/nodes/implement.json")" = "" ]
}

@test "dependency succeeded planner schedules new attempt and provided consumer gets fresh control" {
  local run_id registry_run graph_dir sourcep controlp new_control
  # Planner path
  run_id="$(seed_dependency_planner_run run-dep-reset-planner)"
  registry_run="$CASE/workflow-runs/$run_id"
  graph_dir="$CASE/graph-runs/recovery/$run_id"

  run workflow_dep_reset_apply \
    --state-root "$CASE" --run-id "$run_id" --stage plan-implementation --workspace "$FIX_PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(printf '%s' "$output" | jq -r '.stages[] | select(.stageId=="plan-implementation") | .planAction')" = "new-planner-attempt" ]
  [ "$(printf '%s' "$output" | jq -r '.stages[] | select(.stageId=="plan-implementation") | .nextAttempt')" = "2" ]
  [ "$(jq -r '.scheduledPlannerAttempt' "$graph_dir/nodes/plan-implementation.json")" = "2" ]
  [ "$(jq -r '.waitingForPlanner' "$graph_dir/nodes/implement.json")" = "true" ]

  # Provided consumer path (existing seed_dependency_run)
  run_id="$(seed_dependency_run run-dep-reset-provided)"
  registry_run="$CASE/workflow-runs/$run_id"
  graph_dir="$CASE/graph-runs/recovery/$run_id"
  sourcep="$registry_run/plans/implement/attempt-1/source.plan.md"
  controlp="$registry_run/plans/implement/attempt-1/control.plan.md"
  printf 'marker-provided\n' >>"$controlp"
  workflow_state_clear_owner_and_set_state "$CASE" "$run_id" failed
  jq '.status="failed"' "$graph_dir/nodes/implement.json" >"$graph_dir/nodes/implement.json.tmp"
  mv -f "$graph_dir/nodes/implement.json.tmp" "$graph_dir/nodes/implement.json"

  run workflow_dep_reset_apply \
    --state-root "$CASE" --run-id "$run_id" --stage implement --workspace "$FIX_PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(printf '%s' "$output" | jq -r '.stages[] | select(.stageId=="implement") | .planAction')" = "fresh-control-provided" ]
  new_control="$(jq -r '.controlPlanPath' "$graph_dir/nodes/implement.json")"
  [ -n "$new_control" ]
  [ -f "$new_control" ]
  [ -f "$sourcep" ]
  ! grep -q 'marker-provided' "$new_control"
  [ "$(cksum "$sourcep" | awk '{print $1}')" = "$(cksum "$new_control" | awk '{print $1}')" ]
  [ "$(jq -r '.status' "$graph_dir/nodes/implement.json")" = "pending" ]
  [ "$(jq -r '.state' "$registry_run/run.json")" = "blocked" ]
}

@test "Dependency exhausted review reset carries the final verdict into the repair retry" {
  local run_id registry_run graph_dir graph_file sourcep controlp preview applied new_control orch
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-dispatch.sh"
  run_id="$(seed_dependency_planner_run run-dep-reset-review-exhausted)"
  export RALPH_GRAPH_STATE_ROOT="$CASE"
  export RALPH_PLAN_WORKSPACE_ROOT="$CASE"
  registry_run="$CASE/workflow-runs/$run_id"
  graph_dir="$CASE/graph-runs/recovery/$run_id"
  graph_file="$graph_dir/graph.json"
  sourcep="$registry_run/plans/plan-implementation/attempt-1/source.plan.md"
  controlp="$registry_run/plans/implement-r2/attempt-1/control.plan.md"

  mkdir -p "$(dirname "$controlp")" "$CASE/artifacts/recovery" \
    "$FIX_PROJECT/bundle/.ralph/schemas"
  cp -f "$sourcep" "$controlp"
  cp -f "$REPO_ROOT/bundle/.ralph/schemas/evaluator-verdict.schema.json" \
    "$FIX_PROJECT/bundle/.ralph/schemas/evaluator-verdict.schema.json"
  printf '%s\n' '{"status":"changes-required","feedback":["remove the unrelated resolver rewrite"]}' \
    >"$CASE/artifacts/recovery/review-r2-verdict.json"

  jq '
    .nodes += [
      {id:"implement-r2",type:"agent",dependsOn:[],derivedFrom:"rework",
       planFromBinding:{plannerStageId:"plan-implementation",planSourceKind:"generated"},
       stage:{id:"implement-r2",runtime:"cursor",planFrom:"plan-implementation"}},
      {id:"review-r2",type:"agent",dependsOn:["implement-r2"],derivedFrom:"rework",
       stage:{id:"review-r2",runtime:"claude",
         loopCheck:{path:".ralph-workspace/artifacts/{{ARTIFACT_NS}}/{{STAGE_ID}}-verdict.json",
                    schema:"bundle/.ralph/schemas/evaluator-verdict.schema.json"}}}
    ]
    | .edges += [{from:"implement-r2",to:"review-r2",reasons:["rework"]}]
  ' "$graph_file" >"$graph_file.tmp"
  mv -f "$graph_file.tmp" "$graph_file"

  jq -n --arg source "$sourcep" --arg control "$controlp" --arg run "$run_id" '{
    schemaVersion:3,nodeId:"implement-r2",status:"succeeded",
    lastAttemptId:("implement-r2__" + $run + "__1"),
    planSourceKind:"generated",planSourceStageId:"plan-implementation",
    sourcePlanPath:$source,controlPlanPath:$control,planPath:$control,
    completedTodos:1,totalTodos:1,
    attempts:[{attemptId:("implement-r2__" + $run + "__1"),outcome:"success"}]
  }' >"$graph_dir/nodes/implement-r2.json"
  jq -n --arg run "$run_id" '{
    schemaVersion:3,nodeId:"review-r2",status:"failed",
    lastAttemptId:("review-r2__" + $run + "__1"),
    attempts:[{attemptId:("review-r2__" + $run + "__1"),outcome:"failed",
      reason:"review-changes-required-no-edge"}]
  }' >"$graph_dir/nodes/review-r2.json"
  workflow_state_clear_owner_and_set_state "$CASE" "$run_id" failed

  run workflow_dep_reset_plan \
    --state-root "$CASE" --run-id "$run_id" --stage implement-r2 --workspace "$FIX_PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  preview="$output"
  [ "$(printf '%s' "$preview" | jq -r '.evaluatorFeedback.sourceStageId')" = "review-r2" ]
  [ "$(printf '%s' "$preview" | jq -r '.evaluatorFeedback.targetStageId')" = "implement-r2" ]
  [ "$(printf '%s' "$preview" | jq -r '.evaluatorFeedback.status')" = "changes-required" ]

  run workflow_dep_reset_apply \
    --state-root "$CASE" --run-id "$run_id" --stage implement-r2 --workspace "$FIX_PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  applied="$output"
  [ "$(printf '%s' "$applied" | jq -r '.evaluatorFeedback.sourceStageId')" = "review-r2" ]
  [ "$(jq -r '.recoveryFeedback.sourceStageId' "$graph_dir/nodes/implement-r2.json")" = "review-r2" ]
  [ "$(graph_state_read_node "$CASE" recovery "$run_id" implement-r2 \
    | jq -r '.recoveryFeedback.sourceStageId')" = "review-r2" ]
  new_control="$(jq -r '.controlPlanPath' "$graph_dir/nodes/implement-r2.json")"
  [ -f "$new_control" ]

  orch="$CASE/recovery-review.orch.json"
  jq -n --arg plan "$new_control" '{name:"recovery",namespace:"recovery",
    stages:[{id:"implement-r2",runtime:"cursor",plan:$plan}]}' >"$orch"
  run _graph_dispatch_inject_rework_feedback \
    "$graph_file" implement-r2 "$FIX_PROJECT" recovery "$CASE" \
    "$FIX_PROJECT" "$orch" "$run_id"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -Fq -- "remove the unrelated resolver rewrite" "$new_control"
  grep -Fq -- 'Source stage: `review-r2`' "$new_control"
}

@test "human feedback binds once and invalidate approval plus derived supervisor" {
  local run_id registry_run graph_dir inj
  run_id="$(seed_dependency_planner_run run-dep-reset-feedback)"
  registry_run="$CASE/workflow-runs/$run_id"
  graph_dir="$CASE/graph-runs/recovery/$run_id"

  write_approval_request "$registry_run" appr-reset approve-plan
  jq '.changesTarget="plan-implementation"' \
    "$registry_run/actions/requests/appr-reset.json" >"$registry_run/actions/requests/appr-reset.json.tmp"
  mv -f "$registry_run/actions/requests/appr-reset.json.tmp" "$registry_run/actions/requests/appr-reset.json"
  chmod u+w "$registry_run/actions/requests/appr-reset.json" 2>/dev/null || true
  workflow_action_decision_write "$registry_run" "$(jq -nc \
    --arg runId "$run_id" \
    '{requestId:"appr-reset",kind:"approval",runId:$runId,stageId:"approve-plan",attemptId:"approve-plan-1",decision:"request-changes",message:"please regenerate plan",actorSource:"test",decidedAt:"2026-08-26T15:00:00Z"}')" >/dev/null
  jq '.status="blocked" | .blocker={kind:"approval",requestId:"appr-reset",reasonCode:"human-changes-requested",retryable:false,changesTarget:"plan-implementation"}' \
    "$graph_dir/nodes/approve-plan.json" >"$graph_dir/nodes/approve-plan.json.tmp"
  mv -f "$graph_dir/nodes/approve-plan.json.tmp" "$graph_dir/nodes/approve-plan.json"

  run workflow_dep_reset_apply \
    --state-root "$CASE" --run-id "$run_id" --stage plan-implementation --workspace "$FIX_PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(printf '%s' "$output" | jq -r '.humanFeedback.requestId')" = "appr-reset" ]
  [ -f "$registry_run/actions/consumed/appr-reset.json" ]
  [ "$(jq -r '.consumer' "$registry_run/actions/consumed/appr-reset.json")" = "reset" ]
  inj="$registry_run/actions/injections/appr-reset.md"
  [ -f "$inj" ]
  grep -q 'OPERATOR_HUMAN_FEEDBACK' "$inj"
  grep -q 'please regenerate plan' "$inj"
  [ "$(jq -r '.status' "$graph_dir/nodes/approve-plan.json")" = "pending" ]
  [ "$(jq -r '.status' "$graph_dir/nodes/integrate.json")" = "pending" ]
  [ "$(jq -r '.blocker // null' "$graph_dir/nodes/approve-plan.json")" = "null" ]
}

@test "dependency unsafe refuses unknown supervisor live-running cancelled and succeeded" {
  local run_id registry_run graph_dir
  run_id="$(seed_dependency_planner_run run-dep-reset-unsafe)"
  registry_run="$CASE/workflow-runs/$run_id"
  graph_dir="$CASE/graph-runs/recovery/$run_id"

  run workflow_dep_reset_plan --state-root "$CASE" --run-id "$run_id" --stage missing-stage --workspace "$FIX_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown stage"* ]]

  run workflow_dep_reset_plan --state-root "$CASE" --run-id "$run_id" --stage approve-plan --workspace "$FIX_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"supervisor"* || "$output" == *"approval"* ]]

  run workflow_dep_reset_plan --state-root "$CASE" --run-id "$run_id" --stage integrate --workspace "$FIX_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"supervisor"* || "$output" == *"integrate"* ]]

  jq '.status="running"' "$graph_dir/nodes/implement.json" >"$graph_dir/nodes/implement.json.tmp"
  mv -f "$graph_dir/nodes/implement.json.tmp" "$graph_dir/nodes/implement.json"
  run workflow_dep_reset_plan --state-root "$CASE" --run-id "$run_id" --stage plan-implementation --workspace "$FIX_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"live-running"* ]]
  jq '.status="failed"' "$graph_dir/nodes/implement.json" >"$graph_dir/nodes/implement.json.tmp"
  mv -f "$graph_dir/nodes/implement.json.tmp" "$graph_dir/nodes/implement.json"

  workflow_state_clear_owner_and_set_state "$CASE" "$run_id" cancelled
  run workflow_dep_reset_plan --state-root "$CASE" --run-id "$run_id" --stage plan-implementation --workspace "$FIX_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cancelled"* || "$output" == *"terminal"* ]]

  # Fresh succeeded outer run
  run_id="$(seed_dependency_planner_run run-dep-reset-ok)"
  workflow_state_clear_owner_and_set_state "$CASE" "$run_id" succeeded
  run workflow_dep_reset_plan --state-root "$CASE" --run-id "$run_id" --stage plan-implementation --workspace "$FIX_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"succeeded"* || "$output" == *"terminal"* ]]
}

# --- Sequential reset primitive ---------------------------------------------

write_seq_planner_orch() {
  local path="$1"
  cat >"$path" <<'ORCH'
{
  "name": "seq-reset-planner",
  "namespace": "seq-reset-planner",
  "stages": [
    {
      "id": "plan-implementation",
      "runtime": "cursor",
      "planner": {"outputMode": "plan-file", "maxTodos": 40}
    },
    {
      "id": "implement",
      "runtime": "cursor",
      "planFrom": "plan-implementation"
    },
    {
      "id": "approve-plan",
      "type": "approval",
      "question": "Approve?",
      "changesTarget": "plan-implementation",
      "inputArtifacts": [
        {"path": ".ralph-workspace/artifacts/seq-reset/impl.md", "required": true}
      ]
    },
    {
      "id": "integrate",
      "type": "integrate"
    }
  ]
}
ORCH
}

write_seq_parallel_orch() {
  local path="$1"
  cat >"$path" <<'ORCH'
{
  "name": "seq-reset-parallel",
  "namespace": "seq-reset-parallel",
  "stages": [
    {"id": "wave-a", "runtime": "cursor"},
    {"id": "wave-b", "runtime": "cursor"},
    {"id": "join-tail", "runtime": "cursor"},
    {"id": "approve-plan", "type": "approval", "question": "Ok?", "changesTarget": "wave-a",
      "inputArtifacts": [{"path": ".ralph-workspace/artifacts/seq-reset/a.md", "required": true}]}
  ],
  "parallelStages": [
    ["wave-a", "wave-b"],
    ["join-tail"]
  ]
}
ORCH
}

seed_sequential_planner_run() {
  local preferred="${1:-}"
  local run_id registry_run sourcep controlp input_path
  mkdir -p "$CASE/inputs"
  printf '%s\n' '---' 'kind: workflow' 'mode: sequential' 'overview: seq reset' '---' >"$CASE/inputs/wf-seq-plan.md"
  write_seq_planner_orch "$CASE/inputs/seq.planner.orch.json"
  printf '# plan\n- [ ] work\n' >"$CASE/inputs/seq.input.plan.md"

  if [[ -n "$preferred" ]]; then
    export WORKFLOW_STATE_FIXED_RUN_ID="$preferred"
  else
    unset WORKFLOW_STATE_FIXED_RUN_ID
  fi
  run_id="$(
    workflow_state_create \
      --state-root "$CASE" \
      --source-path "$CASE/inputs/wf-seq-plan.md" \
      --source-kind project \
      --mode sequential \
      --entry-kind task \
      --task "Sequential planner reset fixture" \
      --task-provenance explicit \
      --input-file "$CASE/inputs/seq.planner.orch.json" \
      --workflow-id seq-reset-planner \
      --state blocked
  )"
  unset WORKFLOW_STATE_FIXED_RUN_ID
  registry_run="$CASE/workflow-runs/$run_id"
  input_path="$(jq -r '.inputPath' "$registry_run/run.json")"
  export WORKFLOW_SEQ_FIXED_RESET_SUFFIX="abc123"
  workflow_seq_init_engine \
    --registry-run "$registry_run" \
    --input-file "$input_path" \
    --run-id "$run_id" \
    --state blocked >/dev/null

  sourcep="$registry_run/plans/plan-implementation/attempt-1/source.plan.md"
  controlp="$registry_run/plans/implement/attempt-1/control.plan.md"
  mkdir -p \
    "$registry_run/plans/plan-implementation/attempt-1" \
    "$registry_run/plans/implement/attempt-1"
  printf '# plan\n- [ ] work\n' >"$sourcep"
  printf '%s\n' '{"schemaVersion":1,"producerStageId":"plan-implementation","producerAttempt":1,"planPath":"'"$sourcep"'","planSha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","todoCount":1,"createdAt":"2026-08-26T15:00:00Z"}' \
    >"$registry_run/plans/plan-implementation/attempt-1/manifest.json"
  # Bind helpers also look for attempt-N.manifest.json
  cp -f "$registry_run/plans/plan-implementation/attempt-1/manifest.json" \
    "$registry_run/plans/plan-implementation/attempt-1.manifest.json"
  cp -f "$sourcep" "$controlp"

  workflow_seq_write_stage \
    --registry-run "$registry_run" --stage-id plan-implementation --state running --attempt 1 \
    --skip-transition-check
  workflow_seq_write_stage \
    --registry-run "$registry_run" --stage-id plan-implementation --state succeeded \
    --terminal-result succeeded \
    --source-plan-path "$sourcep" \
    --attempt 1
  workflow_seq_write_stage \
    --registry-run "$registry_run" --stage-id implement --state running --attempt 1
  workflow_seq_write_stage \
    --registry-run "$registry_run" --stage-id implement --state failed --attempt 1 \
    --plan-path "$controlp" \
    --plan-run-id "implement-run-1" \
    --plan-source-kind generated \
    --plan-source-stage-id plan-implementation \
    --source-plan-path "$sourcep" \
    --control-plan-path "$controlp" \
    --current-todo-id work \
    --completed-todos 0 \
    --total-todos 1
  workflow_seq_update_run --registry-run "$registry_run" --state blocked \
    --owner-json "$(_workflow_seq_null_owner_json)" --skip-transition-check
  workflow_state_clear_owner_and_set_state "$CASE" "$run_id" blocked
  printf '%s\n' "$run_id"
}

seed_sequential_provided_run() {
  local preferred="${1:-}"
  local run_id registry_run sourcep controlp input_path
  mkdir -p "$CASE/inputs"
  printf '%s\n' '---' 'kind: workflow' 'mode: sequential' 'overview: provided' '---' >"$CASE/inputs/wf-seq-prov.md"
  cat >"$CASE/inputs/seq.provided.orch.json" <<'ORCH'
{
  "name": "seq-reset-provided",
  "namespace": "seq-reset-provided",
  "stages": [
    {"id": "implement", "runtime": "cursor"},
    {"id": "approve-plan", "type": "approval", "question": "Approve?", "changesTarget": "implement",
      "inputArtifacts": [{"path": ".ralph-workspace/artifacts/seq-reset/impl.md", "required": true}]}
  ]
}
ORCH
  printf '# plan\n- [ ] work\n' >"$CASE/inputs/seq.provided.source.md"

  if [[ -n "$preferred" ]]; then
    export WORKFLOW_STATE_FIXED_RUN_ID="$preferred"
  else
    unset WORKFLOW_STATE_FIXED_RUN_ID
  fi
  run_id="$(
    workflow_state_create \
      --state-root "$CASE" \
      --source-path "$CASE/inputs/wf-seq-prov.md" \
      --source-kind project \
      --mode sequential \
      --entry-kind task \
      --task "Provided consumer reset" \
      --task-provenance explicit \
      --input-file "$CASE/inputs/seq.provided.orch.json" \
      --workflow-id seq-reset-provided \
      --state failed
  )"
  unset WORKFLOW_STATE_FIXED_RUN_ID
  registry_run="$CASE/workflow-runs/$run_id"
  input_path="$(jq -r '.inputPath' "$registry_run/run.json")"
  export WORKFLOW_SEQ_FIXED_RESET_SUFFIX="abc123"
  workflow_seq_init_engine \
    --registry-run "$registry_run" \
    --input-file "$input_path" \
    --run-id "$run_id" \
    --state failed >/dev/null

  sourcep="$registry_run/plans/implement/attempt-1/source.plan.md"
  controlp="$registry_run/plans/implement/attempt-1/control.plan.md"
  mkdir -p "$registry_run/plans/implement/attempt-1" "$registry_run/plans/input"
  printf '# plan\n- [ ] work\n' >"$sourcep"
  cp -f "$sourcep" "$registry_run/plans/input/source.plan.md"
  cp -f "$sourcep" "$controlp"
  printf '%s\n' '{"schemaVersion":1,"sourceKind":"provided","planPath":"'"$sourcep"'","todoCount":1,"createdAt":"2026-08-26T15:00:00Z"}' \
    >"$registry_run/plans/input/manifest.json"

  workflow_seq_write_stage \
    --registry-run "$registry_run" --stage-id implement --state running --attempt 1 \
    --skip-transition-check
  workflow_seq_write_stage \
    --registry-run "$registry_run" --stage-id implement --state failed --attempt 1 \
    --plan-path "$controlp" \
    --plan-source-kind provided \
    --source-plan-path "$sourcep" \
    --control-plan-path "$controlp" \
    --current-todo-id work \
    --completed-todos 0 \
    --total-todos 1
  workflow_seq_update_run --registry-run "$registry_run" --state failed \
    --owner-json "$(_workflow_seq_null_owner_json)" --skip-transition-check
  workflow_state_clear_owner_and_set_state "$CASE" "$run_id" failed
  printf '%s\n' "$run_id"
}

seed_sequential_parallel_run() {
  local preferred="${1:-}"
  local run_id registry_run input_path
  mkdir -p "$CASE/inputs"
  printf '%s\n' '---' 'kind: workflow' 'mode: sequential' 'overview: parallel' '---' >"$CASE/inputs/wf-seq-par.md"
  write_seq_parallel_orch "$CASE/inputs/seq.parallel.orch.json"

  if [[ -n "$preferred" ]]; then
    export WORKFLOW_STATE_FIXED_RUN_ID="$preferred"
  else
    unset WORKFLOW_STATE_FIXED_RUN_ID
  fi
  run_id="$(
    workflow_state_create \
      --state-root "$CASE" \
      --source-path "$CASE/inputs/wf-seq-par.md" \
      --source-kind project \
      --mode sequential \
      --entry-kind task \
      --task "Parallel wave reset" \
      --task-provenance explicit \
      --input-file "$CASE/inputs/seq.parallel.orch.json" \
      --workflow-id seq-reset-parallel \
      --state blocked
  )"
  unset WORKFLOW_STATE_FIXED_RUN_ID
  registry_run="$CASE/workflow-runs/$run_id"
  input_path="$(jq -r '.inputPath' "$registry_run/run.json")"
  export WORKFLOW_SEQ_FIXED_RESET_SUFFIX="abc123"
  workflow_seq_init_engine \
    --registry-run "$registry_run" \
    --input-file "$input_path" \
    --run-id "$run_id" \
    --state blocked >/dev/null

  # wave-a failed; wave-b succeeded (independent completed wave member); later stages queued
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id wave-a --state running --attempt 1
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id wave-a --state failed --attempt 1
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id wave-b --state running --attempt 1
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id wave-b --state succeeded \
    --terminal-result succeeded --attempt 1
  workflow_seq_update_run --registry-run "$registry_run" --state blocked \
    --completed-waves 0 --owner-json "$(_workflow_seq_null_owner_json)" --skip-transition-check
  workflow_state_clear_owner_and_set_state "$CASE" "$run_id" blocked
  printf '%s\n' "$run_id"
}

@test "Sequential reset primitive plans selected stage plus sequential downstream" {
  local run_id preview
  run_id="$(seed_sequential_planner_run run-seq-reset-plan)"

  run workflow_seq_reset_plan \
    --state-root "$CASE" \
    --run-id "$run_id" \
    --stage plan-implementation \
    --workspace "$FIX_PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  preview="$output"
  [ "$(printf '%s' "$preview" | jq -r '.ok')" = "true" ]
  [ "$(printf '%s' "$preview" | jq -r '.dryRun')" = "true" ]
  [ "$(printf '%s' "$preview" | jq -r '.mode')" = "sequential" ]
  [ "$(printf '%s' "$preview" | jq -r '.stageId')" = "plan-implementation" ]
  [ "$(printf '%s' "$preview" | jq -r '[.stages[].stageId] | join(" ")')" = "plan-implementation implement approve-plan integrate" ]
  [ "$(printf '%s' "$preview" | jq -r '.stages[] | select(.stageId=="plan-implementation") | .planAction')" = "new-planner-attempt" ]
  [ "$(printf '%s' "$preview" | jq -r '.stages[] | select(.stageId=="implement") | .planAction')" = "wait-upstream" ]
  [ "$(printf '%s' "$preview" | jq -r '.stages[] | select(.stageId=="approve-plan") | .action')" = "invalidate" ]
  [ "$(printf '%s' "$preview" | jq -r '.stages[] | select(.stageId=="integrate") | .role')" = "derived-supervisor" ]
}

@test "sequential parallel wave excludes independent completed wave member" {
  local run_id preview
  run_id="$(seed_sequential_parallel_run run-seq-reset-wave)"

  run workflow_seq_reset_plan \
    --state-root "$CASE" --run-id "$run_id" --stage wave-a --workspace "$FIX_PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  preview="$output"
  [ "$(printf '%s' "$preview" | jq -r '[.stages[].stageId] | join(" ")')" = "wave-a join-tail approve-plan" ]
  [ "$(printf '%s' "$preview" | jq -r 'any(.stages[]; .stageId=="wave-b")')" = "false" ]

  # Independent succeeded peer must remain untouched after apply
  run workflow_seq_reset_apply \
    --state-root "$CASE" --run-id "$run_id" --stage wave-a --workspace "$FIX_PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(jq -r '.state' "$CASE/workflow-runs/$run_id/engine/stages/wave-b.json")" = "succeeded" ]
  [ "$(jq -r '.state' "$CASE/workflow-runs/$run_id/engine/stages/wave-a.json")" = "queued" ]
  [ "$(jq -r '.state' "$CASE/workflow-runs/$run_id/engine/stages/join-tail.json")" = "queued" ]
  [ "$(jq -r '.state' "$CASE/workflow-runs/$run_id/run.json")" = "blocked" ]
}

@test "sequential archive preserves immutable sources and sequential dry-run is byte-nonmutating" {
  local run_id registry_run sourcep controlp before after archive
  run_id="$(seed_sequential_planner_run run-seq-reset-dry)"
  registry_run="$CASE/workflow-runs/$run_id"
  sourcep="$registry_run/plans/plan-implementation/attempt-1/source.plan.md"
  controlp="$registry_run/plans/implement/attempt-1/control.plan.md"

  before="$(find "$registry_run" -type f -print0 | sort -z | xargs -0 cksum | cksum)"
  run workflow_seq_reset_plan \
    --state-root "$CASE" --run-id "$run_id" --stage plan-implementation --workspace "$FIX_PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  after="$(find "$registry_run" -type f -print0 | sort -z | xargs -0 cksum | cksum)"
  [ "$before" = "$after" ]

  run workflow_seq_reset_apply \
    --state-root "$CASE" --run-id "$run_id" --stage plan-implementation --workspace "$FIX_PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  archive="$(printf '%s' "$output" | jq -r '.archivePath')"
  [ -d "$archive" ]
  [ -f "$archive/stages/plan-implementation.json" ]
  [ -f "$archive/stages/implement.json" ]
  [ -f "$sourcep" ]
  [ -f "$registry_run/plans/plan-implementation/attempt-1/manifest.json" ]
  [ "$(jq -r '.state' "$registry_run/run.json")" = "blocked" ]
  [ "$(jq -r '.state' "$registry_run/engine/stages/plan-implementation.json")" = "queued" ]
  [ "$(jq -r '.waitingForPlanner // false' "$registry_run/engine/stages/implement.json")" = "true" ]
  [ ! -f "$controlp" ] || [ "$(jq -r '.controlPlanPath // empty' "$registry_run/engine/stages/implement.json")" = "" ]
}

@test "sequential succeeded planner schedules new attempt and provided consumer gets fresh control" {
  local run_id registry_run sourcep controlp new_control
  run_id="$(seed_sequential_planner_run run-seq-reset-planner)"
  registry_run="$CASE/workflow-runs/$run_id"

  run workflow_seq_reset_apply \
    --state-root "$CASE" --run-id "$run_id" --stage plan-implementation --workspace "$FIX_PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(printf '%s' "$output" | jq -r '.stages[] | select(.stageId=="plan-implementation") | .planAction')" = "new-planner-attempt" ]
  [ "$(printf '%s' "$output" | jq -r '.stages[] | select(.stageId=="plan-implementation") | .nextAttempt')" = "2" ]
  [ "$(jq -r '.scheduledPlannerAttempt' "$registry_run/engine/stages/plan-implementation.json")" = "2" ]
  [ "$(jq -r '.waitingForPlanner' "$registry_run/engine/stages/implement.json")" = "true" ]

  run_id="$(seed_sequential_provided_run run-seq-reset-provided)"
  registry_run="$CASE/workflow-runs/$run_id"
  sourcep="$registry_run/plans/implement/attempt-1/source.plan.md"
  controlp="$registry_run/plans/implement/attempt-1/control.plan.md"
  printf 'marker-provided\n' >>"$controlp"

  run workflow_seq_reset_apply \
    --state-root "$CASE" --run-id "$run_id" --stage implement --workspace "$FIX_PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(printf '%s' "$output" | jq -r '.stages[] | select(.stageId=="implement") | .planAction')" = "fresh-control-provided" ]
  new_control="$(jq -r '.controlPlanPath' "$registry_run/engine/stages/implement.json")"
  [ -n "$new_control" ]
  [ -f "$new_control" ]
  [ -f "$sourcep" ]
  ! grep -q 'marker-provided' "$new_control"
  [ "$(cksum "$sourcep" | awk '{print $1}')" = "$(cksum "$new_control" | awk '{print $1}')" ]
  [ "$(jq -r '.state' "$registry_run/engine/stages/implement.json")" = "queued" ]
  [ "$(jq -r '.state' "$registry_run/run.json")" = "blocked" ]
}

@test "sequential human feedback binds once and invalidate approval plus derived supervisor" {
  local run_id registry_run inj
  run_id="$(seed_sequential_planner_run run-seq-reset-feedback)"
  registry_run="$CASE/workflow-runs/$run_id"

  write_approval_request "$registry_run" appr-seq-reset approve-plan
  jq '.changesTarget="plan-implementation"' \
    "$registry_run/actions/requests/appr-seq-reset.json" >"$registry_run/actions/requests/appr-seq-reset.json.tmp"
  mv -f "$registry_run/actions/requests/appr-seq-reset.json.tmp" "$registry_run/actions/requests/appr-seq-reset.json"
  chmod u+w "$registry_run/actions/requests/appr-seq-reset.json" 2>/dev/null || true
  workflow_action_decision_write "$registry_run" "$(jq -nc \
    --arg runId "$run_id" \
    '{requestId:"appr-seq-reset",kind:"approval",runId:$runId,stageId:"approve-plan",attemptId:"approve-plan-1",decision:"request-changes",message:"please regenerate plan",actorSource:"test",decidedAt:"2026-08-26T15:00:00Z"}')" >/dev/null
  workflow_seq_write_stage \
    --registry-run "$registry_run" --stage-id approve-plan --state blocked \
    --blocker-json '{"kind":"approval","requestId":"appr-seq-reset","reasonCode":"human-changes-requested","retryable":false,"changesTarget":"plan-implementation"}' \
    --skip-transition-check

  run workflow_seq_reset_apply \
    --state-root "$CASE" --run-id "$run_id" --stage plan-implementation --workspace "$FIX_PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(printf '%s' "$output" | jq -r '.humanFeedback.requestId')" = "appr-seq-reset" ]
  [ -f "$registry_run/actions/consumed/appr-seq-reset.json" ]
  [ "$(jq -r '.consumer' "$registry_run/actions/consumed/appr-seq-reset.json")" = "reset" ]
  inj="$registry_run/actions/injections/appr-seq-reset.md"
  [ -f "$inj" ]
  grep -q 'OPERATOR_HUMAN_FEEDBACK' "$inj"
  grep -q 'please regenerate plan' "$inj"
  [ "$(jq -r '.state' "$registry_run/engine/stages/approve-plan.json")" = "queued" ]
  [ "$(jq -r '.state' "$registry_run/engine/stages/integrate.json")" = "queued" ]
  [ "$(jq -r '.blocker // null' "$registry_run/engine/stages/approve-plan.json")" = "null" ]
}

@test "sequential unsafe refuses unknown supervisor live-running cancelled and succeeded" {
  local run_id registry_run
  run_id="$(seed_sequential_planner_run run-seq-reset-unsafe)"
  registry_run="$CASE/workflow-runs/$run_id"

  run workflow_seq_reset_plan --state-root "$CASE" --run-id "$run_id" --stage missing-stage --workspace "$FIX_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown stage"* ]]

  run workflow_seq_reset_plan --state-root "$CASE" --run-id "$run_id" --stage approve-plan --workspace "$FIX_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"supervisor"* || "$output" == *"approval"* ]]

  run workflow_seq_reset_plan --state-root "$CASE" --run-id "$run_id" --stage integrate --workspace "$FIX_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"supervisor"* || "$output" == *"integrate"* ]]

  workflow_seq_write_stage --registry-run "$registry_run" --stage-id implement --state running --skip-transition-check
  run workflow_seq_reset_plan --state-root "$CASE" --run-id "$run_id" --stage plan-implementation --workspace "$FIX_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"live-running"* ]]
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id implement --state failed --skip-transition-check

  workflow_state_clear_owner_and_set_state "$CASE" "$run_id" cancelled
  run workflow_seq_reset_plan --state-root "$CASE" --run-id "$run_id" --stage plan-implementation --workspace "$FIX_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cancelled"* || "$output" == *"terminal"* ]]

  run_id="$(seed_sequential_planner_run run-seq-reset-ok)"
  workflow_state_clear_owner_and_set_state "$CASE" "$run_id" succeeded
  run workflow_seq_reset_plan --state-root "$CASE" --run-id "$run_id" --stage plan-implementation --workspace "$FIX_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"succeeded"* || "$output" == *"terminal"* ]]
}

# --- public reset CLI -------------------------------------------------------

@test "reset CLI requires exact ID and rejects latest plan namespace" {
  wf_cli reset
  [ "$status" -eq 2 ]
  [[ "$output" == *"exact-run-id"* ]]

  wf_cli reset latest --yes
  [ "$status" -eq 2 ]
  [[ "$output" == *"exact run id"* ]]

  wf_cli reset run-x --namespace recovery --yes
  [ "$status" -eq 2 ]
  [[ "$output" == *"plan/namespace/node"* ]]
}

@test "reset CLI sole human changesTarget infers stage and prints resume action" {
  local run_id registry_run
  run_id="$(seed_sequential_planner_run run-seq-reset-infer)"
  registry_run="$CASE/workflow-runs/$run_id"

  write_approval_request "$registry_run" appr-cli-infer approve-plan
  jq '.changesTarget="plan-implementation"' \
    "$registry_run/actions/requests/appr-cli-infer.json" >"$registry_run/actions/requests/appr-cli-infer.json.tmp"
  mv -f "$registry_run/actions/requests/appr-cli-infer.json.tmp" "$registry_run/actions/requests/appr-cli-infer.json"
  chmod u+w "$registry_run/actions/requests/appr-cli-infer.json" 2>/dev/null || true
  workflow_action_decision_write "$registry_run" "$(jq -nc \
    --arg runId "$run_id" \
    '{requestId:"appr-cli-infer",kind:"approval",runId:$runId,stageId:"approve-plan",attemptId:"approve-plan-1",decision:"request-changes",message:"redo plan",actorSource:"test",decidedAt:"2026-08-26T15:00:00Z"}')" >/dev/null
  workflow_seq_write_stage \
    --registry-run "$registry_run" --stage-id approve-plan --state blocked \
    --blocker-json '{"kind":"approval","requestId":"appr-cli-infer","reasonCode":"human-changes-requested","retryable":false,"changesTarget":"plan-implementation"}' \
    --skip-transition-check

  wf_cli reset "$run_id" --yes
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"Operation: reset"* ]] || [[ "$output" == *"Reset workflow run"* ]]
  [[ "$output" == *"resume"* ]]
  [[ "$output" == *"confirmed-noninteractive"* ]] || [[ "$output" == *"Reset workflow"* ]]
  [ "$(jq -r '.state' "$registry_run/run.json")" = "blocked" ]
}

@test "reset CLI multiple blockers refuse noninteractive without --stage" {
  local run_id registry_run
  run_id="$(seed_sequential_planner_run run-seq-reset-multi)"
  registry_run="$CASE/workflow-runs/$run_id"

  write_approval_request "$registry_run" appr-a approve-plan
  write_approval_request "$registry_run" appr-b implement
  jq '.changesTarget="plan-implementation"' \
    "$registry_run/actions/requests/appr-a.json" >"$registry_run/actions/requests/appr-a.json.tmp"
  mv -f "$registry_run/actions/requests/appr-a.json.tmp" "$registry_run/actions/requests/appr-a.json"
  jq '.stageId="implement" | .changesTarget="implement"' \
    "$registry_run/actions/requests/appr-b.json" >"$registry_run/actions/requests/appr-b.json.tmp"
  mv -f "$registry_run/actions/requests/appr-b.json.tmp" "$registry_run/actions/requests/appr-b.json"
  workflow_action_decision_write "$registry_run" "$(jq -nc \
    --arg runId "$run_id" \
    '{requestId:"appr-a",kind:"approval",runId:$runId,stageId:"approve-plan",attemptId:"approve-plan-1",decision:"request-changes",message:"a",actorSource:"test",decidedAt:"2026-08-26T15:00:00Z"}')" >/dev/null
  workflow_action_decision_write "$registry_run" "$(jq -nc \
    --arg runId "$run_id" \
    '{requestId:"appr-b",kind:"approval",runId:$runId,stageId:"implement",attemptId:"implement-1",decision:"request-changes",message:"b",actorSource:"test",decidedAt:"2026-08-26T15:00:00Z"}')" >/dev/null
  workflow_seq_write_stage \
    --registry-run "$registry_run" --stage-id approve-plan --state blocked \
    --blocker-json '{"kind":"approval","requestId":"appr-a","reasonCode":"human-changes-requested","retryable":false,"changesTarget":"plan-implementation"}' \
    --skip-transition-check
  workflow_seq_write_stage \
    --registry-run "$registry_run" --stage-id implement --state blocked \
    --blocker-json '{"kind":"approval","requestId":"appr-b","reasonCode":"human-changes-requested","retryable":false,"changesTarget":"implement"}' \
    --skip-transition-check

  wf_cli reset "$run_id" --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"--stage"* ]]
}

@test "reset CLI --stage preview confirmation both modes succeeded planner provided consumer" {
  local run_id registry_run graph_dir sourcep controlp new_control
  run_id="$(seed_sequential_planner_run run-seq-reset-cli-stage)"
  registry_run="$CASE/workflow-runs/$run_id"

  wf_cli reset "$run_id" --stage plan-implementation --dry-run
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"Operation: reset"* ]]
  [[ "$output" == *"Dry run complete"* ]]
  [[ "$output" == *"new-planner-attempt"* || "$output" == *"plan=new-planner-attempt"* ]]

  wf_cli reset "$run_id" --stage plan-implementation --yes
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(jq -r '.scheduledPlannerAttempt' "$registry_run/engine/stages/plan-implementation.json")" = "2" ]

  run_id="$(seed_sequential_provided_run run-seq-reset-cli-prov)"
  registry_run="$CASE/workflow-runs/$run_id"
  controlp="$registry_run/plans/implement/attempt-1/control.plan.md"
  printf 'marker\n' >>"$controlp"
  wf_cli reset "$run_id" --stage implement --yes
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  new_control="$(jq -r '.controlPlanPath' "$registry_run/engine/stages/implement.json")"
  [ -f "$new_control" ]
  ! grep -q 'marker' "$new_control"

  run_id="$(seed_dependency_planner_run run-dep-reset-cli-stage)"
  registry_run="$CASE/workflow-runs/$run_id"
  graph_dir="$CASE/graph-runs/recovery/$run_id"
  wf_cli reset "$run_id" --stage plan-implementation --yes
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(jq -r '.scheduledPlannerAttempt' "$graph_dir/nodes/plan-implementation.json")" = "2" ]

  run_id="$(seed_dependency_run run-dep-reset-cli-prov)"
  registry_run="$CASE/workflow-runs/$run_id"
  graph_dir="$CASE/graph-runs/recovery/$run_id"
  sourcep="$registry_run/plans/implement/attempt-1/source.plan.md"
  controlp="$registry_run/plans/implement/attempt-1/control.plan.md"
  workflow_state_clear_owner_and_set_state "$CASE" "$run_id" failed
  jq '.status="failed"' "$graph_dir/nodes/implement.json" >"$graph_dir/nodes/implement.json.tmp"
  mv -f "$graph_dir/nodes/implement.json.tmp" "$graph_dir/nodes/implement.json"
  printf 'marker\n' >>"$controlp"
  wf_cli reset "$run_id" --stage implement --yes
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  new_control="$(jq -r '.controlPlanPath' "$graph_dir/nodes/implement.json")"
  [ -f "$new_control" ]
  ! grep -q 'marker' "$new_control"
  [ -f "$sourcep" ]
}

@test "reset CLI --all invalidates derived supervisor and actions" {
  local run_id registry_run graph_dir
  run_id="$(seed_sequential_planner_run run-seq-reset-all)"
  registry_run="$CASE/workflow-runs/$run_id"
  write_approval_request "$registry_run" appr-all approve-plan

  wf_cli reset "$run_id" --all --dry-run
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"Selection: all executable/planner stages"* ]]
  [[ "$output" == *"integrate"* ]]
  [[ "$output" == *"derived-supervisor"* || "$output" == *"invalidate"* ]]

  wf_cli reset "$run_id" --all --yes
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ ! -f "$registry_run/actions/requests/appr-all.json" ]
  [ "$(jq -r '.state' "$registry_run/engine/stages/integrate.json")" = "queued" ]
}

@test "reset CLI human feedback invalidate actions derived supervisor preview" {
  local run_id registry_run inj
  run_id="$(seed_sequential_planner_run run-seq-reset-cli-fb)"
  registry_run="$CASE/workflow-runs/$run_id"

  write_approval_request "$registry_run" appr-cli-fb approve-plan
  jq '.changesTarget="plan-implementation"' \
    "$registry_run/actions/requests/appr-cli-fb.json" >"$registry_run/actions/requests/appr-cli-fb.json.tmp"
  mv -f "$registry_run/actions/requests/appr-cli-fb.json.tmp" "$registry_run/actions/requests/appr-cli-fb.json"
  workflow_action_decision_write "$registry_run" "$(jq -nc \
    --arg runId "$run_id" \
    '{requestId:"appr-cli-fb",kind:"approval",runId:$runId,stageId:"approve-plan",attemptId:"approve-plan-1",decision:"request-changes",message:"please regenerate plan",actorSource:"test",decidedAt:"2026-08-26T15:00:00Z"}')" >/dev/null
  workflow_seq_write_stage \
    --registry-run "$registry_run" --stage-id approve-plan --state blocked \
    --blocker-json '{"kind":"approval","requestId":"appr-cli-fb","reasonCode":"human-changes-requested","retryable":false,"changesTarget":"plan-implementation"}' \
    --skip-transition-check

  wf_cli reset "$run_id" --stage plan-implementation --dry-run
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"Human feedback"* ]]
  [[ "$output" == *"please regenerate plan"* ]]

  wf_cli reset "$run_id" --stage plan-implementation --yes
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -f "$registry_run/actions/consumed/appr-cli-fb.json" ]
  inj="$registry_run/actions/injections/appr-cli-fb.md"
  [ -f "$inj" ]
  grep -q 'OPERATOR_HUMAN_FEEDBACK' "$inj"
  [ "$(jq -r '.state' "$registry_run/engine/stages/approve-plan.json")" = "queued" ]
  [ "$(jq -r '.state' "$registry_run/engine/stages/integrate.json")" = "queued" ]
}

@test "reset CLI refuses live-running terminal run and unknown stage" {
  local run_id registry_run graph_dir
  run_id="$(seed_sequential_planner_run run-seq-reset-live)"
  registry_run="$CASE/workflow-runs/$run_id"
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id implement --state running --skip-transition-check
  wf_cli reset "$run_id" --stage plan-implementation --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"live-running"* ]]
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id implement --state failed --skip-transition-check

  run_id="$(seed_sequential_planner_run run-seq-reset-term)"
  workflow_state_clear_owner_and_set_state "$CASE" "$run_id" succeeded
  wf_cli reset "$run_id" --stage plan-implementation --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"terminal"* || "$output" == *"succeeded"* ]]

  run_id="$(seed_sequential_planner_run run-seq-reset-unknown)"
  wf_cli reset "$run_id" --stage missing-stage --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown stage"* ]]

  run_id="$(seed_dependency_planner_run run-dep-reset-live)"
  graph_dir="$CASE/graph-runs/recovery/$run_id"
  jq '.status="running"' "$graph_dir/nodes/implement.json" >"$graph_dir/nodes/implement.json.tmp"
  mv -f "$graph_dir/nodes/implement.json.tmp" "$graph_dir/nodes/implement.json"
  wf_cli reset "$run_id" --stage plan-implementation --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"live-running"* ]]
}


# --- Dependency recover / cancel primitives ---------------------------------

# mark_dependency_graph_stale <graph-dir> [node-id]
# Force a proven-stale supervisor: expired heartbeat + dead pid + start id.
mark_dependency_graph_stale() {
  local graph_dir="$1" node_id="${2:-implement}"
  local node_file="$graph_dir/nodes/${node_id}.json"
  jq '.status="running"
      | .heartbeatAt="2026-08-12T00:00:00Z"
      | .supervisorPid=999999
      | .ownerProcessStartId="old-start"
      | .ownerHostname="test-host"' \
    "$graph_dir/run.json" >"$graph_dir/run.json.tmp"
  mv -f "$graph_dir/run.json.tmp" "$graph_dir/run.json"
  jq --arg nid "$node_id" --arg aid "${node_id}-1" '
      .status="running"
      | .nodeId=$nid
      | .lastAttemptId=$aid
      | .attempts=[{attemptId:$aid,startedAt:"2026-08-26T10:00:00Z"}]
    ' "$node_file" >"${node_file}.tmp"
  mv -f "${node_file}.tmp" "$node_file"
}

# mark_dependency_graph_live_owned <graph-dir> <pid> <start-id> [hostname]
mark_dependency_graph_live_owned() {
  local graph_dir="$1" pid="$2" start_id="$3"
  local host="${4:-}"
  if [[ -z "$host" ]]; then
    host="$(graph_state_owner_hostname 2>/dev/null || hostname)"
  fi
  jq --argjson pid "$pid" --arg start "$start_id" --arg host "$host" '
      .status="running"
      | .heartbeatAt="2099-01-01T00:00:00Z"
      | .supervisorPid=$pid
      | .ownerProcessStartId=$start
      | .ownerHostname=$host
    ' "$graph_dir/run.json" >"$graph_dir/run.json.tmp"
  mv -f "$graph_dir/run.json.tmp" "$graph_dir/run.json"
}

write_capability_file() {
  local registry_run="$1" run_id="$2" stage_id="$3" attempt_id="$4"
  mkdir -p "$registry_run/actions/capabilities"
  jq -n --arg runId "$run_id" --arg stageId "$stage_id" --arg attemptId "$attempt_id" \
    '{runId:$runId,stageId:$stageId,attemptId:$attemptId,nonce:"test-nonce"}' \
    >"$registry_run/actions/capabilities/${stage_id}-${attempt_id}.json"
}

@test "Dependency recover primitive dry-run previews stale recovery without mutation" {
  local run_id registry_run graph_dir before after
  run_id="$(seed_dependency_run run-dep-recover-prim)"
  registry_run="$CASE/workflow-runs/$run_id"
  graph_dir="$CASE/graph-runs/recovery/$run_id"
  mark_dependency_graph_stale "$graph_dir"
  workflow_state_update "$CASE" "$run_id" '.state="running"'

  before="$(find "$registry_run" "$graph_dir" -type f -print0 | sort -z | xargs -0 cksum | cksum)"
  GRAPH_HEARTBEAT_TTL_SECONDS=1 GRAPH_HEARTBEAT_NOW_EPOCH=1999999999 \
    run workflow_dep_recover --state-root "$CASE" --run-id "$run_id" --workspace "$FIX_PROJECT" --dry-run
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(printf '%s' "$output" | jq -r '.ok')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.dryRun')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.mode')" = "dependency" ]
  after="$(find "$registry_run" "$graph_dir" -type f -print0 | sort -z | xargs -0 cksum | cksum)"
  [ "$before" = "$after" ]
}

@test "dependency stale supervisor recover reconciles and returns retryable stages" {
  local run_id registry_run graph_dir
  run_id="$(seed_dependency_run run-dep-stale)"
  registry_run="$CASE/workflow-runs/$run_id"
  graph_dir="$CASE/graph-runs/recovery/$run_id"
  mark_dependency_graph_stale "$graph_dir"
  workflow_state_update "$CASE" "$run_id" '.state="running"'

  GRAPH_HEARTBEAT_TTL_SECONDS=1 GRAPH_HEARTBEAT_NOW_EPOCH=1999999999 \
    run workflow_dep_recover --state-root "$CASE" --run-id "$run_id" --workspace "$FIX_PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(printf '%s' "$output" | jq -r '.ok')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.mutated')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.autoReran')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.manufacturedDecision')" = "false" ]
  [ "$(jq -r '.state' "$registry_run/run.json")" = "blocked" ]
  [ "$(jq -r '.supervisorPid' "$graph_dir/run.json")" = "null" ]
  # Interrupted node reset to pending by graph recovery rules
  [ "$(jq -r '.status' "$graph_dir/nodes/implement.json")" = "pending" ]
  [ "$(printf '%s' "$output" | jq -r '[.retryableStages[].stageId] | index("implement") != null')" = "true" ]
}

@test "dependency orphan interrupted attempt recover without auto-rerun" {
  local run_id registry_run graph_dir
  run_id="$(seed_dependency_run run-dep-orphan)"
  registry_run="$CASE/workflow-runs/$run_id"
  graph_dir="$CASE/graph-runs/recovery/$run_id"
  # Already interrupted, no owner: orphaned attempt path (not intentional wait).
  jq '.status="interrupted" | .supervisorPid=null | .heartbeatAt=null | .ownerProcessStartId=null' \
    "$graph_dir/run.json" >"$graph_dir/run.json.tmp"
  mv -f "$graph_dir/run.json.tmp" "$graph_dir/run.json"
  jq '.status="interrupted" | .lastAttemptId="implement-1"' \
    "$graph_dir/nodes/implement.json" >"$graph_dir/nodes/implement.json.tmp"
  mv -f "$graph_dir/nodes/implement.json.tmp" "$graph_dir/nodes/implement.json"
  workflow_state_clear_owner_and_set_state "$CASE" "$run_id" stale

  run workflow_dep_recover --state-root "$CASE" --run-id "$run_id" --workspace "$FIX_PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(printf '%s' "$output" | jq -r '.outcome')" = "recovered-orphaned-or-interrupted" ]
  [ "$(printf '%s' "$output" | jq -r '.autoReran')" = "false" ]
  [ "$(jq -r '.status' "$graph_dir/nodes/implement.json")" = "pending" ]
  [ "$(jq -r '.state' "$registry_run/run.json")" = "blocked" ]
}

@test "intentional action wait recover returns unchanged with next actions command" {
  local run_id registry_run graph_dir before after
  run_id="$(seed_dependency_run run-dep-intentional-wait)"
  registry_run="$CASE/workflow-runs/$run_id"
  graph_dir="$CASE/graph-runs/recovery/$run_id"
  write_approval_request "$registry_run" appr-wait approve-plan
  jq '.status="awaiting-operator" | .blocker={kind:"approval",requestId:"appr-wait",reasonCode:"human-approval",retryable:false,changesTarget:"implement"}' \
    "$graph_dir/nodes/approve-plan.json" >"$graph_dir/nodes/approve-plan.json.tmp"
  mv -f "$graph_dir/nodes/approve-plan.json.tmp" "$graph_dir/nodes/approve-plan.json"
  workflow_state_clear_owner_and_set_state "$CASE" "$run_id" waiting

  before="$(cksum "$registry_run/actions/requests/appr-wait.json" "$graph_dir/run.json" "$registry_run/run.json")"
  run workflow_dep_recover --state-root "$CASE" --run-id "$run_id" --workspace "$FIX_PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(printf '%s' "$output" | jq -r '.outcome')" = "unchanged-intentional-wait" ]
  [ "$(printf '%s' "$output" | jq -r '.mutated')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.outstanding.requestId')" = "appr-wait" ]
  [ "$(printf '%s' "$output" | jq -r '.nextAction.argv | join(" ")')" = "ralph workflow actions list $run_id" ]
  after="$(cksum "$registry_run/actions/requests/appr-wait.json" "$graph_dir/run.json" "$registry_run/run.json")"
  [ "$before" = "$after" ]
}

@test "preserve action records across dependency stale recover" {
  local run_id registry_run graph_dir
  run_id="$(seed_dependency_run run-dep-preserve-actions)"
  registry_run="$CASE/workflow-runs/$run_id"
  graph_dir="$CASE/graph-runs/recovery/$run_id"
  mark_dependency_graph_stale "$graph_dir"
  workflow_state_update "$CASE" "$run_id" '.state="running"'
  write_input_request "$registry_run" inp-keep implement
  workflow_action_decision_write "$registry_run" "$(jq -nc --arg runId "$run_id" \
    '{requestId:"inp-keep",kind:"input",runId:$runId,stageId:"implement",attemptId:"implement-1",decision:"answer",message:"keep",actorSource:"test",decidedAt:"2026-08-26T15:00:00Z"}')" >/dev/null
  workflow_action_consume_once "$registry_run" inp-keep resume >/dev/null || true
  [ -f "$registry_run/actions/requests/inp-keep.json" ]
  [ -f "$registry_run/actions/decisions/inp-keep.json" ]
  [ -f "$registry_run/actions/consumed/inp-keep.json" ]

  GRAPH_HEARTBEAT_TTL_SECONDS=1 GRAPH_HEARTBEAT_NOW_EPOCH=1999999999 \
    run workflow_dep_recover --state-root "$CASE" --run-id "$run_id" --workspace "$FIX_PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -f "$registry_run/actions/requests/inp-keep.json" ]
  [ -f "$registry_run/actions/decisions/inp-keep.json" ]
  [ -f "$registry_run/actions/consumed/inp-keep.json" ]
}

@test "capability revoked on dependency recover of interrupted attempt" {
  local run_id registry_run graph_dir
  run_id="$(seed_dependency_run run-dep-cap-revoked)"
  registry_run="$CASE/workflow-runs/$run_id"
  graph_dir="$CASE/graph-runs/recovery/$run_id"
  jq '.status="interrupted" | .supervisorPid=null | .heartbeatAt=null' \
    "$graph_dir/run.json" >"$graph_dir/run.json.tmp"
  mv -f "$graph_dir/run.json.tmp" "$graph_dir/run.json"
  jq '.status="interrupted" | .lastAttemptId="implement-1"' \
    "$graph_dir/nodes/implement.json" >"$graph_dir/nodes/implement.json.tmp"
  mv -f "$graph_dir/nodes/implement.json.tmp" "$graph_dir/nodes/implement.json"
  write_capability_file "$registry_run" "$run_id" implement implement-1
  [ -f "$registry_run/actions/capabilities/implement-implement-1.json" ]
  workflow_state_clear_owner_and_set_state "$CASE" "$run_id" stale

  run workflow_dep_recover --state-root "$CASE" --run-id "$run_id" --workspace "$FIX_PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ ! -f "$registry_run/actions/capabilities/implement-implement-1.json" ]
}

@test "dependency reject live recover and unknown run" {
  local run_id registry_run graph_dir start_id
  use_deterministic_process_start_probe
  run_id="$(seed_dependency_run run-dep-reject-live)"
  registry_run="$CASE/workflow-runs/$run_id"
  graph_dir="$CASE/graph-runs/recovery/$run_id"
  start_id="$(graph_heartbeat_process_start_id_of_pid "$$")"
  mark_dependency_graph_live_owned "$graph_dir" "$$" "$start_id"
  workflow_state_update "$CASE" "$run_id" '.state="running"'

  run workflow_dep_recover --state-root "$CASE" --run-id "$run_id" --workspace "$FIX_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"live"* || "$output" == *"refuses"* ]]

  run workflow_dep_recover --state-root "$CASE" --run-id "run-does-not-exist" --workspace "$FIX_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown"* ]]
}

@test "dependency cancel live owned supervisor after cancel intent" {
  local run_id registry_run graph_dir victim start_id
  use_deterministic_process_start_probe
  run_id="$(seed_dependency_run run-dep-cancel-live)"
  registry_run="$CASE/workflow-runs/$run_id"
  graph_dir="$CASE/graph-runs/recovery/$run_id"
  # Background victim: do not wait on its sleep duration.
  sleep 120 &
  victim=$!
  start_id="$(graph_heartbeat_process_start_id_of_pid "$victim")"
  host="$(graph_state_owner_hostname 2>/dev/null || hostname)"
  mark_dependency_graph_live_owned "$graph_dir" "$victim" "$start_id" "$host"
  workflow_state_update "$CASE" "$run_id" \
    '.state = "running" | .owner = {pid:$pid,hostname:$host,processStartId:$start,heartbeatAt:"2099-01-01T00:00:00Z"}' \
    --argjson pid "$victim" --arg start "$start_id" --arg host "$host"
  write_input_request "$registry_run" inp-cancel-me implement

  run workflow_dep_cancel --state-root "$CASE" --run-id "$run_id" --workspace "$FIX_PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(printf '%s' "$output" | jq -r '.outcome')" = "cancelled" ] || { echo "$output"; return 1; }
  [ "$(jq -r '.state' "$registry_run/run.json")" = "cancelled" ]
  [ "$(jq -r '.status' "$graph_dir/run.json")" = "cancelled" ]
  [ -f "$registry_run/actions/cancel-intent.json" ]
  # Outstanding action cancelled without deletion
  [ -f "$registry_run/actions/requests/inp-cancel-me.json" ]
  [ -f "$registry_run/actions/decisions/inp-cancel-me.json" ]
  [ "$(jq -r '.decision' "$registry_run/actions/decisions/inp-cancel-me.json")" = "cancel" ]
  # Victim should be gone (TERM/KILL). Do not sleep for the victim duration.
  if kill -0 "$victim" 2>/dev/null; then
    kill -KILL "$victim" 2>/dev/null || true
    wait "$victim" 2>/dev/null || true
    echo "victim still alive after cancel" >&2
    return 1
  fi
  wait "$victim" 2>/dev/null || true
}

@test "dependency cancel non-running waiting run and dependency ownership foreign refuse" {
  local run_id registry_run graph_dir victim start_id
  use_deterministic_process_start_probe
  run_id="$(seed_dependency_run run-dep-cancel-waiting)"
  registry_run="$CASE/workflow-runs/$run_id"
  graph_dir="$CASE/graph-runs/recovery/$run_id"
  workflow_state_clear_owner_and_set_state "$CASE" "$run_id" waiting
  write_approval_request "$registry_run" appr-cancel approve-plan

  run workflow_dep_cancel --state-root "$CASE" --run-id "$run_id" --workspace "$FIX_PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(jq -r '.state' "$registry_run/run.json")" = "cancelled" ]
  [ -f "$registry_run/actions/requests/appr-cancel.json" ]
  [ -f "$registry_run/actions/decisions/appr-cancel.json" ]
  [ "$(jq -r '.decision' "$registry_run/actions/decisions/appr-cancel.json")" = "cancel" ]

  # Ownership: healthy heartbeat on foreign hostname must refuse cancel.
  run_id="$(seed_dependency_run run-dep-cancel-foreign)"
  registry_run="$CASE/workflow-runs/$run_id"
  graph_dir="$CASE/graph-runs/recovery/$run_id"
  sleep 120 &
  victim=$!
  start_id="$(graph_heartbeat_process_start_id_of_pid "$victim")"
  mark_dependency_graph_live_owned "$graph_dir" "$victim" "$start_id" "other-host.example"
  workflow_state_update "$CASE" "$run_id" '.state="running"'

  run workflow_dep_cancel --state-root "$CASE" --run-id "$run_id" --workspace "$FIX_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ownership"* || "$output" == *"foreign"* || "$output" == *"ambiguous"* || "$output" == *"refuses"* ]]
  kill -KILL "$victim" 2>/dev/null || true
  wait "$victim" 2>/dev/null || true
}


# --- Sequential recover / cancel primitives ---------------------------------

# The sandboxed macOS test host may prohibit `ps` even for the current process.
# Recovery ownership tests need controlled process-start evidence, not host
# process-table permissions. Each Bats test has an isolated shell, so this
# override cannot leak into dedicated unavailable-inspection cases.
use_deterministic_process_start_probe() {
  graph_heartbeat_process_start_id_of_pid() {
    local pid="$1"
    [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null || return 1
    printf 'test-start:%s\n' "$pid"
  }
}

# mark_sequential_engine_stale <registry-run> [stage-id]
# Force a proven-stale supervisor: expired heartbeat + dead pid + start id.
# Optionally leaves <stage-id> running so recover marks it stale/retryable.
mark_sequential_engine_stale() {
  local registry_run="$1" stage_id="${2:-investigate}"
  local engine="$registry_run/engine/run.json"
  local stage_file="$registry_run/engine/stages/${stage_id}.json"
  jq '.state="running"
      | .owner={pid:999999,hostname:"test-host",processStartId:"old-start",heartbeatAt:"2026-08-12T00:00:00Z"}
      | .currentStageIds=[$sid]
      | .loopIterations=2
      | .completedWaves=1' \
    --arg sid "$stage_id" \
    "$engine" >"$engine.tmp"
  mv -f "$engine.tmp" "$engine"
  jq --arg sid "$stage_id" '
      .state="running"
      | .id=$sid
      | .attempt=1
    ' "$stage_file" >"${stage_file}.tmp"
  mv -f "${stage_file}.tmp" "$stage_file"
}

# mark_sequential_engine_live_owned <registry-run> <pid> <start-id> [hostname]
mark_sequential_engine_live_owned() {
  local registry_run="$1" pid="$2" start_id="$3"
  local host="${4:-}"
  local engine="$registry_run/engine/run.json"
  if [[ -z "$host" ]]; then
    host="$(graph_state_owner_hostname 2>/dev/null || hostname)"
  fi
  jq --argjson pid "$pid" --arg start "$start_id" --arg host "$host" '
      .state="running"
      | .owner={pid:$pid,hostname:$host,processStartId:$start,heartbeatAt:"2099-01-01T00:00:00Z"}
      | .currentStageIds=["investigate"]
    ' "$engine" >"$engine.tmp"
  mv -f "$engine.tmp" "$engine"
}

@test "Sequential recover primitive dry-run previews stale recovery without mutation" {
  local run_id registry_run before after
  run_id="$(seed_sequential_run run-seq-recover-prim)"
  registry_run="$CASE/workflow-runs/$run_id"
  mark_sequential_engine_stale "$registry_run"
  workflow_state_update "$CASE" "$run_id" '.state="running"'

  before="$(find "$registry_run" -type f -print0 | sort -z | xargs -0 cksum | cksum)"
  WORKFLOW_SEQ_OWNER_TTL_SECONDS=1 WORKFLOW_SEQ_OWNER_NOW_EPOCH=1999999999 \
    run workflow_seq_recover --state-root "$CASE" --run-id "$run_id" --workspace "$FIX_PROJECT" --dry-run
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(printf '%s' "$output" | jq -r '.ok')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.dryRun')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.mode')" = "sequential" ]
  after="$(find "$registry_run" -type f -print0 | sort -z | xargs -0 cksum | cksum)"
  [ "$before" = "$after" ]
}

@test "sequential stale supervisor recover marks running stages stale and preserves wave loop" {
  local run_id registry_run
  run_id="$(seed_sequential_run run-seq-stale)"
  registry_run="$CASE/workflow-runs/$run_id"
  mark_sequential_engine_stale "$registry_run"
  workflow_state_update "$CASE" "$run_id" '.state="running"'

  WORKFLOW_SEQ_OWNER_TTL_SECONDS=1 WORKFLOW_SEQ_OWNER_NOW_EPOCH=1999999999 \
    run workflow_seq_recover --state-root "$CASE" --run-id "$run_id" --workspace "$FIX_PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(printf '%s' "$output" | jq -r '.ok')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.mutated')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.autoReran')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.manufacturedDecision')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.loopIterations')" = "2" ]
  [ "$(printf '%s' "$output" | jq -r '.completedWaves')" = "1" ]
  [ "$(jq -r '.state' "$registry_run/run.json")" = "blocked" ]
  [ "$(jq -r '.owner.pid' "$registry_run/engine/run.json")" = "null" ]
  [ "$(jq -r '.loopIterations' "$registry_run/engine/run.json")" = "2" ]
  [ "$(jq -r '.completedWaves' "$registry_run/engine/run.json")" = "1" ]
  [ "$(jq -r '.state' "$registry_run/engine/stages/investigate.json")" = "stale" ]
  [ "$(printf '%s' "$output" | jq -r '[.retryableStages[].stageId] | index("investigate") != null')" = "true" ]
}

@test "sequential PID reuse with mismatched processStartId is stale not live" {
  local run_id registry_run live_start
  use_deterministic_process_start_probe
  run_id="$(seed_sequential_run run-seq-pid-reuse)"
  registry_run="$CASE/workflow-runs/$run_id"
  live_start="$(graph_heartbeat_process_start_id_of_pid "$$")"
  # Live PID, expired heartbeat, WRONG start id => PID reuse => stale.
  jq --argjson pid "$$" --arg bad "old-reused-start" --arg good "$live_start" '
      .state="running"
      | .owner={pid:$pid,hostname:"test-host",processStartId:$bad,heartbeatAt:"2026-08-12T00:00:00Z"}
      | .currentStageIds=["investigate"]
      | .loopIterations=1
      | .completedWaves=0
    ' "$registry_run/engine/run.json" >"$registry_run/engine/run.json.tmp"
  mv -f "$registry_run/engine/run.json.tmp" "$registry_run/engine/run.json"
  jq '.state="running" | .attempt=1' \
    "$registry_run/engine/stages/investigate.json" >"$registry_run/engine/stages/investigate.json.tmp"
  mv -f "$registry_run/engine/stages/investigate.json.tmp" "$registry_run/engine/stages/investigate.json"
  workflow_state_update "$CASE" "$run_id" '.state="running"'

  # Classifier must report stale (never trust PID alone).
  owner="$(jq -c '.owner' "$registry_run/engine/run.json")"
  class="$(WORKFLOW_SEQ_OWNER_TTL_SECONDS=1 WORKFLOW_SEQ_OWNER_NOW_EPOCH=1999999999 \
    workflow_seq_classify_owner_json "$owner")"
  [ "$class" = "stale" ]
  # Good start id with fresh heartbeat would be healthy — prove the mismatch path.
  [ "$live_start" != "old-reused-start" ]

  WORKFLOW_SEQ_OWNER_TTL_SECONDS=1 WORKFLOW_SEQ_OWNER_NOW_EPOCH=1999999999 \
    run workflow_seq_recover --state-root "$CASE" --run-id "$run_id" --workspace "$FIX_PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(printf '%s' "$output" | jq -r '.ownerClass')" = "stale" ]
  [ "$(jq -r '.state' "$registry_run/engine/stages/investigate.json")" = "stale" ]
}

@test "sequential hostname foreign cancel refuses ownership" {
  local run_id registry_run victim start_id
  use_deterministic_process_start_probe
  run_id="$(seed_sequential_run run-seq-hostname-foreign)"
  registry_run="$CASE/workflow-runs/$run_id"
  sleep 120 &
  victim=$!
  start_id="$(graph_heartbeat_process_start_id_of_pid "$victim")"
  mark_sequential_engine_live_owned "$registry_run" "$victim" "$start_id" "other-host.example"
  workflow_state_update "$CASE" "$run_id" '.state="running"'

  run workflow_seq_cancel --state-root "$CASE" --run-id "$run_id" --workspace "$FIX_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ownership"* || "$output" == *"foreign"* || "$output" == *"ambiguous"* || "$output" == *"refuses"* ]]
  kill -KILL "$victim" 2>/dev/null || true
  wait "$victim" 2>/dev/null || true
}

@test "intentional action wait sequential recover returns unchanged with next actions command" {
  local run_id registry_run before after
  run_id="$(seed_sequential_run run-seq-intentional-wait)"
  registry_run="$CASE/workflow-runs/$run_id"
  write_approval_request "$registry_run" appr-seq-wait approve-plan
  workflow_seq_update_run \
    --registry-run "$registry_run" \
    --state waiting \
    --owner-json "$(_workflow_seq_null_owner_json)" \
    --skip-transition-check || true
  workflow_state_clear_owner_and_set_state "$CASE" "$run_id" waiting

  before="$(cksum "$registry_run/actions/requests/appr-seq-wait.json" "$registry_run/engine/run.json" "$registry_run/run.json")"
  run workflow_seq_recover --state-root "$CASE" --run-id "$run_id" --workspace "$FIX_PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(printf '%s' "$output" | jq -r '.outcome')" = "unchanged-intentional-wait" ]
  [ "$(printf '%s' "$output" | jq -r '.mutated')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.outstanding.requestId')" = "appr-seq-wait" ]
  [ "$(printf '%s' "$output" | jq -r '.nextAction.argv | join(" ")')" = "ralph workflow actions list $run_id" ]
  after="$(cksum "$registry_run/actions/requests/appr-seq-wait.json" "$registry_run/engine/run.json" "$registry_run/run.json")"
  [ "$before" = "$after" ]
}

@test "preserve action records across sequential stale recover" {
  local run_id registry_run
  run_id="$(seed_sequential_run run-seq-preserve-actions)"
  registry_run="$CASE/workflow-runs/$run_id"
  mark_sequential_engine_stale "$registry_run"
  workflow_state_update "$CASE" "$run_id" '.state="running"'
  write_input_request "$registry_run" inp-seq-keep investigate
  workflow_action_decision_write "$registry_run" "$(jq -nc --arg runId "$run_id" \
    '{requestId:"inp-seq-keep",kind:"input",runId:$runId,stageId:"investigate",attemptId:"investigate-1",decision:"answer",message:"keep",actorSource:"test",decidedAt:"2026-08-26T15:00:00Z"}')" >/dev/null
  workflow_action_consume_once "$registry_run" inp-seq-keep resume >/dev/null || true
  [ -f "$registry_run/actions/requests/inp-seq-keep.json" ]
  [ -f "$registry_run/actions/decisions/inp-seq-keep.json" ]
  [ -f "$registry_run/actions/consumed/inp-seq-keep.json" ]

  WORKFLOW_SEQ_OWNER_TTL_SECONDS=1 WORKFLOW_SEQ_OWNER_NOW_EPOCH=1999999999 \
    run workflow_seq_recover --state-root "$CASE" --run-id "$run_id" --workspace "$FIX_PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -f "$registry_run/actions/requests/inp-seq-keep.json" ]
  [ -f "$registry_run/actions/decisions/inp-seq-keep.json" ]
  [ -f "$registry_run/actions/consumed/inp-seq-keep.json" ]
}

@test "capability revoked on sequential recover of interrupted attempt" {
  local run_id registry_run
  run_id="$(seed_sequential_run run-seq-cap-revoked)"
  registry_run="$CASE/workflow-runs/$run_id"
  mark_sequential_engine_stale "$registry_run"
  jq '.attempt=1' "$registry_run/engine/stages/investigate.json" >"$registry_run/engine/stages/investigate.json.tmp"
  mv -f "$registry_run/engine/stages/investigate.json.tmp" "$registry_run/engine/stages/investigate.json"
  write_capability_file "$registry_run" "$run_id" investigate 1
  [ -f "$registry_run/actions/capabilities/investigate-1.json" ]
  workflow_state_update "$CASE" "$run_id" '.state="running"'

  WORKFLOW_SEQ_OWNER_TTL_SECONDS=1 WORKFLOW_SEQ_OWNER_NOW_EPOCH=1999999999 \
    run workflow_seq_recover --state-root "$CASE" --run-id "$run_id" --workspace "$FIX_PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ ! -f "$registry_run/actions/capabilities/investigate-1.json" ]
}

@test "sequential reject live recover and unknown run" {
  local run_id registry_run start_id
  use_deterministic_process_start_probe
  run_id="$(seed_sequential_run run-seq-reject-live)"
  registry_run="$CASE/workflow-runs/$run_id"
  start_id="$(graph_heartbeat_process_start_id_of_pid "$$")"
  mark_sequential_engine_live_owned "$registry_run" "$$" "$start_id"
  workflow_state_update "$CASE" "$run_id" \
    '.state = "running" | .owner = {pid:$pid,hostname:$host,processStartId:$start,heartbeatAt:"2099-01-01T00:00:00Z"}' \
    --argjson pid "$$" --arg start "$start_id" --arg host "$(graph_state_owner_hostname 2>/dev/null || hostname)"

  run workflow_seq_recover --state-root "$CASE" --run-id "$run_id" --workspace "$FIX_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"live"* || "$output" == *"refuses"* ]]

  run workflow_seq_recover --state-root "$CASE" --run-id "run-does-not-exist" --workspace "$FIX_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown"* ]]
}

@test "sequential cancel live owned supervisor after cancel intent with TERM" {
  local run_id registry_run victim start_id host
  use_deterministic_process_start_probe
  run_id="$(seed_sequential_run run-seq-cancel-live)"
  registry_run="$CASE/workflow-runs/$run_id"
  # Background victim: do not wait on its sleep duration.
  sleep 120 &
  victim=$!
  start_id="$(graph_heartbeat_process_start_id_of_pid "$victim")"
  host="$(graph_state_owner_hostname 2>/dev/null || hostname)"
  mark_sequential_engine_live_owned "$registry_run" "$victim" "$start_id" "$host"
  workflow_state_update "$CASE" "$run_id" \
    '.state = "running" | .owner = {pid:$pid,hostname:$host,processStartId:$start,heartbeatAt:"2099-01-01T00:00:00Z"}' \
    --argjson pid "$victim" --arg start "$start_id" --arg host "$host"
  write_input_request "$registry_run" inp-seq-cancel-me investigate

  run workflow_seq_cancel --state-root "$CASE" --run-id "$run_id" --workspace "$FIX_PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(printf '%s' "$output" | jq -r '.outcome')" = "cancelled" ] || { echo "$output"; return 1; }
  [ "$(jq -r '.state' "$registry_run/run.json")" = "cancelled" ]
  [ "$(jq -r '.state' "$registry_run/engine/run.json")" = "cancelled" ]
  [ -f "$registry_run/actions/cancel-intent.json" ]
  # Outstanding action cancelled without deletion
  [ -f "$registry_run/actions/requests/inp-seq-cancel-me.json" ]
  [ -f "$registry_run/actions/decisions/inp-seq-cancel-me.json" ]
  [ "$(jq -r '.decision' "$registry_run/actions/decisions/inp-seq-cancel-me.json")" = "cancel" ]
  # Victim should be gone (TERM/KILL). Do not sleep for the victim duration.
  if kill -0 "$victim" 2>/dev/null; then
    kill -KILL "$victim" 2>/dev/null || true
    wait "$victim" 2>/dev/null || true
    echo "victim still alive after cancel" >&2
    return 1
  fi
  wait "$victim" 2>/dev/null || true
}

@test "sequential cancel non-running waiting run" {
  local run_id registry_run
  run_id="$(seed_sequential_run run-seq-cancel-waiting)"
  registry_run="$CASE/workflow-runs/$run_id"
  workflow_state_clear_owner_and_set_state "$CASE" "$run_id" waiting
  write_approval_request "$registry_run" appr-seq-cancel approve-plan

  run workflow_seq_cancel --state-root "$CASE" --run-id "$run_id" --workspace "$FIX_PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(jq -r '.state' "$registry_run/run.json")" = "cancelled" ]
  [ -f "$registry_run/actions/requests/appr-seq-cancel.json" ]
  [ -f "$registry_run/actions/decisions/appr-seq-cancel.json" ]
  [ "$(jq -r '.decision' "$registry_run/actions/decisions/appr-seq-cancel.json")" = "cancel" ]
}

# --- public recover / cancel CLI --------------------------------------------

@test "recover CLI requires exact ID and rejects latest plan namespace" {
  wf_cli recover
  [ "$status" -eq 2 ]
  [[ "$output" == *"exact-run-id"* ]]

  wf_cli recover latest --yes
  [ "$status" -eq 2 ]
  [[ "$output" == *"exact run id"* ]]

  wf_cli recover run-x --namespace recovery --yes
  [ "$status" -eq 2 ]
  [[ "$output" == *"plan/namespace/node"* ]]

  wf_cli recover run-x --plan /tmp/x.plan.md --yes
  [ "$status" -eq 2 ]
  [[ "$output" == *"plan/namespace/node"* ]]

  wf_cli recover path/to/run --yes
  [ "$status" -eq 2 ]
  [[ "$output" == *"not a path"* ]]

  wf_cli recover run-a run-b --yes
  [ "$status" -eq 2 ]
  [[ "$output" == *"exactly one run id"* ]]
}

@test "cancel CLI requires exact ID and rejects latest plan namespace" {
  wf_cli cancel
  [ "$status" -eq 2 ]
  [[ "$output" == *"exact-run-id"* ]]

  wf_cli cancel latest --yes
  [ "$status" -eq 2 ]
  [[ "$output" == *"exact run id"* ]]

  wf_cli cancel run-x --namespace recovery --yes
  [ "$status" -eq 2 ]
  [[ "$output" == *"plan/namespace/node"* ]]

  wf_cli cancel run-x --stage implement --yes
  [ "$status" -eq 2 ]
  [[ "$output" == *"plan/namespace/node"* ]]

  wf_cli cancel path/to/run --yes
  [ "$status" -eq 2 ]
  [[ "$output" == *"not a path"* ]]

  wf_cli cancel run-a run-b --yes
  [ "$status" -eq 2 ]
  [[ "$output" == *"exactly one run id"* ]]
}

@test "recover CLI both modes preview confirmation outer state events next action" {
  local run_id registry_run graph_dir input_path events_before events_after
  # Sequential stale recover
  run_id="$(seed_sequential_run run-seq-recover-cli)"
  registry_run="$CASE/workflow-runs/$run_id"
  mark_sequential_engine_stale "$registry_run"
  workflow_state_update "$CASE" "$run_id" '.state="running"'
  input_path="$(jq -r '.inputPath' "$registry_run/run.json")"
  [ -f "$input_path" ]
  events_before="$(wc -l <"$registry_run/engine/events.jsonl" 2>/dev/null || echo 0)"

  WORKFLOW_SEQ_OWNER_TTL_SECONDS=1 WORKFLOW_SEQ_OWNER_NOW_EPOCH=1999999999 \
    wf_cli recover "$run_id" --yes
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"Operation: recover"* ]]
  [[ "$output" == *"confirmed-noninteractive"* ]] || [[ "$output" == *"Recovered"* ]]
  [[ "$output" == *"Recovered workflow run"* ]]
  [[ "$output" == *"Next:"* ]]
  [[ "$output" == *"resume"* ]]
  [ "$(jq -r '.state' "$registry_run/run.json")" = "blocked" ]
  [ "$(jq -r '.owner.pid // "null"' "$registry_run/run.json")" = "null" ]
  [ -f "$input_path" ]
  events_after="$(wc -l <"$registry_run/engine/events.jsonl" 2>/dev/null || echo 0)"
  [ "$events_after" -gt "$events_before" ]
  grep -Eq 'recovery-finish|run-status-changed' "$registry_run/engine/events.jsonl"

  # Dependency stale recover
  run_id="$(seed_dependency_run run-dep-recover-cli)"
  registry_run="$CASE/workflow-runs/$run_id"
  graph_dir="$CASE/graph-runs/recovery/$run_id"
  mark_dependency_graph_stale "$graph_dir"
  workflow_state_update "$CASE" "$run_id" '.state="running"'
  input_path="$(jq -r '.inputPath' "$registry_run/run.json")"
  [ -f "$input_path" ]
  events_before=0
  [[ -f "$graph_dir/events.jsonl" ]] && events_before="$(wc -l <"$graph_dir/events.jsonl")"

  GRAPH_HEARTBEAT_TTL_SECONDS=1 GRAPH_HEARTBEAT_NOW_EPOCH=1999999999 \
    wf_cli recover "$run_id" --yes
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"Operation: recover"* ]]
  [[ "$output" == *"Recovered workflow run"* ]]
  [[ "$output" == *"Next:"* ]]
  [[ "$output" == *"resume"* ]]
  [ "$(jq -r '.state' "$registry_run/run.json")" = "blocked" ]
  [ -f "$input_path" ]
  [ -f "$registry_run/plans/implement/attempt-1/source.plan.md" ]
  [[ -f "$graph_dir/events.jsonl" ]]
  events_after="$(wc -l <"$graph_dir/events.jsonl")"
  [ "$events_after" -ge "$events_before" ]
  grep -Eq 'recovery-finish|node-recovered|run-status-changed' "$graph_dir/events.jsonl" \
    || grep -Eq 'recovery-finish|run-status-changed' "$registry_run/logs/dependency-recover.log" 2>/dev/null \
    || true
}

@test "recover CLI intentional wait next action confirmation without manufacturing decisions" {
  local run_id registry_run before_req before_dec
  run_id="$(seed_sequential_run run-seq-recover-cli-wait)"
  registry_run="$CASE/workflow-runs/$run_id"
  write_approval_request "$registry_run" appr-cli-wait approve-plan
  workflow_seq_write_stage \
    --registry-run "$registry_run" --stage-id approve-plan --state waiting \
    --blocker-json '{"kind":"approval","requestId":"appr-cli-wait","reasonCode":"human-approval","retryable":false,"changesTarget":"investigate"}' \
    --skip-transition-check
  workflow_seq_update_run --registry-run "$registry_run" --state waiting --owner-json "$(_workflow_seq_null_owner_json)"
  workflow_state_clear_owner_and_set_state "$CASE" "$run_id" waiting
  before_req="$(cksum "$registry_run/actions/requests/appr-cli-wait.json")"
  before_dec="$(find "$registry_run/actions/decisions" -type f 2>/dev/null | sort | cksum || true)"

  wf_cli recover "$run_id" --yes
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"Operation: recover"* ]]
  [[ "$output" == *"unchanged"* || "$output" == *"intentional"* ]]
  [[ "$output" == *"Next:"* ]]
  [[ "$output" == *"actions list"* ]]
  [ "$(jq -r '.state' "$registry_run/run.json")" = "waiting" ]
  [ "$(cksum "$registry_run/actions/requests/appr-cli-wait.json")" = "$before_req" ]
  [ "$(find "$registry_run/actions/decisions" -type f 2>/dev/null | sort | cksum || true)" = "$before_dec" ]
  [ ! -f "$registry_run/actions/decisions/appr-cli-wait.json" ]
}

@test "recover CLI refuses live-running terminal and unknown runs" {
  local run_id registry_run start_id
  use_deterministic_process_start_probe
  run_id="$(seed_sequential_run run-seq-recover-cli-live)"
  registry_run="$CASE/workflow-runs/$run_id"
  start_id="$(graph_heartbeat_process_start_id_of_pid "$$")"
  mark_sequential_engine_live_owned "$registry_run" "$$" "$start_id"
  workflow_state_update "$CASE" "$run_id" \
    '.state = "running" | .owner = {pid:$pid,hostname:$host,processStartId:$start,heartbeatAt:"2099-01-01T00:00:00Z"}' \
    --argjson pid "$$" --arg start "$start_id" --arg host "$(hostname)"

  wf_cli recover "$run_id" --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"live"* || "$output" == *"refuses"* ]]

  run_id="$(seed_sequential_run run-seq-recover-cli-term)"
  registry_run="$CASE/workflow-runs/$run_id"
  workflow_seq_update_run --registry-run "$registry_run" --state running --owner-json "$(_workflow_seq_null_owner_json)"
  workflow_seq_update_run --registry-run "$registry_run" --state cancelled --owner-json "$(_workflow_seq_null_owner_json)"
  workflow_state_clear_owner_and_set_state "$CASE" "$run_id" cancelled
  wf_cli recover "$run_id" --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"terminal"* || "$output" == *"cancelled"* || "$output" == *"refuses"* ]]

  wf_cli recover run-does-not-exist --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* || "$output" == *"unknown"* ]]
}

@test "cancel CLI both modes preview confirmation outer state events next action" {
  local run_id registry_run graph_dir input_path events_before
  # Sequential cancel of waiting run (non-live)
  run_id="$(seed_sequential_run run-seq-cancel-cli)"
  registry_run="$CASE/workflow-runs/$run_id"
  workflow_state_clear_owner_and_set_state "$CASE" "$run_id" waiting
  write_approval_request "$registry_run" appr-cancel-cli approve-plan
  input_path="$(jq -r '.inputPath' "$registry_run/run.json")"
  [ -f "$input_path" ]
  events_before="$(wc -l <"$registry_run/engine/events.jsonl" 2>/dev/null || echo 0)"

  wf_cli cancel "$run_id" --yes
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"Operation: cancel"* ]]
  [[ "$output" == *"confirmed-noninteractive"* ]] || [[ "$output" == *"Cancelled"* ]]
  [[ "$output" == *"Cancelled workflow run"* ]]
  [ "$(jq -r '.state' "$registry_run/run.json")" = "cancelled" ]
  [ -f "$registry_run/actions/cancel-intent.json" ]
  [ -f "$registry_run/actions/requests/appr-cancel-cli.json" ]
  [ -f "$registry_run/actions/decisions/appr-cancel-cli.json" ]
  [ "$(jq -r '.decision' "$registry_run/actions/decisions/appr-cancel-cli.json")" = "cancel" ]
  [ -f "$input_path" ]
  [ "$(wc -l <"$registry_run/engine/events.jsonl")" -gt "$events_before" ]
  grep -Eq 'run-status-changed|cancelled' "$registry_run/engine/events.jsonl"

  # Dependency cancel of waiting run
  run_id="$(seed_dependency_run run-dep-cancel-cli)"
  registry_run="$CASE/workflow-runs/$run_id"
  graph_dir="$CASE/graph-runs/recovery/$run_id"
  workflow_state_clear_owner_and_set_state "$CASE" "$run_id" waiting
  write_approval_request "$registry_run" appr-dep-cancel-cli approve-plan
  input_path="$(jq -r '.inputPath' "$registry_run/run.json")"

  wf_cli cancel "$run_id" --yes
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"Operation: cancel"* ]]
  [[ "$output" == *"Cancelled workflow run"* ]]
  [ "$(jq -r '.state' "$registry_run/run.json")" = "cancelled" ]
  [ -f "$registry_run/actions/cancel-intent.json" ]
  [ -f "$registry_run/actions/requests/appr-dep-cancel-cli.json" ]
  [ -f "$registry_run/actions/decisions/appr-dep-cancel-cli.json" ]
  [ -f "$input_path" ]
  [ -f "$registry_run/plans/implement/attempt-1/source.plan.md" ]
}

@test "cancel CLI refuses terminal run and requires confirmation without --yes" {
  local run_id registry_run
  run_id="$(seed_sequential_run run-seq-cancel-cli-term)"
  registry_run="$CASE/workflow-runs/$run_id"
  workflow_seq_update_run --registry-run "$registry_run" --state running --owner-json "$(_workflow_seq_null_owner_json)"
  workflow_seq_update_run --registry-run "$registry_run" --state succeeded --owner-json "$(_workflow_seq_null_owner_json)"
  workflow_state_clear_owner_and_set_state "$CASE" "$run_id" succeeded

  wf_cli cancel "$run_id" --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"terminal"* || "$output" == *"succeeded"* || "$output" == *"refuses"* ]]

  run_id="$(seed_sequential_run run-seq-cancel-cli-noyes)"
  registry_run="$CASE/workflow-runs/$run_id"
  workflow_state_clear_owner_and_set_state "$CASE" "$run_id" waiting
  # Noninteractive without --yes must refuse confirmation (force closed stdin).
  wf_cli_notty cancel "$run_id"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--yes"* || "$output" == *"confirm"* ]]
  [ "$(jq -r '.state' "$registry_run/run.json")" = "waiting" ]
}
