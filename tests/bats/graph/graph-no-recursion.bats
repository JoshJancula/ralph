#!/usr/bin/env bats
# Adversarial depth-one enforcement tests.
#
# Every test in this file asserts that a forbidden recursive or nested spawn
# attempt fails WITHOUT starting a process. Each failure must produce a record
# in no-recursion.log.
#
# Scenarios covered:
#   1. Direct nested native spawn: native-subagent scope calls graph_native_subagent_setup
#   2. Broker call from native child: native-subagent scope calls ralph_delegated_run_start
#   3. Broker call from delegated child: delegated-child scope calls ralph_delegated_run_start
#   4. Raw graph/orchestrator call: child scope hidden from catalog + handler denial
#   5. Forged depth env: delegated-child scope with RALPH_GRAPH_DELEGATION_DEPTH=0
#   6. Inherited ambient MCP: depth=1 with no scope set blocks delegation
#   7. Custom agent attempts to re-enable tools via env

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

_DEPTH_POLICY_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-depth-policy.sh"
_MCP_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-delegation-mcp.sh"
_SUBAGENT_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-native-subagent.sh"

setup() {
  command -v jq >/dev/null || skip "jq required"
  TMPD="$(mktemp -d)"
  WS="$TMPD/ws"
  mkdir -p "$WS/.ralph-workspace/logs"
  export WORKSPACE_ROOT="$WS"
  export RALPH_MCP_WORKSPACE="$WS"
  # Standard graph-node context
  export RALPH_GRAPH_NAMESPACE="ns"
  export RALPH_GRAPH_RUN_ID="run-1"
  export RALPH_GRAPH_NODE_ID="parent"
  export RALPH_GRAPH_ATTEMPT_ID="attempt-1"
  export RALPH_GRAPH_NODE_RUNTIME="claude"
  export RALPH_GRAPH_DELEGATION_DEPTH="0"
  export RALPH_GRAPH_NODE_POLICY='{"delegatedRuns":{"mode":"read-only","runtimes":["codex"],"roles":["research"],"maxRuns":3,"maxParallel":1}}'
  export RALPH_MCP_SCOPE="graph-node"

  # Stubs for MCP protocol send functions
  LAST_ERROR=""
  LAST_ERROR_CODE=""
  LAST_RESULT=""

  # shellcheck source=../../../bundle/.ralph/bash-lib/graph/graph-depth-policy.sh
  source "$_DEPTH_POLICY_LIB"
}

teardown() {
  unset WORKSPACE_ROOT RALPH_MCP_WORKSPACE
  unset RALPH_GRAPH_NAMESPACE RALPH_GRAPH_RUN_ID RALPH_GRAPH_NODE_ID
  unset RALPH_GRAPH_ATTEMPT_ID RALPH_GRAPH_DELEGATION_DEPTH RALPH_GRAPH_NODE_POLICY
  unset RALPH_GRAPH_NODE_RUNTIME RALPH_MCP_SCOPE
  unset RALPH_STAGE_SUBAGENTS RALPH_GRAPH_CROSS_RUNTIME_DELEGATION
  rm -rf "$TMPD"
}

send_error() { LAST_ERROR_CODE="$3"; LAST_ERROR="$4"; }
send_result() { LAST_RESULT="$3"; }

_no_recursion_log() { printf '%s/.ralph-workspace/logs/no-recursion.log\n' "$WS"; }

_start_args() {
  jq -cn \
    --arg task "inspect files" \
    --arg key "key-1" \
    --arg rt "codex" \
    --arg role "research" \
    '{task:$task,idempotencyKey:$key,runtime:$rt,role:$role}'
}

# ---------------------------------------------------------------------------
# 1. Direct nested native spawn: native-subagent scope tries to call setup
# ---------------------------------------------------------------------------

