#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

POLICY_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-policy.sh"
RESULT_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-result.sh"
TOOLS_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-tools.sh"
UPSTREAM_SCRIPT="$REPO_ROOT/bundle/.ralph/mcp-server.sh"

load_proxy_batch_libs() {
  # shellcheck source=/dev/null
  source "$POLICY_LIB"
  # shellcheck source=/dev/null
  source "$RESULT_LIB"
  # shellcheck source=/dev/null
  source "$TOOLS_LIB"
}

batch_policy_json() {
  local search_enabled="${1:-0}"
  local enabled_bool="false"
  if [[ "$search_enabled" == "1" ]]; then
    enabled_bool="true"
  fi
  jq -nc \
    --argjson searchEnabled "$enabled_bool" \
    '{
      name: "batch-policy",
      proxyOwnedTools: {
        enabled: true,
        searchEnabled: $searchEnabled
      }
    }'
}

invoke_proxy_batch() {
  local policy_json="${1:-}"
  local args_json="${2:-}"
  local extra_env=()
  if [[ "$#" -ge 4 ]]; then
    extra_env+=("$3=$4")
  fi
  env "${extra_env[@]}" \
    RALPH_MCP_PROXY_POLICY_INLINE="$policy_json" \
    RALPH_MCP_PROXY_OWNED_TOOLS_FORCE=1 \
    RALPH_MCP_PROXY_RUNTIME=claude \
    bash -c '
      source "$1"
      source "$2"
      source "$3"
      ralph_mcp_proxy_load_policy "$4" "$5" || exit 1
      ralph_mcp_proxy_call_owned_tool "$6" "ralph_proxy_batch" "$7"
    ' _ "$POLICY_LIB" "$RESULT_LIB" "$TOOLS_LIB" "$REPO_ROOT" "$UPSTREAM_SCRIPT" "$WS" "$args_json" 2>/dev/null
}

batch_result_text() {
  local response="${1:-}"
  printf '%s\n' "$response" | jq -r '.content[0].text // empty'
}

setup() {
  bats_skip_known_ci_flakes
  TEST_TMPDIR="$(mktemp -d)"
  WS="$TEST_TMPDIR/workspace"
  mkdir -p "$WS"
  export RALPH_MCP_WORKSPACE="$WS"
  export RALPH_PLAN_KEY="plan-batch-proxy"
  unset RALPH_PLAN_WORKSPACE_ROOT
  export RALPH_COMPACTORS_LIB_DIR="$REPO_ROOT/.ralph/bash-lib"
  load_proxy_batch_libs
}

teardown() {
  if [[ -e "$TEST_TMPDIR" ]]; then
    rm -rf "$TEST_TMPDIR"
  fi
}

@test "ralph_proxy_batch runs mixed read grep and glob operations successfully" {
  command -v jq >/dev/null || skip "jq required"
  cp "$REPO_ROOT/tests/fixtures/mcp-proxy/grep-many-matches.txt" "$WS/batch-grep.txt"
  mkdir -p "$WS/batch-glob-dir"
  cp "$REPO_ROOT/tests/fixtures/mcp-proxy/glob-many-files/glob-fixture-01.txt" "$WS/batch-glob-dir/"
  printf 'batch-read-marker\n' >"$WS/batch-read.txt"

  local policy args_json response text
  policy="$(batch_policy_json 0)"
  args_json="$(jq -nc '{
    operations: [
      {tool: "ralph_proxy_read", arguments: {path: "batch-read.txt"}},
      {tool: "ralph_proxy_grep", arguments: {pattern: "grep-fixture-line-001", path: "batch-grep.txt"}},
      {tool: "ralph_proxy_glob", arguments: {glob_pattern: "glob-fixture-*.txt", target_directory: "batch-glob-dir"}}
    ]
  }')"
  response="$(invoke_proxy_batch "$policy" "$args_json")"
  text="$(batch_result_text "$response")"

  printf '%s\n' "$response" | jq -e '.isError == false'
  [[ "$text" == *"1. ralph_proxy_read: ok |"* ]]
  [[ "$text" == *"batch-read-marker"* ]]
  [[ "$text" == *"2. ralph_proxy_grep: ok |"* ]]
  [[ "$text" == *"grep-fixture-line-001"* ]]
  [[ "$text" == *"3. ralph_proxy_glob: ok |"* ]]
  [[ "$text" == *"glob-fixture-01.txt"* ]]
}

