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

_runtime_overlay_opencode_effective_workspace() {
  local agent_workspace="${RALPH_AGENT_WORKSPACE:-}"
  local project_workspace="${WORKSPACE:-}"
  if [[ -n "$agent_workspace" ]]; then
    printf '%s' "$agent_workspace"
    return 0
  fi
  if [[ -n "$project_workspace" ]]; then
    printf '%s' "$project_workspace"
    return 0
  fi
  return 1
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
  local plugin_filename="ralph-runtime-hooks.ts"
  if [[ "$(basename "$plugin_source")" == *.ts ]]; then
    plugin_filename="$(basename "$plugin_source")"
  fi
  local plugin_dest="${plugins_dir}/${plugin_filename}"
  cp "$plugin_source" "$plugin_dest" || return 1
  printf '%s' "$plugin_dest"
}

# OpenCode may update its project-local plugin package metadata to the running
# CLI version before the model is invoked.  Those files are runtime state, not
# agent output: snapshot them into the ordinary overlay journal and restore
# them before graph write-scope verification observes the workspace.
run_plan_invoke_opencode_package_metadata_prepare() {
  local workspace="" target backup_var existed_var name
  workspace="$(_runtime_overlay_opencode_effective_workspace)" || return 0
  mkdir -p "$workspace/.opencode" || return 1

  for name in package.json package-lock.json bun.lock; do
    target="$workspace/.opencode/$name"
    backup_var="OPENCODE_PLAN_PACKAGE_${name//[^A-Za-z0-9]/_}_BACKUP"
    existed_var="OPENCODE_PLAN_PACKAGE_${name//[^A-Za-z0-9]/_}_EXISTED"
    printf -v "$existed_var" '%s' 0
    printf -v "$backup_var" '%s' ""
    if [[ -f "$target" ]]; then
      printf -v "$existed_var" '%s' 1
      if declare -F runtime_overlay_record_original_file >/dev/null 2>&1; then
        runtime_overlay_record_original_file "$target" "$backup_var" 1
      else
        local fallback_backup
        fallback_backup="$(mktemp "${TMPDIR:-/tmp}/ralph-opencode-${name//[^A-Za-z0-9]/_}-XXXXXX")"
        cp -p "$target" "$fallback_backup" || return 1
        printf -v "$backup_var" '%s' "$fallback_backup"
      fi
    elif declare -F runtime_overlay_record_generated_file >/dev/null 2>&1; then
      runtime_overlay_record_generated_file "$target"
    fi
    export "$backup_var" "$existed_var"
  done
  OPENCODE_PLAN_PACKAGE_METADATA_PREPARED=1
  export OPENCODE_PLAN_PACKAGE_METADATA_PREPARED
}

run_plan_invoke_opencode_package_metadata_cleanup() {
  [[ "${OPENCODE_PLAN_PACKAGE_METADATA_PREPARED:-0}" == 1 ]] || return 0
  local workspace="" target backup_var existed_var backup existed name rc=0
  workspace="$(_runtime_overlay_opencode_effective_workspace)" || return 0
  for name in package.json package-lock.json bun.lock; do
    target="$workspace/.opencode/$name"
    backup_var="OPENCODE_PLAN_PACKAGE_${name//[^A-Za-z0-9]/_}_BACKUP"
    existed_var="OPENCODE_PLAN_PACKAGE_${name//[^A-Za-z0-9]/_}_EXISTED"
    backup="${!backup_var:-}"
    existed="${!existed_var:-0}"
    if [[ "$existed" == 1 ]]; then
      if [[ -f "$backup" ]]; then
        cp -p "$backup" "$target" || rc=1
      else
        rc=1
      fi
    else
      rm -f "$target" || rc=1
    fi
    unset "$backup_var" "$existed_var"
  done
  unset OPENCODE_PLAN_PACKAGE_METADATA_PREPARED
  return "$rc"
}

_runtime_overlay_opencode_record_tool_access_telemetry() {
  local mode="${RALPH_MODE:-no}"
  case "$mode" in
    hybrid)
      if declare -F runtime_overlay_set_tool_access_mode >/dev/null 2>&1; then
        runtime_overlay_set_tool_access_mode "hybrid"
      fi
      if declare -F runtime_overlay_set_mcp_effective >/dev/null 2>&1; then
        runtime_overlay_set_mcp_effective "true"
      fi
      if declare -F runtime_overlay_add_capability >/dev/null 2>&1; then
        runtime_overlay_add_capability "opencode-hybrid-native-and-ralph-mcp"
      fi
      ;;
    ralph)
      if declare -F runtime_overlay_set_tool_access_mode >/dev/null 2>&1; then
        runtime_overlay_set_tool_access_mode "ralph"
      fi
      if declare -F runtime_overlay_set_mcp_effective >/dev/null 2>&1; then
        runtime_overlay_set_mcp_effective "true"
      fi
      ;;
    native)
      if declare -F runtime_overlay_set_tool_access_mode >/dev/null 2>&1; then
        runtime_overlay_set_tool_access_mode "native"
      fi
      ;;
    *)
      if declare -F runtime_overlay_set_tool_access_mode >/dev/null 2>&1; then
        runtime_overlay_set_tool_access_mode "native"
      fi
      ;;
  esac
}

