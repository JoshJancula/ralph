#!/usr/bin/env bats

# Sequential + Dependency workflow authoring (pipeline-wizard --mode sequential|dependency).
# Prefer sourced helpers over full interactive entry for speed.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

_wtw_load_wizard() {
  SCRIPT_DIR="$REPO_ROOT/bundle/.ralph"
  export SCRIPT_DIR
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/bash-lib/ui-prompt.sh"
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/bash-lib/wizard/wizard-prompts.sh"
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/bash-lib/wizard/wizard-validation.sh"
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/bash-lib/wizard/wizard-workflow-template.sh"
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/bash-lib/wizard/wizard-pipeline-plan.sh"
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/bash-lib/plan-todo.sh"
}

_wtw_seed_stage() {
  local id="$1"
  local type="${2:-agent}"
  cp_stages+=("$id")
  cp_stage_types+=("$type")
  cp_stage_runtimes+=("")
  cp_stage_roles+=("")
  cp_stage_models+=("")
  cp_stage_native_subagents+=("")
  cp_stage_session+=("")
  cp_stage_context+=("")
  cp_stage_plan_files+=("")
  cp_stage_inline_content+=("")
  cp_stage_inline_verification+=("")
  cp_stage_depends_on+=("")
  cp_stage_policy+=("")
  cp_stage_quorum+=("")
  cp_stage_workspace_mode+=("")
  cp_stage_profile+=("")
  cp_stage_write_scopes+=("")
  cp_stage_router_allowed+=("")
  cp_stage_router_default+=("")
  cp_stage_router_terminal+=("")
  cp_stage_router_on_invalid+=("")
  cp_stage_work_source+=("")
  cp_stage_plan_from+=("")
  cp_stage_planner_max+=("")
  cp_stage_question+=("")
  cp_stage_changes_target+=("")
  cp_stage_instructions+=("")
}

# Table-driven Dependency serializer/validator round trips.
# Each row: name|seed_fn|assert_fn (seed/assert are shell function names).
_wtw_dep_round_trip_cases=(
  "prerequisites and instructions| _wtw_seed_dep_prereq | _wtw_assert_dep_prereq"
  "generated Ralph plan planFrom| _wtw_seed_dep_planfrom | _wtw_assert_dep_planfrom"
  "approval changesTarget| _wtw_seed_dep_approval | _wtw_assert_dep_approval"
  "planFrom rework loop| _wtw_seed_dep_rework | _wtw_assert_dep_rework"
  "runtime model overrides| _wtw_seed_dep_overrides | _wtw_assert_dep_overrides"
)

_wtw_seed_dep_prereq() {
  _wtw_seed_stage "research"
  _wtw_seed_stage "implement"
  cp_stage_work_source[0]="inline"
  cp_stage_instructions[0]="Investigate prerequisites with inline instructions."
  cp_stage_inline_content[0]="Investigate {{TASK}}"
  cp_stage_work_source[1]="inline"
  cp_stage_inline_content[1]="Implement after research."
  cp_stage_depends_on[1]="research"
  cp_stage_workspace_mode[1]="snapshot"
  cp_stage_write_scopes[1]="**"
}

_wtw_assert_dep_prereq() {
  local body="$1"
  [[ "$body" == *"mode: dependency"* ]]
  [[ "$body" == *"dependsOn:"* ]]
  [[ "$body" == *"- research"* ]]
  [[ "$body" == *"Investigate prerequisites with inline instructions."* ]]
  [[ "$body" == *"{{TASK}}"* ]]
  ! printf '%s' "$body" | grep -Eiq '^engine:|orchestration|humanAck'
}

_wtw_seed_dep_planfrom() {
  _wtw_seed_stage "plan-implementation"
  _wtw_seed_stage "implement"
  cp_stage_work_source[0]="inline"
  cp_stage_inline_content[0]="Plan work for {{TASK}}"
  cp_stage_planner_max[0]="40"
  cp_stage_work_source[1]="generated-plan"
  cp_stage_plan_from[1]="plan-implementation"
  cp_stage_depends_on[1]="plan-implementation"
  cp_stage_instructions[1]="Execute the generated Ralph plan TODO-by-TODO."
  cp_stage_workspace_mode[1]="snapshot"
  cp_stage_write_scopes[1]="**"
}

