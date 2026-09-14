---
name: assessment
overview: Assess an existing tree or changeset read-only along four independent axes at once - correctness, security, performance, and compatibility - then synthesize one gated verdict without mutating or publishing anything.
kind: workflow
mode: dependency
pipeline:
  maxParallel: 4
  publishMode: manual
  verificationProfiles:
    - name: assessment-verdict
      steps:
        - name: assessment-approved
          command: python3 .ralph/python/evaluator_contract.py require-approved --artifact .ralph-workspace/artifacts/{{ARTIFACT_NS}}/assessment-verdict.json --schema .ralph/schemas/evaluator-verdict.schema.json
          timeout: 120
  stages:
    - id: inspect
      instructions: |
        Establish the shared baseline for assessing {{TASK}} read-only. Identify
        exactly what is under assessment: the changeset, branch, or subsystem, its
        boundaries, and what is explicitly out of scope. Record the entry points,
        the trust boundaries, the hot paths, the public surfaces, and the test and
        build commands that a reviewer would need. Do not evaluate quality here and
        do not raise findings; the four assessors depend on this file for a common,
        neutral map, and a biased baseline biases all four. Write the required
        baseline to
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/assessment-baseline.md.
        Do not modify any file outside that artifact.
        {{INCLUDE:investigation-rigor}}
        {{INCLUDE:evidence-citation}}
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/assessment-baseline.md
          required: true
    - id: assess-correctness
      instructions: |
        Assess {{TASK}} for correctness only, read-only, using
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/assessment-baseline.md as the
        scope map. Look for logic defects, unhandled error and edge cases,
        concurrency and ordering hazards, incorrect state transitions, and tests
        that assert the wrong thing or select nothing. Stay in your lane: security,
        performance, and compatibility have their own assessors, and duplicating
        their findings here inflates the synthesized report. Write findings to
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/assess-correctness-findings.md and a
        schema-valid verdict to
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/assess-correctness-verdict.json.
        Do not mutate the tree.
        {{INCLUDE:evaluator-contract}}
        {{INCLUDE:evidence-citation}}
      dependsOn:
        - inspect
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/assessment-baseline.md
          required: true
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/assess-correctness-findings.md
          required: true
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/assess-correctness-verdict.json
          required: true
          schema: bundle/.ralph/schemas/evaluator-verdict.schema.json
    - id: assess-security
      instructions: |
        Assess {{TASK}} for security only, read-only, using
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/assessment-baseline.md as the
        scope map. Examine the trust boundaries it names: input validation and
        injection paths, authentication and authorization checks, secret and
        credential handling, unsafe deserialization, path and command construction,
        dependency exposure, and information disclosure in errors and logs. Record
        exploitability and affected surface per finding, and mark each blocking or
        advisory on that basis rather than on category alone. Stay in your lane.
        Write findings to
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/assess-security-findings.md and a
        schema-valid verdict to
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/assess-security-verdict.json.
        Do not mutate the tree.
        {{INCLUDE:evaluator-contract}}
        {{INCLUDE:evidence-citation}}
      dependsOn:
        - inspect
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/assessment-baseline.md
          required: true
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/assess-security-findings.md
          required: true
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/assess-security-verdict.json
          required: true
          schema: bundle/.ralph/schemas/evaluator-verdict.schema.json
    - id: assess-performance
      instructions: |
        Assess {{TASK}} for performance and resource behavior only, read-only, using
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/assessment-baseline.md as the
        scope map. Examine the hot paths it names: algorithmic complexity, repeated
        work and N+1 access patterns, unbounded memory or queue growth, blocking
        calls on latency-sensitive paths, missing pagination or limits, and cache
        behavior. Prefer a measurement to an assertion: where a cheap read-only
        benchmark or a complexity argument from the code can settle a claim, do
        that and cite it, rather than reporting a suspicion as a finding. Stay in
        your lane. Write findings to
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/assess-performance-findings.md and a
        schema-valid verdict to
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/assess-performance-verdict.json.
        Do not mutate the tree.
        {{INCLUDE:evaluator-contract}}
        {{INCLUDE:evidence-citation}}
      dependsOn:
        - inspect
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/assessment-baseline.md
          required: true
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/assess-performance-findings.md
          required: true
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/assess-performance-verdict.json
          required: true
          schema: bundle/.ralph/schemas/evaluator-verdict.schema.json
    - id: assess-compatibility
      instructions: |
        Assess {{TASK}} for compatibility and operability only, read-only, using
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/assessment-baseline.md as the
        scope map. Examine the public surfaces it names: API and CLI contract
        changes, schema and data migrations and their rollback path, configuration
        and environment variable changes, serialized formats and persisted state,
        platform and version assumptions, and whether documentation matches current
        behavior. Call out silent breaking changes specifically: a contract that
        changed without a version, flag, or migration is the finding this axis
        exists to catch. Stay in your lane. Write findings to
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/assess-compatibility-findings.md and a
        schema-valid verdict to
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/assess-compatibility-verdict.json.
        Do not mutate the tree.
        {{INCLUDE:evaluator-contract}}
        {{INCLUDE:evidence-citation}}
      dependsOn:
        - inspect
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/assessment-baseline.md
          required: true
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/assess-compatibility-findings.md
          required: true
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/assess-compatibility-verdict.json
          required: true
          schema: bundle/.ralph/schemas/evaluator-verdict.schema.json
    - id: synthesize
      instructions: |
        Synthesize the four independent assessments of {{TASK}} into one operator
        report and one machine-readable verdict. Read all four findings files and
        all four verdicts under .ralph-workspace/artifacts/{{ARTIFACT_NS}}/.
        Merge duplicates that different axes reported as the same defect, keeping
        the highest severity and citing every axis that raised it. Do not
        re-adjudicate an axis you did not run: you may merge, deduplicate, and rank
        findings, but you may not downgrade a blocking finding to advisory or drop
        it. Rank what remains by risk and state the single most important thing to
        fix first. Write
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/assessment-report.md with the
        ranked findings, the per-axis coverage, and what was explicitly not
        assessed. Also write
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/assessment-verdict.json matching
        bundle/.ralph/schemas/evaluator-verdict.schema.json: approve only when no
        axis left a blocking finding open. Do not mutate the tree.
        {{INCLUDE:evaluator-contract}}
        {{INCLUDE:evidence-citation}}
      dependsOn:
        - assess-correctness
        - assess-security
        - assess-performance
        - assess-compatibility
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/assess-correctness-verdict.json
          required: true
          schema: bundle/.ralph/schemas/evaluator-verdict.schema.json
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/assess-security-verdict.json
          required: true
          schema: bundle/.ralph/schemas/evaluator-verdict.schema.json
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/assess-performance-verdict.json
          required: true
          schema: bundle/.ralph/schemas/evaluator-verdict.schema.json
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/assess-compatibility-verdict.json
          required: true
          schema: bundle/.ralph/schemas/evaluator-verdict.schema.json
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/assessment-report.md
          required: true
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/assessment-verdict.json
          required: true
          schema: bundle/.ralph/schemas/evaluator-verdict.schema.json
    - id: assessment-gate
      type: gate
      profile: assessment-verdict
      dependsOn:
        - synthesize
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/assessment-verdict.json
          required: true
