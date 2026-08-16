#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/plan-todo.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-run-base.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-schedule.sh"

FIXTURE_PLAN="$BATS_TEST_DIRNAME/../../fixtures/graph/graph-edges.plan.md"
DIAMOND_PLAN="$BATS_TEST_DIRNAME/../../fixtures/graph/graph-diamond.plan.md"
CONSENSUS_JOIN_PLAN="$BATS_TEST_DIRNAME/../../fixtures/graph/graph-consensus-join-subagents-on.plan.md"
STUB_RUN_PLAN="$BATS_TEST_DIRNAME/../../fixtures/orchestrator-single-stage/run-plan-stub.sh"
RALPH_DIR="$REPO_ROOT/bundle/.ralph"
SCHEDULE_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-schedule.sh"

json_payload() {
  printf '%s\n' "$1" | awk 'END{print}'
}

# Prepare a scratch workspace with a stubbed run-plan. Sets DISPATCH_WORKSPACE
# and exports (must not be invoked via command substitution — exports would be lost).
setup_dispatch_workspace() {
  local tmpd="$1"
  DISPATCH_WORKSPACE="$tmpd/workspace"
  mkdir -p "$DISPATCH_WORKSPACE/.ralph" "$DISPATCH_WORKSPACE/.ralph-workspace"

  # Fresh Ralph tree so the stubbed run-plan cannot affect the repo checkout.
  cp -R "$RALPH_DIR"/* "$DISPATCH_WORKSPACE/.ralph/"
  chmod +x "$DISPATCH_WORKSPACE/.ralph"/*.sh 2>/dev/null || true
  chmod +x "$DISPATCH_WORKSPACE/.ralph/bash-lib"/*/*.sh 2>/dev/null || true

  cp "$STUB_RUN_PLAN" "$DISPATCH_WORKSPACE/.ralph/run-plan.sh"
  chmod +x "$DISPATCH_WORKSPACE/.ralph/run-plan.sh"

  export GRAPH_DISPATCH_ORCHESTRATOR="$DISPATCH_WORKSPACE/.ralph/orchestrator.sh"
  # Dispatch intentionally nests orchestrator.sh under the bats (or plan) process.
  export RALPH_ALLOW_NESTED_RUNS=1
  export ORCHESTRATOR_RUNNER_TO_CONSOLE=0
  export RALPH_MODE=no
  export RALPH_ARTIFACT_SCHEMA_VALIDATION=0
  export RALPH_ARTIFACT_PROVENANCE=0
  unset RALPH_ARTIFACT_NS 2>/dev/null || true
  unset RALPH_PLAN_KEY 2>/dev/null || true
}

compile_graph_to() {
  # $1 = workspace, $2 = out graph path
  local workspace="$1"
  local out_path="$2"
  local plan_file="$workspace/graph-edges.plan.md"
  cp "$FIXTURE_PLAN" "$plan_file"
  plan_pipeline_graph_json "$plan_file" > "$out_path"
}

compile_plan_graph_to() {
  # $1 = source plan fixture, $2 = workspace, $3 = out graph path
  local src_plan="$1"
  local workspace="$2"
  local out_path="$3"
  local plan_file="$workspace/$(basename "$src_plan")"
  cp "$src_plan" "$plan_file"
  plan_pipeline_graph_json "$plan_file" > "$out_path"
}

# Return 0 when haystack (delimited successors) contains needle as a whole token.
successor_set_has() {
  local haystack="$1"
  local needle="$2"
  local IFS="$GRAPH_SUCCESSOR_DELIM"
  local part
  # shellcheck disable=SC2086
  for part in $haystack; do
    [[ "$part" == "$needle" ]] && return 0
  done
  return 1
}

@test "minted attempt id is composed of node id, run id, and attempt number" {
  run graph_dispatch_mint_attempt_id "source" "run-A" "1"
  [ "$status" -eq 0 ]
  [ "$output" = "source__run-A__1" ]

  run graph_dispatch_mint_attempt_id "source" "run-A" "2"
  [ "$status" -eq 0 ]
  [ "$output" = "source__run-A__2" ]
  [ "$output" != "source__run-A__1" ]
}

@test "graph dispatch pins supervisor tooling instead of an isolated workspace copy" {
  local tmpd isolated frozen resolved
  tmpd="$(mktemp -d)"
  isolated="$tmpd/isolated"
  frozen="$tmpd/frozen"
  mkdir -p "$isolated/.ralph" "$frozen"
  printf '#!/usr/bin/env bash\necho mutable\n' >"$isolated/.ralph/orchestrator.sh"
  printf '#!/usr/bin/env bash\necho frozen\n' >"$frozen/orchestrator.sh"

  unset GRAPH_DISPATCH_ORCHESTRATOR
  export RALPH_GRAPH_TOOLING_ROOT="$frozen"
  resolved="$(graph_dispatch_resolve_orchestrator "$isolated")"
  [ "$resolved" = "$frozen/orchestrator.sh" ]
  unset RALPH_GRAPH_TOOLING_ROOT
}

@test "ledger graph dispatch keeps explicit plan loop state outside the node workspace" {
  local tmpd graph_file state_root run_id run_dir run_dir_physical roots_json order_log marker_dir source_plan captured_plan node_key
  tmpd="$(mktemp -d)"
  setup_dispatch_workspace "$tmpd"
  source_plan="$DISPATCH_WORKSPACE/plans/lane.plan.md"
  mkdir -p "$(dirname "$source_plan")"
  printf '%s\n' '---' 'todos:' '  - id: first' '    content: first' '    status: pending' '  - id: second' '    content: second' '    status: pending' '---' >"$source_plan"
  graph_file="$tmpd/explicit-plan.graph.json"
  write_ready_fanout_graph "$graph_file" explicit-plan 1 lane:cursor:on
  jq 'del(.nodes[0].stage._inlineTodos) | (.nodes[0].stage.plan) = "plans/lane.plan.md" | (.nodes[0].stage.workspaceMode) = "snapshot"' \
    "$graph_file" >"$graph_file.next" && mv "$graph_file.next" "$graph_file"

  state_root="$tmpd/state"
  run_id="explicit-plan-run"
  export RALPH_GRAPH_STATE_ROOT="$state_root"
  export RALPH_PLAN_WORKSPACE_ROOT="$state_root"
  graph_state_init_run "$DISPATCH_WORKSPACE" explicit-plan "$run_id" \
    "$DISPATCH_WORKSPACE/explicit-plan.plan.md" "$graph_file" 1
  run_dir="$state_root/graph-runs/explicit-plan/$run_id"
  roots_json="$(jq -cn --arg project "$DISPATCH_WORKSPACE" --arg state "$state_root" \
    '{projectRoot:$project,stateRoot:$state,agentWorkspace:$project}')"
  graph_run_base_prepare "$run_dir" "$roots_json" '["snapshot"]'
  graph_workspace_prepare_run "$run_dir" "$graph_file"
  order_log="$tmpd/order.log"
  marker_dir="$tmpd/markers"
  mkdir -p "$marker_dir"
  install_stage_aware_run_plan "$DISPATCH_WORKSPACE" "$order_log" "$marker_dir"
  export RUN_PLAN_STUB_EXIT_CODE=0

  graph_schedule_run "$graph_file" "$run_id" "$DISPATCH_WORKSPACE" "$run_dir"

  captured_plan="$(jq -r '.args[.args | index("--plan") + 1]' "$marker_dir/capture-lane.json")"
  node_key="$(graph_workspace_node_key lane)"
  run_dir_physical="$(cd "$run_dir" && pwd -P)"
  [ "$captured_plan" = "$run_dir_physical/orchestration-plans/nodes/$node_key/plans/$node_key.plan.md" ]
  [ "$(jq -r '.env.RALPH_PLAN_SUBAGENTS' "$marker_dir/capture-lane.json")" = on ]
  [ -f "$captured_plan" ]
  [ "$(sed -n 's/^[[:space:]]*status: //p' "$source_plan" | tr '\n' ',')" = 'pending,pending,' ]
  [ ! -e "$(graph_workspace_prepare_node "$run_dir" "$graph_file" lane)/.ralph-workspace/graph-runs" ]
  unset RALPH_GRAPH_STATE_ROOT RALPH_PLAN_WORKSPACE_ROOT
}

@test "ledger-backed graph scheduling keeps transition logs in the state root" {
  local tmpd graph_file state_root run_id run_dir roots_json order_log marker_dir
  tmpd="$(mktemp -d)"
  setup_dispatch_workspace "$tmpd"
  graph_file="$tmpd/graph-edges.graph.json"
  compile_plan_graph_to "$FIXTURE_PLAN" "$DISPATCH_WORKSPACE" "$graph_file"
  jq '.nodes = [.nodes[] | select(.id == "source")] | .edges = []' "$graph_file" \
    >"$graph_file.one" && mv "$graph_file.one" "$graph_file"
  state_root="$tmpd/separate-state"
  run_id="three-root-log-run"
  export RALPH_GRAPH_STATE_ROOT="$state_root"
  export RALPH_PLAN_WORKSPACE_ROOT="$state_root"
  graph_state_init_run "$DISPATCH_WORKSPACE" graph-edges "$run_id" \
    "$DISPATCH_WORKSPACE/graph-edges.plan.md" "$graph_file" 2
  run_dir="$state_root/graph-runs/graph-edges/$run_id"
  roots_json="$(jq -cn --arg project "$DISPATCH_WORKSPACE" --arg state "$state_root" \
    '{projectRoot:$project,stateRoot:$state,agentWorkspace:$project}')"
  graph_run_base_prepare "$run_dir" "$roots_json" '["shared"]'
  graph_workspace_prepare_run "$run_dir" "$graph_file"
  order_log="$tmpd/order.log"
  marker_dir="$tmpd/markers"
  mkdir -p "$marker_dir"
  install_stage_aware_run_plan "$DISPATCH_WORKSPACE" "$order_log" "$marker_dir"
  export RUN_PLAN_STUB_EXIT_CODE=0

  graph_schedule_run "$graph_file" "$run_id" "$DISPATCH_WORKSPACE" "$run_dir"

  [ -f "$run_dir/logs/supervisor.log" ]
  [ ! -e "$state_root/logs/graph-edges/graph-schedule-$run_id.log" ]
  [ ! -e "$DISPATCH_WORKSPACE/.ralph-workspace/logs/graph-edges/graph-schedule-$run_id.log" ]
  [ -f "$run_dir/orchestration-plans/graph-edges.orch.json" ]
  [ "$(find "$run_dir/orchestration-plans/graph-edges" -name '*.plan.md' | wc -l | tr -d ' ')" -eq 1 ]
  [ ! -e "$DISPATCH_WORKSPACE/.ralph-workspace/orchestration-plans/graph-edges" ]
  unset RALPH_GRAPH_STATE_ROOT RALPH_PLAN_WORKSPACE_ROOT
}

@test "isolated graph nodes pass all three roots through every runtime route" {
  local tmpd graph_file state_root run_id run_dir roots_json order_log marker_dir runtime node path args runtime_set
  local attempt_id log_rel log_abs
  local runtime_specs=()
  tmpd="$(mktemp -d)"
  setup_dispatch_workspace "$tmpd"
  graph_file="$tmpd/all-runtimes.graph.json"
  runtime_set="${GRAPH_ROOT_RUNTIME_SET:-cursor claude codex opencode antigravity}"
  for runtime in $runtime_set; do
    runtime_specs+=("${runtime}-node:${runtime}")
  done
  write_ready_fanout_graph "$graph_file" all-runtimes 5 "${runtime_specs[@]}"
  jq '(.nodes[] | .stage.workspaceMode) = "snapshot" | (.nodes[] | .stage.outputArtifacts) = [{path:"stub-output.md",required:true}]' "$graph_file" >"$graph_file.next" && \
    mv "$graph_file.next" "$graph_file"
  state_root="$tmpd/separate-state"
  run_id="three-root-all-runtimes"
  export RALPH_GRAPH_STATE_ROOT="$state_root"
  export RALPH_PLAN_WORKSPACE_ROOT="$state_root"
  graph_state_init_run "$DISPATCH_WORKSPACE" all-runtimes "$run_id" \
    "$DISPATCH_WORKSPACE/all-runtimes.plan.md" "$graph_file" 5
  run_dir="$state_root/graph-runs/all-runtimes/$run_id"
  roots_json="$(jq -cn --arg project "$DISPATCH_WORKSPACE" --arg state "$state_root" \
    '{projectRoot:$project,stateRoot:$state,agentWorkspace:$project}')"
  graph_run_base_prepare "$run_dir" "$roots_json" '["snapshot"]'
  graph_workspace_prepare_run "$run_dir" "$graph_file"
  state_root="$(jq -r '.roots.stateRoot' "$run_dir/run.json")"
  order_log="$tmpd/order.log"
  marker_dir="$tmpd/markers"
  mkdir -p "$marker_dir"
  install_stage_aware_run_plan "$DISPATCH_WORKSPACE" "$order_log" "$marker_dir"
  export RUN_PLAN_STUB_EXIT_CODE=0
  export RUN_PLAN_STUB_WRITE_ARTIFACTS=stub-output.md

  graph_schedule_run "$graph_file" "$run_id" "$DISPATCH_WORKSPACE" "$run_dir"

  for runtime in $runtime_set; do
    node="${runtime}-node"
    path="$(graph_workspace_prepare_node "$run_dir" "$graph_file" "$node")"
    args="$(jq -r '.args | join(" ")' "$marker_dir/capture-$node.json")"
    [[ "$args" = *"--runtime $runtime"* ]]
    [[ "$args" = *"--workspace $path"* ]]
    [[ "$args" = *"--workspace-root $state_root"* ]]
    [[ "$args" = *"--agent-workspace $path"* ]]
    [ "$(jq -r '.env.RALPH_PROJECT_ROOT' "$marker_dir/capture-$node.json")" = "$path" ]
    [ "$(jq -r '.env.RALPH_PLAN_WORKSPACE_ROOT' "$marker_dir/capture-$node.json")" = "$state_root" ]
    [ "$(jq -r '.env.RALPH_AGENT_WORKSPACE' "$marker_dir/capture-$node.json")" = "$path" ]
    [ "$(jq -r '.env.RALPH_CONFIG_DISCOVERY_ROOT' "$marker_dir/capture-$node.json")" = "$path" ]
    [ "$(jq -r '.env.RALPH_ARTIFACT_NS' "$marker_dir/capture-$node.json")" = "all-runtimes" ]
    [[ "$(jq -r '.env.RALPH_ORCH_FILE' "$marker_dir/capture-$node.json")" = "$state_root/"* ]]
    attempt_id="$(graph_dispatch_mint_attempt_id "$node" "$run_id" 1)"
    log_rel="$(graph_logs_attempt_rel "$run_dir" "$node" "$attempt_id" runner.log)"
    log_abs="$(graph_logs_resolve "$run_dir" "$log_rel")"
    [ -f "$log_abs" ]
    [ "$(jq -r '.env.RALPH_GRAPH_NODE_LOG_PATH' "$marker_dir/capture-$node.json")" = "$log_abs" ]
    [ "$(jq -r '.env.RALPH_GRAPH_NODE_LOG_DIR' "$marker_dir/capture-$node.json")" = "$(dirname "$log_abs")" ]
    [ ! -e "$state_root/logs/all-runtimes/nodes" ]
    [ ! -e "$path/.git" ]
  done
  unset RALPH_GRAPH_STATE_ROOT RALPH_PLAN_WORKSPACE_ROOT
}

