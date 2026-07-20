#!/usr/bin/env bash

if [[ -n "${RALPH_RUN_PLAN_INVOKE_CODEX_LOADED:-}" ]]; then
  return
fi
RALPH_RUN_PLAN_INVOKE_CODEX_LOADED=1

# Public interface:
#   run_plan_invoke_codex_mcp_config_prepare / run_plan_invoke_codex_mcp_config_cleanup -- ralph-mode ephemeral MCP config.
#   ralph_run_plan_invoke_codex -- run Codex directly with the canonical Ralph-owned invoke path; exports env for
#     the demux pipeline (OUTPUT_LOG, EXIT_CODE_FILE, SESSION_ID_FILE, RALPH_PLAN_CLI_RESUME, resume session/bare
#     flags, CODEX_PLAN_CLI, CODEX_PLAN_MODEL, CODEX_PLAN_SANDBOX,
#     CODEX_PLAN_DANGEROUSLY_BYPASS_APPROVALS_AND_SANDBOX).

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-plan-invoke-common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../mcp/mcp-setup.sh"

# Public interface (native hooks):
#   run_plan_invoke_codex_native_hooks_prepare / run_plan_invoke_codex_native_hooks_cleanup
#   -- per-run Codex hook --config injection (wrapper-based native shell compaction and PostToolUse telemetry).

run_plan_invoke_codex_session_resume_args() {
  local args_name="$1"
  eval "$args_name+=(resume \"\${RALPH_RUN_PLAN_RESUME_SESSION_ID}\")"
}

run_plan_invoke_codex_session_new_args() {
  :
}

run_plan_invoke_codex_bare_resume_args() {
  local args_name="$1"
  eval "$args_name+=(resume --last)"
}

run_plan_invoke_codex_bare_resume_warn() {
  echo "Warning: resume without a session id requires RALPH_PLAN_ALLOW_UNSAFE_RESUME=1 or --allow-unsafe-resume; omitting bare Codex resume --last." >&2
}

_run_plan_invoke_codex_toml_escape() {
  local value="${1:-}"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

_run_plan_invoke_codex_proxy_capability_missing() {
  local cli_name="${1:-codex}"
  local mcp_help exec_help
  local -a missing=()

  if ! mcp_help="$("$cli_name" mcp --help 2>/dev/null)"; then
    missing+=("codex mcp subcommand")
    printf '%s\n' "${missing[@]}"
    return 0
  fi
  if [[ "$mcp_help" != *"add"* ]]; then
    missing+=("codex mcp add")
  fi
  if [[ "$mcp_help" != *"remove"* ]]; then
    missing+=("codex mcp remove")
  fi

  if ! exec_help="$("$cli_name" exec --help 2>/dev/null)"; then
    missing+=("codex exec subcommand")
    printf '%s\n' "${missing[@]}"
    return 0
  fi
  if [[ "$exec_help" != *"--config"* ]]; then
    missing+=("codex exec --config")
  fi
  if [[ "$exec_help" != *"--strict-config"* ]]; then
    missing+=("codex exec --strict-config")
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    printf '%s\n' "${missing[@]}"
  fi
}

_run_plan_invoke_codex_proxy_supported() {
  local cli_name="${1:-codex}"
  local missing
  missing="$(_run_plan_invoke_codex_proxy_capability_missing "$cli_name")"
  [[ -z "$missing" ]]
}

_run_plan_invoke_codex_append_config() {
  local args_name="$1"
  local config_value="$2"
  eval "$args_name+=(--config $(printf '%q' "$config_value"))"
}

_run_plan_invoke_codex_append_add_dirs() {
  local args_name="$1"
  local add_dirs="${2:-}"
  local old_ifs="$IFS"
  local -a dirs=()
  local dir trimmed

  [[ -n "$add_dirs" ]] || return 0
  IFS=','
  read -ra dirs <<< "$add_dirs"
  IFS="$old_ifs"

  for dir in "${dirs[@]}"; do
    trimmed="${dir#"${dir%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [[ -z "$trimmed" ]] && continue
    eval "$args_name+=(--add-dir \"\$trimmed\")"
  done
}

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../runtime-overlay/runtime-overlay-codex.sh"

_run_plan_invoke_codex_mcp_tools_approval_mode_resolve() {
  case "${CODEX_PLAN_MCP_OMIT_TOOLS_APPROVAL_MODE:-0}" in
    1|true|yes|on)
      return 0
      ;;
  esac

  local raw="${CODEX_PLAN_MCP_TOOLS_APPROVAL_MODE:-approve}"
  case "$raw" in
    ""|omit|unset|off|none|skip|disable|disabled)
      return 0
      ;;
    approve|prompt|auto)
      printf '%s' "$raw"
      return 0
      ;;
    *)
      if declare -F ralph_run_plan_log >/dev/null 2>&1; then
        ralph_run_plan_log "Codex MCP: invalid CODEX_PLAN_MCP_TOOLS_APPROVAL_MODE='$raw'; using approve"
      fi
      printf '%s' "approve"
      return 0
      ;;
  esac
}

_run_plan_invoke_codex_mcp_tools_approval_mode_config_line() {
  local mode="$1"
  [[ -n "$mode" ]] || return 1
  printf '%s' "mcp_servers.ralph.default_tools_approval_mode=\"$(_run_plan_invoke_codex_toml_escape "$mode")\""
}

