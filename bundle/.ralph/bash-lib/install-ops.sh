#!/usr/bin/env bash
set -euo pipefail

install_ops_reset_state() {
  DRY_RUN=0
  INSTALL_SHARED=0
  INSTALL_CURSOR=0
  INSTALL_CODEX=0
  INSTALL_CLAUDE=0
  INSTALL_DASHBOARD=1
  SELECTION_SPECIFIED=0
  INSTALL_TARGET_ARG=""
}

install_ops_parse_flags() {
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
        printf 'Unknown option: %s\n' "$1" >&2
        return 1
        ;;
      *)
        INSTALL_TARGET_ARG="$1"
        break
        ;;
    esac
  done
  return 0
}

install_ops_default_selection() {
  if [[ "$SELECTION_SPECIFIED" -eq 0 ]]; then
    INSTALL_SHARED=1
    INSTALL_CURSOR=1
    INSTALL_CODEX=1
    INSTALL_CLAUDE=1
  fi
}

install_ops_resolve_target() {
  local raw="${1:-.}"
  [[ -z "$raw" ]] && raw="."
  if [[ ! -d "$raw" ]]; then
    printf 'Target must be an existing directory (your repo root): %s\n' "$raw" >&2
    return 1
  fi
  (cd "$raw" && pwd)
}

install_ops_verify_bundle() {
  local bundle_path="$1"
  if [[ ! -d "$bundle_path" ]]; then
    printf 'Missing bundle at %s (clone this repo completely).\n' "$bundle_path" >&2
    return 1
  fi
}

install_ops_has_any_stack() {
  [[ "$INSTALL_SHARED$INSTALL_CURSOR$INSTALL_CODEX$INSTALL_CLAUDE" != "0000" ]]
}

install_ops_should_install_dashboard() {
  [[ "$INSTALL_DASHBOARD" -eq 1 ]] && install_ops_has_any_stack
}

install_ops_emit_copy() {
  local src="$1"
  local dest="$2"
  local label="${3:-}"
  printf '%s|%s|%s\n' "$src" "$dest" "$label"
}

install_ops_add_optional_copy() {
  local src="$1"
  local dest="$2"
  local label="${3:-}"
  if [[ -d "$src" ]]; then
    install_ops_emit_copy "$src" "$dest" "$label"
  fi
}

install_ops_build_copy_plan() {
  if [[ "$INSTALL_SHARED" -eq 1 ]]; then
    install_ops_emit_copy "$BUNDLE/.ralph" "$TARGET/.ralph" "shared"
  fi

  if [[ "$INSTALL_CURSOR" -eq 1 ]]; then
    install_ops_emit_copy "$BUNDLE/.cursor/ralph" "$TARGET/.cursor/ralph" "cursor-ralph"
    install_ops_add_optional_copy "$BUNDLE/.cursor/rules" "$TARGET/.cursor/rules" "cursor-rules"
    install_ops_add_optional_copy "$BUNDLE/.cursor/skills" "$TARGET/.cursor/skills" "cursor-skills"
    install_ops_add_optional_copy "$BUNDLE/.cursor/agents" "$TARGET/.cursor/agents" "cursor-agents"
  fi

  if [[ "$INSTALL_CODEX" -eq 1 ]]; then
    install_ops_emit_copy "$BUNDLE/.codex/ralph" "$TARGET/.codex/ralph" "codex-ralph"
    install_ops_add_optional_copy "$BUNDLE/.codex/rules" "$TARGET/.codex/rules" "codex-rules"
    install_ops_add_optional_copy "$BUNDLE/.codex/skills" "$TARGET/.codex/skills" "codex-skills"
    install_ops_add_optional_copy "$BUNDLE/.codex/agents" "$TARGET/.codex/agents" "codex-agents"
  fi

  if [[ "$INSTALL_CLAUDE" -eq 1 ]]; then
    install_ops_emit_copy "$BUNDLE/.claude/ralph" "$TARGET/.claude/ralph" "claude-ralph"
    install_ops_add_optional_copy "$BUNDLE/.claude/rules" "$TARGET/.claude/rules" "claude-rules"
    install_ops_add_optional_copy "$BUNDLE/.claude/skills" "$TARGET/.claude/skills" "claude-skills"
    install_ops_add_optional_copy "$BUNDLE/.claude/agents" "$TARGET/.claude/agents" "claude-agents"
  fi

}

install_ops_execute_plan() {
  local src dest label
  while IFS='|' read -r src dest label; do
    [[ -z "$src" ]] && continue
    install_ops_copy_tree "$src" "$dest"
  done < <(install_ops_build_copy_plan)
}

install_ops_copy_tree() {
  local src="$1"
  local dest="$2"

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
