---
name: small-feature-delivery
overview: Deliver an unambiguous, localized feature with executable acceptance checks, bounded evaluation repair, and verified publication.
kind: workflow
mode: dependency
pipeline:
  maxReworkIterations: 2
  publishMode: on-verified
  verificationProfiles:
    - name: evaluate-verdict
      steps:
        - name: evaluate-approved
          command: python3 .ralph/python/evaluator_contract.py require-approved --artifact .ralph-workspace/artifacts/{{ARTIFACT_NS}}/evaluate-verdict.json --schema .ralph/schemas/evaluator-verdict.schema.json
          timeout: 120
  stages:
    - id: scope-and-plan
      sessionStrategy: resume
      instructions: |
        Scope and plan the small feature {{TASK}}. Use this workflow only when
        the intent is unambiguous, the change is localized, and acceptance
        criteria can be stated as executable checks up front. Establish the
        precise change surface, acceptance checks, applicable repository rules,
        and targeted verification commands. Write the sole required planner JSON
        to .ralph-workspace/artifacts/{{ARTIFACT_NS}}/small-feature-plan.json.
        Every TODO needs executable verification, and the plan must include an
        acceptance TODO listing the acceptance checks. If a product decision is
        unresolved, raise a workflow input action with
        `ralph workflow actions request --question <text> [--details <text>]`
        and stop without completing the TODO rather than inventing the choice.
        {{INCLUDE:plan-budget}}
        {{INCLUDE:evidence-citation}}
      planner:
        outputMode: plan-file
        maxTodos: 30
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/small-feature-plan.json
          required: true
          schema: bundle/.ralph/schemas/planner-output.schema.json
    - id: implement
      sessionStrategy: compact
      instructions: |
        Execute the generated small-feature plan for {{TASK}} TODO by TODO on
        the candidate snapshot. Read
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/small-feature-plan.json. Do
        not skip or replace plan TODOs with a summary. After every plan TODO and
        its verification pass, write
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md
        with plan completion, TODO evidence, changed files and behavior,
        commands run, and residual risks.
        {{INCLUDE:scope-discipline}}
      dependsOn:
        - scope-and-plan
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/small-feature-plan.json
          required: true
      planFrom: scope-and-plan
      workspaceMode: snapshot
      writeScopes: ["**"]
      agentGitAccess: off
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md
          required: true
    - id: evaluate
      sessionStrategy: fresh
      workspaceMode: snapshot
      candidateFrom: implement
      instructions: |
        Evaluate the candidate for {{TASK}} without mutation. Run every
        executable check from
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/small-feature-plan.json
        against the candidate. Inspect the implementation handoff and supervisor
        changeset evidence. Write only the schema-valid verdict to
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/{{STAGE_ID}}-verdict.json.
        Approve only when every acceptance check passes; otherwise provide
        concrete actionable feedback for the next fresh control-copy
        implementation round.
        {{INCLUDE:evaluator-contract}}
        {{INCLUDE:evidence-citation}}
        {{INCLUDE:qa-independence}}
      dependsOn:
        - implement
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/small-feature-plan.json
          required: true
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md
          required: true
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/evaluate-verdict.json
          required: true
          schema: bundle/.ralph/schemas/evaluator-verdict.schema.json
      loopBackTo: implement
      loopCheck:
        path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/evaluate-verdict.json
        schema: bundle/.ralph/schemas/evaluator-verdict.schema.json
      onExhausted: fail
    - id: integrate
      type: integrate
      workspaceMode: snapshot
      dependsOn:
        - evaluate-approved
    - id: verdict-gate
      type: gate
      profile: evaluate-verdict
      dependsOn:
        - integrate
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/evaluate-verdict.json
          required: true
todos:
  - id: scope-and-plan-small-feature
    stage: scope-and-plan
    content: |
      Scope {{TASK}}, record executable acceptance checks, and write the sole
      planner JSON to
      .ralph-workspace/artifacts/{{ARTIFACT_NS}}/small-feature-plan.json.
    verification: Confirm .ralph-workspace/artifacts/{{ARTIFACT_NS}}/small-feature-plan.json matches bundle/.ralph/schemas/planner-output.schema.json.
    status: pending
  - id: evaluate-small-feature
    stage: evaluate
    content: |
      Run every executable check in the small-feature plan against {{TASK}}'s
      candidate without mutation and write
      .ralph-workspace/artifacts/{{ARTIFACT_NS}}/{{STAGE_ID}}-verdict.json.
    verification: Confirm .ralph-workspace/artifacts/{{ARTIFACT_NS}}/{{STAGE_ID}}-verdict.json matches bundle/.ralph/schemas/evaluator-verdict.schema.json.
    status: pending
  - id: gate-small-feature-verdict
    stage: verdict-gate
    content: |
      Run the evaluate-verdict profile so an evaluator failure fails the run.
    verification: Confirm the gate outcome records passed or changes-required.
    status: pending
---
