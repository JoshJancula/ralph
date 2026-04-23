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
  mkdir -p "$bundle_root/.cursor/ralph" "$bundle_root/.claude/ralph" "$bundle_root/.codex/ralph" "$bundle_root/.ralph"
  ln -s "$REPO_ROOT/bundle/.cursor/ralph/select-model.sh" "$bundle_root/.cursor/ralph/select-model.sh"
  ln -s "$REPO_ROOT/bundle/.claude/ralph/select-model.sh" "$bundle_root/.claude/ralph/select-model.sh"
  ln -s "$REPO_ROOT/bundle/.codex/ralph/select-model.sh" "$bundle_root/.codex/ralph/select-model.sh"
  ln -s "$REPO_ROOT/bundle/.ralph/bash-lib" "$bundle_root/.ralph/bash-lib"
  ln -s "$REPO_ROOT/bundle/.ralph/new-agent.sh" "$bundle_root/.ralph/new-agent.sh"

  run bash -c "cd '$bundle_root' && printf 'test-agent\nTest agent description\n' | CURSOR_PLAN_MODEL='gpt-5.1' bash '.ralph/new-agent.sh' --no-interactive"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Created agent 'test-agent' at:"* ]]

  config_file="$bundle_root/.cursor/agents/test-agent/config.json"
  [ -f "$config_file" ]
  grep -q '"model": "gpt-5.1"' "$config_file"
  [ -f "$bundle_root/.cursor/agents/test-agent/rules/README.md" ]
  [ -f "$bundle_root/.cursor/agents/test-agent/skills/README.md" ]
  grep -q 'This scaffold is inert until a rules file is referenced from `config.json`.' "$bundle_root/.cursor/agents/test-agent/rules/README.md"
  grep -q 'This scaffold is inert until a skill file is referenced from `config.json`.' "$bundle_root/.cursor/agents/test-agent/skills/README.md"

  rm -rf "$repo"
}
