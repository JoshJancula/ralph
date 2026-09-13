#!/usr/bin/env bash
# Claude Stop hook adapter: wait for Ralph background jobs and block with reason.

set -uo pipefail

ralph_claude_stop_hook_fail_open() {
  exit 0
}

ralph_claude_stop_hook_main() {
  local project_dir adapter_lib core_script hook_input

  command -v jq >/dev/null 2>&1 || ralph_claude_stop_hook_fail_open

  hook_input="$(cat)" || hook_input="{}"

  if [[ -n "${RALPH_HOME:-}" && -f "${RALPH_HOME}/bundle/.ralph/bash-lib/native-hook/native-hook-lib.sh" ]]; then
    # shellcheck source=/dev/null
    source "${RALPH_HOME}/bundle/.ralph/bash-lib/native-hook/native-hook-lib.sh"
  elif [[ -f "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.ralph/bash-lib/native-hook/native-hook-lib.sh" ]]; then
    local repo_root
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    # shellcheck source=/dev/null
    source "$repo_root/.ralph/bash-lib/native-hook/native-hook-lib.sh"
  else
    ralph_claude_stop_hook_fail_open
  fi

  if ! project_dir="$(ralph_native_hook_project_dir CLAUDE_PROJECT_DIR "$hook_input")"; then
    ralph_claude_stop_hook_fail_open
  fi

  adapter_lib="$(ralph_native_hook_resolve_bash_lib "$project_dir" "native-hook/stop-continuation-block-adapter.sh" 2>/dev/null || true)"
  if [[ -n "${RALPH_BG_STOP_CORE_SCRIPT:-}" && -f "${RALPH_BG_STOP_CORE_SCRIPT}" ]]; then
    core_script="$RALPH_BG_STOP_CORE_SCRIPT"
  else
    core_script="$(ralph_native_hook_resolve_bash_lib "$project_dir" "native-hook/stop-continuation-hook.sh" 2>/dev/null || true)"
  fi
  if [[ -z "$adapter_lib" || ! -f "$adapter_lib" || -z "$core_script" || ! -f "$core_script" ]]; then
    ralph_claude_stop_hook_fail_open
  fi

  # shellcheck source=/dev/null
  source "$adapter_lib"
  RALPH_BG_STOP_CORE_SCRIPT="$core_script"
  ralph_bg_stop_block_adapter_main <<<"$hook_input"
}

ralph_claude_stop_hook_main
