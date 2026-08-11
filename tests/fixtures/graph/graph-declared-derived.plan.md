---
execution: graph
pipeline:
  stages:
    - id: source
      runtime: cursor
      agent: research
      produces:
        - path: shared/output.md
    - id: consumer
      runtime: cursor
      agent: implementation
      dependsOn:
        - source
      requires:
        - path: shared/output.md
todos:
  - id: source-1
    stage: source
    content: write the shared output
    status: pending
  - id: consumer-1
    stage: consumer
    content: consume the shared output
    status: pending
---
