#!/usr/bin/env bash
# Backward-compatible alias for the Claude native result compaction hook.

set -uo pipefail

_HOOK_DIR="${BASH_SOURCE%/*}"
if [[ -x "$_HOOK_DIR/native-result-compact.sh" ]]; then
  exec bash "$_HOOK_DIR/native-result-compact.sh"
fi

_FALLBACK="${RALPH_HOME:-${HOME:-}/.ralph}/bundle/.claude/hooks/native-result-compact.sh"
if [[ -x "$_FALLBACK" ]]; then
  exec bash "$_FALLBACK"
fi
exit 0