@test "ralph_proxy_batch result_read operation returns stored byte range" {
  command -v jq >/dev/null || skip "jq required"
  local content result_id policy args_json response text
  content="alpha-beta-gamma-delta"
  result_id="$(ralph_mcp_proxy_result_store_write "$WS" "$RALPH_PLAN_KEY" "$content" "ralph_proxy_grep")"
  policy="$(batch_policy_json 0)"
  args_json="$(jq -nc --arg id "$result_id" '{
    operations: [
      {tool: "ralph_proxy_result_read", arguments: {resultId: $id, byteStart: 6, byteEnd: 16}}
    ]
  }')"
  response="$(invoke_proxy_batch "$policy" "$args_json")"
  text="$(batch_result_text "$response")"

  printf '%s\n' "$response" | jq -e '.isError == false'
  [[ "$text" == *"1. ralph_proxy_result_read: ok | beta-gamma"* ]]
}

@test "ralph_proxy_batch result_reduce operation returns grep matches" {
  command -v jq >/dev/null || skip "jq required"
  command -v grep >/dev/null || skip "grep required"
  local content result_id policy args_json response text
  content=$'INFO: ok\nERROR: boom\nWARN: maybe\nERROR: again'
  result_id="$(ralph_mcp_proxy_result_store_write "$WS" "$RALPH_PLAN_KEY" "$content" "ralph_proxy_shell")"
  policy="$(batch_policy_json 0)"
  args_json="$(jq -nc --arg id "$result_id" '{
    operations: [
      {
        tool: "ralph_proxy_result_reduce",
        arguments: {resultId: $id, reducer: "grep", expression: "ERROR", lineNumber: true}
      }
    ]
  }')"
  response="$(invoke_proxy_batch "$policy" "$args_json" RALPH_MODE hybrid)"
  text="$(batch_result_text "$response")"

  printf '%s\n' "$response" | jq -e '.isError == false'
  [[ "$text" == *"1. ralph_proxy_result_reduce: ok |"* ]]
  [[ "$text" == *"ERROR: boom"* ]]
  [[ "$text" != *"INFO: ok"* ]]
}

@test "ralph_proxy_batch reports per-operation error when search is disabled" {
  command -v jq >/dev/null || skip "jq required"
  cp -R "$REPO_ROOT/tests/fixtures/mcp-proxy/search-ranking/." "$WS/search-fixture/"
  printf 'before-search\n' >"$WS/before-search.txt"
  printf 'after-search\n' >"$WS/after-search.txt"

  local policy args_json response text
  policy="$(batch_policy_json 0)"
  args_json="$(jq -nc '{
    operations: [
      {tool: "ralph_proxy_read", arguments: {path: "before-search.txt"}},
      {tool: "ralph_proxy_search", arguments: {query: "uniqueZebraHandler", path: "search-fixture"}},
      {tool: "ralph_proxy_read", arguments: {path: "after-search.txt"}}
    ]
  }')"
  response="$(invoke_proxy_batch "$policy" "$args_json")"
  text="$(batch_result_text "$response")"

  printf '%s\n' "$response" | jq -e '.isError == false'
  [[ "$text" == *"1. ralph_proxy_read: ok |"* ]]
  [[ "$text" == *"before-search"* ]]
  [[ "$text" == *"2. ralph_proxy_search: error | ralph_proxy_search is not enabled"* ]]
  [[ "$text" == *"3. ralph_proxy_read: ok |"* ]]
  [[ "$text" == *"after-search"* ]]
}

