#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/plan-todo.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-state.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-run-base.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-workspace-manager.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-publish.sh"

PUBLISH_SNAPSHOT_HELPER="$REPO_ROOT/bundle/.ralph/python/graph_source_snapshot.py"

make_publish_fixture() {
  local mode="$1"
  TEST_ROOT="$(mktemp -d)"
  PROJECT="$TEST_ROOT/project"
  STATE="$TEST_ROOT/state"
  mkdir -p "$PROJECT/src" "$STATE"
  PROJECT="$(cd "$PROJECT" && pwd -P)"
  STATE="$(cd "$STATE" && pwd -P)"
  RUN_DIR="$STATE/graph-runs/publish-test/run-1"
  GRAPH="$RUN_DIR/graph.json"
  PLAN="$TEST_ROOT/publish.plan.md"
  mkdir -p "$RUN_DIR/nodes"
  printf 'base\n' >"$PROJECT/src/app.txt"
  printf '*.cache\n' >"$PROJECT/.gitignore"
  git init -q "$PROJECT"
  git -C "$PROJECT" add src .gitignore
  git -C "$PROJECT" -c user.name=Ralph -c user.email=ralph@example.invalid \
    commit -qm "base"
  cat >"$GRAPH" <<JSON
{"schemaVersion":1,"ralphVersion":"test","name":"publish-test","namespace":"publish-test","maxParallel":1,"failurePolicy":"drain","publishMode":"$mode","nodes":[{"id":"integrate","type":"integrate","dependsOn":[],"derivedFrom":"stage","stage":{"workspaceMode":"snapshot"}}],"edges":[]}
JSON
  printf '%s\n' '---' 'execution: graph' '---' >"$PLAN"
  jq -cn --arg plan "$PLAN" \
    '{schemaVersion:1,ralphVersion:"test",runId:"run-1",planPath:$plan,graphSha:"test",startedAt:"2026-01-01T00:00:00Z",status:"running",maxParallel:1}' \
    >"$RUN_DIR/run.json"
  graph_run_base_prepare "$RUN_DIR" \
    "$(jq -cn --arg project "$PROJECT" --arg state "$STATE" --arg agent "$PROJECT" \
      '{projectRoot:$project,stateRoot:$state,agentWorkspace:$agent}')" '["snapshot"]'
  jq '.status = "succeeded"' "$RUN_DIR/run.json" >"$RUN_DIR/run.json.next"
  mv "$RUN_DIR/run.json.next" "$RUN_DIR/run.json"
  jq -n '{schemaVersion:1,nodeId:"integrate",status:"succeeded",attempts:[],lastAttemptId:null}' \
    >"$RUN_DIR/nodes/integrate.json"

  INTEGRATION_KEY="$(graph_workspace_node_key integrate)"
  INTEGRATION="$RUN_DIR/workspaces/nodes/$INTEGRATION_KEY"
  mkdir -p "$INTEGRATION"
  cp -R "$RUN_DIR/base/source"/. "$INTEGRATION"
  chmod -R u+w "$INTEGRATION"
  printf 'published\n' >"$INTEGRATION/src/app.txt"
  printf 'new output\n' >"$INTEGRATION/src/new.txt"
  RESULT_IDENTITY="$(python3 "$PUBLISH_SNAPSHOT_HELPER" identity \
    --source "$INTEGRATION" --state-root "$STATE" | jq -r '.filesystemIdentity')"
  mkdir -p "$STATE/artifacts/publish-test/integration"
  jq -n --arg path "$INTEGRATION" --arg identity "$RESULT_IDENTITY" \
    '{schemaVersion:1,kind:"graph-integration",nodeId:"integrate",baseIdentity:"unused",
      resultIdentity:$identity,inputs:[],appliedOrder:[],changeCount:2,workspacePath:$path}' \
    >"$STATE/artifacts/publish-test/integration/$INTEGRATION_KEY.json"
}

publish_status() {
  jq -r '.status' "$STATE/artifacts/publish-test/publish/run-1/status.json"
}

