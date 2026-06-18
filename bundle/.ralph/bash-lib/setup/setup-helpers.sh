#!/usr/bin/env bash
#
# Shared setup helper functions for path resolution, atomic writes, JSON validation,
# config merge status output, and Ralph MCP server path resolution.
#
# These helpers are durable (setup-time) and distinct from per-run overlay cleanup
# helpers in runtime-overlay.sh. Reuses existing install/runtime-overlay patterns
# where practical.
#
# Public interface:
#   setup_resolve_absolute_path <path>        -- Resolve path to absolute
#   setup_resolve_bundle_root                 -- Find Ralph bundle root
#   setup_resolve_mcp_server_path           -- Path to mcp-server.sh
#   setup_atomic_write <target> <content>     -- Atomic write with backup
#   setup_atomic_write_file <source> <target> -- Atomic file copy
#   setup_validate_json <file>                -- Validate JSON using jq
#   setup_merge_status <action> <target>      -- Log merge status with dry-run support
#   setup_ensure_dir <path>                   -- Create directory with dry-run support

set -euo pipefail

# Globals that can be set by callers
SETUP_DRY_RUN="${SETUP_DRY_RUN:-}"

# ============================================================================
# Path Resolution Helpers
# ============================================================================

# Resolve a path to absolute, handling relative paths
# Usage: setup_resolve_absolute_path <path>
# Returns: Absolute path on stdout, dies on failure
setup_resolve_absolute_path() {
  local target="${1:-}"
  if [[ -z "$target" ]]; then
    printf '%s: path argument required\n' "${FUNCNAME[0]}" >&2
    return 1
  fi

  # Already absolute
  if [[ "$target" =~ ^/ ]]; then
    printf '%s' "$target"
    return 0
  fi

  # Relative path - resolve using pwd
  if [[ -d "$target" ]]; then
    (cd "$target" && pwd)
  elif [[ -d "$(dirname "$target")" ]]; then
    local parent
    parent="$(cd "$(dirname "$target")" && pwd)"
    printf '%s/%s' "$parent" "$(basename "$target")"
  else
    # Parent doesn't exist, construct syntactically
    local cwd
    cwd="$(pwd)"
    printf '%s/%s' "$cwd" "$target"
  fi
}

# Find the Ralph bundle root from various starting points
# Usage: setup_resolve_bundle_root
# Returns: Absolute path to bundle/ directory
setup_resolve_bundle_root() {
  # Try SCRIPT_DIR (from caller) or derive from this file
  local search_start="${SCRIPT_DIR:-}"
  if [[ -z "$search_start" ]]; then
    # Derive from this file's location
    search_start="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  fi

  # Walk up looking for bundle/.ralph/ structure
  local current="$search_start"
  while [[ "$current" != "/" ]]; do
    if [[ -d "$current/bundle/.ralph" ]]; then
      printf '%s/bundle' "$current"
      return 0
    fi
    if [[ -d "$current/.ralph" && -d "$current/.cursor" ]]; then
      printf '%s' "$current"
      return 0
    fi
    current="$(dirname "$current")"
  done

  # Try RALPH_HOME if set
  if [[ -n "${RALPH_HOME:-}" && -d "$RALPH_HOME/bundle/.ralph" ]]; then
    printf '%s/bundle' "$RALPH_HOME"
    return 0
  fi

  # Try environment
  if [[ -n "${BUNDLE_ROOT:-}" && -d "$BUNDLE_ROOT/.ralph" ]]; then
    printf '%s' "$BUNDLE_ROOT"
    return 0
  fi

  printf '%s: cannot locate Ralph bundle root\n' "${FUNCNAME[0]}" >&2
  return 1
}

# Resolve the path to Ralph's MCP server script
# Usage: setup_resolve_mcp_server_path
# Returns: Absolute path to mcp-server.sh
setup_resolve_mcp_server_path() {
  local bundle_root
  if ! bundle_root="$(setup_resolve_bundle_root)"; then
    return 1
  fi

  local server_path="$bundle_root/.ralph/mcp-server.sh"
  if [[ ! -f "$server_path" ]]; then
    printf '%s: MCP server not found at %s\n' "${FUNCNAME[0]}" "$server_path" >&2
    return 1
  fi

  printf '%s' "$server_path"
}

