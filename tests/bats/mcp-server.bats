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

@test "plan status rejects plan paths outside the workspace" {
  local payload=$'{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ralph_plan_status","arguments":{"workspace":".","plan_path":"../PLAN.md"}}}\n{"jsonrpc":"2.0","id":2,"method":"exit"}\n'
  run_mcp_server_with_payload "$payload"
  [ "$status" -eq 0 ]
  local first_line
  first_line="$(json_response_line 0)"
  printf '%s\n' "$first_line" | jq -e '.error.message | test("plan path invalid or outside workspace")'
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
