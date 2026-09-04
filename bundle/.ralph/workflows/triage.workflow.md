---
name: triage
overview: Classify an unshaped request read-only, route it to the depth of study it actually needs, and emit a runnable next-step Ralph plan plus a recommendation for which workflow should execute it. Never implements anything.
kind: workflow
mode: dependency
pipeline:
  maxParallel: 2
  publishMode: manual
  stages:
    - id: classify
      instructions: |
        Classify {{TASK}} read-only so the run can route to the right depth of
        study. Establish what is actually being asked, what kind of change it
        implies, which parts of the repository it touches, and how well understood
        it already is. Then choose a route and write it to
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/triage-decision.json matching
        bundle/.ralph/schemas/router-decision.schema.json, with target, reason, and
        a calibrated confidence.

        Choose scope-request when the request is well understood and clearly
        bounded: the intent is unambiguous, the affected surface is small and
        identifiable, and no material question needs answering before someone could
        plan the work. Choose deep-investigation when any of that is untrue: the
        request is vague or self-contradictory, the affected surface is unknown or
        large, the root cause is not established, or the request depends on a
        product or architecture decision nobody has made.

        Route on evidence, not on the request's tone or apparent size. A one-line
        request can be deeply ambiguous and a long one can be trivial. When you are
        genuinely torn, choose deep-investigation: the cost of over-studying a
        simple request is one extra read-only stage, while the cost of
        under-studying a hard one is a confidently wrong plan.

        Also write your classification reasoning to
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/triage-classification.md.
        Do not modify any file outside these artifacts and do not implement
        anything.
        {{INCLUDE:investigation-rigor}}
        {{INCLUDE:evidence-citation}}
      router:
        allowedTargets:
          - scope-request
          - deep-investigation
        defaultTarget: deep-investigation
        onInvalid: default
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/triage-classification.md
          required: true
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/triage-decision.json
          required: true
          schema: bundle/.ralph/schemas/router-decision.schema.json
    - id: scope-request
      instructions: |
        Scope {{TASK}} read-only for the shallow route: triage judged this request
        well understood and bounded. Confirm that judgement before relying on it.
        Establish the precise change surface, the acceptance criteria, the existing
        tests and repository rules that apply, and the verification commands the
        work will need. Keep this bounded; you are not doing a full investigation.
        If confirming the scope reveals the request is not in fact well understood,
        say so explicitly at the top of your findings and record what makes it
        ambiguous. That reversal is a valid and useful outcome, not a failure, and
        the recommendation stage depends on hearing it. Write the required findings
        to .ralph-workspace/artifacts/{{ARTIFACT_NS}}/triage-scope-findings.md.
        Do not modify any file outside that artifact and do not implement anything.
        {{INCLUDE:investigation-rigor}}
        {{INCLUDE:evidence-citation}}
      dependsOn:
        - classify
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/triage-classification.md
          required: true
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/triage-scope-findings.md
          required: true
    - id: deep-investigation
      instructions: |
        Investigate {{TASK}} read-only for the deep route: triage judged this
        request ambiguous, unbounded, or not yet root-caused. Resolve what can be
        resolved from the repository. Reproduce the behavior where one is claimed,
        establish the root cause or the true affected surface, and separate fact
        from inference. Identify the viable options with their tradeoffs, and state
        plainly which questions remain open and which of those genuinely require an
        operator decision rather than more reading. Do not invent an answer to a
        product or architecture question nobody has settled; recording it as an
        open decision is the correct outcome. Write the required findings to
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/triage-investigation-findings.md with concrete
        repository citations. Do not modify any file outside that artifact and do
        not implement anything.
        {{INCLUDE:investigation-rigor}}
        {{INCLUDE:evidence-citation}}
      dependsOn:
        - classify
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/triage-classification.md
          required: true
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/triage-investigation-findings.md
          required: true
    - id: recommend
      instructions: |
        Turn the triage findings for {{TASK}} into an executable recommendation.
        Read .ralph-workspace/artifacts/{{ARTIFACT_NS}}/triage-classification.md, then
        whichever findings file exists: the shallow route writes
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/triage-scope-findings.md and the deep route
        writes .ralph-workspace/artifacts/{{ARTIFACT_NS}}/triage-investigation-findings.md.
        Exactly one of the two routes ran, so exactly one of these exists.

        Write .ralph-workspace/artifacts/{{ARTIFACT_NS}}/triage-recommendation.md
        naming the single Ralph workflow that should execute this work and why the
        alternatives lose. Choose from the workflows actually installed here; list
        them with `ralph workflow list` rather than assuming a catalog. Match the
        shape of the work to the shape of the workflow: a defect with an
        established root cause, a feature needing requirements work, a
        behavior-preserving restructure, a read-only assessment or review of
        existing work, and a change whose blast radius warrants an operator
        approving the plan before any code moves are all different answers. If the
        findings show an open decision only the operator can make, recommend that
        the operator settle it first and say exactly what you need from them.

        Then write the sole required planner JSON to
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/triage-plan.json as the runnable
        next-step Ralph plan for the recommended workflow. Every TODO needs
        executable verification. When the work is blocked on an operator decision,
        emit the smallest plan that is still valid without that decision rather
        than guessing it. Do not implement anything and do not execute the plan.
        {{INCLUDE:plan-budget}}
      dependsOn:
        - scope-request
        - deep-investigation
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/triage-classification.md
          required: true
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/triage-scope-findings.md
          required: false
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/triage-investigation-findings.md
          required: false
      planner:
        outputMode: plan-file
        maxTodos: 100
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/triage-recommendation.md
          required: true
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/triage-plan.json
          required: true
          schema: bundle/.ralph/schemas/planner-output.schema.json
