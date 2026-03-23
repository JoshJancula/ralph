#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

RALPH_ENV_SAFETY="$REPO_ROOT/bundle/.ralph/ralph-env-safety.sh"

@test "ralph_assert_path_not_env_secret rejects .env* basename" {
  run bash -c 'source "$1"; ralph_assert_path_not_env_secret "Plan file" ".env.secret"' _ "$RALPH_ENV_SAFETY"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Ralph safety: Plan file must not reference a .env"* ]]
  [[ "$output" == *"Reading .env files is not permitted."* ]]
}
