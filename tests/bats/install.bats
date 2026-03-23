#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

@test "install.sh prints usage when --help is requested" {
  target_dir="$(mktemp -d)"
  run bash "$REPO_ROOT/install.sh" --help "$target_dir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  rm -rf "$target_dir"
}
