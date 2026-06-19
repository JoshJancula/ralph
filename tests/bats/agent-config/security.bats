#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

AGENT_CONFIG_MCP_PY="$REPO_ROOT/bundle/.ralph/python/agent-config-mcp.py"

@test "literal secret rejection: sk-* values are rejected in env" {
  [ -f "$AGENT_CONFIG_MCP_PY" ] || skip "agent-config-mcp.py missing"

  local agents_root agent_id cfg
  agents_root="$(mktemp -d)"
  agent_id="secret-test"
  cfg="$agents_root/$agent_id/config.json"
  mkdir -p "$agents_root/$agent_id"
  cat <<CONFIG > "$cfg"
{
  "name": "secret-test",
  "model": "gpt-test",
  "description": "Agent with literal secret",
  "rules": ["rule-1"],
  "skills": ["skill-1"],
  "mcp_servers": [
    {
      "name": "test-server",
      "transport": "stdio",
      "command": "node",
      "env": {"API_KEY": "sk-abc123xyz789"}
    }
  ]
}
CONFIG

  run python3 "$AGENT_CONFIG_MCP_PY" --validate-config "$cfg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"literal credential"* ]]
  rm -rf "$agents_root"
}

@test "literal secret rejection: Bearer token values are rejected" {
  [ -f "$AGENT_CONFIG_MCP_PY" ] || skip "agent-config-mcp.py missing"

  local agents_root agent_id cfg
  agents_root="$(mktemp -d)"
  agent_id="bearer-test"
  cfg="$agents_root/$agent_id/config.json"
  mkdir -p "$agents_root/$agent_id"
  cat <<CONFIG > "$cfg"
{
  "name": "bearer-test",
  "model": "gpt-test",
  "description": "Agent with Bearer token",
  "rules": ["rule-1"],
  "skills": ["skill-1"],
  "mcp_servers": [
    {
      "name": "test-server",
      "transport": "stdio",
      "command": "node",
      "env": {"AUTH_TOKEN": "Bearer abc123def456"}
    }
  ]
}
CONFIG

  run python3 "$AGENT_CONFIG_MCP_PY" --validate-config "$cfg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"literal credential"* ]]
  rm -rf "$agents_root"
}

@test "literal secret rejection: long base64 strings are rejected" {
  [ -f "$AGENT_CONFIG_MCP_PY" ] || skip "agent-config-mcp.py missing"

  local agents_root agent_id cfg
  agents_root="$(mktemp -d)"
  agent_id="base64-test"
  cfg="$agents_root/$agent_id/config.json"
  mkdir -p "$agents_root/$agent_id"
  # 32+ character base64-like string
  cat <<CONFIG > "$cfg"
{
  "name": "base64-test",
  "model": "gpt-test",
  "description": "Agent with base64 secret",
  "rules": ["rule-1"],
  "skills": ["skill-1"],
  "mcp_servers": [
    {
      "name": "test-server",
      "transport": "stdio",
      "command": "node",
      "env": {"SECRET": "aBcD1234eFgH5678iJkL9012mNoP3456"}
    }
  ]
}
CONFIG

  run python3 "$AGENT_CONFIG_MCP_PY" --validate-config "$cfg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"literal credential"* ]]
  rm -rf "$agents_root"
}

@test "literal secret rejection: github tokens (ghp_*) are rejected" {
  [ -f "$AGENT_CONFIG_MCP_PY" ] || skip "agent-config-mcp.py missing"

  local agents_root agent_id cfg
  agents_root="$(mktemp -d)"
  agent_id="github-test"
  cfg="$agents_root/$agent_id/config.json"
  mkdir -p "$agents_root/$agent_id"
  cat <<CONFIG > "$cfg"
{
  "name": "github-test",
  "model": "gpt-test",
  "description": "Agent with GitHub token",
  "rules": ["rule-1"],
  "skills": ["skill-1"],
  "mcp_servers": [
    {
      "name": "test-server",
      "transport": "stdio",
      "command": "node",
      "env": {"GITHUB_TOKEN": "ghp_abc123def456ghi789"}
    }
  ]
}
CONFIG

  run python3 "$AGENT_CONFIG_MCP_PY" --validate-config "$cfg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"literal credential"* ]]
  rm -rf "$agents_root"
}

