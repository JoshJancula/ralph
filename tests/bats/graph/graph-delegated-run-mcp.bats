#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

MCP="$REPO_ROOT/bundle/.ralph/mcp-server.sh"
MCP_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-delegation-mcp.sh"

setup() {
  TMPD="$(mktemp -d)"
  WS="$TMPD/workspace"
  mkdir -p "$WS"
  unset RALPH_PLAN_WORKSPACE_ROOT
  export WORKSPACE_ROOT="$WS" RALPH_PROJECT_ROOT="$WS" RALPH_MCP_WORKSPACE="$WS"
  export RALPH_MCP_SCOPE=graph-node
  export RALPH_GRAPH_NAMESPACE=delegated-test
  export RALPH_GRAPH_RUN_ID=run-1
  export RALPH_GRAPH_NODE_ID=node-1
  export RALPH_GRAPH_ATTEMPT_ID=attempt-1
  export RALPH_GRAPH_NODE_POLICY='{"delegatedRuns":{"mode":"read-only","runtimes":["codex"],"roles":["research"],"maxRuns":2,"maxParallel":1}}'
  source "$MCP_LIB"
  LAST_ERROR=""
  LAST_RESULT=""
}

teardown() {
  chmod -R u+w "$TMPD" 2>/dev/null || true
  rm -rf "$TMPD"
}

send_error() { LAST_ERROR="$4"; printf 'MCP_ERROR: %s\n' "$4"; }
send_result() { LAST_RESULT="$3"; }

start_args() {
  jq -cn --arg key "${1:-key-1}" '{task:"inspect files",idempotencyKey:$key,runtime:"codex",role:"research",artifactPaths:["results/out.json"]}'
}

start_run() {
  handle_delegated_run_start "$(start_args "${1:-key-1}")" true 1
  jq -r '.structuredContent.delegatedRunId' <<<"$LAST_RESULT"
}

@test "delegated run catalog uses exact names and camelCase schemas" {
  local tools
  tools="$(graph_delegated_run_mcp_tools_json)"
  [ "$(jq 'length' <<<"$tools")" = 5 ]
  [ "$(jq -r '.[].name' <<<"$tools" | sort | tr '\n' ' ')" = "ralph_delegated_run_cancel ralph_delegated_run_result ralph_delegated_run_start ralph_delegated_run_status ralph_delegated_run_wait " ]
  jq -e '.[0:] | all(.[]; .inputSchema.additionalProperties == false)' <<<"$tools" >/dev/null
  jq -e '.[] | select(.name == "ralph_delegated_run_start") | .inputSchema.required == ["task","idempotencyKey","runtime"]' <<<"$tools" >/dev/null
  jq -e '.[] | select(.name == "ralph_delegated_run_status") | .inputSchema.required == ["delegatedRunId"]' <<<"$tools" >/dev/null
}

@test "delegated run start validates before ledger mutation and is idempotent" {
  local bad='{"task":"x","idempotencyKey":"bad","runtime":"codex","role":"wrong"}'
  handle_delegated_run_start "$bad" true 1
  [ -n "$LAST_ERROR" ]
  [ ! -d "$WS/.ralph-workspace/delegated-runs" ]

  LAST_ERROR=""
  local id1 id2
  id1="$(start_run)"
  [ -n "$id1" ] && [ -z "$LAST_ERROR" ]
  LAST_RESULT="" LAST_ERROR=""
  handle_delegated_run_start "$(start_args)" true 2
  id2="$(jq -r '.structuredContent.delegatedRunId' <<<"$LAST_RESULT")"
  [ "$id1" = "$id2" ]
  [ "$(jq -r '.idempotencyKey' "$WS/.ralph-workspace/delegated-runs/$id1/request.json")" = "key-1" ]
}

