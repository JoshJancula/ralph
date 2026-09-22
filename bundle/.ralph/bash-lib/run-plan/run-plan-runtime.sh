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

      local jev_pref
      jev_pref="$(jq -r '.jev_default // empty' "$prefs_file" 2>/dev/null || true)"
      if [[ -z "${RALPH_JEV:-}" && -n "$jev_pref" ]]; then
        case "$jev_pref" in
          compaction|mcp|both) ralph_jev_enable_surfaces "$jev_pref" ;;
          1|yes|true|on)       ralph_jev_enable_surfaces both ;;
          0|no|none|false|off) RALPH_JEV=0 ;;
          *)
            echo "Warning: ignoring invalid jev_default='$jev_pref' in $prefs_file" >&2
            ;;
        esac
      fi
    fi
  fi
  if [[ -n "${RALPH_MODE:-}" ]]; then
    export RALPH_MODE
  fi
  if [[ -n "${RALPH_JEV:-}" ]]; then
    export RALPH_JEV
  fi
  return 0
}

# Turn on the Jev adapter plus the surfaces named by <choice>:
#   compaction = tool-output compaction (RALPH_JEV_COMPACT)
#   mcp        = the ralph-jev MCP server (RALPH_JEV_MCP)
#   both       = both of the above
# Compaction ships repo and log content to a third party and MCP adds a second
# stdio MCP server, so each is enabled only by naming it. Graph routing
# (RALPH_JEV_ROUTING) is a workflow setting and is never set here.
# Any surface the caller set explicitly is left alone.
ralph_jev_enable_surfaces() {
  RALPH_JEV=1
  case "${1:-}" in
    compaction) : "${RALPH_JEV_COMPACT:=1}" ;;
    mcp)        : "${RALPH_JEV_MCP:=1}" ;;
    both)
      : "${RALPH_JEV_COMPACT:=1}"
      : "${RALPH_JEV_MCP:=1}"
      ;;
  esac
  export RALPH_JEV
  [[ -n "${RALPH_JEV_COMPACT:-}" ]] && export RALPH_JEV_COMPACT
  [[ -n "${RALPH_JEV_MCP:-}" ]] && export RALPH_JEV_MCP
  return 0
}

# Apply an explicit CLI surface choice: routing | tooling | all.
#   routing = graph routing (RALPH_JEV_ROUTING)
#   tooling = the ralph-jev MCP server and tool-output compaction
#             (RALPH_JEV_MCP, RALPH_JEV_COMPACT)
#   all     = routing and tooling
# Always enables the adapter (RALPH_JEV=1). Surfaces outside the choice are
# left exactly as the caller set them; nothing is unset.
ralph_jev_apply_cli_choice() {
  local choice="${1:-}"
  case "$choice" in
    routing|tooling|all) ;;
    *)
      printf 'ralph: invalid Jev choice "%s" (expected routing, tooling, or all)\n' "$choice" >&2
      return 2
      ;;
  esac
  export RALPH_JEV=1
  case "$choice" in
    routing) export RALPH_JEV_ROUTING=1 ;;
    tooling) export RALPH_JEV_MCP=1 RALPH_JEV_COMPACT=1 ;;
    all)     export RALPH_JEV_ROUTING=1 RALPH_JEV_MCP=1 RALPH_JEV_COMPACT=1 ;;
  esac
  return 0
}

# Report the configured Jev key source without ever reading or printing the key.
# Emits one of: env | env-file | command | keychain | file | none.
# "none" when this build ships no Jev adapter at all.
ralph_jev_key_source() {
  local key_lib="${RALPH_DIR:-}/bash-lib/jev/jev-key-store.sh"
  if ! declare -F jev_key_source >/dev/null 2>&1; then
    if [[ ! -f "$key_lib" ]]; then
      printf 'none\n'
      return 0
    fi
    # shellcheck source=/dev/null
    source "$key_lib" 2>/dev/null || { printf 'none\n'; return 0; }
  fi
  if ! declare -F jev_key_source >/dev/null 2>&1; then
    printf 'none\n'
    return 0
  fi
  jev_key_source 2>/dev/null || printf 'none\n'
}

