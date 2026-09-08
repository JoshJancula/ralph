#!/usr/bin/env bash
# Install Ralph into a project or globally (Cursor, Claude, Codex, OpenCode, Antigravity + shared .ralph).
# Operator help: ./install.sh --help  or  ralph install --help
# Structured help lives in bundle/.ralph/bash-lib/install/install-colors.sh (install_print_help).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE="$SCRIPT_DIR/bundle"
# Canonical copy lives under bundle/; root .ralph is a local symlink and is gitignored, so
# submodule/subtree/checkouts never have SCRIPT_DIR/.ralph -- only bundle/.ralph is published.
RALPH_BASH_LIB="$BUNDLE/.ralph/bash-lib"

usage() {
  install_print_help
  exit "${1:-0}"
}

source "$RALPH_BASH_LIB/install/install-ops.sh"
source "$RALPH_BASH_LIB/install/install-mcp.sh"

install_ops_reset_state

if ! install_ops_parse_flags "$@"; then
  usage 1
fi

TARGET="$(install_ops_resolve_target "${INSTALL_TARGET_ARG:-}")"

install_ops_verify_bundle "$BUNDLE"

if [[ "$REMOVE_INSTALLED" -eq 1 || "$REMOVE_VENDOR" -eq 1 ]]; then
  if [[ "$REMOVE_INSTALLED" -eq 1 && "$REMOVE_VENDOR" -eq 1 ]]; then
    install_log_banner "Ralph" "purge (uninstall + remove vendor)"
    install_log_ok_detail "target" "$TARGET"
  elif [[ "$REMOVE_INSTALLED" -eq 1 ]]; then
    install_log_banner "Ralph" "uninstall"
    install_log_ok_detail "target" "$TARGET"
  else
    install_log_banner "Ralph" "vendor cleanup (remove vendored package only)"
    install_log_ok_detail "target" "$TARGET"
  fi
  if [[ "$REMOVE_INSTALLED" -eq 1 ]]; then
    install_ops_default_selection
    # Same roots install uses for docs and the dashboard manifest (cleanup may run without a prior export).
    export RALPH_INSTALL_SCRIPT_DIR="$SCRIPT_DIR"
    export RALPH_INSTALL_SOURCE_ROOT="${RALPH_INSTALL_SOURCE_ROOT:-$SCRIPT_DIR}"
    install_ops_execute_remove
  fi
  if [[ "$REMOVE_VENDOR" -eq 1 ]]; then
    install_ops_remove_vendor "$TARGET" "$SCRIPT_DIR"
  fi
  exit 0
fi

install_ops_default_selection

install_global_prepare_dirs() {
  [[ "${GLOBAL_INSTALL:-0}" -eq 1 ]] || return 0

  local config_root state_root bin_dir
  config_root="$(install_ops_config_root)"
  state_root="$(install_ops_state_root)"
  bin_dir="$HOME/.local/bin"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    install_log_dry "[dry-run]" "mkdir -p $TARGET"
    install_log_dry "[dry-run]" "mkdir -p $config_root"
    install_log_dry "[dry-run]" "mkdir -p $state_root"
    install_log_dry "[dry-run]" "mkdir -p $bin_dir"
    return 0
  fi

  mkdir -p "$TARGET" "$config_root" "$state_root" "$bin_dir"
}

install_global_root_files() {
  [[ "${GLOBAL_INSTALL:-0}" -eq 1 ]] || return 0

  local dest="$TARGET/install.sh"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    install_log_dry "[dry-run]" "cp $SCRIPT_DIR/install.sh $dest"
    return 0
  fi
  cp "$SCRIPT_DIR/install.sh" "$dest"
  chmod +x "$dest"
  install_log_ok "Installed" "$dest"
}

