#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

MENU_SELECT_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/menu-select.sh"

@test "menu-select fails when no choices are provided" {
  [ -f "$MENU_SELECT_LIB" ] || skip "menu-select lib missing"
  run bash -c 'source "$1"; ralph_menu_select --' _ "$MENU_SELECT_LIB"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}
