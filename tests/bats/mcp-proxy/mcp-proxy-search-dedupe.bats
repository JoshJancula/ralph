#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

POLICY_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-policy.sh"
RESULT_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-result.sh"
TOOLS_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-tools.sh"
UPSTREAM_SCRIPT="$REPO_ROOT/bundle/.ralph/mcp-server.sh"
GREP_FIXTURE="$REPO_ROOT/tests/fixtures/mcp-proxy/grep-many-matches.txt"
GLOB_FIXTURE_DIR="$REPO_ROOT/tests/fixtures/mcp-proxy/glob-many-files"

load_proxy_search_dedupe_libs() {
  # shellcheck source=/dev/null
  source "$POLICY_LIB"
  # shellcheck source=/dev/null
  source "$RESULT_LIB"
  # shellcheck source=/dev/null
  source "$TOOLS_LIB"
}

grep_trunc_policy_json() {
  jq -nc '{
    name: "search-dedupe-grep",
    proxyOwnedTools: {
      enabled: true,
      maxGrepMatches: 5,
      shellAllowlist: ["true"]
    },
    resultByteCap: 65536,
    toolResultByteCaps: {
      ralph_proxy_grep: 65536
    }
  }'
}

glob_trunc_policy_json() {
  jq -nc '{
    name: "search-dedupe-glob",
    proxyOwnedTools: {
      enabled: true,
      maxGlobResults: 5,
      shellAllowlist: ["true"]
    },
    resultByteCap: 65536,
    toolResultByteCaps: {
      ralph_proxy_glob: 65536
    }
  }'
}

invoke_search_dedupe_grep_pair() {
  local policy_json="${1:-}"
  local grep_args="${2:-}"
  shift 2
  env "$@" \
    RALPH_MCP_PROXY_POLICY_INLINE="$policy_json" \
    bash -c '
      source "$1"
      source "$2"
      source "$3"
      ralph_mcp_proxy_load_policy "$4" "$5" || exit 1
      ralph_mcp_proxy_call_owned_tool "$6" "ralph_proxy_grep" "$7"
      echo __SEARCH_SPLIT__
      ralph_mcp_proxy_call_owned_tool "$6" "ralph_proxy_grep" "$7"
    ' _ "$POLICY_LIB" "$RESULT_LIB" "$TOOLS_LIB" "$REPO_ROOT" "$UPSTREAM_SCRIPT" "$WS" "$grep_args"
}

invoke_search_dedupe_glob_pair() {
  local policy_json="${1:-}"
  local glob_args="${2:-}"
  shift 2
  env "$@" \
    RALPH_MCP_PROXY_POLICY_INLINE="$policy_json" \
    bash -c '
      source "$1"
      source "$2"
      source "$3"
      ralph_mcp_proxy_load_policy "$4" "$5" || exit 1
      ralph_mcp_proxy_call_owned_tool "$6" "ralph_proxy_glob" "$7"
      echo __SEARCH_SPLIT__
      ralph_mcp_proxy_call_owned_tool "$6" "ralph_proxy_glob" "$7"
    ' _ "$POLICY_LIB" "$RESULT_LIB" "$TOOLS_LIB" "$REPO_ROOT" "$UPSTREAM_SCRIPT" "$WS" "$glob_args"
}

invoke_search_dedupe_grep_sequential() {
  local policy_json="${1:-}"
  local grep_args1="${2:-}"
  local grep_args2="${3:-}"
  shift 3
  env "$@" \
    RALPH_MCP_PROXY_POLICY_INLINE="$policy_json" \
    bash -c '
      source "$1"
      source "$2"
      source "$3"
      ralph_mcp_proxy_load_policy "$4" "$5" || exit 1
      ralph_mcp_proxy_call_owned_tool "$6" "ralph_proxy_grep" "$7"
      echo __SEARCH_SPLIT__
      ralph_mcp_proxy_call_owned_tool "$6" "ralph_proxy_grep" "$8"
    ' _ "$POLICY_LIB" "$RESULT_LIB" "$TOOLS_LIB" "$REPO_ROOT" "$UPSTREAM_SCRIPT" "$WS" "$grep_args1" "$grep_args2"
}

