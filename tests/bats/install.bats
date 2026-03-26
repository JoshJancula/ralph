#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

@test "install.sh prints usage when --help is requested" {
  target_dir="$(mktemp -d)"
  run bash "$REPO_ROOT/install.sh" --help "$target_dir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  rm -rf "$target_dir"
}

@test "install.sh cleanup dry-run lists paths without deleting" {
  target_dir="$(mktemp -d)"
  mkdir -p "$target_dir/vendor/ralph/bundle/.ralph"
  cp "$REPO_ROOT/install.sh" "$target_dir/vendor/ralph/"
  cp -R "$REPO_ROOT/bundle" "$target_dir/vendor/ralph/"
  mkdir -p "$target_dir/.ralph"
  run bash "$target_dir/vendor/ralph/install.sh" --cleanup -n "$target_dir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
  [[ "$output" == *"$target_dir/.ralph"* ]]
  [ -d "$target_dir/vendor/ralph" ]
  [ -d "$target_dir/.ralph" ]
  rm -rf "$target_dir"
}
