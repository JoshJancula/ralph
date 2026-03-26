#!/usr/bin/env bash
set -euo pipefail
#
# Installer flag parsing and copy-plan execution for install.sh.
#
# Public interface:
#   install_ops_reset_state -- clear globals before a parse pass.
#   install_ops_parse_flags -- consume argv into install mode flags.
#   install_ops_default_selection, install_ops_resolve_target, install_ops_verify_bundle -- target resolution.
#   install_ops_has_any_stack, install_ops_should_install_dashboard -- derived install choices.
#   install_ops_emit_copy, install_ops_add_optional_copy, install_ops_build_copy_plan -- plan assembly.
#   install_ops_execute_plan, install_ops_copy_tree -- run the file copy plan.
#   install_ops_build_remove_dests, install_ops_execute_remove, install_ops_remove_vendor -- uninstall / vendor cleanup.

install_ops_reset_state() {
  DRY_RUN=0
  SILENT=0
  INSTALL_SHARED=0
  INSTALL_CURSOR=0
  INSTALL_CODEX=0
  INSTALL_CLAUDE=0
  INSTALL_DASHBOARD=1
  SELECTION_SPECIFIED=0
  INSTALL_TARGET_ARG=""
  REMOVE_INSTALLED=0
  REMOVE_VENDOR=0
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
      -s|--silent)
        SILENT=1
        shift
        ;;
      -h|--help)
        usage 0
        ;;
      --remove-installed)
        REMOVE_INSTALLED=1
        shift
        ;;
      --remove-vendor)
        REMOVE_VENDOR=1
        shift
        ;;
      --cleanup)
        REMOVE_INSTALLED=1
        REMOVE_VENDOR=1
        INSTALL_SHARED=1
        INSTALL_CURSOR=1
        INSTALL_CODEX=1
        INSTALL_CLAUDE=1
        INSTALL_DASHBOARD=1
        SELECTION_SPECIFIED=1
        shift
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
    if [[ -n "${RALPH_INSTALL_SOURCE_ROOT:-}" && -d "$RALPH_INSTALL_SOURCE_ROOT/docs" ]]; then
      install_ops_emit_copy "$RALPH_INSTALL_SOURCE_ROOT/docs" "$TARGET/.ralph/docs" "ralph-docs"
    fi
  fi

  if [[ "$INSTALL_CURSOR" -eq 1 ]]; then
    install_ops_emit_copy "$BUNDLE/.cursor/ralph" "$TARGET/.cursor/ralph" "cursor-ralph"
    install_ops_add_optional_copy "$BUNDLE/.cursor/rules" "$TARGET/.cursor/rules" "cursor-rules"
    install_ops_add_optional_copy "$BUNDLE/.cursor/skills" "$TARGET/.cursor/skills" "cursor-skills"
    install_ops_add_optional_copy "$BUNDLE/.cursor/agents" "$TARGET/.cursor/agents" "cursor-agents"
    install_ops_add_optional_copy "$BUNDLE/.ralph/plan-templates" "$TARGET/.cursor/ralph/templates" "cursor-templates"
  fi

  if [[ "$INSTALL_CODEX" -eq 1 ]]; then
    install_ops_emit_copy "$BUNDLE/.codex/ralph" "$TARGET/.codex/ralph" "codex-ralph"
    install_ops_add_optional_copy "$BUNDLE/.codex/rules" "$TARGET/.codex/rules" "codex-rules"
    install_ops_add_optional_copy "$BUNDLE/.codex/skills" "$TARGET/.codex/skills" "codex-skills"
    install_ops_add_optional_copy "$BUNDLE/.codex/agents" "$TARGET/.codex/agents" "codex-agents"
    install_ops_add_optional_copy "$BUNDLE/.ralph/plan-templates" "$TARGET/.codex/ralph/templates" "codex-templates"
  fi

  if [[ "$INSTALL_CLAUDE" -eq 1 ]]; then
    install_ops_emit_copy "$BUNDLE/.claude/ralph" "$TARGET/.claude/ralph" "claude-ralph"
    install_ops_add_optional_copy "$BUNDLE/.claude/rules" "$TARGET/.claude/rules" "claude-rules"
    install_ops_add_optional_copy "$BUNDLE/.claude/skills" "$TARGET/.claude/skills" "claude-skills"
    install_ops_add_optional_copy "$BUNDLE/.claude/agents" "$TARGET/.claude/agents" "claude-agents"
    install_ops_add_optional_copy "$BUNDLE/.ralph/plan-templates" "$TARGET/.claude/ralph/templates" "claude-templates"
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

  local -a conflicts=()
  local file relpath

  while IFS= read -r file; do
    relpath="${file#"$src/"}"
    if [[ -e "$dest/$relpath" ]]; then
      conflicts+=("$relpath")
    fi
  done < <(find "$src" -type f)

  if [[ "${#conflicts[@]}" -eq 0 ]]; then
    rsync -a "$src/" "$dest/"
    echo "Installed: $dest"
    return 0
  fi

  if [[ "$SILENT" -eq 1 ]]; then
    rsync -a --ignore-existing "$src/" "$dest/"
    printf 'Conflicts detected in %s (skipped - manual review required):\n' "$dest"
    printf '  %s\n' "${conflicts[@]}"
    printf 'Run without --silent to resolve interactively.\n'
    return 0
  fi

  # Interactive path: check if we have a TTY
  if [[ ! -t 0 ]]; then
    printf 'WARNING: stdin is not a TTY. Cannot prompt interactively. Falling back to silent mode.\n' >&2
    rsync -a --ignore-existing "$src/" "$dest/"
    printf 'Conflicts detected in %s (skipped - manual review required):\n' "$dest"
    printf '  %s\n' "${conflicts[@]}"
    printf 'Run with an interactive terminal to resolve interactively.\n'
    return 0
  fi

  printf 'Conflicts found in %s:\n' "$dest"
  printf '  %s\n' "${conflicts[@]}"
  printf '\n'

  local choice
  while true; do
    printf 'Conflicts found. [o]verwrite all / [s]kip all / [r]eview each: '
    if ! read -r -t 0 choice < /dev/tty; then
      printf '\n'
      read -r choice < /dev/tty
    else
      read -r choice < /dev/tty
    fi

    case "$choice" in
      o|O)
        rsync -a "$src/" "$dest/"
        echo "Installed (overwrote conflicts): $dest"
        return 0
        ;;
      s|S)
        rsync -a --ignore-existing "$src/" "$dest/"
        echo "Installed (skipped conflicts): $dest"
        return 0
        ;;
      r|R)
        # Review mode: show each conflict and ask per-file
        local -a skipped=()
        local conflict
        for conflict in "${conflicts[@]}"; do
          printf '\n--- Conflict: %s ---\n' "$conflict"
          if command -v diff &> /dev/null; then
            diff --color=auto "$dest/$conflict" "$src/$conflict" 2>/dev/null || true
          fi
          printf 'Overwrite %s? [o]verwrite / [s]kip: ' "$conflict"
          local file_choice
          read -r file_choice < /dev/tty
          case "$file_choice" in
            o|O)
              # Will be included in the final rsync
              ;;
            *)
              skipped+=("$conflict")
              ;;
          esac
        done

        # Build and run rsync with exclusions
        if [[ "${#skipped[@]}" -eq 0 ]]; then
          rsync -a "$src/" "$dest/"
        else
          # Use rsync with --exclude for each skipped file
          local -a rsync_args=("-a" "$src/" "$dest/")
          for conflict in "${skipped[@]}"; do
            rsync_args+=("--exclude" "$conflict")
          done
          rsync "${rsync_args[@]}"
          # Copy non-excluded conflicts, ignoring those we're skipping
          rsync -a --ignore-existing "$src/" "$dest/"
        fi
        echo "Installed (reviewed conflicts): $dest"
        return 0
        ;;
      *)
        printf 'Invalid choice. Please enter o, s, or r.\n'
        ;;
    esac
  done

}