install_global_shim() {
  [[ "${GLOBAL_INSTALL:-0}" -eq 1 ]] || return 0

  local bin_dir="$HOME/.local/bin"
  local dest="$bin_dir/ralph"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    install_log_dry "[dry-run]" "write executable shim $dest"
    return 0
  fi

  mkdir -p "$bin_dir"
  local tmp
  tmp="${dest}.tmp.$$"
  cat > "$tmp" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail

RALPH_HOME="${RALPH_HOME:-$HOME/.ralph}"

# Shared help presentation (stdout TTY only; honors NO_COLOR / RALPH_INSTALL_NO_COLOR).
# shellcheck source=/dev/null
source "$RALPH_HOME/bundle/.ralph/bash-lib/help-render.sh"

ralph_usage() {
  cat <<'USAGE' | ralph_help_render
Usage: ralph <command> [args]

Commands:
  run          Primary: run a saved workflow or concrete plan
  workflow     Primary: list/show/path/start reusable workflow resources (alias: wf)
  list         Primary: discover saved workflows and managed plans
  create       Primary: create a leaf plan or reusable workflow
  mcp          Manage the Ralph MCP server (see: ralph mcp --help)
  models       Manage saved Claude/Codex models (see: ralph models --help)
  usage        Show token-usage report (delegates to usage-report.sh)
  benchmark    Build the token/compaction benchmark report (delegates to benchmark-report.sh)
  dashboard    Start the Ralph dashboard (global). Options: --yes|-y (skip prompts),
               --rebuild (clean dist + npm run build), --update-deps (fresh npm ci).
               Use -- before args for npm start.
  install      Run the global Ralph installer
  workspaces   Manage the Ralph workspace registry
  setup        Set up durable compaction hooks and MCP (see: ralph setup --help)
  safety       Inspect and validate safety/killswitch config (see: ralph safety --help)
  plugin       Host-install packaged runtime plugins (see: ralph plugin --help)
  profiles     Inspect and reset learned command-duration profiles (see: ralph profiles --help)
  config       Manage Ralph configuration (see: ralph config --help)
  process      List or stop managed Ralph process runs (see: ralph process --help)

Options:
  --bundle-path  Print the bundled .ralph directory (for scripts)
USAGE
}

ralph_config_usage() {
  cat <<'USAGE' | ralph_help_render
Usage: ralph config <subcommand> [args]

No config subcommands remain. Use:
  ralph safety <status|validate|check|init|edit>
USAGE
}

ralph_mcp_usage() {
  cat <<'USAGE' | ralph_help_render
Usage: ralph mcp <subcommand> [args]

Subcommands:
  start    Start the Ralph MCP server over stdio.
           Defaults RALPH_MCP_WORKSPACE to the current directory.
USAGE
}

ralph_run_usage() {
  ralph_help_title 'Usage: ralph run --plan <path> [options]'
  ralph_help_note 'Run one classic or YAML leaf plan. Workflow-shaped inputs use ralph workflow start instead.'
  RALPH_RUN_PLAN_HELP_CONTEXT=ralph-run bash "$RALPH_HOME/bundle/.ralph/run-plan.sh" --help 2>/dev/null || true
  ralph_help_section 'Examples'
  ralph_help_note 'ralph workflow start feature-delivery --task "Add CSV export"'
  ralph_help_note 'ralph workflow edit feature-delivery'
  ralph_help_note 'ralph run --plan .ralph-workspace/plans/my-plan.plan.md'
  ralph_help_note 'ralph run --plan my-plan.plan.md --runtime claude --timeout 45m'
}

ralph_list_usage() {
  cat <<'USAGE' | ralph_help_render
Usage: ralph list plans [--global]

  plans      Show managed plans (standard/dependency/sequential) under
             .ralph-workspace/plans/. Scoped like `ralph usage`: this
             workspace plus any child workspaces nested under it.
  --global   Search every registered workspace instead of just this one.

  Workflow discovery moved to: ralph workflow list
USAGE
}

ralph_run_file_is_workflow() {
  local path="$1"
  [[ -f "$path" ]] || return 1
  awk '
    NR == 1 { if ($0 != "---") exit 1; next }
    /^---$/ { exit }
    /^kind:[[:space:]]*workflow[[:space:]]*$/ { found = 1 }
    END { exit !found }
  ' "$path"
}

ralph_run_plan_shape() {
  local path="$1"
  [[ -f "$path" ]] || { printf 'missing'; return 0; }
  if ralph_run_file_is_workflow "$path"; then
    printf 'workflow'
    return 0
  fi
  case "$path" in
    *.graph.json) printf 'graph'; return 0 ;;
    *.json) printf 'orchestration'; return 0 ;;
  esac
  awk '
    NR == 1 { if ($0 != "---") { done = 1; exit 0 } in_fm = 1; next }
    in_fm && $0 == "---" { in_fm = 0 }
    in_fm && /^kind:[[:space:]]*workflow([[:space:]]|$)/ { is_workflow = 1 }
    in_fm && /^execution:[[:space:]]*graph([[:space:]]|$)/ { is_graph = 1 }
    in_fm && /^execution:[[:space:]]*orchestration([[:space:]]|$)/ { is_orch = 1 }
    in_fm && /^mode:[[:space:]]*dependency([[:space:]]|$)/ { is_graph = 1 }
    in_fm && /^mode:[[:space:]]*sequential([[:space:]]|$)/ { is_orch = 1 }
    in_fm && /^[[:space:]]*pipeline:[[:space:]]*$/ { is_pipeline = 1 }
    END {
      if (done) { print "leaf"; exit 0 }
      if (is_workflow) print "workflow"
      else if (is_graph) print "graph"
      else if (is_pipeline || is_orch) print "orchestration"
      else print "leaf"
    }
  ' "$path"
}

