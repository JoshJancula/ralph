#!/usr/bin/env bats
# Sequential engine state storage under <registry-run>/engine/.
# Sourced function coverage for the full public transition matrix, plus exactly
# one stubbed orchestrator --single-stage entry to prove hook wiring.
# Never invokes a runtime or model.
#
# Contracts: agents/rules/test-design.md, agents/rules/testing-workflow.md,
# and .ralph-workspace/artifacts/ralph-first-class-workflows/contracts.md
# (Sequential engine/run.json, stages/<id>.json, events.jsonl).

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

SEQ_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/workflow/workflow-engine-sequential.sh"
STATE_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/workflow/workflow-state.sh"
RUN_SCHEMA="$REPO_ROOT/bundle/.ralph/schemas/workflow-sequential-run.schema.json"
STAGE_SCHEMA="$REPO_ROOT/bundle/.ralph/schemas/workflow-sequential-stage.schema.json"
EVENT_SCHEMA="$REPO_ROOT/bundle/.ralph/schemas/workflow-sequential-event.schema.json"
ARTIFACT_SCHEMA_PY="$REPO_ROOT/bundle/.ralph/python/artifact_json_schema.py"

setup_file() {
  command -v jq >/dev/null || skip "jq required"
  command -v python3 >/dev/null || skip "python3 required"
  [ -f "$SEQ_LIB" ]
  [ -f "$STATE_LIB" ]
  [ -f "$RUN_SCHEMA" ]
  [ -f "$STAGE_SCHEMA" ]
  [ -f "$EVENT_SCHEMA" ]
  export BATS_NO_PARALLELIZE_WITHIN_FILE=true
}

setup() {
  unset RALPH_WORKFLOW_REGISTRY_RUN RALPH_WORKFLOW_RUN_ID
  unset RALPH_WORKFLOW_PLAN_INPUT_STAGE RALPH_WORKFLOW_SEQ_PROVIDED_FORCE_FRESH
  unset RALPH_WORKFLOW_SEQ_PLANFROM_FORCE_FRESH
  unset WORKFLOW_SEQ_FIXED_NOW WORKFLOW_STATE_FIXED_NOW
  unset GRAPH_STATE_SUPERVISOR_PID GRAPH_STATE_OWNER_HOSTNAME
  unset GRAPH_STATE_OWNER_PROCESS_START_ID GRAPH_STATE_HEARTBEAT_AT
  export WORKFLOW_STATE_SKIP_FSYNC=1
  export WORKFLOW_SEQ_SKIP_FSYNC=1
  export WORKFLOW_SEQ_FIXED_NOW="2026-08-26T15:00:00Z"
  export RALPH_WAIT_SCALE=0
  # shellcheck source=/dev/null
  source "$SEQ_LIB"
  CASE="$(mktemp -d "${BATS_TMPDIR:-/tmp}/wfl.XXXXXX")"
  CASE="$(cd "$CASE" && pwd -P)"
  mkdir -p "$CASE/inputs"
  cat >"$CASE/inputs/sample.orch.json" <<'ORCH'
{
  "name": "seq-lifecycle",
  "namespace": "seq-lifecycle",
  "parallelStages": [
    "alpha,beta"
  ],
  "stages": [
    {
      "id": "investigate",
      "runtime": "cursor",
      "instructions": "Inline investigation only.",
      "artifacts": [{"path": ".ralph-workspace/artifacts/seq-lifecycle/investigation.md", "required": true}]
    },
    {
      "id": "alpha",
      "runtime": "cursor",
      "plan": "stages/alpha.plan.md"
    },
    {
      "id": "beta",
      "runtime": "cursor",
      "plan": "stages/beta.plan.md"
    },
    {
      "id": "approve-plan",
      "type": "approval",
      "question": "Approve the plan?",
      "changesTarget": "investigate",
      "inputArtifacts": [
        {
          "path": ".ralph-workspace/artifacts/seq-lifecycle/investigation.md",
          "required": true
        }
      ]
    }
  ]
}
ORCH
  printf '%s\n' '---' 'kind: workflow' 'mode: sequential' 'overview: lifecycle' '---' >"$CASE/inputs/wf.md"
}

teardown() {
  rm -rf "$CASE"
}

validate_run_schema() {
  python3 "$ARTIFACT_SCHEMA_PY" validate-final-output \
    --schema "$RUN_SCHEMA" \
    --artifact "$1"
}

validate_stage_schema() {
  python3 "$ARTIFACT_SCHEMA_PY" validate-final-output \
    --schema "$STAGE_SCHEMA" \
    --artifact "$1"
}

validate_events_jsonl() {
  local path="$1" line i=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    i=$((i + 1))
    printf '%s\n' "$line" >"$CASE/event-row-$i.json"
    python3 "$ARTIFACT_SCHEMA_PY" validate-final-output \
      --schema "$EVENT_SCHEMA" \
      --artifact "$CASE/event-row-$i.json" || return $?
  done <"$path"
  [[ "$i" -gt 0 ]]
}

create_registry_run() {
  local run_id
  run_id="$(
    workflow_state_create \
      --state-root "$CASE" \
      --source-path "$CASE/inputs/wf.md" \
      --source-kind project \
      --mode sequential \
      --entry-kind task \
      --task "Lifecycle fixture" \
      --task-provenance explicit \
      --input-file "$CASE/inputs/sample.orch.json" \
      --workflow-id seq-lifecycle
  )"
  printf '%s\n' "$run_id"
}

# --- state files ------------------------------------------------------------

@test "state files: init persists run.json events.jsonl and stages with null zero fields" {
  local run_id registry_run engine_dir stage_file
  run_id="$(create_registry_run)"
  registry_run="$CASE/workflow-runs/$run_id"
  run workflow_seq_init_engine \
    --registry-run "$registry_run" \
    --input-file "$CASE/inputs/sample.orch.json" \
    --run-id "$run_id"
  [ "$status" -eq 0 ]
  engine_dir="$registry_run/engine"
  [ -f "$engine_dir/run.json" ]
  [ -f "$engine_dir/events.jsonl" ]
  [ -f "$engine_dir/stages/investigate.json" ]
  [ -f "$engine_dir/stages/alpha.json" ]
  [ -f "$engine_dir/stages/beta.json" ]
  [ -f "$engine_dir/stages/approve-plan.json" ]

  validate_run_schema "$engine_dir/run.json"
  [ "$(jq -r '.state' "$engine_dir/run.json")" = "queued" ]
  [ "$(jq -r '.loopIterations' "$engine_dir/run.json")" = "0" ]
  [ "$(jq -r '.completedWaves' "$engine_dir/run.json")" = "0" ]
  [ "$(jq -r '.owner.pid' "$engine_dir/run.json")" = "null" ]
  [ "$(jq -r '.currentStageIds | length' "$engine_dir/run.json")" = "0" ]
  [[ "$(jq -r '.inputSha256' "$engine_dir/run.json")" =~ ^[a-f0-9]{64}$ ]]

  for stage_file in "$engine_dir/stages/"*.json; do
    validate_stage_schema "$stage_file"
    [ "$(jq -r '.planPath,.planRunId,.planSourceKind,.planSourceStageId,.originalPlanPath,.sourcePlanPath,.controlPlanPath,.currentTodoId,.terminalResult,.blocker' "$stage_file" | paste -sd, -)" = "null,null,null,null,null,null,null,null,null,null" ]
    [ "$(jq -r '.completedTodos,.totalTodos' "$stage_file" | paste -sd, -)" = "0,0" ]
    [ "$(jq -r '.state' "$stage_file")" = "queued" ]
    [ "$(jq -r '.attempt' "$stage_file")" = "0" ]
  done

  [ "$(jq -r '.wave' "$engine_dir/stages/alpha.json")" = "0" ]
  [ "$(jq -r '.wave' "$engine_dir/stages/beta.json")" = "0" ]
  [ "$(jq -r '.wave' "$engine_dir/stages/investigate.json")" = "null" ]
  [ "$(jq -r '.index' "$engine_dir/stages/investigate.json")" = "0" ]
  [ "$(jq -r '.index' "$engine_dir/stages/approve-plan.json")" = "3" ]

  validate_events_jsonl "$engine_dir/events.jsonl"
  [ "$(head -n1 "$engine_dir/events.jsonl" | jq -r '.event,.newState,.priorState' | paste -sd, -)" = "run-created,queued,null" ]
}

# --- transitions ------------------------------------------------------------

@test "transitions: full public stage matrix accepts legal edges and rejects illegal ones" {
  local from to
  # Empty / same-state always legal.
  workflow_seq_validate_stage_transition "" queued
  workflow_seq_validate_stage_transition "" running
  for from in queued running waiting blocked stale failed cancelled succeeded; do
    workflow_seq_validate_stage_transition "$from" "$from"
  done

  # Representative legal edges covering every non-terminal source.
  workflow_seq_validate_stage_transition queued running
  workflow_seq_validate_stage_transition queued cancelled
  workflow_seq_validate_stage_transition running succeeded
  workflow_seq_validate_stage_transition running failed
  workflow_seq_validate_stage_transition running waiting
  workflow_seq_validate_stage_transition running blocked
  workflow_seq_validate_stage_transition running stale
  workflow_seq_validate_stage_transition running cancelled
  workflow_seq_validate_stage_transition waiting running
  workflow_seq_validate_stage_transition waiting blocked
  workflow_seq_validate_stage_transition waiting cancelled
  workflow_seq_validate_stage_transition blocked queued
  workflow_seq_validate_stage_transition blocked running
  workflow_seq_validate_stage_transition stale queued
  workflow_seq_validate_stage_transition stale running
  workflow_seq_validate_stage_transition failed queued
  workflow_seq_validate_stage_transition failed running

  # Illegal: leave terminals, skip queued->succeeded, running->queued.
  ! workflow_seq_validate_stage_transition succeeded running
  ! workflow_seq_validate_stage_transition succeeded queued
  ! workflow_seq_validate_stage_transition cancelled running
  ! workflow_seq_validate_stage_transition queued succeeded
  ! workflow_seq_validate_stage_transition running queued
  ! workflow_seq_validate_stage_transition blocked succeeded

  # Run matrix reuses the same validator.
  workflow_seq_validate_run_transition queued running
  ! workflow_seq_validate_run_transition succeeded failed
}

@test "transitions: write_stage journals events and refuses illegal transitions" {
  local run_id registry_run
  run_id="$(create_registry_run)"
  registry_run="$CASE/workflow-runs/$run_id"
  workflow_seq_init_engine \
    --registry-run "$registry_run" \
    --input-file "$CASE/inputs/sample.orch.json" \
    --run-id "$run_id"

  run workflow_seq_write_stage \
    --registry-run "$registry_run" \
    --stage-id investigate \
    --state running \
    --attempt 1 \
    --event-name stage-started \
    --details-json '{"stageType":"inline","phase":"before"}'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.state,.attempt' "$registry_run/engine/stages/investigate.json" | paste -sd, -)" = "running,1" ]

  run workflow_seq_write_stage \
    --registry-run "$registry_run" \
    --stage-id investigate \
    --state succeeded \
    --terminal-result succeeded
  [ "$status" -eq 0 ]
  [ "$(jq -r '.state,.terminalResult' "$registry_run/engine/stages/investigate.json" | paste -sd, -)" = "succeeded,succeeded" ]

  # Illegal: succeeded -> running must leave the file unchanged.
  run workflow_seq_write_stage \
    --registry-run "$registry_run" \
    --stage-id investigate \
    --state running
  [ "$status" -ne 0 ]
  [ "$(jq -r '.state' "$registry_run/engine/stages/investigate.json")" = "succeeded" ]

  validate_events_jsonl "$registry_run/engine/events.jsonl"
  grep -q '"event":"stage-started"' "$registry_run/engine/events.jsonl"
  grep -q '"newState":"succeeded"' "$registry_run/engine/events.jsonl"
}

# --- artifacts / action reference / loop / wave / owner ---------------------

@test "artifacts action reference loop wave owner fields persist on stage and run" {
  local run_id registry_run blocker owner
  run_id="$(create_registry_run)"
  registry_run="$CASE/workflow-runs/$run_id"
  workflow_seq_init_engine \
    --registry-run "$registry_run" \
    --input-file "$CASE/inputs/sample.orch.json" \
    --run-id "$run_id"

  owner="$(jq -cn '{pid:99,hostname:"host",processStartId:"99:1",heartbeatAt:"2026-08-26T15:00:01Z"}')"
  workflow_seq_update_run \
    --registry-run "$registry_run" \
    --state running \
    --current-stage-ids-json '["alpha"]' \
    --loop-iterations 2 \
    --completed-waves 1 \
    --owner-json "$owner" \
    --event-name run-status-changed \
    --details-json '{"reason":"owner-loop-wave"}'

  [ "$(jq -r '.loopIterations,.completedWaves,.owner.pid,.currentStageIds[0]' "$registry_run/engine/run.json" | paste -sd, -)" = "2,1,99,alpha" ]
  validate_run_schema "$registry_run/engine/run.json"

  workflow_seq_write_stage \
    --registry-run "$registry_run" \
    --stage-id alpha \
    --state running \
    --attempt 1 \
    --wave 0 \
    --artifacts-json '[".ralph-workspace/artifacts/seq-lifecycle/alpha.md"]'

  [ "$(jq -r '.wave,.artifacts[0],.attempt' "$registry_run/engine/stages/alpha.json" | paste -sd, -)" = "0,.ralph-workspace/artifacts/seq-lifecycle/alpha.md,1" ]

  blocker="$(jq -cn '{
    kind:"approval",
    requestId:"appr-1",
    reasonCode:"human-approval",
    retryable:false,
    changesTarget:"investigate",
    action:{label:"List actions",argv:["ralph","workflow","actions","list","run-1"]}
  }')"
  workflow_seq_write_stage \
    --registry-run "$registry_run" \
    --stage-id approve-plan \
    --state running \
    --attempt 1
  workflow_seq_write_stage \
    --registry-run "$registry_run" \
    --stage-id approve-plan \
    --state waiting \
    --blocker-json "$blocker" \
    --details-json '{"stageType":"approval"}'

  validate_stage_schema "$registry_run/engine/stages/approve-plan.json"
  [ "$(jq -r '.blocker.kind,.blocker.action.argv[3],.completedTodos,.planSourceKind' "$registry_run/engine/stages/approve-plan.json" | paste -sd, -)" = "approval,list,0,null" ]
}

