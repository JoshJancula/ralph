#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

@test "install.sh prints usage when --help is requested" {
  target_dir="$(mktemp -d)"
  run bash "$REPO_ROOT/install.sh" --help "$target_dir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  rm -rf "$target_dir"
}

@test "install.sh removes subtree-style vendor after silent install" {
  target_dir="$(mktemp -d)"
  mkdir -p "$target_dir/vendor/ralph/bundle/.ralph"
  cp "$REPO_ROOT/install.sh" "$target_dir/vendor/ralph/"
  cp -R "$REPO_ROOT/bundle" "$target_dir/vendor/ralph/"
  run bash "$target_dir/vendor/ralph/install.sh" --silent "$target_dir"
  [ "$status" -eq 0 ]
  [[ ! -e "$target_dir/vendor/ralph" ]]
  [ -d "$target_dir/.ralph" ]
  rm -rf "$target_dir"
}

@test "install.sh keeps vendor when submodule-style .git file exists" {
  target_dir="$(mktemp -d)"
  mkdir -p "$target_dir/vendor/ralph/bundle/.ralph"
  cp "$REPO_ROOT/install.sh" "$target_dir/vendor/ralph/"
  cp -R "$REPO_ROOT/bundle" "$target_dir/vendor/ralph/"
  printf 'gitdir: ../../.git/modules/vendor/ralph\n' > "$target_dir/vendor/ralph/.git"
  run bash "$target_dir/vendor/ralph/install.sh" --silent "$target_dir"
  [ "$status" -eq 0 ]
  [ -f "$target_dir/vendor/ralph/.git" ]
  [ -d "$target_dir/.ralph" ]
  rm -rf "$target_dir"
}

@test "install.sh cleanup dry-run is vendor-only and keeps project install trees" {
  target_dir="$(mktemp -d)"
  mkdir -p "$target_dir/vendor/ralph/bundle/.ralph"
  cp "$REPO_ROOT/install.sh" "$target_dir/vendor/ralph/"
  cp -R "$REPO_ROOT/bundle" "$target_dir/vendor/ralph/"
  mkdir -p "$target_dir/.ralph"
  run bash "$target_dir/vendor/ralph/install.sh" --cleanup -n "$target_dir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
  [[ "$output" == *"$target_dir/vendor/ralph"* ]]
  [[ "$output" != *"$target_dir/.ralph"* ]]
  [ -d "$target_dir/vendor/ralph" ]
  [ -d "$target_dir/.ralph" ]
  rm -rf "$target_dir"
}