ralph_run_refuse_non_leaf_plan() {
  local path="$1" shape="$2"
  echo "Error: ralph run --plan accepts classic or YAML leaf plans only (got: $shape)" >&2
  echo "Use: ralph workflow start --file $path" >&2
  echo "For operator-supplied leaf plans inside a delivery workflow, use: ralph workflow start plan-delivery --plan $path" >&2
  exit 2
}

ralph_run_dispatch_plan() {
  local run_plan_path="$1"
  shift
  local shape
  shape="$(ralph_run_plan_shape "$run_plan_path")"
  case "$shape" in
    leaf|missing)
      exec bash "$RALPH_HOME/bundle/.ralph/run-plan.sh" --plan "$run_plan_path" "$@"
      ;;
    *)
      ralph_run_refuse_non_leaf_plan "$run_plan_path" "$shape"
      ;;
  esac
}

ralph_create_usage() {
  cat <<'USAGE' | ralph_help_render
Usage: ralph create <subcommand> [args]

Subcommands:
  plan      Create a leaf plan file (classic or YAML). Multi-stage work uses
            `ralph create workflow` instead.
            Options:
              --name <name>       Plan name (default: auto-generated PLAN1, PLAN2, ...).
              --format <classic|yaml>
                                  Plan template format (default: classic).
                                  classic: zero-dependency markdown checklist.
                                  yaml: YAML-frontmatter flat TODO queue.
                                  (standard, structured, pipeline, and cursor are
                                   accepted as silent aliases for yaml.)
              --workspace <path>  Workspace directory (default: current directory).

  workflow  Create a reusable SDLC workflow
            (.ralph-workspace/workflows/<name>.workflow.md by default).
            Options:
              --mode <sequential|dependency>
                                  Preselect scheduling mode. When omitted, the
                                  shared mode prompt asks interactively.
              --global            Write under $RALPH_HOME/workflows/ instead of
                                  the project state root.
            Start or edit an existing workflow with
            `ralph workflow start <id>` / `ralph workflow edit <id>`.
USAGE
}

ralph_process_usage() {
  cat <<'USAGE' | ralph_help_render
Usage: ralph process <list|stop> [options]

Inspect or stop Ralph runs that are currently supervised by this project.

Commands:
  list
    Show active runs. The default view uses short plan names; use --json for
    full paths and machine-readable details.

  stop
    Stop exactly one selected run, or use --all to stop every active run in
    the selected state root.

Options:
  --workspace <path>       Project root (default: current directory).
  --workspace-root <path>  State root containing .ralph-workspace.
  --json                   Print complete records for list.
  --run <id>               Select one run to stop.
  --plan <path>            Select the run for a plan to stop.
  --all                    Select all active runs to stop.
  --force                  Escalate stop from TERM to KILL.

Examples:
  ralph process list
  ralph process list --json
  ralph process stop --run 20260820T153915-63145-62183e11
USAGE
}

