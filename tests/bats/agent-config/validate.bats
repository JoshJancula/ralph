#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

agent_config_tool_path() {
  echo "$REPO_ROOT/bundle/.ralph/agent-config-tool.sh"
}

@test "schema validation rejects a config missing the name" {
  local agents_root agent_id cfg
  agents_root="$(mktemp -d)"
  agent_id="missing-name"
  cfg="$agents_root/$agent_id/config.json"
  mkdir -p "$agents_root/$agent_id"
  cat <<CONFIG > "$cfg"
{
  "model": "gpt-test",
  "description": "Agent without a name",
  "rules": [
    "rule-1"
  ],
  "skills": [
    "skill-1"
  ],
  "output_artifacts": [
    {
      "path": "artifacts/missing-name.txt",
      "required": true
    }
  ]
}
CONFIG

  run bash "$(agent_config_tool_path)" validate "$agents_root" "$agent_id" "$REPO_ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing required key: name"* ]]
  rm -rf "$agents_root"
}

@test "rules array blocks paths that resolve to a .env secret" {
  local agents_root agent_id cfg
  agents_root="$(mktemp -d)"
  agent_id="rules-env"
  cfg="$agents_root/$agent_id/config.json"
  mkdir -p "$agents_root/$agent_id"
  cat <<CONFIG > "$cfg"
{
  "name": "rules-env",
  "model": "gpt-test",
  "description": "Agent with a dangerous rule",
  "rules": [
    "rule-ok",
    "../.env.secret"
  ],
  "skills": [
    "skill-ok"
  ],
  "output_artifacts": [
    {
      "path": "artifacts/rules-env.txt",
      "required": true
    }
  ],
  "allowed_tools": "tool-ok"
}
CONFIG

  run bash "$(agent_config_tool_path)" validate "$agents_root" "$agent_id" "$REPO_ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"rules entry must not reference a .env"* ]]
  rm -rf "$agents_root"
}

@test "allowed_tools validation rejects an empty string" {
  local agents_root agent_id cfg
  agents_root="$(mktemp -d)"
  agent_id="allowed-tools-empty"
  cfg="$agents_root/$agent_id/config.json"
  mkdir -p "$agents_root/$agent_id"
  cat <<CONFIG > "$cfg"
{
  "name": "allowed-tools-empty",
  "model": "gpt-test",
  "description": "Agent with invalid allowed tools",
  "rules": [
    "rule-ok"
  ],
  "skills": [
    "skill-ok"
  ],
  "output_artifacts": [
    {
      "path": "artifacts/allowed-tools-empty.txt",
      "required": true
    }
  ],
  "allowed_tools": ""
}
CONFIG

  run bash "$(agent_config_tool_path)" validate "$agents_root" "$agent_id" "$REPO_ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"allowed_tools must be a non-empty string or a non-empty array"* ]]
  rm -rf "$agents_root"
}
