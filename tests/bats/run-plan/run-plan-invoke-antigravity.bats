#!/usr/bin/env bats
# shellcheck shell=bash

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-antigravity.sh"

  TEST_TMPDIR="$(mktemp -d)"
  BIN_DIR="$TEST_TMPDIR/bin"
  mkdir -p "$BIN_DIR"
  export TMPDIR="$TEST_TMPDIR"
  export WORKSPACE="$TEST_TMPDIR/workspace"
  mkdir -p "$WORKSPACE/.ralph"

  ORIGINAL_PATH="$PATH"
  PATH="$BIN_DIR:$PATH"

  export OUTPUT_LOG="$TEST_TMPDIR/output.log"
  export EXIT_CODE_FILE="$TEST_TMPDIR/exit-code"
  export SESSION_ID_FILE="$TEST_TMPDIR/session-id.antigravity.txt"
  export PROMPT="antigravity-test-prompt"

  unset SELECTED_MODEL ANTIGRAVITY_PLAN_CLI ANTIGRAVITY_CLI
  unset RALPH_PLAN_ALLOW_UNSAFE_RESUME RALPH_RUN_PLAN_RESUME_BARE
  unset RALPH_PLAN_SUBAGENTS
  unset RALPH_PLAN_CLI_RESUME RALPH_RUN_PLAN_RESUME_SESSION_ID
  unset RALPH_RUN_PLAN_NEW_SESSION_ID RALPH_RUN_PLAN_RESET_COMMAND_USED
  unset RALPH_MODE RALPH_PLAN_PRETTY RALPH_PLAN_NO_COLOR NO_COLOR
}

teardown() {
  PATH="$ORIGINAL_PATH"
  rm -rf "$TEST_TMPDIR"
}

write_agy_stub() {
  local record="$1"
  cat <<EOF >"$BIN_DIR/agy"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
exit 0
EOF
  chmod +x "$BIN_DIR/agy"
}

@test "antigravity invoke helper dispatches stub agy with --print prompt" {
  local record="$TEST_TMPDIR/agy.args"
  write_agy_stub "$record"

  run ralph_run_plan_invoke_antigravity
  [ "$status" -eq 0 ]
  [ -s "$record" ]
  grep -Fxq -- "--print" "$record"
  grep -Fxq -- "antigravity-test-prompt" "$record"
}

@test "antigravity refuses non-inherit subagents before native argv" {
  local record="$TEST_TMPDIR/agy-subagents.args"
  write_agy_stub "$record"
  export RALPH_PLAN_SUBAGENTS=on
  run ralph_run_plan_invoke_antigravity
  [ "$status" -ne 0 ]
  [[ "$output" == *"nativeSubagents=on was removed"* ]]
  [ ! -e "$record" ]
}

@test "antigravity invoke helper requests live stream-json output" {
  local record="$TEST_TMPDIR/agy-stream.args"
  write_agy_stub "$record"

  run ralph_run_plan_invoke_antigravity
  [ "$status" -eq 0 ]
  grep -Fxq -- "--output-format" "$record"
  grep -Fxq -- "stream-json" "$record"
}

@test "antigravity invoke helper never passes removed flags" {
  local record="$TEST_TMPDIR/agy-noflags.args"
  write_agy_stub "$record"

  run ralph_run_plan_invoke_antigravity
  [ "$status" -eq 0 ]
  # These flags do not exist on agy and must not be emitted.
  ! grep -Fxq -- "--format" "$record"
  ! grep -Fxq -- "--session" "$record"
  ! grep -Fxq -- "--session-id" "$record"
}

@test "antigravity invoke helper auto-approves permissions by default" {
  local record="$TEST_TMPDIR/agy-perms.args"
  write_agy_stub "$record"

  run ralph_run_plan_invoke_antigravity
  [ "$status" -eq 0 ]
  grep -Fxq -- "--dangerously-skip-permissions" "$record"
}

@test "antigravity invoke helper omits skip-permissions when opted out" {
  local record="$TEST_TMPDIR/agy-perms-off.args"
  write_agy_stub "$record"

  ANTIGRAVITY_PLAN_SKIP_PERMISSIONS=0
  export ANTIGRAVITY_PLAN_SKIP_PERMISSIONS

  run ralph_run_plan_invoke_antigravity
  [ "$status" -eq 0 ]
  ! grep -Fxq -- "--dangerously-skip-permissions" "$record"
}

@test "antigravity invoke helper widens print-timeout to Ralph timeout" {
  local record="$TEST_TMPDIR/agy-timeout.args"
  write_agy_stub "$record"

  RALPH_PLAN_INVOCATION_TIMEOUT_SECONDS=1800
  export RALPH_PLAN_INVOCATION_TIMEOUT_SECONDS

  run ralph_run_plan_invoke_antigravity
  [ "$status" -eq 0 ]
  grep -Fxq -- "--print-timeout" "$record"
  grep -Fxq -- "1800s" "$record"
}

