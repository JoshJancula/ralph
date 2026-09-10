#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../../helper/load-lib.bash"

INPUT_ROOT="$REPO_ROOT/bundle/.ralph/plugin-inputs"
BOOTSTRAP="$INPUT_ROOT/shared/ralph-plugin-bootstrap.sh"
WORKFLOW_IDS=(ralph-status ralph-doctor)

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  FAKE_BIN="$TEST_TMPDIR/bin"
  FAKE_BUNDLE="$TEST_TMPDIR/bundle/.ralph"
  FAKE_PROJECT="$TEST_TMPDIR/project"
  PLUGIN_ROOT="$TEST_TMPDIR/plugin"
  RALPH_RECORD="$TEST_TMPDIR/ralph-invocations.log"
  BOOTSTRAP_RECORD="$TEST_TMPDIR/bootstrap-invocations.log"
  INSTALL_RECORD="$TEST_TMPDIR/install-invocations.log"
  EXEC_RECORD="$TEST_TMPDIR/exec-invocations.log"
  mkdir -p "$FAKE_BIN" "$FAKE_BUNDLE" "$FAKE_PROJECT/.claude" "$PLUGIN_ROOT/shared"
  if command -v jq >/dev/null 2>&1; then
    ln -sf "$(command -v jq)" "$FAKE_BIN/jq"
  fi
  write_install_trap
  write_exec_trap
  write_bootstrap_wrapper
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

write_install_trap() {
  cat >"$FAKE_BIN/install.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$INSTALL_RECORD"
printf '%s\n' "install.sh must not run from a read-only workflow" >&2
exit 99
EOF
  chmod +x "$FAKE_BIN/install.sh"
}

write_exec_trap() {
  cat >"$FAKE_BIN/ralph-plugin-exec.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$EXEC_RECORD"
printf '%s\n' "ralph-plugin-exec must not run from a read-only workflow" >&2
exit 99
EOF
  chmod +x "$FAKE_BIN/ralph-plugin-exec.sh"
}

write_bootstrap_wrapper() {
  cat >"$PLUGIN_ROOT/shared/ralph-plugin-bootstrap.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$BOOTSTRAP_RECORD"
exec /bin/bash "$BOOTSTRAP" "\$@"
EOF
  chmod +x "$PLUGIN_ROOT/shared/ralph-plugin-bootstrap.sh"
}

install_fake_ralph() {
  local mode="$1"
  cat >"$FAKE_BIN/ralph" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$RALPH_RECORD"
mode="$mode"
bundle="$FAKE_BUNDLE"
case "\$1" in
  --help)
    cat <<'HELP'
Usage: ralph <command> [args]

Commands:
  run          Run a plan
  create       Create scaffolding
  workflow     Manage workflows

Options:
  --bundle-path  Print the bundled .ralph directory (for scripts)
HELP
    exit 0
    ;;
  --bundle-path)
    if [[ "\$mode" == "legacy" ]]; then
      printf '%s\n' "unknown option" >&2
      exit 2
    fi
    printf '%s\n' "\$bundle"
    exit 0
    ;;
  workflow)
    case "\${2-}" in
      runs|list)
        printf 'workflow %s: ok\n' "\$2"
        exit 0
        ;;
      start|resume)
        printf '%s\n' "executing subcommand is forbidden: \$*" >&2
        exit 99
        ;;
      *)
        printf '%s\n' "unexpected workflow invocation: \$*" >&2
        exit 99
        ;;
    esac
    ;;
  run)
    printf '%s\n' "executing subcommand is forbidden: \$*" >&2
    exit 99
    ;;
  doctor|capabilities|hook|graph|role)
    printf '%s\n' "forbidden verb invoked: \$1" >&2
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

write_abi() {
  printf '%s\n' "$1" >"$FAKE_BUNDLE/plugin-api-version"
}

extract_workflow_script() {
  local name=$1
  local dest=$2
  local rendered="$TEST_TMPDIR/${name}.md"
  sed \
    -e "s|{{SHARED_BOOTSTRAP_REL}}|shared/ralph-plugin-bootstrap.sh|g" \
    -e "s|{{SHARED_EXEC_REL}}|shared/ralph-plugin-exec.sh|g" \
    "$INPUT_ROOT/workflows/${name}.md" >"$rendered"
  awk '/^```bash$/{p=1;next} /^```$/{p=0} p' "$rendered" >"$dest"
  [ -s "$dest" ]
}

workflow_env() {
  env PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    RALPH_PLUGIN_ROOT="$PLUGIN_ROOT" \
    RALPH_PLUGIN_PROJECT_ROOT="$FAKE_PROJECT" \
    RALPH_PLUGIN_INSTALL_SH="$FAKE_BIN/install.sh" \
    "$@"
}

run_workflow() {
  local name=$1
  local script="$TEST_TMPDIR/${name}.sh"
  extract_workflow_script "$name" "$script"
  workflow_env /bin/bash "$script"
}

assert_probe_only_bootstrap() {
  [ -f "$BOOTSTRAP_RECORD" ]
  while IFS= read -r line; do
    case "$line" in
      "probe --json") ;;
      *) echo "unexpected bootstrap invocation: $line" >&2; return 1 ;;
    esac
  done <"$BOOTSTRAP_RECORD"
  ! grep -Eq '(^|[[:space:]])ensure([[:space:]]|$)' "$BOOTSTRAP_RECORD"
}

