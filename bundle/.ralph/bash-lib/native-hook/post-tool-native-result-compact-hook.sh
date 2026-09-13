#!/usr/bin/env bash
# Shared PostToolUse/postToolUse hook: compact native Read/Grep/Glob/SemanticSearch output
# via Ralph envelope/store (same bash path as ralph_proxy_*), without proxy policy guards.
#
# Used by Claude, Cursor, and Codex runtime hook scripts. Fail-open: never blocks.
#
# Fast path: exit before sourcing libraries when neither
# RALPH_NATIVE_RESULT_COMPACT nor RALPH_CURSOR_NATIVE_RESULT_HOOK_COMPACT is truthy.

set -uo pipefail

# Keep in sync with ralph_native_hook_result_compact_enabled (and thin wrappers).
case "${RALPH_NATIVE_RESULT_COMPACT:-}" in
  0 | false | no | off) exit 0 ;;
  1 | true | yes | on) ;;
  *)
    case "${RALPH_CURSOR_NATIVE_RESULT_HOOK_COMPACT:-}" in
      0 | false | no | off) exit 0 ;;
      1 | true | yes | on) ;;
      *) exit 0 ;;
    esac
    ;;
esac

ralph_post_tool_native_result_compact_source_libs() {
  local hook_dir bootstrap result_lib
  hook_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  bootstrap="$hook_dir/native-hook-bootstrap.sh"
  result_lib="$hook_dir/native-result-compact.sh"
  if [[ ! -f "$bootstrap" ]]; then
    bootstrap="${RALPH_HOME:-${HOME:-}/.ralph}/bundle/.ralph/bash-lib/native-hook/native-hook-bootstrap.sh"
    result_lib="${RALPH_HOME:-${HOME:-}/.ralph}/bundle/.ralph/bash-lib/native-hook/native-result-compact.sh"
  fi
  if [[ ! -f "$bootstrap" ]]; then
    return 1
  fi
  # shellcheck source=/dev/null
  source "$bootstrap"
  ralph_native_hook_bootstrap_source_lib || return 1
  if [[ -f "$result_lib" ]]; then
    # shellcheck source=/dev/null
    source "$result_lib"
  fi
  return 0
}

ralph_post_tool_native_result_compact_run() {
  local hook_input
  hook_input="$(cat)" || ralph_native_hook_post_tool_native_result_compact_fail_open
  ralph_native_hook_post_tool_native_result_compact_main "$hook_input" \
    || ralph_native_hook_post_tool_native_result_compact_fail_open
}

ralph_post_tool_native_result_compact_source_libs \
  || exit 0
ralph_post_tool_native_result_compact_run
