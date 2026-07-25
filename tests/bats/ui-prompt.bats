#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

UI_PROMPT_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/ui-prompt.sh"

@test "ralph_prompt_text returns default on empty input" {
  run bash -c '
    source "$1"
    printf "\n" | ralph_prompt_text "Name" "default_value" 2>/dev/null
  ' _ "$UI_PROMPT_LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "default_value" ]
}

@test "ralph_prompt_text exits 1 when no default and empty after retry" {
  run bash -c '
    source "$1"
    printf "\n\n" | ralph_prompt_text "Name"
  ' _ "$UI_PROMPT_LIB"
  [ "$status" -eq 1 ]
}

@test "ralph_prompt_yesno returns y on yes input with default y" {
  run bash -c '
    source "$1"
    printf "yes\n" | ralph_prompt_yesno "Continue?" "y" 2>/dev/null
  ' _ "$UI_PROMPT_LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "y" ]
}

@test "ralph_prompt_yesno returns n on no input with default n" {
  run bash -c '
    source "$1"
    printf "no\n" | ralph_prompt_yesno "Continue?" "n" 2>/dev/null
  ' _ "$UI_PROMPT_LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "n" ]
}

@test "ralph_prompt_choice returns input when valid" {
  run bash -c '
    source "$1"
    printf "lean\n" | ralph_prompt_choice "Pick" "standard" "full" "standard" "lean" 2>/dev/null
  ' _ "$UI_PROMPT_LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "lean" ]
}
