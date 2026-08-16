#!/usr/bin/env bash
# preToolUse exploration adapter for Cursor: nudge native read/search away from
# ralph_proxy_* when Ralph MCP tools are active.
#
# Denies native Grep/Glob/SemanticSearch for exploration.
# Denies native Read unless the path was handoff-allowed after ralph_proxy_read
# (see pre-tool-proxy-read-handoff.sh).
#
# Gate: strict Ralph mode only (RALPH_MODE=ralph with native hooks off). Hybrid and
#       native modes keep native exploration tools available; compaction runs via
#       post-tool-native-result-compact.sh instead.
#       RALPH_NATIVE_EXPLORATION_NUDGE=1 forces on; =0 opts out.
# Fail-open: missing deps, wrong event, or gate off -> allow.

set -uo pipefail

ralph_cursor_exploration_fail_open() {
  exit 0
}

ralph_cursor_exploration_truthy() {
  case "${1:-}" in
    1 | true | yes | on) return 0 ;;
    *) return 1 ;;
  esac
}

ralph_cursor_exploration_nudge_active() {
  case "${RALPH_NATIVE_EXPLORATION_NUDGE:-}" in
    1 | true | yes | on) return 0 ;;
    0 | false | no | off) return 1 ;;
  esac
  case "${RALPH_MODE:-}" in
    hybrid | native) return 1 ;;
    ralph) return 0 ;;
  esac
  if [[ "${RALPH_AGENT_TOOL_ACCESS:-}" == "ralph" ]]; then
    case "${RALPH_NATIVE_HOOKS:-}" in
      off | 0 | false | no) return 0 ;;
    esac
  fi
  return 1
}

ralph_cursor_exploration_workspace() {
  if [[ -n "${WORKSPACE:-}" ]]; then
    printf '%s\n' "$WORKSPACE"
    return 0
  fi
  local root
  root="$(jq -r '.workspace_roots[0] // .cwd // empty' <<<"${RALPH_CURSOR_EXPLORATION_INPUT:-{}}")"
  [[ -n "$root" ]] || return 1
  printf '%s\n' "$root"
}

ralph_cursor_exploration_state_file() {
  local workspace="${1:-}" plan_key="${2:-exploration-hook}"
  local state_root="${RALPH_PLAN_WORKSPACE_ROOT:-$workspace/.ralph-workspace}"
  printf '%s/sessions/%s/native-edit-read-allow.paths\n' "$state_root" "$plan_key"
}

ralph_cursor_exploration_normalize_path() {
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

ralph_cursor_exploration_path_allowed() {
  local state_file="${1:-}" normalized="${2:-}"
  [[ -n "$state_file" && -n "$normalized" && -f "$state_file" ]] || return 1
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    [[ "$line" == "$normalized" ]] && return 0
  done <"$state_file"
  return 1
}

ralph_cursor_exploration_emit_deny() {
  local message="${1:-}" tool_name="${2:-}"
  local workspace plan_key
  workspace="$(ralph_cursor_exploration_workspace)" || ralph_cursor_exploration_fail_open
  plan_key="$(ralph_native_hook_plan_key cursor-exploration)"
  if [[ -n "${RALPH_KILLSWITCH_HOOK_RECORD:-}" ]] && command -v jq >/dev/null 2>&1; then
    jq -nc \
      --arg runtime "cursor" \
      --arg tool "$tool_name" \
      --arg decision "nudge" \
      --argjson applied false \
      --arg source "native-hook" \
      '{runtime:$runtime,tool:$tool,decision:$decision,applied:$applied,source:$source}' \
      >>"$RALPH_KILLSWITCH_HOOK_RECORD" 2>/dev/null || true
  fi
  ralph_native_hook_append_nudge_log \
    "$workspace" \
    "$plan_key" \
    "native:${tool_name}" \
    "$message" \
    "exploration-deny-${tool_name}"
  jq -nc --arg message "$message" \
    '{permission: "deny", agent_message: $message}'
}

ralph_cursor_exploration_normalize_tool_name() {
  local raw="${1:-}"
  case "$raw" in
    Read|read|readToolCall|ReadToolCall) printf 'Read\n' ;;
    Grep|grep|grepToolCall|GrepToolCall) printf 'Grep\n' ;;
    Glob|glob|globToolCall|GlobToolCall) printf 'Glob\n' ;;
    SemanticSearch|semanticSearch|semanticSearchToolCall) printf 'SemanticSearch\n' ;;
    *) printf '%s\n' "$raw" ;;
  esac
}

ralph_cursor_exploration_main() {
  ralph_cursor_exploration_nudge_active || ralph_cursor_exploration_fail_open
  command -v jq >/dev/null 2>&1 || ralph_cursor_exploration_fail_open

  RALPH_CURSOR_EXPLORATION_INPUT="$(cat)" || ralph_cursor_exploration_fail_open

  local event tool_name workspace plan_key state_file path normalized
  event="$(jq -r '.hook_event_name // ""' <<<"$RALPH_CURSOR_EXPLORATION_INPUT")"
  tool_name="$(jq -r '.tool_name // ""' <<<"$RALPH_CURSOR_EXPLORATION_INPUT")"
  tool_name="$(ralph_cursor_exploration_normalize_tool_name "$tool_name")"
  [[ "$event" == "preToolUse" ]] || ralph_cursor_exploration_fail_open

  case "$tool_name" in
    Grep | Glob | SemanticSearch)
      ralph_cursor_exploration_emit_deny \
        "Ralph mode: use ralph_proxy_grep or ralph_proxy_glob for exploration instead of native ${tool_name}." \
        "$tool_name"
      exit 0
      ;;
    Read)
      path="$(jq -r '.tool_input.path // empty' <<<"$RALPH_CURSOR_EXPLORATION_INPUT")"
      [[ -n "$path" ]] || ralph_cursor_exploration_fail_open
      workspace="$(ralph_cursor_exploration_workspace)" || ralph_cursor_exploration_fail_open
      plan_key="$(ralph_native_hook_plan_key cursor-exploration)"
      state_file="$(ralph_cursor_exploration_state_file "$workspace" "$plan_key")"
      normalized="$(ralph_cursor_exploration_normalize_path "$workspace" "$path")" || ralph_cursor_exploration_fail_open
      if ralph_cursor_exploration_path_allowed "$state_file" "$normalized"; then
        ralph_cursor_exploration_fail_open
      fi
      ralph_cursor_exploration_emit_deny \
        "Ralph mode: use ralph_proxy_read for exploration (offset/limit for partial reads). Native Read is allowed only after ralph_proxy_read on the same path when you need to Edit/Write that file." \
        "Read"
      exit 0
      ;;
    *)
      ralph_cursor_exploration_fail_open
      ;;
  esac
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

ralph_cursor_exploration_main
