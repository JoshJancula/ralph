#!/usr/bin/env bash
#
# Antigravity removal adapter: owned hook scripts plus reserved JSON ids.
#
# Public interface:
#   setup_remove_hooks_antigravity <runtime_dir>
#   setup_remove_mcp_antigravity <runtime_dir> <project_root>

set -euo pipefail

if [[ -n "${RALPH_SETUP_REMOVE_ANTIGRAVITY_LOADED:-}" ]]; then
  return 0
fi
RALPH_SETUP_REMOVE_ANTIGRAVITY_LOADED=1

setup_remove_hooks_antigravity() {
  local runtime_dir="$1"
  local bundle_root source_hooks

  bundle_root="$(setup_resolve_bundle_root)" || return 1
  source_hooks="$bundle_root/.agents/hooks"
  setup_remove_owned_hook_scripts "$source_hooks" "$runtime_dir/hooks" || return 1
  setup_remove_json "$runtime_dir/hooks.json" hooks antigravity
}

setup_remove_mcp_antigravity() {
  local runtime_dir="$1"
  local project_root="$2"

  setup_remove_json "$runtime_dir/mcp_config.json" mcp antigravity
}
