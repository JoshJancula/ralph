---
execution: graph
pipeline:
  stages:
    - id: source
      runtime: cursor
      produces:
        - path: shared/input.md
    - id: transform
      runtime: cursor
      dependsOn:
        - source
      requires:
        - path: shared/input.md
      produces:
        - path: shared/output.md
    - id: sink
      runtime: cursor
      dependsOn:
        - transform
      requires:
        - path: shared/output.md
todos:
  - id: source-1
    stage: source
    content: create the input
    status: pending
  - id: transform-1
    stage: transform
    content: transform the input
    status: pending
  - id: sink-1
    stage: sink
    content: consume the output
    status: pending
---
