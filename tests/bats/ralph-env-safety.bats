#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

RALPH_ENV_SAFETY="$REPO_ROOT/bundle/.ralph/ralph-env-safety.sh"

@test "load-lib clears an ambient graph state root" {
  local workspace="$BATS_TEST_TMPDIR/isolated-workspace"

  run env RALPH_GRAPH_STATE_ROOT="/nonexistent" bash -c '
    source "$1/tests/bats/helper/load-lib.bash"
    source "$1/bundle/.ralph/bash-lib/graph/graph-state.sh"
    graph_state_state_root "$2"
  ' _ "$REPO_ROOT" "$workspace"

  [ "$status" -eq 0 ]
  [ "$output" = "$workspace/.ralph-workspace" ]
}

@test "ralph_assert_path_not_env_secret rejects .env* basename" {
  run bash -c 'source "$1"; ralph_assert_path_not_env_secret "Plan file" ".env.secret"' _ "$RALPH_ENV_SAFETY"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Ralph safety: Plan file must not reference a .env"* ]]
  [[ "$output" == *"Reading .env files is not permitted."* ]]
}
