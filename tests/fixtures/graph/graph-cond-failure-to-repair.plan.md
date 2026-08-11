---
execution: graph
pipeline:
  stages:
    - id: implement
      runtime: cursor
      agent: implementation
      produces:
        - path: shared/output.md
    - id: gate-review
      type: gate
      dependsOn:
        - implement
      requires:
        - path: shared/output.md
    - id: publish
      runtime: cursor
      agent: implementation
      dependsOn:
        - id: gate-review
          condition: passed
      requires:
        - path: shared/output.md
    - id: repair
      runtime: cursor
      agent: implementation
      dependsOn:
        - id: gate-review
          condition: changes-required
      requires:
        - path: shared/output.md
      produces:
        - path: shared/revised.md
todos:
  - id: implement-1
    stage: implement
    content: implement the feature
    status: pending
  - id: gate-review-1
    stage: gate-review
    content: review the implementation
    status: pending
  - id: publish-1
    stage: publish
    content: publish the result
    status: pending
  - id: repair-1
    stage: repair
    content: apply reviewer feedback
    status: pending
---
