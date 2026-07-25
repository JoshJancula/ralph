#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

agent_cli_lib="$REPO_ROOT/bundle/.ralph/agent.sh"

setup() {
  _tmp="$(mktemp -d)"
  _ws="$_tmp/project"
  mkdir -p "$_ws/.ralph/agents"
  mkdir -p "$_ws/.ralph-workspace/agents"
  mkdir -p "$_ws/.claude/agents"
  mkdir -p "$_ws/.cursor/agents"
  mkdir -p "$_ws/.codex/agents"
}

teardown() {
  rm -rf "$_tmp"
  unset RALPH_HOME RALPH_ARTIFACT_NS RALPH_PLAN_KEY
}

@test "ralph agent new --ralph creates only canonical file, no sync" {
  source "$agent_cli_lib"

  run agent_cli_new x --ralph "$_ws"
  [ "$status" -eq 0 ]

  # Should create .ralph/agents/x.md
  [[ -f "$_ws/.ralph/agents/x.md" ]]

  # Should contain basic frontmatter
  grep -q "^---$" "$_ws/.ralph/agents/x.md"
  grep -q "^description:" "$_ws/.ralph/agents/x.md"

  # Should NOT run sync-runtime-assets.sh (no .cursor config.json created, no .claude config, etc.)
  [[ ! -f "$_ws/.cursor/agents/x/config.json" ]]
  [[ ! -f "$_ws/.claude/agents/x/config.json" ]]

  # Canonical scaffold includes empty mcp_servers for editors
  grep -q '^mcp_servers: \[\]$' "$_ws/.ralph/agents/x.md"
}

@test "ralph agent new defaults to --ralph when no flag given" {
  source "$agent_cli_lib"

  run agent_cli_new myagent "" "$_ws"
  [ "$status" -eq 0 ]

  [[ -f "$_ws/.ralph/agents/myagent.md" ]]
  [[ ! -f "$_ws/.cursor/agents/myagent/config.json" ]]
}

@test "ralph agent list shows all agent sources with kind annotation" {
  source "$agent_cli_lib"

  # Create agents in different sources
  cat > "$_ws/.ralph/agents/ralph-only.md" <<'EOF'
---
description: Ralph-only agent
---
EOF

  cat > "$_ws/.ralph-workspace/agents/override.md" <<'EOF'
---
description: Override agent
---
EOF

  cat > "$_ws/.claude/agents/native-one.md" <<'EOF'
---
model: claude-opus
description: Native Claude agent
---
EOF

  mkdir -p "$_ws/.cursor/agents/classic"
  echo '{}' > "$_ws/.cursor/agents/classic/config.json"

  run agent_cli_list "$_ws" claude
  [ "$status" -eq 0 ]

  # Should list all agents with kind annotation
  echo "$output" | grep -q "ralph-only"
  echo "$output" | grep -q "override"
  echo "$output" | grep -q "native-one"
  echo "$output" | grep -q "classic"

  # Should show kind (ralph-install, ralph-workspace, native-md, classic-config)
  echo "$output" | grep -q "ralph-install"
}

@test "ralph agent list surfaces shadowing (later sources override earlier)" {
  source "$agent_cli_lib"

  # Create same agent in multiple sources
  cat > "$_ws/.ralph/agents/shared.md" <<'EOF'
---
description: From ralph-install
---
EOF

  cat > "$_ws/.ralph-workspace/agents/shared.md" <<'EOF'
---
description: From workspace
---
EOF

  run agent_cli_list "$_ws" claude
  [ "$status" -eq 0 ]

  # Should show shared only once, annotated as workspace (takes precedence)
  local count
  count=$(echo "$output" | grep -c "shared" || echo 0)
  [ "$count" -eq 1 ]
  echo "$output" | grep "shared" | grep -q "ralph-workspace"
}

@test "ralph agent show carries mcp_servers from canonical frontmatter" {
  source "$agent_cli_lib"

  cat > "$_ws/.ralph/agents/mcp-show.md" <<'EOF'
---
description: Agent for show MCP test
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
---
Body
EOF

  run agent_cli_show mcp-show "$_ws" claude
  [ "$status" -eq 0 ]
  python3 -c "
import json, sys
c = json.loads(sys.stdin.read())
m = c.get('mcp_servers', [])
assert len(m) == 2, m
assert m[0] == {'name': 'ambient-server', 'reference': True}
assert m[1]['name'] == 'portable-stdio'
" <<<"$output"
}

@test "ralph agent show prints classic-config mcp_servers unchanged" {
  source "$agent_cli_lib"

  mkdir -p "$_ws/.claude/agents/classic-show"
  cat > "$_ws/.claude/agents/classic-show/config.json" <<'EOF'
{
  "name": "classic-show",
  "model": "gpt-test",
  "description": "Classic show test",
  "rules": ["rule-ok"],
  "skills": ["skill-ok"],
  "output_artifacts": [
    {
      "path": "artifacts/classic-show.txt",
      "required": true
    }
  ],
  "mcp_servers": [
    {"name": "ambient-server", "reference": true}
  ]
}
EOF

  run agent_cli_show classic-show "$_ws" claude
  [ "$status" -eq 0 ]
  python3 -c "
import json, sys
c = json.loads(sys.stdin.read())
m = c.get('mcp_servers', [])
assert len(m) == 1 and m[0]['name'] == 'ambient-server', m
" <<<"$output"
}

@test "ralph agent show prints normalized profile for ralph-md source" {
  source "$agent_cli_lib"

  cat > "$_ws/.ralph/agents/testx.md" <<'EOF'
---
description: Test agent for showing
model: claude-opus
rules:
  - no-emoji
  - efficient-tool-usage
skills:
  - repo-context
---

## Role
This is a test agent.
EOF

  run agent_cli_show testx "$_ws" claude
  [ "$status" -eq 0 ]

  # Should output normalized config.json or similar profile
  echo "$output" | grep -q "testx"
  echo "$output" | grep -q "Test agent for showing"
}

@test "ralph agent show fails when agent not found" {
  source "$agent_cli_lib"

  run agent_cli_show nonexistent "$_ws" claude
  [ "$status" -ne 0 ]
}

@test "ralph agent is callable through shim" {
  # This test is integration-level: verifies shim routing
  # The actual verification is in the install.sh case statement
  [[ -f "$REPO_ROOT/install.sh" ]]
  grep -q "agent)" "$REPO_ROOT/install.sh"
}
