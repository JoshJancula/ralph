#!/usr/bin/env bash
set -euo pipefail
#
# File generation for .ralph/new-agent.sh.
#
# Public interface:
#   write_agent_scaffold -- create config.json, agent markdown, rule/skill stubs for a runtime.

write_agent_scaffold() {
  local runtime="$1"
  local agent_id="$2"
  local description="$3"
  local model="$4"
  local base_dir="$5"
  local rule_ext="$6"

  local desc_json
  desc_json="$(json_string "$description")"

  mkdir -p "$base_dir/rules" "$base_dir/skills"
  local rules_path=".${runtime}/rules/no-emoji${rule_ext}"
  local skills_path=".${runtime}/skills/repo-context/SKILL.md"
  cat <<EOF >"$base_dir/config.json"
{
  "name": "$agent_id",
  "description": $desc_json,
  "model": "$model",
  "rules": ["$rules_path"],
  "skills": ["$skills_path"],
  "output_artifacts": [
    {
      "path": ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/$agent_id.md",
      "required": true
    }
  ]
}
EOF

  if [[ "$runtime" == "codex" ]]; then
    cat <<'EOF' >"$base_dir/rules/README.md"
# Rules

Add agent-specific rules here. Global Codex policy stays under `.codex/rules/`.
EOF
  else
    cat <<'EOF' >"$base_dir/rules/README.md"
# Rules

Use this folder to document agent-specific rules, validation stages, or guardrails. Expand the README with policy references and examples relevant to this agent.
EOF
  fi

  if [[ "$runtime" == "codex" ]]; then
    cat <<'EOF' >"$base_dir/skills/README.md"
# Skills

List Codex-relevant skills and workflows for this agent.
EOF
  else
    cat <<'EOF' >"$base_dir/skills/README.md"
# Skills

Use this folder to list agent skills, describe intent, and outline how each skill is expected to behave. Include usage guidance and any constraints that matter for this agent.
EOF
  fi
}
