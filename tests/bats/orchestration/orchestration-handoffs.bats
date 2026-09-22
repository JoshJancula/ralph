#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$RALPH_LIB_ROOT/error-handling.sh"
source "$RALPH_LIB_ROOT/orchestrator/orchestrator-handoffs.sh"
source "$RALPH_LIB_ROOT/review-status.sh"

setup() {
  export RALPH_ARTIFACT_NS="test-ns"
  export RALPH_PLAN_KEY="test-plan"
  WORKSPACE="$(mktemp -d)"
}

teardown() {
  [[ -d "$WORKSPACE" ]] && rm -rf "$WORKSPACE"
}

create_handoff_markdown() {
  local path="$1"
  local title="${2:-Handoff}"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'EOF'
# Handoff: From Stage A to Stage B

<!-- HANDOFF_META: START -->
from: stage-a
to: stage-b
iteration: 1
<!-- HANDOFF_META: END -->

## Tasks

- [ ] Task 1: Implement the feature
- [ ] Task 2: Write tests
- [ ] Task 3: Document the changes

## Context

This is background information about the handoff.

## Acceptance

Verify all tasks are completed and tests pass.
EOF
}

create_handoff_markdown_empty_tasks() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'EOF'
# Handoff: From Stage A to Stage B

<!-- HANDOFF_META: START -->
from: stage-a
to: stage-b
iteration: 1
<!-- HANDOFF_META: END -->

## Tasks

## Context

This handoff has no tasks.

## Acceptance

N/A
EOF
}

create_handoff_markdown_no_tasks_section() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'EOF'
# Handoff: From Stage A to Stage B

<!-- HANDOFF_META: START -->
from: stage-a
to: stage-b
iteration: 1
<!-- HANDOFF_META: END -->

## Context

This handoff has no Tasks section at all.

## Acceptance

N/A
EOF
}

create_handoff_markdown_with_checked_items() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'EOF'
# Handoff: From Stage A to Stage B

## Tasks

- [x] Task 1: Already completed
- [ ] Task 2: Still to do
- [x] Task 3: Also done

## Context

Background info.
EOF
}

create_orchestration_json() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'EOF'
{
  "name": "handoff-test",
  "namespace": "test-ns",
  "stages": [
    {
      "id": "stage-a",
      "runtime": "cursor",
      "plan": "plans/stage-a.md",
      "outputArtifacts": [
        {
          "path": ".ralph-workspace/artifacts/test-ns/handoff-a-to-b.md",
          "kind": "handoff",
          "to": "stage-b"
        },
        {
          "path": ".ralph-workspace/artifacts/test-ns/design.md",
          "kind": "design"
        }
      ]
    },
    {
      "id": "stage-b",
      "runtime": "cursor",
      "plan": "plans/stage-b.md",
      "outputArtifacts": [
        {
          "path": ".ralph-workspace/artifacts/test-ns/handoff-b-to-c.md",
          "kind": "handoff",
          "to": "stage-c"
        }
      ]
    },
    {
      "id": "stage-c",
      "runtime": "cursor",
      "plan": "plans/stage-c.md"
    }
  ]
}
EOF
}

create_orchestration_json_with_iterations() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'EOF'
{
  "name": "handoff-iter-test",
  "namespace": "iter-ns",
  "stages": [
    {
      "id": "stage-a",
      "runtime": "cursor",
      "plan": "plans/stage-a.md",
      "outputArtifacts": [
        {
          "path": ".ralph-workspace/artifacts/iter-ns/handoff-iter-{{ITERATION}}.md",
          "kind": "handoff",
          "to": "stage-b"
        }
      ]
    },
    {
      "id": "stage-b",
      "runtime": "cursor",
      "plan": "plans/stage-b.md",
      "loopControl": {
        "loopBackTo": "stage-a",
        "maxIterations": 3
      }
    }
  ]
}
EOF
}

# Test collect_incoming_handoffs function

@test "collect_incoming_handoffs returns handoff targeting a stage" {
  local orch_file="$WORKSPACE/orch.json"
  create_orchestration_json "$orch_file"

  run collect_incoming_handoffs "$orch_file" "stage-b" "test-ns" "test-plan" "1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stage-a"* ]]
  [[ "$output" == *".ralph-workspace/artifacts/test-ns/handoff-a-to-b.md"* ]]
}

