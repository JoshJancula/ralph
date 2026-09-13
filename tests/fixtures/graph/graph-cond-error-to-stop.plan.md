---
execution: graph
pipeline:
  stages:
    - id: implement
      runtime: cursor
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
      dependsOn:
        - id: gate-review
          condition: passed
      requires:
        - path: shared/output.md
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
---
