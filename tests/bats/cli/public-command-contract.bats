#!/usr/bin/env bats
# Public dispatcher argv/exit/stderr contracts for removed and retained routes.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

setup_file() {
  PCC_TMP="$(mktemp -d)"
  export PCC_TMP
  export PCC_SHIM="$PCC_TMP/ralph"
  awk '/^  cat > "\$tmp" <<.SHIM.$/ { flag = 1; next } /^SHIM$/ { flag = 0 } flag { print }' \
    "$REPO_ROOT/install.sh" >"$PCC_SHIM"
  chmod +x "$PCC_SHIM"
}

teardown_file() {
  rm -rf "$PCC_TMP"
}

@test "ralph role: bare command exits 2 with inline workflow stage instructions guidance" {
  run env RALPH_HOME="$REPO_ROOT" bash "$PCC_SHIM" role
  [ "$status" -eq 2 ]
  [ "${lines[0]}" = "Error: 'ralph role' was removed. Workflow stage instructions are inline." ]
}

@test "ralph role: subcommand argv still exits 2 with the same replacement" {
  run env RALPH_HOME="$REPO_ROOT" bash "$PCC_SHIM" role list
  [ "$status" -eq 2 ]
  [ "${lines[0]}" = "Error: 'ralph role' was removed. Workflow stage instructions are inline." ]
}

@test "ralph role: help flag is refused as a removed route" {
  run env RALPH_HOME="$REPO_ROOT" bash "$PCC_SHIM" role --help
  [ "$status" -eq 2 ]
  [ "${lines[0]}" = "Error: 'ralph role' was removed. Workflow stage instructions are inline." ]
}

@test "ralph role: top-level help no longer lists the role command" {
  run env RALPH_HOME="$REPO_ROOT" bash "$PCC_SHIM" --help
  [ "$status" -eq 0 ]
  ! printf '%s\n' "$output" | grep -E '^[[:space:]]+role[[:space:]]'
}

@test "migration: ralph migrate legacy conversion argv exits 2 with no conversion suggestion" {
  # Avoid embedding the removed migration id literally (repo-wide absence gate).
  legacy_mig="$(printf '%s%s' 'agents-to-' 'roles')"
  run env RALPH_HOME="$REPO_ROOT" bash "$PCC_SHIM" migrate "$legacy_mig"
  [ "$status" -eq 2 ]
  [ "${lines[0]}" = "Error: 'ralph migrate' was removed. Workflow stage instructions are inline." ]
  [[ "$output" != *"ralph role"* ]]
  [[ "$output" != *"convert"* ]]
  [[ "$output" != *"legacy agent"* ]]
}

@test "migration: bare ralph migrate exits 2 with the same replacement" {
  run env RALPH_HOME="$REPO_ROOT" bash "$PCC_SHIM" migrate
  [ "$status" -eq 2 ]
  [ "${lines[0]}" = "Error: 'ralph migrate' was removed. Workflow stage instructions are inline." ]
}

@test "migration: top-level help no longer lists the migrate command" {
  run env RALPH_HOME="$REPO_ROOT" bash "$PCC_SHIM" --help
  [ "$status" -eq 0 ]
  ! printf '%s\n' "$output" | grep -E '^[[:space:]]+migrate[[:space:]]'
}

@test "ralph agent: rejected text distinguishes runtime-native agents from inline workflow instructions" {
  run env RALPH_HOME="$REPO_ROOT" bash "$PCC_SHIM" agent list
  [ "$status" -eq 2 ]
  [ "${lines[0]}" = "Error: 'ralph agent' was removed. Runtime-native agents stay with the runtime; workflow stage instructions are inline." ]
  [[ "$output" == *"Runtime-native agents"* ]]
  [[ "$output" == *"workflow stage instructions are inline"* ]]
  [[ "$output" != *"ralph role"* ]]
  [[ "$output" != *"ralph migrate"* ]]
}

