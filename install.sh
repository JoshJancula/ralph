#!/usr/bin/env bash
# Install Ralph agent workflows into a project (Cursor, Claude Code, Codex, OpenCode + shared .ralph).
#
# Usage:
#   ./install.sh [OPTIONS] [TARGET_DIR]          (local install)
#   ./install.sh --global [OPTIONS]              (global install; see docs/INSTALL.md)
#
# TARGET_DIR defaults to the current directory (your repo root). Mutually exclusive with --global.
#
# Options:
#   --all       Install everything (default)
#   --global    Install once under ${RALPH_HOME:-$HOME/.ralph}/ for use across many projects
#               Writes config to ${XDG_CONFIG_HOME:-$HOME/.config}/ralph/ and state to
#               ${XDG_STATE_HOME:-$HOME/.local/state}/ralph/. Creates ~/.local/bin/ralph shim.
#               See docs/INSTALL.md for rationale, layout, and runtime config precedence.
#               Copies this repository's docs/ directory to $RALPH_HOME/docs/ when present (framework docs for the dashboard).
#   --force-global-runtime   With --global, overwrite/update existing $HOME/.<runtime>/ configs
#               (without this flag, existing user runtime configs are preserved)
#   --shared    Only .ralph/ (orchestrator, cleanup, plan-templates/, docs -> .ralph/docs/)
#   --cursor    .cursor/ agents/rules/skills (no-emoji rule, repo-context skill)
#   --codex     .codex/ agents/rules/skills + hooks/ (native hook scripts)
#   --claude    .claude/ agents/rules/skills + hooks/ (native hook scripts)
#   --opencode  .opencode/ agents/rules/skills + plugins/ (Ralph runtime plugin)
#   --antigravity  .agents/ agents/rules/skills (Antigravity agy runtime; reads .agents/)
#   --shared    .ralph/ including bash-lib helpers used by runtime hooks (command-rewriter, compactors, etc.)
#   --no-dashboard   Skip copying the dashboard (local: TARGET/.ralph/ralph-dashboard/, global: $RALPH_HOME/ralph-dashboard/)
#   -s, --silent   Run without interactive prompts (skip conflicts, configure MCP, skip removal prompts)
#   -y, --yes      Assume "yes" for the "already installed, overwrite?" prompt (overwrites existing files)
#   -n, --dry-run   Print what would be copied or removed, do not write
#   -h, --help
#   --remove-installed, --uninstall   Remove Ralph-installed files under TARGET (bundle manifest only; honors stack flags)
#   --remove-vendor      Remove the vendored Ralph package directory when it sits under TARGET (e.g. vendor/ralph)
#   --cleanup            Same as --remove-vendor (manual removal; normal install already drops vendor when safe)
#   --purge              Full removal: --uninstall for all stacks and the dashboard, then --remove-vendor
#
#   When install.sh lives under TARGET and that folder is not its own Git checkout (typical git subtree
#   copy), the vendored directory is removed after install. Submodule or clone checkouts keep vendor/
#   unless you set RALPH_INSTALL_REMOVE_VENDOR=1. Set RALPH_INSTALL_KEEP_VENDOR=1 to always keep vendor/.
#
#   NO_COLOR (https://no-color.org, any value) or RALPH_INSTALL_NO_COLOR=1 disables colored installer output.
#
# Examples:
#   git submodule add https://github.com/you/ralph.git vendor/ralph
#   ./vendor/ralph/install.sh                                    (local: copy into current project)
#   ./vendor/ralph/install.sh --cursor /path/to/other-repo      (local: copy into another project)
#   ./vendor/ralph/install.sh --antigravity /path/to/other-repo (local: copy antigravity runtime)
#   ./install.sh --global                                        (global: install once for all projects)
#   ./vendor/ralph/install.sh --cleanup -n
#   ./vendor/ralph/install.sh --purge --silent
#   ./install.sh --global --yes                                  (global: skip prompts for CI)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE="$SCRIPT_DIR/bundle"
# Canonical copy lives under bundle/; root .ralph is a local symlink and is gitignored, so
# submodule/subtree/checkouts never have SCRIPT_DIR/.ralph -- only bundle/.ralph is published.
RALPH_BASH_LIB="$BUNDLE/.ralph/bash-lib"

