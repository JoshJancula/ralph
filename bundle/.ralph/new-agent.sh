#!/usr/bin/env bash
# Interactive wizard: scaffold the same agent ID under .cursor/agents, .claude/agents,
# and .codex/agents with runtime-appropriate config.json, rules/, and skills/.
#
# Cursor model listing uses the CLI when available; if that fails (not logged in, etc.),
# the script falls back to a built-in list with no error output.
# Codex: when ~/.codex/auth.json has access_token, models are listed from GET https://api.openai.com/v1/models
# (gpt* ids only); on any failure the built-in Codex model menu is used, with no error output.
# Claude/Codex scaffolds are skipped silently when `claude` / `codex` are not on PATH.
# Set RALPH_NEW_AGENT_ALL=1 to always create all three runtimes anyway.
# Set RALPH_NEW_AGENT_CURSOR_ONLY=1 to only create .cursor/agents (ignore claude/codex on PATH).
# --no-interactive: no model prompts; set CURSOR_PLAN_MODEL (required), and if scaffolding Claude/Codex
#   also CLAUDE_PLAN_MODEL and CODEX_PLAN_MODEL (or only the runtimes you create).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../.cursor/ralph/select-model.sh
source "$REPO_ROOT/.cursor/ralph/select-model.sh"
# shellcheck source=../.claude/ralph/select-model.sh
source "$REPO_ROOT/.claude/ralph/select-model.sh"
# shellcheck source=../.codex/ralph/select-model.sh
source "$REPO_ROOT/.codex/ralph/select-model.sh"
# shellcheck source=./bash-lib/new-agent.sh
source "$REPO_ROOT/.ralph/bash-lib/new-agent.sh"
CURSOR_AGENTS="$REPO_ROOT/.cursor/agents"
CLAUDE_AGENTS="$REPO_ROOT/.claude/agents"
CODEX_AGENTS="$REPO_ROOT/.codex/agents"

json_string() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' -- "$1"
  else
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    printf '"%s"' "$s"
  fi
}

print_help() {
  cat <<'EOF'
Usage: bash .ralph/new-agent.sh [--no-interactive] [--help]

Creates a matching agent scaffold under
  .cursor/agents/<id>/
  .claude/agents/<id>/
  .codex/agents/<id>/

Options:
  --no-interactive  use pre-set CURSOR_PLAN_MODEL / CLAUDE_PLAN_MODEL / CODEX_PLAN_MODEL
  --help            show this help text and exit
EOF
}

prompt_agent_id() {
  while true; do
    read -rp "Agent ID (lowercase letters, digits, hyphens): " AGENT_ID
    if [[ -z "$AGENT_ID" ]]; then
      echo "Agent ID cannot be empty."
      continue
    fi
    if new_agent_is_valid_id "$AGENT_ID"; then
      break
    fi
    echo "Invalid agent ID. Only lowercase letters, digits, and hyphens are allowed."
  done
}

resolve_runtimes() {
  SCAFFOLD_CLAUDE=1
  SCAFFOLD_CODEX=1
  if [[ "${RALPH_NEW_AGENT_CURSOR_ONLY:-}" == "1" ]]; then
    SCAFFOLD_CLAUDE=0
    SCAFFOLD_CODEX=0
    return 0
  fi
  if [[ "${RALPH_NEW_AGENT_ALL:-}" == "1" ]]; then
    return 0
  fi
  command -v claude >/dev/null 2>&1 || SCAFFOLD_CLAUDE=0
  command -v codex >/dev/null 2>&1 || SCAFFOLD_CODEX=0
}

require_model() {
  local name="$1"
  local val="$2"
  if [[ -z "$val" ]]; then
    echo "No model selected for $name. Aborting." >&2
    exit 1
  fi
}

agent_dir_nonempty() {
  [[ -d "$1" ]] && [[ -n "$(ls -A "$1" 2>/dev/null || true)" ]]
}

