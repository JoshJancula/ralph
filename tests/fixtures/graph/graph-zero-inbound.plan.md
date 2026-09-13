---
execution: graph
pipeline:
  stages:
    - id: alpha
      runtime: cursor
      produces:
        - path: shared/input.md
    - id: beta
      runtime: cursor
    - id: gamma
      runtime: cursor
      dependsOn:
        - alpha
    - id: delta
      runtime: cursor
      requires:
        - path: external/input.md
todos:
  - id: alpha-1
    stage: alpha
    content: create the input
    status: pending
  - id: beta-1
    stage: beta
    content: work independently
    status: pending
  - id: gamma-1
    stage: gamma
    content: consume the input
    status: pending
  - id: delta-1
    stage: delta
    content: use the external input
    status: pending
---
