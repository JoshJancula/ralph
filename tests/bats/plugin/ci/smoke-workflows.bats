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
    ! grep -Eq 'ralph-agents|ralph-graph|ralph-orchestrate' "$file"
  done
}

@test "host smokes use adapter-matching native install and discovery surfaces" {
  local claude="$WORKFLOW_DIR/ralph-plugin-smoke-claude.yml"
  local codex="$WORKFLOW_DIR/ralph-plugin-smoke-codex.yml"
  local cursor="$WORKFLOW_DIR/ralph-plugin-smoke-cursor.yml"
  local opencode="$WORKFLOW_DIR/ralph-plugin-smoke-opencode.yml"
  local antigravity="$WORKFLOW_DIR/ralph-plugin-smoke-antigravity.yml"

  # Claude adapter argv (exact).
  grep -q 'claude plugin marketplace add --scope user' "$claude"
  grep -q 'claude plugin install --scope user ralph-orchestrator@ralph-plugins --yes' "$claude"
  grep -q 'claude plugin list --json' "$claude"
  grep -q 'claude plugin uninstall --scope user ralph-orchestrator@ralph-plugins' "$claude"
  grep -q 'claude plugin marketplace remove --scope user ralph-plugins' "$claude"

  # Codex adapter verb shape; smoke marketplace name is isolated for CI.
  grep -q 'codex plugin marketplace add' "$codex"
  grep -q 'codex plugin add ralph-orchestrator@ralph-smoke --json' "$codex"
  grep -q 'codex plugin list --json' "$codex"
  grep -q 'codex plugin remove ralph-orchestrator@ralph-smoke --json' "$codex"
  grep -q 'codex plugin marketplace remove ralph-smoke --json' "$codex"
  ! grep -Eq 'codex plugin (install|uninstall)' "$codex"

  # Cursor adapter owned-copy path.
  grep -q 'https://cursor.com/install' "$cursor"
  grep -q '\.cursor/plugins/local/ralph-orchestrator' "$cursor"
  ! grep -Eq 'cursor-agent plugin (install|list|uninstall)' "$cursor"

  # OpenCode adapter owned paths (plugins + skills only; no agents/).
  grep -q '\.opencode/plugins/ralph-runtime-hooks.ts' "$opencode"
  grep -q '\.opencode/skills' "$opencode"
  ! grep -Eq '\.opencode/agents' "$opencode"
  ! grep -Eq 'opencode plugin (install|list|uninstall)' "$opencode"

  # Antigravity adapter argv (exact).
  grep -q 'https://antigravity.google/cli/install.sh' "$antigravity"
  grep -q 'agy.*plugin install' "$antigravity"
  grep -q 'agy plugin list' "$antigravity"
  grep -q 'agy plugin uninstall' "$antigravity"
}

@test "each smoke mock path covers the four required lifecycle checkpoints" {
  local workflow file block_dir block script
  for workflow in "${WORKFLOWS[@]}"; do
    file="$WORKFLOW_DIR/$workflow"
    if [[ "$workflow" == *codex* ]]; then
      # Codex adapter verbs are marketplace add / plugin add / remove.
      grep -Eq "mock: .*plugin (marketplace add|add)" "$file"
      grep -Eq "mock: .*plugin list" "$file"
      grep -Eq "mock: .*plugin (remove|marketplace remove)" "$file"
    else
      grep -Eq "mock: .*plugin install" "$file"
      grep -Eq "mock: .*plugin list" "$file"
      grep -Eq "mock: .*plugin uninstall" "$file"
    fi
    grep -Eq "mock: .*ralph-doctor" "$file"
    grep -Eq "mock: .*ralph-workflow" "$file"

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
