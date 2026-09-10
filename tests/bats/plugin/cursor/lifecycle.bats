#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../../helper/load-lib.bash"

PLUGIN_ROOT="$REPO_ROOT/plugins/ralph-orchestrator/cursor"
SETUP_HELPERS_SH="$REPO_ROOT/bundle/.ralph/bash-lib/setup/setup-helpers.sh"
SETUP_MCP_SH="$REPO_ROOT/bundle/.ralph/bash-lib/setup/setup-mcp.sh"
CANONICAL_WORKFLOWS=(ralph-doctor ralph-plan ralph-run ralph-status ralph-workflow)
OBSOLETE_WORKFLOWS=(ralph-agents ralph-graph ralph-orchestrate)

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export BUNDLE_ROOT="$REPO_ROOT/bundle"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

@test "Cursor plugin contains manifest, skill, rules, hooks, MCP, workflows, and metadata" {
  [ -f "$PLUGIN_ROOT/host-manifest.json" ]
  [ -f "$PLUGIN_ROOT/.cursor-plugin/plugin.json" ]
  [ -f "$PLUGIN_ROOT/skills/repo-context/SKILL.md" ]
  [ -f "$PLUGIN_ROOT/hooks.json" ]
  [ -f "$PLUGIN_ROOT/mcp.example.json" ]
  [ -f "$PLUGIN_ROOT/.ralph-plugin-generated.json" ]

  [ ! -d "$PLUGIN_ROOT/agents" ]
  [ ! -d "$PLUGIN_ROOT/roles" ]

  local workflow
  for workflow in "${CANONICAL_WORKFLOWS[@]}"; do
    [ -f "$PLUGIN_ROOT/workflows/$workflow.md" ]
    [ -f "$PLUGIN_ROOT/skills/$workflow/SKILL.md" ]
  done
  for workflow in "${OBSOLETE_WORKFLOWS[@]}"; do
    [ ! -e "$PLUGIN_ROOT/workflows/$workflow.md" ]
    [ ! -e "$PLUGIN_ROOT/skills/$workflow/SKILL.md" ]
  done
  [ "$(find "$PLUGIN_ROOT/rules" -maxdepth 1 -type f -name '*.mdc' | wc -l | tr -d ' ')" -eq 2 ]
  [ "$(find "$PLUGIN_ROOT/hooks" -maxdepth 1 -type f -name '*.sh' | wc -l | tr -d ' ')" -eq 7 ]

  jq -e '
    .id == "ralph-orchestrator" and
    .runtime == "cursor" and
    .version == "0.1.0-beta.1" and
    .bootstrap == "shared/ralph-plugin-bootstrap.sh" and
    .exec == "shared/ralph-plugin-exec.sh"
  ' "$PLUGIN_ROOT/host-manifest.json"
  jq -e '
    .name == "ralph-orchestrator" and
    .displayName == "Ralph Orchestrator" and
    .version == "0.1.0-beta.1" and
    .license == "MIT" and
    has("_generated") == false
  ' "$PLUGIN_ROOT/.cursor-plugin/plugin.json"
  jq -e '
    .schemaVersion == 1 and
    .pluginVersion == "0.1.0-beta.1" and
    .sourceDescriptor == "bundle/.ralph/plugin-inputs/adapters/cursor.json" and
    (.generatedPaths | index("skills/repo-context/SKILL.md") != null) and
    (.generatedPaths | index("rules/no-emoji.mdc") != null) and
    (.generatedPaths | index("hooks.json") != null)
  ' "$PLUGIN_ROOT/.ralph-plugin-generated.json"
  jq -e '.mcpServers | type == "array" and length == 1 and .[0].name == "ralph-mcp"' \
    "$PLUGIN_ROOT/mcp.example.json"
  grep -Fq 'scripts/sync-plugin-assets.sh' "$PLUGIN_ROOT/skills/repo-context/SKILL.md"
}

@test "Cursor MCP setup merges Ralph without replacing populated native entries" {
  local project="$TEST_TMPDIR/project"
  local runtime_dir="$project/.cursor"
  mkdir -p "$project/.ralph" "$runtime_dir"
  cp "$REPO_ROOT/bundle/.ralph/mcp-server.sh" "$project/.ralph/mcp-server.sh"
  chmod +x "$project/.ralph/mcp-server.sh"
  cat >"$runtime_dir/mcp.json" <<'EOF'
{
  "mcpServers": {
    "native": {
      "command": "native-server",
      "args": ["--keep"]
    }
  },
  "operatorSetting": {
    "keep": true
  }
}
EOF

  run bash -c '
    set -euo pipefail
    source "$1"
    source "$2"
    setup_mcp_cursor "$3" "$4"
  ' _ "$SETUP_HELPERS_SH" "$SETUP_MCP_SH" "$runtime_dir" "$project"
  [ "$status" -eq 0 ]
  jq -e '
    .mcpServers.native.command == "native-server" and
    .mcpServers.native.args == ["--keep"] and
    .mcpServers.ralph.env.RALPH_MODE == "hybrid" and
    .operatorSetting.keep == true
  ' "$runtime_dir/mcp.json"
}

@test "Cursor owned-copy install and remove leave native project config byte-identical" {
  local project="$TEST_TMPDIR/project"
  local home="$TEST_TMPDIR/home"
  local target="$home/.cursor/plugins/local/ralph-orchestrator"
  local native="$project/.cursor/mcp.json"
  local before after

  mkdir -p "$project/.cursor" "$(dirname "$target")"
  cat >"$native" <<'EOF'
{
  "mcpServers": {
    "native": { "command": "keep-me" }
  }
}
EOF
  before="$(shasum -a 256 "$native" | awk '{print $1}')"

  cp -R "$PLUGIN_ROOT" "$target"
  [ -f "$target/.cursor-plugin/plugin.json" ]
  after="$(shasum -a 256 "$native" | awk '{print $1}')"
  [ "$before" = "$after" ]

  # Simulate a modified copied file remaining after partial drift; package remove
  # of the owned tree must still leave the operator native config untouched.
  printf 'operator-edit\n' >>"$target/hooks.json"
  rm -rf "$target"
  [ ! -e "$target" ]
  after="$(shasum -a 256 "$native" | awk '{print $1}')"
  [ "$before" = "$after" ]
}
