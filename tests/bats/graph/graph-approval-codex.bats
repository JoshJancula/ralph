#!/usr/bin/env bats
# Codex app-server approval request capture against a fake JSON-RPC server.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../run-plan/run-plan-invoke-test-helper.bash"
source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-codex.sh"

setup() {
  run_plan_invoke_test_setup_common
  export RALPH_GRAPH_NODE_ID="node-approval-1"
  export RALPH_CODEX_APP_SERVER_CAPTURE_TIMEOUT=3
}

teardown() {
  run_plan_invoke_codex_app_server_cleanup 2>/dev/null || true
  unset RALPH_GRAPH_NODE_ID RALPH_GRAPH_APPROVAL RALPH_CODEX_APP_SERVER_CAPTURE_TIMEOUT
  run_plan_invoke_test_teardown_common
}

write_codex_app_server_help_stub() {
  local mode="${1:-supported}"
  local launched_marker="${2:-}"
  cat >"$BIN_DIR/codex" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "app-server" && "\${2:-}" == "--help" ]]; then
  if [[ "$mode" == "supported" ]]; then
    printf '%s\n' "Usage: codex app-server" "Start the JSON-RPC app-server and wait for initialize."
    exit 0
  fi
  if [[ "$mode" == "empty-help" ]]; then
    printf '%s\n' "ok"
    exit 0
  fi
  printf '%s\n' "unknown command" >&2
  exit 2
fi
if [[ "\$1" == "app-server" ]]; then
  if [[ -n "$launched_marker" ]]; then
    printf 'launched\n' >"$launched_marker"
  fi
  printf '%s\n' "app-server should not start during feature detect" >&2
  exit 3
fi
if [[ "\$1" == "--help" || "\$1" == "help" ]]; then
  printf '%s\n' "Usage: codex" "  exec" "  app-server"
  exit 0
fi
exit 0
EOF
  chmod +x "$BIN_DIR/codex"
}

write_fake_app_server() {
  local request_file="$1"
  local launched_marker="${2:-}"
  cat >"$BIN_DIR/fake-app-server" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "$launched_marker" ]]; then
  printf 'launched\n' >"$launched_marker"
fi
read -r req || exit 1
id="\$(printf '%s' "\$req" | jq -r '.id // 0')"
jq -nc --argjson id "\$id" '{id:\$id,result:{userAgent:"fake-codex",platformFamily:"test",platformOs:"darwin"}}'
read -r _initialized || true
printf '%s\n' '{"method":"item/started","params":{"item":{"id":"item-cmd-1","type":"commandExecution"}}}'
cat "$request_file"
printf '\n'
cat >/dev/null || true
EOF
  chmod +x "$BIN_DIR/fake-app-server"
}

write_exec_and_app_server_stub() {
  local record="$1"
  cat >"$BIN_DIR/codex" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "mcp" && "\${2:-}" == "--help" ]]; then
  printf '%s\n' "Usage: codex mcp" "  add" "  remove"
  exit 0
fi
if [[ "\$1" == "exec" && "\${2:-}" == "--help" ]]; then
  printf '%s\n' "Usage: codex exec" "  --config VALUE" "  --strict-config"
  exit 0
fi
if [[ "\$1" == "app-server" && "\${2:-}" == "--help" ]]; then
  printf '%s\n' "Usage: codex app-server" "Start the JSON-RPC app-server."
  exit 0
fi
if [[ "\$1" == "app-server" ]]; then
  printf 'app-server\n' >>"$record"
  exit 3
fi
printf '%s\n' "\$@" >>"$record"
exit 0
EOF
  chmod +x "$BIN_DIR/codex"
}

command_request_json() {
  jq -nc '{
    id: 11,
    method: "item/commandExecution/requestApproval",
    params: {
      threadId: "thr-cmd",
      turnId: "turn-cmd",
      itemId: "item-cmd-1",
      command: "ls -la src",
      cwd: "/tmp/ws",
      reason: "Need to list files"
    }
  }'
}

file_request_json() {
  jq -nc '{
    id: 12,
    method: "item/fileChange/requestApproval",
    params: {
      threadId: "thr-file",
      turnId: "turn-file",
      itemId: "item-file-1",
      grantRoot: "/tmp/ws/src",
      reason: "Need write access"
    }
  }'
}

