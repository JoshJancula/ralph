---
name: adaptive-delivery
overview: Route a delivery request at an entry router to either a small localized path (scope and plan, implement, evaluate, integrate, gate) or a full delivery path (investigate, plan, implement, review, integrate, qa, qa-gate). Passing --jev routing or --jev enables pre-agent Jev classification on the entry router; without it the entry agent always decides the route.
kind: workflow
mode: dependency
pipeline:
  maxParallel: 1
  maxReworkIterations: 2
  publishMode: on-verified
  verificationProfiles:
    - name: evaluate-verdict
      steps:
        - name: evaluate-approved
          command: python3 .ralph/python/evaluator_contract.py require-approved --artifact .ralph-workspace/artifacts/{{ARTIFACT_NS}}/evaluate-verdict.json --schema .ralph/schemas/evaluator-verdict.schema.json
          timeout: 120
    - name: qa-verdict
      steps:
        - name: qa-approved
          command: python3 .ralph/python/evaluator_contract.py require-approved --artifact .ralph-workspace/artifacts/{{ARTIFACT_NS}}/qa-verdict.json --schema .ralph/schemas/evaluator-verdict.schema.json
          timeout: 120
  stages:
    - id: route
      sessionStrategy: resume
      instructions: |
        Decide the delivery depth for {{TASK}} read-only and write the route to
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-route-decision.json
        matching bundle/.ralph/schemas/router-decision.schema.json, with target,
        reason, and a calibrated confidence.

        Choose scope-and-plan (the localized path) only when the intent is
        unambiguous, the change is localized, and executable acceptance checks can
        be stated up front. Choose investigate (the full delivery path) when the
        request needs investigation, the surface is broad or unknown, or a
        material design question is open. When genuinely torn, choose investigate.
        Do not modify any file outside the route artifacts and do not implement
        anything.
        {{INCLUDE:investigation-rigor}}
        {{INCLUDE:evidence-citation}}

        When RALPH_JEV_ROUTING=1 and Jev is available, the scheduler may ask the
        graph.router-confidence question set before this agent turn. A high-
        confidence Jev act writes the decision and skips the agent. Jev never
        bypasses router-decision.schema.json or allowedTargets validation.
      router:
        allowedTargets:
          - scope-and-plan
          - investigate
        defaultTarget: investigate
        onInvalid: default
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-route-decision.json
          required: true
          schema: bundle/.ralph/schemas/router-decision.schema.json
    - id: scope-and-plan
      dependsOn:
        - route
      sessionStrategy: resume
      instructions: |
        Scope and plan the small feature {{TASK}}. This is the localized route: the
        intent is unambiguous, the change is localized, and acceptance
        criteria can be stated as executable checks up front. Establish the
        precise change surface, acceptance checks, applicable repository rules,
        and targeted verification commands. Write the sole required planner JSON
        to .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-small-plan.json.
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
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-small-plan.json
          required: true
          schema: bundle/.ralph/schemas/planner-output.schema.json
    - id: implement-small
      sessionStrategy: compact
      instructions: |
        Execute the generated small-feature plan for {{TASK}} TODO by TODO on
        the candidate snapshot. Read
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-small-plan.json. Do
        not skip or replace plan TODOs with a summary. After every plan TODO and
        its verification pass, write
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-small-handoff.md
        with plan completion, TODO evidence, changed files and behavior,
        commands run, and residual risks.
        {{INCLUDE:scope-discipline}}
      dependsOn:
        - scope-and-plan
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-small-plan.json
          required: true
      planFrom: scope-and-plan
      workspaceMode: snapshot
      writeScopes: ["**"]
      overlapOwner: delivery-report
      agentGitAccess: off
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-small-handoff.md
          required: true
    - id: evaluate
      sessionStrategy: fresh
      workspaceMode: snapshot
      candidateFrom: implement-small
      instructions: |
        Evaluate the candidate for {{TASK}} without mutation. Run every
        executable check from
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-small-plan.json
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
        - implement-small
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-small-plan.json
          required: true
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-small-handoff.md
          required: true
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/evaluate-verdict.json
          required: true
          schema: bundle/.ralph/schemas/evaluator-verdict.schema.json
      loopBackTo: implement-small
      loopCheck:
        path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/evaluate-verdict.json
        schema: bundle/.ralph/schemas/evaluator-verdict.schema.json
      onExhausted: fail
    - id: integrate-small
      type: integrate
      workspaceMode: snapshot
      dependsOn:
        - evaluate-approved
    - id: verdict-gate
      type: gate
      profile: evaluate-verdict
      dependsOn:
        - integrate-small
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/evaluate-verdict.json
          required: true
    - id: investigate
      dependsOn:
        - route
      sessionStrategy: resume
      instructions: |
        Investigate {{TASK}} as a bounded requirements and repository study.
        Clarify acceptance criteria and non-goals without inventing unanswered
        product choices.
        Map the current architecture, data, API, UI, and compatibility surfaces, and
        identify repository rules and the test baseline. Write the required findings to
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-full-investigation.md. Include
        concrete repository citations and state unresolved decisions as blockers or
        assumptions. Do not implement the feature.
        {{INCLUDE:investigation-rigor}}
        {{INCLUDE:evidence-citation}}
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-full-investigation.md
          required: true
    - id: plan-implementation
      sessionStrategy: resume
      instructions: |
        Using {{TASK}} and
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-full-investigation.md,
        design the feature without inventing unanswered product choices. Cover design
        decisions, independently verifiable implementation slices, migrations and
        compatibility, failure and rollback paths, cheapest appropriate tests, docs,
        and final acceptance. Write the sole required planner JSON to
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-full-plan.json.
        Make the fewest TODOs that fully cover the request; do not pad, arbitrarily
        split, or collapse unrelated work. Every TODO needs executable verification.
        {{INCLUDE:plan-budget}}
      dependsOn:
        - investigate
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-full-investigation.md
          required: true
      planner:
        outputMode: plan-file
        maxTodos: 200
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-full-plan.json
          required: true
          schema: bundle/.ralph/schemas/planner-output.schema.json
    - id: implement-full
      sessionStrategy: compact
      instructions: |
        Execute the entire generated implementation plan for {{TASK}} TODO by TODO
        with compacted session continuity on the candidate snapshot. Read
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-full-investigation.md and
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-full-plan.json. Do
        not skip or replace plan TODOs with a summary. After every plan TODO and its
        verification pass, write the required
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-full-handoff.md with
        plan completion, TODO evidence, changed files and behavior, commands run,
        and residual risks.
        {{INCLUDE:scope-discipline}}
      dependsOn:
        - plan-implementation
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-full-investigation.md
          required: true
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-full-plan.json
          required: true
      planFrom: plan-implementation
      workspaceMode: snapshot
      writeScopes: ["**"]
      overlapOwner: delivery-report
      agentGitAccess: off
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-full-handoff.md
          required: true
    - id: review
      workspaceMode: snapshot
      candidateFrom: implement-full
      sessionStrategy: fresh
      instructions: |
        Review the candidate snapshot for {{TASK}} without mutation. Inspect the
        supervisor changeset evidence, the feature investigation, the latest
        implementation handoff, and generated plan completion. Check correctness,
        scope, regression risk, compatibility, tests, and acceptance criteria.
        Write a schema-valid verdict only to
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/{{STAGE_ID}}-verdict.json.
        Approve only when the candidate is ready for the approved scoped changeset;
        otherwise provide concrete actionable feedback for the next fresh control-copy
        implementation round.
        {{INCLUDE:evaluator-contract}}
        {{INCLUDE:evidence-citation}}
      dependsOn:
        - implement-full
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-full-investigation.md
          required: true
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-full-plan.json
          required: true
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-full-handoff.md
          required: true
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/{{STAGE_ID}}-verdict.json
          required: true
          schema: bundle/.ralph/schemas/evaluator-verdict.schema.json
      loopBackTo: implement-full
      loopCheck:
        path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/{{STAGE_ID}}-verdict.json
        schema: bundle/.ralph/schemas/evaluator-verdict.schema.json
      onExhausted: fail
    - id: integrate-full
      type: integrate
      workspaceMode: snapshot
      dependsOn:
        - review-approved
    - id: plan-qa
      sessionStrategy: resume
      instructions: |
        Using {{TASK}}, .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-full-investigation.md,
        and the latest .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-full-handoff.md,
        create the smallest independent QA plan justified by the task and evidence.
        Cover acceptance, regression, migration and rollback, platform, and
        documentation checks where applicable. Do not invent unanswered product
        choices. Write the sole required planner JSON to
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-full-qa-plan.json. Successful
        integration is the approval boundary, so make checks read-only against the
        integrated candidate snapshot and give every TODO executable verification.
        {{INCLUDE:plan-budget}}
      dependsOn:
        - integrate-full
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-full-investigation.md
          required: true
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-full-handoff.md
          required: true
      planner:
        outputMode: plan-file
        maxTodos: 200
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-full-qa-plan.json
          required: true
          schema: bundle/.ralph/schemas/planner-output.schema.json
    - id: qa
      workspaceMode: snapshot
      candidateFrom: integrate-full
      loopBackTo: implement-full
      loopCheck:
        path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/qa-verdict.json
        schema: bundle/.ralph/schemas/evaluator-verdict.schema.json
      onExhausted: fail
      maxQaRepairRounds: 1
      sessionStrategy: fresh
      instructions: |
        Execute the entire generated QA plan for {{TASK}} TODO by TODO on the
        integrated candidate snapshot. Read
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-full-investigation.md,
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-full-handoff.md, and
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-full-qa-plan.json. Do not
        mutate the tree. Produce
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-full-qa-handoff.md with PASS or FAIL
        per check, exact commands, evidence, and blockers.
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
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-full-investigation.md
          required: true
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-full-handoff.md
          required: true
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-full-qa-plan.json
          required: true
      planFrom: plan-qa
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-full-qa-handoff.md
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
    - id: delivery-report
      sessionStrategy: fresh
      ownershipRole: repair
      instructions: |
        Write a short operator-facing delivery report for {{TASK}} read-only.
        Exactly one delivery path ran. Name which path ran (localized or full),
        read whichever verdict exists, .ralph-workspace/artifacts/{{ARTIFACT_NS}}/evaluate-verdict.json
        for the localized path or .ralph-workspace/artifacts/{{ARTIFACT_NS}}/qa-verdict.json for the full
        path, and summarize the outcome and residual risks with citations. Write
        the report to .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-delivery-report.md.
        Do not modify any other file. This stage also owns the shared write scope
        of the two mutually exclusive implement stages.
        {{INCLUDE:evidence-citation}}
      dependsOn:
        - verdict-gate
        - qa-gate
        - implement-small
        - implement-full
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/evaluate-verdict.json
          required: false
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/qa-verdict.json
          required: false
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-delivery-report.md
          required: true