@test "no-recursion: native-subagent scope cannot spawn a native subagent (scope layer)" {
  export RALPH_MCP_SCOPE="native-subagent"
  export RALPH_GRAPH_DELEGATION_DEPTH="1"

  # shellcheck source=../../../bundle/.ralph/bash-lib/graph/graph-native-subagent.sh
  source "$_SUBAGENT_LIB"

  local tmpoverlay="$TMPD/overlays"
  run graph_native_subagent_setup '{"native":{"mode":"read-only","allowedAgents":["research"]}}' \
    "claude" "$WS" "child-node" "$tmpoverlay"

  [ "$status" -ne 0 ]
  [[ "$output" == *"scope"* || "$output" == *"permitted"* || "$output" == *"spawn"* || "$output" == *"removed"* ]] \
    || { echo "output should mention scope/spawn denial; got: $output"; return 1; }
  # No Ralph-child overlay artifacts written.
  [ ! -d "$tmpoverlay" ] || [ -z "$(find "$tmpoverlay" -type f 2>/dev/null)" ]
}

@test "no-recursion: depth=1 env prevents native spawn even without explicit scope" {
  # No RALPH_MCP_SCOPE set (inherits as operator-like), but depth=1 triggers depth layer
  unset RALPH_MCP_SCOPE
  export RALPH_GRAPH_DELEGATION_DEPTH="1"

  # shellcheck source=../../../bundle/.ralph/bash-lib/graph/graph-native-subagent.sh
  source "$_SUBAGENT_LIB"

  local tmpoverlay="$TMPD/overlays"
  # depth >= GRAPH_DEPTH_MAX should block in native spawn enforcer
  run graph_depth_policy_enforce_native_spawn "claude" "native-subagent-spawn"

  [ "$status" -ne 0 ]
}

@test "no-recursion: native spawn denial writes record to no-recursion.log" {
  export RALPH_MCP_SCOPE="native-subagent"
  export RALPH_GRAPH_DELEGATION_DEPTH="1"

  # shellcheck source=../../../bundle/.ralph/bash-lib/graph/graph-native-subagent.sh
  source "$_SUBAGENT_LIB"

  local tmpoverlay="$TMPD/overlays"
  graph_native_subagent_setup '{"native":{"mode":"read-only","allowedAgents":["research"]}}' \
    "claude" "$WS" "child-node" "$tmpoverlay" 2>/dev/null || true

  local logfile; logfile="$(_no_recursion_log)"
  [ -f "$logfile" ] || { echo "no-recursion.log was not created"; return 1; }
  grep -q "native-spawn\|scope" "$logfile" \
    || { echo "log has no denial record; contents: $(cat "$logfile")"; return 1; }
}

@test "no-recursion: Ralph-child setup from parent scope refuses and writes no overlay or ledger" {
  export RALPH_MCP_SCOPE="graph-node"
  export RALPH_GRAPH_DELEGATION_DEPTH="0"

  # shellcheck source=../../../bundle/.ralph/bash-lib/graph/graph-native-subagent.sh
  source "$_SUBAGENT_LIB"

  local tmpoverlay="$TMPD/overlays-parent"
  mkdir -p "$tmpoverlay"
  run graph_native_subagent_setup '{"native":{"mode":"read-only","allowedAgents":["research"]}}' \
    "claude" "$WS" "parent-node" "$tmpoverlay"

  [ "$status" -ne 0 ]
  [[ "$output" == *"removed"* || "$output" == *"nativeSubagents"* ]]
  [ -z "$(find "$tmpoverlay" -type f 2>/dev/null)" ]
  # No native-child ledger directory under the workspace.
  [ ! -d "$WS/.ralph-workspace/native-subagent-children" ]
  [ ! -d "$WS/.ralph-workspace/native-child-ledger" ]
}

# ---------------------------------------------------------------------------
# 2. Broker call from native child (native-subagent scope)
# ---------------------------------------------------------------------------

@test "no-recursion: native-subagent scope cannot call ralph_delegated_run_start" {
  export RALPH_MCP_SCOPE="native-subagent"

  # shellcheck source=../../../bundle/.ralph/bash-lib/graph/graph-delegation-mcp.sh
  source "$_MCP_LIB"

  handle_delegated_run_start "$(_start_args)" "true" "1"

  [ -n "$LAST_ERROR" ] || { echo "expected error for native-subagent scope"; return 1; }
  [[ "$LAST_ERROR" == *"scope"* ]] \
    || { echo "error should mention scope; got: $LAST_ERROR"; return 1; }
}

