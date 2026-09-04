---
name: review-jury
overview: Review existing work with an independent cross-provider jury - three reviewers on three different runtimes vote in parallel, a quorum join decides, and a gated verdict fails the run on an open blocking finding. Read-only; requires the claude, codex, and cursor runtimes.
kind: workflow
mode: dependency
pipeline:
  maxParallel: 3
  publishMode: manual
  verificationProfiles:
    - name: review-verdict
      steps:
        - name: review-approved
          command: python3 .ralph/python/evaluator_contract.py require-approved --artifact .ralph-workspace/artifacts/{{ARTIFACT_NS}}/review-verdict.json --schema .ralph/schemas/evaluator-verdict.schema.json
          timeout: 120
  stages:
    - id: prepare-review
      instructions: |
        Prepare a neutral review packet for {{TASK}} read-only. Identify exactly
        what is under review: the changeset, branch, or subsystem, the diff or file
        set, and what is explicitly out of scope. Record the intended behavior, the
        acceptance criteria you can establish from the repository, the relevant
        repository rules, and the build and test commands a reviewer would need.
        State facts and scope only. Do not evaluate the work, raise findings, or
        signal an opinion about its quality: every juror reads this file, so any
        judgement here contaminates all three votes and destroys the independence
        the jury exists to provide. Write the required packet to
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/review-packet.md and do not
        modify any file outside it.
        {{INCLUDE:investigation-rigor}}
        {{INCLUDE:evidence-citation}}
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/review-packet.md
          required: true
    - id: jury
      type: consensus
      policy: quorum
      quorum: 2
      minRuntimes: 3
      dependsOn:
        - prepare-review
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/review-packet.md
          required: true
      voters:
        - id: claude-juror
          runtime: claude
          sessionStrategy: fresh
          instructions: |
            Review {{TASK}} independently and read-only, using
            .ralph-workspace/artifacts/{{ARTIFACT_NS}}/review-packet.md for scope
            and commands only. Reach your own conclusion from the code: the packet
            establishes what is under review, not whether it is good. Judge
            correctness, scope discipline, regression risk, compatibility, and test
            adequacy against the stated acceptance criteria. You are one juror of
            three and you cannot see the others; do not hedge toward a middle
            position or soften a real defect in anticipation of disagreement. An
            honest lone dissent is exactly what this jury is for. Emit only the
            verdict JSON at the declared artifact path.
            {{INCLUDE:evaluator-contract}}
            {{INCLUDE:evidence-citation}}
        - id: codex-juror
          runtime: codex
          sessionStrategy: fresh
          instructions: |
            Review {{TASK}} independently and read-only, using
            .ralph-workspace/artifacts/{{ARTIFACT_NS}}/review-packet.md for scope
            and commands only. Reach your own conclusion from the code: the packet
            establishes what is under review, not whether it is good. Judge
            correctness, scope discipline, regression risk, compatibility, and test
            adequacy against the stated acceptance criteria. You are one juror of
            three and you cannot see the others; do not hedge toward a middle
            position or soften a real defect in anticipation of disagreement. An
            honest lone dissent is exactly what this jury is for. Emit only the
            verdict JSON at the declared artifact path.
            {{INCLUDE:evaluator-contract}}
            {{INCLUDE:evidence-citation}}
        - id: cursor-juror
          runtime: cursor
          sessionStrategy: fresh
          instructions: |
            Review {{TASK}} independently and read-only, using
            .ralph-workspace/artifacts/{{ARTIFACT_NS}}/review-packet.md for scope
            and commands only. Reach your own conclusion from the code: the packet
            establishes what is under review, not whether it is good. Judge
            correctness, scope discipline, regression risk, compatibility, and test
            adequacy against the stated acceptance criteria. You are one juror of
            three and you cannot see the others; do not hedge toward a middle
            position or soften a real defect in anticipation of disagreement. An
            honest lone dissent is exactly what this jury is for. Emit only the
            verdict JSON at the declared artifact path.
            {{INCLUDE:evaluator-contract}}
            {{INCLUDE:evidence-citation}}
    - id: jury-decision
      type: join
      policy: quorum
      dependsOn:
        - jury
    - id: report
      instructions: |
        Write the operator-facing review report for {{TASK}} from the three juror
        verdicts and the recorded jury decision under
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/. State the decision, then the
        merged findings ranked by severity, citing which jurors raised each one.
        Report disagreement rather than smoothing it: where the jurors split,
        say so explicitly, give each side's reasoning, and state which reading the
        evidence in the repository actually supports. A finding only one juror
        raised is a signal, not noise, and must survive into the report. Do not
        re-adjudicate the decision, downgrade a blocking finding, or drop one.
        Write .ralph-workspace/artifacts/{{ARTIFACT_NS}}/review-report.md, and
        also write
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/review-verdict.json matching
        bundle/.ralph/schemas/evaluator-verdict.schema.json. The verdict must
        restate the jury decision, not re-decide it: approve only when the recorded
        jury decision was approved and no blocking finding remains open. It decides
        the run outcome, so it must agree with the report. Do not mutate the tree.
        {{INCLUDE:evaluator-contract}}
        {{INCLUDE:evidence-citation}}
      dependsOn:
        - jury-decision
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/review-report.md
          required: true
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/review-verdict.json
          required: true
          schema: bundle/.ralph/schemas/evaluator-verdict.schema.json
    - id: review-gate
      type: gate
      profile: review-verdict
      dependsOn:
        - report
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/review-verdict.json
          required: true
todos:
  - id: review-gate
    stage: review-gate
    content: |
      Run the review-verdict profile so an open blocking finding from the jury
      fails the run.
    verification: Confirm the gate outcome records passed or changes-required.
    status: pending
  - id: prepare-review-packet
    stage: prepare-review
    content: |
      Establish scope, diff or file set, intended behavior, acceptance criteria,
      repository rules, and build and test commands for {{TASK}} in
      .ralph-workspace/artifacts/{{ARTIFACT_NS}}/review-packet.md without
      evaluating the work.
    verification: Confirm .ralph-workspace/artifacts/{{ARTIFACT_NS}}/review-packet.md exists and is non-empty.
    status: pending
  - id: jury-vote
    stage: jury
    content: |
      Each juror independently reviews {{TASK}} on its own runtime and records a
      schema-valid verdict.
    verification: Confirm each juror verdict matches bundle/.ralph/schemas/evaluator-verdict.schema.json.
    status: pending
  - id: jury-decide
    stage: jury-decision
    content: |
      Apply the quorum policy across three distinct runtimes to the juror verdicts.
    verification: Confirm the consensus result records a decision of approved or changes-required.
    status: pending
  - id: write-review-report
    stage: report
    content: |
      Merge the juror verdicts for {{TASK}} into
      .ralph-workspace/artifacts/{{ARTIFACT_NS}}/review-report.md, preserving
      minority findings and stating where the jurors disagreed, then record the
      matching verdict in
      .ralph-workspace/artifacts/{{ARTIFACT_NS}}/review-verdict.json.
    verification: Confirm .ralph-workspace/artifacts/{{ARTIFACT_NS}}/review-verdict.json matches bundle/.ralph/schemas/evaluator-verdict.schema.json.
    status: pending
---
