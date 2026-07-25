#!/usr/bin/env bash
set -euo pipefail
#
# Installer flag parsing and copy-plan execution for install.sh.

_install_ops_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F install_colors_init &>/dev/null; then
  # shellcheck source=/dev/null
  source "$_install_ops_lib_dir/install-colors.sh"
fi
if ! declare -F ralph_runtime_config_dirname &>/dev/null; then
  # shellcheck source=/dev/null
  source "$_install_ops_lib_dir/../runtime-normalize.sh"
fi
install_colors_init

#
#
# Public interface:
#   install_ops_reset_state -- clear globals before a parse pass.
#   install_ops_parse_flags -- consume argv into install mode flags.
#   install_ops_default_selection, install_ops_resolve_target, install_ops_verify_bundle -- target resolution.
#   install_ops_has_any_stack, install_ops_should_install_dashboard -- derived install choices.
#   install_ops_config_root, install_ops_state_root, install_ops_global_runtime_root -- global install paths.
#   install_ops_emit_copy, install_ops_add_optional_copy, install_ops_build_copy_plan -- plan assembly.
#   install_ops_execute_plan, install_ops_copy_tree -- run the file copy plan.
#   install_ops_collect_remove_file_paths, install_ops_build_remove_prune_roots, install_ops_execute_remove,
#   install_ops_resolve_vendor_rel, install_ops_auto_remove_vendor_after_install, install_ops_remove_vendor -- uninstall / vendor.

install_ops_reset_state() {
  DRY_RUN=0
  SILENT=0
  ASSUME_YES=0
  OVERWRITE_EXISTING=0
  INSTALL_SHARED=0
  INSTALL_CURSOR=0
  INSTALL_CODEX=0
  INSTALL_CLAUDE=0
  INSTALL_OPENCODE=0
  INSTALL_ANTIGRAVITY=0
  INSTALL_DASHBOARD=1
  GLOBAL_INSTALL=0
  FORCE_GLOBAL_RUNTIME=0
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
        INSTALL_OPENCODE=1
        INSTALL_ANTIGRAVITY=1
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
      --opencode)
        INSTALL_OPENCODE=1
        SELECTION_SPECIFIED=1
        shift
        ;;
      --antigravity)
        INSTALL_ANTIGRAVITY=1
        SELECTION_SPECIFIED=1
        shift
        ;;
      --no-dashboard)
        INSTALL_DASHBOARD=0
        shift
        ;;
      --global)
        GLOBAL_INSTALL=1
        shift
        ;;
      --force-global-runtime)
        FORCE_GLOBAL_RUNTIME=1
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
      -y|--yes)
        ASSUME_YES=1
        shift
        ;;
      -h|--help)
        usage 0
        ;;
      --remove-installed|--uninstall)
        REMOVE_INSTALLED=1
        shift
        ;;
      --remove-vendor)
        REMOVE_VENDOR=1
        shift
        ;;
      --cleanup)
        REMOVE_VENDOR=1
        shift
        ;;
      --purge)
        REMOVE_INSTALLED=1
        REMOVE_VENDOR=1
        INSTALL_SHARED=1
        INSTALL_CURSOR=1
        INSTALL_CODEX=1
        INSTALL_CLAUDE=1
        INSTALL_OPENCODE=1
        INSTALL_ANTIGRAVITY=1
        INSTALL_DASHBOARD=1
        SELECTION_SPECIFIED=1
        shift
        ;;
      -*)
        install_log_err "Unknown option:" "$1"
        return 1
        ;;
      *)
        INSTALL_TARGET_ARG="$1"
        break
        ;;
    esac
  done
  if [[ "$GLOBAL_INSTALL" -eq 1 && -n "$INSTALL_TARGET_ARG" ]]; then
    install_log_err "Error: --global cannot be combined with TARGET_DIR."
    return 1
  fi
  if [[ "$FORCE_GLOBAL_RUNTIME" -eq 1 && "$GLOBAL_INSTALL" -ne 1 ]]; then
    install_log_err "Error: --force-global-runtime requires --global."
    return 1
  fi
  return 0
}

