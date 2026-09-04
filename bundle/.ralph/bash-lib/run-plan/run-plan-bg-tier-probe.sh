#!/usr/bin/env bash
# Per-runtime background continuation tier probe (tier 1 hook vs tier 2 invocation).
#
# Tier selection is supervisor-owned. RALPH_BG_TIER may force auto (default),
# hook (fail loudly when unavailable), or invocation.

if [[ -n "${RALPH_BG_TIER_PROBE_LOADED:-}" ]]; then
  return
fi
RALPH_BG_TIER_PROBE_LOADED=1

RALPH_BG_TIER="${RALPH_BG_TIER:-auto}"

ralph_bg_tier_probe_debug() {
  [[ -n "${RALPH_CONTINUATION_DEBUG:-}" ]] || return 0
  printf '[ralph-bg-tier-probe] %s %s\n' "${1:-event}" "${2:-}" >&2
}

ralph_bg_tier_probe_normalize_override() {
  local mode="${1:-auto}"
  case "$mode" in
    auto|hook|invocation) printf '%s' "$mode" ;;
    *) printf '%s' "auto" ;;
  esac
}

ralph_bg_tier_probe_isolation_mode() {
  if command -v setsid >/dev/null 2>&1; then
    printf '%s\n' "setsid"
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    printf '%s\n' "python-setsid"
    return 0
  fi
  printf '%s\n' "none"
  return 1
}

ralph_bg_tier_probe_isolation_available() {
  ralph_bg_tier_probe_isolation_mode >/dev/null 2>&1
}

ralph_bg_tier_probe_workspace_root() {
  if [[ -n "${RALPH_AGENT_WORKSPACE:-}" ]]; then
    printf '%s' "$RALPH_AGENT_WORKSPACE"
    return 0
  fi
  if [[ -n "${WORKSPACE:-}" ]]; then
    printf '%s' "$WORKSPACE"
    return 0
  fi
  if [[ -n "${RALPH_PROJECT_ROOT:-}" ]]; then
    printf '%s' "$RALPH_PROJECT_ROOT"
    return 0
  fi
  return 1
}

ralph_bg_tier_probe_config_dir_writable() {
  local dir="${1:-}"
  [[ -n "$dir" ]] || return 1
  mkdir -p "$dir" 2>/dev/null || return 1
  local probe="$dir/.ralph-bg-tier-probe-$$"
  if ! : >"$probe" 2>/dev/null; then
    return 1
  fi
  rm -f "$probe"
  return 0
}

ralph_bg_tier_probe_opencode_revalidation_artifact() {
  local state_root="${RALPH_PLAN_WORKSPACE_ROOT:-}"
  if [[ -z "$state_root" ]]; then
    local project="${RALPH_PROJECT_ROOT:-${WORKSPACE:-}}"
    [[ -n "$project" ]] || return 1
    state_root="${project}/.ralph-workspace"
  fi
  printf '%s/artifacts/PLAN13/opencode-hook-revalidation.md' "$state_root"
}

ralph_bg_tier_probe_opencode_session_idle_proven() {
  if [[ "${RALPH_BG_OPENCODE_SESSION_IDLE_PROVEN:-0}" == "1" ]]; then
    return 0
  fi
  local artifact=""
  artifact="$(ralph_bg_tier_probe_opencode_revalidation_artifact)" || return 1
  [[ -f "$artifact" ]] || return 1
  grep -qE '^session_idle_continuation_proven:[[:space:]]*yes[[:space:]]*$' "$artifact"
}

ralph_bg_tier_probe_runtime_hook_support() {
  local runtime="${1:-}"
  local workspace="" config_dir="" hook_reason=""

  case "$runtime" in
    claude)
      workspace="$(ralph_bg_tier_probe_workspace_root 2>/dev/null || true)"
      [[ -n "$workspace" ]] || return 1
      config_dir="$workspace/.claude"
      ralph_bg_tier_probe_config_dir_writable "$config_dir" || return 1
      return 0
      ;;
    codex)
      if declare -F _run_plan_invoke_codex_hooks_config_supported >/dev/null 2>&1; then
        _run_plan_invoke_codex_hooks_config_supported "${RUNTIME:-codex}" || return 1
        return 0
      fi
      return 1
      ;;
    cursor)
      workspace="$(ralph_bg_tier_probe_workspace_root 2>/dev/null || true)"
      [[ -n "$workspace" ]] || return 1
      config_dir="$workspace/.cursor"
      ralph_bg_tier_probe_config_dir_writable "$config_dir" || return 1
      return 0
      ;;
    antigravity)
      workspace="$(ralph_bg_tier_probe_workspace_root 2>/dev/null || true)"
      [[ -n "$workspace" ]] || return 1
      config_dir="$workspace/.agents"
      ralph_bg_tier_probe_config_dir_writable "$config_dir" || return 1
      return 0
      ;;
    opencode)
      if ralph_bg_tier_probe_opencode_session_idle_proven; then
        workspace="$(ralph_bg_tier_probe_workspace_root 2>/dev/null || true)"
        [[ -n "$workspace" ]] || return 1
        config_dir="$workspace/.opencode/plugins"
        ralph_bg_tier_probe_config_dir_writable "$config_dir" || return 1
        return 0
      fi
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

