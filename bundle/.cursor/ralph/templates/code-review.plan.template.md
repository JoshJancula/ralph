# Stage plan: code-review

## Execution instructions
Treat this stage as a structured review of the implementation described in `implementation-handoff.md`. Verify the delivered code follows the architecture, tests, and any documented constraints before approving it.

## Context
Use `implementation-handoff.md` as the input summary of what changed, how it was verified, and what risks remain. Describe the review scope, including the areas you will validate, any assumptions the author made, and which parts of the implementation need extra scrutiny.

Artifact namespace: {{ARTIFACT_NS}}

## TODOs
{{TODOS}}

## Additional context
{{ADDITIONAL_CONTEXT}}

## Output artifact
Write `code-review.md` capturing your findings, outstanding issues, and follow-up suggestions. Include the review status block below and fill in the `approved` entry only when the change meets all expectations; populate `changes-requested` when you identify blocking concerns.

<!-- REVIEW_STATUS: START -->
approved: (fill in only when you believe the change is ready to merge; reference the implementation verification you performed)
changes-requested: (detail blocking issues, how to reproduce them, and any suggested fixes)
<!-- REVIEW_STATUS: END -->