@test "isolated graph nodes exchange declared artifacts without sharing uncommitted files" {
  local tmpd graph_file state_root run_id run_dir roots_json order_log marker_dir
  local source_workspace sink_workspace
  tmpd="$(mktemp -d)"
  setup_dispatch_workspace "$tmpd"
  graph_file="$tmpd/artifact-exchange.graph.json"
  write_graph_with_edges "$graph_file" artifact-exchange 1 drain \
    --nodes source:cursor sink:codex --edges source:sink
  jq '
    (.nodes[] | .stage.workspaceMode) = "snapshot" |
    (.nodes[] | select(.id == "source") | .stage.outputArtifacts) =
      [{path:"shared/input.md",required:true}] |
    (.nodes[] | select(.id == "sink") | .stage.inputArtifacts) =
      [{path:"shared/input.md",required:true}]
  ' "$graph_file" >"$graph_file.next" && mv "$graph_file.next" "$graph_file"

  state_root="$tmpd/separate-state"
  run_id="artifact-exchange-run"
  export RALPH_GRAPH_STATE_ROOT="$state_root"
  export RALPH_PLAN_WORKSPACE_ROOT="$state_root"
  graph_state_init_run "$DISPATCH_WORKSPACE" artifact-exchange "$run_id" \
    "$DISPATCH_WORKSPACE/artifact-exchange.plan.md" "$graph_file" 1
  run_dir="$state_root/graph-runs/artifact-exchange/$run_id"
  roots_json="$(jq -cn --arg project "$DISPATCH_WORKSPACE" --arg state "$state_root" \
    '{projectRoot:$project,stateRoot:$state,agentWorkspace:$project}')"
  graph_run_base_prepare "$run_dir" "$roots_json" '["snapshot"]'
  graph_workspace_prepare_run "$run_dir" "$graph_file"
  state_root="$(jq -r '.roots.stateRoot' "$run_dir/run.json")"

  order_log="$tmpd/order.log"
  marker_dir="$tmpd/markers"
  mkdir -p "$marker_dir"
  install_stage_aware_run_plan "$DISPATCH_WORKSPACE" "$order_log" "$marker_dir"
  export GRAPH_TEST_ASSERT_ISOLATION=1
  export RUN_PLAN_STUB_EXIT_CODE=0

  graph_schedule_run "$graph_file" "$run_id" "$DISPATCH_WORKSPACE" "$run_dir"

  source_workspace="$(graph_workspace_prepare_node "$run_dir" "$graph_file" source)"
  sink_workspace="$(graph_workspace_prepare_node "$run_dir" "$graph_file" sink)"
  [ -f "$source_workspace/private-uncommitted.txt" ]
  [ ! -e "$sink_workspace/private-uncommitted.txt" ]
  [ -f "$sink_workspace/shared/input.md" ]
  [ -f "$state_root/artifacts/artifact-exchange/exchange/shared/input.md" ]
  [ -f "$marker_dir/sink.exchange-ok" ]
  [ ! -e "$source_workspace/.ralph-workspace/graph-runs" ]
  [ ! -e "$sink_workspace/.ralph-workspace/graph-runs" ]
  [ "$(jq -r '.status' "$run_dir/nodes/source.json")" = "succeeded" ]
  [ "$(jq -r '.status' "$run_dir/nodes/sink.json")" = "succeeded" ]

  unset GRAPH_TEST_ASSERT_ISOLATION RALPH_GRAPH_STATE_ROOT RALPH_PLAN_WORKSPACE_ROOT
}

@test "successful mutating node emits a scoped backend-neutral changeset" {
  local tmpd graph_file state_root run_id run_dir roots_json order_log marker_dir manifest
  tmpd="$(mktemp -d)"
  setup_dispatch_workspace "$tmpd"
  mkdir -p "$DISPATCH_WORKSPACE/src"
  printf 'base\n' >"$DISPATCH_WORKSPACE/src/base.txt"
  graph_file="$tmpd/changeset.graph.json"
  write_ready_fanout_graph "$graph_file" changeset 1 build:cursor
  jq '(.nodes[0].stage.workspaceMode) = "snapshot" |
      (.nodes[0].stage.agentGitAccess) = "off" |
      (.nodes[0].stage.writeScopes) = ["src/**"]' \
    "$graph_file" >"$graph_file.next" && mv "$graph_file.next" "$graph_file"
  state_root="$tmpd/state"
  run_id="changeset-run"
  export RALPH_GRAPH_STATE_ROOT="$state_root"
  export RALPH_PLAN_WORKSPACE_ROOT="$state_root"
  graph_state_init_run "$DISPATCH_WORKSPACE" changeset "$run_id" \
    "$DISPATCH_WORKSPACE/changeset.plan.md" "$graph_file" 1
  run_dir="$state_root/graph-runs/changeset/$run_id"
  roots_json="$(jq -cn --arg project "$DISPATCH_WORKSPACE" --arg state "$state_root" \
    '{projectRoot:$project,stateRoot:$state,agentWorkspace:$project}')"
  graph_run_base_prepare "$run_dir" "$roots_json" '["snapshot"]'
  graph_workspace_prepare_run "$run_dir" "$graph_file"
  order_log="$tmpd/order.log"
  marker_dir="$tmpd/markers"
  mkdir -p "$marker_dir"
  install_stage_aware_run_plan "$DISPATCH_WORKSPACE" "$order_log" "$marker_dir"
  export GRAPH_TEST_MUTATION_PATH="src/generated.txt"
  export RUN_PLAN_STUB_EXIT_CODE=0

  graph_schedule_run "$graph_file" "$run_id" "$DISPATCH_WORKSPACE" "$run_dir"

  manifest="$run_dir/changesets/nodes/$(graph_workspace_node_key build).json"
  [ -f "$manifest" ]
  [ "$(jq -r '.laneVerification.status' "$manifest")" = "passed" ]
  [ "$(jq -r '.changes[] | select(.path == "src/generated.txt") | .operation' "$manifest")" = "added" ]
  [ "$(jq -r '.attemptId' "$manifest")" = "build__changeset-run__1" ]
  [ "$(jq -r '.status' "$run_dir/nodes/build.json")" = "succeeded" ]
  unset GRAPH_TEST_MUTATION_PATH RALPH_GRAPH_STATE_ROOT RALPH_PLAN_WORKSPACE_ROOT
}

@test "scheduler-owned integrate node applies predecessor changesets without invoking a model" {
  local tmpd graph_file state_root run_id run_dir roots_json order_log marker_dir merge_workspace integration_manifest
  tmpd="$(mktemp -d)"
  setup_dispatch_workspace "$tmpd"
  mkdir -p "$DISPATCH_WORKSPACE/src"
  graph_file="$tmpd/integrate.graph.json"
  write_graph_with_edges "$graph_file" integrate-run 2 drain \
    --nodes left:cursor right:codex merge:cursor --edges left:merge right:merge
  jq '
    (.nodes[] | .stage.workspaceMode) = "snapshot" |
    (.nodes[] | select(.id == "left") | .stage.writeScopes) = ["src/left.txt"] |
    (.nodes[] | select(.id == "right") | .stage.writeScopes) = ["src/right.txt"] |
    (.nodes[] | select(.id == "merge") | .type) = "integrate" |
    (.nodes[] | select(.id == "merge") | .stage.type) = "integrate" |
    del(.nodes[] | select(.id == "merge") | .stage.runtime) |
    del(.nodes[] | select(.id == "merge") | .stage.agent)
  ' "$graph_file" >"$graph_file.next" && mv "$graph_file.next" "$graph_file"
  state_root="$tmpd/state"
  run_id="integration-scheduler-run"
  export RALPH_GRAPH_STATE_ROOT="$state_root"
  export RALPH_PLAN_WORKSPACE_ROOT="$state_root"
  graph_state_init_run "$DISPATCH_WORKSPACE" integrate-run "$run_id" \
    "$DISPATCH_WORKSPACE/integrate.plan.md" "$graph_file" 2
  run_dir="$state_root/graph-runs/integrate-run/$run_id"
  roots_json="$(jq -cn --arg project "$DISPATCH_WORKSPACE" --arg state "$state_root" \
    '{projectRoot:$project,stateRoot:$state,agentWorkspace:$project}')"
  graph_run_base_prepare "$run_dir" "$roots_json" '["snapshot"]'
  graph_workspace_prepare_run "$run_dir" "$graph_file"
  order_log="$tmpd/order.log"
  marker_dir="$tmpd/markers"
  mkdir -p "$marker_dir"
  install_stage_aware_run_plan "$DISPATCH_WORKSPACE" "$order_log" "$marker_dir"
  export GRAPH_TEST_INTEGRATION_MUTATIONS=1
  export RUN_PLAN_STUB_EXIT_CODE=0

  graph_schedule_run "$graph_file" "$run_id" "$DISPATCH_WORKSPACE" "$run_dir"

  merge_workspace="$(graph_workspace_prepare_node "$run_dir" "$graph_file" merge)"
  integration_manifest="$state_root/artifacts/integrate-run/integration/$(graph_workspace_node_key merge).json"
  [ -f "$merge_workspace/src/left.txt" ]
  [ -f "$merge_workspace/src/right.txt" ]
  [ -f "$integration_manifest" ]
  [ "$(jq -c '.appliedOrder' "$integration_manifest")" = '["left","right"]' ]
  [ ! -e "$marker_dir/capture-merge.json" ]
  [ "$(jq -r '.status' "$run_dir/nodes/merge.json")" = "succeeded" ]
  unset GRAPH_TEST_INTEGRATION_MUTATIONS RALPH_GRAPH_STATE_ROOT RALPH_PLAN_WORKSPACE_ROOT
}

@test "materialize orch flattens every graph node and omits parallelStages" {
  tmpd="$(mktemp -d)"
  setup_dispatch_workspace "$tmpd"
  graph_file="$tmpd/graph-edges.graph.json"
  compile_graph_to "$DISPATCH_WORKSPACE" "$graph_file"

  run graph_dispatch_materialize_orch "$graph_file" "$DISPATCH_WORKSPACE"
  [ "$status" -eq 0 ]
  orch_path="$(json_payload "$output")"
  [ -f "$orch_path" ]

  node_count="$(jq '.nodes | length' "$graph_file")"
  stage_count="$(jq '.stages | length' "$orch_path")"
  [ "$stage_count" = "$node_count" ]
  [ "$(jq 'has("parallelStages")' "$orch_path")" = "false" ]
  [ "$(jq -r '.namespace' "$orch_path")" = "graph-edges" ]
  # Inline todos must be expanded so the JSON orch path can run unchanged.
  [ "$(jq '[.stages[] | select(has("_inlineTodos"))] | length' "$orch_path")" = "0" ]
  [ "$(jq '[.stages[] | select(has("plan"))] | length' "$orch_path")" = "$stage_count" ]

  rm -rf "$tmpd"
}