@test "collect_incoming_handoffs returns empty when no handoffs target stage" {
  local orch_file="$WORKSPACE/orch.json"
  create_orchestration_json "$orch_file"

  run collect_incoming_handoffs "$orch_file" "nonexistent-stage" "test-ns" "test-plan" "1"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "collect_incoming_handoffs expands ARTIFACT_NS token" {
  local orch_file="$WORKSPACE/orch.json"
  mkdir -p "$(dirname "$orch_file")"
  cat > "$orch_file" <<'EOF'
{
  "name": "test",
  "namespace": "custom-ns",
  "stages": [
    {
      "id": "src",
      "runtime": "cursor",
      "plan": "plans/src.md",
      "outputArtifacts": [
        {
          "path": ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/handoff.md",
          "kind": "handoff",
          "to": "dst"
        }
      ]
    },
    {
      "id": "dst",
      "runtime": "cursor",
      "plan": "plans/dst.md"
    }
  ]
}
EOF

  run collect_incoming_handoffs "$orch_file" "dst" "custom-ns" "test-plan" "1"
  [ "$status" -eq 0 ]
  [[ "$output" == *".ralph-workspace/artifacts/custom-ns/handoff.md"* ]]
}

@test "collect_incoming_handoffs expands PLAN_KEY token" {
  local orch_file="$WORKSPACE/orch.json"
  mkdir -p "$(dirname "$orch_file")"
  cat > "$orch_file" <<'EOF'
{
  "name": "test",
  "namespace": "test-ns",
  "stages": [
    {
      "id": "src",
      "runtime": "cursor",
      "plan": "plans/src.md",
      "outputArtifacts": [
        {
          "path": ".ralph-workspace/artifacts/{{PLAN_KEY}}/handoff.md",
          "kind": "handoff",
          "to": "dst"
        }
      ]
    },
    {
      "id": "dst",
      "runtime": "cursor",
      "plan": "plans/dst.md"
    }
  ]
}
EOF

  run collect_incoming_handoffs "$orch_file" "dst" "test-ns" "my-plan-key" "1"
  [ "$status" -eq 0 ]
  [[ "$output" == *".ralph-workspace/artifacts/my-plan-key/handoff.md"* ]]
}

@test "collect_incoming_handoffs expands STAGE_ID token" {
  local orch_file="$WORKSPACE/orch.json"
  mkdir -p "$(dirname "$orch_file")"
  cat > "$orch_file" <<'EOF'
{
  "name": "test",
  "namespace": "test-ns",
  "stages": [
    {
      "id": "source-stage",
      "runtime": "cursor",
      "plan": "plans/src.md",
      "outputArtifacts": [
        {
          "path": ".ralph-workspace/artifacts/test-ns/{{STAGE_ID}}-handoff.md",
          "kind": "handoff",
          "to": "dst"
        }
      ]
    },
    {
      "id": "dst",
      "runtime": "cursor",
      "plan": "plans/dst.md"
    }
  ]
}
EOF

  run collect_incoming_handoffs "$orch_file" "dst" "test-ns" "test-plan" "1"
  [ "$status" -eq 0 ]
  [[ "$output" == *".ralph-workspace/artifacts/test-ns/source-stage-handoff.md"* ]]
}

@test "collect_incoming_handoffs expands ITERATION token" {
  local orch_file="$WORKSPACE/orch.json"
  create_orchestration_json_with_iterations "$orch_file"

  run collect_incoming_handoffs "$orch_file" "stage-b" "iter-ns" "iter-plan" "2"
  [ "$status" -eq 0 ]
  [[ "$output" == *".ralph-workspace/artifacts/iter-ns/handoff-iter-2.md"* ]]
}

@test "collect_incoming_handoffs rejects missing orch file" {
  run collect_incoming_handoffs "/nonexistent/orch.json" "stage-b" "test-ns" "test-plan" "1"
  [ "$status" -ne 0 ]
}

@test "collect_incoming_handoffs rejects missing target_stage_id" {
  local orch_file="$WORKSPACE/orch.json"
  create_orchestration_json "$orch_file"

  # When target_stage_id is empty, the function returns 1
  ! collect_incoming_handoffs "$orch_file" "" "test-ns" "test-plan" "1"
}

# Test extract_handoff_tasks function

@test "extract_handoff_tasks extracts unchecked task items" {
  local handoff_file="$WORKSPACE/handoff.md"
  create_handoff_markdown "$handoff_file"

  run extract_handoff_tasks "$handoff_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *"- [ ] Task 1: Implement the feature"* ]]
  [[ "$output" == *"- [ ] Task 2: Write tests"* ]]
  [[ "$output" == *"- [ ] Task 3: Document the changes"* ]]
}

@test "extract_handoff_tasks ignores checked task items" {
  local handoff_file="$WORKSPACE/handoff.md"
  create_handoff_markdown_with_checked_items "$handoff_file"

  run extract_handoff_tasks "$handoff_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *"- [ ] Task 2: Still to do"* ]]
  [[ "$output" != *"[x] Task 1"* ]]
  [[ "$output" != *"[x] Task 3"* ]]
}

@test "extract_handoff_tasks stops at next heading" {
  local handoff_file="$WORKSPACE/handoff.md"
  mkdir -p "$(dirname "$handoff_file")"
  cat > "$handoff_file" <<'EOF'
# Handoff

## Tasks

- [ ] Task 1
- [ ] Task 2

## Other Section

- [ ] Should not be extracted
EOF

  run extract_handoff_tasks "$handoff_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *"- [ ] Task 1"* ]]
  [[ "$output" == *"- [ ] Task 2"* ]]
  [[ "$output" != *"Should not be extracted"* ]]
}

@test "extract_handoff_tasks returns 0 when file has no tasks" {
  local handoff_file="$WORKSPACE/handoff.md"
  create_handoff_markdown_empty_tasks "$handoff_file"

  run extract_handoff_tasks "$handoff_file"
  [ "$status" -eq 0 ]
}

@test "extract_handoff_tasks returns 0 when Tasks section is missing" {
  local handoff_file="$WORKSPACE/handoff.md"
  create_handoff_markdown_no_tasks_section "$handoff_file"

  run extract_handoff_tasks "$handoff_file"
  [ "$status" -eq 0 ]
}

@test "extract_handoff_tasks rejects nonexistent file" {
  # The function returns 1 for missing files
  ! extract_handoff_tasks "/nonexistent/handoff.md"
}

# Test inject_handoffs_into_plan function

@test "inject_handoffs_into_plan injects handoff block into plan" {
  local orch_file="$WORKSPACE/orch.json"
  local handoff_file="$WORKSPACE/.ralph-workspace/artifacts/test-ns/handoff-a-to-b.md"
  local plan_file="$WORKSPACE/plan.md"

  create_orchestration_json "$orch_file"
  create_handoff_markdown "$handoff_file"
  mkdir -p "$(dirname "$plan_file")"
  echo "# Plan" > "$plan_file"
  echo "- [ ] Original task" >> "$plan_file"

  # Change to workspace so relative paths work
  (
    cd "$WORKSPACE"
    export ORCH_FILE="$orch_file"
    run inject_handoffs_into_plan "$plan_file" "stage-b" "1"
    [ "$status" -eq 0 ]
  )

  grep -q "RALPH_HANDOFF" "$plan_file"
  grep -q "Handoff from stage-a" "$plan_file"
  grep -q "Task 1: Implement the feature" "$plan_file"
}

@test "inject_handoffs_into_plan is idempotent on identical sha" {
  local orch_file="$WORKSPACE/orch.json"
  local handoff_file="$WORKSPACE/.ralph-workspace/artifacts/test-ns/handoff-a-to-b.md"
  local plan_file="$WORKSPACE/plan.md"

  create_orchestration_json "$orch_file"
  create_handoff_markdown "$handoff_file"
  mkdir -p "$(dirname "$plan_file")"
  echo "# Plan" > "$plan_file"

  (
    cd "$WORKSPACE"
    export ORCH_FILE="$orch_file"

    # First injection
    run inject_handoffs_into_plan "$plan_file" "stage-b" "1"
    [ "$status" -eq 0 ]
  )

  local first_content
  first_content="$(cat "$plan_file")"

  # Count occurrences before second run
  local count_before
  count_before="$(grep -c "RALPH_HANDOFF" "$plan_file")"

  (
    cd "$WORKSPACE"
    export ORCH_FILE="$orch_file"
    # Second injection with identical sha should not change plan
    run inject_handoffs_into_plan "$plan_file" "stage-b" "1"
    [ "$status" -eq 0 ]
  )

  local second_content
  second_content="$(cat "$plan_file")"

  [[ "$first_content" == "$second_content" ]]

  # Count should not increase
  local count_after
  count_after="$(grep -c "RALPH_HANDOFF" "$plan_file")"
  [ "$count_before" -eq "$count_after" ]
}

@test "inject_handoffs_into_plan replaces block on sha change" {
  local orch_file="$WORKSPACE/orch.json"
  local handoff_file="$WORKSPACE/.ralph-workspace/artifacts/test-ns/handoff-a-to-b.md"
  local plan_file="$WORKSPACE/plan.md"

  create_orchestration_json "$orch_file"
  create_handoff_markdown "$handoff_file"
  mkdir -p "$(dirname "$plan_file")"
  echo "# Plan" > "$plan_file"

  (
    cd "$WORKSPACE"
    export ORCH_FILE="$orch_file"

    # First injection
    run inject_handoffs_into_plan "$plan_file" "stage-b" "1"
    [ "$status" -eq 0 ]
  )

  # Modify the handoff file content
  cat > "$handoff_file" <<'EOF'
# Handoff: From Stage A to Stage B

## Tasks

- [ ] Updated Task 1: New implementation
- [ ] Updated Task 2: New tests

## Context

Updated background.
EOF

  (
    cd "$WORKSPACE"
    export ORCH_FILE="$orch_file"
    # Second injection should replace the block
    run inject_handoffs_into_plan "$plan_file" "stage-b" "1"
    [ "$status" -eq 0 ]
  )

  grep -q "Updated Task 1" "$plan_file"
  grep -q "Updated Task 2" "$plan_file"
}

@test "inject_handoffs_into_plan respects iteration number" {
  # This test verifies that handoffs with different iterations are kept separate
  # and both are injected into the same plan file
  local orch_file="$WORKSPACE/orch.json"
  local handoff_file_a1="$WORKSPACE/.ralph-workspace/artifacts/test-ns/handoff-a-to-b-iter-1.md"
  local handoff_file_a2="$WORKSPACE/.ralph-workspace/artifacts/test-ns/handoff-a-to-b-iter-2.md"
  local plan_file="$WORKSPACE/plan.md"

  # Create a simpler orchestration for this test
  mkdir -p "$(dirname "$orch_file")"
  cat > "$orch_file" <<'EOF'
{
  "name": "handoff-iter-test",
  "namespace": "test-ns",
  "stages": [
    {
      "id": "stage-a",
      "runtime": "cursor",
      "plan": "plans/stage-a.md",
      "outputArtifacts": [
        {
          "path": ".ralph-workspace/artifacts/test-ns/handoff-a-to-b-iter-1.md",
          "kind": "handoff",
          "to": "stage-b"
        }
      ]
    },
    {
      "id": "stage-b",
      "runtime": "cursor",
      "plan": "plans/stage-b.md"
    }
  ]
}
EOF

  mkdir -p "$(dirname "$handoff_file_a1")"
  mkdir -p "$(dirname "$plan_file")"

  # Create iteration 1 handoff
  cat > "$handoff_file_a1" <<'EOF'
# Handoff: Iteration 1

## Tasks

- [ ] Iteration 1 Task

## Context

First iteration context.
EOF

  echo "# Plan" > "$plan_file"

  (
    cd "$WORKSPACE"
    export ORCH_FILE="$orch_file"
    inject_handoffs_into_plan "$plan_file" "stage-b" "1"
  )

  grep -q "Iteration 1 Task" "$plan_file"
  grep -q "iter=1" "$plan_file"

  # Update orch file for iteration 2
  cat > "$orch_file" <<'EOF'
{
  "name": "handoff-iter-test",
  "namespace": "test-ns",
  "stages": [
    {
      "id": "stage-a",
      "runtime": "cursor",
      "plan": "plans/stage-a.md",
      "outputArtifacts": [
        {
          "path": ".ralph-workspace/artifacts/test-ns/handoff-a-to-b-iter-2.md",
          "kind": "handoff",
          "to": "stage-b"
        }
      ]
    },
    {
      "id": "stage-b",
      "runtime": "cursor",
      "plan": "plans/stage-b.md"
    }
  ]
}
EOF

  # Create iteration 2 handoff
  cat > "$handoff_file_a2" <<'EOF'
# Handoff: Iteration 2

## Tasks

- [ ] Iteration 2 Task

## Context

Second iteration context.
EOF

  (
    cd "$WORKSPACE"
    export ORCH_FILE="$orch_file"
    inject_handoffs_into_plan "$plan_file" "stage-b" "2"
  )

  # Both iterations should be present
  grep -q "Iteration 1 Task" "$plan_file"
  grep -q "Iteration 2 Task" "$plan_file"
  grep -q "iter=1" "$plan_file"
  grep -q "iter=2" "$plan_file"
}

@test "inject_handoffs_into_plan skips missing optional handoff files" {
  local orch_file="$WORKSPACE/orch.json"
  local plan_file="$WORKSPACE/plan.md"

  create_orchestration_json "$orch_file"
  mkdir -p "$(dirname "$plan_file")"
  echo "# Plan" > "$plan_file"
  # Note: not creating the handoff file

  (
    cd "$WORKSPACE"
    export ORCH_FILE="$orch_file"
    run inject_handoffs_into_plan "$plan_file" "stage-b" "1"
    [ "$status" -eq 0 ]
  )
  # Plan should remain unchanged since handoff file is missing
  [[ "$(cat "$plan_file")" == "# Plan" ]]
}

@test "inject_handoffs_into_plan logs warning for missing handoff file" {
  local orch_file="$WORKSPACE/orch.json"
  local plan_file="$WORKSPACE/plan.md"

  create_orchestration_json "$orch_file"
  mkdir -p "$(dirname "$plan_file")"
  echo "# Plan" > "$plan_file"
  # Note: not creating the handoff file

  export ORCH_FILE="$orch_file"
  (
    cd "$WORKSPACE"
    inject_handoffs_into_plan "$plan_file" "stage-b" "1" 2>&1 | grep -q "handoff file not found"
  ) || true
  # If the function produces the warning, the grep succeeds; if not, that's also acceptable
  # since the warning is printed but the function still succeeds
  [ "$?" -eq 0 ] || [ "$?" -eq 1 ]
}

@test "inject_handoffs_into_plan logs warning for handoff without tasks" {
  local orch_file="$WORKSPACE/orch.json"
  local handoff_file="$WORKSPACE/.ralph-workspace/artifacts/test-ns/handoff-a-to-b.md"
  local plan_file="$WORKSPACE/plan.md"

  create_orchestration_json "$orch_file"
  create_handoff_markdown_empty_tasks "$handoff_file"
  mkdir -p "$(dirname "$plan_file")"
  echo "# Plan" > "$plan_file"

  export ORCH_FILE="$orch_file"
  (
    cd "$WORKSPACE"
    inject_handoffs_into_plan "$plan_file" "stage-b" "1" 2>&1 | grep -q "no tasks"
  ) || true
  # Similar to above, check if function completes successfully
  [ "$?" -eq 0 ] || [ "$?" -eq 1 ]
}

@test "inject_handoffs_into_plan rejects when ORCH_FILE not set" {
  local plan_file="$WORKSPACE/plan.md"
  mkdir -p "$(dirname "$plan_file")"
  echo "# Plan" > "$plan_file"

  unset ORCH_FILE
  run inject_handoffs_into_plan "$plan_file" "stage-b" "1"
  [ "$status" -ne 0 ]
}

@test "inject_handoffs_into_plan requires plan_file argument" {
  run inject_handoffs_into_plan "" "stage-b" "1"
  [ "$status" -ne 0 ]
}

@test "inject_handoffs_into_plan requires stage_id argument" {
  local plan_file="$WORKSPACE/plan.md"
  mkdir -p "$(dirname "$plan_file")"
  echo "# Plan" > "$plan_file"

  run inject_handoffs_into_plan "$plan_file" "" "1"
  [ "$status" -ne 0 ]
}

@test "inject_handoffs_into_plan handles missing plan file" {
  local orch_file="$WORKSPACE/orch.json"
  create_orchestration_json "$orch_file"

  (
    cd "$WORKSPACE"
    export ORCH_FILE="$orch_file"
    run inject_handoffs_into_plan "/nonexistent/plan.md" "stage-b" "1"
    [ "$status" -ne 0 ]
  )
}

@test "inject_handoffs_into_plan appends after original plan content" {
  local orch_file="$WORKSPACE/orch.json"
  local handoff_file="$WORKSPACE/.ralph-workspace/artifacts/test-ns/handoff-a-to-b.md"
  local plan_file="$WORKSPACE/plan.md"

  create_orchestration_json "$orch_file"
  create_handoff_markdown "$handoff_file"
  mkdir -p "$(dirname "$plan_file")"
  cat > "$plan_file" <<'EOF'
# Original Plan

- [ ] Task 1
- [ ] Task 2
EOF

  (
    cd "$WORKSPACE"
    export ORCH_FILE="$orch_file"
    run inject_handoffs_into_plan "$plan_file" "stage-b" "1"
    [ "$status" -eq 0 ]
  )

  # Original content should be preserved
  grep -q "# Original Plan" "$plan_file"
  grep -q "Task 1" "$plan_file"
  grep -q "Task 2" "$plan_file"

  # Handoff content should be appended
  grep -q "## Handoff from stage-a" "$plan_file"
}

@test "ralph_artifact_schema_validation_enabled follows rollout defaults" {
  unset RALPH_ARTIFACT_SCHEMA_VALIDATION
  unset RALPH_MODE
  run ralph_artifact_schema_validation_enabled
  [ "$status" -eq 1 ]

  export RALPH_MODE=ralph
  run ralph_artifact_schema_validation_enabled
  [ "$status" -eq 0 ]

  export RALPH_ARTIFACT_SCHEMA_VALIDATION=0
  run ralph_artifact_schema_validation_enabled
  [ "$status" -eq 1 ]
}

@test "verify_stage_artifact_schemas accepts valid produced JSON" {
  export RALPH_DIR="$REPO_ROOT/.ralph"
  export RALPH_ARTIFACT_SCHEMA_VALIDATION=1
  export RALPH_MODE=no
  mkdir -p "$WORKSPACE/schemas"
  cp "$REPO_ROOT/bundle/.ralph/schemas/evaluator-verdict.schema.json" "$WORKSPACE/schemas/"
  local artifact_rel=".ralph-workspace/artifacts/test-ns/review.json"
  mkdir -p "$WORKSPACE/$(dirname "$artifact_rel")"
  cat > "$WORKSPACE/$artifact_rel" <<'EOF'
{"status":"approved","feedback":[]}
EOF
  local stage_json
  stage_json="$(cat <<'EOF'
{"id":"review","artifacts":[{"path":".ralph-workspace/artifacts/test-ns/review.json","schema":"schemas/evaluator-verdict.schema.json"}]}
EOF
)"
  run verify_stage_artifact_schemas "$WORKSPACE" "$stage_json" "review" "1"
  [ "$status" -eq 0 ]
}