# --- existing semantics + one orchestrator entry ----------------------------

@test "existing semantics: without engine init orchestrator leaves no sequential state files" {
  # Cost justification (entry-point): proving hook no-op requires one stubbed
  # orchestrator --single-stage (~few seconds). Sourced tests cover the matrix;
  # this is the sole entry-point case. RALPH_WAIT_SCALE=0; no runtime/network.
  local workspace orch_file registry_run run_id
  workspace="$(mktemp -d)"
  mkdir -p "$workspace/.ralph/bash-lib/orchestrator" "$workspace/.ralph/python" \
    "$workspace/.ralph/bash-lib/workflow" "$workspace/stages" \
    "$workspace/.ralph-workspace/logs"
  cp "$REPO_ROOT/.ralph/ralph-env-safety.sh" "$workspace/.ralph/"
  for f in error-handling.sh runtime-resolve.sh runtime-normalize.sh artifacts.sh \
           atomic-json.sh ralph-format-elapsed.sh review-status.sh \
           ralph-process-teardown.sh ralph-process-supervisor.sh; do
    cp "$REPO_ROOT/.ralph/bash-lib/$f" "$workspace/.ralph/bash-lib/" 2>/dev/null || true
  done
  cp "$REPO_ROOT/.ralph/bash-lib/orchestrator/"*.sh "$workspace/.ralph/bash-lib/orchestrator/"
  cp "$REPO_ROOT/.ralph/python/ralph_process_supervisor.py" "$workspace/.ralph/python/"
  # Intentionally omit workflow-engine-sequential.sh from workspace .ralph so
  # RALPH_DIR fallback is exercised via REPO_ROOT orchestrator path below.
  cat >"$workspace/.ralph/run-plan.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'stub run-plan ok\n'
exit 0
STUB
  chmod +x "$workspace/.ralph/run-plan.sh"
  cat >"$workspace/stages/only.plan.md" <<'PLAN'
# only
- [ ] do thing
PLAN
  mkdir -p "$workspace/.ralph-workspace/artifacts/seq-hook"
  printf 'ok\n' >"$workspace/.ralph-workspace/artifacts/seq-hook/out.md"
  orch_file="$workspace/only.orch.json"
  cat >"$orch_file" <<'ORCH'
{
  "name": "hook-semantics",
  "namespace": "seq-hook",
  "stages": [
    {
      "id": "only-stage",
      "runtime": "cursor",
      "plan": "stages/only.plan.md",
      "artifacts": [
        {"path": ".ralph-workspace/artifacts/seq-hook/out.md", "required": true}
      ]
    }
  ]
}
ORCH

  # No RALPH_WORKFLOW_REGISTRY_RUN / no engine init => existing semantics, no engine/.
  run env RALPH_ALLOW_NESTED_RUNS=1 RALPH_WAIT_SCALE=0 RALPH_ARTIFACT_SCHEMA_VALIDATION=0 \
    bash "$REPO_ROOT/.ralph/orchestrator.sh" \
      --orchestration "$orch_file" \
      --single-stage only-stage \
      --run-id "run-semantics" \
      --attempt-id "attempt-1" \
      "$workspace" 2>&1
  [ "$status" -eq 0 ] || { echo "$output"; rm -rf "$workspace"; return 1; }
  [ ! -d "$workspace/.ralph-workspace/workflow-runs" ]
  [ ! -e "$workspace/engine/run.json" ]

  # With registry + engine init, the same stubbed entry journals before/after.
  mkdir -p "$workspace/.ralph-workspace/workflow-inputs"
  cp "$orch_file" "$workspace/.ralph-workspace/workflow-inputs/sample.orch.json"
  printf '%s\n' '---' 'kind: workflow' 'mode: sequential' '---' \
    >"$workspace/.ralph-workspace/workflow-inputs/wf.md"
  export WORKFLOW_STATE_SKIP_FSYNC=1
  # shellcheck source=/dev/null
  source "$STATE_LIB"
  # shellcheck source=/dev/null
  source "$SEQ_LIB"
  run_id="$(
    workflow_state_create \
      --state-root "$workspace/.ralph-workspace" \
      --source-path "$workspace/.ralph-workspace/workflow-inputs/wf.md" \
      --source-kind project \
      --mode sequential \
      --entry-kind task \
      --task "hook wiring" \
      --task-provenance explicit \
      --input-file "$workspace/.ralph-workspace/workflow-inputs/sample.orch.json" \
      --workflow-id hook-wiring
  )"
  registry_run="$workspace/.ralph-workspace/workflow-runs/$run_id"
  workflow_seq_init_engine \
    --registry-run "$registry_run" \
    --input-file "$workspace/.ralph-workspace/workflow-inputs/sample.orch.json" \
    --run-id "$run_id"

  run env RALPH_ALLOW_NESTED_RUNS=1 RALPH_WAIT_SCALE=0 RALPH_ARTIFACT_SCHEMA_VALIDATION=0 \
    RALPH_WORKFLOW_REGISTRY_RUN="$registry_run" \
    RALPH_WORKFLOW_RUN_ID="$run_id" \
    WORKFLOW_STATE_SKIP_FSYNC=1 \
    WORKFLOW_SEQ_SKIP_FSYNC=1 \
    bash "$REPO_ROOT/.ralph/orchestrator.sh" \
      --orchestration "$orch_file" \
      --single-stage only-stage \
      --run-id "$run_id" \
      --attempt-id "attempt-1" \
      "$workspace" 2>&1
  [ "$status" -eq 0 ] || { echo "$output"; rm -rf "$workspace"; return 1; }

  [ -f "$registry_run/engine/stages/only-stage.json" ]
  [ "$(jq -r '.state,.terminalResult,.attempt' "$registry_run/engine/stages/only-stage.json" | paste -sd, -)" = "succeeded,succeeded,1" ]
  grep -q '"event":"stage-started"' "$registry_run/engine/events.jsonl"
  grep -q '"event":"stage-finished"' "$registry_run/engine/events.jsonl"
  validate_stage_schema "$registry_run/engine/stages/only-stage.json"
  validate_events_jsonl "$registry_run/engine/events.jsonl"

  ralph_test_rm_workspace "$workspace"
}

# --- resume (internal by common run ID) -------------------------------------

ACTIONS_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/workflow/workflow-actions.sh"

seed_engine() {
  local run_id registry_run
  run_id="$(create_registry_run)"
  registry_run="$CASE/workflow-runs/$run_id"
  workflow_seq_init_engine \
    --registry-run "$registry_run" \
    --input-file "$CASE/inputs/sample.orch.json" \
    --run-id "$run_id" >/dev/null
  printf '%s\n' "$run_id"
}

write_input_request() {
  local run_dir="$1" request_id="${2:-inp-001}" stage_id="${3:-investigate}"
  # shellcheck source=/dev/null
  source "$ACTIONS_LIB"
  export WORKFLOW_ACTION_NOW="2026-08-26T15:00:00Z"
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
  # shellcheck source=/dev/null
  source "$ACTIONS_LIB"
  export WORKFLOW_ACTION_NOW="2026-08-26T15:00:00Z"
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

@test "resume by common run ID dry-run returns plan and restores loop position parallel wave" {
  local run_id registry_run plan
  run_id="$(seed_engine)"
  registry_run="$CASE/workflow-runs/$run_id"

  # Succeed investigate; fail alpha; leave beta queued. Preserve loop/wave.
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id investigate --state running --attempt 1
  mkdir -p "$CASE/.ralph-workspace/artifacts/seq-lifecycle"
  printf 'ok\n' >"$CASE/.ralph-workspace/artifacts/seq-lifecycle/investigation.md"
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id investigate --state succeeded \
    --terminal-result succeeded \
    --artifacts-json '[".ralph-workspace/artifacts/seq-lifecycle/investigation.md"]'
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id alpha --state running --attempt 1 --wave 0
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id alpha --state failed --terminal-result failed --wave 0
  workflow_seq_update_run \
    --registry-run "$registry_run" \
    --state failed \
    --loop-iterations 3 \
    --completed-waves 0 \
    --current-stage-ids-json '["alpha"]' \
    --owner-json "$(_workflow_seq_null_owner_json)"

  run workflow_seq_resume --registry-run "$registry_run" --run-id "$run_id" --workspace "$CASE" --dry-run
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  plan="$output"
  [ "$(printf '%s' "$plan" | jq -r '.ok,.loopIterations,.completedWaves,.retryCount' | paste -sd, -)" = "true,3,0,1" ]
  # alpha failed -> retry; beta queued with prereqs unmet (investigate ok, alpha not) -> defer
  [ "$(printf '%s' "$plan" | jq -r '.stages[] | select(.stageId=="investigate") | .action')" = "skip-succeeded" ]
  [ "$(printf '%s' "$plan" | jq -r '.stages[] | select(.stageId=="alpha") | .action')" = "retry" ]
  [ "$(printf '%s' "$plan" | jq -r '.stages[] | select(.stageId=="alpha") | .wave')" = "0" ]
  [ "$(printf '%s' "$plan" | jq -r '.stages[] | select(.stageId=="beta") | .action')" = "defer" ]

  # Parallel wave position preserved on engine run after apply
  run workflow_seq_resume --registry-run "$registry_run" --run-id "$run_id" --workspace "$CASE"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.loopIterations,.completedWaves,.state' "$registry_run/engine/run.json" | paste -sd, -)" = "3,0,queued" ]
  [ "$(jq -r '.state' "$registry_run/engine/stages/alpha.json")" = "queued" ]
  [ "$(jq -r '.wave' "$registry_run/engine/stages/alpha.json")" = "0" ]
}

@test "skip succeeded stages and never rerun them on resume" {
  local run_id registry_run
  run_id="$(seed_engine)"
  registry_run="$CASE/workflow-runs/$run_id"
  mkdir -p "$CASE/.ralph-workspace/artifacts/seq-lifecycle"
  printf 'ok\n' >"$CASE/.ralph-workspace/artifacts/seq-lifecycle/investigation.md"
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id investigate --state running --attempt 1
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id investigate --state succeeded \
    --terminal-result succeeded \
    --artifacts-json '[".ralph-workspace/artifacts/seq-lifecycle/investigation.md"]'
  workflow_seq_update_run --registry-run "$registry_run" --state waiting --owner-json "$(_workflow_seq_null_owner_json)"

  run workflow_seq_resume_by_run_id --state-root "$CASE" --run-id "$run_id" --workspace "$CASE" --dry-run
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.stages[] | select(.stageId=="investigate") | .action')" = "skip-succeeded" ]
  workflow_seq_stage_should_skip "$registry_run" investigate
  ! workflow_seq_stage_should_skip "$registry_run" alpha
}

@test "input hash validation refuses mutated frozen orch input" {
  local run_id registry_run
  run_id="$(seed_engine)"
  registry_run="$CASE/workflow-runs/$run_id"
  # Mutate the immutable input copy under the registry run.
  jq '.name = "mutated"' "$registry_run/input.orch.json" >"$registry_run/input.orch.json.tmp"
  mv "$registry_run/input.orch.json.tmp" "$registry_run/input.orch.json"

  run workflow_seq_validate_immutable_hashes "$registry_run"
  [ "$status" -ne 0 ]
  [[ "$(printf '%s' "$output" | jq -r '.ok')" == "false" ]]
  [[ "$(printf '%s' "$output" | jq -r '.errors[0]')" == *"input hash mismatch"* ]]

  run workflow_seq_resume --registry-run "$registry_run" --dry-run
  [ "$status" -eq 2 ]
}

@test "provided hash validation refuses mutated supplied plan source" {
  local run_id registry_run source_plan sha
  run_id="$(seed_engine)"
  registry_run="$CASE/workflow-runs/$run_id"
  mkdir -p "$registry_run/plans/input"
  source_plan="$registry_run/plans/input/source.plan.md"
  printf '%s\n' '---' 'name: provided' '---' '- [ ] todo' >"$source_plan"
  sha="$(_workflow_seq_file_sha256 "$source_plan")"
  # Attach inputPlan metadata onto outer run.json
  jq --arg path "$source_plan" --arg sha "$sha" \
    '.inputPlan = {
      originalPath: $path,
      sourcePath: $path,
      manifestPath: ($path | sub("source.plan.md$"; "manifest.json")),
      sha256: $sha,
      format: "classic",
      totalTodos: 1,
      completedTodos: 0,
      openTodos: 1
    }' "$registry_run/run.json" >"$registry_run/run.json.tmp"
  mv "$registry_run/run.json.tmp" "$registry_run/run.json"
  printf 'mutated\n' >>"$source_plan"

  run workflow_seq_validate_immutable_hashes "$registry_run"
  [ "$status" -ne 0 ]
  [[ "$(printf '%s' "$output" | jq -r '.errors[]')" == *"provided hash mismatch"* ]]
}

@test "clean interruption waiting is retryable with no live owner" {
  local run_id registry_run
  run_id="$(seed_engine)"
  registry_run="$CASE/workflow-runs/$run_id"
  mkdir -p "$CASE/.ralph-workspace/artifacts/seq-lifecycle"
  printf 'ok\n' >"$CASE/.ralph-workspace/artifacts/seq-lifecycle/investigation.md"
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id investigate --state running --attempt 1
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id investigate --state succeeded \
    --terminal-result succeeded \
    --artifacts-json '[".ralph-workspace/artifacts/seq-lifecycle/investigation.md"]'
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id alpha --state running --attempt 1 --wave 0
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id alpha --state waiting --wave 0 \
    --blocker-json null
  workflow_seq_update_run --registry-run "$registry_run" --state waiting --owner-json "$(_workflow_seq_null_owner_json)"

  run workflow_seq_resume --registry-run "$registry_run" --workspace "$CASE"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(printf '%s' "$output" | jq -r '.stages[] | select(.stageId=="alpha") | .action')" = "retry-clean-interruption" ]
  [ "$(jq -r '.state' "$registry_run/engine/stages/alpha.json")" = "queued" ]
}

