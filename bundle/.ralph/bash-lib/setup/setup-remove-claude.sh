#!/usr/bin/env bash
#
# Claude removal adapter: owned hook scripts plus reserved JSON ids/names.
#
# Public interface:
#   setup_remove_hooks_claude <runtime_dir>
#   setup_remove_mcp_claude <runtime_dir> <project_root>

set -euo pipefail

if [[ -n "${RALPH_SETUP_REMOVE_CLAUDE_LOADED:-}" ]]; then
  return 0
fi
RALPH_SETUP_REMOVE_CLAUDE_LOADED=1

setup_remove_hooks_claude() {
  local runtime_dir="$1"
  local bundle_root source_hooks

  bundle_root="$(setup_resolve_bundle_root)" || return 1
  source_hooks="$bundle_root/.claude/hooks"
  setup_remove_owned_hook_scripts "$source_hooks" "$runtime_dir/hooks" || return 1
  setup_remove_json "$runtime_dir/settings.json" hooks claude
}

setup_remove_mcp_claude() {
  local runtime_dir="$1"
  local project_root="$2"

  setup_remove_json "$project_root/.mcp.json" mcp claude
}
