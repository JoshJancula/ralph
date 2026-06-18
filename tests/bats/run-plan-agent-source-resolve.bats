#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

resolve_source_lib="$REPO_ROOT/bundle/.ralph/bash-lib/agent-source/resolve-source.sh"
frontmatter_lib="$REPO_ROOT/bundle/.ralph/bash-lib/agent-source/frontmatter.sh"
adapter_ralph_md="$REPO_ROOT/bundle/.ralph/bash-lib/agent-source/adapters/adapter-ralph-md.sh"
adapter_classic="$REPO_ROOT/bundle/.ralph/bash-lib/agent-source/adapters/adapter-classic-config.sh"
agent_funcs="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-agent.sh"
runtime_normalize="$REPO_ROOT/.ralph/bash-lib/runtime-normalize.sh"
runtime_resolve="$REPO_ROOT/.ralph/bash-lib/runtime-resolve.sh"
agent_config_dir="$REPO_ROOT/.ralph/bash-lib/agent-config"

setup() {
  _tmp="$(mktemp -d)"
  _ws="$_tmp/project"
  mkdir -p "$_ws/.cursor/agents/myagent"
  mkdir -p "$_ws/.claude/agents/myagent"
  mkdir -p "$_ws/.ralph/agents"
  mkdir -p "$_ws/.ralph-workspace/agents"
  mkdir -p "$_ws/.ralph-workspace/artifacts/test/agent-cache"
}

teardown() {
  rm -rf "$_tmp"
  unset RALPH_AGENT_SOURCE RALPH_AGENT_SOURCE_ORDER RALPH_HOME RALPH_DISABLE_GLOBAL_FALLBACK
  unset RALPH_ARTIFACT_NS RALPH_PLAN_KEY RUNTIME AGENT_CONFIG_TOOL AGENTS_ROOT_REL AGENTS_ROOT
}

_load_agent_libs() {
  source "$runtime_normalize"
  source "$runtime_resolve"
  source "$frontmatter_lib"
  source "$resolve_source_lib"
  source "$agent_config_dir/parse-json.sh"
  source "$agent_config_dir/validate.sh"
  source "$adapter_classic"
  source "$adapter_ralph_md"
  source "$agent_funcs"
}

@test "ralph-install .md wins over classic config.json of the same name for model read" {
  cat > "$_ws/.claude/agents/myagent/config.json" <<'CFG'
{
  "name": "myagent",
  "model": "classic-model",
  "description": "classic agent",
  "rules": [],
  "skills": [],
  "output_artifacts": []
}
CFG

  cat > "$_ws/.ralph/agents/myagent.md" <<'MDEOF'
---
name: myagent
description: ralph-md agent
models:
  claude: ralph-md-model
rules: []
skills: []
output_artifacts: []
---

# MyAgent

Agent body.
MDEOF

  _load_agent_libs
  RUNTIME=claude
  AGENT_CONFIG_TOOL="$REPO_ROOT/.ralph/agent-config-tool.sh"
  AGENTS_ROOT_REL=".claude/agents"

  run read_prebuilt_agent_model "$_ws" "myagent"
  [ "$status" -eq 0 ]
  [ "$output" = "ralph-md-model" ]
}

@test "ralph-install .md wins over classic config.json of the same name for context block" {
  cat > "$_ws/.claude/agents/myagent/config.json" <<'CFG'
{
  "name": "myagent",
  "model": "classic-model",
  "description": "classic agent",
  "rules": [],
  "skills": [],
  "output_artifacts": []
}
CFG

  cat > "$_ws/.ralph/agents/myagent.md" <<'MDEOF'
---
name: myagent
description: ralph-md agent
models:
  claude: ralph-md-model
rules: []
skills: []
output_artifacts: []
---

# MyAgent

Agent body.
MDEOF

  _load_agent_libs
  RUNTIME=claude
  AGENT_CONFIG_TOOL="$REPO_ROOT/.ralph/agent-config-tool.sh"
  AGENTS_ROOT_REL=".claude/agents"
  RALPH_ARTIFACT_NS=test

  run format_prebuilt_agent_context_block "$_ws" "myagent"
  [ "$status" -eq 0 ]
  [[ "$output" == *"myagent"* ]]
}

