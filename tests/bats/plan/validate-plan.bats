#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

setup() {
  bats_skip_known_ci_flakes
  TEST_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/ralph-validate-plan.XXXXXX")"
  VALIDATE_PLAN_SH="$BATS_TEST_DIRNAME/../../../bundle/.ralph/validate-plan.sh"
  RUN_PLAN_SH="$BATS_TEST_DIRNAME/../../../bundle/.ralph/run-plan.sh"
}

teardown() {
  rm -rf "${TEST_TMPDIR:-}"
}

@test "validate-plan accepts a valid classic markdown plan" {
  plan_file="$TEST_TMPDIR/classic.plan.md"
  cat <<'EOF' >"$plan_file"
- [ ] do the thing
EOF

  run bash "$VALIDATE_PLAN_SH" "$plan_file"
  [ "$status" -eq 0 ]
}

@test "validate-plan accepts a valid pipeline standard plan" {
  plan_file="$TEST_TMPDIR/simple.plan.md"
  cat <<'EOF' >"$plan_file"
---
execution: standard
todos:
  - id: simple-1
    content: do the thing
    status: pending
---
EOF

  run bash "$VALIDATE_PLAN_SH" "$plan_file"
  [ "$status" -eq 0 ]
}

@test "validate-plan accepts a valid pipeline orchestration plan" {
  plan_file="$TEST_TMPDIR/orchestration.plan.md"
  cat <<'EOF' >"$plan_file"
---
execution: orchestration
pipeline:
  stages:
    - id: research
      runtime: cursor
      agent: research
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md
          required: true
    - id: review
      runtime: codex
      agent: code-review
      loopBackTo: research
      maxIterations: 2
      loopCheck:
        path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/review-status.md
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/review.md
          required: true
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/review-status.md
          required: true
  parallelStages:
    - [research]
    - [review]
todos:
  - id: research-1
    stage: research
    content: research the change
    status: pending
    produces:
      - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md
        required: true
  - id: review-1
    stage: review
    content: review the change
    status: pending
    produces:
      - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/review-status.md
        required: true
---
EOF

  run bash "$VALIDATE_PLAN_SH" "$plan_file"
  [ "$status" -eq 0 ]
}

write_loop_contract_plan() {
  local plan_file="$1"
  local on_exhausted="$2"
  local schema="$3"
  cat >"$plan_file" <<EOF
---
execution: orchestration
pipeline:
  stages:
    - id: research
      runtime: cursor
      agent: research
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md
          required: true
    - id: review
      runtime: codex
      agent: code-review
      loopBackTo: research
      maxIterations: 2
      onExhausted: $on_exhausted
      loopCheck:
        path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/review-status.json
        schema: $schema
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/review.md
          required: true
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/review-status.json
          required: true
---
EOF
}

@test "validate-plan accepts loopCheck.schema and onExhausted" {
  plan_file="$TEST_TMPDIR/loop-contract.plan.md"
  write_loop_contract_plan "$plan_file" "proceed" "bundle/.ralph/schemas/evaluator-verdict.schema.json"
  run bash "$VALIDATE_PLAN_SH" "$plan_file"
  [ "$status" -eq 0 ]
}

@test "validate-plan rejects an invalid onExhausted value" {
  plan_file="$TEST_TMPDIR/loop-contract-bad.plan.md"
  write_loop_contract_plan "$plan_file" "maybe" "bundle/.ralph/schemas/evaluator-verdict.schema.json"
  run bash "$VALIDATE_PLAN_SH" "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"onExhausted"* ]]
}

@test "validate-plan rejects an absolute loopCheck.schema path" {
  plan_file="$TEST_TMPDIR/loop-contract-abs.plan.md"
  write_loop_contract_plan "$plan_file" "proceed" "/etc/passwd"
  run bash "$VALIDATE_PLAN_SH" "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"loopCheck.schema"* ]]
}