@test "delegated run start rejects invalid runtime, role, paths, and idempotency" {
  for args in \
    '{"task":"x","idempotencyKey":"../bad","runtime":"codex","role":"research"}' \
    '{"task":"x","idempotencyKey":"k2","runtime":"cursor","role":"research"}' \
    '{"task":"x","idempotencyKey":"k3","runtime":"codex","role":"Research"}' \
    '{"task":"x","idempotencyKey":"k4","runtime":"codex","role":"research","artifactPaths":["../escape"]}' \
    '{"task":"x","idempotencyKey":"k5","runtime":"codex","role":"research","artifactPaths":["a//b"]}' \
    '{"task":"x","idempotencyKey":"k6","runtime":"codex","role":"research","extra":true}'; do
    LAST_ERROR=""
    handle_delegated_run_start "$args" true 1
    [ -n "$LAST_ERROR" ]
  done
}

@test "delegated run status wait result and cancel use delegatedRunId" {
  local id
  id="$(start_run)"
  LAST_RESULT="" LAST_ERROR=""
  handle_delegated_run_status "$(jq -cn --arg id "$id" '{delegatedRunId:$id}')" true 2
  [ "$(jq -r '.structuredContent.delegatedRunId' <<<"$LAST_RESULT")" = "$id" ]
  LAST_RESULT=""
  handle_delegated_run_wait "$(jq -cn --arg id "$id" '{delegatedRunId:$id,timeoutSeconds:1}')" true 3
  [ "$(jq -r '.structuredContent.timedOut' <<<"$LAST_RESULT")" = true ]

  graph_delegation_ledger_transition "$WS" "$id" running >/dev/null
  graph_delegation_ledger_transition "$WS" "$id" succeeded "" "" '{}' '{"answer":"ok"}' >/dev/null
  LAST_RESULT=""
  handle_delegated_run_result "$(jq -cn --arg id "$id" '{delegatedRunId:$id}')" true 4
  [ "$(jq -r '.structuredContent.result.answer' <<<"$LAST_RESULT")" = ok ]

  # A separate queued run exercises cancellation without changing the
  # terminal-result contract above.
  local cancel_id
  cancel_id="$(start_run key-2)"
  LAST_RESULT=""
  handle_delegated_run_cancel "$(jq -cn --arg id "$cancel_id" '{delegatedRunId:$id}')" true 5
  [ "$(jq -r '.structuredContent.delegatedRunId' <<<"$LAST_RESULT")" = "$cancel_id" ]
  [ "$(jq -r '.structuredContent.status' <<<"$LAST_RESULT")" = cancelled ]
}

@test "old delegate tool is not found and stdout remains JSON" {
  local init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"test","version":"1"}}}'
  local old
  old="$(printf '%s\n' "$init" '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ralph_delegate_start","arguments":{}}}' | bash "$MCP" 2>/dev/null | grep '"id":2')"
  [ "$(jq -r '.error.code' <<<"$old")" = -32601 ]
  [ "$(jq -e . >/dev/null 2>&1 <<<"$old"; echo $?)" = 0 ]
}

# Ported from the pre-redesign graph-delegation-mcp suite: the tool names and
# fields changed, but the scope, identity, injection, and lifecycle boundaries
# they guarded are unchanged.

catalog_hidden() { graph_delegated_run_mcp_catalog_hidden_tools | sort | tr '\n' ' '; }

@test "catalog: operator scope exposes all five delegated-run tools" {
  RALPH_MCP_SCOPE=operator
  [ -z "$(catalog_hidden | tr -d ' ')" ]
}

@test "catalog: graph-node scope hides work-creating tools but keeps delegated-run tools" {
  RALPH_MCP_SCOPE=graph-node
  [ "$(catalog_hidden)" = "ralph_graph_run ralph_orchestrator_run ralph_run_plan " ]
}

@test "catalog: no scope intended for a child exposes a tool that can create work" {
  local scope hidden
  for scope in native-subagent delegated-child; do
    RALPH_MCP_SCOPE="$scope"
    hidden="$(catalog_hidden)"
    for tool in ralph_delegated_run_start ralph_delegated_run_status ralph_delegated_run_wait \
      ralph_delegated_run_result ralph_delegated_run_cancel ralph_run_plan ralph_orchestrator_run ralph_graph_run; do
      [[ "$hidden" == *"$tool"* ]]
    done
  done
}

