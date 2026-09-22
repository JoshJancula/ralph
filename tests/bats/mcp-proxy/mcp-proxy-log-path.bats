#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  LOGGING_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-logging.sh"
}

@test "plan workspace root is used as the state root" {
  run env RALPH_PLAN_KEY="my-plan" RALPH_PLAN_WORKSPACE_ROOT="/tmp/state-root" \
    bash -c 'source "$1"; ralph_mcp_proxy_plan_log_path' _ "$LOGGING_LIB"

  [ "$status" -eq 0 ]
  [ "$output" = "/tmp/state-root/logs/my-plan/mcp.log" ]
}

@test "legacy MCP workspace is treated as a project root" {
  run env RALPH_PLAN_KEY="my-plan" RALPH_MCP_WORKSPACE="/tmp/project-root" \
    bash -c 'source "$1"; ralph_mcp_proxy_plan_log_path' _ "$LOGGING_LIB"

  [ "$status" -eq 0 ]
  [ "$output" = "/tmp/project-root/.ralph-workspace/logs/my-plan/mcp.log" ]
}
