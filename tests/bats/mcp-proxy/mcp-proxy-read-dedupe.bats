#!/usr/bin/env bats
# Duplicate ralph_proxy_read returns cached body with a one-line prefix
# (COMPACTION-CACHE-AUDIT d1), never the old "(duplicate read suppressed ...)" stub.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

POLICY_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-policy.sh"
RESULT_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-result.sh"
TOOLS_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-tools.sh"
UPSTREAM_SCRIPT="$REPO_ROOT/bundle/.ralph/mcp-server.sh"

READ_DEDUPE_PREFIX='(repeat of an earlier identical read in this session; file unchanged)'

setup() {
  WS="$(mktemp -d)"
  export RALPH_MCP_WORKSPACE="$WS"
  export RALPH_PLAN_KEY="plan-read-dedupe"
  # Default exploration path: return the gathered window inline (no envelope).
  unset RALPH_MCP_EXPLORATION_RESULT_COMPACT
  export RALPH_MCP_EXPLORATION_RESULT_COMPACT=0
  unset RALPH_MCP_PROXY_POLICY_INLINE
  unset RALPH_MCP_PROXY_POLICY_FILE
  unset RALPH_MCP_PROXY_POLICY
  unset RALPH_PROXY_DEDUPE_READS
}

teardown() {
  rm -rf "$WS"
}

invoke_read() {
  local args_json="$1"
  shift
  env "$@" \
    RALPH_MCP_WORKSPACE="$WS" \
    RALPH_PLAN_KEY="$RALPH_PLAN_KEY" \
    RALPH_MCP_EXPLORATION_RESULT_COMPACT=0 \
    RALPH_MCP_PROXY_OWNED_TOOLS_FORCE=1 \
    bash -c '
      source "$1"
      source "$2"
      source "$3"
      ralph_mcp_proxy_load_policy "$4" "$5" || exit 1
      ralph_mcp_proxy_call_owned_tool "$4" "ralph_proxy_read" "$6"
    ' _ "$POLICY_LIB" "$RESULT_LIB" "$TOOLS_LIB" "$WS" "$UPSTREAM_SCRIPT" "$args_json"
}

invoke_read_pair() {
  local args_json="$1"
  shift
  env "$@" \
    RALPH_MCP_WORKSPACE="$WS" \
    RALPH_PLAN_KEY="$RALPH_PLAN_KEY" \
    RALPH_MCP_EXPLORATION_RESULT_COMPACT=0 \
    RALPH_MCP_PROXY_OWNED_TOOLS_FORCE=1 \
    bash -c '
      source "$1"
      source "$2"
      source "$3"
      ralph_mcp_proxy_load_policy "$4" "$5" || exit 1
      ralph_mcp_proxy_call_owned_tool "$4" "ralph_proxy_read" "$6"
      echo __READ_DEDUPE_SPLIT__
      ralph_mcp_proxy_call_owned_tool "$4" "ralph_proxy_read" "$6"
    ' _ "$POLICY_LIB" "$RESULT_LIB" "$TOOLS_LIB" "$WS" "$UPSTREAM_SCRIPT" "$args_json"
}

invoke_read_pair_with_mtime_bump() {
  local args_json="$1"
  local target_rel="$2"
  shift 2
  env "$@" \
    RALPH_MCP_WORKSPACE="$WS" \
    RALPH_PLAN_KEY="$RALPH_PLAN_KEY" \
    RALPH_MCP_EXPLORATION_RESULT_COMPACT=0 \
    RALPH_MCP_PROXY_OWNED_TOOLS_FORCE=1 \
    bash -c '
      source "$1"
      source "$2"
      source "$3"
      ralph_mcp_proxy_load_policy "$4" "$5" || exit 1
      ralph_mcp_proxy_call_owned_tool "$4" "ralph_proxy_read" "$6"
      echo __READ_DEDUPE_SPLIT__
      # Bump mtime without changing size so the cache key still matches but
      # try_return refuses the entry and a fresh read is emitted. Use an
      # explicit timestamp so same-second create/touch cannot no-op.
      touch -t 200001010000 "$4/$7"
      ralph_mcp_proxy_call_owned_tool "$4" "ralph_proxy_read" "$6"
    ' _ "$POLICY_LIB" "$RESULT_LIB" "$TOOLS_LIB" "$WS" "$UPSTREAM_SCRIPT" "$args_json" "$target_rel"
}

response_text() {
  jq -r '.content[0].text // empty'
}

split_pair() {
  READ_DEDUPE_FIRST="${1%%__READ_DEDUPE_SPLIT__*}"
  READ_DEDUPE_SECOND="${1#*__READ_DEDUPE_SPLIT__}"
  # Trim leading newline from the split marker.
  READ_DEDUPE_SECOND="${READ_DEDUPE_SECOND#$'\n'}"
}

