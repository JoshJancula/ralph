---
name: release-gate
overview: Inspect a release candidate, plan and execute read-only verification, assess security independently, and issue a release verdict without mutating or publishing anything.
kind: workflow
mode: dependency
pipeline:
  verificationProfiles:
    - name: release-verdict
      steps:
        - name: release-approved
          command: python3 .ralph/python/evaluator_contract.py require-approved --artifact .ralph-workspace/artifacts/{{ARTIFACT_NS}}/release-verdict.json --schema .ralph/schemas/evaluator-verdict.schema.json
          timeout: 120
  stages:
    - id: inspect-candidate
      instructions: |
        Inspect the release candidate for {{TASK}} read-only. Identify the release
        scope and acceptance criteria, the changed surfaces, versioning and
        migrations, the verification evidence that already exists in the
        repository, and the risk that remains unresolved. Write the required
        summary to .ralph-workspace/artifacts/{{ARTIFACT_NS}}/candidate.md with
        concrete repository citations. Do not modify the project and do not draw
        the release conclusion here.
        {{INCLUDE:investigation-rigor}}
        {{INCLUDE:evidence-citation}}
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/candidate.md
          required: true
    - id: plan-verification
      instructions: |
        Using {{TASK}} and
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/candidate.md, plan the release
        verification. Select targeted, acceptance, regression, migration,
        rollback, and packaging checks from the repository evidence rather than
        from a fixed checklist, and justify each one by the candidate. Every TODO
        must be read-only against the project and must carry executable
        verification. Write the sole required planner JSON to
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/release-verification-plan.json.
        Make the fewest TODOs that cover the release; do not pad or arbitrarily
        split.
        {{INCLUDE:plan-budget}}
      dependsOn:
        - inspect-candidate
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/candidate.md
          required: true
      planner:
        outputMode: plan-file
        maxTodos: 100
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/release-verification-plan.json
          required: true
          schema: bundle/.ralph/schemas/planner-output.schema.json
    - id: verify
      instructions: |
        Execute the entire generated verification plan for {{TASK}} TODO by TODO
        in a fresh session. Read
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/candidate.md and
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/release-verification-plan.json.
        Do not mutate the project; run checks only. Do not skip or replace plan
        TODOs with a summary. Write the required
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/verification-handoff.md with
        PASS or FAIL per check, the exact commands run, and the evidence for each
        result.
        {{INCLUDE:qa-independence}}
      dependsOn:
        - plan-verification
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/candidate.md
          required: true
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/release-verification-plan.json
          required: true
      planFrom: plan-verification
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/verification-handoff.md
          required: true
    - id: security
      instructions: |
        Assess the security of the release candidate for {{TASK}} read-only and
        independently of any verification conclusion. Read
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/candidate.md and examine the
        changed surfaces, dependencies, and configuration directly. Write the
        required assessment to
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/security.md, giving each
        finding a severity, an exploitability judgement, the affected surface, and
        an explicit blocking or nonblocking disposition. Do not modify the
        project.
        {{INCLUDE:evaluator-contract}}
        {{INCLUDE:evidence-citation}}
      dependsOn:
        - inspect-candidate
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/candidate.md
          required: true
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/security.md
          required: true
    - id: release-decision
      instructions: |
        Decide the release for {{TASK}} from
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/candidate.md,
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/verification-handoff.md, and
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/security.md. Write a
        schema-valid verdict only to
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/release-verdict.json. Use
        approved only when every required check passes and no blocking security
        finding remains. Otherwise use changes-required and give one concrete,
        self-contained feedback item per unresolved blocker. Do not modify the
        project.
        {{INCLUDE:evaluator-contract}}
      dependsOn:
        - verify
        - security
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/candidate.md
          required: true
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/verification-handoff.md
          required: true
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/security.md
          required: true
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/release-verdict.json
          required: true
          schema: bundle/.ralph/schemas/evaluator-verdict.schema.json
    - id: release-gate-decision
      type: gate
      profile: release-verdict
      dependsOn:
        - release-decision
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/release-verdict.json
          required: true
todos:
  - id: release-gate-decision
    stage: release-gate-decision
    content: |
      Run the release-verdict profile so a non-approving release decision fails
      the run instead of exiting zero.
    verification: Confirm the gate outcome records passed or changes-required.
    status: pending
  - id: inspect-release-candidate
    stage: inspect-candidate
    content: |
      Inspect the release candidate for {{TASK}} read-only and write release
      scope, acceptance criteria, changed surfaces, versioning, migrations,
      existing evidence, and unresolved risk to
      .ralph-workspace/artifacts/{{ARTIFACT_NS}}/candidate.md.
    verification: Confirm .ralph-workspace/artifacts/{{ARTIFACT_NS}}/candidate.md exists and is non-empty.
    status: pending
  - id: plan-release-verification
    stage: plan-verification
    content: |
      Plan the read-only release verification for {{TASK}} from
      .ralph-workspace/artifacts/{{ARTIFACT_NS}}/candidate.md and write the sole
      planner JSON to
      .ralph-workspace/artifacts/{{ARTIFACT_NS}}/release-verification-plan.json.
    verification: Confirm .ralph-workspace/artifacts/{{ARTIFACT_NS}}/release-verification-plan.json matches bundle/.ralph/schemas/planner-output.schema.json.
    status: pending
  - id: assess-release-security
    stage: security
    content: |
      Assess the security of the release candidate for {{TASK}} independently from
      .ralph-workspace/artifacts/{{ARTIFACT_NS}}/candidate.md and write severity,
      exploitability, affected surface, and blocking disposition per finding to
      .ralph-workspace/artifacts/{{ARTIFACT_NS}}/security.md.
    verification: Confirm .ralph-workspace/artifacts/{{ARTIFACT_NS}}/security.md exists and is non-empty.
    status: pending
  - id: decide-release
    stage: release-decision
    content: |
      Decide the release for {{TASK}} from
      .ralph-workspace/artifacts/{{ARTIFACT_NS}}/candidate.md,
      .ralph-workspace/artifacts/{{ARTIFACT_NS}}/verification-handoff.md, and
      .ralph-workspace/artifacts/{{ARTIFACT_NS}}/security.md; write
      .ralph-workspace/artifacts/{{ARTIFACT_NS}}/release-verdict.json.
    verification: Confirm .ralph-workspace/artifacts/{{ARTIFACT_NS}}/release-verdict.json matches bundle/.ralph/schemas/evaluator-verdict.schema.json.
    status: pending
---
