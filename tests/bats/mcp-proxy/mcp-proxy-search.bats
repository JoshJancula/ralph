#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

POLICY_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-policy.sh"
RESULT_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-result.sh"
TOOLS_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-tools.sh"
UPSTREAM_SCRIPT="$REPO_ROOT/bundle/.ralph/mcp-server.sh"
SEARCH_FIXTURE="$REPO_ROOT/tests/fixtures/mcp-proxy/search-ranking"

load_proxy_search_libs() {
  # shellcheck source=/dev/null
  source "$POLICY_LIB"
  # shellcheck source=/dev/null
  source "$RESULT_LIB"
  # shellcheck source=/dev/null
  source "$TOOLS_LIB"
}

search_policy_json() {
  local search_enabled="${1:-1}"
  local max_candidates="${2:-500}"
  local max_results="${3:-5}"
  local enabled_bool="false"
  if [[ "$search_enabled" == "1" ]]; then
    enabled_bool="true"
  fi
  jq -nc \
    --argjson searchEnabled "$enabled_bool" \
    --argjson maxSearchCandidates "$max_candidates" \
    --argjson maxSearchResults "$max_results" \
    '{
      name: "search-policy",
      proxyOwnedTools: {
        enabled: true,
        searchEnabled: $searchEnabled,
        maxSearchCandidates: $maxSearchCandidates,
        maxSearchResults: $maxSearchResults
      },
      resultByteCap: 65536,
      toolResultByteCaps: {
        ralph_proxy_search: 65536
      }
    }'
}

invoke_proxy_search() {
  local policy_json="${1:-}"
  local args_json="${2:-}"
  local disable_rg="${3:-0}"
  local path_prefix=""
  if [[ "$disable_rg" == "1" ]]; then
    path_prefix="/usr/bin:/bin:/usr/sbin:/sbin"
  fi
  env PATH="${path_prefix:+$path_prefix:}$PATH" \
    RALPH_MCP_PROXY_POLICY_INLINE="$policy_json" \
    RALPH_MCP_PROXY_OWNED_TOOLS_FORCE=1 \
    RALPH_MCP_PROXY_RUNTIME=claude \
    RALPH_PLAN_WORKSPACE_ROOT= \
    bash -c '
      source "$1"
      source "$2"
      source "$3"
      ralph_mcp_proxy_load_policy "$4" "$5" || exit 1
      ralph_mcp_proxy_call_owned_tool "$6" "ralph_proxy_search" "$7"
    ' _ "$POLICY_LIB" "$RESULT_LIB" "$TOOLS_LIB" "$REPO_ROOT" "$UPSTREAM_SCRIPT" "$WS" "$args_json" 2>/dev/null
}

proxy_search_result_text() {
  local response="${1:-}"
  printf '%s\n' "$response" | jq -r '
    if ((.content[0].text | type) == "string" and (.content[0].text | startswith("{"))) then
      (.content[0].text | fromjson | .preview // .content[0].text)
    else
      .content[0].text
    end
  '
}

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  WS="$TEST_TMPDIR/workspace"
  mkdir -p "$WS"
  cp -R "$SEARCH_FIXTURE/." "$WS/"
  unset RALPH_PLAN_WORKSPACE_ROOT
  export RALPH_MCP_WORKSPACE="$WS"
  export RALPH_PLAN_KEY="plan55-proxy-search"
  export RALPH_COMPACTORS_LIB_DIR="$REPO_ROOT/bundle/.ralph/bash-lib"
  load_proxy_search_libs
}

teardown() {
  if [[ -e "$TEST_TMPDIR" ]]; then
    rm -rf "$TEST_TMPDIR"
  fi
}

@test "compact tool catalog gate follows Ralph rollout defaults" {
  run env RALPH_MODE=no bash -c '
    source "$1"
    unset RALPH_MCP_COMPACT_TOOL_CATALOG
    ralph_mcp_proxy_compact_tool_catalog_active
  ' _ "$TOOLS_LIB"
  [ "$status" -ne 0 ]

  run env RALPH_MODE=ralph bash -c '
    source "$1"
    unset RALPH_MCP_COMPACT_TOOL_CATALOG
    ralph_mcp_proxy_compact_tool_catalog_active
  ' _ "$TOOLS_LIB"
  [ "$status" -eq 0 ]

  run env RALPH_MODE=no RALPH_MCP_COMPACT_TOOL_CATALOG=1 bash -c '
    source "$1"
    ralph_mcp_proxy_compact_tool_catalog_active
  ' _ "$TOOLS_LIB"
  [ "$status" -eq 0 ]

  run env RALPH_MODE=ralph RALPH_MCP_COMPACT_TOOL_CATALOG=0 bash -c '
    source "$1"
    ralph_mcp_proxy_compact_tool_catalog_active
  ' _ "$TOOLS_LIB"
  [ "$status" -ne 0 ]
}

@test "compact tool catalog rejects invalid boolean values" {
  run env RALPH_MODE=ralph RALPH_MCP_COMPACT_TOOL_CATALOG=maybe bash -c '
    source "$1"
    ralph_mcp_proxy_compact_tool_catalog_active
  ' _ "$TOOLS_LIB"
  [ "$status" -eq 2 ]
  [[ "$output" == *"RALPH_MCP_COMPACT_TOOL_CATALOG: invalid value"* ]]
}

