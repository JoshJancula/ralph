#!/usr/bin/env bash
# preToolUse MCP adapter for Cursor: record ralph_proxy_read paths so a follow-up
# native Read is allowed for the edit-adjacent flow (proxy read -> native Read -> Edit).
#
# Gate: same as pre-tool-exploration-policy.sh (Ralph MCP active; opt-out via
# RALPH_NATIVE_EXPLORATION_NUDGE=0). Fail-open.

set -uo pipefail

ralph_cursor_proxy_handoff_fail_open() {
  exit 0
}

ralph_cursor_proxy_handoff_truthy() {
  case "${1:-}" in
    1 | true | yes | on) return 0 ;;
    *) return 1 ;;
  esac
}

ralph_cursor_proxy_handoff_active() {
  if ralph_cursor_proxy_handoff_truthy "${RALPH_NATIVE_EXPLORATION_NUDGE:-}"; then
    return 0
  fi
  case "${RALPH_NATIVE_EXPLORATION_NUDGE:-}" in
    0 | false | no | off) return 1 ;;
  esac
  case "${RALPH_AGENT_TOOL_ACCESS:-}" in
    ralph) return 0 ;;
  esac
  ralph_cursor_proxy_handoff_truthy "${RALPH_MCP_TOOLS_ENABLED:-}"
}

ralph_cursor_proxy_handoff_workspace() {
  if [[ -n "${WORKSPACE:-}" ]]; then
    printf '%s\n' "$WORKSPACE"
    return 0
  fi
  local root
  root="$(jq -r '.workspace_roots[0] // .cwd // empty' <<<"${RALPH_CURSOR_PROXY_HANDOFF_INPUT:-{}}")"
  [[ -n "$root" ]] || return 1
  printf '%s\n' "$root"
}

ralph_cursor_proxy_handoff_normalize_tool() {
  local raw="${1:-}"
  raw="${raw#MCP:}"
  raw="${raw#mcp__ralph__}"
  raw="${raw#ralph-}"
  printf '%s\n' "$raw"
}

ralph_cursor_proxy_handoff_state_file() {
  local workspace="${1:-}" plan_key="${2:-exploration-hook}"
  local state_root="${RALPH_PLAN_WORKSPACE_ROOT:-$workspace/.ralph-workspace}"
  printf '%s/sessions/%s/native-edit-read-allow.paths\n' "$state_root" "$plan_key"
}

ralph_cursor_proxy_handoff_normalize_path() {
  local workspace="${1:-}" raw_path="${2:-}"
  [[ -n "$raw_path" ]] || return 1
  if [[ "$raw_path" != /* ]]; then
    raw_path="$workspace/$raw_path"
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$raw_path" <<'PY'
import os
import sys

print(os.path.normpath(os.path.abspath(sys.argv[1])))
PY
    return 0
  fi
  (
    cd "$(dirname "$raw_path")" 2>/dev/null || exit 1
    printf '%s/%s\n' "$(pwd -P)" "$(basename "$raw_path")"
  )
}

ralph_cursor_proxy_handoff_record_path() {
  local state_file="${1:-}" normalized="${2:-}"
  [[ -n "$state_file" && -n "$normalized" ]] || return 0
  mkdir -p "$(dirname "$state_file")"
  if [[ -f "$state_file" ]] && grep -Fxq "$normalized" "$state_file" 2>/dev/null; then
    return 0
  fi
  printf '%s\n' "$normalized" >>"$state_file"
}

ralph_cursor_proxy_handoff_main() {
  ralph_cursor_proxy_handoff_active || ralph_cursor_proxy_handoff_fail_open
  command -v jq >/dev/null 2>&1 || ralph_cursor_proxy_handoff_fail_open

  RALPH_CURSOR_PROXY_HANDOFF_INPUT="$(cat)" || ralph_cursor_proxy_handoff_fail_open

  local event tool_name raw_tool path workspace plan_key state_file normalized
  event="$(jq -r '.hook_event_name // ""' <<<"$RALPH_CURSOR_PROXY_HANDOFF_INPUT")"
  tool_name="$(jq -r '.tool_name // ""' <<<"$RALPH_CURSOR_PROXY_HANDOFF_INPUT")"
  [[ "$event" == "preToolUse" ]] || ralph_cursor_proxy_handoff_fail_open

  raw_tool="$(ralph_cursor_proxy_handoff_normalize_tool "$tool_name")"
  [[ "$raw_tool" == "ralph_proxy_read" ]] || ralph_cursor_proxy_handoff_fail_open

  path="$(jq -r '.tool_input.path // .tool_input.arguments.path // empty' <<<"$RALPH_CURSOR_PROXY_HANDOFF_INPUT")"
  [[ -n "$path" ]] || ralph_cursor_proxy_handoff_fail_open

  workspace="$(ralph_cursor_proxy_handoff_workspace)" || ralph_cursor_proxy_handoff_fail_open
  plan_key="$(ralph_native_hook_plan_key cursor-proxy-handoff)"
  state_file="$(ralph_cursor_proxy_handoff_state_file "$workspace" "$plan_key")"
  normalized="$(ralph_cursor_proxy_handoff_normalize_path "$workspace" "$path")" || ralph_cursor_proxy_handoff_fail_open
  ralph_cursor_proxy_handoff_record_path "$state_file" "$normalized"
  ralph_cursor_proxy_handoff_fail_open
}

_NATIVE_HOOK_BOOTSTRAP="${BASH_SOURCE%/*}/../../.ralph/bash-lib/native-hook/native-hook-bootstrap.sh"
if [[ ! -f "$_NATIVE_HOOK_BOOTSTRAP" ]]; then
  _NATIVE_HOOK_BOOTSTRAP="${RALPH_HOME:-${HOME:-}/.ralph}/bundle/.ralph/bash-lib/native-hook/native-hook-bootstrap.sh"
fi
if [[ ! -f "$_NATIVE_HOOK_BOOTSTRAP" ]]; then
  exit 0
fi
# shellcheck source=/dev/null
source "$_NATIVE_HOOK_BOOTSTRAP"
ralph_native_hook_bootstrap_source_lib || exit 0
unset _NATIVE_HOOK_BOOTSTRAP

ralph_cursor_proxy_handoff_main
