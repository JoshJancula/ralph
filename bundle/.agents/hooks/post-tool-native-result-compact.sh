#!/usr/bin/env bash
# postToolUse native adapter: compact Read/Grep/Glob/SemanticSearch via shared Ralph hook.
# See bundle/.ralph/bash-lib/native-hook/post-tool-native-result-compact-hook.sh

set -uo pipefail

_SHARED_HOOK="${BASH_SOURCE%/*}/../../.ralph/bash-lib/native-hook/post-tool-native-result-compact-hook.sh"
if [[ ! -f "$_SHARED_HOOK" ]]; then
  _SHARED_HOOK="${RALPH_HOME:-${HOME:-}/.ralph}/bundle/.ralph/bash-lib/native-hook/post-tool-native-result-compact-hook.sh"
fi
if [[ ! -f "$_SHARED_HOOK" ]]; then
  exit 0
fi
exec bash "$_SHARED_HOOK"