@test "start: rejects a child scope instead of creating work" {
  local scope
  for scope in native-subagent delegated-child; do
    RALPH_MCP_SCOPE="$scope"
    LAST_ERROR=""
    handle_delegated_run_start "$(start_args)" true 1
    [ -n "$LAST_ERROR" ]
    [ ! -d "$WS/.ralph-workspace/delegated-runs" ]
  done
}

@test "start: rejects forged identity with missing graph context" {
  local var
  for var in RALPH_GRAPH_NAMESPACE RALPH_GRAPH_RUN_ID RALPH_GRAPH_NODE_ID RALPH_GRAPH_ATTEMPT_ID; do
    local saved="${!var}"
    unset "$var"
    LAST_ERROR=""
    handle_delegated_run_start "$(start_args)" true 1
    [ -n "$LAST_ERROR" ]
    [ ! -d "$WS/.ralph-workspace/delegated-runs" ]
    export "$var=$saved"
  done
}

@test "start: rejects workspace, plan, env, and graph path injection" {
  local args
  for key in workspace plan_path planPath env_overrides envOverrides graph_path graphPath model agent; do
    args="$(jq -cn --arg k "$key" '{task:"x",idempotencyKey:"key-1",runtime:"codex",role:"research"} + {($k):"injected"}')"
    LAST_ERROR=""
    handle_delegated_run_start "$args" true 1
    [ -n "$LAST_ERROR" ]
  done
  [ ! -d "$WS/.ralph-workspace/delegated-runs" ]
}

@test "start: rejects an out-of-policy runtime and role" {
  LAST_ERROR=""
  handle_delegated_run_start '{"task":"x","idempotencyKey":"k1","runtime":"claude","role":"research"}' true 1
  [ -n "$LAST_ERROR" ]
  LAST_ERROR=""
  handle_delegated_run_start '{"task":"x","idempotencyKey":"k2","runtime":"codex","role":"implementation"}' true 1
  [ -n "$LAST_ERROR" ]
  # An allowlist that is present requires a listed role rather than a roleless request.
  LAST_ERROR=""
  handle_delegated_run_start '{"task":"x","idempotencyKey":"k3","runtime":"codex"}' true 1
  [ -n "$LAST_ERROR" ]
  [ ! -d "$WS/.ralph-workspace/delegated-runs" ]
}

@test "start: rejects a request under an off or malformed policy" {
  RALPH_GRAPH_NODE_POLICY='{"delegatedRuns":{"mode":"off","runtimes":[],"roles":[],"maxRuns":0,"maxParallel":0}}'
  LAST_ERROR=""
  handle_delegated_run_start "$(start_args)" true 1
  [ -n "$LAST_ERROR" ]
  RALPH_GRAPH_NODE_POLICY='not json'
  LAST_ERROR=""
  handle_delegated_run_start "$(start_args)" true 1
  [ -n "$LAST_ERROR" ]
  [ ! -d "$WS/.ralph-workspace/delegated-runs" ]
}

@test "start: rejects a task over the server maximum" {
  local big args
  big="$(head -c 5000 /dev/zero | tr '\0' 'x')"
  args="$(jq -cn --arg task "$big" '{task:$task,idempotencyKey:"key-1",runtime:"codex",role:"research"}')"
  LAST_ERROR=""
  handle_delegated_run_start "$args" true 1
  [ -n "$LAST_ERROR" ]
  [ ! -d "$WS/.ralph-workspace/delegated-runs" ]
}

@test "start: an idempotency key reused with a different task is rejected" {
  local id
  id="$(start_run key-conflict)"
  [ -n "$id" ]
  LAST_ERROR=""
  handle_delegated_run_start '{"task":"a different task","idempotencyKey":"key-conflict","runtime":"codex","role":"research"}' true 2
  [ -n "$LAST_ERROR" ]
  [ "$(jq -r '.task' "$WS/.ralph-workspace/delegated-runs/$id/request.json")" = "inspect files" ]
}

