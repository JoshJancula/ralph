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
#   run_plan_invoke_cursor_native_subagents_preflight -- fail closed when nativeSubagents=off lacks a proven deny.
#   run_plan_invoke_cursor_graph_approval_live_supported -- graph help-only live-channel proof (no model call).
#   run_plan_invoke_cursor_graph_approval_capabilities -- advertise only enforceable Cursor lifetimes.
#   run_plan_invoke_cursor_graph_approval_parse_permission -- elevate a fake-adapter event into the G15 contract.
#   run_plan_invoke_cursor_graph_approval_apply / restore -- common resumable overlay fallback.
#   run_plan_invoke_cursor_graph_approval_start_or_fallback -- live path only after nonbillable proof.
#
# MCP overlay behavior:
#   Cursor natively discovers .cursor/mcp.json, rules, skills, hooks, and settings from the
#   project root, and it loads ~/.cursor/mcp.json at the same time as the project file. The
#   overlay writes into the workspace .cursor/mcp.json for the run, then restores the
#   byte-exact original (or removes a newly created file) on every cleanup path. Under a Ralph
#   profile with no selected-agent MCP overrides, only Ralph's own server is layered on top of
#   the project file so ambient user-level servers keep being discovered natively. When an
#   agent declares mcp_servers overrides, the shared runtime-config resolver's effective
#   catalog (RALPH_RUNTIME_MCP_RESOLVE_PATH) is authoritative because Cursor has no
#   invocation-local mechanism for that case; the choice is recorded in
#   RUNTIME_OVERLAY_SUMMARY_MCP_OVERRIDE_DECISIONS. --workspace, --trust, and --approve-mcps are added only
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

  # Ambient-MCP boundary rule. Proven mechanism: the Cursor CLI has no
  # invocation-local MCP config flag (`cursor-agent --help` exposes only
  # `--approve-mcps`; `cursor-agent mcp login` documents the sources as
  # ".cursor/mcp.json or ~/.cursor/mcp.json"), and `cursor-agent mcp list` run
  # against an isolated HOME reports BOTH the user-level and the project-level
  # server at the same time. Native discovery of ~/.cursor/mcp.json therefore
  # survives a project-root overlay, so a Ralph profile must layer only Ralph's
  # own server onto the project file instead of re-emitting a reconstructed copy
  # of every ambient server (a lossy snapshot that can drop fields the shared
  # JSON catalog shape does not carry).
  #
  # The one class of ambient state native layering cannot preserve is a
  # selected-agent `mcp_servers` override that must win over an ambient entry of
  # the same name: Cursor has no per-invocation mechanism to express that, so the
  # safest current merge (the reconstructed effective catalog) is retained for
  # that case and the limitation is recorded in
  # RUNTIME_OVERLAY_SUMMARY_MCP_OVERRIDE_DECISIONS rather than left silent.
  # Non-Ralph (raw) runs keep their existing behavior untouched.
  local _cursor_agent_mcp_present=0
  if [[ -n "${RALPH_RUNTIME_MCP_AGENT_ENTRIES_JSON:-}" && "${RALPH_RUNTIME_MCP_AGENT_ENTRIES_JSON}" != "[]" ]]; then
    _cursor_agent_mcp_present=1
  fi
  local _cursor_ralph_profile=0
  if [[ "${RALPH_MODE:-no}" == "ralph" || "${RALPH_MODE:-no}" == "hybrid" \
    || "${RALPH_AGENT_TOOL_ACCESS:-}" == "ralph" ]]; then
    _cursor_ralph_profile=1
  fi

  # Prefer the shared effective catalog (ambient user/project + agent overrides + Ralph)
  # when the runtime-config resolver has produced it and native layering cannot express
  # the run's requirements; otherwise use the Ralph-only generator so a Ralph profile
  # layers Ralph on top of natively discovered ambient servers.
  local resolve_path="${RALPH_RUNTIME_MCP_RESOLVE_PATH:-}"
  local overlay_decision=""
  if [[ "$_cursor_ralph_profile" == "1" && "$_cursor_agent_mcp_present" != "1" ]]; then
    # Native layering: Ralph's own server only, on top of ambient discovery.
    resolve_path=""
  fi
  if [[ -z "$resolve_path" || ! -f "$resolve_path" ]]; then
    if [[ "$_cursor_ralph_profile" == "1" ]]; then
      overlay_decision="profile_ralph_layered_native_project_mcp_json"
    else
      overlay_decision="profile_raw_ralph_only_fallback"
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
    resolve_path="$fragment_path"
  elif [[ "$_cursor_agent_mcp_present" == "1" ]]; then
    if [[ "$_cursor_ralph_profile" == "1" ]]; then
      overlay_decision="profile_ralph_agent_overrides_reconstructed_catalog"
    else
      overlay_decision="profile_raw_agent_overrides_reconstructed_catalog"
    fi
  else
    overlay_decision="profile_raw_reconstructed_catalog"
  fi

  CURSOR_PLAN_MCP_OVERLAY_DECISION="$overlay_decision"
  export CURSOR_PLAN_MCP_OVERLAY_DECISION
  if declare -F runtime_overlay_set_mcp_override_decisions >/dev/null 2>&1; then
    runtime_overlay_set_mcp_override_decisions "$overlay_decision"
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