_run_plan_invoke_codex_mcp_print_proxy_config_values() {
  local config_path="$1"
  local include_type="${2:-0}"
  local include_required="${3:-0}"
  local include_approval_mode="${4:-0}"
  local approval_mode_value="${5:-}"
  local command_path workspace_root
  local -a proxy_args=()
  local env_key env_value

  command_path="$(jq -r '.mcpServers.ralph.command // empty' "$config_path")"
  workspace_root="$(jq -r '.mcpServers.ralph.env.RALPH_MCP_WORKSPACE // empty' "$config_path")"

  if [[ -z "$command_path" || -z "$workspace_root" ]]; then
    echo "Error: Codex proxy config is missing the Ralph MCP command or workspace." >&2
    return 1
  fi

  while IFS= read -r line; do
    [[ -n "$line" ]] && proxy_args+=("$line")
  done < <(jq -r '.mcpServers.ralph.args[]? // empty' "$config_path")

  if [[ ${#proxy_args[@]} -eq 0 ]]; then
    echo "Error: Codex proxy config is missing the Ralph MCP args." >&2
    return 1
  fi

  printf '%s\n' 'mcp_servers.ralph.enabled=true'
  printf '%s\n' "mcp_servers.ralph.command=\"$( _run_plan_invoke_codex_toml_escape "$command_path" )\""

  local args_value="["
  local args_sep=""
  local proxy_arg
  for proxy_arg in "${proxy_args[@]}"; do
    args_value+="${args_sep}\"$(_run_plan_invoke_codex_toml_escape "$proxy_arg")\""
    args_sep=", "
  done
  args_value+="]"
  printf '%s\n' "mcp_servers.ralph.args=$args_value"

  while IFS=$'\t' read -r env_key env_value; do
    [[ -n "${env_key:-}" ]] || continue
    printf '%s\n' "mcp_servers.ralph.env.$env_key=\"$( _run_plan_invoke_codex_toml_escape "$env_value" )\""
  done < <(jq -r '.mcpServers.ralph.env | to_entries[]? | [.key, .value] | @tsv' "$config_path")

  if [[ "$include_type" == "1" ]]; then
    printf '%s\n' 'mcp_servers.ralph.type="stdio"'
  fi

  if [[ "$include_required" == "1" ]]; then
    printf '%s\n' 'mcp_servers.ralph.required=true'
  fi

  if [[ "$include_approval_mode" == "1" && -n "$approval_mode_value" ]]; then
    printf '%s\n' "$(_run_plan_invoke_codex_mcp_tools_approval_mode_config_line "$approval_mode_value")"
  fi
}

_run_plan_invoke_codex_mcp_probe_config_values() {
  local cli_name="${1:-codex}"
  shift

  if ! command -v "$cli_name" &>/dev/null; then
    return 0
  fi

  local stderr_file probe_status=0
  local -a cmd=("$cli_name" exec --strict-config)
  local config_value

  for config_value in "$@"; do
    cmd+=(--config "$config_value")
  done

  stderr_file="$(mktemp "${TMPDIR:-/tmp}/ralph-codex-complete-config-probe.XXXXXX")"

  "${cmd[@]}" >/dev/null 2>"$stderr_file" <<< "" || probe_status=$?

  local stderr_output
  stderr_output="$(cat "$stderr_file" 2>/dev/null)"
  rm -f "$stderr_file"

  if [[ "$probe_status" -ne 0 ]] && grep -qE 'unknown configuration field' <<<"$stderr_output"; then
    echo "$stderr_output"
    return 1
  fi

  return 0
}

_run_plan_invoke_codex_mcp_optional_field_supported() {
  local cli_name="${1:-codex}"
  local config_path="$2"
  local field="$3"
  local config_value="$4"
  local -a probe_values=()
  local probe_error

  while IFS= read -r line; do
    probe_values+=("$line")
  done < <(_run_plan_invoke_codex_mcp_print_proxy_config_values "$config_path" 0 0) || return 2

  probe_values+=("$config_value")
  probe_error="$(_run_plan_invoke_codex_mcp_probe_config_values "$cli_name" "${probe_values[@]}")"

  if [[ -z "$probe_error" ]]; then
    return 0
  fi

  if grep -qE "unknown configuration field.*mcp_servers\\.ralph\\.${field}" <<<"$probe_error"; then
    if declare -F ralph_run_plan_log >/dev/null 2>&1; then
      ralph_run_plan_log "Codex MCP: omitting $field (unsupported by installed Codex CLI under --strict-config)"
    fi
    return 1
  fi

  echo "$probe_error" >&2
  return 2
}

_run_plan_invoke_codex_add_proxy_config_args() {
  local args_name="$1"
  local config_path="$2"
  local cli_name="${3:-${CODEX_PLAN_CLI:-codex}}"
  local include_type=0
  local include_required=0
  local include_approval_mode=0
  local approval_mode=""
  local approval_config_line=""
  local optional_status=0
  local -a config_values=()

  case "${CODEX_PLAN_MCP_OMIT_TYPE:-0}" in
    1|true|yes|on)
      if declare -F ralph_run_plan_log >/dev/null 2>&1; then
        ralph_run_plan_log "Codex MCP: omitting type (CODEX_PLAN_MCP_OMIT_TYPE=1)"
      fi
      ;;
    *)
      if _run_plan_invoke_codex_mcp_optional_field_supported \
        "$cli_name" \
        "$config_path" \
        "type" \
        'mcp_servers.ralph.type="stdio"'; then
        include_type=1
      else
        optional_status=$?
        if [[ "$optional_status" -eq 2 ]]; then
          return 1
        fi
      fi
      ;;
  esac

  case "${CODEX_PLAN_MCP_OMIT_REQUIRED:-0}" in
    1|true|yes|on)
      if declare -F ralph_run_plan_log >/dev/null 2>&1; then
        ralph_run_plan_log "Codex MCP: omitting required (CODEX_PLAN_MCP_OMIT_REQUIRED=1)"
      fi
      ;;
    *)
      if _run_plan_invoke_codex_mcp_optional_field_supported \
        "$cli_name" \
        "$config_path" \
        "required" \
        'mcp_servers.ralph.required=true'; then
        include_required=1
      else
        optional_status=$?
        if [[ "$optional_status" -eq 2 ]]; then
          return 1
        fi
      fi
      ;;
  esac

  case "${CODEX_PLAN_MCP_OMIT_TOOLS_APPROVAL_MODE:-0}" in
    1|true|yes|on)
      if declare -F ralph_run_plan_log >/dev/null 2>&1; then
        ralph_run_plan_log "Codex MCP: omitting default_tools_approval_mode (CODEX_PLAN_MCP_OMIT_TOOLS_APPROVAL_MODE=1)"
      fi
      ;;
    *)
      approval_mode="$(_run_plan_invoke_codex_mcp_tools_approval_mode_resolve)"
      if [[ -n "$approval_mode" ]]; then
        approval_config_line="$(_run_plan_invoke_codex_mcp_tools_approval_mode_config_line "$approval_mode")"
        if _run_plan_invoke_codex_mcp_optional_field_supported \
          "$cli_name" \
          "$config_path" \
          "default_tools_approval_mode" \
          "$approval_config_line"; then
          include_approval_mode=1
        else
          optional_status=$?
          if [[ "$optional_status" -eq 2 ]]; then
            return 1
          fi
        fi
      fi
      ;;
  esac

  while IFS= read -r line; do
    config_values+=("$line")
  done < <(_run_plan_invoke_codex_mcp_print_proxy_config_values \
    "$config_path" \
    "$include_type" \
    "$include_required" \
    "$include_approval_mode" \
    "$approval_mode") || return 1

  local config_value
  for config_value in "${config_values[@]}"; do
    _run_plan_invoke_codex_append_config "$args_name" "$config_value"
  done
}