network_request_json() {
  jq -nc '{
    id: 13,
    method: "item/commandExecution/requestApproval",
    params: {
      threadId: "thr-net",
      turnId: "turn-net",
      itemId: "item-net-1",
      networkApprovalContext: {host: "example.com", protocol: "https"},
      reason: "Need network"
    }
  }'
}

permissions_request_json() {
  jq -nc '{
    id: 14,
    method: "item/permissions/requestApproval",
    params: {
      threadId: "thr-perm",
      turnId: "turn-perm",
      itemId: "item-perm-1",
      reason: "Select a workspace root",
      permissions: {fileSystem: {write: ["/tmp/ws/src", "/tmp/ws/shared"]}},
      availableDecisions: ["grant-subset", "decline"]
    }
  }'
}

@test "codex approval request feature-detects app-server from cli help without a model call" {
  local launched="$TEST_TMPDIR/app-server-launched"
  write_codex_app_server_help_stub supported "$launched"
  run run_plan_invoke_codex_app_server_supported "$BIN_DIR/codex"
  [ "$status" -eq 0 ]
  [ ! -f "$launched" ]
}

@test "codex approval request reports unsupported when app-server is missing" {
  write_codex_app_server_help_stub missing
  run run_plan_invoke_codex_app_server_supported "$BIN_DIR/codex"
  [ "$status" -ne 0 ]
  run _run_plan_invoke_codex_app_server_capability_missing "$BIN_DIR/codex"
  [ "$status" -eq 0 ]
  [[ "$output" == *"codex app-server"* ]]
}

@test "codex approval request reports unsupported when app-server help has no protocol surface" {
  write_codex_app_server_help_stub empty-help
  run run_plan_invoke_codex_app_server_supported "$BIN_DIR/codex"
  [ "$status" -ne 0 ]
}

@test "codex approval request captures command thread turn item type resource and choices" {
  local captured
  run run_plan_invoke_codex_app_server_capture_request "$(command_request_json)"
  [ "$status" -eq 0 ]
  captured="$output"
  [ "$(printf '%s' "$captured" | jq -r '.thread')" = "thr-cmd" ]
  [ "$(printf '%s' "$captured" | jq -r '.turn')" = "turn-cmd" ]
  [ "$(printf '%s' "$captured" | jq -r '.item')" = "item-cmd-1" ]
  [ "$(printf '%s' "$captured" | jq -r '.requestType')" = "command" ]
  [ "$(printf '%s' "$captured" | jq -r '.resource')" = "ls -la src" ]
  [ "$(printf '%s' "$captured" | jq -r '.choices | join(",")')" = "accept,acceptForSession,acceptWithExecpolicyAmendment,decline" ]
  [ "$(printf '%s' "$captured" | jq -r '.requestId')" = "11" ]
}

@test "codex approval request captures file grant root" {
  local captured
  run run_plan_invoke_codex_app_server_capture_request "$(file_request_json)"
  [ "$status" -eq 0 ]
  captured="$output"
  [ "$(printf '%s' "$captured" | jq -r '.thread')" = "thr-file" ]
  [ "$(printf '%s' "$captured" | jq -r '.turn')" = "turn-file" ]
  [ "$(printf '%s' "$captured" | jq -r '.item')" = "item-file-1" ]
  [ "$(printf '%s' "$captured" | jq -r '.requestType')" = "file" ]
  [ "$(printf '%s' "$captured" | jq -r '.resource')" = "/tmp/ws/src" ]
  [ "$(printf '%s' "$captured" | jq -r '.choices | join(",")')" = "accept,acceptForSession,decline" ]
}

@test "codex approval request captures network host from networkApprovalContext" {
  local captured
  run run_plan_invoke_codex_app_server_capture_request "$(network_request_json)"
  [ "$status" -eq 0 ]
  captured="$output"
  [ "$(printf '%s' "$captured" | jq -r '.thread')" = "thr-net" ]
  [ "$(printf '%s' "$captured" | jq -r '.turn')" = "turn-net" ]
  [ "$(printf '%s' "$captured" | jq -r '.item')" = "item-net-1" ]
  [ "$(printf '%s' "$captured" | jq -r '.requestType')" = "network" ]
  [ "$(printf '%s' "$captured" | jq -r '.resource')" = "example.com" ]
  [ "$(printf '%s' "$captured" | jq -r '.choices | join(",")')" = "accept,acceptForSession,applyNetworkPolicyAmendment,decline" ]
}

