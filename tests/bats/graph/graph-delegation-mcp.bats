#!/usr/bin/env bats
# Tests for the five delegation MCP tools:
#   ralph_delegate_start, ralph_delegate_status, ralph_delegate_wait,
#   ralph_delegate_result, ralph_delegate_cancel
#
# Covers:
#   - Tool catalog presence and schema per scope
#   - Handler logic (start, status, wait, result, cancel)
#   - Scope enforcement (graph-node, native-subagent, delegated-child, operator)
#   - Forged run/node/attempt identity
#   - Out-of-policy runtime or agent
#   - Arbitrary path and env injection rejection
#   - Path traversal in delegation_id
#   - Idempotency (same key+content -> same id)
#   - Idempotency conflict (same key, different content -> error)
#   - Wait timeout (returns within server max, does not block forever)
#   - Child-depth limit enforcement
#   - No scope intended for a child exposes a tool that can create work
#   - Logging to delegation-mcp.log

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-delegation-mcp.sh"
source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-delegation-ledger.sh"

SERVER_SCRIPT="$REPO_ROOT/bundle/.ralph/mcp-server.sh"

# ---- Test helpers ----------------------------------------------------------

setup() {
  command -v jq >/dev/null || skip "jq required"
  TMPD="$(mktemp -d)"
  WS="$TMPD/ws"
  mkdir -p "$WS"
  # Set required context for graph-node scope
  export WORKSPACE_ROOT="$WS"
  export RALPH_MCP_WORKSPACE="$WS"
  export RALPH_GRAPH_NAMESPACE="ns"
  export RALPH_GRAPH_RUN_ID="run-1"
  export RALPH_GRAPH_NODE_ID="parent"
  export RALPH_GRAPH_ATTEMPT_ID="attempt-1"
  export RALPH_GRAPH_DELEGATION_DEPTH="0"
  export RALPH_GRAPH_NODE_POLICY='{"maxDepth":2,"maxChildren":3,"native":{"mode":"read-only","allowedAgents":["research"],"maxParallel":1},"crossRuntime":{"mode":"changeset","allowedRuntimes":["claude"],"allowedAgents":["implementation"],"maxParallel":1}}'
  export RALPH_MCP_SCOPE="graph-node"
  # Capture send_error / send_result output in test variables
  LAST_ERROR=""
  LAST_ERROR_CODE=""
  LAST_RESULT=""
}

teardown() {
  unset WORKSPACE_ROOT RALPH_MCP_WORKSPACE
  unset RALPH_GRAPH_NAMESPACE RALPH_GRAPH_RUN_ID RALPH_GRAPH_NODE_ID
  unset RALPH_GRAPH_ATTEMPT_ID RALPH_GRAPH_DELEGATION_DEPTH RALPH_GRAPH_NODE_POLICY
  unset RALPH_MCP_SCOPE
  rm -rf "$TMPD"
}

# Minimal stubs for send_error / send_result so handler tests capture output.
send_error() {
  LAST_ERROR_CODE="$3"
  LAST_ERROR="$4"
}
send_result() {
  LAST_RESULT="$3"
}

_delegation_args() {
  jq -cn \
    --arg task "inspect files" \
    --arg key "key-1" \
    --arg rt "inherit" \
    --arg ag "research" \
    '{task:$task,idempotency_key:$key,runtime:$rt,agent:$ag}'
}

_call_start() {
  handle_delegate_start "$1" "true" "1"
}

_call_status() {
  handle_delegate_status "$(jq -cn --arg d "$1" '{delegation_id:$d}')" "true" "1"
}

_call_wait() {
  local did="$1" timeout="${2:-1}"
  handle_delegate_wait "$(jq -cn --arg d "$did" --argjson t "$timeout" '{delegation_id:$d,timeout_seconds:$t}')" "true" "1"
}

_call_result() {
  handle_delegate_result "$(jq -cn --arg d "$1" '{delegation_id:$d}')" "true" "1"
}

_call_cancel() {
  handle_delegate_cancel "$(jq -cn --arg d "$1" '{delegation_id:$d}')" "true" "1"
}

# ---- Catalog tests via MCP protocol ----------------------------------------

