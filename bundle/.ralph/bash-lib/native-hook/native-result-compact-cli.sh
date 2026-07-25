#!/usr/bin/env bash
# CLI for OpenCode/plugin callers: compact exploration tool text via shared hook libs.
# stdin JSON: {tool_name, text, workspace?, plan_key?}
# stdout JSON: {applied: true, compacted: "..."} or empty on skip (fail-open)

set -uo pipefail

_hook_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_hook_dir/native-hook-bootstrap.sh" 2>/dev/null || {
  _bootstrap="${RALPH_HOME:-${HOME:-}/.ralph}/bundle/.ralph/bash-lib/native-hook/native-hook-bootstrap.sh"
  # shellcheck source=/dev/null
  source "$_bootstrap" 2>/dev/null || exit 0
}
ralph_native_hook_bootstrap_source_lib || exit 0
# shellcheck source=/dev/null
source "$_hook_dir/native-result-compact.sh" 2>/dev/null || exit 0

payload="$(cat)" || exit 0
ralph_native_hook_native_result_compact_cli_main "$payload" || true
