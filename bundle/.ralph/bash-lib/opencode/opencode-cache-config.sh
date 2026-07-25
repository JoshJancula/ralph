#!/usr/bin/env bash
# Read-only OpenCode setCacheKey validation (never edits opencode.json).
#
# Public:
#   ralph_opencode_cache_config_status  -- prints confirmed|unconfirmed|indeterminate
#   ralph_opencode_cache_config_confirmed -- exit 0 when confirmed
#   ralph_check_opencode_cache_config   -- stderr warnings; always returns 0

if [[ -n "${RALPH_OPENCODE_CACHE_CONFIG_LOADED:-}" ]]; then
  return 0
fi
RALPH_OPENCODE_CACHE_CONFIG_LOADED=1

_opencode_cache_config_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_OPENCODE_CACHE_CONFIG_VALIDATOR="$_opencode_cache_config_dir/opencode-cache-config-validator.py"
unset _opencode_cache_config_dir

_ralph_opencode_cache_config_query() {
  local workspace="${1:-${WORKSPACE:-}}"
  local -a py_args=()
  if [[ -n "$workspace" ]]; then
    py_args+=(--workspace "$workspace")
  fi
  if [[ ! -f "$_OPENCODE_CACHE_CONFIG_VALIDATOR" ]]; then
    printf '%s\n' "status=indeterminate"
    printf '%s\n' "reason=validator script missing"
    return 2
  fi
  python3 "$_OPENCODE_CACHE_CONFIG_VALIDATOR" "${py_args[@]}" 2>/dev/null
}

ralph_opencode_cache_config_status() {
  local out status
  out="$(_ralph_opencode_cache_config_query "$@")" || true
  status="$(printf '%s\n' "$out" | awk -F= '/^status=/ { print $2; exit }')"
  if [[ -z "$status" ]]; then
    printf '%s' indeterminate
    return 0
  fi
  printf '%s' "$status"
}

ralph_opencode_cache_config_confirmed() {
  [[ "$(ralph_opencode_cache_config_status "$@")" == confirmed ]]
}

ralph_check_opencode_cache_config() {
  local out status reason sources_line
  out="$(_ralph_opencode_cache_config_query)" || true
  status="$(printf '%s\n' "$out" | awk -F= '/^status=/ { print $2; exit }')"
  reason="$(printf '%s\n' "$out" | awk -F= '/^reason=/ { print substr($0, index($0, "=") + 1); exit }')"
  sources_line="$(printf '%s\n' "$out" | awk -F= '/^sources=/ { print substr($0, index($0, "=") + 1); exit }')"

  case "${status:-indeterminate}" in
    confirmed)
      return 0
      ;;
    unconfirmed)
      echo "Warning: setCacheKey not confirmed in effective OpenCode config (${reason:-checked provider merge})." >&2
      echo "Add setCacheKey: true under provider options in opencode.json (project config overrides ~/.config/opencode/). Ralph does not modify your OpenCode config." >&2
      if [[ -n "$sources_line" ]]; then
        echo "Checked: ${sources_line//|/, }" >&2
      fi
      ;;
    *)
      echo "Warning: cannot confirm OpenCode caching prerequisites (${reason:-no readable config})." >&2
      echo "Provider cache may be limited until setCacheKey is set in opencode.json. Ralph does not modify your OpenCode config." >&2
      if [[ -n "$sources_line" ]]; then
        echo "Partially checked: ${sources_line//|/, }" >&2
      fi
      ;;
  esac
  return 0
}
