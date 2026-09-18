#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

SERVER_SCRIPT="$REPO_ROOT/bundle/.ralph/mcp-server.sh"

setup() {
  command -v jq >/dev/null || skip "jq required"
  command -v python3 >/dev/null || skip "python3 required"
  TEST_TMPDIR="$(mktemp -d)"
  XDG_HOME="$TEST_TMPDIR/config"
  mkdir -p "$XDG_HOME/ralph/dashboard" "$TEST_TMPDIR/workspace"
  export XDG_CONFIG_HOME="$XDG_HOME"
  export RALPH_MCP_WORKSPACE="$TEST_TMPDIR/workspace"
  export RALPH_MODE=ralph
  unset RALPH_MCP_DASHBOARD_DETECTION_DISABLED RALPH_MCP_DASHBOARD_DISABLED
}

teardown() {
  if [[ -n "${DASHBOARD_PID:-}" ]]; then
    kill "$DASHBOARD_PID" 2>/dev/null || true
    wait "$DASHBOARD_PID" 2>/dev/null || true
  fi
  rm -rf "$TEST_TMPDIR"
}

write_endpoint() {
  local host="$1" port="$2" pid="$3"
  jq -nc --arg host "$host" --arg port "$port" --arg pid "$pid" \
    '{host:$host,port:($port|tonumber),pid:($pid|tonumber),startedAt:"2026-09-17T00:00:00Z"}' \
    >"$XDG_HOME/ralph/dashboard/endpoint.json"
}

reset_detection_cache() {
  RALPH_MCP_DASHBOARD_ENDPOINT_CHECKED=0
  RALPH_MCP_DASHBOARD_ENDPOINT_AVAILABLE=0
  TOOL_LIST_RESULT=""
}

assert_no_dashboard_tools() {
  reset_detection_cache
  ! ensure_dashboard_mcp_endpoint_detection
  result="$(get_tool_list_result)"
  [[ "$(jq '[.tools[] | select(.name | startswith("ralph_dashboard_"))] | length' <<<"$result")" == "0" ]]
}

@test "dashboard detection rejects invalid endpoints and advertises only read-only live tools" {
  # Source once: starting the full MCP JSON-RPC server for each tiny fixture
  # made this focused test take ~19 seconds. The catalog helper is the same
  # tools/list implementation and its cache is reset between independent cases.
  source "$SERVER_SCRIPT"

  assert_no_dashboard_tools # missing endpoint
  printf '%s\n' '{not-json' >"$XDG_HOME/ralph/dashboard/endpoint.json"
  assert_no_dashboard_tools # malformed JSON
  write_endpoint 127.0.0.1 18273 999999
  assert_no_dashboard_tools # dead pid
  write_endpoint 127.0.0.1 18273 "$BASHPID"
  assert_no_dashboard_tools # unreachable server
  write_endpoint 192.0.2.1 18273 "$BASHPID"
  assert_no_dashboard_tools # non-loopback host

  # The test sandbox does not permit binding a listening socket. Stub only the
  # optional socket probe; the endpoint still has a live PID and loopback data.
  mkdir -p "$TEST_TMPDIR/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$TEST_TMPDIR/bin/python3"
  chmod +x "$TEST_TMPDIR/bin/python3"
  PATH="$TEST_TMPDIR/bin:$PATH"
  write_endpoint 127.0.0.1 12345 "$BASHPID"
  reset_detection_cache
  ensure_dashboard_mcp_endpoint_detection
  result="$(get_tool_list_result)"
  jq -e '
    ([.tools[] | select(.name | startswith("ralph_dashboard_")) | .name] | sort)
      == ["ralph_dashboard_list_runs", "ralph_dashboard_plan_status", "ralph_dashboard_read_artifact", "ralph_dashboard_run_status"]
    and ([.tools[] | select(.name | startswith("ralph_dashboard_")) | .name
      | test("resume|reset|approve|start|stop|cancel"; "i")] | any | not)
  ' <<<"$result"

  RALPH_MCP_DASHBOARD_DETECTION_DISABLED=1
  reset_detection_cache
  ! ensure_dashboard_mcp_endpoint_detection
}
