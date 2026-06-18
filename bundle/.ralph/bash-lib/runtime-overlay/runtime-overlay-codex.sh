#!/usr/bin/env bash
# Codex native hook overlay: per-run --config hook injection (telemetry and policy only).

if [[ -n "${RALPH_RUNTIME_OVERLAY_CODEX_LOADED:-}" ]]; then
  return
fi
RALPH_RUNTIME_OVERLAY_CODEX_LOADED=1

ralph_native_hooks_want_activation() {
  local mode="${RALPH_NATIVE_HOOKS:-}"
  case "$mode" in
    off) return 1 ;;
    on|auto) return 0 ;;
    *) return 1 ;;
  esac
}

_runtime_overlay_codex_lib_dir() {
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

_runtime_overlay_codex_bundle_root() {
  local lib_dir
  lib_dir="$(_runtime_overlay_codex_lib_dir)"
  cd "$lib_dir/../../.." && pwd
}

_runtime_overlay_codex_hooks_dir() {
  local bundle_root
  bundle_root="$(_runtime_overlay_codex_bundle_root)"
  printf '%s/.codex/hooks' "$bundle_root"
}

_RUN_PLAN_INVOKE_CODEX_HOOKS_CONFIG_SUPPORTED_CACHE=""

_run_plan_invoke_codex_hooks_config_supported() {
  local cli_name="${1:-${CODEX_PLAN_CLI:-codex}}"
  if [[ -n "${_RUN_PLAN_INVOKE_CODEX_HOOKS_CONFIG_SUPPORTED_CACHE:-}" ]]; then
    [[ "${_RUN_PLAN_INVOKE_CODEX_HOOKS_CONFIG_SUPPORTED_CACHE}" == "1" ]]
    return
  fi

  if ! command -v "$cli_name" &>/dev/null; then
    _RUN_PLAN_INVOKE_CODEX_HOOKS_CONFIG_SUPPORTED_CACHE=0
    return 1
  fi

  local exec_help stderr_file probe_status=0
  if ! exec_help="$("$cli_name" exec --help 2>/dev/null)"; then
    _RUN_PLAN_INVOKE_CODEX_HOOKS_CONFIG_SUPPORTED_CACHE=0
    return 1
  fi
  if [[ "$exec_help" != *"--config"* ]]; then
    _RUN_PLAN_INVOKE_CODEX_HOOKS_CONFIG_SUPPORTED_CACHE=0
    return 1
  fi
  if [[ "$exec_help" != *"--dangerously-bypass-hook-trust"* ]]; then
    _RUN_PLAN_INVOKE_CODEX_HOOKS_CONFIG_SUPPORTED_CACHE=0
    return 1
  fi

  stderr_file="$(mktemp "${TMPDIR:-/tmp}/ralph-codex-hooks-probe.XXXXXX")"
  "$cli_name" exec \
    --config 'features.hooks=true' \
    --config 'hooks.PostToolUse=[]' \
    >/dev/null 2>"$stderr_file" <<< "" || probe_status=$?
  if [[ "$probe_status" -ne 0 ]] && grep -qE 'unknown configuration field|Error parsing -c overrides|missing field' "$stderr_file" 2>/dev/null; then
    rm -f "$stderr_file"
    _RUN_PLAN_INVOKE_CODEX_HOOKS_CONFIG_SUPPORTED_CACHE=0
    return 1
  fi
  rm -f "$stderr_file"
  _RUN_PLAN_INVOKE_CODEX_HOOKS_CONFIG_SUPPORTED_CACHE=1
  return 0
}

_run_plan_invoke_codex_build_post_tool_use_toml() {
  local telemetry_cmd="$1" native_result_cmd="$2"
  local bash_groups exploration_group inner
  bash_groups="$(_run_plan_invoke_codex_build_shell_hook_groups_toml "$telemetry_cmd")"
  exploration_group="$(_run_plan_invoke_codex_build_hook_group_toml '^read_file$|^grep$|^Glob$|^Read$|^Grep$' "$native_result_cmd")"
  inner="${bash_groups:1:-1},${exploration_group:1:-1}"
  printf '[%s]' "$inner"
}

_run_plan_invoke_codex_native_hook_paths() {
  local hooks_dir pre_cmd post_telemetry_cmd post_native_cmd probe_enabled
  hooks_dir="$(_runtime_overlay_codex_hooks_dir)"
  pre_cmd="${hooks_dir}/pre-tool-bash-policy.sh"
  post_telemetry_cmd="${hooks_dir}/post-tool-bash-telemetry.sh"
  post_native_cmd="${hooks_dir}/post-tool-native-result-compact.sh"

  probe_enabled="${RALPH_CODEX_POST_TOOL_PROBE:-0}"
  if [[ "$probe_enabled" == "1" ]]; then
    local probe_cmd
    probe_cmd="${hooks_dir}/post-tool-bash-mutation-probe.sh"
    if [[ -x "$probe_cmd" ]]; then
      post_telemetry_cmd="$probe_cmd"
    fi
  fi

  if [[ ! -x "$pre_cmd" || ! -x "$post_telemetry_cmd" || ! -x "$post_native_cmd" ]]; then
    return 1
  fi
  printf '%s\t%s\t%s\n' "$pre_cmd" "$post_telemetry_cmd" "$post_native_cmd"
}

_run_plan_invoke_codex_build_hook_group_toml() {
  local matcher="$1"
  local command_path="$2"
  local escaped
  escaped="$(_run_plan_invoke_codex_toml_escape "$command_path")"
  printf '[{matcher="%s",hooks=[{type="command",command="%s",timeout=30}]}]' "$matcher" "$escaped"
}

_run_plan_invoke_codex_build_shell_hook_groups_toml() {
  local command_path="$1"
  local bash_group command_execution_group
  bash_group="$(_run_plan_invoke_codex_build_hook_group_toml '^Bash$' "$command_path")"
  command_execution_group="$(_run_plan_invoke_codex_build_hook_group_toml '^command_execution$' "$command_path")"
  printf '[%s,%s]' "${bash_group:1:-1}" "${command_execution_group:1:-1}"
}

_run_plan_invoke_codex_append_native_hook_config_args() {
  local args_name="$1"
  local paths pre_cmd post_telemetry_cmd post_native_cmd pre_group post_group

  paths="$(_run_plan_invoke_codex_native_hook_paths)" || return 1
  pre_cmd="${paths%%$'\t'*}"
  paths="${paths#*$'\t'}"
  post_telemetry_cmd="${paths%%$'\t'*}"
  post_native_cmd="${paths#*$'\t'}"

  pre_group="$(_run_plan_invoke_codex_build_shell_hook_groups_toml "$pre_cmd")"
  post_group="$(_run_plan_invoke_codex_build_post_tool_use_toml "$post_telemetry_cmd" "$post_native_cmd")"

  _run_plan_invoke_codex_append_config "$args_name" 'features.hooks=true'
  _run_plan_invoke_codex_append_config "$args_name" "hooks.PreToolUse=$pre_group"
  _run_plan_invoke_codex_append_config "$args_name" "hooks.PostToolUse=$post_group"
}

run_plan_invoke_codex_native_hooks_cleanup() {
  unset CODEX_PLAN_NATIVE_HOOKS_ACTIVE CODEX_PLAN_NATIVE_HOOKS_BYPASS_TRUST
}

run_plan_invoke_codex_native_hooks_prepare() {
  local requested="${RALPH_NATIVE_HOOKS:-}"
  local overlay_mode="${RALPH_OPTIMIZATION_MODE:-}"
  local cli_name="${CODEX_PLAN_CLI:-${CODEX_CLI:-codex}}"
  local wrapper_enabled="${RALPH_NATIVE_SHELL_WRAPPER:-}"

  CODEX_PLAN_NATIVE_HOOKS_ACTIVE=0
  CODEX_PLAN_NATIVE_HOOKS_BYPASS_TRUST=0
  export CODEX_PLAN_NATIVE_HOOKS_ACTIVE CODEX_PLAN_NATIVE_HOOKS_BYPASS_TRUST

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

  if ! _run_plan_invoke_codex_hooks_config_supported "$cli_name"; then
    local unsupported_reason="Codex CLI does not support per-run hook injection via --config (missing --config, --dangerously-bypass-hook-trust, or hooks.* overrides)"
    if declare -F runtime_overlay_add_warning >/dev/null 2>&1; then
      runtime_overlay_add_warning "$unsupported_reason"
    fi
    if declare -F runtime_overlay_set_native_hooks_effective >/dev/null 2>&1; then
      runtime_overlay_set_native_hooks_effective "false"
    fi
    if declare -F runtime_overlay_add_capability >/dev/null 2>&1; then
      runtime_overlay_add_capability "codex-hooks-config-unsupported"
    fi
    return 0
  fi

  if ! _run_plan_invoke_codex_native_hook_paths >/dev/null; then
    if declare -F runtime_overlay_add_warning >/dev/null 2>&1; then
      runtime_overlay_add_warning "Ralph Codex hook scripts are missing or not executable under bundle/.codex/hooks/"
    fi
    if declare -F runtime_overlay_set_native_hooks_effective >/dev/null 2>&1; then
      runtime_overlay_set_native_hooks_effective "false"
    fi
    return 0
  fi

  CODEX_PLAN_NATIVE_HOOKS_ACTIVE=1
  CODEX_PLAN_NATIVE_HOOKS_BYPASS_TRUST=1
  export CODEX_PLAN_NATIVE_HOOKS_ACTIVE CODEX_PLAN_NATIVE_HOOKS_BYPASS_TRUST

  if [[ -z "$wrapper_enabled" ]] || [[ "$wrapper_enabled" != "0" ]]; then
    export RALPH_NATIVE_SHELL_WRAPPER=1
  fi

  if declare -F runtime_overlay_set_native_hooks_configured >/dev/null 2>&1; then
    runtime_overlay_set_native_hooks_configured "true"
  fi
  if declare -F runtime_overlay_set_native_hooks_effective >/dev/null 2>&1; then
    runtime_overlay_set_native_hooks_effective "true"
  fi
  if declare -F runtime_overlay_set_native_hooks_reason >/dev/null 2>&1; then
    runtime_overlay_set_native_hooks_reason "wrapper_based_native_shell_compaction"
  fi
  if declare -F runtime_overlay_set_native_output_mutation_proven >/dev/null 2>&1; then
    runtime_overlay_set_native_output_mutation_proven "false"
  fi
  if [[ "${RALPH_NATIVE_SHELL_WRAPPER:-0}" != "0" ]]; then
    if declare -F runtime_overlay_set_native_shell_wrapper_enabled >/dev/null 2>&1; then
      runtime_overlay_set_native_shell_wrapper_enabled "true"
    fi
    if declare -F runtime_overlay_set_native_shell_wrapper_effective >/dev/null 2>&1; then
      runtime_overlay_set_native_shell_wrapper_effective "true"
    fi
    if declare -F runtime_overlay_set_native_shell_wrapper_reason >/dev/null 2>&1; then
      runtime_overlay_set_native_shell_wrapper_reason "preToolUse_wrapper_rewrite"
    fi
    if declare -F runtime_overlay_set_native_shell_compaction_authoritative >/dev/null 2>&1; then
      runtime_overlay_set_native_shell_compaction_authoritative "wrapper_based_native_shell_compaction"
    fi
  else
    if declare -F runtime_overlay_set_native_shell_wrapper_enabled >/dev/null 2>&1; then
      runtime_overlay_set_native_shell_wrapper_enabled "false"
    fi
    if declare -F runtime_overlay_set_native_shell_wrapper_effective >/dev/null 2>&1; then
      runtime_overlay_set_native_shell_wrapper_effective "false"
    fi
  fi
  if declare -F runtime_overlay_add_capability >/dev/null 2>&1; then
    runtime_overlay_add_capability "codex-hooks-injected-per-run"
    runtime_overlay_add_capability "codex-native-result-hook-compact"
    if [[ "${RALPH_NATIVE_SHELL_WRAPPER:-0}" != "0" ]]; then
      runtime_overlay_add_capability "codex-native-shell-wrapper-compact"
    fi
  fi
  if declare -F runtime_overlay_note_mcp_compaction_fallback_authoritative >/dev/null 2>&1; then
    runtime_overlay_note_mcp_compaction_fallback_authoritative
  fi
  if declare -F ralph_mcp_overlay_register_runtime_cleanup >/dev/null 2>&1; then
    ralph_mcp_overlay_register_runtime_cleanup run_plan_invoke_codex_native_hooks_cleanup
  fi
  return 0
}
