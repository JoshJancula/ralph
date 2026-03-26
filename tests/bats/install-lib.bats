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

@test "cleanup flag is vendor removal only" {
  install_ops_parse_flags --cleanup
  [ "$?" -eq 0 ]
  [ "$REMOVE_INSTALLED" -eq 0 ]
  [ "$REMOVE_VENDOR" -eq 1 ]
  [ "$INSTALL_SHARED" -eq 0 ]
}

@test "purge sets full uninstall plus vendor removal and stacks" {
  install_ops_parse_flags --purge
  [ "$?" -eq 0 ]
  [ "$REMOVE_INSTALLED" -eq 1 ]
  [ "$REMOVE_VENDOR" -eq 1 ]
  [ "$INSTALL_SHARED" -eq 1 ]
  [ "$INSTALL_CURSOR" -eq 1 ]
  [ "$INSTALL_DASHBOARD" -eq 1 ]
}

@test "uninstall is alias for remove-installed" {
  install_ops_parse_flags --uninstall --shared
  [ "$?" -eq 0 ]
  [ "$REMOVE_INSTALLED" -eq 1 ]
  [ "$INSTALL_SHARED" -eq 1 ]
  [ "$REMOVE_VENDOR" -eq 0 ]
}

@test "prune_empty_vendor_ancestors removes empty parent directories" {
  t="$(mktemp -d)"
  mkdir -p "$t/vendor/ralph"
  printf 'x\n' > "$t/vendor/ralph/keep.txt"
  rm -f "$t/vendor/ralph/keep.txt"
  ( cd "$t" && rm -rf vendor/ralph )
  install_ops_prune_empty_vendor_ancestors "$t" "vendor/ralph"
  [[ ! -d "$t/vendor" ]]
  rm -rf "$t"
}

@test "prune_empty_vendor_ancestors keeps parent when non-empty" {
  t="$(mktemp -d)"
  mkdir -p "$t/vendor/ralph"
  printf 'other\n' > "$t/vendor/other.txt"
  ( cd "$t" && rm -rf vendor/ralph )
  install_ops_prune_empty_vendor_ancestors "$t" "vendor/ralph"
  [[ -d "$t/vendor" ]]
  [[ -f "$t/vendor/other.txt" ]]
  rm -rf "$t"
}

@test "resolve_vendor_rel prints path when script dir is under target" {
  t="$(mktemp -d)"
  mkdir -p "$t/vendor/ralph"
  rel="$(install_ops_resolve_vendor_rel "$t" "$t/vendor/ralph")"
  [ "$rel" = "vendor/ralph" ]
  rm -rf "$t"
}

@test "auto_remove_vendor skips when vendored tree has .git" {
  t="$(mktemp -d)"
  mkdir -p "$t/vendor/ralph"
  printf 'gitdir: ../../.git/modules/vendor/ralph\n' > "$t/vendor/ralph/.git"
  DRY_RUN=0 install_ops_auto_remove_vendor_after_install "$t" "$t/vendor/ralph"
  [ -d "$t/vendor/ralph" ]
  rm -rf "$t"
}

@test "auto_remove_vendor forces removal with RALPH_INSTALL_REMOVE_VENDOR despite .git" {
  t="$(mktemp -d)"
  mkdir -p "$t/vendor/ralph"
  printf 'gitdir: ../../.git/modules/vendor/ralph\n' > "$t/vendor/ralph/.git"
  RALPH_INSTALL_REMOVE_VENDOR=1 install_ops_auto_remove_vendor_after_install "$t" "$t/vendor/ralph"
  [[ ! -d "$t/vendor/ralph" ]]
  rm -rf "$t"
}

@test "remove-installed and remove-vendor flags" {
  install_ops_parse_flags --remove-installed --remove-vendor --shared
  [ "$?" -eq 0 ]
  [ "$REMOVE_INSTALLED" -eq 1 ]
  [ "$REMOVE_VENDOR" -eq 1 ]
  [ "$INSTALL_SHARED" -eq 1 ]
  [ "$INSTALL_CURSOR" -eq 0 ]
}

@test "remove prune roots list matches selected stacks" {
  target_dir="$(mktemp -d)"
  BUNDLE="$REPO_ROOT/bundle"
  TARGET="$target_dir"
  INSTALL_SHARED=1
  INSTALL_CURSOR=1
  INSTALL_CODEX=0
  INSTALL_CLAUDE=0
  INSTALL_DASHBOARD=1
  RALPH_INSTALL_SOURCE_ROOT="$REPO_ROOT"
  export RALPH_INSTALL_SOURCE_ROOT
  dests="$(install_ops_build_remove_prune_roots | sort -u)"
  [[ "$dests" == *"$target_dir/.ralph"* ]]
  [[ "$dests" == *"$target_dir/.cursor/ralph"* ]]
  [[ "$dests" != *"$target_dir/ralph-dashboard"* ]]
  [[ "$dests" != *"$target_dir/.codex"* ]]
  rm -rf "$target_dir"
  TARGET=""
  BUNDLE=""
  unset RALPH_INSTALL_SOURCE_ROOT
}

@test "remove prune roots includes dashboard under .ralph when shared is off" {
  target_dir="$(mktemp -d)"
  BUNDLE="$REPO_ROOT/bundle"
  TARGET="$target_dir"
  INSTALL_SHARED=0
  INSTALL_CURSOR=1
  INSTALL_CODEX=0
  INSTALL_CLAUDE=0
  INSTALL_DASHBOARD=1
  RALPH_INSTALL_SOURCE_ROOT="$REPO_ROOT"
  export RALPH_INSTALL_SOURCE_ROOT
  dests="$(install_ops_build_remove_prune_roots | sort -u)"
  [[ "$dests" == *"$target_dir/.ralph/ralph-dashboard"* ]]
  rm -rf "$target_dir"
  TARGET=""
  BUNDLE=""
  unset RALPH_INSTALL_SOURCE_ROOT
}

@test "remove-installed deletes only bundle files under merged dirs" {
  bundle_dir="$(mktemp -d)"
  target_dir="$(mktemp -d)"
  mkdir -p "$bundle_dir/.cursor/rules"
  printf 'ralph\n' > "$bundle_dir/.cursor/rules/ralph-only.mdc"
  mkdir -p "$target_dir/.cursor/rules"
  printf 'ralph\n' > "$target_dir/.cursor/rules/ralph-only.mdc"
  printf 'mine\n' > "$target_dir/.cursor/rules/mine.mdc"

  BUNDLE="$bundle_dir"
  TARGET="$target_dir"
  INSTALL_SHARED=0
  INSTALL_CURSOR=1
  INSTALL_CODEX=0
  INSTALL_CLAUDE=0
  INSTALL_DASHBOARD=0
  SILENT=1
  DRY_RUN=0
  install_ops_execute_remove

  [[ ! -f "$target_dir/.cursor/rules/ralph-only.mdc" ]]
  [[ -f "$target_dir/.cursor/rules/mine.mdc" ]]

  rm -rf "$bundle_dir" "$target_dir"
  BUNDLE=""
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
  [[ "$output" == *"Skip (missing source): $missing_dir"* ]]
  [ ! -d "$dest_dir" ]
}