# --- Effective MCP catalog serializer (ambient + agent + Ralph) ----------------
#
# The shared runtime-config resolver writes a Codex-native catalog to
# RALPH_RUNTIME_MCP_RESOLVE_PATH using the `mcp_servers` TOML key (distinct from
# the Ralph-only generator's `mcpServers` JSON shape used for Claude). These
# helpers translate every named server in that catalog into per-run
# `--config mcp_servers.<name>.*` overrides, preserving Codex's native loading of
# ~/.codex/config.toml and the trusted project .codex/config.toml while adding
# agent MCP overrides and Ralph's protected server on top. Ralph's protected
# `required`, `enabled`, `type`, and `default_tools_approval_mode` enhancements
# are probed exactly like the Ralph-only path; other servers emit only the
# required transport fields so unsupported optional fields cannot leak.

_run_plan_invoke_codex_mcp_server_is_http() {
  local config_path="$1"
  local name="$2"
  local url
  url="$(jq -r --arg name "$name" '.mcp_servers[$name].url // empty' "$config_path" 2>/dev/null)"
  [[ -n "$url" ]]
}

_run_plan_invoke_codex_mcp_print_server_config_values() {
  local config_path="$1"
  local name="$2"
  local include_ralph_optional="${3:-0}"
  local include_type="${4:-0}"
  local include_required="${5:-0}"
  local include_approval_mode="${6:-0}"
  local approval_mode_value="${7:-}"

  local url command args_value env_key env_value
  url="$(jq -r --arg name "$name" '.mcp_servers[$name].url // empty' "$config_path" 2>/dev/null)"

  if [[ -n "$url" ]]; then
    printf '%s\n' "mcp_servers.${name}.url=\"$(_run_plan_invoke_codex_toml_escape "$url")\""
    while IFS=$'\t' read -r env_key env_value; do
      [[ -n "${env_key:-}" ]] || continue
      printf '%s\n' "mcp_servers.${name}.env.$env_key=\"$(_run_plan_invoke_codex_toml_escape "$env_value")\""
    done < <(jq -r --arg name "$name" '.mcp_servers[$name].env // {} | to_entries[]? | [.key, .value] | @tsv' "$config_path" 2>/dev/null)
    while IFS=$'\t' read -r env_key env_value; do
      [[ -n "${env_key:-}" ]] || continue
      printf '%s\n' "mcp_servers.${name}.headers.$env_key=\"$(_run_plan_invoke_codex_toml_escape "$env_value")\""
    done < <(jq -r --arg name "$name" '.mcp_servers[$name].headers // {} | to_entries[]? | [.key, .value] | @tsv' "$config_path" 2>/dev/null)
    return 0
  fi

  command="$(jq -r --arg name "$name" '.mcp_servers[$name].command // empty' "$config_path" 2>/dev/null)"
  if [[ -z "$command" ]]; then
    echo "Error: Codex effective MCP server '$name' is missing command and url." >&2
    return 1
  fi
  printf '%s\n' "mcp_servers.${name}.command=\"$(_run_plan_invoke_codex_toml_escape "$command")\""

  args_value="["
  local args_sep=""
  local proxy_arg
  while IFS= read -r proxy_arg; do
    [[ -n "$proxy_arg" ]] || continue
    args_value+="${args_sep}\"$(_run_plan_invoke_codex_toml_escape "$proxy_arg")\""
    args_sep=", "
  done < <(jq -r --arg name "$name" '.mcp_servers[$name].args // [] | .[]?' "$config_path" 2>/dev/null)
  args_value+="]"
  printf '%s\n' "mcp_servers.${name}.args=$args_value"

  while IFS=$'\t' read -r env_key env_value; do
    [[ -n "${env_key:-}" ]] || continue
    printf '%s\n' "mcp_servers.${name}.env.$env_key=\"$(_run_plan_invoke_codex_toml_escape "$env_value")\""
  done < <(jq -r --arg name "$name" '.mcp_servers[$name].env // {} | to_entries[]? | [.key, .value] | @tsv' "$config_path" 2>/dev/null)

  if [[ "$include_ralph_optional" == "1" && "$name" == "ralph" ]]; then
    printf '%s\n' 'mcp_servers.ralph.enabled=true'
    if [[ "$include_type" == "1" ]]; then
      printf '%s\n' 'mcp_servers.ralph.type="stdio"'
    fi
    if [[ "$include_required" == "1" ]]; then
      printf '%s\n' 'mcp_servers.ralph.required=true'
    fi
    if [[ "$include_approval_mode" == "1" && -n "$approval_mode_value" ]]; then
      printf '%s\n' "$(_run_plan_invoke_codex_mcp_tools_approval_mode_config_line "$approval_mode_value")"
    fi
  fi
  return 0
}