_wtw_assert_dep_planfrom() {
  local body="$1"
  [[ "$body" == *"planner:"* ]]
  [[ "$body" == *"outputMode: plan-file"* ]]
  [[ "$body" == *"maxTodos: 40"* ]]
  [[ "$body" == *"planFrom: plan-implementation"* ]]
  [[ "$body" == *"schema: bundle/.ralph/schemas/planner-output.schema.json"* ]]
  ! printf '%s' "$body" | grep -q 'stage: implement'
}

_wtw_seed_dep_approval() {
  _wtw_seed_stage "research"
  _wtw_seed_stage "approve-plan" "approval"
  _wtw_seed_stage "implement"
  cp_stage_work_source[0]="inline"
  cp_stage_inline_content[0]="Investigate {{TASK}}"
  wizard_create_plan_append_artifact "research" \
    ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md" "true" "produces"
  cp_stage_work_source[1]="approval"
  cp_stage_question[1]="Approve the research findings for {{TASK}}?"
  cp_stage_changes_target[1]="research"
  cp_stage_depends_on[1]="research"
  wizard_create_plan_append_artifact "approve-plan" \
    ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md" "true" "requires"
  cp_stage_work_source[2]="inline"
  cp_stage_inline_content[2]="Implement after approval."
  cp_stage_depends_on[2]="approve-plan"
}

_wtw_assert_dep_approval() {
  local body="$1"
  [[ "$body" == *"type: approval"* ]]
  [[ "$body" == *"question: Approve the research findings for {{TASK}}?"* ]]
  [[ "$body" == *"changesTarget: research"* ]]
  ! printf '%s' "$body" | grep -Eiq 'humanAck|engine:'
}

_wtw_seed_dep_rework() {
  _wtw_seed_dep_planfrom
  _wtw_seed_stage "review"
  cp_stage_work_source[2]="inline"
  cp_stage_inline_content[2]="Review the implementation for {{TASK}}"
  cp_stage_depends_on[2]="implement"
  wizard_create_plan_set_loop "review" "implement" "2" \
    ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/{{STAGE_ID}}-verdict.json"
  wizard_create_plan_append_artifact "review" \
    ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/{{STAGE_ID}}-verdict.json" "true" "produces"
}

_wtw_assert_dep_rework() {
  local body="$1"
  [[ "$body" == *"loopBackTo: implement"* ]]
  [[ "$body" == *"maxIterations: 2"* ]]
  [[ "$body" == *"planFrom: plan-implementation"* ]]
}

_wtw_seed_dep_overrides() {
  _wtw_seed_stage "research"
  cp_stage_work_source[0]="inline"
  cp_stage_inline_content[0]="Investigate {{TASK}}"
  cp_stage_instructions[0]="Use overrides carefully."
  cp_stage_runtimes[0]="claude"
  cp_stage_models[0]="sonnet"
}

_wtw_assert_dep_overrides() {
  local body="$1"
  [[ "$body" == *"runtime: claude"* ]]
  [[ "$body" == *"model: sonnet"* ]]
  [[ "$body" == *"Use overrides carefully."* ]]
}

setup() {
  WTW_TMP="$(mktemp -d)"
  _wtw_load_wizard
  wizard_sequential_reset_arrays
}

teardown() {
  rm -rf "$WTW_TMP"
}

@test "default public mode is Sequential when unanswered or empty" {
  run wizard_sequential_resolve_public_mode ""
  [ "$status" -eq 0 ]
  [ "$output" = "sequential" ]

  run env -u RALPH_CREATE_WORKFLOW_MODE bash -c '
    SCRIPT_DIR="'"$REPO_ROOT"'/bundle/.ralph"
    source "$SCRIPT_DIR/bash-lib/menu-select.sh"
    source "$SCRIPT_DIR/bash-lib/wizard/wizard-prompts.sh"
    wizard_sequential_resolve_public_mode
  '
  [ "$status" -eq 0 ]
  [ "$output" = "sequential" ]

  printf '\n' >"$WTW_TMP/mode-in.txt"
  run bash -c '
    export LC_ALL=C LANG=C RALPH_SKIP_FZF_HINT=1
    SCRIPT_DIR="'"$REPO_ROOT"'/bundle/.ralph"
    source "$SCRIPT_DIR/bash-lib/ui-prompt.sh"
    source "$SCRIPT_DIR/bash-lib/wizard/wizard-prompts.sh"
    wizard_sequential_select_public_mode 2>/dev/null
  ' <"$WTW_TMP/mode-in.txt"
  [ "$status" -eq 0 ]
  [ "$output" = "sequential" ]
}

