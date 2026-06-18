#!/usr/bin/env bash
# OpenCode native hook overlay: local workspace plugin staging (telemetry + optional mutation).

if [[ -n "${RALPH_RUNTIME_OVERLAY_OPENCODE_LOADED:-}" ]]; then
  return
fi
RALPH_RUNTIME_OVERLAY_OPENCODE_LOADED=1

ralph_native_hooks_want_activation() {
  local mode="${RALPH_NATIVE_HOOKS:-}"
  case "$mode" in
    off) return 1 ;;
    on|auto) return 0 ;;
    *) return 1 ;;
  esac
}

_runtime_overlay_opencode_lib_dir() {
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

_runtime_overlay_opencode_bundle_root() {
  local lib_dir
  lib_dir="$(_runtime_overlay_opencode_lib_dir)"
  cd "$lib_dir/../../.." && pwd
}

_runtime_overlay_opencode_plugin_path() {
  local bundle_root="${RALPH_HOME:+${RALPH_HOME}/bundle}"
  if [[ -z "$bundle_root" ]]; then
    bundle_root="$(_runtime_overlay_opencode_bundle_root)"
  fi
  local candidate
  for ext in ts js mjs; do
    candidate="$bundle_root/.opencode/plugins/ralph-runtime-hooks.$ext"
    if [[ -f "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  if [[ -n "${RALPH_HOME:-}" ]]; then
    for ext in ts js mjs; do
      candidate="${RALPH_HOME}/bundle/.opencode/plugins/ralph-runtime-hooks.$ext"
      if [[ -f "$candidate" ]]; then
        printf '%s' "$candidate"
        return 0
      fi
    done
  fi
  return 1
}

_run_plan_invoke_opencode_stage_workspace_plugin() {
  local workspace="${1:-}"
  local plugin_source="${2:-}"
  if [[ -z "$workspace" || -z "$plugin_source" || ! -f "$plugin_source" ]]; then
    return 1
  fi
  local plugins_dir="${workspace}/.opencode/plugins"
  mkdir -p "$plugins_dir" || return 1
  local plugin_filename
  plugin_filename="$(basename "$plugin_source")"
  local plugin_dest="${plugins_dir}/${plugin_filename}"
  cp "$plugin_source" "$plugin_dest" || return 1
  printf '%s' "$plugin_dest"
}

run_plan_invoke_opencode_native_hooks_cleanup() {
  if [[ -n "${OPENCODE_PLAN_STAGED_PLUGIN_PATH:-}" && -f "$OPENCODE_PLAN_STAGED_PLUGIN_PATH" ]]; then
    rm -f "$OPENCODE_PLAN_STAGED_PLUGIN_PATH"
  fi
  unset OPENCODE_PLAN_NATIVE_HOOKS_ACTIVE OPENCODE_PLAN_STAGED_PLUGIN_PATH
}

run_plan_invoke_opencode_native_hooks_prepare() {
  local requested="${RALPH_NATIVE_HOOKS:-}"
  local overlay_mode="${RALPH_OPTIMIZATION_MODE:-}"
  local workspace="${WORKSPACE:-}"
  local mutation_note="OpenCode plugin loaded from workspace .opencode/plugins/; tool.execute.after output.output mutation is unproven on the headless run path; use MCP compaction (RALPH_PROXY_SHELL_COMPACT=1) for reliable token reduction"

  OPENCODE_PLAN_NATIVE_HOOKS_ACTIVE=0
  export OPENCODE_PLAN_NATIVE_HOOKS_ACTIVE

  if declare -F runtime_overlay_set_native_hooks_requested >/dev/null 2>&1; then
    runtime_overlay_set_native_hooks_requested "${requested:-unset}"
  fi
  if [[ -n "$overlay_mode" ]] && declare -F runtime_overlay_set_overlay_mode >/dev/null 2>&1; then
    runtime_overlay_set_overlay_mode "$overlay_mode"
  fi

  if ! ralph_native_hooks_want_activation; then
    if declare -F runtime_overlay_set_native_hooks_effective >/dev/null 2>&1; then
      runtime_overlay_set_native_hooks_effective "false"
    fi
    return 0
  fi

  case "${RALPH_BASH_COMPACT:-}" in
    1 | true | yes | on)
      if declare -F runtime_overlay_add_warning >/dev/null 2>&1; then
        runtime_overlay_add_warning "RALPH_BASH_COMPACT is ignored for OpenCode native plugin hooks: $mutation_note"
      fi
      ;;
  esac

  if [[ -z "$workspace" ]]; then
    if declare -F runtime_overlay_add_warning >/dev/null 2>&1; then
      runtime_overlay_add_warning "Ralph OpenCode plugin staging requires WORKSPACE to be set"
    fi
    if declare -F runtime_overlay_set_native_hooks_effective >/dev/null 2>&1; then
      runtime_overlay_set_native_hooks_effective "false"
    fi
    return 0
  fi

  local plugin_source=""
  if ! plugin_source="$(_runtime_overlay_opencode_plugin_path)"; then
    if declare -F runtime_overlay_add_warning >/dev/null 2>&1; then
      runtime_overlay_add_warning "Ralph OpenCode plugin not found under bundle/.opencode/plugins/"
    fi
    if declare -F runtime_overlay_set_native_hooks_effective >/dev/null 2>&1; then
      runtime_overlay_set_native_hooks_effective "false"
    fi
    return 0
  fi

  local staged_plugin_path=""
  if ! staged_plugin_path="$(_run_plan_invoke_opencode_stage_workspace_plugin "$workspace" "$plugin_source")"; then
    if declare -F runtime_overlay_add_warning >/dev/null 2>&1; then
      runtime_overlay_add_warning "Failed to stage Ralph OpenCode plugin to workspace .opencode/plugins/"
    fi
    if declare -F runtime_overlay_set_native_hooks_effective >/dev/null 2>&1; then
      runtime_overlay_set_native_hooks_effective "false"
    fi
    return 0
  fi

  OPENCODE_PLAN_NATIVE_HOOKS_ACTIVE=1
  OPENCODE_PLAN_STAGED_PLUGIN_PATH="$staged_plugin_path"
  export OPENCODE_PLAN_NATIVE_HOOKS_ACTIVE OPENCODE_PLAN_STAGED_PLUGIN_PATH

  if declare -F runtime_overlay_set_native_hooks_configured >/dev/null 2>&1; then
    runtime_overlay_set_native_hooks_configured "true"
  fi
  if declare -F runtime_overlay_set_native_hooks_effective >/dev/null 2>&1; then
    runtime_overlay_set_native_hooks_effective "false"
  fi
  if declare -F runtime_overlay_set_native_hooks_reason >/dev/null 2>&1; then
    runtime_overlay_set_native_hooks_reason "plugin_local_load_mutation_unproven"
  fi
  if declare -F runtime_overlay_set_native_output_mutation_proven >/dev/null 2>&1; then
    runtime_overlay_set_native_output_mutation_proven "false"
  fi
  if declare -F runtime_overlay_set_native_shell_wrapper_enabled >/dev/null 2>&1; then
    runtime_overlay_set_native_shell_wrapper_enabled "false"
  fi
  if declare -F runtime_overlay_set_native_shell_wrapper_effective >/dev/null 2>&1; then
    runtime_overlay_set_native_shell_wrapper_effective "false"
  fi
  if declare -F runtime_overlay_set_native_shell_compaction_authoritative >/dev/null 2>&1; then
    runtime_overlay_set_native_shell_compaction_authoritative "mcp_proxy_compaction"
  fi
  if declare -F runtime_overlay_note_mcp_compaction_fallback_authoritative >/dev/null 2>&1; then
    runtime_overlay_note_mcp_compaction_fallback_authoritative
  fi
  if declare -F runtime_overlay_add_capability >/dev/null 2>&1; then
    runtime_overlay_add_capability "opencode-plugin-local-load"
  fi
  if declare -F runtime_overlay_add_warning >/dev/null 2>&1; then
    runtime_overlay_add_warning "$mutation_note"
  fi
  if declare -F ralph_mcp_overlay_register_runtime_cleanup >/dev/null 2>&1; then
    ralph_mcp_overlay_register_runtime_cleanup run_plan_invoke_opencode_native_hooks_cleanup
  fi
  return 0
}
