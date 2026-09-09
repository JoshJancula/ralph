#!/usr/bin/env bats
# Unified operator read model across logs, attach, and TUI surfaces.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-state.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-operator-view.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-logs.sh"

GRAPH_RUN_SH="$REPO_ROOT/bundle/.ralph/graph-run.sh"
GRAPH_TUI_PY="$REPO_ROOT/bundle/.ralph/python/graph_tui.py"
PTY_EXEC="$REPO_ROOT/tests/bats/bin/ralph-pty-exec"
GENERIC_FIXTURE="$REPO_ROOT/tests/fixtures/graph-mode-recovery/generic-opencode-request.json"

setup() {
  TMPD="$(mktemp -d)"
  WORKSPACE="$TMPD/ws"
  mkdir -p "$WORKSPACE"
  NAMESPACE="obs-ns"
  RUN_ID="run-obs-001"
  GRAPH_JSON="$TMPD/graph.json"
  PLAN_FILE="$WORKSPACE/obs.plan.md"
  printf '# observability fixture\n' >"$PLAN_FILE"
  jq -n '{
    schemaVersion: 1,
    ralphVersion: "test",
    name: "obs",
    namespace: "obs-ns",
    maxParallel: 1,
    failurePolicy: "cancel",
    nodes: [{
      id: "impl",
      type: "agent",
      dependsOn: [],
      derivedFrom: "stage",
      stage: {id: "impl", runtime: "opencode", role: "implementation", workspaceMode: "snapshot"}
    }],
    edges: []
  }' >"$GRAPH_JSON"
  graph_state_init_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$PLAN_FILE" "$GRAPH_JSON" 1
  RUN_DIR="$(graph_state_run_dir "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
}

teardown() {
  if [[ -n "${FOLLOW_PID:-}" ]]; then
    kill -TERM "$FOLLOW_PID" 2>/dev/null || true
    sleep 0.05
    kill -KILL "$FOLLOW_PID" 2>/dev/null || true
    wait "$FOLLOW_PID" 2>/dev/null || true
    FOLLOW_PID=""
  fi
  unset RALPH_GRAPH_FOLLOW_INTERVAL RALPH_GRAPH_FOLLOW_MAX_POLLS 2>/dev/null || true
  rm -rf "$TMPD"
}

_mcp_request() {
  local payload="$1"
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"observability-test","version":"1"}}}' "$payload" \
    | RALPH_MCP_WORKSPACE="$WORKSPACE" bash "$REPO_ROOT/bundle/.ralph/mcp-server.sh" 2>/dev/null \
    | grep '"id":2' | tail -n 1
}

@test "MCP catalog uses runtime role modelSource and nativeSubagents fields" {
  local response run_plan
  response="$(_mcp_request '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')"
  run_plan="$(printf '%s' "$response" | jq -c '.result.tools[] | select(.name == "ralph_run_plan")')"
  [ "$(printf '%s' "$run_plan" | jq -r '.inputSchema.properties.role.type')" = "string" ]
  [ "$(printf '%s' "$run_plan" | jq -r '.inputSchema.properties.nativeSubagents.enum | join(",")')" = "off,inherit" ]
  [ "$(printf '%s' "$run_plan" | jq -r '.outputSchema.properties.modelSource.type')" = "string" ]
  [ "$(printf '%s' "$run_plan" | jq -r '.outputSchema.properties.delegatedRunId.type')" = "string" ]
  [ "$(printf '%s' "$run_plan" | jq 'has("agent") or (.inputSchema.properties | has("agent"))')" = "false" ]
  [ "$(printf '%s' "$run_plan" | jq -r '.description' | grep -c 'runtime supplies the agent')" -eq 1 ]
}

@test "MCP catalog rejects removed agent fields and removes agent resource" {
  local response resources
  response="$(_mcp_request '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')"
  ! printf '%s' "$response" | jq -e '.result.tools[] | select(.name == "ralph_run_plan") | .inputSchema.properties.agent' >/dev/null
  resources="$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"observability-test","version":"1"}}}' '{"jsonrpc":"2.0","id":2,"method":"resources/list"}' \
    | RALPH_MCP_WORKSPACE="$WORKSPACE" bash "$REPO_ROOT/bundle/.ralph/mcp-server.sh" 2>/dev/null | grep '"id":2' | tail -n 1)"
  [ "$(printf '%s' "$resources" | jq '.result.resources')" = "[]" ]
  ! printf '%s' "$resources" | grep -Eiq 'ralph/agents|agent catalog|brokered child|delegationId'
}

