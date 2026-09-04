---
execution: graph
pipeline:
  stages:
    - id: implement
      runtime: cursor
      produces:
        - path: shared/output.md
  repairRounds:
    id: fix
    rounds: 1
    dependsOn:
      - implement
    integrate:
      requires:
        - path: shared/output.md
      produces:
        - path: shared/fix-integrated.md
    gate:
      requires:
        - path: shared/fix-integrated.md
    diagnose:
      runtime: cursor
      nativeSubagents: inherit
      content: diagnose gate failures and route to owning repair lanes
    lanes:
      - id: lane-a
        runtime: cursor
        nativeSubagents: off
        content: repair lane a scope
      - id: lane-b
        runtime: cursor
        content: repair lane b scope roleless
    reintegrate:
      produces:
        - path: shared/fix-reintegrated.md
todos:
  - id: implement-1
    stage: implement
    content: implement
    status: pending
---
