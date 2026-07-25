#!/usr/bin/env bash
# Interactive wizard: scaffold the same agent ID under .cursor/agents, .claude/agents,
# .codex/agents, .opencode/agents, and Antigravity's dual layout:
# .agents/agents.md for native personas plus .agents/agents/<id>/ for Ralph metadata.
#
# Cursor model listing uses the CLI when available; if that fails (not logged in, etc.),
# the script falls back to a built-in list with no error output.
# Codex: when ~/.codex/auth.json has access_token, models are listed from GET https://api.openai.com/v1/models
# (gpt* ids only); on any failure the built-in Codex model menu is used, with no error output.
# Claude/Codex scaffolds are skipped silently when `claude` / `codex` are not on PATH.
# Opencode scaffolds are skipped silently when `opencode` is not on PATH.
# Antigravity scaffolds are skipped silently when `agy` is not on PATH.
# Set RALPH_NEW_AGENT_ALL=1 to always create all runtimes anyway.
# Set RALPH_NEW_AGENT_CURSOR_ONLY=1 to only create .cursor/agents (ignore claude/codex on PATH).
# --no-interactive: no model prompts; set CURSOR_PLAN_MODEL (required), and if scaffolding other runtimes
#   also their PLAN_MODEL env vars (or only the runtimes you create).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./bash-lib/select-model/select-model-cursor.sh
source "$REPO_ROOT/.ralph/bash-lib/select-model/select-model-cursor.sh"
# shellcheck source=./bash-lib/select-model/select-model-claude.sh
source "$REPO_ROOT/.ralph/bash-lib/select-model/select-model-claude.sh"
# shellcheck source=./bash-lib/select-model/select-model-codex.sh
source "$REPO_ROOT/.ralph/bash-lib/select-model/select-model-codex.sh"
# shellcheck source=./bash-lib/select-model/select-model-opencode.sh
source "$REPO_ROOT/.ralph/bash-lib/select-model/select-model-opencode.sh"
# shellcheck source=./bash-lib/select-model/select-model-antigravity.sh
source "$REPO_ROOT/.ralph/bash-lib/select-model/select-model-antigravity.sh"
# shellcheck source=./bash-lib/new-agent/new-agent.sh
source "$REPO_ROOT/.ralph/bash-lib/new-agent/new-agent.sh"
# shellcheck source=./bash-lib/new-agent/new-agent-writers.sh
source "$REPO_ROOT/.ralph/bash-lib/new-agent/new-agent-writers.sh"
# shellcheck source=./bash-lib/new-agent/new-agent-helpers.sh
source "$REPO_ROOT/.ralph/bash-lib/new-agent/new-agent-helpers.sh"
CURSOR_AGENTS="$REPO_ROOT/.cursor/agents"
CLAUDE_AGENTS="$REPO_ROOT/.claude/agents"
CODEX_AGENTS="$REPO_ROOT/.codex/agents"
OPENCODE_AGENTS="$REPO_ROOT/.opencode/agents"
ANTIGRAVITY_AGENTS="$REPO_ROOT/.agents/agents"

json_string() {
  if command -v python3 >/dev/null 2>&1; then
    # With -c, sys.argv[0] is '-c' and the first positional arg after '--' is sys.argv[2].
    python3 -c 'import json,sys; print(json.dumps(sys.argv[2]))' -- "$1"
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
  .opencode/agents/<id>/
  .agents/agents.md and .agents/agents/<id>/

Options:
  --no-interactive  use pre-set CURSOR_PLAN_MODEL / CLAUDE_PLAN_MODEL / CODEX_PLAN_MODEL /
                    OPENCODE_PLAN_MODEL / ANTIGRAVITY_PLAN_MODEL
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
  :
}

write_claude_agent() {
  :
}

write_codex_agent() {
  :
}

write_opencode_agent() {
  :
}