@test "Sequential render emits kind workflow mode sequential ordered stages and TASK" {
  _wtw_seed_stage "research"
  _wtw_seed_stage "implement"
  cp_stage_work_source[0]="inline"
  cp_stage_instructions[0]="Investigate the request with inline instructions."
  cp_stage_inline_content[0]="Investigate:"
  cp_stage_runtimes[0]="cursor"
  cp_stage_work_source[1]="inline"
  cp_stage_inline_content[1]="Implement the approved change."
  cp_stage_depends_on[1]="research"
  cp_stage_runtimes[1]="claude"
  cp_stage_models[1]="sonnet"

  run wizard_render_sequential_workflow "seq-demo" "Sequential ordered stages demo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"kind: workflow"* ]]
  [[ "$output" == *"mode: sequential"* ]]
  [[ "$output" == *"id: research"* ]]
  [[ "$output" == *"id: implement"* ]]
  [[ "$output" == *"instructions: |"* ]]
  [[ "$output" == *"Investigate the request with inline instructions."* ]]
  [[ "$output" == *"{{TASK}}"* ]]
  [[ "$output" == *"runtime: claude"* ]]
  [[ "$output" == *"model: sonnet"* ]]
  ! printf '%s' "$output" | grep -Eiq 'engine:|orchestration|humanAck|ORCHESTRATOR_HUMAN_ACK'

  printf '%s\n' "$output" >"$WTW_TMP/seq-demo.workflow.md"
  run plan_workflow_validate "$WTW_TMP/seq-demo.workflow.md"
  [ "$status" -eq 0 ]
}

@test "parallel waves render under Sequential mode without internal vocabulary" {
  _wtw_seed_stage "a"
  _wtw_seed_stage "b"
  _wtw_seed_stage "c"
  cp_stage_work_source[0]="inline"
  cp_stage_work_source[1]="inline"
  cp_stage_work_source[2]="inline"
  cp_stage_inline_content[0]="Do A for {{TASK}}"
  cp_stage_inline_content[1]="Do B for {{TASK}}"
  cp_stage_inline_content[2]="Do C for {{TASK}}"
  cp_parallel_waves=("a,b" "c")

  run wizard_render_sequential_workflow "waves-demo" "Parallel waves demo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mode: sequential"* ]]
  [[ "$output" == *"parallelStages:"* ]]
  [[ "$output" == *"- [a, b]"* ]]
  [[ "$output" == *"- [c]"* ]]
  ! printf '%s' "$output" | grep -Eiq 'orchestration|graph mode|humanAck'
}

@test "inline action work source keeps bounded instructions and TASK" {
  _wtw_seed_stage "investigate"
  cp_stage_work_source[0]="inline"
  cp_stage_instructions[0]="One bounded inline action only."
  cp_stage_inline_content[0]="Summarize findings."

  run wizard_render_sequential_workflow "inline-demo" "Inline action demo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"One bounded inline action only."* ]]
  [[ "$output" == *"Summarize findings."* ]]
  [[ "$output" == *"{{TASK}}"* ]]
  ! printf '%s' "$output" | grep -q 'planFile:'
  ! printf '%s' "$output" | grep -q 'planFrom:'
  ! printf '%s' "$output" | grep -q 'planner:'
}

@test "static plan work source emits planFile only" {
  _wtw_seed_stage "implement"
  cp_stage_work_source[0]="static-plan"
  cp_stage_plan_files[0]=".ralph-workspace/plans/existing-impl.plan.md"
  cp_stage_runtimes[0]="cursor"

  run wizard_render_sequential_workflow "static-demo" "Static plan demo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"planFile: .ralph-workspace/plans/existing-impl.plan.md"* ]]
  ! printf '%s' "$output" | grep -q 'planFrom:'
  ! printf '%s' "$output" | grep -q 'planner:'
  # Static planFile stages are plan-backed: no authored TODO for that stage.
  ! printf '%s' "$output" | grep -q 'stage: implement'
}

