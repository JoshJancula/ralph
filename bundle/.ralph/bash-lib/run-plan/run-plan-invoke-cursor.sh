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
#   run_plan_invoke_cursor_mcp_config_prepare / run_plan_invoke_cursor_mcp_config_cleanup -- per-run workspace MCP overlay.
#   ralph_run_plan_invoke_cursor -- invoke Cursor CLI; exports OUTPUT_LOG, EXIT_CODE_FILE, SESSION_ID_FILE for demux.
#
# MCP overlay behavior:
#   Cursor natively discovers .cursor/mcp.json, rules, skills, hooks, and settings from the
#   project root. The overlay writes the effective MCP catalog (ambient user/project servers
#   merged with selected-agent references/definitions and Ralph's protected server) into the
#   workspace .cursor/mcp.json for the run, then restores the byte-exact original (or removes a
#   newly created file) on every cleanup path. When the shared runtime-config resolver has
#   already produced RALPH_RUNTIME_MCP_RESOLVE_PATH, that catalog is authoritative and the
#   Ralph-only generator is skipped. --workspace, --trust, and --approve-mcps are added only
#   when an overlay or native-hook overlay is actually applied for the run.

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
  local fragment_path="" backup_path=""

  if [[ -z "$workspace" ]]; then
    echo "Error: WORKSPACE is required for Cursor MCP overlay." >&2
    return 1
  fi

  if ! command -v jq &>/dev/null; then
    echo "Error: jq is required for the Cursor MCP overlay." >&2
    return 1
  fi

  target="$workspace/.cursor/mcp.json"
  mkdir -p "$(dirname "$target")"

  # Validate an existing project MCP file before mutating it; fail closed on invalid JSON.
  if [[ -f "$target" ]]; then
    had_file=1
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

  # Prefer the shared effective catalog (ambient user/project + agent overrides + Ralph)
  # when the runtime-config resolver has produced it; otherwise fall back to the
  # Ralph-only generator so ralph/hybrid mode keeps working without the resolver.
  local resolve_path="${RALPH_RUNTIME_MCP_RESOLVE_PATH:-}"
  if [[ -z "$resolve_path" || ! -f "$resolve_path" ]]; then
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
    resolve_path="$fragment_path"
  fi

  if [[ "$had_file" == "1" ]]; then
    # Replace the project MCP servers with the effective catalog while preserving any
    # unrelated keys already present in the file (cursor rules, skills, settings, etc.).
    if ! jq --slurpfile ralph "$resolve_path" \
      '.mcpServers = ((.mcpServers // {}) * $ralph[0].mcpServers)' \
      "$target" > "${target}.ralph.tmp" 2>/dev/null; then
      ralph_mcp_cleanup_config "$fragment_path" 2>/dev/null || true
      echo "Error: failed to merge effective MCP overlay into $target" >&2
      return 1
    fi
    mv "${target}.ralph.tmp" "$target"
  else
    if ! cp "$resolve_path" "$target" 2>/dev/null; then
      ralph_mcp_cleanup_config "$fragment_path" 2>/dev/null || true
      echo "Error: failed to write Cursor MCP overlay to $target" >&2
      return 1
    fi
    ralph_mcp_overlay_record_workspace_mutation "$target" 0
  fi
  ralph_mcp_cleanup_config "$fragment_path" 2>/dev/null || true

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
  run_plan_invoke_common_add_reasoning_effort_flag args cursor "${CURSOR_PLAN_CLI:-cursor-agent}"
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

  # Determine whether a per-run MCP overlay is required. The shared runtime-config
  # resolver may have produced RALPH_RUNTIME_MCP_RESOLVE_PATH (ambient + agent + Ralph),
  # or ralph/hybrid mode may need the Ralph-only generator. An agent with mcp_servers but
  # no Ralph mode still requires the overlay so agent definitions/references are applied.
  local _ralph_mode="${RALPH_MODE:-no}"
  local _ralph_active=0
  if [[ "$_ralph_mode" == "ralph" || "$_ralph_mode" == "hybrid" || "${RALPH_AGENT_TOOL_ACCESS:-}" == "ralph" ]]; then
    _ralph_active=1
  fi
  local _agent_mcp_present=0
  if [[ -n "${RALPH_RUNTIME_MCP_AGENT_ENTRIES_JSON:-}" && "${RALPH_RUNTIME_MCP_AGENT_ENTRIES_JSON}" != "[]" ]]; then
    _agent_mcp_present=1
  fi
  local _mcp_overlay_required=0
  if [[ "$_ralph_active" == "1" || "$_agent_mcp_present" == "1" ]]; then
    _mcp_overlay_required=1
  fi
  if [[ -n "${RALPH_RUNTIME_MCP_RESOLVE_PATH:-}" && -f "$RALPH_RUNTIME_MCP_RESOLVE_PATH" ]]; then
    _mcp_overlay_required=1
  fi

  local _mcp_overlay_applied=0
  if [[ "$_mcp_overlay_required" == "1" ]]; then
    if ! run_plan_invoke_cursor_mcp_config_prepare; then
      run_plan_invoke_cursor_native_hooks_cleanup
      return 1
    fi
    _mcp_overlay_applied=1
    if declare -F runtime_overlay_set_mcp_effective >/dev/null 2>&1; then
      runtime_overlay_set_mcp_effective "true"
    fi
  elif declare -F runtime_overlay_set_mcp_effective >/dev/null 2>&1; then
    runtime_overlay_set_mcp_effective "false"
  fi

  # --workspace, --trust, and --approve-mcps are added only when an overlay (MCP or
  # native hooks) is actually applied for the run, so native runs without Ralph stay
  # untouched and Cursor's ambient discovery is preserved.
  local agent_workspace="${RALPH_AGENT_WORKSPACE:-${WORKSPACE:-}}"
  if [[ -n "$agent_workspace" ]] \
    && { [[ "$_mcp_overlay_applied" == "1" ]] \
      || [[ "${CURSOR_PLAN_NATIVE_HOOKS_ACTIVE:-0}" == "1" ]]; }; then
    args+=(--workspace "$agent_workspace")
  fi
  if [[ "${CURSOR_PLAN_NATIVE_HOOKS_ACTIVE:-0}" == "1" ]]; then
    args+=(--trust)
  fi
  if [[ "$_mcp_overlay_applied" == "1" ]]; then
    args+=(--approve-mcps)
  fi

  args+=("$PROMPT")

  run_plan_invoke_cursor_cli() {
    local cli_pid
    "$cli" "${args[@]}" &
    cli_pid=$!
    run_plan_invoke_common_record_cli_pid "$cli_pid"
    wait "$cli_pid"
  }

  local invoke_status=0
  run_plan_invoke_common_execute \
    run_plan_invoke_cursor_cli \
    cursor \
    "Warning: RALPH_PLAN_CLI_RESUME needs python3 to parse JSON and update session-id.cursor.txt; running without it." \
    || invoke_status=$?

  # Restore the original MCP file (or remove a newly created overlay) on every exit path
  # including success, CLI failure, and timeouts. The registered runtime cleanup runs on
  # signal/exit; this explicit call covers the normal return path when an overlay was applied.
  if [[ "$_mcp_overlay_applied" == "1" ]]; then
    run_plan_invoke_cursor_mcp_config_cleanup
  fi
  run_plan_invoke_cursor_native_hooks_cleanup

  if declare -F runtime_overlay_write_summary >/dev/null 2>&1; then
    runtime_overlay_write_summary || true
  fi

  return "$invoke_status"
}
