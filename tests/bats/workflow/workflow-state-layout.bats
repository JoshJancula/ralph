#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

setup() {
  unset RALPH_STATE_LAYOUT
  CASE="$(mktemp -d)"
  export CASE
  export WORKFLOW_STATE_SKIP_FSYNC=1
  mkdir -p "$CASE/state"
  STATE="$(cd "$CASE/state" && pwd -P)"
  export STATE
  source "$REPO_ROOT/bundle/.ralph/bash-lib/atomic-json.sh"
  source "$REPO_ROOT/bundle/.ralph/bash-lib/state-paths.sh"
  source "$REPO_ROOT/bundle/.ralph/bash-lib/workflow/workflow-state.sh"
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-manifest.sh"
}

teardown() { rm -rf "$CASE"; }

# create_run <mode> <workflow-id> [extra workflow_state_create args...]
create_run() {
  local mode="$1" workflow_id="$2"
  shift 2
  local input
  printf '%s\n' '---' 'kind: workflow' "mode: $mode" '---' >"$CASE/$workflow_id.workflow.md"
  if [[ "$mode" == "sequential" ]]; then
    input="$CASE/$workflow_id.orch.json"
    printf '{"pipeline":{"stages":[{"id":"s1","runtime":"cursor","model":"stub"}]}}\n' >"$input"
  else
    input="$CASE/$workflow_id.plan.md"
    printf '# dep\n- [ ] work\n' >"$input"
  fi
  workflow_state_create \
    --state-root "$STATE" \
    --source-path "$CASE/$workflow_id.workflow.md" \
    --source-kind project \
    --mode "$mode" \
    --entry-kind task \
    --task "layout fixture for $workflow_id" \
    --task-provenance explicit \
    --input-file "$input" \
    --workflow-id "$workflow_id" \
    "$@"
}

# write_plan_manifest <run-id> <status>
write_plan_manifest() {
  RALPH_PLAN_WORKSPACE_ROOT="$STATE" \
  RALPH_PROCESS_RUN_ID="$1" \
  RALPH_PLAN_KEY="leaf.plan" \
  RALPH_ARTIFACT_NS="leaf.plan" \
  RALPH_LOG_DIR="$STATE/logs/leaf.plan" \
  RUNTIME=cursor SELECTED_MODEL=stub PLAN_PATH="$CASE/leaf.plan.md" \
  _plan_started_at="2026-01-01T00:00:00Z" total_invocations=1 \
    ralph_run_plan_write_manifest "$2"
}

@test "new workflow records use the v2 run root and legacy records remain v1" {
  [ "$(ralph_state_layout_version "$STATE")" = 2 ]
  [ "$(workflow_state_runs_root "$STATE")" = "$STATE/runs" ]

  mkdir -p "$STATE/workflow-runs/legacy"
  printf '{"runId":"legacy"}\n' >"$STATE/workflow-runs/legacy/run.json"
  [ "$(workflow_state_run_dir "$STATE" legacy)" = "$STATE/workflow-runs/legacy" ]

  mkdir -p "$STATE/runs/current"
  printf '{"layoutVersion":2}\n' >"$STATE/runs/current/run.json"
  [ "$(workflow_state_run_dir "$STATE" current)" = "$STATE/runs/current/engine/workflow" ]
}

@test "layout one preserves the legacy workflow run root" {
  RALPH_STATE_LAYOUT=1
  export RALPH_STATE_LAYOUT
  [ "$(workflow_state_runs_root "$STATE")" = "$STATE/workflow-runs" ]
  [ "$(workflow_state_run_dir "$STATE" new-run)" = "$STATE/workflow-runs/new-run" ]
}

@test "an unusable RALPH_STATE_LAYOUT is refused rather than silently downgraded" {
  RALPH_STATE_LAYOUT=3
  export RALPH_STATE_LAYOUT
  run ralph_state_layout_for_new_run
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid RALPH_STATE_LAYOUT: 3"* ]]
}