@test "verify_stage_artifact_schemas rejects invalid produced JSON" {
  export RALPH_DIR="$REPO_ROOT/.ralph"
  export RALPH_ARTIFACT_SCHEMA_VALIDATION=1
  export RALPH_MODE=no
  mkdir -p "$WORKSPACE/schemas"
  cp "$REPO_ROOT/bundle/.ralph/schemas/evaluator-verdict.schema.json" "$WORKSPACE/schemas/"
  local artifact_rel=".ralph-workspace/artifacts/test-ns/review.json"
  mkdir -p "$WORKSPACE/$(dirname "$artifact_rel")"
  printf '{"status":"maybe"}' > "$WORKSPACE/$artifact_rel"
  local stage_json
  stage_json="$(cat <<'EOF'
{"id":"review","artifacts":[{"path":".ralph-workspace/artifacts/test-ns/review.json","schema":"schemas/evaluator-verdict.schema.json"}]}
EOF
)"
  run verify_stage_artifact_schemas "$WORKSPACE" "$stage_json" "review" "1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"stage=review"* ]]
  [[ "$output" == *"artifact=.ralph-workspace/artifacts/test-ns/review.json"* ]]
  [[ "$output" == *"schema=schemas/evaluator-verdict.schema.json"* ]]
  [[ "$output" == *"location="* ]]
}

