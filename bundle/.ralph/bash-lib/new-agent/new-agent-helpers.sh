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
  SCAFFOLD_OPENCODE=1
  SCAFFOLD_ANTIGRAVITY=1
  if [[ "${RALPH_NEW_AGENT_CURSOR_ONLY:-}" == "1" ]]; then
    SCAFFOLD_CLAUDE=0
    SCAFFOLD_CODEX=0
    SCAFFOLD_OPENCODE=0
    SCAFFOLD_ANTIGRAVITY=0
    return 0
  fi
  if [[ "${RALPH_NEW_AGENT_ALL:-}" == "1" ]]; then
    return 0
  fi
  command -v claude >/dev/null 2>&1 || SCAFFOLD_CLAUDE=0
  command -v codex >/dev/null 2>&1 || SCAFFOLD_CODEX=0
  command -v opencode >/dev/null 2>&1 || SCAFFOLD_OPENCODE=0
  command -v agy >/dev/null 2>&1 || SCAFFOLD_ANTIGRAVITY=0
  # If the runtime's model helper is not available (partial install / minimal fixture),
  # skip that runtime so the wizard does not fail with an undefined function.
  declare -f select_model_opencode >/dev/null 2>&1 || SCAFFOLD_OPENCODE=0
  declare -f select_model_antigravity >/dev/null 2>&1 || SCAFFOLD_ANTIGRAVITY=0
}

confirm_overwrite_all() {
  local any=0
  agent_dir_nonempty "$CURSOR_DIR" && any=1
  [[ "$SCAFFOLD_CLAUDE" -eq 1 ]] && agent_dir_nonempty "$CLAUDE_DIR" && any=1
  [[ "$SCAFFOLD_CODEX" -eq 1 ]] && agent_dir_nonempty "$CODEX_DIR" && any=1
  [[ "$SCAFFOLD_OPENCODE" -eq 1 ]] && agent_dir_nonempty "$OPENCODE_DIR" && any=1
  [[ "$SCAFFOLD_ANTIGRAVITY" -eq 1 ]] && agent_dir_nonempty "$ANTIGRAVITY_DIR" && any=1
  if [[ "$any" -eq 0 ]]; then
    return 0
  fi
  echo ""
  echo "Agent '$AGENT_ID' already exists in one or more runtimes:"
  agent_dir_nonempty "$CURSOR_DIR" && echo "  - $CURSOR_DIR"
  [[ "$SCAFFOLD_CLAUDE" -eq 1 ]] && agent_dir_nonempty "$CLAUDE_DIR" && echo "  - $CLAUDE_DIR"
  [[ "$SCAFFOLD_CODEX" -eq 1 ]] && agent_dir_nonempty "$CODEX_DIR" && echo "  - $CODEX_DIR"
  [[ "$SCAFFOLD_OPENCODE" -eq 1 ]] && agent_dir_nonempty "$OPENCODE_DIR" && echo "  - $OPENCODE_DIR"
  [[ "$SCAFFOLD_ANTIGRAVITY" -eq 1 ]] && agent_dir_nonempty "$ANTIGRAVITY_DIR" && echo "  - $ANTIGRAVITY_DIR"
  # This stays bespoke (not using ralph_prompt_yesno) because it's a destructive
  # confirmation prompt that should fail safe (no default) and abort immediately.
  read -rp "Overwrite all of the above? Existing scaffolding will be removed. [y/N]: " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborting without changes."
    exit 1
  fi
  agent_dir_nonempty "$CURSOR_DIR" && rm -rf "$CURSOR_DIR"
  [[ "$SCAFFOLD_CLAUDE" -eq 1 ]] && agent_dir_nonempty "$CLAUDE_DIR" && rm -rf "$CLAUDE_DIR"
  [[ "$SCAFFOLD_CODEX" -eq 1 ]] && agent_dir_nonempty "$CODEX_DIR" && rm -rf "$CODEX_DIR"
  [[ "$SCAFFOLD_OPENCODE" -eq 1 ]] && agent_dir_nonempty "$OPENCODE_DIR" && rm -rf "$OPENCODE_DIR"
  [[ "$SCAFFOLD_ANTIGRAVITY" -eq 1 ]] && agent_dir_nonempty "$ANTIGRAVITY_DIR" && rm -rf "$ANTIGRAVITY_DIR"
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
      MODEL_CLAUDE=$(select_model_claude --batch 1 "${CLAUDE_PLAN_MODEL:-}" "")
      require_model "Claude (set CLAUDE_PLAN_MODEL or add a saved model via ralph models add claude)" "$MODEL_CLAUDE"
    fi
    if [[ "$SCAFFOLD_CODEX" -eq 1 ]]; then
      MODEL_CODEX=$(select_model_codex --batch 1 "${CODEX_PLAN_MODEL:-}" "")
      require_model "Codex (set CODEX_PLAN_MODEL or add a saved model via ralph models add codex)" "$MODEL_CODEX"
    fi
    if [[ "$SCAFFOLD_OPENCODE" -eq 1 ]]; then
      MODEL_OPENCODE=$(select_model_opencode --no-interactive)
      require_model "Opencode (set OPENCODE_PLAN_MODEL)" "$MODEL_OPENCODE"
    fi
    if [[ "$SCAFFOLD_ANTIGRAVITY" -eq 1 ]]; then
      MODEL_ANTIGRAVITY=$(select_model_antigravity --no-interactive)
      require_model "Antigravity (set ANTIGRAVITY_PLAN_MODEL)" "$MODEL_ANTIGRAVITY"
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
    if [[ "$SCAFFOLD_OPENCODE" -eq 1 ]]; then
      MODEL_OPENCODE=$(select_model_opencode --interactive)
      require_model Opencode "$MODEL_OPENCODE"
    fi
    if [[ "$SCAFFOLD_ANTIGRAVITY" -eq 1 ]]; then
      MODEL_ANTIGRAVITY=$(select_model_antigravity --interactive)
      require_model Antigravity "$MODEL_ANTIGRAVITY"
    fi
  fi
}