_runtime_overlay_opencode_record_hook_configured_not_effective() {
  if declare -F runtime_overlay_set_native_hooks_configured >/dev/null 2>&1; then
    runtime_overlay_set_native_hooks_configured "true"
  fi
  if declare -F runtime_overlay_set_native_hooks_effective >/dev/null 2>&1; then
    runtime_overlay_set_native_hooks_effective "false"
  fi
  if declare -F runtime_overlay_set_native_hooks_used_on_run >/dev/null 2>&1; then
    runtime_overlay_set_native_hooks_used_on_run "false"
  fi
  if declare -F runtime_overlay_set_native_hooks_observed_effect >/dev/null 2>&1; then
    runtime_overlay_set_native_hooks_observed_effect "pending_hook_event"
  fi
  if declare -F runtime_overlay_set_native_hooks_observed_reason >/dev/null 2>&1; then
    runtime_overlay_set_native_hooks_observed_reason "plugin_staged_awaiting_observed_hook_event"
  fi
}

_runtime_overlay_opencode_record_hook_unconfigured() {
  if declare -F runtime_overlay_set_native_hooks_configured >/dev/null 2>&1; then
    runtime_overlay_set_native_hooks_configured "false"
  fi
  if declare -F runtime_overlay_set_native_hooks_effective >/dev/null 2>&1; then
    runtime_overlay_set_native_hooks_effective "false"
  fi
  if declare -F runtime_overlay_set_native_hooks_used_on_run >/dev/null 2>&1; then
    runtime_overlay_set_native_hooks_used_on_run "false"
  fi
}

_runtime_overlay_opencode_snapshot_hook_telemetry() {
  OPENCODE_OVERLAY_HOOK_REQUESTED="${RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_REQUESTED:-${RALPH_NATIVE_HOOKS:-unset}}"
  OPENCODE_OVERLAY_HOOK_CONFIGURED="${RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_CONFIGURED:-false}"
  OPENCODE_OVERLAY_HOOK_EFFECTIVE="${RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_EFFECTIVE:-false}"
  OPENCODE_OVERLAY_HOOK_REASON="${RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_REASON:-}"
  OPENCODE_OVERLAY_HOOK_OBSERVED_EFFECT="${RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_OBSERVED_EFFECT:-}"
  OPENCODE_OVERLAY_HOOK_OBSERVED_REASON="${RUNTIME_OVERLAY_SUMMARY_NATIVE_HOOKS_OBSERVED_REASON:-}"
  OPENCODE_OVERLAY_TOOL_ACCESS_MODE="${RUNTIME_OVERLAY_SUMMARY_TOOL_ACCESS_MODE:-}"
  OPENCODE_OVERLAY_MCP_EFFECTIVE="${RUNTIME_OVERLAY_SUMMARY_MCP_EFFECTIVE:-}"
  export OPENCODE_OVERLAY_HOOK_REQUESTED OPENCODE_OVERLAY_HOOK_CONFIGURED OPENCODE_OVERLAY_HOOK_EFFECTIVE
  export OPENCODE_OVERLAY_HOOK_REASON OPENCODE_OVERLAY_HOOK_OBSERVED_EFFECT OPENCODE_OVERLAY_HOOK_OBSERVED_REASON
  export OPENCODE_OVERLAY_TOOL_ACCESS_MODE OPENCODE_OVERLAY_MCP_EFFECTIVE
}