@test "a sequential start owns runs/<id> with the registry and engine beneath it" {
  local run_id
  run_id="$(create_run sequential golden-seq)"
  [ -n "$run_id" ]

  [ -f "$STATE/runs/$run_id/run.json" ]
  [ "$(jq -r '.kind' "$STATE/runs/$run_id/run.json")" = "ralph_run_catalog" ]
  [ "$(jq -r '.layoutVersion' "$STATE/runs/$run_id/run.json")" = "2" ]
  [ "$(jq -r '.runKind' "$STATE/runs/$run_id/run.json")" = "workflow" ]
  [ "$(jq -r '.runId' "$STATE/runs/$run_id/run.json")" = "$run_id" ]
  [ "$(jq -r '.status' "$STATE/runs/$run_id/run.json")" = "queued" ]

  # The registry schema is unchanged; only its home moved.
  [ "$(workflow_state_run_dir "$STATE" "$run_id")" = "$STATE/runs/$run_id/engine/workflow" ]
  [ -f "$STATE/runs/$run_id/engine/workflow/run.json" ]
  [ -f "$STATE/runs/$run_id/engine/workflow/input.orch.json" ]
  [ "$(jq -r '.mode' "$STATE/runs/$run_id/engine/workflow/run.json")" = "sequential" ]
  [ "$(jq -r '.engine.statePath' "$STATE/runs/$run_id/engine/workflow/run.json")" = "$STATE/runs/$run_id/engine/sequential" ]

  [ ! -d "$STATE/workflow-runs" ]
  run workflow_state_read "$STATE" "$run_id"
  [ "$status" -eq 0 ]
}

@test "a dependency start points its engine at runs/<id>/engine/graph" {
  local run_id
  run_id="$(create_run dependency golden-dep --engine-namespace golden-dep)"
  [ -f "$STATE/runs/$run_id/engine/workflow/input.plan.md" ]
  [ "$(jq -r '.engine.kind' "$STATE/runs/$run_id/engine/workflow/run.json")" = "graph" ]
  [ "$(jq -r '.engine.statePath' "$STATE/runs/$run_id/engine/workflow/run.json")" = "$STATE/runs/$run_id/engine/graph" ]
  [ "$(ralph_state_graph_run_dir "$STATE" golden-dep "$run_id")" = "$STATE/runs/$run_id/engine/graph" ]
  [ ! -d "$STATE/graph-runs" ]
}

@test "waiting, resuming, and finishing a run keep the catalog in step" {
  local run_id catalog
  run_id="$(create_run sequential golden-wait)"
  catalog="$STATE/runs/$run_id/run.json"

  workflow_state_update "$STATE" "$run_id" '.state = "waiting"'
  [ "$(jq -r '.status' "$catalog")" = "waiting" ]
  [ "$(jq -r '.endedAt' "$catalog")" = "null" ]

  workflow_state_update "$STATE" "$run_id" '.state = "running"'
  [ "$(jq -r '.status' "$catalog")" = "running" ]
  [ "$(jq -r '.endedAt' "$catalog")" = "null" ]

  workflow_state_update "$STATE" "$run_id" '.state = "succeeded"'
  [ "$(jq -r '.status' "$catalog")" = "succeeded" ]
  [ "$(jq -r '.endedAt' "$catalog")" != "null" ]
  [ "$(jq -r '.runId' "$catalog")" = "$run_id" ]
}

