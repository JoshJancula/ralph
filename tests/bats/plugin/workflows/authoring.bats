#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../../helper/load-lib.bash"

INPUT_ROOT="$REPO_ROOT/bundle/.ralph/plugin-inputs"
BOOTSTRAP="$INPUT_ROOT/shared/ralph-plugin-bootstrap.sh"
WORKFLOW_IDS=(ralph-plan ralph-workflow)

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
  VALIDATE_RECORD="$TEST_TMPDIR/validate-invocations.log"
  mkdir -p "$FAKE_BIN" "$FAKE_BUNDLE" "$FAKE_PROJECT" "$PLUGIN_ROOT/shared"
  if command -v jq >/dev/null 2>&1; then
    ln -sf "$(command -v jq)" "$FAKE_BIN/jq"
  fi
  write_install_trap
  write_exec_trap
  write_bootstrap_wrapper
  write_validate_stub
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

write_install_trap() {
  cat >"$FAKE_BIN/install.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$INSTALL_RECORD"
printf '%s\n' "install.sh must not run from an authoring workflow" >&2
exit 99
EOF
  chmod +x "$FAKE_BIN/install.sh"
}

write_exec_trap() {
  cat >"$FAKE_BIN/ralph-plugin-exec.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$EXEC_RECORD"
printf '%s\n' "ralph-plugin-exec must not run from an authoring workflow" >&2
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

write_validate_stub() {
  cat >"$FAKE_BUNDLE/validate-plan.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$VALIDATE_RECORD"
printf 'validate-plan: ok %s\n' "\$1"
exit 0
EOF
  chmod +x "$FAKE_BUNDLE/validate-plan.sh"
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
  create)
    printf 'scaffolded: %s\n' "\$*"
    exit 0
    ;;
  workflow)
    case "\${2-}" in
      inspect|runs|list|status|actions)
        printf 'workflow-%s: %s\n' "\$2" "\$*"
        exit 0
        ;;
      start|resume|reset|recover)
        printf '%s\n' "mutating lifecycle must be printed, not executed: \$*" >&2
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
  shift
  workflow_env "$@" /bin/bash "$script"
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

assert_no_run_or_resume() {
  [ ! -f "$INSTALL_RECORD" ]
  [ ! -f "$EXEC_RECORD" ]
  if [[ -f "$RALPH_RECORD" ]]; then
    ! grep -Eq '(^|[[:space:]])(run)([[:space:]]|$)' "$RALPH_RECORD"
    ! grep -Eq '^workflow[[:space:]]+(start|resume|reset|recover)([[:space:]]|$)' "$RALPH_RECORD"
    ! grep -Eq '(^|[[:space:]])(doctor|capabilities|hook|graph|role)([[:space:]]|$)' "$RALPH_RECORD"
    while IFS= read -r line; do
      case "$line" in
        --help|--bundle-path) ;;
        "create plan"*|"create workflow"*) ;;
        "workflow inspect "*|"workflow runs --all"|"workflow status "*|"workflow actions list "*) ;;
        *) echo "unexpected recorded invocation: $line" >&2; return 1 ;;
      esac
    done <"$RALPH_RECORD"
  fi
}

assert_bash_never_executes() {
  local script=$1
  ! grep -Eq 'ralph-plugin-exec\.sh|bootstrap\.sh ensure|install\.sh' "$script"
  # Allow printf/echo guidance that mentions public start/resume; forbid invoking them.
  ! grep -Eq '^[[:space:]]*ralph[[:space:]]+run([[:space:]]|$)' "$script"
  ! grep -Eq '^[[:space:]]*ralph[[:space:]]+workflow[[:space:]]+(start|resume)([[:space:]]|$)' "$script"
}

@test "authoring workflow inputs exist and bash never executes through the plugin gate" {
  local id script
  for id in "${WORKFLOW_IDS[@]}"; do
    [ -f "$INPUT_ROOT/workflows/${id}.md" ]
    grep -q 'Never call' "$INPUT_ROOT/workflows/${id}.md"
    grep -q '`ensure`' "$INPUT_ROOT/workflows/${id}.md"
    extract_workflow_script "$id" "$TEST_TMPDIR/${id}.sh"
    script="$TEST_TMPDIR/${id}.sh"
    assert_bash_never_executes "$script"
  done
  grep -q 'ralph create plan' "$INPUT_ROOT/workflows/ralph-plan.md"
  grep -q 'ralph create workflow' "$INPUT_ROOT/workflows/ralph-workflow.md"
  grep -q 'Sequential' "$INPUT_ROOT/workflows/ralph-workflow.md"
  grep -q 'Dependency' "$INPUT_ROOT/workflows/ralph-workflow.md"
  grep -q 'generated versus supplied' "$INPUT_ROOT/workflows/ralph-workflow.md" || \
    grep -qi 'generated versus supplied\|Generated versus supplied' "$INPUT_ROOT/workflows/ralph-workflow.md"
  grep -q 'immutable' "$INPUT_ROOT/workflows/ralph-workflow.md"
  grep -q 'approval' "$INPUT_ROOT/workflows/ralph-workflow.md"
  grep -q 'resume' "$INPUT_ROOT/workflows/ralph-workflow.md"
  grep -q 'untracked one-turn' "$INPUT_ROOT/workflows/ralph-workflow.md"
  [ ! -f "$INPUT_ROOT/workflows/ralph-agents.md" ]
  [ ! -f "$INPUT_ROOT/workflows/ralph-graph.md" ]
  [ ! -f "$INPUT_ROOT/workflows/ralph-orchestrate.md" ]
}