# Ask whether to enable Jev, but ONLY when a key is already configured.
# Without a key the question is noise: there is nothing to enable. Mirrors
# prompt_ralph_mode - opt-in, default "no", silent on every non-TTY path.
prompt_ralph_jev() {
  # Tests can set RALPH_JEV_PROMPT_ASSUME_TTY=1 to bypass the TTY gating.
  if [[ "${RALPH_JEV_PROMPT_ASSUME_TTY:-0}" != "1" ]]; then
    if [[ "${NON_INTERACTIVE_FLAG:-0}" == "1" ]]; then
      return 0
    fi
    if [[ ! -t 0 || ! -t 1 ]]; then
      return 0
    fi
  fi
  if [[ -n "${RALPH_JEV:-}" ]]; then
    return 0
  fi
  if ! command -v jq &>/dev/null; then
    return 0
  fi

  local key_source
  key_source="$(ralph_jev_key_source)"
  if [[ -z "$key_source" || "$key_source" == "none" ]]; then
    # No key configured: stay silent rather than advertising an unusable feature.
    return 0
  fi

  echo "" >&2
  echo -e "${C_Y}Enable Jev (TypeSafe AI) for this run?${C_RST}" >&2
  echo -e "${C_DIM}  A TypeSafe API key is configured (source: ${key_source}).${C_RST}" >&2
  echo -e "${C_DIM}  none       = no Jev calls at all (default)${C_RST}" >&2
  echo -e "${C_DIM}  compaction = Jev ranked-line selection on large tool output (sends repo/log content to TypeSafe)${C_RST}" >&2
  echo -e "${C_DIM}  mcp        = ralph-jev MCP tools (adds a second stdio MCP server)${C_RST}" >&2
  echo -e "${C_DIM}  both       = compaction and mcp${C_RST}" >&2
  echo -e "${C_DIM}Jev is advisory only: it never marks a TODO done, passes a gate, or bypasses validation.${C_RST}" >&2
  echo -e "${C_DIM}Skip this question with RALPH_JEV=0/1, or jev_default in .ralph-workspace/preferences.json.${C_RST}" >&2

  local choice
  # Default index 1 = "none" (opt-in).
  choice="$(ralph_menu_select --prompt "Enable Jev" --default 1 -- "none" "compaction" "mcp" "both")" || return 0

  case "$choice" in
    compaction|mcp|both)
      ralph_jev_enable_surfaces "$choice"
      ;;
    none|no|n|N|"")
      RALPH_JEV=0
      export RALPH_JEV
      ;;
  esac
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
  echo -e "${C_Y}Enable Ralph tooling?${C_RST}" >&2
  echo -e "${C_DIM}  yes = Ralph MCP (shell, results, batch) + native hooks/adapters where supported (hybrid)${C_RST}" >&2
  echo -e "${C_DIM}  no  = stock assistant tools only${C_RST}" >&2
  echo -e "${C_DIM}Expert override: --ralph-mode native|ralph for hooks-only or MCP-only.${C_RST}" >&2

  local choice
  # Default index 1 = "no" (opt-in).
  choice="$(ralph_menu_select --prompt "Enable Ralph tooling" --default 1 -- "no" "yes")" || return 0

  case "$choice" in
    yes|y|Y)
      RALPH_MODE="hybrid"
      ;;
    no|n|N|"")
      RALPH_MODE="no"
      ;;
  esac
}

# Default Claude permission allowlist; must match run-plan-invoke-claude.sh.
RALPH_CLAUDE_DEFAULT_ALLOWED_TOOLS="Bash,Read,Edit,Write"

# Accept a comma-separated list of plausible tool names (Bash, mcp__srv__tool,
# Bash(git:*)). Rejects whitespace-only, empty items, and shell metacharacters.
ralph_claude_allowed_tools_valid() {
  local list="${1//[[:space:]]/}"
  [[ -n "$list" ]] || return 1
  [[ "$list" =~ ^[A-Za-z][A-Za-z0-9_:*.()/@-]*(,[A-Za-z][A-Za-z0-9_:*.()/@-]*)*$ ]]
}