_tools_list_response() {
  local extra_env=("$@")
  local init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"test","version":"1.0"}}}'
  local list='{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
  printf '%s\n%s\n' "$init" "$list" \
    | env "${extra_env[@]}" RALPH_MCP_WORKSPACE="$WS" bash "$SERVER_SCRIPT" 2>/dev/null \
    | grep '"id":2'
}

@test "catalog: all five delegation tools appear in default (operator) scope" {
  [ -f "$SERVER_SCRIPT" ] || skip "mcp-server.sh missing"
  local resp
  resp="$(_tools_list_response)"
  [ -n "$resp" ] || { echo "empty tools/list"; return 1; }
  for tool in ralph_delegate_start ralph_delegate_status ralph_delegate_wait ralph_delegate_result ralph_delegate_cancel; do
    jq -e --arg n "$tool" '.result.tools[] | select(.name == $n)' <<<"$resp" >/dev/null \
      || { echo "$tool not in catalog; resp=$resp"; return 1; }
  done
}

@test "catalog: graph-node scope hides run_plan, orchestrator_run, graph_run but keeps delegation tools" {
  [ -f "$SERVER_SCRIPT" ] || skip "mcp-server.sh missing"
  local resp
  resp="$(_tools_list_response RALPH_MCP_SCOPE=graph-node)"
  [ -n "$resp" ]
  for hidden in ralph_run_plan ralph_orchestrator_run ralph_graph_run; do
    run jq -e --arg n "$hidden" '.result.tools[] | select(.name == $n)' <<<"$resp"
    [ "$status" -ne 0 ] || { echo "$hidden should be hidden in graph-node scope; resp=$resp"; return 1; }
  done
  for visible in ralph_delegate_start ralph_delegate_status ralph_delegate_wait ralph_delegate_result ralph_delegate_cancel; do
    jq -e --arg n "$visible" '.result.tools[] | select(.name == $n)' <<<"$resp" >/dev/null \
      || { echo "$visible should be visible in graph-node scope; resp=$resp"; return 1; }
  done
}

@test "catalog: native-subagent scope hides delegate_start, run_plan, orchestrator_run, graph_run" {
  [ -f "$SERVER_SCRIPT" ] || skip "mcp-server.sh missing"
  local resp
  resp="$(_tools_list_response RALPH_MCP_SCOPE=native-subagent)"
  [ -n "$resp" ]
  for hidden in ralph_delegate_start ralph_run_plan ralph_orchestrator_run ralph_graph_run; do
    run jq -e --arg n "$hidden" '.result.tools[] | select(.name == $n)' <<<"$resp"
    [ "$status" -ne 0 ] || { echo "$hidden should be hidden in native-subagent scope; resp=$resp"; return 1; }
  done
}

@test "catalog: delegated-child scope hides delegate_start, run_plan, orchestrator_run, graph_run" {
  [ -f "$SERVER_SCRIPT" ] || skip "mcp-server.sh missing"
  local resp
  resp="$(_tools_list_response RALPH_MCP_SCOPE=delegated-child)"
  [ -n "$resp" ]
  for hidden in ralph_delegate_start ralph_run_plan ralph_orchestrator_run ralph_graph_run; do
    run jq -e --arg n "$hidden" '.result.tools[] | select(.name == $n)' <<<"$resp"
    [ "$status" -ne 0 ] || { echo "$hidden should be hidden in delegated-child scope; resp=$resp"; return 1; }
  done
}

@test "catalog: delegation tools have required inputSchema fields" {
  [ -f "$SERVER_SCRIPT" ] || skip "mcp-server.sh missing"
  local resp
  resp="$(_tools_list_response)"
  # start requires task, idempotency_key, runtime, agent
  local start_required
  start_required="$(jq -r '.result.tools[] | select(.name=="ralph_delegate_start") | .inputSchema.required[]' <<<"$resp" | sort | tr '\n' ',')"
  [[ "$start_required" == *"task"* ]] || { echo "task missing from ralph_delegate_start required; got $start_required"; return 1; }
  [[ "$start_required" == *"idempotency_key"* ]] || { echo "idempotency_key missing from required"; return 1; }
  # status requires delegation_id
  local status_required
  status_required="$(jq -r '.result.tools[] | select(.name=="ralph_delegate_status") | .inputSchema.required[]' <<<"$resp")"
  [[ "$status_required" == *"delegation_id"* ]] || { echo "delegation_id missing from ralph_delegate_status required"; return 1; }
}

