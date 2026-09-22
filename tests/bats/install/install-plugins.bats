#!/usr/bin/env bats
# Installer packaging for generated plugins under $RALPH_HOME/plugins/ralph-orchestrator/.
# Entry-point cases share one fixture; host CLIs are stubbed and must never be called.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$RALPH_LIB_ROOT/install/install-ops.sh"

setup_file() {
  export PL_SHARED="$(mktemp -d "${TMPDIR:-/tmp}/ralph-pl-install.XXXXXX")"
  export PL_HOST_STUBS="$PL_SHARED/host-stubs"
  export PL_HOST_MARKER="$PL_SHARED/host-cli-called"
  mkdir -p "$PL_HOST_STUBS"

  local cli
  for cli in claude codex agy cursor agent opencode; do
    cat >"$PL_HOST_STUBS/$cli" <<EOF
#!/usr/bin/env bash
printf '%s\n' "$cli \$*" >>"$PL_HOST_MARKER"
echo "stub $cli should never be invoked by install packaging" >&2
exit 99
EOF
    chmod +x "$PL_HOST_STUBS/$cli"
  done
}

teardown_file() {
  rm -rf "${PL_SHARED:-}"
}

setup() {
  install_ops_reset_state
  BUNDLE="$REPO_ROOT/bundle"
  TARGET=""
  GLOBAL_INSTALL=0
  INSTALL_SHARED=1
  DRY_RUN=0
  : >"$PL_HOST_MARKER"
  export PATH="$PL_HOST_STUBS:$PATH"
  export RALPH_INSTALL_SOURCE_ROOT="$REPO_ROOT"
  export RALPH_INSTALL_SCRIPT_DIR="$REPO_ROOT"
}

_assert_no_host_install() {
  if [[ -s "$PL_HOST_MARKER" ]]; then
    echo "host CLI invoked during install packaging:" >&2
    cat "$PL_HOST_MARKER" >&2
    return 1
  fi
}

_assert_packaged_runtimes() {
  local dest_root="$1"
  local runtime
  [ -f "$dest_root/VERSION" ]
  for runtime in claude codex cursor opencode antigravity; do
    [ -d "$dest_root/$runtime" ]
    [ -f "$dest_root/$runtime/.ralph-plugin-generated.json" ]
    [ -f "$dest_root/$runtime/host-manifest.json" ]
    cmp -s "$REPO_ROOT/plugins/ralph-orchestrator/$runtime/.ralph-plugin-generated.json" \
      "$dest_root/$runtime/.ralph-plugin-generated.json"
  done
}

@test "package metadata validation accepts generated runtime packages" {
  local runtime
  for runtime in claude codex cursor opencode antigravity; do
    run install_ops_plugin_package_metadata_valid \
      "$REPO_ROOT/plugins/ralph-orchestrator/$runtime"
    [ "$status" -eq 0 ]
  done
}

@test "package metadata validation rejects missing version or source fields" {
  local bad="$PL_SHARED/bad-meta"
  mkdir -p "$bad"
  printf '%s\n' '{"schemaVersion":1}' >"$bad/.ralph-plugin-generated.json"
  run install_ops_plugin_package_metadata_valid "$bad"
  [ "$status" -ne 0 ]
}

@test "local install packages generated plugins under overridden RALPH_HOME" {
  local target ralph_home dest
  target="$(mktemp -d "$PL_SHARED/local.XXXXXX")"
  ralph_home="$(mktemp -d "$PL_SHARED/rhome.XXXXXX")"
  dest="$ralph_home/plugins/ralph-orchestrator"
  mkdir -p "$ralph_home/plugin-installs"
  printf '%s\n' '{"schemaVersion":1,"runtime":"claude","keep":true}' \
    >"$ralph_home/plugin-installs/claude.json"
  local journal_before
  journal_before="$(cksum "$ralph_home/plugin-installs/claude.json")"

  run env PATH="$PL_HOST_STUBS:$PATH" RALPH_HOME="$ralph_home" \
    RALPH_USAGE_RISKS_ACKNOWLEDGED=1 \
    bash "$REPO_ROOT/install.sh" --shared --silent --yes --no-dashboard "$target"
  [ "$status" -eq 0 ]
  _assert_no_host_install
  _assert_packaged_runtimes "$dest"
  [ "$(cksum "$ralph_home/plugin-installs/claude.json")" = "$journal_before" ]
  [ ! -e "$target/.cursor/plugins/local/ralph-orchestrator" ]
}