install_ops_default_selection() {
  if [[ "$SELECTION_SPECIFIED" -eq 0 ]]; then
    INSTALL_SHARED=1
    INSTALL_CURSOR=1
    INSTALL_CODEX=1
    INSTALL_CLAUDE=1
    INSTALL_OPENCODE=1
    INSTALL_ANTIGRAVITY=1
  fi
}

install_ops_resolve_target() {
  if [[ "${GLOBAL_INSTALL:-0}" -eq 1 ]]; then
    local global_root="${RALPH_HOME:-$HOME/.ralph}"
    if [[ "$DRY_RUN" -eq 0 ]]; then
      mkdir -p "$global_root"
      (cd "$global_root" && pwd)
      return
    fi
    local parent base
    parent="$(dirname "$global_root")"
    base="$(basename "$global_root")"
    if [[ -d "$parent" ]]; then
      (cd "$parent" && printf '%s/%s\n' "$(pwd)" "$base")
    else
      printf '%s\n' "$global_root"
    fi
    return
  fi

  local raw="${1:-.}"
  [[ -z "$raw" ]] && raw="."
  if [[ ! -d "$raw" ]]; then
    install_log_err "Target must be an existing directory (your repo root):" "$raw"
    return 1
  fi
  (cd "$raw" && pwd)
}

install_ops_verify_bundle() {
  local bundle_path="$1"
  if [[ ! -d "$bundle_path" ]]; then
    install_log_err "Missing bundle (clone this repo completely):" "$bundle_path"
    return 1
  fi
}

# Detects an existing Ralph install at TARGET and resolves how to proceed.
# Sets OVERWRITE_EXISTING=1 when the user (or a flag) opts to replace it.
# Honors --yes (overwrite, no prompt) and --silent (keep existing, skip conflicts).
# Without a TTY and no flag, errors out so we never silently leave stale files behind.
install_ops_check_existing_install() {
  local existing_marker=""
  if [[ "${GLOBAL_INSTALL:-0}" -eq 1 ]]; then
    [[ -d "$TARGET/bundle/.ralph/bash-lib" ]] && existing_marker="$TARGET/bundle"
  else
    [[ -d "$TARGET/.ralph/bash-lib" ]] && existing_marker="$TARGET/.ralph"
  fi

  [[ -z "$existing_marker" ]] && return 0
  [[ "${DRY_RUN:-0}" -eq 1 ]] && return 0

  if [[ "$ASSUME_YES" -eq 1 ]]; then
    OVERWRITE_EXISTING=1
    install_log_warn "Existing Ralph install detected; overwriting (--yes):" "$existing_marker"
    return 0
  fi

  if [[ "$SILENT" -eq 1 ]]; then
    OVERWRITE_EXISTING=0
    install_log_warn "Existing Ralph install detected; keeping existing files (--silent):" "$existing_marker"
    return 0
  fi

  if [[ ! -t 0 ]]; then
    install_log_err "Ralph is already installed at $existing_marker"
    install_log_err "Re-run with --yes to overwrite, or --silent to keep existing files."
    return 1
  fi

  printf '\n%bRalph is already installed at%b %s\n' "${C_Y}${C_BOLD}" "${C_RST}" "$existing_marker"
  printf '%bOverwrite the previous installation?%b [y/N]: ' "${C_Y}${C_BOLD}" "${C_RST}"
  local reply
  read -r reply < /dev/tty
  case "$reply" in
    y|Y|yes|YES)
      OVERWRITE_EXISTING=1
      install_log_ok "Overwriting existing install:" "$existing_marker"
      ;;
    *)
      install_log_warn "Aborted: leaving existing install untouched."
      exit 0
      ;;
  esac
}

install_ops_has_any_stack() {
  [[ "$INSTALL_SHARED$INSTALL_CURSOR$INSTALL_CODEX$INSTALL_CLAUDE$INSTALL_OPENCODE$INSTALL_ANTIGRAVITY" != "000000" ]]
}

install_ops_should_install_dashboard() {
  [[ "$INSTALL_DASHBOARD" -eq 1 ]] && install_ops_has_any_stack
}

