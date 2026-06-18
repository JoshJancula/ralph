#!/usr/bin/env bats

load "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

setup() {
  WORKSPACE="$(mktemp -d)"
  PLAN_PATH="$WORKSPACE/PLAN.md"
  echo "# Test plan" > "$PLAN_PATH"
  export WORKSPACE PLAN_PATH
  export RALPH_PLAN_WORKSPACE_ROOT="$WORKSPACE/.ralph-workspace"
  mkdir -p "$RALPH_PLAN_WORKSPACE_ROOT"
  export RALPH_PLAN_KEY="approval-plan"
  export RALPH_ARTIFACT_NS="approval-namespace"
  export RALPH_AGENT_WORKSPACE="$WORKSPACE"
  export RALPH_APPROVAL_TIMEOUT=5
  export RALPH_APPROVAL_POLL_INTERVAL=1
  export RALPH_APPROVAL_PROGRESS_INTERVAL=1
  export RALPH_PLAN_KEY RALPH_ARTIFACT_NS
  export RALPH_RUN_PLAN_APPROVALS_TTY_PATH="$WORKSPACE/tty"
  touch "$RALPH_RUN_PLAN_APPROVALS_TTY_PATH"
  ralph_run_plan_log() {
    :
  }
  source "$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-approvals.sh"
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-approvals.sh"
  RALPH_RUN_PLAN_APPROVALS_LAST_PENDING=""
}

teardown() {
  rm -rf "$WORKSPACE"
}

create_request_id() {
  ralph_mcp_approvals_write_request "ralph_proxy_read" "policy" "test request" '{"path":"/tmp"}'
}

approved_artifact_dir() {
  printf '%s/artifacts/%s' "${RALPH_PLAN_WORKSPACE_ROOT:-$WORKSPACE/.ralph-workspace}" "${RALPH_ARTIFACT_NS:-$RALPH_PLAN_KEY}"
}

@test "approval watcher prompts on tty when requests pending" {
  export RALPH_AGENT_TOOL_ACCESS=ralph
  export RALPH_MCP_POLICY_VIOLATION_MODE=approve
  export RALPH_RUN_PLAN_APPROVALS_FORCE_TTY=1
  request_id="$(create_request_id)"
  [[ -n "$request_id" ]]

  run ralph_run_plan_approvals_check_pending
  [ "$status" -eq 0 ]

  grep -q "Operator approval pending" "$RALPH_RUN_PLAN_APPROVALS_TTY_PATH"
  grep -q "$request_id" "$(approved_artifact_dir)/APPROVAL-REQUIRED.md"
}

@test "approval watcher writes artifacts for headless runs" {
  export RALPH_AGENT_TOOL_ACCESS=ralph
  export RALPH_MCP_POLICY_VIOLATION_MODE=approve
  unset RALPH_RUN_PLAN_APPROVALS_FORCE_TTY
  request_id="$(create_request_id)"
  [[ -n "$request_id" ]]

  run ralph_run_plan_approvals_check_pending
  [ "$status" -eq 0 ]

  local artifact_dir
  artifact_dir="$(approved_artifact_dir)"
  [ -f "$artifact_dir/APPROVAL-REQUIRED.md" ]
  grep -q "$request_id" "$artifact_dir/APPROVAL-REQUIRED.md"
  [ -f "$artifact_dir/approvals.md" ]
  grep -q "$request_id" "$artifact_dir/approvals.md"
}

@test "approval watcher ignores non-ralph tool access" {
  export RALPH_AGENT_TOOL_ACCESS=native
  export RALPH_MCP_POLICY_VIOLATION_MODE=approve
  request_id="$(create_request_id)"
  [[ -n "$request_id" ]]

  run ralph_run_plan_approvals_check_pending
  [ "$status" -eq 0 ]

  local artifact_dir
  artifact_dir="$(approved_artifact_dir)"
  [ ! -f "$artifact_dir/APPROVAL-REQUIRED.md" ]
  [ ! -f "$artifact_dir/approvals.md" ]
  [ ! -s "$RALPH_RUN_PLAN_APPROVALS_TTY_PATH" ]
}

@test "approval watcher no-ops in error violation mode" {
  export RALPH_AGENT_TOOL_ACCESS=ralph
  export RALPH_MCP_POLICY_VIOLATION_MODE=error
  request_id="$(create_request_id)"
  [[ -n "$request_id" ]]

  run ralph_run_plan_approvals_check_pending
  [ "$status" -eq 0 ]

  local artifact_dir
  artifact_dir="$(approved_artifact_dir)"
  [ ! -f "$artifact_dir/APPROVAL-REQUIRED.md" ]
  [ ! -f "$artifact_dir/approvals.md" ]
}
