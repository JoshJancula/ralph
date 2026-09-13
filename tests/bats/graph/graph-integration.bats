#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/plan-todo.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-state.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-run-base.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-workspace-manager.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-changeset.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-integration.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-publish.sh"

CHANGESET_HELPER="$REPO_ROOT/bundle/.ralph/python/graph_changeset.py"
INTEGRATE_HELPER="$REPO_ROOT/bundle/.ralph/python/graph_integrate.py"
SNAPSHOT_HELPER="$REPO_ROOT/bundle/.ralph/python/graph_source_snapshot.py"

make_changeset() {
  local workspace="$1" baseline="$2" output="$3" node="$4" scopes="$5"
  python3 "$CHANGESET_HELPER" capture --workspace "$workspace" --baseline "$baseline" \
    --output "$output" --node-id "$node" --attempt-id "$node-attempt" \
    --workspace-mode snapshot --base-identity frozen-base --write-scopes-json "$scopes" >/dev/null
}

caller_identity() {
  python3 "$SNAPSHOT_HELPER" identity \
    --source "$PROJECT" --state-root "$STATE" | jq -c .
}

write_node_status() {
  local id="$1" status="$2"
  mkdir -p "$RUN_DIR/nodes"
  jq -n --arg id "$id" --arg status "$status" \
    '{schemaVersion:1,nodeId:$id,status:$status,attempts:[],lastAttemptId:null}' \
    >"$RUN_DIR/nodes/$id.json"
}

# make_manual_integration_fixture <clean|conflict>
# Isolated snapshot run with publishMode=manual, two predecessor lanes, and
# one integrate node. Clean lanes edit disjoint files; conflict lanes edit
# the same file with different bytes.
make_manual_integration_fixture() {
  local mode="$1" namespace run_id left_scope right_scope left_file right_file
  TEST_ROOT="$(mktemp -d)"
  PROJECT="$TEST_ROOT/project"
  STATE="$TEST_ROOT/state"
  mkdir -p "$PROJECT/src" "$STATE" "$PROJECT/.ralph"
  PROJECT="$(cd "$PROJECT" && pwd -P)"
  STATE="$(cd "$STATE" && pwd -P)"
  if [[ "$mode" == "conflict" ]]; then
    namespace="integration-conflict"
    run_id="run-conflict"
    left_scope='["src/shared.txt"]'
    right_scope='["src/shared.txt"]'
    left_file="src/shared.txt"
    right_file="src/shared.txt"
    printf 'base-shared\n' >"$PROJECT/src/shared.txt"
  else
    namespace="integration-clean"
    run_id="run-clean"
    left_scope='["src/left.txt"]'
    right_scope='["src/right.txt"]'
    left_file="src/left.txt"
    right_file="src/right.txt"
    printf 'base-left\n' >"$PROJECT/src/left.txt"
    printf 'base-right\n' >"$PROJECT/src/right.txt"
  fi
  printf 'caller-sentinel\n' >"$PROJECT/caller-sentinel.txt"
  git init -q "$PROJECT"
  git -C "$PROJECT" add .
  git -C "$PROJECT" -c user.name=Ralph -c user.email=ralph@example.invalid \
    commit -qm fixture

  RUN_DIR="$STATE/graph-runs/$namespace/$run_id"
  GRAPH="$RUN_DIR/graph.json"
  PLAN="$TEST_ROOT/${namespace}.plan.md"
  mkdir -p "$RUN_DIR"
  jq -cn --arg ns "$namespace" --argjson leftScope "$left_scope" --argjson rightScope "$right_scope" \
    '{schemaVersion:1,ralphVersion:"test",name:$ns,namespace:$ns,maxParallel:2,
      failurePolicy:"drain",publishMode:"manual",
      nodes:[
        {id:"left",type:"agent",dependsOn:[],derivedFrom:"stage",
         stage:{id:"left",runtime:"cursor",agent:"implementation",
                workspaceMode:"snapshot",writeScopes:$leftScope}},
        {id:"right",type:"agent",dependsOn:[],derivedFrom:"stage",
         stage:{id:"right",runtime:"cursor",agent:"implementation",
                workspaceMode:"snapshot",writeScopes:$rightScope}},
        {id:"integrate",type:"integrate",dependsOn:["left","right"],derivedFrom:"stage",
         stage:{id:"integrate",workspaceMode:"snapshot"}}
      ],edges:[]}' >"$GRAPH"
  printf '%s\n' '---' 'execution: graph' '---' >"$PLAN"
  jq -cn --arg plan "$PLAN" --arg run "$run_id" \
    '{schemaVersion:1,ralphVersion:"test",runId:$run,planPath:$plan,graphSha:"test",
      startedAt:"2026-01-01T00:00:00Z",status:"running",maxParallel:2}' \
    >"$RUN_DIR/run.json"
  graph_run_base_prepare "$RUN_DIR" \
    "$(jq -cn --arg project "$PROJECT" --arg state "$STATE" --arg agent "$PROJECT" \
      '{projectRoot:$project,stateRoot:$state,agentWorkspace:$agent}')" \
    '["snapshot"]'
  graph_workspace_prepare_run "$RUN_DIR" "$GRAPH"

  LEFT="$(graph_workspace_prepare_node "$RUN_DIR" "$GRAPH" left)"
  RIGHT="$(graph_workspace_prepare_node "$RUN_DIR" "$GRAPH" right)"
  INTEGRATION="$(graph_workspace_prepare_node "$RUN_DIR" "$GRAPH" integrate)"
  graph_changeset_capture_baseline "$RUN_DIR" "$GRAPH" left a1 "$LEFT"
  graph_changeset_capture_baseline "$RUN_DIR" "$GRAPH" right a1 "$RIGHT"
  if [[ "$mode" == "conflict" ]]; then
    printf 'left-shared\n' >"$LEFT/$left_file"
    printf 'right-shared\n' >"$RIGHT/$right_file"
  else
    printf 'left-lane\n' >"$LEFT/$left_file"
    printf 'right-lane\n' >"$RIGHT/$right_file"
  fi
  graph_changeset_capture_node "$RUN_DIR" "$GRAPH" left a1 "$LEFT" "$STATE"
  graph_changeset_capture_node "$RUN_DIR" "$GRAPH" right a1 "$RIGHT" "$STATE"
  write_node_status left succeeded
  write_node_status right succeeded
  write_node_status integrate pending
  NAMESPACE="$namespace"
  RUN_ID="$run_id"
  INTEGRATE_KEY="$(graph_workspace_node_key integrate)"
}

