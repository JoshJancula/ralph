#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

INTERACTIVE_SELECT_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/interactive-select.sh"

@test "numeric prompt repeats on out-of-range selection" {
  run bash -c '
    source "$1"
    _ralph_menu_read_tty() {
      local var_name="$1"
      read -r "$var_name"
    }
    printf "0\n2\n" | _ralph_menu_numeric_prompt "Pick a value" 1 "apple" "banana"
  ' _ "$INTERACTIVE_SELECT_LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *banana* ]]
  [[ "$output" == *Invalid\ selection.* ]]
}
