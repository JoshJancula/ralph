#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"
source "$RALPH_LIB_ROOT/install-ops.sh"

setup() {
  install_ops_reset_state
}

@test "flag parsing sets stacks and target argument" {
  install_ops_parse_flags --cursor --codex /tmp
  [ "$?" -eq 0 ]
  [ "$INSTALL_CURSOR" -eq 1 ]
  [ "$INSTALL_CODEX" -eq 1 ]
  [ "$INSTALL_TARGET_ARG" = "/tmp" ]
}

@test "flag parsing rejects unknown option" {
  set +e
  install_ops_parse_flags --bogus
  [ "$?" -ne 0 ]
  set -e
}

@test "cleanup flags set remove and stack options" {
  install_ops_parse_flags --cleanup
  [ "$?" -eq 0 ]
  [ "$REMOVE_INSTALLED" -eq 1 ]
  [ "$REMOVE_VENDOR" -eq 1 ]
  [ "$INSTALL_SHARED" -eq 1 ]
  [ "$INSTALL_CURSOR" -eq 1 ]
  [ "$INSTALL_DASHBOARD" -eq 1 ]
}

@test "remove-installed and remove-vendor flags" {
  install_ops_parse_flags --remove-installed --remove-vendor --shared
  [ "$?" -eq 0 ]
  [ "$REMOVE_INSTALLED" -eq 1 ]
  [ "$REMOVE_VENDOR" -eq 1 ]
  [ "$INSTALL_SHARED" -eq 1 ]
  [ "$INSTALL_CURSOR" -eq 0 ]
}

@test "remove dests list matches selected stacks" {
  target_dir="$(mktemp -d)"
  TARGET="$target_dir"
  INSTALL_SHARED=1
  INSTALL_CURSOR=1
  INSTALL_CODEX=0
  INSTALL_CLAUDE=0
  INSTALL_DASHBOARD=1
  dests="$(install_ops_build_remove_dests | sort -u)"
  [[ "$dests" == *"$target_dir/.ralph"* ]]
  [[ "$dests" == *"$target_dir/.cursor/ralph"* ]]
  [[ "$dests" != *"$target_dir/ralph-dashboard"* ]]
  [[ "$dests" != *"$target_dir/.codex"* ]]
  rm -rf "$target_dir"
  TARGET=""
}

@test "remove dests includes dashboard under .ralph when shared is off" {
  target_dir="$(mktemp -d)"
  TARGET="$target_dir"
  INSTALL_SHARED=0
  INSTALL_CURSOR=1
  INSTALL_CODEX=0
  INSTALL_CLAUDE=0
  INSTALL_DASHBOARD=1
  dests="$(install_ops_build_remove_dests | sort -u)"
  [[ "$dests" == *"$target_dir/.ralph/ralph-dashboard"* ]]
  rm -rf "$target_dir"
  TARGET=""
}

@test "resolving target returns absolute path" {
  workspace="$(mktemp -d)"
  output="$(install_ops_resolve_target "$workspace")"
  [ "$?" -eq 0 ]
  [ "$output" = "$workspace" ]
  rm -rf "$workspace"
}

@test "stack helper toggles when selections change" {
  set +e
  install_ops_has_any_stack
  [ "$?" -ne 0 ]
  set -e
  INSTALL_CURSOR=1
  install_ops_has_any_stack
  [ "$?" -eq 0 ]
}

@test "dashboard flag respects selected stacks" {
  INSTALL_DASHBOARD=1
  INSTALL_CURSOR=1
  install_ops_should_install_dashboard
  [ "$?" -eq 0 ]
  INSTALL_DASHBOARD=0
  set +e
  install_ops_should_install_dashboard
  [ "$?" -ne 0 ]
  set -e
}

@test "copy plan lists the selected stacks and optional dirs" {
  bundle_dir="$(mktemp -d)"
  target_dir="$(mktemp -d)"
  pkg_root="$(mktemp -d)"
  mkdir -p "$bundle_dir/.ralph"
  mkdir -p "$bundle_dir/.cursor/ralph" "$bundle_dir/.cursor/rules"
  mkdir -p "$bundle_dir/.codex/ralph"
  mkdir -p "$bundle_dir/.claude/ralph"
  mkdir -p "$pkg_root/docs"

  BUNDLE="$bundle_dir"
  TARGET="$target_dir"
  RALPH_INSTALL_SOURCE_ROOT="$pkg_root"
  export RALPH_INSTALL_SOURCE_ROOT
  INSTALL_SHARED=1
  INSTALL_CURSOR=1
  INSTALL_CODEX=1
  INSTALL_CLAUDE=1

  run install_ops_build_copy_plan
  [ "$status" -eq 0 ]
  [[ "$output" == *"$bundle_dir/.ralph|$target_dir/.ralph|shared"* ]]
  [[ "$output" == *"$pkg_root/docs|$target_dir/.ralph/docs|ralph-docs"* ]]
  [[ "$output" == *"$bundle_dir/.cursor/ralph|$target_dir/.cursor/ralph|cursor-ralph"* ]]
  [[ "$output" == *"$bundle_dir/.cursor/rules|$target_dir/.cursor/rules|cursor-rules"* ]]
  [[ "$output" == *"$bundle_dir/.codex/ralph|$target_dir/.codex/ralph|codex-ralph"* ]]
  [[ "$output" == *"$bundle_dir/.claude/ralph|$target_dir/.claude/ralph|claude-ralph"* ]]

  rm -rf "$bundle_dir" "$target_dir" "$pkg_root"
  BUNDLE=""
  TARGET=""
  unset RALPH_INSTALL_SOURCE_ROOT
}

@test "copy tree skips missing source directories" {
  local missing_dir="$BATS_TMPDIR/missing-source"
  local dest_dir="$BATS_TMPDIR/unused-dest"
  run install_ops_copy_tree "$missing_dir" "$dest_dir" 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skip (missing): $missing_dir"* ]]
  [ ! -d "$dest_dir" ]
}