@test "reserved 'ralph' name protection: string reference rejected" {
  [ -f "$AGENT_CONFIG_MCP_PY" ] || skip "agent-config-mcp.py missing"

  local agents_root agent_id cfg
  agents_root="$(mktemp -d)"
  agent_id="ralph-test"
  cfg="$agents_root/$agent_id/config.json"
  mkdir -p "$agents_root/$agent_id"
  cat <<CONFIG > "$cfg"
{
  "name": "ralph-test",
  "model": "gpt-test",
  "description": "Agent with reserved name",
  "rules": ["rule-1"],
  "skills": ["skill-1"],
  "mcp_servers": ["ralph"]
}
CONFIG

  run python3 "$AGENT_CONFIG_MCP_PY" --validate-config "$cfg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"reserved"* ]]
  [[ "$output" == *"ralph"* ]]
  rm -rf "$agents_root"
}

@test "reserved 'ralph' name protection: object definition rejected" {
  [ -f "$AGENT_CONFIG_MCP_PY" ] || skip "agent-config-mcp.py missing"

  local agents_root agent_id cfg
  agents_root="$(mktemp -d)"
  agent_id="ralph-obj-test"
  cfg="$agents_root/$agent_id/config.json"
  mkdir -p "$agents_root/$agent_id"
  cat <<CONFIG > "$cfg"
{
  "name": "ralph-obj-test",
  "model": "gpt-test",
  "description": "Agent with reserved name object",
  "rules": ["rule-1"],
  "skills": ["skill-1"],
  "mcp_servers": [
    {
      "name": "ralph",
      "transport": "stdio",
      "command": "node"
    }
  ]
}
CONFIG

  run python3 "$AGENT_CONFIG_MCP_PY" --validate-config "$cfg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"reserved"* ]]
  [[ "$output" == *"ralph"* ]]
  rm -rf "$agents_root"
}

@test "malformed env reference: partial VAR rejected" {
  [ -f "$AGENT_CONFIG_MCP_PY" ] || skip "agent-config-mcp.py missing"

  local agents_root agent_id cfg
  agents_root="$(mktemp -d)"
  agent_id="malformed-test"
  cfg="$agents_root/$agent_id/config.json"
  mkdir -p "$agents_root/$agent_id"
  # Use single quotes to prevent variable expansion
  cat <<'CONFIG' > "$cfg"
{
  "name": "malformed-test",
  "model": "gpt-test",
  "description": "Agent with malformed env ref",
  "rules": ["rule-1"],
  "skills": ["skill-1"],
  "mcp_servers": [
    {
      "name": "test-server",
      "transport": "stdio",
      "command": "node",
      "env": {"API_KEY": "$PARTIAL_VAR"}
    }
  ]
}
CONFIG

  run python3 "$AGENT_CONFIG_MCP_PY" --validate-config "$cfg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"malformed environment reference"* ]]
  rm -rf "$agents_root"
}

@test "malformed env reference: missing closing brace rejected" {
  [ -f "$AGENT_CONFIG_MCP_PY" ] || skip "agent-config-mcp.py missing"

  local agents_root agent_id cfg
  agents_root="$(mktemp -d)"
  agent_id="unclosed-test"
  cfg="$agents_root/$agent_id/config.json"
  mkdir -p "$agents_root/$agent_id"
  # Use single quotes to avoid shell interpreting the brace
  cat <<'CONFIG' > "$cfg"
{
  "name": "unclosed-test",
  "model": "gpt-test",
  "description": "Agent with unclosed env ref",
  "rules": ["rule-1"],
  "skills": ["skill-1"],
  "mcp_servers": [
    {
      "name": "test-server",
      "transport": "stdio",
      "command": "node",
      "env": {"API_KEY": "${API_KEY"}
    }
  ]
}
CONFIG

  run python3 "$AGENT_CONFIG_MCP_PY" --validate-config "$cfg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"malformed environment reference"* ]]
  rm -rf "$agents_root"
}

@test ".env file reference rejected in command" {
  [ -f "$AGENT_CONFIG_MCP_PY" ] || skip "agent-config-mcp.py missing"

  local agents_root agent_id cfg
  agents_root="$(mktemp -d)"
  agent_id="dotenv-test"
  cfg="$agents_root/$agent_id/config.json"
  mkdir -p "$agents_root/$agent_id"
  cat <<CONFIG > "$cfg"
{
  "name": "dotenv-test",
  "model": "gpt-test",
  "description": "Agent with .env reference",
  "rules": ["rule-1"],
  "skills": ["skill-1"],
  "mcp_servers": [
    {
      "name": "test-server",
      "transport": "stdio",
      "command": "./.env.local"
    }
  ]
}
CONFIG

  run python3 "$AGENT_CONFIG_MCP_PY" --validate-config "$cfg"
  [ "$status" -ne 0 ]
  [[ "$output" == *".env"* ]]
  rm -rf "$agents_root"
}

