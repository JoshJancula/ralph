#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$RALPH_LIB_ROOT/install/install-ops.sh"

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

@test "flag parsing supports global install flags" {
  install_ops_parse_flags --global --force-global-runtime
  [ "$?" -eq 0 ]
  [ "$GLOBAL_INSTALL" -eq 1 ]
  [ "$FORCE_GLOBAL_RUNTIME" -eq 1 ]
  [ "$INSTALL_TARGET_ARG" = "" ]
}

@test "global install rejects positional target" {
  set +e
  install_ops_parse_flags --global /tmp/project
  [ "$?" -ne 0 ]
  set -e
}

@test "force global runtime requires global install" {
  set +e
  install_ops_parse_flags --force-global-runtime
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
  # .cursor/ralph is deprecated (moved to .ralph/), verify it is NOT in prune roots
  [[ "$dests" != *"$target_dir/.cursor/ralph"* ]]
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

@test "global target resolves to RALPH_HOME and creates it outside dry-run" {
  workspace="$(mktemp -d)"
  RALPH_HOME="$workspace/home/.ralph"
  export RALPH_HOME
  GLOBAL_INSTALL=1
  DRY_RUN=0
  output="$(install_ops_resolve_target "")"
  [ "$?" -eq 0 ]
  [ "$output" = "$RALPH_HOME" ]
  [ -d "$RALPH_HOME" ]
  rm -rf "$workspace"
  unset RALPH_HOME
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
  # .<runtime>/ralph/ directories are deprecated (moved to .ralph/), only create rules/agents
  mkdir -p "$bundle_dir/.cursor/rules"
  mkdir -p "$bundle_dir/.codex/hooks"
  mkdir -p "$bundle_dir/.claude/hooks"
  mkdir -p "$bundle_dir/.opencode/plugins"
  mkdir -p "$pkg_root/docs"

  BUNDLE="$bundle_dir"
  TARGET="$target_dir"
  RALPH_INSTALL_SOURCE_ROOT="$pkg_root"
  export RALPH_INSTALL_SOURCE_ROOT
  INSTALL_SHARED=1
  INSTALL_CURSOR=1
  INSTALL_CODEX=1
  INSTALL_CLAUDE=1
  INSTALL_OPENCODE=1

  run install_ops_build_copy_plan
  [ "$status" -eq 0 ]
  [[ "$output" == *"$bundle_dir/.ralph|$target_dir/.ralph|shared"* ]]
  [[ "$output" == *"$pkg_root/docs|$target_dir/.ralph/docs|ralph-docs"* ]]
  # .cursor/ralph is deprecated (moved to .ralph/), verify it is NOT in the copy plan
  [[ "$output" != *".cursor/ralph"* ]]
  [[ "$output" == *"$bundle_dir/.cursor/rules|$target_dir/.cursor/rules|cursor-rules"* ]]
  # .codex/ralph is deprecated, verify it is NOT in the copy plan
  [[ "$output" != *".codex/ralph"* ]]
  [[ "$output" == *"$bundle_dir/.codex/hooks|$target_dir/.codex/hooks|codex-hooks"* ]]
  # .claude/ralph is deprecated, verify it is NOT in the copy plan
  [[ "$output" != *".claude/ralph"* ]]
  [[ "$output" == *"$bundle_dir/.claude/hooks|$target_dir/.claude/hooks|claude-hooks"* ]]
  # .opencode/ralph is deprecated, verify it is NOT in the copy plan
  [[ "$output" != *".opencode/ralph"* ]]
  [[ "$output" == *"$bundle_dir/.opencode/plugins|$target_dir/.opencode/plugins|opencode-plugins"* ]]

  rm -rf "$bundle_dir" "$target_dir" "$pkg_root"
  BUNDLE=""
  TARGET=""
  unset RALPH_INSTALL_SOURCE_ROOT
}

@test "global copy plan uses install root bundle and user runtime dirs" {
  bundle_dir="$(mktemp -d)"
  target_dir="$(mktemp -d)"
  home_dir="$(mktemp -d)"
  mkdir -p "$bundle_dir/.ralph"
  mkdir -p "$bundle_dir/.cursor/agents" "$bundle_dir/.claude/agents" "$bundle_dir/.codex/agents" "$bundle_dir/.opencode/agents"

  BUNDLE="$bundle_dir"
  TARGET="$target_dir"
  HOME="$home_dir"
  export HOME
  GLOBAL_INSTALL=1
  INSTALL_SHARED=1
  INSTALL_CURSOR=1
  INSTALL_CODEX=1
  INSTALL_CLAUDE=1
  INSTALL_OPENCODE=1

  run install_ops_build_copy_plan
  [ "$status" -eq 0 ]
  [[ "$output" == *"$bundle_dir|$target_dir/bundle|global-bundle"* ]]
  [[ "$output" == *"$bundle_dir/.cursor/agents|$home_dir/.cursor/agents|global-cursor-agents"* ]]
  [[ "$output" == *"$bundle_dir/.claude/agents|$home_dir/.claude/agents|global-claude-agents"* ]]
  [[ "$output" == *"$bundle_dir/.codex/agents|$home_dir/.codex/agents|global-codex-agents"* ]]
  [[ "$output" == *"$bundle_dir/.opencode/agents|$home_dir/.opencode/agents|global-opencode-agents"* ]]
  [[ "$output" != *"$target_dir/.cursor"* ]]
  [[ "$output" != *"$target_dir/.claude"* ]]

  rm -rf "$bundle_dir" "$target_dir" "$home_dir"
  BUNDLE=""
  TARGET=""
}

@test "global copy plan skips existing user runtime unless forced" {
  bundle_dir="$(mktemp -d)"
  target_dir="$(mktemp -d)"
  home_dir="$(mktemp -d)"
  mkdir -p "$bundle_dir/.cursor/agents" "$home_dir/.cursor"

  BUNDLE="$bundle_dir"
  TARGET="$target_dir"
  HOME="$home_dir"
  export HOME
  GLOBAL_INSTALL=1
  INSTALL_CURSOR=1
  FORCE_GLOBAL_RUNTIME=0

  run install_ops_build_copy_plan
  [ "$status" -eq 0 ]
  [[ "$output" != *"global-cursor-agents"* ]]

  FORCE_GLOBAL_RUNTIME=1
  run install_ops_build_copy_plan
  [ "$status" -eq 0 ]
  [[ "$output" == *"$bundle_dir/.cursor/agents|$home_dir/.cursor/agents|global-cursor-agents"* ]]

  rm -rf "$bundle_dir" "$target_dir" "$home_dir"
  BUNDLE=""
  TARGET=""
}

@test "copy tree skips missing source directories" {
  local missing_dir="$BATS_TMPDIR/missing-source"
  local dest_dir="$BATS_TMPDIR/unused-dest"
  run install_ops_copy_tree "$missing_dir" "$dest_dir" 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skip (missing source): $missing_dir"* ]]
  [ ! -d "$dest_dir" ]
}

@test "detect stale runtime ralph directories" {
  target_dir="$(mktemp -d)"

  # Create stale directories with .sh files (these are old Ralph scripts)
  mkdir -p "$target_dir/.cursor/ralph"
  echo '#!/bin/bash' > "$target_dir/.cursor/ralph/select-model.sh"
  mkdir -p "$target_dir/.claude/ralph"
  echo '#!/bin/bash' > "$target_dir/.claude/ralph/new-agent.sh"

  # Create empty ralph directories (no .sh files, should be ignored)
  mkdir -p "$target_dir/.codex/ralph"

  # Create user agents directory (should NOT be detected as stale)
  mkdir -p "$target_dir/.cursor/agents/my-agent"
  echo '{}' > "$target_dir/.cursor/agents/my-agent/config.json"

  run install_ops_detect_stale_runtime_ralph_dirs "$target_dir"
  [ "$status" -eq 0 ]
  [[ "$output" == *".cursor/ralph"* ]]
  [[ "$output" == *".claude/ralph"* ]]
  [[ "$output" != *".codex/ralph"* ]]
  [[ "$output" != *"agents"* ]]

  rm -rf "$target_dir"
}

@test "uninstall does NOT delete user data under .cursor/agents/" {
  target_dir="$(mktemp -d)"
  BUNDLE="$REPO_ROOT/bundle"
  TARGET="$target_dir"
  INSTALL_SHARED=1
  INSTALL_CURSOR=1
  INSTALL_CODEX=0
  INSTALL_CLAUDE=0
  INSTALL_OPENCODE=0
  INSTALL_DASHBOARD=0
  SILENT=1
  DRY_RUN=0

  # Simulate user-created agent config
  mkdir -p "$target_dir/.cursor/agents/my-custom-agent"
  echo '{"name":"custom"}' > "$target_dir/.cursor/agents/my-custom-agent/config.json"
  echo '# Custom agent' > "$target_dir/.cursor/agents/my-custom-agent/custom.md"

  # Simulate bundle-installed agent
  mkdir -p "$target_dir/.cursor/agents/research"
  echo '{}' > "$target_dir/.cursor/agents/research/config.json"

  # Verify files exist before uninstall
  [ -f "$target_dir/.cursor/agents/my-custom-agent/config.json" ]
  [ -f "$target_dir/.cursor/agents/my-custom-agent/custom.md" ]
  [ -f "$target_dir/.cursor/agents/research/config.json" ]

  # Check that custom agent is NOT in the remove list
  custom_agent_in_list="$(install_ops_collect_remove_file_paths 2>/dev/null | grep -c 'my-custom-agent' || true)"
  [ "$custom_agent_in_list" -eq 0 ]

  rm -rf "$target_dir"
  BUNDLE=""
  TARGET=""
}

@test "stale runtime ralph notice prints removal instructions" {
  target_dir="$(mktemp -d)"

  # Create stale .cursor/ralph with a .sh file
  mkdir -p "$target_dir/.cursor/ralph"
  echo '#!/bin/bash' > "$target_dir/.cursor/ralph/select-model.sh"

  # Create user agents (should be safe)
  mkdir -p "$target_dir/.cursor/agents/my-agent"
  echo '{}' > "$target_dir/.cursor/agents/my-agent/config.json"

  # Create a mock install_log_warn function to capture output
  SILENT=0
  DRY_RUN=0

  run install_ops_stale_runtime_ralph_notice "$target_dir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Deprecated directories detected"* ]]
  [[ "$output" == *".cursor/ralph"* ]]
  [[ "$output" == *"rm -rf"* ]]
  [[ "$output" == *"agents/rules/skills"* ]] || [[ "$output" == *"are safe"* ]]

  rm -rf "$target_dir"
}
