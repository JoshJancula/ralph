#!/usr/bin/env bash
#
# OpenCode removal adapter: owned plugin file plus reserved MCP ids.
# JSONC comments in opencode.json / opencode.jsonc are preserved.
#
# Public interface:
#   setup_remove_hooks_opencode <runtime_dir>
#   setup_remove_mcp_opencode <runtime_dir> <project_root>

set -euo pipefail

if [[ -n "${RALPH_SETUP_REMOVE_OPENCODE_LOADED:-}" ]]; then
  return 0
fi
RALPH_SETUP_REMOVE_OPENCODE_LOADED=1

setup_remove_hooks_opencode() {
  local runtime_dir="$1"
  local bundle_root plugin_source plugin_target

  bundle_root="$(setup_resolve_bundle_root)" || return 1
  if ! plugin_source="$(setup_hooks_opencode_resolve_plugin_source "$bundle_root")"; then
    return 1
  fi
  plugin_target="$runtime_dir/plugins/$(basename "$plugin_source")"
  setup_remove_owned_file "$plugin_source" "$plugin_target"
}

setup_remove_mcp_opencode() {
  local runtime_dir="$1"
  local project_root="$2"
  local path

  for path in \
    "$project_root/opencode.json" \
    "$project_root/opencode.jsonc" \
    "$runtime_dir/opencode.json" \
    "$runtime_dir/opencode.jsonc"
  do
    setup_remove_json "$path" mcp opencode || return 1
  done
}