@test "integrator applies disjoint backend-neutral changesets in declared order and resumes idempotently" {
  local tmpd base baseline left right third fourth integration out conflict first_identity
  tmpd="$(mktemp -d)"
  base="$tmpd/base"
  mkdir -p "$base/src"
  printf 'base-a\n' >"$base/src/a.txt"
  printf 'base-b\n' >"$base/src/b.txt"
  printf 'base-c\n' >"$base/src/c.txt"
  printf 'base-d\n' >"$base/src/d.txt"
  baseline="$tmpd/baseline.json"
  python3 "$CHANGESET_HELPER" baseline --workspace "$base" --output "$baseline" >/dev/null
  cp -R "$base" "$tmpd/left"
  cp -R "$base" "$tmpd/right"
  cp -R "$base" "$tmpd/third"
  cp -R "$base" "$tmpd/fourth"
  printf 'left\n' >"$tmpd/left/src/a.txt"
  printf 'right\n' >"$tmpd/right/src/b.txt"
  printf 'third\n' >"$tmpd/third/src/c.txt"
  printf 'fourth\n' >"$tmpd/fourth/src/d.txt"
  left="$tmpd/manifests/left.json"
  right="$tmpd/manifests/right.json"
  third="$tmpd/manifests/third.json"
  fourth="$tmpd/manifests/fourth.json"
  make_changeset "$tmpd/left" "$baseline" "$left" left '["src/a.txt"]'
  make_changeset "$tmpd/right" "$baseline" "$right" right '["src/b.txt"]'
  make_changeset "$tmpd/third" "$baseline" "$third" third '["src/c.txt"]'
  make_changeset "$tmpd/fourth" "$baseline" "$fourth" fourth '["src/d.txt"]'
  cp -R "$base" "$tmpd/integration"
  integration="$tmpd/integration"
  out="$tmpd/integration.json"
  conflict="$tmpd/conflict.json"

  run env RALPH_GRAPH_INTEGRATION_TEST_INTERRUPT_AFTER=1 python3 "$INTEGRATE_HELPER" \
    --workspace "$integration" --output "$out" --conflict-output "$conflict" \
    --node-id integrate --base-identity frozen-base \
    --manifest "$right" --manifest "$left" --manifest "$third" --manifest "$fourth"
  [ "$status" -ne 0 ]
  [ ! -e "$out" ]

  python3 "$INTEGRATE_HELPER" --workspace "$integration" --output "$out" \
    --conflict-output "$conflict" --node-id integrate --base-identity frozen-base \
    --manifest "$right" --manifest "$left" --manifest "$third" --manifest "$fourth" >/dev/null
  [ "$(cat "$integration/src/a.txt")" = "left" ]
  [ "$(cat "$integration/src/b.txt")" = "right" ]
  [ "$(cat "$integration/src/c.txt")" = "third" ]
  [ "$(cat "$integration/src/d.txt")" = "fourth" ]
  [ "$(jq -c '.appliedOrder' "$out")" = '["right","left","third","fourth"]' ]
  [ ! -e "$conflict" ]
  first_identity="$(jq -r '.resultIdentity' "$out")"

  # Reapplying after a simulated scheduler restart is idempotent.
  python3 "$INTEGRATE_HELPER" --workspace "$integration" --output "$out" \
    --conflict-output "$conflict" --node-id integrate --base-identity frozen-base \
    --manifest "$right" --manifest "$left" --manifest "$third" --manifest "$fourth" >/dev/null
  [ "$(jq -r '.resultIdentity' "$out")" = "$first_identity" ]
}

