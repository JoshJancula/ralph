#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

adapter_dir="$REPO_ROOT/bundle/.ralph/bash-lib/agent-source/adapters"
frontmatter_lib="$REPO_ROOT/bundle/.ralph/bash-lib/agent-source/frontmatter.sh"
resolve_lib="$REPO_ROOT/bundle/.ralph/bash-lib/agent-source/resolve-source.sh"
runtime_normalize="$REPO_ROOT/.ralph/bash-lib/runtime-normalize.sh"
runtime_resolve="$REPO_ROOT/.ralph/bash-lib/runtime-resolve.sh"
agent_config_dir="$REPO_ROOT/.ralph/bash-lib/agent-config"

setup() {
  _tmp="$(mktemp -d)"
  _cache="$_tmp/cache"
  mkdir -p "$_cache"
}

teardown() {
  rm -rf "$_tmp"
  unset RALPH_AGENT_SOURCE RALPH_AGENT_SOURCE_ORDER RALPH_HOME RALPH_ARTIFACT_NS RALPH_PLAN_KEY
}

# Load all required libraries in order
_load_libs() {
  source "$runtime_normalize"
  source "$frontmatter_lib"
  source "$resolve_lib"
  source "$agent_config_dir/parse-json.sh"
  source "$agent_config_dir/validate.sh"
  source "$adapter_dir/adapter-classic-config.sh"
  source "$adapter_dir/adapter-ralph-md.sh"
}

# Golden compare: the ralph-md adapter output must be byte-identical to what
# sync-runtime-assets.sh compiles for the same agent+runtime+layer.
_golden_compare() {
  local agent_id="$1"
  local runtime="$2"
  local layer="${3:-bundle}"
  local golden="$REPO_ROOT/bundle/.${runtime}/agents/${agent_id}/config.json"

  if [[ "$runtime" == "antigravity" ]]; then
    golden="$REPO_ROOT/bundle/.agents/agents/${agent_id}/config.json"
  fi

  _load_libs
  local result
  result="$(agent_adapter_ralph_md_to_config_json "$agent_id" "$runtime" "$REPO_ROOT" "$_cache" "$layer")"
  [[ -f "$result" ]] || { echo "adapter did not produce output file" >&2; return 1; }
  [[ -f "$golden" ]] || { echo "golden file missing: $golden" >&2; return 1; }

  diff "$golden" "$result"
}

@test "ralph-md adapter: research agent at claude runtime matches golden config" {
  _golden_compare research claude
}

@test "ralph-md adapter: research agent at codex runtime matches golden config (empty model)" {
  _golden_compare research codex
}

@test "ralph-md adapter: architect agent at claude runtime matches golden config" {
  _golden_compare architect claude
}

@test "ralph-md adapter: research agent at cursor runtime matches golden config (.mdc rules)" {
  _golden_compare research cursor
}

@test "ralph-md adapter: research agent at opencode runtime matches golden config" {
  _golden_compare research opencode
}

@test "ralph-md adapter: research agent at antigravity runtime matches golden config" {
  _golden_compare research antigravity
}

@test "ralph-md adapter: code-review agent at claude runtime matches golden config" {
  _golden_compare code-review claude
}

@test "ralph-md adapter: code-review agent at codex runtime matches golden config" {
  _golden_compare code-review codex
}

@test "ralph-md adapter: architect agent at codex runtime matches golden config (empty model)" {
  _golden_compare architect codex
}

@test "ralph-md adapter: output_artifacts objects match golden (research at claude)" {
  _golden_compare research claude
}

@test "ralph-md adapter: output_artifacts objects match golden (architect at claude)" {
  _golden_compare architect claude
}

@test "ralph-md adapter: security agent at claude runtime matches golden config" {
  _golden_compare security claude
}

@test "ralph-md adapter: security agent at codex runtime matches golden config" {
  _golden_compare security codex
}

@test "classic-config adapter: resolve finds existing config.json" {
  _load_libs
  local runtime_root
  runtime_root="$(ralph_resolve_runtime_root claude "$REPO_ROOT" 2>/dev/null)" || skip "no claude runtime root"
  local config_path="$runtime_root/agents/research/config.json"
  [[ -f "$config_path" ]] || skip "config.json missing at $config_path"
  run agent_adapter_classic_config_resolve research claude "$REPO_ROOT"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "classic-config	$config_path" ]]
}

@test "classic-config adapter: to_config_json copies config to cache" {
  _load_libs
  local runtime_root
  runtime_root="$(ralph_resolve_runtime_root claude "$REPO_ROOT" 2>/dev/null)" || skip "no claude runtime root"
  local config_path="$runtime_root/agents/research/config.json"
  [[ -f "$config_path" ]] || skip "config.json missing at $config_path"
  local result
  result="$(agent_adapter_classic_config_to_config_json research claude "$REPO_ROOT" "$_cache")"
  [[ -f "$result" ]]
  diff "$config_path" "$result"
}

@test "classic-config adapter: resolve returns error for missing agent" {
  _load_libs
  run agent_adapter_classic_config_resolve nonexistent claude "$REPO_ROOT"
  [[ "$status" -eq 1 ]]
}

@test "classic-config adapter: to_config_json requires all arguments" {
  _load_libs
  run agent_adapter_classic_config_to_config_json "" claude "$REPO_ROOT" "$_cache"
  [[ "$status" -eq 2 ]]
}

