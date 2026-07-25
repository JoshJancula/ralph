#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

@test "bundle new-agent creates the cursor scaffold with the built-in default model" {
  repo="$(mktemp -d)"
  bundle_root="$repo/bundle"
  mkdir -p "$bundle_root/.cursor/agents" "$bundle_root/.ralph" "$bundle_root/scripts"
  ln -s "$REPO_ROOT/bundle/.ralph/new-agent.sh" "$bundle_root/.ralph/new-agent.sh"
  ln -s "$REPO_ROOT/bundle/.ralph/bash-lib" "$bundle_root/.ralph/bash-lib"
  ln -s "$REPO_ROOT/scripts/sync-runtime-assets.sh" "$bundle_root/scripts/sync-runtime-assets.sh"

  # Runtime wrappers have been removed; use canonical .ralph/new-agent.sh
  run bash -c "cd '$bundle_root' && printf 'cursor-test\nCursor test agent\n' | env CURSOR_PLAN_MODEL='auto' PATH='/usr/bin:/bin' bash '.ralph/new-agent.sh' --no-interactive"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Created agent 'cursor-test' at:"* ]]

  config="$bundle_root/bundle/.cursor/agents/cursor-test/config.json"
  [ -f "$config" ]
  grep -q '"model": "auto"' "$config"
  [ ! -e "$bundle_root/bundle/.cursor/agents/cursor-test/rules" ]
  [ ! -e "$bundle_root/bundle/.cursor/agents/cursor-test/skills" ]

  rm -rf "$repo"
}

@test "bundle new-agent accepts a custom model choice" {
  repo="$(mktemp -d)"
  bundle_root="$repo/bundle"
  mkdir -p "$bundle_root/.claude/agents" "$bundle_root/.ralph" "$bundle_root/scripts"
  ln -s "$REPO_ROOT/bundle/.ralph/new-agent.sh" "$bundle_root/.ralph/new-agent.sh"
  ln -s "$REPO_ROOT/bundle/.ralph/bash-lib" "$bundle_root/.ralph/bash-lib"
  ln -s "$REPO_ROOT/scripts/sync-runtime-assets.sh" "$bundle_root/scripts/sync-runtime-assets.sh"

  # Use --no-interactive with env vars to test model selection.
  run bash -c "cd '$bundle_root' && CURSOR_PLAN_MODEL='gpt-4o' CLAUDE_PLAN_MODEL='claude-custom-model' bash '.ralph/new-agent.sh' --no-interactive <<< \$'claude-test\nClaude test agent\n'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Created agent 'claude-test' at:"* ]]

  config="$bundle_root/bundle/.cursor/agents/claude-test/config.json"
  [ -f "$config" ]
  grep -q '"model": "gpt-4o"' "$config"
  [ ! -e "$bundle_root/bundle/.cursor/agents/claude-test/rules" ]
  [ ! -e "$bundle_root/bundle/.cursor/agents/claude-test/skills" ]

  rm -rf "$repo"
}

@test "bundle new-agent accepts a custom model entry" {
  repo="$(mktemp -d)"
  bundle_root="$repo/bundle"
  mkdir -p "$bundle_root/.codex/agents" "$bundle_root/.ralph" "$bundle_root/scripts"
  ln -s "$REPO_ROOT/bundle/.ralph/new-agent.sh" "$bundle_root/.ralph/new-agent.sh"
  ln -s "$REPO_ROOT/bundle/.ralph/bash-lib" "$bundle_root/.ralph/bash-lib"
  ln -s "$REPO_ROOT/scripts/sync-runtime-assets.sh" "$bundle_root/scripts/sync-runtime-assets.sh"

  # Use --no-interactive with env vars to test model selection.
  run bash -c "cd '$bundle_root' && CURSOR_PLAN_MODEL='gpt-4o' CODEX_PLAN_MODEL='codex-special-model' bash '.ralph/new-agent.sh' --no-interactive <<< \$'codex-test\nCodex test agent\n'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Created agent 'codex-test' at:"* ]]

  config="$bundle_root/bundle/.cursor/agents/codex-test/config.json"
  [ -f "$config" ]
  grep -q '"model": "gpt-4o"' "$config"
  [ ! -e "$bundle_root/bundle/.codex/agents/codex-test/rules" ]
  [ ! -e "$bundle_root/bundle/.codex/agents/codex-test/skills" ]

  rm -rf "$repo"
}

@test "bundle new-agent scaffolds antigravity agent with runtime-specific shape" {
  repo="$(mktemp -d)"
  bundle_root="$repo/bundle"
  mkdir -p "$bundle_root/.agents/agents" "$bundle_root/.ralph" "$bundle_root/scripts"
  ln -s "$REPO_ROOT/bundle/.ralph/new-agent.sh" "$bundle_root/.ralph/new-agent.sh"
  ln -s "$REPO_ROOT/bundle/.ralph/bash-lib" "$bundle_root/.ralph/bash-lib"
  ln -s "$REPO_ROOT/scripts/sync-runtime-assets.sh" "$bundle_root/scripts/sync-runtime-assets.sh"

  run bash -c "cd '$bundle_root' && RALPH_NEW_AGENT_ALL=1 CURSOR_PLAN_MODEL='gpt-5.1-codex-mini' ANTIGRAVITY_PLAN_MODEL='auto' bash '.ralph/new-agent.sh' --no-interactive <<< \$'antigravity-test\nAntigravity test agent\n'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Created agent 'antigravity-test' at:"* ]]

  config="$bundle_root/bundle/.agents/agents/antigravity-test/config.json"
  [ -f "$config" ]
  grep -q '"model": "auto"' "$config"
  grep -q 'efficient-tool-usage.md' "$config"
  grep -q '"output_artifacts"' "$config"
  [ -f "$bundle_root/bundle/.agents/agents/antigravity-test/antigravity-test.md" ]
  grep -q 'model: inherit' "$bundle_root/bundle/.agents/agents/antigravity-test/antigravity-test.md"
  [ -f "$bundle_root/bundle/.agents/agents.md" ]
  grep -q '^## @antigravity-test$' "$bundle_root/bundle/.agents/agents.md"
  grep -q 'Antigravity test agent' "$bundle_root/bundle/.agents/agents.md"

  rm -rf "$repo"
}
