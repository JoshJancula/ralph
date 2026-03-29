#!/usr/bin/env bash
# Install Ralph agent workflows into a project (Cursor, Claude Code, Codex, OpenCode + shared .ralph).
#
# Usage:
#   ./install.sh [OPTIONS] [TARGET_DIR]
#
# TARGET_DIR defaults to the current directory (your repo root).
#
# Options:
#   --all       Install everything (default)
#   --shared    Only .ralph/ (orchestrator, cleanup, plan.template, docs -> .ralph/docs/)
#   --cursor    .cursor/ralph + rules/skills/agents (no-emoji, repo-context)
#   --codex     .codex/ralph + rules/skills/agents (same)
#   --claude    .claude/ralph + rules/skills/agents (same)
#   --opencode  .opencode/ralph + rules/skills/agents (same)
#   --no-dashboard   Skip copying the dashboard into TARGET/.ralph/ralph-dashboard/
#   -s, --silent   Run without interactive prompts (skip conflicts, configure MCP, skip removal prompts)
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
#   ./vendor/ralph/install.sh
#   ./vendor/ralph/install.sh --cursor /path/to/other-repo
#   ./vendor/ralph/install.sh --cleanup -n
#   ./vendor/ralph/install.sh --purge --silent

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE="$SCRIPT_DIR/bundle"
# Canonical copy lives under bundle/; root .ralph is a local symlink and is gitignored, so
# submodule/subtree/checkouts never have SCRIPT_DIR/.ralph -- only bundle/.ralph is published.
RALPH_BASH_LIB="$BUNDLE/.ralph/bash-lib"

usage() {
  sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

source "$RALPH_BASH_LIB/install-ops.sh"
source "$RALPH_BASH_LIB/install-mcp.sh"

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

install_dashboard() {
  local src="$SCRIPT_DIR/ralph-dashboard"
  local dest="$TARGET/.ralph/ralph-dashboard"
  if [[ ! -d "$src" ]]; then
    install_log_skip "Skip ralph-dashboard (missing):" "$src"
    return 0
  fi
  mkdir -p "$dest"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    install_log_dry "[dry-run]" "rsync -a --exclude __pycache__ --exclude '*.pyc' $src/ $dest/"
    return 0
  fi
  rsync -a --exclude '__pycache__' --exclude '*.pyc' "$src/" "$dest/"
  install_log_ok "Dashboard" "$dest"
}

install_log_divider "----------------------------------------------------------------------"
install_log_banner "Ralph" "install"
install_log_ok_detail "target" "$TARGET"
install_log_divider "----------------------------------------------------------------------"
export RALPH_INSTALL_SOURCE_ROOT="$SCRIPT_DIR"
install_log_phase "Copying components"
install_ops_execute_plan
install_configure_mcp

if install_ops_should_install_dashboard; then
  install_log_phase "Dashboard (optional Python UI)"
  install_dashboard
fi

install_ops_auto_remove_vendor_after_install "$TARGET" "$SCRIPT_DIR"

if [[ "$DRY_RUN" -eq 0 ]] && install_ops_has_any_stack; then
  printf '\n'
  install_log_divider "----------------------------------------------------------------------"
  install_log_next_header "You are set. Here is what to do next."
  install_log_divider "----------------------------------------------------------------------"
  if [[ -d "$TARGET/.ralph/ralph-dashboard" ]]; then
    install_log_next_line "Dashboard: python3 -m pip install -e .ralph/ralph-dashboard && python3 -m ralph_dashboard"
    install_log_next_line "Plans: copy .ralph/plan.template to something like PLAN.md and pass --plan to run-plan.sh"
  else
    install_log_next_line "Plans: copy .ralph/plan.template to something like PLAN.md and pass --plan to run-plan.sh"
  fi
  install_log_next_line "MCP (optional): RALPH_MCP_WORKSPACE=\$PWD bash .ralph/mcp-server.sh (needs jq)"
  if [[ -d "$TARGET/.ralph/docs" ]]; then
    install_log_next_line "Docs: $TARGET/.ralph/docs/"
  fi
  install_log_divider "----------------------------------------------------------------------"
  printf '\n'
fi