# run_plan_invoke_cursor_native_subagents_preflight
# nativeSubagents=off requires a proven deny boundary. Cursor has none (capability
# nativeSubagentsOffDeny=unsupported), so graph/orchestration/standard off fails
# closed before argv or model invocation. inherit preserves ambient behavior.
# Never uses prompt-only suppression.
run_plan_invoke_cursor_native_subagents_preflight() {
  local mode

  mode="$(ralph_run_plan_native_subagents_mode)" || return 1
  [[ "$mode" == "off" ]] || return 0

  if ! declare -F graph_runtime_native_subagents_off_supported >/dev/null 2>&1; then
    # shellcheck source=../graph/graph-runtime-capabilities.sh
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../graph" && pwd)/graph-runtime-capabilities.sh"
  fi

  if graph_runtime_native_subagents_off_supported cursor; then
    # Future: apply the proven deny argv/config here. Cursor has none today.
    return 0
  fi

  echo "Error: nativeSubagents=off is unsupported for runtime cursor (no proven deny boundary); refusing to invoke (use nativeSubagents=inherit)." >&2
  return 1
}

ralph_run_plan_invoke_cursor() {
  ralph_run_plan_sync_mode_knobs
  ralph_run_plan_subagents_log_contract cursor || return 1
  ralph_run_plan_subagents_require_runtime_capability cursor || return 1
  ralph_run_plan_native_subagent_verify_runtime cursor || return 1

  # nativeSubagents=off: Cursor capability is unsupported; fail before CLI argv.
  # inherit: skip; do not alter ambient native-subagent availability.
  if ! run_plan_invoke_cursor_native_subagents_preflight; then
    return 1
  fi

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
    run_plan_invoke_common_launch_cli cursor "$cli" "${args[@]}"
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

# Graph-only Cursor approval transport.
# A live structured channel is used only after nonbillable `--help` proof of
# `--permission-prompt-tool`. --force, --yolo, --auto-review, and --approve-mcps
# are not a same-operation response protocol. Otherwise the common resumable
# overlay writes project `.cursor/cli.json` only. Advertised lifetimes are only
# those enforceable without ambient user writes: once and run. always-policy is
# Ralph project policy reapplied through future temporary overlays, never a
# native Cursor lifetime and never `~/.cursor/cli-config.json`.
# Normal non-graph `ralph_run_plan_invoke_cursor` does not call these helpers.

run_plan_invoke_cursor_graph_approval_graph_enabled() {
  case "${RALPH_GRAPH_APPROVAL:-}" in
    1|true|yes|on)
      return 0
      ;;
  esac
  [[ -n "${RALPH_GRAPH_NODE_ID:-}" ]]
}

_run_plan_invoke_cursor_graph_approval_ensure_adapter() {
  if declare -F ralph_approval_adapter_capabilities >/dev/null 2>&1; then
    return 0
  fi
  # shellcheck source=/dev/null
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-plan-approval-adapter.sh"
}

_run_plan_invoke_cursor_graph_approval_live_capability_missing() {
  local cli_name="${1:-cursor-agent}"
  local help_text
  local -a missing=()

  if ! command -v "$cli_name" >/dev/null 2>&1; then
    printf '%s\n' "cursor cli"
    return 0
  fi

  if ! help_text="$("$cli_name" --help 2>/dev/null)"; then
    missing+=("cursor permission-prompt-tool")
    printf '%s\n' "${missing[@]}"
    return 0
  fi

  if [[ "$help_text" != *"--permission-prompt-tool"* && "$help_text" != *"permission-prompt-tool"* ]]; then
    missing+=("cursor permission-prompt-tool")
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    printf '%s\n' "${missing[@]}"
  fi
}

