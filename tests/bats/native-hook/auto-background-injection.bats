#!/usr/bin/env bats
# PreToolUse auto-background injection via rewrite-bash-command.sh
# (PLAN-HOOK-DIET auto-background-injection). Spike-proven path: inject
# run_in_background:true when the auto_background channel is effective and
# command_profiles marks the fingerprint long_running and not denylisted.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

HOOK="$REPO_ROOT/bundle/.claude/hooks/rewrite-bash-command.sh"

setup() {
  _tmp="$(mktemp -d)"
  export CLAUDE_PROJECT_DIR="$_tmp/project"
  mkdir -p "$CLAUDE_PROJECT_DIR"
  ln -sfn "$REPO_ROOT/.ralph" "$CLAUDE_PROJECT_DIR/.ralph"
  # Pin state root to the temp project so ambient RALPH_PLAN_WORKSPACE_ROOT
  # from a parent plan run does not redirect profile reads/writes.
  export RALPH_PLAN_WORKSPACE_ROOT="$CLAUDE_PROJECT_DIR/.ralph-workspace"
  export RALPH_PLAN_KEY="auto-bg-inject-bats"
  unset RALPH_BASH_REWRITE
  bats_skip_known_ci_flakes
}

teardown() {
  rm -rf "$_tmp"
  unset CLAUDE_PROJECT_DIR RALPH_PLAN_KEY RALPH_MODE RALPH_BASH_REWRITE RALPH_PLAN_WORKSPACE_ROOT
}

_store_dir() {
  printf '%s/.ralph-workspace/command-profiles\n' "$CLAUDE_PROJECT_DIR"
}

_expected_fingerprint() {
  local command="$1"
  python3 -c "
import sys
sys.path.insert(0, '$REPO_ROOT/bundle/.ralph/python')
from command_fingerprint import fingerprint
print(fingerprint(sys.argv[1]) or '')
" "$command"
}

_seed_long_running() {
  local command="$1"
  local fingerprint
  fingerprint="$(_expected_fingerprint "$command")"
  [ -n "$fingerprint" ]
  mkdir -p "$(_store_dir)"
  python3 -c "
import sys
from pathlib import Path
sys.path.insert(0, '$REPO_ROOT/bundle/.ralph/python')
from command_profiles import record_observation
state = Path('$CLAUDE_PROJECT_DIR') / '.ralph-workspace'
entry = record_observation(state, sys.argv[1], sys.argv[2], 90000)
assert entry is not None and entry.get('long_running') is True, entry
" "$fingerprint" "$command"
  printf '%s\n' "$fingerprint"
}

_pretool_json() {
  local command="$1"
  jq -nc \
    --arg cmd "$command" \
    --arg cwd "$CLAUDE_PROJECT_DIR" \
    '{
      hook_event_name: "PreToolUse",
      tool_name: "Bash",
      cwd: $cwd,
      tool_input: {command: $cmd}
    }'
}

@test "long_running non-denylisted fingerprint injects run_in_background when channel effective" {
  local cmd fp input hook_out
  cmd="bash scripts/run-bats.sh"
  fp="$(_seed_long_running "$cmd")"
  [ -n "$fp" ]
  input="$_tmp/inject-on.json"
  _pretool_json "$cmd" >"$input"

  export RALPH_MODE=hybrid
  run bash -c "bash '$HOOK' < '$input'"
  [ "$status" -eq 0 ]
  hook_out="$output"
  run jq -e '.hookSpecificOutput.updatedInput.run_in_background == true' <<<"$hook_out"
  [ "$status" -eq 0 ]
  run jq -e --arg cmd "$cmd" '.hookSpecificOutput.updatedInput.command == $cmd' <<<"$hook_out"
  [ "$status" -eq 0 ]
}

@test "same long_running input produces no injection when RALPH_MODE is no" {
  local cmd input
  cmd="bash scripts/run-bats.sh"
  _seed_long_running "$cmd" >/dev/null
  input="$_tmp/inject-mode-no.json"
  _pretool_json "$cmd" >"$input"

  export RALPH_MODE=no
  run bash -c "bash '$HOOK' < '$input'"
  [ "$status" -eq 0 ]
  [[ "$output" != *run_in_background* ]]
}

@test "denylisted command is never injected even when long_running and channel effective" {
  local cmd input
  cmd="npm install"
  _seed_long_running "$cmd" >/dev/null
  input="$_tmp/inject-deny.json"
  _pretool_json "$cmd" >"$input"

  export RALPH_MODE=hybrid
  run bash -c "bash '$HOOK' < '$input'"
  [ "$status" -eq 0 ]
  [[ "$output" != *run_in_background* ]]
}

@test "unknown fingerprint is never injected when channel effective" {
  local cmd input
  cmd="bash scripts/run-bats.sh"
  # Do not seed the store — fingerprint is unknown.
  input="$_tmp/inject-unknown.json"
  _pretool_json "$cmd" >"$input"

  export RALPH_MODE=hybrid
  run bash -c "bash '$HOOK' < '$input'"
  [ "$status" -eq 0 ]
  [[ "$output" != *run_in_background* ]]
}
