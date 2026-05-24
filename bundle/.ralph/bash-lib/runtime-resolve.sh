#!/usr/bin/env bash

if [[ -n "${RALPH_RUNTIME_RESOLVE_LOADED:-}" ]]; then
  return
fi
RALPH_RUNTIME_RESOLVE_LOADED=1

ralph_resolve_runtime_root() {
  local runtime="${1:-}"
  local workspace="${2:-}"

  case "$runtime" in
    cursor|claude|codex|opencode) ;;
    *)
      echo "Error: unsupported runtime: $runtime" >&2
      return 2
      ;;
  esac

  if [[ -z "$workspace" ]]; then
    echo "Error: workspace is required to resolve runtime root" >&2
    return 2
  fi

  local project_root="$workspace/.$runtime"
  if [[ -d "$project_root" ]]; then
    printf '%s\n' "$project_root"
    return 0
  fi

  if [[ "${RALPH_DISABLE_GLOBAL_FALLBACK:-0}" == "1" ]]; then
    return 1
  fi

  local user_root="${RALPH_GLOBAL_RUNTIME_HOME:-$HOME}/.$runtime"
  if [[ -d "$user_root" ]]; then
    printf '%s\n' "$user_root"
    return 0
  fi

  local bundled_root="${RALPH_HOME:-$HOME/.ralph}/bundle/.$runtime"
  if [[ -d "$bundled_root" ]]; then
    printf '%s\n' "$bundled_root"
    return 0
  fi

  return 1
}
