# run-plan-args.sh -- argument parsing for .ralph/run-plan.sh (sourced only; not standalone).
#
# Public interface:
#   print_usage -- writes run-plan --help text to stdout.
#   ralph_run_plan_parse_args -- consumes "$@"; sets WORKSPACE, RUNTIME, PLAN_OVERRIDE, agent/model
#     flags, and resume-related globals. Exports RALPH_PLAN_ALLOW_UNSAFE_RESUME for child processes
#     when bare resume is allowed.

PROJECT_ROOT_OVERRIDE=""
WORKSPACE_ROOT_OVERRIDE=""

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

# Print the run-plan CLI usage summary.
# Args: none
# Returns: 0 on success, non-zero on error
print_usage() {
  cat <<'EOU'
Usage: .ralph/run-plan.sh --plan <path> [OPTIONS]

Required:
  --plan <path>                        Path to the plan file relative to the workspace.

Options:
  --runtime <cursor|claude|codex|opencode>  CLI runtime (omit if RALPH_PLAN_RUNTIME is set or you use the interactive prompt).
  --workspace <path>                   Repo workspace root (default: current directory).
  --project-root <path>                Alias for --workspace; where the project (and .ralph/) lives.
  --workspace-root <path>              Directory that contains .ralph-workspace (defaults to <project>/.ralph-workspace).

Common options:
  --agent <name>                       Prebuilt agent directory under .<runtime>/agents/.
  --select-agent                       Pick a prebuilt agent interactively.
  --non-interactive / --no-interactive  Skip interactive prompts.
  --model <id>                         CLI model id (overrides agent default).
  --claude-bare                        Enable Claude --bare / CLAUDE_PLAN_BARE (default: off; fewer automatic context sources, lower overhead).
  --claude-permission-mode <default|acceptEdits|auto|bypassPermissions|dontAsk|plan>
                                       Set CLAUDE_PLAN_PERMISSION_MODE for Claude exec (omit to use the CLI default; modes that skip or auto-approve permissions reduce safety).
  --codex-sandbox <read-only|workspace-write|danger-full-access>
                                        Sets CODEX_PLAN_SANDBOX for Codex exec (default: workspace-write; danger-full-access is high risk).
  --codex-full-auto <0|1>
                                        Sets CODEX_PLAN_FULL_AUTO for Codex exec (default: 1; 0 disables --full-auto flag).
  --codex-dangerously-bypass <0|1>
                                        Sets CODEX_PLAN_DANGEROUSLY_BYPASS_APPROVALS_AND_SANDBOX (default: 0; 1 adds --dangerously-bypass-approvals-and-sandbox; isolated-runner-only).
  --cli-resume / --no-cli-resume       Enable/disable CLI resume prompts.
  --allow-unsafe-resume                Allow bare CLI resume without session id.
  --resume <id>                        Force a CLI session id for this run.
  --max-iterations <n>                 Per-TODO gutter: exit after n attempts on the same open item (positive integer).
                                       Overrides CURSOR_PLAN_GUTTER_ITER / CLAUDE_PLAN_GUTTER_ITER / CODEX_PLAN_GUTTER_ITER.
  --timeout <duration>                 Invocation timeout (default: 30m). Format: e.g. 30m, 1800s, 2h.
  --help                               Show this message.
EOU
}

# Parse CLI flags for run-plan and configure environment variables.
# Args: none (consumes the passed-in argument list)
# Returns: 0 on success, non-zero on error
ralph_run_plan_parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help)
        print_usage
        exit 0
        ;;
      --runtime)
        if [[ -z "${2:-}" ]]; then
          ralph_die "Error: --runtime requires an argument (cursor, claude, codex, or opencode)."
        fi
        case "$2" in
          cursor|claude|codex|opencode)
            RUNTIME="$2"
            ;;
          *)
            ralph_die "Error: --runtime must be one of cursor, claude, codex, or opencode."
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
      --claude-bare)
        CLAUDE_PLAN_BARE=1
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
      --codex-full-auto)
        if [[ -z "${2:-}" ]]; then
          ralph_die "Error: --codex-full-auto requires a value (0 or 1)."
        fi
        if ! ralph_validate_codex_boolean "$2"; then
          ralph_die "Error: --codex-full-auto / CODEX_PLAN_FULL_AUTO must be one of 0, 1, true, false, yes, no, on, or off."
        fi
        CODEX_PLAN_FULL_AUTO="$2"
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
      --agent)
        if [[ -z "${2:-}" ]]; then
          ralph_die "Error: --agent requires a prebuilt agent name (subdirectory of .<runtime>/agents/)."
        fi
        PREBUILT_AGENT="$2"
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

  if [[ -z "${PLAN_OVERRIDE:-}" ]]; then
    ralph_die "Error: --plan <path> is required."
  fi

  if [[ -n "${CODEX_PLAN_SANDBOX:-}" ]]; then
    ralph_validate_codex_sandbox_mode "$CODEX_PLAN_SANDBOX"
    export CODEX_PLAN_SANDBOX
  fi

  if [[ -n "${CODEX_PLAN_FULL_AUTO:-}" ]]; then
    CODEX_PLAN_FULL_AUTO="$(ralph_normalize_codex_boolean "$CODEX_PLAN_FULL_AUTO")"
    export CODEX_PLAN_FULL_AUTO
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

  if [[ -n "${CLAUDE_PLAN_PERMISSION_MODE:-}" ]]; then
    ralph_validate_claude_permission_mode "$CLAUDE_PLAN_PERMISSION_MODE"
    export CLAUDE_PLAN_PERMISSION_MODE
  fi

  if [[ "$NO_CLI_RESUME_FLAG" == "1" ]]; then
    RALPH_PLAN_CLI_RESUME=0
  elif [[ "$CLI_RESUME_FLAG" == "1" ]]; then
    RALPH_PLAN_CLI_RESUME=1
  elif [[ "$_RALPH_CLI_RESUME_ENV_WAS_SET" == "1" ]]; then
    case "${RALPH_PLAN_CLI_RESUME:-0}" in
      1|true|yes|on) RALPH_PLAN_CLI_RESUME=1 ;;
      *) RALPH_PLAN_CLI_RESUME=0 ;;
    esac
  else
    RALPH_PLAN_CLI_RESUME=0
    if [[ -t 0 ]] && [[ -t 1 ]]; then
      _RALPH_PROMPT_CLI_RESUME_INTERACTIVE=1
    fi
  fi

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
