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

  # The shim sources the shared help renderer from its install root before it
  # dispatches, so the fake RALPH_HOME must carry the real library.
  mkdir -p "$RH/bundle/.ralph/bash-lib"
  cp "$REPO_ROOT/bundle/.ralph/bash-lib/help-render.sh" "$RH/bundle/.ralph/bash-lib/help-render.sh"

  # Extract the embedded SHIM heredoc from install.sh into a runnable script.
  SHIM="$RH/ralph"
  awk "/cat > \"\\\$tmp\" <<'SHIM'/{f=1;next} /^SHIM\$/{f=0} f" "$REPO_ROOT/install.sh" > "$SHIM"
  chmod +x "$SHIM"

  FIX="$(mktemp -d)"
  printf '# Plan\n\n- [ ] do a thing\n' > "$FIX/classic.md"
  printf '%s\n' '---' 'name: Flat' 'execution: standard' '' 'todos:' '  - id: t1' '    content: x' '    status: pending' '---' > "$FIX/flat.plan.md"
  printf '%s\n' '---' 'name: Orc' 'execution: orchestration' 'pipeline:' '  stages:' '    - id: a' '      runtime: cursor' '---' > "$FIX/orc.plan.md"
  printf '%s\n' '---' 'name: O2' 'execution: orchestration' '---' > "$FIX/execonly.plan.md"
  printf '{}' > "$FIX/legacy.orch.json"
  # A plan with a pipeline: block but NO execution: field -- must route to orchestrator,
  # not graph-run.sh. This is the "bare pipeline block" guarantee: no auto-upgrade to graph.
  printf '%s\n' '---' 'name: BareP' 'pipeline:' '  stages:' '    - id: a' '      runtime: cursor' '---' > "$FIX/bare-pipeline.plan.md"
  # Graph fixtures
  printf '%s\n' '---' 'name: Graph' 'execution: graph' 'pipeline:' '  stages:' '    - id: a' '      runtime: cursor' '---' > "$FIX/mygraph.plan.md"
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




@test "ralph run --orc is no longer recognized" {
  run run_ralph run --orc "$FIX/legacy.orch.json"
  [ "$status" -ne 0 ]
}

@test "ralph run with no --plan errors" {
  run run_ralph run
  [ "$status" -ne 0 ]
}

# Graph routing tests








@test "execution: standard still routes to run-plan.sh" {
  run run_ralph run --plan "$FIX/flat.plan.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RAN run-plan.sh"* ]]
}

# Graph subcommand verb dispatch tests






# --- removed routes ---------------------------------------------------------
#
# Leaf routing above is what `ralph run --plan` still does. Everything else that
# used to dispatch from here is now refused at the boundary. The exact refusal
# text is asserted once in tests/bats/cli/public-command-contract.bats; these
# cases only prove the dispatcher never reaches an engine.

@test "non-leaf plan sources are refused instead of dispatching to an engine" {
  local fixture
  for fixture in orc.plan.md execonly.plan.md bare-pipeline.plan.md mygraph.plan.md \
    legacy.orch.json mygraph.graph.json; do
    run run_ralph run --plan "$FIX/$fixture"
    [ "$status" -eq 2 ]
    [[ "$output" == *"leaf plans only"* ]]
    [[ "$output" != *"RAN orchestrator.sh"* ]]
    [[ "$output" != *"RAN graph-run.sh"* ]]
    [[ "$output" != *"RAN run-plan.sh"* ]]
  done
}

@test "ralph graph is refused as a removed public route" {
  local verb
  for verb in compile run resume status render; do
    run run_ralph graph "$verb"
    [ "$status" -eq 2 ]
    [[ "$output" == *"'ralph graph' was removed"* ]]
    [[ "$output" != *"RAN graph-run.sh"* ]]
  done
}
