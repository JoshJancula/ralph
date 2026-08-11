---
execution: graph
pipeline:
  stages:
    - id: review
      type: consensus
      voters:
        - id: alpha
          runtime: cursor
          agent: code-review
          subagents: off
        - id: beta
          runtime: codex
          agent: code-review
todos:
  - id: review-1
    stage: review
    content: review
    status: pending
---
