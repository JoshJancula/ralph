---
name: checkpoint-test
namespace: checkpoint-test
execution: graph
pipeline:
  stages:
    - id: gate
      type: checkpoint
    - id: independent
      runtime: claude
      agent: research
    - id: after-gate
      runtime: claude
      agent: research
      dependsOn:
        - gate
todos:
  - id: independent-1
    stage: independent
    content: work independent
    verification: ok
    status: pending
  - id: after-gate-1
    stage: after-gate
    content: work after gate
    verification: ok
    status: pending
---