@test "delegated run catalog uses delegatedRunId while graph agent terminology remains" {
  local response
  response="$(_mcp_request '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')"
  [ "$(printf '%s' "$response" | jq '[.result.tools[] | select((.name | startswith("ralph_delegated_run_")) and .name != "ralph_delegated_run_start") | (.inputSchema.properties | has("delegatedRunId"))] | all')" = "true" ]
  [ "$(jq -r '.nodes[0].type' "$GRAPH_JSON")" = "agent" ]
  ! printf '%s' "$response" | grep -Eiq 'brokered child|brokered-child|delegationId'
}

write_actionable_request() {
  local request_id="${1:-req-actionable}"
  mkdir -p "$RUN_DIR/operator/requests"
  jq -nc \
    --arg requestId "$request_id" \
    --arg namespace "$NAMESPACE" \
    --arg runId "$RUN_ID" \
  '{
    schemaVersion: 1,
    requestId: $requestId,
    nonce: "aabbccddeeff00112233445566778899",
    namespace: $namespace,
    runId: $runId,
    nodeId: "impl",
    attemptId: "impl-1",
    runtime: "opencode",
    classification: "operator-permission",
    action: "Bash",
    resource: "src/app.ts",
    effect: "write",
    choices: ["allow-once", "allow-run", "allow-always", "deny"],
    createdAt: "2026-08-13T00:00:00Z",
    expiresAt: "2026-08-13T01:00:00Z"
  }' >"$RUN_DIR/operator/requests/${request_id}.json"
}

write_running_attempt() {
  local create_files="${1:-1}"
  local log_dir="$RUN_DIR/logs/nodes/impl/impl-1"
  mkdir -p "$log_dir" "$RUN_DIR/nodes"
  if [[ "$create_files" == "1" ]]; then
    printf 'agent-line-1\n' >"$log_dir/agent.log"
    printf 'runner-line-1\n' >"$log_dir/runner.log"
    printf '{"attempt":"impl-1"}\n' >"$log_dir/usage.json"
  fi
  jq -nc '{
    schemaVersion: 3,
    nodeId: "impl",
    status: "awaiting-operator",
    lastAttemptId: "impl-1",
    operatorRequestId: "req-actionable",
    attempts: [{
      attemptId: "impl-1",
      logPaths: {
        runner: "logs/nodes/impl/impl-1/runner.log",
        agent: "logs/nodes/impl/impl-1/agent.log",
        usage: "logs/nodes/impl/impl-1/usage.json"
      }
    }]
  }' >"$RUN_DIR/nodes/impl.json"
  jq '.status = "running"' "$RUN_DIR/run.json" >"${RUN_DIR}/run.json.tmp" && mv "${RUN_DIR}/run.json.tmp" "$RUN_DIR/run.json"
}

write_failed_generic_node() {
  mkdir -p "$RUN_DIR/nodes"
  jq -nc '{
    schemaVersion: 3,
    nodeId: "impl",
    status: "failed",
    lastAttemptId: "impl-1",
    attempts: [{
      attemptId: "impl-1",
      outcome: "failed",
      stageOutcomeReport: {
        failure: {
          classification: "unknown",
          summary: "permission requested: external_directory; auto-rejecting",
          retryable: false
        }
      },
      logPaths: {
        runner: "logs/nodes/impl/impl-1/runner.log",
        agent: "logs/nodes/impl/impl-1/agent.log"
      }
    }]
  }' >"$RUN_DIR/nodes/impl.json"
  jq '.status = "failed"' "$RUN_DIR/run.json" >"${RUN_DIR}/run.json.tmp" && mv "${RUN_DIR}/run.json.tmp" "$RUN_DIR/run.json"
}

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