_runtime_overlay_opencode_revalidation_artifact_path() {
  local state_root="${RALPH_PLAN_WORKSPACE_ROOT:-}"
  if [[ -z "$state_root" ]]; then
    local project="${RALPH_PROJECT_ROOT:-${WORKSPACE:-}}"
    if [[ -n "$project" ]]; then
      state_root="${project}/.ralph-workspace"
    fi
  fi
  [[ -n "$state_root" ]] || return 1
  printf '%s/artifacts/PLAN13/opencode-hook-revalidation.md' "$state_root"
}

_runtime_overlay_opencode_headless_mutation_reaches_model() {
  local artifact=""
  artifact="$(_runtime_overlay_opencode_revalidation_artifact_path)" || return 1
  [[ -f "$artifact" ]] || return 1
  grep -qE '^headless_mutation_reaches_model:[[:space:]]*yes[[:space:]]*$' "$artifact"
}

_runtime_overlay_opencode_set_compaction_authoritative() {
  local authoritative="mcp_proxy_compaction"
  if _runtime_overlay_opencode_headless_mutation_reaches_model; then
    authoritative="plugin_hook_compaction"
  fi
  if declare -F runtime_overlay_set_native_shell_compaction_authoritative >/dev/null 2>&1; then
    runtime_overlay_set_native_shell_compaction_authoritative "$authoritative"
  fi
  if [[ "$authoritative" == "mcp_proxy_compaction" ]]; then
    if declare -F runtime_overlay_note_mcp_proxy_channels_proven >/dev/null 2>&1; then
      runtime_overlay_note_mcp_proxy_channels_proven
    fi
    if declare -F runtime_overlay_note_native_result_hook_measured_only >/dev/null 2>&1; then
      runtime_overlay_note_native_result_hook_measured_only
    fi
    if declare -F runtime_overlay_note_mcp_compaction_fallback_authoritative >/dev/null 2>&1; then
      runtime_overlay_note_mcp_compaction_fallback_authoritative
    fi
  else
    if declare -F runtime_overlay_note_native_result_hook_proven >/dev/null 2>&1; then
      runtime_overlay_note_native_result_hook_proven
    fi
  fi
}