@test "validate-plan rejects a TODO referencing an unknown stage" {
  plan_file="$TEST_TMPDIR/unknown-stage.plan.md"
  cat <<'EOF' >"$plan_file"
---
execution: orchestration
pipeline:
  stages:
    - id: review
      runtime: cursor
      agent: research
todos:
  - id: review-1
    stage: missing
    content: review the change
    status: pending
---
EOF

  run bash "$VALIDATE_PLAN_SH" "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"todo review-1 stage: unknown stage 'missing'"* ]]
}

@test "validate-plan rejects duplicate stage ids" {
  plan_file="$TEST_TMPDIR/duplicate-stage.plan.md"
  cat <<'EOF' >"$plan_file"
---
execution: orchestration
pipeline:
  stages:
    - id: review
      runtime: cursor
      agent: research
    - id: review
      runtime: codex
      agent: code-review
todos:
  - id: review-1
    stage: review
    content: review the change
    status: pending
---
EOF

  run bash "$VALIDATE_PLAN_SH" "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"stage review id: duplicate stage id"* ]]
}

@test "validate-plan rejects an invalid stage id format" {
  plan_file="$TEST_TMPDIR/bad-stage-id.plan.md"
  cat <<'EOF' >"$plan_file"
---
execution: orchestration
pipeline:
  stages:
    - id: Review
      runtime: cursor
      agent: research
todos:
  - id: review-1
    stage: Review
    content: review the change
    status: pending
---
EOF

  run bash "$VALIDATE_PLAN_SH" "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"stage Review id: invalid stage id format"* ]]
}

@test "validate-plan rejects a stage missing both agent and model" {
  plan_file="$TEST_TMPDIR/missing-routing.plan.md"
  cat <<'EOF' >"$plan_file"
---
execution: orchestration
pipeline:
  stages:
    - id: review
      runtime: cursor
todos:
  - id: review-1
    stage: review
    content: review the change
    status: pending
---
EOF

  run bash "$VALIDATE_PLAN_SH" "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"stage review routing: must declare agent or model"* ]]
}

@test "validate-plan accepts a stage with planFile (no agent/model required)" {
  plan_file="$TEST_TMPDIR/planfile-stage.plan.md"
  cat <<'EOF' >"$plan_file"
---
execution: orchestration
pipeline:
  stages:
    - id: review
      planFile: .ralph-workspace/plans/review-stage.plan.md
todos:
  - id: review-1
    stage: review
    content: Run nested plan
    status: pending
---
EOF

  run bash "$VALIDATE_PLAN_SH" "$plan_file"
  [ "$status" -eq 0 ]
}

@test "validate-plan rejects a stage with an invalid planFile path" {
  plan_file="$TEST_TMPDIR/planfile-invalid-path.plan.md"
  cat <<'EOF' >"$plan_file"
---
execution: orchestration
pipeline:
  stages:
    - id: review
      planFile: ../../../etc/passwd
todos:
  - id: review-1
    stage: review
    content: Run nested plan
    status: pending
---
EOF

  run bash "$VALIDATE_PLAN_SH" "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"planFile"* ]]
}

@test "validate-plan rejects a routing-rule violation" {
  plan_file="$TEST_TMPDIR/routing-violation.plan.md"
  cat <<'EOF' >"$plan_file"
---
execution: orchestration
pipeline:
  stages:
    - id: review
      runtime: cursor
      agent: research
todos:
  - id: review-1
    stage: review
    runtime: codex
    content: review the change
    status: pending
---
EOF

  run bash "$VALIDATE_PLAN_SH" "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"todo review-1 runtime: overriding a staged runtime requires agent or model"* ]]
}

@test "validate-plan rejects invalid artifact shorthand" {
  plan_file="$TEST_TMPDIR/artifact-shorthand.plan.md"
  cat <<'EOF' >"$plan_file"
---
execution: orchestration
pipeline:
  stages:
    - id: review
      runtime: cursor
      agent: research
      produces:
        - .ralph-workspace/artifacts/{{ARTIFACT_NS}}/review.md
todos:
  - id: review-1
    stage: review
    content: review the change
    status: pending
---
EOF

  run bash "$VALIDATE_PLAN_SH" "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"stage review produces[0]: invalid artifact shorthand"* ]]
}

