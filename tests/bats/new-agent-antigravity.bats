#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

@test "new-agent --no-interactive scaffolds antigravity agent in temp repo" {
  repo="$(mktemp -d)"
  bundle_root="$repo/bundle"
  mkdir -p "$bundle_root/.agents/agents" "$bundle_root/.ralph" "$bundle_root/scripts"
  ln -s "$REPO_ROOT/bundle/.ralph/new-agent.sh" "$bundle_root/.ralph/new-agent.sh"
  ln -s "$REPO_ROOT/bundle/.ralph/bash-lib" "$bundle_root/.ralph/bash-lib"
  ln -s "$REPO_ROOT/scripts/sync-runtime-assets.sh" "$bundle_root/scripts/sync-runtime-assets.sh"

  run bash -c 'cd "$1" && printf "%s\n%s\n" agy-agent "Antigravity agent" | RALPH_NEW_AGENT_ALL=1 CURSOR_PLAN_MODEL=auto ANTIGRAVITY_PLAN_MODEL="Gemini 3.1 Pro (high)" bash .ralph/new-agent.sh --no-interactive' bash "$bundle_root"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Created agent 'agy-agent' at:"* ]]

  config_file="$bundle_root/bundle/.agents/agents/agy-agent/config.json"
  [ -f "$config_file" ]
  grep -q '"model": "Gemini 3.1 Pro (high)"' "$config_file"
  [ -f "$bundle_root/bundle/.agents/agents/agy-agent/agy-agent.md" ]
  grep -q 'model: inherit' "$bundle_root/bundle/.agents/agents/agy-agent/agy-agent.md"
  [ -f "$bundle_root/bundle/.agents/agents.md" ]
  grep -q '^## @agy-agent$' "$bundle_root/bundle/.agents/agents.md"
  grep -q 'Antigravity agent' "$bundle_root/bundle/.agents/agents.md"
  [ -f "$bundle_root/bundle/.ralph/agents/agy-agent.md" ]

  rm -rf "$repo"
}