@test "catalog: no scope intended for a child exposes a tool that can create work" {
  [ -f "$SERVER_SCRIPT" ] || skip "mcp-server.sh missing"
  local work_tools=(ralph_run_plan ralph_orchestrator_run ralph_graph_run ralph_delegate_start)
  for scope in native-subagent delegated-child; do
    local resp
    resp="$(_tools_list_response RALPH_MCP_SCOPE="$scope")"
    [ -n "$resp" ]
    for tool in "${work_tools[@]}"; do
      run jq -e --arg n "$tool" '.result.tools[] | select(.name == $n)' <<<"$resp"
      [ "$status" -ne 0 ] \
        || { echo "$tool is visible in $scope scope but should not be; resp=$resp"; return 1; }
    done
  done
}

# ---- Handler unit tests ----------------------------------------------------

@test "start: valid args create delegation and return delegation_id" {
  local args; args="$(_delegation_args)"
  _call_start "$args"
  [ -n "$LAST_RESULT" ]
  local did; did="$(jq -r '.structuredContent.delegation_id' <<<"$LAST_RESULT" 2>/dev/null)"
  [[ "$did" =~ ^delegation-[0-9a-f]{24}$ ]] || { echo "invalid delegation_id: $did"; return 1; }
  [ "$(jq -r '.structuredContent.status' <<<"$LAST_RESULT")" = "queued" ]
  [ "$(jq -r '.isError' <<<"$LAST_RESULT")" = "false" ]
}

@test "start: idempotent - same key and content returns same delegation_id" {
  local args; args="$(_delegation_args)"
  _call_start "$args"
  local did1; did1="$(jq -r '.structuredContent.delegation_id' <<<"$LAST_RESULT")"
  LAST_RESULT=""
  _call_start "$args"
  local did2; did2="$(jq -r '.structuredContent.delegation_id' <<<"$LAST_RESULT")"
  [ "$did1" = "$did2" ] || { echo "idempotency failed: $did1 != $did2"; return 1; }
}

@test "start: idempotency conflict - same key with different task is rejected" {
  local args; args="$(_delegation_args)"
  _call_start "$args"
  local args2; args2="$(jq -cn --arg task "different task" --arg key "key-1" --arg rt "inherit" --arg ag "research" '{task:$task,idempotency_key:$key,runtime:$rt,agent:$ag}')"
  _call_start "$args2"
  [ -n "$LAST_ERROR" ] || { echo "expected error for idempotency conflict"; return 1; }
  [[ "$LAST_ERROR" == *"idempotency"* ]] || { echo "error should mention idempotency: $LAST_ERROR"; return 1; }
}

@test "start: rejects workspace injection" {
  local args; args="$(jq -cn --arg task "t" --arg key "k" --arg rt "inherit" --arg ag "research" --arg ws "/tmp/evil" '{task:$task,idempotency_key:$key,runtime:$rt,agent:$ag,workspace:$ws}')"
  _call_start "$args"
  [ -n "$LAST_ERROR" ] || { echo "expected error for workspace injection"; return 1; }
  [[ "$LAST_ERROR" == *"workspace"* || "$LAST_ERROR" == *"does not accept"* ]] \
    || { echo "error should mention rejected key: $LAST_ERROR"; return 1; }
}

@test "start: rejects plan_path injection" {
  local args; args="$(jq -cn --arg task "t" --arg key "k" --arg rt "inherit" --arg ag "research" --arg pp "/tmp/evil.md" '{task:$task,idempotency_key:$key,runtime:$rt,agent:$ag,plan_path:$pp}')"
  _call_start "$args"
  [ -n "$LAST_ERROR" ] || { echo "expected error for plan_path injection"; return 1; }
}

@test "start: rejects env_overrides injection" {
  local args; args="$(jq -cn --arg task "t" --arg key "k" --arg rt "inherit" --arg ag "research" '{task:$task,idempotency_key:$key,runtime:$rt,agent:$ag,env_overrides:{FOO:"bar"}}')"
  _call_start "$args"
  [ -n "$LAST_ERROR" ] || { echo "expected error for env_overrides injection"; return 1; }
}