@test "validate-plan rejects absolute artifact paths" {
  plan_file="$TEST_TMPDIR/absolute-path.plan.md"
  cat <<'EOF' >"$plan_file"
---
execution: orchestration
pipeline:
  stages:
    - id: review
      runtime: cursor
      agent: research
      produces:
        - path: /tmp/review.md
todos:
  - id: review-1
    stage: review
    content: review the change
    status: pending
---
EOF

  run bash "$VALIDATE_PLAN_SH" "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"stage review produces[0].path: absolute paths are not portable"* ]]
}

@test "validate-plan rejects parent traversal artifact paths" {
  plan_file="$TEST_TMPDIR/parent-traversal.plan.md"
  cat <<'EOF' >"$plan_file"
---
execution: orchestration
pipeline:
  stages:
    - id: review
      runtime: cursor
      agent: research
      produces:
        - path: ../review.md
todos:
  - id: review-1
    stage: review
    content: review the change
    status: pending
---
EOF

  run bash "$VALIDATE_PLAN_SH" "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"stage review produces[0].path: parent traversal is not portable"* ]]
}

@test "validate-plan rejects unsupported artifact tokens" {
  plan_file="$TEST_TMPDIR/unsupported-token.plan.md"
  cat <<'EOF' >"$plan_file"
---
execution: orchestration
pipeline:
  stages:
    - id: review
      runtime: cursor
      agent: research
      produces:
        - path: .ralph-workspace/artifacts/{{FOO}}/review.md
todos:
  - id: review-1
    stage: review
    content: review the change
    status: pending
---
EOF

  run bash "$VALIDATE_PLAN_SH" "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"stage review produces[0].path: unsupported token {{FOO}}"* ]]
}

@test "validate-plan rejects an invalid loopBackTo" {
  plan_file="$TEST_TMPDIR/invalid-loopback.plan.md"
  cat <<'EOF' >"$plan_file"
---
execution: orchestration
pipeline:
  stages:
    - id: review
      runtime: cursor
      agent: research
      loopBackTo: missing
      maxIterations: 2
      loopCheck:
        path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/review-status.md
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/review-status.md
          required: true
todos:
  - id: review-1
    stage: review
    content: review the change
    status: pending
    produces:
      - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/review-status.md
        required: true
---
EOF

  run bash "$VALIDATE_PLAN_SH" "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"stage review loopBackTo: unknown stage 'missing'"* ]]
}

@test "validate-plan rejects an invalid maxIterations" {
  plan_file="$TEST_TMPDIR/invalid-max-iterations.plan.md"
  cat <<'EOF' >"$plan_file"
---
execution: orchestration
pipeline:
  stages:
    - id: review
      runtime: cursor
      agent: research
      loopBackTo: research
      maxIterations: 0
      loopCheck:
        path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/review-status.md
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/review-status.md
          required: true
    - id: research
      runtime: cursor
      agent: research
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md
          required: true
todos:
  - id: review-1
    stage: review
    content: review the change
    status: pending
    produces:
      - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/review-status.md
        required: true
---
EOF

  run bash "$VALIDATE_PLAN_SH" "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"stage review maxIterations: must be a positive integer"* ]]
}

@test "validate-plan rejects a missing loopCheck.path for a loop source" {
  plan_file="$TEST_TMPDIR/missing-loopcheck.plan.md"
  cat <<'EOF' >"$plan_file"
---
execution: orchestration
pipeline:
  stages:
    - id: review
      runtime: cursor
      agent: research
      loopBackTo: research
      maxIterations: 2
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/review-status.md
          required: true
    - id: research
      runtime: cursor
      agent: research
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md
          required: true
todos:
  - id: review-1
    stage: review
    content: review the change
    status: pending
    produces:
      - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/review-status.md
        required: true
---
EOF

  run bash "$VALIDATE_PLAN_SH" "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"stage review loopCheck.path: required when loopBackTo is set"* ]]
}

