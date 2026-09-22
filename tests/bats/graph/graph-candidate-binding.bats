#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/plan-todo.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-state.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-run-base.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-workspace-manager.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-changeset.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-publish.sh"

SNAPSHOT_HELPER="$REPO_ROOT/bundle/.ralph/python/graph_source_snapshot.py"

candidate_plan() {
  local path="$1" source="$2" mode="$3"
  cat >"$path" <<PLAN
---
execution: graph
pipeline:
  stages:
    - id: implement
      runtime: cursor
      workspaceMode: snapshot
      writeScopes:
        - src/**
    - id: qa
      runtime: cursor
      workspaceMode: $mode
      candidateFrom: $source
      dependsOn:
        - implement
todos:
  - id: implement-1
    stage: implement
    content: implement
    status: pending
  - id: qa-1
    stage: qa
    content: qa
    status: pending
---
PLAN
}

write_node_ledger() {
  local id="$1" status="$2"
  local workspace_path="${3:-}" identity="${4:-}" attempt_id="${5:-}"
  mkdir -p "$RUN_DIR/nodes"
  jq -n \
    --arg id "$id" \
    --arg status "$status" \
    --arg workspace "$workspace_path" \
    --arg identity "$identity" \
    --arg attempt "$attempt_id" \
    '{
       schemaVersion:1,
       nodeId:$id,
       status:$status,
       lastAttemptId:(if $attempt == "" then null else $attempt end),
       workspacePath:(if $workspace == "" then null else $workspace end),
       candidateIdentity:(if $identity == "" then null else $identity end),
       attempts:(
         if $attempt == "" then []
         else [{
           attemptId:$attempt,
           workspacePath:(if $workspace == "" then null else $workspace end),
           candidateIdentity:(if $identity == "" then null else $identity end)
         }]
         end
       )
     }' >"$RUN_DIR/nodes/$id.json"
}

filesystem_identity() {
  python3 "$SNAPSHOT_HELPER" identity \
    --source "$1" --state-root "$STATE" | jq -r '.filesystemIdentity'
}

make_binding_project() {
  TEST_ROOT="$(mktemp -d)"
  PROJECT="$TEST_ROOT/project"
  STATE="$TEST_ROOT/state"
  mkdir -p "$PROJECT/src" "$STATE"
  PROJECT="$(cd "$PROJECT" && pwd -P)"
  STATE="$(cd "$STATE" && pwd -P)"
  printf 'base\n' >"$PROJECT/src/app.txt"
  git init -q "$PROJECT"
  git -C "$PROJECT" add .
  git -C "$PROJECT" -c user.name=Ralph -c user.email=ralph@example.invalid \
    commit -qm fixture
  RUN_DIR="$STATE/graph-runs/candidate-binding/run-1"
  GRAPH="$RUN_DIR/graph.json"
  PLAN="$TEST_ROOT/candidate-binding.plan.md"
  mkdir -p "$RUN_DIR/nodes"
  printf '%s\n' '---' 'execution: graph' '---' >"$PLAN"
}

@test "candidateFrom names a non-ancestor is rejected at validation" {
  local d="$BATS_TEST_TMPDIR/non-ancestor.plan.md"
  candidate_plan "$d" qa snapshot
  run plan_pipeline_graph_json "$d"
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be an ancestor"* ]]
}

@test "candidateFrom naming a read-only stage is rejected at validation" {
  local d="$BATS_TEST_TMPDIR/read-only.plan.md"
  candidate_plan "$d" implement snapshot
  sed -i.bak '/writeScopes:/,+1d' "$d"
  run plan_pipeline_graph_json "$d"
  [ "$status" -ne 0 ]
  [[ "$output" == *"read-only"* ]]
}

@test "candidateFrom requires an evaluator snapshot" {
  local d="$BATS_TEST_TMPDIR/shared.plan.md"
  candidate_plan "$d" implement shared
  run plan_pipeline_graph_json "$d"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires workspaceMode snapshot"* ]]
}

@test "graph_workspace_prepare_node materializes evaluator from candidate workspace" {
  local implement_ws qa_ws
  make_binding_project
  jq -cn \
    '{schemaVersion:1,ralphVersion:"test",name:"candidate-binding",
      namespace:"candidate-binding",maxParallel:1,failurePolicy:"drain",
      publishMode:"manual",
      nodes:[
        {id:"implement",type:"agent",dependsOn:[],derivedFrom:"stage",
         stage:{id:"implement",runtime:"cursor",workspaceMode:"snapshot",
                writeScopes:["src/**"]}},
        {id:"qa",type:"agent",dependsOn:["implement"],derivedFrom:"stage",
         stage:{id:"qa",runtime:"cursor",workspaceMode:"snapshot",
                candidateFrom:"implement"}}
      ],edges:[{from:"implement",to:"qa",reasons:["declared"]}]}' >"$GRAPH"
  jq -cn --arg plan "$PLAN" \
    '{schemaVersion:1,ralphVersion:"test",runId:"run-1",planPath:$plan,graphSha:"test",
      startedAt:"2026-01-01T00:00:00Z",status:"running",maxParallel:1}' \
    >"$RUN_DIR/run.json"
  graph_run_base_prepare "$RUN_DIR" \
    "$(jq -cn --arg project "$PROJECT" --arg state "$STATE" --arg agent "$PROJECT" \
      '{projectRoot:$project,stateRoot:$state,agentWorkspace:$agent}')" \
    '["snapshot"]'
  graph_workspace_prepare_run "$RUN_DIR" "$GRAPH"

  implement_ws="$(graph_workspace_prepare_node "$RUN_DIR" "$GRAPH" implement)"
  printf 'candidate-only\n' >"$implement_ws/src/candidate-only.txt"
  printf 'caller-only\n' >"$PROJECT/src/caller-only.txt"
  write_node_ledger implement succeeded "$implement_ws" "$(filesystem_identity "$implement_ws")" implement__run-1__1

  qa_ws="$(graph_workspace_prepare_node "$RUN_DIR" "$GRAPH" qa)"
  [ -f "$qa_ws/src/candidate-only.txt" ]
  [ "$(cat "$qa_ws/src/candidate-only.txt")" = "candidate-only" ]
  [ ! -e "$qa_ws/src/caller-only.txt" ]
  [ "$(cat "$qa_ws/src/app.txt")" = "base" ]
}

@test "graph_workspace_prepare_node fails candidate-missing when candidate is absent or not succeeded" {
  make_binding_project
  jq -cn \
    '{schemaVersion:1,ralphVersion:"test",name:"candidate-binding",
      namespace:"candidate-binding",maxParallel:1,failurePolicy:"drain",
      publishMode:"manual",
      nodes:[
        {id:"implement",type:"agent",dependsOn:[],derivedFrom:"stage",
         stage:{id:"implement",runtime:"cursor",workspaceMode:"snapshot",
                writeScopes:["src/**"]}},
        {id:"qa",type:"agent",dependsOn:["implement"],derivedFrom:"stage",
         stage:{id:"qa",runtime:"cursor",workspaceMode:"snapshot",
                candidateFrom:"implement"}}
      ],edges:[{from:"implement",to:"qa",reasons:["declared"]}]}' >"$GRAPH"
  jq -cn --arg plan "$PLAN" \
    '{schemaVersion:1,ralphVersion:"test",runId:"run-1",planPath:$plan,graphSha:"test",
      startedAt:"2026-01-01T00:00:00Z",status:"running",maxParallel:1}' \
    >"$RUN_DIR/run.json"
  graph_run_base_prepare "$RUN_DIR" \
    "$(jq -cn --arg project "$PROJECT" --arg state "$STATE" --arg agent "$PROJECT" \
      '{projectRoot:$project,stateRoot:$state,agentWorkspace:$agent}')" \
    '["snapshot"]'
  graph_workspace_prepare_run "$RUN_DIR" "$GRAPH"

  run graph_workspace_prepare_node "$RUN_DIR" "$GRAPH" qa
  [ "$status" -ne 0 ]
  [[ "$output" == *"candidate-missing"* ]]

  write_node_ledger implement pending
  run graph_workspace_prepare_node "$RUN_DIR" "$GRAPH" qa
  [ "$status" -ne 0 ]
  [[ "$output" == *"candidate-missing"* ]]
}

@test "graph_publish_finalize refuses when an evaluator receipt differs from integration resultIdentity" {
  local integrate_ws result_identity
  make_binding_project
  jq -cn \
    '{schemaVersion:1,ralphVersion:"test",name:"candidate-binding",
      namespace:"candidate-binding",maxParallel:1,failurePolicy:"drain",
      publishMode:"on-verified",
      nodes:[
        {id:"integrate",type:"integrate",dependsOn:[],derivedFrom:"stage",
         stage:{id:"integrate",workspaceMode:"snapshot"}},
        {id:"qa",type:"agent",dependsOn:["integrate"],derivedFrom:"stage",
         stage:{id:"qa",runtime:"cursor",workspaceMode:"snapshot",
                candidateFrom:"integrate"}}
      ],edges:[{from:"integrate",to:"qa",reasons:["declared"]}]}' >"$GRAPH"
  jq -cn --arg plan "$PLAN" \
    '{schemaVersion:1,ralphVersion:"test",runId:"run-1",planPath:$plan,graphSha:"test",
      startedAt:"2026-01-01T00:00:00Z",status:"running",maxParallel:1}' \
    >"$RUN_DIR/run.json"
  graph_run_base_prepare "$RUN_DIR" \
    "$(jq -cn --arg project "$PROJECT" --arg state "$STATE" --arg agent "$PROJECT" \
      '{projectRoot:$project,stateRoot:$state,agentWorkspace:$agent}')" \
    '["snapshot"]'
  jq '.status = "succeeded"' "$RUN_DIR/run.json" >"$RUN_DIR/run.json.next"
  mv "$RUN_DIR/run.json.next" "$RUN_DIR/run.json"

  INTEGRATION_KEY="$(graph_workspace_node_key integrate)"
  integrate_ws="$RUN_DIR/workspaces/nodes/$INTEGRATION_KEY"
  mkdir -p "$integrate_ws"
  cp -R "$RUN_DIR/base/source"/. "$integrate_ws"
  chmod -R u+w "$integrate_ws"
  printf 'published\n' >"$integrate_ws/src/app.txt"
  result_identity="$(filesystem_identity "$integrate_ws")"
  mkdir -p "$STATE/artifacts/candidate-binding/integration"
  jq -n --arg path "$integrate_ws" --arg identity "$result_identity" \
    '{schemaVersion:1,kind:"graph-integration",nodeId:"integrate",baseIdentity:"unused",
      resultIdentity:$identity,inputs:[],appliedOrder:[],changeCount:1,workspacePath:$path}' \
    >"$STATE/artifacts/candidate-binding/integration/$INTEGRATION_KEY.json"
  write_node_ledger integrate succeeded "$integrate_ws" "$result_identity" integrate__run-1__1
  write_node_ledger qa succeeded "" "wrong-candidate-identity" qa__run-1__1

  run graph_publish_finalize "$RUN_DIR" "$GRAPH" "$PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"publish-candidate-mismatch"* ]] || \
    [[ "$(jq -r '.detail // empty' "$STATE/artifacts/candidate-binding/publish/run-1/recovery.json" 2>/dev/null)" == *"publish-candidate-mismatch"* ]]
}

@test "graph_publish_finalize publishes human-verified-delivery-shaped fixtures with upstream approve-plan" {
  local integrate_ws result_identity
  make_binding_project
  jq -cn \
    '{schemaVersion:1,ralphVersion:"test",name:"candidate-binding",
      namespace:"candidate-binding",maxParallel:1,failurePolicy:"drain",
      publishMode:"on-verified",
      nodes:[
        {id:"plan-implementation",type:"agent",dependsOn:[],derivedFrom:"stage",
         stage:{id:"plan-implementation",runtime:"cursor",workspaceMode:"shared"}},
        {id:"approve-plan",type:"approval",dependsOn:["plan-implementation"],derivedFrom:"stage",
         stage:{id:"approve-plan",type:"approval",question:"Approve plan?",
                changesTarget:"plan-implementation"}},
        {id:"implement",type:"agent",dependsOn:["approve-plan"],derivedFrom:"stage",
         stage:{id:"implement",runtime:"cursor",workspaceMode:"snapshot",
                writeScopes:["src/**"]}},
        {id:"integrate",type:"integrate",dependsOn:["implement"],derivedFrom:"stage",
         stage:{id:"integrate",workspaceMode:"snapshot"}},
        {id:"qa",type:"agent",dependsOn:["integrate"],derivedFrom:"stage",
         stage:{id:"qa",runtime:"cursor",workspaceMode:"snapshot",
                candidateFrom:"integrate"}},
        {id:"approve-result",type:"approval",
         dependsOn:["qa","integrate"],derivedFrom:"stage",
         stage:{id:"approve-result",type:"approval",question:"Accept result?",
                changesTarget:"plan-implementation"}}
      ],
      edges:[
        {from:"plan-implementation",to:"approve-plan",reasons:["declared"]},
        {from:"approve-plan",to:"implement",reasons:["declared"]},
        {from:"implement",to:"integrate",reasons:["declared"]},
        {from:"integrate",to:"qa",reasons:["declared"]},
        {from:"qa",to:"approve-result",reasons:["declared"]},
        {from:"integrate",to:"approve-result",reasons:["declared"]}
      ]}' >"$GRAPH"
  jq -cn --arg plan "$PLAN" \
    '{schemaVersion:1,ralphVersion:"test",runId:"run-1",planPath:$plan,graphSha:"test",
      startedAt:"2026-01-01T00:00:00Z",status:"running",maxParallel:1}' \
    >"$RUN_DIR/run.json"
  graph_run_base_prepare "$RUN_DIR" \
    "$(jq -cn --arg project "$PROJECT" --arg state "$STATE" --arg agent "$PROJECT" \
      '{projectRoot:$project,stateRoot:$state,agentWorkspace:$agent}')" \
    '["snapshot"]'
  jq '.status = "succeeded"' "$RUN_DIR/run.json" >"$RUN_DIR/run.json.next"
  mv "$RUN_DIR/run.json.next" "$RUN_DIR/run.json"

  INTEGRATION_KEY="$(graph_workspace_node_key integrate)"
  integrate_ws="$RUN_DIR/workspaces/nodes/$INTEGRATION_KEY"
  mkdir -p "$integrate_ws"
  cp -R "$RUN_DIR/base/source"/. "$integrate_ws"
  chmod -R u+w "$integrate_ws"
  printf 'published\n' >"$integrate_ws/src/app.txt"
  result_identity="$(filesystem_identity "$integrate_ws")"
  mkdir -p "$STATE/artifacts/candidate-binding/integration"
  jq -n --arg path "$integrate_ws" --arg identity "$result_identity" \
    '{schemaVersion:1,kind:"graph-integration",nodeId:"integrate",baseIdentity:"unused",
      resultIdentity:$identity,inputs:[],appliedOrder:[],changeCount:1,workspacePath:$path}' \
    >"$STATE/artifacts/candidate-binding/integration/$INTEGRATION_KEY.json"

  write_node_ledger plan-implementation succeeded
  write_node_ledger approve-plan succeeded
  write_node_ledger implement succeeded
  write_node_ledger integrate succeeded "$integrate_ws" "$result_identity" integrate__run-1__1
  write_node_ledger qa succeeded "" "$result_identity" qa__run-1__1
  write_node_ledger approve-result succeeded "" "$result_identity" approve-result__run-1__1

  graph_publish_finalize "$RUN_DIR" "$GRAPH" "$PROJECT"
  [ "$(jq -r '.status' "$STATE/artifacts/candidate-binding/publish/run-1/status.json")" = "published" ]
  [ "$(cat "$PROJECT/src/app.txt")" = "published" ]
}

@test "rework-seeded node workspace contains seed changes and changeset is cumulative against base" {
  local implement_ws rework_ws seeded_json seed_identity change_paths
  make_binding_project
  jq -cn \
    '{schemaVersion:1,ralphVersion:"test",name:"candidate-binding",
      namespace:"candidate-binding",maxParallel:1,failurePolicy:"drain",
      publishMode:"manual",
      nodes:[
        {id:"implement",type:"agent",dependsOn:[],derivedFrom:"stage",
         stage:{id:"implement",runtime:"cursor",workspaceMode:"snapshot",
                writeScopes:["src/**"]}},
        {id:"implement-r1",type:"agent",dependsOn:["implement"],derivedFrom:"rework",
         stage:{id:"implement-r1",runtime:"cursor",workspaceMode:"snapshot",
                writeScopes:["src/**"],seedFrom:"implement"}}
      ],edges:[{from:"implement",to:"implement-r1",reasons:["rework"],
                condition:"changes-required"}]}' >"$GRAPH"
  jq -cn --arg plan "$PLAN" \
    '{schemaVersion:1,ralphVersion:"test",runId:"run-1",planPath:$plan,graphSha:"test",
      startedAt:"2026-01-01T00:00:00Z",status:"running",maxParallel:1}' \
    >"$RUN_DIR/run.json"
  graph_run_base_prepare "$RUN_DIR" \
    "$(jq -cn --arg project "$PROJECT" --arg state "$STATE" --arg agent "$PROJECT" \
      '{projectRoot:$project,stateRoot:$state,agentWorkspace:$agent}')" \
    '["snapshot"]'
  graph_workspace_prepare_run "$RUN_DIR" "$GRAPH"

  implement_ws="$(graph_workspace_prepare_node "$RUN_DIR" "$GRAPH" implement)"
  graph_changeset_capture_baseline "$RUN_DIR" "$GRAPH" implement implement__run-1__1 "$implement_ws"
  printf 'seeded-v1\n' >"$implement_ws/src/app.txt"
  printf 'from-seed\n' >"$implement_ws/src/seed-only.txt"
  graph_changeset_capture_node "$RUN_DIR" "$GRAPH" implement implement__run-1__1 "$implement_ws" "$STATE"
  seed_identity="$(filesystem_identity "$implement_ws")"
  write_node_ledger implement succeeded "$implement_ws" "$seed_identity" implement__run-1__1

  rework_ws="$(graph_workspace_prepare_node "$RUN_DIR" "$GRAPH" implement-r1)"
  [ "$(cat "$rework_ws/src/app.txt")" = "base" ]
  [ ! -e "$rework_ws/src/seed-only.txt" ]

  graph_changeset_capture_baseline "$RUN_DIR" "$GRAPH" implement-r1 implement-r1__run-1__1 "$rework_ws"
  seeded_json="$(graph_changeset_seed_rework_node \
    "$RUN_DIR" "$GRAPH" implement-r1 implement-r1__run-1__1 "$rework_ws")"
  [ "$(printf '%s' "$seeded_json" | jq -r '.nodeId')" = "implement" ]
  [ "$(printf '%s' "$seeded_json" | jq -r '.identity')" = "$seed_identity" ]
  [ "$(cat "$rework_ws/src/app.txt")" = "seeded-v1" ]
  [ "$(cat "$rework_ws/src/seed-only.txt")" = "from-seed" ]

  printf 'seeded-plus-new\n' >"$rework_ws/src/app.txt"
  printf 'round-two\n' >"$rework_ws/src/round-two.txt"
  graph_changeset_capture_node "$RUN_DIR" "$GRAPH" implement-r1 implement-r1__run-1__1 "$rework_ws" "$STATE"
  change_paths="$(jq -r '[.changes[].path] | sort | join(",")' \
    "$(graph_changeset_manifest_path "$RUN_DIR" implement-r1)")"
  [[ "$change_paths" == *"src/app.txt"* ]]
  [[ "$change_paths" == *"src/seed-only.txt"* ]]
  [[ "$change_paths" == *"src/round-two.txt"* ]]
  [ "$(jq -r '.changes[] | select(.path=="src/app.txt") | .after.sha256' \
    "$(graph_changeset_manifest_path "$RUN_DIR" implement-r1)" | wc -c)" -gt 1 ]
}

# --- review fixes: seeding, integration sources, approvals, validation ------

write_finished_ledger() {
  local id="$1" status="$2" finished="$3" workspace_path="${4:-}"
  mkdir -p "$RUN_DIR/nodes"
  jq -n --arg id "$id" --arg status "$status" --arg finished "$finished" --arg ws "$workspace_path" \
    '{schemaVersion:1,nodeId:$id,status:$status,lastAttemptId:($id + "__run-1__1"),
      workspacePath:(if $ws == "" then null else $ws end),
      attempts:[{attemptId:($id + "__run-1__1"),finishedAt:$finished,
                 workspacePath:(if $ws == "" then null else $ws end)}]}' \
    >"$RUN_DIR/nodes/$id.json"
}

rework_chain_graph() {
  jq -cn '{schemaVersion:1,ralphVersion:"test",name:"candidate-binding",
    namespace:"candidate-binding",maxParallel:1,failurePolicy:"drain",publishMode:"manual",
    nodes:[
      {id:"implement",type:"agent",dependsOn:[],derivedFrom:"stage",logicalStage:"implement",
       stage:{id:"implement",runtime:"cursor",workspaceMode:"snapshot",writeScopes:["src/**"]}},
      {id:"review",type:"agent",dependsOn:["implement"],derivedFrom:"stage",logicalStage:"review",
       stage:{id:"review",runtime:"cursor",workspaceMode:"snapshot",candidateFrom:"implement"}},
      {id:"implement-r1",type:"agent",dependsOn:["review"],derivedFrom:"rework",logicalStage:"implement",
       stage:{id:"implement-r1",runtime:"cursor",workspaceMode:"snapshot",writeScopes:["src/**"],seedFrom:"implement"}},
      {id:"review-r1",type:"agent",dependsOn:["implement-r1"],derivedFrom:"rework",logicalStage:"review",
       stage:{id:"review-r1",runtime:"cursor",workspaceMode:"snapshot",candidateFrom:"implement-r1"}},
      {id:"review-approved",type:"join",dependsOn:[],derivedFrom:"rework",logicalStage:"review",stage:{id:"review-approved",type:"join"}},
      {id:"integrate",type:"integrate",dependsOn:["review-approved"],derivedFrom:"stage",logicalStage:"integrate",
       stage:{id:"integrate",type:"integrate",workspaceMode:"snapshot"}},
      {id:"qa",type:"agent",dependsOn:["integrate"],derivedFrom:"stage",logicalStage:"qa",
       stage:{id:"qa",runtime:"cursor",workspaceMode:"snapshot",candidateFrom:"integrate"}},
      {id:"implement-q1",type:"agent",dependsOn:["qa"],derivedFrom:"qa-repair",logicalStage:"implement",
       stage:{id:"implement-q1",runtime:"cursor",workspaceMode:"snapshot",writeScopes:["src/**"],seedFrom:"integrate"}}
    ],
    edges:[
      {from:"review",to:"review-approved",reasons:["rework"],condition:"passed"},
      {from:"review",to:"implement-r1",reasons:["rework"],condition:"changes-required"},
      {from:"review-r1",to:"review-approved",reasons:["rework"],condition:"passed"},
      {from:"qa",to:"implement-q1",reasons:["qa-repair"],condition:"changes-required"}
    ]}' >"$GRAPH"
  jq -cn --arg plan "$PLAN" \
    '{schemaVersion:1,ralphVersion:"test",runId:"run-1",planPath:$plan,graphSha:"test",
      startedAt:"2026-01-01T00:00:00Z",status:"running",maxParallel:1}' >"$RUN_DIR/run.json"
  graph_run_base_prepare "$RUN_DIR" \
    "$(jq -cn --arg project "$PROJECT" --arg state "$STATE" --arg agent "$PROJECT" \
      '{projectRoot:$project,stateRoot:$state,agentWorkspace:$agent}')" \
    '["snapshot"]'
  graph_workspace_prepare_run "$RUN_DIR" "$GRAPH"
}

@test "integration applies only the latest rework round, and a QA repair round seeds from the integrated candidate" {
  local ws1 ws2 wsq
  make_binding_project
  source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-integration.sh"
  rework_chain_graph

  # First pass edits app.txt.
  ws1="$(graph_workspace_prepare_node "$RUN_DIR" "$GRAPH" implement)"
  graph_changeset_capture_baseline "$RUN_DIR" "$GRAPH" implement implement__run-1__1 "$ws1"
  printf 'round-0\n' >"$ws1/src/app.txt"
  graph_changeset_capture_node "$RUN_DIR" "$GRAPH" implement implement__run-1__1 "$ws1" "$STATE"
  write_finished_ledger implement succeeded 2026-01-01T00:01:00Z "$ws1"
  write_finished_ledger review succeeded 2026-01-01T00:02:00Z

  # Rework round edits the same file again, seeded from round 0.
  ws2="$(graph_workspace_prepare_node "$RUN_DIR" "$GRAPH" implement-r1)"
  graph_changeset_capture_baseline "$RUN_DIR" "$GRAPH" implement-r1 implement-r1__run-1__1 "$ws2"
  graph_changeset_seed_rework_node "$RUN_DIR" "$GRAPH" implement-r1 implement-r1__run-1__1 "$ws2" >/dev/null
  printf 'round-1\n' >"$ws2/src/app.txt"
  printf 'added-in-round-1\n' >"$ws2/src/extra.txt"
  graph_changeset_capture_node "$RUN_DIR" "$GRAPH" implement-r1 implement-r1__run-1__1 "$ws2" "$STATE"
  write_finished_ledger implement-r1 succeeded 2026-01-01T00:03:00Z "$ws2"
  write_finished_ledger review-r1 succeeded 2026-01-01T00:04:00Z
  write_finished_ledger review-approved succeeded 2026-01-01T00:04:30Z

  # Both rounds reach the join; only the newest, cumulative round integrates.
  run graph_integration_source_node_ids "$RUN_DIR" "$GRAPH" integrate
  [ "$status" -eq 0 ]
  [ "$output" = "implement-r1" ] || { echo "sources=[$output]"; false; }

  # QA evaluated the integrated candidate; its repair round starts there.
  write_finished_ledger integrate succeeded 2026-01-01T00:05:00Z
  write_finished_ledger qa succeeded 2026-01-01T00:06:00Z
  wsq="$(graph_workspace_prepare_node "$RUN_DIR" "$GRAPH" implement-q1)"
  [ "$(cat "$wsq/src/app.txt")" = "base" ]
  graph_changeset_capture_baseline "$RUN_DIR" "$GRAPH" implement-q1 implement-q1__run-1__1 "$wsq"
  run graph_changeset_seed_rework_node "$RUN_DIR" "$GRAPH" implement-q1 implement-q1__run-1__1 "$wsq"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.nodeId')" = "integrate" ]
  [ "$(cat "$wsq/src/app.txt")" = "round-1" ]
  [ "$(cat "$wsq/src/extra.txt")" = "added-in-round-1" ]
}

@test "an approval certifies the last succeeded integrate ancestor, not its first dependency" {
  make_binding_project
  jq -cn '{nodes:[
      {id:"plan",type:"agent",dependsOn:[]},
      {id:"approve-plan",type:"approval",dependsOn:["plan"]},
      {id:"integrate",type:"integrate",dependsOn:["approve-plan"]},
      {id:"qa",type:"agent",dependsOn:["integrate"]},
      {id:"integrate-q1",type:"integrate",dependsOn:["qa"]},
      {id:"qa-q1",type:"agent",dependsOn:["integrate-q1"]},
      {id:"qa-approved",type:"join",dependsOn:[]},
      {id:"qa-gate",type:"gate",dependsOn:["qa-approved"]},
      {id:"approve-result",type:"approval",dependsOn:["qa-gate","integrate"]}],
    edges:[{from:"qa",to:"qa-approved",condition:"passed"},{from:"qa-q1",to:"qa-approved",condition:"passed"}]}' >"$GRAPH"
  write_node_ledger integrate succeeded
  write_node_ledger integrate-q1 pending
  # First dependency is a gate with no identity; the certified candidate is
  # the integrate ancestor that succeeded.
  [ "$(graph_publish_approval_integration_source "$RUN_DIR" "$GRAPH" approve-result)" = "integrate" ]
  write_node_ledger integrate-q1 succeeded
  [ "$(graph_publish_approval_integration_source "$RUN_DIR" "$GRAPH" approve-result)" = "integrate-q1" ]
  # A plan-time approval has no integrate ancestor and certifies nothing.
  [ -z "$(graph_publish_approval_integration_source "$RUN_DIR" "$GRAPH" approve-plan)" ]
}

@test "a writer stage with candidateFrom is rejected at plan validation" {
  local d="$BATS_TEST_TMPDIR/writer.plan.md"
  candidate_plan "$d" implement snapshot
  sed -i.bak 's/^      candidateFrom: implement$/      candidateFrom: implement\n      writeScopes:\n        - docs\/**/' "$d"
  grep -q 'docs/\*\*' "$d"
  run plan_pipeline_graph_json "$d"
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be read-only"* ]]
}

