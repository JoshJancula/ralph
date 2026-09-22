#!/usr/bin/env bats

# Inline workflow stage instructions: schema, materialize carry, prompt
# injection (WORKFLOW_STAGE_INSTRUCTIONS), and bundled role-guidance fold.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/plan-todo.sh"

setup() {
  TMPD="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMPD"
  unset RALPH_WORKFLOW_STAGE_INSTRUCTIONS
}

# Write a minimal graph workflow with one agent stage. Extra stage YAML is
# inserted under the stage (already indented 6 spaces in callers).
write_agent_workflow() {
  local path="$1"
  local stage_extra="${2:-}"
  {
    printf '%s\n' \
      '---' \
      'name: instructions-schema' \
      'kind: workflow' \
      'engine: graph' \
      'pipeline:' \
      '  stages:' \
      '    - id: research' \
      '      runtime: cursor'
    if [ -n "$stage_extra" ]; then
      printf '%s\n' "$stage_extra"
    fi
    printf '%s\n' \
      'todos:' \
      '  - id: research-1' \
      '    stage: research' \
      '    content: Investigate {{TASK}}' \
      '    status: pending' \
      '---'
  } >"$path"
}

write_supervisor_workflow() {
  local path="$1"
  local stage_type="$2"
  local stage_extra="$3"
  {
    printf '%s\n' \
      '---' \
      'name: instructions-supervisor' \
      'kind: workflow' \
      'engine: graph' \
      'pipeline:' \
      '  stages:' \
      '    - id: research' \
      '      runtime: cursor' \
      '    - id: control' \
      "      type: ${stage_type}" \
      '      dependsOn:' \
      '        - research'
    if [ -n "$stage_extra" ]; then
      printf '%s\n' "$stage_extra"
    fi
    printf '%s\n' \
      'todos:' \
      '  - id: research-1' \
      '    stage: research' \
      '    content: Investigate {{TASK}}' \
      '    status: pending' \
      '---'
  } >"$path"
}

run_case() {
  local case_id="$1" kind="$2" expect="$3" needle="$4" payload="$5"
  local wf="$TMPD/${case_id}.workflow.md"

  case "$kind" in
    agent)
      write_agent_workflow "$wf" "$payload"
      ;;
    include-key)
      write_agent_workflow "$wf" "      ${payload}: roles/research.md"
      ;;
    supervisor:*)
      write_supervisor_workflow "$wf" "${kind#supervisor:}" "$payload"
      ;;
    *)
      echo "unknown case kind: $kind" >&2
      return 2
      ;;
  esac

  run plan_workflow_validate "$wf"
  if [ "$expect" = "pass" ]; then
    [ "$status" -eq 0 ]
  else
    [ "$status" -ne 0 ]
    [[ "$output" == *"$needle"* ]]
  fi
}

@test "schema accepts agent stage instructions scalar" {
  run_case scalar-agent agent pass "" "      instructions: Focus on root cause evidence."
}

@test "schema scalar text is preserved exactly through parse and instantiate" {
  local wf="$TMPD/scalar-preserve.workflow.md"
  local out="$TMPD/scalar-preserve.plan.md"
  write_agent_workflow "$wf" '      instructions: Focus on root cause evidence.'
  run plan_workflow_validate "$wf"
  [ "$status" -eq 0 ]
  run plan_workflow_instantiate "$wf" "task-one" "$out"
  [ "$status" -eq 0 ]
  grep -qx '      instructions: Focus on root cause evidence.' "$out"
}

@test "schema block scalar text is preserved exactly through parse and instantiate" {
  local wf="$TMPD/block-preserve.workflow.md"
  local out="$TMPD/block-preserve.plan.md"
  write_agent_workflow "$wf" "$(printf '%s\n' \
    '      instructions: |' \
    '        Line one with exact text' \
    '        Preserve exact spacing & $VARS' \
    '        trailing line')"
  run plan_workflow_validate "$wf"
  [ "$status" -eq 0 ]
  run plan_workflow_instantiate "$wf" "task-two" "$out"
  [ "$status" -eq 0 ]
  grep -qx '        Line one with exact text' "$out"
  grep -qx '        Preserve exact spacing & $VARS' "$out"
  grep -qx '        trailing line' "$out"
}