invoke_search_dedupe_grep_with_shell() {
  local policy_json="${1:-}"
  local grep_args="${2:-}"
  local shell_cmd="${3:-true}"
  env \
    RALPH_MCP_PROXY_POLICY_INLINE="$policy_json" \
    bash -c '
      source "$1"
      source "$2"
      source "$3"
      ralph_mcp_proxy_load_policy "$4" "$5" || exit 1
      ralph_mcp_proxy_call_owned_tool "$6" "ralph_proxy_grep" "$7"
      echo __SEARCH_SPLIT__
      ralph_mcp_proxy_call_owned_tool "$6" "ralph_proxy_shell" "$(jq -nc --arg cmd "$8" "{command:\$cmd}")"
      echo __SEARCH_SPLIT__
      ralph_mcp_proxy_call_owned_tool "$6" "ralph_proxy_grep" "$7"
    ' _ "$POLICY_LIB" "$RESULT_LIB" "$TOOLS_LIB" "$REPO_ROOT" "$UPSTREAM_SCRIPT" "$WS" "$grep_args" "$shell_cmd"
}

split_search_dedupe_response() {
  SEARCH_DEDUPE_FIRST="${1%%__SEARCH_SPLIT__*}"
  local rest="${1#*__SEARCH_SPLIT__}"
  SEARCH_DEDUPE_SECOND="${rest%%__SEARCH_SPLIT__*}"
  SEARCH_DEDUPE_THIRD="${rest#*__SEARCH_SPLIT__}"
  if [[ "$SEARCH_DEDUPE_THIRD" == "$rest" ]]; then
    SEARCH_DEDUPE_THIRD=""
  fi
}