@test "publishMode defaults manual and validates on-verified" {
  local plan="$BATS_TEST_TMPDIR/publish-mode.plan.md"
  cat >"$plan" <<'PLAN'
---
execution: graph
pipeline:
  stages:
    - id: one
      runtime: cursor
      agent: implementation
todos:
  - id: one-todo
    stage: one
    content: test
    status: pending
---
PLAN
  run plan_pipeline_graph_json "$plan"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | awk 'END {print}' | jq -r '.publishMode')" = "manual" ]
  sed -i.bak '/pipeline:/a\
  publishMode: on-verified' "$plan"
  run plan_pipeline_graph_json "$plan"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | awk 'END {print}' | jq -r '.publishMode')" = "on-verified" ]
  sed -i.bak 's/publishMode: on-verified/publishMode: always/' "$plan"
  run plan_pipeline_graph_json "$plan"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid publishMode value"* ]]
}

@test "manual publish leaves verified workspace and backend-neutral bundle without caller mutation" {
  make_publish_fixture manual
  graph_publish_finalize "$RUN_DIR" "$GRAPH" "$PROJECT"
  local handoff="$STATE/artifacts/publish-test/publish/run-1/handoff.json"
  [ "$(cat "$PROJECT/src/app.txt")" = "base" ]
  [ "$(jq -r '.status' "$handoff")" = "ready" ]
  [ "$(jq -r '.verified' "$handoff")" = "true" ]
  [ "$(jq -r '.integrationWorkspace' "$handoff")" = "$INTEGRATION" ]
  [ -f "$(jq -r '.changesetManifest' "$handoff")" ]
  [ -f "$(jq -r '.changesetBundle' "$handoff")" ]
  [ -d "$INTEGRATION" ]
}

@test "on-verified clean publish is guarded, journaled, and idempotent" {
  make_publish_fixture on-verified
  graph_publish_finalize "$RUN_DIR" "$GRAPH" "$PROJECT"
  [ "$(cat "$PROJECT/src/app.txt")" = "published" ]
  [ "$(cat "$PROJECT/src/new.txt")" = "new output" ]
  [ "$(publish_status)" = "published" ]
  [ -s "$STATE/artifacts/publish-test/publish/run-1/publish-journal.jsonl" ]
  graph_publish_finalize "$RUN_DIR" "$GRAPH" "$PROJECT"
  [ "$(publish_status)" = "published" ]
  [ "$(cat "$PROJECT/src/app.txt")" = "published" ]
}

@test "publish selects the succeeded integration before a skipped repair integration" {
  make_publish_fixture on-verified
  jq '.nodes += [{id:"repair-integrate",type:"integrate",dependsOn:["integrate"],derivedFrom:"repair",stage:{workspaceMode:"snapshot"}}]' \
    "$GRAPH" >"$GRAPH.next"
  mv "$GRAPH.next" "$GRAPH"
  jq -n '{schemaVersion:1,nodeId:"repair-integrate",status:"skipped",attempts:[],lastAttemptId:null}' \
    >"$RUN_DIR/nodes/repair-integrate.json"
  graph_publish_finalize "$RUN_DIR" "$GRAPH" "$PROJECT"
  [ "$(publish_status)" = "published" ]
  [ "$(cat "$PROJECT/src/app.txt")" = "published" ]
}

@test "publish refuses changed HEAD and preserves the new commit" {
  make_publish_fixture on-verified
  git -C "$PROJECT" -c user.name=Ralph -c user.email=ralph@example.invalid \
    commit --allow-empty -qm "caller moved"
  local moved
  moved="$(git -C "$PROJECT" rev-parse HEAD)"
  run graph_publish_finalize "$RUN_DIR" "$GRAPH" "$PROJECT"
  [ "$status" -ne 0 ]
  [ "$(git -C "$PROJECT" rev-parse HEAD)" = "$moved" ]
  [ "$(cat "$PROJECT/src/app.txt")" = "base" ]
  [ "$(jq -r '.status' "$STATE/artifacts/publish-test/publish/run-1/recovery.json")" = "refused" ]
  [ -d "$INTEGRATION" ]
}

@test "publish refuses a new tracked local edit without removing it" {
  make_publish_fixture on-verified
  printf 'operator edit\n' >"$PROJECT/src/app.txt"
  run graph_publish_finalize "$RUN_DIR" "$GRAPH" "$PROJECT"
  [ "$status" -ne 0 ]
  [ "$(cat "$PROJECT/src/app.txt")" = "operator edit" ]
  [ ! -e "$PROJECT/src/new.txt" ]
  [ -d "$INTEGRATION" ]
}

@test "publish refuses a new untracked file without removing it" {
  make_publish_fixture on-verified
  printf 'operator untracked\n' >"$PROJECT/operator.txt"
  run graph_publish_finalize "$RUN_DIR" "$GRAPH" "$PROJECT"
  [ "$status" -ne 0 ]
  [ "$(cat "$PROJECT/operator.txt")" = "operator untracked" ]
  [ "$(cat "$PROJECT/src/app.txt")" = "base" ]
}

