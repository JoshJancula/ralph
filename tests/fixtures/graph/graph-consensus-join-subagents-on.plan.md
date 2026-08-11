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
          agent: code-review
        - id: beta
          runtime: codex
          agent: code-review
    - id: adjudicate
      type: join
      runtime: claude
      agent: adjudicator
      subagents: on
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