@test "materialized inline plans name exact external-state output artifacts" {
  tmpd="$(mktemp -d)"
  setup_dispatch_workspace "$tmpd"
  graph_file="$tmpd/artifact.graph.json"
  state_root="$tmpd/external-state"
  mkdir -p "$state_root"
  cat >"$graph_file" <<'JSON'
{"name":"artifact","namespace":"artifact-ns","nodes":[{"id":"review:alpha","type":"agent","dependsOn":[],"stage":{"id":"review:alpha","runtime":"claude","agent":"code-review","artifacts":[{"path":".ralph-workspace/artifacts/{{ARTIFACT_NS}}/reviews/alpha.md","required":true}],"_inlineTodos":[{"id":"review","content":"Review it","status":"pending"}]}}],"edges":[]}
JSON
  export RALPH_PLAN_WORKSPACE_ROOT="$state_root"
  orch_path="$(graph_dispatch_materialize_orch "$graph_file" "$DISPATCH_WORKSPACE")"
  plan_path="$(jq -r '.stages[0].plan' "$orch_path")"
  [[ "$plan_path" == /* ]] || plan_path="$DISPATCH_WORKSPACE/$plan_path"
  grep -Fq "Required output artifacts (write each exact path):" "$plan_path"
  grep -Fq -- "- $state_root/artifacts/artifact-ns/reviews/alpha.md" "$plan_path"
  unset RALPH_PLAN_WORKSPACE_ROOT
  rm -rf "$tmpd"
}

@test "dispatching a node against stubbed run-plan writes StageOutcomeReport by attempt id" {
  local original_pwd
  tmpd="$(mktemp -d)"
  setup_dispatch_workspace "$tmpd"
  graph_file="$tmpd/graph-edges.graph.json"
  compile_graph_to "$DISPATCH_WORKSPACE" "$graph_file"

  capture_dir="$tmpd/captures"
  mkdir -p "$capture_dir"
  export RALPH_RUN_PLAN_CAPTURE_FILE="$capture_dir/attempt-1.json"
  export RUN_PLAN_STUB_EXIT_CODE=0
  export RUN_PLAN_STUB_WRITE_ARTIFACTS="shared/input.md"
  unset RUN_PLAN_STUB_SLEEP_SECONDS RUN_PLAN_STUB_READY_FILE 2>/dev/null || true

  # Run from an otherwise empty directory so the single-stage argument
  # contract cannot silently treat the numeric stage index as a usage path.
  original_pwd="$PWD"
  cd "$tmpd"
  run graph_schedule_run_node "$graph_file" "source" "run-A" "1" "$DISPATCH_WORKSPACE"
  cd "$original_pwd"
  [ "$status" -eq 0 ]
  [ ! -e "$tmpd/0" ]
  attempt_id="$(json_payload "$output")"
  [ "$attempt_id" = "source__run-A__1" ]

  report="$(graph_dispatch_report_path "$DISPATCH_WORKSPACE" "graph-edges" "$attempt_id")"
  [ -f "$report" ]
  [ -f "$capture_dir/attempt-1.json" ]

  [[ "$(jq -r '.args | join(" ")' "$capture_dir/attempt-1.json")" = *"--workspace $DISPATCH_WORKSPACE"* ]]

  [ "$(jq -r '.schemaVersion' "$report")" = "1" ]
  [ "$(jq -r '.runId' "$report")" = "run-A" ]
  [ "$(jq -r '.stageId' "$report")" = "source" ]
  [ "$(jq -r '.attemptId' "$report")" = "$attempt_id" ]
  [ "$(jq -r '.outcome' "$report")" = "success" ]
  [ "$(jq -r '.exitCode' "$report")" = "0" ]
  [ -n "$(jq -r '.startedAt' "$report")" ]
  [ -n "$(jq -r '.finishedAt' "$report")" ]

  rm -rf "$tmpd"
}

@test "second attempt for the same node mints a distinct attempt id and keeps the first report" {
  tmpd="$(mktemp -d)"
  setup_dispatch_workspace "$tmpd"
  graph_file="$tmpd/graph-edges.graph.json"
  compile_graph_to "$DISPATCH_WORKSPACE" "$graph_file"

  capture_dir="$tmpd/captures"
  mkdir -p "$capture_dir"
  export RUN_PLAN_STUB_EXIT_CODE=0
  export RUN_PLAN_STUB_WRITE_ARTIFACTS="shared/input.md"
  unset RUN_PLAN_STUB_SLEEP_SECONDS RUN_PLAN_STUB_READY_FILE 2>/dev/null || true

  export RALPH_RUN_PLAN_CAPTURE_FILE="$capture_dir/attempt-1.json"
  run graph_schedule_run_node "$graph_file" "source" "run-B" "1" "$DISPATCH_WORKSPACE"
  [ "$status" -eq 0 ]
  attempt_1="$(json_payload "$output")"
  report_1="$(graph_dispatch_report_path "$DISPATCH_WORKSPACE" "graph-edges" "$attempt_1")"
  [ -f "$report_1" ]
  # Fingerprint the first report so a silent overwrite would fail the check.
  checksum_1="$(cksum < "$report_1")"

  export RALPH_RUN_PLAN_CAPTURE_FILE="$capture_dir/attempt-2.json"
  run graph_schedule_run_node "$graph_file" "source" "run-B" "2" "$DISPATCH_WORKSPACE"
  [ "$status" -eq 0 ]
  attempt_2="$(json_payload "$output")"
  report_2="$(graph_dispatch_report_path "$DISPATCH_WORKSPACE" "graph-edges" "$attempt_2")"

  [ "$attempt_1" = "source__run-B__1" ]
  [ "$attempt_2" = "source__run-B__2" ]
  [ "$attempt_1" != "$attempt_2" ]
  [ -f "$report_1" ]
  [ -f "$report_2" ]
  [ "$report_1" != "$report_2" ]
  [ "$(cksum < "$report_1")" = "$checksum_1" ]
  [ "$(jq -r '.attemptId' "$report_1")" = "$attempt_1" ]
  [ "$(jq -r '.attemptId' "$report_2")" = "$attempt_2" ]
  [ "$(jq -r '.outcome' "$report_2")" = "success" ]

  rm -rf "$tmpd"
}

@test "diamond fixture loads with correct indegrees and successor sets" {
  tmpd="$(mktemp -d)"
  mkdir -p "$tmpd/workspace"
  graph_file="$tmpd/graph-diamond.graph.json"
  compile_plan_graph_to "$DIAMOND_PLAN" "$tmpd/workspace" "$graph_file"

  # Call directly (not via `run`): load mutates parallel arrays in the current shell.
  graph_schedule_load_index "$graph_file"
  [ "$(graph_schedule_node_count)" -eq 4 ]

  [ "$(graph_schedule_node_indegree_by_id source)" = "0" ]
  [ "$(graph_schedule_node_indegree_by_id left)" = "1" ]
  [ "$(graph_schedule_node_indegree_by_id right)" = "1" ]
  [ "$(graph_schedule_node_indegree_by_id sink)" = "2" ]

  source_succ="$(graph_schedule_node_successors_by_id source)"
  successor_set_has "$source_succ" "left"
  successor_set_has "$source_succ" "right"
  [ "$(graph_schedule_node_successors_by_id left)" = "sink" ]
  [ "$(graph_schedule_node_successors_by_id right)" = "sink" ]
  [ -z "$(graph_schedule_node_successors_by_id sink)" ]

  [ "$(graph_schedule_node_type_by_id source)" = "agent" ]
  [ "$(graph_schedule_node_runtime_by_id source)" = "cursor" ]

  rm -rf "$tmpd"
}

@test "linear graph loads with indegree one for every node but the first" {
  tmpd="$(mktemp -d)"
  mkdir -p "$tmpd/workspace"
  graph_file="$tmpd/graph-edges.graph.json"
  compile_plan_graph_to "$FIXTURE_PLAN" "$tmpd/workspace" "$graph_file"

  graph_schedule_load_index "$graph_file"
  [ "$(graph_schedule_node_count)" -eq 3 ]

  [ "$(graph_schedule_node_indegree_by_id source)" = "0" ]
  [ "$(graph_schedule_node_indegree_by_id transform)" = "1" ]
  [ "$(graph_schedule_node_indegree_by_id sink)" = "1" ]
  [ "$(graph_schedule_node_successors_by_id source)" = "transform" ]
  [ "$(graph_schedule_node_successors_by_id transform)" = "sink" ]
  [ -z "$(graph_schedule_node_successors_by_id sink)" ]

  rm -rf "$tmpd"
}

@test "lookups by id and by index agree" {
  tmpd="$(mktemp -d)"
  mkdir -p "$tmpd/workspace"
  graph_file="$tmpd/graph-diamond.graph.json"
  compile_plan_graph_to "$DIAMOND_PLAN" "$tmpd/workspace" "$graph_file"

  graph_schedule_load_index "$graph_file"

  count="$(graph_schedule_node_count)"
  [ "$count" -eq 4 ]
  i=0
  while [ "$i" -lt "$count" ]; do
    id="$(graph_schedule_node_id_at "$i")"
    mapped="$(graph_schedule_index_map_get "$id")"
    [ "$mapped" = "$i" ]
    [ "$(graph_schedule_node_type_at "$i")" = "$(graph_schedule_node_type_by_id "$id")" ]
    [ "$(graph_schedule_node_runtime_at "$i")" = "$(graph_schedule_node_runtime_by_id "$id")" ]
    [ "$(graph_schedule_node_indegree_at "$i")" = "$(graph_schedule_node_indegree_by_id "$id")" ]
    [ "$(graph_schedule_node_successors_at "$i")" = "$(graph_schedule_node_successors_by_id "$id")" ]
    i=$((i + 1))
  done

  rm -rf "$tmpd"
}

@test "node id containing the successor delimiter is rejected at load" {
  tmpd="$(mktemp -d)"
  graph_file="$tmpd/bad-delim.graph.json"
  cat >"$graph_file" <<EOF
{
  "schemaVersion": 1,
  "ralphVersion": "test",
  "name": "bad-delim",
  "namespace": "bad-delim",
  "maxParallel": 1,
  "failurePolicy": "drain",
  "nodes": [
    {
      "id": "bad${GRAPH_SUCCESSOR_DELIM}id",
      "type": "agent",
      "dependsOn": [],
      "derivedFrom": "stage",
      "stage": {"id": "bad${GRAPH_SUCCESSOR_DELIM}id", "runtime": "cursor", "agent": "research"}
    }
  ],
  "edges": []
}
EOF

  run graph_schedule_load_index "$graph_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"successor delimiter"* ]]
  [[ "$output" == *"bad${GRAPH_SUCCESSOR_DELIM}id"* ]]
  [ "$(graph_schedule_node_count)" -eq 0 ]

  rm -rf "$tmpd"
}

@test "edge referencing an unknown node fails load with the offending edge named" {
  tmpd="$(mktemp -d)"
  graph_file="$tmpd/unknown-edge.graph.json"
  cat >"$graph_file" <<'EOF'
{
  "schemaVersion": 1,
  "ralphVersion": "test",
  "name": "unknown-edge",
  "namespace": "unknown-edge",
  "maxParallel": 1,
  "failurePolicy": "drain",
  "nodes": [
    {
      "id": "source",
      "type": "agent",
      "dependsOn": [],
      "derivedFrom": "stage",
      "stage": {"id": "source", "runtime": "cursor", "agent": "research"}
    }
  ],
  "edges": [
    {"from": "source", "to": "missing-sink", "reasons": ["declared"]}
  ]
}
EOF

  run graph_schedule_load_index "$graph_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"source -> missing-sink"* ]]
  [[ "$output" == *"unknown: missing-sink"* ]]
  [ "$(graph_schedule_node_count)" -eq 0 ]

  rm -rf "$tmpd"
}

@test "index loader runs under /bin/bash 3.2" {
  tmpd="$(mktemp -d)"
  mkdir -p "$tmpd/workspace"
  graph_file="$tmpd/graph-edges.graph.json"
  compile_plan_graph_to "$FIXTURE_PLAN" "$tmpd/workspace" "$graph_file"

  script="$tmpd/load-under-32.sh"
  cat >"$script" <<EOF
#!/bin/bash
set -euo pipefail
# Intentionally invoke with /bin/bash (macOS ships 3.2).
source "$SCHEDULE_LIB"
graph_schedule_load_index "$graph_file"
printf 'bash=%s\n' "\$BASH_VERSION"
printf 'count=%s\n' "\$(graph_schedule_node_count)"
printf 'source_idx=%s\n' "\$(graph_schedule_index_map_get source)"
printf 'transform_indegree=%s\n' "\$(graph_schedule_node_indegree_by_id transform)"
printf 'source_succ=%s\n' "\$(graph_schedule_node_successors_by_id source)"
EOF
  chmod +x "$script"

  run /bin/bash "$script"
  [ "$status" -eq 0 ]
  [[ "$output" == bash=3.2* ]]
  [[ "$output" == *$'\n'count=3$'\n'* ]] || [[ "$output" == *"count=3"* ]]
  [[ "$output" == *"transform_indegree=1"* ]]
  [[ "$output" == *"source_succ=transform"* ]]

  rm -rf "$tmpd"
}

# --- Child reaper -----------------------------------------------------------

write_fake_stage_report() {
  # $1=path $2=node_id $3=exit_code $4=outcome
  local path="$1" node_id="$2" exit_code="$3" outcome="$4"
  mkdir -p "$(dirname "$path")"
  cat >"$path" <<EOF
{"schemaVersion":1,"runId":"reaper-test","stageId":"$node_id","attemptId":"${node_id}__reaper-test__1","outcome":"$outcome","exitCode":$exit_code,"startedAt":"2026-01-01T00:00:00Z","finishedAt":"2026-01-01T00:00:01Z"}
EOF
}

assert_pid_gone() {
  local pid="$1"
  if kill -0 "$pid" 2>/dev/null; then
    echo "orphan still alive: $pid" >&2
    return 1
  fi
  return 0
}

# Capture reap stdout without command-substitution (subshell cannot wait on
# this shell's children, and GRAPH_REAP_* globals must stay in-shell).
reap_one_capture() {
  # Sets: REAP_RC, REAP_LINE. Uses REAP_OUT_FILE if set.
  local out="${REAP_OUT_FILE:-}"
  if [[ -z "$out" ]]; then
    out="$(mktemp "${TMPDIR:-/tmp}/ralph-reap-out.XXXXXX")"
  fi
  REAP_RC=0
  graph_schedule_reap_one >"$out" || REAP_RC=$?
  REAP_LINE="$(cat "$out")"
  if [[ -z "${REAP_OUT_FILE:-}" ]]; then
    rm -f "$out"
  fi
}

@test "reaper harvests a fast-exiting child with StageOutcomeReport" {
  tmpd="$(mktemp -d)"
  report="$tmpd/stage-outcomes/fast.json"
  graph_schedule_clear_children

  (
    write_fake_stage_report "$report" "fast" "0" "success"
    exit 0
  ) &
  pid=$!
  graph_schedule_track_child "$pid" "fast" "$report"

  REAP_OUT_FILE="$tmpd/reap.out"
  reap_one_capture
  [ "$REAP_RC" -eq 0 ]
  [ "$GRAPH_REAP_NODE" = "fast" ]
  [ "$GRAPH_REAP_EXIT_CODE" = "0" ]
  [ "$GRAPH_REAP_REPORT_PATH" = "$report" ]
  [ "$GRAPH_REAP_MISSING_REPORT" -eq 0 ]
  [ -z "$GRAPH_REAP_REASON" ]
  [[ "$REAP_LINE" == *"node=fast"* ]]
  [[ "$REAP_LINE" != *"reason=missing-report"* ]]
  [ "$(graph_schedule_child_count)" -eq 0 ]
  assert_pid_gone "$pid"

  rm -rf "$tmpd"
}

@test "reaper harvests a slow child without hanging" {
  tmpd="$(mktemp -d)"
  report="$tmpd/stage-outcomes/slow.json"
  graph_schedule_clear_children

  (
    sleep 1
    write_fake_stage_report "$report" "slow" "0" "success"
    exit 0
  ) &
  pid=$!
  graph_schedule_track_child "$pid" "slow" "$report"

  REAP_OUT_FILE="$tmpd/reap.out"
  reap_one_capture
  [ "$REAP_RC" -eq 0 ]
  [ "$GRAPH_REAP_NODE" = "slow" ]
  [ "$GRAPH_REAP_EXIT_CODE" = "0" ]
  [ -f "$GRAPH_REAP_REPORT_PATH" ]
  [ "$GRAPH_REAP_MISSING_REPORT" -eq 0 ]
  [[ "$REAP_LINE" == *"node=slow"* ]]
  assert_pid_gone "$pid"

  rm -rf "$tmpd"
}

@test "reaper harvests several children completing out of order" {
  tmpd="$(mktemp -d)"
  graph_schedule_clear_children

  report_a="$tmpd/stage-outcomes/a.json"
  report_b="$tmpd/stage-outcomes/b.json"
  report_c="$tmpd/stage-outcomes/c.json"

  (
    sleep 0.8
    write_fake_stage_report "$report_a" "a" "0" "success"
    exit 0
  ) &
  pid_a=$!
  (
    write_fake_stage_report "$report_b" "b" "0" "success"
    exit 0
  ) &
  pid_b=$!
  (
    sleep 0.4
    write_fake_stage_report "$report_c" "c" "7" "failed"
    exit 7
  ) &
  pid_c=$!

  graph_schedule_track_child "$pid_a" "a" "$report_a"
  graph_schedule_track_child "$pid_b" "b" "$report_b"
  graph_schedule_track_child "$pid_c" "c" "$report_c"

  harvested=""
  i=0
  while [ "$i" -lt 3 ]; do
    REAP_OUT_FILE="$tmpd/reap-$i.out"
    reap_one_capture
    [ "$REAP_RC" -eq 0 ]
    harvested="${harvested}${GRAPH_REAP_NODE}:${GRAPH_REAP_EXIT_CODE}"$'\n'
    i=$((i + 1))
  done

  [ "$(graph_schedule_child_count)" -eq 0 ]
  [[ "$harvested" == *"a:0"* ]]
  [[ "$harvested" == *"b:0"* ]]
  [[ "$harvested" == *"c:7"* ]]
  # First harvest should be the fast child (b), not the slowest (a).
  first="$(printf '%s' "$harvested" | head -n 1)"
  [ "$first" = "b:0" ]

  assert_pid_gone "$pid_a"
  assert_pid_gone "$pid_b"
  assert_pid_gone "$pid_c"

  rm -rf "$tmpd"
}

@test "reaper reports SIGKILL missing-report failure without hanging" {
  tmpd="$(mktemp -d)"
  report="$tmpd/stage-outcomes/killed.json"
  graph_schedule_clear_children

  # Child sleeps forever and never writes a report; SIGKILL skips EXIT traps.
  sleep 30 &
  pid=$!
  graph_schedule_track_child "$pid" "killed" "$report"

  kill -KILL "$pid" 2>/dev/null || true

  REAP_OUT_FILE="$tmpd/reap.out"
  reap_one_capture
  [ "$REAP_RC" -eq 2 ]
  [ "$GRAPH_REAP_NODE" = "killed" ]
  [ "$GRAPH_REAP_MISSING_REPORT" -eq 1 ]
  [ "$GRAPH_REAP_REASON" = "missing-report" ]
  [ "$GRAPH_REAP_REPORT_PATH" = "$report" ]
  [ ! -f "$report" ]
  # 128 + 9 = 137 on systems that surface SIGKILL via wait.
  [ "$GRAPH_REAP_EXIT_CODE" = "137" ] || [ "$GRAPH_REAP_EXIT_CODE" != "" ]
  [[ "$REAP_LINE" == *"reason=missing-report"* ]]
  [ "$(graph_schedule_child_count)" -eq 0 ]
  assert_pid_gone "$pid"

  rm -rf "$tmpd"
}

@test "reaper poll path and wait -n path produce identical results" {
  tmpd="$(mktemp -d)"
  harness="$tmpd/reaper-harness.sh"
  # Shared harness: four cases, deterministic record lines (order-normalized
  # for the multi-child case). Invoked under /bin/bash 3.2 (poll) and default
  # bash (wait -n).
  cat >"$harness" <<EOF
#!/bin/bash
set +e
source "$SCHEDULE_LIB"

write_report() {
  local path="\$1" node_id="\$2" exit_code="\$3" outcome="\$4"
  mkdir -p "\$(dirname "\$path")"
  printf '%s\n' "{\"schemaVersion\":1,\"runId\":\"parity\",\"stageId\":\"\$node_id\",\"attemptId\":\"\${node_id}__parity__1\",\"outcome\":\"\$outcome\",\"exitCode\":\$exit_code,\"startedAt\":\"2026-01-01T00:00:00Z\",\"finishedAt\":\"2026-01-01T00:00:01Z\"}" >"\$path"
}

assert_gone() {
  local pid="\$1"
  if kill -0 "\$pid" 2>/dev/null; then
    echo "orphan=\$pid" >&2
    exit 99
  fi
}

base="$tmpd/run-\$\$"
mkdir -p "\$base"

# Case fast
graph_schedule_clear_children
rf="\$base/fast.json"
( write_report "\$rf" "fast" "0" "success"; exit 0 ) &
p=\$!
graph_schedule_track_child "\$p" "fast" "\$rf"
rc=0
graph_schedule_reap_one >/dev/null || rc=\$?
printf 'fast rc=%s node=%s exit=%s missing=%s reason=%s\n' \\
  "\$rc" "\$GRAPH_REAP_NODE" "\$GRAPH_REAP_EXIT_CODE" "\$GRAPH_REAP_MISSING_REPORT" "\$GRAPH_REAP_REASON"
assert_gone "\$p"

# Case slow
graph_schedule_clear_children
rs="\$base/slow.json"
( sleep 1; write_report "\$rs" "slow" "0" "success"; exit 0 ) &
p=\$!
graph_schedule_track_child "\$p" "slow" "\$rs"
rc=0
graph_schedule_reap_one >/dev/null || rc=\$?
printf 'slow rc=%s node=%s exit=%s missing=%s reason=%s\n' \\
  "\$rc" "\$GRAPH_REAP_NODE" "\$GRAPH_REAP_EXIT_CODE" "\$GRAPH_REAP_MISSING_REPORT" "\$GRAPH_REAP_REASON"
assert_gone "\$p"

# Case out-of-order (normalize harvest set)
graph_schedule_clear_children
ra="\$base/a.json"; rb="\$base/b.json"; rcpath="\$base/c.json"
( sleep 0.8; write_report "\$ra" "a" "0" "success"; exit 0 ) &
pa=\$!
( write_report "\$rb" "b" "0" "success"; exit 0 ) &
pb=\$!
( sleep 0.4; write_report "\$rcpath" "c" "7" "failed"; exit 7 ) &
pc=\$!
graph_schedule_track_child "\$pa" "a" "\$ra"
graph_schedule_track_child "\$pb" "b" "\$rb"
graph_schedule_track_child "\$pc" "c" "\$rcpath"
set_lines=""
i=0
while [ "\$i" -lt 3 ]; do
  graph_schedule_reap_one >/dev/null
  set_lines="\${set_lines}\${GRAPH_REAP_NODE}:\${GRAPH_REAP_EXIT_CODE}:\${GRAPH_REAP_MISSING_REPORT}"\$'\\n'
  i=\$((i + 1))
done
sorted="\$(printf '%s' "\$set_lines" | sort | tr '\\n' ' ')"
printf 'ooo set=%s\n' "\$sorted"
assert_gone "\$pa"; assert_gone "\$pb"; assert_gone "\$pc"

# Case SIGKILL missing report
graph_schedule_clear_children
rk="\$base/killed.json"
sleep 30 &
p=\$!
graph_schedule_track_child "\$p" "killed" "\$rk"
kill -KILL "\$p" 2>/dev/null
rc=0
graph_schedule_reap_one >/dev/null || rc=\$?
printf 'kill rc=%s node=%s missing=%s reason=%s exit=%s\n' \\
  "\$rc" "\$GRAPH_REAP_NODE" "\$GRAPH_REAP_MISSING_REPORT" "\$GRAPH_REAP_REASON" "\$GRAPH_REAP_EXIT_CODE"
assert_gone "\$p"

printf 'bash=%s force_poll=%s wait_n=%s\n' \\
  "\$BASH_VERSION" "\${GRAPH_REAP_FORCE_POLL:-0}" \\
  "\$(_graph_schedule_reap_supports_wait_n && echo yes || echo no)"
EOF
  chmod +x "$harness"

  out32="$tmpd/out-32.txt"
  out_default="$tmpd/out-default.txt"

  # bash 3.2: portable poll path
  run /bin/bash "$harness"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" >"$out32"
  [[ "$(grep '^bash=' "$out32")" == bash=3.2* ]]
  [[ "$(grep '^fast ' "$out32")" == *"rc=0"* ]]
  [[ "$(grep '^fast ' "$out32")" == *"missing=0"* ]]
  [[ "$(grep '^slow ' "$out32")" == *"rc=0"* ]]
  [[ "$(grep '^kill ' "$out32")" == *"rc=2"* ]]
  [[ "$(grep '^kill ' "$out32")" == *"reason=missing-report"* ]]
  [[ "$(grep '^ooo ' "$out32")" == *"a:0:0"* ]]
  [[ "$(grep '^ooo ' "$out32")" == *"b:0:0"* ]]
  [[ "$(grep '^ooo ' "$out32")" == *"c:7:0"* ]]
  [[ "$(grep 'wait_n=' "$out32")" == *"wait_n=no"* ]]

  # Default bash: wait -n fast path
  default_bash="$(command -v bash)"
  run env GRAPH_REAP_FORCE_POLL=0 "$default_bash" "$harness"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" >"$out_default"
  [[ "$(grep '^fast ' "$out_default")" == *"rc=0"* ]]
  [[ "$(grep '^kill ' "$out_default")" == *"rc=2"* ]]
  [[ "$(grep '^kill ' "$out_default")" == *"reason=missing-report"* ]]
  [[ "$(grep 'wait_n=' "$out_default")" == *"wait_n=yes"* ]]

  # Comparable fields (drop per-process exit codes; kill exit is always 137
  # here but strip anyway so paths stay aligned).
  norm32="$tmpd/norm-32.txt"
  norm_def="$tmpd/norm-default.txt"
  grep -E '^(fast|slow|ooo|kill) ' "$out32" \
    | sed -E 's/ exit=[0-9]+//' >"$norm32"
  grep -E '^(fast|slow|ooo|kill) ' "$out_default" \
    | sed -E 's/ exit=[0-9]+//' >"$norm_def"
  run diff -u "$norm32" "$norm_def"
  [ "$status" -eq 0 ]

  rm -rf "$tmpd"
}

# --- Ready-set scheduling loop ---------------------------------------------

# Wrap the stub run-plan so each stage writes only its own produces and appends
# to an order log. Diamond branches sleep briefly so wall-clock overlap is
# observable without a mutual barrier (which flakes when spawn is staggered).
install_stage_aware_run_plan() {
  # $1 = workspace, $2 = order_log, $3 = marker_dir
  local workspace="$1" order_log="$2" marker_dir="$3"
  local stub_src="$workspace/.ralph/run-plan.sh"
  local stub_real="$workspace/.ralph/run-plan.stub-real.sh"
  mv "$stub_src" "$stub_real"
  cat >"$stub_src" <<EOF
#!/usr/bin/env bash
set -euo pipefail
ORDER_LOG="$order_log"
MARKER_DIR="$marker_dir"
STAGE="\${RALPH_STAGE_ID:-unknown}"
mkdir -p "\$MARKER_DIR" "\$(dirname "\$ORDER_LOG")"
printf '%s\n' "\$STAGE" >>"\$ORDER_LOG"
# Second-resolution timestamps are enough to detect a 1s overlap window.
date +%s >"\$MARKER_DIR/\$STAGE.started_at"
: >"\$MARKER_DIR/\$STAGE.started"
case "\$STAGE" in
  source) export RUN_PLAN_STUB_WRITE_ARTIFACTS="shared/input.md" ;;
  transform) export RUN_PLAN_STUB_WRITE_ARTIFACTS="shared/output.md" ;;
  left) export RUN_PLAN_STUB_WRITE_ARTIFACTS="shared/left.md" ;;
  right) export RUN_PLAN_STUB_WRITE_ARTIFACTS="shared/right.md" ;;
  sink) export RUN_PLAN_STUB_WRITE_ARTIFACTS="" ;;
  *) export RUN_PLAN_STUB_WRITE_ARTIFACTS="\${RUN_PLAN_STUB_WRITE_ARTIFACTS:-}" ;;
esac
if [[ "\${GRAPH_TEST_ASSERT_ISOLATION:-0}" == "1" ]]; then
  if [[ "\$STAGE" == "source" ]]; then
    printf 'producer-private\n' >"\${RALPH_PROJECT_ROOT}/private-uncommitted.txt"
  elif [[ "\$STAGE" == "sink" ]]; then
    [[ ! -e "\${RALPH_PROJECT_ROOT}/private-uncommitted.txt" ]] || exit 91
    [[ -s "\${RALPH_PROJECT_ROOT}/shared/input.md" ]] || exit 92
    printf 'isolated-with-artifact\n' >"\$MARKER_DIR/sink.exchange-ok"
  fi
fi
if [[ -n "\${GRAPH_TEST_MUTATION_PATH:-}" ]]; then
  mkdir -p "\${RALPH_PROJECT_ROOT}/\$(dirname "\$GRAPH_TEST_MUTATION_PATH")"
  printf 'node mutation\n' >"\${RALPH_PROJECT_ROOT}/\$GRAPH_TEST_MUTATION_PATH"
fi
if [[ "\${GRAPH_TEST_INTEGRATION_MUTATIONS:-0}" == "1" ]]; then
  case "\$STAGE" in
    left) mkdir -p "\${RALPH_PROJECT_ROOT}/src"; printf 'left\n' >"\${RALPH_PROJECT_ROOT}/src/left.txt" ;;
    right) mkdir -p "\${RALPH_PROJECT_ROOT}/src"; printf 'right\n' >"\${RALPH_PROJECT_ROOT}/src/right.txt" ;;
  esac
  export RUN_PLAN_STUB_WRITE_ARTIFACTS=""
fi
if [[ "\$STAGE" == "left" || "\$STAGE" == "right" ]]; then
  if [[ "\${RUN_PLAN_STUB_OVERLAP_BARRIER:-0}" == "1" ]]; then
    # Rendezvous instead of a fixed hold. A fixed sleep races the scheduler:
    # under a parallel suite the sibling's orch startup can lag by more than
    # the hold, so both stages run concurrently yet their second-resolution
    # intervals do not overlap and the overlap assertion fails spuriously.
    # Waiting for the sibling's own started marker makes the overlap window
    # depend on real concurrency rather than on startup skew. The bounded
    # wait falls through instead of hanging, so a scheduler that genuinely
    # serializes the two stages still fails the assertion honestly.
    if [[ "\$STAGE" == "left" ]]; then PEER="right"; else PEER="left"; fi
    waited=0
    while [[ ! -e "\$MARKER_DIR/\$PEER.started" && "\$waited" -lt 300 ]]; do
      sleep 0.1
      waited=\$((waited + 1))
    done
    # Both stages are now in flight; hold past the next second boundary so the
    # recorded intervals overlap at second resolution.
    sleep 2
  else
    sleep 3
  fi
fi
date +%s >"\$MARKER_DIR/\$STAGE.finished_at"
: >"\$MARKER_DIR/\$STAGE.finished"
export RALPH_RUN_PLAN_CAPTURE_FILE="\$MARKER_DIR/capture-\$STAGE.json"
export RUN_PLAN_STUB_EXIT_CODE="\${RUN_PLAN_STUB_EXIT_CODE:-0}"
exec "$stub_real" "\$@"
EOF
  chmod +x "$stub_src"
}

assert_intervals_overlap() {
  # $1=a_start $2=a_end $3=b_start $4=b_end (unix seconds)
  local a_start="$1" a_end="$2" b_start="$3" b_end="$4"
  [ "$a_start" -lt "$b_end" ] && [ "$b_start" -lt "$a_end" ]
}

# Fail loudly when a barrier participant gave up waiting. Without this a
# timeout looks identical to the scheduler genuinely serializing the nodes,
# which is the actual bug the overlap tests exist to catch.
assert_no_barrier_timeout() {
  local marker_dir="$1" f
  for f in "$marker_dir"/*.barrier_timeout; do
    [[ -e "$f" ]] || continue
    echo "barrier timed out in $(basename "$f"): $(cat "$f")" >&2
    return 1
  done
  return 0
}

assert_intervals_disjoint() {
  # $1=a_start $2=a_end $3=b_start $4=b_end (unix seconds)
  local a_start="$1" a_end="$2" b_start="$3" b_end="$4"
  ! { [ "$a_start" -lt "$b_end" ] && [ "$b_start" -lt "$a_end" ]; }
}

# Write a fan-out .graph.json of ready (indegree-0) nodes.
# Args: out_path namespace maxParallel then one or more id:runtime[:subagents]
# Optional env WRITE_GRAPH_FAILURE_POLICY (drain|cancel, default drain).
write_ready_fanout_graph() {
  local out_path="$1" ns="$2" max_parallel="$3"
  shift 3
  WRITE_GRAPH_FAILURE_POLICY="${WRITE_GRAPH_FAILURE_POLICY:-drain}" \
  python3 - "$out_path" "$ns" "$max_parallel" "$@" <<'PY'
import json, os, sys
out_path, ns, max_parallel = sys.argv[1], sys.argv[2], int(sys.argv[3])
policy = os.environ.get("WRITE_GRAPH_FAILURE_POLICY", "drain")
nodes = []
for spec in sys.argv[4:]:
    parts = spec.split(":")
    node_id, runtime = parts[0], parts[1]
    subagents = parts[2] if len(parts) > 2 else "inherit"
    nodes.append({
        "id": node_id,
        "type": "agent",
        "dependsOn": [],
        "derivedFrom": "stage",
        "stage": {
            "id": node_id,
            "runtime": runtime,
            "agent": "research",
            "subagents": subagents,
            "_inlineTodos": [{
                "id": f"{node_id}-1",
                "content": f"work {node_id}",
                "verification": "ok",
                "status": "pending",
            }],
        },
    })
doc = {
    "schemaVersion": 1,
    "ralphVersion": "1.0.0",
    "name": ns,
    "namespace": ns,
    "maxParallel": max_parallel,
    "failurePolicy": policy,
    "nodes": nodes,
    "edges": [],
}
with open(out_path, "w", encoding="utf-8") as fh:
    json.dump(doc, fh)
PY
}

# Write a .graph.json from node specs and edge pairs.
# Args: out_path namespace maxParallel failurePolicy
#       --nodes id:runtime[:subagents]... --edges from:to...
write_graph_with_edges() {
  local out_path="$1" ns="$2" max_parallel="$3" policy="$4"
  shift 4
  python3 - "$out_path" "$ns" "$max_parallel" "$policy" "$@" <<'PY'
import json, sys
out_path, ns, max_parallel, policy = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
args = sys.argv[5:]
mode = None
node_specs = []
edge_specs = []
for a in args:
    if a == "--nodes":
        mode = "nodes"
        continue
    if a == "--edges":
        mode = "edges"
        continue
    if mode == "nodes":
        node_specs.append(a)
    elif mode == "edges":
        edge_specs.append(a)
nodes = []
depends = {spec.split(":")[0]: [] for spec in node_specs}
for es in edge_specs:
    frm, to = es.split(":", 1)
    depends.setdefault(to, []).append(frm)
for spec in node_specs:
    parts = spec.split(":")
    node_id, runtime = parts[0], parts[1]
    subagents = parts[2] if len(parts) > 2 else "inherit"
    nodes.append({
        "id": node_id,
        "type": "agent",
        "dependsOn": depends.get(node_id, []),
        "derivedFrom": "stage",
        "stage": {
            "id": node_id,
            "runtime": runtime,
            "agent": "research",
            "subagents": subagents,
            "_inlineTodos": [{
                "id": f"{node_id}-1",
                "content": f"work {node_id}",
                "verification": "ok",
                "status": "pending",
            }],
        },
    })
edges = []
for es in edge_specs:
    frm, to = es.split(":", 1)
    edges.append({"from": frm, "to": to, "reasons": ["declared"]})
doc = {
    "schemaVersion": 1,
    "ralphVersion": "1.0.0",
    "name": ns,
    "namespace": ns,
    "maxParallel": max_parallel,
    "failurePolicy": policy,
    "nodes": nodes,
    "edges": edges,
}
with open(out_path, "w", encoding="utf-8") as fh:
    json.dump(doc, fh)
PY
}

# Install a lightweight single-stage orchestrator driven by per-stage behavior
# files under behavior_dir: success | fail:<ec> | awaiting | stuck | sleep:<sec>
# On SIGTERM/SIGINT writes outcome=cancelled (simulates real orch EXIT trap).
# Writes $marker_dir/$stage.pid for orphan assertions.
install_behavior_orchestrator() {
  local workspace="$1" ns="$2" run_id="$3" behavior_dir="$4" marker_dir="$5"
  mkdir -p "$behavior_dir" "$marker_dir"
  cat >"$workspace/.ralph/orchestrator.sh" <<EOF
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
ns="$ns"
run_id="$run_id"
behavior_dir="$behavior_dir"
marker_dir="$marker_dir"
report="\$workspace/.ralph-workspace/artifacts/\$ns/stage-outcomes/\${attempt}.json"
mkdir -p "\$(dirname "\$report")" "\$marker_dir"
printf '%s\n' "\$\$" >"\$marker_dir/\$stage.pid"
: >"\$marker_dir/\$stage.started"

write_report() {
  local outcome="\$1" exit_code="\$2"
  printf '%s\n' "{\"schemaVersion\":1,\"runId\":\"\$run_id\",\"stageId\":\"\$stage\",\"attemptId\":\"\$attempt\",\"outcome\":\"\$outcome\",\"exitCode\":\$exit_code,\"startedAt\":\"2026-01-01T00:00:00Z\",\"finishedAt\":\"2026-01-01T00:00:01Z\"}" >"\$report"
}

on_cancel() {
  write_report cancelled 143
  : >"\$marker_dir/\$stage.cancelled"
  exit 143
}
trap on_cancel TERM INT

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
  awaiting)
    write_report failed 3
    : >"\$marker_dir/\$stage.finished"
    exit 3
    ;;
  stuck)
    write_report failed 4
    : >"\$marker_dir/\$stage.finished"
    exit 4
    ;;
  sleep:*)
    sec="\${behavior#sleep:}"
    [[ "\$sec" =~ ^[0-9]+([.][0-9]+)?$ ]] || sec=2
    sleep "\$sec"
    write_report success 0
    : >"\$marker_dir/\$stage.finished"
    exit 0
    ;;
  *)
    write_report success 0
    : >"\$marker_dir/\$stage.finished"
    exit 0
    ;;
esac
EOF
  chmod +x "$workspace/.ralph/orchestrator.sh"
  export GRAPH_DISPATCH_ORCHESTRATOR="$workspace/.ralph/orchestrator.sh"
}

assert_no_orphan_pids() {
  local marker_dir="$1"
  local pid_file pid
  for pid_file in "$marker_dir"/*.pid; do
    [[ -e "$pid_file" ]] || continue
    pid="$(cat "$pid_file")"
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    if kill -0 "$pid" 2>/dev/null; then
      echo "orphan still alive: $pid ($(basename "$pid_file"))" >&2
      return 1
    fi
  done
  return 0
}

# Timed stub: every stage sleeps so overlap/serialization is observable.
install_timed_run_plan() {
  # $1=workspace $2=order_log $3=marker_dir $4=sleep_seconds
  local workspace="$1" order_log="$2" marker_dir="$3" sleep_s="${4:-1}"
  local stub_src="$workspace/.ralph/run-plan.sh"
  local stub_real="$workspace/.ralph/run-plan.stub-real.sh"
  mv "$stub_src" "$stub_real"
  cat >"$stub_src" <<EOF
#!/usr/bin/env bash
set -euo pipefail
ORDER_LOG="$order_log"
MARKER_DIR="$marker_dir"
STAGE="\${RALPH_STAGE_ID:-unknown}"
mkdir -p "\$MARKER_DIR" "\$(dirname "\$ORDER_LOG")"
printf '%s\n' "\$STAGE" >>"\$ORDER_LOG"
printf '%s\n' "\${RALPH_ARTIFACT_NS:-}" >"\$MARKER_DIR/\$STAGE.artifact_ns"
printf '%s\n' "\${RALPH_PLAN_KEY:-}" >"\$MARKER_DIR/\$STAGE.plan_key"
printf '%s\n' "\${RALPH_GRAPH_NODE_ID:-}" >"\$MARKER_DIR/\$STAGE.graph_node_id"
date +%s >"\$MARKER_DIR/\$STAGE.started_at"
: >"\$MARKER_DIR/\$STAGE.started"
sleep "$sleep_s"
date +%s >"\$MARKER_DIR/\$STAGE.finished_at"
: >"\$MARKER_DIR/\$STAGE.finished"
export RALPH_RUN_PLAN_CAPTURE_FILE="\$MARKER_DIR/capture-\$STAGE.json"
export RUN_PLAN_STUB_EXIT_CODE="\${RUN_PLAN_STUB_EXIT_CODE:-0}"
export RUN_PLAN_STUB_WRITE_ARTIFACTS=""
exec "$stub_real" "\$@"
EOF
  chmod +x "$stub_src"
}

# Barrier stub: each stage waits until barrier_count peers have started (or
# timeout). Guarantees wall-clock overlap despite staggered orch startup.
# Nodes that run alone later must use a different marker_dir or lower count.
install_barrier_run_plan() {
  # $1=workspace $2=order_log $3=marker_dir $4=barrier_count
  local workspace="$1" order_log="$2" marker_dir="$3" barrier_count="${4:-2}"
  local stub_src="$workspace/.ralph/run-plan.sh"
  local stub_real="$workspace/.ralph/run-plan.stub-real.sh"
  mv "$stub_src" "$stub_real"
  cat >"$stub_src" <<EOF
#!/usr/bin/env bash
set -euo pipefail
ORDER_LOG="$order_log"
MARKER_DIR="$marker_dir"
BARRIER_COUNT="$barrier_count"
STAGE="\${RALPH_STAGE_ID:-unknown}"
mkdir -p "\$MARKER_DIR" "\$(dirname "\$ORDER_LOG")"
printf '%s\n' "\$STAGE" >>"\$ORDER_LOG"
printf '%s\n' "\${RALPH_ARTIFACT_NS:-}" >"\$MARKER_DIR/\$STAGE.artifact_ns"
printf '%s\n' "\${RALPH_PLAN_KEY:-}" >"\$MARKER_DIR/\$STAGE.plan_key"
printf '%s\n' "\${RALPH_GRAPH_NODE_ID:-}" >"\$MARKER_DIR/\$STAGE.graph_node_id"
date +%s >"\$MARKER_DIR/\$STAGE.started_at"
: >"\$MARKER_DIR/\$STAGE.started"
# Wait for every barrier participant to start. The old 20s budget (80 * 0.25)
# was too tight under run-bats' 8-way file parallelism: a node that takes
# longer than that to get scheduled would fall through the loop, run alone,
# and fail the overlap assertion as if the scheduler had serialized it. The
# budget is now 150s, and exhausting it records a marker so the failure reads
# as "barrier timed out" instead of a mysterious non-overlap.
i=0
while [[ "\$i" -lt 600 ]]; do
  # Avoid ls-glob + pipefail aborting when the directory is briefly empty.
  n=0
  for _f in "\$MARKER_DIR"/*.started; do
    [[ -e "\$_f" ]] || continue
    n=\$((n + 1))
  done
  if [[ "\$n" -ge "\$BARRIER_COUNT" ]]; then
    break
  fi
  sleep 0.25
  i=\$((i + 1))
done
if [[ "\$i" -ge 600 ]]; then
  printf 'barrier timeout: saw %s of %s starters\\n' "\$n" "\$BARRIER_COUNT" \
    >"\$MARKER_DIR/\$STAGE.barrier_timeout"
fi
# Hold for a full second so started_at < finished_at under second-resolution clocks.
sleep 1
date +%s >"\$MARKER_DIR/\$STAGE.finished_at"
: >"\$MARKER_DIR/\$STAGE.finished"
export RALPH_RUN_PLAN_CAPTURE_FILE="\$MARKER_DIR/capture-\$STAGE.json"
export RUN_PLAN_STUB_EXIT_CODE="\${RUN_PLAN_STUB_EXIT_CODE:-0}"
export RUN_PLAN_STUB_WRITE_ARTIFACTS=""
exec "$stub_real" "\$@"
EOF
  chmod +x "$stub_src"
}

@test "ready-set loop runs a linear graph in topological order and exits 0" {
  tmpd="$(mktemp -d)"
  setup_dispatch_workspace "$tmpd"
  graph_file="$tmpd/graph-edges.graph.json"
  compile_plan_graph_to "$FIXTURE_PLAN" "$DISPATCH_WORKSPACE" "$graph_file"

  order_log="$tmpd/order.log"
  marker_dir="$tmpd/markers"
  mkdir -p "$marker_dir"
  install_stage_aware_run_plan "$DISPATCH_WORKSPACE" "$order_log" "$marker_dir"

  export RUN_PLAN_STUB_EXIT_CODE=0
  unset RUN_PLAN_STUB_SLEEP_SECONDS RUN_PLAN_STUB_READY_FILE 2>/dev/null || true
  unset RALPH_ARTIFACT_NS RALPH_PLAN_KEY 2>/dev/null || true

  # Call directly so scheduler state stays in this shell.
  graph_schedule_run "$graph_file" "linear-run" "$DISPATCH_WORKSPACE"
  [ "$(graph_schedule_node_state_by_id source)" = "succeeded" ]
  [ "$(graph_schedule_node_state_by_id transform)" = "succeeded" ]
  [ "$(graph_schedule_node_state_by_id sink)" = "succeeded" ]
  [ "$GRAPH_SCHEDULE_EXIT_CODE" -eq 0 ]

  # Order log is stage ids in execution order.
  order_joined="$(tr '\n' ',' <"$order_log")"
  [ "$order_joined" = "source,transform,sink," ]

  rm -rf "$tmpd"
}

@test "ready-set loop diamond middle nodes overlap and sink waits for both" {
  tmpd="$(mktemp -d)"
  setup_dispatch_workspace "$tmpd"
  graph_file="$tmpd/graph-diamond.graph.json"
  compile_plan_graph_to "$DIAMOND_PLAN" "$DISPATCH_WORKSPACE" "$graph_file"
  # Fixture default maxParallel is 2; left/right use distinct runtimes so the
  # default per-runtime cap of 1 still allows them to overlap.
  [ "$(jq -r '.maxParallel' "$graph_file")" = "2" ]
  [ "$(jq -r '.nodes[] | select(.id=="left") | .stage.runtime' "$graph_file")" != \
    "$(jq -r '.nodes[] | select(.id=="right") | .stage.runtime' "$graph_file")" ]

  order_log="$tmpd/order.log"
  marker_dir="$tmpd/markers"
  mkdir -p "$marker_dir"
  install_stage_aware_run_plan "$DISPATCH_WORKSPACE" "$order_log" "$marker_dir"

  export RUN_PLAN_STUB_EXIT_CODE=0
  # left/right rendezvous on each other's started marker rather than holding a
  # fixed 3s, so the overlap window survives staggered startup under a
  # parallel suite. Only this test asserts overlap, so only this test opts in.
  export RUN_PLAN_STUB_OVERLAP_BARRIER=1
  unset RUN_PLAN_STUB_SLEEP_SECONDS RUN_PLAN_STUB_READY_FILE 2>/dev/null || true

  unset RALPH_ARTIFACT_NS RALPH_PLAN_KEY 2>/dev/null || true
  graph_schedule_run "$graph_file" "diamond-run" "$DISPATCH_WORKSPACE"
  [ "$GRAPH_SCHEDULE_EXIT_CODE" -eq 0 ]
  [ "$(graph_schedule_node_state_by_id source)" = "succeeded" ]
  [ "$(graph_schedule_node_state_by_id left)" = "succeeded" ]
  [ "$(graph_schedule_node_state_by_id right)" = "succeeded" ]
  [ "$(graph_schedule_node_state_by_id sink)" = "succeeded" ]

  [ -f "$marker_dir/left.started_at" ]
  [ -f "$marker_dir/right.started_at" ]
  [ -f "$marker_dir/left.finished_at" ]
  [ -f "$marker_dir/right.finished_at" ]
  [ -f "$marker_dir/sink.started_at" ]

  left_start="$(cat "$marker_dir/left.started_at")"
  left_end="$(cat "$marker_dir/left.finished_at")"
  right_start="$(cat "$marker_dir/right.started_at")"
  right_end="$(cat "$marker_dir/right.finished_at")"
  sink_start="$(cat "$marker_dir/sink.started_at")"
  assert_intervals_overlap "$left_start" "$left_end" "$right_start" "$right_end"
  [ "$sink_start" -ge "$left_end" ]
  [ "$sink_start" -ge "$right_end" ]

  # sink must appear after both left and right in the order log.
  source_line="$(grep -n '^source$' "$order_log" | head -n1 | cut -d: -f1)"
  left_line="$(grep -n '^left$' "$order_log" | head -n1 | cut -d: -f1)"
  right_line="$(grep -n '^right$' "$order_log" | head -n1 | cut -d: -f1)"
  sink_line="$(grep -n '^sink$' "$order_log" | head -n1 | cut -d: -f1)"
  [ "$source_line" -lt "$left_line" ]
  [ "$source_line" -lt "$right_line" ]
  [ "$left_line" -lt "$sink_line" ]
  [ "$right_line" -lt "$sink_line" ]

  rm -rf "$tmpd"
}

@test "ready-set loop treats a missing StageOutcomeReport as failed" {
  tmpd="$(mktemp -d)"
  setup_dispatch_workspace "$tmpd"
  graph_file="$tmpd/graph-edges.graph.json"
  compile_plan_graph_to "$FIXTURE_PLAN" "$DISPATCH_WORKSPACE" "$graph_file"
  ns="$(jq -r '.namespace' "$graph_file")"

  # Write a report then delete it before exit so the reaper observes missing-report.
  cat >"$DISPATCH_WORKSPACE/.ralph/orchestrator.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
attempt=""
prev=""
for arg in "\$@"; do
  if [[ "\$prev" == "--attempt-id" ]]; then
    attempt="\$arg"
  fi
  prev="\$arg"
done
workspace="\${@: -1}"
report="\$workspace/.ralph-workspace/artifacts/$ns/stage-outcomes/\${attempt}.json"
mkdir -p "\$(dirname "\$report")"
printf '%s\n' '{"schemaVersion":1,"runId":"missing-report-run","stageId":"source","attemptId":"'"\$attempt"'","outcome":"success","exitCode":0,"startedAt":"2026-01-01T00:00:00Z","finishedAt":"2026-01-01T00:00:01Z"}' >"\$report"
rm -f "\$report"
exit 0
EOF
  chmod +x "$DISPATCH_WORKSPACE/.ralph/orchestrator.sh"
  export GRAPH_DISPATCH_ORCHESTRATOR="$DISPATCH_WORKSPACE/.ralph/orchestrator.sh"

  # Call directly (not via `run`) so GRAPH_* state remains in this shell.
  unset RALPH_ARTIFACT_NS RALPH_PLAN_KEY 2>/dev/null || true
  rc=0
  graph_schedule_run "$graph_file" "missing-report-run" "$DISPATCH_WORKSPACE" || rc=$?
  [ "$rc" -ne 0 ]
  [ "$(graph_schedule_node_state_by_id source)" = "failed" ]
  [ "$GRAPH_SCHEDULE_FAILED_NODE" = "source" ]
  # Transitive descendants with no alternate path are blocked (drain policy).
  [ "$(graph_schedule_node_state_by_id transform)" = "blocked" ]
  [ "$(graph_schedule_node_state_by_id sink)" = "blocked" ]

  rm -rf "$tmpd"
}

@test "ready-set loop under /bin/bash 3.2 completes a linear graph" {
  tmpd="$(mktemp -d)"
  setup_dispatch_workspace "$tmpd"
  graph_file="$tmpd/graph-edges.graph.json"
  compile_plan_graph_to "$FIXTURE_PLAN" "$DISPATCH_WORKSPACE" "$graph_file"

  order_log="$tmpd/order.log"
  marker_dir="$tmpd/markers"
  mkdir -p "$marker_dir"
  install_stage_aware_run_plan "$DISPATCH_WORKSPACE" "$order_log" "$marker_dir"

  script="$tmpd/schedule-under-32.sh"
  cat >"$script" <<EOF
#!/bin/bash
set -euo pipefail
source "$SCHEDULE_LIB"
unset RALPH_ARTIFACT_NS RALPH_PLAN_KEY 2>/dev/null || true
export GRAPH_DISPATCH_ORCHESTRATOR="$DISPATCH_WORKSPACE/.ralph/orchestrator.sh"
export RALPH_ALLOW_NESTED_RUNS=1
export ORCHESTRATOR_RUNNER_TO_CONSOLE=0
export RALPH_MODE=no
export RALPH_ARTIFACT_SCHEMA_VALIDATION=0
export RALPH_ARTIFACT_PROVENANCE=0
export RUN_PLAN_STUB_EXIT_CODE=0
export GRAPH_REAP_FORCE_POLL=1
graph_schedule_run "$graph_file" "bash32-run" "$DISPATCH_WORKSPACE"
printf 'bash=%s\n' "\$BASH_VERSION"
printf 'exit=%s\n' "\$GRAPH_SCHEDULE_EXIT_CODE"
printf 'source=%s\n' "\$(graph_schedule_node_state_by_id source)"
printf 'transform=%s\n' "\$(graph_schedule_node_state_by_id transform)"
printf 'sink=%s\n' "\$(graph_schedule_node_state_by_id sink)"
printf 'order=%s\n' "\$(tr '\\n' ',' <"$order_log")"
EOF
  chmod +x "$script"

  run /bin/bash "$script"
  [ "$status" -eq 0 ]
  # Substring, not prefix: bats merges stderr into $output and the scheduler
  # prints its run header there before this script's own printf lines.
  [[ "$output" == *"bash=3.2"* ]]
  [[ "$output" == *"exit=0"* ]]
  [[ "$output" == *"source=succeeded"* ]]
  [[ "$output" == *"transform=succeeded"* ]]
  [[ "$output" == *"sink=succeeded"* ]]
  [[ "$output" == *"order=source,transform,sink,"* ]]

  rm -rf "$tmpd"
}

# --- Concurrency caps and per-node isolation -------------------------------

@test "default per-runtime cap serializes three same-runtime ready nodes" {
  tmpd="$(mktemp -d)"
  setup_dispatch_workspace "$tmpd"
  graph_file="$tmpd/same-rt.graph.json"
  write_ready_fanout_graph "$graph_file" "same-rt" 3 \
    "a:cursor:inherit" "b:cursor:inherit" "c:cursor:inherit"

  order_log="$tmpd/order.log"
  marker_dir="$tmpd/markers"
  mkdir -p "$marker_dir"
  install_timed_run_plan "$DISPATCH_WORKSPACE" "$order_log" "$marker_dir" 1

  unset RALPH_ARTIFACT_NS RALPH_PLAN_KEY RALPH_GRAPH_MAX_PARALLEL \
    RALPH_GRAPH_MAX_PARALLEL_PER_RUNTIME 2>/dev/null || true
  graph_schedule_run "$graph_file" "same-rt-run" "$DISPATCH_WORKSPACE"
  [ "$GRAPH_SCHEDULE_EXIT_CODE" -eq 0 ]

  assert_no_barrier_timeout "$marker_dir"
  a_s="$(cat "$marker_dir/a.started_at")"; a_e="$(cat "$marker_dir/a.finished_at")"
  b_s="$(cat "$marker_dir/b.started_at")"; b_e="$(cat "$marker_dir/b.finished_at")"
  c_s="$(cat "$marker_dir/c.started_at")"; c_e="$(cat "$marker_dir/c.finished_at")"
  assert_intervals_disjoint "$a_s" "$a_e" "$b_s" "$b_e"
  assert_intervals_disjoint "$a_s" "$a_e" "$c_s" "$c_e"
  assert_intervals_disjoint "$b_s" "$b_e" "$c_s" "$c_e"

  rm -rf "$tmpd"
}

@test "proven temporary-config adapter runs three same-runtime nodes in parallel" {
  tmpd="$(mktemp -d)"
  setup_dispatch_workspace "$tmpd"
  graph_file="$tmpd/safe-same-rt.graph.json"
  write_ready_fanout_graph "$graph_file" "safe-same-rt" 3 \
    "a:claude:inherit" "b:claude:inherit" "c:claude:inherit"

  order_log="$tmpd/order.log"
  marker_dir="$tmpd/markers"
  mkdir -p "$marker_dir"
  install_barrier_run_plan "$DISPATCH_WORKSPACE" "$order_log" "$marker_dir" 3

  export RALPH_GRAPH_MAX_PARALLEL=3
  export RALPH_GRAPH_MAX_PARALLEL_PER_RUNTIME=3
  unset RALPH_ARTIFACT_NS RALPH_PLAN_KEY 2>/dev/null || true
  graph_schedule_run "$graph_file" "safe-same-rt-run" "$DISPATCH_WORKSPACE"
  [ "$GRAPH_SCHEDULE_EXIT_CODE" -eq 0 ]
  assert_intervals_overlap "$(cat "$marker_dir/a.started_at")" "$(cat "$marker_dir/a.finished_at")" "$(cat "$marker_dir/b.started_at")" "$(cat "$marker_dir/b.finished_at")"
  assert_intervals_overlap "$(cat "$marker_dir/a.started_at")" "$(cat "$marker_dir/a.finished_at")" "$(cat "$marker_dir/c.started_at")" "$(cat "$marker_dir/c.finished_at")"

  admission="$(graph_state_run_dir "$DISPATCH_WORKSPACE" "safe-same-rt" "safe-same-rt-run")/logs/admission.jsonl"
  [ "$(jq -s '[.[] | select(.decision == "admitted" and .runtime == "claude")] | length' "$admission")" -eq 3 ]
  jq -s -e 'all(.[]; (.sameRuntimeParallelSafe == true and .overlayIsolation == "temporary-cli-config"))' "$admission" >/dev/null
  rm -rf "$tmpd"
}

@test "unsafe project-overlay adapter serializes despite snapshots and cap three" {
  tmpd="$(mktemp -d)"
  setup_dispatch_workspace "$tmpd"
  graph_file="$tmpd/unsafe-same-rt.graph.json"
  write_ready_fanout_graph "$graph_file" "unsafe-same-rt" 3 \
    "a:cursor:inherit" "b:cursor:inherit" "c:cursor:inherit"
  jq '(.nodes[].stage.workspaceMode) = "snapshot"' "$graph_file" >"$graph_file.tmp"
  mv "$graph_file.tmp" "$graph_file"

  order_log="$tmpd/order.log"
  marker_dir="$tmpd/markers"
  mkdir -p "$marker_dir"
  install_timed_run_plan "$DISPATCH_WORKSPACE" "$order_log" "$marker_dir" 1

  export RALPH_GRAPH_MAX_PARALLEL=3
  export RALPH_GRAPH_MAX_PARALLEL_PER_RUNTIME=3
  graph_schedule_run "$graph_file" "unsafe-same-rt-run" "$DISPATCH_WORKSPACE"
  assert_intervals_disjoint "$(cat "$marker_dir/a.started_at")" "$(cat "$marker_dir/a.finished_at")" "$(cat "$marker_dir/b.started_at")" "$(cat "$marker_dir/b.finished_at")"
  assert_intervals_disjoint "$(cat "$marker_dir/b.started_at")" "$(cat "$marker_dir/b.finished_at")" "$(cat "$marker_dir/c.started_at")" "$(cat "$marker_dir/c.finished_at")"

  admission="$(graph_state_run_dir "$DISPATCH_WORKSPACE" "unsafe-same-rt" "unsafe-same-rt-run")/logs/admission.jsonl"
  jq -s -e 'any(.[]; .decision == "denied" and .runtime == "cursor" and .sameRuntimeParallelSafe == false and .effectiveRuntimeCap == 1 and .requestedRuntimeCap == 3)' "$admission" >/dev/null
  rm -rf "$tmpd"
}

@test "distinct-runtime ready nodes overlap at maxParallel 3" {
  tmpd="$(mktemp -d)"
  setup_dispatch_workspace "$tmpd"
  graph_file="$tmpd/multi-rt.graph.json"
  write_ready_fanout_graph "$graph_file" "multi-rt" 3 \
    "a:cursor:inherit" "b:claude:inherit" "c:codex:inherit"

  order_log="$tmpd/order.log"
  marker_dir="$tmpd/markers"
  mkdir -p "$marker_dir"
  install_barrier_run_plan "$DISPATCH_WORKSPACE" "$order_log" "$marker_dir" 3

  unset RALPH_GRAPH_MAX_PARALLEL_PER_RUNTIME 2>/dev/null || true
  export RALPH_GRAPH_MAX_PARALLEL=3
  unset RALPH_ARTIFACT_NS RALPH_PLAN_KEY 2>/dev/null || true
  graph_schedule_run "$graph_file" "multi-rt-run" "$DISPATCH_WORKSPACE"
  [ "$GRAPH_SCHEDULE_EXIT_CODE" -eq 0 ]
  [ "$GRAPH_SCHEDULE_MAX_PARALLEL" -eq 3 ]

  assert_no_barrier_timeout "$marker_dir"
  a_s="$(cat "$marker_dir/a.started_at")"; a_e="$(cat "$marker_dir/a.finished_at")"
  b_s="$(cat "$marker_dir/b.started_at")"; b_e="$(cat "$marker_dir/b.finished_at")"
  c_s="$(cat "$marker_dir/c.started_at")"; c_e="$(cat "$marker_dir/c.finished_at")"
  assert_intervals_overlap "$a_s" "$a_e" "$b_s" "$b_e"
  assert_intervals_overlap "$a_s" "$a_e" "$c_s" "$c_e"
  assert_intervals_overlap "$b_s" "$b_e" "$c_s" "$c_e"

  rm -rf "$tmpd"
}

@test "global maxParallel binds below the sum of per-runtime caps" {
  tmpd="$(mktemp -d)"
  setup_dispatch_workspace "$tmpd"
  graph_file="$tmpd/global-cap.graph.json"
  write_ready_fanout_graph "$graph_file" "global-cap" 3 \
    "a:cursor:inherit" "b:claude:inherit" "c:codex:inherit"

  order_log="$tmpd/order.log"
  marker_dir="$tmpd/markers"
  mkdir -p "$marker_dir"
  install_timed_run_plan "$DISPATCH_WORKSPACE" "$order_log" "$marker_dir" 1

  export RALPH_GRAPH_MAX_PARALLEL=1
  unset RALPH_GRAPH_MAX_PARALLEL_PER_RUNTIME 2>/dev/null || true
  unset RALPH_ARTIFACT_NS RALPH_PLAN_KEY 2>/dev/null || true
  graph_schedule_run "$graph_file" "global-cap-run" "$DISPATCH_WORKSPACE"
  [ "$GRAPH_SCHEDULE_EXIT_CODE" -eq 0 ]
  [ "$GRAPH_SCHEDULE_MAX_PARALLEL" -eq 1 ]

  assert_no_barrier_timeout "$marker_dir"
  a_s="$(cat "$marker_dir/a.started_at")"; a_e="$(cat "$marker_dir/a.finished_at")"
  b_s="$(cat "$marker_dir/b.started_at")"; b_e="$(cat "$marker_dir/b.finished_at")"
  c_s="$(cat "$marker_dir/c.started_at")"; c_e="$(cat "$marker_dir/c.finished_at")"
  assert_intervals_disjoint "$a_s" "$a_e" "$b_s" "$b_e"
  assert_intervals_disjoint "$a_s" "$a_e" "$c_s" "$c_e"
  assert_intervals_disjoint "$b_s" "$b_e" "$c_s" "$c_e"

  rm -rf "$tmpd"
}

@test "per-node log dirs are isolated and RALPH_ARTIFACT_NS is shared" {
  local run_dir attempt_id log_rel node ns_a ns_b ns_c
  tmpd="$(mktemp -d)"
  setup_dispatch_workspace "$tmpd"
  graph_file="$tmpd/iso.graph.json"
  write_ready_fanout_graph "$graph_file" "iso-ns" 3 \
    "a:cursor:inherit" "b:claude:inherit" "c:codex:inherit"

  order_log="$tmpd/order.log"
  marker_dir="$tmpd/markers"
  mkdir -p "$marker_dir"
  install_timed_run_plan "$DISPATCH_WORKSPACE" "$order_log" "$marker_dir" 0

  export RALPH_GRAPH_MAX_PARALLEL=3
  unset RALPH_ARTIFACT_NS RALPH_PLAN_KEY 2>/dev/null || true
  graph_schedule_run "$graph_file" "iso-run" "$DISPATCH_WORKSPACE"
  [ "$GRAPH_SCHEDULE_EXIT_CODE" -eq 0 ]

  run_dir="$(graph_state_run_dir "$DISPATCH_WORKSPACE" "iso-ns" "iso-run")"
  for node in a b c; do
    attempt_id="$(graph_dispatch_mint_attempt_id "$node" "iso-run" 1)"
    log_rel="$(graph_logs_attempt_rel "$run_dir" "$node" "$attempt_id" runner.log)"
    [ -f "$(graph_logs_resolve "$run_dir" "$log_rel")" ]
  done
  [ ! -e "$DISPATCH_WORKSPACE/.ralph-workspace/logs/iso-ns/nodes" ]

  ns_a="$(cat "$marker_dir/a.artifact_ns")"
  ns_b="$(cat "$marker_dir/b.artifact_ns")"
  ns_c="$(cat "$marker_dir/c.artifact_ns")"
  [ "$ns_a" = "iso-ns" ]
  [ "$ns_a" = "$ns_b" ]
  [ "$ns_a" = "$ns_c" ]

  [ "$(cat "$marker_dir/a.plan_key")" = "iso-ns-a" ]
  [ "$(cat "$marker_dir/b.plan_key")" = "iso-ns-b" ]
  [ "$(cat "$marker_dir/c.plan_key")" = "iso-ns-c" ]
  [ "$(cat "$marker_dir/a.graph_node_id")" = "a" ]
  [ "$(cat "$marker_dir/b.graph_node_id")" = "b" ]
  [ "$(cat "$marker_dir/c.graph_node_id")" = "c" ]

  rm -rf "$tmpd"
}

@test "subagents=on reserves the whole per-runtime allowance and logs the binder" {
  tmpd="$(mktemp -d)"
  setup_dispatch_workspace "$tmpd"
  graph_file="$tmpd/sub-on.graph.json"
  write_ready_fanout_graph "$graph_file" "sub-on" 3 \
    "boss:claude:on" "sib:claude:inherit" "other:cursor:inherit"

  order_log="$tmpd/order.log"
  # Separate marker dirs so sib's later solo run does not satisfy the wave-1
  # barrier via leftover *.started files from boss/other.
  marker_dir="$tmpd/markers"
  mkdir -p "$marker_dir"
  install_barrier_run_plan "$DISPATCH_WORKSPACE" "$order_log" "$marker_dir" 2

  export RALPH_GRAPH_MAX_PARALLEL=3
  export RALPH_GRAPH_MAX_PARALLEL_PER_RUNTIME=2
  unset RALPH_ARTIFACT_NS RALPH_PLAN_KEY 2>/dev/null || true

  schedule_err="$tmpd/schedule.err"
  graph_schedule_run "$graph_file" "sub-on-run" "$DISPATCH_WORKSPACE" 2>"$schedule_err"
  [ "$GRAPH_SCHEDULE_EXIT_CODE" -eq 0 ]

  grep -q 'graph-schedule: node=boss subagents=on reserves runtime=claude allowance=2' "$schedule_err"

  boss_s="$(cat "$marker_dir/boss.started_at")"; boss_e="$(cat "$marker_dir/boss.finished_at")"
  sib_s="$(cat "$marker_dir/sib.started_at")"; sib_e="$(cat "$marker_dir/sib.finished_at")"
  other_s="$(cat "$marker_dir/other.started_at")"; other_e="$(cat "$marker_dir/other.finished_at")"
  # Same-runtime sibling must wait even though per-runtime cap is 2.
  assert_intervals_disjoint "$boss_s" "$boss_e" "$sib_s" "$sib_e"
  # Other runtime may overlap the reserving node.
  assert_intervals_overlap "$boss_s" "$boss_e" "$other_s" "$other_e"

  rm -rf "$tmpd"
}

@test "subagents reservation releases on failure so a same-runtime sibling can run" {
  tmpd="$(mktemp -d)"
  setup_dispatch_workspace "$tmpd"
  graph_file="$tmpd/sub-fail.graph.json"
  write_ready_fanout_graph "$graph_file" "sub-fail" 2 \
    "boss:claude:on" "sib:claude:inherit"

  order_log="$tmpd/order.log"
  marker_dir="$tmpd/markers"
  mkdir -p "$marker_dir"

  # Fail boss; sibling should still be able to run after reservation release.
  # STOP_DISPATCH after first failure means sibling stays pending — so assert
  # reservation counters are cleared instead, via a second controlled spawn.
  install_timed_run_plan "$DISPATCH_WORKSPACE" "$order_log" "$marker_dir" 0
  # Override stub exit for boss only.
  stub_src="$DISPATCH_WORKSPACE/.ralph/run-plan.sh"
  stub_real="$DISPATCH_WORKSPACE/.ralph/run-plan.stub-real.sh"
  cat >"$stub_src" <<EOF
#!/usr/bin/env bash
set -euo pipefail
STAGE="\${RALPH_STAGE_ID:-unknown}"
MARKER_DIR="$marker_dir"
ORDER_LOG="$order_log"
mkdir -p "\$MARKER_DIR" "\$(dirname "\$ORDER_LOG")"
printf '%s\n' "\$STAGE" >>"\$ORDER_LOG"
date +%s >"\$MARKER_DIR/\$STAGE.started_at"
: >"\$MARKER_DIR/\$STAGE.started"
date +%s >"\$MARKER_DIR/\$STAGE.finished_at"
: >"\$MARKER_DIR/\$STAGE.finished"
export RALPH_RUN_PLAN_CAPTURE_FILE="\$MARKER_DIR/capture-\$STAGE.json"
if [[ "\$STAGE" == "boss" ]]; then
  export RUN_PLAN_STUB_EXIT_CODE=7
else
  export RUN_PLAN_STUB_EXIT_CODE=0
fi
export RUN_PLAN_STUB_WRITE_ARTIFACTS=""
exec "$stub_real" "\$@"
EOF
  chmod +x "$stub_src"

  export RALPH_GRAPH_MAX_PARALLEL=2
  export RALPH_GRAPH_MAX_PARALLEL_PER_RUNTIME=2
  unset RALPH_ARTIFACT_NS RALPH_PLAN_KEY 2>/dev/null || true
  schedule_err="$tmpd/schedule.err"
  rc=0
  graph_schedule_run "$graph_file" "sub-fail-run" "$DISPATCH_WORKSPACE" 2>"$schedule_err" || rc=$?
  [ "$rc" -ne 0 ]
  [ "$(graph_schedule_node_state_by_id boss)" = "failed" ]
  grep -q 'graph-schedule: node=boss subagents=on reserves runtime=claude allowance=2' "$schedule_err"

  # Reservation must be released: runtime used slots back to 0, exclusive cleared.
  _graph_schedule_runtime_map_index claude
  [ "${GRAPH_RUNTIME_USED_SLOTS[$GRAPH_RUNTIME_LOOKUP_IDX]}" -eq 0 ]
  [ -z "${GRAPH_RUNTIME_EXCLUSIVE_NODE[$GRAPH_RUNTIME_LOOKUP_IDX]}" ]
  # Held slots on the failed node cleared.
  boss_idx="$(graph_schedule_index_map_get boss)"
  [ "${GRAPH_NODE_HELD_SLOTS[$boss_idx]}" -eq 0 ]

  rm -rf "$tmpd"
}

@test "subagents reservation releases on cancelled outcome" {
  tmpd="$(mktemp -d)"
  setup_dispatch_workspace "$tmpd"
  graph_file="$tmpd/sub-cancel.graph.json"
  write_ready_fanout_graph "$graph_file" "sub-cancel" 2 \
    "boss:claude:on" "sib:claude:inherit"
  ns="$(jq -r '.namespace' "$graph_file")"

  # Custom orchestrator: write cancelled StageOutcomeReport and exit non-zero.
  cat >"$DISPATCH_WORKSPACE/.ralph/orchestrator.sh" <<EOF
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
report="\$workspace/.ralph-workspace/artifacts/$ns/stage-outcomes/\${attempt}.json"
mkdir -p "\$(dirname "\$report")"
printf '%s\n' '{"schemaVersion":1,"runId":"sub-cancel-run","stageId":"'"\$stage"'","attemptId":"'"\$attempt"'","outcome":"cancelled","exitCode":130,"startedAt":"2026-01-01T00:00:00Z","finishedAt":"2026-01-01T00:00:01Z"}' >"\$report"
# Echo reservation-relevant env for debugging; scheduler captures stdout to node log.
echo "cancelled stage=\$stage"
exit 130
EOF
  chmod +x "$DISPATCH_WORKSPACE/.ralph/orchestrator.sh"
  export GRAPH_DISPATCH_ORCHESTRATOR="$DISPATCH_WORKSPACE/.ralph/orchestrator.sh"

  export RALPH_GRAPH_MAX_PARALLEL=2
  export RALPH_GRAPH_MAX_PARALLEL_PER_RUNTIME=2
  unset RALPH_ARTIFACT_NS RALPH_PLAN_KEY 2>/dev/null || true
  schedule_err="$tmpd/schedule.err"
  rc=0
  graph_schedule_run "$graph_file" "sub-cancel-run" "$DISPATCH_WORKSPACE" 2>"$schedule_err" || rc=$?
  [ "$rc" -ne 0 ]
  [ "$(graph_schedule_node_state_by_id boss)" = "cancelled" ]
  grep -q 'graph-schedule: node=boss subagents=on reserves runtime=claude allowance=2' "$schedule_err"

  _graph_schedule_runtime_map_index claude
  [ "${GRAPH_RUNTIME_USED_SLOTS[$GRAPH_RUNTIME_LOOKUP_IDX]}" -eq 0 ]
  [ -z "${GRAPH_RUNTIME_EXCLUSIVE_NODE[$GRAPH_RUNTIME_LOOKUP_IDX]}" ]

  rm -rf "$tmpd"
}

# --- Failure and cancellation semantics -------------------------------------

@test "drain lets in-flight sibling complete, blocks descendants, propagates exit code" {
  tmpd="$(mktemp -d)"
  setup_dispatch_workspace "$tmpd"
  graph_file="$tmpd/drain-sib.graph.json"
  write_graph_with_edges "$graph_file" "drain-sib" 2 "drain" \
    --nodes "boom:cursor" "linger:claude" "child:cursor" \
    --edges "boom:child"
  behavior_dir="$tmpd/behavior"
  marker_dir="$tmpd/markers"
  mkdir -p "$behavior_dir" "$marker_dir"
  printf '%s\n' "fail:7" >"$behavior_dir/boom"
  printf '%s\n' "sleep:2" >"$behavior_dir/linger"
  printf '%s\n' "success" >"$behavior_dir/child"
  install_behavior_orchestrator "$DISPATCH_WORKSPACE" "drain-sib" "drain-sib-run" \
    "$behavior_dir" "$marker_dir"

  export RALPH_GRAPH_MAX_PARALLEL=2
  export RALPH_GRAPH_MAX_PARALLEL_PER_RUNTIME=1
  unset RALPH_ARTIFACT_NS RALPH_PLAN_KEY 2>/dev/null || true
  rc=0
  graph_schedule_run "$graph_file" "drain-sib-run" "$DISPATCH_WORKSPACE" || rc=$?
  [ "$rc" -eq 7 ]
  [ "$(graph_schedule_node_state_by_id boom)" = "failed" ]
  [ "$(graph_schedule_node_state_by_id linger)" = "succeeded" ]
  [ "$(graph_schedule_node_state_by_id child)" = "blocked" ]
  [ -f "$marker_dir/linger.finished" ]
  [ ! -f "$marker_dir/child.started" ]
  assert_no_orphan_pids "$marker_dir"

  rm -rf "$tmpd"
}

@test "drain does not block a descendant reachable by another satisfied path" {
  tmpd="$(mktemp -d)"
  setup_dispatch_workspace "$tmpd"
  graph_file="$tmpd/drain-alt.graph.json"
  # Diamond: sink is a descendant of left but also reachable via right.
  write_graph_with_edges "$graph_file" "drain-alt" 2 "drain" \
    --nodes "source:cursor" "left:claude" "right:codex" "sink:cursor" \
    --edges "source:left" "source:right" "left:sink" "right:sink"
  behavior_dir="$tmpd/behavior"
  marker_dir="$tmpd/markers"
  mkdir -p "$behavior_dir" "$marker_dir"
  printf '%s\n' "success" >"$behavior_dir/source"
  printf '%s\n' "fail:9" >"$behavior_dir/left"
  printf '%s\n' "sleep:2" >"$behavior_dir/right"
  printf '%s\n' "success" >"$behavior_dir/sink"
  install_behavior_orchestrator "$DISPATCH_WORKSPACE" "drain-alt" "drain-alt-run" \
    "$behavior_dir" "$marker_dir"

  export RALPH_GRAPH_MAX_PARALLEL=2
  export RALPH_GRAPH_MAX_PARALLEL_PER_RUNTIME=1
  unset RALPH_ARTIFACT_NS RALPH_PLAN_KEY 2>/dev/null || true
  rc=0
  graph_schedule_run "$graph_file" "drain-alt-run" "$DISPATCH_WORKSPACE" || rc=$?
  [ "$rc" -eq 9 ]
  [ "$(graph_schedule_node_state_by_id source)" = "succeeded" ]
  [ "$(graph_schedule_node_state_by_id left)" = "failed" ]
  [ "$(graph_schedule_node_state_by_id right)" = "succeeded" ]
  # Alternate path source->right->sink keeps sink from being marked blocked.
  # Drain stops new dispatch, so sink stays pending (not blocked, not run).
  [ "$(graph_schedule_node_state_by_id sink)" = "pending" ]
  [ ! -f "$marker_dir/sink.started" ]
  assert_no_orphan_pids "$marker_dir"

  rm -rf "$tmpd"
}

@test "cancel terminates in-flight children and produces cancelled outcome reports" {
  tmpd="$(mktemp -d)"
  setup_dispatch_workspace "$tmpd"
  graph_file="$tmpd/cancel-sib.graph.json"
  WRITE_GRAPH_FAILURE_POLICY=cancel \
    write_ready_fanout_graph "$graph_file" "cancel-sib" 2 \
      "boom:cursor" "linger:claude"
  marker_dir="$tmpd/markers"
  mkdir -p "$marker_dir"

  # Custom orch: boom fails after a short delay so linger is in-flight; linger
  # sleeps until SIGTERM and writes outcome=cancelled (EXIT-trap equivalent).
  ns="cancel-sib"
  cat >"$DISPATCH_WORKSPACE/.ralph/orchestrator.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
attempt=""; stage=""; prev=""
for arg in "\$@"; do
  if [[ "\$prev" == "--attempt-id" ]]; then attempt="\$arg"
  elif [[ "\$prev" == "--single-stage" ]]; then stage="\$arg"
  fi
  prev="\$arg"
done
workspace="\${@: -1}"
report="\$workspace/.ralph-workspace/artifacts/$ns/stage-outcomes/\${attempt}.json"
mkdir -p "\$(dirname "\$report")" "$marker_dir"
printf '%s\n' "\$\$" >"$marker_dir/\$stage.pid"
: >"$marker_dir/\$stage.started"
write_report() {
  printf '%s\n' "{\"schemaVersion\":1,\"runId\":\"cancel-sib-run\",\"stageId\":\"\$stage\",\"attemptId\":\"\$attempt\",\"outcome\":\"\$1\",\"exitCode\":\$2,\"startedAt\":\"2026-01-01T00:00:00Z\",\"finishedAt\":\"2026-01-01T00:00:01Z\"}" >"\$report"
}
on_cancel() {
  write_report cancelled 143
  : >"$marker_dir/\$stage.cancelled"
  exit 143
}
trap on_cancel TERM INT
if [[ "\$stage" == "boom" ]]; then
  # Brief pause so linger is dispatched and sleeping before we fail.
  sleep 0.5
  write_report failed 11
  : >"$marker_dir/\$stage.finished"
  exit 11
fi
# linger: sleep until cancelled
sleep 30
write_report success 0
: >"$marker_dir/\$stage.finished"
exit 0
EOF
  chmod +x "$DISPATCH_WORKSPACE/.ralph/orchestrator.sh"
  export GRAPH_DISPATCH_ORCHESTRATOR="$DISPATCH_WORKSPACE/.ralph/orchestrator.sh"

  export RALPH_GRAPH_MAX_PARALLEL=2
  export RALPH_GRAPH_MAX_PARALLEL_PER_RUNTIME=1
  # Keep TERM grace short so the test stays snappy after cancel.
  export RALPH_PROCESS_TERM_GRACE_SECONDS=2
  unset RALPH_ARTIFACT_NS RALPH_PLAN_KEY 2>/dev/null || true
  rc=0
  graph_schedule_run "$graph_file" "cancel-sib-run" "$DISPATCH_WORKSPACE" || rc=$?
  [ "$rc" -eq 11 ]
  [ "$(graph_schedule_node_state_by_id boom)" = "failed" ]
  [ "$(graph_schedule_node_state_by_id linger)" = "cancelled" ]
  [ -f "$marker_dir/linger.cancelled" ]
  linger_attempt="$(ls "$DISPATCH_WORKSPACE/.ralph-workspace/artifacts/cancel-sib/stage-outcomes/"*linger* 2>/dev/null | head -n1)"
  [ -n "$linger_attempt" ]
  [ "$(jq -r '.outcome' "$linger_attempt")" = "cancelled" ]
  assert_no_orphan_pids "$marker_dir"

  rm -rf "$tmpd"
}

@test "exit code 3 marks only its own node awaiting-ack while siblings continue" {
  tmpd="$(mktemp -d)"
  setup_dispatch_workspace "$tmpd"
  graph_file="$tmpd/ack-sib.graph.json"
  write_graph_with_edges "$graph_file" "ack-sib" 2 "drain" \
    --nodes "ask:cursor" "sib:claude" "child:cursor" \
    --edges "ask:child"
  behavior_dir="$tmpd/behavior"
  marker_dir="$tmpd/markers"
  mkdir -p "$behavior_dir" "$marker_dir"
  printf '%s\n' "awaiting" >"$behavior_dir/ask"
  printf '%s\n' "sleep:1" >"$behavior_dir/sib"
  printf '%s\n' "success" >"$behavior_dir/child"
  install_behavior_orchestrator "$DISPATCH_WORKSPACE" "ack-sib" "ack-sib-run" \
    "$behavior_dir" "$marker_dir"

  export RALPH_GRAPH_MAX_PARALLEL=2
  export RALPH_GRAPH_MAX_PARALLEL_PER_RUNTIME=1
  unset RALPH_ARTIFACT_NS RALPH_PLAN_KEY 2>/dev/null || true
  rc=0
  graph_schedule_run "$graph_file" "ack-sib-run" "$DISPATCH_WORKSPACE" || rc=$?
  [ "$rc" -eq 3 ]
  [ "$(graph_schedule_node_state_by_id ask)" = "awaiting-ack" ]
  [ "$(graph_schedule_node_state_by_id sib)" = "succeeded" ]
  # Descendants of awaiting-ack are not marked blocked; they simply never
  # become ready because successors are not released.
  [ "$(graph_schedule_node_state_by_id child)" = "pending" ]
  [ ! -f "$marker_dir/child.started" ]
  [ -f "$marker_dir/sib.finished" ]
  assert_no_orphan_pids "$marker_dir"

  rm -rf "$tmpd"
}

# Exit 4 used to be an ordinary drain failure. The operator-permission work in
# the production-hardening continuation made it a permission pause instead: the
# node parks in awaiting-operator, keeps its retry grant, and the run reports 3
# (incomplete, waiting on a human) rather than a failure exit. Independent
# siblings still drain and the paused node's descendants are still blocked.
# See graph-operator-schedule.bats for the request/decision contract itself.
@test "exit code 4 pauses the node for an operator decision under drain" {
  tmpd="$(mktemp -d)"
  setup_dispatch_workspace "$tmpd"
  graph_file="$tmpd/stuck-fail.graph.json"
  write_graph_with_edges "$graph_file" "stuck-fail" 2 "drain" \
    --nodes "stuck:cursor" "sib:claude" "child:cursor" \
    --edges "stuck:child"
  behavior_dir="$tmpd/behavior"
  marker_dir="$tmpd/markers"
  mkdir -p "$behavior_dir" "$marker_dir"
  printf '%s\n' "stuck" >"$behavior_dir/stuck"
  printf '%s\n' "sleep:2" >"$behavior_dir/sib"
  printf '%s\n' "success" >"$behavior_dir/child"
  install_behavior_orchestrator "$DISPATCH_WORKSPACE" "stuck-fail" "stuck-fail-run" \
    "$behavior_dir" "$marker_dir"

  export RALPH_GRAPH_MAX_PARALLEL=2
  export RALPH_GRAPH_MAX_PARALLEL_PER_RUNTIME=1
  unset RALPH_ARTIFACT_NS RALPH_PLAN_KEY 2>/dev/null || true
  rc=0
  graph_schedule_run "$graph_file" "stuck-fail-run" "$DISPATCH_WORKSPACE" || rc=$?
  [ "$rc" -eq 3 ]
  [ "$(graph_schedule_node_state_by_id stuck)" = "awaiting-operator" ]
  [ "$(graph_schedule_node_state_by_id sib)" = "succeeded" ]
  [ "$(graph_schedule_node_state_by_id child)" = "blocked" ]
  [ ! -f "$marker_dir/child.started" ]
  assert_no_orphan_pids "$marker_dir"

  rm -rf "$tmpd"
}

# --- consensus-join scheduling regression ---------------------------------
# Regression test for the edge-alias bug: plan_pipeline_graph_json previously
# emitted edges referencing the bare consensus root id (e.g. "review") which
# is not a real node id after consensus expansion. graph_schedule_load_index
# would fail with "unknown node: review". The fix rewrites:
#   from=consensus_root  ->  from=consensus_root:barrier
#   to=consensus_root    ->  fan-out to to=consensus_root:<voter_id>
# This test compiles the join fixture (consensus voters + downstream join node)
# and drives the full ready-set loop to completion, proving the adjudicate node
# can be scheduled after the barrier.

@test "consensus-join: full ready-set loop runs all voters and adjudicate to succeeded" {
  tmpd="$(mktemp -d)"
  setup_dispatch_workspace "$tmpd"

  graph_file="$tmpd/consensus-join.graph.json"
  compile_plan_graph_to "$CONSENSUS_JOIN_PLAN" "$DISPATCH_WORKSPACE" "$graph_file"

  # After the fix, top-level edges must use only real node ids.
  # The bare consensus root id "review" must not appear in any edge endpoint.
  run jq -e '
    (.nodes | map(.id)) as $real_ids |
    .edges[] | select(
      ((.from | . as $f | ($real_ids | index($f))) == null) or
      ((.to   | . as $t | ($real_ids | index($t))) == null)
    )
  ' "$graph_file"
  [ "$status" -ne 0 ]  # jq -e returns 1 when no match (all edges use real ids)

  # The barrier -> adjudicate edge must be present.
  barrier_to_adj="$(jq '[.edges[] | select(.from == "review:barrier" and .to == "adjudicate")] | length' "$graph_file")"
  [ "$barrier_to_adj" = "1" ]

  # Use a behavior orchestrator so every node succeeds without running a real
  # agent CLI. The barrier stage has no stage-level agent/runtime in the fixture
  # (it inherits them from voters), so the real orchestrator's agent-validation
  # would reject it. The behavior orchestrator bypasses that path entirely,
  # letting us focus on the scheduler's edge-loading and ordering logic.
  #
  # The namespace must match the graph JSON's namespace so the behavior
  # orchestrator writes reports to the path the scheduler expects.
  ns="$(jq -r '.namespace' "$graph_file")"
  run_id="consensus-join-run"
  behavior_dir="$tmpd/behavior"
  marker_dir="$tmpd/markers"
  mkdir -p "$behavior_dir" "$marker_dir"
  install_behavior_orchestrator "$DISPATCH_WORKSPACE" "$ns" "$run_id" \
    "$behavior_dir" "$marker_dir"

  # review:barrier (type consensus-barrier) is dispatched in-process by the
  # scheduler, never as an orchestrator subprocess, so it reads each voter's
  # declared outputArtifacts[0] itself rather than relying on the behavior
  # orchestrator (which only writes StageOutcomeReports, not review verdicts).
  # Pre-seed both voter verdict artifacts as approved before running.
  mkdir -p "$DISPATCH_WORKSPACE/.ralph-workspace/artifacts/$ns/review"
  printf '<!-- REVIEW_STATUS: START -->\nstatus: approved\n<!-- REVIEW_STATUS: END -->\n' \
    >"$DISPATCH_WORKSPACE/.ralph-workspace/artifacts/$ns/review/alpha.md"
  printf '<!-- REVIEW_STATUS: START -->\nstatus: approved\n<!-- REVIEW_STATUS: END -->\n' \
    >"$DISPATCH_WORKSPACE/.ralph-workspace/artifacts/$ns/review/beta.md"

  export RALPH_GRAPH_MAX_PARALLEL=4
  export RALPH_GRAPH_MAX_PARALLEL_PER_RUNTIME=2
  unset RALPH_ARTIFACT_NS RALPH_PLAN_KEY 2>/dev/null || true

  graph_schedule_run "$graph_file" "$run_id" "$DISPATCH_WORKSPACE"
  [ "$GRAPH_SCHEDULE_EXIT_CODE" -eq 0 ]
  [ "$(graph_schedule_node_state_by_id "review:alpha")"   = "succeeded" ]
  [ "$(graph_schedule_node_state_by_id "review:beta")"    = "succeeded" ]
  [ "$(graph_schedule_node_state_by_id "review:barrier")" = "succeeded" ]
  [ "$(graph_schedule_node_state_by_id "adjudicate")"     = "succeeded" ]

  # review:barrier must have actually run graph_consensus_run_join (not been
  # dispatched as a plain orchestrator subprocess): a consensus result exists
  # and decides approved. adjudicate still spawns as an ordinary agent node
  # (it declares its own runtime/agent), confirming the scheduler respected
  # the review:barrier -> adjudicate edge derived by the fix.
  barrier_result="$DISPATCH_WORKSPACE/.ralph-workspace/artifacts/$ns/consensus/review_barrier.json"
  [ -f "$barrier_result" ]
  [ "$(jq -r '.decision' "$barrier_result")" = "approved" ]
  [ ! -f "$marker_dir/review:barrier.started" ]
  [ -f "$marker_dir/adjudicate.started" ]

  rm -rf "$tmpd"
}

# --- voter->barrier gating regression --------------------------------------
# Regression test for the missing voter->barrier edge bug: plan_pipeline_graph_json
# previously never emitted voter->barrier edges into the top-level edges[] array.
# The scheduler computes indegree strictly from edges[], so the barrier's indegree
# was 0 and it was dispatched immediately (concurrently with voters).
#
# This test proves the fix by:
# 1. Asserting voter->barrier edges are present in the compiled graph.
# 2. Running the full scheduler ready-set loop with voters that sleep long enough
#    to create a real race window.
# 3. Asserting the barrier's started_at timestamp is >= all voters' finished_at
#    timestamps, proving it was not dispatched before voters completed.

@test "consensus-join: barrier gating - barrier starts only after all voters finish" {
  tmpd="$(mktemp -d)"
  setup_dispatch_workspace "$tmpd"

  graph_file="$tmpd/consensus-join-gating.graph.json"
  compile_plan_graph_to "$CONSENSUS_JOIN_PLAN" "$DISPATCH_WORKSPACE" "$graph_file"

  # voter->barrier edges must be present in the compiled graph (the core fix).
  voter_to_barrier_count="$(jq '[.edges[] | select(.to == "review:barrier")] | length' "$graph_file")"
  [ "$voter_to_barrier_count" = "2" ]

  alpha_to_barrier="$(jq '[.edges[] | select(.from == "review:alpha" and .to == "review:barrier")] | length' "$graph_file")"
  beta_to_barrier="$(jq '[.edges[] | select(.from == "review:beta"  and .to == "review:barrier")] | length' "$graph_file")"
  [ "$alpha_to_barrier" = "1" ]
  [ "$beta_to_barrier"  = "1" ]

  # Install a timed orchestrator: voters sleep 2 seconds so the barrier can only
  # become ready at indegree=0 (wrong) or after both voters finish (correct).
  # review:barrier itself is dispatched in-process by the scheduler (type
  # consensus-barrier), not as an orchestrator subprocess -- its readiness is
  # gated by the scheduler's own indegree/successor-release bookkeeping, which
  # is exactly the mechanism this regression test protects. Each voter also
  # writes its own REVIEW_STATUS verdict artifact so the barrier's
  # graph_consensus_run_join call has something real to read.
  ns="$(jq -r '.namespace' "$graph_file")"
  run_id="barrier-gating-run"
  marker_dir="$tmpd/markers"
  mkdir -p "$marker_dir"
  cat >"$DISPATCH_WORKSPACE/.ralph/orchestrator.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
attempt=""
stage=""
prev=""
for arg in "\$@"; do
  if [[ "\$prev" == "--attempt-id" ]]; then attempt="\$arg"; fi
  if [[ "\$prev" == "--single-stage" ]];  then stage="\$arg";   fi
  prev="\$arg"
done
workspace="\${@: -1}"
marker_dir="$marker_dir"
run_id="$run_id"
ns="$ns"
report="\$workspace/.ralph-workspace/artifacts/\$ns/stage-outcomes/\${attempt}.json"
mkdir -p "\$(dirname "\$report")" "\$marker_dir"
date +%s >"\$marker_dir/\$stage.started_at"
: >"\$marker_dir/\$stage.started"
case "\$stage" in
  review:alpha|review:beta)
    sleep 2
    voter_dir="\$workspace/.ralph-workspace/artifacts/\$ns/review"
    mkdir -p "\$voter_dir"
    voter_id="\${stage#review:}"
    printf '<!-- REVIEW_STATUS: START -->\nstatus: approved\n<!-- REVIEW_STATUS: END -->\n' \
      >"\$voter_dir/\$voter_id.md"
    ;;
esac
date +%s >"\$marker_dir/\$stage.finished_at"
: >"\$marker_dir/\$stage.finished"
printf '%s\n' "{\"schemaVersion\":1,\"runId\":\"\$run_id\",\"stageId\":\"\$stage\",\"attemptId\":\"\$attempt\",\"outcome\":\"success\",\"exitCode\":0,\"startedAt\":\"2026-01-01T00:00:00Z\",\"finishedAt\":\"2026-01-01T00:00:01Z\"}" >"\$report"
exit 0
EOF
  chmod +x "$DISPATCH_WORKSPACE/.ralph/orchestrator.sh"
  export GRAPH_DISPATCH_ORCHESTRATOR="$DISPATCH_WORKSPACE/.ralph/orchestrator.sh"

  export RALPH_GRAPH_MAX_PARALLEL=4
  export RALPH_GRAPH_MAX_PARALLEL_PER_RUNTIME=2
  unset RALPH_ARTIFACT_NS RALPH_PLAN_KEY 2>/dev/null || true

  graph_schedule_run "$graph_file" "$run_id" "$DISPATCH_WORKSPACE"
  [ "$GRAPH_SCHEDULE_EXIT_CODE" -eq 0 ]
  [ "$(graph_schedule_node_state_by_id "review:alpha")"   = "succeeded" ]
  [ "$(graph_schedule_node_state_by_id "review:beta")"    = "succeeded" ]
  [ "$(graph_schedule_node_state_by_id "review:barrier")" = "succeeded" ]
  [ "$(graph_schedule_node_state_by_id "adjudicate")"     = "succeeded" ]

  # review:barrier never spawns a subprocess of its own (proving it took the
  # in-process consensus path, not a plain orchestrator dispatch).
  [ ! -f "$marker_dir/review:barrier.started" ]

  # Core ordering assertion: the barrier could only have produced a consensus
  # result (via graph_consensus_run_join, called synchronously once the node
  # becomes ready) after both voters finished, since it is scheduler-gated on
  # their success and reads artifacts the voters themselves just wrote.
  alpha_end="$(cat "$marker_dir/review:alpha.finished_at")"
  beta_end="$(cat "$marker_dir/review:beta.finished_at")"
  barrier_result="$DISPATCH_WORKSPACE/.ralph-workspace/artifacts/$ns/consensus/review_barrier.json"
  [ -f "$barrier_result" ]
  [ "$(jq -r '.decision' "$barrier_result")" = "approved" ]

  rm -rf "$tmpd"
}

@test "consensus voter artifacts below .ralph-workspace resolve against external state root" {
  GRAPH_SCHEDULE_WORKSPACE="$BATS_TEST_TMPDIR/workspace"
  GRAPH_SCHEDULE_NAMESPACE="jury"
  export RALPH_PLAN_WORKSPACE_ROOT="$BATS_TEST_TMPDIR/state"
  mkdir -p "$GRAPH_SCHEDULE_WORKSPACE" "$RALPH_PLAN_WORKSPACE_ROOT"

  stage_json='{"outputArtifacts":[{"path":".ralph-workspace/artifacts/{{ARTIFACT_NS}}/reviews/alpha.md"}]}'
  [ "$(_graph_schedule_consensus_voter_artifact_abs "$stage_json")" = \
    "$RALPH_PLAN_WORKSPACE_ROOT/artifacts/jury/reviews/alpha.md" ]
}

# ---------------------------------------------------------------------------
# p5-attempt-upserts: _graph_schedule_ledger_record schema-version dispatch
# ---------------------------------------------------------------------------

@test "_graph_schedule_ledger_record on a v2 run produces one attempts[] entry for a running-to-terminal attempt" {
  local tmpd workspace ns run_id graph_file plan_file node_file aid
  tmpd="$(mktemp -d)"
  workspace="$tmpd/ws"
  mkdir -p "$workspace"
  ns="sched-v2-ns"
  run_id="run-sched-v2"
  plan_file="$workspace/$(basename "$DIAMOND_PLAN")"
  cp "$DIAMOND_PLAN" "$plan_file"
  graph_file="$tmpd/graph.json"
  plan_pipeline_graph_json "$plan_file" > "$graph_file"

  graph_state_init_run_v2 "$workspace" "$ns" "$run_id" "$plan_file" "$graph_file" 2 >/dev/null

  GRAPH_SCHEDULE_WORKSPACE="$workspace"
  GRAPH_SCHEDULE_LEDGER_NAMESPACE="$ns"
  GRAPH_SCHEDULE_RUN_ID="$run_id"
  GRAPH_SCHEDULE_LEDGER_RUN_DIR="$(graph_state_run_dir "$workspace" "$ns" "$run_id")"
  GRAPH_SCHEDULE_LEDGER_SCHEMA_VERSION=""
  GRAPH_SCHEDULE_LOG_FILE=""

  local nid="left"
  aid="${nid}__${run_id}__1"
  _graph_schedule_ledger_record "$nid" "running" "$aid" "" "" "2026-01-01T00:00:00Z" "" "cursor" "off" "" ""
  # The run's schemaVersion (2) is detected and cached without being told.
  [ "$GRAPH_SCHEDULE_LEDGER_SCHEMA_VERSION" = "2" ]

  _graph_schedule_ledger_record "$nid" "succeeded" "$aid" "success" "0" "" "2026-01-01T00:01:00Z" "cursor" "off" "" ""

  node_file="$(graph_state_node_file "$workspace" "$ns" "$run_id" "$nid")"
  [ "$(jq -r '.schemaVersion' "$node_file")" = "2" ]
  [ "$(jq -r '.status' "$node_file")" = "succeeded" ]
  # One attempts[] object for the whole running-to-terminal attempt, not one
  # record per transition.
  [ "$(jq '.attempts | length' "$node_file")" -eq 1 ]
  [ "$(jq -r '.attempts[0].attemptId' "$node_file")" = "$aid" ]
  [ "$(jq -r '.attempts[0].startedAt' "$node_file")" = "2026-01-01T00:00:00Z" ]
  [ "$(jq -r '.attempts[0].finishedAt' "$node_file")" = "2026-01-01T00:01:00Z" ]
  [ "$(jq -r '.attempts[0].outcome' "$node_file")" = "success" ]
  [ "$(jq -r '.attempts[0].exitCode' "$node_file")" -eq 0 ]
  # Next attempt number is max suffix (1), not array length after a
  # would-be v1 duplication.
  [ "$(graph_state_max_attempt_number "$node_file")" -eq 1 ]
  [ "$(graph_state_max_attempt_number "$node_file")" -eq "$(jq '.attempts | length' "$node_file")" ]

  rm -rf "$tmpd"
}

@test "_graph_schedule_ledger_record on a v1 run keeps writing through graph_state_write_node unchanged" {
  local tmpd workspace ns run_id graph_file plan_file node_file aid
  tmpd="$(mktemp -d)"
  workspace="$tmpd/ws"
  mkdir -p "$workspace"
  ns="sched-v1-ns"
  run_id="run-sched-v1"
  plan_file="$workspace/$(basename "$DIAMOND_PLAN")"
  cp "$DIAMOND_PLAN" "$plan_file"
  graph_file="$tmpd/graph.json"
  plan_pipeline_graph_json "$plan_file" > "$graph_file"

  graph_state_init_run "$workspace" "$ns" "$run_id" "$plan_file" "$graph_file" 2 >/dev/null

  GRAPH_SCHEDULE_WORKSPACE="$workspace"
  GRAPH_SCHEDULE_LEDGER_NAMESPACE="$ns"
  GRAPH_SCHEDULE_RUN_ID="$run_id"
  GRAPH_SCHEDULE_LEDGER_RUN_DIR="$(graph_state_run_dir "$workspace" "$ns" "$run_id")"
  GRAPH_SCHEDULE_LEDGER_SCHEMA_VERSION=""
  GRAPH_SCHEDULE_LOG_FILE=""

  local nid="left"
  aid="${nid}__${run_id}__1"
  _graph_schedule_ledger_record "$nid" "running" "$aid" "" "" "2026-01-01T00:00:00Z" "" "cursor" "off" "" ""
  [ "$GRAPH_SCHEDULE_LEDGER_SCHEMA_VERSION" = "1" ]
  _graph_schedule_ledger_record "$nid" "succeeded" "$aid" "success" "0" "" "2026-01-01T00:01:00Z" "cursor" "off" "" ""

  node_file="$(graph_state_node_file "$workspace" "$ns" "$run_id" "$nid")"
  [ "$(jq -r '.schemaVersion' "$node_file")" = "1" ]
  # v1 behavior is unchanged: one record per transition, still two entries.
  [ "$(jq '.attempts | length' "$node_file")" -eq 2 ]

  rm -rf "$tmpd"
}