todos:
  - id: classify-request
    stage: classify
    content: |
      Classify {{TASK}} read-only, record the reasoning in
      .ralph-workspace/artifacts/{{ARTIFACT_NS}}/triage-classification.md, and
      write the route to
      .ralph-workspace/artifacts/{{ARTIFACT_NS}}/triage-decision.json.
    verification: Confirm .ralph-workspace/artifacts/{{ARTIFACT_NS}}/triage-decision.json matches bundle/.ralph/schemas/router-decision.schema.json.
    status: pending
  - id: scope-bounded-request
    stage: scope-request
    content: |
      Confirm the bounded scope of {{TASK}} and record the change surface,
      acceptance criteria, applicable rules, and verification commands to
      .ralph-workspace/artifacts/{{ARTIFACT_NS}}/triage-scope-findings.md.
    verification: Confirm .ralph-workspace/artifacts/{{ARTIFACT_NS}}/triage-scope-findings.md exists and is non-empty.
    status: pending
  - id: investigate-unbounded-request
    stage: deep-investigation
    content: |
      Investigate {{TASK}} read-only and record reproduction, root cause or true
      affected surface, fact versus inference, options and tradeoffs, and open
      operator decisions to
      .ralph-workspace/artifacts/{{ARTIFACT_NS}}/triage-investigation-findings.md.
    verification: Confirm .ralph-workspace/artifacts/{{ARTIFACT_NS}}/triage-investigation-findings.md exists and is non-empty.
    status: pending
  - id: recommend-workflow-and-plan
    stage: recommend
    content: |
      Recommend the workflow that should execute {{TASK}} in
      .ralph-workspace/artifacts/{{ARTIFACT_NS}}/triage-recommendation.md and write
      the runnable next-step plan to
      .ralph-workspace/artifacts/{{ARTIFACT_NS}}/triage-plan.json.
    verification: Confirm .ralph-workspace/artifacts/{{ARTIFACT_NS}}/triage-plan.json matches bundle/.ralph/schemas/planner-output.schema.json.
    status: pending
---
