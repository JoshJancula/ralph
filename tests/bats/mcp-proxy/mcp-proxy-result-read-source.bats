#!/usr/bin/env bats

# Regression: ralph_proxy_result_read must surface the source tool that produced
# a stored result in its readback envelope. Without this, a misremembered/stale
# resultId (e.g. a grep result re-read while expecting file content) gives no
# signal that it is the wrong artifact, causing wasted re-read round-trips.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

POLICY_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-policy.sh"
RESULT_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-result.sh"
TOOLS_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-tools.sh"
UPSTREAM_SCRIPT="$REPO_ROOT/bundle/.ralph/mcp-server.sh"

setup() {
  bats_skip_known_ci_flakes
  command -v jq >/dev/null || skip "jq required"
  TEST_TMPDIR="$(mktemp -d)"
  WS="$TEST_TMPDIR/workspace"
  mkdir -p "$WS"
  export RALPH_MCP_WORKSPACE="$WS"
  export RALPH_PLAN_KEY="plan-result-read-source"
  unset RALPH_PLAN_WORKSPACE_ROOT
  export RALPH_COMPACTORS_LIB_DIR="$REPO_ROOT/.ralph/bash-lib"
  # shellcheck source=/dev/null
  source "$POLICY_LIB"
  # shellcheck source=/dev/null
  source "$RESULT_LIB"
  # shellcheck source=/dev/null
  source "$TOOLS_LIB"
}

teardown() {
  [[ -n "${TEST_TMPDIR:-}" ]] && rm -rf "$TEST_TMPDIR"
}

invoke_result_read() {
  local policy_json="$1" args_json="$2"
  env \
    RALPH_MCP_PROXY_POLICY_INLINE="$policy_json" \
    RALPH_MCP_PROXY_OWNED_TOOLS_FORCE=1 \
    RALPH_MCP_PROXY_RUNTIME=claude \
    RALPH_HOOK_RESULT_BYTE_CAP=16384 \
    RALPH_MCP_WORKSPACE="$WS" \
    RALPH_PLAN_KEY="$RALPH_PLAN_KEY" \
    bash -c '
      source "$1"; source "$2"; source "$3"
      ralph_mcp_proxy_load_policy "$4" "$5" || exit 1
      ralph_mcp_proxy_call_owned_tool "$6" "ralph_proxy_result_read" "$7"
    ' _ "$POLICY_LIB" "$RESULT_LIB" "$TOOLS_LIB" "$REPO_ROOT" "$UPSTREAM_SCRIPT" "$WS" "$args_json" 2>/dev/null
}

policy_json() {
  jq -nc '{name: "src-policy", proxyOwnedTools: {enabled: true, searchEnabled: false}}'
}

make_big_result() {
  # Emit > 20000 bytes of deterministic content (one interface per line).
  local i
  for i in $(seq 1 1000); do
    printf 'export interface Thing%04d {}\n' "$i"
  done
}

@test "result_read capped envelope surfaces the source tool" {
  local big result_id policy args response source_val
  # A byte range that exceeds the result_read cap (16384) forces the capped
  # envelope, which is exactly where a stale/misremembered resultId is re-read.
  big="$(make_big_result)"
  result_id="$(ralph_mcp_proxy_result_store_write "$WS" "$RALPH_PLAN_KEY" "$big" "ralph_proxy_grep")"
  [[ -n "$result_id" ]]
  policy="$(policy_json)"
  args="$(jq -nc --arg id "$result_id" '{resultId: $id, view: "raw", byteStart: 0, byteEnd: 20000}')"
  response="$(invoke_result_read "$policy" "$args")"

  printf '%s\n' "$response" | jq -e '.isError != true'
  source_val="$(printf '%s\n' "$response" | jq -r '.content[0].text | fromjson | .source // empty')"
  [[ "$source_val" == "ralph_proxy_grep" ]]
}

@test "result_read envelope omits source when origin tool is unknown" {
  local big result_id policy args response has_source
  big="$(make_big_result)"
  # Store without a tool label; source must not be fabricated.
  result_id="$(ralph_mcp_proxy_result_store_write "$WS" "$RALPH_PLAN_KEY" "$big" "")"
  [[ -n "$result_id" ]]
  policy="$(policy_json)"
  args="$(jq -nc --arg id "$result_id" '{resultId: $id, view: "raw", byteStart: 0, byteEnd: 20000}')"
  response="$(invoke_result_read "$policy" "$args")"

  printf '%s\n' "$response" | jq -e '.isError != true'
  has_source="$(printf '%s\n' "$response" | jq -r '.content[0].text | fromjson | has("source")')"
  [[ "$has_source" == "false" ]]
}