confirm_overwrite_all() {
  local any=0
  agent_dir_nonempty "$CURSOR_DIR" && any=1
  [[ "$SCAFFOLD_CLAUDE" -eq 1 ]] && agent_dir_nonempty "$CLAUDE_DIR" && any=1
  [[ "$SCAFFOLD_CODEX" -eq 1 ]] && agent_dir_nonempty "$CODEX_DIR" && any=1
  if [[ "$any" -eq 0 ]]; then
    return 0
  fi
  echo ""
  echo "Agent '$AGENT_ID' already exists in one or more runtimes:"
  agent_dir_nonempty "$CURSOR_DIR" && echo "  - $CURSOR_DIR"
  [[ "$SCAFFOLD_CLAUDE" -eq 1 ]] && agent_dir_nonempty "$CLAUDE_DIR" && echo "  - $CLAUDE_DIR"
  [[ "$SCAFFOLD_CODEX" -eq 1 ]] && agent_dir_nonempty "$CODEX_DIR" && echo "  - $CODEX_DIR"
  read -rp "Overwrite all of the above? Existing scaffolding will be removed. [y/N]: " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborting without changes."
    exit 1
  fi
  agent_dir_nonempty "$CURSOR_DIR" && rm -rf "$CURSOR_DIR"
  [[ "$SCAFFOLD_CLAUDE" -eq 1 ]] && agent_dir_nonempty "$CLAUDE_DIR" && rm -rf "$CLAUDE_DIR"
  [[ "$SCAFFOLD_CODEX" -eq 1 ]] && agent_dir_nonempty "$CODEX_DIR" && rm -rf "$CODEX_DIR"
}

write_cursor_agent() {
  local desc_json
  desc_json="$(json_string "$DESCRIPTION")"
  mkdir -p "$CURSOR_DIR/rules" "$CURSOR_DIR/skills"
  cat <<EOF >"$CURSOR_DIR/config.json"
{
  "name": "$AGENT_ID",
  "description": $desc_json,
  "model": "$MODEL_CURSOR",
  "rules": [".cursor/rules/no-emoji.mdc"],
  "skills": [".cursor/skills/repo-context/SKILL.md"],
  "output_artifacts": [
    {
      "path": ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/$AGENT_ID.md",
      "required": true
    }
  ]
}
EOF
  cat <<'EOF' >"$CURSOR_DIR/rules/README.md"
# Rules

Use this folder to document agent-specific rules, validation stages, or guardrails. Expand the README with policy references and examples relevant to this agent.
EOF
  cat <<'EOF' >"$CURSOR_DIR/skills/README.md"
# Skills

Use this folder to list agent skills, describe intent, and outline how each skill is expected to behave. Include usage guidance and any constraints that matter for this agent.
EOF
}