# Resolve the Ralph MCP server script for a target project.
# Prefers project-local .ralph/mcp-server.sh, then $RALPH_HOME, then bundle root.
# Usage: setup_resolve_mcp_server_path_for_project <project_root>
setup_resolve_mcp_server_path_for_project() {
  local project_root="${1:-}"
  local server_path resolved

  if [[ -z "$project_root" ]]; then
    printf '%s: project root required\n' "${FUNCNAME[0]}" >&2
    return 1
  fi

  server_path="$project_root/.ralph/mcp-server.sh"
  if [[ -f "$server_path" ]]; then
    resolved="$(cd "$(dirname "$server_path")" && pwd)/$(basename "$server_path")"
    printf '%s' "$resolved"
    return 0
  fi

  if [[ -n "${RALPH_HOME:-}" ]]; then
    server_path="$RALPH_HOME/bundle/.ralph/mcp-server.sh"
    if [[ -f "$server_path" ]]; then
      printf '%s' "$server_path"
      return 0
    fi
  fi

  setup_resolve_mcp_server_path
}

# ============================================================================
# Atomic Write Helpers
# ============================================================================

# Write content atomically to a file with backup support
# On failure, the original file is preserved unchanged
# Usage: setup_atomic_write <target_path> <content>
# Options:
#   SETUP_DRY_RUN=1   -- Log action but don't write
# Returns: 0 on success, 1 on failure
setup_atomic_write() {
  local target="${1:-}"
  local content="${2:-}"

  if [[ -z "$target" ]]; then
    printf '%s: target path required\n' "${FUNCNAME[0]}" >&2
    return 1
  fi

  # Dry-run: just report
  if [[ -n "${SETUP_DRY_RUN:-}" ]]; then
    printf '[DRY-RUN] Would write: %s\n' "$target"
    return 0
  fi

  # Ensure parent directory exists
  local parent
  parent="$(dirname "$target")"
  if [[ ! -d "$parent" ]]; then
    if ! mkdir -p "$parent" 2>/dev/null; then
      printf '%s: failed to create directory %s\n' "${FUNCNAME[0]}" "$parent" >&2
      return 1
    fi
  fi

  # If target doesn't exist, simple atomic write
  if [[ ! -f "$target" ]]; then
    local tmpfile
    tmpfile="$(mktemp "${parent}/.tmp.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -f '$tmpfile' 2>/dev/null || true" RETURN

    if ! printf '%s\n' "$content" > "$tmpfile"; then
      rm -f "$tmpfile" 2>/dev/null || true
      printf '%s: failed to write temp file\n' "${FUNCNAME[0]}" >&2
      return 1
    fi

    if ! mv "$tmpfile" "$target"; then
      rm -f "$tmpfile" 2>/dev/null || true
      printf '%s: failed to move temp file to target\n' "${FUNCNAME[0]}" >&2
      return 1
    fi

    trap - RETURN
    return 0
  fi

  # Target exists - atomic update with backup
  local backup
  backup="${target}.backup.$(date +%s).$$"
  local tmpfile
  tmpfile="$(mktemp "${parent}/.tmp.XXXXXX")"

  # Cleanup on exit
  # shellcheck disable=SC2064
  trap "rm -f '$tmpfile' '$backup' 2>/dev/null || true" RETURN

  # Write new content to temp file
  if ! printf '%s\n' "$content" > "$tmpfile"; then
    rm -f "$tmpfile" 2>/dev/null || true
    printf '%s: failed to write temp file\n' "${FUNCNAME[0]}" >&2
    return 1
  fi

  # Create backup of original
  if ! cp "$target" "$backup" 2>/dev/null; then
    rm -f "$tmpfile" "$backup" 2>/dev/null || true
    printf '%s: failed to create backup\n' "${FUNCNAME[0]}" >&2
    return 1
  fi

  # Atomic move
  if ! mv "$tmpfile" "$target"; then
    # Restore backup on failure
    cp "$backup" "$target" 2>/dev/null || true
    rm -f "$tmpfile" "$backup" 2>/dev/null || true
    printf '%s: failed to update target, original restored\n' "${FUNCNAME[0]}" >&2
    return 1
  fi

  # Success - remove backup
  rm -f "$backup" 2>/dev/null || true
  trap - RETURN
  return 0
}

