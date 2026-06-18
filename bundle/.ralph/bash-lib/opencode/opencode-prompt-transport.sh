#!/usr/bin/env bash
# OpenCode prompt transport (PLAN25 Phase 10): move PROMPT_STATIC to a Ralph-owned
# file under .ralph-workspace/artifacts/<ns>/opencode-static-context.md and pass it
# via `opencode run --file`. Project AGENTS.md and user opencode.json are never edited.
#
# Env:
#   RALPH_OPENCODE_PROMPT_TRANSPORT=0     disable file transport (baseline inline append)
#   RALPH_OPENCODE_PROMPT_TRANSPORT=1     enable when prerequisites pass (default)
#
# Resolve modes (ralph_opencode_prompt_transport_resolve):
#   file    --file + dynamic user prompt only
#   inline  append PROMPT_STATIC to user prompt (fallback)
#   passthrough -- no static content

if [[ -n "${RALPH_OPENCODE_PROMPT_TRANSPORT_LOADED:-}" ]]; then
  return 0
fi
RALPH_OPENCODE_PROMPT_TRANSPORT_LOADED=1

_opencode_prompt_transport_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_opencode_prompt_transport_dir/opencode-cache-config.sh"
unset _opencode_prompt_transport_dir

# Ralph-owned static context (documented cacheable channel; project rules still win via OpenCode load order).
ralph_opencode_static_artifact_path() {
  local workspace_root="${1:-}"
  local artifact_ns="${2:-${RALPH_ARTIFACT_NS:-${RALPH_PLAN_KEY:-}}}"
  [[ -n "$artifact_ns" ]] || return 1
  if [[ -n "$workspace_root" ]]; then
    printf '%s/.ralph-workspace/artifacts/%s/opencode-static-context.md' \
      "$workspace_root" "$artifact_ns"
    return 0
  fi
  if [[ -n "${RALPH_PLAN_WORKSPACE_ROOT:-}" ]]; then
    printf '%s/artifacts/%s/opencode-static-context.md' \
      "$RALPH_PLAN_WORKSPACE_ROOT" "$artifact_ns"
    return 0
  fi
  if [[ -n "${WORKSPACE:-}" ]]; then
    printf '%s/.ralph-workspace/artifacts/%s/opencode-static-context.md' \
      "$WORKSPACE" "$artifact_ns"
    return 0
  fi
  return 1
}

ralph_opencode_prompt_transport_enabled() {
  case "${RALPH_OPENCODE_PROMPT_TRANSPORT:-1}" in
    0|false|FALSE|no|NO|off|OFF) return 1 ;;
    *) return 0 ;;
  esac
}

ralph_opencode_cli_supports_file_flag() {
  local cli="${1:-}"
  [[ -n "$cli" ]] || return 1
  if ! command -v "$cli" &>/dev/null; then
    return 1
  fi
  local help_out=""
  help_out="$("$cli" run --help 2>&1)" || help_out="$("$cli" --help 2>&1)" || return 1
  grep -qE '(^|[[:space:]])--file([[:space:]=,]|$)' <<<"$help_out"
}

ralph_opencode_prompt_transport_cache_config_confirmed() {
  ralph_opencode_cache_config_confirmed
}

# Idempotent write: skip rewrite when content unchanged.
ralph_opencode_prompt_transport_write_static() {
  local path="$1"
  local content="$2"
  local dir
  dir="$(dirname "$path")"
  if ! mkdir -p "$dir" 2>/dev/null; then
    return 1
  fi
  if [[ -f "$path" ]]; then
    local existing=""
    existing="$(<"$path")" || return 1
    if [[ "$existing" == "$content" || "$existing" == "${content}"$'\n' ]]; then
      return 0
    fi
  fi
  printf '%s\n' "$content" >"$path"
}

# Prints: file | inline | passthrough
ralph_opencode_prompt_transport_resolve() {
  local cli="${1:-}"
  local static="${2:-}"

  if [[ -z "$static" ]]; then
    printf '%s' passthrough
    return 0
  fi
  if ! ralph_opencode_prompt_transport_enabled; then
    # run-plan-core already appended PROMPT_STATIC to PROMPT when transport is off.
    printf '%s' passthrough
    return 0
  fi
  if ! ralph_opencode_cli_supports_file_flag "$cli"; then
    printf '%s' inline
    return 0
  fi

  local static_path=""
  if ! static_path="$(ralph_opencode_static_artifact_path)"; then
    printf '%s' inline
    return 0
  fi
  if ! ralph_opencode_prompt_transport_write_static "$static_path" "$static"; then
    printf '%s' inline
    return 0
  fi

  printf '%s' file
}

ralph_opencode_prompt_transport_log_mode() {
  local mode="$1"
  local static_path="${2:-}"
  case "$mode" in
    file)
      ralph_run_plan_log "opencode prompt transport: static via --file $static_path (project instructions retain precedence)"
      if ! ralph_opencode_prompt_transport_cache_config_confirmed; then
        ralph_run_plan_log "opencode prompt transport: setCacheKey not confirmed in opencode.json; provider cache may be limited (file transport still reduces user-prompt bytes)"
      fi
      ;;
    inline)
      ralph_run_plan_log "opencode prompt transport: fallback inline PROMPT_STATIC in user prompt"
      ;;
    passthrough)
      :
      ;;
  esac
}
