---
execution: graph
pipeline:
  stages:
    - id: implement
      runtime: cursor
      agent: implementation
      produces:
        - path: shared/output.md
  repairRounds:
    id: fix
    rounds: 0
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
todos:
  - id: implement-1
    stage: implement
    content: implement the feature
    status: pending
---
