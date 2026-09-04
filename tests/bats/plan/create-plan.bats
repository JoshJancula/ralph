#!/usr/bin/env bats
# Leaf plan creation and removed graph/orchestration format refusals.
# Contracts: agents/rules/test-design.md, agents/rules/testing-workflow.md.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$RALPH_LIB_ROOT/plan-todo.sh"

setup() {
  TEST_WORKSPACE="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEST_WORKSPACE"
}

create_plan_script="$REPO_ROOT/.ralph/create-plan.sh"
validate_plan_script="$REPO_ROOT/.ralph/validate-plan.sh"

created_plan_path() {
  local plan_name="${1:-PLAN1}"
  printf '%s/.ralph-workspace/plans/%s.plan.md\n' "$TEST_WORKSPACE" "$plan_name"
}

@test "create-plan leaf default invocation produces classic template" {
  run bash "$create_plan_script" --workspace "$TEST_WORKSPACE"
  [ "$status" -eq 0 ]

  plan_file="$(created_plan_path)"
  [ -f "$plan_file" ]
  grep -Fq '## TODOs' "$plan_file"
  grep -Fq -- '- [ ]' "$plan_file"
}

@test "create-plan leaf --format classic creates markdown checklist plan" {
  run bash "$create_plan_script" --format classic --name classic-demo --workspace "$TEST_WORKSPACE"
  [ "$status" -eq 0 ]

  plan_file="$(created_plan_path classic-demo)"
  [ -f "$plan_file" ]
  grep -Fq '## TODOs' "$plan_file"
  grep -Fq -- '- [ ]' "$plan_file"
}

@test "create-plan leaf --format legacy matches classic output" {
  run bash "$create_plan_script" --format legacy --name legacy-demo --workspace "$TEST_WORKSPACE"
  [ "$status" -eq 0 ]
  legacy_plan="$(created_plan_path legacy-demo)"

  classic_workspace="$(mktemp -d)"
  run bash "$create_plan_script" --format classic --name legacy-demo --workspace "$classic_workspace"
  [ "$status" -eq 0 ]
  classic_plan="$classic_workspace/.ralph-workspace/plans/legacy-demo.plan.md"

  cmp -s "$legacy_plan" "$classic_plan"
  rm -rf "$classic_workspace"
}

@test "create-plan leaf --format yaml scaffolds a flat yaml plan" {
  run bash "$create_plan_script" --format yaml --name yaml-demo --workspace "$TEST_WORKSPACE"
  [ "$status" -eq 0 ]

  plan_file="$(created_plan_path yaml-demo)"
  [ -f "$plan_file" ]
  [ "$(head -1 "$plan_file")" = "---" ]
  grep -Fq 'mode: standard' "$plan_file"
  grep -Fq 'todos:' "$plan_file"
  [ "$(plan_detect_format "$plan_file")" = "yaml" ]
}

@test "create-plan leaf --format standard scaffolds a flat standard plan" {
  run bash "$create_plan_script" --format standard --name std-demo --workspace "$TEST_WORKSPACE"
  [ "$status" -eq 0 ]

  plan_file="$(created_plan_path std-demo)"
  [ -f "$plan_file" ]
  [ "$(head -1 "$plan_file")" = "---" ]
  grep -Fq 'mode: standard' "$plan_file"
  grep -Fq 'todos:' "$plan_file"
}

@test "create-plan leaf format aliases standard structured pipeline cursor scaffold yaml plans" {
  local alias plan_name plan_file
  for alias in standard structured pipeline cursor; do
    plan_name="alias-${alias}"
    run bash "$create_plan_script" --format "$alias" --name "$plan_name" --workspace "$TEST_WORKSPACE"
    [ "$status" -eq 0 ]

    plan_file="$(created_plan_path "$plan_name")"
    [ "$(head -1 "$plan_file")" = "---" ]
    grep -Fq 'todos:' "$plan_file"
    [ "$(plan_detect_format "$plan_file")" = "yaml" ]
  done
}

@test "create-plan leaf --format yaml prints the per-todo fresh-session tip" {
  run bash "$create_plan_script" --format yaml --name tip-demo --workspace "$TEST_WORKSPACE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"per-todo routing applies under fresh session management"* ]]
}

