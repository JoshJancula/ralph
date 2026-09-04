---
name: human-verified-delivery
overview: Investigate, plan, and deliver a feature with two durable human gates - the operator approves the concrete plan before implementation and accepts the verified result before terminal success.
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
        Investigate {{TASK}} as a bounded requirements and repository study.
        Clarify acceptance criteria and non-goals without inventing unanswered
        product choices. Map the current architecture, data, API, UI, and
        compatibility surfaces, and identify repository rules and the test
        baseline. Write the required findings to
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/human-verified-investigation.md
        with concrete repository citations. Do not implement the feature.
        If a missing product decision, unavailable credential configuration,
        external fact, or mutually exclusive requirement genuinely blocks you,
        follow the operator input protocol:
        run `ralph workflow actions request --question <text> [--details <text>]`
        and stop without completing the TODO rather than guessing.
        {{INCLUDE:investigation-rigor}}
        {{INCLUDE:evidence-citation}}
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/human-verified-investigation.md
          required: true
    - id: plan-implementation
      instructions: |
        Using {{TASK}} and
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/human-verified-investigation.md,
        design the feature without inventing unanswered product choices. Cover
        design decisions, independently verifiable implementation slices,
        migrations and compatibility, failure and rollback paths, cheapest
        appropriate tests, docs, and final acceptance. Write the sole required
        planner JSON to
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/human-verified-plan.json. Make
        the fewest TODOs that fully cover the request; do not pad, arbitrarily
        split, or collapse unrelated work. Every TODO needs executable
        verification. The operator reviews this plan at the next gate, so state
        the acceptance scope explicitly.
        If a missing product decision, unavailable credential configuration,
        external fact, or mutually exclusive requirement genuinely blocks you,
        follow the operator input protocol:
        run `ralph workflow actions request --question <text> [--details <text>]`
        and stop without completing the TODO rather than guessing.
        {{INCLUDE:plan-budget}}
      dependsOn:
        - investigate
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/human-verified-investigation.md
          required: true
      planner:
        outputMode: plan-file
        maxTodos: 200
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/human-verified-plan.json
          required: true
          schema: bundle/.ralph/schemas/planner-output.schema.json
    - id: approve-plan
      type: approval
      question: Approve the generated implementation plan and its acceptance scope before any code changes?
      changesTarget: plan-implementation
      dependsOn:
        - plan-implementation
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/human-verified-investigation.md
          required: true
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/human-verified-plan.json
          required: true
          schema: bundle/.ralph/schemas/planner-output.schema.json
    - id: implement
      instructions: |
        Execute the entire generated implementation plan for {{TASK}} TODO by TODO
        in a fresh session on the candidate snapshot. The operator has already
        approved this plan; do not renegotiate its scope. Read
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/human-verified-investigation.md
        and .ralph-workspace/artifacts/{{ARTIFACT_NS}}/human-verified-plan.json.
        Do not skip or replace plan TODOs with a summary. After every plan TODO
        and its verification pass, write the required
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/human-verified-implementation-handoff.md
        with plan completion, TODO evidence, changed files and behavior, commands
        run, and residual risks.
        If a missing product decision, unavailable credential configuration,
        external fact, or mutually exclusive requirement genuinely blocks you,
        follow the operator input protocol:
        run `ralph workflow actions request --question <text> [--details <text>]`
        and stop without completing the TODO rather than guessing.
        {{INCLUDE:scope-discipline}}
      dependsOn:
        - approve-plan
        - plan-implementation
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/human-verified-investigation.md
          required: true
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/human-verified-plan.json
          required: true
      planFrom: plan-implementation
      workspaceMode: snapshot
      writeScopes: ["**"]
      agentGitAccess: off
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/human-verified-implementation-handoff.md
          required: true
    - id: review
      instructions: |
        Review the candidate snapshot for {{TASK}} without mutation. Inspect the
        supervisor changeset evidence, the investigation, the latest
        implementation handoff, and generated plan completion. Check correctness,
        scope, regression risk, compatibility, tests, and the acceptance criteria
        the operator approved. Write a schema-valid verdict only to
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/review-verdict.json. Approve
        only when the candidate is ready for the approved scoped changeset;
        otherwise provide concrete actionable feedback for the next fresh
        control-copy implementation round.
        If a missing product decision, unavailable credential configuration,
        external fact, or mutually exclusive requirement genuinely blocks you,
        follow the operator input protocol:
        run `ralph workflow actions request --question <text> [--details <text>]`
        and stop without completing the TODO rather than guessing.
        {{INCLUDE:evaluator-contract}}
        {{INCLUDE:evidence-citation}}
      dependsOn:
        - implement
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/human-verified-investigation.md
          required: true
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/human-verified-plan.json
          required: true
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/human-verified-implementation-handoff.md
          required: true
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/review-verdict.json
          required: true
          schema: bundle/.ralph/schemas/evaluator-verdict.schema.json
      loopBackTo: implement
      loopCheck:
        path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/review-verdict.json
        schema: bundle/.ralph/schemas/evaluator-verdict.schema.json
      onExhausted: fail
    - id: integrate
      type: integrate
      workspaceMode: snapshot
      dependsOn:
        - review-approved
        - review
    - id: plan-qa
      instructions: |
        Using {{TASK}},
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/human-verified-investigation.md,
        and the latest
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/human-verified-implementation-handoff.md,
        create the smallest independent QA plan justified by the task and
        evidence. Cover acceptance, regression, migration and rollback, platform,
        and documentation checks where applicable. Do not invent unanswered
        product choices. Write the sole required planner JSON to
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/human-verified-qa-plan.json.
        Successful integration is the approval boundary, so make checks read-only
        against the integrated tree and give every TODO executable verification.
        The operator accepts these results at the final gate, so make each check
        legible on its own.
        If a missing product decision, unavailable credential configuration,
        external fact, or mutually exclusive requirement genuinely blocks you,
        follow the operator input protocol:
        run `ralph workflow actions request --question <text> [--details <text>]`
        and stop without completing the TODO rather than guessing.
        {{INCLUDE:plan-budget}}
      dependsOn:
        - integrate
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/human-verified-investigation.md
          required: true
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/human-verified-implementation-handoff.md
          required: true
      planner:
        outputMode: plan-file
        maxTodos: 200
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/human-verified-qa-plan.json
          required: true
          schema: bundle/.ralph/schemas/planner-output.schema.json
    - id: qa
      instructions: |
        Execute the entire generated QA plan for {{TASK}} TODO by TODO on the
        integrated tree. Read
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/human-verified-investigation.md,
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/human-verified-implementation-handoff.md,
        and .ralph-workspace/artifacts/{{ARTIFACT_NS}}/human-verified-qa-plan.json.
        Do not mutate the tree. Produce
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/human-verified-qa-handoff.md
        with PASS or FAIL per check, exact commands, evidence, and blockers.
        If a missing product decision, unavailable credential configuration,
        external fact, or mutually exclusive requirement genuinely blocks you,
        follow the operator input protocol:
        run `ralph workflow actions request --question <text> [--details <text>]`
        and stop without completing the TODO rather than guessing.
        Also write a machine-readable verdict to
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/qa-verdict.json matching
        bundle/.ralph/schemas/evaluator-verdict.schema.json: approve only when
        every check passed, otherwise record each failure as a blocking finding.
        The verdict decides the run outcome, so it must agree with the handoff.
        {{INCLUDE:evaluator-contract}}
        {{INCLUDE:qa-independence}}
      dependsOn:
        - plan-qa
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/human-verified-investigation.md
          required: true
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/human-verified-implementation-handoff.md
          required: true
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/human-verified-qa-plan.json
          required: true
      planFrom: plan-qa
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/human-verified-qa-handoff.md
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
    - id: approve-result
      type: approval
      question: Accept the integrated and independently verified result as final?
      changesTarget: plan-implementation
      dependsOn:
        - qa-gate
        - integrate
        - review-approved
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/human-verified-investigation.md
          required: true
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/human-verified-implementation-handoff.md
          required: true
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/human-verified-qa-handoff.md
          required: true
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/review-verdict.json
          required: true
          schema: bundle/.ralph/schemas/evaluator-verdict.schema.json