assert_no_executing_subcommand() {
  [ ! -f "$INSTALL_RECORD" ]
  [ ! -f "$EXEC_RECORD" ]
  if [[ -f "$RALPH_RECORD" ]]; then
    ! grep -Eq '(^|[[:space:]])(run)([[:space:]]|$)' "$RALPH_RECORD"
    ! grep -Eq '^workflow[[:space:]]+(start|resume)([[:space:]]|$)' "$RALPH_RECORD"
    ! grep -Eq '(^|[[:space:]])(doctor|capabilities|hook|graph|role)([[:space:]]|$)' "$RALPH_RECORD"
    while IFS= read -r line; do
      case "$line" in
        --help|--bundle-path|"workflow runs --all"|"workflow list") ;;
        *) echo "unexpected recorded invocation: $line" >&2; return 1 ;;
      esac
    done <"$RALPH_RECORD"
  fi
}

assert_no_inspect_beyond_probe() {
  [[ ! -f "$RALPH_RECORD" ]] && return 0
  while IFS= read -r line; do
    case "$line" in
      --help|--bundle-path) ;;
      *) echo "inspect ran despite blocked probe: $line" >&2; return 1 ;;
    esac
  done <"$RALPH_RECORD"
}

@test "read-only workflow inputs exist and never mention install or execute operations" {
  local id
  for id in "${WORKFLOW_IDS[@]}"; do
    [ -f "$INPUT_ROOT/workflows/${id}.md" ]
    grep -q 'probe' "$INPUT_ROOT/workflows/${id}.md"
    grep -q 'Never call `ensure`' "$INPUT_ROOT/workflows/${id}.md"
    ! grep -Eq 'bootstrap\.sh ensure|ralph-plugin-exec\.sh execute|install\.sh --global' \
      "$INPUT_ROOT/workflows/${id}.md"
    ! grep -Eq 'ralph (run|workflow start|workflow resume)' "$INPUT_ROOT/workflows/${id}.md"
  done
  grep -q 'ralph --bundle-path' "$INPUT_ROOT/workflows/ralph-doctor.md"
  grep -q 'ralph workflow runs' "$INPUT_ROOT/workflows/ralph-doctor.md"
  grep -q 'ralph workflow list' "$INPUT_ROOT/workflows/ralph-doctor.md"
  [ ! -f "$INPUT_ROOT/workflows/ralph-agents.md" ]
}

@test "healthy CLI: each read-only workflow completes without executing" {
  local id
  install_fake_ralph current
  write_abi 1
  for id in "${WORKFLOW_IDS[@]}"; do
    rm -f "$RALPH_RECORD" "$BOOTSTRAP_RECORD" "$INSTALL_RECORD" "$EXEC_RECORD"
    run run_workflow "$id"
    [ "$status" -eq 0 ]
    [[ "$output" == *"\"outcome\":\"usable\""* ]]
    [[ "$output" == *"status: healthy"* ]]
    [[ "$output" == *"workflow: ${id}"* ]]
    assert_probe_only_bootstrap
    assert_no_executing_subcommand
  done
}

@test "missing CLI: each workflow prints remediation, skips install, and does not execute" {
  local id
  for id in "${WORKFLOW_IDS[@]}"; do
    rm -f "$RALPH_RECORD" "$BOOTSTRAP_RECORD" "$INSTALL_RECORD" "$EXEC_RECORD"
    run run_workflow "$id"
    [ "$status" -ne 0 ]
    [[ "$output" == *"\"outcome\":\"missing\""* ]]
    [[ "$output" == *"status: blocked"* ]]
    [[ "$output" == *"remediation:"* ]]
    [[ "$output" == *"install.sh --global"* ]]
    assert_probe_only_bootstrap
    [ ! -f "$RALPH_RECORD" ]
    [ ! -f "$INSTALL_RECORD" ]
    assert_no_executing_subcommand
  done
}

@test "old CLI: legacy --bundle-path failure and too-old ABI both block without execution" {
  local id
  install_fake_ralph legacy
  for id in "${WORKFLOW_IDS[@]}"; do
    rm -f "$RALPH_RECORD" "$BOOTSTRAP_RECORD" "$INSTALL_RECORD" "$EXEC_RECORD"
    run run_workflow "$id"
    [ "$status" -ne 0 ]
    [[ "$output" == *"\"outcome\":\"legacy\""* ]]
    [[ "$output" == *"status: blocked"* ]]
    [[ "$output" == *"remediation:"* ]]
    assert_probe_only_bootstrap
    assert_no_inspect_beyond_probe
    assert_no_executing_subcommand
  done

  install_fake_ralph current
  write_abi 0
  for id in "${WORKFLOW_IDS[@]}"; do
    rm -f "$RALPH_RECORD" "$BOOTSTRAP_RECORD" "$INSTALL_RECORD" "$EXEC_RECORD"
    run run_workflow "$id"
    [ "$status" -ne 0 ]
    [[ "$output" == *"\"outcome\":\"too-old\""* ]]
    [[ "$output" == *"status: blocked"* ]]
    [[ "$output" == *"remediation:"* ]]
    assert_probe_only_bootstrap
    assert_no_inspect_beyond_probe
    assert_no_executing_subcommand
  done
}

@test "newer CLI: each workflow warns and still completes without executing" {
  local id
  install_fake_ralph current
  write_abi 2
  for id in "${WORKFLOW_IDS[@]}"; do
    rm -f "$RALPH_RECORD" "$BOOTSTRAP_RECORD" "$INSTALL_RECORD" "$EXEC_RECORD"
    run run_workflow "$id"
    [ "$status" -eq 0 ]
    [[ "$output" == *"\"outcome\":\"newer\""* ]]
    [[ "$output" == *"status: newer-cli-warning"* ]]
    assert_probe_only_bootstrap
    assert_no_executing_subcommand
  done
}