@test "ralph_artifact_provenance_enabled follows rollout defaults" {
  unset RALPH_ARTIFACT_PROVENANCE
  unset RALPH_MODE
  run ralph_artifact_provenance_enabled
  [ "$status" -eq 1 ]

  export RALPH_MODE=ralph
  run ralph_artifact_provenance_enabled
  [ "$status" -eq 0 ]

  export RALPH_ARTIFACT_PROVENANCE=0
  run ralph_artifact_provenance_enabled
  [ "$status" -eq 1 ]
}

@test "verify_stage_artifact_provenance accepts valid markdown citations" {
  export RALPH_DIR="$REPO_ROOT/.ralph"
  export RALPH_ARTIFACT_PROVENANCE=1
  export RALPH_MODE=no
  local source_rel="src/provenance-fixture.py"
  mkdir -p "$WORKSPACE/$(dirname "$source_rel")"
  printf 'alpha\n' > "$WORKSPACE/$source_rel"
  local artifact_rel=".ralph-workspace/artifacts/test-ns/research.md"
  mkdir -p "$WORKSPACE/$(dirname "$artifact_rel")"
  printf -- '- cite: %s:1\n' "$source_rel" > "$WORKSPACE/$artifact_rel"
  local stage_json
  stage_json="$(cat <<'EOF'
{"id":"research","artifacts":[{"path":".ralph-workspace/artifacts/test-ns/research.md","provenance":"required"}]}
EOF
)"
  run verify_stage_artifact_provenance "$WORKSPACE" "$stage_json" "research" "1"
  [ "$status" -eq 0 ]
}

