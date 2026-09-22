#!/usr/bin/env bats

# Antigravity named-hook overlay merge: only the ralph-native key is owned by Ralph.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  OVERLAY="$REPO_ROOT/bundle/.ralph/bash-lib/runtime-overlay/runtime-overlay-antigravity.sh"
  TEMPLATE="$REPO_ROOT/bundle/.agents/hooks.json"
  workspace="$(mktemp -d "${TMPDIR:-/tmp}/ralph-agy-overlay-XXXXXX")"
  mkdir -p "$workspace/.agents"
  HOOKS="$workspace/.agents/hooks.json"
  command -v python3 >/dev/null 2>&1 || skip "python3 not available"
  # shellcheck disable=SC1090
  source "$OVERLAY"
}

teardown() {
  rm -rf "$workspace"
}

@test "merge into a missing file writes only the ralph-native key" {
  runtime_overlay_antigravity_merge_hooks_file "$HOOKS" "$TEMPLATE" 0
  jq -e '(keys == ["ralph-native"]) and (.["ralph-native"].PreToolUse[0].matcher == "run_command")' "$HOOKS" >/dev/null
  jq -e '.["ralph-native"] | has("Stop") | not' "$HOOKS" >/dev/null
}

@test "merge preserves other named hooks and is idempotent" {
  printf '%s\n' '{"user-hook":{"PreToolUse":[{"matcher":"run_command","hooks":[{"command":"/opt/u.sh"}]}]}}' >"$HOOKS"
  runtime_overlay_antigravity_merge_hooks_file "$HOOKS" "$TEMPLATE" 1
  first="$(jq -S . "$HOOKS")"
  runtime_overlay_antigravity_merge_hooks_file "$HOOKS" "$TEMPLATE" 1
  [ "$first" = "$(jq -S . "$HOOKS")" ]
  jq -e '.["user-hook"].PreToolUse[0].hooks[0].command == "/opt/u.sh"' "$HOOKS" >/dev/null
  jq -e '.["ralph-native"].Stop[0].timeout == 5400' "$HOOKS" >/dev/null
}

@test "stop timeout follows RALPH_BG_HOOK_TIMEOUT" {
  RALPH_BG_HOOK_TIMEOUT=123 runtime_overlay_antigravity_merge_hooks_file "$HOOKS" "$TEMPLATE" 1
  jq -e '.["ralph-native"].Stop[0].timeout == 123' "$HOOKS" >/dev/null
}

@test "merge strips only Ralph entries from a legacy cursor-shaped file" {
  cat >"$HOOKS" <<'JSON'
{"version":1,"keep":"user","hooks":{
  "preToolUse":[{"command":".agents/hooks/pre-tool-shell-policy.sh","matcher":"Shell"},{"command":"./keep-me.sh"}],
  "afterShellExecution":[{"command":".agents/hooks/after-shell-telemetry.sh"}]}}
JSON
  runtime_overlay_antigravity_merge_hooks_file "$HOOKS" "$TEMPLATE" 0
  jq -e '.keep == "user" and .version == 1 and (.hooks.preToolUse | length == 1) and (.hooks.preToolUse[0].command == "./keep-me.sh") and (.hooks | has("afterShellExecution") | not) and has("ralph-native")' "$HOOKS" >/dev/null
}

@test "merge drops a legacy file that held only Ralph entries down to ralph-native" {
  printf '%s\n' '{"version":1,"hooks":{"Stop":[{"command":".agents/hooks/stop-continuation.sh"}]}}' >"$HOOKS"
  runtime_overlay_antigravity_merge_hooks_file "$HOOKS" "$TEMPLATE" 0
  jq -e 'keys == ["ralph-native"]' "$HOOKS" >/dev/null
}

@test "detection looks for the ralph-native key" {
  run runtime_overlay_antigravity_hooks_detected_in_file "$HOOKS"
  [ "$status" -ne 0 ]
  printf '%s\n' '{"user-hook":{}}' >"$HOOKS"
  run runtime_overlay_antigravity_hooks_detected_in_file "$HOOKS"
  [ "$status" -ne 0 ]
  runtime_overlay_antigravity_merge_hooks_file "$HOOKS" "$TEMPLATE" 0
  runtime_overlay_antigravity_hooks_detected_in_file "$HOOKS"
}