@test "ralph_proxy_search is absent from owned tools when searchEnabled is false" {
  command -v jq >/dev/null || skip "jq required"
  local policy tools_json
  policy="$(search_policy_json 0)"
  env RALPH_MCP_COMPACT_TOOL_CATALOG=0 RALPH_MCP_PROXY_POLICY_INLINE="$policy" \
    RALPH_MCP_PROXY_OWNED_TOOLS_FORCE=1 \
    RALPH_MCP_PROXY_RUNTIME=claude \
    bash -c '
      source "$1"
      source "$2"
      source "$3"
      ralph_mcp_proxy_load_policy "$4" "$5" || exit 1
      ralph_mcp_proxy_owned_tools_json
    ' _ "$POLICY_LIB" "$RESULT_LIB" "$TOOLS_LIB" "$REPO_ROOT" "$UPSTREAM_SCRIPT"
  tools_json="$(env RALPH_MCP_COMPACT_TOOL_CATALOG=0 RALPH_MCP_PROXY_POLICY_INLINE="$policy" \
    RALPH_MCP_PROXY_OWNED_TOOLS_FORCE=1 \
    RALPH_MCP_PROXY_RUNTIME=claude \
    bash -c '
      source "$1"
      source "$2"
      source "$3"
      ralph_mcp_proxy_load_policy "$4" "$5" || exit 1
      ralph_mcp_proxy_owned_tools_json
    ' _ "$POLICY_LIB" "$RESULT_LIB" "$TOOLS_LIB" "$REPO_ROOT" "$UPSTREAM_SCRIPT" 2>/dev/null)"
  printf '%s\n' "$tools_json" | jq -e 'map(.name) | index("ralph_proxy_search") == null'
}

@test "ralph_proxy_search appears in owned tools when searchEnabled is true" {
  command -v jq >/dev/null || skip "jq required"
  local policy tools_json
  policy="$(search_policy_json 1)"
  tools_json="$(env RALPH_MCP_COMPACT_TOOL_CATALOG=0 RALPH_MCP_PROXY_POLICY_INLINE="$policy" \
    RALPH_MCP_PROXY_OWNED_TOOLS_FORCE=1 \
    RALPH_MCP_PROXY_RUNTIME=claude \
    bash -c '
      source "$1"
      source "$2"
      source "$3"
      ralph_mcp_proxy_load_policy "$4" "$5" || exit 1
      ralph_mcp_proxy_owned_tools_json
    ' _ "$POLICY_LIB" "$RESULT_LIB" "$TOOLS_LIB" "$REPO_ROOT" "$UPSTREAM_SCRIPT" 2>/dev/null)"
  printf '%s\n' "$tools_json" | jq -e 'map(.name) | index("ralph_proxy_search") != null'
}

@test "ralph_proxy_search returns envelope compatible with result follow-up tools" {
  command -v jq >/dev/null || skip "jq required"
  local policy response
  policy="$(jq -nc '{
    name: "search-envelope",
    proxyOwnedTools: {
      enabled: true,
      searchEnabled: true,
      maxSearchCandidates: 500,
      maxSearchResults: 1
    },
    resultByteCap: 65536,
    toolResultByteCaps: {
      ralph_proxy_search: 65536
    }
  }')"
  response="$(invoke_proxy_search "$policy" '{"query":"uniqueZebraHandler"}' 0)"
  payload="$(printf '%s\n' "$response" | jq -r '.content[0].text | fromjson')"
  printf '%s\n' "$response" | jq -e '.isError == false'
  printf '%s\n' "$payload" | jq -e '.truncated == true'
  printf '%s\n' "$payload" | jq -e '.preview | test("uniqueZebraHandler")'
  printf '%s\n' "$payload" | jq -e '.resultId | test("^[a-f0-9]{16}$")'
  printf '%s\n' "$payload" | jq -e '.breakpoints | map(select(.kind == "matchCluster")) | length >= 1'
  printf '%s\n' "$payload" | jq -e '.nextActions | map(.tool) | index("ralph_proxy_result_search") != null'
  printf '%s\n' "$payload" | jq -e '.nextActions | map(.tool) | index("ralph_proxy_result_read") != null'
}

@test "ralph_proxy_search rejects calls when searchEnabled is false" {
  command -v jq >/dev/null || skip "jq required"
  local policy response
  policy="$(search_policy_json 0)"
  response="$(invoke_proxy_search "$policy" '{"query":"uniqueZebraHandler"}' 0)"
  printf '%s\n' "$response" | jq -e '
    .isError == true
    and (.content[0].text | test("searchEnabled"))
  '
}

@test "policy validation accepts search policy fields" {
  command -v jq >/dev/null || skip "jq required"
  run bash -c '
    source "$1"
    ralph_mcp_proxy_policy_validate_json "$2" "search-fields"
  ' _ "$POLICY_LIB" "$(search_policy_json 1 250 25)"
  [ "$status" -eq 0 ]
}

@test "policy validation rejects malformed search policy fields" {
  command -v jq >/dev/null || skip "jq required"
  run bash -c '
    source "$1"
    ralph_mcp_proxy_policy_validate_json "$2" "bad-search"
  ' _ "$POLICY_LIB" '{"name":"bad-search","proxyOwnedTools":{"searchEnabled":"yes"}}'
  [ "$status" -eq 1 ]
  run bash -c '
    source "$1"
    ralph_mcp_proxy_policy_validate_json "$2" "bad-search-candidates"
  ' _ "$POLICY_LIB" '{"name":"bad-search","proxyOwnedTools":{"maxSearchCandidates":"many"}}'
  [ "$status" -eq 1 ]
}
