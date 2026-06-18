#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$RALPH_LIB_ROOT/install/install-ops.sh"

setup() {
  install_ops_reset_state
}

@test "install flag parsing recognizes --antigravity" {
  install_ops_parse_flags --antigravity /tmp/target
  [ "$?" -eq 0 ]
  [ "$INSTALL_ANTIGRAVITY" -eq 1 ]
  [ "$INSTALL_TARGET_ARG" = "/tmp/target" ]
}

@test "install copy plan includes antigravity runtime trees when selected" {
  bundle_dir="$(mktemp -d)"
  target_dir="$(mktemp -d)"
  mkdir -p "$bundle_dir/.agents/agents" "$bundle_dir/.agents/rules" "$bundle_dir/.agents/skills"
  printf '%s\n' "# Agents" >"$bundle_dir/.agents/agents.md"

  BUNDLE="$bundle_dir"
  TARGET="$target_dir"
  INSTALL_ANTIGRAVITY=1

  run install_ops_build_copy_plan
  [ "$status" -eq 0 ]
  [[ "$output" == *"$bundle_dir/.agents/agents.md|$target_dir/.agents/agents.md|antigravity-agents-md"* ]]
  [[ "$output" == *"$bundle_dir/.agents/agents|$target_dir/.agents/agents|antigravity-agents"* ]]
  [[ "$output" == *"$bundle_dir/.agents/rules|$target_dir/.agents/rules|antigravity-rules"* ]]
  [[ "$output" == *"$bundle_dir/.agents/skills|$target_dir/.agents/skills|antigravity-skills"* ]]

  rm -rf "$bundle_dir" "$target_dir"
  BUNDLE=""
  TARGET=""
}

@test "install copy plan omits antigravity trees when not selected" {
  bundle_dir="$(mktemp -d)"
  target_dir="$(mktemp -d)"
  mkdir -p "$bundle_dir/.agents/agents"

  BUNDLE="$bundle_dir"
  TARGET="$target_dir"
  INSTALL_ANTIGRAVITY=0
  INSTALL_CURSOR=1

  run install_ops_build_copy_plan
  [ "$status" -eq 0 ]
  [[ "$output" != *"antigravity-agents"* ]]
  [[ "$output" != *".agents"* ]]

  rm -rf "$bundle_dir" "$target_dir"
  BUNDLE=""
  TARGET=""
}

@test "install.sh --help documents --antigravity" {
  run bash "$REPO_ROOT/install.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--antigravity"* ]]
}

@test "install.sh antigravity dry-run lists antigravity copy actions" {
  target_dir="$(mktemp -d)"
  run env RALPH_USAGE_RISKS_ACKNOWLEDGED=1 \
    bash "$REPO_ROOT/install.sh" -n --silent --no-dashboard --antigravity "$target_dir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"antigravity-agents-md"* || "$output" == *".agents/agents.md"* ]]
  [[ "$output" == *"antigravity-agents"* || "$output" == *".agents/agents"* ]]
  [[ "$output" == *"antigravity-rules"* || "$output" == *".agents/rules"* ]]
  [ ! -d "$target_dir/.agents" ]
  rm -rf "$target_dir"
}

@test "local --antigravity install copies antigravity agents and rules" {
  target_dir="$(mktemp -d)"
  run env RALPH_USAGE_RISKS_ACKNOWLEDGED=1 \
    bash "$REPO_ROOT/install.sh" --silent --no-dashboard --antigravity "$target_dir"
  [ "$status" -eq 0 ]
  [ -f "$target_dir/.agents/agents.md" ]
  [ -f "$target_dir/.agents/agents/research/config.json" ]
  [ -f "$target_dir/.agents/rules/no-emoji.md" ]
  [ ! -f "$target_dir/.claude/hooks/compact-bash-output.sh" ]
  rm -rf "$target_dir"
}
