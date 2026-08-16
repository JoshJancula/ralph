#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../../helper/load-lib.bash"

WORKFLOW_DIR="$REPO_ROOT/.github/workflows"
WORKFLOWS=(
  ralph-plugin-smoke-claude.yml
  ralph-plugin-smoke-codex.yml
  ralph-plugin-smoke-cursor.yml
  ralph-plugin-smoke-opencode.yml
  ralph-plugin-smoke-antigravity.yml
)

@test "authenticated smoke workflows are valid scheduled/manual host smokes" {
  local workflow file
  for workflow in "${WORKFLOWS[@]}"; do
    file="$WORKFLOW_DIR/$workflow"
    [ -f "$file" ]

    # Ruby's standard YAML parser provides syntax validation without adding a
    # CI dependency. GitHub expressions are scalar values to this parser.
    run ruby -e 'require "yaml"; YAML.parse_file(ARGV.fetch(0))' "$file"
    [ "$status" -eq 0 ]

    grep -Eq '^  schedule:' "$file"
    grep -Eq '^  workflow_dispatch:' "$file"
    ! grep -Eq '^  (push|pull_request|pull_request_target):' "$file"
    ! grep -Eq 'gh[[:space:]]+workflow[[:space:]]+(run|dispatch)' "$file"
    grep -Eq '\$\{\{[[:space:]]*secrets\.[A-Z0-9_]+[[:space:]]*\}\}' "$file"
    grep -q 'add-mask' "$file"
    grep -q 'Smoke discovery' "$file"
    grep -q 'Smoke read-only doctor' "$file"
    grep -q 'Smoke safe workflow' "$file"
    grep -q 'Uninstall repository plugin' "$file"
    grep -q 'RALPH_SMOKE_MOCK' "$file"
  done
}

@test "host smokes use supported native install and discovery surfaces" {
  local codex="$WORKFLOW_DIR/ralph-plugin-smoke-codex.yml"
  local cursor="$WORKFLOW_DIR/ralph-plugin-smoke-cursor.yml"
  local opencode="$WORKFLOW_DIR/ralph-plugin-smoke-opencode.yml"
  local antigravity="$WORKFLOW_DIR/ralph-plugin-smoke-antigravity.yml"

  grep -q 'codex plugin marketplace add' "$codex"
  grep -q 'codex plugin add ralph-orchestrator@ralph-smoke' "$codex"
  grep -q 'codex plugin remove ralph-orchestrator@ralph-smoke' "$codex"
  ! grep -Eq 'codex plugin (install|uninstall)' "$codex"

  grep -q 'https://cursor.com/install' "$cursor"
  grep -q '\.cursor/plugins/local/ralph-orchestrator' "$cursor"
  ! grep -Eq 'cursor-agent plugin (install|list|uninstall)' "$cursor"

  grep -q '\.opencode/plugins/ralph-runtime-hooks.ts' "$opencode"
  grep -q '\.opencode/skills' "$opencode"
  ! grep -Eq 'opencode plugin (install|list|uninstall)' "$opencode"

  grep -q 'https://antigravity.google/cli/install.sh' "$antigravity"
  grep -q 'agy.*plugin install' "$antigravity"
  grep -q 'agy plugin list' "$antigravity"
  grep -q 'agy plugin uninstall' "$antigravity"
}

@test "each smoke mock path covers the four required lifecycle checkpoints" {
  local workflow file block_dir block script
  for workflow in "${WORKFLOWS[@]}"; do
    file="$WORKFLOW_DIR/$workflow"
    grep -Eq "mock: .*plugin install" "$file"
    grep -Eq "mock: .*plugin list" "$file"
    grep -Eq "mock: .*ralph-doctor" "$file"
    grep -Eq "mock: .*ralph-agents" "$file"
    grep -Eq "mock: .*plugin uninstall" "$file"

    # Extract and execute every Actions `run` block with the host mock branch.
    # This exercises the local path without dispatching an authenticated run.
    block_dir="$(mktemp -d)"
    awk -v dir="$block_dir" '
      /^        run: \|$/ { n++; file=dir "/step-" n ".sh"; inrun=1; next }
      inrun && /^        [^ ]/ { inrun=0 }
      inrun && /^          / {
        line=$0
        sub(/^          /, "", line)
        print line >file
      }
      END { if (file != "") close(file) }
    ' "$file"
    for script in "$block_dir"/*.sh; do
      [ -s "$script" ]
      run env \
        RALPH_SMOKE_MOCK=1 \
        ANTHROPIC_API_KEY=mock-anthropic \
        OPENAI_API_KEY=mock-openai \
        CURSOR_API_KEY=mock-cursor \
        ANTIGRAVITY_API_KEY=mock-antigravity \
        GITHUB_WORKSPACE="$REPO_ROOT" \
        RUNNER_TEMP="$block_dir" \
        CODEX_HOME="$block_dir/codex-home" \
        CURSOR_HOME="$block_dir/cursor-home" \
        /bin/bash "$script"
      [ "$status" -eq 0 ]
    done
    rm -rf "$block_dir"
  done
}