@test "create-plan leaf --execution simple is accepted as backward-compat alias for standard" {
  run bash "$create_plan_script" --format yaml --execution simple --name simple-compat-demo --workspace "$TEST_WORKSPACE"
  [ "$status" -eq 0 ]

  plan_file="$(created_plan_path simple-compat-demo)"
  grep -Fq 'mode: standard' "$plan_file"
}

@test "create-plan rejects --format graph with workflow replacement" {
  run bash "$create_plan_script" --format graph --name nope-graph --workspace "$TEST_WORKSPACE"
  [ "$status" -eq 2 ]
  [ "${lines[0]}" = "Error: 'ralph create plan --format graph' was removed. Use: ralph create workflow" ]
  [ ! -e "$(created_plan_path nope-graph)" ]
}

@test "create-plan rejects --format orchestration with workflow replacement" {
  run bash "$create_plan_script" --format orchestration --name nope-orch --workspace "$TEST_WORKSPACE"
  [ "$status" -eq 2 ]
  [ "${lines[0]}" = "Error: 'ralph create plan --format orchestration' was removed. Use: ralph create workflow" ]
  [ ! -e "$(created_plan_path nope-orch)" ]
}

@test "create-plan rejects --execution orchestration with workflow replacement" {
  run bash "$create_plan_script" \
    --format yaml --execution orchestration --name nope-exec --workspace "$TEST_WORKSPACE"
  [ "$status" -eq 2 ]
  [ "${lines[0]}" = "Error: orchestration plans are created with 'ralph create workflow', not 'ralph create plan'" ]
  [ ! -e "$(created_plan_path nope-exec)" ]
}

@test "create-plan rejects graph preset flags with workflow replacement" {
  run bash "$create_plan_script" \
    --format yaml --preset parallel-implementation --name nope-preset --workspace "$TEST_WORKSPACE"
  [ "$status" -eq 2 ]
  [[ "${lines[0]}" == *"ralph create workflow"* ]]
  [ ! -e "$(created_plan_path nope-preset)" ]
}

@test "create-plan rejects orchestration stage flags with workflow replacement" {
  run bash "$create_plan_script" \
    --format yaml --name nope-stages --workspace "$TEST_WORKSPACE" \
    --stage research --stage-runtime research=cursor
  [ "$status" -eq 2 ]
  [[ "${lines[0]}" == *"ralph create workflow"* ]]
  [ ! -e "$(created_plan_path nope-stages)" ]
}

@test "create-plan rejects --kind" {
  run bash "$create_plan_script" --kind simple --workspace "$TEST_WORKSPACE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported flag: --kind"* ]]
}

@test "create-plan rejects invalid --execution" {
  run bash "$create_plan_script" --format yaml --execution bogus --workspace "$TEST_WORKSPACE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid --execution: bogus"* ]]
}

@test "create-plan rejects invalid --format values" {
  run bash "$create_plan_script" --format bogus --workspace "$TEST_WORKSPACE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid --format: bogus"* ]]
}

@test "create-plan rejects missing --format value" {
  run bash "$create_plan_script" --format
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing value for --format"* ]]
}

@test "plan_detect_format reports yaml for generated yaml plan" {
  run bash "$create_plan_script" --format yaml --name demo --workspace "$TEST_WORKSPACE"
  [ "$status" -eq 0 ]

  plan_file="$(created_plan_path demo)"
  [ "$(plan_detect_format "$plan_file")" = "yaml" ]
}

@test "plan_cursor_frontmatter_op get_next returns first example todo from generated structured plan" {
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"

  run bash "$create_plan_script" --format structured --name demo --workspace "$TEST_WORKSPACE"
  [ "$status" -eq 0 ]

  plan_file="$(created_plan_path demo)"
  run plan_cursor_frontmatter_op "$plan_file" get_next
  [ "$status" -eq 0 ]
  [ "$output" = "1|example-task|This is a task to do something." ]
}

@test "canonical leaf plan templates exist" {
  [ -f "$REPO_ROOT/bundle/.ralph/plan-templates/classic.plan.template.md" ]
  [ -f "$REPO_ROOT/bundle/.ralph/plan-templates/pipeline-simple.plan.template.md" ]
}

@test "leaf plan templates omit model pins" {
  local templates_dir="$REPO_ROOT/bundle/.ralph/plan-templates"

  for template in classic.plan.template.md pipeline-simple.plan.template.md; do
    ! grep -Eq '^[[:space:]]*(agent|role|model):' "$templates_dir/$template"
  done
}
