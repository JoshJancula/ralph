#!/usr/bin/env bash
set -euo pipefail
#
# File generation for .ralph/new-agent.sh.
#
# Public interface:
#   write_agent_scaffold -- create config.json and agent markdown for a runtime.
#   runtime_default_model -- return a sensible default model for a runtime.

if ! declare -F ralph_runtime_config_dirname >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../runtime-normalize.sh"
fi

write_agent_scaffold() {
  local runtime="$1"
  local agent_id="$2"
  local description="$3"
  local model="$4"
  local base_dir="$5"
  local rule_ext="$6"
  local agent_template="${7:-}"

  local desc_json
  desc_json="$(json_string "$description")"

  if [[ -z "$model" ]]; then
    model="$(runtime_default_model "$runtime")"
  fi

  local config_dir
  config_dir="$(ralph_runtime_config_dirname "$runtime")"
  local rules_path="${config_dir}/rules/no-emoji${rule_ext}"
  local skills_path="${config_dir}/skills/repo-context/SKILL.md"

  if [[ -n "$agent_template" && -f "$agent_template" ]]; then
    # Use the provided runtime-specific template as-is, substituting placeholders.
    sed \
      -e "s/{{AGENT_ID}}/$agent_id/g" \
      -e "s/{{DESCRIPTION}}/$description/g" \
      -e "s/{{MODEL}}/$model/g" \
      "$agent_template" >"$base_dir/${agent_id}${rule_ext}"
  elif [[ "$runtime" == "antigravity" ]]; then
    # Antigravity agents use the runtime's native profile shape.
    cat <<'EOF' >"$base_dir/${agent_id}${rule_ext}"
---
name: {{AGENT_ID}}
description: {{DESCRIPTION}}
model: inherit
---

## Role
You are the {{AGENT_ID}} agent. {{DESCRIPTION}}

## Constraints
- Read-only: use Read, Grep, Glob, and read-only Bash only; no builds, tests, or edits unless the plan explicitly requests them.
- If a TODO requires reading more than 30 files, summarize progress and mark remaining areas as follow-up.
- Plain ASCII only; no emoji.
- Use the repo-context skill when you need build/test/run information.

## Deliverable
`.ralph-workspace/artifacts/{{ARTIFACT_NS}}/{{AGENT_ID}}.md` -- deliver the requested output.
EOF
    sed -i.bak \
      -e "s/{{AGENT_ID}}/$agent_id/g" \
      -e "s/{{DESCRIPTION}}/$description/g" \
      -e "s/{{MODEL}}/$model/g" \
      "$base_dir/${agent_id}${rule_ext}"
    rm -f "$base_dir/${agent_id}${rule_ext}.bak"
  else
    # Fallback markdown when no template is supplied.
    cat <<'EOF' >"$base_dir/${agent_id}${rule_ext}"
---
name: {{AGENT_ID}}
description: {{DESCRIPTION}}
model: {{MODEL}}
---

## Role
You are the {{AGENT_ID}} agent. {{DESCRIPTION}}

## Constraints
- Plain ASCII only; no emoji.
- Use the repo-context skill when you need build/test/run information.

## Deliverable
`.ralph-workspace/artifacts/{{ARTIFACT_NS}}/{{AGENT_ID}}.md` -- deliver the requested output.
EOF
    sed -i.bak \
      -e "s/{{AGENT_ID}}/$agent_id/g" \
      -e "s/{{DESCRIPTION}}/$description/g" \
      -e "s/{{MODEL}}/$model/g" \
      "$base_dir/${agent_id}${rule_ext}"
    rm -f "$base_dir/${agent_id}${rule_ext}.bak"
  fi

  if [[ "$runtime" == "antigravity" ]]; then
    cat <<EOF >"$base_dir/config.json"
{
  "name": "$agent_id",
  "description": $desc_json,
  "model": "$model",
  "rules": [
    ".agents/rules/no-emoji.md",
    ".agents/rules/efficient-tool-usage.md"
  ],
  "skills": ["$skills_path"],
  "output_artifacts": [
    {
      "path": ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/$agent_id.md",
      "required": true
    }
  ]
}
EOF
    write_antigravity_native_agents_entry "$base_dir" "$agent_id" "$description"
  else
    cat <<EOF >"$base_dir/config.json"
{
  "name": "$agent_id",
  "description": $desc_json,
  "model": "$model",
  "rules": ["$rules_path"],
  "skills": ["$skills_path"]
}
EOF
  fi

}

