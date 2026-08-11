# shellcheck shell=bash
# Runtime detection and CLI validation helpers for run-plan.sh (sourced early in run-plan).
#
# Public interface:
#   ralph_shared_ralph_dir_complete, ralph_resolve_shared_ralph_dir -- locate installed .ralph tree.
#   prompt_select_runtime -- interactive runtime picker.
#   ralph_ensure_cursor_cli, ralph_ensure_claude_cli, ralph_ensure_codex_cli -- verify CLIs (exit on failure).

# Ensure color vars exist even when run-plan-core hasn't initialized them (tests set -u).
C_Y="${C_Y:-}"
C_DIM="${C_DIM:-}"
C_RST="${C_RST:-}"

if ! declare -F ralph_normalize_runtime_name >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/runtime-normalize.sh"
fi

# Determine whether the provided directory contains the shared .ralph tree.
# Args: $1 - path to inspect for the shared directory layout.
# Returns: 0 when the directory hosts the required bash-lib helpers and runner scripts, 1 otherwise.
ralph_shared_ralph_dir_complete() {
  local d="$1"
  if [[ -f "$d/bash-lib/run-plan/run-plan-env.sh" && -f "$d/ralph-env-safety.sh" \
    && -f "$d/bash-lib/run-plan/run-plan-invoke-cursor.sh" \
    && -f "$d/bash-lib/run-plan/run-plan-invoke-claude.sh" \
    && -f "$d/bash-lib/run-plan/run-plan-invoke-codex.sh" \
    && -f "$d/bash-lib/run-plan/run-plan-invoke-opencode.sh" \
    && -f "$d/bash-lib/run-plan/run-plan-invoke-antigravity.sh" ]]; then
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

# Helpers for Ralph mode validation and normalization (used by preference loading and prompts).
ralph_validate_ralph_mode() {
  local mode="${1:-}"
  case "$mode" in
    no|native|ralph|hybrid|"")
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

ralph_normalize_ralph_mode() {
  local value
  value="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  case "$value" in
    no|native|ralph|hybrid) printf '%s' "$value" ;;
    "") printf '' ;;
    *) printf '%s' "${1:-}" ;;
  esac
}

# Prompt interactively for the runtime to use when it is not provided explicitly.
# Args: none.
# Returns: prints the selected runtime (cursor, claude, or codex) and 0 on success, 1 on failure.
prompt_select_runtime() {
  if [[ "$NON_INTERACTIVE_FLAG" == "1" ]]; then
    echo "Error: runtime must be provided via --runtime or RALPH_PLAN_RUNTIME (cursor, claude, codex, opencode, antigravity, or agy)." >&2
    return 1
  fi
  if [[ ! -t 0 ]]; then
    echo "Error: runtime must be provided via --runtime or RALPH_PLAN_RUNTIME when stdin is not a terminal." >&2
    return 1
  fi
  ralph_menu_select --prompt "runtime" --default 1 -- cursor claude codex opencode antigravity
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

# Ensure the Antigravity CLI is installed and available, exiting when it is missing.
# Args: none.
# Returns: sets ANTIGRAVITY_CLI and exits the script when the CLI cannot be found.
ralph_ensure_antigravity_cli() {
  local cli="${ANTIGRAVITY_PLAN_CLI:-}"
  if [[ -z "$cli" && -n "$(command -v agy 2>/dev/null)" ]]; then
    cli="agy"
  fi
  if [[ -z "$cli" ]] || ! command -v "$cli" &>/dev/null; then
    ralph_run_plan_log "ERROR: Antigravity CLI not found (set ANTIGRAVITY_PLAN_CLI or install agy)"
    echo -e "${C_R}${C_BOLD}Antigravity CLI is not installed or not on PATH.${C_RST}"
    echo ""
    echo "Install the Antigravity CLI and authenticate:"
    echo -e "  ${C_C}https://antigravity.google${C_RST}"
    echo ""
    exit 1
  fi
  ANTIGRAVITY_CLI="$cli"
  : "$ANTIGRAVITY_CLI"
}

ralph_load_workspace_preferences() {
  local workspace="${1:-}"
  local workspace_root="${2:-${RALPH_PLAN_WORKSPACE_ROOT:-}}"
  local prefs_file

  if [[ -z "$workspace_root" ]]; then
    workspace_root="${workspace}/.ralph-workspace"
  fi

  prefs_file="$workspace_root/preferences.json"
  if [[ ! -f "$prefs_file" ]]; then
    return 0
  fi

  if command -v jq &>/dev/null; then
    if [[ -f "$prefs_file" ]]; then
      local ralph_mode_pref
      ralph_mode_pref="$(jq -r '.ralph_mode_default // empty' "$prefs_file" 2>/dev/null || true)"
      if [[ -z "${RALPH_MODE:-}" && -n "$ralph_mode_pref" ]]; then
        ralph_mode_pref="$(ralph_normalize_ralph_mode "$ralph_mode_pref")"
        if ralph_validate_ralph_mode "$ralph_mode_pref"; then
          RALPH_MODE="$ralph_mode_pref"
        else
          echo "Warning: ignoring invalid ralph_mode_default='$ralph_mode_pref' in $prefs_file" >&2
        fi
      fi
    fi
  fi
  if [[ -n "${RALPH_MODE:-}" ]]; then
    export RALPH_MODE
  fi
  return 0
}

prompt_ralph_mode() {
  # Tests can set RALPH_MODE_PROMPT_ASSUME_TTY=1 to bypass the TTY gating.
  if [[ "${RALPH_MODE_PROMPT_ASSUME_TTY:-0}" != "1" ]]; then
    if [[ "$NON_INTERACTIVE_FLAG" == "1" ]]; then
      return 0
    fi
    if [[ ! -t 0 || ! -t 1 ]]; then
      return 0
    fi
  fi
  if [[ -n "${RALPH_MODE:-}" ]]; then
    return 0
  fi

  echo "" >&2
  echo -e "${C_Y}Ralph tooling mode?${C_RST}" >&2
  echo -e "${C_DIM}Choose how Ralph tooling and native hooks & adapters are enabled for this run.${C_RST}" >&2
  echo -e "${C_DIM}  hybrid = Ralph MCP tools + native hooks & adapters${C_RST}" >&2
  echo -e "${C_DIM}  ralph  = Ralph tools connected via MCP only${C_RST}" >&2
  echo -e "${C_DIM}  native = native tools + native hooks & adapters${C_RST}" >&2
  echo -e "${C_DIM}  no     = no Ralph tooling or native hooks/adapters${C_RST}" >&2

  local choice
  choice="$(ralph_menu_select --prompt "Ralph mode" --default 1 -- "no" "native" "ralph" "hybrid")" || return 0

  case "$choice" in
    "hybrid"|"ralph"|"native"|"no")
      RALPH_MODE="$choice"
      ;;
  esac
}