@test "codex approval request captures permissions resource and available decisions" {
  local captured
  run run_plan_invoke_codex_app_server_capture_request "$(permissions_request_json)"
  [ "$status" -eq 0 ]
  captured="$output"
  [ "$(printf '%s' "$captured" | jq -r '.thread')" = "thr-perm" ]
  [ "$(printf '%s' "$captured" | jq -r '.turn')" = "turn-perm" ]
  [ "$(printf '%s' "$captured" | jq -r '.item')" = "item-perm-1" ]
  [ "$(printf '%s' "$captured" | jq -r '.requestType')" = "permissions" ]
  [ "$(printf '%s' "$captured" | jq -r '.resource')" = "/tmp/ws/src" ]
  [ "$(printf '%s' "$captured" | jq -r '.choices | join(",")')" = "grant-subset,decline" ]
}

@test "codex approval request prefers availableDecisions when present" {
  local raw captured
  raw="$(command_request_json | jq -c '.params.availableDecisions=["accept","decline"]')"
  run run_plan_invoke_codex_app_server_capture_request "$raw"
  [ "$status" -eq 0 ]
  captured="$output"
  [ "$(printf '%s' "$captured" | jq -r '.choices | join(",")')" = "accept,decline" ]
}

@test "codex approval request ignores non-approval json-rpc methods" {
  run run_plan_invoke_codex_app_server_capture_request '{"id":1,"method":"item/started","params":{"threadId":"t","turnId":"u","itemId":"i"}}'
  [ "$status" -ne 0 ]
}

@test "codex approval request talks to a fake json-rpc server only" {
  local request_file="$TEST_TMPDIR/command-request.json"
  local launched="$TEST_TMPDIR/fake-launched"
  command_request_json >"$request_file"
  write_fake_app_server "$request_file" "$launched"

  run run_plan_invoke_codex_app_server_capture_from_command "$BIN_DIR/fake-app-server"
  [ "$status" -eq 0 ]
  [ -f "$launched" ]
  [ "$(printf '%s' "$output" | jq -r '.thread')" = "thr-cmd" ]
  [ "$(printf '%s' "$output" | jq -r '.turn')" = "turn-cmd" ]
  [ "$(printf '%s' "$output" | jq -r '.item')" = "item-cmd-1" ]
  [ "$(printf '%s' "$output" | jq -r '.requestType')" = "command" ]
  [ "$(printf '%s' "$output" | jq -r '.resource')" = "ls -la src" ]
  [ "$(printf '%s' "$output" | jq -r '.choices | index("accept") != null')" = "true" ]
}

@test "codex approval request captures file request from a fake json-rpc server" {
  local request_file="$TEST_TMPDIR/file-request.json"
  file_request_json >"$request_file"
  write_fake_app_server "$request_file"

  run run_plan_invoke_codex_app_server_capture_from_command "$BIN_DIR/fake-app-server"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.requestType')" = "file" ]
  [ "$(printf '%s' "$output" | jq -r '.resource')" = "/tmp/ws/src" ]
  [ "$(printf '%s' "$output" | jq -r '.thread')" = "thr-file" ]
  [ "$(printf '%s' "$output" | jq -r '.item')" = "item-file-1" ]
}

@test "codex approval request does not start app-server outside graph mode" {
  local request_file="$TEST_TMPDIR/command-request.json"
  local launched="$TEST_TMPDIR/fake-launched"
  command_request_json >"$request_file"
  write_fake_app_server "$request_file" "$launched"
  unset RALPH_GRAPH_NODE_ID RALPH_GRAPH_APPROVAL

  run run_plan_invoke_codex_app_server_capture_from_command "$BIN_DIR/fake-app-server"
  [ "$status" -ne 0 ]
  [[ "$output" == *"graph-only"* ]]
  [ ! -f "$launched" ]
}