_run_plan_invoke_codex_mcp_print_effective_config_values() {
  local config_path="$1"
  local include_type="${2:-0}"
  local include_required="${3:-0}"
  local include_approval_mode="${4:-0}"
  local approval_mode_value="${5:-}"
  local name

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    _run_plan_invoke_codex_mcp_print_server_config_values \
      "$config_path" \
      "$name" \
      1 \
      "$include_type" \
      "$include_required" \
      "$include_approval_mode" \
      "$approval_mode_value" || return 1
  done < <(jq -r '.mcp_servers // {} | keys[]?' "$config_path" 2>/dev/null | sort)
}

# Probe an optional field against the full effective catalog so unsupported
# optional fields are omitted once for the whole run instead of per-server.
_run_plan_invoke_codex_mcp_effective_optional_field_supported() {
  local cli_name="${1:-${CODEX_PLAN_CLI:-codex}}"
  local config_path="$2"
  local field="$3"
  local config_value="$4"
  local -a probe_values=()
  local probe_error name

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    while IFS= read -r line; do
      probe_values+=("$line")
    done < <(_run_plan_invoke_codex_mcp_print_server_config_values "$config_path" "$name" 0 0 0 0 "") || return 2
  done < <(jq -r '.mcp_servers // {} | keys[]?' "$config_path" 2>/dev/null | sort)

  probe_values+=("$config_value")
  probe_error="$(_run_plan_invoke_codex_mcp_probe_config_values "$cli_name" "${probe_values[@]}")"

  if [[ -z "$probe_error" ]]; then
    return 0
  fi

  if grep -qE "unknown configuration field.*mcp_servers\\.ralph\\.${field}" <<<"$probe_error"; then
    if declare -F ralph_run_plan_log >/dev/null 2>&1; then
      ralph_run_plan_log "Codex MCP: omitting $field (unsupported by installed Codex CLI under --strict-config)"
    fi
    return 1
  fi

  echo "$probe_error" >&2
  return 2
}

_run_plan_invoke_codex_add_effective_config_args() {
  local args_name="$1"
  local config_path="$2"
  local cli_name="${3:-${CODEX_PLAN_CLI:-codex}}"
  local include_type=0
  local include_required=0
  local include_approval_mode=0
  local approval_mode=""
  local approval_config_line=""
  local optional_status=0
  local -a config_values=()

  case "${CODEX_PLAN_MCP_OMIT_TYPE:-0}" in
    1|true|yes|on)
      if declare -F ralph_run_plan_log >/dev/null 2>&1; then
        ralph_run_plan_log "Codex MCP: omitting type (CODEX_PLAN_MCP_OMIT_TYPE=1)"
      fi
      ;;
    *)
      if _run_plan_invoke_codex_mcp_effective_optional_field_supported \
        "$cli_name" \
        "$config_path" \
        "type" \
        'mcp_servers.ralph.type="stdio"'; then
        include_type=1
      else
        optional_status=$?
        if [[ "$optional_status" -eq 2 ]]; then
          return 1
        fi
      fi
      ;;
  esac

  case "${CODEX_PLAN_MCP_OMIT_REQUIRED:-0}" in
    1|true|yes|on)
      if declare -F ralph_run_plan_log >/dev/null 2>&1; then
        ralph_run_plan_log "Codex MCP: omitting required (CODEX_PLAN_MCP_OMIT_REQUIRED=1)"
      fi
      ;;
    *)
      if _run_plan_invoke_codex_mcp_effective_optional_field_supported \
        "$cli_name" \
        "$config_path" \
        "required" \
        'mcp_servers.ralph.required=true'; then
        include_required=1
      else
        optional_status=$?
        if [[ "$optional_status" -eq 2 ]]; then
          return 1
        fi
      fi
      ;;
  esac

  case "${CODEX_PLAN_MCP_OMIT_TOOLS_APPROVAL_MODE:-0}" in
    1|true|yes|on)
      if declare -F ralph_run_plan_log >/dev/null 2>&1; then
        ralph_run_plan_log "Codex MCP: omitting default_tools_approval_mode (CODEX_PLAN_MCP_OMIT_TOOLS_APPROVAL_MODE=1)"
      fi
      ;;
    *)
      approval_mode="$(_run_plan_invoke_codex_mcp_tools_approval_mode_resolve)"
      if [[ -n "$approval_mode" ]]; then
        approval_config_line="$(_run_plan_invoke_codex_mcp_tools_approval_mode_config_line "$approval_mode")"
        if _run_plan_invoke_codex_mcp_effective_optional_field_supported \
          "$cli_name" \
          "$config_path" \
          "default_tools_approval_mode" \
          "$approval_config_line"; then
          include_approval_mode=1
        else
          optional_status=$?
          if [[ "$optional_status" -eq 2 ]]; then
            return 1
          fi
        fi
      fi
      ;;
  esac

  while IFS= read -r line; do
    config_values+=("$line")
  done < <(_run_plan_invoke_codex_mcp_print_effective_config_values \
    "$config_path" \
    "$include_type" \
    "$include_required" \
    "$include_approval_mode" \
    "$approval_mode") || return 1

  local config_value
  for config_value in "${config_values[@]}"; do
    _run_plan_invoke_codex_append_config "$args_name" "$config_value"
  done
}

