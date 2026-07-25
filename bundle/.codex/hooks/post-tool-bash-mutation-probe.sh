#!/usr/bin/env bash
# PostToolUse:Bash mutation probe for Codex contract verification (T4).
# When RALPH_CODEX_POST_TOOL_PROBE=1, attempts updatedToolOutput replacement
# with CODEX-POSTTOOL-SENTINEL when tool stdout contains ORIGINAL-CODEX-SHELL-OUTPUT.
# Not used in production runs; opt-in verification and Bats fixture only.

set -uo pipefail

ralph_codex_mutation_probe_fail_open() {
  exit 0
}

ralph_codex_mutation_probe_shell_name() {
  case "${1:-}" in
    Bash | command_execution) return 0 ;;
    *) return 1 ;;
  esac
}

ralph_codex_mutation_probe_log() {
  local log_path="${RALPH_CODEX_POST_TOOL_PROBE_LOG:-}"
  [[ -n "$log_path" ]] || return 0
  mkdir -p "$(dirname "$log_path")" 2>/dev/null || true
  printf '%s\n' "$1" >>"$log_path" 2>/dev/null || true
}

ralph_codex_mutation_probe_main() {
  ralph_codex_mutation_probe_log "probe-start"

  command -v jq >/dev/null 2>&1 || ralph_codex_mutation_probe_fail_open

  local input
  input="$(cat)" || ralph_codex_mutation_probe_fail_open

  local event tool_name stdout
  event="$(jq -r '.hook_event_name // ""' <<<"$input")"
  tool_name="$(jq -r '.tool_name // ""' <<<"$input")"
  if [[ "$event" != "PostToolUse" ]] || ! ralph_codex_mutation_probe_shell_name "$tool_name"; then
    ralph_codex_mutation_probe_fail_open
  fi

  ralph_codex_mutation_probe_log "post-tool-use-bash"

  stdout="$(jq -r '.tool_response.stdout // ""' <<<"$input")"
  if [[ "$stdout" != *"ORIGINAL-CODEX-SHELL-OUTPUT"* ]]; then
    ralph_codex_mutation_probe_fail_open
  fi

  ralph_codex_mutation_probe_log "sentinel-emit"

  _NATIVE_HOOK_BOOTSTRAP="${BASH_SOURCE%/*}/../../.ralph/bash-lib/native-hook/native-hook-bootstrap.sh"
  if [[ ! -f "$_NATIVE_HOOK_BOOTSTRAP" ]]; then
    _NATIVE_HOOK_BOOTSTRAP="${RALPH_HOME:-${HOME:-}/.ralph}/bundle/.ralph/bash-lib/native-hook/native-hook-bootstrap.sh"
  fi
  if [[ ! -f "$_NATIVE_HOOK_BOOTSTRAP" ]]; then
    ralph_codex_mutation_probe_fail_open
  fi
  # shellcheck source=/dev/null
  source "$_NATIVE_HOOK_BOOTSTRAP"
  ralph_native_hook_bootstrap_source_lib || ralph_codex_mutation_probe_fail_open

  ralph_native_hook_emit_codex_post_tool_updated_output \
    "CODEX-POSTTOOL-SENTINEL" \
    "" \
    false \
    false \
    ""
}

ralph_codex_mutation_probe_main