usage() {
  sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'
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

ralph_usage() {
  cat <<'USAGE'
Usage: ralph <command> [args]

Commands:
  run          Run a plan (--plan <path>; auto-detects classic, standard, or orchestration)
  create       Create scaffolding (subcommands: orc, plan)
  run-plan     Run a Ralph plan (legacy; prefer: ralph run --plan)
  split-plan   Preview or apply executable TODO normalization
  orchestrate  Run a Ralph orchestration directly (advanced; prefer: ralph run --plan)
  graph        Compile/lint a graph-mode plan's artifact DAG (see: ralph graph --help)
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
  config       Manage Ralph configuration (see: ralph config --help)
  agent        Manage agent profiles (see: ralph agent --help)
  process      List or stop managed Ralph process runs (see: ralph process --help)

Options:
  --bundle-path  Print the bundled .ralph directory (for scripts)
USAGE
}

ralph_graph_usage() {
  cat <<'USAGE'
Usage: ralph graph <verb> [args]

Verbs:
  compile <plan-path> [--render mermaid|dot|ascii] [--out <path>] [--force]
      Compile a graph-mode plan into .graph.json, validate it, and cache the
      result beside the plan.

  run <plan-path> [--namespace <ns>] [--max-parallel <n>]
      Compile and run a graph plan to completion.

  resume <plan-path> --namespace <ns> --run <run-id|latest> [--accept-graph-change]
      Resume a graph run from the durable run-state ledger.

  status
      Not implemented yet; lands in a later phase of the GRAPH-MODE plan.

  render
      Not implemented yet; lands in a later phase of the GRAPH-MODE plan.
USAGE
}

ralph_config_usage() {
  cat <<'USAGE'
Usage: ralph config <subcommand> [args]

Subcommands:
  killswitch   Manage killswitch.json (see: ralph config killswitch --help)
USAGE
}

ralph_mcp_usage() {
  cat <<'USAGE'
Usage: ralph mcp <subcommand> [args]

Subcommands:
  start    Start the Ralph MCP server over stdio.
           Defaults RALPH_MCP_WORKSPACE to the current directory.
USAGE
}

ralph_run_usage() {
  cat <<'USAGE'
Usage: ralph run --plan <path> [options]

  --plan  Run a plan file. The format is auto-detected:
            classic markdown checklist or flat yaml-frontmatter plan -> run-plan.sh
            orchestration plan (pipeline frontmatter) or .orch.json -> orchestrator.sh
            graph plan (execution: graph frontmatter) or .graph.json -> graph-run.sh
          Remaining options are forwarded to the selected runner.
USAGE
}

ralph_create_usage() {
  cat <<'USAGE'
Usage: ralph create <subcommand> [args]

Subcommands:
  orc   Launch the orchestration wizard for a multi-stage pipeline plan.
  plan  Create a flat plan file (delegates to create-plan.sh).
        Options:
          --name <name>            Plan name (default: auto-generated PLAN1, PLAN2, ...).
          --format <classic|yaml>
                                   Plan template format (default: classic).
                                   classic: zero-dependency markdown checklist.
                                   yaml: YAML-frontmatter flat TODO queue.
                                   (standard, structured, pipeline, orchestration, and cursor are accepted as silent aliases for yaml.)
          --workspace <path>       Workspace directory (default: current directory).

        For a multi-stage orchestration, use: ralph create orc
USAGE
}

ralph_process_usage() {
  cat <<'USAGE'
Usage: ralph process <subcommand> [options]

Subcommands:
  list [--workspace PATH] [--workspace-root PATH] [--json]
  stop (--run ID|--plan PATH|--all) [--workspace PATH] [--workspace-root PATH] [--force]
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
        *)
          run_args+=("$1")
          shift
          ;;
      esac
    done
    if [[ -z "$run_plan_path" ]]; then
      echo "Error: ralph run requires --plan <path>" >&2
      ralph_run_usage >&2
      exit 1
    fi
    # Route by file content/name: graph plans (execution: graph or .graph.json)
    # go to graph-run.sh; orchestration plans (pipeline frontmatter, .orch.json,
    # execution: orchestration) go to orchestrator.sh; everything else goes to
    # run-plan.sh. Match execution: graph before pipeline: because graph plans
    # also carry a pipeline block and match order determines correctness.
    ralph_run_plan_kind() {
      local path="$1"
      # .graph.json -> graph runner
      [[ "$path" == *.graph.json ]] && { echo "graph"; return 0; }
      # other .json (legacy .orch.json) -> orchestrator
      [[ "$path" == *.json ]] && { echo "orchestration"; return 0; }
      [[ -f "$path" ]] || { echo "standard"; return 0; }
      awk '
        NR == 1 { if ($0 != "---") { print "standard"; exit 0 } in_fm = 1; next }
        in_fm && $0 == "---" { in_fm = 0 }
        in_fm && /^execution:[[:space:]]*graph/ { is_graph = 1 }
        in_fm && /^[[:space:]]*pipeline:[[:space:]]*/ { is_pipeline = 1 }
        in_fm && /^execution:[[:space:]]*orchestration/ { is_orch = 1 }
        END {
          if (is_graph) { print "graph" }
          else if (is_pipeline || is_orch) { print "orchestration" }
          else { print "standard" }
        }
      ' "$path"
    }
    ralph_run_is_orchestration() {
      local kind
      kind="$(ralph_run_plan_kind "$1")"
      [ "$kind" = "orchestration" ]
    }
    run_kind="$(ralph_run_plan_kind "$run_plan_path")"
    case "$run_kind" in
      graph)
        exec bash "$RALPH_HOME/bundle/.ralph/graph-run.sh" run "$run_plan_path" "${run_args[@]+"${run_args[@]}"}"
        ;;
      orchestration)
        exec bash "$RALPH_HOME/bundle/.ralph/orchestrator.sh" --orchestration "$run_plan_path" "${run_args[@]+"${run_args[@]}"}"
        ;;
      *)
        exec bash "$RALPH_HOME/bundle/.ralph/run-plan.sh" --plan "$run_plan_path" "${run_args[@]+"${run_args[@]}"}"
        ;;
    esac
    ;;
  run-plan)
    exec bash "$RALPH_HOME/bundle/.ralph/run-plan.sh" "$@"
    ;;
  split-plan)
    exec bash "$RALPH_HOME/bundle/.ralph/split-plan.sh" "$@"
    ;;
  orchestrate|orchestrator)
    exec bash "$RALPH_HOME/bundle/.ralph/orchestrator.sh" "$@"
    ;;
  graph)
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
      ralph_graph_usage
      exit 0
    fi
    graph_cli="$RALPH_HOME/bundle/.ralph/graph-run.sh"
    if [[ ! -f "$graph_cli" ]]; then
      echo "Error: graph CLI is not installed yet: $graph_cli" >&2
      exit 1
    fi
    exec bash "$graph_cli" "$@"
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
  config)
    sub="${1:-}"
    if [[ -z "$sub" || "$sub" == "-h" || "$sub" == "--help" ]]; then
      ralph_config_usage
      [[ -z "$sub" ]] && exit 1 || exit 0
    fi
    shift
    case "$sub" in
      killswitch)
        killswitch_cli="$RALPH_HOME/bundle/.ralph/bash-lib/config/killswitch-cli.sh"
        if [[ ! -f "$killswitch_cli" ]]; then
          echo "Error: killswitch config CLI is not installed yet: $killswitch_cli" >&2
          exit 1
        fi
        exec bash "$killswitch_cli" "$@"
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
      orc)
        exec bash "$RALPH_HOME/bundle/.ralph/orchestration-wizard.sh" "$@"
        ;;
      plan)
        exec bash "$RALPH_HOME/bundle/.ralph/create-plan.sh" "$@"
        ;;
      *)
        echo "Error: unknown ralph create subcommand: $sub" >&2
        ralph_create_usage >&2
        exit 1
        ;;
    esac
    ;;
  agent)
    agent_cli="$RALPH_HOME/bundle/.ralph/agent.sh"
    if [[ ! -f "$agent_cli" ]]; then
      echo "Error: agent CLI is not installed yet: $agent_cli" >&2
      exit 1
    fi
    exec bash "$agent_cli" "$@"
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
