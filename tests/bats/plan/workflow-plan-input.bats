#!/usr/bin/env bats

# Workflow planInput schema: top-level {stage, required?}, consumer rules,
# {{INPUT_PLAN}} gating, and rejection on non-workflow / materialized orch JSON.
# Sourced parser/schema only — no engine or runtime invocation.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/plan-todo.sh"

setup() {
  TMPD="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMPD"
}

# Table-driven optional planInput with planner -> planFrom consumer.
write_optional_plan_input_workflow() {
  local path="$1"
  local extra_top="${2:-}"
  local implement_extra="${3:-}"
  {
    printf '%s\n' \
      '---' \
      'name: plan-input-optional' \
      'kind: workflow' \
      'mode: dependency'
    if [ -n "$extra_top" ]; then
      printf '%s\n' "$extra_top"
    fi
    printf '%s\n' \
      'planInput:' \
      '  stage: implement' \
      'pipeline:' \
      '  stages:' \
      '    - id: plan-implementation' \
      '      planner:' \
      '        outputMode: plan-file' \
      '        maxTodos: 40' \
      '      produces:' \
      '        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/impl-plan.json' \
      '          schema: bundle/.ralph/schemas/planner-output.schema.json' \
      '          required: true' \
      '    - id: implement' \
      '      planFrom: plan-implementation' \
      '      dependsOn:' \
      '        - plan-implementation' \
      '      produces:' \
      '        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md' \
      '          required: true'
    if [ -n "$implement_extra" ]; then
      printf '%s\n' "$implement_extra"
    fi
    printf '%s\n' \
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

write_required_plan_input_workflow() {
  local path="$1"
  local implement_extra="${2:-}"
  {
    printf '%s\n' \
      '---' \
      'name: plan-input-required' \
      'kind: workflow' \
      'mode: dependency' \
      'planInput:' \
      '  stage: implement' \
      '  required: true' \
      'pipeline:' \
      '  stages:' \
      '    - id: implement' \
      '      produces:' \
      '        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md' \
      '          required: true'
    if [ -n "$implement_extra" ]; then
      printf '%s\n' "$implement_extra"
    fi
    printf '%s\n' \
      '    - id: review' \
      '      dependsOn:' \
      '        - implement' \
      'todos:' \
      '  - id: review-work' \
      '    stage: review' \
      '    content: |' \
      '      Review result for:' \
      '      {{TASK}}' \
      '    status: pending' \
      '---'
  } >"$path"
}

# --- schema ---

@test "schema accepts optional planInput with stage and required default false" {
  write_optional_plan_input_workflow "$TMPD/wf.md"
  run plan_workflow_validate "$TMPD/wf.md"
  [ "$status" -eq 0 ]
  # Preserve planInput through authored validation (source unchanged).
  grep -q '^planInput:' "$TMPD/wf.md"
  grep -q 'stage: implement' "$TMPD/wf.md"
}

@test "schema accepts required planInput and omits planFrom on the consumer" {
  write_required_plan_input_workflow "$TMPD/wf.md"
  run plan_workflow_validate "$TMPD/wf.md"
  [ "$status" -eq 0 ]
}

@test "schema rejects unknown planInput fields" {
  write_optional_plan_input_workflow "$TMPD/wf.md" "$(printf '%s\n' 'planInput:' '  stage: implement' '  waiveArtifacts: true')"
  # The helper above already writes planInput; overwrite with explicit bad block.
  cat >"$TMPD/wf.md" <<'EOF'
---
name: plan-input-bad
kind: workflow
mode: dependency
planInput:
  stage: implement
  waiveArtifacts: true
pipeline:
  stages:
    - id: plan-implementation
      planner:
        outputMode: plan-file
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/impl-plan.json
          schema: bundle/.ralph/schemas/planner-output.schema.json
          required: true
    - id: implement
      planFrom: plan-implementation
      dependsOn:
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
  [[ "$output" == *"planInput"* ]]
  [[ "$output" == *"waiveArtifacts"* ]] || [[ "$output" == *"unknown"* ]]
}

@test "schema rejects planInput on non-workflows" {
  cat >"$TMPD/plan.md" <<'EOF'
---
name: not-a-workflow
execution: graph
planInput:
  stage: implement
pipeline:
  stages:
    - id: implement
      runtime: cursor
todos:
  - id: work
    stage: implement
    content: Do the work
    status: pending
---
EOF
  run plan_pipeline_validate_plan "$TMPD/plan.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"planInput"* ]]
}

@test "schema rejects planInput on legacy materialized orch JSON" {
  cat >"$TMPD/bad.orch.json" <<'EOF'
{
  "name": "legacy",
  "namespace": "legacy",
  "planInput": {"stage": "implement", "required": false},
  "stages": [
    {
      "id": "implement",
      "runtime": "cursor",
      "plan": ".ralph-workspace/plans/x.plan.md"
    }
  ]
}
EOF
  run bash "$REPO_ROOT/scripts/validate-orchestration-schema.sh" "$TMPD/bad.orch.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"planInput"* ]]
}

# --- required ---

@test "required planInput may omit planFrom and stay schema-valid" {
  write_required_plan_input_workflow "$TMPD/wf.md"
  run plan_workflow_validate "$TMPD/wf.md"
  [ "$status" -eq 0 ]
}

@test "required planInput rejects task-only instantiate path" {
  write_required_plan_input_workflow "$TMPD/wf.md"
  run plan_workflow_instantiate "$TMPD/wf.md" "fix the bug" "$TMPD/out.plan.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"required"* ]] || [[ "$output" == *"planInput"* ]]
  [[ "$output" == *"task"* ]] || [[ "$output" == *"--plan"* ]] || [[ "$output" == *"supply"* ]]
}

# --- optional requires planFrom ---

@test "optional requires planFrom for task-mode starts" {
  cat >"$TMPD/wf.md" <<'EOF'
---
name: plan-input-optional-missing
kind: workflow
mode: dependency
planInput:
  stage: implement
pipeline:
  stages:
    - id: implement
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md
          required: true
todos:
  - id: other
    stage: implement
    content: Should fail before TODO check {{TASK}}
    status: pending
---
EOF
  # Also has authored TODO on input stage; either planFrom or no-TODO may fire first.
  run plan_workflow_validate "$TMPD/wf.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"planFrom"* ]] || [[ "$output" == *"authored TODO"* ]] || [[ "$output" == *"planInput"* ]]
}

@test "optional requires planFrom when consumer has no authored TODOs" {
  cat >"$TMPD/wf.md" <<'EOF'
---
name: plan-input-optional-no-from
kind: workflow
mode: dependency
planInput:
  stage: implement
  required: false
pipeline:
  stages:
    - id: research
    - id: implement
      dependsOn:
        - research
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md
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
  [[ "$output" == *"planFrom"* ]]
  [[ "$output" == *"optional"* ]] || [[ "$output" == *"planInput"* ]]
}

# --- single consumer / ordinary stage ---

@test "single consumer rejects planInput naming an unknown stage" {
  cat >"$TMPD/wf.md" <<'EOF'
---
name: plan-input-unknown
kind: workflow
mode: dependency
planInput:
  stage: missing-stage
pipeline:
  stages:
    - id: implement
todos:
  - id: work
    stage: implement
    content: Do {{TASK}}
    status: pending
---
EOF
  run plan_workflow_validate "$TMPD/wf.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"planInput.stage"* ]] || [[ "$output" == *"unknown"* ]]
}

@test "ordinary stage rejects planInput on integrate supervisor" {
  cat >"$TMPD/wf.md" <<'EOF'
---
name: plan-input-integrate
kind: workflow
mode: dependency
planInput:
  stage: integrate
pipeline:
  stages:
    - id: implement
      runtime: cursor
    - id: integrate
      type: integrate
      workspaceMode: snapshot
      dependsOn:
        - implement
todos:
  - id: work
    stage: implement
    content: Do {{TASK}}
    status: pending
---
EOF
  run plan_workflow_validate "$TMPD/wf.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"planInput"* ]]
  [[ "$output" == *"ordinary"* ]] || [[ "$output" == *"integrate"* ]]
}

@test "ordinary stage rejects authored TODOs on the planInput consumer" {
  write_optional_plan_input_workflow "$TMPD/wf.md"
  cat >"$TMPD/wf.md" <<'EOF'
---
name: plan-input-with-todos
kind: workflow
mode: dependency
planInput:
  stage: implement
pipeline:
  stages:
    - id: plan-implementation
      planner:
        outputMode: plan-file
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/impl-plan.json
          schema: bundle/.ralph/schemas/planner-output.schema.json
          required: true
    - id: implement
      planFrom: plan-implementation
      dependsOn:
        - plan-implementation
todos:
  - id: plan-work
    stage: plan-implementation
    content: Plan {{TASK}}
    status: pending
  - id: bad-inline
    stage: implement
    content: Inline work {{TASK}}
    status: pending
---
EOF
  run plan_workflow_validate "$TMPD/wf.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"authored TODO"* ]] || [[ "$output" == *"planInput"* ]]
}

# --- mutual exclusion ---

@test "mutual exclusion rejects planInput consumer with planFile" {
  cat >"$TMPD/wf.md" <<'EOF'
---
name: plan-input-planfile
kind: workflow
mode: dependency
planInput:
  stage: implement
  required: true
pipeline:
  stages:
    - id: implement
      planFile: .ralph-workspace/plans/other.plan.md
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md
          required: true
    - id: review
      dependsOn:
        - implement
todos:
  - id: review-work
    stage: review
    content: Review {{TASK}}
    status: pending
---
EOF
  run plan_workflow_validate "$TMPD/wf.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"planFile"* ]] || [[ "$output" == *"mutually exclusive"* ]]
  [[ "$output" == *"planInput"* ]]
}

@test "mutual exclusion rejects planInput consumer that is a planner" {
  cat >"$TMPD/wf.md" <<'EOF'
---
name: plan-input-planner
kind: workflow
mode: dependency
planInput:
  stage: plan-implementation
  required: true
pipeline:
  stages:
    - id: plan-implementation
      planner:
        outputMode: plan-file
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/impl-plan.json
          schema: bundle/.ralph/schemas/planner-output.schema.json
          required: true
    - id: review
      dependsOn:
        - plan-implementation
todos:
  - id: review-work
    stage: review
    content: Review {{TASK}}
    status: pending
---
EOF
  run plan_workflow_validate "$TMPD/wf.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"planner"* ]]
  [[ "$output" == *"planInput"* ]]
}

# --- INPUT_PLAN / task path ---

@test "INPUT_PLAN is accepted only when planInput is declared" {
  write_required_plan_input_workflow "$TMPD/wf.md" "$(printf '%s\n' '      instructions: |' '        Execute {{INPUT_PLAN}} for {{TASK}}')"
  # required + INPUT_PLAN in instructions: valid for authored workflow
  cat >"$TMPD/wf.md" <<'EOF'
---
name: plan-input-token-ok
kind: workflow
mode: dependency
planInput:
  stage: implement
  required: true
pipeline:
  stages:
    - id: implement
      instructions: |
        Execute the frozen plan at {{INPUT_PLAN}}
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md
          required: true
    - id: review
      dependsOn:
        - implement
      requires:
        - path: {{INPUT_PLAN}}
          required: true
todos:
  - id: review-work
    stage: review
    content: |
      Review {{TASK}} against {{INPUT_PLAN}}
    status: pending
---
EOF
  run plan_workflow_validate "$TMPD/wf.md"
  [ "$status" -eq 0 ]
}

@test "INPUT_PLAN is rejected without planInput" {
  cat >"$TMPD/wf.md" <<'EOF'
---
name: no-plan-input
kind: workflow
mode: dependency
pipeline:
  stages:
    - id: implement
      instructions: |
        Read {{INPUT_PLAN}}
todos:
  - id: work
    stage: implement
    content: Do {{TASK}}
    status: pending
---
EOF
  run plan_workflow_validate "$TMPD/wf.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"INPUT_PLAN"* ]]
}

@test "task path rejects INPUT_PLAN without a supplied plan" {
  cat >"$TMPD/wf.md" <<'EOF'
---
name: plan-input-task-path
kind: workflow
mode: dependency
planInput:
  stage: implement
pipeline:
  stages:
    - id: plan-implementation
      planner:
        outputMode: plan-file
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/impl-plan.json
          schema: bundle/.ralph/schemas/planner-output.schema.json
          required: true
    - id: implement
      planFrom: plan-implementation
      dependsOn:
        - plan-implementation
      instructions: |
        Prefer {{INPUT_PLAN}} when supplied
todos:
  - id: plan-work
    stage: plan-implementation
    content: Plan {{TASK}}
    status: pending
---
EOF
  run plan_workflow_validate "$TMPD/wf.md"
  [ "$status" -eq 0 ]
  run plan_workflow_instantiate "$TMPD/wf.md" "ship feature" "$TMPD/out.plan.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"INPUT_PLAN"* ]]
  [[ "$output" == *"task"* ]] || [[ "$output" == *"supplied"* ]]
}

@test "task path strips planInput on successful optional materialization" {
  write_optional_plan_input_workflow "$TMPD/wf.md"
  run plan_workflow_validate "$TMPD/wf.md"
  [ "$status" -eq 0 ]
  run plan_workflow_instantiate "$TMPD/wf.md" "ship feature" "$TMPD/out.plan.md"
  [ "$status" -eq 0 ]
  ! grep -E '^planInput:' "$TMPD/out.plan.md"
  ! grep -E '^kind:' "$TMPD/out.plan.md"
  grep -q '^execution: graph' "$TMPD/out.plan.md"
}

# --- no topology waiver ---

@test "no topology waiver keeps planFrom dependency and artifact rules" {
  cat >"$TMPD/wf.md" <<'EOF'
---
name: plan-input-no-waiver
kind: workflow
mode: dependency
planInput:
  stage: implement
pipeline:
  stages:
    - id: plan-implementation
      planner:
        outputMode: plan-file
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/impl-plan.json
          schema: bundle/.ralph/schemas/planner-output.schema.json
          required: true
    - id: implement
      planFrom: plan-implementation
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md
          required: true
todos:
  - id: plan-work
    stage: plan-implementation
    content: Plan {{TASK}}
    status: pending
---
EOF
  # Missing dependsOn must still fail; planInput does not waive topology.
  run plan_workflow_validate "$TMPD/wf.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"planFrom"* ]]
  [[ "$output" == *"direct"* ]] || [[ "$output" == *"dependsOn"* ]]
}

# =============================================================================
# Provided-plan input manifest schema + pure extractor
# (define-provided-plan-manifest-contract)
# =============================================================================

INPUT_PLAN_SCHEMA="$BATS_TEST_DIRNAME/../../../bundle/.ralph/schemas/workflow-input-plan.schema.json"
ARTIFACT_SCHEMA_PY="$BATS_TEST_DIRNAME/../../../bundle/.ralph/python/artifact_json_schema.py"

write_classic_leaf() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat >"$path" <<'EOF'
# classic leaf
- [ ] Do the first thing
- [x] Already finished
- [ ] Do the second thing
EOF
}

write_yaml_leaf() {
  local path="$1"
  local overview="${2:-Ship the YAML leaf}"
  local runtime="${3:-}"
  local model="${4:-}"
  mkdir -p "$(dirname "$path")"
  {
    printf '%s\n' '---' 'name: yaml-leaf'
    printf 'overview: %s\n' "$overview"
    if [[ -n "$runtime" ]]; then
      printf 'runtime: %s\n' "$runtime"
    fi
    if [[ -n "$model" ]]; then
      printf 'model: %s\n' "$model"
    fi
    printf '%s\n' \
      'todos:' \
      '  - id: one' \
      '    content: Do the thing' \
      '    verification: true' \
      '    status: pending' \
      '  - id: two' \
      '    content: Already done' \
      '    verification: true' \
      '    status: completed' \
      '---'
  } >"$path"
}

extract_ok() {
  local path="$1"
  local task="${2:-}"
  if [[ -n "$task" ]]; then
    plan_provided_input_extract "$path" "$TMPD/project" "$TMPD/project/.ralph-workspace" "$task"
  else
    plan_provided_input_extract "$path" "$TMPD/project" "$TMPD/project/.ralph-workspace"
  fi
}

@test "manifest schema accepts a minimal version-1 provided-plan manifest" {
  command -v python3 >/dev/null || skip "python3 required"
  [ -f "$INPUT_PLAN_SCHEMA" ]
  cat >"$TMPD/manifest.json" <<'EOF'
{
  "schemaVersion": 1,
  "sourceKind": "provided",
  "originalPath": "/tmp/project/plans/leaf.plan.md",
  "copiedPath": "/tmp/project/.ralph-workspace/workflow-runs/run-1/plans/input/source.plan.md",
  "originalSha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "copiedSha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "format": "yaml",
  "totalTodos": 2,
  "completedTodos": 1,
  "openTodos": 1,
  "task": "Ship the YAML leaf",
  "taskProvenance": "plan-overview",
  "createdAt": "2026-01-01T00:00:00Z"
}
EOF
  run plan_provided_input_validate_manifest "$TMPD/manifest.json"
  [ "$status" -eq 0 ]
}

@test "manifest schema rejects unknown fields and bad enums" {
  command -v python3 >/dev/null || skip "python3 required"
  cat >"$TMPD/bad.json" <<'EOF'
{
  "schemaVersion": 1,
  "sourceKind": "generated",
  "originalPath": "/tmp/a.md",
  "copiedPath": "/tmp/b.md",
  "originalSha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "copiedSha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "format": "classic",
  "totalTodos": 1,
  "completedTodos": 0,
  "openTodos": 1,
  "task": "x",
  "taskProvenance": "explicit",
  "createdAt": "2026-01-01T00:00:00Z",
  "extra": true
}
EOF
  run plan_provided_input_validate_manifest "$TMPD/bad.json"
  [ "$status" -ne 0 ]
}

@test "classic leaf extract reports format classic and SHA-256 inputs" {
  mkdir -p "$TMPD/project/plans"
  write_classic_leaf "$TMPD/project/plans/classic.plan.md"
  cp "$TMPD/project/plans/classic.plan.md" "$TMPD/project/plans/classic.plan.md.bak"
  run extract_ok "$TMPD/project/plans/classic.plan.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"format":"classic"'* ]]
  [[ "$output" == *'"originalSha256":"'* ]]
  local sha
  sha="$(plan_provided_input_file_sha256 "$TMPD/project/plans/classic.plan.md")"
  [[ "$output" == *"\"originalSha256\":\"$sha\""* ]]
  cmp -s "$TMPD/project/plans/classic.plan.md" "$TMPD/project/plans/classic.plan.md.bak"
}

@test "YAML leaf extract reports format YAML overview and header routing" {
  mkdir -p "$TMPD/project/plans"
  write_yaml_leaf "$TMPD/project/plans/yaml.plan.md" "YAML overview text" "cursor" "header-model"
  run extract_ok "$TMPD/project/plans/yaml.plan.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"format":"yaml"'* ]]
  [[ "$output" == *'"overview":"YAML overview text"'* ]]
  [[ "$output" == *'"headerRuntime":"cursor"'* ]]
  [[ "$output" == *'"headerModel":"header-model"'* ]]
  [[ "$output" == *'"taskProvenance":"plan-overview"'* ]]
  [[ "$output" == *'"task":"YAML overview text"'* ]]
}

@test "routing rejects invalid YAML header runtime" {
  mkdir -p "$TMPD/project/plans"
  cat >"$TMPD/project/plans/bad-rt.plan.md" <<'EOF'
---
name: bad-rt
overview: Bad runtime
runtime: not-a-runtime
todos:
  - id: one
    content: Do it
    verification: true
    status: pending
---
EOF
  run extract_ok "$TMPD/project/plans/bad-rt.plan.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid YAML routing"* ]] || [[ "$output" == *"invalid runtime"* ]]
}

