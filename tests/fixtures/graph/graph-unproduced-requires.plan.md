---
execution: graph
pipeline:
  stages:
    - id: consumer
      runtime: cursor
      agent: implementation
      requires:
        - path: external/input.md
todos:
  - id: consumer-1
    stage: consumer
    content: read the external input
    status: pending
---
