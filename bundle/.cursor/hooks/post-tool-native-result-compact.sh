#!/usr/bin/env bash
# postToolUse native adapter: compact Read/Grep/Glob/SemanticSearch via shared Ralph hook.
# See bundle/.ralph/bash-lib/native-hook/post-tool-native-result-compact-hook.sh
#
# Fast path: when neither RALPH_NATIVE_RESULT_COMPACT nor
# RALPH_CURSOR_NATIVE_RESULT_HOOK_COMPACT is truthy, exit 0 before exec/source.

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
