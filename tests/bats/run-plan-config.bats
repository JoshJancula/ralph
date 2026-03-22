#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

RUN_PLAN_SH="$REPO_ROOT/bundle/.ralph/run-plan.sh"

@test "run-plan requires --plan" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  run "$RUN_PLAN_SH" --runtime cursor
  [ "$status" -ne 0 ]
  [[ "$output" == *"Error: --plan <path> is required."* ]]
}

@test "run-plan accepts --plan without workspace positional" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  # Without PATH sanitization, a real Cursor CLI plus a TTY can reach interactive menus and hang Bats (SIGINT / status 130).
  run env PATH="/usr/bin:/bin" \
    "$RUN_PLAN_SH" --runtime cursor --no-cli-resume --plan "$REPO_ROOT/PLAN.md"
  [ "$status" -ne 0 ]
  [[ "$output" != *"Error: --plan <path> is required."* ]]
}
