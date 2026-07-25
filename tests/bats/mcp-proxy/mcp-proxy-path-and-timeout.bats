#!/usr/bin/env bats

# Regression coverage for two proxy faults that stalled downstream plan runs:
#   1. A wrong-but-in-tree relative path was misclassified as a boundary escape
#      (fatal, server-killing) instead of a recoverable "does not exist".
#   2. Read-only search tools had no transport-safe time cap, so a slow scan
#      blocked the single stdio loop and the host client timed out the queue.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

TOOLS_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-tools.sh"
POLICY_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-policy.sh"
RESULT_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-result.sh"
UPSTREAM_SCRIPT="$REPO_ROOT/bundle/.ralph/mcp-server.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  WS="$TEST_TMPDIR/workspace"
  mkdir -p "$WS/ui/src/app/components/pipelines"
  printf 'export const x = 1;\n' >"$WS/ui/src/app/components/pipelines/pipeline-builder.component.ts"
  unset RALPH_PLAN_WORKSPACE_ROOT
  export RALPH_MCP_WORKSPACE="$WS"
  # shellcheck source=/dev/null
  source "$TOOLS_LIB"
}

teardown() {
  [[ -e "$TEST_TMPDIR" ]] && rm -rf "$TEST_TMPDIR"
}

@test "lexical_path normalizes without touching the filesystem" {
  run ralph_mcp_proxy_lexical_path "/a//b/./c/"
  [ "$status" -eq 0 ]
  [ "$output" = "/a/b/c" ]
}

@test "path_is_allowed reports does-not-exist (2) for a wrong-but-in-tree relative path" {
  # Parent dir does not exist, so canonicalization fails; the lexical form is
  # still under the workspace, so this must be 2 (does not exist), never 1.
  run ralph_mcp_proxy_path_is_allowed "pipelines/pipeline-builder.component.ts" 0
  [ "$status" -eq 2 ]
}

@test "path_is_allowed reports does-not-exist (2) for a missing in-tree path when existence required" {
  # Parent exists here, so canonicalization succeeds; with require_exists=1 the
  # missing file must report 2 (does not exist), never a boundary escape.
  run ralph_mcp_proxy_path_is_allowed "ui/src/app/components/pipelines/does-not-exist.ts" 1
  [ "$status" -eq 2 ]
}

@test "path_is_allowed still denies a genuine absolute escape (1)" {
  run ralph_mcp_proxy_path_is_allowed "/etc/passwd" 0
  [ "$status" -eq 1 ]
}

@test "path_is_allowed still denies parent-traversal escape (1)" {
  run ralph_mcp_proxy_path_is_allowed "../../../etc/passwd" 0
  [ "$status" -eq 1 ]
}

@test "path_is_allowed resolves an existing in-tree relative path (0)" {
  # Output is the canonical (symlink-resolved) path, which on some platforms
  # differs from $WS by a /private or /var prefix; assert on the leaf instead.
  run ralph_mcp_proxy_path_is_allowed "ui/src/app/components/pipelines/pipeline-builder.component.ts" 0
  [ "$status" -eq 0 ]
  [[ "$output" == *"/pipelines/pipeline-builder.component.ts" ]]
}

@test "ralph_proxy_grep on a wrong-but-in-tree path is a non-fatal does-not-exist error" {
  command -v jq >/dev/null || skip "jq required"
  local args response
  args="$(jq -nc '{pattern: "x", path: "pipelines/pipeline-builder.component.ts"}')"
  response="$(RALPH_MCP_PROXY_OWNED_TOOLS_FORCE=1 ralph_mcp_proxy_owned_tool_grep "$WS" "$args")"
  printf '%s\n' "$response" | jq -e '.isError == true'
  printf '%s\n' "$response" | jq -e '.content[0].text | test("does not exist")'
  # Must NOT escalate to a fatal boundary violation that kills the server.
  printf '%s\n' "$response" | jq -e '.content[0].text | test("outside the workspace") | not'
  [ "${RALPH_MCP_PROXY_FATAL_VIOLATION:-0}" != "1" ]
}

@test "search sync timeout defaults to 25s and honors override" {
  run ralph_mcp_proxy_search_sync_timeout_seconds
  [ "$output" = "25" ]
  run env RALPH_PROXY_SEARCH_SYNC_TIMEOUT_SECONDS=7 bash -c 'source "$1"; ralph_mcp_proxy_search_sync_timeout_seconds' _ "$TOOLS_LIB"
  [ "$output" = "7" ]
}

@test "run_search_cmd returns 124 when the transport-safe cap fires" {
  command -v timeout >/dev/null || skip "timeout binary required"
  local out; out="$(mktemp)"
  run env RALPH_PROXY_SEARCH_SYNC_TIMEOUT_SECONDS=1 bash -c \
    'source "$1"; ralph_mcp_proxy_run_search_cmd "$2" -- sleep 5' _ "$TOOLS_LIB" "$out"
  rm -f "$out"
  [ "$status" -eq 124 ]
}

@test "run_search_cmd returns command status when it completes under the cap" {
  local out; out="$(mktemp)"
  run env RALPH_PROXY_SEARCH_SYNC_TIMEOUT_SECONDS=10 bash -c \
    'source "$1"; ralph_mcp_proxy_run_search_cmd "$2" -- printf hi' _ "$TOOLS_LIB" "$out"
  [ "$status" -eq 0 ]
  [ "$(cat "$out")" = "hi" ]
  rm -f "$out"
}
