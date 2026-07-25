# shellcheck shell=bash
# run-plan-args.sh -- argument parsing for .ralph/run-plan.sh (sourced only; not standalone).
#
# Public interface:
#   print_usage -- writes run-plan --help text to stdout.
#   ralph_run_plan_parse_args -- consumes "$@"; sets WORKSPACE, RUNTIME, PLAN_OVERRIDE, agent/model
#     flags, and session strategy globals. Exports RALPH_PLAN_ALLOW_UNSAFE_RESUME for child processes
#     when bare resume is allowed.

PROJECT_ROOT_OVERRIDE=""
WORKSPACE_ROOT_OVERRIDE=""
AGENT_WORKSPACE_OVERRIDE=""

if ! declare -F ralph_normalize_runtime_name >/dev/null 2>&1; then
  _ralph_run_plan_args_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=/dev/null
  source "$_ralph_run_plan_args_dir/../runtime-normalize.sh"
  unset _ralph_run_plan_args_dir
fi

ralph_validate_claude_permission_mode() {
  local mode="${1:-}"
  case "$mode" in
    default|acceptEdits|auto|bypassPermissions|dontAsk|plan)
      return 0
      ;;
    "")
      return 0
      ;;
    *)
      ralph_die "Error: --claude-permission-mode / CLAUDE_PLAN_PERMISSION_MODE must be one of default, acceptEdits, auto, bypassPermissions, dontAsk, or plan."
      ;;
  esac
}

ralph_validate_codex_sandbox_mode() {
  local mode="${1:-}"
  case "$mode" in
    read-only|workspace-write|danger-full-access)
      return 0
      ;;
    "")
      return 0
      ;;
    *)
      ralph_die "Error: --codex-sandbox / CODEX_PLAN_SANDBOX must be one of read-only, workspace-write, or danger-full-access."
      ;;
  esac
}

ralph_validate_codex_boolean() {
  local value="${1:-}"
  case "$value" in
    0|1|true|false|yes|no|on|off)
      return 0
      ;;
    "")
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

ralph_normalize_codex_boolean() {
  local value="${1:-}"
  case "$value" in
    1|true|yes|on)
      printf '1'
      ;;
    0|false|no|off|"")
      printf '0'
      ;;
    *)
      printf '0'
      ;;
  esac
}

ralph_validate_session_strategy() {
  local strategy="${1:-}"
  case "$strategy" in
    fresh|resume|reset|compact)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

ralph_validate_transcript_eviction() {
  local mode="${1:-}"
  case "$mode" in
    off|safe|aggressive|"")
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

ralph_normalize_transcript_eviction() {
  local value
  value="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  case "$value" in
    off|safe|aggressive) printf '%s' "$value" ;;
    "") printf '' ;;
    *) printf '%s' "${1:-}" ;;
  esac
}

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

# Apply default compaction env for paths that provably reach the model.
# Args: $1 - resolved RALPH_MODE value (no, native, ralph, hybrid)
# Sets RALPH_PROXY_SHELL_COMPACT=1 in ralph|hybrid when unset (MCP proxy shell path).
# Sets RALPH_BASH_COMPACT=1 in native|hybrid when unset (Claude PostToolUse:Bash proven path).
# Sets RALPH_NATIVE_RESULT_COMPACT=1 in native|hybrid when unset (native exploration result compaction path).
# Explicit 0 (or any other value) opts out or overrides; unset-only defaults apply.
ralph_apply_mode_compaction_defaults() {
  local mode="${1:-no}"

  if [[ -z "${RALPH_PROXY_SHELL_COMPACT:-}" ]]; then
    case "$mode" in
      ralph|hybrid)
        RALPH_PROXY_SHELL_COMPACT=1
        export RALPH_PROXY_SHELL_COMPACT
        ;;
    esac
  fi

  if [[ -z "${RALPH_BASH_COMPACT:-}" ]]; then
    case "$mode" in
      native|hybrid)
        RALPH_BASH_COMPACT=1
        export RALPH_BASH_COMPACT
        ;;
    esac
  fi

  if [[ -z "${RALPH_NATIVE_RESULT_COMPACT:-}" ]]; then
    case "$mode" in
      native|hybrid)
        RALPH_NATIVE_RESULT_COMPACT=1
        export RALPH_NATIVE_RESULT_COMPACT
        ;;
    esac
  fi
}

