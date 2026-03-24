#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

agent_config_tool_path() {
  echo "$REPO_ROOT/bundle/.ralph/agent-config-tool.sh"
}

@test "required artifacts resolves {{ARTIFACT_NS}} placeholders" {
  local agents_root agent_id cfg
  agents_root="$(mktemp -d)"
  agent_id="artifacts-template"
  cfg="$agents_root/$agent_id/config.json"
  mkdir -p "$agents_root/$agent_id"
  cat <<CONFIG > "$cfg"
{
  "name": "artifacts-template",
  "model": "gpt-test",
  "description": "Agent for template resolution",
  "rules": [
    "rule-ok"
  ],
  "skills": [
    "skill-ok"
  ],
  "output_artifacts": [
    {
      "path": "artifacts/{{ARTIFACT_NS}}/template-path.txt",
      "required": true
    },
    {
      "path": "artifacts/{{PLAN_KEY}}/plan-path.txt"
    }
  ]
}
CONFIG

  run env RALPH_ARTIFACT_NS="resolved-ns" RALPH_PLAN_KEY="plan-123" bash "$(agent_config_tool_path)" required-artifacts "$agents_root" "$agent_id"
  [ "$status" -eq 0 ]
  trimmed="${output%$'\n'}"
  [ "$trimmed" = $'artifacts/resolved-ns/template-path.txt\nartifacts/plan-123/plan-path.txt' ]
  rm -rf "$agents_root"
}

@test "required artifacts only returns required entries" {
  local agents_root agent_id cfg
  agents_root="$(mktemp -d)"
  agent_id="artifacts-required"
  cfg="$agents_root/$agent_id/config.json"
  mkdir -p "$agents_root/$agent_id"
  cat <<CONFIG > "$cfg"
{
  "name": "artifacts-required",
  "model": "gpt-test",
  "description": "Agent for required flag",
  "rules": [
    "rule-ok"
  ],
  "skills": [
    "skill-ok"
  ],
  "output_artifacts": [
    "artifacts/string-entry.txt",
    {
      "path": "artifacts/explicit-required.txt",
      "required": true
    },
    {
      "path": "artifacts/optional.txt",
      "required": false
    },
    {
      "path": "artifacts/implicit-required.txt"
    }
  ]
}
CONFIG

  run bash "$(agent_config_tool_path)" required-artifacts "$agents_root" "$agent_id"
  [ "$status" -eq 0 ]
  trimmed="${output%$'\n'}"
  [ "$trimmed" = $'artifacts/string-entry.txt\nartifacts/explicit-required.txt\nartifacts/implicit-required.txt' ]
  rm -rf "$agents_root"
}