write_fake_app_server_wait() {
  local request_file="$1"
  local record_file="$2"
  local waiting_marker="${3:-}"
  local resolve_mode="${4:-after-response}"
  cat >"$BIN_DIR/fake-app-server" <<EOF
#!/usr/bin/env bash
set -euo pipefail
record_file="$record_file"
waiting_marker="$waiting_marker"
resolve_mode="$resolve_mode"
request_file="$request_file"
read -r req || exit 1
id="\$(printf '%s' "\$req" | jq -r '.id // 0')"
jq -nc --argjson id "\$id" '{id:\$id,result:{userAgent:"fake-codex",platformFamily:"test",platformOs:"darwin"}}'
read -r _initialized || true
printf '%s\n' '{"method":"item/started","params":{"item":{"id":"item-cmd-1","type":"commandExecution"}}}'
cat "\$request_file"
printf '\n'
thread="\$(jq -r '.params.threadId // empty' "\$request_file")"
req_id="\$(jq -c '.id' "\$request_file")"
if [[ -n "\$waiting_marker" ]]; then
  printf 'waiting\n' >"\$waiting_marker"
fi
if [[ "\$resolve_mode" == "immediate" ]]; then
  jq -nc --arg thread "\$thread" --argjson requestId "\$req_id" \
    '{method:"serverRequest/resolved",params:{threadId:\$thread,requestId:\$requestId}}'
fi
while IFS= read -r line; do
  [[ -n "\$line" ]] || continue
  printf '%s\n' "\$line" >>"\$record_file"
  if [[ "\$resolve_mode" != "never" ]]; then
    jq -nc --arg thread "\$thread" --argjson requestId "\$req_id" \
      '{method:"serverRequest/resolved",params:{threadId:\$thread,requestId:\$requestId}}'
  fi
done
EOF
  chmod +x "$BIN_DIR/fake-app-server"
  : >"$record_file"
}

start_codex_wait_session() {
  local request_file="$1"
  local record_file="$2"
  local waiting_marker="${3:-}"
  local resolve_mode="${4:-after-response}"
  write_fake_app_server_wait "$request_file" "$record_file" "$waiting_marker" "$resolve_mode"
  run_plan_invoke_codex_app_server_session_start "$BIN_DIR/fake-app-server"
}

@test "codex approval request leaves non-graph exec invocation unchanged" {
  local record="$TEST_TMPDIR/codex.args"
  write_exec_and_app_server_stub "$record"
  unset RALPH_GRAPH_NODE_ID RALPH_GRAPH_APPROVAL
  export PROMPT="codex-nongraph-prompt"
  export RALPH_MODE=native
  export CODEX_PLAN_NO_ADD_AGENTS_DIR=1
  export CODEX_PLAN_CLI="$BIN_DIR/codex"

  run ralph_run_plan_invoke_codex
  [ "$status" -eq 0 ]
  [ -s "$record" ]
  [[ "$(cat "$record")" == *"exec"* ]]
  [[ "$(cat "$record")" == *"codex-nongraph-prompt"* ]]
  [[ "$(cat "$record")" != *"app-server"* ]]
}

@test "codex approval response maps once to accept" {
  run run_plan_invoke_codex_app_server_map_decision "$(command_request_json)" once
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.fallback')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.ralphDecision')" = "once" ]
  [ "$(printf '%s' "$output" | jq -r '.native')" = "accept" ]
  [ "$(printf '%s' "$output" | jq -r '.response.result.decision')" = "accept" ]
  [ "$(printf '%s' "$output" | jq -r '.response.id')" = "11" ]
}

@test "codex approval response maps session to acceptForSession" {
  run run_plan_invoke_codex_app_server_map_decision "$(command_request_json)" session
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.native')" = "acceptForSession" ]
  [ "$(printf '%s' "$output" | jq -r '.response.result.decision')" = "acceptForSession" ]
}

@test "codex approval response maps deny to decline" {
  run run_plan_invoke_codex_app_server_map_decision "$(file_request_json)" deny
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.native')" = "decline" ]
  [ "$(printf '%s' "$output" | jq -r '.response.result.decision')" = "decline" ]
}

@test "codex approval response maps exact amendment to acceptWithExecpolicyAmendment" {
  run run_plan_invoke_codex_app_server_map_decision "$(command_request_json)" amendment
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.native')" = "acceptWithExecpolicyAmendment" ]
  [ "$(printf '%s' "$output" | jq -r '.response.result.decision.acceptWithExecpolicyAmendment.execpolicy_amendment | join(" ")')" = "ls -la src" ]
}