@test "answered input ready for consumption is consumed once on resume" {
  local run_id registry_run control
  run_id="$(seed_engine)"
  registry_run="$CASE/workflow-runs/$run_id"
  mkdir -p "$CASE/.ralph-workspace/artifacts/seq-lifecycle" "$registry_run/plans/investigate/attempt-1"
  printf 'ok\n' >"$CASE/.ralph-workspace/artifacts/seq-lifecycle/investigation.md"
  control="$registry_run/plans/investigate/attempt-1/control.plan.md"
  printf '%s\n' '---' 'name: ctrl' '---' '- [ ] open-todo' >"$control"

  workflow_seq_write_stage --registry-run "$registry_run" --stage-id investigate --state running --attempt 1
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id investigate --state waiting --attempt 1 \
    --control-plan-path "$control" \
    --current-todo-id open-todo \
    --plan-source-kind generated \
    --completed-todos 0 --total-todos 1 \
    --blocker-json '{"kind":"input","requestId":"inp-001","reasonCode":"operator-input","retryable":true,"changesTarget":null,"action":{"label":"List","argv":["ralph","workflow","actions","list","'"$run_id"'"]}}'
  write_input_request "$registry_run" inp-001 investigate
  # shellcheck source=/dev/null
  source "$ACTIONS_LIB"
  workflow_action_decision_write "$registry_run" "$(jq -nc \
    --arg runId "$run_id" \
    '{requestId:"inp-001",kind:"input",runId:$runId,stageId:"investigate",attemptId:"investigate-1",decision:"answer",message:"use staging",actorSource:"human",decidedAt:"2026-08-26T15:00:00Z"}')" >/dev/null
  workflow_seq_update_run --registry-run "$registry_run" --state waiting --owner-json "$(_workflow_seq_null_owner_json)"

  run workflow_seq_resume --registry-run "$registry_run" --workspace "$CASE"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(printf '%s' "$output" | jq -r '.stages[] | select(.stageId=="investigate") | .action')" = "retry-answered-input" ]
  [ "$(printf '%s' "$output" | jq -r '.stages[] | select(.stageId=="investigate") | .controlPlanPath')" = "$control" ]
  [ "$(printf '%s' "$output" | jq -r '.stages[] | select(.stageId=="investigate") | .currentTodoId')" = "open-todo" ]
  [ -f "$registry_run/actions/consumed/inp-001.json" ]
  [ "$(jq -r '.consumer' "$registry_run/actions/consumed/inp-001.json")" = "resume" ]
  # same control plan path retained on stage document
  [ "$(jq -r '.controlPlanPath,.currentTodoId,.state' "$registry_run/engine/stages/investigate.json" | paste -sd, -)" = "$control,open-todo,queued" ]
  # second consume must fail (already consumed)
  run workflow_action_consume_once "$registry_run" inp-001 resume
  [ "$status" -ne 0 ]
}

@test "approved gate is completed during resume with one-time consumption" {
  local run_id registry_run
  run_id="$(seed_engine)"
  registry_run="$CASE/workflow-runs/$run_id"
  mkdir -p "$CASE/.ralph-workspace/artifacts/seq-lifecycle"
  printf 'ok\n' >"$CASE/.ralph-workspace/artifacts/seq-lifecycle/investigation.md"
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id investigate --state running --attempt 1
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id investigate --state succeeded \
    --terminal-result succeeded \
    --artifacts-json '[".ralph-workspace/artifacts/seq-lifecycle/investigation.md"]'
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id alpha --state running --attempt 1 --wave 0
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id alpha --state succeeded --terminal-result succeeded --wave 0
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id beta --state running --attempt 1 --wave 0
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id beta --state succeeded --terminal-result succeeded --wave 0
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id approve-plan --state running --attempt 1
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id approve-plan --state waiting \
    --blocker-json '{"kind":"approval","requestId":"appr-001","reasonCode":"human-approval","retryable":true,"changesTarget":"investigate","action":{"label":"List","argv":["ralph","workflow","actions","list","'"$run_id"'"]}}'
  write_approval_request "$registry_run" appr-001 approve-plan
  # shellcheck source=/dev/null
  source "$ACTIONS_LIB"
  workflow_action_decision_write "$registry_run" "$(jq -nc \
    --arg runId "$run_id" \
    '{requestId:"appr-001",kind:"approval",runId:$runId,stageId:"approve-plan",attemptId:"approve-plan-1",decision:"approve",actorSource:"human",decidedAt:"2026-08-26T15:00:00Z"}')" >/dev/null
  workflow_seq_update_run --registry-run "$registry_run" --state waiting --owner-json "$(_workflow_seq_null_owner_json)"

  run workflow_seq_resume --registry-run "$registry_run" --workspace "$CASE"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(printf '%s' "$output" | jq -r '.stages[] | select(.stageId=="approve-plan") | .action')" = "complete-approved-gate" ]
  [ "$(jq -r '.state,.terminalResult' "$registry_run/engine/stages/approve-plan.json" | paste -sd, -)" = "succeeded,succeeded" ]
  [ -f "$registry_run/actions/consumed/appr-001.json" ]
}

@test "unresolved action and changes-requested are refused by resume" {
  local run_id registry_run
  run_id="$(seed_engine)"
  registry_run="$CASE/workflow-runs/$run_id"

  # Unresolved approval
  write_approval_request "$registry_run" appr-u approve-plan
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id approve-plan --state running --attempt 1
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id approve-plan --state waiting \
    --blocker-json '{"kind":"approval","requestId":"appr-u","reasonCode":"human-approval","retryable":false,"changesTarget":"investigate","action":{"label":"List","argv":["ralph","workflow","actions","list","x"]}}'
  workflow_seq_update_run --registry-run "$registry_run" --state waiting --owner-json "$(_workflow_seq_null_owner_json)"
  run workflow_seq_resume --registry-run "$registry_run" --workspace "$CASE" --dry-run
  [ "$status" -ne 0 ]
  [ "$(printf '%s' "$output" | jq -r '.ok')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.stages[] | select(.stageId=="approve-plan") | .action')" = "refuse" ]
  [ "$(printf '%s' "$output" | jq -r '.stages[] | select(.stageId=="approve-plan") | .reasonCode')" = "human-approval" ]

  # Reset approve-plan to changes-requested blocked
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id approve-plan --state blocked \
    --blocker-json '{"kind":"approval","requestId":"appr-u","reasonCode":"human-changes-requested","retryable":false,"changesTarget":"investigate","action":{"label":"Reset","argv":["ralph","workflow","reset","x","--stage","investigate"]}}' \
    --skip-transition-check
  # shellcheck source=/dev/null
  source "$ACTIONS_LIB"
  workflow_action_decision_write "$registry_run" "$(jq -nc \
    --arg runId "$run_id" \
    '{requestId:"appr-u",kind:"approval",runId:$runId,stageId:"approve-plan",attemptId:"approve-plan-1",decision:"request-changes",message:"fix the plan",actorSource:"human",decidedAt:"2026-08-26T15:00:00Z"}')" >/dev/null
  workflow_seq_update_run --registry-run "$registry_run" --state blocked --owner-json "$(_workflow_seq_null_owner_json)" --skip-transition-check
  run workflow_seq_resume --registry-run "$registry_run" --workspace "$CASE" --dry-run
  [ "$status" -ne 0 ]
  [ "$(printf '%s' "$output" | jq -r '.stages[] | select(.stageId=="approve-plan") | .reasonCode')" = "human-changes-requested" ]
}

@test "same control plan path is restored for resume plan output" {
  local run_id registry_run control
  run_id="$(seed_engine)"
  registry_run="$CASE/workflow-runs/$run_id"
  mkdir -p "$registry_run/plans/alpha/attempt-2"
  control="$registry_run/plans/alpha/attempt-2/control.plan.md"
  printf '%s\n' '- [x] done' '- [ ] next' >"$control"
  mkdir -p "$CASE/.ralph-workspace/artifacts/seq-lifecycle"
  printf 'ok\n' >"$CASE/.ralph-workspace/artifacts/seq-lifecycle/investigation.md"
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id investigate --state running --attempt 1
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id investigate --state succeeded \
    --terminal-result succeeded \
    --artifacts-json '[".ralph-workspace/artifacts/seq-lifecycle/investigation.md"]'
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id alpha --state running --attempt 2 --wave 0 \
    --control-plan-path "$control" --current-todo-id next \
    --plan-source-kind provided --completed-todos 1 --total-todos 2
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id alpha --state failed --terminal-result failed --wave 0
  workflow_seq_update_run --registry-run "$registry_run" --state failed --owner-json "$(_workflow_seq_null_owner_json)"

  run workflow_seq_resume --registry-run "$registry_run" --workspace "$CASE" --dry-run
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.stages[] | select(.stageId=="alpha") | .controlPlanPath,.currentTodoId,.planSourceKind' | paste -sd, -)" = "$control,next,provided" ]
  [ "$(workflow_seq_resolve_control_plan "$registry_run" alpha)" = "$control" ]
}

@test "artifact recheck refuses resume when succeeded prerequisite artifact is missing" {
  local run_id registry_run
  run_id="$(seed_engine)"
  registry_run="$CASE/workflow-runs/$run_id"
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id investigate --state running --attempt 1
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id investigate --state succeeded \
    --terminal-result succeeded \
    --artifacts-json '[".ralph-workspace/artifacts/seq-lifecycle/investigation.md"]'
  # Deliberately do not create the artifact file.
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id alpha --state failed --terminal-result failed --wave 0 \
    --skip-transition-check
  workflow_seq_update_run --registry-run "$registry_run" --state failed --owner-json "$(_workflow_seq_null_owner_json)" --skip-transition-check

  run workflow_seq_resume --registry-run "$registry_run" --workspace "$CASE" --dry-run
  [ "$status" -ne 0 ]
  [ "$(printf '%s' "$output" | jq -r '.stages[] | select(.stageId=="investigate") | .action')" = "refuse" ]
  [ "$(printf '%s' "$output" | jq -r '.stages[] | select(.stageId=="investigate") | .reasonCode')" = "missing-artifact" ]
}

# --- Sequential planFrom control copy / progress / resume / reset -----------
# Contracts: generated planFrom resolve/bind, control copy, progress fields,
# same-plan resume, consumer reset, planner reset, invalid plan refusal.
# Level: sourced functions + one stub run-plan argv/progress hook.
# Never invokes a model or full orchestration journey.

write_seq_planner_artifact() {
  local dest="${1:-$CASE/artifacts/planner.json}"
  mkdir -p "$(dirname -- "$dest")"
  cat >"$dest" <<'EOF'
{
  "schemaVersion": 2,
  "name": "seq-generated",
  "overview": "Sequential planFrom fixture plan",
  "rationale": "Two verifiable TODOs for control-copy tests.",
  "todos": [
    {
      "id": "implement-core",
      "content": "Update owned files for the demo change.",
      "verification": "test -f README.md",
      "status": "pending"
    },
    {
      "id": "verify-tests",
      "content": "Run the narrow unit tests.",
      "verification": "true",
      "status": "pending"
    }
  ]
}
EOF
  printf '%s\n' "$dest"
}

write_planfrom_orch() {
  local dest="${1:-$CASE/inputs/planfrom.orch.json}"
  cat >"$dest" <<'ORCH'
{
  "name": "seq-planfrom",
  "namespace": "seq-planfrom",
  "stages": [
    {
      "id": "plan-implementation",
      "runtime": "cursor",
      "planner": {"outputMode": "plan-file", "maxTodos": 40},
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/seq-planfrom/impl-plan.json",
          "required": true,
          "schema": "bundle/.ralph/schemas/planner-output.schema.json"
        }
      ]
    },
    {
      "id": "implement",
      "runtime": "cursor",
      "model": "auto",
      "planFrom": "plan-implementation",
      "artifacts": [
        {"path": ".ralph-workspace/artifacts/seq-planfrom/implementation-handoff.md", "required": true}
      ]
    }
  ]
}
ORCH
  printf '%s\n' "$dest"
}

seed_planfrom_engine() {
  local orch run_id registry_run
  orch="$(write_planfrom_orch)"
  run_id="$(
    workflow_state_create \
      --state-root "$CASE" \
      --source-path "$CASE/inputs/wf.md" \
      --source-kind project \
      --mode sequential \
      --entry-kind task \
      --task "Sequential planFrom fixture" \
      --task-provenance explicit \
      --input-file "$orch" \
      --workflow-id seq-planfrom
  )"
  registry_run="$CASE/workflow-runs/$run_id"
  workflow_seq_init_engine \
    --registry-run "$registry_run" \
    --input-file "$orch" \
    --run-id "$run_id" >/dev/null
  printf '%s\n' "$run_id"
}

materialize_seq_generated_plan() {
  local run_id="$1" attempt="${2:-1}" artifact="${3:-}"
  [[ -n "$artifact" ]] || artifact="$(write_seq_planner_artifact)"
  workflow_state_materialize_generated_plan \
    --registry-run "$CASE/workflow-runs/$run_id" \
    --planner-stage-id plan-implementation \
    --attempt "$attempt" \
    --artifact "$artifact" \
    --max-todos 40 \
    --default-runtime cursor \
    --default-model auto
}

mark_planner_succeeded() {
  local registry_run="$1" attempt="${2:-1}"
  workflow_seq_write_stage \
    --registry-run "$registry_run" \
    --stage-id plan-implementation \
    --state running \
    --attempt "$attempt" \
    --skip-transition-check
  workflow_seq_write_stage \
    --registry-run "$registry_run" \
    --stage-id plan-implementation \
    --state succeeded \
    --terminal-result succeeded \
    --attempt "$attempt"
}

