#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

POLICY_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-policy.sh"
RESULT_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-result.sh"
TOOLS_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-tools.sh"
REPO_MAP_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/repo-map.sh"
UPSTREAM_SCRIPT="$REPO_ROOT/bundle/.ralph/mcp-server.sh"
REPOMAP_FIXTURE="$REPO_ROOT/tests/fixtures/mcp-proxy/repomap"

load_proxy_repomap_libs() {
  # shellcheck source=/dev/null
  source "$POLICY_LIB"
  # shellcheck source=/dev/null
  source "$RESULT_LIB"
  # shellcheck source=/dev/null
  source "$TOOLS_LIB"
}

repomap_policy_json() {
  local repomap_enabled="${1:-1}"
  local max_files="${2:-500}"
  local enabled_bool="false"
  if [[ "$repomap_enabled" == "1" ]]; then
    enabled_bool="true"
  fi
  jq -nc \
    --argjson repoMapEnabled "$enabled_bool" \
    --argjson maxRepoMapFiles "$max_files" \
    '{
      name: "repomap-policy",
      proxyOwnedTools: {
        enabled: true,
        repoMapEnabled: $repoMapEnabled,
        maxRepoMapFiles: $maxRepoMapFiles
      },
      resultByteCap: 65536,
      toolResultByteCaps: {
        ralph_proxy_repomap: 65536
      }
    }'
}

invoke_proxy_repomap() {
  local policy_json="${1:-}"
  local args_json="${2:-}"
  local disable_tools="${3:-0}"
  local path_prefix=""
  if [[ "$disable_tools" == "1" ]]; then
    path_prefix="/usr/bin:/bin:/usr/sbin:/sbin"
  fi
  env PATH="${path_prefix:+$path_prefix:}$PATH" \
    RALPH_MCP_PROXY_POLICY_INLINE="$policy_json" \
    RALPH_MCP_PROXY_OWNED_TOOLS_FORCE=1 \
    RALPH_MCP_PROXY_RUNTIME=claude \
    RALPH_PLAN_WORKSPACE_ROOT="$WS/.ralph-workspace" \
    bash -c '
      source "$1"
      source "$2"
      source "$3"
      ralph_mcp_proxy_load_policy "$4" "$5" || exit 1
      ralph_mcp_proxy_call_owned_tool "$6" "ralph_proxy_repomap" "$7"
    ' _ "$POLICY_LIB" "$RESULT_LIB" "$TOOLS_LIB" "$REPO_ROOT" "$UPSTREAM_SCRIPT" "$WS" "$args_json" 2>/dev/null
}

proxy_repomap_result_text() {
  local response="${1:-}"
  printf '%s\n' "$response" | jq -r '
    if ((.content[0].text | type) == "string" and (.content[0].text | startswith("{"))) then
      (.content[0].text | fromjson | .preview // .content[0].text)
    else
      .content[0].text
    end
  '
}

repomap_contains_symbols() {
  local text="${1:-}"
  [[ "$text" == *"AlphaClass"* ]]
  [[ "$text" == *"alpha_fn"* ]]
  [[ "$text" == *"betaFn"* ]]
  [[ "$text" == *"util_fn"* ]]
}

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  WS="$TEST_TMPDIR/workspace"
  mkdir -p "$WS/.ralph-workspace"
  cp -R "$REPOMAP_FIXTURE/." "$WS/"
  export RALPH_MCP_WORKSPACE="$WS"
  export RALPH_MCP_EXPLORATION_RESULT_COMPACT=1
  export RALPH_PLAN_WORKSPACE_ROOT="$WS/.ralph-workspace"
  export RALPH_PLAN_KEY="plan55-proxy-repomap"
  export RALPH_COMPACTORS_LIB_DIR="$REPO_ROOT/bundle/.ralph/bash-lib"
  load_proxy_repomap_libs
}

teardown() {
  if [[ -e "$TEST_TMPDIR" ]]; then
    rm -rf "$TEST_TMPDIR"
  fi
}

@test "ralph_proxy_repomap is absent from owned tools when repoMapEnabled is false" {
  command -v jq >/dev/null || skip "jq required"
  local policy tools_json
  policy="$(repomap_policy_json 0)"
  tools_json="$(env RALPH_MCP_PROXY_POLICY_INLINE="$policy" \
    RALPH_MCP_PROXY_OWNED_TOOLS_FORCE=1 \
    RALPH_MCP_PROXY_RUNTIME=claude \
    bash -c '
      source "$1"
      source "$2"
      source "$3"
      ralph_mcp_proxy_load_policy "$4" "$5" || exit 1
      ralph_mcp_proxy_owned_tools_json
    ' _ "$POLICY_LIB" "$RESULT_LIB" "$TOOLS_LIB" "$REPO_ROOT" "$UPSTREAM_SCRIPT" 2>/dev/null)"
  printf '%s\n' "$tools_json" | jq -e 'map(.name) | index("ralph_proxy_repomap") == null'
}

@test "ralph_proxy_repomap appears in owned tools when repoMapEnabled is true" {
  command -v jq >/dev/null || skip "jq required"
  local policy tools_json
  policy="$(repomap_policy_json 1)"
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
  printf '%s\n' "$tools_json" | jq -e 'map(.name) | index("ralph_proxy_repomap") != null'
}

