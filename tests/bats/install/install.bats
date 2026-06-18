#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

@test "install.sh prints usage when --help is requested" {
  target_dir="$(mktemp -d)"
  run bash "$REPO_ROOT/install.sh" --help "$target_dir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"--global"* ]]
  rm -rf "$target_dir"
}

@test "install.sh rejects global install with target dir" {
  target_dir="$(mktemp -d)"
  run bash "$REPO_ROOT/install.sh" --global "$target_dir"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--global cannot be combined with TARGET_DIR"* ]]
  rm -rf "$target_dir"
}

@test "install.sh global dry-run lists global destinations" {
  temp_home="$(mktemp -d)"
  ralph_home="$temp_home/global-ralph"
  xdg_config="$temp_home/config"
  xdg_state="$temp_home/state"

  run env HOME="$temp_home" RALPH_HOME="$ralph_home" XDG_CONFIG_HOME="$xdg_config" XDG_STATE_HOME="$xdg_state" \
    bash "$REPO_ROOT/install.sh" --global -n --silent

  [ "$status" -eq 0 ]
  [[ "$output" == *"$ralph_home"* ]]
  [[ "$output" == *"$ralph_home/bundle"* ]]
  [[ "$output" == *"$ralph_home/ralph-dashboard"* ]]
  [[ "$output" == *"$xdg_config/ralph"* ]]
  [[ "$output" == *"$xdg_state/ralph"* ]]
  [[ "$output" == *"$temp_home/.local/bin"* ]]
  [[ "$output" == *"$temp_home/.local/bin/ralph"* ]]
  [[ "$output" == *"$temp_home/.cursor"* ]]
  [[ "$output" == *"$temp_home/.claude"* ]]
  [[ "$output" == *"$temp_home/.codex"* ]]
  [[ "$output" == *"$temp_home/.opencode"* ]]
  [[ "$output" != *"$PWD/.cursor"* ]]
  [ ! -e "$ralph_home" ]

  rm -rf "$temp_home"
}

@test "install.sh global install writes idempotent shim that dispatches" {
  temp_home="$(mktemp -d)"
  ralph_home="$temp_home/global-ralph"
  xdg_config="$temp_home/config"
  xdg_state="$temp_home/state"
  shim="$temp_home/.local/bin/ralph"

  run env HOME="$temp_home" RALPH_HOME="$ralph_home" XDG_CONFIG_HOME="$xdg_config" XDG_STATE_HOME="$xdg_state" \
    bash "$REPO_ROOT/install.sh" --global --silent --no-dashboard

  [ "$status" -eq 0 ]
  [ -x "$shim" ]
  [[ "$output" == *"~/.local/bin is not on PATH"* ]]
  [ -f "$xdg_config/ralph/path-hint-shown" ]

  cp "$shim" "$temp_home/first-shim"

  run env HOME="$temp_home" RALPH_HOME="$ralph_home" "$shim" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: ralph <command>"* ]]

  run env HOME="$temp_home" RALPH_HOME="$ralph_home" "$shim" run-plan --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: .ralph/run-plan.sh"* ]]

  run env HOME="$temp_home" RALPH_HOME="$ralph_home" "$shim" models --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"models.sh"* ]]

  run env HOME="$temp_home" RALPH_HOME="$ralph_home" "$shim" install --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--global"* ]]

  run env HOME="$temp_home" RALPH_HOME="$ralph_home" XDG_CONFIG_HOME="$xdg_config" "$shim" workspaces list
  [ "$status" -eq 0 ]
  [[ "$output" == *"No workspaces registered."* ]]

  run env HOME="$temp_home" RALPH_HOME="$ralph_home" XDG_CONFIG_HOME="$xdg_config" XDG_STATE_HOME="$xdg_state" \
    bash "$REPO_ROOT/install.sh" --global --silent --no-dashboard

  [ "$status" -eq 0 ]
  cmp "$temp_home/first-shim" "$shim"
  [[ "$output" != *"~/.local/bin is not on PATH"* ]]

  rm -rf "$temp_home"
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
