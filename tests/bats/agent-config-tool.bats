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

@test "progressive context emits tier1 metadata and stable alwaysApply bodies" {
  local agents_root workspace rules_dir cfg_dir
  agents_root="$(mktemp -d)"
  workspace="$(mktemp -d)"
  rules_dir="$workspace/.cursor/rules"
  cfg_dir="$agents_root/demo"
  mkdir -p "$rules_dir" "$cfg_dir"

  cat > "$rules_dir/always-on.md" <<'RULE'
---
name: always-on
description: Always applied safety rule
alwaysApply: true
---
Always on body.
RULE

  cat > "$rules_dir/optional.md" <<'RULE'
---
name: optional-rule
description: Optional guidance about documentation
alwaysApply: false
---
Optional body should not load for unrelated todos.
RULE

  cat > "$cfg_dir/config.json" <<'CFG'
{
  "name": "demo",
  "model": "gpt-test",
  "description": "demo agent",
  "rules": [
    ".cursor/rules/always-on.md",
    ".cursor/rules/optional.md"
  ],
  "skills": [],
  "output_artifacts": []
}
CFG

  run env RALPH_MODE=ralph RALPH_PROGRESSIVE_CONTEXT=1 RALPH_PROGRESSIVE_CONTEXT_PART=stable \
    RALPH_PROGRESSIVE_CONTEXT_THRESHOLD=999 \
    bash "$(agent_config_tool_path)" context "$agents_root" "demo" "$workspace"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Tier 1 metadata"* ]]
  [[ "$output" == *"Always on body"* ]]
  [[ "$output" != *"Optional body should not load"* ]]

  run env RALPH_MODE=ralph RALPH_PROGRESSIVE_CONTEXT=1 RALPH_PROGRESSIVE_CONTEXT_PART=volatile \
    RALPH_PROGRESSIVE_TODO_TEXT="Write documentation for operators" \
    RALPH_PROGRESSIVE_CONTEXT_THRESHOLD=999 \
    bash "$(agent_config_tool_path)" context "$agents_root" "demo" "$workspace"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Optional body should not load"* ]]

  rm -rf "$agents_root" "$workspace"
}

@test "progressive context loads explicitly mentioned rule in volatile part" {
  local agents_root workspace rules_dir cfg_dir
  agents_root="$(mktemp -d)"
  workspace="$(mktemp -d)"
  rules_dir="$workspace/.cursor/rules"
  cfg_dir="$agents_root/demo"
  mkdir -p "$rules_dir" "$cfg_dir"

  cat > "$rules_dir/optional.md" <<'RULE'
---
name: optional-rule
description: Optional guidance about documentation
alwaysApply: false
---
Optional body for explicit mention test.
RULE

  cat > "$cfg_dir/config.json" <<'CFG'
{
  "name": "demo",
  "model": "gpt-test",
  "description": "demo agent",
  "rules": [".cursor/rules/optional.md"],
  "skills": [],
  "output_artifacts": []
}
CFG

  run env RALPH_MODE=ralph RALPH_PROGRESSIVE_CONTEXT=1 RALPH_PROGRESSIVE_CONTEXT_PART=volatile \
    RALPH_PROGRESSIVE_TODO_TEXT="Apply optional-rule guidance" \
    RALPH_PROGRESSIVE_CONTEXT_THRESHOLD=999 \
    bash "$(agent_config_tool_path)" context "$agents_root" "demo" "$workspace"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Optional body for explicit mention test"* ]]

  rm -rf "$agents_root" "$workspace"
}

@test "reasoning-effort subcommand prints configured value" {
  local agents_root agent_id cfg
  agents_root="$(mktemp -d)"
  agent_id="effort-reader"
  cfg="$agents_root/$agent_id/config.json"
  mkdir -p "$agents_root/$agent_id"
  cat <<CONFIG > "$cfg"
{
  "name": "effort-reader",
  "model": "gpt-test",
  "description": "Agent with reasoning effort",
  "reasoning_effort": "high",
  "rules": ["rule-effort-reader"],
  "skills": ["skill-effort-reader"],
  "output_artifacts": [
    {
      "path": "artifacts/effort-reader.txt",
      "required": true
    }
  ]
}
CONFIG

  run bash "$(agent_config_tool_path)" reasoning-effort "$agents_root" "$agent_id"
  [ "$status" -eq 0 ]
  [ "$output" = "high" ]
  rm -rf "$agents_root"
}

@test "validate rejects invalid reasoning_effort values" {
  local agents_root agent_id cfg
  agents_root="$(mktemp -d)"
  agent_id="bad-effort"
  cfg="$agents_root/$agent_id/config.json"
  mkdir -p "$agents_root/$agent_id"
  cat <<CONFIG > "$cfg"
{
  "name": "bad-effort",
  "model": "gpt-test",
  "description": "Invalid reasoning effort",
  "reasoning_effort": "turbo",
  "rules": ["rule-bad-effort"],
  "skills": ["skill-bad-effort"],
  "output_artifacts": [
    {
      "path": "artifacts/bad-effort.txt",
      "required": true
    }
  ]
}
CONFIG

  run bash "$(agent_config_tool_path)" validate "$agents_root" "$agent_id" "$REPO_ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"reasoning_effort must be one of"* ]]
  rm -rf "$agents_root"
}