ralph_bg_tier_probe_runtime_hook_reason() {
  local runtime="${1:-}"
  case "$runtime" in
    claude) printf '%s' "claude-stop-hook-block-with-stop_hook_active-guard" ;;
    codex) printf '%s' "codex-stop-hook-block-with-stop_hook_active-guard" ;;
    cursor) printf '%s' "cursor-stop-hook-followup-with-loop_limit-guard" ;;
    antigravity) printf '%s' "antigravity-stop-hook-continue-with-ralph-bg-max-per-todo-guard" ;;
    opencode)
      if ralph_bg_tier_probe_opencode_session_idle_proven; then
        printf '%s' "opencode-session-idle-continuation-proven"
      else
        printf '%s' "opencode-session-idle-not-a-turn-gate-client-injection-unproven"
      fi
      ;;
    *) printf '%s' "unsupported-runtime" ;;
  esac
}

ralph_bg_tier_probe_runtime_guard_understood() {
  local runtime="${1:-}"
  case "$runtime" in
    claude|codex) return 0 ;;
    cursor) return 0 ;;
    antigravity) return 0 ;;
    opencode)
      if ralph_bg_tier_probe_opencode_session_idle_proven; then
        return 0
      fi
      return 1
      ;;
    *) return 1 ;;
  esac
}

