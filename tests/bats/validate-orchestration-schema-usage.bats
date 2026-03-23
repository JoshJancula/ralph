#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

setup() {
  VALIDATOR="$REPO_ROOT/scripts/validate-orchestration-schema.sh"
}

@test "validator prints usage when missing args" {
  run "$VALIDATOR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage: validate-orchestration-schema.sh <orchestration-file>"* ]]
}