write_claude_agent() {
  local desc_json
  desc_json="$(json_string "$DESCRIPTION")"
  mkdir -p "$CLAUDE_DIR/rules" "$CLAUDE_DIR/skills"
  cat <<EOF >"$CLAUDE_DIR/config.json"
{
  "name": "$AGENT_ID",
  "model": "$MODEL_CLAUDE",
  "description": $desc_json,
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
  cat <<'EOF' >"$CLAUDE_DIR/rules/README.md"
# Rules

Use this folder to document agent-specific rules, validation stages, or guardrails. Expand the README with policy references and examples relevant to this agent.
EOF
  cat <<'EOF' >"$CLAUDE_DIR/skills/README.md"
# Skills

Use this folder to list agent skills, describe intent, and outline how each skill is expected to behave. Include usage guidance and any constraints that matter for this agent.
EOF
}

write_codex_agent() {
  local desc_json
  desc_json="$(json_string "$DESCRIPTION")"
  mkdir -p "$CODEX_DIR/rules" "$CODEX_DIR/skills"
  cat <<EOF >"$CODEX_DIR/config.json"
{
  "name": "$AGENT_ID",
  "model": "$MODEL_CODEX",
  "description": $desc_json,
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
  cat <<'EOF' >"$CODEX_DIR/rules/README.md"
# Rules

Add agent-specific rules here. Global Codex policy stays under `.codex/rules/`.
EOF
  cat <<'EOF' >"$CODEX_DIR/skills/README.md"
# Skills

List Codex-relevant skills and workflows for this agent.
EOF
}

write_codex_toml() {
  local desc_json
  desc_json="$(json_string "$DESCRIPTION")"
  mkdir -p "$REPO_ROOT/.codex/agents"
  cat <<EOF >"$REPO_ROOT/.codex/agents/$AGENT_ID.toml"
# Codex custom agent: official subagent format (developers.openai.com/codex/subagents)

name = "$AGENT_ID"
description = $desc_json

sandbox_mode = "read-only"

developer_instructions = """
You are the $AGENT_ID agent. $DESCRIPTION

When invoked:
1. Follow the plan or prompt instructions and respect the no-emoji rule defined in .codex/rules/no-emoji.md.
2. Use the repo-context skill when you need build/test/run information.
3. Deliver the primary output to .ralph-workspace/artifacts/{{ARTIFACT_NS}}/$AGENT_ID.md as specified by the orchestrator plan.
Do not use emojis in any output.
"""
EOF
}

main() {
  local NO_INTERACTIVE=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-interactive | --non-interactive)
        NO_INTERACTIVE=1
        shift
        ;;
      --help)
        print_help
        exit 0
        ;;
      *)
        break
        ;;
    esac
  done

  echo "New agent (all runtimes)"
  echo "This creates matching scaffolds under:"
  echo "  .cursor/agents/<id>/"
  echo "  .claude/agents/<id>/"
  echo "  .codex/agents/<id>/"
  echo ""

  prompt_agent_id
  read -rp "Description (one line recommended): " DESCRIPTION

  CURSOR_DIR="$(new_agent_workspace_path "$REPO_ROOT" ".cursor" "agents" "$AGENT_ID")"
  CLAUDE_DIR="$(new_agent_workspace_path "$REPO_ROOT" ".claude" "agents" "$AGENT_ID")"
  CODEX_DIR="$(new_agent_workspace_path "$REPO_ROOT" ".codex" "agents" "$AGENT_ID")"

  resolve_runtimes
  confirm_overwrite_all

  if [[ "$NO_INTERACTIVE" -eq 1 ]]; then
    MODEL_CURSOR=$(select_model_cursor --no-interactive)
    require_model "Cursor (set CURSOR_PLAN_MODEL)" "$MODEL_CURSOR"
    if [[ "$SCAFFOLD_CLAUDE" -eq 1 ]]; then
      MODEL_CLAUDE=$(select_model_claude --no-interactive)
      require_model "Claude (set CLAUDE_PLAN_MODEL)" "$MODEL_CLAUDE"
    fi
    if [[ "$SCAFFOLD_CODEX" -eq 1 ]]; then
      MODEL_CODEX=$(select_model_codex --no-interactive)
      require_model "Codex (set CODEX_PLAN_MODEL)" "$MODEL_CODEX"
    fi
  else
    MODEL_CURSOR=$(select_model_cursor --interactive)
    require_model Cursor "$MODEL_CURSOR"
    if [[ "$SCAFFOLD_CLAUDE" -eq 1 ]]; then
      MODEL_CLAUDE=$(select_model_claude --interactive)
      require_model Claude "$MODEL_CLAUDE"
    fi
    if [[ "$SCAFFOLD_CODEX" -eq 1 ]]; then
      MODEL_CODEX=$(select_model_codex --interactive)
      require_model Codex "$MODEL_CODEX"
    fi
  fi

  write_cursor_agent
  [[ "$SCAFFOLD_CLAUDE" -eq 1 ]] && write_claude_agent
  [[ "$SCAFFOLD_CODEX" -eq 1 ]] && write_codex_agent
  [[ "$SCAFFOLD_CODEX" -eq 1 ]] && write_codex_toml

  echo ""
  echo "Done. Created agent '$AGENT_ID' at:"
  echo "  $CURSOR_DIR"
  [[ "$SCAFFOLD_CLAUDE" -eq 1 ]] && echo "  $CLAUDE_DIR"
  [[ "$SCAFFOLD_CODEX" -eq 1 ]] && echo "  $CODEX_DIR"
  echo ""
  echo "Next: run .ralph/run-plan.sh with required --plan <path> and --agent <name> (or add the agent to orchestration JSON for multi-stage pipelines)."
}

main "$@"