ralph_bg_tier_probe_evaluate() {
  local runtime="${1:-${RUNTIME:-}}"
  local override reason tier isolation_mode="" isolation_available=false
  local hook_support=false config_writable=false guard_understood=false
  local workspace="" config_dir=""

  override="$(ralph_bg_tier_probe_normalize_override "${RALPH_BG_TIER:-auto}")"

  if [[ "${RALPH_BG_JOBS:-0}" == "0" ]]; then
    tier="invocation"
    reason="bg-jobs-disabled"
    jq -nc \
      --arg tier "$tier" \
      --arg reason "$reason" \
      --arg override "$override" \
      --arg runtime "$runtime" \
      --argjson isolationAvailable false \
      --arg isolationMode "none" \
      --argjson hookSupportPresent false \
      --argjson configWritable false \
      --argjson runtimeGuardUnderstood false \
      '{
        tier: $tier,
        reason: $reason,
        override: $override,
        runtime: $runtime,
        isolationAvailable: $isolationAvailable,
        isolationMode: $isolationMode,
        hookSupportPresent: $hookSupportPresent,
        configWritable: $configWritable,
        runtimeGuardUnderstood: $runtimeGuardUnderstood
      }'
    return 0
  fi

  if isolation_mode="$(ralph_bg_tier_probe_isolation_mode 2>/dev/null)"; then
    isolation_available=true
  else
    isolation_mode="none"
    isolation_available=false
  fi

  if ralph_bg_tier_probe_runtime_hook_support "$runtime"; then
    hook_support=true
  fi

  workspace="$(ralph_bg_tier_probe_workspace_root 2>/dev/null || true)"
  case "$runtime" in
    claude) config_dir="${workspace:+$workspace/.claude}" ;;
    codex) config_dir="${workspace:+$workspace/.codex}" ;;
    cursor) config_dir="${workspace:+$workspace/.cursor}" ;;
    antigravity) config_dir="${workspace:+$workspace/.agents}" ;;
    opencode) config_dir="${workspace:+$workspace/.opencode/plugins}" ;;
  esac
  if [[ -n "$config_dir" ]] && ralph_bg_tier_probe_config_dir_writable "$config_dir"; then
    config_writable=true
  fi

  if ralph_bg_tier_probe_runtime_guard_understood "$runtime"; then
    guard_understood=true
  fi

  if [[ "$override" == "invocation" ]]; then
    tier="invocation"
    reason="forced-by-RALPH_BG_TIER"
  elif [[ "$override" == "hook" ]]; then
    if [[ "$isolation_available" != "true" ]]; then
      tier="invocation"
      reason="tier-1-unavailable: no-isolation-primitive"
    elif [[ "$hook_support" != "true" ]]; then
      tier="invocation"
      reason="tier-1-unavailable: $(ralph_bg_tier_probe_runtime_hook_reason "$runtime")"
    elif [[ "$config_writable" != "true" ]]; then
      tier="invocation"
      reason="tier-1-unavailable: hook-config-not-writable"
    elif [[ "$guard_understood" != "true" ]]; then
      tier="invocation"
      reason="tier-1-unavailable: runtime-guard-unproven"
    else
      tier="hook"
      reason="$(ralph_bg_tier_probe_runtime_hook_reason "$runtime")"
    fi
  else
    if [[ "$isolation_available" != "true" ]]; then
      tier="invocation"
      reason="fallback-no-isolation-primitive"
    elif [[ "$hook_support" != "true" ]]; then
      tier="invocation"
      reason="fallback-$(ralph_bg_tier_probe_runtime_hook_reason "$runtime")"
    elif [[ "$config_writable" != "true" ]]; then
      tier="invocation"
      reason="fallback-hook-config-not-writable"
    elif [[ "$guard_understood" != "true" ]]; then
      tier="invocation"
      reason="fallback-runtime-guard-unproven"
    else
      tier="hook"
      reason="$(ralph_bg_tier_probe_runtime_hook_reason "$runtime")"
    fi
  fi

  jq -nc \
    --arg tier "$tier" \
    --arg reason "$reason" \
    --arg override "$override" \
    --arg runtime "$runtime" \
    --argjson isolationAvailable "$isolation_available" \
    --arg isolationMode "$isolation_mode" \
    --argjson hookSupportPresent "$hook_support" \
    --argjson configWritable "$config_writable" \
    --argjson runtimeGuardUnderstood "$guard_understood" \
    '{
      tier: $tier,
      reason: $reason,
      override: $override,
      runtime: $runtime,
      isolationAvailable: $isolationAvailable,
      isolationMode: $isolationMode,
      hookSupportPresent: $hookSupportPresent,
      configWritable: $configWritable,
      runtimeGuardUnderstood: $runtimeGuardUnderstood
    }'
}

ralph_bg_tier_probe_apply() {
  local runtime="${1:-${RUNTIME:-}}" probe_json="" tier="" reason="" override=""
  probe_json="$(ralph_bg_tier_probe_evaluate "$runtime")" || return 1
  tier="$(jq -r '.tier' <<<"$probe_json")"
  reason="$(jq -r '.reason' <<<"$probe_json")"
  override="$(jq -r '.override' <<<"$probe_json")"

  export RALPH_BG_TIER_SELECTED="$tier"
  export RALPH_BG_TIER_REASON="$reason"
  export RALPH_BG_TIER_PROBE_JSON="$probe_json"

  if declare -F runtime_overlay_set_bg_tier >/dev/null 2>&1; then
    runtime_overlay_set_bg_tier "$tier"
  fi
  if declare -F runtime_overlay_set_bg_tier_reason >/dev/null 2>&1; then
    runtime_overlay_set_bg_tier_reason "$reason"
  fi
  if declare -F runtime_overlay_add_capability >/dev/null 2>&1; then
    runtime_overlay_add_capability "bg-tier-${tier}"
  fi

  ralph_bg_tier_probe_debug "selected" "runtime=${runtime} tier=${tier} reason=${reason} override=${override}"

  if [[ "$override" == "hook" && "$tier" != "hook" ]]; then
    printf '%s\n' "Error: RALPH_BG_TIER=hook requires tier-1 hook continuation but probe selected tier=${tier} (${reason})" >&2
    return 1
  fi

  printf '%s\n' "$probe_json"
  return 0
}

ralph_bg_tier_stop_hook_enabled() {
  [[ "${RALPH_BG_JOBS:-0}" != "0" ]] || return 1
  [[ "${RALPH_BG_TIER_SELECTED:-}" == "hook" ]]
}

ralph_bg_tier_hook_enabled() {
  ralph_bg_tier_stop_hook_enabled
}