@test "listing reads the v2 registry and legacy v1 history together" {
  local run_id
  run_id="$(create_run sequential golden-list)"

  mkdir -p "$STATE/workflow-runs/run-legacy-0001"
  jq -n --arg dir "$STATE/workflow-runs/run-legacy-0001" '{
    runId: "run-legacy-0001", workflowId: "legacy-flow", sourcePath: "/tmp/legacy.workflow.md",
    sourceKind: "project", mode: "sequential", entryKind: "task", task: "legacy",
    taskProvenance: "explicit", inputPath: ($dir + "/input.orch.json"), inputPlan: null,
    state: "succeeded", createdAt: "2020-01-01T00:00:00Z", updatedAt: "2020-01-01T00:00:00Z",
    owner: null, engine: null
  }' >"$STATE/workflow-runs/run-legacy-0001/run.json"

  run workflow_state_list "$STATE" --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r --arg id "$run_id" '[.[] | select(.runId == $id)] | length')" = "1" ]
  [ "$(printf '%s' "$output" | jq -r '[.[] | select(.runId == "run-legacy-0001")] | length')" = "1" ]

  # A legacy record keeps resolving to its original home.
  [ "$(workflow_state_run_dir "$STATE" run-legacy-0001)" = "$STATE/workflow-runs/run-legacy-0001" ]
}

@test "a standalone plan run owns its catalog and attempt directory" {
  write_plan_manifest run-leaf-0001 running

  local attempt="$STATE/runs/run-leaf-0001/stages/plan/attempts/run-leaf-0001"
  [ -f "$attempt/run-manifest.json" ]
  [ -d "$attempt/handoffs" ]
  [ -d "$attempt/manual-verification" ]
  [ "$(jq -r '.status' "$attempt/run-manifest.json")" = "running" ]
  [ "$(jq -r '.paths.run_dir' "$attempt/run-manifest.json")" = "runs/run-leaf-0001/stages/plan/attempts/run-leaf-0001" ]
  [ "$(jq -r '.runKind' "$STATE/runs/run-leaf-0001/run.json")" = "plan" ]
  [ "$(jq -r '.status' "$STATE/runs/run-leaf-0001/run.json")" = "running" ]
  [ "$(jq -r '.endedAt' "$STATE/runs/run-leaf-0001/run.json")" = "null" ]
  [ "$(jq -r '.stages[0].path' "$STATE/runs/run-leaf-0001/run.json")" = "stages/plan/attempts/run-leaf-0001" ]
  [ ! -e "$STATE/logs/leaf.plan/runs" ]

  write_plan_manifest run-leaf-0001 complete
  [ "$(jq -r '.status' "$attempt/run-manifest.json")" = "complete" ]
  [ "$(jq -r '.status' "$STATE/runs/run-leaf-0001/run.json")" = "complete" ]
  [ "$(jq -r '.endedAt' "$STATE/runs/run-leaf-0001/run.json")" != "null" ]
  [ "$(jq -r '.stages | length' "$STATE/runs/run-leaf-0001/run.json")" = "1" ]
}

@test "a workflow child attempt lands under the outer run without rewriting its catalog" {
  local run_id
  run_id="$(create_run sequential golden-child)"

  RALPH_WORKFLOW_RUN_ID="$run_id" RALPH_STAGE_ID=build \
    write_plan_manifest run-child-0001 complete

  local attempt="$STATE/runs/$run_id/stages/build/attempts/run-child-0001"
  [ -f "$attempt/run-manifest.json" ]
  [ "$(jq -r '.parent.workflow_run_id' "$attempt/run-manifest.json")" = "$run_id" ]
  [ "$(jq -r '.parent.stage_id' "$attempt/run-manifest.json")" = "build" ]
  [ ! -d "$STATE/runs/run-child-0001" ]

  # The child records a stage entry but must not claim the outer run.
  [ "$(jq -r '.runKind' "$STATE/runs/$run_id/run.json")" = "workflow" ]
  [ "$(jq -r '.status' "$STATE/runs/$run_id/run.json")" = "queued" ]
  [ "$(jq -r '.stages[0].stageId' "$STATE/runs/$run_id/run.json")" = "build" ]
  [ "$(jq -r '.stages[0].latestAttemptId' "$STATE/runs/$run_id/run.json")" = "run-child-0001" ]
}

