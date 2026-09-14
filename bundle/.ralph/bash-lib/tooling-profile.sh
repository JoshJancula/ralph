#!/usr/bin/env bash
# Named tooling-profile resolver.
#
# Loads env overlays from bundle/.ralph/tooling-profiles.json and degrades
# them per runtime using the static delivery contract in
# bash-lib/graph/graph-runtime-capabilities.sh. This file never invents a
# runtime matrix of its own: every supported/unsupported decision comes from
# graph_runtime_tooling_profile_capabilities.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

if [[ -n "${RALPH_TOOLING_PROFILE_LOADED:-}" ]]; then
  return 0
fi
RALPH_TOOLING_PROFILE_LOADED=1

_RALPH_TOOLING_PROFILE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RALPH_TOOLING_PROFILE_JSON_PATH="${RALPH_TOOLING_PROFILE_JSON_PATH:-$_RALPH_TOOLING_PROFILE_LIB_DIR/../tooling-profiles.json}"

# shellcheck source=./graph/graph-runtime-capabilities.sh
source "$_RALPH_TOOLING_PROFILE_LIB_DIR/graph/graph-runtime-capabilities.sh"

# ralph_tooling_profile_names
# Prints the valid profile names, one per line.
ralph_tooling_profile_names() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required for ralph_tooling_profile_names" >&2
    return 1
  fi
  jq -r '.profiles | keys[]' "$RALPH_TOOLING_PROFILE_JSON_PATH"
}

# ralph_tooling_profile_validate <name>
# Exit 0 when <name> is a known profile, 1 otherwise.
ralph_tooling_profile_validate() {
  local name="${1-}"
  [[ -n "$name" ]] || return 1
  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required for ralph_tooling_profile_validate" >&2
    return 1
  fi
  jq -e --arg name "$name" '.profiles | has($name)' "$RALPH_TOOLING_PROFILE_JSON_PATH" >/dev/null 2>&1
}

# ralph_tooling_profile_env <name> <runtime>
# Prints KEY=VALUE lines for the resolved env overlay, one per line, suitable
# for use as an `env` prefix. Always emits RALPH_TOOLING_PROFILE=<name>.
# Drops any profile env var the runtime cannot deliver per the static
# capability contract, and emits a RALPH_TOOLING_PROFILE_DEGRADED line
# listing the dropped keys (sorted) when anything was dropped. An unknown
# profile name is a hard error to stderr with exit 1.
ralph_tooling_profile_env() {
  local name="${1-}" runtime="${2-}"

  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required for ralph_tooling_profile_env" >&2
    return 1
  fi

  if ! ralph_tooling_profile_validate "$name"; then
    echo "Error: unknown tooling profile '${name}'" >&2
    return 1
  fi

  local normalized_runtime
  normalized_runtime="$(graph_runtime_normalize_runtime "$runtime")"

  local capabilities_json
  capabilities_json="$(graph_runtime_tooling_profile_capabilities "$normalized_runtime")"

  local profile_keys_json
  profile_keys_json="$(jq -c --arg name "$name" '.profiles[$name].env' "$RALPH_TOOLING_PROFILE_JSON_PATH")"

  local key value dropped_keys=""
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    value="$(printf '%s' "$profile_keys_json" | jq -r --arg k "$key" '.[$k]')"
    if graph_runtime_tooling_profile_key_is_supported "$capabilities_json" "$key"; then
      printf '%s=%s\n' "$key" "$value"
    else
      if [[ -z "$dropped_keys" ]]; then
        dropped_keys="$key"
      else
        dropped_keys="$dropped_keys
$key"
      fi
    fi
  done < <(printf '%s' "$profile_keys_json" | jq -r 'keys[]')

  if [[ -n "$dropped_keys" ]]; then
    local sorted_dropped
    sorted_dropped="$(printf '%s\n' "$dropped_keys" | sort | paste -sd ',' -)"
    printf 'RALPH_TOOLING_PROFILE_DEGRADED=%s\n' "$sorted_dropped"
  fi

  printf 'RALPH_TOOLING_PROFILE=%s\n' "$name"
}