_runtime_overlay_opencode_preserve_hook_telemetry() {
  if declare -F runtime_overlay_set_native_hooks_requested >/dev/null 2>&1; then
    runtime_overlay_set_native_hooks_requested "${OPENCODE_OVERLAY_HOOK_REQUESTED:-unset}"
  fi
  if declare -F runtime_overlay_set_native_hooks_configured >/dev/null 2>&1; then
    runtime_overlay_set_native_hooks_configured "${OPENCODE_OVERLAY_HOOK_CONFIGURED:-false}"
  fi
  if declare -F runtime_overlay_set_native_hooks_effective >/dev/null 2>&1; then
    runtime_overlay_set_native_hooks_effective "${OPENCODE_OVERLAY_HOOK_EFFECTIVE:-false}"
  fi
  if [[ -n "${OPENCODE_OVERLAY_HOOK_REASON:-}" ]] \
    && declare -F runtime_overlay_set_native_hooks_reason >/dev/null 2>&1; then
    runtime_overlay_set_native_hooks_reason "$OPENCODE_OVERLAY_HOOK_REASON"
  fi
  if [[ -n "${OPENCODE_OVERLAY_HOOK_OBSERVED_EFFECT:-}" ]] \
    && declare -F runtime_overlay_set_native_hooks_observed_effect >/dev/null 2>&1; then
    runtime_overlay_set_native_hooks_observed_effect "$OPENCODE_OVERLAY_HOOK_OBSERVED_EFFECT"
  fi
  if [[ -n "${OPENCODE_OVERLAY_HOOK_OBSERVED_REASON:-}" ]] \
    && declare -F runtime_overlay_set_native_hooks_observed_reason >/dev/null 2>&1; then
    runtime_overlay_set_native_hooks_observed_reason "$OPENCODE_OVERLAY_HOOK_OBSERVED_REASON"
  fi
  if [[ -n "${OPENCODE_OVERLAY_TOOL_ACCESS_MODE:-}" ]] \
    && declare -F runtime_overlay_set_tool_access_mode >/dev/null 2>&1; then
    runtime_overlay_set_tool_access_mode "$OPENCODE_OVERLAY_TOOL_ACCESS_MODE"
  fi
  if [[ -n "${OPENCODE_OVERLAY_MCP_EFFECTIVE:-}" ]] \
    && declare -F runtime_overlay_set_mcp_effective >/dev/null 2>&1; then
    runtime_overlay_set_mcp_effective "$OPENCODE_OVERLAY_MCP_EFFECTIVE"
  fi
}

run_plan_invoke_opencode_native_hooks_cleanup() {
  _runtime_overlay_opencode_preserve_hook_telemetry
  if [[ -n "${OPENCODE_PLAN_STAGED_PLUGIN_PATH:-}" && -f "$OPENCODE_PLAN_STAGED_PLUGIN_PATH" ]]; then
    rm -f "$OPENCODE_PLAN_STAGED_PLUGIN_PATH"
  fi
  run_plan_invoke_opencode_package_metadata_cleanup || true
  unset OPENCODE_PLAN_NATIVE_HOOKS_ACTIVE OPENCODE_PLAN_STAGED_PLUGIN_PATH
}

