#!/usr/bin/env bats

# orchestrator.sh accepts a structured orchestration .plan.md (pipeline frontmatter) and
# normalizes it into the .orch.json shape it already runs. ORCH_NORMALIZE_ONLY=1 stops
# right after the generated file is written so we can assert the conversion in isolation.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

orchestrator="$REPO_ROOT/.ralph/orchestrator.sh"
validate_plan_script="$REPO_ROOT/.ralph/validate-plan.sh"

setup() {
  WS="$(mktemp -d)"
}

teardown() {
  rm -rf "$WS"
}

write_orc_plan() {
  cat > "$WS/demo.plan.md" <<'EOF'
---
name: Demo Orchestration
execution: orchestration
pipeline:
  stages:
    - id: research
      runtime: cursor
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md
          required: true
    - id: review
      runtime: codex
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md
          required: true
      planFile: .ralph-workspace/plans/review-stage.plan.md
todos:
  - id: research-1
    stage: research
    content: Do the research and write findings.
    verification: Confirm research.md exists.
    status: pending
---
EOF
}

@test "orchestrator normalizes a structured .plan.md into .orch.json" {
  write_orc_plan
  run env ORCH_NORMALIZE_ONLY=1 ORCHESTRATOR_NO_COLOR=1 bash "$orchestrator" --orchestration "$WS/demo.plan.md" "$WS"
  [ "$status" -eq 0 ]

  gen="$WS/.ralph-workspace/orchestration-plans/demo/demo.orch.json"
  [ -f "$gen" ]
  [ "$(jq -r '.name' "$gen")" = "Demo Orchestration" ]
  [ "$(jq -r '.namespace' "$gen")" = "demo" ]
  [ "$(jq '.stages | length' "$gen")" -eq 2 ]
  # produces -> outputArtifacts + artifacts
  [ "$(jq -r '.stages[0].outputArtifacts[0].path' "$gen")" = ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md" ]
  [ "$(jq -r '.stages[0].artifacts[0].required' "$gen")" = "true" ]
  # _inlineTodos stripped after materialization; stage now points to a generated plan file
  [ "$(jq -r '.stages[0] | has("_inlineTodos")' "$gen")" = "false" ]
  inline_plan="$(jq -r '.stages[0].plan' "$gen")"
  [ -f "$inline_plan" ]
  grep -Fq 'Do the research and write findings.' "$inline_plan"
  # requires -> inputArtifacts; planFile passthrough preserved
  [ "$(jq -r '.stages[1].inputArtifacts[0].path' "$gen")" = ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md" ]
  [ "$(jq -r '.stages[1].plan' "$gen")" = ".ralph-workspace/plans/review-stage.plan.md" ]
}

@test "orchestrator materializes a valid runnable stage plan from inline todos" {
  write_orc_plan
  run env ORCH_NORMALIZE_ONLY=1 ORCHESTRATOR_NO_COLOR=1 bash "$orchestrator" --orchestration "$WS/demo.plan.md" "$WS"
  [ "$status" -eq 0 ]
  gen="$WS/.ralph-workspace/orchestration-plans/demo/demo.orch.json"
  inline_plan="$(jq -r '.stages[0].plan' "$gen")"
  run bash "$validate_plan_script" "$inline_plan"
  [ "$status" -eq 0 ]
}

@test "orchestrator still accepts a legacy .orch.json directly" {
  cat > "$WS/legacy.orch.json" <<'EOF'
{"name":"Legacy","namespace":"legacy","stages":[{"id":"only","runtime":"cursor","role":"research","plan":".ralph-workspace/plans/only.plan.md"}]}
EOF
  run env ORCHESTRATOR_DRY_RUN=1 ORCHESTRATOR_NO_COLOR=1 bash "$orchestrator" --orchestration "$WS/legacy.orch.json" "$WS"
  [ "$status" -eq 0 ]
}
