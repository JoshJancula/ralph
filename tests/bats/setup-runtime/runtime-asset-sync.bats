#!/usr/bin/env bats
# Drift fixtures for sync-runtime-assets role validation and retired
# six-profile agent generation.

bats_require_minimum_version 1.5.0

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

SYNC_SH="$REPO_ROOT/scripts/sync-runtime-assets.sh"
_RALPH_SIX_IDS=(architect code-review implementation qa research security)

setup() {
  bats_skip_known_ci_flakes
  _tmp="$(mktemp -d)"
}

teardown() {
  rm -rf "${_tmp:-}"
}

# Clean sync fixture: rules/skills + bundled six roles only.
# No canonical agent sources and no generated six-profile agent outputs.
_fixture_sync_repo() {
  local dest="$1"
  local id
  mkdir -p \
    "$dest/agents/rules" \
    "$dest/agents/skills" \
    "$dest/bundle/.ralph/rules" \
    "$dest/bundle/.ralph/skills" \
    "$dest/bundle/.ralph/bash-lib" \
    "$dest/scripts"

  cp "$REPO_ROOT/scripts/sync-runtime-assets.sh" "$dest/scripts/sync-runtime-assets.sh"
  cp "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-normalize.sh" \
    "$dest/bundle/.ralph/bash-lib/runtime-normalize.sh"
  cp "$REPO_ROOT/bundle/.ralph/bash-lib/error-handling.sh" \
    "$dest/bundle/.ralph/bash-lib/error-handling.sh"
  cp "$REPO_ROOT/bundle/.ralph/bash-lib/skill-package.sh" \
    "$dest/bundle/.ralph/bash-lib/skill-package.sh"
  cp "$REPO_ROOT/bundle/.ralph/bash-lib/canonical-frontmatter.sh" \
    "$dest/bundle/.ralph/bash-lib/canonical-frontmatter.sh"

}




@test "agent generation: write mode does not create six-profile native defs" {
  _fixture_sync_repo "$_tmp"
  # Opt-in stale canonical only for this case; clean fixture stays role-only.
  mkdir -p "$_tmp/bundle/.ralph/agents"
  cat >"$_tmp/bundle/.ralph/agents/research.md" <<'EOF'
---
description: Fixture research agent
models:
  claude: claude-test
---
Body
EOF

  run -- env -u REPO_ROOT -u SCRIPT_DIR bash "$_tmp/scripts/sync-runtime-assets.sh" --layer bundle
  [ "$status" -eq 0 ]

  [ ! -e "$_tmp/bundle/.cursor/agents/research" ]
  [ ! -e "$_tmp/bundle/.claude/agents/research" ]
  [ ! -e "$_tmp/bundle/.codex/agents/research" ]
  [ ! -e "$_tmp/bundle/.opencode/agents/research" ]
  [ ! -e "$_tmp/bundle/.agents/agents/research" ]
  [ ! -e "$_tmp/bundle/.agents/agents.md" ]
}

@test "agent generation: --check detects newly generated six-profile output" {
  _fixture_sync_repo "$_tmp"
  mkdir -p "$_tmp/bundle/.ralph/agents"
  cat >"$_tmp/bundle/.ralph/agents/research.md" <<'EOF'
---
description: Fixture research agent
models:
  claude: claude-test
---
Body
EOF

  # Destinations absent while canonical exists => would newly generate.
  run -- env -u REPO_ROOT -u SCRIPT_DIR bash "$_tmp/scripts/sync-runtime-assets.sh" --check --layer bundle
  [ "$status" -ne 0 ]
  [[ "$output" == *"would newly generate six-profile output:"* ]]
  [[ "$output" == *"bundle/.claude/agents/research/research.md"* ]] || \
    [[ "$output" == *"bundle/.cursor/agents/research/research.md"* ]]
}

@test "removed generated profiles: canonical and six-ID dirs are gone" {
  local id base target
  [ ! -d "$REPO_ROOT/agents/agents" ]
  [ ! -d "$REPO_ROOT/bundle/.ralph/agents" ]
  [ ! -e "$REPO_ROOT/.agents/agents.md" ]
  [ ! -e "$REPO_ROOT/bundle/.agents/agents.md" ]

  for base in \
    .cursor .claude .codex .opencode .agents \
    bundle/.cursor bundle/.claude bundle/.codex bundle/.opencode bundle/.agents; do
    for id in "${_RALPH_SIX_IDS[@]}"; do
      target="$REPO_ROOT/$base/agents/$id"
      [ ! -e "$target" ]
    done
    # Containing agent directories remain.
    [ -d "$REPO_ROOT/$base/agents" ]
  done
}

@test "preserve unrelated native agent: sync does not remove non-six-id dirs" {
  local custom_dir custom_file marker
  _fixture_sync_repo "$_tmp"
  custom_dir="$_tmp/bundle/.cursor/agents/my-native-agent"
  custom_file="$custom_dir/my-native-agent.md"
  marker="native-agent-marker-do-not-touch"
  mkdir -p "$custom_dir"
  printf '%s\n' "$marker" >"$custom_file"
  # Six-ID leftover that must also be left alone by sync (generation retired).
  mkdir -p "$_tmp/bundle/.cursor/agents/research"
  printf 'stale-six\n' >"$_tmp/bundle/.cursor/agents/research/research.md"

  run -- env -u REPO_ROOT -u SCRIPT_DIR bash "$_tmp/scripts/sync-runtime-assets.sh" --layer bundle
  [ "$status" -eq 0 ]

  [ -f "$custom_file" ]
  [[ "$(cat "$custom_file")" == "$marker" ]]
  [ -f "$_tmp/bundle/.cursor/agents/research/research.md" ]
  [ -d "$_tmp/bundle/.cursor/agents" ]
}