# Copy a file atomically to a target location
# Usage: setup_atomic_write_file <source_path> <target_path>
# Options:
#   SETUP_DRY_RUN=1   -- Log action but don't copy
# Returns: 0 on success, 1 on failure
setup_atomic_write_file() {
  local source="${1:-}"
  local target="${2:-}"

  if [[ -z "$source" || -z "$target" ]]; then
    printf '%s: source and target paths required\n' "${FUNCNAME[0]}" >&2
    return 1
  fi

  if [[ ! -f "$source" ]]; then
    printf '%s: source file not found: %s\n' "${FUNCNAME[0]}" "$source" >&2
    return 1
  fi

  # Dry-run: just report
  if [[ -n "${SETUP_DRY_RUN:-}" ]]; then
    printf '[DRY-RUN] Would copy %s to %s\n' "$source" "$target"
    return 0
  fi

  # Ensure parent directory exists
  local parent
  parent="$(dirname "$target")"
  if [[ ! -d "$parent" ]]; then
    if ! mkdir -p "$parent" 2>/dev/null; then
      printf '%s: failed to create directory %s\n' "${FUNCNAME[0]}" "$parent" >&2
      return 1
    fi
  fi

  # If target doesn't exist, simple atomic copy
  if [[ ! -f "$target" ]]; then
    local tmpfile
    tmpfile="$(mktemp "${parent}/.tmp.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -f '$tmpfile' 2>/dev/null || true" RETURN

    if ! cp "$source" "$tmpfile"; then
      rm -f "$tmpfile" 2>/dev/null || true
      printf '%s: failed to copy to temp file\n' "${FUNCNAME[0]}" >&2
      return 1
    fi

    if ! mv "$tmpfile" "$target"; then
      rm -f "$tmpfile" 2>/dev/null || true
      printf '%s: failed to move temp file to target\n' "${FUNCNAME[0]}" >&2
      return 1
    fi

    trap - RETURN
    return 0
  fi

  # Target exists - atomic update with backup
  local backup
  backup="${target}.backup.$(date +%s).$$"
  local tmpfile
  tmpfile="$(mktemp "${parent}/.tmp.XXXXXX")"

  # shellcheck disable=SC2064
  trap "rm -f '$tmpfile' '$backup' 2>/dev/null || true" RETURN

  # Copy to temp file first
  if ! cp "$source" "$tmpfile"; then
    rm -f "$tmpfile" "$backup" 2>/dev/null || true
    printf '%s: failed to copy to temp file\n' "${FUNCNAME[0]}" >&2
    return 1
  fi

  # Create backup of original
  if ! cp "$target" "$backup" 2>/dev/null; then
    rm -f "$tmpfile" "$backup" 2>/dev/null || true
    printf '%s: failed to create backup\n' "${FUNCNAME[0]}" >&2
    return 1
  fi

  # Atomic move
  if ! mv "$tmpfile" "$target"; then
    cp "$backup" "$target" 2>/dev/null || true
    rm -f "$tmpfile" "$backup" 2>/dev/null || true
    printf '%s: failed to update target, original restored\n' "${FUNCNAME[0]}" >&2
    return 1
  fi

  # Success - remove backup
  rm -f "$backup" 2>/dev/null || true
  trap - RETURN
  return 0
}

# ============================================================================
# JSON Validation Helpers
# ============================================================================

# Validate a file contains valid JSON using jq
# Usage: setup_validate_json <file_path>
# Returns: 0 if valid, 1 if invalid or file missing
setup_validate_json() {
  local file="${1:-}"

  if [[ -z "$file" ]]; then
    printf '%s: file path required\n' "${FUNCNAME[0]}" >&2
    return 1
  fi

  if [[ ! -f "$file" ]]; then
    printf '%s: file not found: %s\n' "${FUNCNAME[0]}" "$file" >&2
    return 1
  fi

  if ! command -v jq &>/dev/null; then
    printf '%s: jq is required for JSON validation\n' "${FUNCNAME[0]}" >&2
    return 1
  fi

  if ! jq empty "$file" 2>/dev/null; then
    printf '%s: invalid JSON in %s\n' "${FUNCNAME[0]}" "$file" >&2
    return 1
  fi

  return 0
}

# Validate a JSON string
# Usage: setup_validate_json_string <json_string>
# Returns: 0 if valid, 1 if invalid
setup_validate_json_string() {
  local json="${1:-}"

  if [[ -z "$json" ]]; then
    printf '%s: JSON string required\n' "${FUNCNAME[0]}" >&2
    return 1
  fi

  if ! command -v jq &>/dev/null; then
    printf '%s: jq is required for JSON validation\n' "${FUNCNAME[0]}" >&2
    return 1
  fi

  if ! printf '%s' "$json" | jq empty 2>/dev/null; then
    printf '%s: invalid JSON string\n' "${FUNCNAME[0]}" >&2
    return 1
  fi

  return 0
}

# ============================================================================
# Config Merge Status Output Helpers
# ============================================================================

