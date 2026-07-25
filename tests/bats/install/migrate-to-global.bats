#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

setup() {
  export TMPDIR="$(mktemp -d)"
  export HOME="$TMPDIR/home"
  mkdir -p "$HOME"
  unset RALPH_WORKSPACES_FILE
  unset XDG_CONFIG_HOME
}

teardown() {
  rm -rf "$TMPDIR"
}

create_fixture_project() {
  local project_path="$1"
  mkdir -p "$project_path/.ralph/bash-lib"
  mkdir -p "$project_path/.claude/agents"
  mkdir -p "$project_path/.cursor/agents"
  touch "$project_path/.ralph/run-plan.sh"
  touch "$project_path/.claude/agents/test-agent"
  touch "$project_path/.cursor/agents/test-agent"
  mkdir -p "$project_path/src"
  touch "$project_path/src/main.py"
  printf '%s\n' "$project_path"
}

@test "migration script shows help with -h flag" {
  bash "$REPO_ROOT/bundle/.ralph/migrate-to-global.sh" -h | grep -q "Usage: migrate-to-global.sh"
}

@test "migration script rejects no project paths" {
  run bash "$REPO_ROOT/bundle/.ralph/migrate-to-global.sh"
  [ $status -eq 2 ]
  [[ "$output" =~ "at least one project path is required" ]]
}

@test "migration dry-run shows what would be done" {
  local project="$TMPDIR/test-project"
  create_fixture_project "$project"

  run bash "$REPO_ROOT/bundle/.ralph/migrate-to-global.sh" --dry-run "$project"
  [ $status -eq 0 ]
  [[ "$output" =~ "DRY RUN" ]]
  [[ "$output" =~ "Would register: $project" ]]
  [[ "$output" =~ "Would remove: .ralph/" ]]
  [[ "$output" =~ "Would remove: .claude/" ]]
  [[ "$output" =~ "Would remove: .cursor/" ]]
}

@test "migration dry-run does not modify the project" {
  local project="$TMPDIR/test-project"
  create_fixture_project "$project"

  bash "$REPO_ROOT/bundle/.ralph/migrate-to-global.sh" --dry-run "$project"

  [ -d "$project/.ralph" ]
  [ -d "$project/.claude" ]
  [ -d "$project/.cursor" ]
}

@test "migration handles non-existent project path" {
  local project="/nonexistent/path/project"

  run bash "$REPO_ROOT/bundle/.ralph/migrate-to-global.sh" --dry-run "$project"
  [ $status -eq 0 ]
  [[ "$output" =~ "does not exist" ]]
  [[ "$output" =~ "Failed: 1" ]]
}

@test "migration skips projects without local Ralph files" {
  local project="$TMPDIR/test-project"
  mkdir -p "$project/src"
  touch "$project/src/main.py"

  run bash "$REPO_ROOT/bundle/.ralph/migrate-to-global.sh" --dry-run "$project"
  [ $status -eq 0 ]
  [[ "$output" =~ "no .ralph/ or .<runtime>/ directories" ]]
}

@test "migration dry-run with multiple projects shows all entries" {
  local project1="$TMPDIR/project1"
  local project2="$TMPDIR/project2"
  create_fixture_project "$project1"
  create_fixture_project "$project2"

  run bash "$REPO_ROOT/bundle/.ralph/migrate-to-global.sh" --dry-run "$project1" "$project2"
  [ $status -eq 0 ]
  [[ "$output" =~ "Would register: $project1" ]]
  [[ "$output" =~ "Would register: $project2" ]]
  [[ "$output" =~ "Summary:" ]]
  [[ "$output" =~ "Processed: 2" ]]
  [[ "$output" =~ "Successful: 2" ]]
}

@test "migration summary includes failed count when projects are skipped" {
  local valid_project="$TMPDIR/valid-project"
  local invalid_project="$TMPDIR/invalid-project"
  create_fixture_project "$valid_project"
  mkdir -p "$invalid_project"

  run bash "$REPO_ROOT/bundle/.ralph/migrate-to-global.sh" --dry-run "$valid_project" "$invalid_project"
  [ $status -eq 0 ]
  [[ "$output" =~ "Processed: 2" ]]
  [[ "$output" =~ "Successful: 1" ]]
  [[ "$output" =~ "Failed: 1" ]]
}

@test "migration --yes flag skips prompts and removes directories" {
  local project="$TMPDIR/test-project"
  create_fixture_project "$project"

  # Verify files exist before migration
  [ -d "$project/.ralph" ]
  [ -d "$project/.claude" ]

  bash "$REPO_ROOT/bundle/.ralph/migrate-to-global.sh" --yes "$project" 2>/dev/null || true

  # Verify files are removed
  [ ! -d "$project/.ralph" ]
  [ ! -d "$project/.claude" ]
  [ ! -d "$project/.cursor" ]
}

@test "migration registers project in workspace registry when python3 available" {
  local project="$TMPDIR/test-project"
  create_fixture_project "$project"

  if ! command -v python3 >/dev/null 2>&1; then
    skip "python3 not available"
  fi

  local registry="$HOME/.config/ralph/workspaces.json"
  bash "$REPO_ROOT/bundle/.ralph/migrate-to-global.sh" --yes "$project" 2>/dev/null || true

  [ -f "$registry" ]
  grep -q "$(cd "$project" && pwd)" "$registry"
}
