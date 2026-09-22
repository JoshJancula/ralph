---
execution: graph
pipeline:
  stages:
    - id: source
      runtime: cursor
      produces:
        - path: shared/input.md
todos:
  - id: source-1
    stage: source
    content: create the input
    status: pending
---