@test "a plan run admitted under layout 1 keeps its v1 attempt path after the default flips" {
  # Layout 1 is the pre-plan contract: no admission write, one exit write.
  RALPH_STATE_LAYOUT=1 write_plan_manifest run-pinned-0001 running
  [ ! -e "$STATE/logs/leaf.plan/runs/run-pinned-0001/run-manifest.json" ]
  RALPH_STATE_LAYOUT=1 write_plan_manifest run-pinned-0001 complete
  [ "$(jq -r '.status' "$STATE/logs/leaf.plan/runs/run-pinned-0001/run-manifest.json")" = "complete" ]
  [ "$(wc -l <"$STATE/logs/leaf.plan/runs/index.jsonl" | tr -d ' ')" -eq 1 ]

  # A later writer under the layout-2 default must follow the existing v1
  # directory (never mint runs/) and must not append a second index row.
  # Clear the per-process layout cache so this acts as a separate process.
  unset _RALPH_RUN_PLAN_MANIFEST_LAYOUT_RUN _RALPH_RUN_PLAN_MANIFEST_LAYOUT
  write_plan_manifest run-pinned-0001 interrupted
  [ "$(jq -r '.status' "$STATE/logs/leaf.plan/runs/run-pinned-0001/run-manifest.json")" = "complete" ]
  [ "$(wc -l <"$STATE/logs/leaf.plan/runs/index.jsonl" | tr -d ' ')" -eq 1 ]
  [ ! -d "$STATE/runs/run-pinned-0001" ]
}

@test "layout 2 control copies land under stages/<stage>/controls" {
  local run_id registry control
  run_id="$(create_run sequential golden-control)"
  registry="$(workflow_state_run_dir "$STATE" "$run_id")"
  [ "$registry" = "$STATE/runs/$run_id/engine/workflow" ]

  control="$(_workflow_state_control_dir "$registry" implement 1)"
  [ "$control" = "$STATE/runs/$run_id/stages/implement/controls/attempt-1" ]
  mkdir -p "$control"
  printf '# control\n- [ ] work\n' >"$control/control.plan.md"
  [ -f "$STATE/runs/$run_id/stages/implement/controls/attempt-1/control.plan.md" ]
  [ ! -e "$registry/plans/implement" ]
}

@test "concurrent catalog stage updates leave both entries in valid JSON" {
  local run_id barrier go ready1 ready2 catalog
  run_id="$(create_run sequential golden-concurrent)"
  catalog="$STATE/runs/$run_id/run.json"
  barrier="$(mktemp -d "$CASE/barrier.XXXXXX")"
  go="$barrier/go"
  ready1="$barrier/ready1"
  ready2="$barrier/ready2"

  (
    source "$REPO_ROOT/bundle/.ralph/bash-lib/atomic-json.sh"
    source "$REPO_ROOT/bundle/.ralph/bash-lib/state-paths.sh"
    touch "$ready1"
    until [[ -e "$go" ]]; do sleep 0.05; done
    ralph_state_catalog_record_stage "$STATE" "$run_id" build run-a-0001 complete
  ) &
  (
    source "$REPO_ROOT/bundle/.ralph/bash-lib/atomic-json.sh"
    source "$REPO_ROOT/bundle/.ralph/bash-lib/state-paths.sh"
    touch "$ready2"
    until [[ -e "$go" ]]; do sleep 0.05; done
    ralph_state_catalog_record_stage "$STATE" "$run_id" test run-b-0001 complete
  ) &

  until [[ -e "$ready1" && -e "$ready2" ]]; do sleep 0.05; done
  touch "$go"
  wait

  jq -e . "$catalog" >/dev/null
  [ "$(jq -r '.stages | length' "$catalog")" = "2" ]
  [ "$(jq -r '[.stages[].stageId] | sort | join(",")' "$catalog")" = "build,test" ]
  [ "$(jq -r '.stages[] | select(.stageId=="build") | .latestAttemptId' "$catalog")" = "run-a-0001" ]
  [ "$(jq -r '.stages[] | select(.stageId=="test") | .latestAttemptId' "$catalog")" = "run-b-0001" ]
  [ ! -e "$STATE/runs/$run_id/.catalog.lock" ]
}