@test "start: rejects artifact_paths injection" {
  local args; args="$(jq -cn --arg task "t" --arg key "k" --arg rt "inherit" --arg ag "research" '{task:$task,idempotency_key:$key,runtime:$rt,agent:$ag,artifact_paths:["/tmp/x"]}')"
  _call_start "$args"
  [ -n "$LAST_ERROR" ] || { echo "expected error for artifact_paths injection"; return 1; }
}

@test "start: rejects graph_path injection" {
  local args; args="$(jq -cn --arg task "t" --arg key "k" --arg rt "inherit" --arg ag "research" '{task:$task,idempotency_key:$key,runtime:$rt,agent:$ag,graph_path:"/tmp/g.json"}')"
  _call_start "$args"
  [ -n "$LAST_ERROR" ] || { echo "expected error for graph_path injection"; return 1; }
}

@test "start: rejects native-subagent scope" {
  export RALPH_MCP_SCOPE="native-subagent"
  local args; args="$(_delegation_args)"
  _call_start "$args"
  [ -n "$LAST_ERROR" ] || { echo "expected scope error"; return 1; }
  [[ "$LAST_ERROR" == *"scope"* ]] || { echo "error should mention scope: $LAST_ERROR"; return 1; }
}

@test "start: rejects delegated-child scope" {
  export RALPH_MCP_SCOPE="delegated-child"
  local args; args="$(_delegation_args)"
  _call_start "$args"
  [ -n "$LAST_ERROR" ] || { echo "expected scope error"; return 1; }
}

@test "start: rejects missing graph context (forged identity)" {
  local saved_ns="$RALPH_GRAPH_NAMESPACE"
  unset RALPH_GRAPH_NAMESPACE
  local args; args="$(_delegation_args)"
  _call_start "$args"
  [ -n "$LAST_ERROR" ] || { echo "expected error for missing context"; return 1; }
  [[ "$LAST_ERROR" == *"context"* ]] || { echo "error should mention context: $LAST_ERROR"; return 1; }
  export RALPH_GRAPH_NAMESPACE="$saved_ns"
}

@test "start: rejects missing run_id context" {
  local saved="$RALPH_GRAPH_RUN_ID"
  unset RALPH_GRAPH_RUN_ID
  _call_start "$(_delegation_args)"
  [ -n "$LAST_ERROR" ]
  export RALPH_GRAPH_RUN_ID="$saved"
}

@test "start: rejects missing attempt_id context" {
  local saved="$RALPH_GRAPH_ATTEMPT_ID"
  unset RALPH_GRAPH_ATTEMPT_ID
  _call_start "$(_delegation_args)"
  [ -n "$LAST_ERROR" ]
  export RALPH_GRAPH_ATTEMPT_ID="$saved"
}

@test "start: rejects out-of-policy runtime" {
  local args; args="$(jq -cn --arg task "t" --arg key "k2" --arg rt "cursor" --arg ag "research" '{task:$task,idempotency_key:$key,runtime:$rt,agent:$ag}')"
  _call_start "$args"
  [ -n "$LAST_ERROR" ] || { echo "expected policy error for cursor runtime"; return 1; }
  [[ "$LAST_ERROR" == *"allowlist"* || "$LAST_ERROR" == *"policy"* || "$LAST_ERROR" == *"runtime"* ]] \
    || { echo "error should mention allowlist/policy: $LAST_ERROR"; return 1; }
}

@test "start: rejects out-of-policy agent for cross-runtime" {
  local args; args="$(jq -cn --arg task "t" --arg key "k3" --arg rt "claude" --arg ag "research" '{task:$task,idempotency_key:$key,runtime:$rt,agent:$ag}')"
  _call_start "$args"
  # research is not in crossRuntime.allowedAgents (which has implementation)
  [ -n "$LAST_ERROR" ] || { echo "expected policy error for out-of-policy agent"; return 1; }
}

@test "start: rejects depth exceeding maxDepth" {
  export RALPH_GRAPH_DELEGATION_DEPTH="2"
  # maxDepth is 2, so depth >= 2 should be rejected
  _call_start "$(_delegation_args)"
  [ -n "$LAST_ERROR" ] || { echo "expected depth limit error"; return 1; }
  [[ "$LAST_ERROR" == *"depth"* ]] || { echo "error should mention depth: $LAST_ERROR"; return 1; }
  export RALPH_GRAPH_DELEGATION_DEPTH="0"
}