# run_plan_invoke_cursor_graph_approval_live_supported [cli]
# Help-only. Never starts a session or sends a prompt.
run_plan_invoke_cursor_graph_approval_live_supported() {
  local cli_name="${1:-${CURSOR_PLAN_CLI:-cursor-agent}}"
  local missing
  missing="$(_run_plan_invoke_cursor_graph_approval_live_capability_missing "$cli_name")"
  [[ -z "$missing" ]]
}

# run_plan_invoke_cursor_graph_approval_capabilities [cli]
# Overlay can enforce once and run. Live streaming is true only after help proof.
# always-policy stays unsupported: it must not edit ambient user files.
run_plan_invoke_cursor_graph_approval_capabilities() {
  local cli_name="${1:-${CURSOR_PLAN_CLI:-cursor-agent}}"
  local live="false"
  local proof

  _run_plan_invoke_cursor_graph_approval_ensure_adapter || return 1
  if run_plan_invoke_cursor_graph_approval_live_supported "$cli_name"; then
    live="true"
  fi
  proof="$(jq -nc --argjson live "$live" '{
    liveRequestStreaming: $live,
    sameOperationResponse: $live,
    sessionContinuation: true,
    lifetimes: {once: true, run: true, "always-policy": false}
  }')"
  ralph_approval_adapter_capabilities cursor "$proof"
}