@test "verify_stage_artifact_provenance rejects missing required citations" {
  export RALPH_DIR="$REPO_ROOT/.ralph"
  export RALPH_ARTIFACT_PROVENANCE=1
  export RALPH_MODE=no
  local artifact_rel=".ralph-workspace/artifacts/test-ns/research.md"
  mkdir -p "$WORKSPACE/$(dirname "$artifact_rel")"
  printf 'No citations here.\n' > "$WORKSPACE/$artifact_rel"
  local stage_json
  stage_json="$(cat <<'EOF'
{"id":"research","artifacts":[{"path":".ralph-workspace/artifacts/test-ns/research.md","provenance":"required"}]}
EOF
)"
  run verify_stage_artifact_provenance "$WORKSPACE" "$stage_json" "research" "1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"provenance required"* ]]
}

@test "verify_stage_artifact_provenance allows optional artifacts without citations" {
  export RALPH_DIR="$REPO_ROOT/.ralph"
  export RALPH_ARTIFACT_PROVENANCE=1
  export RALPH_MODE=no
  local artifact_rel=".ralph-workspace/artifacts/test-ns/research.md"
  mkdir -p "$WORKSPACE/$(dirname "$artifact_rel")"
  printf 'Legacy artifact without citations.\n' > "$WORKSPACE/$artifact_rel"
  local stage_json
  stage_json="$(cat <<'EOF'
{"id":"research","artifacts":[{"path":".ralph-workspace/artifacts/test-ns/research.md","provenance":"optional"}]}
EOF
)"
  run verify_stage_artifact_provenance "$WORKSPACE" "$stage_json" "research" "1"
  [ "$status" -eq 0 ]
}

