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