@test "candidateFrom through a review-approved join compiles" {
  local d="$BATS_TEST_TMPDIR/join.plan.md"
  cat >"$d" <<'PLAN'
---
execution: graph
pipeline:
  maxReworkIterations: 1
  stages:
    - id: implement
      runtime: cursor
      workspaceMode: snapshot
      writeScopes:
        - src/**
    - id: review
      runtime: cursor
      workspaceMode: snapshot
      candidateFrom: implement
      dependsOn:
        - implement
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/{{STAGE_ID}}-verdict.json
          required: true
          schema: bundle/.ralph/schemas/evaluator-verdict.schema.json
      loopBackTo: implement
      loopCheck:
        path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/{{STAGE_ID}}-verdict.json
        schema: bundle/.ralph/schemas/evaluator-verdict.schema.json
      onExhausted: fail
    - id: audit
      runtime: cursor
      workspaceMode: snapshot
      candidateFrom: implement
      dependsOn:
        - review-approved
todos:
  - id: implement-1
    stage: implement
    content: implement
    status: pending
  - id: review-1
    stage: review
    content: review
    status: pending
  - id: audit-1
    stage: audit
    content: audit
    status: pending
---
PLAN
  run plan_pipeline_graph_json "$d"
  [ "$status" -eq 0 ]
}

@test "compiled graph validator enforces candidateFrom and accepts bundled delivery graphs" {
  local wf out graph bad
  for wf in feature-delivery bug-fix refactor human-verified-delivery small-feature-delivery; do
    out="$BATS_TEST_TMPDIR/$wf.plan.md"; graph="$BATS_TEST_TMPDIR/$wf.graph.json"
    plan_workflow_instantiate "$REPO_ROOT/bundle/.ralph/workflows/$wf.workflow.md" task "$out" \
      fallback_runtime=cursor fallback_model=auto >/dev/null
    plan_pipeline_graph_json "$out" >"$graph"
    run bash "$REPO_ROOT/bundle/.ralph/bash-lib/graph/validate-graph-schema.sh" "$graph"
    [ "$status" -eq 0 ] || { echo "$wf: $output"; false; }
  done
  bad="$BATS_TEST_TMPDIR/bad.graph.json"
  jq '(.nodes[] | select(.id == "review") | .stage.writeScopes) = ["src/**"]' \
    "$BATS_TEST_TMPDIR/feature-delivery.graph.json" >"$bad"
  run bash "$REPO_ROOT/bundle/.ralph/bash-lib/graph/validate-graph-schema.sh" "$bad"
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be read-only"* ]]
}