@test "a workflow admitted under layout 1 keeps resolving to workflow-runs after the default flips" {
  local run_id
  RALPH_STATE_LAYOUT=1
  export RALPH_STATE_LAYOUT
  run_id="$(create_run sequential golden-v1-pin)"
  [ -f "$STATE/workflow-runs/$run_id/run.json" ]
  [ ! -d "$STATE/runs/$run_id" ]

  unset RALPH_STATE_LAYOUT
  [ "$(ralph_state_layout_for_new_run)" = 2 ]
  [ "$(workflow_state_run_dir "$STATE" "$run_id")" = "$STATE/workflow-runs/$run_id" ]
  [ "$(ralph_state_run_layout "$STATE" "$run_id")" = 1 ]

  workflow_state_update "$STATE" "$run_id" '.state = "waiting"'
  [ "$(jq -r '.state' "$STATE/workflow-runs/$run_id/run.json")" = "waiting" ]
  [ ! -d "$STATE/runs/$run_id" ]
}

@test "graph_state_init_run under layout 2 writes engine/graph and admits a catalog" {
  source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-state.sh"
  local ws ns run_id plan graph
  ws="$CASE/graph-ws"
  mkdir -p "$ws"
  ns=demo
  run_id=run-graph-v2-0001
  plan="$ws/plan.md"
  graph="$ws/graph.json"
  printf '# plan\n- [ ] work\n' >"$plan"
  printf '{"namespace":"demo","nodes":[{"id":"n1","type":"agent","stage":{"id":"n1","runtime":"cursor"}}]}\n' >"$graph"
  export RALPH_PLAN_WORKSPACE_ROOT="$STATE"
  unset RALPH_STATE_LAYOUT

  run graph_state_init_run "$ws" "$ns" "$run_id" "$plan" "$graph" 1
  [ "$status" -eq 0 ]
  [ -f "$STATE/runs/$run_id/engine/graph/run.json" ]
  [ -f "$STATE/runs/$run_id/engine/graph/graph.json" ]
  [ -f "$STATE/runs/$run_id/run.json" ]
  [ "$(jq -r '.layoutVersion' "$STATE/runs/$run_id/run.json")" = "2" ]
  [ "$(jq -r '.runKind' "$STATE/runs/$run_id/run.json")" = "graph" ]
  [ "$(graph_state_run_dir "$ws" "$ns" "$run_id")" = "$STATE/runs/$run_id/engine/graph" ]
  [ ! -d "$STATE/graph-runs" ]
}

@test "graph_state_init_run under layout 1 keeps graph-runs and a prior v1 run still resolves there" {
  source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-state.sh"
  local ws ns run_id plan graph
  ws="$CASE/graph-ws-v1"
  mkdir -p "$ws"
  ns=demo
  run_id=run-graph-v1-0001
  plan="$ws/plan.md"
  graph="$ws/graph.json"
  printf '# plan\n- [ ] work\n' >"$plan"
  printf '{"namespace":"demo","nodes":[{"id":"n1","type":"agent","stage":{"id":"n1","runtime":"cursor"}}]}\n' >"$graph"
  export RALPH_PLAN_WORKSPACE_ROOT="$STATE"
  RALPH_STATE_LAYOUT=1
  export RALPH_STATE_LAYOUT

  run graph_state_init_run "$ws" "$ns" "$run_id" "$plan" "$graph" 1
  [ "$status" -eq 0 ]
  [ -f "$STATE/graph-runs/$ns/$run_id/run.json" ]
  [ ! -d "$STATE/runs/$run_id" ]

  unset RALPH_STATE_LAYOUT
  [ "$(ralph_state_layout_for_new_run)" = 2 ]
  [ "$(ralph_state_graph_run_dir "$STATE" "$ns" "$run_id")" = "$STATE/graph-runs/$ns/$run_id" ]
  [ "$(graph_state_run_dir "$ws" "$ns" "$run_id")" = "$STATE/graph-runs/$ns/$run_id" ]
}