@test "start: writes the delegated-run MCP log" {
  start_run >/dev/null
  [ -s "$WS/.ralph-workspace/logs/delegated-run-mcp.log" ]
  grep -q "start delegatedRunId=delegated-run-" "$WS/.ralph-workspace/logs/delegated-run-mcp.log"
}

@test "read tools: reject a child scope" {
  local id handler
  id="$(start_run)"
  for handler in handle_delegated_run_status handle_delegated_run_wait \
    handle_delegated_run_result handle_delegated_run_cancel; do
    RALPH_MCP_SCOPE=native-subagent
    LAST_ERROR=""
    "$handler" "$(jq -cn --arg id "$id" '{delegatedRunId:$id}')" true 2
    [ -n "$LAST_ERROR" ]
    RALPH_MCP_SCOPE=delegated-child
    LAST_ERROR=""
    "$handler" "$(jq -cn --arg id "$id" '{delegatedRunId:$id}')" true 2
    [ -n "$LAST_ERROR" ]
    RALPH_MCP_SCOPE=graph-node
  done
}

@test "read tools: reject a traversing or wrong-format delegatedRunId" {
  local handler bad
  for handler in handle_delegated_run_status handle_delegated_run_result handle_delegated_run_cancel; do
    for bad in "../escape" "delegation-0123456789abcdef01234567" "delegated-run-XYZ" ""; do
      LAST_ERROR=""
      run "$handler" "$(jq -cn --arg id "$bad" '{delegatedRunId:$id}')" true 2
      [[ "$output" == *MCP_ERROR:* ]]
    done
  done
}

@test "wait: caps the timeout at the server maximum" {
  local id started elapsed
  id="$(start_run)"
  [ "$GRAPH_DELEGATED_RUN_MCP_WAIT_MAX_SECONDS" = 30 ]
  # A request above the cap is clamped rather than honoured; the schema itself
  # also refuses a non-integer or sub-second timeout.
  LAST_ERROR=""
  handle_delegated_run_wait "$(jq -cn --arg id "$id" '{delegatedRunId:$id,timeoutSeconds:0}')" true 2
  [ -n "$LAST_ERROR" ]
  started="$(date +%s)"
  LAST_RESULT=""
  handle_delegated_run_wait "$(jq -cn --arg id "$id" '{delegatedRunId:$id,timeoutSeconds:1}')" true 3
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -lt 30 ]
  [ "$(jq -r '.structuredContent.timedOut' <<<"$LAST_RESULT")" = true ]
}

@test "result: rejects a nonterminal delegated run" {
  local id
  id="$(start_run)"
  LAST_ERROR=""
  handle_delegated_run_result "$(jq -cn --arg id "$id" '{delegatedRunId:$id}')" true 2
  [ -n "$LAST_ERROR" ]
}

@test "cancel: is idempotent for a cancelled run and refuses a succeeded run" {
  local id done_id
  id="$(start_run key-cancel)"
  handle_delegated_run_cancel "$(jq -cn --arg id "$id" '{delegatedRunId:$id}')" true 2
  LAST_ERROR=""
  LAST_RESULT=""
  handle_delegated_run_cancel "$(jq -cn --arg id "$id" '{delegatedRunId:$id}')" true 3
  [ -z "$LAST_ERROR" ]
  [ "$(jq -r '.structuredContent.status' <<<"$LAST_RESULT")" = cancelled ]

  done_id="$(start_run key-done)"
  graph_delegation_ledger_transition "$WS" "$done_id" running >/dev/null
  graph_delegation_ledger_transition "$WS" "$done_id" succeeded "" "" '{}' '{"answer":"ok"}' >/dev/null
  LAST_ERROR=""
  handle_delegated_run_cancel "$(jq -cn --arg id "$done_id" '{delegatedRunId:$id}')" true 4
  [ -n "$LAST_ERROR" ]
}
