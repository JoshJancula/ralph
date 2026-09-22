#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

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

# The dashboard command lives in the shim template that install.sh writes, so
# these two exercise the installed shim rather than install.sh's own dispatch.
ralph_test_install_shim() {
  local temp_home="$1"
  env HOME="$temp_home" RALPH_HOME="$temp_home/global-ralph" \
    XDG_CONFIG_HOME="$temp_home/config" XDG_STATE_HOME="$temp_home/state" \
    bash "$REPO_ROOT/install.sh" --global --silent --no-dashboard >/dev/null
}

@test "global ralph shim refuses to install dashboard deps when the lockfile is missing" {
  temp_home="$(mktemp -d)"
  ralph_home="$temp_home/global-ralph"
  ralph_test_install_shim "$temp_home"

  mkdir -p "$ralph_home/ralph-dashboard"
  printf '{"name":"ralph-dashboard","private":true}\n' >"$ralph_home/ralph-dashboard/package.json"

  # No package-lock.json and no node_modules: npm would resolve the whole tree
  # from the registry, which is what turns an unrelated upstream release into a
  # broken install. The guard must stop before any npm invocation.
  run env HOME="$temp_home" RALPH_HOME="$ralph_home" \
    "$temp_home/.local/bin/ralph" dashboard --yes

  [ "$status" -eq 1 ]
  [[ "$output" == *"package-lock.json missing"* ]]
  [[ "$output" == *"not reproducible"* ]]
  [ ! -d "$ralph_home/ralph-dashboard/node_modules" ]

  rm -rf "$temp_home"
}

@test "global ralph shim installs dashboard deps when the lockfile is present" {
  temp_home="$(mktemp -d)"
  ralph_home="$temp_home/global-ralph"
  stub_bin="$temp_home/stub-bin"
  ralph_test_install_shim "$temp_home"

  mkdir -p "$ralph_home/ralph-dashboard" "$stub_bin"
  printf '{"name":"ralph-dashboard","private":true}\n' >"$ralph_home/ralph-dashboard/package.json"
  printf '{"lockfileVersion":3}\n' >"$ralph_home/ralph-dashboard/package-lock.json"

  cat >"$stub_bin/npm" <<'NPM_STUB'
#!/usr/bin/env bash
echo "npm stub: $*"
NPM_STUB
  chmod +x "$stub_bin/npm"

  run env HOME="$temp_home" RALPH_HOME="$ralph_home" PATH="$stub_bin:$PATH" \
    "$temp_home/.local/bin/ralph" dashboard --yes

  # The guard must not fire with a lockfile present: the run proceeds through
  # npm install and only stops later, when the stubbed build emits no CSR bundle.
  [[ "$output" != *"package-lock.json missing"* ]]
  [[ "$output" == *"npm stub: install"* ]]
  [[ "$output" == *"dashboard build output missing"* ]]

  rm -rf "$temp_home"
}
