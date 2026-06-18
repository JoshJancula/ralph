#!/usr/bin/env bash

if [[ -n "${RALPH_RUN_PLAN_INVOKE_CURSOR_LOADED:-}" ]]; then
  return
fi
RALPH_RUN_PLAN_INVOKE_CURSOR_LOADED=1

_run_plan_invoke_cursor_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_run_plan_invoke_cursor_dir/run-plan-cli-helpers.sh"
# shellcheck source=/dev/null
source "$_run_plan_invoke_cursor_dir/run-plan-invoke-common.sh"
# shellcheck source=/dev/null
source "$_run_plan_invoke_cursor_dir/../mcp/mcp-setup.sh"
# shellcheck source=/dev/null
source "$_run_plan_invoke_cursor_dir/../runtime-overlay/runtime-overlay-cursor.sh"
unset _run_plan_invoke_cursor_dir

# Public interface:
#   run_plan_invoke_cursor_session_resume_args / run_plan_invoke_cursor_bare_resume_args -- argv helpers for resume.
#   run_plan_invoke_cursor_bare_resume_warn -- stderr when bare resume is disallowed.
#   run_plan_invoke_cursor_native_hooks_prepare / run_plan_invoke_cursor_native_hooks_cleanup -- workspace hooks.json overlay.
#   run_plan_invoke_cursor_mcp_config_prepare / run_plan_invoke_cursor_mcp_config_cleanup -- ralph-mode workspace MCP config.
#   ralph_run_plan_invoke_cursor -- invoke Cursor CLI; exports OUTPUT_LOG, EXIT_CODE_FILE, SESSION_ID_FILE for demux.

run_plan_invoke_cursor_session_resume_args() {
  local args_name="$1"
  eval "$args_name+=(--resume \"\${RALPH_RUN_PLAN_RESUME_SESSION_ID}\")"
}

run_plan_invoke_cursor_session_new_args() {
  :
}

run_plan_invoke_cursor_bare_resume_args() {
  local args_name="$1"
  eval "$args_name+=(--resume --continue)"
}

run_plan_invoke_cursor_bare_resume_warn() {
  echo "Warning: resume without a session id requires RALPH_PLAN_ALLOW_UNSAFE_RESUME=1 or --allow-unsafe-resume; omitting bare --resume." >&2
}

run_plan_invoke_cursor_mcp_config_cleanup() {
  local target="${CURSOR_PLAN_MCP_CONFIG_TARGET:-}"
  if [[ -z "$target" ]]; then
    return 0
  fi

  if [[ "${CURSOR_PLAN_MCP_CONFIG_HAD_FILE:-0}" == "1" ]]; then
    if [[ -n "${CURSOR_PLAN_MCP_CONFIG_BACKUP:-}" && -f "$CURSOR_PLAN_MCP_CONFIG_BACKUP" ]]; then
      cp "$CURSOR_PLAN_MCP_CONFIG_BACKUP" "$target" 2>/dev/null || true
      if ! ralph_mcp_overlay_lifecycle_available; then
        rm -f "$CURSOR_PLAN_MCP_CONFIG_BACKUP" 2>/dev/null || true
      fi
    fi
  else
    rm -f "$target" 2>/dev/null || true
  fi

  unset CURSOR_PLAN_MCP_CONFIG_TARGET
  unset CURSOR_PLAN_MCP_CONFIG_BACKUP
  unset CURSOR_PLAN_MCP_CONFIG_HAD_FILE
}

run_plan_invoke_cursor_mcp_config_prepare() {
  local workspace="${WORKSPACE:-}"
  local target had_file=0
  local fragment_path backup_path=""

  if [[ -z "$workspace" ]]; then
    echo "Error: WORKSPACE is required for Cursor Ralph MCP config injection." >&2
    return 1
  fi

  target="$workspace/.cursor/mcp.json"
  mkdir -p "$(dirname "$target")"

  if [[ -f "$target" ]]; then
    had_file=1
    if ! command -v jq &>/dev/null; then
      echo "Error: jq is required to validate an existing Cursor MCP config in ralph mode." >&2
      return 1
    fi
    if ! jq empty "$target" >/dev/null 2>&1; then
      echo "Error: existing Cursor MCP config is invalid JSON: $target" >&2
      return 1
    fi
    if ralph_mcp_overlay_lifecycle_available; then
      runtime_overlay_record_original_file "$target" backup_path
      CURSOR_PLAN_MCP_CONFIG_BACKUP="$backup_path"
    else
      CURSOR_PLAN_MCP_CONFIG_BACKUP="$(mktemp "${TMPDIR:-/tmp}/ralph-cursor-mcp-backup-XXXXXX")"
      cp "$target" "$CURSOR_PLAN_MCP_CONFIG_BACKUP"
    fi
  fi

  fragment_path="$(mktemp "${TMPDIR:-/tmp}/ralph-cursor-mcp-fragment-XXXXXX")"
  if ! ralph_mcp_generate_config cursor "$fragment_path" "$workspace"; then
    ralph_mcp_cleanup_config "$fragment_path"
    if [[ "$had_file" == "1" && -n "${CURSOR_PLAN_MCP_CONFIG_BACKUP:-}" && -f "$CURSOR_PLAN_MCP_CONFIG_BACKUP" ]] \
      && ! ralph_mcp_overlay_lifecycle_available; then
      rm -f "$CURSOR_PLAN_MCP_CONFIG_BACKUP"
    fi
    return 1
  fi
  ralph_mcp_overlay_record_temp_file "$fragment_path"

  if [[ "$had_file" == "1" ]]; then
    if ! jq --slurpfile ralph "$fragment_path" \
      '.mcpServers = ((.mcpServers // {}) + $ralph[0].mcpServers)' \
      "$target" > "${target}.ralph.tmp" 2>/dev/null; then
      ralph_mcp_cleanup_config "$fragment_path"
      echo "Error: failed to merge Ralph MCP config into $target" >&2
      return 1
    fi
    mv "${target}.ralph.tmp" "$target"
  else
    if ! cp "$fragment_path" "$target" 2>/dev/null; then
      ralph_mcp_cleanup_config "$fragment_path"
      echo "Error: failed to write Cursor MCP config to $target" >&2
      return 1
    fi
    ralph_mcp_overlay_record_workspace_mutation "$target" 0
  fi
  ralph_mcp_cleanup_config "$fragment_path"

  CURSOR_PLAN_MCP_CONFIG_TARGET="$target"
  CURSOR_PLAN_MCP_CONFIG_HAD_FILE="$had_file"
  export CURSOR_PLAN_MCP_CONFIG_TARGET CURSOR_PLAN_MCP_CONFIG_HAD_FILE
  [[ -n "${CURSOR_PLAN_MCP_CONFIG_BACKUP:-}" ]] && export CURSOR_PLAN_MCP_CONFIG_BACKUP

  ralph_mcp_overlay_register_runtime_cleanup run_plan_invoke_cursor_mcp_config_cleanup
  return 0
}