@test "precompleted TODO counts are preserved without changing checkboxes" {
  mkdir -p "$TMPD/project/plans"
  write_classic_leaf "$TMPD/project/plans/pre.plan.md"
  cp "$TMPD/project/plans/pre.plan.md" "$TMPD/pre.bak"
  run extract_ok "$TMPD/project/plans/pre.plan.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"totalTodos":3'* ]]
  [[ "$output" == *'"completedTodos":1'* ]]
  [[ "$output" == *'"openTodos":2'* ]]
  cmp -s "$TMPD/project/plans/pre.plan.md" "$TMPD/pre.bak"
}

@test "zero TODO plans are rejected" {
  mkdir -p "$TMPD/project/plans"
  printf '%s\n' '# empty' 'no todos here' >"$TMPD/project/plans/empty.plan.md"
  run extract_ok "$TMPD/project/plans/empty.plan.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no TODOs"* ]]
}

@test "zero open TODO plans are rejected" {
  mkdir -p "$TMPD/project/plans"
  printf '%s\n' '- [x] Done only' >"$TMPD/project/plans/all-done.plan.md"
  run extract_ok "$TMPD/project/plans/all-done.plan.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no pending TODOs"* ]]
}

@test "workflow rejection for provided plan extract" {
  mkdir -p "$TMPD/project/plans"
  cat >"$TMPD/project/plans/wf.plan.md" <<'EOF'
---
name: not-a-leaf
kind: workflow
mode: dependency
---
EOF
  run extract_ok "$TMPD/project/plans/wf.plan.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"workflow"* ]]
}

