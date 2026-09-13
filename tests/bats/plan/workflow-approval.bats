#!/usr/bin/env bats

# Public supervisor type: approval for Sequential and Dependency workflows.
# Sourced schema/compiler only — no workflow or engine execution.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/plan-todo.sh"

VALIDATE_ORCH_SCHEMA="$BATS_TEST_DIRNAME/../../../scripts/validate-orchestration-schema.sh"

setup() {
  TMPD="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMPD"
}

json_payload() {
  printf '%s\n' "$1" | awk 'END{print}'
}

json_field() {
  printf '%s' "$1" | jq -r "$2"
}

# Minimal valid approval workflow: planner -> approval -> consumer.
write_approval_workflow() {
  local path="$1"
  local mode="${2:-dependency}"
  local approval_extra="${3:-}"
  {
    printf '%s\n' \
      '---' \
      'name: approval-demo' \
      'kind: workflow' \
      "mode: ${mode}" \
      'pipeline:' \
      '  stages:' \
      '    - id: plan-implementation' \
      '      runtime: cursor' \
      '      planner:' \
      '        outputMode: plan-file' \
      '        maxTodos: 20' \
      '      produces:' \
      '        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/impl-plan.json' \
      '          schema: bundle/.ralph/schemas/planner-output.schema.json' \
      '          required: true' \
      '    - id: approve-plan' \
      '      type: approval' \
      '      question: Approve the concrete implementation plan?' \
      '      changesTarget: plan-implementation' \
      '      dependsOn:' \
      '        - plan-implementation' \
      '      requires:' \
      '        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/impl-plan.json' \
      '          schema: bundle/.ralph/schemas/planner-output.schema.json' \
      '          required: true'
    if [ -n "$approval_extra" ]; then
      printf '%s\n' "$approval_extra"
    fi
    printf '%s\n' \
      '    - id: implement' \
      '      runtime: cursor' \
      '      planFrom: plan-implementation' \
      '      dependsOn:' \
      '        - approve-plan' \
      '        - plan-implementation' \
      '      produces:' \
      '        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md' \
      '          required: true' \
      'todos:' \
      '  - id: plan-work' \
      '    stage: plan-implementation' \
      '    content: |' \
      '      Plan work for:' \
      '      {{TASK}}' \
      '    status: pending' \
      '---'
  } >"$path"
}

# --- approval schema ---

@test "approval schema accepts Sequential workflow with question changesTarget dependsOn requires" {
  write_approval_workflow "$TMPD/wf.md" sequential
  run plan_workflow_validate "$TMPD/wf.md"
  [ "$status" -eq 0 ]
}

@test "approval schema accepts Dependency workflow with planner changesTarget" {
  write_approval_workflow "$TMPD/wf.md" dependency
  run plan_workflow_validate "$TMPD/wf.md"
  [ "$status" -eq 0 ]
}

@test "question rejects empty approval question" {
  write_approval_workflow "$TMPD/wf.md" dependency "$(printf '%s\n' '      question: ""')"
  # Helper already wrote question; overwrite with explicit empty.
  cat >"$TMPD/wf.md" <<'EOF'
---
name: approval-empty-question
kind: workflow
mode: dependency
pipeline:
  stages:
    - id: plan-implementation
      planner:
        outputMode: plan-file
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/impl-plan.json
          schema: bundle/.ralph/schemas/planner-output.schema.json
          required: true
    - id: approve-plan
      type: approval
      question: ""
      changesTarget: plan-implementation
      dependsOn:
        - plan-implementation
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/impl-plan.json
          required: true
    - id: implement
      planFrom: plan-implementation
      dependsOn:
        - approve-plan
        - plan-implementation
todos:
  - id: plan-work
    stage: plan-implementation
    content: Plan {{TASK}}
    status: pending
---
EOF
  run plan_workflow_validate "$TMPD/wf.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"question"* ]]
}

@test "changesTarget rejects missing value" {
  cat >"$TMPD/wf.md" <<'EOF'
---
name: approval-missing-target
kind: workflow
mode: sequential
pipeline:
  stages:
    - id: research
    - id: approve-plan
      type: approval
      question: Approve research?
      dependsOn:
        - research
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md
          required: true
todos:
  - id: research-work
    stage: research
    content: Investigate {{TASK}}
    status: pending
---
EOF
  run plan_workflow_validate "$TMPD/wf.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"changesTarget"* ]]
}

@test "ancestor accepts transitive upstream executable changesTarget" {
  cat >"$TMPD/wf.md" <<'EOF'
---
name: approval-transitive
kind: workflow
mode: dependency
pipeline:
  stages:
    - id: research
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md
          required: true
    - id: plan-implementation
      planner:
        outputMode: plan-file
      dependsOn:
        - research
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md
          required: true
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/impl-plan.json
          schema: bundle/.ralph/schemas/planner-output.schema.json
          required: true
    - id: approve-plan
      type: approval
      question: Approve plan built from research?
      changesTarget: research
      dependsOn:
        - plan-implementation
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md
          required: true
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/impl-plan.json
          required: true
    - id: implement
      planFrom: plan-implementation
      dependsOn:
        - approve-plan
        - plan-implementation
todos:
  - id: research-work
    stage: research
    content: Investigate {{TASK}}
    status: pending
  - id: plan-work
    stage: plan-implementation
    content: Plan {{TASK}}
    status: pending
---
EOF
  run plan_workflow_validate "$TMPD/wf.md"
  [ "$status" -eq 0 ]
}

