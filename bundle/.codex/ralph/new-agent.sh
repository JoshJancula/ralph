#!/usr/bin/env bash
# Scaffold a new prebuilt agent under .codex/agents/<id>/ (config, rules/, skills/).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AGENTS_DIR="$REPO_ROOT/.codex/agents"

prompt_agent_id() {
  while true; do
    read -rp "Agent ID (lowercase letters, digits, hyphens): " AGENT_ID
    if [[ -z "$AGENT_ID" ]]; then
      echo "Agent ID cannot be empty."
      continue
    fi
    if [[ "$AGENT_ID" =~ ^[a-z0-9-]+$ ]]; then
      break
    fi
    echo "Invalid agent ID. Only lowercase letters, digits, and hyphens are allowed."
  done
}

select_model() {
  echo "Model options (Codex CLI):"
  echo "  1) auto (default)"
  echo "  2) gpt-5.1-codex-mini"
  echo "  3) gpt-5.1-turbo"
  echo "  4) Enter custom model id"
  read -rp "Select model [1]: " choice
  choice="${choice:-1}"
  case "$choice" in
    1) MODEL="auto" ;;
    2) MODEL="gpt-5.1-codex-mini" ;;
    3) MODEL="gpt-5.1-turbo" ;;
    4)
      read -rp "Enter custom model name: " custom_model
      if [[ -z "$custom_model" ]]; then
        echo "Custom model cannot be empty."
        select_model
        return
      fi
      MODEL="$custom_model"
      ;;
    *)
      echo "Invalid selection."
      select_model
      return
      ;;
  esac
}

confirm_overwrite() {
  if [[ -d "$AGENT_DIR" ]] && [[ -n "$(ls -A "$AGENT_DIR" 2>/dev/null || true)" ]]; then
    read -rp "Agent '$AGENT_ID' already exists. Overwrite? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      echo "Aborting without changes."
      exit 1
    fi
    rm -rf "$AGENT_DIR"
  fi
}

prompt_agent_id
select_model
read -rp "Optional description: " DESCRIPTION

AGENT_DIR="$AGENTS_DIR/$AGENT_ID"
RULES_DIR="$AGENT_DIR/rules"
SKILLS_DIR="$AGENT_DIR/skills"

confirm_overwrite

mkdir -p "$RULES_DIR" "$SKILLS_DIR"

# Codex agents use .codex/rules and .codex/skills only (runtime isolation).
cat <<EOF >"$AGENT_DIR/config.json"
{
  "name": "$AGENT_ID",
  "model": "$MODEL",
  "description": "$(printf '%s' "$DESCRIPTION")",
  "rules": [".codex/rules/no-emoji.md"],
  "skills": [".codex/skills/repo-context/SKILL.md"],
  "output_artifacts": [
    {
      "path": ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/$AGENT_ID.md",
      "required": true
    }
  ]
}
EOF

cat <<'EOF' >"$RULES_DIR/README.md"
# Rules

This scaffold is inert until a rules file is referenced from `config.json`.
Add agent-specific rules here. Global Codex policy stays under `.codex/rules/`.
EOF

cat <<'EOF' >"$SKILLS_DIR/README.md"
# Skills

This scaffold is inert until a skill file is referenced from `config.json`.
List Codex-relevant skills and workflows for this agent.
EOF

echo "Generated Codex agent scaffold at $AGENT_DIR."
