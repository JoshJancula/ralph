#!/usr/bin/env bash
# Effective hook-configuration resolver (PLAN15).
#
# Combines compaction-gate provenance (run-plan-compaction-provenance.sh) with
# a per-runtime capability matrix to answer, per channel: was it requested,
# is it enabled, and can this runtime actually make it effective (mutate
# model-visible output) -- or is that unknown/unsupported. Pure: no exports,
# no mutation, same inputs always produce the same JSON.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

_RALPH_EFFECTIVE_HOOK_CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F ralph_compaction_gate_provenance >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "$_RALPH_EFFECTIVE_HOOK_CONFIG_DIR/run-plan-compaction-provenance.sh"
fi

# Capability of a (runtime, channel) pair to actually mutate model-visible
# output when its gate is enabled. One of: proven | measured_only | unsupported | unknown.
#
# - proven: the runtime's native hook (or MCP proxy, which is runtime-agnostic)
#   has observed/documented output-mutation capability for this channel.
# - measured_only: the runtime can run the hook and record telemetry, but
#   cannot mutate the model-visible payload (Cursor/Codex native result and
#   bash compaction paths at time of writing; MCP proxy is the effective
#   fallback for those runtimes instead).
# - unsupported: this runtime has no adapter for this channel at all.
# - unknown: the runtime name itself is missing/unrecognized, so capability
#   cannot be determined.
ralph_hook_channel_capability() {
  local runtime="${1:-}" channel="${2:-}"
  case "$runtime" in
    claude)
      case "$channel" in
        bash_compact | native_result_compact | proxy_shell_compact) printf 'proven\n' ;;
        bash_rewrite) printf 'unsupported\n' ;;
        *) printf 'unknown\n' ;;
      esac
      ;;
    cursor)
      case "$channel" in
        bash_compact | native_result_compact) printf 'measured_only\n' ;;
        proxy_shell_compact | bash_rewrite) printf 'proven\n' ;;
        *) printf 'unknown\n' ;;
      esac
      ;;
    codex)
      case "$channel" in
        bash_compact | native_result_compact) printf 'measured_only\n' ;;
        proxy_shell_compact) printf 'proven\n' ;;
        bash_rewrite) printf 'unsupported\n' ;;
        *) printf 'unknown\n' ;;
      esac
      ;;
    opencode)
      case "$channel" in
        proxy_shell_compact) printf 'proven\n' ;;
        bash_compact | native_result_compact | bash_rewrite) printf 'unsupported\n' ;;
        *) printf 'unknown\n' ;;
      esac
      ;;
    *)
      printf 'unknown\n'
      ;;
  esac
}

# Args: channel runtime mode [mode_source]
# Prints JSON: {channel, runtime, requestedGate, requestedSource, enabled,
#               effective (true|false|"unknown"), reason}
ralph_effective_hook_config_resolve() {
  local channel="${1:-}" runtime="${2:-}" mode="${3:-${RALPH_MODE:-no}}" mode_source="${4:-explicit}"

  local provenance
  provenance="$(ralph_compaction_gate_provenance "$channel" "$mode" "$mode_source")" || return 1
  local requested_gate requested_source
  requested_gate="$(jq -r '.gate' <<<"$provenance")"
  requested_source="$(jq -r '.source' <<<"$provenance")"

  local enabled="false" enabled_reason=""
  if [[ "$requested_gate" == "on" ]]; then
    enabled="true"
    enabled_reason="$requested_source"
  elif [[ "$channel" == "native_result_compact" ]]; then
    # Coupled legacy fallback: native_result_compact also activates when
    # either legacy Bash or proxy-shell compaction is on, even if its own
    # gate is off/unset (mirrors ralph_native_hook_result_compact_enabled).
    local bash_prov proxy_prov bash_gate proxy_gate
    bash_prov="$(ralph_compaction_gate_provenance "bash_compact" "$mode" "$mode_source")"
    proxy_prov="$(ralph_compaction_gate_provenance "proxy_shell_compact" "$mode" "$mode_source")"
    bash_gate="$(jq -r '.gate' <<<"$bash_prov")"
    proxy_gate="$(jq -r '.gate' <<<"$proxy_prov")"
    if [[ "$bash_gate" == "on" ]]; then
      enabled="true"
      enabled_reason="coupled_bash_compact"
    elif [[ "$proxy_gate" == "on" ]]; then
      enabled="true"
      enabled_reason="coupled_proxy_shell_compact"
    fi
  fi

  local capability
  capability="$(ralph_hook_channel_capability "$runtime" "$channel")"

  local effective reason
  if [[ "$enabled" != "true" ]]; then
    effective="false"
    reason="gate_disabled"
  else
    case "$capability" in
      proven)
        effective="true"
        reason="proven_channel:${enabled_reason}"
        ;;
      measured_only)
        effective="false"
        reason="runtime_cannot_mutate_output"
        ;;
      unsupported)
        effective="false"
        reason="channel_unsupported_on_runtime"
        ;;
      *)
        effective="unknown"
        reason="runtime_capability_unknown"
        ;;
    esac
  fi

  jq -nc \
    --arg channel "$channel" \
    --arg runtime "$runtime" \
    --arg requestedGate "$requested_gate" \
    --arg requestedSource "$requested_source" \
    --argjson enabled "$enabled" \
    --arg effective "$effective" \
    --arg reason "$reason" \
    '{
      channel: $channel,
      runtime: $runtime,
      requestedGate: $requestedGate,
      requestedSource: $requestedSource,
      enabled: $enabled,
      effective: (if $effective == "unknown" then "unknown" else ($effective == "true") end),
      reason: $reason
    }'
}

# Convenience: all four channels for one runtime/mode as a JSON array.
ralph_effective_hook_config_resolve_all() {
  local runtime="${1:-}" mode="${2:-${RALPH_MODE:-no}}" mode_source="${3:-explicit}"
  local channel
  local -a records=()
  for channel in bash_compact native_result_compact proxy_shell_compact bash_rewrite; do
    records+=("$(ralph_effective_hook_config_resolve "$channel" "$runtime" "$mode" "$mode_source")")
  done
  printf '%s\n' "${records[@]}" | jq -sc .
}
