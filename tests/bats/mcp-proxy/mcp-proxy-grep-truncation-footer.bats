#!/usr/bin/env bats
# Honest truncation footer for ralph_proxy_grep on the
# RALPH_MCP_EXPLORATION_RESULT_COMPACT=0 fast path (COMPACTION-CACHE-AUDIT a2).

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

POLICY_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-policy.sh"
RESULT_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-result.sh"
TOOLS_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-tools.sh"
UPSTREAM_SCRIPT="$REPO_ROOT/bundle/.ralph/mcp-server.sh"

setup() {
  WS="$(mktemp -d)"
  export RALPH_MCP_WORKSPACE="$WS"
  export RALPH_PLAN_KEY="plan-grep-truncation-footer"
  # Default exploration path: return the gathered window inline (no envelope).
  unset RALPH_MCP_EXPLORATION_RESULT_COMPACT
  export RALPH_MCP_EXPLORATION_RESULT_COMPACT=0
  unset RALPH_MCP_PROXY_POLICY_INLINE
  unset RALPH_MCP_PROXY_POLICY_FILE
  unset RALPH_MCP_PROXY_POLICY
  unset RALPH_MCP_PROXY_POLICY_OWNED_GREP_SOURCE_LINE_CAP
  unset RALPH_MCP_PROXY_POLICY_OWNED_GREP_SOURCE_BYTE_CAP
}

teardown() {
  rm -rf "$WS"
}

invoke_grep() {
  local args_json="$1"
  shift || true
  env \
    RALPH_MCP_WORKSPACE="$WS" \
    RALPH_PLAN_KEY="$RALPH_PLAN_KEY" \
    RALPH_MCP_EXPLORATION_RESULT_COMPACT=0 \
    RALPH_MCP_PROXY_OWNED_TOOLS_FORCE=1 \
    "$@" \
    bash -c '
      source "$1"
      source "$2"
      source "$3"
      ralph_mcp_proxy_load_policy "$4" "$5" || exit 1
      ralph_mcp_proxy_call_owned_tool "$4" "ralph_proxy_grep" "$6"
    ' _ "$POLICY_LIB" "$RESULT_LIB" "$TOOLS_LIB" "$WS" "$UPSTREAM_SCRIPT" "$args_json"
}

seed_matches() {
  local count="${1:-213}"
  local i
  : >"$WS/matches.txt"
  for i in $(seq 1 "$count"); do
    printf 'NEEDLE match-%d\n' "$i" >>"$WS/matches.txt"
  done
}

response_text() {
  jq -r '.content[0].text // empty'
}

@test "grep-truncation-footer: >50 matches gets footer with true total and policy cap 50" {
  seed_matches 213
  local response text footer
  response="$(invoke_grep "$(jq -nc '{pattern:"NEEDLE", path:"matches.txt"}')")"
  printf '%s\n' "$response" | jq -e '.isError != true'
  text="$(printf '%s\n' "$response" | response_text)"
  footer='[ralph_proxy_grep: 50 of 213 matches shown (policy cap 50); narrow the pattern or path, or pass head_limit/offset]'
  [[ "$text" == *"$footer" ]]
  [[ "$(printf '%s\n' "$text" | tail -n1)" == "$footer" ]]
  [[ "$(printf '%s\n' "$text" | grep -c 'NEEDLE match-')" -eq 50 ]]
}

@test "grep-truncation-footer: <=50 matches delivers every match with no footer" {
  seed_matches 30
  local response text
  response="$(invoke_grep "$(jq -nc '{pattern:"NEEDLE", path:"matches.txt"}')")"
  printf '%s\n' "$response" | jq -e '.isError != true'
  text="$(printf '%s\n' "$response" | response_text)"
  [[ "$text" != *"[ralph_proxy_grep:"* ]]
  [[ "$(printf '%s\n' "$text" | grep -c 'NEEDLE match-')" -eq 30 ]]
  [[ "$(printf '%s\n' "$text" | tail -n1)" == "NEEDLE match-30" ]] || \
    [[ "$(printf '%s\n' "$text" | tail -n1)" == *"NEEDLE match-30"* ]]
}

@test "grep-truncation-footer: source-capped run says at least and names the reason" {
  seed_matches 100
  local response text
  response="$(
    invoke_grep "$(jq -nc '{pattern:"NEEDLE", path:"matches.txt"}')" \
      RALPH_MCP_PROXY_POLICY_OWNED_GREP_SOURCE_LINE_CAP=10
  )"
  printf '%s\n' "$response" | jq -e '.isError != true'
  text="$(printf '%s\n' "$response" | response_text)"
  [[ "$text" == *"of at least"* ]]
  [[ "$text" == *"source search stopped early"* ]]
  [[ "$text" == *"[ralph_proxy_grep:"* ]]
  [[ "$text" == *"line_cap"* ]] || [[ "$text" == *"byte_cap"* ]]
}
