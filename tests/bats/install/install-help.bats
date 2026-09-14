#!/usr/bin/env bats
# Installer help: both public entry points share install_print_help; color only on TTY.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

PTY_EXEC="$REPO_ROOT/tests/bats/bin/ralph-pty-exec"

setup_file() {
  IH_HOME="$(mktemp -d "${TMPDIR:-/tmp}/ralph-install-help.XXXXXX")"
  export IH_HOME
  mkdir -p "$IH_HOME/.local/bin"
  # Minimal ralph shim: install --help must reach the same install.sh renderer.
  cat >"$IH_HOME/.local/bin/ralph" <<EOF
#!/usr/bin/env bash
set -euo pipefail
RALPH_HOME="\${RALPH_HOME:-$REPO_ROOT}"
cmd="\${1:-}"
shift || true
case "\$cmd" in
  install) exec bash "\$RALPH_HOME/install.sh" "\$@" ;;
  *) echo "test shim: unsupported: \$cmd" >&2; exit 2 ;;
esac
EOF
  chmod +x "$IH_HOME/.local/bin/ralph"
}

teardown_file() {
  rm -rf "$IH_HOME"
}

assert_install_help_sections_and_options() {
  local text="$1"
  [[ "$text" == *"Usage:"* ]]
  [[ "$text" == *"Local install"* ]]
  [[ "$text" == *"Global install"* ]]
  [[ "$text" == *"Update / removal"* ]]
  [[ "$text" == *"Workflow / plugin follow-up"* ]]
  [[ "$text" == *"Options"* ]]
  [[ "$text" == *"Examples"* ]]
  [[ "$text" == *"--global"* ]]
  [[ "$text" == *"--force-global-runtime"* ]]
  [[ "$text" == *"--shared"* ]]
  [[ "$text" == *"--cursor"* ]]
  [[ "$text" == *"--codex"* ]]
  [[ "$text" == *"--claude"* ]]
  [[ "$text" == *"--opencode"* ]]
  [[ "$text" == *"--antigravity"* ]]
  [[ "$text" == *"--no-dashboard"* ]]
  [[ "$text" == *"--silent"* ]]
  [[ "$text" == *"--yes"* ]]
  [[ "$text" == *"--dry-run"* ]]
  [[ "$text" == *"--help"* ]]
  [[ "$text" == *"--uninstall"* ]]
  [[ "$text" == *"--remove-vendor"* ]]
  [[ "$text" == *"--cleanup"* ]]
  [[ "$text" == *"--purge"* ]]
  [[ "$text" == *"does not install native agents"* ]]
  [[ "$text" == *"six-ID"* ]]
}

@test "install.sh --help and ralph install --help share durable sections and options" {
  run bash "$REPO_ROOT/install.sh" --help
  [ "$status" -eq 0 ]
  assert_install_help_sections_and_options "$output"
  direct="$output"

  run env PATH="$IH_HOME/.local/bin:$PATH" RALPH_HOME="$REPO_ROOT" \
    ralph install --help
  [ "$status" -eq 0 ]
  assert_install_help_sections_and_options "$output"
  [ "$output" = "$direct" ]
}

@test "redirected help is plain and identical under NO_COLOR and RALPH_INSTALL_NO_COLOR" {
  run env -u NO_COLOR -u RALPH_INSTALL_NO_COLOR bash "$REPO_ROOT/install.sh" --help
  [ "$status" -eq 0 ]
  plain="$output"
  [[ "$plain" != *$'\033['* ]]

  run env NO_COLOR=1 bash "$REPO_ROOT/install.sh" --help
  [ "$status" -eq 0 ]
  [ "$output" = "$plain" ]
  [[ "$output" != *$'\033['* ]]

  run env -u NO_COLOR RALPH_INSTALL_NO_COLOR=1 bash "$REPO_ROOT/install.sh" --help
  [ "$status" -eq 0 ]
  [ "$output" = "$plain" ]
  [[ "$output" != *$'\033['* ]]

  run env -u NO_COLOR -u RALPH_INSTALL_NO_COLOR \
    PATH="$IH_HOME/.local/bin:$PATH" RALPH_HOME="$REPO_ROOT" \
    ralph install --help
  [ "$status" -eq 0 ]
  [ "$output" = "$plain" ]
  [[ "$output" != *$'\033['* ]]
}

@test "pseudo-TTY help emits color; NO_COLOR and RALPH_INSTALL_NO_COLOR strip escapes" {
  run env -u NO_COLOR -u RALPH_INSTALL_NO_COLOR \
    "$PTY_EXEC" bash "$REPO_ROOT/install.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\033['* ]]
  assert_install_help_sections_and_options "$output"

  run env NO_COLOR=1 "$PTY_EXEC" bash "$REPO_ROOT/install.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" != *$'\033['* ]]

  run env -u NO_COLOR RALPH_INSTALL_NO_COLOR=1 \
    "$PTY_EXEC" bash "$REPO_ROOT/install.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" != *$'\033['* ]]

  run env -u NO_COLOR -u RALPH_INSTALL_NO_COLOR PATH="$IH_HOME/.local/bin:$PATH" \
    RALPH_HOME="$REPO_ROOT" "$PTY_EXEC" ralph install --help
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\033['* ]]
}