@test "ralph_proxy_batch rejects shell operations per operation" {
  command -v jq >/dev/null || skip "jq required"
  local policy args_json response text
  policy="$(batch_policy_json 0)"
  args_json="$(jq -nc '{
    operations: [
      {tool: "ralph_proxy_shell", arguments: {command: "pwd"}}
    ]
  }')"
  response="$(invoke_proxy_batch "$policy" "$args_json")"
  text="$(batch_result_text "$response")"

  printf '%s\n' "$response" | jq -e '.isError == false'
  [[ "$text" == *"1. ralph_proxy_shell: error | operation tool not allowed in batch"* ]]
}

@test "ralph_proxy_batch rejects unknown operations per operation" {
  command -v jq >/dev/null || skip "jq required"
  local policy args_json response text
  policy="$(batch_policy_json 0)"
  args_json="$(jq -nc '{
    operations: [
      {tool: "ralph_proxy_write", arguments: {path: "x.txt", contents: "nope"}}
    ]
  }')"
  response="$(invoke_proxy_batch "$policy" "$args_json")"
  text="$(batch_result_text "$response")"

  printf '%s\n' "$response" | jq -e '.isError == false'
  [[ "$text" == *"1. ralph_proxy_write: error | operation tool not allowed in batch"* ]]
}

@test "ralph_proxy_batch enforces max operation count" {
  command -v jq >/dev/null || skip "jq required"
  local policy args_json response text
  policy="$(batch_policy_json 0)"
  args_json="$(jq -nc '
    {
      operations: [
        {tool: "ralph_proxy_read", arguments: {path: "missing-01.txt"}},
        {tool: "ralph_proxy_read", arguments: {path: "missing-02.txt"}},
        {tool: "ralph_proxy_read", arguments: {path: "missing-03.txt"}}
      ]
    }
  ')"
  response="$(invoke_proxy_batch "$policy" "$args_json" "RALPH_MCP_PROXY_BATCH_MAX_OPERATIONS" "2")"
  text="$(batch_result_text "$response")"

  printf '%s\n' "$response" | jq -e '.isError == true'
  [[ "$text" == *"too many operations (max 2)"* ]]
}

@test "ralph_proxy_batch continues after non-fatal path policy denial" {
  command -v jq >/dev/null || skip "jq required"
  printf 'recovered\n' >"$WS/recovered.txt"

  local policy args_json response text
  policy="$(batch_policy_json 0)"
  args_json="$(jq -nc '{
    operations: [
      {tool: "ralph_proxy_read", arguments: {path: "missing-batch.txt"}},
      {tool: "ralph_proxy_read", arguments: {path: "recovered.txt"}}
    ]
  }')"
  response="$(invoke_proxy_batch "$policy" "$args_json")"
  text="$(batch_result_text "$response")"

  printf '%s\n' "$response" | jq -e '.isError == false'
  [[ "$text" == *"1. ralph_proxy_read: error |"* ]]
  [[ "$text" == *"path does not exist"* ]]
  [[ "$text" == *"2. ralph_proxy_read: ok | recovered"* ]]
}

@test "ralph_proxy_batch stops on fatal path policy denial like single read tool" {
  command -v jq >/dev/null || skip "jq required"
  printf 'before-fatal\n' >"$WS/before-fatal.txt"
  printf 'after-fatal\n' >"$WS/after-fatal.txt"

  local policy args_json response text
  policy="$(batch_policy_json 0)"
  args_json="$(jq -nc '{
    operations: [
      {tool: "ralph_proxy_read", arguments: {path: "before-fatal.txt"}},
      {tool: "ralph_proxy_read", arguments: {path: "/etc/passwd"}},
      {tool: "ralph_proxy_read", arguments: {path: "after-fatal.txt"}}
    ]
  }')"
  response="$(invoke_proxy_batch "$policy" "$args_json")"
  text="$(batch_result_text "$response")"

  printf '%s\n' "$response" | jq -e '.isError == true'
  [[ "$text" == *"1. ralph_proxy_read: ok | before-fatal"* ]]
  [[ "$text" == *"2. ralph_proxy_read: error |"* ]]
  [[ "$text" == *"FATAL: ralph_proxy_read: path is outside the workspace"* ]]
  [[ "$text" != *"after-fatal"* ]]
}