@test "Sequential planFrom control copy binds validated source without mutating it" {
  local run_id registry_run orch artifact source_plan binding control before after

  export WORKFLOW_STATE_FIXED_NOW="2026-08-26T16:00:00Z"
  orch="$(write_planfrom_orch)"
  run_id="$(seed_planfrom_engine)"
  registry_run="$CASE/workflow-runs/$run_id"
  artifact="$(write_seq_planner_artifact)"
  source_plan="$(materialize_seq_generated_plan "$run_id" 1 "$artifact")"
  mark_planner_succeeded "$registry_run" 1
  before="$(cksum "$source_plan" | awk '{print $1" "$2}')"

  run workflow_seq_bind_planfrom_control \
    --registry-run "$registry_run" \
    --orch-path "$orch" \
    --stage-id implement
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  binding="$output"
  control="$(printf '%s' "$binding" | jq -r '.controlPlanPath')"
  [[ "$control" == "$registry_run/plans/implement/attempt-1/control.plan.md" ]]
  [ -f "$control" ]
  [ "$(printf '%s' "$binding" | jq -r '.planSourceKind')" = "generated" ]
  [ "$(printf '%s' "$binding" | jq -r '.planSourceStageId')" = "plan-implementation" ]
  [ "$(printf '%s' "$binding" | jq -r '.sourcePlanPath')" = "$source_plan" ]
  [ "$(printf '%s' "$binding" | jq -r '.createdControl')" = "true" ]
  [ "$(printf '%s' "$binding" | jq -r '.totalTodos')" = "2" ]
  [ "$(printf '%s' "$binding" | jq -r '.completedTodos')" = "0" ]
  [ "$(printf '%s' "$binding" | jq -r '.currentTodoId')" = "implement-core" ]

  [ "$(jq -r '.stages[] | select(.id=="implement") | .plan' "$orch")" = "$control" ]
  [ "$(jq -r '.stages[] | select(.id=="implement") | has("planFrom")' "$orch")" = "false" ]
  [ "$(jq -r '.stages[] | select(.id=="implement") | .sessionStrategy' "$orch")" = "fresh" ]
  [ "$(jq -r '.planSourceKind,.controlPlanPath,.currentTodoId,.completedTodos,.totalTodos' \
    "$registry_run/engine/stages/implement.json" | paste -sd, -)" = \
    "generated,$control,implement-core,0,2" ]

  after="$(cksum "$source_plan" | awk '{print $1" "$2}')"
  [ "$before" = "$after" ]
  [ ! -w "$source_plan" ]
  [ -w "$control" ]
}

@test "invalid plan and missing manifest block Sequential planFrom before control copy" {
  local run_id registry_run orch source_plan

  export WORKFLOW_STATE_FIXED_NOW="2026-08-26T16:01:00Z"
  orch="$(write_planfrom_orch)"
  run_id="$(seed_planfrom_engine)"
  registry_run="$CASE/workflow-runs/$run_id"

  # Planner never succeeded / no manifest.
  run workflow_seq_bind_planfrom_control \
    --registry-run "$registry_run" \
    --orch-path "$orch" \
    --stage-id implement
  [ "$status" -ne 0 ]
  [[ "$output" == *"not succeeded"* ]] || [[ "$output" == *"missing"* ]]
  [ ! -e "$registry_run/plans/implement/attempt-1/control.plan.md" ]

  source_plan="$(materialize_seq_generated_plan "$run_id" 1)"
  mark_planner_succeeded "$registry_run" 1
  # Stale hash: mutate immutable source after publish.
  chmod u+w "$source_plan"
  printf '\n# tampered\n' >>"$source_plan"
  run workflow_seq_bind_planfrom_control \
    --registry-run "$registry_run" \
    --orch-path "$orch" \
    --stage-id implement
  [ "$status" -ne 0 ]
  [[ "$output" == *"hash mismatch"* ]] || [[ "$output" == *"stale"* ]] || [[ "$output" == *"invalid"* ]]
  [ ! -e "$registry_run/plans/implement/attempt-1/control.plan.md" ]
}

@test "same-plan resume reuses Sequential control copy and plan progress advances" {
  local run_id registry_run orch source_plan binding1 binding2 control progress

  export WORKFLOW_STATE_FIXED_NOW="2026-08-26T16:02:00Z"
  orch="$(write_planfrom_orch)"
  run_id="$(seed_planfrom_engine)"
  registry_run="$CASE/workflow-runs/$run_id"
  source_plan="$(materialize_seq_generated_plan "$run_id" 1)"
  mark_planner_succeeded "$registry_run" 1

  binding1="$(
    workflow_seq_bind_planfrom_control \
      --registry-run "$registry_run" \
      --orch-path "$orch" \
      --stage-id implement
  )"
  control="$(printf '%s' "$binding1" | jq -r '.controlPlanPath')"

  # Simulate one completed TODO on the mutable control copy only.
  python3 - "$control" <<'PY'
import re, sys
from pathlib import Path
p = Path(sys.argv[1])
text = p.read_text(encoding="utf-8")
text2, n = re.subn(
    r"(  - id: implement-core\n(?:.*\n)*?    status: )pending",
    r"\1completed",
    text,
    count=1,
)
assert n == 1, "failed to mark implement-core completed"
p.write_text(text2, encoding="utf-8")
PY

  # Refresh progress after a runner-like transition.
  export RALPH_WORKFLOW_REGISTRY_RUN="$registry_run"
  export RALPH_STAGE_ID=implement
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id implement \
    --state running --attempt 1
  workflow_seq_refresh_plan_progress_after_runner "$control"
  [ "$(jq -r '.completedTodos,.currentTodoId' "$registry_run/engine/stages/implement.json" | paste -sd, -)" = \
    "1,verify-tests" ]

  # Resume bind reuses the same control copy.
  binding2="$(
    workflow_seq_bind_planfrom_control \
      --registry-run "$registry_run" \
      --orch-path "$orch" \
      --stage-id implement
  )"
  [ "$(printf '%s' "$binding2" | jq -r '.controlPlanPath')" = "$control" ]
  [ "$(printf '%s' "$binding2" | jq -r '.createdControl')" = "false" ]
  [ "$(printf '%s' "$binding2" | jq -r '.completedTodos')" = "1" ]
  [ "$(printf '%s' "$binding2" | jq -r '.currentTodoId')" = "verify-tests" ]

  progress="$(workflow_state_plan_progress_json "$control")"
  [ "$(printf '%s' "$progress" | jq -r '.completedTodos')" = "1" ]
  [ "$(printf '%s' "$progress" | jq -r '.totalTodos')" = "2" ]
  grep -q 'status: pending' "$source_plan"
  [ ! -w "$source_plan" ]
}

@test "consumer reset force-fresh creates new Sequential control copy from same source" {
  local run_id registry_run orch source_plan binding1 binding2 control before after

  export WORKFLOW_STATE_FIXED_NOW="2026-08-26T16:03:00Z"
  orch="$(write_planfrom_orch)"
  run_id="$(seed_planfrom_engine)"
  registry_run="$CASE/workflow-runs/$run_id"
  source_plan="$(materialize_seq_generated_plan "$run_id" 1)"
  mark_planner_succeeded "$registry_run" 1
  before="$(cksum "$source_plan" | awk '{print $1" "$2}')"

  binding1="$(
    workflow_seq_bind_planfrom_control \
      --registry-run "$registry_run" \
      --orch-path "$orch" \
      --stage-id implement
  )"
  control="$(printf '%s' "$binding1" | jq -r '.controlPlanPath')"
  python3 - "$control" <<'PY'
import re, sys
from pathlib import Path
p = Path(sys.argv[1])
text = p.read_text(encoding="utf-8")
text2, n = re.subn(
    r"(  - id: implement-core\n(?:.*\n)*?    status: )pending",
    r"\1completed",
    text,
    count=1,
)
assert n == 1
p.write_text(text2, encoding="utf-8")
PY
  [ "$(workflow_state_plan_progress_json "$control" | jq -r '.completedTodos')" = "1" ]

  binding2="$(
    workflow_seq_bind_planfrom_control \
      --registry-run "$registry_run" \
      --orch-path "$orch" \
      --stage-id implement \
      --force-fresh
  )"
  [ "$(printf '%s' "$binding2" | jq -r '.controlPlanPath')" = "$control" ]
  [ "$(printf '%s' "$binding2" | jq -r '.createdControl')" = "true" ]
  [ "$(printf '%s' "$binding2" | jq -r '.completedTodos')" = "0" ]
  [ "$(printf '%s' "$binding2" | jq -r '.currentTodoId')" = "implement-core" ]
  [ "$(printf '%s' "$binding2" | jq -r '.sourcePlanPath')" = "$source_plan" ]

  after="$(cksum "$source_plan" | awk '{print $1" "$2}')"
  [ "$before" = "$after" ]
  [ ! -w "$source_plan" ]
}

@test "planner reset causes later Sequential source attempt to win on rebind" {
  local run_id registry_run orch artifact source1 source2 binding1 binding2

  export WORKFLOW_STATE_FIXED_NOW="2026-08-26T16:04:00Z"
  orch="$(write_planfrom_orch)"
  run_id="$(seed_planfrom_engine)"
  registry_run="$CASE/workflow-runs/$run_id"
  artifact="$(write_seq_planner_artifact)"
  source1="$(materialize_seq_generated_plan "$run_id" 1 "$artifact")"
  mark_planner_succeeded "$registry_run" 1

  binding1="$(
    workflow_seq_bind_planfrom_control \
      --registry-run "$registry_run" \
      --orch-path "$orch" \
      --stage-id implement
  )"
  [ "$(printf '%s' "$binding1" | jq -r '.sourcePlanPath')" = "$source1" ]

  # Planner reset publishes attempt-2; engine attempt advances to 2.
  source2="$(materialize_seq_generated_plan "$run_id" 2 "$artifact")"
  mark_planner_succeeded "$registry_run" 2
  [ "$source1" != "$source2" ]
  [ -f "$registry_run/plans/plan-implementation/attempt-2.manifest.json" ]

  binding2="$(
    workflow_seq_bind_planfrom_control \
      --registry-run "$registry_run" \
      --orch-path "$orch" \
      --stage-id implement \
      --consumer-attempt 2 \
      --force-fresh
  )"
  [ "$(printf '%s' "$binding2" | jq -r '.sourcePlanPath')" = "$source2" ]
  [ "$(printf '%s' "$binding2" | jq -r '.controlPlanPath')" = \
    "$registry_run/plans/implement/attempt-2/control.plan.md" ]
  [ "$(printf '%s' "$binding2" | jq -r '.createdControl')" = "true" ]
  [ "$(workflow_seq_resolve_planner_attempt "$registry_run" plan-implementation)" = "2" ]
}

