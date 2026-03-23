#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

@test "orchestration wizard stage inputs can map earlier artifacts" {
  wizard="$REPO_ROOT/bundle/.ralph/orchestration-wizard.sh"
  run bash -n "$wizard"
  [ "$status" -eq 0 ]
  run grep -q 'inputArtifacts' "$wizard"
  [ "$status" -eq 0 ]
}