seed_small_file() {
  printf 'alpha\nbeta\ngamma\n' >"$WS/small.txt"
}

seed_large_file() {
  awk 'BEGIN { for (i = 1; i <= 400; i++) printf "line-%d\n", i }' >"$WS/four-hundred.txt"
}

@test "identical read dedupe returns body with repeat prefix" {
  seed_small_file
  local response first second first_text second_text body
  response="$(invoke_read_pair "$(jq -nc '{path:"small.txt", limit:20}')")"
  split_pair "$response"
  first="$READ_DEDUPE_FIRST"
  second="$READ_DEDUPE_SECOND"

  printf '%s\n' "$first" | jq -e '.isError != true'
  printf '%s\n' "$second" | jq -e '.isError != true'
  first_text="$(printf '%s\n' "$first" | response_text)"
  second_text="$(printf '%s\n' "$second" | response_text)"

  [[ "$first_text" == *$'\nalpha\n'* || "$first_text" == "alpha"$'\n'* ]]
  [[ "$first_text" == *"alpha"* && "$first_text" == *"beta"* && "$first_text" == *"gamma"* ]]
  [[ "$first_text" != *"$READ_DEDUPE_PREFIX"* ]]
  [[ "$first_text" != *"duplicate read suppressed"* ]]

  [[ "$(printf '%s\n' "$second_text" | sed -n '1p')" == "$READ_DEDUPE_PREFIX" ]]
  body="$(printf '%s\n' "$second_text" | sed '1d')"
  [[ "$body" == "$first_text" ]]
  [[ "$second_text" != *"duplicate read suppressed"* ]]
}

@test "identical truncated read dedupe replays body plus truncation footer" {
  seed_large_file
  local response first second first_text second_text body footer
  footer='[ralph_proxy_read: lines 1-250 of 400 shown (policy cap 250); continue with offset=251]'
  response="$(invoke_read_pair "$(jq -nc '{path:"four-hundred.txt"}')")"
  split_pair "$response"
  first="$READ_DEDUPE_FIRST"
  second="$READ_DEDUPE_SECOND"

  first_text="$(printf '%s\n' "$first" | response_text)"
  second_text="$(printf '%s\n' "$second" | response_text)"

  [[ "$first_text" == *"$footer"* ]]
  [[ "$(printf '%s\n' "$first_text" | tail -n1)" == "$footer" ]]
  [[ "$(printf '%s\n' "$first_text" | grep -c '^line-')" -eq 250 ]]

  [[ "$(printf '%s\n' "$second_text" | sed -n '1p')" == "$READ_DEDUPE_PREFIX" ]]
  body="$(printf '%s\n' "$second_text" | sed '1d')"
  [[ "$body" == "$first_text" ]]
  [[ "$second_text" == *"$footer"* ]]
  [[ "$(printf '%s\n' "$second_text" | grep -c '^line-')" -eq 250 ]]
}

@test "mtime change invalidates read dedupe and returns fresh content with no prefix" {
  seed_small_file
  local response first second first_text second_text
  response="$(invoke_read_pair_with_mtime_bump "$(jq -nc '{path:"small.txt", limit:20}')" "small.txt")"
  split_pair "$response"
  first="$READ_DEDUPE_FIRST"
  second="$READ_DEDUPE_SECOND"

  first_text="$(printf '%s\n' "$first" | response_text)"
  second_text="$(printf '%s\n' "$second" | response_text)"

  [[ "$first_text" == *"alpha"* ]]
  [[ "$second_text" == *"alpha"* ]]
  [[ "$second_text" != *"$READ_DEDUPE_PREFIX"* ]]
  [[ "$second_text" != *"duplicate read suppressed"* ]]
  # Fresh delivery matches the first body (file contents unchanged; only mtime bumped).
  [[ "$second_text" == "$first_text" ]]
}

@test "RALPH_PROXY_DEDUPE_READS=0 disables read dedupe prefix" {
  seed_small_file
  local response first second first_text second_text
  response="$(invoke_read_pair "$(jq -nc '{path:"small.txt", limit:20}')" RALPH_PROXY_DEDUPE_READS=0)"
  split_pair "$response"
  first="$READ_DEDUPE_FIRST"
  second="$READ_DEDUPE_SECOND"

  first_text="$(printf '%s\n' "$first" | response_text)"
  second_text="$(printf '%s\n' "$second" | response_text)"

  [[ "$first_text" == *"alpha"* ]]
  [[ "$second_text" == *"alpha"* ]]
  [[ "$second_text" != *"$READ_DEDUPE_PREFIX"* ]]
  [[ "$second_text" != *"duplicate read suppressed"* ]]
  [[ "$second_text" == "$first_text" ]]
}