@test "codex approval response maps network exact amendment to applyNetworkPolicyAmendment" {
  run run_plan_invoke_codex_app_server_map_decision "$(network_request_json)" exact
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.native')" = "applyNetworkPolicyAmendment" ]
  [ "$(printf '%s' "$output" | jq -r '.response.result.decision.applyNetworkPolicyAmendment.network_policy_amendment.host')" = "example.com" ]
  [ "$(printf '%s' "$output" | jq -r '.response.result.decision.applyNetworkPolicyAmendment.network_policy_amendment.action')" = "allow" ]
}

@test "codex approval response maps permissions once to the requested subset" {
  run run_plan_invoke_codex_app_server_map_decision "$(permissions_request_json)" once
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.native')" = "grant-subset" ]
  [ "$(printf '%s' "$output" | jq -r '.response.result.scope')" = "turn" ]
  [ "$(printf '%s' "$output" | jq -c '.response.result.permissions.fileSystem.write')" = '["/tmp/ws/src","/tmp/ws/shared"]' ]
}

@test "codex approval response maps permissions session without broadening the grant" {
  local subset='{"permissions":{"fileSystem":{"write":["/tmp/ws/src"]}}}'
  run run_plan_invoke_codex_app_server_map_decision "$(permissions_request_json)" session "$subset"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.response.result.scope')" = "session" ]
  [ "$(printf '%s' "$output" | jq -c '.response.result.permissions.fileSystem.write')" = '["/tmp/ws/src"]' ]
}

@test "codex approval response falls back when exact amendment is not advertised" {
  run run_plan_invoke_codex_app_server_map_decision "$(file_request_json)" amendment
  [ "$status" -eq 2 ]
  [ "$(printf '%s' "$output" | jq -r '.fallback')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.path')" = "overlay" ]
}

@test "codex approval response falls back when app-server is unsupported" {
  write_codex_app_server_help_stub missing
  run run_plan_invoke_codex_app_server_start_or_fallback "$BIN_DIR/codex"
  [ "$status" -eq 2 ]
  [ "$(printf '%s' "$output" | jq -r '.fallback')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.reason')" = "unsupported" ]
  [ "$(printf '%s' "$output" | jq -r '.path')" = "overlay" ]
}

@test "codex approval response keeps the fake server alive while waiting" {
  local request_file="$TEST_TMPDIR/command-request.json"
  local record_file="$TEST_TMPDIR/responses.jsonl"
  local waiting="$TEST_TMPDIR/waiting"
  local session session_dir pid
  command_request_json >"$request_file"
  session="$(start_codex_wait_session "$request_file" "$record_file" "$waiting")"
  session_dir="$(printf '%s' "$session" | jq -r '.sessionDir')"
  pid="$(printf '%s' "$session" | jq -r '.pid')"
  [ -f "$waiting" ]
  run run_plan_invoke_codex_app_server_session_alive "$session_dir"
  [ "$status" -eq 0 ]
  sleep 0.3
  run run_plan_invoke_codex_app_server_session_alive "$session_dir"
  [ "$status" -eq 0 ]
  kill -0 "$pid"
  [ ! -s "$record_file" ]
  run_plan_invoke_codex_app_server_close "$session_dir" supervisor >/dev/null
}

@test "codex approval response sends once and waits for serverRequest/resolved" {
  local request_file="$TEST_TMPDIR/command-request.json"
  local record_file="$TEST_TMPDIR/responses.jsonl"
  local session session_dir
  command_request_json >"$request_file"
  session="$(start_codex_wait_session "$request_file" "$record_file")"
  session_dir="$(printf '%s' "$session" | jq -r '.sessionDir')"
  run run_plan_invoke_codex_app_server_respond "$session_dir" once
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.native')" = "accept" ]
  [ "$(printf '%s' "$output" | jq -r '.duplicate')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.resolved')" = "true" ]
  [ "$(jq -s 'length' "$record_file")" -eq 1 ]
  [ "$(jq -r '.result.decision' "$record_file")" = "accept" ]
  [ -f "$session_dir/resolved.json" ]
  [ "$(jq -r '.method' "$session_dir/resolved.json")" = "serverRequest/resolved" ]
  run_plan_invoke_codex_app_server_close "$session_dir" completion >/dev/null
}

