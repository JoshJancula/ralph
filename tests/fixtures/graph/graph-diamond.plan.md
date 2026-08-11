---
execution: graph
pipeline:
  stages:
    - id: source
      runtime: cursor
      agent: research
      produces:
        - path: shared/input.md
    - id: left
      runtime: cursor
      agent: implementation
      dependsOn:
        - source
      requires:
        - path: shared/input.md
      produces:
        - path: shared/left.md
    # Distinct runtime from left so the default per-runtime cap of 1 still
    # permits the diamond middle nodes to overlap (cross-provider happy path).
    - id: right
      runtime: claude
      agent: implementation
      dependsOn:
        - source
      requires:
        - path: shared/input.md
      produces:
        - path: shared/right.md
    - id: sink
      runtime: cursor
      agent: implementation
      dependsOn:
        - left
        - right
      requires:
        - path: shared/left.md
        - path: shared/right.md
todos:
  - id: source-1
    stage: source
    content: create the input
    status: pending
  - id: left-1
    stage: left
    content: transform the input on the left branch
    status: pending
  - id: right-1
    stage: right
    content: transform the input on the right branch
    status: pending
  - id: sink-1
    stage: sink
    content: merge the branch outputs
    status: pending
---