@test "logs attach and status share operator state labels and next actions" {
  write_actionable_request
  write_running_attempt
  local status_out ctx_out logs_out logs_err attach_out
  status_out="$(env NO_COLOR=1 COLUMNS=80 bash "$GRAPH_RUN_SH" status \
    --namespace "$NAMESPACE" --run "$RUN_ID" --workspace "$WORKSPACE")"
  ctx_out="$(graph_attach_operator_context_print "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  [ "$status_out" = "$ctx_out" ]
  printf '%s\n' "$status_out" | grep -q '== NEEDS ATTENTION =='
  printf '%s\n' "$status_out" | grep -q 'awaiting-operator'
  printf '%s\n' "$status_out" | grep -q 'ralph workflow actions respond '"$RUN_ID"' req-actionable'

  logs_out="$(
    bash "$GRAPH_RUN_SH" logs --namespace "$NAMESPACE" --run "$RUN_ID" --node impl \
      --stream agent --workspace "$WORKSPACE" 2>"$TMPD/logs.err"
  )"
  logs_err="$(cat "$TMPD/logs.err")"
  [ "$logs_out" = "agent-line-1" ]
  printf '%s\n' "$logs_err" | grep -q '# graph logs  node=impl  state=awaiting-operator'
  printf '%s\n' "$logs_err" | grep -q 'ralph workflow actions respond '"$RUN_ID"' req-actionable'

  attach_out="$(env RALPH_GRAPH_FOLLOW_MAX_POLLS=1 RALPH_GRAPH_FOLLOW_INTERVAL=0.05 \
    bash "$GRAPH_RUN_SH" attach --namespace "$NAMESPACE" --run "$RUN_ID" \
    --workspace "$WORKSPACE" 2>/dev/null | head -n 20)"
  printf '%s\n' "$attach_out" | grep -q '# graph status'
  printf '%s\n' "$attach_out" | grep -q 'awaiting-operator'
}

@test "logs follow rotation and detach stay read-only" {
  write_running_attempt
  local out="$TMPD/follow.out" err="$TMPD/follow.err"
  local log_file="$RUN_DIR/logs/nodes/impl/impl-1/agent.log"
  local node_file="$RUN_DIR/nodes/impl.json" run_file="$RUN_DIR/run.json"
  local before_node before_run
  before_node="$(cat "$node_file")"
  before_run="$(cat "$run_file")"
  export RALPH_GRAPH_FOLLOW_INTERVAL=0.05
  export RALPH_GRAPH_FOLLOW_MAX_POLLS=80
  bash "$GRAPH_RUN_SH" logs --namespace "$NAMESPACE" --run "$RUN_ID" --node impl \
    --stream agent --follow --workspace "$WORKSPACE" >"$out" 2>"$err" &
  FOLLOW_PID=$!
  wait_for_file_match "$out" 'agent-line-1'
  printf 'agent-line-2\n' >>"$log_file"
  wait_for_file_match "$out" 'agent-line-2'
  printf 'after-trunc\n' >"$log_file"
  wait_for_file_match "$out" 'after-trunc'
  rm -f "$log_file"
  printf 'after-rotate\n' >"$log_file"
  wait_for_file_match "$out" 'after-rotate'
  kill -TERM "$FOLLOW_PID"
  wait_pid_exit "$FOLLOW_PID" || true
  FOLLOW_PID=""
  [ "$(cat "$node_file")" = "$before_node" ]
  [ "$(cat "$run_file")" = "$before_run" ]
  printf '%s\n' "$(cat "$err")" | grep -q '# graph logs  node=impl'
}

