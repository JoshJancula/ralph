# run-plan-args.sh -- argument parsing for .ralph/run-plan.sh (sourced only; not standalone).
#
# Public interface:
#   print_usage -- writes run-plan --help text to stdout.
#   ralph_run_plan_parse_args -- consumes "$@"; sets WORKSPACE, RUNTIME, PLAN_OVERRIDE, agent/model
#     flags, and resume-related globals. Exports RALPH_PLAN_ALLOW_UNSAFE_RESUME for child processes
#     when bare resume is allowed.

# Print the run-plan CLI usage summary.
# Args: none
# Returns: 0 on success, non-zero on error
print_usage() {
  cat <<'EOU'
Usage: .ralph/run-plan.sh --plan <path> [OPTIONS]

Required:
  --plan <path>                        Path to the plan file relative to the workspace.

Options:
  --runtime <cursor|claude|codex>      CLI runtime (omit if RALPH_PLAN_RUNTIME is set or you use the interactive prompt).
  --workspace <path>                   Repo workspace root (default: current directory).

Common options:
  --agent <name>                       Prebuilt agent directory under .<runtime>/agents/.
  --select-agent                       Pick a prebuilt agent interactively.
  --non-interactive / --no-interactive  Skip interactive prompts.
  --model <id>                         CLI model id (overrides agent default).
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
          ralph_die "Error: --runtime requires an argument (cursor, claude, or codex)."
        fi
        case "$2" in
          cursor|claude|codex)
            RUNTIME="$2"
            ;;
          *)
            ralph_die "Error: --runtime must be one of cursor, claude, or codex."
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

  WORKSPACE="$(cd "$WORKSPACE" && pwd)"

  if [[ -z "${PLAN_OVERRIDE:-}" ]]; then
    ralph_die "Error: --plan <path> is required."
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