@test "schema rejects empty instructions scalar" {
  run_case empty-scalar agent fail "must be non-empty text" '      instructions: ""'
}

@test "schema rejects empty bare instructions" {
  run_case empty-bare agent fail "must be non-empty text" '      instructions:'
}

@test "schema rejects instructions list" {
  local wf="$TMPD/list.workflow.md"
  write_agent_workflow "$wf" "$(printf '%s\n' \
    '      instructions:' \
    '        - first' \
    '        - second')"
  run plan_workflow_validate "$wf"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a list or map"* ]]
}

@test "schema rejects instructions map" {
  local wf="$TMPD/map.workflow.md"
  write_agent_workflow "$wf" "$(printf '%s\n' \
    '      instructions:' \
    '        path: roles/research.md' \
    '        include: true')"
  run plan_workflow_validate "$wf"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a list or map"* ]]
}

@test "schema rejects instructionsPath include key" {
  run_case include-path include-key fail "path/include keys are not allowed" instructionsPath
}

@test "schema rejects instructionsInclude include key" {
  run_case include-include include-key fail "path/include keys are not allowed" instructionsInclude
}

@test "schema rejects supervisor instructions on join" {
  run_case supervisor-join supervisor:join fail "do not take instructions" '      instructions: not for supervisors'
}

@test "schema rejects supervisor instructions on gate" {
  run_case supervisor-gate supervisor:gate fail "do not take instructions" '      instructions: not for supervisors'
}

@test "schema rejects supervisor instructions on checkpoint" {
  run_case supervisor-checkpoint supervisor:checkpoint fail "do not take instructions" '      instructions: not for supervisors'
}

@test "schema rejects supervisor instructions on router" {
  local wf="$TMPD/router.workflow.md"
  write_supervisor_workflow "$wf" router "$(printf '%s\n' \
    '      instructions: not for supervisors' \
    '      router:' \
    '        allowedTargets:' \
    '          - research' \
    '        defaultTarget: research')"
  run plan_workflow_validate "$wf"
  [ "$status" -ne 0 ]
  [[ "$output" == *"do not take instructions"* ]]
}

@test "schema rejects supervisor instructions on integrate" {
  run_case supervisor-integrate supervisor:integrate fail "do not take instructions" '      instructions: not for supervisors'
}

@test "schema accepts consensus-voter instructions and rejects consensus container instructions" {
  local wf_ok="$TMPD/voter-ok.workflow.md"
  local wf_bad="$TMPD/consensus-bad.workflow.md"
  cat >"$wf_ok" <<'EOF'
---
name: voter-instructions
kind: workflow
engine: graph
pipeline:
  stages:
    - id: review
      type: consensus
      runtime: cursor
      voters:
        - id: a
          runtime: cursor
          instructions: Vote with evidence only.
        - id: b
          runtime: claude
          instructions: |
            Independent review.
            No shared session.
todos:
  - id: review-1
    stage: review
    content: Review {{TASK}}
    status: pending
---
EOF
  run plan_workflow_validate "$wf_ok"
  [ "$status" -eq 0 ]

  cat >"$wf_bad" <<'EOF'
---
name: consensus-instructions
kind: workflow
engine: graph
pipeline:
  stages:
    - id: review
      type: consensus
      runtime: cursor
      instructions: container must not get this
      voters:
        - id: a
          runtime: cursor
        - id: b
          runtime: claude
todos:
  - id: review-1
    stage: review
    content: Review {{TASK}}
    status: pending
---
EOF
  run plan_workflow_validate "$wf_bad"
  [ "$status" -ne 0 ]
  [[ "$output" == *"do not take instructions"* ]]
}

