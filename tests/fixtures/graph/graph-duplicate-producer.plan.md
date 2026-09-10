---
execution: graph
pipeline:
  stages:
    - id: left
      runtime: cursor
      produces:
        - path: shared/output.md
    - id: right
      runtime: cursor
      produces:
        - path: shared/output.md
todos:
  - id: left-1
    stage: left
    content: write the shared output
    status: pending
  - id: right-1
    stage: right
    content: also write the shared output
    status: pending
---