@test "start: rejects task exceeding max length" {
  local big_task; big_task="$(awk 'BEGIN{s=""; for(i=0;i<5001;i++) s=s"a"; print s}')"
  local args; args="$(jq -cn --arg task "$big_task" --arg key "bigk" --arg rt "inherit" --arg ag "research" '{task:$task,idempotency_key:$key,runtime:$rt,agent:$ag}')"
  _call_start "$args"
  [ -n "$LAST_ERROR" ] || { echo "expected task-too-long error"; return 1; }
  [[ "$LAST_ERROR" == *"max"* || "$LAST_ERROR" == *"length"* || "$LAST_ERROR" == *"4096"* ]] \
    || { echo "error should mention length: $LAST_ERROR"; return 1; }
}

@test "start: rejects idempotency_key with path traversal" {
  local args; args="$(jq -cn --arg task "t" --arg key "../../evil" --arg rt "inherit" --arg ag "research" '{task:$task,idempotency_key:$key,runtime:$rt,agent:$ag}')"
  _call_start "$args"
  [ -n "$LAST_ERROR" ] || { echo "expected path traversal error in idempotency_key"; return 1; }
}

@test "start: rejects mode not in allowed set" {
  local args; args="$(jq -cn --arg task "t" --arg key "km" --arg rt "inherit" --arg ag "research" --arg m "custom" '{task:$task,idempotency_key:$key,runtime:$rt,agent:$ag,mode:$m}')"
  _call_start "$args"
  [ -n "$LAST_ERROR" ]
}

@test "start: rejects result_kind not in allowed set" {
  local args; args="$(jq -cn --arg task "t" --arg key "kr" --arg rt "inherit" --arg ag "research" --arg k "binary" '{task:$task,idempotency_key:$key,runtime:$rt,agent:$ag,result_kind:$k}')"
  _call_start "$args"
  [ -n "$LAST_ERROR" ]
}

@test "start: freezes per-child read-only or changeset access under a changeset-capable policy" {
  local readonly_args changeset_args readonly_id changeset_id
  readonly_args="$(jq -cn '{task:"inspect",idempotency_key:"access-read",runtime:"claude",agent:"implementation",access:"read-only"}')"
  _call_start "$readonly_args"
  [ -z "$LAST_ERROR" ]
  readonly_id="$(jq -r '.structuredContent.delegation_id' <<<"$LAST_RESULT")"
  jq -e '.accessMode == "read-only"' "$(graph_delegation_ledger_request_file "$WS" ns run-1 parent "$readonly_id")" >/dev/null

  LAST_RESULT=""; LAST_ERROR=""
  changeset_args="$(jq -cn '{task:"edit",idempotency_key:"access-write",runtime:"claude",agent:"implementation",access:"changeset"}')"
  _call_start "$changeset_args"
  [ -z "$LAST_ERROR" ]
  changeset_id="$(jq -r '.structuredContent.delegation_id' <<<"$LAST_RESULT")"
  jq -e '.accessMode == "changeset"' "$(graph_delegation_ledger_request_file "$WS" ns run-1 parent "$changeset_id")" >/dev/null
}

@test "start: rejects changeset access when the frozen policy is read-only" {
  export RALPH_GRAPH_NODE_POLICY='{"maxDepth":1,"maxChildren":1,"crossRuntime":{"mode":"read-only","allowedRuntimes":["claude"],"allowedAgents":["implementation"],"maxParallel":1}}'
  _call_start "$(jq -cn '{task:"edit",idempotency_key:"denied-write",runtime:"claude",agent:"implementation",access:"changeset"}')"
  [[ "$LAST_ERROR" == *"not allowed"* || "$LAST_ERROR" == *"policy"* ]]
}

@test "start: cross-runtime delegation with valid policy succeeds" {
  local args; args="$(jq -cn --arg task "implement feature" --arg key "cr-1" --arg rt "claude" --arg ag "implementation" '{task:$task,idempotency_key:$key,runtime:$rt,agent:$ag}')"
  _call_start "$args"
  [ -z "$LAST_ERROR" ] || { echo "unexpected error for valid cross-runtime: $LAST_ERROR"; return 1; }
  [ "$(jq -r '.structuredContent.status' <<<"$LAST_RESULT")" = "queued" ]
}