install_ops_config_root() {
  printf '%s\n' "${RALPH_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/ralph}"
}

install_ops_state_root() {
  printf '%s\n' "${RALPH_STATE_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/ralph}"
}

install_ops_global_runtime_root() {
  local runtime="$1"
  printf '%s/%s\n' "${RALPH_GLOBAL_RUNTIME_HOME:-$HOME}" "$(ralph_runtime_config_dirname "$runtime")"
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

install_ops_add_optional_file_copy() {
  local src="$1"
  local dest="$2"
  local label="${3:-}"
  if [[ -f "$src" ]]; then
    install_ops_emit_copy "$src" "$dest" "$label"
  fi
}

install_ops_add_global_runtime_copy() {
  local runtime="$1"
  local src_root="$BUNDLE/$(ralph_runtime_config_dirname "$runtime")"
  local dest
  dest="$(install_ops_global_runtime_root "$runtime")"
  [[ -d "$src_root" ]] || return 0
  if [[ "${FORCE_GLOBAL_RUNTIME:-0}" -eq 1 || ! -d "$dest" ]]; then
    # Copy agents/rules/skills (and runtime-specific dirs like hooks/plugins),
    # but exclude the ralph/ subtree (scripts now live under .ralph/)
    for subdir in agents rules skills hooks plugins; do
      local src="$src_root/$subdir"
      if [[ -d "$src" ]]; then
        install_ops_emit_copy "$src" "$dest/$subdir" "global-$runtime-$subdir"
      fi
    done
    if [[ "$runtime" == "antigravity" ]]; then
      install_ops_add_optional_file_copy "$src_root/agents.md" "$dest/agents.md" "global-$runtime-agents-md"
    fi
  fi
}

install_ops_build_copy_plan() {
  if [[ "${GLOBAL_INSTALL:-0}" -eq 1 ]]; then
    install_ops_emit_copy "$BUNDLE" "$TARGET/bundle" "global-bundle"
    if [[ -n "${RALPH_INSTALL_SOURCE_ROOT:-}" ]]; then
      install_ops_add_optional_copy "$RALPH_INSTALL_SOURCE_ROOT/docs" "$TARGET/docs" "global-ralph-docs"
    fi
    [[ "$INSTALL_CURSOR" -eq 1 ]] && install_ops_add_global_runtime_copy "cursor"
    [[ "$INSTALL_CODEX" -eq 1 ]] && install_ops_add_global_runtime_copy "codex"
    [[ "$INSTALL_CLAUDE" -eq 1 ]] && install_ops_add_global_runtime_copy "claude"
    [[ "$INSTALL_OPENCODE" -eq 1 ]] && install_ops_add_global_runtime_copy "opencode"
    [[ "$INSTALL_ANTIGRAVITY" -eq 1 ]] && install_ops_add_global_runtime_copy "antigravity"
    return 0
  fi

  if [[ "$INSTALL_SHARED" -eq 1 ]]; then
    install_ops_emit_copy "$BUNDLE/.ralph" "$TARGET/.ralph" "shared"
    if [[ -n "${RALPH_INSTALL_SOURCE_ROOT:-}" && -d "$RALPH_INSTALL_SOURCE_ROOT/docs" ]]; then
      install_ops_emit_copy "$RALPH_INSTALL_SOURCE_ROOT/docs" "$TARGET/.ralph/docs" "ralph-docs"
    fi
  fi

  if [[ "$INSTALL_CURSOR" -eq 1 ]]; then
    install_ops_add_optional_copy "$BUNDLE/.cursor/rules" "$TARGET/.cursor/rules" "cursor-rules"
    install_ops_add_optional_copy "$BUNDLE/.cursor/skills" "$TARGET/.cursor/skills" "cursor-skills"
    install_ops_add_optional_copy "$BUNDLE/.cursor/agents" "$TARGET/.cursor/agents" "cursor-agents"
  fi

  if [[ "$INSTALL_CODEX" -eq 1 ]]; then
    install_ops_add_optional_copy "$BUNDLE/.codex/rules" "$TARGET/.codex/rules" "codex-rules"
    install_ops_add_optional_copy "$BUNDLE/.codex/skills" "$TARGET/.codex/skills" "codex-skills"
    install_ops_add_optional_copy "$BUNDLE/.codex/agents" "$TARGET/.codex/agents" "codex-agents"
    install_ops_add_optional_copy "$BUNDLE/.codex/hooks" "$TARGET/.codex/hooks" "codex-hooks"
  fi

  if [[ "$INSTALL_CLAUDE" -eq 1 ]]; then
    install_ops_add_optional_copy "$BUNDLE/.claude/rules" "$TARGET/.claude/rules" "claude-rules"
    install_ops_add_optional_copy "$BUNDLE/.claude/skills" "$TARGET/.claude/skills" "claude-skills"
    install_ops_add_optional_copy "$BUNDLE/.claude/agents" "$TARGET/.claude/agents" "claude-agents"
    install_ops_add_optional_copy "$BUNDLE/.claude/hooks" "$TARGET/.claude/hooks" "claude-hooks"
  fi

  if [[ "$INSTALL_OPENCODE" -eq 1 ]]; then
    install_ops_add_optional_copy "$BUNDLE/.opencode/rules" "$TARGET/.opencode/rules" "opencode-rules"
    install_ops_add_optional_copy "$BUNDLE/.opencode/skills" "$TARGET/.opencode/skills" "opencode-skills"
    install_ops_add_optional_copy "$BUNDLE/.opencode/agents" "$TARGET/.opencode/agents" "opencode-agents"
    install_ops_add_optional_copy "$BUNDLE/.opencode/plugins" "$TARGET/.opencode/plugins" "opencode-plugins"
  fi

  if [[ "$INSTALL_ANTIGRAVITY" -eq 1 ]]; then
    install_ops_add_optional_file_copy "$BUNDLE/.agents/agents.md" "$TARGET/.agents/agents.md" "antigravity-agents-md"
    install_ops_add_optional_copy "$BUNDLE/.agents/rules" "$TARGET/.agents/rules" "antigravity-rules"
    install_ops_add_optional_copy "$BUNDLE/.agents/skills" "$TARGET/.agents/skills" "antigravity-skills"
    install_ops_add_optional_copy "$BUNDLE/.agents/agents" "$TARGET/.agents/agents" "antigravity-agents"
    install_ops_add_optional_copy "$BUNDLE/.agents/hooks" "$TARGET/.agents/hooks" "antigravity-hooks"
  fi

}

install_ops_execute_plan() {
  local src dest label
  while IFS='|' read -r src dest label; do
    [[ -z "$src" ]] && continue
    install_ops_copy_tree "$src" "$dest" "$label"
  done < <(install_ops_build_copy_plan)
}

install_ops_copy_tree() {
  local src="$1"
  local dest="$2"
  local label="${3:-}"

  if [[ -f "$src" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      if [[ -n "$label" ]]; then
        install_log_dry "[dry-run]" "[$label] cp $src $dest"
      else
        install_log_dry "[dry-run]" "cp $src $dest"
      fi
      return 0
    fi

    mkdir -p "$(dirname "$dest")"
    if [[ -e "$dest" && "${OVERWRITE_EXISTING:-0}" -ne 1 ]]; then
      if [[ "$SILENT" -eq 1 || ! -t 0 ]]; then
        install_log_warn "Conflict skipped:" "$dest"
        return 0
      fi
      install_log_phase "File conflict"
      install_log_warn "Destination:" "$dest"
      printf '%bOverwrite this file?%b [y/N]: ' "${C_Y}${C_BOLD}" "${C_RST}"
      local reply
      read -r reply < /dev/tty
      case "$reply" in
        y|Y|yes|YES) ;;
        *)
          install_log_warn "Skipped:" "$dest"
          return 0
          ;;
      esac
    fi
    cp "$src" "$dest"
    if [[ -n "$label" ]]; then
      install_log_ok "Installed" "$dest"
      install_log_ok_detail "component" "$label"
    else
      install_log_ok "Installed" "$dest"
    fi
    return 0
  fi

  if [[ ! -d "$src" ]]; then
    install_log_skip "Skip (missing source):" "$src"
    return 0
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    if [[ -n "$label" ]]; then
      install_log_dry "[dry-run]" "[$label] rsync -a $src/ $dest/"
    else
      install_log_dry "[dry-run]" "rsync -a $src/ $dest/"
    fi
    return 0
  fi

  mkdir -p "$dest"

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
    if [[ -n "$label" ]]; then
      install_log_ok "Installed" "$dest"
      install_log_ok_detail "component" "$label"
    else
      install_log_ok "Installed" "$dest"
    fi
    return 0
  fi

  if [[ "${OVERWRITE_EXISTING:-0}" -eq 1 ]]; then
    rsync -a "$src/" "$dest/"
    if [[ -n "$label" ]]; then
      install_log_ok "Installed (overwrote existing)" "$dest"
      install_log_ok_detail "component" "$label"
    else
      install_log_ok "Installed (overwrote existing)" "$dest"
    fi
    return 0
  fi

  if [[ "$SILENT" -eq 1 ]]; then
    rsync -a --ignore-existing "$src/" "$dest/"
    install_log_warn "Conflicts skipped under $dest (run without --silent to resolve interactively)"
    local _c
    for _c in "${conflicts[@]}"; do
      printf '%b\n' "  ${C_DIM}${_c}${C_RST}"
    done
    return 0
  fi

  # Interactive path: check if we have a TTY
  if [[ ! -t 0 ]]; then
    install_log_warn "stdin is not a TTY; merging with --ignore-existing for:" "$dest"
    rsync -a --ignore-existing "$src/" "$dest/"
    install_log_warn "Conflicts left unchanged (open a TTY to resolve interactively):" "$dest"
    local _c
    for _c in "${conflicts[@]}"; do
      printf '%b\n' "  ${C_DIM}${_c}${C_RST}"
    done
    return 0
  fi

  install_log_phase "File conflicts"
  install_log_warn "Destination:" "$dest"
  local _c
  for _c in "${conflicts[@]}"; do
    printf '%b\n' "  ${C_DIM}${_c}${C_RST}"
  done
  printf '\n'

  local choice
  # This stays bespoke (not using ralph_menu_select) because it's a single-character
  # action menu (o/s/r) with conditional review sub-loop, not a list selection.
  while true; do
    printf '%b' "${C_Y}${C_BOLD}Conflicts: [o]verwrite all / [s]kip all / [r]eview each:${C_RST} "
    if ! read -r -t 0 choice < /dev/tty; then
      printf '\n'
      read -r choice < /dev/tty
    else
      read -r choice < /dev/tty
    fi

    case "$choice" in
      o|O)
        rsync -a "$src/" "$dest/"
        install_log_ok "Installed (overwrote conflicts)" "$dest"
        return 0
        ;;
      s|S)
        rsync -a --ignore-existing "$src/" "$dest/"
        install_log_ok "Installed (skipped conflicts)" "$dest"
        return 0
        ;;
      r|R)
        # Review mode: show each conflict and ask per-file
        local -a skipped=()
        local conflict
        for conflict in "${conflicts[@]}"; do
          printf '\n%b%s%b%s%b%s%b\n' "${C_C}" "--- Conflict: " "${C_BOLD}" "$conflict" "${C_RST}${C_C}" " ---" "${C_RST}"
          if command -v diff &> /dev/null; then
            diff --color=auto "$dest/$conflict" "$src/$conflict" 2>/dev/null || true
          fi
          printf '%b%s%b%s%b%s%b' "${C_Y}" "Overwrite " "${C_B}" "$conflict" "${C_Y}" "? [o]verwrite / [s]kip:" "${C_RST}"
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
        install_log_ok "Installed (reviewed conflicts)" "$dest"
        return 0
        ;;
      *)
        printf '%b\n' "${C_Y}Invalid choice. Enter o, s, or r.${C_RST}" >&2
        ;;
    esac
  done

}

