#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

install_hooks_target() {
  mktemp -d "${BATS_TMPDIR}/ralph-install-hooks.XXXXXX"
}

install_hooks_run_local() {
  local target_dir="$1"
  shift
  run env RALPH_USAGE_RISKS_ACKNOWLEDGED=1 \
    bash "$REPO_ROOT/install.sh" --silent --no-dashboard "$@" "$target_dir"
}

install_hooks_assert_claude_assets() {
  local root="$1"
  [ -f "$root/.claude/hooks/compact-bash-output.sh" ]
  [ -f "$root/.claude/hooks/rewrite-bash-command.sh" ]
  [ -f "$root/.claude/hooks/block-env-reads.sh" ]
  [ -f "$root/.claude/hooks/native-result-compact.sh" ]
}

install_hooks_assert_codex_assets() {
  local root="$1"
  [ -f "$root/.codex/hooks/pre-tool-bash-policy.sh" ]
  [ -f "$root/.codex/hooks/post-tool-bash-telemetry.sh" ]
}

install_hooks_assert_opencode_assets() {
  local root="$1"
  [ -f "$root/.opencode/plugins/ralph-runtime-hooks.mjs" ]
}

install_hooks_assert_shared_hook_libs() {
  local root="$1"
  [ -f "$root/.ralph/bash-lib/command-rewriter.sh" ]
  [ -f "$root/.ralph/bash-lib/compactors.sh" ]
  [ -f "$root/.ralph/bash-lib/hook-telemetry.sh" ]
  [ -f "$root/.ralph/python/shell-command-rewrite.py" ]
  [ -f "$root/.ralph/python/shell-output-compact.py" ]
}

install_hooks_assert_shared_plan_assets() {
  local root="$1"
  [ -f "$root/.ralph/bash-lib/run-plan/run-plan-runtime.sh" ]
  [ -f "$root/.ralph/bash-lib/mcp-proxy/mcp-proxy-tools.sh" ]
  [ -f "$root/.ralph/bash-lib/mcp-proxy/mcp-proxy-result.sh" ]
  [ -f "$root/.ralph/bash-lib/mcp-proxy/mcp-proxy-policy.sh" ]
  [ -f "$root/.ralph/python/tool_call_classification.py" ]
  [ -f "$root/.ralph/mcp-proxy-policy.example.json" ]
}

install_hooks_assert_plan_docs() {
  local docs_root="$1"
  [ -f "$docs_root/TOOLING.md" ]
}

@test "local --claude install copies Claude hooks only" {
  target_dir="$(install_hooks_target)"
  install_hooks_run_local "$target_dir" --claude
  [ "$status" -eq 0 ]
  install_hooks_assert_claude_assets "$target_dir"
  [ ! -f "$target_dir/.codex/hooks/pre-tool-bash-policy.sh" ]
  [ ! -f "$target_dir/.opencode/plugins/ralph-runtime-hooks.mjs" ]
  [ ! -f "$target_dir/.ralph/bash-lib/command-rewriter.sh" ]
  rm -rf "$target_dir"
}

@test "local --codex install copies Codex hooks only" {
  target_dir="$(install_hooks_target)"
  install_hooks_run_local "$target_dir" --codex
  [ "$status" -eq 0 ]
  install_hooks_assert_codex_assets "$target_dir"
  [ ! -f "$target_dir/.claude/hooks/compact-bash-output.sh" ]
  [ ! -f "$target_dir/.opencode/plugins/ralph-runtime-hooks.mjs" ]
  rm -rf "$target_dir"
}

@test "local --opencode install copies OpenCode plugins only" {
  target_dir="$(install_hooks_target)"
  install_hooks_run_local "$target_dir" --opencode
  [ "$status" -eq 0 ]
  install_hooks_assert_opencode_assets "$target_dir"
  [ ! -f "$target_dir/.claude/hooks/compact-bash-output.sh" ]
  [ ! -f "$target_dir/.codex/hooks/pre-tool-bash-policy.sh" ]
  rm -rf "$target_dir"
}

@test "local --cursor install does not copy hook or plugin trees" {
  target_dir="$(install_hooks_target)"
  install_hooks_run_local "$target_dir" --cursor
  [ "$status" -eq 0 ]
  # .cursor/ralph/ is deprecated (moved to .ralph/); verify it is not copied
  [ ! -d "$target_dir/.cursor/ralph" ]
  # Verify other runtime hooks/plugins are not copied
  [ ! -f "$target_dir/.claude/hooks/compact-bash-output.sh" ]
  [ ! -f "$target_dir/.codex/hooks/pre-tool-bash-policy.sh" ]
  [ ! -f "$target_dir/.opencode/plugins/ralph-runtime-hooks.mjs" ]
  rm -rf "$target_dir"
}