@test "plan and workflow scaffold and inspect without executing" {
  local plan="$FAKE_PROJECT/sample.plan.md"
  local workflow="$FAKE_PROJECT/sample.workflow.md"
  printf 'plan\n' >"$plan"
  printf 'workflow\n' >"$workflow"
  install_fake_ralph current
  write_abi 1

  rm -f "$RALPH_RECORD" "$BOOTSTRAP_RECORD" "$INSTALL_RECORD" "$EXEC_RECORD" "$VALIDATE_RECORD"
  run run_workflow ralph-plan \
    RALPH_PLUGIN_OPERATION=scaffold \
    RALPH_PLUGIN_PLAN_NAME=demo \
    RALPH_PLUGIN_PLAN_FORMAT=classic
  [ "$status" -eq 0 ]
  [[ "$output" == *"workflow: ralph-plan"* ]]
  [[ "$output" == *"operation: scaffold"* ]]
  grep -Fxq 'create plan --name demo --format classic' "$RALPH_RECORD"
  assert_probe_only_bootstrap
  assert_no_run_or_resume

  rm -f "$RALPH_RECORD" "$BOOTSTRAP_RECORD" "$VALIDATE_RECORD"
  run run_workflow ralph-plan \
    RALPH_PLUGIN_OPERATION=validate \
    RALPH_PLUGIN_PLAN_PATH="$plan"
  [ "$status" -eq 0 ]
  grep -Fxq "$plan" "$VALIDATE_RECORD"
  assert_no_run_or_resume

  rm -f "$RALPH_RECORD" "$BOOTSTRAP_RECORD"
  run run_workflow ralph-workflow \
    RALPH_PLUGIN_OPERATION=scaffold \
    RALPH_PLUGIN_WORKFLOW_MODE=sequential
  [ "$status" -eq 0 ]
  [[ "$output" == *"workflow: ralph-workflow"* ]]
  [[ "$output" == *"modes: Sequential Dependency"* ]]
  grep -Fxq 'create workflow --mode sequential' "$RALPH_RECORD"
  assert_no_run_or_resume

  rm -f "$RALPH_RECORD" "$BOOTSTRAP_RECORD"
  run run_workflow ralph-workflow \
    RALPH_PLUGIN_OPERATION=inspect \
    RALPH_PLUGIN_WORKFLOW_PATH="$workflow"
  [ "$status" -eq 0 ]
  grep -Fxq "workflow inspect --file $workflow" "$RALPH_RECORD"
  assert_no_run_or_resume

  rm -f "$RALPH_RECORD" "$BOOTSTRAP_RECORD"
  run run_workflow ralph-workflow \
    RALPH_PLUGIN_OPERATION=print-start \
    RALPH_PLUGIN_WORKFLOW_ID=feature-delivery \
    RALPH_PLUGIN_TASK='ship it' \
    RALPH_PLUGIN_LEAF_PLAN="$plan"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ralph workflow start feature-delivery --task ship it --plan $plan"* ]]
  assert_no_run_or_resume
}

@test "quoted or hypothetical execution text does not run or resume" {
  install_fake_ralph current
  write_abi 1

  rm -f "$RALPH_RECORD" "$BOOTSTRAP_RECORD" "$EXEC_RECORD"
  run run_workflow ralph-plan \
    RALPH_PLUGIN_OPERATION=scaffold \
    RALPH_PLUGIN_REQUEST='Could you "ralph run demo.plan.md" if we wanted to?'
  [ "$status" -eq 0 ]
  assert_no_run_or_resume

  rm -f "$RALPH_RECORD" "$BOOTSTRAP_RECORD"
  run run_workflow ralph-workflow \
    RALPH_PLUGIN_OPERATION=scaffold \
    RALPH_PLUGIN_WORKFLOW_MODE=dependency \
    RALPH_PLUGIN_REQUEST='hypothetically ralph workflow start the plan'
  [ "$status" -eq 0 ]
  assert_no_run_or_resume

  rm -f "$RALPH_RECORD" "$BOOTSTRAP_RECORD"
  run run_workflow ralph-workflow RALPH_PLUGIN_OPERATION=run
  [ "$status" -ne 0 ]
  [[ "$output" == *"rejected-operation: run"* ]]
  assert_no_run_or_resume
}

@test "missing and too-old CLI block authoring without execution" {
  local id
  for id in "${WORKFLOW_IDS[@]}"; do
    rm -f "$RALPH_RECORD" "$BOOTSTRAP_RECORD" "$INSTALL_RECORD" "$EXEC_RECORD"
    run run_workflow "$id"
    [ "$status" -ne 0 ]
    [[ "$output" == *"\"outcome\":\"missing\""* ]]
    assert_probe_only_bootstrap
    [ ! -f "$RALPH_RECORD" ]
    assert_no_run_or_resume
  done

  install_fake_ralph current
  write_abi 0
  for id in "${WORKFLOW_IDS[@]}"; do
    rm -f "$RALPH_RECORD" "$BOOTSTRAP_RECORD"
    run run_workflow "$id"
    [ "$status" -ne 0 ]
    [[ "$output" == *"\"outcome\":\"too-old\""* ]]
    assert_no_run_or_resume
  done
}
