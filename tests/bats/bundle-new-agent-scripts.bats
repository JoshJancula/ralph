#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

@test "bundle cursor new-agent creates the cursor scaffold with the built-in default model" {
  repo="$(mktemp -d)"
  bundle_root="$repo/bundle"
  mkdir -p "$bundle_root/.cursor/ralph" "$bundle_root/.cursor/agents"
  ln -s "$REPO_ROOT/bundle/.cursor/ralph/new-agent.sh" "$bundle_root/.cursor/ralph/new-agent.sh"

  run bash -c "cd '$bundle_root' && printf 'cursor-test\n\n\n' | PATH='/usr/bin:/bin' bash '.cursor/ralph/new-agent.sh'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Generated agent scaffold at"* ]]

  config="$bundle_root/.cursor/agents/cursor-test/config.json"
  [ -f "$config" ]
  grep -q '"model": "auto"' "$config"
  [ -f "$bundle_root/.cursor/agents/cursor-test/rules/README.md" ]
  [ -f "$bundle_root/.cursor/agents/cursor-test/skills/README.md" ]
  grep -q 'This scaffold is inert until a rules file is referenced from `config.json`.' "$bundle_root/.cursor/agents/cursor-test/rules/README.md"
  grep -q 'This scaffold is inert until a skill file is referenced from `config.json`.' "$bundle_root/.cursor/agents/cursor-test/skills/README.md"
  [ ! -d "$bundle_root/.claude/agents" ]
  [ ! -d "$bundle_root/.codex/agents" ]

  rm -rf "$repo"
}

@test "bundle claude new-agent accepts a custom model choice" {
  repo="$(mktemp -d)"
  bundle_root="$repo/bundle"
  mkdir -p "$bundle_root/.claude/ralph" "$bundle_root/.claude/agents"
  ln -s "$REPO_ROOT/bundle/.claude/ralph/new-agent.sh" "$bundle_root/.claude/ralph/new-agent.sh"

  run bash -c "cd '$bundle_root' && printf '\nclaude-test\n3\nclaude-custom-model\n\n' | PATH='/usr/bin:/bin' bash '.claude/ralph/new-agent.sh'"
  [ "$status" -eq 0 ]

  config="$bundle_root/.claude/agents/claude-test/config.json"
  [ -f "$config" ]
  grep -q '"model": "claude-custom-model"' "$config"
  [ -f "$bundle_root/.claude/agents/claude-test/rules/README.md" ]
  [ -f "$bundle_root/.claude/agents/claude-test/skills/README.md" ]
  grep -q 'This scaffold is inert until a rules file is referenced from `config.json`.' "$bundle_root/.claude/agents/claude-test/rules/README.md"
  grep -q 'This scaffold is inert until a skill file is referenced from `config.json`.' "$bundle_root/.claude/agents/claude-test/skills/README.md"

  rm -rf "$repo"
}

@test "bundle codex new-agent accepts a custom model entry" {
  repo="$(mktemp -d)"
  bundle_root="$repo/bundle"
  mkdir -p "$bundle_root/.codex/ralph" "$bundle_root/.codex/agents"
  ln -s "$REPO_ROOT/bundle/.codex/ralph/new-agent.sh" "$bundle_root/.codex/ralph/new-agent.sh"

  run bash -c "cd '$bundle_root' && printf 'codex-test\n4\ncodex-special-model\n\n' | PATH='/usr/bin:/bin' bash '.codex/ralph/new-agent.sh'"
  [ "$status" -eq 0 ]

  config="$bundle_root/.codex/agents/codex-test/config.json"
  [ -f "$config" ]
  grep -q '"model": "codex-special-model"' "$config"
  [ -f "$bundle_root/.codex/agents/codex-test/rules/README.md" ]
  [ -f "$bundle_root/.codex/agents/codex-test/skills/README.md" ]
  grep -q 'This scaffold is inert until a rules file is referenced from `config.json`.' "$bundle_root/.codex/agents/codex-test/rules/README.md"
  grep -q 'This scaffold is inert until a skill file is referenced from `config.json`.' "$bundle_root/.codex/agents/codex-test/skills/README.md"

  rm -rf "$repo"
}