# Lists destination directory roots where empty dirs are pruned after file removal (one path per line).
# Caller sets BUNDLE, TARGET, stack flags, and (for docs/dashboard manifest) RALPH_INSTALL_SOURCE_ROOT / RALPH_INSTALL_SCRIPT_DIR.
install_ops_build_remove_prune_roots() {
  local src dest label
  while IFS='|' read -r src dest label; do
    [[ -z "$src" ]] && continue
    [[ -d "$src" ]] || continue
    printf '%s\n' "$dest"
  done < <(install_ops_build_copy_plan) | sort -u

  if [[ "$INSTALL_SHARED" -eq 0 ]] && install_ops_should_install_dashboard; then
    printf '%s\n' "$TARGET/.ralph/ralph-dashboard"
  fi
}

# Prints one absolute file path per line: only paths that exist in this package's bundle (and dashboard tree).
# Does not delete sibling files the user added under the same directories.
install_ops_collect_remove_file_paths() {
  local src dest label file relpath dash_src
  while IFS='|' read -r src dest label; do
    [[ -z "$src" ]] && continue
    [[ -d "$src" ]] || continue
    while IFS= read -r -d '' file; do
      relpath="${file#"$src"/}"
      printf '%s/%s\n' "$dest" "$relpath"
    done < <(find "$src" -type f -print0 2>/dev/null)
  done < <(install_ops_build_copy_plan)

  dash_src=""
  if [[ -n "${RALPH_INSTALL_SCRIPT_DIR:-}" ]]; then
    dash_src="${RALPH_INSTALL_SCRIPT_DIR%/}/ralph-dashboard"
  elif [[ -n "${RALPH_INSTALL_SOURCE_ROOT:-}" ]]; then
    dash_src="${RALPH_INSTALL_SOURCE_ROOT%/}/ralph-dashboard"
  fi
  if install_ops_should_install_dashboard && [[ -n "$dash_src" && -d "$dash_src" ]]; then
    while IFS= read -r -d '' file; do
      relpath="${file#"$dash_src"/}"
      printf '%s/.ralph/ralph-dashboard/%s\n' "$TARGET" "$relpath"
    done < <(find "$dash_src" -type f -print0 2>/dev/null)
  fi
}