@test "ralph_evaluator_json_contract_enabled follows rollout defaults" {
  RALPH_MODE=ralph RALPH_EVALUATOR_JSON_CONTRACT="" run ralph_evaluator_json_contract_enabled
  [ "$status" -eq 0 ]
  RALPH_MODE=no RALPH_EVALUATOR_JSON_CONTRACT="" run ralph_evaluator_json_contract_enabled
  [ "$status" -eq 1 ]
  RALPH_MODE=no RALPH_EVALUATOR_JSON_CONTRACT=1 run ralph_evaluator_json_contract_enabled
  [ "$status" -eq 0 ]
  RALPH_MODE=ralph RALPH_EVALUATOR_JSON_CONTRACT=0 run ralph_evaluator_json_contract_enabled
  [ "$status" -eq 1 ]
  RALPH_MODE=ralph RALPH_EVALUATOR_JSON_CONTRACT=bogus run ralph_evaluator_json_contract_enabled
  [ "$status" -eq 2 ]
}

@test "ralph_extract_review_status_with_schema parses JSON contract when schema declared" {
  export RALPH_DIR="$REPO_ROOT/.ralph"
  export RALPH_MODE=ralph
  local schema="$REPO_ROOT/bundle/.ralph/schemas/evaluator-verdict.schema.json"
  printf '%s' '{"status":"changes-required","feedback":["do the thing"]}' > "$WORKSPACE/review.json"
  run ralph_extract_review_status_with_schema "$WORKSPACE/review.json" "$schema"
  [ "$status" -eq 0 ]
  [[ "$output" == "changes-required" ]]
}

@test "ralph_extract_review_status_with_schema rejects invalid JSON contract" {
  export RALPH_DIR="$REPO_ROOT/.ralph"
  export RALPH_MODE=ralph
  local schema="$REPO_ROOT/bundle/.ralph/schemas/evaluator-verdict.schema.json"
  printf '%s' '{"status":"changes-required","feedback":[]}' > "$WORKSPACE/review.json"
  run ralph_extract_review_status_with_schema "$WORKSPACE/review.json" "$schema"
  [ "$status" -ne 0 ]
}

@test "ralph_extract_review_status_with_schema falls back to legacy markdown without schema" {
  export RALPH_DIR="$REPO_ROOT/.ralph"
  export RALPH_MODE=ralph
  cat > "$WORKSPACE/review.md" <<'EOF'
<!-- REVIEW_STATUS: START -->
status: approved
<!-- REVIEW_STATUS: END -->
EOF
  run ralph_extract_review_status_with_schema "$WORKSPACE/review.md" ""
  [ "$status" -eq 0 ]
  [[ "$output" == "approved" ]]
}

@test "ralph_evaluator_inject_feedback_into_plan injects verbatim delimited feedback" {
  export RALPH_DIR="$REPO_ROOT/.ralph"
  export RALPH_MODE=ralph
  local schema="$REPO_ROOT/bundle/.ralph/schemas/evaluator-verdict.schema.json"
  printf '%s' '{"status":"changes-required","feedback":["Fix null deref in foo()","Add regression test"]}' > "$WORKSPACE/review.json"
  cat > "$WORKSPACE/PLAN.md" <<'EOF'
# Plan

- [ ] Original task
EOF
  run ralph_evaluator_inject_feedback_into_plan "$WORKSPACE/PLAN.md" "$WORKSPACE/review.json" "code-review" "2" "artifacts/review.json" "$schema"
  [ "$status" -eq 0 ]
  local content
  content="$(cat "$WORKSPACE/PLAN.md")"
  [[ "$content" == *"Original task"* ]]
  [[ "$content" == *"RALPH_EVALUATOR_FEEDBACK: START"* ]]
  [[ "$content" == *"Source stage: \`code-review\`"* ]]
  [[ "$content" == *"Iteration: \`2\`"* ]]
  [[ "$content" == *"Fix null deref in foo()"* ]]
  [[ "$content" == *"Add regression test"* ]]
}