todos:
  - id: qa-gate
    stage: qa-gate
    content: |
      Run the qa-verdict profile so an independent QA failure fails the run.
    verification: Confirm the gate outcome records passed or changes-required.
    status: pending
  - id: investigate-feature
    stage: investigate
    content: |
      Investigate {{TASK}} and write acceptance criteria, non-goals, architecture,
      data, API, UI, compatibility, repository rules, and test baseline findings to
      .ralph-workspace/artifacts/{{ARTIFACT_NS}}/human-verified-investigation.md.
    verification: Confirm .ralph-workspace/artifacts/{{ARTIFACT_NS}}/human-verified-investigation.md exists and is non-empty.
    status: pending
  - id: plan-human-verified-implementation
    stage: plan-implementation
    content: |
      Plan {{TASK}} from
      .ralph-workspace/artifacts/{{ARTIFACT_NS}}/human-verified-investigation.md
      and write the sole planner JSON to
      .ralph-workspace/artifacts/{{ARTIFACT_NS}}/human-verified-plan.json.
    verification: Confirm .ralph-workspace/artifacts/{{ARTIFACT_NS}}/human-verified-plan.json matches bundle/.ralph/schemas/planner-output.schema.json.
    status: pending
  - id: review-human-verified-candidate
    stage: review
    content: |
      Review {{TASK}} and generated plan completion against
      .ralph-workspace/artifacts/{{ARTIFACT_NS}}/human-verified-investigation.md,
      .ralph-workspace/artifacts/{{ARTIFACT_NS}}/human-verified-implementation-handoff.md,
      and supervisor changeset evidence; write
      .ralph-workspace/artifacts/{{ARTIFACT_NS}}/review-verdict.json.
    verification: Confirm .ralph-workspace/artifacts/{{ARTIFACT_NS}}/review-verdict.json matches bundle/.ralph/schemas/evaluator-verdict.schema.json.
    status: pending
  - id: plan-human-verified-qa
    stage: plan-qa
    content: |
      Create the smallest independent QA plan for {{TASK}} from
      .ralph-workspace/artifacts/{{ARTIFACT_NS}}/human-verified-investigation.md
      and the latest
      .ralph-workspace/artifacts/{{ARTIFACT_NS}}/human-verified-implementation-handoff.md;
      write the sole planner JSON to
      .ralph-workspace/artifacts/{{ARTIFACT_NS}}/human-verified-qa-plan.json.
    verification: Confirm .ralph-workspace/artifacts/{{ARTIFACT_NS}}/human-verified-qa-plan.json matches bundle/.ralph/schemas/planner-output.schema.json.
    status: pending
---