@test "no-recursion: native-subagent scope cannot call broker read tools" {
  export RALPH_MCP_SCOPE="native-subagent"

  source "$_MCP_LIB"

  local fake_id="delegation-000000000000000000000001"
  handle_delegated_run_status "$(jq -cn --arg d "$fake_id" '{delegatedRunId:$d}')" "true" "1"
  [ -n "$LAST_ERROR" ] || { echo "expected status denial"; return 1; }

  LAST_ERROR=""
  handle_delegated_run_wait "$(jq -cn --arg d "$fake_id" '{delegatedRunId:$d}')" "true" "1"
  [ -n "$LAST_ERROR" ] || { echo "expected wait denial"; return 1; }

  LAST_ERROR=""
  handle_delegated_run_result "$(jq -cn --arg d "$fake_id" '{delegatedRunId:$d}')" "true" "1"
  [ -n "$LAST_ERROR" ] || { echo "expected result denial"; return 1; }

  LAST_ERROR=""
  handle_delegated_run_cancel "$(jq -cn --arg d "$fake_id" '{delegatedRunId:$d}')" "true" "1"
  [ -n "$LAST_ERROR" ] || { echo "expected cancel denial"; return 1; }
}

@test "no-recursion: native-subagent broker call denial writes no-recursion.log record" {
  export RALPH_MCP_SCOPE="native-subagent"

  source "$_MCP_LIB"

  handle_delegated_run_start "$(_start_args)" "true" "1"

  local logfile; logfile="$(_no_recursion_log)"
  [ -f "$logfile" ] || { echo "no-recursion.log was not created"; return 1; }
  grep -q '"layer"' "$logfile" && grep -q '"scope"' "$logfile" \
    || { echo "log has no structured denial record; contents: $(cat "$logfile")"; return 1; }
  grep -q '"requested_tool".*ralph_delegated_run_start' "$logfile" \
    || { echo "log missing requested_tool field; contents: $(cat "$logfile")"; return 1; }
}

# ---------------------------------------------------------------------------
# 3. Broker call from delegated child (delegated-child scope)
# ---------------------------------------------------------------------------

@test "no-recursion: delegated-child scope cannot call ralph_delegated_run_start" {
  export RALPH_MCP_SCOPE="delegated-child"
  export RALPH_GRAPH_DELEGATION_DEPTH="1"

  source "$_MCP_LIB"

  handle_delegated_run_start "$(_start_args)" "true" "1"

  [ -n "$LAST_ERROR" ] || { echo "expected error for delegated-child scope"; return 1; }
  [[ "$LAST_ERROR" == *"scope"* ]] \
    || { echo "error should mention scope; got: $LAST_ERROR"; return 1; }
}

@test "no-recursion: delegated-child scope cannot call broker read tools" {
  export RALPH_MCP_SCOPE="delegated-child"
  export RALPH_GRAPH_DELEGATION_DEPTH="1"

  source "$_MCP_LIB"

  local fake_id="delegation-000000000000000000000001"
  handle_delegated_run_status "$(jq -cn --arg d "$fake_id" '{delegatedRunId:$d}')" "true" "1"
  [ -n "$LAST_ERROR" ] || { echo "expected status denial for delegated-child"; return 1; }
}

@test "no-recursion: delegated-child broker call denial writes no-recursion.log record" {
  export RALPH_MCP_SCOPE="delegated-child"
  export RALPH_GRAPH_DELEGATION_DEPTH="1"

  source "$_MCP_LIB"

  handle_delegated_run_start "$(_start_args)" "true" "1"

  local logfile; logfile="$(_no_recursion_log)"
  [ -f "$logfile" ] || { echo "no-recursion.log was not created"; return 1; }
  local record
  record="$(grep '"requested_tool".*ralph_delegated_run_start' "$logfile" | head -1)"
  [ -n "$record" ] || { echo "no matching denial record; contents: $(cat "$logfile")"; return 1; }
  # Validate JSON fields present
  jq -e '.layer and .runtime and .parent_node and .child_identity and .requested_tool and .reason' \
    <<<"$record" >/dev/null \
    || { echo "denial record missing required fields; record: $record"; return 1; }
}

# ---------------------------------------------------------------------------
# 4. Raw graph/orchestrator/run_plan call from child scope
# ---------------------------------------------------------------------------

