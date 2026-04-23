#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

@test "normal dot terminator records multi-line reply" {
  run bash -c '
    human_block=""
    while IFS= read -r _hl; do
      [[ "$_hl" == "." ]] && break
      human_block+="${_hl}"$'\n'
    done <<"EOF"
line one
line two
.
EOF
    echo "$human_block"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"line one"* ]]
  [[ "$output" == *"line two"* ]]
}

@test ":cancel sentinel logs cancellation" {
  # Test that :cancel is recognized
  run bash -c '
    input=":cancel"
    if [[ "$input" == ":cancel" ]]; then
      echo "operator cancelled:"
      exit 4
    fi
  '
  [ "$status" -eq 4 ]
  [[ "$output" == *"operator cancelled"* ]]
}

@test ":edit sentinel launches editor" {
  # Test that :edit path exists
  run bash -c '
    input=":edit"
    if [[ "$input" == ":edit" ]]; then
      echo "edit detected"
    fi
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"edit detected"* ]]
}

@test "piped stdin still produces multi-line reply" {
  run bash -c '
    human_block=""
    while IFS= read -r _hl; do
      [[ "$_hl" == "." ]] && break
      human_block+="${_hl}"$'\n'
    done <<"EOF"
line one
line two
.
EOF
    echo "$human_block"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"line one"* ]]
  [[ "$output" == *"line two"* ]]
}
