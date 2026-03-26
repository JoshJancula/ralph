#!/usr/bin/env bash
# Install Ralph agent workflows into a project (Cursor, Claude Code, Codex + shared .ralph).
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
#   --no-dashboard   Skip copying ralph-dashboard/ into TARGET
#   -s, --silent   Run without interactive prompts (skip conflicts, configure MCP)
#   -n, --dry-run   Print what would be copied, do not write
#   -h, --help
#
# Examples:
#   git submodule add https://github.com/you/ralph.git vendor/ralph
#   ./vendor/ralph/install.sh
#   ./vendor/ralph/install.sh --cursor /path/to/other-repo

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE="$SCRIPT_DIR/bundle"
# Canonical copy lives under bundle/; root .ralph is a local symlink and is gitignored, so
# submodule/subtree/checkouts never have SCRIPT_DIR/.ralph -- only bundle/.ralph is published.
RALPH_BASH_LIB="$BUNDLE/.ralph/bash-lib"

usage() {
  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

source "$RALPH_BASH_LIB/install-ops.sh"
source "$RALPH_BASH_LIB/install-mcp.sh"

install_ops_reset_state

if ! install_ops_parse_flags "$@"; then
  usage 1
fi

install_ops_default_selection

TARGET="$(install_ops_resolve_target "${INSTALL_TARGET_ARG:-}")"

install_ops_verify_bundle "$BUNDLE"

install_dashboard() {
  local src="$SCRIPT_DIR/ralph-dashboard"
  local dest="$TARGET/ralph-dashboard"
  if [[ ! -d "$src" ]]; then
    echo "Skip ralph-dashboard (missing): $src" >&2
    return 0
  fi
  mkdir -p "$dest"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[dry-run] rsync -a --exclude __pycache__ --exclude '*.pyc' $src/ $dest/"
    return 0
  fi
  rsync -a --exclude '__pycache__' --exclude '*.pyc' "$src/" "$dest/"
  echo "Installed: $dest"
}

echo "Ralph install -> $TARGET"
export RALPH_INSTALL_SOURCE_ROOT="$SCRIPT_DIR"
install_ops_execute_plan
install_configure_mcp

if install_ops_should_install_dashboard; then
  install_dashboard
fi

if [[ "$DRY_RUN" -eq 0 ]] && install_ops_has_any_stack; then
  echo ""
  echo "Next: python3 ralph-dashboard/server.py for the local dashboard; optional package.json scripts (docs/package-scripts.snippet.json); add PLAN.md from .ralph/plan.template as needed."
  echo "The canonical bash MCP server is bundled in .ralph/mcp-server.sh; run it with RALPH_MCP_WORKSPACE=\$PWD bash .ralph/mcp-server.sh once jq is installed."
  if [[ -d "$TARGET/.ralph/docs" ]]; then
    echo "Docs: $TARGET/.ralph/docs/"
  fi
  echo "Package README: $SCRIPT_DIR/README.md"
fi
