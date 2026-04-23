#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENTS_DIR="$ROOT_DIR/agents"
CURSOR_CLI=""

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
  local models=()

  detect_cursor_cli
  while IFS= read -r model; do
    [[ -n "$model" ]] && models+=("$model")
  done < <(list_cli_models)

  if [[ ${#models[@]} -eq 0 ]]; then
    models=(
      "auto"
      "gpt-5.1-codex-mini"
      "gpt-5.1-turbo"
      "gpt-5"
      "gpt-4o"
    )
  fi

  local default_index=1
  local i
  for ((i = 0; i < ${#models[@]}; i++)); do
    if [[ "${models[$i]}" == "auto" ]]; then
      default_index=$((i + 1))
      break
    fi
  done

  local custom_index
  custom_index=$((${#models[@]} + 1))

  echo "Model options:"
  for ((i = 0; i < ${#models[@]}; i++)); do
    if [[ $((i + 1)) -eq "$default_index" ]]; then
      echo "  $((i + 1))) ${models[$i]} (default)"
    else
      echo "  $((i + 1))) ${models[$i]}"
    fi
  done
  echo "  $custom_index) Enter custom model"

  while true; do
    read -rp "Select model [$default_index]: " choice
    choice="${choice:-$default_index}"
    if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#models[@]})); then
      MODEL="${models[$((choice - 1))]}"
      return
    fi
    if [[ "$choice" == "$custom_index" ]]; then
      read -rp "Enter custom model name: " custom_model
      if [[ -z "$custom_model" ]]; then
        echo "Custom model cannot be empty."
      else
        MODEL="$custom_model"
        return
      fi
      continue
    fi
    echo "Invalid selection."
  done
}

detect_cursor_cli() {
  if [[ -n "$CURSOR_CLI" ]]; then
    return
  fi
  if command -v cursor-agent >/dev/null 2>&1; then
    CURSOR_CLI="cursor-agent"
  elif command -v agent >/dev/null 2>&1; then
    CURSOR_CLI="agent"
  fi
}

list_cli_models() {
  if [[ -z "$CURSOR_CLI" ]]; then
    return 0
  fi
  "$CURSOR_CLI" --list-models 2>/dev/null \
    | sed -n '1,/^Tip:/p' \
    | sed '/^Tip:/d' \
    | grep -E ' - ' \
    | sed -E 's/[[:space:]]+-[[:space:]]+.*$//' \
    || true
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
  "description": "$(printf '%s' "$DESCRIPTION")",
  "model": "$MODEL",
  "rules": [
    ".cursor/rules/no-emoji.mdc"
  ],
  "skills": [],
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
