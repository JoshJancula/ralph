#!/usr/bin/env bats
# shellcheck shell=bash

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
# shellcheck disable=SC1090
source "$BATS_TEST_DIRNAME/run-plan-invoke-test-helper.bash"

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-opencode.sh"
  run_plan_invoke_test_setup_common
}

teardown() {
  run_plan_invoke_test_teardown_common
}

@test "opencode invoke helper dispatches the stubbed CLI" {
  local record="$TEST_TMPDIR/opencode.args"
  run_plan_invoke_test_write_stub "opencode" "$record"

  export PROMPT="opencode-smoke-prompt"
  export RALPH_MODE=native

  run ralph_run_plan_invoke_opencode
  [ "$status" -eq 0 ]
  [ -s "$record" ]

  local captured
  captured="$(cat "$record")"
  [[ "$captured" == *"run"* ]]
  [[ "$captured" == *"--agent"* ]]
  [[ "$captured" == *"build"* ]]
  [[ "$captured" == *"opencode-smoke-prompt"* ]]
}

@test "opencode refuses subagents on before native argv" {
  local record="$TEST_TMPDIR/opencode-subagents.args"
  run_plan_invoke_test_write_stub "opencode" "$record"
  export RALPH_PLAN_SUBAGENTS=on
  run ralph_run_plan_invoke_opencode
  [ "$status" -ne 0 ]
  [[ "$output" == *"nativeSubagents=on was removed"* ]]
  [ ! -e "$record" ]
}

@test "opencode refuses nativeSubagents off before native argv" {
  local record="$TEST_TMPDIR/opencode-subagents-off.args"
  : >"$record"
  run_plan_invoke_test_write_stub "opencode" "$record"
  export RALPH_PLAN_NATIVE_SUBAGENTS=off
  export PROMPT="opencode-subagents-off"
  export RALPH_MODE=native
  run ralph_run_plan_invoke_opencode
  [ "$status" -ne 0 ]
  [[ "$output" == *"nativeSubagents=off"* ]]
  [[ "$output" == *"unsupported for runtime opencode"* ]]
  ! grep -Fxq -- "run" "$record"
}

@test "opencode restores project-local package metadata mutated by the CLI" {
  local record="$TEST_TMPDIR/opencode-package.args"
  mkdir -p "$WORKSPACE/.opencode"
  printf '%s' '{"dependencies":{"@opencode-ai/plugin":"original"}}' >"$WORKSPACE/.opencode/package.json"
  printf '%s' '{"lock":"original"}' >"$WORKSPACE/.opencode/package-lock.json"
  printf '%s' 'original-bun-lock' >"$WORKSPACE/.opencode/bun.lock"

  cat >"$BIN_DIR/opencode" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
printf '%s' '{"dependencies":{"@opencode-ai/plugin":"updated"}}' >"$WORKSPACE/.opencode/package.json"
printf '%s' '{"lock":"updated"}' >"$WORKSPACE/.opencode/package-lock.json"
printf '%s' 'updated-bun-lock' >"$WORKSPACE/.opencode/bun.lock"
exit 0
EOF
  chmod +x "$BIN_DIR/opencode"
  export OPENCODE_PLAN_CLI="$BIN_DIR/opencode"
  export PROMPT="opencode-package-restore"
  export RALPH_MODE=native
  export RALPH_NATIVE_HOOKS=off

  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-overlay/runtime-overlay.sh"
  export RALPH_PLAN_KEY="opencode-package-restore"
  export RALPH_PLAN_WORKSPACE_ROOT="$WORKSPACE/.ralph-workspace"
  runtime_overlay_init_state opencode "$RALPH_PLAN_KEY"

  run ralph_run_plan_invoke_opencode
  [ "$status" -eq 0 ]
  [ "$(cat "$WORKSPACE/.opencode/package.json")" = '{"dependencies":{"@opencode-ai/plugin":"original"}}' ]
  [ "$(cat "$WORKSPACE/.opencode/package-lock.json")" = '{"lock":"original"}' ]
  [ "$(cat "$WORKSPACE/.opencode/bun.lock")" = 'original-bun-lock' ]
}

@test "opencode transiently allows the supervisor-owned external plan directory" {
  local record="$TEST_TMPDIR/opencode-control.args"
  local captured_config="$TEST_TMPDIR/opencode-control.config.json"
  local control_dir="$TEST_TMPDIR/state/graph-runs/ns/run/orchestration-plans/node/plans"
  mkdir -p "$control_dir"
  export PLAN_PATH="$control_dir/lane.plan.md"
  printf '%s\n' plan >"$PLAN_PATH"
  export WORKSPACE="$TEST_TMPDIR/workspace"
  export RALPH_AGENT_WORKSPACE="$WORKSPACE"
  export RALPH_PROJECT_ROOT="$WORKSPACE"
  export PROMPT="opencode-control-plan"
  export RALPH_MODE=native
  export RALPH_NATIVE_HOOKS=off

  cat >"$BIN_DIR/opencode" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
cp "\${OPENCODE_CONFIG:?}" "$captured_config"
exit 0
EOF
  chmod +x "$BIN_DIR/opencode"
  export OPENCODE_PLAN_CLI="$BIN_DIR/opencode"

  run ralph_run_plan_invoke_opencode
  [ "$status" -eq 0 ]
  jq -e --arg pattern "$control_dir/**" '.permission.external_directory[$pattern] == "allow"' "$captured_config" >/dev/null
}

@test "opencode invoke ignores portable-profile model context config" {
  local record="$TEST_TMPDIR/opencode-no-profile.args"
  run_plan_invoke_test_write_stub "opencode" "$record"

  # Legacy portable-profile fields must not become OpenCode argv/config.
  # Native primary remains `--agent build`. Model comes only from SELECTED_MODEL
  # (prior TODOs); unset => native default.
  export PREBUILT_AGENT=implementation
  export PREBUILT_AGENT_CONTEXT=$'## profile context\nmust-not-appear-in-argv'
  export RALPH_AGENT_MAX_BUDGET=7.25
  export RALPH_AGENT_NATIVE_NAME=implementation
  export RALPH_AGENT_NATIVE_PASSTHROUGH=1
  export PROMPT="opencode-primary-default-turn"
  export RALPH_MODE=native

  run ralph_run_plan_invoke_opencode
  [ "$status" -eq 0 ]
  [ -s "$record" ]

  grep -Fxq -- "run" "$record"
  grep -Fxq -- "--agent" "$record"
  grep -Fxq -- "build" "$record"
  ! grep -Fxq -- "--model" "$record"
  ! grep -Fxq -- "--max-budget-usd" "$record"
  ! grep -Fxq -- "implementation" "$record"
  ! grep -Fq -- "must-not-appear-in-argv" "$record"
  grep -Fxq -- "opencode-primary-default-turn" "$record"
}

@test "opencode invoke honors SELECTED_MODEL without profile reads" {
  local record="$TEST_TMPDIR/opencode-selected-model.args"
  run_plan_invoke_test_write_stub "opencode" "$record"

  export PREBUILT_AGENT=implementation
  export SELECTED_MODEL="opencode-resolved-model"
  export PROMPT="opencode-model-turn"
  export RALPH_MODE=native

  run ralph_run_plan_invoke_opencode
  [ "$status" -eq 0 ]
  grep -Fxq -- "--model" "$record"
  grep -Fxq -- "opencode-resolved-model" "$record"
  grep -Fxq -- "--agent" "$record"
  grep -Fxq -- "build" "$record"
  ! grep -Fxq -- "implementation" "$record"
}