install_ops_emit_remove_dest() {
  local dest="$1"
  [[ -n "$dest" ]] || return 0
  printf '%s\n' "$dest"
}

# Prints one absolute path per line (dest dirs Ralph may have created). Caller sets TARGET.
install_ops_build_remove_dests() {
  if [[ "$INSTALL_SHARED" -eq 1 ]]; then
    install_ops_emit_remove_dest "$TARGET/.ralph"
  fi

  if [[ "$INSTALL_CURSOR" -eq 1 ]]; then
    install_ops_emit_remove_dest "$TARGET/.cursor/ralph"
    install_ops_emit_remove_dest "$TARGET/.cursor/rules"
    install_ops_emit_remove_dest "$TARGET/.cursor/skills"
    install_ops_emit_remove_dest "$TARGET/.cursor/agents"
    install_ops_emit_remove_dest "$TARGET/.cursor/ralph/templates"
  fi

  if [[ "$INSTALL_CODEX" -eq 1 ]]; then
    install_ops_emit_remove_dest "$TARGET/.codex/ralph"
    install_ops_emit_remove_dest "$TARGET/.codex/rules"
    install_ops_emit_remove_dest "$TARGET/.codex/skills"
    install_ops_emit_remove_dest "$TARGET/.codex/agents"
    install_ops_emit_remove_dest "$TARGET/.codex/ralph/templates"
  fi

  if [[ "$INSTALL_CLAUDE" -eq 1 ]]; then
    install_ops_emit_remove_dest "$TARGET/.claude/ralph"
    install_ops_emit_remove_dest "$TARGET/.claude/rules"
    install_ops_emit_remove_dest "$TARGET/.claude/skills"
    install_ops_emit_remove_dest "$TARGET/.claude/agents"
    install_ops_emit_remove_dest "$TARGET/.claude/ralph/templates"
  fi

  if [[ "$INSTALL_DASHBOARD" -eq 1 ]] && install_ops_has_any_stack; then
    if [[ "$INSTALL_SHARED" -eq 0 ]]; then
      install_ops_emit_remove_dest "$TARGET/.ralph/ralph-dashboard"
    fi
  fi
}