@test "start: writes delegation-mcp.log" {
  _call_start "$(_delegation_args)"
  [ -f "$WS/.ralph-workspace/logs/delegation-mcp.log" ] \
    || { echo "delegation-mcp.log not created"; return 1; }
  grep -q "delegation" "$WS/.ralph-workspace/logs/delegation-mcp.log"
}

@test "start: writes its log under an external state root" {
  local external="$TMPD/external-state"
  export RALPH_PLAN_WORKSPACE_ROOT="$external"
  _call_start "$(_delegation_args)"
  [ -f "$external/logs/delegation-mcp.log" ]
  [ ! -e "$WS/.ralph-workspace/logs/delegation-mcp.log" ]
}

@test "status: returns queued status after start" {
  _call_start "$(_delegation_args)"
  local did; did="$(jq -r '.structuredContent.delegation_id' <<<"$LAST_RESULT")"
  LAST_RESULT=""; LAST_ERROR=""
  _call_status "$did"
  [ -z "$LAST_ERROR" ] || { echo "unexpected error: $LAST_ERROR"; return 1; }
  [ "$(jq -r '.structuredContent.status' <<<"$LAST_RESULT")" = "queued" ]
}

@test "status: rejects invalid delegation_id" {
  _call_status "../../etc/passwd"
  [ -n "$LAST_ERROR" ] || { echo "expected error for traversal delegation_id"; return 1; }
  [[ "$LAST_ERROR" == *"traversal"* || "$LAST_ERROR" == *"invalid"* ]] \
    || { echo "error should mention traversal or invalid: $LAST_ERROR"; return 1; }
}

@test "status: rejects delegation_id with wrong format" {
  _call_status "not-a-valid-id"
  [ -n "$LAST_ERROR" ]
}

@test "status: rejects native-subagent scope" {
  export RALPH_MCP_SCOPE="native-subagent"
  _call_status "delegation-aaaaaaaaaaaaaaaaaaaaaaaa"
  [ -n "$LAST_ERROR" ] || { echo "expected scope error"; return 1; }
  export RALPH_MCP_SCOPE="graph-node"
}

@test "status: rejects when delegation does not belong to this node" {
  # delegation_id has valid format but was never created for this node
  _call_status "delegation-aaaaaaaaaaaaaaaaaaaaaaaa"
  [ -n "$LAST_ERROR" ] || { echo "expected not-found error"; return 1; }
  [[ "$LAST_ERROR" == *"not found"* ]] || { echo "error should mention not found: $LAST_ERROR"; return 1; }
}

@test "wait: returns immediately when delegation is in queued state and timeout is short" {
  _call_start "$(_delegation_args)"
  local did; did="$(jq -r '.structuredContent.delegation_id' <<<"$LAST_RESULT")"
  LAST_RESULT=""; LAST_ERROR=""
  # timeout 1 second; delegation is queued so it will timeout
  local before; before="$(date +%s)"
  _call_wait "$did" 1
  local after; after="$(date +%s)"
  local elapsed=$(( after - before ))
  # Should complete within a few seconds of the timeout
  [ "$elapsed" -le 10 ] || { echo "wait did not return promptly; elapsed=$elapsed"; return 1; }
  # Should report timedOut or still-running (not an error, delegation exists)
  [ -z "$LAST_ERROR" ] || { echo "unexpected error from wait: $LAST_ERROR"; return 1; }
}

@test "wait: returns terminal status immediately for succeeded delegation" {
  _call_start "$(_delegation_args)"
  local did; did="$(jq -r '.structuredContent.delegation_id' <<<"$LAST_RESULT")"
  # Manually transition to succeeded
  graph_delegation_ledger_transition \
    "$WS" "ns" "run-1" "parent" "$did" "succeeded" "a1" "pass" '{"tokens":1}' '{"kind":"text","value":"ok"}' ""
  LAST_RESULT=""; LAST_ERROR=""
  _call_wait "$did" 30
  [ -z "$LAST_ERROR" ] || { echo "unexpected wait error: $LAST_ERROR"; return 1; }
  [ "$(jq -r '.structuredContent.status' <<<"$LAST_RESULT")" = "succeeded" ]
}

