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
  jq -e --arg cmd "$runtime_dir/hooks/compact-bash-output.sh" '.hooks.PostToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.command == $cmd)' "$runtime_dir/settings.json"
  jq -e --arg cmd "$runtime_dir/hooks/native-result-compact.sh" '.hooks.PostToolUse[] | select(.matcher == "Read|Grep|Glob") | .hooks[] | select(.command == $cmd)' "$runtime_dir/settings.json"
}

@test "Claude setup repairs legacy paths and runs from unrelated directories with shell-safe quoting" {
  command -v python3 >/dev/null || skip "python3 required"
  source "$SETUP_HELPERS_SH"
  source "$SETUP_HOOKS_SH"
  local runtime_dir="$TEST_TEMP_DIR/user's home \$(false)/.claude"
  mkdir -p "$runtime_dir" "$TEST_TEMP_DIR/project/package"
  cp "$REPO_ROOT/bundle/.claude/settings.json" "$runtime_dir/settings.json"
  setup_hooks_claude "$runtime_dir"
  cp "$runtime_dir/settings.json" "$TEST_TEMP_DIR/first.json"
  setup_hooks_claude "$runtime_dir"
  cmp "$runtime_dir/settings.json" "$TEST_TEMP_DIR/first.json"
  run python3 - "$runtime_dir/settings.json" "$TEST_TEMP_DIR/project/package" <<'PY'
import json, os, shlex, subprocess, sys
settings = json.load(open(sys.argv[1]))
for groups in settings['hooks'].values():
    for group in groups:
        for hook in group['hooks']:
            command = hook['command']
            executable, = shlex.split(command)
            assert os.path.isabs(executable) and os.access(executable, os.X_OK)
            result = subprocess.run(command, shell=True, cwd=sys.argv[2], input='{}',
                                    text=True, capture_output=True)
            assert result.returncode == 0, (command, result.stderr)
PY
  [ "$status" -eq 0 ]
}

@test "Claude hook removal recognizes quoted absolute paths" {
  command -v python3 >/dev/null || skip "python3 required"
  source "$SETUP_HELPERS_SH"
  source "$SETUP_HOOKS_SH"
  local runtime_dir="$TEST_TEMP_DIR/user's home/.claude"
  setup_hooks_claude "$runtime_dir"
  # Exercise the removal classifier without writing runtime configuration.
  run python3 - "$REPO_ROOT/bundle/.ralph/python" "$runtime_dir/settings.json" <<'PY'
import importlib.util, json, pathlib, sys
spec = importlib.util.spec_from_file_location('remove', pathlib.Path(sys.argv[1]) / 'setup-remove-json.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
data = json.load(open(sys.argv[2]))
reserved = {'block-env-reads.sh', 'rewrite-bash-command.sh', 'compact-bash-output.sh',
            'native-result-compact.sh', 'stop-continuation.sh'}
assert module._remove_hooks(data, reserved)
assert all(not group.get('hooks') for groups in data.get('hooks', {}).values() for group in groups), data
PY
  [ "$status" -eq 0 ]
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

# Clean hooks fixture: runtime dir with an unrelated native agent already present.
_fixture_hooks_with_native_agent() {
  local runtime_dir="$1"
  local marker="${2:-native-agent-marker-do-not-touch}"
  mkdir -p "$runtime_dir/agents/my-native-agent"
  printf '%s\n' "$marker" >"$runtime_dir/agents/my-native-agent/my-native-agent.md"
  # Stale six-ID leftover must also remain untouched (setup never validates agents).
  mkdir -p "$runtime_dir/agents/research"
  printf 'stale-six\n' >"$runtime_dir/agents/research/research.md"
}

@test "clean setup hooks continue and preserve unrelated native agent" {
  command -v jq >/dev/null || skip "jq required"
  command -v python3 >/dev/null || skip "python3 required"
  [ -f "$SETUP_HOOKS_SH" ] || skip "setup-hooks.sh missing"

  local runtime_dir="$TEST_TEMP_DIR/.cursor"
  local marker="native-agent-marker-do-not-touch"
  _fixture_hooks_with_native_agent "$runtime_dir" "$marker"
  printf '%s' '{"version":1,"hooks":{},"keep":"value"}' >"$runtime_dir/hooks.json"

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
  [ -f "$runtime_dir/agents/my-native-agent/my-native-agent.md" ]
  [[ "$(cat "$runtime_dir/agents/my-native-agent/my-native-agent.md")" == "$marker" ]]
  [ -f "$runtime_dir/agents/research/research.md" ]
  [[ "$(cat "$runtime_dir/agents/research/research.md")" == "stale-six" ]]
  # Clean setup must not create additional Ralph six-profile agent dirs.
  [ ! -d "$runtime_dir/agents/architect" ]
  [ ! -d "$runtime_dir/agents/code-review" ]
  [ ! -d "$runtime_dir/agents/implementation" ]
  [ ! -d "$runtime_dir/agents/qa" ]
  [ ! -d "$runtime_dir/agents/security" ]
}

@test "clean setup hooks leave native agent dirs untouched for claude" {
  command -v jq >/dev/null || skip "jq required"
  command -v python3 >/dev/null || skip "python3 required"
  [ -f "$SETUP_HOOKS_SH" ] || skip "setup-hooks.sh missing"

  local runtime_dir="$TEST_TEMP_DIR/.claude"
  local marker="claude-native-agent-keep"
  _fixture_hooks_with_native_agent "$runtime_dir" "$marker"
  printf '%s\n' '{"env":{"CUSTOM_FLAG":"keep-me"}}' >"$runtime_dir/settings.json"

  run bash -c "
    set -euo pipefail
    source \"$SETUP_HELPERS_SH\"
    source \"$SETUP_HOOKS_SH\"
    export BUNDLE_ROOT=\"$BUNDLE_ROOT\"
    setup_hooks_claude \"$runtime_dir\"
  "
  [ "$status" -eq 0 ]
  [ -x "$runtime_dir/hooks/block-env-reads.sh" ]
  [ -f "$runtime_dir/agents/my-native-agent/my-native-agent.md" ]
  [[ "$(cat "$runtime_dir/agents/my-native-agent/my-native-agent.md")" == "$marker" ]]
  [ ! -d "$runtime_dir/agents/architect" ]
}