@test "generated Ralph plan emits planner planFrom schema exactly" {
  _wtw_seed_stage "plan-implementation"
  _wtw_seed_stage "implement"
  cp_stage_work_source[0]="inline"
  cp_stage_inline_content[0]="Plan work for:"
  cp_stage_planner_max[0]="40"
  cp_stage_work_source[1]="generated-plan"
  cp_stage_plan_from[1]="plan-implementation"
  cp_stage_depends_on[1]="plan-implementation"
  cp_stage_runtimes[1]="cursor"
  cp_stage_instructions[1]="Execute the generated Ralph plan TODO-by-TODO."

  run wizard_render_sequential_workflow "gen-demo" "Generated Ralph plan demo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"planner:"* ]]
  [[ "$output" == *"outputMode: plan-file"* ]]
  [[ "$output" == *"maxTodos: 40"* ]]
  [[ "$output" == *"planFrom: plan-implementation"* ]]
  [[ "$output" == *"schema: bundle/.ralph/schemas/planner-output.schema.json"* ]]
  [[ "$output" == *"Execute the generated Ralph plan TODO-by-TODO."* ]]
  [[ "$output" == *"{{TASK}}"* ]]
  # Consumer has no authored TODO.
  ! printf '%s' "$output" | grep -q 'stage: implement'

  printf '%s\n' "$output" >"$WTW_TMP/gen-demo.workflow.md"
  run plan_workflow_validate "$WTW_TMP/gen-demo.workflow.md"
  [ "$status" -eq 0 ]
}

@test "approval authoring emits question changesTarget and documents decisions" {
  _wtw_seed_stage "research"
  _wtw_seed_stage "approve-plan"
  _wtw_seed_stage "implement"
  cp_stage_work_source[0]="inline"
  cp_stage_inline_content[0]="Investigate {{TASK}}"
  wizard_create_plan_append_artifact "research" \
    ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md" "true" "produces"

  cp_stage_types[1]="approval"
  cp_stage_work_source[1]="approval"
  cp_stage_question[1]="Approve the research findings for {{TASK}}?"
  cp_stage_changes_target[1]="research"
  cp_stage_depends_on[1]="research"
  wizard_create_plan_append_artifact "approve-plan" \
    ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md" "true" "requires"

  cp_stage_work_source[2]="inline"
  cp_stage_inline_content[2]="Implement after approval."
  cp_stage_depends_on[2]="approve-plan"

  run wizard_sequential_print_approval_decisions
  [ "$status" -eq 0 ]
  [[ "$output" == *"approve"* ]]
  [[ "$output" == *"request-changes"* ]]
  [[ "$output" == *"cancel"* ]]
  [[ "$output" == *"changesTarget"* ]]

  run wizard_render_sequential_workflow "approval-demo" "Approval changesTarget demo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"type: approval"* ]]
  [[ "$output" == *"question: Approve the research findings for {{TASK}}?"* ]]
  [[ "$output" == *"changesTarget: research"* ]]
  ! printf '%s' "$output" | grep -Eiq 'humanAck|checkpoint|orchestration'

  printf '%s\n' "$output" >"$WTW_TMP/approval-demo.workflow.md"
  run plan_workflow_validate "$WTW_TMP/approval-demo.workflow.md"
  [ "$status" -eq 0 ]
}

