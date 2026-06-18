#!/usr/bin/env bash
#
# Shared runtime-name normalization helpers.
#
# Public interface:
#   ralph_normalize_runtime_name <runtime> -- lowercases and maps shorthand aliases to the
#     canonical runtime name used by the runner (currently agy -> antigravity).
#   ralph_runtime_is_supported <runtime> -- returns 0 when the runtime is recognized.
#   ralph_runtime_config_dirname <runtime> -- prints the on-disk config dir name for a runtime
#     (e.g. ".agents" for antigravity, ".<runtime>" for everything else). Antigravity reads
#     project config from .agents/, not .antigravity/.

if [[ -n "${RALPH_RUNTIME_NORMALIZE_LOADED:-}" ]]; then
  return 0
fi
RALPH_RUNTIME_NORMALIZE_LOADED=1

ralph_normalize_runtime_name() {
  local runtime="${1:-}"
  runtime="$(printf '%s' "$runtime" | tr '[:upper:]' '[:lower:]' | tr -d '\r\n')"
  case "$runtime" in
    agy)
      printf '%s' "antigravity"
      ;;
    cursor|claude|codex|opencode|antigravity)
      printf '%s' "$runtime"
      ;;
    *)
      printf '%s' "$runtime"
      ;;
  esac
}

ralph_runtime_is_supported() {
  case "$(ralph_normalize_runtime_name "${1:-}")" in
    cursor|claude|codex|opencode|antigravity)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

ralph_runtime_config_dirname() {
  case "$(ralph_normalize_runtime_name "${1:-}")" in
    antigravity)
      printf '%s' ".agents"
      ;;
    *)
      printf '%s' ".$(ralph_normalize_runtime_name "${1:-}")"
      ;;
  esac
}
