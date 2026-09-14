#!/usr/bin/env bash
# PostToolUse:Bash telemetry + duration learning for Codex.
#
# Native shell compaction is handled via PreToolUse wrapper in pre-tool-bash-policy.sh.
# Codex PostToolUse payloads do not include duration_ms (observed keys: cwd,
# hook_event_name, model, permission_mode, session_id, tool_input, tool_name,
# tool_response, tool_use_id, transcript_path, turn_id). Duration learning uses
# pre/post inflight pairing keyed by tool_use_id.
#
# Optional JSONL audit path: RALPH_BASH_TELEMETRY_LOG
# Gate: RALPH_NATIVE_HOOKS=on|auto with optimization mode, or RALPH_BASH_TELEMETRY_LOG set.

set -uo pipefail

ralph_codex_post_tool_fail_open() {
  exit 0
}

ralph_codex_post_tool_shell_name() {
  case "${1:-}" in
    Bash | command_execution) return 0 ;;
    *) return 1 ;;
  esac
}

ralph_codex_post_tool_workspace() {
  if [[ -n "${WORKSPACE:-}" ]]; then
    printf '%s\n' "$WORKSPACE"
    return 0
  fi
  jq -r '.cwd // empty' <<<"${RALPH_CODEX_POST_TOOL_INPUT:-{}}"
}

ralph_codex_post_tool_plan_key() {
  if [[ -n "${RALPH_PLAN_KEY:-}" ]]; then
    printf '%s\n' "$RALPH_PLAN_KEY"
    return 0
  fi
  if [[ -n "${RALPH_ARTIFACT_NS:-}" ]]; then
    printf '%s\n' "$RALPH_ARTIFACT_NS"
    return 0
  fi
  printf 'codex-hook\n'
}

ralph_codex_post_tool_sha256() {
  local text="${1-}"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.argv[1].encode("utf-8")).hexdigest())' "$text"
    return 0
  fi
  printf ''
}

ralph_codex_post_tool_byte_count() {
  local text="${1-}"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import sys; print(len(sys.argv[1].encode("utf-8")))' "$text"
    return 0
  fi
  printf '%s' "$text" | wc -c | tr -d ' '
}

ralph_codex_post_tool_combine_streams() {
  local stdout="${1-}" stderr="${2-}"
  if [[ -n "$stderr" ]]; then
    if [[ -n "$stdout" ]]; then
      printf '%s\n%s' "$stdout" "$stderr"
    else
      printf '%s' "$stderr"
    fi
  else
    printf '%s' "$stdout"
  fi
}

ralph_codex_post_tool_main() {
  command -v jq >/dev/null 2>&1 || ralph_codex_post_tool_fail_open

  RALPH_CODEX_POST_TOOL_INPUT="$(cat)" || ralph_codex_post_tool_fail_open

  local event tool_name command stdout stderr combined_bytes command_hash log_path
  local workspace plan_key timestamp line invocation_id duration_raw duration_ms fingerprint
  event="$(jq -r '.hook_event_name // ""' <<<"$RALPH_CODEX_POST_TOOL_INPUT")"
  tool_name="$(jq -r '.tool_name // ""' <<<"$RALPH_CODEX_POST_TOOL_INPUT")"
  if [[ "$event" != "PostToolUse" ]] || ! ralph_codex_post_tool_shell_name "$tool_name"; then
    ralph_codex_post_tool_fail_open
  fi

  command="$(jq -r '.tool_input.command // ""' <<<"$RALPH_CODEX_POST_TOOL_INPUT")"
  stdout="$(jq -r '.tool_response.stdout // ""' <<<"$RALPH_CODEX_POST_TOOL_INPUT")"
  stderr="$(jq -r '.tool_response.stderr // ""' <<<"$RALPH_CODEX_POST_TOOL_INPUT")"
  invocation_id="$(jq -r '.tool_use_id // empty' <<<"$RALPH_CODEX_POST_TOOL_INPUT")"
  workspace="$(ralph_codex_post_tool_workspace)"
  plan_key="$(ralph_codex_post_tool_plan_key)"

  _NATIVE_HOOK_BOOTSTRAP="${BASH_SOURCE%/*}/../../.ralph/bash-lib/native-hook/native-hook-bootstrap.sh"
  if [[ ! -f "$_NATIVE_HOOK_BOOTSTRAP" ]]; then
    _NATIVE_HOOK_BOOTSTRAP="${RALPH_HOME:-${HOME:-}/.ralph}/bundle/.ralph/bash-lib/native-hook/native-hook-bootstrap.sh"
  fi
  if [[ -n "$workspace" && -f "$_NATIVE_HOOK_BOOTSTRAP" ]]; then
    # shellcheck source=/dev/null
    source "$_NATIVE_HOOK_BOOTSTRAP"
    ralph_native_hook_bootstrap_source_lib || true
    # Forward-compat: if Codex ever adds duration_ms, prefer it over pairing.
    duration_raw="$(jq -r '.duration_ms // .duration // empty' <<<"$RALPH_CODEX_POST_TOOL_INPUT")"
    duration_ms=""
    if [[ "$duration_raw" =~ ^[0-9]+$ ]]; then
      duration_ms="$duration_raw"
      fingerprint="$(ralph_native_hook_command_fingerprint "$workspace" "$command" 2>/dev/null || true)"
      ralph_native_hook_maybe_record_duration \
        "$workspace" "$command" "$fingerprint" "$duration_ms" "false" || true
    else
      ralph_native_hook_complete_inflight "$workspace" "$command" "$invocation_id" || true
    fi
  fi

  log_path="${RALPH_BASH_TELEMETRY_LOG:-}"
  [[ -n "$log_path" ]] || ralph_codex_post_tool_fail_open

  combined_bytes="$(ralph_codex_post_tool_byte_count "$(ralph_codex_post_tool_combine_streams "$stdout" "$stderr")")"
  command_hash="$(ralph_codex_post_tool_sha256 "$command")"
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  line="$(
    jq -nc \
      --arg timestamp "$timestamp" \
      --arg workspace "$workspace" \
      --arg planKey "$plan_key" \
      --arg commandHash "$command_hash" \
      --argjson originalBytes "$combined_bytes" \
      --arg runtime "codex" \
      '{
        timestamp: $timestamp,
        workspace: $workspace,
        planKey: $planKey,
        runtime: $runtime,
        commandHash: $commandHash,
        originalBytes: $originalBytes,
        compactionSkipped: true
      }'
  )"

  mkdir -p "$(dirname "$log_path")" 2>/dev/null || true
  printf '%s\n' "$line" >>"$log_path" 2>/dev/null || true
  ralph_codex_post_tool_fail_open
}

ralph_codex_post_tool_main
