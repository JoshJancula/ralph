#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../../helper/load-lib.bash"

BOOTSTRAP="$REPO_ROOT/bundle/.ralph/plugin-inputs/shared/ralph-plugin-bootstrap.sh"
EXEC_STUB_DIR=""

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  FAKE_HOME="$TEST_TMPDIR/home"
  FAKE_BIN="$TEST_TMPDIR/bin"
  FAKE_BUNDLE="$TEST_TMPDIR/bundle/.ralph"
  INSTALL_SH="$TEST_TMPDIR/install.sh"
  INSTALL_RECORD="$TEST_TMPDIR/install-invocations.log"
  RALPH_RECORD="$TEST_TMPDIR/ralph-invocations.log"
  EXEC_RECORD="$TEST_TMPDIR/exec-invocations.log"
  MARKER="$TEST_TMPDIR/install-ran"
  RALPH_HOME_DIR="$FAKE_HOME/.ralph"
  mkdir -p "$FAKE_HOME" "$FAKE_BIN" "$FAKE_BUNDLE"
  write_fake_install_sh
  write_exec_stub
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

write_exec_stub() {
  EXEC_STUB_DIR="$TEST_TMPDIR/exec-bin"
  mkdir -p "$EXEC_STUB_DIR"
  cat >"$EXEC_STUB_DIR/ralph-plugin-exec.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$EXEC_RECORD"
printf '%s\n' "ralph-plugin-exec must not run during install consent" >&2
exit 99
EOF
  chmod +x "$EXEC_STUB_DIR/ralph-plugin-exec.sh"
}

write_fake_install_sh() {
  cat >"$INSTALL_SH" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$INSTALL_RECORD"
touch "$MARKER"
mkdir -p "\${RALPH_HOME:-\$HOME/.ralph}" "\$HOME/.local/bin"
# Post-install ralph shim for re-probe. Never invoke a plan.
cat >"$FAKE_BIN/ralph" <<'RALPH'
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$RALPH_RECORD"
case "\$1" in
  --help)
    cat <<'HELP'
Usage: ralph <command> [args]

Commands:
  run          Run a plan
  create       Create scaffolding
  graph        Graph-mode plans
  agent        Manage agent profiles

Options:
  --bundle-path  Print the bundled .ralph directory (for scripts)
HELP
    exit 0
    ;;
  --bundle-path)
    printf '%s\n' "$FAKE_BUNDLE"
    exit 0
    ;;
  run|graph)
    printf '%s\n' "plan execution is forbidden during install consent: \$*" >&2
    exit 99
    ;;
  *)
    printf '%s\n' "unexpected ralph invocation: \$*" >&2
    exit 99
    ;;
esac
RALPH
  chmod +x "$FAKE_BIN/ralph"
  printf '1\n' >"$FAKE_BUNDLE/plugin-api-version"
  if [[ "\$1" != "--global" ]]; then
    printf '%s\n' "install.sh must be invoked with --global" >&2
    exit 2
  fi
EOF
  chmod +x "$INSTALL_SH"
}

install_fake_ralph() {
  printf '1\n' >"$FAKE_BUNDLE/plugin-api-version"
  cat >"$FAKE_BIN/ralph" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$RALPH_RECORD"
case "\$1" in
  --help)
    cat <<'HELP'
Usage: ralph <command> [args]

Commands:
  run          Run a plan
  create       Create scaffolding
  graph        Graph-mode plans
  agent        Manage agent profiles

Options:
  --bundle-path  Print the bundled .ralph directory (for scripts)
HELP
    exit 0
    ;;
  --bundle-path)
    printf '%s\n' "$FAKE_BUNDLE"
    exit 0
    ;;
  run|graph)
    printf '%s\n' "plan execution is forbidden during install consent: \$*" >&2
    exit 99
    ;;
  *)
    printf '%s\n' "unexpected ralph invocation: \$*" >&2
    exit 99
    ;;
esac
EOF
  chmod +x "$FAKE_BIN/ralph"
}

ensure_env() {
  env HOME="$FAKE_HOME" \
    RALPH_HOME="$RALPH_HOME_DIR" \
    RALPH_PLUGIN_INSTALL_SH="$INSTALL_SH" \
    PATH="$FAKE_BIN:$EXEC_STUB_DIR:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$@"
}

run_ensure() {
  ensure_env /bin/bash "$BOOTSTRAP" ensure --json "$@"
}

json_from_output() {
  printf '%s\n' "$1" | awk 'match($0, /\{.*\}/) { print substr($0, RSTART, RLENGTH); exit }'
}

assert_json_field() {
  local json=$1
  local field=$2
  local expected=$3
  local actual
  actual="$(printf '%s\n' "$json" | jq -r --arg f "$field" '.[$f] | if type=="boolean" then (if . then "true" else "false" end) else tostring end')"
  [ "$actual" = "$expected" ]
}

assert_no_plan_execution() {
  [[ ! -f "$RALPH_RECORD" ]] || ! grep -Eq '^(run|graph)([[:space:]]|$)' "$RALPH_RECORD"
  [[ ! -f "$EXEC_RECORD" ]]
}

home_snapshot() {
  find "$FAKE_HOME" -print | LC_ALL=C sort
}

