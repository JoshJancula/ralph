#!/usr/bin/env bash
# PostToolUse adapter: compact read_file/grep/Glob via shared Ralph envelope/store path.
# Gate: RALPH_NATIVE_RESULT_COMPACT=0 opts out; otherwise follows RALPH_BASH_COMPACT /
# RALPH_PROXY_SHELL_COMPACT defaults. Fail-open: never blocks the agent.

set -uo pipefail

_SHARED_HOOK="${BASH_SOURCE%/*}/../../.ralph/bash-lib/native-hook/post-tool-native-result-compact-hook.sh"
if [[ ! -f "$_SHARED_HOOK" ]]; then
  _SHARED_HOOK="${RALPH_HOME:-${HOME:-}/.ralph}/bundle/.ralph/bash-lib/native-hook/post-tool-native-result-compact-hook.sh"
fi
if [[ ! -f "$_SHARED_HOOK" ]]; then
  exit 0
fi
exec bash "$_SHARED_HOOK"