@test "classic-config adapter: preserves mcp_servers from config.json" {
  _load_libs
  mkdir -p "$_tmp/.claude/agents/classic-mcp"
  cat >"$_tmp/.claude/agents/classic-mcp/config.json" <<'EOF'
{
  "name": "classic-mcp",
  "model": "gpt-test",
  "description": "Classic config with MCP",
  "rules": ["rule-ok"],
  "skills": ["skill-ok"],
  "output_artifacts": [
    {
      "path": "artifacts/classic-mcp.txt",
      "required": true
    }
  ],
  "mcp_servers": [
    {"name": "ambient-server", "reference": true},
    {
      "name": "portable-http",
      "transport": "http",
      "url": "https://example.com/mcp",
      "headers": {"Authorization": "${MCP_TOKEN}"}
    }
  ]
}
EOF

  local result
  result="$(agent_adapter_classic_config_to_config_json classic-mcp claude "$_tmp" "$_cache")"
  [[ -f "$result" ]]
  python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    m = json.load(f).get('mcp_servers', [])
assert len(m) == 2, m
assert m[0]['name'] == 'ambient-server'
assert m[1]['transport'] == 'http'
" "$result"
}

@test "ralph-md adapter: resolve finds bundle canonical .md" {
  _load_libs
  run agent_adapter_ralph_md_resolve research claude "$REPO_ROOT"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "ralph-md	$REPO_ROOT/.ralph/agents/research.md" || "$output" == "ralph-md	$REPO_ROOT/bundle/.ralph/agents/research.md" ]]
}

@test "ralph-md adapter: resolve returns error for nonexistent agent" {
  _load_libs
  run agent_adapter_ralph_md_resolve nonexistent claude "$REPO_ROOT"
  [[ "$status" -eq 1 ]]
}

@test "ralph-md adapter: to_config_json requires all arguments" {
  _load_libs
  run agent_adapter_ralph_md_to_config_json "" claude "$REPO_ROOT" "$_cache"
  [[ "$status" -eq 2 ]]
}

@test "ralph-md adapter: implementation agent at claude runtime matches golden config" {
  _golden_compare implementation claude
}

@test "ralph-md adapter: qa agent at claude runtime matches golden config" {
  _golden_compare qa claude
}

@test "ralph-md adapter: carries mcp_servers from canonical frontmatter to config.json" {
  _load_libs
  mkdir -p "$REPO_ROOT/.ralph-workspace/agents"
  cat >"$REPO_ROOT/.ralph-workspace/agents/mcp-test.md" <<'EOF'
---
description: Agent with MCP
models:
  claude: claude-test
rules:
  - no-emoji
skills:
  - repo-context
mcp_servers:
  - ambient-server
  - name: portable-stdio
    transport: stdio
    command: node
    args:
      - /path/to/server.js
    env:
      API_KEY: "${MY_API_KEY}"
---
Body
EOF
  local result
  result="$(agent_adapter_ralph_md_to_config_json mcp-test claude "$REPO_ROOT" "$_cache" bundle)"
  [[ -f "$result" ]]
  python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    c = json.load(f)
m = c.get('mcp_servers', [])
assert len(m) == 2, m
assert m[0] == {'name': 'ambient-server', 'reference': True}
assert m[1]['name'] == 'portable-stdio'
assert m[1]['transport'] == 'stdio'
assert m[1]['command'] == 'node'
assert m[1]['args'] == ['/path/to/server.js']
assert m[1]['env'] == {'API_KEY': '\${MY_API_KEY}'}, m[1]['env']
" "$result"
  rm -f "$REPO_ROOT/.ralph-workspace/agents/mcp-test.md"
}

@test "ralph-md adapter: omits mcp_servers field when frontmatter absent" {
  _load_libs
  mkdir -p "$REPO_ROOT/.ralph-workspace/agents"
  cat >"$REPO_ROOT/.ralph-workspace/agents/no-mcp.md" <<'EOF'
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
  local result
  result="$(agent_adapter_ralph_md_to_config_json no-mcp claude "$REPO_ROOT" "$_cache" bundle)"
  [[ -f "$result" ]]
  ! python3 -c "import json,sys; print('mcp_servers' in json.load(open(sys.argv[1])))" "$result" | grep -q True
  rm -f "$REPO_ROOT/.ralph-workspace/agents/no-mcp.md"
}

@test "ralph-md adapter: empty mcp_servers array omits field for backward compatibility" {
  _load_libs
  mkdir -p "$REPO_ROOT/.ralph-workspace/agents"
  cat >"$REPO_ROOT/.ralph-workspace/agents/empty-mcp.md" <<'EOF'
---
description: Empty MCP
models:
  claude: claude-test
rules:
  - no-emoji
skills:
  - repo-context
mcp_servers: []
---
Body
EOF
  local result
  result="$(agent_adapter_ralph_md_to_config_json empty-mcp claude "$REPO_ROOT" "$_cache" bundle)"
  [[ -f "$result" ]]
  ! python3 -c "import json,sys; print('mcp_servers' in json.load(open(sys.argv[1])))" "$result" | grep -q True
  rm -f "$REPO_ROOT/.ralph-workspace/agents/empty-mcp.md"
}