todos:
  - id: assessment-gate
    stage: assessment-gate
    content: |
      Run the assessment-verdict profile so an open blocking finding on any axis
      fails the run.
    verification: Confirm the gate outcome records passed or changes-required.
    status: pending
  - id: establish-assessment-baseline
    stage: inspect
    content: |
      Map the scope, boundaries, entry points, trust boundaries, hot paths, public
      surfaces, and build and test commands for {{TASK}} into
      .ralph-workspace/artifacts/{{ARTIFACT_NS}}/assessment-baseline.md without
      raising findings.
    verification: Confirm .ralph-workspace/artifacts/{{ARTIFACT_NS}}/assessment-baseline.md exists and is non-empty.
    status: pending
  - id: assess-correctness-axis
    stage: assess-correctness
    content: |
      Assess {{TASK}} for logic defects, edge cases, concurrency hazards, state
      transitions, and test validity, then write the findings and verdict for this
      axis.
    verification: Confirm .ralph-workspace/artifacts/{{ARTIFACT_NS}}/assess-correctness-verdict.json matches bundle/.ralph/schemas/evaluator-verdict.schema.json.
    status: pending
  - id: assess-security-axis
    stage: assess-security
    content: |
      Assess {{TASK}} for injection, authn and authz, secret handling, unsafe
      deserialization, dependency exposure, and information disclosure, then write
      the findings and verdict for this axis.
    verification: Confirm .ralph-workspace/artifacts/{{ARTIFACT_NS}}/assess-security-verdict.json matches bundle/.ralph/schemas/evaluator-verdict.schema.json.
    status: pending
  - id: assess-performance-axis
    stage: assess-performance
    content: |
      Assess {{TASK}} for algorithmic complexity, repeated work, unbounded growth,
      blocking calls, and cache behavior, then write the findings and verdict for
      this axis.
    verification: Confirm .ralph-workspace/artifacts/{{ARTIFACT_NS}}/assess-performance-verdict.json matches bundle/.ralph/schemas/evaluator-verdict.schema.json.
    status: pending
  - id: assess-compatibility-axis
    stage: assess-compatibility
    content: |
      Assess {{TASK}} for API and CLI contract changes, migrations and rollback,
      configuration changes, persisted formats, platform assumptions, and
      documentation drift, then write the findings and verdict for this axis.
    verification: Confirm .ralph-workspace/artifacts/{{ARTIFACT_NS}}/assess-compatibility-verdict.json matches bundle/.ralph/schemas/evaluator-verdict.schema.json.
    status: pending
  - id: synthesize-assessment
    stage: synthesize
    content: |
      Merge, deduplicate, and rank the four axis findings for {{TASK}} into
      .ralph-workspace/artifacts/{{ARTIFACT_NS}}/assessment-report.md and write the
      combined verdict to
      .ralph-workspace/artifacts/{{ARTIFACT_NS}}/assessment-verdict.json.
    verification: Confirm .ralph-workspace/artifacts/{{ARTIFACT_NS}}/assessment-verdict.json matches bundle/.ralph/schemas/evaluator-verdict.schema.json.
    status: pending
---
