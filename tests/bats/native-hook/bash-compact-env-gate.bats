#!/usr/bin/env bats
# Prove RALPH_BASH_COMPACT=0 opts out of Claude PostToolUse:Bash compact
# replacement, and that shipped settings/hooks JSON no longer force
# RALPH_BASH_COMPACT=1 or RALPH_BASH_REWRITE=1 on the hook command line.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

FIXTURE_DIR="$REPO_ROOT/tests/fixtures/native-hook"
HOOK="$REPO_ROOT/bundle/.claude/hooks/compact-bash-output.sh"

setup() {
  _tmp="$(mktemp -d)"
  export WORKSPACE="$_tmp/workspace"
  mkdir -p "$WORKSPACE"
  export CLAUDE_PROJECT_DIR="$REPO_ROOT"
  export RALPH_BASH_COMPACT=0
  export RALPH_PLAN_KEY="bash-compact-env-gate-bats"
  bats_skip_known_ci_flakes
}

teardown() {
  rm -rf "$_tmp"
  unset WORKSPACE CLAUDE_PROJECT_DIR RALPH_BASH_COMPACT RALPH_PLAN_KEY
}

_bash_payload_from_fixture() {
  local command="$1" stdout="$2" out="$3"
  local stdout_file="$_tmp/hook-stdout"
  printf '%s' "$stdout" >"$stdout_file"
  jq --arg cmd "$command" --rawfile stdout "$stdout_file" \
    '.tool_input.command = $cmd
     | .tool_response.stdout = $stdout
     | .tool_response.stderr = ""
     | .tool_response.interrupted = false
     | .tool_response.isImage = false' \
    "$FIXTURE_DIR/bash.json" >"$out"
}

_assert_no_replacement() {
  local hook_out="$1"
  [ -z "$hook_out" ]
  ! grep -q 'updatedToolOutput' <<<"$hook_out"
  ! grep -q 'hookSpecificOutput' <<<"$hook_out"
}

@test "env-gate: RALPH_BASH_COMPACT=0 leaves compactable npm install untouched" {
  local big input
  # Family npm_install: repeated summary lines that would compact when enabled.
  big="$(python3 -c "print(('added 1 package in 2s ' * 400).strip())")"
  [ "$(printf '%s' "$big" | wc -c | tr -d ' ')" -gt 1000 ]
  input="$_tmp/npm-install.json"
  _bash_payload_from_fixture "npm install" "$big" "$input"

  run bash -c "bash '$HOOK' < '$input'"
  [ "$status" -eq 0 ]
  _assert_no_replacement "$output"
}

@test "env-gate: settings/hooks JSON omit inline RALPH_BASH_COMPACT=1 and REWRITE=1" {
  local hits
  hits="$(
    find "$REPO_ROOT/bundle" "$REPO_ROOT/.claude" \
      \( -name 'settings.json' -o -name 'hooks.json' \) \
      -print0 2>/dev/null \
      | xargs -0 grep -lE 'RALPH_BASH_(COMPACT|REWRITE)=1' 2>/dev/null || true
  )"
  # Also cover the generated Claude plugin hooks.json under plugins/.
  if grep -qE 'RALPH_BASH_(COMPACT|REWRITE)=1' \
    "$REPO_ROOT/plugins/ralph-orchestrator/claude/hooks/hooks.json" 2>/dev/null; then
    hits="${hits}"$'\n'"$REPO_ROOT/plugins/ralph-orchestrator/claude/hooks/hooks.json"
  fi
  hits="$(printf '%s\n' "$hits" | sed '/^$/d')"
  [ -z "$hits" ]
}