@test "codex approval response handles duplicate resolution" {
  local request_file="$TEST_TMPDIR/command-request.json"
  local record_file="$TEST_TMPDIR/responses.jsonl"
  local session session_dir
  command_request_json >"$request_file"
  session="$(start_codex_wait_session "$request_file" "$record_file")"
  session_dir="$(printf '%s' "$session" | jq -r '.sessionDir')"
  run run_plan_invoke_codex_app_server_respond "$session_dir" session
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.native')" = "acceptForSession" ]
  run run_plan_invoke_codex_app_server_respond "$session_dir" deny
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.duplicate')" = "true" ]
  [ "$(jq -s 'length' "$record_file")" -eq 1 ]
  [ "$(jq -r '.result.decision' "$record_file")" = "acceptForSession" ]
  run_plan_invoke_codex_app_server_close "$session_dir" completion >/dev/null
}

@test "codex approval response treats a prior serverRequest/resolved as duplicate" {
  local request_file="$TEST_TMPDIR/command-request.json"
  local record_file="$TEST_TMPDIR/responses.jsonl"
  local session session_dir
  command_request_json >"$request_file"
  session="$(start_codex_wait_session "$request_file" "$record_file" "" immediate)"
  session_dir="$(printf '%s' "$session" | jq -r '.sessionDir')"
  local start="$SECONDS"
  while (( SECONDS - start < 3 )); do
    [[ "$(cat "$session_dir/state" 2>/dev/null || true)" == "resolved" ]] && break
    sleep 0.05
  done
  [ "$(cat "$session_dir/state")" = "resolved" ]
  run run_plan_invoke_codex_app_server_respond "$session_dir" once
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.duplicate')" = "true" ]
  [ ! -s "$record_file" ]
  run_plan_invoke_codex_app_server_close "$session_dir" completion >/dev/null
}

@test "codex approval response closes on completion" {
  local request_file="$TEST_TMPDIR/command-request.json"
  local record_file="$TEST_TMPDIR/responses.jsonl"
  local session session_dir pid
  command_request_json >"$request_file"
  session="$(start_codex_wait_session "$request_file" "$record_file")"
  session_dir="$(printf '%s' "$session" | jq -r '.sessionDir')"
  pid="$(printf '%s' "$session" | jq -r '.pid')"
  run_plan_invoke_codex_app_server_respond "$session_dir" deny >/dev/null
  run run_plan_invoke_codex_app_server_close "$session_dir" completion
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.closed')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.reason')" = "completion" ]
  ! kill -0 "$pid" 2>/dev/null
  run run_plan_invoke_codex_app_server_session_alive "$session_dir"
  [ "$status" -ne 0 ]
}

@test "codex approval response closes on cancellation" {
  local request_file="$TEST_TMPDIR/command-request.json"
  local record_file="$TEST_TMPDIR/responses.jsonl"
  local session session_dir pid
  command_request_json >"$request_file"
  session="$(start_codex_wait_session "$request_file" "$record_file")"
  session_dir="$(printf '%s' "$session" | jq -r '.sessionDir')"
  pid="$(printf '%s' "$session" | jq -r '.pid')"
  run run_plan_invoke_codex_app_server_close "$session_dir" cancellation
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.reason')" = "cancellation" ]
  ! kill -0 "$pid" 2>/dev/null
  if [[ -s "$record_file" ]]; then
    [ "$(jq -r '.result.decision' "$record_file")" = "cancel" ]
  fi
}

@test "codex approval response closes on supervisor cleanup" {
  local request_file="$TEST_TMPDIR/command-request.json"
  local record_file="$TEST_TMPDIR/responses.jsonl"
  local session session_dir pid
  command_request_json >"$request_file"
  session="$(start_codex_wait_session "$request_file" "$record_file")"
  session_dir="$(printf '%s' "$session" | jq -r '.sessionDir')"
  pid="$(printf '%s' "$session" | jq -r '.pid')"
  run run_plan_invoke_codex_app_server_cleanup
  [ "$status" -eq 0 ]
  ! kill -0 "$pid" 2>/dev/null
  [ "$(cat "$session_dir/state")" = "closed" ]
  [ "$(cat "$session_dir/close.reason")" = "supervisor" ]
}