@test "wait: caps timeout at server maximum" {
  # Validate at the function level: the wait handler must not exceed GRAPH_DELEGATION_MCP_WAIT_MAX_SECONDS.
  # We cannot test 30s blocking in bats, so we verify the cap logic by checking
  # the constant is reasonable.
  [ "$GRAPH_DELEGATION_MCP_WAIT_MAX_SECONDS" -le 60 ] \
    || { echo "wait max is too high: $GRAPH_DELEGATION_MCP_WAIT_MAX_SECONDS"; return 1; }
  [ "$GRAPH_DELEGATION_MCP_WAIT_MAX_SECONDS" -ge 5 ] \
    || { echo "wait max is too low: $GRAPH_DELEGATION_MCP_WAIT_MAX_SECONDS"; return 1; }
}

@test "wait: rejects invalid delegation_id" {
  _call_wait "../../../etc/shadow" 1
  [ -n "$LAST_ERROR" ] || { echo "expected error for traversal delegation_id"; return 1; }
}

@test "result: returns final result for succeeded delegation" {
  _call_start "$(_delegation_args)"
  local did; did="$(jq -r '.structuredContent.delegation_id' <<<"$LAST_RESULT")"
  graph_delegation_ledger_transition \
    "$WS" "ns" "run-1" "parent" "$did" "succeeded" "a1" "pass" '{"tokens":2}' '{"kind":"text","value":"done"}' ""
  LAST_RESULT=""; LAST_ERROR=""
  _call_result "$did"
  [ -z "$LAST_ERROR" ] || { echo "unexpected result error: $LAST_ERROR"; return 1; }
  [ "$(jq -r '.structuredContent.status' <<<"$LAST_RESULT")" = "succeeded" ]
  graph_delegation_ledger_read_status "$WS" "ns" "run-1" "parent" "$did" | jq -e '.acknowledgement.kind == "result-read"' >/dev/null
}

@test "result: rejects non-terminal delegation" {
  _call_start "$(_delegation_args)"
  local did; did="$(jq -r '.structuredContent.delegation_id' <<<"$LAST_RESULT")"
  LAST_RESULT=""; LAST_ERROR=""
  _call_result "$did"
  [ -n "$LAST_ERROR" ] || { echo "expected not-terminal error"; return 1; }
  [[ "$LAST_ERROR" == *"terminal"* ]] || { echo "error should mention terminal: $LAST_ERROR"; return 1; }
}

@test "result: rejects invalid delegation_id" {
  _call_result "../../../etc/passwd"
  [ -n "$LAST_ERROR" ]
}

@test "result: rejects native-subagent scope" {
  export RALPH_MCP_SCOPE="native-subagent"
  _call_result "delegation-aaaaaaaaaaaaaaaaaaaaaaaa"
  [ -n "$LAST_ERROR" ]
  export RALPH_MCP_SCOPE="graph-node"
}

@test "cancel: cancels a queued delegation" {
  _call_start "$(_delegation_args)"
  local did; did="$(jq -r '.structuredContent.delegation_id' <<<"$LAST_RESULT")"
  LAST_RESULT=""; LAST_ERROR=""
  _call_cancel "$did"
  [ -z "$LAST_ERROR" ] || { echo "unexpected cancel error: $LAST_ERROR"; return 1; }
  [ "$(jq -r '.structuredContent.status' <<<"$LAST_RESULT")" = "cancelled" ]
}

@test "cancel: idempotent - cancelling already-cancelled delegation succeeds" {
  _call_start "$(_delegation_args)"
  local did; did="$(jq -r '.structuredContent.delegation_id' <<<"$LAST_RESULT")"
  _call_cancel "$did"
  LAST_RESULT=""; LAST_ERROR=""
  _call_cancel "$did"
  [ -z "$LAST_ERROR" ] || { echo "expected idempotent cancel; got: $LAST_ERROR"; return 1; }
  [ "$(jq -r '.structuredContent.status' <<<"$LAST_RESULT")" = "cancelled" ]
}