@test "Sequential planFrom stub run-plan argv and plan progress hook" {
  # Cost justification (entry-point): one stubbed orchestrator --single-stage
  # proves planFrom bind projects --plan <control> + --session-strategy fresh
  # and refreshes Sequential progress after the runner. RALPH_WAIT_SCALE=0;
  # no runtime/network/model.
  local workspace orch_file registry_run run_id artifact source_plan control argv_log

  workspace="$(mktemp -d)"
  mkdir -p "$workspace/.ralph/bash-lib/orchestrator" "$workspace/.ralph/python" \
    "$workspace/.ralph-workspace/logs" \
    "$workspace/.ralph-workspace/artifacts/seq-planfrom"
  cp "$REPO_ROOT/.ralph/ralph-env-safety.sh" "$workspace/.ralph/"
  for f in error-handling.sh runtime-resolve.sh runtime-normalize.sh artifacts.sh \
           atomic-json.sh ralph-format-elapsed.sh review-status.sh \
           ralph-process-teardown.sh ralph-process-supervisor.sh; do
    cp "$REPO_ROOT/.ralph/bash-lib/$f" "$workspace/.ralph/bash-lib/" 2>/dev/null || true
  done
  cp "$REPO_ROOT/.ralph/bash-lib/orchestrator/"*.sh "$workspace/.ralph/bash-lib/orchestrator/"
  cp "$REPO_ROOT/.ralph/python/ralph_process_supervisor.py" "$workspace/.ralph/python/" 2>/dev/null || true
  # Intentionally omit workflow-engine-sequential.sh from workspace .ralph so
  # orch_workflow_seq_ensure_lib falls back to REPO_ROOT via RALPH_DIR.
  argv_log="$workspace/run-plan-argv.log"
  cat >"$workspace/.ralph/run-plan.sh" <<STUB
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >"$argv_log"
# Advance one TODO on the control plan passed via --plan.
plan=""
prev=""
for arg in "\$@"; do
  if [[ "\$prev" == "--plan" ]]; then
    plan="\$arg"
  fi
  prev="\$arg"
done
if [[ -n "\$plan" && -f "\$plan" ]]; then
  python3 - "\$plan" <<'PY'
import re, sys
from pathlib import Path
p = Path(sys.argv[1])
text = p.read_text(encoding="utf-8")
text2, n = re.subn(
    r"(  - id: implement-core\\n(?:.*\\n)*?    status: )pending",
    r"\\1completed",
    text,
    count=1,
)
if n == 1:
    p.write_text(text2, encoding="utf-8")
PY
fi
printf 'stub run-plan ok\n'
exit 0
STUB
  chmod +x "$workspace/.ralph/run-plan.sh"
  printf 'handoff\n' >"$workspace/.ralph-workspace/artifacts/seq-planfrom/implementation-handoff.md"

  orch_file="$workspace/planfrom.orch.json"
  cat >"$orch_file" <<'ORCH'
{
  "name": "seq-planfrom-hook",
  "namespace": "seq-planfrom",
  "stages": [
    {
      "id": "plan-implementation",
      "runtime": "cursor",
      "planner": {"outputMode": "plan-file", "maxTodos": 40},
      "artifacts": [
        {
          "path": ".ralph-workspace/artifacts/seq-planfrom/impl-plan.json",
          "required": true,
          "schema": "bundle/.ralph/schemas/planner-output.schema.json"
        }
      ]
    },
    {
      "id": "implement",
      "runtime": "cursor",
      "model": "auto",
      "planFrom": "plan-implementation",
      "artifacts": [
        {"path": ".ralph-workspace/artifacts/seq-planfrom/implementation-handoff.md", "required": true}
      ]
    }
  ]
}
ORCH

  export WORKFLOW_STATE_SKIP_FSYNC=1
  export WORKFLOW_STATE_FIXED_NOW="2026-08-26T16:05:00Z"
  # shellcheck source=/dev/null
  source "$STATE_LIB"
  # shellcheck source=/dev/null
  source "$SEQ_LIB"

  mkdir -p "$workspace/.ralph-workspace/workflow-inputs"
  cp "$orch_file" "$workspace/.ralph-workspace/workflow-inputs/planfrom.orch.json"
  printf '%s\n' '---' 'kind: workflow' 'mode: sequential' '---' \
    >"$workspace/.ralph-workspace/workflow-inputs/wf.md"

  run_id="$(
    workflow_state_create \
      --state-root "$workspace/.ralph-workspace" \
      --source-path "$workspace/.ralph-workspace/workflow-inputs/wf.md" \
      --source-kind project \
      --mode sequential \
      --entry-kind task \
      --task "planFrom hook" \
      --task-provenance explicit \
      --input-file "$workspace/.ralph-workspace/workflow-inputs/planfrom.orch.json" \
      --workflow-id seq-planfrom-hook
  )"
  registry_run="$workspace/.ralph-workspace/workflow-runs/$run_id"
  workflow_seq_init_engine \
    --registry-run "$registry_run" \
    --input-file "$workspace/.ralph-workspace/workflow-inputs/planfrom.orch.json" \
    --run-id "$run_id"

  artifact="$(write_seq_planner_artifact "$workspace/artifacts/planner.json")"
  source_plan="$(
    workflow_state_materialize_generated_plan \
      --registry-run "$registry_run" \
      --planner-stage-id plan-implementation \
      --attempt 1 \
      --artifact "$artifact" \
      --max-todos 40 \
      --default-runtime cursor \
      --default-model auto
  )"
  mark_planner_succeeded "$registry_run" 1
  # Planner prerequisite marked succeeded so implement may run; artifact file present.
  printf '%s\n' "$(cat "$artifact")" \
    >"$workspace/.ralph-workspace/artifacts/seq-planfrom/impl-plan.json"
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id plan-implementation \
    --state succeeded --terminal-result succeeded --attempt 1 \
    --artifacts-json '[".ralph-workspace/artifacts/seq-planfrom/impl-plan.json"]' \
    --skip-transition-check

  run env RALPH_ALLOW_NESTED_RUNS=1 RALPH_WAIT_SCALE=0 RALPH_ARTIFACT_SCHEMA_VALIDATION=0 \
    RALPH_WORKFLOW_REGISTRY_RUN="$registry_run" \
    RALPH_WORKFLOW_RUN_ID="$run_id" \
    WORKFLOW_STATE_SKIP_FSYNC=1 \
    WORKFLOW_SEQ_SKIP_FSYNC=1 \
    bash "$REPO_ROOT/.ralph/orchestrator.sh" \
      --orchestration "$orch_file" \
      --single-stage implement \
      --run-id "$run_id" \
      --attempt-id "attempt-1" \
      "$workspace" 2>&1
  [ "$status" -eq 0 ] || { echo "$output"; rm -rf "$workspace"; return 1; }

  control="$registry_run/plans/implement/attempt-1/control.plan.md"
  [ -f "$control" ]
  [ -f "$argv_log" ]
  # macOS may surface /var vs /private/var; match the durable suffix.
  grep -Eq -- '--plan .*/plans/implement/attempt-1/control\.plan\.md( |$)' "$argv_log"
  grep -Fq -- "--session-strategy fresh" "$argv_log"
  [[ "$(jq -r '.stages[] | select(.id=="implement") | .plan' "$orch_file")" == *"/plans/implement/attempt-1/control.plan.md" ]]
  [ "$(jq -r '.completedTodos,.currentTodoId,.planSourceKind' \
    "$registry_run/engine/stages/implement.json" | paste -sd, -)" = \
    "1,verify-tests,generated" ]
  [[ "$(jq -r '.controlPlanPath' "$registry_run/engine/stages/implement.json")" == *"/plans/implement/attempt-1/control.plan.md" ]]
  [ "$(jq -r '.state,.terminalResult' "$registry_run/engine/stages/implement.json" | paste -sd, -)" = \
    "succeeded,succeeded" ]
  [ ! -w "$source_plan" ]

  ralph_test_rm_workspace "$workspace"
}

# --- Sequential provided plan (planInput) control copy / routing / resume ---
# Contracts: designated-stage bind, source kind provided/null producer, routing
# order, control copy, same-plan resume, consumer reset, original unchanged,
# invalid input refusal. Level: sourced functions + one stub run-plan hook.
# Never invokes a model or full orchestration journey.

ROUTING_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/workflow/workflow-routing.sh"

write_seq_provided_leaf_plan() {
  local dest="${1:-$CASE/project/plans/feature.plan.md}"
  local body="${2:-}"
  mkdir -p "$(dirname -- "$dest")"
  if [[ -n "$body" ]]; then
    printf '%s' "$body" >"$dest"
  else
    cat >"$dest" <<'EOF'
# Feature plan

- [x] already done by operator
- [ ] implement the change
- [ ] verify the change
EOF
  fi
  printf '%s\n' "$dest"
}

write_provided_orch() {
  local dest="${1:-$CASE/inputs/provided.orch.json}"
  cat >"$dest" <<'ORCH'
{
  "name": "seq-provided",
  "namespace": "seq-provided",
  "stages": [
    {
      "id": "implement",
      "runtime": "cursor",
      "model": "stage-model",
      "artifacts": [
        {"path": ".ralph-workspace/artifacts/seq-provided/implementation-handoff.md", "required": true}
      ]
    },
    {
      "id": "review",
      "runtime": "cursor",
      "instructions": "Review the implementation handoff only.",
      "artifacts": [
        {"path": ".ralph-workspace/artifacts/seq-provided/review-notes.md", "required": true}
      ]
    }
  ]
}
ORCH
  printf '%s\n' "$dest"
}

seed_provided_engine() {
  local orch run_id registry_run
  orch="$(write_provided_orch)"
  run_id="$(
    workflow_state_create \
      --state-root "$CASE" \
      --source-path "$CASE/inputs/wf.md" \
      --source-kind project \
      --mode sequential \
      --entry-kind plan \
      --task "Execute the supplied feature plan" \
      --task-provenance plan-overview \
      --input-file "$orch" \
      --workflow-id plan-delivery
  )"
  registry_run="$CASE/workflow-runs/$run_id"
  workflow_seq_init_engine \
    --registry-run "$registry_run" \
    --input-file "$orch" \
    --run-id "$run_id" >/dev/null
  # Caller must export RALPH_WORKFLOW_PLAN_INPUT_STAGE in the parent shell;
  # this helper often runs under command substitution where exports are lost.
  printf '%s\n' "$run_id"
}

import_seq_provided() {
  local run_id="$1"
  local plan_body="${2:-}"
  local plan_path source_path
  mkdir -p "$CASE/project/plans"
  if [[ -n "$plan_body" ]]; then
    plan_path="$(write_seq_provided_leaf_plan "$CASE/project/plans/feature.plan.md" "$plan_body")"
  else
    plan_path="$(write_seq_provided_leaf_plan "$CASE/project/plans/feature.plan.md")"
  fi
  workflow_state_import_provided_plan \
    --state-root "$CASE" \
    --run-id "$run_id" \
    --plan "$plan_path" \
    --project-root "$CASE/project" >/dev/null
  source_path="$CASE/workflow-runs/$run_id/plans/input/source.plan.md"
  printf '%s\n' "$source_path"
}

@test "Sequential provided plan control copy binds with source kind provided and null producer" {
  # shellcheck source=/dev/null
  source "$ROUTING_LIB"
  local run_id registry_run orch source_plan binding control before after original

  export WORKFLOW_STATE_FIXED_NOW="2026-08-26T17:00:00Z"
  orch="$(write_provided_orch)"
  run_id="$(seed_provided_engine)"
  workflow_seq_set_plan_input_stage implement
  registry_run="$CASE/workflow-runs/$run_id"
  source_plan="$(import_seq_provided "$run_id")"
  original="$(jq -r '.originalPath' "$registry_run/plans/input/manifest.json")"
  before="$(cksum "$source_plan" | awk '{print $1" "$2}')"
  before_orig="$(cksum "$original" | awk '{print $1" "$2}')"

  run workflow_seq_bind_provided_plan_control \
    --registry-run "$registry_run" \
    --orch-path "$orch" \
    --stage-id implement
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  binding="$output"
  control="$(printf '%s' "$binding" | jq -r '.controlPlanPath')"
  [[ "$control" == "$registry_run/plans/implement/attempt-1/control.plan.md" ]]
  [ -f "$control" ]
  [ "$(printf '%s' "$binding" | jq -r '.planSourceKind')" = "provided" ]
  [ "$(printf '%s' "$binding" | jq -r '.planSourceStageId')" = "null" ]
  [ "$(printf '%s' "$binding" | jq -r '.sourcePlanPath')" = "$source_plan" ]
  [ "$(printf '%s' "$binding" | jq -r '.originalPlanPath')" = "$original" ]
  [ "$(printf '%s' "$binding" | jq -r '.createdControl')" = "true" ]
  [ "$(printf '%s' "$binding" | jq -r '.totalTodos')" = "3" ]
  [ "$(printf '%s' "$binding" | jq -r '.completedTodos')" = "1" ]
  [ "$(printf '%s' "$binding" | jq -r '.currentTodoId')" = "todo-2" ]

  [ "$(jq -r '.stages[] | select(.id=="implement") | .plan' "$orch")" = "$control" ]
  [ "$(jq -r '.stages[] | select(.id=="implement") | .sessionStrategy' "$orch")" = "fresh" ]
  # Non-designated stage must not receive the provided plan.
  [ "$(jq -r '.stages[] | select(.id=="review") | .plan // empty' "$orch")" = "" ]

  [ "$(jq -r '.planSourceKind,.planSourceStageId,.originalPlanPath,.controlPlanPath,.completedTodos,.totalTodos' \
    "$registry_run/engine/stages/implement.json" | paste -sd, -)" = \
    "provided,null,$original,$control,1,3" ]

  after="$(cksum "$source_plan" | awk '{print $1" "$2}')"
  after_orig="$(cksum "$original" | awk '{print $1" "$2}')"
  [ "$before" = "$after" ]
  [ "$before_orig" = "$after_orig" ]
  [ ! -w "$source_plan" ]
  [ -w "$control" ]
}

@test "invalid input missing or corrupt Sequential provided plan blocks before control copy" {
  local run_id registry_run orch

  export WORKFLOW_STATE_FIXED_NOW="2026-08-26T17:01:00Z"
  orch="$(write_provided_orch)"
  run_id="$(seed_provided_engine)"
  workflow_seq_set_plan_input_stage implement
  registry_run="$CASE/workflow-runs/$run_id"

  run workflow_seq_bind_provided_plan_control \
    --registry-run "$registry_run" \
    --orch-path "$orch" \
    --stage-id implement
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid input"* ]] || [[ "$output" == *"missing"* ]]
  [ ! -e "$registry_run/plans/implement/attempt-1/control.plan.md" ]

  import_seq_provided "$run_id" >/dev/null
  chmod u+w "$registry_run/plans/input/source.plan.md"
  printf '\n# corrupted\n' >>"$registry_run/plans/input/source.plan.md"
  run workflow_seq_bind_provided_plan_control \
    --registry-run "$registry_run" \
    --orch-path "$orch" \
    --stage-id implement
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid input"* ]] || [[ "$output" == *"hash mismatch"* ]] || [[ "$output" == *"stale"* ]]
  [ ! -e "$registry_run/plans/implement/attempt-1/control.plan.md" ]
}

@test "Sequential provided plan routing order prefers stage over provided-plan header" {
  # shellcheck source=/dev/null
  source "$ROUTING_LIB"
  local run_id registry_run orch source_plan binding

  export WORKFLOW_STATE_FIXED_NOW="2026-08-26T17:02:00Z"
  orch="$(write_provided_orch)"
  run_id="$(seed_provided_engine)"
  workflow_seq_set_plan_input_stage implement
  registry_run="$CASE/workflow-runs/$run_id"
  source_plan="$(import_seq_provided "$run_id" "$(cat <<'EOF'
---
name: Provided Feature
overview: Ship it
runtime: claude
model: plan-header-model
todos:
  - id: one
    content: Do one
    verification: Check one
    status: pending
  - id: two
    content: Do two
    verification: Check two
    status: pending
---
EOF
)")"

  binding="$(
    workflow_seq_bind_provided_plan_control \
      --registry-run "$registry_run" \
      --orch-path "$orch" \
      --stage-id implement
  )"
  [ "$(printf '%s' "$binding" | jq -r '.planSourceKind')" = "provided" ]
  # Stage pins beat provided-plan header.
  [ "$(jq -r '.stages[] | select(.id=="implement") | .runtime' "$orch")" = "cursor" ]
  [ "$(jq -r '.stages[] | select(.id=="implement") | .model' "$orch")" = "stage-model" ]

  # Clear stage pins so provided-plan header participates via routing helper.
  jq '.stages |= map(if .id == "implement" then del(.runtime, .model) else . end)' "$orch" \
    >"$orch.tmp" && mv "$orch.tmp" "$orch"
  # Sanity: clearing pins must not null out sibling stages.
  [ "$(jq -r '.stages | length' "$orch")" = "2" ]
  [ "$(jq -r '.stages[] | select(.id=="implement") | .runtime // empty' "$orch")" = "" ]
  workflow_seq_apply_provided_routing_order "$orch" implement "$source_plan"
  [ "$(jq -r '.stages[] | select(.id=="implement") | .runtime' "$orch")" = "claude" ]
  [ "$(jq -r '.stages[] | select(.id=="implement") | .model' "$orch")" = "plan-header-model" ]
  # Non-consumer review stage remains untouched.
  [ "$(jq -r '.stages[] | select(.id=="review") | .runtime' "$orch")" = "cursor" ]
}

