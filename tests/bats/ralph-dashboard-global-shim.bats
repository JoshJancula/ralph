#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

@test "global ralph shim documents dashboard flags" {
  run grep -F 'Start the Ralph dashboard (global)' "$REPO_ROOT/install.sh"
  [ "$status" -eq 0 ]
  run grep -F -- '--rebuild' "$REPO_ROOT/install.sh"
  [ "$status" -eq 0 ]
  run grep -F -- '--update-deps' "$REPO_ROOT/install.sh"
  [ "$status" -eq 0 ]
}

@test "global ralph shim runs npm ci when --update-deps is set" {
  run grep -F 'Updating dashboard dependencies (npm ci)' "$REPO_ROOT/install.sh"
  [ "$status" -eq 0 ]
  run grep -F 'npm ci' "$REPO_ROOT/install.sh"
  [ "$status" -eq 0 ]
}

@test "global ralph shim cleans dist when rebuilding" {
  run grep -F 'rm -rf dist' "$REPO_ROOT/install.sh"
  [ "$status" -eq 0 ]
}

@test "global ralph shim forwards non-dashboard args to npm start without empty-array nounset" {
  run grep -F 'exec npm start "${npm_forward[@]}"' "$REPO_ROOT/install.sh"
  [ "$status" -eq 0 ]
  run grep -F '${#npm_forward[@]}' "$REPO_ROOT/install.sh"
  [ "$status" -eq 0 ]
}

@test "global ralph shim exports RALPH_DASHBOARD_BROWSER_DIST for installed tree" {
  run grep -F 'export RALPH_DASHBOARD_BROWSER_DIST="$dashboard_dir/dist/ralph-dashboard/browser"' "$REPO_ROOT/install.sh"
  [ "$status" -eq 0 ]
}
