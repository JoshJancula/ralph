#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../../helper/load-lib.bash"

INPUT_ROOT="$REPO_ROOT/bundle/.ralph/plugin-inputs"
BOOTSTRAP="$INPUT_ROOT/shared/ralph-plugin-bootstrap.sh"
WORKFLOW_IDS=(ralph-plan ralph-orchestrate ralph-graph)
CAPS_SOURCE="$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-runtime-capabilities.sh"

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
  CAPS_RECORD="$TEST_TMPDIR/capabilities-invocations.log"
  mkdir -p "$FAKE_BIN" "$FAKE_BUNDLE/bash-lib/graph" "$FAKE_PROJECT" "$PLUGIN_ROOT/shared"
  if command -v jq >/dev/null 2>&1; then
    ln -sf "$(command -v jq)" "$FAKE_BIN/jq"
  fi
  write_install_trap
  write_exec_trap
  write_bootstrap_wrapper
  write_validate_stub
  write_capabilities_stub
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

write_capabilities_stub() {
  cat >"$FAKE_BUNDLE/bash-lib/graph/graph-runtime-capabilities.sh" <<EOF
#!/usr/bin/env bash
# Test double: records queries and marks selected runtimes unavailable.
GRAPH_RUNTIME_CAPABILITIES_KNOWN='claude
cursor
codex
opencode
antigravity
mystery'
graph_runtime_cli_name() {
  case "\$1" in
    claude) printf 'claude\n' ;;
    cursor) printf 'cursor-agent\n' ;;
    codex) printf 'codex\n' ;;
    opencode) printf 'opencode\n' ;;
    antigravity) printf 'agy\n' ;;
    *) printf '\n' ;;
  esac
}
graph_runtime_capabilities() {
  local runtime="\$1"
  printf '%s\n' "\$runtime" >>"$CAPS_RECORD"
  local usage="authoritative"
  case "\$runtime" in
    mystery) usage="unavailable" ;;
    opencode|antigravity) usage="estimated" ;;
  esac
  command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; return 1; }
  jq -nc --arg runtime "\$runtime" --arg usage "\$usage" '{
    schemaVersion: 1,
    runtime: \$runtime,
    workspaceEnforcement: true,
    liveApprovals: false,
    sessionContinuation: true,
    usageReliability: \$usage,
    provenSandboxBoundary: false,
    probe: { attempted: false, modelCall: false }
  }'
}
EOF
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
  graph        Graph-mode plans
  agent        Manage agent profiles

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
  graph)
    case "\${2-}" in
      compile|render)
        printf 'graph-%s: %s\n' "\$2" "\$*"
        exit 0
        ;;
      run|resume)
        printf '%s\n' "executing subcommand is forbidden: \$*" >&2
        exit 99
        ;;
      *)
        printf '%s\n' "unexpected graph invocation: \$*" >&2
        exit 99
        ;;
    esac
    ;;
  run)
    printf '%s\n' "executing subcommand is forbidden: \$*" >&2
    exit 99
    ;;
  doctor|capabilities|hook)
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

install_present_runtime_clis() {
  local name
  for name in claude cursor-agent; do
    cat >"$FAKE_BIN/$name" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$FAKE_BIN/$name"
  done
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
    ! grep -Eq '(^|[[:space:]])(run|resume)([[:space:]]|$)' "$RALPH_RECORD"
    ! grep -Eq '^graph[[:space:]]+(run|resume)([[:space:]]|$)' "$RALPH_RECORD"
    ! grep -Eq '(^|[[:space:]])(doctor|capabilities|hook)([[:space:]]|$)' "$RALPH_RECORD"
    while IFS= read -r line; do
      case "$line" in
        --help|--bundle-path) ;;
        "create plan"*|"create orc"|"create graph"|"create plan --format graph --name "*) ;;
        "graph compile "*|"graph render "*) ;;
        *) echo "unexpected recorded invocation: $line" >&2; return 1 ;;
      esac
    done <"$RALPH_RECORD"
  fi
}

