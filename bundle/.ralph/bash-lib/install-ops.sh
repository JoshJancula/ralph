#!/usr/bin/env bash
set -euo pipefail
#
# Installer flag parsing and copy-plan execution for install.sh.

_install_ops_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F install_colors_init &>/dev/null; then
  # shellcheck source=/dev/null
  source "$_install_ops_lib_dir/install-colors.sh"
fi
install_colors_init

#
#
# Public interface:
#   install_ops_reset_state -- clear globals before a parse pass.
#   install_ops_parse_flags -- consume argv into install mode flags.
#   install_ops_default_selection, install_ops_resolve_target, install_ops_verify_bundle -- target resolution.
#   install_ops_has_any_stack, install_ops_should_install_dashboard -- derived install choices.
#   install_ops_emit_copy, install_ops_add_optional_copy, install_ops_build_copy_plan -- plan assembly.
#   install_ops_execute_plan, install_ops_copy_tree -- run the file copy plan.
#   install_ops_collect_remove_file_paths, install_ops_build_remove_prune_roots, install_ops_execute_remove,
#   install_ops_resolve_vendor_rel, install_ops_auto_remove_vendor_after_install, install_ops_remove_vendor -- uninstall / vendor.

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
    install_ops_copy_tree "$src" "$dest" "$label"
  done < <(install_ops_build_copy_plan)
}

install_ops_copy_tree() {
  local src="$1"
  local dest="$2"
  local label="${3:-}"

  if [[ ! -d "$src" ]]; then
    install_log_skip "Skip (missing source):" "$src"
    return 0
  fi

  mkdir -p "$dest"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    if [[ -n "$label" ]]; then
      install_log_dry "[dry-run]" "[$label] rsync -a $src/ $dest/"
    else
      install_log_dry "[dry-run]" "rsync -a $src/ $dest/"
    fi
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
    if [[ -n "$label" ]]; then
      install_log_ok "Installed" "$dest"
      install_log_ok_detail "component" "$label"
    else
      install_log_ok "Installed" "$dest"
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
