#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

POLICY_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-policy.sh"
RESULT_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-result.sh"
TOOLS_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-tools.sh"
UPSTREAM_SCRIPT="$REPO_ROOT/bundle/.ralph/mcp-server.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  WS="$TEST_TMPDIR/workspace"
  mkdir -p "$WS"
  export RALPH_MCP_WORKSPACE="$WS"
  export RALPH_PLAN_KEY="async-shell"
  POLICY_JSON='{"name":"async-shell","proxyOwnedTools":{"enabled":true,"allowAllCommands":true,"allowShellOperators":true,"shellTimeoutSeconds":2,"maxShellOutputBytes":1024},"resultByteCap":65536,"toolResultByteCaps":{"ralph_proxy_shell":65536,"ralph_proxy_shell_start":65536,"ralph_proxy_shell_status":65536,"ralph_proxy_shell_read":65536,"ralph_proxy_shell_cancel":65536}}'
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

invoke_async_tool() {
  local tool_name="$1"
  local args_json="$2"
  env \
    RALPH_MCP_WORKSPACE="$WS" \
    RALPH_PLAN_KEY="$RALPH_PLAN_KEY" \
    RALPH_MCP_PROXY_POLICY_INLINE="$POLICY_JSON" \
    bash -c '
      source "$1"
      source "$2"
      source "$3"
      ralph_mcp_proxy_load_policy "$4" "$5" >/dev/null || exit 1
      ralph_mcp_proxy_call_owned_tool "$6" "$7" "$8"
    ' _ "$POLICY_LIB" "$RESULT_LIB" "$TOOLS_LIB" "$REPO_ROOT" "$UPSTREAM_SCRIPT" "$WS" "$tool_name" "$args_json"
}

extract_json_object() {
  python3 -c '
import sys
text = sys.stdin.read()
start = text.find("{")
if start == -1:
    sys.exit(1)
depth = 0
for idx in range(start, len(text)):
    ch = text[idx]
    if ch == "{":
        depth += 1
    elif ch == "}":
        depth -= 1
        if depth == 0:
            sys.stdout.write(text[start:idx+1])
            sys.exit(0)
sys.exit(1)
' || return 1
}

response_text() {
  printf '%s\n' "$1" | extract_json_object | jq -r '.content[0].text'
}

response_json_text() {
  printf '%s\n' "$1" | extract_json_object | jq -r '.content[0].text | fromjson'
}

wait_for_job_with_wait() {
  local job_id="$1"
  local wait_seconds="${2:-60}"
  invoke_async_tool \
    ralph_proxy_shell_wait \
    "$(jq -nc --arg jobId "$job_id" --argjson waitSeconds "$wait_seconds" '{jobId:$jobId,waitSeconds:$waitSeconds}')"
}

@test "async shell start returns immediately and status/read expose completed output" {
  command -v jq >/dev/null || skip "jq required"
  local start_response job_id status_response read_response

  start_response="$(invoke_async_tool ralph_proxy_shell_start "$(jq -nc --arg command 'printf start; sleep 1; printf done' '{command:$command}')")"
  printf '%s\n' "$start_response" | jq -e '.isError == false and (.content[0].text | fromjson | .status) == "running"'
  job_id="$(response_json_text "$start_response" | jq -r '.jobId')"

  status_response="$(wait_for_job_with_wait "$job_id")"
  printf '%s\n' "$status_response" | jq -e '
    .isError == false
    and (.content[0].text | fromjson | .status) == "passed"
    and (.content[0].text | fromjson | .resultId | test("^[a-f0-9]{16}$"))
    and ((.content[0].text | fromjson | has("waitTimedOut")) | not)
  '

  read_response="$(invoke_async_tool ralph_proxy_shell_read "$(jq -nc --arg jobId "$job_id" '{jobId:$jobId, stream:"combined"}')")"
  [ "$(response_text "$read_response")" = "startdone" ]
}

@test "async shell timeout records timed_out status" {
  command -v jq >/dev/null || skip "jq required"
  local start_response job_id status_response

  start_response="$(invoke_async_tool ralph_proxy_shell_start "$(jq -nc --arg command 'sleep 5' '{command:$command}')")"
  job_id="$(response_json_text "$start_response" | jq -r '.jobId')"

  status_response="$(wait_for_job_with_wait "$job_id" 1)"
  response_json="$(response_json_text "$status_response")"
  jq -n --argjson response "$response_json" '
    $response.waitTimedOut == true
    and $response.status == "running"
    and ($response.nextActions | map(.tool) | index("ralph_proxy_shell_wait") != null)
    and ($response.nextActions | map(.tool) | index("ralph_proxy_shell_read") != null)
  '
}

@test "async shell wait returns terminal payload when job already finished" {
  command -v jq >/dev/null || skip "jq required"
  local start_response job_id first_response second_response first_result_id

  start_response="$(invoke_async_tool ralph_proxy_shell_start "$(jq -nc --arg command 'printf done' '{command:$command}')")"
  job_id="$(response_json_text "$start_response" | jq -r '.jobId')"

  first_response="$(wait_for_job_with_wait "$job_id")"
  printf '%s\n' "$first_response" | jq -e '
    .isError == false
    and (.content[0].text | fromjson | .status) == "passed"
    and (.content[0].text | fromjson | has("waitTimedOut") | not)
  '
  first_result_id="$(response_json_text "$first_response" | jq -r '.resultId')"

  second_response="$(wait_for_job_with_wait "$job_id")"
  printf '%s\n' "$second_response" | jq -e '
    .isError == false
    and (.content[0].text | fromjson | .status) == "passed"
    and (.content[0].text | fromjson | has("waitTimedOut") | not)
    and (.content[0].text | fromjson | .resultId == "'"${first_result_id}"'")
  '
}

@test "async shell cancel terminates running job" {
  command -v jq >/dev/null || skip "jq required"
  local start_response job_id cancel_response

  start_response="$(invoke_async_tool ralph_proxy_shell_start "$(jq -nc --arg command 'sleep 30' '{command:$command}')")"
  job_id="$(response_json_text "$start_response" | jq -r '.jobId')"

  cancel_response="$(invoke_async_tool ralph_proxy_shell_cancel "$(jq -nc --arg jobId "$job_id" '{jobId:$jobId}')")"
  printf '%s\n' "$cancel_response" | jq -e '
    .isError == false
    and (.content[0].text | fromjson | .status) == "cancelled"
  '
}