@test "work source menu offers inline action static plan and generated Ralph plan" {
  printf '1\n' >"$WTW_TMP/ws-in.txt"
  run bash -c '
    export LC_ALL=C LANG=C RALPH_SKIP_FZF_HINT=1
    SCRIPT_DIR="'"$REPO_ROOT"'/bundle/.ralph"
    source "$SCRIPT_DIR/bash-lib/ui-prompt.sh"
    source "$SCRIPT_DIR/bash-lib/wizard/wizard-prompts.sh"
    wizard_sequential_select_work_source research 2>/dev/null
  ' <"$WTW_TMP/ws-in.txt"
  [ "$status" -eq 0 ]
  [ "$output" = "bounded inline action" ]

  printf '2\n' >"$WTW_TMP/ws-in2.txt"
  run bash -c '
    export LC_ALL=C LANG=C RALPH_SKIP_FZF_HINT=1
    SCRIPT_DIR="'"$REPO_ROOT"'/bundle/.ralph"
    source "$SCRIPT_DIR/bash-lib/ui-prompt.sh"
    source "$SCRIPT_DIR/bash-lib/wizard/wizard-prompts.sh"
    wizard_sequential_select_work_source research 2>/dev/null
  ' <"$WTW_TMP/ws-in2.txt"
  [ "$status" -eq 0 ]
  [ "$output" = "existing static plan file" ]

  printf '3\n' >"$WTW_TMP/ws-in3.txt"
  run bash -c '
    export LC_ALL=C LANG=C RALPH_SKIP_FZF_HINT=1
    SCRIPT_DIR="'"$REPO_ROOT"'/bundle/.ralph"
    source "$SCRIPT_DIR/bash-lib/ui-prompt.sh"
    source "$SCRIPT_DIR/bash-lib/wizard/wizard-prompts.sh"
    wizard_sequential_select_work_source research 2>/dev/null
  ' <"$WTW_TMP/ws-in3.txt"
  [ "$status" -eq 0 ]
  [ "$output" = "generated Ralph plan" ]
}

@test "pipeline-wizard --mode sequential authors ordered stages via stdin" {
  WTW_WORKSPACE="$(mktemp -d)"
  # name, description (accept default), defaults n,
  # stages, research config, implement config, parallel n,
  # planInput n, mutating-without-plan y, confirm y
  cat >"$WTW_WORKSPACE/input.txt" <<'EOF'
seq-ordered

n
research,implement
1
1
n
Investigate with inline instructions.
Investigate {{TASK}}
Confirm research output exists


1
1
n

Implement {{TASK}}
Confirm implementation handoff


n
n
y
y
EOF

  run bash -c '
    export LC_ALL=C LANG=C RALPH_SKIP_FZF_HINT=1
    cd "$1" && tr -d "\r" < "$1/input.txt" | bash "'"$REPO_ROOT"'/bundle/.ralph/pipeline-wizard.sh" --mode sequential
  ' _ "$WTW_WORKSPACE"
  [ "$status" -eq 0 ]

  workflow="$WTW_WORKSPACE/.ralph-workspace/workflows/seq-ordered.workflow.md"
  [ -f "$workflow" ]
  run grep -E '^(kind|mode):' "$workflow"
  [[ "$output" == *"kind: workflow"* ]]
  [[ "$output" == *"mode: sequential"* ]]
  run grep -F '{{TASK}}' "$workflow"
  [ "$status" -eq 0 ]
  ! grep -Eiq 'engine:|orchestration|humanAck' "$workflow"

  source "$REPO_ROOT/bundle/.ralph/bash-lib/plan-todo.sh"
  run plan_workflow_validate "$workflow"
  [ "$status" -eq 0 ]

  rm -rf "$WTW_WORKSPACE"
}

@test "Dependency node types contract lists approval and supervisors" {
  contract="$REPO_ROOT/bundle/.ralph/schemas/graph-authoring-contract.json"
  [ -f "$contract" ]
  run jq -r '.nodeTypes | keys[]' "$contract"
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent"* ]]
  [[ "$output" == *"approval"* ]]
  [[ "$output" == *"gate"* ]]
  [[ "$output" == *"checkpoint"* ]]
  [[ "$output" == *"consensus"* ]]
  [[ "$output" == *"integrate"* ]]
  [[ "$output" == *"router"* ]]
  [[ "$output" == *"join"* ]]
  run jq -r '.operatorTopics.rework.help' "$contract"
  [ "$status" -eq 0 ]
  [[ "$output" == *"planFrom"* ]]
  [[ "$output" == *"fresh control copy"* ]]
}

@test "Dependency render emits mode dependency prerequisites instructions and TASK" {
  _wtw_seed_dep_prereq
  run wizard_render_dependency_workflow "dep-prereq" "Dependency prerequisites demo"
  [ "$status" -eq 0 ]
  _wtw_assert_dep_prereq "$output"
  printf '%s\n' "$output" >"$WTW_TMP/dep-prereq.workflow.md"
  run plan_workflow_validate "$WTW_TMP/dep-prereq.workflow.md"
  [ "$status" -eq 0 ]
}

