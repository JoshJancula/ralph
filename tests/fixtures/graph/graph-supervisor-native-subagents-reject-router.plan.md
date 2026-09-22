---
execution: graph
pipeline:
  stages:
    - id: route
      type: router
      nativeSubagents: off
      router:
        allowedTargets:
          - next
        defaultTarget: next
    - id: next
      runtime: cursor
todos:
  - id: next-1
    stage: next
    content: continue
    status: pending
---