# Apply transcript-eviction defaults for safe prompt pruning and continuation-summary compaction.
# Args: $1 - resolved RALPH_MODE value (no, native, ralph, hybrid)
# Sets RALPH_PLAN_TRANSCRIPT_EVICTION=safe in ralph|hybrid when unset, off otherwise.
# Safe mode also ensures continuation summaries are enabled and rendered compactly.
# Explicit env values win; unset-only defaults apply.
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

# Map RALPH_MODE to internal behavior knobs.
# Args: $1 - resolved RALPH_MODE value (no, native, ralph, hybrid)
# Sets: RALPH_AGENT_TOOL_ACCESS, RALPH_NATIVE_HOOKS
ralph_apply_ralph_mode_to_knobs() {
  local mode="${1:-no}"
  case "$mode" in
    no)
      RALPH_AGENT_TOOL_ACCESS="native"
      RALPH_NATIVE_HOOKS="off"
      ;;
    native)
      RALPH_AGENT_TOOL_ACCESS="native"
      RALPH_NATIVE_HOOKS="auto"
      ;;
    ralph)
      RALPH_AGENT_TOOL_ACCESS="ralph"
      RALPH_NATIVE_HOOKS="off"
      ;;
    hybrid)
      RALPH_AGENT_TOOL_ACCESS="ralph"
      RALPH_NATIVE_HOOKS="auto"
      ;;
  esac
  ralph_apply_mode_compaction_defaults "$mode"
  ralph_apply_mode_transcript_eviction_defaults "$mode"
  if [[ -z "${RALPH_MCP_CONTEXTUAL_SEARCH:-}" ]]; then
    case "$mode" in
      ralph|hybrid)
        RALPH_MCP_CONTEXTUAL_SEARCH=1
        export RALPH_MCP_CONTEXTUAL_SEARCH
        ;;
    esac
  fi
}