@test "ancestor rejects self changesTarget" {
  cat >"$TMPD/wf.md" <<'EOF'
---
name: approval-self
kind: workflow
mode: dependency
pipeline:
  stages:
    - id: research
    - id: approve-plan
      type: approval
      question: Approve?
      changesTarget: approve-plan
      dependsOn:
        - research
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md
          required: true
todos:
  - id: research-work
    stage: research
    content: Investigate {{TASK}}
    status: pending
---
EOF
  run plan_workflow_validate "$TMPD/wf.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"changesTarget"* ]]
  [[ "$output" == *"self"* ]]
}

@test "ancestor rejects unknown changesTarget" {
  write_approval_workflow "$TMPD/wf.md" dependency
  # Patch changesTarget to unknown id via rewrite.
  cat >"$TMPD/wf.md" <<'EOF'
---
name: approval-unknown
kind: workflow
mode: dependency
pipeline:
  stages:
    - id: plan-implementation
      planner:
        outputMode: plan-file
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/impl-plan.json
          schema: bundle/.ralph/schemas/planner-output.schema.json
          required: true
    - id: approve-plan
      type: approval
      question: Approve?
      changesTarget: missing-stage
      dependsOn:
        - plan-implementation
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/impl-plan.json
          required: true
    - id: implement
      planFrom: plan-implementation
      dependsOn:
        - approve-plan
        - plan-implementation
todos:
  - id: plan-work
    stage: plan-implementation
    content: Plan {{TASK}}
    status: pending
---
EOF
  run plan_workflow_validate "$TMPD/wf.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"changesTarget"* ]]
  [[ "$output" == *"unknown"* ]]
}

@test "ancestor rejects independent-branch changesTarget" {
  cat >"$TMPD/wf.md" <<'EOF'
---
name: approval-cross-branch
kind: workflow
mode: dependency
pipeline:
  stages:
    - id: root
    - id: branch-a
      dependsOn:
        - root
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/a.md
          required: true
    - id: branch-b
      dependsOn:
        - root
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/b.md
          required: true
    - id: approve-a
      type: approval
      question: Approve branch A?
      changesTarget: branch-b
      dependsOn:
        - branch-a
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/a.md
          required: true
todos:
  - id: root-work
    stage: root
    content: Start {{TASK}}
    status: pending
  - id: a-work
    stage: branch-a
    content: Do A for {{TASK}}
    status: pending
  - id: b-work
    stage: branch-b
    content: Do B for {{TASK}}
    status: pending
---
EOF
  run plan_workflow_validate "$TMPD/wf.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"changesTarget"* ]]
  [[ "$output" == *"ancestor"* ]]
}

