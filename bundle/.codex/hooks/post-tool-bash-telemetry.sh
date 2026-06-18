#!/usr/bin/env bash
# PostToolUse:Bash telemetry for Codex (observability only).
#
# Native shell compaction is handled via PreToolUse wrapper in pre-tool-bash-policy.sh.
# This hook is telemetry-only: it records byte counts and command hashes for audit.
# Note: Codex PostToolUse model-visible output mutation is unproven on the current CLI build.
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
  event="$(jq -r '.hook_event_name // ""' <<<"$RALPH_CODEX_POST_TOOL_INPUT")"
  tool_name="$(jq -r '.tool_name // ""' <<<"$RALPH_CODEX_POST_TOOL_INPUT")"
  if [[ "$event" != "PostToolUse" ]] || ! ralph_codex_post_tool_shell_name "$tool_name"; then
    ralph_codex_post_tool_fail_open
  fi

  log_path="${RALPH_BASH_TELEMETRY_LOG:-}"
  [[ -n "$log_path" ]] || ralph_codex_post_tool_fail_open

  command="$(jq -r '.tool_input.command // ""' <<<"$RALPH_CODEX_POST_TOOL_INPUT")"
  stdout="$(jq -r '.tool_response.stdout // ""' <<<"$RALPH_CODEX_POST_TOOL_INPUT")"
  stderr="$(jq -r '.tool_response.stderr // ""' <<<"$RALPH_CODEX_POST_TOOL_INPUT")"
  combined_bytes="$(ralph_codex_post_tool_byte_count "$(ralph_codex_post_tool_combine_streams "$stdout" "$stderr")")"
  command_hash="$(ralph_codex_post_tool_sha256 "$command")"

  local workspace plan_key timestamp line
  workspace="$(ralph_codex_post_tool_workspace)"
  plan_key="$(ralph_codex_post_tool_plan_key)"
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
