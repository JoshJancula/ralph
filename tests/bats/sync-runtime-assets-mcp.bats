#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

frontmatter_lib="$REPO_ROOT/bundle/.ralph/bash-lib/canonical-frontmatter.sh"
runtime_normalize="$REPO_ROOT/bundle/.ralph/bash-lib/runtime-normalize.sh"

setup() {
  bats_skip_known_ci_flakes
  _tmp="$(mktemp -d)"
  _cache="$_tmp/cache"
  mkdir -p "$_cache"
}

teardown() {
  rm -rf "${_tmp:-}"
}

_source_sync_lib() {
  export SCRIPT_DIR="$REPO_ROOT/scripts"
  # shellcheck disable=SC1090
  eval "$(sed '/^sync_assets_main "\$@"/d' "$REPO_ROOT/scripts/sync-runtime-assets.sh")"
}

_write_mcp_canonical() {
  local dest="$1"
  cat >"$dest" <<'EOF'
---
description: Sync MCP test agent
models:
  claude: claude-test
rules:
  - no-emoji
skills:
  - repo-context
mcp_servers:
  - ambient-server
  - name: portable-http
    transport: http
    url: https://example.com/mcp
    headers:
      Authorization: "${MCP_TOKEN}"
---
Body
EOF
}

@test "sync-runtime-assets --check passes with current generated fixtures" {
  run bash "$REPO_ROOT/scripts/sync-runtime-assets.sh" --check
  [ "$status" -eq 0 ]
}

@test "sync-runtime-assets render rejects profile mcp_servers in canonical frontmatter" {
  _source_sync_lib
  source "$runtime_normalize"
  source "$frontmatter_lib"

  mkdir -p "$_tmp/bundle/.ralph/agents"
  local canonical="$_tmp/bundle/.ralph/agents/mcp-sync.md"
  _write_mcp_canonical "$canonical"

  run sync_assets_render_agent_config_json bundle claude mcp-sync "$canonical" "bundle/.ralph/agents/mcp-sync.md"
  [ "$status" -ne 0 ]
}

@test "sync-runtime-assets render omits mcp_servers when frontmatter absent" {
  _source_sync_lib

  local canonical="$_tmp/no-mcp.md"
  cat >"$canonical" <<'EOF'
---
description: No MCP
models:
  claude: claude-test
rules:
  - no-emoji
skills:
  - repo-context
---
Body
EOF

  local sync_file="$_cache/no-mcp.json"
  sync_assets_render_agent_config_json bundle claude no-mcp "$canonical" "bundle/.ralph/agents/no-mcp.md" >"$sync_file"
  ! python3 -c "import json,sys; print('mcp_servers' in json.load(open(sys.argv[1])))" "$sync_file" | grep -q True
}

@test "skill package validation rejects invalid skill name when enabled" {
  _source_sync_lib
  mkdir -p "$_tmp/bundle/.ralph/skills/bad-name"
  cat >"$_tmp/bundle/.ralph/skills/bad-name/SKILL.md" <<'EOF'
---
name: Bad-Name
description: Invalid package name casing pattern
---
Body
EOF

  REPO_ROOT="$_tmp"
  export REPO_ROOT RALPH_MODE=hybrid RALPH_SKILL_PACKAGE_VALIDATION=1
  run sync_assets_sync_skills_for_layer bundle
  [ "$status" -eq 0 ]
  [[ "$output" == *"skill package validation failed"* ]]
}

@test "skill package validation accepts canonical repo-context skill" {
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/skill-package.sh"
  export RALPH_MODE=hybrid RALPH_SKILL_PACKAGE_VALIDATION=1

  # Guard against a vacuous pass: ralph_validate_skill_package returns 0
  # unconditionally when validation is disabled, so a dropped env gate would
  # make the acceptance assertion below prove nothing. Assert it is active.
  ralph_skill_package_validation_enabled

  run ralph_validate_skill_package "$REPO_ROOT/bundle/.ralph/skills/repo-context" repo-context
  [ "$status" -eq 0 ]
}

@test "sync-runtime-assets copies skill resources deterministically" {
  _source_sync_lib
  mkdir -p "$_tmp/bundle/.ralph/skills/with-resources/scripts"
  cat >"$_tmp/bundle/.ralph/skills/with-resources/SKILL.md" <<'EOF'
---
name: with-resources
description: Skill with bundled scripts
---
Body
EOF
  cat >"$_tmp/bundle/.ralph/skills/with-resources/scripts/run.sh" <<'EOF'
#!/bin/sh
echo ok
EOF
  mkdir -p "$_tmp/bundle/.cursor/skills" "$_tmp/bundle/.claude"

  REPO_ROOT="$_tmp"
  export REPO_ROOT RALPH_MODE=no RALPH_SKILL_PACKAGE_VALIDATION=0
  run sync_assets_sync_skills_for_layer bundle
  [ "$status" -eq 0 ]
  [[ -f "$_tmp/bundle/.cursor/skills/with-resources/scripts/run.sh" ]]
  [[ -f "$_tmp/bundle/.cursor/skills/with-resources/.ralph-sync-manifest.json" ]]
  grep -q '"scripts/run.sh"' "$_tmp/bundle/.cursor/skills/with-resources/.ralph-sync-manifest.json"
}

@test "sync-runtime-assets emits native Claude skill layout when compatible" {
  _source_sync_lib
  mkdir -p "$_tmp/bundle/.ralph/skills/native-skill" "$_tmp/bundle/.claude"
  cat >"$_tmp/bundle/.ralph/skills/native-skill/SKILL.md" <<'EOF'
---
name: native-skill
description: Native Claude skill package
---
Native body
EOF

  REPO_ROOT="$_tmp"
  export REPO_ROOT RALPH_MODE=no RALPH_SKILL_PACKAGE_VALIDATION=0
  run sync_assets_sync_skills_for_layer bundle
  [ "$status" -eq 0 ]
  grep -q 'Native body' "$_tmp/bundle/.claude/skills/native-skill/SKILL.md"
  ! grep -q 'GENERATED from' "$_tmp/bundle/.claude/skills/native-skill/SKILL.md"
}
