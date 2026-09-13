---
name: graph-rework-loop
execution: graph
pipeline:
  maxReworkIterations: 2
  stages:
    - id: implement
      runtime: cursor
      produces:
        - path: shared/output.md
    - id: review
      runtime: cursor
      dependsOn:
        - implement
      produces:
        - path: shared/verdict.json
          schema: bundle/.ralph/schemas/evaluator-verdict.schema.json
      loopBackTo: implement
      loopCheck:
        path: shared/verdict.json
        schema: bundle/.ralph/schemas/evaluator-verdict.schema.json
      onExhausted: fail
todos:
  - id: implement-1
    stage: implement
    content: implement the feature
    status: pending
  - id: review-1
    stage: review
    content: review the feature
    status: pending
---
