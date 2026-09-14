---
name: investigation
overview: Answer a question read-only, then recommend a runnable next-step Ralph plan without executing, integrating, or publishing anything.
kind: workflow
mode: dependency
pipeline:
  stages:
    - id: investigate
      instructions: |
        Investigate {{TASK}} read-only. Search the repository and current behavior,
        record the sources you read and the observations you actually reproduced,
        and keep fact separate from inference. Identify the available options,
        their tradeoffs, and the unknowns that remain. Write the required findings
        to .ralph-workspace/artifacts/{{ARTIFACT_NS}}/investigation.md with
        concrete repository citations. Do not modify any file outside that
        artifact and do not implement anything.
        {{INCLUDE:investigation-rigor}}
        {{INCLUDE:evidence-citation}}
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/investigation.md
          required: true
    - id: recommend-plan
      instructions: |
        Using {{TASK}} and
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/investigation.md, write the
        required synthesis to
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/investigation-synthesis.md
        stating the answer, the recommended option, and why the alternatives lose.
        Then write the sole required planner JSON to
        .ralph-workspace/artifacts/{{ARTIFACT_NS}}/recommended-plan.json as a
        runnable next-step Ralph plan. Emit an implementation plan only when the
        investigation shows implementation is warranted. When the question
        requires no code change, emit the smallest valid verification or
        documentation plan instead and explain that decision in the rationale.
        Every TODO needs executable verification. Do not implement anything and do
        not execute the recommended plan.
        {{INCLUDE:plan-budget}}
      dependsOn:
        - investigate
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/investigation.md
          required: true
      planner:
        outputMode: plan-file
        maxTodos: 100
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/investigation-synthesis.md
          required: true
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/recommended-plan.json
          required: true
          schema: bundle/.ralph/schemas/planner-output.schema.json
todos:
  - id: investigate-question
    stage: investigate
    content: |
      Investigate {{TASK}} read-only and write sources, reproduced observations,
      fact versus inference, options, tradeoffs, and unknowns to
      .ralph-workspace/artifacts/{{ARTIFACT_NS}}/investigation.md.
    verification: Confirm .ralph-workspace/artifacts/{{ARTIFACT_NS}}/investigation.md exists and is non-empty.
    status: pending
  - id: recommend-next-plan
    stage: recommend-plan
    content: |
      Synthesize {{TASK}} from
      .ralph-workspace/artifacts/{{ARTIFACT_NS}}/investigation.md into
      .ralph-workspace/artifacts/{{ARTIFACT_NS}}/investigation-synthesis.md, then
      write the sole planner JSON recommending the runnable next-step plan to
      .ralph-workspace/artifacts/{{ARTIFACT_NS}}/recommended-plan.json.
    verification: Confirm .ralph-workspace/artifacts/{{ARTIFACT_NS}}/recommended-plan.json matches bundle/.ralph/schemas/planner-output.schema.json.
    status: pending
---
