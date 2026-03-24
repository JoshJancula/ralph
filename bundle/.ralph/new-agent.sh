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
# shellcheck source=./bash-lib/new-agent-writers.sh
source "$REPO_ROOT/.ralph/bash-lib/new-agent-writers.sh"
# shellcheck source=./bash-lib/new-agent-helpers.sh
source "$REPO_ROOT/.ralph/bash-lib/new-agent-helpers.sh"
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

write_cursor_agent() {
  write_agent_scaffold "cursor" "$AGENT_ID" "$DESCRIPTION" "$MODEL_CURSOR" "$CURSOR_DIR" ".mdc"
}

write_claude_agent() {
  write_agent_scaffold "claude" "$AGENT_ID" "$DESCRIPTION" "$MODEL_CLAUDE" "$CLAUDE_DIR" ".md"
}

write_codex_agent() {
  write_agent_scaffold "codex" "$AGENT_ID" "$DESCRIPTION" "$MODEL_CODEX" "$CODEX_DIR" ".md"
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

  select_models "$NO_INTERACTIVE"

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