# Show the Claude permission allowlist and let the operator change it. Sets
# CLAUDE_PLAN_ALLOWED_TOOLS only when they choose their own list. Silent on
# every non-TTY / non-Claude / already-configured path, like prompt_ralph_mode.
prompt_claude_allowed_tools() {
  [[ "${RUNTIME:-}" == "claude" ]] || return 0
  ralph_tools_prompt_attended || return 0
  [[ "${CLAUDE_PLAN_ALLOWED_TOOLS+set}" == "set" ]] && return 0
  [[ "${CLAUDE_PLAN_NO_ALLOWED_TOOLS:-0}" == "1" ]] && return 0

  local pref
  pref="$(ralph_tools_pref claude_allowed_tools_default)"
  if [[ -n "$pref" ]]; then
    if ralph_claude_allowed_tools_valid "$pref"; then
      CLAUDE_PLAN_ALLOWED_TOOLS="${pref//[[:space:]]/}"
      export CLAUDE_PLAN_ALLOWED_TOOLS
    else
      echo "Warning: ignoring invalid claude_allowed_tools_default='$pref' in preferences.json" >&2
    fi
    return 0
  fi

  local default="$RALPH_CLAUDE_DEFAULT_ALLOWED_TOOLS"
  echo "" >&2
  echo -e "${C_Y}Claude allowed tools${C_RST}" >&2
  echo -e "${C_DIM}  Current default: ${default//,/, }${C_RST}" >&2
  echo -e "${C_DIM}  Ralph adds its own mcp__ralph__* tools (and mcp__ralph-jev__* when Jev MCP is on) automatically.${C_RST}" >&2
  echo -e "${C_DIM}  Also available to grant: WebSearch, WebFetch, Grep, Glob, Skill, TodoWrite, NotebookEdit, Task${C_RST}" >&2
  echo -e "${C_DIM}  These are permission grants. Un-granted tools are not removed; Claude's own permission rules apply.${C_RST}" >&2
  echo -e "${C_DIM}Skip this question with CLAUDE_PLAN_ALLOWED_TOOLS, or claude_allowed_tools_default in .ralph-workspace/preferences.json.${C_RST}" >&2

  local choice
  choice="$(ralph_menu_select --prompt "Claude allowed tools" --default 1 -- "leave as is" "set my own")" || return 0
  [[ "$choice" == "set my own" ]] || return 0

  local entry
  entry="$(ralph_prompt_text "Allowed tools, comma-separated" "$default")" || return 0
  entry="${entry//[[:space:]]/}"
  if ! ralph_claude_allowed_tools_valid "$entry"; then
    echo "Invalid or empty tool list; keeping default: $default" >&2
    return 0
  fi
  CLAUDE_PLAN_ALLOWED_TOOLS="$entry"
  export CLAUDE_PLAN_ALLOWED_TOOLS
}

# True on an attended TTY run (or when tests set RALPH_TOOLS_PROMPT_ASSUME_TTY=1).
ralph_tools_prompt_attended() {
  [[ "${RALPH_TOOLS_PROMPT_ASSUME_TTY:-0}" == "1" ]] && return 0
  [[ "${NON_INTERACTIVE_FLAG:-0}" == "1" ]] && return 1
  [[ -t 0 && -t 1 ]]
}

# Read one key from .ralph-workspace/preferences.json; empty when absent.
ralph_tools_pref() {
  local prefs_file="${RALPH_PLAN_WORKSPACE_ROOT:-${WORKSPACE:-.}/.ralph-workspace}/preferences.json"
  [[ -f "$prefs_file" ]] && command -v jq &>/dev/null || return 0
  jq -r --arg k "$1" '.[$k] // empty | tostring' "$prefs_file" 2>/dev/null || true
}

ralph_tools_prompt_skip_hint() {
  echo -e "${C_DIM}Skip this question with $1, or $2 in .ralph-workspace/preferences.json.${C_RST}" >&2
}