@test "same-plan resume reuses Sequential provided control copy and original unchanged" {
  local run_id registry_run orch source_plan binding1 binding2 control before after original

  export WORKFLOW_STATE_FIXED_NOW="2026-08-26T17:03:00Z"
  orch="$(write_provided_orch)"
  run_id="$(seed_provided_engine)"
  workflow_seq_set_plan_input_stage implement
  registry_run="$CASE/workflow-runs/$run_id"
  source_plan="$(import_seq_provided "$run_id")"
  original="$(jq -r '.originalPath' "$registry_run/plans/input/manifest.json")"
  before="$(cksum "$source_plan" | awk '{print $1" "$2}')"
  before_orig="$(cksum "$original" | awk '{print $1" "$2}')"

  binding1="$(
    workflow_seq_bind_provided_plan_control \
      --registry-run "$registry_run" \
      --orch-path "$orch" \
      --stage-id implement
  )"
  control="$(printf '%s' "$binding1" | jq -r '.controlPlanPath')"

  python3 - "$control" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
text = p.read_text(encoding="utf-8")
text2, n = re.subn(r"- \[ \] implement the change", "- [x] implement the change", text, count=1)
assert n == 1
p.write_text(text2, encoding="utf-8")
PY

  export RALPH_WORKFLOW_REGISTRY_RUN="$registry_run"
  export RALPH_STAGE_ID=implement
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id implement \
    --state running --attempt 1
  workflow_seq_refresh_plan_progress_after_runner "$control"
  [ "$(jq -r '.completedTodos' "$registry_run/engine/stages/implement.json")" = "2" ]

  binding2="$(
    workflow_seq_bind_provided_plan_control \
      --registry-run "$registry_run" \
      --orch-path "$orch" \
      --stage-id implement
  )"
  [ "$(printf '%s' "$binding2" | jq -r '.controlPlanPath')" = "$control" ]
  [ "$(printf '%s' "$binding2" | jq -r '.createdControl')" = "false" ]
  [ "$(printf '%s' "$binding2" | jq -r '.completedTodos')" = "2" ]
  [ "$(printf '%s' "$binding2" | jq -r '.planSourceKind')" = "provided" ]
  [ "$(printf '%s' "$binding2" | jq -r '.planSourceStageId')" = "null" ]

  after="$(cksum "$source_plan" | awk '{print $1" "$2}')"
  after_orig="$(cksum "$original" | awk '{print $1" "$2}')"
  [ "$before" = "$after" ]
  [ "$before_orig" = "$after_orig" ]
  [ ! -w "$source_plan" ]
}

@test "consumer reset force-fresh creates new Sequential provided control copy from same source" {
  local run_id registry_run orch source_plan binding1 binding2 control before after

  export WORKFLOW_STATE_FIXED_NOW="2026-08-26T17:04:00Z"
  orch="$(write_provided_orch)"
  run_id="$(seed_provided_engine)"
  workflow_seq_set_plan_input_stage implement
  registry_run="$CASE/workflow-runs/$run_id"
  source_plan="$(import_seq_provided "$run_id")"
  before="$(cksum "$source_plan" | awk '{print $1" "$2}')"

  binding1="$(
    workflow_seq_bind_provided_plan_control \
      --registry-run "$registry_run" \
      --orch-path "$orch" \
      --stage-id implement
  )"
  control="$(printf '%s' "$binding1" | jq -r '.controlPlanPath')"
  python3 - "$control" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
text = p.read_text(encoding="utf-8")
text2, n = re.subn(r"- \[ \] implement the change", "- [x] implement the change", text, count=1)
assert n == 1
p.write_text(text2, encoding="utf-8")
PY
  [ "$(workflow_state_plan_progress_json "$control" | jq -r '.completedTodos')" = "2" ]

  binding2="$(
    workflow_seq_bind_provided_plan_control \
      --registry-run "$registry_run" \
      --orch-path "$orch" \
      --stage-id implement \
      --force-fresh
  )"
  [ "$(printf '%s' "$binding2" | jq -r '.controlPlanPath')" = "$control" ]
  [ "$(printf '%s' "$binding2" | jq -r '.createdControl')" = "true" ]
  [ "$(printf '%s' "$binding2" | jq -r '.completedTodos')" = "1" ]
  [ "$(printf '%s' "$binding2" | jq -r '.sourcePlanPath')" = "$source_plan" ]
  [ "$(printf '%s' "$binding2" | jq -r '.planSourceKind')" = "provided" ]
  grep -q '\- \[ \] implement the change' "$control"

  after="$(cksum "$source_plan" | awk '{print $1" "$2}')"
  [ "$before" = "$after" ]
  [ ! -w "$source_plan" ]
}

@test "Sequential provided plan stub run-plan argv and plan progress hook" {
  # Cost justification (entry-point): one stubbed orchestrator --single-stage
  # proves provided-plan bind projects --plan <control> + --session-strategy fresh
  # and refreshes Sequential progress after the runner. RALPH_WAIT_SCALE=0;
  # no runtime/network/model.
  local workspace orch_file registry_run run_id source_plan control argv_log

  workspace="$(mktemp -d)"
  mkdir -p "$workspace/.ralph/bash-lib/orchestrator" "$workspace/.ralph/python" \
    "$workspace/.ralph-workspace/logs" \
    "$workspace/.ralph-workspace/artifacts/seq-provided" \
    "$workspace/project/plans"
  cp "$REPO_ROOT/.ralph/ralph-env-safety.sh" "$workspace/.ralph/"
  for f in error-handling.sh runtime-resolve.sh runtime-normalize.sh artifacts.sh \
           atomic-json.sh ralph-format-elapsed.sh review-status.sh \
           ralph-process-teardown.sh ralph-process-supervisor.sh; do
    cp "$REPO_ROOT/.ralph/bash-lib/$f" "$workspace/.ralph/bash-lib/" 2>/dev/null || true
  done
  cp "$REPO_ROOT/.ralph/bash-lib/orchestrator/"*.sh "$workspace/.ralph/bash-lib/orchestrator/"
  cp "$REPO_ROOT/.ralph/python/ralph_process_supervisor.py" "$workspace/.ralph/python/" 2>/dev/null || true
  argv_log="$workspace/run-plan-argv.log"
  cat >"$workspace/.ralph/run-plan.sh" <<STUB
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >"$argv_log"
plan=""
prev=""
for arg in "\$@"; do
  if [[ "\$prev" == "--plan" ]]; then
    plan="\$arg"
  fi
  prev="\$arg"
done
if [[ -n "\$plan" && -f "\$plan" ]]; then
  python3 - "\$plan" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
text = p.read_text(encoding="utf-8")
text2, n = re.subn(r"- \[ \] implement the change", "- [x] implement the change", text, count=1)
if n == 1:
    p.write_text(text2, encoding="utf-8")
PY
fi
printf 'stub run-plan ok\n'
exit 0
STUB
  chmod +x "$workspace/.ralph/run-plan.sh"
  printf 'handoff\n' >"$workspace/.ralph-workspace/artifacts/seq-provided/implementation-handoff.md"

  orch_file="$workspace/provided.orch.json"
  cat >"$orch_file" <<'ORCH'
{
  "name": "seq-provided-hook",
  "namespace": "seq-provided",
  "stages": [
    {
      "id": "implement",
      "runtime": "cursor",
      "model": "auto",
      "artifacts": [
        {"path": ".ralph-workspace/artifacts/seq-provided/implementation-handoff.md", "required": true}
      ]
    }
  ]
}
ORCH

  export WORKFLOW_STATE_SKIP_FSYNC=1
  export WORKFLOW_STATE_FIXED_NOW="2026-08-26T17:05:00Z"
  # shellcheck source=/dev/null
  source "$STATE_LIB"
  # shellcheck source=/dev/null
  source "$SEQ_LIB"

  mkdir -p "$workspace/.ralph-workspace/workflow-inputs"
  cp "$orch_file" "$workspace/.ralph-workspace/workflow-inputs/provided.orch.json"
  printf '%s\n' '---' 'kind: workflow' 'mode: sequential' '---' \
    >"$workspace/.ralph-workspace/workflow-inputs/wf.md"

  write_seq_provided_leaf_plan "$workspace/project/plans/feature.plan.md" >/dev/null

  run_id="$(
    workflow_state_create \
      --state-root "$workspace/.ralph-workspace" \
      --source-path "$workspace/.ralph-workspace/workflow-inputs/wf.md" \
      --source-kind project \
      --mode sequential \
      --entry-kind plan \
      --task "provided hook" \
      --task-provenance plan-overview \
      --input-file "$workspace/.ralph-workspace/workflow-inputs/provided.orch.json" \
      --workflow-id seq-provided-hook
  )"
  registry_run="$workspace/.ralph-workspace/workflow-runs/$run_id"
  workflow_seq_init_engine \
    --registry-run "$registry_run" \
    --input-file "$workspace/.ralph-workspace/workflow-inputs/provided.orch.json" \
    --run-id "$run_id"
  workflow_seq_set_plan_input_stage implement

  source_plan="$(
    workflow_state_import_provided_plan \
      --state-root "$workspace/.ralph-workspace" \
      --run-id "$run_id" \
      --plan "$workspace/project/plans/feature.plan.md" \
      --project-root "$workspace/project"
  )"

  run env RALPH_ALLOW_NESTED_RUNS=1 RALPH_WAIT_SCALE=0 RALPH_ARTIFACT_SCHEMA_VALIDATION=0 \
    RALPH_WORKFLOW_REGISTRY_RUN="$registry_run" \
    RALPH_WORKFLOW_RUN_ID="$run_id" \
    RALPH_WORKFLOW_PLAN_INPUT_STAGE=implement \
    WORKFLOW_STATE_SKIP_FSYNC=1 \
    WORKFLOW_SEQ_SKIP_FSYNC=1 \
    bash "$REPO_ROOT/.ralph/orchestrator.sh" \
      --orchestration "$orch_file" \
      --single-stage implement \
      --run-id "$run_id" \
      --attempt-id "attempt-1" \
      "$workspace" 2>&1
  [ "$status" -eq 0 ] || { echo "$output"; rm -rf "$workspace"; return 1; }

  control="$registry_run/plans/implement/attempt-1/control.plan.md"
  [ -f "$control" ]
  [ -f "$argv_log" ]
  grep -Eq -- '--plan .*/plans/implement/attempt-1/control\.plan\.md( |$)' "$argv_log"
  grep -Fq -- "--session-strategy fresh" "$argv_log"
  [[ "$(jq -r '.stages[] | select(.id=="implement") | .plan' "$orch_file")" == *"/plans/implement/attempt-1/control.plan.md" ]]
  [ "$(jq -r '.completedTodos,.planSourceKind,.planSourceStageId' \
    "$registry_run/engine/stages/implement.json" | paste -sd, -)" = \
    "2,provided,null" ]
  [[ "$(jq -r '.controlPlanPath' "$registry_run/engine/stages/implement.json")" == *"/plans/implement/attempt-1/control.plan.md" ]]
  [ "$(jq -r '.state,.terminalResult' "$registry_run/engine/stages/implement.json" | paste -sd, -)" = \
    "succeeded,succeeded" ]
  [ ! -w "$source_plan" ]

  ralph_test_rm_workspace "$workspace"
}

# --- Sequential approval (common actions; stub orch; no runtime) ------------

@test "Sequential approval activate waiting exit 3 no runtime and consume once approve" {
  local run_id registry_run activation request_id attempt_id result
  local loop_before waves_before
  run_id="$(seed_engine)"
  registry_run="$CASE/workflow-runs/$run_id"
  mkdir -p "$CASE/.ralph-workspace/artifacts/seq-lifecycle"
  printf 'investigation ok\n' >"$CASE/.ralph-workspace/artifacts/seq-lifecycle/investigation.md"

  # Upstream succeeded; preserve loop/wave before parking the gate.
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id investigate --state running --attempt 1
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id investigate --state succeeded \
    --terminal-result succeeded \
    --artifacts-json '[".ralph-workspace/artifacts/seq-lifecycle/investigation.md"]'
  workflow_seq_update_run \
    --registry-run "$registry_run" \
    --state running \
    --loop-iterations 2 \
    --completed-waves 1 \
    --current-stage-ids-json '["approve-plan"]' \
    --owner-json "$(_workflow_seq_live_owner_json)"
  loop_before="$(jq -r '.loopIterations' "$registry_run/engine/run.json")"
  waves_before="$(jq -r '.completedWaves' "$registry_run/engine/run.json")"

  activation="$(workflow_seq_approval_activate \
    --workspace "$CASE" \
    --namespace seq-lifecycle \
    --run-id "$run_id" \
    --registry-run "$registry_run" \
    --stage-id approve-plan \
    --attempt-id "approve-plan-1" \
    --orch-json "$CASE/inputs/sample.orch.json" \
    --state-root "$CASE")"
  [ "$(printf '%s' "$activation" | jq -r '.blocker.reasonCode')" = "human-approval" ]
  [ "$(jq -r '.state' "$registry_run/engine/stages/approve-plan.json")" = "waiting" ]
  [ "$(jq -r '.state' "$registry_run/engine/run.json")" = "waiting" ]
  [ "$(jq -r '.owner.pid' "$registry_run/engine/run.json")" = "null" ]
  [ "$(jq -r '.state' "$registry_run/run.json")" = "waiting" ]
  [ "$(jq -r '.loopIterations,.completedWaves' "$registry_run/engine/run.json" | paste -sd, -)" = "${loop_before},${waves_before}" ]
  [ "$(find "$registry_run/actions/requests" -name '*.json' | wc -l | tr -d ' ')" = "1" ]

  # Gate is not skippable while waiting; a synthetic higher-index successor
  # cannot satisfy prerequisites until the gate succeeds.
  ! workflow_seq_stage_should_skip "$registry_run" approve-plan
  mkdir -p "$registry_run/engine/stages"
  jq -cn '{
    id:"after-gate", index:99, state:"queued", attempt:0,
    planPath:null, planRunId:null, planSourceKind:null, planSourceStageId:null,
    originalPlanPath:null, sourcePlanPath:null, controlPlanPath:null,
    currentTodoId:null, completedTodos:0, totalTodos:0, wave:null,
    terminalResult:null, blocker:null, artifacts:[],
    createdAt:"2026-08-26T15:00:00Z", updatedAt:"2026-08-26T15:00:00Z"
  }' >"$registry_run/engine/stages/after-gate.json"
  ! workflow_seq_prerequisites_satisfied "$registry_run" after-gate

  # Duplicate outstanding request fails closed.
  run workflow_seq_approval_activate \
    --workspace "$CASE" \
    --namespace seq-lifecycle \
    --run-id "$run_id" \
    --registry-run "$registry_run" \
    --stage-id approve-plan \
    --attempt-id "approve-plan-1" \
    --orch-json "$CASE/inputs/sample.orch.json" \
    --state-root "$CASE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"duplicate"* ]]
  [ "$(find "$registry_run/actions/requests" -name '*.json' | wc -l | tr -d ' ')" = "1" ]

  request_id="$(printf '%s' "$activation" | jq -r '.requestId')"
  attempt_id="approve-plan-1"
  # shellcheck source=/dev/null
  source "$ACTIONS_LIB"
  workflow_action_decision_write "$registry_run" "$(jq -nc \
    --arg rid "$request_id" --arg aid "$attempt_id" --arg runId "$run_id" '{
      requestId:$rid, kind:"approval", runId:$runId, stageId:"approve-plan",
      attemptId:$aid, decision:"approve", actorSource:"human",
      decidedAt:"2026-08-26T15:05:00Z"
    }')" >/dev/null

  result="$(workflow_seq_approval_apply_decision \
    --registry-run "$registry_run" --request-id "$request_id" \
    --run-id "$run_id" --state-root "$CASE" --stage-id approve-plan)"
  [ "$(printf '%s' "$result" | jq -r '.outcome,.nodeState' | paste -sd, -)" = "approved,succeeded" ]
  [ "$(jq -r '.state,.terminalResult' "$registry_run/engine/stages/approve-plan.json" | paste -sd, -)" = "succeeded,succeeded" ]
  [ -f "$registry_run/actions/consumed/$request_id.json" ]
  [ "$(jq -r '.loopIterations,.completedWaves' "$registry_run/engine/run.json" | paste -sd, -)" = "${loop_before},${waves_before}" ]

  # Consume once: second apply refuses.
  run workflow_seq_approval_apply_decision \
    --registry-run "$registry_run" --request-id "$request_id" \
    --run-id "$run_id" --state-root "$CASE" --stage-id approve-plan
  [ "$status" -ne 0 ]
  [ "$(find "$registry_run/actions/consumed" -name '*.json' | wc -l | tr -d ' ')" = "1" ]
}

