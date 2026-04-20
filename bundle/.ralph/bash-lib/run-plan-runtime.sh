# Runtime detection and CLI validation helpers for run-plan.sh (sourced early in run-plan).
#
# Public interface:
#   ralph_shared_ralph_dir_complete, ralph_resolve_shared_ralph_dir -- locate installed .ralph tree.
#   prompt_select_runtime -- interactive runtime picker.
#   ralph_ensure_cursor_cli, ralph_ensure_claude_cli, ralph_ensure_codex_cli -- verify CLIs (exit on failure).

# Determine whether the provided directory contains the shared .ralph tree.
# Args: $1 - path to inspect for the shared directory layout.
# Returns: 0 when the directory hosts the required bash-lib helpers and runner scripts, 1 otherwise.
ralph_shared_ralph_dir_complete() {
  local d="$1"
  if [[ -f "$d/bash-lib/run-plan-env.sh" && -f "$d/ralph-env-safety.sh" \
    && -f "$d/bash-lib/run-plan-invoke-cursor.sh" \
    && -f "$d/bash-lib/run-plan-invoke-claude.sh" \
    && -f "$d/bash-lib/run-plan-invoke-codex.sh" \
    && -f "$d/bash-lib/run-plan-invoke-opencode.sh" ]]; then
    return 0
  fi
  return 1
}

# Resolve the shared .ralph directory by walking ancestors from the starting path.
# Args: $1 - path from which to begin searching for the shared .ralph tree.
# Returns: prints the resolved path and returns 0 when a shared tree is found (or returns the input path when not).
ralph_resolve_shared_ralph_dir() {
  local d="$1"
  local ancestor cand2
  if ralph_shared_ralph_dir_complete "$d"; then
    printf '%s\n' "$d"
    return 0
  fi
  ancestor="$(dirname "$d")"
  while [[ "$ancestor" != "/" ]]; do
    cand2="$ancestor/.ralph"
    if ralph_shared_ralph_dir_complete "$cand2"; then
      printf '%s\n' "$(cd "$cand2" && pwd)"
      return 0
    fi
    ancestor="$(dirname "$ancestor")"
  done
  printf '%s\n' "$d"
}

# Prompt interactively for the runtime to use when it is not provided explicitly.
# Args: none.
# Returns: prints the selected runtime (cursor, claude, or codex) and 0 on success, 1 on failure.
prompt_select_runtime() {
  if [[ "$NON_INTERACTIVE_FLAG" == "1" ]]; then
    echo "Error: runtime must be provided via --runtime or RALPH_PLAN_RUNTIME (cursor, claude, codex, or opencode)." >&2
    return 1
  fi
  if [[ ! -t 0 ]]; then
    echo "Error: runtime must be provided via --runtime or RALPH_PLAN_RUNTIME when stdin is not a terminal." >&2
    return 1
  fi
  ralph_menu_select --prompt "runtime" --default 1 -- cursor claude codex opencode
}

# Ensure the Cursor CLI is installed and available, exiting when it is missing.
# Args: none.
# Returns: sets CURSOR_CLI and exits the script when the CLI cannot be found.
ralph_ensure_cursor_cli() {
  CURSOR_CLI=""
  if command -v cursor-agent &>/dev/null; then
    CURSOR_CLI="cursor-agent"
  elif command -v agent &>/dev/null; then
    CURSOR_CLI="agent"
  else
    ralph_run_plan_log "ERROR: Cursor CLI not found (neither cursor-agent nor agent in PATH)"
    echo -e "${C_R}${C_BOLD}Cursor CLI is not installed or not logged in.${C_RST}"
    echo ""
    echo -e "This script requires the Cursor CLI. Please:"
    echo -e "  1. Install the CLI"
    echo -e "  2. Log in (e.g. run \`agent\` or \`cursor-agent\` and complete sign-in)"
    echo ""
    echo -e "Official installation and login instructions:"
    echo -e "  ${C_C}https://cursor.com/docs/cli/installation${C_RST}"
    echo ""
    echo -e "${C_DIM}After installing, add ~/.local/bin to your PATH, then run \`agent\` to log in and re-run this script.${C_RST}"
    exit 1
  fi
}

# Ensure the Claude CLI is installed and available, exiting when it is missing.
# Args: none.
# Returns: sets CLAUDE_CLI and exits the script when the CLI cannot be found.
ralph_ensure_claude_cli() {
  local cli="${CLAUDE_PLAN_CLI:-}"
  if [[ -z "$cli" && -n "$(command -v claude 2>/dev/null)" ]]; then
    cli="claude"
  fi
  if [[ -z "$cli" ]] || ! command -v "$cli" &>/dev/null; then
    ralph_run_plan_log "ERROR: Claude CLI not found (set CLAUDE_PLAN_CLI or install claude)"
    echo -e "${C_R}${C_BOLD}Claude Code CLI is not installed or not on PATH.${C_RST}"
    echo ""
    echo "Install Claude Code, then ensure \`claude\` is available:"
    echo -e "  ${C_C}https://code.claude.com/docs/en/overview${C_RST}"
    echo -e "  ${C_C}https://code.claude.com/docs/en/headless${C_RST}"
    echo ""
    exit 1
  fi
  CLAUDE_CLI="$cli"
  : "$CLAUDE_CLI"
}

# Ensure the Codex CLI is installed and available, exiting when it is missing.
# Args: none.
# Returns: sets CODEX_CLI and exits the script when the CLI cannot be found.
ralph_ensure_codex_cli() {
  local cli="${CODEX_PLAN_CLI:-}"
  if [[ -z "$cli" && -n "$(command -v codex 2>/dev/null)" ]]; then
    cli="codex"
  fi
  if [[ -z "$cli" ]] || ! command -v "$cli" &>/dev/null; then
    ralph_run_plan_log "ERROR: Codex CLI not found (set CODEX_PLAN_CLI or install codex)"
    echo -e "${C_R}${C_BOLD}Codex CLI is not installed or not on PATH.${C_RST}"
    echo ""
    echo "Install the Codex CLI and authenticate. Non-interactive runs use: codex exec"
    echo -e "  ${C_C}https://developers.openai.com/codex/noninteractive${C_RST}"
    echo -e "  ${C_C}https://developers.openai.com/codex/cli/reference${C_RST}"
    echo ""
    exit 1
  fi
  CODEX_CLI="$cli"
  : "$CODEX_CLI"
}

# Ensure the Opencode CLI is installed and available, exiting when it is missing.
# Args: none.
# Returns: sets OPENCODE_CLI and exits the script when the CLI cannot be found.
ralph_ensure_opencode_cli() {
  local cli="${OPENCODE_PLAN_CLI:-}"
  if [[ -z "$cli" && -n "$(command -v opencode 2>/dev/null)" ]]; then
    cli="opencode"
  fi
  if [[ -z "$cli" ]] || ! command -v "$cli" &>/dev/null; then
    ralph_run_plan_log "ERROR: Opencode CLI not found (set OPENCODE_PLAN_CLI or install opencode)"
    echo -e "${C_R}${C_BOLD}Opencode CLI is not installed or not on PATH.${C_RST}"
    echo ""
    echo "Install the Opencode CLI and authenticate:"
    echo -e "  ${C_C}https://opencode.ai${C_RST}"
    echo ""
    exit 1
  fi
  OPENCODE_CLI="$cli"
  : "$OPENCODE_CLI"
}
