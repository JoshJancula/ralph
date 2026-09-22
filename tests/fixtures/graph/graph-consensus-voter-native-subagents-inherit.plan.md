---
execution: graph
pipeline:
  stages:
    - id: review
      type: consensus
      voters:
        - id: alpha
          runtime: cursor
          nativeSubagents: inherit
        - id: beta
          runtime: codex
todos:
  - id: review-1
    stage: review
    content: review
    status: pending
---