@test "global install packages plugins under RALPH_HOME and leaves journals alone" {
  local temp_home ralph_home xdg_config xdg_state dest
  temp_home="$(mktemp -d "$PL_SHARED/ghome.XXXXXX")"
  ralph_home="$temp_home/global-ralph"
  xdg_config="$temp_home/config"
  xdg_state="$temp_home/state"
  dest="$ralph_home/plugins/ralph-orchestrator"
  mkdir -p "$ralph_home/plugin-installs"
  printf '%s\n' '{"schemaVersion":1,"runtime":"codex","keep":true}' \
    >"$ralph_home/plugin-installs/codex.json"
  local journal_before
  journal_before="$(cksum "$ralph_home/plugin-installs/codex.json")"

  run env HOME="$temp_home" PATH="$PL_HOST_STUBS:$PATH" RALPH_HOME="$ralph_home" \
    XDG_CONFIG_HOME="$xdg_config" XDG_STATE_HOME="$xdg_state" \
    RALPH_USAGE_RISKS_ACKNOWLEDGED=1 \
    bash "$REPO_ROOT/install.sh" --global --silent --yes --no-dashboard
  [ "$status" -eq 0 ]
  _assert_no_host_install
  _assert_packaged_runtimes "$dest"
  [ "$(cksum "$ralph_home/plugin-installs/codex.json")" = "$journal_before" ]
}

@test "update install overwrites packaged plugin assets byte-exact and keeps journals" {
  local target ralph_home dest journal_before
  target="$(mktemp -d "$PL_SHARED/update.XXXXXX")"
  ralph_home="$(mktemp -d "$PL_SHARED/rhome-u.XXXXXX")"
  dest="$ralph_home/plugins/ralph-orchestrator"
  mkdir -p "$ralph_home/plugin-installs"
  printf '%s\n' '{"schemaVersion":1,"runtime":"claude","keep":true,"owner":"user"}' \
    >"$ralph_home/plugin-installs/claude.json"
  journal_before="$(cksum "$ralph_home/plugin-installs/claude.json")"

  run env PATH="$PL_HOST_STUBS:$PATH" RALPH_HOME="$ralph_home" \
    RALPH_USAGE_RISKS_ACKNOWLEDGED=1 \
    bash "$REPO_ROOT/install.sh" --shared --silent --yes --no-dashboard "$target"
  [ "$status" -eq 0 ]

  printf '%s\n' 'stale-package' >"$dest/claude/host-manifest.json"
  [ "$(cat "$dest/claude/host-manifest.json")" = "stale-package" ]

  run env PATH="$PL_HOST_STUBS:$PATH" RALPH_HOME="$ralph_home" \
    RALPH_USAGE_RISKS_ACKNOWLEDGED=1 \
    bash "$REPO_ROOT/install.sh" --shared --silent --no-dashboard "$target"
  [ "$status" -eq 0 ]
  _assert_no_host_install
  cmp -s "$REPO_ROOT/plugins/ralph-orchestrator/claude/host-manifest.json" \
    "$dest/claude/host-manifest.json"
  # Journals are user-owned host-install records; Ralph package upgrade must
  # not rewrite or claim them.
  [ -f "$ralph_home/plugin-installs/claude.json" ]
  [ "$(cksum "$ralph_home/plugin-installs/claude.json")" = "$journal_before" ]
}

@test "dry-run lists plugin package copies and does not write them" {
  local target ralph_home
  target="$(mktemp -d "$PL_SHARED/dry.XXXXXX")"
  ralph_home="$(mktemp -d "$PL_SHARED/rhome-dry.XXXXXX")"

  run env PATH="$PL_HOST_STUBS:$PATH" RALPH_HOME="$ralph_home" \
    RALPH_USAGE_RISKS_ACKNOWLEDGED=1 \
    bash "$REPO_ROOT/install.sh" --shared -n --silent --no-dashboard "$target"
  [ "$status" -eq 0 ]
  _assert_no_host_install
  [[ "$output" == *"plugins/ralph-orchestrator"* ]]
  [[ "$output" == *"rsync -a --delete"* ]] || [[ "$output" == *"/claude/"* ]]
  [ ! -d "$ralph_home/plugins/ralph-orchestrator" ]
}