@test "antigravity invoke ignores portable-profile model context config" {
  local record="$TEST_TMPDIR/agy-no-profile.args"
  write_agy_stub "$record"

  # Legacy portable-profile fields must not become Antigravity argv/config.
  # Model comes only from SELECTED_MODEL (prior TODOs); unset => native default.
  export PREBUILT_AGENT=implementation
  export PREBUILT_AGENT_CONTEXT=$'## profile context\nmust-not-appear-in-argv'
  export RALPH_AGENT_MAX_BUDGET=7.25
  export RALPH_AGENT_NATIVE_NAME=implementation
  export RALPH_AGENT_NATIVE_PASSTHROUGH=1
  export PROMPT="antigravity-primary-default-turn"
  export RALPH_MODE=native

  run ralph_run_plan_invoke_antigravity
  [ "$status" -eq 0 ]
  [ -s "$record" ]

  ! grep -Fxq -- "--agent" "$record"
  ! grep -Fxq -- "--model" "$record"
  ! grep -Fxq -- "--max-budget-usd" "$record"
  ! grep -Fxq -- "implementation" "$record"
  ! grep -Fq -- "must-not-appear-in-argv" "$record"
  grep -Fxq -- "--print" "$record"
  grep -Fxq -- "antigravity-primary-default-turn" "$record"
}

@test "antigravity invoke honors SELECTED_MODEL without profile reads" {
  local record="$TEST_TMPDIR/agy-selected-model.args"
  write_agy_stub "$record"

  export PREBUILT_AGENT=implementation
  export SELECTED_MODEL="Claude Sonnet 4.6 (thinking)"
  export PROMPT="antigravity-model-turn"
  export RALPH_MODE=native

  run ralph_run_plan_invoke_antigravity
  [ "$status" -eq 0 ]
  grep -Fxq -- "--model" "$record"
  grep -Fxq -- "Claude Sonnet 4.6 (thinking)" "$record"
  ! grep -Fxq -- "--agent" "$record"
  ! grep -Fxq -- "implementation" "$record"
}

@test "antigravity invoke helper passes exact model string unchanged" {
  local record="$TEST_TMPDIR/agy-model.args"
  write_agy_stub "$record"

  SELECTED_MODEL="Claude Sonnet 4.6 (thinking)"
  export SELECTED_MODEL

  run ralph_run_plan_invoke_antigravity
  [ "$status" -eq 0 ]
  grep -Fxq -- "--model" "$record"
  grep -Fxq -- "Claude Sonnet 4.6 (thinking)" "$record"
}

@test "antigravity invoke helper honors ANTIGRAVITY_PLAN_CLI override" {
  local record="$TEST_TMPDIR/agy-cli.args"
  cat <<EOF >"$BIN_DIR/custom-agy"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
exit 0
EOF
  chmod +x "$BIN_DIR/custom-agy"

  ANTIGRAVITY_PLAN_CLI="$BIN_DIR/custom-agy"
  export ANTIGRAVITY_PLAN_CLI

  run ralph_run_plan_invoke_antigravity
  [ "$status" -eq 0 ]
  [ -s "$record" ]
}

@test "antigravity invoke helper passes --conversation when resume session id is set" {
  local record="$TEST_TMPDIR/agy-session.args"
  write_agy_stub "$record"

  RALPH_RUN_PLAN_RESUME_SESSION_ID="agy-session-abc"
  export RALPH_RUN_PLAN_RESUME_SESSION_ID

  run ralph_run_plan_invoke_antigravity
  [ "$status" -eq 0 ]
  grep -Fxq -- "--conversation" "$record"
  grep -Fxq -- "agy-session-abc" "$record"
}

@test "antigravity invoke helper passes --continue for bare resume" {
  local record="$TEST_TMPDIR/agy-continue.args"
  write_agy_stub "$record"

  RALPH_RUN_PLAN_RESUME_BARE=1
  RALPH_PLAN_ALLOW_UNSAFE_RESUME=1
  export RALPH_RUN_PLAN_RESUME_BARE RALPH_PLAN_ALLOW_UNSAFE_RESUME

  run ralph_run_plan_invoke_antigravity
  [ "$status" -eq 0 ]
  grep -Fxq -- "--continue" "$record"
}

@test "antigravity invoke helper captures conversation id from agy store" {
  local record="$TEST_TMPDIR/agy-capture.args"
  write_agy_stub "$record"

  export RALPH_GEMINI_HOME="$TEST_TMPDIR/gemini"
  mkdir -p "$RALPH_GEMINI_HOME/antigravity-cli/cache"
  printf '{"%s": "captured-conversation-id"}\n' "$WORKSPACE" \
    >"$RALPH_GEMINI_HOME/antigravity-cli/cache/last_conversations.json"

  run ralph_run_plan_invoke_antigravity
  [ "$status" -eq 0 ]
  [ -f "$SESSION_ID_FILE" ]
  grep -Fxq -- "captured-conversation-id" "$SESSION_ID_FILE"
}

@test "antigravity invoke helper fails when agy is missing" {
  PATH="/usr/bin:/bin"
  export PATH

  run ralph_run_plan_invoke_antigravity
  [ "$status" -eq 1 ]
  [[ "$output" == *"Antigravity CLI not found"* ]]
}