# Print the run-plan CLI usage summary.
# Args: none
# Returns: 0 on success, non-zero on error
print_usage() {
  cat <<'EOU'
Usage: .ralph/run-plan.sh --plan <path> [OPTIONS]

Required:
  --plan <path>                        Path to the plan file relative to the workspace.

Options:
  --runtime <cursor|claude|codex|opencode|antigravity|agy>  CLI runtime (use agy as shorthand for antigravity; omit if RALPH_PLAN_RUNTIME is set or you use the interactive prompt).
  --workspace <path>                   Repo workspace root (default: current directory).
  --project-root <path>                Alias for --workspace; where the project (and .ralph/) lives.
  --workspace-root <path>              Directory that contains .ralph-workspace (defaults to <project>/.ralph-workspace).
  --agent-workspace <path>             Agent sandbox root (default: original invocation directory; files the agent can read/write).

Common options:
  --agent <name>                       Prebuilt agent directory under .<runtime>/agents/.
  --agent-source <path>                Explicit agent source file (overrides probe order; sets RALPH_AGENT_SOURCE).
  --select-agent                       Pick a prebuilt agent interactively.
  --non-interactive / --no-interactive  Skip interactive prompts.
  --model <id>                         CLI model id (overrides agent default).
  --reasoning-effort <low|medium|high|xhigh|max|inherit>
                                       Portable reasoning effort (overrides agent and stage defaults).
  --claude-bare                        Enable Claude --bare / CLAUDE_PLAN_BARE (default: on; --no-claude-bare or CLAUDE_PLAN_BARE=0 restores CLAUDE.md auto-discovery, auto-memory, and plugin sync).
  --claude-allow-mcp                   In Claude minimal mode, omit empty MCP lockdown so project MCP servers load (sets CLAUDE_PLAN_MINIMAL_DISABLE_MCP=0).
  --no-claude-allow-mcp                Restore default minimal MCP lockdown (sets CLAUDE_PLAN_MINIMAL_DISABLE_MCP=1).
  --claude-permission-mode <default|acceptEdits|auto|bypassPermissions|dontAsk|plan>
                                       Set CLAUDE_PLAN_PERMISSION_MODE for Claude exec (omit to use the CLI default; modes that skip or auto-approve permissions reduce safety).
  --codex-sandbox <read-only|workspace-write|danger-full-access>
                                        Sets CODEX_PLAN_SANDBOX for Codex exec (default: workspace-write; danger-full-access is high risk).
  --codex-dangerously-bypass <0|1>
                                        Sets CODEX_PLAN_DANGEROUSLY_BYPASS_APPROVALS_AND_SANDBOX (default: 0; 1 adds --dangerously-bypass-approvals-and-sandbox; isolated-runner-only).
  --session-strategy <fresh|resume|reset|compact>
                                        Session behavior between TODOs.
                                        fresh=default strict isolation, resume=keep same conversation,
                                        reset=reuse session id with reset-oriented prompts,
                                        compact=reuse session id with compact command prefix (Codex=/compact, Cursor=/compress).
  --cli-resume / --no-cli-resume       Enable/disable CLI resume prompts.
  --allow-unsafe-resume                Allow bare CLI resume without session id.
  --resume <id>                        Force a CLI session id for this run.
  --ralph-mode <no|native|ralph|hybrid>
                                       Set Ralph tooling and native adapter mode (sets RALPH_MODE).
                                       no     = no Ralph MCP injection and no native adapters.
                                       native = native tools primary; native adapters enabled; result tools only.
                                       ralph  = full Ralph MCP catalog; native adapters disabled.
                                       hybrid = full Ralph MCP catalog plus native adapters.
                                       Interactive runs prompt when no flag, env, or preference exists.
  --skip-mcp-preflight                 Skip Ralph MCP handshake preflight when Ralph MCP is active (CI/stubs only).
  --max-iterations <n>                 Per-TODO gutter: exit after n attempts on the same open item (positive integer).
                                       Overrides CURSOR_PLAN_GUTTER_ITER / CLAUDE_PLAN_GUTTER_ITER / CODEX_PLAN_GUTTER_ITER.
  --timeout <duration>                 Invocation timeout (default: 30m). Format: e.g. 30m, 1800s, 2h.
  --help                               Show this message.

Environment variables:
  RALPH_PLAN_CONSOLIDATE=1             Collapse adjacent unchecked todos once at run start (off by default).
  RALPH_MODE=<no|native|ralph|hybrid>  Set Ralph tooling and native adapter mode (matches --ralph-mode flag; default no unless a prompt/preference selects otherwise).
  RALPH_SKIP_MCP_PREFLIGHT=1           Skip MCP preflight when Ralph MCP is active.
  RALPH_AGENT_WORKSPACE=<path>         Agent sandbox root (default: original invocation directory).
  RALPH_AGENT_SOURCE=<path>            Explicit agent source file (overrides probe order; same as --agent-source).
EOU
}

