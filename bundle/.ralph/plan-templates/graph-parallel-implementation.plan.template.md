---
name: GRAPH_PLAN_NAME_HERE
namespace: GRAPH_PLAN_NAMESPACE_HERE
overview: Parallel implementation authoring template with static ownership and deterministic integration.
execution: graph
instructions: Two-pass planning only. Validate the proposed static shards and ownership map, then compile to freeze this topology before execution. Never add nodes to a live run.
pipeline:
  maxParallel: 2
  edgeDerivation: declared
  strictEdges: true
  failurePolicy: drain
  publishMode: manual
  verificationProfiles:
    - name: fast
      steps:
        - name: replace-with-fast-project-checks
          command: true
          timeout: 300
          continueOnFailure: false
          requiredArtifacts: []
    - name: full
      steps:
        - name: replace-with-full-project-checks
          command: true
          timeout: 1200
          continueOnFailure: false
          requiredArtifacts: []
  stages:
    - id: plan-shards
      runtime: claude
      agent: architect
      planFile: .ralph-workspace/plans/GRAPH_PLAN_NAMESPACE_HERE-parallel/00-plan-shards.plan.md
      workspaceMode: snapshot
      agentGitAccess: off
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/parallel/shard-plan.md
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/parallel/ownership-map.json

    # Add two to four lanes. Every lane needs a unique planFile and a disjoint
    # project-relative writeScopes entry. Snapshot is the safe default.
    - id: lane-1
      runtime: cursor
      agent: implementation
      planFile: .ralph-workspace/plans/GRAPH_PLAN_NAMESPACE_HERE-parallel/01-lane-1.plan.md
      dependsOn: [plan-shards]
      workspaceMode: snapshot
      agentGitAccess: off
      writeScopes: [src/lane-1/**]

    - id: lane-2
      runtime: codex
      agent: implementation
      planFile: .ralph-workspace/plans/GRAPH_PLAN_NAMESPACE_HERE-parallel/02-lane-2.plan.md
      dependsOn: [plan-shards]
      workspaceMode: snapshot
      agentGitAccess: off
      writeScopes: [src/lane-2/**]

    - id: full-gate
      type: gate
      profile: full
      dependsOn: [implementation-passed]

    - id: review
      type: consensus
      policy: veto
      dependsOn: [full-gate]
      subagents: off
      voters:
        - id: cursor-review
          runtime: cursor
          agent: code-review
          sessionStrategy: fresh
          subagents: off
        - id: codex-review
          runtime: codex
          agent: code-review
          sessionStrategy: fresh
          subagents: off
        - id: claude-review
          runtime: claude
          agent: code-review
          sessionStrategy: fresh
          subagents: off

    - id: review-decision
      type: join
      policy: veto
      dependsOn: [review]

    # Optional publish checkpoint:
    # - id: publish-checkpoint
    #   type: checkpoint
    #   dependsOn: [review-decision]

  repairRounds:
    id: implementation
    rounds: 2
    dependsOn: [lane-1, lane-2]
    integrate:
      workspaceMode: snapshot
    gate:
      profile: fast
    diagnose:
      runtime: claude
      agent: architect
      content: Route each fast-gate finding through the frozen ownership map to exactly one repair lane.
    lanes:
      - id: lane-1
        runtime: cursor
        agent: implementation
        planFile: .ralph-workspace/plans/GRAPH_PLAN_NAMESPACE_HERE-parallel/01-lane-1.plan.md
        workspaceMode: snapshot
        agentGitAccess: off
        writeScopes: [src/lane-1/**]
        content: Repair only lane-1 findings; do not widen its scope or mutate the graph.
      - id: lane-2
        runtime: codex
        agent: implementation
        planFile: .ralph-workspace/plans/GRAPH_PLAN_NAMESPACE_HERE-parallel/02-lane-2.plan.md
        workspaceMode: snapshot
        agentGitAccess: off
        writeScopes: [src/lane-2/**]
        content: Repair only lane-2 findings; do not widen its scope or mutate the graph.
    reintegrate:
      workspaceMode: snapshot

todos: []
isProject: false
---

For `workspaceMode: worktree`, keep `agentGitAccess: off` and compile/run only
with a proved runtime sandbox boundary. For shared lanes, set both
`parallelMutation: allow` and `acknowledgeSharedMutationRisk: true` on every
mutating lane. Shared mutation is not isolated and can race or corrupt the
caller workspace.

If scopes intentionally overlap, set the same `overlapOwner` on both lanes and
declare that downstream owner with `ownershipRole: integration` on an
`integrate` node or `ownershipRole: repair` on an agent node. All other
unordered overlaps are compile errors.