@test "ralph_proxy_batch appears in owned tools json when owned proxy tools are active" {
  command -v jq >/dev/null || skip "jq required"
  local policy tools_json
  policy="$(batch_policy_json 0)"
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
  printf '%s\n' "$tools_json" | jq -e 'map(.name) | index("ralph_proxy_batch") != null'
}

@test "ralph_mcp_proxy_merge_owned_tools_into_list omits batch when owned proxy tools are inactive" {
  command -v jq >/dev/null || skip "jq required"
  local policy merged_json
  policy="$(batch_policy_json 0)"
  merged_json="$(env RALPH_MCP_PROXY_POLICY_INLINE="$policy" \
    RALPH_MCP_PROXY_OWNED_TOOLS_FORCE=0 \
    bash -c '
      source "$1"
      source "$2"
      source "$3"
      ralph_mcp_proxy_load_policy "$4" "$5" || exit 1
      ralph_mcp_proxy_merge_owned_tools_into_list "{\"result\":{\"tools\":[{\"name\":\"upstream_tool\"}]}}"
    ' _ "$POLICY_LIB" "$RESULT_LIB" "$TOOLS_LIB" "$REPO_ROOT" "$UPSTREAM_SCRIPT" 2>/dev/null)"
  printf '%s\n' "$merged_json" | jq -e '
    (.result.tools | map(.name) | index("ralph_proxy_batch")) == null
    and (.result.tools | map(.name) | index("ralph_proxy_read")) == null
    and (.result.tools | length) == 1
  '
}

@test "ralph_mcp_proxy_merge_owned_tools_into_list includes batch when owned proxy tools are active" {
  command -v jq >/dev/null || skip "jq required"
  local policy merged_json
  policy="$(batch_policy_json 0)"
  merged_json="$(env RALPH_MCP_PROXY_POLICY_INLINE="$policy" \
    RALPH_MCP_PROXY_OWNED_TOOLS_FORCE=1 \
    RALPH_MCP_PROXY_RUNTIME=claude \
    bash -c '
      source "$1"
      source "$2"
      source "$3"
      ralph_mcp_proxy_load_policy "$4" "$5" || exit 1
      ralph_mcp_proxy_merge_owned_tools_into_list "{\"result\":{\"tools\":[{\"name\":\"upstream_tool\"}]}}"
    ' _ "$POLICY_LIB" "$RESULT_LIB" "$TOOLS_LIB" "$REPO_ROOT" "$UPSTREAM_SCRIPT" 2>/dev/null)"
  printf '%s\n' "$merged_json" | jq -e '
    (.result.tools | map(.name) | index("ralph_proxy_batch")) != null
    and (.result.tools | map(.name) | index("ralph_proxy_read")) != null
  '
}

@test "ralph_proxy_batch times out and reports partial failure on long-running operations" {
  command -v jq >/dev/null || skip "jq required"
  printf 'first-file\n' >"$WS/first.txt"
  printf 'second-file\n' >"$WS/second.txt"
  printf 'third-file\n' >"$WS/third.txt"

  local policy args_json response text
  policy="$(batch_policy_json 0)"
  args_json="$(jq -nc '{
    operations: [
      {tool: "ralph_proxy_read", arguments: {path: "first.txt"}},
      {tool: "ralph_proxy_read", arguments: {path: "second.txt"}},
      {tool: "ralph_proxy_read", arguments: {path: "third.txt"}}
    ]
  }')"
  response="$(RALPH_MCP_PROXY_BATCH_TIMEOUT_SEC=1 invoke_proxy_batch "$policy" "$args_json")"
  text="$(batch_result_text "$response")"

  printf '%s\n' "$response" | jq -e '.isError == true'
  [[ "$text" == *"ralph_proxy_read: ok"* ]]
  [[ "$text" == *"PARTIAL_FAILURE: batch timeout"* ]]
  [[ "$text" != *"(completed -"* ]]
}