@test "integrator accepts identical edits and emits structured overlap conflicts without partial success" {
  local tmpd base baseline one same other rename rename2 delete bin1 bin2 integration out conflict
  tmpd="$(mktemp -d)"
  base="$tmpd/base"
  mkdir -p "$base/src"
  printf 'base\n' >"$base/src/value.txt"
  printf 'rename\n' >"$base/src/old.txt"
  printf '\0base\n' >"$base/src/data.bin"
  baseline="$tmpd/baseline.json"
  python3 "$CHANGESET_HELPER" baseline --workspace "$base" --output "$baseline" >/dev/null
  for lane in one same other rename rename2 delete bin1 bin2; do cp -R "$base" "$tmpd/$lane"; done
  printf 'identical\n' >"$tmpd/one/src/value.txt"
  printf 'identical\n' >"$tmpd/same/src/value.txt"
  printf 'divergent\n' >"$tmpd/other/src/value.txt"
  mv "$tmpd/rename/src/old.txt" "$tmpd/rename/src/new.txt"
  mv "$tmpd/rename2/src/old.txt" "$tmpd/rename2/src/alternate.txt"
  rm "$tmpd/delete/src/value.txt"
  printf '\0one\n' >"$tmpd/bin1/src/data.bin"
  printf '\0two\n' >"$tmpd/bin2/src/data.bin"
  one="$tmpd/manifests/one.json"; same="$tmpd/manifests/same.json"
  other="$tmpd/manifests/other.json"; rename="$tmpd/manifests/rename.json"
  rename2="$tmpd/manifests/rename2.json"; delete="$tmpd/manifests/delete.json"
  bin1="$tmpd/manifests/bin1.json"; bin2="$tmpd/manifests/bin2.json"
  make_changeset "$tmpd/one" "$baseline" "$one" one '["src/value.txt"]'
  make_changeset "$tmpd/same" "$baseline" "$same" same '["src/value.txt"]'
  make_changeset "$tmpd/other" "$baseline" "$other" other '["src/value.txt"]'
  make_changeset "$tmpd/rename" "$baseline" "$rename" rename '["src/**"]'
  make_changeset "$tmpd/rename2" "$baseline" "$rename2" rename2 '["src/**"]'
  make_changeset "$tmpd/delete" "$baseline" "$delete" delete '["src/value.txt"]'
  make_changeset "$tmpd/bin1" "$baseline" "$bin1" bin1 '["src/data.bin"]'
  make_changeset "$tmpd/bin2" "$baseline" "$bin2" bin2 '["src/data.bin"]'
  cp -R "$base" "$tmpd/integration"
  integration="$tmpd/integration"; out="$tmpd/out.json"; conflict="$tmpd/conflict.json"

  python3 "$INTEGRATE_HELPER" --workspace "$integration" --output "$out" \
    --conflict-output "$conflict" --node-id integrate --base-identity frozen-base \
    --manifest "$one" --manifest "$same" --manifest "$rename" >/dev/null
  [ "$(cat "$integration/src/value.txt")" = "identical" ]
  [ -f "$integration/src/new.txt" ]

  cp -R "$base" "$tmpd/conflicting"
  run python3 "$INTEGRATE_HELPER" --workspace "$tmpd/conflicting" --output "$tmpd/no-success.json" \
    --conflict-output "$conflict" --node-id integrate --base-identity frozen-base \
    --manifest "$one" --manifest "$other"
  [ "$status" -ne 0 ]
  [ ! -e "$tmpd/no-success.json" ]
  [ -f "$conflict" ]
  [ "$(jq -r '.kind' "$conflict")" = "integration-conflict" ]
  [ "$(jq -r '.conflicts[0].path' "$conflict")" = "src/value.txt" ]
  [ "$(jq '.conflicts[0].hunks | length' "$conflict")" -gt 0 ]
  [ -n "$(jq -r '.conflicts[0].firstChangeset' "$conflict")" ]
  [ "$(cat "$tmpd/conflicting/src/value.txt")" = "base" ]

  run python3 "$INTEGRATE_HELPER" --workspace "$tmpd/conflicting" --output "$tmpd/no-rename.json" \
    --conflict-output "$tmpd/rename-conflict.json" --node-id integrate --base-identity frozen-base \
    --manifest "$rename" --manifest "$rename2"
  [ "$status" -ne 0 ]
  [ "$(jq -r '.conflicts[0].path' "$tmpd/rename-conflict.json")" = "src/old.txt" ]

  run python3 "$INTEGRATE_HELPER" --workspace "$tmpd/conflicting" --output "$tmpd/no-delete.json" \
    --conflict-output "$tmpd/delete-conflict.json" --node-id integrate --base-identity frozen-base \
    --manifest "$one" --manifest "$delete"
  [ "$status" -ne 0 ]
  [ "$(jq -r '.conflicts[0].path' "$tmpd/delete-conflict.json")" = "src/value.txt" ]

  run python3 "$INTEGRATE_HELPER" --workspace "$tmpd/conflicting" --output "$tmpd/no-binary.json" \
    --conflict-output "$tmpd/binary-conflict.json" --node-id integrate --base-identity frozen-base \
    --manifest "$bin1" --manifest "$bin2"
  [ "$status" -ne 0 ]
  [ "$(jq -r '.conflicts[0].path' "$tmpd/binary-conflict.json")" = "src/data.bin" ]
}

