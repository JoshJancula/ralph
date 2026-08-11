---
# Graph mode authoring template.
#
# execution: graph is the only thing that distinguishes this from a plain
# pipeline plan - a graph node is a pipeline stage plus a small number of
# extra fields (type, dependsOn, voters, policy, ...). Compile this file with
# `ralph graph compile <this-file>` (or `bash bundle/.ralph/graph-run.sh
# compile <this-file>`) to lint it and cache a .graph.json beside it without
# running anything.
#
# This template shows every graph node shape covered by the GRAPH-MODE plan:
#   - research         a plain agent node (type defaults to "agent")
#   - implement         an agent node on a different runtime than research,
#                       consuming research's artifact via requires/produces
#                       (a derived edge - no dependsOn needed for that edge)
#   - review            a three-runtime consensus node: three voters, each a
#                       distinct provider, expanded at compile time into
#                       synthetic voter nodes plus a barrier node
#   - decide            a join node with policy: veto - any single
#                       changes-required verdict among the voters blocks
#   - human-checkpoint  a checkpoint node - a human acknowledgement gate that
#                       blocks only its own downstream subtree
name: GRAPH_PLAN_NAME_HERE
namespace: GRAPH_PLAN_NAMESPACE_HERE
execution: graph
pipeline:
  maxParallel: 3
  edgeDerivation: both
  failurePolicy: drain
  stages:
    - id: research
      runtime: cursor
      agent: research
      produces:
        - path: "{{ARTIFACT_NS}}/research.md"

    - id: implement
      runtime: claude
      agent: implementation
      dependsOn:
        - research
      requires:
        - path: "{{ARTIFACT_NS}}/research.md"
      produces:
        - path: "{{ARTIFACT_NS}}/implementation.md"

    - id: review
      type: consensus
      runtime: cursor
      agent: code-review
      quorum: 2
      minRuntimes: 3
      voters:
        - id: alpha
          runtime: cursor
          agent: code-review
        - id: beta
          runtime: codex
          agent: code-review
        - id: gamma
          runtime: claude
          agent: code-review
      dependsOn:
        - implement
      requires:
        - path: "{{ARTIFACT_NS}}/implementation.md"

    - id: decide
      type: join
      policy: veto
      dependsOn:
        - review

    - id: human-checkpoint
      type: checkpoint
      dependsOn:
        - decide

todos:
  - id: research-1
    stage: research
    content: Research the change and write findings to the shared artifact.
    status: pending

  - id: implement-1
    stage: implement
    content: Implement the change described by the research artifact.
    status: pending

  - id: review-1
    stage: review
    content: Review the implementation and record a verdict.
    status: pending

  - id: decide-1
    stage: decide
    content: Apply the veto policy to the three review verdicts.
    status: pending

  - id: human-checkpoint-1
    stage: human-checkpoint
    content: Wait for a human to acknowledge the decision before closing out.
    status: pending
---