@test "sequential and delegation path functions resolve layout 2 and layout 1 homes" {
  source "$REPO_ROOT/bundle/.ralph/bash-lib/workflow/workflow-engine-sequential.sh"
  source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-delegation-ledger.sh"
  local run_id registry parent did legacy_parent
  export RALPH_PLAN_WORKSPACE_ROOT="$STATE"

  run_id="$(create_run sequential golden-seq-engine)"
  registry="$(workflow_state_run_dir "$STATE" "$run_id")"
  [ "$registry" = "$STATE/runs/$run_id/engine/workflow" ]
  [ "$(workflow_seq_engine_dir "$registry")" = "$STATE/runs/$run_id/engine/sequential" ]
  [ "$(ralph_state_sequential_run_dir "$STATE" "$run_id" "$registry/engine")" = "$STATE/runs/$run_id/engine/sequential" ]

  parent=run-parent-del-0001
  did=delegated-run-0123456789abcdef01234567
  mkdir -p "$STATE/runs/$parent"
  printf '{"layoutVersion":2}\n' >"$STATE/runs/$parent/run.json"
  [ "$(ralph_state_delegation_root "$STATE" "$parent")" = "$STATE/runs/$parent/engine/delegation" ]
  [ "$(ralph_state_delegation_dir "$STATE" "$parent" "$did")" = "$STATE/runs/$parent/engine/delegation/$did" ]
  export RALPH_GRAPH_RUN_ID="$parent"
  [ "$(graph_delegation_ledger_root "$CASE" "$parent")" = "$STATE/runs/$parent/engine/delegation" ]
  [ "$(graph_delegation_ledger_dir "$CASE" "$did" "$parent")" = "$STATE/runs/$parent/engine/delegation/$did" ]

  RALPH_STATE_LAYOUT=1
  export RALPH_STATE_LAYOUT
  legacy_parent=run-parent-v1-0001
  mkdir -p "$STATE/graph-runs/demo/$legacy_parent"
  printf '{"runId":"%s"}\n' "$legacy_parent" >"$STATE/graph-runs/demo/$legacy_parent/run.json"
  [ "$(ralph_state_delegation_root "$STATE" "$legacy_parent")" = "$STATE/delegated-runs" ]
  [ "$(ralph_state_graph_run_dir "$STATE" demo "$legacy_parent")" = "$STATE/graph-runs/demo/$legacy_parent" ]
}

@test "a child attempt of a layout-1 workflow stays layout 1 and never writes a catalog over it" {
  # A workflow created before layout 2: registry at workflow-runs/<id>, no catalog.
  mkdir -p "$STATE/workflow-runs/wf-legacy"
  printf '{"state":"running"}\n' >"$STATE/workflow-runs/wf-legacy/run.json"
  # The child runs in a process whose default is layout 2.
  RALPH_WORKFLOW_RUN_ID=wf-legacy RALPH_STAGE_ID=build write_plan_manifest run-child-legacy running
  RALPH_WORKFLOW_RUN_ID=wf-legacy RALPH_STAGE_ID=build write_plan_manifest run-child-legacy complete
  [ -f "$STATE/logs/leaf.plan/runs/run-child-legacy/run-manifest.json" ]
  [ ! -e "$STATE/runs/wf-legacy/run.json" ]
  [ "$(ralph_state_run_layout "$STATE" wf-legacy)" = 1 ]
}

@test "the run catalog keeps one entry per stage with the latest attempt" {
  local run_id
  run_id="$(create_run dependency layout-stages)"
  ralph_state_catalog_record_stage "$STATE" "$run_id" build attempt-1 failed
  ralph_state_catalog_record_stage "$STATE" "$run_id" build attempt-2 running
  ralph_state_catalog_record_stage "$STATE" "$run_id" build attempt-3 complete
  [ "$(jq '[.stages[] | select(.stageId == "build")] | length' "$STATE/runs/$run_id/run.json")" -eq 1 ]
  [ "$(jq -r '.stages[] | select(.stageId == "build") | .latestAttemptId' "$STATE/runs/$run_id/run.json")" = attempt-3 ]
}