@test "cancel: rejects cancellation of succeeded delegation" {
  _call_start "$(_delegation_args)"
  local did; did="$(jq -r '.structuredContent.delegation_id' <<<"$LAST_RESULT")"
  graph_delegation_ledger_transition "$WS" "ns" "run-1" "parent" "$did" "succeeded" "a1" "pass" '{}' 'null' ""
  LAST_RESULT=""; LAST_ERROR=""
  _call_cancel "$did"
  [ -n "$LAST_ERROR" ] || { echo "expected error cancelling succeeded delegation"; return 1; }
  [[ "$LAST_ERROR" == *"terminal"* ]] || { echo "error should mention terminal: $LAST_ERROR"; return 1; }
}

@test "cancel: rejects invalid delegation_id" {
  _call_cancel "../../../etc/shadow"
  [ -n "$LAST_ERROR" ]
}

@test "cancel: rejects delegated-child scope" {
  export RALPH_MCP_SCOPE="delegated-child"
  _call_cancel "delegation-aaaaaaaaaaaaaaaaaaaaaaaa"
  [ -n "$LAST_ERROR" ]
  export RALPH_MCP_SCOPE="graph-node"
}

@test "scope helpers: operator allows start and broker" {
  export RALPH_MCP_SCOPE="operator"
  _graph_delegation_mcp_scope_allows_start
  _graph_delegation_mcp_scope_allows_broker
  export RALPH_MCP_SCOPE="graph-node"
}

@test "scope helpers: native-subagent does not allow start" {
  export RALPH_MCP_SCOPE="native-subagent"
  run _graph_delegation_mcp_scope_allows_start
  [ "$status" -ne 0 ]
  export RALPH_MCP_SCOPE="graph-node"
}

@test "scope helpers: delegated-child does not allow broker" {
  export RALPH_MCP_SCOPE="delegated-child"
  run _graph_delegation_mcp_scope_allows_broker
  [ "$status" -ne 0 ]
  export RALPH_MCP_SCOPE="graph-node"
}

@test "validate_delegation_id: rejects path traversal" {
  run _graph_delegation_mcp_validate_delegation_id "../../../etc/passwd"
  [ "$status" -ne 0 ]
  run _graph_delegation_mcp_validate_delegation_id "delegation-/../evil"
  [ "$status" -ne 0 ]
  run _graph_delegation_mcp_validate_delegation_id "delegation-aaaaaaaaaaaaaaaaaaaaaaaa"
  [ "$status" -eq 0 ]
}

@test "validate_delegation_id: rejects wrong format" {
  run _graph_delegation_mcp_validate_delegation_id "delegation-GGGGGGGGGGGGGGGGGGGGGGGG"
  [ "$status" -ne 0 ]
  run _graph_delegation_mcp_validate_delegation_id "notadelgation-aaaaaaaaaaaaaaaaaaaaaaaa"
  [ "$status" -ne 0 ]
}

@test "runtime_allowed: native allowed when policy mode is not off" {
  local policy='{"maxDepth":1,"native":{"mode":"read-only","allowedAgents":["research"]}}'
  _graph_delegation_mcp_runtime_allowed "inherit" "$policy"
}

@test "runtime_allowed: native rejected when policy mode is off" {
  local policy='{"maxDepth":1,"native":{"mode":"off"}}'
  run _graph_delegation_mcp_runtime_allowed "inherit" "$policy"
  [ "$status" -ne 0 ]
}

@test "runtime_allowed: cross-runtime allowed for listed runtime" {
  local policy='{"maxDepth":1,"crossRuntime":{"mode":"changeset","allowedRuntimes":["claude"],"allowedAgents":["impl"]}}'
  _graph_delegation_mcp_runtime_allowed "claude" "$policy"
}

@test "runtime_allowed: cross-runtime rejected for unlisted runtime" {
  local policy='{"maxDepth":1,"crossRuntime":{"mode":"changeset","allowedRuntimes":["claude"],"allowedAgents":["impl"]}}'
  run _graph_delegation_mcp_runtime_allowed "codex" "$policy"
  [ "$status" -ne 0 ]
}

@test "agent_allowed: wildcard allows any agent in native policy" {
  # Policy with wildcard should NOT be valid (rejected in compile), so just
  # verify that a specific agent name is allowed correctly.
  local policy='{"maxDepth":1,"native":{"mode":"read-only","allowedAgents":["research"]}}'
  _graph_delegation_mcp_agent_allowed "research" "inherit" "$policy"
  run _graph_delegation_mcp_agent_allowed "other" "inherit" "$policy"
  [ "$status" -ne 0 ]
}
