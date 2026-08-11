---
execution: graph
pipeline:
  stages:
    - id: prepare
      runtime: cursor
      agent: implementation
      produces:
        - path: shared/prepared.md
    - id: gate-check
      type: gate
      dependsOn:
        - prepare
      requires:
        - path: shared/prepared.md
    - id: finalize
      runtime: cursor
      agent: implementation
      dependsOn:
        - id: gate-check
          condition: passed
        - prepare
      requires:
        - path: shared/prepared.md
todos:
  - id: prepare-1
    stage: prepare
    content: prepare the artifact
    status: pending
  - id: gate-check-1
    stage: gate-check
    content: check the artifact
    status: pending
  - id: finalize-1
    stage: finalize
    content: finalize using both unconditional and conditional predecessors
    status: pending
---
