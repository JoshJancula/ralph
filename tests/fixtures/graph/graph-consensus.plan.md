---
execution: graph
pipeline:
  stages:
    - id: source
      runtime: cursor
      agent: research
      produces:
        - path: shared/input.md
    - id: review
      type: consensus
      runtime: cursor
      agent: code-review
      quorum: 2
      minRuntimes: 2
      voters:
        - id: alpha
          runtime: cursor
          agent: code-review
        - id: beta
          runtime: codex
          agent: code-review
        - id: gamma
          runtime: claude
          agent: code-review
      dependsOn:
        - source
      requires:
        - path: shared/input.md
todos:
  - id: source-1
    stage: source
    content: create the input
    status: pending
  - id: review-1
    stage: review
    content: review the input
    status: pending
---