@test "Dependency generated Ralph plan emits planner planFrom schema" {
  _wtw_seed_dep_planfrom
  run wizard_render_dependency_workflow "dep-gen" "Dependency generated Ralph plan demo"
  [ "$status" -eq 0 ]
  _wtw_assert_dep_planfrom "$output"
  printf '%s\n' "$output" >"$WTW_TMP/dep-gen.workflow.md"
  run plan_workflow_validate "$WTW_TMP/dep-gen.workflow.md"
  [ "$status" -eq 0 ]
}

@test "Dependency approval authoring emits question changesTarget without checkpoint" {
  _wtw_seed_dep_approval
  run wizard_sequential_print_approval_decisions
  [ "$status" -eq 0 ]
  [[ "$output" == *"approve"* ]]
  [[ "$output" == *"request-changes"* ]]
  [[ "$output" == *"cancel"* ]]
  [[ "$output" == *"changesTarget"* ]]

  run wizard_render_dependency_workflow "dep-approval" "Dependency approval changesTarget demo"
  [ "$status" -eq 0 ]
  _wtw_assert_dep_approval "$output"
  ! printf '%s' "$output" | grep -Eiq 'type: checkpoint'
  printf '%s\n' "$output" >"$WTW_TMP/dep-approval.workflow.md"
  run plan_workflow_validate "$WTW_TMP/dep-approval.workflow.md"
  [ "$status" -eq 0 ]
}

@test "Dependency planFrom rework emits loop and fresh-control-copy guidance" {
  run wizard_dependency_explain_planfrom_rework
  [ "$status" -eq 0 ]
  [[ "$output" == *"fresh control copy"* ]]
  [[ "$output" == *"planFrom"* ]]
  [[ "$output" == *"Static planFile"* ]]

  _wtw_seed_dep_rework
  run wizard_render_dependency_workflow "dep-rework" "Dependency planFrom rework demo"
  [ "$status" -eq 0 ]
  _wtw_assert_dep_rework "$output"
  printf '%s\n' "$output" >"$WTW_TMP/dep-rework.workflow.md"
  run plan_workflow_validate "$WTW_TMP/dep-rework.workflow.md"
  [ "$status" -eq 0 ]
}

@test "static plan rejection blocks rework target and approval cannot be rework target" {
  _wtw_seed_stage "static-impl"
  cp_stage_work_source[0]="static-plan"
  cp_stage_plan_files[0]=".ralph-workspace/plans/existing.plan.md"
  run wizard_dependency_validate_rework_target "static-impl"
  [ "$status" -ne 0 ]
  [[ "$output" == *"static planFile rework rejected"* ]]

  wizard_sequential_reset_arrays
  _wtw_seed_stage "research"
  _wtw_seed_stage "approve-plan" "approval"
  cp_stage_work_source[1]="approval"
  cp_stage_question[1]="Approve?"
  cp_stage_changes_target[1]="research"
  run wizard_dependency_validate_rework_target "approve-plan"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot be a rework target"* ]]
}

