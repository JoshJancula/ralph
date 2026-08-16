#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

@test "run-bats expands a directory target and executes every contained test" {
  local suite_dir
  suite_dir="$(mktemp -d)"
  mkdir -p "$suite_dir/nested"

  printf '%s\n' '#!/usr/bin/env bats' '@test "first" { true; }' >"$suite_dir/first.bats"
  printf '%s\n' '#!/usr/bin/env bats' '@test "second" { true; }' >"$suite_dir/nested/second.bats"

  run bash "$REPO_ROOT/scripts/run-bats.sh" --no-setup-fixtures -j 2 "$suite_dir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1..2"* ]]
  [[ "$output" != *"1..0"* ]]
}
