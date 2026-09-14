---
name: graph-tooling
execution: graph
pipeline:
  tooling:
    defaultProfile: ralph-compact
    overrides:
      qa: ralph-read-heavy
  stages:
    - id: research
      runtime: cursor
      toolingProfile: ralph-compact
      produces:
        - path: shared/research.md
    - id: qa
      runtime: cursor
      dependsOn:
        - research
      toolingProfile: ralph-read-heavy
      produces:
        - path: shared/qa.md
todos:
  - id: research-1
    stage: research
    content: do the research
    status: pending
  - id: qa-1
    stage: qa
    content: check the research
    status: pending
---
