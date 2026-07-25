#!/usr/bin/env bash
#
# Classic config.json adapter -- thin wrapper over existing parse-json.sh.
#
# Public interface:
#   agent_adapter_classic_config_resolve <name> <runtime> <workspace>
#     Prints "classic-config<TAB><path>" and exits 0.
#     The path is the existing config.json discovered through runtime root
#     resolution (project, global, bundle fallback).
#
#   agent_adapter_classic_config_to_config_json <name> <runtime> <workspace> <cache_dir>
#     Validates the classic config.json and copies it into <cache_dir>/<name>.config.json.
#     Prints the cache path and exits 0.
#
# No behavior change: classic-config sources are already config.json files.
# This adapter exists so the resolver dispatch table has a uniform interface.

if [[ -n "${RALPH_ADAPTER_CLASSIC_CONFIG_LOADED:-}" ]]; then
  return 0
fi
RALPH_ADAPTER_CLASSIC_CONFIG_LOADED=1

_adapters_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
source "$_adapters_dir/../../runtime-normalize.sh"
# shellcheck source=/dev/null
source "$_adapters_dir/../../runtime-resolve.sh"
# shellcheck source=/dev/null
source "$_adapters_dir/../../agent-config/parse-json.sh"
# shellcheck source=/dev/null
source "$_adapters_dir/../../agent-config/validate.sh"

agent_adapter_classic_config_resolve() {
  local name="${1:-}"
  local runtime="${2:-}"
  local workspace="${3:-}"

  if [[ -z "$name" || -z "$runtime" || -z "$workspace" ]]; then
    echo "Error: name, runtime, and workspace are required" >&2
    return 2
  fi

  local runtime_root
  runtime_root="$(ralph_resolve_runtime_root "$runtime" "$workspace" 2>/dev/null)" || runtime_root=""

  if [[ -n "$runtime_root" && -r "$runtime_root/agents/$name/config.json" ]]; then
    printf 'classic-config\t%s\n' "$runtime_root/agents/$name/config.json"
    return 0
  fi

  echo "Error: classic config not found for '$name' (runtime=$runtime)" >&2
  return 1
}

agent_adapter_classic_config_to_config_json() {
  local name="${1:-}"
  local runtime="${2:-}"
  local workspace="${3:-}"
  local cache_dir="${4:-}"

  if [[ -z "$name" || -z "$runtime" || -z "$workspace" || -z "$cache_dir" ]]; then
    echo "Error: name, runtime, workspace, and cache_dir are required" >&2
    return 2
  fi

  local runtime_root agents_root src dest
  runtime_root="$(ralph_resolve_runtime_root "$runtime" "$workspace" 2>/dev/null)" || runtime_root=""

  if [[ -z "$runtime_root" ]]; then
    echo "Error: could not resolve runtime root for '$runtime'" >&2
    return 1
  fi

  agents_root="$runtime_root/agents"
  src="$agents_root/$name/config.json"

  if [[ ! -r "$src" ]]; then
    echo "Error: classic config not found: $src" >&2
    return 1
  fi

  validate_config "$agents_root" "$name" >/dev/null || {
    echo "Error: classic config validation failed for '$name'" >&2
    return 1
  }

  mkdir -p "$cache_dir"
  dest="$cache_dir/$name.config.json"
  cp "$src" "$dest"
  printf '%s\n' "$dest"
}