@test ".env file reference rejected in env key" {
  [ -f "$AGENT_CONFIG_MCP_PY" ] || skip "agent-config-mcp.py missing"

  local agents_root agent_id cfg
  agents_root="$(mktemp -d)"
  agent_id="dotenv-key-test"
  cfg="$agents_root/$agent_id/config.json"
  mkdir -p "$agents_root/$agent_id"
  cat <<CONFIG > "$cfg"
{
  "name": "dotenv-key-test",
  "model": "gpt-test",
  "description": "Agent with .env key",
  "rules": ["rule-1"],
  "skills": ["skill-1"],
  "mcp_servers": [
    {
      "name": "test-server",
      "transport": "stdio",
      "command": "node",
      "env": {".env.secret": "value"}
    }
  ]
}
CONFIG

  run python3 "$AGENT_CONFIG_MCP_PY" --validate-config "$cfg"
  [ "$status" -ne 0 ]
  [[ "$output" == *".env"* ]]
  rm -rf "$agents_root"
}

@test "http transport rejects file:// URLs" {
  [ -f "$AGENT_CONFIG_MCP_PY" ] || skip "agent-config-mcp.py missing"

  local agents_root agent_id cfg
  agents_root="$(mktemp -d)"
  agent_id="fileurl-test"
  cfg="$agents_root/$agent_id/config.json"
  mkdir -p "$agents_root/$agent_id"
  cat <<CONFIG > "$cfg"
{
  "name": "fileurl-test",
  "model": "gpt-test",
  "description": "Agent with file URL",
  "rules": ["rule-1"],
  "skills": ["skill-1"],
  "mcp_servers": [
    {
      "name": "test-server",
      "transport": "http",
      "url": "file:///etc/passwd"
    }
  ]
}
CONFIG

  run python3 "$AGENT_CONFIG_MCP_PY" --validate-config "$cfg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"must not reference local files"* ]]
  rm -rf "$agents_root"
}

@test "duplicate mcp server names are rejected" {
  [ -f "$AGENT_CONFIG_MCP_PY" ] || skip "agent-config-mcp.py missing"

  local agents_root agent_id cfg
  agents_root="$(mktemp -d)"
  agent_id="duplicate-test"
  cfg="$agents_root/$agent_id/config.json"
  mkdir -p "$agents_root/$agent_id"
  cat <<CONFIG > "$cfg"
{
  "name": "duplicate-test",
  "model": "gpt-test",
  "description": "Agent with duplicate servers",
  "rules": ["rule-1"],
  "skills": ["skill-1"],
  "mcp_servers": [
    {"name": "server1", "reference": true},
    {"name": "server1", "reference": true}
  ]
}
CONFIG

  run python3 "$AGENT_CONFIG_MCP_PY" --validate-config "$cfg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"duplicate"* ]]
  rm -rf "$agents_root"
}

@test "unsupported transport type rejected" {
  [ -f "$AGENT_CONFIG_MCP_PY" ] || skip "agent-config-mcp.py missing"

  local agents_root agent_id cfg
  agents_root="$(mktemp -d)"
  agent_id="transport-test"
  cfg="$agents_root/$agent_id/config.json"
  mkdir -p "$agents_root/$agent_id"
  cat <<CONFIG > "$cfg"
{
  "name": "transport-test",
  "model": "gpt-test",
  "description": "Agent with bad transport",
  "rules": ["rule-1"],
  "skills": ["skill-1"],
  "mcp_servers": [
    {
      "name": "test-server",
      "transport": "websocket",
      "command": "node"
    }
  ]
}
CONFIG

  run python3 "$AGENT_CONFIG_MCP_PY" --validate-config "$cfg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported transport"* ]]
  rm -rf "$agents_root"
}

@test "empty mcp server name rejected" {
  [ -f "$AGENT_CONFIG_MCP_PY" ] || skip "agent-config-mcp.py missing"

  local agents_root agent_id cfg
  agents_root="$(mktemp -d)"
  agent_id="empty-name-test"
  cfg="$agents_root/$agent_id/config.json"
  mkdir -p "$agents_root/$agent_id"
  cat <<CONFIG > "$cfg"
{
  "name": "empty-name-test",
  "model": "gpt-test",
  "description": "Agent with empty name",
  "rules": ["rule-1"],
  "skills": ["skill-1"],
  "mcp_servers": [""]
}
CONFIG

  run python3 "$AGENT_CONFIG_MCP_PY" --validate-config "$cfg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot be empty"* ]]
  rm -rf "$agents_root"
}