install_ops_prune_empty_dirs_under() {
  local root
  for root in "$@"; do
    [[ -d "$root" ]] || continue
    find "$root" -depth -type d -empty 2>/dev/null | while IFS= read -r d; do
      rmdir "$d" 2>/dev/null || true
    done
  done
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
  install_log_err "Removal requires an interactive terminal or --silent for non-interactive runs."
  return 1
}

install_ops_execute_remove() {
  install_ops_removal_needs_tty_or_silent || return 1

  local -a files=()
  local -a prune_roots=()
  local p f

  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    [[ -f "$f" ]] && files+=("$f")
  done < <(install_ops_collect_remove_file_paths | sort -u)

  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    prune_roots+=("$p")
  done < <(install_ops_build_remove_prune_roots | sort -u)

  if [[ "${#files[@]}" -eq 0 ]]; then
    install_log_warn "Nothing to remove under $TARGET (no Ralph-installed files for this selection)."
    return 0
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    install_log_dry "[dry-run]" "would remove ${#files[@]} Ralph-installed file(s); prune empty dirs under:"
    local _p
    for _p in "${prune_roots[@]}"; do
      printf '%b\n' "  ${C_DIM}${_p}${C_RST}"
    done
    install_log_dry "[dry-run]" "sample files (first 20):"
    local i=0
    for f in "${files[@]}"; do
      printf '%b\n' "  ${C_DIM}${f}${C_RST}"
      i=$((i + 1))
      [[ "$i" -ge 20 ]] && break
    done
    [[ "${#files[@]}" -gt 20 ]] && printf '%b\n' "  ${C_DIM}... and $((${#files[@]} - 20)) more${C_RST}"
    return 0
  fi

  if [[ "$SILENT" -eq 0 ]]; then
    install_log_phase "Confirm uninstall"
    printf '%b%d%b\n' "${C_Y}Will remove ${C_BOLD}" "${#files[@]}" "${C_Y} Ralph-installed file(s) only; your other files stay.${C_RST}"
    printf '%b\n' "${C_DIM}Then prune empty directories under:${C_RST}"
    local _p
    for _p in "${prune_roots[@]}"; do
      printf '%b\n' "  ${C_DIM}${_p}${C_RST}"
    done
    printf '%b' "${C_Y}${C_BOLD}Proceed? [y/N]${C_RST} "
    local answer
    if ! read -r -t 0 answer < /dev/tty 2>/dev/null; then
      read -r answer < /dev/tty
    else
      read -r answer < /dev/tty
    fi
    case "$answer" in
      y|Y) ;;
      *)
        install_log_warn "Cancelled."
        return 1
        ;;
    esac
  fi

  for f in "${files[@]}"; do
    rm -f "$f"
  done
  install_log_ok "Removed file(s)" "${#files[@]}"

  install_ops_prune_empty_dirs_under "${prune_roots[@]}"
  install_log_ok "Pruned empty directories" "${#prune_roots[@]} path(s)"

  # After uninstall, check for and report stale runtime ralph directories
  install_ops_stale_runtime_ralph_notice "$TARGET"
}