# Log a configuration merge operation with appropriate dry-run prefix
# Usage: setup_merge_status <action> <target_path> [<source_path>]
# Actions: write, merge, skip, remove
# Example: setup_merge_status "write" "$HOME/.claude/mcp.json"
#          setup_merge_status "merge" "$HOME/.claude/mcp.json" "$BUNDLE/.claude/mcp.example.json"
setup_merge_status() {
  local action="${1:-}"
  local target="${2:-}"
  local source="${3:-}"

  if [[ -z "$action" || -z "$target" ]]; then
    printf '%s: action and target required\n' "${FUNCNAME[0]}" >&2
    return 1
  fi

  local prefix=""
  if [[ -n "${SETUP_DRY_RUN:-}" ]]; then
    prefix="[DRY-RUN] "
  fi

  case "$action" in
    write|create)
      if [[ -n "$source" ]]; then
        printf '%s%s: %s (from %s)\n' "$prefix" "Created" "$target" "$source"
      else
        printf '%s%s: %s\n' "$prefix" "Created" "$target"
      fi
      ;;
    merge|update)
      if [[ -n "$source" ]]; then
        printf '%s%s: %s (merged with %s)\n' "$prefix" "Updated" "$target" "$source"
      else
        printf '%s%s: %s\n' "$prefix" "Updated" "$target"
      fi
      ;;
    skip|exists)
      printf '%s%s: %s (no changes needed)\n' "$prefix" "Skipped" "$target"
      ;;
    remove|delete)
      printf '%s%s: %s\n' "$prefix" "Removed" "$target"
      ;;
    *)
      printf '%s%s: %s\n' "$prefix" "$action" "$target"
      ;;
  esac
}

# Log a general setup action with dry-run support
# Usage: setup_action_status <verb> <target>
# Example: setup_action_status "Install hooks" "/path/to/.claude/hooks"
setup_action_status() {
  local verb="${1:-}"
  local target="${2:-}"

  if [[ -z "$verb" || -z "$target" ]]; then
    printf '%s: verb and target required\n' "${FUNCNAME[0]}" >&2
    return 1
  fi

  if [[ -n "${SETUP_DRY_RUN:-}" ]]; then
    printf '[DRY-RUN] Would %s: %s\n' "$verb" "$target"
  else
    printf '%s: %s\n' "$verb" "$target"
  fi
}

# ============================================================================
# Directory Helpers
# ============================================================================

# Ensure a directory exists (with dry-run support)
# Usage: setup_ensure_dir <path>
# Returns: 0 on success, 1 on failure
setup_ensure_dir() {
  local path="${1:-}"

  if [[ -z "$path" ]]; then
    printf '%s: path required\n' "${FUNCNAME[0]}" >&2
    return 1
  fi

  if [[ -n "${SETUP_DRY_RUN:-}" ]]; then
    if [[ ! -d "$path" ]]; then
      printf '[DRY-RUN] Would create directory: %s\n' "$path"
    fi
    return 0
  fi

  if [[ ! -d "$path" ]]; then
    if mkdir -p "$path"; then
      return 0
    else
      printf '%s: failed to create directory %s\n' "${FUNCNAME[0]}" "$path" >&2
      return 1
    fi
  fi

  return 0
}

# ============================================================================
# Utility Helpers
# ============================================================================

# Check if a file contains specific content
# Usage: setup_file_contains <file> <pattern>
# Returns: 0 if found, 1 if not found
setup_file_contains() {
  local file="${1:-}"
  local pattern="${2:-}"

  if [[ -z "$file" || -z "$pattern" ]]; then
    return 1
  fi

  if [[ ! -f "$file" ]]; then
    return 1
  fi

  grep -q "$pattern" "$file" 2>/dev/null
}

# Copy a directory tree preserving structure
# Usage: setup_copy_tree <source_dir> <target_parent>
# Options:
#   SETUP_DRY_RUN=1   -- Log action but don't copy
# Returns: 0 on success, 1 on failure
setup_copy_tree() {
  local source="${1:-}"
  local target_parent="${2:-}"

  if [[ -z "$source" || -z "$target_parent" ]]; then
    printf '%s: source and target parent required\n' "${FUNCNAME[0]}" >&2
    return 1
  fi

  if [[ ! -d "$source" ]]; then
    printf '%s: source directory not found: %s\n' "${FUNCNAME[0]}" "$source" >&2
    return 1
  fi

  local source_name
  source_name="$(basename "$source")"
  local target="$target_parent/$source_name"

  if [[ -n "${SETUP_DRY_RUN:-}" ]]; then
    printf '[DRY-RUN] Would copy directory %s to %s\n' "$source" "$target"
    return 0
  fi

  if [[ ! -d "$target_parent" ]]; then
    mkdir -p "$target_parent" || {
      printf '%s: failed to create target parent %s\n' "${FUNCNAME[0]}" "$target_parent" >&2
      return 1
    }
  fi

  if [[ -d "$target" ]]; then
    # Target exists, merge contents
    local file
    while IFS= read -r -d '' file; do
      local rel_path="${file#$source/}"
      local target_file="$target/$rel_path"
      local target_file_dir
      target_file_dir="$(dirname "$target_file")"
      
      if [[ ! -d "$target_file_dir" ]]; then
        mkdir -p "$target_file_dir" || continue
      fi
      
      cp "$file" "$target_file"
    done < <(find "$source" -type f -print0 2>/dev/null)
  else
    # Target doesn't exist, copy entire tree
    cp -r "$source" "$target"
  fi

  return 0
}