@test "local --shared install copies hook support libs without runtime hooks" {
  target_dir="$(install_hooks_target)"
  install_hooks_run_local "$target_dir" --shared
  [ "$status" -eq 0 ]
  install_hooks_assert_shared_hook_libs "$target_dir"
  install_hooks_assert_shared_plan_assets "$target_dir"
  install_hooks_assert_plan_docs "$target_dir/.ralph/docs"
  [ ! -f "$target_dir/.claude/hooks/compact-bash-output.sh" ]
  [ ! -f "$target_dir/.codex/hooks/pre-tool-bash-policy.sh" ]
  [ ! -f "$target_dir/.opencode/plugins/ralph-runtime-hooks.mjs" ]
  rm -rf "$target_dir"
}

@test "local full install copies all runtime hook assets and shared libs" {
  target_dir="$(install_hooks_target)"
  install_hooks_run_local "$target_dir" --all
  [ "$status" -eq 0 ]
  install_hooks_assert_claude_assets "$target_dir"
  install_hooks_assert_codex_assets "$target_dir"
  install_hooks_assert_opencode_assets "$target_dir"
  install_hooks_assert_shared_hook_libs "$target_dir"
  install_hooks_assert_shared_plan_assets "$target_dir"
  install_hooks_assert_plan_docs "$target_dir/.ralph/docs"
  rm -rf "$target_dir"
}

@test "local dry-run lists hook destinations without writing files" {
  target_dir="$(install_hooks_target)"
  run env RALPH_USAGE_RISKS_ACKNOWLEDGED=1 \
    bash "$REPO_ROOT/install.sh" -n --silent --no-dashboard --claude --codex "$target_dir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude-hooks"* ]]
  [[ "$output" == *".claude/hooks"* ]]
  [[ "$output" == *"codex-hooks"* ]]
  [[ "$output" == *".codex/hooks"* ]]
  [ ! -f "$target_dir/.claude/hooks/compact-bash-output.sh" ]
  [ ! -f "$target_dir/.codex/hooks/pre-tool-bash-policy.sh" ]
  rm -rf "$target_dir"
}

@test "global install fixture includes bundle and user-runtime hook assets" {
  temp_home="$(mktemp -d)"
  ralph_home="$temp_home/global-ralph"
  xdg_config="$temp_home/config"
  xdg_state="$temp_home/state"

  run env HOME="$temp_home" RALPH_HOME="$ralph_home" XDG_CONFIG_HOME="$xdg_config" XDG_STATE_HOME="$xdg_state" \
    RALPH_USAGE_RISKS_ACKNOWLEDGED=1 \
    bash "$REPO_ROOT/install.sh" --global --silent --no-dashboard

  [ "$status" -eq 0 ]
  install_hooks_assert_claude_assets "$ralph_home/bundle"
  install_hooks_assert_codex_assets "$ralph_home/bundle"
  install_hooks_assert_opencode_assets "$ralph_home/bundle"
  install_hooks_assert_shared_hook_libs "$ralph_home/bundle"
  install_hooks_assert_shared_plan_assets "$ralph_home/bundle"
  install_hooks_assert_plan_docs "$ralph_home/docs"
  install_hooks_assert_claude_assets "$temp_home"
  install_hooks_assert_codex_assets "$temp_home"
  install_hooks_assert_opencode_assets "$temp_home"

  rm -rf "$temp_home"
}

@test "global dry-run lists bundle hook paths" {
  temp_home="$(mktemp -d)"
  ralph_home="$temp_home/global-ralph"

  run env HOME="$temp_home" RALPH_HOME="$ralph_home" RALPH_USAGE_RISKS_ACKNOWLEDGED=1 \
    bash "$REPO_ROOT/install.sh" --global -n --silent --no-dashboard --claude

  [ "$status" -eq 0 ]
  [[ "$output" == *"$ralph_home/bundle"* ]]
  [[ "$output" == *".claude/hooks"* || "$output" == *"global-claude"* ]]
  [ ! -d "$ralph_home/bundle/.claude/hooks" ]

  rm -rf "$temp_home"
}

@test "global --codex only copies Codex user runtime hooks not Claude home hooks" {
  temp_home="$(mktemp -d)"
  ralph_home="$temp_home/global-ralph"

  run env HOME="$temp_home" RALPH_HOME="$ralph_home" RALPH_USAGE_RISKS_ACKNOWLEDGED=1 \
    bash "$REPO_ROOT/install.sh" --global --silent --no-dashboard --codex

  [ "$status" -eq 0 ]
  install_hooks_assert_codex_assets "$ralph_home/bundle"
  install_hooks_assert_codex_assets "$temp_home"
  [ ! -f "$temp_home/.claude/hooks/compact-bash-output.sh" ]
  install_hooks_assert_claude_assets "$ralph_home/bundle"

  rm -rf "$temp_home"
}