# Classify Codex --json NDJSON from a live MCP probe.
# Prints one of: ok, cancelled, native_fallback, failed, inconclusive
ralph_mcp_codex_analyze_preflight_output() {
  local transcript="${1:-}"
  if [[ -z "$transcript" ]]; then
    echo "inconclusive"
    return 0
  fi

  if printf '%s' "$transcript" | grep -qi 'user cancelled MCP tool call'; then
    echo "cancelled"
    return 0
  fi

  local saw_ralph_ok=0 saw_native=0 saw_turn=0
  local line item_type item_name item_status event_type

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    event_type="$(jq -r '.type // empty' <<<"$line" 2>/dev/null)" || continue
    case "$event_type" in
      turn.completed|thread.completed)
        saw_turn=1
        ;;
      item.completed)
        item_type="$(jq -r '.item.type // empty' <<<"$line" 2>/dev/null)"
        item_name="$(jq -r '.item | .name // .tool_name // .toolName // empty' <<<"$line" 2>/dev/null)"
        item_status="$(jq -r '.item | .status // .state // empty' <<<"$line" 2>/dev/null)"
        item_type_lc="$(printf '%s' "$item_type" | tr '[:upper:]' '[:lower:]')"
        item_status_lc="$(printf '%s' "$item_status" | tr '[:upper:]' '[:lower:]')"
        case "$item_type_lc" in
          mcp_tool_call|tool_use|mcp_tool|mcp_tool_use)
            if [[ "$item_name" == *ralph_proxy_read* || "$item_name" == mcp__ralph__ralph_proxy_read ]]; then
              case "$item_status_lc" in
                ""|completed|success|succeeded)
                  saw_ralph_ok=1
                  ;;
                failed|error|cancelled|canceled)
                  if jq -e '.item | (.error // .message // "") | test("cancel"; "i")' <<<"$line" >/dev/null 2>&1; then
                    echo "cancelled"
                    return 0
                  fi
                  ;;
              esac
            fi
            ;;
          command_execution|read_file|grep|shell|exec|shell_command)
            saw_native=1
            ;;
        esac
        ;;
    esac
  done <<<"$transcript"

  if [[ "$saw_ralph_ok" == "1" ]]; then
    echo "ok"
    return 0
  fi
  if [[ "$saw_native" == "1" ]]; then
    echo "native_fallback"
    return 0
  fi
  if [[ "$saw_turn" == "1" ]]; then
    echo "failed"
    return 0
  fi
  if printf '%s' "$transcript" | grep -qiE 'rate.?limit|unauthorized|authentication|invalid[_ ]?api|quota exceeded|billing'; then
    echo "inconclusive"
    return 0
  fi
  echo "inconclusive"
}

# Live Codex CLI gate: prove ralph_proxy_read works before the real TODO invocation.
# Return codes: 0 success, 1 conclusive proxy failure, 2 inconclusive (caller may continue)
ralph_mcp_codex_cli_preflight() {
  local workspace="${1:-}"
  local model="${2:-}"
  local cli="${CODEX_PLAN_CLI:-${CODEX_CLI:-codex}}"

  if [[ -z "$workspace" ]]; then
    echo "Note: skipping Codex CLI MCP preflight; workspace not provided." >&2
    return 2
  fi
  if ! command -v "$cli" >/dev/null 2>&1; then
    echo "Note: skipping Codex CLI MCP preflight; '$cli' not found." >&2
    return 2
  fi
  if ! _run_plan_invoke_codex_proxy_supported "$cli"; then
    echo "Error: Codex CLI missing Ralph MCP capabilities required for strict proxy preflight." >&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "Note: skipping Codex CLI MCP preflight; jq not found." >&2
    return 2
  fi

  local read_path="${RALPH_CODEX_PREFLIGHT_READ_PATH:-AGENTS.md}"
  if [[ ! -f "$workspace/$read_path" ]]; then
    echo "Error: Codex strict-proxy preflight requires readable file $workspace/$read_path." >&2
    return 1
  fi

  local config_path
  config_path="$(mktemp "${TMPDIR:-/tmp}/ralph-codex-cli-preflight-XXXXXX")"
  if ! ralph_mcp_generate_config codex "$config_path" "$workspace"; then
    ralph_mcp_cleanup_config "$config_path"
    echo "Note: skipping Codex CLI MCP preflight; could not generate MCP config." >&2
    return 2
  fi

  local -a args=(exec --json --strict-config)
  local sandbox="${CODEX_PLAN_SANDBOX:-workspace-write}"
  case "$sandbox" in
    read-only|workspace-write|danger-full-access) ;;
    *)
      sandbox="workspace-write"
      ;;
  esac
  args+=(--sandbox "$sandbox")

  if [[ -n "$model" && "$model" != "auto" ]]; then
    args+=(--model "$model")
  fi

  if ! _run_plan_invoke_codex_add_proxy_config_args args "$config_path" "$cli"; then
    ralph_mcp_cleanup_config "$config_path"
    echo "Error: failed to build Codex MCP config overrides for live preflight." >&2
    return 1
  fi

  local prompt
  prompt="You MUST call the tool ralph_proxy_read with {\"path\":\"${read_path}\"} right now and nothing else."

  local out cli_status=0
  out="$(printf '%s' "$prompt" | "$cli" "${args[@]}" 2>&1)" || cli_status=$?
  ralph_mcp_cleanup_config "$config_path"

  local verdict
  verdict="$(ralph_mcp_codex_analyze_preflight_output "$out")"
  case "$verdict" in
    ok)
      return 0
      ;;
    cancelled)
      echo "Error: Codex live MCP preflight saw user cancelled MCP tool call for ralph_proxy_read." >&2
      return 1
      ;;
    native_fallback)
      echo "Error: Codex live MCP preflight saw native tool fallback without a successful ralph_proxy_read." >&2
      return 1
      ;;
    failed)
      echo "Error: Codex ran but never completed a successful ralph_proxy_read MCP tool call." >&2
      return 1
      ;;
    inconclusive)
      echo "Note: Codex CLI MCP preflight inconclusive (cli exit=$cli_status; likely auth, credit, or rate limit). Skipping the live gate." >&2
      return 2
      ;;
    *)
      echo "Note: Codex CLI MCP preflight inconclusive (unexpected verdict=$verdict, cli exit=$cli_status)." >&2
      return 2
      ;;
  esac
}

run_plan_invoke_codex_mcp_config_cleanup() {
  if [[ -n "${CODEX_PLAN_MCP_CONFIG_PATH:-}" && "${CODEX_PLAN_MCP_CONFIG_OWNED:-0}" == "1" ]]; then
    ralph_mcp_cleanup_config "$CODEX_PLAN_MCP_CONFIG_PATH"
  fi
  unset CODEX_PLAN_MCP_CONFIG_PATH CODEX_PLAN_MCP_CONFIG_OWNED
}

