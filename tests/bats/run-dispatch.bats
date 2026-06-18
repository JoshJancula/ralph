#!/usr/bin/env bats

# The `ralph run --plan <file>` shim routes by file content: classic markdown and flat
# standard plans go to run-plan.sh; orchestration plans (pipeline/execution frontmatter)
# and legacy .orch.json go to orchestrator.sh. The --orc flag has been removed.

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

setup() {
  RH="$(mktemp -d)"            # fake RALPH_HOME
  mkdir -p "$RH/bundle/.ralph"
  # Stub runners that announce which one ran and echo their args.
  cat > "$RH/bundle/.ralph/run-plan.sh" <<'EOF'
#!/usr/bin/env bash
echo "RAN run-plan.sh $*"
EOF
  cat > "$RH/bundle/.ralph/orchestrator.sh" <<'EOF'
#!/usr/bin/env bash
echo "RAN orchestrator.sh $*"
EOF
  chmod +x "$RH/bundle/.ralph/run-plan.sh" "$RH/bundle/.ralph/orchestrator.sh"

  # Extract the embedded SHIM heredoc from install.sh into a runnable script.
  SHIM="$RH/ralph"
  awk "/cat > \"\\\$tmp\" <<'SHIM'/{f=1;next} /^SHIM\$/{f=0} f" "$REPO_ROOT/install.sh" > "$SHIM"
  chmod +x "$SHIM"

  FIX="$(mktemp -d)"
  printf '# Plan\n\n- [ ] do a thing\n' > "$FIX/classic.md"
  printf '%s\n' '---' 'name: Flat' 'execution: standard' '' 'todos:' '  - id: t1' '    content: x' '    status: pending' '---' > "$FIX/flat.plan.md"
  printf '%s\n' '---' 'name: Orc' 'execution: orchestration' 'pipeline:' '  stages:' '    - id: a' '      runtime: cursor' '      agent: research' '---' > "$FIX/orc.plan.md"
  printf '%s\n' '---' 'name: O2' 'execution: orchestration' '---' > "$FIX/execonly.plan.md"
  printf '{}' > "$FIX/legacy.orch.json"
}

teardown() {
  rm -rf "$RH" "$FIX"
}

run_ralph() {
  RALPH_HOME="$RH" bash "$SHIM" "$@"
}

@test "classic markdown routes to run-plan.sh" {
  run run_ralph run --plan "$FIX/classic.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RAN run-plan.sh"* ]]
}

@test "flat standard plan routes to run-plan.sh" {
  run run_ralph run --plan "$FIX/flat.plan.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RAN run-plan.sh"* ]]
}

@test "pipeline frontmatter routes to orchestrator.sh" {
  run run_ralph run --plan "$FIX/orc.plan.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RAN orchestrator.sh"* ]]
}

@test "execution: orchestration routes to orchestrator.sh" {
  run run_ralph run --plan "$FIX/execonly.plan.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RAN orchestrator.sh"* ]]
}

@test "legacy .orch.json routes to orchestrator.sh" {
  run run_ralph run --plan "$FIX/legacy.orch.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RAN orchestrator.sh"* ]]
}

@test "ralph run --orc is no longer recognized" {
  run run_ralph run --orc "$FIX/legacy.orch.json"
  [ "$status" -ne 0 ]
}

@test "ralph run with no --plan errors" {
  run run_ralph run
  [ "$status" -ne 0 ]
}
