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
#   --shared    Only .ralph/ (orchestrator, cleanup, plan.template)
#   --cursor    .cursor/ralph + rules/skills/agents (no-emoji, repo-context, ralph-starter)
#   --codex     .codex/ralph + rules/skills/agents (same)
#   --claude    .claude/ralph + rules/skills/agents (same)
#   --no-dashboard   Skip copying ralph-dashboard/ into TARGET
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
DRY_RUN=0
INSTALL_SHARED=0
INSTALL_CURSOR=0
INSTALL_CODEX=0
INSTALL_CLAUDE=0
INSTALL_DASHBOARD=1
SELECTION_SPECIFIED=0

usage() {
  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)
      INSTALL_SHARED=1
      INSTALL_CURSOR=1
      INSTALL_CODEX=1
      INSTALL_CLAUDE=1
      SELECTION_SPECIFIED=1
      shift
      ;;
    --shared)
      INSTALL_SHARED=1
      SELECTION_SPECIFIED=1
      shift
      ;;
    --cursor)
      INSTALL_CURSOR=1
      SELECTION_SPECIFIED=1
      shift
      ;;
    --codex)
      INSTALL_CODEX=1
      SELECTION_SPECIFIED=1
      shift
      ;;
    --claude)
      INSTALL_CLAUDE=1
      SELECTION_SPECIFIED=1
      shift
      ;;
    --no-dashboard)
      INSTALL_DASHBOARD=0
      shift
      ;;
    -n|--dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage 1
      ;;
    *)
      break
      ;;
  esac
done

if [[ "$SELECTION_SPECIFIED" -eq 0 ]]; then
  INSTALL_SHARED=1
  INSTALL_CURSOR=1
  INSTALL_CODEX=1
  INSTALL_CLAUDE=1
fi

TARGET="${1:-.}"
if [[ ! -d "$TARGET" ]]; then
  echo "Target must be an existing directory (your repo root): $TARGET" >&2
  exit 1
fi
TARGET="$(cd "$TARGET" && pwd)"

if [[ ! -d "$BUNDLE" ]]; then
  echo "Missing bundle at $BUNDLE (clone this repo completely)." >&2
  exit 1
fi

copy_tree() {
  local src="$1" dest="$2"
  if [[ ! -d "$src" ]]; then
    echo "Skip (missing): $src" >&2
    return 0
  fi
  mkdir -p "$dest"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[dry-run] rsync -a $src/ $dest/"
    return 0
  fi
  rsync -a "$src/" "$dest/"
  echo "Installed: $dest"
}

install_cursor_stack() {
  copy_tree "$BUNDLE/.cursor/ralph" "$TARGET/.cursor/ralph"
  [[ -d "$BUNDLE/.cursor/rules" ]] && copy_tree "$BUNDLE/.cursor/rules" "$TARGET/.cursor/rules"
  [[ -d "$BUNDLE/.cursor/skills" ]] && copy_tree "$BUNDLE/.cursor/skills" "$TARGET/.cursor/skills"
  [[ -d "$BUNDLE/.cursor/agents" ]] && copy_tree "$BUNDLE/.cursor/agents" "$TARGET/.cursor/agents"
}

install_codex_stack() {
  copy_tree "$BUNDLE/.codex/ralph" "$TARGET/.codex/ralph"
  [[ -d "$BUNDLE/.codex/rules" ]] && copy_tree "$BUNDLE/.codex/rules" "$TARGET/.codex/rules"
  [[ -d "$BUNDLE/.codex/skills" ]] && copy_tree "$BUNDLE/.codex/skills" "$TARGET/.codex/skills"
  [[ -d "$BUNDLE/.codex/agents" ]] && copy_tree "$BUNDLE/.codex/agents" "$TARGET/.codex/agents"
}

install_claude_stack() {
  copy_tree "$BUNDLE/.claude/ralph" "$TARGET/.claude/ralph"
  [[ -d "$BUNDLE/.claude/rules" ]] && copy_tree "$BUNDLE/.claude/rules" "$TARGET/.claude/rules"
  [[ -d "$BUNDLE/.claude/skills" ]] && copy_tree "$BUNDLE/.claude/skills" "$TARGET/.claude/skills"
  [[ -d "$BUNDLE/.claude/agents" ]] && copy_tree "$BUNDLE/.claude/agents" "$TARGET/.claude/agents"
}

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
[[ "$INSTALL_SHARED" -eq 1 ]] && copy_tree "$BUNDLE/.ralph" "$TARGET/.ralph"
[[ "$INSTALL_CURSOR" -eq 1 ]] && install_cursor_stack
[[ "$INSTALL_CODEX" -eq 1 ]] && install_codex_stack
[[ "$INSTALL_CLAUDE" -eq 1 ]] && install_claude_stack
[[ "$INSTALL_DASHBOARD" -eq 1 ]] && [[ "$INSTALL_SHARED$INSTALL_CURSOR$INSTALL_CODEX$INSTALL_CLAUDE" != "0000" ]] && install_dashboard

if [[ "$DRY_RUN" -eq 0 ]] && [[ "$INSTALL_SHARED$INSTALL_CURSOR$INSTALL_CODEX$INSTALL_CLAUDE" != "0000" ]]; then
  echo ""
  echo "Next: python3 ralph-dashboard/server.py for the local dashboard; optional package.json scripts (docs/package-scripts.snippet.json); add PLAN.md from .ralph/plan.template as needed."
  echo "Docs: $SCRIPT_DIR/README.md"
fi
