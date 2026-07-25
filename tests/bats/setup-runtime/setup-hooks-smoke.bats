#!/usr/bin/env bats
# Smoke coverage for durable hook setup across runtimes.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

SETUP_HELPERS_SH="$REPO_ROOT/bundle/.ralph/bash-lib/setup/setup-helpers.sh"
SETUP_HOOKS_SH="$REPO_ROOT/bundle/.ralph/bash-lib/setup/setup-hooks.sh"

setup() {
  TEST_TEMP_DIR="$(mktemp -d)"
  export TEST_TEMP_DIR
  export BUNDLE_ROOT="$REPO_ROOT/bundle"
}

teardown() {
  if [[ -d "${TEST_TEMP_DIR:-}" ]]; then
    rm -rf "$TEST_TEMP_DIR"
  fi
}

@test "setup_hooks_claude copies hook scripts and preserves existing settings" {
  command -v jq >/dev/null || skip "jq required"
  command -v python3 >/dev/null || skip "python3 required"
  [ -f "$SETUP_HOOKS_SH" ] || skip "setup-hooks.sh missing"

  local runtime_dir="$TEST_TEMP_DIR/.claude"
  mkdir -p "$runtime_dir"
  printf '%s\n' '{"env":{"CUSTOM_FLAG":"keep-me"},"other":123}' >"$runtime_dir/settings.json"

  run bash -c "
    set -euo pipefail
    source \"$SETUP_HELPERS_SH\"
    source \"$SETUP_HOOKS_SH\"
    export BUNDLE_ROOT=\"$BUNDLE_ROOT\"
    setup_hooks_claude \"$runtime_dir\"
  "
  [ "$status" -eq 0 ]
  [ -x "$runtime_dir/hooks/block-env-reads.sh" ]
  [ -x "$runtime_dir/hooks/native-result-compact.sh" ]
  jq -e '.env.CUSTOM_FLAG == "keep-me"' "$runtime_dir/settings.json"
  jq -e '.hooks.PostToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.command == "RALPH_BASH_COMPACT=1 .claude/hooks/compact-bash-output.sh")' "$runtime_dir/settings.json"
  jq -e '.hooks.PostToolUse[] | select(.matcher == "Read|Grep|Glob") | .hooks[] | select(.command == "RALPH_NATIVE_RESULT_COMPACT=1 .claude/hooks/native-result-compact.sh")' "$runtime_dir/settings.json"
}

@test "setup_hooks_cursor copies hook scripts and preserves existing hooks.json" {
  command -v jq >/dev/null || skip "jq required"
  command -v python3 >/dev/null || skip "python3 required"
  [ -f "$SETUP_HOOKS_SH" ] || skip "setup-hooks.sh missing"

  local runtime_dir="$TEST_TEMP_DIR/.cursor"
  mkdir -p "$runtime_dir"
  printf '%s' '{"version":1,"hooks":{"preToolUse":[{"command":"./keep-me.sh"}]},"keep":"value"}' \
    >"$runtime_dir/hooks.json"

  run bash -c "
    set -euo pipefail
    source \"$SETUP_HELPERS_SH\"
    source \"$SETUP_HOOKS_SH\"
    export BUNDLE_ROOT=\"$BUNDLE_ROOT\"
    setup_hooks_cursor \"$runtime_dir\"
  "
  [ "$status" -eq 0 ]
  [ -x "$runtime_dir/hooks/pre-tool-shell-policy.sh" ]
  jq -e '.keep == "value"' "$runtime_dir/hooks.json"
}

@test "setup_hooks_codex copies hook scripts and preserves existing hooks.json" {
  command -v jq >/dev/null || skip "jq required"
  command -v python3 >/dev/null || skip "python3 required"
  [ -f "$SETUP_HOOKS_SH" ] || skip "setup-hooks.sh missing"

  local runtime_dir="$TEST_TEMP_DIR/.codex"
  mkdir -p "$runtime_dir"
  printf '%s\n' '{"custom":"keep-me","hooks":{"Stop":[{"hooks":[{"type":"command","command":"./keep-me.sh"}]}]}}' \
    >"$runtime_dir/hooks.json"

  run bash -c "
    set -euo pipefail
    source \"$SETUP_HELPERS_SH\"
    source \"$SETUP_HOOKS_SH\"
    export BUNDLE_ROOT=\"$BUNDLE_ROOT\"
    setup_hooks_codex \"$runtime_dir\"
  "
  [ "$status" -eq 0 ]
  [ -x "$runtime_dir/hooks/pre-tool-bash-policy.sh" ]
  jq -e '.custom == "keep-me"' "$runtime_dir/hooks.json"
}

@test "setup_hooks_opencode stages plugin when bundle plugin exists" {
  command -v jq >/dev/null || skip "jq required"
  [ -f "$SETUP_HOOKS_SH" ] || skip "setup-hooks.sh missing"

  local runtime_dir="$TEST_TEMP_DIR/.opencode"
  mkdir -p "$runtime_dir"

  run bash -c "
    set -euo pipefail
    source \"$SETUP_HELPERS_SH\"
    source \"$SETUP_HOOKS_SH\"
    export BUNDLE_ROOT=\"$BUNDLE_ROOT\"
    setup_hooks_opencode \"$runtime_dir\"
  "
  [ "$status" -eq 0 ]
  local plugin
  plugin="$(find "$runtime_dir/plugins" -maxdepth 1 -type f \( -name 'ralph-runtime-hooks.ts' -o -name 'ralph-runtime-hooks.mjs' -o -name 'ralph-runtime-hooks.js' \) 2>/dev/null | head -1)"
  [ -n "$plugin" ]
}