assert_bash_never_executes() {
  local script=$1
  ! grep -Eq 'ralph-plugin-exec\.sh|bootstrap\.sh ensure|install\.sh' "$script"
  ! grep -Eq 'ralph[[:space:]]+run|ralph[[:space:]]+graph[[:space:]]+run|ralph[[:space:]]+graph[[:space:]]+resume' "$script"
}

@test "authoring workflow inputs exist and bash never executes or invents capabilities" {
  local id script
  for id in "${WORKFLOW_IDS[@]}"; do
    [ -f "$INPUT_ROOT/workflows/${id}.md" ]
    grep -q 'Category: authoring' "$INPUT_ROOT/workflows/${id}.md"
    grep -q 'Never call' "$INPUT_ROOT/workflows/${id}.md"
    grep -q '`ensure`' "$INPUT_ROOT/workflows/${id}.md"
    extract_workflow_script "$id" "$TEST_TMPDIR/${id}.sh"
    script="$TEST_TMPDIR/${id}.sh"
    assert_bash_never_executes "$script"
  done
  grep -q 'ralph create plan' "$INPUT_ROOT/workflows/ralph-plan.md"
  grep -q 'ralph create orc' "$INPUT_ROOT/workflows/ralph-orchestrate.md"
  grep -q 'graph_runtime_capabilities' "$INPUT_ROOT/workflows/ralph-graph.md"
  grep -q 'ralph graph compile' "$INPUT_ROOT/workflows/ralph-graph.md"
  grep -q 'ralph graph render' "$INPUT_ROOT/workflows/ralph-graph.md"
  grep -q 'never-invent' "$INPUT_ROOT/workflows/ralph-graph.md"
  [ -f "$CAPS_SOURCE" ]
}

@test "plan, orchestration, and graph scaffold and validate without executing" {
  local plan="$FAKE_PROJECT/sample.plan.md"
  printf 'plan\n' >"$plan"
  install_fake_ralph current
  write_abi 1
  install_present_runtime_clis

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
  run run_workflow ralph-orchestrate RALPH_PLUGIN_OPERATION=scaffold
  [ "$status" -eq 0 ]
  [[ "$output" == *"workflow: ralph-orchestrate"* ]]
  grep -Fxq 'create orc' "$RALPH_RECORD"
  assert_no_run_or_resume

  rm -f "$RALPH_RECORD" "$BOOTSTRAP_RECORD" "$VALIDATE_RECORD"
  run run_workflow ralph-orchestrate \
    RALPH_PLUGIN_OPERATION=validate \
    RALPH_PLUGIN_PLAN_PATH="$plan"
  [ "$status" -eq 0 ]
  grep -Fxq "$plan" "$VALIDATE_RECORD"
  assert_no_run_or_resume

  rm -f "$RALPH_RECORD" "$BOOTSTRAP_RECORD" "$CAPS_RECORD"
  run run_workflow ralph-graph RALPH_PLUGIN_OPERATION=scaffold
  [ "$status" -eq 0 ]
  [[ "$output" == *"workflow: ralph-graph"* ]]
  grep -Fxq 'create graph' "$RALPH_RECORD"
  [ -f "$CAPS_RECORD" ]
  assert_no_run_or_resume
}

@test "graph compile and render are permitted and never call run or resume" {
  local plan="$FAKE_PROJECT/graph.plan.md"
  printf 'graph\n' >"$plan"
  install_fake_ralph current
  write_abi 1
  install_present_runtime_clis

  rm -f "$RALPH_RECORD" "$BOOTSTRAP_RECORD" "$CAPS_RECORD"
  run run_workflow ralph-graph \
    RALPH_PLUGIN_OPERATION=compile \
    RALPH_PLUGIN_PLAN_PATH="$plan"
  [ "$status" -eq 0 ]
  [[ "$output" == *"author: ralph graph compile"* ]]
  grep -Fxq "graph compile $plan" "$RALPH_RECORD"
  assert_no_run_or_resume

  rm -f "$RALPH_RECORD" "$BOOTSTRAP_RECORD"
  run run_workflow ralph-graph \
    RALPH_PLUGIN_OPERATION=render \
    RALPH_PLUGIN_PLAN_PATH="$plan"
  [ "$status" -eq 0 ]
  grep -Fxq "graph render $plan" "$RALPH_RECORD"
  assert_no_run_or_resume
}

