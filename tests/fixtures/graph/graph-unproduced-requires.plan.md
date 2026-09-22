---
execution: graph
pipeline:
  stages:
    - id: consumer
      runtime: cursor
      requires:
        - path: external/input.md
todos:
  - id: consumer-1
    stage: consumer
    content: read the external input
    status: pending
---
