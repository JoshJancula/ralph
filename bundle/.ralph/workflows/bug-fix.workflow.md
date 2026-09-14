---
name: bug-fix
overview: Reproduce, plan, implement, review, integrate, and independently verify a defect with bounded rework.
kind: workflow
mode: dependency
pipeline:
  maxParallel: 1
  maxReworkIterations: 2
  publishMode: on-verified
  verificationProfiles:
    - name: qa-verdict
      steps:
        - name: qa-approved
          command: python3 .ralph/python/evaluator_contract.py require-approved --artifact .ralph-workspace/artifacts/{{ARTIFACT_NS}}/qa-verdict.json --schema .ralph/schemas/evaluator-verdict.schema.json
          timeout: 120
  stages:
    - id: investigate
      instructions: |
        Investigate the defect described by {{TASK}}. Reproduce the symptom, identify
        the root cause and regression surface, and record observed versus expected
        behavior in .ralph-workspace/artifacts/{{ARTIFACT_NS}}/investigation.md.
        Keep this bounded and evidence-driven; do not implement the fix.
        {{INCLUDE:investigation-rigor}}
        {{INCLUDE:evidence-citation}}
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/investigation.md
          required: true
    - id: plan-implementation
      instructions: |
        Using the task {{TASK}} and
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/investigation.md, create the
        smallest independently verifiable implementation plan. Write the sole
        planner output to
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/bug-fix-plan.json and include
        verification for every plan TODO.
        {{INCLUDE:plan-budget}}
      dependsOn:
        - investigate
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/investigation.md
          required: true
      planner:
        outputMode: plan-file
        maxTodos: 40
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/bug-fix-plan.json
          required: true
          schema: bundle/.ralph/schemas/planner-output.schema.json
    - id: implement
      instructions: |
        Execute the generated implementation plan for {{TASK}} on the isolated
        candidate tree. Read
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/investigation.md and
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/bug-fix-plan.json. Complete the
        plan before writing
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md,
        which must summarize completed plan IDs, changed behavior and files,
        verification, and residual risk.
        {{INCLUDE:scope-discipline}}
      dependsOn:
        - plan-implementation
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/investigation.md
          required: true
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/bug-fix-plan.json
          required: true
      planFrom: plan-implementation
      workspaceMode: snapshot
      writeScopes: ["**"]
      agentGitAccess: off
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md
          required: true
    - id: review
      instructions: |
        Review the candidate for {{TASK}} without mutation. Inspect the supervisor
        changeset evidence and the implementation handoff together with
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/investigation.md. Write only
        concrete correctness, regression, or scope fixes to
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/{{STAGE_ID}}-verdict.json,
        matching bundle/.ralph/schemas/evaluator-verdict.schema.json. Approve only
        when no such fixes remain.
        {{INCLUDE:evaluator-contract}}
        {{INCLUDE:evidence-citation}}
      dependsOn:
        - implement
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/investigation.md
          required: true
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md
          required: true
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/{{STAGE_ID}}-verdict.json
          required: true
          schema: bundle/.ralph/schemas/evaluator-verdict.schema.json
      loopBackTo: implement
      loopCheck:
        path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/{{STAGE_ID}}-verdict.json
        schema: bundle/.ralph/schemas/evaluator-verdict.schema.json
      onExhausted: fail
    - id: integrate
      type: integrate
      workspaceMode: snapshot
      dependsOn:
        - review-approved
    - id: plan-qa
      instructions: |
        Using {{TASK}}, the investigation, and the latest implementation handoff,
        create the smallest independent QA plan after successful integration.
        The plan must use read-only independent reproduction and targeted
        regressions. Write the sole planner output to
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/bug-fix-qa-plan.json.
        {{INCLUDE:plan-budget}}
      dependsOn:
        - integrate
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/investigation.md
          required: true
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md
          required: true
      planner:
        outputMode: plan-file
        maxTodos: 40
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/bug-fix-qa-plan.json
          required: true
          schema: bundle/.ralph/schemas/planner-output.schema.json
    - id: qa
      instructions: |
        Execute the generated QA plan for {{TASK}} on the integrated tree. Read
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/investigation.md,
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md, and
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/bug-fix-qa-plan.json. Do not
        mutate the tree. Produce
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/qa-handoff.md with PASS or FAIL
        per check, commands, evidence, and blockers. Also write a machine-readable
        verdict to .ralph-workspace/artifacts/{{ARTIFACT_NS}}/qa-verdict.json
        matching bundle/.ralph/schemas/evaluator-verdict.schema.json: approve only
        when every check passed, otherwise record each failure as a blocking
        finding. The verdict decides the run outcome, so it must agree with the
        handoff.
        {{INCLUDE:qa-independence}}
        {{INCLUDE:evaluator-contract}}
      dependsOn:
        - plan-qa
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/investigation.md
          required: true
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md
          required: true
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/bug-fix-qa-plan.json
          required: true
      planFrom: plan-qa
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/qa-handoff.md
          required: true
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/qa-verdict.json
          required: true
          schema: bundle/.ralph/schemas/evaluator-verdict.schema.json
    - id: qa-gate
      type: gate
      profile: qa-verdict
      dependsOn:
        - qa
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/qa-verdict.json
          required: true
todos:
  - id: investigate-defect
    stage: investigate
    content: |
      Reproduce and investigate {{TASK}}. Record the symptom, root cause,
      regression surface, observed behavior, and expected behavior in
      .ralph-workspace/artifacts/{{ARTIFACT_NS}}/investigation.md.
    verification: Confirm .ralph-workspace/artifacts/{{ARTIFACT_NS}}/investigation.md exists and is non-empty.
    status: pending
  - id: plan-implementation
    stage: plan-implementation
    content: |
      Create the smallest implementation plan for {{TASK}} from
      .ralph-workspace/artifacts/{{ARTIFACT_NS}}/investigation.md and write the
      sole planner JSON to
      .ralph-workspace/artifacts/{{ARTIFACT_NS}}/bug-fix-plan.json.
    verification: Confirm .ralph-workspace/artifacts/{{ARTIFACT_NS}}/bug-fix-plan.json matches bundle/.ralph/schemas/planner-output.schema.json.
    status: pending
  - id: review-candidate
    stage: review
    content: |
      Review the candidate for {{TASK}} against the investigation and handoff,
      inspect supervisor changeset evidence, and write only concrete
      correctness, regression, or scope fixes to
      .ralph-workspace/artifacts/{{ARTIFACT_NS}}/{{STAGE_ID}}-verdict.json using
      bundle/.ralph/schemas/evaluator-verdict.schema.json.
    verification: Confirm .ralph-workspace/artifacts/{{ARTIFACT_NS}}/{{STAGE_ID}}-verdict.json matches bundle/.ralph/schemas/evaluator-verdict.schema.json.
    status: pending
  - id: qa-gate
    stage: qa-gate
    content: |
      Run the qa-verdict profile so an independent QA failure fails the run.
    verification: Confirm the gate outcome records passed or changes-required.
    status: pending
  - id: plan-qa
    stage: plan-qa
    content: |
      Create the smallest independent read-only reproduction and targeted
      regression plan for {{TASK}} and write the sole planner JSON to
      .ralph-workspace/artifacts/{{ARTIFACT_NS}}/bug-fix-qa-plan.json.
    verification: Confirm .ralph-workspace/artifacts/{{ARTIFACT_NS}}/bug-fix-qa-plan.json matches bundle/.ralph/schemas/planner-output.schema.json.
    status: pending
---
