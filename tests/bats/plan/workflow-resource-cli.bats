#!/usr/bin/env bats

# Public workflow resource CLI: list/show/path/edit/start over the resolver,
# plus retained list-plans and removed-starter rejection coverage.
# Script entry point (argv/stdout/stderr/exit contracts). Contracts:
# agents/rules/test-design.md, agents/rules/testing-workflow.md, and
# .ralph-workspace/artifacts/ralph-first-class-workflows/contracts.md
# (List / show / path / edit).

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

setup() {
  unset RALPH_PROJECT_ROOT RALPH_PLAN_WORKSPACE_ROOT RALPH_AGENT_WORKSPACE
  WRC_TMP="$(mktemp -d)"
  # Physical paths so absolute path assertions match resolver pwd -P roots.
  WRC_TMP="$(cd "$WRC_TMP" && pwd -P)"
  WRC_HOME="$WRC_TMP/home"
  WRC_WORKSPACE="$WRC_TMP/workspace"
  WRC_SHIM="$WRC_TMP/ralph"
  mkdir -p \
    "$WRC_HOME/bundle/.ralph" \
    "$WRC_HOME/workflows" \
    "$WRC_WORKSPACE/.ralph-workspace/workflows" \
    "$WRC_HOME/bundle/.ralph/workflows"
  cp -R "$REPO_ROOT/bundle/.ralph/." "$WRC_HOME/bundle/.ralph/"
  # Ensure canonical bundled dir exists even when install assets still ship
  # templates elsewhere (moved in a later TODO).
  mkdir -p "$WRC_HOME/bundle/.ralph/workflows"
  awk '/^  cat > "\$tmp" <<.SHIM.$/ { flag = 1; next } /^SHIM$/ { flag = 0 } flag { print }' \
    "$REPO_ROOT/install.sh" >"$WRC_SHIM"
  chmod +x "$WRC_SHIM"
}

teardown() { rm -rf "$WRC_TMP"; }

write_wf() {
  local path="$1"
  local overview="${2:-overview text}"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' '---' 'kind: workflow' "overview: $overview" 'mode: dependency' '---' \
    '# body' "marker-$(basename "$path")" >"$path"
}

ralph_wf() {
  (cd "$WRC_WORKSPACE" && env -u RALPH_PROJECT_ROOT -u RALPH_PLAN_WORKSPACE_ROOT \
    RALPH_HOME="$WRC_HOME" bash "$WRC_SHIM" workflow "$@")
}

@test "list --tsv is sorted id kind overview with winning scope" {
  write_wf "$WRC_HOME/bundle/.ralph/workflows/zeta.workflow.md" "bundled zeta"
  write_wf "$WRC_HOME/workflows/alpha.workflow.md" "global alpha"
  write_wf "$WRC_WORKSPACE/.ralph-workspace/workflows/alpha.workflow.md" "project alpha"
  write_wf "$WRC_HOME/bundle/.ralph/workflows/beta.workflow.md" "bundled beta"

  run ralph_wf list --tsv
  [ "$status" -eq 0 ]
  # Project alpha wins over global alpha, and each id appears exactly once.
  [ "$(printf '%s\n' "$output" | grep -c $'^alpha\t')" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep $'^alpha\t')" = $'alpha\tproject\tproject alpha' ]
  [ "$(printf '%s\n' "$output" | grep $'^beta\t')" = $'beta\tbundled\tbundled beta' ]
  [ "$(printf '%s\n' "$output" | grep $'^zeta\t')" = $'zeta\tbundled\tbundled zeta' ]
  # Sorted by id across every scope, bundled workflows included.
  [ "$(printf '%s\n' "$output" | cut -f1)" = "$(printf '%s\n' "$output" | cut -f1 | sort)" ]
}

@test "list default renders an aligned table with a header row and invocation examples" {
  write_wf "$WRC_HOME/bundle/.ralph/workflows/zeta.workflow.md" "bundled zeta"
  write_wf "$WRC_WORKSPACE/.ralph-workspace/workflows/alpha.workflow.md" "project alpha"

  run ralph_wf list
  [ "$status" -eq 0 ]
  [[ "$output" == *"ID"*"SCOPE"*"MODE"*"OVERVIEW"* ]]
  [[ "$output" == *"alpha"*"project"*"project alpha"* ]]
  [[ "$output" == *"zeta"*"bundled"*"bundled zeta"* ]]
  [[ "$output" == *"Examples"* ]]
  [[ "$output" == *"ralph workflow start <id> --task"* ]]
  [[ "$output" != *$'alpha\tproject\t'* ]]
}

@test "list workflows old route exits 2 with ralph workflow list" {
  run bash -c "cd '$WRC_WORKSPACE' && env -u RALPH_PROJECT_ROOT -u RALPH_PLAN_WORKSPACE_ROOT RALPH_HOME='$WRC_HOME' bash '$WRC_SHIM' list workflows"
  [ "$status" -eq 2 ]
  [ "${lines[0]}" = "Use: ralph workflow list" ]
}

