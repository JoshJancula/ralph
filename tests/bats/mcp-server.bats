#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

setup() {
  export RALPH_MCP_WORKSPACE="$REPO_ROOT"
}

teardown() {
  if [[ -n "${PLAN_STATUS_DIR:-}" ]]; then
    rm -rf "$PLAN_STATUS_DIR"
    PLAN_STATUS_DIR=""
  fi
}

run_mcp_server_with_payload() {
  local payload="$1"
  shift
  local env_command=(env "RALPH_MCP_WORKSPACE=$REPO_ROOT")
  if (( $# )); then
    env_command+=("$@")
  fi
  env_command+=("bash" "$REPO_ROOT/.ralph/mcp-server.sh")
  local stderr_log
  stderr_log="$(mktemp)"
  set +e
  output="$("${env_command[@]}" 2>"$stderr_log" <<< "$payload")"
  status=$?
  set -e
  rm -f "$stderr_log"
}

json_response_line() {
  local idx="$1"
  printf '%s\n' "$output" | jq -s --argjson idx "$idx" '.[$idx]'
}

@test "JSON-RPC tools/list request yields tool descriptions" {
  local payload=$'{"jsonrpc":"2.0","id":1,"method":"tools/list"}\n{"jsonrpc":"2.0","id":2,"method":"exit"}\n'
  run_mcp_server_with_payload "$payload"
  [ "$status" -eq 0 ]
  local first_line
  first_line="$(json_response_line 0)"
  printf '%s\n' "$first_line" | jq -e '.result.tools | length > 0'
}

@test "MCP tool-call rejects missing auth token when guard enabled" {
  local payload=$'{"jsonrpc":"2.0","id":1,"method":"tools/list"}\n{"jsonrpc":"2.0","id":2,"method":"exit"}\n'
  run_mcp_server_with_payload "$payload" "RALPH_MCP_AUTH_TOKEN=secret"
  [ "$status" -eq 0 ]
  local first_line
  first_line="$(json_response_line 0)"
  printf '%s\n' "$first_line" | jq -e '.error.code == -32001'
  printf '%s\n' "$first_line" | jq -e '.error.message == "unauthorized"'
}

@test "MCP tool-call succeeds when correct auth token provided" {
  local payload=$'{"jsonrpc":"2.0","id":1,"authToken":"secret","method":"tools/list"}\n{"jsonrpc":"2.0","id":2,"method":"exit"}\n'
  run_mcp_server_with_payload "$payload" "RALPH_MCP_AUTH_TOKEN=secret"
  [ "$status" -eq 0 ]
  local first_line
  first_line="$(json_response_line 0)"
  printf '%s\n' "$first_line" | jq -e '.result.tools | length > 0'
}

@test "plan status rejects plan paths outside the workspace" {
  local payload=$'{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ralph_plan_status","arguments":{"workspace":".","plan_path":"../PLAN.md"}}}\n{"jsonrpc":"2.0","id":2,"method":"exit"}\n'
  run_mcp_server_with_payload "$payload"
  [ "$status" -eq 0 ]
  local first_line
  first_line="$(json_response_line 0)"
  printf '%s\n' "$first_line" | jq -e '.error.message | test("plan path invalid")'
}

@test "plan status tool reports checkbox counts" {
  PLAN_STATUS_DIR="$(mktemp -d "$REPO_ROOT/tests/bats/plan-status.XXXX")"
  local plan_path="$PLAN_STATUS_DIR/PLAN.md"
  cat <<'EOF' > "$plan_path"
- [ ] todo
- [x] done
- [?] maybe later
EOF
  local plan_rel="${plan_path#$REPO_ROOT/}"
  local payload
  payload=$(cat <<EOF
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ralph_plan_status","arguments":{"workspace":".","plan_path":"$plan_rel"}}}
{"jsonrpc":"2.0","id":2,"method":"exit"}
EOF
)
  run_mcp_server_with_payload "$payload"
  [ "$status" -eq 0 ]
  local first_line
  first_line="$(json_response_line 0)"
  printf '%s\n' "$first_line" | jq -e '.result.structuredContent.total == 3'
  printf '%s\n' "$first_line" | jq -e '.result.structuredContent.completed == 1'
  printf '%s\n' "$first_line" | jq -e '.result.structuredContent.remaining == 1'
  printf '%s\n' "$first_line" | jq -e '.result.structuredContent.unknown == 1'
}

@test "initialize request yields default capabilities" {
  local payload=$'{"jsonrpc":"2.0","id":1,"method":"initialize"}\n{"jsonrpc":"2.0","id":2,"method":"exit"}\n'
  run_mcp_server_with_payload "$payload" "timeout" "5s"
  [ "$status" -eq 0 ]
  local first_line
  first_line="$(json_response_line 0)"
  printf '%s\n' "$first_line" | jq -e '.result.capabilities.tools.listChanged == false'
  printf '%s\n' "$first_line" | jq -e '.result.capabilities.resources.listChanged == false'
  printf '%s\n' "$first_line" | jq -e '.result.capabilities.prompts.listChanged == false'
}

@test "resources/list exposes the agent catalog" {
  local payload=$'{"jsonrpc":"2.0","id":1,"method":"resources/list"}\n{"jsonrpc":"2.0","id":2,"method":"exit"}\n'
  run_mcp_server_with_payload "$payload"
  [ "$status" -eq 0 ]
  local first_line
  first_line="$(json_response_line 0)"
  printf '%s\n' "$first_line" | jq -e '.result.resources[0].uri == "resource://ralph/agents"'
  printf '%s\n' "$first_line" | jq -e '.result.resources[0].mimeType == "text/markdown"'
}

@test "resources/read returns the agent catalog markdown" {
  local payload=$'{"jsonrpc":"2.0","id":1,"method":"resources/read","params":{"uri":"resource://ralph/agents"}}\n{"jsonrpc":"2.0","id":2,"method":"exit"}\n'
  run_mcp_server_with_payload "$payload"
  [ "$status" -eq 0 ]
  local first_line
  first_line="$(json_response_line 0)"
  printf '%s\n' "$first_line" | jq -e '.result.contents[0].mimeType == "text/markdown"'
  printf '%s\n' "$first_line" | jq -e '.result.contents[0].text | test("# Ralph agent catalog")'
  printf '%s\n' "$first_line" | jq -e '.result.contents[0].text | test("Cursor agents")'
}

@test "prompts/list advertises the next TODO prompt" {
  local payload=$'{"jsonrpc":"2.0","id":1,"method":"prompts/list"}\n{"jsonrpc":"2.0","id":2,"method":"exit"}\n'
  run_mcp_server_with_payload "$payload"
  [ "$status" -eq 0 ]
  local first_line
  first_line="$(json_response_line 0)"
  printf '%s\n' "$first_line" | jq -e '.result.prompts[0].name == "ralph_run_next_todo_prompt"'
  printf '%s\n' "$first_line" | jq -e '.result.prompts[0].arguments | map(select(.name == "plan_path")) | length == 1'
}

@test "prompts/get delivers guidance for the next unchecked TODO" {
  local prompt_dir
  prompt_dir="$(mktemp -d "$REPO_ROOT/tests/bats/next-todo.XXXX")"
  local plan_path="$prompt_dir/PLAN.md"
  cat <<'EOF' > "$plan_path"
- [ ] pick runtime
- [x] done
EOF
  local plan_rel="${plan_path#$REPO_ROOT/}"
  local payload
  payload=$(cat <<EOF
{"jsonrpc":"2.0","id":1,"method":"prompts/get","params":{"name":"ralph_run_next_todo_prompt","arguments":{"plan_path":"$plan_rel"}}}
{"jsonrpc":"2.0","id":2,"method":"exit"}
EOF
)
  run_mcp_server_with_payload "$payload"
  [ "$status" -eq 0 ]
  local first_line
  first_line="$(json_response_line 0)"
  printf '%s\n' "$first_line" | jq -e --arg term "ralph_plan_status" '.result.messages[0].content.text | contains($term)'
  printf '%s\n' "$first_line" | jq -e --arg term "resource://ralph/agents" '.result.messages[0].content.text | contains($term)'
  printf '%s\n' "$first_line" | jq -e --arg term "ralph_run_plan" '.result.messages[0].content.text | contains($term)'
  printf '%s\n' "$first_line" | jq -e --arg plan "$plan_rel" '.result.messages[0].content.text | contains($plan)'
  rm -rf "$prompt_dir"
}

@test "initialized notification does not produce a response" {
  local payload=$'{"jsonrpc":"2.0","id":1,"method":"initialized"}\n{"jsonrpc":"2.0","id":2,"method":"exit"}\n'
  run_mcp_server_with_payload "$payload" "timeout" "5s"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -s -e 'length == 1'
  local only_line
  only_line="$(json_response_line 0)"
  printf '%s\n' "$only_line" | jq -e '.result.status == "exiting"'
}

@test "shutdown request reports shutting_down status" {
  local payload=$'{"jsonrpc":"2.0","id":1,"method":"shutdown"}\n{"jsonrpc":"2.0","id":2,"method":"exit"}\n'
  run_mcp_server_with_payload "$payload" "timeout" "5s"
  [ "$status" -eq 0 ]
  local shutdown_line
  shutdown_line="$(json_response_line 0)"
  printf '%s\n' "$shutdown_line" | jq -e '.result.status == "shutting_down"'
  local exit_line
  exit_line="$(json_response_line 1)"
  printf '%s\n' "$exit_line" | jq -e '.result.status == "exiting"'
}

@test "exit request returns exiting status" {
  local payload=$'{"jsonrpc":"2.0","id":1,"method":"exit"}\n'
  run_mcp_server_with_payload "$payload" "timeout" "5s"
  [ "$status" -eq 0 ]
  local first_line
  first_line="$(json_response_line 0)"
  printf '%s\n' "$first_line" | jq -e '.result.status == "exiting"'
}

@test "unhandled JSON-RPC methods return method not found errors" {
  local payload=$'{"jsonrpc":"2.0","id":1,"method":"not-real"}\n{"jsonrpc":"2.0","id":2,"method":"exit"}\n'
  run_mcp_server_with_payload "$payload" "timeout" "5s"
  [ "$status" -eq 0 ]
  local error_line
  error_line="$(json_response_line 0)"
  printf '%s\n' "$error_line" | jq -e '.error.message | test("method not found: not-real")'
}

@test "ralph_run_plan tool executes a workspace runner script" {
  local workspace
  workspace="$(mktemp -d "$REPO_ROOT/tests/bats/mcp-run-plan-fixture-XXXX")"
  mkdir -p "$workspace/.ralph"
  cat <<'EOF' > "$workspace/.ralph/run-plan.sh"
#!/usr/bin/env bash
printf 'runner-output\n'
printf 'runner-error\n' >&2
EOF
  chmod +x "$workspace/.ralph/run-plan.sh"
  printf 'todo plan content\n' > "$workspace/PLAN.md"
  local payload
  payload=$(cat <<EOF
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ralph_run_plan","arguments":{"workspace":".","plan_path":"PLAN.md","runtime":"cursor","agent":"fixture-agent"}}}
{"jsonrpc":"2.0","id":2,"method":"exit"}
EOF
)
  run_mcp_server_with_payload "$payload" "RALPH_MCP_WORKSPACE=$workspace" "timeout" "5s"
  [ "$status" -eq 0 ]
  local first_line
  first_line="$(json_response_line 0)"
  printf '%s\n' "$first_line" | jq -e '.result.structuredContent.exit_code == 0'
  printf '%s\n' "$first_line" | jq -e '.result.structuredContent.stdout_tail | test("runner-output")'
  printf '%s\n' "$first_line" | jq -e '.result.structuredContent.stderr_tail | test("runner-error")'
  printf '%s\n' "$first_line" | jq -e '.result.structuredContent.command | test("--runtime cursor")'
  rm -rf "$workspace"
}

@test "ralph_run_plan rejects unsupported runtime" {
  local workspace
  workspace="$(mktemp -d "$REPO_ROOT/tests/bats/mcp-run-plan-reject-XXXX")"
  mkdir -p "$workspace/.ralph"
  printf 'todo plan content\n' > "$workspace/PLAN.md"
  local payload
  payload=$(cat <<EOF
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ralph_run_plan","arguments":{"workspace":".","plan_path":"PLAN.md","runtime":"invalid_runtime","agent":"fixture-agent"}}}
EOF
)
  run_mcp_server_with_payload "$payload" "RALPH_MCP_WORKSPACE=$workspace" "timeout" "5s"
  [ "$status" -eq 0 ]
  local error_line
  error_line="$(json_response_line 0)"
  printf '%s\n' "$error_line" | jq -e '.error.message | test("unsupported runtime: invalid_runtime")'
  rm -rf "$workspace"
}

@test "ralph_orchestrator_run tool executes orchestrator script with dry run" {
  local workspace
  workspace="$(mktemp -d "$REPO_ROOT/tests/bats/mcp-orchestrator-fixture-XXXX")"
  mkdir -p "$workspace/.ralph"
  cat <<'EOF' > "$workspace/.ralph/orchestrator.sh"
#!/usr/bin/env bash
printf 'orchestrator running with %s\n' "$*"
if [[ "${ORCHESTRATOR_DRY_RUN:-}" == "1" ]]; then
  printf 'dry run mode\n'
fi
EOF
  chmod +x "$workspace/.ralph/orchestrator.sh"
  cat <<'EOF' > "$workspace/orchestration.json"
{"stages":[{"name":"alpha"},{"name":"beta"}]}
EOF
  local payload
  payload=$(cat <<EOF
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ralph_orchestrator_run","arguments":{"workspace":".","orchestration_path":"orchestration.json","dry_run":true}}}
{"jsonrpc":"2.0","id":2,"method":"exit"}
EOF
)
  run_mcp_server_with_payload "$payload" "RALPH_MCP_WORKSPACE=$workspace" "timeout" "5s"
  [ "$status" -eq 0 ]
  local first_line
  first_line="$(json_response_line 0)"
  printf '%s\n' "$first_line" | jq -e '.result.structuredContent.stage_count == 2'
  printf '%s\n' "$first_line" | jq -e '.result.structuredContent.dry_run == true'
  printf '%s\n' "$first_line" | jq -e '.result.structuredContent.stdout_tail | test("orchestrator running")'
  printf '%s\n' "$first_line" | jq -e '.result.structuredContent.stdout_tail | test("dry run mode")'
  rm -rf "$workspace"
}