@test "schema accepts repair diagnose instructions and rejects repair integrate instructions" {
  local wf_ok="$TMPD/repair-ok.workflow.md"
  local wf_bad="$TMPD/repair-bad.workflow.md"
  cat >"$wf_ok" <<'EOF'
---
name: repair-instructions
kind: workflow
engine: graph
pipeline:
  stages:
    - id: research
      runtime: cursor
  repairRounds:
    id: epoch
    rounds: 1
    dependsOn:
      - research
    integrate: {}
    gate:
      profile: unit
    diagnose:
      runtime: cursor
      instructions: Diagnose with the analyzer first.
    reintegrate: {}
    lanes:
      - id: lane-a
        runtime: cursor
        content: Fix the failing scope
        instructions: Repair only the declared writeScopes.
  verificationProfiles:
    - name: unit
      steps:
        - name: noop
          command: true
todos:
  - id: research-1
    stage: research
    content: Investigate {{TASK}}
    status: pending
---
EOF
  run plan_workflow_validate "$wf_ok"
  [ "$status" -eq 0 ]

  cat >"$wf_bad" <<'EOF'
---
name: repair-integrate-instructions
kind: workflow
engine: graph
pipeline:
  stages:
    - id: research
      runtime: cursor
  repairRounds:
    id: epoch
    rounds: 0
    dependsOn:
      - research
    integrate:
      instructions: supervisors cannot take this
    gate:
      profile: unit
  verificationProfiles:
    - name: unit
      steps:
        - name: noop
          command: true
todos:
  - id: research-1
    stage: research
    content: Investigate {{TASK}}
    status: pending
---
EOF
  run plan_workflow_validate "$wf_bad"
  [ "$status" -ne 0 ]
  [[ "$output" == *"do not take instructions"* ]]
}

# --- materialize / prompt / planFile / no leakage ---------------------------

@test "materialize carries per-stage instructions into orch JSON without source mutation" {
  local wf="$TMPD/mat-two.workflow.md"
  local out="$TMPD/mat-two.plan.md"
  local src_before src_after orch_json
  cat >"$wf" <<'EOF'
---
name: mat-two
kind: workflow
engine: orchestration
pipeline:
  stages:
    - id: research
      runtime: cursor
      instructions: Focus on root cause only.
    - id: implement
      runtime: cursor
      instructions: |
        Change only the failing scope.
        Do not widen the diff.
todos:
  - id: research-1
    stage: research
    content: Investigate {{TASK}}
    status: pending
  - id: implement-1
    stage: implement
    content: Fix {{TASK}}
    status: pending
---
EOF
  src_before="$(cat "$wf")"
  run plan_workflow_validate "$wf"
  [ "$status" -eq 0 ]
  run plan_workflow_instantiate "$wf" "the-bug" "$out"
  [ "$status" -eq 0 ]
  src_after="$(cat "$wf")"
  [ "$src_before" = "$src_after" ]

  orch_json="$(plan_pipeline_orch_json "$out")"
  [ "$(printf '%s' "$orch_json" | jq -r '.stages[0].instructions')" = "Focus on root cause only." ]
  [ "$(printf '%s' "$orch_json" | jq -r '.stages[1].instructions')" = $'Change only the failing scope.\nDo not widen the diff.' ]
  [ "$(printf '%s' "$orch_json" | jq -r '.stages[0] | has("_inlineTodos")')" = "true" ]
  [ "$(printf '%s' "$orch_json" | jq -r '.stages[1] | has("_inlineTodos")')" = "true" ]
}

@test "planFile stage materialize carries instructions and leaves planFile untouched" {
  local child="$TMPD/child.plan.md"
  local wf="$TMPD/planfile.workflow.md"
  local out="$TMPD/planfile.plan.md"
  local child_before child_after orch_json
  cat >"$child" <<'EOF'
---
name: child
overview: child plan
execution: standard
todos:
  - id: t1
    content: Do the thing
    verification: Confirm done
    status: pending
isProject: false
---
EOF
  child_before="$(cat "$child")"
  cat >"$wf" <<'EOF'
---
name: planfile-mat
kind: workflow
engine: orchestration
pipeline:
  stages:
    - id: research
      runtime: cursor
      instructions: Use the planFile path only.
      planFile: child.plan.md
todos:
  - id: research-1
    stage: research
    content: Run nested plan for {{TASK}}
    status: pending
---
EOF
  run plan_workflow_validate "$wf"
  [ "$status" -eq 0 ]
  run plan_workflow_instantiate "$wf" "task" "$out"
  [ "$status" -eq 0 ]
  child_after="$(cat "$child")"
  [ "$child_before" = "$child_after" ]
  ! grep -q "WORKFLOW_STAGE_INSTRUCTIONS" "$child"
  ! grep -q "Use the planFile path only" "$child"

  orch_json="$(plan_pipeline_orch_json "$out")"
  [ "$(printf '%s' "$orch_json" | jq -r '.stages[0].instructions')" = "Use the planFile path only." ]
  [ "$(printf '%s' "$orch_json" | jq -r '.stages[0].plan')" = "child.plan.md" ]
  [ "$(printf '%s' "$orch_json" | jq -r '.stages[0] | has("_inlineTodos")')" = "false" ]
}

