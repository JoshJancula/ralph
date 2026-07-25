#!/usr/bin/env bash
#
# Durable hook setup for Claude, Cursor, Codex, and OpenCode runtimes.
#
# Copies bundle hook scripts (or plugins) into the selected runtime directory and
# merges Ralph hook configuration using the same Python merge helpers as per-run overlays.
#
# Public interface:
#   setup_hooks_for_runtime <runtime> <runtime_dir>
#   setup_hooks_claude <runtime_dir>
#   setup_hooks_cursor <runtime_dir>
#   setup_hooks_codex <runtime_dir>
#   setup_hooks_opencode <runtime_dir>

set -euo pipefail

if [[ -n "${RALPH_SETUP_HOOKS_LOADED:-}" ]]; then
  return 0
fi
RALPH_SETUP_HOOKS_LOADED=1

SETUP_HOOKS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RALPH_SETUP_ROOT="$(cd "$SETUP_HOOKS_LIB_DIR/../.." && pwd)"

setup_hooks_python_script() {
  local script_name="$1"
  printf '%s/python/%s' "$RALPH_SETUP_ROOT" "$script_name"
}

setup_hooks_validate_existing_json() {
  local file="$1"
  local label="$2"

  if [[ ! -f "$file" ]]; then
    return 0
  fi

  if ! setup_validate_json "$file"; then
    printf 'Error: existing %s is invalid JSON: %s\n' "$label" "$file" >&2
    return 1
  fi

  return 0
}

