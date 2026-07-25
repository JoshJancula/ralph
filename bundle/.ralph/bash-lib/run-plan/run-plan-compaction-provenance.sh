#!/usr/bin/env bash
# Compaction-gate provenance resolution (PLAN15).
#
# Wraps the existing mode-default resolution in ralph_apply_mode_compaction_defaults
# (run-plan-args.sh) with a read-only, side-effect-free provenance query: for a
# given channel, was the resolved gate an explicit environment override, a
# Ralph-mode default, a workspace-saved ralph_mode_default preference, or the
# unset/default-off fallback? Does not export or mutate any gate variable.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

# Args: channel mode [mode_source]
#   channel: bash_compact | native_result_compact | proxy_shell_compact | bash_rewrite
#   mode: resolved RALPH_MODE value (no|native|ralph|hybrid); defaults to $RALPH_MODE or "no"
#   mode_source: how RALPH_MODE itself was resolved -- "explicit" (flag/env) or
#     "workspace_preference" (.ralph-workspace/preferences.json ralph_mode_default).
#     Defaults to "explicit". Only affects the reported source when the gate
#     ends up on via the mode default; has no effect on an explicit gate
#     env-var override, which always wins and reports "explicit_env".
#
# Prints JSON: {"channel":..., "gate":"on"|"off", "source":"explicit_env"|"mode_default"|"workspace_preference"|"unset_default_off"}
ralph_compaction_gate_provenance() {
  local channel="${1:-}" mode="${2:-${RALPH_MODE:-no}}" mode_source="${3:-explicit}"
  local env_var=""

  case "$channel" in
    bash_compact) env_var="RALPH_BASH_COMPACT" ;;
    native_result_compact) env_var="RALPH_NATIVE_RESULT_COMPACT" ;;
    proxy_shell_compact) env_var="RALPH_PROXY_SHELL_COMPACT" ;;
    bash_rewrite) env_var="RALPH_BASH_REWRITE" ;;
    *) return 1 ;;
  esac

  local explicit_value="${!env_var:-}"
  if [[ -n "$explicit_value" ]]; then
    local gate="off"
    case "$explicit_value" in
      1 | true | yes | on) gate="on" ;;
    esac
    printf '{"channel":"%s","gate":"%s","source":"explicit_env"}\n' "$channel" "$gate"
    return 0
  fi

  local mode_gate="off"
  case "$channel" in
    bash_compact | native_result_compact)
      case "$mode" in
        native | hybrid) mode_gate="on" ;;
      esac
      ;;
    proxy_shell_compact)
      case "$mode" in
        ralph | hybrid) mode_gate="on" ;;
      esac
      ;;
    bash_rewrite)
      # bash_rewrite has no Ralph-mode default of its own; it is set
      # unconditionally by runtime-capability logic (e.g. the Cursor overlay
      # for native shell wrapper activation), never by RALPH_MODE alone.
      mode_gate="off"
      ;;
  esac

  if [[ "$mode_gate" == "on" ]]; then
    if [[ "$mode_source" == "workspace_preference" ]]; then
      printf '{"channel":"%s","gate":"on","source":"workspace_preference"}\n' "$channel"
    else
      printf '{"channel":"%s","gate":"on","source":"mode_default"}\n' "$channel"
    fi
    return 0
  fi

  printf '{"channel":"%s","gate":"off","source":"unset_default_off"}\n' "$channel"
}

# Convenience: prints provenance for all four channels as a JSON array.
ralph_compaction_gate_provenance_all() {
  local mode="${1:-${RALPH_MODE:-no}}" mode_source="${2:-explicit}"
  local channel
  local -a records=()
  for channel in bash_compact native_result_compact proxy_shell_compact bash_rewrite; do
    records+=("$(ralph_compaction_gate_provenance "$channel" "$mode" "$mode_source")")
  done
  printf '%s\n' "${records[@]}" | jq -sc .
}