run_plan_invoke_codex_mcp_config_prepare() {
  local workspace="${WORKSPACE:-}"
  if [[ -z "$workspace" ]]; then
    echo "Error: WORKSPACE is required for Codex Ralph MCP config injection." >&2
    return 1
  fi
  if ! command -v jq &>/dev/null; then
    echo "Error: jq is required to generate the MCP config for Codex Agent Tool Access (ralph mode)." >&2
    return 1
  fi

  # Prefer the shared effective catalog (ambient user/project config.toml +
  # selected-agent overrides + Ralph's protected server) when the runtime-config
  # resolver has produced it. Codex keeps loading ~/.codex/config.toml and the
  # trusted project .codex/config.toml natively; the resolver catalog is only
  # used to translate the effective servers into per-run --config overrides.
  if [[ -n "${RALPH_RUNTIME_MCP_RESOLVE_PATH:-}" && -f "$RALPH_RUNTIME_MCP_RESOLVE_PATH" ]]; then
    CODEX_PLAN_MCP_CONFIG_PATH="$RALPH_RUNTIME_MCP_RESOLVE_PATH"
    CODEX_PLAN_MCP_CONFIG_OWNED=0
    export CODEX_PLAN_MCP_CONFIG_PATH CODEX_PLAN_MCP_CONFIG_OWNED
    return 0
  fi

  local config_path
  config_path="$(mktemp "${TMPDIR:-/tmp}/ralph-codex-mcp-XXXXXX")"
  if ! ralph_mcp_generate_config codex "$config_path" "$workspace"; then
    ralph_mcp_cleanup_config "$config_path"
    echo "Error: failed to generate Codex MCP config." >&2
    return 1
  fi

  ralph_mcp_overlay_record_temp_file "$config_path"

  CODEX_PLAN_MCP_CONFIG_PATH="$config_path"
  CODEX_PLAN_MCP_CONFIG_OWNED=1
  export CODEX_PLAN_MCP_CONFIG_PATH CODEX_PLAN_MCP_CONFIG_OWNED
  ralph_mcp_overlay_register_runtime_cleanup run_plan_invoke_codex_mcp_config_cleanup
}