# Codex has no tool allowlist. Its native knobs are the sandbox mode and live web search.
prompt_codex_tool_access() {
  [[ "${RUNTIME:-}" == "codex" ]] || return 0
  ralph_tools_prompt_attended || return 0

  if [[ -z "${CODEX_PLAN_SANDBOX:-}" ]]; then
    local pref
    pref="$(ralph_tools_pref codex_sandbox_default)"
    case "$pref" in
      read-only|workspace-write|danger-full-access)
        CODEX_PLAN_SANDBOX="$pref"; export CODEX_PLAN_SANDBOX ;;
      "") ;;
      *) echo "Warning: ignoring invalid codex_sandbox_default='$pref' in preferences.json" >&2 ;;
    esac
  fi
  if [[ -z "${CODEX_PLAN_WEB_SEARCH:-}" ]]; then
    local wpref
    wpref="$(ralph_tools_pref codex_web_search_default)"
    case "$wpref" in
      1|true|yes|on) CODEX_PLAN_WEB_SEARCH=1; export CODEX_PLAN_WEB_SEARCH ;;
      0|false|no|off) CODEX_PLAN_WEB_SEARCH=0; export CODEX_PLAN_WEB_SEARCH ;;
    esac
  fi

  local choice
  if [[ -z "${CODEX_PLAN_SANDBOX:-}" ]]; then
    echo "" >&2
    echo -e "${C_Y}Codex sandbox${C_RST}" >&2
    echo -e "${C_DIM}  Codex has no per-tool allowlist; the sandbox mode is what bounds shell commands.${C_RST}" >&2
    echo -e "${C_DIM}  Current default: workspace-write. read-only cannot edit files. danger-full-access removes the sandbox.${C_RST}" >&2
    ralph_tools_prompt_skip_hint "CODEX_PLAN_SANDBOX (--codex-sandbox)" codex_sandbox_default
    choice="$(ralph_menu_select --prompt "Codex sandbox" --default 1 -- "leave as is" "read-only" "workspace-write" "danger-full-access")" || choice=""
    case "$choice" in
      read-only|workspace-write|danger-full-access)
        CODEX_PLAN_SANDBOX="$choice"; export CODEX_PLAN_SANDBOX ;;
    esac
  fi
  if [[ -z "${CODEX_PLAN_WEB_SEARCH:-}" ]]; then
    echo "" >&2
    echo -e "${C_Y}Codex live web search${C_RST}" >&2
    echo -e "${C_DIM}  Enables Codex's native web_search tool with no per-call approval. Off by default.${C_RST}" >&2
    ralph_tools_prompt_skip_hint CODEX_PLAN_WEB_SEARCH codex_web_search_default
    choice="$(ralph_menu_select --prompt "Codex web search" --default 1 -- "leave off" "enable live search")" || choice=""
    if [[ "$choice" == "enable live search" ]]; then
      CODEX_PLAN_WEB_SEARCH=1
    else
      CODEX_PLAN_WEB_SEARCH=0
    fi
    export CODEX_PLAN_WEB_SEARCH
  fi
}

RALPH_OPENCODE_PERMISSION_TOOLS="bash read edit glob grep webfetch websearch task todowrite lsp skill"

# Validate "tool=allow|ask|deny,..." and emit {"permission":{...}} JSON.
ralph_opencode_permission_json() {
  local spec="${1//[[:space:]]/}" pair tool action known
  [[ -n "$spec" ]] || return 1
  local -a pairs
  IFS=',' read -r -a pairs <<<"$spec"
  local json='{}'
  for pair in "${pairs[@]}"; do
    tool="${pair%%=*}"; action="${pair#*=}"
    [[ "$pair" == *=* ]] || return 1
    case "$action" in allow|ask|deny) ;; *) return 1 ;; esac
    known=0
    for t in $RALPH_OPENCODE_PERMISSION_TOOLS; do [[ "$t" == "$tool" ]] && known=1; done
    [[ "$known" == "1" ]] || return 1
    json="$(jq -c --arg t "$tool" --arg a "$action" '. + {($t): $a}' <<<"$json")" || return 1
  done
  jq -c '{permission: .}' <<<"$json"
}