write_antigravity_native_agents_entry() {
  local base_dir="$1"
  local agent_id="$2"
  local description="$3"
  local agents_root registry

  agents_root="$(cd "$base_dir/.." && pwd)"
  registry="$(cd "$agents_root/.." && pwd)/agents.md"
  if [[ ! -f "$registry" ]]; then
    cat <<'EOF' >"$registry"
# Ralph Antigravity Agent Registry

This file is the Antigravity-native team registry. Ralph also keeps machine-readable metadata under `.agents/agents/<agent-id>/config.json` for `run-plan.sh --agent`, orchestration, MCP catalogs, output artifact validation, and model resolution.
EOF
  fi

  if grep -Eq "^## @[[:space:]]*${agent_id//\//\\/}$|^## @${agent_id//\//\\/}[[:space:]]*$" "$registry"; then
    return 0
  fi

  cat <<EOF >>"$registry"

## @$agent_id
$description

- Follow the corresponding Ralph metadata in \`.agents/agents/$agent_id/config.json\` when this profile is used through \`run-plan.sh --agent $agent_id\`.
- Use \`.agents/rules/\` and \`.agents/skills/\` for Antigravity-native project guidance.
- Plain ASCII only; no emoji.
EOF
}

runtime_default_model() {
  local runtime="$1"
  case "$runtime" in
    cursor) echo "gpt-5.1-codex-mini" ;;
    claude) echo "claude-sonnet-4-6" ;;
    codex) echo "gpt-5-nano" ;;
    opencode) echo "opencode/nemotron-3-super-free" ;;
    antigravity) echo "auto" ;;
    *) echo "auto" ;;
  esac
}

write_agent_scaffold_body() {
  local agent_id="$1"
  local description="$2"
  local deliverable="${3:-${agent_id}.md}"

  cat <<EOF
## Role
You are the ${agent_id} agent. ${description}

## Constraints
- Plain ASCII only; no emoji.
- Use the repo-context skill when you need build/test/run information.
- Keep the change set small and focused on the requested task.

## Deliverable
\`.ralph-workspace/artifacts/{{ARTIFACT_NS}}/${deliverable}\` -- provide the requested output.
EOF
}

yaml_double_quote() {
  local value="${1:-}"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

write_agent_canonical_source() {
  local canonical_root="$1"
  local agent_id="$2"
  local description="$3"
  local canonical_kind="${4:-generic}"
  local canonical_file="$canonical_root/$agent_id.md"
  local rules_block

  mkdir -p "$canonical_root"

  if [[ "$canonical_kind" == "root" ]]; then
    rules_block=$'  - no-emoji\n  - efficient-tool-usage\n  - bundle-vs-root\n  - no-new-dependencies\n  - bash-style\n  - agent-dual-file-sync'
  else
    rules_block=$'  - no-emoji\n  - efficient-tool-usage'
  fi

  cat >"$canonical_file" <<EOF
---
description: $(yaml_double_quote "$description")
models:
  claude: $(yaml_double_quote "${MODEL_CLAUDE:-}")
  cursor: $(yaml_double_quote "${MODEL_CURSOR:-}")
  codex: $(yaml_double_quote "${MODEL_CODEX:-}")
  opencode: $(yaml_double_quote "${MODEL_OPENCODE:-}")
  antigravity: $(yaml_double_quote "${MODEL_ANTIGRAVITY:-auto}")
rules:
${rules_block}
skills:
  - repo-context
output_artifacts:
  - $(yaml_double_quote ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/${agent_id}.md|required|notes")
mcp_servers: []
---
$(write_agent_scaffold_body "$agent_id" "$description" "${agent_id}.md")

## Agent MCP Servers (Optional)

The mcp_servers field declares optional MCP servers for this agent. It accepts:

# String references to ambient servers:
#   - playwright
#   - github
#
# Portable definitions with inline configuration:
#   - name: my-api
#     transport: http
#     url: https://api.example.com/v1/mcp
#     headers:
#       Authorization: \${API_TOKEN}
#   - name: local-tool
#     transport: stdio
#     command: node
#     args:
#       - /path/to/server.js
#     env:
#       API_KEY: \${LOCAL_API_KEY}
#
# Precedence: Native ambient > Agent definitions > Ralph's protected 'ralph' server
# Reserved name: 'ralph' cannot be redefined by agents.
# Secret policy: Use \${ENV_VAR} references; literal secrets are rejected.
#
# See bundle/.claude/agents/README.md for full schema and validation rules.
EOF
}