@test "ensure accept with --yes runs install.sh --global after printing command and destination" {
  run run_ensure --yes
  local json
  json="$(json_from_output "$output")"
  [ "$status" -eq 0 ]
  [[ "$output" == *"command: bash $INSTALL_SH --global --yes"* ]]
  [[ "$output" == *"destination: $RALPH_HOME_DIR"* ]]
  [[ "$output" == *"Installation consent does not authorize plan execution"* ]]
  assert_json_field "$json" "outcome" "usable"
  assert_json_field "$json" "installConsent" "accepted"
  assert_json_field "$json" "installRan" "true"
  assert_json_field "$json" "planExecuted" "false"
  [ -f "$MARKER" ]
  grep -qx -- '--global --yes' "$INSTALL_RECORD" || grep -qx -- '--global' "$INSTALL_RECORD"
  grep -q -- '--global' "$INSTALL_RECORD"
  grep -q -- '--yes' "$INSTALL_RECORD"
  assert_no_plan_execution
}

@test "ensure decline mutates nothing and does not execute a plan" {
  local before after json
  before="$(home_snapshot)"
  run bash -c 'printf "no\n" | "$@"' _ env HOME="$FAKE_HOME" \
    RALPH_HOME="$RALPH_HOME_DIR" \
    RALPH_PLUGIN_INSTALL_SH="$INSTALL_SH" \
    PATH="$FAKE_BIN:$EXEC_STUB_DIR:/usr/bin:/bin:/usr/sbin:/sbin" \
    /bin/bash "$BOOTSTRAP" ensure --json
  after="$(home_snapshot)"
  json="$(json_from_output "$output")"
  [ "$status" -ne 0 ]
  [[ "$output" == *"command: bash $INSTALL_SH --global"* ]]
  [[ "$output" == *"destination: $RALPH_HOME_DIR"* ]]
  assert_json_field "$json" "installConsent" "declined"
  assert_json_field "$json" "installRan" "false"
  assert_json_field "$json" "planExecuted" "false"
  [ ! -f "$MARKER" ]
  [ ! -f "$INSTALL_RECORD" ]
  [ "$before" = "$after" ]
  assert_no_plan_execution
}

@test "ensure closed stdin without --yes exits with remediation and mutates nothing" {
  local before after json
  before="$(home_snapshot)"
  run bash -c 'exec < /dev/null; exec "$@"' _ env HOME="$FAKE_HOME" \
    RALPH_HOME="$RALPH_HOME_DIR" \
    RALPH_PLUGIN_INSTALL_SH="$INSTALL_SH" \
    PATH="$FAKE_BIN:$EXEC_STUB_DIR:/usr/bin:/bin:/usr/sbin:/sbin" \
    /bin/bash "$BOOTSTRAP" ensure --json
  after="$(home_snapshot)"
  json="$(json_from_output "$output")"
  [ "$status" -ne 0 ]
  [[ "$output" == *"command: bash $INSTALL_SH --global"* ]]
  [[ "$output" == *"destination: $RALPH_HOME_DIR"* ]]
  [[ "$output" == *"--yes"* ]]
  [[ "$output" == *"Closed stdin"* ]] || [[ "$output" == *"no TTY"* ]]
  assert_json_field "$json" "installConsent" "blocked-noninteractive"
  assert_json_field "$json" "installRan" "false"
  assert_json_field "$json" "planExecuted" "false"
  [ ! -f "$MARKER" ]
  [ ! -f "$INSTALL_RECORD" ]
  [ "$before" = "$after" ]
  assert_no_plan_execution
}

@test "ensure no TTY without --yes exits with remediation and mutates nothing" {
  local before after json
  before="$(home_snapshot)"
  # Regular-file stdin is not a TTY and not a pipe; bats also captures stdout.
  : >"$TEST_TMPDIR/no-tty-stdin"
  run bash -c 'exec < "$1"; shift; exec "$@"' _ "$TEST_TMPDIR/no-tty-stdin" \
    env HOME="$FAKE_HOME" \
    RALPH_HOME="$RALPH_HOME_DIR" \
    RALPH_PLUGIN_INSTALL_SH="$INSTALL_SH" \
    PATH="$FAKE_BIN:$EXEC_STUB_DIR:/usr/bin:/bin:/usr/sbin:/sbin" \
    /bin/bash "$BOOTSTRAP" ensure --json
  after="$(home_snapshot)"
  json="$(json_from_output "$output")"
  [ "$status" -ne 0 ]
  [[ "$output" == *"command: bash $INSTALL_SH --global"* ]]
  [[ "$output" == *"destination: $RALPH_HOME_DIR"* ]]
  [[ "$output" == *"--yes"* ]]
  [[ "$output" == *"TTY"* ]] || [[ "$output" == *"stdin"* ]]
  assert_json_field "$json" "installConsent" "blocked-noninteractive"
  assert_json_field "$json" "installRan" "false"
  assert_json_field "$json" "planExecuted" "false"
  [ ! -f "$MARKER" ]
  [ ! -f "$INSTALL_RECORD" ]
  [ "$before" = "$after" ]
  assert_no_plan_execution
}

@test "ensure post-install skips installer and does not execute a plan" {
  install_fake_ralph
  run run_ensure --yes
  local json
  json="$(json_from_output "$output")"
  [ "$status" -eq 0 ]
  assert_json_field "$json" "outcome" "usable"
  assert_json_field "$json" "installConsent" "not-offered"
  assert_json_field "$json" "installRan" "false"
  assert_json_field "$json" "planExecuted" "false"
  [ ! -f "$MARKER" ]
  [ ! -f "$INSTALL_RECORD" ]
  assert_no_plan_execution
  if [[ -f "$RALPH_RECORD" ]]; then
    while IFS= read -r line; do
      case "$line" in
        --help|--bundle-path) ;;
        *) echo "unexpected recorded invocation: $line" >&2; return 1 ;;
      esac
    done <"$RALPH_RECORD"
  fi
}