@test "Sequential approval request changes changesTarget reset argv cancel and retained feedback" {
  local run_id registry_run activation request_id result
  run_id="$(seed_engine)"
  registry_run="$CASE/workflow-runs/$run_id"
  mkdir -p "$CASE/.ralph-workspace/artifacts/seq-lifecycle"
  printf 'investigation ok\n' >"$CASE/.ralph-workspace/artifacts/seq-lifecycle/investigation.md"
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id investigate --state running --attempt 1
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id investigate --state succeeded \
    --terminal-result succeeded \
    --artifacts-json '[".ralph-workspace/artifacts/seq-lifecycle/investigation.md"]'

  activation="$(workflow_seq_approval_activate \
    --workspace "$CASE" --namespace seq-lifecycle --run-id "$run_id" \
    --registry-run "$registry_run" --stage-id approve-plan --attempt-id "approve-plan-1" \
    --orch-json "$CASE/inputs/sample.orch.json" --state-root "$CASE")"
  request_id="$(printf '%s' "$activation" | jq -r '.requestId')"
  # shellcheck source=/dev/null
  source "$ACTIONS_LIB"
  workflow_action_decision_write "$registry_run" "$(jq -nc \
    --arg rid "$request_id" --arg runId "$run_id" '{
      requestId:$rid, kind:"approval", runId:$runId, stageId:"approve-plan",
      attemptId:"approve-plan-1", decision:"request-changes", actorSource:"human",
      decidedAt:"2026-08-26T15:05:00Z", message:"Tighten acceptance criteria."
    }')" >/dev/null

  result="$(workflow_seq_approval_apply_decision \
    --registry-run "$registry_run" --request-id "$request_id" \
    --run-id "$run_id" --state-root "$CASE" --stage-id approve-plan)"
  [ "$(printf '%s' "$result" | jq -r '.outcome,.nodeState' | paste -sd, -)" = "changes-requested,blocked" ]
  [ "$(printf '%s' "$result" | jq -c '.nextAction.argv')" = "[\"ralph\",\"workflow\",\"reset\",\"$run_id\",\"--stage\",\"investigate\"]" ]
  [ "$(printf '%s' "$result" | jq -r '.message,.blocker.feedback' | paste -sd, -)" = "Tighten acceptance criteria.,Tighten acceptance criteria." ]
  [ "$(jq -r '.state' "$registry_run/engine/stages/approve-plan.json")" = "blocked" ]
  [ "$(jq -r '.blocker.reasonCode,.blocker.changesTarget' "$registry_run/engine/stages/approve-plan.json" | paste -sd, -)" = "human-changes-requested,investigate" ]
  [ "$(jq -r '.state' "$registry_run/run.json")" = "blocked" ]
  # Higher-index successor still cannot pass the blocked gate.
  ! workflow_seq_prerequisites_satisfied "$registry_run" after-gate 2>/dev/null || {
    jq -cn '{
      id:"after-gate", index:99, state:"queued", attempt:0,
      planPath:null, planRunId:null, planSourceKind:null, planSourceStageId:null,
      originalPlanPath:null, sourcePlanPath:null, controlPlanPath:null,
      currentTodoId:null, completedTodos:0, totalTodos:0, wave:null,
      terminalResult:null, blocker:null, artifacts:[],
      createdAt:"2026-08-26T15:00:00Z", updatedAt:"2026-08-26T15:00:00Z"
    }' >"$registry_run/engine/stages/after-gate.json"
    ! workflow_seq_prerequisites_satisfied "$registry_run" after-gate
  }

  # Cancel path on a fresh run.
  run_id="$(seed_engine)"
  registry_run="$CASE/workflow-runs/$run_id"
  mkdir -p "$CASE/.ralph-workspace/artifacts/seq-lifecycle"
  printf 'investigation ok\n' >"$CASE/.ralph-workspace/artifacts/seq-lifecycle/investigation.md"
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id investigate --state running --attempt 1
  workflow_seq_write_stage --registry-run "$registry_run" --stage-id investigate --state succeeded \
    --terminal-result succeeded \
    --artifacts-json '[".ralph-workspace/artifacts/seq-lifecycle/investigation.md"]'
  activation="$(workflow_seq_approval_activate \
    --workspace "$CASE" --namespace seq-lifecycle --run-id "$run_id" \
    --registry-run "$registry_run" --stage-id approve-plan --attempt-id "approve-plan-1" \
    --orch-json "$CASE/inputs/sample.orch.json" --state-root "$CASE")"
  request_id="$(printf '%s' "$activation" | jq -r '.requestId')"
  workflow_action_decision_write "$registry_run" "$(jq -nc \
    --arg rid "$request_id" --arg runId "$run_id" '{
      requestId:$rid, kind:"approval", runId:$runId, stageId:"approve-plan",
      attemptId:"approve-plan-1", decision:"cancel", actorSource:"human",
      decidedAt:"2026-08-26T15:06:00Z"
    }')" >/dev/null
  result="$(workflow_seq_approval_apply_decision \
    --registry-run "$registry_run" --request-id "$request_id" \
    --run-id "$run_id" --state-root "$CASE" --stage-id approve-plan)"
  [ "$(printf '%s' "$result" | jq -r '.outcome,.nodeState' | paste -sd, -)" = "cancelled,cancelled" ]
  [ "$(jq -r '.state' "$registry_run/engine/run.json")" = "cancelled" ]
  [ "$(jq -r '.state' "$registry_run/run.json")" = "cancelled" ]
  [ -s "$registry_run/actions/cancel-intent.json" ]
  [ "$(jq -r '.kind' "$registry_run/actions/cancel-intent.json")" = "cancel-intent" ]
}

@test "Sequential approval stub orchestrator stage hook exit 3 no runtime" {
  # Cost justification (entry-point): one stubbed orchestrator --single-stage
  # proves approval parks via common actions without invoking run-plan.
  local workspace orch_file registry_run run_id
  workspace="$(mktemp -d)"
  workspace="$(cd "$workspace" && pwd -P)"
  mkdir -p "$workspace/.ralph/bash-lib/orchestrator" "$workspace/.ralph/python" \
    "$workspace/stages" \
    "$workspace/.ralph-workspace/logs" \
    "$workspace/.ralph-workspace/artifacts/seq-appr"
  cp "$REPO_ROOT/.ralph/ralph-env-safety.sh" "$workspace/.ralph/"
  for f in error-handling.sh runtime-resolve.sh runtime-normalize.sh artifacts.sh \
           atomic-json.sh ralph-format-elapsed.sh review-status.sh \
           ralph-process-teardown.sh ralph-process-supervisor.sh; do
    cp "$REPO_ROOT/.ralph/bash-lib/$f" "$workspace/.ralph/bash-lib/" 2>/dev/null || true
  done
  cp "$REPO_ROOT/.ralph/bash-lib/orchestrator/"*.sh "$workspace/.ralph/bash-lib/orchestrator/"
  cp "$REPO_ROOT/.ralph/python/ralph_process_supervisor.py" "$workspace/.ralph/python/"
  # Intentionally omit workflow-engine-sequential.sh from workspace .ralph so
  # orch_workflow_seq_ensure_lib falls back to REPO_ROOT via RALPH_DIR.
  cat >"$workspace/.ralph/run-plan.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "ERROR: run-plan must not run for Sequential approval" >&2
exit 99
STUB
  chmod +x "$workspace/.ralph/run-plan.sh"
  printf 'evidence\n' >"$workspace/.ralph-workspace/artifacts/seq-appr/plan.json"
  orch_file="$workspace/appr.orch.json"
  cat >"$orch_file" <<'ORCH'
{
  "name": "seq-appr",
  "namespace": "seq-appr",
  "stages": [
    {
      "id": "approve-plan",
      "type": "approval",
      "question": "Approve?",
      "changesTarget": "approve-plan",
      "inputArtifacts": [
        {"path": ".ralph-workspace/artifacts/seq-appr/plan.json", "required": true}
      ]
    }
  ]
}
ORCH
  mkdir -p "$workspace/.ralph-workspace/workflow-inputs"
  cp "$orch_file" "$workspace/.ralph-workspace/workflow-inputs/sample.orch.json"
  printf '%s\n' '---' 'kind: workflow' 'mode: sequential' '---' \
    >"$workspace/.ralph-workspace/workflow-inputs/wf.md"
  export WORKFLOW_STATE_SKIP_FSYNC=1
  export WORKFLOW_SEQ_SKIP_FSYNC=1
  export WORKFLOW_ACTION_NOW="2026-08-26T15:00:00Z"
  # shellcheck source=/dev/null
  source "$STATE_LIB"
  # shellcheck source=/dev/null
  source "$SEQ_LIB"
  run_id="$(
    workflow_state_create \
      --state-root "$workspace/.ralph-workspace" \
      --source-path "$workspace/.ralph-workspace/workflow-inputs/wf.md" \
      --source-kind project \
      --mode sequential \
      --entry-kind task \
      --task "approval hook" \
      --task-provenance explicit \
      --input-file "$workspace/.ralph-workspace/workflow-inputs/sample.orch.json" \
      --workflow-id seq-appr
  )"
  registry_run="$workspace/.ralph-workspace/workflow-runs/$run_id"
  workflow_seq_init_engine \
    --registry-run "$registry_run" \
    --input-file "$workspace/.ralph-workspace/workflow-inputs/sample.orch.json" \
    --run-id "$run_id"

  run env RALPH_ALLOW_NESTED_RUNS=1 RALPH_WAIT_SCALE=0 RALPH_ARTIFACT_SCHEMA_VALIDATION=0 \
    RALPH_WORKFLOW_REGISTRY_RUN="$registry_run" \
    RALPH_WORKFLOW_RUN_ID="$run_id" \
    WORKFLOW_STATE_SKIP_FSYNC=1 \
    WORKFLOW_SEQ_SKIP_FSYNC=1 \
    WORKFLOW_ACTION_NOW="2026-08-26T15:00:00Z" \
    bash "$REPO_ROOT/.ralph/orchestrator.sh" \
      --orchestration "$orch_file" \
      --single-stage approve-plan \
      --run-id "$run_id" \
      --attempt-id "approve-plan-1" \
      "$workspace" 2>&1
  [ "$status" -eq 3 ] || { echo "$output"; rm -rf "$workspace"; return 1; }
  [[ "$output" != *"run-plan must not run"* ]]
  [ "$(jq -r '.state' "$registry_run/engine/stages/approve-plan.json")" = "waiting" ]
  [ "$(jq -r '.blocker.kind,.blocker.reasonCode' "$registry_run/engine/stages/approve-plan.json" | paste -sd, -)" = "approval,human-approval" ]
  [ "$(jq -r '.state' "$registry_run/run.json")" = "waiting" ]
  [ "$(find "$registry_run/actions/requests" -name '*.json' | wc -l | tr -d ' ')" = "1" ]

  ralph_test_rm_workspace "$workspace"
}