@test "ralph_proxy_batch respects default max operations of 4" {
  command -v jq >/dev/null || skip "jq required"
  local policy args_json response text
  policy="$(batch_policy_json 0)"
  args_json="$(jq -nc '
    {
      operations: [
        {tool: "ralph_proxy_read", arguments: {path: "missing-01.txt"}},
        {tool: "ralph_proxy_read", arguments: {path: "missing-02.txt"}},
        {tool: "ralph_proxy_read", arguments: {path: "missing-03.txt"}},
        {tool: "ralph_proxy_read", arguments: {path: "missing-04.txt"}},
        {tool: "ralph_proxy_read", arguments: {path: "missing-05.txt"}}
      ]
    }
  ')"
  response="$(invoke_proxy_batch "$policy" "$args_json")"
  text="$(batch_result_text "$response")"

  printf '%s\n' "$response" | jq -e '.isError == true'
  [[ "$text" == *"too many operations (max 4)"* ]]
}

@test "ralph_proxy_batch timeout reports PARTIAL_FAILURE with completed operation count" {
  command -v jq >/dev/null || skip "jq required"
  printf 'file-a\n' >"$WS/file-a.txt"
  printf 'file-b\n' >"$WS/file-b.txt"
  printf 'file-c\n' >"$WS/file-c.txt"

  local policy args_json response text completed_count
  policy="$(batch_policy_json 0)"
  args_json="$(jq -nc '{
    operations: [
      {tool: "ralph_proxy_read", arguments: {path: "file-a.txt"}},
      {tool: "ralph_proxy_read", arguments: {path: "file-b.txt"}},
      {tool: "ralph_proxy_read", arguments: {path: "file-c.txt"}}
    ]
  }')"
  response="$(RALPH_MCP_PROXY_BATCH_TIMEOUT_SEC=1 invoke_proxy_batch "$policy" "$args_json")"
  text="$(batch_result_text "$response")"

  printf '%s\n' "$response" | jq -e '.isError == true'
  [[ "$text" == *"PARTIAL_FAILURE: batch timeout"* ]]
  [[ "$text" == *"(completed "* ]]
}

@test "ralph_proxy_batch timeout returns partial results with isError true" {
  command -v jq >/dev/null || skip "jq required"
  printf 'first\n' >"$WS/first.txt"
  printf 'second\n' >"$WS/second.txt"
  printf 'third\n' >"$WS/third.txt"

  local policy args_json response
  policy="$(batch_policy_json 0)"
  args_json="$(jq -nc '{
    operations: [
      {tool: "ralph_proxy_read", arguments: {path: "first.txt"}},
      {tool: "ralph_proxy_read", arguments: {path: "second.txt"}},
      {tool: "ralph_proxy_read", arguments: {path: "third.txt"}}
    ]
  }')"
  response="$(RALPH_MCP_PROXY_BATCH_TIMEOUT_SEC=1 invoke_proxy_batch "$policy" "$args_json")"

  printf '%s\n' "$response" | jq -e '.isError == true'
  printf '%s\n' "$response" | jq -e '.content[0].text != null'
}

@test "ralph_proxy_batch completes successfully when all operations finish before timeout" {
  command -v jq >/dev/null || skip "jq required"
  printf 'quick-file-a\n' >"$WS/quick-file-a.txt"
  printf 'quick-file-b\n' >"$WS/quick-file-b.txt"

  local policy args_json response text
  policy="$(batch_policy_json 0)"
  args_json="$(jq -nc '{
    operations: [
      {tool: "ralph_proxy_read", arguments: {path: "quick-file-a.txt"}},
      {tool: "ralph_proxy_read", arguments: {path: "quick-file-b.txt"}}
    ]
  }')"
  response="$(RALPH_MCP_PROXY_BATCH_TIMEOUT_SEC=30 invoke_proxy_batch "$policy" "$args_json")"
  text="$(batch_result_text "$response")"

  printf '%s\n' "$response" | jq -e '.isError == false'
  [[ "$text" == *"1. ralph_proxy_read: ok |"* ]]
  [[ "$text" == *"2. ralph_proxy_read: ok |"* ]]
  [[ "$text" != *"PARTIAL_FAILURE"* ]]
}