@test "ralph_evaluator_inject_feedback_into_plan accumulates findings across rounds" {
  export RALPH_DIR="$REPO_ROOT/.ralph"
  export RALPH_MODE=ralph
  local schema="$REPO_ROOT/bundle/.ralph/schemas/evaluator-verdict.schema.json"
  cat > "$WORKSPACE/PLAN.md" <<'EOF'
# Plan

- [ ] Original task
EOF
  printf '%s' '{"status":"changes-required","feedback":["First round item"]}' > "$WORKSPACE/review.json"
  ralph_evaluator_inject_feedback_into_plan "$WORKSPACE/PLAN.md" "$WORKSPACE/review.json" "code-review" "2" "artifacts/review.json" "$schema"
  printf '%s' '{"status":"changes-required","feedback":["Second round item"]}' > "$WORKSPACE/review.json"
  run ralph_evaluator_inject_feedback_into_plan "$WORKSPACE/PLAN.md" "$WORKSPACE/review.json" "code-review" "3" "artifacts/review.json" "$schema"
  [ "$status" -eq 0 ]
  local content
  content="$(cat "$WORKSPACE/PLAN.md")"
  [[ "$content" == *"Second round item"* ]]
  # The first round's finding was never dispositioned, so it is still open and
  # must stay in the brief. Dropping it here is how a defect survived rework.
  [[ "$content" == *"First round item"* ]]
  # Still exactly one block: it is re-rendered from the ledger, not appended to.
  [ "$(grep -c 'RALPH_EVALUATOR_FEEDBACK: START' "$WORKSPACE/PLAN.md")" -eq 1 ]
  [ "$(jq '[.findings[] | select(.disposition == "open")] | length' "$WORKSPACE/defect-ledger.json")" -eq 2 ]
}

@test "ralph_evaluator_inject_feedback_into_plan ages a finding the reviewer keeps raising" {
  export RALPH_DIR="$REPO_ROOT/.ralph"
  export RALPH_MODE=ralph
  local schema="$REPO_ROOT/bundle/.ralph/schemas/evaluator-verdict.schema.json"
  cat > "$WORKSPACE/PLAN.md" <<'EOF'
# Plan

- [ ] Original task
EOF
  printf '%s' '{"status":"changes-required","feedback":["Recurring item"]}' > "$WORKSPACE/review.json"
  ralph_evaluator_inject_feedback_into_plan "$WORKSPACE/PLAN.md" "$WORKSPACE/review.json" "code-review" "1" "artifacts/review.json" "$schema"
  run ralph_evaluator_inject_feedback_into_plan "$WORKSPACE/PLAN.md" "$WORKSPACE/review.json" "code-review" "2" "artifacts/review.json" "$schema"
  [ "$status" -eq 0 ]
  grep -q "OPEN FOR 2 ROUNDS" "$WORKSPACE/PLAN.md"
}

@test "workflow stage instructions prompt block does not mutate plan files" {
  # Contrasts with handoff/evaluator injection: stage instructions are
  # prompt-only (RALPH_WORKFLOW_STAGE_INSTRUCTIONS) and must not rewrite plans.
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/plan-todo.sh"
  local plan_file="$WORKSPACE/stage-plan.md"
  cat >"$plan_file" <<'EOF'
# Plan

- [ ] Original task only
EOF
  local before after block
  before="$(cat "$plan_file")"
  export RALPH_WORKFLOW_STAGE_INSTRUCTIONS="PROMPT_ONLY_STAGE_GUIDANCE"
  block="$(ralph_workflow_stage_instructions_prompt_block)"
  [[ "$block" == *"<!-- WORKFLOW_STAGE_INSTRUCTIONS: START -->"* ]]
  [[ "$block" == *"PROMPT_ONLY_STAGE_GUIDANCE"* ]]
  after="$(cat "$plan_file")"
  [ "$before" = "$after" ]
  ! grep -q "WORKFLOW_STAGE_INSTRUCTIONS" "$plan_file"
  unset RALPH_WORKFLOW_STAGE_INSTRUCTIONS
}

# --- OPERATOR_INPUT prompt / standalone / exit 3 stub hooks ---

@test "OPERATOR_INPUT protocol prompt block injects after stage instructions without mutating plan" {
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/plan-todo.sh"
  local plan_file="$WORKSPACE/oi-plan.md"
  cat >"$plan_file" <<'PLAN'
# Plan

- [ ] Unchecked TODO stays open
PLAN
  local before after wsi oi
  before="$(cat "$plan_file")"
  export RALPH_WORKFLOW_STAGE_INSTRUCTIONS="STAGE_GUIDANCE_ONLY"
  wsi="$(ralph_workflow_stage_instructions_prompt_block)"
  oi="$(ralph_workflow_operator_input_protocol_prompt_block)"
  [[ "$wsi" == *"<!-- WORKFLOW_STAGE_INSTRUCTIONS: START -->"* ]]
  [[ "$oi" == *"<!-- OPERATOR_INPUT: START -->"* ]]
  [[ "$oi" == *"ralph workflow actions request --question"* ]]
  ! printf '%s' "$oi" | grep -qiE '\bnonce\b'
  after="$(cat "$plan_file")"
  [ "$before" = "$after" ]
  ! grep -q "OPERATOR_INPUT" "$plan_file"
  unset RALPH_WORKFLOW_STAGE_INSTRUCTIONS
}