run_plan_invoke_opencode_native_hooks_prepare() {
  local requested="${RALPH_NATIVE_HOOKS:-}"
  local tooling_profile="${RALPH_MODE:-}"
  local effective_workspace=""
  local mutation_note="OpenCode plugin loaded from workspace .opencode/plugins/; tool.execute.after output.output mutation is unproven on the headless run path; use MCP compaction (RALPH_PROXY_SHELL_COMPACT=1) for reliable token reduction"
  local tier_selected="" tier_reason=""

  OPENCODE_PLAN_NATIVE_HOOKS_ACTIVE=0
  export OPENCODE_PLAN_NATIVE_HOOKS_ACTIVE

  if declare -F ralph_bg_tier_probe_apply >/dev/null 2>&1 \
    && [[ -z "${RALPH_BG_TIER_SELECTED:-}" ]]; then
    ralph_bg_tier_probe_apply "opencode" >/dev/null || true
  fi
  tier_selected="${RALPH_BG_TIER_SELECTED:-invocation}"
  tier_reason="${RALPH_BG_TIER_REASON:-opencode-session-idle-not-a-turn-gate-client-injection-unproven}"
  export RALPH_BG_TIER_SELECTED="$tier_selected"
  export RALPH_BG_TIER_REASON="$tier_reason"
  if declare -F runtime_overlay_set_bg_tier >/dev/null 2>&1; then
    runtime_overlay_set_bg_tier "$tier_selected"
  fi
  if declare -F runtime_overlay_set_bg_tier_reason >/dev/null 2>&1; then
    runtime_overlay_set_bg_tier_reason "$tier_reason"
  fi
  if [[ "$tier_selected" == "invocation" ]] \
    && declare -F runtime_overlay_add_capability >/dev/null 2>&1; then
    runtime_overlay_add_capability "opencode-bg-tier-invocation-fallback"
  fi

  _runtime_overlay_opencode_record_tool_access_telemetry

  if declare -F runtime_overlay_set_native_hooks_requested >/dev/null 2>&1; then
    runtime_overlay_set_native_hooks_requested "${requested:-unset}"
  fi
  if [[ -n "$tooling_profile" ]] && declare -F runtime_overlay_set_overlay_mode >/dev/null 2>&1; then
    runtime_overlay_set_overlay_mode "$tooling_profile"
  fi

  if ! ralph_native_hooks_want_activation; then
    _runtime_overlay_opencode_record_hook_unconfigured
    _runtime_overlay_opencode_snapshot_hook_telemetry
    return 0
  fi

  case "${RALPH_BASH_COMPACT:-}" in
    1 | true | yes | on)
      if declare -F runtime_overlay_add_warning >/dev/null 2>&1; then
        runtime_overlay_add_warning "RALPH_BASH_COMPACT is ignored for OpenCode native plugin hooks: $mutation_note"
      fi
      ;;
  esac

  if ! effective_workspace="$(_runtime_overlay_opencode_effective_workspace)"; then
    if declare -F runtime_overlay_add_warning >/dev/null 2>&1; then
      runtime_overlay_add_warning "Ralph OpenCode plugin staging requires RALPH_AGENT_WORKSPACE or WORKSPACE to be set"
    fi
    _runtime_overlay_opencode_record_hook_unconfigured
    _runtime_overlay_opencode_snapshot_hook_telemetry
    return 0
  fi

  local plugin_source=""
  if ! plugin_source="$(_runtime_overlay_opencode_plugin_path)"; then
    if declare -F runtime_overlay_add_warning >/dev/null 2>&1; then
      runtime_overlay_add_warning "Ralph OpenCode plugin not found under bundle/.opencode/plugins/"
    fi
    _runtime_overlay_opencode_record_hook_unconfigured
    _runtime_overlay_opencode_snapshot_hook_telemetry
    return 0
  fi

  local staged_plugin_path=""
  if ! staged_plugin_path="$(_run_plan_invoke_opencode_stage_workspace_plugin "$effective_workspace" "$plugin_source")"; then
    if declare -F runtime_overlay_add_warning >/dev/null 2>&1; then
      runtime_overlay_add_warning "Failed to stage Ralph OpenCode plugin to agent workspace .opencode/plugins/"
    fi
    _runtime_overlay_opencode_record_hook_unconfigured
    _runtime_overlay_opencode_snapshot_hook_telemetry
    return 0
  fi

  OPENCODE_PLAN_NATIVE_HOOKS_ACTIVE=1
  OPENCODE_PLAN_STAGED_PLUGIN_PATH="$staged_plugin_path"
  export OPENCODE_PLAN_NATIVE_HOOKS_ACTIVE OPENCODE_PLAN_STAGED_PLUGIN_PATH

  if declare -F runtime_overlay_record_generated_file >/dev/null 2>&1; then
    runtime_overlay_record_generated_file "$staged_plugin_path"
  fi

  _runtime_overlay_opencode_record_hook_configured_not_effective
  if declare -F runtime_overlay_set_native_hooks_reason >/dev/null 2>&1; then
    runtime_overlay_set_native_hooks_reason "plugin_injected_unproven_headless"
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
  _runtime_overlay_opencode_set_compaction_authoritative
  if declare -F runtime_overlay_add_capability >/dev/null 2>&1; then
    runtime_overlay_add_capability "opencode-plugin-local-load"
  fi
  if declare -F runtime_overlay_add_warning >/dev/null 2>&1; then
    runtime_overlay_add_warning "$mutation_note"
  fi
  if declare -F ralph_mcp_overlay_register_runtime_cleanup >/dev/null 2>&1; then
    ralph_mcp_overlay_register_runtime_cleanup run_plan_invoke_opencode_native_hooks_cleanup
  fi
  _runtime_overlay_opencode_snapshot_hook_telemetry
  return 0
}
