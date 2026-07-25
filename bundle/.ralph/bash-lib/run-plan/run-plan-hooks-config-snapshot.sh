#!/usr/bin/env bash
# Effective hook-config snapshot writer (PLAN15).
#
# Appends one JSONL record to hooks-config.jsonl per invocation/runtime,
# after Ralph mode defaults have been resolved and runtime adapter
# preparation has established effective capability state -- NOT during
# runtime_overlay_init_state, which runs before either is known. Uses the
# same small-atomic-write append convention as hook-telemetry.sh (a single
# printf under PIPE_BUF is atomic on POSIX, so concurrent invocations do not
# interleave/corrupt each other's lines).

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

_RALPH_HOOKS_CONFIG_SNAPSHOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F ralph_effective_hook_config_resolve_all >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "$_RALPH_HOOKS_CONFIG_SNAPSHOT_DIR/run-plan-effective-hook-config.sh"
fi

# Default snapshot path for a given workspace root.
ralph_hooks_config_snapshot_path() {
  local workspace_root="${1:-}"
  [[ -n "$workspace_root" ]] || return 1
  printf '%s/hooks-config.jsonl\n' "${workspace_root%/}"
}

# Args: workspace_root plan_key iteration runtime [mode] [mode_source]
# Appends one JSONL line: {timestamp, planKey, iteration, runtime, channels:[...]}
ralph_hooks_config_snapshot_append() {
  local workspace_root="${1:-}" plan_key="${2:-}" iteration="${3:-}" runtime="${4:-}"
  local mode="${5:-${RALPH_MODE:-no}}" mode_source="${6:-explicit}"
  local snapshot_path

  [[ -n "$workspace_root" && -n "$plan_key" ]] || return 0
  snapshot_path="$(ralph_hooks_config_snapshot_path "$workspace_root")" || return 0

  local channels_json
  channels_json="$(ralph_effective_hook_config_resolve_all "$runtime" "$mode" "$mode_source" 2>/dev/null)" || return 0
  [[ -n "$channels_json" ]] || return 0

  local timestamp
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown')"

  local line
  line="$(jq -nc \
    --arg timestamp "$timestamp" \
    --arg planKey "$plan_key" \
    --arg iteration "$iteration" \
    --arg runtime "$runtime" \
    --argjson channels "$channels_json" \
    '{timestamp: $timestamp, planKey: $planKey, iteration: $iteration, runtime: $runtime, channels: $channels}' \
    2>/dev/null)" || return 0
  [[ -n "$line" ]] || return 0

  mkdir -p "$(dirname "$snapshot_path")" 2>/dev/null || return 0
  printf '%s\n' "$line" >>"$snapshot_path" 2>/dev/null || return 0
}
