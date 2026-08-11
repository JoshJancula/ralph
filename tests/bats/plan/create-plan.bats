#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$RALPH_LIB_ROOT/plan-todo.sh"

setup() {
  TEST_WORKSPACE="$(mktemp -d)"
  # Orchestration generation via create-plan.sh is gated; ralph create orc is the user-facing
  # entry. Engine tests opt in explicitly via this internal flag.
  export RALPH_CREATE_ALLOW_ORCHESTRATION=1
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

orchestration_flags() {
  printf '%s\n' \
    --stage research \
    --stage review \
    --stage-runtime research=cursor \
    --stage-agent research=research \
    --stage-produces research=.ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md \
    --stage-runtime review=codex \
    --stage-agent review=code-review \
    --stage-requires review=.ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md \
    --stage-produces review=.ralph-workspace/artifacts/{{ARTIFACT_NS}}/review.md
}

@test "create-plan default invocation produces classic template" {
  run bash "$create_plan_script" --workspace "$TEST_WORKSPACE"
  [ "$status" -eq 0 ]

  plan_file="$(created_plan_path)"
  [ -f "$plan_file" ]
  grep -Fq '## TODOs' "$plan_file"
  grep -Fq -- '- [ ]' "$plan_file"
}

@test "create-plan --format classic creates markdown checklist plan" {
  run bash "$create_plan_script" --format classic --name classic-demo --workspace "$TEST_WORKSPACE"
  [ "$status" -eq 0 ]

  plan_file="$(created_plan_path classic-demo)"
  [ -f "$plan_file" ]
  grep -Fq '## TODOs' "$plan_file"
  grep -Fq -- '- [ ]' "$plan_file"
}

@test "create-plan --format legacy matches classic output" {
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

@test "create-plan --format orchestration --execution standard scaffolds standard plan" {
  run bash "$create_plan_script" --format orchestration --execution standard --name standard-demo --workspace "$TEST_WORKSPACE"
  [ "$status" -eq 0 ]

  plan_file="$(created_plan_path standard-demo)"
  [ -f "$plan_file" ]
  [ "$(head -1 "$plan_file")" = "---" ]
  grep -Fq 'execution: standard' "$plan_file"
  grep -Fq 'name: standard-demo' "$plan_file"
  grep -Fq 'todos:' "$plan_file"
}

@test "create-plan --format standard scaffolds a flat standard plan" {
  run bash "$create_plan_script" --format standard --name std-demo --workspace "$TEST_WORKSPACE"
  [ "$status" -eq 0 ]

  plan_file="$(created_plan_path std-demo)"
  [ -f "$plan_file" ]
  [ "$(head -1 "$plan_file")" = "---" ]
  grep -Fq 'execution: standard' "$plan_file"
  grep -Fq 'todos:' "$plan_file"
}

@test "create-plan --format standard prints the per-todo fresh-session tip" {
  run bash "$create_plan_script" --format standard --name tip-demo --workspace "$TEST_WORKSPACE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"per-todo routing applies under fresh session management"* ]]
}

@test "create-plan rejects --execution orchestration and points to ralph create orc" {
  run env -u RALPH_CREATE_ALLOW_ORCHESTRATION bash "$create_plan_script" \
    --format standard --execution orchestration --name nope-demo --workspace "$TEST_WORKSPACE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ralph create orc"* ]]
}

@test "create-plan --execution simple is accepted as backward-compat alias for standard" {
  run bash "$create_plan_script" --format orchestration --execution simple --name simple-compat-demo --workspace "$TEST_WORKSPACE"
  [ "$status" -eq 0 ]

  plan_file="$(created_plan_path simple-compat-demo)"
  grep -Fq 'execution: standard' "$plan_file"
}

@test "create-plan --format yaml scaffolds a flat yaml plan" {
  run bash "$create_plan_script" --format yaml --name yaml-demo --workspace "$TEST_WORKSPACE"
  [ "$status" -eq 0 ]

  plan_file="$(created_plan_path yaml-demo)"
  [ -f "$plan_file" ]
  [ "$(head -1 "$plan_file")" = "---" ]
  grep -Fq 'execution: standard' "$plan_file"
  grep -Fq 'todos:' "$plan_file"
  [ "$(plan_detect_format "$plan_file")" = "yaml" ]
}

