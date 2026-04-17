#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENTS_DIR="$ROOT_DIR/agents"

prompt_runtimes() {
  echo "Available runtimes: cursor, claude."
  read -rp "Enter runtimes (comma separated, default claude): " raw_runtimes
  raw_runtimes="${raw_runtimes:-claude}"
  IFS=',' read -ra tokens <<< "${raw_runtimes// /}"
  local valid=()
  for token in "${tokens[@]}"; do
    case "$token" in
      cursor | claude)
        valid+=("$token")
        ;;
      '')
        ;;
      *)
        echo "Invalid runtime '$token'. Only 'cursor' and 'claude' are supported."
        prompt_runtimes
        return
        ;;
    esac
  done

  if [ "${#valid[@]}" -eq 0 ]; then
    valid=("claude")
  fi

  RUNTIMES=("${valid[@]}")
}

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
  echo "Model options:"
  echo "  1) gpt-5.1-codex-mini (default)"
  echo "  2) gpt-5.1-turbo"
  echo "  3) Enter custom model"
  read -rp "Select model [1]: " choice
  choice="${choice:-1}"
  case "$choice" in
    1)
      MODEL="gpt-5.1-codex-mini"
      ;;
    2)
      MODEL="gpt-5.1-turbo"
      ;;
    3)
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
  if [ -d "$AGENT_DIR" ] && [ "$(ls -A "$AGENT_DIR" 2>/dev/null || true)" ]; then
    read -rp "Agent '$AGENT_ID' already exists. Overwrite? This will remove existing scaffolding. [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      echo "Aborting without changes."
      exit 1
    fi
    rm -rf "$AGENT_DIR"
  fi
}

prompt_runtimes
prompt_agent_id
select_model
read -rp "Optional description: " DESCRIPTION

AGENT_DIR="$AGENTS_DIR/$AGENT_ID"
RULES_DIR="$AGENT_DIR/rules"
SKILLS_DIR="$AGENT_DIR/skills"

confirm_overwrite

mkdir -p "$RULES_DIR" "$SKILLS_DIR"

cat <<EOF >"$AGENT_DIR/config.json"
{
  "name": "$AGENT_ID",
  "model": "$MODEL",
  "description": "$(printf '%s' "$DESCRIPTION")",
  "rules": [".claude/rules/no-emoji.md"],
  "skills": [".claude/skills/repo-context/SKILL.md"],
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
Use this folder to document agent-specific rules, validation stages, or guardrails. Expand the README with policy references and examples relevant to this agent.
EOF

cat <<'EOF' >"$SKILLS_DIR/README.md"
# Skills

This scaffold is inert until a skill file is referenced from `config.json`.
Use this folder to list agent skills, describe intent, and outline how each skill is expected to behave. Include usage guidance and any constraints that matter for this agent.
EOF

echo "Generated agent scaffold at $AGENT_DIR."