@test "ralph_proxy_repomap is independent from searchEnabled" {
  command -v jq >/dev/null || skip "jq required"
  local policy tools_json
  policy="$(jq -nc '{
    name: "repomap-only",
    proxyOwnedTools: {
      enabled: true,
      searchEnabled: false,
      repoMapEnabled: true
    }
  }')"
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
  printf '%s\n' "$tools_json" | jq -e '
    (map(.name) | index("ralph_proxy_repomap")) != null
    and (map(.name) | index("ralph_proxy_search")) == null
  '
}

@test "ralph_proxy_repomap includes key symbols with full toolchain" {
  command -v jq >/dev/null || skip "jq required"
  local policy response text
  policy="$(repomap_policy_json 1)"
  response="$(invoke_proxy_repomap "$policy" '{}' 0)"
  text="$(proxy_repomap_result_text "$response")"
  repomap_contains_symbols "$text"
}

@test "ralph_proxy_repomap fallback parity without ctags and rg on PATH" {
  command -v jq >/dev/null || skip "jq required"
  local policy response text
  policy="$(repomap_policy_json 1)"
  response="$(invoke_proxy_repomap "$policy" '{}' 1)"
  text="$(proxy_repomap_result_text "$response")"
  repomap_contains_symbols "$text"
}

@test "repo-map library fallback parity without ctags and rg on PATH" {
  local text
  text="$(env PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    RALPH_PLAN_WORKSPACE_ROOT="$WS/.ralph-workspace" \
    bash -c '
      source "$1"
      ralph_repo_map_emit_digest "$2" "." 0
    ' _ "$REPO_MAP_LIB" "$WS")"
  repomap_contains_symbols "$text"
}

@test "ralph_proxy_repomap returns envelope compatible with result follow-up tools" {
  command -v jq >/dev/null || skip "jq required"
  local policy response
  policy="$(jq -nc '{
    name: "repomap-envelope",
    proxyOwnedTools: {
      enabled: true,
      repoMapEnabled: true,
      maxRepoMapFiles: 500
    },
    resultByteCap: 64,
    toolResultByteCaps: {
      ralph_proxy_repomap: 64
    }
  }')"
  response="$(invoke_proxy_repomap "$policy" '{}' 0)"
  printf '%s\n' "$response" | jq -e '
    .isError == false
    and (.content[0].text | fromjson | .truncated) == true
    and (.content[0].text | fromjson | .preview | test("AlphaClass|alpha_fn|betaFn|util_fn"))
    and (.content[0].text | fromjson | .resultId | test("^[a-f0-9]{16}$"))
    and (.content[0].text | fromjson | .nextActions | map(.tool) | index("ralph_proxy_result_read")) != null
    and (.content[0].text | fromjson | .nextActions | map(.tool) | index("ralph_proxy_result_summary")) != null
  '
}

@test "ralph_proxy_repomap rejects calls when repoMapEnabled is false" {
  command -v jq >/dev/null || skip "jq required"
  local policy response
  policy="$(repomap_policy_json 0)"
  response="$(invoke_proxy_repomap "$policy" '{}' 0)"
  printf '%s\n' "$response" | jq -e '
    .isError == true
    and (.content[0].text | test("repoMapEnabled"))
  '
}

@test "repo-map cache rebuilds on source file staleness" {
  command -v jq >/dev/null || skip "jq required"
  local policy first_meta second_meta
  policy="$(repomap_policy_json 1)"
  invoke_proxy_repomap "$policy" '{}' 0 >/dev/null
  first_meta="$(ralph_repo_map_cache_meta_json "$WS" ".")"
  printf '%s\n' "$first_meta" | jq -e '.rebuilt == true'

  printf '\nclass StaleMarker:\n    pass\n' >>"$WS/src/alpha.py"
  invoke_proxy_repomap "$policy" '{}' 0 >/dev/null
  second_meta="$(ralph_repo_map_cache_meta_json "$WS" ".")"
  printf '%s\n' "$second_meta" | jq -e '.rebuilt == true'

  local digest
  digest="$(cat "$WS/.ralph-workspace/repo-map"/*/digest.txt)"
  [[ "$digest" == *"StaleMarker"* ]]
}

@test "policy validation accepts repomap policy fields" {
  command -v jq >/dev/null || skip "jq required"
  run bash -c '
    source "$1"
    ralph_mcp_proxy_policy_validate_json "$2" "repomap-fields"
  ' _ "$POLICY_LIB" "$(repomap_policy_json 1 250)"
  [ "$status" -eq 0 ]
}

@test "policy validation rejects malformed repomap policy fields" {
  command -v jq >/dev/null || skip "jq required"
  run bash -c '
    source "$1"
    ralph_mcp_proxy_policy_validate_json "$2" "bad-repomap"
  ' _ "$POLICY_LIB" '{"name":"bad-repomap","proxyOwnedTools":{"repoMapEnabled":"yes"}}'
  [ "$status" -eq 1 ]
  run bash -c '
    source "$1"
    ralph_mcp_proxy_policy_validate_json "$2" "bad-repomap-files"
  ' _ "$POLICY_LIB" '{"name":"bad-repomap","proxyOwnedTools":{"maxRepoMapFiles":"many"}}'
  [ "$status" -eq 1 ]
}
