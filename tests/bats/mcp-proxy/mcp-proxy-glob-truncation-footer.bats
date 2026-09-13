#!/usr/bin/env bats
# Honest truncation footer for ralph_proxy_glob on the
# RALPH_MCP_EXPLORATION_RESULT_COMPACT=0 fast path (COMPACTION-CACHE-AUDIT a3).

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

POLICY_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-policy.sh"
RESULT_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-result.sh"
TOOLS_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-tools.sh"
UPSTREAM_SCRIPT="$REPO_ROOT/bundle/.ralph/mcp-server.sh"

setup() {
  WS="$(mktemp -d)"
  export RALPH_MCP_WORKSPACE="$WS"
  export RALPH_PLAN_KEY="plan-glob-truncation-footer"
  # Default exploration path: return the gathered window inline (no envelope).
  unset RALPH_MCP_EXPLORATION_RESULT_COMPACT
  export RALPH_MCP_EXPLORATION_RESULT_COMPACT=0
  unset RALPH_MCP_PROXY_POLICY_INLINE
  unset RALPH_MCP_PROXY_POLICY_FILE
  unset RALPH_MCP_PROXY_POLICY
}

teardown() {
  rm -rf "$WS"
}

invoke_glob() {
  local args_json="$1"
  env \
    RALPH_MCP_WORKSPACE="$WS" \
    RALPH_PLAN_KEY="$RALPH_PLAN_KEY" \
    RALPH_MCP_EXPLORATION_RESULT_COMPACT=0 \
    RALPH_MCP_PROXY_OWNED_TOOLS_FORCE=1 \
    bash -c '
      source "$1"
      source "$2"
      source "$3"
      ralph_mcp_proxy_load_policy "$4" "$5" || exit 1
      ralph_mcp_proxy_call_owned_tool "$4" "ralph_proxy_glob" "$6"
    ' _ "$POLICY_LIB" "$RESULT_LIB" "$TOOLS_LIB" "$WS" "$UPSTREAM_SCRIPT" "$args_json"
}

seed_files() {
  local count="${1:-150}"
  local i
  mkdir -p "$WS/glob-many-files"
  for i in $(seq 1 "$count"); do
    printf 'x\n' >"$WS/glob-many-files/glob-fixture-$(printf '%03d' "$i").txt"
  done
}

response_text() {
  jq -r '.content[0].text // empty'
}

path_line_count() {
  # Count delivered path lines (exclude the truncation footer).
  awk '
    /^\[ralph_proxy_glob:/ { next }
    NF { count++ }
    END { print count + 0 }
  '
}

glob_args() {
  jq -nc '{glob_pattern:"glob-fixture-*.txt", target_directory:"glob-many-files"}'
}

@test "glob-truncation-footer: >100 paths gets footer with true total and policy cap 100" {
  seed_files 150
  local response text footer
  response="$(invoke_glob "$(glob_args)")"
  printf '%s\n' "$response" | jq -e '.isError != true'
  text="$(printf '%s\n' "$response" | response_text)"
  footer='[ralph_proxy_glob: 100 of 150 paths shown (policy cap 100); narrow the pattern or pass offset/limit]'
  [[ "$text" == *"$footer" ]]
  [[ "$(printf '%s\n' "$text" | tail -n1)" == "$footer" ]]
  [[ "$(printf '%s\n' "$text" | path_line_count)" -eq 100 ]]
}

@test "glob-truncation-footer: <=100 paths delivers every path with no footer" {
  seed_files 10
  local response text
  response="$(invoke_glob "$(glob_args)")"
  printf '%s\n' "$response" | jq -e '.isError != true'
  text="$(printf '%s\n' "$response" | response_text)"
  [[ "$text" != *"[ralph_proxy_glob:"* ]]
  [[ "$(printf '%s\n' "$text" | path_line_count)" -eq 10 ]]
}