todos:
  - id: route-delivery
    stage: route
    content: |
      Decide the delivery depth for {{TASK}} and write the route to
      .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-route-decision.json.
    verification: Confirm .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-route-decision.json matches bundle/.ralph/schemas/router-decision.schema.json.
    status: pending
  - id: scope-and-plan-small-feature
    stage: scope-and-plan
    content: |
      Scope {{TASK}}, record executable acceptance checks, and write the sole
      planner JSON to
      .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-small-plan.json.
    verification: Confirm .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-small-plan.json matches bundle/.ralph/schemas/planner-output.schema.json.
    status: pending
  - id: evaluate-small-feature
    stage: evaluate
    content: |
      Run every executable check in the small plan against {{TASK}}'s candidate
      without mutation and write
      .ralph-workspace/artifacts/{{ARTIFACT_NS}}/{{STAGE_ID}}-verdict.json.
    verification: Confirm .ralph-workspace/artifacts/{{ARTIFACT_NS}}/{{STAGE_ID}}-verdict.json matches bundle/.ralph/schemas/evaluator-verdict.schema.json.
    status: pending
  - id: gate-small-feature-verdict
    stage: verdict-gate
    content: |
      Run the evaluate-verdict profile so an evaluator failure fails the run.
    verification: Confirm the gate outcome records passed or changes-required.
    status: pending
  - id: investigate-feature
    stage: investigate
    content: |
      Investigate {{TASK}} and write acceptance criteria, non-goals, architecture,
      data, API, UI, compatibility, repository rules, and test baseline findings to
      .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-full-investigation.md.
    verification: Confirm .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-full-investigation.md exists and is non-empty.
    status: pending
  - id: plan-feature-implementation
    stage: plan-implementation
    content: |
      Plan {{TASK}} from .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-full-investigation.md
      and write the sole planner JSON to
      .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-full-plan.json.
    verification: Confirm .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-full-plan.json matches bundle/.ralph/schemas/planner-output.schema.json.
    status: pending
  - id: review-feature
    stage: review
    content: |
      Review {{TASK}} and generated plan completion against
      .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-full-investigation.md,
      .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-full-handoff.md, and
      supervisor changeset evidence; write
      .ralph-workspace/artifacts/{{ARTIFACT_NS}}/{{STAGE_ID}}-verdict.json.
    verification: Confirm .ralph-workspace/artifacts/{{ARTIFACT_NS}}/{{STAGE_ID}}-verdict.json matches bundle/.ralph/schemas/evaluator-verdict.schema.json.
    status: pending
  - id: plan-feature-qa
    stage: plan-qa
    content: |
      Create the smallest independent QA plan for {{TASK}} and write the sole
      planner JSON to
      .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-full-qa-plan.json.
    verification: Confirm .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-full-qa-plan.json matches bundle/.ralph/schemas/planner-output.schema.json.
    status: pending
  - id: report-delivery
    stage: delivery-report
    content: |
      Write the delivery report for {{TASK}} to
      .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-delivery-report.md.
    verification: Confirm .ralph-workspace/artifacts/{{ARTIFACT_NS}}/adaptive-delivery-report.md exists and is non-empty.
    status: pending
  - id: qa-gate
    stage: qa-gate
    content: |
      Run the qa-verdict profile so an independent QA failure fails the run.
    verification: Confirm the gate outcome records passed or changes-required.
    status: pending
---