@test "prompt block renders delimited WORKFLOW_STAGE_INSTRUCTIONS before TODO content" {
  local block prompt
  unset RALPH_WORKFLOW_STAGE_INSTRUCTIONS
  block="$(ralph_workflow_stage_instructions_prompt_block "")"
  [ -z "$block" ]

  RALPH_WORKFLOW_STAGE_INSTRUCTIONS=$'Stage guidance line one.\nLine two.'
  block="$(ralph_workflow_stage_instructions_prompt_block)"
  [[ "$block" == *"<!-- WORKFLOW_STAGE_INSTRUCTIONS: START -->"* ]]
  [[ "$block" == *"Stage guidance line one."* ]]
  [[ "$block" == *"Line two."* ]]
  [[ "$block" == *"<!-- WORKFLOW_STAGE_INSTRUCTIONS: END -->"* ]]

  prompt="${block}"$'\n\n'"Complete exactly this TODO and nothing else:"$'\n\n'"**TODO (line 4):** Do the work"
  local i_start i_todo
  i_start="${prompt%%<!-- WORKFLOW_STAGE_INSTRUCTIONS: START -->*}"
  i_todo="${prompt%%\*\*TODO \(line 4\):\*\*}"
  # Block must appear before TODO content.
  [ "${#i_start}" -lt "${#i_todo}" ]
}

@test "no leakage across stages for materialize and prompt" {
  local wf="$TMPD/leak.workflow.md"
  local out="$TMPD/leak.plan.md"
  local orch_json block_a block_b
  cat >"$wf" <<'EOF'
---
name: leak-check
kind: workflow
engine: orchestration
pipeline:
  stages:
    - id: research
      runtime: cursor
      instructions: RESEARCH_ONLY_TOKEN_AAA
    - id: implement
      runtime: cursor
      instructions: IMPLEMENT_ONLY_TOKEN_BBB
todos:
  - id: research-1
    stage: research
    content: Investigate {{TASK}}
    status: pending
  - id: implement-1
    stage: implement
    content: Fix {{TASK}}
    status: pending
---
EOF
  run plan_workflow_instantiate "$wf" "task" "$out"
  [ "$status" -eq 0 ]
  orch_json="$(plan_pipeline_orch_json "$out")"
  [ "$(printf '%s' "$orch_json" | jq -r '.stages[0].instructions')" = "RESEARCH_ONLY_TOKEN_AAA" ]
  [ "$(printf '%s' "$orch_json" | jq -r '.stages[1].instructions')" = "IMPLEMENT_ONLY_TOKEN_BBB" ]
  [[ "$(printf '%s' "$orch_json" | jq -r '.stages[0].instructions')" != *BBB* ]]
  [[ "$(printf '%s' "$orch_json" | jq -r '.stages[1].instructions')" != *AAA* ]]

  block_a="$(ralph_workflow_stage_instructions_prompt_block "RESEARCH_ONLY_TOKEN_AAA")"
  block_b="$(ralph_workflow_stage_instructions_prompt_block "IMPLEMENT_ONLY_TOKEN_BBB")"
  [[ "$block_a" == *AAA* ]]
  [[ "$block_a" != *BBB* ]]
  [[ "$block_b" == *BBB* ]]
  [[ "$block_b" != *AAA* ]]

  # Empty env clears ambient leakage for a stage without instructions.
  export RALPH_WORKFLOW_STAGE_INSTRUCTIONS="RESEARCH_ONLY_TOKEN_AAA"
  block_a="$(RALPH_WORKFLOW_STAGE_INSTRUCTIONS= ralph_workflow_stage_instructions_prompt_block)"
  [ -z "$block_a" ]
}