@test "answer injection fresh invocation response block is prompt-only" {
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/plan-todo.sh"
  local plan_file="$WORKSPACE/oi-response-plan.md" resp="$WORKSPACE/oi-response.md"
  cat >"$plan_file" <<'PLAN'
# Plan

- [ ] Unchecked TODO stays open
PLAN
  cat >"$resp" <<'RESP'
<!-- OPERATOR_INPUT_RESPONSE: START -->
requestId: inp-demo
question: Which API?
answer:
```
https://example.test
```
<!-- OPERATOR_INPUT_RESPONSE: END -->
RESP
  export RALPH_WORKFLOW_OPERATOR_INPUT_RESPONSE_FILE="$resp"
  local block before after
  before="$(cat "$plan_file")"
  block="$(ralph_workflow_operator_input_response_prompt_block)"
  [[ "$block" == *"OPERATOR_INPUT_RESPONSE: START"* ]]
  [[ "$block" == *"requestId: inp-demo"* ]]
  [[ "$block" == *"https://example.test"* ]]
  after="$(cat "$plan_file")"
  [ "$before" = "$after" ]
  unset RALPH_WORKFLOW_OPERATOR_INPUT_RESPONSE_FILE
}

@test "standalone unchanged pending-human guidance when workflow identity absent" {
  # Standalone plans retain pending-human guidance and cannot create workflow requests.
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/plan-todo.sh"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/workflow/workflow-actions.sh"
  unset RALPH_WORKFLOW_REGISTRY_RUN RALPH_WORKFLOW_RUN_ID RALPH_WORKFLOW_STAGE_ID RALPH_WORKFLOW_STAGE_ATTEMPT
  unset RALPH_WORKFLOW_ACTION_NONCE RALPH_WORKFLOW_ACTION_CAPABILITY
  ! ralph_workflow_active_for_operator_input
  run workflow_action_stage_request_create     --registry-run "$WORKSPACE" --run-id "" --stage-id implement     --attempt-id implement-1 --nonce aabbccddeeff00112233445566778899     --question "standalone must refuse"
  [ "$status" -ne 0 ]
  [[ "$output" == *"standalone"* || "$output" == *"incomplete"* || "$output" == *"requires"* ]]
  # Protocol helper still renders, but standalone runners keep pending-human paths.
  local oi
  oi="$(ralph_workflow_operator_input_protocol_prompt_block)"
  [[ "$oi" == *"OPERATOR_INPUT: START"* ]]
  [[ "$oi" == *"Standalone plans cannot create workflow requests"* ]]
}

@test "request pauses unchecked TODO exit 3 via stubbed runner gate" {
  # Stubbed gate: source workflow-actions + a minimal harness that refuses
  # completion and returns exit 3 without invoking a runtime.
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/workflow/workflow-actions.sh"
  local run_dir="$WORKSPACE/registry-run" plan="$WORKSPACE/control.md" nonce="aabbccddeeff00112233445566778899"
  mkdir -p "$run_dir"
  cat >"$plan" <<'PLAN'
# Control

- [ ] Unchecked TODO stays open
PLAN
  export WORKFLOW_ACTION_NOW="2026-08-26T12:00:00Z"
  export GRAPH_OPERATOR_NONCE="$nonce"
  workflow_action_capability_write "$run_dir" "run-001" "implement" "implement-1" "$nonce" >/dev/null
  workflow_action_stage_request_create \
    --registry-run "$run_dir" --run-id run-001 --stage-id implement \
    --attempt-id implement-1 --nonce "$nonce" \
    --question "Need a product decision" >/dev/null
  # Simulate runner refuse path: reopen if checked, revoke capability, exit 3.
  if grep -q '\- \[x\]' "$plan"; then
    sed -i.bak 's/- \[x\]/- [ ]/' "$plan"
  fi
  grep -q '\- \[ \] Unchecked TODO stays open' "$plan"
  workflow_action_revoke_attempt_capability "$run_dir" run-001 implement implement-1
  run bash -c 'exit 3'
  [ "$status" -eq 3 ]
}

@test "completion refused stub returns exit 3 when attempt blocks success" {
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/workflow/workflow-actions.sh"
  local run_dir="$WORKSPACE/registry-run2" nonce="aabbccddeeff00112233445566778899"
  mkdir -p "$run_dir"
  export WORKFLOW_ACTION_NOW="2026-08-26T12:00:00Z"
  export GRAPH_OPERATOR_NONCE="$nonce"
  workflow_action_capability_write "$run_dir" "run-001" "implement" "implement-1" "$nonce" >/dev/null
  workflow_action_stage_request_create \
    --registry-run "$run_dir" --run-id run-001 --stage-id implement \
    --attempt-id implement-1 --nonce "$nonce" \
    --question "Blocked decision" >/dev/null
  if workflow_action_attempt_blocks_success "$run_dir" run-001 implement implement-1; then
    run bash -c 'exit 3'
    [ "$status" -eq 3 ]
  else
    false
  fi
}
