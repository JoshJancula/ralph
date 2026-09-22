#!/usr/bin/env bats

# Antigravity hook changes must stay isolated from the Cursor, Claude, Codex and
# OpenCode runtimes. No runtime CLI is executed here.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  BUNDLE="$REPO_ROOT/bundle"
  OVERLAY_DIR="$BUNDLE/.ralph/bash-lib/runtime-overlay"
  AGY_HOOKS="$BUNDLE/.agents/hooks.json"
  workspace="$(mktemp -d "${TMPDIR:-/tmp}/ralph-agy-isolation-XXXXXX")"
}

teardown() {
  rm -rf "$workspace"
}

event_shape() {
  jq -c '.hooks | to_entries | map({e: .key, m: (.value | map(.matcher // null))})' "$1"
}

@test "cursor hooks.json event names and matchers are unchanged" {
  run event_shape "$BUNDLE/.cursor/hooks.json"
  [ "$status" -eq 0 ]
  [ "$output" = '[{"e":"preToolUse","m":["Shell"]},{"e":"postToolUse","m":["Shell","Read|read|readToolCall|Grep|grep|grepToolCall|Glob|glob|globToolCall|SemanticSearch|semanticSearch","MCP:*"]},{"e":"afterShellExecution","m":[null]},{"e":"stop","m":[null]}]' ]
}

@test "claude settings hooks event names and matchers are unchanged" {
  run event_shape "$BUNDLE/.claude/settings.json"
  [ "$status" -eq 0 ]
  [ "$output" = '[{"e":"PreToolUse","m":["Read|Edit|MultiEdit|Glob|Grep|LS","Bash"]},{"e":"PostToolUse","m":["Bash","Read|Grep|Glob"]},{"e":"Stop","m":[null]}]' ]
}

@test "codex hooks.json event names and matchers are unchanged" {
  run event_shape "$BUNDLE/.codex/hooks.json"
  [ "$status" -eq 0 ]
  [ "$output" = '[{"e":"PreToolUse","m":["Bash","command_execution"]},{"e":"PostToolUse","m":["Bash","command_execution","read_file","grep","Glob","Read","Grep"]}]' ]
}

@test "opencode plugin still registers its three hook entry points" {
  plugin="$BUNDLE/.opencode/plugins/ralph-runtime-hooks.ts"
  for name in '"permission.ask"' '"tool.execute.before"' '"tool.execute.after"'; do
    grep -qF "$name" "$plugin"
  done
}

@test "agy hooks.json contains no Cursor-shaped tokens" {
  for token in preToolUse postToolUse afterShellExecution Shell updated_input; do
    run grep -F "\"$token\"" "$AGY_HOOKS"
    [ "$status" -ne 0 ]
    run grep -F "$token" "$AGY_HOOKS"
    [ "$status" -ne 0 ]
  done
}

@test "other runtime hook scripts never reference the agy tree or overlay" {
  run grep -rIlE '\.agents/|runtime-overlay-antigravity' \
    "$BUNDLE/.cursor/hooks" "$BUNDLE/.claude/hooks" "$BUNDLE/.codex/hooks" "$BUNDLE/.opencode/plugins" \
    "$BUNDLE/.cursor/hooks.json" "$BUNDLE/.claude/settings.json" "$BUNDLE/.codex/hooks.json"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "agy overlay defines no function that another runtime overlay defines" {
  agy_funcs="$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*\(\)' "$OVERLAY_DIR/runtime-overlay-antigravity.sh" | sort -u)"
  [ -n "$agy_funcs" ]
  others="$(cat "$OVERLAY_DIR"/runtime-overlay-cursor.sh "$OVERLAY_DIR"/runtime-overlay-claude.sh \
    "$OVERLAY_DIR"/runtime-overlay-codex.sh "$OVERLAY_DIR"/runtime-overlay-opencode.sh \
    | grep -oE '^[A-Za-z_][A-Za-z0-9_]*\(\)' | sort -u)"
  run comm -12 <(printf '%s\n' "$agy_funcs") <(printf '%s\n' "$others")
  [ -z "$output" ]
}

@test "sourcing the agy overlay after another overlay leaves that overlay's functions intact" {
  command -v python3 >/dev/null 2>&1 || skip "python3 not available"
  run bash -c '
    source "$1/runtime-overlay-codex.sh"
    before="$(declare -f ralph_native_hooks_want_activation)"
    source "$1/runtime-overlay-antigravity.sh"
    [ "$before" = "$(declare -f ralph_native_hooks_want_activation)" ]
  ' _ "$OVERLAY_DIR"
  [ "$status" -eq 0 ]
}

@test "merge then restore returns a user-authored hooks.json byte-identical" {
  command -v python3 >/dev/null 2>&1 || skip "python3 not available"
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  mkdir -p "$workspace/.agents"
  cat >"$workspace/.agents/hooks.json" <<'JSON'
{"user-hook":{"PreToolUse":[{"matcher":"run_command","hooks":[{"command":"/opt/u.sh","timeout":10}]}]},
   "z":  [1,   2]}
JSON
  cp "$workspace/.agents/hooks.json" "$workspace/original.json"

  run bash -c '
    set -euo pipefail
    export WORKSPACE="$2"
    ralph_mcp_overlay_lifecycle_available() { return 1; }
    ralph_mcp_overlay_register_runtime_cleanup() { :; }
    source "$1/runtime-overlay-antigravity.sh"
    run_plan_invoke_antigravity_hooks_config_prepare
    jq -e "has(\"ralph-native\") and has(\"user-hook\")" "$WORKSPACE/.agents/hooks.json" >/dev/null
    run_plan_invoke_antigravity_hooks_config_cleanup
  ' _ "$OVERLAY_DIR" "$workspace"
  [ "$status" -eq 0 ]
  cmp "$workspace/.agents/hooks.json" "$workspace/original.json"
  [ ! -e "$workspace/.agents/hooks/pre-tool-shell-policy.sh" ]
}
