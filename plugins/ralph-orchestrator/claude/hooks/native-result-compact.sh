#!/usr/bin/env bash
# GENERATED from bundle/.claude/hooks/native-result-compact.sh by scripts/sync-plugin-assets.sh - edit the canonical file
# PostToolUse adapter: compact Read/Grep/Glob via shared Ralph envelope/store path.
# Gate: RALPH_NATIVE_RESULT_COMPACT=1 explicitly opts in (or
# RALPH_CURSOR_NATIVE_RESULT_HOOK_COMPACT when the primary is unset). Fail-open:
# never blocks the agent.
#
# Fast path: when neither gate env is truthy, exit 0 before exec/source so a
# disabled feature costs only an env check (target under 40 ms).

set -uo pipefail

# Keep in sync with ralph_native_hook_result_compact_enabled.
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

_SHARED_HOOK="${BASH_SOURCE%/*}/../../.ralph/bash-lib/native-hook/post-tool-native-result-compact-hook.sh"
if [[ ! -f "$_SHARED_HOOK" ]]; then
  _SHARED_HOOK="${RALPH_HOME:-${HOME:-}/.ralph}/bundle/.ralph/bash-lib/native-hook/post-tool-native-result-compact-hook.sh"
fi
if [[ ! -f "$_SHARED_HOOK" ]]; then
  exit 0
fi
exec bash "$_SHARED_HOOK"