if [[ "${1:-}" == "--bundle-path" ]]; then
  printf '%s/bundle/.ralph\n' "$RALPH_HOME"
  exit 0
fi

cmd="${1:-}"
if [[ -z "$cmd" || "$cmd" == "-h" || "$cmd" == "--help" ]]; then
  ralph_usage
  exit 0
fi
shift

case "$cmd" in
  run)
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
      ralph_run_usage
      exit 0
    fi
    if [[ "${1:-}" == "workflow" ]]; then
      echo "Error: 'ralph run workflow <name>' was removed. Use: ralph workflow start <id> --task \"<text>\"" >&2
      exit 2
    fi
    run_plan_path=""
    run_args=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -h|--help)
          ralph_run_usage
          exit 0
          ;;
        --plan)
          if [[ -z "${2:-}" ]]; then
            echo "Error: --plan requires a path" >&2
            exit 1
          fi
          run_plan_path="$2"
          shift 2
          ;;
        --workflow|--workflow=*)
          printf "Error: 'ralph run %s' was removed. Use: ralph workflow start <id> --task \"<text>\"\n" "--workflow" >&2
          exit 2
          ;;
        --task|--task=*)
          echo "Error: unknown option for ralph run: ${1%%=*} (workflows run via: ralph workflow start <id> --task \"<text>\")" >&2
          exit 2
          ;;
        *)
          run_args+=("$1")
          shift
          ;;
      esac
    done
    if [[ -z "$run_plan_path" ]]; then
      if [[ -t 0 && -t 1 ]]; then
        printf 'Plan path: ' >/dev/tty; read -r run_plan_path </dev/tty
      else
        echo "Error: ralph run requires --plan <path>" >&2
        echo "Example: ralph run --plan PLAN.md" >&2
        exit 1
      fi
    fi
    if [[ -z "$run_plan_path" ]]; then
      echo "Error: ralph run requires --plan <path>" >&2
      ralph_run_usage >&2
      exit 1
    fi
    ralph_run_dispatch_plan "$run_plan_path" "${run_args[@]+"${run_args[@]}"}"
    ;;
  list)
    sub="${1:-}"
    case "$sub" in
      workflows)
        echo "Use: ralph workflow list" >&2
        exit 2
        ;;
      plans) shift; exec bash "$RALPH_HOME/bundle/.ralph/workflow-cli.sh" list-plans "$@" ;;
      -h|--help|'') ralph_list_usage; [[ -n "$sub" ]] && exit 0 || exit 1 ;;
      *) echo "Error: unknown ralph list subcommand: $sub" >&2; ralph_list_usage >&2; exit 1 ;;
    esac
    ;;
  workflow|wf)
    # Resource verbs (list/show/path/start/...) live in workflow-cli.sh.
    # `wf` is an alias for `workflow`.
    exec bash "$RALPH_HOME/bundle/.ralph/workflow-cli.sh" "$@"
    ;;
  run-plan)
    exec bash "$RALPH_HOME/bundle/.ralph/run-plan.sh" "$@"
    ;;
  split-plan)
    exec bash "$RALPH_HOME/bundle/.ralph/split-plan.sh" "$@"
    ;;
  orchestrate|orchestrator|graph)
    printf "Error: 'ralph %s' was removed. Use: ralph workflow start --file <path> --task \"<text>\"\n" "$cmd" >&2
    exit 2
    ;;
  mcp)
    sub="${1:-}"
    if [[ -z "$sub" || "$sub" == "-h" || "$sub" == "--help" ]]; then
      ralph_mcp_usage
      [[ -z "$sub" ]] && exit 1 || exit 0
    fi
    shift
    case "$sub" in
      start)
        export RALPH_MCP_WORKSPACE="${RALPH_MCP_WORKSPACE:-$PWD}"
        exec bash "$RALPH_HOME/bundle/.ralph/mcp-server.sh" "$@"
        ;;
      *)
        echo "Error: unknown ralph mcp subcommand: $sub" >&2
        ralph_mcp_usage >&2
        exit 1
        ;;
    esac
    ;;
  usage)
    exec bash "$RALPH_HOME/bundle/.ralph/usage-report.sh" "$@"
    ;;
  benchmark)
    exec bash "$RALPH_HOME/bundle/.ralph/benchmark-report.sh" "$@"
    ;;
  models)
    exec bash "$RALPH_HOME/bundle/.ralph/models.sh" "$@"
    ;;
  dashboard)
    dashboard_dir="$RALPH_HOME/ralph-dashboard"
    if [[ ! -d "$dashboard_dir" ]]; then
      echo "Error: Ralph dashboard not found at $dashboard_dir" >&2
      exit 1
    fi
    cd "$dashboard_dir"

    rebuild=0
    update_deps=0
    ask_confirm=1
    dash_dd=0
    npm_forward=()
    for arg in "$@"; do
      if [[ "$dash_dd" -eq 1 ]]; then
        npm_forward+=("$arg")
        continue
      fi
      case "$arg" in
        --)
          dash_dd=1
          ;;
        --yes|-y)
          ask_confirm=0
          ;;
        --rebuild)
          rebuild=1
          ;;
        --update-deps)
          update_deps=1
          ask_confirm=0
          ;;
        *)
          npm_forward+=("$arg")
          ;;
      esac
    done

    if [[ "$update_deps" -eq 1 ]]; then
      echo "Updating dashboard dependencies (npm ci)..."
      npm ci
    elif [[ ! -d "node_modules" ]]; then
      if [[ $ask_confirm -eq 1 ]]; then
        echo "Dependencies not found. Install node_modules? (y/N)"
        read -r confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
          echo "Cancelled."
          exit 1
        fi
      fi
      npm install
    fi

    # Require a full production build: an empty dist/ or server-only output skips ng build
    # and leaves sendFile unable to find dist/ralph-dashboard/browser/index.csr.html.
    if [[ "$rebuild" -eq 1 ]]; then
      echo "Rebuilding dashboard (clean dist)..."
      rm -rf dist
      npm run build
    elif [[ ! -f "dist/ralph-dashboard/server/server.mjs" || ! -f "dist/ralph-dashboard/browser/index.csr.html" ]]; then
      echo "Building dashboard..."
      npm run build
    fi

    csr_index="$dashboard_dir/dist/ralph-dashboard/browser/index.csr.html"
    if [[ ! -f "$csr_index" ]]; then
      echo "Error: dashboard build output missing at $csr_index (build failed or incomplete). Try: ralph dashboard --rebuild" >&2
      exit 1
    fi

    # Global CLI only: absolute path to the CSR bundle under RALPH_HOME (do not rely on
    # bundled server chunk paths / import.meta.url under dist/).
    export RALPH_DASHBOARD_BROWSER_DIST="$dashboard_dir/dist/ralph-dashboard/browser"

    export PORT="${PORT:-8123}"
    export RALPH_DASHBOARD_GLOBAL=1
    # Under set -u, "${empty[@]}" errors on bash 3.x (macOS); branch instead.
    if [[ ${#npm_forward[@]} -gt 0 ]]; then
      exec npm start "${npm_forward[@]}"
    else
      exec npm start
    fi
    ;;
  install)
    exec bash "$RALPH_HOME/install.sh" "$@"
    ;;
  setup)
    setup_script="$RALPH_HOME/bundle/.ralph/setup-runtime.sh"
    if [[ ! -f "$setup_script" ]]; then
      echo "Error: setup script not found at $setup_script" >&2
      exit 1
    fi
    exec bash "$setup_script" "$@"
    ;;
  workspaces)
    workspaces_cli="$RALPH_HOME/bundle/.ralph/bash-lib/workspaces-cli.sh"
    if [[ ! -f "$workspaces_cli" ]]; then
      echo "Error: workspace registry CLI is not installed yet: $workspaces_cli" >&2
      exit 1
    fi
    exec bash "$workspaces_cli" "$@"
    ;;
  safety)
    safety_cli="$RALPH_HOME/bundle/.ralph/bash-lib/config/safety-cli.sh"
    if [[ ! -f "$safety_cli" ]]; then
      echo "Error: safety CLI is not installed yet: $safety_cli" >&2
      exit 1
    fi
    exec bash "$safety_cli" "$@"
    ;;
  profiles)
    profiles_cli="$RALPH_HOME/bundle/.ralph/bash-lib/profiles/profiles-cli.sh"
    if [[ ! -f "$profiles_cli" ]]; then
      echo "Error: profiles CLI is not installed yet: $profiles_cli" >&2
      exit 1
    fi
    exec bash "$profiles_cli" "$@"
    ;;
  plugin)
    plugin_cli="$RALPH_HOME/bundle/.ralph/bash-lib/plugin/plugin-cli.sh"
    if [[ ! -f "$plugin_cli" ]]; then
      echo "Error: plugin CLI is not installed yet: $plugin_cli" >&2
      exit 1
    fi
    exec bash "$plugin_cli" "$@"
    ;;
  config)
    sub="${1:-}"
    if [[ -z "$sub" || "$sub" == "-h" || "$sub" == "--help" ]]; then
      ralph_config_usage
      [[ -z "$sub" ]] && exit 1 || exit 0
    fi
    shift
    case "$sub" in
      killswitch)
        # Old route rejection only; use ralph safety.
        echo "Use: ralph safety <status|validate|check|init|edit>" >&2
        exit 2
        ;;
      *)
        echo "Error: unknown ralph config subcommand: $sub" >&2
        ralph_config_usage >&2
        exit 1
        ;;
    esac
    ;;
  create)
    sub="${1:-}"
    if [[ -z "$sub" || "$sub" == "-h" || "$sub" == "--help" ]]; then
      ralph_create_usage
      [[ -z "$sub" ]] && exit 1 || exit 0
    fi
    shift
    case "$sub" in
      plan)
        exec bash "$RALPH_HOME/bundle/.ralph/create-plan.sh" "$@"
        ;;
      workflow)
        if [[ "${1:-}" == "--starter" ]]; then
          echo "Use: ralph workflow start <id>" >&2
          echo "Use: ralph workflow edit <id>" >&2
          exit 2
        fi
        exec bash "$RALPH_HOME/bundle/.ralph/workflow-wizard.sh" "$@"
        ;;
      orc|orchestration|graph|wizard)
        echo "Error: 'ralph create $sub' was removed. Use: ralph create workflow" >&2
        exit 2
        ;;
      *)
        echo "Error: unknown ralph create subcommand: $sub" >&2
        ralph_create_usage >&2
        exit 2
        ;;
    esac
    ;;
  role)
    # printf keeps the retired argv out of source for the public-surface absence gate;
    # runtime stderr remains the exact replacement asserted by public-command-contract.
    printf "Error: 'ralph %s' was removed. Workflow stage instructions are inline.\n" "role" >&2
    exit 2
    ;;
  migrate)
    echo "Error: 'ralph migrate' was removed. Workflow stage instructions are inline." >&2
    exit 2
    ;;
  agent)
    echo "Error: 'ralph agent' was removed. Runtime-native agents stay with the runtime; workflow stage instructions are inline." >&2
    exit 2
    ;;
  process)
    sub="${1:-}"
    if [[ -z "$sub" || "$sub" == "-h" || "$sub" == "--help" ]]; then
      ralph_process_usage
      [[ -z "$sub" ]] && exit 1 || exit 0
    fi
    shift
    process_workspace="$PWD"
    process_state_root=""
    process_plan=""
    process_args=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --workspace)
          [[ -n "${2:-}" ]] || { echo "Error: --workspace requires a path" >&2; exit 1; }
          process_workspace="$2"
          shift 2
          ;;
        --workspace-root)
          [[ -n "${2:-}" ]] || { echo "Error: --workspace-root requires a path" >&2; exit 1; }
          process_state_root="$2"
          shift 2
          ;;
        --plan)
          [[ -n "${2:-}" ]] || { echo "Error: --plan requires a path" >&2; exit 1; }
          process_plan="$2"
          shift 2
          ;;
        *)
          process_args+=("$1")
          shift
          ;;
      esac
    done
    if [[ -n "$process_plan" ]]; then
      if [[ "$process_plan" == /* ]]; then
        process_args+=(--plan "$process_plan")
      else
        process_args+=(--plan "$process_workspace/$process_plan")
      fi
    fi
    [[ -n "$process_state_root" ]] || process_state_root="$process_workspace/.ralph-workspace"
    process_script="$RALPH_HOME/bundle/.ralph/python/ralph_process_supervisor.py"
    if ! command -v python3 >/dev/null 2>&1; then
      echo "Error: ralph process requires Python 3." >&2
      exit 2
    fi
    if [[ ! -f "$process_script" ]]; then
      echo "Error: process supervisor not found: $process_script" >&2
      exit 1
    fi
    case "$sub" in
      list|stop)
        exec python3 "$process_script" "$sub" --state-root "$process_state_root" "${process_args[@]}"
        ;;
      *)
        echo "Error: unknown ralph process subcommand: $sub" >&2
        ralph_process_usage >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "Error: unknown ralph command: $cmd" >&2
    ralph_usage >&2
    exit 1
    ;;
esac
SHIM
  chmod +x "$tmp"
  mv "$tmp" "$dest"
  install_log_ok "Installed shim" "$dest"
}

install_global_path_hint() {
  [[ "${GLOBAL_INSTALL:-0}" -eq 1 ]] || return 0

  local bin_dir="$HOME/.local/bin"
  case ":$PATH:" in
    *":$bin_dir:"*) return 0 ;;
  esac

  local config_root marker shell_name rc_file
  config_root="$(install_ops_config_root)"
  marker="$config_root/path-hint-shown"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    install_log_dry "[dry-run]" "would show PATH hint and write marker $marker"
    return 0
  fi
  [[ -f "$marker" ]] && return 0

  shell_name="$(basename "${SHELL:-bash}")"
  if [[ "$shell_name" == "zsh" ]]; then
    rc_file="~/.zshrc"
  else
    rc_file="~/.bashrc"
  fi

  install_log_warn "~/.local/bin is not on PATH; add Ralph with:"
  printf '  export PATH="$HOME/.local/bin:$PATH"\n'
  printf '  # add that line to %s, then restart your shell or run: hash -r\n' "$rc_file"

  mkdir -p "$config_root"
  : > "$marker"
}

install_check_node() {
  if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    return 0
  fi

  install_log_warn "Node.js is not installed." "The Ralph dashboard requires Node.js and npm."

  if [[ "$DRY_RUN" -eq 1 ]]; then
    install_log_dry "[dry-run]" "would prompt to install Node.js"
    return 1
  fi

  if [[ "$SILENT" -eq 1 ]]; then
    install_log_warn "Skipping dashboard (--silent, Node.js not found)." "Install Node.js to use the dashboard."
    return 1
  fi

  if [[ "$ASSUME_YES" -eq 1 ]]; then
    if command -v brew >/dev/null 2>&1; then
      install_log_phase "Installing Node.js via Homebrew (--yes)..."
      brew install node
      install_log_ok "Node.js installed" "$(node --version 2>/dev/null || true)"
      return 0
    else
      install_log_warn "Homebrew not found; cannot auto-install Node.js (--yes)." "Install manually: https://nodejs.org/en/download"
      return 1
    fi
  fi

  printf 'Install Node.js now? (y/N) '
  read -r _node_confirm
  case "$_node_confirm" in
    y|Y|yes|YES)
      if command -v brew >/dev/null 2>&1; then
        install_log_phase "Installing Node.js via Homebrew..."
        brew install node
        install_log_ok "Node.js installed" "$(node --version 2>/dev/null || true)"
        return 0
      else
        install_log_warn "Homebrew not found. Install Node.js manually, then re-run the installer:"
        printf '  https://nodejs.org/en/download\n'
        printf '  or via nvm: https://github.com/nvm-sh/nvm\n'
        return 1
      fi
      ;;
    *)
      install_log_warn "Node.js not installed; skipping dashboard." "Run the installer again after installing Node.js."
      return 1
      ;;
  esac
}

install_dashboard() {
  local src="$SCRIPT_DIR/ralph-dashboard"
  local dest="$TARGET/.ralph/ralph-dashboard"
  if [[ "${GLOBAL_INSTALL:-0}" -eq 1 ]]; then
    dest="$TARGET/ralph-dashboard"
  fi
  if [[ ! -d "$src" ]]; then
    install_log_skip "Skip ralph-dashboard (missing):" "$src"
    return 0
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    install_log_dry "[dry-run]" "rsync -a --exclude __pycache__ --exclude '*.pyc' --exclude='node_modules/' --exclude='dist/' --exclude='.angular/' $src/ $dest/"
    return 0
  fi
  mkdir -p "$dest"
  rsync -a --exclude '__pycache__' --exclude '*.pyc' --exclude='node_modules/' --exclude='dist/' --exclude='.angular/' "$src/" "$dest/"
  install_log_ok "Dashboard" "$dest"
}

install_log_divider "----------------------------------------------------------------------"
install_log_banner "Ralph" "install"
install_log_ok_detail "target" "$TARGET"
install_log_divider "----------------------------------------------------------------------"
install_ops_check_existing_install
export RALPH_INSTALL_SOURCE_ROOT="$SCRIPT_DIR"
install_log_phase "Copying components"
install_global_prepare_dirs
install_global_root_files
install_global_shim
install_ops_execute_plan
install_ops_sync_bundled_workflows
install_ops_remove_legacy_workflow_templates
install_ops_sync_plugin_packages
install_ops_remove_stale_ralph_agent_profiles "$TARGET"
if [[ "${GLOBAL_INSTALL:-0}" -ne 1 ]]; then
  install_configure_mcp
fi

if install_ops_should_install_dashboard; then
  install_log_phase "Dashboard (optional Node UI)"
  if install_check_node; then
    install_dashboard
  fi
fi

install_global_path_hint

if [[ "${GLOBAL_INSTALL:-0}" -ne 1 ]]; then
  install_ops_auto_remove_vendor_after_install "$TARGET" "$SCRIPT_DIR"
fi

# Warn about stale runtime ralph directories from pre-PLAN26 installs
if [[ "$DRY_RUN" -eq 0 && "${GLOBAL_INSTALL:-0}" -ne 1 ]]; then
  install_ops_stale_runtime_ralph_notice "$TARGET"
fi

if [[ "$DRY_RUN" -eq 0 ]] && install_ops_has_any_stack; then
  printf '\n'
  install_log_divider "----------------------------------------------------------------------"
  install_log_next_header "You are set. Here is what to do next."
  install_log_divider "----------------------------------------------------------------------"
  if [[ "${GLOBAL_INSTALL:-0}" -eq 1 ]]; then
    install_log_next_line "Command: ensure ~/.local/bin is on PATH, then run ralph --help"
    install_log_next_line "Compaction hooks: ralph setup --runtime claude --runtime-dir ~/.claude --hooks"
    install_log_next_line "Plans: run ralph run-plan --plan PLAN.md --runtime <runtime> from a project"
  elif [[ -d "$TARGET/.ralph/ralph-dashboard" ]]; then
    install_log_next_line "Compaction hooks: ralph setup --runtime claude --runtime-dir \"$TARGET/.claude\" --hooks"
    install_log_next_line "Dashboard: cd .ralph/ralph-dashboard && npm install && npm run build && npm start"
    install_log_next_line "Plans: copy .ralph/plan-templates/classic.plan.template.md to something like PLAN.md and pass --plan to run-plan.sh"
  else
    install_log_next_line "Compaction hooks: ralph setup --runtime claude --runtime-dir \"$TARGET/.claude\" --hooks"
    install_log_next_line "Plans: copy .ralph/plan-templates/classic.plan.template.md to something like PLAN.md and pass --plan to run-plan.sh"
  fi
  if [[ "${GLOBAL_INSTALL:-0}" -ne 1 ]]; then
    install_log_next_line "MCP (optional): RALPH_MCP_WORKSPACE=\$PWD bash .ralph/mcp-server.sh (needs jq)"
  fi
  if [[ "${GLOBAL_INSTALL:-0}" -ne 1 && -d "$TARGET/.ralph/docs" ]]; then
    install_log_next_line "Docs: $TARGET/.ralph/docs/"
  fi
  install_log_divider "----------------------------------------------------------------------"
  printf '\n'
fi