@test "integrator rejects wrong-base and compiler requires an isolated integrate node" {
  local tmpd base baseline lane manifest plan payload
  tmpd="$(mktemp -d)"
  base="$tmpd/base"; lane="$tmpd/lane"
  mkdir -p "$base/src"
  printf 'base\n' >"$base/src/a.txt"
  baseline="$tmpd/baseline.json"
  python3 "$CHANGESET_HELPER" baseline --workspace "$base" --output "$baseline" >/dev/null
  cp -R "$base" "$lane"
  printf 'changed\n' >"$lane/src/a.txt"
  manifest="$tmpd/manifest.json"
  make_changeset "$lane" "$baseline" "$manifest" lane '["src/**"]'
  run python3 "$INTEGRATE_HELPER" --workspace "$base" --output "$tmpd/out.json" \
    --conflict-output "$tmpd/conflict.json" --node-id integrate --base-identity wrong \
    --manifest "$manifest"
  [ "$status" -ne 0 ]
  [[ "$output" = *"wrong-base"* ]]
  run python3 "$INTEGRATE_HELPER" --workspace "$base" --output "$tmpd/missing-out.json" \
    --conflict-output "$tmpd/missing-conflict.json" --node-id integrate --base-identity frozen-base \
    --manifest "$tmpd/does-not-exist.json"
  [ "$status" -ne 0 ]
  [[ "$output" = *"predecessor changeset missing"* ]]

  plan="$tmpd/integrate.plan.md"
  cat >"$plan" <<'PLAN'
---
execution: graph
pipeline:
  stages:
    - id: build
      runtime: cursor
      workspaceMode: snapshot
      writeScopes: [src/**]
    - id: merge
      type: integrate
      workspaceMode: snapshot
      dependsOn: [build]
todos:
  - id: build-1
    stage: build
    content: build
    status: pending
---
PLAN
  run plan_pipeline_graph_json "$plan"
  [ "$status" -eq 0 ]
  payload="$(printf '%s\n' "$output" | awk 'END { print }')"
  [ "$(printf '%s' "$payload" | jq -r '.nodes[] | select(.id == "merge") | .type')" = "integrate" ]
  sed -i.bak '/id: merge/,/dependsOn/ s/workspaceMode: snapshot/workspaceMode: shared/' "$plan"
  run plan_pipeline_graph_json "$plan"
  [ "$status" -ne 0 ]
  [[ "$output" = *"integrate nodes require snapshot or worktree"* ]]
}

@test "manual publication keeps caller bytes unchanged for clean and conflict integration" {
  local caller_before caller_after first_identity second_identity receipt bundle
  local inspect_cmd conflict_file success_file

  make_manual_integration_fixture clean
  caller_before="$(caller_identity)"
  graph_integration_run "$RUN_DIR" "$GRAPH" integrate "$INTEGRATION" "$STATE" "$NAMESPACE"
  success_file="$STATE/artifacts/$NAMESPACE/integration/$INTEGRATE_KEY.json"
  [ -f "$success_file" ]
  [ "$(cat "$INTEGRATION/src/left.txt")" = "left-lane" ]
  [ "$(cat "$INTEGRATION/src/right.txt")" = "right-lane" ]
  [ "$(jq -c '.appliedOrder' "$success_file")" = '["left","right"]' ]
  first_identity="$(jq -r '.resultIdentity' "$success_file")"
  [ -n "$first_identity" ]
  graph_integration_run "$RUN_DIR" "$GRAPH" integrate "$INTEGRATION" "$STATE" "$NAMESPACE"
  second_identity="$(jq -r '.resultIdentity' "$success_file")"
  [ "$second_identity" = "$first_identity" ]
  [ ! -e "$(graph_integration_conflict_recovery_dir "$STATE" "$NAMESPACE" integrate)" ]

  write_node_status left succeeded
  write_node_status right succeeded
  write_node_status integrate succeeded
  jq '.status = "succeeded"' "$RUN_DIR/run.json" >"$RUN_DIR/run.json.next"
  mv "$RUN_DIR/run.json.next" "$RUN_DIR/run.json"
  graph_publish_finalize "$RUN_DIR" "$GRAPH" "$PROJECT"
  caller_after="$(caller_identity)"
  [ "$caller_after" = "$caller_before" ]
  [ "$(cat "$PROJECT/src/left.txt")" = "base-left" ]
  [ "$(cat "$PROJECT/src/right.txt")" = "base-right" ]
  [ "$(cat "$PROJECT/caller-sentinel.txt")" = "caller-sentinel" ]
  [ "$(jq -r '.status' "$STATE/artifacts/$NAMESPACE/publish/$RUN_ID/handoff.json")" = "ready" ]
  [ "$(jq -r '.publishMode' "$STATE/artifacts/$NAMESPACE/publish/$RUN_ID/handoff.json")" = "manual" ]

  make_manual_integration_fixture conflict
  caller_before="$(caller_identity)"
  run graph_integration_run "$RUN_DIR" "$GRAPH" integrate "$INTEGRATION" "$STATE" "$NAMESPACE"
  [ "$status" -ne 0 ]
  success_file="$STATE/artifacts/$NAMESPACE/integration/$INTEGRATE_KEY.json"
  conflict_file="$STATE/artifacts/$NAMESPACE/integration/$INTEGRATE_KEY.conflict.json"
  bundle="$(graph_integration_conflict_recovery_dir "$STATE" "$NAMESPACE" integrate)"
  receipt="$bundle/receipt.json"
  [ ! -e "$success_file" ]
  [ -f "$conflict_file" ]
  [ -f "$receipt" ]
  [ "$(cat "$INTEGRATION/src/shared.txt")" = "base-shared" ]
  [ "$(jq -r '.kind' "$receipt")" = "graph-integration-conflict-receipt" ]
  [ "$(jq -r '.status' "$receipt")" = "conflict" ]
  [ "$(jq -r '.conflictingPaths[]' "$receipt" | grep -c 'src/shared.txt')" -eq 1 ]
  [ "$(jq -r '.integrationBase.filesystemIdentity' "$receipt")" = \
    "$(jq -r '.sourceBase.filesystemIdentity' "$RUN_DIR/run.json")" ]
  [ "$(jq -r '.integrationBase.workspacePath' "$receipt")" = "$INTEGRATION" ]
  [ "$(jq -r '.integrationBase.frozenSourcePath' "$receipt")" = "$RUN_DIR/base/source" ]
  [ "$(jq '(.inputs | length) >= 2' "$receipt")" = "true" ]
  [ -f "$(jq -r '.inputs[0].retainedManifest' "$receipt")" ]
  [ -f "$(jq -r '.inputs[1].retainedManifest' "$receipt")" ]
  [ "$(jq -r '.inputs[0].contentIdentity' "$receipt")" != "null" ]
  inspect_cmd="$(jq -r '.nextCommand' "$receipt")"
  [ "$inspect_cmd" = "$(jq -r '.inspectCommand' "$receipt")" ]
  # The public status verb addresses a run by ID; the graph --namespace/--run
  # selector pair went with the removed graph surface.
  [ "$inspect_cmd" = "ralph workflow status ${RUN_ID}" ]
  [[ "$output" == *"Inspect with: $inspect_cmd"* ]]
  [[ "$output" == *"Recovery bundle: $bundle"* ]]
  [[ "$output" == *"published nothing"* ]]

  caller_after="$(caller_identity)"
  [ "$caller_after" = "$caller_before" ]
  [ "$(cat "$PROJECT/src/shared.txt")" = "base-shared" ]
  [ "$(cat "$PROJECT/caller-sentinel.txt")" = "caller-sentinel" ]

  write_node_status left succeeded
  write_node_status right succeeded
  write_node_status integrate failed
  jq '.status = "failed"' "$RUN_DIR/run.json" >"$RUN_DIR/run.json.next"
  mv "$RUN_DIR/run.json.next" "$RUN_DIR/run.json"
  run graph_publish_finalize "$RUN_DIR" "$GRAPH" "$PROJECT"
  [ "$status" -ne 0 ]
  caller_after="$(caller_identity)"
  [ "$caller_after" = "$caller_before" ]
  [ "$(cat "$PROJECT/src/shared.txt")" = "base-shared" ]
  [ ! -e "$PROJECT/src/left.txt" ]
}

@test "integrate resolves through succeeded review and join passthrough nodes" {
  local success_file
  make_manual_integration_fixture clean

  jq '
    .nodes = [
      (.nodes[] | select(.id == "left")),
      {id:"review",type:"agent",dependsOn:["left"],derivedFrom:"stage",
       stage:{id:"review",runtime:"claude",workspaceMode:"shared"}},
      {id:"review-approved",type:"join",dependsOn:[],derivedFrom:"rework",
       stage:{id:"review-approved",type:"join"}},
      ((.nodes[] | select(.id == "integrate")) | .dependsOn = ["review-approved"])
    ]
    | .edges = [
      {from:"left",to:"review",reasons:["declared"]},
      {from:"review",to:"review-approved",reasons:["rework"],condition:"passed"},
      {from:"review-approved",to:"integrate",reasons:["declared"]}
    ]
  ' "$GRAPH" >"$GRAPH.next"
  mv "$GRAPH.next" "$GRAPH"
  write_node_status left succeeded
  write_node_status review succeeded
  write_node_status review-approved succeeded
  write_node_status integrate pending

  [ "$(graph_integration_source_node_ids "$RUN_DIR" "$GRAPH" integrate)" = "left" ]
  graph_integration_run "$RUN_DIR" "$GRAPH" integrate "$INTEGRATION" "$STATE" "$NAMESPACE"

  success_file="$STATE/artifacts/$NAMESPACE/integration/$INTEGRATE_KEY.json"
  [ -f "$success_file" ]
  [ "$(jq -c '.appliedOrder' "$success_file")" = '["left"]' ]
  [ "$(cat "$INTEGRATION/src/left.txt")" = "left-lane" ]
}