@test "allowed roots accept project and state-root plans" {
  mkdir -p "$TMPD/project/plans" "$TMPD/project/.ralph-workspace/plans"
  write_classic_leaf "$TMPD/project/plans/in-project.plan.md"
  write_classic_leaf "$TMPD/project/.ralph-workspace/plans/in-state.plan.md"
  run extract_ok "$TMPD/project/plans/in-project.plan.md"
  [ "$status" -eq 0 ]
  run extract_ok "$TMPD/project/.ralph-workspace/plans/in-state.plan.md"
  [ "$status" -eq 0 ]
}

@test "allowed roots reject plans outside the four roots" {
  mkdir -p "$TMPD/project" "$TMPD/elsewhere"
  write_classic_leaf "$TMPD/elsewhere/escape.plan.md"
  run extract_ok "$TMPD/elsewhere/escape.plan.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"project root"* ]] || [[ "$output" == *"allowed"* ]] || [[ "$output" == *"\$HOME"* ]]
}

@test "symlink escape outside allowed roots is rejected" {
  mkdir -p "$TMPD/project/plans" "$TMPD/outside"
  write_classic_leaf "$TMPD/outside/secret.plan.md"
  ln -s "$TMPD/outside/secret.plan.md" "$TMPD/project/plans/link.plan.md"
  run extract_ok "$TMPD/project/plans/link.plan.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"project root"* ]] || [[ "$output" == *"\$HOME"* ]] || [[ "$output" == *"must be under"* ]]
}

