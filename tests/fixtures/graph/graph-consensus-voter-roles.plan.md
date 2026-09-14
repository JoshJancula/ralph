---
execution: graph
pipeline:
  stages:
    - id: source
      runtime: cursor
      role: research
      produces:
        - path: shared/input.md
    - id: review
      type: consensus
      runtime: cursor
      quorum: 2
      minRuntimes: 2
      voters:
        - id: alpha
          runtime: cursor
          role: code-review
        - id: beta
          runtime: codex
        - id: gamma
          runtime: claude
          role: security
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