# Apply default shell compaction based on Ralph mode (delegates to mode knob defaults).
# Args: none (uses RALPH_MODE env var)
# Returns: sets compaction env vars when mode defaults apply; leaves explicit values untouched
ralph_apply_shell_compact_defaults() {
  if declare -F ralph_apply_mode_compaction_defaults >/dev/null 2>&1; then
    ralph_apply_mode_compaction_defaults "${RALPH_MODE:-no}"
    if declare -F ralph_apply_mode_transcript_eviction_defaults >/dev/null 2>&1; then
      ralph_apply_mode_transcript_eviction_defaults "${RALPH_MODE:-no}"
    fi
    return 0
  fi

  # Fallback when only run-plan-runtime.sh is sourced (tests).
  if [[ -z "${RALPH_PROXY_SHELL_COMPACT:-}" ]]; then
    case "${RALPH_MODE:-no}" in
      ralph|hybrid)
        RALPH_PROXY_SHELL_COMPACT=1
        export RALPH_PROXY_SHELL_COMPACT
        ;;
    esac
  fi

  if [[ -z "${RALPH_BASH_COMPACT:-}" ]]; then
    case "${RALPH_MODE:-no}" in
      native|hybrid)
        RALPH_BASH_COMPACT=1
        export RALPH_BASH_COMPACT
        ;;
    esac
  fi

}

ralph_apply_mode_transcript_eviction_defaults() {
  local mode="${1:-no}"

  if [[ -z "${RALPH_PLAN_TRANSCRIPT_EVICTION:-}" ]]; then
    case "$mode" in
      ralph|hybrid)
        RALPH_PLAN_TRANSCRIPT_EVICTION=safe
        export RALPH_PLAN_TRANSCRIPT_EVICTION
        ;;
      *)
        RALPH_PLAN_TRANSCRIPT_EVICTION=off
        export RALPH_PLAN_TRANSCRIPT_EVICTION
        ;;
    esac
  fi

  case "${RALPH_PLAN_TRANSCRIPT_EVICTION:-off}" in
    safe|aggressive)
      if [[ -z "${RALPH_CONTINUATION_SUMMARY:-}" ]]; then
        RALPH_CONTINUATION_SUMMARY=1
        export RALPH_CONTINUATION_SUMMARY
      fi
      if [[ -z "${RALPH_CONTINUATION_SUMMARY_HIERARCHICAL:-}" ]]; then
        RALPH_CONTINUATION_SUMMARY_HIERARCHICAL=1
        export RALPH_CONTINUATION_SUMMARY_HIERARCHICAL
      fi
      if [[ -z "${RALPH_CONTINUATION_SUMMARY_MAX_RENDER_BYTES:-}" ]]; then
        RALPH_CONTINUATION_SUMMARY_MAX_RENDER_BYTES=8192
        export RALPH_CONTINUATION_SUMMARY_MAX_RENDER_BYTES
      fi
      ;;
  esac

  case "${RALPH_PLAN_TRANSCRIPT_EVICTION:-off}" in
    aggressive)
      if [[ -z "${RALPH_PLAN_CONTEXT_BUDGET:-}" ]]; then
        RALPH_PLAN_CONTEXT_BUDGET=lean
        export RALPH_PLAN_CONTEXT_BUDGET
      fi
      if [[ -z "${RALPH_CONTINUATION_SUMMARY_RECENT_DETAIL_COUNT:-}" ]]; then
        RALPH_CONTINUATION_SUMMARY_RECENT_DETAIL_COUNT=3
        export RALPH_CONTINUATION_SUMMARY_RECENT_DETAIL_COUNT
      fi
      ;;
  esac
}