@test "quoted or hypothetical execution text does not run or resume" {
  install_fake_ralph current
  write_abi 1
  install_present_runtime_clis

  rm -f "$RALPH_RECORD" "$BOOTSTRAP_RECORD" "$EXEC_RECORD"
  run run_workflow ralph-plan \
    RALPH_PLUGIN_OPERATION=scaffold \
    RALPH_PLUGIN_REQUEST='Could you "ralph run demo.plan.md" if we wanted to?'
  [ "$status" -eq 0 ]
  assert_no_run_or_resume

  rm -f "$RALPH_RECORD" "$BOOTSTRAP_RECORD"
  run run_workflow ralph-graph \
    RALPH_PLUGIN_OPERATION=scaffold \
    RALPH_PLUGIN_REQUEST='hypothetically ralph graph run the plan'
  [ "$status" -eq 0 ]
  assert_no_run_or_resume

  rm -f "$RALPH_RECORD" "$BOOTSTRAP_RECORD"
  run run_workflow ralph-graph RALPH_PLUGIN_OPERATION=run
  [ "$status" -ne 0 ]
  [[ "$output" == *"rejected-operation: run"* ]]
  assert_no_run_or_resume
}

@test "graph authoring queries capabilities and does not emit unavailable runtimes or models" {
  install_fake_ralph current
  write_abi 1
  install_present_runtime_clis

  rm -f "$RALPH_RECORD" "$CAPS_RECORD"
  run run_workflow ralph-graph \
    RALPH_PLUGIN_OPERATION=scaffold \
    RALPH_PLUGIN_RUNTIME=opencode \
    RALPH_PLUGIN_MODEL=invented-from-training
  [ "$status" -eq 0 ]
  [ -f "$CAPS_RECORD" ]
  grep -Fxq claude "$CAPS_RECORD"
  grep -Fxq mystery "$CAPS_RECORD"
  grep -Fxq opencode "$CAPS_RECORD"
  [[ "$output" == *"capabilities-query: graph_runtime_capabilities"* ]]
  [[ "$output" == *"available-runtimes: claude cursor"* ]]
  [[ "$output" != *"available-runtimes:"*"opencode"* ]]
  [[ "$output" != *"available-runtimes:"*"mystery"* ]]
  [[ "$output" != *"available-runtimes:"*"codex"* ]]
  [[ "$output" != *"assigned-runtime: opencode"* ]]
  [[ "$output" == *"assigned-runtime: none"* ]]
  [[ "$output" == *"runtime-status: not-offered"* ]]
  [[ "$output" != *"assigned-model: invented-from-training"* ]]
  [[ "$output" == *"assigned-model: none"* ]]
  [[ "$output" == *"model-status: ask-operator"* ]]
  [[ "$output" != *"gpt-"* ]]
  [[ "$output" != *"claude-opus"* ]]
  assert_no_run_or_resume

  rm -f "$RALPH_RECORD" "$CAPS_RECORD"
  run run_workflow ralph-graph \
    RALPH_PLUGIN_OPERATION=edit \
    RALPH_PLUGIN_PLAN_PATH="$FAKE_PROJECT/graph.plan.md" \
    RALPH_PLUGIN_RUNTIME=claude \
    RALPH_PLUGIN_MODEL=listed-model \
    RALPH_PLUGIN_MODELS=$'listed-model\nother-model'
  [ "$status" -eq 0 ]
  [[ "$output" == *"assigned-runtime: claude"* ]]
  [[ "$output" == *"assigned-model: listed-model"* ]]
  [[ "$output" != *"assigned-model: other-model"* ]]
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