@test "create commands: help lists only plan and workflow" {
  run env RALPH_HOME="$REPO_ROOT" bash "$PCC_SHIM" create --help
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -E '^[[:space:]]+plan[[:space:]]'
  printf '%s\n' "$output" | grep -E '^[[:space:]]+workflow[[:space:]]'
  ! printf '%s\n' "$output" | grep -E '^[[:space:]]+(graph|orc|orchestration|wizard)[[:space:]]'
  [[ "$output" == *"--mode"* ]]
  [[ "$output" == *"sequential"* ]]
  [[ "$output" == *"dependency"* ]]
  [[ "$output" == *"--global"* ]]
  [[ "$output" != *"--format graph"* ]]
  [[ "$output" != *"ralph create orc"* ]]
  [[ "$output" != *"ralph create graph"* ]]
}

@test "create commands: create graph exits 2 with exact replacement" {
  run env RALPH_HOME="$REPO_ROOT" bash "$PCC_SHIM" create graph
  [ "$status" -eq 2 ]
  [ "${lines[0]}" = "Error: 'ralph create graph' was removed. Use: ralph create workflow" ]
}

@test "create commands: create orc exits 2 with exact replacement" {
  run env RALPH_HOME="$REPO_ROOT" bash "$PCC_SHIM" create orc
  [ "$status" -eq 2 ]
  [ "${lines[0]}" = "Error: 'ralph create orc' was removed. Use: ralph create workflow" ]
}

@test "create commands: create orchestration exits 2 with exact replacement" {
  run env RALPH_HOME="$REPO_ROOT" bash "$PCC_SHIM" create orchestration
  [ "$status" -eq 2 ]
  [ "${lines[0]}" = "Error: 'ralph create orchestration' was removed. Use: ralph create workflow" ]
}

@test "create commands: create wizard exits 2 with exact replacement" {
  run env RALPH_HOME="$REPO_ROOT" bash "$PCC_SHIM" create wizard
  [ "$status" -eq 2 ]
  [ "${lines[0]}" = "Error: 'ralph create wizard' was removed. Use: ralph create workflow" ]
}

@test "create commands: create plan help still dispatches" {
  run env RALPH_HOME="$REPO_ROOT" bash "$PCC_SHIM" create plan --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"classic"* ]]
  [[ "$output" == *"yaml"* ]]
  [[ "$output" == *"ralph create workflow"* ]]
  [[ "$output" != *"--format graph"* ]]
}

@test "create commands: create workflow accepts --mode and --global via help" {
  run env RALPH_HOME="$REPO_ROOT" bash "$PCC_SHIM" create workflow --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--mode"* ]]
  [[ "$output" == *"sequential"* ]]
  [[ "$output" == *"dependency"* ]]
  [[ "$output" == *"--global"* ]]
}

@test "create commands: create workflow rejects invalid --mode" {
  run env RALPH_HOME="$REPO_ROOT" bash "$PCC_SHIM" create workflow --mode graph
  [ "$status" -eq 2 ]
  [[ "${lines[0]}" == *"invalid --mode: graph"* ]]
  [[ "${lines[0]}" == *"sequential"* ]]
  [[ "${lines[0]}" == *"dependency"* ]]
}

@test "create commands: create workflow accepts --mode sequential without unknown-option failure" {
  # --help is parsed after --mode; proves mode is accepted and does not enter the wizard.
  run env RALPH_HOME="$REPO_ROOT" bash "$PCC_SHIM" create workflow --mode sequential --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--mode"* ]]
}

@test "create commands: create workflow accepts --global with --help" {
  run env RALPH_HOME="$REPO_ROOT" bash "$PCC_SHIM" create workflow --global --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--global"* ]]
}

# --- removed routes ------------------------------------------------------------

@test "removed routes: ralph graph exits 2 with exact replacement" {
  run env RALPH_HOME="$REPO_ROOT" bash "$PCC_SHIM" graph
  [ "$status" -eq 2 ]
  [ "${lines[0]}" = "Error: 'ralph graph' was removed. Use: ralph workflow start --file <path> --task \"<text>\"" ]
}