@test "validate_prebuilt_agent_config succeeds for ralph-install .md source" {
  cat > "$_ws/.ralph/agents/myagent.md" <<'MDEOF'
---
name: myagent
description: ralph-md agent
models:
  claude: ralph-md-model
rules: []
skills: []
output_artifacts: []
---

# MyAgent
MDEOF

  _load_agent_libs
  RUNTIME=claude
  AGENT_CONFIG_TOOL="$REPO_ROOT/.ralph/agent-config-tool.sh"
  AGENTS_ROOT_REL=".claude/agents"
  RALPH_ARTIFACT_NS=test

  run validate_prebuilt_agent_config "$_ws" "myagent"
  [ "$status" -eq 0 ]
}

@test "classic-only install is unchanged when no .md exists" {
  cat > "$_ws/.claude/agents/myagent/config.json" <<'CFG'
{
  "name": "myagent",
  "model": "classic-model",
  "description": "classic agent",
  "rules": [],
  "skills": [],
  "output_artifacts": []
}
CFG

  _load_agent_libs
  RUNTIME=claude
  AGENT_CONFIG_TOOL="$REPO_ROOT/.ralph/agent-config-tool.sh"
  AGENTS_ROOT_REL=".claude/agents"

  run read_prebuilt_agent_model "$_ws" "myagent"
  [ "$status" -eq 0 ]
  [ "$output" = "classic-model" ]
}

@test "list_prebuilt_agent_ids merges classic and ralph-md sources" {
  mkdir -p "$_ws/.claude/agents/alpha"
  cat > "$_ws/.claude/agents/alpha/config.json" <<'CFG'
{
  "name": "alpha",
  "model": "alpha-model",
  "description": "alpha agent",
  "rules": [],
  "skills": [],
  "output_artifacts": []
}
CFG

  cat > "$_ws/.ralph/agents/beta.md" <<'MDEOF'
---
name: beta
description: beta agent
models:
  claude: beta-model
rules: []
skills: []
output_artifacts: []
---

# Beta
MDEOF

  _load_agent_libs
  RUNTIME=claude
  AGENT_CONFIG_TOOL="$REPO_ROOT/.ralph/agent-config-tool.sh"
  AGENTS_ROOT_REL=".claude/agents"

  run list_prebuilt_agent_ids "$_ws"
  [ "$status" -eq 0 ]

  local found_alpha=0 found_beta=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" == "alpha" ]] && found_alpha=1
    [[ "$line" == "beta" ]] && found_beta=1
  done <<< "$output"

  [ "$found_alpha" -eq 1 ]
  [ "$found_beta" -eq 1 ]
}

@test "native-md probe wins over classic config.json when ralph-install is absent" {
  cat > "$_ws/.claude/agents/myagent/config.json" <<'CFG'
{
  "name": "myagent",
  "model": "classic-model",
  "description": "classic agent",
  "rules": [],
  "skills": [],
  "output_artifacts": []
}
CFG

  cat > "$_ws/.claude/agents/myagent.md" <<'MDEOF'
---
name: myagent
description: native-md agent
models:
  claude: native-md-model
rules: []
skills: []
output_artifacts: []
---

# MyAgent
MDEOF

  _load_agent_libs
  RUNTIME=claude
  AGENT_CONFIG_TOOL="$REPO_ROOT/.ralph/agent-config-tool.sh"
  AGENTS_ROOT_REL=".claude/agents"

  run read_prebuilt_agent_model "$_ws" "myagent"
  [ "$status" -eq 0 ]
  [ "$output" = "native-md-model" ]
}