@test "publish refuses a branch switch even when HEAD and files are unchanged" {
  make_publish_fixture on-verified
  git -C "$PROJECT" branch alternate
  git -C "$PROJECT" checkout -q alternate
  run graph_publish_finalize "$RUN_DIR" "$GRAPH" "$PROJECT"
  [ "$status" -ne 0 ]
  [ "$(git -C "$PROJECT" branch --show-current)" = "alternate" ]
  [ "$(cat "$PROJECT/src/app.txt")" = "base" ]
}

@test "publish interruption rolls caller back and retains exact recovery artifacts" {
  make_publish_fixture on-verified
  run env RALPH_GRAPH_PUBLISH_TEST_INTERRUPT_AFTER=1 bash -c \
    'source "$1"; graph_publish_finalize "$2" "$3" "$4"' \
    publish-interrupt \
    "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-publish.sh" \
    "$RUN_DIR" "$GRAPH" "$PROJECT"
  [ "$status" -ne 0 ]
  [ "$(cat "$PROJECT/src/app.txt")" = "base" ]
  [ ! -e "$PROJECT/src/new.txt" ]
  [ "$(publish_status)" = "rolled-back" ]
  [ "$(jq -r '.status' "$STATE/artifacts/publish-test/publish/run-1/recovery.json")" = "rolled-back" ]
  jq -e 'select(.event == "rollback-completed")' \
    "$STATE/artifacts/publish-test/publish/run-1/publish-journal.jsonl" >/dev/null
  [ -d "$INTEGRATION" ]
  graph_publish_finalize "$RUN_DIR" "$GRAPH" "$PROJECT"
  [ "$(publish_status)" = "published" ]
}

@test "failed gates and pending human input refuse publish and retain integration" {
  make_publish_fixture on-verified
  jq '.status = "failed"' "$RUN_DIR/run.json" >"$RUN_DIR/run.json.next"
  mv "$RUN_DIR/run.json.next" "$RUN_DIR/run.json"
  jq '.status = "failed"' "$RUN_DIR/nodes/integrate.json" >"$RUN_DIR/nodes/integrate.json.next"
  mv "$RUN_DIR/nodes/integrate.json.next" "$RUN_DIR/nodes/integrate.json"
  run graph_publish_finalize "$RUN_DIR" "$GRAPH" "$PROJECT"
  [ "$status" -ne 0 ]
  [ "$(cat "$PROJECT/src/app.txt")" = "base" ]
  [ -d "$INTEGRATION" ]

  make_publish_fixture on-verified
  jq '.status = "awaiting-ack"' "$RUN_DIR/run.json" >"$RUN_DIR/run.json.next"
  mv "$RUN_DIR/run.json.next" "$RUN_DIR/run.json"
  jq '.status = "awaiting-ack"' "$RUN_DIR/nodes/integrate.json" >"$RUN_DIR/nodes/integrate.json.next"
  mv "$RUN_DIR/nodes/integrate.json.next" "$RUN_DIR/nodes/integrate.json"
  run graph_publish_finalize "$RUN_DIR" "$GRAPH" "$PROJECT"
  [ "$status" -ne 0 ]
  [ "$(cat "$PROJECT/src/app.txt")" = "base" ]
  [ -d "$INTEGRATION" ]
}

@test "incomplete delegation and integration conflict refuse publish" {
  make_publish_fixture on-verified
  mkdir -p "$RUN_DIR/nodes/parent/delegations/child"
  printf '{"schemaVersion":1,"delegationId":"child","status":"running"}\n' \
    >"$RUN_DIR/nodes/parent/delegations/child/status.json"
  run graph_publish_finalize "$RUN_DIR" "$GRAPH" "$PROJECT"
  [ "$status" -ne 0 ]
  [ "$(cat "$PROJECT/src/app.txt")" = "base" ]

  make_publish_fixture on-verified
  printf '{"kind":"integration-conflict"}\n' \
    >"$STATE/artifacts/publish-test/integration/$INTEGRATION_KEY.conflict.json"
  run graph_publish_finalize "$RUN_DIR" "$GRAPH" "$PROJECT"
  [ "$status" -ne 0 ]
  [ "$(cat "$PROJECT/src/app.txt")" = "base" ]
  [ -d "$INTEGRATION" ]
}
