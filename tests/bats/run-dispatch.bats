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
  cat > "$RH/bundle/.ralph/graph-run.sh" <<'EOF'
#!/usr/bin/env bash
echo "RAN graph-run.sh $*"
EOF
  chmod +x "$RH/bundle/.ralph/run-plan.sh" "$RH/bundle/.ralph/orchestrator.sh" "$RH/bundle/.ralph/graph-run.sh"

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
  # A plan with a pipeline: block but NO execution: field -- must route to orchestrator,
  # not graph-run.sh. This is the "bare pipeline block" guarantee: no auto-upgrade to graph.
  printf '%s\n' '---' 'name: BareP' 'pipeline:' '  stages:' '    - id: a' '      runtime: cursor' '      agent: research' '---' > "$FIX/bare-pipeline.plan.md"
  # Graph fixtures
  printf '%s\n' '---' 'name: Graph' 'execution: graph' 'pipeline:' '  stages:' '    - id: a' '      runtime: cursor' '      agent: research' '---' > "$FIX/mygraph.plan.md"
  printf '{}' > "$FIX/mygraph.graph.json"
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

# Graph routing tests

@test "execution: graph routes to graph-run.sh even with pipeline block" {
  run run_ralph run --plan "$FIX/mygraph.plan.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RAN graph-run.sh"* ]]
  [[ "$output" != *"RAN orchestrator.sh"* ]]
}

@test "execution: graph with pipeline block does not route to orchestrator.sh" {
  run run_ralph run --plan "$FIX/mygraph.plan.md"
  [ "$status" -eq 0 ]
  [[ "$output" != *"RAN orchestrator.sh"* ]]
}

@test ".graph.json routes to graph-run.sh" {
  run run_ralph run --plan "$FIX/mygraph.graph.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RAN graph-run.sh"* ]]
}

@test ".orch.json still routes to orchestrator.sh" {
  run run_ralph run --plan "$FIX/legacy.orch.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RAN orchestrator.sh"* ]]
  [[ "$output" != *"RAN graph-run.sh"* ]]
}

@test "execution: orchestration still routes to orchestrator.sh" {
  run run_ralph run --plan "$FIX/execonly.plan.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RAN orchestrator.sh"* ]]
}

@test "bare pipeline block still routes to orchestrator.sh" {
  run run_ralph run --plan "$FIX/orc.plan.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RAN orchestrator.sh"* ]]
}

@test "pipeline block with no execution field routes to orchestrator not graph-run" {
  # Guarantees no auto-upgrade: omitting execution: must never silently select graph mode.
  run run_ralph run --plan "$FIX/bare-pipeline.plan.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RAN orchestrator.sh"* ]]
  [[ "$output" != *"RAN graph-run.sh"* ]]
}

@test "execution: standard still routes to run-plan.sh" {
  run run_ralph run --plan "$FIX/flat.plan.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RAN run-plan.sh"* ]]
}

# Graph subcommand verb dispatch tests

@test "ralph graph compile dispatches to graph-run.sh" {
  run run_ralph graph compile "$FIX/mygraph.plan.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RAN graph-run.sh"* ]]
}

@test "ralph graph run dispatches to graph-run.sh" {
  run run_ralph graph run "$FIX/mygraph.plan.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RAN graph-run.sh"* ]]
}

@test "ralph graph resume dispatches to graph-run.sh" {
  run run_ralph graph resume "$FIX/mygraph.plan.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RAN graph-run.sh"* ]]
}

@test "ralph graph status dispatches to graph-run.sh" {
  run run_ralph graph status
  [ "$status" -eq 0 ]
  [[ "$output" == *"RAN graph-run.sh"* ]]
}

@test "ralph graph render dispatches to graph-run.sh" {
  run run_ralph graph render
  [ "$status" -eq 0 ]
  [[ "$output" == *"RAN graph-run.sh"* ]]
}