@test "Dependency serializer validator round trips are table-driven" {
  local row name seed_fn assert_fn
  for row in "${_wtw_dep_round_trip_cases[@]}"; do
    IFS='|' read -r name seed_fn assert_fn <<< "$row"
    name="$(printf '%s' "$name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    seed_fn="$(printf '%s' "$seed_fn" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    assert_fn="$(printf '%s' "$assert_fn" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    wizard_sequential_reset_arrays
    "$seed_fn"
    run wizard_render_dependency_workflow "rt-${name// /-}" "round trip ${name}"
    [ "$status" -eq 0 ]
    "$assert_fn" "$output"
    printf '%s\n' "$output" >"$WTW_TMP/rt.workflow.md"
    run plan_workflow_validate "$WTW_TMP/rt.workflow.md"
    [ "$status" -eq 0 ]
  done
}

@test "Dependency work source menu matches Sequential exact choices" {
  printf '1\n' >"$WTW_TMP/dep-ws.txt"
  run bash -c '
    export LC_ALL=C LANG=C RALPH_SKIP_FZF_HINT=1
    SCRIPT_DIR="'"$REPO_ROOT"'/bundle/.ralph"
    source "$SCRIPT_DIR/bash-lib/ui-prompt.sh"
    source "$SCRIPT_DIR/bash-lib/wizard/wizard-prompts.sh"
    wizard_sequential_select_work_source implement 2>/dev/null
  ' <"$WTW_TMP/dep-ws.txt"
  [ "$status" -eq 0 ]
  [ "$output" = "bounded inline action" ]
}

@test "project scope resolves to state-root workflows by default" {
  unset RALPH_CREATE_WORKFLOW_GLOBAL
  run wizard_workflow_resolve_create_dest "proj-demo" "$WTW_TMP"
  [ "$status" -eq 0 ]
  IFS=$'\t' read -r scope plans_dir dest <<< "$output"
  [ "$scope" = "project" ]
  [ "$plans_dir" = "$WTW_TMP/.ralph-workspace/workflows" ]
  [ "$dest" = "$WTW_TMP/.ralph-workspace/workflows/proj-demo.workflow.md" ]
}

@test "global scope resolves under RALPH_HOME workflows" {
  export RALPH_CREATE_WORKFLOW_GLOBAL=1
  export RALPH_HOME="$WTW_TMP/ralph-home"
  run wizard_workflow_resolve_create_dest "glob-demo" "$WTW_TMP"
  [ "$status" -eq 0 ]
  IFS=$'\t' read -r scope plans_dir dest <<< "$output"
  [ "$scope" = "global" ]
  [ "$plans_dir" = "$WTW_TMP/ralph-home/workflows" ]
  [ "$dest" = "$WTW_TMP/ralph-home/workflows/glob-demo.workflow.md" ]
  unset RALPH_CREATE_WORKFLOW_GLOBAL RALPH_HOME
}

@test "defaults runtime and model emit with stage overrides" {
  _wtw_seed_stage "research"
  _wtw_seed_stage "implement"
  cp_defaults_runtime="cursor"
  cp_defaults_model="auto"
  cp_stage_work_source[0]="inline"
  cp_stage_inline_content[0]="Investigate {{TASK}}"
  cp_stage_work_source[1]="inline"
  cp_stage_inline_content[1]="Implement {{TASK}}"
  cp_stage_runtimes[1]="claude"
  cp_stage_models[1]="sonnet"

  run wizard_render_sequential_workflow "defaults-demo" "Defaults and overrides"
  [ "$status" -eq 0 ]
  [[ "$output" == *"defaults:"* ]]
  [[ "$output" == *"runtime: cursor"* ]]
  [[ "$output" == *"model: auto"* ]]
  [[ "$output" == *"runtime: claude"* ]]
  [[ "$output" == *"model: sonnet"* ]]
  printf '%s\n' "$output" >"$WTW_TMP/defaults-demo.workflow.md"
  run plan_workflow_validate "$WTW_TMP/defaults-demo.workflow.md"
  [ "$status" -eq 0 ]
}

@test "plan input optional designates eligible stage and explains --plan" {
  _wtw_seed_dep_planfrom
  cp_plan_input_stage="implement"
  cp_plan_input_required="false"

  run wizard_workflow_plan_input_eligible_csv 0
  [ "$status" -eq 0 ]
  [[ "$output" == *"implement"* ]]

  run wizard_workflow_explain_plan_command "opt-input" 0
  [ "$status" -eq 0 ]
  [[ "$output" == *"--plan"* ]]
  [[ "$output" == *"ralph workflow start opt-input"* ]]

  run wizard_render_dependency_workflow "opt-input" "Optional planInput demo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"planInput:"* ]]
  [[ "$output" == *"stage: implement"* ]]
  ! printf '%s' "$output" | grep -q 'required: true'
  [[ "$output" == *"planFrom: plan-implementation"* ]]
  printf '%s\n' "$output" >"$WTW_TMP/opt-input.workflow.md"
  run plan_workflow_validate "$WTW_TMP/opt-input.workflow.md"
  [ "$status" -eq 0 ]
}

@test "required input planInput may omit planFrom and explains --plan" {
  wizard_sequential_reset_arrays
  _wtw_seed_stage "implement"
  _wtw_seed_stage "review"
  # Required planInput consumer: no authored TODOs / no planFrom.
  cp_stage_work_source[0]=""
  cp_stage_inline_content[0]=""
  cp_stage_work_source[1]="inline"
  cp_stage_inline_content[1]="Review the implementation for {{TASK}}"
  cp_stage_depends_on[1]="implement"
  cp_plan_input_stage="implement"
  cp_plan_input_required="true"
  wizard_create_plan_append_artifact "implement" \
    ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md" "true" "produces"

  run wizard_workflow_plan_input_eligible_csv 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"implement"* ]]

  run wizard_workflow_explain_plan_command "req-input" 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"--plan <leaf-plan-path>"* ]]

  run wizard_render_sequential_workflow "req-input" "Required planInput demo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"planInput:"* ]]
  [[ "$output" == *"stage: implement"* ]]
  [[ "$output" == *"required: true"* ]]
  ! printf '%s' "$output" | grep -q 'planFrom:'
  ! printf '%s' "$output" | grep -q 'stage: implement'
  printf '%s\n' "$output" >"$WTW_TMP/req-input.workflow.md"
  run plan_workflow_validate "$WTW_TMP/req-input.workflow.md"
  [ "$status" -eq 0 ]
}