# Parse CLI flags for run-plan and configure environment variables.
# Args: none (consumes the passed-in argument list)
# Returns: 0 on success, non-zero on error
ralph_run_plan_parse_args() {
  local _ralph_session_strategy_env_was_set=0
  [[ "${RALPH_PLAN_SESSION_STRATEGY+x}" == x ]] && _ralph_session_strategy_env_was_set=1

  # Fail fast if the old split-knob env vars are set in the caller's environment.
  if [[ "${RALPH_AGENT_TOOL_ACCESS+x}" == x ]]; then
    ralph_die "Error: RALPH_AGENT_TOOL_ACCESS is no longer supported. Use RALPH_MODE=<no|native|ralph|hybrid> instead."
  fi
  if [[ "${RALPH_NATIVE_HOOKS+x}" == x ]]; then
    ralph_die "Error: RALPH_NATIVE_HOOKS is no longer supported. Use RALPH_MODE=<no|native|ralph|hybrid> instead."
  fi

  local _ralph_mode_env_was_set=0
  [[ "${RALPH_MODE+x}" == x ]] && _ralph_mode_env_was_set=1
  local _ralph_mode_env_value="${RALPH_MODE:-}"
  local RALPH_MODE_FLAG_SET=0
  local RALPH_MODE_FLAG_VALUE=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help)
        print_usage
        exit 0
        ;;
      --runtime)
        if [[ -z "${2:-}" ]]; then
          ralph_die "Error: --runtime requires an argument (cursor, claude, codex, opencode, or antigravity)."
        fi
        RUNTIME="$(ralph_normalize_runtime_name "$2")"
        case "$RUNTIME" in
          cursor|claude|codex|opencode|antigravity)
            ;;
          *)
            ralph_die "Error: --runtime must be one of cursor, claude, codex, opencode, or antigravity."
            ;;
        esac
        shift 2
        ;;
      --plan)
        if [[ -z "${2:-}" ]]; then
          ralph_die "Error: --plan requires a plan file path."
        fi
        PLAN_OVERRIDE="$2"
        shift 2
        ;;
      --model)
        if [[ -z "${2:-}" ]]; then
          ralph_die "Error: --model requires a model id string."
        fi
        PLAN_MODEL_CLI="$2"
        shift 2
        ;;
      --reasoning-effort)
        if [[ -z "${2:-}" ]]; then
          ralph_die "Error: --reasoning-effort requires a value (low, medium, high, xhigh, max, or inherit)."
        fi
        PLAN_REASONING_EFFORT_CLI="$2"
        shift 2
        ;;
      --claude-bare)
        CLAUDE_PLAN_BARE=1
        shift
        ;;
      --no-claude-bare)
        CLAUDE_PLAN_BARE=0
        shift
        ;;
      --claude-minimal)
        CLAUDE_PLAN_MINIMAL=1
        shift
        ;;
      --no-claude-minimal)
        CLAUDE_PLAN_MINIMAL=0
        shift
        ;;
      --claude-allow-mcp)
        CLAUDE_PLAN_MINIMAL_DISABLE_MCP=0
        shift
        ;;
      --no-claude-allow-mcp)
        CLAUDE_PLAN_MINIMAL_DISABLE_MCP=1
        shift
        ;;
      --claude-permission-mode)
        if [[ -z "${2:-}" ]]; then
          ralph_die "Error: --claude-permission-mode requires a mode (default, acceptEdits, auto, bypassPermissions, dontAsk, or plan)."
        fi
        CLAUDE_PLAN_PERMISSION_MODE="$2"
        shift 2
        ;;
      --codex-sandbox)
        if [[ -z "${2:-}" ]]; then
          ralph_die "Error: --codex-sandbox requires a mode (read-only, workspace-write, or danger-full-access)."
        fi
        CODEX_PLAN_SANDBOX="$2"
        shift 2
        ;;
      --codex-dangerously-bypass)
        if [[ -z "${2:-}" ]]; then
          ralph_die "Error: --codex-dangerously-bypass requires a value (0 or 1)."
        fi
        if ! ralph_validate_codex_boolean "$2"; then
          ralph_die "Error: --codex-dangerously-bypass / CODEX_PLAN_DANGEROUSLY_BYPASS_APPROVALS_AND_SANDBOX must be one of 0, 1, true, false, yes, no, on, or off."
        fi
        CODEX_PLAN_DANGEROUSLY_BYPASS_APPROVALS_AND_SANDBOX="$2"
        shift 2
        ;;
      --session-strategy)
        if [[ -z "${2:-}" ]]; then
          ralph_die "Error: --session-strategy requires one of fresh, resume, reset, or compact."
        fi
        if ! ralph_validate_session_strategy "$2"; then
          ralph_die "Error: --session-strategy must be one of fresh, resume, reset, or compact."
        fi
        SESSION_STRATEGY_FLAG="$2"
        shift 2
        ;;
      --agent)
        if [[ -z "${2:-}" ]]; then
          ralph_die "Error: --agent requires a prebuilt agent name (subdirectory of .<runtime>/agents/)."
        fi
        PREBUILT_AGENT="$2"
        shift 2
        ;;
      --agent-source)
        if [[ -z "${2:-}" ]]; then
          ralph_die "Error: --agent-source requires a path to an agent source file."
        fi
        RALPH_AGENT_SOURCE="$2"
        export RALPH_AGENT_SOURCE
        shift 2
        ;;
      --select-agent)
        INTERACTIVE_SELECT_AGENT_FLAG=1
        shift
        ;;
      --non-interactive | --no-interactive)
        NON_INTERACTIVE_FLAG=1
        shift
        ;;
      --cli-resume)
        CLI_RESUME_FLAG=1
        shift
        ;;
      --no-cli-resume)
        NO_CLI_RESUME_FLAG=1
        shift
        ;;
      --allow-unsafe-resume)
        ALLOW_UNSAFE_RESUME_FLAG=1
        shift
        ;;
      --ralph-tools)
        ralph_die "Error: --ralph-tools is removed. Use --ralph-mode ralph (or RALPH_MODE=ralph) to enable Ralph MCP tools."
        ;;
      --no-ralph-tools)
        ralph_die "Error: --no-ralph-tools is removed. Use --ralph-mode no (or RALPH_MODE=no) to disable Ralph tooling."
        ;;
      --tool-access)
        ralph_die "Error: --tool-access is removed. Use --ralph-mode <no|native|ralph|hybrid> (or RALPH_MODE) instead."
        ;;
      --native-hooks)
        ralph_die "Error: --native-hooks is removed. Use --ralph-mode <no|native|ralph|hybrid> (or RALPH_MODE) instead."
        ;;
      --ralph-mode)
        if [[ -z "${2:-}" ]]; then
          ralph_die "Error: --ralph-mode requires a value (no, native, ralph, or hybrid)."
        fi
        local _ralph_mode_arg
        _ralph_mode_arg="$(ralph_normalize_ralph_mode "$2")"
        if ! ralph_validate_ralph_mode "$_ralph_mode_arg"; then
          ralph_die "Error: --ralph-mode must be one of no, native, ralph, or hybrid."
        fi
        RALPH_MODE_FLAG_SET=1
        RALPH_MODE_FLAG_VALUE="$_ralph_mode_arg"
        shift 2
        ;;
      --skip-mcp-preflight)
        SKIP_MCP_PREFLIGHT_FLAG=1
        shift
        ;;
      --mcp-proxy)
        ralph_die "Error: --mcp-proxy is no longer supported. Use --ralph-mode ralph (or RALPH_MODE=ralph) to enable Ralph MCP tools."
        ;;
      --no-mcp-proxy)
        ralph_die "Error: --no-mcp-proxy is no longer supported. Use --ralph-mode no (or RALPH_MODE=no) to disable Ralph tooling."
        ;;
      --mcp-proxy-policy)
        ralph_die "Error: --mcp-proxy-policy is no longer supported. Set RALPH_MCP_PROXY_POLICY, RALPH_MCP_PROXY_POLICY_FILE, or RALPH_MCP_PROXY_POLICY_INLINE instead."
        ;;
      --mcp-proxy-policy-file)
        ralph_die "Error: --mcp-proxy-policy-file is no longer supported. Set RALPH_MCP_PROXY_POLICY_FILE or RALPH_MCP_PROXY_POLICY_INLINE instead."
        ;;
      --mcp-proxy-policy-inline)
        ralph_die "Error: --mcp-proxy-policy-inline is no longer supported. Set RALPH_MCP_PROXY_POLICY_INLINE or RALPH_MCP_PROXY_POLICY_FILE instead."
        ;;
      --resume)
        if [[ -z "${2:-}" ]]; then
          ralph_die "Error: --resume requires a session id."
        fi
        RESUME_SESSION_ID_OVERRIDE="$2"
        shift 2
        ;;
      --workspace)
        if [[ -z "${2:-}" ]]; then
          ralph_die "Error: --workspace requires a workspace path."
        fi
        WORKSPACE="$2"
        shift 2
        ;;
      --project-root)
        if [[ -z "${2:-}" ]]; then
          ralph_die "Error: --project-root requires a project path."
        fi
        PROJECT_ROOT_OVERRIDE="$2"
        shift 2
        ;;
      --workspace-root)
        if [[ -z "${2:-}" ]]; then
          ralph_die "Error: --workspace-root requires a directory path."
        fi
        WORKSPACE_ROOT_OVERRIDE="$2"
        shift 2
        ;;
      --agent-workspace)
        if [[ -z "${2:-}" ]]; then
          ralph_die "Error: --agent-workspace requires a directory path."
        fi
        AGENT_WORKSPACE_OVERRIDE="$2"
        shift 2
        ;;
      --max-iterations)
        if [[ -z "${2:-}" ]]; then
          ralph_die "Error: --max-iterations requires a positive integer."
        fi
        if ! [[ "$2" =~ ^[1-9][0-9]*$ ]]; then
          ralph_die "Error: --max-iterations must be a positive integer."
        fi
        RALPH_PLAN_TODO_MAX_ITERATIONS="$2"
        shift 2
        ;;
      --timeout)
        if [[ -z "${2:-}" ]]; then
          ralph_die "Error: --timeout requires a duration string (e.g. 30m, 1800s, 2h)."
        fi
        if ! [[ "$2" =~ ^[0-9]+(s|m|h)$ ]]; then
          ralph_die "Error: --timeout must be a positive integer with a unit (s, m, or h). Got '$2'."
        fi
        if [[ "${2%[smh]}" -le 0 ]]; then
          ralph_die "Error: --timeout duration must be positive. Got '$2'."
        fi
        RALPH_PLAN_INVOCATION_TIMEOUT_RAW="$2"
        shift 2
        ;;
      *)
        ralph_die "Error: unknown argument $1"
        ;;
    esac
  done

  if [[ -n "$PREBUILT_AGENT" && "$INTERACTIVE_SELECT_AGENT_FLAG" == "1" ]]; then
    ralph_die "Error: use only one of --agent <name> and --select-agent."
  fi

  if [[ "$NON_INTERACTIVE_FLAG" == "1" && "$INTERACTIVE_SELECT_AGENT_FLAG" == "1" ]]; then
    ralph_die "Error: --non-interactive cannot be combined with --select-agent."
  fi

  if [[ -n "$PROJECT_ROOT_OVERRIDE" ]]; then
    WORKSPACE="$PROJECT_ROOT_OVERRIDE"
  fi

  WORKSPACE="$(cd "$WORKSPACE" && pwd)"

  if [[ -n "${WORKSPACE_ROOT_OVERRIDE:-}" ]]; then
    WORKSPACE_ROOT_OVERRIDE="$(cd "$WORKSPACE_ROOT_OVERRIDE" && pwd)"
  fi

  # Handle agent workspace: use override if provided, otherwise default to original invocation directory
  if [[ -n "${AGENT_WORKSPACE_OVERRIDE:-}" ]]; then
    AGENT_WORKSPACE_OVERRIDE="$(cd "$AGENT_WORKSPACE_OVERRIDE" && pwd)"
    RALPH_AGENT_WORKSPACE="$AGENT_WORKSPACE_OVERRIDE"
  else
    # Default to current working directory (original invocation directory)
    RALPH_AGENT_WORKSPACE="$(pwd)"
  fi
  export RALPH_AGENT_WORKSPACE

  if [[ -z "${PLAN_OVERRIDE:-}" ]]; then
    ralph_die "Error: --plan <path> is required."
  fi

  if [[ -n "${CODEX_PLAN_SANDBOX:-}" ]]; then
    ralph_validate_codex_sandbox_mode "$CODEX_PLAN_SANDBOX"
    export CODEX_PLAN_SANDBOX
  fi

  if [[ -n "${CODEX_PLAN_DANGEROUSLY_BYPASS_APPROVALS_AND_SANDBOX:-}" ]]; then
    CODEX_PLAN_DANGEROUSLY_BYPASS_APPROVALS_AND_SANDBOX="$(ralph_normalize_codex_boolean "$CODEX_PLAN_DANGEROUSLY_BYPASS_APPROVALS_AND_SANDBOX")"
    export CODEX_PLAN_DANGEROUSLY_BYPASS_APPROVALS_AND_SANDBOX
  fi

  if [[ -n "${CLAUDE_PLAN_BARE:-}" ]]; then
    case "${CLAUDE_PLAN_BARE}" in
      1|true|yes|on)
        CLAUDE_PLAN_BARE=1
        ;;
      0|false|no|off)
        CLAUDE_PLAN_BARE=0
        ;;
      *)
        ralph_die "Error: --claude-bare / CLAUDE_PLAN_BARE must be one of 1, true, yes, on, 0, false, no, or off."
        ;;
    esac
    export CLAUDE_PLAN_BARE
  fi

  if [[ -n "${CLAUDE_PLAN_MINIMAL:-}" ]]; then
    case "${CLAUDE_PLAN_MINIMAL}" in
      1|true|yes|on)
        CLAUDE_PLAN_MINIMAL=1
        ;;
      0|false|no|off)
        CLAUDE_PLAN_MINIMAL=0
        ;;
      *)
        ralph_die "Error: --claude-minimal / CLAUDE_PLAN_MINIMAL must be one of 1, true, yes, on, 0, false, no, or off."
        ;;
    esac
    export CLAUDE_PLAN_MINIMAL
  fi

  if [[ -n "${CLAUDE_PLAN_MINIMAL_DISABLE_MCP:-}" ]]; then
    case "${CLAUDE_PLAN_MINIMAL_DISABLE_MCP}" in
      1|true|yes|on)
        CLAUDE_PLAN_MINIMAL_DISABLE_MCP=1
        ;;
      0|false|no|off)
        CLAUDE_PLAN_MINIMAL_DISABLE_MCP=0
        ;;
      *)
        ralph_die "Error: CLAUDE_PLAN_MINIMAL_DISABLE_MCP / --claude-allow-mcp must be one of 1, true, yes, on, 0, false, no, or off."
        ;;
    esac
    export CLAUDE_PLAN_MINIMAL_DISABLE_MCP
  fi

  if [[ -n "${CLAUDE_PLAN_PERMISSION_MODE:-}" ]]; then
    ralph_validate_claude_permission_mode "$CLAUDE_PLAN_PERMISSION_MODE"
    export CLAUDE_PLAN_PERMISSION_MODE
  fi

  if [[ -n "${RALPH_PLAN_TRANSCRIPT_EVICTION:-}" ]]; then
    RALPH_PLAN_TRANSCRIPT_EVICTION="$(ralph_normalize_transcript_eviction "$RALPH_PLAN_TRANSCRIPT_EVICTION")"
    if ! ralph_validate_transcript_eviction "$RALPH_PLAN_TRANSCRIPT_EVICTION"; then
      ralph_die "Error: RALPH_PLAN_TRANSCRIPT_EVICTION must be one of off, safe, or aggressive."
    fi
    export RALPH_PLAN_TRANSCRIPT_EVICTION
  fi

  # Resolve RALPH_MODE from the flag or env var only. When neither supplies a
  # mode, leave RALPH_MODE unset so run-plan-core can resolve it from the saved
  # ralph_mode_default preference, the interactive prompt, or the no default.
  local _resolved_ralph_mode=""
  if [[ "$RALPH_MODE_FLAG_SET" == "1" ]]; then
    _resolved_ralph_mode="$RALPH_MODE_FLAG_VALUE"
  elif [[ "$_ralph_mode_env_was_set" == "1" && -n "$_ralph_mode_env_value" ]]; then
    _resolved_ralph_mode="$(ralph_normalize_ralph_mode "$_ralph_mode_env_value")"
    if ! ralph_validate_ralph_mode "$_resolved_ralph_mode"; then
      ralph_die "Error: RALPH_MODE must be one of no, native, ralph, or hybrid."
    fi
  fi
  if [[ -n "$_resolved_ralph_mode" ]]; then
    RALPH_MODE="$_resolved_ralph_mode"
    export RALPH_MODE
    # Derive internal knobs from RALPH_MODE for backward compatibility with downstream code.
    ralph_apply_ralph_mode_to_knobs "$RALPH_MODE"
    export RALPH_AGENT_TOOL_ACCESS
    export RALPH_NATIVE_HOOKS
  else
    unset RALPH_MODE
  fi

  if [[ -n "${SESSION_STRATEGY_FLAG:-}" ]]; then
    RALPH_PLAN_SESSION_STRATEGY="$SESSION_STRATEGY_FLAG"
  elif [[ "$_ralph_session_strategy_env_was_set" == "1" ]]; then
    if ! ralph_validate_session_strategy "${RALPH_PLAN_SESSION_STRATEGY:-}"; then
      ralph_die "Error: RALPH_PLAN_SESSION_STRATEGY must be one of fresh, resume, reset, or compact."
    fi
  elif [[ "$NO_CLI_RESUME_FLAG" == "1" ]]; then
    RALPH_PLAN_SESSION_STRATEGY="fresh"
  elif [[ "$CLI_RESUME_FLAG" == "1" ]]; then
    RALPH_PLAN_SESSION_STRATEGY="resume"
  elif [[ "$_RALPH_CLI_RESUME_ENV_WAS_SET" == "1" ]]; then
    case "${RALPH_PLAN_CLI_RESUME:-0}" in
      1|true|yes|on) RALPH_PLAN_SESSION_STRATEGY="resume" ;;
      *) RALPH_PLAN_SESSION_STRATEGY="fresh" ;;
    esac
  else
    RALPH_PLAN_SESSION_STRATEGY="fresh"
    if [[ -t 0 ]] && [[ -t 1 ]]; then
      _RALPH_PROMPT_CLI_RESUME_INTERACTIVE=1
      _RALPH_PROMPT_SESSION_STRATEGY_INTERACTIVE=1
    fi
  fi

  if [[ -n "${RESUME_SESSION_ID_OVERRIDE:-}" ]]; then
    # Explicit session ids imply resume semantics for this run.
    RALPH_PLAN_SESSION_STRATEGY="resume"
  fi

  case "${RALPH_PLAN_SESSION_STRATEGY:-fresh}" in
    resume|reset|compact) RALPH_PLAN_CLI_RESUME=1 ;;
    *) RALPH_PLAN_CLI_RESUME=0 ;;
  esac
  export RALPH_PLAN_SESSION_STRATEGY

  if [[ "${RALPH_GRADER_STAGE:-0}" == "1" ]]; then
    case "${RALPH_PLAN_SESSION_STRATEGY:-fresh}" in
      fresh) ;;
      *)
        ralph_die "Error: grader stages require sessionStrategy fresh (not resume, reset, or compact)."
        ;;
    esac
  fi

  if [[ "$_ralph_session_strategy_env_was_set" == "1" ]]; then
    RALPH_PLAN_SESSION_STRATEGY_ENV_SPECIFIED=1
  else
    RALPH_PLAN_SESSION_STRATEGY_ENV_SPECIFIED=0
  fi
  export RALPH_PLAN_SESSION_STRATEGY_ENV_SPECIFIED

  RALPH_PLAN_ALLOW_UNSAFE_RESUME="${RALPH_PLAN_ALLOW_UNSAFE_RESUME:-0}"
  if [[ "$ALLOW_UNSAFE_RESUME_FLAG" == "1" ]]; then
    RALPH_PLAN_ALLOW_UNSAFE_RESUME=1
  fi
  case "${RALPH_PLAN_ALLOW_UNSAFE_RESUME:-0}" in
    1|true|yes|on) RALPH_PLAN_ALLOW_UNSAFE_RESUME=1 ;;
    *) RALPH_PLAN_ALLOW_UNSAFE_RESUME=0 ;;
  esac
  # When 1, allows CLI resume without a stored session id (unsafe on shared hosts); visible to subprocesses.
  export RALPH_PLAN_ALLOW_UNSAFE_RESUME

  RALPH_SKIP_MCP_PREFLIGHT="${RALPH_SKIP_MCP_PREFLIGHT:-${SKIP_MCP_PREFLIGHT_FLAG:-0}}"
  case "${RALPH_SKIP_MCP_PREFLIGHT}" in
    1|true|yes|on) RALPH_SKIP_MCP_PREFLIGHT=1 ;;
    *) RALPH_SKIP_MCP_PREFLIGHT=0 ;;
  esac
  export RALPH_SKIP_MCP_PREFLIGHT

  # Handle RALPH_STRICT_PROXY normalization
  if [[ -n "${RALPH_STRICT_PROXY:-}" ]]; then
    case "${RALPH_STRICT_PROXY}" in
      1|true|yes|on) RALPH_STRICT_PROXY=1 ;;
      0|false|no|off) RALPH_STRICT_PROXY=0 ;;
      *)
        ralph_die "Error: RALPH_STRICT_PROXY must be one of 0, 1, true, false, yes, no, on, or off."
        ;;
    esac
    export RALPH_STRICT_PROXY
  fi

  # Reject legacy RALPH_OPTIMIZATION_MODE; it has been removed.
  if [[ -n "${RALPH_OPTIMIZATION_MODE:-}" ]]; then
    ralph_die "Error: RALPH_OPTIMIZATION_MODE is no longer supported. Use RALPH_MODE=<no|native|ralph|hybrid> (or --ralph-mode) instead."
  fi

}

# Normalize RALPH_PLAN_CONTEXT_BUDGET (full / standard / lean; default standard).
case "${RALPH_PLAN_CONTEXT_BUDGET:-standard}" in
  full|standard|lean) ;;
  *) RALPH_PLAN_CONTEXT_BUDGET="standard" ;;
esac
RALPH_PLAN_CONTEXT_BUDGET="${RALPH_PLAN_CONTEXT_BUDGET:-standard}"
export RALPH_PLAN_CONTEXT_BUDGET

# Human-context byte cap for non-resume (fresh) invocations when standard/lean budget is active.
: "${RALPH_HUMAN_CONTEXT_MAX_BYTES_NO_RESUME:=2048}"
export RALPH_HUMAN_CONTEXT_MAX_BYTES_NO_RESUME
