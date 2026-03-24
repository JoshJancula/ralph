#!/usr/bin/env bash
# Helpers extracted from new-agent.sh to keep the main script short.
#
# Public interface:
#   agent_dir_nonempty -- true if an agent directory already has files.
#   resolve_runtimes -- which stacks to install into from CLI flags.
#   confirm_overwrite_all -- batch confirm when replacing existing agent dirs.
#   require_model -- prompt until a non-empty model string.
#   select_models -- per-runtime model prompts (or shared default).

agent_dir_nonempty() {
  [[ -d "$1" ]] && [[ -n "$(ls -A "$1" 2>/dev/null || true)" ]]
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

require_model() {
  local name="$1"
  local val="$2"
  if [[ -z "$val" ]]; then
    echo "No model selected for $name. Aborting." >&2
    exit 1
  fi
}

select_models() {
  local no_interactive="$1"
  if [[ "$no_interactive" -eq 1 ]]; then
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
}
