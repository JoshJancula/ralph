#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../../helper/load-lib.bash"

PLUGIN_ROOT="$REPO_ROOT/plugins/ralph-orchestrator/claude"
NATIVE_SETTINGS="$REPO_ROOT/bundle/.claude/settings.json"
MCP_SERVER="$REPO_ROOT/bundle/.ralph/mcp-server.sh"
CANONICAL_WORKFLOWS=(ralph-doctor ralph-plan ralph-run ralph-status ralph-workflow)
OBSOLETE_WORKFLOWS=(ralph-agents ralph-graph ralph-orchestrate)

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export RALPH_MCP_WORKSPACE="$TEST_TMPDIR/workspace"
  mkdir -p "$RALPH_MCP_WORKSPACE"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

@test "Claude plugin installs with manifest, skill, workflows, MCP, and marketplace" {
  [ -f "$PLUGIN_ROOT/.claude-plugin/plugin.json" ]
  [ -f "$PLUGIN_ROOT/.claude-plugin/marketplace.json" ]
  [ -f "$PLUGIN_ROOT/hooks/hooks.json" ]
  [ -f "$PLUGIN_ROOT/.mcp.json" ]
  [ -d "$PLUGIN_ROOT/skills/repo-context" ]

  jq -e '
    .name == "ralph-orchestrator" and
    .version == "0.1.0-beta.1" and
    (.description | length > 0) and
    .author.name == "Ralph maintainers" and
    has("_generated") == false
  ' "$PLUGIN_ROOT/.claude-plugin/plugin.json"
  jq -e 'has("_generated") == false' "$PLUGIN_ROOT/hooks/hooks.json"
  jq -e 'has("_generated") == false' "$PLUGIN_ROOT/.mcp.json"
  jq -e '
    .name == "ralph-plugins" and
    (.plugins | length) == 1 and
    .plugins[0].name == "ralph-orchestrator" and
    .plugins[0].source == "." and
    .plugins[0].version == "0.1.0-beta.1"
  ' "$PLUGIN_ROOT/.claude-plugin/marketplace.json"

  [ ! -d "$PLUGIN_ROOT/agents" ]
  [ ! -d "$PLUGIN_ROOT/roles" ]
  [ -f "$PLUGIN_ROOT/skills/repo-context/SKILL.md" ]

  jq -e '.mcpServers.ralph.command == "bash" and (.mcpServers.ralph.args | length) == 1' \
    "$PLUGIN_ROOT/.mcp.json"
  local workflow
  for workflow in "${CANONICAL_WORKFLOWS[@]}"; do
    [ -f "$PLUGIN_ROOT/workflows/$workflow.md" ]
    [ -f "$PLUGIN_ROOT/skills/$workflow/SKILL.md" ]
    if [ "$workflow" != "ralph-run" ]; then
      grep -Fq 'CLAUDE_PLUGIN_ROOT' "$PLUGIN_ROOT/workflows/$workflow.md"
    fi
  done
  for workflow in "${OBSOLETE_WORKFLOWS[@]}"; do
    [ ! -e "$PLUGIN_ROOT/workflows/$workflow.md" ]
    [ ! -e "$PLUGIN_ROOT/skills/$workflow/SKILL.md" ]
  done
}

@test "Claude hooks are allowlisted, plugin-root relative, and resolve to files" {
  local command hook_path
  while IFS= read -r command; do
    [[ "$command" == *'${CLAUDE_PLUGIN_ROOT}/hooks/'* ]]
    hook_path="$(sed -n 's/.*CLAUDE_PLUGIN_ROOT}\/\([^"\\]*\).*/\1/p' <<<"$command")"
    [ -n "$hook_path" ]
    [ -f "$PLUGIN_ROOT/$hook_path" ]
  done < <(jq -r '.. | objects | .command? // empty' "$PLUGIN_ROOT/hooks/hooks.json")

  [ "$(jq '[.. | objects | .command? // empty] | length' "$PLUGIN_ROOT/hooks/hooks.json")" -eq 4 ]
}

@test "install and uninstall leave Claude native configuration byte-identical" {
  local before after cache_dir
  before="$(shasum -a 256 "$NATIVE_SETTINGS" | awk '{print $1}')"
  cache_dir="$TEST_TMPDIR/home/.claude/plugins/cache/ralph-orchestrator"
  mkdir -p "$cache_dir"
  cp -R "$PLUGIN_ROOT" "$cache_dir/claude"
  [ -f "$cache_dir/claude/.claude-plugin/plugin.json" ]
  rm -rf "$cache_dir/claude"
  [ ! -e "$cache_dir/claude" ]
  after="$(shasum -a 256 "$NATIVE_SETTINGS" | awk '{print $1}')"
  [ "$before" = "$after" ]
}

@test "Claude MCP startup exposes a valid tools list without nextCursor" {
  local init list response
  init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"claude-lifecycle","version":"1.0"}}}'
  list='{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
  response="$(printf '%s\n%s\n' "$init" "$list" | bash "$MCP_SERVER" 2>/dev/null | grep '"id":2')"
  [ -n "$response" ]
  printf '%s' "$response" | jq -e '.result.tools | type == "array" and length > 0'
  [ "$(printf '%s' "$response" | jq 'has("nextCursor") or (.result | has("nextCursor"))')" = false ]
}