@test "attach follow detach and terminal restore stay read-only" {
  write_running_attempt
  local out="$TMPD/attach.out" err="$TMPD/attach.err"
  local events="$RUN_DIR/events.jsonl"
  local node_file="$RUN_DIR/nodes/impl.json" run_file="$RUN_DIR/run.json"
  local before_node before_run
  before_node="$(cat "$node_file")"
  before_run="$(cat "$run_file")"
  printf '%s\n' '{"schemaVersion":1,"sequence":1,"event":"run-started","runId":"run-obs-001"}' >"$events"
  export RALPH_GRAPH_FOLLOW_INTERVAL=0.05
  export RALPH_GRAPH_FOLLOW_MAX_POLLS=80
  bash "$GRAPH_RUN_SH" attach --namespace "$NAMESPACE" --run "$RUN_ID" \
    --workspace "$WORKSPACE" >"$out" 2>"$err" &
  FOLLOW_PID=$!
  wait_for_file_match "$out" 'run-started'
  printf '%s\n' '{"schemaVersion":1,"sequence":2,"event":"node-spawn","runId":"run-obs-001","nodeId":"impl"}' >>"$events"
  wait_for_file_match "$out" 'node-spawn'
  kill -TERM "$FOLLOW_PID"
  wait_pid_exit "$FOLLOW_PID" || true
  FOLLOW_PID=""
  [ "$(cat "$node_file")" = "$before_node" ]
  [ "$(cat "$run_file")" = "$before_run" ]
  printf '%s\n' "$(cat "$out")" | grep -q '# graph status'
}

@test "tui keys and non-tty fallback use the operator read model" {
  write_actionable_request
  write_running_attempt
  local streamed
  streamed="$(python3 "$GRAPH_TUI_PY" --run-dir "$RUN_DIR" --workspace "$WORKSPACE" \
    --graph-run "$GRAPH_RUN_SH" --mode no-tui --refresh-interval 0 2>/dev/null)"
  printf '%s\n' "$streamed" | grep -q 'awaiting-operator'
  printf '%s\n' "$streamed" | grep -q 'ralph workflow actions respond '"$RUN_ID"' req-actionable'

  run python3 -c "
import sys
sys.path.insert(0, '$REPO_ROOT/bundle/.ralph/python')
import graph_tui as gt
snapshot = gt.load_snapshot('$RUN_DIR', workspace='$WORKSPACE', graph_run='$GRAPH_RUN_SH')
state = gt.initial_state(snapshot)
state = gt.apply_keys(state, ['j', 'q'], snapshot)
assert state.quit_requested
frame = gt.render_frame(snapshot, width=80, height=24, state=state)
assert 'awaiting-operator' in frame
"
  [ "$status" -eq 0 ]
}

@test "tui defaults to the latest run when --run is omitted" {
  write_running_attempt
  run bash "$GRAPH_RUN_SH" tui --namespace "$NAMESPACE" \
    --workspace "$WORKSPACE" --no-tui
  [ "$status" -eq 0 ]
  [[ "$output" == *"run=$RUN_ID"* ]]
}

@test "generic permission failures expose no actionable respond key" {
  [ -f "$GENERIC_FIXTURE" ]
  write_failed_generic_node
  mkdir -p "$RUN_DIR/logs/nodes/impl/impl-1"
  printf 'runner-only\n' >"$RUN_DIR/logs/nodes/impl/impl-1/runner.log"

  local view_out logs_err status_out streamed
  view_out="$(graph_operator_view_build "$WORKSPACE" "$NAMESPACE" "$RUN_ID")"
  [ "$(printf '%s' "$view_out" | jq -r '.attention[0].state')" = "failed" ]
  [ "$(printf '%s' "$view_out" | jq -r '.attention[0].nextActions[0].commandText // empty' | grep -c 'actions respond' || true)" = "0" ]
  printf '%s' "$view_out" | jq -r '.attention[0].nextActions[0].commandText // empty' | grep -q 'ralph workflow logs'

  status_out="$(env NO_COLOR=1 bash "$GRAPH_RUN_SH" status --namespace "$NAMESPACE" --run "$RUN_ID" --workspace "$WORKSPACE")"
  ! printf '%s\n' "$status_out" | grep -q 'ralph workflow actions respond'
  printf '%s\n' "$status_out" | grep -q 'ralph workflow logs'

  bash "$GRAPH_RUN_SH" logs --namespace "$NAMESPACE" --run "$RUN_ID" --node impl \
    --stream runner --workspace "$WORKSPACE" >"$TMPD/generic.logs" 2>"$TMPD/generic.err"
  logs_err="$(cat "$TMPD/generic.err")"
  ! printf '%s\n' "$logs_err" | grep -q 'ralph workflow actions respond'
  printf '%s\n' "$logs_err" | grep -q 'state=failed'

  streamed="$(python3 "$GRAPH_TUI_PY" --run-dir "$RUN_DIR" --workspace "$WORKSPACE" \
    --graph-run "$GRAPH_RUN_SH" --mode no-tui --refresh-interval 0 2>/dev/null)"
  ! printf '%s\n' "$streamed" | grep -q 'ralph workflow actions respond'
  printf '%s\n' "$streamed" | grep -q 'failed'
}

