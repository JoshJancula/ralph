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

@test "ralph_prompt_text returns input when provided" {
  run bash -c '
    source "$1"
    printf "user_input\n" | ralph_prompt_text "Name" "default_value" 2>/dev/null
  ' _ "$UI_PROMPT_LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "user_input" ]
}

@test "ralph_prompt_text exits 1 when no default and empty after retry" {
  run bash -c '
    source "$1"
    printf "\n\n" | ralph_prompt_text "Name"
  ' _ "$UI_PROMPT_LIB"
  [ "$status" -eq 1 ]
}

@test "ralph_prompt_text succeeds on second attempt with input" {
  run bash -c '
    source "$1"
    printf "\nuser_input\n" | ralph_prompt_text "Name" 2>/dev/null
  ' _ "$UI_PROMPT_LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "user_input" ]
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

@test "ralph_prompt_yesno uses default y on empty input" {
  run bash -c '
    source "$1"
    printf "\n" | ralph_prompt_yesno "Continue?" "y" 2>/dev/null
  ' _ "$UI_PROMPT_LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "y" ]
}

@test "ralph_prompt_yesno uses default n on empty input" {
  run bash -c '
    source "$1"
    printf "\n" | ralph_prompt_yesno "Continue?" "n" 2>/dev/null
  ' _ "$UI_PROMPT_LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "n" ]
}

@test "ralph_prompt_yesno re-prompts on bad input then accepts valid" {
  run bash -c '
    source "$1"
    printf "maybe\ny\n" | ralph_prompt_yesno "Continue?" "n"
  ' _ "$UI_PROMPT_LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"y"* ]]
  [[ "$output" == *"please answer y or n"* ]]
}

@test "ralph_prompt_yesno accepts uppercase Y and N" {
  run bash -c '
    source "$1"
    printf "Y\n" | ralph_prompt_yesno "Continue?" "n" 2>/dev/null
  ' _ "$UI_PROMPT_LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "y" ]
}

@test "ralph_prompt_choice returns default on empty input" {
  run bash -c '
    source "$1"
    printf "\n" | ralph_prompt_choice "Pick" "standard" "full" "standard" "lean" 2>/dev/null
  ' _ "$UI_PROMPT_LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "standard" ]
}

@test "ralph_prompt_choice returns input when valid" {
  run bash -c '
    source "$1"
    printf "lean\n" | ralph_prompt_choice "Pick" "standard" "full" "standard" "lean" 2>/dev/null
  ' _ "$UI_PROMPT_LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "lean" ]
}

@test "ralph_prompt_choice re-prompts on typo then accepts valid" {
  run bash -c '
    source "$1"
    printf "extra\nfull\n" | ralph_prompt_choice "Pick" "standard" "full" "standard" "lean"
  ' _ "$UI_PROMPT_LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"full"* ]]
  [[ "$output" == *"must be one of"* ]]
}

@test "ralph_prompt_list parses numeric indices" {
  run bash -c '
    source "$1"
    printf "1,2\n" | ralph_prompt_list "Stages" "" "research,plan,test" 2>/dev/null
  ' _ "$UI_PROMPT_LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"research,plan"* ]]
}

@test "ralph_prompt_list parses stage names" {
  run bash -c '
    source "$1"
    printf "plan,test\n" | ralph_prompt_list "Stages" "" "research,plan,test" 2>/dev/null
  ' _ "$UI_PROMPT_LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"plan,test"* ]]
}

@test "ralph_prompt_list mixes numeric indices and names" {
  run bash -c '
    source "$1"
    printf "1,test\n" | ralph_prompt_list "Stages" "" "research,plan,test" 2>/dev/null
  ' _ "$UI_PROMPT_LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"research,test"* ]]
}

@test "ralph_prompt_list uses default on empty input" {
  run bash -c '
    source "$1"
    printf "\n" | ralph_prompt_list "Stages" "research,plan" "research,plan,test" 2>/dev/null
  ' _ "$UI_PROMPT_LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"research,plan"* ]]
}

@test "ralph_prompt_list echoes back accepted items in green" {
  run bash -c '
    source "$1"
    printf "1,2\n" | ralph_prompt_list "Stages" "" "research,plan,test"
  ' _ "$UI_PROMPT_LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"accepted:"* ]]
}

@test "ralph_prompt_list echoes back ignored items in yellow on unknown" {
  run bash -c '
    source "$1"
    printf "1,badstage\n" | ralph_prompt_list "Stages" "" "research,plan,test"
  ' _ "$UI_PROMPT_LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ignored:"* ]]
  [[ "$output" == *"badstage (unknown)"* ]]
}

@test "ralph_prompt_list echoes back ignored items for duplicates" {
  run bash -c '
    source "$1"
    printf "1,1,plan\n" | ralph_prompt_list "Stages" "" "research,plan,test"
  ' _ "$UI_PROMPT_LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ignored:"* ]]
  [[ "$output" == *"(duplicate)"* ]]
}

@test "ralph_prompt_list allow_custom accepts custom stage ids" {
  run bash -c '
    source "$1"
    printf "r1,r2,r3\n" | ralph_prompt_list "Stages" "" "research,architecture" "1"
  ' _ "$UI_PROMPT_LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"r1,r2,r3"* ]]
}

@test "ralph_prompt_list allow_custom still rejects unknown when sanitization is empty" {
  run bash -c '
    source "$1"
    printf "___\n\n" | ralph_prompt_list "Stages" "" "research" "1"
  ' _ "$UI_PROMPT_LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"unknown"* ]]
}

@test "ralph_prompt_list re-prompts when ignored items present and input given" {
  run bash -c '
    source "$1"
    printf "1,bad\nretry\n1,2\n" | ralph_prompt_list "Stages" "" "research,plan,test" 2>/dev/null
  ' _ "$UI_PROMPT_LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"research,plan"* ]]
}

@test "ralph_prompt_list keeps accepted items when ignored items and user presses Enter" {
  run bash -c '
    source "$1"
    printf "1,bad\n\n" | ralph_prompt_list "Stages" "" "research,plan,test" 2>/dev/null
  ' _ "$UI_PROMPT_LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"research"* ]]
}

@test "ralph_prompt_text with NO_COLOR disables ANSI output" {
  run bash -c '
    export NO_COLOR=1
    source "$1"
    printf "input\n" | ralph_prompt_text "Name" "default" 2>/dev/null
  ' _ "$UI_PROMPT_LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "input" ]
}

@test "ralph_prompt_list with NO_COLOR has no color codes in output" {
  run bash -c '
    export NO_COLOR=1
    source "$1"
    printf "1\n" | ralph_prompt_list "Stages" "" "research,plan"
  ' _ "$UI_PROMPT_LIB"
  [ "$status" -eq 0 ]
  [[ ! "$output" == *$'\033'* ]]
}

@test "ralph_prompt_text works with piped stdin (no TTY)" {
  run bash -c '
    source "$1"
    printf "piped_input\n" | ralph_prompt_text "Name" "default" 2>/dev/null
  ' _ "$UI_PROMPT_LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "piped_input" ]
}

@test "ralph_prompt_yesno works with piped stdin (no TTY)" {
  run bash -c '
    source "$1"
    printf "yes\n" | ralph_prompt_yesno "Continue?" "n" 2>/dev/null
  ' _ "$UI_PROMPT_LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "y" ]
}

@test "ralph_prompt_choice works with piped stdin (no TTY)" {
  run bash -c '
    source "$1"
    printf "lean\n" | ralph_prompt_choice "Pick" "standard" "full" "standard" "lean" 2>/dev/null
  ' _ "$UI_PROMPT_LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "lean" ]
}

@test "ralph_prompt_list works with piped stdin (no TTY)" {
  run bash -c '
    source "$1"
    printf "1,2\n" | ralph_prompt_list "Stages" "" "research,plan,test" 2>/dev/null
  ' _ "$UI_PROMPT_LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"research,plan"* ]]
}
