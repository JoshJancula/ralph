#!/usr/bin/env bash

if [[ -n "${RALPH_RUN_PLAN_REASONING_EFFORT_LOADED:-}" ]]; then
  return
fi
RALPH_RUN_PLAN_REASONING_EFFORT_LOADED=1

# Portable reasoning-effort values for agent frontmatter and orchestration stages.
RALPH_REASONING_EFFORT_PORTABLE_VALUES=(low medium high xhigh max inherit)

# Rollout gate for per-agent/stage reasoning effort mapping.
# Ralph/hybrid mode enables it unless RALPH_REASONING_EFFORT=0.
# Native/no mode leaves it disabled unless RALPH_REASONING_EFFORT=1.
ralph_run_plan_reasoning_effort_enabled() {
  local gate="${RALPH_REASONING_EFFORT:-}"
  if [[ -n "$gate" ]]; then
    case "$gate" in
      0) return 1 ;;
      1) return 0 ;;
      *)
        if declare -F ralph_run_plan_log >/dev/null 2>&1; then
          ralph_run_plan_log "RALPH_REASONING_EFFORT: invalid value '$gate' (use 0 or 1)"
        fi
        echo "RALPH_REASONING_EFFORT: invalid value '$gate' (use 0 or 1)" >&2
        return 2
        ;;
    esac
  fi
  case "${RALPH_MODE:-no}" in
    ralph|hybrid) return 0 ;;
    *) return 1 ;;
  esac
}

ralph_reasoning_effort_portable_valid() {
  local value="${1:-}"
  local allowed
  for allowed in "${RALPH_REASONING_EFFORT_PORTABLE_VALUES[@]}"; do
    if [[ "$value" == "$allowed" ]]; then
      return 0
    fi
  done
  return 1
}

ralph_reasoning_effort_runtime_env_name() {
  local runtime="$1"
  case "$runtime" in
    claude) printf '%s' "CLAUDE_PLAN_REASONING_EFFORT" ;;
    codex) printf '%s' "CODEX_PLAN_REASONING_EFFORT" ;;
    cursor) printf '%s' "CURSOR_PLAN_REASONING_EFFORT" ;;
    opencode) printf '%s' "OPENCODE_PLAN_REASONING_EFFORT" ;;
    antigravity) printf '%s' "ANTIGRAVITY_PLAN_REASONING_EFFORT" ;;
    *) return 1 ;;
  esac
}

ralph_reasoning_effort_runtime_env_value() {
  local runtime="$1"
  case "$runtime" in
    claude) printf '%s' "${CLAUDE_PLAN_REASONING_EFFORT:-}" ;;
    codex) printf '%s' "${CODEX_PLAN_REASONING_EFFORT:-}" ;;
    cursor) printf '%s' "${CURSOR_PLAN_REASONING_EFFORT:-}" ;;
    opencode) printf '%s' "${OPENCODE_PLAN_REASONING_EFFORT:-${CURSOR_PLAN_REASONING_EFFORT:-}}" ;;
    antigravity)
      if [[ -n "${ANTIGRAVITY_PLAN_REASONING_EFFORT:-}" ]]; then
        printf '%s' "${ANTIGRAVITY_PLAN_REASONING_EFFORT}"
      elif [[ -n "${OPENCODE_PLAN_REASONING_EFFORT:-}" ]]; then
        printf '%s' "${OPENCODE_PLAN_REASONING_EFFORT}"
      else
        printf '%s' "${CURSOR_PLAN_REASONING_EFFORT:-}"
      fi
      ;;
    *) return 1 ;;
  esac
}

# Precedence: CLI --reasoning-effort > runtime env (includes orchestration stage) > agent config > inherit.
ralph_resolve_reasoning_effort() {
  local runtime="$1"
  local agent_effort="${2:-}"
  local cli_effort="${PLAN_REASONING_EFFORT_CLI:-}"
  local env_effort=""

  env_effort="$(ralph_reasoning_effort_runtime_env_value "$runtime" 2>/dev/null || true)"

  if [[ -n "$cli_effort" ]]; then
    printf '%s\n' "$cli_effort"
    return 0
  fi
  if [[ -n "$env_effort" ]]; then
    printf '%s\n' "$env_effort"
    return 0
  fi
  if [[ -n "$agent_effort" ]]; then
    printf '%s\n' "$agent_effort"
    return 0
  fi
  printf '%s\n' "inherit"
}

ralph_validate_reasoning_effort_config() {
  local value="${1:-}"
  local label="${2:-reasoning_effort}"
  if [[ -z "$value" ]]; then
    return 0
  fi
  if ralph_reasoning_effort_portable_valid "$value"; then
    return 0
  fi
  echo "Error: $label must be one of: low, medium, high, xhigh, max, inherit (got '$value')." >&2
  return 1
}

