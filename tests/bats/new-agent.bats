#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"
source "$RALPH_LIB_ROOT/new-agent/new-agent.sh"

@test "valid agent id passes validation" {
  run new_agent_is_valid_id "ralph-agent"
  [ "$status" -eq 0 ]
}

@test "invalid agent id rejects uppercase characters" {
  run new_agent_is_valid_id "Invalid-ID"
  [ "$status" -ne 0 ]
}

@test "empty agent id fails validation" {
  run new_agent_is_valid_id ""
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

@test "new-agent --no-interactive scaffolds cursor agent inside temp repo" {
  repo="$(mktemp -d)"
  bundle_root="$repo/bundle"
  mkdir -p "$bundle_root/.cursor/agents" "$bundle_root/.claude/agents" "$bundle_root/.codex/agents" "$bundle_root/.ralph/bash-lib/select-model" "$bundle_root/.ralph/bash-lib/new-agent" "$bundle_root/.ralph/bash-lib/agent-source"
  mkdir -p "$bundle_root/scripts"
  ln -s "$REPO_ROOT/bundle/.ralph/bash-lib/select-model/select-model-common.sh" "$bundle_root/.ralph/bash-lib/select-model/select-model-common.sh"
  ln -s "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-normalize.sh" "$bundle_root/.ralph/bash-lib/runtime-normalize.sh"
  ln -s "$REPO_ROOT/bundle/.ralph/bash-lib/agent-source/frontmatter.sh" "$bundle_root/.ralph/bash-lib/agent-source/frontmatter.sh"
  ln -s "$REPO_ROOT/bundle/.ralph/bash-lib/select-model/select-model-cursor.sh" "$bundle_root/.ralph/bash-lib/select-model/select-model-cursor.sh"
  ln -s "$REPO_ROOT/bundle/.ralph/bash-lib/select-model/select-model-claude.sh" "$bundle_root/.ralph/bash-lib/select-model/select-model-claude.sh"
  ln -s "$REPO_ROOT/bundle/.ralph/bash-lib/select-model/select-model-codex.sh" "$bundle_root/.ralph/bash-lib/select-model/select-model-codex.sh"
  ln -s "$REPO_ROOT/bundle/.ralph/bash-lib/select-model/select-model-opencode.sh" "$bundle_root/.ralph/bash-lib/select-model/select-model-opencode.sh"
  ln -s "$REPO_ROOT/bundle/.ralph/bash-lib/select-model/select-model-antigravity.sh" "$bundle_root/.ralph/bash-lib/select-model/select-model-antigravity.sh"
  ln -s "$REPO_ROOT/bundle/.ralph/bash-lib/new-agent/new-agent.sh" "$bundle_root/.ralph/bash-lib/new-agent/new-agent.sh"
  ln -s "$REPO_ROOT/bundle/.ralph/bash-lib/new-agent/new-agent-writers.sh" "$bundle_root/.ralph/bash-lib/new-agent/new-agent-writers.sh"
  ln -s "$REPO_ROOT/bundle/.ralph/bash-lib/new-agent/new-agent-helpers.sh" "$bundle_root/.ralph/bash-lib/new-agent/new-agent-helpers.sh"
  ln -s "$REPO_ROOT/bundle/.ralph/new-agent.sh" "$bundle_root/.ralph/new-agent.sh"
  ln -s "$REPO_ROOT/scripts/sync-runtime-assets.sh" "$bundle_root/scripts/sync-runtime-assets.sh"

  run bash -c 'cd "$1" && printf "%s\n%s\n" test-agent "Test agent description" | CURSOR_PLAN_MODEL=gpt-5.1 bash .ralph/new-agent.sh --no-interactive' bash "$bundle_root"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Created agent 'test-agent' at:"* ]]

  config_file="$bundle_root/bundle/.cursor/agents/test-agent/config.json"
  [ -f "$config_file" ]
  grep -q '"model": "gpt-5.1"' "$config_file"
  [ ! -e "$bundle_root/bundle/.cursor/agents/test-agent/rules" ]
  [ ! -e "$bundle_root/bundle/.cursor/agents/test-agent/skills" ]
  [ -f "$bundle_root/bundle/.ralph/agents/test-agent.md" ]
  grep -q '^mcp_servers: \[\]$' "$bundle_root/bundle/.ralph/agents/test-agent.md"

  rm -rf "$repo"
}
