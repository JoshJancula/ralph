#!/usr/bin/env bash
# GENERATED from bundle/.cursor/hooks/after-shell-telemetry.sh by scripts/sync-plugin-assets.sh - edit the canonical file
# afterShellExecution telemetry for Cursor (observability only; audit surface).

set -uo pipefail

ralph_cursor_after_shell_fail_open() {
  exit 0
}

ralph_cursor_after_shell_main() {
  command -v jq >/dev/null 2>&1 || ralph_cursor_after_shell_fail_open

  local input log_path
  input="$(cat)" || ralph_cursor_after_shell_fail_open
  log_path="${RALPH_BASH_TELEMETRY_LOG:-}"
  [[ -n "$log_path" ]] || ralph_cursor_after_shell_fail_open

  local command output
  command="$(jq -r '.command // ""' <<<"$input")"
  output="$(jq -r '.output // ""' <<<"$input")"
  [[ -n "$command" ]] || ralph_cursor_after_shell_fail_open

  mkdir -p "$(dirname "$log_path")" 2>/dev/null || ralph_cursor_after_shell_fail_open
  printf '%s afterShellExecution bytes=%s command_hash=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$(printf '%s' "$output" | wc -c | tr -d ' ')" \
    "$(printf '%s' "$command" | shasum -a 256 2>/dev/null | awk '{print $1}' || printf '')" \
    >>"$log_path" 2>/dev/null || true
  ralph_cursor_after_shell_fail_open
}

ralph_cursor_after_shell_main