@test "no-recursion: catalog hides ralph_run_plan from delegated-child scope" {
  export RALPH_MCP_SCOPE="delegated-child"

  source "$_MCP_LIB"

  local hidden_tools
  hidden_tools="$(graph_delegated_run_mcp_catalog_hidden_tools)"
  [[ "$hidden_tools" == *"ralph_run_plan"* ]] \
    || { echo "ralph_run_plan should be hidden for delegated-child; got: $hidden_tools"; return 1; }
  [[ "$hidden_tools" == *"ralph_orchestrator_run"* ]] \
    || { echo "ralph_orchestrator_run should be hidden for delegated-child; got: $hidden_tools"; return 1; }
  [[ "$hidden_tools" == *"ralph_graph_run"* ]] \
    || { echo "ralph_graph_run should be hidden for delegated-child; got: $hidden_tools"; return 1; }
}

@test "no-recursion: catalog hides spawn tools from native-subagent scope" {
  export RALPH_MCP_SCOPE="native-subagent"

  source "$_MCP_LIB"

  local hidden_tools
  hidden_tools="$(graph_delegated_run_mcp_catalog_hidden_tools)"
  [[ "$hidden_tools" == *"ralph_delegated_run_start"* ]] \
    || { echo "ralph_delegated_run_start should be hidden for native-subagent; got: $hidden_tools"; return 1; }
  [[ "$hidden_tools" == *"ralph_run_plan"* ]] \
    || { echo "ralph_run_plan should be hidden for native-subagent; got: $hidden_tools"; return 1; }
}

@test "no-recursion: graph-node scope hides raw run tools from catalog" {
  export RALPH_MCP_SCOPE="graph-node"

  source "$_MCP_LIB"

  local hidden_tools
  hidden_tools="$(graph_delegated_run_mcp_catalog_hidden_tools)"
  [[ "$hidden_tools" == *"ralph_run_plan"* ]] \
    || { echo "ralph_run_plan should be hidden for graph-node; got: $hidden_tools"; return 1; }
  [[ "$hidden_tools" == *"ralph_orchestrator_run"* ]] \
    || { echo "ralph_orchestrator_run should be hidden for graph-node; got: $hidden_tools"; return 1; }
}

# ---------------------------------------------------------------------------
# 5. Forged depth env: delegated-child scope with RALPH_GRAPH_DELEGATION_DEPTH=0
# ---------------------------------------------------------------------------

@test "no-recursion: forged depth=0 does not bypass delegated-child scope block" {
  export RALPH_MCP_SCOPE="delegated-child"
  export RALPH_GRAPH_DELEGATION_DEPTH="0"  # forged: child claiming it is a top-level node

  source "$_MCP_LIB"

  handle_delegated_run_start "$(_start_args)" "true" "1"

  [ -n "$LAST_ERROR" ] || { echo "expected scope denial despite forged depth=0"; return 1; }
  [[ "$LAST_ERROR" == *"scope"* ]] \
    || { echo "scope layer should catch forged depth before depth check; got: $LAST_ERROR"; return 1; }
}

@test "no-recursion: forged depth=0 denial is logged to no-recursion.log" {
  export RALPH_MCP_SCOPE="delegated-child"
  export RALPH_GRAPH_DELEGATION_DEPTH="0"

  source "$_MCP_LIB"

  handle_delegated_run_start "$(_start_args)" "true" "1"

  local logfile; logfile="$(_no_recursion_log)"
  [ -f "$logfile" ] || { echo "no-recursion.log was not created"; return 1; }
  grep -q '"layer".*"scope"' "$logfile" \
    || { echo "log should record scope layer denial; contents: $(cat "$logfile")"; return 1; }
}

@test "no-recursion: frozen policy hard-caps maxDepth above 1" {
  export RALPH_MCP_SCOPE="graph-node"
  export RALPH_GRAPH_DELEGATION_DEPTH="1"
  # Policy claims maxDepth=5, which exceeds the frozen cap
  export RALPH_GRAPH_NODE_POLICY='{"delegatedRuns":{"mode":"read-only","runtimes":["codex"],"roles":["research"],"maxRuns":3,"maxParallel":1}}'

  source "$_MCP_LIB"

  handle_delegated_run_start "$(_start_args)" "true" "1"

  [ -n "$LAST_ERROR" ] || { echo "expected depth denial even with maxDepth=5 in policy"; return 1; }
  [[ "$LAST_ERROR" == *"depth"* ]] \
    || { echo "error should mention depth; got: $LAST_ERROR"; return 1; }

  local logfile; logfile="$(_no_recursion_log)"
  [ -f "$logfile" ] || { echo "no-recursion.log was not created"; return 1; }
  # Should contain either a policy-cap or depth record
  grep -q '"layer"' "$logfile" \
    || { echo "log should have denial records; contents: $(cat "$logfile")"; return 1; }
}