# run_plan_invoke_cursor_graph_approval_parse_permission <fake-adapter-event-json>
# Elevates a Cursor fake-adapter permission event into the G15 actionable
# request contract. Choices/lifetimes come only from Cursor capabilities
# (once+run; never advertise always-policy).
run_plan_invoke_cursor_graph_approval_parse_permission() {
  local raw="${1:-}"
  local fields caps

  if [[ -z "$raw" ]]; then
    echo "Error: Cursor graph approval parse requires a permission event" >&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required for Cursor graph approval parse" >&2
    return 1
  fi
  if ! printf '%s' "$raw" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "Error: Cursor graph approval parse requires a JSON object" >&2
    return 1
  fi
  _run_plan_invoke_cursor_graph_approval_ensure_adapter || return 1

  if printf '%s' "$raw" | jq -e '
    def lower($v):
      if $v == null then ""
      elif ($v | type) == "string" then ($v | ascii_downcase)
      else "" end;
    (lower(.tool // .permissionRequest.tool // "")) == "permission"
    and (lower(.action // .permissionRequest.action // "")) == "permission"
    and (lower(.effect // .permissionRequest.effect // "")) == "write"
  ' >/dev/null 2>&1; then
    ralph_approval_adapter_permission_unknown cursor \
      "generic permission/permission/write is not actionable"
    return 0
  fi

  fields="$(printf '%s' "$raw" | jq -ce '
    def str($v):
      if $v == null then ""
      elif ($v | type) == "string" then $v
      elif ($v | type) == "number" then ($v | tostring)
      else "" end;
    {
      runtime: "cursor",
      sessionId: str(.sessionId // .sessionID // .session // .permissionRequest.sessionId // ""),
      nativeRequestId: str(.nativeRequestId // .requestId // .id // .permissionRequest.nativeRequestId // ""),
      tool: str(.tool // .tool_name // .permissionRequest.tool // ""),
      action: str(.action // .permissionRequest.action // ""),
      resource: str(.resource // .command // .path // .permissionRequest.resource // ""),
      effect: str(.effect // .permissionRequest.effect // ""),
      reason: str(.reason // .permissionRequest.reason // ""),
      expiresAt: (.expiresAt // null)
    }
  ' 2>/dev/null)" || {
    ralph_approval_adapter_permission_unknown cursor \
      "Cursor permission event is missing actionable identity"
    return 0
  }

  caps="$(run_plan_invoke_cursor_graph_approval_capabilities "${CURSOR_PLAN_CLI:-cursor-agent}")" || return 1
  ralph_approval_adapter_build_permission_record "$fields" "$caps"
}

# run_plan_invoke_cursor_graph_approval_fallback [reason]
run_plan_invoke_cursor_graph_approval_fallback() {
  local reason="${1:-unsupported}"
  if ! command -v jq >/dev/null 2>&1; then
    printf '%s\n' "{\"schemaVersion\":1,\"runtime\":\"cursor\",\"fallback\":true,\"reason\":\"${reason}\",\"path\":\"overlay\"}"
    return 0
  fi
  jq -nc --arg reason "$reason" '{
    schemaVersion: 1,
    runtime: "cursor",
    fallback: true,
    reason: $reason,
    path: "overlay",
    liveRequestStreaming: false
  }'
}

run_plan_invoke_cursor_graph_approval_settings_target() {
  local root="${WORKSPACE:-${RALPH_PROJECT_ROOT:-}}"
  if [[ -z "$root" ]]; then
    echo "Error: Cursor graph approval overlay requires WORKSPACE or RALPH_PROJECT_ROOT" >&2
    return 1
  fi
  printf '%s/.cursor/cli.json' "$root"
}

# run_plan_invoke_cursor_graph_approval_permission_rule <action> <resource> <effect>
run_plan_invoke_cursor_graph_approval_permission_rule() {
  local action="$1" resource="$2" effect="$3"
  action="$(printf '%s' "$action" | tr '[:upper:]' '[:lower:]')"
  effect="$(printf '%s' "$effect" | tr '[:upper:]' '[:lower:]')"
  resource="${resource#"${resource%%[![:space:]]*}"}"
  resource="${resource%"${resource##*[![:space:]]}"}"
  if [[ -z "$resource" || "$resource" == *$'\n'* || "$resource" == *')'* ]]; then
    echo "Error: Cursor graph approval resource must be a non-empty single line without ')'" >&2
    return 1
  fi
  case "$effect" in
    network)
      printf 'WebFetch(domain:%s)' "$resource"
      ;;
    read)
      case "$action" in
        bash|shell) printf 'Shell(%s)' "$resource" ;;
        *) printf 'Read(%s)' "$resource" ;;
      esac
      ;;
    write)
      case "$action" in
        bash|shell) printf 'Shell(%s)' "$resource" ;;
        write) printf 'Write(%s)' "$resource" ;;
        *) printf 'Edit(%s)' "$resource" ;;
      esac
      ;;
    *)
      echo "Error: Cursor graph approval effect is unsupported: ${effect:-<empty>}" >&2
      return 1
      ;;
  esac
}

# Merge a Cursor cli.json object with an exact allow or deny rule. Deny wins.
_run_plan_invoke_cursor_graph_approval_merge_settings() {
  local existing="$1"
  local rule="$2"
  local kind="$3"
  if [[ -z "$existing" ]] || ! printf '%s' "$existing" | jq -e 'type == "object"' >/dev/null 2>&1; then
    existing='{}'
  fi
  printf '%s' "$existing" | jq -c --arg rule "$rule" --arg kind "$kind" '
    . as $src
    | (($src.permissions // {}) | type == "object") as $ok
    | (if $ok then ($src.permissions.allow // []) else [] end) as $allow0
    | (if $ok then ($src.permissions.deny // []) else [] end) as $deny0
    | (if ($allow0 | type) == "array" then $allow0 else [] end) as $allow
    | (if ($deny0 | type) == "array" then $deny0 else [] end) as $deny
    | (if $kind == "deny" then ($deny + [$rule] | unique) else $deny end) as $deny1
    | (if $kind == "deny" then [$allow[] | select(. != $rule)]
       elif ($deny1 | index($rule)) == null then ($allow + [$rule] | unique)
       else $allow end) as $allow1
    | ($src + {
        permissions: ((($src.permissions // {}) | if type == "object" then . else {} end) + {
          allow: $allow1,
          deny: $deny1
        })
      })
  '
}

_run_plan_invoke_cursor_graph_approval_write_target() {
  local target="$1" overlay_text="$2"
  local existed=0 backup="" tmp_path
  _run_plan_invoke_cursor_graph_approval_ensure_adapter || return 1
  ralph_approval_adapter_ensure_overlay_state cursor || return 1
  if declare -F _runtime_overlay_abs_path >/dev/null 2>&1; then
    target="$(_runtime_overlay_abs_path "$target")"
  fi
  if ralph_approval_adapter_is_ambient_user_path "$target"; then
    echo "Error: Cursor graph approval refuses ambient user path: $target" >&2
    return 1
  fi
  ralph_approval_adapter_overlay_load_state || true
  if [[ -f "$target" ]]; then
    existed=1
  fi
  runtime_overlay_record_original_file "$target" "" 1 || return 1
  if [[ ${#RUNTIME_OVERLAY_MUTATED_BACKUPS[@]} -gt 0 ]]; then
    backup="${RUNTIME_OVERLAY_MUTATED_BACKUPS[${#RUNTIME_OVERLAY_MUTATED_BACKUPS[@]}-1]}"
  fi
  mkdir -p "$(dirname "$target")"
  tmp_path="${target}.ralph-approval.tmp"
  if ! printf '%s\n' "$overlay_text" >"$tmp_path"; then
    runtime_overlay_restore_file "$target" "$backup" "$existed" || true
    echo "Error: Cursor graph approval failed to write $target" >&2
    return 1
  fi
  mv "$tmp_path" "$target"
  RALPH_APPROVAL_ADAPTER_OVERLAY_TARGETS+=("$target")
  RALPH_APPROVAL_ADAPTER_OVERLAY_BACKUPS+=("$backup")
  RALPH_APPROVAL_ADAPTER_OVERLAY_EXISTED+=("$existed")
  ralph_approval_adapter_overlay_install_traps
  ralph_approval_adapter_overlay_save_state || true
  jq -nc --arg target "$target" --arg backup "$backup" '{target:$target,backup:(if $backup == "" then null else $backup end)}'
}

# run_plan_invoke_cursor_graph_approval_apply <request-json>
# Graph-only. Builds an equal-or-narrower project cli.json overlay, journals
# the original, and resumes the same session when continuation is supported.
run_plan_invoke_cursor_graph_approval_apply() {
  local input="${1:-}"
  local caps translated decision lifetime grant_json
  local action resource effect rule kind
  local target existing overlay_text session_id tmp_dir

  if ! run_plan_invoke_cursor_graph_approval_graph_enabled; then
    echo "Error: Cursor graph approval apply is graph-only" >&2
    return 1
  fi
  _run_plan_invoke_cursor_graph_approval_ensure_adapter || return 1
  if [[ -z "$input" ]] || ! printf '%s' "$input" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "Error: Cursor graph approval apply requires a JSON object" >&2
    return 1
  fi
  ralph_approval_adapter_reject_dangerous_fallback "$(printf '%s' "$input" | jq -r '.fallback // empty')" || return 1
  ralph_approval_adapter_reject_dangerous_fallback "$(printf '%s' "$input" | jq -r '.permissionMode // .permission_mode // .approvalMode // .approval_mode // empty')" || return 1

  caps="$(run_plan_invoke_cursor_graph_approval_capabilities "${CURSOR_PLAN_CLI:-cursor-agent}")"
  translated="$(ralph_approval_adapter_translate_decision "$input" "$caps")" || return 1
  decision="$(printf '%s' "$translated" | jq -r '.decision')"
  lifetime="$(printf '%s' "$translated" | jq -r '.lifetime')"
  grant_json="$(printf '%s' "$translated" | jq -c '.grant')"
  session_id="$(printf '%s' "$input" | jq -r '.sessionId // .session_id // empty')"
  target="$(printf '%s' "$input" | jq -r '.target // empty')"
  if [[ -z "$target" ]]; then
    target="$(run_plan_invoke_cursor_graph_approval_settings_target)" || return 1
  fi
  if ralph_approval_adapter_is_ambient_user_path "$target"; then
    echo "Error: Cursor graph approval refuses ambient user path: $target" >&2
    return 1
  fi

  if [[ "$decision" == "deny" ]]; then
    action="$(printf '%s' "$input" | jq -r '.request.action // .action // "Shell"')"
    resource="$(printf '%s' "$input" | jq -r '.request.resource // .resource // empty')"
    effect="$(printf '%s' "$input" | jq -r '.request.effect // .effect // "write"')"
    kind="deny"
  else
    action="$(printf '%s' "$grant_json" | jq -r '.action')"
    resource="$(printf '%s' "$grant_json" | jq -r '.resource')"
    effect="$(printf '%s' "$grant_json" | jq -r '.effect')"
    kind="allow"
  fi
  rule="$(run_plan_invoke_cursor_graph_approval_permission_rule "$action" "$resource" "$effect")" || return 1

  existing="{}"
  if [[ -f "$target" ]]; then
    existing="$(cat "$target")"
  fi
  overlay_text="$(_run_plan_invoke_cursor_graph_approval_merge_settings "$existing" "$rule" "$kind")" || return 1

  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/ralph-cursor-approval.XXXXXX")" || return 1

  if [[ "$decision" == "deny" ]]; then
    if ! _run_plan_invoke_cursor_graph_approval_write_target "$target" "$overlay_text" >"$tmp_dir/write.json"; then
      rm -rf "$tmp_dir"
      return 1
    fi
    if ! ralph_approval_adapter_overlay_fallback "$(jq -nc --arg runtime cursor '{decision:"deny",runtime:$runtime}')" "$caps" >"$tmp_dir/fallback.json"; then
      rm -rf "$tmp_dir"
      return 1
    fi
    jq -nc \
      --argjson applied "$(cat "$tmp_dir/fallback.json")" \
      --argjson write "$(cat "$tmp_dir/write.json")" \
      --argjson grant "$grant_json" \
      --arg lifetime "$lifetime" \
      --arg decision "$decision" \
      --arg session "$session_id" \
      --arg overlay "$overlay_text" \
      '{
        schemaVersion: 1,
        runtime: "cursor",
        path: "overlay",
        fallback: "overlay",
        applied: true,
        decision: $decision,
        lifetime: $lifetime,
        grant: $grant,
        equalOrNarrower: true,
        continuation: $applied.continuation,
        sessionStrategy: $applied.sessionStrategy,
        sessionId: (if $session == "" then null else $session end),
        target: $write.target,
        backup: $write.backup,
        restored: false,
        overlay: ($overlay | fromjson)
      }'
    rm -rf "$tmp_dir"
    return 0
  fi

  if ! ralph_approval_adapter_overlay_fallback "$(jq -nc \
    --arg runtime cursor \
    --arg decision "$decision" \
    --arg target "$target" \
    --arg session "$session_id" \
    --argjson grant "$grant_json" \
    --argjson overlay "$overlay_text" \
    --arg action "$action" \
    --arg resource "$resource" \
    --arg effect "$effect" \
    '{
      decision: $decision,
      runtime: $runtime,
      action: $action,
      resource: $resource,
      effect: $effect,
      grant: $grant,
      target: $target,
      overlay: $overlay,
      sessionId: $session
    }')" "$caps" >"$tmp_dir/applied.json"; then
    rm -rf "$tmp_dir"
    return 1
  fi

  jq -c \
    --argjson overlay "$overlay_text" \
    '. + {runtime:"cursor", path:"overlay", overlay:$overlay}' \
    "$tmp_dir/applied.json"
  rm -rf "$tmp_dir"
}

# run_plan_invoke_cursor_graph_approval_restore [reason]
run_plan_invoke_cursor_graph_approval_restore() {
  _run_plan_invoke_cursor_graph_approval_ensure_adapter || return 1
  ralph_approval_adapter_overlay_restore "${1:-success}"
}

# run_plan_invoke_cursor_graph_approval_start_or_fallback [cli] [request-json]
# Live channel only after nonbillable help proof. Otherwise overlay fallback.
run_plan_invoke_cursor_graph_approval_start_or_fallback() {
  local cli="${1:-${CURSOR_PLAN_CLI:-cursor-agent}}"
  local request="${2:-}"
  local caps

  if ! run_plan_invoke_cursor_graph_approval_graph_enabled; then
    echo "Error: Cursor graph approval is graph-only" >&2
    return 1
  fi
  _run_plan_invoke_cursor_graph_approval_ensure_adapter || return 1

  if run_plan_invoke_cursor_graph_approval_live_supported "$cli"; then
    caps="$(run_plan_invoke_cursor_graph_approval_capabilities "$cli")"
    jq -nc --argjson caps "$caps" '{
      schemaVersion: 1,
      runtime: "cursor",
      fallback: false,
      path: "live",
      channel: "permission-prompt-tool",
      liveRequestStreaming: $caps.liveRequestStreaming,
      sameOperationResponse: $caps.sameOperationResponse,
      sessionContinuation: $caps.sessionContinuation,
      lifetimes: $caps.lifetimes
    }'
    return 0
  fi

  if [[ -n "$request" ]]; then
    run_plan_invoke_cursor_graph_approval_apply "$request" || return 1
    return 2
  fi
  run_plan_invoke_cursor_graph_approval_fallback "unsupported"
  return 2
}