# Prints the path of the vendored package directory relative to target (e.g. vendor/ralph) when
# script_dir is a strict subdirectory of target_root and the path is safe. Returns 0 on stdout.
# Return 1 when there is no vendored layout to remove (no stderr). Return 2 when unsafe (stderr).
install_ops_resolve_vendor_rel() {
  local target_root="$1"
  local script_dir="$2"
  local tn sn rel

  tn="$(cd "$target_root" && pwd -P)" || return 1
  sn="$(cd "$script_dir" && pwd -P)" || return 1

  if [[ "$sn" == "$tn" ]]; then
    install_log_err "Refusing vendor removal: install script directory equals target (unsafe)."
    return 2
  fi

  case "$sn" in
    "$tn"/*) ;;
    *) return 1 ;;
  esac

  rel="${sn#"$tn"/}"
  if [[ -z "$rel" || "$rel" == *..* ]]; then
    install_log_err "Refusing vendor removal: unsafe relative path" "$rel"
    return 2
  fi

  if [[ ! -d "$tn/$rel" ]]; then
    return 1
  fi

  printf '%s\n' "$rel"
  return 0
}

# After rm -rf of rel (e.g. vendor/ralph), remove empty parent segments under tn (e.g. empty vendor/).
install_ops_prune_empty_vendor_ancestors() {
  local tn="$1"
  local rel="$2"
  local _p
  _p="$(dirname "$rel")"
  while [[ "$_p" != "." && "$_p" != "/" ]]; do
    [[ -d "$tn/$_p" ]] || break
    rmdir "$tn/$_p" 2>/dev/null || break
    _p="$(dirname "$_p")"
  done
}

# After a normal install from vendor/ralph, remove that vendored copy so only project-root files remain.
# Skips when the vendored tree is its own Git checkout (submodule gitlink or .git directory) so
# submodule/clone workflows keep vendor/ralph for updates. Honors DRY_RUN. Set RALPH_INSTALL_KEEP_VENDOR=1
# to always skip, or RALPH_INSTALL_REMOVE_VENDOR=1 to force removal even with .git present.
install_ops_auto_remove_vendor_after_install() {
  local target_root="$1"
  local script_dir="$2"
  local rel tn vendor_path
  local rc=0

  [[ "${RALPH_INSTALL_KEEP_VENDOR:-0}" == "1" ]] && return 0

  if [[ -e "$script_dir/.git" && "${RALPH_INSTALL_REMOVE_VENDOR:-0}" != "1" ]]; then
    return 0
  fi

  rel="$(install_ops_resolve_vendor_rel "$target_root" "$script_dir")" || return 0
  tn="$(cd "$target_root" && pwd -P)"
  vendor_path="$tn/$rel"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    install_log_dry "[dry-run]" "would remove vendored Ralph copy after install: $vendor_path"
    return 0
  fi

  ( cd "$tn" && rm -rf "$rel" )
  install_ops_prune_empty_vendor_ancestors "$tn" "$rel"
  install_log_ok "Removed vendored copy (Ralph lives at project root)" "$vendor_path"
}

# Removes the vendored Ralph package directory (e.g. vendor/ralph) when it lives under target.
install_ops_remove_vendor() {
  local target_root="$1"
  local script_dir="$2"

  install_ops_removal_needs_tty_or_silent || return 1

  local tn rel vendor_path rc
  tn="$(cd "$target_root" && pwd -P)" || return 1

  rel="$(install_ops_resolve_vendor_rel "$target_root" "$script_dir")"
  rc=$?
  if [[ "$rc" -eq 1 ]]; then
    install_log_skip "Skip --remove-vendor (not under target; use git submodule or manual rm):" "$(cd "$script_dir" && pwd -P)"
    return 0
  fi
  if [[ "$rc" -ne 0 ]]; then
    return "$rc"
  fi

  vendor_path="$tn/$rel"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    install_log_dry "[dry-run]" "rm -rf $vendor_path"
    return 0
  fi

  if [[ "$SILENT" -eq 0 ]]; then
    printf '%b' "${C_Y}${C_BOLD}Remove entire vendored Ralph tree?${C_RST} ${C_DIM}${vendor_path}${C_RST} ${C_Y}[y/N]${C_RST} "
    local answer
    if ! read -r -t 0 answer < /dev/tty 2>/dev/null; then
      read -r answer < /dev/tty
    else
      read -r answer < /dev/tty
    fi
    case "$answer" in
      y|Y) ;;
      *)
        install_log_warn "Cancelled."
        return 1
        ;;
    esac
  fi

  ( cd "$tn" && rm -rf "$rel" )
  install_ops_prune_empty_vendor_ancestors "$tn" "$rel"
  install_log_ok "Removed vendored package" "$vendor_path"
}

# Detects and reports stale .<runtime>/ralph/ directories that may exist from pre-PLAN26 installs.
# These directories contained Ralph framework scripts that have been moved to .ralph/.
# Returns 0 if any stale directories were found, 1 otherwise.
# Prints detected paths to stdout (one per line) when found.
install_ops_detect_stale_runtime_ralph_dirs() {
  local target_root="${1:-$TARGET}"
  local found_any=0
  local runtime

  for runtime in cursor claude codex opencode; do
    local ralph_dir="$target_root/.$runtime/ralph"
    if [[ -d "$ralph_dir" ]]; then
      # Verify this is actually a stale Ralph scripts directory (contains .sh files)
      # and not user data (agents/, rules/, skills/ are preserved)
      if find "$ralph_dir" -maxdepth 1 -name "*.sh" -type f 2>/dev/null | grep -q .; then
        printf '%s\n' "$ralph_dir"
        found_any=1
      fi
    fi
  done

  return $((found_any == 0))
}

# Prints a notice about stale runtime ralph directories and how to remove them.
# Call this after install to warn users upgrading from pre-PLAN26 installs.
install_ops_stale_runtime_ralph_notice() {
  local target_root="${1:-$TARGET}"
  local -a stale_dirs=()
  local dir

  while IFS= read -r dir; do
    [[ -n "$dir" ]] && stale_dirs+=("$dir")
  done < <(install_ops_detect_stale_runtime_ralph_dirs "$target_root" 2>/dev/null)

  if [[ "${#stale_dirs[@]}" -eq 0 ]]; then
    return 0
  fi

  install_log_warn "Deprecated directories detected (pre-PLAN26 install)"
  printf '%b\n' "${C_DIM}The following directories contain old Ralph scripts that have moved to .ralph/:${C_RST}"
  for dir in "${stale_dirs[@]}"; do
    printf '  %b%s%b\n' "${C_Y}" "$dir" "${C_RST}"
  done
  printf '%b\n' "${C_DIM}These directories are no longer updated by the installer.${C_RST}"
  printf '%b\n' "${C_DIM}To remove them (your agents/rules/skills under .<runtime>/ are safe):${C_RST}"
  for dir in "${stale_dirs[@]}"; do
    printf '  rm -rf %q\n' "$dir"
  done
}
