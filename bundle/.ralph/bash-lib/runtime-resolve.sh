#!/usr/bin/env bash

if [[ -n "${RALPH_RUNTIME_RESOLVE_LOADED:-}" ]]; then
  return
fi
RALPH_RUNTIME_RESOLVE_LOADED=1

if ! declare -F ralph_normalize_runtime_name >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/runtime-normalize.sh"
fi

ralph_resolve_runtime_root() {
  local runtime="${1:-}"
  local workspace="${2:-}"
  runtime="$(ralph_normalize_runtime_name "$runtime")"

  case "$runtime" in
    cursor|claude|codex|opencode|antigravity) ;;
    *)
      echo "Error: unsupported runtime: $runtime" >&2
      return 2
      ;;
  esac

  if [[ -z "$workspace" ]]; then
    echo "Error: workspace is required to resolve runtime root" >&2
    return 2
  fi

  local config_dir
  config_dir="$(ralph_runtime_config_dirname "$runtime")"

  local project_root="$workspace/$config_dir"
  if [[ -d "$project_root" ]]; then
    printf '%s\n' "$project_root"
    return 0
  fi

  if [[ "${RALPH_DISABLE_GLOBAL_FALLBACK:-0}" == "1" ]]; then
    return 1
  fi

  local user_root="${RALPH_GLOBAL_RUNTIME_HOME:-$HOME}/$config_dir"
  if [[ -d "$user_root" ]]; then
    printf '%s\n' "$user_root"
    return 0
  fi

  local bundled_root="${RALPH_HOME:-$HOME/.ralph}/bundle/$config_dir"
  if [[ -d "$bundled_root" ]]; then
    printf '%s\n' "$bundled_root"
    return 0
  fi

  return 1
}

# Resolve the select-model library for a runtime.
# Precedence: project .ralph/bash-lib > global RALPH_HOME install > bundle fallback
# (bundle_ralph_dir) > deprecated .<runtime>/ralph/select-model.sh thin wrapper.
# Args: $1 runtime, $2 workspace, $3 optional bundle .ralph dir (e.g. SCRIPT_DIR from run-plan)
# Returns: prints readable script path, 0 on success, 1 when not found, 2 on bad runtime.
ralph_select_model_script() {
  local runtime="${1:-}"
  local workspace="${2:-}"
  local bundle_ralph="${3:-}"
  local lib_name="select-model-${runtime}.sh"
  local candidate runtime_root

  runtime="$(ralph_normalize_runtime_name "$runtime")"
  lib_name="select-model-${runtime}.sh"

  case "$runtime" in
    cursor|claude|codex|opencode|antigravity) ;;
    *)
      echo "Error: unsupported runtime: $runtime" >&2
      return 2
      ;;
  esac

  if [[ -n "$workspace" ]]; then
    for candidate in \
      "$workspace/.ralph/bash-lib/select-model/$lib_name" \
      "$workspace/.ralph/bash-lib/$lib_name"; do
      if [[ -r "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done
  fi

  if [[ -n "${RALPH_HOME:-}" ]]; then
    for candidate in \
      "${RALPH_HOME}/bundle/.ralph/bash-lib/select-model/$lib_name" \
      "${RALPH_HOME}/bundle/.ralph/bash-lib/$lib_name" \
      "${RALPH_HOME}/.ralph/bash-lib/select-model/$lib_name" \
      "${RALPH_HOME}/.ralph/bash-lib/$lib_name" \
      "${RALPH_HOME}/bash-lib/select-model/$lib_name" \
      "${RALPH_HOME}/bash-lib/$lib_name"; do
      if [[ -r "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done
  fi

  if [[ -z "$bundle_ralph" ]]; then
    bundle_ralph="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  fi
  for candidate in \
    "$bundle_ralph/bash-lib/select-model/$lib_name" \
    "$bundle_ralph/bash-lib/$lib_name"; do
    if [[ -r "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  if [[ -n "$workspace" ]]; then
    runtime_root="$(ralph_resolve_runtime_root "$runtime" "$workspace" 2>/dev/null || true)"
    if [[ -n "$runtime_root" ]]; then
      candidate="$runtime_root/ralph/select-model.sh"
      if [[ -r "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    fi
  fi

  return 1
}
