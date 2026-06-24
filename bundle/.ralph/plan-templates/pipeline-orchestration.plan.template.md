---
name: PLAN_TITLE_HERE
overview: PLAN_OVERVIEW_HERE
execution: orchestration
instructions: Execute one TODO at a time. After each, run the verification steps this project expects (build, test, lint, or equivalents as documented in README or below); keep fixing failures until they pass, and report the result with `TODO_VERIFICATION: PASS` or `TODO_VERIFICATION: FAIL: <reason>` as appropriate. When the TODO is done, set `status: completed` rather than marking `[x]`. For additional context see the original plan at PATH_TO_PLAN (if exists)
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
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/review.md
          required: true

todos:
  - id: research-1
    stage: research
    content: Research the change and write findings to .ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md.
    verification: Confirm .ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md exists and is non-empty.
    status: pending
  - id: review-1
    stage: review
    content: Read .ralph-workspace/artifacts/{{ARTIFACT_NS}}/research.md and write the review to .ralph-workspace/artifacts/{{ARTIFACT_NS}}/review.md.
    verification: Confirm .ralph-workspace/artifacts/{{ARTIFACT_NS}}/review.md exists and is non-empty.
    status: pending
isProject: false
---