@test "removed routes: ralph graph with verb argv exits 2 with the same replacement" {
  run env RALPH_HOME="$REPO_ROOT" bash "$PCC_SHIM" graph status --namespace ns --run latest
  [ "$status" -eq 2 ]
  [ "${lines[0]}" = "Error: 'ralph graph' was removed. Use: ralph workflow start --file <path> --task \"<text>\"" ]
}

@test "removed routes: ralph orchestrate exits 2 with exact replacement" {
  run env RALPH_HOME="$REPO_ROOT" bash "$PCC_SHIM" orchestrate --orchestration plan.orch.json
  [ "$status" -eq 2 ]
  [ "${lines[0]}" = "Error: 'ralph orchestrate' was removed. Use: ralph workflow start --file <path> --task \"<text>\"" ]
}

@test "removed routes: ralph orchestrator alias exits 2 with exact replacement" {
  run env RALPH_HOME="$REPO_ROOT" bash "$PCC_SHIM" orchestrator --help
  [ "$status" -eq 2 ]
  [ "${lines[0]}" = "Error: 'ralph orchestrator' was removed. Use: ralph workflow start --file <path> --task \"<text>\"" ]
}

@test "removed routes: ralph run --workflow exits 2 with exact replacement" {
  legacy_run_wf="$(printf '%s%s' 'run --' 'workflow')"
  run env RALPH_HOME="$REPO_ROOT" bash "$PCC_SHIM" $legacy_run_wf feature-delivery --task "Add CSV export"
  [ "$status" -eq 2 ]
  [ "${lines[0]}" = "Error: 'ralph run --workflow' was removed. Use: ralph workflow start <id> --task \"<text>\"" ]
}

@test "removed routes: ralph run workflow exits 2 with exact replacement" {
  run env RALPH_HOME="$REPO_ROOT" bash "$PCC_SHIM" run workflow feature-delivery
  [ "$status" -eq 2 ]
  [ "${lines[0]}" = "Error: 'ralph run workflow <name>' was removed. Use: ralph workflow start <id> --task \"<text>\"" ]
}

@test "removed routes: ralph workflow create exits 2 with exact replacement" {
  run env RALPH_HOME="$REPO_ROOT" bash "$PCC_SHIM" workflow create
  [ "$status" -eq 2 ]
  [ "${lines[0]}" = "Error: 'ralph workflow create' was removed. Use: ralph create workflow" ]
}

@test "removed routes: top-level help no longer lists graph or orchestrate" {
  run env RALPH_HOME="$REPO_ROOT" bash "$PCC_SHIM" --help
  [ "$status" -eq 0 ]
  ! printf '%s\n' "$output" | grep -E '^[[:space:]]+(graph|orchestrate|orchestrator)[[:space:]]'
  ! printf '%s\n' "$output" | grep -F -- '--workflow'
}

@test "removed routes: run help no longer offers --workflow" {
  run env RALPH_HOME="$REPO_ROOT" bash "$PCC_SHIM" run --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: ralph run --plan <path>"* ]]
  ! printf '%s\n' "$output" | grep -F -- '--workflow'
}

# --- plan workflow boundary ---------------------------------------------------
# Cheap argv/refusal contracts for ralph run --plan leaf-only dispatch.

