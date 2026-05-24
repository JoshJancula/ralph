#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

@test "running --global twice does not duplicate or corrupt files" {
  temp_home="$(mktemp -d)"
  ralph_home="$temp_home/global-ralph"
  xdg_config="$temp_home/config"
  xdg_state="$temp_home/state"
  shim="$temp_home/.local/bin/ralph"

  run env HOME="$temp_home" RALPH_HOME="$ralph_home" XDG_CONFIG_HOME="$xdg_config" XDG_STATE_HOME="$xdg_state" \
    bash "$REPO_ROOT/install.sh" --global --silent --no-dashboard

  [ "$status" -eq 0 ]
  [ -x "$shim" ]
  cp "$shim" "$temp_home/first-shim.txt"

  run env HOME="$temp_home" RALPH_HOME="$ralph_home" XDG_CONFIG_HOME="$xdg_config" XDG_STATE_HOME="$xdg_state" \
    bash "$REPO_ROOT/install.sh" --global --silent --no-dashboard

  [ "$status" -eq 0 ]
  cmp "$temp_home/first-shim.txt" "$shim"
  [ -d "$ralph_home/bundle/.ralph" ]
  [ -f "$xdg_config/ralph/path-hint-shown" ]

  rm -rf "$temp_home"
}

@test "global install copies framework docs to RALPH_HOME/docs" {
  temp_home="$(mktemp -d)"
  ralph_home="$temp_home/global-ralph"
  xdg_config="$temp_home/config"
  xdg_state="$temp_home/state"

  run env HOME="$temp_home" RALPH_HOME="$ralph_home" XDG_CONFIG_HOME="$xdg_config" XDG_STATE_HOME="$xdg_state" \
    bash "$REPO_ROOT/install.sh" --global --silent --no-dashboard

  [ "$status" -eq 0 ]
  [ -d "$ralph_home/docs" ]
  [ -f "$ralph_home/docs/GLOBAL-INSTALL.md" ]

  rm -rf "$temp_home"
}

@test "running --global on a host with existing local install does not modify that project" {
  temp_home="$(mktemp -d)"
  project_dir="$temp_home/my-project"
  global_ralph_home="$temp_home/global-ralph"
  xdg_config="$temp_home/config"

  mkdir -p "$project_dir"
  cd "$project_dir"

  run env HOME="$temp_home" bash "$REPO_ROOT/install.sh" --silent --no-dashboard "$project_dir"
  [ "$status" -eq 0 ]
  [ -d "$project_dir/.ralph" ]
  [ -f "$project_dir/.claude/agents/architect/architect.md" ]

  project_shim_before="$(cat "$project_dir/.ralph/run-plan.sh" 2>/dev/null || echo "")"

  run env HOME="$temp_home" RALPH_HOME="$global_ralph_home" XDG_CONFIG_HOME="$xdg_config" \
    bash "$REPO_ROOT/install.sh" --global --silent --no-dashboard

  [ "$status" -eq 0 ]
  [ -d "$global_ralph_home" ]
  [ -x "$temp_home/.local/bin/ralph" ]

  project_shim_after="$(cat "$project_dir/.ralph/run-plan.sh" 2>/dev/null || echo "")"
  [ "$project_shim_before" = "$project_shim_after" ]
  [ -d "$project_dir/.ralph" ]

  rm -rf "$temp_home"
}

@test "running local install on a host with existing global install leaves global untouched" {
  temp_home="$(mktemp -d)"
  project_dir="$temp_home/my-project"
  global_ralph_home="$temp_home/global-ralph"
  xdg_config="$temp_home/config"

  mkdir -p "$project_dir"

  run env HOME="$temp_home" RALPH_HOME="$global_ralph_home" XDG_CONFIG_HOME="$xdg_config" \
    bash "$REPO_ROOT/install.sh" --global --silent --no-dashboard

  [ "$status" -eq 0 ]
  [ -d "$global_ralph_home/bundle/.ralph" ]
  global_shim_before="$(cat "$temp_home/.local/bin/ralph")"

  run env HOME="$temp_home" bash "$REPO_ROOT/install.sh" --silent --no-dashboard "$project_dir"
  [ "$status" -eq 0 ]
  [ -d "$project_dir/.ralph" ]

  global_shim_after="$(cat "$temp_home/.local/bin/ralph")"
  [ "$global_shim_before" = "$global_shim_after" ]
  [ -d "$global_ralph_home/bundle/.ralph" ]

  rm -rf "$temp_home"
}

@test "dry-run output enumerates every destination path including ~/.local/bin/ralph" {
  temp_home="$(mktemp -d)"
  ralph_home="$temp_home/global-ralph"
  xdg_config="$temp_home/config"
  xdg_state="$temp_home/state"

  run env HOME="$temp_home" RALPH_HOME="$ralph_home" XDG_CONFIG_HOME="$xdg_config" XDG_STATE_HOME="$xdg_state" \
    bash "$REPO_ROOT/install.sh" --global -n --silent

  [ "$status" -eq 0 ]
  [[ "$output" == *"$ralph_home/bundle/.ralph"* ]]
  [[ "$output" == *"$ralph_home/docs"* ]]
  [[ "$output" == *"$ralph_home/bundle/.claude"* ]]
  [[ "$output" == *"$ralph_home/bundle/.cursor"* ]]
  [[ "$output" == *"$ralph_home/bundle/.codex"* ]]
  [[ "$output" == *"$ralph_home/bundle/.opencode"* ]]
  [[ "$output" == *"$ralph_home/ralph-dashboard"* ]]
  [[ "$output" == *"$xdg_config/ralph"* ]]
  [[ "$output" == *"$xdg_state/ralph"* ]]
  [[ "$output" == *"$temp_home/.local/bin"* ]]
  [[ "$output" == *"$temp_home/.local/bin/ralph"* ]]
  [[ "$output" == *"$temp_home/.claude"* ]]
  [[ "$output" == *"$temp_home/.cursor"* ]]
  [[ "$output" == *"$temp_home/.codex"* ]]
  [[ "$output" == *"$temp_home/.opencode"* ]]

  rm -rf "$temp_home"
}
