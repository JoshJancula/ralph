#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

agent_config_tool_path() {
  echo "$REPO_ROOT/bundle/.ralph/agent-config-tool.sh"
}

agent_config_json() {
  local name="$1"
  cat <<CONFIG
{
  "name": "${name}",
  "model": "gpt-test",
  "description": "${name} agent",
  "rules": [
    "rule-${name}"
  ],
  "skills": [
    "skill-${name}"
  ],
  "output_artifacts": [
    {
      "path": "artifacts/${name}.txt",
      "required": true
    }
  ]
}
CONFIG
}

@test "list subcommand prints sorted agent ids from fixture dirs" {
  local agents_root
  agents_root="$(mktemp -d)"

  for agent_id in zeta alpha beta; do
    mkdir -p "$agents_root/$agent_id"
    agent_config_json "$agent_id" > "$agents_root/$agent_id/config.json"
  done

  run bash "$(agent_config_tool_path)" list "$agents_root"
  [ "$status" -eq 0 ]
  ids=()
  while IFS= read -r line; do
    ids+=("$line")
  done <<< "$output"
  [ "${#ids[@]}" -eq 3 ]
  [ "${ids[0]}" = "alpha" ]
  [ "${ids[1]}" = "beta" ]
  [ "${ids[2]}" = "zeta" ]
  rm -rf "$agents_root"
}

@test "validate subcommand succeeds on a well formed config" {
  local agents_root
  agents_root="$(mktemp -d)"
  local agent_id="validate-me"
  mkdir -p "$agents_root/$agent_id"
  agent_config_json "$agent_id" > "$agents_root/$agent_id/config.json"

  run bash "$(agent_config_tool_path)" validate "$agents_root" "$agent_id" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  rm -rf "$agents_root"
}

@test "mcp-proxy-policy subcommand prints the configured policy name" {
  local agents_root agent_id cfg
  agents_root="$(mktemp -d)"
  agent_id="policy-reader"
  cfg="$agents_root/$agent_id/config.json"
  mkdir -p "$agents_root/$agent_id"
  cat <<CONFIG > "$cfg"
{
  "name": "policy-reader",
  "model": "gpt-test",
  "description": "Agent with a proxy policy",
  "rules": [
    "rule-policy-reader"
  ],
  "skills": [
    "skill-policy-reader"
  ],
  "output_artifacts": [
    {
      "path": "artifacts/policy-reader.txt",
      "required": true
    }
  ],
  "mcp_proxy_policy": "readonly"
}
CONFIG

  run bash "$(agent_config_tool_path)" mcp-proxy-policy "$agents_root" "$agent_id"
  [ "$status" -eq 0 ]
  [ "$output" = "readonly" ]
  rm -rf "$agents_root"
}

@test "mcp-servers subcommand prints redacted normalized JSON" {
  local agents_root agent_id cfg
  agents_root="$(mktemp -d)"
  agent_id="mcp-reader"
  cfg="$agents_root/$agent_id/config.json"
  mkdir -p "$agents_root/$agent_id"
  cat <<CONFIG > "$cfg"
{
  "name": "mcp-reader",
  "model": "gpt-test",
  "description": "Agent with MCP servers",
  "rules": [
    "rule-mcp-reader"
  ],
  "skills": [
    "skill-mcp-reader"
  ],
  "output_artifacts": [
    {
      "path": "artifacts/mcp-reader.txt",
      "required": true
    }
  ],
  "mcp_servers": [
    {"name": "ambient-server", "reference": true},
    {
      "name": "portable-stdio",
      "transport": "stdio",
      "command": "node",
      "args": ["/path/to/server.js"],
      "env": {"API_KEY": "\${MY_API_KEY}"}
    }
  ]
}
CONFIG

  run bash "$(agent_config_tool_path)" mcp-servers "$agents_root" "$agent_id"
  [ "$status" -eq 0 ]
  python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
assert len(data) == 2, data
assert data[0] == {'name': 'ambient-server', 'reference': True}
assert data[1]['name'] == 'portable-stdio'
assert data[1]['env']['API_KEY'] == '***REDACTED***'
" <<<"$output"
  rm -rf "$agents_root"
}

