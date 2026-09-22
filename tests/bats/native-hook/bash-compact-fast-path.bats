#!/usr/bin/env bats
# Fast path for Claude PostToolUse:Bash compact-bash-output.sh: tiny + fast
# payloads must exit before sourcing libraries / launching python3.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

HOOK="$REPO_ROOT/bundle/.claude/hooks/compact-bash-output.sh"

setup() {
  _tmp="$(mktemp -d)"
  export CLAUDE_PROJECT_DIR="$REPO_ROOT"
  export RALPH_BASH_COMPACT=1
  export RALPH_PLAN_KEY="bash-compact-fast-path-bats"
  bats_skip_known_ci_flakes
}

teardown() {
  rm -rf "$_tmp"
  unset CLAUDE_PROJECT_DIR RALPH_BASH_COMPACT RALPH_PLAN_KEY
}

_tiny_fast_payload() {
  local out="$1"
  jq -n '{
    hook_event_name: "PostToolUse",
    tool_name: "Bash",
    tool_input: {command: "echo hi"},
    tool_response: {
      stdout: "hi\n",
      stderr: "",
      interrupted: false,
      isImage: false
    },
    duration_ms: 50
  }' >"$out"
}

@test "compact-bash fast-path: tiny payload skips python3" {
  local input stub_bin
  input="$_tmp/echo-hi.json"
  _tiny_fast_payload "$input"

  stub_bin="$_tmp/stub-bin"
  mkdir -p "$stub_bin"
  # Shadow python3 so a slow-path launch would fail the hook turn.
  cat >"$stub_bin/python3" <<'EOF'
#!/bin/sh
exit 99
EOF
  chmod +x "$stub_bin/python3"

  run bash -c "PATH='$stub_bin:'\"\$PATH\" bash '$HOOK' < '$input'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "compact-bash fast-path: 20KB npm install still compacted" {
  local big input stdout_file compact_stdout
  # Family npm_install needs a recognizable summary line to rewrite successfully.
  big="$(python3 -c "
lines = ['npm notice fetching ' + ('pkg-' + str(i)).ljust(80, 'x') for i in range(300)]
lines.append('added 42 packages in 3s')
print('\\n'.join(lines))
")"
  [ "$(printf '%s' "$big" | wc -c | tr -d ' ')" -ge 20480 ]
  stdout_file="$_tmp/npm-stdout.txt"
  printf '%s' "$big" >"$stdout_file"
  input="$_tmp/npm-install.json"
  jq -n --arg cmd "npm install" --rawfile stdout "$stdout_file" '{
    hook_event_name: "PostToolUse",
    tool_name: "Bash",
    tool_input: {command: $cmd},
    tool_response: {
      stdout: $stdout,
      stderr: "",
      interrupted: false,
      isImage: false
    },
    duration_ms: 2500
  }' >"$input"

  run bash -c "bash '$HOOK' < '$input'"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  echo "$output" | jq -e '.hookSpecificOutput.updatedToolOutput' >/dev/null
  compact_stdout="$(echo "$output" | jq -r '.hookSpecificOutput.updatedToolOutput.stdout')"
  [ -n "$compact_stdout" ]
  [ "$(printf '%s' "$compact_stdout" | wc -c | tr -d ' ')" -lt "$(printf '%s' "$big" | wc -c | tr -d ' ')" ]
}