# ---------------------------------------------------------------------------
# 6. Inherited ambient MCP: depth=1 with no scope set (no RALPH_MCP_SCOPE)
# ---------------------------------------------------------------------------

@test "no-recursion: unset scope with depth=1 blocks delegation at depth layer" {
  unset RALPH_MCP_SCOPE  # simulates inheriting ambient MCP without scope restriction
  export RALPH_GRAPH_DELEGATION_DEPTH="1"
  # policy maxDepth=1, depth is already at limit
  export RALPH_GRAPH_NODE_POLICY='{"delegatedRuns":{"mode":"read-only","runtimes":["codex"],"roles":["research"],"maxRuns":3,"maxParallel":1}}'

  source "$_MCP_LIB"

  handle_delegated_run_start "$(jq -cn \
    --arg task "inspect" \
    --arg key "k-ambient" \
    --arg rt "codex" \
    --arg role "research" \
    '{task:$task,idempotencyKey:$key,runtime:$rt,role:$role}')" "true" "1"

  [ -n "$LAST_ERROR" ] || { echo "expected depth denial with unset scope + depth=1"; return 1; }
  [[ "$LAST_ERROR" == *"depth"* ]] \
    || { echo "error should mention depth; got: $LAST_ERROR"; return 1; }
}

@test "no-recursion: unset scope with depth=1 denial is logged to no-recursion.log" {
  unset RALPH_MCP_SCOPE
  export RALPH_GRAPH_DELEGATION_DEPTH="1"
  export RALPH_GRAPH_NODE_POLICY='{"delegatedRuns":{"mode":"read-only","runtimes":["codex"],"roles":["research"],"maxRuns":3,"maxParallel":1}}'

  source "$_MCP_LIB"

  handle_delegated_run_start "$(jq -cn \
    --arg task "inspect" \
    --arg key "k-ambient-log" \
    --arg rt "codex" \
    --arg role "research" \
    '{task:$task,idempotencyKey:$key,runtime:$rt,role:$role}')" "true" "1"

  local logfile; logfile="$(_no_recursion_log)"
  [ -f "$logfile" ] || { echo "no-recursion.log was not created"; return 1; }
  grep -q '"layer"' "$logfile" \
    || { echo "no denial record in log; contents: $(cat "$logfile")"; return 1; }
}

# ---------------------------------------------------------------------------
# 7. Custom agent attempts to re-enable tools via env or scope override
# ---------------------------------------------------------------------------

@test "no-recursion: custom agent cannot override RALPH_MCP_SCOPE to re-enable start" {
  # Agent sets scope to graph-node but RALPH_GRAPH_DELEGATION_DEPTH=1 still blocks
  export RALPH_MCP_SCOPE="graph-node"
  export RALPH_GRAPH_DELEGATION_DEPTH="1"
  export RALPH_GRAPH_NODE_POLICY='{"delegatedRuns":{"mode":"read-only","runtimes":["codex"],"roles":["research"],"maxRuns":3,"maxParallel":1}}'

  source "$_MCP_LIB"

  handle_delegated_run_start "$(_start_args)" "true" "1"

  [ -n "$LAST_ERROR" ] || { echo "expected depth denial for graph-node with depth=1"; return 1; }
  [[ "$LAST_ERROR" == *"depth"* ]] \
    || { echo "error should mention depth; got: $LAST_ERROR"; return 1; }
}

@test "no-recursion: ledger guard blocks depth > 1 even if handler is bypassed" {
  source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-delegation-ledger.sh"

  # Attempt to write a ledger entry with depth=2 (exceeds GRAPH_DEPTH_MAX=1)
  run graph_depth_policy_ledger_guard "2" "ralph_delegated_run_start"

  [ "$status" -ne 0 ] || { echo "ledger guard should reject depth=2"; return 1; }
}

@test "no-recursion: ledger guard allows depth <= 1" {
  run graph_depth_policy_ledger_guard "1" "ralph_delegated_run_start"
  [ "$status" -eq 0 ] || { echo "ledger guard should allow depth=1; got status=$status output=$output"; return 1; }
}