@test "create-plan format aliases standard structured pipeline cursor scaffold yaml plans" {
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

@test "create-plan --format structured alias scaffolds standard plan" {
  run bash "$create_plan_script" --format structured --name demo --workspace "$TEST_WORKSPACE"
  [ "$status" -eq 0 ]

  plan_file="$(created_plan_path demo)"
  [ -f "$plan_file" ]
  [ "$(head -1 "$plan_file")" = "---" ]
  grep -Fq 'execution: standard' "$plan_file"
  grep -Fq 'name: demo' "$plan_file"
  grep -Fq 'todos:' "$plan_file"
}

@test "create-plan --format pipeline without --execution creates standard execution" {
  run bash "$create_plan_script" --format pipeline --name pipeline-default --workspace "$TEST_WORKSPACE"
  [ "$status" -eq 0 ]

  plan_file="$(created_plan_path pipeline-default)"
  grep -Fq 'execution: standard' "$plan_file"
}

@test "create-plan --format structured alone keeps backward-compatible standard behavior" {
  run bash "$create_plan_script" --format structured --workspace "$TEST_WORKSPACE"
  [ "$status" -eq 0 ]

  plan_file="$(created_plan_path)"
  grep -Fq 'execution: standard' "$plan_file"
  grep -Fq 'todos:' "$plan_file"
}

@test "create-plan pipeline orchestration scaffolds with exact flag surface" {
  run bash "$create_plan_script" \
    --format pipeline \
    --execution orchestration \
    --name orch-demo \
    --workspace "$TEST_WORKSPACE" \
    --stage research \
    --stage review \
    --stage-runtime research=cursor \
    --stage-agent research=research \
    --stage-produces research=.ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md \
    --stage-runtime review=codex \
    --stage-agent review=code-review \
    --stage-requires review=.ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md \
    --stage-produces review=.ralph-workspace/artifacts/{{ARTIFACT_NS}}/review.md \
    --parallel-wave research,review
  [ "$status" -eq 0 ]

  plan_file="$(created_plan_path orch-demo)"
  grep -Fq 'execution: orchestration' "$plan_file"
  grep -Fq 'pipeline:' "$plan_file"
  grep -Fq 'parallelStages:' "$plan_file"
  grep -Fq '[research, review]' "$plan_file"
  grep -Fq 'required: true' "$plan_file"
  grep -Fq 'stage: research' "$plan_file"
  grep -Fq 'Write outputs:' "$plan_file"
  grep -Fq '.ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md' "$plan_file"
  grep -Fq 'Read input artifacts:' "$plan_file"
}

@test "create-plan rejects --kind" {
  run bash "$create_plan_script" --kind simple --workspace "$TEST_WORKSPACE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported flag: --kind"* ]]
}

@test "create-plan rejects invalid --execution" {
  run bash "$create_plan_script" --format pipeline --execution bogus --workspace "$TEST_WORKSPACE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid --execution: bogus"* ]]
}

@test "create-plan rejects invalid --format values" {
  run bash "$create_plan_script" --format bogus --workspace "$TEST_WORKSPACE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid --format: bogus"* ]]
}

@test "create-plan rejects missing required orchestration flags with clear message" {
  run bash "$create_plan_script" \
    --format pipeline \
    --execution orchestration \
    --workspace "$TEST_WORKSPACE" \
    --stage research \
    --stage-agent research=research
  [ "$status" -ne 0 ]
  [[ "$output" == *"stage research: missing --stage-runtime"* ]]
}

@test "create-plan rejects partial loop declaration" {
  run bash "$create_plan_script" \
    --format pipeline \
    --execution orchestration \
    --workspace "$TEST_WORKSPACE" \
    $(orchestration_flags) \
    --stage-loop-back review=research \
    --stage-max-iterations review=2
  [ "$status" -ne 0 ]
  [[ "$output" == *"stage review: partial loop declaration"* ]]
}

@test "create-plan rejects duplicate --stage values" {
  run bash "$create_plan_script" \
    --format pipeline \
    --execution orchestration \
    --workspace "$TEST_WORKSPACE" \
    --stage research \
    --stage research \
    --stage-runtime research=cursor \
    --stage-agent research=research \
    --stage-produces research=.ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md
  [ "$status" -ne 0 ]
  [[ "$output" == *"duplicate --stage value: research"* ]]
}

@test "create-plan rejects duplicate stage ids after sanitization" {
  run bash "$create_plan_script" \
    --format pipeline \
    --execution orchestration \
    --workspace "$TEST_WORKSPACE" \
    --stage Research \
    --stage research \
    --stage-runtime research=cursor \
    --stage-agent research=research \
    --stage-produces research=.ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md
  [ "$status" -ne 0 ]
  [[ "$output" == *"duplicate --stage value: research"* ]]
}

