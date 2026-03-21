#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

RUN_PLAN_SH="$REPO_ROOT/bundle/.ralph/run-plan.sh"

@test "unified runner entrypoint exists (bundle)" {
  [ -f "$RUN_PLAN_SH" ]
}

@test "missing runtime without TTY fails fast with guidance" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  # Bats inherits a TTY when run from an interactive terminal; force non-TTY stdin
  # so we exercise the fast-fail branch instead of blocking on the runtime menu.
  unset RALPH_PLAN_RUNTIME
  run "$RUN_PLAN_SH" --plan "$REPO_ROOT/PLAN.md" </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"Error: runtime must be provided via --runtime or RALPH_PLAN_RUNTIME when stdin is not a terminal."* ]]
}

@test "missing runtime with non-interactive still requires explicit runtime" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  run "$RUN_PLAN_SH" --non-interactive --plan "$REPO_ROOT/PLAN.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Error: runtime must be provided via --runtime or RALPH_PLAN_RUNTIME (cursor, claude, or codex)."* ]]
}

@test "invalid runtime value fails fast with guidance" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  run "$RUN_PLAN_SH" --runtime invalid --plan "$REPO_ROOT/PLAN.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Error: --runtime must be one of cursor, claude, or codex."* ]]
}

@test "non-interactive gate includes --model (PLAN_MODEL_CLI)" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  grep -Fq 'PLAN_MODEL_CLI' "$RUN_PLAN_SH"
  run grep -F 'Non-interactive mode requires a prebuilt agent' "$RUN_PLAN_SH"
  [[ "$output" == *"--model <id>"* ]]
}

@test "--model requires a value" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  run /usr/bin/env bash "$RUN_PLAN_SH" --runtime cursor --plan "$REPO_ROOT/PLAN.md" --model
  [ "$status" -ne 0 ]
  [[ "$output" == *"Error: --model requires a model id string."* ]]
}

@test "bundle run-plan.sh is valid bash" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  run bash -n "$RUN_PLAN_SH"
  [ "$status" -eq 0 ]
}

@test "run-plan sources menu-select helper for prebuilt agent TTY menu" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  grep -Fq 'bash-lib/menu-select.sh' "$RUN_PLAN_SH"
}

@test "menu-select library defines ralph_menu_select" {
  local lib="$REPO_ROOT/bundle/.ralph/bash-lib/menu-select.sh"
  [ -f "$lib" ] || skip "menu-select lib missing"
  run bash -c 'source "$1"; type -t ralph_menu_select' _ "$lib"
  [ "$status" -eq 0 ]
  [[ "$output" == function ]]
}