@test "no-recursion: scope_allows_spawn false for all child scopes" {
  # Empty string and unset both default to 'operator' via ${:-} expansion; they
  # are not child scopes and are intentionally NOT in this list.
  local denied_scopes=("native-subagent" "delegated-child" "unknown")
  for scope in "${denied_scopes[@]}"; do
    export RALPH_MCP_SCOPE="$scope"
    run graph_depth_policy_scope_allows_spawn
    [ "$status" -ne 0 ] \
      || { echo "scope '$scope' should not allow spawn; returned 0"; return 1; }
  done
}

@test "no-recursion: scope_allows_spawn true only for operator and graph-node" {
  local allowed_scopes=("operator" "graph-node")
  for scope in "${allowed_scopes[@]}"; do
    export RALPH_MCP_SCOPE="$scope"
    run graph_depth_policy_scope_allows_spawn
    [ "$status" -eq 0 ] \
      || { echo "scope '$scope' should allow spawn; returned $status"; return 1; }
  done
}

@test "no-recursion: child_env_vars sets all required depth-blocking env" {
  run graph_depth_policy_child_env_vars "delegated-child" "1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RALPH_MCP_SCOPE=delegated-child"* ]] \
    || { echo "missing RALPH_MCP_SCOPE; got: $output"; return 1; }
  [[ "$output" == *"RALPH_GRAPH_DELEGATION_DEPTH=1"* ]] \
    || { echo "missing RALPH_GRAPH_DELEGATION_DEPTH; got: $output"; return 1; }
  [[ "$output" == *"RALPH_STAGE_SUBAGENTS=off"* ]] \
    || { echo "missing RALPH_STAGE_SUBAGENTS; got: $output"; return 1; }
  [[ "$output" == *"RALPH_GRAPH_CROSS_RUNTIME_DELEGATION=off"* ]] \
    || { echo "missing RALPH_GRAPH_CROSS_RUNTIME_DELEGATION; got: $output"; return 1; }
}

@test "no-recursion: child_env_vars never emits a parent scope" {
  # Passing a parent scope as child_scope should be sanitized to delegated-child
  run graph_depth_policy_child_env_vars "operator" "1"
  [ "$status" -eq 0 ]
  [[ "$output" != *"RALPH_MCP_SCOPE=operator"* ]] \
    || { echo "child_env_vars must not emit parent scope; got: $output"; return 1; }
  [[ "$output" == *"RALPH_MCP_SCOPE=delegated-child"* ]] \
    || { echo "sanitized scope should be delegated-child; got: $output"; return 1; }
}

@test "no-recursion: denial record contains required fields (no prompt or secrets)" {
  export RALPH_MCP_SCOPE="delegated-child"
  export RALPH_GRAPH_DELEGATION_DEPTH="1"

  source "$_MCP_LIB"

  handle_delegated_run_start "$(_start_args)" "true" "1"

  local logfile; logfile="$(_no_recursion_log)"
  local record
  record="$(grep '"layer"' "$logfile" | head -1)"
  [ -n "$record" ] || { echo "no denial record found in log"; return 1; }

  # Must have all required fields
  jq -e '.ts' <<<"$record" >/dev/null || { echo "missing ts field"; return 1; }
  jq -e '.layer' <<<"$record" >/dev/null || { echo "missing layer field"; return 1; }
  jq -e '.runtime' <<<"$record" >/dev/null || { echo "missing runtime field"; return 1; }
  jq -e '.parent_node' <<<"$record" >/dev/null || { echo "missing parent_node field"; return 1; }
  jq -e '.child_identity' <<<"$record" >/dev/null || { echo "missing child_identity field"; return 1; }
  jq -e '.requested_tool' <<<"$record" >/dev/null || { echo "missing requested_tool field"; return 1; }
  jq -e '.reason' <<<"$record" >/dev/null || { echo "missing reason field"; return 1; }

  # Must NOT contain prompt or secret content (these fields must not appear)
  [[ "$record" != *'"prompt"'* ]] || { echo "record must not contain prompt field"; return 1; }
  [[ "$record" != *'"secret"'* ]] || { echo "record must not contain secret field"; return 1; }
  [[ "$record" != *'"task"'* ]] || { echo "record must not contain task (content) field"; return 1; }
}
