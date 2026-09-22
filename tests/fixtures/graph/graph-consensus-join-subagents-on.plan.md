---
execution: graph
pipeline:
  stages:
    - id: review
      type: consensus
      produces:
        - path: ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/review/{{VOTER_ID}}.md"
      voters:
        - id: alpha
          runtime: cursor
        - id: beta
          runtime: codex
    - id: adjudicate
      type: join
      runtime: claude
      dependsOn:
        - review
todos:
  - id: review-1
    stage: review
    content: review
    status: pending
  - id: adjudicate-1
    stage: adjudicate
    content: adjudicate
    status: pending
---