@test "observability surfaces remain read-only on a read-only filesystem" {
  write_running_attempt
  local ro_ws="$TMPD/ro-ws"
  cp -R "$WORKSPACE" "$ro_ws"
  chmod -R a-w "$ro_ws"
  local ro_run_dir
  ro_run_dir="$(graph_state_run_dir "$ro_ws" "$NAMESPACE" "$RUN_ID")"
  local before
  before="$(find "$ro_run_dir" -type f -exec shasum {} \; | sort)"
  env NO_COLOR=1 bash "$GRAPH_RUN_SH" status --namespace "$NAMESPACE" --run "$RUN_ID" \
    --workspace "$ro_ws" >/dev/null
  bash "$GRAPH_RUN_SH" logs --namespace "$NAMESPACE" --run "$RUN_ID" --node impl \
    --stream agent --workspace "$ro_ws" >/dev/null 2>/dev/null || true
  env RALPH_GRAPH_FOLLOW_MAX_POLLS=1 RALPH_GRAPH_FOLLOW_INTERVAL=0.05 \
    bash "$GRAPH_RUN_SH" attach --namespace "$NAMESPACE" --run "$RUN_ID" \
    --workspace "$ro_ws" >/dev/null 2>/dev/null || true
  python3 "$GRAPH_TUI_PY" --run-dir "$ro_run_dir" --workspace "$ro_ws" \
    --graph-run "$GRAPH_RUN_SH" --mode no-tui --refresh-interval 0 >/dev/null 2>&1 || true
  after="$(find "$ro_run_dir" -type f -exec shasum {} \; | sort)"
  chmod -R u+w "$ro_ws" 2>/dev/null || true
  [ "$before" = "$after" ]
}

# --- Shared UI routing: public workflow-backed vs standalone internal graphs ---

load_graph_tui_helpers() {
  # Extract the internal TUI helpers without executing graph-run main.
  eval "$(awk '
    /^graph_run_tui_public_run_id\(\)/ {keep=1}
    /^graph_run_tui_public_state_root\(\)/ {keep=1}
    /^graph_run_tui_route_public\(\)/ {keep=1}
    /^graph_run_tui_script\(\)/ {keep=0}
    /^graph_run_tui_python_ok\(\)/ {keep=0}
    /^graph_run_tui_launch\(\)/ {keep=0}
    keep {print}
    keep && /^}/ {keep=0; print ""}
  ' "$GRAPH_RUN_SH")"
}

@test "tui resolves public workflow run id for registry-backed graphs" {
  load_graph_tui_helpers
  local registry="$TMPD/state/workflow-runs/$RUN_ID"
  mkdir -p "$registry"
  jq -n --arg id "$RUN_ID" '{runId:$id,state:"running"}' >"$registry/run.json"
  jq --arg rrp "$registry" '.registryRunPath=$rrp' "$RUN_DIR/run.json" >"$RUN_DIR/run.json.tmp"
  mv "$RUN_DIR/run.json.tmp" "$RUN_DIR/run.json"

  run graph_run_tui_public_run_id "$RUN_DIR"
  [ "$status" -eq 0 ]
  [ "$output" = "$RUN_ID" ]

  run graph_run_tui_public_state_root "$RUN_DIR"
  [ "$status" -eq 0 ]
  [ "$output" = "$TMPD/state" ]
}

@test "tui keeps standalone graphs on the internal viewer path" {
  load_graph_tui_helpers
  run graph_run_tui_public_run_id "$RUN_DIR"
  [ "$status" -ne 0 ]

  run graph_run_tui_route_public "$RUN_DIR" "no-tui"
  [ "$status" -eq 2 ]
}

