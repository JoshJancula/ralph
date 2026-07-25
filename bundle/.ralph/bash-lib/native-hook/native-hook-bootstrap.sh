#!/usr/bin/env bash
# Bootstrap native runtime hooks when project-local .ralph/ is absent.
# Resolves and sources native-hook-lib.sh from the project tree or $RALPH_HOME.

if [[ -n "${RALPH_NATIVE_HOOK_BOOTSTRAP_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
RALPH_NATIVE_HOOK_BOOTSTRAP_LOADED=1

ralph_native_hook_bootstrap_ralph_home() {
  if [[ -n "${RALPH_HOME:-}" ]]; then
    printf '%s\n' "$RALPH_HOME"
    return 0
  fi
  if [[ -n "${HOME:-}" ]]; then
    printf '%s/.ralph\n' "$HOME"
    return 0
  fi
  return 1
}

ralph_native_hook_bootstrap_hook_dir() {
  local caller_source="${1:-${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}}"
  cd "$(dirname "$caller_source")" && pwd
}

# Args: optional hook script path (defaults to caller's BASH_SOURCE).
# Sources native-hook-lib.sh when found; returns 1 when not found.
ralph_native_hook_bootstrap_source_lib() {
  local hook_dir ralph_home candidate
  local -a candidates=()

  hook_dir="$(ralph_native_hook_bootstrap_hook_dir "${1:-}")"
  candidates+=("$hook_dir/native-hook-lib.sh")
  candidates+=("$hook_dir/../../.ralph/bash-lib/native-hook/native-hook-lib.sh")

  ralph_home="$(ralph_native_hook_bootstrap_ralph_home 2>/dev/null || true)"
  if [[ -n "$ralph_home" ]]; then
    candidates+=("$ralph_home/bundle/.ralph/bash-lib/native-hook/native-hook-lib.sh")
  fi

  for candidate in "${candidates[@]}"; do
    if [[ -n "$candidate" && -f "$candidate" ]]; then
      # shellcheck source=/dev/null
      source "$candidate"
      return 0
    fi
  done

  return 1
}