@test "legacy humanAck remains for classic orchestration without Sequential engine" {
  # Without RALPH_WORKFLOW_REGISTRY_RUN / engine, ORCHESTRATOR_HUMAN_ACK touch-file
  # still gates; workflow Sequential runs never use this path.
  local workspace orch_file
  workspace="$(mktemp -d)"
  workspace="$(cd "$workspace" && pwd -P)"
  mkdir -p "$workspace/.ralph/bash-lib/orchestrator" "$workspace/.ralph/python" \
    "$workspace/.ralph/bash-lib" "$workspace/stages" \
    "$workspace/.ralph-workspace/logs" \
    "$workspace/.ralph-workspace/artifacts/legacy-ack"
  cp "$REPO_ROOT/.ralph/ralph-env-safety.sh" "$workspace/.ralph/"
  for f in error-handling.sh runtime-resolve.sh runtime-normalize.sh artifacts.sh \
           atomic-json.sh ralph-format-elapsed.sh review-status.sh \
           ralph-process-teardown.sh ralph-process-supervisor.sh; do
    cp "$REPO_ROOT/.ralph/bash-lib/$f" "$workspace/.ralph/bash-lib/" 2>/dev/null || true
  done
  cp "$REPO_ROOT/.ralph/bash-lib/orchestrator/"*.sh "$workspace/.ralph/bash-lib/orchestrator/"
  cp "$REPO_ROOT/.ralph/python/ralph_process_supervisor.py" "$workspace/.ralph/python/"
  cat >"$workspace/.ralph/run-plan.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'stub run-plan ok\n'
exit 0
STUB
  chmod +x "$workspace/.ralph/run-plan.sh"
  cat >"$workspace/stages/only.plan.md" <<'PLAN'
# only
- [ ] do thing
PLAN
  printf 'ok\n' >"$workspace/.ralph-workspace/artifacts/legacy-ack/out.md"
  orch_file="$workspace/legacy.orch.json"
  cat >"$orch_file" <<'ORCH'
{
  "name": "legacy-ack",
  "namespace": "legacy-ack",
  "stages": [
    {
      "id": "only-stage",
      "runtime": "cursor",
      "plan": "stages/only.plan.md",
      "artifacts": [
        {"path": ".ralph-workspace/artifacts/legacy-ack/out.md", "required": true}
      ],
      "humanAck": {
        "path": ".ralph-workspace/artifacts/legacy-ack/human.ack",
        "message": "legacy humanAck gate"
      }
    },
    {
      "id": "next-stage",
      "runtime": "cursor",
      "plan": "stages/only.plan.md",
      "artifacts": [
        {"path": ".ralph-workspace/artifacts/legacy-ack/out.md", "required": true}
      ]
    }
  ]
}
ORCH

  # Multi-stage (not --single-stage) so humanAck waiting is enforced.
  run env RALPH_ALLOW_NESTED_RUNS=1 RALPH_WAIT_SCALE=0 RALPH_ARTIFACT_SCHEMA_VALIDATION=0 \
    ORCHESTRATOR_HUMAN_ACK=1 \
    bash "$REPO_ROOT/.ralph/orchestrator.sh" \
      --orchestration "$orch_file" \
      --run-id "run-legacy-ack" \
      --attempt-id "attempt-1" \
      "$workspace" 2>&1
  [ "$status" -eq 3 ] || { echo "$output"; rm -rf "$workspace"; return 1; }
  [[ "$output" == *"humanAck"* || "$output" == *"Human acknowledgment"* || "$output" == *"human.ack"* ]]
  [ ! -f "$workspace/.ralph-workspace/artifacts/legacy-ack/human.ack" ]

  ralph_test_rm_workspace "$workspace"
}


# --- Operator interrupt / cancel checkpoint (sourced; no orchestrator run) ---
#
# Owning contract: checkpoint-workflow-on-operator-interrupt. Handlers run as
# sourced functions with a stubbed child teardown, plus exactly one minimal
# signalled subshell. No runtime, no orchestrator entrypoint, no blocking sleep.

load_seq_action_libs() {
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-operator-records.sh"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/workflow/workflow-actions.sh"
}

# seed_seq_interrupt_run
# Sets SEQ_RUN_ID, SEQ_REGISTRY_RUN, SEQ_ATTEMPT and leaves stage `investigate`
# running under an owner, with one granted capability and a control plan whose
# recorded progress must survive the checkpoint unchanged.
seed_seq_interrupt_run() {
  export WORKFLOW_ACTION_NOW="2026-08-26T15:00:00Z"
  SEQ_RUN_ID="$(create_registry_run)"
  SEQ_REGISTRY_RUN="$CASE/workflow-runs/$SEQ_RUN_ID"
  SEQ_ATTEMPT="investigate__${SEQ_RUN_ID}__1"
  workflow_seq_init_engine \
    --registry-run "$SEQ_REGISTRY_RUN" \
    --input-file "$CASE/inputs/sample.orch.json" \
    --run-id "$SEQ_RUN_ID"

  printf '%s\n' '- [x] first' '- [ ] second' >"$CASE/control.plan.md"
  workflow_seq_write_stage \
    --registry-run "$SEQ_REGISTRY_RUN" \
    --stage-id investigate \
    --state running \
    --attempt 1 \
    --control-plan-path "$CASE/control.plan.md" \
    --current-todo-id second \
    --completed-todos 1 \
    --total-todos 2 \
    --event-name stage-started \
    --details-json '{"stageType":"inline","phase":"before"}'
  workflow_seq_update_run \
    --registry-run "$SEQ_REGISTRY_RUN" \
    --state running \
    --current-stage-ids-json '["investigate"]' \
    --owner-json '{"pid":4242,"hostname":"host","processStartId":"1:1","heartbeatAt":"2026-08-26T15:00:00Z"}' \
    --event-name run-started \
    --details-json '{}'
  workflow_action_capability_write "$SEQ_REGISTRY_RUN" "$SEQ_RUN_ID" investigate "$SEQ_ATTEMPT" >/dev/null
}

# seq_publish_request <kind> <request-id> [extra-json]
seq_publish_request() {
  local kind="$1" request_id="$2" extra="${3:-{\}}"
  workflow_action_request_write "$SEQ_REGISTRY_RUN" "$(jq -nc \
    --arg id "$request_id" --arg kind "$kind" --arg run "$SEQ_RUN_ID" \
    --arg attempt "$SEQ_ATTEMPT" --argjson extra "$extra" '{
      requestId:$id, kind:$kind, runId:$run, stageId:"investigate", attemptId:$attempt,
      question:"Decide?", createdAt:"2026-08-26T15:01:00Z"
    } + $extra')" >/dev/null
}

# seq_wait_for_file <path> [deadline-secs]
# Concrete file condition with a wall-clock deadline and a small poll, per
# agents/rules/test-design.md. Never a blocking sleep.
seq_wait_for_file() {
  local path="$1" deadline
  deadline=$(( $(date +%s) + ${2:-20} ))
  until [[ -e "$path" ]]; do
    [[ $(date +%s) -lt $deadline ]] || {
      echo "timed out waiting for $path" >&2
      return 1
    }
    sleep 0.05
  done
  return 0
}

@test "operator interrupt: workflow SIGINT checkpoint parks waiting after stub child teardown" {
  load_seq_action_libs
  seed_seq_interrupt_run

  # One minimal signalled subshell: it blocks on a FIFO open (interruptible, no
  # blocking sleep), tears down a stub child, then checkpoints and exits 130.
  local fifo="$CASE/int.fifo" ready="$CASE/int.ready"
  local teardown_marker="$CASE/int.teardown" pid rc=0
  mkfifo "$fifo"
  (
    orch_stub_teardown() { : >"$teardown_marker"; }
    handler() {
      trap '' INT TERM HUP
      orch_stub_teardown
      workflow_seq_operator_interrupt_checkpoint "$SEQ_REGISTRY_RUN" || exit 1
      exit 130
    }
    trap handler INT
    : >"$ready"
    read -r _ <"$fifo" || true
    exit 0
  ) &
  pid=$!
  seq_wait_for_file "$ready" 20
  kill -INT "$pid" 2>/dev/null || true
  wait "$pid" || rc=$?

  [ "$rc" -eq 130 ]
  # Child teardown ran before the checkpoint was written.
  [ -f "$teardown_marker" ]

  local engine_dir="$SEQ_REGISTRY_RUN/engine"
  validate_run_schema "$engine_dir/run.json"
  validate_stage_schema "$engine_dir/stages/investigate.json"
  validate_events_jsonl "$engine_dir/events.jsonl"

  # Both projections park, ownership is cleared, loop position is preserved.
  [ "$(jq -r '.state' "$engine_dir/run.json")" = "waiting" ]
  [ "$(jq -r '.owner.pid' "$engine_dir/run.json")" = "null" ]
  [ "$(jq -c '.currentStageIds' "$engine_dir/run.json")" = '["investigate"]' ]
  [ "$(jq -r '.state' "$engine_dir/stages/investigate.json")" = "waiting" ]
  [ "$(jq -r '.state' "$SEQ_REGISTRY_RUN/run.json")" = "waiting" ]
  [ "$(jq -r '.owner.pid' "$SEQ_REGISTRY_RUN/run.json")" = "null" ]

  # The interrupt is journalled and the diagnosis is retryable with resume argv.
  [ "$(grep -c '"event":"operator-interrupted"' "$engine_dir/events.jsonl")" -ge 1 ]
  [ "$(jq -r '.state,.reasonCode,.retryable,.stageId' "$SEQ_REGISTRY_RUN/diagnosis.json" | paste -sd, -)" = "waiting,operator-request,true,investigate" ]
  [ "$(jq -c '.nextAction.argv' "$SEQ_REGISTRY_RUN/diagnosis.json")" = "[\"ralph\",\"workflow\",\"resume\",\"$SEQ_RUN_ID\"]" ]
}

@test "operator interrupt: checkpoint keeps the same control progress and immutable input" {
  load_seq_action_libs
  seed_seq_interrupt_run
  local stage_file="$SEQ_REGISTRY_RUN/engine/stages/investigate.json"
  local input_before control_before before
  input_before="$(cksum <"$CASE/inputs/sample.orch.json")"
  control_before="$(cksum <"$CASE/control.plan.md")"
  before="$(jq -c '{controlPlanPath,currentTodoId,completedTodos,totalTodos,attempt}' "$stage_file")"

  workflow_seq_operator_interrupt_checkpoint "$SEQ_REGISTRY_RUN"

  # Exactly the same control plan pointer, todo cursor, counts, and attempt.
  [ "$(jq -c '{controlPlanPath,currentTodoId,completedTodos,totalTodos,attempt}' "$stage_file")" = "$before" ]
  [ "$(jq -r '.state' "$stage_file")" = "waiting" ]
  # Immutable input and the control plan bytes are untouched.
  [ "$(cksum <"$CASE/inputs/sample.orch.json")" = "$input_before" ]
  [ "$(cksum <"$CASE/control.plan.md")" = "$control_before" ]
}

@test "operator interrupt: action wait preserved when a request was published first" {
  load_seq_action_libs
  seed_seq_interrupt_run
  local stage_file="$SEQ_REGISTRY_RUN/engine/stages/investigate.json"
  local request_id="reqseqinput1" events_before

  seq_publish_request input "$request_id"
  # The stage is already parked on that durable request.
  workflow_seq_write_stage \
    --registry-run "$SEQ_REGISTRY_RUN" \
    --stage-id investigate \
    --state waiting \
    --blocker-json "$(jq -nc --arg id "$request_id" \
      '{reasonCode:"operator-input",requestId:$id,summary:"Awaiting operator input"}')" \
    --event-name stage-waiting \
    --details-json '{"reason":"operator-input"}'
  events_before="$(wc -l <"$SEQ_REGISTRY_RUN/engine/events.jsonl")"

  workflow_seq_operator_interrupt_checkpoint "$SEQ_REGISTRY_RUN"

  # The action-derived wait survives: same blocker, no operator-request overwrite.
  [ "$(jq -r '.state' "$stage_file")" = "waiting" ]
  [ "$(jq -r '.blocker.reasonCode' "$stage_file")" = "operator-input" ]
  [ "$(jq -r '.blocker.requestId' "$stage_file")" = "$request_id" ]
  # No second request is minted and no interrupt event is journalled over it.
  [ "$(find "$SEQ_REGISTRY_RUN/actions/requests" -name '*.json' | wc -l | tr -d ' ')" = "1" ]
  [ "$(wc -l <"$SEQ_REGISTRY_RUN/engine/events.jsonl")" = "$events_before" ]
  # The run is still parked for the operator.
  [ "$(jq -r '.state' "$SEQ_REGISTRY_RUN/run.json")" = "waiting" ]
}

@test "operator interrupt: capability revoked for the interrupted attempt only" {
  load_seq_action_libs
  seed_seq_interrupt_run
  local own_cap other_cap
  own_cap="$SEQ_REGISTRY_RUN/actions/capabilities/investigate-${SEQ_ATTEMPT}.json"
  [ -f "$own_cap" ]
  other_cap="$(workflow_action_capability_write "$SEQ_REGISTRY_RUN" "$SEQ_RUN_ID" alpha "alpha__${SEQ_RUN_ID}__1")"
  [ -f "$other_cap" ]

  workflow_seq_operator_interrupt_checkpoint "$SEQ_REGISTRY_RUN"

  [ ! -f "$own_cap" ]
  [ -f "$other_cap" ]
}

@test "operator cancel: cancel intent is durable and never reclassified as retryable waiting" {
  load_seq_action_libs
  seed_seq_interrupt_run
  local request_id="reqseqappr1" request_path

  seq_publish_request approval "$request_id" '{"changesTarget":"investigate"}'
  request_path="$(find "$SEQ_REGISTRY_RUN/actions/requests" -name '*.json' | head -n1)"

  workflow_seq_operator_cancel "$SEQ_REGISTRY_RUN"

  # Durable intent written before teardown; outstanding actions are cancelled by
  # decision, never by deleting their records.
  [ -s "$SEQ_REGISTRY_RUN/actions/cancel-intent.json" ]
  [ "$(jq -r '.kind,.source' "$SEQ_REGISTRY_RUN/actions/cancel-intent.json" | paste -sd, -)" = "cancel-intent,operator-signal" ]
  [ -f "$request_path" ]
  [ "$(workflow_action_decision_read "$SEQ_REGISTRY_RUN" "$request_id" | jq -r '.decision')" = "cancel" ]

  # Cancel is terminal, not a retryable operator-request wait.
  [ "$(jq -r '.state' "$SEQ_REGISTRY_RUN/engine/run.json")" = "cancelled" ]
  [ "$(jq -r '.state' "$SEQ_REGISTRY_RUN/run.json")" = "cancelled" ]
  [ ! -f "$SEQ_REGISTRY_RUN/actions/capabilities/investigate-${SEQ_ATTEMPT}.json" ]
}