@test "tui routes registry-backed graphs through workflow_operator_watch" {
  load_graph_tui_helpers
  local registry="$TMPD/state/workflow-runs/$RUN_ID"
  mkdir -p "$registry"
  jq -n --arg id "$RUN_ID" '{runId:$id,state:"running"}' >"$registry/run.json"
  jq --arg rrp "$registry" '.registryRunPath=$rrp' "$RUN_DIR/run.json" >"$RUN_DIR/run.json.tmp"
  mv "$RUN_DIR/run.json.tmp" "$RUN_DIR/run.json"

  workflow_operator_watch() {
    printf 'routed-public state=%s run=%s plain=%s\n' "$1" "$2" "$3"
    return 0
  }
  run graph_run_tui_route_public "$RUN_DIR" "no-tui"
  [ "$status" -eq 0 ]
  [[ "$output" == *"routed-public state=$TMPD/state run=$RUN_ID plain=1"* ]]

  run graph_run_tui_route_public "$RUN_DIR" "tui"
  [ "$status" -eq 0 ]
  [[ "$output" == *"plain=0"* ]]
}

@test "tui latest selector remains internal and does not expose workflow namespace flags" {
  write_running_attempt
  run bash "$GRAPH_RUN_SH" tui --namespace "$NAMESPACE" --workspace "$WORKSPACE" --no-tui
  [ "$status" -eq 0 ]
  [[ "$output" == *"run=$RUN_ID"* ]]

  run bash "$REPO_ROOT/bundle/.ralph/workflow-cli.sh" watch --help
  [ "$status" -eq 0 ]
  ! printf '%s\n' "$output" | grep -q -- '--namespace'
  ! printf '%s\n' "$output" | grep -q -- '--tui'
}

@test "tui no-python and no-curses fallbacks remain available for standalone graphs" {
  write_running_attempt
  # no-curses / forced plain path
  run python3 "$GRAPH_TUI_PY" --run-dir "$RUN_DIR" --workspace "$WORKSPACE" \
    --graph-run "$GRAPH_RUN_SH" --mode no-tui --refresh-interval 0
  [ "$status" -eq 0 ]
  [[ "$output" == *"run=$RUN_ID"* ]]

  # Probe reports curses unavailability without launching an interactive session.
  run python3 - <<PY
import json, os, sys
sys.path.insert(0, "$REPO_ROOT/bundle/.ralph/python")
import graph_tui as gt
caps = gt.probe_tui_capabilities(
    stdin_isatty=True,
    stdout_isatty=True,
    term="xterm",
    environ={},
    curses_importer=lambda: (_ for _ in ()).throw(ImportError("no curses")),
)
assert caps.available is False
assert caps.reason == "curses"
plan = gt.decide_tui_launch("auto", caps)
assert plan.backend == "status"
assert plan.fallback is True
caps_py = gt.probe_tui_capabilities(python_ok=False)
assert caps_py.reason == "python"
print("fallback-ok")
PY
  [ "$status" -eq 0 ]
  [[ "$output" == *"fallback-ok"* ]]
}

@test "graph and workflow viewers share semantic palette roles" {
  run python3 - <<PY
import sys
sys.path.insert(0, "$REPO_ROOT/bundle/.ralph/python")
import graph_tui as gt
import workflow_curses as wc
assert issubclass(gt.TerminalRestorer, wc.TerminalRestorer)
assert gt.init_curses_palette is wc.init_palette
assert gt.paint_semantic_canvas is wc.paint_canvas
class Fake:
    A_NORMAL=0; A_BOLD=1; A_DIM=2; A_REVERSE=4
    COLOR_CYAN=6; COLOR_GREEN=2; COLOR_YELLOW=3; COLOR_RED=1
    def has_colors(self): return False
palette = gt.init_curses_palette(Fake())
for role in ("accent", "success", "warning", "failure", "muted", "heading", "focus"):
    assert role in palette, role
print("shared-ok")
PY
  [ "$status" -eq 0 ]
  [[ "$output" == *"shared-ok"* ]]
}