@test "show is byte-exact for the winning workflow" {
  write_wf "$WRC_HOME/workflows/demo.workflow.md" "global demo"
  write_wf "$WRC_WORKSPACE/.ralph-workspace/workflows/demo.workflow.md" "project demo"
  local expected
  expected="$(cat "$WRC_WORKSPACE/.ralph-workspace/workflows/demo.workflow.md")"

  run ralph_wf show demo
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

@test "path prints one absolute path for the winning workflow" {
  write_wf "$WRC_WORKSPACE/.ralph-workspace/workflows/demo.workflow.md" "project demo"

  run ralph_wf path demo
  [ "$status" -eq 0 ]
  [ "$output" = "$WRC_WORKSPACE/.ralph-workspace/workflows/demo.workflow.md" ]
  [[ "$output" == /* ]]
}

@test "show and path honor explicit scope without fallthrough" {
  write_wf "$WRC_HOME/bundle/.ralph/workflows/shared.workflow.md" "bundled"
  write_wf "$WRC_HOME/workflows/shared.workflow.md" "global"
  write_wf "$WRC_WORKSPACE/.ralph-workspace/workflows/shared.workflow.md" "project"

  run ralph_wf path shared --global
  [ "$status" -eq 0 ]
  [ "$output" = "$WRC_HOME/workflows/shared.workflow.md" ]

  run ralph_wf show shared --bundled
  [ "$status" -eq 0 ]
  [[ "$output" == *"overview: bundled"* ]]

  run ralph_wf path missing --project
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found in project"* ]]
}

@test "verbose diagnostics go to stderr only for show and path" {
  write_wf "$WRC_WORKSPACE/.ralph-workspace/workflows/demo.workflow.md" "project demo"
  local expected stdout_file stderr_file
  expected="$(cat "$WRC_WORKSPACE/.ralph-workspace/workflows/demo.workflow.md")"
  stdout_file="$WRC_TMP/show-out.txt"
  stderr_file="$WRC_TMP/show-err.txt"

  run bash -c "cd '$WRC_WORKSPACE' && env -u RALPH_PROJECT_ROOT -u RALPH_PLAN_WORKSPACE_ROOT RALPH_HOME='$WRC_HOME' bash '$WRC_SHIM' workflow show demo --verbose >'$stdout_file' 2>'$stderr_file'"
  [ "$status" -eq 0 ]
  [ "$(cat "$stdout_file")" = "$expected" ]
  [[ "$(cat "$stderr_file")" == *"resolved scope: project"* ]]
  [[ "$(cat "$stderr_file")" == *"resolved path:"* ]]

  stdout_file="$WRC_TMP/path-out.txt"
  stderr_file="$WRC_TMP/path-err.txt"
  run bash -c "cd '$WRC_WORKSPACE' && env -u RALPH_PROJECT_ROOT -u RALPH_PLAN_WORKSPACE_ROOT RALPH_HOME='$WRC_HOME' bash '$WRC_SHIM' workflow path demo --verbose >'$stdout_file' 2>'$stderr_file'"
  [ "$status" -eq 0 ]
  [ "$(cat "$stdout_file")" = "$WRC_WORKSPACE/.ralph-workspace/workflows/demo.workflow.md" ]
  [[ "$(cat "$stderr_file")" == *"resolved scope: project"* ]]
}

@test "invalid id and duplicate scopes are rejected before filesystem access" {
  # No workflow dirs on a fresh empty home: invalid id must still exit 2.
  rm -rf "$WRC_WORKSPACE/.ralph-workspace" "$WRC_HOME/workflows" "$WRC_HOME/bundle/.ralph/workflows"

  run ralph_wf show 'Bad_ID'
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid workflow id"* ]]

  run ralph_wf path 'also_bad'
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid workflow id"* ]]

  run ralph_wf show ok-id --project --global
  [ "$status" -eq 2 ]
  [[ "$output" == *"use only one of --project, --global, --bundled"* ]]
}

@test "removed starter exits 2 with start and edit replacements" {
  # Public create --starter was the clone surface; keep CLI rejection only here.
  run bash -c "cd '$WRC_WORKSPACE' && RALPH_HOME='$WRC_HOME' bash '$WRC_SHIM' create workflow --starter investigation --name repo-research --overview 'Repository research'"
  [ "$status" -eq 2 ]
  [ "${lines[0]}" = "Use: ralph workflow start <id>" ]
  [ "${lines[1]}" = "Use: ralph workflow edit <id>" ]
  [ ! -e "$WRC_WORKSPACE/.ralph-workspace/workflows/repo-research.workflow.md" ]

  run bash -c "cd '$WRC_WORKSPACE' && RALPH_HOME='$WRC_HOME' bash '$WRC_SHIM' create workflow --starter no-such --name other"
  [ "$status" -eq 2 ]
  [ "${lines[0]}" = "Use: ralph workflow start <id>" ]
  [ "${lines[1]}" = "Use: ralph workflow edit <id>" ]
}

@test "list plans only reports managed plan storage and classifies plans by public mode name" {
  mkdir -p "$WRC_WORKSPACE/.ralph-workspace/plans/nested"
  printf '%s\n' '- [ ] Standard' >"$WRC_WORKSPACE/.ralph-workspace/plans/nested/standard.md"
  printf '%s\n' '---' 'execution: graph' '---' >"$WRC_WORKSPACE/.ralph-workspace/plans/graph.plan.md"
  printf '%s\n' '---' 'pipeline:' '  stages: []' '---' >"$WRC_WORKSPACE/.ralph-workspace/plans/old.plan.md"
  printf '%s\n' '- [ ] Outside' >"$WRC_WORKSPACE/outside.md"
  run bash -c "cd '$WRC_WORKSPACE' && RALPH_HOME='$WRC_HOME' bash '$WRC_SHIM' list plans"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Dependency plans"* && "$output" == *"graph.plan.md"* ]]
  [[ "$output" == *"Standard plans"* && "$output" == *"nested/standard.md"* ]]
  [[ "$output" == *"Sequential plans"* && "$output" == *"old.plan.md"* ]]
  [[ "$output" != *"outside.md"* ]]
}

@test "list plans finds nested child workspaces without --global and only the registry with it" {
  mkdir -p "$WRC_WORKSPACE/.ralph-workspace/plans"
  printf '%s\n' '- [ ] Root' >"$WRC_WORKSPACE/.ralph-workspace/plans/root.md"
  mkdir -p "$WRC_WORKSPACE/pkg/child/.ralph-workspace/plans"
  printf '%s\n' '- [ ] Child' >"$WRC_WORKSPACE/pkg/child/.ralph-workspace/plans/child.md"

  run bash -c "cd '$WRC_WORKSPACE' && RALPH_HOME='$WRC_HOME' bash '$WRC_SHIM' list plans"
  [ "$status" -eq 0 ]
  [[ "$output" == *"root.md"* ]]
  [[ "$output" == *"child.md"* ]]

  local elsewhere="$WRC_TMP/elsewhere" global_home="$WRC_TMP/globalhome"
  mkdir -p "$elsewhere" "$global_home"
  local registry="$WRC_TMP/workspaces.json"
  printf '[{"path": "%s"}]\n' "$WRC_WORKSPACE" >"$registry"

  # HOME is sandboxed here (separate from RALPH_HOME) so --global's home scan
  # only sees this fixture, not the real machine's workspaces.
  run bash -c "cd '$elsewhere' && HOME='$global_home' RALPH_HOME='$WRC_HOME' RALPH_WORKSPACES_FILE='$registry' bash '$WRC_SHIM' list plans"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No .ralph-workspace found here"* ]]

  run bash -c "cd '$elsewhere' && HOME='$global_home' RALPH_HOME='$WRC_HOME' RALPH_WORKSPACES_FILE='$registry' bash '$WRC_SHIM' list plans --global"
  [ "$status" -eq 0 ]
  [[ "$output" == *"root.md"* ]]
}

@test "run rejects positional workflow migration and incompatible selectors" {
  run bash -c "cd '$WRC_WORKSPACE' && RALPH_HOME='$WRC_HOME' bash '$WRC_SHIM' run workflow old --task x"
  [ "$status" -ne 0 ]
  [[ "$output" == *"'ralph run workflow <name>' was removed"* ]]
  [[ "$output" == *"Use: ralph workflow start <id> --task"* ]]

  # --workflow is gone entirely, so pairing it with --plan is refused as a
  # removed selector rather than as an incompatible combination.
  run bash -c "cd '$WRC_WORKSPACE' && RALPH_HOME='$WRC_HOME' bash '$WRC_SHIM' run --plan PLAN.md --workflow old --task x"
  [ "$status" -ne 0 ]
  [[ "$output" == *"'ralph run --workflow' was removed"* ]]
  [[ "$output" == *"Use: ralph workflow start <id> --task"* ]]
}

@test "public CLI help is colored only on a terminal and honors NO_COLOR" {
  run env -u NO_COLOR RALPH_HOME="$WRC_HOME" \
    "$REPO_ROOT/tests/bats/bin/ralph-pty-exec" bash "$WRC_SHIM" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\033['* ]]
  [[ "$output" == *"Commands:"* && "$output" == *"Options:"* ]]

  run env NO_COLOR=1 RALPH_HOME="$WRC_HOME" bash "$WRC_SHIM" --help
  [ "$status" -eq 0 ]
  [[ "$output" != *$'\033['* ]]
}

# --- start parser / entry / dry dispatch tuple ----------------------------

write_required_plan_input_wf() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat >"$path" <<'EOF'
---
name: plan-input-required
kind: workflow
mode: dependency
planInput:
  stage: implement
  required: true
pipeline:
  stages:
    - id: implement
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md
          required: true
    - id: review
      dependsOn:
        - implement
todos:
  - id: review-work
    stage: review
    content: |
      Review result for:
      {{TASK}}
    status: pending
---
EOF
}

write_optional_plan_input_wf() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat >"$path" <<'EOF'
---
name: plan-input-optional
kind: workflow
mode: dependency
planInput:
  stage: implement
pipeline:
  stages:
    - id: plan-implementation
      planner:
        outputMode: plan-file
        maxTodos: 40
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/impl-plan.json
          schema: bundle/.ralph/schemas/planner-output.schema.json
          required: true
    - id: implement
      planFrom: plan-implementation
      dependsOn:
        - plan-implementation
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md
          required: true
todos:
  - id: plan-work
    stage: plan-implementation
    content: |
      Plan work for:
      {{TASK}}
    status: pending
---
EOF
}

write_leaf_yaml_plan() {
  local path="$1"
  local overview="${2:-}"
  mkdir -p "$(dirname "$path")"
  {
    printf '%s\n' '---' 'name: leaf-plan'
    if [[ -n "$overview" ]]; then
      printf 'overview: %s\n' "$overview"
    fi
    printf '%s\n' 'todos:' \
      '  - id: one' \
      '    content: Do the thing' \
      '    verification: true' \
      '    status: pending' \
      '---'
  } >"$path"
}

write_leaf_classic_plan() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' '# classic' '- [ ] Do classic work' >"$path"
}

ralph_wf_start_dry() {
  (cd "$WRC_WORKSPACE" && env -u RALPH_PROJECT_ROOT -u RALPH_PLAN_WORKSPACE_ROOT \
    RALPH_HOME="$WRC_HOME" RALPH_WORKFLOW_START_DRY=1 \
    bash "$WRC_SHIM" workflow start "$@")
}

@test "start parser help documents task plan and file forms" {
  run ralph_wf start --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"ralph workflow start <id> --task"* ]]
  [[ "$output" == *"--plan"* && "$output" == *"--file"* ]]
  [[ "$output" == *"Engine-only"* ]]
}

@test "start parser rejects engine-only flags with exit 2" {
  run ralph_wf start demo --task "x" --namespace ns
  [ "$status" -eq 2 ]
  [[ "$output" == *"engine-only"* && "$output" == *"--namespace"* ]]

  run ralph_wf start demo --task "x" --single-stage impl
  [ "$status" -eq 2 ]
  [[ "$output" == *"engine-only"* ]]

  run ralph_wf start demo --task "x" --tui
  [ "$status" -eq 2 ]
  [[ "$output" == *"engine-only"* ]]
}

@test "start parser rejects duplicates and missing flag values" {
  run ralph_wf start demo --task "a" --task "b"
  [ "$status" -eq 2 ]
  [[ "$output" == *"duplicate --task"* ]]

  run ralph_wf start demo --plan a.md --plan b.md
  [ "$status" -eq 2 ]
  [[ "$output" == *"duplicate --plan"* ]]

  run ralph_wf start --file a.workflow.md --file b.workflow.md --task x
  [ "$status" -eq 2 ]
  [[ "$output" == *"duplicate --file"* ]]

  run ralph_wf start demo --task
  [ "$status" -eq 2 ]
  [[ "$output" == *"--task requires a value"* ]]

  run ralph_wf start demo --runtime
  [ "$status" -eq 2 ]
  [[ "$output" == *"--runtime requires a value"* ]]

  run ralph_wf start demo --model
  [ "$status" -eq 2 ]
  [[ "$output" == *"--model requires a value"* ]]
}

@test "start parser rejects id with workflow file and requires task or plan" {
  run ralph_wf start demo --file "$WRC_WORKSPACE/x.workflow.md" --task "x"
  [ "$status" -eq 2 ]
  [[ "$output" == *"mutually exclusive"* ]]

  write_wf "$WRC_HOME/bundle/.ralph/workflows/demo.workflow.md" "bundled demo"
  # Minimal write_wf is not schema-valid; use investigation for semantic checks.
  run ralph_wf start investigation
  [ "$status" -eq 2 ]
  [[ "$output" == *"--task"* || "$output" == *"--plan"* ]]
}

@test "start with neither task nor plan rejects ordinary reusable workflow" {
  run ralph_wf_start_dry investigation
  [ "$status" -eq 2 ]
  [[ "$output" == *"--task"* ]]
}

@test "start task entry via id prints dry dispatch tuple" {
  run ralph_wf_start_dry investigation --task "Inspect auth"
  [ "$status" -eq 0 ]
  [ "$output" = $'task\texplicit\t-' ]
}

@test "direct start dry-dispatches a bundled workflow by id" {
  run ralph_wf_start_dry investigation --task "Repository research"
  [ "$status" -eq 0 ]
  [ "$output" = $'task\texplicit\t-' ]
}

@test "start accepts runtime and model flags on task entry" {
  run ralph_wf_start_dry investigation --task "ship it" --runtime cursor --model gpt-test
  [ "$status" -eq 0 ]
  [ "$output" = $'task\texplicit\t-' ]
}

@test "start workflow file form resolves and materializes dry tuple" {
  local wf="$WRC_WORKSPACE/custom.workflow.md"
  cp "$WRC_HOME/bundle/.ralph/workflows/investigation.workflow.md" "$wf"
  run ralph_wf_start_dry --file "$wf" --task "from file"
  [ "$status" -eq 0 ]
  [ "$output" = $'task\texplicit\t-' ]
}

@test "required planInput rejects task-only start" {
  write_required_plan_input_wf "$WRC_WORKSPACE/.ralph-workspace/workflows/plan-delivery.workflow.md"
  run ralph_wf_start_dry plan-delivery --task "only task"
  [ "$status" -eq 1 ]
  [[ "$output" == *"required planInput"* && "$output" == *"--plan"* ]]
}

@test "workflow without planInput rejects provided plan" {
  write_leaf_yaml_plan "$WRC_WORKSPACE/leaf.md" "Leaf overview"
  run ralph_wf_start_dry investigation --plan "$WRC_WORKSPACE/leaf.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"planInput"* && "$output" == *"--plan"* ]]
}

@test "provided plan entry derives task provenance from overview" {
  write_optional_plan_input_wf "$WRC_WORKSPACE/.ralph-workspace/workflows/opt-plan.workflow.md"
  write_leaf_yaml_plan "$WRC_WORKSPACE/leaf-overview.plan.md" "Ship the overview task"
  run ralph_wf_start_dry opt-plan --plan "$WRC_WORKSPACE/leaf-overview.plan.md"
  [ "$status" -eq 0 ]
  [[ "$output" == $'plan\tplan-overview\t'*leaf-overview.plan.md ]]
}

@test "task provenance uses explicit task over plan overview" {
  write_optional_plan_input_wf "$WRC_WORKSPACE/.ralph-workspace/workflows/opt-plan.workflow.md"
  write_leaf_yaml_plan "$WRC_WORKSPACE/leaf-overview.plan.md" "Ship the overview task"
  run ralph_wf_start_dry opt-plan --plan "$WRC_WORKSPACE/leaf-overview.plan.md" --task "Explicit wins"
  [ "$status" -eq 0 ]
  [[ "$output" == $'plan\texplicit\t'*leaf-overview.plan.md ]]
}

@test "task provenance falls back to plan filename for classic leaf" {
  write_optional_plan_input_wf "$WRC_WORKSPACE/.ralph-workspace/workflows/opt-plan.workflow.md"
  write_leaf_classic_plan "$WRC_WORKSPACE/classic-fix.plan.md"
  run ralph_wf_start_dry opt-plan --plan "$WRC_WORKSPACE/classic-fix.plan.md"
  [ "$status" -eq 0 ]
  [[ "$output" == $'plan\tplan-filename\t'*classic-fix.plan.md ]]
}

@test "unsupported plan shapes are rejected for --plan" {
  write_optional_plan_input_wf "$WRC_WORKSPACE/.ralph-workspace/workflows/opt-plan.workflow.md"
  cp "$WRC_HOME/bundle/.ralph/workflows/investigation.workflow.md" "$WRC_WORKSPACE/not-a-leaf.workflow.md"
  run ralph_wf_start_dry opt-plan --plan "$WRC_WORKSPACE/not-a-leaf.workflow.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unsupported plan"* && "$output" == *"workflow"* ]]

  printf '%s\n' '---' 'execution: graph' '---' '- [ ] x' >"$WRC_WORKSPACE/graphish.plan.md"
  run ralph_wf_start_dry opt-plan --plan "$WRC_WORKSPACE/graphish.plan.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unsupported plan"* && "$output" == *"graph"* ]]

  printf '%s\n' '---' 'pipeline:' '  stages: []' '---' >"$WRC_WORKSPACE/orchish.plan.md"
  run ralph_wf_start_dry opt-plan --plan "$WRC_WORKSPACE/orchish.plan.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unsupported plan"* && "$output" == *"orchestration"* ]]
}

@test "dispatch tuple for required planInput with provided plan" {
  write_required_plan_input_wf "$WRC_WORKSPACE/.ralph-workspace/workflows/plan-delivery.workflow.md"
  write_leaf_yaml_plan "$WRC_WORKSPACE/delivery.plan.md" "Deliver this"
  run ralph_wf_start_dry plan-delivery --plan "$WRC_WORKSPACE/delivery.plan.md"
  [ "$status" -eq 0 ]
  [[ "$output" == $'plan\tplan-overview\t'*delivery.plan.md ]]
}

# --- project edit / shadow / editor order / failure modes --------------------
# Contracts: agents/rules/test-design.md, agents/rules/testing-workflow.md,
# contracts.md (List / show / path / edit). Script-entry level: argv, exit,
# state-root project writes, immutability of seed sources, and refusal paths.

seed_valid_bundled() {
  local id="${1:-demo}"
  mkdir -p "$WRC_HOME/bundle/.ralph/workflows"
  cp "$REPO_ROOT/bundle/.ralph/workflows/investigation.workflow.md" \
    "$WRC_HOME/bundle/.ralph/workflows/${id}.workflow.md"
}

seed_valid_global() {
  local id="${1:-demo}"
  mkdir -p "$WRC_HOME/workflows"
  cp "$REPO_ROOT/bundle/.ralph/workflows/investigation.workflow.md" \
    "$WRC_HOME/workflows/${id}.workflow.md"
}

seed_valid_project() {
  local id="${1:-demo}"
  mkdir -p "$WRC_WORKSPACE/.ralph-workspace/workflows"
  cp "$REPO_ROOT/bundle/.ralph/workflows/investigation.workflow.md" \
    "$WRC_WORKSPACE/.ralph-workspace/workflows/${id}.workflow.md"
}

# Rewrite overview in a workflow file via a line substitution (keeps schema valid).
set_overview() {
  local path="$1"
  local overview="$2"
  local tmp
  tmp="$(mktemp "$WRC_TMP/ov-XXXXXX")"
  awk -v ov="$overview" '
    BEGIN { done=0 }
    /^overview:/ && !done { print "overview: " ov; done=1; next }
    { print }
  ' "$path" >"$tmp"
  mv -f "$tmp" "$path"
}

write_editor_script() {
  local path="$1"
  cat >"$path"
  chmod +x "$path"
}

@test "project edit updates an existing project winner atomically" {
  seed_valid_project demo
  local target="$WRC_WORKSPACE/.ralph-workspace/workflows/demo.workflow.md"
  local before after
  before="$(cat "$target")"
  set_overview "$target" "project before edit"
  before="$(cat "$target")"

  write_editor_script "$WRC_TMP/ok-editor.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
path="$1"
tmp="$(mktemp)"
awk '
  BEGIN { done=0 }
  /^overview:/ && !done { print "overview: project after edit"; done=1; next }
  { print }
' "$path" >"$tmp"
mv -f "$tmp" "$path"
EOF

  run bash -c "cd '$WRC_WORKSPACE' && env -u RALPH_PROJECT_ROOT -u RALPH_PLAN_WORKSPACE_ROOT \
    RALPH_HOME='$WRC_HOME' VISUAL='$WRC_TMP/ok-editor.sh' \
    bash '$WRC_SHIM' workflow edit demo --project"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Edited project workflow:"* ]]
  after="$(cat "$target")"
  [[ "$after" == *"overview: project after edit"* ]]
  [[ "$after" != "$before" ]]
  # No leftover same-directory temp/backup files after atomic publish.
  local leftovers
  leftovers="$(find "$WRC_WORKSPACE/.ralph-workspace/workflows" -name '.workflow-edit-*' 2>/dev/null | wc -l | tr -d ' ')"
  [ "$leftovers" = "0" ]
}

@test "direct edit updates an existing project workflow" {
  seed_valid_project edit-direct
  local target="$WRC_WORKSPACE/.ralph-workspace/workflows/edit-direct.workflow.md"
  set_overview "$target" "before direct edit"
  write_editor_script "$WRC_TMP/direct-edit.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
path="$1"
tmp="$(mktemp)"
awk '
  BEGIN { done=0 }
  /^overview:/ && !done { print "overview: after direct edit"; done=1; next }
  { print }
' "$path" >"$tmp"
mv -f "$tmp" "$path"
EOF
  run bash -c "cd '$WRC_WORKSPACE' && env -u RALPH_PROJECT_ROOT -u RALPH_PLAN_WORKSPACE_ROOT \
    RALPH_HOME='$WRC_HOME' VISUAL='$WRC_TMP/direct-edit.sh' \
    bash '$WRC_SHIM' workflow edit edit-direct --project"
  [ "$status" -eq 0 ]
  [[ "$(cat "$target")" == *"overview: after direct edit"* ]]
}

@test "shadow seeds bundled winner into a project file without mutating bundle" {
  seed_valid_bundled shadow-me
  local bundled="$WRC_HOME/bundle/.ralph/workflows/shadow-me.workflow.md"
  local project="$WRC_WORKSPACE/.ralph-workspace/workflows/shadow-me.workflow.md"
  local bundled_before
  bundled_before="$(cat "$bundled")"
  [ ! -e "$project" ]

  write_editor_script "$WRC_TMP/shadow-editor.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
path="$1"
tmp="$(mktemp)"
awk '
  BEGIN { done=0 }
  /^overview:/ && !done { print "overview: project shadow"; done=1; next }
  { print }
' "$path" >"$tmp"
mv -f "$tmp" "$path"
EOF

  run bash -c "cd '$WRC_WORKSPACE' && env -u RALPH_PROJECT_ROOT -u RALPH_PLAN_WORKSPACE_ROOT \
    RALPH_HOME='$WRC_HOME' VISUAL='$WRC_TMP/shadow-editor.sh' \
    bash '$WRC_SHIM' workflow edit shadow-me"
  [ "$status" -eq 0 ]
  [ -f "$project" ]
  [[ "$(cat "$project")" == *"overview: project shadow"* ]]
  [ "$(cat "$bundled")" = "$bundled_before" ]
  [ ! -L "$project" ]
}

@test "shadow seeds global winner into project when unscoped" {
  seed_valid_global from-global
  local global="$WRC_HOME/workflows/from-global.workflow.md"
  local project="$WRC_WORKSPACE/.ralph-workspace/workflows/from-global.workflow.md"
  local global_before
  global_before="$(cat "$global")"

  write_editor_script "$WRC_TMP/gshadow-editor.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
path="$1"
tmp="$(mktemp)"
awk '
  BEGIN { done=0 }
  /^overview:/ && !done { print "overview: shadowed from global"; done=1; next }
  { print }
' "$path" >"$tmp"
mv -f "$tmp" "$path"
EOF

  run bash -c "cd '$WRC_WORKSPACE' && env -u RALPH_PROJECT_ROOT -u RALPH_PLAN_WORKSPACE_ROOT \
    RALPH_HOME='$WRC_HOME' VISUAL='$WRC_TMP/gshadow-editor.sh' \
    bash '$WRC_SHIM' workflow edit from-global --project"
  [ "$status" -eq 0 ]
  [ -f "$project" ]
  [[ "$(cat "$project")" == *"overview: shadowed from global"* ]]
  [ "$(cat "$global")" = "$global_before" ]
}

@test "editor order prefers VISUAL then EDITOR then nano over vi" {
  seed_valid_project order-demo
  mkdir -p "$WRC_TMP/bin"
  write_editor_script "$WRC_TMP/bin/visual-ed" <<'EOF'
#!/usr/bin/env bash
printf 'visual\n' >"${EDIT_MARKER:?}"
exit 0
EOF
  write_editor_script "$WRC_TMP/bin/editor-ed" <<'EOF'
#!/usr/bin/env bash
printf 'editor\n' >"${EDIT_MARKER:?}"
exit 0
EOF
  # Shadows real nano earlier in PATH; a real vi may also exist on PATH, but
  # the stubbed nano must still win since nano is now preferred over vi.
  write_editor_script "$WRC_TMP/bin/nano" <<'EOF'
#!/usr/bin/env bash
printf 'nano\n' >"${EDIT_MARKER:?}"
exit 0
EOF

  local marker="$WRC_TMP/editor-used.txt"
  rm -f "$marker"

  run env -u RALPH_PROJECT_ROOT -u RALPH_PLAN_WORKSPACE_ROOT \
    RALPH_HOME="$WRC_HOME" EDIT_MARKER="$marker" \
    VISUAL="$WRC_TMP/bin/visual-ed" EDITOR="$WRC_TMP/bin/editor-ed" PATH="$WRC_TMP/bin:$PATH" \
    bash -c "cd '$WRC_WORKSPACE' && bash '$WRC_SHIM' workflow edit order-demo"
  [ "$status" -eq 0 ]
  [ "$(cat "$marker")" = "visual" ]

  rm -f "$marker"
  run env -u VISUAL -u RALPH_PROJECT_ROOT -u RALPH_PLAN_WORKSPACE_ROOT \
    RALPH_HOME="$WRC_HOME" EDIT_MARKER="$marker" \
    EDITOR="$WRC_TMP/bin/editor-ed" PATH="$WRC_TMP/bin:$PATH" \
    bash -c "cd '$WRC_WORKSPACE' && bash '$WRC_SHIM' workflow edit order-demo"
  [ "$status" -eq 0 ]
  [ "$(cat "$marker")" = "editor" ]

  # Neither VISUAL nor EDITOR set: nano wins over vi (a modal editor is the
  # wrong default for someone who never asked for one).
  rm -f "$marker"
  run env -u VISUAL -u EDITOR -u RALPH_PROJECT_ROOT -u RALPH_PLAN_WORKSPACE_ROOT \
    RALPH_HOME="$WRC_HOME" EDIT_MARKER="$marker" PATH="$WRC_TMP/bin:$PATH" \
    bash -c "cd '$WRC_WORKSPACE' && bash '$WRC_SHIM' workflow edit order-demo"
  [ "$status" -eq 0 ]
  [ "$(cat "$marker")" = "nano" ]
}

@test "editor hint names the editor and explains save/exit for vi and nano" {
  seed_valid_project hint-demo
  mkdir -p "$WRC_TMP/bin-vi" "$WRC_TMP/bin-nano"
  write_editor_script "$WRC_TMP/bin-vi/vi" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  write_editor_script "$WRC_TMP/bin-nano/nano" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  # EDITOR resolved to a literal `vi`: the modal-editor save/exit hint applies,
  # the exact case a "normal person" gets stuck in without :wq.
  run env -u VISUAL -u RALPH_PROJECT_ROOT -u RALPH_PLAN_WORKSPACE_ROOT \
    RALPH_HOME="$WRC_HOME" EDITOR="$WRC_TMP/bin-vi/vi" \
    bash -c "cd '$WRC_WORKSPACE' && bash '$WRC_SHIM' workflow edit hint-demo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Opening"*"vi"*"to edit the workflow"* ]]
  [[ "$output" == *":wq"* ]]
  [[ "$output" == *":q!"* ]]

  run env -u VISUAL -u RALPH_PROJECT_ROOT -u RALPH_PLAN_WORKSPACE_ROOT \
    RALPH_HOME="$WRC_HOME" EDITOR="$WRC_TMP/bin-nano/nano" \
    bash -c "cd '$WRC_WORKSPACE' && bash '$WRC_SHIM' workflow edit hint-demo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Opening"*"nano"*"to edit the workflow"* ]]
  [[ "$output" == *"Ctrl+O"* ]]
  [[ "$output" == *"Ctrl+X"* ]]
}

@test "project edit editor failure preserves the original workflow" {
  seed_valid_project fail-demo
  local target="$WRC_WORKSPACE/.ralph-workspace/workflows/fail-demo.workflow.md"
  set_overview "$target" "keep me"
  local before
  before="$(cat "$target")"

  write_editor_script "$WRC_TMP/fail-editor.sh" <<'EOF'
#!/usr/bin/env bash
echo "mutated-by-failed-editor" >>"$1"
exit 7
EOF

  run bash -c "cd '$WRC_WORKSPACE' && env -u RALPH_PROJECT_ROOT -u RALPH_PLAN_WORKSPACE_ROOT \
    RALPH_HOME='$WRC_HOME' VISUAL='$WRC_TMP/fail-editor.sh' \
    bash '$WRC_SHIM' workflow edit fail-demo"
  [ "$status" -eq 1 ]
  [[ "$output" == *"editor failed"* ]]
  [ "$(cat "$target")" = "$before" ]
  local leftovers
  leftovers="$(find "$WRC_WORKSPACE/.ralph-workspace/workflows" -name '.workflow-edit-*' 2>/dev/null | wc -l | tr -d ' ')"
  [ "$leftovers" = "0" ]
}

@test "invalid edit is refused and original is preserved" {
  seed_valid_project invalid-demo
  local target="$WRC_WORKSPACE/.ralph-workspace/workflows/invalid-demo.workflow.md"
  set_overview "$target" "valid original"
  local before
  before="$(cat "$target")"

  write_editor_script "$WRC_TMP/bad-editor.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '---' 'kind: workflow' 'mode: dependency' 'overview: broken' '---' '# no TASK todo' >"$1"
EOF

  run bash -c "cd '$WRC_WORKSPACE' && env -u RALPH_PROJECT_ROOT -u RALPH_PLAN_WORKSPACE_ROOT \
    RALPH_HOME='$WRC_HOME' VISUAL='$WRC_TMP/bad-editor.sh' \
    bash '$WRC_SHIM' workflow edit invalid-demo"
  [ "$status" -eq 1 ]
  [[ "$output" == *"failed validation"* ]]
  [ "$(cat "$target")" = "$before" ]
}

@test "signal during edit restores the original and cleans temps" {
  seed_valid_project signal-demo
  local target="$WRC_WORKSPACE/.ralph-workspace/workflows/signal-demo.workflow.md"
  set_overview "$target" "signal original"
  local before
  before="$(cat "$target")"

  write_editor_script "$WRC_TMP/signal-editor.sh" <<'EOF'
#!/usr/bin/env bash
# Mutate the temp buffer, then signal the parent CLI so traps must restore.
printf '%s\n' '---' 'kind: workflow' 'mode: dependency' 'overview: should not stick' '---' >"$1"
kill -TERM "$PPID"
exit 1
EOF

  run bash -c "cd '$WRC_WORKSPACE' && env -u RALPH_PROJECT_ROOT -u RALPH_PLAN_WORKSPACE_ROOT \
    RALPH_HOME='$WRC_HOME' VISUAL='$WRC_TMP/signal-editor.sh' \
    bash '$WRC_SHIM' workflow edit signal-demo"
  [ "$status" -ne 0 ]
  [ "$(cat "$target")" = "$before" ]
  local leftovers
  leftovers="$(find "$WRC_WORKSPACE/.ralph-workspace/workflows" -name '.workflow-edit-*' 2>/dev/null | wc -l | tr -d ' ')"
  [ "$leftovers" = "0" ]
}

@test "symlink target edit replaces the project link without mutating the referent" {
  seed_valid_bundled link-src
  local bundled="$WRC_HOME/bundle/.ralph/workflows/link-src.workflow.md"
  local project="$WRC_WORKSPACE/.ralph-workspace/workflows/link-src.workflow.md"
  local bundled_before
  bundled_before="$(cat "$bundled")"
  ln -s "$bundled" "$project"
  [ -L "$project" ]

  write_editor_script "$WRC_TMP/symlink-editor.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
path="$1"
tmp="$(mktemp)"
awk '
  BEGIN { done=0 }
  /^overview:/ && !done { print "overview: replaced symlink entry"; done=1; next }
  { print }
' "$path" >"$tmp"
mv -f "$tmp" "$path"
EOF

  run bash -c "cd '$WRC_WORKSPACE' && env -u RALPH_PROJECT_ROOT -u RALPH_PLAN_WORKSPACE_ROOT \
    RALPH_HOME='$WRC_HOME' VISUAL='$WRC_TMP/symlink-editor.sh' \
    bash '$WRC_SHIM' workflow edit link-src --project"
  [ "$status" -eq 0 ]
  [ -f "$project" ]
  [ ! -L "$project" ]
  [[ "$(cat "$project")" == *"overview: replaced symlink entry"* ]]
  [ "$(cat "$bundled")" = "$bundled_before" ]
}

@test "target race refuses overwrite and keeps the concurrent project file" {
  seed_valid_project race-demo
  local target="$WRC_WORKSPACE/.ralph-workspace/workflows/race-demo.workflow.md"
  set_overview "$target" "pre-race"
  local raced="$WRC_TMP/raced.workflow.md"
  cp "$target" "$raced"
  set_overview "$raced" "concurrent winner"

  write_editor_script "$WRC_TMP/race-editor.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
# Concurrent writer changes the live project file while we edit the temp.
cp -f '$raced' '$target'
# Leave a still-valid buffer that would overwrite if race checks were absent.
tmp="\$(mktemp)"
awk '
  BEGIN { done=0 }
  /^overview:/ && !done { print "overview: losing edit"; done=1; next }
  { print }
' "\$1" >"\$tmp"
mv -f "\$tmp" "\$1"
EOF

  run bash -c "cd '$WRC_WORKSPACE' && env -u RALPH_PROJECT_ROOT -u RALPH_PLAN_WORKSPACE_ROOT \
    RALPH_HOME='$WRC_HOME' VISUAL='$WRC_TMP/race-editor.sh' \
    bash '$WRC_SHIM' workflow edit race-demo"
  [ "$status" -eq 1 ]
  [[ "$output" == *"race"* ]]
  [[ "$(cat "$target")" == *"overview: concurrent winner"* ]]
  [[ "$(cat "$target")" != *"overview: losing edit"* ]]
}

@test "atomic publish leaves no edit temps after success or invalid edit" {
  seed_valid_project atomic-demo
  local target="$WRC_WORKSPACE/.ralph-workspace/workflows/atomic-demo.workflow.md"
  local dir
  dir="$(dirname "$target")"

  write_editor_script "$WRC_TMP/atomic-ok.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
tmp="$(mktemp)"
awk '
  BEGIN { done=0 }
  /^overview:/ && !done { print "overview: atomic ok"; done=1; next }
  { print }
' "$1" >"$tmp"
mv -f "$tmp" "$1"
EOF

  run bash -c "cd '$WRC_WORKSPACE' && env -u RALPH_PROJECT_ROOT -u RALPH_PLAN_WORKSPACE_ROOT \
    RALPH_HOME='$WRC_HOME' VISUAL='$WRC_TMP/atomic-ok.sh' \
    bash '$WRC_SHIM' workflow edit atomic-demo"
  [ "$status" -eq 0 ]
  [[ "$(cat "$target")" == *"overview: atomic ok"* ]]
  [ "$(find "$dir" -name '.workflow-edit-*' | wc -l | tr -d ' ')" = "0" ]

  write_editor_script "$WRC_TMP/atomic-bad.sh" <<'EOF'
#!/usr/bin/env bash
printf 'not a workflow\n' >"$1"
EOF

  run bash -c "cd '$WRC_WORKSPACE' && env -u RALPH_PROJECT_ROOT -u RALPH_PLAN_WORKSPACE_ROOT \
    RALPH_HOME='$WRC_HOME' VISUAL='$WRC_TMP/atomic-bad.sh' \
    bash '$WRC_SHIM' workflow edit atomic-demo"
  [ "$status" -eq 1 ]
  [[ "$(cat "$target")" == *"overview: atomic ok"* ]]
  [ "$(find "$dir" -name '.workflow-edit-*' | wc -l | tr -d ' ')" = "0" ]
}

# --- global edit / cross-project / Ralph home / shadow / unwritable ---------
# Contracts: contracts.md (List / show / path / edit; ownership). Same atomic
# editor as project; target is $RALPH_HOME/workflows/<id>.workflow.md.

@test "global edit updates an existing global workflow atomically" {
  seed_valid_global g-edit
  local target="$WRC_HOME/workflows/g-edit.workflow.md"
  set_overview "$target" "global before edit"
  local before after
  before="$(cat "$target")"

  write_editor_script "$WRC_TMP/g-ok-editor.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
path="$1"
tmp="$(mktemp)"
awk '
  BEGIN { done=0 }
  /^overview:/ && !done { print "overview: global after edit"; done=1; next }
  { print }
' "$path" >"$tmp"
mv -f "$tmp" "$path"
EOF

  run bash -c "cd '$WRC_WORKSPACE' && env -u RALPH_PROJECT_ROOT -u RALPH_PLAN_WORKSPACE_ROOT \
    RALPH_HOME='$WRC_HOME' VISUAL='$WRC_TMP/g-ok-editor.sh' \
    bash '$WRC_SHIM' workflow edit g-edit --global"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Edited global workflow:"* ]]
  after="$(cat "$target")"
  [[ "$after" == *"overview: global after edit"* ]]
  [[ "$after" != "$before" ]]
  local leftovers
  leftovers="$(find "$WRC_HOME/workflows" -name '.workflow-edit-*' 2>/dev/null | wc -l | tr -d ' ')"
  [ "$leftovers" = "0" ]
}

@test "global edit seeds from bundled when global absent without mutating bundle" {
  seed_valid_bundled g-from-bundle
  local bundled="$WRC_HOME/bundle/.ralph/workflows/g-from-bundle.workflow.md"
  local global="$WRC_HOME/workflows/g-from-bundle.workflow.md"
  local bundled_before
  bundled_before="$(cat "$bundled")"
  [ ! -e "$global" ]

  write_editor_script "$WRC_TMP/g-seed-bundled.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
path="$1"
tmp="$(mktemp)"
awk '
  BEGIN { done=0 }
  /^overview:/ && !done { print "overview: global seeded from bundled"; done=1; next }
  { print }
' "$path" >"$tmp"
mv -f "$tmp" "$path"
EOF

  run bash -c "cd '$WRC_WORKSPACE' && env -u RALPH_PROJECT_ROOT -u RALPH_PLAN_WORKSPACE_ROOT \
    RALPH_HOME='$WRC_HOME' VISUAL='$WRC_TMP/g-seed-bundled.sh' \
    bash '$WRC_SHIM' workflow edit g-from-bundle --global"
  [ "$status" -eq 0 ]
  [ -f "$global" ]
  [[ "$(cat "$global")" == *"overview: global seeded from bundled"* ]]
  [ "$(cat "$bundled")" = "$bundled_before" ]
}

@test "global edit seeds from project winner when global absent" {
  seed_valid_project g-from-project
  local project="$WRC_WORKSPACE/.ralph-workspace/workflows/g-from-project.workflow.md"
  local global="$WRC_HOME/workflows/g-from-project.workflow.md"
  set_overview "$project" "project seed source"
  local project_before
  project_before="$(cat "$project")"
  [ ! -e "$global" ]

  write_editor_script "$WRC_TMP/g-seed-project.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
path="$1"
tmp="$(mktemp)"
awk '
  BEGIN { done=0 }
  /^overview:/ && !done { print "overview: global seeded from project"; done=1; next }
  { print }
' "$path" >"$tmp"
mv -f "$tmp" "$path"
EOF

  run bash -c "cd '$WRC_WORKSPACE' && env -u RALPH_PROJECT_ROOT -u RALPH_PLAN_WORKSPACE_ROOT \
    RALPH_HOME='$WRC_HOME' VISUAL='$WRC_TMP/g-seed-project.sh' \
    bash '$WRC_SHIM' workflow edit g-from-project --global"
  [ "$status" -eq 0 ]
  [ -f "$global" ]
  [[ "$(cat "$global")" == *"overview: global seeded from project"* ]]
  [ "$(cat "$project")" = "$project_before" ]
}

@test "cross project visibility shares a global edit across workspaces" {
  seed_valid_bundled shared-g
  local ws_a="$WRC_TMP/ws-a"
  local ws_b="$WRC_TMP/ws-b"
  mkdir -p "$ws_a/.ralph-workspace/workflows" "$ws_b/.ralph-workspace/workflows"

  write_editor_script "$WRC_TMP/cross-ed.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
path="$1"
tmp="$(mktemp)"
awk '
  BEGIN { done=0 }
  /^overview:/ && !done { print "overview: cross project global"; done=1; next }
  { print }
' "$path" >"$tmp"
mv -f "$tmp" "$path"
EOF

  run bash -c "cd '$ws_a' && env -u RALPH_PROJECT_ROOT -u RALPH_PLAN_WORKSPACE_ROOT \
    RALPH_HOME='$WRC_HOME' VISUAL='$WRC_TMP/cross-ed.sh' \
    bash '$WRC_SHIM' workflow edit shared-g --global"
  [ "$status" -eq 0 ]
  [ -f "$WRC_HOME/workflows/shared-g.workflow.md" ]

  run bash -c "cd '$ws_b' && env -u RALPH_PROJECT_ROOT -u RALPH_PLAN_WORKSPACE_ROOT \
    RALPH_HOME='$WRC_HOME' bash '$WRC_SHIM' workflow list --tsv"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\tglobal\tcross project global'* ]]

  run bash -c "cd '$ws_b' && env -u RALPH_PROJECT_ROOT -u RALPH_PLAN_WORKSPACE_ROOT \
    RALPH_HOME='$WRC_HOME' bash '$WRC_SHIM' workflow path shared-g"
  [ "$status" -eq 0 ]
  [ "$output" = "$WRC_HOME/workflows/shared-g.workflow.md" ]
}

@test "Ralph home overridden and spaced paths host global edit" {
  local spaced_home="$WRC_TMP/ralph home with spaces"
  mkdir -p "$spaced_home/workflows" "$spaced_home/bundle/.ralph/workflows"
  cp -R "$REPO_ROOT/bundle/.ralph/." "$spaced_home/bundle/.ralph/"
  mkdir -p "$spaced_home/bundle/.ralph/workflows"
  cp "$REPO_ROOT/bundle/.ralph/workflows/investigation.workflow.md" \
    "$spaced_home/workflows/space-g.workflow.md"
  set_overview "$spaced_home/workflows/space-g.workflow.md" "spaced before"

  write_editor_script "$WRC_TMP/space-ed.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
path="$1"
tmp="$(mktemp)"
awk '
  BEGIN { done=0 }
  /^overview:/ && !done { print "overview: spaced Ralph home edit"; done=1; next }
  { print }
' "$path" >"$tmp"
mv -f "$tmp" "$path"
EOF

  run bash -c "cd '$WRC_WORKSPACE' && env -u RALPH_PROJECT_ROOT -u RALPH_PLAN_WORKSPACE_ROOT \
    RALPH_HOME='$spaced_home' VISUAL='$WRC_TMP/space-ed.sh' \
    bash '$WRC_SHIM' workflow edit space-g --global"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Edited global workflow:"* ]]
  [[ "$(cat "$spaced_home/workflows/space-g.workflow.md")" == *"overview: spaced Ralph home edit"* ]]

  run bash -c "cd '$WRC_WORKSPACE' && env -u RALPH_PROJECT_ROOT -u RALPH_PLAN_WORKSPACE_ROOT \
    RALPH_HOME='$spaced_home' bash '$WRC_SHIM' workflow path space-g --global"
  [ "$status" -eq 0 ]
  [ "$output" = "$spaced_home/workflows/space-g.workflow.md" ]
}

@test "shadow precedence global shadows bundled and project shadows global" {
  seed_valid_bundled prec-demo
  local bundled="$WRC_HOME/bundle/.ralph/workflows/prec-demo.workflow.md"
  local global="$WRC_HOME/workflows/prec-demo.workflow.md"
  local project="$WRC_WORKSPACE/.ralph-workspace/workflows/prec-demo.workflow.md"
  local bundled_before
  bundled_before="$(cat "$bundled")"

  write_editor_script "$WRC_TMP/prec-g.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
path="$1"
tmp="$(mktemp)"
awk '
  BEGIN { done=0 }
  /^overview:/ && !done { print "overview: global shadow of bundled"; done=1; next }
  { print }
' "$path" >"$tmp"
mv -f "$tmp" "$path"
EOF

  run bash -c "cd '$WRC_WORKSPACE' && env -u RALPH_PROJECT_ROOT -u RALPH_PLAN_WORKSPACE_ROOT \
    RALPH_HOME='$WRC_HOME' VISUAL='$WRC_TMP/prec-g.sh' \
    bash '$WRC_SHIM' workflow edit prec-demo --global"
  [ "$status" -eq 0 ]
  [ "$(cat "$bundled")" = "$bundled_before" ]

  run ralph_wf list --tsv
  [ "$status" -eq 0 ]
  [[ "$output" == *"prec-demo"$'\t'"global"$'\t'"global shadow of bundled"* ]]
  run ralph_wf path prec-demo
  [ "$status" -eq 0 ]
  [ "$output" = "$global" ]

  write_editor_script "$WRC_TMP/prec-p.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
path="$1"
tmp="$(mktemp)"
awk '
  BEGIN { done=0 }
  /^overview:/ && !done { print "overview: project shadow of global"; done=1; next }
  { print }
' "$path" >"$tmp"
mv -f "$tmp" "$path"
EOF

  run bash -c "cd '$WRC_WORKSPACE' && env -u RALPH_PROJECT_ROOT -u RALPH_PLAN_WORKSPACE_ROOT \
    RALPH_HOME='$WRC_HOME' VISUAL='$WRC_TMP/prec-p.sh' \
    bash '$WRC_SHIM' workflow edit prec-demo --project"
  [ "$status" -eq 0 ]
  [ -f "$project" ]
  [[ "$(cat "$global")" == *"overview: global shadow of bundled"* ]]
  [[ "$(cat "$project")" == *"overview: project shadow of global"* ]]

  run ralph_wf list --tsv
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\tproject\tproject shadow of global'* ]]
}

@test "unwritable Ralph home workflows directory refuses global edit" {
  seed_valid_global locked-g
  local target="$WRC_HOME/workflows/locked-g.workflow.md"
  set_overview "$target" "must stay"
  local before
  before="$(cat "$target")"

  write_editor_script "$WRC_TMP/locked-ed.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'should not run' >"$1"
exit 0
EOF

  chmod a-w "$WRC_HOME/workflows"
  run bash -c "cd '$WRC_WORKSPACE' && env -u RALPH_PROJECT_ROOT -u RALPH_PLAN_WORKSPACE_ROOT \
    RALPH_HOME='$WRC_HOME' VISUAL='$WRC_TMP/locked-ed.sh' \
    bash '$WRC_SHIM' workflow edit locked-g --global"
  local ec=$status
  chmod u+w "$WRC_HOME/workflows"
  [ "$ec" -eq 1 ]
  [[ "$output" == *"not writable"* || "$output" == *"failed to create edit temp"* ]]
  [ "$(cat "$target")" = "$before" ]
}

@test "global edit editor failure preserves the original workflow" {
  seed_valid_global g-preserve
  local target="$WRC_HOME/workflows/g-preserve.workflow.md"
  set_overview "$target" "keep global"
  local before
  before="$(cat "$target")"

  write_editor_script "$WRC_TMP/g-fail-ed.sh" <<'EOF'
#!/usr/bin/env bash
echo "mutated-by-failed-editor" >>"$1"
exit 7
EOF

  run bash -c "cd '$WRC_WORKSPACE' && env -u RALPH_PROJECT_ROOT -u RALPH_PLAN_WORKSPACE_ROOT \
    RALPH_HOME='$WRC_HOME' VISUAL='$WRC_TMP/g-fail-ed.sh' \
    bash '$WRC_SHIM' workflow edit g-preserve --global"
  [ "$status" -eq 1 ]
  [[ "$output" == *"editor failed"* ]]
  [ "$(cat "$target")" = "$before" ]
  local leftovers
  leftovers="$(find "$WRC_HOME/workflows" -name '.workflow-edit-*' 2>/dev/null | wc -l | tr -d ' ')"
  [ "$leftovers" = "0" ]
}

@test "invalid global edit is refused and original is preserved" {
  seed_valid_global g-invalid
  local target="$WRC_HOME/workflows/g-invalid.workflow.md"
  set_overview "$target" "valid global original"
  local before
  before="$(cat "$target")"

  write_editor_script "$WRC_TMP/g-bad-ed.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '---' 'kind: workflow' 'mode: dependency' 'overview: broken' '---' '# no TASK todo' >"$1"
EOF

  run bash -c "cd '$WRC_WORKSPACE' && env -u RALPH_PROJECT_ROOT -u RALPH_PLAN_WORKSPACE_ROOT \
    RALPH_HOME='$WRC_HOME' VISUAL='$WRC_TMP/g-bad-ed.sh' \
    bash '$WRC_SHIM' workflow edit g-invalid --global"
  [ "$status" -eq 1 ]
  [[ "$output" == *"failed validation"* ]]
  [ "$(cat "$target")" = "$before" ]
}