assert_grep_response_not_deduped() {
  local response="${1:-}"
  printf '%s\n' "$response" | jq -e '
    if (.content[0].text | startswith("{")) then
      ((.content[0].text | fromjson | .deduped) // false) == false
    else
      (.content[0].text | test("duplicate grep suppressed") | not)
    end
  '
}

setup() {
  bats_skip_known_ci_flakes
  TEST_TMPDIR="$(mktemp -d)"
  WS="$TEST_TMPDIR/workspace"
  mkdir -p "$WS"
  cp "$GREP_FIXTURE" "$WS/grep-many-matches.txt"
  cp "$GREP_FIXTURE" "$WS/grep-many-matches-alt.txt"
  cp -R "$GLOB_FIXTURE_DIR" "$WS/glob-many-files"
  export RALPH_MCP_WORKSPACE="$WS"
  export RALPH_MCP_EXPLORATION_RESULT_COMPACT=1
  export RALPH_PLAN_KEY="plan-search-dedupe"
  unset RALPH_PLAN_WORKSPACE_ROOT
  export RALPH_COMPACTORS_LIB_DIR="$REPO_ROOT/bundle/.ralph/bash-lib"
  load_proxy_search_dedupe_libs
}

teardown() {
  if [[ -e "${TEST_TMPDIR:-}" ]]; then
    rm -rf "$TEST_TMPDIR"
  fi
}

@test "identical grep deduped with resultId readable via ralph_proxy_result_read" {
  command -v jq >/dev/null || skip "jq required"

  local policy grep_args response out_dir
  policy="$(grep_trunc_policy_json)"
  grep_args='{"pattern":"MATCHME","path":"grep-many-matches.txt"}'

  response="$(env \
    RALPH_MCP_PROXY_POLICY_INLINE="$policy" \
    bash -c '
      source "$1"
      source "$2"
      source "$3"
      ralph_mcp_proxy_load_policy "$4" "$5" || exit 1
      out="$(mktemp -d)"
      ralph_mcp_proxy_call_owned_tool "$6" "ralph_proxy_grep" "$7" >"$out/first.json"
      ralph_mcp_proxy_call_owned_tool "$6" "ralph_proxy_grep" "$7" >"$out/second.json"
      result_id=$(jq -r ".content[0].text | fromjson | .resultId" "$out/second.json")
      ralph_mcp_proxy_call_owned_tool "$6" "ralph_proxy_result_read" "$(jq -nc --arg id "$result_id" "{resultId:\$id}")" >"$out/read-back.json"
      printf "%s" "$result_id" >"$out/result-id.txt"
      printf "RALPH_SEARCH_DEDUPE_OUT=%s\n" "$out"
    ' _ "$POLICY_LIB" "$RESULT_LIB" "$TOOLS_LIB" "$REPO_ROOT" "$UPSTREAM_SCRIPT" "$WS" "$grep_args")"

  out_dir="$(printf '%s\n' "$response" | sed -n 's/^RALPH_SEARCH_DEDUPE_OUT=//p' | tail -n1)"
  [ -n "$out_dir" ]
  [ -f "$out_dir/first.json" ]

  printf '%s\n' "$(<"$out_dir/first.json")" | jq -e '
    .isError == false
    and (.content[0].text | fromjson | .truncated) == true
    and (.content[0].text | fromjson | .preview | test("grep-fixture-line-001"))
    and (.content[0].text | fromjson | .resultId | test("^[a-f0-9]{16}$"))
  '
  printf '%s\n' "$(<"$out_dir/second.json")" | jq -e '
    (.content[0].text | fromjson | .deduped) == true
    and (.content[0].text | fromjson | .preview | test("duplicate grep suppressed"))
    and (.content[0].text | test("grep-fixture-line-006") | not)
  '
  [[ "$(<"$out_dir/result-id.txt")" =~ ^[a-f0-9]{16}$ ]]
  printf '%s\n' "$(<"$out_dir/read-back.json")" | jq -e '.content[0].text | test("grep-fixture-line-006")'

  rm -rf "$out_dir"
}

@test "identical glob deduped" {
  command -v jq >/dev/null || skip "jq required"

  local policy glob_args response first second
  policy="$(glob_trunc_policy_json)"
  glob_args='{"glob_pattern":"glob-fixture-*.txt","target_directory":"glob-many-files"}'
  response="$(invoke_search_dedupe_glob_pair "$policy" "$glob_args")"
  split_search_dedupe_response "$response"
  first="$SEARCH_DEDUPE_FIRST"
  second="$SEARCH_DEDUPE_SECOND"

  printf '%s\n' "$first" | jq -e '
    .isError == false
    and (.content[0].text | fromjson | .truncated) == true
    and (.content[0].text | fromjson | .preview | test("glob-fixture-01.txt"))
    and (.content[0].text | fromjson | .resultId | test("^[a-f0-9]{16}$"))
  '
  printf '%s\n' "$second" | jq -e '
    .isError == false
    and (.content[0].text | fromjson | .deduped) == true
    and (.content[0].text | fromjson | .preview | test("duplicate glob suppressed"))
  '
  [[ "$second" != *"glob-fixture-20.txt"* ]]
}

@test "glob search skips ralph workspace state files" {
  command -v jq >/dev/null || skip "jq required"

  mkdir -p "$WS/.ralph-workspace/tool-results/plan-a/results"
  mkdir -p "$WS/visible"
  printf 'hidden workspace file\n' >"$WS/.ralph-workspace/tool-results/plan-a/results/hidden-workspace-file.txt"
  printf 'visible workspace file\n' >"$WS/visible/hidden-workspace-file.txt"

  local policy glob_args response text
  policy="$(glob_trunc_policy_json)"
  glob_args='{"glob_pattern":"**/hidden-workspace-file.txt","target_directory":"."}'
  response="$(invoke_search_dedupe_glob_pair "$policy" "$glob_args")"
  split_search_dedupe_response "$response"
  text="$SEARCH_DEDUPE_FIRST"

  printf '%s\n' "$text" | jq -e '
    .isError == false
    and (.content[0].text | test("visible/hidden-workspace-file.txt"))
    and (.content[0].text | test("\\.ralph-workspace") | not)
  '
}

@test "different grep pattern path or flags not deduped" {
  command -v jq >/dev/null || skip "jq required"

  local policy response first second

  policy="$(grep_trunc_policy_json)"

  response="$(invoke_search_dedupe_grep_sequential "$policy" \
    '{"pattern":"MATCHME","path":"grep-many-matches.txt"}' \
    '{"pattern":"grep-fixture-line-010","path":"grep-many-matches.txt"}')"
  split_search_dedupe_response "$response"
  assert_grep_response_not_deduped "$SEARCH_DEDUPE_SECOND"

  response="$(invoke_search_dedupe_grep_sequential "$policy" \
    '{"pattern":"MATCHME","path":"grep-many-matches.txt"}' \
    '{"pattern":"MATCHME","path":"grep-many-matches-alt.txt"}')"
  split_search_dedupe_response "$response"
  assert_grep_response_not_deduped "$SEARCH_DEDUPE_SECOND"

  response="$(invoke_search_dedupe_grep_sequential "$policy" \
    '{"pattern":"MATCHME","path":"grep-many-matches.txt","head_limit":2}' \
    '{"pattern":"MATCHME","path":"grep-many-matches.txt","head_limit":5}')"
  split_search_dedupe_response "$response"
  assert_grep_response_not_deduped "$SEARCH_DEDUPE_SECOND"
}

@test "mutating shell between calls invalidates search dedupe cache" {
  command -v jq >/dev/null || skip "jq required"

  local policy grep_args response first second third
  policy="$(grep_trunc_policy_json)"
  grep_args='{"pattern":"MATCHME","path":"grep-many-matches.txt"}'
  response="$(invoke_search_dedupe_grep_with_shell "$policy" "$grep_args" "true")"
  split_search_dedupe_response "$response"
  first="$SEARCH_DEDUPE_FIRST"
  second="$SEARCH_DEDUPE_SECOND"
  third="$SEARCH_DEDUPE_THIRD"

  printf '%s\n' "$first" | jq -e '
    .isError == false
    and (.content[0].text | fromjson | .truncated) == true
  '
  printf '%s\n' "$second" | jq -e '.isError == false'
  printf '%s\n' "$third" | jq -e '
    .isError == false
    and (.content[0].text | fromjson | .deduped // false) == false
    and (.content[0].text | fromjson | .truncated) == true
    and (.content[0].text | fromjson | .preview | test("grep-fixture-line-001"))
  '
}

@test "RALPH_PROXY_DEDUPE_SEARCH=0 disables search dedupe" {
  command -v jq >/dev/null || skip "jq required"

  local policy grep_args response first second
  policy="$(grep_trunc_policy_json)"
  grep_args='{"pattern":"MATCHME","path":"grep-many-matches.txt"}'
  response="$(invoke_search_dedupe_grep_pair "$policy" "$grep_args" RALPH_PROXY_DEDUPE_SEARCH=0)"
  split_search_dedupe_response "$response"
  first="$SEARCH_DEDUPE_FIRST"
  second="$SEARCH_DEDUPE_SECOND"

  printf '%s\n' "$first" | jq -e '
    .isError == false
    and (.content[0].text | fromjson | .preview | test("grep-fixture-line-001"))
  '
  printf '%s\n' "$second" | jq -e '
    .isError == false
    and (.content[0].text | fromjson | .deduped // false) == false
    and (.content[0].text | fromjson | .preview | test("grep-fixture-line-001"))
  '
  [[ "$second" != *"duplicate grep suppressed"* ]]
}

grep_dedupe_preview_text() {
  local response="${1:-}"
  printf '%s\n' "$response" | jq -r '
    if (.content[0].text | startswith("{")) then
      (.content[0].text | fromjson | .preview // empty)
    else
      .content[0].text
    end
  '
}

@test "duplicate grep response does not include full match body" {
  command -v jq >/dev/null || skip "jq required"

  local policy grep_args response first second preview_text
  policy="$(grep_trunc_policy_json)"
  grep_args='{"pattern":"MATCHME","path":"grep-many-matches.txt"}'
  response="$(invoke_search_dedupe_grep_pair "$policy" "$grep_args")"
  split_search_dedupe_response "$response"
  first="$SEARCH_DEDUPE_FIRST"
  second="$SEARCH_DEDUPE_SECOND"

  preview_text="$(grep_dedupe_preview_text "$first")"
  [[ "$preview_text" == *"grep-fixture-line-005"* ]]
  [[ "$preview_text" != *"grep-fixture-line-006"* ]]
  preview_text="$(grep_dedupe_preview_text "$second")"
  printf '%s\n' "$second" | jq -e '
    if (.content[0].text | startswith("{")) then
      (.content[0].text | fromjson | .deduped) == true
    else
      (.content[0].text | test("duplicate grep suppressed"))
    end
    and (.content[0].text | test("grep-fixture-line-001") | not)
    and (.content[0].text | test("grep-fixture-line-006") | not)
  '
  [[ "$preview_text" != *"grep-fixture-line-001"* ]]
  [[ "$preview_text" != *"grep-fixture-line-006"* ]]
}