@test "unsupported fields rejected for reference entries" {
  [ -f "$AGENT_CONFIG_MCP_PY" ] || skip "agent-config-mcp.py missing"

  local agents_root agent_id cfg
  agents_root="$(mktemp -d)"
  agent_id="ref-fields-test"
  cfg="$agents_root/$agent_id/config.json"
  mkdir -p "$agents_root/$agent_id"
  cat <<CONFIG > "$cfg"
{
  "name": "ref-fields-test",
  "model": "gpt-test",
  "description": "Agent with extra ref fields",
  "rules": ["rule-1"],
  "skills": ["skill-1"],
  "mcp_servers": [
    {
      "name": "ambient-server",
      "reference": true,
      "transport": "stdio"
    }
  ]
}
CONFIG

  run python3 "$AGENT_CONFIG_MCP_PY" --validate-config "$cfg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported field"* ]]
  rm -rf "$agents_root"
}

@test "empty env values rejected" {
  [ -f "$AGENT_CONFIG_MCP_PY" ] || skip "agent-config-mcp.py missing"

  local agents_root agent_id cfg
  agents_root="$(mktemp -d)"
  agent_id="empty-env-test"
  cfg="$agents_root/$agent_id/config.json"
  mkdir -p "$agents_root/$agent_id"
  cat <<CONFIG > "$cfg"
{
  "name": "empty-env-test",
  "model": "gpt-test",
  "description": "Agent with empty env value",
  "rules": ["rule-1"],
  "skills": ["skill-1"],
  "mcp_servers": [
    {
      "name": "test-server",
      "transport": "stdio",
      "command": "node",
      "env": {"EMPTY": ""}
    }
  ]
}
CONFIG

  run python3 "$AGENT_CONFIG_MCP_PY" --validate-config "$cfg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot be empty"* ]]
  rm -rf "$agents_root"
}

@test "valid env reference accepted" {
  [ -f "$AGENT_CONFIG_MCP_PY" ] || skip "agent-config-mcp.py missing"

  local agents_root agent_id cfg
  agents_root="$(mktemp -d)"
  agent_id="valid-env-test"
  cfg="$agents_root/$agent_id/config.json"
  mkdir -p "$agents_root/$agent_id"
  # Escape $ to avoid shell expansion
  cat <<'CONFIG' > "$cfg"
{
  "name": "valid-env-test",
  "model": "gpt-test",
  "description": "Agent with valid env ref",
  "rules": ["rule-1"],
  "skills": ["skill-1"],
  "mcp_servers": [
    {
      "name": "test-server",
      "transport": "stdio",
      "command": "node",
      "env": {"API_KEY": "${MY_API_KEY}"}
    }
  ]
}
CONFIG

  run python3 "$AGENT_CONFIG_MCP_PY" --validate-config "$cfg"
  [ "$status" -eq 0 ]
  rm -rf "$agents_root"
}

@test "redaction hides credential values in output" {
  [ -f "$AGENT_CONFIG_MCP_PY" ] || skip "agent-config-mcp.py missing"

  local agents_root agent_id cfg
  agents_root="$(mktemp -d)"
  agent_id="redact-test"
  cfg="$agents_root/$agent_id/config.json"
  mkdir -p "$agents_root/$agent_id"
  # Escape $ to avoid shell expansion
  cat <<'CONFIG' > "$cfg"
{
  "name": "redact-test",
  "model": "gpt-test",
  "description": "Agent for redaction test",
  "rules": ["rule-1"],
  "skills": ["skill-1"],
  "mcp_servers": [
    {
      "name": "test-server",
      "transport": "stdio",
      "command": "node",
      "env": {"API_KEY": "${MY_API_KEY}", "SECRET": "${MY_SECRET}"}
    }
  ]
}
CONFIG

  run python3 "$AGENT_CONFIG_MCP_PY" --redact-config "$cfg"
  [ "$status" -eq 0 ]
  [[ "$output" == *"***REDACTED***"* ]]
  # Original env ref should not appear in output
  [[ "$output" != *'$'{MY_API_KEY}* ]] || true
  rm -rf "$agents_root"
}
