#!/usr/bin/env bash
#
# Shared helpers plus runtime removal adapters for ralph setup --remove.
#
# Public interface:
#   setup_remove_hooks <runtime> <runtime_dir>
#   setup_remove_mcp <runtime> <runtime_dir> <project_root>
#
# Adapters remove only recognized Ralph JSON ids/names or byte-identical owned
# files. Modified owned files are refused. Configs with no Ralph entry are left
# byte-for-byte. Dry-run discovers and prints without creating a journal.

set -euo pipefail

if [[ -n "${RALPH_SETUP_REMOVE_LOADED:-}" ]]; then
  return 0
fi
RALPH_SETUP_REMOVE_LOADED=1

SETUP_REMOVE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RALPH_SETUP_REMOVE_ROOT="$(cd "$SETUP_REMOVE_LIB_DIR/../.." && pwd)"

# shellcheck source=setup-remove-claude.sh
source "$SETUP_REMOVE_LIB_DIR/setup-remove-claude.sh"
# shellcheck source=setup-remove-cursor.sh
source "$SETUP_REMOVE_LIB_DIR/setup-remove-cursor.sh"
# shellcheck source=setup-remove-codex.sh
source "$SETUP_REMOVE_LIB_DIR/setup-remove-codex.sh"
# shellcheck source=setup-remove-opencode.sh
source "$SETUP_REMOVE_LIB_DIR/setup-remove-opencode.sh"
# shellcheck source=setup-remove-antigravity.sh
source "$SETUP_REMOVE_LIB_DIR/setup-remove-antigravity.sh"

setup_remove_python_script() {
  printf '%s/python/setup-remove-json.py' "$RALPH_SETUP_REMOVE_ROOT"
}

setup_remove_require_python3() {
  if ! command -v python3 >/dev/null 2>&1; then
    printf 'Error: python3 is required for Ralph JSON removal\n' >&2
    return 1
  fi
  return 0
}

setup_remove_owned_file() {
  local source="$1"
  local target="$2"

  if [[ ! -e "$target" && ! -L "$target" ]]; then
    return 0
  fi
  if [[ ! -f "$source" ]]; then
    printf 'Error: Ralph-owned source missing for %s: %s\n' "$target" "$source" >&2
    return 1
  fi
  if ! cmp -s "$source" "$target"; then
    printf 'Error: refusing to remove modified Ralph-owned file: %s\n' "$target" >&2
    return 1
  fi
  setup_merge_status remove "$target"
  if [[ -n "${SETUP_DRY_RUN:-}" ]]; then
    return 0
  fi
  setup_journal_record "$target" || return 1
  rm -f "$target" || return 1
}

setup_remove_owned_hook_scripts() {
  local source_dir="$1"
  local target_dir="$2"
  local file basename target

  if [[ ! -d "$source_dir" ]]; then
    printf 'Error: Ralph hook source directory not found: %s\n' "$source_dir" >&2
    return 1
  fi

  shopt -s nullglob
  local files=("$source_dir"/*)
  shopt -u nullglob

  for file in "${files[@]}"; do
    [[ -f "$file" ]] || continue
    basename="$(basename "$file")"
    target="$target_dir/$basename"
    if [[ -e "$target" || -L "$target" ]]; then
      if [[ ! -f "$file" ]] || ! cmp -s "$file" "$target"; then
        printf 'Error: refusing to remove modified Ralph-owned file: %s\n' "$target" >&2
        return 1
      fi
    fi
  done

  for file in "${files[@]}"; do
    [[ -f "$file" ]] || continue
    basename="$(basename "$file")"
    setup_remove_owned_file "$file" "$target_dir/$basename" || return 1
  done
  return 0
}

setup_remove_json() {
  local target="$1"
  local mode="$2"
  local runtime="$3"
  local bundle_root tmpfile rc

  if [[ ! -f "$target" ]]; then
    return 0
  fi
  if ! setup_remove_require_python3; then
    return 1
  fi
  bundle_root="$(setup_resolve_bundle_root)" || return 1
  tmpfile="$(mktemp "${TMPDIR:-/tmp}/ralph-setup-remove-XXXXXX")"
  rc=0
  python3 "$(setup_remove_python_script)" "$mode" "$target" "$bundle_root" "$runtime" >"$tmpfile" || rc=$?
  if [[ "$rc" -eq 2 ]]; then
    rm -f "$tmpfile"
    return 0
  fi
  if [[ "$rc" -ne 0 ]]; then
    rm -f "$tmpfile"
    return 1
  fi
  setup_merge_status remove "$target"
  if [[ -n "${SETUP_DRY_RUN:-}" ]]; then
    rm -f "$tmpfile"
    return 0
  fi
  if ! setup_journal_record "$target"; then
    rm -f "$tmpfile"
    return 1
  fi
  mv "$tmpfile" "$target" || return 1
}

setup_remove_hooks() {
  local runtime="$1"
  local runtime_dir="$2"

  case "$runtime" in
    claude)
      setup_remove_hooks_claude "$runtime_dir"
      ;;
    cursor)
      setup_remove_hooks_cursor "$runtime_dir"
      ;;
    codex)
      setup_remove_hooks_codex "$runtime_dir"
      ;;
    opencode)
      setup_remove_hooks_opencode "$runtime_dir"
      ;;
    antigravity)
      setup_remove_hooks_antigravity "$runtime_dir"
      ;;
    *)
      printf 'Error: hook removal adapter is not implemented for runtime %s\n' "$runtime" >&2
      return 1
      ;;
  esac
}

setup_remove_mcp() {
  local runtime="$1"
  local runtime_dir="$2"
  local project_root="$3"

  case "$runtime" in
    claude)
      setup_remove_mcp_claude "$runtime_dir" "$project_root"
      ;;
    cursor)
      setup_remove_mcp_cursor "$runtime_dir" "$project_root"
      ;;
    codex)
      setup_remove_mcp_codex "$runtime_dir" "$project_root"
      ;;
    opencode)
      setup_remove_mcp_opencode "$runtime_dir" "$project_root"
      ;;
    antigravity)
      setup_remove_mcp_antigravity "$runtime_dir" "$project_root"
      ;;
    *)
      printf 'Error: MCP removal adapter is not implemented for runtime %s\n' "$runtime" >&2
      return 1
      ;;
  esac
}