ralph_run_plan_invoke_cursor() {
  ralph_run_plan_sync_mode_knobs
  # Log path, exit-code sidecar, and session-id file for JSON demux and resume capture.
  export OUTPUT_LOG EXIT_CODE_FILE SESSION_ID_FILE

  local cli=""
  if ! cli="$(ralph_resolve_cursor_cli)"; then
    echo "Error: Cursor CLI not found (cursor-agent or agent missing from PATH)." >&2
    return 1
  fi

  # shellcheck disable=SC2034
  CURSOR_CLI="$cli"

  local -a args=(-p --force)
  run_plan_invoke_common_add_model_flag args --model
  run_plan_invoke_common_add_resume_args \
    args \
    run_plan_invoke_cursor_session_resume_args \
    run_plan_invoke_cursor_session_new_args \
    run_plan_invoke_cursor_bare_resume_args \
    run_plan_invoke_cursor_bare_resume_warn

  local cursor_output_format="${CURSOR_PLAN_OUTPUT_FORMAT:-stream-json}"
  case "$cursor_output_format" in
    json|stream-json) ;;
    *)
      echo "Error: CURSOR_PLAN_OUTPUT_FORMAT must be one of json or stream-json." >&2
      return 1
      ;;
  esac
  run_plan_invoke_common_add_cli_resume_flags args --output-format "$cursor_output_format"

  run_plan_invoke_cursor_native_hooks_prepare

  # Check RALPH_MODE and RALPH_AGENT_TOOL_ACCESS for injection behavior
  local _ralph_mode="${RALPH_MODE:-no}"
  if [[ "$_ralph_mode" == "ralph" || "$_ralph_mode" == "hybrid" || "${RALPH_AGENT_TOOL_ACCESS:-}" == "ralph" ]]; then
    if ! run_plan_invoke_cursor_mcp_config_prepare; then
      return 1
    fi
    if declare -F runtime_overlay_set_mcp_effective >/dev/null 2>&1; then
      runtime_overlay_set_mcp_effective "true"
    fi
    args+=(--approve-mcps)
  elif declare -F runtime_overlay_set_mcp_effective >/dev/null 2>&1; then
    runtime_overlay_set_mcp_effective "false"
  fi

  local agent_workspace="${RALPH_AGENT_WORKSPACE:-${WORKSPACE:-}}"
  local _ralph_active=0
  if [[ "$_ralph_mode" == "ralph" || "$_ralph_mode" == "hybrid" || "${RALPH_AGENT_TOOL_ACCESS:-}" == "ralph" ]]; then
    _ralph_active=1
  fi
  if [[ -n "$agent_workspace" ]] \
    && { [[ "$_ralph_active" == "1" ]] \
      || [[ "${CURSOR_PLAN_NATIVE_HOOKS_ACTIVE:-0}" == "1" ]]; }; then
    args+=(--workspace "$agent_workspace")
  fi
  if [[ "${CURSOR_PLAN_NATIVE_HOOKS_ACTIVE:-0}" == "1" ]]; then
    args+=(--trust)
  fi

  args+=("$PROMPT")

  run_plan_invoke_cursor_cli() {
    "$cli" "${args[@]}"
  }

  local invoke_status=0
  run_plan_invoke_common_execute \
    run_plan_invoke_cursor_cli \
    cursor \
    "Warning: RALPH_PLAN_CLI_RESUME needs python3 to parse JSON and update session-id.cursor.txt; running without it." \
    || invoke_status=$?

  if [[ "$_ralph_mode" == "ralph" || "$_ralph_mode" == "hybrid" ]]; then
    run_plan_invoke_cursor_mcp_config_cleanup
  fi
  run_plan_invoke_cursor_native_hooks_cleanup

  if declare -F runtime_overlay_write_summary >/dev/null 2>&1; then
    runtime_overlay_write_summary || true
  fi

  return "$invoke_status"
}