@test "ancestor rejects supervisor changesTarget" {
  cat >"$TMPD/wf.md" <<'EOF'
---
name: approval-supervisor-target
kind: workflow
mode: dependency
pipeline:
  stages:
    - id: implement
      workspaceMode: snapshot
      writeScopes:
        - src/**
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md
          required: true
    - id: integrate
      type: integrate
      workspaceMode: snapshot
      dependsOn:
        - implement
    - id: approve-result
      type: approval
      question: Approve integrated result?
      changesTarget: integrate
      dependsOn:
        - integrate
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md
          required: true
todos:
  - id: impl-work
    stage: implement
    content: Implement {{TASK}}
    status: pending
---
EOF
  run plan_workflow_validate "$TMPD/wf.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"changesTarget"* ]]
  [[ "$output" == *"supervisor"* ]] || [[ "$output" == *"resettable"* ]]
}

@test "forbidden fields reject runtime model instructions planFile on approval" {
  cat >"$TMPD/wf.md" <<'EOF'
---
name: approval-forbidden
kind: workflow
mode: sequential
pipeline:
  stages:
    - id: research
    - id: approve-plan
      type: approval
      question: Approve?
      changesTarget: research
      runtime: cursor
      model: auto
      instructions: not allowed
      planFile: .ralph-workspace/plans/x.plan.md
      dependsOn:
        - research
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md
          required: true
todos:
  - id: research-work
    stage: research
    content: Investigate {{TASK}}
    status: pending
---
EOF
  run plan_workflow_validate "$TMPD/wf.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"approval"* ]]
  [[ "$output" == *"runtime"* ]] || [[ "$output" == *"reject"* ]] || [[ "$output" == *"instructions"* ]]
}

@test "forbidden fields reject humanAck and workspace Git fields on approval" {
  cat >"$TMPD/wf.md" <<'EOF'
---
name: approval-forbidden-legacy
kind: workflow
mode: dependency
pipeline:
  stages:
    - id: research
    - id: approve-plan
      type: approval
      question: Approve?
      changesTarget: research
      humanAck:
        path: .ralph-workspace/acks/x.ack
      workspaceMode: snapshot
      writeScopes:
        - src/**
      agentGitAccess: off
      dependsOn:
        - research
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md
          required: true
todos:
  - id: research-work
    stage: research
    content: Investigate {{TASK}}
    status: pending
---
EOF
  run plan_workflow_validate "$TMPD/wf.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"approval"* ]] || [[ "$output" == *"humanAck"* ]] || [[ "$output" == *"workspaceMode"* ]] || [[ "$output" == *"unknown"* ]]
}

@test "Sequential internal projection keeps type approval without humanAck or checkpoint" {
  write_approval_workflow "$TMPD/wf.md" sequential
  run plan_workflow_instantiate "$TMPD/wf.md" "ship the fix" "$TMPD/out.plan.md"
  [ "$status" -eq 0 ]
  grep -qx 'execution: orchestration' "$TMPD/out.plan.md"
  ! grep -qi 'humanAck' "$TMPD/out.plan.md"
  ! grep -qi 'ORCHESTRATOR_HUMAN_ACK' "$TMPD/out.plan.md"
  ! grep -E 'type:[[:space:]]*checkpoint' "$TMPD/out.plan.md"

  run plan_pipeline_orch_json "$TMPD/out.plan.md"
  [ "$status" -eq 0 ]
  payload="$(json_payload "$output")"
  [ "$(json_field "$payload" '.stages[] | select(.id=="approve-plan") | .type')" = "approval" ]
  [ "$(json_field "$payload" '.stages[] | select(.id=="approve-plan") | .question')" = "Approve the concrete implementation plan?" ]
  [ "$(json_field "$payload" '.stages[] | select(.id=="approve-plan") | .changesTarget')" = "plan-implementation" ]
  [ "$(json_field "$payload" '.stages[] | select(.id=="approve-plan") | has("humanAck")')" = "false" ]
  [ "$(json_field "$payload" '.stages[] | select(.id=="approve-plan") | has("runtime")')" = "false" ]
  [ "$(json_field "$payload" '.stages[] | select(.id=="approve-plan") | has("_inlineTodos")')" = "false" ]
  ! printf '%s' "$payload" | grep -qi 'ORCHESTRATOR_HUMAN_ACK'
  ! printf '%s' "$payload" | grep -qi '"type":"checkpoint"'

  # Minimal orch document for schema gate (ordinary stages still require plan/planFrom).
  python3 -c '
import json, sys
json.dump({
  "name": "approval-schema",
  "namespace": "approval-schema",
  "stages": [
    {
      "id": "plan-implementation",
      "runtime": "cursor",
      "plan": ".ralph-workspace/plans/impl.plan.md",
      "planner": {"outputMode": "plan-file", "maxTodos": 20},
      "artifacts": [{
        "path": ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/impl-plan.json",
        "schema": "bundle/.ralph/schemas/planner-output.schema.json",
        "required": True,
      }],
    },
    {
      "id": "approve-plan",
      "type": "approval",
      "question": "Approve the concrete implementation plan?",
      "changesTarget": "plan-implementation",
      "dependsOn": ["plan-implementation"],
      "inputArtifacts": [{
        "path": ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/impl-plan.json",
        "schema": "bundle/.ralph/schemas/planner-output.schema.json",
        "required": True,
      }],
    },
  ],
}, open(sys.argv[1], "w"), separators=(",", ":"))
' "$TMPD/orch.json"
  [ -s "$TMPD/orch.json" ]
  run bash "$VALIDATE_ORCH_SCHEMA" "$TMPD/orch.json" "$REPO_ROOT"
  [ "$status" -eq 0 ]
}

@test "Dependency internal projection keeps type approval without checkpoint vocabulary" {
  write_approval_workflow "$TMPD/wf.md" dependency
  run plan_workflow_instantiate "$TMPD/wf.md" "ship the fix" "$TMPD/out.plan.md"
  [ "$status" -eq 0 ]
  grep -qx 'execution: graph' "$TMPD/out.plan.md"

  run plan_pipeline_graph_json "$TMPD/out.plan.md"
  [ "$status" -eq 0 ]
  payload="$(json_payload "$output")"
  [ "$(json_field "$payload" '.nodes[] | select(.id=="approve-plan") | .type')" = "approval" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="approve-plan") | .stage.type')" = "approval" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="approve-plan") | .stage.question')" = "Approve the concrete implementation plan?" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="approve-plan") | .stage.changesTarget')" = "plan-implementation" ]
  [ "$(json_field "$payload" '.nodes[] | select(.id=="approve-plan") | .stage | has("humanAck")')" = "false" ]
  ! printf '%s' "$payload" | grep -qi 'ORCHESTRATOR_HUMAN_ACK'
  [ "$(json_field "$payload" '[.nodes[] | select(.type=="checkpoint")] | length')" = "0" ]
}