# OpenCode's native knob is a per-tool allow/ask/deny map, merged over the
# ambient config by the existing OPENCODE_PLAN_PERMISSION_CONFIG_PATH overlay.
prompt_opencode_tool_access() {
  [[ "${RUNTIME:-}" == "opencode" ]] || return 0
  ralph_tools_prompt_attended || return 0
  [[ -n "${OPENCODE_PLAN_PERMISSION_CONFIG_PATH:-}" ]] && return 0
  command -v jq &>/dev/null || return 0

  local out_dir="${RALPH_PLAN_WORKSPACE_ROOT:-${WORKSPACE:-.}/.ralph-workspace}"
  local spec json
  spec="$(ralph_tools_pref opencode_permission_default)"
  if [[ -z "$spec" ]]; then
    echo "" >&2
    echo -e "${C_Y}OpenCode tool permissions${C_RST}" >&2
    echo -e "${C_DIM}  Default: your own OpenCode config decides. Ralph changes nothing unless you set a map.${C_RST}" >&2
    echo -e "${C_DIM}  Tools: ${RALPH_OPENCODE_PERMISSION_TOOLS}${C_RST}" >&2
    echo -e "${C_DIM}  Actions: allow | ask | deny. Example: bash=allow,edit=allow,webfetch=deny${C_RST}" >&2
    echo -e "${C_DIM}  Unlisted tools keep their configured behavior. 'ask' can stall an unattended run.${C_RST}" >&2
    ralph_tools_prompt_skip_hint OPENCODE_PLAN_PERMISSION_CONFIG_PATH opencode_permission_default
    local choice
    choice="$(ralph_menu_select --prompt "OpenCode permissions" --default 1 -- "leave as is" "set my own")" || return 0
    [[ "$choice" == "set my own" ]] || return 0
    spec="$(ralph_prompt_text "Permissions (tool=action, comma-separated)")" || return 0
  fi
  if ! json="$(ralph_opencode_permission_json "$spec")"; then
    echo "Invalid OpenCode permission map '$spec'; leaving config unchanged." >&2
    return 0
  fi
  mkdir -p "$out_dir"
  printf '%s\n' "$json" >"$out_dir/opencode-permission-overlay.json"
  OPENCODE_PLAN_PERMISSION_CONFIG_PATH="$out_dir/opencode-permission-overlay.json"
  export OPENCODE_PLAN_PERMISSION_CONFIG_PATH
}

# Cursor and Antigravity expose a single approvals switch: auto-approve on (the
# headless default) or off (every tool call waits for an answer).
_ralph_prompt_approvals_switch() {
  local label="$1" var="$2" pref_key="$3" var_hint="$4" pref choice
  [[ -z "${!var:-}" ]] || return 0
  pref="$(ralph_tools_pref "$pref_key")"
  case "$pref" in
    1|true|yes|on) printf -v "$var" '%s' 1; export "${var?}"; return 0 ;;
    0|false|no|off) printf -v "$var" '%s' 0; export "${var?}"; return 0 ;;
  esac
  echo "" >&2
  echo -e "${C_Y}${label} tool approvals${C_RST}" >&2
  echo -e "${C_DIM}  ${label} has no per-tool list, only auto-approve on or off. Default: on.${C_RST}" >&2
  echo -e "${C_DIM}  Off makes every tool call wait for an approval, which stalls unattended runs.${C_RST}" >&2
  ralph_tools_prompt_skip_hint "$var_hint" "$pref_key"
  choice="$(ralph_menu_select --prompt "${label} approvals" --default 1 -- "auto-approve (default)" "require approvals")" || return 0
  if [[ "$choice" == "require approvals" ]]; then
    printf -v "$var" '%s' 0; export "${var?}"
  fi
}

prompt_cursor_tool_access() {
  [[ "${RUNTIME:-}" == "cursor" ]] || return 0
  ralph_tools_prompt_attended || return 0
  _ralph_prompt_approvals_switch Cursor CURSOR_PLAN_FORCE cursor_force_default CURSOR_PLAN_FORCE
}

prompt_antigravity_tool_access() {
  [[ "${RUNTIME:-}" == "antigravity" ]] || return 0
  ralph_tools_prompt_attended || return 0
  _ralph_prompt_approvals_switch Antigravity ANTIGRAVITY_PLAN_SKIP_PERMISSIONS antigravity_skip_permissions_default ANTIGRAVITY_PLAN_SKIP_PERMISSIONS
}

# One entry point: each runtime shows the tool/permission knob it actually has.
prompt_runtime_tool_access() {
  case "${RUNTIME:-}" in
    claude)      prompt_claude_allowed_tools ;;
    codex)       prompt_codex_tool_access ;;
    opencode)    prompt_opencode_tool_access ;;
    cursor)      prompt_cursor_tool_access ;;
    antigravity) prompt_antigravity_tool_access ;;
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