@test "uninstall removes packaged plugin assets only and preserves journals" {
  local target ralph_home dest state_root
  target="$(mktemp -d "$PL_SHARED/uninst.XXXXXX")"
  ralph_home="$(mktemp -d "$PL_SHARED/rhome-un.XXXXXX")"
  dest="$ralph_home/plugins/ralph-orchestrator"
  state_root="$target/.ralph-workspace"
  mkdir -p "$ralph_home/plugin-installs" "$state_root/plugin-installs"
  printf '%s\n' '{"schemaVersion":1,"runtime":"cursor","keep":true,"owner":"user"}' \
    >"$ralph_home/plugin-installs/cursor.json"
  printf '%s\n' '{"schemaVersion":1,"runtime":"opencode","scope":"project","owner":"user"}' \
    >"$state_root/plugin-installs/opencode.json"
  local journal_before opencode_before
  journal_before="$(cksum "$ralph_home/plugin-installs/cursor.json")"
  opencode_before="$(cksum "$state_root/plugin-installs/opencode.json")"

  run env PATH="$PL_HOST_STUBS:$PATH" RALPH_HOME="$ralph_home" \
    RALPH_USAGE_RISKS_ACKNOWLEDGED=1 \
    bash "$REPO_ROOT/install.sh" --shared --silent --yes --no-dashboard "$target"
  [ "$status" -eq 0 ]
  [ -d "$dest/claude" ]

  run env PATH="$PL_HOST_STUBS:$PATH" RALPH_HOME="$ralph_home" \
    RALPH_USAGE_RISKS_ACKNOWLEDGED=1 \
    bash "$REPO_ROOT/install.sh" --uninstall --shared --silent --no-dashboard "$target"
  [ "$status" -eq 0 ]
  _assert_no_host_install
  [ ! -e "$dest/claude/.ralph-plugin-generated.json" ]
  [ ! -e "$dest/VERSION" ]
  [ -f "$ralph_home/plugin-installs/cursor.json" ]
  [ "$(cksum "$ralph_home/plugin-installs/cursor.json")" = "$journal_before" ]
  # Project OpenCode journal lives under the state root and must remain
  # user-owned across Ralph package uninstall.
  [ -f "$state_root/plugin-installs/opencode.json" ]
  [ "$(cksum "$state_root/plugin-installs/opencode.json")" = "$opencode_before" ]
}

@test "no host install occurs for local or global packaging paths" {
  local target ralph_home temp_home xdg_config xdg_state
  target="$(mktemp -d "$PL_SHARED/nohost.XXXXXX")"
  ralph_home="$(mktemp -d "$PL_SHARED/rhome-nh.XXXXXX")"

  run env PATH="$PL_HOST_STUBS:$PATH" RALPH_HOME="$ralph_home" \
    RALPH_USAGE_RISKS_ACKNOWLEDGED=1 \
    bash "$REPO_ROOT/install.sh" --shared --silent --yes --no-dashboard "$target"
  [ "$status" -eq 0 ]
  _assert_no_host_install

  temp_home="$(mktemp -d "$PL_SHARED/g-nohost.XXXXXX")"
  ralph_home="$temp_home/global ralph"
  xdg_config="$temp_home/config"
  xdg_state="$temp_home/state"
  : >"$PL_HOST_MARKER"
  run env HOME="$temp_home" PATH="$PL_HOST_STUBS:$PATH" RALPH_HOME="$ralph_home" \
    XDG_CONFIG_HOME="$xdg_config" XDG_STATE_HOME="$xdg_state" \
    RALPH_USAGE_RISKS_ACKNOWLEDGED=1 \
    bash "$REPO_ROOT/install.sh" --global --silent --yes --no-dashboard
  [ "$status" -eq 0 ]
  _assert_no_host_install
  _assert_packaged_runtimes "$ralph_home/plugins/ralph-orchestrator"
}

@test "spaces in overridden Ralph home still package generated plugins" {
  local spaced target ralph_home
  spaced="$PL_SHARED/with spaces"
  mkdir -p "$spaced"
  target="$(mktemp -d "$spaced/target.XXXXXX")"
  ralph_home="$(mktemp -d "$spaced/ralph home.XXXXXX")"

  run env PATH="$PL_HOST_STUBS:$PATH" RALPH_HOME="$ralph_home" \
    RALPH_USAGE_RISKS_ACKNOWLEDGED=1 \
    bash "$REPO_ROOT/install.sh" --shared --silent --yes --no-dashboard "$target"
  [ "$status" -eq 0 ]
  _assert_no_host_install
  _assert_packaged_runtimes "$ralph_home/plugins/ralph-orchestrator"
}