install_ops_removal_needs_tty_or_silent() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  if [[ "$SILENT" -eq 1 ]]; then
    return 0
  fi
  if [[ -t 0 ]]; then
    return 0
  fi
  printf 'Removal requires an interactive terminal or %s for non-interactive runs.\n' "--silent" >&2
  return 1
}

install_ops_execute_remove() {
  install_ops_removal_needs_tty_or_silent || return 1

  local -a paths=()
  local p
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    [[ -e "$p" ]] && paths+=("$p")
  done < <(install_ops_build_remove_dests | sort -u)

  if [[ "${#paths[@]}" -eq 0 ]]; then
    printf 'Nothing to remove under %s (paths already absent).\n' "$TARGET"
    return 0
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run] would remove:\n'
    printf '  %s\n' "${paths[@]}"
    return 0
  fi

  if [[ "$SILENT" -eq 0 ]]; then
    printf 'Will remove these paths:\n'
    printf '  %s\n' "${paths[@]}"
    printf 'Proceed? [y/N] '
    local answer
    if ! read -r -t 0 answer < /dev/tty 2>/dev/null; then
      read -r answer < /dev/tty
    else
      read -r answer < /dev/tty
    fi
    case "$answer" in
      y|Y) ;;
      *)
        printf 'Cancelled.\n'
        return 1
        ;;
    esac
  fi

  for p in "${paths[@]}"; do
    rm -rf "$p"
    printf 'Removed: %s\n' "$p"
  done
}

# Removes the vendored Ralph package directory (e.g. vendor/ralph) when it lives under target.
install_ops_remove_vendor() {
  local target_root="$1"
  local script_dir="$2"

  install_ops_removal_needs_tty_or_silent || return 1

  local tn sn
  tn="$(cd "$target_root" && pwd -P)"
  sn="$(cd "$script_dir" && pwd -P)"

  if [[ "$sn" == "$tn" ]]; then
    printf 'Refusing %s: install script directory equals target (unsafe).\n' "--remove-vendor" >&2
    return 1
  fi

  case "$sn" in
    "$tn"/*) ;;
    *)
      printf 'Skip %s: %s is not under %s (nothing to delete as a vendor subtree; use git submodule or manual rm).\n' \
        "--remove-vendor" "$sn" "$tn" >&2
      return 0
      ;;
  esac

  local rel="${sn#"$tn"/}"
  if [[ -z "$rel" || "$rel" == *..* ]]; then
    printf 'Refusing %s: unsafe relative path %s\n' "--remove-vendor" "$rel" >&2
    return 1
  fi

  local vendor_path="$tn/$rel"
  if [[ ! -d "$vendor_path" ]]; then
    printf 'Skip %s: not a directory: %s\n' "--remove-vendor" "$vendor_path" >&2
    return 0
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run] rm -rf %s\n' "$vendor_path"
    return 0
  fi

  if [[ "$SILENT" -eq 0 ]]; then
    printf 'Remove entire vendored Ralph tree %s ? [y/N] ' "$vendor_path"
    local answer
    if ! read -r -t 0 answer < /dev/tty 2>/dev/null; then
      read -r answer < /dev/tty
    else
      read -r answer < /dev/tty
    fi
    case "$answer" in
      y|Y) ;;
      *)
        printf 'Cancelled.\n'
        return 1
        ;;
    esac
  fi

  ( cd "$tn" && rm -rf "$rel" )
  printf 'Removed vendored package: %s\n' "$vendor_path"
}
