#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

MENU_SELECT_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/menu-select.sh"

@test "menu-select fails when no choices are provided" {
  [ -f "$MENU_SELECT_LIB" ] || skip "menu-select lib missing"
  run bash -c 'source "$1"; ralph_menu_select --' _ "$MENU_SELECT_LIB"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "menu-select prints numbered choices before prompt" {
  [ -f "$MENU_SELECT_LIB" ] || skip "menu-select lib missing"
  run bash -c 'source "$1"; printf "2\n" | ralph_menu_select --prompt "runtime" -- "cursor" "claude" "codex"' _ "$MENU_SELECT_LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1)"* ]]
  [[ "$output" == *"cursor"* ]]
  [[ "$output" == *"2)"* ]]
  [[ "$output" == *"claude"* ]]
  [[ "$output" == *"runtime"* ]]
}