setup_copy_hook_scripts() {
  local source_dir="$1"
  local target_dir="$2"
  local file basename

  if [[ ! -d "$source_dir" ]]; then
    printf '%s: hook source directory not found: %s\n' "${FUNCNAME[0]}" "$source_dir" >&2
    return 1
  fi

  setup_ensure_dir "$target_dir"

  shopt -s nullglob
  local files=("$source_dir"/*)
  shopt -u nullglob

  if [[ ${#files[@]} -eq 0 ]]; then
    printf '%s: no hook scripts in %s\n' "${FUNCNAME[0]}" "$source_dir" >&2
    return 1
  fi

  for file in "${files[@]}"; do
    [[ -f "$file" ]] || continue
    basename="$(basename "$file")"
    if ! setup_atomic_write_file "$file" "$target_dir/$basename"; then
      return 1
    fi
    if [[ -z "${SETUP_DRY_RUN:-}" ]]; then
      chmod +x "$target_dir/$basename" 2>/dev/null || true
    fi
  done

  return 0
}

setup_merge_json_with_template() {
  local target="$1"
  local template="$2"
  local merge_script="$3"
  local label="$4"
  local tmpfile=""

  if [[ ! -f "$template" ]]; then
    printf 'Error: %s template missing at %s\n' "$label" "$template" >&2
    return 1
  fi

  if ! command -v python3 &>/dev/null; then
    printf 'Error: python3 is required for %s merge\n' "$label" >&2
    return 1
  fi

  if [[ -n "${SETUP_DRY_RUN:-}" ]]; then
    setup_merge_status "Merge" "$target"
    return 0
  fi

  tmpfile="$(mktemp "${TMPDIR:-/tmp}/ralph-setup-merge-XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -f '$tmpfile'" RETURN

  if [[ -f "$target" ]]; then
    cp "$target" "$tmpfile"
  else
    printf '{}\n' >"$tmpfile"
  fi

  if ! python3 "$merge_script" "$tmpfile" "$template"; then
    printf 'Error: failed to merge %s into %s\n' "$label" "$target" >&2
    return 1
  fi

  if ! setup_atomic_write_file "$tmpfile" "$target"; then
    return 1
  fi

  trap - RETURN
  rm -f "$tmpfile"
  return 0
}

setup_hooks_claude() {
  local runtime_dir="$1"
  local bundle_root source_hooks target_hooks settings_target settings_template merge_script

  bundle_root="$(setup_resolve_bundle_root)"
  source_hooks="$bundle_root/.claude/hooks"
  target_hooks="$runtime_dir/hooks"
  settings_target="$runtime_dir/settings.json"
  settings_template="$bundle_root/.claude/settings.json"
  merge_script="$(setup_hooks_python_script runtime-overlay-claude-merge-settings.py)"

  if ! setup_hooks_validate_existing_json "$settings_target" "Claude settings"; then
    return 1
  fi

  setup_merge_status "Install hook scripts" "$target_hooks"
  if ! setup_copy_hook_scripts "$source_hooks" "$target_hooks"; then
    return 1
  fi

  setup_merge_status "Merge Claude hook settings" "$settings_target"
  if ! setup_merge_json_with_template \
    "$settings_target" \
    "$settings_template" \
    "$merge_script" \
    "Claude hook settings"; then
    return 1
  fi

  return 0
}

setup_hooks_cursor() {
  local runtime_dir="$1"
  local bundle_root source_hooks target_hooks hooks_target hooks_template merge_script

  bundle_root="$(setup_resolve_bundle_root)"
  source_hooks="$bundle_root/.cursor/hooks"
  target_hooks="$runtime_dir/hooks"
  hooks_target="$runtime_dir/hooks.json"
  hooks_template="$bundle_root/.cursor/hooks.json"
  merge_script="$(setup_hooks_python_script runtime-overlay-cursor-merge-hooks.py)"

  if ! setup_hooks_validate_existing_json "$hooks_target" "Cursor hooks config"; then
    return 1
  fi

  setup_merge_status "Install hook scripts" "$target_hooks"
  if ! setup_copy_hook_scripts "$source_hooks" "$target_hooks"; then
    return 1
  fi

  setup_merge_status "Merge Cursor hooks config" "$hooks_target"
  if ! setup_merge_json_with_template \
    "$hooks_target" \
    "$hooks_template" \
    "$merge_script" \
    "Cursor hooks config"; then
    return 1
  fi

  return 0
}

setup_hooks_opencode_resolve_plugin_source() {
  local bundle_root="$1"
  local ext candidate

  for ext in ts js mjs; do
    candidate="$bundle_root/.opencode/plugins/ralph-runtime-hooks.$ext"
    if [[ -f "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done

  printf '%s: Ralph OpenCode plugin not found under %s/.opencode/plugins/\n' \
    "${FUNCNAME[0]}" "$bundle_root" >&2
  return 1
}

setup_hooks_codex() {
  local runtime_dir="$1"
  local bundle_root source_hooks target_hooks hooks_target hooks_template merge_script

  bundle_root="$(setup_resolve_bundle_root)"
  source_hooks="$bundle_root/.codex/hooks"
  target_hooks="$runtime_dir/hooks"
  hooks_target="$runtime_dir/hooks.json"
  hooks_template="$bundle_root/.codex/hooks.json"
  merge_script="$(setup_hooks_python_script runtime-overlay-codex-merge-hooks.py)"

  if ! setup_hooks_validate_existing_json "$hooks_target" "Codex hooks config"; then
    return 1
  fi

  setup_merge_status "Install hook scripts" "$target_hooks"
  if ! setup_copy_hook_scripts "$source_hooks" "$target_hooks"; then
    return 1
  fi

  setup_merge_status "Merge Codex hooks config" "$hooks_target"
  if ! setup_merge_json_with_template \
    "$hooks_target" \
    "$hooks_template" \
    "$merge_script" \
    "Codex hooks config"; then
    return 1
  fi

  return 0
}

setup_hooks_opencode() {
  local runtime_dir="$1"
  local bundle_root plugin_source plugin_target plugins_dir basename

  bundle_root="$(setup_resolve_bundle_root)"
  plugins_dir="$runtime_dir/plugins"

  if ! plugin_source="$(setup_hooks_opencode_resolve_plugin_source "$bundle_root")"; then
    return 1
  fi

  basename="$(basename "$plugin_source")"
  plugin_target="$plugins_dir/$basename"

  setup_merge_status "Install OpenCode plugin" "$plugin_target" "$plugin_source"
  if ! setup_atomic_write_file "$plugin_source" "$plugin_target"; then
    return 1
  fi

  printf 'Note: OpenCode native hook effectiveness is not proven headless; use MCP proxy compaction as the authoritative path.\n'

  return 0
}

setup_hooks_antigravity() {
  local runtime_dir="$1"
  local bundle_root source_hooks target_hooks hooks_target hooks_template merge_script

  bundle_root="$(setup_resolve_bundle_root)"
  source_hooks="$bundle_root/.agents/hooks"
  target_hooks="$runtime_dir/hooks"
  hooks_target="$runtime_dir/hooks.json"
  hooks_template="$bundle_root/.agents/hooks.json"
  merge_script="$(setup_hooks_python_script runtime-overlay-antigravity-merge-hooks.py)"

  if ! setup_hooks_validate_existing_json "$hooks_target" "Antigravity hooks config"; then
    return 1
  fi

  setup_merge_status "Install hook scripts" "$target_hooks"
  if ! setup_copy_hook_scripts "$source_hooks" "$target_hooks"; then
    return 1
  fi

  setup_merge_status "Merge Antigravity hooks config" "$hooks_target"
  if ! setup_merge_json_with_template \
    "$hooks_target" \
    "$hooks_template" \
    "$merge_script" \
    "Antigravity hooks config"; then
    return 1
  fi

  return 0
}

setup_hooks_for_runtime() {
  local runtime="$1"
  local runtime_dir="$2"

  case "$runtime" in
    claude)
      setup_hooks_claude "$runtime_dir"
      ;;
    cursor)
      setup_hooks_cursor "$runtime_dir"
      ;;
    codex)
      setup_hooks_codex "$runtime_dir"
      ;;
    opencode)
      setup_hooks_opencode "$runtime_dir"
      ;;
    antigravity)
      setup_hooks_antigravity "$runtime_dir"
      ;;
    *)
      printf 'Error: durable hook setup is not implemented for runtime %s\n' "$runtime" >&2
      return 1
      ;;
  esac
}
