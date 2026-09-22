#!/usr/bin/env bats
# Disabled native-result compact: wrappers must exit before sourcing libraries
# or launching python3 (D5 / e3).

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

CLAUDE_HOOK="$REPO_ROOT/bundle/.claude/hooks/native-result-compact.sh"
CURSOR_HOOK="$REPO_ROOT/bundle/.cursor/hooks/post-tool-native-result-compact.sh"
SHARED_HOOK="$REPO_ROOT/bundle/.ralph/bash-lib/native-hook/post-tool-native-result-compact-hook.sh"
BLOCK_ENV_HOOK="$REPO_ROOT/bundle/.claude/hooks/block-env-reads.sh"
FIXTURE_DIR="$REPO_ROOT/tests/fixtures/native-hook"

setup() {
  _tmp="$(mktemp -d)"
  export CLAUDE_PROJECT_DIR="$REPO_ROOT"
  unset RALPH_NATIVE_RESULT_COMPACT RALPH_CURSOR_NATIVE_RESULT_HOOK_COMPACT
  bats_skip_known_ci_flakes
}

teardown() {
  rm -rf "$_tmp"
  unset CLAUDE_PROJECT_DIR RALPH_NATIVE_RESULT_COMPACT RALPH_CURSOR_NATIVE_RESULT_HOOK_COMPACT
  unset BASH_ENV
}

_make_python99_stub_bin() {
  local stub_bin="$_tmp/stub-bin"
  mkdir -p "$stub_bin"
  cat >"$stub_bin/python3" <<'EOF'
#!/bin/sh
exit 99
EOF
  chmod +x "$stub_bin/python3"
  printf '%s\n' "$stub_bin"
}

_make_bash_env_counter() {
  local counter_file="$1"
  local bash_env="$2"
  : >"$counter_file"
  cat >"$bash_env" <<EOF
echo source >>'$counter_file'
EOF
}

@test "native-result disabled: wrapper exits without sourcing libs or python3" {
  local stub_bin bash_env counter input count
  stub_bin="$(_make_python99_stub_bin)"
  counter="$_tmp/source-count.txt"
  bash_env="$_tmp/bash-env.sh"
  _make_bash_env_counter "$counter" "$bash_env"
  input="$FIXTURE_DIR/read.json"
  [[ -f "$input" ]]

  # Unset gates (default off). BASH_ENV fires once for the wrapper bash; early
  # exit must not exec the shared hook (which would fire BASH_ENV again).
  run bash -c "PATH='$stub_bin:'\"\$PATH\" BASH_ENV='$bash_env' bash '$CLAUDE_HOOK' < '$input'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  count="$(wc -l <"$counter" | tr -d ' ')"
  [ "$count" -eq 1 ]

  : >"$counter"
  run bash -c "PATH='$stub_bin:'\"\$PATH\" BASH_ENV='$bash_env' bash '$CURSOR_HOOK' < '$input'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  count="$(wc -l <"$counter" | tr -d ' ')"
  [ "$count" -eq 1 ]

  : >"$counter"
  export RALPH_NATIVE_RESULT_COMPACT=0
  run bash -c "PATH='$stub_bin:'\"\$PATH\" BASH_ENV='$bash_env' bash '$CLAUDE_HOOK' < '$input'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  count="$(wc -l <"$counter" | tr -d ' ')"
  [ "$count" -eq 1 ]
}

@test "native-result disabled: shared hook exits before source when gate off" {
  local stub_bin bash_env counter input count
  stub_bin="$(_make_python99_stub_bin)"
  counter="$_tmp/source-count.txt"
  bash_env="$_tmp/bash-env.sh"
  _make_bash_env_counter "$counter" "$bash_env"
  input="$FIXTURE_DIR/read.json"

  # Direct shared-hook invoke with gate off: BASH_ENV once, no library work.
  unset RALPH_NATIVE_RESULT_COMPACT RALPH_CURSOR_NATIVE_RESULT_HOOK_COMPACT
  run bash -c "PATH='$stub_bin:'\"\$PATH\" BASH_ENV='$bash_env' bash '$SHARED_HOOK' < '$input'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  count="$(wc -l <"$counter" | tr -d ' ')"
  [ "$count" -eq 1 ]
}

@test "disabled native-result block-env: non-env path exits without python3" {
  local stub_bin bash_env counter input count
  stub_bin="$(_make_python99_stub_bin)"
  counter="$_tmp/source-count.txt"
  bash_env="$_tmp/bash-env.sh"
  _make_bash_env_counter "$counter" "$bash_env"
  input="$_tmp/pre-tool-readme.json"
  jq -n '{
    hook_event_name: "PreToolUse",
    tool_name: "Read",
    tool_input: {file_path: "README.md"}
  }' >"$input"

  run bash -c "PATH='$stub_bin:'\"\$PATH\" BASH_ENV='$bash_env' bash '$BLOCK_ENV_HOOK' < '$input'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  count="$(wc -l <"$counter" | tr -d ' ')"
  [ "$count" -eq 1 ]
}

@test "disabled native-result block-env: .env path still blocked" {
  local input
  input="$_tmp/pre-tool-env.json"
  jq -n '{
    hook_event_name: "PreToolUse",
    tool_name: "Read",
    tool_input: {file_path: "/proj/.env.local"}
  }' >"$input"

  run bash -c "bash '$BLOCK_ENV_HOOK' < '$input'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"BLOCKED"* ]]
  [[ "$output" == *".env.local"* ]]
}