@test "validate-plan rejects a loopCheck.path missing from required effective produces" {
  plan_file="$TEST_TMPDIR/missing-effective-produce.plan.md"
  cat <<'EOF' >"$plan_file"
---
execution: orchestration
pipeline:
  stages:
    - id: research
      runtime: cursor
      agent: research
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md
          required: true
    - id: review
      runtime: cursor
      agent: research
      loopBackTo: research
      maxIterations: 2
      loopCheck:
        path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/review-status.md
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/review.md
          required: true
todos:
  - id: review-1
    stage: review
    content: review the change
    status: pending
    produces:
      - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/review.md
        required: true
---
EOF

  run bash "$VALIDATE_PLAN_SH" "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"stage review loopCheck.path: missing from required effective produces"* ]]
}

@test "validate-plan rejects an invalid parallelStages shape" {
  plan_file="$TEST_TMPDIR/bad-parallel-stages.plan.md"
  cat <<'EOF' >"$plan_file"
---
execution: orchestration
pipeline:
  stages:
    - id: review
      runtime: cursor
      agent: research
  parallelStages: [review]
todos:
  - id: review-1
    stage: review
    content: review the change
    status: pending
---
EOF

  run bash "$VALIDATE_PLAN_SH" "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"pipeline.parallelStages:"* ]]
}

@test "validate-plan accepts valid parallelStages metadata" {
  plan_file="$TEST_TMPDIR/valid-parallel-stages.plan.md"
  cat <<'EOF' >"$plan_file"
---
execution: orchestration
pipeline:
  stages:
    - id: research
      runtime: cursor
      agent: research
    - id: review
      runtime: codex
      agent: code-review
    - id: qa
      runtime: claude
      agent: qa
  parallelStages:
    - [research, review]
    - [qa]
todos:
  - id: research-1
    stage: research
    content: research the change
    status: pending
---
EOF

  run bash "$VALIDATE_PLAN_SH" "$plan_file"
  [ "$status" -eq 0 ]
}

@test "validate-plan rejects duplicate stage ids across parallel waves" {
  plan_file="$TEST_TMPDIR/duplicate-parallel-stage.plan.md"
  cat <<'EOF' >"$plan_file"
---
execution: orchestration
pipeline:
  stages:
    - id: research
      runtime: cursor
      agent: research
    - id: review
      runtime: codex
      agent: code-review
  parallelStages:
    - [research]
    - [research, review]
todos:
  - id: research-1
    stage: research
    content: research the change
    status: pending
---
EOF

  run bash "$VALIDATE_PLAN_SH" "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"pipeline.parallelStages[2][1]: duplicate stage 'research' across parallel waves"* ]]
}

@test "run-plan fails fast on an invalid pipeline plan" {
  workspace="$TEST_TMPDIR/workspace"
  mkdir -p "$workspace/bin"
  cat <<'EOF' >"$workspace/bin/cursor"
#!/usr/bin/env bash
exit 99
EOF
  chmod +x "$workspace/bin/cursor"

  plan_file="$workspace/invalid.plan.md"
  cat <<'EOF' >"$plan_file"
---
execution: orchestration
pipeline:
  stages:
    - id: review
      runtime: cursor
      agent: research
todos:
  - id: review-1
    stage: missing
    content: review the change
    status: pending
---
EOF

  run env -u RALPH_AGENT_TOOL_ACCESS PATH="$workspace/bin:$PATH" bash "$RUN_PLAN_SH" --runtime cursor --model test-model --non-interactive --workspace "$workspace" --plan invalid.plan.md
  [ "$status" -ne 0 ]
  [[ "$output" == *"todo review-1 stage: unknown stage 'missing'"* ]]
}
