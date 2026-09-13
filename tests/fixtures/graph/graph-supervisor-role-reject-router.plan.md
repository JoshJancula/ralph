---
execution: graph
pipeline:
  stages:
    - id: route
      type: router
      role: research
      router:
        allowedTargets:
          - next
        defaultTarget: next
    - id: next
      runtime: cursor
      role: implementation
todos:
  - id: next-1
    stage: next
    content: continue
    status: pending
---