@test "routing rejects invalid checkbox checkboxes" {
  mkdir -p "$TMPD/project/plans"
  printf '%s\n' '- [] missing space' '- [] another' >"$TMPD/project/plans/bad-box.plan.md"
  run extract_ok "$TMPD/project/plans/bad-box.plan.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid checkbox"* ]] || [[ "$output" == *"no TODOs"* ]]
}

@test "manifest schema build from extract is pure and validates" {
  command -v python3 >/dev/null || skip "python3 required"
  mkdir -p "$TMPD/project/plans"
  write_yaml_leaf "$TMPD/project/plans/build.plan.md" "Build me"
  local extract copied manifest
  extract="$(extract_ok "$TMPD/project/plans/build.plan.md")"
  copied="/tmp/project/.ralph-workspace/workflow-runs/run-x/plans/input/source.plan.md"
  manifest="$(plan_provided_input_manifest_json "$extract" "$copied" "2026-01-02T03:04:05Z")"
  printf '%s\n' "$manifest" >"$TMPD/built.json"
  run plan_provided_input_validate_manifest "$TMPD/built.json"
  [ "$status" -eq 0 ]
  [[ "$manifest" == *'"copiedPath":"'"$copied"'"'* ]]
  [[ "$manifest" == *'"createdAt":"2026-01-02T03:04:05Z"'* ]]
  # Extract path was never written as a run artifact by these helpers.
  [ ! -e "$copied" ]
}