@test "approval review final review lists gate changesTarget and handoffs" {
  _wtw_seed_dep_planfrom
  _wtw_seed_stage "approve-plan" "approval"
  cp_stage_work_source[2]="approval"
  cp_stage_question[2]="Approve the implementation plan?"
  cp_stage_changes_target[2]="plan-implementation"
  cp_stage_depends_on[2]="implement"
  cp_defaults_runtime="cursor"
  cp_plan_input_stage="implement"
  cp_plan_input_required="false"

  run wizard_workflow_print_final_review "project" "$WTW_TMP/review.workflow.md" "dependency"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Scope: project"* ]]
  [[ "$output" == *"Mode: dependency"* ]]
  [[ "$output" == *"Defaults: runtime=cursor"* ]]
  [[ "$output" == *"plan-implementation (maxTodos=40) -> planFrom implement"* ]]
  [[ "$output" == *"maxTodos=40"* ]]
  [[ "$output" == *"stage=implement required=false"* ]]
  [[ "$output" == *"approve-plan: changesTarget=plan-implementation"* ]]
  [[ "$output" == *"reusable workflow policy"* ]]
  [[ "$output" == *"Per-run generated plans"* ]]
}

@test "collision refuses existing target before write" {
  mkdir -p "$WTW_TMP/workflows"
  dest="$WTW_TMP/workflows/collision-demo.workflow.md"
  printf 'existing\n' >"$dest"
  _wtw_seed_stage "research"
  cp_stage_work_source[0]="inline"
  cp_stage_inline_content[0]="Investigate {{TASK}}"

  run wizard_workflow_atomic_validate_and_rename "$dest" \
    wizard_render_sequential_workflow "collision-demo" "Collision demo"
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]]
  [ "$(cat "$dest")" = "existing" ]
}

@test "atomic write uses same-directory temp validate and rename" {
  mkdir -p "$WTW_TMP/workflows"
  dest="$WTW_TMP/workflows/atomic-demo.workflow.md"
  _wtw_seed_stage "research"
  cp_stage_work_source[0]="inline"
  cp_stage_inline_content[0]="Investigate {{TASK}}"

  run wizard_workflow_atomic_validate_and_rename "$dest" \
    wizard_render_sequential_workflow "atomic-demo" "Atomic write demo"
  [ "$status" -eq 0 ]
  [ -f "$dest" ]
  # No leftover same-directory temp siblings.
  shopt -s nullglob
  leftovers=( "$WTW_TMP/workflows/.atomic-demo.workflow.md."* )
  shopt -u nullglob
  [ "${#leftovers[@]}" -eq 0 ]
  run plan_workflow_validate "$dest"
  [ "$status" -eq 0 ]
  [[ "$(cat "$dest")" == *"kind: workflow"* ]]
}

@test "closed stdin exits 1 with interactive-terminal explanation" {
  run bash -c '
    export LC_ALL=C LANG=C RALPH_SKIP_FZF_HINT=1
    exec </dev/null
    bash "'"$REPO_ROOT"'/bundle/.ralph/workflow-wizard.sh" --mode sequential
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"interactive terminal"* ]]
  [[ "$output" == *"Closed stdin"* ]]
}
