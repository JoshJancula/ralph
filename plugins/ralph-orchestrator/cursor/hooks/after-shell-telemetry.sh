#!/usr/bin/env bash
# GENERATED from bundle/.cursor/hooks/after-shell-telemetry.sh by scripts/sync-plugin-assets.sh - edit the canonical file
# afterShellExecution telemetry + duration learning for Cursor / Antigravity.
#
# Cursor's afterShellExecution payload documents a top-level `duration` field
# (milliseconds, excluding approval wait). Record into the shared
# command_profiles store whenever the hook fires; optional RALPH_BASH_TELEMETRY_LOG
# audit lines remain independent of learning.

set -uo pipefail

ralph_cursor_after_shell_fail_open() {
  exit 0
}

ralph_cursor_after_shell_workspace() {
  if [[ -n "${WORKSPACE:-}" ]]; then
    printf '%s\n' "$WORKSPACE"
    return 0
  fi
  local root
  root="$(jq -r '.workspace_roots[0] // .cwd // empty' <<<"${RALPH_CURSOR_AFTER_SHELL_INPUT:-{}}")"
  [[ -n "$root" ]] || return 1
  printf '%s\n' "$root"
}

ralph_cursor_after_shell_main() {
  command -v jq >/dev/null 2>&1 || ralph_cursor_after_shell_fail_open

  RALPH_CURSOR_AFTER_SHELL_INPUT="$(cat)" || ralph_cursor_after_shell_fail_open

  local command output duration_ms duration_raw fingerprint workspace log_path
  command="$(jq -r '.command // ""' <<<"$RALPH_CURSOR_AFTER_SHELL_INPUT")"
  output="$(jq -r '.output // ""' <<<"$RALPH_CURSOR_AFTER_SHELL_INPUT")"
  [[ -n "$command" ]] || ralph_cursor_after_shell_fail_open

  # Prefer documented `duration`; accept `duration_ms` for forward compatibility.
  duration_raw="$(jq -r '.duration // .duration_ms // empty' <<<"$RALPH_CURSOR_AFTER_SHELL_INPUT")"
  duration_ms=""
  if [[ "$duration_raw" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    duration_ms="${duration_raw%%.*}"
  fi

  workspace="$(ralph_cursor_after_shell_workspace)" || true
  if [[ -n "$workspace" ]]; then
    _NATIVE_HOOK_BOOTSTRAP="${BASH_SOURCE%/*}/../../.ralph/bash-lib/native-hook/native-hook-bootstrap.sh"
    if [[ ! -f "$_NATIVE_HOOK_BOOTSTRAP" ]]; then
      _NATIVE_HOOK_BOOTSTRAP="${RALPH_HOME:-${HOME:-}/.ralph}/bundle/.ralph/bash-lib/native-hook/native-hook-bootstrap.sh"
    fi
    if [[ -f "$_NATIVE_HOOK_BOOTSTRAP" ]]; then
      # shellcheck source=/dev/null
      source "$_NATIVE_HOOK_BOOTSTRAP"
      ralph_native_hook_bootstrap_source_lib || true
      fingerprint="$(ralph_native_hook_command_fingerprint "$workspace" "$command" 2>/dev/null || true)"
      ralph_native_hook_maybe_record_duration \
        "$workspace" "$command" "$fingerprint" "$duration_ms" "false" || true
    fi
  fi

  log_path="${RALPH_BASH_TELEMETRY_LOG:-}"
  [[ -n "$log_path" ]] || ralph_cursor_after_shell_fail_open

  mkdir -p "$(dirname "$log_path")" 2>/dev/null || ralph_cursor_after_shell_fail_open
  printf '%s afterShellExecution bytes=%s command_hash=%s duration_ms=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$(printf '%s' "$output" | wc -c | tr -d ' ')" \
    "$(printf '%s' "$command" | shasum -a 256 2>/dev/null | awk '{print $1}' || printf '')" \
    "${duration_ms:-}" \
    >>"$log_path" 2>/dev/null || true
  ralph_cursor_after_shell_fail_open
}

ralph_cursor_after_shell_main