ralph_run_plan_invoke_codex() {
  ralph_run_plan_sync_mode_knobs
  # Demux/tee inputs: combined output log, sidecar exit code, session id file path.
  export OUTPUT_LOG EXIT_CODE_FILE SESSION_ID_FILE
  # Codex wrapper reads this to decide resume behavior and JSON parsing.
  export RALPH_PLAN_CLI_RESUME
  if [[ -n "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]]; then
    # Passed to codex-exec-prompt.sh for `codex exec resume <id>`.
    export RALPH_RUN_PLAN_RESUME_SESSION_ID
  else
    unset RALPH_RUN_PLAN_RESUME_SESSION_ID
  fi
  if [[ "${RALPH_RUN_PLAN_RESUME_BARE:-0}" == "1" ]] && [[ "${RALPH_PLAN_ALLOW_UNSAFE_RESUME:-0}" == "1" ]]; then
    # Enables bare resume path in the Codex wrapper when no session id is stored.
    export RALPH_RUN_PLAN_RESUME_BARE
  elif [[ "${RALPH_RUN_PLAN_RESUME_BARE:-0}" == "1" ]]; then
    echo "Warning: resume without a session id requires RALPH_PLAN_ALLOW_UNSAFE_RESUME=1 or --allow-unsafe-resume; not using Codex resume --last." >&2
    unset RALPH_RUN_PLAN_RESUME_BARE
  else
    unset RALPH_RUN_PLAN_RESUME_BARE
  fi

  if [[ -n "${CODEX_CLI:-}" ]]; then
    # Executable name or path for the Codex binary (wrapper reads CODEX_PLAN_CLI).
    export CODEX_PLAN_CLI="$CODEX_CLI"
  elif [[ -z "${CODEX_PLAN_CLI:-}" ]] && command -v codex &>/dev/null; then
    # Default binary on PATH when CODEX_CLI and CODEX_PLAN_CLI were unset.
    export CODEX_PLAN_CLI="codex"
  fi

  if [[ -n "${SELECTED_MODEL:-}" && "$SELECTED_MODEL" != "auto" ]]; then
    # Model id for codex exec; empty means runtime default.
    export CODEX_PLAN_MODEL="$SELECTED_MODEL"
  elif [[ -z "${CODEX_PLAN_MODEL:-}" ]]; then
    # Explicit empty tells the wrapper to omit model override (use Codex default).
    export CODEX_PLAN_MODEL=""
  fi
  export CODEX_PLAN_SANDBOX
  export CODEX_PLAN_DANGEROUSLY_BYPASS_APPROVALS_AND_SANDBOX

  # Use RALPH_MODE and RALPH_AGENT_TOOL_ACCESS to determine MCP injection behavior
  local _ralph_mode="${RALPH_MODE:-no}"
  local _ralph_mcp_active=0
  if [[ "$_ralph_mode" == "ralph" || "$_ralph_mode" == "hybrid" || "${RALPH_AGENT_TOOL_ACCESS:-}" == "ralph" ]]; then
    _ralph_mcp_active=1
  fi
  local _agent_mcp_present=0
  if [[ -n "${RALPH_RUNTIME_MCP_AGENT_ENTRIES_JSON:-}" && "${RALPH_RUNTIME_MCP_AGENT_ENTRIES_JSON}" != "[]" ]]; then
    _agent_mcp_present=1
  fi
  local _resolver_catalog_present=0
  if [[ -n "${RALPH_RUNTIME_MCP_RESOLVE_PATH:-}" && -f "$RALPH_RUNTIME_MCP_RESOLVE_PATH" ]]; then
    _resolver_catalog_present=1
  fi
  local _mcp_overlay_required=0
  if [[ "$_ralph_mcp_active" == "1" || "$_agent_mcp_present" == "1" || "$_resolver_catalog_present" == "1" ]]; then
    _mcp_overlay_required=1
  fi
  local codex_mcp_config_path=""
  local codex_mcp_effective_catalog=0
  if [[ "$_mcp_overlay_required" == "1" ]]; then
    local codex_cli_for_caps="${CODEX_PLAN_CLI:-${CODEX_CLI:-codex}}"
    if [[ "$_ralph_mcp_active" == "1" ]]; then
      local codex_missing_capabilities
      codex_missing_capabilities="$(_run_plan_invoke_codex_proxy_capability_missing "$codex_cli_for_caps")"
      if [[ -n "$codex_missing_capabilities" ]]; then
        local codex_missing_list
        codex_missing_list="$(printf '%s' "$codex_missing_capabilities" | paste -sd ', ' -)"
        echo "Error: RALPH_MODE=$_ralph_mode is unsupported because this Codex CLI is missing: ${codex_missing_list}. Use --ralph-mode native or --ralph-mode no." >&2
        return 1
      fi
    fi
    if ! run_plan_invoke_codex_mcp_config_prepare; then
      return 1
    fi
    codex_mcp_config_path="$CODEX_PLAN_MCP_CONFIG_PATH"
    # The resolver emits a Codex-native `mcp_servers` catalog; the Ralph-only
    # fallback generator emits a Claude-shaped `mcpServers` document. Pick the
    # serializer that matches the catalog shape so required-field validation and
    # per-run --config overrides stay accurate for both paths.
    if jq -e '.mcp_servers // empty' "$codex_mcp_config_path" >/dev/null 2>&1; then
      codex_mcp_effective_catalog=1
    fi

    local validation_error
    local -a validation_values=()
    if [[ "$codex_mcp_effective_catalog" == "1" ]]; then
      while IFS= read -r line; do
        validation_values+=("$line")
      done < <(_run_plan_invoke_codex_mcp_print_effective_config_values "$codex_mcp_config_path" 0 0 0 "") || {
        run_plan_invoke_codex_mcp_config_cleanup
        return 1
      }
    else
      while IFS= read -r line; do
        validation_values+=("$line")
      done < <(_run_plan_invoke_codex_mcp_print_proxy_config_values "$codex_mcp_config_path" 0 0) || {
        run_plan_invoke_codex_mcp_config_cleanup
        return 1
      }
    fi
    validation_error="$(_run_plan_invoke_codex_mcp_probe_config_values "$codex_cli_for_caps" "${validation_values[@]}")"
    if [[ -n "$validation_error" ]]; then
      echo "Error: Codex MCP strict-config validation failed before model invocation:" >&2
      echo "$validation_error" >&2
      if grep -qE 'unknown configuration field.*mcp_servers\.[a-zA-Z_]+\.(enabled|command|args|env\.|url|headers\.)' <<<"$validation_error"; then
        local unsupported_field
        unsupported_field="$(grep -oE 'mcp_servers\.[a-zA-Z_]+\.[a-zA-Z_\.]+' <<<"$validation_error" | head -1)"
        echo "Error: unsupported required field: $unsupported_field" >&2
      fi
      run_plan_invoke_codex_mcp_config_cleanup
      return 1
    fi

    if declare -F ralph_run_plan_log >/dev/null 2>&1; then
      ralph_run_plan_log "Codex Ralph MCP: strict-config validation succeeded for required fields"
    fi

    if declare -F runtime_overlay_set_mcp_effective >/dev/null 2>&1; then
      runtime_overlay_set_mcp_effective "true"
    fi
    if declare -F runtime_overlay_set_proxy_shell_compact_effective >/dev/null 2>&1; then
      case "${RALPH_PROXY_SHELL_COMPACT:-}" in
        1 | true | yes | on)
          runtime_overlay_set_proxy_shell_compact_effective "true"
          ;;
        *)
          runtime_overlay_set_proxy_shell_compact_effective "false"
          ;;
      esac
    fi
  elif declare -F runtime_overlay_set_mcp_effective >/dev/null 2>&1; then
    runtime_overlay_set_mcp_effective "false"
    if declare -F runtime_overlay_set_proxy_shell_compact_effective >/dev/null 2>&1; then
      runtime_overlay_set_proxy_shell_compact_effective "false"
    fi
  fi

  run_plan_invoke_codex_native_hooks_prepare

  local -a _codex_structured_output_args=()
  run_plan_invoke_common_add_structured_output_flag _codex_structured_output_args codex "${CODEX_PLAN_CLI:-${CODEX_CLI:-codex}}"

  run_plan_invoke_codex_cli() {
    local cli="${CODEX_PLAN_CLI:-${CURSOR_PLAN_CLI:-codex}}"
    local sandbox="${CODEX_PLAN_SANDBOX:-workspace-write}"
    local -a args=()

    case "$sandbox" in
      read-only|workspace-write|danger-full-access)
        ;;
      *)
        echo "Error: CODEX_PLAN_SANDBOX must be one of read-only, workspace-write, or danger-full-access." >&2
        return 2
        ;;
    esac

    local resume_bare=0
    local resume_session=0
    if [[ "${RALPH_RUN_PLAN_RESUME_BARE:-0}" == "1" ]] && [[ "${RALPH_PLAN_ALLOW_UNSAFE_RESUME:-0}" == "1" ]]; then
      resume_bare=1
    elif [[ -n "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]]; then
      resume_session=1
    fi

    if [[ "$resume_bare" == "1" ]]; then
      args=(exec resume --last -c "sandbox_mode=\"$sandbox\"")
    elif [[ "$resume_session" == "1" ]]; then
      args=(exec resume -c "sandbox_mode=\"$sandbox\"")
    else
      args=(exec --sandbox "$sandbox")
    fi

    local model="${CODEX_PLAN_MODEL:-${CURSOR_PLAN_MODEL:-}}"
    if [[ -n "$model" && "$model" != "auto" ]]; then
      args+=(--model "$model")
    fi

    if ! run_plan_invoke_common_add_reasoning_effort_flag args codex "$cli"; then
      return 1
    fi
    if ((${#_codex_structured_output_args[@]} > 0)); then
      args+=("${_codex_structured_output_args[@]}")
    fi

    local global_runtime_root=""
    local user_runtime_root="${RALPH_GLOBAL_RUNTIME_HOME:-$HOME}/.codex"
    if [[ "$resume_bare" != "1" && "$resume_session" != "1" ]]; then
      if [[ "${CODEX_PLAN_NO_ADD_AGENTS_DIR:-0}" != "1" ]]; then
        local _agent_ws_abs
        _agent_ws_abs="$(cd "${RALPH_AGENT_WORKSPACE:-$WORKSPACE}" && pwd)"
        mkdir -p "$_agent_ws_abs/.ralph-workspace"
        args+=(--add-dir "$_agent_ws_abs/.ralph-workspace")
      fi
      if [[ -n "${CODEX_GLOBAL_RUNTIME_ROOT:-}" ]] && [[ -d "$CODEX_GLOBAL_RUNTIME_ROOT" ]]; then
        global_runtime_root="$CODEX_GLOBAL_RUNTIME_ROOT"
      elif [[ ! -d "$WORKSPACE/.codex" ]] && [[ -d "$user_runtime_root" ]]; then
        global_runtime_root="$user_runtime_root"
      fi
      if [[ -n "$global_runtime_root" ]]; then
        args+=(--add-dir "$global_runtime_root")
      fi
    fi

    if [[ "${CODEX_PLAN_DANGEROUSLY_BYPASS_APPROVALS_AND_SANDBOX:-0}" == "1" ]]; then
      args+=(--dangerously-bypass-approvals-and-sandbox)
    fi

    # Codex refuses to start when the working root is not inside a git repo,
    # unless --skip-git-repo-check is passed. Ralph workspaces are frequently a
    # parent dir holding several sibling repos (a lib, an API, client apps)
    # rather than a repo itself, which trips this guard before the agent runs a
    # single turn ("Not inside a trusted directory and --skip-git-repo-check was
    # not specified."). Auto-add the flag when WORKSPACE is not inside a work
    # tree. CODEX_PLAN_SKIP_GIT_REPO_CHECK=1 forces it on, =0 forces it off.
    # Accepted on both plain `exec` and `exec resume`.
    case "${CODEX_PLAN_SKIP_GIT_REPO_CHECK:-auto}" in
      1)
        args+=(--skip-git-repo-check)
        ;;
      0)
        :
        ;;
      *)
        if ! git -C "$WORKSPACE" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
          args+=(--skip-git-repo-check)
        fi
        ;;
    esac

    _run_plan_invoke_codex_append_add_dirs args "${CODEX_PLAN_EXTRA_ADD_DIRS:-}"

    if [[ -n "$codex_mcp_config_path" ]]; then
      if [[ "$codex_mcp_effective_catalog" == "1" ]]; then
        if ! _run_plan_invoke_codex_add_effective_config_args args "$codex_mcp_config_path" "$cli"; then
          echo "Error: failed to build Codex effective MCP config overrides." >&2
          return 1
        fi
      else
        if ! _run_plan_invoke_codex_add_proxy_config_args args "$codex_mcp_config_path" "$cli"; then
          echo "Error: failed to build Codex Ralph MCP config overrides." >&2
          return 1
        fi
      fi
      args+=(--strict-config)
      if declare -F ralph_run_plan_log >/dev/null 2>&1; then
        ralph_run_plan_log "Codex Ralph MCP: injecting ephemeral config (--strict-config)"
      fi
    fi

    if [[ "${CODEX_PLAN_NATIVE_HOOKS_ACTIVE:-0}" == "1" ]]; then
      if ! _run_plan_invoke_codex_append_native_hook_config_args args; then
        echo "Error: failed to build Codex native hook config overrides." >&2
        return 1
      fi
      if [[ "${CODEX_PLAN_NATIVE_HOOKS_BYPASS_TRUST:-0}" == "1" ]]; then
        args+=(--dangerously-bypass-hook-trust)
      fi
      if declare -F ralph_run_plan_log >/dev/null 2>&1; then
        ralph_run_plan_log "Codex native hooks: injecting per-run hook config (--config)"
      fi
    fi

    if [[ "${RALPH_PLAN_CLI_RESUME:-0}" == "1" || "${RALPH_PLAN_CAPTURE_USAGE:-1}" == "1" ]]; then
      args+=(--json)
    fi

    if [[ -n "${CODEX_PLAN_EXEC_EXTRA:-}" ]]; then
      read -r -a extra_args <<< "${CODEX_PLAN_EXEC_EXTRA}"
      if [[ ${#extra_args[@]} -gt 0 ]]; then
        args+=("${extra_args[@]}")
      fi
    fi

    if [[ "$resume_session" == "1" ]]; then
      args+=("${RALPH_RUN_PLAN_RESUME_SESSION_ID}")
    fi

    args+=("$PROMPT")

    cd "$WORKSPACE" || {
      return 1
    }
    local cli_pid
    "$cli" "${args[@]}" &
    cli_pid=$!
    run_plan_invoke_common_record_cli_pid "$cli_pid"
    wait "$cli_pid"
  }

  run_plan_invoke_common_execute \
    run_plan_invoke_codex_cli \
    codex \
    "Warning: RALPH_PLAN_CLI_RESUME needs python3 to parse --json and update session-id.codex.txt; running without it."

  if [[ -n "$codex_mcp_config_path" ]]; then
    run_plan_invoke_codex_mcp_config_cleanup
  fi
  run_plan_invoke_codex_native_hooks_cleanup

  if declare -F runtime_overlay_write_summary >/dev/null 2>&1; then
    runtime_overlay_write_summary || true
  fi
}

# Direct execution: when invoked as a script (not sourced), treat $1 as prompt
# file and $2 as workspace, then run the canonical invoke function.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ -n "${1:-}" ]]; then
    PROMPT="$(cat "$1")"
  fi
  if [[ -n "${2:-}" ]]; then
    WORKSPACE="$2"
  fi
  export PROMPT WORKSPACE
  ralph_run_plan_invoke_codex
fi
