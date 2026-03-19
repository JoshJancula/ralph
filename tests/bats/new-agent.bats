#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"
source "$RALPH_LIB_ROOT/new-agent.sh"

@test "valid agent id passes validation" {
  run new_agent_is_valid_id "ralph-agent"
  [ "$status" -eq 0 ]
}

@test "invalid agent id rejects uppercase characters" {
  run new_agent_is_valid_id "Invalid-ID"
  [ "$status" -ne 0 ]
}

@test "workspace path helper joins nested segments" {
  workspace="$(mktemp -d)"
  run new_agent_workspace_path "$workspace" ".cursor" "agents" "alpha"
  [ "$status" -eq 0 ]
  [ "$output" = "$workspace/.cursor/agents/alpha" ]
  rm -rf "$workspace"
}

@test "workspace path helper rejects traversal above root" {
  workspace="$(mktemp -d)"
  run new_agent_workspace_path "$workspace" ".." "etc"
  [ "$status" -ne 0 ]
  rm -rf "$workspace"
}
