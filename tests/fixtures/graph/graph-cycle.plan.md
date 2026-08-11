---
execution: graph
pipeline:
  stages:
    - id: a
      runtime: cursor
      agent: research
      dependsOn:
        - c
    - id: b
      runtime: cursor
      agent: implementation
      dependsOn:
        - a
    - id: c
      runtime: cursor
      agent: implementation
      dependsOn:
        - b
todos:
  - id: a-1
    stage: a
    content: stage a
    status: pending
  - id: b-1
    stage: b
    content: stage b
    status: pending
  - id: c-1
    stage: c
    content: stage c
    status: pending
---