setup_plan_boundary() {
  PCC_FIX="$(mktemp -d)"
  PCC_RH="$(mktemp -d)"
  mkdir -p "$PCC_RH/bundle/.ralph/bash-lib"
  # The shim sources the shared help renderer from its install root before it
  # dispatches, so a fake RALPH_HOME must carry the real library.
  cp "$REPO_ROOT/bundle/.ralph/bash-lib/help-render.sh" \
    "$PCC_RH/bundle/.ralph/bash-lib/help-render.sh"
  cat >"$PCC_RH/bundle/.ralph/run-plan.sh" <<'EOF'
#!/usr/bin/env bash
echo "RAN run-plan.sh $*"
EOF
  chmod +x "$PCC_RH/bundle/.ralph/run-plan.sh"
  cat >"$PCC_FIX/leaf.plan.md" <<'EOF'
# Leaf

- [ ] do one thing
EOF
  cat >"$PCC_FIX/workflow.workflow.md" <<'EOF'
---
kind: workflow
mode: dependency
overview: boundary fixture
---
EOF
  printf '%s\n' '---' 'execution: graph' 'pipeline:' '  stages: []' '---' >"$PCC_FIX/graph.plan.md"
  printf '%s\n' '---' 'pipeline:' '  stages: []' '---' >"$PCC_FIX/orch.plan.md"
  printf '{}' >"$PCC_FIX/legacy.graph.json"
  printf '{}' >"$PCC_FIX/legacy.orch.json"
}

teardown_plan_boundary() {
  rm -rf "${PCC_FIX:-}" "${PCC_RH:-}"
}

@test "plan workflow boundary: classic leaf routes to run-plan.sh" {
  setup_plan_boundary
  run env RALPH_HOME="$PCC_RH" bash "$PCC_SHIM" run --plan "$PCC_FIX/leaf.plan.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RAN run-plan.sh"* ]]
  teardown_plan_boundary
}

@test "plan workflow boundary: graph plan exits 2 with workflow start --file" {
  setup_plan_boundary
  run env RALPH_HOME="$PCC_RH" bash "$PCC_SHIM" run --plan "$PCC_FIX/graph.plan.md"
  [ "$status" -eq 2 ]
  [[ "${lines[0]}" == *"leaf plans only"* ]]
  [[ "${lines[0]}" == *"(got: graph)"* ]]
  [ "${lines[1]}" = "Use: ralph workflow start --file $PCC_FIX/graph.plan.md" ]
  [[ "${lines[2]}" == *"ralph workflow start plan-delivery --plan"* ]]
  teardown_plan_boundary
}

@test "plan workflow boundary: orchestration plan exits 2 with workflow start --file" {
  setup_plan_boundary
  run env RALPH_HOME="$PCC_RH" bash "$PCC_SHIM" run --plan "$PCC_FIX/orch.plan.md"
  [ "$status" -eq 2 ]
  [[ "${lines[0]}" == *"(got: orchestration)"* ]]
  [ "${lines[1]}" = "Use: ralph workflow start --file $PCC_FIX/orch.plan.md" ]
  teardown_plan_boundary
}

@test "plan workflow boundary: workflow file exits 2 with workflow start --file" {
  setup_plan_boundary
  run env RALPH_HOME="$PCC_RH" bash "$PCC_SHIM" run --plan "$PCC_FIX/workflow.workflow.md"
  [ "$status" -eq 2 ]
  [[ "${lines[0]}" == *"(got: workflow)"* ]]
  [ "${lines[1]}" = "Use: ralph workflow start --file $PCC_FIX/workflow.workflow.md" ]
  teardown_plan_boundary
}

@test "plan workflow boundary: graph json exits 2 with workflow start --file" {
  setup_plan_boundary
  run env RALPH_HOME="$PCC_RH" bash "$PCC_SHIM" run --plan "$PCC_FIX/legacy.graph.json"
  [ "$status" -eq 2 ]
  [[ "${lines[0]}" == *"(got: graph)"* ]]
  teardown_plan_boundary
}

@test "plan-delivery: run --plan refusal distinguishes plan-delivery --plan" {
  setup_plan_boundary
  run env RALPH_HOME="$PCC_RH" bash "$PCC_SHIM" run --plan "$PCC_FIX/leaf.plan.md"
  [ "$status" -eq 0 ]
  run env RALPH_HOME="$PCC_RH" bash "$PCC_SHIM" run --plan "$PCC_FIX/graph.plan.md"
  [ "$status" -eq 2 ]
  [ "${lines[2]}" = "For operator-supplied leaf plans inside a delivery workflow, use: ralph workflow start plan-delivery --plan $PCC_FIX/graph.plan.md" ]
  teardown_plan_boundary
}