_run_plan_reasoning_effort_log_unsupported_once() {
  local runtime="$1"
  local var="_RALPH_REASONING_EFFORT_UNSUPPORTED_LOGGED_${runtime}"
  if [[ -n "${!var:-}" ]]; then
    return 0
  fi
  printf -v "$var" '%s' 1
  if declare -F ralph_run_plan_log >/dev/null 2>&1; then
    ralph_run_plan_log "reasoning_effort: no native control for runtime=$runtime; using inherit"
  fi
  echo "Note: reasoning_effort is not supported by the $runtime adapter; using inherit." >&2
}

_run_plan_invoke_claude_effort_supported() {
  local cli_name="${1:-claude}"
  local help=""
  if ! help="$("$cli_name" --help 2>/dev/null)"; then
    return 1
  fi
  [[ "$help" == *"--effort"* ]]
}

_run_plan_invoke_claude_effort_values_supported() {
  local cli_name="${1:-claude}"
  local help=""
  if ! help="$("$cli_name" --help 2>/dev/null)"; then
    printf '%s\n' "low medium high xhigh max"
    return 0
  fi
  if [[ "$help" == *"xhigh"* ]]; then
    printf '%s\n' "low medium high xhigh max"
  else
    printf '%s\n' "low medium high"
  fi
}

_run_plan_invoke_claude_effort_value_supported() {
  local cli_name="$1"
  local value="$2"
  local supported
  supported="$(_run_plan_invoke_claude_effort_values_supported "$cli_name")"
  [[ " $supported " == *" $value "* ]]
}

_run_plan_invoke_codex_reasoning_effort_supported() {
  local cli_name="${1:-codex}"
  local exec_help=""
  if ! exec_help="$("$cli_name" exec --help 2>/dev/null)"; then
    return 1
  fi
  [[ "$exec_help" == *"--config"* ]] || return 1
  local err=""
  if command -v timeout >/dev/null 2>&1; then
    err="$(timeout 3 "$cli_name" -c 'model_reasoning_effort="low"' --strict-config exec '' 2>&1)" || true
  else
    err="$( "$cli_name" -c 'model_reasoning_effort="low"' --strict-config exec '' 2>&1 & pid=$!; sleep 1; kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null )" || true
  fi
  [[ "$err" != *"unknown configuration field \`model_reasoning_effort\`"* ]]
}

_run_plan_invoke_codex_append_reasoning_effort_config() {
  local args_name="$1"
  local config_value="$2"
  eval "$args_name+=(--config $(printf '%q' "$config_value"))"
}

# Append runtime-specific reasoning-effort controls when capability-detected.
# Sets RALPH_PLAN_REASONING_EFFORT_APPLIED to the CLI value or "inherit".
run_plan_invoke_common_add_reasoning_effort_flag() {
  local args_name="$1"
  local runtime="${2:-${RUNTIME:-}}"
  local cli_name="${3:-}"
  local resolved="${SELECTED_REASONING_EFFORT:-inherit}"

  RALPH_PLAN_REASONING_EFFORT_APPLIED="inherit"
  export RALPH_PLAN_REASONING_EFFORT_APPLIED

  if ! ralph_run_plan_reasoning_effort_enabled; then
    return 0
  fi

  if [[ -z "$resolved" || "$resolved" == "inherit" ]]; then
    return 0
  fi

  if ! ralph_validate_reasoning_effort_config "$resolved" "reasoning_effort"; then
    return 1
  fi

  case "$runtime" in
    claude)
      cli_name="${cli_name:-${CLAUDE_PLAN_CLI:-claude}}"
      if ! _run_plan_invoke_claude_effort_supported "$cli_name"; then
        echo "Error: reasoning_effort='$resolved' configured but Claude CLI at '$cli_name' does not expose --effort. Update Claude Code or set reasoning_effort to inherit." >&2
        return 1
      fi
      if ! _run_plan_invoke_claude_effort_value_supported "$cli_name" "$resolved"; then
        local supported
        supported="$(_run_plan_invoke_claude_effort_values_supported "$cli_name" | tr ' ' ',')"
        echo "Error: reasoning_effort='$resolved' is not supported by this Claude CLI --effort mapping (supported: $supported). Set reasoning_effort to inherit or a supported value." >&2
        return 1
      fi
      eval "$args_name+=(--effort \"\$resolved\")"
      RALPH_PLAN_REASONING_EFFORT_APPLIED="$resolved"
      export RALPH_PLAN_REASONING_EFFORT_APPLIED
      ;;
    codex)
      cli_name="${cli_name:-${CODEX_PLAN_CLI:-${CODEX_CLI:-codex}}}"
      if ! _run_plan_invoke_codex_reasoning_effort_supported "$cli_name"; then
        _run_plan_reasoning_effort_log_unsupported_once "codex"
        return 0
      fi
      _run_plan_invoke_codex_append_reasoning_effort_config "$args_name" "model_reasoning_effort=\"$resolved\""
      RALPH_PLAN_REASONING_EFFORT_APPLIED="$resolved"
      export RALPH_PLAN_REASONING_EFFORT_APPLIED
      ;;
    cursor|opencode|antigravity)
      _run_plan_reasoning_effort_log_unsupported_once "$runtime"
      ;;
    *)
      _run_plan_reasoning_effort_log_unsupported_once "$runtime"
      ;;
  esac
}