write_antigravity_agent() {
  :
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

write_opencode_toml() {
  local desc_json
  desc_json="$(json_string "$DESCRIPTION")"
  mkdir -p "$REPO_ROOT/.opencode/agents"
  cat <<EOF >"$REPO_ROOT/.opencode/agents/$AGENT_ID.toml"
# Opencode custom agent: global agent override format.

name = "$AGENT_ID"
description = $desc_json

instructions = """
You are the $AGENT_ID agent. $DESCRIPTION

When invoked:
1. Follow the plan or prompt instructions and respect the no-emoji rule defined in .opencode/rules/no-emoji.md.
2. Use the repo-context skill when you need build/test/run information.
3. Deliver the primary output to .ralph-workspace/artifacts/{{ARTIFACT_NS}}/$AGENT_ID.md as specified by the orchestrator plan.
Do not use emojis in any output.
"""
EOF
}

write_antigravity_toml() {
  write_antigravity_native_agents_entry "$ANTIGRAVITY_DIR" "$AGENT_ID" "$DESCRIPTION"
}

resolve_canonical_layer() {
  if [[ "${RALPH_NEW_AGENT_CANONICAL_SET:-}" == "bundle" ]]; then
    printf '%s\n' "bundle"
    return 0
  fi
  if [[ "${RALPH_NEW_AGENT_CANONICAL_SET:-}" == "root" ]]; then
    printf '%s\n' "root"
    return 0
  fi
  if [[ -d "$REPO_ROOT/agents/agents" ]]; then
    printf '%s\n' "root"
  else
    printf '%s\n' "bundle"
  fi
}

sync_runtime_assets_for_layer() {
  local layer="$1"
  local sync_script="$REPO_ROOT/scripts/sync-runtime-assets.sh"
  if [[ -x "$sync_script" || -f "$sync_script" ]]; then
    bash "$sync_script" --layer "$layer"
  fi
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
  echo "  .opencode/agents/<id>/"
  echo "  .agents/agents.md and .agents/agents/<id>/"
  echo ""

  prompt_agent_id
  read -rp "Description (one line recommended): " DESCRIPTION

  CANONICAL_LAYER="$(resolve_canonical_layer)"
  if [[ "$CANONICAL_LAYER" == "root" ]]; then
    OUTPUT_PREFIX=""
  else
    OUTPUT_PREFIX="bundle"
  fi
  CURSOR_DIR="$(new_agent_workspace_path "$REPO_ROOT" "$OUTPUT_PREFIX" ".cursor" "agents" "$AGENT_ID")"
  CLAUDE_DIR="$(new_agent_workspace_path "$REPO_ROOT" "$OUTPUT_PREFIX" ".claude" "agents" "$AGENT_ID")"
  CODEX_DIR="$(new_agent_workspace_path "$REPO_ROOT" "$OUTPUT_PREFIX" ".codex" "agents" "$AGENT_ID")"
  OPENCODE_DIR="$(new_agent_workspace_path "$REPO_ROOT" "$OUTPUT_PREFIX" ".opencode" "agents" "$AGENT_ID")"
  ANTIGRAVITY_DIR="$(new_agent_workspace_path "$REPO_ROOT" "$OUTPUT_PREFIX" ".agents" "agents" "$AGENT_ID")"
  if [[ "$CANONICAL_LAYER" == "root" ]]; then
    CANONICAL_DIR="$(new_agent_workspace_path "$REPO_ROOT" "agents" "agents")"
  else
    CANONICAL_DIR="$(new_agent_workspace_path "$REPO_ROOT" "bundle" ".ralph" "agents")"
  fi

  resolve_runtimes
  confirm_overwrite_all

  select_models "$NO_INTERACTIVE"

  write_agent_canonical_source "$CANONICAL_DIR" "$AGENT_ID" "$DESCRIPTION" "$CANONICAL_LAYER"
  sync_runtime_assets_for_layer "$CANONICAL_LAYER"

  write_cursor_agent
  [[ "$SCAFFOLD_CLAUDE" -eq 1 ]] && write_claude_agent
  [[ "$SCAFFOLD_CODEX" -eq 1 ]] && write_codex_agent
  [[ "$SCAFFOLD_OPENCODE" -eq 1 ]] && write_opencode_agent
  [[ "$SCAFFOLD_ANTIGRAVITY" -eq 1 ]] && write_antigravity_agent

  echo ""
  echo "Done. Created agent '$AGENT_ID' at:"
  echo "  $CURSOR_DIR"
  [[ "$SCAFFOLD_CLAUDE" -eq 1 ]] && echo "  $CLAUDE_DIR"
  [[ "$SCAFFOLD_CODEX" -eq 1 ]] && echo "  $CODEX_DIR"
  [[ "$SCAFFOLD_OPENCODE" -eq 1 ]] && echo "  $OPENCODE_DIR"
  [[ "$SCAFFOLD_ANTIGRAVITY" -eq 1 ]] && echo "  $ANTIGRAVITY_DIR"
  echo "Canonical source:"
  echo "  $CANONICAL_DIR/$AGENT_ID.md"
  echo ""
  echo "Next: run .ralph/run-plan.sh with required --plan <path> and --agent <name> (or add the agent to orchestration JSON for multi-stage pipelines)."
}

main "$@"