@test "create-plan rejects unknown orchestration flags" {
  run bash "$create_plan_script" \
    --format pipeline \
    --execution orchestration \
    --workspace "$TEST_WORKSPACE" \
    --stage-extra research
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown flag: --stage-extra"* ]]
}

@test "create-plan rejects invalid stage mapping for unknown stage" {
  run bash "$create_plan_script" \
    --format pipeline \
    --execution orchestration \
    --workspace "$TEST_WORKSPACE" \
    --stage research \
    --stage-runtime missing=cursor
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown stage id in --stage-runtime: missing"* ]]
}

@test "create-plan --interactive is the only prompt trigger for execution mode" {
  run bash "$create_plan_script" --format pipeline --name no-prompt --workspace "$TEST_WORKSPACE"
  [ "$status" -eq 0 ]
  plan_file="$(created_plan_path no-prompt)"
  grep -Fq 'execution: standard' "$plan_file"

  interactive_workspace="$(mktemp -d)"
  run bash "$create_plan_script" --format pipeline --interactive --name interactive-demo --workspace "$interactive_workspace" <<< $'1\n'
  [ "$status" -eq 0 ]
  interactive_plan="$interactive_workspace/.ralph-workspace/plans/interactive-demo.plan.md"
  grep -Fq 'execution: standard' "$interactive_plan"
  rm -rf "$interactive_workspace"
}

@test "create-plan generated artifact entries use object schema" {
  run bash "$create_plan_script" \
    --format pipeline \
    --execution orchestration \
    --name artifact-schema \
    --workspace "$TEST_WORKSPACE" \
    $(orchestration_flags)
  [ "$status" -eq 0 ]

  plan_file="$(created_plan_path artifact-schema)"
  grep -Fq 'produces:' "$plan_file"
  grep -Fq 'requires:' "$plan_file"
  grep -Fq 'path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md' "$plan_file"
  grep -Fq 'required: true' "$plan_file"
  ! grep -Fq 'produces: .ralph-workspace' "$plan_file"
}

@test "create-plan generated parallelStages uses array-of-arrays YAML" {
  run bash "$create_plan_script" \
    --format pipeline \
    --execution orchestration \
    --name parallel-schema \
    --workspace "$TEST_WORKSPACE" \
    $(orchestration_flags) \
    --parallel-wave research,review
  [ "$status" -eq 0 ]

  plan_file="$(created_plan_path parallel-schema)"
  grep -Fq 'parallelStages:' "$plan_file"
  grep -Fq '    - [research, review]' "$plan_file"
  ! grep -Fq '"parallelStages"' "$plan_file"
}

@test "create-plan generated TODO content includes read and write artifact paths" {
  run bash "$create_plan_script" \
    --format pipeline \
    --execution orchestration \
    --name todo-paths \
    --workspace "$TEST_WORKSPACE" \
    $(orchestration_flags)
  [ "$status" -eq 0 ]

  plan_file="$(created_plan_path todo-paths)"
  grep -A20 'id: review-1' "$plan_file" | grep -Fq 'Read input artifacts:'
  grep -A20 'id: review-1' "$plan_file" | grep -Fq '.ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md'
  grep -A20 'id: research-1' "$plan_file" | grep -Fq 'Write outputs:'
  grep -A20 'id: research-1' "$plan_file" | grep -Fq '.ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md'
}

@test "create-plan generated pipeline orchestration plan passes validate-plan.sh" {
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"

  run bash "$create_plan_script" \
    --format pipeline \
    --execution orchestration \
    --name validated \
    --workspace "$TEST_WORKSPACE" \
    $(orchestration_flags)
  [ "$status" -eq 0 ]

  plan_file="$(created_plan_path validated)"
  run bash "$validate_plan_script" "$plan_file"
  [ "$status" -eq 0 ]
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

@test "create-plan rejects missing --format value" {
  run bash "$create_plan_script" --format
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing value for --format"* ]]
}

@test "canonical plan templates exist" {
  [ -f "$REPO_ROOT/bundle/.ralph/plan-templates/classic.plan.template.md" ]
  [ -f "$REPO_ROOT/bundle/.ralph/plan-templates/pipeline-simple.plan.template.md" ]
  [ -f "$REPO_ROOT/bundle/.ralph/plan-templates/pipeline-orchestration.plan.template.md" ]
  [ -f "$REPO_ROOT/bundle/.ralph/plan-templates/graph-parallel-implementation.plan.template.md" ]
}
