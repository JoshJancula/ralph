---
name: Orch JSON Characterization
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
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md
          required: true
      planFile: .ralph-workspace/plans/review-stage.plan.md
  parallelStages:
    - [research]
    - [review]
todos:
  - id: research-1
    stage: research
    content: Do the research and write findings.
    verification: Confirm research.md exists.
    status: pending
---
